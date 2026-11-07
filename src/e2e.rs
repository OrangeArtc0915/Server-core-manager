//! 端到端冒烟测试：不经控制台界面，直接以协议客户端身份验证
//! 「命名管道 → 后台服务 → ConPTY → cmd.exe → 输出回传」整条链路。

use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use crate::ipc::pipe::{self, PipeStream};
use crate::proto::{self, caps, msg, FrameType};

#[test]
fn named_pipe_roundtrip() {
    let path = r"\\.\pipe\scterm-selftest-pipe".to_string();
    let sec = pipe::security_for_current_user().expect("构造安全描述符");
    let server = pipe::create_instance(&path, &sec).expect("创建管道实例");

    let client_path = path.clone();
    let client = thread::spawn(move || {
        let mut stream: Option<Arc<PipeStream>> = None;
        for _ in 0..100 {
            match pipe::connect(&client_path) {
                Ok(s) => {
                    stream = Some(s);
                    break;
                }
                Err(_) => thread::sleep(Duration::from_millis(20)),
            }
        }
        let stream = stream.expect("客户端未能连接");
        stream.write_all(b"ping").expect("客户端写入");
        let mut buf = [0u8; 4];
        let n = stream.read_some(&mut buf, 5000).expect("客户端读取");
        assert_eq!(n, 4);
        assert_eq!(&buf, b"pong");
    });

    server.accept().expect("接受连接");
    let mut buf = [0u8; 4];
    let n = server.read_some(&mut buf, 5000).expect("服务端读取");
    assert_eq!(n, 4);
    assert_eq!(&buf, b"ping");
    server.write_all(b"pong").expect("服务端写入");
    client.join().expect("客户端线程");
}

/// 只验证连接层：ConPTY 能启动子进程并回传输出。
#[test]
fn conpty_direct_output() {
    use std::sync::mpsc;
    use crate::term::conpty::{FrameSink, Pane};

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let sink: FrameSink = Arc::new(move |frame: Vec<u8>| {
        let _ = tx.send(frame);
    });
    // `/d` 关闭 cmd 的 AutoRun 脚本，避免用户环境里的欢迎脚本干扰测试。
    let pane = Pane::spawn(1, "cmd.exe /d /c echo direct-ok", None, 80, 24, sink)
        .expect("创建窗格失败");

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = String::new();
    while Instant::now() < deadline && !seen.contains("direct-ok") {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(raw) => {
                let (ty, _len) = crate::proto::decode_header(&raw[..12]).expect("帧头");
                if ty == FrameType::Output {
                    if let Ok(data) = msg::PaneData::decode(&raw[12..]) {
                        seen.push_str(&String::from_utf8_lossy(&data.data));
                    }
                } else if ty == FrameType::PaneExited {
                    break;
                }
            }
            Err(_) => {}
        }
    }
    drop(pane);
    assert!(
        seen.contains("direct-ok"),
        "ConPTY 未回传子进程输出，累计：{seen:?}"
    );
}

/// 运行一条命令并收集窗格输出（shell 集成冒烟用）。
fn capture_pane_output(command_line: &str) -> String {
    use crate::term::conpty::{FrameSink, Pane};
    use std::sync::mpsc;

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let sink: FrameSink = Arc::new(move |frame: Vec<u8>| {
        let _ = tx.send(frame);
    });
    let pane = Pane::spawn(1, command_line, None, 120, 30, sink).expect("创建窗格失败");
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut seen = String::new();
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(raw) => {
                let (ty, _len) = crate::proto::decode_header(&raw[..12]).expect("帧头");
                if ty == FrameType::Output {
                    if let Ok(data) = msg::PaneData::decode(&raw[12..]) {
                        seen.push_str(&String::from_utf8_lossy(&data.data));
                    }
                } else if ty == FrameType::PaneExited {
                    break;
                }
            }
            Err(_) => {}
        }
    }
    drop(pane);
    seen
}

/// PowerShell 集成脚本应输出 OSC 133;A 与 OSC 7。
#[test]
fn powershell_integration_emits_osc() {
    let dir = std::env::temp_dir().join(format!("scterm-e2e-integration-{}", std::process::id()));
    let assets = crate::integration::ensure(&dir).expect("写入集成脚本");
    let path = assets.ps1.display().to_string().replace('\'', "''");
    let command_line = format!(
        "powershell.exe -NoProfile -Command \". '{}'; prompt; exit\"",
        path
    );
    let seen = capture_pane_output(&command_line);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(seen.contains("]133;A"), "未看到提示符标记，累计：{seen:?}");
    assert!(seen.contains("]7;file://"), "未看到目录上报，累计：{seen:?}");
}

/// cmd 集成脚本应通过 PROMPT 输出 OSC 133;A。
#[test]
fn cmd_integration_sets_prompt() {
    let dir = std::env::temp_dir().join(format!("scterm-e2e-integration-{}", std::process::id()));
    let assets = crate::integration::ensure(&dir).expect("写入集成脚本");
    let command_line = format!("cmd.exe /d /c call \"{}\" & set PROMPT", assets.cmd.display());
    let seen = capture_pane_output(&command_line);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(seen.contains("]133;A"), "未看到提示符标记，累计：{seen:?}");
}

/// 仿真 + 渲染链路：把真实 ConPTY 输出喂给解析器，验证差异渲染结果。
#[test]
fn emulation_renders_real_conpty_output() {
    use std::sync::mpsc;
    use crate::emulation::screen::Screen;
    use crate::emulation::Parser;
    use crate::render::Renderer;
    use crate::term::conpty::{FrameSink, Pane};

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let sink: FrameSink = Arc::new(move |frame: Vec<u8>| {
        let _ = tx.send(frame);
    });
    let pane = Pane::spawn(
        1,
        "cmd.exe /d /c echo scterm-render-ok",
        None,
        80,
        24,
        sink,
    )
    .expect("创建窗格失败");

    let mut screen = Screen::new(80, 24, 1000);
    let mut parser = Parser::new();
    let mut renderer = Renderer::new();

    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(raw) => {
                let (ty, _len) = crate::proto::decode_header(&raw[..12]).expect("帧头");
                if ty == FrameType::Output {
                    let data = msg::PaneData::decode(&raw[12..]).expect("Output 负载");
                    parser.feed(&data.data, &mut screen);
                } else if ty == FrameType::PaneExited {
                    break;
                }
            }
            Err(_) => {}
        }
    }
    drop(pane);

    let painted = String::from_utf8_lossy(&renderer.paint(
        screen.cells(),
        screen.cols,
        screen.rows,
        None,
        0,
    ))
    .to_string();
    assert!(
        painted.contains("scterm-render-ok"),
        "渲染结果应包含命令输出，实际：{painted:?}"
    );
    assert!(
        screen.cells().iter().any(|c| c.ch == 's'),
        "屏幕网格应已被写入"
    );
}

/// 真实客户端冒烟：把 scterm.exe 放进伪控制台里跑，再解析它绘制出的画面。
///
/// 这是「客户端渲染 + 键盘转发」不需要人眼盯屏的验证方式，默认不参与 `cargo test`：
/// 它会启动真实的客户端与后台服务进程，用 `cargo test zz_client_console_smoke -- --ignored` 单独执行。
#[test]
#[ignore]
fn zz_client_console_smoke() {
    use std::sync::mpsc;
    use crate::emulation::screen::Screen;
    use crate::emulation::Parser;
    use crate::term::conpty::{FrameSink, Pane};

    let exe = match std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .map(|dir| dir.join("scterm.exe"))
    {
        Some(p) if p.exists() => p,
        _ => {
            eprintln!("[skip] 未找到 scterm.exe，跳过真实客户端冒烟");
            return;
        }
    };

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let sink: FrameSink = Arc::new(move |frame: Vec<u8>| {
        let _ = tx.send(frame);
    });
    let pane = Pane::spawn(1, &format!("\"{}\"", exe.display()), None, 100, 30, sink)
        .expect("启动客户端失败");

    let mut screen = Screen::new(100, 30, 1000);
    let mut parser = Parser::new();
    let mut typed = false;
    let started = Instant::now();
    let mut found = false;

    while started.elapsed() < Duration::from_secs(25) {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(raw) => {
                if raw.len() < 12 {
                    continue;
                }
                let (ty, _len) = crate::proto::decode_header(&raw[..12]).expect("帧头");
                if ty == FrameType::Output {
                    let data = msg::PaneData::decode(&raw[12..]).expect("负载");
                    parser.feed(&data.data, &mut screen);
                    let text: String = screen.cells().iter().map(|c| c.ch).collect();
                    if !typed && text.contains('>') {
                        // 客户端已完成首屏绘制，开始模拟键入
                        if pane.write_input(b"echo client-ok\r\n").is_ok() {
                            typed = true;
                        }
                    }
                    if text.contains("client-ok") && text.matches("client-ok").count() >= 2 {
                        found = true;
                        break;
                    }
                } else if ty == FrameType::PaneExited {
                    break;
                }
            }
            Err(_) => {}
        }
    }
    drop(pane);

    assert!(
        found,
        "客户端未把命令结果绘制到画面。首屏内容：{:?}",
        screen.cells().iter().map(|c| c.ch).collect::<String>()
    );
}

#[test]
fn conpty_roundtrip_over_named_pipe() {
    crate::platform::logging::init(true);
    thread::spawn(|| {
        let _ = crate::ipc::server::run();
    });

    let path = pipe::pipe_path().expect("获取管道路径");
    let stream = connect_with_retry(&path);

    let hello = msg::Hello {
        proto_ver: proto::PROTO_VERSION as u16,
        build: 19044,
        caps: caps::TRUECOLOR,
        cols: 80,
        rows: 24,
        profile: "default".to_string(),
    };
    stream
        .write_frame(FrameType::Hello, &hello.encode())
        .expect("发送 Hello");
    let ack = expect_frame(&stream, FrameType::HelloAck, 5000).expect("未收到 HelloAck");
    assert_eq!(
        msg::HelloAck::decode(&ack).unwrap().proto_ver,
        proto::PROTO_VERSION as u16
    );

    let create = msg::CreatePane {
        pane_id: 1,
        profile: "cmd".to_string(),
        cols: 80,
        rows: 24,
    };
    stream
        .write_frame(FrameType::CreatePane, &create.encode())
        .expect("发送 CreatePane");
    expect_frame(&stream, FrameType::PaneCreated, 10000).expect("窗格未在 10 秒内创建");

    let input = msg::PaneData {
        pane_id: 1,
        data: b"echo scterm-e2e-ok\r\n".to_vec(),
    };
    stream
        .write_frame(FrameType::Input, &input.encode())
        .expect("发送输入");

    let deadline = Instant::now() + Duration::from_secs(15);
    let mut seen = String::new();
    while Instant::now() < deadline && !seen.contains("scterm-e2e-ok") {
        let remain = deadline.saturating_duration_since(Instant::now()).as_millis() as u32;
        match stream.read_frame_with(remain) {
            Ok(Some(frame)) => match frame.ty {
                FrameType::Output => {
                    if let Ok(data) = msg::PaneData::decode(&frame.payload) {
                        seen.push_str(&String::from_utf8_lossy(&data.data));
                    }
                }
                FrameType::PaneExited => break,
                _ => {}
            },
            Ok(None) => break,
            Err(e) => panic!("读取输出失败：{e}"),
        }
    }

    let close = msg::PaneId { pane_id: 1 };
    let _ = stream.write_frame(FrameType::ClosePane, &close.encode());

    assert!(
        seen.contains("scterm-e2e-ok"),
        "15 秒内未看到命令回显，累计输出：{seen:?}"
    );
}

fn connect_with_retry(path: &str) -> Arc<PipeStream> {
    for _ in 0..100 {
        if let Ok(s) = pipe::connect(path) {
            return s;
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("后台服务未在 5 秒内就绪");
}

fn expect_frame(stream: &PipeStream, ty: FrameType, timeout_ms: u32) -> Option<Vec<u8>> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms as u64);
    loop {
        let remain = deadline.saturating_duration_since(Instant::now()).as_millis() as u32;
        if remain == 0 {
            return None;
        }
        match stream.read_frame_with(remain) {
            Ok(Some(frame)) => {
                if frame.ty == ty {
                    return Some(frame.payload);
                }
                if frame.ty == FrameType::Error {
                    if let Ok(e) = msg::ErrorMsg::decode(&frame.payload) {
                        eprintln!("[e2e] 服务端返回错误：{}", e.message);
                    }
                    return None;
                }
            }
            Ok(None) => return None,
            Err(e) => {
                eprintln!("[e2e] 读取失败：{e}");
                return None;
            }
        }
    }
}

/// 客户端进程退出后必须补发 PaneExited（重叠 I/O 输出泵的回归测试）。
#[test]
fn pane_exit_code_is_reported() {
    use std::sync::mpsc;
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let sink: crate::term::conpty::FrameSink = Arc::new(move |frame: Vec<u8>| {
        let _ = tx.send(frame);
    });
    let pane = crate::term::conpty::Pane::spawn(1, "cmd.exe /d /c exit 5", None, 80, 24, sink)
        .expect("创建窗格失败");

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut code = None;
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(raw) => {
                if let Some((FrameType::PaneExited, payload)) = decode_pane_frame(&raw) {
                    code = Some(msg::PaneExited::decode(&payload).unwrap().exit_code);
                    break;
                }
            }
            Err(_) => {}
        }
    }
    drop(pane);
    assert_eq!(code, Some(5), "未收到退出码为 5 的 PaneExited");
}

/// 真实客户端探针：把 scterm.exe（客户端本体）跑在 ConPTY 里，
/// 用本项目的 VT 解析器回读它画出的屏幕，验证启动、执行命令、滚轮回看、退出提示。
///
/// 运行方式（需要先 `cargo build --release`）：
/// `cargo test zz_client_probe -- --ignored --test-threads=1`
#[test]
#[ignore]
fn zz_client_probe() {
    use crate::emulation::screen::Screen;
    use crate::emulation::Parser;
    use std::path::PathBuf;
    use std::sync::mpsc;

    let report_path = std::env::temp_dir().join("scterm_client_probe.txt");
    let mut report = String::new();
    let exe = std::env::var("SCTERM_EXE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("target")
                .join("release")
                .join("scterm.exe")
        });
    if !exe.is_file() {
        let _ = std::fs::write(
            &report_path,
            format!("未找到 {}，请先 cargo build --release\n", exe.display()),
        );
        return;
    }

    let outcome = (|| -> Result<(), String> {
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let sink: crate::term::conpty::FrameSink = Arc::new(move |frame: Vec<u8>| {
            let _ = tx.send(frame);
        });
        let home = std::env::var("USERPROFILE").ok();
        let pane = crate::term::conpty::Pane::spawn(
            1,
            &format!("\"{}\"", exe.display()),
            home.as_deref(),
            100,
            30,
            sink,
        )
        .map_err(|e| format!("启动客户端失败：{e}"))?;

        let mut screen = Screen::new(100, 30, 4000);
        let mut parser = Parser::new();
        let mut raw: Vec<u8> = Vec::new();
        let first = pump_until(&rx, &mut parser, &mut screen, &mut raw, "客户端首屏", Duration::from_secs(20), |s| {
            screen_text(s).contains("命令解释器")
        });
        if first.is_err() {
            report.push_str("== 首屏失败，屏幕内容 ==\n");
            report.push_str(&screen_text(&screen));
            report.push_str("\n== 原始输出（前 4KB）==\n");
            let head = &raw[..raw.len().min(4096)];
            report.push_str(&String::from_utf8_lossy(head));
            report.push_str("\n== 原始输出（尾部 4KB）==\n");
            let tail = &raw[raw.len().saturating_sub(4096)..];
            report.push_str(&String::from_utf8_lossy(tail));
            return first;
        }
        report.push_str("== 1. 启动后 ==\n");
        report.push_str(&screen_text(&screen));
        report.push_str("\n");
        let _ = std::fs::write(
            std::env::temp_dir().join("scterm_probe_raw1.bin"),
            &raw,
        );

        pane.write_input(b"ver\r")
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(&rx, &mut parser, &mut screen, &mut raw, "ver 输出", Duration::from_secs(10), |s| {
            screen_text(s).contains("Windows build")
        })?;
        report.push_str("\n== 2. ver 之后 ==\n");
        report.push_str(&screen_text(&screen));
        report.push_str("\n");

        pane.write_input(b"dir C:\\Windows\r")
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(&rx, &mut parser, &mut screen, &mut raw, "dir 输出", Duration::from_secs(20), |s| {
            screen_text(s).contains("个文件")
        })?;

        // Tab 补全：hel<TAB> 应补成 help 并执行（等帮助正文最后一行，避免首行滚出屏幕）
        pane.write_input(b"hel\t\r")
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "Tab 补全",
            Duration::from_secs(10),
            |s| screen_text(s).contains("Ctrl+C 取消当前行"),
        )
        .map_err(|e| format!("Tab 补全失败：{e}"))?;
        if screen_text(&screen).contains("未知的内置命令") {
            return Err("Tab 补全没有补成 help".into());
        }

        // 退格：输入 echo zzqX<BS>zz9，退格生效时输出 zzqzz9 且不出现 zzqX
        pane.write_input(b"echo zzqX\x7fzz9\r")
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "退格后输出",
            Duration::from_secs(10),
            |s| screen_text(s).matches("zzqzz9").count() >= 2,
        )
        .map_err(|e| format!("退格失败：{e}"))?;
        if screen_text(&screen).contains("zzqX") {
            return Err("退格没有删除字符（屏幕上仍有 zzqX）".into());
        }

        // 中文输入 + 输出：屏幕最终应出现两处「中文测试」（输入回显 + 命令输出）
        pane.write_input("echo 中文测试\r".as_bytes())
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "中文输出",
            Duration::from_secs(10),
            |s| screen_text(s).matches("中文测试").count() >= 2,
        )
        .map_err(|e| format!("中文输入输出失败：{e}"))?;

        // 历史：↑ 再回车应重复上一条命令（再多一处中文测试）
        pane.write_input(b"\x1b[A\r")
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "历史命令",
            Duration::from_secs(10),
            |s| screen_text(s).matches("中文测试").count() >= 3,
        )
        .map_err(|e| format!("历史命令失败：{e}"))?;

        // 中文文件名 + 对齐
        let temp = std::env::temp_dir();
        let cjk_dir = temp.join("scterm_probe_cjk");
        let _ = std::fs::create_dir_all(&cjk_dir);
        let _ = std::fs::write(cjk_dir.join("中文文件.txt"), b"x");
        pane.write_input(format!("dir \"{}\"\r", cjk_dir.display()).as_bytes())
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "中文文件名",
            Duration::from_secs(10),
            |s| screen_text(s).contains("中文文件.txt"),
        )
        .map_err(|e| format!("中文文件名显示失败：{e}"))?;
        report.push_str("\n== 2.5 中文 / Tab / 退格 ==\n");
        report.push_str(&screen_text(&screen));
        report.push_str("\n");

        // 高吞吐输出：几万个目录项，验证客户端不卡死、不崩溃
        pane.write_input(b"cmd /d /c \"dir /s C:\\Windows\\System32 & echo done-marker\"\r")
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "大输出完成",
            Duration::from_secs(90),
            |s| screen_text(s).contains("done-marker"),
        )?;
        report.push_str("\n== 3. 大输出完成 ==\n");
        report.push_str(&screen_text(&screen));
        report.push_str("\n");

        // 缩放：100x30 -> 80x24，客户端应重排并重绘
        pane.resize(80, 24);
        let mut resized = Screen::new(80, 24, 4000);
        pump_until(
            &rx,
            &mut parser,
            &mut resized,
            &mut raw,
            "缩放后重绘",
            Duration::from_secs(15),
            |s| {
                let text = screen_text(s);
                text.contains("1:scterm") && text.contains("C:\\Users")
            },
        )?;
        report.push_str("\n== 4. 缩放后 ==\n");
        report.push_str(&screen_text(&resized));
        report.push_str("\n");

        // OSC 7：换目录后标签栏右侧应显示新路径
        pane.write_input(b"cd C:\\Windows\r")
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(
            &rx,
            &mut parser,
            &mut resized,
            &mut raw,
            "cd 后目录显示",
            Duration::from_secs(10),
            |s| {
                screen_text(s)
                    .lines()
                    .next()
                    .map(|line| line.contains("C:\\Windows"))
                    .unwrap_or(false)
            },
        )
        .map_err(|e| format!("标签栏没有跟随目录变化：{e}"))?;
        report.push_str("\n== 4.5 cd 之后（标签栏应显示 C:\\Windows）==\n");
        report.push_str(&screen_text(&resized));
        report.push_str("\n");

        // 输出超过一屏：应正常滚屏（最后 10 行分别是 L51..L60），不能全堆在最后一行
        let paging = std::env::temp_dir().join("scterm_paging_probe.txt");
        let body: String = (1..=60).map(|i| format!("L{i}\r\n")).collect();
        let _ = std::fs::write(&paging, body);
        pane.write_input(format!("type \"{}\"\r", paging.display()).as_bytes())
            .map_err(|e| format!("写入失败：{e}"))?;
        pump_until(
            &rx,
            &mut parser,
            &mut resized,
            &mut raw,
            "分页输出",
            Duration::from_secs(20),
            |s| screen_text(s).contains("L60"),
        )
        .map_err(|e| format!("分页输出失败：{e}"))?;
        let text = screen_text(&resized);
        report.push_str("\n== 4.6 60 行输出之后 ==\n");
        report.push_str(&text);
        report.push_str("\n");
        let tail: Vec<&str> = text.lines().rev().take(12).collect();
        for n in 51..=60 {
            let needle = format!("L{n}");
            if !tail.iter().any(|line| line.trim().ends_with(&needle)) {
                return Err(format!(
                    "输出超过一屏后 L{n} 不在屏幕上（内容可能全堆在最后一行）"
                ));
            }
        }

        pane.write_input(b"exit\r")
            .map_err(|e| format!("写入失败：{e}"))?;
        let exited = pump_until(
            &rx,
            &mut parser,
            &mut resized,
            &mut raw,
            "退出提示",
            Duration::from_secs(15),
            |s| screen_text(s).contains("进程已退出"),
        )
        .is_ok();
        report.push_str(&format!(
            "\n== 5. exit 结果：{} ==\n",
            if exited { "显示退出码" } else { "无退出提示（BUG）" }
        ));
        report.push_str(&screen_text(&resized));
        report.push_str("\n");

        if !exited {
            return Err("exit 后没有显示退出提示".into());
        }
        Ok(())
    })();

    let status = match &outcome {
        Ok(()) => "通过".to_string(),
        Err(e) => format!("失败：{e}"),
    };
    report.push_str(&format!("\n结果：{status}\n"));
    let _ = std::fs::write(&report_path, &report);
    if let Err(e) = outcome {
        panic!("客户端探针失败：{e}（详见 {}）", report_path.display());
    }
}

/// 拉取输出帧喂给解析器，直到屏幕满足条件或超时。
fn pump_until(
    rx: &std::sync::mpsc::Receiver<Vec<u8>>,
    parser: &mut crate::emulation::Parser,
    screen: &mut crate::emulation::screen::Screen,
    raw: &mut Vec<u8>,
    what: &str,
    timeout: Duration,
    mut predicate: impl FnMut(&crate::emulation::screen::Screen) -> bool,
) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    loop {
        if predicate(screen) {
            return Ok(());
        }
        let remain = deadline.saturating_duration_since(Instant::now());
        if remain.is_zero() {
            return Err(format!("{what} 超时"));
        }
        match rx.recv_timeout(remain.min(Duration::from_millis(100))) {
            Ok(raw_frame) => {
                if let Some((FrameType::Output, payload)) = decode_pane_frame(&raw_frame) {
                    if let Ok(data) = msg::PaneData::decode(&payload) {
                        raw.extend_from_slice(&data.data);
                        if raw.len() > 262_144 {
                            raw.drain(..131_072);
                        }
                        parser.feed(&data.data, screen);
                    }
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                return Err(format!("{what} 时输出通道关闭"));
            }
        }
    }
}

fn screen_text(screen: &crate::emulation::screen::Screen) -> String {
    let mut out = String::new();
    for y in 0..screen.rows {
        let mut line = String::new();
        if let Some(cells) = screen.row(y) {
            for cell in cells {
                if cell.attrs.flags & crate::emulation::screen::ATTR_WIDE_TAIL != 0 {
                    continue;
                }
                line.push(cell.ch);
            }
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}

/// 诊断用：40 列窗口里输入超长命令行，检查行编辑的换行/滚动是否正确。
///
/// `cargo test zz_long_input_probe -- --ignored --test-threads=1`
#[test]
#[ignore]
fn zz_long_input_probe() {
    use crate::emulation::screen::Screen;
    use crate::emulation::Parser;
    use std::path::PathBuf;
    use std::sync::mpsc;

    let report_path = std::env::temp_dir().join("scterm_long_input_probe.txt");
    let exe = std::env::var("SCTERM_EXE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("target")
                .join("release")
                .join("scterm.exe")
        });
    if !exe.is_file() {
        return;
    }

    let mut report = String::new();
    let outcome = (|| -> Result<(), String> {
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let sink: crate::term::conpty::FrameSink = Arc::new(move |frame: Vec<u8>| {
            let _ = tx.send(frame);
        });
        let home = std::env::var("USERPROFILE").ok();
        let pane = crate::term::conpty::Pane::spawn(
            1,
            &format!("\"{}\"", exe.display()),
            home.as_deref(),
            40,
            12,
            sink,
        )
        .map_err(|e| format!("启动客户端失败：{e}"))?;

        let mut screen = Screen::new(40, 12, 100);
        let mut parser = Parser::new();
        let mut raw: Vec<u8> = Vec::new();
        pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "首屏",
            Duration::from_secs(15),
            |s| screen_text(s).contains("命令解释器"),
        )?;
        report.push_str("== 初始 ==\n");
        report.push_str(&screen_text(&screen));
        report.push('\n');

        let text: String = "abcdefghij".repeat(9);
        pane.write_input(text.as_bytes())
            .map_err(|e| format!("写入失败：{e}"))?;
        let _ = pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "输入后",
            Duration::from_millis(900),
            |_| false,
        );
        report.push_str("== 输入 90 字符后 ==\n");
        report.push_str(&screen_text(&screen));
        report.push('\n');
        let flat = screen_text(&screen).replace('\n', "");
        if !flat.contains(&text[..20]) || !flat.contains(&text[text.len() - 20..]) {
            return Err("超长命令行首尾显示不完整（换行/滚动有问题）".into());
        }

        // Ctrl+U 清空当前行，再输入 90 个中文字符（占 180 列）
        pane.write_input(b"\x15")
            .map_err(|e| format!("写入失败：{e}"))?;
        let cjk: String = "中文输入测试".repeat(15);
        pane.write_input(cjk.as_bytes())
            .map_err(|e| format!("写入失败：{e}"))?;
        let _ = pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "中文长行",
            Duration::from_millis(900),
            |_| false,
        );
        report.push_str("== 输入 90 个中文字符后 ==\n");
        report.push_str(&screen_text(&screen));
        report.push('\n');
        let flat = screen_text(&screen).replace('\n', "");
        if !flat.contains(&cjk[..12]) || !flat.contains(&cjk[cjk.len() - 12..]) {
            return Err("中文超长命令行显示不完整（宽字符换行有问题）".into());
        }

        pane.write_input(b"\x7f\x7f\x7f")
            .map_err(|e| format!("写入失败：{e}"))?;
        let _ = pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "退格后",
            Duration::from_millis(600),
            |_| false,
        );
        report.push_str("== 退格 3 次后 ==\n");
        report.push_str(&screen_text(&screen));
        report.push('\n');

        // 强制触发滚动：400 字符（10 行）在 12 行窗口里必滚屏
        pane.write_input(b"\x15")
            .map_err(|e| format!("写入失败：{e}"))?;
        let long_text: String = "0123456789".repeat(40);
        pane.write_input(long_text.as_bytes())
            .map_err(|e| format!("写入失败：{e}"))?;
        let _ = pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "超长滚动",
            Duration::from_millis(1200),
            |_| false,
        );
        report.push_str("== 400 字符（强制滚动）后 ==\n");
        report.push_str(&screen_text(&screen));
        report.push('\n');
        let flat = screen_text(&screen).replace('\n', "");
        if !flat.contains(&long_text[long_text.len() - 20..]) {
            return Err("超长输入滚动后，行尾内容丢失（回退行数算错）".into());
        }
        if screen_text(&screen).contains("命令解释器") {
            // 滚屏后 banner 应该已经被顶出屏幕；仍可见说明没有真正滚动
            return Err("400 字符输入没有触发滚动（画面没有上移）".into());
        }

        // 输入比整屏还高：600 字符 = 15 行 > 12 行。
        // 正确做法是「从屏幕顶部重画最后一屏」，错误做法是每敲一个键就把整屏再滚一遍
        // （表现就是内容一直往下堆，最后只剩最后一行在变）。
        pane.write_input(b"\x15")
            .map_err(|e| format!("写入失败：{e}"))?;
        let before = screen.history_len();
        let tall: String = "T".repeat(600);
        pane.write_input(tall.as_bytes())
            .map_err(|e| format!("写入失败：{e}"))?;
        let _ = pump_until(
            &rx,
            &mut parser,
            &mut screen,
            &mut raw,
            "超过一屏的输入",
            Duration::from_millis(1800),
            |_| false,
        );
        report.push_str("== 600 字符（超过一屏）后 ==\n");
        report.push_str(&screen_text(&screen));
        report.push('\n');
        let text = screen_text(&screen);
        let filled = text.lines().filter(|line| !line.trim().is_empty()).count();
        if filled < 8 {
            return Err(format!("超出整屏的输入只占了 {filled} 行（应铺满整屏）"));
        }
        if !text.replace('\n', "").contains(&tall[tall.len() - 20..]) {
            return Err("超出整屏的输入后，行尾内容丢失".into());
        }
        let grew = screen.history_len().saturating_sub(before);
        if grew > 60 {
            return Err(format!(
                "输入超过一屏时每个按键都把整屏重滚了一遍（新增 {grew} 行回看）"
            ));
        }
        Ok(())
    })();

    let status = match &outcome {
        Ok(()) => "通过".to_string(),
        Err(e) => format!("失败：{e}"),
    };
    report.push_str(&format!("\n结果：{status}\n"));
    let _ = std::fs::write(&report_path, &report);
    if let Err(e) = outcome {
        panic!("超长输入探针失败：{e}（详见 {}）", report_path.display());
    }
}

/// 真实自研 shell 冒烟：以 release 构建的 scterm.exe 作为窗格子进程，
/// 经 ConPTY 执行内置命令、外部命令、重定向、管道与 `exit 3`。
///
/// 运行方式（需要先 `cargo build --release`）：
/// `cargo test zz_shell_smoke -- --ignored --test-threads=1`
///
/// 注意：`Pane::spawn` 会 `FreeConsole` + 清空标准句柄，测试进程之后的
/// 标准输出不可用，因此结果同时写入 `%TEMP%\scterm_shell_smoke.txt`。
#[test]
#[ignore]
fn zz_shell_smoke_via_release_binary() {
    use std::path::PathBuf;
    use std::sync::mpsc;

    let mut report = String::new();
    let mut seen = String::new();
    let outcome = (|| -> Result<(), String> {
        let exe = std::env::var("SCTERM_EXE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("target")
                    .join("release")
                    .join("scterm.exe")
            });
        if !exe.is_file() {
            return Err(format!("未找到 {}，请先 cargo build --release", exe.display()));
        }

        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let sink: crate::term::conpty::FrameSink = Arc::new(move |frame: Vec<u8>| {
            let _ = tx.send(frame);
        });
        let command_line = format!("\"{}\" shell --verbose", exe.display());
        let home = std::env::var("USERPROFILE").ok();
        let pane = crate::term::conpty::Pane::spawn(
            1,
            &command_line,
            home.as_deref(),
            80,
            24,
            sink,
        )
        .map_err(|e| format!("启动 shell 失败：{e}"))?;

        expect_pane_text(&rx, &mut seen, "scterm shell", 10_000)?;
        pane.write_input(b"help\r")
            .map_err(|e| format!("写入输入失败：{e}"))?;
        expect_pane_text(&rx, &mut seen, "scterm shell 内置命令", 10_000)?;
        pane.write_input(b"where cmd\r")
            .map_err(|e| format!("写入输入失败：{e}"))?;
        expect_pane_text(&rx, &mut seen, "cmd.exe", 10_000)?;

        let temp = std::env::temp_dir();
        let redirect_file = temp.join("scterm_smoke_redirect.txt");
        let _ = std::fs::remove_file(&redirect_file);
        pane.write_input(format!("echo hello-redirect > \"{}\"\r", redirect_file.display()).as_bytes())
            .map_err(|e| format!("写入输入失败：{e}"))?;
        wait_until(Duration::from_secs(10), || {
            std::fs::read_to_string(&redirect_file)
                .map(|text| text.trim() == "hello-redirect")
                .unwrap_or(false)
        })
        .map_err(|e| format!("内置命令重定向未生效：{e}"))?;

        let pipe_file = temp.join("scterm_smoke_pipe.txt");
        let _ = std::fs::remove_file(&pipe_file);
        pane.write_input(
            format!(
                "cmd.exe /d /c echo pipe-ok | findstr pipe-ok > \"{}\"\r",
                pipe_file.display()
            )
            .as_bytes(),
        )
        .map_err(|e| format!("写入输入失败：{e}"))?;
        wait_until(Duration::from_secs(10), || {
            std::fs::read_to_string(&pipe_file)
                .map(|text| text.contains("pipe-ok"))
                .unwrap_or(false)
        })
        .map_err(|e| format!("管道 + 重定向未生效：{e}"))?;

        // 内置命令作为管道首段：echo 的输出直接喂给 findstr。
        let builtin_pipe_file = temp.join("scterm_smoke_builtin_pipe.txt");
        let _ = std::fs::remove_file(&builtin_pipe_file);
        pane.write_input(
            format!(
                "echo builtin-pipe-ok | findstr builtin-pipe-ok > \"{}\"\r",
                builtin_pipe_file.display()
            )
            .as_bytes(),
        )
        .map_err(|e| format!("写入输入失败：{e}"))?;
        wait_until(Duration::from_secs(10), || {
            std::fs::read_to_string(&builtin_pipe_file)
                .map(|text| text.contains("builtin-pipe-ok"))
                .unwrap_or(false)
        })
        .map_err(|e| format!("内置命令管道未生效：{e}"))?;

        // 新增内置命令（cmd 同名）：md/ren/erase/rd/vol/chcp/date/pushd/popd
        let cmd_dir = temp.join("scterm_smoke_cmd");
        let _ = std::fs::remove_dir_all(&cmd_dir);
        let _ = std::fs::create_dir_all(&cmd_dir);
        let _ = std::fs::write(cmd_dir.join("a.txt"), b"x");

        let write = |text: String| {
            // 上一条命令可能还没回到提示符，等一会儿再敲，避免输入被子进程吃掉。
            thread::sleep(Duration::from_millis(700));
            pane.write_input(format!("{text}\r").as_bytes())
                .map_err(|e| format!("写入输入失败：{e}"))
        };
        write(format!("ren \"{}\" b.txt", cmd_dir.join("a.txt").display()))?;
        wait_until(Duration::from_secs(10), || cmd_dir.join("b.txt").is_file())
            .map_err(|e| format!("ren 未生效：{e}"))?;

        write(format!("md \"{}\"", cmd_dir.join("sub").display()))?;
        wait_until(Duration::from_secs(10), || cmd_dir.join("sub").is_dir())
            .map_err(|e| format!("md 未生效：{e}"))?;

        write(format!("erase \"{}\"", cmd_dir.join("b.txt").display()))?;
        wait_until(Duration::from_secs(10), || !cmd_dir.join("b.txt").exists())
            .map_err(|e| format!("erase 未生效：{e}"))?;

        write(format!("rd \"{}\"", cmd_dir.join("sub").display()))?;
        wait_until(Duration::from_secs(10), || !cmd_dir.join("sub").exists())
            .map_err(|e| format!("rd 未生效：{e}"))?;

        write("vol".to_string())?;
        expect_pane_text(&rx, &mut seen, "文件系统：", 10_000)?;

        write("chcp".to_string())?;
        expect_pane_text(&rx, &mut seen, "65001", 10_000)?;

        write("date /t".to_string())?;
        expect_pane_text(&rx, &mut seen, "周", 10_000)?;

        // pushd / popd：进目录后 pwd 应显示新路径，popd 后回到原目录
        write(format!("pushd \"{}\"", cmd_dir.display()))?;
        write("pwd".to_string())?;
        expect_pane_text(&rx, &mut seen, "scterm_smoke_cmd", 10_000)?;
        write("popd".to_string())?;

        // 等 shell 完全回到提示符后再发 exit（子进程运行期间键入的回车可能被控制台吞掉）。
        thread::sleep(Duration::from_millis(1500));
        pane.write_input(b"exit 3\r")
            .map_err(|e| format!("写入输入失败：{e}"))?;
        let code = expect_pane_exit(&rx, &mut seen, 15_000)?;
        if code != 3 {
            return Err(format!("exit 3 的退出码应为 3，实际 {code}"));
        }
        Ok(())
    })();

    report.push_str(&seen);
    let status = match &outcome {
        Ok(()) => "通过".to_string(),
        Err(e) => format!("失败：{e}"),
    };
    report.push_str(&format!("\r\n结果：{status}\r\n"));
    let report_path = std::env::temp_dir().join("scterm_shell_smoke.txt");
    let _ = std::fs::write(&report_path, &report);
    if let Err(e) = outcome {
        panic!("shell 冒烟失败：{e}（详见 {}）", report_path.display());
    }
}

/// 脚本控制流冒烟：`run 脚本.sct` 在真实 shell 里执行
/// `set /a`、`if / else`、`for /l`、`call :标签`、`goto` 与 `exit /b`。
///
/// 运行方式（需要先 `cargo test --release --no-run` 或 `cargo build --release`）：
/// `cargo test zz_script_smoke -- --ignored --test-threads=1`
#[test]
#[ignore]
fn zz_script_smoke_via_release_binary() {
    use std::path::PathBuf;
    use std::sync::mpsc;

    const SCRIPT: &str = "\
@echo off
set /a n=0
set /a n=n+1
echo step1=%n%
set /a p=1,q=p+4
echo pq=%q% p=%p%
if defined n (
    echo if-defined
) else (
    echo if-missing
)
if not exist scterm_missing_file.tmp (
    echo not-exist
)
for /l %%i in (1,1,3) do (
    echo loop=%%i
    set /a n=n+1
)
call :sub alpha beta
echo n=%n%
goto :done
echo skipped
:done
exit /b 7
:sub
echo sub=%1-%2
if \"%1\"==\"alpha\" echo alpha-ok
exit /b 0
";

    let mut report = String::new();
    let mut seen = String::new();
    let outcome = (|| -> Result<(), String> {
        let exe = std::env::var("SCTERM_EXE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("target")
                    .join("release")
                    .join("scterm.exe")
            });
        if !exe.is_file() {
            return Err(format!("未找到 {}，请先 cargo build --release", exe.display()));
        }

        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let sink: crate::term::conpty::FrameSink = Arc::new(move |frame: Vec<u8>| {
            let _ = tx.send(frame);
        });
        let command_line = format!("\"{}\" shell", exe.display());
        let pane = crate::term::conpty::Pane::spawn(
            1,
            &command_line,
            std::env::var("USERPROFILE").ok().as_deref(),
            100,
            30,
            sink,
        )
        .map_err(|e| format!("启动 shell 失败：{e}"))?;

        let script = std::env::temp_dir().join("scterm_script_smoke.sct");
        std::fs::write(&script, SCRIPT)
            .map_err(|e| format!("写入脚本失败：{e}"))?;

        expect_pane_text(&rx, &mut seen, ">", 10_000)?;
        pane.write_input(format!("run \"{}\"\r", script.display()).as_bytes())
            .map_err(|e| format!("写入输入失败：{e}"))?;

        for needle in [
            "step1=1",
            "pq=5 p=1",
            "if-defined",
            "not-exist",
            "loop=1",
            "loop=2",
            "loop=3",
            "sub=alpha-beta",
            "alpha-ok",
            "n=4",
        ] {
            expect_pane_text(&rx, &mut seen, needle, 15_000)
                .map_err(|e| format!("脚本输出缺少「{needle}」：{e}"))?;
        }
        if seen.contains("skipped") {
            return Err("goto :done 没有跳过标签前的命令".into());
        }

        thread::sleep(Duration::from_millis(500));
        pane.write_input(b"echo code=%errorlevel%\r")
            .map_err(|e| format!("写入输入失败：{e}"))?;
        expect_pane_text(&rx, &mut seen, "code=7", 10_000)?;

        // cmd 在命令行里执行 `set /a 变量=表达式` 会打印结果（脚本里不打印）。
        pane.write_input(b"set /a q=6*7\r")
            .map_err(|e| format!("写入输入失败：{e}"))?;
        expect_pane_text(&rx, &mut seen, "42", 10_000)?;

        // 逗号多段时 cmd 只打印最后一段的值。
        pane.write_input(b"set /a 111,222\r")
            .map_err(|e| format!("写入输入失败：{e}"))?;
        expect_pane_text(&rx, &mut seen, "222", 10_000)?;

        pane.write_input(b"exit 0\r")
            .map_err(|e| format!("写入输入失败：{e}"))?;
        let code = expect_pane_exit(&rx, &mut seen, 15_000)?;
        if code != 0 {
            return Err(format!("exit 0 的退出码应为 0，实际 {code}"));
        }
        Ok(())
    })();

    report.push_str(&seen);
    let status = match &outcome {
        Ok(()) => "通过".to_string(),
        Err(e) => format!("失败：{e}"),
    };
    report.push_str(&format!("\r\n结果：{status}\r\n"));
    let report_path = std::env::temp_dir().join("scterm_script_smoke.txt");
    let _ = std::fs::write(&report_path, &report);
    if let Err(e) = outcome {
        panic!("脚本冒烟失败：{e}（详见 {}）", report_path.display());
    }
}

/// 性能基准：shell 启动到首个提示符的时延，以及经 ConPTY 输出 10 万行的吞吐。
///
/// `cargo test --release zz_bench_probe -- --ignored --test-threads=1`
/// 报告写在 `%TEMP%\scterm_bench.txt`（本进程 FreeConsole 后标准输出不可用）。
#[test]
#[ignore]
fn zz_bench_probe() {
    use std::path::PathBuf;
    use std::sync::mpsc;

    let mut report = String::new();
    let exe = std::env::var("SCTERM_EXE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("target")
                .join("release")
                .join("scterm.exe")
        });
    if !exe.is_file() {
        let _ = std::fs::write(
            std::env::temp_dir().join("scterm_bench.txt"),
            format!("未找到 {}，请先 cargo build --release\n", exe.display()),
        );
        return;
    }

    // 1) 启动时延：进程创建到绘制出第一个提示符。
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let sink: crate::term::conpty::FrameSink = Arc::new(move |frame| {
        let _ = tx.send(frame);
    });
    let start = Instant::now();
    let pane = crate::term::conpty::Pane::spawn(
        1,
        &format!("\"{}\" shell", exe.display()),
        std::env::var("USERPROFILE").ok().as_deref(),
        80,
        24,
        sink,
    )
    .expect("启动 shell 失败");
    let mut first_prompt = None;
    let mut seen = String::new();
    let mut exited = None;
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(raw) => match decode_pane_frame(&raw) {
                Some((FrameType::Output, payload)) => {
                    if let Ok(data) = msg::PaneData::decode(&payload) {
                        seen.push_str(&String::from_utf8_lossy(&data.data));
                        if first_prompt.is_none() && seen.contains('>') {
                            first_prompt = Some(start.elapsed());
                            let _ = pane.write_input(b"exit 0\r");
                        }
                    }
                }
                Some((FrameType::PaneExited, payload)) => {
                    exited = msg::PaneExited::decode(&payload).ok();
                    break;
                }
                _ => {}
            },
            Err(_) => {}
        }
    }
    let startup_ms = first_prompt.map(|d| d.as_millis()).unwrap_or(0);
    let exit_code = exited.map(|e| e.exit_code).unwrap_or(-1);

    // 2) 吞吐：cmd.exe 连续输出 10 万行，统计从 spawn 到退出收到的字节数。
    let (tx2, rx2) = mpsc::channel::<Vec<u8>>();
    let sink2: crate::term::conpty::FrameSink = Arc::new(move |frame| {
        let _ = tx2.send(frame);
    });
    let start = Instant::now();
    let _pane2 = crate::term::conpty::Pane::spawn(
        2,
        "cmd.exe /d /c \"for /l %i in (1,1,100000) do @echo 0123456789\"",
        None,
        200,
        50,
        sink2,
    )
    .expect("启动 cmd 失败");
    let mut bytes = 0usize;
    let mut frames = 0usize;
    let mut finished = false;
    let deadline = Instant::now() + Duration::from_secs(180);
    while Instant::now() < deadline {
        match rx2.recv_timeout(Duration::from_millis(50)) {
            Ok(raw) => match decode_pane_frame(&raw) {
                Some((FrameType::Output, payload)) => {
                    if let Ok(data) = msg::PaneData::decode(&payload) {
                        bytes += data.data.len();
                        frames += 1;
                    }
                }
                Some((FrameType::PaneExited, _)) => {
                    finished = true;
                    break;
                }
                _ => {}
            },
            Err(_) => {}
        }
    }
    let elapsed = start.elapsed();
    let secs = elapsed.as_secs_f64().max(0.001);
    report.push_str(&format!(
        "shell 启动到首个提示符：{startup_ms} 毫秒（退出码 {exit_code}）\r\n\
         10 万行输出：{bytes} 字节，{frames} 帧，耗时 {:.3} 秒，{:.1} 行/秒，{:.2} MB/秒\r\n\
         完成：{finished}\r\n",
        secs,
        100_000.0 / secs,
        bytes as f64 / secs / (1024.0 * 1024.0)
    ));
    let path = std::env::temp_dir().join("scterm_bench.txt");
    let _ = std::fs::write(&path, &report);
    println!("{report}");
}

fn decode_pane_frame(raw: &[u8]) -> Option<(FrameType, Vec<u8>)> {
    if raw.len() < 12 {
        return None;
    }
    let (ty, _len) = proto::decode_header(&raw[..12]).ok()?;
    Some((ty, raw[12..].to_vec()))
}

fn expect_pane_text(
    rx: &std::sync::mpsc::Receiver<Vec<u8>>,
    seen: &mut String,
    needle: &str,
    timeout_ms: u64,
) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    loop {
        if seen.contains(needle) {
            return Ok(());
        }
        let remain = deadline.saturating_duration_since(Instant::now());
        if remain.is_zero() {
            return Err(format!("{timeout_ms} 毫秒内未看到「{needle}」"));
        }
        match rx.recv_timeout(remain.min(Duration::from_millis(200))) {
            Ok(raw) => match decode_pane_frame(&raw) {
                Some((FrameType::Output, payload)) => {
                    if let Ok(data) = msg::PaneData::decode(&payload) {
                        seen.push_str(&String::from_utf8_lossy(&data.data));
                    }
                }
                Some((FrameType::PaneExited, _)) => {
                    return Err("窗格在出现预期输出前就退出了".into());
                }
                _ => {}
            },
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                return Err("输出通道已关闭".into())
            }
        }
    }
}

fn expect_pane_exit(
    rx: &std::sync::mpsc::Receiver<Vec<u8>>,
    seen: &mut String,
    timeout_ms: u64,
) -> Result<i32, String> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    loop {
        let remain = deadline.saturating_duration_since(Instant::now());
        if remain.is_zero() {
            return Err("等待窗格退出超时".into());
        }
        match rx.recv_timeout(remain.min(Duration::from_millis(200))) {
            Ok(raw) => match decode_pane_frame(&raw) {
                Some((FrameType::Output, payload)) => {
                    if let Ok(data) = msg::PaneData::decode(&payload) {
                        seen.push_str(&String::from_utf8_lossy(&data.data));
                    }
                }
                Some((FrameType::PaneExited, payload)) => {
                    let exited = msg::PaneExited::decode(&payload)
                        .map_err(|e| format!("解析 PaneExited 失败：{e}"))?;
                    return Ok(exited.exit_code);
                }
                _ => {}
            },
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                return Err("输出通道已关闭".into())
            }
        }
    }
}

fn wait_until(timeout: Duration, mut probe: impl FnMut() -> bool) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if probe() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    Err("等待超时".into())
}

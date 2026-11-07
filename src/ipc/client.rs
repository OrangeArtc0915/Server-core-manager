//! 客户端：原始输入 + 重叠 I/O 管道 + 标签页/窗格 UI。

use std::ptr::null_mut;
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use crate::config::Config;
use crate::input::{decode_record, Record};
use crate::ipc::pipe::{self, PipeStream};
use crate::platform::console::{RawConsole, StdOut};
use crate::platform::{logging, version, win32};
use crate::proto::{self, caps, msg, FrameType};
use crate::ui::layout::LayoutNode;
use crate::ui::App;

/// 客户端启动选项（来自 `main` 的命令行解析）。
#[derive(Debug, Default, Clone)]
pub struct Options {
    /// `--layout` 的布局名或表达式。
    pub layout: Option<String>,
    /// `--quake`：启动后隐藏窗口，等待全局热键呼出。
    pub quake: bool,
}

pub fn run(options: Options) -> Result<(), String> {
    let config = Config::load();
    for warning in &config.warnings {
        logging::warn(warning);
    }
    // 布局在进入原始模式和拉起服务之前校验，坏参数不留下任何副作用。
    let layout = match options.layout.as_deref() {
        Some(value) => Some(resolve_layout(&config, value)?),
        None => None,
    };
    let session = if layout.is_none() && config.behavior.restore_session {
        crate::session::load()
    } else {
        None
    };
    let quake_config = config.quake.clone();
    let quake_mode = options.quake;

    let console = RawConsole::enter()?;

    // 字体改动只影响当前控制台窗口，失败时沿用 conhost 的设置。
    if let Err(e) = crate::platform::console::apply_font(
        config.render.font_face.as_deref(),
        config.render.font_size,
    ) {
        logging::warn(&e);
    }
    // 全屏绘制要求缓冲区 == 窗口，否则 conhost 会滚动窗口、画面「堆到最下面」。
    crate::platform::console::fit_buffer_to_window();
    let (cols, rows) = console.size();
    logging::info(&format!("客户端启动，终端尺寸 {cols}x{rows}"));

    let stream = ensure_server()?;

    // ---- 握手 ----
    let hello = msg::Hello {
        proto_ver: proto::PROTO_VERSION as u16,
        build: version::build_number(),
        caps: client_caps(&config),
        cols,
        rows,
        profile: config.default_profile.clone(),
    };
    stream.write_frame(FrameType::Hello, &hello.encode())?;

    loop {
        match stream.read_frame_with(5000)? {
            None => return Err("后台服务在握手阶段关闭了连接".into()),
            Some(frame) => match frame.ty {
                FrameType::HelloAck => {
                    let ack = msg::HelloAck::decode(&frame.payload)?;
                    logging::info(&format!(
                        "握手完成：服务端 build {}，协商能力 {}",
                        ack.build,
                        caps::describe(ack.caps)
                    ));
                    break;
                }
                FrameType::Error => {
                    let e = msg::ErrorMsg::decode(&frame.payload)?;
                    return Err(format!("后台服务拒绝连接：{}", e.message));
                }
                other => logging::warn(&format!("握手阶段忽略帧 {other:?}")),
            },
        }
    }

    // ---- 应用与 IO ----
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let app = Arc::new(Mutex::new({
        let mut app = if layout.is_none() && session.is_none() {
            App::new(config, cols as usize, rows as usize, tx.clone())
        } else {
            App::new_empty(config, cols as usize, rows as usize, tx.clone())
        };
        if let Some(layout) = &layout {
            app.new_tab_with_layout(layout);
        } else if let Some(session) = &session {
            app.restore_session(session);
        }
        // 会话为空 / 文件损坏 / 全部标签页失效时回到单标签页。
        if app.tabs.is_empty() {
            app.new_tab();
        }
        app.enable_profile_font();
        app
    }));

    let quake_enabled = quake_config.enabled || quake_mode;
    if quake_enabled {
        match crate::platform::quake::start(&quake_config.hotkey, quake_config.topmost) {
            Ok(()) => {
                logging::info(&format!(
                    "Quake 热键已注册：{}（置顶={}）",
                    quake_config.hotkey, quake_config.topmost
                ));
                if quake_mode {
                    crate::platform::quake::hide_console();
                }
            }
            Err(e) => {
                logging::warn(&e);
                lock(&app).set_status(format!("Quake 热键不可用：{e}"));
                // 注册失败时不隐藏启动，避免窗口找不回来。
            }
        }
    }

    let writer_stream = stream.clone();
    let writer = thread::spawn(move || {
        while let Ok(buf) = rx.recv() {
            if let Err(e) = writer_stream.write_all(&buf) {
                logging::warn(&format!("向后台服务写入帧失败：{e}"));
                break;
            }
        }
    });

    let exit_event = unsafe { win32::CreateEventW(null_mut(), 1, 0, null_mut()) };
    if exit_event.is_null() {
        return Err(format!("创建退出事件失败（错误码 {}）", win32::last_error()));
    }
    let event_value = exit_event as usize;

    let reader_stream = stream.clone();
    let tx_for_reader = tx.clone();
    let app_for_reader = app.clone();
    let reader = thread::spawn(move || {
        let mut last_paint: Option<Instant> = None;
        loop {
            match reader_stream.read_frame() {
                Ok(Some(frame)) => match frame.ty {
                    FrameType::Output => {
                        if let Ok(data) = msg::PaneData::decode(&frame.payload) {
                            let responses = {
                                let mut guard = lock(&app_for_reader);
                                guard.on_pane_output(data.pane_id, &data.data)
                            };
                            if !responses.is_empty() {
                                let reply = msg::PaneData {
                                    pane_id: data.pane_id,
                                    data: responses,
                                };
                                if tx_for_reader
                                    .send(proto::encode(FrameType::Input, &reply.encode()))
                                    .is_err()
                                {
                                    break;
                                }
                            }
                            if paint_throttled(&app_for_reader, &mut last_paint).is_err() {
                                break;
                            }
                        }
                    }
                    FrameType::PaneCreated => {
                        if let Ok(created) = msg::PaneCreated::decode(&frame.payload) {
                            lock(&app_for_reader).on_pane_created(created.pane_id, created.pid);
                            let _ = paint_throttled(&app_for_reader, &mut last_paint);
                        }
                    }
                    FrameType::PaneExited => {
                        if let Ok(exited) = msg::PaneExited::decode(&frame.payload) {
                            lock(&app_for_reader).on_pane_exited(exited.pane_id, exited.exit_code);
                            let _ = paint(&app_for_reader);
                        }
                    }
                    FrameType::Ping => {
                        if let Ok(token) = msg::Token::decode(&frame.payload) {
                            let _ = tx_for_reader
                                .send(proto::encode(FrameType::Pong, &token.encode()));
                        }
                    }
                    FrameType::Error => {
                        if let Ok(e) = msg::ErrorMsg::decode(&frame.payload) {
                            logging::error(&format!("服务端错误：{}", e.message));
                            lock(&app_for_reader)
                                .set_status(format!("服务端错误：{}", e.message));
                            let _ = paint(&app_for_reader);
                        }
                    }
                    other => logging::debug(&format!("客户端忽略帧 {other:?}")),
                },
                Ok(None) => {
                    logging::info("后台服务关闭了连接");
                    unsafe {
                        win32::SetEvent(event_value as win32::HANDLE);
                    }
                    break;
                }
                Err(e) => {
                    logging::warn(&format!("读取后台服务数据失败：{e}"));
                    unsafe {
                        win32::SetEvent(event_value as win32::HANDLE);
                    }
                    break;
                }
            }
        }
    });

    let _ = paint(&app);

    // ---- 主输入循环 ----
    let stdin_handle = console.stdin_handle() as usize;
    let normal_exit = loop {
        if lock(&app).quit {
            break true;
        }
        let handles = [stdin_handle as win32::HANDLE, event_value as win32::HANDLE];
        let r = unsafe { win32::WaitForMultipleObjects(2, handles.as_ptr(), 0, 250) };

        if r == win32::WAIT_OBJECT_0 + 1 {
            break true;
        }
        if r != win32::WAIT_OBJECT_0 && r != win32::WAIT_TIMEOUT {
            logging::warn(&format!("等待控制台输入失败（结果 {r}）"));
            break false;
        }

        if r == win32::WAIT_OBJECT_0 {
            let mut records = [win32::INPUT_RECORD::default(); 64];
            match console.read_records(&mut records) {
                Ok(count) => {
                    for rec in records.iter().take(count) {
                        match decode_record(rec) {
                            Some(Record::Key(ev)) => {
                                let bytes = lock(&app).on_key(&ev);
                                if !bytes.is_empty() {
                                    let data = msg::PaneData {
                                        pane_id: lock(&app).focused_pane_id(),
                                        data: bytes,
                                    };
                                    if tx
                                        .send(proto::encode(FrameType::Input, &data.encode()))
                                        .is_err()
                                    {
                                        break;
                                    }
                                }
                            }
                            Some(Record::Resize(buf_cols, buf_rows)) => {
                                // 注意：这个事件带的是「屏幕缓冲区」尺寸（conhost 常有
                                // 9001 行历史），不是可见窗口大小。整屏绘制必须按窗口来，
                                // 否则画布会变成 9001 行高、窗口被顶到最底部。
                                if logging::is_verbose() {
                                    logging::debug(&format!(
                                        "窗口尺寸事件：缓冲区 {buf_cols}x{buf_rows}，按可见窗口重算"
                                    ));
                                }
                                crate::platform::console::fit_buffer_to_window();
                                let (cols, rows) = console.size();
                                if cols > 0 && rows > 0 {
                                    lock(&app).on_resize(cols as usize, rows as usize);
                                }
                            }
                            Some(Record::Mouse(ev)) => {
                                if logging::is_verbose() {
                                    logging::debug(&format!(
                                        "鼠标：({}, {}) 按钮=0x{:04X} 滚轮={} 移动={}",
                                        ev.x, ev.y, ev.buttons, ev.wheel, ev.moved
                                    ));
                                }
                                if let Some((pane_id, bytes)) = lock(&app).on_mouse(&ev) {
                                    if !bytes.is_empty() {
                                        let data = msg::PaneData {
                                            pane_id,
                                            data: bytes,
                                        };
                                        if tx
                                            .send(proto::encode(FrameType::Input, &data.encode()))
                                            .is_err()
                                        {
                                            break;
                                        }
                                    }
                                }
                            }
                            None => {}
                        }
                    }
                }
                Err(e) => {
                    logging::warn(&format!("读取控制台输入失败（错误码 {e}）"));
                    break false;
                }
            }
        } else {
            // 超时：让状态提示自然过期
            lock(&app).tick();
        }

        if paint(&app).is_err() {
            break false;
        }
    };

    drop(tx);
    let _ = writer.join();
    if normal_exit {
        // 退出前保存会话；失败只记日志，不影响退出。
        let snapshot = {
            let guard = lock(&app);
            if guard.config.behavior.restore_session {
                Some(crate::session::Session::capture(&guard))
            } else {
                None
            }
        };
        if let Some(session) = snapshot {
            if let Err(e) = session.save(&crate::session::path()) {
                logging::warn(&format!("保存会话失败：{e}"));
            }
        }
        let _ = reader.join();
    }
    let _ = console_shutdown();
    unsafe {
        win32::CloseHandle(event_value as win32::HANDLE);
    }
    drop(stream);
    logging::info("客户端退出");
    Ok(())
}

/// 把 `--layout` 的值解析成布局树：先按 `[layouts]` 名称查找，否则当表达式。
fn resolve_layout(config: &Config, value: &str) -> Result<LayoutNode, String> {
    let named = config.layouts.iter().find(|(name, _)| name == value);
    let spec = named
        .map(|(_, spec)| spec.as_str())
        .unwrap_or(value);
    let node = LayoutNode::parse(spec).map_err(|e| format!("布局「{value}」无效：{e}"))?;
    for profile in node.profiles() {
        if config.profile(profile).is_none() {
            if named.is_none() && node.profiles().len() == 1 && profile == value {
                return Err(format!(
                    "未找到布局「{value}」：没有同名布局，也没有同名 profile"
                ));
            }
            return Err(format!(
                "布局「{value}」引用了不存在的 profile「{profile}」"
            ));
        }
    }
    Ok(node)
}

fn lock(app: &Arc<Mutex<App>>) -> MutexGuard<'_, App> {
    match app.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// 输出洪峰时限流重绘：最多每 16ms 画一次（主循环每 250ms 兜底刷新）。
fn paint_throttled(app: &Arc<Mutex<App>>, last: &mut Option<Instant>) -> Result<(), String> {
    let now = Instant::now();
    if let Some(previous) = *last {
        if now.duration_since(previous) < Duration::from_millis(16) {
            return Ok(());
        }
    }
    *last = Some(now);
    paint(app)
}

fn paint(app: &Arc<Mutex<App>>) -> Result<(), String> {
    let (bytes, title) = {
        let mut guard = lock(app);
        (guard.paint(), guard.take_title())
    };
    if !bytes.is_empty() {
        StdOut::stdout().write(&bytes)?;
    }
    if let Some(title) = title {
        let wide = win32::wide(&title);
        unsafe {
            win32::SetConsoleTitleW(wide.as_ptr());
        }
    }
    Ok(())
}

fn console_shutdown() -> Result<(), String> {
    StdOut::stdout().write(b"\x1b[0m\x1b[?25h\x1b[?7h")
}

fn client_caps(config: &Config) -> u32 {
    let build = version::build_number();
    let mut caps = caps::BRACKETED_PASTE;
    if config.render.truecolor != crate::config::TrueColorMode::Never {
        caps |= caps::TRUECOLOR;
    }
    if config.render.mouse && version::mouse_report_supported(build) {
        caps |= caps::MOUSE;
    } else if config.render.mouse {
        logging::warn(&format!(
            "系统 build {build} 低于 {}，ConPTY 鼠标上报存在缺陷，已关闭鼠标功能",
            version::CONPTY_MOUSE_FIX_BUILD
        ));
    }
    caps
}

/// 连接后台服务；不存在时自动拉起。
fn ensure_server() -> Result<Arc<PipeStream>, String> {
    let path = pipe::pipe_path()?;
    let mut spawned = false;
    let mut last_err = 0u32;

    for _ in 0..60 {
        match pipe::connect(&path) {
            Ok(s) => {
                logging::info("已连接到后台服务");
                return Ok(s);
            }
            Err(win32::ERROR_PIPE_BUSY) => {
                pipe::wait_server(&path, 2000);
            }
            Err(e) => {
                last_err = e;
                if !spawned {
                    spawn_server()?;
                    spawned = true;
                }
            }
        }
        thread::sleep(Duration::from_millis(50));
    }

    Err(format!(
        "无法连接到后台服务（最后错误码 {last_err}），请查看日志目录 {}",
        logging::log_dir().display()
    ))
}

fn spawn_server() -> Result<(), String> {
    use std::os::windows::process::CommandExt;

    let exe = std::env::current_exe().map_err(|e| format!("无法获取自身可执行文件路径：{e}"))?;
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("server").arg("--detached");
    if logging::is_verbose() {
        cmd.arg("--verbose");
    }
    cmd.creation_flags(win32::DETACHED_PROCESS | win32::CREATE_NEW_PROCESS_GROUP)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    cmd.spawn()
        .map_err(|e| format!("自动拉起后台服务失败：{e}"))?;
    logging::info("已自动拉起后台服务");
    Ok(())
}

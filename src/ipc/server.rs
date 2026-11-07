//! 后台守护进程：按用户 SID 隔离的命名管道服务，管理 ConPTY 窗格。

use std::collections::HashMap;
use std::ptr::null_mut;
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::config::Config;
use crate::ipc::pipe::{self, PipeStream};
use crate::platform::{logging, version, win32};
use crate::proto::{self, caps, msg, FrameType};
use crate::term::conpty::{FrameSink, Pane};

pub fn run() -> Result<(), String> {
    // 单实例：已有服务在跑时本实例直接退出。
    let mutex_name = win32::wide("Local\\scterm-server-mutex");
    let mutex = unsafe { win32::CreateMutexW(null_mut(), 1, mutex_name.as_ptr()) };
    if mutex.is_null() {
        return Err(format!(
            "创建服务互斥量失败（错误码 {}）",
            win32::last_error()
        ));
    }
    if unsafe { win32::GetLastError() } == win32::ERROR_ALREADY_EXISTS {
        logging::info("已有后台服务在运行，本实例退出");
        unsafe {
            win32::CloseHandle(mutex);
        }
        return Ok(());
    }

    let build = version::build_number();
    let path = pipe::pipe_path()?;
    let sec = pipe::security_for_current_user()?;
    let config = Config::load();
    for warning in &config.warnings {
        logging::warn(warning);
    }
    logging::info(&format!(
        "后台服务启动：管道 {path}，系统 build {build}，默认 profile {}（{}）",
        config.default_profile,
        config.default_profile_ref().command
    ));
    if !version::mouse_report_supported(build) {
        logging::warn(&format!(
            "系统 build {build} 低于 {}，ConPTY 鼠标上报存在已知缺陷，已自动关闭鼠标功能",
            version::CONPTY_MOUSE_FIX_BUILD
        ));
    }

    loop {
        let stream = match pipe::create_instance(&path, &sec) {
            Ok(s) => s,
            Err(e) => {
                logging::error(&e);
                thread::sleep(Duration::from_millis(500));
                continue;
            }
        };

        if let Err(e) = stream.accept() {
            logging::warn(&e);
            continue;
        }

        thread::spawn(move || {
            // 会话线程隔离：单个客户端的异常不影响后台服务和其他会话。
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                handle_client(stream)
            }));
            if result.is_err() {
                logging::error("客户端会话线程异常退出（已隔离，服务继续运行）");
            }
        });
    }
}

fn resolve_profile(name: &str) -> (String, Option<String>) {
    let config = Config::load();
    let profile = config
        .profile(name)
        .unwrap_or_else(|| config.default_profile_ref());
    // 外部 shell 集成：把脚本路径拼进命令行（失败不影响窗格启动）。
    let command = match crate::integration::ensure(&crate::integration::dir()) {
        Ok(assets) => crate::integration::decorate(profile, &assets),
        Err(e) => {
            logging::warn(&format!("外部 shell 集成未生效：{e}"));
            profile.command_line()
        }
    };
    (command, profile.expanded_cwd())
}

fn send_error(sink: &FrameSink, code: u16, message: &str) {
    logging::warn(&format!("返回错误帧：{message}"));
    let payload = msg::ErrorMsg {
        code,
        message: message.to_string(),
    }
    .encode();
    sink(proto::encode(FrameType::Error, &payload));
}

fn handle_client(stream: Arc<PipeStream>) {
    logging::info("客户端已连接");

    // 写线程：与读线程分离。管道使用重叠 I/O，同一句柄可安全并发读写。
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let writer_stream = stream.clone();
    let writer = thread::spawn(move || {
        while let Ok(buf) = rx.recv() {
            if let Err(e) = writer_stream.write_all(&buf) {
                logging::warn(&format!("向客户端写入帧失败：{e}"));
                break;
            }
        }
    });

    let sink: FrameSink = Arc::new(move |frame: Vec<u8>| {
        let _ = tx.send(frame);
    });

    let mut panes: HashMap<u32, Arc<Pane>> = HashMap::new();

    loop {
        match stream.read_frame() {
            Ok(Some(frame)) => {
                if !handle_frame(frame, &mut panes, &sink) {
                    break;
                }
            }
            Ok(None) => {
                logging::info("客户端断开连接");
                break;
            }
            Err(e) => {
                logging::warn(&format!("读取客户端数据失败：{e}"));
                break;
            }
        }
    }

    // 关闭窗格：Drop 释放伪控制台与句柄。
    panes.clear();
    drop(sink);
    let _ = writer.join();
    logging::info("会话结束");
}

fn handle_frame(
    frame: proto::Frame,
    panes: &mut HashMap<u32, Arc<Pane>>,
    sink: &FrameSink,
) -> bool {
    logging::debug(&format!(
        "收到帧 {:?}，{} 字节",
        frame.ty,
        frame.payload.len()
    ));
    match frame.ty {
        FrameType::Hello => match msg::Hello::decode(&frame.payload) {
            Ok(hello) => {
                let negotiated = hello.caps & caps::SERVER;
                logging::info(&format!(
                    "握手：客户端 build {}，终端 {}x{}，协商能力 {}",
                    hello.build,
                    hello.cols,
                    hello.rows,
                    caps::describe(negotiated)
                ));
                let ack = msg::HelloAck {
                    proto_ver: proto::PROTO_VERSION as u16,
                    build: version::build_number(),
                    caps: negotiated,
                    session_id: unsafe { win32::GetTickCount64() },
                };
                sink(proto::encode(FrameType::HelloAck, &ack.encode()));
            }
            Err(e) => {
                send_error(sink, msg::ERR_PROTOCOL, &format!("Hello 解析失败：{e}"));
                return false;
            }
        },
        FrameType::CreatePane => match msg::CreatePane::decode(&frame.payload) {
            Ok(req) => {
                if panes.contains_key(&req.pane_id) {
                    send_error(sink, msg::ERR_BAD_REQUEST, "窗格 ID 已存在");
                    return true;
                }
                let (command, cwd) = resolve_profile(&req.profile);
                match Pane::spawn(
                    req.pane_id,
                    &command,
                    cwd.as_deref(),
                    req.cols,
                    req.rows,
                    sink.clone(),
                ) {
                    Ok(pane) => {
                        let created = msg::PaneCreated {
                            pane_id: req.pane_id,
                            pid: pane.pid,
                        };
                        sink(proto::encode(FrameType::PaneCreated, &created.encode()));
                        logging::info(&format!(
                            "窗格 {} 已创建：{}，pid={}，{}x{}",
                            req.pane_id, command, pane.pid, req.cols, req.rows
                        ));
                        panes.insert(req.pane_id, Arc::new(pane));
                    }
                    Err(e) => send_error(sink, msg::ERR_PANE_CREATE, &e),
                }
            }
            Err(e) => send_error(sink, msg::ERR_PROTOCOL, &format!("CreatePane 解析失败：{e}")),
        },
        FrameType::Input => match msg::PaneData::decode(&frame.payload) {
            Ok(data) => match panes.get(&data.pane_id) {
                Some(pane) => {
                    if let Err(e) = pane.write_input(&data.data) {
                        logging::warn(&format!("窗格 {} 写入失败：{e}", data.pane_id));
                    }
                }
                None => logging::warn(&format!("收到未知窗格 {} 的输入", data.pane_id)),
            },
            Err(e) => send_error(sink, msg::ERR_PROTOCOL, &format!("Input 解析失败：{e}")),
        },
        FrameType::Resize => match msg::Resize::decode(&frame.payload) {
            Ok(req) => {
                if let Some(pane) = panes.get(&req.pane_id) {
                    pane.resize(req.cols, req.rows);
                    logging::debug(&format!(
                        "窗格 {} 尺寸调整为 {}x{}",
                        req.pane_id, req.cols, req.rows
                    ));
                }
            }
            Err(e) => send_error(sink, msg::ERR_PROTOCOL, &format!("Resize 解析失败：{e}")),
        },
        FrameType::ClosePane => {
            if let Ok(req) = msg::PaneId::decode(&frame.payload) {
                if panes.remove(&req.pane_id).is_some() {
                    logging::info(&format!("窗格 {} 已关闭", req.pane_id));
                }
            }
        }
        FrameType::Ping => {
            if let Ok(token) = msg::Token::decode(&frame.payload) {
                sink(proto::encode(FrameType::Pong, &token.encode()));
            }
        }
        other => logging::warn(&format!("服务端忽略未知帧 {other:?}")),
    }
    true
}

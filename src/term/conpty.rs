//! ConPTY 封装：创建伪控制台、启动子进程、双向数据泵。

use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::Arc;
use std::thread;

use crate::platform::win32::{self, HANDLE, HPCON};
use crate::proto::{self, msg, FrameType};

/// 帧输出回调：由一个后台泵线程调用，必须可跨线程且非阻塞。
pub type FrameSink = Arc<dyn Fn(Vec<u8>) + Send + Sync>;

/// 一个 ConPTY 窗格。持有伪控制台与输入写端；
/// 输出读端与子进程句柄由读取线程持有。
pub struct Pane {
    #[allow(dead_code)] // 供后续阶段（窗格树、事件流）使用
    pub id: u32,
    pub pid: u32,
    hpc: HPCON,
    input: HANDLE,
}

unsafe impl Send for Pane {}
unsafe impl Sync for Pane {}

impl Pane {
    /// 创建伪控制台并启动子进程，输出通过 `sink` 以帧形式转发。
    pub fn spawn(
        id: u32,
        command_line: &str,
        cwd: Option<&str>,
        cols: u16,
        rows: u16,
        sink: FrameSink,
    ) -> Result<Pane, String> {
        prepare_process_for_pseudo_console();
        unsafe {
            let mut in_read: HANDLE = null_mut();
            let mut in_write: HANDLE = null_mut();
            if win32::CreatePipe(&mut in_read, &mut in_write, null_mut(), 0) == 0 {
                return Err(format!(
                    "创建 PTY 输入管道失败（错误码 {}）",
                    win32::last_error()
                ));
            }

            let mut out_write: HANDLE = null_mut();
            let out_read = match create_overlapped_pipe(&mut out_write) {
                Ok(handle) => handle,
                Err(e) => {
                    win32::CloseHandle(in_read);
                    win32::CloseHandle(in_write);
                    return Err(e);
                }
            };

            let size = win32::COORD {
                X: cols as i16,
                Y: rows as i16,
            };
            let mut hpc: HPCON = null_mut();
            let hr = win32::CreatePseudoConsole(size, in_read, out_write, 0, &mut hpc);

            // 伪控制台建立后，本地不再需要这两个句柄。
            win32::CloseHandle(in_read);
            win32::CloseHandle(out_write);

            if hr < 0 {
                win32::CloseHandle(in_write);
                win32::CloseHandle(out_read);
                return Err(format!(
                    "CreatePseudoConsole 失败（HRESULT 0x{:08X}）：当前系统可能不支持 ConPTY",
                    hr as u32
                ));
            }

            match Self::start_process(id, command_line, cwd, hpc, in_write, out_read, sink) {
                Ok(pane) => Ok(pane),
                Err(e) => {
                    win32::ClosePseudoConsole(hpc);
                    win32::CloseHandle(in_write);
                    win32::CloseHandle(out_read);
                    Err(e)
                }
            }
        }
    }

    unsafe fn start_process(
        id: u32,
        command_line: &str,
        cwd: Option<&str>,
        hpc: HPCON,
        input: HANDLE,
        output: HANDLE,
        sink: FrameSink,
    ) -> Result<Pane, String> {
        let mut attr_size: usize = 0;
        win32::InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut attr_size);
        if attr_size == 0 {
            return Err(format!(
                "初始化线程属性列表失败（错误码 {}）",
                win32::last_error()
            ));
        }

        // u64 缓冲区保证指针对齐。
        let mut attr_buf = vec![0u64; (attr_size + 7) / 8];
        let attr = attr_buf.as_mut_ptr() as *mut c_void;
        if win32::InitializeProcThreadAttributeList(attr, 1, 0, &mut attr_size) == 0 {
            return Err(format!(
                "初始化线程属性列表失败（错误码 {}）",
                win32::last_error()
            ));
        }

        // 注意：lpValue 直接传 HPCON 本身（官方 EchoCon 示例的写法），
        // 传 &HPCON 会让内核拿到错误的句柄值，子进程将无法挂到伪控制台。
        let updated = win32::UpdateProcThreadAttribute(
            attr,
            0,
            win32::PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            hpc,
            std::mem::size_of::<HPCON>(),
            null_mut(),
            null_mut(),
        );
        if updated == 0 {
            let err = win32::last_error();
            win32::DeleteProcThreadAttributeList(attr);
            return Err(format!("绑定伪控制台属性失败（错误码 {err}）"));
        }

        let mut si: win32::STARTUPINFOEXW = std::mem::zeroed();
        si.StartupInfo.cb = std::mem::size_of::<win32::STARTUPINFOEXW>() as u32;
        si.lpAttributeList = attr;

        let mut cmd: Vec<u16> = command_line.encode_utf16().chain(std::iter::once(0)).collect();
        let cwd_wide = cwd.map(win32::wide);
        let cwd_ptr = cwd_wide
            .as_ref()
            .map(|w| w.as_ptr())
            .unwrap_or(std::ptr::null());
        let mut pi: win32::PROCESS_INFORMATION = std::mem::zeroed();
        let created = win32::CreateProcessW(
            null_mut(),
            cmd.as_mut_ptr(),
            null_mut(),
            null_mut(),
            0,
            win32::EXTENDED_STARTUPINFO_PRESENT,
            null_mut(),
            cwd_ptr,
            &si.StartupInfo,
            &mut pi,
        );
        win32::DeleteProcThreadAttributeList(attr);

        if created == 0 {
            return Err(format!(
                "启动子进程失败（错误码 {}）：{command_line}",
                win32::last_error()
            ));
        }
        win32::CloseHandle(pi.hThread);

        let pid = pi.dwProcessId;
        let process = pi.hProcess as usize;
        let output = output as usize;
        let sink_for_reader = sink.clone();
        thread::spawn(move || {
            pump_output(
                id,
                output as HANDLE,
                process as HANDLE,
                sink_for_reader,
            );
        });

        Ok(Pane {
            id,
            pid,
            hpc,
            input,
        })
    }

    pub fn write_input(&self, data: &[u8]) -> Result<(), String> {
        let mut rest = data;
        while !rest.is_empty() {
            let mut written = 0u32;
            let ok = unsafe {
                win32::WriteFile(
                    self.input,
                    rest.as_ptr() as *const c_void,
                    rest.len() as u32,
                    &mut written,
                    null_mut(),
                )
            };
            if ok == 0 {
                return Err(format!("写入 PTY 失败（错误码 {}）", win32::last_error()));
            }
            if written == 0 {
                return Err("写入 PTY 返回 0 字节".into());
            }
            rest = &rest[written as usize..];
        }
        Ok(())
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        let size = win32::COORD {
            X: cols.max(1) as i16,
            Y: rows.max(1) as i16,
        };
        unsafe {
            win32::ResizePseudoConsole(self.hpc, size);
        }
    }
}

impl Drop for Pane {
    fn drop(&mut self) {
        unsafe {
            win32::ClosePseudoConsole(self.hpc);
            win32::CloseHandle(self.input);
        }
    }
}

/// 让当前进程满足创建伪控制台的前提条件。
///
/// 两个条件缺一不可，否则子进程会继承父进程的控制台/句柄而不挂到伪控制台
/// （表现为 CreateProcess 成功但读不到任何输出）：
/// 1. 父进程不能持有控制台 —— `FreeConsole`；
/// 2. 父进程的标准句柄必须为空 —— 分离启动时 stdio 会绑定到 NUL 设备，
///    子进程会继承这些句柄，需要用 `SetStdHandle(NULL)` 清空。
fn prepare_process_for_pseudo_console() {
    unsafe {
        win32::FreeConsole();
        win32::SetStdHandle(win32::STD_INPUT_HANDLE, null_mut());
        win32::SetStdHandle(win32::STD_OUTPUT_HANDLE, null_mut());
        win32::SetStdHandle(win32::STD_ERROR_HANDLE, null_mut());
    }
}

/// 创建 ConPTY 输出管道：读端是重叠 I/O 的命名管道，写端交给伪控制台。
///
/// 用重叠 I/O 的原因是：客户端进程退出后，本机 ConPTY 并不会关闭输出管道，
/// 同步 `ReadFile` 会永远阻塞。重叠读可以把「管道有数据」和「进程已退出」
/// 放进同一个 `WaitForMultipleObjects`，从而可靠地结束输出泵并发 PaneExited。
fn create_overlapped_pipe(write_out: &mut HANDLE) -> Result<HANDLE, String> {
    static SEQ: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let name = format!(
        "\\\\.\\pipe\\scterm-conpty-{}-{seq}",
        std::process::id()
    );
    let name_w = win32::wide(&name);
    unsafe {
        let read = win32::CreateNamedPipeW(
            name_w.as_ptr(),
            win32::PIPE_ACCESS_INBOUND | win32::FILE_FLAG_OVERLAPPED,
            win32::PIPE_TYPE_BYTE | win32::PIPE_READMODE_BYTE | win32::PIPE_WAIT,
            1,
            0,
            64 * 1024,
            0,
            null_mut(),
        );
        if read.is_null() || read == win32::INVALID_HANDLE_VALUE {
            return Err(format!(
                "创建 PTY 输出管道失败（错误码 {}）",
                win32::last_error()
            ));
        }
        let write = win32::CreateFileW(
            name_w.as_ptr(),
            win32::GENERIC_WRITE,
            0,
            null_mut(),
            win32::OPEN_EXISTING,
            0,
            null_mut(),
        );
        if write.is_null() || write == win32::INVALID_HANDLE_VALUE {
            let err = win32::last_error();
            win32::CloseHandle(read);
            return Err(format!("连接 PTY 输出管道失败（错误码 {err}）"));
        }
        *write_out = write;
        Ok(read)
    }
}

fn emit_output(id: u32, sink: &FrameSink, data: &[u8]) {
    let payload = msg::PaneData {
        pane_id: id,
        data: data.to_vec(),
    }
    .encode();
    sink(proto::encode(FrameType::Output, &payload));
}

/// 读取线程：把 PTY 输出转发为 Output 帧，退出时补发 PaneExited。
fn pump_output(id: u32, output: HANDLE, process: HANDLE, sink: FrameSink) {
    let event = unsafe { win32::CreateEventW(null_mut(), 1, 0, null_mut()) };
    let mut buf = vec![0u8; 8192];
    let mut exited = false;

    'pump: loop {
        let mut ov: win32::OVERLAPPED = win32::OVERLAPPED::default();
        ov.hEvent = event;
        let mut read = 0u32;
        let ok = unsafe {
            win32::ReadFile(
                output,
                buf.as_mut_ptr() as *mut c_void,
                buf.len() as u32,
                &mut read,
                &mut ov as *mut win32::OVERLAPPED as *mut c_void,
            )
        };
        if ok != 0 {
            if read == 0 {
                break;
            }
            emit_output(id, &sink, &buf[..read as usize]);
            continue;
        }
        if win32::last_error() != win32::ERROR_IO_PENDING {
            break;
        }

        // 等待这一次重叠读完成；进程退出后改用 300ms 超时排空剩余数据。
        loop {
            let handles = [event, process];
            let count = if exited { 1 } else { 2 };
            let timeout = if exited { 300 } else { win32::INFINITE };
            let result = unsafe {
                win32::WaitForMultipleObjects(count, handles.as_ptr(), 0, timeout)
            };
            if result == win32::WAIT_OBJECT_0 {
                let mut transferred = 0u32;
                let got = unsafe {
                    win32::GetOverlappedResult(output, &ov, &mut transferred, 0)
                };
                if got == 0 || transferred == 0 {
                    break 'pump;
                }
                emit_output(id, &sink, &buf[..transferred as usize]);
                continue 'pump;
            }
            if result == win32::WAIT_OBJECT_0 + 1 {
                exited = true;
                continue;
            }
            // 进程已退出且 300ms 内没有新数据：排空结束。
            unsafe {
                win32::CancelIoEx(output, &ov);
                let mut transferred = 0u32;
                win32::GetOverlappedResult(output, &ov, &mut transferred, 1);
            }
            break 'pump;
        }
    }

    unsafe {
        win32::CloseHandle(event);
        // 3 秒内未退出则强制结束，避免残留进程树。
        if win32::WaitForSingleObject(process, 3000) == win32::WAIT_TIMEOUT {
            win32::TerminateProcess(process, 1);
            win32::WaitForSingleObject(process, 1000);
        }
        let mut code = 0u32;
        win32::GetExitCodeProcess(process, &mut code);
        let payload = msg::PaneExited {
            pane_id: id,
            exit_code: code as i32,
        }
        .encode();
        sink(proto::encode(FrameType::PaneExited, &payload));
        win32::CloseHandle(output);
        win32::CloseHandle(process);
    }
}

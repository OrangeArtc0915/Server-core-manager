//! 命名管道：按用户 SID 建立 ACL、重叠 I/O 读写、帧收发。
//!
//! 管道句柄必须使用 `FILE_FLAG_OVERLAPPED`：同步句柄无法可靠地
//! 「等待可读」，且跨线程并发读写会被 I/O 管理器串行化导致互锁。

use std::ffi::c_void;
use std::ptr::null_mut;
use std::sync::Arc;

use crate::platform::win32::{self, HANDLE};
use crate::proto::{self, Frame, FrameType};

/// 持有安全描述符的安全属性，Drop 时释放描述符内存。
pub struct PipeSecurity {
    sa: win32::SECURITY_ATTRIBUTES,
    sd: *mut c_void,
}

unsafe impl Send for PipeSecurity {}

impl Drop for PipeSecurity {
    fn drop(&mut self) {
        if !self.sd.is_null() {
            unsafe {
                win32::LocalFree(self.sd);
            }
        }
    }
}

/// 当前登录用户的 SID 字符串（形如 S-1-5-21-...）。
pub fn current_user_sid() -> Result<String, String> {
    unsafe {
        let mut token: HANDLE = null_mut();
        if win32::OpenProcessToken(win32::GetCurrentProcess(), win32::TOKEN_QUERY, &mut token) == 0 {
            return Err(format!(
                "获取当前进程令牌失败（错误码 {}）",
                win32::last_error()
            ));
        }

        let mut len: u32 = 0;
        win32::GetTokenInformation(token, win32::TOKEN_USER_CLASS, null_mut(), 0, &mut len);
        if len == 0 {
            win32::CloseHandle(token);
            return Err("无法获取令牌用户信息长度".into());
        }

        // u64 缓冲区保证指针对齐。
        let mut buf = vec![0u64; (len as usize + 7) / 8];
        if win32::GetTokenInformation(
            token,
            win32::TOKEN_USER_CLASS,
            buf.as_mut_ptr() as *mut c_void,
            len,
            &mut len,
        ) == 0
        {
            let err = win32::last_error();
            win32::CloseHandle(token);
            return Err(format!("读取令牌用户信息失败（错误码 {err}）"));
        }
        win32::CloseHandle(token);

        // TOKEN_USER 首字段是 SID_AND_ATTRIBUTES { Sid, Attributes }
        let sid_ptr = *(buf.as_ptr() as *const *mut c_void);
        let mut sid_str: *mut u16 = null_mut();
        if win32::ConvertSidToStringSidW(sid_ptr, &mut sid_str) == 0 {
            return Err(format!("SID 转字符串失败（错误码 {}）", win32::last_error()));
        }
        let result = win32::from_wide_ptr(sid_str);
        win32::LocalFree(sid_str as win32::HLOCAL);
        Ok(result)
    }
}

pub fn pipe_path() -> Result<String, String> {
    let sid = current_user_sid()?;
    Ok(format!(r"\\.\pipe\scterm-{sid}"))
}

/// 构造仅允许当前用户与 SYSTEM 访问的 DACL。
pub fn security_for_current_user() -> Result<PipeSecurity, String> {
    let sid = current_user_sid()?;
    let sddl = format!("D:(A;;GA;;;{sid})(A;;GA;;;SY)");
    let wide = win32::wide(&sddl);
    unsafe {
        let mut sd: *mut c_void = null_mut();
        let mut size: u32 = 0;
        if win32::ConvertStringSecurityDescriptorToSecurityDescriptorW(
            wide.as_ptr(),
            win32::SDDL_REVISION_1,
            &mut sd,
            &mut size,
        ) == 0
        {
            return Err(format!(
                "构造管道安全描述符失败（错误码 {}）",
                win32::last_error()
            ));
        }
        Ok(PipeSecurity {
            sa: win32::SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<win32::SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: sd,
                bInheritHandle: 0,
            },
            sd,
        })
    }
}

/// 一个已建立的管道连接（重叠 I/O）。
pub struct PipeStream {
    handle: HANDLE,
    read_event: HANDLE,
    write_event: HANDLE,
    accept_event: HANDLE,
}

// 句柄是内核对象引用，读写各自使用独立事件，可跨线程使用。
unsafe impl Send for PipeStream {}
unsafe impl Sync for PipeStream {}

impl Drop for PipeStream {
    fn drop(&mut self) {
        unsafe {
            win32::CancelIoEx(self.handle, null_mut());
            win32::CloseHandle(self.read_event);
            win32::CloseHandle(self.write_event);
            win32::CloseHandle(self.accept_event);
            win32::CloseHandle(self.handle);
        }
    }
}

impl PipeStream {
    fn new(handle: HANDLE) -> Result<PipeStream, String> {
        unsafe {
            let read_event = win32::CreateEventW(null_mut(), 1, 0, null_mut());
            let write_event = win32::CreateEventW(null_mut(), 1, 0, null_mut());
            let accept_event = win32::CreateEventW(null_mut(), 1, 0, null_mut());
            if read_event.is_null() || write_event.is_null() || accept_event.is_null() {
                let err = win32::last_error();
                win32::CloseHandle(handle);
                return Err(format!("创建管道事件失败（错误码 {err}）"));
            }
            Ok(PipeStream {
                handle,
                read_event,
                write_event,
                accept_event,
            })
        }
    }

    /// 阻塞等待客户端连接（服务端实例）。
    pub fn accept(&self) -> Result<(), String> {
        unsafe {
            let mut ov = win32::OVERLAPPED {
                hEvent: self.accept_event,
                ..Default::default()
            };
            let ok = win32::ConnectNamedPipe(self.handle, &mut ov as *mut _ as *mut c_void);
            if ok != 0 {
                return Ok(());
            }
            let err = win32::GetLastError();
            if err == win32::ERROR_PIPE_CONNECTED {
                return Ok(());
            }
            if err != win32::ERROR_IO_PENDING {
                return Err(format!("等待客户端连接失败（错误码 {err}）"));
            }
            if win32::WaitForSingleObject(self.accept_event, win32::INFINITE) != win32::WAIT_OBJECT_0 {
                return Err("等待客户端连接事件失败".into());
            }
            let mut transferred = 0u32;
            if win32::GetOverlappedResult(self.handle, &ov, &mut transferred, 0) == 0 {
                let err = win32::GetLastError();
                if err != win32::ERROR_PIPE_CONNECTED {
                    return Err(format!("接受连接失败（错误码 {err}）"));
                }
            }
            Ok(())
        }
    }

    /// 读一段数据，返回读取字节数；0 表示对端已关闭。
    pub fn read_some(&self, buf: &mut [u8], timeout_ms: u32) -> Result<usize, String> {
        unsafe {
            win32::ResetEvent(self.read_event);
            let mut ov = win32::OVERLAPPED {
                hEvent: self.read_event,
                ..Default::default()
            };
            let mut read = 0u32;
            let ok = win32::ReadFile(
                self.handle,
                buf.as_mut_ptr() as *mut c_void,
                buf.len() as u32,
                &mut read,
                &mut ov as *mut _ as *mut c_void,
            );
            if ok == 0 {
                let err = win32::GetLastError();
                if is_closed(err) {
                    return Ok(0);
                }
                if err != win32::ERROR_IO_PENDING {
                    return Err(format!("读取管道失败（错误码 {err}）"));
                }
                let waited = win32::WaitForSingleObject(self.read_event, timeout_ms);
                if waited != win32::WAIT_OBJECT_0 {
                    win32::CancelIoEx(self.handle, &ov);
                    let mut ignored = 0u32;
                    win32::GetOverlappedResult(self.handle, &ov, &mut ignored, 1);
                    return Err(format!("读取管道超时（{timeout_ms} 毫秒）"));
                }
                let mut transferred = 0u32;
                if win32::GetOverlappedResult(self.handle, &ov, &mut transferred, 0) == 0 {
                    let err = win32::GetLastError();
                    if is_closed(err) {
                        return Ok(0);
                    }
                    return Err(format!("读取管道失败（错误码 {err}）"));
                }
                read = transferred;
            }
            Ok(read as usize)
        }
    }

    pub fn write_all(&self, data: &[u8]) -> Result<(), String> {
        let mut rest = data;
        while !rest.is_empty() {
            let written = self.write_some(rest)?;
            if written == 0 {
                return Err("写入管道返回 0 字节".into());
            }
            rest = &rest[written..];
        }
        Ok(())
    }

    fn write_some(&self, data: &[u8]) -> Result<usize, String> {
        unsafe {
            win32::ResetEvent(self.write_event);
            let mut ov = win32::OVERLAPPED {
                hEvent: self.write_event,
                ..Default::default()
            };
            let mut written = 0u32;
            let ok = win32::WriteFile(
                self.handle,
                data.as_ptr() as *const c_void,
                data.len() as u32,
                &mut written,
                &mut ov as *mut _ as *mut c_void,
            );
            if ok == 0 {
                let err = win32::GetLastError();
                if err != win32::ERROR_IO_PENDING {
                    return Err(format!("写入管道失败（错误码 {err}）"));
                }
                if win32::WaitForSingleObject(self.write_event, win32::INFINITE) != win32::WAIT_OBJECT_0 {
                    return Err("等待写入完成失败".into());
                }
                let mut transferred = 0u32;
                if win32::GetOverlappedResult(self.handle, &ov, &mut transferred, 0) == 0 {
                    let err = win32::GetLastError();
                    return Err(format!("写入管道失败（错误码 {err}）"));
                }
                written = transferred;
            }
            Ok(written as usize)
        }
    }

    /// 读取一帧。`timeout_ms` 为 `win32::INFINITE` 表示一直等待。
    /// 返回 `Ok(None)` 表示对端正常关闭。
    pub fn read_frame_with(&self, timeout_ms: u32) -> Result<Option<Frame>, String> {
        let mut header = [0u8; proto::HEADER_LEN];
        let mut filled = 0usize;
        while filled < header.len() {
            let n = self.read_some(&mut header[filled..], timeout_ms)?;
            if n == 0 {
                return if filled == 0 {
                    Ok(None)
                } else {
                    Err("连接在帧头中途关闭".into())
                };
            }
            filled += n;
        }

        let (ty, len) = proto::decode_header(&header)?;
        let mut payload = vec![0u8; len];
        let mut got = 0usize;
        while got < len {
            let n = self.read_some(&mut payload[got..], timeout_ms)?;
            if n == 0 {
                return Err("连接在帧负载中途关闭".into());
            }
            got += n;
        }
        Ok(Some(Frame { ty, payload }))
    }

    pub fn read_frame(&self) -> Result<Option<Frame>, String> {
        self.read_frame_with(win32::INFINITE)
    }

    pub fn write_frame(&self, ty: FrameType, payload: &[u8]) -> Result<(), String> {
        self.write_all(&proto::encode(ty, payload))
    }
}

fn is_closed(err: u32) -> bool {
    err == win32::ERROR_BROKEN_PIPE
        || err == win32::ERROR_PIPE_NOT_CONNECTED
        || err == win32::ERROR_HANDLE_EOF
        || err == win32::ERROR_OPERATION_ABORTED
}

/// 创建一个管道服务端实例（尚未连接）。每个实例对应一个客户端。
pub fn create_instance(path: &str, sec: &PipeSecurity) -> Result<Arc<PipeStream>, String> {
    let name = win32::wide(path);
    let handle = unsafe {
        win32::CreateNamedPipeW(
            name.as_ptr(),
            win32::PIPE_ACCESS_DUPLEX | win32::FILE_FLAG_OVERLAPPED,
            win32::PIPE_TYPE_BYTE
                | win32::PIPE_READMODE_BYTE
                | win32::PIPE_WAIT
                | win32::PIPE_REJECT_REMOTE_CLIENTS,
            win32::PIPE_UNLIMITED_INSTANCES,
            64 * 1024,
            64 * 1024,
            0,
            &sec.sa,
        )
    };
    if handle == win32::INVALID_HANDLE_VALUE {
        return Err(format!(
            "创建命名管道失败（错误码 {}）",
            win32::last_error()
        ));
    }
    Ok(Arc::new(PipeStream::new(handle)?))
}

/// 作为客户端连接管道，返回 Win32 错误码以便上层区分「服务未启动」。
pub fn connect(path: &str) -> Result<Arc<PipeStream>, u32> {
    let name = win32::wide(path);
    let handle = unsafe {
        win32::CreateFileW(
            name.as_ptr(),
            win32::GENERIC_READ | win32::GENERIC_WRITE,
            0,
            null_mut(),
            win32::OPEN_EXISTING,
            win32::FILE_FLAG_OVERLAPPED,
            null_mut(),
        )
    };
    if handle == win32::INVALID_HANDLE_VALUE {
        return Err(unsafe { win32::GetLastError() });
    }
    PipeStream::new(handle).map(Arc::new).map_err(|e| {
        let _ = e;
        win32::ERROR_FILE_NOT_FOUND
    })
}

pub fn wait_server(path: &str, ms: u32) -> bool {
    let name = win32::wide(path);
    unsafe { win32::WaitNamedPipeW(name.as_ptr(), ms) != 0 }
}

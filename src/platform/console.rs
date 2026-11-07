//! 控制台模式管理：进入原始输入 + VT 输出，退出时恢复。

use std::ffi::c_void;

use super::win32::{self, HANDLE};

/// 标准输出的轻量句柄包装，可跨线程写入。
#[derive(Clone, Copy)]
pub struct StdOut(HANDLE);

// 句柄仅作为内核对象引用传递，跨线程使用安全。
unsafe impl Send for StdOut {}

impl StdOut {
    pub fn stdout() -> Self {
        StdOut(unsafe { win32::GetStdHandle(win32::STD_OUTPUT_HANDLE) })
    }

    pub fn write(&self, data: &[u8]) -> Result<(), String> {
        let h = self.0;
        if h.is_null() || h == win32::INVALID_HANDLE_VALUE {
            return Err("标准输出句柄不可用".into());
        }
        write_all(h, data).map_err(|e| format!("写入标准输出失败（错误码 {e}）"))
    }
}

/// 读取当前控制台窗口尺寸（列, 行）。
pub fn console_size(h: HANDLE) -> (u16, u16) {
    unsafe {
        let mut info = win32::CONSOLE_SCREEN_BUFFER_INFO::default();
        if win32::GetConsoleScreenBufferInfo(h, &mut info) == 0 {
            return (80, 24);
        }
        let cols = (info.srWindow.Right - info.srWindow.Left + 1).max(1) as u16;
        let rows = (info.srWindow.Bottom - info.srWindow.Top + 1).max(1) as u16;
        (cols, rows)
    }
}

/// 把控制台缓冲区固定成窗口大小。
///
/// 客户端用绝对坐标整屏绘制；若缓冲区比窗口高（conhost 默认有滚动历史），
/// 光标一旦落到窗口外，conhost 会滚动窗口跟随光标，画面就会「堆到最下面」。
/// 缓冲区与窗口同尺寸后，任何绝对坐标都落在可见区域内。
pub fn fit_buffer_to_window() {
    unsafe {
        let h = win32::GetStdHandle(win32::STD_OUTPUT_HANDLE);
        if h.is_null() || h == win32::INVALID_HANDLE_VALUE {
            return;
        }
        let mut info = win32::CONSOLE_SCREEN_BUFFER_INFO::default();
        if win32::GetConsoleScreenBufferInfo(h, &mut info) == 0 {
            return;
        }
        let cols = info.srWindow.Right - info.srWindow.Left + 1;
        let rows = info.srWindow.Bottom - info.srWindow.Top + 1;
        if cols <= 0 || rows <= 0 {
            return;
        }
        if info.dwSize.X == cols && info.dwSize.Y == rows && info.srWindow.Top == 0 {
            return;
        }
        // 收缩缓冲区前必须先把窗口移到左上角，否则调用会失败。
        let window = win32::SMALL_RECT {
            Left: 0,
            Top: 0,
            Right: cols - 1,
            Bottom: rows - 1,
        };
        win32::SetConsoleWindowInfo(h, 1, &window);
        let size = win32::COORD { X: cols, Y: rows };
        if win32::SetConsoleScreenBufferSize(h, size) == 0 {
            super::logging::warn(&format!(
                "无法把控制台缓冲区调整为窗口大小（错误码 {}），全屏刷新可能错位",
                win32::last_error()
            ));
        }
        win32::SetConsoleWindowInfo(h, 1, &window);
    }
}

/// 运行时开关鼠标输入（设置面板切换「鼠标上报」时用）。
pub fn set_mouse_enabled(enabled: bool) {
    unsafe {
        let h = win32::GetStdHandle(win32::STD_INPUT_HANDLE);
        if h.is_null() || h == win32::INVALID_HANDLE_VALUE {
            return;
        }
        let mut mode = 0u32;
        if win32::GetConsoleMode(h, &mut mode) == 0 {
            return;
        }
        let next = if enabled {
            mode | win32::ENABLE_MOUSE_INPUT
        } else {
            mode & !win32::ENABLE_MOUSE_INPUT
        };
        if next != mode {
            win32::SetConsoleMode(h, next);
        }
    }
}

/// 应用配置里的控制台字体（字号 / 字体名）。
///
/// 只能改「当前控制台窗口」的字体，且必须系统里存在该字体；
/// Server Core 上可用字体有限，失败时返回错误由调用方记录警告。
pub fn apply_font(face: Option<&str>, size: Option<u16>) -> Result<(), String> {
    if face.is_none() && size.is_none() {
        return Ok(());
    }
    unsafe {
        let handle = win32::GetStdHandle(win32::STD_OUTPUT_HANDLE);
        let mut info = win32::CONSOLE_FONT_INFOEX::default();
        if win32::GetCurrentConsoleFontEx(handle, 0, &mut info) == 0 {
            info = win32::CONSOLE_FONT_INFOEX::default();
            info.FontFamily = 54; // FF_MODERN | TMPF_FIXED_PITCH
        }
        if let Some(face) = face {
            info.FaceName = [0; 32];
            for (index, unit) in face.encode_utf16().take(31).enumerate() {
                info.FaceName[index] = unit;
            }
        }
        if let Some(size) = size {
            info.dwFontSize = win32::COORD {
                X: 0,
                Y: size as i16,
            };
        }
        if win32::SetCurrentConsoleFontEx(handle, 0, &info) == 0 {
            return Err(format!(
                "设置控制台字体失败（错误码 {}），已沿用当前字体",
                win32::last_error()
            ));
        }
    }
    Ok(())
}

pub struct RawConsole {
    stdin: HANDLE,
    stdout: HANDLE,
    saved_in: u32,
    saved_out: u32,
    active: bool,
}

impl RawConsole {
    /// 进入原始输入模式：关闭行缓冲/回显/行处理，开启 VT 输入解析与 VT 输出。
    pub fn enter() -> Result<Self, String> {
        unsafe {
            let stdin = win32::GetStdHandle(win32::STD_INPUT_HANDLE);
            let stdout = win32::GetStdHandle(win32::STD_OUTPUT_HANDLE);
            if stdin.is_null() || stdin == win32::INVALID_HANDLE_VALUE {
                return Err("无法获取标准输入句柄，请在真实控制台中运行 scterm".into());
            }
            if stdout.is_null() || stdout == win32::INVALID_HANDLE_VALUE {
                return Err("无法获取标准输出句柄，请在真实控制台中运行 scterm".into());
            }

            win32::SetConsoleCP(65001);
            win32::SetConsoleOutputCP(65001);

            let mut saved_in = 0u32;
            if win32::GetConsoleMode(stdin, &mut saved_in) == 0 {
                return Err(format!(
                    "无法读取控制台输入模式（错误码 {}），请在真实控制台中运行 scterm",
                    win32::last_error()
                ));
            }
            let mut saved_out = 0u32;
            win32::GetConsoleMode(stdout, &mut saved_out);

            // 原始输入：关闭行缓冲/回显/行处理（Ctrl+C 作为键事件交给子进程），
            // 打开窗口事件与鼠标事件；关闭 QuickEdit，否则鼠标会被控制台拿去选区。
            let raw_in =
                win32::ENABLE_EXTENDED_FLAGS | win32::ENABLE_WINDOW_INPUT | win32::ENABLE_MOUSE_INPUT;
            if win32::SetConsoleMode(stdin, raw_in) == 0 {
                return Err(format!(
                    "无法进入原始输入模式（错误码 {}），请在真实控制台中运行 scterm",
                    win32::last_error()
                ));
            }
            // 记录生效后的模式，便于排查「鼠标收不到事件」这类环境问题。
            let mut actual_in = 0u32;
            win32::GetConsoleMode(stdin, &mut actual_in);
            super::logging::info(&format!(
                "控制台输入模式：0x{actual_in:04X} 鼠标={}",
                actual_in & win32::ENABLE_MOUSE_INPUT != 0
            ));

            let raw_out = saved_out | win32::ENABLE_PROCESSED_OUTPUT | win32::ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            if win32::SetConsoleMode(stdout, raw_out) == 0 {
                win32::SetConsoleMode(stdin, saved_in);
                return Err(format!(
                    "当前控制台不支持虚拟终端输出（错误码 {}），需要 Windows 10 及以上",
                    win32::last_error()
                ));
            }

            Ok(RawConsole {
                stdin,
                stdout,
                saved_in,
                saved_out,
                active: true,
            })
        }
    }

    pub fn stdin_handle(&self) -> HANDLE {
        self.stdin
    }

    pub fn size(&self) -> (u16, u16) {
        console_size(self.stdout)
    }

    /// 读取控制台输入记录（键事件 / 窗口尺寸事件）。
    pub fn read_records(&self, buf: &mut [win32::INPUT_RECORD]) -> Result<usize, u32> {
        let mut n = 0u32;
        let ok = unsafe {
            win32::ReadConsoleInputW(self.stdin, buf.as_mut_ptr(), buf.len() as u32, &mut n)
        };
        if ok == 0 {
            Err(unsafe { win32::GetLastError() })
        } else {
            Ok(n as usize)
        }
    }

    /// 恢复进入前的控制台模式。
    pub fn restore(&mut self) {
        if !self.active {
            return;
        }
        self.active = false;
        unsafe {
            win32::SetConsoleMode(self.stdin, self.saved_in);
            win32::SetConsoleMode(self.stdout, self.saved_out);
        }
    }
}

impl Drop for RawConsole {
    fn drop(&mut self) {
        self.restore();
    }
}

fn write_all(h: HANDLE, mut data: &[u8]) -> Result<(), u32> {
    while !data.is_empty() {
        let mut written = 0u32;
        let ok = unsafe {
            win32::WriteFile(
                h,
                data.as_ptr() as *const c_void,
                data.len() as u32,
                &mut written,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            return Err(unsafe { win32::GetLastError() });
        }
        if written == 0 {
            return Err(win32::ERROR_BROKEN_PIPE);
        }
        data = &data[written as usize..];
    }
    Ok(())
}

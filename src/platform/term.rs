//! 终端面板：ConPTY + 最小 VT 解析。
//!
//! - 用 Win32 伪终端（Windows 10 1809+）启动 shell，输出经管道读入；
//! - 解析常用 CSI / SGR，维护一块字符网格，由 `render.rs` 画进面板；
//! - 键盘输入转成 ANSI 字节写回伪终端。
//!
//! 伪终端不可用时（老系统）会返回错误，界面提示后自动关闭面板。

#![allow(non_snake_case, non_camel_case_types)]

use std::collections::VecDeque;
use std::ffi::c_void;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use super::win32::{COORD, HANDLE, BOOL, DWORD, WORD};
use crate::render::Color;

type HPCON = isize;
type HRESULT = i32;

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x0002_0016;
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x0008_0000;
const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x0000_0400;

#[repr(C)]
struct STARTUPINFOW {
    cb: DWORD,
    lpReserved: *mut u16,
    lpDesktop: *mut u16,
    lpTitle: *mut u16,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: *mut u8,
    hStdInput: HANDLE,
    hStdOutput: HANDLE,
    hStdError: HANDLE,
}

#[repr(C)]
struct STARTUPINFOEXW {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: *mut c_void,
}

#[repr(C)]
struct PROCESS_INFORMATION {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
}

#[repr(C)]
struct SECURITY_ATTRIBUTES {
    nLength: DWORD,
    lpSecurityDescriptor: *mut c_void,
    bInheritHandle: BOOL,
}

#[link(name = "kernel32")]
extern "system" {
    fn CreatePipe(
        hReadPipe: *mut HANDLE,
        hWritePipe: *mut HANDLE,
        lpPipeAttributes: *const SECURITY_ATTRIBUTES,
        nSize: DWORD,
    ) -> BOOL;
    fn ReadFile(
        hFile: HANDLE,
        lpBuffer: *mut u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: *mut DWORD,
        lpOverlapped: *mut c_void,
    ) -> BOOL;
    fn WriteFile(
        hFile: HANDLE,
        lpBuffer: *const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: *mut DWORD,
        lpOverlapped: *mut c_void,
    ) -> BOOL;
    fn CreateProcessW(
        lpApplicationName: *const u16,
        lpCommandLine: *mut u16,
        lpProcessAttributes: *const SECURITY_ATTRIBUTES,
        lpThreadAttributes: *const SECURITY_ATTRIBUTES,
        bInheritHandles: BOOL,
        dwCreationFlags: DWORD,
        lpEnvironment: *mut c_void,
        lpCurrentDirectory: *const u16,
        lpStartupInfo: *mut STARTUPINFOEXW,
        lpProcessInformation: *mut PROCESS_INFORMATION,
    ) -> BOOL;
    fn InitializeProcThreadAttributeList(
        lpAttributeList: *mut c_void,
        dwAttributeCount: DWORD,
        dwFlags: DWORD,
        lpSize: *mut usize,
    ) -> BOOL;
    fn UpdateProcThreadAttribute(
        lpAttributeList: *mut c_void,
        dwFlags: DWORD,
        Attribute: usize,
        lpValue: *mut c_void,
        cbSize: usize,
        lpPreviousValue: *mut c_void,
        lpReturnSize: *mut usize,
    ) -> BOOL;
    fn DeleteProcThreadAttributeList(lpAttributeList: *mut c_void);
    fn CreatePseudoConsole(
        size: COORD,
        hInput: HANDLE,
        hOutput: HANDLE,
        dwFlags: DWORD,
        phPC: *mut HPCON,
    ) -> HRESULT;
    fn ResizePseudoConsole(hPC: HPCON, size: COORD) -> HRESULT;
    fn ClosePseudoConsole(hPC: HPCON);
    fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) -> BOOL;
    fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *mut DWORD) -> BOOL;
    fn CloseHandle(hObject: HANDLE) -> BOOL;
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

#[derive(Clone, Copy)]
pub struct Cell {
    pub ch: char,
    pub fg: Option<Color>,
    pub bg: Option<Color>,
}

impl Default for Cell {
    fn default() -> Self {
        Cell {
            ch: ' ',
            fg: None,
            bg: None,
        }
    }
}

pub struct Screen {
    pub cols: usize,
    pub rows: usize,
    cells: Vec<Cell>,
    pub cur_x: usize,
    pub cur_y: usize,
    fg: Option<Color>,
    bg: Option<Color>,
    /// 解析状态
    state: State,
    params: Vec<i32>,
    private: bool,
    utf8: Vec<u8>,
    pub dirty: bool,
    /// 最近一屏文本（供测试 / 复制）。
    pub plain: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Ground,
    Esc,
    Csi,
    Osc,
    OscEsc,
}

impl Screen {
    pub fn new(cols: usize, rows: usize) -> Screen {
        let cols = cols.max(2);
        let rows = rows.max(1);
        Screen {
            cols,
            rows,
            cells: vec![Cell::default(); cols * rows],
            cur_x: 0,
            cur_y: 0,
            fg: None,
            bg: None,
            state: State::Ground,
            params: Vec::new(),
            private: false,
            utf8: Vec::new(),
            dirty: true,
            plain: String::new(),
        }
    }

    pub fn cell(&self, x: usize, y: usize) -> Cell {
        self.cells
            .get(y * self.cols + x)
            .copied()
            .unwrap_or_default()
    }

    fn clear(&mut self) {
        for cell in &mut self.cells {
            *cell = Cell::default();
        }
        self.cur_x = 0;
        self.cur_y = 0;
        self.dirty = true;
    }

    fn scroll_up(&mut self, count: usize) {
        let count = count.min(self.rows);
        if count == 0 {
            return;
        }
        self.cells.drain(0..count * self.cols);
        self.cells
            .extend(std::iter::repeat(Cell::default()).take(count * self.cols));
        self.dirty = true;
    }

    fn put(&mut self, ch: char) {
        if self.cur_x >= self.cols {
            self.cur_x = 0;
            self.newline();
        }
        let width = crate::core::unicode::char_width(ch).max(1);
        let index = self.cur_y * self.cols + self.cur_x;
        if index < self.cells.len() {
            self.cells[index] = Cell {
                ch,
                fg: self.fg,
                bg: self.bg,
            };
            // 宽字符占位：第二格标记为不可见
            if width == 2 && self.cur_x + 1 < self.cols {
                self.cells[index + 1] = Cell {
                    ch: '\u{0}',
                    fg: self.fg,
                    bg: self.bg,
                };
            }
        }
        self.cur_x += width;
        if self.cur_x >= self.cols {
            self.cur_x = 0;
            self.newline();
        }
        self.dirty = true;
    }

    fn newline(&mut self) {
        if self.cur_y + 1 >= self.rows {
            self.scroll_up(1);
            self.cur_y = self.rows - 1;
        } else {
            self.cur_y += 1;
        }
        self.dirty = true;
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.feed_byte(byte);
        }
    }

    fn feed_byte(&mut self, byte: u8) {
        match self.state {
            State::Ground => match byte {
                0x1b => self.state = State::Esc,
                0x0d => {
                    self.cur_x = 0;
                    self.dirty = true;
                }
                0x0a => {
                    // Windows 控制台的 LF 同时回车，与 cmd / PowerShell 输出一致。
                    self.cur_x = 0;
                    self.newline();
                }
                0x08 => {
                    if self.cur_x > 0 {
                        self.cur_x -= 1;
                    }
                    self.dirty = true;
                }
                0x09 => {
                    let stop = 8;
                    let next = ((self.cur_x / stop) + 1) * stop;
                    self.cur_x = next.min(self.cols.saturating_sub(1));
                    self.dirty = true;
                }
                0x07 => {}
                b if b < 0x20 => {}
                _ => {
                    self.utf8.push(byte);
                    if let Ok(text) = std::str::from_utf8(&self.utf8) {
                        let owned: Vec<char> = text.chars().collect();
                        self.utf8.clear();
                        for ch in owned {
                            self.put(ch);
                        }
                    } else if self.utf8.len() > 4 {
                        // 非法序列，丢弃
                        self.utf8.clear();
                    }
                }
            },
            State::Esc => match byte {
                b'[' => {
                    self.state = State::Csi;
                    self.params.clear();
                    self.private = false;
                }
                b']' => {
                    self.state = State::Osc;
                }
                b'(' | b')' => self.state = State::Ground,
                _ => self.state = State::Ground,
            },
            State::Csi => match byte {
                b'0'..=b'9' => {
                    if self.params.is_empty() {
                        self.params.push(0);
                    }
                    let value = self.params.last_mut().expect("参数存在");
                    *value = value.saturating_mul(10).saturating_add((byte - b'0') as i32);
                }
                b';' => self.params.push(0),
                b'?' => self.private = true,
                b' ' | b'!' | b'"' | b'$' | b'\'' | b'*' | b'+' => {}
                0x40..=0x7e => {
                    self.csi(byte as char);
                    self.state = State::Ground;
                }
                _ => self.state = State::Ground,
            },
            State::Osc => {
                if byte == 0x07 {
                    self.state = State::Ground;
                } else if byte == 0x1b {
                    self.state = State::OscEsc;
                }
            }
            State::OscEsc => {
                self.state = if byte == b'\\' {
                    State::Ground
                } else {
                    State::Osc
                };
            }
        }
    }

    fn param(&self, index: usize, default: i32) -> i32 {
        self.params
            .get(index)
            .copied()
            .filter(|value| *value > 0)
            .unwrap_or(default)
    }

    fn csi(&mut self, final_byte: char) {
        match final_byte {
            'm' => self.sgr(),
            'H' | 'f' => {
                let row = self.param(0, 1) as usize - 1;
                let col = self.param(1, 1) as usize - 1;
                self.cur_y = row.min(self.rows - 1);
                self.cur_x = col.min(self.cols - 1);
                self.dirty = true;
            }
            'A' => {
                self.cur_y = self.cur_y.saturating_sub(self.param(0, 1) as usize);
                self.dirty = true;
            }
            'B' => {
                self.cur_y = (self.cur_y + self.param(0, 1) as usize).min(self.rows - 1);
                self.dirty = true;
            }
            'C' => {
                self.cur_x = (self.cur_x + self.param(0, 1) as usize).min(self.cols - 1);
                self.dirty = true;
            }
            'D' => {
                self.cur_x = self.cur_x.saturating_sub(self.param(0, 1) as usize);
                self.dirty = true;
            }
            'G' => {
                self.cur_x = (self.param(0, 1) as usize - 1).min(self.cols - 1);
                self.dirty = true;
            }
            'd' => {
                self.cur_y = (self.param(0, 1) as usize - 1).min(self.rows - 1);
                self.dirty = true;
            }
            'J' => {
                let mode = self.params.first().copied().unwrap_or(0);
                match mode {
                    2 | 3 => self.clear(),
                    _ => {
                        let start = self.cur_y * self.cols + self.cur_x;
                        for cell in self.cells.iter_mut().skip(start) {
                            *cell = Cell::default();
                        }
                        self.dirty = true;
                    }
                }
            }
            'K' => {
                let mode = self.params.first().copied().unwrap_or(0);
                let line_start = self.cur_y * self.cols;
                match mode {
                    2 => {
                        for cell in self.cells.iter_mut().skip(line_start).take(self.cols) {
                            *cell = Cell::default();
                        }
                    }
                    _ => {
                        let start = line_start + self.cur_x;
                        for cell in self.cells.iter_mut().skip(start).take(self.cols - self.cur_x) {
                            *cell = Cell::default();
                        }
                    }
                }
                self.dirty = true;
            }
            'S' => self.scroll_up(self.param(0, 1) as usize),
            'T' => {
                let count = self.param(0, 1) as usize;
                let count = count.min(self.rows);
                self.cells
                    .splice(0..0, std::iter::repeat(Cell::default()).take(count * self.cols));
                self.cells.truncate(self.cols * self.rows);
                self.dirty = true;
            }
            'L' => {
                let count = self.param(0, 1) as usize;
                let at = self.cur_y * self.cols;
                self.cells
                    .splice(at..at, std::iter::repeat(Cell::default()).take(count * self.cols));
                self.cells.truncate(self.cols * self.rows);
                self.dirty = true;
            }
            'M' => {
                let count = self.param(0, 1) as usize;
                let at = self.cur_y * self.cols;
                let end = (at + count * self.cols).min(self.cells.len());
                self.cells.drain(at..end);
                self.cells
                    .extend(std::iter::repeat(Cell::default()).take(self.cols * self.rows - self.cells.len()));
                self.dirty = true;
            }
            'P' => {
                let count = self.param(0, 1) as usize;
                let at = self.cur_y * self.cols + self.cur_x;
                let end = (at + count).min((self.cur_y + 1) * self.cols);
                self.cells.drain(at..end);
                let insert_at = (self.cur_y + 1) * self.cols - (end - at);
                self.cells
                    .splice(insert_at..insert_at, std::iter::repeat(Cell::default()).take(end - at));
                self.dirty = true;
            }
            'X' => {
                let count = self.param(0, 1) as usize;
                let at = self.cur_y * self.cols + self.cur_x;
                for cell in self.cells.iter_mut().skip(at).take(count) {
                    *cell = Cell {
                        ch: ' ',
                        fg: self.fg,
                        bg: self.bg,
                    };
                }
                self.dirty = true;
            }
            _ => {}
        }
    }

    fn sgr(&mut self) {
        if self.params.is_empty() {
            self.fg = None;
            self.bg = None;
            return;
        }
        let params = self.params.clone();
        let mut index = 0usize;
        while index < params.len() {
            match params[index] {
                0 => {
                    self.fg = None;
                    self.bg = None;
                }
                1 => {}
                7 => {
                    let fg = self.fg;
                    self.fg = self.bg;
                    self.bg = fg;
                }
                22 | 23 | 24 | 27 | 39 => self.fg = None,
                49 => self.bg = None,
                30..=37 => self.fg = Some(ansi16(params[index] - 30)),
                90..=97 => self.fg = Some(ansi16(params[index] - 90 + 8)),
                40..=47 => self.bg = Some(ansi16(params[index] - 40)),
                100..=107 => self.bg = Some(ansi16(params[index] - 100 + 8)),
                38 | 48 => {
                    let is_fg = params[index] == 38;
                    if params.get(index + 1) == Some(&5) {
                        if let Some(&n) = params.get(index + 2) {
                            let color = ansi256(n as u8);
                            if is_fg {
                                self.fg = Some(color);
                            } else {
                                self.bg = Some(color);
                            }
                        }
                        index += 2;
                    } else if params.get(index + 1) == Some(&2) {
                        let r = params.get(index + 2).copied().unwrap_or(0).clamp(0, 255) as u8;
                        let g = params.get(index + 3).copied().unwrap_or(0).clamp(0, 255) as u8;
                        let b = params.get(index + 4).copied().unwrap_or(0).clamp(0, 255) as u8;
                        let color = Color::rgb(r, g, b);
                        if is_fg {
                            self.fg = Some(color);
                        } else {
                            self.bg = Some(color);
                        }
                        index += 4;
                    }
                }
                _ => {}
            }
            index += 1;
        }
    }

    /// 最近 N 行文本（调试 / 自检用）。
    pub fn text(&self) -> String {
        let mut out = String::new();
        for y in 0..self.rows {
            for x in 0..self.cols {
                let cell = self.cell(x, y);
                if cell.ch != '\u{0}' {
                    out.push(cell.ch);
                }
            }
            while out.ends_with(' ') {
                out.pop();
            }
            out.push('\n');
        }
        out
    }
}

fn ansi16(index: i32) -> Color {
    const TABLE: [(u8, u8, u8); 16] = [
        (0, 0, 0),
        (205, 49, 49),
        (13, 188, 121),
        (229, 229, 16),
        (36, 114, 200),
        (188, 63, 188),
        (17, 168, 205),
        (229, 229, 229),
        (102, 102, 102),
        (241, 76, 76),
        (35, 209, 139),
        (245, 245, 67),
        (59, 142, 234),
        (214, 112, 214),
        (41, 184, 219),
        (255, 255, 255),
    ];
    let (r, g, b) = TABLE[(index as usize).min(15)];
    Color::rgb(r, g, b)
}

fn ansi256(index: u8) -> Color {
    if index < 16 {
        return ansi16(index as i32);
    }
    if index < 232 {
        let value = index - 16;
        let r = value / 36;
        let g = (value % 36) / 6;
        let b = value % 6;
        let step = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
        return Color::rgb(step(r), step(g), step(b));
    }
    let gray = 8 + (index - 232) * 10;
    Color::rgb(gray, gray, gray)
}

pub struct Terminal {
    screen: Arc<Mutex<Screen>>,
    input: isize,
    process: isize,
    hpc: HPCON,
    reader: Option<JoinHandle<()>>,
    alive: Arc<Mutex<bool>>,
    pub cols: usize,
    pub rows: usize,
}

unsafe impl Send for Terminal {}

impl Terminal {
    pub fn spawn(shell: &str, cols: usize, rows: usize, cwd: &Path) -> Result<Terminal, String> {
        let cols = cols.max(10);
        let rows = rows.max(3);
        let size = COORD {
            X: cols as i16,
            Y: rows as i16,
        };

        unsafe {
            let mut sa = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as DWORD,
                lpSecurityDescriptor: std::ptr::null_mut(),
                bInheritHandle: 1,
            };
            let mut input_read: HANDLE = std::ptr::null_mut();
            let mut input_write: HANDLE = std::ptr::null_mut();
            let mut output_read: HANDLE = std::ptr::null_mut();
            let mut output_write: HANDLE = std::ptr::null_mut();
            if CreatePipe(&mut input_read, &mut input_write, &mut sa, 0) == 0 {
                return Err("CreatePipe 失败（输入）".into());
            }
            if CreatePipe(&mut output_read, &mut output_write, &mut sa, 0) == 0 {
                CloseHandle(input_read);
                CloseHandle(input_write);
                return Err("CreatePipe 失败（输出）".into());
            }

            let mut hpc: HPCON = 0;
            let hr = CreatePseudoConsole(size, input_read, output_write, 0, &mut hpc);
            if hr != 0 || hpc == 0 {
                CloseHandle(input_read);
                CloseHandle(input_write);
                CloseHandle(output_read);
                CloseHandle(output_write);
                return Err("当前系统不支持 ConPTY（需要 Windows 10 1809+）".into());
            }

            // 属性列表
            let mut list_size: usize = 0;
            InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut list_size);
            let mut buffer = vec![0u8; list_size.max(64) + 64];
            let list = buffer.as_mut_ptr() as *mut c_void;
            if InitializeProcThreadAttributeList(list, 1, 0, &mut list_size) == 0 {
                ClosePseudoConsole(hpc);
                CloseHandle(input_read);
                CloseHandle(input_write);
                CloseHandle(output_read);
                CloseHandle(output_write);
                return Err("InitializeProcThreadAttributeList 失败".into());
            }
            let mut pc_value = hpc;
            if UpdateProcThreadAttribute(
                list,
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                &mut pc_value as *mut HPCON as *mut c_void,
                std::mem::size_of::<HPCON>(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            ) == 0
            {
                DeleteProcThreadAttributeList(list);
                ClosePseudoConsole(hpc);
                CloseHandle(input_read);
                CloseHandle(input_write);
                CloseHandle(output_read);
                CloseHandle(output_write);
                return Err("UpdateProcThreadAttribute 失败".into());
            }

            let mut startup: STARTUPINFOEXW = std::mem::zeroed();
            startup.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as DWORD;
            startup.StartupInfo.dwFlags = 0;
            startup.lpAttributeList = list;

            let mut command = if shell.trim().is_empty() {
                let comspec = std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".into());
                format!("{comspec} /Q")
            } else {
                shell.to_string()
            };
            if command.trim().is_empty() {
                command = "cmd.exe /Q".into();
            }
            let mut cmd_wide = wide(&command);
            let cwd_wide = wide(&cwd.display().to_string());

            let mut info: PROCESS_INFORMATION = std::mem::zeroed();
            let created = CreateProcessW(
                std::ptr::null(),
                cmd_wide.as_mut_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                1,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                std::ptr::null_mut(),
                cwd_wide.as_ptr(),
                &mut startup,
                &mut info,
            );
            DeleteProcThreadAttributeList(list);
            CloseHandle(input_read);
            CloseHandle(output_write);

            if created == 0 {
                ClosePseudoConsole(hpc);
                CloseHandle(input_write);
                CloseHandle(output_read);
                return Err(format!(
                    "启动 shell 失败：{command}（错误码 {}）",
                    super::win32::GetLastError()
                ));
            }
            CloseHandle(info.hThread);

            let screen = Arc::new(Mutex::new(Screen::new(cols, rows)));
            let alive = Arc::new(Mutex::new(true));
            let reader_screen = screen.clone();
            let reader_alive = alive.clone();
            let read_handle = output_read as isize;
            let reader = std::thread::spawn(move || {
                let handle = read_handle as HANDLE;
                let mut buffer = vec![0u8; 8192];
                loop {
                    let mut read: DWORD = 0;
                    let ok = ReadFile(
                        handle,
                        buffer.as_mut_ptr(),
                        buffer.len() as DWORD,
                        &mut read,
                        std::ptr::null_mut(),
                    );
                    if ok == 0 || read == 0 {
                        break;
                    }
                    if let Ok(mut guard) = reader_screen.lock() {
                        guard.feed(&buffer[..read as usize]);
                    }
                }
                let _ = std::fs::OpenOptions::new();
                if let Ok(mut guard) = reader_alive.lock() {
                    *guard = false;
                }
                CloseHandle(handle);
            });

            Ok(Terminal {
                screen,
                input: input_write as isize,
                process: info.hProcess as isize,
                hpc,
                reader: Some(reader),
                alive,
                cols,
                rows,
            })
        }
    }

    pub fn with_screen<R>(&self, f: impl FnOnce(&Screen) -> R) -> R {
        let guard = self.screen.lock().unwrap_or_else(|e| e.into_inner());
        f(&guard)
    }

    pub fn write(&self, bytes: &[u8]) {
        if bytes.is_empty() || self.input == 0 {
            return;
        }
        unsafe {
            let mut written: DWORD = 0;
            WriteFile(
                self.input as HANDLE,
                bytes.as_ptr(),
                bytes.len() as DWORD,
                &mut written,
                std::ptr::null_mut(),
            );
        }
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        let cols = cols.max(10);
        let rows = rows.max(3);
        if cols == self.cols && rows == self.rows {
            return;
        }
        self.cols = cols;
        self.rows = rows;
        unsafe {
            if self.hpc != 0 {
                ResizePseudoConsole(
                    self.hpc,
                    COORD {
                        X: cols as i16,
                        Y: rows as i16,
                    },
                );
            }
        }
        if let Ok(mut screen) = self.screen.lock() {
            let old = screen.text();
            *screen = Screen::new(cols, rows);
            for line in old.lines().take(rows) {
                for ch in line.chars() {
                    screen.put(ch);
                }
                screen.cur_x = 0;
                screen.newline();
            }
        }
    }

    pub fn is_alive(&self) -> bool {
        *self.alive.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn screen_size(&self) -> (usize, usize) {
        (self.cols, self.rows)
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe {
            if self.process != 0 {
                let mut code: DWORD = 0;
                if GetExitCodeProcess(self.process as HANDLE, &mut code) != 0 && code == 259 {
                    TerminateProcess(self.process as HANDLE, 0);
                }
                CloseHandle(self.process as HANDLE);
            }
            if self.hpc != 0 {
                ClosePseudoConsole(self.hpc);
            }
            if self.input != 0 {
                CloseHandle(self.input as HANDLE);
            }
        }
        if let Some(handle) = self.reader.take() {
            let _ = handle.join();
        }
    }
}

/// Vim 风格的终端按键 → ANSI 字节。
pub fn key_bytes(key: &crate::platform::console::Key) -> Vec<u8> {
    use crate::platform::console::KeyCode;
    let mut out = Vec::new();
    if key.mods.ctrl {
        if let KeyCode::Char(c) = key.code {
            let upper = c.to_ascii_uppercase();
            if upper.is_ascii_alphabetic() {
                out.push((upper as u8) & 0x1f);
                return out;
            }
        }
    }
    match key.code {
        KeyCode::Char(ch) => {
            let mut buf = [0u8; 4];
            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
        }
        KeyCode::Enter => out.push(b'\r'),
        KeyCode::Tab => out.push(b'\t'),
        KeyCode::Backspace => out.push(0x7f),
        KeyCode::Esc => out.push(0x1b),
        KeyCode::Up => out.extend_from_slice(b"\x1b[A"),
        KeyCode::Down => out.extend_from_slice(b"\x1b[B"),
        KeyCode::Right => out.extend_from_slice(b"\x1b[C"),
        KeyCode::Left => out.extend_from_slice(b"\x1b[D"),
        KeyCode::Home => out.extend_from_slice(b"\x1b[H"),
        KeyCode::End => out.extend_from_slice(b"\x1b[F"),
        KeyCode::PageUp => out.extend_from_slice(b"\x1b[5~"),
        KeyCode::PageDown => out.extend_from_slice(b"\x1b[6~"),
        KeyCode::Insert => out.extend_from_slice(b"\x1b[2~"),
        KeyCode::Delete => out.extend_from_slice(b"\x1b[3~"),
        KeyCode::F(n) => {
            let seq: &[u8] = match n {
                1 => b"\x1bOP",
                2 => b"\x1bOQ",
                3 => b"\x1bOR",
                4 => b"\x1bOS",
                5 => b"\x1b[15~",
                6 => b"\x1b[17~",
                7 => b"\x1b[18~",
                8 => b"\x1b[19~",
                9 => b"\x1b[20~",
                10 => b"\x1b[21~",
                11 => b"\x1b[23~",
                12 => b"\x1b[24~",
                _ => b"",
            };
            out.extend_from_slice(seq);
        }
        KeyCode::Unknown(_) => {}
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain_text() {
        let mut screen = Screen::new(10, 3);
        screen.feed(b"hi\nthere");
        assert_eq!(screen.cell(0, 0).ch, 'h');
        assert_eq!(screen.cell(1, 0).ch, 'i');
        assert_eq!(screen.cell(0, 1).ch, 't');
    }

    #[test]
    fn carriage_return_overwrites() {
        let mut screen = Screen::new(10, 2);
        screen.feed(b"abc\rX");
        assert_eq!(screen.cell(0, 0).ch, 'X');
        assert_eq!(screen.cell(1, 0).ch, 'b');
    }

    #[test]
    fn sgr_truecolor() {
        let mut screen = Screen::new(10, 2);
        screen.feed(b"\x1b[38;2;10;20;30mZ");
        let cell = screen.cell(0, 0);
        assert_eq!(cell.ch, 'Z');
        assert_eq!(cell.fg, Some(Color::rgb(10, 20, 30)));
    }

    #[test]
    fn cursor_position() {
        let mut screen = Screen::new(10, 4);
        screen.feed(b"\x1b[3;5HX");
        assert_eq!(screen.cell(4, 2).ch, 'X');
    }

    #[test]
    fn clear_screen() {
        let mut screen = Screen::new(6, 2);
        screen.feed(b"abc\x1b[2Jz");
        assert_eq!(screen.cell(0, 0).ch, 'z');
    }

    #[test]
    fn scrolls_on_overflow() {
        let mut screen = Screen::new(6, 2);
        screen.feed(b"a\r\nb\r\nc");
        assert_eq!(screen.cell(0, 0).ch, 'b');
        assert_eq!(screen.cell(0, 1).ch, 'c');
    }
}

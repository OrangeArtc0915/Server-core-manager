//! TUI 后端：VT 真彩输出 + `ReadConsoleInputW` 输入。
//!
//! 选择控制台 API 而不是 ANSI 输入解析的原因：
//! 中文输入法、Alt 组合键、鼠标位置与窗口缩放都能拿到结构化事件。

#![allow(unused_assignments)]

use std::ffi::c_void;

use super::win32::{self, CONSOLE_SCREEN_BUFFER_INFO, HANDLE, INPUT_RECORD};
use crate::render::{Cell, Color, Grid};

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Mods {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
}

impl Mods {
    pub fn none() -> Mods {
        Mods::default()
    }
    pub fn ctrl() -> Mods {
        Mods {
            ctrl: true,
            ..Mods::default()
        }
    }
    pub fn shift() -> Mods {
        Mods {
            shift: true,
            ..Mods::default()
        }
    }
    pub fn ctrl_shift() -> Mods {
        Mods {
            ctrl: true,
            shift: true,
            ..Mods::default()
        }
    }
    pub fn alt() -> Mods {
        Mods {
            alt: true,
            ..Mods::default()
        }
    }
    pub fn with_alt(self) -> Mods {
        Mods { alt: true, ..self }
    }
    pub fn with_shift(self) -> Mods {
        Mods { shift: true, ..self }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum KeyCode {
    Char(char),
    Enter,
    Tab,
    Backspace,
    Esc,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    F(u8),
    Unknown(u16),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Key {
    pub code: KeyCode,
    pub mods: Mods,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Button {
    Left,
    Right,
    Middle,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MouseKind {
    Down,
    Up,
    Drag,
    Move,
    DoubleClick,
    Wheel,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Mouse {
    pub x: u16,
    pub y: u16,
    pub kind: MouseKind,
    pub button: Option<Button>,
    /// 滚轮格数，向上为正。
    pub wheel: i16,
    pub mods: Mods,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Event {
    Key(Key),
    Mouse(Mouse),
    Resize(u16, u16),
    Focus(bool),
}

struct Pen {
    fg: Color,
    bg: Color,
    attr: u8,
    cursor: Option<(u16, u16)>,
}

pub struct Console {
    out: HANDLE,
    inp: HANDLE,
    out_mode: u32,
    in_mode: u32,
    pub cols: u16,
    pub rows: u16,
    origin: (i16, i16),
    prev: Vec<Cell>,
    last_buttons: u32,
    pen: Pen,
    started: bool,
    cursor_visible: bool,
}

unsafe impl Send for Console {}

impl Console {
    /// 接管当前控制台；失败时返回错误（GUI 子系统或重定向）。
    pub fn new() -> Result<Console, String> {
        unsafe {
            let out = win32::GetStdHandle(win32::STD_OUTPUT_HANDLE);
            let inp = win32::GetStdHandle(win32::STD_INPUT_HANDLE);
            if out.is_null() || out == (-1isize as HANDLE) {
                return Err("标准输出不可用（请从控制台运行，或使用 --gui）".into());
            }
            if inp.is_null() || inp == (-1isize as HANDLE) {
                return Err("标准输入不可用（请从控制台运行，或使用 --gui）".into());
            }

            let mut out_mode = 0u32;
            let mut in_mode = 0u32;
            if win32::GetConsoleMode(out, &mut out_mode) == 0 {
                return Err("当前输出不是控制台（重定向到文件时无法进入 TUI）".into());
            }
            if win32::GetConsoleMode(inp, &mut in_mode) == 0 {
                return Err("当前输入不是控制台".into());
            }

            // 输出：开启 VT 处理，按真彩色绘制。
            let new_out = out_mode
                | win32::ENABLE_PROCESSED_OUTPUT
                | win32::ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            win32::SetConsoleMode(out, new_out);

            // 输入：鼠标 + 窗口事件 + 扩展标志；关闭行输入与回显。
            let new_in = (in_mode
                | win32::ENABLE_WINDOW_INPUT
                | win32::ENABLE_MOUSE_INPUT
                | win32::ENABLE_EXTENDED_FLAGS)
                & !(win32::ENABLE_LINE_INPUT
                    | win32::ENABLE_ECHO_INPUT
                    | win32::ENABLE_QUICK_EDIT_MODE
                    | win32::ENABLE_PROCESSED_INPUT);
            win32::SetConsoleMode(inp, new_in);

            let mut console = Console {
                out,
                inp,
                out_mode,
                in_mode,
                cols: 80,
                rows: 25,
                origin: (0, 0),
                prev: Vec::new(),
                last_buttons: 0,
                pen: Pen {
                    fg: Color::rgb(0, 0, 0),
                    bg: Color::rgb(0, 0, 0),
                    attr: 0,
                    cursor: None,
                },
                started: false,
                cursor_visible: true,
            };
            console.query_size();
            console.enter();
            console.prev = vec![Cell::default(); console.cols as usize * console.rows as usize];
            Ok(console)
        }
    }

    fn enter(&mut self) {
        // 备用屏幕 + 清屏 + 隐藏光标 + 关闭自动换行。
        let setup = "\x1b[?1049h\x1b[?7l\x1b[2J\x1b[H\x1b[?25l";
        self.write_str(setup);
        self.started = true;
    }

    fn query_size(&mut self) {
        unsafe {
            let mut info: CONSOLE_SCREEN_BUFFER_INFO = std::mem::zeroed();
            if win32::GetConsoleScreenBufferInfo(self.out, &mut info) != 0 {
                let width = (info.srWindow.Right - info.srWindow.Left + 1).max(1) as u16;
                let height = (info.srWindow.Bottom - info.srWindow.Top + 1).max(1) as u16;
                self.cols = width;
                self.rows = height;
                self.origin = (info.srWindow.Left, info.srWindow.Top);
            }
        }
    }

    pub fn size(&self) -> (u16, u16) {
        (self.cols, self.rows)
    }

    pub fn set_title(&self, title: &str) {
        unsafe {
            win32::SetConsoleTitleW(win32::wide(title).as_ptr());
        }
    }

    pub fn beep(&self) {
        unsafe {
            win32::Beep(880, 40);
        }
    }

    fn write_str(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        let units: Vec<u16> = text.encode_utf16().collect();
        let mut offset = 0usize;
        while offset < units.len() {
            let chunk = (units.len() - offset).min(8192);
            let mut written = 0u32;
            let ok = unsafe {
                win32::WriteConsoleW(
                    self.out,
                    units[offset..].as_ptr(),
                    chunk as u32,
                    &mut written,
                    std::ptr::null_mut::<c_void>(),
                )
            };
            if ok == 0 || written == 0 {
                break;
            }
            offset += written as usize;
        }
    }

    /// 绘制一帧：只重写发生变化的行。
    pub fn present(&mut self, grid: &Grid) {
        if grid.cols != self.cols as usize || grid.rows != self.rows as usize {
            self.cols = grid.cols as u16;
            self.rows = grid.rows as u16;
            self.prev = vec![Cell::default(); grid.cells.len()];
            self.write_str("\x1b[2J");
        }

        let mut out = String::with_capacity(4096);
        let cols = grid.cols;
        let mut pen_fg = self.pen.fg;
        let mut pen_bg = self.pen.bg;
        let mut pen_attr = self.pen.attr;

        for y in 0..grid.rows {
            let start = y * cols;
            let end = start + cols;
            if self.prev.len() == grid.cells.len()
                && self.prev[start..end] == grid.cells[start..end]
            {
                continue;
            }
            // 光标移动到行首
            out.push_str(&format!(
                "\x1b[{};{}H",
                y as i32 + self.origin.1 as i32 + 1,
                self.origin.0 as i32 + 1
            ));
            let mut x = 0usize;
            while x < cols {
                let cell = &grid.cells[start + x];
                if cell.cont {
                    x += 1;
                    continue;
                }
                if cell.fg != pen_fg {
                    out.push_str(&format!(
                        "\x1b[38;2;{};{};{}m",
                        cell.fg.r, cell.fg.g, cell.fg.b
                    ));
                    pen_fg = cell.fg;
                }
                if cell.bg != pen_bg {
                    out.push_str(&format!(
                        "\x1b[48;2;{};{};{}m",
                        cell.bg.r, cell.bg.g, cell.bg.b
                    ));
                    pen_bg = cell.bg;
                }
                if cell.attr != pen_attr {
                    out.push_str("\x1b[0m");
                    pen_fg = Color::rgb(255, 255, 255);
                    pen_bg = Color::rgb(0, 0, 0);
                    if cell.attr & crate::render::attr::BOLD != 0 {
                        out.push_str("\x1b[1m");
                    }
                    if cell.attr & crate::render::attr::DIM != 0 {
                        out.push_str("\x1b[2m");
                    }
                    if cell.attr & crate::render::attr::ITALIC != 0 {
                        out.push_str("\x1b[3m");
                    }
                    if cell.attr & crate::render::attr::UNDERLINE != 0 {
                        out.push_str("\x1b[4m");
                    }
                    if cell.attr & crate::render::attr::REVERSE != 0 {
                        out.push_str("\x1b[7m");
                    }
                    if cell.attr & crate::render::attr::STRIKE != 0 {
                        out.push_str("\x1b[9m");
                    }
                    out.push_str(&format!(
                        "\x1b[38;2;{};{};{}m\x1b[48;2;{};{};{}m",
                        cell.fg.r, cell.fg.g, cell.fg.b, cell.bg.r, cell.bg.g, cell.bg.b
                    ));
                    pen_fg = cell.fg;
                    pen_bg = cell.bg;
                    pen_attr = cell.attr;
                }
                out.push(cell.ch);
                x += 1 + usize::from(cell.wide);
            }
        }

        self.pen.fg = pen_fg;
        self.pen.bg = pen_bg;
        self.pen.attr = pen_attr;
        self.prev.clear();
        self.prev.extend_from_slice(&grid.cells);
        self.write_str(&out);
    }

    /// 设置光标位置（网格坐标）；`None` 隐藏。
    pub fn set_cursor(&mut self, pos: Option<(u16, u16)>) {
        let mut out = String::new();
        match pos {
            Some((x, y)) => {
                out.push_str(&format!(
                    "\x1b[{};{}H",
                    y as i32 + self.origin.1 as i32 + 1,
                    x as i32 + self.origin.0 as i32 + 1
                ));
                if !self.cursor_visible {
                    out.push_str("\x1b[?25h");
                    self.cursor_visible = true;
                }
            }
            None => {
                if self.cursor_visible {
                    out.push_str("\x1b[?25l");
                    self.cursor_visible = false;
                }
            }
        }
        self.write_str(&out);
    }

    /// 等待一个事件；超时返回 `None`（用于刷新光标动画与后台任务）。
    pub fn read_event(&mut self, timeout_ms: u32) -> Option<Event> {
        unsafe {
            let wait = win32::WaitForSingleObject(self.inp, timeout_ms);
            if wait != 0 {
                return None; // WAIT_TIMEOUT = 258
            }
            let mut record: INPUT_RECORD = std::mem::zeroed();
            let mut count = 0u32;
            if win32::ReadConsoleInputW(self.inp, &mut record, 1, &mut count) == 0 || count == 0 {
                return None;
            }
            match record.EventType {
                win32::KEY_EVENT => {
                    let key = record.Event.KeyEvent;
                    if key.bKeyDown == 0 {
                        return None;
                    }
                    translate_key(key)
                }
                win32::MOUSE_EVENT => {
                    let mouse = record.Event.MouseEvent;
                    self.translate_mouse(mouse)
                }
                win32::WINDOW_BUFFER_SIZE_EVENT => {
                    self.query_size();
                    Some(Event::Resize(self.cols, self.rows))
                }
                win32::FOCUS_EVENT => {
                    let focus = record.Event.FocusEvent;
                    Some(Event::Focus(focus.bSetFocus != 0))
                }
                _ => None,
            }
        }
    }

    unsafe fn translate_mouse(&mut self, record: win32::MOUSE_EVENT_RECORD) -> Option<Event> {
        let x = (record.dwMousePosition.X - self.origin.0).max(0) as u16;
        let y = (record.dwMousePosition.Y - self.origin.1).max(0) as u16;
        let mods = mods_from(record.dwControlKeyState);
        let buttons = record.dwButtonState & 0xFFFF;

        let kind;
        let mut button = None;

        if record.dwEventFlags & win32::MOUSE_WHEELED != 0 {
            let delta = ((record.dwButtonState >> 16) as i16) / 120;
            return Some(Event::Mouse(Mouse {
                x,
                y,
                kind: MouseKind::Wheel,
                button: None,
                wheel: delta,
                mods,
            }));
        }

        match record.dwEventFlags {
            0 => {
                let pressed = buttons & !self.last_buttons;
                button = button_of(pressed).or_else(|| button_of(buttons));
                kind = if pressed != 0 {
                    MouseKind::Down
                } else {
                    MouseKind::Up
                };
            }
            win32::MOUSE_MOVED => {
                kind = if buttons != 0 {
                    MouseKind::Drag
                } else {
                    MouseKind::Move
                };
                button = button_of(buttons);
            }
            win32::DOUBLE_CLICK => {
                kind = MouseKind::DoubleClick;
                button = button_of(buttons);
            }
            _ => return None,
        }
        if kind == MouseKind::Up && button.is_none() {
            button = button_of(self.last_buttons);
        }
        self.last_buttons = buttons;
        Some(Event::Mouse(Mouse {
            x,
            y,
            kind,
            button,
            wheel: 0,
            mods,
        }))
    }

    /// 恢复原控制台状态（退出时调用）。
    pub fn restore(&mut self) {
        if !self.started {
            return;
        }
        self.write_str("\x1b[0m\x1b[?25h\x1b[?7h\x1b[?1049l");
        unsafe {
            win32::SetConsoleMode(self.out, self.out_mode);
            win32::SetConsoleMode(self.inp, self.in_mode);
        }
        self.started = false;
    }
}

impl Drop for Console {
    fn drop(&mut self) {
        self.restore();
    }
}

fn button_of(bits: u32) -> Option<Button> {
    if bits & win32::FROM_LEFT_1ST_BUTTON_PRESSED != 0 {
        Some(Button::Left)
    } else if bits & win32::RIGHTMOST_BUTTON_PRESSED != 0 {
        Some(Button::Right)
    } else if bits & win32::FROM_LEFT_2ND_BUTTON_PRESSED != 0 {
        Some(Button::Middle)
    } else {
        None
    }
}

fn mods_from(state: u32) -> Mods {
    Mods {
        ctrl: state & (win32::LEFT_CTRL_PRESSED | win32::RIGHT_CTRL_PRESSED) != 0,
        alt: state & (win32::LEFT_ALT_PRESSED | win32::RIGHT_ALT_PRESSED) != 0,
        shift: state & win32::SHIFT_PRESSED != 0,
    }
}

fn translate_key(key: win32::KEY_EVENT_RECORD) -> Option<Event> {
    let mut mods = mods_from(key.dwControlKeyState);
    let vk = key.wVirtualKeyCode;
    let ch = char::from_u32(key.uChar as u32).filter(|c| *c != '\0');

    // AltGr 在 Windows 上表现为 Ctrl+Alt+字符，此时不当作 Ctrl+Alt 组合。
    let altgr = mods.ctrl && mods.alt && ch.is_some();
    if altgr {
        mods.ctrl = false;
        mods.alt = false;
    }

    let code = match vk {
        win32::VK_RETURN => KeyCode::Enter,
        win32::VK_TAB => KeyCode::Tab,
        win32::VK_BACK => KeyCode::Backspace,
        win32::VK_ESCAPE => KeyCode::Esc,
        win32::VK_UP => KeyCode::Up,
        win32::VK_DOWN => KeyCode::Down,
        win32::VK_LEFT => KeyCode::Left,
        win32::VK_RIGHT => KeyCode::Right,
        win32::VK_HOME => KeyCode::Home,
        win32::VK_END => KeyCode::End,
        win32::VK_PRIOR => KeyCode::PageUp,
        win32::VK_NEXT => KeyCode::PageDown,
        win32::VK_INSERT => KeyCode::Insert,
        win32::VK_DELETE => KeyCode::Delete,
        v if (win32::VK_F1..=win32::VK_F24).contains(&v) => {
            KeyCode::F((v - win32::VK_F1 + 1) as u8)
        }
        _ => {
            if let Some(ch) = ch {
                // Ctrl + 字母的控制字符还原为可读字母；Ctrl+[ \ ] 等标点单独处理。
                let code = match ch as u32 {
                    1..=26 if mods.ctrl => {
                        KeyCode::Char(char::from_u32(ch as u32 + 0x60).unwrap_or(ch))
                    }
                    0x1B if mods.ctrl => KeyCode::Char('['),
                    0x1C if mods.ctrl => KeyCode::Char('\\'),
                    0x1D if mods.ctrl => KeyCode::Char(']'),
                    0x1E if mods.ctrl => KeyCode::Char('^'),
                    0x1F if mods.ctrl => KeyCode::Char('_'),
                    _ => KeyCode::Char(ch),
                };
                code
            } else if mods.alt {
                // Alt+字母：uChar 为 0，用虚拟键还原。
                match vk {
                    0x30..=0x39 => KeyCode::Char((b'0' + (vk - 0x30) as u8) as char),
                    0x41..=0x5A => KeyCode::Char(
                        (b'a' + (vk - 0x41) as u8).to_ascii_lowercase() as char,
                    ),
                    _ => KeyCode::Unknown(vk),
                }
            } else {
                KeyCode::Unknown(vk)
            }
        }
    };
    Some(Event::Key(Key { code, mods }))
}

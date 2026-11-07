//! 键盘输入：把控制台 KEY_EVENT 归一化成快捷键组合，或翻译成 VT 字节。

use crate::action::{Chord, Key};
use crate::platform::win32;

/// 一条由控制台输入记录解码出的事件。
#[derive(Debug, Clone, Copy)]
pub enum Record {
    Key(KeyEvent),
    Resize(u16, u16),
    Mouse(MouseEvent),
}

/// 鼠标事件（控制台坐标，0 起）。
#[derive(Debug, Clone, Copy, Default)]
pub struct MouseEvent {
    pub x: usize,
    pub y: usize,
    /// `dwButtonState` 原始位：0x1 左键、0x2 右键、0x4 中键；滚轮时高 16 位是增量。
    pub buttons: u32,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    /// 滚轮（正 = 向上）。
    pub wheel: i16,
    /// 水平滚轮。
    pub hwheel: i16,
    pub moved: bool,
    pub double_click: bool,
}

pub const FROM_LEFT_1ST_BUTTON_PRESSED: u32 = 0x0001;
pub const RIGHTMOST_BUTTON_PRESSED: u32 = 0x0002;
pub const FROM_LEFT_2ND_BUTTON_PRESSED: u32 = 0x0004;
pub const MOUSE_MOVED: u32 = 0x0001;
pub const DOUBLE_CLICK: u32 = 0x0002;
pub const MOUSE_WHEELED: u32 = 0x0004;
pub const MOUSE_HWHEELED: u32 = 0x0008;

/// 解码 `ReadConsoleInputW` 记录；不关心的事件返回 `None`。
pub fn decode_record(rec: &win32::INPUT_RECORD) -> Option<Record> {
    match rec.event_type {
        win32::KEY_EVENT => {
            // 布局：data[0] = bKeyDown（BOOL 占 4 字节）
            //       data[1] = wRepeatCount | (wVirtualKeyCode << 16)
            //       data[2] = wVirtualScanCode | (UnicodeChar << 16)
            //       data[3] = dwControlKeyState
            // 抬起事件也要保留：win32-input-mode（`CSI ? 9001 h`）需要它。
            let down = rec.data[0] != 0;
            let repeat = (rec.data[1] & 0xffff) as u16;
            let vk = (rec.data[1] >> 16) as u16;
            let scan = (rec.data[2] & 0xffff) as u16;
            let ch_raw = (rec.data[2] >> 16) as u16;
            let ch = char::from_u32(ch_raw as u32).filter(|c| *c != '\0');
            let state = rec.data[3];
            Some(Record::Key(KeyEvent {
                vk,
                scan,
                repeat: repeat.max(1),
                down,
                ch,
                ctrl: state & (win32::LEFT_CTRL_PRESSED | win32::RIGHT_CTRL_PRESSED) != 0,
                alt: state & (win32::LEFT_ALT_PRESSED | win32::RIGHT_ALT_PRESSED) != 0,
                shift: state & win32::SHIFT_PRESSED != 0,
            }))
        }
        win32::WINDOW_BUFFER_SIZE_EVENT => {
            let coord = rec.data[0];
            let cols = (coord & 0xffff) as u16;
            let rows = (coord >> 16) as u16;
            if cols == 0 || rows == 0 {
                None
            } else {
                Some(Record::Resize(cols, rows))
            }
        }
        win32::MOUSE_EVENT => {
            let pos = rec.data[0];
            let x = pos & 0xffff;
            let y = pos >> 16;
            if x == 0xffff || y == 0xffff {
                return None;
            }
            let buttons = rec.data[1];
            let state = rec.data[2];
            let flags = rec.data[3];
            let wheel = if flags & MOUSE_WHEELED != 0 {
                (buttons >> 16) as i16
            } else {
                0
            };
            let hwheel = if flags & MOUSE_HWHEELED != 0 {
                (buttons >> 16) as i16
            } else {
                0
            };
            Some(Record::Mouse(MouseEvent {
                x: x as usize,
                y: y as usize,
                buttons,
                ctrl: state & (win32::LEFT_CTRL_PRESSED | win32::RIGHT_CTRL_PRESSED) != 0,
                alt: state & (win32::LEFT_ALT_PRESSED | win32::RIGHT_ALT_PRESSED) != 0,
                shift: state & win32::SHIFT_PRESSED != 0,
                wheel,
                hwheel,
                moved: flags & MOUSE_MOVED != 0,
                double_click: flags & DOUBLE_CLICK != 0,
            }))
        }
        _ => None,
    }
}

pub const VK_BACK: u16 = 0x08;
pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_SPACE: u16 = 0x20;
pub const VK_PRIOR: u16 = 0x21;
pub const VK_NEXT: u16 = 0x22;
pub const VK_END: u16 = 0x23;
pub const VK_HOME: u16 = 0x24;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_INSERT: u16 = 0x2D;
pub const VK_DELETE: u16 = 0x2E;
pub const VK_OEM_1: u16 = 0xBA;
pub const VK_OEM_PLUS: u16 = 0xBB;
pub const VK_OEM_COMMA: u16 = 0xBC;
pub const VK_OEM_MINUS: u16 = 0xBD;
pub const VK_OEM_PERIOD: u16 = 0xBE;
pub const VK_OEM_2: u16 = 0xBF;
pub const VK_OEM_3: u16 = 0xC0;
pub const VK_OEM_4: u16 = 0xDB;
pub const VK_OEM_5: u16 = 0xDC;
pub const VK_OEM_6: u16 = 0xDD;
pub const VK_OEM_7: u16 = 0xDE;

#[derive(Debug, Clone, Copy)]
pub struct KeyEvent {
    pub vk: u16,
    /// 扫描码（win32-input-mode 需要）。
    pub scan: u16,
    /// 重复次数（按住不放时 >1）。
    pub repeat: u16,
    /// true = 按下，false = 抬起。
    pub down: bool,
    pub ch: Option<char>,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
}

impl KeyEvent {
    /// 测试与内部构造用的默认值：按下、无扫描码、repeat=1。
    #[cfg(test)]
    pub fn simple(vk: u16, ch: Option<char>, ctrl: bool, alt: bool, shift: bool) -> KeyEvent {
        KeyEvent {
            vk,
            scan: 0,
            repeat: 1,
            down: true,
            ch,
            ctrl,
            alt,
            shift,
        }
    }
}

/// win32-input-mode（`CSI ? 9001 h`）编码：`CSI Vk;Sc;Uc;Kd;Cs;Rc _`
///
/// 这样 Shift+Enter、Ctrl+Shift+字母等 VT 表达不了的组合键也能原样送进 TUI 程序。
pub fn encode_win32_key(ev: &KeyEvent) -> Vec<u8> {
    let mut state = 0u32;
    if ev.shift {
        state |= win32::SHIFT_PRESSED;
    }
    if ev.ctrl {
        state |= win32::LEFT_CTRL_PRESSED;
    }
    if ev.alt {
        state |= win32::LEFT_ALT_PRESSED;
    }
    let unicode = ev.ch.map(|ch| ch as u32).unwrap_or(0);
    format!(
        "\x1b[{};{};{};{};{};{}_",
        ev.vk,
        ev.scan,
        unicode,
        if ev.down { 1 } else { 0 },
        state,
        ev.repeat.max(1)
    )
    .into_bytes()
}

/// 转换成快捷键组合（供动作分发使用）。
pub fn chord_of(ev: &KeyEvent) -> Option<Chord> {
    let key = key_of(ev)?;
    Some(Chord {
        ctrl: ev.ctrl,
        alt: ev.alt,
        shift: ev.shift,
        key,
    })
}

fn key_of(ev: &KeyEvent) -> Option<Key> {
    let key = match ev.vk {
        VK_TAB => Key::Tab,
        VK_RETURN => Key::Enter,
        VK_ESCAPE => Key::Escape,
        VK_BACK => Key::Backspace,
        VK_SPACE => Key::Space,
        VK_UP => Key::Up,
        VK_DOWN => Key::Down,
        VK_LEFT => Key::Left,
        VK_RIGHT => Key::Right,
        VK_HOME => Key::Home,
        VK_END => Key::End,
        VK_PRIOR => Key::PageUp,
        VK_NEXT => Key::PageDown,
        VK_INSERT => Key::Insert,
        VK_DELETE => Key::Delete,
        0x30..=0x39 => Key::Char((b'0' + (ev.vk - 0x30) as u8) as char),
        0x41..=0x5A => Key::Char((b'a' + (ev.vk - 0x41) as u8) as char),
        0x70..=0x87 => Key::F((ev.vk - 0x70 + 1) as u8),
        VK_OEM_MINUS => Key::Char('-'),
        VK_OEM_PLUS => Key::Char(if ev.shift { '+' } else { '=' }),
        VK_OEM_COMMA => Key::Char(','),
        VK_OEM_PERIOD => Key::Char('.'),
        VK_OEM_1 => Key::Char(if ev.shift { ':' } else { ';' }),
        VK_OEM_2 => Key::Char(if ev.shift { '?' } else { '/' }),
        VK_OEM_3 => Key::Char(if ev.shift { '~' } else { '`' }),
        VK_OEM_4 => Key::Char(if ev.shift { '{' } else { '[' }),
        VK_OEM_5 => Key::Char(if ev.shift { '|' } else { '\\' }),
        VK_OEM_6 => Key::Char(if ev.shift { '}' } else { ']' }),
        VK_OEM_7 => Key::Char(if ev.shift { '"' } else { '\'' }),
        _ => {
            let ch = ev.ch?;
            if ch.is_control() {
                return None;
            }
            Key::Char(ch.to_ascii_lowercase())
        }
    };
    Some(key)
}

fn modifier_param(ev: &KeyEvent) -> u8 {
    1 + u8::from(ev.shift) + 2 * u8::from(ev.alt) + 4 * u8::from(ev.ctrl)
}

/// 翻译成要发给子进程的 VT 字节；纯修饰键返回空。
pub fn encode_key(ev: &KeyEvent, app_cursor: bool) -> Vec<u8> {
    let m = modifier_param(ev);
    let mut out: Vec<u8> = Vec::new();

    match key_of(ev) {
        Some(Key::Up) => csi_letter(&mut out, 'A', m, app_cursor),
        Some(Key::Down) => csi_letter(&mut out, 'B', m, app_cursor),
        Some(Key::Right) => csi_letter(&mut out, 'C', m, app_cursor),
        Some(Key::Left) => csi_letter(&mut out, 'D', m, app_cursor),
        Some(Key::Home) => csi_letter(&mut out, 'H', m, app_cursor),
        Some(Key::End) => csi_letter(&mut out, 'F', m, app_cursor),
        Some(Key::Insert) => csi_tilde(&mut out, 2, m),
        Some(Key::Delete) => csi_tilde(&mut out, 3, m),
        Some(Key::PageUp) => csi_tilde(&mut out, 5, m),
        Some(Key::PageDown) => csi_tilde(&mut out, 6, m),
        Some(Key::F(n)) => {
            if n <= 4 {
                let letter = (b'P' + (n - 1)) as char;
                if m == 1 {
                    out.extend_from_slice(b"\x1bO");
                    out.push(letter as u8);
                } else {
                    out.extend_from_slice(format!("\x1b[1;{m}{letter}").as_bytes());
                }
            } else {
                let code = match n {
                    5 => 15,
                    6 => 17,
                    7 => 18,
                    8 => 19,
                    9 => 20,
                    10 => 21,
                    11 => 23,
                    12 => 24,
                    _ => 0,
                };
                if code > 0 {
                    csi_tilde(&mut out, code, m);
                }
            }
        }
        Some(Key::Tab) => {
            if ev.shift && !ev.ctrl && !ev.alt {
                out.extend_from_slice(b"\x1b[Z");
            } else {
                out.push(0x09);
            }
        }
        Some(Key::Enter) => {
            if ev.alt {
                out.push(0x1b);
            }
            out.push(b'\r');
        }
        Some(Key::Backspace) => out.push(0x7f),
        Some(Key::Escape) => out.push(0x1b),
        Some(Key::Space) => {
            if ev.alt {
                out.push(0x1b);
            }
            out.push(if ev.ctrl { 0x00 } else { b' ' });
        }
        Some(Key::Char(c)) => {
            if ev.ctrl {
                if let Some(code) = control_code(c) {
                    if ev.alt {
                        out.push(0x1b);
                    }
                    out.push(code);
                    return out;
                }
            }
            // 非 Ctrl 组合直接使用键事件带来的字符，保留大小写与输入法结果
            let effective = if ev.ctrl {
                c
            } else {
                ev.ch.filter(|ch| !ch.is_control()).unwrap_or(c)
            };
            if ev.alt {
                out.push(0x1b);
            }
            let mut buf = [0u8; 4];
            out.extend_from_slice(effective.encode_utf8(&mut buf).as_bytes());
        }
        None => return out,
    }
    out
}

fn csi_letter(out: &mut Vec<u8>, final_byte: char, m: u8, app_cursor: bool) {
    if m == 1 && app_cursor {
        out.extend_from_slice(b"\x1bO");
        out.push(final_byte as u8);
    } else if m == 1 {
        out.extend_from_slice(b"\x1b[");
        out.push(final_byte as u8);
    } else {
        out.extend_from_slice(format!("\x1b[1;{m}{final_byte}").as_bytes());
    }
}

fn csi_tilde(out: &mut Vec<u8>, code: u32, m: u8) {
    if m == 1 {
        out.extend_from_slice(format!("\x1b[{code}~").as_bytes());
    } else {
        out.extend_from_slice(format!("\x1b[{code};{m}~").as_bytes());
    }
}

fn control_code(c: char) -> Option<u8> {
    let c = c.to_ascii_lowercase();
    match c {
        'a'..='z' => Some((c as u8) - b'a' + 1),
        '[' => Some(0x1b),
        '\\' => Some(0x1c),
        ']' => Some(0x1d),
        '^' => Some(0x1e),
        '_' => Some(0x1f),
        '@' => Some(0x00),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(vk: u16, ch: Option<char>, ctrl: bool, alt: bool, shift: bool) -> KeyEvent {
        KeyEvent::simple(vk, ch, ctrl, alt, shift)
    }

    #[test]
    fn key_records_keep_scan_repeat_and_release() {
        // 按下 a：bKeyDown=1，vk=0x41，scan=0x1E，UnicodeChar='a'
        let mut rec = win32::INPUT_RECORD {
            event_type: win32::KEY_EVENT,
            ..Default::default()
        };
        rec.data[0] = 1;
        rec.data[1] = 2 | (0x41 << 16);
        rec.data[2] = 0x1e | (('a' as u32) << 16);
        rec.data[3] = 0;
        let ev = match decode_record(&rec) {
            Some(Record::Key(ev)) => ev,
            other => panic!("应解码为按键：{other:?}"),
        };
        assert!(ev.down);
        assert_eq!(ev.vk, 0x41);
        assert_eq!(ev.scan, 0x1e);
        assert_eq!(ev.repeat, 2);

        // 抬起事件仍需保留，供 win32-input-mode 使用
        rec.data[0] = 0;
        let ev = match decode_record(&rec) {
            Some(Record::Key(ev)) => ev,
            other => panic!("抬起事件应保留：{other:?}"),
        };
        assert!(!ev.down);
    }

    #[test]
    fn win32_input_mode_encoding() {
        // Shift+Enter：Vk=13 Sc=28 Uc=13 Kd=1 Cs=16 Rc=1
        let mut ev = KeyEvent::simple(VK_RETURN, Some('\r'), false, false, true);
        ev.scan = 28;
        assert_eq!(encode_win32_key(&ev), b"\x1b[13;28;13;1;16;1_");
        ev.down = false;
        assert_eq!(encode_win32_key(&ev), b"\x1b[13;28;13;0;16;1_");
        // Ctrl+Alt+Del 不会被系统送到这里，但组合位必须正确：Ctrl(8) + Alt(2)
        let ev = KeyEvent::simple(0x41, Some('\u{1}'), true, true, false);
        assert_eq!(encode_win32_key(&ev), b"\x1b[65;0;1;1;10;1_");
    }

    #[test]
    fn arrows_with_modifiers() {
        assert_eq!(
            encode_key(&ev(VK_UP, None, false, false, false), false),
            b"\x1b[A"
        );
        assert_eq!(
            encode_key(&ev(VK_UP, None, false, false, false), true),
            b"\x1bOA"
        );
        assert_eq!(
            encode_key(&ev(VK_LEFT, None, true, false, false), false),
            b"\x1b[1;5D"
        );
        assert_eq!(
            encode_key(&ev(VK_RIGHT, None, false, true, true), false),
            b"\x1b[1;4C"
        );
    }

    #[test]
    fn ctrl_and_alt_letters() {
        assert_eq!(
            encode_key(&ev(0x41, Some('a'), true, false, false), false),
            vec![0x01]
        );
        assert_eq!(
            encode_key(&ev(0x41, Some('a'), false, true, false), false),
            b"\x1ba"
        );
        assert_eq!(
            encode_key(&ev(0x41, Some('A'), false, true, true), false),
            "\x1bA".as_bytes()
        );
    }

    #[test]
    fn function_keys() {
        assert_eq!(
            encode_key(&ev(0x70, None, false, false, false), false),
            b"\x1bOP"
        );
        assert_eq!(
            encode_key(&ev(0x74, None, false, false, false), false),
            b"\x1b[15~"
        );
    }

    #[test]
    fn chord_normalization() {
        let chord = chord_of(&ev(0x54, Some('t'), true, false, true)).unwrap();
        assert!(chord.ctrl && chord.shift);
        assert_eq!(chord.key, Key::Char('t'));
        let chord = chord_of(&ev(VK_OEM_MINUS, Some('-'), false, true, true)).unwrap();
        assert_eq!(chord.key, Key::Char('-'));
        assert!(!chord.ctrl);
    }

    #[test]
    fn decodes_wheel_event() {
        let mut record = win32::INPUT_RECORD::default();
        record.event_type = win32::MOUSE_EVENT;
        record.data[0] = 10 | (5 << 16);
        record.data[1] = 120u32 << 16;
        record.data[3] = MOUSE_WHEELED;
        match decode_record(&record) {
            Some(Record::Mouse(ev)) => {
                assert_eq!((ev.x, ev.y), (10, 5));
                assert_eq!(ev.wheel, 120);
                assert_eq!(ev.buttons & 0xffff, 0);
            }
            other => panic!("应解码为鼠标事件：{other:?}"),
        }
    }

    #[test]
    fn shift_tab_is_cbt() {
        assert_eq!(
            encode_key(&ev(VK_TAB, Some('\t'), false, false, true), false),
            b"\x1b[Z"
        );
    }
}

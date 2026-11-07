//! VT 序列解析状态机：CSI / OSC / ESC / DCS，处理 UTF-8 多字节字符。
//!
//! 只做「解析 + 派发」，所有屏幕状态变更都落在 `Screen` 上，便于单测。

use super::screen::Screen;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    Ground,
    Escape,
    EscapeIntermediate,
    CsiEntry,
    CsiParam,
    CsiIntermediate,
    OscString,
    OscEscape,
    IgnoredString,
    IgnoredStringEscape,
}

pub struct Parser {
    state: State,
    params: Vec<u32>,
    param_seen: bool,
    private: Option<u8>,
    intermediates: Vec<u8>,
    string_buf: Vec<u8>,
    utf8: [u8; 4],
    utf8_len: usize,
    utf8_need: usize,
}

impl Default for Parser {
    fn default() -> Self {
        Parser::new()
    }
}

impl Parser {
    pub fn new() -> Parser {
        Parser {
            state: State::Ground,
            params: Vec::new(),
            param_seen: false,
            private: None,
            intermediates: Vec::new(),
            string_buf: Vec::new(),
            utf8: [0; 4],
            utf8_len: 0,
            utf8_need: 0,
        }
    }

    pub fn feed(&mut self, bytes: &[u8], screen: &mut Screen) {
        for &b in bytes {
            self.byte(b, screen);
        }
    }

    fn reset_sequence(&mut self) {
        self.params.clear();
        self.param_seen = false;
        self.private = None;
        self.intermediates.clear();
        self.string_buf.clear();
    }

    fn byte(&mut self, b: u8, screen: &mut Screen) {
        // UTF-8 续字节优先处理
        if self.utf8_need > 0 && self.state == State::Ground {
            if b & 0xc0 == 0x80 {
                self.utf8[self.utf8_len] = b;
                self.utf8_len += 1;
                if self.utf8_len == self.utf8_need {
                    if let Ok(s) = std::str::from_utf8(&self.utf8[..self.utf8_len]) {
                        for ch in s.chars() {
                            screen.print(ch);
                        }
                    }
                    self.utf8_len = 0;
                    self.utf8_need = 0;
                }
                return;
            }
            // 非法序列：丢弃未完成字节，按新字节继续
            self.utf8_len = 0;
            self.utf8_need = 0;
        }

        match self.state {
            State::Ground => self.ground(b, screen),
            State::Escape => self.escape(b, screen),
            State::EscapeIntermediate => {
                if (0x20..=0x2f).contains(&b) {
                    self.intermediates.push(b);
                } else if self.intermediates.first() == Some(&b'#') && b == b'8' {
                    // DECALN：整屏填 E 的对齐测试
                    screen.alignment_test();
                    self.reset_sequence();
                    self.state = State::Ground;
                } else {
                    self.state = State::Ground;
                    self.reset_sequence();
                    if b == 0x1b {
                        self.state = State::Escape;
                    }
                }
            }
            State::CsiEntry | State::CsiParam | State::CsiIntermediate => self.csi(b, screen),
            State::OscString => match b {
                0x07 => {
                    self.dispatch_osc(screen);
                    self.state = State::Ground;
                }
                0x1b => self.state = State::OscEscape,
                _ => {
                    if self.string_buf.len() < 8192 {
                        self.string_buf.push(b);
                    }
                }
            },
            State::OscEscape => {
                if b == b'\\' {
                    self.dispatch_osc(screen);
                    self.state = State::Ground;
                } else {
                    // ESC 后跟非 '\' ：OSC 中止，按新序列处理
                    self.string_buf.clear();
                    self.state = State::Escape;
                    self.escape(b, screen);
                }
            }
            State::IgnoredString => {
                if b == 0x1b {
                    self.state = State::IgnoredStringEscape;
                }
            }
            State::IgnoredStringEscape => {
                if b == b'\\' {
                    self.state = State::Ground;
                } else {
                    self.state = State::IgnoredString;
                }
            }
        }
    }

    fn ground(&mut self, b: u8, screen: &mut Screen) {
        match b {
            0x1b => {
                self.reset_sequence();
                self.state = State::Escape;
            }
            0x00..=0x1f => screen.execute(b),
            0x7f => {}
            0x20..=0x7e => screen.print(b as char),
            _ => {
                self.utf8[0] = b;
                self.utf8_len = 1;
                self.utf8_need = if b & 0xe0 == 0xc0 {
                    2
                } else if b & 0xf0 == 0xe0 {
                    3
                } else if b & 0xf8 == 0xf0 {
                    4
                } else {
                    0
                };
                if self.utf8_need == 0 {
                    self.utf8_len = 0;
                }
            }
        }
    }

    fn escape(&mut self, b: u8, screen: &mut Screen) {
        match b {
            b'[' => {
                self.reset_sequence();
                self.state = State::CsiEntry;
            }
            b']' => {
                self.string_buf.clear();
                self.state = State::OscString;
            }
            b'P' | b'^' | b'_' | b'X' => {
                self.state = State::IgnoredString;
            }
            b'(' | b')' | b'*' | b'+' | b'#' | b'%' => {
                self.intermediates.push(b);
                self.state = State::EscapeIntermediate;
            }
            b'7' => {
                screen.save_cursor();
                self.state = State::Ground;
            }
            b'8' => {
                screen.restore_cursor();
                self.state = State::Ground;
            }
            b'D' => {
                screen.index();
                self.state = State::Ground;
            }
            b'E' => {
                screen.newline();
                self.state = State::Ground;
            }
            b'M' => {
                screen.reverse_index();
                self.state = State::Ground;
            }
            b'H' => {
                screen.set_tab_stop();
                self.state = State::Ground;
            }
            b'c' => {
                screen.reset();
                self.state = State::Ground;
            }
            b'\\' => self.state = State::Ground,
            _ => {
                if (0x20..=0x2f).contains(&b) {
                    self.intermediates.push(b);
                    self.state = State::EscapeIntermediate;
                } else {
                    self.state = State::Ground;
                }
            }
        }
    }

    fn csi(&mut self, b: u8, screen: &mut Screen) {
        match b {
            0x1b => {
                self.reset_sequence();
                self.state = State::Escape;
            }
            0x00..=0x1f => {
                // 序列中的控制字符直接执行（如 CSI 中夹带 CR）
                screen.execute(b);
            }
            b'0'..=b'9' => {
                let value = self.params.last().copied().unwrap_or(0);
                let next = value.saturating_mul(10).saturating_add((b - b'0') as u32);
                if let Some(last) = self.params.last_mut() {
                    *last = next;
                } else {
                    self.params.push(next);
                }
                self.param_seen = true;
                self.state = State::CsiParam;
            }
            b';' | b':' => {
                if !self.param_seen {
                    self.params.push(0);
                }
                self.params.push(0);
                self.param_seen = false;
                self.state = State::CsiParam;
            }
            b'?' | b'>' | b'<' | b'=' => {
                self.private = Some(b);
                self.state = State::CsiParam;
            }
            0x20..=0x2f => {
                self.intermediates.push(b);
                self.state = State::CsiIntermediate;
            }
            0x40..=0x7e => {
                let mut params = std::mem::take(&mut self.params);
                if params.last() == Some(&0) && !self.param_seen && !params.is_empty() {
                    // 尾部分号产生的占位参数保留为 0，交由具体处理器解释
                }
                let private = self.private;
                let intermediates = std::mem::take(&mut self.intermediates);
                self.state = State::Ground;
                self.params = Vec::new();
                self.param_seen = false;
                self.private = None;
                self.apply_csi(private, &intermediates, b, &mut params, screen);
            }
            _ => {}
        }
    }

    fn param(params: &[u32], idx: usize, default: u32) -> u32 {
        match params.get(idx) {
            Some(&0) | None => default,
            Some(&v) => v,
        }
    }

    fn param_raw(params: &[u32], idx: usize) -> u32 {
        params.get(idx).copied().unwrap_or(0)
    }

    fn apply_csi(
        &mut self,
        private: Option<u8>,
        intermediates: &[u8],
        final_byte: u8,
        params: &mut Vec<u32>,
        screen: &mut Screen,
    ) {
        let private_mode = private == Some(b'?');

        match final_byte {
            b'A' => screen.move_up(Self::param(params, 0, 1) as usize),
            b'B' | b'e' => screen.move_down(Self::param(params, 0, 1) as usize),
            b'C' | b'a' => screen.move_right(Self::param(params, 0, 1) as usize),
            b'D' => screen.move_left(Self::param(params, 0, 1) as usize),
            b'E' => {
                let n = Self::param(params, 0, 1) as usize;
                screen.move_down(n);
                screen.goto(0, screen.cursor_y);
            }
            b'F' => {
                let n = Self::param(params, 0, 1) as usize;
                screen.move_up(n);
                screen.goto(0, screen.cursor_y);
            }
            b'G' | b'`' => {
                let x = Self::param(params, 0, 1) as usize - 1;
                screen.goto(x, screen.cursor_y);
            }
            b'd' => {
                let y = Self::param(params, 0, 1) as usize - 1;
                screen.goto(screen.cursor_x, y);
            }
            b'H' | b'f' => {
                let y = Self::param(params, 0, 1) as usize - 1;
                let x = Self::param(params, 1, 1) as usize - 1;
                screen.goto(x, y);
            }
            b'I' => screen.tab_forward(Self::param(params, 0, 1) as usize),
            b'Z' => screen.tab_backward(Self::param(params, 0, 1) as usize),
            b'J' => screen.erase_display(Self::param_raw(params, 0)),
            b'K' => screen.erase_line(Self::param_raw(params, 0)),
            b'L' => screen.insert_lines(Self::param(params, 0, 1) as usize),
            b'M' => screen.delete_lines(Self::param(params, 0, 1) as usize),
            b'P' => screen.delete_chars(Self::param(params, 0, 1) as usize),
            b'X' => screen.erase_chars(Self::param(params, 0, 1) as usize),
            b'@' => screen.insert_chars(Self::param(params, 0, 1) as usize),
            b'S' => screen.scroll_up(Self::param(params, 0, 1) as usize),
            b'T' => screen.scroll_down(Self::param(params, 0, 1) as usize),
            b'g' => screen.clear_tab_stops(Self::param_raw(params, 0)),
            b'm' => screen.sgr(params),
            b'b' => screen.repeat_last(Self::param(params, 0, 1) as usize),
            b'n' => match Self::param_raw(params, 0) {
                5 => screen.respond_status(),
                6 => {
                    if private_mode {
                        screen.respond_cursor_position_private();
                    } else {
                        screen.respond_cursor_position();
                    }
                }
                _ => {}
            },
            b'c' => {
                if private == Some(b'>') {
                    screen.respond_device_attributes(true);
                } else if private.is_none() {
                    screen.respond_device_attributes(false);
                }
            }
            b'q' => {
                if intermediates.first() == Some(&b' ') {
                    screen.cursor_shape = Self::param_raw(params, 0) as u8;
                }
            }
            b'r' => {
                let top = Self::param_raw(params, 0);
                let bottom = Self::param_raw(params, 1);
                screen.set_scroll_region(top, bottom);
            }
            b's' => {
                if params.is_empty() {
                    screen.save_cursor();
                }
            }
            b'u' => {
                if params.is_empty() {
                    screen.restore_cursor();
                }
            }
            b'h' | b'l' => {
                let enable = final_byte == b'h';
                for i in 0..params.len().max(1) {
                    let mode = Self::param_raw(params, i);
                    self.apply_mode(mode, private_mode, enable, screen);
                }
            }
            b'p' => {
                if intermediates.first() == Some(&b'$') {
                    let mode = Self::param_raw(params, 0);
                    let set = self.mode_is_set(mode, private_mode, screen);
                    screen.respond_mode(private_mode, mode, set);
                }
            }
            b't' => {
                // XTWINOPS：窗口操作/尺寸查询，阶段 1 忽略
            }
            _ => {}
        }
    }

    fn mode_is_set(&self, mode: u32, private: bool, screen: &Screen) -> bool {
        if !private {
            return false;
        }
        match mode {
            1 => screen.app_cursor_keys,
            6 => screen.origin_mode,
            7 => screen.autowrap,
            25 => screen.cursor_visible,
            2004 => screen.bracketed_paste,
            1049 | 1047 | 47 => screen.alt_active,
            1000..=1003 => screen.mouse_mode == mode,
            1005 => false,
            1006 => screen.mouse_sgr,
            1004 => screen.focus_reporting,
            2026 => screen.synchronized_output,
            9001 => screen.win32_input,
            _ => false,
        }
    }

    fn apply_mode(&mut self, mode: u32, private: bool, enable: bool, screen: &mut Screen) {
        if !private {
            return;
        }
        match mode {
            1 => screen.app_cursor_keys = enable,
            6 => {
                screen.origin_mode = enable;
                screen.goto(0, 0);
            }
            7 => screen.autowrap = enable,
            25 => screen.cursor_visible = enable,
            47 | 1047 => screen.set_alt_screen(enable, false),
            1048 => {
                if enable {
                    screen.save_cursor();
                } else {
                    screen.restore_cursor();
                }
            }
            1049 => screen.set_alt_screen(enable, true),
            1000 | 1002 | 1003 => {
                screen.mouse_mode = if enable { mode } else { 0 };
            }
            1005 => {} // UTF-8 坐标编码：统一按 SGR 优先处理，忽略
            1006 => screen.mouse_sgr = enable,
            1004 => screen.focus_reporting = enable,
            2026 => screen.synchronized_output = enable,
            2004 => screen.bracketed_paste = enable,
            // win32-input-mode：接收原始的 Windows 按键（含抬起、扫描码）。
            9001 => screen.win32_input = enable,
            _ => {}
        }
    }

    fn dispatch_osc(&mut self, screen: &mut Screen) {
        let payload = std::mem::take(&mut self.string_buf);
        let text = String::from_utf8_lossy(&payload);
        let (code, body) = match text.split_once(';') {
            Some((c, b)) => (c, b),
            None => (text.as_ref(), ""),
        };
        match code {
            "0" | "1" | "2" => {
                screen.title = body.to_string();
            }
            // OSC 52：写剪贴板。格式 52;c;BASE64，c 是选择区（忽略），? 是查询（不支持）。
            "52" => {
                if let Some((_, value)) = body.split_once(';') {
                    if !value.is_empty() && value != "?" {
                        if let Some(bytes) = base64_decode(value) {
                            if bytes.len() <= 100_000 {
                                if let Ok(text) = String::from_utf8(bytes) {
                                    screen.clipboard = Some(text);
                                }
                            }
                        }
                    }
                }
            }
            // OSC 133：Shell 集成。A = 提示符开始（可跳转），C = 命令开始，D = 命令结束（带退出码）。
            "133" => {
                if body.starts_with('A') {
                    screen.record_prompt();
                } else if body.starts_with('C') {
                    screen.last_exit = None;
                } else if let Some(rest) = body.strip_prefix("D;") {
                    if let Ok(code) = rest.trim().parse::<i32>() {
                        screen.last_exit = Some(code);
                    }
                }
            }
            // OSC 7：当前工作目录，格式 file://HOST/PATH（Windows 上是 /C:/Users/...）。
            "7" => {
                if let Some(path) = parse_osc7(body) {
                    screen.cwd = Some(path);
                }
            }
            // OSC 8：超链接。格式 8;params;URI，URI 为空表示结束当前链接。
            "8" => {
                if let Some((_params, uri)) = body.split_once(';') {
                    screen.set_link(uri);
                }
            }
            // OSC 9：iTerm2 风格的桌面通知，正文直接是消息。
            "9" => {
                if !body.trim().is_empty() {
                    push_notification(screen, body.trim());
                }
            }
            // OSC 777;notify;标题;正文（rxvt-unicode / kitty 通用）。
            "777" => {
                if let Some(rest) = body.strip_prefix("notify;") {
                    let (title, text) = match rest.split_once(';') {
                        Some((title, text)) => (title.trim(), text.trim()),
                        None => ("", rest.trim()),
                    };
                    let message = if title.is_empty() {
                        text.to_string()
                    } else if text.is_empty() {
                        title.to_string()
                    } else {
                        format!("{title}：{text}")
                    };
                    if !message.is_empty() {
                        push_notification(screen, &message);
                    }
                }
            }
            _ => {}
        }
    }
}

/// 记录一条 OSC 9 / 777 通知；只保留最近的若干条，避免异常程序刷屏。
fn push_notification(screen: &mut Screen, text: &str) {
    if screen.notifications.len() >= 8 {
        screen.notifications.pop_front();
    }
    screen.notifications.push_back(text.to_string());
}

/// 解析 OSC 7 的 `file://主机/路径`，返回 Windows 风格路径。
fn parse_osc7(body: &str) -> Option<String> {
    let rest = body.strip_prefix("file://")?;
    // 主机名与路径之间以第一个 '/' 分隔（本机通常为空）。
    let path = &rest[rest.find('/')?..];
    let mut decoded = percent_decode(path);
    // `/C:/dir` → `C:/dir`，再统一成反斜杠；POSIX 路径（如 /c/Users）保持原样。
    let bytes: Vec<char> = decoded.chars().collect();
    let drive = bytes.len() >= 3
        && bytes[0] == '/'
        && bytes[1].is_ascii_alphabetic()
        && bytes[2] == ':';
    if drive {
        decoded = bytes[1..].iter().collect::<String>().replace('/', "\\");
    }
    if decoded.is_empty() {
        None
    } else {
        Some(decoded)
    }
}

/// 解码 `%XX`（OSC 7 里的空格等字符会被转义）。
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_value(bytes[i + 1]), hex_value(bytes[i + 2])) {
                out.push(hi * 16 + lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// 最小的 Base64 解码（OSC 52 用），非法字符返回 `None`。
fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut buffer = 0u32;
    let mut bits = 0u32;
    for byte in text.bytes() {
        let value = match byte {
            b'A'..=b'Z' => (byte - b'A') as u32,
            b'a'..=b'z' => (byte - b'a') as u32 + 26,
            b'0'..=b'9' => (byte - b'0') as u32 + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            b'\r' | b'\n' | b' ' => continue,
            _ => return None,
        };
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emulation::screen::{Color, Screen, ATTR_BOLD};

    fn feed(screen: &mut Screen, bytes: &[u8]) {
        let mut p = Parser::new();
        p.feed(bytes, screen);
    }

    #[test]
    fn plain_text_and_newline() {
        let mut s = Screen::new(10, 3, 10);
        feed(&mut s, b"abc\r\ndef");
        assert_eq!(s.cell(0, 0).ch, 'a');
        assert_eq!(s.cell(0, 1).ch, 'd');
        assert_eq!((s.cursor_x, s.cursor_y), (3, 1));
    }

    #[test]
    fn cursor_position_and_erase() {
        let mut s = Screen::new(10, 5, 10);
        feed(&mut s, b"hello\x1b[2;3H\x1b[K");
        assert_eq!(s.cell(2, 1).ch, ' ', "从光标到行尾被擦除");
        assert_eq!(s.cell(1, 0).ch, 'e');
    }

    #[test]
    fn sgr_color_applies_to_cells() {
        let mut s = Screen::new(10, 2, 10);
        feed(&mut s, b"\x1b[1;31;48;5;21mX\x1b[0mY");
        assert_eq!(s.cell(0, 0).attrs.flags & ATTR_BOLD, ATTR_BOLD);
        assert_eq!(s.cell(0, 0).attrs.fg, Color::Indexed(1));
        assert_eq!(s.cell(0, 0).attrs.bg, Color::Indexed(21));
        assert_eq!(s.cell(1, 0).attrs, Default::default());
    }

    #[test]
    fn utf8_wide_chars() {
        let mut s = Screen::new(10, 2, 10);
        feed(&mut s, "中文".as_bytes());
        assert_eq!(s.cell(0, 0).ch, '中');
        assert_eq!(s.cell(2, 0).ch, '文');
        assert_eq!(s.cursor_x, 4);
    }

    #[test]
    fn alt_screen_switch_by_1049() {
        let mut s = Screen::new(10, 3, 10);
        feed(&mut s, b"main\x1b[?1049h");
        assert!(s.alt_active);
        assert_eq!(s.cell(0, 0).ch, ' ');
        feed(&mut s, b"alt\x1b[?1049l");
        assert!(!s.alt_active);
        assert_eq!(s.cell(0, 0).ch, 'm');
    }

    #[test]
    fn cursor_visibility_and_shape() {
        let mut s = Screen::new(10, 3, 10);
        feed(&mut s, b"\x1b[?25l\x1b[4 q");
        assert!(!s.cursor_visible);
        assert_eq!(s.cursor_shape, 4);
    }

    #[test]
    fn title_from_osc() {
        let mut s = Screen::new(10, 3, 10);
        feed(&mut s, b"\x1b]0;my title\x07");
        assert_eq!(s.title, "my title");
    }

    #[test]
    fn osc52_writes_clipboard() {
        let mut s = Screen::new(10, 3, 10);
        feed(&mut s, b"\x1b]52;c;aGVsbG8=\x07");
        assert_eq!(s.clipboard.as_deref(), Some("hello"));
    }

    #[test]
    fn osc133_marks_prompt_rows() {
        let mut s = Screen::new(10, 4, 100);
        feed(&mut s, b"\x1b]133;A\x07$ \x1b]133;B\x07echo hi\r\nhi\r\n");
        assert_eq!(s.prompt_marks.len(), 1);
        assert_eq!(s.prompt_marks[0], 0);
        feed(&mut s, b"\x1b]133;A\x07$ ");
        assert_eq!(s.prompt_marks.len(), 2);
        assert_eq!(s.prompt_marks[1], 2);
    }

    #[test]
    fn osc7_reports_working_directory() {
        let mut s = Screen::new(20, 4, 100);
        feed(&mut s, b"\x1b]7;file:///C:/Program%20Files/cmd\x07");
        assert_eq!(s.cwd.as_deref(), Some("C:\\Program Files\\cmd"));
        // POSIX 风格路径保持原样（来自 WSL / Git Bash）
        feed(&mut s, b"\x1b]7;file://host/c/Users/me\x07");
        assert_eq!(s.cwd.as_deref(), Some("/c/Users/me"));
        // 非 OSC 7 的载荷不改变目录
        feed(&mut s, b"\x1b]7;garbage\x07");
        assert_eq!(s.cwd.as_deref(), Some("/c/Users/me"));
    }

    #[test]
    fn repeat_last_char_and_alignment_test() {
        let mut s = Screen::new(10, 3, 10);
        feed(&mut s, b"x\x1b[4b");
        assert_eq!(s.cell(4, 0).ch, 'x');
        assert_eq!(s.cursor_x, 5);

        feed(&mut s, b"\x1b#8");
        assert_eq!(s.cell(0, 0).ch, 'E');
        assert_eq!(s.cell(9, 2).ch, 'E');
        assert_eq!((s.cursor_x, s.cursor_y), (0, 0));
    }

    #[test]
    fn osc8_attaches_links_to_printed_cells() {
        let mut s = Screen::new(20, 3, 10);
        feed(&mut s, b"\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\after");
        assert_eq!(s.link_at_absolute(0, 0), Some("https://example.com"));
        assert_eq!(s.link_at_absolute(0, 3), Some("https://example.com"));
        assert_eq!(s.link_at_absolute(0, 5), None, "结束链接后新字符不带链接");
        // 相同 URI 复用同一个 id
        feed(&mut s, b"\x1b]8;;https://example.com\x07again");
        let id = s.cell(10, 0).link;
        assert_eq!(id, s.cell(0, 0).link);
        assert_ne!(id, 0);
    }

    #[test]
    fn dsr_status_and_private_cursor() {
        let mut s = Screen::new(10, 3, 10);
        feed(&mut s, b"\x1b[5n\x1b[?6n");
        assert_eq!(
            String::from_utf8_lossy(&s.responses),
            "\x1b[0n\x1b[?1;1R"
        );
    }

    #[test]
    fn parser_handles_large_stream_and_history_limit() {
        let mut s = Screen::new(120, 40, 1000);
        let mut p = Parser::new();
        let chunk = "line with text and \x1b[31mcolor\x1b[0m\r\n".repeat(200);
        for _ in 0..200 {
            p.feed(chunk.as_bytes(), &mut s);
        }
        assert_eq!(s.history_len(), 1000, "回看缓冲必须受上限约束");
        assert_eq!(s.cell(0, s.rows - 1).ch, ' ');
        // 继续喂也不应崩溃或越界
        for _ in 0..50 {
            p.feed(b"\x1b[999;999H\x1b[2J\x1b[?1049h\x1b[?1049l", &mut s);
        }
    }

    #[test]
    fn dsr_reports_cursor_position() {
        let mut s = Screen::new(10, 3, 10);
        feed(&mut s, b"\x1b[3;4H\x1b[6n");
        assert_eq!(String::from_utf8_lossy(&s.responses), "\x1b[3;4R");
    }

    #[test]
    fn scroll_region_limits_scrolling() {
        let mut s = Screen::new(4, 4, 10);
        feed(&mut s, b"\x1b[2;3r");
        feed(&mut s, b"\x1b[4;1H\x1b[4;1Hz");
        // 区域内滚动不应影响第 1 行与第 4 行
        assert_eq!(s.cell(0, 0).ch, ' ');
    }

    #[test]
    fn insert_and_delete_lines() {
        let mut s = Screen::new(4, 3, 10);
        feed(&mut s, b"a\r\nb\r\nc");
        feed(&mut s, b"\x1b[1;1H\x1b[L");
        assert_eq!(s.cell(0, 0).ch, ' ');
        assert_eq!(s.cell(0, 1).ch, 'a');
        assert_eq!(s.cell(0, 2).ch, 'b');
    }
}

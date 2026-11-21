//! Vim 模态编辑引擎：模式、动作、操作符、文本对象、寄存器、宏、`.` 重复。
//!
//! 引擎只操作 [`Document`]，不依赖界面；App 负责把按键交给它，
//! 并处理它返回的 [`Action`]（Ex 命令行、搜索、分屏、滚动等）。

use std::collections::HashMap;

use super::document::{Document, Pos};
use crate::platform::console::{Key, KeyCode, Mods};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Normal,
    Insert,
    Visual,
    VisualLine,
    VisualBlock,
    Replace,
}

impl Mode {
    pub fn label(self) -> &'static str {
        match self {
            Mode::Normal => "普通",
            Mode::Insert => "插入",
            Mode::Visual => "可视",
            Mode::VisualLine => "可视行",
            Mode::VisualBlock => "可视块",
            Mode::Replace => "替换",
        }
    }

    pub fn is_visual(self) -> bool {
        matches!(self, Mode::Visual | Mode::VisualLine | Mode::VisualBlock)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Op {
    Delete,
    Change,
    Yank,
    Indent,
    Outdent,
    Upper,
    Lower,
    ToggleCase,
}

/// 引擎返回给 App 的额外动作（不能在引擎内部完成的部分）。
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Action {
    None,
    /// 打开 `:` / `/` / `?` 命令行，参数是前缀字符。
    Cmdline(char),
    /// 搜索：模式、是否向前。
    Search(String, bool),
    /// 半页滚动：true 向下。
    ScrollHalf(bool),
    /// 分屏：true 为左右分栏。
    Split(bool),
    /// 关闭分屏。
    OnlyOne,
    /// 切换分屏焦点。
    OtherPane,
    /// 切换标签：+1 / -1。
    Tab(i32),
    /// 需要 App 刷新（行缓存、高亮、状态栏）。
    Changed,
    Message(String),
}

/// 可序列化的按键（宏与 `.` 重复用）。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct VimKey {
    pub code: KeyCode,
    pub mods: Mods,
}

impl VimKey {
    pub fn from_key(key: Key) -> VimKey {
        VimKey {
            code: key.code,
            mods: key.mods,
        }
    }

    pub fn to_key(self) -> Key {
        Key {
            code: self.code,
            mods: self.mods,
        }
    }

    pub fn label(self) -> String {
        let mut out = String::new();
        if self.mods.ctrl {
            out.push_str("C-");
        }
        if self.mods.alt {
            out.push_str("M-");
        }
        match self.code {
            KeyCode::Char(c) => out.push(c),
            KeyCode::Enter => out.push_str("CR"),
            KeyCode::Tab => out.push_str("Tab"),
            KeyCode::Backspace => out.push_str("BS"),
            KeyCode::Esc => out.push_str("Esc"),
            KeyCode::Up => out.push_str("Up"),
            KeyCode::Down => out.push_str("Down"),
            KeyCode::Left => out.push_str("Left"),
            KeyCode::Right => out.push_str("Right"),
            KeyCode::Home => out.push_str("Home"),
            KeyCode::End => out.push_str("End"),
            KeyCode::PageUp => out.push_str("PgUp"),
            KeyCode::PageDown => out.push_str("PgDn"),
            KeyCode::Insert => out.push_str("Ins"),
            KeyCode::Delete => out.push_str("Del"),
            KeyCode::F(n) => out.push_str(&format!("F{n}")),
            KeyCode::Unknown(_) => out.push('?'),
        }
        out
    }
}

/// 待输入的后续按键（f/t/r/m/q 等）。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Pending {
    None,
    /// 等待一个字符作为动作参数。
    Char(CharUse),
    /// 等待一个字符作为寄存器名。
    Register,
    /// 等待一个文本对象选择符之后的字符（i/a 已按过）。
    TextObject(Op, bool),
    /// `g` 前缀。
    G,
    /// `q` 等待寄存器名。
    Record,
    /// `@` 等待寄存器名。
    Play,
    /// `m` / `` ` `` / `'` 等待标记名。
    Mark(MarkUse),
    /// `"` 之后的操作符已被前面的按键缓存。
    Operator(Op),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum CharUse {
    Find(bool, bool),    // 向前, till
    Replace,
    None,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum MarkUse {
    Set,
    JumpExact,
    JumpLine,
}

pub struct Vim {
    pub mode: Mode,
    pub pending: String,
    op: Option<Op>,
    count: usize,
    digits: String,
    register: char,
    pending_state: Pending,
    /// 已按下的 `g` 前缀后的按键数（gg 需要）。
    target_col: Option<usize>,
    registers: HashMap<char, (String, bool)>,
    macros: HashMap<char, Vec<VimKey>>,
    recording: Option<char>,
    macro_buf: Vec<VimKey>,
    last_change: Option<Vec<VimKey>>,
    span: Vec<VimKey>,
    span_changed: bool,
    suppress_change: bool,
    playing: bool,
    /// 上一次 f/t 的字符与方向，供 `;` / `,` 使用。
    last_find: Option<(char, bool, bool)>,
    pub last_search: Option<(String, bool)>,
    visual_anchor: Option<Pos>,
    visual_block_col: usize,
    last_visual: Option<(Pos, Pos, Mode)>,
    marks: HashMap<char, Pos>,
    /// 当前一次操作前的内容版本，用于判断是否真的改了文档。
    revision_before: u64,
    pub last_message: String,
}

impl Default for Vim {
    fn default() -> Self {
        Vim::new()
    }
}

impl Vim {
    pub fn new() -> Vim {
        Vim {
            mode: Mode::Normal,
            pending: String::new(),
            op: None,
            count: 0,
            digits: String::new(),
            register: '"',
            pending_state: Pending::None,
            target_col: None,
            registers: HashMap::new(),
            macros: HashMap::new(),
            recording: None,
            macro_buf: Vec::new(),
            last_change: None,
            span: Vec::new(),
            span_changed: false,
            suppress_change: false,
            playing: false,
            last_find: None,
            last_search: None,
            visual_anchor: None,
            visual_block_col: 0,
            last_visual: None,
            marks: HashMap::new(),
            revision_before: 0,
            last_message: String::new(),
        }
    }

    pub fn register_names(&self) -> Vec<char> {
        let mut names: Vec<char> = self.registers.keys().copied().filter(|c| *c != '"').collect();
        names.sort_unstable();
        names
    }

    /// 上一次可视模式的范围（供 `:'<,'>s` 使用）。
    pub fn last_visual(&self) -> Option<(Pos, Pos)> {
        self.last_visual.map(|(start, end, _)| (start, end))
    }

    /// 供 `:normal` 使用：把一段按键直接交给引擎。
    pub fn feed_keys(&mut self, doc: &mut Document, keys: &str, tab_width: usize) {
        for ch in keys.chars() {
            let key = Key {
                code: KeyCode::Char(ch),
                mods: Mods::none(),
            };
            self.dispatch(key, doc, tab_width);
            if self.mode == Mode::Insert {
                doc.insert_text(&ch.to_string());
            }
        }
        if self.mode == Mode::Insert {
            self.mode = Mode::Normal;
        }
    }

    /// 主入口：处理一个按键。返回需要 App 执行的动作。
    pub fn handle(&mut self, key: Key, doc: &mut Document, tab_width: usize) -> Action {
        self.revision_before = doc.revision;
        self.last_message.clear();

        if !self.playing && self.mode != Mode::Insert {
            self.span.push(VimKey::from_key(key));
        }

        // 宏录制：记录除结束键以外的全部按键。
        if self.recording.is_some()
            && !(self.mode == Mode::Normal
                && self.pending_state == Pending::None
                && is_char(&key, 'q')
                && key.mods == Mods::none())
        {
            self.macro_buf.push(VimKey::from_key(key));
        }

        let action = self.dispatch(key, doc, tab_width);
        let action = if action == Action::None && doc.revision != self.revision_before {
            Action::Changed
        } else {
            action
        };
        self.settle(doc);
        action
    }

    /// 插入模式下的按键记录（App 仍用原有输入逻辑）。
    pub fn record_insert_key(&mut self, key: Key) {
        if self.mode != Mode::Insert && self.mode != Mode::Replace {
            return;
        }
        self.span.push(VimKey::from_key(key));
        if let Some(name) = self.recording {
            if name != 'q' {
                self.macro_buf.push(VimKey::from_key(key));
            }
        }
    }

    /// 插入模式结束：判断这次插入是否算一次可重复的修改。
    pub fn finish_insert(&mut self, doc: &mut Document) {
        if doc.revision != self.revision_before {
            self.span_changed = true;
        }
        self.mode = Mode::Normal;
        self.pending_state = Pending::None;
        self.op = None;
        self.settle(doc);
    }

    fn settle(&mut self, doc: &mut Document) {
        if doc.revision != self.revision_before {
            self.span_changed = true;
        }
        let busy = self.op.is_some()
            || !self.digits.is_empty()
            || !matches!(self.pending_state, Pending::None)
            || self.mode.is_visual();
        if !busy && self.mode != Mode::Insert && self.mode != Mode::Replace {
            if self.span_changed && !self.suppress_change {
                let span = std::mem::take(&mut self.span);
                if !span.is_empty() {
                    self.last_change = Some(span);
                }
            } else if !self.span_changed {
                self.span.clear();
            }
            self.span_changed = false;
            self.pending.clear();
            self.count = 0;
            self.digits.clear();
        }
        self.suppress_change = false;
        self.update_pending();
    }

    fn update_pending(&mut self) {
        let mut text = String::new();
        text.push_str(&self.digits);
        if let Some(op) = self.op {
            text.push(match op {
                Op::Delete => 'd',
                Op::Change => 'c',
                Op::Yank => 'y',
                Op::Indent => '>',
                Op::Outdent => '<',
                Op::Upper => 'U',
                Op::Lower => 'u',
                Op::ToggleCase => '~',
            });
        }
        match self.pending_state {
            Pending::None => {}
            Pending::Char(_) => text.push('…'),
            Pending::Register => text.push('"'),
            Pending::TextObject(_, _) => text.push('i'),
            Pending::G => text.push('g'),
            Pending::Record => text.push('q'),
            Pending::Play => text.push('@'),
            Pending::Mark(_) => text.push('m'),
            Pending::Operator(_) => {}
        }
        self.pending = text;
    }

    fn take_count(&mut self) -> usize {
        let count = if self.digits.is_empty() {
            1
        } else {
            self.digits.parse::<usize>().unwrap_or(1).max(1)
        };
        self.digits.clear();
        count
    }

    // ------------------------------------------------------------ 分发

    fn dispatch(&mut self, key: Key, doc: &mut Document, tab_width: usize) -> Action {
        // 数字前缀（0 在没有前缀时是行首动作）。
        if let KeyCode::Char(c) = key.code {
            if key.mods == Mods::none() {
                if c.is_ascii_digit() && (c != '0' || !self.digits.is_empty()) {
                    if self.digits.is_empty() && c == '0' {
                        // 落到下面按动作为 0 处理
                    } else {
                        self.digits.push(c);
                        self.update_pending();
                        return Action::None;
                    }
                }
            }
        }

        match self.pending_state {
            Pending::Register => {
                self.pending_state = Pending::None;
                if let KeyCode::Char(c) = key.code {
                    self.register = c;
                }
                return Action::None;
            }
            Pending::G => {
                self.pending_state = Pending::None;
                return self.handle_g(key, doc, tab_width);
            }
            Pending::Char(use_) => {
                self.pending_state = Pending::None;
                if let KeyCode::Char(c) = key.code {
                    return self.handle_char_arg(c, use_, doc);
                }
                return Action::None;
            }
            Pending::TextObject(op, inner) => {
                self.pending_state = Pending::None;
                if let KeyCode::Char(c) = key.code {
                    return self.apply_text_object(op, inner, c, doc, tab_width);
                }
                return Action::None;
            }
            Pending::Record => {
                self.pending_state = Pending::None;
                if let KeyCode::Char(c) = key.code {
                    self.recording = Some(c);
                    self.macro_buf.clear();
                    self.last_message = format!("录制 @{c}");
                }
                return Action::None;
            }
            Pending::Play => {
                self.pending_state = Pending::None;
                if let KeyCode::Char('@') = key.code {
                    return self.play_macro(None, doc, tab_width);
                }
                if let KeyCode::Char(c) = key.code {
                    return self.play_macro(Some(c), doc, tab_width);
                }
                return Action::None;
            }
            Pending::Mark(use_) => {
                self.pending_state = Pending::None;
                if let KeyCode::Char(c) = key.code {
                    return self.handle_mark(use_, c, doc);
                }
                return Action::None;
            }
            Pending::Operator(op) => {
                self.pending_state = Pending::None;
                self.op = Some(op);
                return self.dispatch(key, doc, tab_width);
            }
            Pending::None => {}
        }

        match self.mode {
            Mode::Insert | Mode::Replace => Action::None,
            Mode::Normal => self.normal_key(key, doc, tab_width),
            Mode::Visual | Mode::VisualLine | Mode::VisualBlock => {
                self.visual_key(key, doc, tab_width)
            }
        }
    }

    fn normal_key(&mut self, key: Key, doc: &mut Document, tab_width: usize) -> Action {
        use KeyCode::*;
        let m = key.mods;
        let count = self.take_count();

        if m.ctrl {
            return match key.code {
                Char('d') => Action::ScrollHalf(true),
                Char('u') => Action::ScrollHalf(false),
                Char('r') => {
                    self.suppress_change = true;
                    if doc.redo() {
                        Action::Changed
                    } else {
                        Action::Message("没有可重做的修改".into())
                    }
                }
                Char('v') => {
                    self.mode = Mode::VisualBlock;
                    self.visual_anchor = Some(doc.primary().pos);
                    self.visual_block_col = doc.primary().pos.col;
                    Action::None
                }
                Char('w') => Action::OtherPane,
                Char('o') => Action::None,
                Char('i') => Action::None,
                _ => Action::None,
            };
        }

        // 操作符已挂起：等待动作。
        if let Some(op) = self.op {
            return self.operator_motion(op, key, count, doc, tab_width);
        }

        let Some(ch) = ch_of(&key) else {
            return Action::None;
        };
        match ch {
            // ---- 模式切换
            'i' => self.enter_insert(doc, InsertAt::Before, count),
            'a' => self.enter_insert(doc, InsertAt::After, count),
            'I' => self.enter_insert(doc, InsertAt::LineStart, count),
            'A' => self.enter_insert(doc, InsertAt::LineEnd, count),
            'o' => {
                let line = doc.primary().pos.line;
                let len = doc.line_chars(line);
                doc.set_cursor(Pos::new(line, len));
                doc.insert_text("\n");
                self.enter_insert(doc, InsertAt::Here, 1);
                Action::Changed
            }
            'O' => {
                let line = doc.primary().pos.line;
                doc.set_cursor(Pos::new(line, 0));
                doc.insert_text("\n");
                doc.set_cursor(Pos::new(line, 0));
                self.enter_insert(doc, InsertAt::Here, 1);
                Action::Changed
            }
            'v' => {
                self.mode = Mode::Visual;
                self.visual_anchor = Some(doc.primary().pos);
                self.visual_block_col = doc.primary().pos.col;
                Action::None
            }
            'V' => {
                self.mode = Mode::VisualLine;
                self.visual_anchor = Some(doc.primary().pos);
                doc.select_line(doc.primary().pos.line);
                self.visual_block_col = doc.primary().pos.col;
                Action::None
            }
            '\u{16}' => {
                // Ctrl+V 会以控制字符到达，兜底处理
                self.mode = Mode::VisualBlock;
                self.visual_anchor = Some(doc.primary().pos);
                self.visual_block_col = doc.primary().pos.col;
                Action::None
            }
            // ---- 插入
            'R' => {
                self.mode = Mode::Replace;
                Action::None
            }
            // ---- 操作符
            'd' => {
                self.op = Some(Op::Delete);
                self.digits = count.to_string();
                self.update_pending();
                Action::None
            }
            'c' => {
                self.op = Some(Op::Change);
                self.digits = count.to_string();
                self.update_pending();
                Action::None
            }
            'y' => {
                self.op = Some(Op::Yank);
                self.digits = count.to_string();
                self.update_pending();
                Action::None
            }
            '>' => {
                self.op = Some(Op::Indent);
                self.digits = count.to_string();
                self.update_pending();
                Action::None
            }
            '<' => {
                self.op = Some(Op::Outdent);
                self.digits = count.to_string();
                self.update_pending();
                Action::None
            }
            '~' => {
                self.toggle_char(count, doc)
            }
            // ---- 动作
            'h' | 'j' | 'k' | 'l' | 'w' | 'W' | 'b' | 'B' | 'e' | 'E' | '0' | '^' | '$'
            | 'G' | '}' | '{' | '%' | '+' | '-' | '_' | ';' | ',' | '|' => {
                self.move_with(ch, count, doc)
            }
            'g' => {
                self.pending_state = Pending::G;
                self.digits = count.to_string();
                Action::None
            }
            'f' => {
                self.pending_state = Pending::Char(CharUse::Find(true, false));
                self.digits = count.to_string();
                Action::None
            }
            'F' => {
                self.pending_state = Pending::Char(CharUse::Find(false, false));
                self.digits = count.to_string();
                Action::None
            }
            't' => {
                self.pending_state = Pending::Char(CharUse::Find(true, true));
                self.digits = count.to_string();
                Action::None
            }
            'T' => {
                self.pending_state = Pending::Char(CharUse::Find(false, true));
                self.digits = count.to_string();
                Action::None
            }
            'm' => {
                self.pending_state = Pending::Mark(MarkUse::Set);
                Action::None
            }
            '`' => {
                self.pending_state = Pending::Mark(MarkUse::JumpExact);
                Action::None
            }
            '\'' => {
                self.pending_state = Pending::Mark(MarkUse::JumpLine);
                Action::None
            }
            // ---- 编辑
            'x' => {
                let mut action = Action::None;
                for _ in 0..count {
                    let pos = doc.primary().pos;
                    let len = doc.line_chars(pos.line);
                    if len == 0 {
                        break;
                    }
                    if pos.col < len {
                        let end = Pos::new(pos.line, pos.col + 1);
                        let text = doc.slice(pos, end);
                        self.store('"', text, false);
                        doc.replace_ranges(&[(pos, end)], "");
                        action = Action::Changed;
                    }
                }
                action
            }
            'X' => {
                let pos = doc.primary().pos;
                if pos.col > 0 {
                    let start = Pos::new(pos.line, pos.col - count.min(pos.col));
                    doc.replace_ranges(&[(start, pos)], "");
                    Action::Changed
                } else {
                    Action::None
                }
            }
            'D' => {
                let pos = doc.primary().pos;
                let end = Pos::new(pos.line, doc.line_chars(pos.line));
                if pos.col < end.col {
                    doc.replace_ranges(&[(pos, end)], "");
                    Action::Changed
                } else {
                    Action::None
                }
            }
            'C' => {
                let pos = doc.primary().pos;
                let end = Pos::new(pos.line, doc.line_chars(pos.line));
                doc.replace_ranges(&[(pos, end)], "");
                self.enter_insert(doc, InsertAt::Here, 1);
                Action::Changed
            }
            's' => {
                let pos = doc.primary().pos;
                let len = doc.line_chars(pos.line);
                let end = Pos::new(pos.line, (pos.col + count).min(len));
                if end.col > pos.col {
                    doc.replace_ranges(&[(pos, end)], "");
                }
                self.enter_insert(doc, InsertAt::Here, 1);
                Action::Changed
            }
            'S' => {
                let line = doc.primary().pos.line;
                let len = doc.line_chars(line);
                doc.replace_ranges(&[(Pos::new(line, 0), Pos::new(line, len))], "");
                self.enter_insert(doc, InsertAt::Here, 1);
                Action::Changed
            }
            'p' => self.paste(false, count, doc, tab_width),
            'P' => self.paste(true, count, doc, tab_width),
            'u' => {
                self.suppress_change = true;
                if doc.undo() {
                    Action::Changed
                } else {
                    Action::Message("已到最早的修改".into())
                }
            }
            'r' => {
                self.pending_state = Pending::Char(CharUse::Replace);
                self.digits = count.to_string();
                Action::None
            }
            'J' => {
                let mut changed = false;
                for _ in 0..count {
                    if doc.join_lines() {
                        changed = true;
                    } else {
                        break;
                    }
                }
                if changed {
                    Action::Changed
                } else {
                    Action::None
                }
            }
            '.' => {
                if let Some(keys) = self.last_change.clone() {
                    self.replay(keys, doc, tab_width);
                    Action::Changed
                } else {
                    Action::Message("没有可重复的修改".into())
                }
            }
            'q' => {
                if self.recording.is_some() {
                    if let Some(name) = self.recording.take() {
                        let buf = std::mem::take(&mut self.macro_buf);
                        self.macros.insert(name, buf);
                        self.last_message = format!("已录制 @{name}");
                    }
                } else {
                    self.pending_state = Pending::Record;
                }
                Action::None
            }
            '@' => {
                self.pending_state = Pending::Play;
                Action::None
            }
            '"' => {
                self.pending_state = Pending::Register;
                Action::None
            }
            'n' => {
                if let Some((pattern, _)) = self.last_search.clone() {
                    Action::Search(pattern, true)
                } else {
                    Action::Message("没有搜索模式".into())
                }
            }
            'N' => {
                if let Some((pattern, _)) = self.last_search.clone() {
                    Action::Search(pattern, false)
                } else {
                    Action::Message("没有搜索模式".into())
                }
            }
            '/' => Action::Cmdline('/'),
            '?' => Action::Cmdline('?'),
            ':' => Action::Cmdline(':'),
            'K' => Action::None,
            'Q' => Action::None,
            '*' => {
                // 搜索光标下的词
                let pos = doc.primary().pos;
                let text = doc.line(pos.line);
                let chars: Vec<char> = text.chars().collect();
                let mut start = pos.col.min(chars.len());
                while start > 0 && is_word(chars[start - 1]) {
                    start -= 1;
                }
                let mut end = pos.col.min(chars.len());
                while end < chars.len() && is_word(chars[end]) {
                    end += 1;
                }
                if start < end {
                    let word: String = chars[start..end].iter().collect();
                    self.last_search = Some((word.clone(), true));
                    Action::Search(word, true)
                } else {
                    Action::None
                }
            }
            '#' => {
                let pos = doc.primary().pos;
                let text = doc.line(pos.line);
                let chars: Vec<char> = text.chars().collect();
                let mut start = pos.col.min(chars.len());
                while start > 0 && is_word(chars[start - 1]) {
                    start -= 1;
                }
                let mut end = pos.col.min(chars.len());
                while end < chars.len() && is_word(chars[end]) {
                    end += 1;
                }
                if start < end {
                    let word: String = chars[start..end].iter().collect();
                    self.last_search = Some((word.clone(), true));
                    Action::Search(word, false)
                } else {
                    Action::None
                }
            }
            _ => Action::None,
        }
    }

    fn handle_g(&mut self, key: Key, doc: &mut Document, _tab_width: usize) -> Action {
        let count = self.take_count();
        let Some(ch) = ch_of(&key) else {
            return Action::None;
        };
        match ch {
            'g' => {
                let line = if count == 1 {
                    0
                } else {
                    (count - 1).min(doc.line_count().saturating_sub(1))
                };
                doc.set_cursor(Pos::new(line, first_non_blank(doc, line)));
                Action::Changed
            }
            'e' => self.move_with('E', count, doc),
            'E' => self.move_with('E', count, doc),
            'j' => self.move_with('j', count, doc),
            'k' => self.move_with('k', count, doc),
            't' => Action::Tab(1),
            'T' => Action::Tab(-1),
            'v' => {
                self.mode = Mode::Visual;
                self.visual_anchor = self.last_visual.as_ref().map(|v| v.0);
                if let Some((start, end, _)) = self.last_visual.clone() {
                    doc.set_cursor(start);
                    doc.move_cursor(end, true);
                }
                Action::None
            }
            '~' => {
                self.op = Some(Op::ToggleCase);
                self.digits = count.to_string();
                self.update_pending();
                Action::None
            }
            'u' => {
                self.op = Some(Op::Lower);
                self.digits = count.to_string();
                self.update_pending();
                Action::None
            }
            'U' => {
                self.op = Some(Op::Upper);
                self.digits = count.to_string();
                self.update_pending();
                Action::None
            }
            'd' => Action::Message("gd：跳转到定义".into()),
            _ => Action::None,
        }
    }

    fn handle_char_arg(&mut self, c: char, use_: CharUse, doc: &mut Document) -> Action {
        let count = self.take_count();
        match use_ {
            CharUse::Find(forward, till) => {
                self.last_find = Some((c, forward, till));
                self.find_char(c, forward, till, count, doc)
            }
            CharUse::Replace => {
                let pos = doc.primary().pos;
                let len = doc.line_chars(pos.line);
                if pos.col < len {
                    let end = Pos::new(pos.line, (pos.col + count).min(len));
                    let text: String = c.to_string().repeat(end.col - pos.col);
                    doc.replace_ranges(&[(pos, end)], &text);
                    Action::Changed
                } else {
                    Action::None
                }
            }
            CharUse::None => Action::None,
        }
    }

    fn handle_mark(&mut self, use_: MarkUse, c: char, doc: &mut Document) -> Action {
        match use_ {
            MarkUse::Set => {
                self.marks.insert(c, doc.primary().pos);
                Action::None
            }
            MarkUse::JumpExact | MarkUse::JumpLine => {
                if let Some(pos) = self.marks.get(&c).copied() {
                    let target = if use_ == MarkUse::JumpLine {
                        Pos::new(pos.line, first_non_blank(doc, pos.line))
                    } else {
                        pos
                    };
                    doc.set_cursor(target);
                    Action::Changed
                } else {
                    Action::Message(format!("标记 {c} 未设置"))
                }
            }
        }
    }

    fn enter_insert(&mut self, doc: &mut Document, at: InsertAt, count: usize) -> Action {
        let pos = doc.primary().pos;
        match at {
            InsertAt::Before => {}
            InsertAt::After => {
                let len = doc.line_chars(pos.line);
                doc.set_cursor(Pos::new(pos.line, (pos.col + 1).min(len)));
            }
            InsertAt::LineStart => {
                doc.set_cursor(Pos::new(pos.line, first_non_blank(doc, pos.line)));
            }
            InsertAt::LineEnd => {
                let len = doc.line_chars(pos.line);
                doc.set_cursor(Pos::new(pos.line, len));
            }
            InsertAt::Here => {}
        }
        // `3i` 之类的重复插入
        if count > 1 {
            let text = self.last_insert_text().unwrap_or_default();
            if !text.is_empty() {
                doc.insert_text(&text.repeat(count - 1));
            }
        }
        self.mode = Mode::Insert;
        self.visual_anchor = None;
        self.update_pending();
        Action::Changed
    }

    fn last_insert_text(&self) -> Option<String> {
        let keys = self.last_change.as_ref()?;
        let mut text = String::new();
        for key in keys {
            if let KeyCode::Char(c) = key.code {
                if key.mods == Mods::none() {
                    text.push(c);
                }
            }
        }
        Some(text)
    }

    fn move_with(&mut self, ch: char, count: usize, doc: &mut Document) -> Action {
        if ch == ';' || ch == ',' {
            if let Some((c, forward, till)) = self.last_find {
                let forward = if ch == ',' { !forward } else { forward };
                return self.find_char(c, forward, till, count, doc);
            }
            return Action::None;
        }
        let from = doc.primary().pos;
        let result = match ch {
            'h' => Some((move_left(from, count), false)),
            'l' => Some((move_right(doc, from, count), false)),
            'j' => Some((move_down(doc, from, count), true)),
            'k' => Some((move_up(doc, from, count), true)),
            'w' => Some((word_forward(doc, from, count, false), false)),
            'W' => Some((word_forward(doc, from, count, true), false)),
            'b' => Some((word_backward(doc, from, count, false), false)),
            'B' => Some((word_backward(doc, from, count, true), false)),
            'e' => Some((word_end_forward(doc, from, count, false), false)),
            'E' => Some((word_end_forward(doc, from, count, true), false)),
            '0' => Some((Pos::new(from.line, 0), false)),
            '^' => Some((Pos::new(from.line, first_non_blank(doc, from.line)), false)),
            '$' => Some((pos_line_end(doc, from.line, count), false)),
            'G' => {
                let line = if count == 1 {
                    doc.line_count().saturating_sub(1)
                } else {
                    (count - 1).min(doc.line_count() - 1)
                };
                Some((Pos::new(line, first_non_blank(doc, line)), true))
            }
            '{' => Some((paragraph_back(doc, from, count), true)),
            '}' => Some((paragraph_forward(doc, from, count), true)),
            '%' => {
                if doc.goto_bracket() {
                    return Action::Changed;
                }
                None
            }
            '+' => Some((move_down(doc, Pos::new(from.line, 0), count), true)),
            '-' => Some((move_up(doc, Pos::new(from.line, 0), count), true)),
            '_' => {
                let line = (from.line + count).min(doc.line_count() - 1);
                Some((Pos::new(line, first_non_blank(doc, line)), true))
            }
            '|' => Some((Pos::new(from.line, count.saturating_sub(1)), false)),
            _ => None,
        };
        if let Some((pos, linewise)) = result {
            let pos = if linewise {
                pos
            } else {
                clamp_normal(doc, pos)
            };
            doc.move_cursor(pos, false);
            self.target_col = Some(pos.col);
            Action::Changed
        } else {
            Action::None
        }
    }

    fn find_char(
        &mut self,
        c: char,
        forward: bool,
        till: bool,
        count: usize,
        doc: &mut Document,
    ) -> Action {
        let from = doc.primary().pos;
        let chars: Vec<char> = doc.line(from.line).chars().collect();
        let mut col = from.col;
        let mut found = None;
        for _ in 0..count {
            if forward {
                let mut i = col + 1;
                while i < chars.len() {
                    if chars[i] == c {
                        found = Some(if till { i.saturating_sub(1) } else { i });
                        break;
                    }
                    i += 1;
                }
                match found {
                    Some(v) => col = v,
                    None => break,
                }
            } else {
                let mut i = col;
                while i > 0 {
                    i -= 1;
                    if chars[i] == c {
                        found = Some(if till { i + 1 } else { i });
                        break;
                    }
                }
                match found {
                    Some(v) => col = v,
                    None => break,
                }
            }
        }
        match found {
            Some(value) => {
                doc.move_cursor(Pos::new(from.line, value), false);
                Action::Changed
            }
            None => Action::Message(format!("未找到 {c}")),
        }
    }

    fn operator_motion(
        &mut self,
        op: Op,
        key: Key,
        count: usize,
        doc: &mut Document,
        tab_width: usize,
    ) -> Action {
        // 连续两次操作符 = 当前行
        if let Some(ch) = ch_of(&key) {
            if ch == op_char(op) {
                self.op = None;
                return self.apply_line_op(op, count, doc, tab_width);
            }
            if (ch == 'i' || ch == 'a') && matches!(op, Op::Delete | Op::Yank | Op::Change) {
                self.pending_state = Pending::TextObject(op, ch == 'i');
                self.op = None;
                self.digits = count.to_string();
                return Action::None;
            }
        }
        self.op = None;
        let Some(ch) = ch_of(&key) else {
            return Action::None;
        };
        let from = doc.primary().pos;
        let Some((target, linewise, inclusive)) = motion_target(doc, from, ch, count) else {
            // 文本对象之外的动作不支持时给出提示
            return Action::Message(format!("不支持的操作 {ch}"));
        };
        let (start, end) = ordered_range(
            doc,
            from,
            target,
            linewise,
            inclusive,
        );
        self.apply_op(op, start, end, linewise, doc, tab_width)
    }

    fn apply_line_op(&mut self, op: Op, count: usize, doc: &mut Document, tab_width: usize) -> Action {
        let line = doc.primary().pos.line;
        let end_line = (line + count).min(doc.line_count());
        let start = Pos::new(line, 0);
        let end = line_end_pos(doc, end_line);
        self.apply_op(op, start, end, true, doc, tab_width)
    }

    fn apply_op(
        &mut self,
        op: Op,
        start: Pos,
        end: Pos,
        linewise: bool,
        doc: &mut Document,
        tab_width: usize,
    ) -> Action {
        if start == end && !linewise {
            return Action::None;
        }
        match op {
            Op::Yank => {
                let text = if linewise {
                    let mut text = doc.slice(start, pos_before(end, doc));
                    if !text.ends_with('\n') {
                        text.push('\n');
                    }
                    text
                } else {
                    doc.slice(start, end)
                };
                self.store(self.register, text, linewise);
                self.register = '"';
                doc.set_cursor(start);
                Action::Changed
            }
            Op::Delete | Op::Change => {
                let text = if linewise {
                    let mut text = doc.slice(start, pos_before(end, doc));
                    if !text.ends_with('\n') {
                        text.push('\n');
                    }
                    text
                } else {
                    doc.slice(start, end)
                };
                self.store('"', text, linewise);
                doc.replace_ranges(&[(start, end)], "");
                doc.set_cursor(clamp_normal(doc, start));
                if op == Op::Change {
                    self.mode = Mode::Insert;
                    self.update_pending();
                }
                Action::Changed
            }
            Op::Indent | Op::Outdent => {
                let outdent = op == Op::Outdent;
                let first = start.line;
                let last = pos_before(end, doc).line;
                self.indent_range(first, last, outdent, doc, tab_width)
            }
            Op::Upper | Op::Lower | Op::ToggleCase => {
                let text = doc.slice(start, end);
                let replaced = match op {
                    Op::Upper => text.to_uppercase(),
                    Op::Lower => text.to_lowercase(),
                    _ => text
                        .chars()
                        .map(|c| {
                            if c.is_uppercase() {
                                c.to_lowercase().next().unwrap_or(c)
                            } else {
                                c.to_uppercase().next().unwrap_or(c)
                            }
                        })
                        .collect(),
                };
                if replaced != text {
                    doc.replace_ranges(&[(start, end)], &replaced);
                    Action::Changed
                } else {
                    Action::None
                }
            }
        }
    }

    fn apply_text_object(
        &mut self,
        op: Op,
        inner: bool,
        ch: char,
        doc: &mut Document,
        tab_width: usize,
    ) -> Action {
        let pos = doc.primary().pos;
        let Some((start, end, linewise)) = text_object(doc, pos, ch, inner) else {
            return Action::Message(format!("没有文本对象 {ch}"));
        };
        self.apply_op(op, start, end, linewise, doc, tab_width)
    }

    fn indent_lines(&mut self, count: usize, outdent: bool, doc: &mut Document, tab_width: usize) -> Action {
        let line = doc.primary().pos.line;
        self.indent_range(line, line + count - 1, outdent, doc, tab_width)
    }

    fn indent_range(
        &mut self,
        first: usize,
        last: usize,
        outdent: bool,
        doc: &mut Document,
        tab_width: usize,
    ) -> Action {
        let last = last.min(doc.line_count().saturating_sub(1));
        let unit = if doc.use_spaces {
            " ".repeat(tab_width.max(1))
        } else {
            "\t".to_string()
        };
        let mut edits: Vec<(Pos, Pos, String)> = Vec::new();
        for line in first..=last {
            let text = doc.line(line).to_string();
            let new = if outdent {
                let stripped = if text.starts_with('\t') {
                    text[1..].to_string()
                } else {
                    let spaces = text.chars().take(tab_width.max(1)).take_while(|c| *c == ' ').count();
                    text[spaces..].to_string()
                };
                stripped
            } else if text.is_empty() {
                unit.clone()
            } else {
                format!("{unit}{text}")
            };
            if new != text {
                let len = text.chars().count();
                edits.push((Pos::new(line, 0), Pos::new(line, len), new));
            }
        }
        if edits.is_empty() {
            return Action::None;
        }
        doc.replace_ranges_each(&edits);
        doc.set_cursor(Pos::new(first, first_non_blank(doc, first)));
        Action::Changed
    }

    fn toggle_char(&mut self, count: usize, doc: &mut Document) -> Action {
        let pos = doc.primary().pos;
        let len = doc.line_chars(pos.line);
        let end = (pos.col + count).min(len);
        if end <= pos.col {
            return Action::None;
        }
        let text = doc.slice(pos, Pos::new(pos.line, end));
        let replaced: String = text
            .chars()
            .map(|c| {
                if c.is_uppercase() {
                    c.to_lowercase().next().unwrap_or(c)
                } else {
                    c.to_uppercase().next().unwrap_or(c)
                }
            })
            .collect();
        doc.replace_ranges(&[(pos, Pos::new(pos.line, end))], &replaced);
        let target = clamp_normal(doc, Pos::new(pos.line, end));
        doc.set_cursor(target);
        Action::Changed
    }

    fn store(&mut self, name: char, text: String, linewise: bool) {
        let name = if name == '"' { '"' } else { name };
        self.registers.insert(name, (text.clone(), linewise));
        if name != '"' {
            self.registers.insert('"', (text, linewise));
        }
    }

    fn paste(&mut self, before: bool, count: usize, doc: &mut Document, tab_width: usize) -> Action {
        let Some((text, linewise)) = self.registers.get(&self.register).cloned() else {
            return Action::Message("寄存器为空".into());
        };
        let text = text.repeat(count.max(1));
        let pos = doc.primary().pos;
        if linewise {
            let line = pos.line;
            if before {
                doc.set_cursor(Pos::new(line, 0));
                let block = format!("{}\n", text.trim_end_matches('\n'));
                doc.insert_text(&block);
                doc.set_cursor(Pos::new(line, 0));
            } else {
                let len = doc.line_chars(line);
                doc.set_cursor(Pos::new(line, len));
                let block = format!("\n{}", text.trim_end_matches('\n'));
                doc.insert_text(&block);
                doc.set_cursor(Pos::new(line + 1, 0));
            }
        } else if before {
            doc.set_cursor(pos);
            doc.insert_text(&text);
            doc.set_cursor(clamp_normal(doc, pos));
        } else {
            let len = doc.line_chars(pos.line);
            let target = Pos::new(pos.line, (pos.col + 1).min(len));
            doc.set_cursor(target);
            doc.insert_text(&text);
        }
        self.register = '"';
        let _ = tab_width;
        Action::Changed
    }

    fn play_macro(&mut self, name: Option<char>, doc: &mut Document, tab_width: usize) -> Action {
        let name = name.unwrap_or('"');
        let Some(keys) = self.macros.get(&name).cloned() else {
            return Action::Message(format!("宏 @{name} 为空"));
        };
        self.playing = true;
        for key in keys {
            let k = key.to_key();
            self.dispatch(k, doc, tab_width);
            if self.mode == Mode::Insert {
                // 插入模式里的可打印字符直接写入
                if let KeyCode::Char(c) = k.code {
                    if k.mods == Mods::none() {
                        doc.insert_text(&c.to_string());
                    }
                } else if k.code == KeyCode::Esc {
                    self.mode = Mode::Normal;
                }
            }
        }
        self.playing = false;
        if self.mode == Mode::Insert {
            self.mode = Mode::Normal;
        }
        Action::Changed
    }

    fn replay(&mut self, keys: Vec<VimKey>, doc: &mut Document, tab_width: usize) {
        self.playing = true;
        for key in keys {
            let k = key.to_key();
            self.dispatch(k, doc, tab_width);
            if self.mode == Mode::Insert {
                match k.code {
                    KeyCode::Char(c) if k.mods == Mods::none() => {
                        doc.insert_text(&c.to_string());
                    }
                    KeyCode::Enter => doc.insert_newline(),
                    KeyCode::Backspace => doc.backspace(false),
                    KeyCode::Esc => self.mode = Mode::Normal,
                    _ => {}
                }
            }
        }
        self.playing = false;
        if self.mode == Mode::Insert {
            self.mode = Mode::Normal;
        }
    }

    // ------------------------------------------------------------ 可视模式

    fn visual_key(&mut self, key: Key, doc: &mut Document, tab_width: usize) -> Action {
        use KeyCode::*;
        let count = self.take_count();
        if let Some(ch) = ch_of(&key) {
            match ch {
                'h' | 'j' | 'k' | 'l' | 'w' | 'W' | 'b' | 'B' | 'e' | 'E' | '0' | '^' | '$'
                | 'G' | '{' | '}' | '%' | 'f' | 'F' | 't' | 'T' => {
                    return self.visual_move(ch, count, doc);
                }
                'o' => {
                    // 交换光标与锚点
                    if let Some(anchor) = self.visual_anchor {
                        let pos = doc.primary().pos;
                        doc.set_cursor(anchor);
                        doc.move_cursor(pos, true);
                        self.visual_anchor = Some(pos);
                    }
                    return Action::Changed;
                }
                'd' | 'x' => return self.visual_op(Op::Delete, doc, tab_width),
                'y' => return self.visual_op(Op::Yank, doc, tab_width),
                'c' => return self.visual_op(Op::Change, doc, tab_width),
                'D' => return self.visual_op(Op::Delete, doc, tab_width),
                'Y' => return self.visual_op(Op::Yank, doc, tab_width),
                '>' => return self.visual_op(Op::Indent, doc, tab_width),
                '<' => return self.visual_op(Op::Outdent, doc, tab_width),
                'u' => return self.visual_op(Op::Lower, doc, tab_width),
                'U' => return self.visual_op(Op::Upper, doc, tab_width),
                '~' => return self.visual_op(Op::ToggleCase, doc, tab_width),
                'p' => {
                    // 用寄存器内容替换选区
                    if self.registers.contains_key(&self.register) {
                        self.visual_op(Op::Delete, doc, tab_width);
                        self.paste(false, 1, doc, tab_width);
                    }
                    return Action::Changed;
                }
                'v' => {
                    self.mode = if self.mode == Mode::Visual {
                        Mode::Normal
                    } else {
                        Mode::Visual
                    };
                    if self.mode == Mode::Normal {
                        doc.set_cursor(doc.primary().pos);
                    }
                    return Action::None;
                }
                'V' => {
                    self.mode = if self.mode == Mode::VisualLine {
                        Mode::Normal
                    } else {
                        Mode::VisualLine
                    };
                    return Action::None;
                }
                'g' => {
                    self.pending_state = Pending::G;
                    return Action::None;
                }
                _ => return Action::None,
            }
        }
        if key.code == Esc {
            let start = doc.primary().pos;
            let anchor = self.visual_anchor.take();
            self.mode = Mode::Normal;
            doc.set_cursor(start);
            if let Some(anchor) = anchor {
                self.last_visual = Some((anchor.min(start), anchor.max(start), Mode::Visual));
            }
            return Action::Changed;
        }
        if key.code == Char('v') && key.mods.ctrl {
            self.mode = Mode::VisualBlock;
            self.visual_block_col = doc.primary().pos.col;
            self.visual_anchor = Some(doc.primary().pos);
        }
        Action::None
    }

    fn visual_move(&mut self, ch: char, count: usize, doc: &mut Document) -> Action {
        if matches!(ch, 'f' | 'F' | 't' | 'T') {
            self.pending_state = Pending::Char(CharUse::Find(ch == 'f' || ch == 't', ch == 't' || ch == 'T'));
            self.digits = count.to_string();
            return Action::None;
        }
        let from = doc.primary().pos;
        let (target, _) = match ch {
            'h' => (move_left(from, count), true),
            'l' => (move_right(doc, from, count), true),
            'j' => (move_down(doc, from, count), true),
            'k' => (move_up(doc, from, count), true),
            'w' => (word_forward(doc, from, count, false), false),
            'W' => (word_forward(doc, from, count, true), false),
            'b' => (word_backward(doc, from, count, false), false),
            'B' => (word_backward(doc, from, count, true), false),
            'e' => (word_end_forward(doc, from, count, false), false),
            'E' => (word_end_forward(doc, from, count, true), false),
            '0' => (Pos::new(from.line, 0), false),
            '^' => (Pos::new(from.line, first_non_blank(doc, from.line)), false),
            '$' => (pos_line_end(doc, from.line, count), false),
            'G' => (Pos::new(doc.line_count() - 1, first_non_blank(doc, doc.line_count() - 1)), true),
            '{' => (paragraph_back(doc, from, count), true),
            '}' => (paragraph_forward(doc, from, count), true),
            '%' => {
                if doc.goto_bracket() {
                    return Action::Changed;
                }
                (from, false)
            }
            _ => (from, false),
        };
        let target = clamp_normal(doc, target);
        doc.move_cursor(target, true);
        Action::Changed
    }

    fn visual_range(&self, doc: &Document) -> Option<(Pos, Pos, bool)> {
        let anchor = self.visual_anchor?;
        let pos = doc.primary().pos;
        let (start, end) = if anchor <= pos { (anchor, pos) } else { (pos, anchor) };
        match self.mode {
            Mode::VisualLine => Some((
                Pos::new(start.line, 0),
                line_end_pos(doc, end.line + 1),
                true,
            )),
            Mode::VisualBlock => Some((start, Pos::new(end.line, end.col + 1), false)),
            _ => Some((start, Pos::new(end.line, end.col + 1), false)),
        }
    }

    fn visual_op(&mut self, op: Op, doc: &mut Document, tab_width: usize) -> Action {
        let Some((start, end, linewise)) = self.visual_range(doc) else {
            self.mode = Mode::Normal;
            return Action::None;
        };
        if self.mode == Mode::VisualBlock && !linewise {
            // 块选择：按行构造矩形范围
            let mut ranges = Vec::new();
            for line in start.line..=end.line {
                let len = doc.line_chars(line);
                let from = start.col.min(len);
                let to = end.col.min(len);
                if to > from {
                    ranges.push((Pos::new(line, from), Pos::new(line, to)));
                }
            }
            if ranges.is_empty() {
                self.mode = Mode::Normal;
                return Action::None;
            }
            match op {
                Op::Yank => {
                    let text = ranges
                        .iter()
                        .map(|(s, e)| doc.slice(*s, *e))
                        .collect::<Vec<_>>()
                        .join("\n");
                    self.store(self.register, text, false);
                }
                _ => {
                    doc.replace_ranges(&ranges, "");
                }
            }
            self.mode = Mode::Normal;
            self.visual_anchor = None;
            return Action::Changed;
        }
        let action = self.apply_op(op, start, end, linewise, doc, tab_width);
        if op != Op::Change {
            self.mode = Mode::Normal;
        }
        self.last_visual = Some((start, end, self.mode));
        self.visual_anchor = None;
        if op == Op::Change {
            self.mode = Mode::Insert;
        }
        action
    }
}

enum InsertAt {
    Before,
    After,
    LineStart,
    LineEnd,
    Here,
}

// ---------------------------------------------------------------- 辅助函数

fn ch_of(key: &Key) -> Option<char> {
    if key.mods.ctrl || key.mods.alt {
        return None;
    }
    match key.code {
        KeyCode::Char(c) => Some(c),
        _ => None,
    }
}

fn is_char(key: &Key, c: char) -> bool {
    matches!(key.code, KeyCode::Char(v) if v == c)
}

fn op_char(op: Op) -> char {
    match op {
        Op::Delete => 'd',
        Op::Change => 'c',
        Op::Yank => 'y',
        Op::Indent => '>',
        Op::Outdent => '<',
        Op::Upper => 'U',
        Op::Lower => 'u',
        Op::ToggleCase => '~',
    }
}

fn is_word(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_'
}

fn class(ch: char, big: bool) -> u8 {
    if ch.is_whitespace() {
        0
    } else if big || is_word(ch) {
        1
    } else {
        2
    }
}

pub fn clamp_normal(doc: &Document, pos: Pos) -> Pos {
    let line = pos.line.min(doc.line_count().saturating_sub(1));
    let len = doc.line_chars(line);
    let col = if len == 0 { 0 } else { pos.col.min(len - 1) };
    Pos::new(line, col)
}

fn move_left(from: Pos, count: usize) -> Pos {
    Pos::new(from.line, from.col.saturating_sub(count))
}

fn move_right(doc: &Document, from: Pos, count: usize) -> Pos {
    let len = doc.line_chars(from.line);
    let max = len.saturating_sub(1);
    Pos::new(from.line, (from.col + count).min(max))
}

fn move_down(doc: &Document, from: Pos, count: usize) -> Pos {
    let line = (from.line + count).min(doc.line_count().saturating_sub(1));
    Pos::new(line, from.col)
}

fn move_up(doc: &Document, from: Pos, count: usize) -> Pos {
    Pos::new(from.line.saturating_sub(count), from.col)
}

fn pos_line_end(doc: &Document, line: usize, count: usize) -> Pos {
    let line = (line + count - 1).min(doc.line_count().saturating_sub(1));
    let len = doc.line_chars(line);
    Pos::new(line, len.saturating_sub(1))
}

fn first_non_blank(doc: &Document, line: usize) -> usize {
    doc.line(line)
        .chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .count()
}

fn word_forward(doc: &Document, from: Pos, count: usize, big: bool) -> Pos {
    let mut pos = from;
    for _ in 0..count {
        let mut line = pos.line;
        let mut col = pos.col;
        loop {
            let text = doc.line(line);
            let chars: Vec<char> = text.chars().collect();
            if col >= chars.len() {
                if line + 1 < doc.line_count() {
                    line += 1;
                    col = 0;
                    if doc.line_chars(line) == 0 {
                        continue;
                    }
                    break;
                }
                col = chars.len().saturating_sub(1);
                break;
            }
            let cls = class(chars[col], big);
            while col < chars.len() && class(chars[col], big) == cls {
                col += 1;
            }
            if col >= chars.len() {
                if line + 1 < doc.line_count() {
                    line += 1;
                    col = 0;
                    break;
                }
                col = chars.len().saturating_sub(1);
                break;
            }
            if cls == 0 {
                break;
            }
            // 遇到分隔符再跳到下一个词
            if class(chars[col], big) == 0 {
                while col < chars.len() && class(chars[col], big) == 0 {
                    col += 1;
                }
                if col >= chars.len() && line + 1 < doc.line_count() {
                    line += 1;
                    col = 0;
                }
            }
            break;
        }
        pos = Pos::new(line, col);
    }
    pos
}

fn word_backward(doc: &Document, from: Pos, count: usize, big: bool) -> Pos {
    let mut pos = from;
    for _ in 0..count {
        let mut line = pos.line;
        let mut col = pos.col;
        loop {
            let chars: Vec<char> = doc.line(line).chars().collect();
            if col == 0 {
                if line > 0 {
                    line -= 1;
                    col = doc.line_chars(line);
                    continue;
                }
                break;
            }
            col -= 1;
            while col > 0 && class(chars[col], big) == 0 {
                col -= 1;
            }
            let cls = class(chars[col], big);
            while col > 0 && class(chars[col - 1], big) == cls {
                col -= 1;
            }
            break;
        }
        pos = Pos::new(line, col);
    }
    pos
}

fn word_end_forward(doc: &Document, from: Pos, count: usize, big: bool) -> Pos {
    let mut pos = from;
    for _ in 0..count {
        let mut line = pos.line;
        let mut col = pos.col;
        loop {
            let chars: Vec<char> = doc.line(line).chars().collect();
            if chars.is_empty() {
                if line + 1 < doc.line_count() {
                    line += 1;
                    col = 0;
                    continue;
                }
                break;
            }
            if col + 1 >= chars.len() {
                if line + 1 < doc.line_count() {
                    line += 1;
                    col = 0;
                    continue;
                }
                col = chars.len().saturating_sub(1);
                break;
            }
            col += 1;
            while col < chars.len() && class(chars[col], big) == 0 {
                col += 1;
            }
            if col >= chars.len() {
                col = chars.len().saturating_sub(1);
                break;
            }
            let cls = class(chars[col], big);
            while col + 1 < chars.len() && class(chars[col + 1], big) == cls {
                col += 1;
            }
            break;
        }
        pos = Pos::new(line, col);
    }
    pos
}

fn paragraph_forward(doc: &Document, from: Pos, count: usize) -> Pos {
    let mut line = from.line;
    for _ in 0..count {
        let mut next = line + 1;
        while next + 1 < doc.line_count() && !doc.line(next).trim().is_empty() {
            next += 1;
        }
        line = next.min(doc.line_count().saturating_sub(1));
    }
    Pos::new(line, 0)
}

fn paragraph_back(doc: &Document, from: Pos, count: usize) -> Pos {
    let mut line = from.line;
    for _ in 0..count {
        let mut next = line.saturating_sub(1);
        while next > 0 && !doc.line(next).trim().is_empty() {
            next -= 1;
        }
        line = next;
    }
    Pos::new(line, 0)
}

/// 动作目标：普通动作默认从行首到行尾。
fn motion_target(
    doc: &Document,
    from: Pos,
    ch: char,
    count: usize,
) -> Option<(Pos, bool, bool)> {
    match ch {
        'h' => Some((move_left(from, count), false, false)),
        'l' => Some((move_right(doc, from, count), false, false)),
        'j' => Some((move_down(doc, from, count), true, false)),
        'k' => Some((move_up(doc, from, count), true, false)),
        'w' => Some((word_forward(doc, from, count, false), false, false)),
        'W' => Some((word_forward(doc, from, count, true), false, false)),
        'b' => Some((word_backward(doc, from, count, false), false, false)),
        'B' => Some((word_backward(doc, from, count, true), false, false)),
        'e' => Some((word_end_forward(doc, from, count, false), false, true)),
        'E' => Some((word_end_forward(doc, from, count, true), false, true)),
        '0' => Some((Pos::new(from.line, 0), false, false)),
        '^' => Some((Pos::new(from.line, first_non_blank(doc, from.line)), false, false)),
        '$' => Some((pos_line_end(doc, from.line, count), false, true)),
        'G' => {
            let line = if count == 1 {
                doc.line_count().saturating_sub(1)
            } else {
                (count - 1).min(doc.line_count() - 1)
            };
            Some((Pos::new(line, 0), true, false))
        }
        '{' => Some((paragraph_back(doc, from, count), true, false)),
        '}' => Some((paragraph_forward(doc, from, count), true, false)),
        '%' => {
            let (a, b) = doc.bracket_pair(from)?;
            let (start, end) = if a <= b { (a, b) } else { (b, a) };
            let target = if from == start { end } else { start };
            Some((target, false, true))
        }
        '+' | '_' => {
            let line = (from.line + count).min(doc.line_count() - 1);
            Some((Pos::new(line, 0), true, false))
        }
        '-' => Some((Pos::new(from.line.saturating_sub(count), 0), true, false)),
        _ => None,
    }
}

/// 把「起点 + 目标」变成规范化的替换区间；linewise 时 end 指向下一行行首。
fn ordered_range(
    doc: &Document,
    from: Pos,
    target: Pos,
    linewise: bool,
    inclusive: bool,
) -> (Pos, Pos) {
    let (mut start, mut end) = if from <= target { (from, target) } else { (target, from) };
    if linewise {
        if from <= target {
            start = Pos::new(start.line, 0);
            end = line_end_pos(doc, end.line + 1);
        } else {
            start = Pos::new(start.line, 0);
            end = line_end_pos(doc, from.line + 1);
        }
        return (start, end);
    }
    if inclusive {
        let len = doc.line_chars(end.line);
        end = Pos::new(end.line, (end.col + 1).min(len));
    }
    (start, end)
}

/// 第 `line` 行行首；越界时返回文档末尾。
fn line_end_pos(doc: &Document, line: usize) -> Pos {
    if line >= doc.line_count() {
        let last = doc.line_count() - 1;
        Pos::new(last, doc.line_chars(last))
    } else {
        Pos::new(line, 0)
    }
}

fn pos_before(pos: Pos, doc: &Document) -> Pos {
    if pos.col == 0 && pos.line > 0 {
        let line = pos.line - 1;
        Pos::new(line, doc.line_chars(line))
    } else {
        pos
    }
}

/// 文本对象：返回 (start, end, linewise)。
fn text_object(doc: &Document, pos: Pos, ch: char, inner: bool) -> Option<(Pos, Pos, bool)> {
    match ch {
        'w' => {
            let line = doc.line(pos.line);
            let chars: Vec<char> = line.chars().collect();
            if chars.is_empty() {
                return None;
            }
            let mut start = pos.col.min(chars.len() - 1);
            while start > 0 && is_word(chars[start - 1]) {
                start -= 1;
            }
            let mut end = pos.col.min(chars.len() - 1);
            while end + 1 < chars.len() && is_word(chars[end + 1]) {
                end += 1;
            }
            if inner {
                Some((Pos::new(pos.line, start), Pos::new(pos.line, end + 1), false))
            } else {
                let mut from = start;
                while from > 0 && chars[from - 1].is_whitespace() {
                    from -= 1;
                }
                let mut to = end + 1;
                while to < chars.len() && chars[to].is_whitespace() {
                    to += 1;
                }
                Some((Pos::new(pos.line, from), Pos::new(pos.line, to), false))
            }
        }
        'W' => {
            let line = doc.line(pos.line);
            let chars: Vec<char> = line.chars().collect();
            if chars.is_empty() {
                return None;
            }
            let mut start = pos.col.min(chars.len() - 1);
            while start > 0 && !chars[start - 1].is_whitespace() {
                start -= 1;
            }
            let mut end = pos.col.min(chars.len() - 1);
            while end + 1 < chars.len() && !chars[end + 1].is_whitespace() {
                end += 1;
            }
            if inner {
                Some((Pos::new(pos.line, start), Pos::new(pos.line, end + 1), false))
            } else {
                let mut from = start;
                while from > 0 && chars[from - 1].is_whitespace() {
                    from -= 1;
                }
                let mut to = end + 1;
                while to < chars.len() && chars[to].is_whitespace() {
                    to += 1;
                }
                Some((Pos::new(pos.line, from), Pos::new(pos.line, to), false))
            }
        }
        '(' | ')' | 'b' => pair_object(doc, pos, '(', ')', inner),
        '[' | ']' => pair_object(doc, pos, '[', ']', inner),
        '{' | '}' | 'B' => pair_object(doc, pos, '{', '}', inner),
        '<' | '>' => pair_object(doc, pos, '<', '>', inner),
        '"' | '\'' | '`' => quote_object(doc, pos, ch, inner),
        'p' => {
            let mut start = pos.line;
            while start > 0 && !doc.line(start).trim().is_empty() {
                start -= 1;
            }
            let mut end = pos.line;
            while end + 1 < doc.line_count() && !doc.line(end).trim().is_empty() {
                end += 1;
            }
            Some((Pos::new(start, 0), line_end_pos(doc, end + 1), true))
        }
        _ => None,
    }
}

fn pair_object(
    doc: &Document,
    pos: Pos,
    open: char,
    close: char,
    inner: bool,
) -> Option<(Pos, Pos, bool)> {
    let text = doc.text();
    let chars: Vec<char> = text.chars().collect();
    // 字符偏移
    let mut offset = 0usize;
    for line in 0..pos.line {
        offset += doc.line_chars(line) + 1;
    }
    offset += pos.col;
    if offset >= chars.len() {
        offset = chars.len().saturating_sub(1);
    }
    // 当前位置如果在括号上，先从它开始
    let mut depth = 0i32;
    let mut start = None;
    let mut i = offset as isize;
    while i >= 0 {
        let c = chars[i as usize];
        if c == close && i as usize != offset {
            depth += 1;
        } else if c == open {
            if depth == 0 {
                start = Some(i as usize);
                break;
            }
            depth -= 1;
        }
        i -= 1;
    }
    let start = start?;
    let mut depth = 0i32;
    let mut end = None;
    let mut j = start;
    while j < chars.len() {
        let c = chars[j];
        if c == open {
            depth += 1;
        } else if c == close {
            depth -= 1;
            if depth == 0 {
                end = Some(j);
                break;
            }
        }
        j += 1;
    }
    let end = end?;
    let (start, end) = if inner {
        (start + 1, end)
    } else {
        (start, end + 1)
    };
    Some((offset_to_pos(doc, start), offset_to_pos(doc, end), false))
}

fn quote_object(doc: &Document, pos: Pos, quote: char, inner: bool) -> Option<(Pos, Pos, bool)> {
    let line = doc.line(pos.line);
    let chars: Vec<char> = line.chars().collect();
    if chars.is_empty() {
        return None;
    }
    let mut positions: Vec<usize> = chars
        .iter()
        .enumerate()
        .filter(|(_, c)| **c == quote)
        .map(|(i, _)| i)
        .collect();
    if positions.len() < 2 {
        return None;
    }
    // 找到包含光标的一对
    let col = pos.col.min(chars.len() - 1);
    let mut pair = None;
    let mut index = 0;
    while index + 1 < positions.len() {
        if positions[index] <= col && col <= positions[index + 1] {
            pair = Some((positions[index], positions[index + 1]));
            break;
        }
        index += 2;
    }
    let (start, end) = pair?;
    let (start, end) = if inner {
        (start + 1, end)
    } else {
        (start, end + 1)
    };
    Some((Pos::new(pos.line, start), Pos::new(pos.line, end), false))
}

fn offset_to_pos(doc: &Document, offset: usize) -> Pos {
    let mut remaining = offset;
    for line in 0..doc.line_count() {
        let len = doc.line_chars(line);
        if remaining <= len {
            return Pos::new(line, remaining);
        }
        remaining -= len + 1;
    }
    let last = doc.line_count() - 1;
    Pos::new(last, doc.line_chars(last))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(c: char) -> Key {
        Key {
            code: KeyCode::Char(c),
            mods: Mods::none(),
        }
    }

    fn press(vim: &mut Vim, doc: &mut Document, keys: &str) {
        for c in keys.chars() {
            vim.handle(key(c), doc, 4);
        }
    }

    #[test]
    fn delete_word() {
        let mut doc = Document::from_text("hello world", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "dw");
        assert_eq!(doc.line(0), "world");
    }

    #[test]
    fn delete_line() {
        let mut doc = Document::from_text("a\nb\nc", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "dd");
        assert_eq!(doc.text(), "b\nc");
    }

    #[test]
    fn change_inner_word() {
        let mut doc = Document::from_text("foo bar", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "ciw");
        assert_eq!(vim.mode, Mode::Insert);
        doc.insert_text("x");
        assert_eq!(doc.line(0), "x bar");
    }

    #[test]
    fn yank_and_paste() {
        let mut doc = Document::from_text("abc\ndef", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "yy");
        press(&mut vim, &mut doc, "p");
        assert_eq!(doc.text(), "abc\nabc\ndef");
    }

    #[test]
    fn visual_delete() {
        let mut doc = Document::from_text("abcdef", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "vlll");
        press(&mut vim, &mut doc, "d");
        assert_eq!(doc.line(0), "ef");
        assert_eq!(vim.mode, Mode::Normal);
    }

    #[test]
    fn dot_repeat() {
        let mut doc = Document::from_text("a a a", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "dw");
        assert_eq!(doc.line(0), "a a");
        press(&mut vim, &mut doc, ".");
        assert_eq!(doc.line(0), "a");
    }

    #[test]
    fn indent_line() {
        let mut doc = Document::from_text("abc", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, ">>");
        assert_eq!(doc.line(0), "    abc");
    }

    #[test]
    fn word_motion() {
        let doc = Document::from_text("one two three", None);
        let pos = word_forward(&doc, Pos::new(0, 0), 1, false);
        assert_eq!(pos, Pos::new(0, 4));
        let pos = word_end_forward(&doc, Pos::new(0, 0), 1, false);
        assert_eq!(pos, Pos::new(0, 2));
    }

    #[test]
    fn text_object_parens() {
        let doc = Document::from_text("fn(a, b)", None);
        let (start, end, _) = text_object(&doc, Pos::new(0, 4), '(', true).unwrap();
        assert_eq!(doc.slice(start, end), "a, b");
    }

    #[test]
    fn g_prefix_gg() {
        let mut doc = Document::from_text("a\nb\nc", None);
        doc.set_cursor(Pos::new(2, 0));
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "gg");
        assert_eq!(doc.primary().pos.line, 0);
    }

    #[test]
    fn number_prefix() {
        let mut doc = Document::from_text("a\nb\nc\nd", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "3j");
        assert_eq!(doc.primary().pos.line, 3);
    }

    #[test]
    fn marks_jump() {
        let mut doc = Document::from_text("a\nb\nc", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "ma");
        doc.set_cursor(Pos::new(2, 0));
        press(&mut vim, &mut doc, "'a");
        assert_eq!(doc.primary().pos.line, 0);
    }

    #[test]
    fn register_roundtrip() {
        let mut doc = Document::from_text("one\ntwo", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "\"ayy");
        assert!(vim.registers.contains_key(&'a'));
    }

    #[test]
    fn macro_replay() {
        let mut doc = Document::from_text("a\nb\nc", None);
        let mut vim = Vim::new();
        press(&mut vim, &mut doc, "qa");
        press(&mut vim, &mut doc, "dd");
        press(&mut vim, &mut doc, "q");
        press(&mut vim, &mut doc, "@a");
        assert_eq!(doc.text(), "c");
    }
}

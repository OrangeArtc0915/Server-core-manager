//! 字符网格：单元格、颜色、SGR 属性，光标与滚动区，主/备用屏幕。

use std::collections::VecDeque;

pub const ATTR_BOLD: u16 = 1 << 0;
pub const ATTR_DIM: u16 = 1 << 1;
pub const ATTR_ITALIC: u16 = 1 << 2;
pub const ATTR_UNDERLINE: u16 = 1 << 3;
pub const ATTR_BLINK: u16 = 1 << 4;
pub const ATTR_REVERSE: u16 = 1 << 5;
pub const ATTR_HIDDEN: u16 = 1 << 6;
pub const ATTR_STRIKE: u16 = 1 << 7;
/// 宽字符的右半格（不单独绘制）。
pub const ATTR_WIDE_TAIL: u16 = 1 << 8;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Color {
    #[default]
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Attrs {
    pub fg: Color,
    pub bg: Color,
    pub flags: u16,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Cell {
    pub ch: char,
    pub attrs: Attrs,
    /// OSC 8 超链接 id；0 表示无链接（索引由 `Screen::link_url` 解析）。
    pub link: u16,
    /// 组合符串 id；0 表示无。基字符 + 这些零宽标记一起显示（见 `combining_text`）。
    pub combining: u16,
}

impl Default for Cell {
    fn default() -> Self {
        Cell {
            ch: ' ',
            attrs: Attrs::default(),
            link: 0,
            combining: 0,
        }
    }
}

/// 组合符驻留表：`Cell::combining` 存的是这里的下标。
///
/// 放在全局而非 `Screen` 里，是因为画布由多个窗格拼成，
/// 渲染时只有单元格、拿不到它属于哪个窗格；全局表天然避免下标串台。
static COMBINING: std::sync::OnceLock<std::sync::Mutex<Vec<String>>> = std::sync::OnceLock::new();

fn combining_table() -> std::sync::MutexGuard<'static, Vec<String>> {
    let table = COMBINING.get_or_init(|| std::sync::Mutex::new(vec![String::new()]));
    // 只在渲染线程使用；锁中毒时直接恢复（数据只是字符串表）。
    table.lock().unwrap_or_else(|e| e.into_inner())
}

/// 把一串零宽标记驻留到全局表，返回其 id（0 表示空串）。
pub fn intern_combining(marks: &str) -> u16 {
    if marks.is_empty() {
        return 0;
    }
    let mut table = combining_table();
    if let Some(index) = table.iter().position(|item| item == marks) {
        return index as u16;
    }
    if table.len() >= u16::MAX as usize {
        table.truncate(1);
        return 0;
    }
    table.push(marks.to_string());
    (table.len() - 1) as u16
}

/// 组合符串 id → 文本；0 或越界返回 `None`。
pub fn combining_text(id: u16) -> Option<String> {
    if id == 0 {
        return None;
    }
    combining_table().get(id as usize).cloned()
}

/// 拉丁字母的基字符 + 组合符 → 预组合字符（NFC 的一小部分）。
///
/// 能合成时单元格只存一个字符，渲染、复制、搜索都按普通字符处理；
/// 合成不了的（如中文 + 声调）留在 `Cell::combining` 里由渲染器逐字输出。
fn compose_latin(base: char, mark: char) -> Option<char> {
    let composed = match (base, mark) {
        ('A', '\u{300}') => 'À',
        ('A', '\u{301}') => 'Á',
        ('A', '\u{302}') => 'Â',
        ('A', '\u{303}') => 'Ã',
        ('A', '\u{308}') => 'Ä',
        ('A', '\u{30a}') => 'Å',
        ('A', '\u{304}') => 'Ā',
        ('A', '\u{306}') => 'Ă',
        ('A', '\u{328}') => 'Ą',
        ('C', '\u{327}') => 'Ç',
        ('C', '\u{301}') => 'Ć',
        ('C', '\u{302}') => 'Ĉ',
        ('C', '\u{307}') => 'Ċ',
        ('C', '\u{30c}') => 'Č',
        ('D', '\u{30c}') => 'Ď',
        ('E', '\u{300}') => 'È',
        ('E', '\u{301}') => 'É',
        ('E', '\u{302}') => 'Ê',
        ('E', '\u{308}') => 'Ë',
        ('E', '\u{304}') => 'Ē',
        ('E', '\u{306}') => 'Ĕ',
        ('E', '\u{307}') => 'Ė',
        ('E', '\u{328}') => 'Ę',
        ('E', '\u{30c}') => 'Ě',
        ('G', '\u{302}') => 'Ĝ',
        ('G', '\u{306}') => 'Ğ',
        ('G', '\u{307}') => 'Ġ',
        ('G', '\u{327}') => 'Ģ',
        ('H', '\u{302}') => 'Ĥ',
        ('I', '\u{300}') => 'Ì',
        ('I', '\u{301}') => 'Í',
        ('I', '\u{302}') => 'Î',
        ('I', '\u{308}') => 'Ï',
        ('I', '\u{303}') => 'Ĩ',
        ('I', '\u{304}') => 'Ī',
        ('I', '\u{306}') => 'Ĭ',
        ('I', '\u{328}') => 'Į',
        ('J', '\u{302}') => 'Ĵ',
        ('K', '\u{327}') => 'Ķ',
        ('L', '\u{301}') => 'Ĺ',
        ('L', '\u{327}') => 'Ļ',
        ('L', '\u{30c}') => 'Ľ',
        ('N', '\u{303}') => 'Ñ',
        ('N', '\u{301}') => 'Ń',
        ('N', '\u{327}') => 'Ņ',
        ('N', '\u{30c}') => 'Ň',
        ('O', '\u{300}') => 'Ò',
        ('O', '\u{301}') => 'Ó',
        ('O', '\u{302}') => 'Ô',
        ('O', '\u{303}') => 'Õ',
        ('O', '\u{308}') => 'Ö',
        ('O', '\u{304}') => 'Ō',
        ('O', '\u{306}') => 'Ŏ',
        ('O', '\u{30b}') => 'Ő',
        ('R', '\u{301}') => 'Ŕ',
        ('R', '\u{327}') => 'Ŗ',
        ('R', '\u{30c}') => 'Ř',
        ('S', '\u{301}') => 'Ś',
        ('S', '\u{302}') => 'Ŝ',
        ('S', '\u{327}') => 'Ş',
        ('S', '\u{30c}') => 'Š',
        ('T', '\u{327}') => 'Ţ',
        ('T', '\u{30c}') => 'Ť',
        ('U', '\u{300}') => 'Ù',
        ('U', '\u{301}') => 'Ú',
        ('U', '\u{302}') => 'Û',
        ('U', '\u{308}') => 'Ü',
        ('U', '\u{303}') => 'Ũ',
        ('U', '\u{304}') => 'Ū',
        ('U', '\u{306}') => 'Ŭ',
        ('U', '\u{30a}') => 'Ů',
        ('U', '\u{30b}') => 'Ű',
        ('U', '\u{328}') => 'Ų',
        ('W', '\u{302}') => 'Ŵ',
        ('Y', '\u{301}') => 'Ý',
        ('Y', '\u{302}') => 'Ŷ',
        ('Y', '\u{308}') => 'Ÿ',
        ('Z', '\u{301}') => 'Ź',
        ('Z', '\u{307}') => 'Ż',
        ('Z', '\u{30c}') => 'Ž',
        ('a', '\u{300}') => 'à',
        ('a', '\u{301}') => 'á',
        ('a', '\u{302}') => 'â',
        ('a', '\u{303}') => 'ã',
        ('a', '\u{308}') => 'ä',
        ('a', '\u{30a}') => 'å',
        ('a', '\u{304}') => 'ā',
        ('a', '\u{306}') => 'ă',
        ('a', '\u{328}') => 'ą',
        ('c', '\u{327}') => 'ç',
        ('c', '\u{301}') => 'ć',
        ('c', '\u{302}') => 'ĉ',
        ('c', '\u{307}') => 'ċ',
        ('c', '\u{30c}') => 'č',
        ('d', '\u{30c}') => 'ď',
        ('e', '\u{300}') => 'è',
        ('e', '\u{301}') => 'é',
        ('e', '\u{302}') => 'ê',
        ('e', '\u{308}') => 'ë',
        ('e', '\u{304}') => 'ē',
        ('e', '\u{306}') => 'ĕ',
        ('e', '\u{307}') => 'ė',
        ('e', '\u{328}') => 'ę',
        ('e', '\u{30c}') => 'ě',
        ('g', '\u{302}') => 'ĝ',
        ('g', '\u{306}') => 'ğ',
        ('g', '\u{307}') => 'ġ',
        ('g', '\u{327}') => 'ģ',
        ('h', '\u{302}') => 'ĥ',
        ('i', '\u{300}') => 'ì',
        ('i', '\u{301}') => 'í',
        ('i', '\u{302}') => 'î',
        ('i', '\u{308}') => 'ï',
        ('i', '\u{303}') => 'ĩ',
        ('i', '\u{304}') => 'ī',
        ('i', '\u{306}') => 'ĭ',
        ('i', '\u{328}') => 'į',
        ('j', '\u{302}') => 'ĵ',
        ('k', '\u{327}') => 'ķ',
        ('l', '\u{301}') => 'ĺ',
        ('l', '\u{327}') => 'ļ',
        ('l', '\u{30c}') => 'ľ',
        ('n', '\u{303}') => 'ñ',
        ('n', '\u{301}') => 'ń',
        ('n', '\u{327}') => 'ņ',
        ('n', '\u{30c}') => 'ň',
        ('o', '\u{300}') => 'ò',
        ('o', '\u{301}') => 'ó',
        ('o', '\u{302}') => 'ô',
        ('o', '\u{303}') => 'õ',
        ('o', '\u{308}') => 'ö',
        ('o', '\u{304}') => 'ō',
        ('o', '\u{306}') => 'ŏ',
        ('o', '\u{30b}') => 'ő',
        ('r', '\u{301}') => 'ŕ',
        ('r', '\u{327}') => 'ŗ',
        ('r', '\u{30c}') => 'ř',
        ('s', '\u{301}') => 'ś',
        ('s', '\u{302}') => 'ŝ',
        ('s', '\u{327}') => 'ş',
        ('s', '\u{30c}') => 'š',
        ('t', '\u{327}') => 'ţ',
        ('t', '\u{30c}') => 'ť',
        ('u', '\u{300}') => 'ù',
        ('u', '\u{301}') => 'ú',
        ('u', '\u{302}') => 'û',
        ('u', '\u{308}') => 'ü',
        ('u', '\u{303}') => 'ũ',
        ('u', '\u{304}') => 'ū',
        ('u', '\u{306}') => 'ŭ',
        ('u', '\u{30a}') => 'ů',
        ('u', '\u{30b}') => 'ű',
        ('u', '\u{328}') => 'ų',
        ('w', '\u{302}') => 'ŵ',
        ('y', '\u{301}') => 'ý',
        ('y', '\u{302}') => 'ŷ',
        ('y', '\u{308}') => 'ÿ',
        ('z', '\u{301}') => 'ź',
        ('z', '\u{307}') => 'ż',
        ('z', '\u{30c}') => 'ž',
        _ => return None,
    };
    Some(composed)
}

impl Cell {
    /// 供阶段 2（选区、搜索）判断空单元格使用。
    #[allow(dead_code)]
    pub fn is_blank(&self) -> bool {
        self.ch == ' ' && self.attrs.bg == Color::Default && self.attrs.flags == 0
    }
}

/// 字符显示宽度：0 = 组合符，1 = 普通，2 = 宽字符（CJK / emoji）。
pub fn char_width(ch: char) -> usize {
    let c = ch as u32;
    if c == 0 {
        return 0;
    }
    if c < 0x20 || (0x7f..0xa0).contains(&c) {
        return 0;
    }
    // 组合符
    if (0x0300..=0x036f).contains(&c)
        || (0x1ab0..=0x1aff).contains(&c)
        || (0x1dc0..=0x1dff).contains(&c)
        || (0x20d0..=0x20f0).contains(&c)
        || (0xfe00..=0xfe0f).contains(&c)
        || (0xfe20..=0xfe2f).contains(&c)
    {
        return 0;
    }
    // 宽字符（East Asian Wide / Fullwidth，含 emoji）
    if (0x1100..=0x115f).contains(&c)
        || (0x2e80..=0x303e).contains(&c)
        || (0x3041..=0x33ff).contains(&c)
        || (0x3400..=0x4dbf).contains(&c)
        || (0x4e00..=0x9fff).contains(&c)
        || (0xa000..=0xa4cf).contains(&c)
        || (0xa960..=0xa97f).contains(&c)
        || (0xac00..=0xd7a3).contains(&c)
        || (0xf900..=0xfaff).contains(&c)
        || (0xfe10..=0xfe19).contains(&c)
        || (0xfe30..=0xfe6f).contains(&c)
        || (0xff00..=0xff60).contains(&c)
        || (0xffe0..=0xffe6).contains(&c)
        || (0x1f300..=0x1f64f).contains(&c)
        || (0x1f900..=0x1f9ff).contains(&c)
        || (0x1f680..=0x1f6ff).contains(&c)
        || (0x20000..=0x3fffd).contains(&c)
    {
        return 2;
    }
    1
}

pub struct Screen {
    pub cols: usize,
    pub rows: usize,
    cells: Vec<Cell>,
    history: VecDeque<Vec<Cell>>,
    /// 与 `history` 一一对应：该行是否因为自动换行而延续到下一行。
    history_wrap: VecDeque<bool>,
    history_limit: usize,
    /// 屏幕每一行是否因为自动换行而延续到下一行（改宽度时据此重排）。
    wrap_flags: Vec<bool>,
    /// 最近一次打印基字符所在的单元格（组合符要挂在它上面）。
    last_cell: Option<(usize, usize)>,

    pub cursor_x: usize,
    pub cursor_y: usize,
    saved_cursor: (usize, usize, Attrs),
    pub attrs: Attrs,
    pending_wrap: bool,

    scroll_top: usize,
    scroll_bottom: usize,

    tabs: Vec<bool>,

    pub title: String,
    pub alt_active: bool,
    main_cells: Vec<Cell>,
    main_cursor: (usize, usize),

    pub cursor_visible: bool,
    /// DECSCUSR：0 = 默认，1/2 = 块，3/4 = 下划线，5/6 = 竖线。
    pub cursor_shape: u8,
    pub autowrap: bool,
    pub origin_mode: bool,
    pub app_cursor_keys: bool,
    pub bracketed_paste: bool,
    /// 鼠标追踪模式：0 = 关闭，1000 = 按键，1002 = 按键+拖动，1003 = 任意移动。
    pub mouse_mode: u32,
    /// `?1006`：SGR 扩展鼠标坐标编码。
    pub mouse_sgr: bool,
    /// 需要回写给子进程的字节（DSR 等查询响应）。
    pub responses: Vec<u8>,
    /// OSC 52 请求写入剪贴板的文本，由客户端取走。
    pub clipboard: Option<String>,
    /// REP（CSI b）重复的最近一个可见字符。
    pub last_printed: Option<char>,
    /// `?1004` 焦点上报。
    pub focus_reporting: bool,
    /// `?2026` 同步输出（当前无异步渲染，仅记录状态）。
    pub synchronized_output: bool,
    /// `?9001` win32-input-mode：子进程要求原样接收 Windows 按键事件。
    pub win32_input: bool,
    /// OSC 133;A 标记的提示符行（绝对行号，用于「跳到上/下一条提示符」）。
    pub prompt_marks: VecDeque<usize>,
    /// OSC 133;D 报告的上一条命令退出码（`None` 表示正在执行或未启用 shell 集成）。
    pub last_exit: Option<i32>,
    /// OSC 7 报告的当前工作目录（已转换成 Windows 风格路径）。
    pub cwd: Option<String>,
    /// OSC 9 / OSC 777 通知（桌面通知的终端内替代：标签标记 + 状态栏）。
    pub notifications: VecDeque<String>,
    /// OSC 8 超链接表；索引 0 恒为空（无链接）。
    link_table: Vec<String>,
    /// 当前 OSC 8 设定的链接，后续打印的字符都归属它。
    current_link: u16,
    pub bell: bool,
}

impl Screen {
    pub fn new(cols: usize, rows: usize, history_limit: usize) -> Screen {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let mut screen = Screen {
            cols,
            rows,
            cells: vec![Cell::default(); cols * rows],
            history: VecDeque::new(),
            history_wrap: VecDeque::new(),
            history_limit,
            wrap_flags: vec![false; rows],
            last_cell: None,
            cursor_x: 0,
            cursor_y: 0,
            saved_cursor: (0, 0, Attrs::default()),
            attrs: Attrs::default(),
            pending_wrap: false,
            scroll_top: 0,
            scroll_bottom: rows - 1,
            tabs: (0..cols).map(|i| i % 8 == 0).collect(),
            title: String::new(),
            alt_active: false,
            main_cells: Vec::new(),
            main_cursor: (0, 0),
            cursor_visible: true,
            cursor_shape: 0,
            autowrap: true,
            origin_mode: false,
            app_cursor_keys: false,
            bracketed_paste: false,
            mouse_mode: 0,
            mouse_sgr: false,
            responses: Vec::new(),
            clipboard: None,
            last_printed: None,
            focus_reporting: false,
            synchronized_output: false,
            win32_input: false,
            prompt_marks: VecDeque::new(),
            last_exit: None,
            cwd: None,
            notifications: VecDeque::new(),
            link_table: vec![String::new()],
            current_link: 0,
            bell: false,
        };
        screen.tabs[0] = true;
        screen
    }

    /// 整块网格（渲染与测试用）。
    #[allow(dead_code)]
    pub fn cells(&self) -> &[Cell] {
        &self.cells
    }

    /// 滚动回看缓冲区行数（阶段 2 的搜索会用到）。
    #[allow(dead_code)]
    pub fn history_len(&self) -> usize {
        self.history.len()
    }

    pub fn cell(&self, x: usize, y: usize) -> Cell {
        if x >= self.cols || y >= self.rows {
            return Cell::default();
        }
        self.cells[y * self.cols + x]
    }

    /// 按绝对行号取单元格（回看缓冲在前、屏幕在后）。
    pub fn cell_absolute(&self, row: usize, col: usize) -> Option<Cell> {
        if row < self.history.len() {
            self.history.get(row).and_then(|cells| cells.get(col)).copied()
        } else {
            let y = row - self.history.len();
            if col < self.cols && y < self.rows {
                Some(self.cells[y * self.cols + col])
            } else {
                None
            }
        }
    }

    /// OSC 8：`params;uri`，uri 为空时结束当前链接。
    pub fn set_link(&mut self, uri: &str) {
        let uri = uri.trim();
        if uri.is_empty() {
            self.current_link = 0;
            return;
        }
        if let Some(index) = self.link_table.iter().position(|item| item == uri) {
            self.current_link = index as u16;
            return;
        }
        // id 是 u16：表满后清空旧链接（已有单元格会失去链接，但不会误连到别的地址）。
        if self.link_table.len() >= u16::MAX as usize {
            self.link_table.truncate(1);
        }
        self.link_table.push(uri.to_string());
        self.current_link = (self.link_table.len() - 1) as u16;
    }

    /// 链接 id → URL；0 或越界返回 `None`。
    pub fn link_url(&self, id: u16) -> Option<&str> {
        if id == 0 {
            return None;
        }
        self.link_table.get(id as usize).map(|s| s.as_str())
    }

    /// 按绝对行号取该单元格的链接。
    pub fn link_at_absolute(&self, row: usize, col: usize) -> Option<&str> {
        self.link_url(self.cell_absolute(row, col)?.link)
    }

    /// 屏幕某一行（0 为最上面一行）。
    pub fn row(&self, y: usize) -> Option<&[Cell]> {
        if y >= self.rows {
            return None;
        }
        Some(&self.cells[y * self.cols..(y + 1) * self.cols])
    }

    /// 回看缓冲中的一行（0 为最旧的一行）。
    pub fn history_row(&self, index: usize) -> Option<&[Cell]> {
        self.history.get(index).map(|row| row.as_slice())
    }

    fn cell_mut(&mut self, x: usize, y: usize) -> &mut Cell {
        let idx = y * self.cols + x;
        &mut self.cells[idx]
    }

    pub fn blank_cell(&self) -> Cell {
        Cell {
            ch: ' ',
            attrs: Attrs {
                fg: Color::Default,
                bg: self.attrs.bg,
                flags: 0,
            },
            link: 0,
            combining: 0,
        }
    }

    // ---------- 输出 ----------

    pub fn print(&mut self, ch: char) {
        let width = char_width(ch);
        if width == 0 {
            self.attach_combining(ch);
            return;
        }
        self.last_printed = Some(ch);

        if self.pending_wrap {
            self.pending_wrap = false;
            // 上一行写满后由下一个字符触发换行：记下「自动换行」标记，供改宽度时重排。
            if let Some(flag) = self.wrap_flags.get_mut(self.cursor_y) {
                *flag = true;
            }
            self.cursor_x = 0;
            self.index();
        }

        if width == 2 && self.cursor_x + 1 >= self.cols {
            self.cursor_x = 0;
            self.index();
        }

        let attrs = self.attrs;
        let link = self.current_link;
        let x = self.cursor_x;
        let y = self.cursor_y;
        *self.cell_mut(x, y) = Cell {
            ch,
            attrs,
            link,
            combining: 0,
        };
        self.last_cell = Some((x, y));
        if width == 2 && x + 1 < self.cols {
            let mut tail = attrs;
            tail.flags |= ATTR_WIDE_TAIL;
            *self.cell_mut(x + 1, y) = Cell {
                ch: ' ',
                attrs: tail,
                link,
                combining: 0,
            };
        }

        let next = x + width;
        if next >= self.cols {
            if self.autowrap {
                self.cursor_x = self.cols - 1;
                self.pending_wrap = true;
            } else {
                self.cursor_x = self.cols - 1;
            }
        } else {
            self.cursor_x = next;
        }
    }

    /// 组合符（零宽字符）：并到最近一次打印的基字符上。
    ///
    /// 拉丁字母优先合成预组合字符（`e` + 重音 → `é`），
    /// 合成不了的（中文 + 声调、多个标记等）存成组合串，渲染器会连着基字符输出。
    fn attach_combining(&mut self, mark: char) {
        let Some((x, y)) = self.last_cell else {
            return;
        };
        if x >= self.cols || y >= self.rows {
            return;
        }
        let cell = self.cells[y * self.cols + x];
        if cell.attrs.flags & ATTR_WIDE_TAIL != 0 {
            return;
        }
        // 已有组合串时先拼上，再看能否合成（处理「先加一个标记再加另一个」的情况）。
        let marks = match combining_text(cell.combining) {
            Some(text) => text,
            None => String::new(),
        };
        let mut next = marks.clone();
        next.push(mark);
        if marks.is_empty() {
            if let Some(composed) = compose_latin(cell.ch, mark) {
                let mut composed_cell = cell;
                composed_cell.ch = composed;
                self.cells[y * self.cols + x] = composed_cell;
                return;
            }
        }
        let id = intern_combining(&next);
        self.cells[y * self.cols + x].combining = id;
    }

    /// 回车 + 换行（LF），必要时滚动。
    pub fn newline(&mut self) {
        self.pending_wrap = false;
        self.cursor_x = 0;
        self.last_cell = None;
        self.index();
    }

    /// REP（CSI b）：重复最近一个可见字符。
    pub fn repeat_last(&mut self, count: usize) {
        let Some(ch) = self.last_printed else {
            return;
        };
        for _ in 0..count.min(100_000) {
            self.print(ch);
        }
    }

    /// DECALN（ESC # 8）：整屏填 `E`，用于对齐测试。
    pub fn alignment_test(&mut self) {
        let blank = Cell {
            ch: 'E',
            attrs: Attrs::default(),
            link: 0,
            combining: 0,
        };
        for cell in &mut self.cells {
            *cell = blank;
        }
        for flag in &mut self.wrap_flags {
            *flag = false;
        }
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.pending_wrap = false;
    }

    pub fn index(&mut self) {
        self.pending_wrap = false;
        if self.cursor_y == self.scroll_bottom {
            self.scroll_up(1);
        } else if self.cursor_y + 1 < self.rows {
            self.cursor_y += 1;
        }
    }

    pub fn reverse_index(&mut self) {
        self.pending_wrap = false;
        if self.cursor_y == self.scroll_top {
            self.scroll_down(1);
        } else if self.cursor_y > 0 {
            self.cursor_y -= 1;
        }
    }

    pub fn execute(&mut self, byte: u8) {
        match byte {
            0x07 => self.bell = true,
            0x08 => {
                // BS：若当前格是宽字符右半格，回退两列
                self.pending_wrap = false;
                if self.cursor_x > 0 {
                    self.cursor_x -= 1;
                    let cell = self.cell(self.cursor_x, self.cursor_y);
                    if cell.attrs.flags & ATTR_WIDE_TAIL != 0 && self.cursor_x > 0 {
                        self.cursor_x -= 1;
                    }
                }
            }
            0x09 => self.tab_forward(1),
            0x0a | 0x0b | 0x0c => self.index(),
            0x0d => {
                self.pending_wrap = false;
                self.cursor_x = 0;
            }
            _ => {}
        }
    }

    // ---------- 滚动 ----------

    fn full_screen_region(&self) -> bool {
        self.scroll_top == 0 && self.scroll_bottom + 1 == self.rows
    }

    /// 调整回看行数上限；缩小时丢弃最旧的行，并同步移动提示符标记。
    pub fn set_history_limit(&mut self, limit: usize) {
        self.history_limit = limit;
        if self.history_limit == 0 {
            self.history.clear();
            self.history_wrap.clear();
            self.prompt_marks.clear();
            return;
        }
        while self.history.len() > self.history_limit {
            self.history.pop_front();
            self.history_wrap.pop_front();
            for mark in &mut self.prompt_marks {
                *mark = mark.saturating_sub(1);
            }
        }
    }

    /// 记录一个提示符位置（OSC 133;A）。
    pub fn record_prompt(&mut self) {
        let mark = self.history_len() + self.cursor_y;
        self.prompt_marks.push_back(mark);
        while self.prompt_marks.len() > 500 {
            self.prompt_marks.pop_front();
        }
    }

    pub fn scroll_up(&mut self, lines: usize) {
        let lines = lines.max(1).min(self.scroll_bottom - self.scroll_top + 1);
        let blank = self.blank_cell();
        let record = !self.alt_active && self.full_screen_region();
        for _ in 0..lines {
            if record {
                let row: Vec<Cell> = self.cells[0..self.cols].to_vec();
                let wrapped = self.wrap_flags[0];
                if self.history_limit > 0 {
                    self.history.push_back(row);
                    self.history_wrap.push_back(wrapped);
                    while self.history.len() > self.history_limit {
                        self.history.pop_front();
                        self.history_wrap.pop_front();
                        // 回看缓冲整体上移一行，提示符标记同步左移。
                        for mark in &mut self.prompt_marks {
                            *mark = mark.saturating_sub(1);
                        }
                    }
                }
            }
            let top = self.scroll_top;
            let bottom = self.scroll_bottom;
            let cols = self.cols;
            let height = bottom - top + 1;
            let region = &mut self.cells[top * cols..(bottom + 1) * cols];
            region.copy_within(cols..height * cols, 0);
            for x in 0..cols {
                self.cells[bottom * cols + x] = blank;
            }
            // 换行标记跟着内容一起上移。
            let height = bottom - top + 1;
            self.wrap_flags
                .copy_within(top + 1..top + height, top);
            self.wrap_flags[bottom] = false;
        }
    }

    pub fn scroll_down(&mut self, lines: usize) {
        let lines = lines.max(1).min(self.scroll_bottom - self.scroll_top + 1);
        let blank = self.blank_cell();
        for _ in 0..lines {
            let top = self.scroll_top;
            let bottom = self.scroll_bottom;
            let cols = self.cols;
            let height = bottom - top + 1;
            let region = &mut self.cells[top * cols..(bottom + 1) * cols];
            region.copy_within(0..(height - 1) * cols, cols);
            for x in 0..cols {
                self.cells[top * cols + x] = blank;
            }
            let height = bottom - top + 1;
            self.wrap_flags
                .copy_within(top..top + height - 1, top + 1);
            self.wrap_flags[top] = false;
        }
    }

    // ---------- 擦除 ----------

    pub fn erase_line(&mut self, mode: u32) {
        let blank = self.blank_cell();
        let y = self.cursor_y;
        match mode {
            0 => {
                for x in self.cursor_x..self.cols {
                    *self.cell_mut(x, y) = blank;
                }
            }
            1 => {
                for x in 0..=self.cursor_x.min(self.cols - 1) {
                    *self.cell_mut(x, y) = blank;
                }
            }
            2 => {
                for x in 0..self.cols {
                    *self.cell_mut(x, y) = blank;
                }
            }
            _ => {}
        }
        self.pending_wrap = false;
    }

    pub fn erase_display(&mut self, mode: u32) {
        let blank = self.blank_cell();
        match mode {
            0 => {
                self.erase_line(0);
                for y in self.cursor_y + 1..self.rows {
                    for x in 0..self.cols {
                        *self.cell_mut(x, y) = blank;
                    }
                }
            }
            1 => {
                self.erase_line(1);
                for y in 0..self.cursor_y {
                    for x in 0..self.cols {
                        *self.cell_mut(x, y) = blank;
                    }
                }
            }
            2 | 3 => {
                for y in 0..self.rows {
                    for x in 0..self.cols {
                        *self.cell_mut(x, y) = blank;
                    }
                }
                if mode == 3 && !self.alt_active {
                    self.history.clear();
                    self.history_wrap.clear();
                    self.prompt_marks.clear();
                }
            }
            _ => {}
        }
        self.pending_wrap = false;
    }

    pub fn erase_chars(&mut self, n: usize) {
        let blank = self.blank_cell();
        let end = (self.cursor_x + n).min(self.cols);
        for x in self.cursor_x..end {
            *self.cell_mut(x, self.cursor_y) = blank;
        }
    }

    pub fn insert_chars(&mut self, n: usize) {
        let cols = self.cols;
        let y = self.cursor_y;
        let start = y * cols + self.cursor_x;
        let end = y * cols + cols;
        let n = n.min(cols - self.cursor_x);
        if n == 0 {
            return;
        }
        let len = end - start;
        self.cells[start..end].copy_within(0..len - n, n);
        let blank = self.blank_cell();
        for x in self.cursor_x..self.cursor_x + n {
            *self.cell_mut(x, y) = blank;
        }
    }

    pub fn delete_chars(&mut self, n: usize) {
        let cols = self.cols;
        let y = self.cursor_y;
        let start = y * cols + self.cursor_x;
        let end = y * cols + cols;
        let n = n.min(cols - self.cursor_x);
        if n == 0 {
            return;
        }
        let len = end - start;
        self.cells[start..end].copy_within(n..len, 0);
        let blank = self.blank_cell();
        for x in cols - n..cols {
            *self.cell_mut(x, y) = blank;
        }
    }

    pub fn insert_lines(&mut self, n: usize) {
        if self.cursor_y < self.scroll_top || self.cursor_y > self.scroll_bottom {
            return;
        }
        let saved_top = self.scroll_top;
        self.scroll_top = self.cursor_y;
        self.scroll_down(n);
        self.scroll_top = saved_top;
    }

    pub fn delete_lines(&mut self, n: usize) {
        if self.cursor_y < self.scroll_top || self.cursor_y > self.scroll_bottom {
            return;
        }
        let saved_top = self.scroll_top;
        self.scroll_top = self.cursor_y;
        self.scroll_up(n);
        self.scroll_top = saved_top;
    }

    // ---------- 光标与制表 ----------

    pub fn goto(&mut self, x: usize, y: usize) {
        self.pending_wrap = false;
        let y = if self.origin_mode {
            (self.scroll_top + y).min(self.scroll_bottom)
        } else {
            y.min(self.rows - 1)
        };
        self.cursor_y = y;
        self.cursor_x = x.min(self.cols - 1);
    }

    pub fn move_up(&mut self, n: usize) {
        self.pending_wrap = false;
        let limit = if self.cursor_y >= self.scroll_top {
            self.scroll_top
        } else {
            0
        };
        self.cursor_y = self.cursor_y.saturating_sub(n).max(limit);
    }

    pub fn move_down(&mut self, n: usize) {
        self.pending_wrap = false;
        let limit = if self.cursor_y <= self.scroll_bottom {
            self.scroll_bottom
        } else {
            self.rows - 1
        };
        self.cursor_y = (self.cursor_y + n).min(limit);
    }

    pub fn move_left(&mut self, n: usize) {
        self.pending_wrap = false;
        self.cursor_x = self.cursor_x.saturating_sub(n);
    }

    pub fn move_right(&mut self, n: usize) {
        self.pending_wrap = false;
        self.cursor_x = (self.cursor_x + n).min(self.cols - 1);
    }

    pub fn tab_forward(&mut self, n: usize) {
        self.pending_wrap = false;
        for _ in 0..n.max(1) {
            let mut x = self.cursor_x + 1;
            while x < self.cols && !self.tabs[x] {
                x += 1;
            }
            self.cursor_x = x.min(self.cols - 1);
            if x >= self.cols {
                break;
            }
        }
    }

    pub fn tab_backward(&mut self, n: usize) {
        self.pending_wrap = false;
        for _ in 0..n.max(1) {
            let mut x = self.cursor_x;
            while x > 0 {
                x -= 1;
                if self.tabs[x] {
                    break;
                }
            }
            self.cursor_x = x;
            if x == 0 {
                break;
            }
        }
    }

    pub fn set_tab_stop(&mut self) {
        self.tabs[self.cursor_x] = true;
    }

    pub fn clear_tab_stops(&mut self, mode: u32) {
        match mode {
            0 => self.tabs[self.cursor_x] = false,
            3 => {
                for t in self.tabs.iter_mut() {
                    *t = false;
                }
            }
            _ => {}
        }
    }

    pub fn save_cursor(&mut self) {
        self.saved_cursor = (self.cursor_x, self.cursor_y, self.attrs);
    }

    pub fn restore_cursor(&mut self) {
        let (x, y, attrs) = self.saved_cursor;
        self.cursor_x = x.min(self.cols - 1);
        self.cursor_y = y.min(self.rows - 1);
        self.attrs = attrs;
        self.pending_wrap = false;
    }

    pub fn set_scroll_region(&mut self, top: u32, bottom: u32) {
        let top = (top.max(1) as usize - 1).min(self.rows - 1);
        let bottom = if bottom == 0 {
            self.rows - 1
        } else {
            (bottom as usize - 1).min(self.rows - 1)
        };
        if top < bottom {
            self.scroll_top = top;
            self.scroll_bottom = bottom;
            self.goto(0, 0);
            self.pending_wrap = false;
        }
    }

    pub fn reset_scroll_region(&mut self) {
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
    }

    // ---------- SGR ----------

    pub fn sgr(&mut self, params: &[u32]) {
        if params.is_empty() {
            self.attrs = Attrs::default();
            return;
        }
        let mut i = 0;
        while i < params.len() {
            let p = params[i];
            match p {
                0 => self.attrs = Attrs::default(),
                1 => self.attrs.flags |= ATTR_BOLD,
                2 => self.attrs.flags |= ATTR_DIM,
                3 => self.attrs.flags |= ATTR_ITALIC,
                4 => self.attrs.flags |= ATTR_UNDERLINE,
                5 | 6 => self.attrs.flags |= ATTR_BLINK,
                7 => self.attrs.flags |= ATTR_REVERSE,
                8 => self.attrs.flags |= ATTR_HIDDEN,
                9 => self.attrs.flags |= ATTR_STRIKE,
                21 | 22 => self.attrs.flags &= !(ATTR_BOLD | ATTR_DIM),
                23 => self.attrs.flags &= !ATTR_ITALIC,
                24 => self.attrs.flags &= !ATTR_UNDERLINE,
                25 => self.attrs.flags &= !ATTR_BLINK,
                27 => self.attrs.flags &= !ATTR_REVERSE,
                28 => self.attrs.flags &= !ATTR_HIDDEN,
                29 => self.attrs.flags &= !ATTR_STRIKE,
                30..=37 => self.attrs.fg = Color::Indexed((p - 30) as u8),
                39 => self.attrs.fg = Color::Default,
                40..=47 => self.attrs.bg = Color::Indexed((p - 40) as u8),
                49 => self.attrs.bg = Color::Default,
                90..=97 => self.attrs.fg = Color::Indexed((p - 90 + 8) as u8),
                100..=107 => self.attrs.bg = Color::Indexed((p - 100 + 8) as u8),
                38 | 48 | 58 => {
                    let is_fg = p == 38;
                    let color = match params.get(i + 1).copied() {
                        Some(5) => {
                            let idx = params.get(i + 2).copied().unwrap_or(0) as u8;
                            i += 2;
                            Color::Indexed(idx)
                        }
                        Some(2) => {
                            let r = params.get(i + 2).copied().unwrap_or(0) as u8;
                            let g = params.get(i + 3).copied().unwrap_or(0) as u8;
                            let b = params.get(i + 4).copied().unwrap_or(0) as u8;
                            i += 4;
                            Color::Rgb(r, g, b)
                        }
                        _ => {
                            i += 1;
                            Color::Default
                        }
                    };
                    if is_fg {
                        self.attrs.fg = color;
                    } else if p == 48 {
                        self.attrs.bg = color;
                    }
                }
                _ => {}
            }
            i += 1;
        }
    }

    // ---------- 备用屏幕 ----------

    pub fn set_alt_screen(&mut self, active: bool, save_cursor: bool) {
        if active == self.alt_active {
            return;
        }
        if active {
            if save_cursor {
                self.save_cursor();
            }
            self.main_cells = self.cells.clone();
            self.main_cursor = (self.cursor_x, self.cursor_y);
            self.alt_active = true;
            let blank = Cell::default();
            for c in self.cells.iter_mut() {
                *c = blank;
            }
            self.cursor_x = 0;
            self.cursor_y = 0;
            self.pending_wrap = false;
            self.reset_scroll_region();
        } else {
            let main = std::mem::take(&mut self.main_cells);
            if main.len() == self.cells.len() {
                self.cells = main;
            } else {
                let blank = Cell::default();
                for c in self.cells.iter_mut() {
                    *c = blank;
                }
            }
            self.alt_active = false;
            self.cursor_x = self.main_cursor.0.min(self.cols - 1);
            self.cursor_y = self.main_cursor.1.min(self.rows - 1);
            self.pending_wrap = false;
            if save_cursor {
                self.restore_cursor();
            }
            self.reset_scroll_region();
        }
    }

    // ---------- 尺寸 ----------

    /// 某绝对行是否因为自动换行而延续到下一行。
    fn row_wrapped(&self, abs: usize) -> bool {
        if abs < self.history.len() {
            self.history_wrap.get(abs).copied().unwrap_or(false)
        } else {
            let y = abs - self.history.len();
            self.wrap_flags.get(y).copied().unwrap_or(false)
        }
    }

    /// 尺寸变化：宽度改变时按「自动换行」标记重排（Reflow），高度改变时只裁切。
    ///
    /// 备用屏幕（全屏程序自己会重画）保持 ConPTY 的裁切行为。
    pub fn resize(&mut self, cols: usize, rows: usize) {
        let cols = cols.max(1);
        let rows = rows.max(1);
        if cols == self.cols && rows == self.rows {
            return;
        }
        if cols != self.cols && !self.alt_active {
            self.reflow(cols, rows);
            return;
        }
        self.crop(cols, rows);
    }

    /// 只把内容裁剪/补空到新尺寸（不重排）。
    fn crop(&mut self, cols: usize, rows: usize) {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let mut next = vec![Cell::default(); cols * rows];
        let copy_cols = cols.min(self.cols);
        let copy_rows = rows.min(self.rows);
        for y in 0..copy_rows {
            for x in 0..copy_cols {
                next[y * cols + x] = self.cells[y * self.cols + x];
            }
        }
        let mut wrap_flags = vec![false; rows];
        for y in 0..copy_rows {
            wrap_flags[y] = self.wrap_flags.get(y).copied().unwrap_or(false);
        }
        self.cells = next;
        self.wrap_flags = wrap_flags;
        if self.alt_active {
            let mut main = vec![Cell::default(); cols * rows];
            let mc = cols.min(self.cols);
            let mr = rows.min(self.main_cells.len() / self.cols.max(1));
            for y in 0..mr {
                for x in 0..mc {
                    main[y * cols + x] = self.main_cells[y * self.cols + x];
                }
            }
            self.main_cells = main;
        }
        self.cols = cols;
        self.rows = rows;
        self.last_cell = None;
        let mut tabs = vec![false; cols];
        for (i, t) in tabs.iter_mut().enumerate() {
            *t = i % 8 == 0;
        }
        self.tabs = tabs;
        self.cursor_x = self.cursor_x.min(cols - 1);
        self.cursor_y = self.cursor_y.min(rows - 1);
        self.reset_scroll_region();
        self.pending_wrap = false;
    }

    /// 按新宽度重排：先按换行标记拼回逻辑行，再按新宽度折行。
    ///
    /// 光标、提示符标记都跟着映射到新位置；回看缓冲超出的旧行按上限丢弃。
    fn reflow(&mut self, cols: usize, rows: usize) {
        const REFLOW_MAX_ROWS: usize = 4000;
        let old_cols = self.cols;
        let hist_len = self.history.len();
        let total = hist_len + self.rows;
        if old_cols == 0 || total == 0 || total > REFLOW_MAX_ROWS {
            self.crop(cols, rows);
            return;
        }

        // 1) 把被自动换行打断的物理行拼回逻辑行。
        let mut logical: Vec<Vec<Cell>> = Vec::new();
        let mut line_of = vec![0usize; total];
        let mut offset_in = vec![0usize; total];
        for abs in 0..total {
            let mut row_cells: Vec<Cell> = if abs < hist_len {
                self.history[abs].clone()
            } else {
                let y = abs - hist_len;
                self.cells[y * old_cols..(y + 1) * old_cols].to_vec()
            };
            if abs > 0 && self.row_wrapped(abs - 1) {
                offset_in[abs] = logical.last().map(|l| l.len()).unwrap_or(0);
                line_of[abs] = logical.len().saturating_sub(1);
                if let Some(line) = logical.last_mut() {
                    line.extend_from_slice(&row_cells);
                    continue;
                }
            }
            // 行尾空白不参与折行，否则右侧留白会把内容顶走。
            while matches!(row_cells.last(), Some(c) if c.ch == ' '
                && c.combining == 0
                && c.link == 0
                && c.attrs.fg == Color::Default
                && c.attrs.bg == Color::Default
                && c.attrs.flags == 0)
            {
                row_cells.pop();
            }
            offset_in[abs] = 0;
            line_of[abs] = logical.len();
            logical.push(row_cells);
        }

        // 2) 按新宽度折行。
        let mut out_rows: Vec<Vec<Cell>> = Vec::new();
        let mut out_wrap: Vec<bool> = Vec::new();
        let mut line_start = vec![0usize; logical.len()];
        for (index, line) in logical.iter().enumerate() {
            line_start[index] = out_rows.len();
            if line.is_empty() {
                out_rows.push(vec![Cell::default(); cols]);
                out_wrap.push(false);
                continue;
            }
            let chunks = (line.len() + cols - 1) / cols;
            for chunk in 0..chunks {
                let start = chunk * cols;
                let end = (start + cols).min(line.len());
                let mut row = vec![Cell::default(); cols];
                row[..end - start].copy_from_slice(&line[start..end]);
                out_rows.push(row);
                out_wrap.push(chunk + 1 < chunks);
            }
        }

        // 3) 光标映射到新的视觉坐标。
        let cursor_abs = (hist_len + self.cursor_y).min(total - 1);
        let cursor_line = line_of[cursor_abs];
        let cursor_offset = offset_in[cursor_abs] + self.cursor_x.min(old_cols - 1);
        let cursor_row = line_start[cursor_line] + cursor_offset / cols;
        let cursor_col = cursor_offset % cols;

        // 4) 切分为回看缓冲 + 屏幕。
        let total_out = out_rows.len();
        let keep_on_screen = total_out.min(rows);
        let hist_take = total_out - keep_on_screen;
        let limit = self.history_limit;
        let mut new_history: VecDeque<Vec<Cell>> = VecDeque::new();
        let mut new_wrap: VecDeque<bool> = VecDeque::new();
        let mut dropped = 0usize;
        for i in 0..hist_take {
            new_history.push_back(std::mem::take(&mut out_rows[i]));
            new_wrap.push_back(out_wrap[i]);
            while new_history.len() > limit {
                new_history.pop_front();
                new_wrap.pop_front();
                dropped += 1;
            }
        }

        let pad = 0usize;
        let mut new_cells = vec![Cell::default(); cols * rows];
        for (k, row) in out_rows[hist_take..].iter().enumerate() {
            let y = k;
            if y >= rows {
                break;
            }
            new_cells[y * cols..(y + 1) * cols].copy_from_slice(row);
        }
        let mut wrap_flags = vec![false; rows];
        for (k, wrapped) in out_wrap[hist_take..].iter().enumerate() {
            if k < rows {
                wrap_flags[k] = *wrapped;
            }
        }

        // 5) 提示符标记与光标按同一映射搬过去。
        let history_len = new_history.len();
        let map_row = |out_row: usize| -> usize {
            if out_row < hist_take {
                out_row.saturating_sub(dropped)
            } else {
                history_len + pad + (out_row - hist_take)
            }
        };
        let mut marks: VecDeque<usize> = VecDeque::new();
        for mark in self.prompt_marks.drain(..) {
            if mark >= total {
                continue;
            }
            let line = line_of[mark];
            let out_row = line_start[line] + offset_in[mark] / cols;
            marks.push_back(map_row(out_row));
        }
        self.prompt_marks = marks;

        self.history = new_history;
        self.history_wrap = new_wrap;
        self.cells = new_cells;
        self.wrap_flags = wrap_flags;
        self.cols = cols;
        self.rows = rows;
        let mut tabs = vec![false; cols];
        for (i, t) in tabs.iter_mut().enumerate() {
            *t = i % 8 == 0;
        }
        self.tabs = tabs;
        // cursor_row 是「新视觉行」的绝对下标，换算回屏幕内的行号。
        self.cursor_y = if cursor_row < hist_take {
            0
        } else {
            (pad + (cursor_row - hist_take)).min(rows - 1)
        };
        self.cursor_x = cursor_col.min(cols - 1);
        self.last_cell = None;
        self.reset_scroll_region();
        self.pending_wrap = false;
    }


    pub fn reset(&mut self) {
        let cols = self.cols;
        let rows = self.rows;
        let history_limit = self.history_limit;
        *self = Screen::new(cols, rows, history_limit);
    }

    /// 光标位置上报（DSR 6）。
    pub fn respond_cursor_position(&mut self) {
        let s = format!("\x1b[{};{}R", self.cursor_y + 1, self.cursor_x + 1);
        self.responses.extend_from_slice(s.as_bytes());
    }

    /// DECXCPR（CSI ? 6 n）：带私有标记的光标位置上报。
    pub fn respond_cursor_position_private(&mut self) {
        let s = format!("\x1b[?{};{}R", self.cursor_y + 1, self.cursor_x + 1);
        self.responses.extend_from_slice(s.as_bytes());
    }

    /// DSR 5：设备状态正常。
    pub fn respond_status(&mut self) {
        self.responses.extend_from_slice(b"\x1b[0n");
    }

    pub fn respond_device_attributes(&mut self, secondary: bool) {
        if secondary {
            self.responses.extend_from_slice(b"\x1b[>0;276;0c");
        } else {
            self.responses.extend_from_slice(b"\x1b[?1;2c");
        }
    }

    pub fn respond_mode(&mut self, private: bool, mode: u32, set: bool) {
        let state = if set { 1 } else { 2 };
        let s = if private {
            format!("\x1b[?{mode};{state}$y")
        } else {
            format!("\x1b[{mode};{state}$y")
        };
        self.responses.extend_from_slice(s.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wide_char_occupies_two_cells() {
        let mut s = Screen::new(10, 3, 100);
        s.print('中');
        assert_eq!(s.cell(0, 0).ch, '中');
        assert_ne!(s.cell(1, 0).attrs.flags & ATTR_WIDE_TAIL, 0);
        assert_eq!(s.cursor_x, 2);
    }

    #[test]
    fn pending_wrap_defers_to_next_char() {
        let mut s = Screen::new(4, 3, 100);
        for ch in "abcd".chars() {
            s.print(ch);
        }
        assert_eq!(s.cursor_x, 3, "写满一行后光标停在最后一列");
        s.print('e');
        assert_eq!(s.cell(0, 1).ch, 'e', "下一个字符才换行");
    }

    #[test]
    fn scroll_pushes_history_only_for_main_screen() {
        let mut s = Screen::new(4, 2, 10);
        s.print('a');
        s.newline();
        s.print('b');
        s.newline(); // 触底滚动一次，第一行进入回看缓冲
        s.print('c');
        assert_eq!(s.history_len(), 1);
        assert_eq!(s.cell(0, 0).ch, 'b');
        assert_eq!(s.cell(0, 1).ch, 'c');
    }

    #[test]
    fn alt_screen_restores_main_content() {
        let mut s = Screen::new(4, 2, 10);
        s.print('x');
        s.set_alt_screen(true, true);
        assert_eq!(s.cell(0, 0).ch, ' ', "备用屏幕应为空白");
        s.print('y');
        s.set_alt_screen(false, true);
        assert_eq!(s.cell(0, 0).ch, 'x');
    }

    #[test]
    fn sgr_256_and_truecolor() {
        let mut s = Screen::new(4, 2, 10);
        s.sgr(&[38, 5, 196]);
        assert_eq!(s.attrs.fg, Color::Indexed(196));
        s.sgr(&[48, 2, 10, 20, 30]);
        assert_eq!(s.attrs.bg, Color::Rgb(10, 20, 30));
        s.sgr(&[0]);
        assert_eq!(s.attrs, Attrs::default());
    }

    #[test]
    fn combining_mark_composes_latin() {
        let mut s = Screen::new(10, 2, 100);
        s.print('e');
        s.print('\u{301}');
        assert_eq!(s.cell(0, 0).ch, 'é', "拉丁字母 + 重音应合成预组合字符");
        assert_eq!(s.cell(0, 0).combining, 0);
        assert_eq!(s.cursor_x, 1, "组合符不占列宽");
    }

    #[test]
    fn combining_mark_is_stored_when_not_composable() {
        let mut s = Screen::new(10, 2, 100);
        s.print('中');
        s.print('\u{301}');
        let cell = s.cell(0, 0);
        assert_eq!(cell.ch, '中');
        assert_ne!(cell.combining, 0, "合成不了时留在组合串里");
        let marks = combining_text(cell.combining).unwrap_or_default();
        assert_eq!(marks, "\u{301}");
    }

    #[test]
    fn leading_combining_mark_is_ignored() {
        let mut s = Screen::new(10, 2, 100);
        s.print('\u{301}');
        assert_eq!(s.cell(0, 0).ch, ' ');
    }

    #[test]
    fn reflow_rewraps_wrapped_lines() {
        let mut s = Screen::new(10, 3, 100);
        for ch in "0123456789abcde".chars() {
            s.print(ch);
        }
        assert_eq!(s.cell(4, 1).ch, 'e');
        s.resize(20, 3);
        assert_eq!(s.cell(14, 0).ch, 'e', "变宽后整行回到一行");
        assert_eq!(s.cell(0, 1).ch, ' ', "下面那行回到空白");
        assert_eq!(s.cursor_y, 0);
        assert_eq!(s.cursor_x, 15);
    }

    #[test]
    fn reflow_keeps_explicit_line_breaks() {
        let mut s = Screen::new(10, 3, 100);
        for ch in "abc".chars() {
            s.print(ch);
        }
        s.newline();
        for ch in "def".chars() {
            s.print(ch);
        }
        s.resize(20, 3);
        assert_eq!(s.cell(0, 0).ch, 'a');
        assert_eq!(s.cell(0, 1).ch, 'd', "回车换行不会被当成折行");
    }

    #[test]
    fn reflow_narrowing_pushes_rows_into_history() {
        let mut s = Screen::new(40, 3, 100);
        s.newline();
        s.newline();
        for ch in "0123456789abcdefghijklmnopqrst".chars() {
            s.print(ch);
        }
        assert_eq!(s.cursor_y, 2);
        s.resize(20, 3);
        assert_eq!(s.history_len(), 1, "多出来的视觉行进入回看缓冲");
        assert_eq!(s.cell(0, 1).ch, '0');
        assert_eq!(s.cell(19, 1).ch, 'j');
        assert_eq!(s.cell(0, 2).ch, 'k');
        assert_eq!(s.cell(9, 2).ch, 't');
        assert_eq!(s.cursor_y, 2);
    }
}

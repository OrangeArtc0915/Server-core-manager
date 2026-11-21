//! 编辑器应用层：标签页、布局、输入处理、命令与浮层。
//!
//! 同一套状态机同时服务 TUI 与 GUI 后端：后端只负责把 `Canvas` 画出来，
//! 以及把键盘 / 鼠标事件转成 [`Event`]。

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::config::Config;
use crate::core::diff::{self, LineMark};
use crate::core::document::{Cursor, Document, Pos};
use crate::core::fold::Folds;
use crate::core::highlight::{self, LexState, Token};
use crate::core::language::Language;
use crate::core::search::{SearchEngine, SearchOptions};
use crate::platform::clipboard;
use crate::platform::console::{Key, KeyCode, Mods};
use crate::ui::editor;
use crate::ui::theme::{self, Theme};

// ---------------------------------------------------------------- 标签页

pub struct HighlightCache {
    lines: Vec<LineHl>,
    revision: u64,
}

struct LineHl {
    hash: u64,
    state_before: LexState,
    state_after: LexState,
    tokens: Vec<Token>,
}

impl HighlightCache {
    fn new() -> HighlightCache {
        HighlightCache {
            lines: Vec::new(),
            revision: u64::MAX,
        }
    }

    fn refresh(&mut self, doc: &Document) {
        if self.revision == doc.revision && self.lines.len() == doc.line_count() {
            return;
        }
        let mut state = LexState::Normal;
        for line in 0..doc.line_count() {
            let text = doc.line(line);
            let hash = fnv(text);
            if let Some(cached) = self.lines.get(line) {
                if cached.hash == hash && cached.state_before == state {
                    state = cached.state_after;
                    continue;
                }
            }
            let mut next = state;
            let tokens = highlight::highlight(doc.language, text, &mut next);
            let entry = LineHl {
                hash,
                state_before: state,
                state_after: next,
                tokens,
            };
            if line < self.lines.len() {
                self.lines[line] = entry;
            } else {
                self.lines.push(entry);
            }
            state = next;
        }
        self.lines.truncate(doc.line_count());
        self.revision = doc.revision;
    }

    fn tokens(&self, line: usize) -> &[Token] {
        self.lines
            .get(line)
            .map(|l| l.tokens.as_slice())
            .unwrap_or(&[])
    }
}

fn fnv(text: &str) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in text.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

/// 已关闭标签页的快照，用于 Ctrl+Shift+T 重新打开。
#[derive(Clone)]
pub struct ClosedTab {
    pub path: Option<PathBuf>,
    pub text: String,
    pub title: String,
    pub cursor: Pos,
    pub preview: bool,
}

pub struct Tab {
    pub doc: Document,
    pub folds: Folds,
    cache: HighlightCache,
    pub rows: Vec<editor::VisualRow>,
    rows_key: u64,
    pub top_row: usize,
    /// Git 边条标记（相对 HEAD）。
    pub git_marks: Vec<LineMark>,
    pub git_revision: u64,
    /// 只读预览（diff / 图片信息等）。
    pub preview: bool,
    /// 图片标签页的解码结果（文本标签为 None）。
    pub image: Option<crate::image::Image>,
    /// Word 文档（段落正文复用 `doc.lines`）。
    pub word: Option<crate::docx::WordDoc>,
    pub word_styles: Vec<crate::docx::Flags>,
    /// Excel 工作簿（网格模式）。
    pub excel: Option<crate::xlsx::Workbook>,
}

impl Tab {
    pub fn new(doc: Document, config: &Config) -> Tab {
        let mut tab = Tab {
            doc,
            folds: Folds::default(),
            cache: HighlightCache::new(),
            rows: Vec::new(),
            rows_key: u64::MAX,
            top_row: 0,
            git_marks: Vec::new(),
            git_revision: 0,
            preview: false,
            image: None,
            word: None,
            word_styles: Vec::new(),
            excel: None,
        };
        tab.apply_config(config);
        tab.refresh(config, 80, false);
        tab
    }

    pub fn apply_config(&mut self, config: &Config) {
        self.doc.tab_width = config.tab_width;
        self.doc.use_spaces = config.use_spaces;
        self.doc.auto_indent = config.auto_indent;
        self.doc.wrap = config.wrap;
    }

    fn rows_key(&self, width: usize, wrap: bool) -> u64 {
        let mut key = self.doc.revision;
        key ^= (width as u64).wrapping_mul(0x9e3779b97f4a7c15);
        key ^= u64::from(wrap) << 61;
        key ^= (self.folds.collapsed.len() as u64) << 47;
        for start in &self.folds.collapsed {
            key ^= (*start as u64).wrapping_mul(0x100000001b3);
        }
        key
    }

    /// 重新计算折叠、高亮与视觉行。
    pub fn refresh(&mut self, config: &Config, width: usize, force_rows: bool) {
        self.apply_config(config);
        let collapsed_before = self.folds.collapsed.clone();
        self.folds
            .recompute(&self.doc.lines, config.tab_width, config.folding);
        // recompute 会清理失效的折叠行号；若发生变化则重建视觉行
        let collapsed_changed = collapsed_before != self.folds.collapsed;
        self.cache.refresh(&self.doc);
        let key = self.rows_key(width, self.doc.wrap);
        if key != self.rows_key || force_rows || collapsed_changed {
            self.rows = editor::build_rows(&self.doc, &self.folds, width, self.doc.wrap);
            self.rows_key = key;
            if self.top_row >= self.rows.len() {
                self.top_row = self.rows.len().saturating_sub(1);
            }
        }
    }

    pub fn tokens(&self, line: usize) -> &[Token] {
        self.cache.tokens(line)
    }

    pub fn cursor_row(&self) -> usize {
        editor::row_of_pos(&self.rows, self.doc.primary().pos)
    }

    pub fn ensure_visible(&mut self, height: usize) {
        if height == 0 || self.rows.is_empty() {
            return;
        }
        let row = self.cursor_row();
        if row < self.top_row {
            self.top_row = row;
        } else if row >= self.top_row + height {
            self.top_row = row + 1 - height;
        }
        let max = self.rows.len().saturating_sub(1);
        self.top_row = self.top_row.min(max);
    }

    /// 与 HEAD 比较，刷新 Git 边条。
    pub fn refresh_git(&mut self, root: Option<&Path>) {
        if self.preview || self.word.is_some() || self.excel.is_some() || self.image.is_some() {
            return;
        }
        if self.git_revision == self.doc.revision {
            return;
        }
        let Some(root) = root else {
            self.git_marks.clear();
            self.git_revision = self.doc.revision;
            return;
        };
        let Some(path) = self.doc.path.clone() else {
            self.git_marks.clear();
            self.git_revision = self.doc.revision;
            return;
        };
        match crate::vcs::git::head_lines(root, &path) {
            Some(head) => {
                self.git_marks = diff::line_marks(&head, &self.doc.lines);
            }
            None => self.git_marks.clear(),
        }
        self.git_revision = self.doc.revision;
    }

    /// 状态栏 / 面包屑显示的文件类型。
    pub fn format_label(&self) -> &'static str {
        if self.image.is_some() {
            "图片"
        } else if self.word.is_some() {
            "Word"
        } else if self.excel.is_some() {
            "Excel"
        } else {
            self.doc.language.label()
        }
    }

    pub fn is_excel(&self) -> bool {
        self.excel.is_some()
    }

    /// 保存当前标签：Word / Excel 走各自的打包逻辑。
    pub fn save_document(&mut self) -> Result<(), String> {
        let path = self
            .doc
            .path
            .clone()
            .ok_or_else(|| "尚未指定文件名，请使用「另存为」".to_string())?;
        if let Some(word) = &mut self.word {
            word.save(&path, &self.doc.lines, &self.word_styles)?;
            self.word_styles = word.styles();
            self.doc.mark_saved();
            return Ok(());
        }
        if let Some(book) = &mut self.excel {
            book.save(&path)?;
            self.doc.mark_saved();
            return Ok(());
        }
        self.doc.save()
    }
}

// ---------------------------------------------------------------- 布局

#[derive(Clone, Copy, Default, Debug)]
pub struct Rect {
    pub x: usize,
    pub y: usize,
    pub w: usize,
    pub h: usize,
}

impl Rect {
    pub fn contains(&self, x: usize, y: usize) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }

    pub fn right(&self) -> usize {
        self.x + self.w
    }

    pub fn bottom(&self) -> usize {
        self.y + self.h
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LayoutStyle {
    /// sqlmux：双 pane、无顶部栏、标签在 pane 底部。
    Sqlmux,
    /// VSCode：顶部菜单 + 顶部标签 + 左侧活动栏。
    Vscode,
}

impl LayoutStyle {
    pub fn from_config(text: &str) -> LayoutStyle {
        if text.eq_ignore_ascii_case("sqlmux") {
            LayoutStyle::Sqlmux
        } else {
            LayoutStyle::Vscode
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SplitKind {
    /// 左右分栏。
    Vertical,
    /// 上下分栏。
    Horizontal,
}

/// 一个编辑器 pane 内部的几何。
#[derive(Clone, Copy, Default)]
pub struct PaneRects {
    pub editor: Rect,
    pub tabs: Rect,
    pub breadcrumbs: Rect,
    pub gutter: usize,
    pub text: Rect,
    pub minimap: Option<Rect>,
}

#[derive(Clone, Default)]
pub struct Layout {
    pub cols: usize,
    pub rows: usize,
    /// 侧栏 pane（带边框），未显示时为 None。
    pub sidebar: Option<Rect>,
    /// 侧栏 pane 底部的标签行（资源管理器 / 搜索 / Git）。
    pub sidebar_tabs: Rect,
    /// 第一个编辑器 pane（兼容旧代码）。
    pub editor: Rect,
    pub editor_tabs: Rect,
    pub gutter: usize,
    pub text: Rect,
    pub minimap: Option<Rect>,
    pub status: Rect,
    pub breadcrumbs: Rect,
    /// 全部编辑器 pane（1 或 2 个）。
    pub panes: Vec<PaneRects>,
    /// 底部终端面板。
    pub terminal: Option<Rect>,
    /// VSCode 布局：顶部菜单栏。
    pub menu: Option<Rect>,
    /// VSCode 布局：顶部标签栏。
    pub tabs_top: Option<Rect>,
    /// VSCode 布局：左侧活动栏。
    pub activity: Option<Rect>,
    /// 当前布局风格。
    pub style: LayoutStyle,
}

impl Default for LayoutStyle {
    fn default() -> Self {
        LayoutStyle::Vscode
    }
}

impl Layout {
    pub fn compute(cols: usize, rows: usize, config: &Config) -> Layout {
        let style = LayoutStyle::from_config(&config.layout);
        Layout::compute_ext(cols, rows, config, style, None, 0, 0)
    }

    pub fn compute_ext(
        cols: usize,
        rows: usize,
        config: &Config,
        style: LayoutStyle,
        split: Option<SplitKind>,
        split_ratio: usize,
        term_height: usize,
    ) -> Layout {
        let cols = cols.max(20);
        let rows = rows.max(8);
        let status = Rect {
            x: 0,
            y: rows - 1,
            w: cols,
            h: 1,
        };
        let (menu, tabs_top, activity, content_y, mut pane_h) = match style {
            LayoutStyle::Sqlmux => (None, None, None, 0usize, rows.saturating_sub(1)),
            LayoutStyle::Vscode => {
                let menu = Rect {
                    x: 0,
                    y: 0,
                    w: cols,
                    h: 1,
                };
                let tabs = Rect {
                    x: 0,
                    y: 1,
                    w: cols,
                    h: 1,
                };
                let pane_h = rows.saturating_sub(3);
                let activity = Rect {
                    x: 0,
                    y: 2,
                    w: 3,
                    h: pane_h,
                };
                (Some(menu), Some(tabs), Some(activity), 2usize, pane_h)
            }
        };
        let mut x = activity.map(|a| a.right()).unwrap_or(0);
        let sidebar = if config.sidebar {
            let width = config
                .sidebar_width
                .min(cols.saturating_mul(2) / 5)
                .max(14)
                .min(cols.saturating_sub(12).max(14));
            let rect = Rect {
                x,
                y: content_y,
                w: width,
                h: pane_h,
            };
            // pane 之间留 1 列间隙。
            x = rect.right() + 1;
            Some(rect)
        } else {
            None
        };
        let mut term = None;
        if term_height > 0 && pane_h > term_height + 6 {
            pane_h -= term_height + 1;
            term = Some(Rect {
                x,
                y: content_y + pane_h + 1,
                w: cols.saturating_sub(x),
                h: term_height,
            });
        }
        let area = Rect {
            x,
            y: content_y,
            w: cols.saturating_sub(x),
            h: pane_h,
        };
        let editors = match split {
            None => vec![area],
            Some(kind) => match kind {
                SplitKind::Vertical => {
                    let usable = area.w.saturating_sub(1);
                    let left = (usable * split_ratio.clamp(20, 80) / 100).max(16);
                    let left = left.min(usable.saturating_sub(16));
                    vec![
                        Rect {
                            x: area.x,
                            y: area.y,
                            w: left,
                            h: area.h,
                        },
                        Rect {
                            x: area.x + left + 1,
                            y: area.y,
                            w: usable.saturating_sub(left),
                            h: area.h,
                        },
                    ]
                }
                SplitKind::Horizontal => {
                    let usable = area.h.saturating_sub(1);
                    let top = (usable * split_ratio.clamp(20, 80) / 100).max(6);
                    let top = top.min(usable.saturating_sub(6));
                    vec![
                        Rect {
                            x: area.x,
                            y: area.y,
                            w: area.w,
                            h: top,
                        },
                        Rect {
                            x: area.x,
                            y: area.y + top + 1,
                            w: area.w,
                            h: usable.saturating_sub(top),
                        },
                    ]
                }
            },
        };
        let bottom_tabs = style == LayoutStyle::Sqlmux;
        let panes: Vec<PaneRects> = editors
            .iter()
            .map(|rect| Self::pane(config, *rect, bottom_tabs))
            .collect();
        let first = panes.first().copied().unwrap_or_default();
        let sidebar_tabs = sidebar
            .map(|s| Rect {
                x: s.x + 1,
                y: s.bottom().saturating_sub(2),
                w: s.w.saturating_sub(2),
                h: 1,
            })
            .unwrap_or_default();
        Layout {
            cols,
            rows,
            sidebar,
            sidebar_tabs,
            editor: first.editor,
            editor_tabs: first.tabs,
            gutter: first.gutter,
            text: first.text,
            minimap: first.minimap,
            status,
            breadcrumbs: first.breadcrumbs,
            panes,
            terminal: term,
            menu,
            tabs_top,
            activity,
            style,
        }
    }

    fn pane(config: &Config, editor: Rect, bottom_tabs: bool) -> PaneRects {
        let h = editor.h;
        let tabs = if bottom_tabs {
            Rect {
                x: editor.x + 1,
                y: editor.bottom().saturating_sub(2),
                w: editor.w.saturating_sub(2),
                h: 1,
            }
        } else {
            Rect::default()
        };
        let breadcrumbs = Rect {
            x: editor.x + 1,
            y: editor.y + 1,
            w: editor.w.saturating_sub(2),
            h: 1,
        };
        let reserved = if bottom_tabs { 3 } else { 2 };
        let minimap = if config.minimap && editor.w > 40 {
            let width = config.minimap_width.min(editor.w / 4).max(4);
            Some(Rect {
                x: editor.right().saturating_sub(width + 1),
                y: editor.y + 2,
                w: width,
                h: h.saturating_sub(reserved + 1),
            })
        } else {
            None
        };
        // 行号槽：右侧留 1 列画分隔线。
        let gutter = 6usize;
        let text_x = editor.x + 1 + gutter;
        let text_w = minimap
            .map(|m| m.x.saturating_sub(text_x + 1))
            .unwrap_or_else(|| editor.right().saturating_sub(text_x + 1));
        let mut text = Rect {
            x: text_x,
            y: editor.y + 2,
            w: text_w.max(8),
            h: h.saturating_sub(reserved + 1),
        };
        if config.centered && text.w > 100 {
            let pad = (text.w - 100) / 2;
            text.x += pad;
            text.w = 100;
        }
        PaneRects {
            editor,
            tabs,
            breadcrumbs,
            gutter,
            text,
            minimap,
        }
    }
}
// ---------------------------------------------------------------- 欢迎页

/// 空白未命名文档时显示的快捷入口（渲染与点击共用）。
pub struct Welcome {
    pub card: Rect,
    pub items: Vec<(Rect, &'static str, &'static str, HintTarget)>,
}

// ---------------------------------------------------------------- 浮层

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Focus {
    Editor,
    Sidebar,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ListKind {
    Command,
    QuickOpen,
    Tabs,
    Theme,
    Language,
    Encoding,
    Eol,
    Snippet,
    Outline,
    Problems,
    GitLog,
    GitBranches,
    LspCompletion,
    LspReferences,
    LspSymbols,
    LspInfo,
    LspCodeAction,
    ExcelFontSize,
    ExcelFontColor,
    ExcelFillColor,
    ExcelNumberFormat,
    Clipboard,
    TaskList,
    TaskOutput,
    Extensions,
    ExtensionCommand,
    DebugConfig,
    DebugOutput,
    DebugVars,
    RemoteHosts,
    PluginChoice,
    PluginOutput,
}

#[derive(Clone, Debug)]
pub struct ListItem {
    pub title: String,
    pub detail: String,
    pub command: Option<Cmd>,
    pub path: Option<PathBuf>,
    pub line: Option<usize>,
    pub value: Option<String>,
}

impl ListItem {
    pub fn plain(title: impl Into<String>) -> ListItem {
        ListItem {
            title: title.into(),
            detail: String::new(),
            command: None,
            path: None,
            line: None,
            value: None,
        }
    }
}

pub struct ListState {
    pub kind: ListKind,
    pub title: String,
    pub items: Vec<ListItem>,
    pub filtered: Vec<usize>,
    pub selected: usize,
    pub query: String,
    pub scroll: usize,
}

impl ListState {
    pub fn new(kind: ListKind, title: &str, items: Vec<ListItem>) -> ListState {
        let filtered = (0..items.len()).collect();
        ListState {
            kind,
            title: title.to_string(),
            items,
            filtered,
            selected: 0,
            query: String::new(),
            scroll: 0,
        }
    }

    pub fn refilter(&mut self) {
        // 命令面板 / 快速打开支持 VSCode 前缀：> 命令、@ 符号、# 工作区符号。
        let query = self
            .query
            .trim_start_matches(['>', '@', '#'])
            .trim()
            .to_lowercase();
        self.filtered = self
            .items
            .iter()
            .enumerate()
            .filter(|(_, item)| {
                if query.is_empty() {
                    return true;
                }
                item.title.to_lowercase().contains(&query)
                    || item.detail.to_lowercase().contains(&query)
                    || fuzzy_match(&item.title.to_lowercase(), &query)
            })
            .map(|(index, _)| index)
            .collect();
        self.selected = self.selected.min(self.filtered.len().saturating_sub(1));
    }

    pub fn current(&self) -> Option<&ListItem> {
        self.filtered
            .get(self.selected)
            .and_then(|index| self.items.get(*index))
    }

    pub fn move_selection(&mut self, delta: isize) {
        if self.filtered.is_empty() {
            self.selected = 0;
            return;
        }
        let len = self.filtered.len() as isize;
        let mut index = self.selected as isize + delta;
        if index < 0 {
            index = len - 1;
        }
        if index >= len {
            index = 0;
        }
        self.selected = index as usize;
    }
}

pub fn fuzzy_match(haystack: &str, needle: &str) -> bool {
    let mut chars = haystack.chars();
    for target in needle.chars() {
        loop {
            match chars.next() {
                Some(ch) if ch == target => break,
                Some(_) => continue,
                None => return false,
            }
        }
    }
    true
}

pub struct FindState {
    pub replace: bool,
    pub query: String,
    pub replacement: String,
    pub focus_query: bool,
    pub options: SearchOptions,
    pub error: Option<String>,
    pub matches: usize,
    pub current: usize,
}

pub struct MenuState {
    pub index: usize,
    pub selected: usize,
}

/// `:` / `/` / `?` 命令行。
pub struct CmdlineState {
    pub prefix: char,
    pub input: String,
    pub history: Vec<String>,
    pub index: Option<usize>,
}

/// 全屏设置页状态。
pub struct SettingsPage {
    pub category: usize,
    pub selected: usize,
    /// 搜索过滤词（直接输入字母即开始过滤）。
    pub query: String,
    pub scroll: usize,
}

/// 设置页里的一行。
pub struct SettingRow {
    pub key: &'static str,
    pub label: &'static str,
    pub desc: &'static str,
    pub value: String,
}

/// which-key 浮层（F1）：只做展示，按下列出的键即执行。
pub struct KeysState;

/// 右键上下文菜单的一项。
pub struct ContextItem {
    pub label: String,
    pub cmd: Cmd,
}

/// 右键上下文菜单（编辑器 / 标签 / 资源管理器共用）。
pub struct ContextState {
    pub items: Vec<ContextItem>,
    pub x: usize,
    pub y: usize,
    pub selected: usize,
}

/// 可点击的键位提示 / 状态段要执行的动作。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum HintTarget {
    Cmd(Cmd),
    /// 打开 which-key 键位速查。
    Keys,
    /// 打开菜单浮层。
    Menu,
}

/// 界面上一个可点击的提示条（sqlmux：键位提示即按钮）。
pub struct Hint {
    pub rect: Rect,
    pub label: &'static str,
    pub target: HintTarget,
    /// 提示条所压住的底色（边框行 / 状态栏）。
    pub bg: crate::render::Color,
}

/// 状态栏右侧的一段信息（点行列 / 编码等可打开对应面板）。
pub struct StatusItem {
    pub rect: Rect,
    pub label: String,
    pub target: Option<HintTarget>,
}

pub struct KeyHint {
    pub keys: &'static str,
    pub label: &'static str,
    pub code: KeyCode,
    pub mods: Mods,
    pub cmd: Cmd,
}

impl KeyHint {
    pub fn matches(&self, key: &Key) -> bool {
        key.code == self.code && key.mods == self.mods
    }
}

/// 状态栏与 which-key 共用的键位表（两列展示）。
pub static KEY_HINTS: &[KeyHint] = &[
    KeyHint { keys: "Ctrl+S", label: "保存", code: KeyCode::Char('s'), mods: Mods { ctrl: true, alt: false, shift: false }, cmd: Cmd::Save },
    KeyHint { keys: "Ctrl+Shift+S", label: "另存为", code: KeyCode::Char('s'), mods: Mods { ctrl: true, alt: false, shift: true }, cmd: Cmd::SaveAs },
    KeyHint { keys: "Ctrl+P", label: "快速打开", code: KeyCode::Char('p'), mods: Mods { ctrl: true, alt: false, shift: false }, cmd: Cmd::QuickOpen },
    KeyHint { keys: "Ctrl+Shift+P", label: "命令面板", code: KeyCode::Char('p'), mods: Mods { ctrl: true, alt: false, shift: true }, cmd: Cmd::Palette },
    KeyHint { keys: "Ctrl+F", label: "查找", code: KeyCode::Char('f'), mods: Mods { ctrl: true, alt: false, shift: false }, cmd: Cmd::Find },
    KeyHint { keys: "Ctrl+H", label: "替换", code: KeyCode::Char('h'), mods: Mods { ctrl: true, alt: false, shift: false }, cmd: Cmd::Replace },
    KeyHint { keys: "Ctrl+G", label: "转到行", code: KeyCode::Char('g'), mods: Mods { ctrl: true, alt: false, shift: false }, cmd: Cmd::GotoLine },
    KeyHint { keys: "Ctrl+B", label: "侧栏", code: KeyCode::Char('b'), mods: Mods { ctrl: true, alt: false, shift: false }, cmd: Cmd::ToggleSidebar },
    KeyHint { keys: "Ctrl+Shift+F", label: "工程搜索", code: KeyCode::Char('f'), mods: Mods { ctrl: true, alt: false, shift: true }, cmd: Cmd::WorkspaceSearch },
    KeyHint { keys: "Ctrl+Shift+E", label: "资源管理器", code: KeyCode::Char('e'), mods: Mods { ctrl: true, alt: false, shift: true }, cmd: Cmd::FocusExplorer },
    KeyHint { keys: "Ctrl+Shift+X", label: "插件", code: KeyCode::Char('x'), mods: Mods { ctrl: true, alt: false, shift: true }, cmd: Cmd::Extensions },
    KeyHint { keys: "Ctrl+,", label: "设置", code: KeyCode::Char(','), mods: Mods { ctrl: true, alt: false, shift: false }, cmd: Cmd::OpenSettings },
    KeyHint { keys: "F2", label: "书签", code: KeyCode::F(2), mods: Mods { ctrl: false, alt: false, shift: false }, cmd: Cmd::ToggleBookmark },
    KeyHint { keys: "F5", label: "调试", code: KeyCode::F(5), mods: Mods { ctrl: false, alt: false, shift: false }, cmd: Cmd::DebugStart },
    KeyHint { keys: "F9", label: "断点", code: KeyCode::F(9), mods: Mods { ctrl: false, alt: false, shift: false }, cmd: Cmd::DebugToggleBreakpoint },
    KeyHint { keys: "Shift+F1", label: "完整帮助", code: KeyCode::F(1), mods: Mods { ctrl: false, alt: false, shift: true }, cmd: Cmd::Help },
];

/// 设置页的分类：(分类名, [(键, 显示名, 说明)])。
pub static SETTING_CATEGORIES: &[(&str, &[(&str, &str, &str)])] = &[
    (
        "编辑",
        &[
            ("tab_width", "缩进宽度", "2 / 4 / 8"),
            ("use_spaces", "使用空格缩进", "Tab 键插入空格"),
            ("auto_indent", "自动缩进", "换行时保持缩进"),
            ("auto_pair", "自动闭合括号", "成对补齐 () [] {} \"\" ''"),
            ("wrap", "自动换行", "长行折行显示"),
            ("folding", "代码折叠", "支持折叠代码块"),
            ("autosave", "自动保存", "停止输入 2 秒后保存"),
            ("show_whitespace", "显示空白字符", "空格与制表符可见"),
        ],
    ),
    (
        "外观",
        &[
            ("theme", "主题", "←→ 切换配色"),
            ("layout", "界面布局", "vscode / sqlmux"),
            ("minimap", "小地图", "右侧代码缩略图"),
            ("minimap_width", "小地图宽度", "字符列数"),
            ("sidebar", "资源管理器", "左侧文件树"),
            ("sidebar_width", "侧栏宽度", "字符列数"),
            ("gui_font_size", "GUI 字号", "图形窗口字号"),
            ("icons", "图标", "unicode / ascii"),
            ("nerd_font", "Nerd Font", "auto / on / off"),
            ("rainbow_brackets", "彩虹括号", "按嵌套深度着色"),
            ("centered", "居中布局", "超宽窗口限制阅读宽度"),
        ],
    ),
    (
        "Vim",
        &[
            ("vim", "Vim 模式", "普通/插入/可视，: 命令行"),
            ("indent_guides", "缩进参考线", "每级缩进一条淡竖线"),
            ("format_on_save", "保存时格式化", "需语言服务器已连接"),
            ("sticky_scroll", "粘性滚动", "顶部固定外层作用域"),
        ],
    ),
    (
        "终端",
        &[
            ("terminal_height", "终端高度", "0 表示不显示；Ctrl+` 开关"),
        ],
    ),
    (
        "窗口",
        &[
            ("restore_session", "恢复会话", "启动时打开上次的文件"),
            ("confirm_close", "关闭前确认", "有未保存修改时提示"),
            ("confirm_paste", "粘贴多行前确认", "多行粘贴前询问"),
            ("show_hidden", "显示隐藏文件", "资源管理器显示点文件"),
            ("workspace_ignore", "搜索遵循 .gitignore", "工程搜索跳过忽略项"),
            ("git", "Git 集成", "状态与差异"),
            ("language", "界面语言", "zh / en"),
        ],
    ),
    (
        "LSP",
        &[
            ("lsp_auto", "输入自动补全", "需语言服务器已连接"),
            ("lsp_signature", "签名帮助", "输入 ( 或 , 时显示"),
            ("lsp_hints", "内联提示", "行内显示类型/参数名"),
        ],
    ),
    (
        "插件",
        &[("plugins", "插件功能", "开启后加载 textm.json 插件")],
    ),
];

pub struct PromptState {
    pub kind: PromptKind,
    pub title: String,
    pub input: String,
    pub hint: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PromptKind {
    SaveAs,
    OpenPath,
    NewFile,
    GotoLine,
    CompareFile,
    GitCommit,
    GitBranchCreate,
    GitBranchDelete,
    GitMerge,
    LspSymbolQuery,
    ExcelSheetAdd,
    ExcelSheetRename,
    ExcelFilter,
    WorkspaceReplace,
    WorkspaceInclude,
    WorkspaceExclude,
    AddFolder,
    ExplorerNewFile,
    ExplorerNewFolder,
    ExplorerRename,
    LspRename,
    RemoteHostAdd,
    RemoteCommand,
    RemoteFileOpen,
    RemoteUploadPath,
    PluginInput,
}

pub struct ConfirmState {
    pub title: String,
    pub message: String,
    pub selected: usize,
    pub action: ConfirmAction,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ConfirmAction {
    CloseTab(usize),
    Quit,
    Paste,
    ExcelSheetDelete(usize),
    ExplorerDelete(PathBuf),
    GitDiscard(PathBuf),
}

pub enum Overlay {
    None,
    Menu(MenuState),
    Keys(KeysState),
    Context(ContextState),
    Cmdline(CmdlineState),
    List(ListState),
    Find(FindState),
    Prompt(PromptState),
    Confirm(ConfirmState),
}

impl Overlay {
    pub fn is_none(&self) -> bool {
        matches!(self, Overlay::None)
    }
}

// ---------------------------------------------------------------- 侧边栏

#[derive(Clone)]
pub struct FsEntry {
    pub path: PathBuf,
    pub name: String,
    pub depth: usize,
    pub is_dir: bool,
    pub expanded: bool,
}

pub struct Sidebar {
    pub root: PathBuf,
    /// 工作区根目录（可包含多个文件夹）。
    pub roots: Vec<PathBuf>,
    pub entries: Vec<FsEntry>,
    pub selected: usize,
    pub scroll: usize,
    pub expanded: HashSet<PathBuf>,
    pub visible: bool,
    pub mode: SidebarMode,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SidebarMode {
    Explorer,
    Search,
    Git,
}

impl Sidebar {
    pub fn new(root: PathBuf, visible: bool) -> Sidebar {
        let mut sidebar = Sidebar {
            root: root.clone(),
            roots: vec![root],
            entries: Vec::new(),
            selected: 0,
            scroll: 0,
            expanded: HashSet::new(),
            visible,
            mode: SidebarMode::Explorer,
        };
        sidebar.refresh(false);
        sidebar
    }

    /// 追加一个工作区文件夹。
    pub fn add_root(&mut self, path: PathBuf) {
        if !self.roots.iter().any(|r| r == &path) {
            self.roots.push(path.clone());
        }
        self.expanded.insert(path);
        self.refresh(false);
    }

    /// 移除一个工作区文件夹；至少保留一个。
    pub fn remove_root(&mut self, path: &Path) -> bool {
        if self.roots.len() <= 1 {
            return false;
        }
        let before = self.roots.len();
        self.roots.retain(|r| r != path);
        if self.roots.len() == before {
            return false;
        }
        if self.root == path {
            if let Some(first) = self.roots.first().cloned() {
                self.root = first;
            }
        }
        self.expanded.remove(path);
        self.refresh(false);
        true
    }

    /// 该路径是否是工作区根目录。
    pub fn is_root(&self, path: &Path) -> bool {
        self.roots.iter().any(|r| r == path)
    }

    pub fn refresh(&mut self, show_hidden: bool) {
        self.entries.clear();
        if self.roots.is_empty() {
            self.roots.push(self.root.clone());
        }
        let roots = self.roots.clone();
        for root in roots {
            let name = root
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| root.display().to_string());
            let expanded = self.expanded.contains(&root);
            self.entries.push(FsEntry {
                path: root.clone(),
                name,
                depth: 0,
                is_dir: true,
                expanded,
            });
            if expanded {
                self.walk(&root, 1, show_hidden, 0);
            }
        }
        if self.entries.is_empty() {
            self.selected = 0;
        } else {
            self.selected = self.selected.min(self.entries.len() - 1);
        }
    }

    fn walk(&mut self, dir: &Path, depth: usize, show_hidden: bool, guard: usize) {
        if guard > 64 || self.entries.len() > 5000 {
            return;
        }
        let mut children: Vec<PathBuf> = match std::fs::read_dir(dir) {
            Ok(entries) => entries
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| show_hidden || !is_hidden(p))
                .filter(|p| {
                    !p.file_name()
                        .and_then(|n| n.to_str())
                        .map(|n| {
                            matches!(
                                n,
                                ".git"
                                    | "target"
                                    | "node_modules"
                                    | ".vs"
                                    | "bin"
                                    | "obj"
                                    | "__pycache__"
                            )
                        })
                        .unwrap_or(false)
                })
                .collect(),
            Err(_) => return,
        };
        children.sort_by(|a, b| {
            let da = a.is_dir();
            let db = b.is_dir();
            db.cmp(&da).then_with(|| {
                a.file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_lowercase()
                    .cmp(&b.file_name().unwrap_or_default().to_string_lossy().to_lowercase())
            })
        });
        for path in children {
            let is_dir = path.is_dir();
            let expanded = self.expanded.contains(&path);
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            self.entries.push(FsEntry {
                path: path.clone(),
                name,
                depth,
                is_dir,
                expanded,
            });
            if is_dir && expanded {
                self.walk(&path, depth + 1, show_hidden, guard + 1);
            }
        }
    }

    pub fn toggle(&mut self, index: usize) {
        let Some(entry) = self.entries.get(index).cloned() else {
            return;
        };
        if !entry.is_dir {
            return;
        }
        if self.expanded.contains(&entry.path) {
            self.expanded.remove(&entry.path);
        } else {
            self.expanded.insert(entry.path.clone());
        }
        self.refresh(false);
        self.selected = self
            .entries
            .iter()
            .position(|e| e.path == entry.path)
            .unwrap_or(0);
    }
}

fn is_hidden(path: &Path) -> bool {
    path.file_name()
        .and_then(|n| n.to_str())
        .map(|n| n.starts_with('.') && n != ".." && n != ".")
        .unwrap_or(false)
}

// ---------------------------------------------------------------- 事件

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Event {
    Key(Key),
    Mouse(crate::platform::console::Mouse),
    Resize(usize, usize),
    Tick,
}

// ---------------------------------------------------------------- 命令

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Cmd {
    NewFile,
    OpenPath,
    Save,
    SaveAs,
    SaveAll,
    CloseTab,
    Quit,
    Undo,
    Redo,
    Cut,
    Copy,
    Paste,
    SelectAll,
    SelectLine,
    /// 选中下一个相同内容（Ctrl+D）。
    SelectNextOccurrence,
    DuplicateLine,
    DeleteLine,
    MoveLineUp,
    MoveLineDown,
    AddCursorUp,
    AddCursorDown,
    ToggleComment,
    Indent,
    Outdent,
    SortAsc,
    SortDesc,
    Dedup,
    Upper,
    Lower,
    Find,
    Replace,
    FindNext,
    FindPrev,
    GotoLine,
    ToggleBookmark,
    NextBookmark,
    PrevBookmark,
    ToggleSidebar,
    FocusExplorer,
    QuickOpen,
    Palette,
    ToggleWrap,
    ToggleMinimap,
    ToggleAutosave,
    ToggleStickyScroll,
    FoldBlock,
    FoldAll,
    UnfoldAll,
    ToggleWhitespace,
    Help,
    ThemePicker,
    LanguagePicker,
    EncodingPicker,
    EolPicker,
    SnippetPicker,
    Outline,
    Problems,
    CompareFile,
    NewWordDoc,
    NewExcelDoc,
    ToggleBold,
    ToggleItalic,
    ToggleUnderline,
    CycleFontColor,
    GitStatus,
    GitDiff,
    GitLog,
    GitCommit,
    GitStage,
    GitUnstage,
    GitStageAll,
    GitUnstageAll,
    GitDiscard,
    GitBranches,
    GitBlame,
    GitPull,
    GitPush,
    GitFetch,
    GitStash,
    GitStashPop,
    GitBranchCreate,
    GitBranchDelete,
    GitMerge,
    LspDefinition,
    LspPeekDefinition,
    LspComplete,
    LspHover,
    LspReferences,
    LspSymbols,
    LspRename,
    LspFormat,
    LspSignature,
    LspCodeAction,
    ToggleLspAutoComplete,
    ToggleLspSignature,
    ToggleLspInlayHints,
    WorkspaceSearch,
    WorkspaceReplace,
    WorkspaceInclude,
    WorkspaceExclude,
    WorkspaceToggleIgnore,
    WorkspaceAddFolder,
    WorkspaceRemoveFolder,
    ExplorerNewFile,
    ExplorerNewFolder,
    ExplorerRename,
    ExplorerDelete,
    ExplorerRefresh,
    OpenImage,
    // Excel（表格）
    ExcelBold,
    ExcelItalic,
    ExcelUnderline,
    ExcelFontSize,
    ExcelFontColor,
    ExcelFillColor,
    ExcelNumberFormat,
    ExcelAlignLeft,
    ExcelAlignCenter,
    ExcelAlignRight,
    ExcelBorder,
    ExcelClearBorder,
    ExcelMerge,
    ExcelUnmerge,
    ExcelFreeze,
    ExcelFilter,
    ExcelClearFilter,
    ExcelSortAsc,
    ExcelSortDesc,
    ExcelInsertRow,
    ExcelDeleteRow,
    ExcelInsertCol,
    ExcelDeleteCol,
    ExcelSheetAdd,
    ExcelSheetRename,
    ExcelSheetDelete,
    ExcelSheetNext,
    ExcelSheetPrev,
    ExcelClear,
    ExcelCopy,
    ExcelCut,
    ExcelPaste,
    ExcelSelectAll,
    // 视图增强
    ToggleZen,
    ToggleRainbow,
    ToggleCentered,
    ToggleLayout,
    OpenSettings,
    ClipboardHistory,
    // 编辑增强
    SelectAllOccurrences,
    GotoBracket,
    JoinLines,
    InsertLineBelow,
    InsertLineAbove,
    CopyPath,
    ReopenClosedTab,
    AddCursorLineEnds,
    // 任务
    TaskRun,
    TaskRunLast,
    TaskShowOutput,
    TaskStop,
    // 扩展
    Extensions,
    ReloadExtensions,
    OpenExtensionDir,
    RunExtensionCommand,
    PluginOutput,
    // 调试
    DebugStart,
    DebugContinue,
    DebugStepOver,
    DebugStepIn,
    DebugStepOut,
    DebugToggleBreakpoint,
    DebugStop,
    DebugShowOutput,
    DebugVariables,
    // 远程
    RemoteAddFolder,
    RemoteSelectHost,
    RemoteAddHost,
    RemoteRunCommand,
    RemoteOpenFile,
    RemoteUpload,
    // 分屏 / 终端 / Vim
    SplitVertical,
    SplitHorizontal,
    CloseSplit,
    MoveTabToOtherGroup,
    ToggleTerminal,
    ToggleVim,
}

/// 属于“插件功能”的命令：关闭开关时隐藏并从命令面板移除。
pub fn is_plugin_cmd(cmd: Cmd) -> bool {
    matches!(
        cmd,
        Cmd::Extensions
            | Cmd::ReloadExtensions
            | Cmd::OpenExtensionDir
            | Cmd::RunExtensionCommand
            | Cmd::PluginOutput
    )
}

pub struct MenuItemDef {
    pub title: &'static str,
    pub shortcut: &'static str,
    pub cmd: Cmd,
}

pub struct MenuDef {
    pub title: &'static str,
    pub items: &'static [MenuItemDef],
}

macro_rules! item {
    ($title:literal, $shortcut:literal, $cmd:ident) => {
        MenuItemDef {
            title: $title,
            shortcut: $shortcut,
            cmd: Cmd::$cmd,
        }
    };
}

pub static MENUS: &[MenuDef] = &[
    MenuDef {
        title: "文件",
        items: &[
            item!("新建文件", "Ctrl+N", NewFile),
            item!("打开…", "Ctrl+O", OpenPath),
            item!("保存", "Ctrl+S", Save),
            item!("另存为…", "Ctrl+Shift+S", SaveAs),
            item!("全部保存", "Ctrl+Alt+S", SaveAll),
            item!("关闭标签页", "Ctrl+W", CloseTab),
            item!("资源管理器中新建文件…", "", ExplorerNewFile),
            item!("资源管理器中新建文件夹…", "", ExplorerNewFolder),
            item!("重命名（文件树）…", "F2", ExplorerRename),
            item!("删除（文件树）", "Delete", ExplorerDelete),
            item!("刷新资源管理器", "Ctrl+R", ExplorerRefresh),
            item!("退出", "Ctrl+Q", Quit),
        ],
    },
    MenuDef {
        title: "编辑",
        items: &[
            item!("撤销", "Ctrl+Z", Undo),
            item!("重做", "Ctrl+Y", Redo),
            item!("剪切", "Ctrl+X", Cut),
            item!("复制", "Ctrl+C", Copy),
            item!("粘贴", "Ctrl+V", Paste),
            item!("全选", "Ctrl+A", SelectAll),
            item!("选择当前行", "Ctrl+L", SelectLine),
            item!("选择下一个相同内容", "Ctrl+D", SelectNextOccurrence),
            item!("复制当前行", "", DuplicateLine),
            item!("删除当前行", "Ctrl+Shift+K", DeleteLine),
            item!("上移行", "Alt+↑", MoveLineUp),
            item!("下移行", "Alt+↓", MoveLineDown),
            item!("上方添加光标", "Ctrl+Alt+↑", AddCursorUp),
            item!("下方添加光标", "Ctrl+Alt+↓", AddCursorDown),
            item!("切换行注释", "Ctrl+/", ToggleComment),
            item!("升序排序", "", SortAsc),
            item!("降序排序", "", SortDesc),
            item!("删除重复行", "", Dedup),
            item!("转为大写", "", Upper),
            item!("转为小写", "", Lower),
        ],
    },
    MenuDef {
        title: "选择",
        items: &[
            item!("全选", "Ctrl+A", SelectAll),
            item!("选择当前行", "Ctrl+L", SelectLine),
            item!("选中所有出现", "Ctrl+Shift+L", SelectAllOccurrences),
            item!("跳转到匹配括号", "Ctrl+Shift+\\", GotoBracket),
            item!("合并行", "Ctrl+J", JoinLines),
            item!("在下方插入行", "Ctrl+Enter", InsertLineBelow),
            item!("在上方插入行", "Ctrl+Shift+Enter", InsertLineAbove),
            item!("复制完整路径", "", CopyPath),
            item!("重新打开关闭的标签", "Ctrl+Shift+T", ReopenClosedTab),
            item!("每行末尾添加光标", "Shift+Alt+I", AddCursorLineEnds),
        ],
    },
    MenuDef {
        title: "代码",
        items: &[
            item!("补全", "Ctrl+Space", LspComplete),
            item!("签名帮助", "Ctrl+Shift+Space", LspSignature),
            item!("快速修复 / 代码操作…", "Ctrl+.", LspCodeAction),
            item!("悬停提示", "Ctrl+Shift+I", LspHover),
            item!("跳转到定义", "F12", LspDefinition),
            item!("定义预览", "Alt+F12", LspPeekDefinition),
            item!("查找引用", "", LspReferences),
            item!("工作区符号…", "Ctrl+T", LspSymbols),
            item!("重命名符号…", "", LspRename),
            item!("格式化文档", "", LspFormat),
        ],
    },
    MenuDef {
        title: "搜索",
        items: &[
            item!("工程搜索", "Ctrl+Shift+F", WorkspaceSearch),
            item!("工程替换…", "Ctrl+Shift+H", WorkspaceReplace),
            item!("添加文件夹到工作区…", "", WorkspaceAddFolder),
            item!("移除所选工作区文件夹", "", WorkspaceRemoveFolder),
            item!("包含文件…", "", WorkspaceInclude),
            item!("排除文件…", "", WorkspaceExclude),
            item!("切换 .gitignore 过滤", "", WorkspaceToggleIgnore),
            item!("文件内查找", "Ctrl+F", Find),
            item!("文件内替换", "Ctrl+H", Replace),
            item!("快速打开文件", "Ctrl+P", QuickOpen),
        ],
    },
    MenuDef {
        title: "查看",
        items: &[
            item!("资源管理器", "Ctrl+B", ToggleSidebar),
            item!("命令面板", "Ctrl+Shift+P", Palette),
            item!("自动换行", "Alt+Z", ToggleWrap),
            item!("小地图", "Alt+M", ToggleMinimap),
            item!("自动保存", "", ToggleAutosave),
            item!("粘性滚动", "", ToggleStickyScroll),
            item!("输入自动补全", "", ToggleLspAutoComplete),
            item!("签名帮助提示", "", ToggleLspSignature),
            item!("内联提示", "", ToggleLspInlayHints),
            item!("显示空白字符", "Ctrl+Shift+8", ToggleWhitespace),
            item!("折叠 / 展开", "Ctrl+Shift+[", FoldBlock),
            item!("全部折叠", "Ctrl+Alt+[", FoldAll),
            item!("全部展开", "Ctrl+Alt+]", UnfoldAll),
            item!("符号大纲", "", Outline),
            item!("问题列表", "", Problems),
            item!("专注模式", "Ctrl+Alt+Z", ToggleZen),
            item!("彩虹括号", "", ToggleRainbow),
            item!("居中布局", "", ToggleCentered),
            item!("切换界面布局", "", ToggleLayout),
            item!("设置…", "Ctrl+,", OpenSettings),
            item!("剪贴板历史…", "Ctrl+Shift+V", ClipboardHistory),
            item!("选择主题…", "", ThemePicker),
            item!("选择语言模式…", "", LanguagePicker),
            item!("选择编码…", "", EncodingPicker),
            item!("选择换行符…", "", EolPicker),
            item!("Git 状态", "", GitStatus),
            item!("Git 差异", "", GitDiff),
            item!("Git 历史", "", GitLog),
        ],
    },
    MenuDef {
        title: "Git",
        items: &[
            item!("源码管理面板", "", GitStatus),
            item!("查看选中差异", "Enter", GitDiff),
            item!("历史", "", GitLog),
            item!("提交…", "", GitCommit),
            item!("暂存选中", "Space", GitStage),
            item!("取消暂存选中", "", GitUnstage),
            item!("暂存全部", "A", GitStageAll),
            item!("取消暂存全部", "U", GitUnstageAll),
            item!("丢弃选中改动", "D", GitDiscard),
            item!("切换分支…", "B", GitBranches),
            item!("新建分支…", "", GitBranchCreate),
            item!("删除分支…", "", GitBranchDelete),
            item!("合并分支…", "", GitMerge),
            item!("拉取", "", GitPull),
            item!("推送", "", GitPush),
            item!("获取远程", "", GitFetch),
            item!("暂存改动 (stash)", "", GitStash),
            item!("恢复 stash", "", GitStashPop),
            item!("Blame 当前文件", "", GitBlame),
        ],
    },
    MenuDef {
        title: "表格",
        items: &[
            item!("加粗", "Ctrl+B", ExcelBold),
            item!("斜体", "Ctrl+I", ExcelItalic),
            item!("下划线", "Ctrl+U", ExcelUnderline),
            item!("字号…", "", ExcelFontSize),
            item!("字体颜色…", "", ExcelFontColor),
            item!("填充颜色…", "", ExcelFillColor),
            item!("数字格式…", "", ExcelNumberFormat),
            item!("左对齐", "", ExcelAlignLeft),
            item!("居中", "", ExcelAlignCenter),
            item!("右对齐", "", ExcelAlignRight),
            item!("所有框线", "", ExcelBorder),
            item!("清除框线", "", ExcelClearBorder),
            item!("合并单元格", "Ctrl+Shift+M", ExcelMerge),
            item!("取消合并", "", ExcelUnmerge),
            item!("冻结 / 取消冻结", "Ctrl+Shift+L", ExcelFreeze),
            item!("筛选当前列…", "Ctrl+Shift+F", ExcelFilter),
            item!("清除筛选", "", ExcelClearFilter),
            item!("升序排序", "", ExcelSortAsc),
            item!("降序排序", "", ExcelSortDesc),
            item!("插入行", "", ExcelInsertRow),
            item!("删除行", "", ExcelDeleteRow),
            item!("插入列", "", ExcelInsertCol),
            item!("删除列", "", ExcelDeleteCol),
            item!("新建工作表…", "", ExcelSheetAdd),
            item!("重命名工作表…", "", ExcelSheetRename),
            item!("删除工作表", "", ExcelSheetDelete),
            item!("下一个工作表", "Ctrl+PgDn", ExcelSheetNext),
            item!("上一个工作表", "Ctrl+PgUp", ExcelSheetPrev),
        ],
    },
    MenuDef {
        title: "任务",
        items: &[
            item!("运行任务…", "Ctrl+Shift+B", TaskRun),
            item!("重新运行上次任务", "", TaskRunLast),
            item!("显示任务输出", "", TaskShowOutput),
            item!("停止任务", "", TaskStop),
        ],
    },
    MenuDef {
        title: "插件",
        items: &[
            item!("插件管理…", "Ctrl+Shift+X", Extensions),
            item!("运行插件命令…", "", RunExtensionCommand),
            item!("插件输出", "", PluginOutput),
            item!("重新加载插件", "", ReloadExtensions),
            item!("打开插件目录", "", OpenExtensionDir),
        ],
    },
    MenuDef {
        title: "调试",
        items: &[
            item!("开始调试 / 继续", "F5", DebugStart),
            item!("切换断点", "F9", DebugToggleBreakpoint),
            item!("单步跳过", "F10", DebugStepOver),
            item!("单步进入", "F11", DebugStepIn),
            item!("单步跳出", "Shift+F11", DebugStepOut),
            item!("停止调试", "Shift+F5", DebugStop),
            item!("调试输出", "", DebugShowOutput),
            item!("变量 / 调用栈", "", DebugVariables),
        ],
    },
    MenuDef {
        title: "远程",
        items: &[
            item!("选择远程主机…", "", RemoteSelectHost),
            item!("添加 SSH 主机…", "", RemoteAddHost),
            item!("在远端执行命令…", "", RemoteRunCommand),
            item!("打开远端文件…", "", RemoteOpenFile),
            item!("上传当前文件到远端…", "", RemoteUpload),
            item!("添加网络文件夹（UNC）…", "", RemoteAddFolder),
        ],
    },
    MenuDef {
        title: "帮助",
        items: &[
            item!("快捷键与帮助", "Shift+F1", Help),
            item!("语言服务器补全", "Ctrl+Space", LspComplete),
            item!("跳转到定义", "F12", LspDefinition),
        ],
    },
];

// ---------------------------------------------------------------- 应用

/// 非模态签名帮助面板（绘制在光标附近，不拦截输入）。
pub struct SignatureState {
    pub signatures: Vec<(String, String)>,
    pub active: usize,
    pub parameter: usize,
    /// 触发位置；光标离开后自动隐藏。
    pub path: PathBuf,
    pub line: usize,
    pub col: usize,
}

pub struct App {
    pub tabs: Vec<Tab>,
    pub active: usize,
    pub config: Config,
    pub theme: Theme,
    pub layout: Layout,
    pub sidebar: Sidebar,
    /// 工程搜索（侧边栏「搜索」）状态。
    pub workspace_query: String,
    /// 工程搜索：区分大小写 / 全词匹配。
    pub workspace_case: bool,
    pub workspace_word: bool,
    pub workspace_hits: Vec<crate::ui::workspace::WorkspaceHit>,
    pub workspace_selected: usize,
    pub workspace_note: String,
    /// 搜索历史召回位置：0 表示未浏览，n 表示正在看第 n 条（最新为 1）。
    pub workspace_history_index: usize,
    /// 文件树新建 / 重命名的目标路径。
    pub explorer_target: Option<PathBuf>,
    /// Git 面板中选中的变更索引。
    pub git_selected: usize,
    pub overlay: Overlay,
    pub focus: Focus,
    pub running: bool,
    pub status: String,
    pub status_error: bool,
    /// 状态消息出现时间（用于淡出）。
    pub status_at: Instant,
    pub cwd: PathBuf,
    pub overwrite: bool,
    pub cursor_visible: bool,
    blink_at: Instant,
    /// 最近一次编辑时间（用于自动保存）。
    last_edit: Instant,
    pub mouse_selecting: bool,
    /// 正在拖拽的标签下标（用于拖拽排序）。
    pub tab_drag: Option<usize>,
    /// 鼠标最后位置（用于提示条悬停高亮）。
    pub mouse_pos: Option<(usize, usize)>,
    /// 正在拖小地图跳转。
    pub minimap_drag: bool,
    pub last_click: Option<(Instant, u16, u16)>,
    pub modified_count: usize,
    pub search_engine: Option<SearchEngine>,
    pub last_search: Option<(String, SearchOptions)>,
    pub show_whitespace: bool,
    pub tick: u64,
    pub gui: bool,
    pub quit_after_save: bool,
    pub pending_quit: bool,
    pub pending_save_action: Option<ConfirmAction>,
    pub pending_paste: Option<String>,
    pub git: crate::vcs::git::GitState,
    pub lsp: crate::lsp::LspState,
    /// 签名帮助面板。
    pub signature_help: Option<SignatureState>,
    /// 代码操作列表对应的操作（列表项用索引引用）。
    pub pending_code_actions: Vec<crate::lsp::client::CodeAction>,
    /// 内联提示缓存（按文件）。
    pub inlay_hints: std::collections::HashMap<PathBuf, Vec<crate::lsp::client::InlayHint>>,
    pub quick_files: Vec<PathBuf>,
    pub help_open: bool,
    pub preview_mode: bool,
    /// Word 页面视图（仅 GUI）：高保真排版，F6 切回文本编辑。
    pub word_page_view: bool,
    pub word_zoom: f32,
    pub excel_row: usize,
    pub excel_col: usize,
    pub excel_editing: bool,
    pub excel_input: String,
    /// Excel 选区锚点（Shift 扩选 / 鼠标拖动）。
    pub excel_anchor: Option<(usize, usize)>,
    git_checked: Instant,
    lsp_revision: u64,
    lsp_checked: Instant,
    /// 输入防抖后待触发的自动补全。
    pub pending_complete: Option<Instant>,
    /// 已拉取内联提示的 (文件, 版本)。
    pub lsp_hints_key: Option<(PathBuf, u64)>,
    /// 专注模式：隐藏侧栏、小地图与状态栏装饰。
    pub zen: bool,
    /// 进入专注模式前的 (侧栏, 小地图) 开关。
    pub zen_restore: (bool, bool),
    /// 剪贴板历史（最新在前）。
    pub clip_history: Vec<String>,
    /// 最近关闭的标签页（用于重新打开）。
    pub closed_tabs: Vec<ClosedTab>,
    /// 最近执行的命令（命令面板置顶）。
    pub recent_commands: Vec<Cmd>,
    /// 问题面板的严重级过滤：0=全部，1=错误，2=警告，3=信息，4=提示。
    pub problems_filter: u8,
    /// 当前工作区可运行的任务。
    pub tasks: Vec<crate::task::Task>,
    /// 正在运行的任务。
    pub task_run: Option<crate::task::TaskRun>,
    /// 上次运行的任务（用于重新运行）。
    pub task_last: Option<crate::task::Task>,
    /// 输出面板上次刷新时间。
    pub task_refresh_at: Instant,
    /// 已加载的本地扩展。
    pub extensions: Vec<crate::extension::Extension>,
    /// 调试会话状态（DAP）。
    pub debug: crate::debug::DebugState,
    /// 远程主机与远端文件映射。
    pub remote: crate::remote::RemoteState,
    /// 调试输出面板上次刷新时间。
    pub debug_refresh_at: Instant,
    /// 内嵌 JS 插件宿主。
    pub plugin: crate::plugin::PluginHost,
    /// 插件设置的状态栏文字。
    pub plugin_status: String,
    /// 等待用户响应的插件请求：(id, 类型 0=QuickPick 1=输入框 2=打开 3=保存)。
    pub plugin_pending: Option<(i64, u8)>,
    /// 由插件导入的主题名称（关闭插件功能时移除）。
    pub plugin_theme_names: Vec<String>,
    /// 上次触发插件 change 事件的文档版本。
    pub plugin_revision: u64,
    /// Vim 模态引擎。
    pub vim: crate::core::vim::Vim,
    /// 当前编辑器分组（0 = 主 pane，1 = 分屏）。
    pub group: usize,
    /// 每个分组显示的标签下标。
    pub groups: Vec<usize>,
    /// 分屏方向。
    pub split: Option<SplitKind>,
    /// 分屏比例（百分比）。
    pub split_ratio: usize,
    /// 底部终端面板。
    pub terminal: Option<crate::platform::term::Terminal>,
    /// 焦点是否在终端。
    pub term_focus: bool,
    /// Ex 命令历史。
    pub ex_history: Vec<String>,
    /// 全屏设置页（Ctrl+, 打开）。
    pub settings: Option<SettingsPage>,
}

impl App {
    pub fn new(config: Config, files: Vec<PathBuf>, gui: bool) -> App {
        let theme = theme::by_name(&config.theme);
        let cwd = files
            .first()
            .and_then(|p| p.parent().map(|p| p.to_path_buf()))
            .or_else(|| config.last_dir.clone())
            .or_else(|| std::env::current_dir().ok())
            .unwrap_or_else(|| PathBuf::from("."));
        let mut app = App {
            tabs: Vec::new(),
            active: 0,
            sidebar: Sidebar::new(cwd.clone(), config.sidebar),
            workspace_query: String::new(),
            workspace_case: false,
            workspace_word: false,
            workspace_hits: Vec::new(),
            workspace_selected: 0,
            workspace_note: String::new(),
            workspace_history_index: 0,
            explorer_target: None,
            git_selected: 0,
            theme,
            layout: Layout::default(),
            overlay: Overlay::None,
            focus: Focus::Editor,
            running: true,
            status: String::new(),
            status_error: false,
            status_at: Instant::now(),
            cwd,
            overwrite: false,
            cursor_visible: true,
            blink_at: Instant::now(),
            last_edit: Instant::now(),
            mouse_selecting: false,
            tab_drag: None,
            mouse_pos: None,
            minimap_drag: false,
            last_click: None,
            modified_count: 0,
            search_engine: None,
            last_search: None,
            show_whitespace: config.show_whitespace,
            tick: 0,
            gui,
            quit_after_save: false,
            pending_quit: false,
            pending_save_action: None,
            pending_paste: None,
            git: crate::vcs::git::GitState::default(),
            lsp: crate::lsp::LspState::new(),
            signature_help: None,
            pending_code_actions: Vec::new(),
            inlay_hints: std::collections::HashMap::new(),
            quick_files: Vec::new(),
            help_open: false,
            preview_mode: false,
            word_page_view: false,
            word_zoom: 1.0,
            excel_row: 0,
            excel_col: 0,
            excel_editing: false,
            excel_input: String::new(),
            excel_anchor: None,
            git_checked: Instant::now() - std::time::Duration::from_secs(10),
            lsp_revision: 0,
            lsp_checked: Instant::now() - std::time::Duration::from_secs(5),
            pending_complete: None,
            lsp_hints_key: None,
            zen: false,
            zen_restore: (true, true),
            clip_history: Vec::new(),
            closed_tabs: Vec::new(),
            recent_commands: Vec::new(),
            problems_filter: 0,
            tasks: Vec::new(),
            task_run: None,
            task_last: None,
            task_refresh_at: Instant::now(),
            extensions: Vec::new(),
            debug: crate::debug::DebugState::new(),
            remote: crate::remote::RemoteState::new(
                crate::config::Config::path()
                    .parent()
                    .map(|p| p.join("remote"))
                    .unwrap_or_else(|| PathBuf::from("remote")),
            ),
            debug_refresh_at: Instant::now(),
            plugin: crate::plugin::PluginHost::new(),
            plugin_status: String::new(),
            plugin_pending: None,
            plugin_theme_names: Vec::new(),
            plugin_revision: 0,
            vim: crate::core::vim::Vim::new(),
            group: 0,
            groups: vec![0],
            split: None,
            split_ratio: 50,
            terminal: None,
            term_focus: false,
            ex_history: Vec::new(),
            settings: None,
            config,
        };
        let folders = app.config.workspace_folders.clone();
        for folder in folders {
            if folder.is_dir() && !app.sidebar.roots.contains(&folder) {
                app.sidebar.roots.push(folder);
            }
        }
        for root in app.sidebar.roots.clone() {
            app.sidebar.expanded.insert(root);
        }
        app.sidebar.refresh(app.config.show_hidden);
        app.reload_extensions();
        app.reload_plugins();
        if app.config.plugins_enabled {
            let (names, _) = crate::extension::register_contributions(&app.extensions);
            app.plugin_theme_names = names;
        }
        app.reload_remotes();
        for file in files {
            if let Err(e) = app.open_file(&file) {
                app.set_error(&e);
            }
        }
        if app.tabs.is_empty() {
            app.tabs.push(Tab::new(Document::empty(), &app.config));
            app.active = 0;
        } else {
            app.active = app.tabs.len() - 1;
        }
        let lsp_config = app.config.lsp.clone();
        app.lsp.configure(&lsp_config);
        app
    }

    pub fn tab(&self) -> &Tab {
        &self.tabs[self.active.min(self.tabs.len() - 1)]
    }

    pub fn tab_mut(&mut self) -> &mut Tab {
        let index = self.active.min(self.tabs.len() - 1);
        &mut self.tabs[index]
    }

    /// 重新扫描用户目录与工作区扩展。
    pub fn reload_extensions(&mut self) {
        if !self.config.plugins_enabled {
            self.extensions.clear();
            return;
        }
        let dir = crate::config::Config::path()
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_default();
        self.extensions =
            crate::extension::load(&dir, &self.sidebar.roots, &self.config.disabled_plugins);
    }

    /// 重新加载 JS 插件包。
    pub fn reload_plugins(&mut self) {
        if self.config.plugins_enabled {
            self.plugin.reload_from(&self.extensions);
        } else {
            self.plugin.shutdown();
            self.plugin.packages.clear();
            self.plugin.commands.clear();
        }
    }

    /// 顶部菜单（关闭插件功能时隐藏“插件”）。
    pub fn menus(&self) -> Vec<&'static MenuDef> {
        MENUS
            .iter()
            .filter(|menu| self.config.plugins_enabled || menu.title != "插件")
            .collect()
    }

    /// 重新读取远程主机配置。
    pub fn reload_remotes(&mut self) {
        self.remote
            .reload(&self.config.remotes, &self.config.remote_roots);
    }

    pub fn doc(&self) -> &Document {
        &self.tab().doc
    }

    pub fn doc_mut(&mut self) -> &mut Document {
        &mut self.tab_mut().doc
    }

    pub fn language(&self) -> Language {
        self.doc().language
    }

    pub fn set_status(&mut self, message: impl Into<String>) {
        self.status = message.into();
        self.status_error = false;
        self.status_at = Instant::now();
    }

    pub fn set_error(&mut self, message: impl Into<String>) {
        self.status = message.into();
        self.status_error = true;
        self.status_at = Instant::now();
    }

    /// 状态消息仍在显示期内（淡出结束后让位给键位提示）。
    pub fn status_visible(&self) -> bool {
        !self.status.is_empty() && self.status_at.elapsed().as_secs_f32() < 8.0
    }

    pub fn open_file(&mut self, path: &Path) -> Result<(), String> {
        let absolute = path.to_path_buf();
        if let Some(index) = self
            .tabs
            .iter()
            .position(|t| t.doc.path.as_deref() == Some(absolute.as_path()))
        {
            self.active = index;
            return Ok(());
        }
        if let Some(kind) = crate::image::ImageKind::from_path(&absolute) {
            let image = crate::image::Image::load(&absolute, kind)?;
            let mut doc = Document::from_text(
                &format!(
                    "{}\n{} × {} 像素\n\n（图片预览：TUI 使用半块字符，GUI 模式直接绘制位图）",
                    absolute.display(),
                    image.width,
                    image.height
                ),
                Some(absolute.clone()),
            );
            doc.read_only = true;
            let mut tab = Tab::new(doc, &self.config);
            tab.preview = true;
            tab.image = Some(image);
            self.tabs.push(tab);
            self.active = self.tabs.len() - 1;
            self.set_status(format!("已打开图片 {}", absolute.display()));
            return Ok(());
        }

        let extension = absolute
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if extension == "docx" {
            let word = crate::docx::WordDoc::open(&absolute)?;
            let text = word.texts().join("\n");
            let mut doc = Document::from_text(&text, Some(absolute.clone()));
            doc.language = Language::Plain;
            let styles = word.styles();
            let mut tab = Tab::new(doc, &self.config);
            tab.word = Some(word);
            tab.word_styles = styles;
            self.tabs.push(tab);
            self.active = self.tabs.len() - 1;
            self.word_page_view = self.gui;
            self.word_zoom = 1.0;
            self.set_status(if self.gui {
                format!("已打开 Word 文档 {}（页面视图，F6 切换编辑）", absolute.display())
            } else {
                format!("已打开 Word 文档 {}", absolute.display())
            });
            return Ok(());
        }
        if extension == "xlsx" {
            let book = crate::xlsx::Workbook::open(&absolute)?;
            let mut doc = Document::empty();
            doc.path = Some(absolute.clone());
            doc.read_only = true;
            let mut tab = Tab::new(doc, &self.config);
            tab.excel = Some(book);
            self.tabs.push(tab);
            self.active = self.tabs.len() - 1;
            self.set_status(format!("已打开 Excel 表格 {}", absolute.display()));
            return Ok(());
        }
        if extension == "doc" || extension == "xls" {
            return Err("不支持旧版 .doc/.xls，请先用 Office 另存为 .docx/.xlsx".into());
        }
        let doc = Document::load(&absolute)?;
        let tab = Tab::new(doc, &self.config);
        self.tabs.push(tab);
        self.active = self.tabs.len() - 1;
        self.config.push_recent(&absolute);
        if let Some(parent) = absolute.parent() {
            if parent != self.cwd {
                self.cwd = parent.to_path_buf();
                self.sidebar.root = parent.to_path_buf();
                self.sidebar.refresh(self.config.show_hidden);
            }
        }
        self.set_status(format!("已打开 {}", absolute.display()));
        self.fire_plugin_event("open", &absolute);
        Ok(())
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        let mut cfg = self.config.clone();
        if self.zen {
            cfg.sidebar = false;
            cfg.minimap = false;
        }
        // 分组下标会随着标签增删变化，这里统一修正。
        if self.groups.is_empty() {
            self.groups.push(0);
        }
        self.group = self.group.min(self.groups.len().saturating_sub(1));
        for slot in &mut self.groups {
            if *slot >= self.tabs.len() {
                *slot = self.tabs.len().saturating_sub(1);
            }
        }
        self.groups[self.group] = self.active;
        let term_height = if self.terminal.is_some() {
            self.config.terminal_height
        } else {
            0
        };
        self.layout = Layout::compute_ext(
            cols,
            rows,
            &cfg,
            LayoutStyle::from_config(&cfg.layout),
            self.split,
            self.split_ratio,
            term_height,
        );
        let width = self.layout.text.w;
        for tab in &mut self.tabs {
            tab.refresh(&self.config, width, true);
        }
        self.ensure_visible();
        if let Some(term) = &mut self.terminal {
            if let Some(rect) = self.layout.terminal {
                term.resize(rect.w.saturating_sub(2), rect.h.saturating_sub(2));
            }
        }
    }

    /// 当前渲染的编辑器 pane：分组 → 标签 → 几何。
    pub fn pane_views(&self) -> Vec<(usize, PaneRects)> {
        let mut out = Vec::new();
        if self.tabs.is_empty() {
            return out;
        }
        for (index, pane) in self.layout.panes.iter().enumerate() {
            let tab = self
                .groups
                .get(index)
                .copied()
                .unwrap_or(self.active)
                .min(self.tabs.len() - 1);
            out.push((tab, *pane));
        }
        out
    }

    pub fn text_width(&self) -> usize {
        self.layout.text.w.max(8)
    }

    pub fn text_height(&self) -> usize {
        self.layout.text.h.max(1)
    }

    pub fn ensure_visible(&mut self) {
        let height = self.text_height();
        let width = self.text_width();
        let config = self.config.clone();
        self.tab_mut().refresh(&config, width, false);
        self.tab_mut().ensure_visible(height);
    }

    /// 用最新配置刷新当前标签（宽度按当前布局计算）。
    pub(crate) fn refresh_active(&mut self, force_rows: bool) {
        let width = self.text_width();
        let config = self.config.clone();
        self.tab_mut().refresh(&config, width, force_rows);
    }

    /// 调试暂停时跳转到源码位置（DAP 行号从 1 开始）。
    pub(crate) fn open_debug_location(&mut self, path: PathBuf, line: usize) {
        if self.open_file(&path).is_err() {
            return;
        }
        let target = line.saturating_sub(1);
        let max = self.doc().line_count().saturating_sub(1);
        self.doc_mut().set_cursor(Pos::new(target.min(max), 0));
        self.ensure_visible();
    }

    pub fn excel_value(&self, row: usize, col: usize) -> String {
        match &self.tab().excel {
            Some(book) => book.display(book.active, row, col),
            None => String::new(),
        }
    }

    pub fn cursor_screen(&self) -> Option<(u16, u16)> {
        if !self.cursor_visible
            || !self.overlay.is_none()
            || self.settings.is_some()
            || self.focus != Focus::Editor
            || self.tab().preview
            || self.tab().is_excel()
            || (self.tab().word.is_some() && self.word_page_view)
            || self.help_open
        {
            return None;
        }
        let tab = self.tab();
        let doc = &tab.doc;
        let pos = doc.primary().pos;
        let row = tab.cursor_row();
        if row < tab.top_row {
            return None;
        }
        let screen_row = row - tab.top_row;
        let text = self
            .layout
            .panes
            .get(self.group)
            .map(|pane| pane.text)
            .unwrap_or(self.layout.text);
        if screen_row >= text.h {
            return None;
        }
        let visual = tab.rows.get(row)?;
        let col = editor::display_col(doc, pos.line, pos.col, doc.tab_width);
        let offset = col.saturating_sub(visual.start);
        let x = text.x + offset.min(text.w.saturating_sub(1));
        let y = text.y + screen_row;
        Some((x as u16, y as u16))
    }

    pub fn tick(&mut self) {
        self.tick = self.tick.wrapping_add(1);
        if self.blink_at.elapsed().as_millis() >= 500 {
            self.cursor_visible = !self.cursor_visible;
            self.blink_at = Instant::now();
        }
        // 每 3 秒检查一次 Git 状态（只在仓库目录内）
        if self.config.git && self.git_checked.elapsed().as_secs() >= 3 {
            self.git.refresh(&self.cwd);
            let root = self.git.root.clone();
            for tab in &mut self.tabs {
                tab.refresh_git(root.as_deref());
            }
            self.git_checked = Instant::now();
        }
        // 每秒把改动同步给语言服务器（未安装服务器时会安静跳过）
        if self.lsp_checked.elapsed().as_millis() >= 1200 {
            self.lsp_checked = Instant::now();
            let revision = self.doc().revision;
            if revision != self.lsp_revision {
                if let Some(path) = self.doc().path.clone() {
                    let text = self.doc().text();
                    self.lsp.sync(&path, &text);
                    self.lsp_revision = revision;
                }
            }
        }
        // 输入停止约 260ms 后自动弹出补全（只在服务器已连接时，避免同步启动进程）。
        if let Some(at) = self.pending_complete {
            if at.elapsed().as_millis() >= 260 {
                self.pending_complete = None;
                if self.overlay.is_none()
                    && self.focus == Focus::Editor
                    && !self.tab().preview
                    && self.tab().excel.is_none()
                    && !(self.tab().word.is_some() && self.word_page_view)
                {
                    self.lsp_open_completion_auto();
                }
            }
        }
        // 内联提示：停止输入 500ms 后按文件版本刷新。
        if self.config.lsp_inlay_hints {
            let path = self.doc().path.clone();
            let revision = self.doc().revision;
            let eligible = self.last_edit.elapsed() >= std::time::Duration::from_millis(500)
                && !self.tab().preview
                && self.tab().excel.is_none()
                && !(self.tab().word.is_some() && self.word_page_view);
            if let Some(path) = path {
                if eligible && self.lsp.active_for(&path) {
                    let key = (path.clone(), revision);
                    if self.lsp_hints_key.as_ref() != Some(&key) {
                        let text = self.doc().text();
                        let hints = self.lsp.inlay_hints(&path, &text);
                        self.inlay_hints.insert(path, hints);
                        self.lsp_hints_key = Some(key);
                    }
                }
            } else {
                self.lsp_hints_key = None;
            }
        } else if self.lsp_hints_key.take().is_some() {
            self.inlay_hints.clear();
        }
        // 自动保存：停止输入 2 秒后保存已命名的纯文本标签。
        if self.config.autosave && self.last_edit.elapsed() >= std::time::Duration::from_secs(2) {
            let config = self.config.clone();
            let width = self.text_width();
            let mut saved = 0usize;
            for tab in &mut self.tabs {
                if !tab.doc.is_dirty() || tab.doc.path.is_none() || tab.doc.read_only {
                    continue;
                }
                if tab.word.is_some() || tab.excel.is_some() || tab.image.is_some() {
                    continue;
                }
                if tab.save_document().is_ok() {
                    tab.git_revision = 0;
                    tab.refresh(&config, width, true);
                    saved += 1;
                }
            }
            if saved > 0 {
                self.set_status(format!("已自动保存 {saved} 个文件"));
            }
        }
        // 任务运行器：轮询退出状态，并在输出面板打开时刷新内容。
        let mut finished: Option<(String, Option<i32>)> = None;
        if let Some(run) = self.task_run.as_mut() {
            if run.poll() {
                finished = Some((run.label.clone(), run.exit_code()));
            }
        }
        if let Some((label, code)) = finished {
            match code {
                Some(0) => self.set_status(format!("任务完成：{label}")),
                Some(code) => self.set_status(format!("任务失败（退出码 {code}）：{label}")),
                None => self.set_status(format!("任务结束：{label}")),
            }
        }
        let output_open =
            matches!(&self.overlay, Overlay::List(list) if list.kind == ListKind::TaskOutput);
        if output_open && self.task_refresh_at.elapsed().as_millis() >= 300 {
            self.task_refresh_at = Instant::now();
            let items = self.task_output_items();
            if let Overlay::List(list) = &mut self.overlay {
                list.items = items;
                list.refilter();
                list.selected = list.filtered.len().saturating_sub(1);
            }
        }
        // 调试会话：处理适配器发来的应答与事件。
        let messages = match self.debug.client.as_ref() {
            Some(client) => client.drain(),
            None => Vec::new(),
        };
        for message in messages {
            if let Some((path, line)) = self.debug.ingest(&message) {
                self.open_debug_location(path, line);
            }
        }
        if self.debug.running {
            let exited = self
                .debug
                .client
                .as_ref()
                .map(|client| !client.is_alive())
                .unwrap_or(true);
            if exited {
                self.debug.running = false;
                self.debug.status = "调试适配器已退出".into();
            }
        }
        let debug_open =
            matches!(&self.overlay, Overlay::List(list) if list.kind == ListKind::DebugOutput);
        if debug_open && self.debug_refresh_at.elapsed().as_millis() >= 300 {
            self.debug_refresh_at = Instant::now();
            let items = self.debug_output_items();
            if let Overlay::List(list) = &mut self.overlay {
                list.items = items;
                list.refilter();
                list.selected = list.filtered.len().saturating_sub(1);
            }
        }
        // 插件宿主：推进定时器 / Promise，并处理插件推来的请求。
        if self.config.plugins_enabled {
            self.plugin.tick();
            if self.plugin.is_running() {
                let revision = self.doc().revision;
                if revision != self.plugin_revision {
                    self.plugin_revision = revision;
                    if let Some(path) = self.doc().path.clone() {
                        let payload = crate::lsp::json::object(vec![(
                            "path",
                            crate::lsp::json::Json::String(path.to_string_lossy().to_string()),
                        )])
                        .dump();
                        self.plugin.fire_event("change", &payload);
                    }
                }
            }
            self.process_plugin_requests();
            self.refresh_plugin_output_panel();
        }
    }

    /// 记录当前打开的文件与光标，供下次启动恢复。
    fn save_session(&self) {
        let mut files = Vec::new();
        let mut active = 0usize;
        for (index, tab) in self.tabs.iter().enumerate() {
            let Some(path) = tab.doc.path.clone() else {
                continue;
            };
            if tab.image.is_some() {
                continue;
            }
            if index == self.active {
                active = files.len();
            }
            let pos = tab.doc.primary().pos;
            files.push(crate::ui::session::SessionFile {
                path,
                line: pos.line,
                col: pos.col,
            });
        }
        if files.is_empty() {
            // 没有任何可恢复文件时也写入空会话，避免下次启动恢复过期列表。
            crate::ui::session::Session::default().save();
            return;
        }
        crate::ui::session::Session { files, active }.save();
    }

    /// 启动时恢复上次打开的文件与光标（无命令行文件时调用）。
    pub fn restore_session(&mut self) {
        if !self.config.restore_session {
            return;
        }
        let Some(session) = crate::ui::session::Session::load() else {
            return;
        };
        // 启动时的空白标签不参与恢复。
        let blank = self.tabs.len() == 1
            && self.tabs[0].doc.path.is_none()
            && !self.tabs[0].doc.is_dirty();
        if blank {
            self.tabs.clear();
            self.active = 0;
        }
        let height = self.text_height();
        let mut opened = Vec::new();
        for file in &session.files {
            if self.open_file(&file.path).is_err() {
                continue;
            }
            let index = self.active;
            opened.push(index);
            let tab = &mut self.tabs[index];
            if tab.word.is_none() && tab.excel.is_none() && tab.image.is_none() {
                let line = file.line.min(tab.doc.line_count().saturating_sub(1));
                let col = file.col.min(tab.doc.line(line).chars().count());
                tab.doc.set_cursor(Pos::new(line, col));
                tab.ensure_visible(height);
            }
        }
        if opened.is_empty() {
            if self.tabs.is_empty() {
                self.tabs.push(Tab::new(Document::empty(), &self.config));
            }
            self.active = 0;
            return;
        }
        if blank {
            self.active = opened[session.active.min(opened.len() - 1)];
        }
    }

    // ------------------------------------------------------------ 事件分发

    pub fn handle(&mut self, event: Event) {
        match event {
            Event::Resize(cols, rows) => self.resize(cols, rows),
            Event::Tick => self.tick(),
            Event::Key(key) => self.handle_key(key),
            Event::Mouse(mouse) => self.handle_mouse(mouse),
        }
    }

    fn handle_key(&mut self, key: Key) {
        if self.settings.is_some() {
            self.handle_settings_key(key);
            return;
        }
        if self.help_open {
            if key.code == KeyCode::Esc || (key.code == KeyCode::F(1) && key.mods.shift) {
                self.help_open = false;
            }
            return;
        }
        if !matches!(self.overlay, Overlay::None) {
            self.handle_overlay_key(key);
            return;
        }
        // 终端获得焦点时，按键全部转给 shell（Ctrl+` 返回）。
        if self.term_focus {
            if key.code == KeyCode::Char('`') && key.mods.ctrl {
                self.toggle_terminal_focus();
                return;
            }
            if key.code == KeyCode::Char('`') && key.mods.ctrl && key.mods.shift {
                self.toggle_terminal();
                return;
            }
            self.handle_terminal_key(key);
            return;
        }
        if key.code == KeyCode::Char('`') && key.mods.ctrl {
            self.toggle_terminal_focus();
            return;
        }
        if self.tab().is_excel() && self.focus == Focus::Editor && self.excel_global_key(key) {
            return;
        }
        if self.handle_global_key(key) {
            return;
        }
        if self.focus == Focus::Sidebar {
            self.handle_sidebar_key(key);
            return;
        }
        self.handle_editor_key(key);
    }

    fn handle_global_key(&mut self, key: Key) -> bool {
        use KeyCode::*;
        let m = key.mods;
        if let Some(cmd) = self.custom_binding(&key) {
            self.execute(cmd);
            return true;
        }
        // 分屏之间切换（Vim 关闭时也能用）。
        if key.code == Char('w') && m == Mods::ctrl().with_alt() {
            self.focus_other_pane();
            return true;
        }
        let pressed = |c: char, mods: Mods| key.code == Char(c) && m == mods;
        let cmd = if pressed('q', Mods::ctrl()) {
            Cmd::Quit
        } else if pressed('s', Mods::ctrl()) {
            Cmd::Save
        } else if pressed('s', Mods::ctrl_shift()) {
            Cmd::SaveAs
        } else if pressed('s', Mods::ctrl().with_alt()) {
            Cmd::SaveAll
        } else if pressed('n', Mods::ctrl()) {
            Cmd::NewFile
        } else if pressed('o', Mods::ctrl()) {
            Cmd::OpenPath
        } else if pressed('w', Mods::ctrl()) {
            Cmd::CloseTab
        } else if pressed('p', Mods::ctrl()) {
            Cmd::QuickOpen
        } else if pressed('p', Mods::ctrl_shift()) {
            Cmd::Palette
        } else if pressed('f', Mods::ctrl_shift()) {
            Cmd::WorkspaceSearch
        } else if pressed('h', Mods::ctrl_shift()) {
            Cmd::WorkspaceReplace
        } else if pressed('f', Mods::ctrl()) {
            Cmd::Find
        } else if pressed('h', Mods::ctrl()) {
            Cmd::Replace
        } else if pressed('g', Mods::ctrl()) {
            Cmd::GotoLine
        } else if pressed('b', Mods::ctrl_shift()) {
            Cmd::TaskRun
        } else if pressed('b', Mods::ctrl()) {
            Cmd::ToggleSidebar
        } else if pressed(',', Mods::ctrl()) {
            Cmd::OpenSettings
        } else if pressed('v', Mods::ctrl_shift()) {
            Cmd::ClipboardHistory
        } else if pressed('z', Mods::ctrl().with_alt()) {
            Cmd::ToggleZen
        } else if pressed('e', Mods::ctrl_shift()) {
            Cmd::FocusExplorer
        } else if pressed('i', Mods::ctrl_shift()) {
            Cmd::LspHover
        } else if pressed('.', Mods::ctrl()) {
            Cmd::LspCodeAction
        } else if key.code == Char(' ') && m == Mods::ctrl_shift() {
            Cmd::LspSignature
        } else if pressed('t', Mods::ctrl_shift()) {
            Cmd::ReopenClosedTab
        } else if key.code == Char('i') && m.alt && m.shift {
            Cmd::AddCursorLineEnds
        } else if pressed('t', Mods::ctrl()) {
            Cmd::LspSymbols
        } else if pressed('z', Mods::ctrl()) {
            Cmd::Undo
        } else if pressed('y', Mods::ctrl()) {
            Cmd::Redo
        } else if pressed('z', Mods::ctrl_shift()) {
            Cmd::Redo
        } else if pressed('a', Mods::ctrl()) {
            Cmd::SelectAll
        } else if pressed('l', Mods::ctrl()) {
            Cmd::SelectLine
        } else if pressed('d', Mods::ctrl()) {
            Cmd::SelectNextOccurrence
        } else if pressed('l', Mods::ctrl_shift()) && !self.tab().is_excel() {
            Cmd::SelectAllOccurrences
        } else if pressed('j', Mods::ctrl()) {
            Cmd::JoinLines
        } else if key.code == Enter && m == Mods::ctrl_shift() {
            Cmd::InsertLineAbove
        } else if key.code == Enter && m == Mods::ctrl() {
            Cmd::InsertLineBelow
        } else if pressed('\\', Mods::ctrl_shift()) {
            Cmd::GotoBracket
        } else if pressed('k', Mods::ctrl_shift()) {
            Cmd::DeleteLine
        } else if pressed('/', Mods::ctrl()) {
            Cmd::ToggleComment
        } else if pressed('z', Mods::alt()) {
            Cmd::ToggleWrap
        } else if pressed('m', Mods::alt()) {
            Cmd::ToggleMinimap
        } else if pressed('b', Mods::alt()) {
            Cmd::ToggleBold
        } else if pressed('i', Mods::alt()) {
            Cmd::ToggleItalic
        } else if pressed('u', Mods::alt()) {
            Cmd::ToggleUnderline
        } else if pressed('8', Mods::ctrl_shift()) {
            Cmd::ToggleWhitespace
        } else if pressed('[', Mods::ctrl_shift()) {
            Cmd::FoldBlock
        } else if pressed('[', Mods::ctrl().with_alt()) {
            Cmd::FoldAll
        } else if pressed(']', Mods::ctrl().with_alt()) {
            Cmd::UnfoldAll
        } else if pressed('o', Mods::ctrl_shift()) {
            Cmd::SnippetPicker
        } else if pressed('d', Mods::ctrl_shift()) {
            Cmd::CompareFile
        } else if key.code == F(1) && m.shift {
            Cmd::Help
        } else if key.code == F(1) {
            self.overlay = Overlay::Keys(KeysState);
            return true;
        } else if key.code == F(4) {
            self.overlay = Overlay::Menu(MenuState {
                index: 0,
                selected: 0,
            });
            return true;
        } else if key.code == F(6) && self.tab().word.is_some() {
            self.word_page_view = !self.word_page_view;
            self.set_status(if self.word_page_view {
                "Word 页面视图（F6 切换文本编辑）"
            } else {
                "Word 文本编辑视图（F6 回到页面视图）"
            });
            return true;
        } else if key.code == F(2) && m.shift {
            Cmd::PrevBookmark
        } else if key.code == F(2) {
            Cmd::ToggleBookmark
        } else if key.code == F(3) && m.shift {
            Cmd::FindPrev
        } else if key.code == F(3) {
            Cmd::FindNext
        } else if pressed('x', Mods::ctrl_shift()) {
            Cmd::Extensions
        } else if key.code == F(5) && m.shift {
            Cmd::DebugStop
        } else if key.code == F(5) {
            Cmd::DebugStart
        } else if key.code == F(9) {
            Cmd::DebugToggleBreakpoint
        } else if key.code == F(10) && m.shift {
            Cmd::DebugStepOut
        } else if key.code == F(10) {
            Cmd::DebugStepOver
        } else if key.code == F(11) && m.shift {
            Cmd::DebugStepOut
        } else if key.code == F(11) {
            Cmd::DebugStepIn
        } else if key.code == F(12) && m.alt {
            Cmd::LspPeekDefinition
        } else if key.code == F(12) {
            Cmd::LspDefinition
        } else if key.code == Char(' ') && m == Mods::ctrl() {
            Cmd::LspComplete
        } else if key.code == PageUp && m == Mods::ctrl() {
            self.cycle_tab(-1);
            return true;
        } else if (key.code == PageDown || key.code == Tab) && m == Mods::ctrl() {
            self.cycle_tab(1);
            return true;
        } else if let Char(ch) = key.code {
            if ch.is_ascii_digit() && m == Mods::ctrl() {
                let index = ch.to_digit(10).unwrap_or(0) as usize;
                if index == 0 {
                    self.select_tab(self.tabs.len().saturating_sub(1));
                } else if index <= self.tabs.len() {
                    self.select_tab(index - 1);
                }
                return true;
            }
            return false;
        } else {
            return false;
        };
        self.execute(cmd);
        true
    }

    fn handle_sidebar_key(&mut self, key: Key) {
        use KeyCode::*;
        if self.sidebar.mode == SidebarMode::Search && self.workspace_key(key) {
            return;
        }
        if self.sidebar.mode == SidebarMode::Git && self.git_panel_key(key) {
            return;
        }
        if self.sidebar.mode == SidebarMode::Explorer {
            if key.code == F(2) {
                self.execute(Cmd::ExplorerRename);
                return;
            }
            if key.code == Delete {
                self.execute(Cmd::ExplorerDelete);
                return;
            }
        }
        match key.code {
            Up => {
                if self.sidebar.selected > 0 {
                    self.sidebar.selected -= 1;
                }
            }
            Down => {
                if self.sidebar.selected + 1 < self.sidebar.entries.len() {
                    self.sidebar.selected += 1;
                }
            }
            Left => {
                if let Some(entry) = self.sidebar.entries.get(self.sidebar.selected).cloned() {
                    if entry.is_dir && entry.expanded {
                        self.sidebar.toggle(self.sidebar.selected);
                    } else {
                        self.sidebar.selected = self.sidebar.selected.saturating_sub(1);
                    }
                }
            }
            Right => {
                if let Some(entry) = self.sidebar.entries.get(self.sidebar.selected).cloned() {
                    if entry.is_dir && !entry.expanded {
                        self.sidebar.toggle(self.sidebar.selected);
                    }
                }
            }
            Enter => self.sidebar_activate(),
            Esc => self.focus = Focus::Editor,
            Char('r') if key.mods == Mods::ctrl() => {
                self.sidebar.refresh(self.config.show_hidden);
            }
            _ => {}
        }
    }

    fn sidebar_activate(&mut self) {
        let Some(entry) = self.sidebar.entries.get(self.sidebar.selected).cloned() else {
            return;
        };
        if entry.is_dir {
            self.sidebar.toggle(self.sidebar.selected);
        } else if let Err(e) = self.open_file(&entry.path) {
            self.set_error(e);
        } else {
            self.focus = Focus::Editor;
        }
    }

    pub(crate) fn cycle_tab(&mut self, delta: isize) {
        if self.tabs.is_empty() {
            return;
        }
        let len = self.tabs.len() as isize;
        let mut index = self.active as isize + delta;
        if index < 0 {
            index = len - 1;
        }
        if index >= len {
            index = 0;
        }
        self.select_tab(index as usize);
    }

    pub fn select_tab(&mut self, index: usize) {
        if index < self.tabs.len() {
            self.active = index;
            self.excel_editing = false;
            self.excel_input.clear();
            if self.groups.is_empty() {
                self.groups.push(index);
            }
            let group = self.group.min(self.groups.len() - 1);
            if let Some(slot) = self.groups.get_mut(group) {
                *slot = index;
            }
            self.ensure_visible();
        }
    }

    // ------------------------------------------------------------ 编辑器按键

    /// Tab 触发 Emmet 缩写展开（HTML / XML / CSS）。
    fn try_emmet(&mut self) -> bool {
        let lang = self.doc().language;
        let is_html = matches!(lang, Language::Html | Language::Xml);
        let is_css = lang == Language::Css;
        if !is_html && !is_css {
            return false;
        }
        let pos = self.doc().primary().pos;
        let line = self.doc().line(pos.line).to_string();
        let chars: Vec<char> = line.chars().collect();
        if pos.col == 0 || pos.col > chars.len() {
            return false;
        }
        let mut start = pos.col;
        while start > 0 {
            let c = chars[start - 1];
            if c.is_alphanumeric() || ".#{}*>-+_:#".contains(c) {
                start -= 1;
            } else {
                break;
            }
        }
        if start == pos.col {
            return false;
        }
        let abbr: String = chars[start..pos.col].iter().collect();
        let expanded = if is_css {
            crate::emmet::expand_css(&abbr)
        } else {
            crate::emmet::expand_html(&abbr)
        };
        let Some(expanded) = expanded else {
            return false;
        };
        let indent = self.doc().leading_whitespace(pos.line);
        let text = crate::emmet::indent_lines(&expanded, &indent);
        {
            let d = self.doc_mut();
            for _ in 0..abbr.chars().count() {
                d.backspace(false);
            }
            d.insert_text(&text);
        }
        self.after_edit();
        true
    }

    fn handle_editor_key(&mut self, key: Key) {
        use KeyCode::*;
        if self.tab().is_excel() {
            self.handle_excel_key(key);
            return;
        }
        if self.tab().word.is_some() && self.word_page_view {
            // 页面视图只读，方向键与翻页由 GUI 处理。
            return;
        }
        // Vim 模态：插入模式交给原有输入逻辑，其余模式由引擎接管。
        if self.config.vim {
            let mode = self.vim.mode;
            let inserting = matches!(
                mode,
                crate::core::vim::Mode::Insert | crate::core::vim::Mode::Replace
            );
            if inserting {
                if key.code == Esc {
                    self.tab_mut().doc.cursors.truncate(1);
                    let pos = self.doc().primary().pos;
                    if pos.col > 0 {
                        self.tab_mut().doc.set_cursor(Pos::new(pos.line, pos.col - 1));
                    }
                    self.vim.finish_insert(&mut self.tabs[self.active].doc);
                    self.after_edit();
                    return;
                }
                self.vim.record_insert_key(key);
            } else {
                let tab_width = self.config.tab_width;
                let action = {
                    let vim = &mut self.vim;
                    let doc = &mut self.tabs[self.active].doc;
                    vim.handle(key, doc, tab_width)
                };
                self.apply_vim_action(action);
                return;
            }
        }
        let m = key.mods;
        let col = self.doc().primary().pos.col;
        let line = self.doc().primary().pos.line;
        let width = self.config.tab_width.max(1);
        match key.code {
            Char(ch) if !m.ctrl && !m.alt => {
                self.insert_char(ch);
            }
            Enter => {
                self.doc_mut().insert_newline();
                self.after_edit();
            }
            Tab if m.shift => {
                let spaces = self.config.use_spaces;
                let width = self.config.tab_width;
                self.doc_mut().indent(true, width, spaces);
                self.after_edit();
            }
            Tab => {
                if self.try_emmet() {
                    return;
                }
                let col = editor::display_col(self.doc(), line, col, width);
                let spaces = width - (col % width);
                let unit = if self.config.use_spaces {
                    " ".repeat(spaces)
                } else {
                    "\t".to_string()
                };
                self.doc_mut().insert_text(&unit);
                self.after_edit();
            }
            Backspace => {
                self.doc_mut().backspace(m.ctrl);
                self.after_edit();
            }
            Delete => {
                self.doc_mut().delete_forward(m.ctrl);
                self.after_edit();
            }
            Insert => {
                self.overwrite = !self.overwrite;
                self.set_status(if self.overwrite { "改写模式" } else { "插入模式" });
            }
            Esc => {
                if self.signature_help.take().is_some() {
                    return;
                }
                let pos = self.doc().primary().pos;
                self.doc_mut().set_cursor(pos);
                self.after_edit();
            }
            Left => self.move_horizontal(true, m.ctrl, m.shift),
            Right => self.move_horizontal(false, m.ctrl, m.shift),
            Up if m.ctrl && m.alt => self.add_cursor_vertical(-1),
            Down if m.ctrl && m.alt => self.add_cursor_vertical(1),
            Up if m.alt && m.shift => self.add_cursor_vertical(-1),
            Down if m.alt && m.shift => self.add_cursor_vertical(1),
            Up if m.alt => {
                self.doc_mut().move_lines(true);
                self.after_edit();
            }
            Down if m.alt => {
                self.doc_mut().move_lines(false);
                self.after_edit();
            }
            Up => self.move_vertical(-1, m.shift),
            Down => self.move_vertical(1, m.shift),
            Home => self.move_home(m.shift, m.ctrl),
            End => self.move_end(m.shift, m.ctrl),
            PageUp => self.move_page(-1, m.shift),
            PageDown => self.move_page(1, m.shift),
            _ => {}
        }
    }

    fn handle_excel_key(&mut self, key: Key) {
        use KeyCode::*;
        let m = key.mods;
        if self.excel_editing {
            match key.code {
                Esc => {
                    self.excel_editing = false;
                    self.excel_input.clear();
                    self.set_status("已取消编辑");
                }
                Enter => {
                    self.excel_commit_edit();
                    self.excel_move(if m.shift { -1 } else { 1 }, 0, false);
                }
                Tab => {
                    self.excel_commit_edit();
                    self.excel_move(0, if m.shift { -1 } else { 1 }, false);
                }
                Backspace => {
                    self.excel_input.pop();
                }
                Char(ch) if !m.ctrl && !m.alt => {
                    self.excel_input.push(ch);
                }
                _ => {}
            }
            return;
        }
        let extend = m.shift;
        match key.code {
            Up => self.excel_move(-1, 0, extend),
            Down => self.excel_move(1, 0, extend),
            Left => self.excel_move(0, -1, extend),
            Right => self.excel_move(0, 1, extend),
            PageUp if m.ctrl => self.excel_switch_sheet(-1),
            PageDown if m.ctrl => self.excel_switch_sheet(1),
            PageUp => self.excel_move(-10, 0, extend),
            PageDown => self.excel_move(10, 0, extend),
            Home if m.ctrl => self.excel_select(0, 0, extend),
            Home => self.excel_select(self.excel_row, 0, extend),
            End if m.ctrl => {
                let bound = self
                    .tab()
                    .excel
                    .as_ref()
                    .map(|b| (b.sheet().max_row, b.sheet().max_col))
                    .unwrap_or((0, 0));
                self.excel_select(bound.0, bound.1, extend);
            }
            End => {
                let col = self.tab().excel.as_ref().map(|b| b.sheet().max_col).unwrap_or(0);
                self.excel_select(self.excel_row, col, extend);
            }
            Enter => self.excel_move(if m.shift { -1 } else { 1 }, 0, false),
            Tab => self.excel_move(0, if m.shift { -1 } else { 1 }, false),
            F(2) => self.excel_begin_edit(),
            Backspace | Delete => self.excel_clear(),
            Char(ch) if !m.ctrl && !m.alt => self.excel_type(ch),
            _ => {}
        }
    }

    pub(crate) fn current_excel_input(&self) -> String {
        match &self.tab().excel {
            Some(book) => book.sheet().cell_input(self.excel_row, self.excel_col),
            None => String::new(),
        }
    }

    fn excel_move(&mut self, delta_row: isize, delta_col: isize, extend: bool) {
        let row = (self.excel_row as isize + delta_row).max(0) as usize;
        let col = (self.excel_col as isize + delta_col).max(0) as usize;
        self.excel_select(row, col, extend);
    }

    pub(crate) fn excel_switch_sheet(&mut self, delta: isize) {
        if let Some(book) = &mut self.tab_mut().excel {
            let count = book.sheets.len() as isize;
            if count == 0 {
                return;
            }
            let mut active = book.active as isize + delta;
            if active < 0 {
                active = count - 1;
            }
            if active >= count {
                active = 0;
            }
            book.active = active as usize;
        }
        self.excel_row = 0;
        self.excel_col = 0;
        self.refresh_active(true);
        let name = self
            .tab()
            .excel
            .as_ref()
            .map(|b| b.sheet().name.clone())
            .unwrap_or_default();
        self.set_status(format!("工作表：{name}"));
    }

    pub(crate) fn excel_scroll_into_view(&mut self) {
        let rows = self.text_height().saturating_sub(1).max(1);
        let cols = (self.text_width() / 13).max(1);
        let row = self.excel_row;
        let col = self.excel_col;
        let doc = self.doc_mut();
        if row < doc.scroll_top {
            doc.scroll_top = row;
        } else if row >= doc.scroll_top + rows {
            doc.scroll_top = row + 1 - rows;
        }
        if col < doc.scroll_left {
            doc.scroll_left = col;
        } else if col >= doc.scroll_left + cols {
            doc.scroll_left = col + 1 - cols;
        }
    }

    fn insert_char(&mut self, ch: char) {
        if self.overwrite {
            self.doc_mut().delete_forward(false);
        }
        if self.auto_pair_char(ch) {
            self.after_edit();
            self.note_lsp_input(ch);
            return;
        }
        let mut buffer = [0u8; 4];
        self.doc_mut().insert_text(ch.encode_utf8(&mut buffer));
        self.after_edit();
        self.note_lsp_input(ch);
    }

    /// 记录一次输入：安排自动补全，或在 `(` / `,` 后刷新签名帮助。
    fn note_lsp_input(&mut self, ch: char) {
        let is_word = ch.is_alphanumeric() || ch == '_' || ch == '$';
        if self.config.lsp_auto_complete && is_word {
            self.pending_complete = Some(Instant::now());
        } else {
            self.pending_complete = None;
        }
        if self.config.lsp_signature_help && matches!(ch, '(' | ',') {
            self.lsp_auto_signature();
        } else if self.signature_help.is_some() {
            self.signature_help = None;
        }
    }

    /// 自动闭合括号/引号；返回是否已处理。
    fn auto_pair_char(&mut self, ch: char) -> bool {
        if !self.config.auto_pair || self.overwrite {
            return false;
        }
        // 有选区时保持普通输入。
        if self.doc().cursors.iter().any(|cursor| cursor.has_selection()) {
            return false;
        }
        // 输入闭合符号且右侧已有同一符号：光标右移，避免重复。
        if matches!(ch, ')' | ']' | '}' | '"' | '\'') && self.doc().cursors.len() == 1 {
            let pos = self.doc().primary().pos;
            if self.doc().line(pos.line).chars().nth(pos.col) == Some(ch) {
                self.doc_mut()
                    .move_cursor(Pos::new(pos.line, pos.col + 1), false);
                return true;
            }
            return false;
        }
        let close = match ch {
            '(' => ')',
            '[' => ']',
            '{' => '}',
            '"' => '"',
            '\'' => '\'',
            _ => return false,
        };
        let mut pair = String::with_capacity(8);
        pair.push(ch);
        pair.push(close);
        self.doc_mut().insert_text(&pair);
        // 所有光标回退一格，停在括号中间。
        for cursor in &mut self.doc_mut().cursors {
            cursor.pos.col = cursor.pos.col.saturating_sub(1);
            cursor.anchor = None;
        }
        true
    }

    pub(crate) fn after_edit(&mut self) {
        self.pending_quit = false;
        self.last_edit = Instant::now();
        self.ensure_visible();
        self.blink_at = Instant::now();
        self.cursor_visible = true;
        let doc = self.doc();
        self.modified_count = if doc.is_dirty() { 1 } else { 0 };
    }

    fn move_horizontal(&mut self, left: bool, word: bool, extend: bool) {
        let doc = &self.tab().doc;
        let mut cursors = Vec::with_capacity(doc.cursors.len());
        for cursor in &doc.cursors {
            if !extend {
                if let Some((start, end)) = cursor.selection() {
                    cursors.push(Cursor::at(if left { start } else { end }));
                    continue;
                }
            }
            let pos = if word {
                if left {
                    doc.prev_word(cursor.pos)
                } else {
                    doc.next_word(cursor.pos)
                }
            } else if left {
                step_left(doc, cursor.pos)
            } else {
                step_right(doc, cursor.pos)
            };
            let anchor = if extend {
                cursor.anchor.or(Some(cursor.pos))
            } else {
                None
            };
            cursors.push(Cursor {
                pos,
                anchor,
                goal: None,
            });
        }
        self.tab_mut().doc.cursors = cursors;
        self.tab_mut().doc.column_mode = false;
        self.ensure_visible();
    }

    fn move_vertical(&mut self, delta: isize, extend: bool) {
        let doc = &self.tab().doc;
        if doc.line_count() == 0 {
            return;
        }
        let tab = &self.tabs[self.active];
        let mut cursors = Vec::with_capacity(doc.cursors.len());
        for cursor in &doc.cursors {
            let goal = cursor.goal.unwrap_or_else(|| {
                editor::display_col(doc, cursor.pos.line, cursor.pos.col, doc.tab_width)
            });
            let mut line = cursor.pos.line as isize;
            let step = if delta > 0 { 1isize } else { -1 };
            let mut remaining = delta.abs();
            while remaining > 0 {
                let candidate = line + step;
                if candidate < 0 || candidate as usize >= doc.line_count() {
                    break;
                }
                line = candidate;
                if !tab.folds.is_hidden(line as usize) {
                    remaining -= 1;
                }
            }
            let line = line.max(0) as usize;
            let col = editor::col_from_display(doc, line, goal, doc.tab_width);
            let anchor = if extend {
                cursor.anchor.or(Some(cursor.pos))
            } else {
                None
            };
            cursors.push(Cursor {
                pos: Pos::new(line, col),
                anchor,
                goal: Some(goal),
            });
        }
        self.tab_mut().doc.cursors = cursors;
        self.ensure_visible();
    }

    fn move_home(&mut self, extend: bool, doc_start: bool) {
        let doc = &self.tab().doc;
        let mut cursors = Vec::new();
        for cursor in &doc.cursors {
            let pos = if doc_start {
                Pos::new(0, 0)
            } else {
                let text = doc.line(cursor.pos.line);
                let indent = editor::indent_end(text);
                if cursor.pos.col == indent {
                    Pos::new(cursor.pos.line, 0)
                } else {
                    Pos::new(cursor.pos.line, indent)
                }
            };
            let anchor = if extend {
                cursor.anchor.or(Some(cursor.pos))
            } else {
                None
            };
            cursors.push(Cursor {
                pos,
                anchor,
                goal: None,
            });
        }
        self.tab_mut().doc.cursors = cursors;
        self.ensure_visible();
    }

    fn move_end(&mut self, extend: bool, doc_end: bool) {
        let doc = &self.tab().doc;
        let mut cursors = Vec::new();
        for cursor in &doc.cursors {
            let pos = if doc_end {
                doc.end()
            } else {
                doc.line_end(cursor.pos.line)
            };
            let anchor = if extend {
                cursor.anchor.or(Some(cursor.pos))
            } else {
                None
            };
            cursors.push(Cursor {
                pos,
                anchor,
                goal: None,
            });
        }
        self.tab_mut().doc.cursors = cursors;
        self.ensure_visible();
    }

    fn move_page(&mut self, direction: isize, extend: bool) {
        let height = self.text_height().max(1) as isize;
        self.move_vertical(direction * height, extend);
    }

    fn add_cursor_vertical(&mut self, delta: isize) {
        let doc = &self.tab().doc;
        let primary = doc.primary().pos;
        let line = (primary.line as isize + delta).max(0) as usize;
        if line >= doc.line_count() {
            return;
        }
        let col = primary
            .col
            .min(doc.line_chars(line));
        self.tab_mut().doc.column_mode = true;
        self.tab_mut().doc.add_cursor(Pos::new(line, col));
    }

    // ------------------------------------------------------------ 鼠标

    fn handle_mouse(&mut self, mouse: crate::platform::console::Mouse) {
        use crate::platform::console::{Button, MouseKind};
        let (x, y) = (mouse.x as usize, mouse.y as usize);
        self.mouse_pos = Some((x, y));
        if mouse.kind == MouseKind::Up {
            self.tab_drag = None;
        }

        // 设置页优先处理（整页模态）。
        if self.settings.is_some() {
            if self.handle_settings_mouse(mouse) {
                return;
            }
        }

        // 小地图拖动中：继续跳转，松开结束。
        if self.minimap_drag {
            match mouse.kind {
                MouseKind::Up => self.minimap_drag = false,
                MouseKind::Down | MouseKind::Drag => self.minimap_jump(y),
                _ => {}
            }
            return;
        }

        if !self.overlay.is_none() {
            self.handle_overlay_mouse(mouse);
            return;
        }

        // 终端面板：点击任意位置获得焦点。
        if let Some(rect) = self.layout.terminal {
            if rect.contains(x, y) {
                if mouse.kind == MouseKind::Down {
                    self.term_focus = true;
                    self.focus = Focus::Editor;
                    self.set_status("终端（Esc 返回编辑器）");
                }
                return;
            }
        }

        // VSCode 布局：顶部菜单栏、顶部标签栏、左侧活动栏。
        if mouse.kind == MouseKind::Down {
            if let Some(index) = self.menu_at(x, y) {
                self.overlay = Overlay::Menu(MenuState { index, selected: 0 });
                return;
            }
        }
        if let Some(tabs) = self.layout.tabs_top {
            if tabs.contains(x, y) {
                let overflow = self.tabs_overflow(tabs);
                if overflow && x >= tabs.right().saturating_sub(4) {
                    if mouse.kind == MouseKind::Down {
                        self.open_tab_list();
                    }
                    return;
                }
                if let Some(tab_index) = self.tab_at_in(tabs, x) {
                    match (mouse.kind, mouse.button) {
                        (MouseKind::Down, Some(Button::Right)) => {
                            self.select_tab(tab_index);
                            self.open_tab_context(x, y);
                        }
                        (MouseKind::Down, Some(Button::Middle)) => {
                            self.request_close_tab(tab_index)
                        }
                        (MouseKind::Down, _) => {
                            self.tab_drag = Some(tab_index);
                            self.select_tab(tab_index);
                        }
                        (MouseKind::Drag, _) => self.drag_tab_to(tabs, x),
                        (MouseKind::DoubleClick, _) => self.request_close_tab(tab_index),
                        _ => {}
                    }
                }
                return;
            }
        }
        if let Some(bar) = self.layout.activity {
            if bar.contains(x, y) {
                if mouse.kind == MouseKind::Down {
                    for (mode, rect) in self.activity_items() {
                        if !rect.contains(x, y) {
                            continue;
                        }
                        let active = self.config.sidebar
                            && self.focus == Focus::Sidebar
                            && self.sidebar.mode == mode;
                        self.sidebar.mode = mode;
                        if active {
                            self.config.sidebar = false;
                            self.focus = Focus::Editor;
                        } else {
                            self.config.sidebar = true;
                            self.focus = Focus::Sidebar;
                            if mode == SidebarMode::Git {
                                self.git.refresh(&self.cwd);
                            }
                        }
                        self.resize(self.layout.cols, self.layout.rows);
                        return;
                    }
                    if let Some(rect) = self.activity_settings_rect() {
                        if rect.contains(x, y) {
                            self.open_settings();
                        }
                    }
                }
                return;
            }
        }

        // 分屏：点击哪个 pane 就切到哪个 pane。
        if self.split.is_some() {
            for (index, pane) in self.layout.panes.iter().enumerate() {
                if pane.editor.contains(x, y) && index != self.group {
                    self.group = index;
                    self.active = self
                        .groups
                        .get(index)
                        .copied()
                        .unwrap_or(self.active)
                        .min(self.tabs.len().saturating_sub(1));
                    self.ensure_visible();
                    break;
                }
            }
        }

        // 提示条（面板标题 / 状态栏）：画在边框上，点一下等同按键。
        if mouse.kind == MouseKind::Down && mouse.button != Some(Button::Right) {
            if let Some(target) = self.hint_at(x, y) {
                self.run_hint(target);
                return;
            }
        }

        // 状态栏右侧信息段：行列 / 编码 / 换行 / 语言。
        if self.layout.status.contains(x, y) {
            if mouse.kind == MouseKind::Down {
                if let Some(target) = self.status_item_at(x, y) {
                    self.run_hint(target);
                }
            }
            return;
        }

        // 滚轮：文本、侧栏、标签行都响应。
        if mouse.kind == MouseKind::Wheel {
            if let Some(side) = self.layout.sidebar {
                if side.contains(x, y) {
                    self.sidebar_wheel(mouse.wheel);
                    return;
                }
            }
            if self.layout.editor_tabs.contains(x, y)
                || self.layout.tabs_top.is_some_and(|r| r.contains(x, y))
            {
                self.cycle_tab(if mouse.wheel > 0 { -1 } else { 1 });
                return;
            }
            if self.layout.text.contains(x, y) || self.layout.editor.contains(x, y) {
                if self.tab().is_excel() {
                    let doc = self.doc_mut();
                    if mouse.wheel > 0 {
                        doc.scroll_top = doc.scroll_top.saturating_sub(3);
                    } else {
                        doc.scroll_top += 3;
                    }
                    return;
                }
                let tab = self.tab_mut();
                let max = tab.rows.len().saturating_sub(1);
                if mouse.wheel > 0 {
                    tab.top_row = tab.top_row.saturating_sub(3);
                } else if mouse.wheel < 0 {
                    tab.top_row = (tab.top_row + 3).min(max);
                }
            }
            return;
        }

        // 欢迎页：快捷入口可点击，卡片区域内不移动光标。
        for (tab_index, pane) in self.pane_views() {
            if !pane.text.contains(x, y) {
                continue;
            }
            let Some(tab) = self.tabs.get(tab_index) else {
                continue;
            };
            if !Self::is_welcome_tab(tab) {
                continue;
            }
            let Some(welcome) = self.welcome(pane.text) else {
                continue;
            };
            if mouse.kind == MouseKind::Down {
                for (rect, _, _, target) in &welcome.items {
                    if rect.contains(x, y) {
                        self.run_hint(*target);
                        return;
                    }
                }
            }
            if welcome.card.contains(x, y) {
                return;
            }
        }

        // 小地图：按下 / 拖动跳转。
        if let Some(minimap) = self.layout.minimap {
            if minimap.contains(x, y) {
                match mouse.kind {
                    MouseKind::Down => {
                        self.minimap_drag = true;
                        self.minimap_jump(y);
                    }
                    MouseKind::Drag => self.minimap_jump(y),
                    _ => {}
                }
                return;
            }
        }

        // 面包屑：点击打开符号大纲；右侧语言标签打开语言选择。
        if let Some(pane) = self
            .layout
            .panes
            .iter()
            .find(|pane| pane.breadcrumbs.contains(x, y))
            .copied()
        {
            if mouse.kind == MouseKind::Down && !self.tab().is_excel() {
                if x >= pane.breadcrumbs.right().saturating_sub(12) {
                    self.execute(Cmd::LanguagePicker);
                } else {
                    self.execute(Cmd::Outline);
                }
            }
            return;
        }

        // 行号槽：点行号选中整行，点标记列切换断点。
        let gutter_pane = self
            .layout
            .panes
            .iter()
            .find(|pane| pane.editor.contains(x, y) && x < pane.text.x && y >= pane.text.y)
            .copied();
        if gutter_pane.is_some() {
            if mouse.kind == MouseKind::Down {
                self.gutter_click(x, y);
            }
            return;
        }

        // 编辑器 pane 底部的标签栏
        for (index, pane) in self.layout.panes.iter().enumerate() {
            if !pane.tabs.contains(x, y) {
                continue;
            }
            if index != self.group {
                self.group = index;
                self.active = self
                    .groups
                    .get(index)
                    .copied()
                    .unwrap_or(self.active)
                    .min(self.tabs.len().saturating_sub(1));
            }
            if self.tabs_overflow(pane.tabs) && x >= pane.tabs.right().saturating_sub(4) {
                if mouse.kind == MouseKind::Down {
                    self.open_tab_list();
                }
                return;
            }
            if let Some(tab_index) = self.tab_at_in(pane.tabs, x) {
                match (mouse.kind, mouse.button) {
                    (MouseKind::Down, Some(Button::Right)) => {
                        self.select_tab(tab_index);
                        self.open_tab_context(x, y);
                    }
                    (MouseKind::Down, Some(Button::Middle)) => {
                        self.request_close_tab(tab_index)
                    }
                    (MouseKind::Down, _) => {
                        self.tab_drag = Some(tab_index);
                        self.select_tab(tab_index);
                    }
                    (MouseKind::Drag, _) => self.drag_tab_to(pane.tabs, x),
                    (MouseKind::DoubleClick, _) => self.request_close_tab(tab_index),
                    _ => {}
                }
            }
            return;
        }

        // 侧栏 pane 底部的标签栏：三等分切换三个视图
        if self.layout.sidebar_tabs.contains(x, y) {
            if mouse.kind == MouseKind::Down {
                let rect = self.layout.sidebar_tabs;
                let slot = ((x.saturating_sub(rect.x)) * 3 / rect.w.max(1)).min(2);
                self.sidebar.mode = match slot {
                    0 => SidebarMode::Explorer,
                    1 => SidebarMode::Search,
                    _ => SidebarMode::Git,
                };
                if self.sidebar.mode == SidebarMode::Git {
                    self.git.refresh(&self.cwd);
                }
                self.config.sidebar = true;
                self.focus = Focus::Sidebar;
                self.resize(self.layout.cols, self.layout.rows);
            }
            return;
        }

        // 侧边栏
        if let Some(rect) = self.layout.sidebar {
            if rect.contains(x, y) {
                self.focus = Focus::Sidebar;
                if self.sidebar.mode == SidebarMode::Search {
                    if y >= rect.y + 3 {
                        let visible = rect.h.saturating_sub(5);
                        let start = if self.workspace_selected >= visible && visible > 0 {
                            self.workspace_selected + 1 - visible
                        } else {
                            0
                        };
                        let index = start + (y - (rect.y + 3)) as usize;
                        if index < self.workspace_hits.len() {
                            self.workspace_selected = index;
                            if mouse.kind == MouseKind::DoubleClick {
                                self.workspace_open_hit(index);
                            }
                        }
                    }
                    return;
                }
                if self.sidebar.mode == SidebarMode::Git {
                    if y >= rect.y + 3 {
                        let visible = rect.h.saturating_sub(5);
                        let start = if self.git_selected >= visible && visible > 0 {
                            self.git_selected + 1 - visible
                        } else {
                            0
                        };
                        let index = start + (y - (rect.y + 3)) as usize;
                        if index < self.git.changes.len() {
                            self.git_selected = index;
                            if mouse.kind == MouseKind::DoubleClick {
                                self.git_diff_selected();
                            }
                        }
                    }
                    return;
                }
                let row = y.saturating_sub(rect.y + 1) + self.sidebar.scroll;
                if row < self.sidebar.entries.len() {
                    self.sidebar.selected = row;
                    if mouse.kind == MouseKind::DoubleClick {
                        self.sidebar_activate();
                    } else if mouse.kind == MouseKind::Down
                        && mouse.button == Some(Button::Right)
                    {
                        self.open_explorer_context(x, y);
                    } else if mouse.kind == MouseKind::Down {
                        let entry = self.sidebar.entries[row].clone();
                        if entry.is_dir {
                            self.sidebar.toggle(row);
                        }
                    }
                } else if mouse.kind == MouseKind::Down
                    && mouse.button == Some(Button::Right)
                {
                    self.open_explorer_context(x, y);
                }
                return;
            }
        }

        // 编辑器文本区
        let pane_text = self
            .layout
            .panes
            .iter()
            .find(|pane| pane.text.contains(x, y))
            .map(|pane| pane.text);
        if let Some(text_rect) = pane_text {
            self.focus = Focus::Editor;
            if self.tab().is_excel() {
                let text = text_rect;
                if y > text.y {
                    let row = self.tab().doc.scroll_top + (y - text.y - 1);
                    let col = if x >= text.x + 5 {
                        self.tab().doc.scroll_left + (x - text.x - 5) / 13
                    } else {
                        self.tab().doc.scroll_left
                    };
                    self.excel_row = row;
                    self.excel_col = col;
                    if mouse.kind == MouseKind::DoubleClick {
                        self.excel_input = self.current_excel_input();
                        self.excel_editing = true;
                    }
                    self.excel_scroll_into_view();
                }
                return;
            }
            let row = self.tab().top_row + (y - text_rect.y);
            let tab = self.tab();
            let Some(visual) = tab.rows.get(row).copied() else {
                return;
            };
            let local_x = x.saturating_sub(text_rect.x);
            let col = editor::col_at_x(
                &tab.doc,
                visual.line,
                visual.start,
                local_x,
                tab.doc.tab_width,
            );
            let pos = Pos::new(visual.line, col);
            match (mouse.kind, mouse.button) {
                (MouseKind::Down, Some(Button::Right)) => {
                    self.tab_mut().doc.move_cursor(pos, false);
                    self.open_editor_context(x, y);
                }
                (MouseKind::Down, _) => {
                    if mouse.mods.ctrl {
                        self.tab_mut().doc.add_cursor(pos);
                    } else if mouse.mods.alt && mouse.mods.shift {
                        self.tab_mut().doc.add_cursor(pos);
                        self.doc_mut().column_mode = true;
                    } else {
                        self.tab_mut().doc.move_cursor(pos, false);
                    }
                    self.mouse_selecting = true;
                }
                (MouseKind::Drag, _) => {
                    if self.mouse_selecting {
                        self.tab_mut().doc.move_cursor(pos, true);
                    }
                }
                (MouseKind::Up, _) => {
                    self.mouse_selecting = false;
                }
                (MouseKind::DoubleClick, _) => {
                    let pos = self.tab().doc.primary().pos;
                    self.tab_mut().doc.select_word_at(pos);
                }
                _ => {}
            }
            self.ensure_visible();
            return;
        }
    }

    // ------------------------------------------------------------ Vim 动作

    pub(crate) fn apply_vim_action(&mut self, action: crate::core::vim::Action) {
        use crate::core::vim::Action as V;
        match action {
            V::None => {}
            V::Changed => self.after_edit(),
            V::Message(text) => self.set_status(text),
            V::Cmdline(prefix) => {
                self.overlay = Overlay::Cmdline(CmdlineState {
                    prefix,
                    input: String::new(),
                    history: self.ex_history.clone(),
                    index: None,
                })
            }
            V::Search(pattern, forward) => {
                self.vim.last_search = Some((pattern.clone(), forward));
                self.search_from_cursor(&pattern, forward);
            }
            V::ScrollHalf(down) => {
                let half = (self.text_height() / 2).max(1);
                let tab = self.tab_mut();
                if down {
                    let max = tab.rows.len().saturating_sub(1);
                    tab.top_row = (tab.top_row + half).min(max);
                } else {
                    tab.top_row = tab.top_row.saturating_sub(half);
                }
            }
            V::Split(vertical) => self.split_editor(vertical),
            V::OnlyOne => self.close_split(),
            V::OtherPane => self.focus_other_pane(),
            V::Tab(delta) => self.cycle_tab(delta as isize),
        }
    }

    /// 从光标位置开始搜索，命中则移动光标。
    pub fn search_from_cursor(&mut self, pattern: &str, forward: bool) {
        let options = SearchOptions {
            case_sensitive: false,
            whole_word: false,
            regex: false,
        };
        let engine = SearchEngine::new(pattern, options);
        let doc = self.doc();
        let start = doc.primary().pos;
        let count = doc.line_count();
        let mut found = None;
        let mut index = 0usize;
        while index < count {
            let line = if forward {
                (start.line + index) % count
            } else {
                (start.line + count * 8 - index) % count
            };
            let text = doc.line(line);
            let from = if index == 0 {
                if forward {
                    start.col.saturating_add(1)
                } else {
                    0
                }
            } else {
                0
            };
            if let Some((col, _)) = engine.find_in_line(text, from) {
                if !forward && index == 0 && col >= start.col {
                    index += 1;
                    continue;
                }
                found = Some(Pos::new(line, col));
                break;
            }
            index += 1;
        }
        match found {
            Some(pos) => {
                self.doc_mut().set_cursor(pos);
                self.ensure_visible();
                self.set_status(format!("{pattern}"));
            }
            None => self.set_status(format!("未找到：{pattern}")),
        }
    }

    // ------------------------------------------------------------ 分屏 / 终端

    /// 分屏：把当前标签放到第二个 pane，并切到该 pane。
    pub fn split_editor(&mut self, vertical: bool) {
        if self.tabs.is_empty() {
            return;
        }
        if self.split.is_some() {
            self.set_status("已经分屏（:only 关闭）");
            return;
        }
        self.split = Some(if vertical {
            SplitKind::Vertical
        } else {
            SplitKind::Horizontal
        });
        self.groups = vec![self.active, self.active];
        self.group = 1;
        self.resize(self.layout.cols, self.layout.rows);
        self.set_status(if vertical { "左右分屏" } else { "上下分屏" });
    }

    pub fn close_split(&mut self) {
        if self.split.is_none() {
            return;
        }
        self.split = None;
        self.groups.truncate(1);
        self.group = 0;
        self.active = self.groups.first().copied().unwrap_or(self.active);
        self.resize(self.layout.cols, self.layout.rows);
        self.set_status("已关闭分屏");
    }

    pub fn focus_other_pane(&mut self) {
        if self.split.is_none() || self.groups.len() < 2 {
            return;
        }
        self.group = 1 - self.group.min(1);
        self.active = self.groups[self.group];
        self.ensure_visible();
    }

    /// 打开 / 关闭底部终端面板。
    pub fn toggle_terminal(&mut self) {
        if self.terminal.is_some() {
            self.terminal = None;
            self.term_focus = false;
            self.resize(self.layout.cols, self.layout.rows);
            self.set_status("终端已关闭");
            return;
        }
        let height = self.config.terminal_height.max(6);
        let cols = self.layout.cols.saturating_sub(4).max(20);
        match crate::platform::term::Terminal::spawn(
            &self.config.terminal_shell,
            cols,
            height.saturating_sub(2).max(3),
            &self.cwd,
        ) {
            Ok(term) => {
                self.terminal = Some(term);
                self.term_focus = true;
                self.resize(self.layout.cols, self.layout.rows);
                self.set_status("终端已打开（Esc 返回编辑器）");
            }
            Err(e) => self.set_error(e),
        }
    }

    /// 终端获得焦点时的按键。
    fn handle_terminal_key(&mut self, key: Key) {
        use KeyCode::*;
        let Some(term) = self.terminal.as_ref() else {
            return;
        };
        if key.code == Esc {
            self.term_focus = false;
            self.set_status("返回编辑器");
            return;
        }
        let bytes = crate::platform::term::key_bytes(&key);
        term.write(&bytes);
    }

    fn toggle_terminal_focus(&mut self) {
        if self.terminal.is_none() {
            self.toggle_terminal();
            return;
        }
        self.term_focus = !self.term_focus;
        self.set_status(if self.term_focus {
            "终端（Esc 返回编辑器）"
        } else {
            "编辑器"
        });
    }

    pub fn terminal_rect(&self) -> Option<Rect> {
        self.layout.terminal
    }

    // ------------------------------------------------------------ 鼠标辅助
    fn hint_at(&self, x: usize, y: usize) -> Option<HintTarget> {
        self.hints()
            .into_iter()
            .find(|hint| hint.rect.contains(x, y))
            .map(|hint| hint.target)
    }

    fn run_hint(&mut self, target: HintTarget) {
        match target {
            HintTarget::Cmd(cmd) => self.execute(cmd),
            HintTarget::Keys => self.overlay = Overlay::Keys(KeysState),
            HintTarget::Menu => {
                self.overlay = Overlay::Menu(MenuState {
                    index: 0,
                    selected: 0,
                })
            }
        }
    }

    fn status_item_at(&self, x: usize, y: usize) -> Option<HintTarget> {
        self.status_items()
            .into_iter()
            .find(|item| item.rect.contains(x, y))
            .and_then(|item| item.target)
    }

    /// 小地图点击 / 拖动：按纵向比例跳转。
    fn minimap_jump(&mut self, y: usize) {
        let Some(rect) = self.layout.minimap else {
            return;
        };
        if rect.h == 0 || self.tab().is_excel() {
            return;
        }
        let lines = self.doc().line_count().max(1);
        let ratio = y.saturating_sub(rect.y) as f32 / rect.h as f32;
        let line = ((ratio * lines as f32) as usize).min(lines - 1);
        self.focus = Focus::Editor;
        self.doc_mut().set_cursor(Pos::new(line, 0));
        self.ensure_visible();
    }

    /// 行号槽：点最左标记列切换断点，点行号选中整行。
    fn gutter_click(&mut self, x: usize, y: usize) {
        if self.tab().is_excel() {
            return;
        }
        let Some(pane) = self
            .layout
            .panes
            .iter()
            .find(|pane| pane.editor.contains(x, y))
            .copied()
        else {
            return;
        };
        let text = pane.text;
        if y < text.y || y >= text.y + text.h {
            return;
        }
        let line = self.tab().top_row + (y - text.y);
        if line >= self.doc().line_count() {
            return;
        }
        self.focus = Focus::Editor;
        self.doc_mut().set_cursor(Pos::new(line, 0));
        if x <= pane.editor.x + 1 {
            self.execute(Cmd::DebugToggleBreakpoint);
        } else {
            self.execute(Cmd::SelectLine);
        }
    }

    fn sidebar_wheel(&mut self, delta: i16) {
        if delta == 0 {
            return;
        }
        let step: isize = if delta > 0 { -3 } else { 3 };
        self.focus = Focus::Sidebar;
        match self.sidebar.mode {
            SidebarMode::Search => {
                let max = self.workspace_hits.len().saturating_sub(1) as isize;
                self.workspace_selected =
                    (self.workspace_selected as isize + step).clamp(0, max) as usize;
            }
            SidebarMode::Git => {
                let max = self.git.changes.len().saturating_sub(1) as isize;
                self.git_selected = (self.git_selected as isize + step).clamp(0, max) as usize;
            }
            SidebarMode::Explorer => {
                let max = self.sidebar.entries.len().saturating_sub(1) as isize;
                self.sidebar.selected =
                    (self.sidebar.selected as isize + step).clamp(0, max) as usize;
            }
        }
    }

    fn open_context(&mut self, x: usize, y: usize, items: Vec<ContextItem>) {
        if items.is_empty() {
            return;
        }
        self.overlay = Overlay::Context(ContextState {
            items,
            x,
            y,
            selected: 0,
        });
    }

    fn open_editor_context(&mut self, x: usize, y: usize) {
        let items = if self.tab().is_excel() {
            vec![
                ContextItem { label: "剪切".into(), cmd: Cmd::Cut },
                ContextItem { label: "复制".into(), cmd: Cmd::Copy },
                ContextItem { label: "粘贴".into(), cmd: Cmd::Paste },
                ContextItem { label: "清除内容".into(), cmd: Cmd::ExcelClear },
                ContextItem { label: "合并单元格".into(), cmd: Cmd::ExcelMerge },
                ContextItem { label: "命令面板…".into(), cmd: Cmd::Palette },
            ]
        } else {
            vec![
                ContextItem { label: "剪切".into(), cmd: Cmd::Cut },
                ContextItem { label: "复制".into(), cmd: Cmd::Copy },
                ContextItem { label: "粘贴".into(), cmd: Cmd::Paste },
                ContextItem { label: "撤销".into(), cmd: Cmd::Undo },
                ContextItem { label: "重做".into(), cmd: Cmd::Redo },
                ContextItem { label: "选中当前行".into(), cmd: Cmd::SelectLine },
                ContextItem { label: "全选".into(), cmd: Cmd::SelectAll },
                ContextItem { label: "查找…".into(), cmd: Cmd::Find },
                ContextItem { label: "命令面板…".into(), cmd: Cmd::Palette },
            ]
        };
        self.open_context(x, y, items);
    }

    fn open_tab_context(&mut self, x: usize, y: usize) {
        let items = vec![
            ContextItem { label: "关闭标签页".into(), cmd: Cmd::CloseTab },
            ContextItem { label: "重新打开已关闭的标签".into(), cmd: Cmd::ReopenClosedTab },
            ContextItem { label: "在右侧拆分".into(), cmd: Cmd::SplitVertical },
            ContextItem { label: "在下方拆分".into(), cmd: Cmd::SplitHorizontal },
            ContextItem { label: "移动到另一组".into(), cmd: Cmd::MoveTabToOtherGroup },
            ContextItem { label: "复制文件路径".into(), cmd: Cmd::CopyPath },
            ContextItem { label: "保存".into(), cmd: Cmd::Save },
            ContextItem { label: "命令面板…".into(), cmd: Cmd::Palette },
        ];
        self.open_context(x, y, items);
    }

    fn open_explorer_context(&mut self, x: usize, y: usize) {
        let items = vec![
            ContextItem { label: "新建文件…".into(), cmd: Cmd::ExplorerNewFile },
            ContextItem { label: "新建文件夹…".into(), cmd: Cmd::ExplorerNewFolder },
            ContextItem { label: "重命名…".into(), cmd: Cmd::ExplorerRename },
            ContextItem { label: "删除".into(), cmd: Cmd::ExplorerDelete },
            ContextItem { label: "刷新".into(), cmd: Cmd::ExplorerRefresh },
        ];
        self.open_context(x, y, items);
    }

    // ------------------------------------------------------------ 几何辅助

    pub fn tab_title(tab: &Tab) -> String {
        let dirty = if tab.doc.is_dirty() { "● " } else { "" };
        format!("{dirty}{} ", tab.doc.title())
    }

    /// 标签栏里显示的纯名称（是否修改由图标表示）。
    pub fn tab_label(tab: &Tab) -> String {
        tab.doc.title()
    }

    pub fn tab_at_x(&self, x: usize) -> Option<usize> {
        let rect = self.layout.editor_tabs;
        let mut cursor = rect.x;
        for (index, tab) in self.tabs.iter().enumerate() {
            let width = crate::render::canvas::text_width(&Self::tab_label(tab)) + 4;
            if x >= cursor && x < cursor + width {
                return Some(index);
            }
            cursor += width;
        }
        None
    }

    /// VSCode 顶部菜单栏的菜单项命中区（绘制与点击共用）。
    pub fn menu_bar_items(&self) -> Vec<(usize, Rect, &'static str)> {
        let Some(bar) = self.layout.menu else {
            return Vec::new();
        };
        let mut out = Vec::new();
        let mut x = bar.x + 1 + crate::render::canvas::text_width("Textm") + 2;
        for (index, menu) in self.menus().iter().enumerate() {
            let width = crate::render::canvas::text_width(menu.title) + 2;
            if x + width > bar.right() {
                break;
            }
            out.push((
                index,
                Rect {
                    x,
                    y: bar.y,
                    w: width,
                    h: 1,
                },
                menu.title,
            ));
            x += width + 1;
        }
        out
    }

    /// 顶部菜单栏命中：返回菜单下标。
    pub fn menu_at(&self, x: usize, y: usize) -> Option<usize> {
        self.menu_bar_items()
            .into_iter()
            .find(|(_, rect, _)| rect.contains(x, y))
            .map(|(index, _, _)| index)
    }

    /// VSCode 左侧活动栏的图标行。
    pub fn activity_items(&self) -> Vec<(SidebarMode, Rect)> {
        let Some(bar) = self.layout.activity else {
            return Vec::new();
        };
        let modes = [SidebarMode::Explorer, SidebarMode::Search, SidebarMode::Git];
        let mut out = Vec::new();
        for (index, mode) in modes.iter().enumerate() {
            let y = bar.y + 1 + index * 2;
            if y >= bar.bottom() {
                break;
            }
            out.push((
                *mode,
                Rect {
                    x: bar.x,
                    y,
                    w: bar.w,
                    h: 1,
                },
            ));
        }
        out
    }

    /// 空白未命名文档时显示欢迎页。
    pub fn is_welcome_tab(tab: &Tab) -> bool {
        tab.doc.path.is_none()
            && !tab.doc.is_dirty()
            && tab.doc.lines.len() == 1
            && tab.doc.lines[0].is_empty()
            && tab.image.is_none()
            && tab.word.is_none()
            && tab.excel.is_none()
            && !tab.preview
    }

    /// 欢迎页卡片与快捷入口（按文本区居中）。
    pub fn welcome(&self, text: Rect) -> Option<Welcome> {
        let entries: [(&'static str, &'static str, HintTarget); 5] = [
            ("快速打开文件", "Ctrl+P", HintTarget::Cmd(Cmd::QuickOpen)),
            ("命令面板", "Ctrl+Shift+P", HintTarget::Cmd(Cmd::Palette)),
            ("打开文件…", "Ctrl+O", HintTarget::Cmd(Cmd::OpenPath)),
            ("设置", "Ctrl+,", HintTarget::Cmd(Cmd::OpenSettings)),
            ("键位速查", "F1", HintTarget::Keys),
        ];
        let height = entries.len() + 8;
        let width = 56.min(text.w.saturating_sub(6));
        if width < 34 || text.h < height + 2 {
            return None;
        }
        let card = Rect {
            x: text.x + (text.w - width) / 2,
            y: text.y + (text.h - height) / 2,
            w: width,
            h: height,
        };
        let items = entries
            .iter()
            .enumerate()
            .map(|(index, (label, shortcut, target))| {
                (
                    Rect {
                        x: card.x + 2,
                        y: card.y + 6 + index,
                        w: card.w.saturating_sub(4),
                        h: 1,
                    },
                    *label,
                    *shortcut,
                    *target,
                )
            })
            .collect();
        Some(Welcome { card, items })
    }

    /// 活动栏底部的设置图标。
    pub fn activity_settings_rect(&self) -> Option<Rect> {
        let bar = self.layout.activity?;
        if bar.h <= 4 {
            return None;
        }
        Some(Rect {
            x: bar.x,
            y: bar.bottom() - 1,
            w: bar.w,
            h: 1,
        })
    }

    pub fn tab_at_in(&self, rect: Rect, x: usize) -> Option<usize> {
        let mut cursor = rect.x;
        for (index, tab) in self.tabs.iter().enumerate() {
            let width = crate::render::canvas::text_width(&Self::tab_label(tab)) + 4;
            if x >= cursor && x < cursor + width {
                return Some(index);
            }
            cursor += width;
        }
        None
    }

    /// 标签总宽度（与 `tab_at_in` 的算法一致）。
    pub fn tabs_width(&self) -> usize {
        self.tabs
            .iter()
            .map(|tab| crate::render::canvas::text_width(&Self::tab_label(tab)) + 4)
            .sum()
    }

    /// 标签是否放不下（需要溢出菜单）。
    pub fn tabs_overflow(&self, rect: Rect) -> bool {
        self.tabs_width() > rect.w.saturating_sub(4)
    }

    fn drag_tab_to(&mut self, rect: Rect, x: usize) {
        let Some(from) = self.tab_drag else {
            return;
        };
        if from >= self.tabs.len() {
            self.tab_drag = None;
            return;
        }
        let Some(to) = self.tab_at_in(rect, x) else {
            return;
        };
        if to == from {
            return;
        }
        self.move_tab(from, to);
        self.tab_drag = Some(to);
    }

    /// 拖拽排序：同时修正 active 与分屏分组里记录的下标。
    fn move_tab(&mut self, from: usize, to: usize) {
        if from == to || from >= self.tabs.len() || to >= self.tabs.len() {
            return;
        }
        let tab = self.tabs.remove(from);
        self.tabs.insert(to, tab);
        let map = |index: usize| -> usize {
            if index == from {
                to
            } else if from < index && index <= to {
                index - 1
            } else if to <= index && index < from {
                index + 1
            } else {
                index
            }
        };
        self.active = map(self.active);
        for slot in &mut self.groups {
            *slot = map(*slot);
        }
    }

    /// 标签过多时的溢出列表。
    fn open_tab_list(&mut self) {
        let items = self
            .tabs
            .iter()
            .enumerate()
            .map(|(index, tab)| ListItem {
                title: tab.doc.title(),
                detail: if tab.doc.is_dirty() {
                    "未保存".into()
                } else {
                    String::new()
                },
                command: None,
                path: None,
                line: None,
                value: Some(index.to_string()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::Tabs, "打开的标签", items));
    }

    pub fn tab_span(&self, index: usize) -> (usize, usize) {
        let mut cursor = self.layout.editor_tabs.x;
        for (i, tab) in self.tabs.iter().enumerate() {
            let width = crate::render::canvas::text_width(&Self::tab_label(tab)) + 4;
            if i == index {
                return (cursor, width);
            }
            cursor += width;
        }
        (cursor, 0)
    }

    // ------------------------------------------------------------ 文件动作

    fn request_close_tab(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        if !self.tabs[index].doc.is_dirty() {
            self.close_tab(index);
            return;
        }
        if !self.config.confirm_close {
            self.close_tab(index);
            return;
        }
        let title = self.tabs[index].doc.title();
        self.overlay = Overlay::Confirm(ConfirmState {
            title: "关闭标签页".into(),
            message: format!("{title} 有未保存的修改，是否保存？"),
            selected: 0,
            action: ConfirmAction::CloseTab(index),
        });
    }

    fn close_tab(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        {
            let t = &self.tabs[index];
            let entry = ClosedTab {
                path: t.doc.path.clone(),
                text: t.doc.lines.join("\n"),
                title: t.doc.title(),
                cursor: t.doc.primary().pos,
                preview: t.preview,
            };
            self.closed_tabs.insert(0, entry);
            self.closed_tabs.truncate(20);
        }
        self.tabs.remove(index);
        if self.tabs.is_empty() {
            self.tabs.push(Tab::new(Document::empty(), &self.config));
        }
        self.active = self.active.min(self.tabs.len() - 1);
        // 分组下标随标签删除一起前移，避免指向错误文件。
        for slot in &mut self.groups {
            if *slot > index {
                *slot -= 1;
            } else if *slot >= self.tabs.len() {
                *slot = self.tabs.len() - 1;
            }
        }
        if self.split.is_some() && self.groups.len() < 2 {
            self.close_split();
        }
        self.set_status("标签页已关闭");
    }

    fn request_quit(&mut self) {
        for index in 0..self.tabs.len() {
            if self.tabs[index].doc.is_dirty() {
                let title = self.tabs[index].doc.title();
                self.active = index;
                self.overlay = Overlay::Confirm(ConfirmState {
                    title: "退出 Textm".into(),
                    message: format!("{title} 有未保存的修改，是否保存？"),
                    selected: 0,
                    action: ConfirmAction::Quit,
                });
                return;
            }
        }
        self.finish_quit();
    }

    pub fn finish_quit(&mut self) {
        self.config.theme = self.theme.name.to_string();
        self.config.show_whitespace = self.show_whitespace;
        self.config.last_dir = Some(self.cwd.clone());
        if self.config.restore_session {
            self.save_session();
        }
        self.config.save();
        self.lsp.shutdown();
        self.running = false;
    }

    fn copy_selection(&mut self, copy_only: bool) {
        let selection = self.doc().selections_text();
        let text = selection.clone().or_else(|| {
            let pos = self.doc().primary().pos;
            let line = self.doc().line(pos.line).to_string();
            if line.trim().is_empty() {
                None
            } else {
                Some(line)
            }
        });
        let Some(text) = text else {
            return;
        };
        if selection.is_some() {
            let html = self.selection_html(&text);
            let _ = clipboard::set_text_and_html(&text, &html);
        } else {
            let _ = clipboard::set_text(&text);
        }
        if !copy_only {
            self.doc_mut().insert_text("");
            self.after_edit();
        }
        self.push_clip_history(&text);
        self.set_status(format!("已复制 {} 个字符", text.chars().count()));
    }

    /// 选中文本转 HTML（保留语法颜色），供 Word/浏览器粘贴。
    fn selection_html(&self, text: &str) -> String {
        let mut out = String::from(
            "<pre style=\"font-family:Consolas,'Courier New',monospace;font-size:13px;\">",
        );
        let mut state = LexState::Normal;
        for (line_index, line) in text.split('\n').enumerate() {
            if line_index > 0 {
                out.push('\n');
            }
            let tokens = highlight::highlight(self.doc().language, line, &mut state);
            let chars: Vec<char> = line.chars().collect();
            let mut index = 0usize;
            for token in tokens {
                if token.start > index {
                    let chunk: String = chars[index..token.start.min(chars.len())].iter().collect();
                    out.push_str(&escape_html(&chunk));
                }
                let color = self.theme.token_color(token.kind).hex();
                let chunk: String = chars
                    .get(token.start..token.end.min(chars.len()))
                    .unwrap_or(&[])
                    .iter()
                    .collect();
                out.push_str(&format!("<span style=\"color:{color}\">{}</span>", escape_html(&chunk)));
                index = token.end;
            }
            if index < chars.len() {
                let chunk: String = chars[index..].iter().collect();
                out.push_str(&escape_html(&chunk));
            }
        }
        out.push_str("</pre>");
        out
    }

    // 供命令模块调用的公开包装
    pub(crate) fn request_close_tab_public(&mut self, index: usize) {
        self.request_close_tab(index);
    }

    pub(crate) fn request_quit_public(&mut self) {
        self.request_quit();
    }

    pub(crate) fn close_tab_public(&mut self, index: usize) {
        self.close_tab(index);
    }

    pub(crate) fn copy_selection_public(&mut self, copy_only: bool) {
        self.copy_selection(copy_only);
    }
}

fn escape_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

fn step_left(doc: &Document, pos: Pos) -> Pos {
    if pos.col > 0 {
        Pos::new(pos.line, pos.col - 1)
    } else if pos.line > 0 {
        let line = pos.line - 1;
        Pos::new(line, doc.line_chars(line))
    } else {
        pos
    }
}

fn step_right(doc: &Document, pos: Pos) -> Pos {
    let len = doc.line_chars(pos.line);
    if pos.col < len {
        Pos::new(pos.line, pos.col + 1)
    } else if pos.line + 1 < doc.line_count() {
        Pos::new(pos.line + 1, 0)
    } else {
        pos
    }
}

/// 把按键转成可配置的组合字符串，例如 `ctrl+shift+t`、`f12`、`alt+i`。
pub fn key_combo(key: &Key) -> String {
    let mut parts: Vec<String> = Vec::new();
    if key.mods.ctrl {
        parts.push("ctrl".into());
    }
    if key.mods.alt {
        parts.push("alt".into());
    }
    if key.mods.shift {
        parts.push("shift".into());
    }
    let code = match key.code {
        KeyCode::Char(' ') => "space".to_string(),
        KeyCode::Char(c) => c.to_ascii_lowercase().to_string(),
        KeyCode::Enter => "enter".into(),
        KeyCode::Tab => "tab".into(),
        KeyCode::Backspace => "backspace".into(),
        KeyCode::Esc => "esc".into(),
        KeyCode::Up => "up".into(),
        KeyCode::Down => "down".into(),
        KeyCode::Left => "left".into(),
        KeyCode::Right => "right".into(),
        KeyCode::Home => "home".into(),
        KeyCode::End => "end".into(),
        KeyCode::PageUp => "pageup".into(),
        KeyCode::PageDown => "pagedown".into(),
        KeyCode::Insert => "insert".into(),
        KeyCode::Delete => "delete".into(),
        KeyCode::F(n) => format!("f{n}"),
        KeyCode::Unknown(n) => format!("unknown{n}"),
    };
    parts.push(code);
    parts.join("+")
}

fn cmd_from_name(name: &str) -> Option<Cmd> {
    let target = name.trim();
    crate::ui::commands::COMMANDS
        .iter()
        .find(|(_, cmd)| format!("{cmd:?}").eq_ignore_ascii_case(target))
        .map(|(_, cmd)| *cmd)
}

impl App {
    fn custom_binding(&self, key: &Key) -> Option<Cmd> {
        if self.config.keymap.is_empty() {
            return None;
        }
        let combo = key_combo(key);
        self.config
            .keymap
            .iter()
            .find(|(name, _)| *name == combo)
            .and_then(|(_, cmd)| cmd_from_name(cmd))
    }
}

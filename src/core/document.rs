//! 文档模型：行文本、多光标、选区、编辑、撤销 / 重做、文件读写。
//!
//! 每行是 UTF-8 `String`，列号按「字符」计数（不是字节），
//! 这样中文、Emoji 与宽字符在编辑时都不会被截断。

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Instant;

use super::encoding::{self, Encoding, Eol};
use super::language::Language;
use crate::platform::log;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Default)]
pub struct Pos {
    pub line: usize,
    pub col: usize,
}

impl Pos {
    pub fn new(line: usize, col: usize) -> Pos {
        Pos { line, col }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Cursor {
    pub pos: Pos,
    /// 选区锚点；`None` 表示没有选中内容。
    pub anchor: Option<Pos>,
    /// 上下移动时尽量保持的目标列。
    pub goal: Option<usize>,
}

impl Cursor {
    pub fn at(pos: Pos) -> Cursor {
        Cursor {
            pos,
            anchor: None,
            goal: None,
        }
    }

    pub fn selection(&self) -> Option<(Pos, Pos)> {
        let anchor = self.anchor?;
        if anchor == self.pos {
            return None;
        }
        Some(if anchor < self.pos {
            (anchor, self.pos)
        } else {
            (self.pos, anchor)
        })
    }

    pub fn has_selection(&self) -> bool {
        self.selection().is_some()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum GroupKind {
    Insert,
    Delete,
    Other,
}

struct UndoGroup {
    start: usize,
    before: Vec<String>,
    after: Vec<String>,
    cursors_before: Vec<Cursor>,
    cursors_after: Vec<Cursor>,
    kind: GroupKind,
    time: Instant,
}

pub struct Document {
    pub path: Option<PathBuf>,
    pub lines: Vec<String>,
    pub cursors: Vec<Cursor>,
    /// 列选择模式：Backspace / Delete 只在行内删字符，不合并行。
    pub column_mode: bool,
    pub encoding: Encoding,
    pub eol: Eol,
    pub language: Language,
    pub wrap: bool,
    pub tab_width: usize,
    pub use_spaces: bool,
    pub auto_indent: bool,
    pub scroll_top: usize,
    pub scroll_left: usize,
    pub bookmarks: BTreeSet<usize>,
    pub read_only: bool,
    undo: Vec<UndoGroup>,
    redo: Vec<UndoGroup>,
    saved_undo_len: usize,
    meta_dirty: bool,
    last_edit: Option<Instant>,
    /// 版本号：每次内容变化 +1，供高亮缓存失效。
    pub revision: u64,
}

impl Document {
    pub fn empty() -> Document {
        Document {
            path: None,
            lines: vec![String::new()],
            cursors: vec![Cursor::at(Pos::new(0, 0))],
            column_mode: false,
            encoding: Encoding::Utf8,
            eol: Eol::CrLf,
            language: Language::Plain,
            wrap: false,
            tab_width: 4,
            use_spaces: true,
            auto_indent: true,
            scroll_top: 0,
            scroll_left: 0,
            bookmarks: BTreeSet::new(),
            read_only: false,
            undo: Vec::new(),
            redo: Vec::new(),
            saved_undo_len: 0,
            meta_dirty: false,
            last_edit: None,
            revision: 1,
        }
    }

    pub fn from_text(text: &str, path: Option<PathBuf>) -> Document {
        let language = path
            .as_deref()
            .map(Language::from_path)
            .unwrap_or(Language::Plain);
        let mut doc = Document::empty();
        doc.lines = encoding::split_lines(text);
        doc.path = path;
        doc.language = language;
        doc.clamp_all();
        doc
    }

    pub fn load(path: &Path) -> Result<Document, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("读取失败：{e}"))?;
        let decoded = encoding::decode(&bytes);
        if decoded.lossy {
            log::warn(&format!("文件 {} 解码时出现非法字节", path.display()));
        }
        let mut doc = Document::from_text(&decoded.text, Some(path.to_path_buf()));
        doc.encoding = decoded.encoding;
        doc.eol = decoded.eol;
        doc.saved_undo_len = 0;
        Ok(doc)
    }

    pub fn text(&self) -> String {
        self.lines.join("\n")
    }

    pub fn line_count(&self) -> usize {
        self.lines.len()
    }

    pub fn line(&self, index: usize) -> &str {
        self.lines.get(index).map(|s| s.as_str()).unwrap_or("")
    }

    pub fn line_chars(&self, index: usize) -> usize {
        self.line(index).chars().count()
    }

    pub fn is_dirty(&self) -> bool {
        self.undo.len() != self.saved_undo_len || self.meta_dirty
    }

    pub fn mark_saved(&mut self) {
        self.saved_undo_len = self.undo.len();
        self.meta_dirty = false;
        self.last_edit = None;
    }

    /// 标记「需要保存」但不产生文本改动（例如 Word 文字样式）。
    pub fn touch_meta(&mut self) {
        self.meta_dirty = true;
    }

    pub fn title(&self) -> String {
        self.path
            .as_ref()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| "未命名".into())
    }

    pub fn save(&mut self) -> Result<(), String> {
        let path = self
            .path
            .clone()
            .ok_or_else(|| "尚未指定文件名，请使用「另存为」".to_string())?;
        self.save_to(&path)
    }

    pub fn save_to(&mut self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        let bytes = encoding::encode(&self.text(), self.encoding, self.eol);
        std::fs::write(path, bytes).map_err(|e| format!("保存失败：{e}"))?;
        self.path = Some(path.to_path_buf());
        if self.language == Language::Plain {
            self.language = Language::from_path(path);
        }
        self.mark_saved();
        Ok(())
    }

    /// 调整编码 / 换行符（标记为需要保存）。
    pub fn set_encoding(&mut self, encoding: Encoding) {
        if self.encoding != encoding {
            self.encoding = encoding;
            self.meta_dirty = true;
        }
    }

    pub fn set_eol(&mut self, eol: Eol) {
        if self.eol != eol {
            self.eol = eol;
            self.meta_dirty = true;
        }
    }

    // ------------------------------------------------------------ 坐标

    pub fn clamp_pos(&self, pos: Pos) -> Pos {
        let line = pos.line.min(self.lines.len().saturating_sub(1));
        let col = pos.col.min(self.line_chars(line));
        Pos::new(line, col)
    }

    pub fn clamp_all(&mut self) {
        let lengths: Vec<usize> = self.lines.iter().map(|line| line.chars().count()).collect();
        let clamp = |pos: Pos| {
            let line = pos.line.min(lengths.len().saturating_sub(1));
            Pos::new(line, pos.col.min(lengths[line]))
        };
        for cursor in &mut self.cursors {
            cursor.pos = clamp(cursor.pos);
            cursor.anchor = cursor.anchor.map(clamp);
        }
        self.dedupe_cursors();
        if self.cursors.is_empty() {
            self.cursors.push(Cursor::at(Pos::new(0, 0)));
        }
    }

    fn dedupe_cursors(&mut self) {
        let mut seen: Vec<(Pos, Option<Pos>)> = Vec::new();
        let mut kept: Vec<Cursor> = Vec::new();
        for cursor in self.cursors.drain(..) {
            let key = (cursor.pos, cursor.anchor);
            if !seen.contains(&key) {
                seen.push(key);
                kept.push(cursor);
            }
        }
        self.cursors = kept;
    }

    pub fn primary(&self) -> &Cursor {
        &self.cursors[0]
    }

    pub fn primary_mut(&mut self) -> &mut Cursor {
        &mut self.cursors[0]
    }

    pub fn set_cursor(&mut self, pos: Pos) {
        let pos = self.clamp_pos(pos);
        self.cursors = vec![Cursor::at(pos)];
        self.column_mode = false;
    }

    /// 光标处（优先）或光标左侧的括号及其配对位置。
    pub fn bracket_pair(&self, pos: Pos) -> Option<(Pos, Pos)> {
        const OPEN: &[char] = &['(', '[', '{'];
        const CLOSE: &[char] = &[')', ']', '}'];
        let chars: Vec<char> = self.line(pos.line).chars().collect();
        if let Some(ch) = chars.get(pos.col).copied() {
            if OPEN.contains(&ch) || CLOSE.contains(&ch) {
                let bracket = Pos::new(pos.line, pos.col);
                if let Some(pair) = self.find_bracket(bracket, ch) {
                    return Some((bracket, pair));
                }
            }
        }
        if pos.col > 0 {
            if let Some(ch) = chars.get(pos.col - 1).copied() {
                if OPEN.contains(&ch) || CLOSE.contains(&ch) {
                    let bracket = Pos::new(pos.line, pos.col - 1);
                    if let Some(pair) = self.find_bracket(bracket, ch) {
                        return Some((bracket, pair));
                    }
                }
            }
        }
        None
    }

    /// 从 `start` 处的括号出发，按嵌套深度查找同类型的配对括号。
    fn find_bracket(&self, start: Pos, bracket: char) -> Option<Pos> {
        let (open, close, forward) = match bracket {
            '(' => ('(', ')', true),
            '[' => ('[', ']', true),
            '{' => ('{', '}', true),
            ')' => ('(', ')', false),
            ']' => ('[', ']', false),
            '}' => ('{', '}', false),
            _ => return None,
        };
        // 限制扫描量，避免超大单行文件在每帧匹配时卡顿。
        const MAX_LINES: usize = 4000;
        let mut budget = 500_000usize;
        let mut depth = 0i32;
        if forward {
            for line in start.line..self.lines.len().min(start.line + MAX_LINES) {
                let text = self.line(line);
                let offset = if line == start.line { start.col } else { 0 };
                for (col, ch) in text.chars().enumerate().skip(offset) {
                    if ch == open {
                        depth += 1;
                    } else if ch == close {
                        depth -= 1;
                        if depth == 0 {
                            return Some(Pos::new(line, col));
                        }
                    }
                    budget -= 1;
                    if budget == 0 {
                        return None;
                    }
                }
            }
        } else {
            for line in (start.line.saturating_sub(MAX_LINES)..=start.line).rev() {
                let chars: Vec<char> = self.line(line).chars().collect();
                let offset = if line == start.line {
                    start.col + 1
                } else {
                    chars.len()
                };
                for col in (0..offset.min(chars.len())).rev() {
                    let ch = chars[col];
                    if ch == close {
                        depth += 1;
                    } else if ch == open {
                        depth -= 1;
                        if depth == 0 {
                            return Some(Pos::new(line, col));
                        }
                    }
                    budget -= 1;
                    if budget == 0 {
                        return None;
                    }
                }
            }
        }
        None
    }

    pub fn move_cursor(&mut self, pos: Pos, extend: bool) {
        let pos = self.clamp_pos(pos);
        let primary = &mut self.cursors[0];
        if extend {
            if primary.anchor.is_none() {
                primary.anchor = Some(primary.pos);
            }
        } else {
            primary.anchor = None;
        }
        primary.pos = pos;
        primary.goal = None;
        self.cursors.truncate(1);
    }

    pub fn add_cursor(&mut self, pos: Pos) {
        let pos = self.clamp_pos(pos);
        self.cursors.push(Cursor::at(pos));
        self.dedupe_cursors();
    }

    /// 选中当前词/选区的全部相同出现（Ctrl+Shift+L）。
    pub fn select_all_occurrences(&mut self) -> bool {
        if self.cursors[0].selection().is_none() && !self.select_word_at(self.cursors[0].pos) {
            return false;
        }
        let mut added = 0usize;
        while added < 500 && self.select_next_occurrence() {
            added += 1;
        }
        added > 0
    }

    /// 跳转到与光标处括号配对的位置（Ctrl+Shift+\）。
    pub fn goto_bracket(&mut self) -> bool {
        let pos = self.cursors[0].pos;
        if let Some((a, b)) = self.bracket_pair(pos) {
            let target = if pos == a { b } else { a };
            self.set_cursor(target);
            return true;
        }
        false
    }

    /// 合并当前行与下一行（Ctrl+J）。
    pub fn join_lines(&mut self) -> bool {
        let line = self.cursors[0].pos.line;
        if line + 1 >= self.lines.len() {
            return false;
        }
        let end = self.line_chars(line);
        self.set_cursor(Pos::new(line, end));
        self.delete_forward(false);
        true
    }

    pub fn insert_line_below(&mut self) {
        let line = self.cursors[0].pos.line;
        let end = self.line_chars(line);
        self.set_cursor(Pos::new(line, end));
        self.insert_text("\n");
    }

    pub fn insert_line_above(&mut self) {
        let line = self.cursors[0].pos.line;
        self.set_cursor(Pos::new(line, 0));
        self.insert_text("\n");
        self.set_cursor(Pos::new(line, 0));
    }

    /// 在选中的每一行行尾添加光标（Shift+Alt+I）。
    pub fn add_cursors_at_line_ends(&mut self) {
        let (start, end) = self.cursors[0]
            .selection()
            .map(|(a, b)| (a.line, b.line))
            .unwrap_or((self.cursors[0].pos.line, self.cursors[0].pos.line));
        let last = self.lines.len().saturating_sub(1);
        let mut cursors = Vec::new();
        for line in start..=end.min(last) {
            let col = self.line_chars(line);
            cursors.push(Cursor::at(Pos::new(line, col)));
        }
        if cursors.is_empty() {
            return;
        }
        self.cursors = cursors;
        self.dedupe_cursors();
        self.column_mode = false;
    }

    pub fn select_all(&mut self) {
        let last = self.lines.len() - 1;
        let end = Pos::new(last, self.line_chars(last));
        self.cursors = vec![Cursor {
            pos: end,
            anchor: Some(Pos::new(0, 0)),
            goal: None,
        }];
        self.column_mode = false;
    }

    /// 选中光标处或附近的一个「词」。
    pub fn select_word_at(&mut self, pos: Pos) -> bool {
        let pos = self.clamp_pos(pos);
        let line = self.line(pos.line);
        let chars: Vec<char> = line.chars().collect();
        if chars.is_empty() {
            return false;
        }
        let index = pos.col.min(chars.len().saturating_sub(1));
        let is_word = |c: char| c.is_alphanumeric() || c == '_';
        if !is_word(chars[index]) {
            return false;
        }
        let mut start = index;
        while start > 0 && is_word(chars[start - 1]) {
            start -= 1;
        }
        let mut end = index + 1;
        while end < chars.len() && is_word(chars[end]) {
            end += 1;
        }
        self.cursors = vec![Cursor {
            pos: Pos::new(pos.line, end),
            anchor: Some(Pos::new(pos.line, start)),
            goal: None,
        }];
        true
    }

    /// VS Code 风格的 Ctrl+D：无选区时选中光标处的词，
    /// 已有选区时选中下一个相同内容（不循环）。
    pub fn select_next_occurrence(&mut self) -> bool {
        let primary = self.cursors[0];
        let Some((start, end)) = primary.selection() else {
            return self.select_word_at(primary.pos);
        };
        if start.line != end.line {
            return false;
        }
        let needle: Vec<char> = self.slice(start, end).chars().collect();
        if needle.is_empty() {
            return false;
        }
        let is_word = |c: char| c.is_alphanumeric() || c == '_';
        let word_like = needle.iter().all(|c| is_word(*c));
        // 从最后一个选区的末尾继续找，避免重复添加。
        let mut from = end;
        for cursor in &self.cursors {
            if let Some((_, cursor_end)) = cursor.selection() {
                if cursor_end > from {
                    from = cursor_end;
                }
            }
        }
        let mut line = from.line;
        let mut col = from.col;
        while line < self.lines.len() {
            let chars: Vec<char> = self.line(line).chars().collect();
            let mut index = col;
            while index + needle.len() <= chars.len() {
                if chars[index..index + needle.len()] == needle[..] {
                    let before_ok = index == 0 || !is_word(chars[index - 1]);
                    let after_ok = index + needle.len() == chars.len()
                        || !is_word(chars[index + needle.len()]);
                    if !word_like || (before_ok && after_ok) {
                        let match_start = Pos::new(line, index);
                        let match_end = Pos::new(line, index + needle.len());
                        let exists = self.cursors.iter().any(|cursor| {
                            cursor.selection() == Some((match_start, match_end))
                        });
                        if !exists {
                            self.cursors.insert(
                                0,
                                Cursor {
                                    pos: match_end,
                                    anchor: Some(match_start),
                                    goal: None,
                                },
                            );
                            self.dedupe_cursors();
                            return true;
                        }
                    }
                }
                index += 1;
            }
            line += 1;
            col = 0;
        }
        false
    }

    /// 选中当前行（含换行）。
    pub fn select_line(&mut self, line: usize) {
        let line = line.min(self.lines.len() - 1);
        let (start, end) = if line + 1 < self.lines.len() {
            (Pos::new(line, 0), Pos::new(line + 1, 0))
        } else {
            (Pos::new(line, 0), Pos::new(line, self.line_chars(line)))
        };
        self.cursors = vec![Cursor {
            pos: end,
            anchor: Some(start),
            goal: None,
        }];
    }

    /// 所有光标里的选区文本，多个选区用换行连接（主光标在前）。
    pub fn selections_text(&self) -> Option<String> {
        let mut parts = Vec::new();
        for cursor in &self.cursors {
            if let Some((start, end)) = cursor.selection() {
                parts.push(self.slice(start, end));
            }
        }
        if parts.is_empty() {
            None
        } else {
            Some(parts.join("\n"))
        }
    }

    /// 取两个位置之间的文本。
    pub fn slice(&self, start: Pos, end: Pos) -> String {
        let (start, end) = if start <= end { (start, end) } else { (end, start) };
        if start.line == end.line {
            return self.sub_line(start.line, start.col, end.col);
        }
        let mut parts = Vec::new();
        parts.push(self.sub_line(start.line, start.col, self.line_chars(start.line)));
        for line in start.line + 1..end.line {
            parts.push(self.line(line).to_string());
        }
        parts.push(self.sub_line(end.line, 0, end.col));
        parts.join("\n")
    }

    fn sub_line(&self, line: usize, start: usize, end: usize) -> String {
        let text = self.line(line);
        let start_byte = char_to_byte(text, start);
        let end_byte = char_to_byte(text, end);
        text[start_byte..end_byte].to_string()
    }

    // ------------------------------------------------------------ 编辑

    /// 插入文本（替换各光标选区）。支持多行、多光标。
    pub fn insert_text(&mut self, text: &str) {
        if self.read_only {
            return;
        }
        let ranges: Vec<(Pos, Pos)> = self
            .cursors
            .iter()
            .map(|c| {
                c.selection()
                    .unwrap_or((c.pos, c.pos))
            })
            .collect();
        self.apply_edits(&ranges, text, GroupKind::Insert);
    }

    /// 在指定区间集合上批量替换为同一段文本（替换全部用）。
    pub fn replace_ranges(&mut self, ranges: &[(Pos, Pos)], text: &str) {
        if self.read_only || ranges.is_empty() {
            return;
        }
        let cursors: Vec<Cursor> = ranges
            .iter()
            .map(|(start, end)| Cursor {
                pos: *end,
                anchor: Some(*start),
                goal: None,
            })
            .collect();
        self.cursors = cursors;
        self.apply_edits(ranges, text, GroupKind::Other);
        // 替换全部后只保留一个光标，落在最后一处替换之后。
        if let Some(last) = self.cursors.last().copied() {
            self.cursors = vec![Cursor::at(last.pos)];
        }
    }

    /// 每处替换使用不同文本（正则替换里 `$&` 展开后会不同）。
    pub fn replace_ranges_each(&mut self, edits: &[(Pos, Pos, String)]) {
        if self.read_only || edits.is_empty() {
            return;
        }
        self.cursors = edits
            .iter()
            .map(|(start, end, _)| Cursor {
                pos: *end,
                anchor: Some(*start),
                goal: None,
            })
            .collect();
        let cursors_before = self.cursors.clone();
        let start_line = edits.iter().map(|(s, _, _)| s.line).min().unwrap_or(0);
        let end_before = edits
            .iter()
            .map(|(_, e, _)| e.line)
            .max()
            .unwrap_or(0)
            .min(self.lines.len() - 1);
        let before = self.lines[start_line..=end_before].to_vec();

        let mut order: Vec<usize> = (0..edits.len()).collect();
        order.sort_by(|a, b| edits[*b].1.cmp(&edits[*a].1));
        let mut results: Vec<Option<Pos>> = vec![None; edits.len()];
        for index in order {
            let (start, end) = (self.clamp_pos(edits[index].0), self.clamp_pos(edits[index].1));
            let (start, end) = if start <= end { (start, end) } else { (end, start) };
            let new_pos = self.replace_raw(start, end, &edits[index].2);
            let delta_lines = new_pos.line as isize - end.line as isize;
            for slot in results.iter_mut().flatten() {
                if *slot == end {
                    *slot = new_pos;
                } else if *slot > end {
                    if slot.line == end.line {
                        slot.col = slot.col - end.col + new_pos.col;
                        slot.line = new_pos.line;
                    } else {
                        slot.line = (slot.line as isize + delta_lines).max(0) as usize;
                    }
                }
            }
            results[index] = Some(new_pos);
        }
        for (cursor, result) in self.cursors.iter_mut().zip(results.into_iter()) {
            if let Some(pos) = result {
                cursor.pos = pos;
                cursor.anchor = None;
            }
        }
        let final_end = self
            .cursors
            .iter()
            .map(|c| c.pos.line)
            .max()
            .unwrap_or(start_line)
            .min(self.lines.len() - 1);
        let after = self.lines[start_line..=final_end].to_vec();
        self.push_undo(UndoGroup {
            start: start_line,
            before,
            after,
            cursors_before,
            cursors_after: self.cursors.clone(),
            kind: GroupKind::Other,
            time: Instant::now(),
        });
        self.after_change();
    }

    fn apply_edits(&mut self, ranges: &[(Pos, Pos)], text: &str, kind: GroupKind) {
        if ranges.is_empty() {
            return;
        }
        let cursors_before = self.cursors.clone();
        let start_line = ranges.iter().map(|(s, _)| s.line).min().unwrap_or(0);
        let end_before = ranges.iter().map(|(_, e)| e.line).max().unwrap_or(0).min(self.lines.len() - 1);
        let before = self.lines[start_line..=end_before].to_vec();

        let mut order: Vec<usize> = (0..ranges.len()).collect();
        order.sort_by(|a, b| ranges[*b].1.cmp(&ranges[*a].1));
        let mut results: Vec<Option<Pos>> = vec![None; ranges.len()];

        for index in order {
            let (start, end) = (self.clamp_pos(ranges[index].0), self.clamp_pos(ranges[index].1));
            let (start, end) = if start <= end { (start, end) } else { (end, start) };
            let new_pos = self.replace_raw(start, end, text);
            // 已处理的（更靠后的）结果要跟着本次编辑平移：
            // 同一行 -> 落到新文本末尾所在行；后面的行 -> 按行数差平移。
            let delta_lines = new_pos.line as isize - end.line as isize;
            for slot in results.iter_mut().flatten() {
                if *slot == end {
                    *slot = new_pos;
                } else if *slot > end {
                    if slot.line == end.line {
                        slot.col = slot.col - end.col + new_pos.col;
                        slot.line = new_pos.line;
                    } else {
                        slot.line = (slot.line as isize + delta_lines).max(0) as usize;
                    }
                }
            }
            results[index] = Some(new_pos);
        }

        for (cursor, result) in self.cursors.iter_mut().zip(results.into_iter()) {
            if let Some(pos) = result {
                cursor.pos = pos;
                cursor.anchor = None;
                cursor.goal = None;
            }
        }
        let final_end = self
            .cursors
            .iter()
            .map(|c| c.pos.line)
            .max()
            .unwrap_or(start_line)
            .min(self.lines.len() - 1);
        let after = self.lines[start_line..=final_end].to_vec();

        self.push_undo(UndoGroup {
            start: start_line,
            before,
            after,
            cursors_before,
            cursors_after: self.cursors.clone(),
            kind,
            time: Instant::now(),
        });
        self.after_change();
    }

    /// 把 `[start, end)` 替换为 `text`，返回新光标位置。
    fn replace_raw(&mut self, start: Pos, end: Pos, text: &str) -> Pos {
        if start == end && text.is_empty() {
            return start;
        }
        let start_line = self.lines[start.line].clone();
        let end_line = self.lines[end.line].clone();
        let start_byte = char_to_byte(&start_line, start.col);
        let end_byte = char_to_byte(&end_line, end.col);

        let prefix = &start_line[..start_byte];
        let suffix = &end_line[end_byte..];
        let pieces: Vec<&str> = text.split('\n').collect();

        let mut new_lines: Vec<String> = Vec::with_capacity(pieces.len());
        if pieces.len() == 1 {
            new_lines.push(format!("{prefix}{}{suffix}", pieces[0]));
        } else {
            new_lines.push(format!("{prefix}{}", pieces[0]));
            for piece in &pieces[1..pieces.len() - 1] {
                new_lines.push((*piece).to_string());
            }
            new_lines.push(format!("{}{suffix}", pieces[pieces.len() - 1]));
        }

        let new_pos = if pieces.len() == 1 {
            Pos::new(
                start.line,
                start.col + pieces[0].chars().count(),
            )
        } else {
            Pos::new(
                start.line + pieces.len() - 1,
                pieces[pieces.len() - 1].chars().count(),
            )
        };

        self.lines
            .splice(start.line..=end.line, new_lines);
        new_pos
    }

    fn push_undo(&mut self, group: UndoGroup) {
        // 连续输入合并成一组，撤销时一次回退一个「输入段」。
        if let Some(last) = self.undo.last_mut() {
            let mergeable = matches!(group.kind, GroupKind::Insert | GroupKind::Delete)
                && last.kind == group.kind
                && group.start == last.start
                && group.before.len() == 1
                && last.before.len() == 1
                && group.cursors_after.len() == 1
                && last.cursors_after.len() == 1
                && self
                    .last_edit
                    .map(|t| t.elapsed().as_millis() < 800)
                    .unwrap_or(false);
            if mergeable {
                last.after = group.after;
                last.cursors_after = group.cursors_after;
                last.time = group.time;
                self.last_edit = Some(group.time);
                self.redo.clear();
                return;
            }
        }
        self.undo.push(group);
        if self.undo.len() > 500 {
            self.undo.remove(0);
        }
        self.redo.clear();
        self.last_edit = Some(Instant::now());
    }

    fn after_change(&mut self) {
        self.revision = self.revision.wrapping_add(1);
        self.clamp_all();
    }

    pub fn backspace(&mut self, word: bool) {
        if self.read_only {
            return;
        }
        let mut ranges = Vec::new();
        for cursor in &self.cursors {
            if let Some((start, end)) = cursor.selection() {
                ranges.push((start, end));
                continue;
            }
            let pos = self.clamp_pos(cursor.pos);
            if pos.col > 0 {
                let line = self.line(pos.line);
                let del = if word {
                    word_start(line, pos.col)
                } else {
                    pos.col - 1
                };
                ranges.push((Pos::new(pos.line, del), pos));
            } else if !self.column_mode && pos.line > 0 {
                let prev_len = self.line_chars(pos.line - 1);
                ranges.push((Pos::new(pos.line - 1, prev_len), pos));
            }
        }
        ranges.sort();
        ranges.dedup();
        self.apply_edits(&ranges, "", GroupKind::Delete);
    }

    pub fn delete_forward(&mut self, word: bool) {
        if self.read_only {
            return;
        }
        let mut ranges = Vec::new();
        for cursor in &self.cursors {
            if let Some((start, end)) = cursor.selection() {
                ranges.push((start, end));
                continue;
            }
            let pos = self.clamp_pos(cursor.pos);
            let len = self.line_chars(pos.line);
            if pos.col < len {
                let line = self.line(pos.line);
                let end = if word {
                    word_end(line, pos.col)
                } else {
                    pos.col + 1
                };
                ranges.push((pos, Pos::new(pos.line, end)));
            } else if !self.column_mode && pos.line + 1 < self.lines.len() {
                ranges.push((pos, Pos::new(pos.line + 1, 0)));
            }
        }
        ranges.sort();
        ranges.dedup();
        self.apply_edits(&ranges, "", GroupKind::Delete);
    }

    pub fn insert_newline(&mut self) {
        if self.read_only {
            return;
        }
        // 以主光标所在行为准计算缩进；行尾是 `{ ( [ :` 时多缩进一级。
        let line_index = self.clamp_pos(self.cursors[0].pos).line;
        let line = self.line(line_index).to_string();
        let mut indent = self.leading_whitespace(line_index);
        let trimmed = line.trim_end();
        let extra = matches!(
            trimmed.chars().last(),
            Some('{') | Some('(') | Some('[') | Some(':')
        );
        if self.auto_indent && extra {
            indent.push_str(&self.indent_unit());
        }
        self.insert_text(&format!("\n{indent}"));
    }

    pub fn indent_unit(&self) -> String {
        if self.use_spaces {
            " ".repeat(self.tab_width.max(1))
        } else {
            "\t".to_string()
        }
    }

    pub fn indent_string(&self) -> String {
        self.indent_unit()
    }

    /// 缩进 / 反缩进（按选中的行，多光标各自处理）。
    pub fn indent(&mut self, outdent: bool, width: usize, use_spaces: bool) {
        if self.read_only {
            return;
        }
        let mut lines: Vec<usize> = Vec::new();
        for cursor in &self.cursors {
            let (start, end) = cursor
                .selection()
                .unwrap_or((cursor.pos, cursor.pos));
            for line in start.line..=end.line.min(self.lines.len() - 1) {
                lines.push(line);
            }
        }
        lines.sort_unstable();
        lines.dedup();
        if lines.is_empty() {
            return;
        }
        let start_line = lines[0];
        let end_line = *lines.last().unwrap();
        let before = self.lines[start_line..=end_line].to_vec();
        let cursors_before = self.cursors.clone();

        for line in lines.iter().rev() {
            let text = self.lines[*line].clone();
            let leading = text.chars().take_while(|c| *c == ' ' || *c == '\t').count();
            if outdent {
                if leading > 0 {
                    let remove = if text.starts_with('\t') {
                        1
                    } else {
                        leading.min(width)
                    };
                    let byte = char_to_byte(&text, remove);
                    self.lines[*line] = text[byte..].to_string();
                }
            } else {
                let byte = char_to_byte(&text, leading);
                let unit = if use_spaces {
                    " ".repeat(width)
                } else {
                    "\t".to_string()
                };
                self.lines[*line] = format!("{}{}{}", &text[..byte], unit, &text[byte..]);
            }
        }
        // 光标列随缩进平移
        for cursor in &mut self.cursors {
            let mut pos = cursor.pos;
            let mut anchor = cursor.anchor;
            if lines.contains(&pos.line) {
                pos.col = if outdent {
                    pos.col.saturating_sub(width.min(pos.col))
                } else {
                    pos.col + if use_spaces { width } else { 1 }
                };
            }
            if let Some(a) = &mut anchor {
                if lines.contains(&a.line) {
                    a.col = if outdent {
                        a.col.saturating_sub(width.min(a.col))
                    } else {
                        a.col + if use_spaces { width } else { 1 }
                    };
                }
            }
            cursor.pos = pos;
            cursor.anchor = anchor;
        }
        let after = self.lines[start_line..=end_line].to_vec();
        self.push_undo(UndoGroup {
            start: start_line,
            before,
            after,
            cursors_before,
            cursors_after: self.cursors.clone(),
            kind: GroupKind::Other,
            time: Instant::now(),
        });
        self.after_change();
    }

    /// 行注释切换，`prefix` 例如 `"//"`。
    pub fn toggle_comment(&mut self, prefix: &str) {
        if self.read_only {
            return;
        }
        let mut lines: Vec<usize> = Vec::new();
        for cursor in &self.cursors {
            let (start, end) = cursor.selection().unwrap_or((cursor.pos, cursor.pos));
            for line in start.line..=end.line.min(self.lines.len() - 1) {
                if !self.lines[line].trim().is_empty() {
                    lines.push(line);
                }
            }
        }
        lines.sort_unstable();
        lines.dedup();
        if lines.is_empty() {
            return;
        }
        let start_line = lines[0];
        let end_line = *lines.last().unwrap();
        let before = self.lines[start_line..=end_line].to_vec();
        let cursors_before = self.cursors.clone();

        let all_commented = lines.iter().all(|line| {
            let text = &self.lines[*line];
            let trimmed = text.trim_start();
            trimmed.starts_with(prefix)
        });
        for line in lines.iter().rev() {
            let text = self.lines[*line].clone();
            let indent = text.chars().take_while(|c| c.is_whitespace()).count();
            let byte = char_to_byte(&text, indent);
            if all_commented {
                let rest = &text[byte..];
                if let Some(stripped) = rest.strip_prefix(prefix) {
                    let stripped = stripped.strip_prefix(' ').unwrap_or(stripped);
                    self.lines[*line] = format!("{}{}", &text[..byte], stripped);
                }
            } else {
                self.lines[*line] = format!("{}{} {}", &text[..byte], prefix, &text[byte..]);
            }
        }
        let after = self.lines[start_line..=end_line].to_vec();
        self.push_undo(UndoGroup {
            start: start_line,
            before,
            after,
            cursors_before,
            cursors_after: self.cursors.clone(),
            kind: GroupKind::Other,
            time: Instant::now(),
        });
        self.after_change();
    }

    pub fn duplicate_lines(&mut self) {
        if self.read_only {
            return;
        }
        self.transform_lines(|lines| {
            let mut out = Vec::new();
            for line in lines {
                out.push(line.clone());
                out.push(line);
            }
            out
        });
    }

    pub fn delete_lines(&mut self) {
        if self.read_only {
            return;
        }
        let mut selected: Vec<usize> = Vec::new();
        for cursor in &self.cursors {
            let (start, end) = cursor.selection().unwrap_or((cursor.pos, cursor.pos));
            for line in start.line..=end.line.min(self.lines.len() - 1) {
                selected.push(line);
            }
        }
        selected.sort_unstable();
        selected.dedup();
        if selected.is_empty() {
            return;
        }
        if selected.len() == self.lines.len() {
            self.lines = vec![String::new()];
            self.cursors = vec![Cursor::at(Pos::new(0, 0))];
            self.after_change();
            return;
        }
        let start_line = selected[0];
        let end_line = *selected.last().unwrap();
        let before = self.lines[start_line..=end_line].to_vec();
        let cursors_before = self.cursors.clone();
        self.lines.drain(start_line..=end_line);
        let target = start_line.min(self.lines.len() - 1);
        self.cursors = vec![Cursor::at(Pos::new(target, 0))];
        let after = self.lines[start_line..=start_line].to_vec();
        self.push_undo(UndoGroup {
            start: start_line,
            before,
            after,
            cursors_before,
            cursors_after: self.cursors.clone(),
            kind: GroupKind::Other,
            time: Instant::now(),
        });
        self.after_change();
    }

    pub fn move_lines(&mut self, up: bool) {
        if self.read_only {
            return;
        }
        let mut selected: Vec<usize> = Vec::new();
        for cursor in &self.cursors {
            let (start, end) = cursor.selection().unwrap_or((cursor.pos, cursor.pos));
            for line in start.line..=end.line.min(self.lines.len() - 1) {
                selected.push(line);
            }
        }
        selected.sort_unstable();
        selected.dedup();
        if selected.is_empty() {
            return;
        }
        let start_line = selected[0];
        let end_line = *selected.last().unwrap();
        if (up && start_line == 0) || (!up && end_line + 1 >= self.lines.len()) {
            return;
        }
        let before = self.lines
            [start_line.saturating_sub(1)..=(end_line + 1).min(self.lines.len() - 1)]
            .to_vec();
        let cursors_before = self.cursors.clone();

        if up {
            let moved = self.lines.remove(end_line);
            self.lines.insert(start_line - 1, moved);
        } else {
            let moved = self.lines.remove(start_line);
            self.lines.insert(end_line, moved);
        }
        for cursor in &mut self.cursors {
            let delta: isize = if up { -1 } else { 1 };
            cursor.pos.line = (cursor.pos.line as isize + delta).max(0) as usize;
            if let Some(anchor) = &mut cursor.anchor {
                anchor.line = (anchor.line as isize + delta).max(0) as usize;
            }
        }
        let after_start = start_line.saturating_sub(1);
        let after_end = (end_line + 1).min(self.lines.len() - 1);
        let after = self.lines[after_start..=after_end].to_vec();
        self.push_undo(UndoGroup {
            start: after_start,
            before,
            after,
            cursors_before,
            cursors_after: self.cursors.clone(),
            kind: GroupKind::Other,
            time: Instant::now(),
        });
        self.after_change();
    }

    /// 对选中行做变换（排序 / 去重 / 大小写）。
    pub fn transform_lines(&mut self, f: impl FnOnce(Vec<String>) -> Vec<String>) {
        if self.read_only {
            return;
        }
        let mut selected: Vec<usize> = Vec::new();
        for cursor in &self.cursors {
            let (start, end) = cursor.selection().unwrap_or((cursor.pos, cursor.pos));
            for line in start.line..=end.line.min(self.lines.len() - 1) {
                selected.push(line);
            }
        }
        selected.sort_unstable();
        selected.dedup();
        if selected.is_empty() {
            return;
        }
        let start_line = selected[0];
        let end_line = *selected.last().unwrap();
        let before = self.lines[start_line..=end_line].to_vec();
        let cursors_before = self.cursors.clone();
        let block: Vec<String> = self.lines[start_line..=end_line].to_vec();
        let replaced = f(block);
        let replaced_len = replaced.len().max(1);
        self.lines.splice(start_line..=end_line, replaced);
        let after_end = (start_line + replaced_len).min(self.lines.len());
        let after = self.lines[start_line..after_end].to_vec();
        self.cursors = vec![Cursor::at(Pos::new(start_line, 0))];
        self.push_undo(UndoGroup {
            start: start_line,
            before,
            after,
            cursors_before,
            cursors_after: self.cursors.clone(),
            kind: GroupKind::Other,
            time: Instant::now(),
        });
        self.after_change();
    }

    pub fn undo(&mut self) -> bool {
        let Some(group) = self.undo.pop() else {
            return false;
        };
        let end = (group.start + group.after.len()).min(self.lines.len());
        self.lines.splice(group.start..end, group.before.iter().cloned());
        self.cursors = group.cursors_before.clone();
        let cursors_after = self.cursors.clone();
        self.redo.push(UndoGroup {
            cursors_after,
            ..group
        });
        self.last_edit = None;
        self.revision = self.revision.wrapping_add(1);
        self.clamp_all();
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(group) = self.redo.pop() else {
            return false;
        };
        let end = (group.start + group.before.len()).min(self.lines.len());
        self.lines.splice(group.start..end, group.after.iter().cloned());
        self.cursors = group.cursors_after.clone();
        self.undo.push(group);
        self.last_edit = None;
        self.revision = self.revision.wrapping_add(1);
        self.clamp_all();
        true
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    // ------------------------------------------------------------ 导航辅助

    /// 从某位置开始找下一个词边界。
    pub fn next_word(&self, pos: Pos) -> Pos {
        let mut line = pos.line;
        let mut col = pos.col;
        loop {
            let text = self.line(line);
            let chars: Vec<char> = text.chars().collect();
            if col >= chars.len() {
                if line + 1 < self.lines.len() {
                    line += 1;
                    col = 0;
                    continue;
                }
                return Pos::new(line, chars.len());
            }
            let word = is_word(chars[col]);
            while col < chars.len() && is_word(chars[col]) == word {
                col += 1;
            }
            if !word || col < chars.len() {
                return Pos::new(line, col);
            }
        }
    }

    pub fn prev_word(&self, pos: Pos) -> Pos {
        let mut line = pos.line;
        let mut col = pos.col;
        loop {
            let chars: Vec<char> = self.line(line).chars().collect();
            if col == 0 {
                if line > 0 {
                    line -= 1;
                    col = self.line_chars(line);
                    continue;
                }
                return Pos::new(0, 0);
            }
            let word = is_word(chars[col - 1]);
            while col > 0 && is_word(chars[col - 1]) == word {
                col -= 1;
            }
            if !word || col > 0 {
                return Pos::new(line, col);
            }
        }
    }

    pub fn word_start(&self, pos: Pos) -> Pos {
        let chars: Vec<char> = self.line(pos.line).chars().collect();
        let mut col = pos.col.min(chars.len());
        while col > 0 && is_word(chars[col - 1]) {
            col -= 1;
        }
        Pos::new(pos.line, col)
    }

    pub fn line_start(&self, line: usize) -> Pos {
        Pos::new(line.min(self.lines.len() - 1), 0)
    }

    pub fn line_end(&self, line: usize) -> Pos {
        let line = line.min(self.lines.len() - 1);
        Pos::new(line, self.line_chars(line))
    }

    /// 文档末尾位置。
    pub fn end(&self) -> Pos {
        let line = self.lines.len() - 1;
        Pos::new(line, self.line_chars(line))
    }

    /// 缩进宽度（用于 Tab / 自动缩进）。
    pub fn leading_whitespace(&self, line: usize) -> String {
        self.line(line)
            .chars()
            .take_while(|c| *c == ' ' || *c == '\t')
            .collect()
    }
}

fn is_word(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_'
}

pub fn char_to_byte(text: &str, col: usize) -> usize {
    if col == 0 {
        return 0;
    }
    match text.char_indices().nth(col) {
        Some((byte, _)) => byte,
        None => text.len(),
    }
}

pub fn byte_to_char(text: &str, byte: usize) -> usize {
    text[..byte.min(text.len())].chars().count()
}

fn word_start(text: &str, col: usize) -> usize {
    let chars: Vec<char> = text.chars().collect();
    let mut index = col.min(chars.len());
    while index > 0 && !is_word(chars[index - 1]) {
        index -= 1;
    }
    while index > 0 && is_word(chars[index - 1]) {
        index -= 1;
    }
    index
}

fn word_end(text: &str, col: usize) -> usize {
    let chars: Vec<char> = text.chars().collect();
    let mut index = col.min(chars.len());
    while index < chars.len() && !is_word(chars[index]) {
        index += 1;
    }
    while index < chars.len() && is_word(chars[index]) {
        index += 1;
    }
    index
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(text: &str) -> Document {
        Document::from_text(text, None)
    }

    #[test]
    fn insert_and_undo() {
        let mut d = doc("abc");
        d.set_cursor(Pos::new(0, 1));
        d.insert_text("X");
        assert_eq!(d.text(), "aXbc");
        assert!(d.is_dirty());
        assert!(d.undo());
        assert_eq!(d.text(), "abc");
        assert!(d.redo());
        assert_eq!(d.text(), "aXbc");
    }

    #[test]
    fn bracket_matching() {
        let d = doc("fn f() {\n  let v = [1, (2)];\n}");
        // 光标在左括号上
        assert_eq!(
            d.bracket_pair(Pos::new(0, 4)),
            Some((Pos::new(0, 4), Pos::new(0, 5)))
        );
        // 光标紧邻右括号之后
        assert_eq!(
            d.bracket_pair(Pos::new(0, 6)),
            Some((Pos::new(0, 5), Pos::new(0, 4)))
        );
        // 跨行花括号
        assert_eq!(
            d.bracket_pair(Pos::new(0, 7)),
            Some((Pos::new(0, 7), Pos::new(2, 0)))
        );
        // 嵌套方括号
        assert_eq!(
            d.bracket_pair(Pos::new(1, 10)),
            Some((Pos::new(1, 10), Pos::new(1, 17)))
        );
        // 无括号
        assert_eq!(d.bracket_pair(Pos::new(1, 2)), None);
    }

    #[test]
    fn multi_cursor_insert() {
        let mut d = doc("one\ntwo\nthree");
        d.cursors = vec![
            Cursor::at(Pos::new(0, 0)),
            Cursor::at(Pos::new(1, 0)),
        ];
        d.insert_text(">");
        assert_eq!(d.text(), ">one\n>two\nthree");
        assert_eq!(d.cursors.len(), 2);
    }

    #[test]
    fn multi_cursor_with_different_line_lengths() {
        let mut d = doc("abcdef\nxy\n123456");
        d.cursors = vec![
            Cursor::at(Pos::new(0, 3)),
            Cursor::at(Pos::new(1, 1)),
            Cursor::at(Pos::new(2, 5)),
        ];
        d.insert_text("\nZ");
        assert_eq!(d.text(), "abc\nZdef\nx\nZy\n12345\nZ6");
    }

    #[test]
    fn backspace_joins_lines_and_indents() {
        let mut d = doc("ab\ncd");
        d.set_cursor(Pos::new(1, 0));
        d.backspace(false);
        assert_eq!(d.text(), "abcd");
        d.insert_newline();
        assert_eq!(d.text(), "ab\ncd");
    }

    #[test]
    fn selection_replacement() {
        let mut d = doc("hello world");
        d.cursors = vec![Cursor {
            pos: Pos::new(0, 5),
            anchor: Some(Pos::new(0, 0)),
            goal: None,
        }];
        d.insert_text("bye");
        assert_eq!(d.text(), "bye world");
        assert_eq!(d.primary().pos, Pos::new(0, 3));
    }

    #[test]
    fn select_next_occurrence() {
        let mut d = doc("foo bar\nfoo baz foo\nfoobar");
        d.set_cursor(Pos::new(0, 0));
        // 第一次：选中光标处的词
        assert!(d.select_next_occurrence());
        assert_eq!(
            d.cursors[0].selection(),
            Some((Pos::new(0, 0), Pos::new(0, 3)))
        );
        // 第二次、第三次：依次选中后续同名整词（跳过 foobar）
        assert!(d.select_next_occurrence());
        assert_eq!(d.cursors.len(), 2);
        assert!(d.select_next_occurrence());
        assert_eq!(d.cursors.len(), 3);
        assert!(!d.select_next_occurrence());
    }

    #[test]
    fn indent_and_toggle_comment() {
        let mut d = doc("fn a() {\nlet x = 1;\n}");
        d.cursors = vec![Cursor {
            pos: Pos::new(2, 0),
            anchor: Some(Pos::new(1, 0)),
            goal: None,
        }];
        d.indent(false, 4, true);
        assert_eq!(d.line(1), "    let x = 1;");
        d.toggle_comment("//");
        assert_eq!(d.line(1), "    // let x = 1;");
        d.toggle_comment("//");
        assert_eq!(d.line(1), "    let x = 1;");
    }

    #[test]
    fn positions_handle_wide_chars() {
        let mut d = doc("中a");
        d.set_cursor(Pos::new(0, 1));
        d.insert_text("X");
        assert_eq!(d.text(), "中Xa");
    }

    #[test]
    fn save_and_load_roundtrip() {
        let dir = std::env::temp_dir().join("textm-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("roundtrip.txt");
        let mut d = doc("line1\nline2");
        d.save_to(&path).unwrap();
        let loaded = Document::load(&path).unwrap();
        assert_eq!(loaded.text(), "line1\nline2");
        assert!(!loaded.is_dirty());
        let _ = std::fs::remove_file(&path);
    }
}

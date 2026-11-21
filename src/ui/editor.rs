//! 编辑器视图计算：换行、折叠、光标与鼠标位置映射。

use super::super::core::document::{Document, Pos};
use super::super::core::fold::Folds;
use super::super::core::unicode::{char_width, col_to_index, index_to_col};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VisualRow {
    pub line: usize,
    /// 本行在文档行内的起始字符列。
    pub start: usize,
    /// 结束字符列（不含）。
    pub end: usize,
    /// 是否是文档行的第一段（行号只显示在首段）。
    pub first: bool,
}

/// 计算所有可见视觉行。`width` 是文本框宽度（列）。
pub fn build_rows(doc: &Document, folds: &Folds, width: usize, wrap: bool) -> Vec<VisualRow> {
    let width = width.max(1);
    let mut rows = Vec::new();
    for line in 0..doc.line_count() {
        if folds.is_hidden(line) {
            continue;
        }
        let text = doc.line(line);
        let chars = text.chars().count();
        if !wrap || text.is_empty() {
            rows.push(VisualRow {
                line,
                start: 0,
                end: chars,
                first: true,
            });
            continue;
        }
        let mut start = 0usize;
        let mut display = 0usize;
        let mut first = true;
        for (index, ch) in text.chars().enumerate() {
            let w = char_width(ch).max(1);
            if display + w > width && index > start {
                rows.push(VisualRow {
                    line,
                    start,
                    end: index,
                    first,
                });
                first = false;
                start = index;
                display = 0;
            }
            display += w;
        }
        rows.push(VisualRow {
            line,
            start,
            end: chars,
            first,
        });
    }
    if rows.is_empty() {
        rows.push(VisualRow {
            line: 0,
            start: 0,
            end: 0,
            first: true,
        });
    }
    rows
}

/// 某个位置对应的视觉行下标。
pub fn row_of_pos(rows: &[VisualRow], pos: Pos) -> usize {
    let mut best = 0usize;
    for (index, row) in rows.iter().enumerate() {
        if row.line == pos.line {
            best = index;
            if pos.col < row.end || (pos.col == row.end && index + 1 < rows.len() && rows[index + 1].line != pos.line) {
                return index;
            }
            if pos.col <= row.end {
                return index;
            }
        }
    }
    best
}

/// 鼠标列 → 文档列（按字符边界就近吸附）。
pub fn col_at_x(doc: &Document, line: usize, start: usize, x: usize, tab_width: usize) -> usize {
    let text = doc.line(line);
    let mut display = 0usize;
    let mut index = 0usize;
    for (count, ch) in text.chars().enumerate() {
        if count < start {
            let w = if ch == '\t' {
                tab_width.max(1) - (display % tab_width.max(1))
            } else {
                char_width(ch).max(1)
            };
            display += w;
            continue;
        }
        let w = if ch == '\t' {
            tab_width.max(1) - (display % tab_width.max(1))
        } else {
            char_width(ch).max(1)
        };
        if x >= display + w {
            index = count + 1;
            display += w;
            continue;
        }
        if x > display + w / 2 {
            return count + 1;
        }
        return count;
    }
    index.max(start)
}

/// 文档列 → 显示列（Tab 按对齐展开）。
pub fn display_col(doc: &Document, line: usize, col: usize, tab_width: usize) -> usize {
    let text = doc.line(line);
    let mut display = 0usize;
    for (count, ch) in text.chars().enumerate() {
        if count >= col {
            break;
        }
        display += if ch == '\t' {
            tab_width.max(1) - (display % tab_width.max(1))
        } else {
            char_width(ch).max(1)
        };
    }
    display
}

/// 显示列 → 文档列。
pub fn col_from_display(doc: &Document, line: usize, target: usize, tab_width: usize) -> usize {
    let text = doc.line(line);
    let mut display = 0usize;
    for (count, ch) in text.chars().enumerate() {
        if display >= target {
            return count;
        }
        let w = if ch == '\t' {
            tab_width.max(1) - (display % tab_width.max(1))
        } else {
            char_width(ch).max(1)
        };
        if display + w > target {
            return count;
        }
        display += w;
    }
    text.chars().count()
}

/// 从某个视觉行开始，把文本切成若干段（用于绘制）。
pub fn wrap_segments(
    text: &str,
    start: usize,
    width: usize,
) -> Vec<(usize, usize)> {
    let width = width.max(1);
    let chars: Vec<char> = text.chars().collect();
    let mut segments = Vec::new();
    let mut from = start;
    while from < chars.len() {
        let mut to = from;
        let mut display = 0usize;
        while to < chars.len() {
            let w = char_width(chars[to]).max(1);
            if display + w > width && to > from {
                break;
            }
            display += w;
            to += 1;
        }
        segments.push((from, to));
        from = to;
    }
    if segments.is_empty() {
        segments.push((start, start));
    }
    segments
}

/// 行首（跳过缩进）与行首本身交替。
pub fn indent_end(text: &str) -> usize {
    text.chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .count()
}

/// 保证光标可见，返回需要的首行视觉下标。
pub fn scroll_to_cursor(
    rows: &[VisualRow],
    viewport_height: usize,
    top_row: usize,
    cursor_pos: Pos,
) -> usize {
    if rows.is_empty() || viewport_height == 0 {
        return 0;
    }
    let cursor_row = row_of_pos(rows, cursor_pos);
    let mut top = top_row.min(rows.len().saturating_sub(1));
    if cursor_row < top {
        top = cursor_row;
    }
    if cursor_row >= top + viewport_height {
        top = cursor_row + 1 - viewport_height;
    }
    top.min(rows.len().saturating_sub(1))
}

/// 字符列 → 屏幕列（含宽字符）。
pub fn screen_col(text: &str, col: usize) -> usize {
    index_to_col(text, col)
}

/// 屏幕列 → 字符列。
pub fn char_col(text: &str, screen: usize) -> usize {
    col_to_index(text, screen)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(text: &str) -> Document {
        Document::from_text(text, None)
    }

    #[test]
    fn rows_without_wrap() {
        let d = doc("abc\ndef");
        let folds = Folds::default();
        let rows = build_rows(&d, &folds, 20, false);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[1].line, 1);
    }

    #[test]
    fn rows_with_wrap() {
        let d = doc("abcdefghij");
        let folds = Folds::default();
        let rows = build_rows(&d, &folds, 4, true);
        assert!(rows.len() >= 3);
        assert_eq!(rows[0].start, 0);
        assert_eq!(rows[0].end, 4);
        assert!(rows[0].first);
        assert!(!rows[1].first);
    }

    #[test]
    fn cursor_rows_match_wrap() {
        let d = doc("abcdefghij\nx");
        let folds = Folds::default();
        let rows = build_rows(&d, &folds, 4, true);
        assert_eq!(row_of_pos(&rows, Pos::new(0, 2)), 0);
        assert_eq!(row_of_pos(&rows, Pos::new(0, 5)), 1);
        assert_eq!(row_of_pos(&rows, Pos::new(1, 1)), rows.len() - 1);
    }

    #[test]
    fn mouse_column_roundtrip() {
        let d = doc("a中b");
        assert_eq!(display_col(&d, 0, 2, 4), 3);
        assert_eq!(col_from_display(&d, 0, 3, 4), 2);
        assert_eq!(col_at_x(&d, 0, 0, 3, 4), 2);
    }

    #[test]
    fn tabs_align_to_stops() {
        let d = doc("\tx");
        assert_eq!(display_col(&d, 0, 1, 4), 4);
        assert_eq!(col_from_display(&d, 0, 4, 4), 1);
    }
}

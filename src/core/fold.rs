//! 代码折叠：缩进块 + 大括号块，支持折叠 / 展开与可见行映射。

use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug)]
pub struct Fold {
    pub start: usize,
    pub end: usize,
}

#[derive(Clone, Default)]
pub struct Folds {
    pub ranges: Vec<Fold>,
    pub collapsed: BTreeSet<usize>,
    pub enabled: bool,
}

impl Folds {
    pub fn recompute(&mut self, lines: &[String], tab_width: usize, enabled: bool) {
        self.enabled = enabled;
        self.ranges.clear();
        if !enabled {
            self.collapsed.clear();
            return;
        }
        let indents = indent_levels(lines, tab_width);
        let mut folds: Vec<Fold> = Vec::new();

        for start in 0..lines.len().saturating_sub(1) {
            if lines[start].trim().is_empty() {
                continue;
            }
            // 1) 缩进块：下一行缩进更深
            let base = indents[start];
            let mut end = start;
            let mut probe = start + 1;
            while probe < lines.len() {
                let blank = lines[probe].trim().is_empty();
                if blank {
                    probe += 1;
                    continue;
                }
                if indents[probe] > base {
                    end = probe;
                    probe += 1;
                } else {
                    break;
                }
            }
            if end > start {
                folds.push(Fold { start, end });
            }

            // 2) 大括号块：统计 { 与 } 的深度
            if lines[start].contains('{') {
                let mut depth = 0isize;
                let mut close = None;
                for line in start..lines.len() {
                    for ch in lines[line].chars() {
                        if ch == '{' {
                            depth += 1;
                        } else if ch == '}' {
                            depth -= 1;
                            if depth <= 0 && line > start {
                                close = Some(line);
                                break;
                            }
                        }
                    }
                    if close.is_some() {
                        break;
                    }
                }
                if let Some(close) = close {
                    if close > start {
                        folds.push(Fold {
                            start,
                            end: close,
                        });
                    }
                }
            }
        }

        // 同一行起点保留跨度最大的那个
        folds.sort_by(|a, b| a.start.cmp(&b.start).then(b.end.cmp(&a.end)));
        folds.dedup_by(|a, b| a.start == b.start);
        self.ranges = folds;
        // 折叠状态里已不存在的行号直接丢弃
        let valid: BTreeSet<usize> = self.ranges.iter().map(|f| f.start).collect();
        let stale: Vec<usize> = self
            .collapsed
            .iter()
            .copied()
            .filter(|line| !valid.contains(line))
            .collect();
        for line in stale {
            self.collapsed.remove(&line);
        }
    }

    pub fn is_hidden(&self, line: usize) -> bool {
        self.collapsed
            .iter()
            .any(|start| line > *start && self.ranges.iter().any(|f| f.start == *start && line <= f.end))
    }

    /// 该行是否是某个折叠块的起点。
    pub fn fold_at(&self, line: usize) -> bool {
        self.ranges.iter().any(|f| f.start == line)
    }

    pub fn is_collapsed(&self, line: usize) -> bool {
        self.collapsed.contains(&line)
    }

    /// 切换折叠；返回是否发生了折叠。
    pub fn toggle(&mut self, line: usize) {
        if self.collapsed.contains(&line) {
            self.collapsed.remove(&line);
            return;
        }
        if self.ranges.iter().any(|f| f.start == line) {
            self.collapsed.insert(line);
        }
    }

    pub fn collapse_all(&mut self) {
        self.collapsed = self.ranges.iter().map(|f| f.start).collect();
    }

    pub fn expand_all(&mut self) {
        self.collapsed.clear();
    }

    /// 文档行 → 可见行号（隐藏行返回 `None`）。
    pub fn visible_lines(&self, count: usize) -> Vec<usize> {
        (0..count).filter(|line| !self.is_hidden(*line)).collect()
    }

    /// 从某行向上 / 向下找下一个可见行。
    pub fn next_visible(&self, line: usize, count: usize, down: bool) -> usize {
        let mut probe = line;
        loop {
            if down {
                probe += 1;
                if probe >= count {
                    return count.saturating_sub(1);
                }
            } else {
                if probe == 0 {
                    return 0;
                }
                probe -= 1;
            }
            if !self.is_hidden(probe) {
                return probe;
            }
        }
    }

    /// 折叠块覆盖的行数（用于跳转时整体滚动）。
    pub fn block_end(&self, line: usize) -> Option<usize> {
        self.ranges.iter().find(|f| f.start == line).map(|f| f.end)
    }
}

fn indent_levels(lines: &[String], tab_width: usize) -> Vec<usize> {
    lines
        .iter()
        .map(|line| {
            let mut width = 0usize;
            for ch in line.chars() {
                match ch {
                    ' ' => width += 1,
                    '\t' => width += tab_width.max(1),
                    _ => break,
                }
            }
            width
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(text: &str) -> Vec<String> {
        text.split('\n').map(|s| s.to_string()).collect()
    }

    #[test]
    fn indentation_block_folds() {
        let text = "fn a() {\n    let x = 1;\n    let y = 2;\n}\nnext";
        let mut folds = Folds::default();
        folds.recompute(&lines(text), 4, true);
        assert!(folds.ranges.iter().any(|f| f.start == 0 && f.end >= 3));
        assert!(!folds.is_hidden(1));
        folds.toggle(0);
        assert!(folds.is_hidden(1));
        assert!(folds.is_hidden(2));
        assert!(!folds.is_hidden(4));
        assert_eq!(folds.next_visible(0, 5, true), 4);
    }

    #[test]
    fn brace_block_folds() {
        let text = "if x {\n  y();\n}\nplain";
        let mut folds = Folds::default();
        folds.recompute(&lines(text), 2, true);
        assert!(folds.fold_at(0));
    }

    #[test]
    fn disabled_clears() {
        let mut folds = Folds::default();
        folds.recompute(&lines("a {\n b\n}"), 4, false);
        assert!(folds.ranges.is_empty());
    }
}

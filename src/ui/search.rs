//! 全局搜索：在窗格的回看缓冲 + 当前屏幕中查找文本。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MatchHit {
    /// 绝对行号：0..history_len 为回看缓冲，之后为屏幕行。
    pub row: usize,
    pub col: usize,
    pub len: usize,
}

#[derive(Debug, Default)]
pub struct SearchState {
    pub query: String,
    pub matches: Vec<MatchHit>,
    pub current: usize,
}

impl SearchState {
    pub fn new() -> SearchState {
        SearchState::default()
    }

    pub fn next_match(&mut self) {
        if self.matches.is_empty() {
            return;
        }
        self.current = (self.current + 1) % self.matches.len();
    }

    pub fn prev_match(&mut self) {
        if self.matches.is_empty() {
            return;
        }
        self.current = if self.current == 0 {
            self.matches.len() - 1
        } else {
            self.current - 1
        };
    }

    pub fn current_hit(&self) -> Option<MatchHit> {
        self.matches.get(self.current).copied()
    }
}

/// 在给定行序列中查找（大小写不敏感）。
pub fn find_matches(rows: &[Vec<char>], query: &str) -> Vec<MatchHit> {
    let needle: Vec<char> = query.to_lowercase().chars().collect();
    let mut hits = Vec::new();
    if needle.is_empty() {
        return hits;
    }
    for (row_index, row) in rows.iter().enumerate() {
        let hay: Vec<char> = row.iter().map(|c| c.to_ascii_lowercase()).collect();
        let mut i = 0;
        while i + needle.len() <= hay.len() {
            if hay[i..i + needle.len()] == needle[..] {
                hits.push(MatchHit {
                    row: row_index,
                    col: i,
                    len: needle.len(),
                });
                i += needle.len();
            } else {
                i += 1;
            }
        }
    }
    hits
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(text: &str) -> Vec<char> {
        text.chars().collect()
    }

    #[test]
    fn finds_all_occurrences() {
        let rows = vec![row("foo bar foo"), row("nothing"), row("FOO")];
        let hits = find_matches(&rows, "foo");
        assert_eq!(hits.len(), 3);
        assert_eq!(hits[0], MatchHit { row: 0, col: 0, len: 3 });
        assert_eq!(hits[1], MatchHit { row: 0, col: 8, len: 3 });
        assert_eq!(hits[2], MatchHit { row: 2, col: 0, len: 3 });
    }

    #[test]
    fn navigation_wraps() {
        let mut state = SearchState::new();
        state.matches = find_matches(&[row("a"), row("a")], "a");
        assert_eq!(state.current, 0);
        state.next_match();
        assert_eq!(state.current, 1);
        state.next_match();
        assert_eq!(state.current, 0);
        state.prev_match();
        assert_eq!(state.current, 1);
    }

    #[test]
    fn empty_query_matches_nothing() {
        assert!(find_matches(&[row("abc")], "").is_empty());
    }
}

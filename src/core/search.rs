//! 查找与替换：字面量 / 正则、大小写、全词匹配、跨行扫描。
//!
//! 单行内一次收集字符并复用（`find_all_in_line` / `replace_in_line`），
//! 避免对每个匹配重复分配；正则捕获组可用于替换串的 `$1` 引用。

use super::document::{Document, Pos};
use super::regex_lite::{Regex, RegexMatch};

#[derive(Clone, Copy, Debug, Default)]
pub struct SearchOptions {
    pub case_sensitive: bool,
    pub whole_word: bool,
    pub regex: bool,
}

#[derive(Clone, Debug)]
enum Matcher {
    Literal {
        needle: Vec<char>,
        needle_lower: Vec<char>,
        case_sensitive: bool,
    },
    Pattern(Regex),
}

/// 单行匹配结果：字符区间 + 捕获组区间（0 为整体匹配）。
#[derive(Clone, Debug)]
pub struct LineMatch {
    pub start: usize,
    pub end: usize,
    pub groups: Vec<Option<(usize, usize)>>,
}

#[derive(Clone)]
pub struct SearchEngine {
    pub query: String,
    pub options: SearchOptions,
    matcher: Option<Matcher>,
}

impl SearchEngine {
    pub fn new(query: &str, options: SearchOptions) -> SearchEngine {
        let matcher = build(query, options).ok();
        SearchEngine {
            query: query.to_string(),
            options,
            matcher,
        }
    }

    pub fn is_valid(&self) -> bool {
        self.matcher.is_some()
    }

    pub fn error(&self) -> Option<String> {
        build(&self.query, self.options).err()
    }

    /// 匹配必含的字面前缀（工程搜索的字节级预筛用）。
    pub fn prefilter_text(&self) -> Option<String> {
        match &self.matcher {
            Some(Matcher::Literal { needle, .. }) => {
                if needle.is_empty() {
                    None
                } else {
                    Some(needle.iter().collect())
                }
            }
            Some(Matcher::Pattern(regex)) => regex.prefix(),
            None => None,
        }
    }

    /// 在一行里找第一个匹配（字符区间）。
    pub fn find_in_line(&self, text: &str, from: usize) -> Option<(usize, usize)> {
        let chars: Vec<char> = text.chars().collect();
        self.find_in_chars(&chars, from)
    }

    /// 已收集字符数组时查找第一个匹配。
    pub fn find_in_chars(&self, chars: &[char], from: usize) -> Option<(usize, usize)> {
        let lowered = self.lowered(chars);
        self.find_in_chars_impl(chars, lowered.as_deref(), from)
            .map(|m| (m.start, m.end))
    }

    /// 一行内所有匹配（字符只收集一次，大小写折叠也只做一次）。
    pub fn find_all_in_line(&self, text: &str, limit: usize) -> Vec<(usize, usize)> {
        let chars: Vec<char> = text.chars().collect();
        self.find_all_in_chars(&chars, limit)
    }

    pub fn find_all_in_chars(&self, chars: &[char], limit: usize) -> Vec<(usize, usize)> {
        let lowered = self.lowered(chars);
        let mut out = Vec::new();
        let mut from = 0usize;
        while out.len() < limit {
            let Some(item) = self.find_in_chars_impl(chars, lowered.as_deref(), from) else {
                break;
            };
            out.push((item.start, item.end));
            from = if item.end > item.start {
                item.end
            } else {
                item.end + 1
            };
            if from > chars.len() {
                break;
            }
        }
        out
    }

    /// 在一行里找第一个匹配并返回捕获组区间。
    pub fn find_in_line_captures(&self, text: &str, from: usize) -> Option<LineMatch> {
        let chars: Vec<char> = text.chars().collect();
        let lowered = self.lowered(&chars);
        self.find_in_chars_impl(&chars, lowered.as_deref(), from)
    }

    /// 在整段文本（可含换行，支持跨行正则）里找第一个匹配。
    pub fn find_in_text_captures(&self, text: &str, from: usize) -> Option<LineMatch> {
        let chars: Vec<char> = text.chars().collect();
        self.find_in_chars_captures(&chars, from)
    }

    /// 已收集字符数组时做跨行匹配。
    ///
    /// 字面量模式每次调用都会重新折叠大小写，适合单次调用；
    /// 连续扫描请用 `find_all_in_text` / `replace_in_text`。
    pub fn find_in_chars_captures(&self, chars: &[char], from: usize) -> Option<LineMatch> {
        match &self.matcher {
            Some(Matcher::Pattern(regex)) => {
                let mut start = from;
                while start <= chars.len() {
                    let matched: RegexMatch = regex.captures_chars(chars, start)?;
                    if !self.options.whole_word
                        || word_bounded(chars, matched.start, matched.end)
                    {
                        return Some(LineMatch {
                            start: matched.start,
                            end: matched.end,
                            groups: matched.groups,
                        });
                    }
                    start = matched.start + 1;
                }
                None
            }
            Some(Matcher::Literal { .. }) => {
                let lowered = self.lowered(chars);
                self.find_in_chars_impl(chars, lowered.as_deref(), from)
            }
            None => None,
        }
    }

    /// 整段文本内的所有匹配（支持跨行，字符只收集一次）。
    pub fn find_all_in_text(&self, text: &str, limit: usize) -> Vec<(usize, usize)> {
        let chars: Vec<char> = text.chars().collect();
        self.find_all_spans(&chars, limit)
    }

    /// 已收集字符数组时查找所有匹配区间。
    pub fn find_all_spans(&self, chars: &[char], limit: usize) -> Vec<(usize, usize)> {
        let lowered = self.lowered(chars);
        let mut out = Vec::new();
        let mut from = 0usize;
        while out.len() < limit {
            let Some(item) = self.find_in_chars_impl(chars, lowered.as_deref(), from) else {
                break;
            };
            out.push((item.start, item.end));
            from = if item.end > item.start {
                item.end
            } else {
                item.end + 1
            };
            if from > chars.len() {
                break;
            }
        }
        out
    }

    /// 在一行内执行替换，返回（替换后的行, 替换次数）。
    pub fn replace_in_line(&self, line: &str, replacement: &str, limit: usize) -> (String, usize) {
        let chars: Vec<char> = line.chars().collect();
        self.replace_in_chars(&chars, replacement, limit)
    }

    /// 在整段文本内执行替换（支持跨行匹配），返回（新文本, 替换次数）。
    pub fn replace_in_text(&self, text: &str, replacement: &str, limit: usize) -> (String, usize) {
        let chars: Vec<char> = text.chars().collect();
        self.replace_in_chars(&chars, replacement, limit)
    }

    fn replace_in_chars(&self, chars: &[char], replacement: &str, limit: usize) -> (String, usize) {
        let lowered = self.lowered(chars);
        let mut out = String::with_capacity(chars.len() + 64);
        let mut last = 0usize;
        let mut from = 0usize;
        let mut count = 0usize;
        while count < limit {
            let Some(item) = self.find_in_chars_impl(chars, lowered.as_deref(), from) else {
                break;
            };
            out.extend(chars[last.min(chars.len())..item.start.min(chars.len())].iter());
            let groups = group_texts(chars, &item.groups);
            out.push_str(&expand_replacement(replacement, &groups));
            last = item.end;
            count += 1;
            from = if item.end > item.start {
                item.end
            } else {
                item.end + 1
            };
            if from > chars.len() {
                break;
            }
        }
        out.extend(chars[last.min(chars.len())..].iter());
        (out, count)
    }

    fn lowered(&self, chars: &[char]) -> Option<Vec<char>> {
        match &self.matcher {
            Some(Matcher::Literal {
                case_sensitive: false,
                ..
            }) => Some(
                chars
                    .iter()
                    .map(|c| c.to_lowercase().next().unwrap_or(*c))
                    .collect(),
            ),
            _ => None,
        }
    }

    fn find_in_chars_impl(
        &self,
        chars: &[char],
        lowered: Option<&[char]>,
        from: usize,
    ) -> Option<LineMatch> {
        let matcher = self.matcher.as_ref()?;
        match matcher {
            Matcher::Literal {
                needle,
                needle_lower,
                case_sensitive,
            } => {
                let (hay, pat) = if *case_sensitive {
                    (chars, needle.as_slice())
                } else {
                    match lowered {
                        Some(low) => (low, needle_lower.as_slice()),
                        None => (chars, needle.as_slice()),
                    }
                };
                if pat.is_empty() || from > hay.len() || pat.len() > hay.len() {
                    return None;
                }
                let mut i = from;
                while i + pat.len() <= hay.len() {
                    if hay[i] == pat[0] && &hay[i..i + pat.len()] == pat {
                        let end = i + pat.len();
                        if !self.options.whole_word || word_bounded(chars, i, end) {
                            return Some(LineMatch {
                                start: i,
                                end,
                                groups: vec![Some((i, end))],
                            });
                        }
                    }
                    i += 1;
                }
                None
            }
            Matcher::Pattern(regex) => {
                let mut start = from;
                while start <= chars.len() {
                    let matched: RegexMatch = regex.captures_chars(chars, start)?;
                    if !self.options.whole_word
                        || word_bounded(chars, matched.start, matched.end)
                    {
                        return Some(LineMatch {
                            start: matched.start,
                            end: matched.end,
                            groups: matched.groups,
                        });
                    }
                    start = matched.start + 1;
                }
                None
            }
        }
    }

    /// 扫描整个文档，返回所有匹配（限制数量避免卡死）。
    pub fn find_all(&self, doc: &Document) -> Vec<(Pos, Pos)> {
        self.find_all_limited(doc, 20000)
    }

    pub fn find_all_limited(&self, doc: &Document, limit: usize) -> Vec<(Pos, Pos)> {
        let mut results = Vec::new();
        if !self.is_valid() || self.query.is_empty() {
            return results;
        }
        for line in 0..doc.line_count() {
            let text = doc.line(line);
            for (start, end) in self.find_all_in_line(text, limit - results.len()) {
                results.push((Pos::new(line, start), Pos::new(line, end)));
                if results.len() >= limit {
                    return results;
                }
            }
        }
        results
    }

    /// 扫描整个文档，同时给出捕获组文本（`$1` 替换用）。
    pub fn find_all_with_groups(
        &self,
        doc: &Document,
        limit: usize,
    ) -> Vec<(Pos, Pos, Vec<Option<String>>)> {
        let mut results = Vec::new();
        if !self.is_valid() || self.query.is_empty() {
            return results;
        }
        for line in 0..doc.line_count() {
            let text = doc.line(line);
            let chars: Vec<char> = text.chars().collect();
            let lowered = self.lowered(&chars);
            let mut from = 0usize;
            while results.len() < limit {
                let Some(item) = self.find_in_chars_impl(&chars, lowered.as_deref(), from) else {
                    break;
                };
                results.push((
                    Pos::new(line, item.start),
                    Pos::new(line, item.end),
                    group_texts(&chars, &item.groups),
                ));
                from = if item.end > item.start {
                    item.end
                } else {
                    item.end + 1
                };
                if from > chars.len() {
                    break;
                }
            }
            if results.len() >= limit {
                break;
            }
        }
        results
    }

    /// 从 `from` 开始找下一个；到末尾后从头循环。
    pub fn next_match(&self, doc: &Document, from: Pos, wrap: bool) -> Option<(Pos, Pos)> {
        if doc.line_count() == 0 || !self.is_valid() || self.query.is_empty() {
            return None;
        }
        let start_line = from.line.min(doc.line_count() - 1);

        // 1) 当前行，从 from.col 开始
        if let Some((s, e)) = self.find_in_line(doc.line(start_line), from.col) {
            return Some((Pos::new(start_line, s), Pos::new(start_line, e)));
        }
        // 2) 后面的行
        for line in start_line + 1..doc.line_count() {
            if let Some((s, e)) = self.find_in_line(doc.line(line), 0) {
                return Some((Pos::new(line, s), Pos::new(line, e)));
            }
        }
        if !wrap {
            return None;
        }
        // 3) 回到开头
        for line in 0..=start_line {
            if let Some((s, e)) = self.find_in_line(doc.line(line), 0) {
                if line == start_line && s >= from.col {
                    return None;
                }
                return Some((Pos::new(line, s), Pos::new(line, e)));
            }
        }
        None
    }

    /// 从某个位置向前找（Shift+F3）。
    pub fn prev_match(&self, doc: &Document, from: Pos) -> Option<(Pos, Pos)> {
        let mut line = from.line.min(doc.line_count().saturating_sub(1));
        let mut limit = Some(from.col);
        loop {
            let text = doc.line(line);
            let mut found = None;
            let mut start = 0usize;
            while let Some((s, e)) = self.find_in_line(text, start) {
                if let Some(lim) = limit {
                    if e > lim || s >= lim {
                        break;
                    }
                }
                found = Some((s, e));
                start = if e > s { e } else { e + 1 };
            }
            if let Some((s, e)) = found {
                return Some((Pos::new(line, s), Pos::new(line, e)));
            }
            if line == 0 {
                return None;
            }
            line -= 1;
            limit = None;
        }
    }
}

fn word_bounded(chars: &[char], start: usize, end: usize) -> bool {
    let is_word = |c: char| c.is_alphanumeric() || c == '_';
    let before_ok = start == 0 || !is_word(chars[start - 1]);
    let after_ok = end >= chars.len() || !is_word(chars[end]);
    before_ok && after_ok
}

fn build(query: &str, options: SearchOptions) -> Result<Matcher, String> {
    if query.is_empty() {
        return Err("搜索内容为空".into());
    }
    if options.regex {
        Regex::with_options(query, !options.case_sensitive).map(Matcher::Pattern)
    } else {
        let needle: Vec<char> = query.chars().collect();
        let needle_lower = needle
            .iter()
            .map(|c| c.to_lowercase().next().unwrap_or(*c))
            .collect();
        Ok(Matcher::Literal {
            needle,
            needle_lower,
            case_sensitive: options.case_sensitive,
        })
    }
}

/// 把捕获组区间转换为文本（0 为整体匹配）。
pub fn group_texts(chars: &[char], groups: &[Option<(usize, usize)>]) -> Vec<Option<String>> {
    groups
        .iter()
        .map(|group| {
            group.map(|(start, end)| {
                chars[start.min(chars.len())..end.min(chars.len())]
                    .iter()
                    .collect()
            })
        })
        .collect()
}

/// 同上，输入为字符串。
pub fn group_texts_str(text: &str, groups: &[Option<(usize, usize)>]) -> Vec<Option<String>> {
    let chars: Vec<char> = text.chars().collect();
    group_texts(&chars, groups)
}

/// 展开替换串。
///
/// - `$1`..`$99`、`${1}`：捕获组；`$&`、`$0`、`${0}`：整体匹配
/// - `$$`：字面量 `$`
/// - `\n`、`\t`、`\r`、`\\`：换行、制表符、回车、反斜杠
pub fn expand_replacement(replacement: &str, groups: &[Option<String>]) -> String {
    let chars: Vec<char> = replacement.chars().collect();
    let mut out = String::with_capacity(replacement.len());
    let mut i = 0usize;
    while i < chars.len() {
        let ch = chars[i];
        if ch == '\\' {
            if let Some(next) = chars.get(i + 1).copied() {
                let translated = match next {
                    'n' => Some('\n'),
                    't' => Some('\t'),
                    'r' => Some('\r'),
                    '\\' => Some('\\'),
                    _ => None,
                };
                if let Some(value) = translated {
                    out.push(value);
                    i += 2;
                    continue;
                }
            }
            out.push('\\');
            i += 1;
            continue;
        }
        if ch == '$' {
            // $$ → 字面量 $
            if chars.get(i + 1) == Some(&'$') {
                out.push('$');
                i += 2;
                continue;
            }
            // ${n}
            if chars.get(i + 1) == Some(&'{') {
                if let Some(close) = chars[i + 2..].iter().position(|c| *c == '}') {
                    let digits: String = chars[i + 2..i + 2 + close].iter().collect();
                    if let Ok(index) = digits.parse::<usize>() {
                        if let Some(Some(text)) = groups.get(index) {
                            out.push_str(text);
                        }
                        i += close + 3;
                        continue;
                    }
                }
                out.push('$');
                i += 1;
                continue;
            }
            match chars.get(i + 1).copied() {
                Some('&') => {
                    if let Some(Some(text)) = groups.first() {
                        out.push_str(text);
                    }
                    i += 2;
                    continue;
                }
                Some(digit) if digit.is_ascii_digit() => {
                    let mut index = digit.to_digit(10).unwrap_or(0) as usize;
                    let mut consumed = 2usize;
                    if let Some(second) = chars.get(i + 2).and_then(|c| c.to_digit(10)) {
                        let two = index * 10 + second as usize;
                        if groups.get(two).map(|group| group.is_some()).unwrap_or(false) {
                            index = two;
                            consumed = 3;
                        }
                    }
                    if let Some(Some(text)) = groups.get(index) {
                        out.push_str(text);
                    }
                    i += consumed;
                    continue;
                }
                _ => {}
            }
        }
        out.push(ch);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(text: &str) -> Document {
        Document::from_text(text, None)
    }

    #[test]
    fn literal_case_and_word() {
        let engine = SearchEngine::new("hello", SearchOptions::default());
        let d = doc("Hello world\nsay hello");
        let all = engine.find_all(&d);
        assert_eq!(all.len(), 2);
        let engine = SearchEngine::new(
            "hello",
            SearchOptions {
                case_sensitive: true,
                ..Default::default()
            },
        );
        assert_eq!(engine.find_all(&d).len(), 1);
        let engine = SearchEngine::new(
            "hell",
            SearchOptions {
                whole_word: true,
                ..Default::default()
            },
        );
        assert!(engine.find_all(&d).is_empty());
    }

    #[test]
    fn regex_search() {
        let engine = SearchEngine::new(
            "h[a-z]+o",
            SearchOptions {
                regex: true,
                case_sensitive: false,
                whole_word: false,
            },
        );
        let d = doc("hello\nhi");
        let all = engine.find_all(&d);
        assert_eq!(all.len(), 1);
        assert_eq!(all[0], (Pos::new(0, 0), Pos::new(0, 5)));
    }

    #[test]
    fn next_and_prev_wrap() {
        let engine = SearchEngine::new("x", SearchOptions::default());
        let d = doc("x a x\nx");
        let first = engine.next_match(&d, Pos::new(0, 1), true).unwrap();
        assert_eq!(first.0, Pos::new(0, 4));
        let wrapped = engine.next_match(&d, Pos::new(1, 2), true).unwrap();
        assert_eq!(wrapped.0, Pos::new(0, 0));
        let prev = engine.prev_match(&d, Pos::new(1, 0)).unwrap();
        assert_eq!(prev.0, Pos::new(0, 4));
    }

    #[test]
    fn replacement_expansion() {
        assert_eq!(expand_replacement("[$&]", &[Some("abc".into())]), "[abc]");
        let groups = vec![
            Some("foo@bar".to_string()),
            Some("foo".to_string()),
            Some("bar".to_string()),
        ];
        assert_eq!(expand_replacement("$2.$1", &groups), "bar.foo");
        assert_eq!(expand_replacement("${2}${1}", &groups), "barfoo");
        assert_eq!(expand_replacement("$$1", &groups), "$1");
        assert_eq!(expand_replacement("a\\nb", &groups), "a\nb");
        // 不存在的组替换为空串
        assert_eq!(expand_replacement("$9", &groups), "");
    }

    #[test]
    fn regex_replace_with_groups() {
        let engine = SearchEngine::new(
            "(\\w+)@(\\w+)",
            SearchOptions {
                regex: true,
                case_sensitive: false,
                whole_word: false,
            },
        );
        let (text, count) = engine.replace_in_line("foo@bar baz@qux", "$2.$1", 10);
        assert_eq!(count, 2);
        assert_eq!(text, "bar.foo qux.baz");
        // 单行内多次匹配只扫描一遍
        assert_eq!(engine.find_all_in_line("a@b c@d e@f", 10).len(), 3);
    }

    #[test]
    fn cross_line_regex_replace() {
        let engine = SearchEngine::new(
            "foo\\nbar",
            SearchOptions {
                regex: true,
                case_sensitive: false,
                whole_word: false,
            },
        );
        assert_eq!(engine.find_all_in_text("a\nfoo\nbar\nz", 10).len(), 1);
        let (text, count) = engine.replace_in_text("a\nfoo\nbar\nz", "X", 10);
        assert_eq!(count, 1);
        assert_eq!(text, "a\nX\nz");
        // $1 跨行捕获（^ / $ 默认按多行语义）
        let engine = SearchEngine::new(
            "^(\\w+)$",
            SearchOptions {
                regex: true,
                ..Default::default()
            },
        );
        let (text, count) = engine.replace_in_text("a\nbb\nc", "[$1]", 10);
        assert_eq!(count, 3);
        assert_eq!(text, "[a]\n[bb]\n[c]");
    }

    #[test]
    fn prefilter_prefix() {
        let literal = SearchEngine::new("hello", SearchOptions::default());
        assert_eq!(literal.prefilter_text().as_deref(), Some("hello"));
        let regex = SearchEngine::new(
            "foo\\d+",
            SearchOptions {
                regex: true,
                ..Default::default()
            },
        );
        assert_eq!(regex.prefilter_text().as_deref(), Some("foo"));
    }
}

//! 迷你正则引擎：支持编辑器中常用的语法子集。
//!
//! 支持：字面量、`.`、`^`、`$`、`[a-z]`、`[^...]`、`\d \w \s` 及反义、
//! `*` `+` `?` `{n}` `{n,m}`、捕获组 `(...)`、非捕获组 `(?:...)`、选择 `|`、
//! 转义 `\.` 等；捕获组可按序号引用（`$1`）。大小写敏感可配置。

#[derive(Clone, Debug)]
struct Class {
    negated: bool,
    ranges: Vec<(char, char)>,
    builtins: Vec<char>,
}

impl Class {
    fn matches(&self, ch: char, ignore_case: bool) -> bool {
        let mut hit = self
            .ranges
            .iter()
            .any(|(a, b)| (*a <= ch && ch <= *b) || (ignore_case && lower(*a) <= lower(ch) && lower(ch) <= lower(*b)));
        if !hit {
            hit = self.builtins.iter().any(|kind| builtin_match(*kind, ch));
        }
        if self.negated {
            !hit
        } else {
            hit
        }
    }
}

fn lower(ch: char) -> char {
    ch.to_lowercase().next().unwrap_or(ch)
}

fn builtin_match(kind: char, ch: char) -> bool {
    match kind {
        'd' => ch.is_ascii_digit(),
        'w' => ch.is_alphanumeric() || ch == '_',
        's' => ch.is_whitespace(),
        'D' => !ch.is_ascii_digit(),
        'W' => !(ch.is_alphanumeric() || ch == '_'),
        'S' => !ch.is_whitespace(),
        _ => false,
    }
}

#[derive(Clone, Debug)]
enum Ast {
    Empty,
    Char(char),
    Any,
    Class(Class),
    Start,
    End,
    Concat(Vec<Ast>),
    Alt(Vec<Ast>),
    Repeat(Box<Ast>, usize, Option<usize>),
    /// 捕获组：括号序号（从 1 开始）与内部表达式。
    Group(usize, Box<Ast>),
}

/// 一次匹配结果：整体区间 + 各捕获组区间（0 为整体匹配）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RegexMatch {
    pub start: usize,
    pub end: usize,
    pub groups: Vec<Option<(usize, usize)>>,
}

/// 匹配过程中的候选状态（位置 + 已捕获的组区间）。
#[derive(Clone)]
struct State {
    pos: usize,
    caps: Vec<Option<(usize, usize)>>,
}

#[derive(Clone, Debug)]
pub struct Regex {
    ast: Ast,
    ignore_case: bool,
    group_count: usize,
    /// 表达式开头必含的连续字面量，用于上层做字节级预筛。
    prefix: Option<Vec<char>>,
}

impl Regex {
    pub fn new(pattern: &str) -> Result<Regex, String> {
        Regex::with_options(pattern, false)
    }

    pub fn with_options(pattern: &str, ignore_case: bool) -> Result<Regex, String> {
        let chars: Vec<char> = pattern.chars().collect();
        let mut parser = Parser {
            chars,
            pos: 0,
            ignore_case,
            groups: 0,
        };
        let ast = parser.parse_alt()?;
        if parser.pos < parser.chars.len() {
            return Err(format!(
                "正则表达式在位置 {} 处有多余字符 '{}'",
                parser.pos, parser.chars[parser.pos]
            ));
        }
        let prefix = literal_prefix(&ast);
        Ok(Regex {
            ast,
            ignore_case,
            group_count: parser.groups,
            prefix,
        })
    }

    /// 捕获组数量（不含整体匹配）。
    pub fn group_count(&self) -> usize {
        self.group_count
    }

    /// 表达式开头必含的连续字面量（大小写按 `ignore_case` 解释）。
    pub fn prefix(&self) -> Option<String> {
        self.prefix
            .as_ref()
            .map(|chars| chars.iter().collect::<String>())
    }

    /// 在字符数组里找第一个匹配，返回 (start, end)；`start` 为搜索起点。
    pub fn find_chars(&self, text: &[char], from: usize) -> Option<(usize, usize)> {
        self.captures_chars(text, from).map(|m| (m.start, m.end))
    }

    pub fn find(&self, text: &str, from: usize) -> Option<(usize, usize)> {
        let chars: Vec<char> = text.chars().collect();
        self.find_chars(&chars, from)
    }

    /// 找到第一个匹配并返回捕获组区间。
    pub fn captures(&self, text: &str, from: usize) -> Option<RegexMatch> {
        let chars: Vec<char> = text.chars().collect();
        self.captures_chars(&chars, from)
    }

    /// 在字符数组里找第一个匹配并返回捕获组区间。
    pub fn captures_chars(&self, text: &[char], from: usize) -> Option<RegexMatch> {
        let len = text.len();
        // 没有捕获组时用空 Vec，避免每个起始位置都分配。
        let empty_caps = self.group_count == 0;
        let mut start = from;
        while start <= len {
            let state = State {
                pos: start,
                caps: if empty_caps {
                    Vec::new()
                } else {
                    vec![None; self.group_count + 1]
                },
            };
            let mut ends = Vec::new();
            self.match_states(&self.ast, text, &state, &mut ends);
            if let Some(best) = ends.into_iter().max_by_key(|s| s.pos) {
                if best.pos >= start {
                    let mut groups = best.caps;
                    if empty_caps {
                        groups.push(Some((start, best.pos)));
                    } else {
                        groups[0] = Some((start, best.pos));
                    }
                    return Some(RegexMatch {
                        start,
                        end: best.pos,
                        groups,
                    });
                }
            }
            start += 1;
        }
        None
    }

    pub fn is_match(&self, text: &str) -> bool {
        self.captures(text, 0).is_some()
    }

    /// 从 `state` 出发匹配 `ast`，把所有可能的结束状态追加到 `out`。
    fn match_states(&self, ast: &Ast, text: &[char], state: &State, out: &mut Vec<State>) {
        match ast {
            Ast::Empty => out.push(state.clone()),
            Ast::Char(ch) => {
                if state.pos < text.len() && chars_equal(*ch, text[state.pos], self.ignore_case) {
                    let mut next = state.clone();
                    next.pos += 1;
                    out.push(next);
                }
            }
            Ast::Any => {
                if state.pos < text.len() && text[state.pos] != '\n' {
                    let mut next = state.clone();
                    next.pos += 1;
                    out.push(next);
                }
            }
            Ast::Class(class) => {
                if state.pos < text.len() && class.matches(text[state.pos], self.ignore_case) {
                    let mut next = state.clone();
                    next.pos += 1;
                    out.push(next);
                }
            }
            Ast::Start => {
                // 多行语义：行首或文本开头。
                if state.pos == 0 || text[state.pos - 1] == '\n' {
                    out.push(state.clone());
                }
            }
            Ast::End => {
                // 多行语义：行尾或文本结尾。
                if state.pos == text.len() || text[state.pos] == '\n' {
                    out.push(state.clone());
                }
            }
            Ast::Concat(parts) => {
                let mut current = vec![state.clone()];
                for part in parts {
                    let mut next = Vec::new();
                    for item in &current {
                        self.match_states(part, text, item, &mut next);
                    }
                    dedup_states(&mut next);
                    if next.is_empty() {
                        return;
                    }
                    current = next;
                }
                out.extend(current);
            }
            Ast::Alt(options) => {
                let mut all = Vec::new();
                for option in options {
                    self.match_states(option, text, state, &mut all);
                }
                dedup_states(&mut all);
                out.extend(all);
            }
            Ast::Repeat(node, min, max) => {
                // 逐层展开，收集满足最少次数后的所有结束状态。
                let limit = max.unwrap_or(text.len() + 1).min(text.len() + 1);
                let mut current = vec![state.clone()];
                let mut results = Vec::new();
                if *min == 0 {
                    results.push(state.clone());
                }
                for count in 1..=limit {
                    let mut next = Vec::new();
                    for item in &current {
                        self.match_states(node, text, item, &mut next);
                    }
                    // 去掉没有前进或已经出现过的位置，避免死循环。
                    next.retain(|s| {
                        s.pos > state.pos && !current.iter().any(|c| c.pos == s.pos)
                    });
                    dedup_states(&mut next);
                    if next.is_empty() {
                        break;
                    }
                    if count >= *min {
                        results.extend(next.iter().cloned());
                    }
                    current = next;
                }
                dedup_states(&mut results);
                out.extend(results);
            }
            Ast::Group(index, inner) => {
                let start = state.pos;
                let mut inner_states = Vec::new();
                self.match_states(inner, text, state, &mut inner_states);
                for mut item in inner_states {
                    item.caps[*index] = Some((start, item.pos));
                    out.push(item);
                }
            }
        }
    }
}

/// 按结束位置去重，保留最先探索到的状态（捕获组取该路径）。
fn dedup_states(states: &mut Vec<State>) {
    states.sort_by_key(|s| s.pos);
    states.dedup_by(|a, b| a.pos == b.pos);
}

/// 提取表达式开头必含的连续字面量（零宽断言不算消耗）。
fn literal_prefix(ast: &Ast) -> Option<Vec<char>> {
    fn walk(ast: &Ast, out: &mut Vec<char>) -> bool {
        match ast {
            Ast::Empty | Ast::Start | Ast::End => true,
            Ast::Char(ch) => {
                out.push(*ch);
                true
            }
            Ast::Concat(parts) => {
                for part in parts {
                    if !walk(part, out) {
                        return false;
                    }
                }
                true
            }
            _ => false,
        }
    }
    let mut out = Vec::new();
    // `walk` 返回 false 只表示后续原子不再是纯字面量，
    // 已经累积的前缀仍然是匹配必含的，可以继续用于预筛。
    walk(ast, &mut out);
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn chars_equal(a: char, b: char, ignore_case: bool) -> bool {
    if a == b {
        return true;
    }
    ignore_case && lower(a) == lower(b)
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
    ignore_case: bool,
    /// 已分配的捕获组序号（按 '(' 出现顺序递增）。
    groups: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn next(&mut self) -> Option<char> {
        let ch = self.peek();
        if ch.is_some() {
            self.pos += 1;
        }
        ch
    }

    fn parse_alt(&mut self) -> Result<Ast, String> {
        let mut options = vec![self.parse_concat()?];
        while self.peek() == Some('|') {
            self.next();
            options.push(self.parse_concat()?);
        }
        if options.len() == 1 {
            Ok(options.pop().unwrap())
        } else {
            Ok(Ast::Alt(options))
        }
    }

    fn parse_concat(&mut self) -> Result<Ast, String> {
        let mut parts = Vec::new();
        while let Some(ch) = self.peek() {
            if ch == ')' || ch == '|' {
                break;
            }
            let atom = self.parse_atom()?;
            let atom = self.parse_quantifier(atom)?;
            parts.push(atom);
        }
        if parts.is_empty() {
            Ok(Ast::Empty)
        } else if parts.len() == 1 {
            Ok(parts.pop().unwrap())
        } else {
            Ok(Ast::Concat(parts))
        }
    }

    fn parse_quantifier(&mut self, atom: Ast) -> Result<Ast, String> {
        match self.peek() {
            Some('*') => {
                self.next();
                Ok(Ast::Repeat(Box::new(atom), 0, None))
            }
            Some('+') => {
                self.next();
                Ok(Ast::Repeat(Box::new(atom), 1, None))
            }
            Some('?') => {
                self.next();
                Ok(Ast::Repeat(Box::new(atom), 0, Some(1)))
            }
            Some('{') => {
                let save = self.pos;
                self.next();
                let mut min_text = String::new();
                while let Some(ch) = self.peek() {
                    if ch.is_ascii_digit() {
                        min_text.push(ch);
                        self.next();
                    } else {
                        break;
                    }
                }
                if min_text.is_empty() {
                    self.pos = save;
                    return Ok(atom);
                }
                let min: usize = min_text.parse().map_err(|_| "重复次数无效".to_string())?;
                let max = if self.peek() == Some(',') {
                    self.next();
                    let mut max_text = String::new();
                    while let Some(ch) = self.peek() {
                        if ch.is_ascii_digit() {
                            max_text.push(ch);
                            self.next();
                        } else {
                            break;
                        }
                    }
                    if max_text.is_empty() {
                        None
                    } else {
                        Some(max_text.parse().map_err(|_| "重复次数无效".to_string())?)
                    }
                } else {
                    Some(min)
                };
                if self.peek() != Some('}') {
                    return Err("缺少 '}'".into());
                }
                self.next();
                if let Some(max) = max {
                    if max < min {
                        return Err("重复次数上限小于下限".into());
                    }
                }
                Ok(Ast::Repeat(Box::new(atom), min, max))
            }
            _ => Ok(atom),
        }
    }

    fn parse_atom(&mut self) -> Result<Ast, String> {
        match self.next() {
            Some('(') => {
                // 非捕获组 (?:...)
                let mut capturing = true;
                if self.peek() == Some('?') {
                    let save = self.pos;
                    self.next();
                    if self.peek() == Some(':') {
                        self.next();
                        capturing = false;
                    } else {
                        self.pos = save;
                    }
                }
                let index = if capturing {
                    self.groups += 1;
                    self.groups
                } else {
                    0
                };
                let inner = self.parse_alt()?;
                if self.next() != Some(')') {
                    return Err("缺少 ')'".into());
                }
                if capturing {
                    Ok(Ast::Group(index, Box::new(inner)))
                } else {
                    Ok(inner)
                }
            }
            Some('[') => self.parse_class(),
            Some('.') => Ok(Ast::Any),
            Some('^') => Ok(Ast::Start),
            Some('$') => Ok(Ast::End),
            Some('\\') => {
                let ch = self.next().ok_or_else(|| "转义符后缺少字符".to_string())?;
                Ok(match ch {
                    'd' | 'D' | 'w' | 'W' | 's' | 'S' => Ast::Class(Class {
                        negated: false,
                        ranges: Vec::new(),
                        builtins: vec![ch],
                    }),
                    'n' => Ast::Char('\n'),
                    't' => Ast::Char('\t'),
                    'r' => Ast::Char('\r'),
                    '0' => Ast::Char('\0'),
                    other => Ast::Char(other),
                })
            }
            Some(ch) => Ok(Ast::Char(ch)),
            None => Ok(Ast::Empty),
        }
    }

    fn parse_class(&mut self) -> Result<Ast, String> {
        let mut class = Class {
            negated: false,
            ranges: Vec::new(),
            builtins: Vec::new(),
        };
        if self.peek() == Some('^') {
            self.next();
            class.negated = true;
        }
        // 首个 ']' 按字面量处理
        let mut first = true;
        loop {
            let ch = match self.next() {
                Some(ch) => ch,
                None => return Err("字符类缺少 ']'".into()),
            };
            if ch == ']' && !first {
                break;
            }
            first = false;
            if ch == '\\' {
                let escaped = self.next().ok_or_else(|| "转义符后缺少字符".to_string())?;
                match escaped {
                    'd' | 'D' | 'w' | 'W' | 's' | 'S' => class.builtins.push(escaped),
                    'n' => class.ranges.push(('\n', '\n')),
                    't' => class.ranges.push(('\t', '\t')),
                    other => class.ranges.push((other, other)),
                }
                continue;
            }
            // 范围 a-z
            if self.peek() == Some('-') {
                let save = self.pos;
                self.next();
                if let Some(high) = self.peek() {
                    if high != ']' {
                        self.next();
                        let high = if high == '\\' {
                            self.next().ok_or_else(|| "范围转义无效".to_string())?
                        } else {
                            high
                        };
                        class.ranges.push((ch, high));
                        continue;
                    }
                }
                self.pos = save;
            }
            class.ranges.push((ch, ch));
        }
        Ok(Ast::Class(class))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn find(re: &str, text: &str) -> Option<(usize, usize)> {
        Regex::new(re).unwrap().find(text, 0)
    }

    #[test]
    fn literals_and_quantifiers() {
        assert_eq!(find("abc", "xxabcx"), Some((2, 5)));
        assert_eq!(find("a+", "aaa"), Some((0, 3)));
        assert_eq!(find("a*", "bbb"), Some((0, 0)));
        assert_eq!(find("ab?c", "ac"), Some((0, 2)));
        assert_eq!(find("a{2,3}", "aaaa"), Some((0, 3)));
    }

    #[test]
    fn classes_and_escapes() {
        assert_eq!(find("[a-c]+", "xxabc"), Some((2, 5)));
        assert_eq!(find("[^0-9]+", "12ab3"), Some((2, 4)));
        assert_eq!(find("\\d+", "ab123"), Some((2, 5)));
        assert_eq!(find("\\w+", "  hello_1 "), Some((2, 9)));
    }

    #[test]
    fn anchors_and_alternation() {
        assert_eq!(find("^abc", "xabc"), None);
        assert_eq!(find("^abc", "abcx"), Some((0, 3)));
        assert_eq!(find("abc$", "xabc"), Some((1, 4)));
        assert_eq!(find("cat|dog", "a dog"), Some((2, 5)));
    }

    #[test]
    fn groups_and_options() {
        assert_eq!(find("(ab)+", "ababx"), Some((0, 4)));
        assert_eq!(find("(?:ab)+c", "ababc"), Some((0, 5)));
        let re = Regex::with_options("hello", true).unwrap();
        assert_eq!(re.find("HeLLo", 0), Some((0, 5)));
    }

    #[test]
    fn capture_spans() {
        let re = Regex::new("(\\w+)@(\\w+)").unwrap();
        assert_eq!(re.group_count(), 2);
        let m = re.captures("mail: foo@bar", 0).unwrap();
        assert_eq!((m.start, m.end), (6, 13));
        assert_eq!(m.groups[0], Some((6, 13)));
        assert_eq!(m.groups[1], Some((6, 9)));
        assert_eq!(m.groups[2], Some((10, 13)));

        // 嵌套组 + 量词：取最后一轮迭代的捕获。
        let re = Regex::new("((a)(b))+").unwrap();
        assert_eq!(re.group_count(), 3);
        let m = re.captures("abab", 0).unwrap();
        assert_eq!(m.groups[1], Some((2, 4)));
        assert_eq!(m.groups[2], Some((2, 3)));
        assert_eq!(m.groups[3], Some((3, 4)));

        // 未参与匹配的可选组为 None。
        let re = Regex::new("(a)?b").unwrap();
        let m = re.captures("b", 0).unwrap();
        assert_eq!(m.groups[1], None);
    }

    #[test]
    fn literal_prefixes() {
        assert_eq!(Regex::new("abc").unwrap().prefix().as_deref(), Some("abc"));
        assert_eq!(Regex::new("^foo\\d+").unwrap().prefix().as_deref(), Some("foo"));
        assert_eq!(Regex::new("a|b").unwrap().prefix(), None);
        assert_eq!(Regex::new("\\d+x").unwrap().prefix(), None);
    }

    #[test]
    fn multiline_matching() {
        // 显式换行可跨行匹配
        let re = Regex::new("foo\\nbar").unwrap();
        let m = re.captures("x foo\nbar y", 0).unwrap();
        assert_eq!((m.start, m.end), (2, 9));
        // 多行语义：^ 匹配行首、$ 匹配行尾
        let re = Regex::new("^bar$").unwrap();
        let m = re.captures("foo\nbar\nbaz", 0).unwrap();
        assert_eq!((m.start, m.end), (4, 7));
        let re = Regex::new("^baz$").unwrap();
        assert_eq!(re.captures("foo\nbaz", 0).unwrap().start, 4);
    }

    #[test]
    fn invalid_patterns_report_error() {
        assert!(Regex::new("(abc").is_err());
        assert!(Regex::new("[abc").is_err());
        assert!(Regex::new("a{3,2}").is_err());
    }
}

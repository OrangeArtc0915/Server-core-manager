//! 语法高亮：自研轻量词法分析。
//!
//! 每行独立分析，跨行状态（块注释 / 三引号 / 代码块）由调用方缓存。
//! 返回的区间是「字符下标」（不是字节），与编辑器的列号一致。

use super::language::{CustomStyle, Language};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TokenKind {
    Keyword,
    Type,
    String,
    Number,
    Comment,
    Function,
    Macro,
    Operator,
    Property,
    Tag,
    Attribute,
    Heading,
    Link,
    Constant,
    Variable,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Token {
    pub start: usize,
    pub end: usize,
    pub kind: TokenKind,
}

impl Token {
    fn new(start: usize, end: usize, kind: TokenKind) -> Token {
        Token { start, end, kind }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum LexState {
    #[default]
    Normal,
    BlockComment,
    TripleSingle,
    TripleDouble,
    CodeFence,
}

/// 该语言的单行注释前缀（用于「切换行注释」）。
pub fn comment_prefix(lang: Language) -> &'static str {
    match lang {
        Language::Rust
        | Language::C
        | Language::Cpp
        | Language::CSharp
        | Language::Java
        | Language::Go
        | Language::JavaScript
        | Language::TypeScript
        | Language::Php => "//",
        Language::Python | Language::Shell | Language::Yaml | Language::Toml | Language::Makefile => "#",
        Language::Ini => ";",
        Language::Html | Language::Xml => "<!--",
        Language::Sql => "--",
        Language::Lua => "--",
        Language::PowerShell => "#",
        Language::Batch => "REM",
        Language::Css => "/*",
        Language::Markdown => "<!--",
        _ => "//",
    }
}

/// 分析一行，返回高亮区间并推进跨行状态。
pub fn highlight(lang: Language, text: &str, state: &mut LexState) -> Vec<Token> {
    match lang {
        Language::Rust
        | Language::C
        | Language::Cpp
        | Language::CSharp
        | Language::Java
        | Language::Go => c_like(lang, text, state),
        Language::JavaScript | Language::TypeScript => c_like(lang, text, state),
        Language::Php => c_like(lang, text, state),
        Language::Python => python(text, state),
        Language::Json => json(text, state),
        Language::Html | Language::Xml => markup(text, state),
        Language::Css => css(text, state),
        Language::Markdown => markdown(text, state),
        Language::Sql => sql(text, state),
        Language::Yaml => key_value(text, state, '#', true),
        Language::Toml => key_value(text, state, '#', false),
        Language::Ini => key_value(text, state, ';', false),
        Language::PowerShell => powershell(text, state),
        Language::Batch => batch(text, state),
        Language::Shell => shell(text, state),
        Language::Lua => lua(text, state),
        Language::Makefile => makefile(text, state),
        Language::Diff => diff(text),
        Language::Custom(_) => custom_lang(lang, text, state),
        Language::Plain => Vec::new(),
    }
}

fn chars(text: &str) -> Vec<char> {
    text.chars().collect()
}

/// 自定义语言：按配置的 style 选择高亮器。
fn custom_lang(lang: Language, text: &str, state: &mut LexState) -> Vec<Token> {
    match lang.custom_style() {
        Some(CustomStyle::Markup) => markup(text, state),
        Some(CustomStyle::Plain) => Vec::new(),
        Some(CustomStyle::Hash) => {
            let comment = lang.custom_comment().unwrap_or("#");
            generic_script(lang, text, comment)
        }
        _ => c_like(lang, text, state),
    }
}

/// 通用脚本语言高亮：单行注释 + 字符串 + 数字 + 关键字 / 类型 / 函数调用。
fn generic_script(lang: Language, text: &str, comment: &str) -> Vec<Token> {
    let cs = chars(text);
    let keywords = lang.keywords();
    let types = lang.types();
    let comment_chars: Vec<char> = comment.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0usize;
    while i < cs.len() {
        if !comment_chars.is_empty() && cs[i..].starts_with(&comment_chars) {
            push(&mut tokens, i, cs.len(), TokenKind::Comment);
            break;
        }
        let ch = cs[i];
        if ch == '"' || ch == '\'' {
            let end = scan_string(&cs, i, ch, true);
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if ch.is_ascii_digit() {
            let end = scan_number(&cs, i);
            push(&mut tokens, i, end, TokenKind::Number);
            i = end;
            continue;
        }
        if is_ident_start(ch) {
            let end = scan_ident(&cs, i);
            let word: String = cs[i..end].iter().collect();
            if contains_word(keywords, &word, true) {
                push(&mut tokens, i, end, TokenKind::Keyword);
            } else if contains_word(types, &word, true) {
                push(&mut tokens, i, end, TokenKind::Type);
            } else {
                let mut next = end;
                while next < cs.len() && cs[next].is_whitespace() {
                    next += 1;
                }
                if next < cs.len() && cs[next] == '(' {
                    push(&mut tokens, i, end, TokenKind::Function);
                }
            }
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn is_ident_start(ch: char) -> bool {
    ch.is_alphabetic() || ch == '_' || (!ch.is_ascii() && !ch.is_whitespace())
}

fn is_ident(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_'
}

fn scan_ident(cs: &[char], mut i: usize) -> usize {
    while i < cs.len() && is_ident(cs[i]) {
        i += 1;
    }
    i
}

fn scan_number(cs: &[char], mut i: usize) -> usize {
    // 0x / 0b / 0o 前缀、小数、指数、后缀
    if i + 1 < cs.len() && cs[i] == '0' && matches!(cs[i + 1], 'x' | 'X' | 'b' | 'B' | 'o' | 'O') {
        i += 2;
        while i < cs.len() && (cs[i].is_ascii_hexdigit() || cs[i] == '_') {
            i += 1;
        }
        return i;
    }
    let mut seen_dot = false;
    let mut seen_exp = false;
    while i < cs.len() {
        let ch = cs[i];
        if ch.is_ascii_digit() || ch == '_' {
            i += 1;
        } else if ch == '.' && !seen_dot && !seen_exp {
            // `1..2` 这种范围不当作小数
            if i + 1 < cs.len() && cs[i + 1] == '.' {
                break;
            }
            seen_dot = true;
            i += 1;
        } else if matches!(ch, 'e' | 'E') && !seen_exp {
            seen_exp = true;
            i += 1;
            if i < cs.len() && matches!(cs[i], '+' | '-') {
                i += 1;
            }
        } else if matches!(ch, 'f' | 'F' | 'd' | 'D' | 'u' | 'U' | 'l' | 'L' | 'i' | 'I' | 's' | 'S')
        {
            i += 1;
        } else {
            break;
        }
    }
    i
}

fn scan_string(cs: &[char], i: usize, quote: char, escapes: bool) -> usize {
    let mut j = i + 1;
    while j < cs.len() {
        if escapes && cs[j] == '\\' {
            j += 2;
            continue;
        }
        if cs[j] == quote {
            return j + 1;
        }
        j += 1;
    }
    cs.len()
}

fn contains_word(list: &[&str], word: &str, case_insensitive: bool) -> bool {
    if case_insensitive {
        let lower = word.to_ascii_lowercase();
        list.iter().any(|w| w.eq_ignore_ascii_case(&lower))
    } else {
        list.iter().any(|w| *w == word)
    }
}

fn push(tokens: &mut Vec<Token>, start: usize, end: usize, kind: TokenKind) {
    if end > start {
        tokens.push(Token::new(start, end, kind));
    }
}

fn c_like(lang: Language, text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let mut i = 0usize;

    if *state == LexState::BlockComment {
        let mut j = 0usize;
        while j + 1 < cs.len() {
            if cs[j] == '*' && cs[j + 1] == '/' {
                j += 2;
                push(&mut tokens, 0, j, TokenKind::Comment);
                *state = LexState::Normal;
                i = j;
                break;
            }
            j += 1;
        }
        if i == 0 {
            push(&mut tokens, 0, cs.len(), TokenKind::Comment);
            return tokens;
        }
    }

    let keywords = lang.keywords();
    let types = lang.types();

    while i < cs.len() {
        let ch = cs[i];
        if ch == '/' && i + 1 < cs.len() && cs[i + 1] == '/' {
            push(&mut tokens, i, cs.len(), TokenKind::Comment);
            break;
        }
        if ch == '/' && i + 1 < cs.len() && cs[i + 1] == '*' {
            let mut j = i + 2;
            let mut closed = false;
            while j + 1 < cs.len() {
                if cs[j] == '*' && cs[j + 1] == '/' {
                    j += 2;
                    closed = true;
                    break;
                }
                j += 1;
            }
            if !closed {
                j = cs.len();
                *state = LexState::BlockComment;
            }
            push(&mut tokens, i, j, TokenKind::Comment);
            i = j;
            continue;
        }
        if ch == '#' && matches!(lang, Language::C | Language::Cpp) {
            push(&mut tokens, i, cs.len(), TokenKind::Macro);
            break;
        }
        if ch == '#' && matches!(lang, Language::Rust) {
            // 属性 #[...] 与宏调用 foo!
            if i + 1 < cs.len() && cs[i + 1] == '[' {
                let mut depth = 0usize;
                let mut j = i;
                while j < cs.len() {
                    if cs[j] == '[' {
                        depth += 1;
                    } else if cs[j] == ']' {
                        depth -= 1;
                        if depth == 0 {
                            j += 1;
                            break;
                        }
                    }
                    j += 1;
                }
                push(&mut tokens, i, j, TokenKind::Attribute);
                i = j;
                continue;
            }
            i += 1;
            continue;
        }
        if ch == '@' && matches!(lang, Language::CSharp | Language::Java) {
            let end = scan_ident(&cs, i + 1);
            push(&mut tokens, i, end, TokenKind::Attribute);
            i = end;
            continue;
        }
        if ch == '"' || ch == '\'' {
            // Rust 单引号可能是生命周期：'a 后面没有闭合引号时按标识符处理
            if ch == '\'' && lang == Language::Rust {
                let mut j = i + 1;
                let mut closed = false;
                while j < cs.len() && j < i + 12 {
                    if cs[j] == '\'' {
                        closed = true;
                        break;
                    }
                    if cs[j] == '\n' || !is_ident(cs[j]) {
                        break;
                    }
                    j += 1;
                }
                if !closed {
                    i += 1;
                    continue;
                }
            }
            let end = scan_string(&cs, i, ch, true);
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if ch == '`' && matches!(lang, Language::JavaScript | Language::TypeScript) {
            let end = scan_string(&cs, i, '`', true);
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if ch.is_ascii_digit() {
            let end = scan_number(&cs, i);
            push(&mut tokens, i, end, TokenKind::Number);
            i = end;
            continue;
        }
        if is_ident_start(ch) {
            let end = scan_ident(&cs, i);
            let word: String = cs[i..end].iter().collect();
            let kind = if contains_word(keywords, &word, false) {
                TokenKind::Keyword
            } else if contains_word(types, &word, false) {
                TokenKind::Type
            } else if matches!(word.as_str(), "true" | "false" | "null" | "None" | "nil" | "NULL") {
                TokenKind::Constant
            } else {
                // 后面紧跟 ( 视为函数调用
                let mut j = end;
                while j < cs.len() && (cs[j] == ' ' || cs[j] == '\t') {
                    j += 1;
                }
                if j < cs.len() && cs[j] == '(' {
                    TokenKind::Function
                } else {
                    i = end;
                    continue;
                }
            };
            push(&mut tokens, i, end, kind);
            i = end;
            continue;
        }
        if matches!(
            ch,
            '+' | '-' | '*' | '/' | '%' | '=' | '<' | '>' | '!' | '&' | '|' | '^' | '~' | '?'
        ) {
            let start = i;
            while i < cs.len()
                && matches!(
                    cs[i],
                    '+' | '-' | '*' | '/' | '%' | '=' | '<' | '>' | '!' | '&' | '|' | '^' | '~'
                        | '?'
                )
            {
                i += 1;
            }
            push(&mut tokens, start, i, TokenKind::Operator);
            continue;
        }
        i += 1;
    }
    tokens
}

fn python(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let mut i = 0usize;

    match *state {
        LexState::TripleSingle | LexState::TripleDouble => {
            let quote = if *state == LexState::TripleSingle {
                '\''
            } else {
                '"'
            };
            let mut j = 0usize;
            while j + 2 < cs.len() {
                if cs[j] == quote && cs[j + 1] == quote && cs[j + 2] == quote {
                    j += 3;
                    push(&mut tokens, 0, j, TokenKind::String);
                    *state = LexState::Normal;
                    i = j;
                    break;
                }
                j += 1;
            }
            if i == 0 {
                push(&mut tokens, 0, cs.len(), TokenKind::String);
                return tokens;
            }
        }
        _ => {}
    }

    let keywords = Language::Python.keywords();
    while i < cs.len() {
        let ch = cs[i];
        if ch == '#' {
            push(&mut tokens, i, cs.len(), TokenKind::Comment);
            break;
        }
        if ch == '"' || ch == '\'' {
            let triple = i + 2 < cs.len() && cs[i + 1] == ch && cs[i + 2] == ch;
            if triple {
                let mut j = i + 3;
                let mut closed = false;
                while j + 2 < cs.len() {
                    if cs[j] == ch && cs[j + 1] == ch && cs[j + 2] == ch {
                        j += 3;
                        closed = true;
                        break;
                    }
                    j += 1;
                }
                if !closed {
                    j = cs.len();
                    *state = if ch == '"' {
                        LexState::TripleDouble
                    } else {
                        LexState::TripleSingle
                    };
                }
                push(&mut tokens, i, j, TokenKind::String);
                i = j;
            } else {
                let end = scan_string(&cs, i, ch, true);
                push(&mut tokens, i, end, TokenKind::String);
                i = end;
            }
            continue;
        }
        if ch == '@' {
            let end = scan_ident(&cs, i + 1);
            push(&mut tokens, i, end, TokenKind::Attribute);
            i = end;
            continue;
        }
        if ch.is_ascii_digit() {
            let end = scan_number(&cs, i);
            push(&mut tokens, i, end, TokenKind::Number);
            i = end;
            continue;
        }
        if is_ident_start(ch) {
            let end = scan_ident(&cs, i);
            let word: String = cs[i..end].iter().collect();
            let kind = if contains_word(keywords, &word, false) {
                TokenKind::Keyword
            } else if matches!(word.as_str(), "True" | "False" | "None") {
                TokenKind::Constant
            } else if matches!(word.as_str(), "def" | "class") {
                TokenKind::Keyword
            } else {
                let mut j = end;
                while j < cs.len() && (cs[j] == ' ' || cs[j] == '\t') {
                    j += 1;
                }
                if j < cs.len() && cs[j] == '(' {
                    TokenKind::Function
                } else {
                    i = end;
                    continue;
                }
            };
            push(&mut tokens, i, end, kind);
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn json(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let mut i = 0usize;
    // JSON 没有跨行状态；简单处理字符串与数字。
    let _ = state;
    while i < cs.len() {
        let ch = cs[i];
        if ch == '"' {
            let end = scan_string(&cs, i, '"', true);
            // 后面紧跟冒号则是键名
            let mut j = end;
            while j < cs.len() && cs[j].is_whitespace() {
                j += 1;
            }
            let kind = if j < cs.len() && cs[j] == ':' {
                TokenKind::Property
            } else {
                TokenKind::String
            };
            push(&mut tokens, i, end, kind);
            i = end;
            continue;
        }
        if ch.is_ascii_digit() || (ch == '-' && i + 1 < cs.len() && cs[i + 1].is_ascii_digit()) {
            let end = scan_number(&cs, i + usize::from(ch == '-'));
            push(&mut tokens, i, end, TokenKind::Number);
            i = end;
            continue;
        }
        if is_ident_start(ch) {
            let end = scan_ident(&cs, i);
            let word: String = cs[i..end].iter().collect();
            if matches!(word.as_str(), "true" | "false" | "null") {
                push(&mut tokens, i, end, TokenKind::Constant);
            }
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn markup(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let mut i = 0usize;

    if *state == LexState::BlockComment {
        let mut j = 0usize;
        while j + 2 < cs.len() {
            if cs[j] == '-' && cs[j + 1] == '-' && cs[j + 2] == '>' {
                j += 3;
                push(&mut tokens, 0, j, TokenKind::Comment);
                *state = LexState::Normal;
                i = j;
                break;
            }
            j += 1;
        }
        if i == 0 {
            push(&mut tokens, 0, cs.len(), TokenKind::Comment);
            return tokens;
        }
    }

    while i < cs.len() {
        if cs[i] == '<' && i + 3 < cs.len() && cs[i + 1] == '!' && cs[i + 2] == '-' && cs[i + 3] == '-'
        {
            let mut j = i + 4;
            let mut closed = false;
            while j + 2 < cs.len() {
                if cs[j] == '-' && cs[j + 1] == '-' && cs[j + 2] == '>' {
                    j += 3;
                    closed = true;
                    break;
                }
                j += 1;
            }
            if !closed {
                j = cs.len();
                *state = LexState::BlockComment;
            }
            push(&mut tokens, i, j, TokenKind::Comment);
            i = j;
            continue;
        }
        if cs[i] == '<' {
            let start = i;
            let mut j = i + 1;
            let closing = j < cs.len() && cs[j] == '/';
            if closing {
                j += 1;
            }
            push(&mut tokens, start, j, TokenKind::Operator);
            let name_start = j;
            while j < cs.len() && (cs[j].is_alphanumeric() || cs[j] == '-' || cs[j] == ':' || cs[j] == '_') {
                j += 1;
            }
            if j == name_start && !(j < cs.len() && matches!(cs[j], '!' | '?')) {
                i += 1;
                continue;
            }
            push(&mut tokens, name_start, j, TokenKind::Tag);
            // 属性
            while j < cs.len() && cs[j] != '>' {
                if cs[j] == '"' || cs[j] == '\'' {
                    let end = scan_string(&cs, j, cs[j], true);
                    push(&mut tokens, j, end, TokenKind::String);
                    j = end;
                    continue;
                }
                if is_ident_start(cs[j]) {
                    let attr_start = j;
                    j = scan_ident(&cs, j);
                    push(&mut tokens, attr_start, j, TokenKind::Attribute);
                    continue;
                }
                j += 1;
            }
            if j < cs.len() {
                push(&mut tokens, j, j + 1, TokenKind::Operator);
                j += 1;
            }
            i = j;
            continue;
        }
        if cs[i] == '&' {
            let mut j = i + 1;
            while j < cs.len() && cs[j] != ';' && j < i + 12 {
                j += 1;
            }
            if j < cs.len() && cs[j] == ';' {
                push(&mut tokens, i, j + 1, TokenKind::Constant);
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    tokens
}

fn css(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let mut i = 0usize;
    let _ = state;
    while i < cs.len() {
        let ch = cs[i];
        if ch == '/' && i + 1 < cs.len() && cs[i + 1] == '*' {
            let mut j = i + 2;
            while j + 1 < cs.len() && !(cs[j] == '*' && cs[j + 1] == '/') {
                j += 1;
            }
            j = (j + 2).min(cs.len());
            push(&mut tokens, i, j, TokenKind::Comment);
            i = j;
            continue;
        }
        if ch == '"' || ch == '\'' {
            let end = scan_string(&cs, i, ch, true);
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if ch == '@' {
            let end = scan_ident(&cs, i + 1);
            push(&mut tokens, i, end, TokenKind::Keyword);
            i = end;
            continue;
        }
        if ch == '#' {
            let end = scan_ident(&cs, i + 1);
            push(&mut tokens, i, end.max(i + 1), TokenKind::Number);
            i = end.max(i + 1);
            continue;
        }
        if ch.is_ascii_digit() {
            let end = scan_number(&cs, i);
            push(&mut tokens, i, end, TokenKind::Number);
            i = end;
            continue;
        }
        if is_ident_start(ch) {
            let end = scan_ident(&cs, i);
            let mut j = end;
            while j < cs.len() && cs[j].is_whitespace() {
                j += 1;
            }
            if j < cs.len() && cs[j] == ':' {
                push(&mut tokens, i, end, TokenKind::Property);
            } else {
                push(&mut tokens, i, end, TokenKind::Tag);
            }
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn markdown(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let trimmed: String = cs.iter().collect::<String>();

    if *state == LexState::CodeFence {
        if trimmed.trim_start().starts_with("```") {
            *state = LexState::Normal;
        }
        push(&mut tokens, 0, cs.len(), TokenKind::String);
        return tokens;
    }
    if trimmed.trim_start().starts_with("```") || trimmed.trim_start().starts_with("~~~") {
        *state = LexState::CodeFence;
        push(&mut tokens, 0, cs.len(), TokenKind::String);
        return tokens;
    }

    if trimmed.starts_with('#') {
        push(&mut tokens, 0, cs.len(), TokenKind::Heading);
        return tokens;
    }
    if trimmed.starts_with('>') {
        push(&mut tokens, 0, cs.len(), TokenKind::Comment);
        return tokens;
    }

    let mut i = 0usize;
    if trimmed.starts_with("- ") || trimmed.starts_with("* ") || trimmed.starts_with("+ ") {
        push(&mut tokens, 0, 2, TokenKind::Operator);
        i = 2;
    } else {
        // 有序列表 1.
        let mut j = 0usize;
        while j < cs.len() && cs[j].is_ascii_digit() {
            j += 1;
        }
        if j > 0 && j + 1 < cs.len() && cs[j] == '.' && cs[j + 1] == ' ' {
            push(&mut tokens, 0, j + 2, TokenKind::Operator);
            i = j + 2;
        }
    }

    while i < cs.len() {
        if cs[i] == '`' {
            let mut j = i + 1;
            while j < cs.len() && cs[j] != '`' {
                j += 1;
            }
            let end = (j + 1).min(cs.len());
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if cs[i] == '[' {
            // [文字](链接)
            let mut j = i + 1;
            while j < cs.len() && cs[j] != ']' {
                j += 1;
            }
            if j + 1 < cs.len() && cs[j + 1] == '(' {
                let mut k = j + 2;
                while k < cs.len() && cs[k] != ')' {
                    k += 1;
                }
                push(&mut tokens, i, (k + 1).min(cs.len()), TokenKind::Link);
                i = (k + 1).min(cs.len());
                continue;
            }
        }
        if (cs[i] == '*' || cs[i] == '_') && i + 1 < cs.len() {
            // 简单粗体 / 斜体标记
            let marker = cs[i];
            let mut j = i + 1;
            while j < cs.len() && cs[j] != marker {
                j += 1;
            }
            if j < cs.len() && j > i + 1 {
                push(&mut tokens, i, j + 1, TokenKind::Type);
                i = j + 1;
                continue;
            }
        }
        if cs[i] == '<' {
            let mut j = i + 1;
            while j < cs.len() && cs[j] != '>' {
                j += 1;
            }
            if j < cs.len() {
                push(&mut tokens, i, j + 1, TokenKind::Tag);
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    tokens
}

fn sql(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let mut i = 0usize;
    let _ = state;
    let keywords = Language::Sql.keywords();
    while i < cs.len() {
        let ch = cs[i];
        if ch == '-' && i + 1 < cs.len() && cs[i + 1] == '-' {
            push(&mut tokens, i, cs.len(), TokenKind::Comment);
            break;
        }
        if ch == '/' && i + 1 < cs.len() && cs[i + 1] == '*' {
            let mut j = i + 2;
            while j + 1 < cs.len() && !(cs[j] == '*' && cs[j + 1] == '/') {
                j += 1;
            }
            j = (j + 2).min(cs.len());
            push(&mut tokens, i, j, TokenKind::Comment);
            i = j;
            continue;
        }
        if ch == '\'' {
            let end = scan_string(&cs, i, '\'', true);
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if ch.is_ascii_digit() {
            let end = scan_number(&cs, i);
            push(&mut tokens, i, end, TokenKind::Number);
            i = end;
            continue;
        }
        if is_ident_start(ch) {
            let end = scan_ident(&cs, i);
            let word: String = cs[i..end].iter().collect();
            if contains_word(keywords, &word, true) {
                push(&mut tokens, i, end, TokenKind::Keyword);
            } else if contains_word(Language::Sql.types(), &word, true) {
                push(&mut tokens, i, end, TokenKind::Type);
            }
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn key_value(text: &str, state: &mut LexState, comment: char, allow_bare: bool) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let _ = state;
    let trimmed = text.trim_start();
    if trimmed.starts_with(comment) {
        push(&mut tokens, 0, cs.len(), TokenKind::Comment);
        return tokens;
    }
    let mut i = 0usize;
    // 段名 [section]
    if trimmed.starts_with('[') {
        let end = text.find(']').map(|b| text[..=b].chars().count()).unwrap_or(cs.len());
        push(&mut tokens, 0, end, TokenKind::Tag);
        return tokens;
    }
    while i < cs.len() {
        let ch = cs[i];
        if ch == comment {
            push(&mut tokens, i, cs.len(), TokenKind::Comment);
            break;
        }
        if ch == '"' || ch == '\'' {
            let end = scan_string(&cs, i, ch, true);
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if ch == ':' || ch == '=' {
            // 分隔符前的部分标为键
            let start = tokens.last().map(|t| t.end).unwrap_or(0);
            if start < i {
                push(&mut tokens, start, i, TokenKind::Property);
            }
            push(&mut tokens, i, i + 1, TokenKind::Operator);
            i += 1;
            continue;
        }
        i += 1;
    }
    if allow_bare {
        // YAML 值里的 true/false/null
        for word in ["true", "false", "null"] {
            if let Some(byte) = text.find(word) {
                let start = text[..byte].chars().count();
                push(&mut tokens, start, start + word.chars().count(), TokenKind::Constant);
            }
        }
    }
    tokens
}

fn powershell(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let _ = state;
    let mut i = 0usize;
    while i < cs.len() {
        if cs[i] == '#' {
            push(&mut tokens, i, cs.len(), TokenKind::Comment);
            break;
        }
        if cs[i] == '<' && i + 1 < cs.len() && cs[i + 1] == '#' {
            let mut j = i + 2;
            while j + 1 < cs.len() && !(cs[j] == '#' && cs[j + 1] == '>') {
                j += 1;
            }
            j = (j + 2).min(cs.len());
            push(&mut tokens, i, j, TokenKind::Comment);
            i = j;
            continue;
        }
        if cs[i] == '"' || cs[i] == '\'' {
            let end = scan_string(&cs, i, cs[i], true);
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if cs[i] == '$' {
            let end = scan_ident(&cs, i + 1);
            push(&mut tokens, i, end, TokenKind::Variable);
            i = end;
            continue;
        }
        if cs[i].is_ascii_digit() {
            let end = scan_number(&cs, i);
            push(&mut tokens, i, end, TokenKind::Number);
            i = end;
            continue;
        }
        if is_ident_start(cs[i]) || cs[i] == '-' {
            let end = scan_ident(&cs, i + usize::from(cs[i] == '-'));
            let word: String = cs[i..end].iter().collect();
            if contains_word(Language::PowerShell.keywords(), &word, true) {
                push(&mut tokens, i, end, TokenKind::Keyword);
            } else if word.contains('-') {
                push(&mut tokens, i, end, TokenKind::Function);
            }
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn batch(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let _ = state;
    let trimmed = text.trim_start().to_ascii_lowercase();
    if trimmed.starts_with("rem ") || trimmed == "rem" || trimmed.starts_with("::") {
        push(&mut tokens, 0, cs.len(), TokenKind::Comment);
        return tokens;
    }
    let mut i = 0usize;
    while i < cs.len() {
        if cs[i] == '%' {
            let mut j = i + 1;
            while j < cs.len() && cs[j] != '%' {
                j += 1;
            }
            let end = (j + 1).min(cs.len());
            push(&mut tokens, i, end, TokenKind::Variable);
            i = end;
            continue;
        }
        if cs[i] == '"' {
            let end = scan_string(&cs, i, '"', false);
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if is_ident_start(cs[i]) {
            let end = scan_ident(&cs, i);
            let word: String = cs[i..end].iter().collect();
            if contains_word(Language::Batch.keywords(), &word, true) {
                push(&mut tokens, i, end, TokenKind::Keyword);
            }
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn shell(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let _ = state;
    let mut i = 0usize;
    while i < cs.len() {
        if cs[i] == '#' {
            push(&mut tokens, i, cs.len(), TokenKind::Comment);
            break;
        }
        if cs[i] == '"' || cs[i] == '\'' {
            let end = scan_string(&cs, i, cs[i], cs[i] == '"');
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if cs[i] == '$' {
            let end = scan_ident(&cs, i + 1);
            push(&mut tokens, i, end, TokenKind::Variable);
            i = end;
            continue;
        }
        if is_ident_start(cs[i]) {
            let end = scan_ident(&cs, i);
            let word: String = cs[i..end].iter().collect();
            if contains_word(Language::Shell.keywords(), &word, false) {
                push(&mut tokens, i, end, TokenKind::Keyword);
            } else if word.starts_with('-') {
                push(&mut tokens, i, end, TokenKind::Attribute);
            }
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn lua(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let _ = state;
    let mut i = 0usize;
    while i < cs.len() {
        if cs[i] == '-' && i + 1 < cs.len() && cs[i + 1] == '-' {
            push(&mut tokens, i, cs.len(), TokenKind::Comment);
            break;
        }
        if cs[i] == '"' || cs[i] == '\'' {
            let end = scan_string(&cs, i, cs[i], true);
            push(&mut tokens, i, end, TokenKind::String);
            i = end;
            continue;
        }
        if cs[i].is_ascii_digit() {
            let end = scan_number(&cs, i);
            push(&mut tokens, i, end, TokenKind::Number);
            i = end;
            continue;
        }
        if is_ident_start(cs[i]) {
            let end = scan_ident(&cs, i);
            let word: String = cs[i..end].iter().collect();
            if contains_word(Language::Lua.keywords(), &word, false) {
                push(&mut tokens, i, end, TokenKind::Keyword);
            }
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn makefile(text: &str, state: &mut LexState) -> Vec<Token> {
    let cs = chars(text);
    let mut tokens = Vec::new();
    let _ = state;
    if text.trim_start().starts_with('#') {
        push(&mut tokens, 0, cs.len(), TokenKind::Comment);
        return tokens;
    }
    if text.starts_with('\t') {
        push(&mut tokens, 0, cs.len(), TokenKind::String);
        return tokens;
    }
    let mut i = 0usize;
    while i < cs.len() {
        if cs[i] == '$' && i + 1 < cs.len() && (cs[i + 1] == '(' || cs[i + 1] == '{') {
            let close = if cs[i + 1] == '(' { ')' } else { '}' };
            let mut j = i + 2;
            while j < cs.len() && cs[j] != close {
                j += 1;
            }
            let end = (j + 1).min(cs.len());
            push(&mut tokens, i, end, TokenKind::Variable);
            i = end;
            continue;
        }
        if cs[i] == '#' {
            push(&mut tokens, i, cs.len(), TokenKind::Comment);
            break;
        }
        if cs[i] == ':' {
            push(&mut tokens, 0, i, TokenKind::Function);
            i += 1;
            continue;
        }
        i += 1;
    }
    tokens
}

fn diff(text: &str) -> Vec<Token> {
    let count = text.chars().count();
    if text.starts_with("+++") || text.starts_with("---") {
        return vec![Token::new(0, count, TokenKind::Attribute)];
    }
    if text.starts_with('+') {
        return vec![Token::new(0, count, TokenKind::String)];
    }
    if text.starts_with('-') {
        return vec![Token::new(0, count, TokenKind::Comment)];
    }
    if text.starts_with('@') {
        return vec![Token::new(0, count, TokenKind::Keyword)];
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rust_keywords_and_strings() {
        let mut state = LexState::Normal;
        let tokens = highlight(Language::Rust, "fn main() { let s = \"hi\"; }", &mut state);
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Keyword));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::String));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Function));
    }

    #[test]
    fn block_comment_spans_lines() {
        let mut state = LexState::Normal;
        let first = highlight(Language::C, "int x; /* start", &mut state);
        assert_eq!(state, LexState::BlockComment);
        assert!(first.iter().any(|t| t.kind == TokenKind::Comment));
        let second = highlight(Language::C, "still comment */ int y;", &mut state);
        assert_eq!(state, LexState::Normal);
        assert!(second.iter().any(|t| t.kind == TokenKind::Keyword));
    }

    #[test]
    fn python_triple_quote_spans_lines() {
        let mut state = LexState::Normal;
        highlight(Language::Python, "x = \"\"\"start", &mut state);
        assert_eq!(state, LexState::TripleDouble);
        highlight(Language::Python, "end\"\"\"", &mut state);
        assert_eq!(state, LexState::Normal);
    }

    #[test]
    fn markup_tags_and_attrs() {
        let mut state = LexState::Normal;
        let tokens = highlight(Language::Html, "<div class=\"a\">x</div>", &mut state);
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Tag));
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Attribute));
    }
}

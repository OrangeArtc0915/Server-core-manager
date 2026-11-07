//! `.sct` 脚本：逐行执行，空行与 `#` / `::` 开头的行为注释。
//!
//! 支持 cmd 批处理的核心控制流：`if` / `else`、`for`（普通、`/d`、`/r`、`/l`）、
//! `goto` 标签、`call :子程序`、`exit /b`；`run 脚本.sct 参数...` 里的参数可用
//! `%1`…`%9` 引用，`%*` 表示全部参数。
//!
//! 解析分两步：先把源码折成语句树（括号块在解析阶段展开），再按语句树执行。
//! 这样 `goto` 可以跳出 `if` / `for` 块，而 `call` 的返回位置不依赖行号。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::{builtins, exec, parse, Shell};

/// 过滤注释与空行，保留原始行号便于报错。
pub fn parse_script(text: &str) -> Vec<(usize, String)> {
    text.lines()
        .enumerate()
        .filter_map(|(index, line)| {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                None
            } else {
                Some((index + 1, trimmed.to_string()))
            }
        })
        .collect()
}

/// 把 `%1`…`%9`、`%*` 替换成脚本参数（其余 `%` 保持原样，交由命令行解析处理）。
pub fn substitute_args(line: &str, args: &[String]) -> String {
    let chars: Vec<char> = line.chars().collect();
    let mut out = String::with_capacity(line.len());
    let mut i = 0usize;
    while i < chars.len() {
        if chars[i] == '%' && i + 1 < chars.len() {
            match chars[i + 1] {
                '*' => {
                    out.push_str(&args.join(" "));
                    i += 2;
                    continue;
                }
                digit @ '0'..='9' => {
                    let index = (digit as u8 - b'0') as usize;
                    if index >= 1 {
                        if let Some(value) = args.get(index - 1) {
                            out.push_str(value);
                        }
                    }
                    i += 2;
                    continue;
                }
                _ => {}
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ForOption {
    Plain,
    Dirs,
    Recursive,
    Numeric,
}

#[derive(Debug, Clone)]
enum Stmt {
    Noop,
    Command {
        text: String,
        line: usize,
    },
    Label {
        name: String,
        line: usize,
    },
    Goto {
        target: String,
        line: usize,
    },
    Call {
        target: String,
        args: String,
        line: usize,
    },
    Return {
        code: Option<String>,
        line: usize,
    },
    If {
        condition: String,
        then_body: Vec<Stmt>,
        else_body: Vec<Stmt>,
        line: usize,
    },
    For {
        option: ForOption,
        var: String,
        set: String,
        root: Option<String>,
        body: Vec<Stmt>,
        line: usize,
    },
}

impl Stmt {
    fn line(&self) -> usize {
        match self {
            Stmt::Noop => 0,
            Stmt::Command { line, .. }
            | Stmt::Label { line, .. }
            | Stmt::Goto { line, .. }
            | Stmt::Call { line, .. }
            | Stmt::Return { line, .. }
            | Stmt::If { line, .. }
            | Stmt::For { line, .. } => *line,
        }
    }
}

struct Program {
    stmts: Vec<Stmt>,
    labels: BTreeMap<String, usize>,
}

struct Parser {
    lines: Vec<(usize, String)>,
    pos: usize,
}

impl Parser {
    fn new(lines: Vec<(usize, String)>) -> Parser {
        Parser { lines, pos: 0 }
    }

    fn peek(&self) -> Option<&(usize, String)> {
        self.lines.get(self.pos)
    }

    fn next(&mut self) -> Option<(usize, String)> {
        let item = self.lines.get(self.pos).cloned();
        if item.is_some() {
            self.pos += 1;
        }
        item
    }

    fn parse_all(mut self) -> Result<Program, String> {
        let mut stmts = Vec::new();
        while let Some((line, raw)) = self.peek().cloned() {
            self.pos += 1;
            let stmt = self.parse_statement(line, &raw)?;
            stmts.push(stmt);
        }
        let mut labels: BTreeMap<String, usize> = BTreeMap::new();
        for (index, stmt) in stmts.iter().enumerate() {
            if let Stmt::Label { name, line } = stmt {
                let key = name.to_ascii_lowercase();
                if labels.insert(key, index).is_some() {
                    return Err(format!("第 {line} 行：标签「:{name}」重复定义"));
                }
            }
        }
        Ok(Program { stmts, labels })
    }

    fn parse_statement(&mut self, line: usize, raw: &str) -> Result<Stmt, String> {
        let text = raw.trim();
        // cmd 的 `@` 只是「不回显本行」，我们的脚本本来就不回显，直接忽略前缀。
        let text = text.strip_prefix('@').unwrap_or(text).trim_start();
        if text.starts_with("::") {
            return Ok(Stmt::Noop);
        }
        if let Some(name) = text.strip_prefix(':') {
            return Ok(Stmt::Label {
                name: name.trim().to_string(),
                line,
            });
        }
        let (word, rest) = split_first_word(text);
        match word.to_ascii_lowercase().as_str() {
            "goto" => {
                let target = rest.trim().trim_start_matches(':').trim().to_string();
                if target.is_empty() {
                    return Err(format!("第 {line} 行：goto 缺少标签"));
                }
                Ok(Stmt::Goto { target, line })
            }
            "call" => {
                let rest = rest.trim();
                let (target, consumed) = read_token(rest)
                    .ok_or_else(|| format!("第 {line} 行：call 缺少目标"))?;
                Ok(Stmt::Call {
                    target,
                    args: rest[consumed..].trim().to_string(),
                    line,
                })
            }
            "exit" if starts_with_word(rest.trim(), "/b") => {
                let code = rest.trim()[2..].trim();
                Ok(Stmt::Return {
                    code: if code.is_empty() {
                        None
                    } else {
                        Some(code.to_string())
                    },
                    line,
                })
            }
            "if" => self.parse_if(line, rest.trim()),
            "for" => self.parse_for(line, rest.trim()),
            _ => Ok(Stmt::Command {
                text: text.to_string(),
                line,
            }),
        }
    }

    fn parse_if(&mut self, line: usize, rest: &str) -> Result<Stmt, String> {
        if rest.is_empty() {
            return Err(format!("第 {line} 行：if 缺少条件"));
        }
        let (condition, body_text) = split_condition(rest)
            .ok_or_else(|| format!("第 {line} 行：if 条件无法解析（支持 exist / errorlevel / defined / 字符串 == 比较）"))?;
        let (then_body, trailing) = self.parse_body(line, &body_text)?;

        let mut else_body = Vec::new();
        if starts_with_word(&trailing, "else") {
            let rest = trailing[4..].trim().to_string();
            let (body, _) = self.parse_body(line, &rest)?;
            else_body = body;
        } else if trailing.trim().is_empty() {
            if let Some((next_line, next_text)) = self.peek().cloned() {
                if starts_with_word(next_text.trim(), "else") {
                    self.pos += 1;
                    let rest = next_text.trim()[4..].trim().to_string();
                    let (body, _) = self.parse_body(next_line, &rest)?;
                    else_body = body;
                }
            }
        }
        Ok(Stmt::If {
            condition,
            then_body,
            else_body,
            line,
        })
    }

    /// 解析 `if` / `for` 后面的执行体：单条命令，或 `( ... )` 块（可跨行）。
    fn parse_body(&mut self, line: usize, text: &str) -> Result<(Vec<Stmt>, String), String> {
        let text = text.trim();
        if text.is_empty() {
            return Err(format!("第 {line} 行：条件后面缺少要执行的命令"));
        }
        if text.starts_with('(') {
            self.parse_paren_body(line, text)
        } else {
            let stmt = self.parse_statement(line, text)?;
            Ok((vec![stmt], String::new()))
        }
    }

    fn parse_paren_body(
        &mut self,
        line: usize,
        text: &str,
    ) -> Result<(Vec<Stmt>, String), String> {
        let (inner_lines, trailing) = self.scan_paren(line, text)?;
        if inner_lines.is_empty() {
            return Ok((Vec::new(), trailing));
        }
        let program = Parser::new(inner_lines).parse_all()?;
        Ok((program.stmts, trailing))
    }

    /// 从当前行开始扫描配对的 `)`，返回括号内的源码行与右括号之后的内容。
    fn scan_paren(&mut self, line: usize, text: &str) -> Result<(Vec<(usize, String)>, String), String> {
        let mut inner_lines: Vec<(usize, String)> = Vec::new();
        let mut depth = 1usize;
        let mut quote: Option<char> = None;
        let mut current = text[1..].to_string();
        let mut current_line = line;
        loop {
            if let Some(index) = find_close(&current, &mut depth, &mut quote) {
                let before = current[..index].to_string();
                if !before.trim().is_empty() {
                    inner_lines.push((current_line, before));
                }
                return Ok((inner_lines, current[index + 1..].trim().to_string()));
            }
            if !current.trim().is_empty() {
                inner_lines.push((current_line, current));
            }
            let Some((next_line, next_text)) = self.next() else {
                return Err(format!("第 {line} 行：括号块没有闭合"));
            };
            current = next_text;
            current_line = next_line;
            quote = None;
        }
    }

    fn parse_for(&mut self, line: usize, rest: &str) -> Result<Stmt, String> {
        let mut cursor = rest.trim_start();
        let mut option = ForOption::Plain;
        let mut root: Option<String> = None;

        if starts_with_word(cursor, "/l") {
            option = ForOption::Numeric;
            cursor = cursor[2..].trim_start();
        } else if starts_with_word(cursor, "/d") {
            option = ForOption::Dirs;
            cursor = cursor[2..].trim_start();
        } else if starts_with_word(cursor, "/r") {
            option = ForOption::Recursive;
            cursor = cursor[2..].trim_start();
            // `/r` 后面可选根目录；没写时从当前目录开始。
            if !cursor.starts_with('%') && !starts_with_word(cursor, "in") {
                if let Some((token, consumed)) = read_token(cursor) {
                    root = Some(token);
                    cursor = cursor[consumed..].trim_start();
                }
            }
        } else if starts_with_word(cursor, "/f") {
            return Err(format!("第 {line} 行：for /f 暂不支持，请用 for /l 或外部程序逐行处理"));
        }

        let (var_token, consumed) = read_token(cursor)
            .ok_or_else(|| format!("第 {line} 行：for 缺少循环变量（写法如 %%i）"))?;
        let var = loop_var_name(&var_token)
            .ok_or_else(|| format!("第 {line} 行：循环变量「{var_token}」应写成 %%i 或 %i"))?;
        cursor = cursor[consumed..].trim_start();

        if !starts_with_word(cursor, "in") {
            return Err(format!("第 {line} 行：for 缺少 in"));
        }
        cursor = cursor[2..].trim_start();
        if !cursor.starts_with('(') {
            return Err(format!("第 {line} 行：for 的集合必须写在括号里"));
        }
        let (set_lines, trailing) = self.scan_paren(line, cursor)?;
        let set = set_lines
            .iter()
            .map(|(_, text)| text.trim())
            .collect::<Vec<_>>()
            .join(" ");
        cursor = trailing.trim_start();
        if !starts_with_word(cursor, "do") {
            return Err(format!("第 {line} 行：for 缺少 do"));
        }
        cursor = cursor[2..].trim_start();
        let (body, _) = self.parse_body(line, cursor)?;
        Ok(Stmt::For {
            option,
            var,
            set,
            root,
            body,
            line,
        })
    }
}

/// 解析 `if` 的条件，返回条件原文与后面的执行体。
fn split_condition(input: &str) -> Option<(String, String)> {
    let text = input.trim();
    let mut rest = text;
    if starts_with_word(rest, "not") {
        rest = rest[3..].trim_start();
    }
    if starts_with_word(rest, "exist") || starts_with_word(rest, "defined") {
        let word_len = if starts_with_word(rest, "exist") { 5 } else { 7 };
        let after = rest[word_len..].trim_start();
        let (_, consumed) = read_token(after)?;
        let tail = after[consumed..].trim_start();
        return Some((text[..text.len() - tail.len()].trim().to_string(), tail.to_string()));
    }
    if starts_with_word(rest, "errorlevel") {
        let after = rest[10..].trim_start();
        let (_, consumed) = read_token(after)?;
        let tail = after[consumed..].trim_start();
        return Some((text[..text.len() - tail.len()].trim().to_string(), tail.to_string()));
    }
    let mut compare = rest;
    if starts_with_word(compare, "/i") {
        compare = compare[2..].trim_start();
    }
    if let Some(index) = find_double_equal(compare) {
        let right = compare[index + 2..].trim_start();
        let (_, consumed) = read_token(right)?;
        let tail = right[consumed..].trim_start();
        return Some((text[..text.len() - tail.len()].trim().to_string(), tail.to_string()));
    }
    None
}

/// 计算 `if` 条件；变量已由调用方展开。
fn eval_condition(text: &str) -> Result<bool, String> {
    let mut rest = text.trim();
    let mut negate = false;
    if starts_with_word(rest, "not") {
        negate = true;
        rest = rest[3..].trim_start();
    }
    if starts_with_word(rest, "exist") {
        let path = unquote(rest[5..].trim());
        let exists = Path::new(&path).exists();
        return Ok(exists ^ negate);
    }
    if starts_with_word(rest, "errorlevel") {
        let level: i32 = rest[10..]
            .trim()
            .parse()
            .map_err(|_| format!("errorlevel 后面的数字无效：{}", rest[10..].trim()))?;
        let current = std::env::var("ERRORLEVEL")
            .ok()
            .and_then(|value| value.parse::<i32>().ok())
            .unwrap_or(0);
        return Ok((current >= level) ^ negate);
    }
    if starts_with_word(rest, "defined") {
        let name = unquote(rest[7..].trim());
        let defined = std::env::var_os(&name).is_some();
        return Ok(defined ^ negate);
    }

    let mut ignore_case = false;
    if starts_with_word(rest, "/i") {
        ignore_case = true;
        rest = rest[2..].trim_start();
    }
    let index = find_double_equal(rest)
        .ok_or_else(|| format!("if 条件缺少 == 比较：{text}"))?;
    let left = unquote(rest[..index].trim());
    let right = unquote(rest[index + 2..].trim());
    let equal = if ignore_case {
        left.eq_ignore_ascii_case(&right)
    } else {
        left == right
    };
    Ok(equal ^ negate)
}

fn find_double_equal(text: &str) -> Option<usize> {
    let chars: Vec<char> = text.chars().collect();
    let mut quote: Option<char> = None;
    let mut i = 0usize;
    while i + 1 < chars.len() {
        match chars[i] {
            '"' | '\'' => {
                if quote == Some(chars[i]) {
                    quote = None;
                } else if quote.is_none() {
                    quote = Some(chars[i]);
                }
                i += 1;
            }
            '=' if quote.is_none() && chars[i + 1] == '=' => {
                let byte = text
                    .char_indices()
                    .nth(i)
                    .map(|(byte, _)| byte)
                    .unwrap_or(text.len());
                return Some(byte);
            }
            _ => i += 1,
        }
    }
    None
}

/// 找到当前行里深度归零的 `)`，跳过引号内的括号。
fn find_close(line: &str, depth: &mut usize, quote: &mut Option<char>) -> Option<usize> {
    for (index, ch) in line.char_indices() {
        if let Some(q) = *quote {
            if ch == q {
                *quote = None;
            }
            continue;
        }
        match ch {
            '"' | '\'' => *quote = Some(ch),
            '(' => *depth += 1,
            ')' => {
                *depth = depth.saturating_sub(1);
                if *depth == 0 {
                    return Some(index);
                }
            }
            _ => {}
        }
    }
    None
}

fn split_first_word(text: &str) -> (&str, &str) {
    let trimmed = text.trim_start();
    match trimmed.find(|c: char| c.is_whitespace()) {
        Some(index) => (&trimmed[..index], &trimmed[index..]),
        None => (trimmed, ""),
    }
}

fn starts_with_word(text: &str, word: &str) -> bool {
    if text.len() < word.len() {
        return false;
    }
    if !text[..word.len()].eq_ignore_ascii_case(word) {
        return false;
    }
    text[word.len()..]
        .chars()
        .next()
        .map(|c| c.is_whitespace())
        .unwrap_or(true)
}

/// 读取一个词（支持引号），返回去掉引号的内容和消耗的字节数。
fn read_token(text: &str) -> Option<(String, usize)> {
    let trimmed = text.trim_start();
    if trimmed.is_empty() {
        return None;
    }
    let skipped = text.len() - trimmed.len();
    if let Some(first) = trimmed.chars().next() {
        if first == '"' || first == '\'' {
            if let Some(end) = trimmed[1..].find(first) {
                return Some((
                    trimmed[1..1 + end].to_string(),
                    skipped + end + 2,
                ));
            }
            return Some((trimmed[1..].to_string(), text.len()));
        }
    }
    let end = trimmed.find(|c: char| c.is_whitespace()).unwrap_or(trimmed.len());
    Some((trimmed[..end].to_string(), skipped + end))
}

fn unquote(text: &str) -> String {
    let text = text.trim();
    if text.len() >= 2 {
        let first = text.chars().next().unwrap_or(' ');
        let last = text.chars().last().unwrap_or(' ');
        if (first == '"' || first == '\'') && last == first {
            return text[first.len_utf8()..text.len() - last.len_utf8()].to_string();
        }
    }
    text.to_string()
}

/// 把 `call :sub a "b c"` 的参数拆成词。
fn split_words(text: &str) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut out = Vec::new();
    let mut token = String::new();
    let mut quote: Option<char> = None;
    let mut has_token = false;
    let mut i = 0usize;
    while i < chars.len() {
        let ch = chars[i];
        if let Some(q) = quote {
            if ch == q {
                quote = None;
            } else {
                token.push(ch);
            }
            i += 1;
            continue;
        }
        match ch {
            '"' | '\'' => {
                quote = Some(ch);
                has_token = true;
            }
            '^' if i + 1 < chars.len() => {
                token.push(chars[i + 1]);
                has_token = true;
                i += 1;
            }
            c if c.is_whitespace() => {
                if has_token {
                    out.push(std::mem::take(&mut token));
                    has_token = false;
                }
            }
            _ => {
                token.push(ch);
                has_token = true;
            }
        }
        i += 1;
    }
    if has_token {
        out.push(token);
    }
    out
}

fn loop_var_name(token: &str) -> Option<String> {
    let token = token.trim();
    let rest = token.strip_prefix("%%").or_else(|| token.strip_prefix('%'))?;
    if rest.is_empty()
        || !rest
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_')
    {
        return None;
    }
    Some(rest.to_ascii_lowercase())
}

/// 把循环变量（`%%i` / `%i`）替换成当前值。
fn replace_loop_var(text: &str, name: &str, value: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let name_chars: Vec<char> = name.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0usize;
    while i < chars.len() {
        if chars[i] != '%' {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        let double = i + 1 < chars.len() && chars[i + 1] == '%';
        let mut j = if double { i + 2 } else { i + 1 };
        if j >= chars.len() || !chars[j].eq_ignore_ascii_case(&name_chars[0]) {
            out.push('%');
            i += 1;
            continue;
        }
        j += 1;
        for expected in name_chars.iter().skip(1) {
            if j >= chars.len() || !chars[j].eq_ignore_ascii_case(expected) {
                break;
            }
            j += 1;
        }
        let matched = j == i + (if double { 2 } else { 1 }) + name_chars.len();
        let boundary = j >= chars.len()
            || !(chars[j].is_ascii_alphanumeric() || chars[j] == '_');
        if matched && boundary {
            out.push_str(value);
            i = j;
        } else {
            out.push('%');
            i += 1;
        }
    }
    out
}

enum Signal {
    Next,
    Goto(String),
    Return,
    End,
}

struct Runner {
    program: Program,
    args: Vec<String>,
    loop_vars: Vec<(String, String)>,
    depth: usize,
}

impl Runner {
    fn run(&mut self, shell: &mut Shell) -> Result<(), String> {
        let mut start = 0usize;
        loop {
            match self.run_from(shell, start)? {
                Signal::Next | Signal::End | Signal::Return => break,
                Signal::Goto(target) => {
                    start = self.resolve_label(&target)?;
                }
            }
            if !shell.running {
                break;
            }
        }
        Ok(())
    }

    fn run_from(&mut self, shell: &mut Shell, start: usize) -> Result<Signal, String> {
        let total = self.program.stmts.len();
        let mut index = start;
        while index < total {
            if !shell.running {
                return Ok(Signal::End);
            }
            let stmt = self.program.stmts[index].clone();
            index += 1;
            match self.exec_stmt(shell, &stmt)? {
                Signal::Next => {}
                other => return Ok(other),
            }
        }
        Ok(Signal::Next)
    }

    fn run_body(&mut self, shell: &mut Shell, body: &[Stmt]) -> Result<Signal, String> {
        for stmt in body {
            match self.exec_stmt(shell, stmt)? {
                Signal::Next => {}
                other => return Ok(other),
            }
        }
        Ok(Signal::Next)
    }

    fn exec_stmt(&mut self, shell: &mut Shell, stmt: &Stmt) -> Result<Signal, String> {
        let line = stmt.line();
        let result = match stmt {
            Stmt::Noop | Stmt::Label { .. } => Ok(Signal::Next),
            Stmt::Command { text, .. } => {
                let text = self.expand_text(text);
                std::env::set_var("ERRORLEVEL", "0");
                match exec::run_line(shell, &text) {
                    Ok(()) => Ok(Signal::Next),
                    Err(e) => {
                        std::env::set_var("ERRORLEVEL", "1");
                        Err(e)
                    }
                }
            }
            Stmt::Goto { target, .. } => {
                let target = self.expand_text(target);
                Ok(Signal::Goto(target))
            }
            Stmt::Call { target, args, .. } => {
                let target = self.expand_text(target);
                let args = split_words(&self.expand_text(args));
                if let Some(label) = target.strip_prefix(':') {
                    self.call_label(shell, label, &args)
                } else {
                    if target.to_ascii_lowercase().ends_with(".bat")
                        || target.to_ascii_lowercase().ends_with(".cmd")
                    {
                        return Err(format!(
                            "第 {line} 行：call 不能执行 {target}（批处理需要 cmd.exe）"
                        ));
                    }
                    super::script::run_file(shell, &target, &args)
                        .map_err(|e| format!("第 {line} 行：{e}"))?;
                    Ok(Signal::Next)
                }
            }
            Stmt::Return { code, .. } => {
                let code = code.as_ref().map(|text| self.expand_text(text));
                if let Some(code) = code {
                    let value: i32 = code
                        .trim()
                        .parse()
                        .map_err(|_| format!("第 {line} 行：exit /b 的退出码不是数字：{code}"))?;
                    std::env::set_var("ERRORLEVEL", value.to_string());
                }
                if self.depth > 0 {
                    Ok(Signal::Return)
                } else {
                    Ok(Signal::End)
                }
            }
            Stmt::If {
                condition,
                then_body,
                else_body,
                ..
            } => {
                let condition = self.expand_text(condition);
                let condition = parse::expand_vars(&condition);
                let truth = eval_condition(&condition).map_err(|e| format!("第 {line} 行：{e}"))?;
                self.run_body(shell, if truth { then_body } else { else_body })
            }
            Stmt::For {
                option,
                var,
                set,
                root,
                body,
                ..
            } => {
                let set = self.expand_text(set);
                let root = root.as_ref().map(|text| self.expand_text(text));
                let items = for_items(option, &set, root.as_deref())
                    .map_err(|e| format!("第 {line} 行：{e}"))?;
                let mut signal = Signal::Next;
                for item in items {
                    self.loop_vars.push((var.clone(), item));
                    signal = self.run_body(shell, body)?;
                    self.loop_vars.pop();
                    if !matches!(signal, Signal::Next) {
                        break;
                    }
                }
                Ok(signal)
            }
        };
        result.map_err(|e| format!("第 {line} 行：{e}"))
    }

    fn expand_text(&self, text: &str) -> String {
        let mut out = text.to_string();
        for (name, value) in self.loop_vars.iter().rev() {
            out = replace_loop_var(&out, name, value);
        }
        substitute_args(&out, &self.args)
    }

    fn resolve_label(&self, target: &str) -> Result<usize, String> {
        let key = target.trim().trim_start_matches(':').to_ascii_lowercase();
        self.program
            .labels
            .get(&key)
            .copied()
            .ok_or_else(|| format!("找不到标签「:{target}」"))
    }

    fn call_label(&mut self, shell: &mut Shell, label: &str, args: &[String]) -> Result<Signal, String> {
        let start = self.resolve_label(label)?;
        if self.depth >= 64 {
            return Err("call 嵌套超过 64 层".into());
        }
        let old_args = std::mem::replace(&mut self.args, args.to_vec());
        self.depth += 1;
        let mut current = start;
        let result = loop {
            match self.run_from(shell, current) {
                Ok(Signal::Next) | Ok(Signal::Return) => break Ok(Signal::Next),
                Ok(Signal::End) => break Ok(Signal::End),
                Ok(Signal::Goto(target)) => {
                    if target.trim().trim_start_matches(':').eq_ignore_ascii_case("eof") {
                        break Ok(Signal::Next);
                    }
                    match self.resolve_label(&target) {
                        Ok(index) => current = index,
                        Err(e) => break Err(e),
                    }
                }
                Err(e) => break Err(e),
            }
        };
        self.depth -= 1;
        self.args = old_args;
        result
    }
}

fn for_items(option: &ForOption, set: &str, root: Option<&str>) -> Result<Vec<String>, String> {
    let tokens = split_words(set);
    match option {
        ForOption::Numeric => {
            let numbers: Vec<i64> = tokens
                .iter()
                .flat_map(|token| token.split(','))
                .filter(|part| !part.trim().is_empty())
                .map(|part| {
                    part.trim()
                        .parse::<i64>()
                        .map_err(|_| format!("for /l 的数字无效：{}", part.trim()))
                })
                .collect::<Result<_, _>>()?;
            if numbers.len() != 3 {
                return Err("for /l 的集合应写成 (开始,步长,结束)".into());
            }
            let (start, step, end) = (numbers[0], numbers[1], numbers[2]);
            if step == 0 {
                return Err("for /l 的步长不能为 0".into());
            }
            let mut values = Vec::new();
            let mut current = start;
            for _ in 0..1_000_000 {
                if (step > 0 && current > end) || (step < 0 && current < end) {
                    break;
                }
                values.push(current.to_string());
                current = current
                    .checked_add(step)
                    .ok_or_else(|| "for /l 数值溢出".to_string())?;
            }
            Ok(values)
        }
        ForOption::Recursive => {
            let base = PathBuf::from(root.unwrap_or("."));
            if !base.is_dir() {
                return Err(format!("for /r 的根目录不存在：{}", base.display()));
            }
            let mut out = Vec::new();
            for token in tokens {
                let pattern = Path::new(&token)
                    .file_name()
                    .map(|name| name.to_string_lossy().to_string())
                    .unwrap_or_else(|| token.clone());
                walk(&base, &pattern, &mut out)?;
            }
            Ok(out)
        }
        ForOption::Plain | ForOption::Dirs => {
            let mut out = Vec::new();
            for token in tokens {
                if token.contains('*') || token.contains('?') {
                    let matches = builtins::glob(&token);
                    for item in matches {
                        let path = Path::new(&item);
                        if *option == ForOption::Dirs && !path.is_dir() {
                            continue;
                        }
                        out.push(item);
                    }
                } else {
                    out.push(token);
                }
            }
            Ok(out)
        }
    }
}

fn walk(dir: &Path, pattern: &str, out: &mut Vec<String>) -> Result<(), String> {
    let entries = std::fs::read_dir(dir).map_err(|e| format!("无法读取目录 {}：{e}", dir.display()))?;
    for entry in entries.flatten() {
        let path = entry.path();
        let file_type = entry.file_type().ok();
        if let Some(kind) = file_type {
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                walk(&path, pattern, out)?;
                continue;
            }
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if builtins::wildcard_match(pattern, &name) {
            out.push(path.display().to_string());
        }
    }
    Ok(())
}

pub fn run_file(shell: &mut Shell, path: &str, args: &[String]) -> Result<(), String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("无法读取脚本 {path}：{e}"))?;
    let program = Parser::new(parse_script(&text))
        .parse_all()
        .map_err(|e| format!("脚本 {path}：{e}"))?;
    let mut runner = Runner {
        program,
        args: args.to_vec(),
        loop_vars: Vec::new(),
        depth: 0,
    };
    let previous = shell.in_script;
    shell.in_script = true;
    let result = runner
        .run(shell)
        .map_err(|e| format!("脚本 {path}：{e}"));
    shell.in_script = previous;
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skips_comments_and_blanks() {
        let script = "# 注释\n\necho a\n   # 缩进注释\necho b\n";
        let lines = parse_script(script);
        assert_eq!(
            lines,
            vec![(3, "echo a".to_string()), (5, "echo b".to_string())]
        );
    }

    #[test]
    fn substitutes_positional_arguments() {
        let args = vec!["one".to_string(), "two".to_string()];
        assert_eq!(substitute_args("echo %1-%2", &args), "echo one-two");
        assert_eq!(substitute_args("echo %*", &args), "echo one two");
        assert_eq!(substitute_args("echo %3", &args), "echo ");
        assert_eq!(substitute_args("echo 100%", &args), "echo 100%");
    }

    #[test]
    fn parses_labels_and_goto_targets() {
        let program = Parser::new(parse_script(":start\necho a\ngoto start\n")).parse_all().unwrap();
        assert_eq!(program.labels.get("start"), Some(&0));
        assert!(matches!(program.stmts[2], Stmt::Goto { .. }));
    }

    #[test]
    fn parses_single_line_if_else() {
        let program = Parser::new(parse_script(
            "if exist foo.txt (echo yes) else (echo no)\necho tail\n",
        ))
        .parse_all()
        .unwrap();
        match &program.stmts[0] {
            Stmt::If {
                condition,
                then_body,
                else_body,
                ..
            } => {
                assert_eq!(condition, "exist foo.txt");
                assert_eq!(then_body.len(), 1);
                assert_eq!(else_body.len(), 1);
            }
            other => panic!("应为 if 语句：{other:?}"),
        }
        assert_eq!(program.stmts.len(), 2);
    }

    #[test]
    fn parses_multiline_if_else() {
        let program = Parser::new(parse_script(
            "if errorlevel 1 (\n  echo failed\n  echo again\n) else (\n  echo ok\n)\necho after\n",
        ))
        .parse_all()
        .unwrap();
        match &program.stmts[0] {
            Stmt::If {
                then_body, else_body, ..
            } => {
                assert_eq!(then_body.len(), 2);
                assert_eq!(else_body.len(), 1);
            }
            other => panic!("应为 if 语句：{other:?}"),
        }
        assert_eq!(program.stmts.len(), 2);
    }

    #[test]
    fn splits_condition_keywords() {
        assert_eq!(
            split_condition("defined n (echo x)"),
            Some(("defined n".to_string(), "(echo x)".to_string()))
        );
        assert_eq!(
            split_condition("not defined n echo x"),
            Some(("not defined n".to_string(), "echo x".to_string()))
        );
        assert_eq!(
            split_condition("exist \"a b.txt\" echo x"),
            Some(("exist \"a b.txt\"".to_string(), "echo x".to_string()))
        );
        assert_eq!(
            split_condition("errorlevel 2 echo x"),
            Some(("errorlevel 2".to_string(), "echo x".to_string()))
        );
    }

    #[test]
    fn evaluates_conditions() {
        let dir = std::env::temp_dir().join("scterm_script_cond");
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("a.txt");
        std::fs::write(&file, b"x").unwrap();

        std::env::set_var("SCTERM_SCRIPT_VAR", "abc");
        std::env::set_var("ERRORLEVEL", "3");

        assert!(eval_condition(&format!("exist \"{}\"", file.display())).unwrap());
        assert!(!eval_condition(&format!("not exist \"{}\"", file.display())).unwrap());
        assert!(eval_condition("errorlevel 2").unwrap());
        assert!(!eval_condition("errorlevel 5").unwrap());
        assert!(eval_condition("defined SCTERM_SCRIPT_VAR").unwrap());
        assert!(eval_condition("/i \"ABC\"==\"abc\"").unwrap());
        assert!(!eval_condition("\"abc\"==\"ABC\"").unwrap());
        assert!(eval_condition("not \"abc\"==\"abd\"").unwrap());

        std::env::remove_var("SCTERM_SCRIPT_VAR");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn numeric_for_produces_inclusive_range() {
        assert_eq!(
            for_items(&ForOption::Numeric, "1,2,7", None).unwrap(),
            vec!["1", "3", "5", "7"]
        );
        assert_eq!(
            for_items(&ForOption::Numeric, "5,-2,1", None).unwrap(),
            vec!["5", "3", "1"]
        );
        assert!(for_items(&ForOption::Numeric, "1,0,3", None).is_err());
    }

    #[test]
    fn loop_variable_replacement_handles_batch_syntax() {
        assert_eq!(replace_loop_var("echo %%i", "i", "abc"), "echo abc");
        assert_eq!(replace_loop_var("echo %i", "i", "abc"), "echo abc");
        assert_eq!(replace_loop_var("echo %%I", "i", "abc"), "echo abc");
        assert_eq!(replace_loop_var("echo %%ij", "i", "abc"), "echo %%ij");
        assert_eq!(replace_loop_var("echo %PATH%", "i", "abc"), "echo %PATH%");
    }

    #[test]
    fn splits_call_arguments() {
        assert_eq!(
            split_words("a \"b c\" d"),
            vec!["a".to_string(), "b c".to_string(), "d".to_string()]
        );
    }

    #[test]
    fn parses_for_forms() {
        let program = Parser::new(parse_script(
            "for %%i in (*.txt) do echo %%i\nfor /l %%n in (1,1,3) do echo %%n\nfor /d %%d in (src*) do echo %%d\nfor /r \"C:\\tmp\" %%f in (*.log) do echo %%f\n",
        ))
        .parse_all()
        .unwrap();
        match &program.stmts[0] {
            Stmt::For { option, var, set, body, .. } => {
                assert_eq!(*option, ForOption::Plain);
                assert_eq!(var, "i");
                assert_eq!(set, "*.txt");
                assert_eq!(body.len(), 1);
            }
            other => panic!("应为 for 语句：{other:?}"),
        }
        match &program.stmts[1] {
            Stmt::For { option, .. } => assert_eq!(*option, ForOption::Numeric),
            other => panic!("应为 for /l 语句：{other:?}"),
        }
        match &program.stmts[2] {
            Stmt::For { option, .. } => assert_eq!(*option, ForOption::Dirs),
            other => panic!("应为 for /d 语句：{other:?}"),
        }
        match &program.stmts[3] {
            Stmt::For { option, root, .. } => {
                assert_eq!(*option, ForOption::Recursive);
                assert_eq!(root.as_deref(), Some("C:\\tmp"));
            }
            other => panic!("应为 for /r 语句：{other:?}"),
        }
    }
}

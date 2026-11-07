//! 极简 TOML 子集解析器：只覆盖 scterm 配置需要的语法。
//!
//! 支持：注释、`[table]`、`[[array of tables]]`、`key = value`
//! （字符串 / 整数 / 布尔 / 字符串数组）、`"` 与 `'` 两种字符串。
//! 不支持：内联表、多行字符串、日期、点号键。

use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Bool(bool),
    Array(Vec<Value>),
}

#[derive(Debug, Default, Clone)]
pub struct Table {
    pub entries: Vec<(String, Value)>,
}

impl Table {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn set(&mut self, key: String, value: Value) {
        if let Some(slot) = self.entries.iter_mut().find(|(k, _)| *k == key) {
            slot.1 = value;
        } else {
            self.entries.push((key, value));
        }
    }

    pub fn get_str(&self, key: &str) -> Option<&str> {
        match self.get(key) {
            Some(Value::Str(s)) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn get_bool(&self, key: &str) -> Option<bool> {
        match self.get(key) {
            Some(Value::Bool(b)) => Some(*b),
            _ => None,
        }
    }

    pub fn get_int(&self, key: &str) -> Option<i64> {
        match self.get(key) {
            Some(Value::Int(i)) => Some(*i),
            _ => None,
        }
    }

    pub fn get_str_array(&self, key: &str) -> Vec<String> {
        match self.get(key) {
            Some(Value::Array(items)) => items
                .iter()
                .filter_map(|v| match v {
                    Value::Str(s) => Some(s.clone()),
                    _ => None,
                })
                .collect(),
            _ => Vec::new(),
        }
    }
}

#[derive(Debug, Default)]
pub struct Document {
    pub root: Table,
    pub tables: BTreeMap<String, Table>,
    pub arrays: BTreeMap<String, Vec<Table>>,
}

impl Document {
    pub fn table(&self, name: &str) -> Option<&Table> {
        self.tables.get(name)
    }

    pub fn array(&self, name: &str) -> &[Table] {
        self.arrays.get(name).map(|v| v.as_slice()).unwrap_or(&[])
    }
}

#[derive(Clone)]
enum Section {
    Root,
    Table(String),
    Array(String, usize),
}

pub fn parse(text: &str) -> Result<Document, String> {
    let mut doc = Document::default();
    let mut section = Section::Root;

    for (idx, raw) in text.lines().enumerate() {
        let line_no = idx + 1;
        let line = strip_comment(raw).trim().to_string();
        if line.is_empty() {
            continue;
        }

        if let Some(rest) = line.strip_prefix("[[") {
            if !rest.ends_with("]]") {
                return Err(format!("第 {line_no} 行：表数组缺少 `]]`"));
            }
            let name = rest[..rest.len() - 2].trim().to_string();
            let vec = doc.arrays.entry(name.clone()).or_default();
            vec.push(Table::default());
            let index = vec.len() - 1;
            section = Section::Array(name, index);
            continue;
        }

        if let Some(rest) = line.strip_prefix('[') {
            if !rest.ends_with(']') {
                return Err(format!("第 {line_no} 行：表缺少 `]`"));
            }
            let name = rest[..rest.len() - 1].trim().to_string();
            doc.tables.entry(name.clone()).or_default();
            section = Section::Table(name);
            continue;
        }

        let (key, value_text) = line
            .split_once('=')
            .ok_or_else(|| format!("第 {line_no} 行：缺少 `=`"))?;
        let key = key.trim().trim_matches('"').to_string();
        let value = parse_value(value_text.trim())
            .map_err(|e| format!("第 {line_no} 行：{e}"))?;

        match &section {
            Section::Root => doc.root.set(key, value),
            Section::Table(name) => {
                if let Some(table) = doc.tables.get_mut(name) {
                    table.set(key, value);
                }
            }
            Section::Array(name, index) => {
                if let Some(tables) = doc.arrays.get_mut(name) {
                    if let Some(table) = tables.get_mut(*index) {
                        table.set(key, value);
                    }
                }
            }
        }
    }

    Ok(doc)
}

fn strip_comment(line: &str) -> &str {
    let mut in_double = false;
    let mut in_single = false;
    for (i, c) in line.char_indices() {
        match c {
            '"' if !in_single => in_double = !in_double,
            '\'' if !in_double => in_single = !in_single,
            '#' if !in_double && !in_single => return &line[..i],
            _ => {}
        }
    }
    line
}

fn parse_value(text: &str) -> Result<Value, String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("值为空".into());
    }
    if text.starts_with('"') {
        return parse_string(text).map(Value::Str);
    }
    if text.starts_with('\'') {
        if let Some(end) = text[1..].find('\'') {
            return Ok(Value::Str(text[1..1 + end].to_string()));
        }
        return Err("字符串缺少收尾单引号".into());
    }
    if text == "true" {
        return Ok(Value::Bool(true));
    }
    if text == "false" {
        return Ok(Value::Bool(false));
    }
    if text.starts_with('[') {
        if !text.ends_with(']') {
            return Err("数组缺少 `]`".into());
        }
        let inner = &text[1..text.len() - 1];
        let mut items = Vec::new();
        for part in split_array(inner) {
            let part = part.trim();
            if part.is_empty() {
                continue;
            }
            items.push(parse_value(part)?);
        }
        return Ok(Value::Array(items));
    }
    if let Ok(v) = text.replace('_', "").parse::<i64>() {
        return Ok(Value::Int(v));
    }
    Err(format!("无法识别的值：{text}"))
}

fn parse_string(text: &str) -> Result<String, String> {
    let bytes = text.as_bytes();
    let mut out = String::new();
    let mut i = 1;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if c == '\\' && i + 1 < bytes.len() {
            let next = bytes[i + 1] as char;
            out.push(match next {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                other => other,
            });
            i += 2;
            continue;
        }
        if c == '"' {
            return Ok(out);
        }
        // 按 UTF-8 边界推进
        let ch = text[i..].chars().next().ok_or("字符串解析失败")?;
        out.push(ch);
        i += ch.len_utf8();
    }
    Err("字符串缺少收尾双引号".into())
}

fn split_array(inner: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut in_double = false;
    let mut in_single = false;
    for c in inner.chars() {
        match c {
            '"' if !in_single => {
                in_double = !in_double;
                current.push(c);
            }
            '\'' if !in_double => {
                in_single = !in_single;
                current.push(c);
            }
            ',' if !in_double && !in_single => {
                parts.push(std::mem::take(&mut current));
            }
            _ => current.push(c),
        }
    }
    parts.push(current);
    parts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_scalars_and_tables() {
        let doc = parse(
            r#"
# 注释
default_profile = "cmd"   # 行尾注释
scrollback = 10000

[render]
mouse = true
truecolor = "auto"
"#,
        )
        .unwrap();
        assert_eq!(doc.root.get_str("default_profile"), Some("cmd"));
        assert_eq!(doc.root.get_int("scrollback"), Some(10000));
        let render = doc.table("render").unwrap();
        assert_eq!(render.get_bool("mouse"), Some(true));
        assert_eq!(render.get_str("truecolor"), Some("auto"));
    }

    #[test]
    fn parses_array_of_tables() {
        let doc = parse(
            r#"
[[profiles]]
name = "pwsh"
command = "pwsh.exe"
args = ["-NoLogo", "-NoProfile"]

[[profiles]]
name = "cmd"
command = "cmd.exe"
"#,
        )
        .unwrap();
        let profiles = doc.array("profiles");
        assert_eq!(profiles.len(), 2);
        assert_eq!(profiles[0].get_str("name"), Some("pwsh"));
        assert_eq!(
            profiles[0].get_str_array("args"),
            vec!["-NoLogo".to_string(), "-NoProfile".to_string()]
        );
        assert_eq!(profiles[1].get_str("command"), Some("cmd.exe"));
    }

    #[test]
    fn reports_bad_line() {
        let err = parse("foo without equals").unwrap_err();
        assert!(err.contains('='), "错误信息应指出缺少等号：{err}");
    }

    #[test]
    fn comment_inside_string_is_kept() {
        let doc = parse(r#"title = "a # b""#).unwrap();
        assert_eq!(doc.root.get_str("title"), Some("a # b"));
    }
}

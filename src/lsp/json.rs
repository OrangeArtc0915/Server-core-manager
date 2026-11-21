//! 极简 JSON：LSP 协议用到的解析与序列化。

use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
}

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(map) => map.get(key),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(text) => Some(text),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Number(value) => Some(*value),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        self.as_f64().map(|v| v as i64)
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(value) => Some(*value),
            _ => None,
        }
    }

    pub fn dump(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
            Json::Number(value) => {
                if value.fract() == 0.0 {
                    out.push_str(&format!("{}", *value as i64));
                } else {
                    out.push_str(&format!("{value}"));
                }
            }
            Json::String(text) => write_string(out, text),
            Json::Array(items) => {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    item.write(out);
                }
                out.push(']');
            }
            Json::Object(map) => {
                out.push('{');
                for (index, (key, value)) in map.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    write_string(out, key);
                    out.push(':');
                    value.write(out);
                }
                out.push('}');
            }
        }
    }
}

fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

pub fn parse(text: &str) -> Result<Json, String> {
    let mut parser = Parser {
        chars: text.chars().collect(),
        pos: 0,
    };
    parser.skip();
    let value = parser.value()?;
    parser.skip();
    Ok(value)
}

pub fn object(pairs: Vec<(&str, Json)>) -> Json {
    let mut map = BTreeMap::new();
    for (key, value) in pairs {
        map.insert(key.to_string(), value);
    }
    Json::Object(map)
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
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

    fn skip(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t' | '\r' | '\n')) {
            self.pos += 1;
        }
    }

    fn expect(&mut self, target: char) -> Result<(), String> {
        match self.next() {
            Some(ch) if ch == target => Ok(()),
            Some(ch) => Err(format!("JSON 第 {} 个字符应为 '{target}'，实际 '{ch}'", self.pos)),
            None => Err("JSON 意外结束".into()),
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        self.skip();
        match self.peek() {
            Some('{') => self.object_value(),
            Some('[') => self.array_value(),
            Some('"') => Ok(Json::String(self.string_value()?)),
            Some('t') => {
                self.word("true")?;
                Ok(Json::Bool(true))
            }
            Some('f') => {
                self.word("false")?;
                Ok(Json::Bool(false))
            }
            Some('n') => {
                self.word("null")?;
                Ok(Json::Null)
            }
            Some(ch) if ch == '-' || ch.is_ascii_digit() => self.number_value(),
            other => Err(format!("JSON 意外字符 {other:?}")),
        }
    }

    fn word(&mut self, word: &str) -> Result<(), String> {
        for target in word.chars() {
            if self.next() != Some(target) {
                return Err(format!("JSON 期望 '{word}'"));
            }
        }
        Ok(())
    }

    fn object_value(&mut self) -> Result<Json, String> {
        self.expect('{')?;
        let mut map = BTreeMap::new();
        self.skip();
        if self.peek() == Some('}') {
            self.next();
            return Ok(Json::Object(map));
        }
        loop {
            self.skip();
            let key = self.string_value()?;
            self.skip();
            self.expect(':')?;
            let value = self.value()?;
            map.insert(key, value);
            self.skip();
            match self.next() {
                Some(',') => continue,
                Some('}') => break,
                other => return Err(format!("JSON 对象分隔错误 {other:?}")),
            }
        }
        Ok(Json::Object(map))
    }

    fn array_value(&mut self) -> Result<Json, String> {
        self.expect('[')?;
        let mut items = Vec::new();
        self.skip();
        if self.peek() == Some(']') {
            self.next();
            return Ok(Json::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.skip();
            match self.next() {
                Some(',') => continue,
                Some(']') => break,
                other => return Err(format!("JSON 数组分隔错误 {other:?}")),
            }
        }
        Ok(Json::Array(items))
    }

    fn string_value(&mut self) -> Result<String, String> {
        self.expect('"')?;
        let mut out = String::new();
        loop {
            match self.next() {
                Some('"') => break,
                Some('\\') => match self.next() {
                    Some('"') => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some('/') => out.push('/'),
                    Some('b') => out.push('\u{0008}'),
                    Some('f') => out.push('\u{000C}'),
                    Some('n') => out.push('\n'),
                    Some('r') => out.push('\r'),
                    Some('t') => out.push('\t'),
                    Some('u') => {
                        let mut hex = String::new();
                        for _ in 0..4 {
                            hex.push(self.next().ok_or("JSON \\u 转义不完整")?);
                        }
                        let code = u32::from_str_radix(&hex, 16).map_err(|_| "JSON \\u 非法")?;
                        if let Some(ch) = char::from_u32(code) {
                            out.push(ch);
                        }
                    }
                    other => return Err(format!("JSON 转义错误 {other:?}")),
                },
                Some(ch) => out.push(ch),
                None => return Err("JSON 字符串未结束".into()),
            }
        }
        Ok(out)
    }

    fn number_value(&mut self) -> Result<Json, String> {
        let start = self.pos;
        if self.peek() == Some('-') {
            self.next();
        }
        while matches!(self.peek(), Some(ch) if ch.is_ascii_digit()) {
            self.next();
        }
        if self.peek() == Some('.') {
            self.next();
            while matches!(self.peek(), Some(ch) if ch.is_ascii_digit()) {
                self.next();
            }
        }
        if matches!(self.peek(), Some('e' | 'E')) {
            self.next();
            if matches!(self.peek(), Some('+' | '-')) {
                self.next();
            }
            while matches!(self.peek(), Some(ch) if ch.is_ascii_digit()) {
                self.next();
            }
        }
        let text: String = self.chars[start..self.pos].iter().collect();
        text.parse::<f64>()
            .map(Json::Number)
            .map_err(|_| format!("JSON 数字无效：{text}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_nested() {
        let value = parse(r#"{"a":1,"b":[true,null,"x\n"],"c":{"d":2.5}}"#).unwrap();
        assert_eq!(value.get("a").and_then(|v| v.as_i64()), Some(1));
        assert_eq!(
            value
                .get("b")
                .and_then(|v| v.as_array())
                .map(|a| a.len()),
            Some(3)
        );
        assert_eq!(
            value.get("c").and_then(|v| v.get("d")).and_then(|v| v.as_f64()),
            Some(2.5)
        );
    }

    #[test]
    fn roundtrip_strings() {
        let text = "a\"b\\c\n中文";
        let dumped = Json::String(text.into()).dump();
        match parse(&dumped).unwrap() {
            Json::String(parsed) => assert_eq!(parsed, text),
            _ => panic!("类型错误"),
        }
    }

    #[test]
    fn dump_object() {
        let value = object(vec![
            ("id", Json::Number(1.0)),
            ("method", Json::String("initialize".into())),
        ]);
        assert!(value.dump().contains("\"id\":1"));
    }
}

//! 轻量 XML DOM：docx / xlsx 都是 OOXML，需要保留未知元素与属性。

#[derive(Clone, Debug)]
pub enum Node {
    Element(Element),
    Text(String),
}

#[derive(Clone, Debug)]
pub struct Element {
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub children: Vec<Node>,
}

impl Element {
    pub fn new(name: &str) -> Element {
        Element {
            name: name.to_string(),
            attrs: Vec::new(),
            children: Vec::new(),
        }
    }

    pub fn attr(&self, key: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value.as_str())
    }

    pub fn set_attr(&mut self, key: &str, value: &str) {
        if let Some(pair) = self.attrs.iter_mut().find(|(name, _)| name == key) {
            pair.1 = value.to_string();
        } else {
            self.attrs.push((key.to_string(), value.to_string()));
        }
    }

    pub fn elements(&self) -> impl Iterator<Item = &Element> {
        self.children.iter().filter_map(|node| match node {
            Node::Element(element) => Some(element),
            _ => None,
        })
    }

    pub fn elements_mut(&mut self) -> impl Iterator<Item = &mut Element> {
        self.children.iter_mut().filter_map(|node| match node {
            Node::Element(element) => Some(element),
            _ => None,
        })
    }

    pub fn first_child(&self, name: &str) -> Option<&Element> {
        self.elements().find(|element| element.name == name)
    }

    pub fn first_child_mut(&mut self, name: &str) -> Option<&mut Element> {
        self.elements_mut().find(|element| element.name == name)
    }

    /// 深度优先查找第一个同名元素。
    pub fn find(&self, name: &str) -> Option<&Element> {
        if self.name == name {
            return Some(self);
        }
        for element in self.elements() {
            if let Some(found) = element.find(name) {
                return Some(found);
            }
        }
        None
    }

    pub fn find_mut(&mut self, name: &str) -> Option<&mut Element> {
        if self.name == name {
            return Some(self);
        }
        for element in self.elements_mut() {
            if let Some(found) = element.find_mut(name) {
                return Some(found);
            }
        }
        None
    }

    /// 所有文本节点拼接（含后代）。
    pub fn text(&self) -> String {
        let mut out = String::new();
        self.collect_text(&mut out);
        out
    }

    fn collect_text(&self, out: &mut String) {
        for node in &self.children {
            match node {
                Node::Text(text) => out.push_str(text),
                Node::Element(element) => element.collect_text(out),
            }
        }
    }

    pub fn push_text(&mut self, text: &str) {
        self.children.push(Node::Text(text.to_string()));
    }

    pub fn push(&mut self, element: Element) {
        self.children.push(Node::Element(element));
    }
}

pub fn parse(text: &str) -> Result<Element, String> {
    let mut parser = Parser {
        chars: text.chars().collect(),
        pos: 0,
    };
    parser.skip_misc();
    if parser.peek() != Some('<') {
        return Err("XML 缺少根元素".into());
    }
    let root = parser.element()?;
    Ok(root)
}

pub fn serialize(element: &Element) -> String {
    let mut out = String::new();
    write_element(element, &mut out);
    out
}

fn write_element(element: &Element, out: &mut String) {
    out.push('<');
    out.push_str(&element.name);
    for (key, value) in &element.attrs {
        out.push(' ');
        out.push_str(key);
        out.push_str("=\"");
        escape_attr(value, out);
        out.push('"');
    }
    if element.children.is_empty() {
        out.push_str("/>");
        return;
    }
    out.push('>');
    for node in &element.children {
        match node {
            Node::Text(text) => escape_text(text, out),
            Node::Element(child) => write_element(child, out),
        }
    }
    out.push_str("</");
    out.push_str(&element.name);
    out.push('>');
}

fn escape_text(text: &str, out: &mut String) {
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(ch),
        }
    }
}

fn escape_attr(text: &str, out: &mut String) {
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\n' => out.push_str("&#10;"),
            _ => out.push(ch),
        }
    }
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

    fn starts_with(&self, text: &str) -> bool {
        let mut index = self.pos;
        for ch in text.chars() {
            if self.chars.get(index) != Some(&ch) {
                return false;
            }
            index += 1;
        }
        true
    }

    fn skip_until(&mut self, text: &str) -> Result<(), String> {
        while self.pos < self.chars.len() {
            if self.starts_with(text) {
                self.pos += text.chars().count();
                return Ok(());
            }
            self.pos += 1;
        }
        Err(format!("XML 未找到结束标记 {text}"))
    }

    fn skip_space(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t' | '\r' | '\n')) {
            self.pos += 1;
        }
    }

    fn skip_misc(&mut self) {
        loop {
            self.skip_space();
            if self.starts_with("<?") {
                let _ = self.skip_until("?>");
            } else if self.starts_with("<!--") {
                let _ = self.skip_until("-->");
            } else if self.starts_with("<!DOCTYPE") {
                // 跳过 DOCTYPE（可能带内部子集）
                let mut depth = 0i32;
                while let Some(ch) = self.next() {
                    if ch == '[' {
                        depth += 1;
                    } else if ch == ']' {
                        depth -= 1;
                    } else if ch == '>' && depth <= 0 {
                        break;
                    }
                }
            } else {
                break;
            }
        }
    }

    fn element(&mut self) -> Result<Element, String> {
        if self.next() != Some('<') {
            return Err("XML 元素缺少 '<'".into());
        }
        let mut name = String::new();
        while let Some(ch) = self.peek() {
            if ch.is_whitespace() || ch == '>' || ch == '/' {
                break;
            }
            name.push(ch);
            self.pos += 1;
        }
        if name.is_empty() {
            return Err("XML 元素名为空".into());
        }
        let mut element = Element::new(&name);
        // 属性
        loop {
            self.skip_space();
            match self.peek() {
                Some('/') => {
                    self.pos += 1;
                    if self.next() != Some('>') {
                        return Err("XML 自闭合标签错误".into());
                    }
                    return Ok(element);
                }
                Some('>') => {
                    self.pos += 1;
                    break;
                }
                Some(_) => {
                    let mut key = String::new();
                    while let Some(ch) = self.peek() {
                        if ch.is_whitespace() || ch == '=' || ch == '>' || ch == '/' {
                            break;
                        }
                        key.push(ch);
                        self.pos += 1;
                    }
                    self.skip_space();
                    if self.next() != Some('=') {
                        return Err(format!("XML 属性 {key} 缺少 '='"));
                    }
                    self.skip_space();
                    let quote = self.next().ok_or("XML 属性缺少引号")?;
                    if quote != '"' && quote != '\'' {
                        return Err("XML 属性引号错误".into());
                    }
                    let mut value = String::new();
                    while let Some(ch) = self.next() {
                        if ch == quote {
                            break;
                        }
                        if ch == '&' {
                            value.push_str(&self.entity()?);
                        } else {
                            value.push(ch);
                        }
                    }
                    element.attrs.push((key, value));
                }
                None => return Err("XML 元素未闭合".into()),
            }
        }

        // 子节点
        loop {
            if self.starts_with("</") {
                self.pos += 2;
                let mut closing = String::new();
                while let Some(ch) = self.next() {
                    if ch == '>' {
                        break;
                    }
                    closing.push(ch);
                }
                if closing.trim() != name {
                    return Err(format!("XML 标签不匹配：{name} / {closing}"));
                }
                return Ok(element);
            }
            if self.starts_with("<!--") {
                self.skip_until("-->")?;
                continue;
            }
            if self.starts_with("<![CDATA[") {
                self.pos += 9;
                let mut text = String::new();
                while self.pos < self.chars.len() && !self.starts_with("]]>") {
                    text.push(self.chars[self.pos]);
                    self.pos += 1;
                }
                self.skip_until("]]>")?;
                element.children.push(Node::Text(text));
                continue;
            }
            if self.peek() == Some('<') {
                let child = self.element()?;
                element.children.push(Node::Element(child));
                continue;
            }
            // 文本
            let mut text = String::new();
            while let Some(ch) = self.peek() {
                if ch == '<' {
                    break;
                }
                self.pos += 1;
                if ch == '&' {
                    text.push_str(&self.entity()?);
                } else {
                    text.push(ch);
                }
            }
            if !text.is_empty() {
                element.children.push(Node::Text(text));
            }
            if self.peek().is_none() {
                return Err(format!("XML 元素 {name} 未结束"));
            }
        }
    }

    /// 解析以 `&` 开头、`;` 结尾的实体。
    fn entity(&mut self) -> Result<String, String> {
        let mut name = String::new();
        while let Some(ch) = self.next() {
            if ch == ';' {
                break;
            }
            name.push(ch);
        }
        let text = match name.as_str() {
            "amp" => "&",
            "lt" => "<",
            "gt" => ">",
            "quot" => "\"",
            "apos" => "'",
            other => {
                if let Some(hex) = other.strip_prefix("#x") {
                    let code = u32::from_str_radix(hex, 16).map_err(|_| "XML 实体无效")?;
                    return Ok(char::from_u32(code).unwrap_or(' ').to_string());
                }
                if let Some(dec) = other.strip_prefix('#') {
                    let code: u32 = dec.parse().map_err(|_| "XML 实体无效")?;
                    return Ok(char::from_u32(code).unwrap_or(' ').to_string());
                }
                return Ok(format!("&{other};"));
            }
        };
        Ok(text.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_serialize() {
        let text = r#"<?xml version="1.0"?><root a="1"><w:p><w:t>你好 &amp; hi</w:t></w:p></root>"#;
        let root = parse(text).unwrap();
        assert_eq!(root.name, "root");
        assert_eq!(root.attr("a"), Some("1"));
        assert_eq!(root.find("w:t").unwrap().text(), "你好 & hi");
        let out = serialize(&root);
        assert!(out.contains("<w:t>你好 &amp; hi</w:t>"));
    }

    #[test]
    fn handles_comments_and_cdata() {
        let text = "<a><!-- c --><b><![CDATA[x<y]]></b></a>";
        let root = parse(text).unwrap();
        assert_eq!(root.find("b").unwrap().text(), "x<y");
    }
}

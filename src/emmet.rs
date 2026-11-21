//! Emmet 风格缩写展开（HTML / CSS 子集）。
//!
//! 支持 `div.container>p*2`、`ul>li{item}+li`、`img`、`a#top` 等常见写法，
//! 以及 `m10`、`p8`、`w100`、`df` 等基础 CSS 缩写。

struct Node {
    tag: String,
    classes: Vec<String>,
    id: Option<String>,
    text: Option<String>,
    children: Vec<Node>,
    repeat: usize,
}

const VOID_TAGS: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
    "source", "track", "wbr",
];

fn parse_simple(part: &str) -> Option<Node> {
    let chars: Vec<char> = part.chars().collect();
    if chars.is_empty() {
        return None;
    }
    let mut i = 0usize;
    let mut tag = String::new();
    while i < chars.len() && (chars[i].is_alphanumeric() || chars[i] == '-' || chars[i] == ':') {
        tag.push(chars[i]);
        i += 1;
    }
    if tag.is_empty() {
        tag.push_str("div");
    }
    let mut node = Node {
        tag,
        classes: Vec::new(),
        id: None,
        text: None,
        children: Vec::new(),
        repeat: 1,
    };
    while i < chars.len() {
        match chars[i] {
            '.' | '#' => {
                let is_class = chars[i] == '.';
                i += 1;
                let mut name = String::new();
                while i < chars.len()
                    && (chars[i].is_alphanumeric() || chars[i] == '-' || chars[i] == '_')
                {
                    name.push(chars[i]);
                    i += 1;
                }
                if name.is_empty() {
                    return None;
                }
                if is_class {
                    node.classes.push(name);
                } else {
                    node.id = Some(name);
                }
            }
            '{' => {
                i += 1;
                let mut text = String::new();
                while i < chars.len() && chars[i] != '}' {
                    text.push(chars[i]);
                    i += 1;
                }
                if i >= chars.len() {
                    return None;
                }
                i += 1;
                node.text = Some(text);
            }
            '*' => {
                i += 1;
                let mut digits = String::new();
                while i < chars.len() && chars[i].is_ascii_digit() {
                    digits.push(chars[i]);
                    i += 1;
                }
                node.repeat = digits.parse::<usize>().ok().unwrap_or(1).clamp(1, 50);
            }
            _ => return None,
        }
    }
    Some(node)
}

fn parse_chain(chain: &str) -> Option<Node> {
    let mut root: Option<Node> = None;
    for part in chain.split('>') {
        let node = parse_simple(part)?;
        match root.as_mut() {
            None => root = Some(node),
            Some(r) => {
                let mut cur = r;
                loop {
                    if cur.children.is_empty() {
                        break;
                    }
                    cur = cur.children.last_mut()?;
                }
                cur.children.push(node);
            }
        }
    }
    root
}

fn indent_of(spaces: usize) -> String {
    " ".repeat(spaces)
}

fn render(node: &Node, depth: usize, out: &mut String) {
    let pad = indent_of(depth * 2);
    for _ in 0..node.repeat {
        let mut attrs = String::new();
        if let Some(id) = &node.id {
            attrs.push_str(&format!(" id=\"{id}\""));
        }
        if !node.classes.is_empty() {
            attrs.push_str(&format!(" class=\"{}\"", node.classes.join(" ")));
        }
        let void = VOID_TAGS.contains(&node.tag.as_str());
        if void {
            out.push_str(&format!("{pad}<{}{} />", node.tag, attrs));
        } else if node.children.is_empty() {
            let text = node.text.clone().unwrap_or_default();
            out.push_str(&format!("{pad}<{}{}>{}</{}>", node.tag, attrs, text, node.tag));
        } else {
            out.push_str(&format!("{pad}<{}{}>", node.tag, attrs));
            if let Some(t) = &node.text {
                out.push_str(t);
            }
            out.push('\n');
            for child in &node.children {
                render(child, depth + 1, out);
                out.push('\n');
            }
            out.push_str(&format!("{pad}</{}>", node.tag));
        }
        out.push('\n');
    }
}

/// 展开 HTML 缩写；无法识别时返回 None。
pub fn expand_html(abbr: &str) -> Option<String> {
    if abbr.is_empty() || abbr.len() > 120 {
        return None;
    }
    if !abbr
        .chars()
        .all(|c| c.is_alphanumeric() || ".#{}*>-+_ :".contains(c))
    {
        return None;
    }
    let mut out = String::new();
    for chain in abbr.split('+') {
        let node = parse_chain(chain)?;
        render(&node, 0, &mut out);
    }
    let trimmed = out.trim_end_matches('\n').to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

/// 展开基础 CSS 缩写；无法识别时返回 None。
pub fn expand_css(abbr: &str) -> Option<String> {
    let lower = abbr.to_ascii_lowercase();
    let simple = match lower.as_str() {
        "df" => Some("display: flex;"),
        "db" => Some("display: block;"),
        "dn" => Some("display: none;"),
        "dg" => Some("display: grid;"),
        "jcc" => Some("justify-content: center;"),
        "aic" => Some("align-items: center;"),
        "posa" => Some("position: absolute;"),
        "posr" => Some("position: relative;"),
        "tac" => Some("text-align: center;"),
        _ => None,
    };
    if let Some(v) = simple {
        return Some(v.to_string());
    }
    let prefixes: [(&str, &str); 6] = [
        ("m", "margin"),
        ("p", "padding"),
        ("w", "width"),
        ("h", "height"),
        ("fz", "font-size"),
        ("lh", "line-height"),
    ];
    for (prefix, prop) in prefixes {
        if let Some(rest) = lower.strip_prefix(prefix) {
            if rest.is_empty() {
                continue;
            }
            // 支持 m10 / m10-20 / m-10（负值）
            let value = rest.replace('-', " ");
            let mut parts = Vec::new();
            for piece in value.split_whitespace() {
                if piece.parse::<f64>().is_ok() {
                    parts.push(format!("{}px", piece));
                } else {
                    return None;
                }
            }
            if parts.is_empty() {
                return None;
            }
            return Some(format!("{}: {};", prop, parts.join(" ")));
        }
    }
    // 颜色：c#fff / bg#000
    for (prefix, prop) in [("bg", "background"), ("c", "color")] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            if let Some(color) = rest.strip_prefix('#') {
                if !color.is_empty() && color.chars().all(|c| c.is_ascii_hexdigit()) {
                    return Some(format!("{}: #{};", prop, color));
                }
            }
        }
    }
    None
}

/// 把多行文本的后续行按给定缩进对齐（首行保持原样）。
pub fn indent_lines(text: &str, indent: &str) -> String {
    if indent.is_empty() {
        return text.to_string();
    }
    let mut out = String::new();
    for (index, line) in text.split('\n').enumerate() {
        if index > 0 {
            out.push('\n');
            if !line.is_empty() {
                out.push_str(indent);
            }
        }
        out.push_str(line);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simple_tag() {
        assert_eq!(expand_html("div").unwrap(), "<div></div>");
    }

    #[test]
    fn class_and_id() {
        assert_eq!(
            expand_html("div.a#b").unwrap(),
            "<div id=\"b\" class=\"a\"></div>"
        );
    }

    #[test]
    fn nested_and_repeat() {
        let out = expand_html("ul>li*2").unwrap();
        assert!(out.contains("<ul>"));
        assert_eq!(out.matches("<li></li>").count(), 2);
    }

    #[test]
    fn siblings_and_text() {
        let out = expand_html("p{a}+span").unwrap();
        assert!(out.contains("<p>a</p>"));
        assert!(out.contains("<span></span>"));
    }

    #[test]
    fn void_tag() {
        assert_eq!(expand_html("img").unwrap(), "<img />");
    }

    #[test]
    fn css() {
        assert_eq!(expand_css("m10").unwrap(), "margin: 10px;");
        assert_eq!(expand_css("df").unwrap(), "display: flex;");
        assert_eq!(expand_css("c#fff").unwrap(), "color: #fff;");
        assert!(expand_css("xyz").is_none());
    }
}

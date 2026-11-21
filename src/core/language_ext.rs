//! 语言扩展点：从配置目录加载自定义语言定义。
//!
//! 文件位置：`%APPDATA%\Textm\languages\*.ini`，格式：
//!
//! ```ini
//! name = 我的语言
//! extensions = foo, bar
//! keywords = fn, let, if, else
//! types = Int, Str
//! comment = #
//! style = hash
//! ```
//!
//! `style` 可选 `c_like` / `hash` / `markup` / `plain`，决定高亮策略。
//! 语言名、关键字与扩展名会被泄漏为 `'static`，与内置语言共用同一套接口。

use std::path::Path;

use super::language::{CustomLanguage, CustomStyle};

/// 扫描目录并加载全部语言定义；解析失败的文件会被忽略。
pub fn load(dir: &Path) -> Vec<CustomLanguage> {
    let mut out = Vec::new();
    let path = dir.join("languages");
    let Ok(entries) = std::fs::read_dir(&path) else {
        return out;
    };
    let mut files: Vec<_> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_file()
                && path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .map(|ext| ext.eq_ignore_ascii_case("ini"))
                    .unwrap_or(false)
        })
        .collect();
    files.sort();
    for file in files {
        let Ok(text) = std::fs::read_to_string(&file) else {
            continue;
        };
        if let Some(language) = parse(&text) {
            out.push(language);
        }
    }
    out
}

fn parse(text: &str) -> Option<CustomLanguage> {
    let mut name = String::new();
    let mut extensions = Vec::new();
    let mut keywords = Vec::new();
    let mut types = Vec::new();
    let mut comment = String::from("//");
    let mut style = CustomStyle::CLike;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with(';') || line.starts_with('#') || line.starts_with('[')
        {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim().trim_matches('"').trim();
        match key.trim().to_ascii_lowercase().as_str() {
            "name" => name = value.to_string(),
            "extensions" | "extension" => {
                extensions = split_list(value)
                    .into_iter()
                    .map(|item| item.trim_start_matches('.').to_ascii_lowercase())
                    .filter(|item| !item.is_empty())
                    .collect();
            }
            "keywords" | "keyword" => keywords = split_list(value),
            "types" | "type" => types = split_list(value),
            "comment" | "line_comment" => {
                if !value.is_empty() {
                    comment = value.to_string();
                }
            }
            "style" => {
                style = match value.to_ascii_lowercase().as_str() {
                    "hash" | "script" => CustomStyle::Hash,
                    "markup" | "html" | "xml" => CustomStyle::Markup,
                    "plain" | "none" => CustomStyle::Plain,
                    _ => CustomStyle::CLike,
                };
            }
            _ => {}
        }
    }
    if name.is_empty() || extensions.is_empty() {
        return None;
    }
    Some(CustomLanguage {
        name: leak(name),
        extensions,
        keywords: leak_list(keywords),
        types: leak_list(types),
        comment: leak(comment),
        style,
    })
}

fn split_list(value: &str) -> Vec<String> {
    value
        .split([',', ' ', ';'])
        .map(|item| item.trim().to_string())
        .filter(|item| !item.is_empty())
        .collect()
}

fn leak(text: String) -> &'static str {
    Box::leak(text.into_boxed_str())
}

fn leak_list(items: Vec<String>) -> &'static [&'static str] {
    let leaked: Vec<&'static str> = items.into_iter().map(leak).collect();
    Box::leak(leaked.into_boxed_slice())
}

/// 加载用户代码片段：`<dir>/snippets.ini`，按小节定义。
///
/// ```ini
/// [我的 main 函数]
/// language = Rust
/// body = fn main() {\n    println!("hi");\n}
/// ```
pub fn load_snippets(dir: &Path) -> Vec<(String, String, String)> {
    let path = dir.join("snippets.ini");
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut name = String::new();
    let mut language = String::new();
    let mut body = String::new();
    let mut flush = |name: &mut String, language: &mut String, body: &mut String| {
        if !name.is_empty() && !language.is_empty() && !body.is_empty() {
            out.push((name.clone(), language.clone(), body.clone()));
        }
        name.clear();
        language.clear();
        body.clear();
    };
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            flush(&mut name, &mut language, &mut body);
            name = trimmed[1..trimmed.len() - 1].trim().to_string();
        } else if let Some((key, value)) = trimmed.split_once('=') {
            match key.trim().to_ascii_lowercase().as_str() {
                "language" | "lang" => language = value.trim().to_string(),
                "body" | "text" => body = unescape(value.trim()),
                _ => {}
            }
        }
    }
    flush(&mut name, &mut language, &mut body);
    out
}

/// 处理 `\n` `\t` `\r` 转义。
fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_definition() {
        let text = "name = Acme\n扩展名 = x\n";
        assert!(parse(text).is_none());
        let text = "name = Acme\nextensions = acme, .acm\nkeywords = let, fn\ntypes = Int\ncomment = //\nstyle = c_like\n";
        let language = parse(text).unwrap();
        assert_eq!(language.name, "Acme");
        assert_eq!(language.extensions, vec!["acme", "acm"]);
        assert_eq!(language.keywords, &["let", "fn"]);
        assert_eq!(language.comment, "//");
        assert_eq!(language.style, CustomStyle::CLike);
    }
}

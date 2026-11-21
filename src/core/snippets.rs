//! 代码片段：按语言提供常用骨架，插入时按当前缩进对齐。
//!
//! 用户可在 `%APPDATA%\Textm\snippets.ini` 中追加自定义片段（语言扩展点）。

use std::sync::{Mutex, OnceLock};

use super::language::Language;

#[derive(Clone, Copy)]
pub struct Snippet {
    pub name: &'static str,
    pub language: Language,
    pub body: &'static str,
}

static CUSTOM: OnceLock<Mutex<Vec<Snippet>>> = OnceLock::new();
static MARKET: OnceLock<Mutex<Vec<Snippet>>> = OnceLock::new();

fn custom_store() -> &'static Mutex<Vec<Snippet>> {
    CUSTOM.get_or_init(|| Mutex::new(Vec::new()))
}

fn market_store() -> &'static Mutex<Vec<Snippet>> {
    MARKET.get_or_init(|| Mutex::new(Vec::new()))
}

fn push_items(list: &mut Vec<Snippet>, items: Vec<(String, String, String)>) {
    for (name, language, body) in items {
        let Some(language) = Language::from_name(&language) else {
            continue;
        };
        if list
            .iter()
            .any(|snippet| snippet.name == name && snippet.language == language)
        {
            continue;
        }
        list.push(Snippet {
            name: Box::leak(name.into_boxed_str()),
            language,
            body: Box::leak(body.into_boxed_str()),
        });
    }
}

/// 注册用户片段：(名称, 语言名, 内容)；可多次调用（追加）。
pub fn register_custom(items: Vec<(String, String, String)>) {
    let mut list = match custom_store().lock() {
        Ok(guard) => guard,
        Err(e) => e.into_inner(),
    };
    push_items(&mut list, items);
}

/// 注册插件市场片段；关闭插件功能时可通过 [`clear_market`] 一次性移除。
pub fn register_market(items: Vec<(String, String, String)>) {
    let mut list = match market_store().lock() {
        Ok(guard) => guard,
        Err(e) => e.into_inner(),
    };
    push_items(&mut list, items);
}

pub fn clear_market() {
    let mut list = match market_store().lock() {
        Ok(guard) => guard,
        Err(e) => e.into_inner(),
    };
    list.clear();
}

fn snapshot(store: &'static OnceLock<Mutex<Vec<Snippet>>>) -> Vec<Snippet> {
    let list = match store.get_or_init(|| Mutex::new(Vec::new())).lock() {
        Ok(guard) => guard,
        Err(e) => e.into_inner(),
    };
    list.clone()
}

const SNIPPETS: &[Snippet] = &[
    Snippet {
        name: "main 函数",
        language: Language::Rust,
        body: "fn main() {\n    println!(\"Hello, world!\");\n}",
    },
    Snippet {
        name: "结构体 + impl",
        language: Language::Rust,
        body: "struct Point {\n    x: f64,\n    y: f64,\n}\n\nimpl Point {\n    fn new(x: f64, y: f64) -> Self {\n        Self { x, y }\n    }\n}",
    },
    Snippet {
        name: "测试函数",
        language: Language::Rust,
        body: "#[cfg(test)]\nmod tests {\n    use super::*;\n\n    #[test]\n    fn it_works() {\n        assert_eq!(2 + 2, 4);\n    }\n}",
    },
    Snippet {
        name: "for 循环",
        language: Language::Rust,
        body: "for item in items {\n    println!(\"{item:?}\");\n}",
    },
    Snippet {
        name: "match 表达式",
        language: Language::Rust,
        body: "match value {\n    Some(v) => {}\n    None => {}\n}",
    },
    Snippet {
        name: "if __name__",
        language: Language::Python,
        body: "if __name__ == \"__main__\":\n    main()",
    },
    Snippet {
        name: "类定义",
        language: Language::Python,
        body: "class MyClass:\n    def __init__(self):\n        pass\n\n    def method(self):\n        pass",
    },
    Snippet {
        name: "函数定义",
        language: Language::Python,
        body: "def function_name(arg):\n    \"\"\"说明。\"\"\"\n    return arg",
    },
    Snippet {
        name: "类定义",
        language: Language::JavaScript,
        body: "class MyClass {\n  constructor() {}\n\n  method() {}\n}",
    },
    Snippet {
        name: "箭头函数",
        language: Language::JavaScript,
        body: "const handler = (event) => {\n  console.log(event);\n};",
    },
    Snippet {
        name: "异步函数",
        language: Language::TypeScript,
        body: "async function load(): Promise<void> {\n  const response = await fetch(url);\n  const data = await response.json();\n}",
    },
    Snippet {
        name: "main 函数",
        language: Language::C,
        body: "int main(int argc, char **argv) {\n    return 0;\n}",
    },
    Snippet {
        name: "头文件保护",
        language: Language::C,
        body: "#ifndef HEADER_H\n#define HEADER_H\n\n\n\n#endif",
    },
    Snippet {
        name: "类定义",
        language: Language::Cpp,
        body: "class MyClass {\npublic:\n    MyClass() = default;\n    ~MyClass() = default;\n};",
    },
    Snippet {
        name: "main 函数",
        language: Language::Go,
        body: "func main() {\n\tfmt.Println(\"hello\")\n}",
    },
    Snippet {
        name: "结构体",
        language: Language::Go,
        body: "type Item struct {\n\tName string\n\tValue int\n}",
    },
    Snippet {
        name: "类定义",
        language: Language::Java,
        body: "public class Main {\n    public static void main(String[] args) {\n        System.out.println(\"hello\");\n    }\n}",
    },
    Snippet {
        name: "HTML5 骨架",
        language: Language::Html,
        body: "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n  <meta charset=\"utf-8\">\n  <title>标题</title>\n</head>\n<body>\n\n</body>\n</html>",
    },
    Snippet {
        name: "表格",
        language: Language::Markdown,
        body: "| 列1 | 列2 |\n| --- | --- |\n| 值1 | 值2 |",
    },
];

/// 某语言可用的片段（纯文本语言返回通用片段）。
pub fn list(language: Language) -> Vec<Snippet> {
    let mut out: Vec<Snippet> = SNIPPETS
        .iter()
        .copied()
        .filter(|s| s.language == language)
        .collect();
    out.extend(
        snapshot(&CUSTOM)
            .into_iter()
            .filter(|s| s.language == language),
    );
    out.extend(
        snapshot(&MARKET)
            .into_iter()
            .filter(|s| s.language == language),
    );
    out
}

/// 通用片段（任何语言都可插入）。
pub fn general() -> Vec<Snippet> {
    let mut out: Vec<Snippet> = SNIPPETS
        .iter()
        .copied()
        .filter(|s| matches!(s.language, Language::Plain | Language::Markdown))
        .collect();
    out.extend(
        snapshot(&CUSTOM)
            .into_iter()
            .filter(|s| matches!(s.language, Language::Plain | Language::Markdown)),
    );
    out.extend(
        snapshot(&MARKET)
            .into_iter()
            .filter(|s| matches!(s.language, Language::Plain | Language::Markdown)),
    );
    out
}

/// 插入文本时把除首行外的每一行加上当前缩进。
pub fn indented(body: &str, indent: &str) -> String {
    body.split('\n')
        .enumerate()
        .map(|(index, line)| {
            if index == 0 || line.is_empty() {
                line.to_string()
            } else {
                format!("{indent}{line}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rust_snippets_available() {
        let list = list(Language::Rust);
        assert!(!list.is_empty());
        assert!(list.iter().any(|s| s.name.contains("main")));
    }

    #[test]
    fn indentation_applies_to_following_lines() {
        let text = indented("a\nb\n\nc", "    ");
        assert_eq!(text, "a\n    b\n\n    c");
    }
}

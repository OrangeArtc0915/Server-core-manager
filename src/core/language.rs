//! 语言识别与关键字表。

use std::path::Path;
use std::sync::OnceLock;

/// 自定义语言的注释与高亮风格。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CustomStyle {
    CLike,
    Hash,
    Markup,
    Plain,
}

/// 由配置文件定义的语言（语言扩展点）。
pub struct CustomLanguage {
    pub name: &'static str,
    pub extensions: Vec<String>,
    pub keywords: &'static [&'static str],
    pub types: &'static [&'static str],
    pub comment: &'static str,
    pub style: CustomStyle,
}

static CUSTOM: OnceLock<Vec<CustomLanguage>> = OnceLock::new();

/// 注册自定义语言；只在启动时调用一次。
pub fn register_custom_languages(list: Vec<CustomLanguage>) {
    let _ = CUSTOM.set(list);
}

pub fn custom_language(index: usize) -> Option<&'static CustomLanguage> {
    CUSTOM.get()?.get(index)
}

pub fn custom_count() -> usize {
    CUSTOM.get().map(|list| list.len()).unwrap_or(0)
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub enum Language {
    #[default]
    Plain,
    Rust,
    C,
    Cpp,
    CSharp,
    Java,
    Go,
    Python,
    JavaScript,
    TypeScript,
    Json,
    Html,
    Xml,
    Css,
    Markdown,
    Sql,
    Yaml,
    Toml,
    Ini,
    PowerShell,
    Batch,
    Shell,
    Lua,
    Php,
    Makefile,
    Diff,
    /// 配置目录加载的自定义语言，索引见 `language_ext::load`。
    Custom(u16),
}

impl Language {
    pub fn label(self) -> &'static str {
        match self {
            Language::Plain => "纯文本",
            Language::Rust => "Rust",
            Language::C => "C",
            Language::Cpp => "C++",
            Language::CSharp => "C#",
            Language::Java => "Java",
            Language::Go => "Go",
            Language::Python => "Python",
            Language::JavaScript => "JavaScript",
            Language::TypeScript => "TypeScript",
            Language::Json => "JSON",
            Language::Html => "HTML",
            Language::Xml => "XML",
            Language::Css => "CSS",
            Language::Markdown => "Markdown",
            Language::Sql => "SQL",
            Language::Yaml => "YAML",
            Language::Toml => "TOML",
            Language::Ini => "INI",
            Language::PowerShell => "PowerShell",
            Language::Batch => "Batch",
            Language::Shell => "Shell",
            Language::Lua => "Lua",
            Language::Php => "PHP",
            Language::Makefile => "Makefile",
            Language::Diff => "Diff",
            Language::Custom(index) => custom_language(index as usize)
                .map(|language| language.name)
                .unwrap_or("自定义语言"),
        }
    }

    pub fn all() -> &'static [Language] {
        use Language::*;
        &[
            Plain, Rust, C, Cpp, CSharp, Java, Go, Python, JavaScript, TypeScript, Json, Html,
            Xml, Css, Markdown, Sql, Yaml, Toml, Ini, PowerShell, Batch, Shell, Lua, Php,
            Makefile, Diff,
        ]
    }

    /// 全部语言（内置 + 自定义），用于语言选择列表。
    pub fn all_with_custom() -> Vec<Language> {
        let mut list = Language::all().to_vec();
        for index in 0..custom_count() {
            list.push(Language::Custom(index as u16));
        }
        list
    }

    pub fn from_name(text: &str) -> Option<Language> {
        let text = text.trim().to_ascii_lowercase();
        if let Some(language) = Language::all()
            .iter()
            .copied()
            .find(|l| l.label().to_ascii_lowercase() == text || format!("{:?}", l).to_ascii_lowercase() == text)
        {
            return Some(language);
        }
        (0..custom_count())
            .map(|index| Language::Custom(index as u16))
            .find(|language| language.label().to_ascii_lowercase() == text)
    }

    /// 按扩展名 / 文件名识别语言。
    pub fn from_path(path: &Path) -> Language {
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if matches!(
            name.as_str(),
            "makefile" | "gnumakefile" | "cmakelists.txt" | "cargo.toml"
        ) {
            return if name == "cargo.toml" {
                Language::Toml
            } else {
                Language::Makefile
            };
        }
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        Self::from_extension(&ext)
    }

    pub fn from_extension(ext: &str) -> Language {
        let ext = ext.to_ascii_lowercase();
        for index in 0..custom_count() {
            if let Some(language) = custom_language(index) {
                if language.extensions.iter().any(|item| *item == ext) {
                    return Language::Custom(index as u16);
                }
            }
        }
        match ext.as_str() {
            "rs" => Language::Rust,
            "c" | "h" => Language::C,
            "cc" | "cpp" | "cxx" | "hpp" | "hh" | "hxx" => Language::Cpp,
            "cs" => Language::CSharp,
            "java" => Language::Java,
            "go" => Language::Go,
            "py" | "pyw" => Language::Python,
            "js" | "mjs" | "cjs" | "jsx" => Language::JavaScript,
            "ts" | "tsx" | "mts" => Language::TypeScript,
            "json" | "jsonc" => Language::Json,
            "html" | "htm" | "xhtml" => Language::Html,
            "xml" | "xsd" | "svg" | "plist" => Language::Xml,
            "css" | "scss" | "less" => Language::Css,
            "md" | "markdown" | "mdx" => Language::Markdown,
            "sql" => Language::Sql,
            "yml" | "yaml" => Language::Yaml,
            "toml" => Language::Toml,
            "ini" | "conf" | "cfg" | "properties" | "gitconfig" => Language::Ini,
            "ps1" | "psm1" | "psd1" => Language::PowerShell,
            "bat" | "cmd" => Language::Batch,
            "sh" | "bash" | "zsh" | "fish" => Language::Shell,
            "lua" => Language::Lua,
            "php" => Language::Php,
            "mk" => Language::Makefile,
            "diff" | "patch" => Language::Diff,
            _ => Language::Plain,
        }
    }

    pub fn keywords(self) -> &'static [&'static str] {
        match self {
            Language::Custom(index) => custom_language(index as usize)
                .map(|language| language.keywords)
                .unwrap_or(&[]),
            Language::Rust => &[
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match",
                "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
                "super", "trait", "true", "type", "unsafe", "use", "where", "while", "union",
                "macro_rules", "macro", "become", "box", "do", "final", "override", "priv", "try",
                "typeof", "unsized", "virtual", "yield",
            ],
            Language::C => &[
                "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
                "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
                "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
                "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "_Bool",
                "_Static_assert", "_Thread_local",
            ],
            Language::Cpp => &[
                "alignas", "alignof", "and", "asm", "auto", "bool", "break", "case", "catch",
                "char", "class", "concept", "const", "consteval", "constexpr", "constinit",
                "const_cast", "continue", "co_await", "co_return", "co_yield", "decltype",
                "default", "delete", "do", "double", "dynamic_cast", "else", "enum", "explicit",
                "export", "extern", "false", "float", "for", "friend", "goto", "if", "inline",
                "int", "long", "mutable", "namespace", "new", "noexcept", "not", "nullptr",
                "operator", "or", "private", "protected", "public", "reinterpret_cast", "requires",
                "return", "short", "signed", "sizeof", "static", "static_assert", "static_cast",
                "struct", "switch", "template", "this", "throw", "true", "try", "typedef",
                "typeid", "typename", "union", "unsigned", "using", "virtual", "void", "volatile",
                "while", "xor",
            ],
            Language::CSharp => &[
                "abstract", "as", "async", "await", "base", "bool", "break", "byte", "case",
                "catch", "char", "class", "const", "continue", "decimal", "default", "delegate",
                "do", "double", "else", "enum", "event", "explicit", "extern", "false", "finally",
                "fixed", "float", "for", "foreach", "goto", "if", "implicit", "in", "int",
                "interface", "internal", "is", "lock", "long", "namespace", "new", "null",
                "object", "operator", "out", "override", "params", "private", "protected",
                "public", "readonly", "record", "ref", "return", "sbyte", "sealed", "short",
                "sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw",
                "true", "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort",
                "using", "var", "virtual", "void", "volatile", "while", "yield",
            ],
            Language::Java => &[
                "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
                "const", "continue", "default", "do", "double", "else", "enum", "extends",
                "final", "finally", "float", "for", "goto", "if", "implements", "import",
                "instanceof", "int", "interface", "long", "native", "new", "package", "private",
                "protected", "public", "record", "return", "sealed", "short", "static", "strictfp",
                "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try",
                "var", "void", "volatile", "while", "true", "false", "null",
            ],
            Language::Go => &[
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var",
                "nil", "true", "false", "iota",
            ],
            Language::Python => &[
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                "raise", "return", "True", "try", "while", "with", "yield", "match", "case",
            ],
            Language::JavaScript | Language::TypeScript => &[
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends", "false",
                "finally", "for", "function", "get", "if", "import", "in", "instanceof", "let",
                "new", "null", "of", "return", "set", "static", "super", "switch", "this",
                "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with",
                "yield", "interface", "type", "enum", "implements", "namespace", "declare",
                "readonly", "private", "protected", "public", "abstract", "as", "satisfies",
            ],
            Language::Html | Language::Xml => &[],
            Language::Css => &[
                "important", "media", "supports", "keyframes", "font-face", "import", "charset",
                "inherit", "initial", "unset", "auto", "none", "flex", "grid", "block", "inline",
            ],
            Language::Sql => &[
                "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                "create", "table", "alter", "drop", "index", "view", "join", "inner", "left",
                "right", "full", "outer", "on", "group", "by", "order", "having", "limit",
                "offset", "union", "all", "distinct", "as", "and", "or", "not", "null", "is",
                "in", "exists", "between", "like", "case", "when", "then", "else", "end",
                "primary", "key", "foreign", "references", "default", "unique", "check",
                "begin", "commit", "rollback", "transaction", "if", "with", "recursive",
            ],
            Language::Yaml => &["true", "false", "null", "yes", "no", "on", "off"],
            Language::Toml => &["true", "false"],
            Language::Ini => &["true", "false", "yes", "no", "on", "off"],
            Language::PowerShell => &[
                "begin", "break", "catch", "class", "continue", "data", "do", "dynamicparam",
                "else", "elseif", "end", "enum", "exit", "filter", "finally", "for", "foreach",
                "from", "function", "hidden", "if", "in", "param", "process", "return", "static",
                "switch", "throw", "trap", "try", "until", "using", "var", "while", "workflow",
                "true", "false", "null",
            ],
            Language::Batch => &[
                "echo", "set", "if", "else", "for", "goto", "call", "exit", "rem", "shift",
                "start", "dir", "cd", "copy", "move", "del", "type", "pause", "choice",
            ],
            Language::Shell => &[
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                "case", "esac", "function", "in", "select", "time", "local", "export", "return",
                "break", "continue", "true", "false",
            ],
            Language::Lua => &[
                "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto",
                "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true",
                "until", "while",
            ],
            Language::Php => &[
                "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
                "clone", "const", "continue", "declare", "default", "do", "echo", "else",
                "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch",
                "endwhile", "eval", "exit", "extends", "final", "finally", "fn", "for",
                "foreach", "function", "global", "goto", "if", "implements", "include",
                "include_once", "instanceof", "insteadof", "interface", "isset", "list",
                "match", "namespace", "new", "or", "print", "private", "protected", "public",
                "readonly", "require", "require_once", "return", "static", "switch", "throw",
                "trait", "try", "unset", "use", "var", "while", "xor", "yield", "true", "false",
                "null",
            ],
            Language::Makefile => &[
                "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define",
                "endef", "export", "unexport", "override", "vpath",
            ],
            Language::Diff | Language::Markdown | Language::Json => &[],
            Language::Plain => &[],
        }
    }

    /// 类型 / 内置名（用于着色）。
    pub fn types(self) -> &'static [&'static str] {
        match self {
            Language::Custom(index) => custom_language(index as usize)
                .map(|language| language.types)
                .unwrap_or(&[]),
            Language::Rust => &[
                "bool", "char", "str", "String", "i8", "i16", "i32", "i64", "i128", "isize",
                "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "Option", "Result",
                "Vec", "Box", "Rc", "Arc", "Cell", "RefCell", "HashMap", "HashSet", "BTreeMap",
                "String", "Cow", "Path", "PathBuf", "Mutex", "RwLock", "Some", "None", "Ok",
                "Err",
            ],
            Language::C => &[
                "size_t", "ssize_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t",
                "uint16_t", "uint32_t", "uint64_t", "FILE", "NULL", "bool",
            ],
            Language::Cpp => &[
                "std", "string", "vector", "map", "set", "unordered_map", "unique_ptr",
                "shared_ptr", "size_t", "int8_t", "int32_t", "int64_t", "uint8_t", "uint32_t",
                "uint64_t", "NULL", "nullptr_t",
            ],
            Language::CSharp => &[
                "bool", "byte", "char", "decimal", "double", "float", "int", "long", "object",
                "sbyte", "short", "string", "uint", "ulong", "ushort", "void", "List", "Dictionary",
                "Task", "Span", "DateTime", "Guid",
            ],
            Language::Java => &[
                "boolean", "byte", "char", "double", "float", "int", "long", "short", "void",
                "String", "Object", "List", "Map", "Set", "Integer", "Long", "Double", "Boolean",
                "System", "Exception", "RuntimeException",
            ],
            Language::Go => &[
                "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int",
                "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
                "uint32", "uint64", "uintptr", "any",
            ],
            Language::Python => &[
                "int", "float", "complex", "bool", "str", "bytes", "list", "tuple", "dict", "set",
                "frozenset", "object", "super", "self", "cls", "Exception", "ValueError",
                "TypeError", "print", "len", "range", "enumerate", "zip", "open", "isinstance",
            ],
            Language::JavaScript | Language::TypeScript => &[
                "Array", "Boolean", "Date", "Error", "Function", "JSON", "Map", "Math", "Number",
                "Object", "Promise", "RegExp", "Set", "String", "Symbol", "WeakMap", "WeakSet",
                "console", "window", "document", "globalThis", "bigint", "number", "string",
                "boolean", "unknown", "any", "never", "void",
            ],
            Language::Css => &[
                "px", "em", "rem", "vh", "vw", "pt", "deg", "ms", "s", "rgba", "rgb", "hsl",
                "calc", "var", "url", "linear-gradient", "radial-gradient",
            ],
            Language::Sql => &[
                "int", "integer", "bigint", "smallint", "decimal", "numeric", "float", "real",
                "char", "varchar", "text", "blob", "date", "time", "timestamp", "boolean",
                "serial", "uuid", "json", "jsonb", "count", "sum", "avg", "min", "max", "coalesce",
            ],
            _ => &[],
        }
    }

    /// 自定义语言的高亮风格；内置语言返回 None。
    pub fn custom_style(self) -> Option<CustomStyle> {
        match self {
            Language::Custom(index) => custom_language(index as usize).map(|language| language.style),
            _ => None,
        }
    }

    /// 自定义语言的单行注释前缀。
    pub fn custom_comment(self) -> Option<&'static str> {
        match self {
            Language::Custom(index) => custom_language(index as usize).map(|language| language.comment),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_by_extension() {
        assert_eq!(Language::from_path(Path::new("a.rs")), Language::Rust);
        assert_eq!(Language::from_path(Path::new("Makefile")), Language::Makefile);
        assert_eq!(Language::from_path(Path::new("a.md")), Language::Markdown);
        assert_eq!(Language::from_path(Path::new("noext")), Language::Plain);
    }

    #[test]
    fn name_roundtrip() {
        assert_eq!(Language::from_name("Rust"), Some(Language::Rust));
        assert_eq!(Language::from_name("json"), Some(Language::Json));
    }
}

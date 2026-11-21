//! Textm 自有插件系统：清单 `textm.json` + 可选 `index.js` 脚本。
//!
//! 目录约定：
//!   `%APPDATA%\Textm\plugins\<名称>\textm.json`
//!   `<工作区根>\.textm\plugins\<名称>\textm.json`
//!
//! 清单示例：
//! ```json
//! {
//!   "name": "demo",
//!   "version": "1.0.0",
//!   "description": "示例插件",
//!   "main": "index.js",
//!   "activation": ["startup"],
//!   "commands": [
//!     { "id": "demo.echo", "title": "回声", "program": "cmd", "args": ["/C", "echo hi"] },
//!     { "id": "demo.hello", "title": "打招呼" }
//!   ],
//!   "themes": ["themes/dark.json"],
//!   "snippets": ["snippets/rust.json"]
//! }
//! ```

use std::path::{Path, PathBuf};

use crate::core::snippets;
use crate::lsp::json::{self, Json};
use crate::render::Color;
use crate::task::Task;
use crate::ui::theme::{self, Syntax, Theme};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PluginCommand {
    pub id: String,
    pub title: String,
    /// 声明式命令：外部程序；为空表示由 index.js 注册。
    pub program: Option<String>,
    pub args: Vec<String>,
    pub cwd: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Extension {
    pub name: String,
    pub version: String,
    pub description: String,
    pub dir: PathBuf,
    pub source: String,
    pub commands: Vec<PluginCommand>,
    pub main: Option<PathBuf>,
    pub activation: Vec<String>,
    pub themes: Vec<String>,
    pub snippets: Vec<String>,
    pub enabled: bool,
}

impl Extension {
    pub fn display(&self) -> String {
        if self.description.is_empty() {
            self.name.clone()
        } else {
            format!("{} · {}", self.name, self.description)
        }
    }

    pub fn script_commands(&self) -> Vec<&PluginCommand> {
        self.commands
            .iter()
            .filter(|command| command.program.is_none())
            .collect()
    }

    /// 声明式命令转换为任务运行器任务。
    pub fn task(&self, command: &PluginCommand, workspace: &Path) -> Task {
        let cwd = command.cwd.as_ref().map(|raw| {
            let text = raw
                .replace("${pluginDir}", &self.dir.to_string_lossy())
                .replace("${workspaceFolder}", &workspace.to_string_lossy());
            let path = PathBuf::from(text);
            if path.is_absolute() {
                path
            } else {
                self.dir.join(path)
            }
        });
        Task {
            label: format!("{}：{}", self.name, command.title),
            command: command.program.clone().unwrap_or_default(),
            args: command.args.clone(),
            cwd: cwd.or_else(|| Some(self.dir.clone())),
            group: false,
        }
    }
}

/// 插件根目录：用户目录 + 每个工作区根目录。
pub fn search_dirs(user_dir: &Path, workspace_roots: &[PathBuf]) -> Vec<(PathBuf, String)> {
    let mut dirs = vec![(user_dir.join("plugins"), "用户".to_string())];
    for root in workspace_roots {
        dirs.push((
            root.join(".textm").join("plugins"),
            format!("工作区 {}", root.display()),
        ));
    }
    dirs
}

pub fn load(user_dir: &Path, workspace_roots: &[PathBuf], disabled: &[String]) -> Vec<Extension> {
    let mut out = Vec::new();
    for (dir, source) in search_dirs(user_dir, workspace_roots) {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        let mut children: Vec<PathBuf> = entries
            .filter_map(|entry| entry.ok().map(|e| e.path()))
            .filter(|path| path.is_dir())
            .collect();
        children.sort();
        for child in children {
            let manifest = child.join("textm.json");
            let Ok(text) = std::fs::read_to_string(&manifest) else {
                continue;
            };
            if let Some(mut ext) = parse_manifest(&text, &child, &source) {
                ext.enabled = !disabled.iter().any(|name| name == &ext.name);
                out.push(ext);
            }
        }
    }
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out
}

pub fn parse_manifest(text: &str, dir: &Path, source: &str) -> Option<Extension> {
    let value = json::parse(text).ok()?;
    let name = value
        .get("name")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| dir.file_name().map(|n| n.to_string_lossy().to_string()))?;
    let version = value
        .get("version")
        .and_then(|v| v.as_str())
        .unwrap_or("0.0.0")
        .to_string();
    let description = value
        .get("description")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let main = value
        .get("main")
        .and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty())
        .and_then(|s| safe_relative(s))
        .map(|relative| dir.join(relative));
    let activation = value
        .get("activation")
        .and_then(|v| v.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|item| item.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();
    let mut commands = Vec::new();
    if let Some(list) = value.get("commands").and_then(|v| v.as_array()) {
        for item in list {
            let title = item
                .get("title")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            let id = item
                .get("id")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| slug(&title));
            if id.is_empty() || title.is_empty() {
                continue;
            }
            let program = item
                .get("program")
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            let args = item
                .get("args")
                .and_then(|v| v.as_array())
                .map(|args| {
                    args.iter()
                        .filter_map(|arg| arg.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default();
            let cwd = item
                .get("cwd")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            commands.push(PluginCommand {
                id,
                title,
                program,
                args,
                cwd,
            });
        }
    }
    let themes = string_list(value.get("themes"));
    let snippets = string_list(value.get("snippets"));
    Some(Extension {
        name,
        version,
        description,
        dir: dir.to_path_buf(),
        source: source.to_string(),
        commands,
        main,
        activation,
        themes,
        snippets,
        enabled: true,
    })
}

fn string_list(value: Option<&Json>) -> Vec<String> {
    value
        .and_then(|v| v.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|item| item.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

fn slug(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

fn safe_relative(relative: &str) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for part in relative.split(['/', '\\']) {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." || part.contains(':') {
            return None;
        }
        out.push(part);
    }
    if out.as_os_str().is_empty() {
        None
    } else {
        Some(out)
    }
}

// ---------------------------------------------------------------- 声明式贡献

/// 加载所有启用插件的主题与代码片段。
pub fn load_contributions(extensions: &[Extension]) -> (Vec<Theme>, Vec<(String, String, String)>) {
    let mut themes = Vec::new();
    let mut snippets_out = Vec::new();
    for ext in extensions {
        if !ext.enabled {
            continue;
        }
        for relative in &ext.themes {
            let Some(safe) = safe_relative(relative) else {
                continue;
            };
            let Ok(text) = std::fs::read_to_string(ext.dir.join(&safe)) else {
                continue;
            };
            let Ok(value) = json::parse(&text) else {
                continue;
            };
            let fallback = format!(
                "{} · {}",
                ext.name,
                safe.file_stem()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| "主题".into())
            );
            if let Some(theme) = theme_from_json(&value, &fallback) {
                themes.push(theme);
            }
        }
        for relative in &ext.snippets {
            let Some(safe) = safe_relative(relative) else {
                continue;
            };
            let Ok(text) = std::fs::read_to_string(ext.dir.join(&safe)) else {
                continue;
            };
            let Ok(value) = json::parse(&text) else {
                continue;
            };
            snippets_out.extend(snippets_from_json(&value));
        }
    }
    (themes, snippets_out)
}

/// 注册插件贡献（主题与片段）；已注册的主题名会通过 `plugin_theme_names` 记录。
pub fn register_contributions(
    extensions: &[Extension],
) -> (Vec<String>, usize) {
    let (themes, snippets) = load_contributions(extensions);
    let mut names = Vec::new();
    for theme in themes {
        names.push(theme.name.to_string());
        theme::register(theme);
    }
    let count = snippets.len();
    if count > 0 {
        snippets::register_market(snippets);
    }
    (names, count)
}

/// Textm 自有主题格式：
/// `{ "name": "...", "dark": true, "bg": "#1e1e1e", "fg": "#d4d4d4",
///    "syntax": { "keyword": "#569cd6", ... }, "colors": {...} }`
pub fn theme_from_json(value: &Json, fallback_name: &str) -> Option<Theme> {
    let colors = value.get("colors");
    let read = |key: &str| -> Option<Color> {
        value
            .get(key)
            .and_then(|v| v.as_str())
            .or_else(|| colors.and_then(|c| c.get(key)).and_then(|v| v.as_str()))
            .and_then(parse_color)
    };
    let bg = read("bg")?;
    let fg = read("fg").unwrap_or_else(|| {
        if luminance(bg) < 128.0 {
            Color::rgb(212, 212, 212)
        } else {
            Color::rgb(30, 30, 30)
        }
    });
    let dark = value
        .get("dark")
        .and_then(|v| v.as_bool())
        .unwrap_or_else(|| luminance(bg) < 128.0);
    let name = value
        .get("name")
        .and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(fallback_name)
        .to_string();
    let panel = read("panel").unwrap_or_else(|| bg.blend(fg, 8));
    let accent = read("accent").unwrap_or(Color::rgb(0, 122, 204));
    let selection = read("selection").unwrap_or_else(|| accent.blend(bg, 120));
    let syntax_value = value.get("syntax");
    let token = |key: &str, fallback: Color| -> Color {
        syntax_value
            .and_then(|s| s.get(key))
            .and_then(|v| v.as_str())
            .and_then(parse_color)
            .unwrap_or(fallback)
    };
    Some(Theme {
        name: Box::leak(name.into_boxed_str()),
        dark,
        bg,
        fg,
        panel_bg: panel,
        panel_fg: fg,
        activity_bg: read("activity").unwrap_or(panel),
        activity_fg: read("activity_fg").unwrap_or(fg),
        tab_active_bg: read("tab_active").unwrap_or(bg),
        tab_inactive_bg: read("tab_inactive").unwrap_or(panel),
        border: read("border").unwrap_or_else(|| panel.blend(fg, 40)),
        accent,
        selection,
        cursor: read("cursor").unwrap_or(fg),
        current_line: read("current_line").unwrap_or_else(|| bg.blend(fg, 12)),
        gutter_fg: read("gutter").unwrap_or_else(|| fg.blend(bg, 110)),
        status_bg: read("status").unwrap_or(accent),
        status_fg: read("status_fg").unwrap_or(Color::rgb(255, 255, 255)),
        minimap_bg: read("minimap").unwrap_or(bg),
        added: read("added").unwrap_or(Color::rgb(88, 166, 88)),
        removed: read("removed").unwrap_or(Color::rgb(220, 90, 90)),
        find_bg: read("find").unwrap_or(selection),
        syntax: Syntax {
            keyword: token("keyword", Color::rgb(86, 156, 214)),
            type_: token("type", Color::rgb(78, 201, 176)),
            string: token("string", Color::rgb(206, 145, 120)),
            number: token("number", Color::rgb(181, 206, 168)),
            comment: token("comment", Color::rgb(106, 153, 85)),
            function: token("function", Color::rgb(220, 220, 170)),
            operator: token("operator", fg),
            property: token("property", Color::rgb(156, 220, 254)),
            tag: token("tag", Color::rgb(86, 156, 214)),
            attribute: token("attribute", Color::rgb(156, 220, 254)),
            heading: token("heading", Color::rgb(86, 156, 214)),
            link: token("link", Color::rgb(79, 193, 255)),
            constant: token("constant", Color::rgb(79, 193, 255)),
            variable: token("variable", Color::rgb(156, 220, 254)),
            macro_: token("macro", Color::rgb(197, 134, 192)),
        },
    })
}

/// Textm 自有片段格式：
/// `{ "名称": { "language": "Rust", "body": "..." } }` 或数组。
pub fn snippets_from_json(value: &Json) -> Vec<(String, String, String)> {
    let mut out = Vec::new();
    match value {
        Json::Object(map) => {
            for (name, item) in map {
                let language = item
                    .get("language")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Plain")
                    .to_string();
                let body = item
                    .get("body")
                    .map(|v| match v {
                        Json::String(text) => text.clone(),
                        Json::Array(lines) => lines
                            .iter()
                            .filter_map(|line| line.as_str())
                            .collect::<Vec<_>>()
                            .join("\n"),
                        _ => String::new(),
                    })
                    .unwrap_or_default();
                if !body.is_empty() {
                    out.push((name.clone(), language, body));
                }
            }
        }
        Json::Array(list) => {
            for item in list {
                let Some(name) = item.get("name").and_then(|v| v.as_str()) else {
                    continue;
                };
                let language = item
                    .get("language")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Plain")
                    .to_string();
                let body = item
                    .get("body")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                if !body.is_empty() {
                    out.push((name.to_string(), language, body));
                }
            }
        }
        _ => {}
    }
    out
}

fn parse_color(text: &str) -> Option<Color> {
    let text = text.trim().trim_start_matches('#');
    match text.len() {
        3 => {
            let chars: Vec<char> = text.chars().collect();
            let expand = |c: char| -> Option<u8> { c.to_digit(16).map(|v| (v * 17) as u8) };
            Some(Color::rgb(
                expand(chars[0])?,
                expand(chars[1])?,
                expand(chars[2])?,
            ))
        }
        6 | 8 => Some(Color::rgb(
            u8::from_str_radix(&text[0..2], 16).ok()?,
            u8::from_str_radix(&text[2..4], 16).ok()?,
            u8::from_str_radix(&text[4..6], 16).ok()?,
        )),
        _ => None,
    }
}

fn luminance(color: Color) -> f32 {
    0.299 * color.r as f32 + 0.587 * color.g as f32 + 0.114 * color.b as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_manifest_with_script_and_declarative_commands() {
        let text = r#"{
            "name": "demo",
            "version": "1.2.3",
            "description": "示例",
            "main": "index.js",
            "activation": ["startup"],
            "commands": [
                {"id": "demo.echo", "title": "回声", "program": "cmd", "args": ["/C", "echo hi"]},
                {"id": "demo.hello", "title": "打招呼"}
            ],
            "themes": ["themes/dark.json"]
        }"#;
        let ext = parse_manifest(text, Path::new("C:/plugins/demo"), "用户").unwrap();
        assert_eq!(ext.name, "demo");
        assert_eq!(ext.commands.len(), 2);
        assert!(ext.commands[0].program.is_some());
        assert!(ext.commands[1].program.is_none());
        assert_eq!(ext.script_commands().len(), 1);
        assert_eq!(ext.main.as_deref(), Some(Path::new("C:/plugins/demo/index.js")));
        let task = ext.task(&ext.commands[0], Path::new("C:/work"));
        assert_eq!(task.command_line(), "cmd /C \"echo hi\"");
    }

    #[test]
    fn theme_and_snippets_convert() {
        let text = r##"{
            "name": "My Theme",
            "dark": true,
            "bg": "#101010",
            "fg": "#e0e0e0",
            "syntax": {"keyword": "#569cd6", "string": "#ce9178"}
        }"##;
        let value = json::parse(text).unwrap();
        let theme = theme_from_json(&value, "fallback").unwrap();
        assert_eq!(theme.name, "My Theme");
        assert_eq!(theme.bg, Color::rgb(16, 16, 16));
        assert_eq!(theme.syntax.keyword, Color::rgb(86, 156, 214));
        let snippets_text = r#"{"Hello": {"language": "Rust", "body": "fn main() {}"}}"#;
        let value = json::parse(snippets_text).unwrap();
        let items = snippets_from_json(&value);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].0, "Hello");
    }
}

//! Textm 自有插件宿主：Boa JS 引擎 + `textm` API（textm.js）。
//!
//! 插件 = `textm.json` 清单 + 可选 `index.js`。清单里的 `program` 命令由任务运行器执行，
//! JS 命令通过 `textm.commands.register` 注册；需要访问编辑器 / 文件系统的调用
//! 统一以请求队列交给 UI 线程处理。

use std::cell::RefCell;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

use boa_engine::object::ObjectInitializer;
use boa_engine::property::Attribute;
use boa_engine::{Context, JsResult, JsString, JsValue, NativeFunction, Source};

use crate::extension::Extension;
use crate::lsp::json::{self, Json};
use crate::platform::clipboard;

const SHIM: &str = include_str!("textm.js");

#[derive(Clone, Default)]
pub struct HostContext {
    pub workspace: PathBuf,
    pub roots: Vec<PathBuf>,
    pub active_path: Option<PathBuf>,
    pub active_text: String,
    pub active_language: String,
    pub active_line: usize,
    pub active_character: usize,
    pub active_version: u64,
    pub eol: u8,
    pub sel_start_line: usize,
    pub sel_start_character: usize,
    pub sel_end_line: usize,
    pub sel_end_character: usize,
}

#[derive(Clone, Debug)]
pub struct PluginProblem {
    pub path: PathBuf,
    pub message: String,
    pub severity: u8,
    pub line: usize,
    pub character: usize,
    pub source: String,
}

#[derive(Clone, Debug)]
pub struct PluginEdit {
    pub start_line: usize,
    pub start_char: usize,
    pub end_line: usize,
    pub end_char: usize,
    pub new_text: String,
}

#[derive(Clone, Debug)]
pub enum Request {
    Message {
        level: u8,
        text: String,
    },
    Output(String),
    Status(String),
    Problems {
        path: Option<PathBuf>,
        items: Vec<PluginProblem>,
    },
    QuickPick {
        id: i64,
        items: Vec<(String, String, String)>,
        placeholder: String,
    },
    InputBox {
        id: i64,
        prompt: String,
        value: String,
    },
    ApplyEdits {
        path: PathBuf,
        edits: Vec<PluginEdit>,
    },
    OpenDocument(PathBuf),
    ShowDocument {
        path: PathBuf,
        line: usize,
        column: usize,
    },
    SaveDocument(PathBuf),
    Terminal(String),
    Panel {
        title: String,
        text: String,
    },
    CommandRegistered(String),
    Log(String),
}

struct Shared {
    context: HostContext,
    requests: Vec<Request>,
    next_id: i64,
}

thread_local! {
    static SHARED: RefCell<Shared> = RefCell::new(Shared {
        context: HostContext::default(),
        requests: Vec::new(),
        next_id: 1,
    });
}

fn with_shared<R>(f: impl FnOnce(&mut Shared) -> R) -> R {
    SHARED.with(|cell| f(&mut cell.borrow_mut()))
}

fn push_request(request: Request) {
    with_shared(|shared| shared.requests.push(request));
}

fn arg_string(args: &[JsValue], index: usize, context: &mut Context) -> String {
    args.get(index)
        .and_then(|value| value.to_string(context).ok())
        .map(|text| text.to_std_string_escaped())
        .unwrap_or_default()
}

fn arg_number(args: &[JsValue], index: usize) -> f64 {
    args.get(index)
        .and_then(|value| value.as_number())
        .unwrap_or(0.0)
}

fn js_string(text: impl AsRef<str>) -> JsValue {
    JsValue::from(JsString::from(text.as_ref()))
}

// ---------------------------------------------------------------- 原生函数

fn native_message(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let level = arg_number(args, 0) as u8;
    let text = arg_string(args, 1, context);
    push_request(Request::Message { level, text });
    Ok(JsValue::undefined())
}

fn native_output(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let text = arg_string(args, 0, context);
    push_request(Request::Output(text));
    Ok(JsValue::undefined())
}

fn native_status(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let text = arg_string(args, 0, context);
    push_request(Request::Status(text));
    Ok(JsValue::undefined())
}

fn native_log(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let text = arg_string(args, 0, context);
    push_request(Request::Log(text));
    Ok(JsValue::undefined())
}

fn native_next_id(_this: &JsValue, _args: &[JsValue], _context: &mut Context) -> JsResult<JsValue> {
    let id = with_shared(|shared| {
        let id = shared.next_id;
        shared.next_id += 1;
        id
    });
    Ok(JsValue::from(id as f64))
}

fn native_quick_pick(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let id = arg_number(args, 0) as i64;
    let items = parse_quick_items(&arg_string(args, 1, context));
    let placeholder = arg_string(args, 2, context);
    push_request(Request::QuickPick {
        id,
        items,
        placeholder,
    });
    Ok(JsValue::undefined())
}

fn native_input_box(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let id = arg_number(args, 0) as i64;
    let prompt = arg_string(args, 1, context);
    let value = arg_string(args, 2, context);
    push_request(Request::InputBox { id, prompt, value });
    Ok(JsValue::undefined())
}

fn native_command_registered(
    _this: &JsValue,
    args: &[JsValue],
    context: &mut Context,
) -> JsResult<JsValue> {
    let id = arg_string(args, 0, context);
    push_request(Request::CommandRegistered(id));
    Ok(JsValue::undefined())
}

fn native_workspace(_this: &JsValue, _args: &[JsValue], _context: &mut Context) -> JsResult<JsValue> {
    let text = with_shared(|shared| {
        let context = &shared.context;
        let mut roots = context.roots.clone();
        if roots.is_empty() && !context.workspace.as_os_str().is_empty() {
            roots.push(context.workspace.clone());
        }
        let folders: Vec<Json> = roots
            .iter()
            .map(|root| {
                json::object(vec![
                    (
                        "name",
                        Json::String(
                            root.file_name()
                                .map(|n| n.to_string_lossy().to_string())
                                .unwrap_or_else(|| root.to_string_lossy().to_string()),
                        ),
                    ),
                    ("path", Json::String(root.to_string_lossy().to_string())),
                ])
            })
            .collect();
        json::object(vec![("folders", Json::Array(folders))]).dump()
    });
    Ok(js_string(text))
}

fn native_active_doc(_this: &JsValue, _args: &[JsValue], _context: &mut Context) -> JsResult<JsValue> {
    let text = with_shared(|shared| {
        let context = &shared.context;
        let path = context
            .active_path
            .as_ref()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        if path.is_empty() {
            return "{}".to_string();
        }
        json::object(vec![
            ("path", Json::String(path)),
            ("text", Json::String(context.active_text.clone())),
            ("language", Json::String(context.active_language.clone())),
            ("version", Json::Number(context.active_version as f64)),
            ("line", Json::Number(context.active_line as f64)),
            ("character", Json::Number(context.active_character as f64)),
            ("eol", Json::Number(context.eol as f64)),
            (
                "selStartLine",
                Json::Number(context.sel_start_line as f64),
            ),
            (
                "selStartCharacter",
                Json::Number(context.sel_start_character as f64),
            ),
            ("selEndLine", Json::Number(context.sel_end_line as f64)),
            (
                "selEndCharacter",
                Json::Number(context.sel_end_character as f64),
            ),
        ])
        .dump()
    });
    Ok(js_string(text))
}

fn native_config(_this: &JsValue, _args: &[JsValue], _context: &mut Context) -> JsResult<JsValue> {
    let workspace = with_shared(|shared| shared.context.workspace.clone());
    let mut value = Json::Object(Default::default());
    for relative in [".textm/settings.json", ".vscode/settings.json"] {
        let path = workspace.join(relative);
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Ok(parsed) = json::parse(&text) {
                value = parsed;
                break;
            }
        }
    }
    Ok(js_string(value.dump()))
}

fn native_read_text_file(
    _this: &JsValue,
    args: &[JsValue],
    context: &mut Context,
) -> JsResult<JsValue> {
    let path = arg_string(args, 0, context);
    match std::fs::read_to_string(&path) {
        Ok(text) => Ok(js_string(text)),
        Err(_) => Ok(JsValue::null()),
    }
}

fn native_env(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let name = arg_string(args, 0, context);
    match std::env::var(&name) {
        Ok(value) => Ok(js_string(value)),
        Err(_) => Ok(JsValue::null()),
    }
}

fn native_clipboard_read(
    _this: &JsValue,
    _args: &[JsValue],
    _context: &mut Context,
) -> JsResult<JsValue> {
    Ok(js_string(clipboard::get_text()))
}

fn native_clipboard_write(
    _this: &JsValue,
    args: &[JsValue],
    context: &mut Context,
) -> JsResult<JsValue> {
    let text = arg_string(args, 0, context);
    let _ = clipboard::set_text(&text);
    Ok(JsValue::undefined())
}

fn native_fs(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let op = arg_string(args, 0, context);
    let path = arg_string(args, 1, context);
    let data = arg_string(args, 2, context);
    Ok(js_string(fs_op(&op, &path, &data)))
}

fn fs_op(op: &str, path: &str, data: &str) -> String {
    let target = PathBuf::from(path);
    match op {
        "exists" => json::object(vec![("exists", Json::Bool(target.exists()))]).dump(),
        "read" => match std::fs::read(&target) {
            Ok(bytes) => json::object(vec![("data", Json::String(base64_encode(&bytes)))]).dump(),
            Err(e) => json::object(vec![("error", Json::String(e.to_string()))]).dump(),
        },
        "write" => {
            let bytes = base64_decode(data);
            if let Some(parent) = target.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            match std::fs::write(&target, bytes) {
                Ok(()) => json::object(vec![("ok", Json::Bool(true))]).dump(),
                Err(e) => json::object(vec![("error", Json::String(e.to_string()))]).dump(),
            }
        }
        "readdir" => match std::fs::read_dir(&target) {
            Ok(entries) => {
                let mut items: Vec<(String, bool)> = entries
                    .flatten()
                    .map(|entry| (entry.file_name().to_string_lossy().to_string(), entry.path().is_dir()))
                    .collect();
                items.sort();
                let list: Vec<Json> = items
                    .into_iter()
                    .map(|(name, dir)| {
                        json::object(vec![
                            ("name", Json::String(name)),
                            ("dir", Json::Bool(dir)),
                        ])
                    })
                    .collect();
                json::object(vec![("items", Json::Array(list))]).dump()
            }
            Err(e) => json::object(vec![("error", Json::String(e.to_string()))]).dump(),
        },
        "stat" => match std::fs::metadata(&target) {
            Ok(meta) => json::object(vec![
                ("dir", Json::Bool(meta.is_dir())),
                ("size", Json::Number(meta.len() as f64)),
            ])
            .dump(),
            Err(e) => json::object(vec![("error", Json::String(e.to_string()))]).dump(),
        },
        "mkdir" => match std::fs::create_dir_all(&target) {
            Ok(()) => json::object(vec![("ok", Json::Bool(true))]).dump(),
            Err(e) => json::object(vec![("error", Json::String(e.to_string()))]).dump(),
        },
        "remove" => {
            let result = if target.is_dir() {
                std::fs::remove_dir_all(&target)
            } else {
                std::fs::remove_file(&target)
            };
            match result {
                Ok(()) => json::object(vec![("ok", Json::Bool(true))]).dump(),
                Err(e) => json::object(vec![("error", Json::String(e.to_string()))]).dump(),
            }
        }
        "rename" => match std::fs::rename(&target, data) {
            Ok(()) => json::object(vec![("ok", Json::Bool(true))]).dump(),
            Err(e) => json::object(vec![("error", Json::String(e.to_string()))]).dump(),
        },
        "copy" => match std::fs::copy(&target, data) {
            Ok(size) => json::object(vec![("size", Json::Number(size as f64))]).dump(),
            Err(e) => json::object(vec![("error", Json::String(e.to_string()))]).dump(),
        },
        other => json::object(vec![("error", Json::String(format!("未知操作 {other}")))]).dump(),
    }
}

fn native_apply_edits(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let path = arg_string(args, 0, context);
    let edits = parse_edits(&arg_string(args, 1, context));
    if !edits.is_empty() {
        push_request(Request::ApplyEdits {
            path: PathBuf::from(path),
            edits,
        });
    }
    Ok(JsValue::undefined())
}

fn native_open_document(
    _this: &JsValue,
    args: &[JsValue],
    context: &mut Context,
) -> JsResult<JsValue> {
    let path = arg_string(args, 0, context);
    let path_buf = PathBuf::from(&path);
    let text = std::fs::read_to_string(&path_buf).unwrap_or_default();
    push_request(Request::OpenDocument(path_buf.clone()));
    let value = json::object(vec![
        ("path", Json::String(path)),
        ("text", Json::String(text)),
        ("language", Json::String(language_id(&path_buf))),
        ("version", Json::Number(1.0)),
    ]);
    Ok(js_string(value.dump()))
}

fn native_show_document(
    _this: &JsValue,
    args: &[JsValue],
    context: &mut Context,
) -> JsResult<JsValue> {
    push_request(Request::ShowDocument {
        path: PathBuf::from(arg_string(args, 0, context)),
        line: arg_number(args, 1) as usize,
        column: arg_number(args, 2) as usize,
    });
    Ok(JsValue::undefined())
}

fn native_save_document(
    _this: &JsValue,
    args: &[JsValue],
    context: &mut Context,
) -> JsResult<JsValue> {
    push_request(Request::SaveDocument(PathBuf::from(arg_string(args, 0, context))));
    Ok(JsValue::undefined())
}

fn native_terminal(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    push_request(Request::Terminal(arg_string(args, 0, context)));
    Ok(JsValue::undefined())
}

fn native_panel(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let title = arg_string(args, 0, context);
    let text = arg_string(args, 1, context);
    push_request(Request::Panel { title, text });
    Ok(JsValue::undefined())
}

fn native_problems(_this: &JsValue, args: &[JsValue], context: &mut Context) -> JsResult<JsValue> {
    let path = arg_string(args, 0, context);
    let items = parse_problems(&arg_string(args, 1, context));
    push_request(Request::Problems {
        path: if path.is_empty() {
            None
        } else {
            Some(PathBuf::from(path))
        },
        items,
    });
    Ok(JsValue::undefined())
}

fn native_find_files(_this: &JsValue, args: &[JsValue], _context: &mut Context) -> JsResult<JsValue> {
    let limit = arg_number(args, 0).max(1.0) as usize;
    let roots = with_shared(|shared| shared.context.roots.clone());
    let mut files = Vec::new();
    for root in roots {
        collect_files(&root, &mut files, limit);
        if files.len() >= limit {
            break;
        }
    }
    let list: Vec<Json> = files
        .iter()
        .map(|path| Json::String(path.to_string_lossy().to_string()))
        .collect();
    Ok(js_string(Json::Array(list).dump()))
}

// ---------------------------------------------------------------- 解析助手

fn parse_quick_items(text: &str) -> Vec<(String, String, String)> {
    let Some(list) = json::parse(text).ok().and_then(|value| match value {
        Json::Array(items) => Some(items),
        _ => None,
    }) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in list {
        match &item {
            Json::String(text) => out.push((text.clone(), String::new(), item.dump())),
            Json::Object(_) => {
                let label = item
                    .get("label")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let detail = item
                    .get("detail")
                    .or_else(|| item.get("description"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let value = item
                    .get("value")
                    .map(|v| v.dump())
                    .unwrap_or_else(|| item.dump());
                out.push((label, detail, value));
            }
            _ => {}
        }
    }
    out
}

fn parse_edits(text: &str) -> Vec<PluginEdit> {
    let Ok(value) = json::parse(text) else {
        return Vec::new();
    };
    let Some(list) = value.as_array() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in list {
        let Some(start) = item.get("start") else {
            continue;
        };
        let Some(end) = item.get("end") else {
            continue;
        };
        out.push(PluginEdit {
            start_line: start.get("line").and_then(|v| v.as_i64()).unwrap_or(0) as usize,
            start_char: start
                .get("character")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as usize,
            end_line: end.get("line").and_then(|v| v.as_i64()).unwrap_or(0) as usize,
            end_char: end
                .get("character")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as usize,
            new_text: item
                .get("newText")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
        });
    }
    out
}

fn parse_problems(text: &str) -> Vec<PluginProblem> {
    let Ok(value) = json::parse(text) else {
        return Vec::new();
    };
    let Some(list) = value.as_array() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in list {
        let message = item
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if message.is_empty() {
            continue;
        }
        out.push(PluginProblem {
            path: PathBuf::new(),
            message,
            severity: item.get("severity").and_then(|v| v.as_i64()).unwrap_or(0) as u8,
            line: item.get("line").and_then(|v| v.as_i64()).unwrap_or(0) as usize,
            character: item.get("character").and_then(|v| v.as_i64()).unwrap_or(0) as usize,
            source: item
                .get("source")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
        });
    }
    out
}

pub fn language_id(path: &Path) -> String {
    match crate::core::language::Language::from_path(path) {
        crate::core::language::Language::Plain => "plaintext",
        crate::core::language::Language::Rust => "rust",
        crate::core::language::Language::C => "c",
        crate::core::language::Language::Cpp => "cpp",
        crate::core::language::Language::CSharp => "csharp",
        crate::core::language::Language::Java => "java",
        crate::core::language::Language::Go => "go",
        crate::core::language::Language::Python => "python",
        crate::core::language::Language::JavaScript => "javascript",
        crate::core::language::Language::TypeScript => "typescript",
        crate::core::language::Language::Json => "json",
        crate::core::language::Language::Html => "html",
        crate::core::language::Language::Xml => "xml",
        crate::core::language::Language::Css => "css",
        crate::core::language::Language::Markdown => "markdown",
        crate::core::language::Language::Sql => "sql",
        crate::core::language::Language::Yaml => "yaml",
        crate::core::language::Language::Toml => "toml",
        crate::core::language::Language::Ini => "ini",
        crate::core::language::Language::PowerShell => "powershell",
        crate::core::language::Language::Batch => "bat",
        crate::core::language::Language::Shell => "shellscript",
        crate::core::language::Language::Lua => "lua",
        crate::core::language::Language::Php => "php",
        crate::core::language::Language::Makefile => "makefile",
        crate::core::language::Language::Diff => "diff",
        crate::core::language::Language::Custom(_) => "plaintext",
    }
    .to_string()
}

fn collect_files(dir: &Path, out: &mut Vec<PathBuf>, limit: usize) {
    if out.len() >= limit {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut paths: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
    paths.sort();
    for path in paths {
        if out.len() >= limit {
            return;
        }
        if path.is_dir() {
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if name.starts_with('.')
                || matches!(name.as_str(), "target" | "node_modules" | "bin" | "obj" | "dist")
            {
                continue;
            }
            collect_files(&path, out, limit);
        } else {
            out.push(path);
        }
    }
}

// ---------------------------------------------------------------- Base64

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let a = chunk[0];
        let b = *chunk.get(1).unwrap_or(&0);
        let c = *chunk.get(2).unwrap_or(&0);
        out.push(TABLE[(a >> 2) as usize] as char);
        out.push(TABLE[(((a & 3) << 4) | (b >> 4)) as usize] as char);
        out.push(if chunk.len() > 1 {
            TABLE[(((b & 15) << 2) | (c >> 6)) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[(c & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

fn base64_decode(text: &str) -> Vec<u8> {
    fn value(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let clean: Vec<u8> = text
        .bytes()
        .filter(|byte| !byte.is_ascii_whitespace())
        .collect();
    let mut out = Vec::new();
    for chunk in clean.chunks(4) {
        if chunk.len() < 2 {
            break;
        }
        let a = value(chunk[0]).unwrap_or(0);
        let b = value(chunk[1]).unwrap_or(0);
        let c = chunk.get(2).and_then(|byte| value(*byte));
        let d = chunk.get(3).and_then(|byte| value(*byte));
        out.push((a << 2) | (b >> 4));
        if let Some(c) = c {
            out.push(((b & 15) << 4) | (c >> 2));
            if let Some(d) = d {
                out.push(((c & 3) << 6) | d);
            }
        }
    }
    out
}

// ---------------------------------------------------------------- 宿主

#[derive(Clone, Debug)]
pub struct PluginPackage {
    pub name: String,
    pub version: String,
    pub dir: PathBuf,
    pub main: PathBuf,
    pub manifest: String,
    pub commands: Vec<(String, String)>,
    pub activation: Vec<String>,
}

pub struct PluginHost {
    pub packages: Vec<PluginPackage>,
    /// (命令 id, 标题, 插件名)，仅包含 index.js 注册的命令。
    pub commands: Vec<(String, String, String)>,
    pub errors: Vec<String>,
    pub output: Vec<String>,
    pub problems: Vec<PluginProblem>,
    pub status: String,
    pub panels: Vec<(String, String)>,
    context: Option<Context>,
    activated: HashSet<String>,
}

impl Default for PluginHost {
    fn default() -> Self {
        PluginHost::new()
    }
}

impl PluginHost {
    pub fn new() -> PluginHost {
        PluginHost {
            packages: Vec::new(),
            commands: Vec::new(),
            errors: Vec::new(),
            output: Vec::new(),
            problems: Vec::new(),
            status: String::new(),
            panels: Vec::new(),
            context: None,
            activated: HashSet::new(),
        }
    }

    pub fn is_running(&self) -> bool {
        self.context.is_some()
    }

    /// 由 `extension::load` 的结果构建脚本插件列表。
    pub fn reload_from(&mut self, extensions: &[Extension]) {
        self.packages.clear();
        self.commands.clear();
        for ext in extensions {
            if !ext.enabled {
                continue;
            }
            let Some(main) = ext.main.clone() else {
                continue;
            };
            let manifest = std::fs::read_to_string(ext.dir.join("textm.json")).unwrap_or_default();
            let commands: Vec<(String, String)> = ext
                .script_commands()
                .iter()
                .map(|command| (command.id.clone(), command.title.clone()))
                .collect();
            for (id, title) in &commands {
                self.commands
                    .push((id.clone(), title.clone(), ext.name.clone()));
            }
            self.packages.push(PluginPackage {
                name: ext.name.clone(),
                version: ext.version.clone(),
                dir: ext.dir.clone(),
                main,
                manifest,
                commands,
                activation: ext.activation.clone(),
            });
        }
    }

    pub fn set_context(&mut self, context: HostContext) {
        with_shared(|shared| shared.context = context);
    }

    pub fn start(&mut self) -> Result<(), String> {
        if self.context.is_some() {
            return Ok(());
        }
        let mut context = Context::default();
        let native = build_native(&mut context);
        context
            .register_global_property(JsString::from("__textm"), native, Attribute::all())
            .map_err(|e| format!("注册原生接口失败：{e}"))?;
        context
            .eval(Source::from_bytes(SHIM.as_bytes()))
            .map_err(|e| format!("加载 textm API 失败：{e}"))?;
        self.context = Some(context);
        self.errors.clear();
        let indexes: Vec<usize> = self
            .packages
            .iter()
            .enumerate()
            .filter(|(_, package)| package.activation.iter().any(|event| event == "startup"))
            .map(|(index, _)| index)
            .collect();
        for index in indexes {
            if let Err(e) = self.activate(index) {
                self.errors.push(e);
            }
        }
        Ok(())
    }

    fn activate(&mut self, index: usize) -> Result<(), String> {
        let Some(package) = self.packages.get(index).cloned() else {
            return Err("插件不存在".into());
        };
        if self.activated.contains(&package.name) {
            return Ok(());
        }
        self.packages
            .get(index)
            .map(|p| p.name.clone())
            .into_iter()
            .for_each(|name| {
                self.activated.insert(name);
            });
        let context = self.context.as_mut().ok_or("插件引擎未启动")?;
        let storage = package.dir.join(".storage");
        let _ = std::fs::create_dir_all(&storage);
        let code = format!(
            "__textmLoadPlugin({}, {}, {}, {});",
            Json::String(package.main.to_string_lossy().to_string()).dump(),
            Json::String(package.dir.to_string_lossy().to_string()).dump(),
            Json::String(package.manifest.clone()).dump(),
            Json::String(storage.to_string_lossy().to_string()).dump(),
        );
        let value = context
            .eval(Source::from_bytes(code.as_bytes()))
            .map_err(|e| format!("激活 {} 失败：{e}", package.name))?;
        let text = value
            .to_string(context)
            .map(|s| s.to_std_string_escaped())
            .unwrap_or_default();
        let _ = context.run_jobs();
        if text == "error" {
            self.errors
                .push(format!("插件 {} 激活失败，详见插件输出", package.name));
        }
        Ok(())
    }

    pub fn execute(&mut self, command: &str, args_json: &str) -> Result<(), String> {
        let index = self
            .packages
            .iter()
            .position(|package| {
                package
                    .commands
                    .iter()
                    .any(|(id, _)| id.as_str() == command)
            })
            .ok_or_else(|| format!("没有插件注册命令 {command}"))?;
        self.start()?;
        self.activate(index)?;
        let context = self.context.as_mut().ok_or("插件引擎未启动")?;
        let code = format!(
            "__textmInvokeCommand({}, {});",
            Json::String(command.to_string()).dump(),
            Json::String(args_json.to_string()).dump()
        );
        let value = context
            .eval(Source::from_bytes(code.as_bytes()))
            .map_err(|e| format!("命令 {command} 执行失败：{e}"))?;
        let text = value
            .to_string(context)
            .map(|s| s.to_std_string_escaped())
            .unwrap_or_default();
        let _ = context.run_jobs();
        if text.starts_with("error") {
            return Err(format!("命令 {command} 抛出了异常，详见插件输出"));
        }
        Ok(())
    }

    /// 触发插件事件（save / open / change）。
    pub fn fire_event(&mut self, name: &str, payload_json: &str) {
        let Some(context) = self.context.as_mut() else {
            return;
        };
        let code = format!(
            "__textmFire({}, {});",
            Json::String(name.to_string()).dump(),
            Json::String(payload_json.to_string()).dump()
        );
        let _ = context.eval(Source::from_bytes(code.as_bytes()));
        let _ = context.run_jobs();
    }

    pub fn tick(&mut self) {
        if let Some(context) = self.context.as_mut() {
            let _ = context.eval(Source::from_bytes("__textmRunTimers();"));
            let _ = context.run_jobs();
        }
    }

    pub fn resolve(&mut self, id: i64, value_json: &str) -> Result<(), String> {
        let context = self.context.as_mut().ok_or("插件引擎未启动")?;
        let code = format!(
            "__textmResolve({}, {});",
            id,
            Json::String(value_json.to_string()).dump()
        );
        context
            .eval(Source::from_bytes(code.as_bytes()))
            .map_err(|e| format!("解析插件回调失败：{e}"))?;
        let _ = context.run_jobs();
        Ok(())
    }

    pub fn drain_requests(&mut self) -> Vec<Request> {
        with_shared(|shared| std::mem::take(&mut shared.requests))
    }

    pub fn shutdown(&mut self) {
        self.context = None;
        self.activated.clear();
        self.status.clear();
        self.problems.clear();
    }

    pub fn push_output(&mut self, text: impl Into<String>) {
        self.output.push(text.into());
        if self.output.len() > 4000 {
            self.output.drain(0..1000);
        }
    }
}

fn build_native(context: &mut Context) -> boa_engine::object::JsObject {
    let mut object = ObjectInitializer::new(context);
    macro_rules! add {
        ($name:literal, $function:expr, $length:expr) => {
            object.function(
                NativeFunction::from_fn_ptr($function),
                JsString::from($name),
                $length,
            );
        };
    }
    add!("message", native_message, 2);
    add!("output", native_output, 1);
    add!("status", native_status, 1);
    add!("log", native_log, 1);
    add!("nextId", native_next_id, 0);
    add!("quickPick", native_quick_pick, 3);
    add!("inputBox", native_input_box, 3);
    add!("commandRegistered", native_command_registered, 1);
    add!("workspace", native_workspace, 0);
    add!("activeDoc", native_active_doc, 0);
    add!("config", native_config, 0);
    add!("fs", native_fs, 3);
    add!("readTextFile", native_read_text_file, 1);
    add!("env", native_env, 1);
    add!("clipboardRead", native_clipboard_read, 0);
    add!("clipboardWrite", native_clipboard_write, 1);
    add!("applyEdits", native_apply_edits, 2);
    add!("openDocument", native_open_document, 1);
    add!("showDocument", native_show_document, 3);
    add!("saveDocument", native_save_document, 1);
    add!("terminal", native_terminal, 1);
    add!("panel", native_panel, 2);
    add!("problems", native_problems, 2);
    add!("findFiles", native_find_files, 1);
    object.build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_roundtrip() {
        let bytes = b"Textm \xe4\xb8\xad\xe6\x96\x87";
        assert_eq!(base64_decode(&base64_encode(bytes)), bytes);
    }

    #[test]
    fn parse_edits_and_problems() {
        let edits = parse_edits(
            r#"[{"start":{"line":1,"character":2},"end":{"line":1,"character":4},"newText":"x"}]"#,
        );
        assert_eq!(edits.len(), 1);
        assert_eq!(edits[0].start_char, 2);
        let problems =
            parse_problems(r#"[{"message":"mb","severity":1,"line":3,"character":1}]"#);
        assert_eq!(problems.len(), 1);
        assert_eq!(problems[0].line, 3);
    }

    #[test]
    fn api_loads_in_boa() {
        let mut context = Context::default();
        let native = build_native(&mut context);
        context
            .register_global_property(JsString::from("__textm"), native, Attribute::all())
            .unwrap();
        context
            .eval(Source::from_bytes(SHIM.as_bytes()))
            .expect("textm API 应能加载");
        let value = context
            .eval(Source::from_bytes("typeof textm.commands.register"))
            .unwrap();
        assert_eq!(
            value
                .to_string(&mut context)
                .unwrap()
                .to_std_string_escaped(),
            "function"
        );
    }

    #[test]
    fn run_sample_plugin() {
        let root = std::env::temp_dir().join("textm-plugin-own");
        let dir = root.join("plugins").join("demo");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("textm.json"),
            r#"{
                "name": "demo",
                "version": "1.0.0",
                "main": "index.js",
                "commands": [{"id": "demo.hello", "title": "打招呼"}]
            }"#,
        )
        .unwrap();
        std::fs::write(
            dir.join("index.js"),
            r#"
            exports.activate = function (context) {
              const textm = context.textm;
              textm.commands.register('demo.hello', function (name) {
                const root = textm.workspace.root();
                textm.window.info('hello ' + name + ' from ' + (root ? 'workspace' : 'none'));
              });
            };
            "#,
        )
        .unwrap();
        let extensions = crate::extension::load(&root, &[], &[]);
        assert_eq!(extensions.len(), 1);
        let mut host = PluginHost::new();
        host.reload_from(&extensions);
        let mut context = HostContext::default();
        context.workspace = root.clone();
        context.roots = vec![root.clone()];
        host.set_context(context);
        host.execute("demo.hello", r#"["textm"]"#).unwrap();
        let requests = host.drain_requests();
        let _ = std::fs::remove_dir_all(&root);
        assert!(
            requests.iter().any(|request| matches!(
                request,
                Request::Message { text, .. } if text.contains("hello textm from workspace")
            )),
            "未收到插件消息：{requests:?}"
        );
    }
}

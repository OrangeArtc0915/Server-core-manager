//! 最小可用的 LSP 客户端：JSON-RPC over stdio。
//!
//! 启动语言服务器 → initialize → didOpen → 补全 / 跳转定义；
//! 后台线程读取 publishDiagnostics 并按文件保存。

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::json::{self, Json};
use super::Diagnostic;
use crate::core::language::Language;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub struct LspClient {
    child: Child,
    stdin: ChildStdin,
    responses: Receiver<Json>,
    diagnostics: Arc<Mutex<HashMap<PathBuf, Vec<Diagnostic>>>>,
    opened: HashSet<PathBuf>,
    next_id: i64,
    root: PathBuf,
    pub language: Language,
    language_id: String,
    alive: bool,
}

/// 语言服务器返回的文本编辑（UTF-16 列号）。
#[derive(Clone, Debug)]
pub struct LspEdit {
    pub path: PathBuf,
    pub start_line: usize,
    pub start_col: usize,
    pub end_line: usize,
    pub end_col: usize,
    pub new_text: String,
}

/// 签名帮助中的一个重载。
#[derive(Clone, Debug)]
pub struct SignatureItem {
    pub label: String,
    pub docs: String,
}

/// 签名帮助结果。
#[derive(Clone, Debug)]
pub struct SignatureHelp {
    pub signatures: Vec<SignatureItem>,
    pub active: usize,
    pub parameter: usize,
}

/// 代码操作（快速修复 / 重构等）。
#[derive(Clone, Debug)]
pub struct CodeAction {
    pub title: String,
    pub kind: String,
    pub edits: Vec<LspEdit>,
}

/// 内联提示（类型、参数名等），列号已换算为字符列。
#[derive(Clone, Debug)]
pub struct InlayHint {
    pub line: usize,
    pub col: usize,
    pub label: String,
}

impl LspClient {
    pub fn start(command: &str, root: &Path, language: Language) -> Result<LspClient, String> {
        let mut parts = command.split_whitespace();
        let program = parts.next().ok_or("语言服务器命令为空")?;
        let mut process = Command::new(program);
        process.args(parts).current_dir(root);
        process
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(windows)]
        process.creation_flags(CREATE_NO_WINDOW);
        let mut child = process
            .spawn()
            .map_err(|e| format!("启动 {program} 失败：{e}"))?;
        let stdin = child.stdin.take().ok_or("无法获取 LSP stdin")?;
        let stdout = child.stdout.take().ok_or("无法获取 LSP stdout")?;

        let diagnostics = Arc::new(Mutex::new(HashMap::new()));
        let (tx, rx) = channel();
        let store = diagnostics.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                match read_message(&mut reader) {
                    Some(Ok(value)) => {
                        if let Some(method) = value.get("method").and_then(|m| m.as_str()) {
                            if method == "textDocument/publishDiagnostics" {
                                if let Some(params) = value.get("params") {
                                    handle_diagnostics(&store, params);
                                }
                            }
                            continue;
                        }
                        if value.get("id").is_some() {
                            if tx.send(value).is_err() {
                                break;
                            }
                        }
                    }
                    Some(Err(_)) => break,
                    None => break,
                }
            }
        });

        let mut client = LspClient {
            child,
            stdin,
            responses: rx,
            diagnostics,
            opened: HashSet::new(),
            next_id: 1,
            root: root.to_path_buf(),
            language,
            language_id: match language {
                Language::Rust => "rust".into(),
                Language::Python => "python".into(),
                Language::JavaScript => "javascript".into(),
                Language::TypeScript => "typescript".into(),
                Language::Go => "go".into(),
                Language::C => "c".into(),
                Language::Cpp => "cpp".into(),
                _ => "plaintext".into(),
            },
            alive: true,
        };
        client.initialize()?;
        Ok(client)
    }

    fn initialize(&mut self) -> Result<(), String> {
        let root_uri = path_to_uri(&self.root);
        let params = json::object(vec![
            ("processId", Json::Null),
            ("rootUri", Json::String(root_uri)),
            ("clientInfo", json::object(vec![
                ("name", Json::String("Textm".into())),
                ("version", Json::String("2.0".into())),
            ])),
            (
                "capabilities",
                json::object(vec![
                    (
                        "textDocument",
                        json::object(vec![
                            (
                                "completion",
                                json::object(vec![(
                                    "completionItem",
                                    json::object(vec![(
                                        "snippetSupport",
                                        Json::Bool(false),
                                    )]),
                                )]),
                            ),
                            ("definition", json::object(Vec::new())),
                            ("hover", json::object(Vec::new())),
                            ("references", json::object(Vec::new())),
                            ("rename", json::object(Vec::new())),
                            ("formatting", json::object(Vec::new())),
                            ("signatureHelp", json::object(Vec::new())),
                            (
                                "codeAction",
                                json::object(vec![(
                                    "codeActionLiteralSupport",
                                    json::object(vec![(
                                        "codeActionKind",
                                        json::object(vec![(
                                            "valueSet",
                                            Json::Array(vec![
                                                Json::String("quickfix".into()),
                                                Json::String("refactor".into()),
                                                Json::String("source".into()),
                                            ]),
                                        )]),
                                    )]),
                                )]),
                            ),
                            ("inlayHint", json::object(Vec::new())),
                            ("publishDiagnostics", json::object(Vec::new())),
                        ]),
                    ),
                    ("workspace", json::object(Vec::new())),
                ]),
            ),
        ]);
        let id = self.request("initialize", params)?;
        let _ = self.wait_response(id, Duration::from_secs(8));
        self.notify("initialized", json::object(Vec::new()))?;
        Ok(())
    }

    pub fn has_file(&self, path: &Path) -> bool {
        self.opened.contains(path)
    }

    /// 同步文件内容（首次 didOpen，后续 didChange）。
    pub fn sync(&mut self, path: &Path, text: &str) -> Result<(), String> {
        if self.opened.contains(path) {
            let params = json::object(vec![
                (
                    "textDocument",
                    json::object(vec![
                        ("uri", Json::String(path_to_uri(path))),
                        ("version", Json::Number(2.0)),
                    ]),
                ),
                (
                    "contentChanges",
                    Json::Array(vec![json::object(vec![(
                        "text",
                        Json::String(text.to_string()),
                    )])]),
                ),
            ]);
            self.notify("textDocument/didChange", params)
        } else {
            let params = json::object(vec![(
                "textDocument",
                json::object(vec![
                    ("uri", Json::String(path_to_uri(path))),
                    ("languageId", Json::String(self.language_id.clone())),
                    ("version", Json::Number(1.0)),
                    ("text", Json::String(text.to_string())),
                ]),
            )]);
            self.notify("textDocument/didOpen", params)?;
            self.opened.insert(path.to_path_buf());
            Ok(())
        }
    }

    pub fn diagnostics(&self, path: &Path) -> Vec<Diagnostic> {
        let store = self.diagnostics.lock().unwrap_or_else(|e| e.into_inner());
        store.get(path).cloned().unwrap_or_default()
    }

    pub fn definition(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
    ) -> Result<Option<(PathBuf, usize)>, String> {
        self.sync(path, text)?;
        let params = json::object(vec![
            ("textDocument", json::object(vec![("uri", Json::String(path_to_uri(path)))])),
            ("position", position_json(text, line, col)),
        ]);
        let id = self.request("textDocument/definition", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(5)) else {
            return Ok(None);
        };
        let Some(result) = response.get("result") else {
            return Ok(None);
        };
        let location = match result {
            Json::Array(items) => items.first(),
            Json::Object(_) => Some(result),
            _ => None,
        };
        let Some(location) = location else {
            return Ok(None);
        };
        let uri = location
            .get("uri")
            .and_then(|u| u.as_str())
            .or_else(|| location.get("targetUri").and_then(|u| u.as_str()));
        let target_line = location
            .get("range")
            .and_then(|r| r.get("start"))
            .and_then(|s| s.get("line"))
            .and_then(|l| l.as_i64())
            .or_else(|| {
                location
                    .get("targetSelectionRange")
                    .and_then(|r| r.get("start"))
                    .and_then(|s| s.get("line"))
                    .and_then(|l| l.as_i64())
            });
        match (uri, target_line) {
            (Some(uri), Some(line)) => Ok(Some((uri_to_path(uri), line as usize))),
            _ => Ok(None),
        }
    }

    pub fn completion(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
    ) -> Result<Vec<(String, String, String)>, String> {
        self.sync(path, text)?;
        let params = json::object(vec![
            ("textDocument", json::object(vec![("uri", Json::String(path_to_uri(path)))])),
            ("position", position_json(text, line, col)),
        ]);
        let id = self.request("textDocument/completion", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(5)) else {
            return Ok(Vec::new());
        };
        let Some(result) = response.get("result") else {
            return Ok(Vec::new());
        };
        let items = result
            .get("items")
            .and_then(|i| i.as_array())
            .or_else(|| result.as_array())
            .unwrap_or(&[]);
        let mut out = Vec::new();
        for item in items.iter().take(500) {
            let label = item
                .get("label")
                .and_then(|l| l.as_str())
                .unwrap_or("")
                .to_string();
            if label.is_empty() {
                continue;
            }
            let detail = item
                .get("detail")
                .and_then(|d| d.as_str())
                .unwrap_or("")
                .to_string();
            let insert = item
                .get("textEdit")
                .and_then(|edit| edit.get("newText"))
                .and_then(|text| text.as_str())
                .or_else(|| item.get("insertText").and_then(|text| text.as_str()))
                .unwrap_or(&label)
                .to_string();
            out.push((label, detail, insert));
        }
        Ok(out)
    }

    /// 悬停提示（Markdown / 纯文本）。
    pub fn hover(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
    ) -> Result<Option<String>, String> {
        self.sync(path, text)?;
        let params = json::object(vec![
            ("textDocument", json::object(vec![("uri", Json::String(path_to_uri(path)))])),
            ("position", position_json(text, line, col)),
        ]);
        let id = self.request("textDocument/hover", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(4)) else {
            return Ok(None);
        };
        let Some(result) = response.get("result") else {
            return Ok(None);
        };
        if matches!(result, Json::Null) {
            return Ok(None);
        }
        Ok(hover_text(result))
    }

    /// 引用位置列表：(文件, 行, UTF-16 列)。
    pub fn references(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
        include_declaration: bool,
    ) -> Result<Vec<(PathBuf, usize, usize)>, String> {
        self.sync(path, text)?;
        let params = json::object(vec![
            ("textDocument", json::object(vec![("uri", Json::String(path_to_uri(path)))])),
            ("position", position_json(text, line, col)),
            (
                "context",
                json::object(vec![(
                    "includeDeclaration",
                    Json::Bool(include_declaration),
                )]),
            ),
        ]);
        let id = self.request("textDocument/references", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(6)) else {
            return Ok(Vec::new());
        };
        let Some(result) = response.get("result") else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        for item in result.as_array().unwrap_or(&[]) {
            let Some(uri) = item.get("uri").and_then(|u| u.as_str()) else {
                continue;
            };
            let start = item.get("range").and_then(|r| r.get("start"));
            let line = start
                .and_then(|s| s.get("line"))
                .and_then(|l| l.as_i64())
                .unwrap_or(0) as usize;
            let col = start
                .and_then(|s| s.get("character"))
                .and_then(|c| c.as_i64())
                .unwrap_or(0) as usize;
            out.push((uri_to_path(uri), line, col));
            if out.len() >= 500 {
                break;
            }
        }
        Ok(out)
    }

    /// 工作区符号搜索：返回 (文件, 行, UTF-16 列, 名称, 类型)。
    pub fn workspace_symbols(
        &mut self,
        query: &str,
    ) -> Result<Vec<(PathBuf, usize, usize, String, String)>, String> {
        let params = json::object(vec![("query", Json::String(query.to_string()))]);
        let id = self.request("workspace/symbol", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(8)) else {
            return Ok(Vec::new());
        };
        let Some(result) = response.get("result") else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        for item in result.as_array().unwrap_or(&[]) {
            let Some(name) = item.get("name").and_then(|v| v.as_str()) else {
                continue;
            };
            let Some(location) = item.get("location") else {
                continue;
            };
            let Some(uri) = location.get("uri").and_then(|v| v.as_str()) else {
                continue;
            };
            let start = location.get("range").and_then(|r| r.get("start"));
            let line = start
                .and_then(|s| s.get("line"))
                .and_then(|l| l.as_i64())
                .unwrap_or(0) as usize;
            let col = start
                .and_then(|s| s.get("character"))
                .and_then(|c| c.as_i64())
                .unwrap_or(0) as usize;
            let kind = symbol_kind_label(
                item.get("kind").and_then(|v| v.as_i64()).unwrap_or(0),
            );
            out.push((uri_to_path(uri), line, col, name.to_string(), kind.to_string()));
            if out.len() >= 200 {
                break;
            }
        }
        Ok(out)
    }

    /// 重命名，返回需要应用的编辑（UTF-16 列号）。
    pub fn rename(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
        new_name: &str,
    ) -> Result<Vec<LspEdit>, String> {
        self.sync(path, text)?;
        let params = json::object(vec![
            ("textDocument", json::object(vec![("uri", Json::String(path_to_uri(path)))])),
            ("position", position_json(text, line, col)),
            ("newName", Json::String(new_name.to_string())),
        ]);
        let id = self.request("textDocument/rename", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(6)) else {
            return Err("语言服务器未响应重命名请求".into());
        };
        if let Some(error) = response.get("error") {
            let message = error
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("重命名失败");
            return Err(message.to_string());
        }
        let Some(result) = response.get("result") else {
            return Err("语言服务器没有返回编辑".into());
        };
        let edits = parse_workspace_edit(result);
        if edits.is_empty() {
            return Err("没有可应用的编辑（符号可能不可重命名）".into());
        }
        Ok(edits)
    }

    /// 格式化文档。
    pub fn formatting(
        &mut self,
        path: &Path,
        text: &str,
        tab_size: usize,
        use_spaces: bool,
    ) -> Result<Vec<LspEdit>, String> {
        self.sync(path, text)?;
        let params = json::object(vec![
            ("textDocument", json::object(vec![("uri", Json::String(path_to_uri(path)))])),
            (
                "options",
                json::object(vec![
                    ("tabSize", Json::Number(tab_size as f64)),
                    ("insertSpaces", Json::Bool(use_spaces)),
                ]),
            ),
        ]);
        let id = self.request("textDocument/formatting", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(8)) else {
            return Err("语言服务器未响应格式化请求".into());
        };
        let Some(result) = response.get("result") else {
            return Ok(Vec::new());
        };
        let mut edits = parse_edit_array(result);
        // formatting 的编辑都属于当前文档。
        for edit in &mut edits {
            edit.path = path.to_path_buf();
        }
        Ok(edits)
    }

    /// 签名帮助。
    pub fn signature_help(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
    ) -> Result<Option<SignatureHelp>, String> {
        self.sync(path, text)?;
        let params = json::object(vec![
            (
                "textDocument",
                json::object(vec![("uri", Json::String(path_to_uri(path)))]),
            ),
            ("position", position_json(text, line, col)),
        ]);
        let id = self.request("textDocument/signatureHelp", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(3)) else {
            return Ok(None);
        };
        if let Some(error) = response.get("error") {
            return Err(error_message(error));
        }
        match response.get("result") {
            Some(result) => Ok(parse_signature_help(result)),
            None => Ok(None),
        }
    }

    /// 代码操作：只保留带编辑的项（纯 command 暂时不支持）。
    pub fn code_actions(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
        diagnostics: &[Diagnostic],
    ) -> Result<Vec<CodeAction>, String> {
        self.sync(path, text)?;
        let line_text = text.lines().nth(line).unwrap_or("");
        let character = utf16_col(line_text, col);
        let mut context = Vec::new();
        for diagnostic in diagnostics {
            if line >= diagnostic.line && line <= diagnostic.end_line {
                context.push(json::object(vec![
                    (
                        "range",
                        range_json(
                            diagnostic.line,
                            diagnostic.col,
                            diagnostic.end_line,
                            diagnostic.end_col,
                        ),
                    ),
                    ("severity", Json::Number(diagnostic.severity as f64)),
                    ("message", Json::String(diagnostic.message.clone())),
                ]));
            }
        }
        let params = json::object(vec![
            (
                "textDocument",
                json::object(vec![("uri", Json::String(path_to_uri(path)))]),
            ),
            ("range", range_json(line, character, line, character)),
            ("context", json::object(vec![("diagnostics", Json::Array(context))])),
        ]);
        let id = self.request("textDocument/codeAction", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(6)) else {
            return Err("语言服务器未响应代码操作请求".into());
        };
        if let Some(error) = response.get("error") {
            return Err(error_message(error));
        }
        let Some(result) = response.get("result") else {
            return Ok(Vec::new());
        };
        Ok(parse_code_actions(result, path))
    }

    /// 内联提示（类型 / 参数名）。
    pub fn inlay_hints(&mut self, path: &Path, text: &str) -> Result<Vec<InlayHint>, String> {
        self.sync(path, text)?;
        let last_line = text.lines().count().saturating_sub(1);
        let params = json::object(vec![
            (
                "textDocument",
                json::object(vec![("uri", Json::String(path_to_uri(path)))]),
            ),
            ("range", range_json(0, 0, last_line, 0)),
        ]);
        let id = self.request("textDocument/inlayHint", params)?;
        let Some(response) = self.wait_response(id, Duration::from_secs(4)) else {
            return Ok(Vec::new());
        };
        let Some(result) = response.get("result") else {
            return Ok(Vec::new());
        };
        Ok(parse_inlay_hints(result, text))
    }

    fn ensure_open(&mut self, path: &Path) -> Result<(), String> {
        if self.opened.contains(path) {
            return Ok(());
        }
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("读取 {} 失败：{e}", path.display()))?;
        let params = json::object(vec![(
            "textDocument",
            json::object(vec![
                ("uri", Json::String(path_to_uri(path))),
                ("languageId", Json::String(self.language_id.clone())),
                ("version", Json::Number(1.0)),
                ("text", Json::String(text)),
            ]),
        )]);
        self.notify("textDocument/didOpen", params)?;
        self.opened.insert(path.to_path_buf());
        Ok(())
    }

    fn request(&mut self, method: &str, params: Json) -> Result<i64, String> {
        let id = self.next_id;
        self.next_id += 1;
        let message = json::object(vec![
            ("jsonrpc", Json::String("2.0".into())),
            ("id", Json::Number(id as f64)),
            ("method", Json::String(method.into())),
            ("params", params),
        ]);
        self.send(&message)?;
        Ok(id)
    }

    fn notify(&mut self, method: &str, params: Json) -> Result<(), String> {
        let message = json::object(vec![
            ("jsonrpc", Json::String("2.0".into())),
            ("method", Json::String(method.into())),
            ("params", params),
        ]);
        self.send(&message)
    }

    fn send(&mut self, message: &Json) -> Result<(), String> {
        let body = message.dump();
        let header = format!("Content-Length: {}\r\n\r\n", body.len());
        self.stdin
            .write_all(header.as_bytes())
            .and_then(|_| self.stdin.write_all(body.as_bytes()))
            .and_then(|_| self.stdin.flush())
            .map_err(|e| format!("写入 LSP 失败：{e}"))
    }

    fn wait_response(&mut self, id: i64, timeout: Duration) -> Option<Json> {
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return None;
            }
            match self.responses.recv_timeout(remaining) {
                Ok(value) => {
                    if value.get("id").and_then(|v| v.as_i64()) == Some(id) {
                        return Some(value);
                    }
                }
                Err(_) => return None,
            }
        }
    }

    pub fn shutdown(&mut self) {
        if !self.alive {
            return;
        }
        self.alive = false;
        let _ = self.request("shutdown", Json::Null);
        let _ = self.notify("exit", Json::Null);
        std::thread::sleep(Duration::from_millis(50));
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for LspClient {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn read_message(reader: &mut BufReader<std::process::ChildStdout>) -> Option<Result<Json, String>> {
    let mut length = 0usize;
    let mut saw_header = false;
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => return None,
            Ok(_) => {}
            Err(_) => return None,
        }
        let trimmed = line.trim_end();
        if trimmed.is_empty() {
            if saw_header {
                break;
            }
            continue;
        }
        saw_header = true;
        if let Some(value) = trimmed.strip_prefix("Content-Length:") {
            length = value.trim().parse().unwrap_or(0);
        }
    }
    if length == 0 {
        return Some(Err("LSP 消息长度为 0".into()));
    }
    let mut buffer = vec![0u8; length];
    if reader.read_exact(&mut buffer).is_err() {
        return None;
    }
    let text = String::from_utf8_lossy(&buffer).to_string();
    Some(json::parse(&text))
}

fn handle_diagnostics(store: &Arc<Mutex<HashMap<PathBuf, Vec<Diagnostic>>>>, params: &Json) {
    let Some(uri) = params.get("uri").and_then(|u| u.as_str()) else {
        return;
    };
    let path = uri_to_path(uri);
    let mut list = Vec::new();
    if let Some(items) = params.get("diagnostics").and_then(|d| d.as_array()) {
        for item in items {
            let line = item
                .get("range")
                .and_then(|r| r.get("start"))
                .and_then(|s| s.get("line"))
                .and_then(|l| l.as_i64())
                .unwrap_or(0) as usize;
            let col = item
                .get("range")
                .and_then(|r| r.get("start"))
                .and_then(|s| s.get("character"))
                .and_then(|c| c.as_i64())
                .unwrap_or(0) as usize;
            let end_line = item
                .get("range")
                .and_then(|r| r.get("end"))
                .and_then(|s| s.get("line"))
                .and_then(|l| l.as_i64())
                .unwrap_or(line as i64) as usize;
            let end_col = item
                .get("range")
                .and_then(|r| r.get("end"))
                .and_then(|s| s.get("character"))
                .and_then(|c| c.as_i64())
                .unwrap_or(col as i64) as usize;
            let severity = item
                .get("severity")
                .and_then(|s| s.as_i64())
                .unwrap_or(1) as u8;
            let message = item
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("")
                .to_string();
            list.push(Diagnostic {
                line,
                col,
                end_line,
                end_col,
                severity,
                message,
            });
        }
    }
    if let Ok(mut map) = store.lock() {
        map.insert(path, list);
    }
}

fn utf16_col(line: &str, char_col: usize) -> usize {
    line.chars()
        .take(char_col)
        .map(|c| c.len_utf16())
        .sum()
}

fn position_json(text: &str, line: usize, col: usize) -> Json {
    let line_text = text.lines().nth(line).unwrap_or("");
    json::object(vec![
        ("line", Json::Number(line as f64)),
        ("character", Json::Number(utf16_col(line_text, col) as f64)),
    ])
}

/// LSP Range（UTF-16 列号）。
fn range_json(start_line: usize, start_col: usize, end_line: usize, end_col: usize) -> Json {
    json::object(vec![
        (
            "start",
            json::object(vec![
                ("line", Json::Number(start_line as f64)),
                ("character", Json::Number(start_col as f64)),
            ]),
        ),
        (
            "end",
            json::object(vec![
                ("line", Json::Number(end_line as f64)),
                ("character", Json::Number(end_col as f64)),
            ]),
        ),
    ])
}

/// UTF-16 列号 → 字符列号。
fn utf16_to_char_col(line: &str, utf16: usize) -> usize {
    let mut units = 0usize;
    let mut chars = 0usize;
    for ch in line.chars() {
        let next = units + ch.len_utf16();
        if next > utf16 {
            break;
        }
        units = next;
        chars += 1;
    }
    chars
}

fn error_message(error: &Json) -> String {
    error
        .get("message")
        .and_then(|message| message.as_str())
        .unwrap_or("语言服务器返回错误")
        .to_string()
}

/// 解析签名帮助。
fn parse_signature_help(result: &Json) -> Option<SignatureHelp> {
    let signatures = result.get("signatures")?.as_array()?;
    let mut items = Vec::new();
    for signature in signatures {
        let label = signature
            .get("label")
            .and_then(|label| label.as_str())
            .unwrap_or("");
        if label.is_empty() {
            continue;
        }
        let docs = signature
            .get("documentation")
            .and_then(hover_text)
            .unwrap_or_default();
        items.push(SignatureItem {
            label: label.to_string(),
            docs,
        });
    }
    if items.is_empty() {
        return None;
    }
    let active = result
        .get("activeSignature")
        .and_then(|value| value.as_i64())
        .unwrap_or(0)
        .max(0) as usize;
    let parameter = result
        .get("activeParameter")
        .and_then(|value| value.as_i64())
        .unwrap_or(0)
        .max(0) as usize;
    Some(SignatureHelp {
        signatures: items,
        active: active.min(signatures.len().saturating_sub(1)),
        parameter,
    })
}

/// 解析代码操作；只保留带编辑的项。
fn parse_code_actions(result: &Json, default_path: &Path) -> Vec<CodeAction> {
    let mut out = Vec::new();
    for item in result.as_array().unwrap_or(&[]) {
        let Some(title) = item.get("title").and_then(|title| title.as_str()) else {
            continue;
        };
        let kind = item
            .get("kind")
            .and_then(|kind| kind.as_str())
            .unwrap_or("")
            .to_string();
        let mut edits = item
            .get("edit")
            .map(parse_workspace_edit)
            .unwrap_or_default();
        for edit in &mut edits {
            if edit.path.as_os_str().is_empty() {
                edit.path = default_path.to_path_buf();
            }
        }
        if edits.is_empty() {
            continue;
        }
        out.push(CodeAction {
            title: title.to_string(),
            kind,
            edits,
        });
        if out.len() >= 100 {
            break;
        }
    }
    out
}

/// 解析内联提示；label 支持字符串与分段数组，列号换算为字符列。
fn parse_inlay_hints(result: &Json, text: &str) -> Vec<InlayHint> {
    let mut out = Vec::new();
    for item in result.as_array().unwrap_or(&[]) {
        let Some(position) = item.get("position") else {
            continue;
        };
        let line = position
            .get("line")
            .and_then(|line| line.as_i64())
            .unwrap_or(0)
            .max(0) as usize;
        let character = position
            .get("character")
            .and_then(|character| character.as_i64())
            .unwrap_or(0)
            .max(0) as usize;
        let mut label = match item.get("label") {
            Some(Json::String(text)) => text.clone(),
            Some(Json::Array(parts)) => parts
                .iter()
                .filter_map(|part| part.get("value").and_then(|value| value.as_str()))
                .collect(),
            _ => continue,
        };
        if label.is_empty() {
            continue;
        }
        if item
            .get("paddingLeft")
            .and_then(|value| value.as_bool())
            .unwrap_or(true)
        {
            label.insert(0, ' ');
        }
        if item
            .get("paddingRight")
            .and_then(|value| value.as_bool())
            .unwrap_or(false)
        {
            label.push(' ');
        }
        let line_text = text.lines().nth(line).unwrap_or("");
        out.push(InlayHint {
            line,
            col: utf16_to_char_col(line_text, character),
            label,
        });
        if out.len() >= 2000 {
            break;
        }
    }
    out.sort_by_key(|hint| (hint.line, hint.col));
    out
}

/// 提取 Hover.contents：支持字符串、MarkupContent、MarkedString 数组。
fn hover_text(contents: &Json) -> Option<String> {
    match contents {
        Json::String(text) => Some(text.clone()),
        Json::Array(items) => {
            let parts: Vec<String> = items.iter().filter_map(hover_text).collect();
            if parts.is_empty() {
                None
            } else {
                Some(parts.join("\n\n"))
            }
        }
        Json::Object(_) => contents
            .get("value")
            .and_then(|value| value.as_str())
            .map(|value| value.to_string()),
        _ => None,
    }
}

fn parse_edit_array(result: &Json) -> Vec<LspEdit> {
    let mut edits = Vec::new();
    collect_edits("", result, &mut edits);
    edits
}

fn parse_workspace_edit(result: &Json) -> Vec<LspEdit> {
    let mut edits = Vec::new();
    if let Some(Json::Object(changes)) = result.get("changes") {
        for (uri, list) in changes {
            collect_edits(uri, list, &mut edits);
        }
    }
    if let Some(documents) = result.get("documentChanges").and_then(|d| d.as_array()) {
        for document in documents {
            let uri = document
                .get("textDocument")
                .and_then(|document| document.get("uri"))
                .and_then(|uri| uri.as_str())
                .unwrap_or("");
            if let Some(list) = document.get("edits") {
                collect_edits(uri, list, &mut edits);
            }
        }
    }
    edits
}

fn collect_edits(uri: &str, list: &Json, out: &mut Vec<LspEdit>) {
    let path = if uri.is_empty() {
        PathBuf::new()
    } else {
        uri_to_path(uri)
    };
    for edit in list.as_array().unwrap_or(&[]) {
        let Some(range) = edit.get("range") else {
            continue;
        };
        let Some(start) = range.get("start") else {
            continue;
        };
        let Some(end) = range.get("end") else {
            continue;
        };
        let Some(new_text) = edit.get("newText").and_then(|text| text.as_str()) else {
            continue;
        };
        out.push(LspEdit {
            path: path.clone(),
            start_line: start.get("line").and_then(|l| l.as_i64()).unwrap_or(0) as usize,
            start_col: start
                .get("character")
                .and_then(|c| c.as_i64())
                .unwrap_or(0) as usize,
            end_line: end.get("line").and_then(|l| l.as_i64()).unwrap_or(0) as usize,
            end_col: end.get("character").and_then(|c| c.as_i64()).unwrap_or(0) as usize,
            new_text: new_text.to_string(),
        });
    }
}

/// SymbolKind 数字到中文标签。
fn symbol_kind_label(kind: i64) -> &'static str {
    match kind {
        1 => "文件",
        2 => "模块",
        3 => "命名空间",
        4 => "包",
        5 => "类",
        6 => "方法",
        7 => "属性",
        8 => "字段",
        9 => "构造函数",
        10 => "枚举",
        11 => "接口",
        12 => "函数",
        13 => "变量",
        14 => "常量",
        22 => "枚举成员",
        23 => "结构体",
        24 => "事件",
        25 => "运算符",
        26 => "类型参数",
        _ => "符号",
    }
}

fn path_to_uri(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    let text = if text.starts_with('/') {
        text
    } else {
        format!("/{text}")
    };
    let mut encoded = String::from("file://");
    for ch in text.chars() {
        match ch {
            ' ' => encoded.push_str("%20"),
            '#' => encoded.push_str("%23"),
            '%' => encoded.push_str("%25"),
            _ => encoded.push(ch),
        }
    }
    encoded
}

fn uri_to_path(uri: &str) -> PathBuf {
    let rest = uri.strip_prefix("file://").unwrap_or(uri);
    let mut text = String::new();
    let bytes: Vec<char> = rest.chars().collect();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == '%' && i + 3 <= bytes.len() {
            let hex: String = bytes[i + 1..i + 3].iter().collect();
            if let Ok(value) = u8::from_str_radix(&hex, 16) {
                text.push(value as char);
                i += 3;
                continue;
            }
        }
        text.push(bytes[i]);
        i += 1;
    }
    // /F:/path -> F:/path
    let text = text.trim_start_matches('/');
    PathBuf::from(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_roundtrip() {
        let path = PathBuf::from(r"F:\Windows Server core GUI tool\a b.txt");
        let uri = path_to_uri(&path);
        assert!(uri.starts_with("file:///F:/"));
        assert!(uri.contains("%20"));
        let back = uri_to_path(&uri);
        assert_eq!(back, path);
    }

    #[test]
    fn utf16_columns() {
        assert_eq!(utf16_col("abc", 2), 2);
        assert_eq!(utf16_col("中a", 1), 1);
        assert_eq!(utf16_col("😀a", 1), 2);
    }

    #[test]
    fn signature_help_parsing() {
        let result = json::parse(
            r#"{"signatures":[{"label":"fn f(a: u8, b: u8)","documentation":"示例"},
            {"label":"fn f()"}],"activeSignature":1,"activeParameter":0}"#,
        )
        .unwrap();
        let help = parse_signature_help(&result).expect("解析签名帮助失败");
        assert_eq!(help.signatures.len(), 2);
        assert_eq!(help.signatures[0].docs, "示例");
        assert_eq!(help.active, 1);
        assert_eq!(help.parameter, 0);
        // 越界的 activeSignature 会被收敛到有效范围。
        let result = json::parse(
            r#"{"signatures":[{"label":"a"}],"activeSignature":9}"#,
        )
        .unwrap();
        assert_eq!(parse_signature_help(&result).unwrap().active, 0);
    }

    #[test]
    fn code_action_parsing() {
        let result = json::parse(
            r#"[{"title":"导入缺失的模块","kind":"quickfix","edit":{"changes":{
            "file:///F:/work/a%20b.rs":[{"range":{"start":{"line":1,"character":2},
            "end":{"line":1,"character":4}},"newText":"use foo;"}]}}},
            {"title":"无编辑的操作","kind":"refactor"}]"#,
        )
        .unwrap();
        let actions = parse_code_actions(&result, Path::new(r"F:\work\a b.rs"));
        assert_eq!(actions.len(), 1);
        assert_eq!(actions[0].title, "导入缺失的模块");
        assert_eq!(actions[0].kind, "quickfix");
        assert_eq!(actions[0].edits.len(), 1);
        assert_eq!(actions[0].edits[0].start_line, 1);
        assert_eq!(actions[0].edits[0].new_text, "use foo;");
    }

    #[test]
    fn inlay_hint_parsing() {
        let result = json::parse(
            r#"[{"position":{"line":0,"character":5},"label":"参数名:"},
            {"position":{"line":0,"character":5},"label":[{"value":": "},{"value":"u8"}],
            "paddingLeft":false,"paddingRight":true}]"#,
        )
        .unwrap();
        let hints = parse_inlay_hints(&result, "let x = 1;");
        assert_eq!(hints.len(), 2);
        assert_eq!(hints[0].col, 5);
        assert_eq!(hints[0].label, " 参数名:");
        assert_eq!(hints[1].label, ": u8 ");
    }
}

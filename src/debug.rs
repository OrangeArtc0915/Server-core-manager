//! 调试器：Debug Adapter Protocol（DAP）客户端。
//!
//! 传输层是 stdio 上的 `Content-Length` 帧 + JSON，和 LSP 类似但不共用形态；
//! 适配器命令在 `config.ini` 中用 `debug.<type> = 命令` 指定，例如：
//!   debug.python = python -m debugpy.adapter
//!   debug.cpp    = lldb-dap
//! 未配置时 python / debugpy 默认使用 `python -m debugpy.adapter`。

use crate::lsp::json::{self, Json};
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

// ---------------------------------------------------------------- launch.json

#[derive(Clone, Debug)]
pub struct LaunchConfig {
    pub name: String,
    pub kind: String,
    pub request: String,
    /// 原始配置对象，启动时展开 `${...}` 后整体发给适配器。
    pub raw: Json,
    /// 配置所属工作区根（用于 ${workspaceFolder} 展开）。
    pub root: Option<PathBuf>,
}

/// 读取工作区根目录下的 `.vscode/launch.json`（也接受根目录 launch.json）。
pub fn load_launch_configs(root: &Path) -> Vec<LaunchConfig> {
    let candidates = [
        root.join(".vscode").join("launch.json"),
        root.join("launch.json"),
    ];
    for path in candidates {
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(value) = json::parse(&text) else {
            continue;
        };
        let configs = parse_launch(&value);
        if !configs.is_empty() {
            return configs
                .into_iter()
                .map(|mut config| {
                    config.root = Some(root.to_path_buf());
                    config
                })
                .collect();
        }
    }
    Vec::new()
}

pub fn parse_launch(value: &Json) -> Vec<LaunchConfig> {
    let Some(list) = value.get("configurations").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in list {
        let kind = item
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if kind.is_empty() {
            continue;
        }
        let name = item
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("未命名配置")
            .to_string();
        let request = item
            .get("request")
            .and_then(|v| v.as_str())
            .unwrap_or("launch")
            .to_string();
        out.push(LaunchConfig {
            name,
            kind,
            request,
            raw: item.clone(),
            root: None,
        });
    }
    out
}

/// 适配器命令：优先使用配置中的 `debug.<type>`，否则用内置默认值。
pub fn adapter_for(kind: &str, custom: &HashMap<String, String>) -> Option<String> {
    if let Some(command) = custom.get(kind) {
        if !command.trim().is_empty() {
            return Some(command.clone());
        }
    }
    match kind.to_ascii_lowercase().as_str() {
        "python" | "debugpy" => Some("python -m debugpy.adapter".into()),
        "lldb" | "dap" => Some("lldb-dap".into()),
        _ => None,
    }
}

/// 展开配置中的 `${workspaceFolder}` 等占位符。
pub fn expand(text: &str, root: &Path, file: Option<&Path>) -> String {
    let mut out = text
        .replace("${workspaceFolder}", &root.to_string_lossy())
        .replace("${workspaceRoot}", &root.to_string_lossy())
        .replace(
            "${workspaceFolderBasename}",
            &root
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
        );
    if let Some(file) = file {
        out = out
            .replace("${file}", &file.to_string_lossy())
            .replace(
                "${fileBasename}",
                &file
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default(),
            )
            .replace(
                "${fileDirname}",
                &file
                    .parent()
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or_default(),
            );
    }
    // ${env:NAME}
    while let Some(start) = out.find("${env:") {
        let Some(rel_end) = out[start..].find('}') else {
            break;
        };
        let end = start + rel_end;
        let name = &out[start + 6..end];
        let value = std::env::var(name).unwrap_or_default();
        out.replace_range(start..=end, &value);
    }
    out
}

fn expand_json(value: &Json, root: &Path, file: Option<&Path>) -> Json {
    match value {
        Json::String(text) => Json::String(expand(text, root, file)),
        Json::Array(items) => Json::Array(
            items
                .iter()
                .map(|item| expand_json(item, root, file))
                .collect(),
        ),
        Json::Object(map) => {
            let mut out = BTreeMap::new();
            for (key, item) in map {
                out.insert(key.clone(), expand_json(item, root, file));
            }
            Json::Object(out)
        }
        other => other.clone(),
    }
}

/// 把一行命令拆成程序与参数（支持双引号包裹的参数）。
pub fn split_command(line: &str) -> (String, Vec<String>) {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut started = false;
    for ch in line.chars() {
        match ch {
            '"' => {
                quoted = !quoted;
                started = true;
            }
            c if c.is_whitespace() && !quoted => {
                if started {
                    args.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            c => {
                current.push(c);
                started = true;
            }
        }
    }
    if started {
        args.push(current);
    }
    if args.is_empty() {
        return (String::new(), Vec::new());
    }
    let program = args.remove(0);
    (program, args)
}

pub fn normalize(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

// ---------------------------------------------------------------- DAP 传输

pub struct DapClient {
    child: Option<Child>,
    stdin: Arc<Mutex<ChildStdin>>,
    incoming: Arc<Mutex<VecDeque<Json>>>,
    alive: Arc<AtomicBool>,
    seq: i64,
    pub adapter: String,
}

impl DapClient {
    pub fn spawn(
        line: &str,
        cwd: &Path,
        log: Arc<Mutex<Vec<String>>>,
    ) -> Result<DapClient, String> {
        let (program, args) = split_command(line);
        if program.is_empty() {
            return Err("调试适配器命令为空".into());
        }
        let mut command = Command::new(&program);
        command
            .args(&args)
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = command
            .spawn()
            .map_err(|e| format!("无法启动调试适配器 {program}：{e}"))?;
        let stdin = child.stdin.take().ok_or("适配器没有 stdin")?;
        let stdout = child.stdout.take().ok_or("适配器没有 stdout")?;
        let stderr = child.stderr.take();
        let incoming = Arc::new(Mutex::new(VecDeque::new()));
        let alive = Arc::new(AtomicBool::new(true));
        push_log(&log, format!("启动调试适配器：{line}"));
        {
            let incoming = incoming.clone();
            let alive = alive.clone();
            let log = log.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stdout);
                while let Some(message) = read_message(&mut reader) {
                    if let Ok(mut queue) = incoming.lock() {
                        queue.push_back(message);
                    }
                }
                alive.store(false, Ordering::SeqCst);
                push_log(&log, "调试适配器已退出".to_string());
            });
        }
        if let Some(stderr) = stderr {
            let log = log.clone();
            std::thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines().map_while(Result::ok) {
                    push_log(&log, line);
                }
            });
        }
        Ok(DapClient {
            child: Some(child),
            stdin: Arc::new(Mutex::new(stdin)),
            incoming,
            alive,
            seq: 0,
            adapter: line.to_string(),
        })
    }

    pub fn send(&mut self, command: &str, args: Json) -> i64 {
        self.seq += 1;
        let seq = self.seq;
        let message = json::object(vec![
            ("seq", Json::Number(seq as f64)),
            ("type", Json::String("request".into())),
            ("command", Json::String(command.to_string())),
            ("arguments", args),
        ]);
        let body = message.dump();
        let header = format!("Content-Length: {}\r\n\r\n", body.as_bytes().len());
        if let Ok(mut guard) = self.stdin.lock() {
            let _ = guard.write_all(header.as_bytes());
            let _ = guard.write_all(body.as_bytes());
            let _ = guard.flush();
        }
        seq
    }

    pub fn drain(&self) -> Vec<Json> {
        let mut out = Vec::new();
        if let Ok(mut queue) = self.incoming.lock() {
            while let Some(message) = queue.pop_front() {
                out.push(message);
            }
        }
        out
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    pub fn kill(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
        }
        self.child = None;
        self.alive.store(false, Ordering::SeqCst);
    }
}

impl Drop for DapClient {
    fn drop(&mut self) {
        if self.child.is_some() {
            self.kill();
        }
    }
}

fn read_message<R: BufRead>(reader: &mut R) -> Option<Json> {
    let mut length = 0usize;
    let mut line = Vec::new();
    loop {
        line.clear();
        let read = reader.read_until(b'\n', &mut line).ok()?;
        if read == 0 {
            return None;
        }
        let text = String::from_utf8_lossy(&line);
        let trimmed = text.trim();
        if trimmed.is_empty() {
            break;
        }
        if let Some((key, value)) = trimmed.split_once(':') {
            if key.trim().eq_ignore_ascii_case("content-length") {
                length = value.trim().parse().ok()?;
            }
        }
    }
    if length == 0 {
        return None;
    }
    let mut buffer = vec![0u8; length];
    reader.read_exact(&mut buffer).ok()?;
    let text = String::from_utf8_lossy(&buffer);
    json::parse(&text).ok()
}

pub fn push_log(log: &Arc<Mutex<Vec<String>>>, line: impl Into<String>) {
    let mut guard = match log.lock() {
        Ok(guard) => guard,
        Err(e) => e.into_inner(),
    };
    guard.push(line.into());
    if guard.len() > 4000 {
        guard.drain(0..1000);
    }
}

// ---------------------------------------------------------------- 调试状态

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub id: i64,
    pub name: String,
    pub line: usize,
    pub path: Option<PathBuf>,
}

pub struct DebugState {
    pub configs: Vec<LaunchConfig>,
    pub breakpoints: BTreeMap<PathBuf, BTreeSet<usize>>,
    pub client: Option<DapClient>,
    pub status: String,
    pub running: bool,
    pub stopped: bool,
    pub thread: Option<i64>,
    pub frames: Vec<Frame>,
    pub variables: Vec<(String, String)>,
    pub log: Arc<Mutex<Vec<String>>>,
    pending: HashMap<i64, String>,
    launch: Option<Json>,
    pub workspace: PathBuf,
}

impl Default for DebugState {
    fn default() -> Self {
        DebugState::new()
    }
}

impl DebugState {
    pub fn new() -> DebugState {
        DebugState {
            configs: Vec::new(),
            breakpoints: BTreeMap::new(),
            client: None,
            status: String::new(),
            running: false,
            stopped: false,
            thread: None,
            frames: Vec::new(),
            variables: Vec::new(),
            log: Arc::new(Mutex::new(Vec::new())),
            pending: HashMap::new(),
            launch: None,
            workspace: PathBuf::new(),
        }
    }

    pub fn is_active(&self) -> bool {
        self.client.is_some()
    }

    pub fn has_breakpoint(&self, path: &Path, line: usize) -> bool {
        self.breakpoints
            .get(path)
            .map(|set| set.contains(&line))
            .unwrap_or(false)
    }

    /// 切换断点，返回切换后是否处于断点状态。
    pub fn toggle_breakpoint(&mut self, path: &Path, line: usize) -> bool {
        let key = normalize(path);
        let entry = self.breakpoints.entry(key).or_default();
        if entry.remove(&line) {
            false
        } else {
            entry.insert(line);
            true
        }
    }

    pub fn tail_log(&self, max: usize) -> Vec<String> {
        let guard = match self.log.lock() {
            Ok(guard) => guard,
            Err(e) => e.into_inner(),
        };
        let start = guard.len().saturating_sub(max);
        guard[start..].to_vec()
    }

    pub fn push_log(&self, line: impl Into<String>) {
        push_log(&self.log, line);
    }

    /// 发送请求并登记，便于应答时识别命令。
    pub fn request(&mut self, command: &str, args: Json) -> Option<i64> {
        let client = self.client.as_mut()?;
        let seq = client.send(command, args);
        self.pending.insert(seq, command.to_string());
        Some(seq)
    }

    /// 启动会话：`raw` 为已展开的 launch 配置对象。
    pub fn start(&mut self, adapter: &str, workspace: &Path, raw: Json) {
        match DapClient::spawn(adapter, workspace, self.log.clone()) {
            Ok(client) => {
                self.client = Some(client);
                self.workspace = workspace.to_path_buf();
                self.launch = Some(raw);
                self.status = "正在启动调试会话…".into();
                self.running = false;
                self.stopped = false;
                self.frames.clear();
                self.variables.clear();
                self.request(
                    "initialize",
                    json::object(vec![
                        ("clientID", Json::String("textm".into())),
                        ("clientName", Json::String("Textm".into())),
                        ("adapterID", Json::String("textm".into())),
                        ("linesStartAt1", Json::Bool(true)),
                        ("columnsStartAt1", Json::Bool(true)),
                        ("pathFormat", Json::String("path".into())),
                        ("supportsVariableType", Json::Bool(true)),
                    ]),
                );
            }
            Err(e) => {
                self.status = e.clone();
                push_log(&self.log, e);
            }
        }
    }

    /// 为每个文件发送断点集合。
    pub fn flush_breakpoints(&mut self) {
        let entries: Vec<(PathBuf, Vec<usize>)> = self
            .breakpoints
            .iter()
            .filter(|(_, lines)| !lines.is_empty())
            .map(|(path, lines)| (path.clone(), lines.iter().map(|l| l + 1).collect()))
            .collect();
        for (path, lines) in entries {
            let breakpoints: Vec<Json> = lines
                .iter()
                .map(|line| json::object(vec![("line", Json::Number(*line as f64))]))
                .collect();
            let args = json::object(vec![
                (
                    "source",
                    json::object(vec![(
                        "path",
                        Json::String(path.to_string_lossy().to_string()),
                    )]),
                ),
                ("breakpoints", Json::Array(breakpoints)),
                (
                    "lines",
                    Json::Array(lines.iter().map(|l| Json::Number(*l as f64)).collect()),
                ),
                ("sourceModified", Json::Bool(false)),
            ]);
            self.request("setBreakpoints", args);
        }
    }

    /// 处理一条 DAP 消息；返回需要跳转到的源码位置。
    pub fn ingest(&mut self, message: &Json) -> Option<(PathBuf, usize)> {
        let kind = message.get("type").and_then(|v| v.as_str()).unwrap_or("");
        match kind {
            "response" => self.handle_response(message),
            "event" => self.handle_event(message),
            _ => None,
        }
    }

    fn handle_response(&mut self, message: &Json) -> Option<(PathBuf, usize)> {
        let seq = message.get("request_seq").and_then(|v| v.as_i64()).unwrap_or(-1);
        let command = self
            .pending
            .remove(&seq)
            .or_else(|| {
                message
                    .get("command")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_default();
        let success = message
            .get("success")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        if !success {
            let text = message
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("未知错误");
            self.push_log(format!("{command} 失败：{text}"));
            self.status = format!("调试失败：{text}");
            return None;
        }
        match command.as_str() {
            "initialize" => {
                if let Some(raw) = self.launch.take() {
                    let command = match raw.get("request").and_then(|v| v.as_str()) {
                        Some("attach") => "attach",
                        _ => "launch",
                    };
                    self.request(command, raw);
                    self.status = "调试适配器已连接".into();
                }
            }
            "launch" | "attach" => {
                self.running = true;
                self.status = "运行中…".into();
            }
            "stackTrace" => {
                self.frames.clear();
                let frames = message
                    .get("body")
                    .and_then(|b| b.get("stackFrames"))
                    .and_then(|f| f.as_array())
                    .map(|list| list.to_vec())
                    .unwrap_or_default();
                for frame in &frames {
                    let id = frame.get("id").and_then(|v| v.as_i64()).unwrap_or(0);
                    let name = frame
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let line = frame
                        .get("line")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(1)
                        .max(1) as usize;
                    let path = frame
                        .get("source")
                        .and_then(|s| s.get("path"))
                        .and_then(|v| v.as_str())
                        .map(PathBuf::from);
                    self.frames.push(Frame {
                        id,
                        name,
                        line,
                        path,
                    });
                }
                if let Some(first) = self.frames.first().cloned() {
                    let thread = self.thread.unwrap_or(0);
                    self.request(
                        "scopes",
                        json::object(vec![
                            ("frameId", Json::Number(first.id as f64)),
                            ("threadId", Json::Number(thread as f64)),
                        ]),
                    );
                    if let Some(path) = first.path.clone() {
                        return Some((path, first.line));
                    }
                }
            }
            "scopes" => {
                let reference = message
                    .get("body")
                    .and_then(|b| b.get("scopes"))
                    .and_then(|s| s.as_array())
                    .and_then(|list| list.first())
                    .and_then(|scope| scope.get("variablesReference"))
                    .and_then(|v| v.as_i64());
                if let Some(reference) = reference {
                    self.request(
                        "variables",
                        json::object(vec![("variablesReference", Json::Number(reference as f64))]),
                    );
                }
            }
            "variables" => {
                self.variables.clear();
                let vars = message
                    .get("body")
                    .and_then(|b| b.get("variables"))
                    .and_then(|v| v.as_array())
                    .map(|list| list.to_vec())
                    .unwrap_or_default();
                for var in vars {
                    let name = var
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let value = var
                        .get("value")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let kind = var
                        .get("type")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let text = if kind.is_empty() {
                        format!("{name} = {value}")
                    } else {
                        format!("{name} = {value}  ({kind})")
                    };
                    self.variables.push((name, text));
                }
            }
            "continue" | "next" | "stepIn" | "stepOut" => {
                self.running = true;
                self.stopped = false;
                self.thread = message
                    .get("body")
                    .and_then(|b| b.get("threadId"))
                    .and_then(|v| v.as_i64())
                    .or(self.thread);
                self.status = "运行中…".into();
            }
            _ => {}
        }
        None
    }

    fn handle_event(&mut self, message: &Json) -> Option<(PathBuf, usize)> {
        let event = message.get("event").and_then(|v| v.as_str()).unwrap_or("");
        let body = message.get("body").cloned().unwrap_or(Json::Null);
        match event {
            "initialized" => {
                self.flush_breakpoints();
                self.set_exception_breakpoints();
                self.request("configurationDone", Json::Object(BTreeMap::new()));
            }
            "stopped" => {
                let reason = body
                    .get("reason")
                    .and_then(|v| v.as_str())
                    .unwrap_or("pause");
                self.stopped = true;
                self.running = false;
                self.status = match reason {
                    "breakpoint" => "已暂停：断点".to_string(),
                    "exception" => "已暂停：异常".to_string(),
                    "step" => "已暂停：单步".to_string(),
                    "entry" => "已暂停：入口".to_string(),
                    other => format!("已暂停：{other}"),
                };
                self.thread = body.get("threadId").and_then(|v| v.as_i64()).or(self.thread);
                if let Some(thread) = self.thread {
                    self.request(
                        "stackTrace",
                        json::object(vec![
                            ("threadId", Json::Number(thread as f64)),
                            ("startFrame", Json::Number(0.0)),
                            ("levels", Json::Number(20.0)),
                        ]),
                    );
                }
            }
            "continued" => {
                self.running = true;
                self.stopped = false;
                self.status = "运行中…".into();
            }
            "output" => {
                let text = body
                    .get("output")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .trim_end()
                    .to_string();
                if !text.is_empty() {
                    for line in text.lines() {
                        self.push_log(line.to_string());
                    }
                }
            }
            "terminated" | "exited" => {
                self.push_log("调试会话已结束".to_string());
                self.shutdown();
                self.status = "调试会话已结束".into();
            }
            _ => {}
        }
        None
    }

    fn set_exception_breakpoints(&mut self) {
        self.request(
            "setExceptionBreakpoints",
            json::object(vec![(
                "filters",
                Json::Array(vec![Json::String("uncaught".into())]),
            )]),
        );
    }

    pub fn continue_run(&mut self) {
        let thread = self.thread.unwrap_or(1);
        self.request(
            "continue",
            json::object(vec![("threadId", Json::Number(thread as f64))]),
        );
    }

    pub fn single_step(&mut self, command: &str) {
        let thread = self.thread.unwrap_or(1);
        self.request(
            command,
            json::object(vec![("threadId", Json::Number(thread as f64))]),
        );
    }

    pub fn shutdown(&mut self) {
        if self.client.is_some() {
            self.request(
                "disconnect",
                json::object(vec![("terminateDebuggee", Json::Bool(true))]),
            );
            if let Some(client) = self.client.as_mut() {
                client.kill();
            }
        }
        self.client = None;
        self.running = false;
        self.stopped = false;
        self.frames.clear();
        self.variables.clear();
        self.status = "调试已停止".into();
    }
}

/// 展开并准备 launch 参数：python 类型强制使用内部输出通道。
pub fn prepare_launch(config: &LaunchConfig, workspace: &Path, file: Option<&Path>) -> Json {
    let mut value = expand_json(&config.raw, workspace, file);
    if let Json::Object(map) = &mut value {
        if config.request == "launch"
            && matches!(config.kind.to_ascii_lowercase().as_str(), "python" | "debugpy")
            && !map.contains_key("console")
        {
            map.insert("console".into(), Json::String("internalConsole".into()));
        }
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_launch_configurations() {
        let text = r#"{
            "version": "0.2.0",
            "configurations": [
                {"name": "Python: 当前文件", "type": "python", "request": "launch",
                 "program": "${workspaceFolder}/main.py"}
            ]
        }"#;
        let value = json::parse(text).unwrap();
        let configs = parse_launch(&value);
        assert_eq!(configs.len(), 1);
        assert_eq!(configs[0].kind, "python");
        assert_eq!(configs[0].request, "launch");
    }

    #[test]
    fn split_command_handles_quotes() {
        let (program, args) = split_command(r#"python -m "debug py".adapter --x"#);
        assert_eq!(program, "python");
        assert_eq!(args, vec!["-m", "debug py.adapter", "--x"]);
    }

    #[test]
    fn expand_placeholders() {
        let root = Path::new("C:/work");
        let file = Path::new("C:/work/src/main.py");
        assert_eq!(
            expand("${workspaceFolder}/a.py", root, None),
            "C:/work/a.py"
        );
        assert_eq!(expand("${workspaceFolderBasename}", root, None), "work");
        assert_eq!(expand("${fileBasename}", root, Some(file)), "main.py");
        std::env::set_var("TEXTM_TEST_ENV", "42");
        assert_eq!(expand("v=${env:TEXTM_TEST_ENV}", root, None), "v=42");
    }

    #[test]
    fn breakpoints_toggle() {
        let mut state = DebugState::new();
        let path = Path::new("C:/work/main.py");
        assert!(state.toggle_breakpoint(path, 3));
        assert!(state.has_breakpoint(path, 3));
        assert!(!state.toggle_breakpoint(path, 3));
        assert!(!state.has_breakpoint(path, 3));
    }

    #[test]
    fn read_message_parses_content_length_frames() {
        let body = r#"{"seq":1,"type":"event","event":"initialized","body":{}}"#;
        let raw = format!("Content-Length: {}\r\n\r\n{}", body.len(), body);
        let mut reader = std::io::BufReader::new(std::io::Cursor::new(raw.into_bytes()));
        let message = read_message(&mut reader).expect("应解析出消息");
        assert_eq!(
            message.get("event").and_then(|v| v.as_str()),
            Some("initialized")
        );
        // 读到 EOF 后返回 None，读取线程据此退出。
        assert!(read_message(&mut reader).is_none());
    }

    #[test]
    fn python_launch_uses_internal_console() {
        let value = json::parse(
            r#"{"name":"py","type":"python","request":"launch","program":"${workspaceFolder}/a.py"}"#,
        )
        .unwrap();
        let config = parse_launch(&json::object(vec![(
            "configurations",
            Json::Array(vec![value]),
        )]))
        .remove(0);
        let raw = prepare_launch(&config, Path::new("C:/w"), None);
        assert_eq!(raw.get("program").and_then(|v| v.as_str()), Some("C:/w/a.py"));
        assert_eq!(
            raw.get("console").and_then(|v| v.as_str()),
            Some("internalConsole")
        );
    }
}

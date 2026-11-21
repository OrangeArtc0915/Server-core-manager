//! 任务运行器：读取 `.vscode/tasks.json`，在后台运行并收集输出。

use crate::lsp::json::{self, Json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Task {
    pub label: String,
    pub command: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    /// 是否标记为默认构建任务（group 字段存在）。
    pub group: bool,
}

impl Task {
    pub fn command_line(&self) -> String {
        let mut line = self.command.clone();
        for arg in &self.args {
            line.push(' ');
            if arg.contains(' ') || arg.contains('"') {
                line.push('"');
                line.push_str(&arg.replace('"', "\\\""));
                line.push('"');
            } else {
                line.push_str(arg);
            }
        }
        line
    }
}

/// 读取工作区根目录下的 tasks.json（优先 .vscode/）。
pub fn load(root: &Path) -> Vec<Task> {
    let candidates = [
        root.join(".vscode").join("tasks.json"),
        root.join("tasks.json"),
    ];
    for path in candidates {
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(value) = json::parse(&text) else {
            continue;
        };
        let tasks = parse_tasks(&value, root);
        if !tasks.is_empty() {
            return tasks;
        }
    }
    Vec::new()
}

fn parse_tasks(value: &Json, root: &Path) -> Vec<Task> {
    let Some(array) = value.get("tasks").and_then(|t| t.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in array {
        let Some(label) = item.get("label").and_then(|l| l.as_str()) else {
            continue;
        };
        let command = item
            .get("command")
            .and_then(|c| c.as_str())
            .unwrap_or("")
            .to_string();
        if command.is_empty() {
            continue;
        }
        let args = item
            .get("args")
            .and_then(|a| a.as_array())
            .map(|list| {
                list.iter()
                    .filter_map(|x| x.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();
        let cwd = item
            .get("options")
            .and_then(|o| o.get("cwd"))
            .and_then(|c| c.as_str())
            .map(|c| root.join(c));
        let group = item.get("group").is_some();
        out.push(Task {
            label: label.to_string(),
            command,
            args,
            cwd,
            group,
        });
    }
    out
}

/// 一个正在运行或已结束的任务。
pub struct TaskRun {
    pub label: String,
    pub output: Arc<Mutex<Vec<String>>>,
    pub done: Arc<AtomicBool>,
    pub exit: Arc<Mutex<Option<i32>>>,
    child: Option<Child>,
}

impl TaskRun {
    pub fn start(task: &Task) -> Result<TaskRun, String> {
        let mut command = Command::new("cmd");
        command.arg("/C").arg(task.command_line());
        if let Some(dir) = &task.cwd {
            command.current_dir(dir);
        }
        command
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::null());
        let mut child = command
            .spawn()
            .map_err(|e| format!("无法启动任务：{e}"))?;
        let output = Arc::new(Mutex::new(Vec::new()));
        let done = Arc::new(AtomicBool::new(false));
        let exit = Arc::new(Mutex::new(None));
        if let Some(stdout) = child.stdout.take() {
            spawn_reader(stdout, output.clone());
        }
        if let Some(stderr) = child.stderr.take() {
            spawn_reader(stderr, output.clone());
        }
        Ok(TaskRun {
            label: task.label.clone(),
            output,
            done,
            exit,
            child: Some(child),
        })
    }

    /// 非阻塞检查是否结束；返回是否刚刚结束。
    pub fn poll(&mut self) -> bool {
        let Some(child) = self.child.as_mut() else {
            return false;
        };
        match child.try_wait() {
            Ok(Some(status)) => {
                if let Ok(mut guard) = self.exit.lock() {
                    *guard = Some(status.code().unwrap_or(-1));
                }
                self.done.store(true, Ordering::SeqCst);
                self.child = None;
                true
            }
            Ok(None) => false,
            Err(_) => {
                self.done.store(true, Ordering::SeqCst);
                self.child = None;
                true
            }
        }
    }

    pub fn stop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
        }
        self.done.store(true, Ordering::SeqCst);
        if let Ok(mut guard) = self.output.lock() {
            guard.push("— 任务已被用户停止 —".to_string());
        }
        self.child = None;
    }

    pub fn is_running(&self) -> bool {
        self.child.is_some()
    }

    /// 取最近若干行输出（用于渲染）。
    pub fn tail(&self, max: usize) -> Vec<String> {
        let guard = match self.output.lock() {
            Ok(g) => g,
            Err(e) => e.into_inner(),
        };
        let start = guard.len().saturating_sub(max);
        guard[start..].to_vec()
    }

    pub fn exit_code(&self) -> Option<i32> {
        self.exit.lock().ok().and_then(|g| *g)
    }
}

fn spawn_reader<R: std::io::Read + Send + 'static>(reader: R, output: Arc<Mutex<Vec<String>>>) {
    std::thread::spawn(move || {
        let reader = BufReader::new(reader);
        for line in reader.lines().map_while(Result::ok) {
            let mut guard = match output.lock() {
                Ok(g) => g,
                Err(e) => e.into_inner(),
            };
            guard.push(line);
            if guard.len() > 4000 {
                guard.drain(0..1000);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_tasks() {
        let text = r#"{
            "version": "2.0.0",
            "tasks": [
                {"label": "build", "type": "shell", "command": "cargo build", "group": "build"},
                {"label": "test", "command": "cargo", "args": ["test", "--", "--nocapture"]}
            ]
        }"#;
        let value = json::parse(text).unwrap();
        let tasks = parse_tasks(&value, Path::new("C:/demo"));
        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].label, "build");
        assert!(tasks[0].group);
        assert_eq!(tasks[1].command_line(), "cargo test -- --nocapture");
    }

    #[test]
    fn command_line_quotes_spaces() {
        let task = Task {
            label: "x".into(),
            command: "python".into(),
            args: vec!["a b.py".into(), "--flag".into()],
            cwd: None,
            group: false,
        };
        assert_eq!(task.command_line(), "python \"a b.py\" --flag");
    }
}

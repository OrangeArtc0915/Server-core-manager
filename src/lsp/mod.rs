//! LSP 客户端状态。
//!
//! 协议细节（JSON-RPC over stdio、Content-Length 分帧、diagnostics / completion /
//! definition）在 `client.rs` 中实现；本模块对外暴露编辑器需要的稳定接口。

pub mod client;
pub mod json;

use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Diagnostic {
    pub line: usize,
    pub col: usize,
    pub end_line: usize,
    pub end_col: usize,
    pub severity: u8,
    pub message: String,
}

pub struct LspState {
    pub status: String,
    clients: Vec<client::LspClient>,
    /// 语言 → 服务器命令（来自配置 `lsp.<语言>`）。
    commands: std::collections::HashMap<crate::core::language::Language, String>,
}

impl LspState {
    pub fn new() -> LspState {
        LspState {
            status: String::new(),
            clients: Vec::new(),
            commands: std::collections::HashMap::new(),
        }
    }

    pub fn configure(&mut self, map: &std::collections::HashMap<String, String>) {
        use crate::core::language::Language::*;
        let pairs = [
            ("rust", Rust),
            ("python", Python),
            ("javascript", JavaScript),
            ("typescript", TypeScript),
            ("go", Go),
            ("c", C),
            ("cpp", Cpp),
            ("csharp", CSharp),
            ("java", Java),
        ];
        self.commands.clear();
        for (key, language) in pairs {
            if let Some(command) = map.get(key) {
                if !command.trim().is_empty() {
                    self.commands.insert(language, command.clone());
                }
            }
        }
    }

    /// 把当前内容同步给语言服务器（首次 didOpen，之后 didChange）。
    pub fn sync(&mut self, path: &Path, text: &str) {
        if let Some(client) = self.client_for(path) {
            if let Err(e) = client.sync(path, text) {
                self.status = e;
            }
        }
    }

    pub fn shutdown(&mut self) {
        for client in &mut self.clients {
            client.shutdown();
        }
        self.clients.clear();
    }

    pub fn status(&self) -> &str {
        &self.status
    }

    pub fn diagnostics(&self, path: &Path) -> Vec<Diagnostic> {
        for client in &self.clients {
            if client.has_file(path) {
                return client.diagnostics(path);
            }
        }
        Vec::new()
    }

    pub fn definition(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
    ) -> Option<(PathBuf, usize)> {
        let client = self.client_for(path)?;
        match client.definition(path, line, col, text) {
            Ok(result) => result,
            Err(e) => {
                self.status = e;
                None
            }
        }
    }

    pub fn completion_items(
        &mut self,
        path: Option<&Path>,
        line: usize,
        col: usize,
        text: &str,
    ) -> Vec<(String, String, String)> {
        let Some(path) = path else {
            self.status = "文件尚未保存，无法请求补全".into();
            return Vec::new();
        };
        let Some(client) = self.client_for(path) else {
            return Vec::new();
        };
        match client.completion(path, line, col, text) {
            Ok(items) => items,
            Err(e) => {
                self.status = e;
                Vec::new()
            }
        }
    }

    /// 悬停提示。
    pub fn hover(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
    ) -> Option<String> {
        let client = self.client_for(path)?;
        match client.hover(path, line, col, text) {
            Ok(result) => result,
            Err(e) => {
                self.status = e;
                None
            }
        }
    }

    /// 引用列表。
    pub fn references(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
    ) -> Vec<(PathBuf, usize, usize)> {
        let Some(client) = self.client_for(path) else {
            return Vec::new();
        };
        match client.references(path, line, col, text, true) {
            Ok(list) => list,
            Err(e) => {
                self.status = e;
                Vec::new()
            }
        }
    }

    /// 工作区符号（Ctrl+T）。
    pub fn workspace_symbols(
        &mut self,
        path: &Path,
        query: &str,
    ) -> Vec<(PathBuf, usize, usize, String, String)> {
        let Some(client) = self.client_for(path) else {
            return Vec::new();
        };
        match client.workspace_symbols(query) {
            Ok(list) => list,
            Err(error) => {
                self.status = error;
                Vec::new()
            }
        }
    }

    pub fn rename(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
        new_name: &str,
    ) -> Result<Vec<client::LspEdit>, String> {
        let Some(client) = self.client_for(path) else {
            return Err(if self.status.is_empty() {
                "未配置语言服务器".into()
            } else {
                self.status.clone()
            });
        };
        client.rename(path, line, col, text, new_name)
    }

    pub fn formatting(
        &mut self,
        path: &Path,
        text: &str,
        tab_size: usize,
        use_spaces: bool,
    ) -> Result<Vec<client::LspEdit>, String> {
        let Some(client) = self.client_for(path) else {
            return Err(if self.status.is_empty() {
                "未配置语言服务器".into()
            } else {
                self.status.clone()
            });
        };
        client.formatting(path, text, tab_size, use_spaces)
    }

    /// 当前文件是否已有运行中的语言服务器（自动能力只在此时触发，避免输入时启动进程）。
    pub fn active_for(&self, path: &Path) -> bool {
        let language = crate::core::language::Language::from_path(path);
        self.clients.iter().any(|client| client.language == language)
    }

    /// 签名帮助。
    pub fn signature_help(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
    ) -> Option<client::SignatureHelp> {
        let client = self.client_for(path)?;
        match client.signature_help(path, line, col, text) {
            Ok(result) => result,
            Err(e) => {
                self.status = e;
                None
            }
        }
    }

    /// 快速修复 / 代码操作。
    pub fn code_actions(
        &mut self,
        path: &Path,
        line: usize,
        col: usize,
        text: &str,
        diagnostics: &[Diagnostic],
    ) -> Result<Vec<client::CodeAction>, String> {
        let Some(client) = self.client_for(path) else {
            return Err(if self.status.is_empty() {
                "未配置语言服务器".into()
            } else {
                self.status.clone()
            });
        };
        client.code_actions(path, line, col, text, diagnostics)
    }

    /// 内联提示。
    pub fn inlay_hints(&mut self, path: &Path, text: &str) -> Vec<client::InlayHint> {
        let Some(client) = self.client_for(path) else {
            return Vec::new();
        };
        match client.inlay_hints(path, text) {
            Ok(hints) => hints,
            Err(e) => {
                self.status = e;
                Vec::new()
            }
        }
    }

    /// 当前文件是否配置了可用的语言服务器（不启动进程）。
    pub fn can_serve(&self, path: &Path) -> bool {
        let language = crate::core::language::Language::from_path(path);
        if self.clients.iter().any(|client| client.language == language) {
            return true;
        }
        let default = default_command(language);
        let command = self
            .commands
            .get(&language)
            .map(|s| s.as_str())
            .unwrap_or(default);
        if command.is_empty() {
            return false;
        }
        let program = command.split_whitespace().next().unwrap_or("");
        program_exists(program)
    }

    fn client_for(&mut self, path: &Path) -> Option<&mut client::LspClient> {
        // 按扩展名映射语言；同一语言复用同一个服务器进程
        let language = crate::core::language::Language::from_path(path);
        if let Some(index) = self.clients.iter().position(|c| c.language == language) {
            return self.clients.get_mut(index);
        }
        let default = default_command(language);
        let command = self
            .commands
            .get(&language)
            .map(|s| s.as_str())
            .unwrap_or(default)
            .to_string();
        if command.is_empty() {
            self.status = "未配置语言服务器".into();
            return None;
        }
        let program = command.split_whitespace().next().unwrap_or("");
        if !program_exists(program) {
            self.status = format!("未找到语言服务器 {program}（可在配置 lsp.<语言> 指定）");
            return None;
        }
        let root = path.parent().unwrap_or(Path::new("."));
        match client::LspClient::start(&command, root, language) {
            Ok(client) => {
                self.clients.push(client);
                self.status = "LSP 已连接".into();
                self.clients.last_mut()
            }
            Err(e) => {
                self.status = format!("LSP 启动失败：{e}");
                None
            }
        }
    }
}

/// 默认语言服务器命令。
fn default_command(language: crate::core::language::Language) -> &'static str {
    use crate::core::language::Language::*;
    match language {
        Rust => "rust-analyzer",
        Python => "pylsp",
        JavaScript | TypeScript => "typescript-language-server --stdio",
        Go => "gopls",
        C | Cpp => "clangd",
        _ => "",
    }
}

/// 在 PATH 中查找可执行文件（带 .exe 后缀）。
fn program_exists(program: &str) -> bool {
    if program.contains('\\') || program.contains('/') {
        return Path::new(program).is_file();
    }
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path) {
        if dir.join(program).is_file() || dir.join(format!("{program}.exe")).is_file() {
            return true;
        }
    }
    false
}

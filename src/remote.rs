//! 远程开发：UNC/SMB 工作区与 SSH 远端命令 / 文件。
//!
//! SSH 主机在 `config.ini` 中声明：
//!   remote.dev = user@192.0.2.10:22
//!   remote.dev.root = /home/user/project
//! 其余工作交给系统自带的 ssh.exe / scp.exe（Windows 10 及以上默认提供）。

use crate::task::Task;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteHost {
    pub name: String,
    pub user: Option<String>,
    pub host: String,
    pub port: u16,
    /// 远端默认工作目录（可为空）。
    pub root: String,
}

impl RemoteHost {
    pub fn parse(name: &str, spec: &str, root: &str) -> Option<RemoteHost> {
        let spec = spec.trim();
        if spec.is_empty() {
            return None;
        }
        let (user, host_port) = match spec.rsplit_once('@') {
            Some((user, rest)) if !user.is_empty() => (Some(user.to_string()), rest),
            _ => (None, spec),
        };
        let (host, port) = match host_port.rsplit_once(':') {
            Some((host, port)) if port.parse::<u16>().is_ok() => {
                (host.to_string(), port.parse().unwrap_or(22))
            }
            _ => (host_port.to_string(), 22),
        };
        if host.is_empty() {
            return None;
        }
        Some(RemoteHost {
            name: name.trim().to_string(),
            user,
            host,
            port: if port == 0 { 22 } else { port },
            root: root.trim().to_string(),
        })
    }

    pub fn target(&self) -> String {
        match &self.user {
            Some(user) => format!("{user}@{}", self.host),
            None => self.host.clone(),
        }
    }

    pub fn ssh_args(&self) -> Vec<String> {
        let mut args = vec![
            "-o".to_string(),
            "BatchMode=yes".to_string(),
            "-o".to_string(),
            "ConnectTimeout=10".to_string(),
        ];
        if self.port != 22 {
            args.push("-p".to_string());
            args.push(self.port.to_string());
        }
        args
    }

    /// 构造在远端执行的 SSH 任务（复用任务输出面板）。
    pub fn command_task(&self, command: &str) -> Task {
        let mut args = self.ssh_args();
        args.push(self.target());
        let mut line = String::new();
        if !self.root.is_empty() {
            line.push_str("cd ");
            line.push_str(&shell_quote(&self.root));
            line.push_str(" && ");
        }
        line.push_str(command);
        args.push(line);
        Task {
            label: format!("远程 {}：{}", self.name, command),
            command: "ssh".into(),
            args,
            cwd: None,
            group: false,
        }
    }

    fn scp_base(&self) -> Vec<String> {
        let mut args = vec![
            "-q".to_string(),
            "-o".to_string(),
            "BatchMode=yes".to_string(),
            "-o".to_string(),
            "ConnectTimeout=10".to_string(),
        ];
        if self.port != 22 {
            args.push("-P".to_string());
            args.push(self.port.to_string());
        }
        args
    }

    pub fn download(&self, remote: &str, local: &Path) -> Result<(), String> {
        if let Some(parent) = local.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("无法创建缓存目录：{e}"))?;
        }
        let mut command = std::process::Command::new("scp");
        command.args(self.scp_base());
        command.arg(format!("{}:{}", self.target(), shell_quote(remote)));
        command.arg(local);
        run(command, "scp 下载")
    }

    pub fn upload(&self, local: &Path, remote: &str) -> Result<(), String> {
        let mut command = std::process::Command::new("scp");
        command.args(self.scp_base());
        command.arg(local);
        command.arg(format!("{}:{}", self.target(), shell_quote(remote)));
        run(command, "scp 上传")
    }
}

fn run(mut command: std::process::Command, what: &str) -> Result<(), String> {
    let output = command
        .output()
        .map_err(|e| format!("{what} 失败（需要系统安装 ssh/scp）：{e}"))?;
    if output.status.success() {
        return Ok(());
    }
    let text = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(if text.is_empty() {
        format!("{what} 失败（退出码 {:?}）", output.status.code())
    } else {
        format!("{what} 失败：{text}")
    })
}

fn shell_quote(text: &str) -> String {
    if text
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "/._-~".contains(c))
    {
        return text.to_string();
    }
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// 合并配置中的主机与远端根目录。
pub fn load(remotes: &[(String, String)], roots: &[(String, String)]) -> Vec<RemoteHost> {
    let mut root_map: HashMap<&str, &str> = HashMap::new();
    for (name, root) in roots {
        root_map.insert(name.as_str(), root.as_str());
    }
    let mut out = Vec::new();
    for (name, spec) in remotes {
        let root = root_map
            .get(name.to_ascii_lowercase().as_str())
            .copied()
            .unwrap_or("");
        if let Some(host) = RemoteHost::parse(name, spec, root) {
            out.push(host);
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// 远端文件在本地缓存中的路径。
pub fn cache_path(cache_root: &Path, host: &str, remote: &str) -> PathBuf {
    let mut path = cache_root.join(sanitize(host));
    let trimmed = remote.trim_start_matches(['/', '\\']);
    for part in trimmed.split(['/', '\\']) {
        if part.is_empty() || part == "." || part == ".." {
            continue;
        }
        path.push(sanitize(part));
    }
    path
}

fn sanitize(text: &str) -> String {
    let cleaned: String = text
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || "._-@".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "_".to_string()
    } else {
        cleaned
    }
}

/// 远程连接状态（面板 / 活动主机 / 本地缓存映射）。
pub struct RemoteState {
    pub hosts: Vec<RemoteHost>,
    pub active: Option<String>,
    /// 本地缓存文件 → (主机名, 远端路径)，保存时自动回传。
    pub mappings: HashMap<PathBuf, (String, String)>,
    pub cache_root: PathBuf,
}

impl RemoteState {
    pub fn new(cache_root: PathBuf) -> RemoteState {
        RemoteState {
            hosts: Vec::new(),
            active: None,
            mappings: HashMap::new(),
            cache_root,
        }
    }

    pub fn reload(&mut self, remotes: &[(String, String)], roots: &[(String, String)]) {
        self.hosts = load(remotes, roots);
        if !self
            .hosts
            .iter()
            .any(|h| Some(&h.name) == self.active.as_ref())
        {
            self.active = self.hosts.first().map(|h| h.name.clone());
        }
    }

    pub fn host(&self, name: &str) -> Option<&RemoteHost> {
        self.hosts.iter().find(|h| h.name == name)
    }

    pub fn active_host(&self) -> Option<&RemoteHost> {
        let name = self.active.as_ref()?;
        self.host(name)
    }

    pub fn mapping_for(&self, local: &Path) -> Option<(String, String)> {
        self.mappings.get(local).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_host_specs() {
        let host = RemoteHost::parse("dev", "mmm@172.29.220.171:2222", "/srv/app").unwrap();
        assert_eq!(host.user.as_deref(), Some("mmm"));
        assert_eq!(host.host, "172.29.220.171");
        assert_eq!(host.port, 2222);
        assert_eq!(host.root, "/srv/app");
        assert_eq!(host.target(), "mmm@172.29.220.171");

        let plain = RemoteHost::parse("box", "server", "").unwrap();
        assert_eq!(plain.port, 22);
        assert!(plain.user.is_none());
    }

    #[test]
    fn ssh_task_quotes_root() {
        let host = RemoteHost::parse("dev", "u@h", "/srv/my app").unwrap();
        let task = host.command_task("ls -l");
        assert_eq!(task.command, "ssh");
        let last = task.args.last().unwrap();
        assert!(last.starts_with("cd '/srv/my app' && "));
        assert_eq!(last, "cd '/srv/my app' && ls -l");
    }

    #[test]
    fn cache_paths_are_nested() {
        let root = Path::new("C:/cache");
        let path = cache_path(root, "dev", "/home/u/a.py");
        assert_eq!(path, Path::new("C:/cache/dev/home/u/a.py"));
    }

    #[test]
    fn load_merges_roots() {
        let hosts = load(
            &[("dev".into(), "u@h".into())],
            &[("dev".into(), "/srv".into())],
        );
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].root, "/srv");
    }
}

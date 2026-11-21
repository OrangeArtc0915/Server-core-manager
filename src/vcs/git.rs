//! Git 集成：调用系统 `git.exe`（零依赖，不链接 libgit2）。
//!
//! 提供仓库发现、分支、状态、HEAD 版本内容、diff、log 与提交。

use std::path::{Path, PathBuf};
use std::process::Command;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Clone, Debug)]
pub struct Change {
    pub path: String,
    /// porcelain 状态码，例如 ` M`、`??`、`A `。
    pub status: String,
    pub staged: bool,
}

pub fn run(root: &Path, args: &[&str]) -> Result<String, String> {
    let mut command = Command::new("git");
    // 禁止交互式凭据提示与分页器，避免界面卡死。
    command
        .args(args)
        .current_dir(root)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat");
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let output = command.output().map_err(|e| format!("无法运行 git：{e}"))?;
    if !output.status.success() {
        let text = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if text.is_empty() {
            "git 命令失败".into()
        } else {
            text
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

pub fn is_available() -> bool {
    Command::new("git")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// 从任意目录向上找仓库根。
pub fn root_of(start: &Path) -> Option<PathBuf> {
    let text = run(start, &["rev-parse", "--show-toplevel"]).ok()?;
    let path = PathBuf::from(text.trim());
    if path.is_dir() {
        Some(path)
    } else {
        None
    }
}

pub fn branch(root: &Path) -> String {
    run(root, &["rev-parse", "--abbrev-ref", "HEAD"])
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown".into())
}

pub fn status(root: &Path) -> Vec<Change> {
    let Ok(text) = run(root, &["status", "--porcelain"]) else {
        return Vec::new();
    };
    text.lines()
        .filter(|line| line.len() > 3)
        .map(|line| {
            let status = line[..2].to_string();
            let mut path = line[3..].trim().to_string();
            // 重命名：`R  old -> new`
            if let Some((_, new)) = path.split_once(" -> ") {
                path = new.trim_matches('"').to_string();
            } else if path.starts_with('"') && path.ends_with('"') && path.len() >= 2 {
                path = path[1..path.len() - 1]
                    .replace("\\\"", "\"")
                    .replace("\\\\", "\\");
            }
            let staged = !status.starts_with(' ') && status != "??";
            Change {
                path,
                status,
                staged,
            }
        })
        .collect()
}

/// 暂存指定文件。
pub fn stage(root: &Path, paths: &[String]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    let mut args = vec!["add", "--"];
    args.extend(paths.iter().map(|path| path.as_str()));
    run(root, &args).map(|_| ())
}

/// 取消暂存指定文件。
pub fn unstage(root: &Path, paths: &[String]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    let mut args = vec!["reset", "-q", "HEAD", "--"];
    args.extend(paths.iter().map(|path| path.as_str()));
    run(root, &args).map(|_| ())
}

pub fn stage_all(root: &Path) -> Result<(), String> {
    run(root, &["add", "-A"]).map(|_| ())
}

pub fn unstage_all(root: &Path) -> Result<(), String> {
    run(root, &["reset", "-q", "HEAD"]).map(|_| ())
}

/// 丢弃工作区改动（仅已跟踪文件）。
pub fn discard(root: &Path, paths: &[String]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    let mut args = vec!["checkout", "--"];
    args.extend(paths.iter().map(|path| path.as_str()));
    run(root, &args).map(|_| ())
}

/// 拉取（仅快进，失败时汇报而不是卡在凭据输入）。
pub fn pull(root: &Path) -> Result<String, String> {
    run(root, &["pull", "--ff-only"])
}

/// 推送当前分支。
pub fn push(root: &Path) -> Result<String, String> {
    run(root, &["push"])
}

/// 拉取所有远程引用。
pub fn fetch(root: &Path) -> Result<String, String> {
    run(root, &["fetch", "--all", "--prune"])
}

/// 暂存工作区改动（含未跟踪文件）。
pub fn stash_push(root: &Path) -> Result<String, String> {
    run(root, &["stash", "push", "-u"])
}

/// 恢复最近一次 stash。
pub fn stash_pop(root: &Path) -> Result<String, String> {
    run(root, &["stash", "pop"])
}

/// 创建并切换到新分支。
pub fn create_branch(root: &Path, name: &str) -> Result<String, String> {
    run(root, &["switch", "-c", name])
}

/// 删除分支（未合并时会失败并返回 git 的提示）。
pub fn delete_branch(root: &Path, name: &str) -> Result<String, String> {
    run(root, &["branch", "-d", name])
}

/// 合并指定分支到当前分支。
pub fn merge(root: &Path, branch: &str) -> Result<String, String> {
    run(root, &["merge", "--no-edit", branch])
}

/// 分支列表：(名称, 是否当前分支)。
pub fn branches(root: &Path) -> Vec<(String, bool)> {
    let Ok(text) = run(root, &["branch", "--no-color"]) else {
        return Vec::new();
    };
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let current = line.starts_with('*');
            (line.trim_start_matches('*').trim().to_string(), current)
        })
        .collect()
}

pub fn checkout(root: &Path, branch: &str) -> Result<String, String> {
    if branch.trim().is_empty() {
        return Err("分支名不能为空".into());
    }
    run(root, &["checkout", branch])
}

/// 文件逐行 blame。
pub fn blame(root: &Path, file: &Path) -> String {
    let relative = file
        .strip_prefix(root)
        .ok()
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|| file.to_string_lossy().replace('\\', "/"));
    run(
        root,
        &["blame", "--date=short", "--", &relative],
    )
    .unwrap_or_else(|e| e)
}

/// 指定提交的 diff。
pub fn show_commit(root: &Path, hash: &str) -> String {
    run(root, &["show", "--stat", "--patch", hash]).unwrap_or_else(|e| e)
}


/// 读取某文件在 HEAD 中的内容（按行）。新文件返回 `None`。
pub fn head_lines(root: &Path, file: &Path) -> Option<Vec<String>> {
    let relative = file
        .strip_prefix(root)
        .ok()
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|| file.to_string_lossy().replace('\\', "/"));
    let text = run(root, &["show", &format!("HEAD:{relative}")]).ok()?;
    let text = text.trim_end_matches('\n').to_string();
    Some(text.split('\n').map(|s| s.to_string()).collect())
}

pub fn file_diff(root: &Path, file: &Path) -> String {
    let relative = file
        .strip_prefix(root)
        .ok()
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|| file.to_string_lossy().replace('\\', "/"));
    run(root, &["diff", "--", &relative]).unwrap_or_else(|e| e)
}

pub fn file_diff_cached(root: &Path, file: &Path) -> String {
    let relative = file
        .strip_prefix(root)
        .ok()
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|| file.to_string_lossy().replace('\\', "/"));
    run(root, &["diff", "--cached", "--", &relative]).unwrap_or_else(|e| e)
}

pub fn log(root: &Path, limit: usize) -> Vec<String> {
    run(
        root,
        &["log", "--oneline", "--decorate", "-n", &limit.to_string()],
    )
    .map(|text| text.lines().map(|s| s.to_string()).collect())
    .unwrap_or_default()
}

pub fn commit_all(root: &Path, message: &str) -> Result<String, String> {
    run(root, &["add", "-A"])?;
    let text = run(root, &["commit", "-m", message])?;
    Ok(text.lines().next().unwrap_or("提交完成").to_string())
}

#[derive(Clone, Default)]
pub struct GitState {
    pub root: Option<PathBuf>,
    pub branch: String,
    pub changes: Vec<Change>,
    pub available: bool,
    pub message: String,
}

impl GitState {
    pub fn refresh(&mut self, cwd: &Path) {
        self.available = is_available();
        if !self.available {
            self.root = None;
            self.branch.clear();
            self.changes.clear();
            return;
        }
        self.root = root_of(cwd);
        if let Some(root) = self.root.clone() {
            self.branch = branch(&root);
            self.changes = status(&root);
        } else {
            self.branch.clear();
            self.changes.clear();
        }
    }

    pub fn summary(&self) -> String {
        if !self.available {
            return "Git 不可用".into();
        }
        match &self.root {
            None => "不在 Git 仓库".into(),
            Some(_) => format!("{}  {} 个变更", self.branch, self.changes.len()),
        }
    }
}

//! Git 源码管理面板：暂存 / 提交 / 差异 / 丢弃 / 分支 / Blame。

use std::path::PathBuf;

use crate::core::language::Language;
use crate::platform::console::{Key, KeyCode};
use crate::ui::app::{
    App, ConfirmAction, ConfirmState, Focus, ListItem, ListKind, ListState, Overlay, SidebarMode,
};
use crate::vcs::git;

impl App {
    /// 打开 Git 面板并聚焦。
    pub fn git_panel_focus(&mut self) {
        self.sidebar.mode = SidebarMode::Git;
        self.config.sidebar = true;
        self.focus = Focus::Sidebar;
        self.git.refresh(&self.cwd);
        self.clamp_git_selection();
        self.resize(self.layout.cols, self.layout.rows);
    }

    pub(crate) fn clamp_git_selection(&mut self) {
        self.git_selected = self
            .git_selected
            .min(self.git.changes.len().saturating_sub(1));
    }

    fn git_change(&self) -> Option<git::Change> {
        self.git.changes.get(self.git_selected).cloned()
    }

    fn git_absolute(&self, change: &git::Change) -> Option<PathBuf> {
        self.git
            .root
            .as_ref()
            .map(|root| root.join(change.path.replace('/', std::path::MAIN_SEPARATOR_STR)))
    }

    /// 空格：暂存 / 取消暂存选中文件。
    pub fn git_toggle_stage(&mut self) {
        let Some(change) = self.git_change() else {
            self.set_error("没有可暂存的变更");
            return;
        };
        self.git_set_stage(!change.staged);
    }

    /// 明确设置暂存状态。
    pub fn git_set_stage(&mut self, stage: bool) {
        let Some(root) = self.git.root.clone() else {
            self.set_error("不在 Git 仓库中");
            return;
        };
        let Some(change) = self.git_change() else {
            self.set_error("没有可暂存的变更");
            return;
        };
        if change.staged == stage {
            self.set_status(if stage { "文件已暂存" } else { "文件未暂存" });
            return;
        }
        let paths = vec![change.path.clone()];
        let result = if stage {
            git::stage(&root, &paths)
        } else {
            git::unstage(&root, &paths)
        };
        self.git.refresh(&self.cwd);
        self.clamp_git_selection();
        match result {
            Ok(()) => self.set_status(format!(
                "{} {}",
                if stage { "已暂存" } else { "已取消暂存" },
                change.path
            )),
            Err(error) => self.set_error(error),
        }
    }

    pub fn git_stage_all(&mut self, stage: bool) {
        let Some(root) = self.git.root.clone() else {
            self.set_error("不在 Git 仓库中");
            return;
        };
        let result = if stage {
            git::stage_all(&root)
        } else {
            git::unstage_all(&root)
        };
        self.git.refresh(&self.cwd);
        self.clamp_git_selection();
        match result {
            Ok(()) => self.set_status(if stage {
                "已暂存全部变更"
            } else {
                "已取消全部暂存"
            }),
            Err(error) => self.set_error(error),
        }
    }

    /// 显示选中文件的差异。
    pub fn git_diff_selected(&mut self) {
        let Some(root) = self.git.root.clone() else {
            self.set_error("不在 Git 仓库中");
            return;
        };
        let Some(change) = self.git_change() else {
            self.set_error("没有可显示差异的变更");
            return;
        };
        let Some(path) = self.git_absolute(&change) else {
            return;
        };
        let mut diff = git::file_diff(&root, &path);
        if diff.trim().is_empty() {
            diff = git::file_diff_cached(&root, &path);
        }
        if diff.trim().is_empty() {
            diff = format!("{}：没有可显示的差异", change.path);
        }
        self.open_preview(&diff, &format!("Git 差异 {}", change.path), Language::Diff);
    }

    /// 丢弃选中文件的未暂存改动。
    pub fn git_discard_selected(&mut self) {
        let Some(change) = self.git_change() else {
            self.set_error("没有可丢弃的变更");
            return;
        };
        if change.staged {
            self.set_error("该文件已暂存，请先取消暂存再丢弃");
            return;
        }
        if change.status.starts_with("??") {
            self.set_error("未跟踪文件不会通过 Git 丢弃，请直接在资源管理器中删除");
            return;
        }
        let Some(path) = self.git_absolute(&change) else {
            return;
        };
        self.overlay = Overlay::Confirm(ConfirmState {
            title: "丢弃改动".into(),
            message: format!("确定丢弃「{}」的未暂存改动？此操作不可撤销。", change.path),
            selected: 1,
            action: ConfirmAction::GitDiscard(path),
        });
    }

    /// 分支选择器。
    pub fn git_branch_picker(&mut self) {
        let Some(root) = self.git.root.clone() else {
            self.set_error("不在 Git 仓库中");
            return;
        };
        let branches = git::branches(&root);
        if branches.is_empty() {
            self.set_error("没有可用分支");
            return;
        }
        let items = branches
            .iter()
            .map(|(name, current)| ListItem {
                title: name.clone(),
                detail: if *current { "当前分支".into() } else { String::new() },
                command: None,
                path: None,
                line: None,
                value: Some(name.clone()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::GitBranches, "切换分支", items));
    }

    pub fn git_checkout(&mut self, branch: &str) {
        let Some(root) = self.git.root.clone() else {
            self.set_error("不在 Git 仓库中");
            return;
        };
        match git::checkout(&root, branch) {
            Ok(text) => {
                self.git.refresh(&self.cwd);
                self.set_status(format!(
                    "已切换到分支 {branch}{}",
                    if text.trim().is_empty() {
                        String::new()
                    } else {
                        format!("（{}）", text.trim())
                    }
                ));
            }
            Err(error) => self.set_error(error),
        }
    }

    /// 当前文件逐行 Blame。
    pub fn git_blame_current(&mut self) {
        let Some(root) = self.git.root.clone() else {
            self.set_error("不在 Git 仓库中");
            return;
        };
        let Some(path) = self.doc().path.clone() else {
            self.set_error("当前文件尚未保存");
            return;
        };
        let text = git::blame(&root, &path);
        if text.trim().is_empty() {
            self.set_error("没有可显示的 Blame（文件可能未提交）");
            return;
        }
        let name = path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_else(|| path.display().to_string());
        self.open_preview(&text, &format!("Git Blame {name}"), Language::Plain);
    }

    /// Git 面板按键。
    pub fn git_panel_key(&mut self, key: Key) -> bool {
        use KeyCode::*;
        match key.code {
            Up => {
                if self.git_selected > 0 {
                    self.git_selected -= 1;
                }
                true
            }
            Down => {
                if self.git_selected + 1 < self.git.changes.len() {
                    self.git_selected += 1;
                }
                true
            }
            PageUp => {
                self.git_selected = self.git_selected.saturating_sub(10);
                true
            }
            PageDown => {
                self.git_selected =
                    (self.git_selected + 10).min(self.git.changes.len().saturating_sub(1));
                true
            }
            Home => {
                self.git_selected = 0;
                true
            }
            End => {
                self.git_selected = self.git.changes.len().saturating_sub(1);
                true
            }
            Esc => {
                self.focus = Focus::Editor;
                true
            }
            Enter => {
                self.git_diff_selected();
                true
            }
            Char(' ') => {
                self.git_toggle_stage();
                true
            }
            Char('a') if !key.mods.ctrl => {
                self.git_stage_all(true);
                true
            }
            Char('u') if !key.mods.ctrl => {
                self.git_stage_all(false);
                true
            }
            Char('c') if !key.mods.ctrl => {
                self.git_commit_prompt();
                true
            }
            Char('d') if !key.mods.ctrl => {
                self.git_discard_selected();
                true
            }
            Char('l') if !key.mods.ctrl => {
                self.git_show_log();
                true
            }
            Char('b') if !key.mods.ctrl => {
                self.git_branch_picker();
                true
            }
            Char('r') if !key.mods.ctrl => {
                self.git.refresh(&self.cwd);
                self.clamp_git_selection();
                self.set_status(self.git.summary());
                true
            }
            _ => false,
        }
    }
}

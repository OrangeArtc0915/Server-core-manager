//! 会话快照：正常退出时保存标签页/窗格布局，下次启动恢复。
//!
//! 只保存树形与 profile，不保存窗格输出或子进程状态；文件格式是配置解析器
//! 支持的 TOML 子集，便于人工查看与排错。

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::config::{toml, Config};
use crate::platform::logging;
use crate::ui::app::App;
use crate::ui::layout::node_to_spec;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionTab {
    pub title: String,
    pub custom_title: bool,
    /// 聚焦窗格在该标签页叶子顺序中的下标。
    pub focus: usize,
    /// 布局表达式（profile 名 + 分割比例）。
    pub layout: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Session {
    pub active: usize,
    pub tabs: Vec<SessionTab>,
}

impl Session {
    /// 从当前 App 抓取快照。
    pub fn capture(app: &App) -> Session {
        let mut profiles = HashMap::new();
        for (id, pane) in &app.panes {
            profiles.insert(*id, pane.profile.clone());
        }
        let tabs = app
            .tabs
            .iter()
            .map(|tab| {
                let leaves = tab.tree.leaves();
                let focus = leaves
                    .iter()
                    .position(|id| *id == tab.focus)
                    .unwrap_or(0);
                SessionTab {
                    title: tab.title.clone(),
                    custom_title: tab.custom_title,
                    focus,
                    layout: node_to_spec(&tab.tree, &profiles),
                }
            })
            .collect();
        Session {
            active: app.active,
            tabs,
        }
    }

    pub fn to_toml(&self) -> String {
        let mut out = String::from("# scterm 会话快照（自动生成，可删除）\n");
        out.push_str(&format!("active = {}\n", self.active));
        for tab in &self.tabs {
            out.push_str("\n[[tabs]]\n");
            out.push_str(&format!("title = {}\n", toml_string(&tab.title)));
            out.push_str(&format!("custom_title = {}\n", tab.custom_title));
            out.push_str(&format!("focus = {}\n", tab.focus));
            out.push_str(&format!("layout = {}\n", toml_string(&tab.layout)));
        }
        out
    }

    pub fn parse(text: &str) -> Result<Session, String> {
        let doc = toml::parse(text)?;
        let active = doc
            .root
            .get_int("active")
            .unwrap_or(0)
            .max(0) as usize;
        let mut tabs = Vec::new();
        for table in doc.array("tabs") {
            let layout = table.get_str("layout").unwrap_or("").trim().to_string();
            if layout.is_empty() {
                continue;
            }
            tabs.push(SessionTab {
                title: table.get_str("title").unwrap_or("").to_string(),
                custom_title: table.get_bool("custom_title").unwrap_or(false),
                focus: table.get_int("focus").unwrap_or(0).max(0) as usize,
                layout,
            });
        }
        Ok(Session { active, tabs })
    }

    /// 先写临时文件再替换，避免退出途中留下半截会话文件。
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(dir) = path.parent() {
            if !dir.as_os_str().is_empty() {
                fs::create_dir_all(dir)
                    .map_err(|e| format!("创建会话目录 {} 失败：{e}", dir.display()))?;
            }
        }
        let tmp = path.with_extension("tmp");
        fs::write(&tmp, self.to_toml())
            .map_err(|e| format!("写入会话文件 {} 失败：{e}", tmp.display()))?;
        fs::rename(&tmp, path).map_err(|e| {
            format!(
                "替换会话文件 {} 失败：{e}",
                path.display()
            )
        })
    }
}

pub fn path() -> PathBuf {
    Config::session_path()
}

/// 读取会话；文件不存在/损坏时返回 None，不阻断启动。
pub fn load() -> Option<Session> {
    let path = path();
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(e) => {
            logging::warn(&format!("读取会话文件 {} 失败：{e}", path.display()));
            return None;
        }
    };
    match Session::parse(&text) {
        Ok(session) if !session.tabs.is_empty() => Some(session),
        Ok(_) => None,
        Err(e) => {
            logging::warn(&format!("会话文件 {} 无法解析：{e}", path.display()));
            None
        }
    }
}

fn toml_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            other if other.is_control() => out.push(' '),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::layout::LayoutNode;
    use std::sync::mpsc;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_path(name: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "scterm-session-{}-{nanos}-{name}.toml",
            std::process::id()
        ))
    }

    fn capture_layout(layout: &str) -> (App, mpsc::Receiver<Vec<u8>>) {
        let (tx, rx) = mpsc::channel();
        let mut app = App::new_empty(Config::default(), 80, 24, tx);
        let node = LayoutNode::parse(layout).unwrap();
        app.new_tab_with_layout(&node);
        (app, rx)
    }

    #[test]
    fn roundtrip_preserves_tabs_and_layout() {
        let (mut app, _rx) = capture_layout("h30(powershell,v70(cmd,scterm))");
        // 第二个标签页带自定义标题。
        let node = LayoutNode::parse("v(powershell,cmd)").unwrap();
        app.new_tab_with_layout(&node);
        app.tabs[1].title = "my \"tab\"".to_string();
        app.tabs[1].custom_title = true;
        app.tabs[1].focus = app.tabs[1].tree.leaves()[1];
        app.active = 1;

        let session = Session::capture(&app);
        assert_eq!(session.active, 1);
        assert_eq!(session.tabs.len(), 2);
        assert_eq!(session.tabs[0].layout, "h30(powershell,v70(cmd,scterm))");
        assert_eq!(session.tabs[0].focus, 0);
        assert_eq!(session.tabs[1].layout, "v(powershell,cmd)");
        assert_eq!(session.tabs[1].focus, 1);
        assert!(session.tabs[1].custom_title);

        let text = session.to_toml();
        assert!(text.contains("custom_title = true"));
        let parsed = Session::parse(&text).unwrap();
        assert_eq!(parsed, session);

        let path = temp_path("roundtrip");
        session.save(&path).unwrap();
        let loaded = fs::read_to_string(&path).unwrap();
        assert_eq!(Session::parse(&loaded).unwrap(), session);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn title_escapes_quotes_and_newlines() {
        let session = Session {
            active: 0,
            tabs: vec![SessionTab {
                title: "a\"b\\c\nd\te".to_string(),
                custom_title: true,
                focus: 0,
                layout: "powershell".to_string(),
            }],
        };
        let parsed = Session::parse(&session.to_toml()).unwrap();
        assert_eq!(parsed.tabs[0].title, "a\"b\\c\nd\te");
    }

    #[test]
    fn bad_session_is_ignored() {
        assert!(Session::parse("not toml = [").is_err());
        let session = Session::parse("active = 0\n").unwrap();
        assert!(session.tabs.is_empty());
        assert_eq!(session.active, 0);
    }

    #[test]
    fn restore_rebuilds_tabs_and_focus() {
        let (tx, _rx) = mpsc::channel();
        let mut app = App::new_empty(Config::default(), 80, 24, tx);
        let session = Session {
            active: 1,
            tabs: vec![
                SessionTab {
                    title: "powershell".to_string(),
                    custom_title: false,
                    focus: 1,
                    layout: "h(powershell,cmd)".to_string(),
                },
                SessionTab {
                    title: "工作区".to_string(),
                    custom_title: true,
                    focus: 2,
                    layout: "v30(powershell,v70(cmd,scterm))".to_string(),
                },
            ],
        };
        assert_eq!(app.restore_session(&session), 2);
        assert_eq!(app.tabs.len(), 2);
        assert_eq!(app.active, 1);
        assert_eq!(app.tabs[0].tree.leaves().len(), 2);
        assert_eq!(app.tabs[1].tree.leaves().len(), 3);
        assert_eq!(app.tabs[0].focus, app.tabs[0].tree.leaves()[1]);
        assert_eq!(app.tabs[1].focus, app.tabs[1].tree.leaves()[2]);
        assert_eq!(app.tabs[1].title, "工作区");
        assert!(app.tabs[1].custom_title);
        assert!(app.status.as_ref().unwrap().0.contains("已恢复 2"));
    }

    #[test]
    fn restore_skips_bad_layout_and_unknown_profile() {
        let (tx, _rx) = mpsc::channel();
        let mut app = App::new_empty(Config::default(), 80, 24, tx);
        let session = Session {
            active: 5,
            tabs: vec![
                SessionTab {
                    title: "坏".to_string(),
                    custom_title: false,
                    focus: 0,
                    layout: "h(pwsh".to_string(),
                },
                SessionTab {
                    title: "未知 profile".to_string(),
                    custom_title: false,
                    focus: 0,
                    layout: "no-such-profile".to_string(),
                },
            ],
        };
        assert_eq!(app.restore_session(&session), 1);
        assert_eq!(app.active, 0, "越界的活动标签应回落到 0");
        assert_eq!(app.panes.len(), 1);
        assert_eq!(
            app.panes.values().next().unwrap().profile,
            Config::default().default_profile
        );
    }
}

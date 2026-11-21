//! 会话恢复：退出时记录打开的文件、光标位置与活动标签，启动时还原。

use std::path::PathBuf;

use crate::platform::log;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionFile {
    pub path: PathBuf,
    pub line: usize,
    pub col: usize,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Session {
    pub files: Vec<SessionFile>,
    pub active: usize,
}

fn session_path() -> PathBuf {
    log::config_path().with_file_name("session.ini")
}

impl Session {
    /// 读取会话；文件不存在或没有可用条目时返回 None。
    pub fn load() -> Option<Session> {
        let text = std::fs::read_to_string(session_path()).ok()?;
        let session = parse(&text);
        if session.files.is_empty() {
            None
        } else {
            Some(session)
        }
    }

    pub fn save(&self) {
        let path = session_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(error) = std::fs::write(&path, render(self)) {
            log::warn(&format!("写会话失败 {}：{error}", path.display()));
        }
    }
}

/// 解析 `key = value` 文本；`fileN` 的值格式为「行号\t列号\t路径」。
fn parse(text: &str) -> Session {
    let mut session = Session::default();
    let mut files: Vec<(usize, SessionFile)> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with(';') || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim();
        if key == "active" {
            session.active = value.parse().unwrap_or(0);
        } else if let Some(index) = key.strip_prefix("file") {
            let Ok(index) = index.parse::<usize>() else {
                continue;
            };
            let mut parts = value.splitn(3, '\t');
            let line_no = parts
                .next()
                .and_then(|part| part.parse::<usize>().ok())
                .unwrap_or(0);
            let col = parts
                .next()
                .and_then(|part| part.parse::<usize>().ok())
                .unwrap_or(0);
            if let Some(path) = parts.next().filter(|path| !path.is_empty()) {
                files.push((
                    index,
                    SessionFile {
                        path: PathBuf::from(path),
                        line: line_no,
                        col,
                    },
                ));
            }
        }
    }
    files.sort_by_key(|(index, _)| *index);
    session.files = files.into_iter().map(|(_, file)| file).collect();
    session
}

fn render(session: &Session) -> String {
    let mut out = String::new();
    out.push_str("; Textm 会话：退出时自动写入（restore_session = false 可关闭恢复）\n");
    out.push_str(&format!("active = {}\n", session.active));
    for (index, file) in session.files.iter().enumerate() {
        out.push_str(&format!(
            "file{index} = {}\t{}\t{}\n",
            file.line,
            file.col,
            file.path.display()
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_roundtrip() {
        let session = Session {
            files: vec![
                SessionFile {
                    path: PathBuf::from("C:/proj/a.rs"),
                    line: 12,
                    col: 4,
                },
                SessionFile {
                    path: PathBuf::from("C:/proj/使用说明.txt"),
                    line: 0,
                    col: 0,
                },
            ],
            active: 1,
        };
        assert_eq!(parse(&render(&session)), session);
    }

    #[test]
    fn session_sorts_files_and_ignores_bad_lines() {
        let text = "active = 5\nfile2 = 1\t2\tC:/c.txt\nbad line\nfile0 = 3\t4\tC:/a.txt\n";
        let session = parse(text);
        assert_eq!(session.files.len(), 2);
        assert_eq!(session.files[0].path, PathBuf::from("C:/a.txt"));
        assert_eq!(session.files[1].path, PathBuf::from("C:/c.txt"));
        assert_eq!(session.active, 5);
    }
}

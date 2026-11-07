//! Tab 补全：命令名（内置命令 + 别名 + PATH 可执行文件）与文件路径。

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use super::builtins;

pub struct Completion {
    pub line: String,
    pub cursor: usize,
    /// 候选显示名；只有多于 1 个候选时才返回（用于打印列表）。
    pub candidates: Vec<String>,
}

struct Candidate {
    /// 替换当前词用的完整文本。
    insert: String,
    /// 候选列表里的显示文本。
    display: String,
}

pub fn complete(line: &str, cursor: usize, aliases: &BTreeMap<String, String>) -> Completion {
    let chars: Vec<char> = line.chars().collect();
    if cursor > chars.len() {
        return Completion {
            line: line.to_string(),
            cursor,
            candidates: Vec::new(),
        };
    }

    let mut start = cursor;
    while start > 0 && !is_separator(chars[start - 1]) {
        start -= 1;
    }
    let prefix: String = chars[start..cursor].iter().collect();
    let at_command = is_command_position(&chars, start);
    let candidates = if at_command {
        command_candidates(&prefix, aliases)
    } else {
        file_candidates(&prefix)
    };

    if candidates.is_empty() {
        return Completion {
            line: line.to_string(),
            cursor,
            candidates: Vec::new(),
        };
    }

    let replacement = if candidates.len() == 1 {
        let mut text = candidates[0].insert.clone();
        if !text.ends_with('\\') {
            text.push(' ');
        }
        text
    } else {
        let inserts: Vec<&str> = candidates.iter().map(|c| c.insert.as_str()).collect();
        common_prefix(&inserts)
    };

    let new_line = if replacement.chars().count() > prefix.chars().count() {
        let mut out: Vec<char> = chars[..start].to_vec();
        out.extend(replacement.chars());
        let new_cursor = out.len();
        out.extend(chars[cursor..].iter());
        Some((out.iter().collect::<String>(), new_cursor))
    } else {
        None
    };

    let (line, cursor) = new_line.unwrap_or_else(|| (line.to_string(), cursor));
    let candidates = if candidates.len() > 1 {
        candidates.into_iter().map(|c| c.display).collect()
    } else {
        Vec::new()
    };
    Completion {
        line,
        cursor,
        candidates,
    }
}

fn is_separator(ch: char) -> bool {
    ch.is_whitespace() || ch == '|' || ch == '<' || ch == '>'
}

/// 当前词是否处于命令位置（行首、管道后或重定向前）。
fn is_command_position(chars: &[char], start: usize) -> bool {
    let mut i = start;
    while i > 0 && chars[i - 1].is_whitespace() {
        i -= 1;
    }
    if i == 0 {
        return true;
    }
    matches!(chars[i - 1], '|' | '>' | '<')
}

fn command_candidates(prefix: &str, aliases: &BTreeMap<String, String>) -> Vec<Candidate> {
    let lower = prefix.to_ascii_lowercase();
    let mut out: Vec<Candidate> = Vec::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();

    let push = |name: &str, out: &mut Vec<Candidate>, seen: &mut BTreeSet<String>| {
        // 按「去掉可执行扩展名」去重：内置 mkdir 与 PATH 里的 mkdir.exe 是同一个命令，
        // 否则 Git / LLVM 等带 Unix 工具的 PATH 会让补全退化成公共前缀、不再补空格。
        let key = stem_key(name);
        if seen.insert(key) {
            out.push(Candidate {
                insert: name.to_string(),
                display: name.to_string(),
            });
        }
    };

    for name in builtins::BUILTIN_NAMES {
        if name.starts_with(&lower) {
            push(name, &mut out, &mut seen);
        }
    }
    for name in aliases.keys() {
        if name.to_ascii_lowercase().starts_with(&lower) {
            push(name, &mut out, &mut seen);
        }
    }
    // 空前缀不扫 PATH（否则会列出几十万个文件名）。
    if !prefix.is_empty() {
        for name in path_executables(prefix) {
            push(&name, &mut out, &mut seen);
        }
    }
    out.sort_by(|a, b| a.insert.to_ascii_lowercase().cmp(&b.insert.to_ascii_lowercase()));
    out
}

/// 去重键：小写并去掉 PATHEXT 里的扩展名（`mkdir.exe` 与 `mkdir` 视为同一项）。
fn stem_key(name: &str) -> String {
    let lower = name.to_ascii_lowercase();
    for ext in builtins::pathext() {
        if let Some(stem) = lower.strip_suffix(&ext) {
            return stem.to_string();
        }
    }
    lower
}

/// PATH 中前缀匹配的可执行文件名（按 PATHEXT 过滤）。
pub fn path_executables(prefix: &str) -> Vec<String> {
    let lower = prefix.to_ascii_lowercase();
    let exts = builtins::pathext();
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    let Some(path) = std::env::var_os("PATH") else {
        return out;
    };
    for dir in std::env::split_paths(&path) {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            let lower_name = name.to_ascii_lowercase();
            if !lower_name.starts_with(&lower) {
                continue;
            }
            if !exts.iter().any(|ext| lower_name.ends_with(ext.as_str())) {
                continue;
            }
            if seen.insert(lower_name) {
                out.push(name);
            }
        }
    }
    out
}

fn file_candidates(prefix: &str) -> Vec<Candidate> {
    let (dir_part, name_part) = split_dir(prefix);
    let dir = if dir_part.is_empty() {
        PathBuf::from(".")
    } else {
        PathBuf::from(dir_part)
    };
    let lower = name_part.to_ascii_lowercase();
    let mut items: Vec<(String, bool)> = Vec::new();
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.to_ascii_lowercase().starts_with(&lower) {
            continue;
        }
        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        items.push((name, is_dir));
    }
    items.sort_by(|a, b| a.0.to_ascii_lowercase().cmp(&b.0.to_ascii_lowercase()));

    items
        .into_iter()
        .map(|(name, is_dir)| {
            let mut insert = format!("{dir_part}{name}");
            if is_dir {
                insert.push('\\');
            }
            Candidate {
                insert,
                display: if is_dir {
                    format!("{name}\\")
                } else {
                    name
                },
            }
        })
        .collect()
}

/// 拆出目录前缀（含分隔符）与文件名前缀。
fn split_dir(prefix: &str) -> (&str, &str) {
    match prefix.rfind(|c| c == '\\' || c == '/') {
        Some(index) => (&prefix[..=index], &prefix[index + 1..]),
        None => ("", prefix),
    }
}

fn common_prefix(values: &[&str]) -> String {
    let mut chars: Vec<char> = values[0].chars().collect();
    for value in &values[1..] {
        let other: Vec<char> = value.chars().collect();
        let mut i = 0;
        while i < chars.len() && i < other.len() && chars[i].eq_ignore_ascii_case(&other[i]) {
            i += 1;
        }
        chars.truncate(i);
    }
    chars.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn completes_builtin_command() {
        let result = complete("mkdi", 4, &BTreeMap::new());
        assert_eq!(result.line, "mkdir ");
        assert_eq!(result.cursor, 6);
        assert!(result.candidates.is_empty());
    }

    #[test]
    fn stem_key_ignores_executable_extensions() {
        assert_eq!(stem_key("MKDIR.EXE"), "mkdir");
        assert_eq!(stem_key("cmd"), "cmd");
    }

    #[test]
    fn completes_alias() {
        // 用不太可能和 PATH 里可执行文件重名的别名（CI 的 PATH 带 LLVM 的 lld.exe）。
        let mut aliases = BTreeMap::new();
        aliases.insert("zz".to_string(), "dir".to_string());
        let result = complete("zz", 2, &aliases);
        assert_eq!(result.line, "zz ");
    }

    #[test]
    fn completes_files_and_stops_at_common_prefix() {
        let dir = temp_dir("scterm_complete_files");
        std::fs::write(dir.join("alpha.txt"), b"x").unwrap();
        std::fs::write(dir.join("alphabet.txt"), b"x").unwrap();
        std::fs::write(dir.join("beta.txt"), b"x").unwrap();

        let line = format!("type {}\\al", dir.display());
        let cursor = line.chars().count();
        let result = complete(&line, cursor, &BTreeMap::new());
        assert_eq!(result.candidates.len(), 2);
        assert!(result.line.ends_with("alpha"));
        assert_eq!(result.cursor, result.line.chars().count());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn single_file_is_completed_with_space() {
        let dir = temp_dir("scterm_complete_single");
        std::fs::write(dir.join("unique.txt"), b"x").unwrap();

        let line = format!("type {}\\uni", dir.display());
        let cursor = line.chars().count();
        let result = complete(&line, cursor, &BTreeMap::new());
        assert!(result.line.ends_with("unique.txt "));
        assert!(result.candidates.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn directories_get_trailing_backslash() {
        let dir = temp_dir("scterm_complete_dir");
        std::fs::create_dir_all(dir.join("subdir")).unwrap();

        let line = format!("cd {}\\sub", dir.display());
        let cursor = line.chars().count();
        let result = complete(&line, cursor, &BTreeMap::new());
        assert!(result.line.ends_with("subdir\\"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}

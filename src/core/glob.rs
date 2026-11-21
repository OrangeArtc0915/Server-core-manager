//! 简易 glob 匹配与 .gitignore 规则。
//!
//! 支持 `*`（不跨目录）、`**`（跨目录）、`?`（单个非分隔符字符）；
//! 不含 `/` 的模式按文件名匹配，含 `/` 的模式按相对路径匹配。

/// 单个 glob 模式匹配路径。
pub fn glob_match(pattern: &str, text: &str) -> bool {
    let pattern: Vec<char> = pattern.chars().collect();
    let text: Vec<char> = text.chars().collect();
    match_from(&pattern, 0, &text, 0)
}

fn match_from(pattern: &[char], mut p: usize, text: &[char], mut t: usize) -> bool {
    while p < pattern.len() {
        match pattern[p] {
            '*' => {
                // `**` 跨目录，`*` 不跨目录
                let double = pattern.get(p + 1) == Some(&'*');
                let mut next = p + if double { 2 } else { 1 };
                // 跳过 `**/` 形式中的分隔符
                let skip_sep = double && pattern.get(next) == Some(&'/');
                if skip_sep {
                    next += 1;
                }
                if next == pattern.len() {
                    if double {
                        return true;
                    }
                    return !text[t..].contains(&'/');
                }
                let mut index = t;
                loop {
                    if match_from(pattern, next, text, index) {
                        return true;
                    }
                    if index >= text.len() {
                        return false;
                    }
                    if !double && text[index] == '/' {
                        return false;
                    }
                    index += 1;
                }
            }
            '?' => {
                if t >= text.len() || text[t] == '/' {
                    return false;
                }
                p += 1;
                t += 1;
            }
            ch => {
                if t >= text.len() || text[t] != ch {
                    return false;
                }
                p += 1;
                t += 1;
            }
        }
    }
    t == text.len()
}

/// 模式是否按相对路径（含 `/`）匹配。
fn path_pattern(pattern: &str) -> bool {
    pattern.contains('/')
}

/// 判断路径是否命中任意一条模式（逗号或分号分隔）。
pub fn match_patterns(patterns: &str, rel: &str) -> bool {
    let name = rel.rsplit('/').next().unwrap_or(rel);
    patterns
        .split([';', ','])
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .any(|pattern| {
            if path_pattern(pattern) {
                glob_match(pattern.trim_start_matches("./"), rel)
                    || glob_match(pattern.trim_start_matches("./"), &format!("/{rel}"))
            } else {
                glob_match(pattern, name)
            }
        })
}

/// .gitignore 规则（仅根目录的 .gitignore）。
pub struct IgnoreRules {
    rules: Vec<(bool, String)>,
}

impl IgnoreRules {
    pub fn empty() -> IgnoreRules {
        IgnoreRules { rules: Vec::new() }
    }

    /// 从 `root/.gitignore` 加载；读取失败时返回空规则。
    pub fn load(root: &std::path::Path) -> IgnoreRules {
        let Ok(text) = std::fs::read_to_string(root.join(".gitignore")) else {
            return IgnoreRules::empty();
        };
        let mut rules = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (negate, pattern) = match line.strip_prefix('!') {
                Some(rest) => (true, rest.trim()),
                None => (false, line),
            };
            if pattern.is_empty() {
                continue;
            }
            rules.push((negate, pattern.trim_end_matches('/').to_string()));
        }
        IgnoreRules { rules }
    }

    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }

    /// 路径（相对 root，`/` 分隔）是否被忽略；后出现的规则优先。
    pub fn is_ignored(&self, rel: &str, is_dir: bool) -> bool {
        let mut ignored = false;
        for (negate, pattern) in &self.rules {
            // 兼容未去掉末尾 `/` 的目录规则
            let pattern = pattern.trim_end_matches('/');
            let matched = if path_pattern(pattern) {
                // 目录规则：本身或任一祖先目录命中即忽略
                glob_match(pattern, rel)
                    || rel
                        .match_indices('/')
                        .any(|(index, _)| glob_match(pattern, &rel[..index]))
            } else {
                let name = rel.rsplit('/').next().unwrap_or(rel);
                glob_match(pattern, name)
                    || rel
                        .match_indices('/')
                        .any(|(index, _)| glob_match(pattern, &rel[..index]))
            };
            if matched {
                ignored = !negate;
            }
        }
        if is_dir {
            return ignored;
        }
        ignored
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glob_basics() {
        assert!(glob_match("*.rs", "main.rs"));
        assert!(!glob_match("*.rs", "src/main.rs"));
        assert!(glob_match("src/*.rs", "src/main.rs"));
        assert!(!glob_match("src/*.rs", "src/ui/main.rs"));
        assert!(glob_match("src/**/*.rs", "src/ui/main.rs"));
        assert!(glob_match("src/**", "src/ui/main.rs"));
        assert!(glob_match("?.rs", "a.rs"));
        assert!(!glob_match("?.rs", "ab.rs"));
        assert!(glob_match("**/test/*.c", "a/b/test/x.c"));
    }

    #[test]
    fn include_exclude_patterns() {
        assert!(match_patterns("*.rs, *.toml", "src/main.rs"));
        assert!(match_patterns("src/**", "src/ui/app.rs"));
        assert!(!match_patterns("*.md", "src/main.rs"));
        assert!(match_patterns("app.rs; lib.rs", "src/app.rs"));
    }

    #[test]
    fn gitignore_rules() {
        let rules = IgnoreRules {
            rules: vec![
                (false, "target".into()),
                (false, "*.log".into()),
                (true, "keep.log".into()),
                (false, "build/".into()),
                (false, "*.tmp".into()),
            ],
        };
        assert!(rules.is_ignored("target/debug/a.o", false));
        assert!(rules.is_ignored("a/b.log", false));
        assert!(!rules.is_ignored("a/keep.log", false));
        assert!(rules.is_ignored("build/x.txt", false));
        assert!(rules.is_ignored("a/b.tmp", false));
        assert!(!rules.is_ignored("src/main.rs", false));
    }
}

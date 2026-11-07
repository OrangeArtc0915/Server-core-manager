//! 命令行解析：变量展开 → 分词（引号/^ 转义）→ 管道与重定向。
//!
//! 变量语法同时支持 cmd 风格的 `%NAME%` 与 shell 风格的 `$NAME` / `${NAME}`；
//! 与 cmd 一致，展开发生在分词之前，因此引号里的变量同样会被展开。

/// 重定向类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RedirectKind {
    Stdout,
    StdoutAppend,
    Stderr,
    StderrAppend,
    Stdin,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Redirect {
    pub kind: RedirectKind,
    pub target: String,
}

/// 管道中的一条命令：词列表 + 重定向。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Command {
    pub words: Vec<String>,
    pub redirects: Vec<Redirect>,
}

impl Command {
    pub fn redirect(&self, kind: RedirectKind) -> Option<&Redirect> {
        self.redirects.iter().find(|r| r.kind == kind)
    }

    pub fn stdout_target(&self) -> Option<&Redirect> {
        self.redirect(RedirectKind::Stdout)
            .or_else(|| self.redirect(RedirectKind::StdoutAppend))
    }

    pub fn stderr_target(&self) -> Option<&Redirect> {
        self.redirect(RedirectKind::Stderr)
            .or_else(|| self.redirect(RedirectKind::StderrAppend))
    }
}

/// 解析一整行；空行返回空列表。
pub fn parse_line(line: &str) -> Result<Vec<Command>, String> {
    let expanded = expand_vars(line);
    let chars: Vec<char> = expanded.chars().collect();
    let mut commands: Vec<Command> = Vec::new();
    let mut current = Command::default();
    let mut token = String::new();
    let mut has_token = false;
    let mut quote: Option<char> = None;
    let mut i = 0usize;

    while i < chars.len() {
        let ch = chars[i];
        if let Some(q) = quote {
            if ch == q {
                quote = None;
            } else {
                token.push(ch);
            }
            i += 1;
            continue;
        }
        match ch {
            '"' | '\'' => {
                quote = Some(ch);
                has_token = true;
                i += 1;
            }
            ' ' | '\t' => {
                flush(&mut token, &mut has_token, &mut current);
                i += 1;
            }
            '^' => {
                if i + 1 < chars.len() {
                    token.push(chars[i + 1]);
                    has_token = true;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            '|' => {
                flush(&mut token, &mut has_token, &mut current);
                if current.words.is_empty() {
                    return Err("管道两侧都必须有命令".into());
                }
                commands.push(std::mem::take(&mut current));
                i += 1;
            }
            '>' | '<' => {
                flush(&mut token, &mut has_token, &mut current);
                let (kind, consume) = if ch == '>' {
                    if i + 1 < chars.len() && chars[i + 1] == '>' {
                        (RedirectKind::StdoutAppend, 2)
                    } else {
                        (RedirectKind::Stdout, 1)
                    }
                } else {
                    (RedirectKind::Stdin, 1)
                };
                i += consume;
                let target = read_word(&chars, &mut i)
                    .ok_or_else(|| "重定向符号后面缺少文件名".to_string())?;
                current.redirects.push(Redirect { kind, target });
            }
            '2' if !has_token && i + 1 < chars.len() && chars[i + 1] == '>' => {
                let (kind, consume) = if i + 2 < chars.len() && chars[i + 2] == '>' {
                    (RedirectKind::StderrAppend, 3)
                } else {
                    (RedirectKind::Stderr, 2)
                };
                i += consume;
                let target = read_word(&chars, &mut i)
                    .ok_or_else(|| "重定向符号后面缺少文件名".to_string())?;
                current.redirects.push(Redirect { kind, target });
            }
            _ => {
                token.push(ch);
                has_token = true;
                i += 1;
            }
        }
    }

    if quote.is_some() {
        return Err("命令中存在未闭合的引号".into());
    }
    flush(&mut token, &mut has_token, &mut current);
    if !current.words.is_empty() || !current.redirects.is_empty() {
        if current.words.is_empty() {
            return Err("重定向前缺少命令".into());
        }
        commands.push(current);
    }
    Ok(commands)
}

fn flush(token: &mut String, has_token: &mut bool, current: &mut Command) {
    if *has_token {
        current.words.push(std::mem::take(token));
        *has_token = false;
    }
}

/// 读取一个词（用于重定向目标），支持引号与 `^` 转义。
fn read_word(chars: &[char], i: &mut usize) -> Option<String> {
    while *i < chars.len() && (chars[*i] == ' ' || chars[*i] == '\t') {
        *i += 1;
    }
    if *i >= chars.len() {
        return None;
    }
    let mut word = String::new();
    let mut quote: Option<char> = None;
    while *i < chars.len() {
        let ch = chars[*i];
        if let Some(q) = quote {
            if ch == q {
                quote = None;
            } else {
                word.push(ch);
            }
            *i += 1;
            continue;
        }
        match ch {
            '"' | '\'' => {
                quote = Some(ch);
                *i += 1;
            }
            ' ' | '\t' | '|' | '>' | '<' => break,
            '^' => {
                if *i + 1 < chars.len() {
                    word.push(chars[*i + 1]);
                    *i += 2;
                } else {
                    *i += 1;
                }
            }
            _ => {
                word.push(ch);
                *i += 1;
            }
        }
    }
    if word.is_empty() {
        None
    } else {
        Some(word)
    }
}

/// 展开 `%NAME%`、`$NAME`、`${NAME}`；未定义的变量展开为空串（与 cmd 一致）。
pub fn expand_vars(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut out = String::with_capacity(input.len());
    let mut i = 0usize;
    while i < chars.len() {
        match chars[i] {
            '%' => {
                if let Some(rel) = chars[i + 1..].iter().position(|&c| c == '%') {
                    let name: String = chars[i + 1..i + 1 + rel].iter().collect();
                    if !name.is_empty() {
                        out.push_str(&lookup(&name));
                        i += rel + 2;
                        continue;
                    }
                }
                out.push('%');
                i += 1;
            }
            '$' => {
                if i + 1 < chars.len() && chars[i + 1] == '{' {
                    if let Some(rel) = chars[i + 2..].iter().position(|&c| c == '}') {
                        let name: String = chars[i + 2..i + 2 + rel].iter().collect();
                        if !name.is_empty() {
                            out.push_str(&lookup(&name));
                            i += rel + 3;
                            continue;
                        }
                    }
                } else if i + 1 < chars.len()
                    && (chars[i + 1].is_ascii_alphabetic() || chars[i + 1] == '_')
                {
                    let mut j = i + 1;
                    while j < chars.len()
                        && (chars[j].is_ascii_alphanumeric() || chars[j] == '_')
                    {
                        j += 1;
                    }
                    let name: String = chars[i + 1..j].iter().collect();
                    out.push_str(&lookup(&name));
                    i = j;
                    continue;
                }
                out.push('$');
                i += 1;
            }
            ch => {
                out.push(ch);
                i += 1;
            }
        }
    }
    out
}

fn lookup(name: &str) -> String {
    std::env::var(name).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_percent_and_dollar() {
        std::env::set_var("SCTERM_TEST_VAR", "hello world");
        assert_eq!(expand_vars("echo %SCTERM_TEST_VAR%"), "echo hello world");
        assert_eq!(expand_vars("echo $SCTERM_TEST_VAR"), "echo hello world");
        assert_eq!(expand_vars("echo ${SCTERM_TEST_VAR}!"), "echo hello world!");
        assert_eq!(expand_vars("echo 50%"), "echo 50%");
        assert_eq!(expand_vars("echo $"), "echo $");
        std::env::remove_var("SCTERM_TEST_VAR");
    }

    #[test]
    fn quotes_group_words() {
        let cmds = parse_line(r#"echo "hello world" 'second one'"#).unwrap();
        assert_eq!(cmds.len(), 1);
        assert_eq!(cmds[0].words, vec!["echo", "hello world", "second one"]);
    }

    #[test]
    fn pipe_and_redirect() {
        let cmds = parse_line("dir | more > out.txt").unwrap();
        assert_eq!(cmds.len(), 2);
        assert_eq!(cmds[0].words, vec!["dir"]);
        assert_eq!(
            cmds[1].stdout_target(),
            Some(&Redirect {
                kind: RedirectKind::Stdout,
                target: "out.txt".into()
            })
        );

        let cmds = parse_line("echo hi>>log.txt").unwrap();
        assert_eq!(cmds[0].words, vec!["echo", "hi"]);
        assert_eq!(
            cmds[0].stdout_target().unwrap().kind,
            RedirectKind::StdoutAppend
        );
    }

    #[test]
    fn stdin_and_stderr_redirect() {
        let cmds = parse_line("findstr x < in.txt 2> err.txt").unwrap();
        assert_eq!(cmds[0].words, vec!["findstr", "x"]);
        assert_eq!(cmds[0].redirect(RedirectKind::Stdin).unwrap().target, "in.txt");
        assert_eq!(cmds[0].stderr_target().unwrap().target, "err.txt");
    }

    #[test]
    fn errors_are_reported() {
        assert!(parse_line("echo \"unclosed").is_err());
        assert!(parse_line("echo hi >").is_err());
        assert!(parse_line("| more").is_err());
    }

    #[test]
    fn blank_line_is_empty() {
        assert!(parse_line("   ").unwrap().is_empty());
    }
}

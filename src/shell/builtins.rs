//! 内置命令：cd / dir / cls / echo / set / type / del / mkdir / copy / move /
//! where / alias / history / run / ver / help / exit。
//!
//! 内置命令的输出统一走 `Shell::write`，因此 `>` / `>>` 重定向对它们同样生效。

use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use super::Shell;
use crate::platform::version;
use crate::platform::win32;

pub const BUILTIN_NAMES: &[&str] = &[
    "alias", "cd", "chcp", "cls", "copy", "date", "del", "dir", "echo", "erase", "exit", "help",
    "history", "md", "mkdir", "move", "pause", "popd", "prompt", "pushd", "pwd", "rd", "ren",
    "rename", "rmdir", "run", "set", "time", "title", "type", "ver", "vol", "where",
];

fn canonical(name: &str) -> String {
    if name.eq_ignore_ascii_case("echo.") {
        "echo".to_string()
    } else if name.eq_ignore_ascii_case("rd") {
        "rmdir".to_string()
    } else if name.eq_ignore_ascii_case("md") {
        "mkdir".to_string()
    } else if name.eq_ignore_ascii_case("erase") {
        "del".to_string()
    } else if name.eq_ignore_ascii_case("rename") {
        "ren".to_string()
    } else if name.eq_ignore_ascii_case("chdir") {
        "cd".to_string()
    } else {
        name.to_ascii_lowercase()
    }
}

pub fn is_builtin(name: &str) -> bool {
    BUILTIN_NAMES.contains(&canonical(name).as_str())
}

pub fn run(shell: &mut Shell, name: &str, args: &[String]) -> Result<(), String> {
    match canonical(name).as_str() {
        "cd" => cd(args),
        "dir" => dir(shell, args),
        "cls" => shell.write(b"\x1b[2J\x1b[H"),
        "echo" => {
            if name.eq_ignore_ascii_case("echo.") && args.is_empty() {
                return shell.write(b"\r\n");
            }
            if args.len() == 1 && args[0] == "." {
                return shell.write(b"\r\n");
            }
            // cmd 的 `echo off` / `echo on` 只切换命令回显，本身不输出任何内容。
            if args.len() == 1
                && (args[0].eq_ignore_ascii_case("off") || args[0].eq_ignore_ascii_case("on"))
            {
                return Ok(());
            }
            shell.print_line(&args.join(" "))
        }
        "set" => set(shell, args),
        "pwd" => {
            let cwd = std::env::current_dir()
                .map(|p| p.display().to_string())
                .unwrap_or_default();
            shell.print_line(&cwd)
        }
        "type" => type_files(shell, args),
        "del" => del(args),
        "mkdir" => mkdir(args),
        "rmdir" => rmdir(args),
        "copy" => copy(shell, args),
        "move" => move_file(shell, args),
        "where" => where_cmd(shell, args),
        "title" => title(shell, args),
        "prompt" => prompt_cmd(shell, args),
        "vol" => vol(shell),
        "date" => date(shell, args),
        "time" => time(shell, args),
        "chcp" => chcp(shell, args),
        "pause" => pause(shell),
        "pushd" => pushd(shell, args),
        "popd" => popd(shell),
        "ren" => rename(args),
        "alias" => alias(shell, args),
        "history" => history(shell, args),
        "run" => match args.first() {
            Some(path) => super::script::run_file(shell, path, &args[1..]),
            None => Err("用法：run 脚本.sct [参数...]".into()),
        },
        "ver" => shell.print_line(&format!(
            "scterm shell {}（Windows build {}）",
            env!("CARGO_PKG_VERSION"),
            version::build_number()
        )),
        "help" => write_text(shell, HELP_TEXT),
        "exit" => exit(shell, args),
        _ => Err(format!("未知的内置命令 {name}")),
    }
}

const HELP_TEXT: &str = r#"scterm shell 内置命令：
  cd [目录]         切换目录（无参数回用户目录）
  dir [目录|通配符] 列出目录内容（支持 *.txt）
  pwd               显示当前目录
  cls               清屏
  echo 文本...      输出文本（echo. 输出空行）
  set [名[=值]]     查看全部变量 / 查看 / 设置 / 删除变量
  set /a [名=]表达式 计算整数表达式（如 set /a n=n+1）
  type 文件...      输出文件内容（支持通配符）
  mkdir 目录        创建目录（含父目录，md 同义）
  rmdir 目录...     删除空目录（rd 同义）
  del 文件...       删除文件（支持通配符，erase 同义）
  copy 源 目标      复制文件（源支持通配符）
  move 源 目标      移动或重命名（源支持通配符）
  ren 原名 新名     重命名文件或目录（rename 同义）
  pushd [目录]      压栈并切换目录；无参数时与栈顶交换
  popd              弹出栈顶并切换过去
  where 命令...     在 PATH 中查找可执行文件
  title 文本        设置终端标题
  prompt [模板]     查看 / 设置提示符（$P 路径、$G >、$D 日期、$T 时间、$_ 换行、$$ 字面 $）
  vol               显示当前驱动器的卷标与文件系统
  date [/t]         显示本地日期
  time [/t]         显示本地时间
  chcp [代码页]     查看代码页（固定 UTF-8 / 65001）
  pause             等待按键
  alias [名=命令]   查看 / 设置别名
  history [-c]      查看 / 清空历史命令
  run 文件.sct ...  执行脚本，脚本内用 %1 %2 %* 取参数
  ver               显示版本
  exit [码]         退出 shell

其它：任意 .exe 直接运行；支持 | 管道与 > >> < 2> 重定向；%VAR% / $VAR 变量；
Tab 补全、↑↓ 历史、Ctrl+C 取消当前行、Ctrl+L 清屏。
脚本（run 文件.sct）：支持 if / else、for（/l /d /r）、goto 标签、call :子程序、exit /b。
"#;

fn cd(args: &[String]) -> Result<(), String> {
    let target = match args.first() {
        Some(arg) if arg == "~" => home_dir()?,
        Some(arg) => arg.clone(),
        None => home_dir()?,
    };
    let path = PathBuf::from(&target);
    let absolute = if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .map_err(|e| format!("无法读取当前目录：{e}"))?
            .join(path)
    };
    let absolute = normalize(&absolute);
    if !absolute.is_dir() {
        return Err(format!("目录不存在：{}", absolute.display()));
    }
    std::env::set_current_dir(&absolute)
        .map_err(|e| format!("无法进入目录 {}：{e}", absolute.display()))
}

fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn home_dir() -> Result<String, String> {
    if let Some(value) = std::env::var_os("USERPROFILE") {
        let text = value.to_string_lossy().to_string();
        if !text.is_empty() {
            return Ok(text);
        }
    }
    let drive = std::env::var("HOMEDRIVE").unwrap_or_default();
    let path = std::env::var("HOMEPATH").unwrap_or_default();
    if !drive.is_empty() || !path.is_empty() {
        return Ok(format!("{drive}{path}"));
    }
    Err("无法确定用户主目录（USERPROFILE 未设置）".into())
}

pub struct EntryInfo {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: String,
}

pub fn dir_entries(path: &Path) -> Result<Vec<EntryInfo>, String> {
    let read = std::fs::read_dir(path).map_err(|e| format!("无法读取目录 {}：{e}", path.display()))?;
    let mut entries = Vec::new();
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        let meta = entry.metadata().ok();
        let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
        let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
        let modified = meta
            .and_then(|m| m.modified().ok())
            .map(format_time)
            .unwrap_or_else(|| " ".repeat(16));
        entries.push(EntryInfo {
            name,
            is_dir,
            size,
            modified,
        });
    }
    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_ascii_lowercase().cmp(&b.name.to_ascii_lowercase()))
    });
    Ok(entries)
}

fn dir(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    let target = args.first().cloned().unwrap_or_else(|| ".".to_string());
    // 支持 dir *.txt / dir src\*.rs 这类通配符
    let (dir_text, filter) = if target.contains('*') || target.contains('?') {
        let (dir_part, name_part) = split_dir(&target);
        let dir_text = if dir_part.is_empty() {
            ".".to_string()
        } else {
            dir_part.to_string()
        };
        (dir_text, Some(name_part.to_string()))
    } else {
        (target, None)
    };
    let path = PathBuf::from(&dir_text);
    if !path.is_dir() {
        return Err(format!("目录不存在：{dir_text}"));
    }
    let absolute = {
        let base = std::env::current_dir().unwrap_or_default();
        normalize(&base.join(&path))
    };
    let mut entries = dir_entries(&path)?;
    if let Some(pattern) = &filter {
        entries.retain(|entry| wildcard_match(pattern, &entry.name));
    }

    let mut out = String::new();
    match &filter {
        Some(pattern) => out.push_str(&format!(
            " {} 下匹配 {pattern} 的条目\r\n\r\n",
            absolute.display()
        )),
        None => out.push_str(&format!(" {} 的目录\r\n\r\n", absolute.display())),
    }
    out.push_str(&format!(
        "{}{}  {}\r\n",
        pad_cells("修改时间", 19, false),
        pad_cells("大小", 14, true),
        "名称"
    ));
    let mut files = 0usize;
    let mut dirs = 0usize;
    let mut bytes = 0u64;
    for entry in &entries {
        if entry.is_dir {
            dirs += 1;
            out.push_str(&format!(
                "{}{}  {}\r\n",
                pad_cells(&entry.modified, 19, false),
                pad_cells("<DIR>", 14, true),
                entry.name
            ));
        } else {
            files += 1;
            bytes += entry.size;
            out.push_str(&format!(
                "{}{}  {}\r\n",
                pad_cells(&entry.modified, 19, false),
                pad_cells(&format_size(entry.size), 14, true),
                entry.name
            ));
        }
    }
    out.push_str(&format!(
        "\r\n  {} 个文件  {:>14} 字节\r\n  {} 个目录\r\n",
        files,
        format_size(bytes),
        dirs
    ));
    shell.write(out.as_bytes())
}

/// 按「显示单元格宽度」补齐空格（中文字符按 2 格），保证列对齐。
fn pad_cells(text: &str, width: usize, right_align: bool) -> String {
    let cells: usize = text
        .chars()
        .map(|c| crate::emulation::screen::char_width(c).max(1))
        .sum();
    if cells >= width {
        return text.to_string();
    }
    let padding = " ".repeat(width - cells);
    if right_align {
        format!("{padding}{text}")
    } else {
        format!("{text}{padding}")
    }
}

fn format_size(size: u64) -> String {
    let digits = size.to_string();
    let mut out = String::new();
    for (index, ch) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

fn split_dir(text: &str) -> (&str, &str) {
    match text.rfind(|c| c == '\\' || c == '/') {
        Some(index) => (&text[..=index], &text[index + 1..]),
        None => ("", text),
    }
}

/// 展开参数里的 `*` / `?`；没有匹配时保留原串，让调用方给出自然错误。
pub fn expand_patterns(args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for arg in args {
        if arg.contains('*') || arg.contains('?') {
            let matches = glob(arg);
            if matches.is_empty() {
                out.push(arg.clone());
            } else {
                out.extend(matches);
            }
        } else {
            out.push(arg.clone());
        }
    }
    out
}

pub fn glob(pattern: &str) -> Vec<String> {
    let (dir_part, name_part) = split_dir(pattern);
    let dir = if dir_part.is_empty() { "." } else { dir_part };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<String> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            if wildcard_match(name_part, &name) {
                Some(format!("{dir_part}{name}"))
            } else {
                None
            }
        })
        .collect();
    out.sort_by(|a, b| a.to_ascii_lowercase().cmp(&b.to_ascii_lowercase()));
    out
}

/// `*` 匹配任意长度、`?` 匹配单个字符，大小写不敏感。
pub fn wildcard_match(pattern: &str, text: &str) -> bool {
    let pattern: Vec<char> = pattern.to_lowercase().chars().collect();
    let text: Vec<char> = text.to_lowercase().chars().collect();
    let (mut pi, mut ti) = (0usize, 0usize);
    let mut star: Option<usize> = None;
    let mut mark = 0usize;
    while ti < text.len() {
        if pi < pattern.len() && (pattern[pi] == '?' || pattern[pi] == text[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < pattern.len() && pattern[pi] == '*' {
            star = Some(pi);
            mark = ti;
            pi += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    while pi < pattern.len() && pattern[pi] == '*' {
        pi += 1;
    }
    pi == pattern.len()
}

fn format_time(time: SystemTime) -> String {
    let Ok(duration) = time.duration_since(UNIX_EPOCH) else {
        return " ".repeat(16);
    };
    // FILETIME：自 1601 起的 100 纳秒数，UNIX 纪元差 11644473600 秒。
    let filetime =
        duration.as_secs() * 10_000_000 + duration.subsec_nanos() as u64 / 100 + 116_444_736_000_000_000;
    unsafe {
        let mut local = 0u64;
        let mut st = win32::SYSTEMTIME::default();
        if win32::FileTimeToLocalFileTime(&filetime, &mut local) != 0
            && win32::FileTimeToSystemTime(&local, &mut st) != 0
        {
            return format!(
                "{:04}/{:02}/{:02} {:02}:{:02}",
                st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute
            );
        }
    }
    " ".repeat(16)
}

/// `set` / `alias` 的参数解析结果。
#[derive(Debug, PartialEq, Eq)]
pub enum SetAction<'a> {
    Set { name: &'a str, value: &'a str },
    Remove { name: &'a str },
    Query { name: &'a str },
}

pub fn split_set_arg(arg: &str) -> SetAction<'_> {
    match arg.find('=') {
        Some(index) => {
            let name = arg[..index].trim();
            let value = &arg[index + 1..];
            if value.is_empty() {
                SetAction::Remove { name }
            } else {
                SetAction::Set { name, value }
            }
        }
        None => SetAction::Query { name: arg.trim() },
    }
}

fn set(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    if args.first().map(|arg| arg.eq_ignore_ascii_case("/a")).unwrap_or(false) {
        return set_arithmetic(shell, &args[1..]);
    }
    if args.is_empty() {
        let mut vars: Vec<(String, String)> = std::env::vars().collect();
        vars.sort_by(|a, b| a.0.to_ascii_lowercase().cmp(&b.0.to_ascii_lowercase()));
        let mut out = String::new();
        for (name, value) in vars {
            out.push_str(&format!("{name}={value}\r\n"));
        }
        return shell.write(out.as_bytes());
    }

    let joined = args.join(" ");
    match split_set_arg(&joined) {
        SetAction::Set { name, value } => {
            if name.is_empty() {
                return Err("环境变量名不能为空".into());
            }
            std::env::set_var(name, value);
            Ok(())
        }
        SetAction::Remove { name } => {
            if name.is_empty() {
                return Err("环境变量名不能为空".into());
            }
            std::env::remove_var(name);
            Ok(())
        }
        SetAction::Query { name } => match std::env::var(name) {
            Ok(value) => shell.print_line(&format!("{name}={value}")),
            Err(_) => Err(format!("环境变量「{name}」未定义")),
        },
    }
}

/// `set /a`：按 cmd 语义处理逗号分隔的多段表达式。
/// 每段可以是 `变量=表达式` 或裸表达式，最后一段的值决定输出：
/// 命令行里总是打印（`set /a n=1` 输出 `1`，`set /a a=1,b=2` 输出 `2`），
/// 脚本（相当于批处理）里一律不打印。
fn set_arithmetic(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    let joined = args.join(" ");
    let joined = joined.trim();
    if joined.is_empty() {
        return Err("用法：set /a [变量=]表达式".into());
    }
    let segments = split_top_level_commas(joined)?;
    let mut last = 0i64;
    let mut count = 0usize;
    for segment in &segments {
        let segment = segment.trim();
        if segment.is_empty() {
            continue;
        }
        last = if let Some(index) = top_level_assignment(segment) {
            let name = segment[..index].trim();
            if name.is_empty() {
                return Err("set /a 赋值时缺少变量名".into());
            }
            let value = eval_arithmetic(&segment[index + 1..])?;
            std::env::set_var(name, value.to_string());
            value
        } else {
            eval_arithmetic(segment)?
        };
        count += 1;
    }
    if count == 0 {
        return Err("set /a 的表达式为空".into());
    }
    // cmd：命令行总是打印最后一段的值；批处理（`.sct` 脚本）不打印。
    if shell.in_script {
        Ok(())
    } else {
        shell.print_line(&last.to_string())
    }
}

/// 按顶层逗号切分（括号内的逗号保留给表达式求值）。
fn split_top_level_commas(text: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut current = String::new();
    for ch in text.chars() {
        match ch {
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                if depth == 0 {
                    return Err("set /a 的括号没有闭合".into());
                }
                depth -= 1;
                current.push(ch);
            }
            ',' if depth == 0 => out.push(std::mem::take(&mut current)),
            _ => current.push(ch),
        }
    }
    if depth != 0 {
        return Err("set /a 的括号没有闭合".into());
    }
    out.push(current);
    Ok(out)
}

/// 返回顶层赋值号 `=` 的字节位置（左侧必须是合法变量名）。
fn top_level_assignment(text: &str) -> Option<usize> {
    let mut depth = 0usize;
    for (index, ch) in text.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => depth = depth.saturating_sub(1),
            '=' if depth == 0 => {
                let name = text[..index].trim();
                let valid = !name.is_empty()
                    && name
                        .chars()
                        .next()
                        .map(|c| c.is_ascii_alphabetic() || c == '_')
                        .unwrap_or(false)
                    && name
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '_');
                return if valid { Some(index) } else { None };
            }
            _ => {}
        }
    }
    None
}

/// cmd 风格整数表达式求值：支持 + - * / % << >> & ^ | ~ ! 与括号。
pub fn eval_arithmetic(expr: &str) -> Result<i64, String> {
    let tokens = arithmetic_tokens(expr)?;
    let mut cursor = 0usize;
    let value = parse_comma(&tokens, &mut cursor)?;
    if cursor != tokens.len() {
        return Err(format!("表达式中有多余内容：{expr}"));
    }
    Ok(value)
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ArithToken {
    Number(i64),
    Op(char),
    Shl,
    Shr,
    Open,
    Close,
    Comma,
}

fn arithmetic_tokens(expr: &str) -> Result<Vec<ArithToken>, String> {
    let chars: Vec<char> = expr.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0usize;
    while i < chars.len() {
        let ch = chars[i];
        if ch.is_whitespace() {
            i += 1;
            continue;
        }
        if ch.is_ascii_digit() {
            let start = i;
            while i < chars.len() && chars[i].is_ascii_alphanumeric() {
                i += 1;
            }
            let text: String = chars[start..i].iter().collect();
            let value = parse_number(&text)?;
            tokens.push(ArithToken::Number(value));
            continue;
        }
        if ch.is_ascii_alphabetic() || ch == '_' {
            let start = i;
            while i < chars.len() && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            let name: String = chars[start..i].iter().collect();
            let value = std::env::var(&name)
                .ok()
                .and_then(|text| text.trim().parse::<i64>().ok())
                .unwrap_or(0);
            tokens.push(ArithToken::Number(value));
            continue;
        }
        match ch {
            '(' => {
                tokens.push(ArithToken::Open);
                i += 1;
            }
            ')' => {
                tokens.push(ArithToken::Close);
                i += 1;
            }
            ',' => {
                tokens.push(ArithToken::Comma);
                i += 1;
            }
            '<' if i + 1 < chars.len() && chars[i + 1] == '<' => {
                tokens.push(ArithToken::Shl);
                i += 2;
            }
            '>' if i + 1 < chars.len() && chars[i + 1] == '>' => {
                tokens.push(ArithToken::Shr);
                i += 2;
            }
            '%' if i + 1 < chars.len() && chars[i + 1] == '%' => {
                tokens.push(ArithToken::Op('%'));
                i += 2;
            }
            '+' | '-' | '*' | '/' | '%' | '&' | '|' | '^' | '~' | '!' => {
                tokens.push(ArithToken::Op(ch));
                i += 1;
            }
            other => return Err(format!("表达式中出现无法识别的字符「{other}」")),
        }
    }
    if tokens.is_empty() {
        return Err("set /a 的表达式为空".into());
    }
    Ok(tokens)
}

fn parse_number(text: &str) -> Result<i64, String> {
    if let Some(hex) = text.strip_prefix("0x").or_else(|| text.strip_prefix("0X")) {
        return i64::from_str_radix(hex, 16).or_else(|_| {
            u64::from_str_radix(hex, 16)
                .map(|value| value as i64)
                .map_err(|_| format!("无效的十六进制数：{text}"))
        });
    }
    if text.len() > 1 && text.starts_with('0') {
        return i64::from_str_radix(&text[1..], 8)
            .map_err(|_| format!("无效的八进制数：{text}"));
    }
    text.parse::<i64>()
        .map_err(|_| format!("无效的数字：{text}"))
}

fn parse_comma(tokens: &[ArithToken], cursor: &mut usize) -> Result<i64, String> {
    let mut value = parse_or(tokens, cursor)?;
    while matches!(tokens.get(*cursor), Some(ArithToken::Comma)) {
        *cursor += 1;
        value = parse_or(tokens, cursor)?;
    }
    Ok(value)
}

fn parse_or(tokens: &[ArithToken], cursor: &mut usize) -> Result<i64, String> {
    let mut value = parse_xor(tokens, cursor)?;
    while matches!(tokens.get(*cursor), Some(ArithToken::Op('|'))) {
        *cursor += 1;
        value |= parse_xor(tokens, cursor)?;
    }
    Ok(value)
}

fn parse_xor(tokens: &[ArithToken], cursor: &mut usize) -> Result<i64, String> {
    let mut value = parse_and(tokens, cursor)?;
    while matches!(tokens.get(*cursor), Some(ArithToken::Op('^'))) {
        *cursor += 1;
        value ^= parse_and(tokens, cursor)?;
    }
    Ok(value)
}

fn parse_and(tokens: &[ArithToken], cursor: &mut usize) -> Result<i64, String> {
    let mut value = parse_shift(tokens, cursor)?;
    while matches!(tokens.get(*cursor), Some(ArithToken::Op('&'))) {
        *cursor += 1;
        value &= parse_shift(tokens, cursor)?;
    }
    Ok(value)
}

fn parse_shift(tokens: &[ArithToken], cursor: &mut usize) -> Result<i64, String> {
    let mut value = parse_add(tokens, cursor)?;
    loop {
        match tokens.get(*cursor) {
            Some(ArithToken::Shl) => {
                *cursor += 1;
                value = value.wrapping_shl(parse_add(tokens, cursor)? as u32);
            }
            Some(ArithToken::Shr) => {
                *cursor += 1;
                value = value.wrapping_shr(parse_add(tokens, cursor)? as u32);
            }
            _ => break,
        }
    }
    Ok(value)
}

fn parse_add(tokens: &[ArithToken], cursor: &mut usize) -> Result<i64, String> {
    let mut value = parse_mul(tokens, cursor)?;
    loop {
        match tokens.get(*cursor) {
            Some(ArithToken::Op('+')) => {
                *cursor += 1;
                value = value.wrapping_add(parse_mul(tokens, cursor)?);
            }
            Some(ArithToken::Op('-')) => {
                *cursor += 1;
                value = value.wrapping_sub(parse_mul(tokens, cursor)?);
            }
            _ => break,
        }
    }
    Ok(value)
}

fn parse_mul(tokens: &[ArithToken], cursor: &mut usize) -> Result<i64, String> {
    let mut value = parse_unary(tokens, cursor)?;
    loop {
        match tokens.get(*cursor) {
            Some(ArithToken::Op('*')) => {
                *cursor += 1;
                value = value.wrapping_mul(parse_unary(tokens, cursor)?);
            }
            Some(ArithToken::Op('/')) => {
                *cursor += 1;
                let divisor = parse_unary(tokens, cursor)?;
                if divisor == 0 {
                    return Err("set /a 除数为零".into());
                }
                value = value.wrapping_div(divisor);
            }
            Some(ArithToken::Op('%')) => {
                *cursor += 1;
                let divisor = parse_unary(tokens, cursor)?;
                if divisor == 0 {
                    return Err("set /a 除数为零".into());
                }
                value = value.wrapping_rem(divisor);
            }
            _ => break,
        }
    }
    Ok(value)
}

fn parse_unary(tokens: &[ArithToken], cursor: &mut usize) -> Result<i64, String> {
    match tokens.get(*cursor) {
        Some(ArithToken::Op('+')) => {
            *cursor += 1;
            parse_unary(tokens, cursor)
        }
        Some(ArithToken::Op('-')) => {
            *cursor += 1;
            parse_unary(tokens, cursor).map(|value| value.wrapping_neg())
        }
        Some(ArithToken::Op('~')) => {
            *cursor += 1;
            parse_unary(tokens, cursor).map(|value| !value)
        }
        Some(ArithToken::Op('!')) => {
            *cursor += 1;
            parse_unary(tokens, cursor).map(|value| if value == 0 { 1 } else { 0 })
        }
        Some(ArithToken::Number(value)) => {
            let value = *value;
            *cursor += 1;
            Ok(value)
        }
        Some(ArithToken::Open) => {
            *cursor += 1;
            let value = parse_comma(tokens, cursor)?;
            if !matches!(tokens.get(*cursor), Some(ArithToken::Close)) {
                return Err("set /a 的括号没有闭合".into());
            }
            *cursor += 1;
            Ok(value)
        }
        other => Err(format!("set /a 表达式不完整：{other:?}")),
    }
}

fn type_files(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("用法：type 文件...".into());
    }
    for path in expand_patterns(args) {
        let bytes = std::fs::read(&path).map_err(|e| format!("无法读取文件 {path}：{e}"))?;
        let text = String::from_utf8_lossy(&bytes);
        if text.contains('\0') {
            return Err(format!("{path} 看起来是二进制文件，已跳过"));
        }
        write_text(shell, &text)?;
        if !text.ends_with('\n') {
            shell.write(b"\r\n")?;
        }
    }
    Ok(())
}

/// 把 LF 统一成 CRLF 后输出（控制台里裸 LF 只会下移不回车）。
pub fn write_text(shell: &mut Shell, text: &str) -> Result<(), String> {
    let normalized = text
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .replace('\n', "\r\n");
    shell.write(normalized.as_bytes())
}

fn del(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("用法：del 文件...".into());
    }
    for path in expand_patterns(args) {
        let p = Path::new(&path);
        if p.is_dir() {
            return Err(format!("{path} 是目录，del 只删除文件"));
        }
        std::fs::remove_file(p).map_err(|e| format!("无法删除 {path}：{e}"))?;
    }
    Ok(())
}

fn mkdir(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("用法：mkdir 目录".into());
    }
    for path in args {
        std::fs::create_dir_all(path).map_err(|e| format!("无法创建目录 {path}：{e}"))?;
    }
    Ok(())
}

fn rmdir(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("用法：rmdir 目录...".into());
    }
    for path in expand_patterns(args) {
        let p = Path::new(&path);
        if p.is_file() {
            return Err(format!("{path} 是文件，rmdir 只删除目录"));
        }
        std::fs::remove_dir(p).map_err(|e| format!("无法删除目录 {path}：{e}"))?;
    }
    Ok(())
}

fn copy(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    let (source, target) = match args {
        [source, target] => (source, target),
        _ => return Err("用法：copy 源 目标".into()),
    };
    let sources = expand_patterns(std::slice::from_ref(source));
    let target_path = Path::new(target);
    let mut count = 0usize;
    for item in &sources {
        let source_path = Path::new(item);
        if !source_path.is_file() {
            if sources.len() == 1 {
                return Err(format!("源文件不存在：{item}"));
            }
            continue;
        }
        let final_target = if target_path.is_dir() {
            target_path.join(source_path.file_name().unwrap_or_default())
        } else {
            target_path.to_path_buf()
        };
        std::fs::copy(source_path, &final_target)
            .map_err(|e| format!("复制 {item} → {} 失败：{e}", final_target.display()))?;
        count += 1;
    }
    if count == 0 {
        return Err(format!("没有匹配到可复制的文件：{source}"));
    }
    shell.print_line(&format!("已复制 {count} 个文件。"))
}

fn move_file(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    let (source, target) = match args {
        [source, target] => (source, target),
        _ => return Err("用法：move 源 目标".into()),
    };
    let sources = expand_patterns(std::slice::from_ref(source));
    let target_path = Path::new(target);
    let mut count = 0usize;
    for item in &sources {
        let source_path = Path::new(item);
        if !source_path.is_file() && !source_path.is_dir() {
            if sources.len() == 1 {
                return Err(format!("源不存在：{item}"));
            }
            continue;
        }
        let final_target = if target_path.is_dir() && source_path.is_file() {
            target_path.join(source_path.file_name().unwrap_or_default())
        } else {
            target_path.to_path_buf()
        };
        if std::fs::rename(source_path, &final_target).is_err() {
            // 跨卷时 rename 会失败，退化为复制 + 删除。
            if source_path.is_file() {
                std::fs::copy(source_path, &final_target)
                    .map_err(|e| format!("移动 {item} → {} 失败：{e}", final_target.display()))?;
                std::fs::remove_file(source_path)
                    .map_err(|e| format!("已复制但无法删除 {item}：{e}"))?;
            } else {
                return Err(format!("无法移动目录 {item}"));
            }
        }
        count += 1;
    }
    if count == 0 {
        return Err(format!("没有匹配到可移动的文件：{source}"));
    }
    shell.print_line(&format!("已移动 {count} 个文件。"))
}

fn where_cmd(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        return Err("用法：where 命令...".into());
    }
    for name in args {
        let found = find_in_path(name);
        if found.is_empty() {
            return Err(format!("找不到命令：{name}"));
        }
        for path in found {
            shell.print_line(&path)?;
        }
    }
    Ok(())
}

/// `title 文本`：设置终端标题（OSC 2，客户端会同步到窗口标题）。
fn title(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    let text = args.join(" ");
    shell.write(format!("\x1b]2;{text}\x07").as_bytes())
}

/// `prompt [模板]`：查看或设置 cmd 风格的提示符（`$P$G` 等）。
fn prompt_cmd(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        let current = shell.prompt_template().to_string();
        return shell.print_line(&current);
    }
    let template = args.join(" ");
    shell.set_prompt_template(template.clone());
    let rendered = super::render_prompt(&template);
    shell.print_line(&rendered)
}

/// `vol`：显示当前驱动器的卷标、序列号与文件系统。
fn vol(shell: &mut Shell) -> Result<(), String> {
    let cwd = std::env::current_dir().map_err(|e| format!("无法获取当前目录：{e}"))?;
    let root = cwd.ancestors().last().unwrap_or(&cwd).to_path_buf();
    let mut root_text = root.display().to_string();
    if !root_text.ends_with('\\') {
        root_text.push('\\');
    }
    let wide = win32::wide(&root_text);
    let mut label = [0u16; 261];
    let mut filesystem = [0u16; 64];
    let (mut serial, mut max_component, mut flags) = (0u32, 0u32, 0u32);
    let ok = unsafe {
        win32::GetVolumeInformationW(
            wide.as_ptr(),
            label.as_mut_ptr(),
            261,
            &mut serial,
            &mut max_component,
            &mut flags,
            filesystem.as_mut_ptr(),
            64,
        )
    };
    if ok == 0 {
        return Err(format!(
            "无法读取驱动器 {root_text} 的卷信息（错误码 {}）",
            win32::last_error()
        ));
    }
    let volume = fixed_utf16(&label);
    let fs = fixed_utf16(&filesystem);
    shell.print_line(&format!(
        " 驱动器 {} 中的卷是 {}",
        root.display(),
        if volume.is_empty() { "本地磁盘" } else { &volume }
    ))?;
    shell.print_line(&format!(
        " 卷的序列号是 {:04X}-{:04X}",
        (serial >> 16) & 0xffff,
        serial & 0xffff
    ))?;
    shell.print_line(&format!(" 文件系统：{fs}"))
}

/// `date [/t]`：显示本地日期（不支持修改系统日期）。
fn date(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    if !args.is_empty() && !args[0].eq_ignore_ascii_case("/t") {
        return Err("本 shell 不支持修改系统日期；查看请用 date 或 date /t".into());
    }
    let now = local_time();
    shell.print_line(&format!(
        "{} {:04}/{:02}/{:02}",
        weekday_name(now.wDayOfWeek),
        now.wYear,
        now.wMonth,
        now.wDay
    ))
}

/// `time [/t]`：显示本地时间（不支持修改系统时间）。
fn time(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    if !args.is_empty() && !args[0].eq_ignore_ascii_case("/t") {
        return Err("本 shell 不支持修改系统时间；查看请用 time 或 time /t".into());
    }
    let now = local_time();
    shell.print_line(&format!(
        "当前时间: {:02}:{:02}:{:02}.{:02}",
        now.wHour, now.wMinute, now.wSecond, now.wMilliseconds
    ))
}

/// `chcp [代码页]`：本 shell 固定 UTF-8。
fn chcp(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    match args.first().map(|arg| arg.as_str()) {
        None => shell.print_line("活动代码页: 65001"),
        Some(code) if code == "65001" || code.eq_ignore_ascii_case("utf8") => {
            shell.print_line("活动代码页: 65001")
        }
        Some(code) => Err(format!("只支持 UTF-8（65001），无法切换到 {code}")),
    }
}

/// `pause`：等一个按键（与 cmd 一致）。
fn pause(shell: &mut Shell) -> Result<(), String> {
    shell.write("请按任意键继续. . .".as_bytes())?;
    let mut records = [win32::INPUT_RECORD::default(); 16];
    loop {
        let count = shell.read_records(&mut records)?;
        let pressed = records.iter().take(count).any(|record| {
            matches!(
                crate::input::decode_record(record),
                Some(crate::input::Record::Key(ev)) if ev.down
            )
        });
        if pressed {
            break;
        }
    }
    shell.write(b"\r\n")
}

/// `pushd [目录]`：压栈并切换目录；无参数时与栈顶交换。
fn pushd(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    let current = std::env::current_dir().map_err(|e| format!("无法获取当前目录：{e}"))?;
    let target = if args.is_empty() {
        let Some(previous) = shell.dir_stack().pop() else {
            return Err("目录栈是空的".into());
        };
        shell.dir_stack().push(current.display().to_string());
        previous
    } else {
        shell.dir_stack().push(current.display().to_string());
        args.join(" ")
    };
    cd(&[target])?;
    let cwd = std::env::current_dir()
        .map(|path| path.display().to_string())
        .unwrap_or_default();
    shell.print_line(&cwd)
}

/// `popd`：弹出栈顶并切换过去。
fn popd(shell: &mut Shell) -> Result<(), String> {
    let Some(target) = shell.dir_stack().pop() else {
        return Err("目录栈是空的".into());
    };
    cd(&[target])?;
    let cwd = std::env::current_dir()
        .map(|path| path.display().to_string())
        .unwrap_or_default();
    shell.print_line(&cwd)
}

/// `ren 原名 新名`：重命名文件或目录（与 cmd 一致，只改名、不改所在目录）。
fn rename(args: &[String]) -> Result<(), String> {
    let (source, target) = match args {
        [source, target] => (source, target),
        _ => return Err("用法：ren 原文件名 新文件名".into()),
    };
    if source.contains('*') || source.contains('?') {
        return Err("ren 不支持通配符，请逐个重命名".into());
    }
    if target.contains('\\') || target.contains('/') || target.contains(':') {
        return Err("ren 只改文件名，不支持目标路径；移动请用 move".into());
    }
    let source_path = Path::new(source);
    if !source_path.exists() {
        return Err(format!("源文件不存在：{source}"));
    }
    let parent = source_path.parent().unwrap_or_else(|| Path::new("."));
    let final_target = parent.join(target);
    std::fs::rename(source_path, &final_target)
        .map_err(|e| format!("重命名失败 {source} → {}：{e}", final_target.display()))
}

fn local_time() -> win32::SYSTEMTIME {
    let mut st = win32::SYSTEMTIME::default();
    unsafe { win32::GetLocalTime(&mut st) };
    st
}

fn weekday_name(day: u16) -> &'static str {
    match day {
        0 => "周日",
        1 => "周一",
        2 => "周二",
        3 => "周三",
        4 => "周四",
        5 => "周五",
        _ => "周六",
    }
}

fn fixed_utf16(buffer: &[u16]) -> String {
    let end = buffer.iter().position(|unit| *unit == 0).unwrap_or(buffer.len());
    String::from_utf16_lossy(&buffer[..end])
}

/// 在 PATH 中查找可执行文件（无扩展名时按 PATHEXT 依次尝试）。
pub fn find_in_path(name: &str) -> Vec<String> {
    let mut out = Vec::new();
    let Some(path_var) = std::env::var_os("PATH") else {
        return out;
    };
    let has_extension = Path::new(name).extension().is_some();
    let exts = pathext();
    for dir in std::env::split_paths(&path_var) {
        if has_extension {
            let candidate = dir.join(name);
            if candidate.is_file() {
                out.push(candidate.display().to_string());
            }
            continue;
        }
        for ext in &exts {
            let candidate = dir.join(format!("{name}{ext}"));
            if candidate.is_file() {
                out.push(candidate.display().to_string());
            }
        }
    }
    out
}

pub fn pathext() -> Vec<String> {
    let raw = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
    raw.split(';')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_ascii_lowercase())
        .collect()
}

fn alias(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        let mut names: Vec<(String, String)> = shell
            .aliases
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        names.sort_by(|a, b| a.0.cmp(&b.0));
        let mut out = String::new();
        for (name, value) in names {
            out.push_str(&format!("{name}={value}\r\n"));
        }
        return shell.write(out.as_bytes());
    }

    let joined = args.join(" ");
    match split_set_arg(&joined) {
        SetAction::Set { name, value } => {
            if name.is_empty() {
                return Err("别名不能为空".into());
            }
            shell.aliases.insert(name.to_ascii_lowercase(), value.to_string());
            Ok(())
        }
        SetAction::Remove { name } => {
            shell.aliases.remove(&name.to_ascii_lowercase());
            Ok(())
        }
        SetAction::Query { name } => match shell.aliases.get(&name.to_ascii_lowercase()) {
            Some(value) => {
                let value = value.clone();
                shell.print_line(&format!("{name}={value}"))
            }
            None => Err(format!("别名「{name}」未定义")),
        },
    }
}

fn history(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    if args.first().map(|a| a == "-c").unwrap_or(false) {
        shell.history.clear();
        return Ok(());
    }
    let mut out = String::new();
    for (index, line) in shell.history.iter().enumerate() {
        out.push_str(&format!("{:>4}  {line}\r\n", index + 1));
    }
    shell.write(out.as_bytes())
}

fn exit(shell: &mut Shell, args: &[String]) -> Result<(), String> {
    let code = match args.first() {
        Some(arg) => arg
            .parse::<i32>()
            .map_err(|_| format!("退出码不是数字：{arg}"))?,
        None => 0,
    };
    shell.exit_code = code;
    shell.running = false;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_argument_forms() {
        assert_eq!(
            split_set_arg("PATH"),
            SetAction::Query { name: "PATH" }
        );
        assert_eq!(
            split_set_arg("FOO=bar baz"),
            SetAction::Set {
                name: "FOO",
                value: "bar baz"
            }
        );
        assert_eq!(
            split_set_arg("FOO="),
            SetAction::Remove { name: "FOO" }
        );
    }

    #[test]
    fn arithmetic_expressions_follow_cmd_rules() {
        assert_eq!(eval_arithmetic("1+2*3").unwrap(), 7);
        assert_eq!(eval_arithmetic("(1+2)*3").unwrap(), 9);
        assert_eq!(eval_arithmetic("0x10 + 010").unwrap(), 24);
        assert_eq!(eval_arithmetic("1 << 4").unwrap(), 16);
        assert_eq!(eval_arithmetic("8 >> 1").unwrap(), 4);
        assert_eq!(eval_arithmetic("~0").unwrap(), -1);
        assert_eq!(eval_arithmetic("!0").unwrap(), 1);
        assert_eq!(eval_arithmetic("!7").unwrap(), 0);
        assert_eq!(eval_arithmetic("5 % 3").unwrap(), 2);
        assert_eq!(eval_arithmetic("-3 + +4").unwrap(), 1);
        assert_eq!(eval_arithmetic("1,2,3").unwrap(), 3);
        std::env::set_var("SCTERM_ARITH_VAR", "5");
        assert_eq!(eval_arithmetic("SCTERM_ARITH_VAR + 1").unwrap(), 6);
        assert_eq!(eval_arithmetic("SCTERM_ARITH_UNDEFINED + 1").unwrap(), 1);
        assert!(eval_arithmetic("1/0").is_err());
        assert!(eval_arithmetic("1+").is_err());
    }

    #[test]
    fn arithmetic_segments_split_like_cmd() {
        assert_eq!(
            split_top_level_commas("1,2,3").unwrap(),
            vec!["1".to_string(), "2".to_string(), "3".to_string()]
        );
        assert_eq!(
            split_top_level_commas("(1,2),3").unwrap(),
            vec!["(1,2)".to_string(), "3".to_string()]
        );
        assert_eq!(
            split_top_level_commas("n=1,m=n+4").unwrap(),
            vec!["n=1".to_string(), "m=n+4".to_string()]
        );
        assert_eq!(top_level_assignment("n=1").map(|i| &"n=1"[i..]), Some("=1"));
        assert_eq!(top_level_assignment("n+1"), None);
        assert_eq!(top_level_assignment("1=2"), None);
    }

    #[test]
    fn echo_dot_is_echo() {
        assert!(is_builtin("echo."));
        assert!(is_builtin("CD"));
        assert!(!is_builtin("notepad"));
    }

    #[test]
    fn cmd_aliases_are_builtin() {
        assert!(is_builtin("md"), "md 应等同于 mkdir");
        assert!(is_builtin("erase"), "erase 应等同于 del");
        assert!(is_builtin("rename"));
        assert!(is_builtin("chdir"), "chdir 应等同于 cd");
        assert!(is_builtin("pushd"));
        assert!(is_builtin("popd"));
        assert!(is_builtin("vol"));
        assert!(is_builtin("date"));
        assert!(is_builtin("time"));
        assert!(is_builtin("chcp"));
        assert!(is_builtin("pause"));
        assert!(is_builtin("title"));
        assert!(is_builtin("prompt"));
    }

    #[test]
    fn size_is_grouped() {
        assert_eq!(format_size(0), "0");
        assert_eq!(format_size(999), "999");
        assert_eq!(format_size(1234567), "1,234,567");
    }

    #[test]
    fn dir_entries_put_dirs_first() {
        let dir = std::env::temp_dir().join("scterm_builtin_dir_test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("zdir")).unwrap();
        std::fs::write(dir.join("beta.txt"), b"12").unwrap();
        std::fs::write(dir.join("alpha.txt"), b"1").unwrap();

        let entries = dir_entries(&dir).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["zdir", "alpha.txt", "beta.txt"]);
        assert!(entries[0].is_dir);
        assert_eq!(entries[2].size, 2);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn finds_cmd_on_path() {
        let found = find_in_path("cmd");
        assert!(!found.is_empty(), "PATH 中应当能找到 cmd.exe");
        assert!(found.iter().any(|p| p.to_ascii_lowercase().ends_with("cmd.exe")));
    }

    #[test]
    fn wildcard_matching() {
        assert!(wildcard_match("*.txt", "a.txt"));
        assert!(wildcard_match("a?c", "abc"));
        assert!(wildcard_match("A*.TXT", "a1.txt"));
        assert!(!wildcard_match("*.txt", "a.rs"));
        assert!(wildcard_match("*", "任何名字"));
    }

    #[test]
    fn glob_expands_in_directory() {
        let dir = std::env::temp_dir().join("scterm_glob_test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.txt"), b"1").unwrap();
        std::fs::write(dir.join("b.txt"), b"2").unwrap();
        std::fs::write(dir.join("c.rs"), b"3").unwrap();

        let pattern = format!("{}\\*.txt", dir.display());
        let found = glob(&pattern);
        assert_eq!(found.len(), 2, "{found:?}");
        assert!(found.iter().all(|p| p.ends_with(".txt")));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pads_by_display_cells() {
        assert_eq!(
            pad_cells("修改时间", 19, false),
            format!("修改时间{}", " ".repeat(11))
        );
        assert_eq!(
            pad_cells("大小", 14, true),
            format!("{}大小", " ".repeat(10))
        );
        assert_eq!(pad_cells("abcdefghij", 5, false), "abcdefghij");
    }

    #[test]
    fn rd_is_rmdir() {
        assert!(is_builtin("rd"));
    }
}

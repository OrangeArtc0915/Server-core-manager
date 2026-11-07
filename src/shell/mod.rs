//! 自研 shell（`scterm shell`）：不依赖 cmd.exe / PowerShell 的命令解释器。
//!
//! 它是真正的控制台进程，运行在窗格的 ConPTY 里，因此可以再启动 vim / python 等
//! 交互式程序；提示符下自行实现行编辑（历史、补全、Ctrl+C 取消）。
//!
//! 控制台模式切换：行编辑时用原始输入（按键事件），启动子进程前恢复初始模式，
//! 让子进程拿到正常的行缓冲与 Ctrl+C 信号；子进程退出后再切回原始输入。

mod builtins;
mod complete;
mod exec;
mod lineedit;
mod parse;
mod script;

use std::collections::BTreeMap;
use std::ffi::c_void;
use std::fs::File;
use std::io::Write;

use crate::platform::console;
use crate::platform::win32::{self, HANDLE};

/// 内置命令的输出去向：控制台、被重定向到文件，或缓存起来喂给管道。
pub enum Output {
    Console(HANDLE),
    File(File),
    Buffer(Vec<u8>),
}

impl Output {
    fn write_all(&mut self, data: &[u8]) -> Result<(), String> {
        match self {
            Output::Console(handle) => write_console(*handle, data),
            Output::File(file) => file
                .write_all(data)
                .map_err(|e| format!("写入重定向文件失败：{e}")),
            Output::Buffer(buffer) => {
                buffer.extend_from_slice(data);
                Ok(())
            }
        }
    }
}

pub struct Shell {
    stdin: HANDLE,
    stdout: HANDLE,
    saved_in: u32,
    saved_out: u32,
    raw: bool,
    history: Vec<String>,
    aliases: BTreeMap<String, String>,
    /// cmd 风格的提示符模板，默认 `$P$G`。
    prompt_template: String,
    /// pushd/popd 的目录栈。
    dir_stack: Vec<String>,
    running: bool,
    exit_code: i32,
    /// 正在执行 `.sct` 脚本。cmd 在批处理里执行 `set /a` 不打印结果，
    /// 命令行里则总是打印；脚本沿用批处理语义。
    pub in_script: bool,
    out: Output,
}

impl Shell {
    /// 进入 shell：接管控制台并切到原始输入模式。
    pub fn enter() -> Result<Shell, String> {
        unsafe {
            let stdin = win32::GetStdHandle(win32::STD_INPUT_HANDLE);
            let stdout = win32::GetStdHandle(win32::STD_OUTPUT_HANDLE);
            if stdin.is_null() || stdin == win32::INVALID_HANDLE_VALUE {
                return Err("无法获取标准输入句柄，scterm shell 需要在控制台中运行".into());
            }
            if stdout.is_null() || stdout == win32::INVALID_HANDLE_VALUE {
                return Err("无法获取标准输出句柄，scterm shell 需要在控制台中运行".into());
            }

            let mut saved_in = 0u32;
            if win32::GetConsoleMode(stdin, &mut saved_in) == 0 {
                return Err(format!(
                    "无法读取控制台模式（错误码 {}），scterm shell 需要在真实控制台中运行",
                    win32::last_error()
                ));
            }
            let mut saved_out = 0u32;
            win32::GetConsoleMode(stdout, &mut saved_out);

            // 输出始终开启 VT 处理：行编辑与内置命令都靠转义序列定位光标。
            win32::SetConsoleCP(65001);
            win32::SetConsoleOutputCP(65001);
            let out_mode =
                saved_out | win32::ENABLE_PROCESSED_OUTPUT | win32::ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            if win32::SetConsoleMode(stdout, out_mode) == 0 {
                return Err(format!(
                    "当前控制台不支持虚拟终端输出（错误码 {}），需要 Windows 10 及以上",
                    win32::last_error()
                ));
            }

            let mut shell = Shell {
                stdin,
                stdout,
                saved_in,
                saved_out,
                raw: false,
                history: Vec::new(),
                aliases: BTreeMap::new(),
                prompt_template: "$P$G".to_string(),
                dir_stack: Vec::new(),
                running: true,
                exit_code: 0,
                in_script: false,
                out: Output::Console(stdout),
            };
            shell.set_raw(true)?;
            Ok(shell)
        }
    }

    /// 切换标准输入的原始 / 初始模式。
    pub fn set_raw(&mut self, raw: bool) -> Result<(), String> {
        if self.raw == raw {
            return Ok(());
        }
        let mode = if raw {
            win32::ENABLE_EXTENDED_FLAGS | win32::ENABLE_WINDOW_INPUT
        } else {
            self.saved_in
        };
        unsafe {
            if win32::SetConsoleMode(self.stdin, mode) == 0 {
                return Err(format!(
                    "设置控制台输入模式失败（错误码 {}）",
                    win32::last_error()
                ));
            }
            if raw {
                // 子进程可能改过代码页，回到行编辑前统一恢复 UTF-8。
                win32::SetConsoleCP(65001);
                win32::SetConsoleOutputCP(65001);
            }
        }
        self.raw = raw;
        Ok(())
    }

    pub fn write(&mut self, data: &[u8]) -> Result<(), String> {
        self.out.write_all(data)
    }

    /// 输出一行（自动补 `\r\n`，否则 LF 只会下移不回车）。
    pub fn print_line(&mut self, text: &str) -> Result<(), String> {
        self.write(text.as_bytes())?;
        self.write(b"\r\n")
    }

    pub fn cols(&self) -> usize {
        console::console_size(self.stdout).0.max(1) as usize
    }

    pub fn rows(&self) -> usize {
        console::console_size(self.stdout).1.max(1) as usize
    }

    pub fn read_records(&mut self, buf: &mut [win32::INPUT_RECORD]) -> Result<usize, String> {
        let mut n = 0u32;
        let ok = unsafe {
            win32::ReadConsoleInputW(self.stdin, buf.as_mut_ptr(), buf.len() as u32, &mut n)
        };
        if ok == 0 {
            return Err(format!(
                "读取控制台输入失败（错误码 {}）",
                win32::last_error()
            ));
        }
        Ok(n as usize)
    }

    pub fn reset_output(&mut self) {
        self.out = Output::Console(self.stdout);
    }

    /// 让内置命令输出进内存（管道首段），随后用 `take_output` 取走。
    pub fn capture_output(&mut self) {
        self.out = Output::Buffer(Vec::new());
    }

    pub fn take_output(&mut self) -> Option<Vec<u8>> {
        let previous = std::mem::replace(&mut self.out, Output::Console(self.stdout));
        match previous {
            Output::Buffer(buffer) => Some(buffer),
            _ => None,
        }
    }

    pub fn redirect_output(&mut self, path: &str, append: bool) -> Result<(), String> {
        let file = open_output_file(path, append)?;
        self.out = Output::File(file);
        Ok(())
    }

    /// 按 cmd 的 `prompt` 模板生成提示符（`$P$G` 等）。
    pub fn prompt(&self) -> String {
        render_prompt(&self.prompt_template)
    }

    pub fn prompt_template(&self) -> &str {
        &self.prompt_template
    }

    pub fn set_prompt_template(&mut self, template: String) {
        self.prompt_template = template;
    }

    pub fn dir_stack(&mut self) -> &mut Vec<String> {
        &mut self.dir_stack
    }

    pub fn history(&self) -> &[String] {
        &self.history
    }

    pub fn record_history(&mut self, line: &str) {
        if line.trim().is_empty() {
            return;
        }
        if self.history.last().map(|h| h != line).unwrap_or(true) {
            self.history.push(line.to_string());
        }
    }

    pub fn aliases(&self) -> &BTreeMap<String, String> {
        &self.aliases
    }
}

impl Drop for Shell {
    fn drop(&mut self) {
        unsafe {
            win32::SetConsoleMode(self.stdin, self.saved_in);
            win32::SetConsoleMode(self.stdout, self.saved_out);
        }
    }
}

/// 渲染 cmd 风格的 `prompt` 模板：`$P` 当前路径、`$G` `>`、`$L` `<`、`$B` `|`、
/// `$D` 日期、`$T` 时间、`$_` 换行、`$$` 字面 `$`；其它 `$x` 原样保留。
pub fn render_prompt(template: &str) -> String {
    let cwd = std::env::current_dir()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "?".to_string());
    let (date, time) = current_date_time();
    let mut out = String::new();
    let mut chars = template.chars();
    while let Some(ch) = chars.next() {
        if ch != '$' {
            out.push(ch);
            continue;
        }
        match chars.next() {
            Some('P') => out.push_str(&cwd),
            Some('G') => out.push('>'),
            Some('L') => out.push('<'),
            Some('B') => out.push('|'),
            Some('D') => out.push_str(&date),
            Some('T') => out.push_str(&time),
            Some('_') => out.push_str("\r\n"),
            Some('$') => out.push('$'),
            Some(other) => {
                out.push('$');
                out.push(other);
            }
            None => out.push('$'),
        }
    }
    out
}

fn current_date_time() -> (String, String) {
    let mut st = win32::SYSTEMTIME::default();
    unsafe { win32::GetLocalTime(&mut st) };
    (
        format!("{:04}/{:02}/{:02}", st.wYear, st.wMonth, st.wDay),
        format!(
            "{:02}:{:02}:{:02}.{:02}",
            st.wHour, st.wMinute, st.wSecond, st.wMilliseconds
        ),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_template_codes() {
        let cwd = std::env::current_dir()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|_| "?".to_string());
        assert_eq!(render_prompt("$P$G"), format!("{cwd}>"));
        assert_eq!(render_prompt("[$P]$$"), format!("[{cwd}]$"));
        assert_eq!(render_prompt("$L$B"), "<|");
        // 未知的 $x 原样保留
        assert_eq!(render_prompt("100$"), "100$");
        assert_eq!(render_prompt("$Z"), "$Z");
        // 多行提示符
        assert_eq!(render_prompt("a$_b"), "a\r\nb");
        let rendered = render_prompt("$D $T");
        assert!(rendered.contains('/') && rendered.contains(':'), "{rendered}");
    }
}

pub fn open_output_file(path: &str, append: bool) -> Result<File, String> {
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true);
    if append {
        options.append(true);
    } else {
        options.truncate(true);
    }
    options
        .open(path)
        .map_err(|e| format!("无法写入文件 {path}：{e}"))
}

fn write_console(handle: HANDLE, mut data: &[u8]) -> Result<(), String> {
    while !data.is_empty() {
        let mut written = 0u32;
        let ok = unsafe {
            win32::WriteFile(
                handle,
                data.as_ptr() as *const c_void,
                data.len() as u32,
                &mut written,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            return Err(format!("写入控制台失败（错误码 {}）", win32::last_error()));
        }
        if written == 0 {
            return Err("写入控制台返回 0 字节".into());
        }
        data = &data[written as usize..];
    }
    Ok(())
}

unsafe extern "system" fn ignore_ctrl_event(_ctrl_type: u32) -> i32 {
    // 返回 TRUE 表示已处理：shell 自身不因 Ctrl+C 退出，子进程仍会收到该事件。
    1
}

/// 入口：`scterm shell`。返回 shell 的退出码（`exit N`）。
pub fn run() -> Result<i32, String> {
    unsafe {
        win32::SetConsoleCtrlHandler(Some(ignore_ctrl_event), 1);
    }
    let mut shell = Shell::enter()?;
    shell.print_line(&format!(
        "scterm shell {} —— 自研命令解释器，输入 help 查看内置命令",
        env!("CARGO_PKG_VERSION")
    ))?;

    while shell.running {
        shell.set_raw(true)?;
        let prompt = shell.prompt();
        let line = lineedit::read_line(&mut shell, &prompt)?;
        shell.set_raw(false)?;
        let Some(line) = line else {
            continue;
        };
        if line.trim().is_empty() {
            continue;
        }
        shell.record_history(&line);
        crate::platform::logging::info(&format!("执行：{line}"));
        // OSC 133：C = 命令开始，D = 命令结束（带退出码）。
        let _ = shell.write(b"\x1b]133;C\x07");
        let result = exec::run_line(&mut shell, &line);
        let code = std::env::var("ERRORLEVEL")
            .ok()
            .and_then(|value| value.parse::<i32>().ok())
            .unwrap_or(0);
        let _ = shell.write(format!("\x1b]133;D;{code}\x07").as_bytes());
        if let Err(e) = result {
            let _ = shell.print_line(&format!("scterm: {e}"));
        }
    }

    shell.reset_output();
    crate::platform::logging::info(&format!(
        "shell 主循环结束，退出码 {}",
        shell.exit_code
    ));
    Ok(shell.exit_code)
}

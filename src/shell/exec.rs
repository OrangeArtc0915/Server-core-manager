//! 命令执行：别名展开、内置命令分发、外部程序启动、管道与重定向。
//!
//! 外部程序用 `std::process::Command` 启动：它与 shell 共享控制台，
//! 因此 vim / python 等交互式程序在行编辑结束后能正常接管键盘。

use std::collections::BTreeMap;
use std::fs::File;
use std::process::{Child, ChildStdout, Command as ProcessCommand, Stdio};
use std::thread;

use super::builtins;
use super::parse::{self, Command, RedirectKind};
use super::Shell;

pub fn run_line(shell: &mut Shell, line: &str) -> Result<(), String> {
    let mut commands = parse::parse_line(line)?;
    if commands.is_empty() {
        return Ok(());
    }
    let aliases = shell.aliases().clone();
    expand_alias(&mut commands[0], &aliases);

    if commands.len() == 1 {
        run_single(shell, &commands[0])
    } else {
        run_pipeline(shell, &commands)
    }
}

fn expand_alias(command: &mut Command, aliases: &BTreeMap<String, String>) {
    for _ in 0..8 {
        let Some(name) = command.words.first() else {
            break;
        };
        let Some(value) = aliases.get(&name.to_ascii_lowercase()) else {
            break;
        };
        let Ok(mut parsed) = parse::parse_line(value) else {
            break;
        };
        if parsed.len() != 1 {
            break;
        }
        let mut replacement = parsed.remove(0);
        replacement
            .words
            .extend(command.words.iter().skip(1).cloned());
        replacement
            .redirects
            .extend(command.redirects.iter().cloned());
        *command = replacement;
    }
}

fn run_single(shell: &mut Shell, command: &Command) -> Result<(), String> {
    let Some(name) = command.words.first() else {
        return Err("空命令".into());
    };
    if !builtins::is_builtin(name) {
        return run_external(std::slice::from_ref(command), None);
    }
    if command.redirect(RedirectKind::Stdin).is_some() {
        return Err("内置命令不支持输入重定向（<）".into());
    }

    let redirect = command.stdout_target();
    if let Some(redirect) = redirect {
        shell.redirect_output(
            &redirect.target,
            redirect.kind == RedirectKind::StdoutAppend,
        )?;
    }
    let result = builtins::run(shell, name, &command.words[1..]);
    shell.reset_output();
    result
}

fn run_pipeline(shell: &mut Shell, commands: &[Command]) -> Result<(), String> {
    // 管道首段允许内置命令：先执行并把输出缓存起来，再作为下一段的 stdin。
    let mut buffered: Option<Vec<u8>> = None;
    let mut start = 0usize;
    if let Some(name) = commands[0].words.first() {
        if builtins::is_builtin(name) {
            if commands[0].redirect(RedirectKind::Stdin).is_some() {
                return Err("内置命令不支持输入重定向（<）".into());
            }
            shell.capture_output();
            let result = builtins::run(shell, name, &commands[0].words[1..]);
            buffered = shell.take_output();
            result?;
            start = 1;
        }
    }

    for command in &commands[start..] {
        if let Some(name) = command.words.first() {
            if builtins::is_builtin(name) {
                return Err(format!(
                    "管道中只有第一段可以是内置命令，「{name}」请改用外部程序"
                ));
            }
        }
    }
    if start == commands.len() {
        return Ok(());
    }
    run_external(&commands[start..], buffered)
}

fn run_external(commands: &[Command], stdin_data: Option<Vec<u8>>) -> Result<(), String> {
    let mut children: Vec<Child> = Vec::new();
    if let Err(e) = spawn_all(&mut children, commands, stdin_data) {
        for mut child in children.drain(..) {
            let _ = child.kill();
            let _ = child.wait();
        }
        return Err(e);
    }

    let mut last_code = 0;
    for child in &mut children {
        match child.wait() {
            Ok(status) => last_code = status.code().unwrap_or(-1),
            Err(e) => return Err(format!("等待子进程失败：{e}")),
        }
    }
    std::env::set_var("ERRORLEVEL", last_code.to_string());
    // 子进程运行期间键入的按键保留在控制台队列里，回到行编辑后作为「下一行」输入。
    Ok(())
}

fn spawn_all(
    children: &mut Vec<Child>,
    commands: &[Command],
    stdin_data: Option<Vec<u8>>,
) -> Result<(), String> {
    let mut previous_stdout: Option<ChildStdout> = None;
    let mut pending_stdin = stdin_data;
    let total = commands.len();

    for (index, command) in commands.iter().enumerate() {
        let program = command
            .words
            .first()
            .ok_or_else(|| "管道中存在空命令".to_string())?;
        let mut process = ProcessCommand::new(program);
        process.args(&command.words[1..]);

        if let Some(pipe) = previous_stdout.take() {
            process.stdin(Stdio::from(pipe));
        } else if pending_stdin.is_some() {
            process.stdin(Stdio::piped());
        } else if let Some(redirect) = command.redirect(RedirectKind::Stdin) {
            let file = File::open(&redirect.target)
                .map_err(|e| format!("无法打开输入文件 {}：{e}", redirect.target))?;
            process.stdin(Stdio::from(file));
        } else {
            process.stdin(Stdio::inherit());
        }

        let is_last = index + 1 == total;
        if !is_last {
            process.stdout(Stdio::piped());
        } else if let Some(redirect) = command.stdout_target() {
            process.stdout(Stdio::from(super::open_output_file(
                &redirect.target,
                redirect.kind == RedirectKind::StdoutAppend,
            )?));
        } else {
            process.stdout(Stdio::inherit());
        }

        if let Some(redirect) = command.stderr_target() {
            process.stderr(Stdio::from(super::open_output_file(
                &redirect.target,
                redirect.kind == RedirectKind::StderrAppend,
            )?));
        } else {
            process.stderr(Stdio::inherit());
        }

        let mut child = process
            .spawn()
            .map_err(|e| spawn_error(program, e))?;
        if !is_last {
            previous_stdout = child.stdout.take();
        }
        if let Some(data) = pending_stdin.take() {
            if let Some(mut sink) = child.stdin.take() {
                // 内置命令的缓冲可能很大，必须异步写入，避免子进程阻塞时死锁。
                thread::spawn(move || {
                    use std::io::Write;
                    let _ = sink.write_all(&data);
                });
            }
        }
        children.push(child);
    }
    Ok(())
}

fn spawn_error(program: &str, error: std::io::Error) -> String {
    let lower = program.to_ascii_lowercase();
    if lower.ends_with(".bat") || lower.ends_with(".cmd") {
        return format!(
            "「{program}」是批处理文件，需要 cmd.exe 才能执行；请直接运行其中的 .exe"
        );
    }
    format!("无法启动「{program}」：{error}")
}

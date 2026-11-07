//! scterm：Windows Server Core 终端多路复用工具。

mod action;
mod config;
#[cfg(test)]
mod e2e;
mod emulation;
mod input;
mod integration;
mod ipc;
mod platform;
mod proto;
mod render;
mod session;
mod shell;
mod term;
mod ui;

use std::process::ExitCode;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn usage() {
    println!("scterm {VERSION} —— Windows Server Core 终端多路复用工具\n");
    println!("用法：");
    println!("  scterm                       启动客户端（必要时自动拉起后台服务）");
    println!("  scterm server                前台运行后台服务");
    println!("  scterm server --detached     由客户端自动调用，后台常驻");
    println!("  scterm shell                 自研命令解释器（默认 profile，由客户端启动）");
    println!("  scterm reload                校验并打印当前配置");
    println!("  scterm actions               列出全部动作与绑定快捷键");
    println!("  scterm --layout <名称/表达式>  按布局模板打开多窗格标签页");
    println!("  scterm --quake               Quake 模式启动（窗口隐藏，热键呼出）");
    println!("  scterm --version             显示版本");
    println!("  scterm --help                显示本帮助\n");
    println!("可选参数：");
    println!("  --verbose                    输出 debug 级日志");
    println!("  --layout <值>                先用 [layouts] 按名称查找，再按表达式解析");
    println!("  --quake                      注册 [quake] 热键并隐藏启动窗口");
    println!("\n配置文件：{}", config::Config::path().display());
    println!("日志目录：{}", platform::logging::log_dir().display());
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Command {
    Server,
    Shell,
    Reload,
    Actions,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct Cli {
    verbose: bool,
    detached: bool,
    command: Option<Command>,
    layout: Option<String>,
    quake: bool,
}

fn parse_cli(args: &[String]) -> Result<Cli, String> {
    let mut cli = Cli::default();
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].as_str();
        let command = match arg {
            "server" => Some(Command::Server),
            "shell" => Some(Command::Shell),
            "reload" => Some(Command::Reload),
            "actions" => Some(Command::Actions),
            _ => None,
        };
        if let Some(command) = command {
            if cli.command.is_some() {
                return Err("一次只能指定一个命令".to_string());
            }
            cli.command = Some(command);
            index += 1;
            continue;
        }
        match arg {
            "--verbose" => cli.verbose = true,
            "--detached" => cli.detached = true,
            "--quake" => cli.quake = true,
            "--layout" => {
                if cli.layout.is_some() {
                    return Err("--layout 只能指定一次".to_string());
                }
                index += 1;
                let Some(value) = args.get(index) else {
                    return Err("--layout 需要布局名或布局表达式".to_string());
                };
                if value.trim().is_empty() || value.starts_with('-') {
                    return Err("--layout 需要布局名或布局表达式".to_string());
                }
                cli.layout = Some(value.trim().to_string());
            }
            other if other.starts_with("--layout=") => {
                if cli.layout.is_some() {
                    return Err("--layout 只能指定一次".to_string());
                }
                let value = other.trim_start_matches("--layout=").trim();
                if value.is_empty() {
                    return Err("--layout 需要布局名或布局表达式".to_string());
                }
                cli.layout = Some(value.to_string());
            }
            other if other.starts_with('-') => {
                return Err(format!("未知选项 {other}"));
            }
            other => return Err(format!("未知命令 {other}")),
        }
        index += 1;
    }

    if cli.command.is_some() && (cli.layout.is_some() || cli.quake) {
        return Err("--layout / --quake 只能用于启动客户端".to_string());
    }
    if cli.detached && cli.command != Some(Command::Server) {
        return Err("--detached 只能与 server 命令一起使用".to_string());
    }
    Ok(cli)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.iter().any(|a| a == "--help" || a == "-h") {
        usage();
        return ExitCode::SUCCESS;
    }
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("scterm {VERSION}");
        return ExitCode::SUCCESS;
    }

    let cli = match parse_cli(&args) {
        Ok(cli) => cli,
        Err(e) => {
            eprintln!("scterm: {e}，使用 --help 查看用法");
            return ExitCode::FAILURE;
        }
    };
    platform::logging::init(cli.verbose);

    match cli.command {
        Some(Command::Reload) => return report_config(),
        Some(Command::Actions) => return report_actions(),
        Some(Command::Shell) => {
            let result = shell::run();
            platform::logging::info("shell 进程即将退出");
            return match result {
                Ok(code) => ExitCode::from(code as u8),
                Err(e) => {
                    platform::logging::error(&e);
                    eprintln!("scterm: {e}");
                    ExitCode::FAILURE
                }
            };
        }
        Some(Command::Server) => {
            let result = ipc::server::run();
            return finish(result);
        }
        None => {}
    }

    finish(ipc::client::run(ipc::client::Options {
        layout: cli.layout,
        quake: cli.quake,
    }))
}

fn finish(result: Result<(), String>) -> ExitCode {
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            platform::logging::error(&e);
            eprintln!("scterm: {e}");
            ExitCode::FAILURE
        }
    }
}

fn report_config() -> ExitCode {
    let path = config::Config::path();
    let config = config::Config::load();
    println!("配置文件：{}", path.display());
    println!("默认 profile：{}", config.default_profile);
    println!("回看行数：{}", config.scrollback);
    println!(
        "渲染：鼠标={}，真彩色={:?}",
        config.render.mouse, config.render.truecolor
    );
    println!(
        "会话恢复：{}",
        if config.behavior.restore_session {
            "开启"
        } else {
            "关闭"
        }
    );
    println!(
        "Quake：{}，热键 {}，呼出置顶={}",
        if config.quake.enabled { "开启" } else { "关闭" },
        config.quake.hotkey,
        config.quake.topmost
    );
    println!("布局：{} 个", config.layouts.len());
    let mut problems = config.warnings.len();
    for (name, spec) in &config.layouts {
        match ui::layout::LayoutNode::parse(spec) {
            Ok(node) => {
                println!("  - {name} → {spec}（{} 个窗格）", node.profiles().len());
                for profile in node.profiles() {
                    if config.profile(profile).is_none() {
                        println!("    ! 布局引用了不存在的 profile「{profile}」");
                        problems += 1;
                    }
                }
            }
            Err(e) => {
                println!("  ! {name} → {e}");
                problems += 1;
            }
        }
    }
    println!("profiles：{} 个", config.profiles.len());
    for profile in &config.profiles {
        println!("  - {} → {}", profile.name, profile.command_line());
    }
    println!("配色方案：{} 个", config.color_schemes.len());
    for scheme in &config.color_schemes {
        println!("  - {}", scheme.name);
    }
    for note in &config.notes {
        println!("提示：{note}");
    }

    if problems == 0 {
        println!("校验结果：通过（客户端会自动检测文件变化并重载）");
        ExitCode::SUCCESS
    } else {
        println!("校验结果：{problems} 个问题");
        for warning in &config.warnings {
            println!("  ! {warning}");
        }
        ExitCode::FAILURE
    }
}

fn report_actions() -> ExitCode {
    let config = config::Config::load();
    let (registry, warnings) = action::Registry::from_config(&config.action_bindings);
    println!("{:<30} {:<20} {}", "command", "快捷键", "说明");
    for action in action::Action::all() {
        let keys = registry.keys_for(action).unwrap_or_default();
        println!("{:<30} {:<20} {}", action.id(), keys, action.name());
    }
    for warning in warnings {
        println!("! {warning}");
    }
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn parses_client_options_and_legacy_commands() {
        let cli = parse_cli(&args(&["--layout", "dev", "--quake"])).unwrap();
        assert_eq!(cli.command, None);
        assert_eq!(cli.layout.as_deref(), Some("dev"));
        assert!(cli.quake);

        let cli = parse_cli(&args(&["--layout=h30(pwsh,cmd)"])).unwrap();
        assert_eq!(cli.layout.as_deref(), Some("h30(pwsh,cmd)"));

        let cli = parse_cli(&args(&["server", "--detached", "--verbose"])).unwrap();
        assert_eq!(cli.command, Some(Command::Server));
        assert!(cli.detached);
        assert!(cli.verbose);

        assert_eq!(
            parse_cli(&args(&["reload"])).unwrap().command,
            Some(Command::Reload)
        );
        assert_eq!(
            parse_cli(&args(&["actions"])).unwrap().command,
            Some(Command::Actions)
        );
    }

    #[test]
    fn rejects_invalid_cli_combinations() {
        assert!(parse_cli(&args(&["--layout"])).is_err(), "缺少布局值");
        assert!(
            parse_cli(&args(&["--layout", "--quake"])).is_err(),
            "布局值不能是另一个选项"
        );
        assert!(
            parse_cli(&args(&["server", "--layout", "dev"])).is_err(),
            "布局只能启动客户端"
        );
        assert!(
            parse_cli(&args(&["reload", "--quake"])).is_err(),
            "Quake 只能启动客户端"
        );
        assert!(
            parse_cli(&args(&["--detached"])).is_err(),
            "--detached 只能配合 server"
        );
        assert!(parse_cli(&args(&["server", "reload"])).is_err());
        assert!(parse_cli(&args(&["unknown"])).is_err());
        assert!(parse_cli(&args(&["--nope"])).is_err());
    }
}

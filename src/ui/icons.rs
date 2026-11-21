//! 图标：优先 Nerd Font，缺失时回退 Unicode / ASCII，避免 Server Core 乱码。

use std::sync::OnceLock;

use crate::config::Config;

#[derive(Clone, Copy)]
pub struct Icons {
    pub explorer: char,
    pub search: char,
    pub git: char,
    pub chevron_open: char,
    pub chevron_closed: char,
    pub file: char,
    pub folder: char,
    pub folder_open: char,
    pub dirty: char,
}

fn unicode() -> Icons {
    Icons {
        explorer: '▤',
        search: '⌕',
        git: '⎇',
        chevron_open: '▾',
        chevron_closed: '▸',
        file: '·',
        folder: '▸',
        folder_open: '▾',
        dirty: '●',
    }
}

fn nerd() -> Icons {
    Icons {
        explorer: '\u{f0c5}',
        search: '\u{f002}',
        git: '\u{f1d3}',
        chevron_open: '\u{f078}',
        chevron_closed: '\u{f054}',
        file: '\u{f15b}',
        folder: '\u{f07b}',
        folder_open: '\u{f07c}',
        dirty: '\u{f111}',
    }
}

fn ascii() -> Icons {
    Icons {
        explorer: 'E',
        search: 'S',
        git: 'G',
        chevron_open: 'v',
        chevron_closed: '>',
        file: '-',
        folder: '+',
        folder_open: 'v',
        dirty: '*',
    }
}

pub fn for_config(config: &Config) -> Icons {
    let setting = config.nerd_font.to_ascii_lowercase();
    let nerd_enabled = match setting.as_str() {
        "on" | "true" | "1" | "yes" => true,
        "off" | "false" | "0" | "no" => false,
        _ => nerd_installed(),
    };
    if nerd_enabled {
        nerd()
    } else if config.icons {
        unicode()
    } else {
        ascii()
    }
}

/// 检测系统是否安装了名字里带 Nerd 的字体（用户目录 + 系统字体目录）。
pub fn nerd_installed() -> bool {
    static CACHED: OnceLock<bool> = OnceLock::new();
    *CACHED.get_or_init(|| {
        // 仅当终端环境与字体同时满足时才启用 Nerd Font，避免 conhost / 无字体时乱码。
        let modern_terminal = std::env::var("WT_SESSION").is_ok()
            || std::env::var("TERM_PROGRAM").is_ok()
            || std::env::var("ConEmuPID").is_ok()
            || std::env::var("ALACRITTY_LOG").is_ok()
            || std::env::var("WEZTERM_PANE").is_ok();
        if !modern_terminal {
            return false;
        }
        if std::env::var("TEXTM_NERD_FONT").is_ok() {
            return true;
        }
        let mut dirs = Vec::new();
        if let Ok(windir) = std::env::var("WINDIR") {
            dirs.push(std::path::PathBuf::from(windir).join("Fonts"));
        }
        if let Ok(local) = std::env::var("LOCALAPPDATA") {
            dirs.push(
                std::path::PathBuf::from(local)
                    .join("Microsoft")
                    .join("Windows")
                    .join("Fonts"),
            );
        }
        for dir in dirs {
            let Ok(entries) = std::fs::read_dir(dir) else {
                continue;
            };
            for entry in entries.flatten().take(4000) {
                let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
                if name.contains("nerd") {
                    return true;
                }
            }
        }
        false
    })
}

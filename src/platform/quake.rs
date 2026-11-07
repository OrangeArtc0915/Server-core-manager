//! Quake 下拉热键：注册全局热键，隐藏/显示当前控制台窗口。
//!
//! 热键在专用线程里注册并跑消息循环；主 TUI 循环不受影响。窗口句柄来自
//! `GetConsoleWindow`，因此只在 conhost 窗口下有效（Windows Terminal 宿主
//! 返回的是隐藏消息窗口，只会注册热键但看不到显隐效果）。

use std::ptr::null_mut;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use crate::platform::win32;

const HOTKEY_ID: i32 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hotkey {
    pub mods: u32,
    pub vk: u32,
    pub label: String,
}

/// 解析 `win+\``、`ctrl+alt+space` 这类热键写法。
pub fn parse(text: &str) -> Result<Hotkey, String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("Quake 热键为空".to_string());
    }
    let mut mods = 0u32;
    let mut key: Option<u32> = None;
    let tokens: Vec<&str> = text
        .split('+')
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .collect();
    for token in &tokens {
        if key.is_some() {
            return Err(format!("热键「{token}」应放在修饰键之前"));
        }
        let lower = token.to_ascii_lowercase();
        match lower.as_str() {
            "win" | "meta" | "super" => mods |= win32::MOD_WIN,
            "ctrl" | "control" => mods |= win32::MOD_CONTROL,
            "alt" => mods |= win32::MOD_ALT,
            "shift" => mods |= win32::MOD_SHIFT,
            _ => key = Some(virtual_key(token)?),
        }
    }
    let Some(vk) = key else {
        return Err("热键缺少主键（例如 win+` 里的反引号）".to_string());
    };
    if mods == 0 {
        return Err("全局热键至少需要一个修饰键（win/ctrl/alt/shift）".to_string());
    }
    Ok(Hotkey {
        mods: mods | win32::MOD_NOREPEAT,
        vk,
        label: text.to_string(),
    })
}

fn virtual_key(token: &str) -> Result<u32, String> {
    let lower = token.to_ascii_lowercase();
    if lower.chars().count() == 1 {
        let ch = lower.chars().next().unwrap();
        if ch.is_ascii_alphabetic() {
            return Ok(ch.to_ascii_uppercase() as u32);
        }
        if ch.is_ascii_digit() {
            return Ok(ch as u32);
        }
    }
    let vk = match lower.as_str() {
        "space" => 0x20,
        "tab" => 0x09,
        "enter" | "return" => 0x0D,
        "esc" | "escape" => 0x1B,
        "`" | "backtick" | "grave" => 0xC0,
        "-" | "minus" => 0xBD,
        "=" | "plus" => 0xBB,
        "," | "comma" => 0xBC,
        "." | "period" => 0xBE,
        "/" | "slash" => 0xBF,
        "\\" | "backslash" => 0xDC,
        other => {
            let rest = other.strip_prefix('f').unwrap_or("");
            if let Ok(num) = rest.parse::<u32>() {
                if (1..=24).contains(&num) {
                    0x70 + num - 1
                } else {
                    return Err(format!("功能键「{token}」超出 F1–F24"));
                }
            } else {
                return Err(format!("不支持的热键主键「{token}」"));
            }
        }
    };
    Ok(vk)
}

/// 注册全局热键并启动消息循环；注册结果同步返回，失败时调用方只告警。
pub fn start(hotkey: &str, topmost: bool) -> Result<(), String> {
    let parsed = parse(hotkey)?;
    let label = parsed.label.clone();
    let (tx, rx) = mpsc::channel::<Result<(), String>>();
    thread::spawn(move || {
        let ok = unsafe {
            win32::RegisterHotKey(null_mut(), HOTKEY_ID, parsed.mods, parsed.vk)
        };
        if ok == 0 {
            let _ = tx.send(Err(format!(
                "注册全局热键「{label}」失败（错误码 {}），可能已被其他程序占用",
                win32::last_error()
            )));
            return;
        }
        let _ = tx.send(Ok(()));
        loop {
            let mut msg = win32::MSG::default();
            let result = unsafe { win32::GetMessageW(&mut msg, null_mut(), 0, 0) };
            if result <= 0 {
                break;
            }
            if msg.message == win32::WM_HOTKEY {
                toggle(topmost);
            }
        }
    });
    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(result) => result,
        Err(_) => Err("注册全局热键超时".to_string()),
    }
}

/// 隐藏控制台窗口（`--quake` 启动时调用）。
pub fn hide_console() {
    let hwnd = console_window();
    if !hwnd.is_null() {
        unsafe {
            win32::ShowWindow(hwnd, win32::SW_HIDE);
        }
    }
}

fn toggle(topmost: bool) {
    let hwnd = console_window();
    if hwnd.is_null() {
        return;
    }
    let visible = unsafe { win32::IsWindowVisible(hwnd) } != 0;
    let minimized = unsafe { win32::IsIconic(hwnd) } != 0;
    if visible && !minimized {
        hide_console();
        return;
    }
    let cmd = if minimized {
        win32::SW_RESTORE
    } else {
        win32::SW_SHOW
    };
    unsafe {
        win32::ShowWindow(hwnd, cmd);
        win32::BringWindowToTop(hwnd);
        win32::SetForegroundWindow(hwnd);
        if topmost {
            win32::SetWindowPos(
                hwnd,
                win32::HWND_TOPMOST,
                0,
                0,
                0,
                0,
                win32::SWP_NOMOVE | win32::SWP_NOSIZE | win32::SWP_SHOWWINDOW,
            );
        }
    }
}

fn console_window() -> win32::HANDLE {
    unsafe { win32::GetConsoleWindow() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_hotkeys() {
        let key = parse("win+`").unwrap();
        assert_eq!(key.mods & win32::MOD_WIN, win32::MOD_WIN);
        assert_eq!(key.mods & win32::MOD_NOREPEAT, win32::MOD_NOREPEAT);
        assert_eq!(key.vk, 0xC0);

        let key = parse("Ctrl + Alt + Space").unwrap();
        assert_eq!(
            key.mods & (win32::MOD_CONTROL | win32::MOD_ALT),
            win32::MOD_CONTROL | win32::MOD_ALT
        );
        assert_eq!(key.vk, 0x20);

        assert_eq!(parse("alt+f12").unwrap().vk, 0x7B);
        assert_eq!(parse("shift+9").unwrap().vk, 0x39);
        assert_eq!(parse("win+backtick").unwrap().vk, 0xC0);
    }

    #[test]
    fn rejects_bad_hotkeys() {
        assert!(parse("").is_err());
        assert!(parse("a").is_err(), "没有修饰键");
        assert!(parse("ctrl").is_err(), "没有主键");
        assert!(parse("ctrl+f25").is_err(), "功能键越界");
        assert!(parse("ctrl+nosuchkey").is_err(), "未知键");
        assert!(parse("a+ctrl").is_err(), "主键必须在最后");
    }
}

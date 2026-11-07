//! 剪贴板读写（CF_UNICODETEXT）。
//!
//! 终端里的粘贴（Ctrl+Shift+V）与 OSC 52 复制都走这里；
//! 剪贴板被其他进程占用时短暂重试，失败则安静降级。

use std::ptr::null_mut;
use std::time::Duration;

use super::win32;

const MAX_TEXT: usize = 1 << 20; // 1 MiB 文本上限，防止 OSC 52 灌爆剪贴板

fn open_clipboard() -> bool {
    for _ in 0..5 {
        if unsafe { win32::OpenClipboard(null_mut()) } != 0 {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

/// 读取剪贴板文本；没有文本时返回 `None`。
pub fn get_text() -> Option<String> {
    if !open_clipboard() {
        return None;
    }
    let result = unsafe {
        let handle = win32::GetClipboardData(win32::CF_UNICODETEXT);
        if handle.is_null() {
            None
        } else {
            let pointer = win32::GlobalLock(handle) as *const u16;
            let text = if pointer.is_null() {
                None
            } else {
                Some(win32::from_wide_ptr(pointer))
            };
            win32::GlobalUnlock(handle);
            text
        }
    };
    unsafe {
        win32::CloseClipboard();
    }
    result.filter(|text| !text.is_empty())
}

/// 写入剪贴板文本。
pub fn set_text(text: &str) -> Result<(), String> {
    if text.len() > MAX_TEXT {
        return Err("内容过大，已忽略".into());
    }
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let mem = win32::GlobalAlloc(win32::GMEM_MOVEABLE, wide.len() * 2);
        if mem.is_null() {
            return Err("分配剪贴板内存失败".into());
        }
        let pointer = win32::GlobalLock(mem) as *mut u16;
        if pointer.is_null() {
            win32::GlobalFree(mem);
            return Err("锁定剪贴板内存失败".into());
        }
        std::ptr::copy_nonoverlapping(wide.as_ptr(), pointer, wide.len());
        win32::GlobalUnlock(mem);

        if !open_clipboard() {
            win32::GlobalFree(mem);
            return Err("无法打开剪贴板".into());
        }
        win32::EmptyClipboard();
        let written = win32::SetClipboardData(win32::CF_UNICODETEXT, mem);
        win32::CloseClipboard();
        if written.is_null() {
            win32::GlobalFree(mem);
            return Err("写入剪贴板失败".into());
        }
    }
    Ok(())
}

/// 把控制台/终端里的多行文本规整成控制台输入需要的 CR 结尾。
pub fn normalize_newlines(text: &str) -> String {
    text.replace("\r\n", "\n")
        .replace('\r', "\n")
        .replace('\n', "\r")
}

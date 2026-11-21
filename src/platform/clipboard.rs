//! 剪贴板：读写 Unicode 文本，并支持同时写入 HTML 片段（复制保留颜色）。

use super::win32::{self, HANDLE};

const OPEN_ATTEMPTS: usize = 8;

fn open() -> Result<(), String> {
    for _ in 0..OPEN_ATTEMPTS {
        if unsafe { win32::OpenClipboard(std::ptr::null_mut()) } != 0 {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    Err("无法打开剪贴板（可能被其他程序占用）".into())
}

fn alloc_global(bytes: &[u8]) -> Option<HANDLE> {
    unsafe {
        let handle = win32::GlobalAlloc(win32::GMEM_MOVEABLE, bytes.len());
        if handle.is_null() {
            return None;
        }
        let ptr = win32::GlobalLock(handle) as *mut u8;
        if ptr.is_null() {
            win32::GlobalFree(handle);
            return None;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
        win32::GlobalUnlock(handle);
        Some(handle)
    }
}

/// 读取剪贴板文本（UTF-8）；没有文本时返回空串。
pub fn get_text() -> String {
    if unsafe { win32::IsClipboardFormatAvailable(win32::CF_UNICODETEXT) } == 0 {
        return String::new();
    }
    if open().is_err() {
        return String::new();
    }
    let mut result = String::new();
    unsafe {
        let handle = win32::GetClipboardData(win32::CF_UNICODETEXT);
        if !handle.is_null() {
            let ptr = win32::GlobalLock(handle) as *const u16;
            if !ptr.is_null() {
                let size = win32::GlobalSize(handle) / 2;
                let mut units = Vec::with_capacity(size);
                for i in 0..size {
                    let unit = *ptr.add(i);
                    if unit == 0 {
                        break;
                    }
                    units.push(unit);
                }
                result = String::from_utf16_lossy(&units);
                win32::GlobalUnlock(handle);
            }
        }
        win32::CloseClipboard();
    }
    result
}

/// 写入纯文本。
pub fn set_text(text: &str) -> Result<(), String> {
    open()?;
    unsafe {
        win32::EmptyClipboard();
        let units: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
        let bytes = std::slice::from_raw_parts(units.as_ptr() as *const u8, units.len() * 2);
        if let Some(handle) = alloc_global(bytes) {
            if win32::SetClipboardData(win32::CF_UNICODETEXT, handle).is_null() {
                win32::GlobalFree(handle);
            }
        }
        win32::CloseClipboard();
    }
    Ok(())
}

/// 同时写入纯文本与 `CF_HTML`。`html` 是完整片段（自动补 CF_HTML 头）。
pub fn set_text_and_html(text: &str, html: &str) -> Result<(), String> {
    open()?;
    unsafe {
        win32::EmptyClipboard();

        let units: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
        let text_bytes =
            std::slice::from_raw_parts(units.as_ptr() as *const u8, units.len() * 2);
        if let Some(handle) = alloc_global(text_bytes) {
            if win32::SetClipboardData(win32::CF_UNICODETEXT, handle).is_null() {
                win32::GlobalFree(handle);
            }
        }

        let format = win32::RegisterClipboardFormatW(win32::wide("HTML Format").as_ptr());
        if format != 0 {
            let payload = build_cf_html(html);
            let bytes = payload.as_bytes();
            // CF_HTML 按 UTF-8 写入（Office 与浏览器都能识别）。
            if let Some(handle) = alloc_global(bytes) {
                if win32::SetClipboardData(format, handle).is_null() {
                    win32::GlobalFree(handle);
                }
            }
        }
        win32::CloseClipboard();
    }
    Ok(())
}

/// 生成带偏移头的 `CF_HTML` 负载。
pub fn build_cf_html(fragment: &str) -> String {
    let header_template = "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n";
    let prefix = "<html><body>\r\n<!--StartFragment-->";
    let suffix = "<!--EndFragment-->\r\n</body></html>";
    let start_html = header_template.len();
    let start_fragment = start_html + prefix.len();
    let end_fragment = start_fragment + fragment.len();
    let end_html = end_fragment + suffix.len();
    let header = format!(
        "Version:0.9\r\nStartHTML:{:010}\r\nEndHTML:{:010}\r\nStartFragment:{:010}\r\nEndFragment:{:010}\r\n",
        start_html, end_html, start_fragment, end_fragment
    );
    format!("{header}{prefix}{fragment}{suffix}")
}

/// 剪贴板序号，用于检测外部修改。
pub fn sequence() -> u32 {
    unsafe { win32::GetClipboardSequenceNumber() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cf_html_offsets_are_consistent() {
        let payload = build_cf_html("<b>hi</b>");
        assert!(payload.starts_with("Version:0.9\r\n"));
        assert!(payload.contains("StartFragment:"));
        assert!(payload.ends_with("</html>"));
        assert!(payload.contains("<b>hi</b>"));
    }
}

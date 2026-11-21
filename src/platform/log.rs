//! 轻量日志：写到 `%APPDATA%\Textm\textm.log`，超过上限自动截断。

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

pub fn data_dir() -> PathBuf {
    if let Some(dir) = super::win32::env("APPDATA") {
        PathBuf::from(dir).join("Textm")
    } else {
        std::env::temp_dir().join("Textm")
    }
}

pub fn config_path() -> PathBuf {
    if let Some(path) = super::win32::env("TEXTM_CONFIG") {
        return PathBuf::from(path);
    }
    data_dir().join("config.ini")
}

fn file() -> &'static Mutex<Option<std::fs::File>> {
    static LOG: OnceLock<Mutex<Option<std::fs::File>>> = OnceLock::new();
    LOG.get_or_init(|| {
        let dir = data_dir();
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("textm.log");
        // 超过 256 KiB 时清空，避免长期使用无限增长。
        if let Ok(meta) = fs::metadata(&path) {
            if meta.len() > 256 * 1024 {
                let _ = fs::remove_file(&path);
            }
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .ok();
        Mutex::new(file)
    })
}

fn stamp() -> String {
    // 只取系统时间戳，格式为「秒.毫秒」，不引第三方时间库。
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}", now.as_secs(), now.subsec_millis())
}

pub fn write(level: &str, message: &str) {
    let line = format!("[{}] {:<5} {}\n", stamp(), level, message);
    if let Ok(mut guard) = file().lock() {
        if let Some(file) = guard.as_mut() {
            let _ = file.write_all(line.as_bytes());
            let _ = file.flush();
        }
    }
    #[cfg(debug_assertions)]
    eprint!("{line}");
}

pub fn info(message: &str) {
    write("INFO", message);
}

pub fn warn(message: &str) {
    write("WARN", message);
}

pub fn error(message: &str) {
    write("ERROR", message);
}

/// 记录一次操作耗时（毫秒）。
pub fn timed<T>(label: &str, f: impl FnOnce() -> T) -> T {
    let start = std::time::Instant::now();
    let result = f();
    info(&format!("{label} 用时 {} ms", start.elapsed().as_millis()));
    result
}

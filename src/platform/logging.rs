//! 文件日志：%LOCALAPPDATA%\scterm\logs\scterm-YYYYMMDD.log（UTF-8）。

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use super::win32;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Debug,
    Info,
    Warn,
    Error,
}

impl Level {
    fn tag(self) -> &'static str {
        match self {
            Level::Debug => "DEBUG",
            Level::Info => "INFO ",
            Level::Warn => "WARN ",
            Level::Error => "ERROR",
        }
    }
}

struct Logger {
    verbose: bool,
    file: Mutex<Option<File>>,
}

static LOGGER: OnceLock<Logger> = OnceLock::new();

pub fn init(verbose: bool) {
    let path = log_file_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let file = OpenOptions::new().create(true).append(true).open(&path).ok();
    let logger = Logger {
        verbose,
        file: Mutex::new(file),
    };
    if LOGGER.set(logger).is_err() {
        return;
    }
    info(&format!(
        "==== scterm {} 启动，pid={}，verbose={} ====",
        env!("CARGO_PKG_VERSION"),
        std::process::id(),
        verbose
    ));
}

pub fn log_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    base.join("scterm").join("logs")
}

fn log_file_path() -> PathBuf {
    let st = local_time();
    log_dir().join(format!(
        "scterm-{:04}{:02}{:02}.log",
        st.wYear, st.wMonth, st.wDay
    ))
}

fn local_time() -> win32::SYSTEMTIME {
    unsafe {
        let mut st = win32::SYSTEMTIME::default();
        win32::GetLocalTime(&mut st);
        st
    }
}

fn timestamp() -> String {
    let st = local_time();
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03}",
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds
    )
}

pub fn log(level: Level, msg: &str) {
    let line = format!("{} [{}] {}\r\n", timestamp(), level.tag(), msg);
    match LOGGER.get() {
        Some(logger) => {
            if level == Level::Debug && !logger.verbose {
                return;
            }
            if let Ok(mut guard) = logger.file.lock() {
                if let Some(file) = guard.as_mut() {
                    let _ = file.write_all(line.as_bytes());
                }
            }
            if level == Level::Error {
                eprint!("{}", line);
            }
        }
        None => {
            if level >= Level::Warn {
                eprint!("{}", line);
            }
        }
    }
}

pub fn is_verbose() -> bool {
    LOGGER
        .get()
        .map(|logger| logger.verbose)
        .unwrap_or(false)
}

pub fn debug(msg: &str) {
    log(Level::Debug, msg);
}

pub fn info(msg: &str) {
    log(Level::Info, msg);
}

pub fn warn(msg: &str) {
    log(Level::Warn, msg);
}

pub fn error(msg: &str) {
    log(Level::Error, msg);
}

//! 能力协商位。握手时取双方交集。

pub const TRUECOLOR: u32 = 1 << 0;
pub const MOUSE: u32 = 1 << 1;
pub const BRACKETED_PASTE: u32 = 1 << 2;
pub const OSC52: u32 = 1 << 3;
pub const SIXEL: u32 = 1 << 4;

/// 服务端声明支持的能力（阶段 0）。
pub const SERVER: u32 = TRUECOLOR | BRACKETED_PASTE;

pub fn describe(caps: u32) -> String {
    let mut parts = Vec::new();
    if caps & TRUECOLOR != 0 {
        parts.push("真彩色");
    }
    if caps & MOUSE != 0 {
        parts.push("鼠标上报");
    }
    if caps & BRACKETED_PASTE != 0 {
        parts.push("括号粘贴");
    }
    if caps & OSC52 != 0 {
        parts.push("OSC52 剪贴板");
    }
    if caps & SIXEL != 0 {
        parts.push("Sixel");
    }
    if parts.is_empty() {
        "无".to_string()
    } else {
        parts.join("、")
    }
}

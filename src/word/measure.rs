//! 文字度量。
//!
//! 排版需要真实的字体宽度才能与 GUI 的 GDI 绘制一致，因此 TUI 与 GUI 共用
//! 同一套 GDI 度量；测试环境可以使用近似度量。

use std::collections::HashMap;

use crate::platform::win32::{self, HDC, HFONT, HGDIOBJ};

use super::layout::Font;

pub trait Measurer {
    fn width(&mut self, text: &str, font: &Font) -> i32;
    fn height(&mut self, font: &Font) -> i32;
    fn ascent(&mut self, font: &Font) -> i32;
}

#[derive(Clone, Copy, Default)]
struct FontMetrics {
    width: i32,
    height: i32,
    ascent: i32,
}

/// 基于 GDI 的字体度量，带缓存。
pub struct GdiMeasurer {
    dc: HDC,
    fonts: HashMap<Font, (HFONT, FontMetrics)>,
    widths: HashMap<(Font, String), i32>,
}

impl GdiMeasurer {
    pub fn new() -> GdiMeasurer {
        let dc = unsafe { win32::GetDC(std::ptr::null_mut()) };
        GdiMeasurer {
            dc,
            fonts: HashMap::new(),
            widths: HashMap::new(),
        }
    }

    fn font(&mut self, font: &Font) -> Option<&(HFONT, FontMetrics)> {
        if !self.fonts.contains_key(font) {
            let face = win32::wide(&font.family);
            let handle = unsafe {
                win32::CreateFontW(
                    -font.size.max(1),
                    0,
                    0,
                    0,
                    if font.bold { 700 } else { 400 },
                    if font.italic { 1 } else { 0 },
                    0,
                    0,
                    1, // DEFAULT_CHARSET
                    0,
                    0,
                    0,
                    0,
                    face.as_ptr(),
                )
            };
            if handle.is_null() {
                return None;
            }
            unsafe {
                let old = win32::SelectObject(self.dc, handle as HGDIOBJ);
                let mut metrics: win32::TEXTMETRICW = std::mem::zeroed();
                win32::GetTextMetricsW(self.dc, &mut metrics);
                win32::SelectObject(self.dc, old);
                self.fonts.insert(
                    font.clone(),
                    (
                        handle,
                        FontMetrics {
                            width: 0,
                            height: metrics.tmHeight.max(1),
                            ascent: metrics.tmAscent.max(1),
                        },
                    ),
                );
            }
        }
        self.fonts.get(font)
    }
}

impl Measurer for GdiMeasurer {
    fn width(&mut self, text: &str, font: &Font) -> i32 {
        if text.is_empty() {
            return 0;
        }
        let key = (font.clone(), text.to_string());
        if let Some(width) = self.widths.get(&key) {
            return *width;
        }
        let Some((handle, _)) = self.font(font).map(|item| (item.0, item.1)) else {
            return approximate_width(text, font.size);
        };
        let wide = win32::wide(text);
        let mut size = win32::SIZE::default();
        let width = unsafe {
            let old = win32::SelectObject(self.dc, handle as HGDIOBJ);
            let ok = win32::GetTextExtentPoint32W(
                self.dc,
                wide.as_ptr(),
                wide.len() as i32,
                &mut size,
            );
            win32::SelectObject(self.dc, old);
            if ok != 0 {
                size.cx.max(0)
            } else {
                approximate_width(text, font.size)
            }
        };
        self.widths.insert(key, width);
        width
    }

    fn height(&mut self, font: &Font) -> i32 {
        self.font(font)
            .map(|item| item.1.height)
            .unwrap_or_else(|| (font.size as f32 * 1.3).max(6.0) as i32)
    }

    fn ascent(&mut self, font: &Font) -> i32 {
        self.font(font)
            .map(|item| item.1.ascent)
            .unwrap_or_else(|| (font.size as f32 * 1.0).max(4.0) as i32)
    }
}

impl Drop for GdiMeasurer {
    fn drop(&mut self) {
        unsafe {
            for (_, (font, _)) in self.fonts.drain() {
                win32::DeleteObject(font as HGDIOBJ);
            }
            win32::ReleaseDC(std::ptr::null_mut(), self.dc);
        }
    }
}

fn approximate_width(text: &str, size: i32) -> i32 {
    let mut width = 0.0f32;
    for ch in text.chars() {
        width += if is_wide(ch) {
            size as f32
        } else if ch == '\t' {
            size as f32 * 2.0
        } else {
            size as f32 * 0.52
        };
    }
    width as i32
}

fn is_wide(ch: char) -> bool {
    matches!(
        ch as u32,
        0x1100..=0x115F
            | 0x2E80..=0xA4CF
            | 0xAC00..=0xD7A3
            | 0xF900..=0xFAFF
            | 0xFE30..=0xFE4F
            | 0xFF00..=0xFF60
            | 0xFFE0..=0xFFE6
            | 0x20000..=0x3FFFD
    )
}

/// 近似度量：没有 GDI 的单元测试使用。
pub struct ApproxMeasurer;

impl Measurer for ApproxMeasurer {
    fn width(&mut self, text: &str, font: &Font) -> i32 {
        approximate_width(text, font.size)
    }

    fn height(&mut self, font: &Font) -> i32 {
        (font.size as f32 * 1.3).max(6.0) as i32
    }

    fn ascent(&mut self, font: &Font) -> i32 {
        (font.size as f32 * 1.05).max(4.0) as i32
    }
}

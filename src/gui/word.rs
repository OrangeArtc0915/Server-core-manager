//! GUI 下的 Word 高保真页面绘制。
//!
//! 排版结果与后端无关，这里负责把 `word::layout` 的绘制指令用 GDI 画到双缓冲
//! 位图上，并处理页面滚动、缩放与缓存。

use std::collections::HashMap;
use std::path::PathBuf;

use crate::platform::win32::{self, HBITMAP, HDC, HFONT, HGDIOBJ};
use crate::render::Color;
use crate::word::layout::{self, DocumentLayout, Item};
use crate::word::measure::GdiMeasurer;

use super::Gui;

struct ImageBitmap {
    bitmap: HBITMAP,
    dc: HDC,
    width: i32,
    height: i32,
}

/// Word 渲染缓存，生命周期跟随窗口。
pub struct WordView {
    measure: Option<GdiMeasurer>,
    layout: Option<DocumentLayout>,
    key: u64,
    pub scroll: i32,
    pub zoom: f32,
    fonts: HashMap<(String, i32, bool, bool), HFONT>,
    images: HashMap<PathBuf, ImageBitmap>,
    content_height: i32,
    tab: usize,
}

impl Default for WordView {
    fn default() -> Self {
        WordView {
            measure: None,
            layout: None,
            key: u64::MAX,
            scroll: 0,
            zoom: 1.0,
            fonts: HashMap::new(),
            images: HashMap::new(),
            content_height: 0,
            tab: usize::MAX,
        }
    }
}

impl Drop for WordView {
    fn drop(&mut self) {
        unsafe {
            for (_, font) in self.fonts.drain() {
                win32::DeleteObject(font as HGDIOBJ);
            }
            for (_, image) in self.images.drain() {
                win32::DeleteObject(image.bitmap as HGDIOBJ);
                win32::DeleteDC(image.dc);
            }
        }
    }
}

impl WordView {
    pub fn invalidate(&mut self) {
        self.key = u64::MAX;
    }

    fn font(&mut self, family: &str, size: i32, bold: bool, italic: bool) -> HFONT {
        let key = (family.to_string(), size, bold, italic);
        if let Some(font) = self.fonts.get(&key) {
            return *font;
        }
        let face = win32::wide(family);
        let font = unsafe {
            win32::CreateFontW(
                -size.max(1),
                0,
                0,
                0,
                if bold { 700 } else { 400 },
                if italic { 1 } else { 0 },
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
        self.fonts.insert(key, font);
        font
    }

    unsafe fn image(&mut self, path: &PathBuf) -> Option<&ImageBitmap> {
        if !self.images.contains_key(path) {
            let kind = crate::image::ImageKind::from_path(path)?;
            let image = crate::image::Image::load(path, kind).ok()?;
            if image.width == 0 || image.height == 0 {
                return None;
            }
            let info = win32::BITMAPINFO {
                bmiHeader: win32::BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<win32::BITMAPINFOHEADER>() as u32,
                    biWidth: image.width as i32,
                    biHeight: -(image.height as i32),
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: win32::BI_RGB,
                    ..Default::default()
                },
                bmiColors: [win32::RGBQUAD::default()],
            };
            let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
            let bitmap = win32::CreateDIBSection(
                std::ptr::null_mut(),
                &info,
                win32::DIB_RGB_COLORS,
                &mut bits,
                std::ptr::null_mut(),
                0,
            );
            if bitmap.is_null() {
                return None;
            }
            let pixels = bits as *mut u8;
            for index in 0..image.width * image.height {
                let src = index * 4;
                let dst = index * 4;
                *pixels.add(dst) = image.pixels[src + 2];
                *pixels.add(dst + 1) = image.pixels[src + 1];
                *pixels.add(dst + 2) = image.pixels[src];
                *pixels.add(dst + 3) = 0;
            }
            let dc = win32::CreateCompatibleDC(std::ptr::null_mut());
            win32::SelectObject(dc, bitmap as HGDIOBJ);
            self.images.insert(
                path.clone(),
                ImageBitmap {
                    bitmap,
                    dc,
                    width: image.width as i32,
                    height: image.height as i32,
                },
            );
        }
        self.images.get(path)
    }
}

impl Gui {
    /// 在 Canvas 之上叠加 Word 页面。调用方已完成网格绘制。
    pub(super) unsafe fn paint_word(&mut self) {
        if !self.app.word_page_view {
            return;
        }
        if self.app.tab().word.is_none() {
            return;
        }
        let area = self.app.layout.text;
        if area.w == 0 || area.h == 0 {
            return;
        }
        let ax = area.x as i32 * self.cell_w;
        let ay = area.y as i32 * self.cell_h;
        let aw = area.w as i32 * self.cell_w;
        let ah = area.h as i32 * self.cell_h;

        let zoom = self.app.word_zoom.clamp(0.5, 2.0);
        let mut key = 1469598103934665603u64;
        for value in [
            self.app.active as u64,
            self.app.doc().revision,
            zoom.to_bits() as u64,
            aw as u64,
            self.cell_h as u64,
        ] {
            key ^= value;
            key = key.wrapping_mul(1099511628211);
        }
        if self.word_view.key != key || self.word_view.layout.is_none() {
            let measure = self
                .word_view
                .measure
                .get_or_insert_with(GdiMeasurer::new);
            let model = &self.app.tab().word.as_ref().unwrap().model;
            let layout = layout::layout(model, measure, zoom);
            self.word_view.content_height = layout.total_height(20);
            self.word_view.layout = Some(layout);
            self.word_view.key = key;
            if self.word_view.tab != self.app.active {
                self.word_view.scroll = 0;
                self.word_view.tab = self.app.active;
            }
        }

        let max_scroll = (self.word_view.content_height - ah).max(0);
        self.word_view.scroll = self.word_view.scroll.clamp(0, max_scroll);
        let scroll = self.word_view.scroll;
        let Some(layout) = self.word_view.layout.take() else {
            return;
        };

        let saved = win32::SaveDC(self.mem_dc);
        win32::IntersectClipRect(self.mem_dc, ax, ay, ax + aw, ay + ah);
        win32::SetBkMode(self.mem_dc, win32::TRANSPARENT);

        let gap = 20;
        let mut y = ay + gap - scroll;
        let shadow = self.app.theme.bg.scale(0.45);
        let paper = Color::rgb(255, 255, 255);
        for page in &layout.pages {
            if y + page.height >= ay && y <= ay + ah {
                let x = ax + (aw - page.width).max(0) / 2;
                self.fill(x + 5, y + 5, page.width, page.height, shadow);
                self.fill(x, y, page.width, page.height, paper);
                for item in &page.items {
                    self.draw_word_item(item, x, y);
                }
            }
            y += page.height + gap;
        }

        win32::RestoreDC(self.mem_dc, saved);
        self.word_view.layout = Some(layout);
    }

    unsafe fn draw_word_item(&mut self, item: &Item, ox: i32, oy: i32) {
        match item {
            Item::Rect {
                x,
                y,
                w,
                h,
                fill,
                border,
                thickness,
            } => {
                if let Some(color) = fill {
                    self.fill(ox + x, oy + y, *w, *h, *color);
                }
                if let Some(color) = border {
                    let t = (*thickness).max(1);
                    self.fill(ox + x, oy + y, *w, t, *color);
                    self.fill(ox + x, oy + y + h - t, *w, t, *color);
                    self.fill(ox + x, oy + y, t, *h, *color);
                    self.fill(ox + x + w - t, oy + y, t, *h, *color);
                }
            }
            Item::Text {
                x,
                y,
                w,
                h,
                text,
                font,
                color,
                underline,
                strike,
                ..
            } => {
                let handle = self
                    .word_view
                    .font(&font.family, font.size, font.bold, font.italic);
                if handle.is_null() {
                    return;
                }
                let old = win32::SelectObject(self.mem_dc, handle as HGDIOBJ);
                win32::SetTextColor(
                    self.mem_dc,
                    win32::colorref(color.r, color.g, color.b),
                );
                let wide = win32::wide(text);
                win32::ExtTextOutW(
                    self.mem_dc,
                    ox + x,
                    oy + y,
                    0,
                    std::ptr::null(),
                    wide.as_ptr(),
                    wide.len() as i32,
                    std::ptr::null(),
                );
                win32::SelectObject(self.mem_dc, old);
                if *underline {
                    self.fill(ox + x, oy + y + h - 2, *w, 1, *color);
                }
                if *strike {
                    self.fill(ox + x, oy + y + h / 2, *w, 1, *color);
                }
            }
            Item::Image { x, y, w, h, path } => {
                let path = path.clone();
                if let Some(image) = self.word_view.image(&path) {
                    let dc = image.dc;
                    let (iw, ih) = (image.width, image.height);
                    win32::SetStretchBltMode(self.mem_dc, 4);
                    win32::StretchBlt(
                        self.mem_dc,
                        ox + x,
                        oy + y,
                        *w,
                        *h,
                        dc,
                        0,
                        0,
                        iw,
                        ih,
                        win32::SRCCOPY,
                    );
                }
            }
        }
    }

    /// 页面视图下的按键：翻页、缩放、回到编辑。
    pub(super) fn word_key(&mut self, code: crate::platform::console::KeyCode) -> bool {
        use crate::platform::console::KeyCode;
        if !self.app.word_page_view || self.app.tab().word.is_none() {
            return false;
        }
        let page = self
            .word_view
            .layout
            .as_ref()
            .and_then(|layout| layout.pages.first().map(|page| (page.height + 20).max(1)))
            .unwrap_or(600);
        match code {
            KeyCode::PageUp => {
                self.word_view.scroll = (self.word_view.scroll - page).max(0);
            }
            KeyCode::PageDown => {
                self.word_view.scroll =
                    (self.word_view.scroll + page).min(self.word_view.content_height);
            }
            KeyCode::Home => self.word_view.scroll = 0,
            KeyCode::End => self.word_view.scroll = self.word_view.content_height,
            _ => return false,
        }
        true
    }

    /// 页面视图滚轮：Ctrl 缩放，普通滚轮滚动。
    pub(super) fn word_wheel(&mut self, delta: i16, ctrl: bool) -> bool {
        if !self.app.word_page_view || self.app.tab().word.is_none() {
            return false;
        }
        if ctrl {
            let step = 0.1 * delta as f32;
            self.app.word_zoom = (self.app.word_zoom + step).clamp(0.5, 2.0);
            self.app.set_status(format!("Word 缩放 {:.0}%", self.app.word_zoom * 100.0));
            self.word_view.invalidate();
        } else {
            self.word_view.scroll =
                (self.word_view.scroll - delta as i32 * 80).max(0);
        }
        true
    }
}

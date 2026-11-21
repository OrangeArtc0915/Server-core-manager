//! GUI 后端：Win32 窗口 + GDI 双缓冲绘制。
//!
//! 与 TUI 共用同一套 `App` 状态机与 `Canvas` 网格：每个字符单元画成一个
//! 等宽字形，颜色、选择、折叠、浮层都与终端一致；图片直接 StretchBlt 位图。

use std::collections::HashMap;
use std::ffi::c_void;
use std::path::PathBuf;

use crate::config::Config;
use crate::platform::log;
use crate::platform::win32::{self, HANDLE, HBITMAP, HBRUSH, HDC, HFONT, HGDIOBJ, HWND, RECT};
use crate::platform::console::{Button, Key, KeyCode, Mods, Mouse, MouseKind};
use crate::render::Color;
use crate::ui::app::{App, Event};

mod excel;
mod word;
use excel::ExcelView;
use word::WordView;

const TIMER_ID: usize = 1;

pub struct Gui {
    pub app: App,
    hwnd: HWND,
    mem_dc: HDC,
    bitmap: HBITMAP,
    old_bitmap: HGDIOBJ,
    bits: *mut u8,
    width: i32,
    height: i32,
    cell_w: i32,
    cell_h: i32,
    font: HFONT,
    font_bold: HFONT,
    brushes: HashMap<u32, HBRUSH>,
    image_cache: Option<(PathBuf, HBITMAP, HDC, i32, i32)>,
    word_view: WordView,
    excel_view: ExcelView,
    last_title: String,
    destroyed: bool,
}

impl Gui {
    fn new(config: Config, files: Vec<PathBuf>) -> Gui {
        let font_name = config.gui_font.clone();
        let font_size = config.gui_font_size.max(8) as i32;
        let restore = files.is_empty();
        let mut app = App::new(config, files, true);
        if restore {
            app.restore_session();
        }
        let mut gui = Gui {
            app,
            hwnd: std::ptr::null_mut(),
            mem_dc: std::ptr::null_mut(),
            bitmap: std::ptr::null_mut(),
            old_bitmap: std::ptr::null_mut(),
            bits: std::ptr::null_mut(),
            width: 0,
            height: 0,
            cell_w: 8,
            cell_h: 18,
            font: std::ptr::null_mut(),
            font_bold: std::ptr::null_mut(),
            brushes: HashMap::new(),
            image_cache: None,
            word_view: WordView::default(),
            excel_view: ExcelView::default(),
            last_title: String::new(),
            destroyed: false,
        };
        unsafe {
            let face = win32::wide(&font_name);
            gui.font = win32::CreateFontW(
                -font_size,
                0,
                0,
                0,
                400,
                0,
                0,
                0,
                1, // DEFAULT_CHARSET
                0,
                0,
                0,
                0x31, // FIXED_PITCH | FF_MODERN
                face.as_ptr(),
            );
            gui.font_bold = win32::CreateFontW(
                -font_size,
                0,
                0,
                0,
                700,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                0x31,
                face.as_ptr(),
            );
            if gui.font.is_null() {
                gui.font = win32::CreateFontW(
                    -font_size,
                    0,
                    0,
                    0,
                    400,
                    0,
                    0,
                    0,
                    1,
                    0,
                    0,
                    0,
                    0,
                    win32::wide("Consolas").as_ptr(),
                );
            }
        }
        gui
    }

    /// 用窗口 DC 初始化度量与双缓冲。
    unsafe fn init(&mut self, hdc: HDC) {
        self.mem_dc = win32::CreateCompatibleDC(hdc);
        win32::SelectObject(self.mem_dc, self.font as HGDIOBJ);
        let mut metrics: win32::TEXTMETRICW = std::mem::zeroed();
        win32::GetTextMetricsW(self.mem_dc, &mut metrics);
        let mut size = win32::SIZE::default();
        let probe = win32::wide("W");
        win32::GetTextExtentPoint32W(self.mem_dc, probe.as_ptr(), 1, &mut size);
        let mut cell_w = size.cx.max(4);
        let cell_h = metrics.tmHeight.max(8);
        // 让中文字符正好占两格
        let cjk = win32::wide("中");
        if win32::GetTextExtentPoint32W(self.mem_dc, cjk.as_ptr(), 1, &mut size) != 0 {
            cell_w = cell_w.max((size.cx + 1) / 2);
        }
        let mut rect = RECT::default();
        win32::GetClientRect(self.hwnd, &mut rect);
        let rows = ((rect.bottom - rect.top) / cell_h).max(8) as usize;
        let cols = ((rect.right - rect.left) / cell_w).max(20) as usize;
        self.cell_w = cell_w;
        self.cell_h = cell_h;
        self.app.resize(cols, rows);
        self.resize_backbuffer(hdc, cols as i32 * cell_w, rows as i32 * cell_h);
    }

    unsafe fn resize_backbuffer(&mut self, hdc: HDC, width: i32, height: i32) {
        if width <= 0 || height <= 0 {
            return;
        }
        if width == self.width && height == self.height && !self.bitmap.is_null() {
            return;
        }
        if !self.bitmap.is_null() {
            win32::SelectObject(self.mem_dc, self.old_bitmap);
            win32::DeleteObject(self.bitmap as HGDIOBJ);
            self.bitmap = std::ptr::null_mut();
        }
        let info = win32::BITMAPINFO {
            bmiHeader: win32::BITMAPINFOHEADER {
                biSize: std::mem::size_of::<win32::BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height, // 自上而下
                biPlanes: 1,
                biBitCount: 32,
                biCompression: win32::BI_RGB,
                ..Default::default()
            },
            bmiColors: [win32::RGBQUAD::default()],
        };
        let mut bits: *mut c_void = std::ptr::null_mut();
        let bitmap = win32::CreateDIBSection(
            hdc,
            &info,
            win32::DIB_RGB_COLORS,
            &mut bits,
            std::ptr::null_mut::<c_void>() as HANDLE,
            0,
        );
        if bitmap.is_null() {
            log::error("GUI 双缓冲创建失败");
            return;
        }
        self.old_bitmap = win32::SelectObject(self.mem_dc, bitmap as HGDIOBJ);
        self.bitmap = bitmap;
        self.bits = bits as *mut u8;
        self.width = width;
        self.height = height;
    }

    unsafe fn brush(&mut self, color: Color) -> HBRUSH {
        let key = (color.r as u32) | ((color.g as u32) << 8) | ((color.b as u32) << 16);
        if let Some(brush) = self.brushes.get(&key) {
            return *brush;
        }
        let brush = win32::CreateSolidBrush(key);
        self.brushes.insert(key, brush);
        brush
    }

    fn fill(&mut self, x: i32, y: i32, w: i32, h: i32, color: Color) {
        if w <= 0 || h <= 0 {
            return;
        }
        unsafe {
            let rect = RECT {
                left: x,
                top: y,
                right: x + w,
                bottom: y + h,
            };
            let brush = self.brush(color);
            win32::FillRect(self.mem_dc, &rect, brush);
        }
    }

    unsafe fn paint(&mut self, hdc: HDC) {
        let canvas = self.app.render();
        let width = canvas.grid.cols as i32 * self.cell_w;
        let height = canvas.grid.rows as i32 * self.cell_h;
        self.resize_backbuffer(hdc, width, height);
        if self.bitmap.is_null() {
            return;
        }
        let bg = self.app.theme.bg;
        self.fill(0, 0, width, height, bg);
        win32::SetBkMode(self.mem_dc, win32::TRANSPARENT);
        win32::SelectObject(self.mem_dc, self.font as HGDIOBJ);

        for y in 0..canvas.grid.rows {
            // 第一遍：按背景色合并同色区间填充
            let row_bg = canvas.grid.get(0, y).map(|c| c.bg).unwrap_or(bg);
            let mut run_start = 0usize;
            let mut run_color = row_bg;
            for x in 0..canvas.grid.cols {
                let Some(cell) = canvas.grid.get(x, y) else {
                    break;
                };
                if cell.bg != run_color {
                    self.fill(
                        run_start as i32 * self.cell_w,
                        y as i32 * self.cell_h,
                        (x - run_start) as i32 * self.cell_w,
                        self.cell_h,
                        run_color,
                    );
                    run_start = x;
                    run_color = cell.bg;
                }
            }
            self.fill(
                run_start as i32 * self.cell_w,
                y as i32 * self.cell_h,
                (canvas.grid.cols - run_start) as i32 * self.cell_w,
                self.cell_h,
                run_color,
            );

            // 第二遍：绘制文字
            for x in 0..canvas.grid.cols {
                let Some(cell) = canvas.grid.get(x, y) else {
                    break;
                };
                if cell.cont || cell.ch == ' ' || cell.ch == '\0' {
                    continue;
                }
                let mut buffer = [0u16; 2];
                let len = cell.ch.encode_utf16(&mut buffer).len();
                let rect = RECT {
                    left: x as i32 * self.cell_w,
                    top: y as i32 * self.cell_h,
                    right: (x as i32 + if cell.wide { 2 } else { 1 }) * self.cell_w,
                    bottom: (y as i32 + 1) * self.cell_h,
                };
                win32::SetTextColor(
                    self.mem_dc,
                    win32::colorref(cell.fg.r, cell.fg.g, cell.fg.b),
                );
                win32::ExtTextOutW(
                    self.mem_dc,
                    rect.left,
                    rect.top,
                    0,
                    &rect,
                    buffer.as_ptr(),
                    len as i32,
                    std::ptr::null(),
                );
            }
        }

        // 光标
        if let Some((x, y)) = self.app.cursor_screen() {
            self.fill(
                x as i32 * self.cell_w,
                y as i32 * self.cell_h,
                2.max(self.cell_w / 8),
                self.cell_h,
                self.app.theme.fg,
            );
        }

        self.paint_image();
        self.paint_word();
        self.paint_excel();
        win32::BitBlt(hdc, 0, 0, width, height, self.mem_dc, 0, 0, win32::SRCCOPY);
    }

    unsafe fn paint_image(&mut self) {
        let tab = self.app.tab();
        let Some(image) = &tab.image else {
            return;
        };
        if image.pixels.is_empty() || image.width == 0 || image.height == 0 {
            return;
        }
        let path = image.path.clone();
        let rebuild = match &self.image_cache {
            Some((cached, _, _, _, _)) => cached != &path,
            None => true,
        };
        if rebuild {
            if let Some((_, bitmap, dc, _, _)) = self.image_cache.take() {
                win32::DeleteObject(bitmap as HGDIOBJ);
                win32::DeleteDC(dc);
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
            let mut bits: *mut c_void = std::ptr::null_mut();
            let bitmap = win32::CreateDIBSection(
                self.mem_dc,
                &info,
                win32::DIB_RGB_COLORS,
                &mut bits,
                std::ptr::null_mut(),
                0,
            );
            if bitmap.is_null() {
                return;
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
            let dc = win32::CreateCompatibleDC(self.mem_dc);
            win32::SelectObject(dc, bitmap as HGDIOBJ);
            self.image_cache = Some((path, bitmap, dc, image.width as i32, image.height as i32));
        }

        let Some((_, _, dc, iw, ih)) = &self.image_cache else {
            return;
        };
        let (iw, ih) = (*iw, *ih);
        let area = self.app.layout.text;
        let max_w = (area.w as i32) * self.cell_w;
        let max_h = (area.h as i32) * self.cell_h;
        if max_w <= 0 || max_h <= 0 {
            return;
        }
        let scale = (max_w as f32 / iw as f32).min(max_h as f32 / ih as f32).max(0.01);
        let dw = (iw as f32 * scale) as i32;
        let dh = (ih as f32 * scale) as i32;
        let dx = area.x as i32 * self.cell_w + (max_w - dw) / 2;
        let dy = area.y as i32 * self.cell_h + (max_h - dh) / 2;
        win32::SetStretchBltMode(self.mem_dc, 4); // HALFTONE
        win32::StretchBlt(
            self.mem_dc, dx, dy, dw, dh, *dc, 0, 0, iw, ih, win32::SRCCOPY,
        );
    }

    fn resize_from_client(&mut self) {
        unsafe {
            let mut rect = RECT::default();
            win32::GetClientRect(self.hwnd, &mut rect);
            let cols = ((rect.right - rect.left) / self.cell_w).max(20) as usize;
            let rows = ((rect.bottom - rect.top) / self.cell_h).max(8) as usize;
            self.app.resize(cols, rows);
        }
    }

    fn update_title(&mut self) {
        let dirty = if self.app.doc().is_dirty() { "*" } else { "" };
        let title = format!("{}{} - Textm 2.0", dirty, self.app.doc().title());
        if title != self.last_title {
            unsafe {
                win32::SetWindowTextW(self.hwnd, win32::wide(&title).as_ptr());
            }
            self.last_title = title;
        }
    }

    unsafe fn on_key(&mut self, vk: u16, mods: Mods) {
        if vk == 0xE5 {
            return; // VK_PROCESSKEY：输入法处理中
        }
        let Some(code) = key_code(vk, mods) else {
            return;
        };
        if self.word_key(code) {
            return;
        }
        self.app.handle(Event::Key(Key { code, mods }));
        if self.app.tab().excel.is_some() {
            let book = self.app.tab().excel.as_ref().unwrap();
            self.excel_view.ensure_visible(&self.app, book);
        }
    }

    unsafe fn on_char(&mut self, ch: char) {
        let ctrl = win32::GetKeyState(win32::VK_CONTROL) < 0;
        let alt = win32::GetKeyState(win32::VK_MENU) < 0;
        if (ctrl && alt) || (!ctrl && !alt) {
            if ch < ' ' || ch == '\u{7f}' {
                return;
            }
            self.app.handle(Event::Key(Key {
                code: KeyCode::Char(ch),
                mods: Mods::default(),
            }));
        }
    }

    fn mouse_from(&self, x: i32, y: i32, kind: MouseKind, button: Option<Button>, wheel: i16) -> Mouse {
        Mouse {
            x: (x / self.cell_w).max(0) as u16,
            y: (y / self.cell_h).max(0) as u16,
            kind,
            button,
            wheel,
            mods: unsafe {
                Mods {
                    ctrl: win32::GetKeyState(win32::VK_CONTROL) < 0,
                    alt: win32::GetKeyState(win32::VK_MENU) < 0,
                    shift: win32::GetKeyState(win32::VK_SHIFT) < 0,
                }
            },
        }
    }

    unsafe fn on_mouse(&mut self, msg: u32, wparam: usize, x: i32, y: i32) {
        if self.app.tab().excel.is_some() && self.excel_mouse(msg, wparam, x, y) {
            return;
        }
        if msg == win32::WM_MOUSEWHEEL {
            let delta = ((wparam >> 16) as u16 as i16) / 120;
            let ctrl = win32::GetKeyState(win32::VK_CONTROL) < 0;
            if self.word_wheel(delta, ctrl) {
                return;
            }
        }
        if msg == win32::WM_LBUTTONDBLCLK
            && self.app.word_page_view
            && self.app.tab().word.is_some()
        {
            let cell_x = (x / self.cell_w).max(0) as usize;
            let cell_y = (y / self.cell_h).max(0) as usize;
            if self.app.layout.text.contains(cell_x, cell_y) {
                self.app.word_page_view = false;
                self.app
                    .set_status("Word 文本编辑视图（F6 回到页面视图）");
                return;
            }
        }
        let kinds = match msg {
            win32::WM_LBUTTONDOWN => (MouseKind::Down, Some(Button::Left), 0),
            win32::WM_LBUTTONUP => (MouseKind::Up, Some(Button::Left), 0),
            win32::WM_LBUTTONDBLCLK => (MouseKind::DoubleClick, Some(Button::Left), 0),
            win32::WM_RBUTTONDOWN => (MouseKind::Down, Some(Button::Right), 0),
            win32::WM_MBUTTONDOWN => (MouseKind::Down, Some(Button::Middle), 0),
            win32::WM_MOUSEMOVE => {
                if wparam & win32::MK_LBUTTON != 0 {
                    (MouseKind::Drag, Some(Button::Left), 0)
                } else {
                    (MouseKind::Move, None, 0)
                }
            }
            win32::WM_MOUSEWHEEL => {
                let delta = ((wparam >> 16) as u16 as i16) / 120;
                (MouseKind::Wheel, None, delta)
            }
            _ => return,
        };
        let mouse = self.mouse_from(x, y, kinds.0, kinds.1, kinds.2);
        self.app.handle(Event::Mouse(mouse));
    }

    unsafe fn destroy_resources(&mut self) {
        if !self.bitmap.is_null() {
            win32::SelectObject(self.mem_dc, self.old_bitmap);
            win32::DeleteObject(self.bitmap as HGDIOBJ);
            self.bitmap = std::ptr::null_mut();
        }
        if !self.mem_dc.is_null() {
            win32::DeleteDC(self.mem_dc);
            self.mem_dc = std::ptr::null_mut();
        }
        if !self.font.is_null() {
            win32::DeleteObject(self.font as HGDIOBJ);
        }
        if !self.font_bold.is_null() {
            win32::DeleteObject(self.font_bold as HGDIOBJ);
        }
        for (_, brush) in self.brushes.drain() {
            win32::DeleteObject(brush as HGDIOBJ);
        }
        if let Some((_, bitmap, dc, _, _)) = self.image_cache.take() {
            win32::DeleteObject(bitmap as HGDIOBJ);
            win32::DeleteDC(dc);
        }
    }
}

impl Drop for Gui {
    fn drop(&mut self) {
        unsafe {
            self.destroy_resources();
        }
    }
}

/// 把虚拟键转成编辑器按键；普通可打印字符交给 WM_CHAR，避免重复插入。
unsafe fn key_code(vk: u16, mods: Mods) -> Option<KeyCode> {
    use KeyCode::*;
    let special = match vk {
        win32::VK_RETURN => Some(Enter),
        win32::VK_TAB => Some(Tab),
        win32::VK_BACK => Some(Backspace),
        win32::VK_ESCAPE => Some(Esc),
        win32::VK_UP => Some(Up),
        win32::VK_DOWN => Some(Down),
        win32::VK_LEFT => Some(Left),
        win32::VK_RIGHT => Some(Right),
        win32::VK_HOME => Some(Home),
        win32::VK_END => Some(End),
        win32::VK_PRIOR => Some(PageUp),
        win32::VK_NEXT => Some(PageDown),
        win32::VK_INSERT => Some(Insert),
        win32::VK_DELETE => Some(Delete),
        win32::VK_F1..=win32::VK_F24 => Some(F((vk - win32::VK_F1 + 1) as u8)),
        _ => None,
    };
    if let Some(code) = special {
        return Some(code);
    }
    if !mods.ctrl && !mods.alt {
        return None;
    }
    let ch = match vk {
        0x30..=0x39 => char::from_u32((vk - 0x30) as u32 + '0' as u32),
        0x41..=0x5A => char::from_u32((vk - 0x41) as u32 + 'a' as u32),
        win32::VK_SPACE => Some(' '),
        win32::VK_OEM_1 => Some(';'),
        win32::VK_OEM_PLUS => Some('='),
        win32::VK_OEM_COMMA => Some(','),
        win32::VK_OEM_MINUS => Some('-'),
        win32::VK_OEM_PERIOD => Some('.'),
        win32::VK_OEM_2 => Some('/'),
        win32::VK_OEM_3 => Some('`'),
        win32::VK_OEM_4 => Some('['),
        win32::VK_OEM_5 => Some('\\'),
        win32::VK_OEM_6 => Some(']'),
        win32::VK_OEM_7 => Some('\''),
        _ => None,
    };
    ch.map(Char)
}

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) -> isize {
    let pointer = win32::GetWindowLongPtrW(hwnd, win32::GWLP_USERDATA) as *mut Gui;
    if pointer.is_null() {
        return win32::DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    let gui = &mut *pointer;
    match msg {
        win32::WM_PAINT => {
            let mut paint: win32::PAINTSTRUCT = std::mem::zeroed();
            let hdc = win32::BeginPaint(hwnd, &mut paint);
            gui.paint(hdc);
            win32::EndPaint(hwnd, &paint);
            0
        }
        win32::WM_ERASEBKGND => 1,
        win32::WM_SIZE => {
            gui.resize_from_client();
            win32::InvalidateRect(hwnd, std::ptr::null(), 0);
            0
        }
        win32::WM_TIMER => {
            gui.app.handle(Event::Tick);
            gui.update_title();
            win32::InvalidateRect(hwnd, std::ptr::null(), 0);
            0
        }
        win32::WM_KEYDOWN | win32::WM_SYSKEYDOWN => {
            let mods = Mods {
                ctrl: win32::GetKeyState(win32::VK_CONTROL) < 0,
                alt: win32::GetKeyState(win32::VK_MENU) < 0,
                shift: win32::GetKeyState(win32::VK_SHIFT) < 0,
            };
            gui.on_key(wparam as u16, mods);
            win32::InvalidateRect(hwnd, std::ptr::null(), 0);
            0
        }
        win32::WM_CHAR => {
            if let Some(ch) = char::from_u32(wparam as u32) {
                gui.on_char(ch);
            }
            win32::InvalidateRect(hwnd, std::ptr::null(), 0);
            0
        }
        win32::WM_MOUSEMOVE
        | win32::WM_LBUTTONDOWN
        | win32::WM_LBUTTONUP
        | win32::WM_LBUTTONDBLCLK
        | win32::WM_RBUTTONDOWN
        | win32::WM_MBUTTONDOWN => {
            let x = (lparam & 0xFFFF) as u16 as i16 as i32;
            let y = ((lparam >> 16) & 0xFFFF) as u16 as i16 as i32;
            gui.on_mouse(msg, wparam, x, y);
            win32::InvalidateRect(hwnd, std::ptr::null(), 0);
            0
        }
        win32::WM_MOUSEWHEEL => {
            let screen_x = (lparam & 0xFFFF) as u16 as i16 as i32;
            let screen_y = ((lparam >> 16) & 0xFFFF) as u16 as i16 as i32;
            let mut point = win32::POINT {
                x: screen_x,
                y: screen_y,
            };
            win32::ScreenToClient(hwnd, &mut point);
            gui.on_mouse(msg, wparam, point.x, point.y);
            win32::InvalidateRect(hwnd, std::ptr::null(), 0);
            0
        }
        win32::WM_CLOSE => {
            gui.app.request_quit_public();
            if !gui.app.running {
                win32::DestroyWindow(hwnd);
            }
            0
        }
        win32::WM_DESTROY => {
            gui.destroyed = true;
            win32::KillTimer(hwnd, TIMER_ID);
            win32::PostQuitMessage(0);
            0
        }
        _ => win32::DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

pub fn run(config: Config, files: Vec<PathBuf>) -> Result<i32, String> {
    unsafe {
        win32::SetProcessDPIAware();
        // 从控制台进入 GUI 时分离控制台窗口，避免同时出现黑框
        win32::FreeConsole();
        let hinstance = win32::GetModuleHandleW(std::ptr::null());
        let class_name = win32::wide("TextmWindowClass");
        let window_title = win32::wide("Textm 2.0");
        let class = win32::WNDCLASSEXW {
            cbSize: std::mem::size_of::<win32::WNDCLASSEXW>() as u32,
            style: win32::CS_HREDRAW | win32::CS_VREDRAW | win32::CS_DBLCLKS,
            lpfnWndProc: Some(wndproc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hinstance,
            hIcon: std::ptr::null_mut(),
            hCursor: win32::LoadCursorW(
                std::ptr::null_mut(),
                win32::IDC_ARROW as *const u16,
            ),
            hbrBackground: std::ptr::null_mut(),
            lpszMenuName: std::ptr::null(),
            lpszClassName: class_name.as_ptr(),
            hIconSm: std::ptr::null_mut(),
        };
        if win32::RegisterClassExW(&class) == 0 {
            let error = win32::GetLastError();
            if error != 1410 {
                // ERROR_CLASS_ALREADY_EXISTS 可忽略
                return Err(format!("注册窗口类失败（错误码 {error}）"));
            }
        }

        let gui = Box::new(Gui::new(config, files));
        let pointer = Box::into_raw(gui);
        let hwnd = win32::CreateWindowExW(
            0,
            class_name.as_ptr(),
            window_title.as_ptr(),
            win32::WS_OVERLAPPEDWINDOW,
            80,
            60,
            1100,
            760,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            hinstance,
            std::ptr::null_mut(),
        );
        if hwnd.is_null() {
            drop(Box::from_raw(pointer));
            return Err(format!("创建窗口失败（错误码 {}）", win32::GetLastError()));
        }
        win32::SetWindowLongPtrW(hwnd, win32::GWLP_USERDATA, pointer as isize);
        let gui = &mut *pointer;
        gui.hwnd = hwnd;
        let hdc = win32::GetDC(hwnd);
        gui.init(hdc);
        win32::ReleaseDC(hwnd, hdc);
        win32::ShowWindow(hwnd, win32::SW_SHOW);
        win32::UpdateWindow(hwnd);
        win32::SetTimer(hwnd, TIMER_ID, 40, std::ptr::null_mut());
        log::info("GUI 窗口已创建");

        let mut message: win32::MSG = std::mem::zeroed();
        loop {
            let result = win32::GetMessageW(&mut message, std::ptr::null_mut(), 0, 0);
            if result <= 0 {
                break;
            }
            win32::TranslateMessage(&message);
            win32::DispatchMessageW(&message);
            if !gui.app.running && !gui.destroyed {
                win32::DestroyWindow(hwnd);
            }
        }
        drop(Box::from_raw(pointer));
        log::info("GUI 退出");
    }
    Ok(0)
}

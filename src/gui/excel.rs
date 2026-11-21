//! GUI 下的 Excel 高保真网格绘制。
//!
//! 与 TUI 的字符网格不同，这里按像素绘制列宽、行高、字体、填充、边框、
//! 合并单元格与冻结窗格，并负责鼠标命中测试与编辑光标。

use std::collections::HashMap;

use crate::platform::win32::{self, HBRUSH, HDC, HFONT, HGDIOBJ, RECT};
use crate::render::grid::WHITE;
use crate::render::Color;
use crate::ui::app::App;
use crate::xlsx::{Sheet, Value, Workbook};

use super::Gui;

const HEADER_W: i32 = 48;
const HEADER_H: i32 = 22;
const HEADER_BG: Color = Color::rgb(243, 243, 243);
const HEADER_FG: Color = Color::rgb(76, 76, 76);
const GRID: Color = Color::rgb(217, 217, 217);

/// 鼠标命中结果。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ExcelHit {
    Cell(usize, usize),
    ColHeader(usize),
    RowHeader(usize),
    Corner,
    None,
}

/// Excel 渲染与交互缓存，生命周期跟随窗口。
pub struct ExcelView {
    pub scroll_x: i32,
    pub scroll_y: i32,
    pub dragging: bool,
    fonts: HashMap<(String, i32, bool, bool), HFONT>,
    columns: Vec<(usize, i32, i32)>,
    rows: Vec<(usize, i32, i32)>,
    area: (i32, i32, i32, i32),
    tab: usize,
    sheet: usize,
}

impl Default for ExcelView {
    fn default() -> Self {
        ExcelView {
            scroll_x: 0,
            scroll_y: 0,
            dragging: false,
            fonts: HashMap::new(),
            columns: Vec::new(),
            rows: Vec::new(),
            area: (0, 0, 0, 0),
            tab: usize::MAX,
            sheet: usize::MAX,
        }
    }
}

impl Drop for ExcelView {
    fn drop(&mut self) {
        unsafe {
            for (_, font) in self.fonts.drain() {
                win32::DeleteObject(font as HGDIOBJ);
            }
        }
    }
}

fn col_px(sheet: &Sheet, col: usize) -> i32 {
    if sheet.hidden_cols.contains(&col) {
        return 0;
    }
    let width = sheet.col_width(col);
    ((width * 7.0) + 5.0).round().max(12.0) as i32
}

fn row_px(sheet: &Sheet, row: usize) -> i32 {
    if sheet.hidden_rows.contains(&row) || sheet.filtered_rows.contains(&row) {
        return 0;
    }
    let height = sheet.row_height(row);
    ((height * 96.0 / 72.0).round() as i32).max(8)
}

/// 单元格内文字字体像素高度（磅 → 像素）。
fn font_px(size: f32) -> i32 {
    ((size * 96.0 / 72.0).round() as i32).clamp(6, 96)
}

impl ExcelView {
    fn reset_if_switched(&mut self, app: &App, book: &Workbook) {
        if self.tab != app.active || self.sheet != book.active {
            self.scroll_x = 0;
            self.scroll_y = 0;
            self.tab = app.active;
            self.sheet = book.active;
        }
    }

    /// 计算可见列 / 行与滚动范围。
    fn build(&mut self, app: &App, book: &Workbook, ax: i32, ay: i32, aw: i32, ah: i32) {
        self.reset_if_switched(app, book);
        self.area = (ax, ay, aw, ah);
        let sheet = book.sheet();
        self.columns.clear();
        self.rows.clear();
        if aw <= HEADER_W + 4 || ah <= HEADER_H + 4 {
            return;
        }

        // ---- 列几何
        let max_col = (sheet.max_col + 24).clamp(32, 512);
        let mut cum = Vec::with_capacity(max_col + 2);
        cum.push(0i32);
        for col in 0..=max_col {
            let width = col_px(sheet, col);
            cum.push(cum[col] + width);
        }
        let frozen_cols = sheet.freeze_cols.min(max_col + 1);
        let frozen_w = cum[frozen_cols];
        let view_w = (aw - HEADER_W - frozen_w).max(1);
        let scroll_w = (cum[max_col + 1] - frozen_w).max(0);
        self.scroll_x = self.scroll_x.clamp(0, (scroll_w - view_w).max(0));

        let mut x = ax + HEADER_W;
        for col in 0..frozen_cols {
            let width = col_px(sheet, col);
            if width == 0 {
                continue;
            }
            if x + width > ax + aw {
                break;
            }
            self.columns.push((col, x, width));
            x += width;
        }
        let left = ax + HEADER_W + frozen_w;
        let mut col = frozen_cols;
        while col <= max_col {
            let width = col_px(sheet, col);
            if width == 0 {
                col += 1;
                continue;
            }
            let sx = left + (cum[col] - frozen_w) - self.scroll_x;
            if sx + width <= left {
                col += 1;
                continue;
            }
            if sx >= ax + aw {
                break;
            }
            self.columns.push((col, sx, width));
            col += 1;
        }

        // ---- 行几何
        let max_row = (sheet.max_row + 32).clamp(64, 20_000);
        let mut cum = Vec::with_capacity(max_row + 2);
        cum.push(0i32);
        for row in 0..=max_row {
            let height = row_px(sheet, row);
            cum.push(cum[row] + height);
        }
        let frozen_rows = sheet.freeze_rows.min(max_row + 1);
        let frozen_h = cum[frozen_rows];
        let view_h = (ah - HEADER_H - frozen_h).max(1);
        let scroll_h = (cum[max_row + 1] - frozen_h).max(0);
        self.scroll_y = self.scroll_y.clamp(0, (scroll_h - view_h).max(0));

        let mut y = ay + HEADER_H;
        for row in 0..frozen_rows {
            let height = row_px(sheet, row);
            if height == 0 {
                continue;
            }
            if y + height > ay + ah {
                break;
            }
            self.rows.push((row, y, height));
            y += height;
        }
        let top = ay + HEADER_H + frozen_h;
        let mut row = frozen_rows;
        while row <= max_row {
            let height = row_px(sheet, row);
            if height == 0 {
                row += 1;
                continue;
            }
            let sy = top + (cum[row] - frozen_h) - self.scroll_y;
            if sy + height <= top {
                row += 1;
                continue;
            }
            if sy >= ay + ah {
                break;
            }
            self.rows.push((row, sy, height));
            row += 1;
        }
    }

    /// 像素坐标 → 单元格 / 表头。
    pub fn hit(&self, x: i32, y: i32) -> ExcelHit {
        let (ax, ay, aw, ah) = self.area;
        if x < ax || y < ay || x >= ax + aw || y >= ay + ah {
            return ExcelHit::None;
        }
        let header_x = ax + HEADER_W;
        let header_y = ay + HEADER_H;
        if y < header_y && x < header_x {
            return ExcelHit::Corner;
        }
        if y < header_y {
            for &(col, left, width) in &self.columns {
                if x >= left && x < left + width {
                    return ExcelHit::ColHeader(col);
                }
            }
            return ExcelHit::None;
        }
        if x < header_x {
            for &(row, top, height) in &self.rows {
                if y >= top && y < top + height {
                    return ExcelHit::RowHeader(row);
                }
            }
            return ExcelHit::None;
        }
        let mut col = None;
        for &(index, left, width) in &self.columns {
            if x >= left && x < left + width {
                col = Some(index);
                break;
            }
        }
        let mut row = None;
        for &(index, top, height) in &self.rows {
            if y >= top && y < top + height {
                row = Some(index);
                break;
            }
        }
        match (row, col) {
            (Some(row), Some(col)) => ExcelHit::Cell(row, col),
            _ => ExcelHit::None,
        }
    }

    /// 键盘移动后保证活动单元格可见。
    pub fn ensure_visible(&mut self, app: &App, book: &Workbook) {
        let (ax, ay, aw, ah) = self.area;
        if aw <= 0 || ah <= 0 {
            return;
        }
        self.reset_if_switched(app, book);
        let sheet = book.sheet();
        let (row, col) = (app.excel_row, app.excel_col);

        let max_col = (sheet.max_col + 24).clamp(32, 512);
        let target_col = col.min(max_col);
        let mut cum = 0i32;
        for index in 0..target_col {
            cum += col_px(sheet, index);
        }
        let width = col_px(sheet, target_col).max(1);
        let frozen_cols = sheet.freeze_cols.min(max_col + 1);
        let frozen_w: i32 = (0..frozen_cols).map(|index| col_px(sheet, index)).sum();
        let view_w = (aw - HEADER_W - frozen_w).max(1);
        if target_col >= frozen_cols {
            let relative = cum
                - (0..frozen_cols)
                    .map(|index| col_px(sheet, index))
                    .sum::<i32>();
            if relative < self.scroll_x {
                self.scroll_x = relative.max(0);
            } else if relative + width > self.scroll_x + view_w {
                self.scroll_x = relative + width - view_w;
            }
        }

        let max_row = (sheet.max_row + 32).clamp(64, 20_000);
        let target_row = row.min(max_row);
        let mut cum = 0i32;
        for index in 0..target_row {
            cum += row_px(sheet, index);
        }
        let height = row_px(sheet, target_row).max(1);
        let frozen_rows = sheet.freeze_rows.min(max_row + 1);
        let frozen_h: i32 = (0..frozen_rows).map(|index| row_px(sheet, index)).sum();
        let view_h = (ah - HEADER_H - frozen_h).max(1);
        if target_row >= frozen_rows {
            let relative = cum - frozen_h;
            if relative < self.scroll_y {
                self.scroll_y = relative.max(0);
            } else if relative + height > self.scroll_y + view_h {
                self.scroll_y = relative + height - view_h;
            }
        }
        let _ = (ax, ay);
    }
}

/// 用画刷填充矩形（避免借用整个 `Gui`）。
unsafe fn fill_rect(
    dc: HDC,
    brushes: &mut HashMap<u32, HBRUSH>,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: Color,
) {
    if w <= 0 || h <= 0 {
        return;
    }
    let key = (color.r as u32) | ((color.g as u32) << 8) | ((color.b as u32) << 16);
    let brush = match brushes.get(&key) {
        Some(brush) => *brush,
        None => {
            let brush = win32::CreateSolidBrush(key);
            brushes.insert(key, brush);
            brush
        }
    };
    let rect = RECT {
        left: x,
        top: y,
        right: x + w,
        bottom: y + h,
    };
    win32::FillRect(dc, &rect, brush);
}

/// 绘制一段被裁剪的文本。
unsafe fn text_out(
    dc: HDC,
    font: HFONT,
    text: &str,
    x: i32,
    y: i32,
    color: Color,
    align: u32,
    clip: &RECT,
) {
    if text.is_empty() {
        return;
    }
    let old = win32::SelectObject(dc, font as HGDIOBJ);
    win32::SetTextColor(dc, win32::colorref(color.r, color.g, color.b));
    win32::SetTextAlign(dc, align);
    let wide = win32::wide(text);
    win32::ExtTextOutW(
        dc,
        x,
        y,
        win32::ETO_CLIPPED,
        clip,
        wide.as_ptr(),
        wide.len() as i32,
        std::ptr::null(),
    );
    win32::SetTextAlign(dc, win32::TA_LEFT);
    win32::SelectObject(dc, old);
}

unsafe fn text_width(dc: HDC, font: HFONT, text: &str) -> i32 {
    if text.is_empty() {
        return 0;
    }
    let old = win32::SelectObject(dc, font as HGDIOBJ);
    let wide = win32::wide(text);
    let mut size = win32::SIZE::default();
    win32::GetTextExtentPoint32W(dc, wide.as_ptr(), wide.len() as i32, &mut size);
    win32::SelectObject(dc, old);
    size.cx
}

/// 合并区域在可见布局中的像素矩形。
fn merged_rect(
    sheet: &Sheet,
    row: usize,
    col: usize,
    columns: &[(usize, i32, i32)],
    rows: &[(usize, i32, i32)],
) -> Option<(i32, i32, i32, i32)> {
    let range = sheet.merge_at(row, col)?;
    if range.r1 != row || range.c1 != col {
        return None;
    }
    let mut left = None;
    let mut right = 0;
    for &(index, x, width) in columns {
        if index >= range.c1 && index <= range.c2 {
            if left.is_none() {
                left = Some(x);
            }
            right = x + width;
        }
    }
    let mut top = None;
    let mut bottom = 0;
    for &(index, y, height) in rows {
        if index >= range.r1 && index <= range.r2 {
            if top.is_none() {
                top = Some(y);
            }
            bottom = y + height;
        }
    }
    match (left, top) {
        (Some(left), Some(top)) => Some((left, top, right - left, bottom - top)),
        _ => None,
    }
}

impl Gui {
    /// 在 Canvas 之上叠加 Excel 网格。
    pub(super) unsafe fn paint_excel(&mut self) {
        let Some(book) = self.app.tab().excel.as_ref() else {
            return;
        };
        let area = self.app.layout.text;
        if area.w == 0 || area.h == 0 {
            return;
        }
        let ax = area.x as i32 * self.cell_w;
        let ay = area.y as i32 * self.cell_h;
        let mut aw = area.w as i32 * self.cell_w;
        // Excel 不使用小地图，把它并入表格区域，避免右侧留下空白条。
        if let Some(minimap) = self.app.layout.minimap {
            aw = (minimap.x + minimap.w - area.x) as i32 * self.cell_w;
        }
        let ah = area.h as i32 * self.cell_h;

        self.excel_view.build(&self.app, book, ax, ay, aw, ah);
        let columns = self.excel_view.columns.clone();
        let rows = self.excel_view.rows.clone();
        let sheet = book.sheet();
        let active = book.active;

        let dc = self.mem_dc;
        let brushes = &mut self.brushes;
        let fonts = &mut self.excel_view.fonts;
        let accent = self.app.theme.accent;
        let selection_bg = WHITE.blend(accent, 46);
        let selection = self.app.excel_range();
        let editing = self.app.excel_editing;
        let (active_row, active_col) = (self.app.excel_row, self.app.excel_col);
        let cursor_visible = self.app.cursor_visible;
        let base_font = self.font;

        let saved = win32::SaveDC(dc);
        win32::IntersectClipRect(dc, ax, ay, ax + aw, ay + ah);
        win32::SetBkMode(dc, win32::TRANSPARENT);
        fill_rect(dc, brushes, ax, ay, aw, ah, WHITE);

        // 表头背景
        fill_rect(dc, brushes, ax, ay, aw, HEADER_H, HEADER_BG);
        fill_rect(dc, brushes, ax, ay, HEADER_W, ah, HEADER_BG);

        // 列标题
        for &(col, x, width) in &columns {
            let current = col == active_col;
            let in_range = col >= selection.c1 && col <= selection.c2;
            if current {
                fill_rect(dc, brushes, x, ay, width, HEADER_H, selection_bg);
            }
            fill_rect(dc, brushes, x + width - 1, ay, 1, HEADER_H, GRID);
            let clip = RECT {
                left: x + 2,
                top: ay + 3,
                right: x + width - 2,
                bottom: ay + HEADER_H - 2,
            };
            let color = if current {
                accent
            } else if in_range {
                accent
            } else {
                HEADER_FG
            };
            let label = crate::xlsx::column_name(col);
            let w = text_width(dc, base_font, &label);
            text_out(
                dc,
                base_font,
                &label,
                x + (width - w) / 2,
                ay + 4,
                color,
                0,
                &clip,
            );
        }

        // 行号
        for &(row, y, height) in &rows {
            let current = row == active_row;
            let in_range = row >= selection.r1 && row <= selection.r2;
            if current {
                fill_rect(dc, brushes, ax, y, HEADER_W, height, selection_bg);
            }
            fill_rect(dc, brushes, ax, y + height - 1, HEADER_W, 1, GRID);
            let clip = RECT {
                left: ax + 2,
                top: y,
                right: ax + HEADER_W - 4,
                bottom: y + height,
            };
            let color = if current || in_range { accent } else { HEADER_FG };
            let label = (row + 1).to_string();
            text_out(
                dc,
                base_font,
                &label,
                ax + HEADER_W - 6,
                y + (height - font_px(11.0)) / 2,
                color,
                win32::TA_RIGHT,
                &clip,
            );
        }

        // 表头分隔线
        fill_rect(dc, brushes, ax, ay + HEADER_H - 1, aw, 1, GRID);
        fill_rect(dc, brushes, ax + HEADER_W - 1, ay, 1, ah, GRID);

        // 单元格
        for &(row, y, height) in &rows {
            for &(col, x, width) in &columns {
                let range = sheet.merge_at(row, col);
                if let Some(range) = range {
                    if range.r1 != row || range.c1 != col {
                        continue;
                    }
                }
                let (cx, cy, cw, ch) = match range {
                    Some(_) => match merged_rect(sheet, row, col, &columns, &rows) {
                        Some(rect) => rect,
                        None => continue,
                    },
                    None => (x, y, width, height),
                };
                if cw < 2 || ch < 2 {
                    continue;
                }

                let style = book.style_at(active, row, col);
                let selected = row >= selection.r1
                    && row <= selection.r2
                    && col >= selection.c1
                    && col <= selection.c2;
                let bg = if selected { selection_bg } else { style.fill };
                fill_rect(dc, brushes, cx, cy, cw, ch, bg);

                // 网格线 / 单元格边框
                let border = &style.border;
                let bottom = if border.bottom.visible() {
                    border.bottom.color
                } else {
                    GRID
                };
                let right = if border.right.visible() {
                    border.right.color
                } else {
                    GRID
                };
                fill_rect(dc, brushes, cx, cy + ch - 1, cw, 1, bottom);
                fill_rect(dc, brushes, cx + cw - 1, cy, 1, ch, right);
                if border.top.visible() {
                    fill_rect(dc, brushes, cx, cy, cw, 1, border.top.color);
                }
                if border.left.visible() {
                    fill_rect(dc, brushes, cx, cy, 1, ch, border.left.color);
                }

                let value = if selected && editing && row == active_row && col == active_col {
                    self.app.excel_input.clone()
                } else {
                    book.display(active, row, col)
                };
                if value.is_empty() {
                    continue;
                }
                let font = fonts
                    .entry((
                        style.font.name.clone(),
                        font_px(style.font.size),
                        style.font.bold,
                        style.font.italic,
                    ))
                    .or_insert_with(|| {
                        let face = win32::wide(&style.font.name);
                        win32::CreateFontW(
                            -font_px(style.font.size),
                            0,
                            0,
                            0,
                            if style.font.bold { 700 } else { 400 },
                            if style.font.italic { 1 } else { 0 },
                            0,
                            0,
                            1,
                            0,
                            0,
                            0,
                            0,
                            face.as_ptr(),
                        )
                    });
                let font = *font;
                let align = if !style.h_align.is_empty() {
                    style.h_align.as_str()
                } else if matches!(book.value(active, row, col), Value::Number(_)) {
                    "right"
                } else {
                    "left"
                };
                let clip = RECT {
                    left: cx + 3,
                    top: cy + 1,
                    right: cx + cw - 3,
                    bottom: cy + ch - 1,
                };
                let text_h = font_px(style.font.size);
                let ty = cy + (ch - text_h) / 2;
                let color = style.text_color;
                if align == "right" {
                    text_out(
                        dc,
                        font,
                        &value,
                        cx + cw - 4,
                        ty,
                        color,
                        win32::TA_RIGHT,
                        &clip,
                    );
                } else if align == "center" {
                    let w = text_width(dc, font, &value);
                    text_out(
                        dc,
                        font,
                        &value,
                        cx + (cw - w) / 2,
                        ty,
                        color,
                        0,
                        &clip,
                    );
                } else {
                    text_out(dc, font, &value, cx + 4, ty, color, 0, &clip);
                }

                // 编辑光标
                if selected
                    && editing
                    && row == active_row
                    && col == active_col
                    && cursor_visible
                {
                    let w = text_width(dc, font, &value);
                    let caret_x = (cx + 4 + w).min(cx + cw - 4);
                    fill_rect(dc, brushes, caret_x, cy + 2, 2, ch - 5, accent);
                }
            }
        }

        // 活动单元格边框（合并区域取整体）
        if let Some((cx, cy, cw, ch)) =
            merged_rect(sheet, active_row, active_col, &columns, &rows)
        {
            fill_rect(dc, brushes, cx, cy, cw, 2, accent);
            fill_rect(dc, brushes, cx, cy + ch - 2, cw, 2, accent);
            fill_rect(dc, brushes, cx, cy, 2, ch, accent);
            fill_rect(dc, brushes, cx + cw - 2, cy, 2, ch, accent);
        } else if let Some((cx, cy, cw, ch)) = cell_rect(&columns, &rows, active_row, active_col) {
            fill_rect(dc, brushes, cx, cy, cw, 2, accent);
            fill_rect(dc, brushes, cx, cy + ch - 2, cw, 2, accent);
            fill_rect(dc, brushes, cx, cy, 2, ch, accent);
            fill_rect(dc, brushes, cx + cw - 2, cy, 2, ch, accent);
        }

        win32::RestoreDC(dc, saved);
    }

    /// Excel 标签页的鼠标事件；返回 true 表示已消费。
    pub(super) unsafe fn excel_mouse(&mut self, msg: u32, wparam: usize, x: i32, y: i32) -> bool {
        if self.app.tab().excel.is_none() {
            return false;
        }
        let (ax, ay, aw, ah) = self.excel_view.area;
        let inside = x >= ax && y >= ay && x < ax + aw && y < ay + ah;

        if msg == win32::WM_MOUSEWHEEL {
            if !inside {
                return false;
            }
            let delta = ((wparam >> 16) as u16 as i16) / 120;
            let shift = win32::GetKeyState(win32::VK_SHIFT) < 0;
            if shift {
                self.excel_view.scroll_x =
                    (self.excel_view.scroll_x - delta as i32 * 64).max(0);
            } else {
                self.excel_view.scroll_y =
                    (self.excel_view.scroll_y - delta as i32 * 60).max(0);
            }
            return true;
        }

        if !inside {
            if msg == win32::WM_LBUTTONUP {
                self.excel_view.dragging = false;
            }
            return false;
        }

        let shift = win32::GetKeyState(win32::VK_SHIFT) < 0;
        let hit = self.excel_view.hit(x, y);
        match msg {
            win32::WM_LBUTTONDOWN => {
                if self.app.excel_editing {
                    self.app.excel_commit_edit();
                }
                match hit {
                    ExcelHit::Cell(row, col) => {
                        self.app.excel_select(row, col, shift);
                        self.excel_view.dragging = true;
                    }
                    ExcelHit::ColHeader(col) => {
                        let bound = self
                            .app
                            .tab()
                            .excel
                            .as_ref()
                            .map(|book| book.sheet().max_row)
                            .unwrap_or(0);
                        self.app.excel_anchor = Some((0, col));
                        self.app.excel_select(bound, col, true);
                        self.excel_view.dragging = true;
                    }
                    ExcelHit::RowHeader(row) => {
                        let bound = self
                            .app
                            .tab()
                            .excel
                            .as_ref()
                            .map(|book| book.sheet().max_col)
                            .unwrap_or(0);
                        self.app.excel_anchor = Some((row, 0));
                        self.app.excel_select(row, bound, true);
                        self.excel_view.dragging = true;
                    }
                    ExcelHit::Corner => {
                        self.app.excel_select_all();
                    }
                    ExcelHit::None => {}
                }
                true
            }
            win32::WM_MOUSEMOVE => {
                if self.excel_view.dragging {
                    if let ExcelHit::Cell(row, col) = hit {
                        self.app.excel_select(row, col, true);
                    }
                    return true;
                }
                false
            }
            win32::WM_LBUTTONUP => {
                self.excel_view.dragging = false;
                true
            }
            win32::WM_LBUTTONDBLCLK => {
                if let ExcelHit::Cell(row, col) = hit {
                    self.app.excel_select(row, col, false);
                    self.app.excel_begin_edit();
                }
                true
            }
            _ => false,
        }
    }
}

/// 可见单元格矩形（x, y, 宽, 高）。
fn cell_rect(
    columns: &[(usize, i32, i32)],
    rows: &[(usize, i32, i32)],
    row: usize,
    col: usize,
) -> Option<(i32, i32, i32, i32)> {
    let (x, width) = columns
        .iter()
        .find(|(index, _, _)| *index == col)
        .map(|(_, x, width)| (*x, *width))?;
    let (y, height) = rows
        .iter()
        .find(|(index, _, _)| *index == row)
        .map(|(_, y, height)| (*y, *height))?;
    Some((x, y, width, height))
}

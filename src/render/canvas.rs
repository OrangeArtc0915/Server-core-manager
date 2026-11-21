//! 画布：在网格上绘制文本、矩形与边框。

use super::grid::{attr, Cell, Color, Grid};
use crate::core::unicode::char_width;

pub struct Canvas {
    pub grid: Grid,
}

impl Canvas {
    pub fn new(cols: usize, rows: usize, bg: Color) -> Canvas {
        Canvas {
            grid: Grid::new(cols, rows, bg),
        }
    }

    pub fn clear(&mut self, bg: Color) {
        self.grid.fill(bg);
    }

    pub fn put(&mut self, x: usize, y: usize, ch: char, fg: Color, bg: Color) {
        if ch == '\t' {
            self.put(x, y, ' ', fg, bg);
            return;
        }
        let width = char_width(ch);
        if width == 0 {
            return; // 组合字符暂时不叠加
        }
        let mut cell = Cell::new(ch, fg, bg);
        if width == 2 {
            cell.wide = true;
        }
        self.grid.set(x, y, cell);
        if width == 2 {
            self.grid.mark_continuation(x + 1, y, bg);
        }
    }

    pub fn put_styled(&mut self, x: usize, y: usize, ch: char, fg: Color, bg: Color, attr: u8) {
        self.put(x, y, ch, fg, bg);
        if let Some(i) = self.grid.idx(x, y) {
            self.grid.cells[i].attr = attr;
        }
    }

    pub fn fill_rect(&mut self, x: usize, y: usize, w: usize, h: usize, bg: Color) {
        for row in y..y + h {
            for col in x..x + w {
                self.grid.set(col, row, Cell::blank(bg));
            }
        }
    }

    pub fn fill_rect_styled(&mut self, x: usize, y: usize, w: usize, h: usize, cell: Cell) {
        for row in y..y + h {
            for col in x..x + w {
                self.grid.set(col, row, cell);
            }
        }
    }

    /// 只改背景色（用于宽字符第二格跟随底色）。
    pub fn set_cell_bg(&mut self, x: usize, y: usize, bg: Color) {
        if let Some(index) = self.grid.idx(x, y) {
            self.grid.cells[index].bg = bg;
        }
    }

    /// 绘制字符串，返回占用的列数。超出边界自动截断。
    pub fn text(&mut self, x: usize, y: usize, text: &str, fg: Color, bg: Color) -> usize {
        self.text_styled(x, y, text, fg, bg, 0)
    }

    pub fn text_styled(
        &mut self,
        x: usize,
        y: usize,
        text: &str,
        fg: Color,
        bg: Color,
        style: u8,
    ) -> usize {
        let mut col = x;
        for ch in text.chars() {
            if ch == '\n' || ch == '\r' {
                continue;
            }
            if col >= self.grid.cols || y >= self.grid.rows {
                break;
            }
            let width = char_width(ch).max(1);
            if col + width > self.grid.cols {
                break;
            }
            self.put_styled(col, y, ch, fg, bg, style);
            col += width;
        }
        col - x
    }

    /// 在限定宽度内绘制，返回实际列数。
    pub fn text_max(
        &mut self,
        x: usize,
        y: usize,
        max: usize,
        text: &str,
        fg: Color,
        bg: Color,
    ) -> usize {
        self.text_max_styled(x, y, max, text, fg, bg, 0)
    }

    pub fn text_max_styled(
        &mut self,
        x: usize,
        y: usize,
        max: usize,
        text: &str,
        fg: Color,
        bg: Color,
        style: u8,
    ) -> usize {
        let mut col = 0;
        for ch in text.chars() {
            if ch == '\n' || ch == '\r' {
                continue;
            }
            let width = char_width(ch).max(1);
            if col + width > max || x + col + width > self.grid.cols {
                break;
            }
            self.put_styled(x + col, y, ch, fg, bg, style);
            col += width;
        }
        col
    }

    /// 右对齐文本。
    pub fn text_right(&mut self, right: usize, y: usize, text: &str, fg: Color, bg: Color) {
        let width = text_width(text);
        if width >= right {
            self.text_max(right.saturating_sub(width), y, right, text, fg, bg);
        } else {
            self.text(right - width, y, text, fg, bg);
        }
    }

    pub fn hline(&mut self, x: usize, y: usize, w: usize, ch: char, fg: Color, bg: Color) {
        for i in 0..w {
            self.put(x + i, y, ch, fg, bg);
        }
    }

    pub fn vline(&mut self, x: usize, y: usize, h: usize, ch: char, fg: Color, bg: Color) {
        for i in 0..h {
            self.put(x, y + i, ch, fg, bg);
        }
    }

    /// 单线边框（四角用圆角字符，接近 VSCode 面板）。
    pub fn border(&mut self, x: usize, y: usize, w: usize, h: usize, fg: Color, bg: Color) {
        if w < 2 || h < 2 {
            return;
        }
        self.put_styled(x, y, '┌', fg, bg, attr::DIM);
        self.put_styled(x + w - 1, y, '┐', fg, bg, attr::DIM);
        self.put_styled(x, y + h - 1, '└', fg, bg, attr::DIM);
        self.put_styled(x + w - 1, y + h - 1, '┘', fg, bg, attr::DIM);
        for i in 1..w - 1 {
            self.put_styled(x + i, y, '─', fg, bg, attr::DIM);
            self.put_styled(x + i, y + h - 1, '─', fg, bg, attr::DIM);
        }
        for i in 1..h - 1 {
            self.put_styled(x, y + i, '│', fg, bg, attr::DIM);
            self.put_styled(x + w - 1, y + i, '│', fg, bg, attr::DIM);
        }
    }

    pub fn cols(&self) -> usize {
        self.grid.cols
    }

    pub fn rows(&self) -> usize {
        self.grid.rows
    }
}

/// 字符串显示宽度（不含换行）。
pub fn text_width(text: &str) -> usize {
    text.chars().map(|c| char_width(c).max(1)).sum()
}

//! 单元格网格与颜色。

/// 24 位真彩色。
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Color {
    pub const fn rgb(r: u8, g: u8, b: u8) -> Color {
        Color { r, g, b }
    }

    /// 与另一种颜色按 `t`（0..=255）线性混合。
    pub fn blend(self, other: Color, t: u8) -> Color {
        let t = t as u32;
        let inv = 255 - t;
        Color {
            r: ((self.r as u32 * inv + other.r as u32 * t) / 255) as u8,
            g: ((self.g as u32 * inv + other.g as u32 * t) / 255) as u8,
            b: ((self.b as u32 * inv + other.b as u32 * t) / 255) as u8,
        }
    }

    /// 变暗 / 变亮（factor > 1 变亮）。
    pub fn scale(self, factor: f32) -> Color {
        let clamp = |v: u8| ((v as f32 * factor).round() as i32).clamp(0, 255) as u8;
        Color {
            r: clamp(self.r),
            g: clamp(self.g),
            b: clamp(self.b),
        }
    }

    /// `#rrggbb`。
    pub fn hex(self) -> String {
        format!("#{:02x}{:02x}{:02x}", self.r, self.g, self.b)
    }

    pub fn parse_hex(text: &str) -> Option<Color> {
        let text = text.trim().trim_start_matches('#');
        if text.len() != 6 {
            return None;
        }
        let r = u8::from_str_radix(&text[0..2], 16).ok()?;
        let g = u8::from_str_radix(&text[2..4], 16).ok()?;
        let b = u8::from_str_radix(&text[4..6], 16).ok()?;
        Some(Color::rgb(r, g, b))
    }
}

pub const WHITE: Color = Color::rgb(255, 255, 255);
pub const BLACK: Color = Color::rgb(0, 0, 0);

/// 字符属性位。
pub mod attr {
    pub const BOLD: u8 = 1;
    pub const DIM: u8 = 2;
    pub const ITALIC: u8 = 4;
    pub const UNDERLINE: u8 = 8;
    pub const REVERSE: u8 = 16;
    pub const STRIKE: u8 = 32;
}

/// 一个终端单元。宽字符占两格：第一格 `wide=true`，第二格 `cont=true`。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Cell {
    pub ch: char,
    pub fg: Color,
    pub bg: Color,
    pub attr: u8,
    pub wide: bool,
    pub cont: bool,
}

impl Default for Cell {
    fn default() -> Self {
        Cell {
            ch: ' ',
            fg: WHITE,
            bg: BLACK,
            attr: 0,
            wide: false,
            cont: false,
        }
    }
}

impl Cell {
    pub fn new(ch: char, fg: Color, bg: Color) -> Cell {
        Cell {
            ch,
            fg,
            bg,
            ..Cell::default()
        }
    }

    pub fn blank(bg: Color) -> Cell {
        Cell {
            bg,
            ..Cell::default()
        }
    }
}

/// 固定大小的网格。变更检测由后端做（TUI 比较上一帧，GUI 只重绘脏行）。
#[derive(Clone)]
pub struct Grid {
    pub cols: usize,
    pub rows: usize,
    pub cells: Vec<Cell>,
}

impl Grid {
    pub fn new(cols: usize, rows: usize, bg: Color) -> Grid {
        Grid {
            cols,
            rows,
            cells: vec![Cell::blank(bg); cols.max(1) * rows.max(1)],
        }
    }

    pub fn resize(&mut self, cols: usize, rows: usize, bg: Color) {
        if cols == self.cols && rows == self.rows {
            return;
        }
        self.cols = cols.max(1);
        self.rows = rows.max(1);
        self.cells = vec![Cell::blank(bg); self.cols * self.rows];
    }

    #[inline]
    pub fn idx(&self, x: usize, y: usize) -> Option<usize> {
        if x < self.cols && y < self.rows {
            Some(y * self.cols + x)
        } else {
            None
        }
    }

    #[inline]
    pub fn get(&self, x: usize, y: usize) -> Option<&Cell> {
        self.idx(x, y).map(|i| &self.cells[i])
    }

    #[inline]
    pub fn set(&mut self, x: usize, y: usize, cell: Cell) {
        if let Some(i) = self.idx(x, y) {
            self.cells[i] = cell;
        }
    }

    pub fn fill(&mut self, bg: Color) {
        for cell in &mut self.cells {
            *cell = Cell::blank(bg);
        }
    }

    /// 把宽字符的第二个单元标成占位，避免后端重复绘制。
    pub fn mark_continuation(&mut self, x: usize, y: usize, bg: Color) {
        if let Some(i) = self.idx(x, y) {
            self.cells[i] = Cell::blank(bg);
            self.cells[i].cont = true;
        }
    }
}

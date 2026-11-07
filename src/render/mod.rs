//! 差异渲染：把合成后的画布与上次绘制结果比对，只输出变化的部分。

use crate::emulation::screen::{
    combining_text, Attrs, Cell, Color, ATTR_BLINK, ATTR_BOLD, ATTR_DIM, ATTR_HIDDEN, ATTR_ITALIC,
    ATTR_REVERSE, ATTR_STRIKE, ATTR_UNDERLINE, ATTR_WIDE_TAIL,
};

pub struct Renderer {
    prev: Vec<Cell>,
    cols: usize,
    rows: usize,
    prev_cursor: Option<(usize, usize)>,
    prev_cursor_shape: u8,
    default_fg: Option<Color>,
    default_bg: Option<Color>,
    /// 当前配色的 16 色 ANSI 调色板；`None` 时把 `Indexed(0..16)` 交给宿主终端。
    palette: Option<[Color; 16]>,
    truecolor: bool,
    initialized: bool,
}

/// 渐变方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GradientDir {
    Vertical,
    Horizontal,
    Diagonal,
}

/// 背景渐变：按行列位置在两端颜色之间线性插值。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Gradient {
    pub from: (u8, u8, u8),
    pub to: (u8, u8, u8),
    pub dir: GradientDir,
}

impl Gradient {
    pub fn new(from: (u8, u8, u8), to: (u8, u8, u8), dir: GradientDir) -> Gradient {
        Gradient { from, to, dir }
    }

    /// 某个单元格的背景色。
    pub fn at(&self, x: usize, y: usize, cols: usize, rows: usize) -> Color {
        let ratio = match self.dir {
            GradientDir::Vertical => {
                if rows <= 1 {
                    0.0
                } else {
                    y as f32 / (rows - 1) as f32
                }
            }
            GradientDir::Horizontal => {
                if cols <= 1 {
                    0.0
                } else {
                    x as f32 / (cols - 1) as f32
                }
            }
            GradientDir::Diagonal => {
                let span = cols.saturating_sub(1) + rows.saturating_sub(1);
                if span == 0 {
                    0.0
                } else {
                    (x + y) as f32 / span as f32
                }
            }
        };
        let mix = |a: u8, b: u8| -> u8 {
            (a as f32 + (b as f32 - a as f32) * ratio).round().clamp(0.0, 255.0) as u8
        };
        Color::Rgb(
            mix(self.from.0, self.to.0),
            mix(self.from.1, self.to.1),
            mix(self.from.2, self.to.2),
        )
    }
}

/// 把颜色朝白色/黑色混合，用于从配色方案背景自动推导渐变端色。
pub fn tint(rgb: (u8, u8, u8), target: u8, amount: f32) -> (u8, u8, u8) {
    let mix = |v: u8| -> u8 {
        (v as f32 + (target as f32 - v as f32) * amount)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    (mix(rgb.0), mix(rgb.1), mix(rgb.2))
}

impl Default for Renderer {
    fn default() -> Self {
        Renderer::new()
    }
}

impl Renderer {
    pub fn new() -> Renderer {
        Renderer {
            prev: Vec::new(),
            cols: 0,
            rows: 0,
            prev_cursor: None,
            prev_cursor_shape: 0,
            default_fg: None,
            default_bg: None,
            palette: None,
            truecolor: true,
            initialized: false,
        }
    }

    pub fn set_scheme(
        &mut self,
        fg: Option<Color>,
        bg: Option<Color>,
        palette: Option<[Color; 16]>,
    ) {
        self.default_fg = fg;
        self.default_bg = bg;
        self.palette = palette;
    }

    pub fn set_truecolor(&mut self, enabled: bool) {
        self.truecolor = enabled;
    }

    pub fn invalidate(&mut self) {
        self.initialized = false;
    }

    /// 绘制画布；`cursor` 为 `None` 表示隐藏光标。
    pub fn paint(
        &mut self,
        canvas: &[Cell],
        cols: usize,
        rows: usize,
        cursor: Option<(usize, usize)>,
        cursor_shape: u8,
    ) -> Vec<u8> {
        let mut out: Vec<u8> = Vec::with_capacity(4096);
        let full = !self.initialized
            || self.cols != cols
            || self.rows != rows
            || self.prev.len() != canvas.len();

        if full {
            out.extend_from_slice(b"\x1b[?25l\x1b[0m\x1b[?7l\x1b[2J");
            self.prev = vec![Cell::default(); canvas.len()];
            self.cols = cols;
            self.rows = rows;
            self.initialized = true;
            self.prev_cursor = None;
        }

        for y in 0..rows {
            let row = y * cols;
            let mut x = 0;
            while x < cols {
                if x < self.prev.len() - row
                    && row + x < canvas.len()
                    && canvas[row + x] == self.prev[row + x]
                {
                    x += 1;
                    continue;
                }
                // 变化点落在宽字符右半格时，回退到首格一起重画。
                let mut start = x;
                let mut force_head = false;
                while start > 0 && canvas[row + start].attrs.flags & ATTR_WIDE_TAIL != 0 {
                    start -= 1;
                    force_head = true;
                }
                out.extend_from_slice(b"\x1b[");
                push_num(&mut out, y + 1);
                out.push(b';');
                push_num(&mut out, start + 1);
                out.push(b'H');

                let mut last_attrs: Option<Attrs> = None;
                let mut cx = start;
                while cx < cols && row + cx < canvas.len() {
                    let cell = canvas[row + cx];
                    let changed = cell != self.prev[row + cx];
                    if !changed && !(force_head && cx == start) {
                        break;
                    }
                    force_head = false;
                    self.prev[row + cx] = cell;
                    if cell.attrs.flags & ATTR_WIDE_TAIL != 0 {
                        cx += 1;
                        continue;
                    }
                    if last_attrs != Some(cell.attrs) {
                        self.write_sgr(&mut out, cell.attrs);
                        last_attrs = Some(cell.attrs);
                    }
                    let hidden = cell.attrs.flags & ATTR_HIDDEN != 0;
                    let ch = if hidden { ' ' } else { cell.ch };
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                    // 组合符紧跟在基字符后面输出，由宿主终端自己叠加。
                    if !hidden && cell.combining != 0 {
                        if let Some(marks) = combining_text(cell.combining) {
                            out.extend_from_slice(marks.as_bytes());
                        }
                    }
                    cx += 1;
                }
                x = cx.max(x + 1);
            }
        }

        match cursor {
            Some((cx, cy)) => {
                out.extend_from_slice(b"\x1b[");
                push_num(&mut out, cy + 1);
                out.push(b';');
                push_num(&mut out, cx + 1);
                out.push(b'H');
                out.extend_from_slice(b"\x1b[?25h");
                self.prev_cursor = Some((cx, cy));
            }
            None => {
                out.extend_from_slice(b"\x1b[?25l");
                self.prev_cursor = None;
            }
        }
        if cursor_shape != self.prev_cursor_shape && cursor_shape > 0 {
            out.extend_from_slice(b"\x1b[");
            push_num(&mut out, cursor_shape as usize);
            out.extend_from_slice(b" q");
            self.prev_cursor_shape = cursor_shape;
        }
        out.extend_from_slice(b"\x1b[0m\x1b[?7h");
        out
    }

    fn write_sgr(&self, out: &mut Vec<u8>, attrs: Attrs) {
        out.extend_from_slice(b"\x1b[0");
        let f = attrs.flags;
        if f & ATTR_BOLD != 0 {
            out.extend_from_slice(b";1");
        }
        if f & ATTR_DIM != 0 {
            out.extend_from_slice(b";2");
        }
        if f & ATTR_ITALIC != 0 {
            out.extend_from_slice(b";3");
        }
        if f & ATTR_UNDERLINE != 0 {
            out.extend_from_slice(b";4");
        }
        if f & ATTR_BLINK != 0 {
            out.extend_from_slice(b";5");
        }
        if f & ATTR_REVERSE != 0 {
            out.extend_from_slice(b";7");
        }
        if f & ATTR_STRIKE != 0 {
            out.extend_from_slice(b";9");
        }
        self.push_color(out, attrs.bg, self.default_bg, false);
        self.push_color(out, attrs.fg, self.default_fg, true);
        out.push(b'm');
    }

    fn push_color(&self, out: &mut Vec<u8>, color: Color, default: Option<Color>, foreground: bool) {
        let base: u8 = if foreground { 38 } else { 48 };
        let resolved = if color == Color::Default {
            match default {
                Some(c) => c,
                None => return,
            }
        } else {
            color
        };
        match resolved {
            Color::Default => {}
            Color::Indexed(i) => {
                // 0..16 用配色自带的 ANSI 调色板；16..256 用标准 xterm 色表。
                if i < 16 {
                    if let Some(Color::Rgb(r, g, b)) = self.palette.map(|p| p[i as usize]) {
                        self.push_rgb(out, base, r, g, b);
                    } else {
                        out.extend_from_slice(format!(";{base};5;{i}").as_bytes());
                    }
                } else if self.truecolor {
                    let (r, g, b) = xterm_rgb(i);
                    self.push_rgb(out, base, r, g, b);
                } else {
                    out.extend_from_slice(format!(";{base};5;{i}").as_bytes());
                }
            }
            Color::Rgb(r, g, b) => self.push_rgb(out, base, r, g, b),
        }
    }

    fn push_rgb(&self, out: &mut Vec<u8>, base: u8, r: u8, g: u8, b: u8) {
        if self.truecolor {
            out.extend_from_slice(format!(";{base};2;{r};{g};{b}").as_bytes());
        } else {
            out.extend_from_slice(format!(";{base};5;{}", quantize(r, g, b)).as_bytes());
        }
    }
}

/// 标准 xterm 256 色表中 16..255 号颜色的 RGB 值。
fn xterm_rgb(index: u8) -> (u8, u8, u8) {
    if index >= 232 {
        let level = 8 + (index - 232) * 10;
        (level, level, level)
    } else {
        let n = index.saturating_sub(16);
        let r = n / 36;
        let g = (n % 36) / 6;
        let b = n % 6;
        let level = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
        (level(r), level(g), level(b))
    }
}

/// 把 RGB 量化到 256 色（6×6×6 色立方 + 灰阶）。
pub fn quantize(r: u8, g: u8, b: u8) -> u8 {
    let to6 = |v: u8| -> u8 {
        let level = (v as f32 / 255.0 * 5.0).round() as u8;
        level
    };
    let idx = 16 + 36 * to6(r) + 6 * to6(g) + to6(b);
    idx
}

fn push_num(out: &mut Vec<u8>, n: usize) {
    let mut buf = [0u8; 20];
    let mut i = buf.len();
    let mut v = n;
    loop {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
        if v == 0 {
            break;
        }
    }
    out.extend_from_slice(&buf[i..]);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emulation::screen::{Attrs, Cell};

    fn canvas_of(rows: &[&str], cols: usize) -> Vec<Cell> {
        let mut canvas = vec![Cell::default(); cols * rows.len()];
        for (y, line) in rows.iter().enumerate() {
            for (x, ch) in line.chars().enumerate() {
                if x < cols {
                    canvas[y * cols + x] = Cell {
                        ch,
                        attrs: Attrs::default(),
                        link: 0,
                        combining: 0,
                    };
                }
            }
        }
        canvas
    }

    #[test]
    fn first_paint_clears_and_writes() {
        let canvas = canvas_of(&["hi"], 10);
        let mut r = Renderer::new();
        let text = String::from_utf8_lossy(&r.paint(&canvas, 10, 1, Some((2, 0)), 0)).to_string();
        assert!(text.contains("\x1b[2J"));
        assert!(text.contains("hi"));
        assert!(text.contains("\x1b[?25h"));
    }

    #[test]
    fn unchanged_canvas_emits_no_text() {
        let canvas = canvas_of(&["hi"], 10);
        let mut r = Renderer::new();
        let _ = r.paint(&canvas, 10, 1, Some((2, 0)), 0);
        let second = String::from_utf8_lossy(&r.paint(&canvas, 10, 1, Some((2, 0)), 0)).to_string();
        assert!(!second.contains("hi"));
    }

    #[test]
    fn only_changed_cell_repainted() {
        let canvas = canvas_of(&["abc"], 10);
        let mut r = Renderer::new();
        let _ = r.paint(&canvas, 10, 1, Some((0, 0)), 0);
        let mut changed = canvas.clone();
        changed[1] = Cell {
            ch: 'X',
            attrs: Attrs::default(),
            link: 0,
            combining: 0,
        };
        let text = String::from_utf8_lossy(&r.paint(&changed, 10, 1, Some((0, 0)), 0)).to_string();
        assert!(text.contains('X'));
        assert!(!text.contains("abc"));
    }

    #[test]
    fn wide_char_run_advances_two_columns() {
        let mut canvas = vec![Cell::default(); 8];
        canvas[0] = Cell {
            ch: '窗',
            attrs: Attrs::default(),
            link: 0,
            combining: 0,
        };
        canvas[1] = Cell {
            ch: ' ',
            attrs: Attrs {
                flags: ATTR_WIDE_TAIL,
                ..Default::default()
            },
            link: 0,
            combining: 0,
        };
        canvas[2] = Cell {
            ch: 'a',
            attrs: Attrs::default(),
            link: 0,
            combining: 0,
        };
        canvas[3] = Cell {
            ch: 'b',
            attrs: Attrs::default(),
            link: 0,
            combining: 0,
        };
        let mut r = Renderer::new();
        let out = String::from_utf8_lossy(&r.paint(&canvas, 8, 1, None, 0)).to_string();
        assert!(out.contains("窗ab"), "宽字符后应紧跟 a、b：{out:?}");
    }

    #[test]
    fn tail_only_change_repaints_head() {
        let mut canvas = vec![Cell::default(); 8];
        canvas[0] = Cell {
            ch: '窗',
            attrs: Attrs::default(),
            link: 0,
            combining: 0,
        };
        canvas[1] = Cell {
            ch: ' ',
            attrs: Attrs {
                flags: ATTR_WIDE_TAIL,
                ..Default::default()
            },
            link: 0,
            combining: 0,
        };
        let mut r = Renderer::new();
        let _ = r.paint(&canvas, 8, 1, None, 0);

        // 只改右半格的属性：必须连首格一起重画，否则终端列宽会错位
        let mut changed = canvas.clone();
        changed[1].attrs.flags |= ATTR_REVERSE;
        let out = String::from_utf8_lossy(&r.paint(&changed, 8, 1, None, 0)).to_string();
        assert!(out.contains('窗'), "应重画宽字符首格：{out:?}");
    }

    #[test]
    fn gradient_directions() {
        let horizontal = Gradient::new((0, 0, 0), (100, 100, 100), GradientDir::Horizontal);
        assert_eq!(horizontal.at(0, 4, 11, 3), Color::Rgb(0, 0, 0));
        assert_eq!(horizontal.at(10, 4, 11, 3), Color::Rgb(100, 100, 100));

        let vertical = Gradient::new((0, 0, 0), (100, 100, 100), GradientDir::Vertical);
        assert_eq!(vertical.at(4, 0, 11, 11), Color::Rgb(0, 0, 0));
        assert_eq!(vertical.at(4, 10, 11, 11), Color::Rgb(100, 100, 100));

        let diagonal = Gradient::new((0, 0, 0), (100, 100, 100), GradientDir::Diagonal);
        assert_eq!(diagonal.at(0, 0, 11, 11), Color::Rgb(0, 0, 0));
        assert_eq!(diagonal.at(10, 10, 11, 11), Color::Rgb(100, 100, 100));
    }

    #[test]
    fn scheme_default_colors_applied() {
        let canvas = canvas_of(&["a"], 4);
        let mut r = Renderer::new();
        r.set_scheme(
            Some(Color::Rgb(1, 2, 3)),
            Some(Color::Rgb(4, 5, 6)),
            None,
        );
        let text = String::from_utf8_lossy(&r.paint(&canvas, 4, 1, None, 0)).to_string();
        assert!(text.contains("38;2;1;2;3"));
        assert!(text.contains("48;2;4;5;6"));
    }

    #[test]
    fn truecolor_disabled_quantizes() {
        let canvas = canvas_of(&["a"], 4);
        let mut r = Renderer::new();
        r.set_truecolor(false);
        r.set_scheme(Some(Color::Rgb(255, 0, 0)), None, None);
        let text = String::from_utf8_lossy(&r.paint(&canvas, 4, 1, None, 0)).to_string();
        assert!(text.contains("38;5;"), "应降级为 256 色：{text}");
    }

    #[test]
    fn palette_maps_ansi_indexes() {
        let mut canvas = canvas_of(&["a"], 4);
        canvas[0].attrs.fg = Color::Indexed(1);
        canvas[0].attrs.bg = Color::Indexed(4);
        let mut palette = [Color::Rgb(0, 0, 0); 16];
        palette[1] = Color::Rgb(255, 0, 0);
        palette[4] = Color::Rgb(0, 0, 255);
        let mut r = Renderer::new();
        r.set_scheme(None, None, Some(palette));
        let text = String::from_utf8_lossy(&r.paint(&canvas, 4, 1, None, 0)).to_string();
        assert!(text.contains("38;2;255;0;0"), "前景应取调色板：{text}");
        assert!(text.contains("48;2;0;0;255"), "背景应取调色板：{text}");
    }

    #[test]
    fn without_palette_ansi_indexes_pass_through() {
        let mut canvas = canvas_of(&["a"], 4);
        canvas[0].attrs.fg = Color::Indexed(1);
        let mut r = Renderer::new();
        let text = String::from_utf8_lossy(&r.paint(&canvas, 4, 1, None, 0)).to_string();
        assert!(text.contains("38;5;1"), "无调色板时应交给宿主终端：{text}");
    }

    #[test]
    fn indexed_256_color_uses_xterm_table() {
        let mut canvas = canvas_of(&["a"], 4);
        canvas[0].attrs.fg = Color::Indexed(196);
        let mut r = Renderer::new();
        let text = String::from_utf8_lossy(&r.paint(&canvas, 4, 1, None, 0)).to_string();
        assert!(text.contains("38;2;255;0;0"), "196 应为纯红：{text}");
        assert_eq!(xterm_rgb(196), (255, 0, 0));
        assert_eq!(xterm_rgb(232), (8, 8, 8));
        assert_eq!(xterm_rgb(255), (238, 238, 238));
    }
}

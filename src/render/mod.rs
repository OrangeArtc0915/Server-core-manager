//! 渲染基础：颜色、字符单元、网格与画布。
//!
//! TUI 与 GUI 共用同一套单元格网格：TUI 把网格转成 ANSI 转义序列，
//! GUI 把每个单元画成等宽字形，布局代码只写一份。

pub mod canvas;
pub mod grid;

pub use canvas::Canvas;
pub use grid::{attr, Cell, Color, Grid};

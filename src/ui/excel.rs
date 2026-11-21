//! Excel 交互层：选区、单元格编辑、剪贴板、格式、筛选排序与工作表管理。
//!
//! 这里只操作 `xlsx::Workbook` 与 `App` 状态，不关心 TUI / GUI 的绘制细节。

use crate::core::document::Pos;
use crate::platform::clipboard;
use crate::render::Color;
use crate::ui::app::{
    App, ConfirmAction, ConfirmState, ListItem, ListKind, ListState, Overlay, PromptKind,
};
use crate::xlsx::styles::FormatAction;
use crate::xlsx::{self, MergeRange, Value};

impl App {
    // ------------------------------------------------------------ 选区

    /// 当前选区（锚点与活动单元格组成的矩形）。
    pub fn excel_range(&self) -> MergeRange {
        match self.excel_anchor {
            Some((row, col)) => MergeRange::new(
                row.min(self.excel_row),
                col.min(self.excel_col),
                row.max(self.excel_row),
                col.max(self.excel_col),
            ),
            None => MergeRange::new(
                self.excel_row,
                self.excel_col,
                self.excel_row,
                self.excel_col,
            ),
        }
    }

    /// 移动 / 扩展选区。
    pub fn excel_select(&mut self, row: usize, col: usize, extend: bool) {
        if extend {
            if self.excel_anchor.is_none() {
                self.excel_anchor = Some((self.excel_row, self.excel_col));
            }
        } else {
            self.excel_anchor = None;
        }
        self.excel_row = row;
        self.excel_col = col;
        self.excel_editing = false;
        self.excel_input.clear();
        self.excel_scroll_into_view();
        self.excel_report();
    }

    /// 全选已用区域。
    pub fn excel_select_all(&mut self) {
        let bound = self
            .tab()
            .excel
            .as_ref()
            .map(|book| (book.sheet().max_row, book.sheet().max_col))
            .unwrap_or((0, 0));
        self.excel_anchor = Some((0, 0));
        self.excel_row = bound.0;
        self.excel_col = bound.1;
        self.excel_editing = false;
        self.excel_input.clear();
        self.excel_scroll_into_view();
        self.excel_report();
    }

    fn excel_report(&mut self) {
        let reference = xlsx::cell_name(self.excel_row, self.excel_col);
        let value = self.excel_value(self.excel_row, self.excel_col);
        let range = self.excel_range();
        if range.r1 == range.r2 && range.c1 == range.c2 {
            self.set_status(if value.is_empty() {
                reference
            } else {
                format!("{reference}  {value}")
            });
        } else {
            let count = (range.r2 - range.r1 + 1) * (range.c2 - range.c1 + 1);
            self.set_status(format!("{}  {count} 个单元格", range.reference()));
        }
    }

    // ------------------------------------------------------------ 编辑

    /// F2 / 双击进入单元格编辑。
    pub fn excel_begin_edit(&mut self) {
        let range = self.excel_range();
        if range.r1 != range.r2 || range.c1 != range.c2 {
            // 与 Excel 一致：多选时直接输入会替换整个选区。
            self.excel_input.clear();
        } else {
            self.excel_input = self.current_excel_input();
        }
        self.excel_editing = true;
        self.set_status("编辑单元格：Enter 确认，Esc 取消");
    }

    /// 开始输入（覆盖选区）。
    pub fn excel_type(&mut self, ch: char) {
        if !self.excel_editing {
            self.excel_input.clear();
            self.excel_editing = true;
        }
        self.excel_input.push(ch);
    }

    /// 提交编辑内容；`input` 为空时清空选区。
    pub fn excel_commit_edit(&mut self) {
        if !self.excel_editing {
            return;
        }
        self.excel_editing = false;
        let input = std::mem::take(&mut self.excel_input);
        let range = self.excel_range();
        let (row, col) = (self.excel_row, self.excel_col);
        let Some(book) = &mut self.tab_mut().excel else {
            return;
        };
        let active = book.active;
        if input.is_empty() {
            book.clear_range(active, range);
        } else if input.contains('\n') || input.contains('\t') {
            let rows = parse_tsv(&input);
            book.set_range(active, row, col, &rows);
        } else {
            if range.r1 != range.r2 || range.c1 != range.c2 {
                book.clear_range(active, range);
            }
            book.set_cell(active, row, col, &input);
        }
        self.excel_after_change();
        self.set_status(format!(
            "{}  {}",
            xlsx::cell_name(row, col),
            self.excel_value(row, col)
        ));
    }

    /// 清空选区内容（保留格式）。
    pub fn excel_clear(&mut self) {
        let range = self.excel_range();
        let Some(book) = &mut self.tab_mut().excel else {
            return;
        };
        let active = book.active;
        book.clear_range(active, range);
        self.excel_after_change();
        self.set_status("已清除内容");
    }

    fn excel_after_change(&mut self) {
        self.doc_mut().touch_meta();
        self.refresh_active(true);
        self.modified_count = if self.doc().is_dirty() { 1 } else { 0 };
        self.cursor_visible = true;
    }

    // ------------------------------------------------------------ 剪贴板

    /// 复制选区为 TSV；`cut` 为真时复制后清空。
    pub fn excel_copy(&mut self, cut: bool) {
        let range = self.excel_range();
        let mut text = String::new();
        {
            let Some(book) = &self.tab().excel else {
                return;
            };
            let sheet = book.sheet();
            for row in range.r1..=range.r2 {
                if row > range.r1 {
                    text.push_str("\r\n");
                }
                for col in range.c1..=range.c2 {
                    if col > range.c1 {
                        text.push('\t');
                    }
                    text.push_str(&sheet.cell_input(row, col));
                }
            }
        }
        if let Err(e) = clipboard::set_text(&text) {
            self.set_error(format!("复制失败：{e}"));
            return;
        }
        if cut {
            if let Some(book) = &mut self.tab_mut().excel {
                let active = book.active;
                book.clear_range(active, range);
            }
            self.excel_after_change();
            self.set_status(format!("已剪切 {}", range.reference()));
        } else {
            self.set_status(format!("已复制 {}", range.reference()));
        }
    }

    /// 粘贴 TSV / 多行文本，从活动单元格开始写入。
    pub fn excel_paste(&mut self) {
        let text = clipboard::get_text();
        if text.is_empty() {
            return;
        }
        let rows = parse_tsv(&text);
        let width = rows.iter().map(|row| row.len()).max().unwrap_or(0);
        let height = rows.len();
        if width == 0 || height == 0 {
            return;
        }
        let (row, col) = (self.excel_row, self.excel_col);
        if let Some(book) = &mut self.tab_mut().excel {
            let active = book.active;
            book.set_range(active, row, col, &rows);
        }
        self.excel_anchor = Some((row, col));
        self.excel_row = row + height - 1;
        self.excel_col = col + width - 1;
        self.excel_after_change();
        self.excel_scroll_into_view();
        self.set_status(format!("已粘贴 {height}×{width}"));
    }

    // ------------------------------------------------------------ 格式

    pub fn excel_format(&mut self, action: FormatAction, label: &str) {
        let range = self.excel_range();
        let Some(book) = &mut self.tab_mut().excel else {
            return;
        };
        let active = book.active;
        book.format_range(active, range, action);
        self.excel_after_change();
        self.set_status(format!("{label}：{}", range.reference()));
    }

    pub fn excel_font_size_picker(&mut self) {
        let items = [9.0f32, 10.0, 11.0, 12.0, 14.0, 16.0, 18.0, 20.0, 24.0, 28.0, 36.0]
            .iter()
            .map(|size| ListItem {
                title: format!("{size:.0} 磅"),
                detail: String::new(),
                command: None,
                path: None,
                line: None,
                value: Some(size.to_string()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::ExcelFontSize, "字号", items));
    }

    pub fn excel_font_color_picker(&mut self) {
        self.open_color_picker(ListKind::ExcelFontColor, "字体颜色", false);
    }

    pub fn excel_fill_picker(&mut self) {
        self.open_color_picker(ListKind::ExcelFillColor, "填充颜色", true);
    }

    fn open_color_picker(&mut self, kind: ListKind, title: &str, fill: bool) {
        let colors = [
            ("自动 / 无", "auto"),
            ("黑色", "1E1E1E"),
            ("深红", "C00000"),
            ("红色", "FF0000"),
            ("橙色", "ED7D31"),
            ("黄色", "FFC000"),
            ("绿色", "70AD47"),
            ("青色", "00B0F0"),
            ("蓝色", "0070C0"),
            ("紫色", "7030A0"),
            ("浅灰", "D9D9D9"),
            ("浅黄", "FFF2CC"),
            ("浅绿", "E2EFDA"),
            ("浅蓝", "DDEBF7"),
            ("浅红", "FCE4D6"),
        ];
        let items = colors
            .iter()
            .map(|(name, hex)| ListItem {
                title: name.to_string(),
                detail: if *hex == "auto" {
                    if fill {
                        "清除填充".into()
                    } else {
                        "默认颜色".into()
                    }
                } else {
                    format!("#{hex}")
                },
                command: None,
                path: None,
                line: None,
                value: Some(hex.to_string()),
            })
            .collect();
        self.open_list(ListState::new(kind, title, items));
    }

    pub fn excel_number_picker(&mut self) {
        let formats = [
            ("常规", "General"),
            ("数字 0.00", "0.00"),
            ("整数 0", "0"),
            ("千分位 #,##0.00", "#,##0.00"),
            ("货币 ¥#,##0.00", "\"¥\"#,##0.00"),
            ("百分比 0.00%", "0.00%"),
            ("日期 yyyy-mm-dd", "yyyy-mm-dd"),
            ("时间 hh:mm:ss", "hh:mm:ss"),
            ("日期时间 yyyy-mm-dd hh:mm", "yyyy-mm-dd hh:mm"),
            ("科学计数 0.00E+00", "0.00E+00"),
            ("文本 @", "@"),
        ];
        let items = formats
            .iter()
            .map(|(name, code)| ListItem {
                title: name.to_string(),
                detail: code.to_string(),
                command: None,
                path: None,
                line: None,
                value: Some(code.to_string()),
            })
            .collect();
        self.open_list(ListState::new(
            ListKind::ExcelNumberFormat,
            "数字格式",
            items,
        ));
    }

    /// 列表浮层中选择格式后的应用逻辑。
    pub fn excel_apply_picker(&mut self, kind: ListKind, value: &str) {
        match kind {
            ListKind::ExcelFontSize => {
                if let Ok(size) = value.parse::<f32>() {
                    self.excel_format(FormatAction::FontSize(size), "字号");
                }
            }
            ListKind::ExcelFontColor => {
                if value == "auto" {
                    self.excel_format(
                        FormatAction::FontColor(Color::rgb(0, 0, 0)),
                        "字体颜色",
                    );
                } else if let Some(color) = parse_hex(value) {
                    self.excel_format(FormatAction::FontColor(color), "字体颜色");
                }
            }
            ListKind::ExcelFillColor => {
                if value == "auto" {
                    self.excel_format(FormatAction::ClearFill, "清除填充");
                } else if let Some(color) = parse_hex(value) {
                    self.excel_format(FormatAction::Fill(color), "填充颜色");
                }
            }
            ListKind::ExcelNumberFormat => {
                self.excel_format(
                    FormatAction::NumberFormat(value.to_string()),
                    "数字格式",
                );
            }
            _ => {}
        }
    }

    // ------------------------------------------------------------ 合并 / 冻结 / 筛选 / 排序

    pub fn excel_merge(&mut self) {
        let range = self.excel_range();
        if range.r1 == range.r2 && range.c1 == range.c2 {
            self.set_error("请先选择多个单元格再合并");
            return;
        }
        if let Some(book) = &mut self.tab_mut().excel {
            let active = book.active;
            book.merge(active, range);
        }
        self.excel_after_change();
        self.set_status(format!("已合并 {}", range.reference()));
    }

    pub fn excel_unmerge(&mut self) {
        let (row, col) = (self.excel_row, self.excel_col);
        let Some(book) = &mut self.tab_mut().excel else {
            return;
        };
        let active = book.active;
        book.unmerge(active, row, col);
        self.excel_after_change();
        self.set_status("已取消合并");
    }

    pub fn excel_toggle_freeze(&mut self) {
        let (row, col) = (self.excel_row, self.excel_col);
        let Some(book) = &mut self.tab_mut().excel else {
            return;
        };
        let active = book.active;
        let frozen = {
            let sheet = book.sheet();
            sheet.freeze_rows > 0 || sheet.freeze_cols > 0
        };
        if frozen {
            book.freeze(active, 0, 0);
            self.set_status("已取消冻结窗格");
        } else {
            book.freeze(active, row, col);
            self.set_status(format!("已冻结：上方 {row} 行、左侧 {col} 列"));
        }
        self.excel_after_change();
    }

    pub fn excel_filter_prompt(&mut self) {
        let Some(book) = &self.tab().excel else {
            return;
        };
        let sheet = book.sheet();
        if sheet.max_row == 0 {
            self.set_error("没有可筛选的数据");
            return;
        }
        self.open_prompt(
            PromptKind::ExcelFilter,
            "筛选当前列",
            "",
        );
    }

    pub fn excel_clear_filter(&mut self) {
        let Some(book) = &mut self.tab_mut().excel else {
            return;
        };
        let active = book.active;
        book.clear_filter(active);
        self.excel_after_change();
        self.set_status("已清除筛选");
    }

    pub fn excel_sort(&mut self, ascending: bool) {
        let range = self.excel_range();
        let (target, header) = if range.r1 != range.r2 {
            (range, false)
        } else {
            let Some(book) = &self.tab().excel else {
                return;
            };
            let sheet = book.sheet();
            (
                MergeRange::new(0, 0, sheet.max_row, sheet.max_col),
                true,
            )
        };
        if target.r1 == target.r2 {
            self.set_error("没有可排序的数据");
            return;
        }
        let column = self.excel_col;
        let Some(book) = &mut self.tab_mut().excel else {
            return;
        };
        let active = book.active;
        book.sort_range(active, target, column, ascending, header);
        self.excel_after_change();
        self.set_status(format!(
            "{}排序：{}",
            if ascending { "升序" } else { "降序" },
            xlsx::column_name(column)
        ));
    }

    // ------------------------------------------------------------ 行列 / 工作表

    pub fn excel_insert_line(&mut self, rows: bool, delete: bool) {
        let (row, col) = (self.excel_row, self.excel_col);
        let Some(book) = &mut self.tab_mut().excel else {
            return;
        };
        let active = book.active;
        match (rows, delete) {
            (true, false) => book.insert_rows(active, row, 1),
            (true, true) => book.delete_rows(active, row, 1),
            (false, false) => book.insert_cols(active, col, 1),
            (false, true) => book.delete_cols(active, col, 1),
        }
        self.excel_after_change();
        let action = if delete { "删除" } else { "插入" };
        let kind = if rows { "行" } else { "列" };
        self.set_status(format!("{action}{kind}：{}", if rows { row + 1 } else { col + 1 }));
    }

    pub fn excel_sheet_add(&mut self) {
        self.open_prompt(PromptKind::ExcelSheetAdd, "新建工作表", "");
    }

    pub fn excel_sheet_rename(&mut self) {
        let name = self
            .tab()
            .excel
            .as_ref()
            .map(|book| book.sheet().name.clone())
            .unwrap_or_default();
        self.open_prompt(PromptKind::ExcelSheetRename, "重命名工作表", &name);
    }

    pub fn excel_sheet_delete(&mut self) {
        let Some(book) = &self.tab().excel else {
            return;
        };
        let name = book.sheet().name.clone();
        let active = book.active;
        self.overlay = Overlay::Confirm(ConfirmState {
            title: "删除工作表".into(),
            message: format!("确定删除工作表「{name}」？可用 Ctrl+Z 撤销。"),
            selected: 1,
            action: ConfirmAction::ExcelSheetDelete(active),
        });
    }

    pub fn excel_sheet_switch(&mut self, delta: isize) {
        self.excel_switch_sheet(delta);
    }

    /// Excel 专属全局快捷键（在通用快捷键之前处理）。
    pub fn excel_global_key(&mut self, key: crate::platform::console::Key) -> bool {
        use crate::platform::console::KeyCode::*;
        let m = key.mods;
        let pressed = |c: char, mods| key.code == Char(c) && m == mods;
        if pressed('b', crate::platform::console::Mods::ctrl()) {
            self.execute(crate::ui::app::Cmd::ExcelBold);
        } else if pressed('i', crate::platform::console::Mods::ctrl()) {
            self.execute(crate::ui::app::Cmd::ExcelItalic);
        } else if pressed('u', crate::platform::console::Mods::ctrl()) {
            self.execute(crate::ui::app::Cmd::ExcelUnderline);
        } else if pressed('c', crate::platform::console::Mods::ctrl()) {
            self.execute(crate::ui::app::Cmd::ExcelCopy);
        } else if pressed('x', crate::platform::console::Mods::ctrl()) {
            self.execute(crate::ui::app::Cmd::ExcelCut);
        } else if pressed('v', crate::platform::console::Mods::ctrl()) {
            self.execute(crate::ui::app::Cmd::ExcelPaste);
        } else if pressed('a', crate::platform::console::Mods::ctrl()) {
            self.execute(crate::ui::app::Cmd::ExcelSelectAll);
        } else if pressed('m', crate::platform::console::Mods::ctrl_shift()) {
            self.execute(crate::ui::app::Cmd::ExcelMerge);
        } else if pressed('l', crate::platform::console::Mods::ctrl_shift()) {
            self.execute(crate::ui::app::Cmd::ExcelFreeze);
        } else if pressed('f', crate::platform::console::Mods::ctrl_shift()) {
            self.execute(crate::ui::app::Cmd::ExcelFilter);
        } else if key.code == crate::platform::console::KeyCode::PageUp && m.ctrl {
            self.excel_switch_sheet(-1);
        } else if key.code == crate::platform::console::KeyCode::PageDown && m.ctrl {
            self.excel_switch_sheet(1);
        } else {
            return false;
        }
        true
    }

    /// 提交浮层提示。
    pub fn excel_submit_prompt(&mut self, kind: PromptKind, input: &str) -> bool {
        match kind {
            PromptKind::ExcelSheetAdd => {
                if input.is_empty() {
                    self.set_error("工作表名不能为空");
                    return false;
                }
                match self.tab_mut().excel.as_mut() {
                    Some(book) => match book.add_sheet(input) {
                        Ok(index) => {
                            book.active = index;
                            self.excel_row = 0;
                            self.excel_col = 0;
                            self.excel_anchor = None;
                            self.excel_after_change();
                            self.set_status(format!("已新建工作表：{input}"));
                        }
                        Err(e) => {
                            self.set_error(e);
                            return false;
                        }
                    },
                    None => return false,
                }
                true
            }
            PromptKind::ExcelSheetRename => {
                if input.is_empty() {
                    self.set_error("工作表名不能为空");
                    return false;
                }
                let Some(book) = &mut self.tab_mut().excel else {
                    return false;
                };
                let active = book.active;
                match book.rename_sheet(active, input) {
                    Ok(()) => {
                        self.excel_after_change();
                        self.set_status(format!("工作表已重命名为 {input}"));
                        true
                    }
                    Err(e) => {
                        self.set_error(e);
                        false
                    }
                }
            }
            PromptKind::ExcelFilter => {
                let column = self.excel_col;
                let Some(book) = &mut self.tab_mut().excel else {
                    return false;
                };
                let active = book.active;
                let sheet = book.sheet();
                let bound = (sheet.max_row, sheet.max_col);
                let column = column.min(bound.1);
                let criteria = input.trim().to_string();
                if criteria.is_empty() {
                    book.clear_filter(active);
                    self.excel_after_change();
                    self.set_status("已清除筛选");
                    return true;
                }
                let range = MergeRange::new(0, 0, bound.0, bound.1);
                book.set_filter(active, range, column, &criteria);
                self.excel_after_change();
                self.set_status(format!(
                    "筛选 {}：{criteria}",
                    xlsx::column_name(column)
                ));
                true
            }
            _ => false,
        }
    }

    /// Excel 的「转到单元格」：支持 A1、$A$1 与区域 A1:B2。
    pub fn excel_goto(&mut self, text: &str) {
        let text = text.trim().replace('$', "");
        let first = text.split(':').next().unwrap_or("");
        if let Some((row, col)) = xlsx::parse_ref(first) {
            if text.contains(':') {
                if let Some(end) = text.split(':').nth(1).and_then(xlsx::parse_ref) {
                    self.excel_anchor = Some((row, col));
                    self.excel_row = end.0;
                    self.excel_col = end.1;
                    self.excel_scroll_into_view();
                    self.excel_report();
                    return;
                }
            }
            self.excel_select(row, col, false);
        } else {
            self.set_error("单元格地址无效");
        }
    }

    /// 打开「与文件比较」时跳转到差异首行（保留给菜单）。
    pub fn excel_goto_pos(&mut self, pos: Pos) {
        self.excel_select(pos.line, pos.col, false);
    }
}

/// 解析 TSV / 多行文本：`\r\n`、`\n` 分行，`\t` 分列。
fn parse_tsv(text: &str) -> Vec<Vec<String>> {
    text.split('\n')
        .map(|line| line.trim_end_matches('\r'))
        .map(|line| line.split('\t').map(|cell| cell.to_string()).collect())
        .collect()
}

fn parse_hex(hex: &str) -> Option<Color> {
    let hex = hex.trim_start_matches('#');
    if hex.len() != 6 {
        return None;
    }
    let value = u32::from_str_radix(hex, 16).ok()?;
    Some(Color::rgb(
        ((value >> 16) & 0xFF) as u8,
        ((value >> 8) & 0xFF) as u8,
        (value & 0xFF) as u8,
    ))
}

/// 在状态栏显示数值（供 GUI 状态同步）。
pub fn cell_display(book: &xlsx::Workbook, row: usize, col: usize) -> String {
    book.display(book.active, row, col)
}

/// 判断单元格是否是数字（用于右对齐）。
pub fn is_numeric(book: &xlsx::Workbook, row: usize, col: usize) -> bool {
    matches!(book.value(book.active, row, col), Value::Number(_))
}

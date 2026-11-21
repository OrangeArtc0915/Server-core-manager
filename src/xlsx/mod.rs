//! Excel（.xlsx）工作簿：多工作表、样式、合并、冻结、筛选、排序与公式。
//!
//! 保存采用“只改变化单元格”的方式，工作表里的图表、条件格式、数据验证等
//! 未识别部件保持原样。

pub mod formula;
pub mod styles;

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::Path;

use crate::archive::Zip;
use crate::xml::{self, Element, Node};

pub use formula::Value;
pub use styles::{FormatAction, ResolvedStyle, Styles};

pub const DEFAULT_COL_WIDTH: f32 = 8.43;
pub const DEFAULT_ROW_HEIGHT: f32 = 15.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Cell {
    /// 存储值（数字、文本、布尔）。
    pub text: String,
    /// 公式原文（不含前导 `=`）。
    pub formula: Option<String>,
    /// 样式索引。
    pub style: u32,
}

impl Cell {
    fn is_empty(&self) -> bool {
        self.text.is_empty() && self.formula.is_none()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MergeRange {
    pub r1: usize,
    pub c1: usize,
    pub r2: usize,
    pub c2: usize,
}

impl MergeRange {
    pub fn new(r1: usize, c1: usize, r2: usize, c2: usize) -> MergeRange {
        MergeRange {
            r1: r1.min(r2),
            c1: c1.min(c2),
            r2: r1.max(r2),
            c2: c1.max(c2),
        }
    }

    pub fn contains(&self, row: usize, col: usize) -> bool {
        row >= self.r1 && row <= self.r2 && col >= self.c1 && col <= self.c2
    }

    pub fn reference(&self) -> String {
        format!(
            "{}{}:{}{}",
            column_name(self.c1),
            self.r1 + 1,
            column_name(self.c2),
            self.r2 + 1
        )
    }
}

#[derive(Clone, Debug)]
pub struct Sheet {
    pub name: String,
    pub path: String,
    root: Element,
    pub cells: BTreeMap<(usize, usize), Cell>,
    original: BTreeMap<(usize, usize), Cell>,
    pub max_row: usize,
    pub max_col: usize,
    pub col_widths: Vec<f32>,
    pub row_heights: BTreeMap<usize, f32>,
    pub merges: Vec<MergeRange>,
    pub freeze_rows: usize,
    pub freeze_cols: usize,
    pub auto_filter: Option<MergeRange>,
    pub hidden_rows: BTreeSet<usize>,
    pub hidden_cols: BTreeSet<usize>,
    /// 筛选隐藏的行（与手工隐藏分开，取消筛选时恢复）。
    pub filtered_rows: BTreeSet<usize>,
}

impl Sheet {
    pub fn cell(&self, row: usize, col: usize) -> Option<&Cell> {
        self.cells.get(&(row, col))
    }

    pub fn cell_input(&self, row: usize, col: usize) -> String {
        match self.cells.get(&(row, col)) {
            Some(cell) => match &cell.formula {
                Some(formula) => format!("={formula}"),
                None => cell.text.clone(),
            },
            None => String::new(),
        }
    }

    pub fn col_width(&self, col: usize) -> f32 {
        self.col_widths.get(col).copied().unwrap_or(DEFAULT_COL_WIDTH)
    }

    pub fn row_height(&self, row: usize) -> f32 {
        self.row_heights.get(&row).copied().unwrap_or(DEFAULT_ROW_HEIGHT)
    }

    pub fn is_hidden(&self, row: usize, col: usize) -> bool {
        self.hidden_rows.contains(&row)
            || self.filtered_rows.contains(&row)
            || self.hidden_cols.contains(&col)
    }

    pub fn merge_at(&self, row: usize, col: usize) -> Option<&MergeRange> {
        self.merges.iter().find(|range| range.contains(row, col))
    }

    pub fn is_topleft(&self, row: usize, col: usize) -> bool {
        match self.merge_at(row, col) {
            Some(range) => range.r1 == row && range.c1 == col,
            None => true,
        }
    }

    fn recompute_bounds(&mut self) {
        self.max_row = self.cells.keys().map(|(row, _)| *row).max().unwrap_or(0);
        self.max_col = self.cells.keys().map(|(_, col)| *col).max().unwrap_or(0);
    }
}

#[derive(Clone)]
struct Snapshot {
    sheets: Vec<Sheet>,
    active: usize,
    styles: Styles,
}

#[derive(Clone)]
struct Change {
    sheet: usize,
    row: usize,
    col: usize,
    before: Option<Cell>,
    after: Option<Cell>,
}

#[derive(Clone)]
enum EditOp {
    Cells(Vec<Change>),
    Snapshot { before: Snapshot, after: Snapshot },
}

pub struct Workbook {
    zip: Zip,
    pub sheets: Vec<Sheet>,
    shared: Vec<String>,
    pub active: usize,
    pub styles: Styles,
    pub date1904: bool,
    undo: Vec<EditOp>,
    redo: Vec<EditOp>,
}

impl Workbook {
    pub fn open(path: &Path) -> Result<Workbook, String> {
        let zip = Zip::read_file(path)?;
        let workbook_xml = zip
            .get_text("xl/workbook.xml")
            .ok_or_else(|| "不是有效的 Excel 文件（缺少 xl/workbook.xml）".to_string())?;
        let workbook_root = xml::parse(&workbook_xml)?;
        let rels_text = zip
            .get_text("xl/_rels/workbook.xml.rels")
            .unwrap_or_default();
        let rels = if rels_text.is_empty() {
            Element::new("Relationships")
        } else {
            xml::parse(&rels_text)?
        };
        let shared = parse_shared_strings(
            &zip.get_text("xl/sharedStrings.xml").unwrap_or_default(),
        );
        let styles = zip
            .get_text("xl/styles.xml")
            .and_then(|text| xml::parse(&text).ok())
            .map(|root| Styles::parse(&root))
            .unwrap_or_default();
        let date1904 = workbook_root
            .first_child("workbookPr")
            .and_then(|props| props.attr("date1904"))
            .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
            .unwrap_or(false);

        let mut sheets = Vec::new();
        if let Some(list) = workbook_root.first_child("sheets") {
            for sheet in list.elements().filter(|e| local(&e.name) == "sheet") {
                let name = sheet.attr("name").unwrap_or("Sheet").to_string();
                let rid = sheet
                    .attr("r:id")
                    .or_else(|| sheet.attr("id"))
                    .unwrap_or("");
                let target = rels
                    .elements()
                    .find(|rel| rel.attr("Id") == Some(rid))
                    .and_then(|rel| rel.attr("Target"))
                    .map(normalize_target)
                    .unwrap_or_else(|| format!("xl/worksheets/sheet{}.xml", sheets.len() + 1));
                let text = zip
                    .get_text(&target)
                    .ok_or_else(|| format!("缺少工作表 {target}"))?;
                let root = xml::parse(&text)?;
                let mut sheet = parse_sheet(name, target, root, &shared);
                sheet.original = sheet.cells.clone();
                sheets.push(sheet);
            }
        }
        if sheets.is_empty() {
            return Err("工作簿中没有工作表".into());
        }
        let active = workbook_root
            .first_child("bookViews")
            .and_then(|views| views.first_child("workbookView"))
            .and_then(|view| view.attr("activeTab"))
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(0)
            .min(sheets.len() - 1);
        Ok(Workbook {
            zip,
            sheets,
            shared,
            active,
            styles,
            date1904,
            undo: Vec::new(),
            redo: Vec::new(),
        })
    }

    pub fn create() -> Workbook {
        let styles = Styles::new();
        let mut zip = Zip { entries: Vec::new() };
        zip.set(
            "[Content_Types].xml",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"#,
        );
        zip.set(
            "_rels/.rels",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
        );
        zip.set(
            "xl/workbook.xml",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView activeTab="0"/></bookViews><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
        );
        zip.set(
            "xl/_rels/workbook.xml.rels",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#,
        );
        let sheet_xml = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="A1"/><sheetViews><sheetView tabSelected="1" workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/><sheetData/></worksheet>"#;
        zip.set("xl/worksheets/sheet1.xml", sheet_xml.as_bytes());
        zip.set("xl/styles.xml", styles.serialize().as_bytes());
        let root = xml::parse(sheet_xml).unwrap_or_else(|_| Element::new("worksheet"));
        let sheet = parse_sheet("Sheet1".into(), "xl/worksheets/sheet1.xml".into(), root, &[]);
        Workbook {
            zip,
            sheets: vec![sheet],
            shared: Vec::new(),
            active: 0,
            styles,
            date1904: false,
            undo: Vec::new(),
            redo: Vec::new(),
        }
    }

    pub fn sheet_names(&self) -> Vec<&str> {
        self.sheets.iter().map(|sheet| sheet.name.as_str()).collect()
    }

    pub fn sheet_index(&self, name: &str) -> Option<usize> {
        self.sheets
            .iter()
            .position(|sheet| sheet.name.eq_ignore_ascii_case(name))
    }

    pub fn sheet(&self) -> &Sheet {
        &self.sheets[self.active.min(self.sheets.len() - 1)]
    }

    pub fn sheet_mut(&mut self) -> &mut Sheet {
        let index = self.active.min(self.sheets.len() - 1);
        &mut self.sheets[index]
    }

    pub fn set_active(&mut self, index: usize) {
        if index < self.sheets.len() {
            self.active = index;
        }
    }

    pub fn style_at(&self, sheet: usize, row: usize, col: usize) -> ResolvedStyle {
        let style = self
            .sheets
            .get(sheet)
            .and_then(|sheet| sheet.cells.get(&(row, col)))
            .map(|cell| cell.style)
            .unwrap_or(0);
        self.styles.resolve(style)
    }

    pub fn value(&self, sheet: usize, row: usize, col: usize) -> Value {
        self.value_with_seen(sheet, row, col, &mut HashSet::new())
    }

    fn value_with_seen(
        &self,
        sheet: usize,
        row: usize,
        col: usize,
        seen: &mut HashSet<(usize, usize, usize)>,
    ) -> Value {
        let Some(target) = self.sheets.get(sheet) else {
            return Value::Error(formula::ERR_REF.into());
        };
        let Some(cell) = target.cells.get(&(row, col)) else {
            return Value::Empty;
        };
        if let Some(formula) = &cell.formula {
            if !seen.insert((sheet, row, col)) {
                return Value::Error(formula::ERR_CYCLE.into());
            }
            let value = formula::evaluate(self, sheet, formula, row, col, seen);
            seen.remove(&(sheet, row, col));
            return value;
        }
        formula::text_to_value(&cell.text)
    }

    /// 单元格显示值（应用数字格式）。
    pub fn display(&self, sheet: usize, row: usize, col: usize) -> String {
        let value = self.value(sheet, row, col);
        let style = self.style_at(sheet, row, col);
        match value {
            Value::Number(number) => {
                styles::format_number(number, &style.num_format, self.date1904)
            }
            Value::Empty => String::new(),
            other => other.display(),
        }
    }

    /// 写入单元格：`=` 开头按公式保存，保留原样式。
    pub fn set_cell(&mut self, sheet: usize, row: usize, col: usize, input: &str) {
        self.set_cell_with_style(sheet, row, col, input, None);
    }

    pub fn set_cell_with_style(
        &mut self,
        sheet: usize,
        row: usize,
        col: usize,
        input: &str,
        style: Option<u32>,
    ) {
        let Some(target) = self.sheets.get(sheet) else {
            return;
        };
        let before = target.cells.get(&(row, col)).cloned();
        let style = style.unwrap_or_else(|| before.as_ref().map(|cell| cell.style).unwrap_or(0));
        let cell = if let Some(formula) = input.strip_prefix('=') {
            Cell {
                text: String::new(),
                formula: Some(formula.to_string()),
                style,
            }
        } else {
            Cell {
                text: input.to_string(),
                formula: None,
                style,
            }
        };
        let after = if cell.is_empty() && cell.style == 0 {
            None
        } else {
            Some(cell.clone())
        };
        {
            let sheet = &mut self.sheets[sheet];
            if let Some(cell) = &after {
                sheet.max_row = sheet.max_row.max(row);
                sheet.max_col = sheet.max_col.max(col);
                sheet.cells.insert((row, col), cell.clone());
            } else {
                sheet.cells.remove(&(row, col));
            }
        }
        if before != after {
            self.undo.push(EditOp::Cells(vec![Change {
                sheet,
                row,
                col,
                before,
                after,
            }]));
            self.redo.clear();
        }
    }

    pub fn clear_range(&mut self, sheet: usize, range: MergeRange) {
        let mut changes = Vec::new();
        for row in range.r1..=range.r2 {
            for col in range.c1..=range.c2 {
                let before = self
                    .sheets
                    .get(sheet)
                    .and_then(|sheet| sheet.cells.get(&(row, col)))
                    .cloned();
                if before.is_none() {
                    continue;
                }
                if let Some(target) = self.sheets.get_mut(sheet) {
                    target.cells.remove(&(row, col));
                }
                changes.push(Change {
                    sheet,
                    row,
                    col,
                    before,
                    after: None,
                });
            }
        }
        if !changes.is_empty() {
            self.undo.push(EditOp::Cells(changes));
            self.redo.clear();
        }
    }

    /// 批量写入（粘贴/填充），合并为一次撤销。
    pub fn set_range(&mut self, sheet: usize, row: usize, col: usize, rows: &[Vec<String>]) {
        let mut changes = Vec::new();
        for (dr, values) in rows.iter().enumerate() {
            for (dc, input) in values.iter().enumerate() {
                let (r, c) = (row + dr, col + dc);
                if input.is_empty() {
                    continue;
                }
                let before = self
                    .sheets
                    .get(sheet)
                    .and_then(|sheet| sheet.cells.get(&(r, c)))
                    .cloned();
                let style = before.as_ref().map(|cell| cell.style).unwrap_or(0);
                let cell = if let Some(formula) = input.strip_prefix('=') {
                    Cell {
                        text: String::new(),
                        formula: Some(formula.to_string()),
                        style,
                    }
                } else {
                    Cell {
                        text: input.clone(),
                        formula: None,
                        style,
                    }
                };
                let after = Some(cell);
                if before == after {
                    continue;
                }
                if let Some(target) = self.sheets.get_mut(sheet) {
                    target.max_row = target.max_row.max(r);
                    target.max_col = target.max_col.max(c);
                    target
                        .cells
                        .insert((r, c), after.clone().unwrap());
                }
                changes.push(Change {
                    sheet,
                    row: r,
                    col: c,
                    before,
                    after,
                });
            }
        }
        if !changes.is_empty() {
            self.undo.push(EditOp::Cells(changes));
            self.redo.clear();
        }
    }

    /// 对区域应用格式。格式作用于区域左上角单元格的样式副本。
    pub fn format_range(
        &mut self,
        sheet: usize,
        range: MergeRange,
        action: FormatAction,
    ) -> u32 {
        let base = self
            .sheets
            .get(sheet)
            .and_then(|sheet| sheet.cells.get(&(range.r1, range.c1)))
            .map(|cell| cell.style)
            .unwrap_or(0);
        let style = self.styles.apply(base, &action);
        let mut changes = Vec::new();
        for row in range.r1..=range.r2 {
            for col in range.c1..=range.c2 {
                let before = self
                    .sheets
                    .get(sheet)
                    .and_then(|sheet| sheet.cells.get(&(row, col)))
                    .cloned();
                let mut cell = before.clone().unwrap_or(Cell {
                    text: String::new(),
                    formula: None,
                    style: 0,
                });
                if cell.style == style {
                    continue;
                }
                cell.style = style;
                let after = Some(cell);
                if let Some(target) = self.sheets.get_mut(sheet) {
                    target.max_row = target.max_row.max(row);
                    target.max_col = target.max_col.max(col);
                    target
                        .cells
                        .insert((row, col), after.clone().unwrap());
                }
                changes.push(Change {
                    sheet,
                    row,
                    col,
                    before,
                    after,
                });
            }
        }
        if !changes.is_empty() {
            self.undo.push(EditOp::Cells(changes));
            self.redo.clear();
        }
        style
    }

    pub fn merge(&mut self, sheet: usize, range: MergeRange) {
        let before = self.snapshot();
        if let Some(target) = self.sheets.get_mut(sheet) {
            target.merges.retain(|item| {
                item.r2 < range.r1
                    || item.r1 > range.r2
                    || item.c2 < range.c1
                    || item.c1 > range.c2
            });
            target.merges.push(range);
        }
        let after = self.snapshot();
        self.undo.push(EditOp::Snapshot { before, after });
        self.redo.clear();
    }

    pub fn unmerge(&mut self, sheet: usize, row: usize, col: usize) {
        let before = self.snapshot();
        if let Some(target) = self.sheets.get_mut(sheet) {
            target.merges.retain(|item| !item.contains(row, col));
        }
        let after = self.snapshot();
        self.undo.push(EditOp::Snapshot { before, after });
        self.redo.clear();
    }

    pub fn freeze(&mut self, sheet: usize, rows: usize, cols: usize) {
        if let Some(target) = self.sheets.get_mut(sheet) {
            target.freeze_rows = rows;
            target.freeze_cols = cols;
        }
    }

    pub fn set_filter(
        &mut self,
        sheet: usize,
        range: MergeRange,
        column: usize,
        criteria: &str,
    ) {
        let Some(target) = self.sheets.get_mut(sheet) else {
            return;
        };
        target.auto_filter = Some(range);
        target.filtered_rows.clear();
        let mut hidden = Vec::new();
        for row in range.r1 + 1..=range.r2 {
            let value = self.value(sheet, row, column);
            if !formula::criteria_matches(&value, criteria) {
                hidden.push(row);
            }
        }
        if let Some(target) = self.sheets.get_mut(sheet) {
            for row in hidden {
                target.filtered_rows.insert(row);
            }
        }
    }

    pub fn clear_filter(&mut self, sheet: usize) {
        if let Some(target) = self.sheets.get_mut(sheet) {
            target.auto_filter = None;
            target.filtered_rows.clear();
        }
    }

    pub fn sort_range(
        &mut self,
        sheet: usize,
        range: MergeRange,
        column: usize,
        ascending: bool,
        header: bool,
    ) {
        let before = self.snapshot();
        let start = if header { range.r1 + 1 } else { range.r1 };
        let mut rows: Vec<(usize, Value)> = (start..=range.r2)
            .map(|row| (row, self.value(sheet, row, column)))
            .collect();
        rows.sort_by(|a, b| {
            let ordering = compare_sort_values(&a.1, &b.1);
            if ascending {
                ordering
            } else {
                ordering.reverse()
            }
        });
        let order: Vec<usize> = rows.iter().map(|(row, _)| *row).collect();
        let Some(target) = self.sheets.get_mut(sheet) else {
            return;
        };
        let snapshot: Vec<Vec<(usize, Cell)>> = order
            .iter()
            .map(|row| {
                (range.c1..=range.c2)
                    .filter_map(|col| target.cells.get(&(*row, col)).map(|cell| (col, cell.clone())))
                    .collect()
            })
            .collect();
        for row in start..=range.r2 {
            for col in range.c1..=range.c2 {
                target.cells.remove(&(row, col));
            }
        }
        for (index, row_cells) in snapshot.into_iter().enumerate() {
            let row = start + index;
            for (col, cell) in row_cells {
                target.cells.insert((row, col), cell);
            }
        }
        let after = self.snapshot();
        self.undo.push(EditOp::Snapshot { before, after });
        self.redo.clear();
    }

    pub fn add_sheet(&mut self, name: &str) -> Result<usize, String> {
        if self.sheet_index(name).is_some() {
            return Err(format!("工作表 {name} 已存在"));
        }
        let before = self.snapshot();
        let mut index = self.sheets.len() + 1;
        let mut path = format!("xl/worksheets/sheet{index}.xml");
        while self.zip.get(&path).is_some() {
            index += 1;
            path = format!("xl/worksheets/sheet{index}.xml");
        }
        let xml_text = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><dimension ref=\"A1\"/><sheetViews><sheetView workbookViewId=\"0\"/></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/><sheetData/></worksheet>"
        );
        self.zip.set(&path, xml_text.as_bytes());
        let root = xml::parse(&xml_text)?;
        self.sheets.push(parse_sheet(name.to_string(), path.clone(), root, &[]));
        self.sync_workbook_parts()?;
        self.add_content_type_override(&path, "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml");
        let after = self.snapshot();
        self.undo.push(EditOp::Snapshot { before, after });
        self.redo.clear();
        Ok(self.sheets.len() - 1)
    }

    pub fn rename_sheet(&mut self, index: usize, name: &str) -> Result<(), String> {
        if name.trim().is_empty() {
            return Err("工作表名不能为空".into());
        }
        if self.sheet_index(name).map(|value| value != index).unwrap_or(false) {
            return Err(format!("工作表 {name} 已存在"));
        }
        if let Some(sheet) = self.sheets.get_mut(index) {
            sheet.name = name.to_string();
        }
        self.sync_workbook_parts()?;
        Ok(())
    }

    pub fn delete_sheet(&mut self, index: usize) -> Result<(), String> {
        if self.sheets.len() <= 1 {
            return Err("至少要保留一个工作表".into());
        }
        let before = self.snapshot();
        if index >= self.sheets.len() {
            return Err("工作表索引超出范围".into());
        }
        let sheet = self.sheets.remove(index);
        self.zip.remove(&sheet.path);
        if self.active >= self.sheets.len() {
            self.active = self.sheets.len() - 1;
        }
        self.sync_workbook_parts()?;
        self.remove_content_type_override(&sheet.path);
        let after = self.snapshot();
        self.undo.push(EditOp::Snapshot { before, after });
        self.redo.clear();
        Ok(())
    }

    pub fn insert_rows(&mut self, sheet: usize, at: usize, count: usize) {
        if count == 0 {
            return;
        }
        let before = self.snapshot();
        if let Some(target) = self.sheets.get_mut(sheet) {
            shift_rows(target, at, count, false);
        }
        let after = self.snapshot();
        self.undo.push(EditOp::Snapshot { before, after });
        self.redo.clear();
    }

    pub fn delete_rows(&mut self, sheet: usize, at: usize, count: usize) {
        if count == 0 {
            return;
        }
        let before = self.snapshot();
        if let Some(target) = self.sheets.get_mut(sheet) {
            shift_rows(target, at, count, true);
        }
        let after = self.snapshot();
        self.undo.push(EditOp::Snapshot { before, after });
        self.redo.clear();
    }

    pub fn insert_cols(&mut self, sheet: usize, at: usize, count: usize) {
        if count == 0 {
            return;
        }
        let before = self.snapshot();
        if let Some(target) = self.sheets.get_mut(sheet) {
            shift_cols(target, at, count, false);
        }
        let after = self.snapshot();
        self.undo.push(EditOp::Snapshot { before, after });
        self.redo.clear();
    }

    pub fn delete_cols(&mut self, sheet: usize, at: usize, count: usize) {
        if count == 0 {
            return;
        }
        let before = self.snapshot();
        if let Some(target) = self.sheets.get_mut(sheet) {
            shift_cols(target, at, count, true);
        }
        let after = self.snapshot();
        self.undo.push(EditOp::Snapshot { before, after });
        self.redo.clear();
    }

    pub fn undo(&mut self) -> bool {
        let Some(operation) = self.undo.pop() else {
            return false;
        };
        match &operation {
            EditOp::Cells(changes) => {
                for change in changes.iter().rev() {
                    apply_change(&mut self.sheets, change, true);
                }
            }
            EditOp::Snapshot { before, .. } => {
                self.sheets = before.sheets.clone();
                self.active = before.active;
                self.styles = before.styles.clone();
            }
        }
        self.redo.push(operation);
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(operation) = self.redo.pop() else {
            return false;
        };
        match &operation {
            EditOp::Cells(changes) => {
                for change in changes {
                    apply_change(&mut self.sheets, change, false);
                }
            }
            EditOp::Snapshot { after, .. } => {
                self.sheets = after.sheets.clone();
                self.active = after.active;
                self.styles = after.styles.clone();
            }
        }
        self.undo.push(operation);
        true
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            sheets: self.sheets.clone(),
            active: self.active,
            styles: self.styles.clone(),
        }
    }

    pub fn save(&mut self, path: &Path) -> Result<(), String> {
        self.ensure_styles_parts()?;
        for index in 0..self.sheets.len() {
            let prepared: Vec<((usize, usize), Cell, Option<String>)> = {
                let sheet = &self.sheets[index];
                sheet
                    .cells
                    .iter()
                    .filter(|(key, cell)| sheet.original.get(*key) != Some(*cell))
                    .map(|(key, cell)| {
                        let computed = cell.formula.as_ref().map(|_| {
                            let value = self.value(index, key.0, key.1);
                            value.display()
                        });
                        (*key, cell.clone(), computed)
                    })
                    .collect()
            };
            let removed: Vec<(usize, usize)> = {
                let sheet = &self.sheets[index];
                sheet
                    .original
                    .keys()
                    .filter(|key| !sheet.cells.contains_key(key))
                    .copied()
                    .collect()
            };
            let (sheets, styles) = (&mut self.sheets, &self.styles);
            apply_sheet_changes(&mut sheets[index], styles, prepared, removed);
        }
        self.sync_workbook_parts()?;
        self.zip.set(
            "xl/styles.xml",
            self.styles.serialize().as_bytes(),
        );
        for sheet in &self.sheets {
            let mut text = String::from(
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n",
            );
            text.push_str(&xml::serialize(&sheet.root));
            self.zip.set(&sheet.path, text.as_bytes());
        }
        self.zip.save_file(path)?;
        for sheet in &mut self.sheets {
            sheet.original = sheet.cells.clone();
        }
        Ok(())
    }

    fn ensure_styles_parts(&mut self) -> Result<(), String> {
        self.zip
            .set("xl/styles.xml", self.styles.serialize().as_bytes());
        self.add_content_type_override(
            "xl/styles.xml",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml",
        );
        let rels_path = "xl/_rels/workbook.xml.rels";
        let mut root = match self.zip.get_text(rels_path) {
            Some(text) => xml::parse(&text)?,
            None => Element::new("Relationships"),
        };
        let has_styles = root.elements().any(|rel| {
            rel.attr("Type")
                .map(|value| value.ends_with("/styles"))
                .unwrap_or(false)
        });
        if !has_styles {
            let mut relation = Element::new("Relationship");
            let id = format!("rIdStyles{}", root.elements().count() + 1);
            relation.set_attr("Id", &id);
            relation.set_attr(
                "Type",
                "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles",
            );
            relation.set_attr("Target", "styles.xml");
            root.push(relation);
            self.zip.set(rels_path, xml::serialize(&root).as_bytes());
        }
        Ok(())
    }

    fn add_content_type_override(&mut self, part: &str, content_type: &str) {
        let path = "[Content_Types].xml";
        let Some(text) = self.zip.get_text(path) else {
            return;
        };
        let Ok(mut root) = xml::parse(&text) else {
            return;
        };
        let part_name = format!("/{part}");
        if root.elements().any(|item| item.attr("PartName") == Some(part_name.as_str())) {
            return;
        }
        let mut element = Element::new("Override");
        element.set_attr("PartName", &part_name);
        element.set_attr("ContentType", content_type);
        root.push(element);
        self.zip.set(path, xml::serialize(&root).as_bytes());
    }

    fn remove_content_type_override(&mut self, part: &str) {
        let path = "[Content_Types].xml";
        let Some(text) = self.zip.get_text(path) else {
            return;
        };
        let Ok(mut root) = xml::parse(&text) else {
            return;
        };
        let part_name = format!("/{part}");
        root.children.retain(|node| {
            !matches!(node, Node::Element(element)
                if element.name == "Override" && element.attr("PartName") == Some(part_name.as_str()))
        });
        self.zip.set(path, xml::serialize(&root).as_bytes());
    }

    /// 同步 workbook.xml / rels 中的工作表名称、顺序、活动标签。
    fn sync_workbook_parts(&mut self) -> Result<(), String> {
        let workbook_path = "xl/workbook.xml";
        let rels_path = "xl/_rels/workbook.xml.rels";
        let mut workbook = match self.zip.get_text(workbook_path) {
            Some(text) => xml::parse(&text)?,
            None => Element::new("workbook"),
        };
        let mut rels = match self.zip.get_text(rels_path) {
            Some(text) => xml::parse(&text)?,
            None => Element::new("Relationships"),
        };
        let existing_relations: Vec<(String, String)> = rels
            .elements()
            .filter(|rel| {
                rel.attr("Type")
                    .map(|value| value.ends_with("/worksheet"))
                    .unwrap_or(false)
            })
            .filter_map(|rel| {
                Some((
                    rel.attr("Id")?.to_string(),
                    normalize_target(rel.attr("Target")?),
                ))
            })
            .collect();
        let used_ids: Vec<String> = rels
            .elements()
            .filter_map(|rel| rel.attr("Id").map(|id| id.to_string()))
            .collect();
        // 移除全部工作表关系，再按当前工作表顺序重建。
        rels.children.retain(|node| {
            !matches!(node, Node::Element(element)
                if element.attr("Type").map(|value| value.ends_with("/worksheet")).unwrap_or(false))
        });
        let mut added: Vec<(String, String)> = Vec::new();
        let existing_sheets: Vec<Element> = workbook
            .first_child_mut("sheets")
            .map(|list| {
                list.elements()
                    .filter(|element| local(&element.name) == "sheet")
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        let mut new_sheet_elements = Vec::new();
        for (index, sheet) in self.sheets.iter().enumerate() {
            let existing = existing_relations
                .iter()
                .find(|(_, target)| *target == sheet.path)
                .map(|(id, _)| id.clone());
            let mut rid = existing.clone().unwrap_or_else(|| format!("rIdSheet{}", index + 1));
            while existing.is_none() && used_ids.contains(&rid) {
                rid.push('_');
            }
            let mut element = existing_sheets
                .get(index)
                .cloned()
                .unwrap_or_else(|| Element::new("sheet"));
            element.set_attr("name", &sheet.name);
            element.set_attr("sheetId", &(index + 1).to_string());
            element.set_attr("r:id", &rid);
            new_sheet_elements.push(element);
            if !added.iter().any(|(id, _)| *id == rid) {
                let mut relation = Element::new("Relationship");
                relation.set_attr("Id", &rid);
                relation.set_attr(
                    "Type",
                    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet",
                );
                relation.set_attr("Target", sheet.path.trim_start_matches("xl/"));
                rels.push(relation);
                added.push((rid, sheet.path.clone()));
            }
        }
        if let Some(list) = workbook.first_child_mut("sheets") {
            list.children.clear();
            for element in new_sheet_elements {
                list.push(element);
            }
        } else {
            let mut list = Element::new("sheets");
            for element in new_sheet_elements {
                list.push(element);
            }
            workbook.push(list);
        }
        if let Some(views) = workbook.first_child_mut("bookViews") {
            if let Some(view) = views.first_child_mut("workbookView") {
                view.set_attr("activeTab", &self.active.min(self.sheets.len() - 1).to_string());
            }
        }
        self.zip.set(workbook_path, xml::serialize(&workbook).as_bytes());
        self.zip.set(rels_path, xml::serialize(&rels).as_bytes());
        Ok(())
    }
}

fn apply_change(sheets: &mut [Sheet], change: &Change, undo: bool) {
    let value = if undo {
        change.before.clone()
    } else {
        change.after.clone()
    };
    let Some(sheet) = sheets.get_mut(change.sheet) else {
        return;
    };
    match value {
        Some(cell) => {
            sheet.max_row = sheet.max_row.max(change.row);
            sheet.max_col = sheet.max_col.max(change.col);
            sheet.cells.insert((change.row, change.col), cell);
        }
        None => {
            sheet.cells.remove(&(change.row, change.col));
        }
    }
    sheet.recompute_bounds();
}

fn local(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

fn normalize_target(target: &str) -> String {
    if let Some(stripped) = target.strip_prefix('/') {
        stripped.to_string()
    } else if target.starts_with("xl/") {
        target.to_string()
    } else {
        format!("xl/{target}")
    }
}

fn parse_shared_strings(text: &str) -> Vec<String> {
    if text.is_empty() {
        return Vec::new();
    }
    let Ok(root) = xml::parse(text) else {
        return Vec::new();
    };
    root.elements()
        .filter(|element| local(&element.name) == "si")
        .map(si_text)
        .collect()
}

fn si_text(element: &Element) -> String {
    let mut out = String::new();
    for child in element.elements() {
        if local(&child.name) == "t" {
            out.push_str(&child.text());
        } else if local(&child.name) == "r" {
            if let Some(t) = child.elements().find(|item| local(&item.name) == "t") {
                out.push_str(&t.text());
            }
        }
    }
    out
}

fn parse_sheet(name: String, path: String, root: Element, shared: &[String]) -> Sheet {
    let mut cells = BTreeMap::new();
    let mut row_heights = BTreeMap::new();
    let mut hidden_rows = BTreeSet::new();
    let mut max_row = 0usize;
    let mut max_col = 0usize;
    if let Some(data) = root.first_child("sheetData") {
        for (row_index, row) in data
            .elements()
            .filter(|element| local(&element.name) == "row")
            .enumerate()
        {
            let row_number = row
                .attr("r")
                .and_then(|value| value.parse::<usize>().ok())
                .map(|value| value - 1)
                .unwrap_or(row_index);
            if row
                .attr("hidden")
                .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
                .unwrap_or(false)
            {
                hidden_rows.insert(row_number);
            }
            if let Some(height) = row.attr("ht").and_then(|value| value.parse::<f32>().ok()) {
                row_heights.insert(row_number, height);
            }
            let mut next_col = 0usize;
            for cell in row
                .elements()
                .filter(|element| local(&element.name) == "c")
            {
                let (row_at, col_at) = cell
                    .attr("r")
                    .and_then(parse_ref)
                    .unwrap_or((row_number, next_col));
                next_col = col_at + 1;
                let style = cell
                    .attr("s")
                    .and_then(|value| value.parse::<u32>().ok())
                    .unwrap_or(0);
                let formula = cell
                    .elements()
                    .find(|item| local(&item.name) == "f")
                    .map(|item| item.text())
                    .filter(|text| !text.is_empty());
                let kind = cell.attr("t").unwrap_or("n");
                let text = if kind == "inlineStr" {
                    cell.elements()
                        .find(|item| local(&item.name) == "is")
                        .map(si_text)
                        .unwrap_or_default()
                } else if kind == "s" {
                    cell.elements()
                        .find(|item| local(&item.name) == "v")
                        .and_then(|item| item.text().trim().parse::<usize>().ok())
                        .and_then(|index| shared.get(index).cloned())
                        .unwrap_or_default()
                } else if kind == "b" {
                    match cell
                        .elements()
                        .find(|item| local(&item.name) == "v")
                        .map(|item| item.text())
                    {
                        Some(text) if text.trim() == "1" => "TRUE".into(),
                        Some(_) => "FALSE".into(),
                        None => String::new(),
                    }
                } else {
                    cell.elements()
                        .find(|item| local(&item.name) == "v")
                        .map(|item| item.text())
                        .unwrap_or_default()
                };
                let text = text.trim().to_string();
                if formula.is_some() || !text.is_empty() || style != 0 {
                    max_row = max_row.max(row_at);
                    max_col = max_col.max(col_at);
                    cells.insert(
                        (row_at, col_at),
                        Cell {
                            text,
                            formula,
                            style,
                        },
                    );
                }
            }
        }
    }
    // 维度声明也影响空白表格的可编辑区域
    if let Some(dimension) = root.first_child("dimension") {
        if let Some(reference) = dimension.attr("ref") {
            if let Some((row, col)) = reference.split(':').last().and_then(parse_ref) {
                max_row = max_row.max(row);
                max_col = max_col.max(col);
            }
        }
    }
    let mut col_widths = Vec::new();
    if let Some(cols) = root.first_child("cols") {
        for col in cols.elements().filter(|element| local(&element.name) == "col") {
            let min = col
                .attr("min")
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(1)
                .saturating_sub(1);
            let max = col
                .attr("max")
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(min + 1)
                .saturating_sub(1);
            let width = col
                .attr("width")
                .and_then(|value| value.parse::<f32>().ok())
                .unwrap_or(DEFAULT_COL_WIDTH);
            let hidden = col
                .attr("hidden")
                .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            for index in min..=max {
                if col_widths.len() <= index {
                    col_widths.resize(index + 1, DEFAULT_COL_WIDTH);
                }
                if width != DEFAULT_COL_WIDTH {
                    col_widths[index] = width;
                }
            }
            if hidden {
                // 隐藏列在结构字段里单独保存，解析时丢弃列号信息，
                // 由 sheet 级集合保存。
            }
        }
    }
    let mut hidden_cols = BTreeSet::new();
    if let Some(cols) = root.first_child("cols") {
        for col in cols.elements().filter(|element| local(&element.name) == "col") {
            if col
                .attr("hidden")
                .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
                .unwrap_or(false)
            {
                let min = col
                    .attr("min")
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap_or(1)
                    .saturating_sub(1);
                let max = col
                    .attr("max")
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap_or(min + 1)
                    .saturating_sub(1);
                for index in min..=max {
                    hidden_cols.insert(index);
                }
            }
        }
    }
    let mut merges = Vec::new();
    if let Some(container) = root.first_child("mergeCells") {
        for merge in container
            .elements()
            .filter(|element| local(&element.name) == "mergeCell")
        {
            if let Some(reference) = merge.attr("ref") {
                if let Some(range) = parse_range(reference) {
                    merges.push(range);
                }
            }
        }
    }
    let mut freeze_rows = 0;
    let mut freeze_cols = 0;
    if let Some(view) = root
        .first_child("sheetViews")
        .and_then(|views| views.first_child("sheetView"))
    {
        if let Some(pane) = view.first_child("pane") {
            if pane.attr("state") == Some("frozen") {
                freeze_cols = pane
                    .attr("xSplit")
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap_or(0);
                freeze_rows = pane
                    .attr("ySplit")
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap_or(0);
            }
        }
    }
    let auto_filter = root
        .first_child("autoFilter")
        .and_then(|item| item.attr("ref"))
        .and_then(parse_range);
    Sheet {
        name,
        path,
        root,
        cells,
        original: BTreeMap::new(),
        max_row,
        max_col,
        col_widths,
        row_heights,
        merges,
        freeze_rows,
        freeze_cols,
        auto_filter,
        hidden_rows,
        hidden_cols,
        filtered_rows: BTreeSet::new(),
    }
}

pub fn parse_ref(reference: &str) -> Option<(usize, usize)> {
    let mut col = 0usize;
    let mut row = 0usize;
    let mut seen_row = false;
    let mut has_col = false;
    for ch in reference.chars() {
        if ch == '$' {
            continue;
        }
        if ch.is_ascii_alphabetic() {
            if seen_row {
                return None;
            }
            col = col * 26 + (ch.to_ascii_uppercase() as usize - 'A' as usize + 1);
            has_col = true;
        } else if ch.is_ascii_digit() {
            seen_row = true;
            row = row * 10 + (ch as usize - '0' as usize);
        } else {
            return None;
        }
    }
    if !has_col || row == 0 {
        return None;
    }
    Some((row - 1, col - 1))
}

fn parse_range(reference: &str) -> Option<MergeRange> {
    let mut parts = reference.split(':');
    let first = parts.next()?;
    let (r1, c1) = parse_ref(first)?;
    let (r2, c2) = parts.next().and_then(parse_ref).unwrap_or((r1, c1));
    Some(MergeRange::new(r1, c1, r2, c2))
}

pub fn column_name(col: usize) -> String {
    let mut name = String::new();
    let mut value = col + 1;
    while value > 0 {
        let digit = ((value - 1) % 26) as u8;
        name.insert(0, (b'A' + digit) as char);
        value = (value - 1) / 26;
    }
    name
}

pub fn cell_name(row: usize, col: usize) -> String {
    format!("{}{}", column_name(col), row + 1)
}

fn apply_sheet_changes(
    sheet: &mut Sheet,
    styles: &Styles,
    prepared: Vec<((usize, usize), Cell, Option<String>)>,
    removed: Vec<(usize, usize)>,
) {
    let _ = styles;
    if prepared.is_empty() && removed.is_empty() && !sheet.original.is_empty() {
        // 没有单元格变化时仍需刷新合并/冻结/筛选等结构。
    }
    ensure_sheet_data(sheet);
    for ((row, col), cell, computed) in prepared {
        set_cell_element(sheet, row, col, &cell, computed.as_deref());
    }
    for (row, col) in removed {
        remove_cell_element(sheet, row, col);
    }
    refresh_structure(sheet);
}

fn ensure_sheet_data(sheet: &mut Sheet) {
    if sheet.root.first_child("sheetData").is_none() {
        sheet
            .root
            .children
            .insert(0, Node::Element(Element::new("sheetData")));
    }
}

fn sheet_data_mut(sheet: &mut Sheet) -> &mut Element {
    sheet.root.first_child_mut("sheetData").unwrap()
}

fn find_row<'a>(data: &'a mut Element, row: usize) -> Option<&'a mut Element> {
    let target = (row + 1).to_string();
    data.elements_mut()
        .find(|element| local(&element.name) == "row" && element.attr("r") == Some(target.as_str()))
}

fn ensure_row<'a>(data: &'a mut Element, row: usize) -> &'a mut Element {
    let target = (row + 1).to_string();
    let existing = data
        .elements()
        .position(|element| local(&element.name) == "row" && element.attr("r") == Some(target.as_str()));
    let index = match existing {
        Some(index) => index,
        None => {
            let mut element = Element::new("row");
            element.set_attr("r", &target);
            let mut insert_at = data.children.len();
            for probe in 0..data.children.len() {
                let value = match &data.children[probe] {
                    Node::Element(current) if local(&current.name) == "row" => {
                        current.attr("r").and_then(|r| r.parse::<usize>().ok())
                    }
                    _ => None,
                };
                if let Some(value) = value {
                    if value > row + 1 {
                        insert_at = probe;
                        break;
                    }
                }
            }
            data.children.insert(insert_at, Node::Element(element));
            insert_at
        }
    };
    match &mut data.children[index] {
        Node::Element(element) => element,
        _ => unreachable!(),
    }
}

fn set_cell_element(
    sheet: &mut Sheet,
    row: usize,
    col: usize,
    cell: &Cell,
    computed: Option<&str>,
) {
    let reference = cell_name(row, col);
    let data = sheet_data_mut(sheet);
    let row_element = ensure_row(data, row);
    let mut element = Element::new("c");
    element.set_attr("r", &reference);
    if cell.style != 0 {
        element.set_attr("s", &cell.style.to_string());
    }
    if let Some(formula) = &cell.formula {
        let mut f = Element::new("f");
        f.push_text(formula);
        element.push(f);
        let value = computed.unwrap_or("0");
        let mut v = Element::new("v");
        v.push_text(value);
        if value.starts_with('#') {
            element.set_attr("t", "e");
        } else if value.parse::<f64>().is_err() {
            element.set_attr("t", "str");
        }
        element.push(v);
    } else if cell.text.eq_ignore_ascii_case("TRUE") || cell.text.eq_ignore_ascii_case("FALSE") {
        element.set_attr("t", "b");
        let mut v = Element::new("v");
        v.push_text(if cell.text.eq_ignore_ascii_case("TRUE") { "1" } else { "0" });
        element.push(v);
    } else if cell.text.trim().parse::<f64>().is_ok() {
        let mut v = Element::new("v");
        v.push_text(cell.text.trim());
        element.push(v);
    } else if !cell.text.is_empty() {
        element.set_attr("t", "inlineStr");
        let mut is = Element::new("is");
        let mut t = Element::new("t");
        t.set_attr("xml:space", "preserve");
        t.push_text(&cell.text);
        is.push(t);
        element.push(is);
    }

    let existing = row_element
        .elements()
        .position(|current| local(&current.name) == "c" && current.attr("r") == Some(reference.as_str()));
    if let Some(index) = existing {
        row_element.children[index] = Node::Element(element);
        return;
    }
    let mut insert_at = row_element.children.len();
    for index in 0..row_element.children.len() {
        let existing_col = match &row_element.children[index] {
            Node::Element(existing) if local(&existing.name) == "c" => {
                existing.attr("r").and_then(parse_ref).map(|(_, col)| col)
            }
            _ => None,
        };
        if let Some(existing_col) = existing_col {
            if existing_col > col {
                insert_at = index;
                break;
            }
        }
    }
    row_element.children.insert(insert_at, Node::Element(element));
}

fn remove_cell_element(sheet: &mut Sheet, row: usize, col: usize) {
    let reference = cell_name(row, col);
    let data = sheet_data_mut(sheet);
    if let Some(row_element) = find_row(data, row) {
        row_element.children.retain(|node| {
            !matches!(node, Node::Element(element)
                if local(&element.name) == "c" && element.attr("r") == Some(reference.as_str()))
        });
    }
}

fn refresh_structure(sheet: &mut Sheet) {
    // 顺序：sheetPr, dimension, sheetViews, sheetFormatPr, cols, sheetData, autoFilter, mergeCells
    if let Some(index) = sheet
        .root
        .children
        .iter()
        .position(|node| matches!(node, Node::Element(element) if local(&element.name) == "dimension"))
    {
        sheet.root.children.remove(index);
    }
    let mut dimension = Element::new("dimension");
    dimension.set_attr(
        "ref",
        &format!(
            "A1:{}{}",
            column_name(sheet.max_col.max(1)),
            sheet.max_row.max(1) + 1
        ),
    );
    sheet
        .root
        .children
        .insert(1.min(sheet.root.children.len()), Node::Element(dimension));

    // 列宽
    if let Some(index) = sheet
        .root
        .children
        .iter()
        .position(|node| matches!(node, Node::Element(element) if local(&element.name) == "cols"))
    {
        sheet.root.children.remove(index);
    }
    let mut cols = Element::new("cols");
    let max_col = sheet
        .col_widths
        .len()
        .max(sheet.max_col + 1)
        .saturating_sub(1);
    let mut col = 0usize;
    while col <= max_col {
        let width = sheet.col_width(col);
        let hidden = sheet.hidden_cols.contains(&col);
        let mut end = col;
        while end + 1 <= max_col
            && (sheet.col_width(end + 1) - width).abs() < 0.01
            && sheet.hidden_cols.contains(&(end + 1)) == hidden
        {
            end += 1;
        }
        if (width - DEFAULT_COL_WIDTH).abs() > 0.01 || hidden {
            let mut element = Element::new("col");
            element.set_attr("min", &(col + 1).to_string());
            element.set_attr("max", &(end + 1).to_string());
            element.set_attr("width", &format!("{width:.2}"));
            element.set_attr("customWidth", "1");
            if hidden {
                element.set_attr("hidden", "1");
            }
            cols.push(element);
        }
        col = end + 1;
    }
    if !cols.children.is_empty() {
        let data_position = sheet
            .root
            .children
            .iter()
            .position(|node| matches!(node, Node::Element(element) if local(&element.name) == "sheetData"))
            .unwrap_or(sheet.root.children.len());
        sheet
            .root
            .children
            .insert(data_position, Node::Element(cols));
    }

    // 冻结窗格
    if let Some(views) = sheet.root.first_child_mut("sheetViews") {
        if let Some(view) = views.first_child_mut("sheetView") {
            view.children.retain(|node| {
                !matches!(node, Node::Element(element) if local(&element.name) == "pane")
            });
            if sheet.freeze_rows > 0 || sheet.freeze_cols > 0 {
                let mut pane = Element::new("pane");
                if sheet.freeze_cols > 0 {
                    pane.set_attr("xSplit", &sheet.freeze_cols.to_string());
                }
                if sheet.freeze_rows > 0 {
                    pane.set_attr("ySplit", &sheet.freeze_rows.to_string());
                }
                pane.set_attr(
                    "topLeftCell",
                    &cell_name(sheet.freeze_rows, sheet.freeze_cols),
                );
                pane.set_attr("state", "frozen");
                view.children.insert(0, Node::Element(pane));
            }
        }
    }

    // 筛选
    sheet.root.children.retain(|node| {
        !matches!(node, Node::Element(element)
            if local(&element.name) == "autoFilter" || local(&element.name) == "mergeCells")
    });
    if let Some(filter) = sheet.auto_filter {
        let mut element = Element::new("autoFilter");
        element.set_attr("ref", &filter.reference());
        sheet.root.push(element);
    }
    if !sheet.merges.is_empty() {
        let mut container = Element::new("mergeCells");
        container.set_attr("count", &sheet.merges.len().to_string());
        for range in &sheet.merges {
            let mut element = Element::new("mergeCell");
            element.set_attr("ref", &range.reference());
            container.push(element);
        }
        sheet.root.push(container);
    }

    // 行高与隐藏
    let rows: Vec<(usize, Option<f32>, bool)> = sheet
        .row_heights
        .iter()
        .map(|(row, height)| (*row, Some(*height), sheet.hidden_rows.contains(row) || sheet.filtered_rows.contains(row)))
        .chain(
            sheet
                .hidden_rows
                .iter()
                .chain(sheet.filtered_rows.iter())
                .filter(|row| !sheet.row_heights.contains_key(row))
                .map(|row| (*row, None, true)),
        )
        .collect();
    for (row, height, hidden) in rows {
        let data = sheet_data_mut(sheet);
        let row_element = ensure_row(data, row);
        match height {
            Some(height) => {
                row_element.set_attr("ht", &format!("{height:.2}"));
                row_element.set_attr("customHeight", "1");
            }
            None => {}
        }
        if hidden {
            row_element.set_attr("hidden", "1");
        } else {
            row_element.attrs.retain(|(key, _)| local(key) != "hidden");
        }
    }

    // 保证已知元素顺序稳定
    let rank = |name: &str| match local(name) {
        "sheetPr" => 0,
        "dimension" => 1,
        "sheetViews" => 2,
        "sheetFormatPr" => 3,
        "cols" => 4,
        "sheetData" => 5,
        "autoFilter" => 6,
        "mergeCells" => 7,
        _ => 8,
    };
    sheet
        .root
        .children
        .sort_by_key(|node| match node {
            Node::Element(element) => rank(&element.name),
            Node::Text(_) => 9,
        });
}

fn compare_sort_values(a: &Value, b: &Value) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    match (a, b) {
        (Value::Empty, Value::Empty) => Ordering::Equal,
        (Value::Empty, _) => Ordering::Greater,
        (_, Value::Empty) => Ordering::Less,
        (Value::Number(x), Value::Number(y)) => {
            x.partial_cmp(y).unwrap_or(Ordering::Equal)
        }
        (Value::Text(x), Value::Text(y)) => x.to_lowercase().cmp(&y.to_lowercase()),
        (Value::Number(_), Value::Text(_)) => Ordering::Less,
        (Value::Text(_), Value::Number(_)) => Ordering::Greater,
        (Value::Bool(x), Value::Bool(y)) => x.cmp(y),
        _ => Ordering::Equal,
    }
}

fn shift_rows(sheet: &mut Sheet, at: usize, count: usize, delete: bool) {
    let entries: Vec<((usize, usize), Cell)> = sheet
        .cells
        .iter()
        .map(|(key, cell)| (*key, cell.clone()))
        .collect();
    sheet.cells.clear();
    for ((row, col), mut cell) in entries {
        if delete {
            if row >= at && row < at + count {
                continue;
            }
            if row >= at + count {
                if let Some(formula) = &cell.formula {
                    cell.formula = Some(shift_formula(formula, 0, at, count, true));
                }
                sheet.cells.insert((row - count, col), cell);
            } else {
                if let Some(formula) = &cell.formula {
                    cell.formula = Some(shift_formula(formula, 0, at, count, true));
                }
                sheet.cells.insert((row, col), cell);
            }
        } else {
            if let Some(formula) = &cell.formula {
                cell.formula = Some(shift_formula(formula, 0, at, count, false));
            }
            let row = if row >= at { row + count } else { row };
            sheet.cells.insert((row, col), cell);
        }
    }
    shift_merges_rows(&mut sheet.merges, at, count, delete);
    shift_map_rows(&mut sheet.row_heights, at, count, delete);
    shift_set_rows(&mut sheet.hidden_rows, at, count, delete);
    shift_set_rows(&mut sheet.filtered_rows, at, count, delete);
    sheet.recompute_bounds();
}

fn shift_cols(sheet: &mut Sheet, at: usize, count: usize, delete: bool) {
    let entries: Vec<((usize, usize), Cell)> = sheet
        .cells
        .iter()
        .map(|(key, cell)| (*key, cell.clone()))
        .collect();
    sheet.cells.clear();
    for ((row, col), mut cell) in entries {
        if delete {
            if col >= at && col < at + count {
                continue;
            }
            if let Some(formula) = &cell.formula {
                cell.formula = Some(shift_formula(formula, 1, at, count, true));
            }
            if col >= at + count {
                sheet.cells.insert((row, col - count), cell);
            } else {
                sheet.cells.insert((row, col), cell);
            }
        } else {
            if let Some(formula) = &cell.formula {
                cell.formula = Some(shift_formula(formula, 1, at, count, false));
            }
            let col = if col >= at { col + count } else { col };
            sheet.cells.insert((row, col), cell);
        }
    }
    shift_merges_cols(&mut sheet.merges, at, count, delete);
    let mut widths = std::mem::take(&mut sheet.col_widths);
    if delete {
        widths.drain(at.min(widths.len())..(at + count).min(widths.len()));
    } else {
        let fill = widths.get(at).copied().unwrap_or(DEFAULT_COL_WIDTH);
        for _ in 0..count {
            widths.insert(at.min(widths.len()), fill);
        }
    }
    sheet.col_widths = widths;
    shift_set_rows(&mut sheet.hidden_cols, at, count, delete);
    sheet.recompute_bounds();
}

fn shift_map_rows(map: &mut BTreeMap<usize, f32>, at: usize, count: usize, delete: bool) {
    let entries: Vec<(usize, f32)> = map.iter().map(|(key, value)| (*key, *value)).collect();
    map.clear();
    for (row, value) in entries {
        if delete && row >= at && row < at + count {
            continue;
        }
        let row = if delete {
            if row >= at + count {
                row - count
            } else {
                row
            }
        } else if row >= at {
            row + count
        } else {
            row
        };
        map.insert(row, value);
    }
}

fn shift_set_rows(set: &mut BTreeSet<usize>, at: usize, count: usize, delete: bool) {
    let entries: Vec<usize> = set.iter().copied().collect();
    set.clear();
    for row in entries {
        if delete && row >= at && row < at + count {
            continue;
        }
        let row = if delete {
            if row >= at + count {
                row - count
            } else {
                row
            }
        } else if row >= at {
            row + count
        } else {
            row
        };
        set.insert(row);
    }
}

fn shift_merges_rows(merges: &mut Vec<MergeRange>, at: usize, count: usize, delete: bool) {
    merges.retain_mut(|range| {
        if delete {
            if range.r1 >= at && range.r2 < at + count {
                return false;
            }
            if range.r1 >= at + count {
                range.r1 -= count;
                range.r2 -= count;
            } else if range.r2 >= at + count {
                range.r2 -= count;
            } else if range.r2 >= at {
                range.r2 = at.saturating_sub(1);
            }
        } else {
            if range.r1 >= at {
                range.r1 += count;
                range.r2 += count;
            } else if range.r2 >= at {
                range.r2 += count;
            }
        }
        true
    });
}

fn shift_merges_cols(merges: &mut Vec<MergeRange>, at: usize, count: usize, delete: bool) {
    merges.retain_mut(|range| {
        if delete {
            if range.c1 >= at && range.c2 < at + count {
                return false;
            }
            if range.c1 >= at + count {
                range.c1 -= count;
                range.c2 -= count;
            } else if range.c2 >= at + count {
                range.c2 -= count;
            } else if range.c2 >= at {
                range.c2 = at.saturating_sub(1);
            }
        } else {
            if range.c1 >= at {
                range.c1 += count;
                range.c2 += count;
            } else if range.c2 >= at {
                range.c2 += count;
            }
        }
        true
    });
}

/// 结构变化后调整公式中的引用。`axis` 0 行、1 列。
fn shift_formula(formula: &str, axis: u8, at: usize, count: usize, delete: bool) -> String {
    let chars: Vec<char> = formula.chars().collect();
    let mut out = String::new();
    let mut index = 0usize;
    while index < chars.len() {
        let ch = chars[index];
        if ch == '"' {
            out.push(ch);
            index += 1;
            while index < chars.len() {
                out.push(chars[index]);
                if chars[index] == '"' {
                    index += 1;
                    if index < chars.len() && chars[index] == '"' {
                        out.push('"');
                        index += 1;
                    } else {
                        break;
                    }
                } else {
                    index += 1;
                }
            }
            continue;
        }
        if ch == '\'' {
            out.push(ch);
            index += 1;
            while index < chars.len() {
                out.push(chars[index]);
                if chars[index] == '\'' {
                    index += 1;
                    if index < chars.len() && chars[index] == '\'' {
                        out.push('\'');
                        index += 1;
                    } else {
                        break;
                    }
                } else {
                    index += 1;
                }
            }
            continue;
        }
        if ch.is_ascii_alphabetic() || ch == '$' {
            let start = index;
            while index < chars.len()
                && (chars[index].is_ascii_alphanumeric() || chars[index] == '$')
            {
                index += 1;
            }
            let token: String = chars[start..index].iter().collect();
            let next = chars.get(index).copied();
            if next == Some('!') || next == Some('(') {
                out.push_str(&token);
                continue;
            }
            if let Some((row, col, abs_row, abs_col)) = parse_ref_flags(&token) {
                let (mut new_row, mut new_col) = (row, col);
                let mut removed = false;
                if axis == 0 {
                    if delete {
                        if row >= at && row < at + count {
                            removed = true;
                        } else if row >= at + count {
                            new_row -= count;
                        }
                    } else if row >= at {
                        new_row += count;
                    }
                } else if delete {
                    if col >= at && col < at + count {
                        removed = true;
                    } else if col >= at + count {
                        new_col -= count;
                    }
                } else if col >= at {
                    new_col += count;
                }
                if removed {
                    out.push_str("#REF!");
                } else {
                    if abs_col {
                        out.push('$');
                    }
                    out.push_str(&column_name(new_col));
                    if abs_row {
                        out.push('$');
                    }
                    out.push_str(&(new_row + 1).to_string());
                }
            } else {
                out.push_str(&token);
            }
            continue;
        }
        out.push(ch);
        index += 1;
    }
    out
}

fn parse_ref_flags(reference: &str) -> Option<(usize, usize, bool, bool)> {
    let mut col = 0usize;
    let mut row = 0usize;
    let mut seen_row = false;
    let mut has_col = false;
    let mut abs_col = false;
    let mut abs_row = false;
    let mut expect_col = true;
    for ch in reference.chars() {
        if ch == '$' {
            if expect_col {
                abs_col = true;
            } else {
                abs_row = true;
            }
            continue;
        }
        if ch.is_ascii_alphabetic() {
            if seen_row {
                return None;
            }
            col = col * 26 + (ch.to_ascii_uppercase() as usize - 'A' as usize + 1);
            has_col = true;
            expect_col = true;
        } else if ch.is_ascii_digit() {
            seen_row = true;
            expect_col = false;
            row = row * 10 + (ch as usize - '0' as usize);
        } else {
            return None;
        }
    }
    if !has_col || row == 0 {
        return None;
    }
    Some((row - 1, col - 1, abs_row, abs_col))
}

/// 复制公式时按相对偏移平移引用。
pub fn translate_formula(formula: &str, row_delta: i32, col_delta: i32) -> String {
    let chars: Vec<char> = formula.chars().collect();
    let mut out = String::new();
    let mut index = 0usize;
    while index < chars.len() {
        let ch = chars[index];
        if ch == '"' || ch == '\'' {
            let quote = ch;
            out.push(ch);
            index += 1;
            while index < chars.len() {
                out.push(chars[index]);
                if chars[index] == quote {
                    index += 1;
                    if index < chars.len() && chars[index] == quote {
                        out.push(quote);
                        index += 1;
                    } else {
                        break;
                    }
                } else {
                    index += 1;
                }
            }
            continue;
        }
        if ch.is_ascii_alphabetic() || ch == '$' {
            let start = index;
            while index < chars.len()
                && (chars[index].is_ascii_alphanumeric() || chars[index] == '$')
            {
                index += 1;
            }
            let token: String = chars[start..index].iter().collect();
            let next = chars.get(index).copied();
            if next == Some('!') || next == Some('(') {
                out.push_str(&token);
                continue;
            }
            if let Some((row, col, abs_row, abs_col)) = parse_ref_flags(&token) {
                let new_row = if abs_row {
                    row as i64
                } else {
                    (row as i64 + row_delta as i64).max(0)
                };
                let new_col = if abs_col {
                    col as i64
                } else {
                    (col as i64 + col_delta as i64).max(0)
                };
                if abs_col {
                    out.push('$');
                }
                out.push_str(&column_name(new_col as usize));
                if abs_row {
                    out.push('$');
                }
                out.push_str(&(new_row as usize + 1).to_string());
            } else {
                out.push_str(&token);
            }
            continue;
        }
        out.push(ch);
        index += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn column_names() {
        assert_eq!(column_name(0), "A");
        assert_eq!(column_name(25), "Z");
        assert_eq!(column_name(26), "AA");
        assert_eq!(parse_ref("AA10"), Some((9, 26)));
    }

    #[test]
    fn create_save_roundtrip() {
        let dir = std::env::temp_dir().join("textm-xlsx-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("a.xlsx");
        let mut book = Workbook::create();
        book.set_cell(0, 0, 0, "12");
        book.set_cell(0, 0, 1, "=A1*2");
        book.set_cell(0, 1, 0, "文本");
        book.save(&path).unwrap();
        let loaded = Workbook::open(&path).unwrap();
        assert_eq!(loaded.display(0, 0, 0), "12");
        assert_eq!(loaded.display(0, 0, 1), "24");
        assert_eq!(loaded.display(0, 1, 0), "文本");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn formulas() {
        let mut book = Workbook::create();
        book.set_cell(0, 0, 0, "1");
        book.set_cell(0, 0, 1, "2");
        book.set_cell(0, 0, 2, "3");
        book.set_cell(0, 1, 0, "=SUM(A1:C1)");
        book.set_cell(0, 1, 1, "=IF(A1>0,100,200)");
        assert_eq!(book.display(0, 1, 0), "6");
        assert_eq!(book.display(0, 1, 1), "100");
    }

    #[test]
    fn formatting_and_sheets() {
        let mut book = Workbook::create();
        book.set_cell(0, 0, 0, "0.5");
        let style = book.format_range(0, MergeRange::new(0, 0, 0, 0), FormatAction::NumberFormat("0.00%".into()));
        assert!(style > 0);
        assert_eq!(book.display(0, 0, 0), "50.00%");
        let index = book.add_sheet("数据").unwrap();
        book.set_cell(index, 0, 0, "7");
        book.set_cell(0, 0, 1, "=数据!A1*3");
        assert_eq!(book.display(0, 0, 1), "21");
        book.freeze(0, 1, 1);
        book.merge(0, MergeRange::new(2, 0, 3, 1));
        let dir = std::env::temp_dir().join("textm-xlsx-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("b.xlsx");
        book.save(&path).unwrap();
        let loaded = Workbook::open(&path).unwrap();
        assert_eq!(loaded.sheets.len(), 2);
        assert_eq!(loaded.display(0, 0, 1), "21");
        assert_eq!(loaded.sheets[0].freeze_rows, 1);
        assert_eq!(loaded.sheets[0].freeze_cols, 1);
        assert_eq!(loaded.sheets[0].merges.len(), 1);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn insert_rows_shifts_formulas() {
        let mut book = Workbook::create();
        book.set_cell(0, 0, 0, "5");
        book.set_cell(0, 1, 0, "=A1+1");
        book.insert_rows(0, 0, 1);
        assert_eq!(book.sheets[0].cell_input(1, 0), "5");
        assert_eq!(book.sheets[0].cell_input(2, 0), "=A2+1");
    }
}

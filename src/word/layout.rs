//! Word 页面排版：把富文本模型排成一张张固定尺寸的页面。
//!
//! 输出的是与后端无关的绘制指令（文字、矩形、图片），GUI 用 GDI 精确绘制，
//! TUI 与测试可以用近似度量做文本预览。

use std::collections::HashMap;
use std::path::PathBuf;

use crate::render::Color;

use super::measure::Measurer;
use super::model::{
    Align, Block, Border, BorderStyle, Borders, DocModel, InlineImage, LineSpacing, Margins,
    NumberFormat, Numbering, Paragraph, SectionInfo, Table, TableCell, VAlign,
};

/// 1 像素 = 15 twips（96 DPI）。
const TWIPS_PER_PX: f32 = 15.0;

fn px(twips: i32, zoom: f32) -> i32 {
    (twips as f32 / TWIPS_PER_PX * zoom).round() as i32
}

fn px_f(value: f32, zoom: f32) -> i32 {
    (value * zoom).round() as i32
}

fn pt_px(points: f32, zoom: f32) -> i32 {
    (points * 4.0 / 3.0 * zoom).round().max(1.0) as i32
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Font {
    pub family: String,
    pub size: i32,
    pub bold: bool,
    pub italic: bool,
}

#[derive(Clone, Debug)]
pub enum Item {
    Text {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        text: String,
        font: Font,
        color: Color,
        background: Option<Color>,
        underline: bool,
        strike: bool,
        link: bool,
    },
    Rect {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        fill: Option<Color>,
        border: Option<Color>,
        thickness: i32,
    },
    Image {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        path: PathBuf,
    },
}

#[derive(Clone, Debug, Default)]
pub struct PageLayout {
    pub number: usize,
    pub width: i32,
    pub height: i32,
    pub section: usize,
    pub items: Vec<Item>,
    /// 页面内容区域（用于点击定位）。
    pub margin_left: i32,
    pub margin_top: i32,
    pub margin_right: i32,
    pub margin_bottom: i32,
}

#[derive(Clone, Debug, Default)]
pub struct DocumentLayout {
    pub pages: Vec<PageLayout>,
    pub page_w: i32,
    pub page_h: i32,
}

impl DocumentLayout {
    pub fn page_count(&self) -> usize {
        self.pages.len()
    }

    pub fn total_height(&self, gap: i32) -> i32 {
        let mut height = gap;
        for page in &self.pages {
            height += page.height + gap;
        }
        height
    }
}

#[derive(Clone, Debug)]
struct Segment {
    x: i32,
    text: String,
    font: Font,
    width: i32,
    height: i32,
    ascent: i32,
    color: Color,
    background: Option<Color>,
    underline: bool,
    strike: bool,
    link: bool,
    raise: i32,
    image: Option<InlineImage>,
}

#[derive(Clone, Debug)]
struct Line {
    segments: Vec<Segment>,
    width: i32,
    natural_height: i32,
    ascent: i32,
    indent: i32,
    available: i32,
    page_break_before: bool,
    page_break_after: bool,
}

impl Line {
    fn new(indent: i32, available: i32) -> Line {
        Line {
            segments: Vec::new(),
            width: 0,
            natural_height: 0,
            ascent: 0,
            indent,
            available,
            page_break_before: false,
            page_break_after: false,
        }
    }
}

#[derive(Clone, Debug)]
struct RowLayout {
    items: Vec<Item>,
    height: i32,
    header: bool,
}

struct Builder<'a> {
    model: &'a DocModel,
    measure: &'a mut dyn Measurer,
    zoom: f32,
    pages: Vec<PageLayout>,
    items: Vec<Item>,
    page_w: i32,
    page_h: i32,
    content_x: i32,
    content_y: i32,
    content_w: i32,
    content_bottom: i32,
    y: i32,
    section: usize,
    page_sections: Vec<usize>,
    counters: HashMap<(String, usize), i32>,
}

impl<'a> Builder<'a> {
    fn new(model: &'a DocModel, measure: &'a mut dyn Measurer, zoom: f32) -> Builder<'a> {
        Builder {
            model,
            measure,
            zoom,
            pages: Vec::new(),
            items: Vec::new(),
            page_w: 0,
            page_h: 0,
            content_x: 0,
            content_y: 0,
            content_w: 0,
            content_bottom: 0,
            y: 0,
            section: 0,
            page_sections: Vec::new(),
            counters: HashMap::new(),
        }
    }

    fn at_top(&self) -> bool {
        self.y <= self.content_y
    }

    fn start_page(&mut self, section: usize, info: &SectionInfo) {
        self.page_w = px(info.page_w, self.zoom).max(120);
        self.page_h = px(info.page_h, self.zoom).max(160);
        self.content_x = px(info.margins.left, self.zoom);
        self.content_y = px(info.margins.top, self.zoom);
        let right = px(info.margins.right, self.zoom);
        let bottom = px(info.margins.bottom, self.zoom);
        self.content_w = (self.page_w - self.content_x - right).max(40);
        self.content_bottom = (self.page_h - bottom).max(self.content_y + 20);
        self.y = self.content_y;
        self.items.clear();
        self.section = section;
        self.page_sections.push(section);
    }

    fn finish_page(&mut self) {
        if self.page_w == 0 {
            return;
        }
        let number = self.pages.len() + 1;
        let info = self
            .model
            .sections
            .get(self.section)
            .map(|section| section.info.clone())
            .unwrap_or_default();
        self.pages.push(PageLayout {
            number,
            width: self.page_w,
            height: self.page_h,
            section: self.section,
            items: std::mem::take(&mut self.items),
            margin_left: px(info.margins.left, self.zoom),
            margin_top: px(info.margins.top, self.zoom),
            margin_right: px(info.margins.right, self.zoom),
            margin_bottom: px(info.margins.bottom, self.zoom),
        });
        self.y = self.content_y;
    }

    fn new_page(&mut self) {
        self.finish_page();
        let info = self
            .model
            .sections
            .get(self.section)
            .map(|section| section.info.clone())
            .unwrap_or_default();
        self.start_page(self.section, &info);
    }

    fn run(&mut self) {
        let mut first = true;
        for index in 0..self.model.sections.len().max(1) {
            let section = self
                .model
                .sections
                .get(index)
                .cloned()
                .unwrap_or_else(|| super::model::Section {
                    start: 0,
                    end: 0,
                    info: SectionInfo::default(),
                });
            if first {
                self.start_page(index, &section.info);
                first = false;
            } else if section.info.break_type == super::model::SectionBreak::Continuous {
                self.section = index;
                self.page_sections.push(index);
            } else {
                self.finish_page();
                self.start_page(index, &section.info);
            }
            let start = section.start.min(self.model.blocks.len());
            let end = section.end.min(self.model.blocks.len());
            for block_index in start..end {
                let block = self.model.blocks[block_index].clone();
                match &block {
                    Block::Paragraph(paragraph) => self.place_paragraph(paragraph),
                    Block::Table(table) => self.place_table(table, self.content_x, self.content_w),
                }
            }
        }
        if !self.items.is_empty() || self.pages.is_empty() {
            self.finish_page();
        }
        self.add_headers_footers();
        self.resolve_fields();
    }

    fn place_paragraph(&mut self, paragraph: &Paragraph) {
        let lines = build_lines(
            paragraph,
            self.content_w,
            self.measure,
            self.zoom,
            &mut self.counters,
            &self.model.numbering,
        );
        if lines.is_empty() {
            return;
        }
        let before = px(paragraph.props.before, self.zoom);
        let after = px(paragraph.props.after, self.zoom);
        if paragraph.props.page_break_before && !self.at_top() {
            self.new_page();
        }
        if before > 0 {
            self.y += before;
        }
        if paragraph.props.page_break_before && self.at_top() {
            // 已经在新页顶部，无需额外分页。
        }
        let shade = paragraph.props.shade;
        let border_color = paragraph
            .props
            .borders
            .top
            .or(paragraph.props.borders.bottom)
            .map(|border| border.color);
        let paragraph_top = self.y;
        let mut last_line = 0usize;
        for index in 0..lines.len() {
            let line = &lines[index];
            let height = line_height(paragraph, line, self.measure, self.zoom);
            if line.page_break_before && !self.at_top() {
                self.new_page();
            }
            if self.y + height > self.content_bottom && !self.at_top() {
                self.new_page();
            }
            if let Some(color) = shade {
                self.items.push(Item::Rect {
                    x: self.content_x,
                    y: self.y,
                    w: self.content_w,
                    h: height,
                    fill: Some(color),
                    border: None,
                    thickness: 0,
                });
            }
            emit_line(
                &mut self.items,
                line,
                paragraph.props.align,
                index == lines.len() - 1,
                self.content_x,
                self.y,
                height,
                self.measure,
                self.zoom,
            );
            self.y += height;
            last_line = index;
            if line.page_break_after && index + 1 < lines.len() {
                self.new_page();
            }
        }
        // 段落底纹/边框
        if !paragraph.comment_ids.is_empty() {
            self.items.push(Item::Rect {
                x: self.content_x,
                y: paragraph_top,
                w: self.content_w,
                h: (self.y - paragraph_top).max(1),
                fill: Some(Color::rgb(255, 246, 230)),
                border: None,
                thickness: 0,
            });
        }
        if let Some(color) = border_color {
            if paragraph.props.borders.top.is_some() {
                self.items.push(Item::Rect {
                    x: self.content_x,
                    y: paragraph_top,
                    w: self.content_w,
                    h: 1,
                    fill: Some(color),
                    border: None,
                    thickness: 0,
                });
            }
            if paragraph.props.borders.bottom.is_some() {
                self.items.push(Item::Rect {
                    x: self.content_x,
                    y: self.y.max(paragraph_top + 1),
                    w: self.content_w,
                    h: 1,
                    fill: Some(color),
                    border: None,
                    thickness: 0,
                });
            }
        }
        let _ = last_line;
        if after > 0 {
            self.y += after;
        }
    }

    fn place_table(&mut self, table: &Table, x: i32, width: i32) {
        let (rows, table_width) = build_table(
            table,
            width,
            self.measure,
            self.zoom,
            &mut self.counters,
            &self.model.numbering,
        );
        let table_x = match table.align {
            Align::Center => x + (width - table_width).max(0) / 2,
            Align::Right => x + (width - table_width).max(0),
            _ => x,
        };
        let header_count = rows.iter().take_while(|row| row.header).count();
        for (index, row) in rows.iter().enumerate() {
            if self.y + row.height > self.content_bottom
                && !self.at_top()
                && row.height < self.content_bottom - self.content_y
            {
                self.new_page();
                // 重复表头
                for header in rows.iter().take(header_count) {
                    self.push_row(header, table_x);
                }
            }
            self.push_row(row, table_x);
            let _ = index;
        }
        self.y += px(120, self.zoom);
    }

    fn push_row(&mut self, row: &RowLayout, x: i32) {
        for item in &row.items {
            self.items.push(offset_item(item, x, self.y));
        }
        self.y += row.height;
    }

    fn add_headers_footers(&mut self) {
        let mut seen: HashMap<usize, usize> = HashMap::new();
        let mut pages: Vec<(usize, SectionInfo, i32, i32, i32, i32, usize, usize)> = Vec::new();
        for (index, page) in self.pages.iter().enumerate() {
            let info = self
                .model
                .sections
                .get(page.section)
                .map(|section| section.info.clone())
                .unwrap_or_default();
            let within = *seen.entry(page.section).or_insert(0);
            seen.insert(page.section, within + 1);
            pages.push((
                index,
                info,
                page.width,
                page.height,
                page.margin_left,
                page.margin_right,
                page.number,
                within,
            ));
        }
        for (index, info, page_width, page_height, margin_left, margin_right, number, within) in pages
        {
            let odd = number % 2 == 1;
            let use_first = info.title_page && within == 0;
            let (header_part, footer_part) = if use_first {
                (info.header_first.clone(), info.footer_first.clone())
            } else if !odd && info.header_even.is_some() {
                (info.header_even.clone(), info.footer_even.clone())
            } else {
                (info.header_default.clone(), info.footer_default.clone())
            };
            let content_w = page_width - margin_left - margin_right;
            let mut extra: Vec<Item> = Vec::new();
            if let Some(part) = header_part {
                if let Some(blocks) = self.model.headers.get(&part).cloned() {
                    let (items, _) = layout_blocks_plain(
                        &blocks,
                        content_w,
                        self.measure,
                        self.zoom,
                        &mut self.counters,
                        &self.model.numbering,
                    );
                    for item in items {
                        extra.push(offset_item(
                            &item,
                            margin_left,
                            px(info.header_dist, self.zoom),
                        ));
                    }
                }
            }
            if let Some(part) = footer_part {
                if let Some(blocks) = self.model.footers.get(&part).cloned() {
                    let (items, height) = layout_blocks_plain(
                        &blocks,
                        content_w,
                        self.measure,
                        self.zoom,
                        &mut self.counters,
                        &self.model.numbering,
                    );
                    let top = page_height - px(info.footer_dist, self.zoom) - height.max(1);
                    for item in items {
                        extra.push(offset_item(&item, margin_left, top));
                    }
                }
            }
            self.pages[index].items.extend(extra);
        }
    }

    fn resolve_fields(&mut self) {
        let total = self.pages.len();
        for page in &mut self.pages {
            for item in &mut page.items {
                if let Item::Text { text, .. } = item {
                    if text.contains('\u{1}') || text.contains('\u{2}') {
                        *text = text
                            .replace('\u{1}', &page.number.to_string())
                            .replace('\u{2}', &total.to_string());
                    }
                }
            }
        }
    }
}

trait SectionDefault {
    fn default_section() -> super::model::Section;
}

impl SectionDefault for super::model::Section {
    fn default_section() -> super::model::Section {
        super::model::Section {
            start: 0,
            end: 0,
            info: SectionInfo::default(),
        }
    }
}

pub fn layout(model: &DocModel, measure: &mut dyn Measurer, zoom: f32) -> DocumentLayout {
    let zoom = zoom.clamp(0.25, 4.0);
    let mut builder = Builder::new(model, measure, zoom);
    builder.run();
    let page_w = builder.pages.first().map(|page| page.width).unwrap_or(794);
    let page_h = builder.pages.first().map(|page| page.height).unwrap_or(1123);
    DocumentLayout {
        pages: builder.pages,
        page_w,
        page_h,
    }
}

// ---------------------------------------------------------------- 段落分行

fn build_lines(
    paragraph: &Paragraph,
    content_w: i32,
    measure: &mut dyn Measurer,
    zoom: f32,
    counters: &mut HashMap<(String, usize), i32>,
    numbering: &Numbering,
) -> Vec<Line> {
    let left = px(paragraph.props.left, zoom);
    let right = px(paragraph.props.right, zoom);
    let first_line = px(paragraph.props.first_line, zoom);
    let first_indent = left + first_line;
    let base_available = (content_w - left - right).max(24);
    let first_available = (content_w - first_indent - right).max(24);

    let (label, label_font, label_width) = if let Some(label) = number_label(paragraph, numbering, counters) {
        let font = paragraph
            .runs
            .first()
            .map(|run| run_font(&run.props, &label, zoom))
            .unwrap_or_else(|| Font {
                family: "宋体".into(),
                size: pt_px(11.0, zoom),
                bold: false,
                italic: false,
            });
        let width = measure.width(&label, &font);
        (Some(label), Some(font), width)
    } else {
        (None, None, 0)
    };

    let mut lines: Vec<Line> = Vec::new();
    let mut line = Line::new(first_indent, first_available);
    let mut x = 0i32;
    let mut first = true;
    let mut pending_break = false;

    if let (Some(label), Some(font)) = (&label, &label_font) {
        let height = measure.height(font);
        let ascent = measure.ascent(font);
        line.segments.push(Segment {
            x: 0,
            text: label.clone(),
            font: font.clone(),
            width: label_width,
            height,
            ascent,
            color: paragraph
                .runs
                .first()
                .map(|run| run.props.color)
                .unwrap_or(Color::rgb(0, 0, 0)),
            background: None,
            underline: false,
            strike: false,
            link: false,
            raise: 0,
            image: None,
        });
        x = (-first_line).max(label_width + 8);
        line.natural_height = height;
        line.ascent = ascent;
    }

    let mut started = false;
    for run in &paragraph.runs {
        if pending_break {
            if !line.segments.is_empty() || x > 0 {
                flush_line(&mut lines, &mut line, &mut x, &mut first, base_available);
            }
            line.page_break_before = true;
            pending_break = false;
        }
        if let Some(image) = &run.image {
            let mut width = px_f(image.width, zoom).max(1);
            let mut height = px_f(image.height, zoom).max(1);
            let limit = if first { first_available } else { base_available };
            if width > limit {
                let scale = limit as f32 / width as f32;
                width = (width as f32 * scale) as i32;
                height = (height as f32 * scale) as i32;
            }
            if x + width > limit && x > 0 {
                flush_line(&mut lines, &mut line, &mut x, &mut first, base_available);
            }
            let image_clone = image.clone();
            let offset_x = image.offset.map(|value| px_f(value.0, zoom)).unwrap_or(0);
            let _ = offset_x;
            line.segments.push(Segment {
                x,
                text: String::new(),
                font: Font {
                    family: String::new(),
                    size: height,
                    bold: false,
                    italic: false,
                },
                width,
                height,
                ascent: height,
                color: Color::rgb(0, 0, 0),
                background: None,
                underline: false,
                strike: false,
                link: false,
                raise: 0,
                image: Some(image_clone),
            });
            x += width;
            line.natural_height = line.natural_height.max(height);
            line.ascent = line.ascent.max(height);
            started = true;
            continue;
        }
        let text = if run.props.all_caps {
            run.text.to_uppercase()
        } else {
            run.text.clone()
        };
        let mut index = 0usize;
        let chars: Vec<char> = text.chars().collect();
        while index < chars.len() {
            if pending_break {
                if !line.segments.is_empty() || x > 0 {
                    flush_line(&mut lines, &mut line, &mut x, &mut first, base_available);
                }
                line.page_break_before = true;
                pending_break = false;
            }
            let ch = chars[index];
            match ch {
                '\n' => {
                    flush_line(&mut lines, &mut line, &mut x, &mut first, base_available);
                    index += 1;
                }
                '\u{0c}' => {
                    flush_line(&mut lines, &mut line, &mut x, &mut first, base_available);
                    pending_break = true;
                    index += 1;
                }
                '\t' => {
                    let stop = next_tab_stop(x, &paragraph.props.tabs, zoom, line.indent);
                    if stop > x {
                        x = stop;
                    }
                    index += 1;
                }
                ' ' => {
                    let font = run_font(&run.props, " ", zoom);
                    let width = measure.width(" ", &font);
                    let limit = if first { first_available } else { base_available };
                    if x + width > limit && started {
                        flush_line(&mut lines, &mut line, &mut x, &mut first, base_available);
                    }
                    push_text_segment(
                        &mut line,
                        &mut x,
                        " ",
                        run,
                        &font,
                        measure,
                        zoom,
                    );
                    index += 1;
                }
                _ => {
                    let mut end = index + 1;
                    let wide = is_wide(ch);
                    if !wide {
                        while end < chars.len() {
                            let next = chars[end];
                            if next.is_whitespace()
                                || next == '\n'
                                || next == '\t'
                                || next == '\u{0c}'
                                || is_wide(next)
                            {
                                break;
                            }
                            end += 1;
                        }
                    }
                    let word: String = chars[index..end].iter().collect();
                    let font = run_font(&run.props, &word, zoom);
                    let width = measure.width(&word, &font);
                    let limit = if first { first_available } else { base_available };
                    if x + width > limit && x > 0 {
                        flush_line(&mut lines, &mut line, &mut x, &mut first, base_available);
                    }
                    if width > limit {
                        // 超长单词逐字符断开
                        for item in word.chars() {
                            let piece = item.to_string();
                            let piece_font = run_font(&run.props, &piece, zoom);
                            let piece_width = measure.width(&piece, &piece_font);
                            let limit = if first { first_available } else { base_available };
                            if x + piece_width > limit && x > 0 {
                                flush_line(
                                    &mut lines,
                                    &mut line,
                                    &mut x,
                                    &mut first,
                                    base_available,
                                );
                            }
                            push_text_segment(
                                &mut line,
                                &mut x,
                                &piece,
                                run,
                                &piece_font,
                                measure,
                                zoom,
                            );
                        }
                    } else {
                        push_text_segment(
                            &mut line, &mut x, &word, run, &font, measure, zoom,
                        );
                    }
                    index = end;
                }
            }
            started = true;
        }
    }

    // 收尾：即使最后一行是空的也要保留，Word 的空段落占一行。
    flush_line(&mut lines, &mut line, &mut x, &mut first, base_available);
    if pending_break {
        if let Some(last) = lines.last_mut() {
            last.page_break_after = true;
        }
    }
    lines
}

fn flush_line(
    lines: &mut Vec<Line>,
    line: &mut Line,
    x: &mut i32,
    first: &mut bool,
    base_available: i32,
) {
    line.width = *x;
    if line.natural_height == 0 {
        // 空行使用一个默认高度的占位
        line.natural_height = 16;
        line.ascent = 12;
    }
    lines.push(std::mem::replace(line, Line::new(0, base_available)));
    *x = 0;
    *first = false;
}

fn push_text_segment(
    line: &mut Line,
    x: &mut i32,
    text: &str,
    run: &super::model::Run,
    font: &Font,
    measure: &mut dyn Measurer,
    zoom: f32,
) {
    let width = measure.width(text, font);
    let height = measure.height(font);
    let ascent = measure.ascent(font);
    let raise = match run.props.vert {
        super::model::VertAlign::Superscript => -(pt_px(run.props.size * 0.45, zoom)),
        super::model::VertAlign::Subscript => pt_px(run.props.size * 0.2, zoom),
        super::model::VertAlign::Baseline => 0,
    };
    line.segments.push(Segment {
        x: *x,
        text: text.to_string(),
        font: font.clone(),
        width,
        height,
        ascent,
        color: run.props.color,
        background: run.props.highlight,
        underline: run.props.underline,
        strike: run.props.strike,
        link: run.link,
        raise,
        image: None,
    });
    *x += width;
    line.natural_height = line.natural_height.max(height + raise.abs());
    line.ascent = line.ascent.max(ascent + raise.max(0));
}

fn next_tab_stop(x: i32, tabs: &[i32], zoom: f32, indent: i32) -> i32 {
    if !tabs.is_empty() {
        for stop in tabs {
            let stop = px(*stop, zoom) - indent;
            if stop > x {
                return stop;
            }
        }
    }
    let default = px(720, zoom).max(24);
    ((x / default) + 1) * default
}

fn line_height(
    paragraph: &Paragraph,
    line: &Line,
    _measure: &mut dyn Measurer,
    zoom: f32,
) -> i32 {
    let natural = line.natural_height.max(1);
    match paragraph.props.line {
        LineSpacing::Auto(value) => {
            ((natural as f32) * (value as f32 / 240.0)).round().max(1.0) as i32
        }
        LineSpacing::Exact(value) => px(value, zoom).max(1),
        LineSpacing::AtLeast(value) => natural.max(px(value, zoom)),
    }
}

fn emit_line(
    items: &mut Vec<Item>,
    line: &Line,
    align: Align,
    last: bool,
    content_x: i32,
    top: i32,
    height: i32,
    measure: &mut dyn Measurer,
    zoom: f32,
) {
    let _ = measure;
    let _ = zoom;
    let extra = (line.available - line.width).max(0);
    let (mut shift, mut justify) = (0, false);
    match align {
        Align::Center => shift = extra / 2,
        Align::Right => shift = extra,
        Align::Justify if !last => justify = true,
        Align::Distribute if !last => justify = true,
        _ => {}
    }
    let spaces: i32 = line
        .segments
        .iter()
        .map(|segment| segment.text.matches(' ').count() as i32)
        .sum();
    let step = if justify && spaces > 0 {
        extra / spaces
    } else {
        0
    };
    let top_offset = (height - line.natural_height) / 2;
    let baseline = top + top_offset + line.ascent;
    let mut extra_shift = 0;
    for segment in &line.segments {
        let x = content_x + line.indent + shift + segment.x + extra_shift;
        if segment.image.is_some() {
            if let Some(image) = &segment.image {
                let offset = image
                    .offset
                    .map(|value| (px_f(value.0, zoom), px_f(value.1, zoom)))
                    .unwrap_or((0, 0));
                items.push(Item::Image {
                    x: x + offset.0,
                    y: top + top_offset + (line.natural_height - segment.height) + offset.1,
                    w: segment.width,
                    h: segment.height,
                    path: image.path.clone(),
                });
            }
        } else if !segment.text.is_empty() {
            if let Some(background) = segment.background {
                items.push(Item::Rect {
                    x,
                    y: baseline - segment.ascent + segment.raise,
                    w: segment.width,
                    h: segment.height,
                    fill: Some(background),
                    border: None,
                    thickness: 0,
                });
            }
            items.push(Item::Text {
                x,
                y: baseline - segment.ascent + segment.raise,
                w: segment.width,
                h: segment.height,
                text: segment.text.clone(),
                font: segment.font.clone(),
                color: segment.color,
                background: None,
                underline: segment.underline,
                strike: segment.strike,
                link: segment.link,
            });
        }
        if justify {
            extra_shift += segment.text.matches(' ').count() as i32 * step;
        }
    }
}

fn offset_item(item: &Item, dx: i32, dy: i32) -> Item {
    match item {
        Item::Text {
            x,
            y,
            w,
            h,
            text,
            font,
            color,
            background,
            underline,
            strike,
            link,
        } => Item::Text {
            x: x + dx,
            y: y + dy,
            w: *w,
            h: *h,
            text: text.clone(),
            font: font.clone(),
            color: *color,
            background: *background,
            underline: *underline,
            strike: *strike,
            link: *link,
        },
        Item::Rect {
            x,
            y,
            w,
            h,
            fill,
            border,
            thickness,
        } => Item::Rect {
            x: x + dx,
            y: y + dy,
            w: *w,
            h: *h,
            fill: *fill,
            border: *border,
            thickness: *thickness,
        },
        Item::Image { x, y, w, h, path } => Item::Image {
            x: x + dx,
            y: y + dy,
            w: *w,
            h: *h,
            path: path.clone(),
        },
    }
}

// ---------------------------------------------------------------- 编号

fn number_label(
    paragraph: &Paragraph,
    numbering: &Numbering,
    counters: &mut HashMap<(String, usize), i32>,
) -> Option<String> {
    let number = paragraph.number.as_ref()?;
    let definition = numbering.nums.get(&number.num_id)?;
    let level = definition.levels.get(number.level)?;
    if level.format == NumberFormat::None {
        return None;
    }
    let key = (number.num_id.clone(), number.level);
    let value = counters.entry(key).or_insert(level.start - 1);
    *value += 1;
    let current = *value;
    // 更深层级重新开始
    for deeper in number.level + 1..9 {
        if let Some(level) = definition.levels.get(deeper) {
            counters.insert((number.num_id.clone(), deeper), level.start - 1);
        }
    }
    if level.format == NumberFormat::Bullet {
        return Some(if level.text.is_empty() {
            "•".to_string()
        } else {
            level.text.clone()
        });
    }
    let mut out = String::new();
    let chars: Vec<char> = level.text.chars().collect();
    let mut index = 0usize;
    while index < chars.len() {
        if chars[index] == '%' && index + 1 < chars.len() {
            if let Some(digit) = chars[index + 1].to_digit(10) {
                let target = (digit as usize).saturating_sub(1);
                let (value, format) = if target == number.level {
                    (current, level.format)
                } else {
                    let value = counters
                        .get(&(number.num_id.clone(), target))
                        .copied()
                        .or_else(|| definition.levels.get(target).map(|item| item.start))
                        .unwrap_or(1);
                    let format = definition
                        .levels
                        .get(target)
                        .map(|item| item.format)
                        .unwrap_or(NumberFormat::Decimal);
                    (value, format)
                };
                out.push_str(&format_number(value, format));
                index += 2;
                continue;
            }
        }
        out.push(chars[index]);
        index += 1;
    }
    Some(out)
}

fn format_number(value: i32, format: NumberFormat) -> String {
    match format {
        NumberFormat::Decimal | NumberFormat::None => value.to_string(),
        NumberFormat::Bullet => "•".to_string(),
        NumberFormat::LowerLetter => letters(value, false),
        NumberFormat::UpperLetter => letters(value, true),
        NumberFormat::LowerRoman => roman(value).to_ascii_lowercase(),
        NumberFormat::UpperRoman => roman(value),
    }
}

fn letters(value: i32, upper: bool) -> String {
    let mut value = value.max(1) as usize;
    let mut out = String::new();
    while value > 0 {
        let digit = ((value - 1) % 26) as u8;
        out.insert(0, (b'a' + digit) as char);
        value = (value - 1) / 26;
    }
    if upper {
        out.to_uppercase()
    } else {
        out
    }
}

fn roman(value: i32) -> String {
    let mut value = value.max(1);
    let table = [
        (1000, "M"),
        (900, "CM"),
        (500, "D"),
        (400, "CD"),
        (100, "C"),
        (90, "XC"),
        (50, "L"),
        (40, "XL"),
        (10, "X"),
        (9, "IX"),
        (5, "V"),
        (4, "IV"),
        (1, "I"),
    ];
    let mut out = String::new();
    for (amount, text) in table {
        while value >= amount {
            out.push_str(text);
            value -= amount;
        }
    }
    out
}

fn build_table(
    table: &Table,
    available: i32,
    measure: &mut dyn Measurer,
    zoom: f32,
    counters: &mut HashMap<(String, usize), i32>,
    numbering: &Numbering,
) -> (Vec<RowLayout>, i32) {
    let mut widths: Vec<i32> = table.cols.iter().map(|value| px(*value, zoom)).collect();
    if widths.is_empty() {
        widths.push(available);
    }
    let total: i32 = widths.iter().sum();
    let target = table
        .width
        .map(|value| px(value, zoom))
        .unwrap_or(total)
        .min(available)
        .max(24);
    if total > 0 && total != target {
        let scale = target as f32 / total as f32;
        for width in &mut widths {
            *width = (*width as f32 * scale).round().max(8.0) as i32;
        }
    }
    let mut rows = Vec::new();
    for row in &table.rows {
        let mut items = Vec::new();
        let mut row_height = row.height.map(|value| px(value, zoom)).unwrap_or(0);
        let mut col = 0usize;
        let mut cells: Vec<(usize, i32, i32, &TableCell, Vec<Item>, i32)> = Vec::new();
        for cell in &row.cells {
            let span = cell.span.max(1);
            let mut cell_width = 0;
            for offset in 0..span {
                cell_width += widths.get(col + offset).copied().unwrap_or(0);
            }
            let cell_width = cell_width.max(8);
            let x: i32 = widths.iter().take(col).sum();
            col += span;
            let mut content_items = Vec::new();
            let mut content_height = 0;
            if cell.v_merge != Some(false) {
                let inner = cell_width
                    - px(cell.margins.left + cell.margins.right, zoom).max(0);
                let (mut blocks, height) =
                    layout_blocks_plain(&cell.blocks, inner.max(8), measure, zoom, counters, numbering);
                content_items.append(&mut blocks);
                content_height = height;
            }
            let cell_height = content_height
                + px(cell.margins.top + cell.margins.bottom, zoom);
            row_height = row_height.max(cell_height);
            cells.push((col - span, x, cell_width, cell, content_items, cell_height));
        }
        row_height = row_height.max(1);
        for (_, x, cell_width, cell, content_items, content_height) in cells {
            let fill = cell.shade;
            let borders = if has_border(&cell.borders) {
                cell.borders
            } else {
                table.borders
            };
            push_cell_borders(
                &mut items,
                x,
                0,
                cell_width,
                row_height,
                borders,
                zoom,
            );
            if let Some(fill) = fill {
                items.push(Item::Rect {
                    x,
                    y: 0,
                    w: cell_width,
                    h: row_height,
                    fill: Some(fill),
                    border: None,
                    thickness: 0,
                });
            }
            let inner_x = x + px(cell.margins.left, zoom);
            let inner_width =
                (cell_width - px(cell.margins.left + cell.margins.right, zoom)).max(8);
            let extra = (row_height
                - px(cell.margins.top + cell.margins.bottom, zoom)
                - content_height)
                .max(0);
            let top = match cell.valign {
                VAlign::Top => px(cell.margins.top, zoom),
                VAlign::Center => px(cell.margins.top, zoom) + extra / 2,
                VAlign::Bottom => px(cell.margins.top, zoom) + extra,
            };
            for item in content_items {
                items.push(offset_item(&item, inner_x, top));
            }
            let _ = inner_width;
        }
        rows.push(RowLayout {
            items,
            height: row_height,
            header: row.header,
        });
    }
    let _ = table.cell_margins;
    (rows, widths.iter().sum())
}

fn layout_blocks_plain(
    blocks: &[Block],
    width: i32,
    measure: &mut dyn Measurer,
    zoom: f32,
    counters: &mut HashMap<(String, usize), i32>,
    numbering: &Numbering,
) -> (Vec<Item>, i32) {
    let mut items = Vec::new();
    let mut y = 0i32;
    for block in blocks {
        match block {
            Block::Paragraph(paragraph) => {
                let lines = build_lines(paragraph, width, measure, zoom, counters, numbering);
                y += px(paragraph.props.before, zoom);
                for (index, line) in lines.iter().enumerate() {
                    let height = line_height(paragraph, line, measure, zoom);
                    emit_line(
                        &mut items,
                        line,
                        paragraph.props.align,
                        index == lines.len() - 1,
                        0,
                        y,
                        height,
                        measure,
                        zoom,
                    );
                    y += height;
                }
                y += px(paragraph.props.after, zoom);
            }
            Block::Table(table) => {
                let (rows, _) = build_table(table, width, measure, zoom, counters, numbering);
                for row in rows {
                    for item in row.items {
                        items.push(offset_item(&item, 0, y));
                    }
                    y += row.height;
                }
                y += px(120, zoom);
            }
        }
    }
    (items, y)
}

fn has_border(borders: &Borders) -> bool {
    borders.top.is_some()
        || borders.bottom.is_some()
        || borders.left.is_some()
        || borders.right.is_some()
}

fn push_cell_borders(
    items: &mut Vec<Item>,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    borders: Borders,
    zoom: f32,
) {
    if let Some(border) = borders.top {
        push_border_line(items, x, y, w, true, border, zoom);
    }
    if let Some(border) = borders.bottom {
        push_border_line(items, x, y + h - 1, w, true, border, zoom);
    }
    if let Some(border) = borders.left {
        push_border_line(items, x, y, h, false, border, zoom);
    }
    if let Some(border) = borders.right {
        push_border_line(items, x + w - 1, y, h, false, border, zoom);
    }
    if let Some(border) = borders.inside_h {
        push_border_line(items, x, y + h / 2, w, true, border, zoom);
    }
    if let Some(border) = borders.inside_v {
        push_border_line(items, x + w / 2, y, h, false, border, zoom);
    }
}

fn push_border_line(
    items: &mut Vec<Item>,
    x: i32,
    y: i32,
    length: i32,
    horizontal: bool,
    border: Border,
    zoom: f32,
) {
    if border.style == BorderStyle::None {
        return;
    }
    let thickness = ((border.size as f32) / 6.0 * zoom).round().max(1.0) as i32;
    let (w, h) = if horizontal {
        (length.max(1), thickness)
    } else {
        (thickness, length.max(1))
    };
    items.push(Item::Rect {
        x,
        y,
        w,
        h,
        fill: Some(border.color),
        border: None,
        thickness: 0,
    });
    if border.style == BorderStyle::Double && horizontal {
        items.push(Item::Rect {
            x,
            y: y + thickness + 1,
            w,
            h: thickness,
            fill: Some(border.color),
            border: None,
            thickness: 0,
        });
    }
}

// ---------------------------------------------------------------- 字体

fn run_font(props: &super::model::RunProps, text: &str, zoom: f32) -> Font {
    let cjk = text.chars().any(is_wide);
    let family = if cjk {
        props.east_asia_font.clone()
    } else {
        props.ascii_font.clone()
    };
    let mut size = props.size * 4.0 / 3.0 * zoom;
    if props.vert != super::model::VertAlign::Baseline {
        size *= 0.65;
    }
    if props.small_caps {
        size *= 0.8;
    }
    Font {
        family,
        size: size.round().max(4.0) as i32,
        bold: props.bold,
        italic: props.italic,
    }
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

/// 为页眉页脚/TUI 预览生成纯文本行。
pub fn plain_preview(model: &DocModel) -> Vec<String> {
    let mut out = Vec::new();
    for block in &model.blocks {
        match block {
            Block::Paragraph(paragraph) => {
                let mut text = String::new();
                for run in &paragraph.runs {
                    if run.image.is_some() {
                        text.push_str("[图片]");
                    } else {
                        text.push_str(&run.text);
                    }
                }
                out.push(text);
            }
            Block::Table(table) => {
                for row in &table.rows {
                    let mut line = String::new();
                    for cell in &row.cells {
                        if !line.is_empty() {
                            line.push('\t');
                        }
                        let mut cell_text = String::new();
                        for block in &cell.blocks {
                            if let Block::Paragraph(paragraph) = block {
                                for run in &paragraph.runs {
                                    cell_text.push_str(&run.text);
                                }
                            }
                        }
                        line.push_str(cell_text.trim());
                    }
                    out.push(line);
                }
            }
        }
    }
    out
}

fn _unused(_: Numbering, _: NumberFormat, _: Margins) {}

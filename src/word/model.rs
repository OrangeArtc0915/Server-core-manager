//! WordprocessingML 富文本模型。
//!
//! 只读取渲染需要的结构，未识别的元素一律忽略；保存仍由 `docx.rs` 基于原始
//! XML 做最小改动，因此这里的解析不会破坏文档中的其他部件。

use std::collections::HashMap;

use crate::render::Color;
use crate::xml::{Element, Node};

/// 去掉命名空间前缀，`w:p` → `p`。
pub fn local(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

pub fn child<'a>(element: &'a Element, name: &str) -> Option<&'a Element> {
    element.elements().find(|item| local(&item.name) == name)
}

pub fn children<'a>(
    element: &'a Element,
    name: &'a str,
) -> impl Iterator<Item = &'a Element> + 'a {
    element
        .elements()
        .filter(move |item| local(&item.name) == name)
}

pub fn attr<'a>(element: &'a Element, name: &str) -> Option<&'a str> {
    element.attr(name).or_else(|| {
        element
            .attrs
            .iter()
            .find(|(key, _)| local(key) == name)
            .map(|(_, value)| value.as_str())
    })
}

fn attr_i32(element: &Element, name: &str) -> Option<i32> {
    attr(element, name).and_then(|value| value.trim().parse::<i32>().ok())
}

fn attr_f32(element: &Element, name: &str) -> Option<f32> {
    attr(element, name).and_then(|value| value.trim().parse::<f32>().ok())
}

/// OOXML 的开关属性：元素存在且没有 `val` 时为真。
fn on_off(element: &Element) -> bool {
    match attr(element, "val") {
        None => true,
        Some(value) => !matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "off" | "none"
        ),
    }
}

fn flag(element: Option<&Element>) -> Option<bool> {
    element.map(|item| on_off(item))
}

fn color_value(element: &Element) -> Option<Color> {
    if let Some(value) = attr(element, "val") {
        let value = value.trim();
        if value.eq_ignore_ascii_case("auto") {
            return Some(Color::rgb(0, 0, 0));
        }
        if let Some(color) = Color::parse_hex(value) {
            return Some(color);
        }
    }
    None
}

fn twips(value: i32) -> i32 {
    value
}

// ---------------------------------------------------------------- 主题颜色

#[derive(Clone, Debug, Default)]
pub struct ThemeColors {
    map: HashMap<String, Color>,
}

impl ThemeColors {
    pub fn parse(root: &Element) -> ThemeColors {
        let mut map = HashMap::new();
        let Some(scheme) = root.find("clrScheme") else {
            return ThemeColors { map };
        };
        for slot in scheme.elements() {
            let name = local(&slot.name).to_string();
            if let Some(color) = slot.elements().next().and_then(|item| {
                if local(&item.name) == "srgbClr" {
                    attr(item, "val").and_then(Color::parse_hex)
                } else if local(&item.name) == "sysClr" {
                    attr(item, "lastClr").and_then(Color::parse_hex)
                } else {
                    None
                }
            }) {
                map.insert(name, color);
            }
        }
        ThemeColors { map }
    }

    fn get(&self, name: &str) -> Option<Color> {
        self.map.get(name).copied()
    }
}

fn themed_color(element: &Element, theme: &ThemeColors) -> Option<Color> {
    let mut color = color_value(element)?;
    if let Some(name) = attr(element, "themeColor") {
        if let Some(base) = theme.get(name) {
            color = base;
        }
    }
    // 近似处理 tint / shade：tint 向白色混合，shade 向黑色混合。
    if let Some(tint) = attr(element, "themeTint").and_then(|v| u8::from_str_radix(v, 16).ok()) {
        color = color.blend(Color::rgb(255, 255, 255), tint);
    }
    if let Some(shade) = attr(element, "themeShade").and_then(|v| u8::from_str_radix(v, 16).ok()) {
        color = color.blend(Color::rgb(0, 0, 0), shade);
    }
    Some(color)
}

// ---------------------------------------------------------------- 字体与段落属性

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VertAlign {
    Baseline,
    Superscript,
    Subscript,
}

impl Default for VertAlign {
    fn default() -> Self {
        VertAlign::Baseline
    }
}

#[derive(Clone, Debug, Default)]
pub struct RunPatch {
    pub bold: Option<bool>,
    pub italic: Option<bool>,
    pub underline: Option<bool>,
    pub strike: Option<bool>,
    pub double_strike: Option<bool>,
    pub color: Option<Color>,
    pub highlight: Option<Color>,
    pub size: Option<f32>,
    pub ascii_font: Option<String>,
    pub east_asia_font: Option<String>,
    pub vert: Option<VertAlign>,
    pub all_caps: Option<bool>,
    pub small_caps: Option<bool>,
    pub hidden: Option<bool>,
    pub spacing: Option<f32>,
}

impl RunPatch {
    fn merge(&mut self, other: &RunPatch) {
        macro_rules! take {
            ($($field:ident),* $(,)?) => {
                $(if other.$field.is_some() { self.$field = other.$field.clone(); })*
            };
        }
        take!(
            bold, italic, underline, strike, double_strike, color, highlight, size,
            ascii_font, east_asia_font, vert, all_caps, small_caps, hidden, spacing
        );
    }

    pub fn resolve(&self) -> RunProps {
        RunProps {
            bold: self.bold.unwrap_or(false),
            italic: self.italic.unwrap_or(false),
            underline: self.underline.unwrap_or(false),
            strike: self.strike.unwrap_or(false) || self.double_strike.unwrap_or(false),
            color: self.color.unwrap_or(Color::rgb(0, 0, 0)),
            highlight: self.highlight,
            size: self.size.unwrap_or(11.0),
            ascii_font: self
                .ascii_font
                .clone()
                .unwrap_or_else(|| "Calibri".to_string()),
            east_asia_font: self
                .east_asia_font
                .clone()
                .unwrap_or_else(|| "宋体".to_string()),
            vert: self.vert.clone().unwrap_or_default(),
            all_caps: self.all_caps.unwrap_or(false),
            small_caps: self.small_caps.unwrap_or(false),
            hidden: self.hidden.unwrap_or(false),
            spacing: self.spacing.unwrap_or(0.0),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RunProps {
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strike: bool,
    pub color: Color,
    pub highlight: Option<Color>,
    /// 磅值。
    pub size: f32,
    pub ascii_font: String,
    pub east_asia_font: String,
    pub vert: VertAlign,
    pub all_caps: bool,
    pub small_caps: bool,
    pub hidden: bool,
    /// 字间距（磅）。
    pub spacing: f32,
}

impl Default for RunProps {
    fn default() -> Self {
        RunPatch::default().resolve()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Align {
    Left,
    Center,
    Right,
    Justify,
    Distribute,
}

impl Default for Align {
    fn default() -> Self {
        Align::Left
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LineSpacing {
    /// 240 = 单倍行距。
    Auto(i32),
    Exact(i32),
    AtLeast(i32),
}

impl Default for LineSpacing {
    fn default() -> Self {
        LineSpacing::Auto(240)
    }
}

#[derive(Clone, Debug)]
pub struct ParaProps {
    pub align: Align,
    pub left: i32,
    pub right: i32,
    /// 首行缩进，可为负（悬挂缩进）。
    pub first_line: i32,
    pub before: i32,
    pub after: i32,
    pub line: LineSpacing,
    pub page_break_before: bool,
    pub keep_next: bool,
    pub keep_lines: bool,
    pub outline_level: Option<u8>,
    pub shade: Option<Color>,
    pub tabs: Vec<i32>,
    pub borders: Borders,
}

impl Default for ParaProps {
    fn default() -> Self {
        ParaProps {
            align: Align::Left,
            left: 0,
            right: 0,
            first_line: 0,
            before: 0,
            after: 0,
            line: LineSpacing::default(),
            page_break_before: false,
            keep_next: false,
            keep_lines: false,
            outline_level: None,
            shade: None,
            tabs: Vec::new(),
            borders: Borders::default(),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct ParaPatch {
    pub align: Option<Align>,
    pub left: Option<i32>,
    pub right: Option<i32>,
    pub first_line: Option<i32>,
    pub before: Option<i32>,
    pub after: Option<i32>,
    pub line: Option<LineSpacing>,
    pub page_break_before: Option<bool>,
    pub keep_next: Option<bool>,
    pub keep_lines: Option<bool>,
    pub outline_level: Option<u8>,
    pub shade: Option<Color>,
    pub tabs: Option<Vec<i32>>,
    pub borders: Option<Borders>,
}

impl ParaPatch {
    fn merge(&mut self, other: &ParaPatch) {
        if other.align.is_some() {
            self.align = other.align;
        }
        if other.left.is_some() {
            self.left = other.left;
        }
        if other.right.is_some() {
            self.right = other.right;
        }
        if other.first_line.is_some() {
            self.first_line = other.first_line;
        }
        if other.before.is_some() {
            self.before = other.before;
        }
        if other.after.is_some() {
            self.after = other.after;
        }
        if other.line.is_some() {
            self.line = other.line.clone();
        }
        if other.page_break_before.is_some() {
            self.page_break_before = other.page_break_before;
        }
        if other.keep_next.is_some() {
            self.keep_next = other.keep_next;
        }
        if other.keep_lines.is_some() {
            self.keep_lines = other.keep_lines;
        }
        if other.outline_level.is_some() {
            self.outline_level = other.outline_level;
        }
        if other.shade.is_some() {
            self.shade = other.shade;
        }
        if other.tabs.is_some() {
            self.tabs = other.tabs.clone();
        }
        if other.borders.is_some() {
            self.borders = other.borders.clone();
        }
    }

    fn resolve(&self) -> ParaProps {
        ParaProps {
            align: self.align.unwrap_or_default(),
            left: self.left.unwrap_or(0),
            right: self.right.unwrap_or(0),
            first_line: self.first_line.unwrap_or(0),
            before: self.before.unwrap_or(0),
            after: self.after.unwrap_or(0),
            line: self.line.clone().unwrap_or_default(),
            page_break_before: self.page_break_before.unwrap_or(false),
            keep_next: self.keep_next.unwrap_or(false),
            keep_lines: self.keep_lines.unwrap_or(false),
            outline_level: self.outline_level,
            shade: self.shade,
            tabs: self.tabs.clone().unwrap_or_default(),
            borders: self.borders.clone().unwrap_or_default(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Borders {
    pub top: Option<Border>,
    pub bottom: Option<Border>,
    pub left: Option<Border>,
    pub right: Option<Border>,
    pub inside_h: Option<Border>,
    pub inside_v: Option<Border>,
}

#[derive(Clone, Copy, Debug)]
pub struct Border {
    pub color: Color,
    /// 磅的八分之一。
    pub size: i32,
    pub style: BorderStyle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BorderStyle {
    None,
    Single,
    Double,
    Dashed,
    Dotted,
}

fn parse_border(element: &Element, theme: &ThemeColors) -> Option<Border> {
    let style = match attr(element, "val").unwrap_or("single") {
        "none" | "nil" => return None,
        "double" => BorderStyle::Double,
        "dashed" | "dashSmallGap" => BorderStyle::Dashed,
        "dotted" => BorderStyle::Dotted,
        _ => BorderStyle::Single,
    };
    Some(Border {
        color: color_value(element)
            .or_else(|| themed_color(element, theme))
            .unwrap_or(Color::rgb(0, 0, 0)),
        size: attr_i32(element, "sz").unwrap_or(4).max(2),
        style,
    })
}

fn parse_borders(element: &Element, theme: &ThemeColors) -> Borders {
    let mut borders = Borders::default();
    for item in element.elements() {
        let border = parse_border(item, theme);
        match local(&item.name) {
            "top" => borders.top = border,
            "bottom" => borders.bottom = border,
            "left" | "start" => borders.left = border,
            "right" | "end" => borders.right = border,
            "insideH" => borders.inside_h = border,
            "insideV" => borders.inside_v = border,
            _ => {}
        }
    }
    borders
}

// ---------------------------------------------------------------- 样式表

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StyleKind {
    Paragraph,
    Character,
    Table,
    Numbering,
}

#[derive(Clone, Debug)]
pub struct StyleDef {
    pub id: String,
    pub name: String,
    pub based_on: Option<String>,
    pub kind: StyleKind,
    pub para: ParaPatch,
    pub run: RunPatch,
}

#[derive(Clone, Debug, Default)]
pub struct StyleSheet {
    pub styles: HashMap<String, StyleDef>,
    pub default_paragraph: Option<String>,
    pub default_character: Option<String>,
    pub doc_para: ParaPatch,
    pub doc_run: RunPatch,
    pub theme: ThemeColors,
}

impl StyleSheet {
    pub fn parse(root: &Element, theme: ThemeColors) -> StyleSheet {
        let mut sheet = StyleSheet {
            theme,
            ..StyleSheet::default()
        };
        if let Some(defaults) = root.find("docDefaults") {
            if let Some(props) = default_para_props(defaults) {
                sheet.doc_para = props;
            }
            if let Some(props) = defaults.find("rPrDefault").and_then(|item| child(item, "rPr")) {
                sheet.doc_run = parse_run_patch(props, &sheet.theme).0;
            }
        }
        for element in children(root, "style") {
            let id = attr(element, "styleId").unwrap_or("").to_string();
            if id.is_empty() {
                continue;
            }
            let kind = match attr(element, "type").unwrap_or("paragraph") {
                "character" => StyleKind::Character,
                "table" => StyleKind::Table,
                "numbering" => StyleKind::Numbering,
                _ => StyleKind::Paragraph,
            };
            let mut style = StyleDef {
                id: id.clone(),
                name: attr(element, "name").or_else(|| child(element, "name").and_then(|n| attr(n, "val"))).unwrap_or("").to_string(),
                based_on: child(element, "basedOn").and_then(|item| attr(item, "val")).map(|s| s.to_string()),
                kind,
                para: ParaPatch::default(),
                run: RunPatch::default(),
            };
            if let Some(props) = child(element, "pPr") {
                style.para = parse_para_patch(props, &sheet.theme);
            }
            if let Some(props) = child(element, "rPr") {
                style.run = parse_run_patch(props, &sheet.theme).0;
            }
            if attr(element, "default").map(|v| v == "1" || v.eq_ignore_ascii_case("true")).unwrap_or(false) {
                match kind {
                    StyleKind::Paragraph => sheet.default_paragraph = Some(id.clone()),
                    StyleKind::Character => sheet.default_character = Some(id.clone()),
                    _ => {}
                }
            }
            sheet.styles.insert(id, style);
        }
        sheet
    }

    fn chain(&self, id: &str, kind: StyleKind) -> Vec<&StyleDef> {
        let mut out = Vec::new();
        let mut current = Some(id.to_string());
        let mut guard = 0;
        while let Some(id) = current {
            guard += 1;
            if guard > 32 {
                break;
            }
            let Some(style) = self.styles.get(&id) else {
                break;
            };
            if style.kind != kind && style.kind != StyleKind::Table {
                // 段落样式可以引用字符样式之外的类型，宽松处理。
            }
            out.push(style);
            current = style.based_on.clone();
        }
        out
    }

    pub fn paragraph_style_name(&self, id: Option<&str>) -> String {
        let id = id
            .map(|value| value.to_string())
            .or_else(|| self.default_paragraph.clone())
            .unwrap_or_default();
        self.styles
            .get(&id)
            .map(|style| style.name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| id)
    }

    /// 解析段落最终属性与段落样式的字符属性。
    pub fn resolve_paragraph(
        &self,
        style_id: Option<&str>,
        direct: &Element,
    ) -> (ParaProps, RunPatch) {
        let mut para = self.doc_para.clone();
        let mut run = self.doc_run.clone();
        let id = style_id
            .map(|value| value.to_string())
            .or_else(|| self.default_paragraph.clone());
        if let Some(id) = id {
            let chain = self.chain(&id, StyleKind::Paragraph);
            for style in chain.iter().rev() {
                para.merge(&style.para);
                run.merge(&style.run);
            }
        }
        if let Some(props) = direct.first_child("pPr") {
            para.merge(&parse_para_patch(props, &self.theme));
        }
        if let Some(props) = direct.first_child("rPr") {
            run.merge(&parse_run_patch(props, &self.theme).0);
        }
        (para.resolve(), run)
    }

    pub fn resolve_run(
        &self,
        base: &RunPatch,
        char_style: Option<&str>,
        props: Option<&Element>,
    ) -> RunProps {
        let mut patch = base.clone();
        if let Some(id) = char_style {
            let chain = self.chain(id, StyleKind::Character);
            for style in chain.iter().rev() {
                patch.merge(&style.run);
            }
        }
        if let Some(props) = props {
            patch.merge(&parse_run_patch(props, &self.theme).0);
        }
        patch.resolve()
    }
}

fn default_para_props(defaults: &Element) -> Option<ParaPatch> {
    let props = defaults.find("pPrDefault").and_then(|item| child(item, "pPr"))?;
    Some(parse_para_patch(props, &ThemeColors::default()))
}

fn parse_para_patch(props: &Element, theme: &ThemeColors) -> ParaPatch {
    let mut patch = ParaPatch::default();
    for item in props.elements() {
        match local(&item.name) {
            "jc" => {
                patch.align = Some(match attr(item, "val").unwrap_or("left") {
                    "center" => Align::Center,
                    "right" | "end" => Align::Right,
                    "both" => Align::Justify,
                    "distribute" => Align::Distribute,
                    _ => Align::Left,
                });
            }
            "ind" => {
                if let Some(value) = attr_i32(item, "left").or_else(|| attr_i32(item, "start")) {
                    patch.left = Some(twips(value));
                }
                if let Some(value) = attr_i32(item, "right").or_else(|| attr_i32(item, "end")) {
                    patch.right = Some(twips(value));
                }
                if let Some(value) = attr_i32(item, "firstLine") {
                    patch.first_line = Some(value);
                }
                if let Some(value) = attr_i32(item, "hanging") {
                    patch.first_line = Some(-value);
                }
            }
            "spacing" => {
                if let Some(value) = attr_i32(item, "before") {
                    patch.before = Some(value);
                }
                if let Some(value) = attr_i32(item, "after") {
                    patch.after = Some(value);
                }
                if let Some(value) = attr_i32(item, "line") {
                    patch.line = Some(match attr(item, "lineRule").unwrap_or("auto") {
                        "exact" => LineSpacing::Exact(value),
                        "atLeast" => LineSpacing::AtLeast(value),
                        _ => LineSpacing::Auto(value),
                    });
                }
            }
            "pageBreakBefore" => patch.page_break_before = Some(on_off(item)),
            "keepNext" => patch.keep_next = Some(on_off(item)),
            "keepLines" => patch.keep_lines = Some(on_off(item)),
            "outlineLvl" => {
                patch.outline_level = attr_i32(item, "val").map(|v| v.clamp(0, 8) as u8)
            }
            "shd" => {
                if let Some(color) = color_value(item) {
                    if color != Color::rgb(255, 255, 255) {
                        patch.shade = Some(color);
                    }
                }
            }
            "pBdr" => patch.borders = Some(parse_borders(item, theme)),
            "tabs" => {
                let mut stops = Vec::new();
                for tab in children(item, "tab") {
                    if let Some(pos) = attr_i32(tab, "pos") {
                        if attr(tab, "val").map(|v| v == "clear").unwrap_or(false) {
                            continue;
                        }
                        stops.push(pos);
                    }
                }
                stops.sort_unstable();
                patch.tabs = Some(stops);
            }
            _ => {}
        }
    }
    patch
}

fn parse_run_patch(props: &Element, theme: &ThemeColors) -> (RunPatch, Option<String>) {
    let mut patch = RunPatch::default();
    let mut char_style = None;
    for item in props.elements() {
        match local(&item.name) {
            "rStyle" => char_style = attr(item, "val").map(|s| s.to_string()),
            "b" => patch.bold = Some(on_off(item)),
            "i" => patch.italic = Some(on_off(item)),
            "u" => {
                patch.underline = Some(
                    attr(item, "val")
                        .map(|value| value != "none")
                        .unwrap_or(true),
                )
            }
            "strike" => patch.strike = Some(on_off(item)),
            "dstrike" => patch.double_strike = Some(on_off(item)),
            "color" => {
                patch.color = themed_color(item, theme).or_else(|| color_value(item));
            }
            "highlight" => {
                patch.highlight = attr(item, "val").and_then(highlight_color);
            }
            "shd" => {
                if let Some(color) = color_value(item) {
                    if color != Color::rgb(255, 255, 255) {
                        patch.highlight = Some(color);
                    }
                }
            }
            "sz" => {
                patch.size = attr_i32(item, "val").map(|value| value as f32 / 2.0)
            }
            "szCs" => {
                if patch.size.is_none() {
                    patch.size = attr_i32(item, "val").map(|value| value as f32 / 2.0);
                }
            }
            "rFonts" => {
                if let Some(value) = attr(item, "ascii").or_else(|| attr(item, "hAnsi")) {
                    patch.ascii_font = Some(value.to_string());
                }
                if let Some(value) = attr(item, "eastAsia") {
                    patch.east_asia_font = Some(value.to_string());
                }
            }
            "vertAlign" => {
                patch.vert = Some(match attr(item, "val").unwrap_or("baseline") {
                    "superscript" => VertAlign::Superscript,
                    "subscript" => VertAlign::Subscript,
                    _ => VertAlign::Baseline,
                })
            }
            "caps" => patch.all_caps = Some(on_off(item)),
            "smallCaps" => patch.small_caps = Some(on_off(item)),
            "vanish" => patch.hidden = Some(on_off(item)),
            "spacing" => {
                patch.spacing = attr_f32(item, "val").map(|value| value / 20.0)
            }
            _ => {}
        }
    }
    (patch, char_style)
}

fn highlight_color(name: &str) -> Option<Color> {
    Some(match name {
        "yellow" => Color::rgb(255, 255, 0),
        "green" => Color::rgb(0, 255, 0),
        "cyan" => Color::rgb(0, 255, 255),
        "magenta" => Color::rgb(255, 0, 255),
        "blue" => Color::rgb(0, 0, 255),
        "red" => Color::rgb(255, 0, 0),
        "darkBlue" => Color::rgb(0, 0, 139),
        "darkCyan" => Color::rgb(0, 139, 139),
        "darkGreen" => Color::rgb(0, 100, 0),
        "darkMagenta" => Color::rgb(139, 0, 139),
        "darkRed" => Color::rgb(139, 0, 0),
        "darkYellow" => Color::rgb(128, 128, 0),
        "darkGray" => Color::rgb(169, 169, 169),
        "lightGray" => Color::rgb(211, 211, 211),
        "black" => Color::rgb(0, 0, 0),
        "white" => Color::rgb(255, 255, 255),
        _ => return None,
    })
}

// ---------------------------------------------------------------- 编号

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NumberFormat {
    Decimal,
    LowerLetter,
    UpperLetter,
    LowerRoman,
    UpperRoman,
    Bullet,
    None,
}

#[derive(Clone, Debug)]
pub struct NumberLevel {
    pub start: i32,
    pub format: NumberFormat,
    pub text: String,
    pub suff: String,
    pub indent: i32,
    pub hanging: i32,
}

#[derive(Clone, Debug)]
pub struct NumberDef {
    pub num_id: String,
    pub abstract_id: String,
    pub levels: Vec<NumberLevel>,
}

#[derive(Clone, Debug, Default)]
pub struct Numbering {
    pub nums: HashMap<String, NumberDef>,
}

impl Numbering {
    pub fn parse(root: Option<&Element>) -> Numbering {
        let mut numbering = Numbering::default();
        let Some(root) = root else {
            return numbering;
        };
        let mut abstracts: HashMap<String, Vec<NumberLevel>> = HashMap::new();
        for abstract_num in children(root, "abstractNum") {
            let id = attr(abstract_num, "abstractNumId").unwrap_or("").to_string();
            let mut levels = vec![default_level(); 9];
            for level in children(abstract_num, "lvl") {
                let index = attr_i32(level, "ilvl").unwrap_or(0).clamp(0, 8) as usize;
                levels[index] = parse_level(level);
            }
            abstracts.insert(id, levels);
        }
        for num in children(root, "num") {
            let id = attr(num, "numId").unwrap_or("").to_string();
            let abstract_id = child(num, "abstractNumId")
                .and_then(|item| attr(item, "val"))
                .unwrap_or("")
                .to_string();
            let mut levels = abstracts.get(&abstract_id).cloned().unwrap_or_else(|| {
                (0..9).map(|_| default_level()).collect()
            });
            // 支持 lvlOverride 的起始编号覆盖。
            for level in children(num, "lvlOverride") {
                let index = attr_i32(level, "ilvl").unwrap_or(0).clamp(0, 8) as usize;
                if let Some(start) = child(level, "startOverride").and_then(|item| attr_i32(item, "val")) {
                    levels[index].start = start;
                }
            }
            numbering.nums.insert(
                id.clone(),
                NumberDef {
                    num_id: id,
                    abstract_id,
                    levels,
                },
            );
        }
        numbering
    }
}

fn default_level() -> NumberLevel {
    NumberLevel {
        start: 1,
        format: NumberFormat::Decimal,
        text: "%1.".into(),
        suff: "tab".into(),
        indent: 720,
        hanging: 360,
    }
}

fn parse_level(level: &Element) -> NumberLevel {
    let mut out = default_level();
    out.start = attr_i32(level, "start").unwrap_or(1);
    out.format = match child(level, "numFmt").and_then(|item| attr(item, "val")).unwrap_or("decimal") {
        "lowerLetter" => NumberFormat::LowerLetter,
        "upperLetter" => NumberFormat::UpperLetter,
        "lowerRoman" => NumberFormat::LowerRoman,
        "upperRoman" => NumberFormat::UpperRoman,
        "bullet" => NumberFormat::Bullet,
        "none" => NumberFormat::None,
        _ => NumberFormat::Decimal,
    };
    if let Some(text) = child(level, "lvlText").and_then(|item| attr(item, "val")) {
        out.text = text.to_string();
    }
    if let Some(suff) = child(level, "suff").and_then(|item| attr(item, "val")) {
        out.suff = suff.to_string();
    }
    if let Some(props) = child(level, "pPr").and_then(|item| child(item, "ind")) {
        out.indent = attr_i32(props, "left")
            .or_else(|| attr_i32(props, "start"))
            .unwrap_or(720);
        out.hanging = attr_i32(props, "hanging")
            .map(|value| value)
            .or_else(|| attr_i32(props, "firstLine").map(|value| -value))
            .unwrap_or(360);
    }
    out
}

// ---------------------------------------------------------------- 文档模型

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NumberRef {
    pub num_id: String,
    pub level: usize,
}

#[derive(Clone, Debug)]
pub struct InlineImage {
    /// 已解压到临时目录的图片路径。
    pub path: std::path::PathBuf,
    /// 显示尺寸（像素，96 DPI）。
    pub width: f32,
    pub height: f32,
    /// 浮动图片相对文字锚点的偏移（像素）。
    pub offset: Option<(f32, f32)>,
    pub name: String,
}

#[derive(Clone, Debug)]
pub struct Run {
    pub text: String,
    pub props: RunProps,
    pub link: bool,
    pub image: Option<InlineImage>,
}

impl Run {
    pub fn text(text: &str, props: RunProps) -> Run {
        Run {
            text: text.to_string(),
            props,
            link: false,
            image: None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Paragraph {
    pub props: ParaProps,
    pub style_name: String,
    pub runs: Vec<Run>,
    pub number: Option<NumberRef>,
    pub comment_ids: Vec<String>,
    pub section_break: Option<SectionInfo>,
}

#[derive(Clone, Debug)]
pub enum Block {
    Paragraph(Paragraph),
    Table(Table),
}

#[derive(Clone, Debug)]
pub struct Table {
    pub cols: Vec<i32>,
    pub rows: Vec<TableRow>,
    pub align: Align,
    pub width: Option<i32>,
    pub borders: Borders,
    pub cell_margins: Margins,
}

#[derive(Clone, Debug)]
pub struct TableRow {
    pub cells: Vec<TableCell>,
    pub height: Option<i32>,
    pub header: bool,
}

#[derive(Clone, Debug)]
pub struct TableCell {
    pub blocks: Vec<Block>,
    pub span: usize,
    /// `None` 普通单元格，`Some(true)` 纵向合并起点，`Some(false)` 被合并。
    pub v_merge: Option<bool>,
    pub width: Option<i32>,
    pub shade: Option<Color>,
    pub valign: VAlign,
    pub borders: Borders,
    pub margins: Margins,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VAlign {
    Top,
    Center,
    Bottom,
}

impl Default for VAlign {
    fn default() -> Self {
        VAlign::Top
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Margins {
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
    pub left: i32,
}

impl Margins {
    pub fn uniform(value: i32) -> Margins {
        Margins {
            top: value,
            right: value,
            bottom: value,
            left: value,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SectionBreak {
    NextPage,
    Continuous,
    EvenPage,
    OddPage,
}

#[derive(Clone, Debug)]
pub struct SectionInfo {
    pub page_w: i32,
    pub page_h: i32,
    pub margins: Margins,
    pub header_dist: i32,
    pub footer_dist: i32,
    pub header_default: Option<String>,
    pub header_first: Option<String>,
    pub header_even: Option<String>,
    pub footer_default: Option<String>,
    pub footer_first: Option<String>,
    pub footer_even: Option<String>,
    pub title_page: bool,
    pub break_type: SectionBreak,
    pub columns: usize,
}

impl Default for SectionInfo {
    fn default() -> Self {
        SectionInfo {
            page_w: 11906,
            page_h: 16838,
            margins: Margins {
                top: 1440,
                right: 1800,
                bottom: 1440,
                left: 1800,
            },
            header_dist: 851,
            footer_dist: 992,
            header_default: None,
            header_first: None,
            header_even: None,
            footer_default: None,
            footer_first: None,
            footer_even: None,
            title_page: false,
            break_type: SectionBreak::NextPage,
            columns: 1,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Section {
    pub start: usize,
    pub end: usize,
    pub info: SectionInfo,
}

#[derive(Clone, Debug)]
pub struct CommentInfo {
    pub id: String,
    pub author: String,
    pub date: String,
    pub text: String,
}

#[derive(Clone, Debug, Default)]
pub struct DocModel {
    pub blocks: Vec<Block>,
    pub sections: Vec<Section>,
    pub headers: HashMap<String, Vec<Block>>,
    pub footers: HashMap<String, Vec<Block>>,
    pub comments: Vec<CommentInfo>,
    pub numbering: Numbering,
    pub page_w: i32,
    pub page_h: i32,
}

impl DocModel {
    pub fn section_at(&self, block: usize) -> Option<&Section> {
        self.sections
            .iter()
            .find(|section| block >= section.start && block < section.end)
            .or_else(|| self.sections.last())
    }

    pub fn comment_index(&self, id: &str) -> Option<usize> {
        self.comments.iter().position(|comment| comment.id == id)
    }

    /// 供 TUI 大纲/文本视图使用的纯文本。
    pub fn plain_text(&self) -> Vec<String> {
        let mut out = Vec::new();
        for block in &self.blocks {
            match block {
                Block::Paragraph(paragraph) => {
                    let mut text = String::new();
                    for run in &paragraph.runs {
                        text.push_str(&run.text);
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
}

// ---------------------------------------------------------------- 解析入口

pub struct ParseContext<'a> {
    pub sheet: &'a StyleSheet,
    pub numbering: &'a Numbering,
    pub rels: &'a HashMap<String, String>,
    pub media_dir: &'a std::path::Path,
    pub media: &'a HashMap<String, std::path::PathBuf>,
    pub comments: &'a [CommentInfo],
}

pub fn parse_document(
    root: &Element,
    sheet: &StyleSheet,
    numbering: &Numbering,
    rels: &HashMap<String, String>,
    media_dir: &std::path::Path,
    media: &HashMap<String, std::path::PathBuf>,
    comments: &[CommentInfo],
) -> DocModel {
    let context = ParseContext {
        sheet,
        numbering,
        rels,
        media_dir,
        media,
        comments,
    };
    let mut model = DocModel {
        comments: comments.to_vec(),
        numbering: numbering.clone(),
        page_w: SectionInfo::default().page_w,
        page_h: SectionInfo::default().page_h,
        ..DocModel::default()
    };
    let Some(body) = child(root, "body") else {
        return model;
    };
    let mut blocks = Vec::new();
    let mut sections: Vec<Section> = Vec::new();
    let mut section_start = 0usize;
    let mut current_info = SectionInfo::default();
    let mut pending_comments: Vec<String> = Vec::new();

    for node in &body.children {
        let Node::Element(element) = node else {
            continue;
        };
        match local(&element.name) {
            "p" => {
                let paragraph = parse_paragraph(element, &context, &mut pending_comments);
                if let Some(info) = &paragraph.section_break {
                    sections.push(Section {
                        start: section_start,
                        end: blocks.len() + 1,
                        info: info.clone(),
                    });
                    section_start = blocks.len() + 1;
                    current_info = info.clone();
                }
                blocks.push(Block::Paragraph(paragraph));
            }
            "tbl" => {
                let table = parse_table(element, &context);
                blocks.push(Block::Table(table));
            }
            "sectPr" => {
                let info = parse_section(element, &context);
                current_info = info;
            }
            "commentRangeStart" => {
                if let Some(id) = attr(element, "id") {
                    pending_comments.push(id.to_string());
                }
            }
            "commentRangeEnd" => {
                if let Some(id) = attr(element, "id") {
                    pending_comments.retain(|item| item != id);
                }
            }
            _ => {}
        }
    }

    // 正文最后的 sectPr 属于最后一个分节。
    if sections.last().map(|section| section.end).unwrap_or(0) <= blocks.len() {
        let end = blocks.len();
        if section_start <= end {
            sections.push(Section {
                start: section_start,
                end,
                info: current_info.clone(),
            });
        }
    }
    if sections.is_empty() {
        sections.push(Section {
            start: 0,
            end: blocks.len(),
            info: current_info.clone(),
        });
    }
    model.page_w = current_info.page_w;
    model.page_h = current_info.page_h;
    model.sections = sections;
    model.blocks = blocks;

    // 页眉页脚：只解析被分节引用到的部件。
    let mut wanted: Vec<String> = Vec::new();
    for section in &model.sections {
        for part in [
            &section.info.header_default,
            &section.info.header_first,
            &section.info.header_even,
            &section.info.footer_default,
            &section.info.footer_first,
            &section.info.footer_even,
        ]
        .into_iter()
        .flatten()
        {
            if !wanted.contains(part) {
                wanted.push(part.clone());
            }
        }
    }
    for part in wanted {
        // 这里由 docx.rs 填充：它持有 zip，能读取页眉页脚 XML。
        let _ = part;
    }
    model
}

pub fn parse_header_footer(
    root: &Element,
    sheet: &StyleSheet,
    numbering: &Numbering,
    rels: &HashMap<String, String>,
    media_dir: &std::path::Path,
    media: &HashMap<String, std::path::PathBuf>,
) -> Vec<Block> {
    let context = ParseContext {
        sheet,
        numbering,
        rels,
        media_dir,
        media,
        comments: &[],
    };
    let mut blocks = Vec::new();
    let mut pending = Vec::new();
    for node in &root.children {
        let Node::Element(element) = node else {
            continue;
        };
        match local(&element.name) {
            "p" => {
                let paragraph = parse_paragraph(element, &context, &mut pending);
                blocks.push(Block::Paragraph(paragraph));
            }
            "tbl" => blocks.push(Block::Table(parse_table(element, &context))),
            _ => {}
        }
    }
    blocks
}

pub fn parse_comments(root: &Element) -> Vec<CommentInfo> {
    let mut out = Vec::new();
    for comment in children(root, "comment") {
        let mut text = String::new();
        collect_comment_text(comment, &mut text);
        out.push(CommentInfo {
            id: attr(comment, "id").unwrap_or("").to_string(),
            author: attr(comment, "author").unwrap_or("").to_string(),
            date: attr(comment, "date").unwrap_or("").to_string(),
            text: text.trim().to_string(),
        });
    }
    out
}

fn collect_comment_text(element: &Element, out: &mut String) {
    for node in &element.children {
        match node {
            Node::Text(text) => out.push_str(text),
            Node::Element(item) => {
                if local(&item.name) == "t" {
                    out.push_str(&item.text());
                } else {
                    collect_comment_text(item, out);
                }
            }
        }
    }
}

fn parse_section(sect: &Element, context: &ParseContext) -> SectionInfo {
    let mut info = SectionInfo::default();
    if let Some(size) = child(sect, "pgSz") {
        if let Some(width) = attr_i32(size, "w") {
            info.page_w = width;
        }
        if let Some(height) = attr_i32(size, "h") {
            info.page_h = height;
        }
        if attr(size, "orient").map(|v| v == "landscape").unwrap_or(false) && info.page_w < info.page_h {
            std::mem::swap(&mut info.page_w, &mut info.page_h);
        }
    }
    if let Some(margins) = child(sect, "pgMar") {
        info.margins.top = attr_i32(margins, "top").unwrap_or(1440);
        info.margins.bottom = attr_i32(margins, "bottom").unwrap_or(1440);
        info.margins.left = attr_i32(margins, "left").unwrap_or(1800);
        info.margins.right = attr_i32(margins, "right").unwrap_or(1800);
        info.header_dist = attr_i32(margins, "header").unwrap_or(851);
        info.footer_dist = attr_i32(margins, "footer").unwrap_or(992);
    }
    info.title_page = child(sect, "titlePg").map(on_off).unwrap_or(false);
    if let Some(border) = child(sect, "type") {
        info.break_type = match attr(border, "val").unwrap_or("nextPage") {
            "continuous" => SectionBreak::Continuous,
            "evenPage" => SectionBreak::EvenPage,
            "oddPage" => SectionBreak::OddPage,
            _ => SectionBreak::NextPage,
        };
    }
    if let Some(cols) = child(sect, "cols") {
        info.columns = attr_i32(cols, "num").unwrap_or(1).clamp(1, 4) as usize;
    }
    for reference in children(sect, "headerReference") {
        let target = attr(reference, "id")
            .and_then(|id| context.rels.get(id))
            .cloned();
        match attr(reference, "type").unwrap_or("default") {
            "first" => info.header_first = target,
            "even" => info.header_even = target,
            _ => info.header_default = target,
        }
    }
    for reference in children(sect, "footerReference") {
        let target = attr(reference, "id")
            .and_then(|id| context.rels.get(id))
            .cloned();
        match attr(reference, "type").unwrap_or("default") {
            "first" => info.footer_first = target,
            "even" => info.footer_even = target,
            _ => info.footer_default = target,
        }
    }
    info
}

fn parse_paragraph(
    element: &Element,
    context: &ParseContext,
    pending_comments: &mut Vec<String>,
) -> Paragraph {
    let props = child(element, "pPr");
    let style_id = props
        .and_then(|item| child(item, "pStyle"))
        .and_then(|item| attr(item, "val"));
    let (mut para_props, run_base) = context.sheet.resolve_paragraph(style_id, element);
    let mut number = None;
    let mut section_break = None;
    if let Some(props) = props {
        if let Some(num) = child(props, "numPr") {
            let level = child(num, "ilvl")
                .and_then(|item| attr_i32(item, "val"))
                .unwrap_or(0)
                .clamp(0, 8) as usize;
            if let Some(num_id) = child(num, "numId").and_then(|item| attr(item, "val")) {
                number = Some(NumberRef {
                    num_id: num_id.to_string(),
                    level,
                });
            }
        }
        if let Some(sect) = child(props, "sectPr") {
            section_break = Some(parse_section(sect, context));
        }
    }
    // 编号级别自带缩进时覆盖段落缩进。
    if let Some(number_ref) = &number {
        if let Some(def) = context.numbering.nums.get(&number_ref.num_id) {
            if let Some(level) = def.levels.get(number_ref.level) {
                if para_props.left == 0 {
                    para_props.left = level.indent;
                }
                if para_props.first_line == 0 {
                    para_props.first_line = -level.hanging;
                }
            }
        }
    }
    let style_name = context.sheet.paragraph_style_name(style_id);
    let mut runs = Vec::new();
    let mut field = FieldState::None;
    let mut comment_ids = pending_comments.clone();
    parse_inline(
        element,
        context,
        &run_base,
        &mut runs,
        &mut field,
        &mut comment_ids,
        false,
        None,
    );
    Paragraph {
        props: para_props,
        style_name,
        runs,
        number,
        comment_ids,
        section_break,
    }
}

#[derive(Clone)]
enum FieldState {
    None,
    Instr(String),
    Result { page: bool, total: bool },
}

#[allow(clippy::too_many_arguments)]
fn parse_inline(
    element: &Element,
    context: &ParseContext,
    run_base: &RunPatch,
    runs: &mut Vec<Run>,
    field: &mut FieldState,
    comment_ids: &mut Vec<String>,
    link: bool,
    char_style: Option<&str>,
) {
    for node in &element.children {
        let Node::Element(item) = node else {
            continue;
        };
        match local(&item.name) {
            "r" => {
                if let Some(props) = child(item, "rPr") {
                    if let Some(style) = child(props, "rStyle").and_then(|s| attr(s, "val")) {
                        parse_inline_run(
                            item,
                            context,
                            run_base,
                            runs,
                            field,
                            comment_ids,
                            link,
                            Some(style),
                        );
                        continue;
                    }
                }
                parse_inline_run(
                    item, context, run_base, runs, field, comment_ids, link, char_style,
                );
            }
            "hyperlink" => {
                let mut inner = Vec::new();
                let mut inner_comments = Vec::new();
                parse_inline(
                    item,
                    context,
                    run_base,
                    &mut inner,
                    field,
                    &mut inner_comments,
                    true,
                    char_style,
                );
                for run in &mut inner {
                    run.link = true;
                    if run.props.color == Color::rgb(0, 0, 0) {
                        run.props.color = Color::rgb(5, 99, 193);
                    }
                    run.props.underline = true;
                }
                runs.append(&mut inner);
                comment_ids.append(&mut inner_comments);
            }
            "fldSimple" => {
                let instr = attr(item, "instr").unwrap_or("").trim().to_ascii_uppercase();
                let page = instr == "PAGE" || instr.starts_with("PAGE ");
                let total = instr == "NUMPAGES" || instr.starts_with("NUMPAGES ");
                let mut inner = Vec::new();
                let mut inner_comments = Vec::new();
                let mut inner_field = FieldState::None;
                parse_inline(
                    item,
                    context,
                    run_base,
                    &mut inner,
                    &mut inner_field,
                    &mut inner_comments,
                    link,
                    char_style,
                );
                if page || total {
                    let props = inner
                        .first()
                        .map(|run| run.props.clone())
                        .unwrap_or_else(|| run_base.resolve());
                    inner.clear();
                    inner.push(Run::text(if page { "\u{1}" } else { "\u{2}" }, props));
                }
                runs.append(&mut inner);
                comment_ids.append(&mut inner_comments);
            }
            "commentRangeStart" => {
                if let Some(id) = attr(item, "id") {
                    if !comment_ids.iter().any(|value| value == id) {
                        comment_ids.push(id.to_string());
                    }
                }
            }
            "commentRangeEnd" | "commentReference" => {}
            "sdt" => {
                if let Some(content) = child(item, "sdtContent") {
                    parse_inline(
                        content,
                        context,
                        run_base,
                        runs,
                        field,
                        comment_ids,
                        link,
                        char_style,
                    );
                }
            }
            "ins" => {
                parse_inline(
                    item,
                    context,
                    run_base,
                    runs,
                    field,
                    comment_ids,
                    link,
                    char_style,
                );
            }
            "del" | "moveFrom" => {}
            _ => {}
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn parse_inline_run(
    run_element: &Element,
    context: &ParseContext,
    run_base: &RunPatch,
    runs: &mut Vec<Run>,
    field: &mut FieldState,
    comment_ids: &mut Vec<String>,
    link: bool,
    char_style: Option<&str>,
) {
    let props = child(run_element, "rPr");
    let style = props
        .and_then(|item| child(item, "rStyle"))
        .and_then(|item| attr(item, "val"))
        .or(char_style);
    let resolved = context.sheet.resolve_run(run_base, style, props);
    if resolved.hidden {
        return;
    }
    for node in &run_element.children {
        let Node::Element(item) = node else {
            continue;
        };
        match local(&item.name) {
            "t" | "delText" => {
                let text = item.text();
                if !text.is_empty() {
                    push_text_run(runs, field, &text, &resolved, link);
                }
            }
            "tab" => push_text_run(runs, field, "\t", &resolved, link),
            "br" => {
                let kind = attr(item, "type").unwrap_or("textWrapping");
                if kind == "page" {
                    push_text_run(runs, field, "\u{0c}", &resolved, link);
                } else {
                    push_text_run(runs, field, "\n", &resolved, link);
                }
            }
            "cr" => push_text_run(runs, field, "\n", &resolved, link),
            "fldChar" => match attr(item, "fldCharType").unwrap_or("") {
                "begin" => *field = FieldState::Instr(String::new()),
                "separate" => {
                    if let FieldState::Instr(instr) = field {
                        let upper = instr.trim().to_ascii_uppercase();
                        let page = upper == "PAGE" || upper.starts_with("PAGE ");
                        let total = upper == "NUMPAGES" || upper.starts_with("NUMPAGES ");
                        *field = FieldState::Result { page, total };
                        if page || total {
                            runs.push(Run::text(if page { "\u{1}" } else { "\u{2}" }, resolved.clone()));
                        }
                    }
                }
                "end" => {
                    if let FieldState::Result { page, total } = field {
                        if *page || *total {
                            // 结果文字已在 separate 时用占位符替代。
                        }
                    }
                    *field = FieldState::None;
                }
                _ => {}
            },
            "instrText" => {
                if let FieldState::Instr(instr) = field {
                    instr.push_str(&item.text());
                }
            }
            "drawing" | "pict" => {
                if let Some(image) = parse_image(item, context) {
                    let _ = comment_ids;
                    runs.push(Run {
                        text: String::new(),
                        props: resolved.clone(),
                        link,
                        image: Some(image),
                    });
                }
            }
            "commentReference" => {
                if let Some(id) = attr(item, "id") {
                    if let Some(index) = context
                        .comments
                        .iter()
                        .position(|comment| comment.id == id)
                    {
                        let mut marker = resolved.clone();
                        marker.color = Color::rgb(230, 120, 0);
                        marker.size = (marker.size * 0.75).max(6.0);
                        runs.push(Run::text(&format!("[{}]", index + 1), marker));
                    }
                }
            }
            "sdt" | "ins" => {
                parse_inline(
                    item,
                    context,
                    run_base,
                    runs,
                    field,
                    comment_ids,
                    link,
                    style,
                );
            }
            _ => {}
        }
    }
}

fn push_text_run(
    runs: &mut Vec<Run>,
    field: &FieldState,
    text: &str,
    props: &RunProps,
    link: bool,
) {
    if let FieldState::Result { page, total } = field {
        if *page || *total {
            // 字段结果使用动态占位符，忽略缓存文本。
            return;
        }
    }
    // 合并同一格式的相邻片段，减少绘制调用。
    if let Some(last) = runs.last_mut() {
        if last.image.is_none() && last.props == *props && last.link == link {
            last.text.push_str(text);
            return;
        }
    }
    runs.push(Run {
        text: text.to_string(),
        props: props.clone(),
        link,
        image: None,
    });
}

fn parse_image(element: &Element, context: &ParseContext) -> Option<InlineImage> {
    let (blip, width, height, offset, name) = if let Some(drawing) = find_descendant(element, "drawing") {
        let inline = child(drawing, "inline").or_else(|| child(drawing, "anchor"));
        let inline = inline?;
        let extent = child(inline, "extent")?;
        let cx = attr_f32(extent, "cx")?;
        let cy = attr_f32(extent, "cy")?;
        let blip = find_descendant(inline, "blip")?;
        let id = attr(blip, "embed").or_else(|| attr(blip, "link"))?;
        let mut offset = None;
        if local(&inline.name) == "anchor" {
            let mut dx = 0.0;
            let mut dy = 0.0;
            if let Some(position) = child(inline, "positionH") {
                if let Some(value) = find_descendant(position, "posOffset").and_then(|item| item.text().trim().parse::<f32>().ok()) {
                    dx = value;
                }
            }
            if let Some(position) = child(inline, "positionV") {
                if let Some(value) = find_descendant(position, "posOffset").and_then(|item| item.text().trim().parse::<f32>().ok()) {
                    dy = value;
                }
            }
            if dx != 0.0 || dy != 0.0 {
                offset = Some((dx / 9525.0, dy / 9525.0));
            }
        }
        let name = find_descendant(inline, "docPr")
            .and_then(|item| attr(item, "name").or_else(|| attr(item, "descr")))
            .unwrap_or("")
            .to_string();
        (id.to_string(), cx / 9525.0, cy / 9525.0, offset, name)
    } else {
        // VML 兜底：<v:shape style="width:...pt;height:...pt"><v:imagedata r:id="..."/>
        let shape = find_descendant(element, "shape")?;
        let data = find_descendant(shape, "imagedata")?;
        let id = attr(data, "id")?;
        let style = attr(shape, "style").unwrap_or("");
        let width = style_value(style, "width")? * 96.0 / 72.0;
        let height = style_value(style, "height")? * 96.0 / 72.0;
        (id.to_string(), width, height, None, String::new())
    };
    let target = context.rels.get(&blip)?;
    let path = context
        .media
        .get(target)
        .cloned()
        .or_else(|| context.media.get(&normalize_part(target)).cloned())?;
    Some(InlineImage {
        path,
        width: width.max(1.0),
        height: height.max(1.0),
        offset,
        name,
    })
}

fn style_value(style: &str, key: &str) -> Option<f32> {
    for part in style.split(';') {
        let mut pair = part.splitn(2, ':');
        let name = pair.next()?.trim();
        if name.eq_ignore_ascii_case(key) {
            let value = pair.next()?.trim().trim_end_matches("pt").trim_end_matches("px");
            return value.parse::<f32>().ok();
        }
    }
    None
}

fn normalize_part(target: &str) -> String {
    let target = target.trim_start_matches('/');
    if target.starts_with("word/") {
        target.to_string()
    } else {
        format!("word/{target}")
    }
}

pub fn find_descendant<'a>(element: &'a Element, name: &str) -> Option<&'a Element> {
    if local(&element.name) == name {
        return Some(element);
    }
    for child in element.elements() {
        if let Some(found) = find_descendant(child, name) {
            return Some(found);
        }
    }
    None
}

fn parse_table(element: &Element, context: &ParseContext) -> Table {
    let props = child(element, "tblPr");
    let mut align = Align::Left;
    let mut width = None;
    let mut borders = Borders::default();
    let mut cell_margins = Margins::uniform(108);
    if let Some(props) = props {
        if let Some(jc) = child(props, "jc") {
            align = match attr(jc, "val").unwrap_or("left") {
                "center" => Align::Center,
                "right" | "end" => Align::Right,
                _ => Align::Left,
            };
        }
        if let Some(size) = child(props, "tblW") {
            if attr(size, "type").map(|v| v == "dxa").unwrap_or(true) {
                width = attr_i32(size, "w");
            }
        }
        if let Some(border) = child(props, "tblBorders") {
            borders = parse_borders(border, &context.sheet.theme);
        }
        if let Some(margins) = child(props, "tblCellMar") {
            for item in margins.elements() {
                let value = attr_i32(item, "w").unwrap_or(108);
                match local(&item.name) {
                    "top" => cell_margins.top = value,
                    "bottom" => cell_margins.bottom = value,
                    "left" | "start" => cell_margins.left = value,
                    "right" | "end" => cell_margins.right = value,
                    _ => {}
                }
            }
        }
    }
    let mut cols = Vec::new();
    if let Some(grid) = child(element, "tblGrid") {
        for col in children(grid, "gridCol") {
            cols.push(attr_i32(col, "w").unwrap_or(1200));
        }
    }
    let mut rows = Vec::new();
    for row in children(element, "tr") {
        let row_props = child(row, "trPr");
        let mut height = None;
        let mut header = false;
        if let Some(props) = row_props {
            if let Some(value) = child(props, "trHeight") {
                if attr(value, "hRule").map(|rule| rule != "auto").unwrap_or(true) {
                    height = attr_i32(value, "val");
                }
            }
            header = child(props, "tblHeader").map(on_off).unwrap_or(false);
        }
        let mut cells = Vec::new();
        for cell in children(row, "tc") {
            let cell_props = child(cell, "tcPr");
            let mut span = 1usize;
            let mut v_merge = None;
            let mut shade = None;
            let mut valign = VAlign::Top;
            let mut cell_width = None;
            let mut cell_borders = Borders::default();
            let mut margins = cell_margins;
            if let Some(props) = cell_props {
                if let Some(value) = child(props, "gridSpan").and_then(|item| attr_i32(item, "val")) {
                    span = value.clamp(1, 63) as usize;
                }
                if let Some(value) = child(props, "vMerge") {
                    v_merge = Some(attr(value, "val").unwrap_or("continue") != "continue");
                }
                if let Some(value) = child(props, "shd").and_then(color_value) {
                    shade = Some(value);
                }
                if let Some(value) = child(props, "vAlign").and_then(|item| attr(item, "val")) {
                    valign = match value {
                        "center" => VAlign::Center,
                        "bottom" => VAlign::Bottom,
                        _ => VAlign::Top,
                    };
                }
                if let Some(value) = child(props, "tcW") {
                    if attr(value, "type").map(|v| v == "dxa").unwrap_or(true) {
                        cell_width = attr_i32(value, "w");
                    }
                }
                if let Some(border) = child(props, "tcBorders") {
                    cell_borders = parse_borders(border, &context.sheet.theme);
                }
                if let Some(values) = child(props, "tcMar") {
                    for item in values.elements() {
                        let value = attr_i32(item, "w").unwrap_or(margins.top);
                        match local(&item.name) {
                            "top" => margins.top = value,
                            "bottom" => margins.bottom = value,
                            "left" | "start" => margins.left = value,
                            "right" | "end" => margins.right = value,
                            _ => {}
                        }
                    }
                }
            }
            let mut blocks = Vec::new();
            let mut pending = Vec::new();
            for node in &cell.children {
                let Node::Element(item) = node else {
                    continue;
                };
                match local(&item.name) {
                    "p" => blocks.push(Block::Paragraph(parse_paragraph(item, context, &mut pending))),
                    "tbl" => blocks.push(Block::Table(parse_table(item, context))),
                    _ => {}
                }
            }
            cells.push(TableCell {
                blocks,
                span,
                v_merge,
                width: cell_width,
                shade,
                valign,
                borders: cell_borders,
                margins,
            });
        }
        rows.push(TableRow {
            cells,
            height,
            header,
        });
    }
    if cols.is_empty() {
        let count = rows.iter().map(|row| row.cells.len()).max().unwrap_or(1);
        cols = vec![1200; count.max(1)];
    }
    Table {
        cols,
        rows,
        align,
        width,
        borders,
        cell_margins,
    }
}

// ---------------------------------------------------------------- 样式覆盖（编辑用）

/// 把编辑器里的纯文本段落与粗斜体标记写回文档后，用该函数重建模型。
pub fn paragraph_plain_text(paragraph: &Paragraph) -> String {
    let mut text = String::new();
    for run in &paragraph.runs {
        text.push_str(&run.text);
    }
    text
}

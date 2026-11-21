//! Excel 样式表与数字格式。
//!
//! 样式只追加、不重写已有条目，因此不会破坏条件格式引用的 dxfs、图表等部件。

use std::collections::BTreeMap;

use crate::render::Color;
use crate::xml::{Element, Node};

#[derive(Clone, Debug, PartialEq)]
pub struct FontDef {
    pub name: String,
    pub size: f32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strike: bool,
    pub color: Option<Color>,
}

impl Default for FontDef {
    fn default() -> Self {
        FontDef {
            name: "Calibri".into(),
            size: 11.0,
            bold: false,
            italic: false,
            underline: false,
            strike: false,
            color: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FillDef {
    pub pattern: String,
    pub fg: Color,
    pub bg: Color,
}

impl Default for FillDef {
    fn default() -> Self {
        FillDef {
            pattern: "none".into(),
            fg: Color::rgb(255, 255, 255),
            bg: Color::rgb(255, 255, 255),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct BorderSide {
    pub style: String,
    pub color: Color,
}

impl Default for BorderSide {
    fn default() -> Self {
        BorderSide {
            style: "none".into(),
            color: Color::rgb(0, 0, 0),
        }
    }
}

impl BorderSide {
    pub fn visible(&self) -> bool {
        self.style != "none" && !self.style.is_empty()
    }
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct BorderDef {
    pub left: BorderSide,
    pub right: BorderSide,
    pub top: BorderSide,
    pub bottom: BorderSide,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Xf {
    pub num_fmt: u32,
    pub font: u32,
    pub fill: u32,
    pub border: u32,
    pub h_align: String,
    pub v_align: String,
    pub wrap: bool,
    pub indent: u8,
}

impl Default for Xf {
    fn default() -> Self {
        Xf {
            num_fmt: 0,
            font: 0,
            fill: 0,
            border: 0,
            h_align: String::new(),
            v_align: String::new(),
            wrap: false,
            indent: 0,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct ResolvedStyle {
    pub font: FontDef,
    pub fill: Color,
    pub text_color: Color,
    pub num_format: String,
    pub h_align: String,
    pub v_align: String,
    pub wrap: bool,
    pub border: BorderDef,
    pub xf: usize,
}

#[derive(Clone, Debug)]
pub enum FormatAction {
    Bold,
    Italic,
    Underline,
    FontSize(f32),
    FontName(String),
    FontColor(Color),
    Fill(Color),
    ClearFill,
    NumberFormat(String),
    HAlign(String),
    VAlign(String),
    Wrap(bool),
    BorderAll,
    ClearBorder,
}

#[derive(Clone, Debug)]
pub struct Styles {
    pub num_formats: BTreeMap<u32, String>,
    pub fonts: Vec<FontDef>,
    pub fills: Vec<FillDef>,
    pub borders: Vec<BorderDef>,
    pub xfs: Vec<Xf>,
    root: Element,
}

impl Default for Styles {
    fn default() -> Self {
        Styles::new()
    }
}

impl Styles {
    pub fn new() -> Styles {
        let mut styles = Styles {
            num_formats: BTreeMap::new(),
            fonts: vec![FontDef::default()],
            fills: vec![FillDef::default(), FillDef {
                pattern: "gray125".into(),
                ..FillDef::default()
            }],
            borders: vec![BorderDef::default()],
            xfs: vec![Xf::default()],
            root: Element::new("styleSheet"),
        };
        styles.rebuild_root();
        styles
    }

    pub fn parse(root: &Element) -> Styles {
        let mut styles = Styles {
            num_formats: BTreeMap::new(),
            fonts: Vec::new(),
            fills: Vec::new(),
            borders: Vec::new(),
            xfs: Vec::new(),
            root: root.clone(),
        };
        if let Some(formats) = root.first_child("numFmts") {
            for format in formats.elements() {
                if format.name != "numFmt" {
                    continue;
                }
                if let (Some(id), Some(code)) = (
                    format.attr("numFmtId").and_then(|v| v.parse::<u32>().ok()),
                    format.attr("formatCode"),
                ) {
                    styles.num_formats.insert(id, code.to_string());
                }
            }
        }
        if let Some(fonts) = root.first_child("fonts") {
            for font in fonts.elements() {
                if font.name == "font" {
                    styles.fonts.push(parse_font(font));
                }
            }
        }
        if let Some(fills) = root.first_child("fills") {
            for fill in fills.elements() {
                if fill.name == "fill" {
                    styles.fills.push(parse_fill(fill));
                }
            }
        }
        if let Some(borders) = root.first_child("borders") {
            for border in borders.elements() {
                if border.name == "border" {
                    styles.borders.push(parse_border(border));
                }
            }
        }
        if let Some(xfs) = root.first_child("cellXfs") {
            for xf in xfs.elements() {
                if xf.name == "xf" {
                    styles.xfs.push(parse_xf(xf));
                }
            }
        }
        if styles.fonts.is_empty() {
            styles.fonts.push(FontDef::default());
        }
        if styles.fills.len() < 2 {
            styles.fills = vec![FillDef::default(), FillDef {
                pattern: "gray125".into(),
                ..FillDef::default()
            }];
        }
        if styles.borders.is_empty() {
            styles.borders.push(BorderDef::default());
        }
        if styles.xfs.is_empty() {
            styles.xfs.push(Xf::default());
        }
        styles
    }

    fn rebuild_root(&mut self) {
        self.root = Element::new("styleSheet");
        let mut fonts = Element::new("fonts");
        fonts.set_attr("count", &self.fonts.len().to_string());
        for font in &self.fonts {
            fonts.push(font_element(font));
        }
        self.root.push(fonts);
        let mut fills = Element::new("fills");
        fills.set_attr("count", &self.fills.len().to_string());
        for fill in &self.fills {
            fills.push(fill_element(fill));
        }
        self.root.push(fills);
        let mut borders = Element::new("borders");
        borders.set_attr("count", &self.borders.len().to_string());
        for border in &self.borders {
            borders.push(border_element(border));
        }
        self.root.push(borders);
        let mut xfs = Element::new("cellXfs");
        xfs.set_attr("count", &self.xfs.len().to_string());
        for xf in &self.xfs {
            xfs.push(xf_element(xf));
        }
        self.root.push(xfs);
    }

    pub fn serialize(&self) -> String {
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n{}",
            crate::xml::serialize(&self.root)
        )
    }

    pub fn resolve(&self, index: u32) -> ResolvedStyle {
        let xf_index = index as usize;
        let xf = self.xfs.get(xf_index).cloned().unwrap_or_default();
        let font = self.fonts.get(xf.font as usize).cloned().unwrap_or_default();
        let fill = self
            .fills
            .get(xf.fill as usize)
            .filter(|fill| fill.pattern == "solid")
            .map(|fill| fill.fg)
            .unwrap_or_else(|| Color::rgb(255, 255, 255));
        let text_color = font.color.unwrap_or(Color::rgb(0, 0, 0));
        ResolvedStyle {
            font,
            fill,
            text_color,
            num_format: self.num_format_string(xf.num_fmt),
            h_align: xf.h_align.clone(),
            v_align: xf.v_align.clone(),
            wrap: xf.wrap,
            border: self
                .borders
                .get(xf.border as usize)
                .cloned()
                .unwrap_or_default(),
            xf: xf_index,
        }
    }

    pub fn num_format_string(&self, id: u32) -> String {
        if let Some(format) = self.num_formats.get(&id) {
            return format.clone();
        }
        builtin_format(id).unwrap_or("General").to_string()
    }

    fn num_format_id(&mut self, format: &str) -> u32 {
        if let Some(id) = builtin_id(format) {
            return id;
        }
        for (id, code) in &self.num_formats {
            if code == format {
                return *id;
            }
        }
        let id = self.num_formats.keys().next_back().copied().unwrap_or(163).max(163) + 1;
        self.num_formats.insert(id, format.to_string());
        self.ensure_num_format_element(id, format);
        id
    }

    fn ensure_num_format_element(&mut self, id: u32, format: &str) {
        let container = if let Some(index) = self
            .root
            .children
            .iter()
            .position(|node| matches!(node, Node::Element(e) if e.name == "numFmts"))
        {
            match &mut self.root.children[index] {
                Node::Element(element) => element,
                _ => return,
            }
        } else {
            let mut element = Element::new("numFmts");
            element.set_attr("count", "0");
            self.root.children.insert(0, Node::Element(element));
            match &mut self.root.children[0] {
                Node::Element(element) => element,
                _ => return,
            }
        };
        let mut element = Element::new("numFmt");
        element.set_attr("numFmtId", &id.to_string());
        element.set_attr("formatCode", format);
        container.push(element);
        let count = container.elements().filter(|e| e.name == "numFmt").count();
        container.set_attr("count", &count.to_string());
    }

    fn ensure_container(&mut self, name: &str) -> &mut Element {
        let position = self.root.children.iter().position(
            |node| matches!(node, Node::Element(e) if e.name == name),
        );
        let index = match position {
            Some(index) => index,
            None => {
                let mut element = Element::new(name);
                element.set_attr("count", "0");
                self.root.push(element);
                self.root.children.len() - 1
            }
        };
        match &mut self.root.children[index] {
            Node::Element(element) => element,
            _ => unreachable!(),
        }
    }

    pub fn apply(&mut self, base: u32, action: &FormatAction) -> u32 {
        let mut xf = self.xfs.get(base as usize).cloned().unwrap_or_default();
        match action {
            FormatAction::Bold => {
                let mut font = self.fonts.get(xf.font as usize).cloned().unwrap_or_default();
                font.bold = !font.bold;
                xf.font = self.use_font(font);
            }
            FormatAction::Italic => {
                let mut font = self.fonts.get(xf.font as usize).cloned().unwrap_or_default();
                font.italic = !font.italic;
                xf.font = self.use_font(font);
            }
            FormatAction::Underline => {
                let mut font = self.fonts.get(xf.font as usize).cloned().unwrap_or_default();
                font.underline = !font.underline;
                xf.font = self.use_font(font);
            }
            FormatAction::FontSize(size) => {
                let mut font = self.fonts.get(xf.font as usize).cloned().unwrap_or_default();
                font.size = *size;
                xf.font = self.use_font(font);
            }
            FormatAction::FontName(name) => {
                let mut font = self.fonts.get(xf.font as usize).cloned().unwrap_or_default();
                font.name = name.clone();
                xf.font = self.use_font(font);
            }
            FormatAction::FontColor(color) => {
                let mut font = self.fonts.get(xf.font as usize).cloned().unwrap_or_default();
                font.color = Some(*color);
                xf.font = self.use_font(font);
            }
            FormatAction::Fill(color) => {
                xf.fill = self.use_fill(FillDef {
                    pattern: "solid".into(),
                    fg: *color,
                    bg: *color,
                });
            }
            FormatAction::ClearFill => xf.fill = 0,
            FormatAction::NumberFormat(format) => {
                xf.num_fmt = self.num_format_id(format);
            }
            FormatAction::HAlign(align) => xf.h_align = align.clone(),
            FormatAction::VAlign(align) => xf.v_align = align.clone(),
            FormatAction::Wrap(wrap) => xf.wrap = *wrap,
            FormatAction::BorderAll => {
                let side = BorderSide {
                    style: "thin".into(),
                    color: Color::rgb(0, 0, 0),
                };
                xf.border = self.use_border(BorderDef {
                    left: side.clone(),
                    right: side.clone(),
                    top: side.clone(),
                    bottom: side,
                });
            }
            FormatAction::ClearBorder => xf.border = 0,
        }
        if let Some(index) = self.xfs.iter().position(|item| *item == xf) {
            return index as u32;
        }
        self.xfs.push(xf.clone());
        let count = self.xfs.len();
        let container = self.ensure_container("cellXfs");
        container.push(xf_element(&xf));
        container.set_attr("count", &count.to_string());
        (count - 1) as u32
    }

    fn use_font(&mut self, font: FontDef) -> u32 {
        if let Some(index) = self.fonts.iter().position(|item| *item == font) {
            return index as u32;
        }
        self.fonts.push(font.clone());
        let count = self.fonts.len();
        let container = self.ensure_container("fonts");
        container.push(font_element(&font));
        container.set_attr("count", &count.to_string());
        (count - 1) as u32
    }

    fn use_fill(&mut self, fill: FillDef) -> u32 {
        if let Some(index) = self.fills.iter().position(|item| *item == fill) {
            return index as u32;
        }
        self.fills.push(fill.clone());
        let count = self.fills.len();
        let container = self.ensure_container("fills");
        container.push(fill_element(&fill));
        container.set_attr("count", &count.to_string());
        (count - 1) as u32
    }

    fn use_border(&mut self, border: BorderDef) -> u32 {
        if let Some(index) = self.borders.iter().position(|item| *item == border) {
            return index as u32;
        }
        self.borders.push(border.clone());
        let count = self.borders.len();
        let container = self.ensure_container("borders");
        container.push(border_element(&border));
        container.set_attr("count", &count.to_string());
        (count - 1) as u32
    }
}

fn parse_font(element: &Element) -> FontDef {
    let mut font = FontDef::default();
    for child in element.elements() {
        match child.name.as_str() {
            "b" => font.bold = on_off(child),
            "i" => font.italic = on_off(child),
            "u" => font.underline = child.attr("val").map(|v| v != "none").unwrap_or(true),
            "strike" => font.strike = on_off(child),
            "sz" => {
                if let Some(size) = child.attr("val").and_then(|v| v.parse::<f32>().ok()) {
                    font.size = size;
                }
            }
            "color" => font.color = child.attr("rgb").and_then(Color::parse_hex),
            "name" => {
                if let Some(name) = child.attr("val") {
                    font.name = name.to_string();
                }
            }
            _ => {}
        }
    }
    font
}

fn parse_fill(element: &Element) -> FillDef {
    let mut fill = FillDef::default();
    let Some(pattern) = element.first_child("patternFill") else {
        return fill;
    };
    fill.pattern = pattern.attr("patternType").unwrap_or("none").to_string();
    if let Some(color) = pattern.first_child("fgColor") {
        if let Some(value) = color.attr("rgb").and_then(Color::parse_hex) {
            fill.fg = value;
        }
    }
    if let Some(color) = pattern.first_child("bgColor") {
        if let Some(value) = color.attr("rgb").and_then(Color::parse_hex) {
            fill.bg = value;
        }
    }
    fill
}

fn parse_border(element: &Element) -> BorderDef {
    let mut border = BorderDef::default();
    for child in element.elements() {
        let side = match child.name.as_str() {
            "left" => &mut border.left,
            "right" => &mut border.right,
            "top" => &mut border.top,
            "bottom" => &mut border.bottom,
            _ => continue,
        };
        side.style = child.attr("style").unwrap_or("none").to_string();
        if let Some(color) = child.first_child("color") {
            if let Some(value) = color.attr("rgb").and_then(Color::parse_hex) {
                side.color = value;
            }
        }
    }
    border
}

fn parse_xf(element: &Element) -> Xf {
    let mut xf = Xf {
        num_fmt: element
            .attr("numFmtId")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0),
        font: element.attr("fontId").and_then(|v| v.parse().ok()).unwrap_or(0),
        fill: element.attr("fillId").and_then(|v| v.parse().ok()).unwrap_or(0),
        border: element
            .attr("borderId")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0),
        ..Xf::default()
    };
    if let Some(alignment) = element.first_child("alignment") {
        xf.h_align = alignment.attr("horizontal").unwrap_or("").to_string();
        xf.v_align = alignment.attr("vertical").unwrap_or("").to_string();
        xf.wrap = alignment
            .attr("wrapText")
            .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        xf.indent = alignment
            .attr("indent")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
    }
    xf
}

fn on_off(element: &Element) -> bool {
    element
        .attr("val")
        .map(|value| !matches!(value, "0" | "false" | "off"))
        .unwrap_or(true)
}

fn font_element(font: &FontDef) -> Element {
    let mut element = Element::new("font");
    if font.bold {
        element.push(Element::new("b"));
    }
    if font.italic {
        element.push(Element::new("i"));
    }
    if font.underline {
        let mut underline = Element::new("u");
        underline.set_attr("val", "single");
        element.push(underline);
    }
    if font.strike {
        element.push(Element::new("strike"));
    }
    let mut size = Element::new("sz");
    size.set_attr("val", &format!("{:.1}", font.size));
    element.push(size);
    let mut color = Element::new("color");
    color.set_attr(
        "rgb",
        &format!(
            "FF{:02X}{:02X}{:02X}",
            font.color.unwrap_or(Color::rgb(0, 0, 0)).r,
            font.color.unwrap_or(Color::rgb(0, 0, 0)).g,
            font.color.unwrap_or(Color::rgb(0, 0, 0)).b
        ),
    );
    element.push(color);
    let mut name = Element::new("name");
    name.set_attr("val", &font.name);
    element.push(name);
    let mut family = Element::new("family");
    family.set_attr("val", "2");
    element.push(family);
    element
}

fn fill_element(fill: &FillDef) -> Element {
    let mut element = Element::new("fill");
    let mut pattern = Element::new("patternFill");
    pattern.set_attr("patternType", &fill.pattern);
    if fill.pattern == "solid" {
        let mut fg = Element::new("fgColor");
        fg.set_attr(
            "rgb",
            &format!("FF{:02X}{:02X}{:02X}", fill.fg.r, fill.fg.g, fill.fg.b),
        );
        pattern.push(fg);
        let mut bg = Element::new("bgColor");
        bg.set_attr("indexed", "64");
        pattern.push(bg);
    }
    element.push(pattern);
    element
}

fn border_element(border: &BorderDef) -> Element {
    let mut element = Element::new("border");
    for (name, side) in [
        ("left", &border.left),
        ("right", &border.right),
        ("top", &border.top),
        ("bottom", &border.bottom),
    ] {
        let mut child = Element::new(name);
        if side.visible() {
            child.set_attr("style", &side.style);
            let mut color = Element::new("color");
            color.set_attr(
                "rgb",
                &format!("FF{:02X}{:02X}{:02X}", side.color.r, side.color.g, side.color.b),
            );
            child.push(color);
        }
        element.push(child);
    }
    element.push(Element::new("diagonal"));
    element
}

fn xf_element(xf: &Xf) -> Element {
    let mut element = Element::new("xf");
    element.set_attr("numFmtId", &xf.num_fmt.to_string());
    element.set_attr("fontId", &xf.font.to_string());
    element.set_attr("fillId", &xf.fill.to_string());
    element.set_attr("borderId", &xf.border.to_string());
    element.set_attr("xfId", "0");
    element.set_attr("applyNumberFormat", "1");
    element.set_attr("applyFont", "1");
    element.set_attr("applyFill", "1");
    element.set_attr("applyBorder", "1");
    if !xf.h_align.is_empty() || !xf.v_align.is_empty() || xf.wrap || xf.indent > 0 {
        let mut alignment = Element::new("alignment");
        if !xf.h_align.is_empty() {
            alignment.set_attr("horizontal", &xf.h_align);
        }
        if !xf.v_align.is_empty() {
            alignment.set_attr("vertical", &xf.v_align);
        }
        if xf.wrap {
            alignment.set_attr("wrapText", "1");
        }
        if xf.indent > 0 {
            alignment.set_attr("indent", &xf.indent.to_string());
        }
        element.set_attr("applyAlignment", "1");
        element.push(alignment);
    }
    element
}

fn builtin_format(id: u32) -> Option<&'static str> {
    Some(match id {
        0 => "General",
        1 => "0",
        2 => "0.00",
        3 => "#,##0",
        4 => "#,##0.00",
        9 => "0%",
        10 => "0.00%",
        11 => "0.00E+00",
        12 => "# ?/?",
        13 => "# ??/??",
        14 => "mm-dd-yy",
        15 => "d-mmm-yy",
        16 => "d-mmm",
        17 => "mmm-yy",
        18 => "h:mm AM/PM",
        19 => "h:mm:ss AM/PM",
        20 => "h:mm",
        21 => "h:mm:ss",
        22 => "m/d/yy h:mm",
        37 => "#,##0 ;(#,##0)",
        38 => "#,##0 ;[Red](#,##0)",
        39 => "#,##0.00;(#,##0.00)",
        40 => "#,##0.00;[Red](#,##0.00)",
        45 => "mm:ss",
        46 => "[h]:mm:ss",
        47 => "mmss.0",
        48 => "##0.0E+0",
        49 => "@",
        _ => return None,
    })
}

fn builtin_id(format: &str) -> Option<u32> {
    let format = format.trim();
    Some(match format {
        "General" => 0,
        "0" => 1,
        "0.00" => 2,
        "#,##0" => 3,
        "#,##0.00" => 4,
        "0%" => 9,
        "0.00%" => 10,
        "0.00E+00" => 11,
        "mm-dd-yy" => 14,
        "d-mmm-yy" => 15,
        "d-mmm" => 16,
        "mmm-yy" => 17,
        "h:mm AM/PM" => 18,
        "h:mm:ss AM/PM" => 19,
        "h:mm" => 20,
        "h:mm:ss" => 21,
        "m/d/yy h:mm" => 22,
        "mm:ss" => 45,
        "[h]:mm:ss" => 46,
        "mmss.0" => 47,
        "##0.0E+0" => 48,
        "@" => 49,
        _ => return None,
    })
}

/// 把数值按 Excel 数字格式显示。
pub fn format_number(value: f64, format: &str, date1904: bool) -> String {
    if format.is_empty() || format == "General" {
        return general_number(value);
    }
    let sections: Vec<&str> = format.split(';').collect();
    let section = if value > 0.0 || sections.len() == 1 {
        sections[0]
    } else if value < 0.0 {
        sections.get(1).copied().unwrap_or(sections[0])
    } else {
        sections.get(2).copied().unwrap_or(sections[0])
    };
    let section = strip_conditions(section);
    if is_date_format(&section) {
        return format_date(value, &section, date1904);
    }
    if section.contains('@') {
        return general_number(value);
    }
    if section.contains("E+") || section.contains("E-") {
        return format_scientific(value, &section);
    }
    let percent_count = section.matches('%').count();
    let mut scaled = value * 100f64.powi(percent_count as i32);
    if value < 0.0 {
        scaled = scaled.abs();
    }
    let decimals = decimals_of(&section);
    let thousands = section.contains(',') && section.find(',').unwrap_or(usize::MAX) < section.find('.').unwrap_or(usize::MAX);
    let mut text = if thousands {
        format!("{:.*}", decimals, scaled)
            .split('.')
            .enumerate()
            .map(|(index, part)| {
                if index == 0 {
                    add_thousands(part)
                } else {
                    part.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join(".")
    } else {
        format!("{:.*}", decimals, scaled)
    };
    if section.contains('%') {
        text.push('%');
    }
    // 补齐货币符号等前后缀
    let prefix: String = section
        .chars()
        .take_while(|ch| !matches!(ch, '0' | '#' | '?'))
        .filter(|ch| !matches!(ch, '[' | ']') && !ch.is_alphabetic())
        .collect();
    let suffix: String = section
        .chars()
        .rev()
        .take_while(|ch| !matches!(ch, '0' | '#' | '?'))
        .collect::<Vec<_>>()
        .iter()
        .rev()
        .filter(|ch| **ch != '[' && **ch != ']' && **ch != '%' && !ch.is_alphabetic())
        .collect();
    if value < 0.0 && sections.len() == 1 {
        text = format!("-{text}");
    }
    let mut out = String::new();
    out.push_str(&prefix);
    out.push_str(&text);
    out.push_str(&suffix);
    out
}

pub fn general_number(value: f64) -> String {
    if value.is_nan() {
        return "#NUM!".into();
    }
    if value.fract() == 0.0 && value.abs() < 1e15 {
        return format!("{}", value as i64);
    }
    let mut text = format!("{value:.10}");
    if text.contains('.') {
        while text.ends_with('0') {
            text.pop();
        }
        if text.ends_with('.') {
            text.pop();
        }
    }
    text
}

fn decimals_of(section: &str) -> usize {
    if let Some(dot) = section.find('.') {
        section[dot + 1..]
            .chars()
            .take_while(|ch| *ch == '0' || *ch == '#' || *ch == '?')
            .count()
    } else {
        0
    }
}

fn add_thousands(text: &str) -> String {
    let negative = text.starts_with('-');
    let digits = text.trim_start_matches('-');
    let mut out = String::new();
    for (index, ch) in digits.chars().rev().enumerate() {
        if index > 0 && index % 3 == 0 {
            out.insert(0, ',');
        }
        out.insert(0, ch);
    }
    if negative {
        out.insert(0, '-');
    }
    out
}

fn strip_conditions(section: &str) -> String {
    let mut out = String::new();
    let mut chars = section.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '[' {
            let mut buffer = String::new();
            for item in chars.by_ref() {
                if item == ']' {
                    break;
                }
                buffer.push(item);
            }
            if buffer.starts_with('$') {
                // 货币符号，例如 [$-409]
                continue;
            }
            if buffer.eq_ignore_ascii_case("red")
                || buffer.eq_ignore_ascii_case("blue")
                || buffer.eq_ignore_ascii_case("black")
                || buffer.eq_ignore_ascii_case("green")
                || buffer.starts_with('<')
                || buffer.starts_with('>')
                || buffer.starts_with('=')
                || buffer.starts_with("h")
            {
                if buffer.starts_with('h') {
                    out.push('[');
                    out.push_str(&buffer);
                    out.push(']');
                }
                continue;
            }
            continue;
        }
        if ch == '_' || ch == '*' {
            chars.next();
            continue;
        }
        out.push(ch);
    }
    out
}

fn is_date_format(format: &str) -> bool {
    let lower = format.to_ascii_lowercase();
    if lower.contains('e') && (lower.contains("e+") || lower.contains("e-")) {
        return false;
    }
    let has_date = lower.contains('y') || lower.contains('d');
    let has_time = (lower.contains('h') && lower.contains(':')) || lower.contains("am/pm");
    let bare_m = lower.contains('m') && !has_date && !has_time && lower.contains(':');
    has_date || has_time || bare_m
}

fn format_date(value: f64, format: &str, date1904: bool) -> String {
    let (year, month, day, hour, minute, second) = serial_to_date(value, date1904);
    let mut out = String::new();
    let mut index = 0usize;
    let chars: Vec<char> = format.chars().collect();
    let lower: Vec<char> = format.to_ascii_lowercase().chars().collect();
    let mut last_hour_token = false;
    while index < chars.len() {
        let ch = lower[index];
        match ch {
            'y' | 'd' | 'h' | 's' | 'm' => {
                let start = index;
                while index < chars.len() && lower[index] == ch {
                    index += 1;
                }
                let count = index - start;
                let next_char = lower.get(index).copied();
                match ch {
                    'y' => {
                        if count >= 4 {
                            out.push_str(&format!("{year:04}"));
                        } else {
                            out.push_str(&format!("{:02}", year % 100));
                        }
                    }
                    'd' => {
                        if count >= 4 {
                            out.push_str(weekday_name(year, month, day));
                        } else if count == 3 {
                            out.push_str(&weekday_name(year, month, day)[..3]);
                        } else if count == 2 {
                            out.push_str(&format!("{day:02}"));
                        } else {
                            out.push_str(&day.to_string());
                        }
                    }
                    'h' => {
                        let hour = if format.to_ascii_lowercase().contains("am/pm") {
                            let mut hour = hour % 12;
                            if hour == 0 {
                                hour = 12;
                            }
                            hour
                        } else {
                            hour
                        };
                        if count >= 2 {
                            out.push_str(&format!("{hour:02}"));
                        } else {
                            out.push_str(&hour.to_string());
                        }
                    }
                    's' => {
                        if count >= 2 {
                            out.push_str(&format!("{second:02}"));
                        } else {
                            out.push_str(&second.to_string());
                        }
                    }
                    'm' => {
                        // 紧邻小时或秒时是分钟，否则是月份
                        let after_hour = last_hour_token || out.ends_with(':');
                        let before_second = next_char == Some(':');
                        if after_hour || before_second {
                            if count >= 2 {
                                out.push_str(&format!("{minute:02}"));
                            } else {
                                out.push_str(&minute.to_string());
                            }
                        } else if count >= 4 {
                            out.push_str(month_name(month));
                        } else if count == 3 {
                            out.push_str(&month_name(month)[..3]);
                        } else if count == 2 {
                            out.push_str(&format!("{month:02}"));
                        } else {
                            out.push_str(&month.to_string());
                        }
                    }
                    _ => {}
                }
                last_hour_token = ch == 'h';
            }
            'a' => {
                let rest: String = lower[index..].iter().collect();
                if rest.starts_with("am/pm") {
                    let text = if hour < 12 { "AM" } else { "PM" };
                    out.push_str(text);
                    index += 5;
                } else {
                    out.push(chars[index]);
                    index += 1;
                }
            }
            '\\' => {
                index += 1;
                if let Some(ch) = chars.get(index) {
                    out.push(*ch);
                    index += 1;
                }
            }
            '"' => {
                index += 1;
                while index < chars.len() && chars[index] != '"' {
                    out.push(chars[index]);
                    index += 1;
                }
                index += 1;
            }
            _ => {
                out.push(chars[index]);
                index += 1;
            }
        }
    }
    out
}

fn format_scientific(value: f64, section: &str) -> String {
    let decimals = section
        .split('.')
        .nth(1)
        .map(|part| part.chars().take_while(|ch| *ch == '0').count())
        .unwrap_or(0);
    format!("{:.*E}", decimals, value)
}

fn weekday_name(year: i32, month: u32, day: u32) -> &'static str {
    const NAMES: [&str; 7] = [
        "Sunday",
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
    ];
    let days = days_from_civil(year, month, day);
    NAMES[((days + 4).rem_euclid(7)) as usize]
}

fn month_name(month: u32) -> &'static str {
    const NAMES: [&str; 12] = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ];
    NAMES[(month.saturating_sub(1) as usize).min(11)]
}

/// 1900 或 1904 日期系统，返回 (年, 月, 日, 时, 分, 秒)。
pub fn serial_to_date(serial: f64, date1904: bool) -> (i32, u32, u32, u32, u32, u32) {
    let mut days = serial.floor() as i64;
    let fraction = serial - serial.floor();
    let mut seconds = (fraction * 86400.0).round() as i64;
    if seconds >= 86400 {
        seconds -= 86400;
        days += 1;
    }
    let (year, month, day) = if date1904 {
        civil_from_days(days + days_from_civil(1904, 1, 1))
    } else if days == 60 {
        (1900, 2, 29)
    } else if days < 60 {
        civil_from_days(days + days_from_civil(1899, 12, 31))
    } else {
        civil_from_days(days - 1 + days_from_civil(1899, 12, 31))
    };
    (
        year,
        month as u32,
        day as u32,
        (seconds / 3600) as u32,
        ((seconds % 3600) / 60) as u32,
        (seconds % 60) as u32,
    )
}

pub fn date_to_serial(year: i32, month: u32, day: u32, date1904: bool) -> f64 {
    let days = days_from_civil(year, month, day);
    if date1904 {
        (days - days_from_civil(1904, 1, 1)) as f64
    } else if days < days_from_civil(1900, 3, 1) {
        (days - days_from_civil(1899, 12, 31)) as f64
    } else {
        (days - days_from_civil(1899, 12, 31) + 1) as f64
    }
}

fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let yoe = (year - era * 400) as i64;
    let month = month as i64;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    (era as i64) * 146097 + doe - 719468
}

fn civil_from_days(days: i64) -> (i32, i32, i32) {
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if month <= 2 { 1 } else { 0 };
    (year as i32, month as i32, day as i32)
}

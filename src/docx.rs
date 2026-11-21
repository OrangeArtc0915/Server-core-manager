//! Word（.docx）读写：按段落编辑正文，保存时保留表格、图片、页眉页脚等部件。
//!
//! 只重写发生变化的段落；未改动的段落保留原有 XML 结构。

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::archive::Zip;
use crate::word::model::{
    self, CommentInfo, DocModel, Numbering, StyleSheet, ThemeColors,
};
use crate::xml::{self, Element, Node};

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Flags {
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub color: Option<u8>,
}

pub const COLORS: [&str; 8] = [
    "000000", "C00000", "0070C0", "00B050", "FFC000", "7030A0", "FF0000", "FFFFFF",
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Style {
    Bold,
    Italic,
    Underline,
    ColorNext,
}

impl Flags {
    pub fn toggle(&mut self, style: Style) {
        match style {
            Style::Bold => self.bold = !self.bold,
            Style::Italic => self.italic = !self.italic,
            Style::Underline => self.underline = !self.underline,
            Style::ColorNext => {
                self.color = Some(match self.color {
                    Some(index) => (index + 1) % COLORS.len() as u8,
                    None => 1,
                })
            }
        }
    }
}

pub struct WordDoc {
    zip: Zip,
    root: Element,
    /// 每个段落（不含表格内段落）的原始文本与样式。
    original: Vec<(String, Flags)>,
    styles: StyleSheet,
    numbering: Numbering,
    rels: HashMap<String, String>,
    media: HashMap<String, PathBuf>,
    media_dir: PathBuf,
    comments: Vec<CommentInfo>,
    /// 高保真渲染模型。
    pub model: DocModel,
}

impl Drop for WordDoc {
    fn drop(&mut self) {
        if self.media_dir.exists() {
            let _ = std::fs::remove_dir_all(&self.media_dir);
        }
    }
}

impl WordDoc {
    pub fn open(path: &Path) -> Result<WordDoc, String> {
        let zip = Zip::read_file(path)?;
        let text = zip
            .get_text("word/document.xml")
            .ok_or_else(|| "不是有效的 Word 文档（缺少 word/document.xml）".to_string())?;
        let root = xml::parse(&text)?;
        let mut original = Vec::new();
        for paragraph in paragraph_elements(&root) {
            original.push((paragraph_text(paragraph), paragraph_flags(paragraph)));
        }
        if original.is_empty() {
            original.push((String::new(), Flags::default()));
        }
        let (styles, numbering, rels, media_dir, media, comments) = load_parts(&zip)?;
        let mut doc = WordDoc {
            zip,
            root,
            original,
            styles,
            numbering,
            rels,
            media,
            media_dir,
            comments,
            model: DocModel::default(),
        };
        doc.model = doc.build_model();
        Ok(doc)
    }

    /// 新建空白文档。
    pub fn create() -> WordDoc {
        let mut zip = Zip { entries: Vec::new() };
        zip.set(
            "[Content_Types].xml",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#,
        );
        zip.set(
            "_rels/.rels",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#,
        );
        let document = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t xml:space="preserve"></w:t></w:r></w:p><w:sectPr/></w:body></w:document>"#;
        zip.set("word/document.xml", document.as_bytes());
        let root = xml::parse(document).unwrap_or_else(|_| Element::new("w:document"));
        let media_dir = unique_media_dir();
        let _ = std::fs::create_dir_all(&media_dir);
        let mut doc = WordDoc {
            zip,
            root,
            original: vec![(String::new(), Flags::default())],
            styles: StyleSheet::default(),
            numbering: Numbering::default(),
            rels: HashMap::new(),
            media: HashMap::new(),
            media_dir,
            comments: Vec::new(),
            model: DocModel::default(),
        };
        doc.model = doc.build_model();
        doc
    }

    /// 重新解析富文本模型（保存或外部改动后调用）。
    fn build_model(&self) -> DocModel {
        let mut model = model::parse_document(
            &self.root,
            &self.styles,
            &self.numbering,
            &self.rels,
            &self.media_dir,
            &self.media,
            &self.comments,
        );
        let mut headers = Vec::new();
        let mut footers = Vec::new();
        for section in &model.sections {
            for part in [
                &section.info.header_default,
                &section.info.header_first,
                &section.info.header_even,
            ]
            .into_iter()
            .flatten()
            {
                if !headers.contains(part) {
                    headers.push(part.clone());
                }
            }
            for part in [
                &section.info.footer_default,
                &section.info.footer_first,
                &section.info.footer_even,
            ]
            .into_iter()
            .flatten()
            {
                if !footers.contains(part) {
                    footers.push(part.clone());
                }
            }
        }
        for (parts, target) in [(headers, true), (footers, false)] {
            for part in parts {
                let Some(text) = self.zip.get_text(&part) else {
                    continue;
                };
                let Ok(root) = xml::parse(&text) else {
                    continue;
                };
                let rels = part_rels(&self.zip, &part).unwrap_or_else(|| self.rels.clone());
                let blocks = model::parse_header_footer(
                    &root,
                    &self.styles,
                    &self.numbering,
                    &rels,
                    &self.media_dir,
                    &self.media,
                );
                if target {
                    model.headers.insert(part, blocks);
                } else {
                    model.footers.insert(part, blocks);
                }
            }
        }
        model
    }

    pub fn paragraph_count(&self) -> usize {
        self.original.len()
    }

    pub fn styles(&self) -> Vec<Flags> {
        self.original.iter().map(|(_, flags)| *flags).collect()
    }

    pub fn texts(&self) -> Vec<String> {
        self.original
            .iter()
            .map(|(text, _)| text.replace('\n', " "))
            .collect()
    }

    /// 保存：`lines` 与 `styles` 对应编辑器中的段落行。
    pub fn save(&mut self, path: &Path, lines: &[String], styles: &[Flags]) -> Result<(), String> {
        let indices = paragraph_indices(&self.root);

        // 先基于只读树算出所有修改，再统一变更，避免借用冲突。
        let mut changed: Vec<(usize, Element)> = Vec::new();
        for ordinal in 0..lines.len().min(indices.len()) {
            let flags = styles.get(ordinal).copied().unwrap_or_default();
            let unchanged = match self.original.get(ordinal) {
                Some((text, original_flags)) => text == &lines[ordinal] && *original_flags == flags,
                None => false,
            };
            if unchanged {
                continue;
            }
            let paragraph = build_paragraph(&self.root, indices[ordinal], &lines[ordinal], flags);
            changed.push((indices[ordinal], paragraph));
        }
        let remove: Vec<usize> = if lines.len() < indices.len() {
            let mut list: Vec<usize> = indices[lines.len()..].to_vec();
            list.sort_unstable();
            list
        } else {
            Vec::new()
        };
        let added: Vec<Element> = (indices.len()..lines.len())
            .map(|ordinal| {
                let flags = styles.get(ordinal).copied().unwrap_or_default();
                build_paragraph_simple(&lines[ordinal], flags)
            })
            .collect();

        let body = self
            .root
            .find_mut("w:body")
            .ok_or_else(|| "Word 文档缺少 w:body".to_string())?;
        for (index, paragraph) in changed {
            if index < body.children.len() {
                body.children[index] = Node::Element(paragraph);
            }
        }
        for index in remove.into_iter().rev() {
            if index < body.children.len() {
                body.children.remove(index);
            }
        }
        for paragraph in added {
            let insert_at = body
                .children
                .iter()
                .position(|node| matches!(node, Node::Element(e) if e.name == "w:sectPr"))
                .unwrap_or(body.children.len());
            body.children.insert(insert_at, Node::Element(paragraph));
        }

        // 重新序列化并写回 zip
        let mut text = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
        text.push_str(&xml::serialize(&self.root));
        self.zip.set("word/document.xml", text.as_bytes());
        self.zip.save_file(path)?;
        self.original = lines
            .iter()
            .enumerate()
            .map(|(index, line)| (line.clone(), styles.get(index).copied().unwrap_or_default()))
            .collect();
        self.model = self.build_model();
        Ok(())
    }
}

/// 读取样式、编号、关系、批注，并把媒体解压到临时目录。
fn load_parts(
    zip: &Zip,
) -> Result<
    (
        StyleSheet,
        Numbering,
        HashMap<String, String>,
        PathBuf,
        HashMap<String, PathBuf>,
        Vec<CommentInfo>,
    ),
    String,
> {
    let empty = Element::new("styles");
    let styles_root = zip
        .get_text("word/styles.xml")
        .and_then(|text| xml::parse(&text).ok())
        .unwrap_or(empty);
    let theme = zip
        .get_text("word/theme/theme1.xml")
        .and_then(|text| xml::parse(&text).ok())
        .map(|root| ThemeColors::parse(&root))
        .unwrap_or_default();
    let styles = StyleSheet::parse(&styles_root, theme);
    let numbering_root = zip
        .get_text("word/numbering.xml")
        .and_then(|text| xml::parse(&text).ok());
    let numbering = Numbering::parse(numbering_root.as_ref());
    let rels = parse_rels(zip, "word/_rels/document.xml.rels");
    let comments = zip
        .get_text("word/comments.xml")
        .and_then(|text| xml::parse(&text).ok())
        .map(|root| model::parse_comments(&root))
        .unwrap_or_default();
    let (media_dir, media) = extract_media(zip)?;
    Ok((styles, numbering, rels, media_dir, media, comments))
}

fn parse_rels(zip: &Zip, path: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let Some(text) = zip.get_text(path) else {
        return map;
    };
    let Ok(root) = xml::parse(&text) else {
        return map;
    };
    for relation in root.elements() {
        if model::local(&relation.name) != "Relationship" {
            continue;
        }
        let Some(id) = model::attr(relation, "Id") else {
            continue;
        };
        let Some(target) = model::attr(relation, "Target") else {
            continue;
        };
        map.insert(id.to_string(), normalize_target(target));
    }
    map
}

fn part_rels(zip: &Zip, part: &str) -> Option<HashMap<String, String>> {
    let file = part.rsplit('/').next()?;
    let path = format!("word/_rels/{file}.rels");
    let map = parse_rels(zip, &path);
    if map.is_empty() {
        None
    } else {
        Some(map)
    }
}

fn normalize_target(target: &str) -> String {
    let target = target.trim();
    if let Some(stripped) = target.strip_prefix('/') {
        stripped.to_string()
    } else if target.starts_with("word/") {
        target.to_string()
    } else {
        format!("word/{target}")
    }
}

fn unique_media_dir() -> PathBuf {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let index = COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "textm-word-{}-{}",
        std::process::id(),
        index
    ))
}

fn extract_media(zip: &Zip) -> Result<(PathBuf, HashMap<String, PathBuf>), String> {
    let dir = unique_media_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建图片临时目录失败：{e}"))?;
    let mut map = HashMap::new();
    for entry in &zip.entries {
        if !entry.name.starts_with("word/media/") {
            continue;
        }
        let Some(bytes) = zip.get(&entry.name) else {
            continue;
        };
        let name = entry
            .name
            .rsplit('/')
            .next()
            .unwrap_or("image")
            .to_string();
        let path = dir.join(&name);
        std::fs::write(&path, bytes).map_err(|e| format!("解压图片失败：{e}"))?;
        map.insert(entry.name.clone(), path);
    }
    Ok((dir, map))
}

/// 正文中直接子级的 `w:p`（跳过表格内的段落）。
pub fn paragraph_elements(root: &Element) -> Vec<&Element> {
    let Some(body) = root.first_child("w:body") else {
        return Vec::new();
    };
    body.elements()
        .filter(|element| element.name == "w:p")
        .collect()
}

pub fn paragraph_text(paragraph: &Element) -> String {
    let mut out = String::new();
    collect_text(paragraph, &mut out);
    out
}

fn collect_text(element: &Element, out: &mut String) {
    for node in &element.children {
        match node {
            Node::Element(child) => {
                if child.name == "w:t" || child.name == "w:delText" {
                    out.push_str(&child.text());
                } else if child.name == "w:tab" {
                    out.push('\t');
                } else if child.name == "w:br" || child.name == "w:cr" {
                    out.push('\n');
                } else {
                    collect_text(child, out);
                }
            }
            Node::Text(text) => {
                if element.name == "w:t" {
                    out.push_str(text);
                }
            }
        }
    }
}

fn paragraph_flags(paragraph: &Element) -> Flags {
    let mut flags = Flags::default();
    let Some(run) = paragraph.first_child("w:r") else {
        return flags;
    };
    let Some(props) = run.first_child("w:rPr") else {
        return flags;
    };
    flags.bold = props.first_child("w:b").is_some();
    flags.italic = props.first_child("w:i").is_some();
    flags.underline = props.first_child("w:u").is_some();
    if let Some(color) = props.first_child("w:color") {
        if let Some(value) = color.attr("w:val") {
            let value = value.trim_start_matches('#');
            if let Some(index) = COLORS.iter().position(|c| c.eq_ignore_ascii_case(value)) {
                flags.color = Some(index as u8);
            }
        }
    }
    flags
}

fn paragraph_indices(root: &Element) -> Vec<usize> {
    let Some(body) = root.first_child("w:body") else {
        return Vec::new();
    };
    body.children
        .iter()
        .enumerate()
        .filter(|(_, node)| matches!(node, Node::Element(e) if e.name == "w:p"))
        .map(|(index, _)| index)
        .collect()
}

fn build_paragraph(root: &Element, body_index: usize, text: &str, flags: Flags) -> Element {
    let properties = root
        .first_child("w:body")
        .and_then(|body| body.children.get(body_index))
        .and_then(|node| match node {
            Node::Element(element) => element.first_child("w:pPr").cloned(),
            _ => None,
        });
    let mut paragraph = Element::new("w:p");
    if let Some(properties) = properties {
        paragraph.push(properties);
    }
    paragraph.push(run_element(text, flags));
    paragraph
}

fn build_paragraph_simple(text: &str, flags: Flags) -> Element {
    let mut paragraph = Element::new("w:p");
    paragraph.push(run_element(text, flags));
    paragraph
}

fn run_element(text: &str, flags: Flags) -> Element {
    let mut run = Element::new("w:r");
    if flags != Flags::default() {
        let mut props = Element::new("w:rPr");
        if flags.bold {
            let mut bold = Element::new("w:b");
            bold.set_attr("w:val", "1");
            props.push(bold);
        }
        if flags.italic {
            let mut italic = Element::new("w:i");
            italic.set_attr("w:val", "1");
            props.push(italic);
        }
        if flags.underline {
            let mut underline = Element::new("w:u");
            underline.set_attr("w:val", "single");
            props.push(underline);
        }
        if let Some(index) = flags.color {
            if let Some(hex) = COLORS.get(index as usize) {
                let mut color = Element::new("w:color");
                color.set_attr("w:val", hex);
                props.push(color);
            }
        }
        run.push(props);
    }
    // 文本中的换行拆成 <w:br/>
    let mut first = true;
    for piece in text.split('\n') {
        if !first {
            run.push(Element::new("w:br"));
        }
        first = false;
        let mut text_element = Element::new("w:t");
        text_element.set_attr("xml:space", "preserve");
        if !piece.is_empty() {
            text_element.push_text(piece);
        }
        run.push(text_element);
    }
    run
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_and_roundtrip() {
        let dir = std::env::temp_dir().join("textm-docx-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("a.docx");
        let mut doc = WordDoc::create();
        doc.save(&path, &["标题段落".into(), "正文".into()], &[Flags::default(), Flags::default()])
            .unwrap();
        let mut loaded = WordDoc::open(&path).unwrap();
        assert_eq!(loaded.paragraph_count(), 2);
        let root = &loaded.root;
        let texts: Vec<String> = paragraph_elements(root).iter().map(|p| paragraph_text(p)).collect();
        assert_eq!(texts, vec!["标题段落", "正文"]);
        let mut styles = loaded.styles();
        styles[0].bold = true;
        loaded.save(&path, &["标题段落".into(), "正文".into()], &styles).unwrap();
        let loaded = WordDoc::open(&path).unwrap();
        assert!(loaded.styles()[0].bold);
        let _ = std::fs::remove_file(&path);
    }
}

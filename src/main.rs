//! Textm 2.0 —— Windows Server Core 终端 / 图形双模式编辑器。
//!
//! 零第三方依赖：控制台、DirectWrite、GDI+、剪贴板等全部通过手写 Win32 FFI 调用。

// 各模块按完整 API 设计，部分入口在后续阶段（GUI / docx / xlsx）接入。
#![allow(dead_code)]

mod archive;
mod config;
mod core;
mod debug;
mod docx;
mod emmet;
mod extension;
mod gui;
mod image;
mod lsp;
mod platform;
mod plugin;
mod remote;
mod render;
mod task;
mod ui;
mod vcs;
mod word;
mod xlsx;
mod xml;

use std::path::PathBuf;

use crate::ui::app::App;

fn main() {
    // Boa 解析 / 执行插件脚本时递归较深，给主线程更大的栈（避免调试版栈溢出）。
    let handle = std::thread::Builder::new()
        .name("textm-main".into())
        .stack_size(32 * 1024 * 1024)
        .spawn(real_main)
        .expect("无法创建主线程");
    let code = handle.join().unwrap_or(1);
    std::process::exit(code);
}

fn real_main() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut width = 100usize;
    let mut height = 30usize;
    let mut dump: Option<String> = None;
    let mut theme: Option<String> = None;
    let mut sidebar = true;
    let mut minimap = true;
    let mut gui = false;
    let mut self_test = false;
    let mut files: Vec<PathBuf> = Vec::new();

    let mut index = 0usize;
    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "-h" | "--help" => {
                print_help();
                return 0;
            }
            "-v" | "--version" => {
                println!("Textm 2.0.0");
                return 0;
            }
            "--self-test" => self_test = true,
            "--gui" => gui = true,
            "--tui" => gui = false,
            "--no-sidebar" => sidebar = false,
            "--no-minimap" => minimap = false,
            "--theme" => {
                index += 1;
                theme = args.get(index).cloned();
            }
            "--dump" => {
                index += 1;
                match args.get(index) {
                    Some(path) => dump = Some(path.clone()),
                    None => {
                        eprintln!("--dump 需要一个输出文件路径");
                        return 2;
                    }
                }
            }
            "--width" => {
                index += 1;
                width = args.get(index).and_then(|v| v.parse().ok()).unwrap_or(100);
            }
            "--height" => {
                index += 1;
                height = args.get(index).and_then(|v| v.parse().ok()).unwrap_or(30);
            }
            other if other.starts_with('-') => {
                eprintln!("未知参数：{other}（使用 --help 查看用法）");
                return 2;
            }
            other => files.push(PathBuf::from(other)),
        }
        index += 1;
    }

    let mut config = config::Config::load();
    // 语言扩展点：加载配置目录下的 languages/*.ini。
    let language_dir = config::Config::path()
        .parent()
        .map(|path| path.to_path_buf())
        .unwrap_or_default();
    let customs = crate::core::language_ext::load(&language_dir);
    crate::core::language::register_custom_languages(customs);
    let snippets = crate::core::language_ext::load_snippets(&language_dir);
    crate::core::snippets::register_custom(snippets);
    if let Some(theme) = theme {
        config.theme = theme;
    }
    if !sidebar {
        config.sidebar = false;
    }
    if !minimap {
        config.minimap = false;
    }

    if self_test {
        return self_test::run(&config);
    }
    if let Some(path) = dump {
        return dump_ui(config, files, width, height, &path);
    }
    if gui || config.gui {
        return match gui::run(config, files) {
            Ok(code) => code,
            Err(e) => {
                eprintln!("GUI 启动失败：{e}");
                platform::log::error(&format!("GUI 启动失败：{e}"));
                3
            }
        };
    }
    match ui::tui::run(config, files) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("启动失败：{e}");
            platform::log::error(&format!("TUI 启动失败：{e}"));
            1
        }
    }
}

fn dump_ui(config: config::Config, files: Vec<PathBuf>, width: usize, height: usize, path: &str) -> i32 {
    let mut app = App::new(config, files, false);
    app.resize(width.max(20), height.max(8));
    let canvas = app.render();
    let mut text = String::new();
    for y in 0..canvas.grid.rows {
        for x in 0..canvas.grid.cols {
            let Some(cell) = canvas.grid.get(x, y) else {
                continue;
            };
            if cell.cont {
                continue;
            }
            text.push(cell.ch);
        }
        while text.ends_with(' ') {
            text.pop();
        }
        text.push('\n');
    }
    if path == "-" {
        print!("{text}");
        return 0;
    }
    match std::fs::write(path, text) {
        Ok(()) => {
            println!("界面已渲染到 {path}（{width}×{height}）");
            0
        }
        Err(e) => {
            eprintln!("写入失败：{e}");
            1
        }
    }
}

fn print_help() {
    println!(
        "Textm 2.0 —— Windows Server Core 终端 / 图形双模式编辑器（零依赖）\n\
\n\
用法：\n  textm.exe [选项] [文件…]\n\
\n\
选项：\n\
  -h, --help             显示本帮助\n\
  -v, --version          显示版本号\n\
      --theme <名称>     启动主题（vscode-dark、dracula、nord…）\n\
      --no-sidebar       启动时隐藏资源管理器\n\
      --no-minimap       启动时关闭小地图\n\
      --gui              图形窗口模式\n\
      --self-test        运行自检并退出（31 项）\n\
      --dump <文件>      把界面渲染为文本后退出（- 表示标准输出）\n\
      --width <列数>     --dump 的宽度（默认 100）\n\
      --height <行数>    --dump 的高度（默认 30）\n\
\n\
常用快捷键：\n\
  Ctrl+N/O/S/W/Q   新建 / 打开 / 保存 / 关闭标签 / 退出\n\
  Ctrl+Z/Y         撤销 / 重做\n\
  Ctrl+F/H         查找 / 替换（Alt+C 大小写、Alt+W 全词、Alt+R 正则）\n\
  Ctrl+Shift+P     命令面板        Ctrl+P 快速打开文件\n\
  Ctrl+Shift+F/H   工程搜索 / 工程替换\n\
  Ctrl+B           资源管理器      Ctrl+Shift+E 聚焦资源管理器\n\
  Ctrl+D           选中下一个相同词  Ctrl+Shift+L 选中所有出现\n\
  Ctrl+Shift+\\     跳转到匹配括号    Ctrl+J 合并行\n\
  Ctrl+Enter       下方插入行        Ctrl+Shift+Enter 上方插入行\n\
  Ctrl+,           设置…             Ctrl+Shift+V 剪贴板历史\n\
  Ctrl+Alt+Z       专注模式（Zen）   彩虹括号 / 居中布局（查看菜单）\n\
  Ctrl+Shift+K     删除当前行\n\
  Ctrl+Shift+X     插件管理\n\
  F5 / Shift+F5    开始调试 / 继续 / 停止\n\
  F9               切换断点        F10/F11 单步跳过 / 进入\n\
  F1               键位速查（按列出的键即执行）   F4 菜单   Shift+F1 完整帮助\n\
  远程             在菜单 / 命令面板里选 SSH 主机、执行远端命令、打开或上传远端文件\n\
  Alt+↑/↓          上移 / 下移行   Ctrl+/ 切换行注释\n\
  Ctrl+Alt+↑/↓     添加多光标\n\
  Alt+Z / Alt+M    自动换行 / 小地图\n\
  Ctrl+Shift+[     折叠当前块\n\
  Ctrl+Space / F12 补全 / 跳转到定义（需配置 LSP）\n\
  Ctrl+Shift+I     悬停提示（LSP）\n\
  Alt+B/I/U        Word 加粗 / 斜体 / 下划线\n\
  F6               Word 页面视图 / 文本视图切换\n\
  Excel            F2 编辑、Shift+方向键扩选、Ctrl+C/X/V、Ctrl+PageUp/Down 切表\n\
  Excel            Ctrl+Shift+M 合并、Ctrl+Shift+L 冻结、Ctrl+Shift+F 筛选\n\
  Git 面板         Space 暂存、Enter 差异、c 提交、D 丢弃、b 分支、l 历史\n\
  打开 .docx/.xlsx 高保真查看 / 段落与单元格编辑（Ctrl+S 原样保存）\n\
  打开图片         PNG/JPEG/GIF/BMP（TUI 半块预览，GUI 位图）\n\
\n\
配置文件：%APPDATA%\\Textm\\config.ini（可用 TEXTM_CONFIG 覆盖）\n\
插件目录：%APPDATA%\\Textm\\plugins\\<名称>\\textm.json（可选 index.js）\n\
远程：remote.<名称> = user@host[:端口]、remote.<名称>.root = /远端/目录\n\
调试：debug.<类型> = 适配器命令（如 debug.python = python -m debugpy.adapter）\n"
    );
}

mod self_test {
    use super::*;
    use crate::config::Config;
    use crate::core::diff;
    use crate::core::document::{Cursor, Document, Pos};
    use crate::core::encoding::{self, Encoding, Eol};
    use crate::core::fold::Folds;
    use crate::core::highlight::{self, LexState};
    use crate::core::language::Language;
    use crate::core::search::{SearchEngine, SearchOptions};

    pub fn run(config: &Config) -> i32 {
        let mut passed = 0;
        let mut failed = 0;
        let mut check = |name: &str, result: Result<(), String>| {
            match result {
                Ok(()) => {
                    println!("[ OK ] {name}");
                    passed += 1;
                }
                Err(e) => {
                    println!("[FAIL] {name}: {e}");
                    failed += 1;
                }
            }
        };

        check("缓冲区与编辑", (|| -> Result<(), String> {
            let mut doc = Document::from_text("abc", None);
            doc.set_cursor(Pos::new(0, 1));
            doc.insert_text("X");
            if doc.text() == "aXbc" {
                Ok(())
            } else {
                Err(format!("得到 {}", doc.text()))
            }
        })());

        check("撤销与重做", (|| -> Result<(), String> {
            let mut doc = Document::from_text("abc", None);
            doc.set_cursor(Pos::new(0, 3));
            doc.insert_text("d");
            doc.undo();
            if doc.text() != "abc" {
                return Err("撤销失败".into());
            }
            doc.redo();
            if doc.text() != "abcd" {
                return Err("重做失败".into());
            }
            Ok(())
        })());

        check("多光标编辑", (|| -> Result<(), String> {
            let mut doc = Document::from_text("a\nb", None);
            doc.cursors = vec![Cursor::at(Pos::new(0, 0)), Cursor::at(Pos::new(1, 0))];
            doc.insert_text(">");
            if doc.text() == ">a\n>b" {
                Ok(())
            } else {
                Err(doc.text())
            }
        })());

        check("GBK 往返", (|| -> Result<(), String> {
            let bytes = encoding::encode("中文\r\n第二行", Encoding::Gbk, Eol::CrLf);
            let decoded = encoding::decode(&bytes);
            if decoded.encoding == Encoding::Gbk && decoded.text == "中文\n第二行" {
                Ok(())
            } else {
                Err(format!("{:?} {:?}", decoded.encoding, decoded.text))
            }
        })());

        check("UTF-16LE 往返", (|| -> Result<(), String> {
            let bytes = encoding::encode("Textm 中文", Encoding::Utf16Le, Eol::Lf);
            let decoded = encoding::decode(&bytes);
            if decoded.text == "Textm 中文" {
                Ok(())
            } else {
                Err(decoded.text)
            }
        })());

        check("查找与替换", (|| -> Result<(), String> {
            let doc = Document::from_text("hello world\nhello", None);
            let engine = SearchEngine::new("hello", SearchOptions::default());
            let all = engine.find_all(&doc);
            if all.len() != 2 {
                return Err(format!("找到 {} 处", all.len()));
            }
            let mut doc = doc;
            let edits: Vec<(Pos, Pos, String)> = all
                .iter()
                .map(|(s, e)| (*s, *e, "hi".to_string()))
                .collect();
            doc.replace_ranges_each(&edits);
            if doc.text() == "hi world\nhi" {
                Ok(())
            } else {
                Err(doc.text())
            }
        })());

        check("正则表达式", (|| -> Result<(), String> {
            let engine = SearchEngine::new(
                "h[a-z]+o",
                SearchOptions {
                    regex: true,
                    case_sensitive: false,
                    whole_word: false,
                },
            );
            let doc = Document::from_text("hello", None);
            if engine.find_all(&doc).len() != 1 {
                return Err("匹配数量不对".into());
            }
            // 捕获组 + $1 替换（工程替换与编辑器内替换共用）。
            let engine = SearchEngine::new(
                "(\\w+)@(\\w+)",
                SearchOptions {
                    regex: true,
                    case_sensitive: false,
                    whole_word: false,
                },
            );
            let (text, count) = engine.replace_in_line("foo@bar baz@qux", "$2.$1", 10);
            if count != 2 || text != "bar.foo qux.baz" {
                return Err(format!("捕获组替换结果不对：{count} 处，{text}"));
            }
            Ok(())
        })());

        check("语法高亮", (|| -> Result<(), String> {
            let mut state = LexState::Normal;
            let tokens = highlight::highlight(Language::Rust, "fn main() {}", &mut state);
            if tokens.iter().any(|t| t.kind == highlight::TokenKind::Keyword) {
                Ok(())
            } else {
                Err("没有识别到关键字".into())
            }
        })());

        check("代码折叠", (|| -> Result<(), String> {
            let mut folds = Folds::default();
            let lines: Vec<String> = "fn a() {\n  b();\n}\n".split('\n').map(|s| s.to_string()).collect();
            folds.recompute(&lines, 4, true);
            if folds.ranges.is_empty() {
                Err("没有生成折叠范围".into())
            } else {
                Ok(())
            }
        })());

        check("差异视图", (|| -> Result<(), String> {
            let old: Vec<String> = vec!["a".into(), "b".into()];
            let new: Vec<String> = vec!["a".into(), "c".into()];
            let text = diff::unified_diff(&old, &new, "a", "b", 1);
            if text.contains("@@") {
                Ok(())
            } else {
                Err(text)
            }
        })());

        check("保存与读取", (|| -> Result<(), String> {
            let dir = std::env::temp_dir().join("textm-selftest");
            let _ = std::fs::create_dir_all(&dir);
            let path = dir.join("roundtrip.txt");
            let mut doc = Document::from_text("第一行\nline2", None);
            doc.save_to(&path)?;
            let loaded = Document::load(&path)?;
            let _ = std::fs::remove_file(&path);
            if loaded.text() == "第一行\nline2" {
                Ok(())
            } else {
                Err(loaded.text())
            }
        })());

        check("界面渲染", (|| -> Result<(), String> {
            let mut app = App::new(config.clone(), Vec::new(), false);
            app.resize(100, 30);
            let canvas = app.render();
            if canvas.grid.cols == 100 && canvas.grid.rows == 30 {
                Ok(())
            } else {
                Err("画布尺寸不符".into())
            }
        })());

        check("剪贴板", (|| -> Result<(), String> {
            let text = "Textm 剪贴板测试";
            crate::platform::clipboard::set_text(text)?;
            let back = crate::platform::clipboard::get_text();
            if back == text {
                Ok(())
            } else {
                Err(format!("读回 {:?}", back))
            }
        })());

        check("JSON / LSP 协议", (|| -> Result<(), String> {
            let value = crate::lsp::json::parse("{\"id\":1,\"result\":null}")?;
            if value.get("id").and_then(|v| v.as_i64()) == Some(1) {
                Ok(())
            } else {
                Err("JSON 解析结果不对".into())
            }
        })());

        check("图片格式识别", (|| -> Result<(), String> {
            if crate::image::ImageKind::from_path(std::path::Path::new("a.png")).is_some() {
                Ok(())
            } else {
                Err("PNG 未识别".into())
            }
        })());

        check("ZIP / OOXML 容器", (|| -> Result<(), String> {
            let mut zip = crate::archive::Zip { entries: Vec::new() };
            zip.set("word/document.xml", "<a>中文</a>".as_bytes());
            let bytes = zip.write();
            let read = crate::archive::Zip::read(&bytes)?;
            if read.get_text("word/document.xml").as_deref() == Some("<a>中文</a>") {
                Ok(())
            } else {
                Err("ZIP 往返失败".into())
            }
        })());

        check("Word 文档往返", (|| -> Result<(), String> {
            let dir = std::env::temp_dir().join("textm-selftest");
            let _ = std::fs::create_dir_all(&dir);
            let path = dir.join("selftest.docx");
            let mut word = crate::docx::WordDoc::create();
            word.save(
                &path,
                &["第一段".into(), "第二段".into()],
                &[crate::docx::Flags::default(), crate::docx::Flags::default()],
            )?;
            let loaded = crate::docx::WordDoc::open(&path)?;
            let _ = std::fs::remove_file(&path);
            if loaded.paragraph_count() == 2 && loaded.texts()[0] == "第一段" {
                Ok(())
            } else {
                Err("Word 段落数量或内容不对".into())
            }
        })());

        check("Word 富文本与分页排版", (|| -> Result<(), String> {
            let dir = std::env::temp_dir().join("textm-selftest");
            let _ = std::fs::create_dir_all(&dir);
            let path = dir.join("rich.docx");
            let document = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>标题</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr><w:ind w:left="720" w:hanging="360"/></w:pPr><w:r><w:t>列表项</w:t></w:r></w:p>
<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders><w:top w:val="single" w:sz="4"/><w:left w:val="single" w:sz="4"/><w:bottom w:val="single" w:sz="4"/><w:right w:val="single" w:sz="4"/><w:insideH w:val="single" w:sz="4"/><w:insideV w:val="single" w:sz="4"/></w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w="2400"/><w:gridCol w:w="2400"/></w:tblGrid><w:tr><w:tc><w:tcPr><w:tcW w:w="2400" w:type="dxa"/><w:shd w:fill="D9E2F3"/></w:tcPr><w:p><w:r><w:t>单元格A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:rPr><w:b/><w:color w:val="C00000"/></w:rPr><w:t>单元格B</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:p><w:r><w:br w:type="page"/></w:r><w:r><w:t>第二页</w:t></w:r></w:p>
<w:sectPr><w:headerReference w:type="default" r:id="rId2"/><w:footerReference w:type="default" r:id="rId3"/><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1800" w:bottom="1440" w:left="1800" w:header="851" w:footer="992"/></w:sectPr>
</w:body></w:document>"#;
            let styles = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:eastAsia="宋体"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/><w:color w:val="1F3864"/></w:rPr></w:style></w:styles>"#;
            let numbering = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>"#;
            let rels = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/></Relationships>"#;
            let header = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>页眉 </w:t></w:r><w:fldSimple w:instr=" PAGE "><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p></w:hdr>"#;
            let footer = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>页脚</w:t></w:r></w:p></w:ftr>"#;
            let mut zip = crate::archive::Zip { entries: Vec::new() };
            zip.set("word/document.xml", document.as_bytes());
            zip.set("word/styles.xml", styles.as_bytes());
            zip.set("word/numbering.xml", numbering.as_bytes());
            zip.set("word/_rels/document.xml.rels", rels.as_bytes());
            zip.set("word/header1.xml", header.as_bytes());
            zip.set("word/footer1.xml", footer.as_bytes());
            std::fs::write(&path, zip.write()).map_err(|e| e.to_string())?;

            let mut word = crate::docx::WordDoc::open(&path)?;
            let heading = word
                .model
                .blocks
                .iter()
                .find_map(|block| match block {
                    crate::word::model::Block::Paragraph(paragraph)
                        if paragraph.style_name == "heading 1" =>
                    {
                        Some(paragraph)
                    }
                    _ => None,
                })
                .ok_or("没有解析到标题样式")?;
            if !heading.runs.first().map(|run| run.props.bold).unwrap_or(false) {
                return Err("标题样式未继承粗体".into());
            }
            let has_table = word
                .model
                .blocks
                .iter()
                .any(|block| matches!(block, crate::word::model::Block::Table(_)));
            if !has_table {
                return Err("表格未解析".into());
            }
            if word.model.headers.is_empty() {
                return Err("页眉未解析".into());
            }
            let mut measure = crate::word::measure::ApproxMeasurer;
            let layout = crate::word::layout::layout(&word.model, &mut measure, 1.0);
            if layout.pages.len() < 2 {
                return Err(format!("分页数量 {}", layout.pages.len()));
            }
            let texts: Vec<String> = layout
                .pages
                .iter()
                .flat_map(|page| page.items.iter())
                .filter_map(|item| match item {
                    crate::word::layout::Item::Text { text, .. } => Some(text.clone()),
                    _ => None,
                })
                .collect();
            let joined = texts.join("");
            if !joined.contains("页眉") || !joined.contains("第二页") {
                return Err(format!(
                    "页眉或正文没有排入页面：headers={} pages={} texts={joined}",
                    word.model.headers.len(),
                    layout.pages.len(),
                ));
            }
            // 保存后模型应能重建
            let texts = word.texts();
            let styles = word.styles();
            word.save(&path, &texts, &styles)?;
            let loaded = crate::docx::WordDoc::open(&path)?;
            let _ = std::fs::remove_file(&path);
            if loaded.model.blocks.len() != word.model.blocks.len() {
                return Err("保存后模型块数量变化".into());
            }
            Ok(())
        })());

        check("Excel 表格与公式", (|| -> Result<(), String> {
            let dir = std::env::temp_dir().join("textm-selftest");
            let _ = std::fs::create_dir_all(&dir);
            let path = dir.join("selftest.xlsx");
            let mut book = crate::xlsx::Workbook::create();
            book.set_cell(0, 0, 0, "2");
            book.set_cell(0, 0, 1, "3");
            book.set_cell(0, 1, 0, "=A1+B1");
            // 高级表格流程：样式、合并、冻结、排序、多工作表。
            let mut sheet = crate::xlsx::Workbook::create();
            sheet.set_cell(0, 0, 0, "名称");
            sheet.set_cell(0, 0, 1, "数量");
            sheet.set_cell(0, 1, 0, "苹果");
            sheet.set_cell(0, 1, 1, "3");
            sheet.set_cell(0, 2, 0, "香蕉");
            sheet.set_cell(0, 2, 1, "5");
            sheet.set_cell(0, 3, 0, "=SUM(B2:B3)");
            sheet.merge(0, crate::xlsx::MergeRange::new(0, 3, 0, 4));
            sheet.freeze(0, 1, 1);
            sheet.sort_range(0, crate::xlsx::MergeRange::new(0, 0, 2, 1), 1, false, true);
            sheet.format_range(
                0,
                crate::xlsx::MergeRange::new(1, 0, 1, 1),
                crate::xlsx::styles::FormatAction::Bold,
            );
            let index = sheet.add_sheet("数据二")?;
            sheet.set_cell(index, 0, 0, "42");
            sheet.active = 0;
            let path2 = dir.join("selftest-advanced.xlsx");
            sheet.save(&path2)?;
            let loaded = crate::xlsx::Workbook::open(&path2)?;
            let _ = std::fs::remove_file(&path2);
            book.save(&path)?;
            let first = crate::xlsx::Workbook::open(&path)?;
            let _ = std::fs::remove_file(&path);
            if first.display(0, 1, 0) != "5" {
                return Err(format!("公式结果 {}", first.display(0, 1, 0)));
            }
            if !loaded.style_at(0, 1, 0).font.bold {
                return Err("样式未保存".into());
            }
            match loaded.sheet().merge_at(0, 3) {
                Some(range) if range.c2 == 4 => {}
                _ => return Err("合并单元格未保存".into()),
            }
            if loaded.sheet().freeze_rows != 1 || loaded.sheet().freeze_cols != 1 {
                return Err("冻结窗格未保存".into());
            }
            if loaded.sheet().cell_input(1, 0) != "香蕉" {
                return Err("排序未生效".into());
            }
            if loaded.display(0, 3, 0) != "8" {
                return Err(format!("区域公式结果 {}", loaded.display(0, 3, 0)));
            }
            if loaded.sheets.len() != 2 || loaded.sheets[1].cell_input(0, 0) != "42" {
                return Err("多工作表未保存".into());
            }
            Ok(())
        })());

        check("扩展编辑命令", (|| -> Result<(), String> {
            // 括号配对与跳转
            let mut doc = Document::from_text("(a\nb)", None);
            doc.set_cursor(Pos::new(0, 0));
            if !doc.goto_bracket() {
                return Err("括号配对失败".into());
            }
            if doc.primary().pos != Pos::new(1, 1) {
                return Err("括号跳转位置错误".into());
            }
            // 合并行
            let mut d2 = Document::from_text("a\nb", None);
            d2.set_cursor(Pos::new(0, 1));
            if !d2.join_lines() || d2.line(0) != "ab" {
                return Err("合并行失败".into());
            }
            // 插入行
            let mut d3 = Document::from_text("x", None);
            d3.set_cursor(Pos::new(0, 0));
            d3.insert_line_below();
            if d3.line_count() != 2 {
                return Err("在下方插入行失败".into());
            }
            // 选中所有出现
            let mut d4 = Document::from_text("x x x", None);
            d4.set_cursor(Pos::new(0, 0));
            if !d4.select_all_occurrences() {
                return Err("选中所有出现失败".into());
            }
            Ok(())
        })());

        check("Emmet 与多光标", (|| -> Result<(), String> {
            let mut doc = Document::from_text("a\nbb", None);
            doc.select_all();
            doc.add_cursors_at_line_ends();
            let out = crate::emmet::expand_html("div.a>p{b}")
                .ok_or_else(|| "Emmet 展开失败".to_string())?;
            if !out.contains("class=\"a\"") || !out.contains("<p>b</p>") {
                return Err("Emmet 结果错误".into());
            }
            Ok(())
        })());

        check("任务运行", (|| -> Result<(), String> {
            let task = crate::task::Task {
                label: "echo".into(),
                command: "echo".into(),
                args: vec!["textm-task".into()],
                cwd: None,
                group: false,
            };
            let mut run = crate::task::TaskRun::start(&task)?;
            let start = std::time::Instant::now();
            while !run.poll() {
                if start.elapsed().as_secs() > 10 {
                    run.stop();
                    return Err("任务超时".into());
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            let lines = run.tail(10);
            if lines.iter().any(|l| l.contains("textm-task")) {
                Ok(())
            } else {
                Err(format!("输出：{lines:?}"))
            }
        })());

        check("插件清单与命令", (|| -> Result<(), String> {
            let dir = std::env::temp_dir().join("textm-selftest-ext");
            let ext_dir = dir.join("plugins").join("demo");
            std::fs::create_dir_all(&ext_dir).map_err(|e| e.to_string())?;
            let manifest = r#"{
                "name": "demo",
                "version": "1.0.0",
                "description": "示例插件",
                "commands": [
                    {"id": "demo.build", "title": "构建", "program": "cargo", "args": ["build"], "cwd": "${workspaceFolder}"}
                ]
            }"#;
            std::fs::write(ext_dir.join("textm.json"), manifest).map_err(|e| e.to_string())?;
            let list = crate::extension::load(&dir, &[], &[]);
            let _ = std::fs::remove_dir_all(&dir);
            let Some(ext) = list.iter().find(|ext| ext.name == "demo") else {
                return Err("未扫描到插件".into());
            };
            if ext.commands.len() != 1 {
                return Err(format!("命令数量 {}", ext.commands.len()));
            }
            if ext.commands[0].id != "demo.build" {
                return Err(format!("命令 id {}", ext.commands[0].id));
            }
            let task = ext.task(&ext.commands[0], std::path::Path::new("C:/work"));
            if task.command_line() != "cargo build" {
                return Err(task.command_line());
            }
            Ok(())
        })());

        check("调试配置与断点", (|| -> Result<(), String> {
            let text = r#"{
                "version": "0.2.0",
                "configurations": [
                    {"name": "Python", "type": "python", "request": "launch",
                     "program": "${workspaceFolder}/main.py"}
                ]
            }"#;
            let value = crate::lsp::json::parse(text)?;
            let configs = crate::debug::parse_launch(&value);
            let Some(cfg) = configs.first() else {
                return Err("未解析到调试配置".into());
            };
            let raw = crate::debug::prepare_launch(cfg, std::path::Path::new("C:/work"), None);
            let program = raw
                .get("program")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if program != "C:/work/main.py" {
                return Err(format!("占位符展开结果 {program}"));
            }
            if crate::debug::adapter_for("python", &std::collections::HashMap::new()).is_none() {
                return Err("python 默认适配器缺失".into());
            }
            let mut state = crate::debug::DebugState::new();
            let path = std::path::Path::new("C:/work/main.py");
            if !state.toggle_breakpoint(path, 4) || !state.has_breakpoint(path, 4) {
                return Err("断点设置失败".into());
            }
            if state.toggle_breakpoint(path, 4) || state.has_breakpoint(path, 4) {
                return Err("断点移除失败".into());
            }
            Ok(())
        })());

        check("远程主机与路径", (|| -> Result<(), String> {
            let host = crate::remote::RemoteHost::parse("dev", "u@192.0.2.10:2222", "/srv/app")
                .ok_or_else(|| "主机解析失败".to_string())?;
            if host.target() != "u@192.0.2.10" || host.port != 2222 {
                return Err(format!("{}:{}", host.target(), host.port));
            }
            let task = host.command_task("ls -l");
            let last = task.args.last().cloned().unwrap_or_default();
            if last != "cd /srv/app && ls -l" {
                return Err(last);
            }
            let cache = crate::remote::cache_path(
                std::path::Path::new("C:/cache"),
                "dev",
                "/home/u/a.py",
            );
            if cache != std::path::Path::new("C:/cache/dev/home/u/a.py") {
                return Err(cache.display().to_string());
            }
            Ok(())
        })());

        check("插件主题与片段", (|| -> Result<(), String> {
            let theme_text = r##"{
                "name": "示例主题",
                "dark": true,
                "bg": "#1e1e1e",
                "fg": "#d4d4d4",
                "syntax": {"keyword": "#569cd6"}
            }"##;
            let value = crate::lsp::json::parse(theme_text)?;
            let theme = crate::extension::theme_from_json(&value, "回退")
                .ok_or_else(|| "主题转换失败".to_string())?;
            if theme.bg != crate::render::Color::rgb(30, 30, 30)
                || theme.syntax.keyword != crate::render::Color::rgb(86, 156, 214)
            {
                return Err("主题颜色未正确解析".into());
            }
            let snippet_text = r#"{
                "Print": {"language": "Rust", "body": "println!(\"hi\");"}
            }"#;
            let value = crate::lsp::json::parse(snippet_text)?;
            let items = crate::extension::snippets_from_json(&value);
            if items.len() != 1 || items[0].0 != "Print" || !items[0].2.contains("println!") {
                return Err(format!("片段解析结果不对：{items:?}"));
            }
            Ok(())
        })());

        check("插件开关与菜单", (|| -> Result<(), String> {
            let mut config = Config::default();
            config.plugins_enabled = false;
            let mut app = App::new(config, Vec::new(), false);
            if app.menus().iter().any(|menu| menu.title == "插件") {
                return Err("关闭插件功能时仍显示“插件”菜单".into());
            }
            if !crate::ui::app::is_plugin_cmd(crate::ui::app::Cmd::Extensions) {
                return Err("插件命令分类缺失".into());
            }
            app.config.plugins_enabled = true;
            if !app.menus().iter().any(|menu| menu.title == "插件") {
                return Err("开启后没有“插件”菜单".into());
            }
            Ok(())
        })());

        check("插件运行（JS）", (|| -> Result<(), String> {
            let root = std::env::temp_dir().join("textm-selftest-plugin");
            let dir = root.join("plugins").join("demo");
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            std::fs::write(
                dir.join("textm.json"),
                r#"{
                    "name": "self-test",
                    "version": "1.0.0",
                    "description": "自检插件",
                    "main": "index.js",
                    "commands": [{"id": "demo.ping", "title": "Ping"}]
                }"#,
            )
            .map_err(|e| e.to_string())?;
            std::fs::write(
                dir.join("index.js"),
                r#"
                exports.activate = function (context) {
                  const textm = context.textm;
                  textm.commands.register('demo.ping', function () {
                    textm.window.info('plugin-ok ' + textm.env.appName);
                  });
                };
                "#,
            )
            .map_err(|e| e.to_string())?;
            let plugins = crate::extension::load(&root, &[], &[]);
            let mut host = crate::plugin::PluginHost::new();
            host.reload_from(&plugins);
            let mut context = crate::plugin::HostContext::default();
            context.workspace = root.clone();
            context.roots = vec![root.clone()];
            host.set_context(context);
            host.execute("demo.ping", "[]")?;
            let requests = host.drain_requests();
            let _ = std::fs::remove_dir_all(&root);
            let hit = requests.iter().any(|request| {
                matches!(
                    request,
                    crate::plugin::Request::Message { text, .. } if text.contains("plugin-ok Textm")
                )
            });
            if hit {
                Ok(())
            } else {
                Err(format!("未收到插件消息：{requests:?}"))
            }
        })());

        check("Vim 引擎", (|| -> Result<(), String> {
            use crate::core::vim::{Mode, Vim};
            use crate::platform::console::{Key, KeyCode, Mods};
            let press = |vim: &mut Vim, doc: &mut Document, keys: &str| {
                for ch in keys.chars() {
                    vim.handle(
                        Key {
                            code: KeyCode::Char(ch),
                            mods: Mods::none(),
                        },
                        doc,
                        4,
                    );
                }
            };
            let mut doc = Document::from_text("one two\nthree", None);
            let mut vim = Vim::new();
            press(&mut vim, &mut doc, "dw");
            if doc.line(0) != "two" {
                return Err(format!("dw 得到 {:?}", doc.line(0)));
            }
            press(&mut vim, &mut doc, "yy");
            press(&mut vim, &mut doc, "p");
            if doc.line_count() != 3 {
                return Err("yy/p 未复制整行".into());
            }
            press(&mut vim, &mut doc, "ciw");
            if vim.mode != Mode::Insert {
                return Err("ciw 未进入插入模式".into());
            }
            // Ex 替换
            let mut app = App::new(Config::default(), Vec::new(), false);
            app.resize(100, 30);
            app.tab_mut().doc = Document::from_text("a b a", None);
            app.refresh_active(true);
            app.exec_ex("%s/a/c/g");
            if app.doc().line(0) != "c b c" {
                return Err(format!(":s 得到 {:?}", app.doc().line(0)));
            }
            Ok(())
        })());

        check("分屏与终端解析", (|| -> Result<(), String> {
            let mut app = App::new(Config::default(), Vec::new(), false);
            app.resize(120, 34);
            app.tab_mut().doc = Document::from_text("a\nb\nc", None);
            app.refresh_active(true);
            app.split_editor(true);
            if app.layout.panes.len() != 2 {
                return Err("分屏后 pane 数不为 2".into());
            }
            let canvas = app.render();
            if canvas.grid.cols != 120 || canvas.grid.rows != 34 {
                return Err("分屏渲染尺寸不对".into());
            }
            app.close_split();
            if app.layout.panes.len() != 1 {
                return Err("关闭分屏失败".into());
            }
            // 终端 VT 解析
            let mut screen = crate::platform::term::Screen::new(20, 4);
            screen.feed(b"\x1b[32mok\x1b[0m\r\nsecond");
            let text = screen.text();
            if !text.contains("ok") || !text.contains("second") {
                return Err("终端文本解析失败".into());
            }
            Ok(())
        })());

        check("设置页", (|| -> Result<(), String> {
            let mut app = App::new(Config::default(), Vec::new(), false);
            app.resize(100, 30);
            app.open_settings();
            if app.settings_rows().is_empty() {
                return Err("设置页没有条目".into());
            }
            // 切到「外观」分类的第一项（主题）并右移，应立即生效。
            if let Some(page) = app.settings.as_mut() {
                page.category = 1;
                page.selected = 0;
            }
            let before = app.config.theme.clone();
            app.settings_adjust(1);
            if app.config.theme == before || app.theme.name != app.config.theme {
                return Err(format!("主题未切换：{} -> {}", before, app.config.theme));
            }
            // 搜索词过滤
            if let Some(page) = app.settings.as_mut() {
                page.query = "终端".into();
            }
            let rows = app.settings_rows();
            if rows.is_empty() {
                return Err("搜索没有结果".into());
            }
            // 渲染出「设置」标题
            let canvas = app.render();
            let mut top = String::new();
            for x in 0..canvas.grid.cols {
                if let Some(cell) = canvas.grid.get(x, 0) {
                    if cell.cont {
                        continue;
                    }
                    top.push(cell.ch);
                }
            }
            if !top.contains("设置") {
                return Err(format!("设置页标题未渲染：{top:?}"));
            }
            Ok(())
        })());

        println!("\n自检结果：{passed} 通过，{failed} 失败");
        if failed == 0 {
            0
        } else {
            1
        }
    }
}

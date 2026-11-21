//! 编辑器核心：文档、编码、语法、搜索、折叠、diff 等。

pub mod diff;
pub mod document;
pub mod encoding;
pub mod fold;
pub mod glob;
pub mod highlight;
pub mod language;
pub mod language_ext;
pub mod regex_lite;
pub mod search;
pub mod snippets;
pub mod unicode;
pub mod vim;

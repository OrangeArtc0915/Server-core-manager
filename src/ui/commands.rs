//! 命令执行、浮层交互、Git / LSP / 文件操作的具体实现。

use std::path::{Path, PathBuf};

use crate::core::diff::unified_diff;
use crate::core::document::{Document, Pos};
use crate::core::encoding::{Encoding, Eol};
use crate::core::language::Language;
use crate::core::search::{SearchEngine, SearchOptions};
use crate::core::snippets;
use crate::lsp::json::Json;
use crate::platform::clipboard;
use crate::platform::console::{Key, KeyCode, Mods, Mouse, MouseKind};
use crate::ui::app::{
    Cmd, ConfirmAction, ConfirmState, FindState, Focus, Hint, HintTarget, LayoutStyle, ListItem,
    ListKind, ListState, Overlay, PromptKind, PromptState, Rect, SettingRow, StatusItem, Tab,
};

pub static COMMANDS: &[(&str, Cmd)] = &[
    ("新建文件", Cmd::NewFile),
    ("打开文件…", Cmd::OpenPath),
    ("保存", Cmd::Save),
    ("另存为…", Cmd::SaveAs),
    ("全部保存", Cmd::SaveAll),
    ("关闭标签页", Cmd::CloseTab),
    ("退出", Cmd::Quit),
    ("撤销", Cmd::Undo),
    ("重做", Cmd::Redo),
    ("剪切", Cmd::Cut),
    ("复制", Cmd::Copy),
    ("粘贴", Cmd::Paste),
    ("全选", Cmd::SelectAll),
    ("选择当前行", Cmd::SelectLine),
    ("选择下一个相同内容", Cmd::SelectNextOccurrence),
    ("复制当前行", Cmd::DuplicateLine),
    ("删除当前行", Cmd::DeleteLine),
    ("上移行", Cmd::MoveLineUp),
    ("下移行", Cmd::MoveLineDown),
    ("上方添加光标", Cmd::AddCursorUp),
    ("下方添加光标", Cmd::AddCursorDown),
    ("切换行注释", Cmd::ToggleComment),
    ("升序排序", Cmd::SortAsc),
    ("降序排序", Cmd::SortDesc),
    ("删除重复行", Cmd::Dedup),
    ("转为大写", Cmd::Upper),
    ("转为小写", Cmd::Lower),
    ("查找", Cmd::Find),
    ("替换", Cmd::Replace),
    ("转到行…", Cmd::GotoLine),
    ("切换书签", Cmd::ToggleBookmark),
    ("资源管理器", Cmd::ToggleSidebar),
    ("快速打开…", Cmd::QuickOpen),
    ("命令面板…", Cmd::Palette),
    ("自动换行", Cmd::ToggleWrap),
    ("小地图", Cmd::ToggleMinimap),
    ("自动保存", Cmd::ToggleAutosave),
    ("粘性滚动", Cmd::ToggleStickyScroll),
    ("切换折叠", Cmd::FoldBlock),
    ("全部折叠", Cmd::FoldAll),
    ("全部展开", Cmd::UnfoldAll),
    ("显示空白字符", Cmd::ToggleWhitespace),
    ("选择主题…", Cmd::ThemePicker),
    ("选择语言模式…", Cmd::LanguagePicker),
    ("选择编码…", Cmd::EncodingPicker),
    ("选择换行符…", Cmd::EolPicker),
    ("插入代码片段…", Cmd::SnippetPicker),
    ("符号大纲", Cmd::Outline),
    ("问题列表", Cmd::Problems),
    ("与文件比较…", Cmd::CompareFile),
    ("新建 Word 文档", Cmd::NewWordDoc),
    ("新建 Excel 表格", Cmd::NewExcelDoc),
    ("Git 状态", Cmd::GitStatus),
    ("Git 差异", Cmd::GitDiff),
    ("Git 历史", Cmd::GitLog),
    ("Git 提交…", Cmd::GitCommit),
    ("Git 暂存选中", Cmd::GitStage),
    ("Git 取消暂存选中", Cmd::GitUnstage),
    ("Git 暂存全部", Cmd::GitStageAll),
    ("Git 取消暂存全部", Cmd::GitUnstageAll),
    ("Git 丢弃选中改动", Cmd::GitDiscard),
    ("Git 切换分支…", Cmd::GitBranches),
    ("Git 新建分支…", Cmd::GitBranchCreate),
    ("Git 删除分支…", Cmd::GitBranchDelete),
    ("Git 合并分支…", Cmd::GitMerge),
    ("Git 拉取", Cmd::GitPull),
    ("Git 推送", Cmd::GitPush),
    ("Git 获取远程", Cmd::GitFetch),
    ("Git 暂存改动 (stash)", Cmd::GitStash),
    ("Git 恢复 stash", Cmd::GitStashPop),
    ("Git Blame 当前文件", Cmd::GitBlame),
    ("语言服务器补全", Cmd::LspComplete),
    ("跳转到定义", Cmd::LspDefinition),
    ("定义预览", Cmd::LspPeekDefinition),
    ("悬停提示", Cmd::LspHover),
    ("查找引用", Cmd::LspReferences),
    ("工作区符号…", Cmd::LspSymbols),
    ("重命名符号…", Cmd::LspRename),
    ("格式化文档", Cmd::LspFormat),
    ("签名帮助", Cmd::LspSignature),
    ("快速修复 / 代码操作…", Cmd::LspCodeAction),
    ("切换输入自动补全", Cmd::ToggleLspAutoComplete),
    ("切换签名帮助提示", Cmd::ToggleLspSignature),
    ("切换内联提示", Cmd::ToggleLspInlayHints),
    ("工程搜索", Cmd::WorkspaceSearch),
    ("工程替换…", Cmd::WorkspaceReplace),
    ("工程搜索：包含文件…", Cmd::WorkspaceInclude),
    ("工程搜索：排除文件…", Cmd::WorkspaceExclude),
    ("工程搜索：切换 .gitignore 过滤", Cmd::WorkspaceToggleIgnore),
    ("工作区：添加文件夹…", Cmd::WorkspaceAddFolder),
    ("工作区：移除所选文件夹", Cmd::WorkspaceRemoveFolder),
    ("资源管理器：新建文件…", Cmd::ExplorerNewFile),
    ("资源管理器：新建文件夹…", Cmd::ExplorerNewFolder),
    ("资源管理器：重命名…", Cmd::ExplorerRename),
    ("资源管理器：删除", Cmd::ExplorerDelete),
    ("资源管理器：刷新", Cmd::ExplorerRefresh),
    ("加粗", Cmd::ExcelBold),
    ("斜体", Cmd::ExcelItalic),
    ("下划线", Cmd::ExcelUnderline),
    ("字号…", Cmd::ExcelFontSize),
    ("字体颜色…", Cmd::ExcelFontColor),
    ("填充颜色…", Cmd::ExcelFillColor),
    ("数字格式…", Cmd::ExcelNumberFormat),
    ("左对齐", Cmd::ExcelAlignLeft),
    ("居中", Cmd::ExcelAlignCenter),
    ("右对齐", Cmd::ExcelAlignRight),
    ("所有框线", Cmd::ExcelBorder),
    ("清除框线", Cmd::ExcelClearBorder),
    ("合并单元格", Cmd::ExcelMerge),
    ("取消合并", Cmd::ExcelUnmerge),
    ("冻结 / 取消冻结窗格", Cmd::ExcelFreeze),
    ("筛选当前列…", Cmd::ExcelFilter),
    ("清除筛选", Cmd::ExcelClearFilter),
    ("表格升序排序", Cmd::ExcelSortAsc),
    ("表格降序排序", Cmd::ExcelSortDesc),
    ("插入行", Cmd::ExcelInsertRow),
    ("删除行", Cmd::ExcelDeleteRow),
    ("插入列", Cmd::ExcelInsertCol),
    ("删除列", Cmd::ExcelDeleteCol),
    ("新建工作表…", Cmd::ExcelSheetAdd),
    ("重命名工作表…", Cmd::ExcelSheetRename),
    ("删除工作表", Cmd::ExcelSheetDelete),
    ("下一个工作表", Cmd::ExcelSheetNext),
    ("上一个工作表", Cmd::ExcelSheetPrev),
    ("清除单元格内容", Cmd::ExcelClear),
    ("专注模式（Zen）", Cmd::ToggleZen),
    ("彩虹括号", Cmd::ToggleRainbow),
    ("居中布局", Cmd::ToggleCentered),
    ("切换界面布局", Cmd::ToggleLayout),
    ("标签：移动到另一组", Cmd::MoveTabToOtherGroup),
    ("设置…", Cmd::OpenSettings),
    ("剪贴板历史…", Cmd::ClipboardHistory),
    ("选中所有出现", Cmd::SelectAllOccurrences),
    ("跳转到匹配括号", Cmd::GotoBracket),
    ("合并行", Cmd::JoinLines),
    ("在下方插入行", Cmd::InsertLineBelow),
    ("在上方插入行", Cmd::InsertLineAbove),
    ("复制完整路径", Cmd::CopyPath),
    ("重新打开关闭的标签", Cmd::ReopenClosedTab),
    ("每行末尾添加光标", Cmd::AddCursorLineEnds),
    ("运行任务…", Cmd::TaskRun),
    ("重新运行上次任务", Cmd::TaskRunLast),
    ("任务输出", Cmd::TaskShowOutput),
    ("停止任务", Cmd::TaskStop),
    ("插件管理…", Cmd::Extensions),
    ("运行插件命令…", Cmd::RunExtensionCommand),
    ("插件输出", Cmd::PluginOutput),
    ("重新加载插件", Cmd::ReloadExtensions),
    ("打开插件目录", Cmd::OpenExtensionDir),
    ("开始调试 / 继续", Cmd::DebugStart),
    ("切换断点", Cmd::DebugToggleBreakpoint),
    ("单步跳过", Cmd::DebugStepOver),
    ("单步进入", Cmd::DebugStepIn),
    ("单步跳出", Cmd::DebugStepOut),
    ("停止调试", Cmd::DebugStop),
    ("调试输出", Cmd::DebugShowOutput),
    ("调试变量 / 调用栈", Cmd::DebugVariables),
    ("远程：选择主机…", Cmd::RemoteSelectHost),
    ("远程：添加 SSH 主机…", Cmd::RemoteAddHost),
    ("远程：执行命令…", Cmd::RemoteRunCommand),
    ("远程：打开远端文件…", Cmd::RemoteOpenFile),
    ("远程：上传当前文件…", Cmd::RemoteUpload),
    ("分屏：左右", Cmd::SplitVertical),
    ("分屏：上下", Cmd::SplitHorizontal),
    ("关闭分屏", Cmd::CloseSplit),
    ("切换终端面板", Cmd::ToggleTerminal),
    ("切换 Vim 模式", Cmd::ToggleVim),
    ("远程：添加网络文件夹（UNC）…", Cmd::RemoteAddFolder),
    ("帮助", Cmd::Help),
];

impl super::app::App {
    // ------------------------------------------------------------ 命令入口

    pub fn execute(&mut self, cmd: Cmd) {
        if !self.config.plugins_enabled && crate::ui::app::is_plugin_cmd(cmd) {
            self.set_status("插件功能未开启：Ctrl+, 打开设置 → 插件功能");
            return;
        }
        match cmd {
            Cmd::NewFile => {
                self.tabs.push(Tab::new(Document::empty(), &self.config));
                self.active = self.tabs.len() - 1;
                self.set_status("新建文件");
            }
            Cmd::OpenPath => self.open_prompt(PromptKind::OpenPath, "打开文件", ""),
            Cmd::Save => self.save_or_prompt(),
            Cmd::SaveAs => {
                let current = self
                    .doc()
                    .path
                    .as_ref()
                    .map(|p| p.display().to_string())
                    .unwrap_or_default();
                self.open_prompt(PromptKind::SaveAs, "另存为", &current);
            }
            Cmd::SaveAll => self.save_all(),
            Cmd::CloseTab => self.request_close_active(),
            Cmd::Quit => self.request_quit_public(),
            Cmd::Undo => {
                if self.tab().excel.is_some() {
                    let changed = match &mut self.tab_mut().excel {
                        Some(book) => book.undo(),
                        None => false,
                    };
                    if changed {
                        self.doc_mut().touch_meta();
                        self.refresh_active(true);
                        self.set_status("撤销");
                    }
                } else if self.doc_mut().undo() {
                    self.set_status("撤销");
                    self.after_change();
                }
            }
            Cmd::Redo => {
                if self.tab().excel.is_some() {
                    let changed = match &mut self.tab_mut().excel {
                        Some(book) => book.redo(),
                        None => false,
                    };
                    if changed {
                        self.doc_mut().touch_meta();
                        self.refresh_active(true);
                        self.set_status("重做");
                    }
                } else if self.doc_mut().redo() {
                    self.set_status("重做");
                    self.after_change();
                }
            }
            Cmd::Cut => {
                if self.tab().is_excel() {
                    self.excel_copy(true);
                } else {
                    self.copy_selection_public(false);
                }
            }
            Cmd::Copy => {
                if self.tab().is_excel() {
                    self.excel_copy(false);
                } else {
                    self.copy_selection_public(true);
                }
            }
            Cmd::Paste => {
                if self.tab().is_excel() {
                    self.excel_paste();
                } else {
                    let text = clipboard::get_text();
                    if !text.is_empty() {
                        self.push_clip_history(&text);
                        if self.config.confirm_multiline_paste && text.contains('\n') {
                            self.pending_paste = Some(text);
                            self.overlay = Overlay::Confirm(ConfirmState {
                                title: "粘贴多行文本".into(),
                                message: "内容包含换行，可能直接执行命令。确定粘贴？".into(),
                                selected: 0,
                                action: ConfirmAction::Paste,
                            });
                        } else {
                            self.doc_mut().insert_text(&text);
                            self.after_change();
                        }
                    }
                }
            }
            Cmd::SelectAll => {
                if self.tab().is_excel() {
                    self.excel_select_all();
                } else {
                    self.doc_mut().select_all();
                    self.ensure_visible();
                }
            }
            Cmd::SelectLine => {
                let line = self.doc().primary().pos.line;
                self.doc_mut().select_line(line);
                self.ensure_visible();
            }
            Cmd::SelectNextOccurrence => {
                if self.doc_mut().select_next_occurrence() {
                    self.ensure_visible();
                }
            }
            Cmd::DuplicateLine => {
                self.doc_mut().duplicate_lines();
                self.after_change();
            }
            Cmd::DeleteLine => {
                self.doc_mut().delete_lines();
                self.after_change();
            }
            Cmd::MoveLineUp => {
                self.doc_mut().move_lines(true);
                self.after_change();
            }
            Cmd::MoveLineDown => {
                self.doc_mut().move_lines(false);
                self.after_change();
            }
            Cmd::AddCursorUp => self.add_cursor_line(-1),
            Cmd::AddCursorDown => self.add_cursor_line(1),
            Cmd::ToggleComment => {
                let prefix = crate::core::highlight::comment_prefix(self.doc().language).to_string();
                self.doc_mut().toggle_comment(&prefix);
                self.after_change();
            }
            Cmd::Indent => {
                let width = self.config.tab_width;
                let spaces = self.config.use_spaces;
                self.doc_mut().indent(false, width, spaces);
                self.after_change();
            }
            Cmd::Outdent => {
                let width = self.config.tab_width;
                let spaces = self.config.use_spaces;
                self.doc_mut().indent(true, width, spaces);
                self.after_change();
            }
            Cmd::SortAsc => {
                self.doc_mut().transform_lines(|mut lines| {
                    lines.sort_by(|a, b| a.to_lowercase().cmp(&b.to_lowercase()));
                    lines
                });
                self.after_change();
            }
            Cmd::SortDesc => {
                self.doc_mut().transform_lines(|mut lines| {
                    lines.sort_by(|a, b| b.to_lowercase().cmp(&a.to_lowercase()));
                    lines
                });
                self.after_change();
            }
            Cmd::Dedup => {
                let mut seen = std::collections::HashSet::new();
                self.doc_mut().transform_lines(|lines| {
                    lines
                        .into_iter()
                        .filter(|line| seen.insert(line.clone()))
                        .collect()
                });
                self.after_change();
            }
            Cmd::Upper => {
                self.doc_mut()
                    .transform_lines(|lines| lines.into_iter().map(|l| l.to_uppercase()).collect());
                self.after_change();
            }
            Cmd::Lower => {
                self.doc_mut()
                    .transform_lines(|lines| lines.into_iter().map(|l| l.to_lowercase()).collect());
                self.after_change();
            }
            Cmd::Find => self.open_find(false),
            Cmd::Replace => self.open_find(true),
            Cmd::FindNext => self.find_next(true),
            Cmd::FindPrev => self.find_next(false),
            Cmd::GotoLine => {
                let current = (self.doc().primary().pos.line + 1).to_string();
                self.open_prompt(PromptKind::GotoLine, "转到行", &current);
            }
            Cmd::ToggleBookmark => {
                let line = self.doc().primary().pos.line;
                if self.doc().bookmarks.contains(&line) {
                    self.doc_mut().bookmarks.remove(&line);
                    self.set_status("已取消书签");
                } else {
                    self.doc_mut().bookmarks.insert(line);
                    self.set_status("已添加书签");
                }
            }
            Cmd::NextBookmark => self.jump_bookmark(true),
            Cmd::PrevBookmark => self.jump_bookmark(false),
            Cmd::ToggleSidebar => {
                self.config.sidebar = !self.config.sidebar;
                self.sidebar.visible = self.config.sidebar;
                self.resize(self.layout.cols, self.layout.rows);
                self.set_status(if self.config.sidebar {
                    "显示资源管理器"
                } else {
                    "隐藏资源管理器"
                });
            }
            Cmd::FocusExplorer => {
                if !self.config.sidebar {
                    self.config.sidebar = true;
                    self.sidebar.visible = true;
                    self.resize(self.layout.cols, self.layout.rows);
                }
                self.focus = Focus::Sidebar;
            }
            Cmd::QuickOpen => self.open_quick_open(),
            Cmd::Palette => self.open_palette(),
            Cmd::ToggleWrap => {
                self.config.wrap = !self.config.wrap;
                self.resize(self.layout.cols, self.layout.rows);
                self.set_status(if self.config.wrap {
                    "自动换行：开"
                } else {
                    "自动换行：关"
                });
            }
            Cmd::ToggleMinimap => {
                self.config.minimap = !self.config.minimap;
                self.resize(self.layout.cols, self.layout.rows);
                self.set_status(if self.config.minimap {
                    "小地图：开"
                } else {
                    "小地图：关"
                });
            }
            Cmd::ToggleAutosave => {
                self.config.autosave = !self.config.autosave;
                self.set_status(if self.config.autosave {
                    "自动保存：开（停止输入 2 秒后保存）"
                } else {
                    "自动保存：关"
                });
            }
            Cmd::ToggleStickyScroll => {
                self.config.sticky_scroll = !self.config.sticky_scroll;
                self.set_status(if self.config.sticky_scroll {
                    "粘性滚动：开"
                } else {
                    "粘性滚动：关"
                });
            }
            Cmd::FoldBlock => {
                let line = self.doc().primary().pos.line;
                self.tab_mut().folds.toggle(line);
                self.refresh_active(true);
                self.ensure_visible();
            }
            Cmd::FoldAll => {
                self.tab_mut().folds.collapse_all();
                self.refresh_active(true);
                self.ensure_visible();
            }
            Cmd::UnfoldAll => {
                self.tab_mut().folds.expand_all();
                self.refresh_active(true);
                self.ensure_visible();
            }
            Cmd::ToggleWhitespace => {
                self.show_whitespace = !self.show_whitespace;
                self.config.show_whitespace = self.show_whitespace;
                self.set_status(if self.show_whitespace {
                    "显示空白字符"
                } else {
                    "隐藏空白字符"
                });
            }
            Cmd::Help => {
                self.help_open = !self.help_open;
            }
            Cmd::ThemePicker => self.open_theme_picker(),
            Cmd::LanguagePicker => self.open_language_picker(),
            Cmd::EncodingPicker => self.open_encoding_picker(),
            Cmd::EolPicker => self.open_eol_picker(),
            Cmd::SnippetPicker => self.open_snippet_picker(),
            Cmd::Outline => self.open_outline(),
            Cmd::Problems => self.open_problems(),
            Cmd::CompareFile => {
                let path = self
                    .doc()
                    .path
                    .as_ref()
                    .map(|p| p.display().to_string())
                    .unwrap_or_default();
                self.open_prompt(PromptKind::CompareFile, "与文件比较（输入路径）", &path);
            }
            Cmd::NewWordDoc => {
                let doc = Document::from_text("", None);
                let mut tab = Tab::new(doc, &self.config);
                tab.word = Some(crate::docx::WordDoc::create());
                tab.word_styles = vec![crate::docx::Flags::default()];
                self.tabs.push(tab);
                self.active = self.tabs.len() - 1;
                self.set_status("新建 Word 文档（Ctrl+S 保存为 .docx）");
            }
            Cmd::NewExcelDoc => {
                let mut doc = Document::empty();
                doc.read_only = true;
                let mut tab = Tab::new(doc, &self.config);
                tab.excel = Some(crate::xlsx::Workbook::create());
                self.tabs.push(tab);
                self.active = self.tabs.len() - 1;
                self.set_status("新建 Excel 表格（Ctrl+S 保存为 .xlsx）");
            }
            Cmd::ToggleBold => self.word_style(crate::docx::Style::Bold),
            Cmd::ToggleItalic => self.word_style(crate::docx::Style::Italic),
            Cmd::ToggleUnderline => self.word_style(crate::docx::Style::Underline),
            Cmd::CycleFontColor => self.word_style(crate::docx::Style::ColorNext),
            Cmd::GitStatus => self.git_show_status(),
            Cmd::GitDiff => self.git_show_diff(),
            Cmd::GitLog => self.git_show_log(),
            Cmd::GitCommit => self.git_commit_prompt(),
            Cmd::GitStage => self.git_set_stage(true),
            Cmd::GitUnstage => self.git_set_stage(false),
            Cmd::GitStageAll => self.git_stage_all(true),
            Cmd::GitUnstageAll => self.git_stage_all(false),
            Cmd::GitDiscard => self.git_discard_selected(),
            Cmd::GitBranches => self.git_branch_picker(),
            Cmd::GitBlame => self.git_blame_current(),
            Cmd::GitPull => self.git_simple_action("拉取", crate::vcs::git::pull),
            Cmd::GitPush => self.git_simple_action("推送", crate::vcs::git::push),
            Cmd::GitFetch => self.git_simple_action("获取远程", crate::vcs::git::fetch),
            Cmd::GitStash => self.git_simple_action("暂存改动", crate::vcs::git::stash_push),
            Cmd::GitStashPop => self.git_simple_action("恢复 stash", crate::vcs::git::stash_pop),
            Cmd::GitBranchCreate => {
                self.open_prompt(PromptKind::GitBranchCreate, "新建分支", "")
            }
            Cmd::GitBranchDelete => {
                self.open_prompt(PromptKind::GitBranchDelete, "删除分支", "")
            }
            Cmd::GitMerge => self.open_prompt(PromptKind::GitMerge, "合并分支", ""),
            Cmd::LspDefinition => self.lsp_goto_definition(),
            Cmd::LspPeekDefinition => self.lsp_peek_definition(),
            Cmd::LspComplete => self.lsp_open_completion(),
            Cmd::LspHover => self.lsp_hover(),
            Cmd::LspReferences => self.lsp_references(),
            Cmd::LspSymbols => self.open_prompt(PromptKind::LspSymbolQuery, "工作区符号", ""),
            Cmd::LspRename => self.lsp_rename_prompt(),
            Cmd::LspFormat => self.lsp_format_document(),
            Cmd::LspSignature => self.lsp_signature_help(true),
            Cmd::LspCodeAction => self.lsp_code_actions(),
            Cmd::ToggleLspAutoComplete => {
                self.config.lsp_auto_complete = !self.config.lsp_auto_complete;
                self.pending_complete = None;
                self.set_status(if self.config.lsp_auto_complete {
                    "输入自动补全：开（需语言服务器已连接）"
                } else {
                    "输入自动补全：关"
                });
            }
            Cmd::ToggleLspSignature => {
                self.config.lsp_signature_help = !self.config.lsp_signature_help;
                if !self.config.lsp_signature_help {
                    self.signature_help = None;
                }
                self.set_status(if self.config.lsp_signature_help {
                    "签名帮助：开（输入 ( 或 , 时显示）"
                } else {
                    "签名帮助：关"
                });
            }
            Cmd::ToggleLspInlayHints => {
                self.config.lsp_inlay_hints = !self.config.lsp_inlay_hints;
                if !self.config.lsp_inlay_hints {
                    self.inlay_hints.clear();
                    self.lsp_hints_key = None;
                }
                self.set_status(if self.config.lsp_inlay_hints {
                    "内联提示：开"
                } else {
                    "内联提示：关"
                });
            }
            Cmd::WorkspaceSearch => self.workspace_focus(),
            Cmd::WorkspaceReplace => {
                if self.workspace_query.trim().is_empty() {
                    self.workspace_focus();
                    self.set_status("请先在搜索面板输入内容，再执行工程替换");
                } else {
                    self.open_prompt(PromptKind::WorkspaceReplace, "工程替换为", "");
                }
            }
            Cmd::WorkspaceInclude => {
                let initial = self.config.workspace_include.clone();
                self.open_prompt(PromptKind::WorkspaceInclude, "包含文件（glob）", &initial);
            }
            Cmd::WorkspaceExclude => {
                let initial = self.config.workspace_exclude.clone();
                self.open_prompt(PromptKind::WorkspaceExclude, "排除文件（glob）", &initial);
            }
            Cmd::WorkspaceToggleIgnore => {
                self.config.workspace_ignore = !self.config.workspace_ignore;
                self.refresh_workspace_options();
                let state = if self.config.workspace_ignore {
                    "工程搜索将遵循 .gitignore"
                } else {
                    "工程搜索将忽略 .gitignore（搜索全部文件）"
                };
                self.set_status(state);
            }
            Cmd::WorkspaceAddFolder => {
                let initial = self
                    .sidebar
                    .entries
                    .get(self.sidebar.selected)
                    .map(|e| e.path.display().to_string())
                    .unwrap_or_else(|| self.cwd.display().to_string());
                self.open_prompt(PromptKind::AddFolder, "添加文件夹到工作区", &initial);
            }
            Cmd::WorkspaceRemoveFolder => {
                let path = self
                    .sidebar
                    .entries
                    .get(self.sidebar.selected)
                    .map(|e| e.path.clone());
                match path {
                    Some(p) if self.sidebar.is_root(&p) => {
                        if self.sidebar.remove_root(&p) {
                            self.config.workspace_folders = self.sidebar.roots.clone();
                            self.quick_files.clear();
                            self.set_status(format!("已移除工作区文件夹 {}", p.display()));
                        } else {
                            self.set_error("至少保留一个工作区文件夹");
                        }
                    }
                    _ => self.set_error("请在资源管理器中选中一个工作区根目录"),
                }
            }
            Cmd::ExplorerNewFile => self.explorer_new(true),
            Cmd::ExplorerNewFolder => self.explorer_new(false),
            Cmd::ExplorerRename => self.explorer_rename_prompt(),
            Cmd::ExplorerDelete => self.explorer_delete(),
            Cmd::ExplorerRefresh => {
                self.sidebar.refresh(self.config.show_hidden);
                self.set_status("资源管理器已刷新");
            }
            Cmd::ExcelBold => self.excel_format(crate::xlsx::styles::FormatAction::Bold, "加粗"),
            Cmd::ExcelItalic => {
                self.excel_format(crate::xlsx::styles::FormatAction::Italic, "斜体")
            }
            Cmd::ExcelUnderline => {
                self.excel_format(crate::xlsx::styles::FormatAction::Underline, "下划线")
            }
            Cmd::ExcelFontSize => self.excel_font_size_picker(),
            Cmd::ExcelFontColor => self.excel_font_color_picker(),
            Cmd::ExcelFillColor => self.excel_fill_picker(),
            Cmd::ExcelNumberFormat => self.excel_number_picker(),
            Cmd::ExcelAlignLeft => self.excel_format(
                crate::xlsx::styles::FormatAction::HAlign("left".into()),
                "左对齐",
            ),
            Cmd::ExcelAlignCenter => self.excel_format(
                crate::xlsx::styles::FormatAction::HAlign("center".into()),
                "居中",
            ),
            Cmd::ExcelAlignRight => self.excel_format(
                crate::xlsx::styles::FormatAction::HAlign("right".into()),
                "右对齐",
            ),
            Cmd::ExcelBorder => {
                self.excel_format(crate::xlsx::styles::FormatAction::BorderAll, "框线")
            }
            Cmd::ExcelClearBorder => {
                self.excel_format(crate::xlsx::styles::FormatAction::ClearBorder, "清除框线")
            }
            Cmd::ExcelMerge => self.excel_merge(),
            Cmd::ExcelUnmerge => self.excel_unmerge(),
            Cmd::ExcelFreeze => self.excel_toggle_freeze(),
            Cmd::ExcelFilter => self.excel_filter_prompt(),
            Cmd::ExcelClearFilter => self.excel_clear_filter(),
            Cmd::ExcelSortAsc => self.excel_sort(true),
            Cmd::ExcelSortDesc => self.excel_sort(false),
            Cmd::ExcelInsertRow => self.excel_insert_line(true, false),
            Cmd::ExcelDeleteRow => self.excel_insert_line(true, true),
            Cmd::ExcelInsertCol => self.excel_insert_line(false, false),
            Cmd::ExcelDeleteCol => self.excel_insert_line(false, true),
            Cmd::ExcelSheetAdd => self.excel_sheet_add(),
            Cmd::ExcelSheetRename => self.excel_sheet_rename(),
            Cmd::ExcelSheetDelete => self.excel_sheet_delete(),
            Cmd::ExcelSheetNext => self.excel_sheet_switch(1),
            Cmd::ExcelSheetPrev => self.excel_sheet_switch(-1),
            Cmd::ExcelClear => self.excel_clear(),
            Cmd::ExcelCopy => self.excel_copy(false),
            Cmd::ExcelCut => self.excel_copy(true),
            Cmd::ExcelPaste => self.excel_paste(),
            Cmd::ExcelSelectAll => self.excel_select_all(),
            Cmd::OpenImage => {
                self.open_prompt(PromptKind::OpenPath, "打开图片", "");
            }
            Cmd::ToggleZen => {
                self.zen = !self.zen;
                if self.zen {
                    self.zen_restore = (self.config.sidebar, self.config.minimap);
                    self.config.sidebar = false;
                    self.config.minimap = false;
                    self.set_status("专注模式：Ctrl+Alt+Z 或再次执行退出");
                } else {
                    self.config.sidebar = self.zen_restore.0;
                    self.config.minimap = self.zen_restore.1;
                    self.set_status("已退出专注模式");
                }
                self.resize(self.layout.cols, self.layout.rows);
            }
            Cmd::ToggleRainbow => {
                self.config.rainbow_brackets = !self.config.rainbow_brackets;
                self.set_status(if self.config.rainbow_brackets {
                    "彩虹括号：开"
                } else {
                    "彩虹括号：关"
                });
            }
            Cmd::ToggleCentered => {
                self.config.centered = !self.config.centered;
                self.resize(self.layout.cols, self.layout.rows);
                self.set_status(if self.config.centered {
                    "居中布局：开"
                } else {
                    "居中布局：关"
                });
            }
            Cmd::ToggleLayout => {
                let next = if LayoutStyle::from_config(&self.config.layout) == LayoutStyle::Vscode {
                    "sqlmux"
                } else {
                    "vscode"
                };
                self.config.layout = next.to_string();
                self.resize(self.layout.cols, self.layout.rows);
                self.set_status(format!("界面布局：{next}"));
            }
            Cmd::OpenSettings => self.open_settings(),
            Cmd::ClipboardHistory => self.open_clipboard_history(),
            Cmd::SelectAllOccurrences => {
                if self.doc_mut().select_all_occurrences() {
                    self.ensure_visible();
                    self.set_status("已选中所有相同出现");
                } else {
                    self.set_status("光标处没有可匹配的词");
                }
            }
            Cmd::GotoBracket => {
                if !self.doc_mut().goto_bracket() {
                    self.set_status("光标处没有可匹配的括号");
                }
                self.ensure_visible();
            }
            Cmd::JoinLines => {
                if self.doc_mut().join_lines() {
                    self.after_change();
                } else {
                    self.set_status("已是最后一行");
                }
            }
            Cmd::InsertLineBelow => {
                self.doc_mut().insert_line_below();
                self.after_change();
            }
            Cmd::InsertLineAbove => {
                self.doc_mut().insert_line_above();
                self.after_change();
            }
            Cmd::CopyPath => {
                match self.doc().path.clone() {
                    Some(path) => match clipboard::set_text(&path.display().to_string()) {
                        Ok(()) => self.set_status(format!("已复制路径 {}", path.display())),
                        Err(e) => self.set_error(e),
                    },
                    None => self.set_error("当前文件尚未保存，没有路径"),
                }
            }
            Cmd::ReopenClosedTab => {
                if let Some(entry) = self.closed_tabs.first().cloned() {
                    self.closed_tabs.remove(0);
                    let reopened = match &entry.path {
                        Some(path) if path.exists() => self.open_file(path).is_ok(),
                        _ => false,
                    };
                    if !reopened {
                        let mut doc = Document::from_text(&entry.text, entry.path.clone());
                        doc.set_cursor(entry.cursor);
                        let mut tab = Tab::new(doc, &self.config);
                        tab.preview = entry.preview;
                        self.tabs.push(tab);
                        self.active = self.tabs.len() - 1;
                    }
                    self.set_status(format!("已重新打开 {}", entry.title));
                } else {
                    self.set_status("没有可重新打开的标签页");
                }
            }
            Cmd::AddCursorLineEnds => {
                self.doc_mut().add_cursors_at_line_ends();
                self.ensure_visible();
                self.set_status("已在每行末尾添加光标");
            }
            Cmd::TaskRun => self.open_task_list(),
            Cmd::TaskRunLast => {
                if let Some(task) = self.task_last.clone() {
                    self.start_task(task);
                } else {
                    self.open_task_list();
                }
            }
            Cmd::TaskShowOutput => self.open_task_output(),
            Cmd::TaskStop => {
                if let Some(run) = self.task_run.as_mut() {
                    run.stop();
                    self.set_status("任务已停止");
                } else {
                    self.set_status("没有正在运行的任务");
                }
            }
            Cmd::Extensions => self.open_extensions(),
            Cmd::ReloadExtensions => {
                self.reload_extensions();
                self.reload_plugins();
                let (names, snippets) =
                    crate::extension::register_contributions(&self.extensions);
                self.plugin_theme_names = names;
                self.set_status(format!(
                    "已加载 {} 个插件（{} 个主题、{} 个片段）",
                    self.extensions.len(),
                    self.plugin_theme_names.len(),
                    snippets
                ));
            }
            Cmd::OpenExtensionDir => self.open_extension_dir(),
            Cmd::RunExtensionCommand => self.open_extension_commands(),
            Cmd::PluginOutput => self.open_plugin_output(),
            Cmd::DebugStart => self.debug_start(),
            Cmd::DebugContinue => {
                if self.debug.is_active() {
                    self.debug.continue_run();
                    self.set_status("继续执行");
                } else {
                    self.debug_start();
                }
            }
            Cmd::DebugStepOver => self.debug_step("next", "单步跳过"),
            Cmd::DebugStepIn => self.debug_step("stepIn", "单步进入"),
            Cmd::DebugStepOut => self.debug_step("stepOut", "单步跳出"),
            Cmd::DebugToggleBreakpoint => self.debug_toggle_breakpoint(),
            Cmd::DebugStop => {
                if self.debug.is_active() {
                    self.debug.shutdown();
                    self.set_status("调试已停止");
                } else {
                    self.set_status("没有调试会话");
                }
            }
            Cmd::DebugShowOutput => self.open_debug_output(),
            Cmd::DebugVariables => self.open_debug_vars(),
            Cmd::RemoteAddFolder => self.open_prompt(
                PromptKind::AddFolder,
                "添加网络文件夹（\\\\server\\share）",
                "",
            ),
            Cmd::RemoteSelectHost => self.open_remote_hosts(),
            Cmd::RemoteAddHost => self.open_prompt(
                PromptKind::RemoteHostAdd,
                "添加 SSH 主机（名称=user@host:端口）",
                "",
            ),
            Cmd::RemoteRunCommand => {
                if self.remote.active_host().is_none() {
                    self.set_error("尚未配置远程主机：在 config.ini 添加 remote.<名称> = user@host");
                } else {
                    self.open_prompt(PromptKind::RemoteCommand, "远程命令（在远端默认目录执行）", "");
                }
            }
            Cmd::RemoteOpenFile => {
                if self.remote.active_host().is_none() {
                    self.set_error("尚未配置远程主机：在 config.ini 添加 remote.<名称> = user@host");
                } else {
                    self.open_prompt(PromptKind::RemoteFileOpen, "远端文件路径（scp 下载后编辑）", "");
                }
            }
            Cmd::RemoteUpload => {
                if self.doc().path.is_none() {
                    self.set_error("当前文件尚未保存");
                } else if self.remote.active_host().is_none() {
                    self.set_error("尚未配置远程主机");
                } else {
                    let initial = self
                        .doc()
                        .path
                        .as_ref()
                        .and_then(|path| self.remote.mapping_for(path))
                        .map(|(_, remote)| remote)
                        .unwrap_or_default();
                    self.open_prompt(PromptKind::RemoteUploadPath, "上传到远端路径", &initial);
                }
            }
            Cmd::SplitVertical => self.split_editor(true),
            Cmd::SplitHorizontal => self.split_editor(false),
            Cmd::CloseSplit => self.close_split(),
            Cmd::MoveTabToOtherGroup => {
                if self.split.is_none() {
                    self.split_editor(true);
                } else if self.groups.len() >= 2 {
                    let other = 1 - self.group.min(1);
                    self.groups[other] = self.active;
                    self.group = other;
                    self.ensure_visible();
                    self.set_status("标签已移动到另一组");
                }
            }
            Cmd::ToggleTerminal => self.toggle_terminal(),
            Cmd::ToggleVim => {
                self.config.vim = !self.config.vim;
                if !self.config.vim {
                    // 关闭时回到普通插入状态，避免卡在普通模式。
                    self.vim = crate::core::vim::Vim::new();
                    self.vim.mode = crate::core::vim::Mode::Insert;
                } else {
                    self.vim = crate::core::vim::Vim::new();
                }
                self.set_status(if self.config.vim {
                    "Vim 模式已开启（Esc 回普通模式）"
                } else {
                    "Vim 模式已关闭"
                });
            }
        }
        self.ensure_visible();
    }

    fn after_change(&mut self) {
        self.cursor_visible = true;
        self.ensure_visible();
        self.refresh_active(false);
    }

    /// Word 文字样式：作用于选中行（没有选区则当前行）。
    fn word_style(&mut self, style: crate::docx::Style) {
        if self.tab().word.is_none() {
            self.set_error("文字样式只对 Word 文档生效");
            return;
        }
        let (start, end) = {
            let cursor = self.doc().primary();
            let (from, to) = cursor
                .selection()
                .unwrap_or((cursor.pos, cursor.pos));
            (from.line.min(to.line), from.line.max(to.line))
        };
        let count = self.doc().line_count();
        {
            let tab = self.tab_mut();
            if tab.word_styles.len() < count {
                tab.word_styles.resize(count, crate::docx::Flags::default());
            }
            for line in start..=end.min(count.saturating_sub(1)) {
                tab.word_styles[line].toggle(style);
            }
        }
        self.doc_mut().touch_meta();
        let label = match style {
            crate::docx::Style::Bold => "加粗",
            crate::docx::Style::Italic => "斜体",
            crate::docx::Style::Underline => "下划线",
            crate::docx::Style::ColorNext => "字体颜色",
        };
        self.set_status(format!("{label}：已应用到第 {}–{} 段", start + 1, end + 1));
    }

    fn request_close_active(&mut self) {
        self.request_close_tab_public(self.active);
    }

    fn save_all(&mut self) {
        for index in 0..self.tabs.len() {
            if !self.tabs[index].doc.is_dirty() {
                continue;
            }
            if self.tabs[index].doc.path.is_none() {
                self.active = index;
                self.open_prompt(PromptKind::SaveAs, "另存为", "");
                self.set_status("请先指定未命名文件的位置");
                return;
            }
            if let Err(e) = self.tabs[index].save_document() {
                self.active = index;
                self.set_error(e);
                return;
            }
            if let Some(path) = self.tabs[index].doc.path.clone() {
                self.remote_upload_if_mapped(&path);
                self.fire_plugin_event("save", &path);
            }
        }
        self.set_status("全部已保存");
    }

    pub fn save_or_prompt(&mut self) {
        if self.doc().path.is_none() {
            self.open_prompt(PromptKind::SaveAs, "另存为", "");
            return;
        }
        // 保存前格式化（语言服务器已连接时）。
        if self.config.format_on_save {
            if let Some(path) = self.doc().path.clone() {
                if self.lsp.active_for(&path) {
                    self.execute(Cmd::LspFormat);
                }
            }
        }
        match self.tab_mut().save_document() {
            Ok(()) => {
                let path = self.doc().path.clone();
                if let Some(path) = &path {
                    self.config.push_recent(path);
                    self.set_status(format!("已保存 {}", path.display()));
                }
                self.tab_mut().git_revision = 0;
                self.refresh_active(false);
                if let Some(path) = self.doc().path.clone() {
                    self.remote_upload_if_mapped(&path);
                    self.fire_plugin_event("save", &path);
                }
                if let Some(action) = self.pending_save_action.take() {
                    self.apply_confirm(action, 0);
                }
            }
            Err(e) => self.set_error(e),
        }
    }

    // ------------------------------------------------------------ 浮层构造

    pub fn open_prompt(&mut self, kind: PromptKind, title: &str, initial: &str) {
        self.overlay = Overlay::Prompt(PromptState {
            kind,
            title: title.to_string(),
            input: initial.to_string(),
            hint: match kind {
                PromptKind::SaveAs => "输入完整路径，Enter 保存，Esc 取消",
                PromptKind::OpenPath => "输入文件或目录路径，Enter 打开",
                PromptKind::NewFile => "输入新文件名，Enter 创建",
                PromptKind::GotoLine => "输入行号，Enter 跳转",
                PromptKind::CompareFile => "输入用于比较的文件路径，Enter 生成差异",
                PromptKind::GitCommit => "输入提交说明，Enter 提交",
                PromptKind::GitBranchCreate => "输入新分支名，Enter 创建并切换",
                PromptKind::GitBranchDelete => "输入要删除的分支名，Enter 确认",
                PromptKind::GitMerge => "输入要合并到当前分支的分支名，Enter 执行",
                PromptKind::ExcelSheetAdd => "输入新工作表名称，Enter 创建",
                PromptKind::ExcelSheetRename => "输入新的工作表名称，Enter 确认",
                PromptKind::ExcelFilter => {
                    "输入筛选条件（如 苹果、>100、<>0）；留空清除筛选"
                }
                PromptKind::WorkspaceReplace => {
                    "输入替换内容（支持 $1 捕获组与 \\n 等转义），Enter 替换工程内所有匹配"
                }
                PromptKind::WorkspaceInclude => {
                    "输入包含 glob（如 *.rs, src/**；逗号分隔，留空表示全部）"
                }
                PromptKind::WorkspaceExclude => {
                    "输入排除 glob（如 *.min.js, build/**；逗号分隔，留空表示不排除）"
                }
                PromptKind::AddFolder => "输入要加入工作区的文件夹路径，Enter 添加",
                PromptKind::ExplorerNewFile => "输入文件名（可含相对路径），Enter 创建并打开",
                PromptKind::ExplorerNewFolder => "输入文件夹名（可含相对路径），Enter 创建",
                PromptKind::ExplorerRename => "输入新的名称，Enter 确认",
                PromptKind::LspRename => "输入新的符号名，Enter 应用到工程内引用",
                PromptKind::LspSymbolQuery => "输入符号名（可留空搜索全部），Enter 搜索工作区",
                PromptKind::RemoteHostAdd => "名称=user@host[:端口]，例如 dev=mmm@192.0.2.10:22",
                PromptKind::RemoteCommand => "在远端默认目录执行的命令，Enter 运行并显示输出",
                PromptKind::RemoteFileOpen => "远端绝对路径，Enter 下载到本地缓存并打开",
                PromptKind::RemoteUploadPath => "远端目标路径，留空则使用已记录的路径",
                PromptKind::PluginInput => "插件请求输入，Enter 确认，Esc 取消",
            }
            .to_string(),
        });
    }

    pub fn open_list(&mut self, list: ListState) {
        self.overlay = Overlay::List(list);
    }

    fn open_palette(&mut self) {
        let plugins = self.config.plugins_enabled;
        let mut items: Vec<ListItem> = Vec::new();
        // 最近使用的命令置顶。
        for cmd in &self.recent_commands {
            if let Some((title, _)) = COMMANDS.iter().find(|(_, item)| item == cmd) {
                items.push(ListItem {
                    title: title.to_string(),
                    detail: "最近使用".into(),
                    command: Some(*cmd),
                    path: None,
                    line: None,
                    value: None,
                });
            }
        }
        for (title, cmd) in COMMANDS.iter() {
            if self.recent_commands.contains(cmd) {
                continue;
            }
            if !plugins && crate::ui::app::is_plugin_cmd(*cmd) {
                continue;
            }
            items.push(ListItem {
                title: title.to_string(),
                detail: format!("{cmd:?}"),
                command: Some(*cmd),
                path: None,
                line: None,
                value: None,
            });
        }
        if plugins {
            for (id, title, extension) in &self.plugin.commands {
                items.push(ListItem {
                    title: format!("插件：{title}"),
                    detail: extension.clone(),
                    command: None,
                    path: None,
                    line: None,
                    value: Some(format!("js\u{1}{id}")),
                });
            }
        }
        let mut list = ListState::new(ListKind::Command, "命令面板", items);
        list.query.clear();
        self.open_list(list);
    }

    /// 记录一次命令执行（命令面板的“最近使用”）。
    pub(crate) fn push_recent_command(&mut self, cmd: Cmd) {
        self.recent_commands.retain(|item| *item != cmd);
        self.recent_commands.insert(0, cmd);
        self.recent_commands.truncate(8);
    }

    fn open_quick_open(&mut self) {
        if self.quick_files.is_empty() {
            self.quick_files = collect_files_multi(&self.sidebar.roots, 6000);
        }
        let items = self
            .quick_files
            .iter()
            .map(|path| {
                let relative = path
                    .strip_prefix(&self.cwd)
                    .unwrap_or(path)
                    .to_string_lossy()
                    .replace('\\', "/");
                ListItem {
                    title: relative,
                    detail: path
                        .parent()
                        .map(|p| p.to_string_lossy().to_string())
                        .unwrap_or_default(),
                    command: None,
                    path: Some(path.clone()),
                    line: None,
                    value: None,
                }
            })
            .collect();
        let mut list = ListState::new(ListKind::QuickOpen, "快速打开", items);
        list.query.clear();
        self.open_list(list);
    }

    fn open_find(&mut self, replace: bool) {
        let selected = self
            .doc()
            .selections_text()
            .and_then(|text| text.lines().next().map(|s| s.to_string()))
            .filter(|s| !s.is_empty() && !s.contains('\n'));
        let query = selected
            .or_else(|| self.last_search.as_ref().map(|(q, _)| q.clone()))
            .unwrap_or_default();
        let options = self
            .last_search
            .as_ref()
            .map(|(_, o)| *o)
            .unwrap_or_default();
        let mut state = FindState {
            replace,
            query,
            replacement: String::new(),
            focus_query: true,
            options,
            error: None,
            matches: 0,
            current: 0,
        };
        self.update_find(&mut state);
        self.overlay = Overlay::Find(state);
    }

    fn update_find(&mut self, state: &mut FindState) {
        if state.query.is_empty() {
            state.matches = 0;
            state.error = None;
            self.search_engine = None;
            return;
        }
        let engine = SearchEngine::new(&state.query, state.options);
        if !engine.is_valid() {
            state.error = engine.error();
            state.matches = 0;
            self.search_engine = None;
            return;
        }
        state.error = None;
        let matches = engine.find_all(self.doc()).len();
        state.matches = matches;
        self.last_search = Some((state.query.clone(), state.options));
        self.search_engine = Some(engine);
    }

    fn find_next(&mut self, forward: bool) {
        let engine = match &self.search_engine {
            Some(engine) if !engine.query.is_empty() => engine.clone(),
            _ => {
                self.open_find(false);
                return;
            }
        };
        let doc = self.doc();
        let cursor = doc.primary();
        let found = if forward {
            let from = match cursor.selection() {
                Some((_, end)) => end,
                None => cursor.pos,
            };
            engine.next_match(doc, from, true)
        } else {
            let from = cursor.selection().map(|(start, _)| start).unwrap_or(cursor.pos);
            engine.prev_match(doc, from)
        };
        if let Some((start, end)) = found {
            let height = self.text_height();
            let tab = self.tab_mut();
            tab.doc.cursors = vec![crate::core::document::Cursor {
                pos: end,
                anchor: Some(start),
                goal: None,
            }];
            tab.ensure_visible(height);
            let count = self.search_count();
            self.set_status(format!("匹配 {count} 处"));
        } else {
            self.set_error("未找到匹配");
        }
    }

    fn search_count(&self) -> usize {
        self.search_engine
            .as_ref()
            .map(|e| e.find_all(self.doc()).len())
            .unwrap_or(0)
    }

    fn replace_current(&mut self, state: &FindState) {
        let Some(engine) = &self.search_engine else {
            return;
        };
        let matched = self
            .doc()
            .selections_text()
            .filter(|text| engine.find_in_line(text, 0).is_some());
        let Some(selected) = matched else {
            self.find_next(true);
            return;
        };
        // 替换串中的 $1.. 取自选区内的实际匹配；没有捕获组时 $& 回退为整个选区。
        let groups = match engine.find_in_line_captures(&selected, 0) {
            Some(item) => crate::core::search::group_texts_str(&selected, &item.groups),
            None => vec![Some(selected.clone())],
        };
        let replacement = crate::core::search::expand_replacement(&state.replacement, &groups);
        self.doc_mut().insert_text(&replacement);
        self.after_change();
        self.find_next(true);
    }

    fn replace_all(&mut self, state: &FindState) {
        let Some(engine) = &self.search_engine else {
            return;
        };
        if state.query.is_empty() {
            return;
        }
        let found = engine.find_all_with_groups(self.doc(), 20000);
        if found.is_empty() {
            self.set_error("没有可替换的匹配");
            return;
        }
        let mut edits = Vec::with_capacity(found.len());
        for (start, end, groups) in &found {
            let replacement = crate::core::search::expand_replacement(&state.replacement, groups);
            edits.push((*start, *end, replacement));
        }
        let count = edits.len();
        self.doc_mut().replace_ranges_each(&edits);
        self.after_change();
        self.set_status(format!("已替换 {count} 处"));
    }

    fn jump_bookmark(&mut self, forward: bool) {
        let bookmarks: Vec<usize> = self.doc().bookmarks.iter().copied().collect();
        if bookmarks.is_empty() {
            self.set_error("没有书签");
            return;
        }
        let current = self.doc().primary().pos.line;
        let target = if forward {
            bookmarks
                .iter()
                .find(|line| **line > current)
                .copied()
                .unwrap_or(bookmarks[0])
        } else {
            bookmarks
                .iter()
                .rev()
                .find(|line| **line < current)
                .copied()
                .unwrap_or(*bookmarks.last().unwrap())
        };
        let end = self.doc().line_end(target);
        self.doc_mut().set_cursor(Pos::new(target, end.col));
        self.ensure_visible();
    }

    fn add_cursor_line(&mut self, delta: isize) {
        let primary = self.doc().primary().pos;
        let line = (primary.line as isize + delta).max(0) as usize;
        if line >= self.doc().line_count() {
            return;
        }
        let col = primary.col.min(self.doc().line_chars(line));
        self.doc_mut().add_cursor(Pos::new(line, col));
        self.ensure_visible();
        self.set_status(format!("{} 个光标", self.doc().cursors.len()));
    }

    fn open_theme_picker(&mut self) {
        let items = crate::ui::theme::all_names()
            .iter()
            .map(|name| ListItem {
                title: name.to_string(),
                detail: if *name == self.theme.name {
                    "当前".into()
                } else {
                    String::new()
                },
                command: None,
                path: None,
                line: None,
                value: Some(name.to_string()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::Theme, "选择主题", items));
    }

    fn open_language_picker(&mut self) {
        let current = self.doc().language;
        let items = Language::all_with_custom()
            .iter()
            .map(|lang| ListItem {
                title: lang.label().to_string(),
                detail: if *lang == current {
                    "当前".into()
                } else {
                    format!("{lang:?}")
                },
                command: None,
                path: None,
                line: None,
                value: Some(lang.label().to_string()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::Language, "选择语言模式", items));
    }

    fn open_encoding_picker(&mut self) {
        let current = self.doc().encoding;
        let items = Encoding::all()
            .iter()
            .map(|enc| ListItem {
                title: enc.label().to_string(),
                detail: if *enc == current {
                    "当前".into()
                } else {
                    String::new()
                },
                command: None,
                path: None,
                line: None,
                value: Some(enc.label().to_string()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::Encoding, "选择文件编码", items));
    }

    fn open_eol_picker(&mut self) {
        let current = self.doc().eol;
        let items = Eol::all()
            .iter()
            .map(|eol| ListItem {
                title: eol.label().to_string(),
                detail: if *eol == current {
                    "当前".into()
                } else {
                    String::new()
                },
                command: None,
                path: None,
                line: None,
                value: Some(eol.label().to_string()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::Eol, "选择换行符", items));
    }

    fn open_snippet_picker(&mut self) {
        let language = self.doc().language;
        let list = snippets::list(language);
        let mut items: Vec<ListItem> = list
            .iter()
            .map(|snippet| ListItem {
                title: snippet.name.to_string(),
                detail: format!("{} 行", snippet.body.lines().count()),
                command: None,
                path: None,
                line: None,
                value: Some(snippet.body.to_string()),
            })
            .collect();
        if items.is_empty() {
            items = snippets::general()
                .iter()
                .map(|snippet| ListItem {
                    title: snippet.name.to_string(),
                    detail: format!("{} 行", snippet.body.lines().count()),
                    command: None,
                    path: None,
                    line: None,
                    value: Some(snippet.body.to_string()),
                })
                .collect();
        }
        self.open_list(ListState::new(ListKind::Snippet, "插入代码片段", items));
    }

    fn open_outline(&mut self) {
        let items = outline_items(self.doc());
        if items.is_empty() {
            self.set_error("未找到可用的符号");
            return;
        }
        self.open_list(ListState::new(ListKind::Outline, "符号大纲", items));
    }

    /// 语言服务器 + 插件上报的错误 / 警告数量（状态栏用）。
    pub fn problem_counts(&self) -> (usize, usize) {
        let mut errors = 0;
        let mut warnings = 0;
        if let Some(path) = self.doc().path.clone() {
            for diagnostic in self.lsp.diagnostics(&path) {
                match diagnostic.severity {
                    1 => errors += 1,
                    2 => warnings += 1,
                    _ => {}
                }
            }
        }
        for problem in &self.plugin.problems {
            match problem.severity {
                0 => errors += 1,
                1 => warnings += 1,
                _ => {}
            }
        }
        (errors, warnings)
    }

    fn open_problems(&mut self) {
        let mut entries: Vec<(u8, ListItem)> = Vec::new();
        for line in 0..self.doc().line_count() {
            let text = self.doc().line(line);
            if let Some((index, _)) = text.match_indices("TODO").next() {
                entries.push((
                    3,
                    ListItem {
                        title: format!("TODO: {}", text.trim()),
                        detail: format!("第 {} 行 · 第 {} 列", line + 1, index + 1),
                        command: None,
                        path: None,
                        line: Some(line),
                        value: None,
                    },
                ));
            } else if let Some((index, _)) = text.match_indices("FIXME").next() {
                entries.push((
                    3,
                    ListItem {
                        title: format!("FIXME: {}", text.trim()),
                        detail: format!("第 {} 行 · 第 {} 列", line + 1, index + 1),
                        command: None,
                        path: None,
                        line: Some(line),
                        value: None,
                    },
                ));
            } else if text.len() != text.trim_end().len() {
                entries.push((
                    4,
                    ListItem {
                        title: format!("行尾空白：{}", text.trim()),
                        detail: format!("第 {} 行", line + 1),
                        command: None,
                        path: None,
                        line: Some(line),
                        value: None,
                    },
                ));
            }
        }
        // 语言服务器诊断
        if let Some(path) = self.doc().path.clone() {
            for diagnostic in self.lsp.diagnostics(&path) {
                let label = match diagnostic.severity {
                    1 => "错误",
                    2 => "警告",
                    3 => "信息",
                    _ => "提示",
                };
                entries.push((
                    diagnostic.severity.clamp(1, 4) as u8,
                    ListItem {
                        title: format!("{label}：{}", diagnostic.message),
                        detail: format!(
                            "第 {} 行 · 第 {} 列",
                            diagnostic.line + 1,
                            diagnostic.col + 1
                        ),
                        command: None,
                        path: None,
                        line: Some(diagnostic.line),
                        value: None,
                    },
                ));
            }
        }
        // 插件问题
        for problem in &self.plugin.problems {
            let (severity, label) = match problem.severity {
                0 => (1u8, "错误"),
                1 => (2, "警告"),
                2 => (3, "信息"),
                _ => (4, "提示"),
            };
            entries.push((
                severity,
                ListItem {
                    title: format!("{label}：{}", problem.message),
                    detail: format!(
                        "{} · 第 {} 行",
                        problem.path.display(),
                        problem.line + 1
                    ),
                    command: None,
                    path: Some(problem.path.clone()),
                    line: Some(problem.line),
                    value: None,
                },
            ));
        }
        let (errors, warnings) = self.problem_counts();
        let filter = self.problems_filter;
        let mut items: Vec<ListItem> = entries
            .into_iter()
            .filter(|(severity, _)| filter == 0 || *severity == filter)
            .map(|(_, item)| item)
            .collect();
        if items.is_empty() {
            items.push(ListItem::plain("没有匹配的问题"));
        }
        let name = match filter {
            1 => "问题：错误",
            2 => "问题：警告",
            3 => "问题：信息",
            4 => "问题：提示",
            _ => "问题",
        };
        let title = format!("{name}（{errors} 错误 / {warnings} 警告）");
        self.open_list(ListState::new(ListKind::Problems, &title, items));
    }

    // ------------------------------------------------------------ 浮层按键

    pub fn handle_overlay_key(&mut self, key: Key) {
        let overlay = std::mem::replace(&mut self.overlay, Overlay::None);
        match overlay {
            Overlay::None => {}
            Overlay::Menu(mut state) => {
                use KeyCode::*;
                match key.code {
                    Esc => {}
                    Left => {
                        let len = self.menus().len().max(1);
                        state.index = if state.index == 0 {
                            len - 1
                        } else {
                            state.index - 1
                        };
                        state.selected = 0;
                        self.overlay = Overlay::Menu(state);
                    }
                    Right => {
                        let len = self.menus().len().max(1);
                        state.index = (state.index + 1) % len;
                        state.selected = 0;
                        self.overlay = Overlay::Menu(state);
                    }
                    Up => {
                        let len = self
                            .menus()
                            .get(state.index)
                            .map(|menu| menu.items.len())
                            .unwrap_or(0);
                        if len > 0 {
                            state.selected = if state.selected == 0 {
                                len - 1
                            } else {
                                state.selected - 1
                            };
                        }
                        self.overlay = Overlay::Menu(state);
                    }
                    Down => {
                        let len = self
                            .menus()
                            .get(state.index)
                            .map(|menu| menu.items.len())
                            .unwrap_or(0);
                        if len > 0 {
                            state.selected = (state.selected + 1) % len;
                        }
                        self.overlay = Overlay::Menu(state);
                    }
                    Enter => {
                        let cmd = self
                            .menus()
                            .get(state.index)
                            .and_then(|menu| menu.items.get(state.selected))
                            .map(|item| item.cmd);
                        if let Some(cmd) = cmd {
                            self.execute(cmd);
                        }
                    }
                    _ => {
                        self.overlay = Overlay::Menu(state);
                    }
                }
            }
            Overlay::Keys(_) => {
                use KeyCode::*;
                if key.code == Esc || key.code == F(1) {
                    // 关闭
                } else if let Some(hint) = crate::ui::app::KEY_HINTS
                    .iter()
                    .find(|hint| hint.matches(&key))
                {
                    self.execute(hint.cmd);
                }
            }
            Overlay::Context(mut state) => {
                use KeyCode::*;
                match key.code {
                    Esc => {}
                    Up => {
                        state.selected = state.selected.saturating_sub(1);
                        self.overlay = Overlay::Context(state);
                    }
                    Down => {
                        if !state.items.is_empty() {
                            state.selected =
                                (state.selected + 1).min(state.items.len() - 1);
                        }
                        self.overlay = Overlay::Context(state);
                    }
                    Enter => {
                        if let Some(item) = state.items.get(state.selected) {
                            let cmd = item.cmd;
                            self.execute(cmd);
                        }
                    }
                    _ => self.overlay = Overlay::Context(state),
                }
            }
            Overlay::Cmdline(mut state) => {
                use KeyCode::*;
                match key.code {
                    Esc => {
                        self.vim.mode = crate::core::vim::Mode::Normal;
                    }
                    Enter => {
                        let text = state.input.clone();
                        let prefix = state.prefix;
                        if prefix == ':' {
                            self.exec_ex(&text);
                        } else if !text.is_empty() {
                            let forward = prefix == '/';
                            self.vim.last_search = Some((text.clone(), forward));
                            self.search_from_cursor(&text, forward);
                            self.vim.mode = crate::core::vim::Mode::Normal;
                        } else {
                            self.vim.mode = crate::core::vim::Mode::Normal;
                        }
                    }
                    Backspace => {
                        state.input.pop();
                        self.overlay = Overlay::Cmdline(state);
                    }
                    Up => {
                        let history = state.history.clone();
                        if !history.is_empty() {
                            let index = state
                                .index
                                .map(|i| i + 1)
                                .unwrap_or(0)
                                .min(history.len() - 1);
                            state.input = history[index].clone();
                            state.index = Some(index);
                        }
                        self.overlay = Overlay::Cmdline(state);
                    }
                    Down => {
                        let history = state.history.clone();
                        match state.index {
                            Some(0) => {
                                state.input.clear();
                                state.index = None;
                            }
                            Some(index) => {
                                state.input = history[index - 1].clone();
                                state.index = Some(index - 1);
                            }
                            None => {}
                        }
                        self.overlay = Overlay::Cmdline(state);
                    }
                    Char(c) if !key.mods.ctrl && !key.mods.alt => {
                        state.input.push(c);
                        self.overlay = Overlay::Cmdline(state);
                    }
                    _ => self.overlay = Overlay::Cmdline(state),
                }
            }
            Overlay::List(mut state) => {
                use KeyCode::*;
                match key.code {
                    Esc => {
                        if state.kind == ListKind::PluginChoice {
                            if let Some((id, _)) = self.plugin_pending.take() {
                                let _ = self.plugin.resolve(id, "null");
                                self.process_plugin_requests();
                            }
                        }
                    }
                    Up => {
                        state.move_selection(-1);
                        self.overlay = Overlay::List(state);
                    }
                    Down => {
                        state.move_selection(1);
                        self.overlay = Overlay::List(state);
                    }
                    PageUp => {
                        state.move_selection(-10);
                        self.overlay = Overlay::List(state);
                    }
                    PageDown => {
                        state.move_selection(10);
                        self.overlay = Overlay::List(state);
                    }
                    Tab if state.kind == ListKind::Problems => {
                        self.problems_filter = (self.problems_filter + 1) % 5;
                        self.open_problems();
                        return;
                    }
                    Enter => {
                        let item = state.current().cloned();
                        if let Some(item) = item {
                            self.activate_list_item(&state.kind, item);
                        }
                    }
                    Backspace => {
                        state.query.pop();
                        state.refilter();
                        self.overlay = Overlay::List(state);
                    }
                    Char('v') if key.mods == Mods::ctrl() => {
                        state.query.push_str(&clipboard::get_text());
                        state.refilter();
                        self.overlay = Overlay::List(state);
                    }
                    Char(ch) if !key.mods.ctrl && !key.mods.alt => {
                        // 命令面板 / 快速打开的 VSCode 前缀路由。
                        if state.query.is_empty()
                            && matches!(state.kind, ListKind::Command | ListKind::QuickOpen)
                        {
                            match ch {
                                '>' => {
                                    self.open_palette();
                                    if let Overlay::List(list) = &mut self.overlay {
                                        list.query.push('>');
                                    }
                                    return;
                                }
                                '@' => {
                                    self.open_outline();
                                    if let Overlay::List(list) = &mut self.overlay {
                                        list.query.push('@');
                                    }
                                    return;
                                }
                                '#' => {
                                    self.lsp_workspace_symbols("");
                                    return;
                                }
                                ':' => {
                                    self.execute(Cmd::GotoLine);
                                    return;
                                }
                                _ => {}
                            }
                        }
                        state.query.push(ch);
                        state.refilter();
                        self.overlay = Overlay::List(state);
                    }
                    _ => {
                        self.overlay = Overlay::List(state);
                    }
                }
            }
            Overlay::Find(mut state) => {
                use KeyCode::*;
                match key.code {
                    Esc => {}
                    Tab if state.replace => {
                        state.focus_query = !state.focus_query;
                        self.overlay = Overlay::Find(state);
                    }
                    Enter if key.mods.alt => {
                        self.replace_all(&state);
                        self.update_find(&mut state);
                        self.overlay = Overlay::Find(state);
                    }
                    Enter => {
                        if state.replace && !state.focus_query {
                            self.replace_current(&state);
                        } else {
                            self.find_next(true);
                        }
                        self.update_find(&mut state);
                        self.overlay = Overlay::Find(state);
                    }
                    Up => {
                        self.find_next(false);
                        self.overlay = Overlay::Find(state);
                    }
                    Down => {
                        self.find_next(true);
                        self.overlay = Overlay::Find(state);
                    }
                    Backspace => {
                        if state.focus_query {
                            state.query.pop();
                        } else {
                            state.replacement.pop();
                        }
                        self.update_find(&mut state);
                        self.overlay = Overlay::Find(state);
                    }
                    Char('v') if key.mods == Mods::ctrl() => {
                        let text = clipboard::get_text();
                        if state.focus_query {
                            state.query.push_str(&text);
                        } else {
                            state.replacement.push_str(&text);
                        }
                        self.update_find(&mut state);
                        self.overlay = Overlay::Find(state);
                    }
                    Char('c') if key.mods.alt => {
                        state.options.case_sensitive = !state.options.case_sensitive;
                        self.update_find(&mut state);
                        self.overlay = Overlay::Find(state);
                    }
                    Char('w') if key.mods.alt => {
                        state.options.whole_word = !state.options.whole_word;
                        self.update_find(&mut state);
                        self.overlay = Overlay::Find(state);
                    }
                    Char('r') if key.mods.alt => {
                        state.options.regex = !state.options.regex;
                        self.update_find(&mut state);
                        self.overlay = Overlay::Find(state);
                    }
                    Char(ch) if !key.mods.ctrl && !key.mods.alt => {
                        if state.focus_query {
                            state.query.push(ch);
                        } else {
                            state.replacement.push(ch);
                        }
                        self.update_find(&mut state);
                        self.overlay = Overlay::Find(state);
                    }
                    _ => {
                        self.overlay = Overlay::Find(state);
                    }
                }
            }
            Overlay::Prompt(mut state) => {
                use KeyCode::*;
                match key.code {
                    Esc => {
                        if matches!(state.kind, PromptKind::PluginInput) {
                            if let Some((id, _)) = self.plugin_pending.take() {
                                let _ = self.plugin.resolve(id, "null");
                                self.process_plugin_requests();
                            }
                        }
                    }
                    Enter => self.submit_prompt(state),
                    Backspace => {
                        state.input.pop();
                        self.overlay = Overlay::Prompt(state);
                    }
                    Char('v') if key.mods == Mods::ctrl() => {
                        state.input.push_str(&clipboard::get_text());
                        self.overlay = Overlay::Prompt(state);
                    }
                    Char(ch) if !key.mods.ctrl && !key.mods.alt => {
                        state.input.push(ch);
                        self.overlay = Overlay::Prompt(state);
                    }
                    _ => {
                        self.overlay = Overlay::Prompt(state);
                    }
                }
            }
            Overlay::Confirm(mut state) => {
                use KeyCode::*;
                match key.code {
                    Esc => {}
                    Left | Up => {
                        state.selected = state.selected.saturating_sub(1);
                        self.overlay = Overlay::Confirm(state);
                    }
                    Right | Down => {
                        state.selected = (state.selected + 1).min(2);
                        self.overlay = Overlay::Confirm(state);
                    }
                    Enter => self.apply_confirm(state.action, state.selected),
                    Char('y') | Char('Y') => self.apply_confirm(state.action, 0),
                    Char('n') | Char('N') => self.apply_confirm(state.action, 1),
                    _ => {
                        self.overlay = Overlay::Confirm(state);
                    }
                }
            }
        }
    }

    fn activate_list_item(&mut self, kind: &ListKind, item: ListItem) {
        match kind {
            ListKind::Command => {
                if let Some(cmd) = item.command {
                    self.push_recent_command(cmd);
                    self.execute(cmd);
                } else if let Some(value) = item.value {
                    if let Some(id) = value.strip_prefix("js\u{1}") {
                        self.run_plugin_command(id);
                    }
                }
            }
            ListKind::QuickOpen => {
                if let Some(path) = item.path {
                    if let Err(e) = self.open_file(&path) {
                        self.set_error(e);
                    }
                }
            }
            ListKind::Tabs => {
                if let Some(value) = item.value {
                    if let Ok(index) = value.parse::<usize>() {
                        self.select_tab(index);
                    }
                }
            }
            ListKind::Theme => {
                if let Some(name) = item.value {
                    self.theme = crate::ui::theme::by_name(&name);
                    self.config.theme = name.clone();
                    self.set_status(format!("主题：{name}"));
                }
            }
            ListKind::Language => {
                if let Some(value) = item.value {
                    if let Some(lang) = Language::from_name(&value) {
                        self.doc_mut().language = lang;
                        self.refresh_active(false);
                        self.set_status(format!("语言模式：{}", lang.label()));
                    }
                }
            }
            ListKind::Encoding => {
                if let Some(value) = item.value {
                    if let Some(enc) = Encoding::parse(&value) {
                        self.doc_mut().set_encoding(enc);
                        self.set_status(format!(
                            "编码：{}（保存后生效）",
                            enc.label()
                        ));
                    }
                }
            }
            ListKind::Eol => {
                if let Some(value) = item.value {
                    if let Some(eol) = Eol::parse(&value) {
                        self.doc_mut().set_eol(eol);
                        self.set_status(format!(
                            "换行符：{}（保存后生效）",
                            eol.label()
                        ));
                    }
                }
            }
            ListKind::Snippet => {
                if let Some(body) = item.value {
                    let indent = self.doc().leading_whitespace(self.doc().primary().pos.line);
                    let text = snippets::indented(&body, &indent);
                    self.doc_mut().insert_text(&text);
                    self.after_change();
                }
            }
            ListKind::Outline | ListKind::Problems => {
                if let Some(path) = item.path {
                    if let Err(e) = self.open_file(&path) {
                        self.set_error(e);
                        return;
                    }
                }
                if let Some(line) = item.line {
                    self.doc_mut().set_cursor(Pos::new(line, 0));
                    self.ensure_visible();
                }
            }
            ListKind::GitLog => {
                if let Some(value) = item.value {
                    self.open_git_show(&value);
                }
            }
            ListKind::GitBranches => {
                if let Some(value) = item.value {
                    self.git_checkout(&value);
                }
            }
            ListKind::LspReferences | ListKind::LspSymbols => {
                if let (Some(path), Some(line)) = (item.path, item.line) {
                    let col = item
                        .value
                        .as_deref()
                        .and_then(|value| value.parse::<usize>().ok())
                        .unwrap_or(0);
                    self.lsp_open_location(path, line, col);
                }
            }
            ListKind::LspInfo => {
                if let (Some(path), Some(line)) = (item.path, item.line) {
                    self.lsp_open_location(path, line, 0);
                }
            }
            ListKind::LspCodeAction => {
                if let Some(value) = item.value {
                    if let Ok(index) = value.parse::<usize>() {
                        self.apply_code_action(index);
                    }
                }
            }
            ListKind::LspCompletion => {
                if let Some(value) = item.value {
                    // 用补全结果替换已输入的同前缀标识符。
                    let pos = self.doc().primary().pos;
                    let prefix = word_prefix(self.doc().line(pos.line), pos.col);
                    if !prefix.is_empty() && value.starts_with(&prefix) {
                        for _ in 0..prefix.chars().count() {
                            self.doc_mut().backspace(false);
                        }
                    }
                    self.doc_mut().insert_text(&value);
                    self.after_change();
                }
            }
            ListKind::ExcelFontSize
            | ListKind::ExcelFontColor
            | ListKind::ExcelFillColor
            | ListKind::ExcelNumberFormat => {
                if let Some(value) = item.value {
                    self.excel_apply_picker(*kind, &value);
                }
            }
            ListKind::Clipboard => {
                if let Some(text) = item.value {
                    self.overlay = Overlay::None;
                    self.doc_mut().insert_text(&text);
                    self.after_change();
                    self.set_status("已从剪贴板历史插入");
                }
            }
            ListKind::TaskList => {
                if let Some(label) = item.value {
                    if let Some(task) = self.tasks.iter().find(|t| t.label == label).cloned() {
                        self.overlay = Overlay::None;
                        self.start_task(task);
                    }
                }
            }
            ListKind::TaskOutput => {
                self.overlay = Overlay::None;
            }
            ListKind::Extensions => {
                if let Some(name) = item.value {
                    self.toggle_extension(&name);
                }
            }
            ListKind::ExtensionCommand => {
                if let Some(key) = item.value {
                    self.overlay = Overlay::None;
                    self.run_extension_command(&key);
                }
            }
            ListKind::DebugConfig => {
                if let Some(value) = item.value {
                    if let Ok(index) = value.parse::<usize>() {
                        self.overlay = Overlay::None;
                        self.start_debug_config(index);
                    }
                }
            }
            ListKind::DebugOutput => {
                self.overlay = Overlay::None;
            }
            ListKind::DebugVars => {
                if let (Some(path), Some(line)) = (item.path, item.line) {
                    self.open_debug_location(path, line + 1);
                }
            }
            ListKind::RemoteHosts => {
                if let Some(name) = item.value {
                    self.overlay = Overlay::None;
                    self.select_remote_host(&name);
                }
            }
            ListKind::PluginChoice => {
                let value = item.value.unwrap_or_else(|| "null".to_string());
                self.overlay = Overlay::None;
                if let Some((id, _)) = self.plugin_pending.take() {
                    if let Err(e) = self.plugin.resolve(id, &value) {
                        self.set_error(e);
                    }
                    self.process_plugin_requests();
                }
            }
            ListKind::PluginOutput => {
                self.overlay = Overlay::None;
            }
        }
    }

    // ------------------------------------------------------------ 任务运行器

    fn open_task_list(&mut self) {
        let mut tasks = Vec::new();
        for root in &self.sidebar.roots {
            tasks.extend(crate::task::load(root));
        }
        tasks.sort_by(|a, b| a.label.cmp(&b.label));
        self.tasks = tasks;
        if self.tasks.is_empty() {
            self.set_error("未找到 tasks.json：可在 .vscode/tasks.json 中定义任务");
            return;
        }
        let items: Vec<ListItem> = self
            .tasks
            .iter()
            .map(|task| ListItem {
                title: task.label.clone(),
                detail: task.command_line(),
                command: None,
                path: None,
                line: None,
                value: Some(task.label.clone()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::TaskList, "运行任务", items));
    }

    fn start_task(&mut self, task: crate::task::Task) {
        match crate::task::TaskRun::start(&task) {
            Ok(run) => {
                self.task_run = Some(run);
                self.task_last = Some(task.clone());
                self.set_status(format!("任务运行中：{}", task.label));
                self.open_task_output();
            }
            Err(e) => self.set_error(e),
        }
    }

    pub(crate) fn task_output_items(&self) -> Vec<ListItem> {
        let Some(run) = &self.task_run else {
            return vec![ListItem::plain("（没有任务输出）")];
        };
        let state = match run.exit_code() {
            Some(code) => format!("（退出码 {code}）"),
            None if run.is_running() => "（运行中…）".to_string(),
            None => String::new(),
        };
        let mut items = vec![
            ListItem::plain(format!("任务：{}{}", run.label, state)),
            ListItem::plain(String::new()),
        ];
        for line in run.tail(400) {
            items.push(ListItem::plain(line));
        }
        items
    }

    fn open_task_output(&mut self) {
        let items = self.task_output_items();
        let mut list = ListState::new(ListKind::TaskOutput, "任务输出", items);
        list.selected = list.filtered.len().saturating_sub(1);
        self.task_refresh_at = std::time::Instant::now();
        self.overlay = Overlay::List(list);
    }

    // ------------------------------------------------------------ 插件

    fn open_extensions(&mut self) {
        let items: Vec<ListItem> = self
            .extensions
            .iter()
            .map(|ext| ListItem {
                title: format!(
                    "{}  {}",
                    if ext.enabled { "●" } else { "○" },
                    ext.name
                ),
                detail: format!(
                    "v{} · {} 条命令 · {} 个主题 · {} 个片段 · {} · {}",
                    ext.version,
                    ext.commands.len(),
                    ext.themes.len(),
                    ext.snippets.len(),
                    if ext.main.is_some() { "JS" } else { "声明式" },
                    ext.source
                ),
                command: None,
                path: None,
                line: None,
                value: Some(ext.name.clone()),
            })
            .collect();
        if items.is_empty() {
            self.set_error(
                "未找到插件：把插件放到 %APPDATA%\\Textm\\plugins\\<名称>\\textm.json",
            );
            return;
        }
        let mut list = ListState::new(ListKind::Extensions, "插件管理（回车启用/禁用）", items);
        list.selected = 0;
        self.open_list(list);
    }

    fn toggle_extension(&mut self, name: &str) {
        let was_enabled = self
            .extensions
            .iter()
            .find(|ext| ext.name == name)
            .map(|ext| ext.enabled)
            .unwrap_or(true);
        self.config.disabled_plugins.retain(|item| item != name);
        if was_enabled {
            self.config.disabled_plugins.push(name.to_string());
        }
        self.reload_extensions();
        self.reload_plugins();
        let (names, _) = crate::extension::register_contributions(&self.extensions);
        self.plugin_theme_names = names;
        self.open_extensions();
        if let Overlay::List(list) = &mut self.overlay {
            if let Some(index) = list
                .items
                .iter()
                .position(|item| item.value.as_deref() == Some(name))
            {
                if let Some(pos) = list.filtered.iter().position(|i| *i == index) {
                    list.selected = pos;
                }
            }
        }
        self.set_status(format!(
            "插件 {name}：{}",
            if was_enabled { "已禁用" } else { "已启用" }
        ));
    }

    fn open_extension_commands(&mut self) {
        let mut items = Vec::new();
        for ext in &self.extensions {
            if !ext.enabled {
                continue;
            }
            for command in ext.commands.iter().filter(|c| c.program.is_some()) {
                let program = command.program.clone().unwrap_or_default();
                let detail = if command.args.is_empty() {
                    program
                } else {
                    format!("{} {}", program, command.args.join(" "))
                };
                items.push(ListItem {
                    title: format!("{}：{}", ext.name, command.title),
                    detail,
                    command: None,
                    path: None,
                    line: None,
                    value: Some(format!("{}\u{1}{}", ext.name, command.title)),
                });
            }
            if let Some(main) = &ext.main {
                for command in ext.commands.iter().filter(|c| c.program.is_none()) {
                    items.push(ListItem {
                        title: format!("{}：{}", ext.name, command.title),
                        detail: format!("JS · {}", main.display()),
                        command: None,
                        path: None,
                        line: None,
                        value: Some(format!("js\u{1}{}", command.id)),
                    });
                }
            }
        }
        // 运行时注册、但清单里没写的 JS 命令
        for (id, title, extension) in &self.plugin.commands {
            if items
                .iter()
                .any(|item| item.value.as_deref() == Some(&format!("js\u{1}{id}")))
            {
                continue;
            }
            items.push(ListItem {
                title: format!("插件：{title}"),
                detail: extension.clone(),
                command: None,
                path: None,
                line: None,
                value: Some(format!("js\u{1}{id}")),
            });
        }
        if items.is_empty() {
            self.set_error("没有可用的插件命令（插件未启用或未定义 commands）");
            return;
        }
        self.open_list(ListState::new(ListKind::ExtensionCommand, "运行插件命令", items));
    }

    fn run_extension_command(&mut self, key: &str) {
        if let Some(id) = key.strip_prefix("js\u{1}") {
            self.run_plugin_command(id);
            return;
        }
        let Some((name, title)) = key.split_once('\u{1}') else {
            return;
        };
        let Some(ext) = self.extensions.iter().find(|ext| ext.name == name).cloned() else {
            self.set_error("插件已被移除");
            return;
        };
        let Some(command) = ext.commands.iter().find(|c| c.title == title).cloned() else {
            return;
        };
        if command.program.is_none() {
            self.run_plugin_command(&command.id);
            return;
        }
        let workspace = self
            .sidebar
            .roots
            .iter()
            .find(|root| ext.dir.starts_with(root))
            .cloned()
            .unwrap_or_else(|| self.sidebar.root.clone());
        let task = ext.task(&command, &workspace);
        self.start_task(task);
    }

    fn open_extension_dir(&mut self) {
        let dir = crate::config::Config::path()
            .parent()
            .map(|p| p.join("plugins"))
            .unwrap_or_else(|| PathBuf::from("plugins"));
        let _ = std::fs::create_dir_all(&dir);
        match std::process::Command::new("explorer").arg(&dir).spawn() {
            Ok(_) => self.set_status(format!("插件目录：{}", dir.display())),
            Err(e) => self.set_error(format!("无法打开插件目录：{e}")),
        }
    }

    // ------------------------------------------------------------ 插件宿主

    fn plugin_context(&self) -> crate::plugin::HostContext {
        let doc = self.doc();
        let pos = doc.primary().pos;
        let cursor = doc.primary();
        let selection = cursor.selection();
        let (sel_start, sel_end) = selection.unwrap_or((pos, pos));
        crate::plugin::HostContext {
            workspace: self.sidebar.root.clone(),
            roots: self.sidebar.roots.clone(),
            active_path: doc.path.clone(),
            active_text: doc.text(),
            active_language: doc
                .path
                .as_deref()
                .map(crate::plugin::language_id)
                .unwrap_or_else(|| "plaintext".into()),
            active_line: pos.line,
            active_character: pos.col,
            active_version: doc.revision,
            eol: if doc.eol == Eol::CrLf { 2 } else { 1 },
            sel_start_line: sel_start.line,
            sel_start_character: sel_start.col,
            sel_end_line: sel_end.line,
            sel_end_character: sel_end.col,
        }
    }

    fn run_plugin_command(&mut self, id: &str) {
        let context = self.plugin_context();
        self.plugin.set_context(context);
        match self.plugin.execute(id, "[]") {
            Ok(()) => {}
            Err(e) => self.set_error(e),
        }
        self.process_plugin_requests();
        self.refresh_plugin_output_panel();
    }

    /// 通知插件某个事件（save / open / change）。
    pub(crate) fn fire_plugin_event(&mut self, name: &str, path: &Path) {
        if !self.config.plugins_enabled || !self.plugin.is_running() {
            return;
        }
        let payload = crate::lsp::json::object(vec![(
            "path",
            Json::String(path.to_string_lossy().to_string()),
        )])
        .dump();
        self.plugin.fire_event(name, &payload);
        self.process_plugin_requests();
    }

    pub(crate) fn process_plugin_requests(&mut self) {
        let requests = self.plugin.drain_requests();
        for request in requests {
            self.apply_plugin_request(request);
        }
    }

    fn apply_plugin_request(&mut self, request: crate::plugin::Request) {
        use crate::plugin::Request;
        match request {
            Request::Message { level, text } => {
                if level >= 3 {
                    self.set_error(format!("插件：{text}"));
                } else {
                    self.set_status(format!("插件：{text}"));
                }
            }
            Request::Output(text) => self.plugin.push_output(text),
            Request::Status(text) => self.plugin_status = text,
            Request::Log(text) => self.plugin.push_output(format!("[日志] {text}")),
            Request::Problems { path, items } => {
                let path = path.or_else(|| self.doc().path.clone());
                if let Some(path) = path {
                    let mut items = items;
                    for item in &mut items {
                        item.path = path.clone();
                    }
                    self.plugin
                        .problems
                        .retain(|existing| existing.path != path);
                    let count = items.len();
                    self.plugin.problems.extend(items);
                    self.set_status(format!("插件问题：{count} 条（{}）", path.display()));
                }
            }
            Request::QuickPick {
                id,
                items,
                placeholder,
            } => {
                let list: Vec<ListItem> = items
                    .into_iter()
                    .map(|(label, detail, raw)| ListItem {
                        title: label,
                        detail,
                        command: None,
                        path: None,
                        line: None,
                        value: Some(raw),
                    })
                    .collect();
                self.plugin_pending = Some((id, 0));
                let title = if placeholder.is_empty() {
                    "插件选择"
                } else {
                    &placeholder
                };
                let mut state = ListState::new(ListKind::PluginChoice, title, list);
                state.query.clear();
                self.overlay = Overlay::List(state);
            }
            Request::InputBox { id, prompt, value } => {
                self.plugin_pending = Some((id, 1));
                self.open_prompt(PromptKind::PluginInput, &prompt, &value);
            }
            Request::ApplyEdits { path, edits } => self.plugin_apply_edits(path, edits),
            Request::OpenDocument(path) => {
                if let Err(e) = self.open_file(&path) {
                    self.set_error(e);
                }
            }
            Request::ShowDocument {
                path,
                line,
                column,
            } => {
                self.open_debug_location(path, line + 1);
                let cursor_line = self.doc().primary().pos.line;
                self.doc_mut().set_cursor(Pos::new(cursor_line, column));
                self.ensure_visible();
            }
            Request::SaveDocument(path) => {
                if let Some(index) = self
                    .tabs
                    .iter()
                    .position(|tab| tab.doc.path.as_deref() == Some(path.as_path()))
                {
                    self.active = index;
                    if let Err(e) = self.tab_mut().save_document() {
                        self.set_error(e);
                    } else {
                        self.fire_plugin_event("save", &path);
                    }
                }
            }
            Request::Terminal(command) => {
                let task = crate::task::Task {
                    label: "插件终端".into(),
                    command: "cmd".into(),
                    args: vec!["/C".into(), command],
                    cwd: Some(self.sidebar.root.clone()),
                    group: false,
                };
                self.start_task(task);
            }
            Request::Panel { title, text } => {
                self.plugin.panels.push((title.clone(), text.clone()));
                let mut doc = Document::from_text(
                    &format!("// 插件视图：{title}\n{text}"),
                    None,
                );
                doc.read_only = true;
                let mut tab = Tab::new(doc, &self.config);
                tab.preview = true;
                self.tabs.push(tab);
                self.active = self.tabs.len() - 1;
                self.set_status(format!("插件视图：{title}"));
            }
            Request::CommandRegistered(_) => {}
        }
    }

    fn plugin_apply_edits(&mut self, path: PathBuf, edits: Vec<crate::plugin::PluginEdit>) {
        if let Some(index) = self
            .tabs
            .iter()
            .position(|tab| tab.doc.path.as_deref() == Some(path.as_path()))
        {
            self.active = index;
            let ranges: Vec<(Pos, Pos, String)> = edits
                .iter()
                .map(|edit| {
                    (
                        Pos::new(edit.start_line, edit.start_char),
                        Pos::new(edit.end_line, edit.end_char),
                        edit.new_text.clone(),
                    )
                })
                .collect();
            self.doc_mut().replace_ranges_each(&ranges);
            self.after_change();
            return;
        }
        if let Ok(text) = std::fs::read_to_string(&path) {
            let updated = apply_text_edits(&text, &edits);
            if std::fs::write(&path, updated).is_ok() {
                self.set_status(format!("插件已修改 {}", path.display()));
            }
        }
    }

    pub(crate) fn plugin_output_items(&self) -> Vec<ListItem> {
        let mut items = vec![ListItem::plain(format!(
            "插件功能：{}",
            if self.config.plugins_enabled {
                "已开启"
            } else {
                "已关闭"
            }
        ))];
        if !self.plugin.errors.is_empty() {
            items.push(ListItem::plain("— 错误 —"));
            for error in &self.plugin.errors {
                items.push(ListItem::plain(error.clone()));
            }
        }
        items.push(ListItem::plain(String::new()));
        let start = self.plugin.output.len().saturating_sub(400);
        for line in &self.plugin.output[start..] {
            items.push(ListItem::plain(line.clone()));
        }
        if self.plugin.output.is_empty() {
            items.push(ListItem::plain("（暂无输出）"));
        }
        items
    }

    fn open_plugin_output(&mut self) {
        let items = self.plugin_output_items();
        let mut list = ListState::new(ListKind::PluginOutput, "插件输出", items);
        list.selected = list.filtered.len().saturating_sub(1);
        self.overlay = Overlay::List(list);
    }

    pub(crate) fn refresh_plugin_output_panel(&mut self) {
        if matches!(&self.overlay, Overlay::List(list) if list.kind == ListKind::PluginOutput) {
            let items = self.plugin_output_items();
            if let Overlay::List(list) = &mut self.overlay {
                list.items = items;
                list.refilter();
                list.selected = list.filtered.len().saturating_sub(1);
            }
        }
    }

    /// 设置面板切换“插件功能”后的加载 / 卸载。
    pub(crate) fn apply_plugins_toggle(&mut self) {
        if self.config.plugins_enabled {
            self.reload_extensions();
            self.reload_plugins();
            let (names, snippet_count) =
                crate::extension::register_contributions(&self.extensions);
            self.plugin_theme_names = names;
            let count = self.plugin.commands.len();
            self.set_status(format!(
                "插件功能已开启（{} 个插件，{} 个 JS 命令，{} 个片段）",
                self.extensions.len(),
                count,
                snippet_count
            ));
        } else {
            self.plugin.shutdown();
            self.plugin.packages.clear();
            self.plugin.commands.clear();
            for name in self.plugin_theme_names.drain(..) {
                crate::ui::theme::unregister(&name);
            }
            crate::core::snippets::clear_market();
            self.extensions.clear();
            self.plugin_status.clear();
            self.plugin_pending = None;
            if !crate::ui::theme::all_names().contains(&self.theme.name) {
                self.theme = crate::ui::theme::by_name("vscode-dark");
                self.config.theme = "vscode-dark".into();
            }
            self.set_status("插件功能已关闭");
        }
    }

    // ------------------------------------------------------------ 调试

    fn debug_start(&mut self) {
        if self.debug.is_active() {
            if self.debug.stopped {
                self.debug.continue_run();
                self.set_status("继续执行");
            } else {
                self.set_status("调试会话正在运行");
            }
            return;
        }
        let mut roots = self.sidebar.roots.clone();
        if roots.is_empty() {
            roots.push(self.cwd.clone());
        }
        let mut configs = Vec::new();
        for root in &roots {
            configs.extend(crate::debug::load_launch_configs(root));
        }
        if configs.is_empty() {
            self.set_error("未找到 .vscode/launch.json：请先在工程中配置调试启动项");
            return;
        }
        self.debug.workspace = roots
            .first()
            .cloned()
            .unwrap_or_else(|| self.cwd.clone());
        self.debug.configs = configs;
        let items: Vec<ListItem> = self
            .debug
            .configs
            .iter()
            .enumerate()
            .map(|(index, cfg)| ListItem {
                title: cfg.name.clone(),
                detail: format!("{} · {}", cfg.kind, cfg.request),
                command: None,
                path: None,
                line: None,
                value: Some(index.to_string()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::DebugConfig, "选择调试配置", items));
    }

    fn start_debug_config(&mut self, index: usize) {
        let Some(cfg) = self.debug.configs.get(index).cloned() else {
            return;
        };
        let workspace = cfg
            .root
            .clone()
            .unwrap_or_else(|| {
                if self.debug.workspace.as_os_str().is_empty() {
                    self.sidebar.root.clone()
                } else {
                    self.debug.workspace.clone()
                }
            });
        let Some(adapter) = crate::debug::adapter_for(&cfg.kind, &self.config.debug_adapters)
        else {
            self.set_error(format!(
                "未配置 {} 调试适配器：在 config.ini 添加 debug.{} = 适配器命令",
                cfg.kind, cfg.kind
            ));
            return;
        };
        let file = self.doc().path.clone();
        let raw = crate::debug::prepare_launch(&cfg, &workspace, file.as_deref());
        self.debug.start(&adapter, &workspace, raw);
        self.set_status(format!("启动调试：{}", cfg.name));
    }

    fn debug_step(&mut self, command: &str, label: &str) {
        if !self.debug.is_active() {
            self.set_error("没有调试会话（先按 F5 启动）");
            return;
        }
        if !self.debug.stopped {
            self.set_error("程序正在运行，暂停后才能单步");
            return;
        }
        self.debug.single_step(command);
        self.set_status(format!("{label}…"));
    }

    fn debug_toggle_breakpoint(&mut self) {
        if self.tab().preview || self.tab().excel.is_some() || self.tab().word.is_some() {
            self.set_error("当前标签不支持断点");
            return;
        }
        let Some(path) = self.doc().path.clone() else {
            self.set_error("请先保存文件再设置断点");
            return;
        };
        let line = self.doc().primary().pos.line;
        let set = self.debug.toggle_breakpoint(&path, line);
        if self.debug.is_active() {
            self.debug.flush_breakpoints();
        }
        self.set_status(format!(
            "{}第 {} 行断点",
            if set { "已设置" } else { "已移除" },
            line + 1
        ));
    }

    pub(crate) fn debug_output_items(&self) -> Vec<ListItem> {
        let status = if self.debug.status.is_empty() {
            "未启动"
        } else {
            self.debug.status.as_str()
        };
        let mut items = vec![
            ListItem::plain(format!("调试状态：{status}")),
            ListItem::plain(String::new()),
        ];
        for line in self.debug.tail_log(400) {
            items.push(ListItem::plain(line));
        }
        items
    }

    fn open_debug_output(&mut self) {
        let items = self.debug_output_items();
        let mut list = ListState::new(ListKind::DebugOutput, "调试输出", items);
        list.selected = list.filtered.len().saturating_sub(1);
        self.debug_refresh_at = std::time::Instant::now();
        self.overlay = Overlay::List(list);
    }

    fn open_debug_vars(&mut self) {
        let status = if self.debug.status.is_empty() {
            "未启动"
        } else {
            self.debug.status.as_str()
        };
        let mut items = vec![ListItem::plain(format!("调试状态：{status}"))];
        if let Some(frame) = self.debug.frames.first() {
            items.push(ListItem::plain(format!(
                "当前位置：{}（第 {} 行）",
                frame.name, frame.line
            )));
        }
        items.push(ListItem::plain(String::new()));
        items.push(ListItem::plain("调用栈："));
        if self.debug.frames.is_empty() {
            items.push(ListItem::plain("（暂无，暂停后自动获取）"));
        }
        for (index, frame) in self.debug.frames.iter().enumerate().take(12) {
            items.push(ListItem {
                title: format!("{index}. {}", frame.name),
                detail: format!("第 {} 行", frame.line),
                command: None,
                path: frame.path.clone(),
                line: Some(frame.line.saturating_sub(1)),
                value: None,
            });
        }
        items.push(ListItem::plain(String::new()));
        items.push(ListItem::plain("变量："));
        if self.debug.variables.is_empty() {
            items.push(ListItem::plain("（暂无）"));
        }
        for (_, text) in &self.debug.variables {
            items.push(ListItem::plain(text.clone()));
        }
        self.open_list(ListState::new(ListKind::DebugVars, "变量 / 调用栈", items));
    }

    // ------------------------------------------------------------ 远程

    fn open_remote_hosts(&mut self) {
        if self.remote.hosts.is_empty() {
            self.set_error("尚未配置远程主机：在 config.ini 添加 remote.<名称> = user@host[:端口]");
            return;
        }
        let active = self.remote.active.clone();
        let items: Vec<ListItem> = self
            .remote
            .hosts
            .iter()
            .map(|host| ListItem {
                title: format!(
                    "{} {}",
                    if active.as_deref() == Some(host.name.as_str()) {
                        "●"
                    } else {
                        "○"
                    },
                    host.name
                ),
                detail: format!(
                    "{} · 端口 {} · 目录 {}",
                    host.target(),
                    host.port,
                    if host.root.is_empty() {
                        "~"
                    } else {
                        &host.root
                    }
                ),
                command: None,
                path: None,
                line: None,
                value: Some(host.name.clone()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::RemoteHosts, "选择远程主机", items));
    }

    fn select_remote_host(&mut self, name: &str) {
        if self.remote.host(name).is_some() {
            self.remote.active = Some(name.to_string());
            self.set_status(format!("当前远程主机：{name}"));
        }
    }

    fn add_remote_host(&mut self, input: &str) -> Result<(), String> {
        let (name, spec) = input
            .split_once('=')
            .ok_or_else(|| "格式：名称=user@host[:端口]".to_string())?;
        let name = name.trim();
        let spec = spec.trim();
        if name.is_empty() || crate::remote::RemoteHost::parse(name, spec, "").is_none() {
            return Err("主机格式无效，示例：dev=mmm@192.0.2.10:22".into());
        }
        self.config.remotes.retain(|(item, _)| item != name);
        self.config.remotes.push((name.to_string(), spec.to_string()));
        self.reload_remotes();
        self.remote.active = Some(name.to_string());
        Ok(())
    }

    fn run_remote_command(&mut self, command: &str) {
        let Some(host) = self.remote.active_host().cloned() else {
            self.set_error("尚未选择远程主机");
            return;
        };
        if command.trim().is_empty() {
            self.set_error("命令不能为空");
            return;
        }
        self.start_task(host.command_task(command.trim()));
    }

    fn open_remote_file(&mut self, remote: &str) {
        let Some(host) = self.remote.active_host().cloned() else {
            self.set_error("尚未选择远程主机");
            return;
        };
        let remote = remote.trim();
        if remote.is_empty() {
            self.set_error("远端路径不能为空");
            return;
        }
        let local = crate::remote::cache_path(&self.remote.cache_root, &host.name, remote);
        if let Err(e) = host.download(remote, &local) {
            self.set_error(e);
            return;
        }
        if let Err(e) = self.open_file(&local) {
            self.set_error(e);
            return;
        }
        self.remote
            .mappings
            .insert(local, (host.name.clone(), remote.to_string()));
        self.set_status(format!("已打开 {remote}（保存时自动回传）"));
    }

    fn upload_remote(&mut self, remote: &str) {
        let Some(path) = self.doc().path.clone() else {
            self.set_error("当前文件尚未保存");
            return;
        };
        let Some(host) = self.remote.active_host().cloned() else {
            self.set_error("尚未选择远程主机");
            return;
        };
        let mut target = remote.trim().to_string();
        if target.is_empty() {
            if let Some((_, mapped)) = self.remote.mapping_for(&path) {
                target = mapped;
            }
        }
        if target.is_empty() {
            self.set_error("请输入远端路径");
            return;
        }
        match host.upload(&path, &target) {
            Ok(()) => {
                self.remote
                    .mappings
                    .insert(path, (host.name.clone(), target.clone()));
                self.set_status(format!("已上传到 {}:{}", host.name, target));
            }
            Err(e) => self.set_error(e),
        }
    }

    /// 保存后把已映射的远端文件回传。
    fn remote_upload_if_mapped(&mut self, path: &Path) {
        let Some((name, remote)) = self.remote.mapping_for(path) else {
            return;
        };
        let Some(host) = self.remote.host(&name).cloned() else {
            return;
        };
        match host.upload(path, &remote) {
            Ok(()) => self.set_status(format!("已回传 {remote}（{}）", host.name)),
            Err(e) => self.set_error(e),
        }
    }

    // ------------------------------------------------------------ 设置与剪贴板历史

    // ------------------------------------------------------------ 设置页

    /// 设置页的内容区（状态栏之上）。
    pub fn settings_area(&self) -> Rect {
        Rect {
            x: 0,
            y: 0,
            w: self.layout.cols,
            h: self.layout.status.y,
        }
    }

    pub fn settings_category_rect(&self) -> Rect {
        let area = self.settings_area();
        Rect {
            x: area.x + 1,
            y: area.y + 2,
            w: 16,
            h: area.h.saturating_sub(4),
        }
    }

    pub fn settings_list_rect(&self) -> Rect {
        let area = self.settings_area();
        let x = area.x + 19;
        Rect {
            x,
            y: area.y + 2,
            w: area.right().saturating_sub(x + 1),
            h: area.h.saturating_sub(5),
        }
    }

    /// 当前显示的行：无搜索词时只显示当前分类，有搜索词时跨分类过滤。
    pub fn settings_rows(&self) -> Vec<SettingRow> {
        let Some(page) = &self.settings else {
            return Vec::new();
        };
        let query = page.query.trim().to_lowercase();
        let mut out = Vec::new();
        for (index, (name, items)) in crate::ui::app::SETTING_CATEGORIES.iter().enumerate() {
            if query.is_empty() && index != page.category {
                continue;
            }
            for (key, label, desc) in items.iter() {
                if !query.is_empty() {
                    let hay = format!("{name}{label}{desc}{key}").to_lowercase();
                    if !hay.contains(&query) {
                        continue;
                    }
                }
                out.push(SettingRow {
                    key,
                    label,
                    desc,
                    value: self.setting_value(key),
                });
            }
        }
        out
    }

    fn setting_value(&self, key: &str) -> String {
        let c = &self.config;
        let onoff = |b: bool| if b { "开" } else { "关" };
        match key {
            "tab_width" => format!("{}", c.tab_width),
            "use_spaces" => if c.use_spaces { "空格".into() } else { "制表符".into() },
            "auto_indent" => onoff(c.auto_indent).into(),
            "auto_pair" => onoff(c.auto_pair).into(),
            "wrap" => onoff(c.wrap).into(),
            "folding" => onoff(c.folding).into(),
            "autosave" => onoff(c.autosave).into(),
            "show_whitespace" => onoff(c.show_whitespace).into(),
            "theme" => c.theme.clone(),
            "layout" => c.layout.clone(),
            "minimap" => onoff(c.minimap).into(),
            "minimap_width" => format!("{}", c.minimap_width),
            "sidebar" => onoff(c.sidebar).into(),
            "sidebar_width" => format!("{}", c.sidebar_width),
            "gui_font_size" => format!("{}", c.gui_font_size),
            "icons" => if c.icons { "unicode".into() } else { "ascii".into() },
            "nerd_font" => c.nerd_font.clone(),
            "rainbow_brackets" => onoff(c.rainbow_brackets).into(),
            "centered" => onoff(c.centered).into(),
            "vim" => onoff(c.vim).into(),
            "indent_guides" => onoff(c.indent_guides).into(),
            "format_on_save" => onoff(c.format_on_save).into(),
            "sticky_scroll" => onoff(c.sticky_scroll).into(),
            "terminal_height" => format!("{}", c.terminal_height),
            "restore_session" => onoff(c.restore_session).into(),
            "confirm_close" => onoff(c.confirm_close).into(),
            "confirm_paste" => onoff(c.confirm_multiline_paste).into(),
            "show_hidden" => onoff(c.show_hidden).into(),
            "workspace_ignore" => onoff(c.workspace_ignore).into(),
            "git" => onoff(c.git).into(),
            "language" => if c.language_en() { "en".into() } else { "zh".into() },
            "lsp_auto" => onoff(c.lsp_auto_complete).into(),
            "lsp_signature" => onoff(c.lsp_signature_help).into(),
            "lsp_hints" => onoff(c.lsp_inlay_hints).into(),
            "plugins" => onoff(c.plugins_enabled).into(),
            _ => String::new(),
        }
    }

    fn cycle_number(value: usize, dir: i32, options: &[usize]) -> usize {
        let current = options
            .iter()
            .position(|item| *item == value)
            .unwrap_or(0);
        let index = if dir >= 0 {
            (current + 1) % options.len()
        } else {
            (current + options.len() - 1) % options.len()
        };
        options[index]
    }

    fn adjust_setting(&mut self, key: &str, dir: i32) {
        {
            let c = &mut self.config;
            match key {
                "tab_width" => c.tab_width = Self::cycle_number(c.tab_width, dir, &[2, 4, 8]),
                "use_spaces" => c.use_spaces = !c.use_spaces,
                "auto_indent" => c.auto_indent = !c.auto_indent,
                "auto_pair" => c.auto_pair = !c.auto_pair,
                "wrap" => c.wrap = !c.wrap,
                "folding" => c.folding = !c.folding,
                "autosave" => c.autosave = !c.autosave,
                "show_whitespace" => c.show_whitespace = !c.show_whitespace,
                "theme" => {
                    let names = crate::ui::theme::all_names();
                    let current = names
                        .iter()
                        .position(|name| name.eq_ignore_ascii_case(&c.theme))
                        .unwrap_or(0);
                    let next = if dir >= 0 {
                        (current + 1) % names.len()
                    } else {
                        (current + names.len() - 1) % names.len()
                    };
                    c.theme = names[next].to_string();
                }
                "minimap" => c.minimap = !c.minimap,
                "layout" => {
                    c.layout = if crate::ui::app::LayoutStyle::from_config(&c.layout)
                        == crate::ui::app::LayoutStyle::Vscode
                    {
                        "sqlmux".into()
                    } else {
                        "vscode".into()
                    };
                }
                "minimap_width" => {
                    let step = if dir >= 0 { 2 } else { -2 };
                    c.minimap_width = (c.minimap_width as i32 + step).clamp(4, 24) as usize;
                }
                "sidebar" => c.sidebar = !c.sidebar,
                "sidebar_width" => {
                    let step = if dir >= 0 { 2 } else { -2 };
                    c.sidebar_width = (c.sidebar_width as i32 + step).clamp(14, 50) as usize;
                }
                "gui_font_size" => {
                    let step = if dir >= 0 { 1 } else { -1 };
                    c.gui_font_size = (c.gui_font_size as i32 + step).clamp(10, 40) as u16;
                }
                "icons" => c.icons = !c.icons,
                "nerd_font" => {
                    let options = ["auto", "on", "off"];
                    let current = options
                        .iter()
                        .position(|item| item.eq_ignore_ascii_case(&c.nerd_font))
                        .unwrap_or(0);
                    let next = if dir >= 0 {
                        (current + 1) % options.len()
                    } else {
                        (current + options.len() - 1) % options.len()
                    };
                    c.nerd_font = options[next].to_string();
                }
                "rainbow_brackets" => c.rainbow_brackets = !c.rainbow_brackets,
                "centered" => c.centered = !c.centered,
                "vim" => c.vim = !c.vim,
                "indent_guides" => c.indent_guides = !c.indent_guides,
                "format_on_save" => c.format_on_save = !c.format_on_save,
                "sticky_scroll" => c.sticky_scroll = !c.sticky_scroll,
                "terminal_height" => {
                    let step = if dir >= 0 { 2 } else { -2 };
                    c.terminal_height = (c.terminal_height as i32 + step).clamp(0, 30) as usize;
                }
                "restore_session" => c.restore_session = !c.restore_session,
                "confirm_close" => c.confirm_close = !c.confirm_close,
                "confirm_paste" => c.confirm_multiline_paste = !c.confirm_multiline_paste,
                "show_hidden" => c.show_hidden = !c.show_hidden,
                "workspace_ignore" => c.workspace_ignore = !c.workspace_ignore,
                "git" => c.git = !c.git,
                "language" => {
                    c.ui_language = if c.language_en() { "zh".into() } else { "en".into() };
                }
                "lsp_auto" => c.lsp_auto_complete = !c.lsp_auto_complete,
                "lsp_signature" => c.lsp_signature_help = !c.lsp_signature_help,
                "lsp_hints" => c.lsp_inlay_hints = !c.lsp_inlay_hints,
                "plugins" => c.plugins_enabled = !c.plugins_enabled,
                _ => {}
            }
        }
        self.after_setting_change(key);
    }

    fn after_setting_change(&mut self, key: &str) {
        match key {
            "theme" => self.theme = crate::ui::theme::by_name(&self.config.theme),
            "vim" => {
                self.vim = crate::core::vim::Vim::new();
                if !self.config.vim {
                    self.vim.mode = crate::core::vim::Mode::Insert;
                }
            }
            "plugins" => self.apply_plugins_toggle(),
            "show_hidden" => {
                let hidden = self.config.show_hidden;
                self.sidebar.refresh(hidden);
            }
            "lsp_auto" if !self.config.lsp_auto_complete => self.pending_complete = None,
            "lsp_signature" if !self.config.lsp_signature_help => self.signature_help = None,
            "lsp_hints" if !self.config.lsp_inlay_hints => {
                self.inlay_hints.clear();
                self.lsp_hints_key = None;
            }
            _ => {}
        }
        let cfg = self.config.clone();
        for tab in &mut self.tabs {
            tab.apply_config(&cfg);
        }
        self.resize(self.layout.cols, self.layout.rows);
    }

    pub(crate) fn open_settings(&mut self) {
        self.settings = Some(crate::ui::app::SettingsPage {
            category: 0,
            selected: 0,
            query: String::new(),
            scroll: 0,
        });
    }

    fn settings_move(&mut self, delta: isize) {
        let len = self.settings_rows().len();
        if len == 0 {
            return;
        }
        let visible = self.settings_list_rect().h.max(1);
        let Some(page) = &mut self.settings else {
            return;
        };
        let next = (page.selected as isize + delta).clamp(0, len as isize - 1) as usize;
        page.selected = next;
        if next < page.scroll {
            page.scroll = next;
        }
        if next >= page.scroll + visible {
            page.scroll = next + 1 - visible;
        }
    }

    fn settings_category(&mut self, delta: isize) {
        let len = crate::ui::app::SETTING_CATEGORIES.len() as isize;
        if len == 0 {
            return;
        }
        if let Some(page) = &mut self.settings {
            let next = (page.category as isize + delta).rem_euclid(len);
            page.category = next as usize;
            page.selected = 0;
            page.scroll = 0;
            page.query.clear();
        }
    }

    pub(crate) fn settings_adjust(&mut self, dir: i32) {
        let rows = self.settings_rows();
        let Some(page) = &self.settings else {
            return;
        };
        let Some(row) = rows.get(page.selected) else {
            return;
        };
        let key = row.key;
        self.adjust_setting(key, dir);
    }

    pub(crate) fn handle_settings_key(&mut self, key: Key) {
        use KeyCode::*;
        let m = key.mods;
        match key.code {
            Esc => {
                let cleared = if let Some(page) = &mut self.settings {
                    if page.query.is_empty() {
                        false
                    } else {
                        page.query.clear();
                        page.selected = 0;
                        page.scroll = 0;
                        true
                    }
                } else {
                    false
                };
                if !cleared {
                    self.settings = None;
                    self.set_status("已退出设置");
                }
            }
            Char(',') if m.ctrl => {
                self.settings = None;
                self.set_status("已退出设置");
            }
            Up => self.settings_move(-1),
            Down => self.settings_move(1),
            PageUp => self.settings_move(-10),
            PageDown => self.settings_move(10),
            Tab if m.shift => self.settings_category(-1),
            Tab => self.settings_category(1),
            Left => self.settings_adjust(-1),
            Right => self.settings_adjust(1),
            Enter => self.settings_adjust(1),
            Char(' ') if m == Mods::none() => self.settings_adjust(1),
            Backspace => {
                if let Some(page) = &mut self.settings {
                    page.query.pop();
                    page.selected = 0;
                    page.scroll = 0;
                }
            }
            Char(c) if !m.ctrl && !m.alt => {
                if let Some(page) = &mut self.settings {
                    page.query.push(c);
                    page.selected = 0;
                    page.scroll = 0;
                }
            }
            _ => {}
        }
    }

    /// 设置页的鼠标：点分类、点条目切换、滚轮滚动。返回是否已处理。
    pub(crate) fn handle_settings_mouse(&mut self, mouse: Mouse) -> bool {
        let (x, y) = (mouse.x as usize, mouse.y as usize);
        match mouse.kind {
            MouseKind::Wheel => {
                self.settings_move(if mouse.wheel > 0 { -3 } else { 3 });
                return true;
            }
            MouseKind::Down => {}
            _ => return true,
        }
        let category = self.settings_category_rect();
        if category.contains(x, y) {
            let row = y.saturating_sub(category.y);
            if row < crate::ui::app::SETTING_CATEGORIES.len() {
                if let Some(page) = &mut self.settings {
                    page.category = row;
                    page.selected = 0;
                    page.scroll = 0;
                    page.query.clear();
                }
            }
            return true;
        }
        let list = self.settings_list_rect();
        if list.contains(x, y) {
            let index = (y - list.y) + self.settings.as_ref().map(|p| p.scroll).unwrap_or(0);
            if index < self.settings_rows().len() {
                if let Some(page) = &mut self.settings {
                    page.selected = index;
                }
                self.settings_adjust(1);
            }
            return true;
        }
        let area = self.settings_area();
        if !area.contains(x, y) {
            self.settings = None;
        }
        true
    }
    fn open_clipboard_history(&mut self) {
        if self.clip_history.is_empty() {
            self.set_error("剪贴板历史为空：复制或粘贴后会出现记录");
            return;
        }
        let items: Vec<ListItem> = self
            .clip_history
            .iter()
            .map(|text| {
                let first: String = text
                    .lines()
                    .next()
                    .unwrap_or("")
                    .chars()
                    .take(60)
                    .collect();
                ListItem {
                    title: if first.is_empty() {
                        "（空行）".to_string()
                    } else {
                        first
                    },
                    detail: format!("{} 字符", text.chars().count()),
                    command: None,
                    path: None,
                    line: None,
                    value: Some(text.clone()),
                }
            })
            .collect();
        self.open_list(ListState::new(ListKind::Clipboard, "剪贴板历史", items));
    }

    pub(crate) fn push_clip_history(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        self.clip_history.retain(|t| t != text);
        self.clip_history.insert(0, text.to_string());
        self.clip_history.truncate(20);
    }

    fn submit_prompt(&mut self, state: PromptState) {
        let input = state.input.trim().to_string();
        match state.kind {
            PromptKind::SaveAs => {
                if input.is_empty() {
                    self.set_error("文件名不能为空");
                    self.overlay = Overlay::Prompt(state);
                    return;
                }
                let path = self.resolve_path(&input);
                self.tab_mut().doc.path = Some(path.clone());
                match self.tab_mut().save_document() {
                    Ok(()) => {
                        self.config.push_recent(&path);
                        self.set_status(format!("已保存 {}", path.display()));
                        self.tab_mut().git_revision = 0;
                        self.remote_upload_if_mapped(&path);
                        self.fire_plugin_event("save", &path);
                        if let Some(action) = self.pending_save_action.take() {
                            self.apply_confirm(action, 0);
                        }
                    }
                    Err(e) => {
                        self.set_error(e);
                        self.overlay = Overlay::Prompt(state);
                    }
                }
            }
            PromptKind::OpenPath => {
                let path = self.resolve_path(&input);
                if path.is_dir() {
                    self.cwd = path.clone();
                    self.sidebar.root = path;
                    self.sidebar.refresh(self.config.show_hidden);
                    self.set_status(format!("目录：{}", self.cwd.display()));
                } else if let Err(e) = self.open_file(&path) {
                    self.set_error(e);
                    self.overlay = Overlay::Prompt(state);
                }
            }
            PromptKind::NewFile => {
                let path = self.resolve_path(&input);
                let mut doc = Document::empty();
                doc.path = Some(path.clone());
                doc.language = Language::from_path(&path);
                self.tabs.push(Tab::new(doc, &self.config));
                self.active = self.tabs.len() - 1;
                self.set_status(format!("新建 {}", path.display()));
            }
            PromptKind::GotoLine => match input.parse::<usize>() {
                Ok(line) if line >= 1 => {
                    let target = (line - 1).min(self.doc().line_count().saturating_sub(1));
                    self.doc_mut().set_cursor(Pos::new(target, 0));
                    self.ensure_visible();
                    self.set_status(format!("转到第 {line} 行"));
                }
                _ => self.set_error("行号无效"),
            },
            PromptKind::CompareFile => {
                let path = self.resolve_path(&input);
                match std::fs::read(&path) {
                    Ok(bytes) => {
                        let decoded = crate::core::encoding::decode(&bytes);
                        let other: Vec<String> = decoded.text.split('\n').map(|s| s.to_string()).collect();
                        let current = self.doc().lines.clone();
                        let name = self.doc().title();
                        let text = unified_diff(
                            &other,
                            &current,
                            &path.to_string_lossy(),
                            &name,
                            2,
                        );
                        let mut doc = Document::from_text(&text, None);
                        doc.language = Language::Diff;
                        doc.read_only = true;
                        let mut tab = Tab::new(doc, &self.config);
                        tab.preview = true;
                        self.tabs.push(tab);
                        self.active = self.tabs.len() - 1;
                        self.set_status("差异视图（只读）");
                    }
                    Err(e) => {
                        self.set_error(format!("读取失败：{e}"));
                        self.overlay = Overlay::Prompt(state);
                    }
                }
            }
            PromptKind::AddFolder => {
                let path = self.resolve_path(&input);
                if !path.is_dir() {
                    self.set_error("不是有效的文件夹");
                    self.overlay = Overlay::Prompt(state);
                    return;
                }
                self.sidebar.add_root(path.clone());
                self.config.workspace_folders = self.sidebar.roots.clone();
                self.quick_files.clear();
                self.set_status(format!("已添加工作区文件夹 {}", path.display()));
            }
            PromptKind::GitCommit => {
                let Some(root) = self.git.root.clone() else {
                    self.set_error("不在 Git 仓库中");
                    return;
                };
                match crate::vcs::git::commit_all(&root, &input) {
                    Ok(message) => {
                        self.git.refresh(&self.cwd);
                        self.set_status(format!("Git 提交：{message}"));
                    }
                    Err(e) => self.set_error(e),
                }
            }
            PromptKind::GitBranchCreate | PromptKind::GitBranchDelete | PromptKind::GitMerge => {
                self.git.refresh(&self.cwd);
                let Some(root) = self.git.root.clone() else {
                    self.set_error("不在 Git 仓库中");
                    return;
                };
                let name = input.trim().to_string();
                if name.is_empty() {
                    self.set_error("分支名不能为空");
                    return;
                }
                let result = match state.kind {
                    PromptKind::GitBranchCreate => {
                        crate::vcs::git::create_branch(&root, &name)
                    }
                    PromptKind::GitBranchDelete => {
                        crate::vcs::git::delete_branch(&root, &name)
                    }
                    _ => crate::vcs::git::merge(&root, &name),
                };
                match result {
                    Ok(text) => {
                        self.git.refresh(&self.cwd);
                        let first = text.lines().next().unwrap_or("").trim().to_string();
                        if first.is_empty() {
                            self.set_status(format!("Git 操作完成：{name}"));
                        } else {
                            self.set_status(format!("Git：{first}"));
                        }
                    }
                    Err(error) => self.set_error(format!("Git 操作失败：{error}")),
                }
            }
            PromptKind::ExcelSheetAdd
            | PromptKind::ExcelSheetRename
            | PromptKind::ExcelFilter => {
                if !self.excel_submit_prompt(state.kind, &input) {
                    self.overlay = Overlay::Prompt(state);
                }
            }
            PromptKind::WorkspaceReplace => match self.workspace_replace_all(&input) {
                Ok(message) => self.set_status(message),
                Err(error) => {
                    self.set_error(error);
                    self.overlay = Overlay::Prompt(state);
                }
            },
            PromptKind::WorkspaceInclude | PromptKind::WorkspaceExclude => {
                let include = state.kind == PromptKind::WorkspaceInclude;
                if include {
                    self.config.workspace_include = input;
                } else {
                    self.config.workspace_exclude = input;
                }
                self.refresh_workspace_options();
            }
            PromptKind::ExplorerNewFile | PromptKind::ExplorerNewFolder => {
                let folder = state.kind == PromptKind::ExplorerNewFolder;
                let base = self.explorer_target.clone().unwrap_or_else(|| self.cwd.clone());
                let raw = Path::new(&input);
                let path = if raw.is_absolute() {
                    raw.to_path_buf()
                } else {
                    base.join(raw)
                };
                let result = if folder {
                    std::fs::create_dir_all(&path).map(|_| ())
                } else {
                    if let Some(parent) = path.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    match std::fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(&path)
                    {
                        Ok(_) => Ok(()),
                        Err(error) => Err(error),
                    }
                };
                match result {
                    Ok(()) => {
                        self.sidebar.refresh(self.config.show_hidden);
                        if !folder {
                            if let Err(error) = self.open_file(&path) {
                                self.set_error(error);
                            } else {
                                self.focus = Focus::Editor;
                            }
                        }
                        self.set_status(format!(
                            "已创建{} {}",
                            if folder { "文件夹" } else { "文件" },
                            path.display()
                        ));
                    }
                    Err(error) => {
                        self.set_error(format!("创建失败：{error}"));
                        self.overlay = Overlay::Prompt(state);
                    }
                }
            }
            PromptKind::ExplorerRename => {
                let Some(old) = self.explorer_target.clone() else {
                    self.set_error("没有可重命名的目标");
                    return;
                };
                if input.contains('/') || input.contains('\\') {
                    self.set_error("重命名只接受名称，不能包含路径分隔符");
                    self.overlay = Overlay::Prompt(state);
                    return;
                }
                let new_path = old.with_file_name(&input);
                if new_path == old {
                    return;
                }
                if new_path.exists() {
                    self.set_error(format!("目标已存在：{}", new_path.display()));
                    self.overlay = Overlay::Prompt(state);
                    return;
                }
                match std::fs::rename(&old, &new_path) {
                    Ok(()) => {
                        for tab in &mut self.tabs {
                            if tab.doc.path.as_deref() == Some(old.as_path()) {
                                tab.doc.path = Some(new_path.clone());
                            }
                        }
                        self.sidebar.refresh(self.config.show_hidden);
                        self.set_status(format!("已重命名为 {}", new_path.display()));
                    }
                    Err(error) => {
                        self.set_error(format!("重命名失败：{error}"));
                        self.overlay = Overlay::Prompt(state);
                    }
                }
            }
            PromptKind::LspRename => {
                if input.is_empty() || input.contains(char::is_whitespace) {
                    self.set_error("符号名不能为空或包含空白");
                    self.overlay = Overlay::Prompt(state);
                } else {
                    self.lsp_apply_rename(&input);
                }
            }
            PromptKind::LspSymbolQuery => self.lsp_workspace_symbols(&input),
            PromptKind::RemoteHostAdd => match self.add_remote_host(&input) {
                Ok(()) => self.set_status(format!("已添加远程主机 {input}")),
                Err(e) => {
                    self.set_error(e);
                    self.overlay = Overlay::Prompt(state);
                }
            },
            PromptKind::RemoteCommand => self.run_remote_command(&input),
            PromptKind::RemoteFileOpen => self.open_remote_file(&input),
            PromptKind::RemoteUploadPath => self.upload_remote(&input),
            PromptKind::PluginInput => {
                let value = Json::String(input.clone()).dump();
                if let Some((id, _)) = self.plugin_pending.take() {
                    if let Err(e) = self.plugin.resolve(id, &value) {
                        self.set_error(e);
                    }
                    self.process_plugin_requests();
                }
            }
        }
    }

    pub fn apply_confirm(&mut self, action: ConfirmAction, selected: usize) {
        match action {
            ConfirmAction::CloseTab(index) => match selected {
                0 => {
                    if index >= self.tabs.len() {
                        return;
                    }
                    self.active = index;
                    if self.doc().path.is_none() {
                        self.pending_save_action = Some(ConfirmAction::CloseTab(index));
                        self.open_prompt(PromptKind::SaveAs, "另存为", "");
                        return;
                    }
                    match self.tab_mut().save_document() {
                        Ok(()) => self.close_tab_public(index),
                        Err(e) => self.set_error(e),
                    }
                }
                1 => self.close_tab_public(index),
                _ => {}
            },
            ConfirmAction::Quit => match selected {
                0 => {
                    for index in 0..self.tabs.len() {
                        if !self.tabs[index].doc.is_dirty() {
                            continue;
                        }
                        self.active = index;
                        if self.tabs[index].doc.path.is_none() {
                            self.pending_save_action = Some(ConfirmAction::Quit);
                            self.open_prompt(PromptKind::SaveAs, "另存为", "");
                            return;
                        }
                        if let Err(e) = self.tabs[index].save_document() {
                            self.set_error(e);
                            return;
                        }
                    }
                    self.finish_quit();
                }
                1 => self.finish_quit(),
                _ => {}
            },
            ConfirmAction::ExcelSheetDelete(index) => {
                if selected != 0 {
                    return;
                }
                let Some(book) = &mut self.tab_mut().excel else {
                    return;
                };
                match book.delete_sheet(index) {
                    Ok(()) => {
                        self.excel_row = 0;
                        self.excel_col = 0;
                        self.excel_anchor = None;
                        self.excel_editing = false;
                        self.excel_input.clear();
                        self.doc_mut().touch_meta();
                        self.refresh_active(true);
                        self.set_status("已删除工作表");
                    }
                    Err(e) => self.set_error(e),
                }
            }
            ConfirmAction::ExplorerDelete(path) => {
                if selected != 0 {
                    return;
                }
                let result = if path.is_dir() {
                    std::fs::remove_dir_all(&path)
                } else {
                    std::fs::remove_file(&path)
                };
                match result {
                    Ok(()) => {
                        let mut kept = Vec::new();
                        for tab in self.tabs.drain(..) {
                            let inside = tab
                                .doc
                                .path
                                .as_deref()
                                .map(|tab_path| tab_path.starts_with(&path))
                                .unwrap_or(false);
                            if !inside {
                                kept.push(tab);
                            }
                        }
                        self.tabs = kept;
                        if self.tabs.is_empty() {
                            self.tabs.push(Tab::new(Document::empty(), &self.config));
                        }
                        self.active = self.active.min(self.tabs.len() - 1);
                        self.sidebar.refresh(self.config.show_hidden);
                        self.resize(self.layout.cols, self.layout.rows);
                        self.set_status(format!("已删除 {}", path.display()));
                    }
                    Err(error) => self.set_error(format!("删除失败：{error}")),
                }
            }
            ConfirmAction::GitDiscard(path) => {
                if selected != 0 {
                    return;
                }
                let Some(root) = self.git.root.clone() else {
                    return;
                };
                let relative = path
                    .strip_prefix(&root)
                    .map(|relative| relative.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_else(|_| path.to_string_lossy().replace('\\', "/"));
                match crate::vcs::git::discard(&root, &[relative.clone()]) {
                    Ok(()) => {
                        self.git.refresh(&self.cwd);
                        self.clamp_git_selection();
                        // 已打开的文件重新从磁盘载入，避免保存时把丢弃的改动写回。
                        if let Some(index) = self
                            .tabs
                            .iter()
                            .position(|tab| tab.doc.path.as_deref() == Some(path.as_path()))
                        {
                            let config = self.config.clone();
                            let width = self.text_width();
                            let language = self.tabs[index].doc.language;
                            if let Ok(mut doc) = Document::load(&path) {
                                doc.language = language;
                                self.tabs[index].doc = doc;
                                self.tabs[index].refresh(&config, width, true);
                            }
                        }
                        self.set_status(format!("已丢弃 {relative} 的改动"));
                    }
                    Err(error) => self.set_error(error),
                }
            }
            ConfirmAction::Paste => {
                if selected == 0 {
                    if let Some(text) = self.pending_paste.take() {
                        self.doc_mut().insert_text(&text);
                        self.after_change();
                    }
                } else {
                    self.pending_paste = None;
                }
            }
        }
    }

    fn resolve_path(&self, input: &str) -> PathBuf {
        let expanded = expand_env(input);
        let path = PathBuf::from(&expanded);
        if path.is_absolute() {
            path
        } else {
            self.cwd.join(path)
        }
    }

    // ------------------------------------------------------------ 浮层鼠标

    pub fn handle_overlay_mouse(&mut self, mouse: Mouse) {
        let (x, y) = (mouse.x as usize, mouse.y as usize);
        let overlay = std::mem::replace(&mut self.overlay, Overlay::None);
        match overlay {
            Overlay::Menu(state) => {
                let index = state.index;
                if mouse.kind == MouseKind::Down {
                    if let Some(hit) = menu_item_at(self, index, x, y) {
                        if let Some(cmd) = self
                            .menus()
                            .get(index)
                            .and_then(|menu| menu.items.get(hit))
                            .map(|item| item.cmd)
                        {
                            self.execute(cmd);
                        }
                        return;
                    }
                    if !menu_rect(self, index).contains(x, y) {
                        return;
                    }
                }
                self.overlay = Overlay::Menu(state);
            }
            Overlay::Keys(state) => {
                let rect = keys_rect(self);
                if mouse.kind == MouseKind::Down {
                    if !rect.contains(x, y) {
                        return;
                    }
                    // 点标题栏（Esc 关闭）直接关掉。
                    if y <= rect.y {
                        return;
                    }
                    let hints = crate::ui::app::KEY_HINTS;
                    let rows = (hints.len() + 1) / 2;
                    let col_w = rect.w.saturating_sub(2) / 2;
                    let column = (x.saturating_sub(rect.x + 1) / col_w.max(1)).min(1);
                    let row = y.saturating_sub(rect.y + 1);
                    if let Some(hint) = hints.get(column * rows.max(1) + row) {
                        self.execute(hint.cmd);
                        return;
                    }
                }
                self.overlay = Overlay::Keys(state);
            }
            Overlay::Context(mut state) => {
                let rect = context_rect(self);
                match mouse.kind {
                    MouseKind::Down => {
                        if !rect.contains(x, y) {
                            return;
                        }
                        if y > rect.y && y + 1 < rect.bottom() {
                            let index = y - rect.y - 1;
                            if let Some(item) = state.items.get(index) {
                                let cmd = item.cmd;
                                self.execute(cmd);
                                return;
                            }
                        }
                    }
                    MouseKind::Move | MouseKind::Drag => {
                        if rect.contains(x, y) && y > rect.y {
                            let index = y - rect.y - 1;
                            if index < state.items.len() {
                                state.selected = index;
                            }
                        }
                    }
                    _ => {}
                }
                self.overlay = Overlay::Context(state);
            }
            Overlay::Cmdline(state) => {
                if mouse.kind == MouseKind::Down {
                    return;
                }
                self.overlay = Overlay::Cmdline(state);
            }
            Overlay::List(mut state) => {
                let rect = list_rect(self);
                if !rect.contains(x, y) {
                    if mouse.kind == MouseKind::Down {
                        return;
                    }
                    self.overlay = Overlay::List(state);
                    return;
                }
                let inner_y = y.saturating_sub(rect.y + 2);
                match mouse.kind {
                    MouseKind::Down => {
                        let index = state.scroll + inner_y;
                        if index < state.filtered.len() {
                            state.selected = index;
                        }
                        self.overlay = Overlay::List(state);
                    }
                    MouseKind::DoubleClick => {
                        let index = state.scroll + inner_y;
                        if index < state.filtered.len() {
                            let item = state.items[state.filtered[index]].clone();
                            let kind = state.kind;
                            self.activate_list_item(&kind, item);
                        }
                    }
                    MouseKind::Wheel => {
                        if mouse.wheel > 0 {
                            state.move_selection(-3);
                        } else {
                            state.move_selection(3);
                        }
                        self.overlay = Overlay::List(state);
                    }
                    _ => {
                        self.overlay = Overlay::List(state);
                    }
                }
            }
            Overlay::Confirm(state) => {
                if mouse.kind == MouseKind::Down && !confirm_rect(self).contains(x, y) {
                    return;
                }
                self.overlay = Overlay::Confirm(state);
            }
            other => {
                self.overlay = other;
            }
        }
    }

    // ------------------------------------------------------------ Ex 命令行

    /// 执行 `:` 命令行（支持范围、:s、:set、:sp、:term 等）。
    pub fn exec_ex(&mut self, line: &str) {
        let line = line.trim().to_string();
        if line.is_empty() {
            return;
        }
        self.ex_history.retain(|item| item != &line);
        self.ex_history.insert(0, line.clone());
        self.ex_history.truncate(50);

        let mut rest = line.as_str();
        let mut first = self.doc().primary().pos.line;
        let mut last = first;
        if let Some(tail) = rest.strip_prefix('%') {
            first = 0;
            last = self.doc().line_count().saturating_sub(1);
            rest = tail.trim_start();
        } else if let Some(tail) = rest.strip_prefix("'<,'>") {
            if let Some((a, b)) = self.vim.last_visual() {
                first = a.line.min(b.line);
                last = a.line.max(b.line);
            }
            rest = tail.trim_start();
        } else if let Some((lo, hi, tail)) = parse_line_range(rest, self.doc().line_count()) {
            first = lo;
            last = hi;
            rest = tail;
        }
        // 命令名只取字母（含 `!`），剩余部分即参数：`s/a/b/g`、`q!` 都能解析。
        let name_len = rest
            .chars()
            .take_while(|c| c.is_ascii_alphabetic() || *c == '!')
            .count();
        let name = rest[..name_len].trim();
        let args = rest[name_len..].trim();

        // `:42` 直接跳转到第 42 行。
        if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) {
            let target = rest.parse::<usize>().unwrap_or(1).saturating_sub(1);
            let target = target.min(self.doc().line_count().saturating_sub(1));
            self.doc_mut().set_cursor(Pos::new(target, 0));
            self.ensure_visible();
            return;
        }

        match name {
            "w" | "write" => {
                if args.is_empty() {
                    self.save_or_prompt();
                } else {
                    let path = PathBuf::from(args);
                    match self.doc_mut().save_to(&path) {
                        Ok(()) => {
                            self.config.push_recent(&path);
                            self.set_status(format!("已保存 {}", path.display()));
                        }
                        Err(e) => self.set_error(e),
                    }
                }
            }
            "wq" | "x" | "xit" => {
                self.save_or_prompt();
                if !self.doc().is_dirty() {
                    self.execute(Cmd::Quit);
                }
            }
            "q" | "quit" => self.execute(Cmd::Quit),
            "q!" | "quit!" | "qa!" | "qa" => {
                self.running = false;
            }
            "e" | "edit" => {
                if !args.is_empty() {
                    if let Err(e) = self.open_file(&PathBuf::from(args)) {
                        self.set_error(e);
                    }
                }
            }
            "noh" | "nohlsearch" => {
                self.search_engine = None;
                self.set_status("已清除搜索高亮");
            }
            "set" => self.exec_set(args),
            "sp" | "split" => self.split_editor(false),
            "vs" | "vsplit" | "vnew" => self.split_editor(true),
            "only" | "close" => {
                if self.split.is_some() {
                    self.close_split();
                } else {
                    self.execute(Cmd::CloseTab);
                }
            }
            "term" | "terminal" => self.toggle_terminal(),
            "s" | "substitute" => self.exec_substitute(first, last, args),
            "sort" => self.exec_sort(first, last, false),
            "sort!" | "sortn" => self.exec_sort(first, last, true),
            "normal" | "norm" => {
                let keys = args.to_string();
                let width = self.config.tab_width;
                let vim = &mut self.vim;
                let doc = &mut self.tabs[self.active].doc;
                vim.feed_keys(doc, &keys, width);
                self.after_edit();
            }
            "tabnew" | "tabedit" => self.execute(Cmd::NewFile),
            "bn" | "bnext" | "tabnext" => self.cycle_tab(1),
            "bp" | "bprev" | "tabprev" => self.cycle_tab(-1),
            "bd" | "bdelete" => self.execute(Cmd::CloseTab),
            "theme" | "color" | "colorscheme" => {
                if args.is_empty() {
                    self.set_status(format!("当前主题：{}", self.config.theme));
                } else {
                    self.config.theme = args.to_string();
                    self.theme = crate::ui::theme::by_name(args);
                    self.set_status(format!("主题：{args}"));
                }
            }
            "help" => self.help_open = true,
            "marks" | "reg" | "registers" => {
                let names = self.vim.register_names();
                if names.is_empty() {
                    self.set_status("寄存器为空");
                } else {
                    self.set_status(format!(
                        "寄存器：{}",
                        names.iter().map(|c| c.to_string()).collect::<Vec<_>>().join(" ")
                    ));
                }
            }
            "files" | "ls" | "buffers" => {
                let titles: Vec<String> = self
                    .tabs
                    .iter()
                    .enumerate()
                    .map(|(index, tab)| format!("{}{}", if index == self.active { "% " } else { "  " }, tab.doc.title()))
                    .collect();
                self.set_status(titles.join("  "));
            }
            _ => self.set_error(format!("未知命令：{name}")),
        }
        self.vim.mode = crate::core::vim::Mode::Normal;
    }

    fn exec_set(&mut self, args: &str) {
        let mut message = String::new();
        for item in args.split_whitespace() {
            let (negate, body) = if let Some(rest) = item.strip_prefix("no") {
                (true, rest)
            } else {
                (false, item)
            };
            let (key, value) = match body.split_once('=') {
                Some((k, v)) => (k, Some(v)),
                None => (body, None),
            };
            match (key, value) {
                ("wrap", _) => self.config.wrap = !negate,
                ("et" | "expandtab", _) => self.config.use_spaces = !negate,
                ("ai" | "autoindent", _) => self.config.auto_indent = !negate,
                ("nu" | "number", _) => {}
                ("ic" | "ignorecase", _) => {}
                ("hls" | "hlsearch", _) => {
                    if negate {
                        self.search_engine = None;
                    }
                }
                ("ts" | "tabstop", Some(v)) => {
                    if let Ok(n) = v.parse::<usize>() {
                        self.config.tab_width = n.clamp(1, 16);
                    }
                }
                ("sw" | "shiftwidth", Some(v)) => {
                    if let Ok(n) = v.parse::<usize>() {
                        self.config.tab_width = n.clamp(1, 16);
                    }
                }
                ("vim", _) => self.config.vim = !negate,
                ("indentguides", _) => self.config.indent_guides = !negate,
                ("minimap", _) => self.config.minimap = !negate,
                ("sidebar", _) => self.config.sidebar = !negate,
                ("theme", Some(v)) => {
                    self.config.theme = v.to_string();
                    self.theme = crate::ui::theme::by_name(v);
                }
                ("rnu" | "relativenumber" | "list" | "paste", _) => {}
                _ => message = format!("未知选项：{item}"),
            }
        }
        let cfg = self.config.clone();
        for tab in &mut self.tabs {
            tab.apply_config(&cfg);
        }
        self.resize(self.layout.cols, self.layout.rows);
        if !message.is_empty() {
            self.set_error(message);
        }
    }

    fn exec_substitute(&mut self, first: usize, last: usize, args: &str) {
        let Some((pattern, replacement, flags)) = parse_substitute(args) else {
            self.set_error("替换格式：s/旧/新/g");
            return;
        };
        if pattern.is_empty() {
            self.set_error("替换模式为空");
            return;
        }
        let options = SearchOptions {
            case_sensitive: flags.contains('i'),
            whole_word: false,
            regex: true,
        };
        let engine = SearchEngine::new(&pattern, options);
        let replacement = vim_replacement(&replacement);
        let limit = if flags.contains('g') {
            usize::MAX
        } else {
            1
        };
        let last = last.min(self.doc().line_count().saturating_sub(1));
        let mut edits: Vec<(Pos, Pos, String)> = Vec::new();
        let mut total = 0usize;
        for line in first..=last {
            let text = self.doc().line(line).to_string();
            let (new_text, count) = engine.replace_in_line(&text, &replacement, limit);
            if count > 0 && new_text != text {
                total += count;
                let len = text.chars().count();
                edits.push((Pos::new(line, 0), Pos::new(line, len), new_text));
            }
        }
        if edits.is_empty() {
            self.set_status(format!("未匹配：{pattern}"));
            return;
        }
        self.doc_mut().replace_ranges_each(&edits);
        self.after_edit();
        let scope = if first == 0 && last + 1 == self.doc().line_count() {
            format!("{total} 处")
        } else {
            format!("{total} 处（第 {}–{} 行）", first + 1, last + 1)
        };
        self.set_status(format!("已替换 {scope}"));
    }

    fn exec_sort(&mut self, first: usize, last: usize, numeric: bool) {
        let last = last.min(self.doc().line_count().saturating_sub(1));
        if last <= first {
            return;
        }
        let mut lines: Vec<String> = (first..=last)
            .map(|line| self.doc().line(line).to_string())
            .collect();
        if numeric {
            lines.sort_by(|a, b| {
                let na = a.trim().parse::<f64>().unwrap_or(f64::MAX);
                let nb = b.trim().parse::<f64>().unwrap_or(f64::MAX);
                na.partial_cmp(&nb).unwrap_or(std::cmp::Ordering::Equal)
            });
        } else {
            lines.sort();
        }
        let text = lines.join("\n");
        let end = Pos::new(last, self.doc().line_chars(last));
        self.doc_mut().replace_ranges(&[(Pos::new(first, 0), end)], &text);
        self.after_edit();
        self.set_status("已排序");
    }

    // ------------------------------------------------------------ 几何

    pub fn list_rect(&self) -> Rect {
        list_rect(self)
    }

    pub fn menu_rect(&self, index: usize) -> Rect {
        menu_rect(self, index)
    }

    pub fn keys_rect(&self) -> Rect {
        keys_rect(self)
    }

    pub fn context_rect(&self) -> Rect {
        context_rect(self)
    }

    // ------------------------------------------------------------ 可点击提示条

    /// 面板标题 / 标签行 / 状态栏上的键位提示：画在这里，也在这里点。
    pub fn hints(&self) -> Vec<Hint> {
        let items = self.status_items();
        self.hints_with(&items)
    }

    pub(crate) fn hints_with(&self, items: &[StatusItem]) -> Vec<Hint> {
        let mut out = Vec::new();
        let width_of = crate::render::canvas::text_width;

        // 焦点 pane 的顶边右侧：从右往左排 F1 / Ctrl+F / Ctrl+S。
        let pane = self
            .layout
            .panes
            .get(self.group)
            .copied()
            .unwrap_or_default();
        let editor = pane.editor;
        let title_w = width_of(&Self::tab_title(self.tab())) + 4;
        let mut right = editor.right().saturating_sub(2);
        let chips: [(&'static str, HintTarget); 3] = [
            ("F1 键位", HintTarget::Keys),
            ("Ctrl+F 查找", HintTarget::Cmd(Cmd::Find)),
            ("Ctrl+S 保存", HintTarget::Cmd(Cmd::Save)),
        ];
        for (label, target) in chips {
            let width = width_of(label) + 2;
            if right < width + 2 || right.saturating_sub(width) < editor.x + title_w + 4 {
                break;
            }
            let x = right - width;
            out.push(Hint {
                rect: Rect {
                    x,
                    y: editor.y,
                    w: width,
                    h: 1,
                },
                label,
                target,
                bg: self.theme.bg,
            });
            right = x.saturating_sub(1);
        }

        // 侧栏 pane 顶边右侧。
        if let Some(side) = self.layout.sidebar {
            let label = "Ctrl+B 隐藏";
            let width = width_of(label) + 2;
            let title_w = width_of(" 资源管理器 ") + 4;
            if side.w > width + title_w + 4 {
                out.push(Hint {
                    rect: Rect {
                        x: side.right() - 2 - width,
                        y: side.y,
                        w: width,
                        h: 1,
                    },
                    label,
                    target: HintTarget::Cmd(Cmd::ToggleSidebar),
                    bg: self.theme.panel_bg,
                });
            }
        }

        // 编辑器标签行右侧。
        let tabs = pane.tabs;
        let label = "Ctrl+N 新建";
        let width = width_of(label) + 2;
        let last_end = if self.tabs.is_empty() {
            tabs.x
        } else {
            let (x, w) = self.tab_span(self.tabs.len() - 1);
            x + w
        };
        if tabs.right() > last_end + width + 3 {
            out.push(Hint {
                rect: Rect {
                    x: tabs.right() - 1 - width,
                    y: tabs.y,
                    w: width,
                    h: 1,
                },
                label,
                target: HintTarget::Cmd(Cmd::NewFile),
                bg: self.theme.tab_inactive_bg,
            });
        }

        // VSCode 顶部标签行右侧。
        if let Some(tabs) = self.layout.tabs_top {
            let label = "Ctrl+N 新建";
            let width = width_of(label) + 2;
            let mut last_end = tabs.x;
            for tab in &self.tabs {
                last_end += width_of(&Self::tab_label(tab)) + 4;
            }
            if tabs.right() > last_end + width + 3 {
                out.push(Hint {
                    rect: Rect {
                        x: tabs.right() - 1 - width,
                        y: tabs.y,
                        w: width,
                        h: 1,
                    },
                    label,
                    target: HintTarget::Cmd(Cmd::NewFile),
                    bg: self.theme.tab_inactive_bg,
                });
            }
        }

        out.extend(self.status_hints_with(items));
        out
    }

    /// 状态栏左侧的常用键位（没有消息时显示）。
    fn status_hints_with(&self, items: &[StatusItem]) -> Vec<Hint> {
        let rect = self.layout.status;
        if self.status_visible() {
            return Vec::new();
        }
        let message_x = rect.x + crate::render::canvas::text_width(" TEXTM ") + 1;
        let pill_left = items
            .iter()
            .map(|item| item.rect.x)
            .min()
            .unwrap_or(rect.right());
        let avail = pill_left.saturating_sub(message_x + 1);
        // 空间不够时优先保留「菜单 + 设置」这一对按钮。
        let chips: &[(&'static str, HintTarget)] = if avail >= 64 {
            &[
                ("Ctrl+S 保存", HintTarget::Cmd(Cmd::Save)),
                ("Ctrl+Shift+P 命令", HintTarget::Cmd(Cmd::Palette)),
                ("F1 键位", HintTarget::Keys),
                ("F4 菜单", HintTarget::Menu),
                ("Ctrl+, 设置", HintTarget::Cmd(Cmd::OpenSettings)),
            ]
        } else if avail >= 38 {
            &[
                ("F1 键位", HintTarget::Keys),
                ("F4 菜单", HintTarget::Menu),
                ("Ctrl+, 设置", HintTarget::Cmd(Cmd::OpenSettings)),
            ]
        } else if avail >= 22 {
            &[
                ("F4 菜单", HintTarget::Menu),
                ("设置", HintTarget::Cmd(Cmd::OpenSettings)),
            ]
        } else {
            &[]
        };
        let mut out = Vec::new();
        let mut x = message_x;
        for (label, target) in chips.iter() {
            let width = crate::render::canvas::text_width(label) + 2;
            if x + width + 1 > pill_left {
                break;
            }
            out.push(Hint {
                rect: Rect {
                    x,
                    y: rect.y,
                    w: width,
                    h: 1,
                },
                label,
                target: *target,
                bg: self.theme.status_bg,
            });
            x += width + 1;
        }
        out
    }

    /// 状态栏右侧信息段（右对齐），带可点击动作。
    pub fn status_items(&self) -> Vec<StatusItem> {
        let rect = self.layout.status;
        let doc = self.doc();
        let mut items: Vec<(String, Option<HintTarget>)> = Vec::new();
        if self.tab().excel.is_none() {
            if let Some(selection) = doc.selections_text() {
                let chars = selection.chars().count();
                items.push((format!("选中 {chars}"), None));
            }
        }
        if let Some(book) = &self.tab().excel {
            let reference = format!(
                "{}{}",
                crate::xlsx::column_name(self.excel_col),
                self.excel_row + 1
            );
            items.push((reference, None));
            items.push((book.sheet().name.clone(), None));
        } else {
            let pos = doc.primary().pos;
            items.push((
                format!("行 {}, 列 {}", pos.line + 1, pos.col + 1),
                Some(HintTarget::Cmd(Cmd::GotoLine)),
            ));
        }
        items.push((
            format!(
                "{}:{}",
                if self.config.use_spaces { "空格" } else { "Tab" },
                self.config.tab_width
            ),
            None,
        ));
        if self.overwrite {
            items.push(("改写".into(), None));
        }
        if self.config.git && self.git.root.is_some() {
            items.push((self.git.branch.clone(), Some(HintTarget::Cmd(Cmd::GitBranches))));
        }
        items.push((
            doc.encoding.label().to_string(),
            Some(HintTarget::Cmd(Cmd::EncodingPicker)),
        ));
        items.push((
            doc.eol.label().to_string(),
            Some(HintTarget::Cmd(Cmd::EolPicker)),
        ));
        items.push((
            self.tab().format_label().to_string(),
            Some(HintTarget::Cmd(Cmd::LanguagePicker)),
        ));
        if !self.lsp.status.is_empty() {
            items.push((self.lsp.status.clone(), None));
        }
        let (errors, warnings) = self.problem_counts();
        if errors + warnings > 0 {
            items.push((
                format!("ⓧ {errors}  ⚠ {warnings}"),
                Some(HintTarget::Cmd(Cmd::Problems)),
            ));
        }
        if !self.debug.status.is_empty() {
            items.push((format!("调试：{}", self.debug.status), None));
        }
        if !self.plugin_status.is_empty() {
            items.push((self.plugin_status.clone(), None));
        }
        if !self.vim.pending.is_empty() {
            items.push((self.vim.pending.clone(), None));
        }

        let mut out = Vec::new();
        let mut right = rect.right();
        for (label, target) in items.into_iter().rev() {
            let text = format!(" {label} ");
            let width = crate::render::canvas::text_width(&text);
            if right < width + 1 {
                break;
            }
            right -= width;
            out.push(StatusItem {
                rect: Rect {
                    x: right,
                    y: rect.y,
                    w: width,
                    h: 1,
                },
                label: text,
                target,
            });
            right = right.saturating_sub(1);
        }
        out.reverse();
        out
    }

    pub fn find_rect(&self) -> Rect {
        find_rect(self)
    }

    pub fn confirm_rect(&self) -> Rect {
        confirm_rect(self)
    }

    pub fn prompt_rect(&self) -> Rect {
        prompt_rect(self)
    }

    // ------------------------------------------------------------ Git

    fn explorer_dir(&self) -> PathBuf {
        if let Some(entry) = self.sidebar.entries.get(self.sidebar.selected) {
            if entry.is_dir {
                entry.path.clone()
            } else {
                entry
                    .path
                    .parent()
                    .map(|path| path.to_path_buf())
                    .unwrap_or_else(|| self.cwd.clone())
            }
        } else {
            self.cwd.clone()
        }
    }

    fn explorer_new(&mut self, file: bool) {
        self.explorer_target = Some(self.explorer_dir());
        let (kind, title) = if file {
            (PromptKind::ExplorerNewFile, "新建文件")
        } else {
            (PromptKind::ExplorerNewFolder, "新建文件夹")
        };
        self.open_prompt(kind, title, "");
    }

    fn explorer_rename_prompt(&mut self) {
        let Some(entry) = self.sidebar.entries.get(self.sidebar.selected).cloned() else {
            self.set_error("请先在资源管理器中选择文件");
            return;
        };
        if entry.path == self.cwd {
            self.set_error("不能重命名工程根目录");
            return;
        }
        self.explorer_target = Some(entry.path.clone());
        let name = entry
            .path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default();
        self.open_prompt(PromptKind::ExplorerRename, "重命名", &name);
    }

    fn explorer_delete(&mut self) {
        let Some(entry) = self.sidebar.entries.get(self.sidebar.selected).cloned() else {
            self.set_error("请先在资源管理器中选择文件");
            return;
        };
        if entry.path == self.cwd {
            self.set_error("不能删除工程根目录");
            return;
        }
        let kind = if entry.is_dir { "文件夹" } else { "文件" };
        self.overlay = Overlay::Confirm(ConfirmState {
            title: format!("删除{kind}"),
            message: format!(
                "确定删除「{}」{}？此操作不可撤销。",
                entry.path.display(),
                if entry.is_dir { "及其全部内容" } else { "" }
            ),
            selected: 1,
            action: ConfirmAction::ExplorerDelete(entry.path),
        });
    }

    /// 执行一个无参数 Git 操作（拉取/推送/获取/stash 等）。
    fn git_simple_action(
        &mut self,
        label: &str,
        action: fn(&std::path::Path) -> Result<String, String>,
    ) {
        self.git.refresh(&self.cwd);
        let Some(root) = self.git.root.clone() else {
            self.set_error("不在 Git 仓库中");
            return;
        };
        match action(&root) {
            Ok(text) => {
                self.git.refresh(&self.cwd);
                let first = text.lines().next().unwrap_or("").trim().to_string();
                if first.is_empty() {
                    self.set_status(format!("Git {label}完成"));
                } else {
                    self.set_status(format!("Git {label}：{first}"));
                }
            }
            Err(error) => self.set_error(format!("Git {label}失败：{error}")),
        }
    }

    fn git_show_status(&mut self) {
        self.git.refresh(&self.cwd);
        if self.git.root.is_none() {
            self.set_error(self.git.summary());
            return;
        }
        if self.git.changes.is_empty() {
            self.set_status(format!("{} · 工作区干净", self.git.branch));
            return;
        }
        let items = self
            .git
            .changes
            .iter()
            .map(|change| ListItem {
                title: change.path.clone(),
                detail: change.status.trim().to_string(),
                command: None,
                path: self
                    .git
                    .root
                    .as_ref()
                    .map(|root| root.join(&change.path)),
                line: None,
                value: None,
            })
            .collect();
        self.open_list(ListState::new(
            ListKind::GitLog,
            &format!("Git 变更 · {}", self.git.branch),
            items,
        ));
    }

    fn git_show_diff(&mut self) {
        let Some(root) = self.git.root.clone() else {
            self.set_error("不在 Git 仓库中");
            return;
        };
        let Some(path) = self.doc().path.clone() else {
            self.set_error("当前文件尚未保存");
            return;
        };
        let text = crate::vcs::git::file_diff(&root, &path);
        if text.trim().is_empty() {
            self.set_status("该文件没有未提交的差异");
            return;
        }
        self.open_preview(&text, "Git 差异", Language::Diff);
    }

    pub(crate) fn git_show_log(&mut self) {
        let Some(root) = self.git.root.clone() else {
            self.set_error("不在 Git 仓库中");
            return;
        };
        let lines = crate::vcs::git::log(&root, 100);
        if lines.is_empty() {
            self.set_status("没有提交记录");
            return;
        }
        let items = lines
            .iter()
            .map(|line| {
                let hash = line.split_whitespace().next().unwrap_or("").to_string();
                ListItem {
                    title: line.clone(),
                    detail: hash.clone(),
                    command: None,
                    path: None,
                    line: None,
                    value: Some(hash),
                }
            })
            .collect();
        self.open_list(ListState::new(ListKind::GitLog, "Git 历史", items));
    }

    fn open_git_show(&mut self, hash: &str) {
        let Some(root) = self.git.root.clone() else {
            return;
        };
        match crate::vcs::git::run(&root, &["show", "--stat", "--patch", hash]) {
            Ok(text) => self.open_preview(&text, &format!("Git {hash}"), Language::Diff),
            Err(e) => self.set_error(e),
        }
    }

    pub(crate) fn git_commit_prompt(&mut self) {
        if self.git.root.is_none() {
            self.set_error("不在 Git 仓库中");
            return;
        }
        self.open_prompt(PromptKind::GitCommit, "Git 提交", "");
    }

    pub(crate) fn open_preview(&mut self, text: &str, title: &str, language: Language) {
        let mut doc = Document::from_text(text, None);
        doc.language = language;
        doc.read_only = true;
        let mut tab = Tab::new(doc, &self.config);
        tab.preview = true;
        self.tabs.push(tab);
        self.active = self.tabs.len() - 1;
        self.set_status(format!("{title}（只读）"));
    }

    // ------------------------------------------------------------ LSP

    fn lsp_goto_definition(&mut self) {
        let Some(path) = self.doc().path.clone() else {
            self.set_error("文件尚未保存，无法跳转定义");
            return;
        };
        let pos = self.doc().primary().pos;
        let text = self.doc().text();
        let result = self.lsp.definition(&path, pos.line, pos.col, &text);
        match result {
            Some((file, line)) => {
                if let Err(e) = self.open_file(&file) {
                    self.set_error(e);
                    return;
                }
                self.doc_mut().set_cursor(Pos::new(line, 0));
                self.ensure_visible();
                self.set_status(format!("已跳转到 {}", file.display()));
            }
            None => {
                let status = self.lsp.status.clone();
                self.set_error(if status.is_empty() {
                    "未找到定义"
                } else {
                    status.as_str()
                });
            }
        }
    }

    /// Alt+F12：在当前文件上方弹出定义处附近的代码（Enter 跳转）。
    fn lsp_peek_definition(&mut self) {
        let Some(path) = self.doc().path.clone() else {
            self.set_error("文件尚未保存，无法预览定义");
            return;
        };
        let pos = self.doc().primary().pos;
        let text = self.doc().text();
        let Some((file, line)) = self.lsp.definition(&path, pos.line, pos.col, &text) else {
            let status = self.lsp.status.clone();
            self.set_error(if status.is_empty() {
                "未找到定义"
            } else {
                status.as_str()
            });
            return;
        };
        let content = std::fs::read_to_string(&file).unwrap_or_default();
        let lines: Vec<&str> = content.lines().collect();
        if lines.is_empty() {
            self.set_error("定义所在文件为空或无法读取");
            return;
        }
        let start = line.saturating_sub(4);
        let end = (line + 5).min(lines.len());
        let items = (start..end)
            .map(|index| ListItem {
                title: format!(
                    "{} {:>4}  {}",
                    if index == line { "▸" } else { " " },
                    index + 1,
                    lines[index]
                ),
                detail: String::new(),
                command: None,
                path: Some(file.clone()),
                line: Some(index),
                value: None,
            })
            .collect();
        let name = file
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| file.display().to_string());
        let title = format!("定义预览：{}:{}（Enter 跳转）", name, line + 1);
        self.open_list(ListState::new(ListKind::LspInfo, &title, items));
    }

    fn lsp_open_completion(&mut self) {
        self.lsp_open_completion_impl(false);
    }

    /// 输入停顿后的自动补全：静默失败，且不主动启动服务器。
    pub(crate) fn lsp_open_completion_auto(&mut self) {
        if !self.config.lsp_auto_complete {
            return;
        }
        let Some(path) = self.doc().path.clone() else {
            return;
        };
        if !self.lsp.active_for(&path) {
            return;
        }
        let pos = self.doc().primary().pos;
        if self.doc().cursors.len() != 1 || self.doc().primary().has_selection() {
            return;
        }
        let prefix = word_prefix(self.doc().line(pos.line), pos.col);
        if prefix.chars().count() < 2 {
            return;
        }
        self.lsp_open_completion_impl(true);
    }

    fn lsp_open_completion_impl(&mut self, auto: bool) {
        if self.tab().excel.is_some() || self.word_page_view {
            if !auto {
                self.set_error("当前视图不支持代码补全");
            }
            return;
        }
        let path = self.doc().path.clone();
        let pos = self.doc().primary().pos;
        let text = self.doc().text();
        let prefix = word_prefix(self.doc().line(pos.line), pos.col);
        let mut items = self
            .lsp
            .completion_items(path.as_deref(), pos.line, pos.col, &text);
        // 无语言服务器时退化为「文档内单词补全」，保证任何语言都能使用。
        for word in self.local_words(&prefix) {
            if !items
                .iter()
                .any(|(label, _, insert)| *label == word || *insert == word)
            {
                items.push((word.clone(), "文档".into(), word));
            }
        }
        if items.is_empty() {
            if auto {
                return;
            }
            let status = self.lsp.status.clone();
            self.set_error(if status.is_empty() {
                "没有可用的补全"
            } else {
                &status
            });
            return;
        }
        let items = items
            .into_iter()
            .map(|(label, detail, insert)| ListItem {
                title: label,
                detail,
                command: None,
                path: None,
                line: None,
                value: Some(insert),
            })
            .collect();
        let mut list = ListState::new(ListKind::LspCompletion, "补全", items);
        // 已输入的标识符作为初始过滤词，继续输入只收窄列表。
        if !prefix.is_empty() {
            list.query = prefix;
            list.refilter();
            if list.filtered.is_empty() {
                list.query.clear();
                list.refilter();
            }
        }
        self.open_list(list);
    }

    /// 从当前文档与其他已打开文档中收集同前缀单词。
    fn local_words(&self, prefix: &str) -> Vec<String> {
        if prefix.chars().count() < 2 {
            return Vec::new();
        }
        let mut words = std::collections::HashSet::new();
        for tab in &self.tabs {
            if tab.excel.is_some() || tab.word.is_some() || tab.image.is_some() {
                continue;
            }
            for line in 0..tab.doc.line_count() {
                for token in tab
                    .doc
                    .line(line)
                    .split(|c: char| !(c.is_alphanumeric() || c == '_' || c == '$'))
                {
                    if token.len() >= 2
                        && token != prefix
                        && token.starts_with(prefix)
                        && token.chars().count() <= 48
                    {
                        words.insert(token.to_string());
                    }
                }
                if words.len() >= 300 {
                    break;
                }
            }
        }
        let mut words: Vec<String> = words.into_iter().collect();
        words.sort_by(|a, b| a.len().cmp(&b.len()).then(a.cmp(b)));
        words.truncate(200);
        words
    }

    fn lsp_hover(&mut self) {
        let Some(path) = self.doc().path.clone() else {
            self.set_error("文件尚未保存，无法获取悬停提示");
            return;
        };
        let pos = self.doc().primary().pos;
        let text = self.doc().text();
        let Some(markdown) = self.lsp.hover(&path, pos.line, pos.col, &text) else {
            let status = self.lsp.status.clone();
            self.set_error(if status.is_empty() {
                "没有可用的悬停信息"
            } else {
                &status
            });
            return;
        };
        let items = markdown
            .lines()
            .take(60)
            .map(|line| ListItem {
                title: line.to_string(),
                detail: String::new(),
                command: None,
                path: None,
                line: None,
                value: None,
            })
            .collect();
        self.open_list(ListState::new(ListKind::LspInfo, "悬停信息", items));
    }

    fn lsp_references(&mut self) {
        let Some(path) = self.doc().path.clone() else {
            self.set_error("文件尚未保存，无法查找引用");
            return;
        };
        let pos = self.doc().primary().pos;
        let text = self.doc().text();
        let list = self.lsp.references(&path, pos.line, pos.col, &text);
        if list.is_empty() {
            let status = self.lsp.status.clone();
            self.set_error(if status.is_empty() {
                "未找到引用"
            } else {
                &status
            });
            return;
        }
        let items = list
            .into_iter()
            .map(|(path, line, col)| ListItem {
                title: path
                    .strip_prefix(&self.cwd)
                    .unwrap_or(&path)
                    .display()
                    .to_string(),
                detail: format!("第 {} 行", line + 1),
                command: None,
                path: Some(path),
                line: Some(line),
                value: Some(col.to_string()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::LspReferences, "引用", items));
    }

    /// 工作区符号搜索（Ctrl+T）。
    fn lsp_workspace_symbols(&mut self, query: &str) {
        let Some(path) = self.doc().path.clone() else {
            self.set_error("文件尚未保存，无法搜索工作区符号");
            return;
        };
        if !self.lsp.can_serve(&path) {
            self.set_error("当前语言未配置可用的语言服务器");
            return;
        }
        let list = self.lsp.workspace_symbols(&path, query.trim());
        if list.is_empty() {
            let status = self.lsp.status.clone();
            self.set_error(if status.is_empty() {
                "未找到符号"
            } else {
                &status
            });
            return;
        }
        let items = list
            .into_iter()
            .map(|(path, line, col, name, kind)| ListItem {
                title: format!("{kind}  {name}"),
                detail: format!(
                    "{}:{}",
                    path.strip_prefix(&self.cwd).unwrap_or(&path).display(),
                    line + 1
                ),
                command: None,
                path: Some(path),
                line: Some(line),
                value: Some(col.to_string()),
            })
            .collect();
        self.open_list(ListState::new(ListKind::LspSymbols, "工作区符号", items));
    }

    fn lsp_rename_prompt(&mut self) {
        let Some(path) = self.doc().path.clone() else {
            self.set_error("文件尚未保存，无法重命名符号");
            return;
        };
        if !self.lsp.can_serve(&path) {
            self.set_error("当前语言未配置可用的语言服务器");
            return;
        }
        let pos = self.doc().primary().pos;
        let word = word_at(self.doc().line(pos.line), pos.col);
        self.open_prompt(PromptKind::LspRename, "重命名符号", &word);
    }

    fn lsp_apply_rename(&mut self, new_name: &str) {
        let Some(path) = self.doc().path.clone() else {
            self.set_error("文件尚未保存，无法重命名符号");
            return;
        };
        let pos = self.doc().primary().pos;
        let text = self.doc().text();
        match self
            .lsp
            .rename(&path, pos.line, pos.col, &text, new_name)
        {
            Ok(edits) => match self.lsp_apply_edits(&edits) {
                Ok(count) => {
                    self.after_change();
                    self.set_status(format!("已重命名 {count} 处为 {new_name}"));
                }
                Err(error) => self.set_error(error),
            },
            Err(error) => self.set_error(error),
        }
    }

    fn lsp_format_document(&mut self) {
        let Some(path) = self.doc().path.clone() else {
            self.set_error("文件尚未保存，无法格式化");
            return;
        };
        let text = self.doc().text();
        let tab_width = self.doc().tab_width;
        match self.lsp.formatting(&path, &text, tab_width, true) {
            Ok(edits) => {
                if edits.is_empty() {
                    self.set_status("文档已符合格式要求");
                    return;
                }
                match self.lsp_apply_edits(&edits) {
                    Ok(count) => {
                        self.after_change();
                        self.set_status(format!("已应用 {count} 处格式化编辑"));
                    }
                    Err(error) => self.set_error(error),
                }
            }
            Err(error) => self.set_error(error),
        }
    }

    /// 输入 `(` / `,` 后的自动签名帮助：只在服务器已连接时触发，失败静默。
    pub(crate) fn lsp_auto_signature(&mut self) {
        let Some(path) = self.doc().path.clone() else {
            return;
        };
        if !self.lsp.active_for(&path) {
            return;
        }
        if self.doc().cursors.len() != 1 || self.doc().primary().has_selection() {
            return;
        }
        self.lsp_signature_help_impl(false);
    }

    fn lsp_signature_help(&mut self, manual: bool) {
        self.lsp_signature_help_impl(manual);
    }

    fn lsp_signature_help_impl(&mut self, manual: bool) {
        let Some(path) = self.doc().path.clone() else {
            if manual {
                self.set_error("文件尚未保存，无法获取签名帮助");
            }
            return;
        };
        let pos = self.doc().primary().pos;
        let text = self.doc().text();
        match self.lsp.signature_help(&path, pos.line, pos.col, &text) {
            Some(help) => {
                let signatures = help
                    .signatures
                    .iter()
                    .map(|item| (item.label.clone(), item.docs.clone()))
                    .collect();
                self.signature_help = Some(crate::ui::app::SignatureState {
                    signatures,
                    active: help.active,
                    parameter: help.parameter,
                    path,
                    line: pos.line,
                    col: pos.col,
                });
                if manual {
                    self.set_status("签名帮助（Esc 关闭）");
                }
            }
            None => {
                self.signature_help = None;
                if manual {
                    let status = self.lsp.status.clone();
                    self.set_error(if status.is_empty() {
                        "没有可用的签名信息"
                    } else {
                        &status
                    });
                }
            }
        }
    }

    /// 快速修复 / 代码操作列表。
    fn lsp_code_actions(&mut self) {
        if self.tab().excel.is_some() || self.word_page_view {
            self.set_error("当前视图不支持代码操作");
            return;
        }
        let Some(path) = self.doc().path.clone() else {
            self.set_error("文件尚未保存，无法获取代码操作");
            return;
        };
        if !self.lsp.can_serve(&path) {
            self.set_error("当前语言未配置可用的语言服务器");
            return;
        }
        let pos = self.doc().primary().pos;
        let text = self.doc().text();
        let diagnostics = self.lsp.diagnostics(&path);
        match self
            .lsp
            .code_actions(&path, pos.line, pos.col, &text, &diagnostics)
        {
            Ok(actions) if !actions.is_empty() => {
                let items = actions
                    .iter()
                    .enumerate()
                    .map(|(index, action)| ListItem {
                        title: action.title.clone(),
                        detail: action.kind.clone(),
                        command: None,
                        path: None,
                        line: None,
                        value: Some(index.to_string()),
                    })
                    .collect();
                self.pending_code_actions = actions;
                self.open_list(ListState::new(
                    ListKind::LspCodeAction,
                    "快速修复 / 代码操作",
                    items,
                ));
            }
            Ok(_) => {
                self.pending_code_actions.clear();
                let status = self.lsp.status.clone();
                self.set_error(if status.is_empty() {
                    "没有可用的代码操作"
                } else {
                    &status
                });
            }
            Err(error) => {
                self.pending_code_actions.clear();
                self.set_error(error);
            }
        }
    }

    /// 应用列表中选择的代码操作。
    fn apply_code_action(&mut self, index: usize) {
        let Some(action) = self.pending_code_actions.get(index).cloned() else {
            self.set_error("代码操作已失效，请重新获取");
            return;
        };
        self.pending_code_actions.clear();
        match self.lsp_apply_edits(&action.edits) {
            Ok(count) => {
                self.after_change();
                self.set_status(format!("已应用「{}」（{count} 处编辑）", action.title));
            }
            Err(error) => self.set_error(error),
        }
    }

    /// 应用 LSP 编辑：打开的文件用编辑器批量替换，未打开的文件直接写盘。
    fn lsp_apply_edits(
        &mut self,
        edits: &[crate::lsp::client::LspEdit],
    ) -> Result<usize, String> {
        use std::collections::BTreeMap;
        let mut groups: BTreeMap<PathBuf, Vec<&crate::lsp::client::LspEdit>> = BTreeMap::new();
        for edit in edits {
            if edit.path.as_os_str().is_empty() {
                return Err("语言服务器返回了空文件路径".into());
            }
            groups.entry(edit.path.clone()).or_default().push(edit);
        }
        let mut applied = 0usize;
        for (path, list) in groups {
            if let Some(index) = self
                .tabs
                .iter()
                .position(|tab| tab.doc.path.as_deref() == Some(path.as_path()))
            {
                let mut doc_edits = Vec::new();
                {
                    let doc = &self.tabs[index].doc;
                    if doc.read_only {
                        return Err("当前文档为只读，无法应用编辑".into());
                    }
                    for edit in &list {
                        let last = doc.line_count().saturating_sub(1);
                        let start_line = edit.start_line.min(last);
                        let end_line = edit.end_line.min(last);
                        let start_col = utf16_to_char(doc.line(start_line), edit.start_col);
                        let end_col = utf16_to_char(doc.line(end_line), edit.end_col);
                        doc_edits.push((
                            Pos::new(start_line, start_col),
                            Pos::new(end_line, end_col),
                            edit.new_text.clone(),
                        ));
                    }
                }
                self.tabs[index].doc.replace_ranges_each(&doc_edits);
                let config = self.config.clone();
                let width = self.text_width();
                self.tabs[index].refresh(&config, width, true);
                applied += list.len();
            } else {
                let bytes = std::fs::read(&path)
                    .map_err(|e| format!("读取 {} 失败：{e}", path.display()))?;
                let mut text = String::from_utf8(bytes)
                    .map_err(|_| format!("{} 不是 UTF-8 文本，无法应用编辑", path.display()))?;
                let mut ranges = Vec::new();
                for edit in &list {
                    let start = text_offset(&text, edit.start_line, edit.start_col);
                    let end = text_offset(&text, edit.end_line, edit.end_col);
                    ranges.push((start.min(end), start.max(end), &edit.new_text));
                    applied += 1;
                }
                ranges.sort_by(|a, b| b.0.cmp(&a.0));
                for (start, end, replacement) in ranges {
                    text.replace_range(start..end, replacement);
                }
                std::fs::write(&path, text.as_bytes())
                    .map_err(|e| format!("写入 {} 失败：{e}", path.display()))?;
            }
        }
        if applied == 0 {
            Err("没有可应用的编辑".into())
        } else {
            Ok(applied)
        }
    }

    fn lsp_open_location(&mut self, path: PathBuf, line: usize, utf16: usize) {
        if let Err(error) = self.open_file(&path) {
            self.set_error(error);
            return;
        }
        let line = line.min(self.doc().line_count().saturating_sub(1));
        let col = utf16_to_char(self.doc().line(line), utf16);
        self.doc_mut().set_cursor(Pos::new(line, col));
        self.ensure_visible();
        self.focus = Focus::Editor;
        self.set_status(format!("{}:{}", path.display(), line + 1));
    }
}

/// 光标前的标识符前缀。
fn word_prefix(line: &str, col: usize) -> String {
    let chars: Vec<char> = line.chars().collect();
    let is_word = |c: char| c.is_alphanumeric() || c == '_' || c == '$';
    let mut start = col.min(chars.len());
    while start > 0 && is_word(chars[start - 1]) {
        start -= 1;
    }
    chars[start..col.min(chars.len())].iter().collect()
}

/// 光标处的标识符（用于重命名默认值）。
fn word_at(line: &str, col: usize) -> String {
    let chars: Vec<char> = line.chars().collect();
    let is_word = |c: char| c.is_alphanumeric() || c == '_';
    let mut start = col.min(chars.len());
    while start > 0 && is_word(chars[start - 1]) {
        start -= 1;
    }
    let mut end = col.min(chars.len());
    while end < chars.len() && is_word(chars[end]) {
        end += 1;
    }
    chars[start..end].iter().collect()
}

/// UTF-16 列号 → 字符列号。
fn utf16_to_char(line: &str, utf16: usize) -> usize {
    let mut units = 0usize;
    let mut chars = 0usize;
    for ch in line.chars() {
        let next = units + ch.len_utf16();
        if next > utf16 {
            break;
        }
        units = next;
        chars += 1;
    }
    chars
}

/// 行列（UTF-16 列）→ 字节偏移。
fn text_offset(text: &str, line: usize, utf16: usize) -> usize {
    let mut offset = 0usize;
    for _ in 0..line {
        match text[offset..].find('\n') {
            Some(index) => offset += index + 1,
            None => return text.len(),
        }
    }
    let end = text[offset..]
        .find('\n')
        .map(|index| offset + index)
        .unwrap_or(text.len());
    let mut units = 0usize;
    let mut byte = offset;
    for ch in text[offset..end].chars() {
        if units + ch.len_utf16() > utf16 {
            break;
        }
        units += ch.len_utf16();
        byte += ch.len_utf8();
    }
    byte
}

fn outline_items(doc: &Document) -> Vec<ListItem> {
    let mut items = Vec::new();
    for line in 0..doc.line_count() {
        let text = doc.line(line);
        let trimmed = text.trim_start();
        let indent = text.len() - trimmed.len();
        let mut title = None;
        let patterns = [
            "fn ", "pub fn ", "async fn ", "struct ", "pub struct ", "enum ", "pub enum ",
            "trait ", "impl ", "mod ", "class ", "def ", "func ", "function ", "interface ",
            "namespace ", "type ",
        ];
        for pattern in patterns {
            if let Some(rest) = trimmed.strip_prefix(pattern) {
                let name: String = rest
                    .chars()
                    .take_while(|c| c.is_alphanumeric() || *c == '_' || *c == ':' || *c == '(' || *c == '<')
                    .collect();
                if !name.is_empty() {
                    title = Some(format!("{}{}", "  ".repeat(indent / 4), name));
                }
                break;
            }
        }
        if title.is_none() {
            let hashes = trimmed.chars().take_while(|c| *c == '#').count();
            if hashes > 0 && trimmed.chars().nth(hashes) == Some(' ') {
                title = Some(trimmed.to_string());
            }
        }
        if let Some(title) = title {
            items.push(ListItem {
                title,
                detail: format!("第 {} 行", line + 1),
                command: None,
                path: None,
                line: Some(line),
                value: None,
            });
        }
    }
    items
}

/// 跨多个工作区根目录收集文件（用于快速打开与工程搜索）。
pub(crate) fn collect_files_multi(roots: &[PathBuf], limit: usize) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    for root in roots {
        let remain = limit.saturating_sub(out.len());
        if remain == 0 {
            break;
        }
        out.extend(collect_files(root, remain));
    }
    out.sort();
    out.dedup();
    out.truncate(limit);
    out
}

pub(crate) fn collect_files(root: &Path, limit: usize) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            if name.starts_with('.') || matches!(name.as_str(), "target" | "node_modules" | "bin" | "obj") {
                continue;
            }
            if path.is_dir() {
                stack.push(path);
            } else if files.len() < limit {
                files.push(path);
            }
        }
        if files.len() >= limit {
            break;
        }
    }
    files.sort();
    files
}

/// `%APPDATA%\Textm`（市场安装 / 卸载使用的配置目录）。
fn config_dir() -> PathBuf {
    crate::config::Config::path()
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_default()
}

/// 按 (行, 列) 应用插件返回的文本编辑（字符位置，降序应用）。
fn apply_text_edits(text: &str, edits: &[crate::plugin::PluginEdit]) -> String {
    let mut starts = vec![0usize];
    for (index, byte) in text.bytes().enumerate() {
        if byte == b'\n' {
            starts.push(index + 1);
        }
    }
    let offset = |line: usize, character: usize| -> usize {
        let base = *starts.get(line).unwrap_or(&text.len());
        let end = text[base..]
            .find('\n')
            .map(|index| base + index)
            .unwrap_or(text.len());
        let segment = &text[base..end];
        base + segment
            .char_indices()
            .nth(character)
            .map(|(index, _)| index)
            .unwrap_or(segment.len())
    };
    let mut list: Vec<(usize, usize, &str)> = edits
        .iter()
        .map(|edit| {
            (
                offset(edit.start_line, edit.start_char),
                offset(edit.end_line, edit.end_char),
                edit.new_text.as_str(),
            )
        })
        .collect();
    list.sort_by(|a, b| b.0.cmp(&a.0));
    let mut out = text.to_string();
    for (start, end, replacement) in list {
        if start <= end && end <= out.len() {
            out.replace_range(start..end, replacement);
        }
    }
    out
}

fn expand_env(input: &str) -> String {
    let input = input.trim().trim_matches('"');
    let mut out = String::new();
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '%' {
            if let Some(end) = (i + 1..chars.len()).find(|j| chars[*j] == '%') {
                let name: String = chars[i + 1..end].iter().collect();
                if let Ok(value) = std::env::var(&name) {
                    out.push_str(&value);
                    i = end + 1;
                    continue;
                }
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

fn menu_rect(app: &super::app::App, index: usize) -> Rect {
    let menus = app.menus();
    let height = menus.get(index).map(|menu| menu.items.len()).unwrap_or(0) + 2;
    let width = 40usize;
    // VSCode 布局：下拉框贴在菜单项下方；sqlmux 布局回退到左上角。
    let (x, y) = app
        .menu_bar_items()
        .into_iter()
        .find(|(i, _, _)| *i == index)
        .map(|(_, rect, _)| (rect.x, rect.y + 1))
        .unwrap_or((2, 1));
    let x = x.min(app.layout.cols.saturating_sub(width));
    Rect {
        x,
        y,
        w: width,
        h: height.min(app.layout.rows.saturating_sub(y + 1)),
    }
}

/// 解析 Ex 范围：`3`、`3,5`、`.`、`$`、`.+2` 等，返回 (起, 止, 剩余文本)。
fn parse_line_range(text: &str, line_count: usize) -> Option<(usize, usize, &str)> {
    let last_line = line_count.saturating_sub(1);
    let mut chars = text.char_indices().peekable();
    let mut parse_one = |chars: &mut std::iter::Peekable<std::str::CharIndices>| -> Option<usize> {
        match chars.peek().map(|(_, c)| *c)? {
            '.' => {
                chars.next();
                Some(usize::MAX)
            }
            '$' => {
                chars.next();
                Some(usize::MAX - 1)
            }
            c if c.is_ascii_digit() => {
                let mut value = 0usize;
                while let Some((_, c)) = chars.peek() {
                    if c.is_ascii_digit() {
                        value = value * 10 + (*c as u8 - b'0') as usize;
                        chars.next();
                    } else {
                        break;
                    }
                }
                Some(value.saturating_sub(1))
            }
            _ => None,
        }
    };
    let first = parse_one(&mut chars)?;
    let mut second = first;
    let mut consumed = false;
    if let Some((index, ',')) = chars.peek().copied() {
        if index == 0 {
            return None;
        }
        chars.next();
        consumed = true;
        second = parse_one(&mut chars).unwrap_or(first);
    }
    let rest_index = chars.peek().map(|(i, _)| *i).unwrap_or(text.len());
    // 范围后面必须是空白或命令名，避免把 `set` 里的数字当范围。
    let rest = &text[rest_index..];
    if !consumed && !rest.starts_with(char::is_whitespace) && !rest.is_empty() {
        return None;
    }
    let map = |value: usize| {
        if value == usize::MAX {
            line_count
        } else if value == usize::MAX - 1 {
            line_count.saturating_sub(1)
        } else {
            value
        }
    };
    let first = map(first).min(last_line);
    let second = map(second).min(last_line);
    Some((first.min(second), first.max(second), rest))
}

/// 解析 `s/旧/新/flags`。
fn parse_substitute(args: &str) -> Option<(String, String, String)> {
    let mut chars = args.chars().peekable();
    let delim = chars.next()?;
    if delim.is_alphanumeric() || delim == '\\' {
        return None;
    }
    let mut parts: Vec<String> = vec![String::new()];
    let mut escaped = false;
    for c in chars {
        if escaped {
            if c != delim {
                parts.last_mut()?.push('\\');
            }
            parts.last_mut()?.push(c);
            escaped = false;
        } else if c == '\\' {
            escaped = true;
        } else if c == delim {
            parts.push(String::new());
        } else {
            parts.last_mut()?.push(c);
        }
    }
    if escaped {
        parts.last_mut()?.push('\\');
    }
    if parts.len() < 2 {
        return Some((parts.remove(0), String::new(), String::new()));
    }
    let pattern = parts.remove(0);
    let replacement = parts.remove(0);
    let flags = parts.join("");
    Some((pattern, replacement, flags))
}

/// Vim 替换串（`\1`、`\&`、`\n`）→ 编辑器替换串（`$1`、`$&`、换行）。
fn vim_replacement(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some(d @ '0'..='9') => {
                    out.push('$');
                    out.push(d);
                }
                Some('&') => out.push_str("$&"),
                Some(other) => out.push(other),
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn keys_rect(app: &super::app::App) -> Rect {
    let hints = crate::ui::app::KEY_HINTS;
    let rows = (hints.len() + 1) / 2;
    let width = 64.min(app.layout.cols.saturating_sub(4)).max(28);
    let height = (rows + 2).min(app.layout.rows.saturating_sub(3));
    Rect {
        x: app.layout.cols.saturating_sub(width + 1),
        y: app.layout.rows.saturating_sub(height + 1),
        w: width,
        h: height,
    }
}

fn context_rect(app: &super::app::App) -> Rect {
    let state = match &app.overlay {
        Overlay::Context(state) => state,
        _ => return Rect::default(),
    };
    let width = state
        .items
        .iter()
        .map(|item| crate::render::canvas::text_width(&item.label))
        .max()
        .unwrap_or(10)
        + 7;
    let width = width
        .max(18)
        .min(app.layout.cols.saturating_sub(2));
    let height = (state.items.len() + 2).min(app.layout.rows.saturating_sub(2));
    Rect {
        x: state.x.min(app.layout.cols.saturating_sub(width + 1)),
        y: state.y.min(app.layout.rows.saturating_sub(height + 1)),
        w: width,
        h: height,
    }
}

fn menu_item_at(app: &super::app::App, index: usize, x: usize, y: usize) -> Option<usize> {
    let rect = menu_rect(app, index);
    if !rect.contains(x, y) || y <= rect.y {
        return None;
    }
    let item = y - rect.y - 1;
    let len = app
        .menus()
        .get(index)
        .map(|menu| menu.items.len())
        .unwrap_or(0);
    if item < len {
        Some(item)
    } else {
        None
    }
}

fn list_rect(app: &super::app::App) -> Rect {
    let width = app.layout.cols.saturating_sub(6).clamp(28, 78);
    let height = app.layout.rows.saturating_sub(6).clamp(6, 16);
    Rect {
        x: (app.layout.cols.saturating_sub(width)) / 2,
        y: (app.layout.rows.saturating_sub(height)) / 2,
        w: width,
        h: height,
    }
}

fn find_rect(app: &super::app::App) -> Rect {
    let width = 50.min(app.layout.cols.saturating_sub(4));
    let height = if matches!(&app.overlay, Overlay::Find(state) if state.replace) {
        5
    } else {
        4
    };
    Rect {
        x: app.layout.cols.saturating_sub(width + 2),
        y: app.layout.editor.y + 1,
        w: width,
        h: height,
    }
}

fn confirm_rect(app: &super::app::App) -> Rect {
    let width = 54.min(app.layout.cols.saturating_sub(4));
    Rect {
        x: (app.layout.cols.saturating_sub(width)) / 2,
        y: app.layout.rows / 2 - 2,
        w: width,
        h: 7,
    }
}

fn prompt_rect(app: &super::app::App) -> Rect {
    let width = 62.min(app.layout.cols.saturating_sub(4));
    Rect {
        x: (app.layout.cols.saturating_sub(width)) / 2,
        y: app.layout.rows / 2 - 2,
        w: width,
        h: 6,
    }
}

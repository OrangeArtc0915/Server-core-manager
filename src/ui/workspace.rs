//! 跨文件搜索与工程替换（侧边栏「搜索」面板）。
//!
//! - 搜索/替换按文件分块并行（`std::thread`，仍为零第三方依赖）；
//! - 解码前先用字面量前缀做字节级预筛，跳过无关文件；
//! - 单行只收集一次字符，避免每个匹配重复分配；
//! - 替换支持正则与 `$1` 捕获组、`\n` 等转义。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::core::document::{Document, Pos};
use crate::core::encoding;
use crate::core::glob;
use crate::core::search::{SearchEngine, SearchOptions};
use crate::platform::console::{Key, KeyCode};
use crate::ui::app::{App, Focus, SidebarMode};

#[derive(Clone, Debug)]
pub struct WorkspaceHit {
    pub path: PathBuf,
    pub line: usize,
    pub col: usize,
    /// 同一行的多个命中共享一份文本，避免重复分配。
    pub text: Arc<str>,
}

/// 单文件最多返回的匹配数，避免一行超长文本刷屏。
const PER_FILE_LIMIT: usize = 500;
const TOTAL_LIMIT: usize = 3000;
/// 超过该大小的文件不参与工程搜索/替换。
const MAX_FILE_BYTES: u64 = 2_000_000;
const MAX_FILES: usize = 8000;
const MAX_THREADS: usize = 8;
/// 文件数太少时并行收益不大，直接单线程。
const MIN_PARALLEL_FILES: usize = 64;

/// 字节级预筛：表达式必含的 ASCII 字面量前缀。
struct Prefilter {
    needle: Vec<u8>,
    ignore_case: bool,
}

impl Prefilter {
    fn for_engine(engine: &SearchEngine) -> Option<Prefilter> {
        let text = engine.prefilter_text()?;
        if text.is_empty() || !text.is_ascii() {
            return None;
        }
        Some(Prefilter {
            needle: text.bytes().map(|b| b.to_ascii_lowercase()).collect(),
            ignore_case: !engine.options.case_sensitive,
        })
    }

    fn allows(&self, data: &[u8]) -> bool {
        let len = self.needle.len();
        if len == 0 {
            return true;
        }
        if data.len() < len {
            return false;
        }
        if self.ignore_case {
            data.windows(len).any(|window| {
                window
                    .iter()
                    .zip(&self.needle)
                    .all(|(byte, want)| byte.to_ascii_lowercase() == *want)
            })
        } else {
            data.windows(len).any(|window| window == self.needle.as_slice())
        }
    }
}

struct ScanOutcome {
    hits: Vec<WorkspaceHit>,
    scanned: usize,
    truncated: bool,
}

enum ReplaceOutcome {
    Skipped,
    Unchanged,
    Changed { count: usize, text: Option<String> },
}

struct ReplaceBatch {
    results: Vec<(PathBuf, ReplaceOutcome)>,
    errors: Vec<String>,
}

fn worker_count(file_count: usize) -> usize {
    if file_count < MIN_PARALLEL_FILES {
        return 1;
    }
    let cores = std::thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(1)
        .min(MAX_THREADS);
    cores.max(1).min((file_count / 32).max(1))
}

fn split_chunks(files: &[PathBuf], parts: usize) -> Vec<&[PathBuf]> {
    let mut chunks = Vec::new();
    if files.is_empty() {
        return chunks;
    }
    let size = ((files.len() + parts - 1) / parts).max(1);
    let mut start = 0usize;
    while start < files.len() {
        let end = (start + size).min(files.len());
        chunks.push(&files[start..end]);
        start = end;
    }
    chunks
}

/// 单个分块的搜索。
fn scan_files(
    files: &[PathBuf],
    engine: &SearchEngine,
    prefilter: Option<&Prefilter>,
) -> ScanOutcome {
    let mut hits = Vec::new();
    let mut scanned = 0usize;
    let mut truncated = false;
    for path in files {
        let Ok(meta) = std::fs::metadata(path) else {
            continue;
        };
        if meta.len() > MAX_FILE_BYTES {
            continue;
        }
        let Ok(bytes) = std::fs::read(path) else {
            continue;
        };
        // UTF-16 文本天然含 NUL 字节，不能据此判定为二进制。
        let utf16 = encoding::is_utf16(&bytes);
        if !utf16 && bytes.contains(&0) {
            continue;
        }
        // UTF-16 的 ASCII 字符与 0 字节交错，字节预筛不适用。
        if !utf16 {
            if let Some(filter) = prefilter {
                if !filter.allows(&bytes) {
                    continue;
                }
            }
        }
        scanned += 1;
        let decoded = encoding::decode(&bytes);
        let mut per_file = 0usize;
        if engine.options.regex {
            // 正则：整段文本匹配，支持跨行；再把字符偏移映射回行列。
            let chars: Vec<char> = decoded.text.chars().collect();
            let starts = line_starts(&chars);
            let lines: Vec<&str> = decoded.text.split('\n').collect();
            let mut from = 0usize;
            while per_file < PER_FILE_LIMIT && hits.len() < TOTAL_LIMIT {
                let Some(item) = engine.find_in_chars_captures(&chars, from) else {
                    break;
                };
                let index = line_index(&starts, item.start);
                let start = starts.get(index).copied().unwrap_or(0);
                let text: Arc<str> = Arc::from(lines.get(index).copied().unwrap_or(""));
                hits.push(WorkspaceHit {
                    path: path.clone(),
                    line: index,
                    col: item.start - start,
                    text,
                });
                per_file += 1;
                from = if item.end > item.start {
                    item.end
                } else {
                    item.end + 1
                };
                if from > chars.len() {
                    break;
                }
            }
        } else {
            // 字面量：查询串不含换行，逐行扫描更快。
            'lines: for (line_no, line) in decoded.text.lines().enumerate() {
                let found = engine.find_all_in_line(line, PER_FILE_LIMIT - per_file);
                if found.is_empty() {
                    continue;
                }
                let text: Arc<str> = Arc::from(line);
                for (col, _end) in found {
                    hits.push(WorkspaceHit {
                        path: path.clone(),
                        line: line_no,
                        col,
                        text: text.clone(),
                    });
                    per_file += 1;
                    if per_file >= PER_FILE_LIMIT {
                        break 'lines;
                    }
                    if hits.len() >= TOTAL_LIMIT {
                        truncated = true;
                        break 'lines;
                    }
                }
            }
        }
        if hits.len() >= TOTAL_LIMIT {
            truncated = true;
            break;
        }
    }
    ScanOutcome {
        hits,
        scanned,
        truncated,
    }
}

/// 每个行首在字符数组中的下标。
fn line_starts(chars: &[char]) -> Vec<usize> {
    let mut starts = vec![0usize];
    for (index, ch) in chars.iter().enumerate() {
        if *ch == '\n' {
            starts.push(index + 1);
        }
    }
    starts
}

/// 字符偏移对应的行号。
fn line_index(starts: &[usize], offset: usize) -> usize {
    starts
        .partition_point(|start| *start <= offset)
        .saturating_sub(1)
        .min(starts.len().saturating_sub(1))
}

/// 字符偏移对应的编辑位置。
fn pos_at(starts: &[usize], offset: usize) -> Pos {
    let line = line_index(starts, offset);
    let start = starts.get(line).copied().unwrap_or(0);
    Pos::new(line, offset - start)
}

/// 为未保存的打开文件生成替换编辑（不写盘，交由编辑器撤销栈处理）。
fn dirty_tab_edits(
    engine: &SearchEngine,
    doc: &Document,
    replacement: &str,
) -> Vec<(Pos, Pos, String)> {
    if !engine.options.regex {
        // 字面量不会跨行，直接复用文档级查找。
        return engine
            .find_all_with_groups(doc, 20000)
            .into_iter()
            .map(|(start, end, groups)| {
                (
                    start,
                    end,
                    crate::core::search::expand_replacement(replacement, &groups),
                )
            })
            .collect();
    }
    let text = doc.text();
    let chars: Vec<char> = text.chars().collect();
    let starts = line_starts(&chars);
    let mut edits = Vec::new();
    let mut from = 0usize;
    while edits.len() < 20000 {
        let Some(item) = engine.find_in_chars_captures(&chars, from) else {
            break;
        };
        let groups = crate::core::search::group_texts(&chars, &item.groups);
        edits.push((
            pos_at(&starts, item.start),
            pos_at(&starts, item.end),
            crate::core::search::expand_replacement(replacement, &groups),
        ));
        from = if item.end > item.start {
            item.end
        } else {
            item.end + 1
        };
        if from > chars.len() {
            break;
        }
    }
    edits
}

/// 单个分块的替换（读 -> 替换 -> 写回，全部在线程内完成）。
fn replace_files(
    files: &[PathBuf],
    engine: &SearchEngine,
    replacement: &str,
    prefilter: Option<&Prefilter>,
    dirty: &[PathBuf],
    open: &[PathBuf],
) -> ReplaceBatch {
    let mut results = Vec::new();
    let mut errors = Vec::new();
    for path in files {
        if dirty.iter().any(|item| item == path) {
            results.push((path.clone(), ReplaceOutcome::Skipped));
            continue;
        }
        match replace_one(path, engine, replacement, prefilter, open) {
            Ok(outcome) => results.push((path.clone(), outcome)),
            Err(error) => errors.push(error),
        }
    }
    ReplaceBatch { results, errors }
}

fn replace_one(
    path: &Path,
    engine: &SearchEngine,
    replacement: &str,
    prefilter: Option<&Prefilter>,
    open: &[PathBuf],
) -> Result<ReplaceOutcome, String> {
    let Ok(meta) = std::fs::metadata(path) else {
        return Ok(ReplaceOutcome::Unchanged);
    };
    if meta.len() > MAX_FILE_BYTES {
        return Ok(ReplaceOutcome::Unchanged);
    }
    let Ok(bytes) = std::fs::read(path) else {
        return Ok(ReplaceOutcome::Unchanged);
    };
    let utf16 = encoding::is_utf16(&bytes);
    if !utf16 && bytes.contains(&0) {
        return Ok(ReplaceOutcome::Unchanged);
    }
    if !utf16 {
        if let Some(filter) = prefilter {
            if !filter.allows(&bytes) {
                return Ok(ReplaceOutcome::Unchanged);
            }
        }
    }
    let decoded = encoding::decode(&bytes);
    let (new_text, count) = if engine.options.regex {
        // 正则：整段替换，支持跨行匹配与 $1 捕获组。
        engine.replace_in_text(&decoded.text, replacement, usize::MAX)
    } else {
        let mut new_text = String::with_capacity(decoded.text.len() + 64);
        let mut count = 0usize;
        for (index, line) in decoded.text.lines().enumerate() {
            if index > 0 {
                new_text.push('\n');
            }
            let (new_line, hits) = engine.replace_in_line(line, replacement, usize::MAX);
            new_text.push_str(&new_line);
            count += hits;
        }
        // `lines()` 会丢弃末尾空行，这里补回原文件的末尾换行。
        if decoded.text.ends_with('\n') && !new_text.ends_with('\n') {
            new_text.push('\n');
        }
        (new_text, count)
    };
    if count == 0 {
        return Ok(ReplaceOutcome::Unchanged);
    }
    let mut encoded = encoding::encode(&new_text, decoded.encoding, decoded.eol);
    // 保留原文件的 UTF-16 BOM（encode 不会主动写入）。
    if let Some(bom) = bytes.get(..2) {
        if (bom == [0xFF, 0xFE] || bom == [0xFE, 0xFF]) && !encoded.starts_with(bom) {
            let mut with_bom = Vec::with_capacity(encoded.len() + 2);
            with_bom.extend_from_slice(bom);
            with_bom.extend_from_slice(&encoded);
            encoded = with_bom;
        }
    }
    std::fs::write(path, encoded).map_err(|e| format!("写入 {} 失败：{e}", path.display()))?;
    let text = if open.iter().any(|item| item == path) {
        Some(new_text)
    } else {
        None
    };
    Ok(ReplaceOutcome::Changed { count, text })
}

/// 相对 root 的 `/` 分隔路径；不在 root 下时返回 None。
fn rel_path(root: &Path, path: &Path) -> Option<String> {
    let rel = path.strip_prefix(root).ok()?;
    Some(rel.to_string_lossy().replace('\\', "/"))
}

/// 按 `.gitignore` 与包含/排除 glob 过滤待处理文件。
fn filter_files(
    root: &Path,
    files: Vec<PathBuf>,
    include: &str,
    exclude: &str,
    ignore: bool,
) -> Vec<PathBuf> {
    let include = include.trim();
    let exclude = exclude.trim();
    let rules = if ignore {
        glob::IgnoreRules::load(root)
    } else {
        glob::IgnoreRules::empty()
    };
    files
        .into_iter()
        .filter(|path| {
            let Some(rel) = rel_path(root, path) else {
                return true;
            };
            if !rules.is_empty() && rules.is_ignored(&rel, false) {
                return false;
            }
            if !include.is_empty() && !glob::match_patterns(include, &rel) {
                return false;
            }
            if !exclude.is_empty() && glob::match_patterns(exclude, &rel) {
                return false;
            }
            true
        })
        .collect()
}

impl App {
    /// 工程搜索选项切换后刷新结果。
    pub(crate) fn refresh_workspace_options(&mut self) {
        if !self.workspace_query.trim().is_empty() {
            self.workspace_search();
            return;
        }
        let mut flags = String::new();
        if self.workspace_case {
            flags.push_str("[Aa] ");
        }
        if self.workspace_word {
            flags.push_str("[全词] ");
        }
        if !self.config.workspace_ignore {
            flags.push_str("[不忽略] ");
        }
        if !self.config.workspace_include.trim().is_empty() {
            flags.push_str(&format!("[包含 {}] ", self.config.workspace_include.trim()));
        }
        if !self.config.workspace_exclude.trim().is_empty() {
            flags.push_str(&format!("[排除 {}] ", self.config.workspace_exclude.trim()));
        }
        self.workspace_note = if flags.is_empty() {
            "Alt+C 大小写   Alt+W 全词   Alt+G .gitignore".into()
        } else {
            format!("搜索选项：{}", flags.trim_end())
        };
        self.set_status(self.workspace_note.clone());
    }

    /// 打开搜索面板并聚焦输入。
    pub fn workspace_focus(&mut self) {
        self.sidebar.mode = SidebarMode::Search;
        self.config.sidebar = true;
        self.focus = Focus::Sidebar;
        self.resize(self.layout.cols, self.layout.rows);
        if self.workspace_query.is_empty() {
            self.workspace_note =
                "Enter 搜索，/正则/，Alt+C/Aa，Alt+W 全词，Alt+G 忽略，↑↓ 历史".into();
        }
    }

    fn workspace_engine(&self) -> Result<SearchEngine, String> {
        let query = self.workspace_query.trim();
        if query.is_empty() {
            return Err("请输入搜索内容".into());
        }
        let (pattern, regex) = if query.len() > 2 && query.starts_with('/') && query.ends_with('/') {
            (&query[1..query.len() - 1], true)
        } else {
            (query, false)
        };
        let engine = SearchEngine::new(
            pattern,
            SearchOptions {
                case_sensitive: self.workspace_case,
                whole_word: self.workspace_word,
                regex,
            },
        );
        if !engine.is_valid() {
            return Err(engine.error().unwrap_or_else(|| "搜索表达式无效".into()));
        }
        Ok(engine)
    }

    /// 扫描工程目录并收集匹配。
    pub fn workspace_search(&mut self) {
        self.workspace_hits.clear();
        self.workspace_selected = 0;
        let engine = match self.workspace_engine() {
            Ok(engine) => engine,
            Err(error) => {
                self.workspace_note = error;
                return;
            }
        };
        let files = crate::ui::commands::collect_files_multi(&self.sidebar.roots, MAX_FILES);
        let files = filter_files(
            &self.cwd,
            files,
            &self.config.workspace_include,
            &self.config.workspace_exclude,
            self.config.workspace_ignore,
        );
        self.config.push_search_history(&self.workspace_query);
        self.workspace_history_index = 0;
        let prefilter = Prefilter::for_engine(&engine);
        let parts = worker_count(files.len());
        let mut hits = Vec::new();
        let mut scanned = 0usize;
        let mut truncated = false;
        if parts <= 1 {
            let outcome = scan_files(&files, &engine, prefilter.as_ref());
            hits = outcome.hits;
            scanned = outcome.scanned;
            truncated = outcome.truncated;
        } else {
            let outcomes: Vec<ScanOutcome> = std::thread::scope(|scope| {
                let mut handles = Vec::new();
                for chunk in split_chunks(&files, parts) {
                    let engine = &engine;
                    let filter = prefilter.as_ref();
                    handles.push(scope.spawn(move || scan_files(chunk, engine, filter)));
                }
                handles
                    .into_iter()
                    .filter_map(|handle| handle.join().ok())
                    .collect()
            });
            for outcome in outcomes {
                hits.extend(outcome.hits);
                scanned += outcome.scanned;
                truncated |= outcome.truncated;
            }
        }
        if hits.len() > TOTAL_LIMIT {
            hits.truncate(TOTAL_LIMIT);
            truncated = true;
        }
        self.workspace_hits = hits;
        self.workspace_note = if truncated {
            "结果过多，已截断（请缩小搜索范围）".into()
        } else if self.workspace_hits.is_empty() && files.is_empty() {
            "没有可搜索的文件（检查包含/排除或 .gitignore 规则）".into()
        } else {
            format!(
                "{} 个结果，扫描 {} 个文件",
                self.workspace_hits.len(),
                scanned
            )
        };
        self.set_status(self.workspace_note.clone());
    }

    /// 打开选中的搜索结果。
    pub fn workspace_open_hit(&mut self, index: usize) {
        let Some(hit) = self.workspace_hits.get(index).cloned() else {
            return;
        };
        if let Err(error) = self.open_file(&hit.path) {
            self.set_error(error);
            return;
        }
        let line = hit.line.min(self.doc().line_count().saturating_sub(1));
        let col = hit.col.min(self.doc().line(line).chars().count());
        self.doc_mut().set_cursor(Pos::new(line, col));
        self.focus = Focus::Editor;
        self.ensure_visible();
        self.set_status(format!("{}:{}", hit.path.display(), line + 1));
    }

    /// 搜索面板按键。
    pub fn workspace_key(&mut self, key: Key) -> bool {
        use KeyCode::*;
        let control = key.mods.ctrl;
        match key.code {
            Up => {
                // 尚未搜索（结果为空）时上下键召回搜索历史；否则移动结果选中项。
                if self.workspace_hits.is_empty()
                    && self.workspace_history_index < self.config.search_history.len()
                {
                    self.workspace_history_index += 1;
                    self.workspace_query =
                        self.config.search_history[self.workspace_history_index - 1].clone();
                    self.workspace_note = format!(
                        "历史 {}/{}，Enter 搜索",
                        self.workspace_history_index,
                        self.config.search_history.len()
                    );
                } else if self.workspace_selected > 0 {
                    self.workspace_selected -= 1;
                }
                true
            }
            Down => {
                if self.workspace_hits.is_empty() && self.workspace_history_index > 0 {
                    self.workspace_history_index -= 1;
                    if self.workspace_history_index == 0 {
                        self.workspace_query.clear();
                    } else {
                        self.workspace_query =
                            self.config.search_history[self.workspace_history_index - 1].clone();
                    }
                    self.workspace_note.clear();
                } else if self.workspace_selected + 1 < self.workspace_hits.len() {
                    self.workspace_selected += 1;
                }
                true
            }
            Enter => {
                if self.workspace_hits.is_empty() {
                    self.workspace_search();
                } else {
                    self.workspace_open_hit(self.workspace_selected);
                }
                true
            }
            Backspace => {
                self.workspace_query.pop();
                self.workspace_hits.clear();
                self.workspace_note.clear();
                self.workspace_history_index = 0;
                true
            }
            Esc => {
                self.focus = Focus::Editor;
                true
            }
            Char('c') | Char('C') if key.mods.alt => {
                self.workspace_case = !self.workspace_case;
                self.refresh_workspace_options();
                true
            }
            Char('w') | Char('W') if key.mods.alt => {
                self.workspace_word = !self.workspace_word;
                self.refresh_workspace_options();
                true
            }
            Char('g') | Char('G') if key.mods.alt => {
                self.config.workspace_ignore = !self.config.workspace_ignore;
                self.refresh_workspace_options();
                true
            }
            Char(ch) if !control && !key.mods.alt => {
                self.workspace_query.push(ch);
                self.workspace_hits.clear();
                self.workspace_note.clear();
                self.workspace_history_index = 0;
                true
            }
            Char('r') if control => {
                self.workspace_search();
                true
            }
            _ => false,
        }
    }

    /// 工程替换：支持字面量与 `/正则/`，替换串支持 `$1` 与 `\n` 等转义。
    pub fn workspace_replace_all(&mut self, replacement: &str) -> Result<String, String> {
        let engine = self.workspace_engine()?;
        let files = crate::ui::commands::collect_files_multi(&self.sidebar.roots, MAX_FILES);
        let files = filter_files(
            &self.cwd,
            files,
            &self.config.workspace_include,
            &self.config.workspace_exclude,
            self.config.workspace_ignore,
        );
        let prefilter = Prefilter::for_engine(&engine);
        let dirty: Vec<PathBuf> = self
            .tabs
            .iter()
            .filter(|tab| tab.doc.is_dirty())
            .filter_map(|tab| tab.doc.path.clone())
            .collect();
        let open: Vec<PathBuf> = self
            .tabs
            .iter()
            .filter_map(|tab| tab.doc.path.clone())
            .collect();
        let parts = worker_count(files.len());

        let mut changed_files = 0usize;
        let mut total = 0usize;
        let mut errors: Vec<String> = Vec::new();
        let mut updated: Vec<(PathBuf, String)> = Vec::new();
        let mut merge = |batch: ReplaceBatch| {
            for (path, outcome) in batch.results {
                match outcome {
                    ReplaceOutcome::Skipped => {}
                    ReplaceOutcome::Unchanged => {}
                    ReplaceOutcome::Changed { count, text } => {
                        changed_files += 1;
                        total += count;
                        if let Some(text) = text {
                            updated.push((path, text));
                        }
                    }
                }
            }
            errors.extend(batch.errors);
        };

        if parts <= 1 {
            merge(replace_files(
                &files,
                &engine,
                replacement,
                prefilter.as_ref(),
                &dirty,
                &open,
            ));
        } else {
            let batches: Vec<ReplaceBatch> = std::thread::scope(|scope| {
                let mut handles = Vec::new();
                for chunk in split_chunks(&files, parts) {
                    let engine = &engine;
                    let filter = prefilter.as_ref();
                    let dirty = &dirty;
                    let open = &open;
                    handles.push(scope.spawn(move || {
                        replace_files(chunk, engine, replacement, filter, dirty, open)
                    }));
                }
                handles
                    .into_iter()
                    .filter_map(|handle| handle.join().ok())
                    .collect()
            });
            for batch in batches {
                merge(batch);
            }
        }

        // 有未保存改动的打开文件不写盘：替换以可撤销编辑应用到编辑器内容。
        let config = self.config.clone();
        let width = self.text_width();
        let mut memory_hits = 0usize;
        let mut memory_files = 0usize;
        for tab in &mut self.tabs {
            if !tab.doc.is_dirty() {
                continue;
            }
            let Some(path) = tab.doc.path.clone() else {
                continue;
            };
            if !files.iter().any(|item| item == &path) {
                continue;
            }
            let edits = dirty_tab_edits(&engine, &tab.doc, replacement);
            if edits.is_empty() {
                continue;
            }
            tab.doc.replace_ranges_each(&edits);
            // 多光标只保留第一个替换结果，避免一次工程替换产生大量光标。
            tab.doc.cursors.truncate(1);
            tab.refresh(&config, width, true);
            memory_files += 1;
            memory_hits += edits.len();
        }

        // 同步已打开且未修改的标签页（这些文件已由工作线程写盘）。
        for (path, text) in updated {
            for tab in &mut self.tabs {
                if tab.doc.path.as_deref() == Some(path.as_path()) {
                    let language = tab.doc.language;
                    let encoding = tab.doc.encoding;
                    let eol = tab.doc.eol;
                    let mut doc = Document::from_text(&text, Some(path.clone()));
                    doc.language = language;
                    doc.encoding = encoding;
                    doc.eol = eol;
                    tab.doc = doc;
                    tab.refresh(&config, width, true);
                }
            }
        }

        let mut message = format!("已替换 {total} 处，修改 {changed_files} 个文件");
        if memory_files > 0 {
            message.push_str(&format!(
                "；{memory_files} 个未保存文件在内存中替换 {memory_hits} 处（未写盘）"
            ));
        }
        if !errors.is_empty() {
            message.push_str(&format!("；{} 个文件失败：{}", errors.len(), errors[0]));
        }
        self.workspace_search();
        self.set_status(message.clone());
        Ok(message)
    }

    /// 侧边栏搜索结果的行数（用于鼠标滚动换算）。
    pub fn workspace_rows(&self) -> usize {
        self.workspace_hits.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "textm-workspace-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn regex_engine() -> SearchEngine {
        SearchEngine::new(
            "foo@(\\w+)",
            SearchOptions {
                regex: true,
                case_sensitive: false,
                whole_word: false,
            },
        )
    }

    #[test]
    fn scan_and_replace_with_groups() {
        let dir = temp_dir("scan");
        let a = dir.join("a.txt");
        let b = dir.join("b.txt");
        std::fs::write(&a, "foo@bar\nnone\n").unwrap();
        std::fs::write(&b, "xx baz@qux\nFOO@BAR\n").unwrap();
        let engine = regex_engine();
        let prefilter = Prefilter::for_engine(&engine);
        assert!(prefilter.is_some());

        let files = vec![a.clone(), b.clone()];
        let outcome = scan_files(&files, &engine, prefilter.as_ref());
        assert_eq!(outcome.scanned, 2);
        assert_eq!(outcome.hits.len(), 2);
        assert!(!outcome.truncated);

        // $1 捕获组替换 + 保留末尾换行
        let batch = replace_files(
            &files,
            &engine,
            "mail:$1",
            prefilter.as_ref(),
            &[],
            std::slice::from_ref(&a),
        );
        assert!(batch.errors.is_empty());
        assert_eq!(std::fs::read_to_string(&a).unwrap(), "mail:bar\nnone\n");
        assert_eq!(
            std::fs::read_to_string(&b).unwrap(),
            "xx baz@qux\nmail:BAR\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cross_line_regex_search_and_replace() {
        let dir = temp_dir("crossline");
        let file = dir.join("multi.txt");
        std::fs::write(&file, "head\nfoo\nbar\ntail\n").unwrap();
        let engine = SearchEngine::new(
            "foo\\nbar",
            SearchOptions {
                regex: true,
                case_sensitive: false,
                whole_word: false,
            },
        );
        let outcome = scan_files(std::slice::from_ref(&file), &engine, None);
        assert_eq!(outcome.hits.len(), 1);
        assert_eq!(outcome.hits[0].line, 1);
        assert_eq!(outcome.hits[0].col, 0);

        let batch = replace_files(
            std::slice::from_ref(&file),
            &engine,
            "joined",
            None,
            &[],
            &[],
        );
        assert!(batch.errors.is_empty());
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "head\njoined\ntail\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn utf16_files_are_searched() {
        let dir = temp_dir("utf16");
        let file = dir.join("u16.txt");
        // 带 BOM 的 UTF-16LE
        let mut bytes = vec![0xFF, 0xFE];
        bytes.extend(encoding::encode(
            "alpha\nfoo@bar\n",
            encoding::Encoding::Utf16Le,
            encoding::Eol::Lf,
        ));
        std::fs::write(&file, bytes).unwrap();
        let engine = SearchEngine::new("foo", SearchOptions::default());
        let prefilter = Prefilter::for_engine(&engine);
        assert!(prefilter.is_some());
        let outcome = scan_files(std::slice::from_ref(&file), &engine, prefilter.as_ref());
        assert_eq!(outcome.scanned, 1);
        assert_eq!(outcome.hits.len(), 1);
        assert_eq!(outcome.hits[0].line, 1);

        let batch = replace_files(
            std::slice::from_ref(&file),
            &engine,
            "baz",
            prefilter.as_ref(),
            &[],
            &[],
        );
        assert!(batch.errors.is_empty());
        let saved = std::fs::read(&file).unwrap();
        assert!(saved.starts_with(&[0xFF, 0xFE]), "BOM 应保留");
        let decoded = encoding::decode(&saved);
        assert_eq!(decoded.text, "alpha\nbaz@bar\n");
        assert_eq!(decoded.encoding, encoding::Encoding::Utf16Le);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn dirty_tab_edits_apply_in_memory() {
        // 字面量：多处替换
        let engine = SearchEngine::new("foo", SearchOptions::default());
        let mut doc = Document::from_text("a foo b\nfoo\n", None);
        let edits = dirty_tab_edits(&engine, &doc, "X");
        assert_eq!(edits.len(), 2);
        doc.replace_ranges_each(&edits);
        assert_eq!(doc.text(), "a X b\nX\n");

        // 跨行正则：单处替换
        let engine = SearchEngine::new(
            "foo\\nbar",
            SearchOptions {
                regex: true,
                case_sensitive: false,
                whole_word: false,
            },
        );
        let mut doc = Document::from_text("head\nfoo\nbar\ntail\n", None);
        let edits = dirty_tab_edits(&engine, &doc, "joined");
        assert_eq!(edits.len(), 1);
        doc.replace_ranges_each(&edits);
        assert_eq!(doc.text(), "head\njoined\ntail\n");
    }

    #[test]
    fn prefilter_skips_unrelated_files() {
        let filter = Prefilter {
            needle: b"needle".to_vec(),
            ignore_case: true,
        };
        assert!(filter.allows(b"...NEEDLE..."));
        assert!(!filter.allows(b"...other..."));
        assert!(!filter.allows(b"need"));
    }

    #[test]
    fn filters_respect_gitignore_include_exclude() {
        let dir = temp_dir("filter");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::create_dir_all(dir.join("build")).unwrap();
        std::fs::write(dir.join(".gitignore"), "build/\n*.log\n!keep.log\n").unwrap();
        let main = dir.join("src").join("main.rs");
        let gen = dir.join("src").join("gen.rs");
        let doc = dir.join("notes.md");
        let log = dir.join("a.log");
        let keep = dir.join("keep.log");
        let built = dir.join("build").join("x.rs");
        for path in [&main, &gen, &doc, &log, &keep, &built] {
            std::fs::write(path, "x").unwrap();
        }
        let files = vec![
            main.clone(),
            gen.clone(),
            doc.clone(),
            log.clone(),
            keep.clone(),
            built.clone(),
        ];
        // .gitignore 生效 + 包含 *.rs：build 被忽略
        let filtered = filter_files(&dir, files.clone(), "*.rs", "", true);
        assert_eq!(filtered, vec![main.clone(), gen.clone()]);
        // 关闭忽略后 build 也参与
        let filtered = filter_files(&dir, files.clone(), "*.rs", "", false);
        assert_eq!(filtered, vec![main.clone(), gen.clone(), built.clone()]);
        // 排除：*.log 与 src/** 都不参与
        let filtered = filter_files(&dir, files.clone(), "", "*.log, src/**", false);
        assert_eq!(filtered, vec![doc.clone(), built]);
        // 包含：只搜 src 目录
        let filtered = filter_files(&dir, files, "src/**", "", true);
        assert_eq!(filtered, vec![main, gen]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn dirty_files_are_skipped() {
        let dir = temp_dir("dirty");
        let file = dir.join("x.txt");
        std::fs::write(&file, "foo\n").unwrap();
        let engine = SearchEngine::new("foo", SearchOptions::default());
        let batch = replace_files(
            std::slice::from_ref(&file),
            &engine,
            "bar",
            None,
            std::slice::from_ref(&file),
            &[],
        );
        assert!(batch.errors.is_empty());
        match &batch.results[0].1 {
            ReplaceOutcome::Skipped => {}
            _ => panic!("有未保存改动的文件应被跳过"),
        }
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "foo\n");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

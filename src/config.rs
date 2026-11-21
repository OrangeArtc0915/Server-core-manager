//! 配置：`%APPDATA%\Textm\config.ini`（`TEXTM_CONFIG` 可覆盖路径）。
//!
//! 简单的 `key = value` 格式，支持 `;` / `#` 注释；未知键保留不报错。

use std::collections::HashMap;
use std::path::PathBuf;

use crate::platform::log;

#[derive(Clone, Debug)]
pub struct Config {
    pub theme: String,
    pub tab_width: usize,
    pub use_spaces: bool,
    pub wrap: bool,
    pub minimap: bool,
    pub minimap_width: usize,
    pub sidebar: bool,
    pub sidebar_width: usize,
    pub show_whitespace: bool,
    pub auto_indent: bool,
    /// 自动闭合括号/引号。
    pub auto_pair: bool,
    /// 停止输入后自动保存（纯文本类文件）。
    pub autosave: bool,
    /// 顶部固定显示外层代码块首行。
    pub sticky_scroll: bool,
    /// 括号按嵌套深度着色（彩虹括号）。
    pub rainbow_brackets: bool,
    /// 超宽窗口下编辑器内容居中，限制阅读宽度。
    pub centered: bool,
    /// 启动时恢复上次打开的文件与光标。
    pub restore_session: bool,
    pub folding: bool,
    pub confirm_close: bool,
    pub confirm_multiline_paste: bool,
    pub icons: bool,
    /// 图标字体：auto / nerd / off。
    pub nerd_font: String,
    pub show_hidden: bool,
    pub last_dir: Option<PathBuf>,
    pub recent: Vec<PathBuf>,
    /// 工程搜索：包含 / 排除 glob（逗号或分号分隔）。
    pub workspace_include: String,
    pub workspace_exclude: String,
    /// 工程搜索是否遵循工程根目录的 `.gitignore`。
    pub workspace_ignore: bool,
    /// 工程搜索历史（最新在前）。
    pub search_history: Vec<String>,
    /// 自定义键位：(组合键, 命令名)，例如 ("ctrl+alt+p", "Palette")。
    pub keymap: Vec<(String, String)>,
    /// 工作区文件夹（多根）。
    pub workspace_folders: Vec<PathBuf>,
    /// 被禁用的插件名称。
    pub disabled_plugins: Vec<String>,
    /// SSH 远程主机：名称 → `[user@]host[:port]`。
    pub remotes: Vec<(String, String)>,
    /// SSH 远程主机的默认目录：名称 → 远端路径。
    pub remote_roots: Vec<(String, String)>,
    /// 调试适配器：类型 → 启动命令，例如 `python = python -m debugpy.adapter`。
    pub debug_adapters: HashMap<String, String>,
    /// 是否开启插件功能（默认关闭：隐藏插件入口，不加载插件）。
    pub plugins_enabled: bool,
    pub ui_language: String,
    pub tab_position: String,
    pub gui_font: String,
    pub gui_font_size: u16,
    pub gui: bool,
    pub git: bool,
    /// 语言 → 语言服务器命令，例如 `rust = rust-analyzer`。
    pub lsp: HashMap<String, String>,
    /// 输入标识符后自动弹出补全列表（需要语言服务器已连接）。
    pub lsp_auto_complete: bool,
    /// 输入 `(` / `,` 时自动显示签名帮助。
    pub lsp_signature_help: bool,
    /// 在代码行内显示类型 / 参数名等内联提示。
    pub lsp_inlay_hints: bool,
    pub backdrop: bool,
    pub backdrop_alpha: u8,
    /// Vim 模态编辑（默认开启）。
    pub vim: bool,
    /// 缩进参考线。
    pub indent_guides: bool,
    /// 保存前调用语言服务器格式化。
    pub format_on_save: bool,
    /// 底部终端面板高度（0 表示关闭）。
    pub terminal_height: usize,
    /// 终端 shell（空表示自动：powershell / cmd）。
    pub terminal_shell: String,
    /// 界面布局：vscode（顶部菜单/标签 + 活动栏）或 sqlmux（双 pane、底部标签）。
    pub layout: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            theme: "tokyonight-storm".into(),
            tab_width: 4,
            use_spaces: true,
            wrap: false,
            minimap: true,
            minimap_width: 12,
            sidebar: true,
            sidebar_width: 26,
            show_whitespace: false,
            auto_indent: true,
            auto_pair: true,
            autosave: false,
            sticky_scroll: true,
            rainbow_brackets: true,
            centered: false,
            restore_session: true,
            folding: true,
            confirm_close: true,
            confirm_multiline_paste: true,
            icons: true,
            nerd_font: "auto".into(),
            show_hidden: false,
            last_dir: None,
            recent: Vec::new(),
            workspace_include: String::new(),
            workspace_exclude: String::new(),
            workspace_ignore: true,
            search_history: Vec::new(),
            keymap: Vec::new(),
            workspace_folders: Vec::new(),
            disabled_plugins: Vec::new(),
            remotes: Vec::new(),
            remote_roots: Vec::new(),
            debug_adapters: HashMap::new(),
            plugins_enabled: false,
            ui_language: "zh".into(),
            tab_position: "top".into(),
            gui_font: "Consolas".into(),
            gui_font_size: 17,
            gui: false,
            git: true,
            lsp: HashMap::new(),
            lsp_auto_complete: true,
            lsp_signature_help: true,
            lsp_inlay_hints: true,
            backdrop: false,
            backdrop_alpha: 80,
            vim: true,
            indent_guides: true,
            format_on_save: false,
            terminal_height: 12,
            terminal_shell: String::new(),
            layout: "vscode".into(),
        }
    }
}

impl Config {
    pub fn path() -> PathBuf {
        log::config_path()
    }

    /// 读取配置；文件不存在时返回默认值。
    pub fn load() -> Config {
        let mut config = Config::default();
        let path = Self::path();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(_) => return config,
        };
        let mut recent_map: HashMap<usize, PathBuf> = HashMap::new();
        let mut search_map: HashMap<usize, String> = HashMap::new();
        let mut folder_map: HashMap<usize, PathBuf> = HashMap::new();
        let mut remote_map: HashMap<String, String> = HashMap::new();
        let mut remote_root_map: HashMap<String, String> = HashMap::new();
        let mut debug_map: HashMap<String, String> = HashMap::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with(';') || line.starts_with('#') {
                continue;
            }
            if line.starts_with('[') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let key = key.trim().to_ascii_lowercase();
            let value = value.trim();
            let value = value.trim_matches('"');
            match key.as_str() {
                "theme" => config.theme = value.to_string(),
                "tab_width" => {
                    if let Ok(v) = value.parse::<usize>() {
                        config.tab_width = v.clamp(1, 16);
                    }
                }
                "use_spaces" => config.use_spaces = truthy(value),
                "wrap" => config.wrap = truthy(value),
                "minimap" => config.minimap = truthy(value),
                "minimap_width" => {
                    if let Ok(v) = value.parse::<usize>() {
                        config.minimap_width = v.clamp(3, 30);
                    }
                }
                "sidebar" => config.sidebar = truthy(value),
                "sidebar_width" => {
                    if let Ok(v) = value.parse::<usize>() {
                        config.sidebar_width = v.clamp(12, 60);
                    }
                }
                "show_whitespace" => config.show_whitespace = truthy(value),
                "auto_indent" => config.auto_indent = truthy(value),
                "auto_pair" => config.auto_pair = truthy(value),
                "autosave" => config.autosave = truthy(value),
                "sticky_scroll" => config.sticky_scroll = truthy(value),
                "rainbow_brackets" => config.rainbow_brackets = truthy(value),
                "centered" => config.centered = truthy(value),
                "restore_session" => config.restore_session = truthy(value),
                "folding" => config.folding = truthy(value),
                "confirm_close" => config.confirm_close = truthy(value),
                "confirm_multiline_paste" => config.confirm_multiline_paste = truthy(value),
                "icons" => config.icons = !matches!(value, "ascii" | "0" | "false"),
                "nerd_font" => config.nerd_font = value.to_string(),
                "show_hidden" => config.show_hidden = truthy(value),
                "last_dir" => config.last_dir = Some(PathBuf::from(value)),
                "workspace_include" => config.workspace_include = value.to_string(),
                "workspace_exclude" => config.workspace_exclude = value.to_string(),
                "workspace_ignore" => config.workspace_ignore = truthy(value),
                "language" | "ui_language" => config.ui_language = value.to_string(),
                "tab_position" => config.tab_position = value.to_string(),
                "font" | "gui_font" => config.gui_font = value.to_string(),
                "font_size" | "gui_font_size" => {
                    if let Ok(v) = value.parse::<u16>() {
                        config.gui_font_size = v.clamp(8, 48);
                    }
                }
                "gui" => config.gui = truthy(value),
                "git" => config.git = truthy(value),
                "lsp_auto_complete" => config.lsp_auto_complete = truthy(value),
                "lsp_signature_help" => config.lsp_signature_help = truthy(value),
                "lsp_inlay_hints" => config.lsp_inlay_hints = truthy(value),
                "backdrop" => config.backdrop = matches!(value, "mica" | "acrylic" | "1" | "true"),
                "vim" => config.vim = truthy(value),
                "indent_guides" => config.indent_guides = truthy(value),
                "format_on_save" => config.format_on_save = truthy(value),
                "terminal_height" => {
                    if let Ok(v) = value.parse::<usize>() {
                        config.terminal_height = v.clamp(0, 40);
                    }
                }
                "terminal_shell" | "shell" => config.terminal_shell = value.to_string(),
                "layout" => config.layout = value.to_string(),
                "plugins_enabled" => config.plugins_enabled = truthy(value),
                "plugins_disabled" => {
                    config.disabled_plugins = value
                        .split([',', ';'])
                        .map(|item| item.trim().to_string())
                        .filter(|item| !item.is_empty())
                        .collect();
                }
                "backdrop_alpha" => {
                    if let Ok(v) = value.parse::<u8>() {
                        config.backdrop_alpha = v.clamp(0, 100);
                    }
                }
                other => {
                    if let Some(index) = other.strip_prefix("recent") {
                        if let (Ok(index), true) = (index.parse::<usize>(), !value.is_empty()) {
                            recent_map.insert(index, PathBuf::from(value));
                        }
                    } else if let Some(index) = other.strip_prefix("search") {
                        if let (Ok(index), true) = (index.parse::<usize>(), !value.is_empty()) {
                            search_map.insert(index, value.to_string());
                        }
                    } else if let Some(lang) = other.strip_prefix("lsp.") {
                        config.lsp.insert(lang.to_string(), value.to_string());
                    } else if let Some(lang) = other.strip_prefix("lsp_") {
                        config.lsp.insert(lang.to_string(), value.to_string());
                    } else if let Some(combo) = other.strip_prefix("key.") {
                        config.keymap.push((
                            combo.trim().to_ascii_lowercase(),
                            value.trim().to_string(),
                        ));
                    } else if let Some(rest) = other.strip_prefix("remote.") {
                        if let Some((name, suffix)) = rest.rsplit_once('.') {
                            if suffix.eq_ignore_ascii_case("root") {
                                remote_root_map.insert(name.to_string(), value.to_string());
                            } else if !value.is_empty() {
                                remote_map.insert(rest.to_string(), value.to_string());
                            }
                        } else if !value.is_empty() {
                            remote_map.insert(rest.to_string(), value.to_string());
                        }
                    } else if let Some(kind) = other.strip_prefix("debug.") {
                        if !value.is_empty() {
                            debug_map.insert(kind.to_string(), value.to_string());
                        }
                    } else if let Some(index) = other.strip_prefix("folder") {
                        if let Ok(index) = index.parse::<usize>() {
                            folder_map.insert(index, PathBuf::from(value));
                        }
                    }
                }
            }
        }
        let mut indexes: Vec<usize> = recent_map.keys().copied().collect();
        indexes.sort_unstable();
        config.recent = indexes
            .into_iter()
            .filter_map(|i| recent_map.remove(&i))
            .take(10)
            .collect();
        let mut search_indexes: Vec<usize> = search_map.keys().copied().collect();
        search_indexes.sort_unstable();
        config.search_history = search_indexes
            .into_iter()
            .filter_map(|i| search_map.remove(&i))
            .take(10)
            .collect();
        let mut folder_indexes: Vec<usize> = folder_map.keys().copied().collect();
        folder_indexes.sort_unstable();
        config.workspace_folders = folder_indexes
            .into_iter()
            .filter_map(|i| folder_map.remove(&i))
            .filter(|p| !p.as_os_str().is_empty())
            .take(10)
            .collect();
        let mut remote_names: Vec<String> = remote_map.keys().cloned().collect();
        remote_names.sort();
        config.remotes = remote_names
            .into_iter()
            .filter_map(|name| remote_map.remove(&name).map(|spec| (name, spec)))
            .collect();
        let mut root_names: Vec<String> = remote_root_map.keys().cloned().collect();
        root_names.sort();
        config.remote_roots = root_names
            .into_iter()
            .filter_map(|name| remote_root_map.remove(&name).map(|root| (name, root)))
            .collect();
        config.debug_adapters = debug_map;
        config.load_json();
        config
    }

    /// 写回配置文件；失败只记录日志，不影响编辑。
    pub fn save(&self) {
        let path = Self::path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let mut out = String::new();
        out.push_str("; Textm 2 配置文件\n");
        out.push_str("; 修改后重新启动生效；主题 / 快捷键也可在命令面板中调整\n\n");
        out.push_str(&format!("theme = {}\n", self.theme));
        out.push_str(&format!("tab_width = {}\n", self.tab_width));
        out.push_str(&format!("use_spaces = {}\n", self.use_spaces));
        out.push_str(&format!("wrap = {}\n", self.wrap));
        out.push_str(&format!("minimap = {}\n", self.minimap));
        out.push_str(&format!("minimap_width = {}\n", self.minimap_width));
        out.push_str(&format!("sidebar = {}\n", self.sidebar));
        out.push_str(&format!("sidebar_width = {}\n", self.sidebar_width));
        out.push_str(&format!("show_whitespace = {}\n", self.show_whitespace));
        out.push_str(&format!("auto_indent = {}\n", self.auto_indent));
        out.push_str(&format!("auto_pair = {}\n", self.auto_pair));
        out.push_str(&format!("autosave = {}\n", self.autosave));
        out.push_str(&format!("sticky_scroll = {}\n", self.sticky_scroll));
        out.push_str(&format!("rainbow_brackets = {}\n", self.rainbow_brackets));
        out.push_str(&format!("centered = {}\n", self.centered));
        out.push_str(&format!("restore_session = {}\n", self.restore_session));
        out.push_str(&format!("folding = {}\n", self.folding));
        out.push_str(&format!("confirm_close = {}\n", self.confirm_close));
        out.push_str(&format!(
            "confirm_multiline_paste = {}\n",
            self.confirm_multiline_paste
        ));
        out.push_str(&format!(
            "icons = {}\n",
            if self.icons { "unicode" } else { "ascii" }
        ));
        out.push_str(&format!("nerd_font = {}\n", self.nerd_font));
        out.push_str(&format!("show_hidden = {}\n", self.show_hidden));
        out.push_str(&format!("language = {}\n", self.ui_language));
        out.push_str(&format!("tab_position = {}\n", self.tab_position));
        out.push_str(&format!("font = {}\n", self.gui_font));
        out.push_str(&format!("font_size = {}\n", self.gui_font_size));
        out.push_str(&format!("gui = {}\n", self.gui));
        out.push_str(&format!("git = {}\n", self.git));
        out.push_str(&format!("lsp_auto_complete = {}\n", self.lsp_auto_complete));
        out.push_str(&format!("lsp_signature_help = {}\n", self.lsp_signature_help));
        out.push_str(&format!("lsp_inlay_hints = {}\n", self.lsp_inlay_hints));
        out.push_str(&format!("backdrop = {}\n", self.backdrop));
        out.push_str(&format!("backdrop_alpha = {}\n", self.backdrop_alpha));
        out.push_str(&format!("vim = {}\n", self.vim));
        out.push_str(&format!("indent_guides = {}\n", self.indent_guides));
        out.push_str(&format!("format_on_save = {}\n", self.format_on_save));
        out.push_str(&format!("terminal_height = {}\n", self.terminal_height));
        out.push_str(&format!("layout = {}\n", self.layout));
        if !self.terminal_shell.is_empty() {
            out.push_str(&format!("terminal_shell = {}\n", self.terminal_shell));
        }
        out.push_str(&format!("workspace_include = {}\n", self.workspace_include));
        out.push_str(&format!("workspace_exclude = {}\n", self.workspace_exclude));
        out.push_str(&format!("workspace_ignore = {}\n", self.workspace_ignore));
        if let Some(dir) = &self.last_dir {
            out.push_str(&format!("last_dir = {}\n", dir.display()));
        }
        let mut langs: Vec<(&String, &String)> = self.lsp.iter().collect();
        langs.sort();
        for (lang, command) in langs {
            out.push_str(&format!("lsp.{lang} = {command}\n"));
        }
        for (index, path) in self.recent.iter().take(10).enumerate() {
            out.push_str(&format!("recent{index} = {}\n", path.display()));
        }
        for (index, query) in self.search_history.iter().take(10).enumerate() {
            out.push_str(&format!("search{index} = {query}\n"));
        }
        for (combo, cmd) in &self.keymap {
            out.push_str(&format!("key.{combo} = {cmd}\n"));
        }
        for (index, folder) in self.workspace_folders.iter().take(10).enumerate() {
            out.push_str(&format!("folder{index} = {}\n", folder.display()));
        }
        if !self.disabled_plugins.is_empty() {
            out.push_str(&format!(
                "plugins_disabled = {}\n",
                self.disabled_plugins.join(",")
            ));
        }
        for (name, spec) in &self.remotes {
            out.push_str(&format!("remote.{name} = {spec}\n"));
        }
        for (name, root) in &self.remote_roots {
            out.push_str(&format!("remote.{name}.root = {root}\n"));
        }
        let mut adapters: Vec<(&String, &String)> = self.debug_adapters.iter().collect();
        adapters.sort();
        for (kind, command) in adapters {
            out.push_str(&format!("debug.{kind} = {command}\n"));
        }
        out.push_str(&format!("plugins_enabled = {}\n", self.plugins_enabled));
        if let Err(e) = std::fs::write(&path, out) {
            log::warn(&format!("写配置失败 {}: {e}", path.display()));
        }
    }

    /// 打开文件后更新最近列表。
    pub fn push_recent(&mut self, path: &std::path::Path) {
        let absolute = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        self.recent.retain(|p| {
            p.canonicalize().unwrap_or_else(|_| p.clone()) != absolute
        });
        self.recent.insert(0, absolute);
        self.recent.truncate(10);
    }

    /// 记录一次工程搜索（去重后置顶，最多 10 条）。
    pub fn push_search_history(&mut self, query: &str) {
        let query = query.trim();
        if query.is_empty() {
            return;
        }
        self.search_history.retain(|item| item != query);
        self.search_history.insert(0, query.to_string());
        self.search_history.truncate(10);
    }

    pub fn language_en(&self) -> bool {
        matches!(self.ui_language.to_ascii_lowercase().as_str(), "en" | "en-us" | "english")
    }

    /// 读取 `%APPDATA%\Textm\settings.json` 与 `keybindings.json`（存在时覆盖 ini）。
    pub fn load_json(&mut self) {
        let Some(dir) = Self::path().parent().map(|p| p.to_path_buf()) else {
            return;
        };
        if let Ok(text) = std::fs::read_to_string(dir.join("settings.json")) {
            match crate::lsp::json::parse(&text) {
                Ok(crate::lsp::json::Json::Object(map)) => {
                    for (key, value) in &map {
                        self.apply_setting(key, value);
                    }
                }
                Ok(_) => log::warn("settings.json 顶层必须是对象"),
                Err(e) => log::warn(&format!("settings.json 解析失败：{e}")),
            }
        }
        if let Ok(text) = std::fs::read_to_string(dir.join("keybindings.json")) {
            match crate::lsp::json::parse(&text) {
                Ok(crate::lsp::json::Json::Array(items)) => {
                    for item in items {
                        let Some(key) = item.get("key").and_then(|v| v.as_str()) else {
                            continue;
                        };
                        let Some(command) = item.get("command").and_then(|v| v.as_str()) else {
                            continue;
                        };
                        if item.get("when").is_some() {
                            // 条件键暂不支持，直接忽略 when。
                        }
                        self.keymap.push((normalize_combo(key), command.to_string()));
                    }
                }
                Ok(_) => log::warn("keybindings.json 顶层必须是数组"),
                Err(e) => log::warn(&format!("keybindings.json 解析失败：{e}")),
            }
        }
    }

    /// settings.json 里的一个键。
    pub fn apply_setting(&mut self, key: &str, value: &crate::lsp::json::Json) {
        use crate::lsp::json::Json;
        let text = match value {
            Json::String(s) => s.clone(),
            Json::Number(n) => {
                if n.fract() == 0.0 {
                    format!("{}", *n as i64)
                } else {
                    n.to_string()
                }
            }
            Json::Bool(b) => b.to_string(),
            _ => return,
        };
        let lower = key.trim().to_ascii_lowercase();
        match lower.as_str() {
            "theme" => self.theme = text,
            "tab_width" | "editor.tabsize" => {
                if let Ok(v) = text.parse::<usize>() {
                    self.tab_width = v.clamp(1, 16);
                }
            }
            "use_spaces" | "editor.insertspaces" => self.use_spaces = truthy(&text),
            "wrap" | "editor.wordwrap" => self.wrap = !matches!(text.as_str(), "off" | "no" | "false"),
            "minimap" => self.minimap = truthy(&text),
            "minimap_width" => {
                if let Ok(v) = text.parse::<usize>() {
                    self.minimap_width = v.clamp(3, 30);
                }
            }
            "sidebar" => self.sidebar = truthy(&text),
            "sidebar_width" => {
                if let Ok(v) = text.parse::<usize>() {
                    self.sidebar_width = v.clamp(12, 60);
                }
            }
            "vim" | "editor.vim" => self.vim = truthy(&text),
            "indent_guides" | "editor.indentguides" => self.indent_guides = truthy(&text),
            "format_on_save" | "editor.formatonsave" => self.format_on_save = truthy(&text),
            "rainbow_brackets" | "editor.bracketpaircolorization" => {
                self.rainbow_brackets = truthy(&text)
            }
            "sticky_scroll" | "editor.stickyscroll" => self.sticky_scroll = truthy(&text),
            "autosave" | "files.autosave" => self.autosave = truthy(&text),
            "wrap_guides" => {}
            "terminal_height" | "terminal.height" => {
                if let Ok(v) = text.parse::<usize>() {
                    self.terminal_height = v.clamp(0, 40);
                }
            }
            "terminal_shell" | "terminal.shell" => self.terminal_shell = text,
            "layout" | "workbench.layout" => self.layout = text,
            "font" | "editor.fontfamily" => self.gui_font = text,
            "font_size" | "editor.fontsize" => {
                if let Ok(v) = text.parse::<u16>() {
                    self.gui_font_size = v.clamp(8, 48);
                }
            }
            "icons" => self.icons = !matches!(text.as_str(), "ascii" | "0" | "false"),
            "nerd_font" => self.nerd_font = text,
            "show_hidden" | "files.excludehidden" => self.show_hidden = truthy(&text),
            "confirm_close" => self.confirm_close = truthy(&text),
            "confirm_multiline_paste" => self.confirm_multiline_paste = truthy(&text),
            "restore_session" => self.restore_session = truthy(&text),
            "folding" | "editor.folding" => self.folding = truthy(&text),
            "auto_indent" | "editor.autoindent" => self.auto_indent = truthy(&text),
            "auto_pair" | "editor.autoclosingbrackets" => self.auto_pair = truthy(&text),
            "show_whitespace" | "editor.renderwhitespace" => {
                self.show_whitespace = !matches!(text.as_str(), "none" | "off" | "false")
            }
            "centered" => self.centered = truthy(&text),
            "git" => self.git = truthy(&text),
            "plugins_enabled" | "plugins.enabled" => self.plugins_enabled = truthy(&text),
            "lsp_auto_complete" | "editor.quicksuggestions" => {
                self.lsp_auto_complete = truthy(&text)
            }
            "lsp_signature_help" | "editor.parameterhints" => {
                self.lsp_signature_help = truthy(&text)
            }
            "lsp_inlay_hints" | "editor.inlayhints" => self.lsp_inlay_hints = truthy(&text),
            _ => {
                if let Some(lang) = lower.strip_prefix("lsp.") {
                    self.lsp.insert(lang.to_string(), text);
                }
            }
        }
    }
}

/// `Control+Alt+P` → `ctrl+alt+p`（VSCode 写法兼容）。
fn normalize_combo(combo: &str) -> String {
    combo
        .split('+')
        .map(|part| match part.trim().to_ascii_lowercase().as_str() {
            "control" | "ctrl" => "ctrl".to_string(),
            "option" | "alt" => "alt".to_string(),
            "cmd" | "command" | "win" => "ctrl".to_string(),
            other => other.to_string(),
        })
        .collect::<Vec<_>>()
        .join("+")
}

fn truthy(value: &str) -> bool {
    !matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "0" | "false" | "no" | "off"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_boolean_variants() {
        assert!(truthy("true"));
        assert!(truthy("1"));
        assert!(truthy("yes"));
        assert!(!truthy("false"));
        assert!(!truthy("off"));
    }

    #[test]
    fn search_history_dedupes_and_caps() {
        let mut config = Config::default();
        for index in 0..12 {
            config.push_search_history(&format!("q{index}"));
        }
        assert_eq!(config.search_history.len(), 10);
        config.push_search_history("q5");
        assert_eq!(config.search_history[0], "q5");
        assert_eq!(
            config.search_history.iter().filter(|item| *item == "q5").count(),
            1
        );
    }
}

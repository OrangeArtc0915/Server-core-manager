//! 配置体系：TOML 加载、默认值、profile / 配色 / 动作绑定。

pub mod toml;

mod schemes;

use std::path::PathBuf;

use crate::emulation::screen::Color;
use crate::render::GradientDir;

pub const CONFIG_ENV: &str = "SCTERM_CONFIG";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrueColorMode {
    Auto,
    Always,
    Never,
}

#[derive(Debug, Clone)]
pub struct RenderConfig {
    pub mouse: bool,
    pub truecolor: TrueColorMode,
    /// 控制台字体名（可选；由 conhost 决定是否可用）。
    pub font_face: Option<String>,
    /// 字号（像素高度）。
    pub font_size: Option<u16>,
    /// 背景渐变方向；`None` 表示纯色背景。
    pub gradient: Option<GradientDir>,
    /// 自定义渐变起始色（六进制）；不写则按配色方案背景自动推导。
    pub gradient_top: Option<Color>,
    /// 自定义渐变结束色。
    pub gradient_bottom: Option<Color>,
    /// 背景图片路径（相对路径按 `backgrounds` 目录解析）；`None` 表示不用图片。
    pub background_image: Option<String>,
    /// 背景图片不透明度（0–100），与渐变/配色背景混合。
    pub background_image_opacity: u8,
}

impl Default for RenderConfig {
    fn default() -> Self {
        RenderConfig {
            mouse: true,
            truecolor: TrueColorMode::Auto,
            font_face: None,
            font_size: None,
            gradient: Some(GradientDir::Vertical),
            gradient_top: None,
            gradient_bottom: None,
            background_image: None,
            background_image_opacity: 35,
        }
    }
}

/// 交互行为（`[behavior]`）。
#[derive(Debug, Clone)]
pub struct BehaviorConfig {
    /// 选中文本松开鼠标后自动复制。
    pub copy_on_select: bool,
    /// 关闭标签页（含中键、Ctrl+Shift+W）前弹确认。
    pub confirm_close: bool,
    /// 粘贴内容含换行时弹确认（避免误按回车执行命令）。
    pub confirm_multiline_paste: bool,
    /// 正常退出时保存标签页/窗格布局，下次启动恢复。
    pub restore_session: bool,
}

impl Default for BehaviorConfig {
    fn default() -> Self {
        BehaviorConfig {
            copy_on_select: false,
            confirm_close: true,
            confirm_multiline_paste: true,
            restore_session: true,
        }
    }
}

/// Quake 下拉热键（`[quake]`）。
#[derive(Debug, Clone)]
pub struct QuakeConfig {
    /// 是否注册全局呼出热键。
    pub enabled: bool,
    /// 热键写法，例如 `win+\``、`ctrl+alt+space`。
    pub hotkey: String,
    /// 呼出时是否把窗口置顶。
    pub topmost: bool,
}

impl Default for QuakeConfig {
    fn default() -> Self {
        QuakeConfig {
            enabled: false,
            hotkey: "win+`".to_string(),
            topmost: true,
        }
    }
}

/// profile 对背景渐变的覆盖：未写 = 继承全局，`off` = 关闭，其余 = 指定方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum GradientOverride {
    #[default]
    Inherit,
    Off,
    Dir(GradientDir),
}

#[derive(Debug, Clone)]
pub struct Profile {
    pub name: String,
    pub command: String,
    pub args: Vec<String>,
    pub cwd: Option<String>,
    pub color_scheme: Option<String>,
    /// 标签栏配色（可选）。为空时用默认灰底。
    pub tab_color: Option<Color>,
    /// 控制台字体覆盖（可选）；为空时沿用 `[render] font_face`。
    pub font_face: Option<String>,
    /// 字号覆盖（可选）；为空时沿用 `[render] font_size`。
    pub font_size: Option<u16>,
    /// 背景渐变覆盖；默认继承 `[render] gradient`。
    pub gradient: GradientOverride,
    /// 渐变起始色覆盖；为空时沿用 `[render] gradient_top`。
    pub gradient_top: Option<Color>,
    /// 渐变结束色覆盖；为空时沿用 `[render] gradient_bottom`。
    pub gradient_bottom: Option<Color>,
    /// 是否给外部 shell（pwsh/powershell/cmd）注入提示符集成脚本；默认开启。
    pub shell_integration: bool,
}

impl Profile {
    /// 拼成 CreateProcessW 需要的命令行。
    pub fn command_line(&self) -> String {
        let mut line = String::new();
        if self.command.contains(' ') && !self.command.starts_with('"') {
            line.push('"');
            line.push_str(&self.command);
            line.push('"');
        } else {
            line.push_str(&self.command);
        }
        for arg in &self.args {
            line.push(' ');
            if arg.contains(' ') && !arg.starts_with('"') {
                line.push('"');
                line.push_str(arg);
                line.push('"');
            } else {
                line.push_str(arg);
            }
        }
        line
    }

    /// 展开 `%VAR%`；失败回退到用户目录。
    pub fn expanded_cwd(&self) -> Option<String> {
        let raw = self.cwd.as_ref()?;
        let expanded = expand_env(raw);
        if expanded.is_empty() {
            None
        } else {
            Some(expanded)
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ColorScheme {
    pub name: String,
    pub foreground: Option<Color>,
    pub background: Option<Color>,
    /// 阶段 3：鼠标选区与光标颜色（Server Core 下光标色不可设，仅选区会用）。
    #[allow(dead_code)]
    pub cursor: Option<Color>,
    #[allow(dead_code)]
    pub selection: Option<Color>,
    /// 16 色 ANSI 调色板（`ansi_0`..`ansi_15`）。`None` 表示沿用宿主终端自带配色。
    pub ansi: Option<[Color; 16]>,
}

#[derive(Debug, Clone)]
pub struct ActionBinding {
    pub command: String,
    pub keys: String,
}

/// 设置页对配置文件的最小改动（写回时保留其余内容与注释）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigEdit {
    /// 根级键（`default_profile`、`scrollback`）。
    Root(&'static str, String),
    /// `[render]` 下的键。
    Render(&'static str, String),
    /// 删除 `[render]` 下的键（恢复自动推导）。
    RemoveRender(&'static str),
    /// `[behavior]` 下的键。
    Behavior(&'static str, String),
    /// 某个 profile 的 `color_scheme`。
    ProfileScheme(String, String),
    /// 某个 profile 下的键。
    ProfileRender(String, &'static str, String),
    /// 删除某个 profile 下的键（恢复继承全局）。
    RemoveProfileRender(String, &'static str),
}

#[derive(Debug, Clone)]
pub struct Config {
    pub default_profile: String,
    pub scrollback: usize,
    pub render: RenderConfig,
    pub behavior: BehaviorConfig,
    pub quake: QuakeConfig,
    pub profiles: Vec<Profile>,
    pub color_schemes: Vec<ColorScheme>,
    /// `[layouts]` 里的命名布局：名称 → 布局表达式。
    pub layouts: Vec<(String, String)>,
    pub action_bindings: Vec<ActionBinding>,
    /// 加载过程中发现的问题（不阻断启动）。
    pub warnings: Vec<String>,
    /// 提示信息（例如配置迁移），不算错误。
    pub notes: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            default_profile: "powershell".to_string(),
            scrollback: 10_000,
            render: RenderConfig::default(),
            behavior: BehaviorConfig::default(),
            quake: QuakeConfig::default(),
            profiles: default_profiles(),
            color_schemes: schemes::default_schemes(),
            layouts: Vec::new(),
            action_bindings: Vec::new(),
            warnings: Vec::new(),
            notes: Vec::new(),
        }
    }
}

fn default_profiles() -> Vec<Profile> {
    let comspec = std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_string());
    vec![
        Profile {
            name: "scterm".to_string(),
            // 由 normalize() 替换成本进程的真实路径。
            command: "@self".to_string(),
            args: vec!["shell".to_string()],
            cwd: Some("%USERPROFILE%".to_string()),
            color_scheme: Some("Campbell".to_string()),
            tab_color: None,
            font_face: None,
            font_size: None,
            gradient: GradientOverride::Inherit,
            gradient_top: None,
            gradient_bottom: None,
            shell_integration: true,
        },
        Profile {
            name: "cmd".to_string(),
            command: comspec,
            args: Vec::new(),
            cwd: None,
            color_scheme: Some("Campbell".to_string()),
            tab_color: None,
            font_face: None,
            font_size: None,
            gradient: GradientOverride::Inherit,
            gradient_top: None,
            gradient_bottom: None,
            shell_integration: true,
        },
        Profile {
            name: "powershell".to_string(),
            // 优先 PowerShell 7，其次 Windows PowerShell 5.1；normalize 时会再兜底。
            command: detect_powershell()
                .map(|path| path.display().to_string())
                .unwrap_or_else(|| "powershell.exe".to_string()),
            args: vec!["-NoLogo".to_string()],
            cwd: None,
            color_scheme: Some("Campbell".to_string()),
            tab_color: None,
            font_face: None,
            font_size: None,
            gradient: GradientOverride::Inherit,
            gradient_top: None,
            gradient_bottom: None,
            shell_integration: true,
        },
    ]
}

/// 探测 PowerShell 7（pwsh.exe）：先扫 PATH，再看默认安装目录。
fn find_pwsh() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join("pwsh.exe");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    if let Some(program_files) = std::env::var_os("ProgramFiles") {
        let candidate = PathBuf::from(program_files)
            .join("PowerShell")
            .join("7")
            .join("pwsh.exe");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// 当前系统可用的 PowerShell：优先 pwsh 7，否则 Windows PowerShell 5.1。
pub fn detect_powershell() -> Option<PathBuf> {
    if let Some(path) = find_pwsh() {
        return Some(path);
    }
    if let Some(root) = std::env::var_os("SystemRoot") {
        let candidate = PathBuf::from(root)
            .join("System32")
            .join("WindowsPowerShell")
            .join("v1.0")
            .join("powershell.exe");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join("powershell.exe");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// 命令是否指向 pwsh.exe（裸名或绝对路径）。
fn is_pwsh_command(command: &str) -> bool {
    command
        .trim_matches('"')
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or(command)
        .eq_ignore_ascii_case("pwsh.exe")
}

/// 命令能否解析成可执行文件（裸名扫 PATH，带路径看文件是否存在）。
fn command_exists(command: &str) -> bool {
    let trimmed = command.trim_matches('"');
    if trimmed.contains('\\') || trimmed.contains('/') {
        return PathBuf::from(trimmed).is_file();
    }
    std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).any(|dir| dir.join(trimmed).is_file()))
        .unwrap_or(false)
}

impl Config {
    pub fn path() -> PathBuf {
        if let Ok(custom) = std::env::var(CONFIG_ENV) {
            if !custom.is_empty() {
                return PathBuf::from(custom);
            }
        }
        let base = std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        base.join("scterm").join("config.toml")
    }

    /// 背景图片目录：配置同级的 `backgrounds` 文件夹。
    pub fn backgrounds_dir() -> PathBuf {
        Config::path()
            .parent()
            .map(|dir| dir.join("backgrounds"))
            .unwrap_or_else(|| PathBuf::from("backgrounds"))
    }

    /// 会话文件：与配置文件同目录（`SCTERM_CONFIG` 会一起改变位置）。
    pub fn session_path() -> PathBuf {
        Config::path()
            .parent()
            .map(|dir| dir.join("session.toml"))
            .unwrap_or_else(|| PathBuf::from("session.toml"))
    }

    /// 把 `render.background_image` 解析成实际文件路径：
    /// 绝对路径原样返回，相对路径先找 `backgrounds` 目录，找不到再按当前目录。
    pub fn resolve_background(name: &str) -> PathBuf {
        let path = PathBuf::from(name);
        if path.is_absolute() {
            return path;
        }
        let in_dir = Config::backgrounds_dir().join(name);
        if in_dir.exists() {
            return in_dir;
        }
        path
    }

    /// `backgrounds` 目录里可用的图片（按文件名排序）。
    pub fn background_files() -> Vec<String> {
        let mut names: Vec<String> = Vec::new();
        if let Ok(entries) = std::fs::read_dir(Config::backgrounds_dir()) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !path.is_file() {
                    continue;
                }
                let ext = path
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if !matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "bmp" | "gif") {
                    continue;
                }
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    names.push(name.to_string());
                }
            }
        }
        names.sort();
        names
    }

    /// 把设置页的改动写回配置文件（先写临时文件再替换，避免写坏原文件）。
    pub fn save_edits(&self, path: &PathBuf, edits: &[ConfigEdit]) -> Result<(), String> {
        let text = std::fs::read_to_string(path).unwrap_or_else(|_| DEFAULT_CONFIG.to_string());
        let updated = patch_config(&text, edits);
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = path.with_extension("toml.tmp");
        std::fs::write(&tmp, &updated)
            .map_err(|e| format!("写入 {} 失败：{e}", tmp.display()))?;
        std::fs::rename(&tmp, path).map_err(|e| format!("替换 {} 失败：{e}", path.display()))?;
        Ok(())
    }

    /// 加载配置；文件不存在时写出默认配置。
    pub fn load() -> Config {
        Config::load_from(&Config::path(), true)
    }

    pub fn load_from(path: &PathBuf, write_default: bool) -> Config {
        let mut config = Config::default();
        match std::fs::read_to_string(path) {
            Ok(text) => match toml::parse(&text) {
                Ok(doc) => config.apply_document(&doc),
                Err(e) => {
                    config.warnings.push(format!(
                        "配置文件 {} 解析失败：{e}；已回退到内置默认值",
                        path.display()
                    ));
                }
            },
            Err(_) => {
                if write_default {
                    if let Some(dir) = path.parent() {
                        let _ = std::fs::create_dir_all(dir);
                    }
                    if std::fs::write(path, DEFAULT_CONFIG).is_err() {
                        config
                            .warnings
                            .push(format!("无法写入默认配置：{}", path.display()));
                    }
                }
            }
        }
        config.normalize();
        config
    }

    fn apply_document(&mut self, doc: &toml::Document) {
        if let Some(v) = doc.root.get_str("default_profile") {
            self.default_profile = v.to_string();
        }
        if let Some(v) = doc.root.get_int("scrollback") {
            if v > 0 {
                self.scrollback = v as usize;
            }
        }

        if let Some(render) = doc.table("render") {
            if let Some(v) = render.get_bool("mouse") {
                self.render.mouse = v;
            }
            if let Some(v) = render.get_str("truecolor") {
                self.render.truecolor = match v {
                    "always" => TrueColorMode::Always,
                    "never" => TrueColorMode::Never,
                    _ => TrueColorMode::Auto,
                };
            }
            if let Some(v) = render.get_str("font_face") {
                if !v.trim().is_empty() {
                    self.render.font_face = Some(v.trim().to_string());
                }
            }
            if let Some(v) = render.get_int("font_size") {
                if v >= 6 && v <= 72 {
                    self.render.font_size = Some(v as u16);
                } else {
                    self.warnings
                        .push(format!("render.font_size={v} 超出 6–72，已忽略"));
                }
            }
            if let Some(v) = render.get_str("gradient") {
                self.render.gradient = match v.trim().to_ascii_lowercase().as_str() {
                    "off" | "none" | "false" => None,
                    "horizontal" => Some(GradientDir::Horizontal),
                    "diagonal" => Some(GradientDir::Diagonal),
                    "" | "on" | "true" | "vertical" => Some(GradientDir::Vertical),
                    other => {
                        self.warnings.push(format!(
                            "render.gradient=\"{other}\" 无法识别，已改用 vertical"
                        ));
                        Some(GradientDir::Vertical)
                    }
                };
            }
            if let Some(v) = render.get_str("gradient_top") {
                match parse_color(v) {
                    Some(color) => self.render.gradient_top = Some(color),
                    None => self
                        .warnings
                        .push(format!("render.gradient_top={v} 不是合法颜色，已忽略")),
                }
            }
            if let Some(v) = render.get_str("gradient_bottom") {
                match parse_color(v) {
                    Some(color) => self.render.gradient_bottom = Some(color),
                    None => self
                        .warnings
                        .push(format!("render.gradient_bottom={v} 不是合法颜色，已忽略")),
                }
            }
            if let Some(v) = render.get_str("background_image") {
                let v = v.trim();
                self.render.background_image = if v.is_empty() {
                    None
                } else {
                    Some(v.to_string())
                };
            }
            if let Some(v) = render.get_int("background_image_opacity") {
                if (0..=100).contains(&v) {
                    self.render.background_image_opacity = v as u8;
                } else {
                    self.warnings.push(format!(
                        "render.background_image_opacity={v} 超出 0–100，已忽略"
                    ));
                }
            }
        }

        if let Some(behavior) = doc.table("behavior") {
            if let Some(v) = behavior.get_bool("copy_on_select") {
                self.behavior.copy_on_select = v;
            }
            if let Some(v) = behavior.get_bool("confirm_close") {
                self.behavior.confirm_close = v;
            }
            if let Some(v) = behavior.get_bool("confirm_multiline_paste") {
                self.behavior.confirm_multiline_paste = v;
            }
            if let Some(v) = behavior.get_bool("restore_session") {
                self.behavior.restore_session = v;
            }
        }

        if let Some(quake) = doc.table("quake") {
            if let Some(v) = quake.get_bool("enabled") {
                self.quake.enabled = v;
            }
            if let Some(v) = quake.get_str("hotkey") {
                if !v.trim().is_empty() {
                    self.quake.hotkey = v.trim().to_string();
                }
            }
            if let Some(v) = quake.get_bool("topmost") {
                self.quake.topmost = v;
            }
        }

        if let Some(layouts) = doc.table("layouts") {
            for (name, value) in &layouts.entries {
                let spec = match value {
                    toml::Value::Str(spec) => spec,
                    _ => {
                        self.warnings
                            .push(format!("layouts 中的「{name}」不是字符串，已忽略"));
                        continue;
                    }
                };
                if name.is_empty() || spec.trim().is_empty() {
                    continue;
                }
                if self.layouts.iter().any(|(existing, _)| existing == name) {
                    self.warnings
                        .push(format!("layouts 中的布局名「{name}」重复，保留第一个"));
                    continue;
                }
                self.layouts.push((name.clone(), spec.trim().to_string()));
            }
        }

        let profiles = doc.array("profiles");
        if !profiles.is_empty() {
            self.profiles.clear();
            for p in profiles {
                let name = p.get_str("name").unwrap_or("").to_string();
                let command = p.get_str("command").unwrap_or("").to_string();
                if name.is_empty() || command.is_empty() {
                    self.warnings
                        .push("profile 缺少 name 或 command，已跳过".to_string());
                    continue;
                }
                let tab_color = match p.get_str("tab_color") {
                    Some(value) => match parse_color(value) {
                        Some(color) => Some(color),
                        None => {
                            self.warnings.push(format!(
                                "profile「{name}」的 tab_color=\"{value}\" 不是合法颜色，已忽略"
                            ));
                            None
                        }
                    },
                    None => None,
                };
                let font_face = p
                    .get_str("font_face")
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty());
                let font_size = match p.get_int("font_size") {
                    Some(v) if (6..=72).contains(&v) => Some(v as u16),
                    Some(v) => {
                        self.warnings.push(format!(
                            "profile「{name}」的 font_size={v} 超出 6–72，已忽略"
                        ));
                        None
                    }
                    None => None,
                };
                let gradient = match p.get_str("gradient") {
                    None => GradientOverride::Inherit,
                    Some(v) => match v.trim().to_ascii_lowercase().as_str() {
                        "" | "on" | "true" | "inherit" => GradientOverride::Inherit,
                        "off" | "none" | "false" => GradientOverride::Off,
                        "vertical" => GradientOverride::Dir(GradientDir::Vertical),
                        "horizontal" => GradientOverride::Dir(GradientDir::Horizontal),
                        "diagonal" => GradientOverride::Dir(GradientDir::Diagonal),
                        other => {
                            self.warnings.push(format!(
                                "profile「{name}」的 gradient=\"{other}\" 无法识别，改为继承全局"
                            ));
                            GradientOverride::Inherit
                        }
                    },
                };
                let gradient_top = match p.get_str("gradient_top") {
                    Some(v) => match parse_color(v) {
                        Some(color) => Some(color),
                        None => {
                            self.warnings.push(format!(
                                "profile「{name}」的 gradient_top=\"{v}\" 不是合法颜色，已忽略"
                            ));
                            None
                        }
                    },
                    None => None,
                };
                let gradient_bottom = match p.get_str("gradient_bottom") {
                    Some(v) => match parse_color(v) {
                        Some(color) => Some(color),
                        None => {
                            self.warnings.push(format!(
                                "profile「{name}」的 gradient_bottom=\"{v}\" 不是合法颜色，已忽略"
                            ));
                            None
                        }
                    },
                    None => None,
                };
                self.profiles.push(Profile {
                    name,
                    command,
                    args: p.get_str_array("args"),
                    cwd: p.get_str("cwd").map(|s| s.to_string()),
                    color_scheme: p.get_str("color_scheme").map(|s| s.to_string()),
                    tab_color,
                    font_face,
                    font_size,
                    gradient,
                    gradient_top,
                    gradient_bottom,
                    shell_integration: p.get_bool("shell_integration").unwrap_or(true),
                });
            }
        }

        let schemes = doc.array("color_schemes");
        if !schemes.is_empty() {
            self.color_schemes.clear();
            for s in schemes {
                let name = s.get_str("name").unwrap_or("").to_string();
                if name.is_empty() {
                    continue;
                }
                let ansi = parse_ansi_palette(s, &name, &mut self.warnings);
                self.color_schemes.push(ColorScheme {
                    name,
                    foreground: s.get_str("foreground").and_then(parse_color),
                    background: s.get_str("background").and_then(parse_color),
                    cursor: s.get_str("cursor").and_then(parse_color),
                    selection: s.get_str("selection").and_then(parse_color),
                    ansi,
                });
            }
        }

        let actions = doc.array("actions");
        for a in actions {
            let command = a.get_str("command").unwrap_or("").to_string();
            let keys = a.get_str("keys").unwrap_or("").to_string();
            if command.is_empty() {
                self.warnings
                    .push("actions 项缺少 command，已跳过".to_string());
                continue;
            }
            self.action_bindings.push(ActionBinding { command, keys });
        }
    }

    fn normalize(&mut self) {
        if self.profiles.is_empty() {
            self.profiles = default_profiles();
        }
        // 内置配色始终可用；配置里同名时以用户配置为准，只补齐旧配置缺失的 ANSI 调色板。
        for scheme in schemes::default_schemes() {
            if let Some(index) = self
                .color_schemes
                .iter()
                .position(|s| s.name == scheme.name)
            {
                if self.color_schemes[index].ansi.is_none() {
                    self.color_schemes[index].ansi = scheme.ansi;
                }
            } else {
                self.color_schemes.push(scheme);
            }
        }
        // 迁移：旧版默认配置只有 cmd / pwsh。补上自研 shell（仍可在设置里切过去），
        // 并把仍指向 cmd 的旧默认切到新的出厂默认（powershell）。
        if !self.profiles.iter().any(|p| p.name == "scterm") {
            self.profiles.push(Profile {
                name: "scterm".to_string(),
                command: "@self".to_string(),
                args: vec!["shell".to_string()],
                cwd: Some("%USERPROFILE%".to_string()),
                color_scheme: Some("Campbell".to_string()),
                tab_color: None,
                font_face: None,
                font_size: None,
                gradient: GradientOverride::Inherit,
                gradient_top: None,
                gradient_bottom: None,
                shell_integration: true,
            });
            if self.default_profile.eq_ignore_ascii_case("cmd") {
                self.default_profile = "powershell".to_string();
                self.notes.push(
                    "已把默认 profile 迁移为 powershell；如需自研 shell，请修改 default_profile"
                        .to_string(),
                );
            }
        }
        // `@self` 表示「本可执行文件」：自研 shell 用它把窗格启动为 `scterm shell`。
        let self_exe = std::env::current_exe()
            .ok()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|| "scterm.exe".to_string());
        for profile in &mut self.profiles {
            if profile.command == "@self" {
                profile.command = self_exe.clone();
            }
        }
        // PowerShell：旧配置里的 pwsh profile 在 pwsh.exe 不存在时回退到
        // Windows PowerShell 5.1，否则用户切过去只会得到一个启动失败的窗格。
        let powershell = detect_powershell();
        let mut ps_notes = Vec::new();
        if let Some(path) = &powershell {
            let display = path.display().to_string();
            for profile in &mut self.profiles {
                if is_pwsh_command(&profile.command) && !command_exists(&profile.command) {
                    profile.command = display.clone();
                    ps_notes.push(format!(
                        "未找到 pwsh.exe，profile「{}」已回退到 {}",
                        profile.name, display
                    ));
                }
            }
        }
        // 既没有 powershell 也没有 pwsh 时补一个，保证设置面板里始终能切到 PowerShell。
        let has_powershell = self.profiles.iter().any(|profile| {
            profile.name.eq_ignore_ascii_case("powershell")
                || profile.name.eq_ignore_ascii_case("pwsh")
        });
        if !has_powershell {
            if let Some(path) = &powershell {
                self.profiles.push(Profile {
                    name: "powershell".to_string(),
                    command: path.display().to_string(),
                    args: vec!["-NoLogo".to_string()],
                    cwd: None,
                    color_scheme: Some("Campbell".to_string()),
                    tab_color: None,
                    font_face: None,
                    font_size: None,
                    gradient: GradientOverride::Inherit,
                    gradient_top: None,
                    gradient_bottom: None,
                    shell_integration: true,
                });
                ps_notes.push(format!(
                    "已自动添加 PowerShell profile（{}）",
                    path.display()
                ));
            }
        }
        self.notes.extend(ps_notes);
        if !self.profiles.iter().any(|p| p.name == self.default_profile) {
            let first = self.profiles[0].name.clone();
            self.warnings.push(format!(
                "default_profile「{}」不存在，已改用「{first}」",
                self.default_profile
            ));
            self.default_profile = first;
        }
        for profile in &self.profiles {
            if let Some(scheme) = &profile.color_scheme {
                if !self.color_schemes.iter().any(|s| &s.name == scheme) {
                    self.warnings.push(format!(
                        "profile「{}」引用了不存在的配色「{scheme}」，已回退 Campbell",
                        profile.name
                    ));
                }
            }
        }
    }

    pub fn profile(&self, name: &str) -> Option<&Profile> {
        self.profiles.iter().find(|p| p.name == name)
    }

    pub fn default_profile_ref(&self) -> &Profile {
        self.profile(&self.default_profile)
            .unwrap_or_else(|| &self.profiles[0])
    }

    pub fn scheme(&self, name: &str) -> Option<&ColorScheme> {
        self.color_schemes.iter().find(|s| s.name == name)
    }

    pub fn scheme_for_profile(&self, profile: &Profile) -> ColorScheme {
        profile
            .color_scheme
            .as_ref()
            .and_then(|name| self.scheme(name))
            .or_else(|| self.scheme("Campbell"))
            .cloned()
            .unwrap_or_default()
    }
}

/// 解析 `ansi_0`..`ansi_15`。一个都没写时返回 `None`（沿用宿主终端的 ANSI 配色）；
/// 写了任意一项时，缺失或非法的项回退到 Campbell 的对应颜色。
fn parse_ansi_palette(
    table: &toml::Table,
    name: &str,
    warnings: &mut Vec<String>,
) -> Option<[Color; 16]> {
    let mut slots: [Option<Color>; 16] = [None; 16];
    let mut any = false;
    for (index, slot) in slots.iter_mut().enumerate() {
        let key = format!("ansi_{index}");
        let Some(text) = table.get_str(&key) else {
            continue;
        };
        match parse_color(text) {
            Some(color) => {
                *slot = Some(color);
                any = true;
            }
            None => warnings.push(format!(
                "配色「{name}」的 {key}=\"{text}\" 不是合法颜色，已回退 Campbell 对应色"
            )),
        }
    }
    if !any {
        return None;
    }
    let fallback = schemes::fallback_ansi();
    Some(std::array::from_fn(|i| slots[i].unwrap_or(fallback[i])))
}

pub fn parse_color(text: &str) -> Option<Color> {
    let hex = text.trim().trim_start_matches('#');
    if hex.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
    let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
    let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
    Some(Color::Rgb(r, g, b))
}

fn expand_env(input: &str) -> String {
    let mut out = String::new();
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '%' {
            if let Some(end) = chars[i + 1..].iter().position(|&c| c == '%') {
                let name: String = chars[i + 1..i + 1 + end].iter().collect();
                if let Ok(value) = std::env::var(&name) {
                    out.push_str(&value);
                    i = i + end + 2;
                    continue;
                }
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

pub const DEFAULT_CONFIG: &str = r##"# scterm 配置文件
# 修改后会自动重载（客户端每秒检查一次文件时间）

default_profile = "powershell"
scrollback = 10000

[render]
# 鼠标上报；系统 build 低于 18362 时会自动关闭
mouse = true
# auto | always | never
truecolor = "auto"
# 控制台字体（可选）。字体必须已安装在系统里，Server Core 下可用字体较少；
# 不写则沿用 conhost 当前字体。
# font_face = "Consolas"
# font_size = 16
# 背景渐变：off | vertical | horizontal | diagonal
# 控制台只能按单元格着色，所以是「逐行/逐列」的平滑渐变。
gradient = "vertical"
# 自定义渐变两端颜色；不写则按配色方案的 background 自动推导（顶部微亮、底部更深）
# gradient_top = "#2b3440"
# gradient_bottom = "#05070a"
# 背景图片：cover 等比铺满、居中裁切，再按不透明度叠在渐变上。
# 相对路径先在配置同级的 backgrounds 文件夹里找，也可以写完整路径。
# background_image = "sea.jpg"
# background_image_opacity = 35

[behavior]
# 选中文本松开鼠标后自动复制到剪贴板
copy_on_select = false
# 关闭标签页前确认（Ctrl+Shift+W、中键、点 × 都会问一次）
confirm_close = true
# 粘贴内容含换行时确认（避免误把多行命令直接回车执行）
confirm_multiline_paste = true
# 正常退出时保存标签页与窗格布局，下次启动恢复
restore_session = true

# 命名布局：scterm --layout <名称>
# h = 左右分，v = 上下分；数字是第一个子节点的百分比（省略为 50）
[layouts]
# dev = "h(powershell,v(cmd,powershell))"
# even = "v50(powershell,cmd)"

# Quake 下拉热键：隐藏/显示当前控制台窗口
[quake]
# 是否注册全局呼出热键（不影响正常启动）
enabled = false
# 修饰键 win/ctrl/alt/shift + 键名；默认 Win+反引号
hotkey = "win+`"
# 呼出时把窗口置顶
topmost = true

# 自研 shell：command = "@self" 表示 scterm 自身，args 为子命令
[[profiles]]
name = "scterm"
command = "@self"
args = ["shell"]
cwd = "%USERPROFILE%"
color_scheme = "Campbell"

[[profiles]]
name = "cmd"
command = "cmd.exe"
cwd = "%USERPROFILE%"
color_scheme = "Campbell"
# 标签栏配色（可选），例如 "#3B78FF"；不写则用默认灰色标签
# tab_color = "#3B78FF"
# 外部 shell 集成：启动时注入提示符脚本（OSC 7 当前目录 / OSC 133 提示符标记）
# shell_integration = true

# PowerShell：默认用 Windows PowerShell 5.1；装了 PowerShell 7 可改成 pwsh.exe
# 设置面板的「默认 profile」可直接切换（也可切回自研 shell / cmd）
[[profiles]]
name = "powershell"
command = "powershell.exe"
args = ["-NoLogo"]
cwd = "%USERPROFILE%"
color_scheme = "Campbell"
# 每个 profile 可单独覆盖外观；不写的键沿用上面 [render] 的全局值。
# font_face = "Cascadia Mono"
# font_size = 18
# gradient = "horizontal"
# gradient_top = "#1B2A45"
# gradient_bottom = "#05070D"
# tab_color = "#3B78FF"
# 外部 shell 集成：启动时注入提示符脚本（OSC 7 当前目录 / OSC 133 提示符标记）
# shell_integration = true

# 16 色 ANSI 调色板：ansi_0..ansi_15，顺序为 黑/红/绿/黄/蓝/紫/青/白，
# 再重复一遍亮色 8 项。写全后 ls / git 等命令的 16 色输出会跟随主题变化；
# 只写一部分时，未写的项回退到 Campbell 的对应颜色；一项都不写则沿用宿主终端配色。
[[color_schemes]]
name = "Campbell"
foreground = "#CCCCCC"
background = "#0C0C0C"
cursor = "#FFFFFF"
selection = "#264F78"
ansi_0 = "#0C0C0C"
ansi_1 = "#C50F1F"
ansi_2 = "#13A10E"
ansi_3 = "#C19C00"
ansi_4 = "#0037DA"
ansi_5 = "#881798"
ansi_6 = "#3A96DD"
ansi_7 = "#CCCCCC"
ansi_8 = "#767676"
ansi_9 = "#E74856"
ansi_10 = "#16C60C"
ansi_11 = "#F9F1A5"
ansi_12 = "#3B78FF"
ansi_13 = "#B4009E"
ansi_14 = "#61D6D6"
ansi_15 = "#F2F2F2"

# 内置另有 60+ 套配色（Windows Terminal 官方与常用社区主题），无需写进配置：
# 在设置面板里切换，或把 profile 的 color_scheme 直接改成方案名。
# 运行 `scterm reload` 可列出全部方案名。

# 自定义快捷键：command 取值见 `scterm actions`
# keys 留空表示只出现在命令面板中
[[actions]]
command = "splitPaneHorizontal"
keys = "alt+shift+-"

[[actions]]
command = "splitPaneVertical"
keys = "alt+shift+plus"
"##;

/// 配置文件的段落。
#[derive(Debug, Clone, PartialEq, Eq)]
enum Section {
    Root,
    Render,
    Behavior,
    Profile(String),
    Other,
}

/// 按最小改动把设置页的值写回配置文本：已有键原位替换，缺失的键插到所属段落末尾，
/// 其余行（包括注释、自定义 profile、配色方案）原样保留。
fn patch_config(text: &str, edits: &[ConfigEdit]) -> String {
    let mut lines: Vec<String> = text
        .split('\n')
        .map(|line| line.trim_end_matches('\r').to_string())
        .collect();

    // 1) 逐行标注所属段落
    let mut sections: Vec<Section> = Vec::with_capacity(lines.len());
    let mut current = Section::Root;
    let mut profile_name = String::new();
    for line in &lines {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("[[") {
            current = if rest.starts_with("profiles") {
                Section::Profile(String::new())
            } else {
                Section::Other
            };
            profile_name.clear();
        } else if let Some(rest) = trimmed.strip_prefix('[') {
            current = if rest.starts_with("render") {
                Section::Render
            } else if rest.starts_with("behavior") {
                Section::Behavior
            } else {
                Section::Other
            };
        } else if matches!(current, Section::Profile(_)) && profile_name.is_empty() {
            if let Some(name) = quoted_value(trimmed, "name") {
                profile_name = name;
            }
        }
        sections.push(match &current {
            Section::Profile(_) => Section::Profile(profile_name.clone()),
            other => other.clone(),
        });
    }

    // 2) 已有键原位替换/删除，缺失的键记下插入位置
    let mut removed = vec![false; lines.len()];
    let mut inserts: Vec<(usize, String)> = Vec::new();
    let mut added_sections: Vec<&'static str> = Vec::new();
    for edit in edits {
        let (key, value, target) = match edit {
            ConfigEdit::Root(k, v) => (*k, Some(v.clone()), Section::Root),
            ConfigEdit::Render(k, v) => (*k, Some(v.clone()), Section::Render),
            ConfigEdit::RemoveRender(k) => (*k, None, Section::Render),
            ConfigEdit::Behavior(k, v) => (*k, Some(v.clone()), Section::Behavior),
            ConfigEdit::ProfileScheme(name, v) => (
                "color_scheme",
                Some(format!("\"{v}\"")),
                Section::Profile(name.clone()),
            ),
            ConfigEdit::ProfileRender(name, k, v) => (
                *k,
                Some(v.clone()),
                Section::Profile(name.clone()),
            ),
            ConfigEdit::RemoveProfileRender(name, k) => {
                (*k, None, Section::Profile(name.clone()))
            }
        };
        let found = lines.iter().enumerate().position(|(i, line)| {
            sections.get(i) == Some(&target) && !removed[i] && key_matches(line, key)
        });
        match (found, value) {
            (Some(i), Some(v)) => lines[i] = format!("{key} = {v}"),
            (Some(i), None) => removed[i] = true,
            (None, Some(v)) => match section_end(&lines, &sections, &target) {
                Some(position) => inserts.push((position, format!("{key} = {v}"))),
                None => {
                    // 段落不存在（例如旧配置没有 [behavior]）：在文件末尾补段落头。
                    let header = match target {
                        Section::Behavior => "[behavior]",
                        Section::Render => "[render]",
                        _ => continue,
                    };
                    if !added_sections.contains(&header) {
                        added_sections.push(header);
                        inserts.push((lines.len(), String::new()));
                        inserts.push((lines.len(), header.to_string()));
                    }
                    inserts.push((lines.len(), format!("{key} = {v}")));
                }
            },
            (None, None) => {}
        }
    }

    // 3) 合并插入
    inserts.sort_by_key(|(position, _)| *position);
    let mut out: Vec<String> = Vec::with_capacity(lines.len() + inserts.len());
    let mut pending = inserts.into_iter().peekable();
    for (i, line) in lines.iter().enumerate() {
        while let Some((position, text)) = pending.peek() {
            if *position <= i {
                out.push(text.clone());
                pending.next();
            } else {
                break;
            }
        }
        if !removed[i] {
            out.push(line.clone());
        }
    }
    while let Some((_, text)) = pending.next() {
        out.push(text);
    }
    out.join("\n")
}

/// 该段落最后一个非空行的下一行；段落不存在时返回 `None`（不硬塞进别的段落）。
fn section_end(lines: &[String], sections: &[Section], target: &Section) -> Option<usize> {
    let last = lines
        .iter()
        .enumerate()
        .filter(|(i, line)| sections.get(*i) == Some(target) && !line.trim().is_empty())
        .map(|(i, _)| i + 1)
        .last();
    if last.is_some() {
        return last;
    }
    if *target == Section::Root {
        // 根级键必须写在任何表格之前
        return Some(
            lines
                .iter()
                .position(|line| line.trim_start().starts_with('['))
                .unwrap_or(lines.len()),
        );
    }
    None
}

fn key_matches(line: &str, key: &str) -> bool {
    let trimmed = line.trim_start();
    if trimmed.starts_with('#') {
        return false;
    }
    match trimmed.strip_prefix(key) {
        Some(rest) => rest.trim_start().starts_with('='),
        None => false,
    }
}

fn quoted_value(line: &str, key: &str) -> Option<String> {
    let trimmed = line.trim_start();
    if trimmed.starts_with('#') {
        return None;
    }
    let rest = trimmed.strip_prefix(key)?.trim_start().strip_prefix('=')?.trim();
    let rest = rest.strip_prefix('"').or_else(|| rest.strip_prefix('\''))?;
    let end = rest.find(['"', '\''])?;
    Some(rest[..end].to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_config_document() {
        let doc = toml::parse(DEFAULT_CONFIG).unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        config.normalize();
        assert_eq!(config.default_profile, "powershell");
        assert_eq!(config.scrollback, 10000);
        assert_eq!(config.profiles.len(), 3);
        assert_eq!(config.profiles[0].name, "scterm");
        assert_eq!(config.profiles[0].args, vec!["shell".to_string()]);
        assert_eq!(config.profiles[2].name, "powershell");
        assert_eq!(config.profiles[2].command, "powershell.exe");
        assert_eq!(config.profiles[2].args, vec!["-NoLogo".to_string()]);
        let scheme = config.scheme("Campbell").unwrap();
        assert_eq!(scheme.foreground, Some(Color::Rgb(0xcc, 0xcc, 0xcc)));
        assert_eq!(scheme.background, Some(Color::Rgb(0x0c, 0x0c, 0x0c)));
        assert!(config.behavior.restore_session);
        assert!(!config.quake.enabled);
        assert_eq!(config.quake.hotkey, "win+`");
        assert!(config.quake.topmost);
        assert!(config.layouts.is_empty());
    }

    #[test]
    fn parses_layouts_and_quake() {
        let doc = toml::parse(
            r#"
[behavior]
restore_session = false

[layouts]
dev = "h(pwsh,cmd)"
bad = 42
empty = ""

[quake]
enabled = true
hotkey = "ctrl+alt+space"
topmost = false
"#,
        )
        .unwrap();
        let mut config = Config::default();
        // 应用两次以模拟重复的布局名（同一 TOML 表内不允许重复键）。
        config.apply_document(&doc);
        config.apply_document(&doc);
        assert!(!config.behavior.restore_session);
        assert_eq!(
            config.layouts,
            vec![("dev".to_string(), "h(pwsh,cmd)".to_string())]
        );
        assert!(
            config
                .warnings
                .iter()
                .any(|w| w.contains("dev") && w.contains("重复")),
            "重复布局名应告警：{:?}",
            config.warnings
        );
        assert!(
            config
                .warnings
                .iter()
                .any(|w| w.contains("bad") && w.contains("不是字符串")),
            "非字符串布局应告警：{:?}",
            config.warnings
        );
        assert!(config.quake.enabled);
        assert_eq!(config.quake.hotkey, "ctrl+alt+space");
        assert!(!config.quake.topmost);
    }

    #[test]
    fn session_path_follows_config_path() {
        let path = Config::session_path();
        assert_eq!(path.file_name().unwrap().to_string_lossy(), "session.toml");
        assert_eq!(path.parent(), Config::path().parent());
    }

    #[test]
    fn old_config_migrates_to_powershell() {
        let doc = toml::parse(
            r#"
default_profile = "cmd"

[[profiles]]
name = "cmd"
command = "cmd.exe"
"#,
        )
        .unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        config.normalize();
        assert_eq!(config.default_profile, "powershell");
        assert!(config.profile("scterm").is_some(), "自研 shell 仍应保留");
        assert!(config.profile("powershell").is_some(), "应补上 PowerShell profile");
        assert!(config.notes.iter().any(|w| w.contains("迁移")));
    }

    #[test]
    fn self_command_is_expanded() {
        let doc = toml::parse(DEFAULT_CONFIG).unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        config.normalize();
        let scterm = config.profile("scterm").unwrap();
        assert_ne!(scterm.command, "@self");
        assert!(scterm.command_line().ends_with(" shell"));
    }

    #[test]
    fn parses_font_options_and_themes() {
        let doc = toml::parse(DEFAULT_CONFIG).unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        // 默认配置只保留 Campbell 作为 ansi_* 写法的模板，其余内置配色由代码提供
        assert_eq!(config.color_schemes.len(), 1);
        let campbell = config.scheme("Campbell").unwrap();
        assert!(campbell.ansi.is_some(), "默认配置应示范 ansi_0..ansi_15");
        config.normalize();
        assert!(config.scheme("Dracula").is_some());
        assert!(config.scheme("Solarized Dark").is_some());
        assert!(config.scheme("Catppuccin Mocha").is_some());
        assert!(config.scheme("Kanagawa Wave").is_some());
        assert!(config.color_schemes.len() >= 60, "内置配色应足够多");
        // 默认配置里字体是注释掉的，不应生效
        assert!(config.render.font_face.is_none());
        assert!(config.render.font_size.is_none());
    }

    #[test]
    fn builtin_schemes_have_full_ansi_palettes() {
        let config = Config::default();
        assert!(config.color_schemes.len() >= 60);
        assert_eq!(config.color_schemes[0].name, "Campbell");
        let mut names: Vec<&str> = config
            .color_schemes
            .iter()
            .map(|s| s.name.as_str())
            .collect();
        names.sort_unstable();
        assert!(
            names.windows(2).all(|w| w[0] != w[1]),
            "内置配色名不能重复"
        );
        for scheme in &config.color_schemes {
            assert!(scheme.ansi.is_some(), "{} 缺少 ANSI 调色板", scheme.name);
            assert!(scheme.foreground.is_some(), "{} 缺少前景色", scheme.name);
            assert!(scheme.background.is_some(), "{} 缺少背景色", scheme.name);
        }
    }

    #[test]
    fn parses_ansi_palette_and_falls_back_to_campbell() {
        let doc = toml::parse(
            r##"
[[color_schemes]]
name = "Mine"
foreground = "#112233"
ansi_0 = "#000000"
ansi_1 = "#FF0000"
ansi_2 = "oops"
ansi_15 = "#FFFFFF"

[[color_schemes]]
name = "Plain"
foreground = "#445566"
"##,
        )
        .unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        let mine = config.scheme("Mine").unwrap();
        let ansi = mine.ansi.expect("写了部分 ansi_* 就应生成调色板");
        assert_eq!(ansi[0], Color::Rgb(0, 0, 0));
        assert_eq!(ansi[1], Color::Rgb(255, 0, 0));
        assert_eq!(ansi[15], Color::Rgb(255, 255, 255));
        // 非法项回退到 Campbell 的绿色（索引 2）
        assert_eq!(ansi[2], Color::Rgb(0x13, 0xA1, 0x0E));
        assert!(
            config.warnings.iter().any(|w| w.contains("ansi_2")),
            "非法 ansi_2 应产生警告：{:?}",
            config.warnings
        );
        // 一项都没写：沿用宿主终端配色
        assert!(config.scheme("Plain").unwrap().ansi.is_none());
    }

    #[test]
    fn normalize_fills_missing_ansi_for_known_schemes() {
        let doc = toml::parse(
            r##"
[[color_schemes]]
name = "Dracula"
foreground = "#010203"
"##,
        )
        .unwrap();
        let mut config = Config::default();
        config.color_schemes.clear(); // 模拟旧版配置：只有用户写的 4 色方案块
        config.apply_document(&doc);
        config.normalize();
        let dracula = config.scheme("Dracula").unwrap();
        assert_eq!(dracula.foreground, Some(Color::Rgb(1, 2, 3)));
        let ansi = dracula.ansi.expect("同名内置方案应补齐 ANSI 调色板");
        assert_eq!(ansi[1], Color::Rgb(0xFF, 0x55, 0x55));
        assert_eq!(ansi[2], Color::Rgb(0x50, 0xFA, 0x7B));
    }

    #[test]
    fn builtin_schemes_are_always_available() {
        let doc = toml::parse(
            r##"
[[color_schemes]]
name = "Mine"
foreground = "#112233"
"##,
        )
        .unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        config.normalize();
        assert!(config.scheme("Mine").is_some());
        assert!(config.scheme("Dracula").is_some(), "内置配色应始终可用");
        assert!(config.scheme("Campbell").is_some());
    }

    #[test]
    fn parses_gradient_options() {
        let doc = toml::parse(
            r##"
[render]
gradient = "diagonal"
gradient_top = "#112233"
gradient_bottom = "#445566"
"##,
        )
        .unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        assert_eq!(config.render.gradient, Some(GradientDir::Diagonal));
        assert_eq!(config.render.gradient_top, Some(Color::Rgb(0x11, 0x22, 0x33)));
        assert_eq!(config.render.gradient_bottom, Some(Color::Rgb(0x44, 0x55, 0x66)));

        // 关闭渐变
        let doc = toml::parse("[render]\ngradient = \"off\"\n").unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        assert_eq!(config.render.gradient, None);

        // 未配置时默认竖直渐变
        assert_eq!(
            Config::default().render.gradient,
            Some(GradientDir::Vertical)
        );
    }

    #[test]
    fn patch_config_replaces_inserts_and_removes() {
        let text = "# 顶部注释
scrollback = 1000

[render]
mouse = true
truecolor = \"auto\"

[[profiles]]
name = \"a\"
command = \"cmd.exe\"
color_scheme = \"Campbell\"

[[profiles]]
name = \"b\"
command = \"pwsh.exe\"
";
        let out = patch_config(
            text,
            &[
                ConfigEdit::Root("scrollback", "5000".into()),
                ConfigEdit::Render("gradient", "\"vertical\"".into()),
                ConfigEdit::Render("truecolor", "\"never\"".into()),
                ConfigEdit::RemoveRender("mouse"),
                ConfigEdit::ProfileScheme("b".into(), "Dracula".into()),
            ],
        );
        assert!(out.contains("# 顶部注释"), "注释应保留");
        assert!(out.contains("scrollback = 5000"));
        assert!(out.contains("truecolor = \"never\""));
        assert!(!out.contains("mouse = true"));
        // 新键必须落在 [render] 段内，而不是跑到 profiles 下面
        let render = out.find("[render]").unwrap();
        let gradient = out.find("gradient = ").unwrap();
        let profiles = out.find("[[profiles]]").unwrap();
        assert!(render < gradient && gradient < profiles, "{out}");
        // 只改 b 的配色
        let split = out.rfind("name = \"b\"").unwrap();
        assert!(out[..split].contains("color_scheme = \"Campbell\""));
        assert!(out[split..].contains("color_scheme = \"Dracula\""));

        // 写回去的文本仍能被解析，并反映改动
        let doc = toml::parse(&out).unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        assert_eq!(config.scrollback, 5000);
        assert_eq!(config.render.truecolor, TrueColorMode::Never);
        assert!(config.render.mouse, "删掉 mouse 后应回到默认 true");
        assert_eq!(config.render.gradient, Some(GradientDir::Vertical));
    }

    #[test]
    fn patch_config_adds_missing_behavior_section() {
        // 旧配置没有 [behavior]：写回时应自动补上段落
        let old = "default_profile = \"scterm\"\n\n[render]\nmouse = true\n";
        let out = patch_config(
            old,
            &[ConfigEdit::Behavior("copy_on_select", "true".into())],
        );
        assert!(out.contains("[behavior]"), "{out}");
        let doc = toml::parse(&out).unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        assert!(config.behavior.copy_on_select, "{out}");
        assert!(config.render.mouse);
    }

    #[test]
    fn patch_config_inserts_root_key_before_tables() {
        let out = patch_config(
            "[render]\nmouse = false\n",
            &[ConfigEdit::Root("scrollback", "2000".into())],
        );
        assert!(out.starts_with("scrollback = 2000\n[render]"), "{out}");
    }

    #[test]
    fn save_edits_roundtrip_to_disk() {
        let dir = std::env::temp_dir().join("scterm_cfg_test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("config.toml");
        let _ = std::fs::write(&path, DEFAULT_CONFIG);
        let config = Config::default();
        config
            .save_edits(&path, &[ConfigEdit::Root("scrollback", "25000".into())])
            .unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("scrollback = 25000"));
        assert!(text.contains("[[color_schemes]]"), "其余内容应保留");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn parses_hex_color() {
        assert_eq!(
            parse_color("#0C0C0C"),
            Some(Color::Rgb(0x0c, 0x0c, 0x0c))
        );
        assert_eq!(parse_color("zzz"), None);
    }

    #[test]
    fn unknown_profile_falls_back() {
        let doc = toml::parse(
            r#"
default_profile = "nope"
[[profiles]]
name = "only"
command = "cmd.exe"
"#,
        )
        .unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        config.normalize();
        assert_eq!(config.default_profile, "only");
        assert!(!config.warnings.is_empty());
    }

    #[test]
    fn parses_profile_tab_color_and_warns_on_invalid() {
        let doc = toml::parse(
            r##"
[[profiles]]
name = "blue"
command = "cmd.exe"
tab_color = "#204080"

[[profiles]]
name = "bad"
command = "cmd.exe"
tab_color = "not-a-color"
"##,
        )
        .unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        let blue = config.profile("blue").unwrap();
        assert_eq!(blue.tab_color, Some(Color::Rgb(0x20, 0x40, 0x80)));
        assert_eq!(config.profile("bad").unwrap().tab_color, None);
        assert!(config.warnings.iter().any(|w| w.contains("tab_color")));
    }

    #[test]
    fn parses_profile_render_overrides() {
        let doc = toml::parse(
            r##"
[[profiles]]
name = "a"
command = "cmd.exe"
font_face = "Cascadia Mono"
font_size = 18
gradient = "off"
gradient_top = "#1B2A45"
gradient_bottom = "#05070D"
tab_color = "#3B78FF"

[[profiles]]
name = "b"
command = "pwsh.exe"
"##,
        )
        .unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        let a = config.profile("a").unwrap();
        assert_eq!(a.font_face.as_deref(), Some("Cascadia Mono"));
        assert_eq!(a.font_size, Some(18));
        assert_eq!(a.gradient, GradientOverride::Off);
        assert_eq!(a.gradient_top, Some(Color::Rgb(0x1B, 0x2A, 0x45)));
        assert_eq!(a.gradient_bottom, Some(Color::Rgb(0x05, 0x07, 0x0D)));
        assert_eq!(a.tab_color, Some(Color::Rgb(0x3B, 0x78, 0xFF)));
        let b = config.profile("b").unwrap();
        assert!(b.font_face.is_none());
        assert_eq!(b.font_size, None);
        assert_eq!(b.gradient, GradientOverride::Inherit, "未写的键应继承全局");
        assert_eq!(b.gradient_top, None);
    }

    #[test]
    fn profile_render_override_warnings() {
        let doc = toml::parse(
            r##"
[[profiles]]
name = "bad"
command = "cmd.exe"
font_size = 100
gradient = "weird"
gradient_top = "red"
"##,
        )
        .unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        let bad = config.profile("bad").unwrap();
        assert_eq!(bad.font_size, None);
        assert_eq!(bad.gradient, GradientOverride::Inherit);
        assert_eq!(bad.gradient_top, None);
        assert!(config.warnings.iter().any(|w| w.contains("font_size=100")));
        assert!(config.warnings.iter().any(|w| w.contains("gradient=\"weird\"")));
        assert!(config.warnings.iter().any(|w| w.contains("gradient_top")));
    }

    #[test]
    fn profile_render_overrides_roundtrip() {
        let dir = std::env::temp_dir().join("scterm_profile_override_test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("config.toml");
        let original = r##"# 保留注释

[[profiles]]
name = "a"
command = "cmd.exe"
tab_color = "#204080"

[[profiles]]
name = "b"
command = "pwsh.exe"
tab_color = "#C50F1F"

[[color_schemes]]
name = "Campbell"
background = "#0C0C0C"
"##;
        let _ = std::fs::write(&path, original);
        Config::default()
            .save_edits(
                &path,
                &[
                    ConfigEdit::ProfileRender("a".into(), "font_face", "\"Consolas\"".into()),
                    ConfigEdit::ProfileRender("a".into(), "font_size", "18".into()),
                    ConfigEdit::ProfileRender("a".into(), "gradient", "\"off\"".into()),
                    ConfigEdit::RemoveProfileRender("b".into(), "tab_color"),
                ],
            )
            .unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("# 保留注释"), "{text}");
        assert!(text.contains("[[color_schemes]]"), "{text}");
        let doc = toml::parse(&text).unwrap();
        let mut config = Config::default();
        config.apply_document(&doc);
        let a = config.profile("a").unwrap();
        assert_eq!(a.font_face.as_deref(), Some("Consolas"));
        assert_eq!(a.font_size, Some(18));
        assert_eq!(a.gradient, GradientOverride::Off);
        assert_eq!(a.tab_color, Some(Color::Rgb(0x20, 0x40, 0x80)));
        assert_eq!(config.profile("b").unwrap().tab_color, None);
        let _ = std::fs::remove_file(&path);
    }

    fn test_profile(name: &str, command: &str) -> Profile {
        Profile {
            name: name.to_string(),
            command: command.to_string(),
            args: vec!["-NoLogo".to_string()],
            cwd: None,
            color_scheme: None,
            tab_color: None,
            font_face: None,
            font_size: None,
            gradient: GradientOverride::Inherit,
            gradient_top: None,
            gradient_bottom: None,
            shell_integration: true,
        }
    }

    #[test]
    fn normalize_adds_powershell_profile_when_missing() {
        let Some(path) = detect_powershell() else {
            return;
        };
        let mut config = Config::default();
        config.profiles = vec![test_profile("cmd", "cmd.exe")];
        config.default_profile = "cmd".to_string();
        config.normalize();

        let powershell = config.profile("powershell").expect("应补上 powershell profile");
        assert_eq!(powershell.command, path.display().to_string());
        assert_eq!(powershell.args, vec!["-NoLogo".to_string()]);
        assert!(config.profile("scterm").is_some(), "旧配置仍应补自研 shell");
        assert_eq!(config.default_profile, "powershell", "旧默认应迁到新的出厂默认");
    }

    #[test]
    fn missing_pwsh_falls_back_to_windows_powershell() {
        if find_pwsh().is_some() {
            return;
        }
        let Some(expected) = detect_powershell() else {
            return;
        };
        let mut config = Config::default();
        config.profiles = vec![test_profile("pwsh", "pwsh.exe")];
        config.default_profile = "pwsh".to_string();
        config.normalize();

        let profile = config.profile("pwsh").expect("原有 profile 名保持不变");
        assert_eq!(profile.command, expected.display().to_string());
        assert!(
            config.notes.iter().any(|note| note.contains("回退")),
            "应提示已回退：{:?}",
            config.notes
        );
        assert!(
            config.profile("powershell").is_none(),
            "已有 pwsh 时不应再补一个 powershell"
        );
    }

    #[test]
    fn existing_pwsh_command_is_kept_when_resolvable() {
        let Some(path) = detect_powershell() else {
            return;
        };
        let mut config = Config::default();
        config.profiles = vec![test_profile("pwsh", &path.display().to_string())];
        config.normalize();
        assert_eq!(
            config.profile("pwsh").unwrap().command,
            path.display().to_string(),
            "可执行的 PowerShell 命令不应被改写"
        );
    }

    #[test]
    fn command_line_quotes_spaces() {
        let p = Profile {
            name: "x".into(),
            command: "C:\\Program Files\\PowerShell\\pwsh.exe".into(),
            args: vec!["-NoLogo".into()],
            cwd: None,
            color_scheme: None,
            tab_color: None,
            font_face: None,
            font_size: None,
            gradient: GradientOverride::Inherit,
            gradient_top: None,
            gradient_bottom: None,
            shell_integration: true,
        };
        assert_eq!(
            p.command_line(),
            "\"C:\\Program Files\\PowerShell\\pwsh.exe\" -NoLogo"
        );
    }
}

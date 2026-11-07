//! 设置面板（TUI）：可调项、取值循环，以及打开时的配置快照。
//!
//! 渲染与按键处理在 `App` 里；这里只放数据模型，方便单测。

use crate::config::{Config, GradientOverride, Profile, TrueColorMode};
use crate::emulation::screen::Color;
use crate::render::GradientDir;

/// 设置面板里的一行。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Row {
    Scheme,
    DefaultProfile,
    Gradient,
    GradientPalette,
    TrueColor,
    FontFace,
    FontSize,
    ProfileFont,
    ProfileFontSize,
    ProfileGradient,
    ProfileGradientPalette,
    ProfileTabColor,
    Scrollback,
    Mouse,
    CopyOnSelect,
    ConfirmClose,
    ConfirmPaste,
    BackgroundImage,
    BackgroundOpacity,
}

pub const ROWS: [Row; 19] = [
    Row::Scheme,
    Row::DefaultProfile,
    Row::Gradient,
    Row::GradientPalette,
    Row::TrueColor,
    Row::FontFace,
    Row::FontSize,
    Row::ProfileFont,
    Row::ProfileFontSize,
    Row::ProfileGradient,
    Row::ProfileGradientPalette,
    Row::ProfileTabColor,
    Row::Scrollback,
    Row::Mouse,
    Row::CopyOnSelect,
    Row::ConfirmClose,
    Row::ConfirmPaste,
    Row::BackgroundImage,
    Row::BackgroundOpacity,
];

impl Row {
    pub fn label(self) -> &'static str {
        match self {
            Row::Scheme => "配色方案",
            Row::DefaultProfile => "默认 profile",
            Row::Gradient => "背景渐变",
            Row::GradientPalette => "渐变配色",
            Row::TrueColor => "真彩色",
            Row::FontFace => "字体",
            Row::FontSize => "字号",
            Row::ProfileFont => "当前 profile 字体",
            Row::ProfileFontSize => "当前 profile 字号",
            Row::ProfileGradient => "当前 profile 渐变",
            Row::ProfileGradientPalette => "当前 profile 配色",
            Row::ProfileTabColor => "当前 profile 标签色",
            Row::Scrollback => "回看行数",
            Row::Mouse => "鼠标上报",
            Row::CopyOnSelect => "选中即复制",
            Row::ConfirmClose => "关闭标签确认",
            Row::ConfirmPaste => "多行粘贴确认",
            Row::BackgroundImage => "背景图片",
            Row::BackgroundOpacity => "图片不透明度",
        }
    }

    /// 这一行的说明，显示在面板底部。
    pub fn hint(self) -> &'static str {
        match self {
            Row::Scheme => "所有 profile 共用的配色，立即生效",
            Row::DefaultProfile => "新建标签页 / 窗格使用的 profile（powershell / cmd / scterm）",
            Row::Gradient => "控制台按单元格着色，逐行/逐列插值",
            Row::GradientPalette => "「自动」按配色背景推导两端颜色，共 13 套预设",
            Row::TrueColor => "真彩色不可用时改用 256 色",
            Row::FontFace => "调用 SetCurrentConsoleFontEx；字体不存在会报错并沿用原字体",
            Row::FontSize => "字号像素高度，立即生效",
            Row::ProfileFont => "作用于当前标签的 profile；继承时沿用全局字体",
            Row::ProfileFontSize => "作用于当前标签的 profile；继承时沿用全局字号",
            Row::ProfileGradient => "作用于当前标签的 profile；继承时沿用全局渐变",
            Row::ProfileGradientPalette => "作用于当前标签的 profile；继承时沿用全局渐变配色",
            Row::ProfileTabColor => "该 profile 新建的标签用此底色；继承时用默认灰底",
            Row::Scrollback => "回看缓冲行数，修改后对现有窗格立即生效",
            Row::Mouse => "关闭后鼠标交给控制台（滚轮回看仍可用）",
            Row::CopyOnSelect => "松开鼠标即把选区写入剪贴板",
            Row::ConfirmClose => "Ctrl+Shift+W、中键、点 × 关闭前先问一次",
            Row::ConfirmPaste => "剪贴板含多行时先显示行数与预览再发送",
            Row::BackgroundImage => "空格/点值输入路径；←→ 在 backgrounds 文件夹里切换",
            Row::BackgroundOpacity => "0–100：越高图片越明显，越低越接近渐变背景",
        }
    }
}

/// 渐变配色预设：`None` 表示按配色方案背景自动推导。
pub const PALETTES: [(&str, Option<(u8, u8, u8)>, Option<(u8, u8, u8)>); 13] = [
    ("自动", None, None),
    ("深蓝", Some((0x1B, 0x2A, 0x45)), Some((0x05, 0x07, 0x0D))),
    ("紫黑", Some((0x24, 0x1A, 0x3A)), Some((0x07, 0x05, 0x0D))),
    ("青灰", Some((0x14, 0x30, 0x2F)), Some((0x05, 0x09, 0x0A))),
    ("暖灰", Some((0x2A, 0x26, 0x22)), Some((0x0A, 0x09, 0x08))),
    ("深绿", Some((0x10, 0x2C, 0x1C)), Some((0x04, 0x0A, 0x06))),
    ("酒红", Some((0x36, 0x14, 0x1C)), Some((0x0C, 0x04, 0x06))),
    ("棕金", Some((0x33, 0x27, 0x12)), Some((0x0B, 0x08, 0x04))),
    ("蓝紫", Some((0x22, 0x1C, 0x4A)), Some((0x06, 0x05, 0x10))),
    ("石墨", Some((0x2B, 0x2E, 0x33)), Some((0x08, 0x09, 0x0B))),
    ("冰蓝", Some((0x12, 0x2B, 0x3D)), Some((0x04, 0x08, 0x0E))),
    ("粉紫", Some((0x35, 0x1A, 0x33)), Some((0x0B, 0x05, 0x0A))),
    ("军绿", Some((0x24, 0x2A, 0x14)), Some((0x08, 0x09, 0x04))),
];

pub const GRADIENTS: [Option<GradientDir>; 4] = [
    None,
    Some(GradientDir::Vertical),
    Some(GradientDir::Horizontal),
    Some(GradientDir::Diagonal),
];

/// profile 的渐变覆盖选项（顺序即 `←→` 循环顺序）。
pub const PROFILE_GRADIENTS: [GradientOverride; 5] = [
    GradientOverride::Inherit,
    GradientOverride::Off,
    GradientOverride::Dir(GradientDir::Vertical),
    GradientOverride::Dir(GradientDir::Horizontal),
    GradientOverride::Dir(GradientDir::Diagonal),
];

/// profile 的标签底色预设；名称即十六进制写法。
pub const TAB_COLORS: [(&str, Color); 12] = [
    ("#3B78FF", Color::Rgb(0x3B, 0x78, 0xFF)),
    ("#C50F1F", Color::Rgb(0xC5, 0x0F, 0x1F)),
    ("#13A10E", Color::Rgb(0x13, 0xA1, 0x0E)),
    ("#C19C00", Color::Rgb(0xC1, 0x9C, 0x00)),
    ("#E74856", Color::Rgb(0xE7, 0x48, 0x56)),
    ("#881798", Color::Rgb(0x88, 0x17, 0x98)),
    ("#0078D7", Color::Rgb(0x00, 0x78, 0xD7)),
    ("#00B294", Color::Rgb(0x00, 0xB2, 0x94)),
    ("#F7630C", Color::Rgb(0xF7, 0x63, 0x0C)),
    ("#B4009E", Color::Rgb(0xB4, 0x00, 0x9E)),
    ("#767676", Color::Rgb(0x76, 0x76, 0x76)),
    ("#7A757E", Color::Rgb(0x7A, 0x75, 0x7E)),
];

pub const TRUECOLORS: [TrueColorMode; 3] = [
    TrueColorMode::Auto,
    TrueColorMode::Always,
    TrueColorMode::Never,
];

pub const FONT_SIZES: [u16; 7] = [12, 14, 16, 18, 20, 22, 24];
pub const SCROLLBACKS: [usize; 6] = [1_000, 2_000, 5_000, 10_000, 25_000, 50_000];

/// 可选字体：第一项是「默认」（沿用 conhost 当前字体）。
pub const FONT_FACES: [(&str, Option<&str>); 7] = [
    ("默认", None),
    ("Consolas", Some("Consolas")),
    ("Cascadia Mono", Some("Cascadia Mono")),
    ("Cascadia Code", Some("Cascadia Code")),
    ("Lucida Console", Some("Lucida Console")),
    ("Courier New", Some("Courier New")),
    ("宋体", Some("SimSun")),
];

/// 当前字体在 `FONT_FACES` 中的下标（未在列表里时返回 0）。
pub fn font_face_index(config: &Config) -> usize {
    let current = config.render.font_face.as_deref();
    FONT_FACES
        .iter()
        .position(|(_, face)| *face == current)
        .unwrap_or(0)
}

/// 循环取值：`delta` 为 ±1，越界时回绕。
pub fn cycle_index(len: usize, current: usize, delta: i32) -> usize {
    if len == 0 {
        return 0;
    }
    let len = len as i32;
    let current = current.min(len as usize - 1) as i32;
    (((current + delta) % len + len) % len) as usize
}

pub fn gradient_name(dir: Option<GradientDir>) -> &'static str {
    match dir {
        None => "关闭",
        Some(GradientDir::Vertical) => "竖向",
        Some(GradientDir::Horizontal) => "横向",
        Some(GradientDir::Diagonal) => "斜向",
    }
}

pub fn gradient_index(dir: Option<GradientDir>) -> usize {
    GRADIENTS.iter().position(|d| *d == dir).unwrap_or(1)
}

pub fn profile_gradient_index(value: GradientOverride) -> usize {
    PROFILE_GRADIENTS
        .iter()
        .position(|item| *item == value)
        .unwrap_or(0)
}

pub fn profile_gradient_name(value: GradientOverride) -> &'static str {
    match value {
        GradientOverride::Inherit => "继承",
        GradientOverride::Off => "关闭",
        GradientOverride::Dir(GradientDir::Vertical) => "竖向",
        GradientOverride::Dir(GradientDir::Horizontal) => "横向",
        GradientOverride::Dir(GradientDir::Diagonal) => "斜向",
    }
}

/// 标签色下标：0 = 继承，1..=12 对应 `TAB_COLORS`。
pub fn tab_color_index(color: Option<Color>) -> usize {
    match color {
        None => 0,
        Some(color) => TAB_COLORS
            .iter()
            .position(|(_, preset)| *preset == color)
            .map(|index| index + 1)
            .unwrap_or(0),
    }
}

pub fn tab_color_at(index: usize) -> Option<Color> {
    index
        .checked_sub(1)
        .and_then(|index| TAB_COLORS.get(index))
        .map(|(_, color)| *color)
}

pub fn tab_color_name(color: Option<Color>) -> String {
    match color {
        None => "继承".to_string(),
        Some(color) => TAB_COLORS
            .iter()
            .find(|(_, preset)| *preset == color)
            .map(|(name, _)| name.to_string())
            .unwrap_or_else(|| match color {
                Color::Rgb(r, g, b) => format!("#{r:02X}{g:02X}{b:02X}"),
                other => format!("{other:?}"),
            }),
    }
}

/// profile 渐变配色的预设下标：`Some(0)` = 继承，`Some(1..=12)` = 预设，`None` = 自定义。
pub fn profile_palette_index(profile: &Profile) -> Option<usize> {
    if profile.gradient_top.is_none() && profile.gradient_bottom.is_none() {
        return Some(0);
    }
    let top = rgb(profile.gradient_top);
    let bottom = rgb(profile.gradient_bottom);
    PALETTES
        .iter()
        .enumerate()
        .skip(1)
        .find(|(_, (_, preset_top, preset_bottom))| *preset_top == top && *preset_bottom == bottom)
        .map(|(index, _)| index)
}

pub fn profile_palette_colors(index: usize) -> (Option<Color>, Option<Color>) {
    palette_colors(index)
}

pub fn truecolor_name(mode: TrueColorMode) -> &'static str {
    match mode {
        TrueColorMode::Auto => "自动",
        TrueColorMode::Always => "总是",
        TrueColorMode::Never => "从不",
    }
}

pub fn palette_index(config: &Config) -> usize {
    let top = rgb(config.render.gradient_top);
    let bottom = rgb(config.render.gradient_bottom);
    PALETTES
        .iter()
        .position(|(_, t, b)| *t == top && *b == bottom)
        .unwrap_or(0)
}

pub fn palette_colors(index: usize) -> (Option<Color>, Option<Color>) {
    let (_, top, bottom) = PALETTES[index.min(PALETTES.len() - 1)];
    (top.map(rgb_color), bottom.map(rgb_color))
}

fn rgb(color: Option<Color>) -> Option<(u8, u8, u8)> {
    match color {
        Some(Color::Rgb(r, g, b)) => Some((r, g, b)),
        _ => None,
    }
}

fn rgb_color(rgb: (u8, u8, u8)) -> Color {
    Color::Rgb(rgb.0, rgb.1, rgb.2)
}

/// 最接近给定值的下标（字号、回看行数这类数值型选项用）。
pub fn nearest_index<T: Copy + Ord + std::ops::Sub<Output = T>>(values: &[T], current: T) -> usize {
    let mut best = 0;
    let mut best_gap = None;
    for (index, value) in values.iter().enumerate() {
        let gap = if *value > current {
            *value - current
        } else {
            current - *value
        };
        if best_gap.map(|best_gap| gap < best_gap).unwrap_or(true) {
            best_gap = Some(gap);
            best = index;
        }
    }
    best
}

/// 打开设置时的配置快照；Esc 取消时按它回滚。
#[derive(Debug, Clone)]
pub struct Snapshot {
    default_profile: String,
    gradient: Option<GradientDir>,
    gradient_top: Option<Color>,
    gradient_bottom: Option<Color>,
    truecolor: TrueColorMode,
    font_face: Option<String>,
    font_size: Option<u16>,
    scrollback: usize,
    mouse: bool,
    copy_on_select: bool,
    confirm_close: bool,
    confirm_multiline_paste: bool,
    background_image: Option<String>,
    background_image_opacity: u8,
    profiles: Vec<Profile>,
}

impl Snapshot {
    pub fn capture(config: &Config) -> Snapshot {
        Snapshot {
            default_profile: config.default_profile.clone(),
            gradient: config.render.gradient,
            gradient_top: config.render.gradient_top,
            gradient_bottom: config.render.gradient_bottom,
            truecolor: config.render.truecolor,
            font_face: config.render.font_face.clone(),
            font_size: config.render.font_size,
            scrollback: config.scrollback,
            mouse: config.render.mouse,
            copy_on_select: config.behavior.copy_on_select,
            confirm_close: config.behavior.confirm_close,
            confirm_multiline_paste: config.behavior.confirm_multiline_paste,
            background_image: config.render.background_image.clone(),
            background_image_opacity: config.render.background_image_opacity,
            profiles: config.profiles.clone(),
        }
    }

    pub fn restore(&self, config: &mut Config) {
        config.default_profile = self.default_profile.clone();
        config.render.gradient = self.gradient;
        config.render.gradient_top = self.gradient_top;
        config.render.gradient_bottom = self.gradient_bottom;
        config.render.truecolor = self.truecolor;
        config.render.font_face = self.font_face.clone();
        config.render.font_size = self.font_size;
        config.scrollback = self.scrollback;
        config.render.mouse = self.mouse;
        config.behavior.copy_on_select = self.copy_on_select;
        config.behavior.confirm_close = self.confirm_close;
        config.behavior.confirm_multiline_paste = self.confirm_multiline_paste;
        config.render.background_image = self.background_image.clone();
        config.render.background_image_opacity = self.background_image_opacity;
        config.profiles = self.profiles.clone();
    }
}

pub struct SettingsState {
    pub selected: usize,
    pub snapshot: Snapshot,
}

impl SettingsState {
    pub fn new(config: &Config) -> SettingsState {
        SettingsState {
            selected: 0,
            snapshot: Snapshot::capture(config),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cycling_wraps_both_ways() {
        assert_eq!(cycle_index(4, 0, 1), 1);
        assert_eq!(cycle_index(4, 3, 1), 0);
        assert_eq!(cycle_index(4, 0, -1), 3);
        assert_eq!(cycle_index(0, 0, 1), 0);
    }

    #[test]
    fn gradient_and_palette_indexes() {
        assert_eq!(gradient_index(None), 0);
        assert_eq!(gradient_index(Some(GradientDir::Vertical)), 1);
        assert_eq!(gradient_index(Some(GradientDir::Diagonal)), 3);
        assert_eq!(gradient_name(None), "关闭");

        let mut config = Config::default();
        assert_eq!(palette_index(&config), 0, "默认应为自动");
        let (top, bottom) = palette_colors(1);
        config.render.gradient_top = top;
        config.render.gradient_bottom = bottom;
        assert_eq!(palette_index(&config), 1);
    }

    #[test]
    fn palette_presets_are_distinct_and_round_trip() {
        assert!(PALETTES.len() >= 12, "至少保留 12 套预设");
        for (index, (name, top, bottom)) in PALETTES.iter().enumerate() {
            assert!(
                PALETTES[..index].iter().all(|(other, _, _)| other != name),
                "预设名重复：{name}"
            );
            if index > 0 {
                assert!(top.is_some() && bottom.is_some(), "具体配色两端色都应存在");
                assert!(
                    PALETTES[..index]
                        .iter()
                        .all(|(_, t, b)| *t != *top || *b != *bottom),
                    "预设色重复：{name}"
                );
            }
        }
        for index in 0..PALETTES.len() {
            let (top, bottom) = palette_colors(index);
            let mut config = Config::default();
            config.render.gradient_top = top;
            config.render.gradient_bottom = bottom;
            assert_eq!(palette_index(&config), index, "第 {index} 套应能回读");
        }
    }

    #[test]
    fn nearest_font_size() {
        assert_eq!(nearest_index(&FONT_SIZES, 16u16), 2);
        assert_eq!(nearest_index(&FONT_SIZES, 15u16), 1);
        assert_eq!(nearest_index(&FONT_SIZES, 100u16), 6);
        assert_eq!(nearest_index(&SCROLLBACKS, 12_000usize), 3);
    }

    #[test]
    fn snapshot_restores_render_and_schemes() {
        let mut config = Config::default();
        config.render.gradient = Some(GradientDir::Vertical);
        config.scrollback = 10_000;
        if let Some(first) = config.profiles.first_mut() {
            first.color_scheme = Some("Campbell".into());
        }
        let snapshot = Snapshot::capture(&config);
        config.render.gradient = None;
        config.scrollback = 1_000;
        if let Some(first) = config.profiles.first_mut() {
            first.color_scheme = Some("Dracula".into());
        }
        snapshot.restore(&mut config);
        assert_eq!(config.render.gradient, Some(GradientDir::Vertical));
        assert_eq!(config.scrollback, 10_000);
        assert_eq!(
            config.profiles.first().and_then(|p| p.color_scheme.clone()),
            Some("Campbell".to_string())
        );
    }

    #[test]
    fn profile_rows_and_options() {
        assert_eq!(ROWS.len(), 19);
        let font_size = ROWS
            .iter()
            .position(|row| *row == Row::FontSize)
            .expect("应有全局字号行");
        for (offset, row) in [
            Row::ProfileFont,
            Row::ProfileFontSize,
            Row::ProfileGradient,
            Row::ProfileGradientPalette,
            Row::ProfileTabColor,
        ]
        .iter()
        .enumerate()
        {
            assert_eq!(ROWS[font_size + 1 + offset], *row, "profile 行应紧跟字号行");
        }
        assert_eq!(PROFILE_GRADIENTS.len(), 5);
        assert_eq!(TAB_COLORS.len(), 12);
        assert_eq!(tab_color_index(None), 0);
        assert_eq!(tab_color_index(Some(TAB_COLORS[2].1)), 3);
        assert_eq!(tab_color_at(3), Some(TAB_COLORS[2].1));
        assert_eq!(tab_color_at(0), None);
        assert_eq!(tab_color_name(None), "继承");
        assert_eq!(tab_color_name(Some(TAB_COLORS[0].1)), TAB_COLORS[0].0);

        let mut profile = Profile {
            name: "p".into(),
            command: "cmd.exe".into(),
            args: Vec::new(),
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
        assert_eq!(profile_palette_index(&profile), Some(0), "两端色都空 = 继承");
        let (top, bottom) = profile_palette_colors(1);
        profile.gradient_top = top;
        profile.gradient_bottom = bottom;
        assert_eq!(profile_palette_index(&profile), Some(1));
        profile.gradient_top = Some(Color::Rgb(1, 2, 3));
        profile.gradient_bottom = None;
        assert_eq!(profile_palette_index(&profile), None, "自定义颜色");
        assert_eq!(profile_gradient_index(GradientOverride::Off), 1);
        assert_eq!(
            profile_gradient_name(GradientOverride::Dir(GradientDir::Horizontal)),
            "横向"
        );
    }
}

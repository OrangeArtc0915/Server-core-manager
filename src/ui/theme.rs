//! 主题：12 套配色，界面与语法高亮共用一套调色板。

use crate::core::highlight::TokenKind;
use crate::render::Color;

#[derive(Clone, Copy)]
pub struct Syntax {
    pub keyword: Color,
    pub type_: Color,
    pub string: Color,
    pub number: Color,
    pub comment: Color,
    pub function: Color,
    pub operator: Color,
    pub property: Color,
    pub tag: Color,
    pub attribute: Color,
    pub heading: Color,
    pub link: Color,
    pub constant: Color,
    pub variable: Color,
    pub macro_: Color,
}

#[derive(Clone, Copy)]
pub struct Theme {
    pub name: &'static str,
    pub dark: bool,
    pub bg: Color,
    pub fg: Color,
    pub panel_bg: Color,
    pub panel_fg: Color,
    pub activity_bg: Color,
    pub activity_fg: Color,
    pub tab_active_bg: Color,
    pub tab_inactive_bg: Color,
    pub border: Color,
    pub accent: Color,
    pub selection: Color,
    pub cursor: Color,
    pub current_line: Color,
    pub gutter_fg: Color,
    pub status_bg: Color,
    pub status_fg: Color,
    pub minimap_bg: Color,
    pub added: Color,
    pub removed: Color,
    pub find_bg: Color,
    pub syntax: Syntax,
}

macro_rules! theme {
    (
        $name:literal, $dark:literal,
        bg $bg:expr, fg $fg:expr, panel $panel:expr, accent $accent:expr,
        sel $sel:expr, border $border:expr, status $status:expr,
        syntax { text $stext:expr, kw $kw:expr, ty $ty:expr, str $str:expr,
                 num $num:expr, com $com:expr, fun $fun:expr, prop $prop:expr,
                 tag $tag:expr, attr $attr:expr, head $head:expr, link $link:expr,
                 konst $konst:expr, var $var:expr, mac $mac:expr }
    ) => {
        Theme {
            name: $name,
            dark: $dark,
            bg: $bg,
            fg: $fg,
            panel_bg: $panel,
            panel_fg: $stext,
            activity_bg: $panel,
            activity_fg: $fg,
            tab_active_bg: $bg,
            tab_inactive_bg: $panel,
            border: $border,
            accent: $accent,
            selection: $sel,
            cursor: $fg,
            current_line: $bg,
            gutter_fg: $com,
            status_bg: $status,
            status_fg: Color::rgb(255, 255, 255),
            minimap_bg: $panel,
            added: Color::rgb(88, 166, 88),
            removed: Color::rgb(220, 90, 90),
            find_bg: $sel,
            syntax: Syntax {
                keyword: $kw,
                type_: $ty,
                string: $str,
                number: $num,
                comment: $com,
                function: $fun,
                operator: $stext,
                property: $prop,
                tag: $tag,
                attribute: $attr,
                heading: $head,
                link: $link,
                constant: $konst,
                variable: $var,
                macro_: $mac,
            },
        }
    };
}

pub fn names() -> &'static [&'static str] {
    &[
        "tokyonight-storm",
        "ristretto",
        "vscode-dark",
        "vscode-dark16",
        "vscode-light",
        "dracula",
        "one-dark",
        "monokai",
        "nord",
        "gruvbox-dark",
        "tokyo-night",
        "solarized-dark",
        "solarized-light",
        "github-light",
    ]
}

pub fn by_name(name: &str) -> Theme {
    let key = name.trim();
    if let Some(theme) = dynamic_theme(key) {
        return theme;
    }
    match key.to_ascii_lowercase().as_str() {
        "tokyonight-storm" | "tokyo-storm" => tokyonight_storm(),
        "ristretto" => ristretto(),
        "vscode-dark" | "default" => vscode_dark(),
        "vscode-dark16" => vscode_dark16(),
        "vscode-light" => vscode_light(),
        "dracula" => dracula(),
        "one-dark" | "onedark" => one_dark(),
        "monokai" => monokai(),
        "nord" => nord(),
        "gruvbox-dark" | "gruvbox" => gruvbox_dark(),
        "tokyo-night" | "tokyonight" => tokyo_night(),
        "solarized-dark" => solarized_dark(),
        "solarized-light" => solarized_light(),
        "github-light" => github_light(),
        _ => tokyonight_storm(),
    }
}

// ---------------------------------------------------------------- 动态主题

use std::sync::{Mutex, OnceLock};

static DYNAMIC: OnceLock<Mutex<Vec<Theme>>> = OnceLock::new();

fn dynamic_list() -> &'static Mutex<Vec<Theme>> {
    DYNAMIC.get_or_init(|| Mutex::new(Vec::new()))
}

/// 注册（或覆盖）来自扩展市场的主题；名称需为 `'static`（调用方可泄漏名称）。
pub fn register(theme: Theme) {
    let mut list = match dynamic_list().lock() {
        Ok(guard) => guard,
        Err(e) => e.into_inner(),
    };
    if let Some(slot) = list
        .iter_mut()
        .find(|item| item.name.eq_ignore_ascii_case(theme.name))
    {
        *slot = theme;
    } else {
        list.push(theme);
    }
}

pub fn dynamic_theme(name: &str) -> Option<Theme> {
    let list = match dynamic_list().lock() {
        Ok(guard) => guard,
        Err(e) => e.into_inner(),
    };
    list.iter()
        .find(|item| item.name.eq_ignore_ascii_case(name))
        .copied()
}

/// 移除动态主题（卸载扩展后调用）。
pub fn unregister(name: &str) {
    let mut list = match dynamic_list().lock() {
        Ok(guard) => guard,
        Err(e) => e.into_inner(),
    };
    list.retain(|item| !item.name.eq_ignore_ascii_case(name));
}

/// 内置 + 动态主题名称（主题选择器使用）。
pub fn all_names() -> Vec<&'static str> {
    let mut out: Vec<&'static str> = names().to_vec();
    let list = match dynamic_list().lock() {
        Ok(guard) => guard,
        Err(e) => e.into_inner(),
    };
    for theme in list.iter() {
        out.push(theme.name);
    }
    out
}

/// 切换到下一套主题，返回新主题名。
pub fn next_name(current: &str) -> &'static str {
    let list = all_names();
    let index = list
        .iter()
        .position(|n| n.eq_ignore_ascii_case(current))
        .unwrap_or(0);
    list[(index + 1) % list.len()]
}

fn vscode_dark() -> Theme {
    theme!(
        "vscode-dark", true,
        bg Color::rgb(30, 30, 30), fg Color::rgb(212, 212, 212),
        panel Color::rgb(37, 37, 38), accent Color::rgb(0, 122, 204),
        sel Color::rgb(38, 79, 120), border Color::rgb(60, 60, 60),
        status Color::rgb(0, 122, 204),
        syntax { text Color::rgb(212, 212, 212), kw Color::rgb(86, 156, 214),
                 ty Color::rgb(78, 201, 176), str Color::rgb(206, 145, 120),
                 num Color::rgb(181, 206, 168), com Color::rgb(106, 153, 85),
                 fun Color::rgb(220, 220, 170), prop Color::rgb(156, 220, 254),
                 tag Color::rgb(86, 156, 214), attr Color::rgb(156, 220, 254),
                 head Color::rgb(86, 156, 214), link Color::rgb(79, 193, 255),
                 konst Color::rgb(79, 193, 255), var Color::rgb(156, 220, 254),
                 mac Color::rgb(197, 134, 192) }
    )
}

fn vscode_dark16() -> Theme {
    theme!(
        "vscode-dark16", true,
        bg Color::rgb(0, 0, 0), fg Color::rgb(204, 204, 204),
        panel Color::rgb(16, 16, 16), accent Color::rgb(0, 102, 204),
        sel Color::rgb(38, 79, 120), border Color::rgb(48, 48, 48),
        status Color::rgb(0, 102, 204),
        syntax { text Color::rgb(204, 204, 204), kw Color::rgb(86, 156, 214),
                 ty Color::rgb(78, 201, 176), str Color::rgb(206, 145, 120),
                 num Color::rgb(181, 206, 168), com Color::rgb(106, 153, 85),
                 fun Color::rgb(220, 220, 170), prop Color::rgb(156, 220, 254),
                 tag Color::rgb(86, 156, 214), attr Color::rgb(156, 220, 254),
                 head Color::rgb(86, 156, 214), link Color::rgb(79, 193, 255),
                 konst Color::rgb(79, 193, 255), var Color::rgb(156, 220, 254),
                 mac Color::rgb(197, 134, 192) }
    )
}

fn vscode_light() -> Theme {
    theme!(
        "vscode-light", false,
        bg Color::rgb(255, 255, 255), fg Color::rgb(0, 0, 0),
        panel Color::rgb(243, 243, 243), accent Color::rgb(0, 122, 204),
        sel Color::rgb(173, 214, 255), border Color::rgb(224, 224, 224),
        status Color::rgb(0, 122, 204),
        syntax { text Color::rgb(0, 0, 0), kw Color::rgb(0, 0, 255),
                 ty Color::rgb(38, 127, 153), str Color::rgb(163, 21, 21),
                 num Color::rgb(9, 134, 88), com Color::rgb(0, 128, 0),
                 fun Color::rgb(121, 94, 38), prop Color::rgb(0, 16, 128),
                 tag Color::rgb(128, 0, 0), attr Color::rgb(255, 0, 0),
                 head Color::rgb(128, 0, 0), link Color::rgb(0, 0, 255),
                 konst Color::rgb(0, 16, 128), var Color::rgb(0, 16, 128),
                 mac Color::rgb(175, 0, 219) }
    )
}

fn dracula() -> Theme {
    theme!(
        "dracula", true,
        bg Color::rgb(40, 42, 54), fg Color::rgb(248, 248, 242),
        panel Color::rgb(33, 34, 44), accent Color::rgb(189, 147, 249),
        sel Color::rgb(68, 71, 90), border Color::rgb(68, 71, 90),
        status Color::rgb(189, 147, 249),
        syntax { text Color::rgb(248, 248, 242), kw Color::rgb(255, 121, 198),
                 ty Color::rgb(139, 233, 253), str Color::rgb(241, 250, 140),
                 num Color::rgb(189, 147, 249), com Color::rgb(98, 114, 164),
                 fun Color::rgb(80, 250, 123), prop Color::rgb(139, 233, 253),
                 tag Color::rgb(255, 121, 198), attr Color::rgb(80, 250, 123),
                 head Color::rgb(139, 233, 253), link Color::rgb(139, 233, 253),
                 konst Color::rgb(189, 147, 249), var Color::rgb(248, 248, 242),
                 mac Color::rgb(255, 184, 108) }
    )
}

fn one_dark() -> Theme {
    theme!(
        "one-dark", true,
        bg Color::rgb(40, 44, 52), fg Color::rgb(171, 178, 191),
        panel Color::rgb(33, 37, 43), accent Color::rgb(97, 175, 239),
        sel Color::rgb(62, 68, 81), border Color::rgb(62, 68, 81),
        status Color::rgb(97, 175, 239),
        syntax { text Color::rgb(171, 178, 191), kw Color::rgb(198, 120, 221),
                 ty Color::rgb(229, 192, 123), str Color::rgb(152, 195, 121),
                 num Color::rgb(209, 154, 102), com Color::rgb(92, 99, 112),
                 fun Color::rgb(97, 175, 239), prop Color::rgb(224, 108, 117),
                 tag Color::rgb(224, 108, 117), attr Color::rgb(209, 154, 102),
                 head Color::rgb(97, 175, 239), link Color::rgb(86, 182, 194),
                 konst Color::rgb(209, 154, 102), var Color::rgb(224, 108, 117),
                 mac Color::rgb(198, 120, 221) }
    )
}

fn monokai() -> Theme {
    theme!(
        "monokai", true,
        bg Color::rgb(39, 40, 34), fg Color::rgb(248, 248, 242),
        panel Color::rgb(30, 31, 28), accent Color::rgb(166, 226, 46),
        sel Color::rgb(73, 72, 62), border Color::rgb(73, 72, 62),
        status Color::rgb(166, 226, 46),
        syntax { text Color::rgb(248, 248, 242), kw Color::rgb(249, 38, 114),
                 ty Color::rgb(102, 217, 239), str Color::rgb(230, 219, 116),
                 num Color::rgb(174, 129, 255), com Color::rgb(117, 113, 94),
                 fun Color::rgb(166, 226, 46), prop Color::rgb(102, 217, 239),
                 tag Color::rgb(249, 38, 114), attr Color::rgb(166, 226, 46),
                 head Color::rgb(166, 226, 46), link Color::rgb(102, 217, 239),
                 konst Color::rgb(174, 129, 255), var Color::rgb(248, 248, 242),
                 mac Color::rgb(249, 38, 114) }
    )
}

fn nord() -> Theme {
    theme!(
        "nord", true,
        bg Color::rgb(46, 52, 64), fg Color::rgb(216, 222, 233),
        panel Color::rgb(59, 66, 82), accent Color::rgb(136, 192, 208),
        sel Color::rgb(67, 76, 94), border Color::rgb(76, 86, 106),
        status Color::rgb(94, 129, 172),
        syntax { text Color::rgb(216, 222, 233), kw Color::rgb(129, 161, 193),
                 ty Color::rgb(143, 188, 187), str Color::rgb(163, 190, 140),
                 num Color::rgb(180, 142, 173), com Color::rgb(97, 110, 136),
                 fun Color::rgb(136, 192, 208), prop Color::rgb(143, 188, 187),
                 tag Color::rgb(129, 161, 193), attr Color::rgb(143, 188, 187),
                 head Color::rgb(136, 192, 208), link Color::rgb(136, 192, 208),
                 konst Color::rgb(180, 142, 173), var Color::rgb(216, 222, 233),
                 mac Color::rgb(191, 97, 106) }
    )
}

fn gruvbox_dark() -> Theme {
    theme!(
        "gruvbox-dark", true,
        bg Color::rgb(40, 40, 40), fg Color::rgb(235, 219, 178),
        panel Color::rgb(50, 48, 47), accent Color::rgb(250, 189, 47),
        sel Color::rgb(80, 73, 69), border Color::rgb(80, 73, 69),
        status Color::rgb(215, 153, 33),
        syntax { text Color::rgb(235, 219, 178), kw Color::rgb(251, 73, 52),
                 ty Color::rgb(131, 165, 152), str Color::rgb(184, 187, 38),
                 num Color::rgb(211, 134, 155), com Color::rgb(146, 131, 116),
                 fun Color::rgb(250, 189, 47), prop Color::rgb(131, 165, 152),
                 tag Color::rgb(251, 73, 52), attr Color::rgb(250, 189, 47),
                 head Color::rgb(250, 189, 47), link Color::rgb(131, 165, 152),
                 konst Color::rgb(211, 134, 155), var Color::rgb(235, 219, 178),
                 mac Color::rgb(211, 134, 155) }
    )
}

fn tokyo_night() -> Theme {
    theme!(
        "tokyo-night", true,
        bg Color::rgb(26, 27, 38), fg Color::rgb(192, 202, 245),
        panel Color::rgb(22, 22, 30), accent Color::rgb(122, 162, 247),
        sel Color::rgb(40, 52, 87), border Color::rgb(41, 46, 66),
        status Color::rgb(122, 162, 247),
        syntax { text Color::rgb(192, 202, 245), kw Color::rgb(187, 154, 247),
                 ty Color::rgb(42, 195, 222), str Color::rgb(158, 206, 106),
                 num Color::rgb(255, 158, 100), com Color::rgb(86, 95, 137),
                 fun Color::rgb(122, 162, 247), prop Color::rgb(42, 195, 222),
                 tag Color::rgb(247, 118, 142), attr Color::rgb(255, 158, 100),
                 head Color::rgb(122, 162, 247), link Color::rgb(125, 207, 255),
                 konst Color::rgb(255, 158, 100), var Color::rgb(192, 202, 245),
                 mac Color::rgb(187, 154, 247) }
    )
}

fn solarized_dark() -> Theme {
    theme!(
        "solarized-dark", true,
        bg Color::rgb(0, 43, 54), fg Color::rgb(131, 148, 150),
        panel Color::rgb(7, 54, 66), accent Color::rgb(38, 139, 210),
        sel Color::rgb(7, 54, 66), border Color::rgb(88, 110, 117),
        status Color::rgb(38, 139, 210),
        syntax { text Color::rgb(131, 148, 150), kw Color::rgb(133, 153, 0),
                 ty Color::rgb(181, 137, 0), str Color::rgb(42, 161, 152),
                 num Color::rgb(211, 54, 130), com Color::rgb(88, 110, 117),
                 fun Color::rgb(38, 139, 210), prop Color::rgb(42, 161, 152),
                 tag Color::rgb(38, 139, 210), attr Color::rgb(181, 137, 0),
                 head Color::rgb(38, 139, 210), link Color::rgb(42, 161, 152),
                 konst Color::rgb(211, 54, 130), var Color::rgb(131, 148, 150),
                 mac Color::rgb(108, 113, 196) }
    )
}

fn solarized_light() -> Theme {
    theme!(
        "solarized-light", false,
        bg Color::rgb(253, 246, 227), fg Color::rgb(101, 123, 131),
        panel Color::rgb(238, 232, 213), accent Color::rgb(38, 139, 210),
        sel Color::rgb(222, 214, 190), border Color::rgb(200, 190, 165),
        status Color::rgb(38, 139, 210),
        syntax { text Color::rgb(101, 123, 131), kw Color::rgb(133, 153, 0),
                 ty Color::rgb(181, 137, 0), str Color::rgb(42, 161, 152),
                 num Color::rgb(211, 54, 130), com Color::rgb(147, 161, 161),
                 fun Color::rgb(38, 139, 210), prop Color::rgb(42, 161, 152),
                 tag Color::rgb(38, 139, 210), attr Color::rgb(181, 137, 0),
                 head Color::rgb(38, 139, 210), link Color::rgb(42, 161, 152),
                 konst Color::rgb(211, 54, 130), var Color::rgb(101, 123, 131),
                 mac Color::rgb(108, 113, 196) }
    )
}

fn github_light() -> Theme {
    theme!(
        "github-light", false,
        bg Color::rgb(255, 255, 255), fg Color::rgb(36, 41, 47),
        panel Color::rgb(246, 248, 250), accent Color::rgb(9, 105, 218),
        sel Color::rgb(216, 228, 250), border Color::rgb(208, 215, 222),
        status Color::rgb(9, 105, 218),
        syntax { text Color::rgb(36, 41, 47), kw Color::rgb(207, 34, 46),
                 ty Color::rgb(149, 56, 0), str Color::rgb(10, 48, 105),
                 num Color::rgb(5, 80, 174), com Color::rgb(110, 119, 129),
                 fun Color::rgb(130, 80, 223), prop Color::rgb(5, 80, 174),
                 tag Color::rgb(17, 99, 41), attr Color::rgb(5, 80, 174),
                 head Color::rgb(9, 105, 218), link Color::rgb(9, 105, 218),
                 konst Color::rgb(5, 80, 174), var Color::rgb(36, 41, 47),
                 mac Color::rgb(130, 80, 223) }
    )
}

impl Theme {
    pub fn token_color(&self, kind: TokenKind) -> Color {
        match kind {
            TokenKind::Keyword => self.syntax.keyword,
            TokenKind::Type => self.syntax.type_,
            TokenKind::String => self.syntax.string,
            TokenKind::Number => self.syntax.number,
            TokenKind::Comment => self.syntax.comment,
            TokenKind::Function => self.syntax.function,
            TokenKind::Macro => self.syntax.macro_,
            TokenKind::Operator => self.syntax.operator,
            TokenKind::Property => self.syntax.property,
            TokenKind::Tag => self.syntax.tag,
            TokenKind::Attribute => self.syntax.attribute,
            TokenKind::Heading => self.syntax.heading,
            TokenKind::Link => self.syntax.link,
            TokenKind::Constant => self.syntax.constant,
            TokenKind::Variable => self.syntax.variable,
        }
    }

    /// 行高亮色（当前行比背景略亮 / 略暗）。
    pub fn current_line_bg(&self) -> Color {
        if self.dark {
            self.bg.blend(Color::rgb(255, 255, 255), 14)
        } else {
            self.bg.blend(Color::rgb(0, 0, 0), 10)
        }
    }

    pub fn selection_bg(&self) -> Color {
        self.selection
    }

    /// 列表行悬停底色（比面板略亮）。
    pub fn hover_bg(&self) -> Color {
        self.panel_bg.blend(self.fg, 12)
    }

    /// 浮层 / 菜单项的轻微抬起底色。
    pub fn raised_bg(&self) -> Color {
        self.panel_bg.blend(self.fg, 7)
    }

    /// 低对比分隔线。
    pub fn divider(&self) -> Color {
        self.border.blend(self.panel_bg, 90)
    }
}

/// tokyonight-storm：冷蓝底色、柔和分层，参考 sqlmux 默认主题。
fn tokyonight_storm() -> Theme {
    let mut theme = theme!(
        "tokyonight-storm", true,
        bg Color::rgb(36, 40, 59), fg Color::rgb(192, 202, 245),
        panel Color::rgb(31, 35, 53), accent Color::rgb(122, 162, 247),
        sel Color::rgb(54, 74, 130), border Color::rgb(59, 66, 97),
        status Color::rgb(31, 35, 53),
        syntax { text Color::rgb(192, 202, 245), kw Color::rgb(187, 154, 247),
                 ty Color::rgb(42, 195, 222), str Color::rgb(158, 206, 106),
                 num Color::rgb(255, 158, 100), com Color::rgb(86, 95, 137),
                 fun Color::rgb(122, 162, 247), prop Color::rgb(115, 218, 202),
                 tag Color::rgb(247, 118, 142), attr Color::rgb(224, 175, 104),
                 head Color::rgb(122, 162, 247), link Color::rgb(115, 218, 202),
                 konst Color::rgb(255, 158, 100), var Color::rgb(192, 202, 245),
                 mac Color::rgb(187, 154, 247) }
    );
    theme.current_line = Color::rgb(41, 46, 66);
    theme.gutter_fg = Color::rgb(86, 95, 137);
    theme.activity_bg = Color::rgb(26, 27, 38);
    theme.activity_fg = Color::rgb(169, 177, 214);
    theme.tab_active_bg = Color::rgb(36, 40, 59);
    theme.tab_inactive_bg = Color::rgb(31, 35, 53);
    theme.status_fg = Color::rgb(192, 202, 245);
    theme.minimap_bg = Color::rgb(31, 35, 53);
    theme.added = Color::rgb(158, 206, 106);
    theme.removed = Color::rgb(247, 118, 142);
    theme.find_bg = Color::rgb(61, 89, 161);
    theme
}

/// ristretto：暖棕底色、柔和对比。
fn ristretto() -> Theme {
    let mut theme = theme!(
        "ristretto", true,
        bg Color::rgb(42, 35, 35), fg Color::rgb(232, 219, 221),
        panel Color::rgb(31, 26, 26), accent Color::rgb(243, 141, 112),
        sel Color::rgb(79, 62, 58), border Color::rgb(70, 57, 55),
        status Color::rgb(30, 25, 25),
        syntax { text Color::rgb(230, 217, 219), kw Color::rgb(168, 169, 235),
                 ty Color::rgb(133, 218, 204), str Color::rgb(173, 218, 120),
                 num Color::rgb(249, 204, 108), com Color::rgb(114, 105, 106),
                 fun Color::rgb(243, 141, 112), prop Color::rgb(133, 218, 204),
                 tag Color::rgb(253, 104, 131), attr Color::rgb(249, 204, 108),
                 head Color::rgb(243, 141, 112), link Color::rgb(133, 218, 204),
                 konst Color::rgb(243, 141, 112), var Color::rgb(230, 217, 219),
                 mac Color::rgb(168, 169, 235) }
    );
    theme.current_line = Color::rgb(56, 46, 45);
    theme.gutter_fg = Color::rgb(124, 111, 110);
    theme.activity_bg = Color::rgb(29, 24, 24);
    theme.activity_fg = Color::rgb(214, 199, 200);
    theme.tab_active_bg = Color::rgb(47, 39, 38);
    theme.tab_inactive_bg = Color::rgb(34, 29, 29);
    theme.status_fg = Color::rgb(232, 219, 221);
    theme.minimap_bg = Color::rgb(31, 26, 26);
    theme.added = Color::rgb(173, 218, 120);
    theme.removed = Color::rgb(253, 104, 131);
    theme.find_bg = Color::rgb(88, 66, 58);
    theme
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_themes_load() {
        for name in names() {
            let theme = by_name(name);
            assert_eq!(theme.name, *name);
            assert_ne!(theme.syntax.keyword, theme.bg);
        }
    }

    #[test]
    fn unknown_theme_falls_back() {
        assert_eq!(by_name("does-not-exist").name, "tokyonight-storm");
    }

    #[test]
    fn new_themes_have_layered_colors() {
        let storm = by_name("tokyonight-storm");
        assert_ne!(storm.current_line, storm.bg);
        assert_ne!(storm.panel_bg, storm.bg);
        let warm = by_name("ristretto");
        assert_ne!(warm.current_line, warm.bg);
    }
}

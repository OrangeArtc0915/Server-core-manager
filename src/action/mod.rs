//! 动作系统：所有 UI 操作都表达为 `Action`，快捷键只负责把键盘组合映射到动作。

use crate::config::ActionBinding;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitAxis {
    /// 左右分割（新窗格在右侧）
    Horizontal,
    /// 上下分割（新窗格在下方）
    Vertical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    NewTab,
    /// 新建标签页时先选择 profile（Ctrl+Shift+B / Alt+点「+」）。
    NewTabWithProfile,
    CloseTab,
    NextTab,
    PrevTab,
    /// 切换到第 N 个标签页（0 起）。
    SelectTab(usize),
    LastTab,
    RenameTab,
    SplitPane(SplitAxis),
    ClosePane,
    FocusPane(Direction),
    /// 放大/还原聚焦窗格（独占内容区）。
    TogglePaneZoom,
    /// 与指定方向的相邻窗格交换位置，焦点跟随窗格。
    SwapPane(Direction),
    /// 把聚焦窗格移到新标签页。
    MovePaneToNewTab,
    /// 按方向调整紧邻的分隔线（每次 5%）。
    ResizePane(Direction),
    CommandPalette,
    Settings,
    Search,
    /// 键盘标记模式（Ctrl+Shift+M）。
    MarkMode,
    ScrollUp,
    ScrollDown,
    ScrollPageUp,
    ScrollPageDown,
    ScrollBottom,
    PromptUp,
    PromptDown,
    PromptFirst,
    PromptLast,
    Copy,
    Paste,
    ReloadConfig,
    Quit,
}

impl Action {
    pub fn id(&self) -> &'static str {
        match self {
            Action::NewTab => "newTab",
            Action::NewTabWithProfile => "newTabWithProfile",
            Action::CloseTab => "closeTab",
            Action::NextTab => "nextTab",
            Action::PrevTab => "prevTab",
            Action::SelectTab(index) => match index {
                0 => "selectTab1",
                1 => "selectTab2",
                2 => "selectTab3",
                3 => "selectTab4",
                4 => "selectTab5",
                5 => "selectTab6",
                6 => "selectTab7",
                _ => "selectTab8",
            },
            Action::LastTab => "lastTab",
            Action::RenameTab => "renameTab",
            Action::SplitPane(SplitAxis::Horizontal) => "splitPaneHorizontal",
            Action::SplitPane(SplitAxis::Vertical) => "splitPaneVertical",
            Action::ClosePane => "closePane",
            Action::FocusPane(Direction::Left) => "focusPaneLeft",
            Action::FocusPane(Direction::Right) => "focusPaneRight",
            Action::FocusPane(Direction::Up) => "focusPaneUp",
            Action::FocusPane(Direction::Down) => "focusPaneDown",
            Action::TogglePaneZoom => "togglePaneZoom",
            Action::SwapPane(Direction::Left) => "swapPaneLeft",
            Action::SwapPane(Direction::Right) => "swapPaneRight",
            Action::SwapPane(Direction::Up) => "swapPaneUp",
            Action::SwapPane(Direction::Down) => "swapPaneDown",
            Action::MovePaneToNewTab => "movePaneToNewTab",
            Action::ResizePane(Direction::Left) => "resizePaneLeft",
            Action::ResizePane(Direction::Right) => "resizePaneRight",
            Action::ResizePane(Direction::Up) => "resizePaneUp",
            Action::ResizePane(Direction::Down) => "resizePaneDown",
            Action::CommandPalette => "commandPalette",
            Action::Settings => "settings",
            Action::Search => "search",
            Action::ScrollUp => "scrollUp",
            Action::ScrollDown => "scrollDown",
            Action::ScrollPageUp => "scrollPageUp",
            Action::ScrollPageDown => "scrollPageDown",
            Action::ScrollBottom => "scrollBottom",
            Action::PromptUp => "promptUp",
            Action::PromptDown => "promptDown",
            Action::PromptFirst => "promptFirst",
            Action::PromptLast => "promptLast",
            Action::Copy => "copy",
            Action::Paste => "paste",
            Action::ReloadConfig => "reloadConfig",
            Action::MarkMode => "markMode",
            Action::Quit => "quit",
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Action::NewTab => "新建标签页",
            Action::NewTabWithProfile => "新建标签页（选择 profile）",
            Action::CloseTab => "关闭标签页",
            Action::NextTab => "下一个标签页",
            Action::PrevTab => "上一个标签页",
            Action::SelectTab(0) => "切换到标签页 1",
            Action::SelectTab(1) => "切换到标签页 2",
            Action::SelectTab(2) => "切换到标签页 3",
            Action::SelectTab(3) => "切换到标签页 4",
            Action::SelectTab(4) => "切换到标签页 5",
            Action::SelectTab(5) => "切换到标签页 6",
            Action::SelectTab(6) => "切换到标签页 7",
            Action::SelectTab(_) => "切换到标签页 8",
            Action::LastTab => "切换到最后一个标签页",
            Action::RenameTab => "重命名标签页",
            Action::SplitPane(SplitAxis::Horizontal) => "左右分屏",
            Action::SplitPane(SplitAxis::Vertical) => "上下分屏",
            Action::ClosePane => "关闭窗格",
            Action::FocusPane(Direction::Left) => "焦点移到左窗格",
            Action::FocusPane(Direction::Right) => "焦点移到右窗格",
            Action::FocusPane(Direction::Up) => "焦点移到上窗格",
            Action::FocusPane(Direction::Down) => "焦点移到下窗格",
            Action::TogglePaneZoom => "放大/还原聚焦窗格",
            Action::SwapPane(Direction::Left) => "与左侧窗格交换",
            Action::SwapPane(Direction::Right) => "与右侧窗格交换",
            Action::SwapPane(Direction::Up) => "与上方窗格交换",
            Action::SwapPane(Direction::Down) => "与下方窗格交换",
            Action::MovePaneToNewTab => "把窗格移到新标签页",
            Action::ResizePane(Direction::Left) => "向左调整分隔线",
            Action::ResizePane(Direction::Right) => "向右调整分隔线",
            Action::ResizePane(Direction::Up) => "向上调整分隔线",
            Action::ResizePane(Direction::Down) => "向下调整分隔线",
            Action::CommandPalette => "命令面板",
            Action::Settings => "设置",
            Action::Search => "搜索回看缓冲",
            Action::MarkMode => "标记模式",
            Action::ScrollUp => "向上滚动一行",
            Action::ScrollDown => "向下滚动一行",
            Action::ScrollPageUp => "向上翻一页",
            Action::ScrollPageDown => "向下翻一页",
            Action::ScrollBottom => "回到最新输出",
            Action::PromptUp => "跳到上一条命令",
            Action::PromptDown => "跳到下一条命令",
            Action::PromptFirst => "跳到最早一条命令",
            Action::PromptLast => "跳到最新一条命令",
            Action::Copy => "复制选区",
            Action::Paste => "粘贴剪贴板",
            Action::ReloadConfig => "重载配置",
            Action::Quit => "退出 scterm",
        }
    }

    pub fn from_id(id: &str) -> Option<Action> {
        let action = match id {
            "newTab" => Action::NewTab,
            "newTabWithProfile" => Action::NewTabWithProfile,
            "closeTab" => Action::CloseTab,
            "nextTab" => Action::NextTab,
            "prevTab" => Action::PrevTab,
            "selectTab1" => Action::SelectTab(0),
            "selectTab2" => Action::SelectTab(1),
            "selectTab3" => Action::SelectTab(2),
            "selectTab4" => Action::SelectTab(3),
            "selectTab5" => Action::SelectTab(4),
            "selectTab6" => Action::SelectTab(5),
            "selectTab7" => Action::SelectTab(6),
            "selectTab8" => Action::SelectTab(7),
            "lastTab" => Action::LastTab,
            "renameTab" => Action::RenameTab,
            "splitPaneHorizontal" => Action::SplitPane(SplitAxis::Horizontal),
            "splitPaneVertical" => Action::SplitPane(SplitAxis::Vertical),
            "closePane" => Action::ClosePane,
            "focusPaneLeft" => Action::FocusPane(Direction::Left),
            "focusPaneRight" => Action::FocusPane(Direction::Right),
            "focusPaneUp" => Action::FocusPane(Direction::Up),
            "focusPaneDown" => Action::FocusPane(Direction::Down),
            "togglePaneZoom" => Action::TogglePaneZoom,
            "swapPaneLeft" => Action::SwapPane(Direction::Left),
            "swapPaneRight" => Action::SwapPane(Direction::Right),
            "swapPaneUp" => Action::SwapPane(Direction::Up),
            "swapPaneDown" => Action::SwapPane(Direction::Down),
            "movePaneToNewTab" => Action::MovePaneToNewTab,
            "resizePaneLeft" => Action::ResizePane(Direction::Left),
            "resizePaneRight" => Action::ResizePane(Direction::Right),
            "resizePaneUp" => Action::ResizePane(Direction::Up),
            "resizePaneDown" => Action::ResizePane(Direction::Down),
            "commandPalette" => Action::CommandPalette,
            "settings" => Action::Settings,
            "search" => Action::Search,
            "markMode" => Action::MarkMode,
            "scrollUp" => Action::ScrollUp,
            "scrollDown" => Action::ScrollDown,
            "scrollPageUp" => Action::ScrollPageUp,
            "scrollPageDown" => Action::ScrollPageDown,
            "scrollBottom" => Action::ScrollBottom,
            "promptUp" => Action::PromptUp,
            "promptDown" => Action::PromptDown,
            "promptFirst" => Action::PromptFirst,
            "promptLast" => Action::PromptLast,
            "copy" => Action::Copy,
            "paste" => Action::Paste,
            "reloadConfig" => Action::ReloadConfig,
            "quit" => Action::Quit,
            _ => return None,
        };
        Some(action)
    }

    /// 命令面板中展示的全部动作。
    pub fn all() -> Vec<Action> {
        vec![
            Action::NewTab,
            Action::NewTabWithProfile,
            Action::CloseTab,
            Action::NextTab,
            Action::PrevTab,
            Action::SelectTab(0),
            Action::SelectTab(1),
            Action::SelectTab(2),
            Action::SelectTab(3),
            Action::SelectTab(4),
            Action::SelectTab(5),
            Action::SelectTab(6),
            Action::SelectTab(7),
            Action::LastTab,
            Action::RenameTab,
            Action::SplitPane(SplitAxis::Horizontal),
            Action::SplitPane(SplitAxis::Vertical),
            Action::ClosePane,
            Action::FocusPane(Direction::Left),
            Action::FocusPane(Direction::Right),
            Action::FocusPane(Direction::Up),
            Action::FocusPane(Direction::Down),
            Action::TogglePaneZoom,
            Action::SwapPane(Direction::Left),
            Action::SwapPane(Direction::Right),
            Action::SwapPane(Direction::Up),
            Action::SwapPane(Direction::Down),
            Action::MovePaneToNewTab,
            Action::ResizePane(Direction::Left),
            Action::ResizePane(Direction::Right),
            Action::ResizePane(Direction::Up),
            Action::ResizePane(Direction::Down),
            Action::CommandPalette,
            Action::Settings,
            Action::Search,
            Action::MarkMode,
            Action::ScrollUp,
            Action::ScrollDown,
            Action::ScrollPageUp,
            Action::ScrollPageDown,
            Action::ScrollBottom,
            Action::PromptUp,
            Action::PromptDown,
            Action::PromptFirst,
            Action::PromptLast,
            Action::Copy,
            Action::Paste,
            Action::ReloadConfig,
            Action::Quit,
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Key {
    Char(char),
    Tab,
    Enter,
    Escape,
    Backspace,
    Space,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    F(u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chord {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub key: Key,
}

impl Chord {
    /// 解析 `ctrl+shift+t`、`alt+shift+plus`、`ctrl+tab` 这类写法。
    pub fn parse(text: &str) -> Option<Chord> {
        let parts: Vec<&str> = text.split('+').filter(|p| !p.is_empty()).collect();
        if parts.is_empty() {
            return None;
        }
        // `alt+shift+plus` 里的 plus 是键名；单字符 `+` 无法通过 split 表达
        let (mods, key_text) = parts.split_at(parts.len() - 1);
        let mut ctrl = false;
        let mut alt = false;
        let mut shift = false;
        for m in mods {
            match m.trim().to_ascii_lowercase().as_str() {
                "ctrl" | "control" => ctrl = true,
                "alt" => alt = true,
                "shift" => shift = true,
                _ => return None,
            }
        }
        let key = parse_key_name(key_text[0].trim())?;
        Some(Chord {
            ctrl,
            alt,
            shift,
            key,
        })
    }

    pub fn label(&self) -> String {
        let mut parts = Vec::new();
        if self.ctrl {
            parts.push("Ctrl".to_string());
        }
        if self.alt {
            parts.push("Alt".to_string());
        }
        if self.shift {
            parts.push("Shift".to_string());
        }
        parts.push(key_label(self.key));
        parts.join("+")
    }
}

pub fn parse_key_name(text: &str) -> Option<Key> {
    let lower = text.to_ascii_lowercase();
    let key = match lower.as_str() {
        "tab" => Key::Tab,
        "enter" | "return" => Key::Enter,
        "escape" | "esc" => Key::Escape,
        "backspace" => Key::Backspace,
        "space" => Key::Space,
        "left" | "arrowleft" => Key::Left,
        "right" | "arrowright" => Key::Right,
        "up" | "arrowup" => Key::Up,
        "down" | "arrowdown" => Key::Down,
        "home" => Key::Home,
        "end" => Key::End,
        "pageup" | "prior" => Key::PageUp,
        "pagedown" | "next" => Key::PageDown,
        "insert" => Key::Insert,
        "delete" | "del" => Key::Delete,
        "plus" => Key::Char('+'),
        "minus" => Key::Char('-'),
        _ => {
            if let Some(rest) = lower.strip_prefix('f') {
                if let Ok(n) = rest.parse::<u8>() {
                    if (1..=24).contains(&n) {
                        return Some(Key::F(n));
                    }
                }
            }
            let mut chars = text.chars();
            let ch = chars.next()?;
            if chars.next().is_some() {
                return None;
            }
            Key::Char(ch.to_ascii_lowercase())
        }
    };
    Some(key)
}

fn key_label(key: Key) -> String {
    match key {
        Key::Char(c) => c.to_string(),
        Key::Tab => "Tab".into(),
        Key::Enter => "Enter".into(),
        Key::Escape => "Esc".into(),
        Key::Backspace => "Backspace".into(),
        Key::Space => "Space".into(),
        Key::Up => "↑".into(),
        Key::Down => "↓".into(),
        Key::Left => "←".into(),
        Key::Right => "→".into(),
        Key::Home => "Home".into(),
        Key::End => "End".into(),
        Key::PageUp => "PgUp".into(),
        Key::PageDown => "PgDn".into(),
        Key::Insert => "Ins".into(),
        Key::Delete => "Del".into(),
        Key::F(n) => format!("F{n}"),
    }
}

pub struct Registry {
    bindings: Vec<(Chord, Action)>,
}

impl Registry {
    /// 默认键位：新建标签 Ctrl+B、设置 Ctrl+S，其余对齐 Windows Terminal。
    pub fn defaults() -> Registry {
        let defaults: &[(&str, Action)] = &[
            ("ctrl+b", Action::NewTab),
            ("ctrl+shift+b", Action::NewTabWithProfile),
            ("ctrl+shift+w", Action::CloseTab),
            ("ctrl+tab", Action::NextTab),
            ("ctrl+shift+tab", Action::PrevTab),
            ("ctrl+1", Action::SelectTab(0)),
            ("ctrl+2", Action::SelectTab(1)),
            ("ctrl+3", Action::SelectTab(2)),
            ("ctrl+4", Action::SelectTab(3)),
            ("ctrl+5", Action::SelectTab(4)),
            ("ctrl+6", Action::SelectTab(5)),
            ("ctrl+7", Action::SelectTab(6)),
            ("ctrl+8", Action::SelectTab(7)),
            ("ctrl+9", Action::LastTab),
            ("ctrl+shift+r", Action::RenameTab),
            (
                "alt+shift+-",
                Action::SplitPane(SplitAxis::Horizontal),
            ),
            (
                "alt+shift+plus",
                Action::SplitPane(SplitAxis::Vertical),
            ),
            ("ctrl+shift+p", Action::CommandPalette),
            ("ctrl+s", Action::Settings),
            ("ctrl+shift+f", Action::Search),
            ("ctrl+shift+m", Action::MarkMode),
            ("alt+arrowleft", Action::FocusPane(Direction::Left)),
            ("alt+arrowright", Action::FocusPane(Direction::Right)),
            ("alt+arrowup", Action::FocusPane(Direction::Up)),
            ("alt+arrowdown", Action::FocusPane(Direction::Down)),
            ("ctrl+shift+z", Action::TogglePaneZoom),
            ("ctrl+shift+alt+left", Action::SwapPane(Direction::Left)),
            ("ctrl+shift+alt+right", Action::SwapPane(Direction::Right)),
            ("ctrl+shift+alt+up", Action::SwapPane(Direction::Up)),
            ("ctrl+shift+alt+down", Action::SwapPane(Direction::Down)),
            ("ctrl+shift+alt+t", Action::MovePaneToNewTab),
            ("alt+shift+left", Action::ResizePane(Direction::Left)),
            ("alt+shift+right", Action::ResizePane(Direction::Right)),
            ("alt+shift+up", Action::ResizePane(Direction::Up)),
            ("alt+shift+down", Action::ResizePane(Direction::Down)),
            ("ctrl+shift+up", Action::PromptUp),
            ("ctrl+shift+down", Action::PromptDown),
            ("ctrl+shift+home", Action::PromptFirst),
            ("ctrl+alt+up", Action::ScrollUp),
            ("ctrl+alt+down", Action::ScrollDown),
            ("shift+pageup", Action::ScrollPageUp),
            ("shift+pagedown", Action::ScrollPageDown),
            ("ctrl+shift+end", Action::ScrollBottom),
            ("ctrl+shift+c", Action::Copy),
            ("ctrl+shift+v", Action::Paste),
        ];
        let bindings = defaults
            .iter()
            .filter_map(|(keys, action)| Chord::parse(keys).map(|c| (c, *action)))
            .collect();
        Registry { bindings }
    }

    /// 用配置里的 `[[actions]]` 覆盖/追加绑定。
    pub fn from_config(custom: &[ActionBinding]) -> (Registry, Vec<String>) {
        let mut registry = Registry::defaults();
        let mut warnings = Vec::new();
        for binding in custom {
            let Some(action) = Action::from_id(&binding.command) else {
                warnings.push(format!(
                    "actions 中未知的 command「{}」，已忽略",
                    binding.command
                ));
                continue;
            };
            if binding.keys.trim().is_empty() {
                continue;
            }
            let Some(chord) = Chord::parse(&binding.keys) else {
                warnings.push(format!(
                    "actions 中无法解析的按键「{}」",
                    binding.keys
                ));
                continue;
            };
            if let Some((_, existing)) = registry.bindings.iter().find(|(c, _)| *c == chord) {
                if *existing == action {
                    // 与默认键位完全一致：不告警、不重复绑定
                    continue;
                }
                warnings.push(format!("快捷键 {} 重复绑定，后者生效", binding.keys));
            }
            // 与 Windows Terminal 一致：给同一个动作换键位时，旧绑定一并移除
            registry
                .bindings
                .retain(|(c, a)| *c != chord && *a != action);
            registry.bindings.push((chord, action));
        }
        (registry, warnings)
    }

    pub fn resolve(&self, chord: &Chord) -> Option<Action> {
        self.bindings
            .iter()
            .find(|(c, _)| c == chord)
            .map(|(_, a)| *a)
    }

    pub fn keys_for(&self, action: Action) -> Option<String> {
        self.bindings
            .iter()
            .find(|(_, a)| *a == action)
            .map(|(c, _)| c.label())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chord_parsing() {
        let chord = Chord::parse("ctrl+shift+t").unwrap();
        assert!(chord.ctrl && chord.shift && !chord.alt);
        assert_eq!(chord.key, Key::Char('t'));

        let chord = Chord::parse("alt+shift+plus").unwrap();
        assert_eq!(chord.key, Key::Char('+'));

        let chord = Chord::parse("ctrl+shift+tab").unwrap();
        assert_eq!(chord.key, Key::Tab);

        assert!(Chord::parse("hyper+x").is_none());
    }

    #[test]
    fn default_bindings_new_tab_and_settings() {
        let registry = Registry::defaults();
        let new_tab = Chord::parse("ctrl+b").unwrap();
        assert_eq!(registry.resolve(&new_tab), Some(Action::NewTab));
        let settings = Chord::parse("ctrl+s").unwrap();
        assert_eq!(registry.resolve(&settings), Some(Action::Settings));
        let first_tab = Chord::parse("ctrl+1").unwrap();
        assert_eq!(registry.resolve(&first_tab), Some(Action::SelectTab(0)));
        let last_tab = Chord::parse("ctrl+9").unwrap();
        assert_eq!(registry.resolve(&last_tab), Some(Action::LastTab));
        let rename = Chord::parse("ctrl+shift+r").unwrap();
        assert_eq!(registry.resolve(&rename), Some(Action::RenameTab));
        let split = Chord::parse("alt+shift+-").unwrap();
        assert_eq!(
            registry.resolve(&split),
            Some(Action::SplitPane(SplitAxis::Horizontal))
        );
        assert_eq!(
            registry.keys_for(Action::CommandPalette).as_deref(),
            Some("Ctrl+Shift+p")
        );
    }

    #[test]
    fn config_overrides_binding() {
        let (registry, warnings) = Registry::from_config(&[ActionBinding {
            command: "splitPaneHorizontal".into(),
            keys: "alt+shift+d".into(),
        }]);
        assert!(warnings.is_empty(), "{warnings:?}");
        let chord = Chord::parse("alt+shift+d").unwrap();
        assert_eq!(
            registry.resolve(&chord),
            Some(Action::SplitPane(SplitAxis::Horizontal))
        );
        // 旧键位已被移除
        let old = Chord::parse("alt+shift+-").unwrap();
        assert_eq!(registry.resolve(&old), None);
    }

    #[test]
    fn identical_override_is_silent() {
        let (registry, warnings) = Registry::from_config(&[ActionBinding {
            command: "splitPaneHorizontal".into(),
            keys: "alt+shift+-".into(),
        }]);
        assert!(warnings.is_empty(), "与默认一致不应告警：{warnings:?}");
        let chord = Chord::parse("alt+shift+-").unwrap();
        assert_eq!(
            registry.resolve(&chord),
            Some(Action::SplitPane(SplitAxis::Horizontal))
        );
    }

    #[test]
    fn unknown_action_command_warns() {
        let (_, warnings) = Registry::from_config(&[ActionBinding {
            command: "noSuchAction".into(),
            keys: "ctrl+x".into(),
        }]);
        assert_eq!(warnings.len(), 1);
    }
}

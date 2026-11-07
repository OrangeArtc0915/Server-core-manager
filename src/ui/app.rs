//! 应用状态：标签页、窗格树、命令面板、搜索、合成绘制。

use std::collections::HashMap;
use std::sync::mpsc::Sender;
use std::time::Instant;

use crate::action::{Action, Direction, Registry, SplitAxis};
use crate::config::{ColorScheme, Config, ConfigEdit, GradientOverride, Profile, TrueColorMode};
use crate::emulation::screen::{
    char_width, Attrs, Cell, Color, Screen, ATTR_REVERSE, ATTR_BOLD, ATTR_UNDERLINE,
    ATTR_WIDE_TAIL,
};
use crate::emulation::Parser;
use crate::input::{
    encode_key, encode_win32_key, KeyEvent, MouseEvent, FROM_LEFT_1ST_BUTTON_PRESSED,
    FROM_LEFT_2ND_BUTTON_PRESSED, RIGHTMOST_BUTTON_PRESSED,
};
use crate::proto::{self, msg, FrameType};
use crate::render::{tint, Gradient, Renderer};
use crate::ui::layout::{compute, neighbor, Axis, LayoutNode, Node, Rect};
use crate::ui::palette::{self, PaletteState};
use crate::ui::search::{self, SearchState};
use crate::ui::settings::{self, Row, SettingsState};

pub struct PaneState {
    pub profile: String,
    pub screen: Screen,
    parser: Parser,
    pub scheme: ColorScheme,
    pub scroll_offset: usize,
    pub exited: Option<i32>,
}

pub struct Tab {
    pub title: String,
    pub custom_title: bool,
    pub tree: Node,
    pub focus: u32,
    /// 该标签最近一条命令的退出码（来自 OSC 133;D），`None` 表示未知或正在执行。
    pub last_exit: Option<i32>,
    /// 后台标签收到过响铃，切过去后清除。
    pub bell: bool,
    /// 窗格放大：聚焦窗格独占内容区，其余窗格暂时隐藏。
    pub zoom: bool,
}

pub enum Overlay {
    Palette(PaletteState),
    Search(SearchState),
    Rename { text: String },
    Settings(SettingsState),
    /// 危险操作前的确认框（关闭标签、多行粘贴）。
    Confirm {
        prompt: String,
        action: ConfirmAction,
    },
    /// 新建标签页前选择 profile。
    ProfilePicker { selected: usize },
    /// 输入背景图片路径；保存设置面板状态，确认/取消后回到设置。
    BackgroundPath {
        text: String,
        state: SettingsState,
    },
}

#[derive(Debug, Clone)]
pub enum ConfirmAction {
    CloseTab(usize),
    Paste { text: String, bracketed: bool },
}

/// 背景图片的状态：解码结果 + 按当前网格采样出来的单元格颜色。
struct BackgroundState {
    /// 配置里的原始写法（相对路径或绝对路径），用来判断是否需要重新加载。
    name: String,
    image: Option<crate::platform::gdiplus::Image>,
    sampled: Vec<Color>,
    cols: usize,
    rows: usize,
    opacity: u8,
}

/// 正在拖动的分隔线：路径用于定位窗格树里的 Split 节点。
#[derive(Debug, Clone)]
struct DragTarget {
    path: Vec<bool>,
    axis: Axis,
    rect: Rect,
}

/// 文本选区：坐标是 (列, 绝对行号)，绝对行号把回看缓冲和屏幕连续编号。
#[derive(Debug, Clone, Copy)]
pub struct Selection {
    pub pane: u32,
    pub anchor: (usize, usize),
    pub head: (usize, usize),
    pub dragging: bool,
    /// 矩形（块）选择：Alt+拖动或块模式。
    pub block: bool,
}

impl Selection {
    fn ordered(&self) -> ((usize, usize), (usize, usize)) {
        let key = |p: (usize, usize)| (p.1, p.0);
        if key(self.anchor) <= key(self.head) {
            (self.anchor, self.head)
        } else {
            (self.head, self.anchor)
        }
    }

    /// 矩形范围：(左列, 首行, 右列, 末行)。
    fn block_bounds(&self) -> (usize, usize, usize, usize) {
        (
            self.anchor.0.min(self.head.0),
            self.anchor.1.min(self.head.1),
            self.anchor.0.max(self.head.0),
            self.anchor.1.max(self.head.1),
        )
    }
}

pub struct App {
    pub config: Config,
    pub registry: Registry,
    pub tabs: Vec<Tab>,
    pub active: usize,
    pub panes: HashMap<u32, PaneState>,
    pub overlay: Option<Overlay>,
    pub cols: usize,
    pub rows: usize,
    pub quit: bool,
    pub status: Option<(String, Instant)>,
    renderer: Renderer,
    tx: Sender<Vec<u8>>,
    next_pane_id: u32,
    pub warnings: Vec<String>,
    prev_title: String,
    config_path: std::path::PathBuf,
    config_mtime: Option<std::time::SystemTime>,
    last_config_check: Instant,
    drag: Option<DragTarget>,
    /// 最近按下的鼠标键（0 左、1 中、2 右），释放事件需要它。
    mouse_button: u8,
    /// 当前文本选区。
    selection: Option<Selection>,
    /// 键盘标记模式：方向键移动选区头，Enter 复制，Esc 退出。
    mark_mode: bool,
    /// 滚轮增量累计值（触控板/部分鼠标的单次增量小于 120）。
    wheel_accum: i32,
    /// 最近一次鼠标位置，用于滚动条悬停显示。
    hover: Option<(usize, usize)>,
    /// 正在拖动的滚动条（窗格 id 与所在矩形）。
    scrollbar_drag: Option<(u32, Rect)>,
    /// 标签栏按下时的（标签下标, 列号），用于拖动重排。
    tab_press: Option<(usize, usize)>,
    /// 背景图片缓存（路径/尺寸/不透明度变了才重新采样）。
    background: Option<BackgroundState>,
    /// 最近一次应用到控制台的字体（profile 覆盖生效后去重）。
    last_font: Option<(Option<String>, Option<u16>)>,
    /// 是否跟随 profile 切换应用字体；仅真实控制台入口启用（单测不碰宿主字体）。
    profile_font_enabled: bool,
}

impl App {
    /// 新建客户端状态，并打开一个默认标签页。
    pub fn new(config: Config, cols: usize, rows: usize, tx: Sender<Vec<u8>>) -> App {
        let mut app = App::new_empty(config, cols, rows, tx);
        app.new_tab();
        app
    }

    /// 新建客户端状态但不打开标签页；供布局启动 / 会话恢复先按需建标签页。
    pub fn new_empty(config: Config, cols: usize, rows: usize, tx: Sender<Vec<u8>>) -> App {
        let (registry, mut warnings) = Registry::from_config(&config.action_bindings);
        warnings.extend(config.warnings.clone());
        let mut renderer = Renderer::new();
        renderer.set_truecolor(true);
        App {
            config,
            registry,
            tabs: Vec::new(),
            active: 0,
            panes: HashMap::new(),
            overlay: None,
            cols,
            rows,
            quit: false,
            status: warnings.first().map(|w| (w.clone(), Instant::now())),
            renderer,
            tx,
            next_pane_id: 1,
            warnings,
            prev_title: String::new(),
            config_path: crate::config::Config::path(),
            config_mtime: crate::config::Config::path()
                .metadata()
                .and_then(|m| m.modified())
                .ok(),
            last_config_check: Instant::now(),
            drag: None,
            mouse_button: 0,
            selection: None,
            mark_mode: false,
            wheel_accum: 0,
            hover: None,
            scrollbar_drag: None,
            tab_press: None,
            background: None,
            last_font: None,
            profile_font_enabled: false,
        }
    }

    // ---------- 标签页 ----------

    pub fn new_tab(&mut self) {
        let profile_name = self.config.default_profile.clone();
        self.new_tab_with_profile(&profile_name);
    }

    /// 用指定 profile 新建标签页（标签标题跟随 profile 名）。
    pub fn new_tab_with_profile(&mut self, profile_name: &str) {
        let profile_name = if self.config.profile(profile_name).is_some() {
            profile_name.to_string()
        } else {
            self.config.default_profile.clone()
        };
        let content = self.content_rect();
        let id = self.spawn_pane(&profile_name, content.w as u16, content.h as u16);
        self.tabs.push(Tab {
            title: profile_name.clone(),
            custom_title: false,
            tree: Node::leaf(id),
            focus: id,
            last_exit: None,
            bell: false,
            zoom: false,
        });
        self.active = self.tabs.len() - 1;
        self.sync_layout();
        self.apply_active_profile_font();
    }

    /// 按布局表达式新建标签页（`--layout` 与会话恢复共用）。
    pub fn new_tab_with_layout(&mut self, layout: &LayoutNode) {
        let content = self.content_rect();
        let tree = self.build_layout(layout, content.w as u16, content.h as u16);
        let leaves = tree.leaves();
        let focus = leaves.first().copied().unwrap_or(1);
        let title = self
            .panes
            .get(&focus)
            .map(|pane| pane.profile.clone())
            .unwrap_or_else(|| self.config.default_profile.clone());
        self.tabs.push(Tab {
            title,
            custom_title: false,
            tree,
            focus,
            last_exit: None,
            bell: false,
            zoom: false,
        });
        self.active = self.tabs.len() - 1;
        self.sync_layout();
        self.apply_active_profile_font();
    }

    /// 按布局表达式递归创建窗格；未知 profile 回退到默认 profile。
    fn build_layout(&mut self, layout: &LayoutNode, cols: u16, rows: u16) -> Node {
        match layout {
            LayoutNode::Pane(name) => {
                let profile = if self.config.profile(name).is_some() {
                    name.clone()
                } else {
                    self.config.default_profile.clone()
                };
                Node::leaf(self.spawn_pane(&profile, cols, rows))
            }
            LayoutNode::Split {
                axis,
                ratio,
                first,
                second,
            } => {
                let first = self.build_layout(first, cols, rows);
                let second = self.build_layout(second, cols, rows);
                Node::Split {
                    axis: *axis,
                    ratio: *ratio,
                    first: Box::new(first),
                    second: Box::new(second),
                }
            }
        }
    }

    /// 从会话快照恢复标签页；返回恢复出的标签页数量。
    ///
    /// 坏布局或已删除的 profile 不会阻断启动：布局解析失败就跳过该标签页，
    /// profile 缺失由 `build_layout` 回退到默认 profile。
    pub fn restore_session(&mut self, session: &crate::session::Session) -> usize {
        for saved in &session.tabs {
            let Ok(layout) = LayoutNode::parse(&saved.layout) else {
                crate::platform::logging::warn(&format!(
                    "会话中的布局「{}」无法解析，已跳过",
                    saved.layout
                ));
                continue;
            };
            let content = self.content_rect();
            let tree = self.build_layout(&layout, content.w as u16, content.h as u16);
            let leaves = tree.leaves();
            let Some(&first) = leaves.first() else {
                continue;
            };
            let focus = leaves.get(saved.focus).copied().unwrap_or(first);
            let title = if saved.custom_title {
                saved.title.clone()
            } else {
                self.panes
                    .get(&first)
                    .map(|pane| pane.profile.clone())
                    .unwrap_or_else(|| self.config.default_profile.clone())
            };
            self.tabs.push(Tab {
                title,
                custom_title: saved.custom_title,
                tree,
                focus,
                last_exit: None,
                bell: false,
                zoom: false,
            });
        }
        if !self.tabs.is_empty() {
            self.active = session.active.min(self.tabs.len() - 1);
            self.sync_layout();
            self.apply_active_profile_font();
            self.status = Some((
                format!("已恢复 {} 个标签页", self.tabs.len()),
                Instant::now(),
            ));
        }
        self.tabs.len()
    }

    pub fn close_tab(&mut self) {
        self.close_tab_at(self.active);
    }

    /// 关闭指定标签页（中键点击标签、点 × 时使用）。
    ///
    /// `behavior.confirm_close` 打开时先弹确认框，避免误关正在跑任务的标签。
    pub fn close_tab_at(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        if self.config.behavior.confirm_close {
            let title = self.tabs[index].title.clone();
            self.overlay = Some(Overlay::Confirm {
                prompt: format!("关闭标签「{title}」？其中正在运行的进程会被终止"),
                action: ConfirmAction::CloseTab(index),
            });
            return;
        }
        self.close_tab_now(index);
    }

    fn close_tab_now(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        let tab = self.tabs.remove(index);
        for id in tab.tree.leaves() {
            self.close_pane_state(id);
        }
        if index < self.active {
            self.active -= 1;
        }
        if self.tabs.is_empty() {
            self.quit = true;
            self.active = 0;
            return;
        }
        if self.active >= self.tabs.len() {
            self.active = self.tabs.len() - 1;
        }
        self.sync_layout();
        self.apply_active_profile_font();
    }

    pub fn next_tab(&mut self) {
        if !self.tabs.is_empty() {
            self.activate_tab((self.active + 1) % self.tabs.len());
        }
    }

    pub fn prev_tab(&mut self) {
        if !self.tabs.is_empty() {
            self.activate_tab((self.active + self.tabs.len() - 1) % self.tabs.len());
        }
    }

    /// 切换标签：清掉该标签的响铃标记与选区，并同步窗格尺寸。
    fn activate_tab(&mut self, index: usize) {
        if let Some(tab) = self.tabs.get_mut(index) {
            tab.bell = false;
        }
        self.active = index;
        self.selection = None;
        self.mark_mode = false;
        self.sync_layout();
        self.apply_active_profile_font();
    }

    pub fn active_tab(&self) -> Option<&Tab> {
        self.tabs.get(self.active)
    }

    pub fn focused_pane(&self) -> Option<&PaneState> {
        let tab = self.active_tab()?;
        self.panes.get(&tab.focus)
    }

    pub fn focused_pane_id(&self) -> u32 {
        self.active_tab().map(|t| t.focus).unwrap_or(0)
    }

    fn focused_pane_mut(&mut self) -> Option<&mut PaneState> {
        let focus = self.active_tab()?.focus;
        self.panes.get_mut(&focus)
    }

    // ---------- profile 外观覆盖 ----------

    /// 当前聚焦窗格所属的 profile 名。
    fn current_profile_name(&self) -> String {
        self.focused_pane()
            .map(|pane| pane.profile.clone())
            .unwrap_or_else(|| self.config.default_profile.clone())
    }

    fn current_profile(&self) -> Option<&Profile> {
        let name = self.current_profile_name();
        self.config.profile(&name)
    }

    fn current_profile_mut(&mut self) -> Option<&mut Profile> {
        let name = self.current_profile_name();
        self.config
            .profiles
            .iter_mut()
            .find(|profile| profile.name == name)
    }

    /// profile 未设置的字体键回退到全局 `[render]`（两项独立回退）。
    fn effective_font(&self) -> (Option<String>, Option<u16>) {
        let profile = self.current_profile();
        (
            profile
                .and_then(|profile| profile.font_face.clone())
                .or_else(|| self.config.render.font_face.clone()),
            profile
                .and_then(|profile| profile.font_size)
                .or(self.config.render.font_size),
        )
    }

    /// 真实控制台入口启用：标签切换时按 profile 字体应用到整个控制台。
    pub fn enable_profile_font(&mut self) {
        self.profile_font_enabled = true;
        self.last_font = None;
        self.apply_active_profile_font();
    }

    /// 按当前标签的 profile 应用字体；conhost 只能有一个控制台字体。
    fn apply_active_profile_font(&mut self) {
        if !self.profile_font_enabled {
            return;
        }
        let (face, size) = self.effective_font();
        if self.last_font.as_ref() == Some(&(face.clone(), size)) {
            return;
        }
        let label = face.clone().unwrap_or_else(|| "默认".to_string());
        match crate::platform::console::apply_font(face.as_deref(), size) {
            Ok(()) => {
                self.last_font = Some((face, size));
                let suffix = size.map(|size| format!(" {size}px")).unwrap_or_default();
                self.set_status(format!("字体：{label}{suffix}"));
            }
            Err(e) => self.set_status(format!("设置字体失败：{e}")),
        }
    }


    // ---------- 窗格 ----------

    pub fn split_focused(&mut self, axis: SplitAxis) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        let focus = tab.focus;
        let profile = self
            .panes
            .get(&focus)
            .map(|p| p.profile.clone())
            .unwrap_or_else(|| self.config.default_profile.clone());
        let id = self.next_pane_id;
        self.next_pane_id += 1;

        // 先占位创建（尺寸在 sync_layout 里校正）
        let content = self.content_rect();
        self.spawn_pane_with_id(&profile, id, (content.w / 2) as u16, content.h as u16);
        let axis = match axis {
            SplitAxis::Horizontal => Axis::Horizontal,
            SplitAxis::Vertical => Axis::Vertical,
        };
        // 放大状态下先还原，否则新窗格会被藏在聚焦窗格后面。
        self.tabs[self.active].zoom = false;
        let tab = &mut self.tabs[self.active];
        tab.tree.split_at(focus, axis, id, 50);
        tab.focus = id;
        self.sync_layout();
    }

    pub fn close_focused_pane(&mut self) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        let focus = tab.focus;
        if tab.tree.leaves().len() <= 1 {
            self.close_tab();
            return;
        }
        let tab = &mut self.tabs[self.active];
        tab.tree.remove(focus);
        let next_focus = tab.tree.first_leaf();
        tab.focus = next_focus;
        tab.zoom = false;
        self.close_pane_state(focus);
        self.sync_layout();
    }

    pub fn focus_direction(&mut self, dir: Direction) {
        if self.tabs.get(self.active).map(|t| t.zoom).unwrap_or(false) {
            return;
        }
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        let (panes, _) = compute(&tab.tree, self.content_rect());
        if let Some(next) = neighbor(&panes, tab.focus, dir) {
            self.tabs[self.active].focus = next;
        }
    }

    /// 放大/还原聚焦窗格：放大时其余窗格被隐藏，键盘焦点不会移走。
    pub fn toggle_pane_zoom(&mut self) {
        let Some(tab) = self.tabs.get_mut(self.active) else {
            return;
        };
        if tab.tree.leaves().len() <= 1 {
            return;
        }
        tab.zoom = !tab.zoom;
        if tab.zoom {
            self.selection = None;
        }
        self.sync_layout();
    }

    /// 与指定方向的相邻窗格交换位置，焦点跟随被交换的窗格。
    pub fn swap_focused_pane(&mut self, dir: Direction) {
        if self.tabs.get(self.active).map(|t| t.zoom).unwrap_or(false) {
            return;
        }
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        let focus = tab.focus;
        let (panes, _) = compute(&tab.tree, self.content_rect());
        let Some(other) = neighbor(&panes, focus, dir) else {
            return;
        };
        let tab = &mut self.tabs[self.active];
        // 焦点始终跟着同一个窗格内容走（它被换到相邻位置）。
        tab.tree.swap_leaves(focus, other);
        self.sync_layout();
    }

    /// 把聚焦窗格移到新标签页；原标签只剩一个窗格时不处理。
    pub fn move_focused_pane_to_new_tab(&mut self) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        let focus = tab.focus;
        if tab.tree.leaves().len() <= 1 {
            return;
        }
        let profile = self
            .panes
            .get(&focus)
            .map(|p| p.profile.clone())
            .unwrap_or_else(|| self.config.default_profile.clone());
        let tab = &mut self.tabs[self.active];
        tab.tree.remove(focus);
        tab.focus = tab.tree.first_leaf();
        tab.zoom = false;
        self.tabs.push(Tab {
            title: profile,
            custom_title: false,
            tree: Node::leaf(focus),
            focus,
            last_exit: None,
            bell: false,
            zoom: false,
        });
        self.active = self.tabs.len() - 1;
        self.selection = None;
        self.sync_layout();
    }

    /// 按方向调整紧邻的分隔线（每次 5%）。
    pub fn resize_focused_pane(&mut self, dir: Direction) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        let focus = tab.focus;
        let (axis, delta) = match dir {
            Direction::Left => (Axis::Horizontal, -5),
            Direction::Right => (Axis::Horizontal, 5),
            Direction::Up => (Axis::Vertical, -5),
            Direction::Down => (Axis::Vertical, 5),
        };
        if self.tabs[self.active].tree.resize(focus, axis, delta) {
            self.sync_layout();
        }
    }

    pub fn scroll_focused(&mut self, delta: isize) {
        if let Some(pane) = self.focused_pane_mut() {
            let history = pane.screen.history_len();
            let offset = pane.scroll_offset as isize + delta;
            pane.scroll_offset = offset.clamp(0, history as isize) as usize;
        }
    }

    pub fn scroll_to_bottom(&mut self) {
        if let Some(pane) = self.focused_pane_mut() {
            pane.scroll_offset = 0;
        }
    }

    fn scroll_pane(&mut self, pane_id: u32, steps: isize) {
        let Some(pane) = self.panes.get_mut(&pane_id) else {
            return;
        };
        let max = pane.screen.history_len() as isize;
        pane.scroll_offset = (pane.scroll_offset as isize + steps).clamp(0, max) as usize;
    }

    /// 滚轮增量 → 行数：120 是一个标准刻度（3 行）。
    /// 触控板/部分鼠标的单次增量只有 30–60，必须累计，否则会被整除截断成 0。
    fn wheel_lines(&mut self, delta: i16) -> isize {
        self.wheel_accum += delta as i32;
        let lines = (self.wheel_accum as f32 / 120.0 * 3.0).round() as isize;
        if lines != 0 {
            self.wheel_accum -= ((lines as f32 / 3.0) * 120.0) as i32;
        }
        lines
    }

    /// 跳到上/下一条命令的提示符（依赖 shell 发送的 OSC 133;A 标记）。
    fn jump_prompt(&mut self, backward: bool) {
        let Some((panes, _)) = self.pane_layout() else {
            return;
        };
        let focus = self.tabs[self.active].focus;
        let Some((_, rect)) = panes.iter().find(|(id, _)| *id == focus).copied() else {
            return;
        };
        let visible = rect.h.max(1) as isize;
        let Some(pane) = self.panes.get_mut(&focus) else {
            return;
        };
        let total = (pane.screen.history_len() + pane.screen.rows) as isize;
        let top = (total - visible - pane.scroll_offset as isize).max(0);
        let marks = &pane.screen.prompt_marks;
        let target = if backward {
            marks
                .iter()
                .copied()
                .filter(|mark| (*mark as isize) < top)
                .max()
                .or_else(|| marks.front().copied())
        } else {
            marks
                .iter()
                .copied()
                .filter(|mark| (*mark as isize) > top)
                .min()
        };
        if let Some(mark) = target {
            let limit = pane.screen.history_len() as isize;
            pane.scroll_offset = (total - visible - mark as isize).clamp(0, limit) as usize;
        } else if !backward {
            pane.scroll_offset = 0;
        }
    }

    /// 跳到最早 / 最新一条命令的提示符（Ctrl+Shift+Home 之类）。
    fn jump_prompt_edge(&mut self, first: bool) {
        let Some((panes, _)) = self.pane_layout() else {
            return;
        };
        let focus = self.tabs[self.active].focus;
        let Some((_, rect)) = panes.iter().find(|(id, _)| *id == focus).copied() else {
            return;
        };
        let visible = rect.h.max(1) as isize;
        let Some(pane) = self.panes.get_mut(&focus) else {
            return;
        };
        let mark = if first {
            pane.screen.prompt_marks.front().copied()
        } else {
            pane.screen.prompt_marks.back().copied()
        };
        let Some(mark) = mark else {
            return;
        };
        let total = (pane.screen.history_len() + pane.screen.rows) as isize;
        let limit = pane.screen.history_len() as isize;
        pane.scroll_offset = (total - visible - mark as isize).clamp(0, limit) as usize;
    }

    /// 命中滚动条：鼠标在窗格最右一列，且滚动条当前可见（正在回看或悬停在该列）。
    fn scrollbar_hit(&self, id: u32, rect: Rect, x: usize, y: usize) -> bool {
        let Some(pane) = self.panes.get(&id) else {
            return false;
        };
        if pane.screen.history_len() == 0 || rect.w < 2 || rect.h < 2 {
            return false;
        }
        if x + 1 != rect.right() || y < rect.y || y >= rect.bottom() {
            return false;
        }
        self.scrollbar_visible(id, rect, pane)
    }

    /// 滚动条是否显示：有回看历史，且正在回看 / 鼠标悬停 / 正在拖动。
    ///
    /// 平时隐藏是为了不永久占用窗格最右一列（否则满宽输出会少一个字符）。
    fn scrollbar_visible(&self, id: u32, rect: Rect, pane: &PaneState) -> bool {
        if pane.screen.history_len() == 0 || rect.w < 2 || rect.h < 2 {
            return false;
        }
        pane.scroll_offset > 0
            || self.scrollbar_drag.map(|(d, _)| d == id).unwrap_or(false)
            || self
                .hover
                .map(|(x, y)| x + 1 == rect.right() && y >= rect.y && y < rect.bottom())
                .unwrap_or(false)
    }

    /// 拖动滚动条：按拇指中心所在行换算回看偏移（越靠上越久远）。
    fn drag_scrollbar(&mut self, id: u32, rect: Rect, y: usize) {
        let Some(pane) = self.panes.get_mut(&id) else {
            return;
        };
        let history = pane.screen.history_len();
        if history == 0 {
            return;
        }
        let (thumb_h, _) = scrollbar_geometry(rect.h, history, pane.scroll_offset);
        let avail = rect.h.saturating_sub(thumb_h);
        if avail == 0 {
            pane.scroll_offset = 0;
            return;
        }
        let row = y.clamp(rect.y, rect.bottom().saturating_sub(1)) - rect.y;
        let shift = row.saturating_sub(thumb_h / 2).min(avail);
        pane.scroll_offset = (history - history * shift / avail).min(history);
    }

    // ---------- 鼠标 ----------

    /// 处理鼠标事件；返回需要转发给某个窗格子进程的字节。
    pub fn on_mouse(&mut self, ev: &MouseEvent) -> Option<(u32, Vec<u8>)> {
        self.hover = Some((ev.x, ev.y));
        if let Some(Overlay::Settings(_)) = self.overlay {
            self.settings_mouse(ev);
            return None;
        }
        if self.overlay.is_some() {
            return None;
        }
        // 标记模式下用鼠标点击/滚轮即退出（纯移动不退出）。
        if self.mark_mode && (ev.buttons != 0 || ev.wheel != 0 || ev.hwheel != 0) {
            self.exit_mark_mode();
        }
        // 拖动滚动条中：左键按住就按位置换算回看偏移，松开结束。
        if let Some((id, rect)) = self.scrollbar_drag {
            if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 {
                self.drag_scrollbar(id, rect, ev.y);
            } else {
                self.scrollbar_drag = None;
            }
            return None;
        }
        // 拖动分隔线中：左键按住就更新比例，松开结束。
        if let Some(drag) = self.drag.clone() {
            if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 {
                self.update_drag(&drag, ev);
            } else {
                self.drag = None;
            }
            return None;
        }

        // 标签栏：滚轮切换、中键关闭、点「+」新建、左键切标签。
        if ev.y == 0 {
            if ev.wheel != 0 {
                if ev.wheel > 0 {
                    self.prev_tab();
                } else {
                    self.next_tab();
                }
                return None;
            }
            if ev.buttons & FROM_LEFT_2ND_BUTTON_PRESSED != 0 && !ev.moved {
                if let Some(index) = self.tab_at(ev.x) {
                    self.close_tab_at(index);
                }
                return None;
            }
            if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 && !ev.moved {
                if self
                    .tab_bar_plus_x(self.cols)
                    .map(|x| ev.x >= x && ev.x < x + TAB_PLUS_WIDTH)
                    .unwrap_or(false)
                {
                    // Alt+点「+」：选择 profile；直接点仍用默认 profile。
                    if ev.alt && !self.config.profiles.is_empty() {
                        self.overlay = Some(Overlay::ProfilePicker { selected: 0 });
                    } else {
                        self.new_tab();
                    }
                } else if let Some(index) = self.tab_close_at(ev.x) {
                    // 标签末尾的「×」：关闭该标签（是否确认由 confirm_close 决定）。
                    self.close_tab_at(index);
                } else if let Some(index) = self.tab_at(ev.x) {
                    self.activate_tab(index);
                    self.tab_press = Some((index, ev.x));
                }
                return None;
            }
            // 按住左键在标签栏上移动：按悬停到的标签重排。
            if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 && ev.moved {
                if let Some((from, _)) = self.tab_press {
                    if let Some(to) = self.tab_at(ev.x) {
                        if to != from {
                            self.move_tab(from, to);
                            self.tab_press = Some((to, ev.x));
                        }
                    }
                }
                return None;
            }
            if ev.buttons == 0 {
                self.tab_press = None;
            }
            return None;
        }

        let content = self.content_rect();
        let tree = self.tabs.get(self.active).map(|t| t.tree.clone())?;
        let zoomed = self.tabs.get(self.active).map(|t| t.zoom).unwrap_or(false);
        let (panes, _) = self.pane_layout()?;

        // Ctrl+左键点击 OSC 8 链接：交给系统默认程序打开。
        if ev.ctrl && !ev.moved && ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 {
            if let Some((id, rect)) = pane_at(&panes, ev.x, ev.y) {
                if let Some(url) = self.link_at_mouse(id, rect, ev.x, ev.y) {
                    let ok = crate::platform::win32::shell_open(&url);
                    self.set_status(if ok {
                        format!("已打开链接：{url}")
                    } else {
                        format!("无法打开链接：{url}")
                    });
                    return None;
                }
            }
        }

        // 选区拖动中：按鼠标位置更新 head，松开后保留选区供复制。
        if let Some(mut selection) = self.selection {
            if selection.dragging {
                if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 {
                    if let Some((_, rect)) = panes
                        .iter()
                        .find(|(id, _)| *id == selection.pane)
                        .copied()
                    {
                        let history = self
                            .panes
                            .get(&selection.pane)
                            .map(|p| p.screen.history_len())
                            .unwrap_or(0);
                        let x = ev.x.clamp(rect.x, rect.right().saturating_sub(1)) - rect.x;
                        let y = ev.y.clamp(rect.y, rect.bottom().saturating_sub(1)) - rect.y;
                        selection.head = (x, history + y);
                        self.selection = Some(selection);
                    }
                    return None;
                }
                selection.dragging = false;
                self.selection = Some(selection);
                // 「选中即复制」：松开鼠标就把选区写入剪贴板。
                if self.config.behavior.copy_on_select {
                    self.copy_selection();
                }
                return None;
            }
        }

        // 滚轮：应用开了鼠标追踪就转发（Shift 强制滚回看），否则滚动回看缓冲。
        if ev.wheel != 0 {
            if let Some((id, rect)) = pane_at(&panes, ev.x, ev.y) {
                let tracking = self
                    .panes
                    .get(&id)
                    .map(|p| p.screen.mouse_mode != 0)
                    .unwrap_or(false);
                if tracking && !ev.shift {
                    return self.mouse_report(id, rect, ev);
                }
                let lines = self.wheel_lines(ev.wheel);
                if lines != 0 {
                    self.scroll_pane(id, lines);
                }
            }
            return None;
        }
        if ev.hwheel != 0 {
            return None;
        }

        // 左键按下滚动条：开始拖动（必须先于选区命中判断）。
        if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 && !ev.moved && !ev.shift {
            if let Some((id, rect)) = panes
                .iter()
                .find(|(id, rect)| self.scrollbar_hit(*id, *rect, ev.x, ev.y))
                .copied()
            {
                self.scrollbar_drag = Some((id, rect));
                self.tabs[self.active].focus = id;
                self.drag_scrollbar(id, rect, ev.y);
                return None;
            }
        }

        // 左键按下：命中分隔线就开始拖拽（放大模式下没有分隔线）。
        if !zoomed && ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 && !ev.moved {
            if let Some((path, axis, rect)) = tree.find_separator(content, ev.x, ev.y) {
                self.drag = Some(DragTarget { path, axis, rect });
                return None;
            }
        }

        if let Some((id, rect)) = pane_at(&panes, ev.x, ev.y) {
            let tracking = self
                .panes
                .get(&id)
                .map(|p| p.screen.mouse_mode != 0)
                .unwrap_or(false);
            // Alt+左键是块选择，不转发给应用，否则无法在全屏程序里选文本。
            let block_select = ev.alt && ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0;
            if tracking && !block_select {
                if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 {
                    self.tabs[self.active].focus = id;
                }
                return self.mouse_report(id, rect, ev);
            }

            // 右键粘贴（与 Windows Terminal 一致），不影响选择。
            if ev.buttons & RIGHTMOST_BUTTON_PRESSED != 0 && !ev.moved {
                self.tabs[self.active].focus = id;
                self.paste_clipboard();
                return None;
            }

            if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 && !ev.moved {
                let history = self
                    .panes
                    .get(&id)
                    .map(|p| p.screen.history_len())
                    .unwrap_or(0);
                let position = (ev.x - rect.x, history + (ev.y - rect.y));
                if ev.shift && self.selection.map(|s| s.pane == id).unwrap_or(false) {
                    // Shift+点击：扩展已有选区
                    if let Some(selection) = self.selection.as_mut() {
                        selection.head = position;
                        selection.dragging = true;
                    }
                } else if ev.double_click {
                    // 双击选词
                    self.selection = self.word_selection(id, position);
                    if self.config.behavior.copy_on_select {
                        self.copy_selection();
                    }
                } else {
                    // Alt+左键：矩形（块）选择，即使子进程开了鼠标上报也优先。
                    self.selection = Some(Selection {
                        pane: id,
                        anchor: position,
                        head: position,
                        dragging: true,
                        block: ev.alt,
                    });
                }
                self.tabs[self.active].focus = id;
                return None;
            }

            if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 {
                self.tabs[self.active].focus = id;
            }
        }
        None
    }

    /// 双击时按「词」扩展选区（字母数字与常见路径字符）。
    fn word_selection(
        &self,
        pane_id: u32,
        position: (usize, usize),
    ) -> Option<Selection> {
        let pane = self.panes.get(&pane_id)?;
        let cells = absolute_row_cells(pane, position.1);
        if cells.is_empty() {
            return None;
        }
        let column = position.0.min(cells.len() - 1);
        if !is_word_char(cells[column].ch) {
            return None;
        }
        let mut start = column;
        while start > 0 && is_word_char(cells[start - 1].ch) {
            start -= 1;
        }
        let mut end = column;
        while end + 1 < cells.len() && is_word_char(cells[end + 1].ch) {
            end += 1;
        }
        Some(Selection {
            pane: pane_id,
            anchor: (start, position.1),
            head: (end, position.1),
            dragging: false,
            block: false,
        })
    }

    /// Ctrl+Shift+C：把选区写入剪贴板。
    fn copy_selection(&mut self) {
        let Some(selection) = self.selection else {
            self.set_status("没有选中文本：按住左键拖动选择".to_string());
            return;
        };
        let Some(text) = self.selection_text(selection) else {
            self.set_status("选区为空".to_string());
            self.selection = None;
            return;
        };
        match crate::platform::clipboard::set_text(&text) {
            Ok(()) => self.set_status(format!("已复制 {} 个字符", text.chars().count())),
            Err(e) => self.set_status(format!("复制失败：{e}")),
        }
        self.selection = None;
    }

    // ---------- 标记模式 ----------

    /// Ctrl+Shift+M：进入/退出键盘标记模式。
    fn toggle_mark_mode(&mut self) {
        if self.mark_mode {
            self.exit_mark_mode();
            self.set_status("已退出标记模式".to_string());
            return;
        }
        let Some(pane) = self.focused_pane() else {
            return;
        };
        let id = self.focused_pane_id();
        let history = pane.screen.history_len();
        let head = (pane.screen.cursor_x, history + pane.screen.cursor_y);
        self.selection = Some(Selection {
            pane: id,
            anchor: head,
            head,
            dragging: false,
            block: false,
        });
        self.mark_mode = true;
        if let Some(pane) = self.focused_pane_mut() {
            pane.scroll_offset = 0;
        }
        self.set_status("标记模式：方向键移动，Enter 复制，Esc 退出".to_string());
    }

    fn exit_mark_mode(&mut self) {
        self.mark_mode = false;
        self.selection = None;
    }

    /// 标记模式下的按键；返回 `Some(空)` 表示已消费，`None` 表示交给后续处理。
    fn mark_mode_key(&mut self, ev: &KeyEvent) -> Option<Vec<u8>> {
        let ctrl_shift = ev.ctrl && ev.shift;
        match ev.vk {
            crate::input::VK_ESCAPE => {
                self.exit_mark_mode();
                return Some(Vec::new());
            }
            crate::input::VK_RETURN => {
                let empty = self
                    .selection
                    .map(|s| s.anchor == s.head)
                    .unwrap_or(true);
                if empty {
                    self.exit_mark_mode();
                    self.set_status("没有选中文本".to_string());
                } else {
                    self.copy_selection();
                    self.mark_mode = false;
                }
                return Some(Vec::new());
            }
            _ if ctrl_shift && ev.vk == 0x43 => {
                // Ctrl+Shift+C：复制并退出。
                if self.selection.map(|s| s.anchor == s.head).unwrap_or(true) {
                    self.exit_mark_mode();
                    self.set_status("没有选中文本".to_string());
                } else {
                    self.copy_selection();
                    self.mark_mode = false;
                }
                return Some(Vec::new());
            }
            _ if ctrl_shift && ev.vk == 0x4D => {
                self.exit_mark_mode();
                return Some(Vec::new());
            }
            _ => {}
        }

        let pane_rows = self
            .focused_pane()
            .map(|pane| pane.screen.rows.max(1))
            .unwrap_or(1);
        let width = self
            .focused_pane()
            .map(|pane| pane.screen.cols.max(1))
            .unwrap_or(1);
        let handled = match ev.vk {
            crate::input::VK_LEFT if ev.ctrl => {
                self.mark_word_step(-1);
                true
            }
            crate::input::VK_RIGHT if ev.ctrl => {
                self.mark_word_step(1);
                true
            }
            crate::input::VK_LEFT => {
                self.mark_move(-1, 0);
                true
            }
            crate::input::VK_RIGHT => {
                self.mark_move(1, 0);
                true
            }
            crate::input::VK_UP => {
                self.mark_move(0, -1);
                true
            }
            crate::input::VK_DOWN => {
                self.mark_move(0, 1);
                true
            }
            crate::input::VK_HOME if ev.ctrl => {
                self.mark_set_head((0, 0));
                true
            }
            crate::input::VK_END if ev.ctrl => {
                self.mark_set_head((width - 1, self.mark_last_row()));
                true
            }
            crate::input::VK_HOME => {
                let row = self.mark_head().1;
                self.mark_set_head((0, row));
                true
            }
            crate::input::VK_END => {
                let row = self.mark_head().1;
                self.mark_set_head((width - 1, row));
                true
            }
            crate::input::VK_PRIOR => {
                self.mark_move(0, -(pane_rows as isize));
                true
            }
            crate::input::VK_NEXT => {
                self.mark_move(0, pane_rows as isize);
                true
            }
            _ => false,
        };
        if handled {
            return Some(Vec::new());
        }
        // 其他按键：退出标记模式，交给正常动作/输入处理。
        self.mark_mode = false;
        None
    }

    fn mark_head(&self) -> (usize, usize) {
        self.selection.map(|s| s.head).unwrap_or((0, 0))
    }

    fn mark_last_row(&self) -> usize {
        self.focused_pane()
            .map(|pane| {
                (pane.screen.history_len() + pane.screen.rows).saturating_sub(1)
            })
            .unwrap_or(0)
    }

    fn mark_set_head(&mut self, head: (usize, usize)) {
        if let Some(selection) = self.selection.as_mut() {
            selection.head = head;
        }
        self.mark_ensure_visible(head.1);
    }

    fn mark_move(&mut self, dx: isize, dy: isize) {
        let Some(selection) = self.selection else {
            return;
        };
        let Some(pane) = self.panes.get(&selection.pane) else {
            return;
        };
        let width = pane.screen.cols.max(1);
        let last_row = (pane.screen.history_len() + pane.screen.rows).saturating_sub(1);
        let x = (selection.head.0 as isize + dx).clamp(0, (width - 1) as isize) as usize;
        let y = (selection.head.1 as isize + dy).clamp(0, last_row as isize) as usize;
        self.mark_set_head((x, y));
    }

    fn mark_word_step(&mut self, direction: isize) {
        let Some(selection) = self.selection else {
            return;
        };
        let Some(pane) = self.panes.get(&selection.pane) else {
            return;
        };
        let cells = absolute_row_cells(pane, selection.head.1);
        if cells.is_empty() {
            return;
        }
        let last = cells.len() - 1;
        let mut column = selection.head.0.min(last);
        if direction > 0 {
            if column < last {
                column += 1;
            }
            while column < last
                && is_word_char(cells[column].ch)
                && is_word_char(cells[column + 1].ch)
            {
                column += 1;
            }
        } else {
            if column > 0 {
                column -= 1;
            }
            while column > 0
                && is_word_char(cells[column].ch)
                && is_word_char(cells[column - 1].ch)
            {
                column -= 1;
            }
        }
        self.mark_set_head((column, selection.head.1));
    }

    /// 让选区头所在行保持在视口内（必要时滚动回看缓冲）。
    fn mark_ensure_visible(&mut self, row: usize) {
        let Some(selection) = self.selection else {
            return;
        };
        let Some(pane) = self.panes.get_mut(&selection.pane) else {
            return;
        };
        let history = pane.screen.history_len();
        let visible = pane.screen.rows.max(1);
        let top = history.saturating_sub(pane.scroll_offset);
        let bottom = top + visible - 1;
        if row < top {
            pane.scroll_offset = history.saturating_sub(row).min(history);
        } else if row > bottom {
            let needed = (history + visible - 1).saturating_sub(row);
            pane.scroll_offset = needed.min(history);
        }
    }

    /// 把选区对应的屏幕内容拼成文本（行尾空白去掉，行间用 CRLF；块选区保留列内空格）。
    fn selection_text(&self, selection: Selection) -> Option<String> {
        let pane = self.panes.get(&selection.pane)?;
        if selection.block {
            return self.block_selection_text(pane, selection);
        }
        let (start, end) = selection.ordered();
        let mut text = String::new();
        let mut copied_rows = 0usize;
        for row in start.1..=end.1 {
            let cells = absolute_row_cells(pane, row);
            if cells.is_empty() {
                continue;
            }
            let from = if row == start.1 { start.0.min(cells.len()) } else { 0 };
            let to = if row == end.1 {
                (end.0 + 1).min(cells.len())
            } else {
                cells.len()
            };
            let mut line = String::new();
            for cell in cells[from.min(to)..to].iter() {
                line.push(cell.ch);
                // 组合符跟着基字符一起复制，粘贴出去仍是原来的字。
                if cell.combining != 0 {
                    if let Some(marks) =
                        crate::emulation::screen::combining_text(cell.combining)
                    {
                        line.push_str(&marks);
                    }
                }
            }
            text.push_str(line.trim_end());
            if row != end.1 {
                text.push_str("\r\n");
            }
            copied_rows += 1;
        }
        if copied_rows == 0 {
            None
        } else {
            Some(text)
        }
    }

    /// 矩形选择：每行取相同列区间，保留区间内的空格。
    fn block_selection_text(&self, pane: &PaneState, selection: Selection) -> Option<String> {
        let (left, top, right, bottom) = selection.block_bounds();
        let mut text = String::new();
        let mut copied_rows = 0usize;
        for row in top..=bottom {
            let cells = absolute_row_cells(pane, row);
            let mut line = String::new();
            for column in left..=right {
                let Some(cell) = cells.get(column) else {
                    break;
                };
                line.push(cell.ch);
                if cell.combining != 0 {
                    if let Some(marks) = crate::emulation::screen::combining_text(cell.combining)
                    {
                        line.push_str(&marks);
                    }
                }
            }
            text.push_str(&line);
            if row != bottom {
                text.push_str("\r\n");
            }
            copied_rows += 1;
        }
        if copied_rows == 0 {
            None
        } else {
            Some(text)
        }
    }

    fn update_drag(&mut self, drag: &DragTarget, ev: &MouseEvent) {
        let ratio = match drag.axis {
            Axis::Horizontal => {
                let usable = drag.rect.w.saturating_sub(1);
                if usable == 0 {
                    return;
                }
                (ev.x.saturating_sub(drag.rect.x) * 100 / usable) as u16
            }
            Axis::Vertical => {
                let usable = drag.rect.h.saturating_sub(1);
                if usable == 0 {
                    return;
                }
                (ev.y.saturating_sub(drag.rect.y) * 100 / usable) as u16
            }
        };
        let changed = self
            .tabs
            .get_mut(self.active)
            .map(|tab| tab.tree.set_ratio(&drag.path, ratio))
            .unwrap_or(false);
        if changed {
            self.sync_layout();
        }
    }

    /// 底部状态栏右侧的文字（临时提示、回看偏移、当前目录）。
    fn status_text(&self, cols: usize) -> String {
        let mut right = String::new();
        if let Some((text, _)) = &self.status {
            right.push_str(text);
            right.push_str("  ");
        }
        let scroll = self.focused_pane().map(|p| p.scroll_offset).unwrap_or(0);
        if scroll > 0 {
            right.push_str(&format!("↑ 回看 {scroll} 行  "));
        }
        // 当前目录（OSC 7）放在右侧信息的最左边：空间不够时优先截断它。
        if let Some(dir) = self.focused_pane().and_then(|p| p.screen.cwd.clone()) {
            let room = cols.saturating_sub(cells_width(&right) + 14);
            if room >= 8 {
                let short = truncate_left(&dir, room);
                right = format!(" {short}  {right}");
            }
        }
        right
    }

    /// 底部状态栏左侧的快捷键提示：常驻显示，优先用最长能整段放下的版本。
    fn status_hint(&self, cols: usize) -> Option<&'static str> {
        TAB_HINTS
            .iter()
            .find(|hint| cells_width(hint) <= cols)
            .copied()
    }

    /// 每个标签在标签栏里的 (起始列, 宽度)，宽度已包含末尾的关闭按钮区域。
    fn tab_segments(&self) -> Vec<(usize, usize)> {
        let mut segments = Vec::with_capacity(self.tabs.len());
        let mut start = 0usize;
        for (index, tab) in self.tabs.iter().enumerate() {
            let width = cells_width(&tab_label(index, tab)) + TAB_CLOSE_WIDTH;
            segments.push((start, width));
            start += width;
        }
        segments
    }

    /// 「+」按钮区域的起始列（与最后一个标签空一格）；空间不足时返回 `None`。
    fn tab_bar_plus_x(&self, cols: usize) -> Option<usize> {
        let end = self
            .tab_segments()
            .last()
            .map(|(start, width)| start + width)
            .unwrap_or(0);
        let start = end + 1;
        (start + TAB_PLUS_WIDTH <= cols).then_some(start)
    }

    fn tab_at(&self, x: usize) -> Option<usize> {
        self.tab_segments()
            .iter()
            .position(|(start, width)| x >= *start && x < *start + *width)
    }

    /// 命中标签末尾的「×」关闭按钮（3 列宽，整块都可点）。
    fn tab_close_at(&self, x: usize) -> Option<usize> {
        self.tab_segments()
            .iter()
            .enumerate()
            .find_map(|(index, (start, width))| {
                // 被窗口边缘裁掉的标签，关闭按钮不可见，也不可点。
                if start + width > self.cols {
                    return None;
                }
                let close_start = start + width.saturating_sub(TAB_CLOSE_WIDTH);
                (x >= close_start && x < start + width).then_some(index)
            })
    }

    /// 标签的配色（取该标签首个窗格所属 profile 的 `tab_color`）。
    fn tab_color_for(&self, index: usize) -> Option<Color> {
        let tab = self.tabs.get(index)?;
        let profile = self.panes.get(&tab.tree.first_leaf())?.profile.clone();
        self.config.profile(&profile).and_then(|p| p.tab_color)
    }

    /// 把标签从 `from` 移到 `to`（拖动重排），并修正当前激活标签的下标。
    fn move_tab(&mut self, from: usize, to: usize) {
        if from == to || from >= self.tabs.len() || to >= self.tabs.len() {
            return;
        }
        let tab = self.tabs.remove(from);
        self.tabs.insert(to, tab);
        self.active = if self.active == from {
            to
        } else if from < self.active && to >= self.active {
            self.active - 1
        } else if from > self.active && to <= self.active {
            self.active + 1
        } else {
            self.active
        };
    }

    /// 鼠标位置的 OSC 8 链接：按当前滚动偏移换算成绝对行号。
    fn link_at_mouse(&self, id: u32, rect: Rect, x: usize, y: usize) -> Option<String> {
        let pane = self.panes.get(&id)?;
        if x < rect.x || x >= rect.right() || y < rect.y || y >= rect.bottom() {
            return None;
        }
        let visible = rect.h.min(pane.screen.rows.max(1));
        let row_in_view = y - rect.y;
        if row_in_view >= visible {
            return None;
        }
        let total = pane.screen.history_len() + pane.screen.rows;
        let start = total
            .saturating_sub(visible + pane.scroll_offset)
            .min(pane.screen.history_len().saturating_add(pane.screen.rows));
        let abs_row = start + row_in_view;
        pane.screen
            .link_at_absolute(abs_row, x - rect.x)
            .map(|s| s.to_string())
    }

    /// 把鼠标事件编码成 VT 鼠标上报，发给对应窗格。
    fn mouse_report(
        &mut self,
        pane_id: u32,
        rect: Rect,
        ev: &MouseEvent,
    ) -> Option<(u32, Vec<u8>)> {
        let pane = self.panes.get(&pane_id)?;
        if pane.screen.mouse_mode == 0 {
            return None;
        }
        if ev.x < rect.x || ev.x >= rect.right() || ev.y < rect.y || ev.y >= rect.bottom() {
            return None;
        }
        let mode = pane.screen.mouse_mode;
        let sgr = pane.screen.mouse_sgr;
        let x = ev.x - rect.x + 1;
        let y = ev.y - rect.y + 1;

        let mut release = false;
        let button: u8 = if ev.wheel != 0 {
            if ev.wheel > 0 {
                64
            } else {
                65
            }
        } else if ev.moved {
            if mode == 1003 {
                32 + self.mouse_button
            } else if mode == 1002 && ev.buttons != 0 {
                32 + self.mouse_button
            } else {
                return None;
            }
        } else if ev.buttons == 0 {
            release = true;
            self.mouse_button
        } else {
            let code = if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED != 0 {
                0
            } else if ev.buttons & FROM_LEFT_2ND_BUTTON_PRESSED != 0 {
                1
            } else if ev.buttons & RIGHTMOST_BUTTON_PRESSED != 0 {
                2
            } else {
                3
            };
            self.mouse_button = code;
            code
        };

        let modifiers = u8::from(ev.shift) * 4 + u8::from(ev.alt) * 8 + u8::from(ev.ctrl) * 16;
        let code = button + modifiers;
        let bytes = if sgr {
            format!(
                "\x1b[<{};{};{}{}",
                code,
                x,
                y,
                if release { 'm' } else { 'M' }
            )
            .into_bytes()
        } else {
            let code = if release { 3 + modifiers } else { code };
            if x > 223 || y > 223 {
                return None;
            }
            vec![0x1b, b'[', b'M', 32 + code, 32 + x as u8, 32 + y as u8]
        };
        Some((pane_id, bytes))
    }

    fn spawn_pane(&mut self, profile: &str, cols: u16, rows: u16) -> u32 {
        let id = self.next_pane_id;
        self.next_pane_id += 1;
        self.spawn_pane_with_id(profile, id, cols, rows);
        id
    }

    fn spawn_pane_with_id(&mut self, profile: &str, id: u32, cols: u16, rows: u16) {
        let scheme = self
            .config
            .profile(profile)
            .map(|p| self.config.scheme_for_profile(p))
            .unwrap_or_default();
        let screen = Screen::new(cols.max(2) as usize, rows.max(1) as usize, self.config.scrollback);
        self.panes.insert(
            id,
            PaneState {
                profile: profile.to_string(),
                screen,
                parser: Parser::new(),
                scheme,
                scroll_offset: 0,
                exited: None,
            },
        );
        let create = msg::CreatePane {
            pane_id: id,
            profile: profile.to_string(),
            cols: cols.max(2),
            rows: rows.max(1),
        };
        let _ = self
            .tx
            .send(proto::encode(FrameType::CreatePane, &create.encode()));
    }

    fn close_pane_state(&mut self, id: u32) {
        if self.selection.map(|s| s.pane == id).unwrap_or(false) {
            self.selection = None;
        }
        self.panes.remove(&id);
        let close = msg::PaneId { pane_id: id };
        let _ = self
            .tx
            .send(proto::encode(FrameType::ClosePane, &close.encode()));
    }

    /// 按当前终端尺寸重新布局，并让每个窗格的网格与子进程尺寸跟上。
    pub fn sync_layout(&mut self) {
        let (panes, _) = self.pane_layout().unwrap_or_default();
        for (id, rect) in panes {
            let Some(pane) = self.panes.get_mut(&id) else {
                continue;
            };
            let old = (pane.screen.cols, pane.screen.rows);
            if old != (rect.w, rect.h) {
                pane.screen.resize(rect.w, rect.h);
                let req = msg::Resize {
                    pane_id: id,
                    cols: rect.w.max(2) as u16,
                    rows: rect.h.max(1) as u16,
                };
                let _ = self
                    .tx
                    .send(proto::encode(FrameType::Resize, &req.encode()));
            }
        }
        self.renderer.invalidate();
    }

    /// 窗格内容区：顶部标签栏 1 行 + 底部状态栏 1 行。
    fn content_rect(&self) -> Rect {
        Rect::new(0, 1, self.cols, self.rows.saturating_sub(2).max(1))
    }

    /// 底部状态栏所在行（提示在左、状态/目录在右）。
    fn status_bar_y(&self) -> usize {
        self.rows.saturating_sub(1)
    }

    /// 当前标签的窗格布局；放大时只有聚焦窗格占满内容区。
    fn pane_layout(&self) -> Option<(Vec<(u32, Rect)>, Vec<Rect>)> {
        let tab = self.tabs.get(self.active)?;
        if tab.zoom {
            Some((vec![(tab.focus, self.content_rect())], Vec::new()))
        } else {
            Some(compute(&tab.tree, self.content_rect()))
        }
    }

    // ---------- 外部事件 ----------

    pub fn on_pane_output(&mut self, pane_id: u32, data: &[u8]) -> Vec<u8> {
        let Some(pane) = self.panes.get_mut(&pane_id) else {
            return Vec::new();
        };
        pane.parser.feed(data, &mut pane.screen);
        // OSC 52：子进程请求复制到剪贴板。
        if let Some(text) = pane.screen.clipboard.take() {
            let _ = crate::platform::clipboard::set_text(&text);
        }
        let bell = std::mem::replace(&mut pane.screen.bell, false);
        let notifications: Vec<String> = pane.screen.notifications.drain(..).collect();
        let exit = pane.screen.last_exit;
        let responses = std::mem::take(&mut pane.screen.responses);
        // 标签页上的状态标记：响铃 + 最近一条命令的退出码（OSC 133;D）。
        if let Some(tab) = self
            .tabs
            .iter_mut()
            .find(|t| t.tree.leaves().contains(&pane_id))
        {
            if tab.last_exit != exit {
                tab.last_exit = exit;
            }
            if bell || !notifications.is_empty() {
                tab.bell = true;
            }
        }
        if let Some(last) = notifications.last() {
            self.set_status(format!("通知：{last}"));
        }
        responses
    }

    pub fn on_pane_created(&mut self, pane_id: u32, pid: u32) {
        // 只记日志，不占用标签栏（启动时状态提示会被误认为错误）。
        crate::platform::logging::info(&format!("窗格 {pane_id} 已启动（pid={pid}）"));
    }

    pub fn on_pane_exited(&mut self, pane_id: u32, code: i32) {
        if let Some(pane) = self.panes.get_mut(&pane_id) {
            pane.exited = Some(code);
        }
        self.set_status(format!(
            "窗格 {pane_id} 已退出，退出码 {code}（Ctrl+Shift+W 关闭）"
        ));
    }

    /// 需要同步到控制台标题的内容（优先前台进程设置的 OSC 标题）。
    pub fn take_title(&mut self) -> Option<String> {
        let from_pane = self
            .focused_pane()
            .map(|p| p.screen.title.clone())
            .filter(|t| !t.is_empty());
        let title = from_pane
            .or_else(|| self.active_tab().map(|t| t.title.clone()))
            .unwrap_or_default();
        if !title.is_empty() && title != self.prev_title {
            self.prev_title = title.clone();
            Some(format!("scterm — {title}"))
        } else {
            None
        }
    }

    pub fn on_resize(&mut self, cols: usize, rows: usize) {
        if cols == self.cols && rows == self.rows {
            return;
        }
        self.cols = cols;
        self.rows = rows;
        self.sync_layout();
    }

    pub fn set_status(&mut self, text: String) {
        self.status = Some((text, Instant::now()));
    }

    pub fn tick(&mut self) {
        if let Some((_, at)) = &self.status {
            if at.elapsed().as_secs() >= 4 {
                self.status = None;
            }
        }
        // 每秒钟检查一次配置文件，实现 Windows Terminal 那样的「改完即生效」。
        if self.last_config_check.elapsed().as_millis() >= 1000 {
            self.last_config_check = Instant::now();
            if let Ok(mtime) = std::fs::metadata(&self.config_path).and_then(|m| m.modified()) {
                if Some(mtime) != self.config_mtime {
                    self.config_mtime = Some(mtime);
                    self.reload_config();
                }
            }
        }
    }

    // ---------- 输入 ----------

    /// 处理一次按键；返回值需要写回聚焦窗格的子进程（可能为空）。
    pub fn on_key(&mut self, ev: &KeyEvent) -> Vec<u8> {
        let win32_input = self
            .focused_pane()
            .map(|p| p.screen.win32_input)
            .unwrap_or(false);
        if self.overlay.is_some() {
            if ev.down {
                self.on_overlay_key(ev);
            }
            return Vec::new();
        }
        // 抬起事件只在 win32-input-mode 下有意义（子进程自己判断按住/松开）。
        if !ev.down {
            if win32_input {
                return self.forward_to_pane(encode_win32_key(ev));
            }
            return Vec::new();
        }
        // 标记模式接管键盘：方向键移动选区头，Enter/Esc 退出。
        if self.mark_mode {
            if let Some(bytes) = self.mark_mode_key(ev) {
                return bytes;
            }
        }
        // Esc 先清掉选区（与 Windows Terminal 一致）。
        if ev.vk == crate::input::VK_ESCAPE && self.selection.is_some() {
            self.selection = None;
            return Vec::new();
        }
        if let Some(chord) = crate::input::chord_of(ev) {
            if let Some(action) = self.registry.resolve(&chord) {
                self.execute(action);
                return Vec::new();
            }
        }
        // win32-input-mode：按下与抬起都按 `CSI Vk;Sc;Uc;Kd;Cs;Rc _` 原样转发，
        // Shift+Enter、Ctrl+Shift+字母等 VT 表达不了的组合键因此也能送达。
        if win32_input {
            return self.forward_to_pane(encode_win32_key(ev));
        }
        let app_cursor = self
            .focused_pane()
            .map(|p| p.screen.app_cursor_keys)
            .unwrap_or(false);
        let bytes = encode_key(ev, app_cursor);
        if !bytes.is_empty() {
            // 一按键就回到最新输出并清掉选区（与 Windows Terminal 一致）。
            self.selection = None;
            if let Some(pane) = self.focused_pane_mut() {
                pane.scroll_offset = 0;
            }
        }
        bytes
    }

    /// 回到底部、清掉选区后把字节写回聚焦窗格。
    fn forward_to_pane(&mut self, bytes: Vec<u8>) -> Vec<u8> {
        if !bytes.is_empty() {
            self.selection = None;
            if let Some(pane) = self.focused_pane_mut() {
                pane.scroll_offset = 0;
            }
        }
        bytes
    }

    fn on_overlay_key(&mut self, ev: &KeyEvent) {
        let ch = ev.ch;
        let text_char = match ch {
            Some(c) if !c.is_control() && !ev.ctrl && !ev.alt => Some(c),
            _ => None,
        };

        if matches!(self.overlay, Some(Overlay::Confirm { .. })) {
            if ev.vk == crate::input::VK_ESCAPE || matches!(text_char, Some('n') | Some('N')) {
                self.overlay = None;
                self.set_status("已取消".to_string());
            } else if ev.vk == crate::input::VK_RETURN
                || matches!(text_char, Some('y') | Some('Y'))
            {
                let Some(Overlay::Confirm { action, .. }) = self.overlay.take() else {
                    return;
                };
                match action {
                    ConfirmAction::CloseTab(index) => self.close_tab_now(index),
                    ConfirmAction::Paste { text, bracketed } => self.send_paste(text, bracketed),
                }
            }
            return;
        }

        if matches!(self.overlay, Some(Overlay::Settings(_))) {
            self.on_settings_key(ev);
            return;
        }

        if matches!(self.overlay, Some(Overlay::BackgroundPath { .. })) {
            self.on_background_path_key(ev);
            return;
        }

        let profile_names = self.profile_names();
        match &mut self.overlay {
            Some(Overlay::Palette(state)) => {
                if ev.vk == crate::input::VK_ESCAPE {
                    self.overlay = None;
                    return;
                }
                if ev.vk == crate::input::VK_UP {
                    if state.selected > 0 {
                        state.selected -= 1;
                    }
                    return;
                }
                if ev.vk == crate::input::VK_DOWN {
                    let count = palette::filter(&self.registry, &state.query, &profile_names).len();
                    if state.selected + 1 < count {
                        state.selected += 1;
                    }
                    return;
                }
                if ev.vk == crate::input::VK_BACK {
                    state.query.pop();
                    state.selected = 0;
                    return;
                }
                if ev.vk == crate::input::VK_RETURN {
                    let items = palette::filter(&self.registry, &state.query, &profile_names);
                    if let Some(item) = items.get(state.selected) {
                        let action = item.action;
                        let profile = item.profile.clone();
                        self.overlay = None;
                        match profile {
                            Some(profile) => self.new_tab_with_profile(&profile),
                            None => self.execute(action),
                        }
                    }
                    return;
                }
                if let Some(c) = text_char {
                    state.query.push(c);
                    state.selected = 0;
                }
            }
            Some(Overlay::ProfilePicker { selected }) => {
                if ev.vk == crate::input::VK_ESCAPE {
                    self.overlay = None;
                    return;
                }
                let count = self.config.profiles.len();
                if count == 0 {
                    self.overlay = None;
                    return;
                }
                if ev.vk == crate::input::VK_UP {
                    *selected = settings::cycle_index(count, *selected, -1);
                    return;
                }
                if ev.vk == crate::input::VK_DOWN {
                    *selected = settings::cycle_index(count, *selected, 1);
                    return;
                }
                let index = if ev.vk == crate::input::VK_RETURN {
                    Some(*selected)
                } else {
                    match text_char {
                        Some(c @ '1'..='9') => {
                            let index = c as usize - '1' as usize;
                            (index < count).then_some(index)
                        }
                        _ => None,
                    }
                };
                if let Some(index) = index {
                    let name = self.config.profiles[index].name.clone();
                    self.overlay = None;
                    self.new_tab_with_profile(&name);
                }
            }
            Some(Overlay::Search(state)) => {
                if ev.vk == crate::input::VK_ESCAPE {
                    self.overlay = None;
                    for pane in self.panes.values_mut() {
                        pane.scroll_offset = 0;
                    }
                    return;
                }
                if ev.vk == crate::input::VK_RETURN {
                    if ev.shift {
                        state.prev_match();
                    } else {
                        state.next_match();
                    }
                    let hit = state.current_hit();
                    self.focus_search_hit(hit);
                    return;
                }
                if ev.vk == crate::input::VK_UP {
                    state.prev_match();
                    let hit = state.current_hit();
                    self.focus_search_hit(hit);
                    return;
                }
                if ev.vk == crate::input::VK_DOWN {
                    state.next_match();
                    let hit = state.current_hit();
                    self.focus_search_hit(hit);
                    return;
                }
                if ev.vk == crate::input::VK_BACK {
                    state.query.pop();
                    self.refresh_search();
                    return;
                }
                if let Some(c) = text_char {
                    state.query.push(c);
                    self.refresh_search();
                }
            }
            Some(Overlay::Rename { text }) => {
                if ev.vk == crate::input::VK_ESCAPE {
                    self.overlay = None;
                    return;
                }
                if ev.vk == crate::input::VK_BACK {
                    text.pop();
                    return;
                }
                if ev.vk == crate::input::VK_RETURN {
                    let new_title = text.clone();
                    self.overlay = None;
                    if let Some(tab) = self.tabs.get_mut(self.active) {
                        if !new_title.trim().is_empty() {
                            tab.title = new_title;
                            tab.custom_title = true;
                        }
                    }
                    return;
                }
                if let Some(c) = text_char {
                    if text.chars().count() < 40 {
                        text.push(c);
                    }
                }
            }
            Some(Overlay::Settings(_)) | Some(Overlay::Confirm { .. }) => {}
            Some(Overlay::BackgroundPath { .. }) => {}
            None => {}
        }
    }

    /// 背景图片路径输入：Enter 写回配置，Esc 放弃并回到设置面板。
    fn on_background_path_key(&mut self, ev: &KeyEvent) {
        if ev.vk == crate::input::VK_ESCAPE {
            let state = match self.overlay.take() {
                Some(Overlay::BackgroundPath { state, .. }) => state,
                _ => return,
            };
            self.overlay = Some(Overlay::Settings(state));
            return;
        }
        if ev.vk == crate::input::VK_RETURN {
            let value = match &self.overlay {
                Some(Overlay::BackgroundPath { text, .. }) => text.trim().to_string(),
                _ => return,
            };
            let state = match self.overlay.take() {
                Some(Overlay::BackgroundPath { state, .. }) => state,
                _ => return,
            };
            self.config.render.background_image = if value.is_empty() {
                None
            } else {
                Some(value.clone())
            };
            self.background = None;
            if value.is_empty() {
                self.set_status("背景图片：无".to_string());
            } else {
                let path = Config::resolve_background(&value);
                if path.exists() {
                    self.set_status(format!("背景图片：{value}"));
                } else {
                    self.set_status(format!("找不到图片文件：{}", path.display()));
                }
            }
            self.overlay = Some(Overlay::Settings(state));
            return;
        }
        let text_char = match ev.ch {
            Some(c) if !c.is_control() && !ev.ctrl && !ev.alt => Some(c),
            _ => None,
        };
        if let Some(Overlay::BackgroundPath { text, .. }) = self.overlay.as_mut() {
            if ev.vk == crate::input::VK_BACK {
                text.pop();
                return;
            }
            if let Some(c) = text_char {
                if text.chars().count() < 120 {
                    text.push(c);
                }
            }
        }
    }

    fn profile_names(&self) -> Vec<String> {
        self.config
            .profiles
            .iter()
            .map(|profile| profile.name.clone())
            .collect()
    }

    // ---------- 设置面板 ----------

    fn on_settings_key(&mut self, ev: &KeyEvent) {
        let Some(Overlay::Settings(state)) = self.overlay.as_ref() else {
            return;
        };
        let row = settings::ROWS[state.selected.min(settings::ROWS.len() - 1)];
        match ev.vk {
            crate::input::VK_ESCAPE => self.close_settings(true),
            crate::input::VK_RETURN => {
                self.overlay = None;
                self.save_settings();
            }
            crate::input::VK_UP => self.settings_move(-1),
            crate::input::VK_DOWN => self.settings_move(1),
            crate::input::VK_TAB => self.settings_move(if ev.shift { -1 } else { 1 }),
            crate::input::VK_LEFT => self.adjust_setting(row, -1),
            crate::input::VK_RIGHT => self.adjust_setting(row, 1),
            crate::input::VK_SPACE => {
                if row == Row::BackgroundImage {
                    self.open_background_path();
                }
            }
            _ => {}
        }
    }

    /// 打开背景图片路径输入框；保留设置面板状态，确认/取消后回到设置。
    fn open_background_path(&mut self) {
        let text = self
            .config
            .render
            .background_image
            .clone()
            .unwrap_or_default();
        let Some(Overlay::Settings(state)) = self.overlay.take() else {
            return;
        };
        self.overlay = Some(Overlay::BackgroundPath { text, state });
    }

    fn settings_move(&mut self, delta: i32) {
        if let Some(Overlay::Settings(state)) = self.overlay.as_mut() {
            state.selected = settings::cycle_index(settings::ROWS.len(), state.selected, delta);
        }
    }

    /// 设置面板的鼠标操作：点行选中、点右侧值区改值、滚轮换行。
    fn settings_mouse(&mut self, ev: &MouseEvent) {
        let rect = Self::settings_panel_rect(self.cols, self.rows);
        if ev.x < rect.x || ev.x >= rect.right() || ev.y < rect.y || ev.y >= rect.bottom() {
            return;
        }
        if ev.wheel != 0 {
            self.settings_move(if ev.wheel > 0 { -1 } else { 1 });
            return;
        }
        if ev.buttons & FROM_LEFT_1ST_BUTTON_PRESSED == 0 || ev.moved {
            return;
        }
        if ev.y < rect.y + 2 {
            return;
        }
        let index = ev.y - (rect.y + 2);
        let first = match self.overlay.as_ref() {
            Some(Overlay::Settings(state)) => Self::settings_first_visible(state.selected, rect.h),
            _ => return,
        };
        let index = first + index;
        // 与绘制循环一致：底部要留提示行，放不下的行不可点。
        if index >= settings::ROWS.len() || ev.y + 3 >= rect.bottom() {
            return;
        }
        if let Some(Overlay::Settings(state)) = self.overlay.as_mut() {
            state.selected = index;
        }
        if ev.x >= rect.x + rect.w.saturating_sub(30) {
            if settings::ROWS[index] == Row::BackgroundImage {
                self.open_background_path();
                return;
            }
            let delta = if ev.x >= rect.x + rect.w.saturating_sub(8) {
                1
            } else {
                -1
            };
            self.adjust_setting(settings::ROWS[index], delta);
        }
    }

    /// 修改当前行的取值；改完立刻生效（关闭设置并保存时才写文件）。
    fn adjust_setting(&mut self, row: Row, delta: i32) {
        match row {
            Row::Scheme => self.cycle_scheme(delta),
            Row::DefaultProfile => {
                let names: Vec<String> = self
                    .config
                    .profiles
                    .iter()
                    .map(|profile| profile.name.clone())
                    .collect();
                if names.is_empty() {
                    return;
                }
                let current = names
                    .iter()
                    .position(|name| *name == self.config.default_profile)
                    .unwrap_or(0);
                let index = settings::cycle_index(names.len(), current, delta);
                self.config.default_profile = names[index].clone();
                self.set_status(format!("默认 profile：{}", self.config.default_profile));
            }
            Row::Gradient => {
                let index = settings::cycle_index(
                    settings::GRADIENTS.len(),
                    settings::gradient_index(self.config.render.gradient),
                    delta,
                );
                self.config.render.gradient = settings::GRADIENTS[index];
            }
            Row::GradientPalette => {
                let index = settings::cycle_index(
                    settings::PALETTES.len(),
                    settings::palette_index(&self.config),
                    delta,
                );
                let (top, bottom) = settings::palette_colors(index);
                self.config.render.gradient_top = top;
                self.config.render.gradient_bottom = bottom;
                // 选了具体配色却没开渐变时顺手打开，避免「改了没效果」。
                if top.is_some() && self.config.render.gradient.is_none() {
                    self.config.render.gradient = Some(crate::render::GradientDir::Vertical);
                }
            }
            Row::TrueColor => {
                let current = settings::TRUECOLORS
                    .iter()
                    .position(|mode| *mode == self.config.render.truecolor)
                    .unwrap_or(0);
                let index = settings::cycle_index(settings::TRUECOLORS.len(), current, delta);
                self.config.render.truecolor = settings::TRUECOLORS[index];
            }
            Row::FontFace => {
                let index = settings::cycle_index(
                    settings::FONT_FACES.len(),
                    settings::font_face_index(&self.config),
                    delta,
                );
                let (label, face) = settings::FONT_FACES[index];
                self.config.render.font_face = face.map(|name| name.to_string());
                self.apply_active_profile_font();
                if !self.profile_font_enabled {
                    self.set_status(format!("字体：{label}"));
                }
            }
            Row::Mouse => {
                self.config.render.mouse = !self.config.render.mouse;
                crate::platform::console::set_mouse_enabled(self.config.render.mouse);
                self.set_status(format!(
                    "鼠标上报：{}",
                    if self.config.render.mouse { "开" } else { "关" }
                ));
            }
            Row::CopyOnSelect => {
                self.config.behavior.copy_on_select = !self.config.behavior.copy_on_select;
                self.set_status(format!(
                    "选中即复制：{}",
                    if self.config.behavior.copy_on_select {
                        "开"
                    } else {
                        "关"
                    }
                ));
            }
            Row::ConfirmClose => {
                self.config.behavior.confirm_close = !self.config.behavior.confirm_close;
                self.set_status(format!(
                    "关闭标签确认：{}",
                    if self.config.behavior.confirm_close {
                        "开"
                    } else {
                        "关"
                    }
                ));
            }
            Row::ConfirmPaste => {
                self.config.behavior.confirm_multiline_paste =
                    !self.config.behavior.confirm_multiline_paste;
                self.set_status(format!(
                    "多行粘贴确认：{}",
                    if self.config.behavior.confirm_multiline_paste {
                        "开"
                    } else {
                        "关"
                    }
                ));
            }
            Row::FontSize => {
                let current = self.config.render.font_size.unwrap_or(16);
                let index = settings::cycle_index(
                    settings::FONT_SIZES.len(),
                    settings::nearest_index(&settings::FONT_SIZES, current),
                    delta,
                );
                let size = settings::FONT_SIZES[index];
                self.config.render.font_size = Some(size);
                self.apply_active_profile_font();
                if !self.profile_font_enabled {
                    self.set_status(format!("字号：{size}"));
                }
            }
            Row::ProfileFont => {
                let Some(profile_name) = self.current_profile().map(|p| p.name.clone()) else {
                    self.set_status("没有活动 profile".to_string());
                    return;
                };
                let current = self
                    .current_profile()
                    .and_then(|profile| profile.font_face.clone())
                    .map(|face| {
                        settings::FONT_FACES
                            .iter()
                            .position(|(_, preset)| {
                                preset.map(|preset| preset == face.as_str()).unwrap_or(false)
                            })
                            .unwrap_or(0)
                    })
                    .unwrap_or(0);
                let index = settings::cycle_index(settings::FONT_FACES.len(), current, delta);
                let face = settings::FONT_FACES
                    .get(index)
                    .and_then(|(_, face)| *face)
                    .map(|face| face.to_string());
                if let Some(profile) = self.current_profile_mut() {
                    profile.font_face = face;
                }
                self.apply_active_profile_font();
                self.set_status(format!("profile「{profile_name}」字体已更新"));
            }
            Row::ProfileFontSize => {
                let Some(profile_name) = self.current_profile().map(|p| p.name.clone()) else {
                    self.set_status("没有活动 profile".to_string());
                    return;
                };
                let current = self.current_profile().and_then(|profile| profile.font_size);
                let current = current
                    .map(|size| settings::nearest_index(&settings::FONT_SIZES, size) + 1)
                    .unwrap_or(0);
                let index =
                    settings::cycle_index(settings::FONT_SIZES.len() + 1, current, delta);
                let size = index
                    .checked_sub(1)
                    .and_then(|index| settings::FONT_SIZES.get(index))
                    .copied();
                if let Some(profile) = self.current_profile_mut() {
                    profile.font_size = size;
                }
                self.apply_active_profile_font();
                self.set_status(format!("profile「{profile_name}」字号已更新"));
            }
            Row::ProfileGradient => {
                let current = self
                    .current_profile()
                    .map(|profile| profile.gradient)
                    .unwrap_or_default();
                let index = settings::cycle_index(
                    settings::PROFILE_GRADIENTS.len(),
                    settings::profile_gradient_index(current),
                    delta,
                );
                let value = settings::PROFILE_GRADIENTS[index];
                if let Some(profile) = self.current_profile_mut() {
                    profile.gradient = value;
                }
                self.set_status(format!(
                    "profile 渐变：{}",
                    settings::profile_gradient_name(value)
                ));
            }
            Row::ProfileGradientPalette => {
                let current = self
                    .current_profile()
                    .and_then(|profile| settings::profile_palette_index(profile))
                    .unwrap_or(0);
                let index = settings::cycle_index(settings::PALETTES.len(), current, delta);
                let (top, bottom) = settings::profile_palette_colors(index);
                if let Some(profile) = self.current_profile_mut() {
                    profile.gradient_top = top;
                    profile.gradient_bottom = bottom;
                }
                self.set_status(format!("profile 渐变配色：{}", settings::PALETTES[index].0));
            }
            Row::ProfileTabColor => {
                let current = self
                    .current_profile()
                    .and_then(|profile| profile.tab_color);
                let index = settings::cycle_index(
                    settings::TAB_COLORS.len() + 1,
                    settings::tab_color_index(current),
                    delta,
                );
                let color = settings::tab_color_at(index);
                if let Some(profile) = self.current_profile_mut() {
                    profile.tab_color = color;
                }
                self.set_status(format!(
                    "profile 标签色：{}",
                    settings::tab_color_name(color)
                ));
            }
            Row::Scrollback => {
                let index = settings::cycle_index(
                    settings::SCROLLBACKS.len(),
                    settings::nearest_index(&settings::SCROLLBACKS, self.config.scrollback),
                    delta,
                );
                let rows = settings::SCROLLBACKS[index];
                self.config.scrollback = rows;
                for pane in self.panes.values_mut() {
                    pane.screen.set_history_limit(rows);
                    pane.scroll_offset = pane.scroll_offset.min(pane.screen.history_len());
                }
                self.set_status(format!("回看行数：{rows}"));
            }
            Row::BackgroundImage => {
                // 选项 = 「无」+ backgrounds 文件夹里的图片；手输的路径若不在
                // 列表里，先插到「无」后面，避免循环时丢掉当前值。
                let current = self.config.render.background_image.clone();
                let files = Config::background_files();
                let mut options: Vec<Option<String>> = vec![None];
                if let Some(name) = current.as_ref() {
                    if !files.iter().any(|file| file == name) {
                        options.push(Some(name.clone()));
                    }
                }
                options.extend(files.into_iter().map(Some));
                let index = options
                    .iter()
                    .position(|option| *option == current)
                    .unwrap_or(0);
                let index = settings::cycle_index(options.len(), index, delta);
                let choice = options[index].clone();
                self.config.render.background_image = choice.clone();
                self.background = None;
                match choice {
                    Some(name) => self.set_status(format!("背景图片：{name}")),
                    None => self.set_status("背景图片：无".to_string()),
                }
            }
            Row::BackgroundOpacity => {
                let current = self.config.render.background_image_opacity as i32;
                let next = (current + delta * 5).clamp(0, 100) as u8;
                self.config.render.background_image_opacity = next;
                self.set_status(format!("图片不透明度：{next}%"));
            }
        }
    }

    fn current_scheme_name(&self) -> String {
        self.focused_pane()
            .map(|pane| pane.scheme.name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| "Campbell".to_string())
    }

    fn cycle_scheme(&mut self, delta: i32) {
        let names: Vec<String> = self
            .config
            .color_schemes
            .iter()
            .map(|scheme| scheme.name.clone())
            .collect();
        if names.is_empty() {
            return;
        }
        let current = names
            .iter()
            .position(|name| *name == self.current_scheme_name())
            .unwrap_or(0);
        let index = settings::cycle_index(names.len(), current, delta);
        let name = names[index].clone();
        for profile in &mut self.config.profiles {
            profile.color_scheme = Some(name.clone());
        }
        self.reapply_schemes();
        self.set_status(format!("配色方案：{name}"));
    }

    /// 按配置重建每个窗格的配色（切主题、取消设置时用）。
    fn reapply_schemes(&mut self) {
        let config = self.config.clone();
        for pane in self.panes.values_mut() {
            if let Some(profile) = config.profile(&pane.profile) {
                pane.scheme = config.scheme_for_profile(profile);
            }
        }
        self.renderer.invalidate();
    }

    /// 关闭设置；`revert` 为真时按快照回滚（Esc）。
    fn close_settings(&mut self, revert: bool) {
        let Some(Overlay::Settings(state)) = self.overlay.take() else {
            return;
        };
        if revert {
            state.snapshot.restore(&mut self.config);
            self.reapply_schemes();
            self.apply_active_profile_font();
            crate::platform::console::set_mouse_enabled(self.config.render.mouse);
            let scrollback = self.config.scrollback;
            for pane in self.panes.values_mut() {
                pane.screen.set_history_limit(scrollback);
            }
            self.background = None;
            self.set_status("设置已取消".to_string());
        }
    }

    /// 把设置写回配置文件（只改相关键，保留注释与自定义内容）。
    fn save_settings(&mut self) {
        let mut edits: Vec<ConfigEdit> = Vec::new();
        for profile in &self.config.profiles {
            let name = profile.name.clone();
            if let Some(scheme) = &profile.color_scheme {
                edits.push(ConfigEdit::ProfileScheme(name.clone(), scheme.clone()));
            }
            match &profile.font_face {
                Some(face) => {
                    edits.push(ConfigEdit::ProfileRender(
                        name.clone(),
                        "font_face",
                        quote_toml(face),
                    ));
                }
                None => edits.push(ConfigEdit::RemoveProfileRender(name.clone(), "font_face")),
            }
            match profile.font_size {
                Some(size) => edits.push(ConfigEdit::ProfileRender(
                    name.clone(),
                    "font_size",
                    size.to_string(),
                )),
                None => edits.push(ConfigEdit::RemoveProfileRender(name.clone(), "font_size")),
            }
            match profile.gradient {
                GradientOverride::Inherit => {
                    edits.push(ConfigEdit::RemoveProfileRender(name.clone(), "gradient"))
                }
                GradientOverride::Off => edits.push(ConfigEdit::ProfileRender(
                    name.clone(),
                    "gradient",
                    "\"off\"".to_string(),
                )),
                GradientOverride::Dir(dir) => {
                    let value = match dir {
                        crate::render::GradientDir::Vertical => "vertical",
                        crate::render::GradientDir::Horizontal => "horizontal",
                        crate::render::GradientDir::Diagonal => "diagonal",
                    };
                    edits.push(ConfigEdit::ProfileRender(
                        name.clone(),
                        "gradient",
                        format!("\"{value}\""),
                    ));
                }
            }
            for (key, value) in [
                ("gradient_top", profile.gradient_top),
                ("gradient_bottom", profile.gradient_bottom),
                ("tab_color", profile.tab_color),
            ] {
                match value {
                    Some(Color::Rgb(r, g, b)) => edits.push(ConfigEdit::ProfileRender(
                        name.clone(),
                        key,
                        format!("\"#{r:02X}{g:02X}{b:02X}\""),
                    )),
                    _ => edits.push(ConfigEdit::RemoveProfileRender(name.clone(), key)),
                }
            }
        }
        edits.push(ConfigEdit::Root(
            "default_profile",
            format!("\"{}\"", self.config.default_profile),
        ));
        edits.push(ConfigEdit::Root(
            "scrollback",
            self.config.scrollback.to_string(),
        ));
        edits.push(ConfigEdit::Behavior(
            "copy_on_select",
            self.config.behavior.copy_on_select.to_string(),
        ));
        edits.push(ConfigEdit::Behavior(
            "confirm_close",
            self.config.behavior.confirm_close.to_string(),
        ));
        edits.push(ConfigEdit::Behavior(
            "confirm_multiline_paste",
            self.config.behavior.confirm_multiline_paste.to_string(),
        ));
        edits.push(ConfigEdit::Render(
            "mouse",
            self.config.render.mouse.to_string(),
        ));
        match &self.config.render.font_face {
            Some(face) => edits.push(ConfigEdit::Render("font_face", format!("\"{face}\""))),
            None => edits.push(ConfigEdit::RemoveRender("font_face")),
        }
        let truecolor = match self.config.render.truecolor {
            TrueColorMode::Auto => "auto",
            TrueColorMode::Always => "always",
            TrueColorMode::Never => "never",
        };
        edits.push(ConfigEdit::Render("truecolor", format!("\"{truecolor}\"")));
        let gradient = match self.config.render.gradient {
            None => "off",
            Some(crate::render::GradientDir::Vertical) => "vertical",
            Some(crate::render::GradientDir::Horizontal) => "horizontal",
            Some(crate::render::GradientDir::Diagonal) => "diagonal",
        };
        edits.push(ConfigEdit::Render("gradient", format!("\"{gradient}\"")));
        for (key, value) in [
            ("gradient_top", self.config.render.gradient_top),
            ("gradient_bottom", self.config.render.gradient_bottom),
        ] {
            match value {
                Some(Color::Rgb(r, g, b)) => {
                    edits.push(ConfigEdit::Render(key, format!("\"#{r:02X}{g:02X}{b:02X}\"")))
                }
                _ => edits.push(ConfigEdit::RemoveRender(key)),
            }
        }
        if let Some(size) = self.config.render.font_size {
            edits.push(ConfigEdit::Render("font_size", size.to_string()));
        }
        match &self.config.render.background_image {
            Some(name) => edits.push(ConfigEdit::Render("background_image", quote_toml(name))),
            None => edits.push(ConfigEdit::RemoveRender("background_image")),
        }
        edits.push(ConfigEdit::Render(
            "background_image_opacity",
            self.config.render.background_image_opacity.to_string(),
        ));
        match self.config.save_edits(&self.config_path, &edits) {
            Ok(()) => {
                // 刚写过的文件不需要再热重载
                self.config_mtime = std::fs::metadata(&self.config_path)
                    .and_then(|m| m.modified())
                    .ok();
                self.set_status(format!("设置已保存：{}", self.config_path.display()));
            }
            Err(e) => self.set_status(format!("保存设置失败：{e}")),
        }
    }

    fn setting_value(&self, row: Row) -> String {
        match row {
            Row::Scheme => self.current_scheme_name(),
            Row::DefaultProfile => self.config.default_profile.clone(),
            Row::Gradient => settings::gradient_name(self.config.render.gradient).to_string(),
            Row::GradientPalette => {
                settings::PALETTES[settings::palette_index(&self.config)].0.to_string()
            }
            Row::TrueColor => settings::truecolor_name(self.config.render.truecolor).to_string(),
            Row::FontFace => {
                settings::FONT_FACES[settings::font_face_index(&self.config)].0.to_string()
            }
            Row::FontSize => self
                .config
                .render
                .font_size
                .map(|size| size.to_string())
                .unwrap_or_else(|| "默认".to_string()),
            Row::ProfileFont => match self.current_profile().and_then(|p| p.font_face.clone()) {
                None => "继承".to_string(),
                Some(face) => settings::FONT_FACES
                    .iter()
                    .find(|(_, preset)| preset.map(|preset| preset == face.as_str()).unwrap_or(false))
                    .map(|(label, _)| label.to_string())
                    .unwrap_or(face),
            },
            Row::ProfileFontSize => self
                .current_profile()
                .and_then(|profile| profile.font_size)
                .map(|size| size.to_string())
                .unwrap_or_else(|| "继承".to_string()),
            Row::ProfileGradient => {
                let value = self
                    .current_profile()
                    .map(|profile| profile.gradient)
                    .unwrap_or_default();
                settings::profile_gradient_name(value).to_string()
            }
            Row::ProfileGradientPalette => match self
                .current_profile()
                .and_then(|profile| settings::profile_palette_index(profile))
            {
                Some(0) => "继承".to_string(),
                Some(index) => settings::PALETTES[index].0.to_string(),
                None => "自定义".to_string(),
            },
            Row::ProfileTabColor => settings::tab_color_name(
                self.current_profile().and_then(|profile| profile.tab_color),
            ),
            Row::Scrollback => self.config.scrollback.to_string(),
            Row::Mouse => if self.config.render.mouse { "开" } else { "关" }.to_string(),
            Row::CopyOnSelect => if self.config.behavior.copy_on_select {
                "开"
            } else {
                "关"
            }
            .to_string(),
            Row::ConfirmClose => if self.config.behavior.confirm_close {
                "开"
            } else {
                "关"
            }
            .to_string(),
            Row::ConfirmPaste => if self.config.behavior.confirm_multiline_paste {
                "开"
            } else {
                "关"
            }
            .to_string(),
            Row::BackgroundImage => match &self.config.render.background_image {
                None => "无".to_string(),
                Some(name) => std::path::Path::new(name)
                    .file_name()
                    .and_then(|n| n.to_str())
                    .map(str::to_string)
                    .unwrap_or_else(|| name.clone()),
            },
            Row::BackgroundOpacity => {
                format!("{}%", self.config.render.background_image_opacity)
            }
        }
    }

    fn refresh_search(&mut self) {
        let Some(Overlay::Search(state)) = &self.overlay else {
            return;
        };
        let query = state.query.clone();
        let matches = self.focused_pane().map(|pane| {
            let rows = collect_rows(pane);
            search::find_matches(&rows, &query)
        });
        if let Some(Overlay::Search(state)) = &mut self.overlay {
            state.matches = matches.unwrap_or_default();
            state.current = 0;
        }
        let hit = match &self.overlay {
            Some(Overlay::Search(s)) => s.current_hit(),
            _ => None,
        };
        self.focus_search_hit(hit);
    }

    fn focus_search_hit(&mut self, hit: Option<search::MatchHit>) {
        let Some(hit) = hit else {
            return;
        };
        if let Some(pane) = self.focused_pane_mut() {
            let visible = pane.screen.rows.max(1);
            let total = pane.screen.history_len() + pane.screen.rows;
            let offset = total.saturating_sub(visible + hit.row);
            pane.scroll_offset = offset.min(pane.screen.history_len());
        }
    }

    // ---------- 动作 ----------

    pub fn execute(&mut self, action: Action) {
        match action {
            Action::NewTab => self.new_tab(),
            Action::NewTabWithProfile => {
                if !self.config.profiles.is_empty() {
                    self.overlay = Some(Overlay::ProfilePicker { selected: 0 });
                }
            }
            Action::CloseTab => self.close_tab(),
            Action::NextTab => self.next_tab(),
            Action::PrevTab => self.prev_tab(),
            Action::SelectTab(index) => {
                if index < self.tabs.len() {
                    self.activate_tab(index);
                }
            }
            Action::LastTab => {
                if !self.tabs.is_empty() {
                    self.activate_tab(self.tabs.len() - 1);
                }
            }
            Action::RenameTab => {
                let current = self
                    .active_tab()
                    .map(|t| t.title.clone())
                    .unwrap_or_default();
                self.overlay = Some(Overlay::Rename { text: current });
            }
            Action::SplitPane(axis) => self.split_focused(axis),
            Action::ClosePane => self.close_focused_pane(),
            Action::FocusPane(dir) => self.focus_direction(dir),
            Action::TogglePaneZoom => self.toggle_pane_zoom(),
            Action::SwapPane(dir) => self.swap_focused_pane(dir),
            Action::MovePaneToNewTab => self.move_focused_pane_to_new_tab(),
            Action::ResizePane(dir) => self.resize_focused_pane(dir),
            Action::CommandPalette => {
                self.overlay = Some(Overlay::Palette(PaletteState::new()));
            }
            Action::Settings => {
                self.overlay = Some(Overlay::Settings(SettingsState::new(&self.config)));
            }
            Action::Search => {
                self.overlay = Some(Overlay::Search(SearchState::new()));
            }
            Action::MarkMode => self.toggle_mark_mode(),
            Action::ScrollUp => self.scroll_focused(1),
            Action::ScrollDown => self.scroll_focused(-1),
            Action::ScrollPageUp => {
                let step = self.content_rect().h.saturating_sub(2).max(1) as isize;
                self.scroll_focused(step);
            }
            Action::ScrollPageDown => {
                let step = self.content_rect().h.saturating_sub(2).max(1) as isize;
                self.scroll_focused(-step);
            }
            Action::ScrollBottom => self.scroll_to_bottom(),
            Action::PromptUp => self.jump_prompt(true),
            Action::PromptDown => self.jump_prompt(false),
            Action::PromptFirst => self.jump_prompt_edge(true),
            Action::PromptLast => self.jump_prompt_edge(false),
            Action::Copy => self.copy_selection(),
            Action::Paste => self.paste_clipboard(),
            Action::ReloadConfig => self.reload_config(),
            Action::Quit => self.quit = true,
        }
    }

    /// Ctrl+Shift+V：把剪贴板文本发给聚焦窗格（应用开启括号粘贴时自动包裹）。
    ///
    /// 含换行的内容先弹确认（`behavior.confirm_multiline_paste`），避免误执行多行命令。
    fn paste_clipboard(&mut self) {
        let Some(text) = crate::platform::clipboard::get_text() else {
            self.set_status("剪贴板中没有文本".to_string());
            return;
        };
        let normalized = crate::platform::clipboard::normalize_newlines(&text);
        let bracketed = self
            .focused_pane()
            .map(|pane| pane.screen.bracketed_paste)
            .unwrap_or(false);
        if self.config.behavior.confirm_multiline_paste && normalized.contains('\n') {
            let lines = normalized.lines().count().max(1);
            let preview: String = normalized
                .lines()
                .next()
                .unwrap_or("")
                .chars()
                .take(48)
                .collect();
            self.overlay = Some(Overlay::Confirm {
                prompt: format!("粘贴 {lines} 行？首行：{preview}"),
                action: ConfirmAction::Paste {
                    text: normalized,
                    bracketed,
                },
            });
            return;
        }
        self.send_paste(normalized, bracketed);
    }

    fn send_paste(&mut self, normalized: String, bracketed: bool) {
        let mut bytes = Vec::new();
        if bracketed {
            bytes.extend_from_slice(b"\x1b[200~");
        }
        bytes.extend_from_slice(normalized.as_bytes());
        if bracketed {
            bytes.extend_from_slice(b"\x1b[201~");
        }
        let pane_id = self.focused_pane_id();
        if let Some(pane) = self.focused_pane_mut() {
            pane.scroll_offset = 0;
        }
        let data = msg::PaneData {
            pane_id,
            data: bytes,
        };
        let _ = self.tx.send(proto::encode(FrameType::Input, &data.encode()));
        self.set_status(format!("已粘贴 {} 个字符", normalized.chars().count()));
    }

    pub fn reload_config(&mut self) {
        let config = Config::load();
        let (registry, mut warnings) = Registry::from_config(&config.action_bindings);
        warnings.extend(config.warnings.clone());
        for pane in self.panes.values_mut() {
            pane.scheme = config
                .profile(&pane.profile)
                .map(|p| config.scheme_for_profile(p))
                .unwrap_or_default();
            pane.screen.set_history_limit(config.scrollback);
            pane.scroll_offset = pane.scroll_offset.min(pane.screen.history_len());
        }
        self.config = config;
        self.registry = registry;
        self.warnings = warnings;
        self.background = None;
        self.config_mtime = std::fs::metadata(&self.config_path)
            .and_then(|m| m.modified())
            .ok();
        self.renderer.invalidate();
        self.set_status("配置已重载".to_string());
        self.apply_active_profile_font();
    }

    // ---------- 绘制 ----------

    pub fn paint(&mut self) -> Vec<u8> {
        self.tick();
        let cols = self.cols.max(1);
        let rows = self.rows.max(1);
        let mut canvas = vec![Cell::default(); cols * rows];

        self.draw_tab_bar(&mut canvas, cols);
        self.draw_panes(&mut canvas, cols, rows);
        self.draw_status_bar(&mut canvas, cols);
        self.draw_overlay(&mut canvas, cols, rows);
        let cursor = self.cursor_position(cols, rows);

        let scheme = self
            .focused_pane()
            .map(|p| p.scheme.clone())
            .unwrap_or_default();
        self.renderer
            .set_scheme(scheme.foreground, scheme.background, scheme.ansi);
        self.renderer.set_truecolor(self.truecolor_enabled());
        // 渐变背景：把默认背景换成按位置取色的背景。必须写进画布，
        // 否则空白单元格与上一帧相同、不会被重画，渐变就只剩有文字的地方。
        let gradient = self.background_gradient(self.current_profile(), &scheme);
        self.refresh_background(cols, rows);
        let base = match scheme.background {
            Some(Color::Rgb(r, g, b)) => (r, g, b),
            _ => (0x0C, 0x0C, 0x0C),
        };
        let image = self
            .background
            .as_ref()
            .filter(|state| !state.sampled.is_empty())
            .map(|state| (state.sampled.as_slice(), state.opacity));
        if gradient.is_some() || image.is_some() {
            apply_background(&mut canvas, cols, rows, gradient.as_ref(), base, image);
        }

        let shape = self
            .focused_pane()
            .map(|p| p.screen.cursor_shape)
            .unwrap_or(0);
        self.renderer.paint(&canvas, cols, rows, cursor, shape)
    }

    pub fn truecolor_enabled(&self) -> bool {
        use crate::config::TrueColorMode;
        match self.config.render.truecolor {
            TrueColorMode::Always => true,
            TrueColorMode::Never => false,
            TrueColorMode::Auto => true,
        }
    }

    /// 由配置、profile 覆盖与配色方案生成本次的背景渐变。
    ///
    /// 控制台只能给单元格上色，所以是逐行（或逐列）的阶梯式平滑渐变；
    /// profile 未写的键沿用全局 `[render]`，默认从配色背景「顶部微亮」过渡到「底部更深」。
    fn background_gradient(
        &self,
        profile: Option<&Profile>,
        scheme: &crate::config::ColorScheme,
    ) -> Option<Gradient> {
        let dir = match profile.map(|profile| profile.gradient) {
            Some(GradientOverride::Off) => None,
            Some(GradientOverride::Dir(dir)) => Some(dir),
            Some(GradientOverride::Inherit) | None => self.config.render.gradient,
        };
        let dir = dir?;
        let base = match scheme.background {
            Some(Color::Rgb(r, g, b)) => (r, g, b),
            _ => (0x0C, 0x0C, 0x0C),
        };
        let profile_top = profile.and_then(|profile| profile.gradient_top);
        let profile_bottom = profile.and_then(|profile| profile.gradient_bottom);
        let from = match profile_top.or(self.config.render.gradient_top) {
            Some(Color::Rgb(r, g, b)) => (r, g, b),
            _ => tint(base, 255, 0.14),
        };
        let to = match profile_bottom.or(self.config.render.gradient_bottom) {
            Some(Color::Rgb(r, g, b)) => (r, g, b),
            _ => tint(base, 0, 0.30),
        };
        Some(Gradient::new(from, to, dir))
    }

    /// 背景图片缓存：路径、网格尺寸或不透明度变化时才重新解码 / 采样。
    fn refresh_background(&mut self, cols: usize, rows: usize) {
        let Some(name) = self.config.render.background_image.clone() else {
            self.background = None;
            return;
        };
        let opacity = self.config.render.background_image_opacity;
        let needs = match &self.background {
            Some(state) => {
                state.name != name
                    || state.cols != cols
                    || state.rows != rows
                    || state.opacity != opacity
            }
            None => true,
        };
        if !needs {
            return;
        }
        let (image, fresh) = match self.background.take() {
            Some(state) if state.name == name => (state.image, false),
            _ => (
                crate::platform::gdiplus::load(&Config::resolve_background(&name)),
                true,
            ),
        };
        if fresh && image.is_none() {
            let reason = if crate::platform::gdiplus::available() {
                "文件不存在或格式不支持"
            } else {
                "此系统缺少 gdiplus.dll"
            };
            self.set_status(format!("背景图片无法加载（{reason}）：{name}"));
        }
        let sampled = image
            .as_ref()
            .map(|img| {
                crate::platform::gdiplus::cover_cells(img, cols, rows)
                    .into_iter()
                    .map(|(r, g, b)| Color::Rgb(r, g, b))
                    .collect()
            })
            .unwrap_or_default();
        self.background = Some(BackgroundState {
            name,
            image,
            sampled,
            cols,
            rows,
            opacity,
        });
    }

    fn draw_tab_bar(&mut self, canvas: &mut [Cell], cols: usize) {
        let attrs = Attrs {
            fg: Color::Indexed(7),
            bg: Color::Indexed(8),
            flags: 0,
        };
        let active_attrs = Attrs {
            fg: Color::Indexed(0),
            bg: Color::Indexed(7),
            flags: ATTR_BOLD,
        };
        for x in 0..cols {
            canvas[x] = Cell { ch: ' ', attrs, link: 0,         combining: 0 };
        }
        let mut x;
        for (index, (start, _width)) in self.tab_segments().into_iter().enumerate() {
            let label = tab_label(index, &self.tabs[index]);
            let base = if index == self.active { active_attrs } else { attrs };
            // 配了 tab_color 的 profile：整段用该颜色当底色，并选对比色前景。
            let color = self.tab_color_for(index);
            let style = match color {
                Some(bg) => Attrs {
                    fg: contrast_color(bg),
                    bg,
                    flags: if index == self.active { ATTR_BOLD } else { 0 },
                },
                None => base,
            };
            x = start;
            for ch in label.chars() {
                let w = char_width(ch).max(1);
                if x + w > cols {
                    break;
                }
                put(canvas, cols, x, 0, ch, style);
                x += w;
            }
            // 关闭按钮：独立的 3 列区域，整块可点，中间画「×」。
            let close_start = start + cells_width(&label);
            let close_fg = if index == self.active && color.is_none() {
                Color::Indexed(1)
            } else {
                Color::Indexed(9)
            };
            let close_style = Attrs {
                fg: close_fg,
                bg: style.bg,
                flags: 0,
            };
            for offset in 0..TAB_CLOSE_WIDTH {
                let column = close_start + offset;
                if column >= cols {
                    break;
                }
                if offset == TAB_CLOSE_WIDTH / 2 {
                    put(canvas, cols, column, 0, '×', close_style);
                } else {
                    put(canvas, cols, column, 0, ' ', style);
                }
            }
            if x >= cols {
                break;
            }
        }
        let plus = self.tab_bar_plus_x(cols);
        if let Some(plus) = plus {
            // 「+」做成 3 列宽的绿色按钮，和标签明显分开。
            let plus_attrs = Attrs {
                fg: Color::Indexed(15),
                bg: Color::Indexed(2),
                flags: ATTR_BOLD,
            };
            for offset in 0..TAB_PLUS_WIDTH {
                let column = plus + offset;
                if column >= cols {
                    break;
                }
                if offset == TAB_PLUS_WIDTH / 2 {
                    put(canvas, cols, column, 0, '+', plus_attrs);
                } else {
                    put(canvas, cols, column, 0, ' ', plus_attrs);
                }
            }
        }
    }

    /// 底部状态栏：左侧常驻快捷键提示，右侧临时状态/回看偏移/当前目录。
    fn draw_status_bar(&mut self, canvas: &mut [Cell], cols: usize) {
        let rows = self.rows.max(1);
        let y = self.status_bar_y();
        let attrs = Attrs {
            fg: Color::Indexed(7),
            bg: Color::Indexed(8),
            flags: 0,
        };
        for x in 0..cols {
            put(canvas, cols, x, y, ' ', attrs);
        }

        // 左侧提示：整段放不下时退到最短提示并截断。
        let hint = self
            .status_hint(cols)
            .map(str::to_string)
            .unwrap_or_else(|| truncate_right(TAB_HINTS[2], cols));
        let hint_width = cells_width(&hint);
        if hint_width > 0 {
            let hint_attrs = Attrs {
                fg: Color::Indexed(14),
                bg: Color::Indexed(8),
                flags: 0,
            };
            put_str(canvas, cols, rows, 0, y, &hint, hint_attrs, hint_width);
        }

        // 右侧状态：空间不够时从左侧截断，保证结尾（目录/状态）可见。
        let right_room = cols.saturating_sub(hint_width + 1);
        let mut right = self.status_text(cols);
        if hint_width > 0 && cells_width(&right) > right_room {
            right = if right_room >= 2 {
                truncate_left(&right, right_room)
            } else {
                String::new()
            };
        }
        if !right.is_empty() {
            let width: usize = right.chars().map(|c| char_width(c).max(1)).sum();
            let start = cols.saturating_sub(width);
            let attrs = Attrs {
                fg: Color::Indexed(11),
                bg: Color::Indexed(8),
                flags: 0,
            };
            let mut offset = 0usize;
            for ch in right.chars() {
                let w = char_width(ch).max(1);
                if start + offset + w > cols {
                    break;
                }
                put(canvas, cols, start + offset, y, ch, attrs);
                offset += w;
            }
        }
    }

    fn draw_panes(&mut self, canvas: &mut [Cell], cols: usize, rows: usize) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        let focus = tab.focus;
        let Some((panes, seps)) = self.pane_layout() else {
            return;
        };
        let _ = rows;

        let search_matches = match &self.overlay {
            Some(Overlay::Search(state)) => Some((state.matches.clone(), state.current)),
            _ => None,
        };

        for (id, rect) in &panes {
            let Some(pane) = self.panes.get(id) else {
                continue;
            };
            let is_focus = *id == focus;
            let selection = self.selection.filter(|sel| sel.pane == *id);
            self.draw_pane_cells(
                canvas,
                cols,
                *rect,
                pane,
                is_focus,
                search_matches.as_ref(),
                selection,
            );
            self.draw_scrollbar(canvas, cols, *id, *rect, pane);
        }

        // 分隔线：与聚焦窗格相邻的用高亮色
        let accent = Attrs {
            fg: Color::Indexed(12),
            bg: Color::Default,
            flags: 0,
        };
        let dim = Attrs {
            fg: Color::Indexed(8),
            bg: Color::Default,
            flags: 0,
        };
        for sep in seps {
            let near_focus = panes
                .iter()
                .any(|(id, r)| *id == focus && adjacent(r, &sep));
            let attrs = if near_focus { accent } else { dim };
            if sep.w == 1 {
                for y in sep.y..sep.bottom() {
                    put(canvas, cols, sep.x, y, '│', attrs);
                }
            } else {
                for x in sep.x..sep.right() {
                    put(canvas, cols, x, sep.y, '─', attrs);
                }
            }
        }
    }

    fn draw_pane_cells(
        &self,
        canvas: &mut [Cell],
        cols: usize,
        rect: Rect,
        pane: &PaneState,
        focused: bool,
        search_matches: Option<&(Vec<search::MatchHit>, usize)>,
        selection: Option<Selection>,
    ) {
        let visible = rect.h.min(pane.screen.rows.max(1));
        let total = pane.screen.history_len() + pane.screen.rows;
        let start = total
            .saturating_sub(visible + pane.scroll_offset)
            .min(pane.screen.history_len().saturating_add(pane.screen.rows));

        for y in 0..visible {
            let abs_row = start + y;
            let source: &[Cell] = if abs_row < pane.screen.history_len() {
                pane.screen.history_row(abs_row).unwrap_or(&[])
            } else {
                let screen_row = abs_row - pane.screen.history_len();
                pane.screen.row(screen_row).unwrap_or(&[])
            };
            for x in 0..rect.w {
                let mut cell = source.get(x).copied().unwrap_or_default();
                if let Some((hits, current)) = search_matches {
                    for (index, hit) in hits.iter().enumerate() {
                        if hit.row == abs_row
                            && x >= hit.col
                            && x < hit.col + hit.len
                        {
                            cell.attrs.flags |= ATTR_REVERSE;
                            if index == *current {
                                cell.attrs.flags |= ATTR_BOLD;
                            }
                        }
                    }
                }
                if let Some(selection) = selection {
                    if selection_contains(&selection, abs_row, x) {
                        cell.attrs.flags |= ATTR_REVERSE;
                    }
                }
                // OSC 8 链接：下划线提示可点击（Ctrl+点击打开）。
                if cell.link != 0 {
                    cell.attrs.flags |= ATTR_UNDERLINE;
                }
                put(canvas, cols, rect.x + x, rect.y + y, cell.ch, cell.attrs);
            }
        }
        if let Some(code) = pane.exited {
            let text = format!(" [进程已退出，退出码 {code}] ");
            let y = rect.bottom().saturating_sub(1);
            let attrs = Attrs {
                fg: Color::Indexed(15),
                bg: Color::Indexed(4),
                flags: 0,
            };
            for (i, ch) in text.chars().enumerate() {
                let x = rect.x + i;
                if x < rect.right() && i < rect.w {
                    put(canvas, cols, x, y, ch, attrs);
                }
            }
        }
        let _ = focused;
    }

    /// 窗格右边缘的滚动条：淡色轨道 + 高亮拇指，表示回看在整段历史里的位置。
    fn draw_scrollbar(
        &self,
        canvas: &mut [Cell],
        cols: usize,
        id: u32,
        rect: Rect,
        pane: &PaneState,
    ) {
        if !self.scrollbar_visible(id, rect, pane) {
            return;
        }
        let (thumb_h, shift) = scrollbar_geometry(rect.h, pane.screen.history_len(), pane.scroll_offset);
        let track = Attrs {
            fg: Color::Indexed(8),
            bg: Color::Default,
            flags: 0,
        };
        let thumb = Attrs {
            fg: Color::Indexed(12),
            bg: Color::Default,
            flags: 0,
        };
        let x = rect.right() - 1;
        for row in 0..rect.h {
            let in_thumb = row >= shift && row < shift + thumb_h;
            let (ch, attrs) = if in_thumb {
                ('█', thumb)
            } else {
                ('│', track)
            };
            put(canvas, cols, x, rect.y + row, ch, attrs);
        }
    }

    fn draw_overlay(&mut self, canvas: &mut [Cell], cols: usize, rows: usize) {
        let border = Attrs {
            fg: Color::Indexed(12),
            bg: Color::Indexed(0),
            flags: 0,
        };
        let text_attrs = Attrs {
            fg: Color::Indexed(15),
            bg: Color::Indexed(0),
            flags: 0,
        };
        let selected_attrs = Attrs {
            fg: Color::Indexed(0),
            bg: Color::Indexed(12),
            flags: ATTR_BOLD,
        };

        match &self.overlay {
            Some(Overlay::Palette(state)) => {
                let items = palette::filter(&self.registry, &state.query, &self.profile_names());
                let width = 60.min(cols.saturating_sub(2)).max(20);
                let height = (items.len().min(12) + 3).min(rows.saturating_sub(2)).max(4);
                let x = (cols.saturating_sub(width)) / 2;
                let y = 2.min(rows.saturating_sub(height));
                draw_box(canvas, cols, rows, Rect::new(x, y, width, height), border);
                put_str(
                    canvas,
                    cols,
                    rows,
                    x + 2,
                    y,
                    " 命令面板 ",
                    border,
                    width.saturating_sub(4),
                );
                put_str(
                    canvas,
                    cols,
                    rows,
                    x + 2,
                    y + 1,
                    &format!("> {}", state.query),
                    text_attrs,
                    width.saturating_sub(4),
                );
                for (i, item) in items.iter().take(height.saturating_sub(3)).enumerate() {
                    let attrs = if i == state.selected {
                        selected_attrs
                    } else {
                        text_attrs
                    };
                    let hint = item
                        .keys
                        .as_ref()
                        .map(|k| format!("  [{k}]"))
                        .unwrap_or_default();
                    let line = match &item.profile {
                        Some(profile) => format!(" {}. 新建标签页：{profile}", i + 1),
                        None => format!(" {}. {}{}", i + 1, item.action.name(), hint),
                    };
                    put_str(
                        canvas,
                        cols,
                        rows,
                        x + 1,
                        y + 2 + i,
                        &line,
                        attrs,
                        width.saturating_sub(2),
                    );
                }
            }
            Some(Overlay::Search(state)) => {
                let total = state.matches.len();
                let current = if total == 0 { 0 } else { state.current + 1 };
                let line = format!(
                    " 搜索: {}    {}/{}   [Enter 下一个 · Shift+Enter 上一个 · Esc 退出]",
                    state.query, current, total
                );
                let y = rows.saturating_sub(1);
                for x in 0..cols {
                    put(canvas, cols, x, y, ' ', text_attrs);
                }
                put_str(canvas, cols, rows, 0, y, &line, text_attrs, cols);
            }
            Some(Overlay::Rename { text }) => {
                let line = format!(" 重命名标签: {}_   [Enter 确认 · Esc 取消]", text);
                for x in 0..cols {
                    put(canvas, cols, x, 0, ' ', selected_attrs);
                }
                put_str(canvas, cols, rows, 0, 0, &line, selected_attrs, cols);
            }
            Some(Overlay::BackgroundPath { text, .. }) => {
                for x in 0..cols {
                    put(canvas, cols, x, 0, ' ', selected_attrs);
                }
                let line = truncate_left(&format!(" 背景图片路径: {text}_"), cols);
                put_str(canvas, cols, rows, 0, 0, &line, selected_attrs, cols);
                if rows > 3 {
                    let dir = Config::backgrounds_dir();
                    let hint = format!(
                        " Enter 确认 · Esc 返回设置 · 相对路径优先在 {} 里找（png/jpg/jpeg/bmp/gif）",
                        dir.display()
                    );
                    let hint = truncate_left(&hint, cols);
                    put_str(canvas, cols, rows, 0, 2, &hint, text_attrs, cols);
                }
            }
            Some(Overlay::Settings(state)) => {
                self.draw_settings_panel(canvas, cols, rows, state);
            }
            Some(Overlay::ProfilePicker { selected }) => {
                let names = &self.config.profiles;
                let width = 54.min(cols.saturating_sub(2)).max(24);
                let height = (names.len() + 4).min(rows.saturating_sub(2)).max(5);
                let x = cols.saturating_sub(width) / 2;
                let y = 2.min(rows.saturating_sub(height));
                draw_box(canvas, cols, rows, Rect::new(x, y, width, height), border);
                put_str(
                    canvas,
                    cols,
                    rows,
                    x + 2,
                    y,
                    " 新建标签页：选择 profile ",
                    border,
                    width.saturating_sub(4),
                );
                for (index, profile) in names.iter().take(height.saturating_sub(4)).enumerate() {
                    let style = if index == *selected {
                        selected_attrs
                    } else {
                        text_attrs
                    };
                    let marker = if index == *selected { ">" } else { " " };
                    let default = if profile.name == self.config.default_profile {
                        "（默认）"
                    } else {
                        ""
                    };
                    let line = format!("{marker} {}. {}{default}", index + 1, profile.name);
                    put_str(
                        canvas,
                        cols,
                        rows,
                        x + 2,
                        y + 1 + index,
                        &line,
                        style,
                        width.saturating_sub(4),
                    );
                }
                put_str(
                    canvas,
                    cols,
                    rows,
                    x + 2,
                    y + height - 2,
                    "↑↓ 选择 · 数字直达 · Enter 新建 · Esc 取消",
                    text_attrs,
                    width.saturating_sub(4),
                );
            }
            Some(Overlay::Confirm { prompt, .. }) => {
                let width = 62.min(cols.saturating_sub(2)).max(24);
                let height = 5.min(rows.saturating_sub(1)).max(3);
                let x = cols.saturating_sub(width) / 2;
                let y = rows.saturating_sub(height) / 2;
                draw_box(canvas, cols, rows, Rect::new(x, y, width, height), border);
                put_str(
                    canvas,
                    cols,
                    rows,
                    x + 2,
                    y,
                    " 确认 ",
                    border,
                    width.saturating_sub(4),
                );
                put_str(
                    canvas,
                    cols,
                    rows,
                    x + 2,
                    y + 1,
                    prompt,
                    text_attrs,
                    width.saturating_sub(4),
                );
                put_str(
                    canvas,
                    cols,
                    rows,
                    x + 2,
                    y + 2,
                    "Enter / Y 确认    Esc / N 取消",
                    selected_attrs,
                    width.saturating_sub(4),
                );
            }
            None => {}
        }
    }

    /// 设置面板的几何：绘制与鼠标命中共用。
    fn settings_panel_rect(cols: usize, rows: usize) -> Rect {
        let width = 76.min(cols.saturating_sub(2)).max(36);
        let height = (settings::ROWS.len() + 6).min(rows.saturating_sub(2)).max(8);
        let x = cols.saturating_sub(width) / 2;
        let y = 2.min(rows.saturating_sub(height));
        Rect::new(x, y, width, height)
    }

    /// 设置面板能显示的行数（底部留提示行）。
    fn settings_visible_rows(height: usize) -> usize {
        height.saturating_sub(5).max(1)
    }

    /// 让选中行始终可见的首行下标。
    fn settings_first_visible(selected: usize, height: usize) -> usize {
        let visible = Self::settings_visible_rows(height);
        let max_first = settings::ROWS.len().saturating_sub(visible);
        selected
            .saturating_sub(visible.saturating_sub(1))
            .min(max_first)
    }

    /// 设置面板：左列名称，右侧取值，选中行反色。
    fn draw_settings_panel(
        &self,
        canvas: &mut [Cell],
        cols: usize,
        rows: usize,
        state: &SettingsState,
    ) {
        let border = Attrs {
            fg: Color::Indexed(12),
            bg: Color::Indexed(0),
            flags: 0,
        };
        let text = Attrs {
            fg: Color::Indexed(15),
            bg: Color::Indexed(0),
            flags: 0,
        };
        let dim = Attrs {
            fg: Color::Indexed(8),
            bg: Color::Indexed(0),
            flags: 0,
        };
        let highlight = Attrs {
            fg: Color::Indexed(0),
            bg: Color::Indexed(12),
            flags: ATTR_BOLD,
        };

        let rect = Self::settings_panel_rect(cols, rows);
        let (x, y, width, height) = (rect.x, rect.y, rect.w, rect.h);
        draw_box(canvas, cols, rows, rect, border);
        let title = format!(" 设置 · {} ", self.current_profile_name());
        put_str(
            canvas,
            cols,
            rows,
            x + 2,
            y,
            &title,
            border,
            width.saturating_sub(4),
        );

        let visible = Self::settings_visible_rows(height);
        let first = Self::settings_first_visible(state.selected, height);
        for (index, row) in settings::ROWS
            .iter()
            .enumerate()
            .skip(first)
            .take(visible)
        {
            let ry = y + 2 + (index - first);
            if ry + 3 >= y + height {
                break;
            }
            let selected = index == state.selected;
            let style = if selected { highlight } else { text };
            if selected {
                for cx in (x + 1)..(x + width - 1) {
                    put(canvas, cols, cx, ry, ' ', style);
                }
            }
            let marker = if selected { ">" } else { " " };
            put_str(canvas, cols, rows, x + 2, ry, marker, style, 1);
            put_str(
                canvas,
                cols,
                rows,
                x + 4,
                ry,
                row.label(),
                style,
                width.saturating_sub(6),
            );
            let value = self.setting_value(*row);
            put_str(
                canvas,
                cols,
                rows,
                x + width.saturating_sub(30),
                ry,
                &value,
                style,
                26,
            );
            put_str(canvas, cols, rows, x + width - 4, ry, "‹ ›", style, 3);
        }

        let hint = settings::ROWS[state.selected.min(settings::ROWS.len() - 1)].hint();
        put_str(
            canvas,
            cols,
            rows,
            x + 2,
            y + height - 3,
            hint,
            dim,
            width.saturating_sub(4),
        );
        put_str(
            canvas,
            cols,
            rows,
            x + 2,
            y + height - 2,
            "↑↓ 选择   ←→/点右侧改值   点行/滚轮换行   Enter 保存   Esc 取消",
            text,
            width.saturating_sub(4),
        );
    }

    fn cursor_position(&self, cols: usize, rows: usize) -> Option<(usize, usize)> {
        if self.overlay.is_some() {
            return None;
        }
        let tab = self.active_tab()?;
        let pane = self.panes.get(&tab.focus)?;
        if pane.scroll_offset > 0 || !pane.screen.cursor_visible {
            return None;
        }
        let (panes, _) = compute(&tab.tree, self.content_rect());
        let rect = panes.iter().find(|(id, _)| *id == tab.focus)?.1;
        let x = rect.x + pane.screen.cursor_x;
        let y = rect.y + pane.screen.cursor_y;
        if x < cols && y < rows {
            Some((x, y))
        } else {
            None
        }
    }

}

/// 取某个绝对行（回看缓冲 + 屏幕）的单元格。
fn absolute_row_cells(pane: &PaneState, row: usize) -> Vec<Cell> {
    let history = pane.screen.history_len();
    if row < history {
        pane.screen
            .history_row(row)
            .map(|cells| cells.to_vec())
            .unwrap_or_default()
    } else {
        pane.screen
            .row(row - history)
            .map(|cells| cells.to_vec())
            .unwrap_or_default()
    }
}

fn is_word_char(ch: char) -> bool {
    ch.is_alphanumeric() || matches!(ch, '_' | '-' | '.' | '\\' | '/' | ':' | '@' | '~' | '+')
}

/// 判断 (行, 列) 是否落在选区内。
fn selection_contains(selection: &Selection, row: usize, column: usize) -> bool {
    if selection.block {
        let (left, top, right, bottom) = selection.block_bounds();
        return row >= top && row <= bottom && column >= left && column <= right;
    }
    let (start, end) = selection.ordered();
    if row < start.1 || row > end.1 {
        return false;
    }
    if row == start.1 && column < start.0 {
        return false;
    }
    if row == end.1 && column > end.0 {
        return false;
    }
    true
}

fn collect_rows(pane: &PaneState) -> Vec<Vec<char>> {
    let mut rows = Vec::with_capacity(pane.screen.history_len() + pane.screen.rows);
    for i in 0..pane.screen.history_len() {
        if let Some(row) = pane.screen.history_row(i) {
            rows.push(row.iter().map(|c| c.ch).collect());
        }
    }
    for y in 0..pane.screen.rows {
        if let Some(row) = pane.screen.row(y) {
            rows.push(row.iter().map(|c| c.ch).collect());
        }
    }
    rows
}

fn adjacent(pane: &Rect, sep: &Rect) -> bool {
    if sep.w == 1 {
        let vertical_overlap = pane.y < sep.bottom() && sep.y < pane.bottom();
        vertical_overlap && (pane.right() == sep.x || pane.x == sep.x + 1)
    } else {
        let horizontal_overlap = pane.x < sep.right() && sep.x < pane.right();
        horizontal_overlap && (pane.bottom() == sep.y || pane.y == sep.y + 1)
    }
}

/// 命中坐标所在的窗格。
fn pane_at(panes: &[(u32, Rect)], x: usize, y: usize) -> Option<(u32, Rect)> {
    panes
        .iter()
        .find(|(_, rect)| x >= rect.x && x < rect.right() && y >= rect.y && y < rect.bottom())
        .copied()
}

/// 写一个字符到画布；宽字符会同时标记右半格，保证渲染器与终端列宽一致。
fn put(canvas: &mut [Cell], cols: usize, x: usize, y: usize, ch: char, attrs: Attrs) {
    let rows = canvas.len() / cols.max(1);
    if x >= cols || y >= rows {
        return;
    }
    let base = y * cols + x;
    let width = char_width(ch);
    if width == 2 && x + 1 >= cols {
        // 宽字符放不下：退化成空格，避免把行尾撑爆。
        canvas[base] = Cell {
            ch: ' ',
            attrs,
            link: 0,
            combining: 0,
        };
        return;
    }
    canvas[base] = Cell {
        ch,
        attrs,
        link: 0,
        combining: 0,
    };
    if width == 2 {
        let mut tail = attrs;
        tail.flags |= ATTR_WIDE_TAIL;
        canvas[base + 1] = Cell {
            ch: ' ',
            attrs: tail,
            link: 0,
            combining: 0,
        };
    }
}

fn put_str(
    canvas: &mut [Cell],
    cols: usize,
    rows: usize,
    x: usize,
    y: usize,
    text: &str,
    attrs: Attrs,
    max_width: usize,
) {
    if y >= rows {
        return;
    }
    let mut offset = 0usize;
    for ch in text.chars() {
        let width = char_width(ch).max(1);
        if offset + width > max_width {
            break;
        }
        put(canvas, cols, x + offset, y, ch, attrs);
        offset += width;
    }
}

/// 标签末尾关闭按钮占用的列数（中间是「×」，两侧留白方便点击）。
const TAB_CLOSE_WIDTH: usize = 3;
/// 「+」新建按钮占用的列数（中间是「+」）。
const TAB_PLUS_WIDTH: usize = 3;

/// 标签栏空白处的快捷键提示，从长到短，放不下就退到下一档。
const TAB_HINTS: [&str; 3] = [
    "Ctrl+B 新建 · Ctrl+Shift+W 关闭 · Ctrl+Tab 切换 · Ctrl+1~9 直达 · Ctrl+S 设置",
    "Ctrl+B 新建 · Ctrl+Shift+W 关闭 · Ctrl+S 设置",
    "Ctrl+B 新建 · Ctrl+S 设置",
];

/// 标签页标题：`序号:名称`，后台标签追加状态标记（`!` 响铃、`✓` 成功、`✗码` 失败）。
fn tab_label(index: usize, tab: &Tab) -> String {
    let mut mark = String::new();
    if tab.bell {
        mark.push_str(" !");
    } else if let Some(code) = tab.last_exit {
        if code == 0 {
            mark.push_str(" ✓");
        } else {
            mark.push_str(&format!(" ✗{code}"));
        }
    }
    format!(" {}:{}{} ", index + 1, tab.title, mark)
}

/// 选一个在给定底色上清晰可读的前景色（深底用亮字，浅底用黑字）。
fn contrast_color(bg: Color) -> Color {
    let light = match bg {
        Color::Default => false,
        Color::Indexed(index) => index >= 8,
        Color::Rgb(r, g, b) => {
            0.2126 * r as f32 + 0.7152 * g as f32 + 0.0722 * b as f32 > 140.0
        }
    };
    if light {
        Color::Indexed(0)
    } else {
        Color::Indexed(15)
    }
}

/// 把字符串包成 TOML 双引号值：转义反斜杠与引号，Windows 路径才能原样读回。
fn quote_toml(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            _ => out.push(ch),
        }
    }
    out.push('"');
    out
}

/// 背景合成：渐变（或纯色）打底，再按不透明度把图片采样叠上去。
///
/// 只处理 `bg == Color::Default` 的单元格，程序显式设置的底色（标签栏、
/// 命令面板、提示条）保持原样。
fn apply_background(
    canvas: &mut [Cell],
    cols: usize,
    rows: usize,
    gradient: Option<&Gradient>,
    base: (u8, u8, u8),
    image: Option<(&[Color], u8)>,
) {
    if cols == 0 || rows == 0 {
        return;
    }
    for y in 0..rows {
        for x in 0..cols {
            let index = y * cols + x;
            let Some(cell) = canvas.get_mut(index) else {
                return;
            };
            if cell.attrs.bg != Color::Default {
                continue;
            }
            let mut color = match gradient.map(|g| g.at(x, y, cols, rows)) {
                Some(Color::Rgb(r, g, b)) => (r, g, b),
                _ => base,
            };
            if let Some((pixels, opacity)) = image {
                if let Some(Color::Rgb(r, g, b)) = pixels.get(index) {
                    color = blend(color, (*r, *g, *b), opacity);
                }
            }
            cell.attrs.bg = Color::Rgb(color.0, color.1, color.2);
        }
    }
}

/// 按百分比把 `top` 叠到 `bottom` 上（0 = 全 bottom，100 = 全 top）。
fn blend(bottom: (u8, u8, u8), top: (u8, u8, u8), percent: u8) -> (u8, u8, u8) {
    let p = percent.min(100) as u32;
    let mix = |a: u8, b: u8| ((a as u32 * (100 - p) + b as u32 * p) / 100) as u8;
    (mix(bottom.0, top.0), mix(bottom.1, top.1), mix(bottom.2, top.2))
}

/// 滚动条几何：返回 (拇指高度, 拇指距轨道顶部的行数)。
///
/// `offset` 为回看行数（0 = 最新输出，`history` = 最早），拇指随之从底部移到顶部。
fn scrollbar_geometry(visible: usize, history: usize, offset: usize) -> (usize, usize) {
    let visible = visible.max(1);
    let total = visible + history;
    let thumb_h = (visible * visible / total.max(1)).clamp(1, visible);
    let avail = visible - thumb_h;
    if history == 0 || avail == 0 {
        return (thumb_h, 0);
    }
    let shift = avail - (avail * offset.min(history) / history);
    (thumb_h, shift)
}

/// 保留开头的 `max_cells` 列（常驻提示被挤窄时用）。
fn truncate_right(text: &str, max_cells: usize) -> String {
    let mut out = String::new();
    let mut width = 0usize;
    for ch in text.chars() {
        let w = char_width(ch).max(1);
        if width + w > max_cells {
            break;
        }
        width += w;
        out.push(ch);
    }
    out
}

/// 截到 `max_cells` 列以内，超出时保留末尾（路径尾部更有信息量）并加 `…`。
fn truncate_left(text: &str, max_cells: usize) -> String {
    if cells_width(text) <= max_cells {
        return text.to_string();
    }
    let mut tail: Vec<char> = Vec::new();
    let mut width = 0usize;
    for ch in text.chars().rev() {
        let w = char_width(ch).max(1);
        if width + w + 1 > max_cells {
            break;
        }
        width += w;
        tail.push(ch);
    }
    tail.reverse();
    format!("…{}", tail.into_iter().collect::<String>())
}

/// 字符串在终端里占用的列数（CJK 占 2 列）。
fn cells_width(text: &str) -> usize {
    text.chars().map(|c| char_width(c).max(1)).sum()
}

fn draw_box(canvas: &mut [Cell], cols: usize, rows: usize, rect: Rect, attrs: Attrs) {
    if rect.w < 2 || rect.h < 2 {
        return;
    }
    for x in rect.x..rect.right() {
        put(canvas, cols, x, rect.y, '─', attrs);
        put(canvas, cols, x, rect.bottom() - 1, '─', attrs);
    }
    for y in rect.y..rect.bottom() {
        put(canvas, cols, rect.x, y, '│', attrs);
        put(canvas, cols, rect.right() - 1, y, '│', attrs);
    }
    put(canvas, cols, rect.x, rect.y, '┌', attrs);
    put(canvas, cols, rect.right() - 1, rect.y, '┐', attrs);
    put(canvas, cols, rect.x, rect.bottom() - 1, '└', attrs);
    put(canvas, cols, rect.right() - 1, rect.bottom() - 1, '┘', attrs);
    for y in rect.y + 1..rect.bottom() - 1 {
        for x in rect.x + 1..rect.right() - 1 {
            put(canvas, cols, x, y, ' ', attrs);
        }
    }
    let _ = rows;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::action::{Chord, SplitAxis};
    use crate::config::Config;
    use crate::input::KeyEvent;
    use std::sync::mpsc;
    use std::sync::mpsc::Receiver;

    fn make_app() -> (App, Receiver<Vec<u8>>) {
        let (tx, rx) = mpsc::channel();
        let mut config = Config::default();
        // 多数测试关心关闭动作本身；确认框另有专门用例。
        config.behavior.confirm_close = false;
        config.behavior.confirm_multiline_paste = false;
        (App::new(config, 80, 24, tx), rx)
    }

    fn frames(rx: &Receiver<Vec<u8>>) -> Vec<(FrameType, Vec<u8>)> {
        let mut out = Vec::new();
        while let Ok(raw) = rx.try_recv() {
            let (ty, _len) = proto::decode_header(&raw[..12]).unwrap();
            out.push((ty, raw[12..].to_vec()));
        }
        out
    }

    #[test]
    fn starts_with_one_tab_and_one_pane() {
        let (app, rx) = make_app();
        assert_eq!(app.tabs.len(), 1);
        assert_eq!(app.panes.len(), 1);
        let sent = frames(&rx);
        assert!(sent.iter().any(|(ty, _)| *ty == FrameType::CreatePane));
    }

    #[test]
    fn split_creates_second_pane_and_moves_focus() {
        let (mut app, rx) = make_app();
        let _ = frames(&rx);
        app.split_focused(SplitAxis::Horizontal);
        assert_eq!(app.panes.len(), 2);
        let tab = app.active_tab().unwrap();
        assert_eq!(tab.tree.leaves().len(), 2);
        assert_eq!(tab.focus, 2, "新窗格应获得焦点");
        let sent = frames(&rx);
        assert!(sent.iter().any(|(ty, _)| *ty == FrameType::CreatePane));
        assert!(sent.iter().any(|(ty, _)| *ty == FrameType::Resize));
    }

    #[test]
    fn closing_last_pane_closes_tab() {
        let (mut app, _rx) = make_app();
        app.close_focused_pane();
        assert!(app.tabs.is_empty());
        assert!(app.quit, "最后一个标签页关闭后应退出");
    }

    #[test]
    fn closing_split_pane_restores_full_rect() {
        let (mut app, _rx) = make_app();
        app.split_focused(SplitAxis::Horizontal);
        app.close_focused_pane();
        assert_eq!(app.panes.len(), 1);
        let tab = app.active_tab().unwrap();
        let (panes, seps) = compute(&tab.tree, app.content_rect());
        assert_eq!(panes.len(), 1);
        assert!(seps.is_empty());
    }

    #[test]
    fn zoom_hides_other_panes_and_blocks_focus_moves() {
        let (mut app, _rx) = make_app();
        app.split_focused(SplitAxis::Horizontal);
        assert_eq!(app.pane_layout().unwrap().0.len(), 2);
        app.toggle_pane_zoom();
        assert!(app.active_tab().unwrap().zoom);
        let (panes, seps) = app.pane_layout().unwrap();
        assert_eq!(panes.len(), 1, "放大时只显示聚焦窗格");
        assert_eq!(panes[0], (app.focused_pane_id(), app.content_rect()));
        assert!(seps.is_empty());
        // 放大期间焦点不随方向键移动
        let focus = app.focused_pane_id();
        app.focus_direction(Direction::Left);
        assert_eq!(app.focused_pane_id(), focus);
        // 还原后两个窗格回来
        app.toggle_pane_zoom();
        assert_eq!(app.pane_layout().unwrap().0.len(), 2);
    }

    #[test]
    fn single_pane_does_not_zoom() {
        let (mut app, _rx) = make_app();
        app.toggle_pane_zoom();
        assert!(!app.active_tab().unwrap().zoom);
    }

    #[test]
    fn swapping_pane_moves_it_and_keeps_focus() {
        let (mut app, _rx) = make_app();
        app.split_focused(SplitAxis::Horizontal);
        let (before, _) = compute(&app.active_tab().unwrap().tree, app.content_rect());
        assert_eq!(before[0].0, 1, "窗格 1 在左侧");
        let focus = app.focused_pane_id();
        assert_eq!(focus, 2);
        app.swap_focused_pane(Direction::Left);
        assert_eq!(app.active_tab().unwrap().tree.leaves(), vec![2, 1]);
        assert_eq!(app.focused_pane_id(), focus, "焦点应跟随原窗格内容");
    }

    #[test]
    fn moving_pane_to_new_tab_keeps_it_alive() {
        let (mut app, rx) = make_app();
        app.split_focused(SplitAxis::Horizontal);
        let _ = frames(&rx);
        let moved = app.focused_pane_id();
        app.move_focused_pane_to_new_tab();
        assert_eq!(app.tabs.len(), 2);
        assert_eq!(app.active, 1);
        assert_eq!(app.panes.len(), 2, "移走窗格不应关闭进程");
        assert_eq!(app.tabs[0].tree.leaves(), vec![1]);
        assert_eq!(app.tabs[0].focus, 1);
        assert_eq!(app.tabs[1].tree.leaves(), vec![moved]);
        assert_eq!(app.tabs[1].focus, moved);
        let sent = frames(&rx);
        assert!(
            !sent.iter().any(|(ty, _)| *ty == FrameType::ClosePane),
            "移动不是关闭"
        );
    }

    #[test]
    fn resizing_pane_changes_split_ratio() {
        let (mut app, _rx) = make_app();
        app.split_focused(SplitAxis::Horizontal);
        let (before, _) = compute(&app.active_tab().unwrap().tree, app.content_rect());
        let left = before[0].1.w;
        app.resize_focused_pane(Direction::Left);
        let (after, _) = compute(&app.active_tab().unwrap().tree, app.content_rect());
        assert!(after[0].1.w < left, "向左调整应让左窗格变窄");
        app.resize_focused_pane(Direction::Right);
        let (back, _) = compute(&app.active_tab().unwrap().tree, app.content_rect());
        assert_eq!(back[0].1.w, left, "反向调整应恢复原比例");
    }

    #[test]
    fn split_clears_zoom() {
        let (mut app, _rx) = make_app();
        app.split_focused(SplitAxis::Horizontal);
        app.toggle_pane_zoom();
        app.split_focused(SplitAxis::Vertical);
        assert!(!app.active_tab().unwrap().zoom);
        assert_eq!(app.pane_layout().unwrap().0.len(), 3);
    }

    #[test]
    fn tab_navigation_wraps() {
        let (mut app, _rx) = make_app();
        app.new_tab();
        assert_eq!(app.tabs.len(), 2);
        assert_eq!(app.active, 1);
        app.next_tab();
        assert_eq!(app.active, 0);
        app.prev_tab();
        assert_eq!(app.active, 1);
    }

    #[test]
    fn closing_tab_keeps_other_tabs_alive() {
        let (mut app, rx) = make_app();
        app.new_tab();
        let _ = frames(&rx);
        app.close_tab();
        assert_eq!(app.tabs.len(), 1);
        assert!(!app.quit);
        let sent = frames(&rx);
        assert!(sent.iter().any(|(ty, _)| *ty == FrameType::ClosePane));
    }

    #[test]
    fn shortcut_dispatches_action_instead_of_forwarding() {
        let (mut app, _rx) = make_app();
        let ctrl_b = KeyEvent::simple(0x42, Some('b'), true, false, false);
        let bytes = app.on_key(&ctrl_b);
        assert!(bytes.is_empty(), "快捷键不应转发给子进程");
        assert_eq!(app.tabs.len(), 2, "Ctrl+B 应新建标签页");

        let plain = KeyEvent::simple(0x41, Some('a'), false, false, false);
        assert_eq!(app.on_key(&plain), b"a", "普通字符应转发");
    }

    #[test]
    fn tab_marks_exit_status_and_bell() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        // 命令开始：清除上一条状态
        app.on_pane_output(id, b"\x1b]133;D;3\x07");
        assert_eq!(app.tabs[0].last_exit, Some(3));
        assert!(tab_label(0, &app.tabs[0]).contains("✗3"));
        app.on_pane_output(id, b"\x1b]133;C\x07");
        assert_eq!(app.tabs[0].last_exit, None);
        app.on_pane_output(id, b"\x1b]133;D;0\x07");
        assert!(tab_label(0, &app.tabs[0]).contains('✓'));

        // 响铃 → 标签标记；切回该标签后清除
        app.on_pane_output(id, b"\x07");
        assert!(app.tabs[0].bell);
        assert!(tab_label(0, &app.tabs[0]).contains('!'));
        app.new_tab();
        app.prev_tab();
        assert!(!app.tabs[0].bell);
    }

    #[test]
    fn tab_click_hit_test_uses_cell_width() {
        let (mut app, _rx) = make_app();
        app.tabs[0].title = "中文标题".to_string();
        // "1:中文标题" 每个汉字占两列，点击第二个标签的最左一列必须命中它
        app.new_tab();
        let second = app.tab_segments()[1].0;
        assert_eq!(app.tab_at(second), Some(1));
    }

    fn mouse(x: usize, y: usize, buttons: u32, wheel: i16) -> MouseEvent {
        MouseEvent {
            x,
            y,
            buttons,
            wheel,
            ..Default::default()
        }
    }

    #[test]
    fn settings_panel_mouse_selects_and_adjusts() {
        use crate::render::GradientDir;
        let (mut app, _rx) = make_app();
        app.execute(Action::Settings);
        let rect = App::settings_panel_rect(app.cols, app.rows);
        let selected = |app: &App| match &app.overlay {
            Some(Overlay::Settings(state)) => state.selected,
            _ => panic!("设置面板应打开"),
        };
        let row_y = |index: usize| rect.y + 2 + index;

        // 点「渐变配色」行首：只选中，不改值。
        app.on_mouse(&mouse(
            rect.x + 2,
            row_y(3),
            FROM_LEFT_1ST_BUTTON_PRESSED,
            0,
        ));
        assert_eq!(selected(&app), 3);
        assert_eq!(settings::palette_index(&app.config), 0);

        // 点该行最右侧：取值 +1，并顺手打开渐变。
        app.on_mouse(&mouse(
            rect.right() - 1,
            row_y(3),
            FROM_LEFT_1ST_BUTTON_PRESSED,
            0,
        ));
        assert_eq!(settings::palette_index(&app.config), 1);
        assert_eq!(app.config.render.gradient, Some(GradientDir::Vertical));

        // 滚轮向上回到上一行。
        app.on_mouse(&mouse(rect.x + 2, row_y(3), 0, 1));
        assert_eq!(selected(&app), 2);

        // 面板外点击不改变选中。
        app.on_mouse(&mouse(
            rect.x + 2,
            app.rows - 1,
            FROM_LEFT_1ST_BUTTON_PRESSED,
            0,
        ));
        assert_eq!(selected(&app), 2);
    }

    #[test]
    fn tab_bar_plus_click_opens_tab() {
        let (mut app, _rx) = make_app();
        let x = app.tab_bar_plus_x(app.cols).expect("宽屏应显示「+」");
        // 「+」是 3 列宽按钮，点在中间也应该新建标签。
        app.on_mouse(&mouse(x + TAB_PLUS_WIDTH / 2, 0, FROM_LEFT_1ST_BUTTON_PRESSED, 0));
        assert_eq!(app.tabs.len(), 2);
        assert_eq!(app.active, 1, "新建的标签应获得焦点");
    }

    #[test]
    fn tab_bar_middle_click_closes_tab() {
        let (mut app, rx) = make_app();
        app.new_tab();
        app.activate_tab(0);
        let _ = frames(&rx);
        let second = app.tab_segments()[1].0;
        app.on_mouse(&mouse(second, 0, FROM_LEFT_2ND_BUTTON_PRESSED, 0));
        assert_eq!(app.tabs.len(), 1);
        assert_eq!(app.active, 0);
        assert!(!app.quit);
        let sent = frames(&rx);
        assert!(sent.iter().any(|(ty, _)| *ty == FrameType::ClosePane));

        // 关闭当前标签之前的标签时，active 随之下移。
        app.new_tab();
        assert_eq!(app.active, 1);
        app.on_mouse(&mouse(0, 0, FROM_LEFT_2ND_BUTTON_PRESSED, 0));
        assert_eq!(app.tabs.len(), 1);
        assert_eq!(app.active, 0);
    }

    #[test]
    fn tab_bar_close_button_closes_tab() {
        let (mut app, _rx) = make_app();
        app.new_tab();
        let (start, width) = app.tab_segments()[1];
        let close = start + width - 1;
        assert_eq!(app.tab_close_at(close), Some(1), "标签末列应是关闭按钮");
        assert_eq!(
            app.tab_close_at(start + width - TAB_CLOSE_WIDTH),
            Some(1),
            "关闭按钮占 3 列，整块都可点"
        );
        assert_eq!(app.tab_close_at(start), None, "标签开头不是关闭按钮");
        app.on_mouse(&mouse(close, 0, FROM_LEFT_1ST_BUTTON_PRESSED, 0));
        assert_eq!(app.tabs.len(), 1);
        assert_eq!(app.active, 0);
    }

    #[test]
    fn dragging_tab_reorders_and_keeps_active_tab() {
        let (mut app, _rx) = make_app();
        app.new_tab();
        app.new_tab();
        let ids: Vec<u32> = app.tabs.iter().map(|t| t.focus).collect();
        assert_eq!(app.active, 2, "最后新建的标签获得焦点");
        let (start, _) = app.tab_segments()[0];
        app.tab_press = Some((0, start));
        let (target, _) = app.tab_segments()[2];
        let mut ev = mouse(target, 0, FROM_LEFT_1ST_BUTTON_PRESSED, 0);
        ev.moved = true;
        app.on_mouse(&ev);
        assert_eq!(app.tabs[0].focus, ids[1]);
        assert_eq!(app.tabs[1].focus, ids[2]);
        assert_eq!(app.tabs[2].focus, ids[0]);
        assert_eq!(
            app.active_tab().unwrap().focus,
            ids[2],
            "激活标签应跟随原标签移动"
        );
    }

    #[test]
    fn tab_color_comes_from_profile() {
        let (mut app, _rx) = make_app();
        // 第一个标签用的是默认 profile，不一定是 profiles[0]。
        let index = app
            .config
            .profiles
            .iter()
            .position(|p| p.name == app.config.default_profile)
            .expect("默认 profile 应存在");
        app.config.profiles[index].tab_color = Some(Color::Rgb(0x20, 0x40, 0x80));
        assert_eq!(app.tab_color_for(0), Some(Color::Rgb(0x20, 0x40, 0x80)));
        app.config.profiles[index].tab_color = None;
        assert_eq!(app.tab_color_for(0), None);
    }

    #[test]
    fn profile_gradient_overrides_and_inherits() {
        use crate::render::GradientDir;
        let (app, _rx) = make_app();
        let scheme = app.config.scheme("Campbell").cloned().expect("内置 Campbell");
        let mut profile = app.config.profiles[0].clone();
        profile.gradient = GradientOverride::Dir(GradientDir::Horizontal);
        profile.gradient_top = Some(Color::Rgb(1, 2, 3));
        profile.gradient_bottom = Some(Color::Rgb(4, 5, 6));
        let gradient = app
            .background_gradient(Some(&profile), &scheme)
            .expect("覆盖后应有渐变");
        assert_eq!(gradient.dir, GradientDir::Horizontal);
        assert_eq!(gradient.from, (1, 2, 3));
        assert_eq!(gradient.to, (4, 5, 6));

        profile.gradient = GradientOverride::Off;
        assert!(
            app.background_gradient(Some(&profile), &scheme).is_none(),
            "profile 关闭后不应有渐变"
        );

        profile.gradient = GradientOverride::Inherit;
        profile.gradient_top = None;
        profile.gradient_bottom = None;
        let gradient = app
            .background_gradient(Some(&profile), &scheme)
            .expect("继承全局应有渐变");
        assert_eq!(gradient.dir, app.config.render.gradient.unwrap());
    }

    #[test]
    fn profile_font_falls_back_to_global() {
        let (mut app, _rx) = make_app();
        app.config.render.font_face = Some("Consolas".into());
        app.config.render.font_size = Some(18);
        let name = app.current_profile_name();
        let profile = app
            .config
            .profiles
            .iter_mut()
            .find(|profile| profile.name == name)
            .expect("应有当前 profile");
        profile.font_face = Some("Cascadia Mono".into());
        profile.font_size = None;
        assert_eq!(
            app.effective_font(),
            (Some("Cascadia Mono".to_string()), Some(18)),
            "字体覆盖、字号回退全局"
        );
    }

    #[test]
    fn profile_settings_rows_update_active_profile() {
        let (mut app, _rx) = make_app();
        app.execute(Action::Settings);
        let key = |vk| KeyEvent::simple(vk, None, false, false, false);
        let goto = |app: &mut App, row: Row| {
            let target = settings::ROWS
                .iter()
                .position(|item| *item == row)
                .expect("应有该行");
            if let Some(Overlay::Settings(state)) = app.overlay.as_mut() {
                state.selected = target;
            }
        };
        let name = app.current_profile_name();
        let profile = |app: &App| {
            app.config
                .profiles
                .iter()
                .find(|profile| profile.name == name)
                .cloned()
                .expect("应有当前 profile")
        };

        goto(&mut app, Row::ProfileGradient);
        app.on_key(&key(crate::input::VK_RIGHT));
        assert_eq!(profile(&app).gradient, GradientOverride::Off);

        goto(&mut app, Row::ProfileGradientPalette);
        app.on_key(&key(crate::input::VK_RIGHT));
        assert_eq!(
            profile(&app).gradient_top,
            settings::palette_colors(1).0,
            "应写入第 1 套预设的顶部色"
        );

        goto(&mut app, Row::ProfileTabColor);
        app.on_key(&key(crate::input::VK_RIGHT));
        assert_eq!(profile(&app).tab_color, Some(settings::TAB_COLORS[0].1));

        goto(&mut app, Row::ProfileFont);
        app.on_key(&key(crate::input::VK_RIGHT));
        assert_eq!(
            profile(&app).font_face,
            settings::FONT_FACES[1].1.map(str::to_string),
            "第 1 项应是继承（不覆盖）的下一个字体"
        );

        goto(&mut app, Row::ProfileFontSize);
        app.on_key(&key(crate::input::VK_RIGHT));
        assert_eq!(profile(&app).font_size, Some(settings::FONT_SIZES[0]));
    }

    #[test]
    fn settings_panel_scrolls_to_selected() {
        let (mut app, _rx) = make_app();
        app.execute(Action::Settings);
        let last = settings::ROWS.len() - 1;
        if let Some(Overlay::Settings(state)) = app.overlay.as_mut() {
            state.selected = last;
        }
        let rect = App::settings_panel_rect(app.cols, app.rows);
        let visible = App::settings_visible_rows(rect.h);
        assert!(visible < settings::ROWS.len(), "面板高度应不足以显示全部行");
        let first = App::settings_first_visible(last, rect.h);
        assert!(first > 0, "选中最后一行时应向上滚动");
        assert_eq!(first + visible - 1, last, "最后一行应刚好落在可视区末尾");
    }

    #[test]
    fn contrast_color_picks_readable_foreground() {
        assert_eq!(contrast_color(Color::Rgb(20, 20, 20)), Color::Indexed(15));
        assert_eq!(contrast_color(Color::Rgb(240, 240, 240)), Color::Indexed(0));
        assert_eq!(contrast_color(Color::Indexed(1)), Color::Indexed(15));
        assert_eq!(contrast_color(Color::Indexed(15)), Color::Indexed(0));
    }

    #[test]
    fn tab_bar_wheel_switches_tabs() {
        let (mut app, _rx) = make_app();
        app.new_tab();
        assert_eq!(app.active, 1);
        app.on_mouse(&mouse(1, 0, 0, 1));
        assert_eq!(app.active, 0);
        app.on_mouse(&mouse(1, 0, 0, -1));
        assert_eq!(app.active, 1);
    }

    #[test]
    fn tab_bar_shortcuts_select_tabs() {
        let (mut app, _rx) = make_app();
        app.new_tab();
        app.new_tab();
        assert_eq!(app.active, 2);
        app.execute(Action::SelectTab(0));
        assert_eq!(app.active, 0);
        app.execute(Action::LastTab);
        assert_eq!(app.active, 2);
        app.execute(Action::SelectTab(7));
        assert_eq!(app.active, 2, "越界的目标标签页不应改变焦点");
    }

    #[test]
    fn status_bar_shows_shortcut_hints_when_room() {
        let (mut app, _rx) = make_app();
        assert!(app.status_hint(app.cols).is_some(), "宽屏应显示提示");
        // 状态与目录占位时提示仍常驻（右侧信息让位）。
        app.status = Some((
            "一个很长很长很长很长很长的状态提示".to_string(),
            std::time::Instant::now(),
        ));
        if let Some(pane) = app.focused_pane_mut() {
            pane.screen.cwd = Some("C:\\Windows\\System32\\WindowsPowerShell\\v1.0".to_string());
        }
        assert!(
            app.status_hint(app.cols).is_some(),
            "右侧信息不应挤掉提示"
        );
        assert_eq!(app.status_bar_y(), app.rows - 1, "状态栏应在最下面一行");
        app.cols = 20;
        assert_eq!(app.status_hint(app.cols), None, "极窄屏整段放不下");
        assert_eq!(truncate_right(TAB_HINTS[2], 5), "Ctrl+");
    }

    #[test]
    fn tab_bar_narrow_hides_plus() {
        let (mut app, _rx) = make_app();
        app.cols = 8;
        assert_eq!(app.tab_bar_plus_x(app.cols), None, "空间不足时不画「+」");
        app.on_mouse(&mouse(0, 0, FROM_LEFT_1ST_BUTTON_PRESSED, 0));
        assert_eq!(app.tabs.len(), 1, "没有「+」时点击不应新建标签");
    }

    #[test]
    fn gradient_fills_default_backgrounds_only() {
        use crate::render::GradientDir;
        let (cols, rows) = (4, 3);
        let mut canvas = vec![Cell::default(); cols * rows];
        canvas[0].attrs.bg = Color::Indexed(8); // 模拟标签栏
        let gradient = Gradient::new((0, 0, 0), (100, 100, 100), GradientDir::Vertical);
        apply_background(
            &mut canvas,
            cols,
            rows,
            Some(&gradient),
            (0x0C, 0x0C, 0x0C),
            None,
        );
        assert_eq!(canvas[0].attrs.bg, Color::Indexed(8), "显式底色不应被覆盖");
        assert_eq!(canvas[cols].attrs.bg, Color::Rgb(50, 50, 50));
        assert_eq!(canvas[2 * cols].attrs.bg, Color::Rgb(100, 100, 100));
        assert_eq!(canvas[2 * cols + 3].attrs.bg, Color::Rgb(100, 100, 100));
    }

    #[test]
    fn background_blends_image_over_gradient() {
        use crate::render::GradientDir;
        let (cols, rows) = (2, 1);
        let mut canvas = vec![Cell::default(); cols * rows];
        canvas[1].attrs.bg = Color::Indexed(8); // 模拟显式底色
        let gradient = Gradient::new((0, 0, 0), (200, 200, 200), GradientDir::Horizontal);
        let pixels = [Color::Rgb(200, 200, 200), Color::Rgb(200, 200, 200)];
        apply_background(
            &mut canvas,
            cols,
            rows,
            Some(&gradient),
            (0, 0, 0),
            Some((&pixels[..], 50)),
        );
        // 渐变 0 打底，图片 200 按 50% 叠加 → 100
        assert_eq!(canvas[0].attrs.bg, Color::Rgb(100, 100, 100));
        assert_eq!(canvas[1].attrs.bg, Color::Indexed(8), "显式底色不应被覆盖");
    }

    #[test]
    fn background_without_gradient_uses_base_color() {
        let (cols, rows) = (2, 1);
        let mut canvas = vec![Cell::default(); cols * rows];
        let pixels = [Color::Rgb(30, 60, 90), Color::Rgb(30, 60, 90)];
        apply_background(
            &mut canvas,
            cols,
            rows,
            None,
            (10, 20, 30),
            Some((&pixels[..], 100)),
        );
        assert_eq!(canvas[0].attrs.bg, Color::Rgb(30, 60, 90));
        assert_eq!(canvas[1].attrs.bg, Color::Rgb(30, 60, 90));
    }

    #[test]
    fn toml_quote_escapes_windows_paths() {
        assert_eq!(quote_toml("C:\\pics\\sea.jpg"), "\"C:\\\\pics\\\\sea.jpg\"");
        assert_eq!(quote_toml("a\"b"), "\"a\\\"b\"");
    }

    #[test]
    fn paint_emits_gradient_background() {
        let (mut app, _rx) = make_app();
        let out = String::from_utf8_lossy(&app.paint()).to_string();
        assert!(
            out.matches("48;2;").count() >= 3,
            "空屏也应逐行输出渐变底色：{out}"
        );
    }

    #[test]
    fn settings_adjusts_and_reverts() {
        use crate::render::GradientDir;
        let (mut app, _rx) = make_app();
        let key = |vk| KeyEvent::simple(vk, None, false, false, false);
        app.execute(Action::Settings);
        let panel = String::from_utf8_lossy(&app.paint()).to_string();
        assert!(panel.contains("设置") && panel.contains("配色方案"), "{panel}");
        assert!(panel.contains("回看行数") && panel.contains("‹ ›"), "{panel}");
        assert!(panel.contains("Enter 保存"), "{panel}");

        app.on_key(&key(crate::input::VK_DOWN)); // → 默认 profile
        app.on_key(&key(crate::input::VK_DOWN)); // → 背景渐变
        app.on_key(&key(crate::input::VK_RIGHT)); // 竖向 → 横向
        assert_eq!(app.config.render.gradient, Some(GradientDir::Horizontal));
        app.on_key(&key(crate::input::VK_DOWN)); // → 渐变配色
        app.on_key(&key(crate::input::VK_RIGHT)); // 自动 → 深蓝
        assert_eq!(
            app.config.render.gradient_top,
            Some(Color::Rgb(0x1B, 0x2A, 0x45))
        );

        // Esc 取消：按打开时的快照回滚
        app.on_key(&key(crate::input::VK_ESCAPE));
        assert!(app.overlay.is_none());
        assert_eq!(app.config.render.gradient, Some(GradientDir::Vertical));
        assert!(app.config.render.gradient_top.is_none());
    }

    #[test]
    fn settings_scrollback_applies_to_open_panes() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        let data: Vec<u8> = (0..40).map(|i| format!("line{i}\r\n")).collect::<String>().into_bytes();
        app.on_pane_output(id, &data);
        let key = |vk| KeyEvent::simple(vk, None, false, false, false);
        app.execute(Action::Settings);
        // 移到「回看行数」行
        let target = settings::ROWS
            .iter()
            .position(|row| *row == Row::Scrollback)
            .expect("应有回看行");
        for _ in 0..target {
            app.on_key(&key(crate::input::VK_DOWN));
        }
        app.on_key(&key(crate::input::VK_RIGHT));
        assert_eq!(app.config.scrollback, 25_000);
        assert!(app.panes[&id].screen.history_len() <= app.config.scrollback);
    }

    #[test]
    fn settings_save_writes_only_related_keys() {
        let (mut app, _rx) = make_app();
        let path = std::env::temp_dir().join("scterm_settings_save_test.toml");
        let _ = std::fs::write(&path, crate::config::DEFAULT_CONFIG);
        app.config_path = path.clone();

        let key = |vk| KeyEvent::simple(vk, None, false, false, false);
        app.execute(Action::Settings);
        app.on_key(&key(crate::input::VK_DOWN)); // → 默认 profile
        app.on_key(&key(crate::input::VK_DOWN)); // → 背景渐变
        app.on_key(&key(crate::input::VK_RIGHT)); // 竖向 → 横向
        app.on_key(&key(crate::input::VK_DOWN)); // → 渐变配色
        app.on_key(&key(crate::input::VK_RIGHT)); // 自动 → 深蓝
        app.on_key(&key(crate::input::VK_RETURN)); // 保存
        assert!(app.overlay.is_none());

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("gradient = \"horizontal\""), "{text}");
        assert!(text.contains("gradient_top = \"#1B2A45\""), "{text}");
        assert!(text.contains("[[color_schemes]]"), "其余内容应保留：{text}");
        assert!(text.contains("copy_on_select = false"), "{text}");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn settings_copy_on_select_toggle() {
        let (mut app, _rx) = make_app();
        let key = |vk| KeyEvent::simple(vk, None, false, false, false);
        app.execute(Action::Settings);
        let target = settings::ROWS
            .iter()
            .position(|row| *row == Row::CopyOnSelect)
            .unwrap();
        for _ in 0..target {
            app.on_key(&key(crate::input::VK_DOWN));
        }
        assert!(!app.config.behavior.copy_on_select);
        app.on_key(&key(crate::input::VK_RIGHT));
        assert!(app.config.behavior.copy_on_select, "选中即复制应能切换");
    }

    #[test]
    fn scrollbar_geometry_follows_offset() {
        // 20 行可见、100 行历史：拇指高 400/120 = 3
        assert_eq!(scrollbar_geometry(20, 100, 0), (3, 17));
        assert_eq!(scrollbar_geometry(20, 100, 100), (3, 0));
        assert_eq!(scrollbar_geometry(20, 100, 50), (3, 9));
        // 没有历史时拇指占满
        assert_eq!(scrollbar_geometry(20, 0, 0), (20, 0));
    }

    #[test]
    fn dragging_scrollbar_scrolls_history() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        let data: Vec<u8> = (0..200)
            .map(|i| format!("line{i}\r\n"))
            .collect::<String>()
            .into_bytes();
        app.on_pane_output(id, &data);
        let history = app.panes[&id].screen.history_len();
        assert!(history > 50, "应有回看历史：{history}");
        assert_eq!(app.panes[&id].scroll_offset, 0);

        // 悬停到最右列 → 按下并拖到顶部
        let press = |x: usize, y: usize, buttons: u32| MouseEvent {
            x,
            y,
            buttons,
            ..Default::default()
        };
        let right = app.cols - 1;
        app.on_mouse(&press(right, 1, 0));
        app.on_mouse(&press(right, 1, FROM_LEFT_1ST_BUTTON_PRESSED));
        assert_eq!(
            app.panes[&id].scroll_offset, history,
            "拖到顶部应回到最早的历史"
        );

        // 继续拖到底部
        app.on_mouse(&press(right, app.rows - 1, FROM_LEFT_1ST_BUTTON_PRESSED));
        assert_eq!(app.panes[&id].scroll_offset, 0);
        // 松开后结束拖动
        app.on_mouse(&press(right, app.rows - 1, 0));
    }

    #[test]
    fn jump_to_first_and_last_prompt() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        let mut data = String::new();
        for i in 0..40 {
            data.push_str(&format!("\x1b]133;A\x07C:\\>cmd{i}\r\nout{i}\r\n"));
        }
        app.on_pane_output(id, data.as_bytes());
        assert!(app.panes[&id].screen.history_len() > 10);

        app.execute(Action::PromptFirst);
        assert_eq!(app.panes[&id].scroll_offset, app.panes[&id].screen.history_len());
        app.execute(Action::PromptLast);
        assert_eq!(app.panes[&id].scroll_offset, 0);
    }

    #[test]
    fn win32_input_mode_forwards_press_and_release() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(id, b"\x1b[?9001h");
        assert!(app.panes[&id].screen.win32_input);

        let mut ev = KeyEvent::simple(crate::input::VK_RETURN, Some('\r'), false, false, true);
        ev.scan = 28;
        assert_eq!(app.on_key(&ev), b"\x1b[13;28;13;1;16;1_");
        ev.down = false;
        assert_eq!(app.on_key(&ev), b"\x1b[13;28;13;0;16;1_");

        // 关闭后回到普通 VT 编码
        app.on_pane_output(id, b"\x1b[?9001l");
        assert!(!app.panes[&id].screen.win32_input);
        assert_eq!(app.on_key(&ev), b"", "普通模式下抬起事件应被忽略");
        let mut down = ev;
        down.down = true;
        assert_eq!(app.on_key(&down), b"\r");
    }

    #[test]
    fn palette_opens_and_lists_actions() {
        let (mut app, _rx) = make_app();
        app.execute(Action::CommandPalette);
        assert!(matches!(app.overlay, Some(Overlay::Palette(_))));
        // 输入“分屏”后回车执行第一个结果
        for ch in "分屏".chars() {
            let ev = KeyEvent::simple(0, Some(ch), false, false, false);
            app.on_key(&ev);
        }
        let ev = KeyEvent::simple(crate::input::VK_RETURN, Some('\r'), false, false, false);
        app.on_key(&ev);
        assert!(app.overlay.is_none());
        assert_eq!(app.panes.len(), 2, "命令面板应能执行未绑定动作");
    }

    #[test]
    fn search_finds_history_and_scrolls() {
        let (mut app, _rx) = make_app();
        let pane_id = app.focused_pane_id();
        // 输出足够多行以产生回看缓冲
        let mut data = String::new();
        for i in 0..40 {
            data.push_str(&format!("line {i}\r\n"));
        }
        data.push_str("needle here\r\n");
        app.on_pane_output(pane_id, data.as_bytes());
        app.execute(Action::Search);
        if let Some(Overlay::Search(state)) = &mut app.overlay {
            state.query = "needle".to_string();
        }
        app.refresh_search();
        let state = match &app.overlay {
            Some(Overlay::Search(s)) => s,
            _ => unreachable!(),
        };
        assert!(!state.matches.is_empty(), "应在回看缓冲/屏幕中找到内容");
        assert!(app.focused_pane().unwrap().scroll_offset > 0 || state.current == 0);
    }

    #[test]
    fn custom_binding_from_config_is_used() {
        let mut config = Config::default();
        config.action_bindings.push(crate::config::ActionBinding {
            command: "splitPaneHorizontal".into(),
            keys: "alt+shift+d".into(),
        });
        let (tx, _rx) = mpsc::channel();
        let mut app = App::new(config, 80, 24, tx);
        let chord = Chord::parse("alt+shift+d").unwrap();
        assert_eq!(
            app.registry.resolve(&chord),
            Some(Action::SplitPane(SplitAxis::Horizontal))
        );
        let ev = KeyEvent::simple(0x44, Some('d'), false, true, true);
        app.on_key(&ev);
        assert_eq!(app.panes.len(), 2);
    }

    #[test]
    fn wheel_scrolls_history_of_pane_under_cursor() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        let data: Vec<u8> = (0..60)
            .map(|i| format!("line{i}\r\n"))
            .collect::<String>()
            .into_bytes();
        app.on_pane_output(id, &data);
        assert!(app.panes[&id].screen.history_len() > 0);

        let mut ev = MouseEvent {
            x: 5,
            y: 5,
            ..Default::default()
        };
        ev.wheel = 120;
        app.on_mouse(&ev);
        assert_eq!(app.panes[&id].scroll_offset, 3);
        ev.wheel = -120;
        app.on_mouse(&ev);
        assert_eq!(app.panes[&id].scroll_offset, 0);
    }

    #[test]
    fn small_wheel_delta_still_scrolls() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        let data: Vec<u8> = (0..60)
            .map(|i| format!("line{i}\r\n"))
            .collect::<String>()
            .into_bytes();
        app.on_pane_output(id, &data);
        assert!(app.panes[&id].screen.history_len() > 0);

        // 触控板常见的 40 增量：累计后应滚 1 行，而不是被整除截断
        let mut ev = MouseEvent {
            x: 5,
            y: 5,
            ..Default::default()
        };
        ev.wheel = 40;
        app.on_mouse(&ev);
        assert_eq!(app.panes[&id].scroll_offset, 1);
        app.on_mouse(&ev);
        assert_eq!(app.panes[&id].scroll_offset, 2);
        ev.wheel = -40;
        app.on_mouse(&ev);
        assert_eq!(app.panes[&id].scroll_offset, 1);
    }

    #[test]
    fn jumps_between_prompts() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        let mut data = Vec::new();
        for i in 0..60 {
            if i % 12 == 0 {
                data.extend_from_slice(b"\x1b]133;A\x07");
            }
            data.extend_from_slice(format!("line{i}\r\n").as_bytes());
        }
        app.on_pane_output(id, &data);

        let (total, rows, history) = {
            let screen = &app.panes[&id].screen;
            (
                (screen.history_len() + screen.rows) as isize,
                screen.rows as isize,
                screen.history_len(),
            )
        };
        assert!(history > 0, "应有回看缓冲");
        app.panes.get_mut(&id).unwrap().scroll_offset = 0;

        app.jump_prompt(true);
        let offset = app.panes[&id].scroll_offset;
        assert!(offset > 0, "应向上跳到某条命令");
        let top = total - rows - offset as isize;
        let marks: Vec<usize> = app.panes[&id].screen.prompt_marks.iter().copied().collect();
        assert!(
            marks.iter().any(|mark| *mark as isize == top),
            "视口顶部应对齐提示符：{marks:?} / {top}"
        );

        app.jump_prompt(true);
        let offset2 = app.panes[&id].scroll_offset;
        assert!(offset2 >= offset, "应继续向上或停在顶部");
        app.jump_prompt(false);
        assert!(app.panes[&id].scroll_offset <= offset2, "应能向下跳回");
    }

    #[test]
    fn dragging_separator_updates_ratio() {
        let (mut app, _rx) = make_app();
        app.split_focused(SplitAxis::Horizontal);
        let content = app.content_rect();
        let (panes, seps) = compute(&app.active_tab().unwrap().tree, content);
        let sep = seps[0];

        let mut down = MouseEvent {
            x: sep.x,
            y: sep.y + 1,
            ..Default::default()
        };
        down.buttons = FROM_LEFT_1ST_BUTTON_PRESSED;
        assert!(app.on_mouse(&down).is_none());
        assert!(app.drag.is_some(), "按在分隔线上应开始拖拽");

        let mut drag = MouseEvent {
            x: content.x + (content.w - 1) / 4,
            y: sep.y + 1,
            ..Default::default()
        };
        drag.buttons = FROM_LEFT_1ST_BUTTON_PRESSED;
        drag.moved = true;
        app.on_mouse(&drag);

        let (panes_after, _) = compute(&app.active_tab().unwrap().tree, content);
        assert!(
            panes_after[0].1.w < panes[0].1.w,
            "向左拖应缩小第一个窗格"
        );

        let up = MouseEvent {
            x: drag.x,
            y: drag.y,
            ..Default::default()
        };
        app.on_mouse(&up);
        assert!(app.drag.is_none(), "松开左键结束拖拽");
    }

    #[test]
    fn forwards_mouse_when_app_enables_tracking() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(id, b"\x1b[?1000h\x1b[?1006h");
        assert_eq!(app.panes[&id].screen.mouse_mode, 1000);
        assert!(app.panes[&id].screen.mouse_sgr);

        let mut ev = MouseEvent {
            x: 3,
            y: 4,
            ..Default::default()
        };
        ev.buttons = FROM_LEFT_1ST_BUTTON_PRESSED;
        let (pane_id, bytes) = app.on_mouse(&ev).expect("应转发鼠标事件");
        assert_eq!(pane_id, id);
        let text = String::from_utf8_lossy(&bytes).to_string();
        assert_eq!(text, "\x1b[<0;4;4M");
    }

    #[test]
    fn selection_text_and_word_selection() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(id, b"hello world\r\nsecond line\r\n");
        let history = app.panes[&id].screen.history_len();

        let selection = Selection {
            pane: id,
            anchor: (0, history),
            head: (4, history),
            dragging: false,
            block: false,
        };
        assert_eq!(app.selection_text(selection).as_deref(), Some("hello"));

        let selection = Selection {
            pane: id,
            anchor: (6, history),
            head: (5, history + 1),
            dragging: false,
            block: false,
        };
        assert_eq!(
            app.selection_text(selection).as_deref(),
            Some("world\r\nsecond")
        );

        let word = app.word_selection(id, (6, history)).expect("应选中单词");
        assert_eq!((word.anchor.0, word.head.0), (6, 10), "world 的范围");
        let word = app.word_selection(id, (1, history + 1)).expect("应选中单词");
        assert_eq!((word.anchor.0, word.head.0), (0, 5), "second 的范围");
    }

    #[test]
    fn put_marks_wide_tail() {
        let mut canvas = vec![Cell::default(); 10];
        put(&mut canvas, 10, 0, 0, '窗', Attrs::default());
        assert_eq!(canvas[0].ch, '窗');
        assert_eq!(canvas[1].ch, ' ');
        assert!(
            canvas[1].attrs.flags & ATTR_WIDE_TAIL != 0,
            "宽字符右半格必须标记，否则渲染会错列"
        );
        // 行尾放不下宽字符时退化为空格
        put(&mut canvas, 10, 9, 0, '窗', Attrs::default());
        assert_eq!(canvas[9].ch, ' ');
    }

    #[test]
    fn selection_contains_range() {
        let selection = Selection {
            pane: 1,
            anchor: (2, 5),
            head: (1, 7),
            dragging: false,
            block: false,
        };
        assert!(selection_contains(&selection, 5, 2));
        assert!(!selection_contains(&selection, 5, 1));
        assert!(selection_contains(&selection, 6, 0));
        assert!(selection_contains(&selection, 7, 1));
        assert!(!selection_contains(&selection, 7, 2));
    }

    #[test]
    fn block_selection_copies_rect_and_keeps_spaces() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(id, b"abcdef\r\nghijkl\r\n");
        let history = app.panes[&id].screen.history_len();

        let selection = Selection {
            pane: id,
            anchor: (3, history + 1),
            head: (1, history),
            dragging: false,
            block: true,
        };
        assert_eq!(
            app.selection_text(selection).as_deref(),
            Some("bcd\r\nhij"),
            "块选区按列区间复制，方向相反也应正常"
        );

        // 列区间包含空格时保留（普通选区会 trim_end）。
        app.on_pane_output(id, b"\x1b[2J\x1b[H");
        app.on_pane_output(id, b"a b\r\nc d\r\n");
        let history = app.panes[&id].screen.history_len();
        let selection = Selection {
            pane: id,
            anchor: (0, history),
            head: (2, history + 1),
            dragging: false,
            block: true,
        };
        assert_eq!(app.selection_text(selection).as_deref(), Some("a b\r\nc d"));
    }

    #[test]
    fn block_selection_hit_test_is_rectangular() {
        let selection = Selection {
            pane: 1,
            anchor: (2, 5),
            head: (4, 7),
            dragging: false,
            block: true,
        };
        assert!(selection_contains(&selection, 5, 2));
        assert!(selection_contains(&selection, 6, 3));
        assert!(selection_contains(&selection, 7, 4));
        assert!(!selection_contains(&selection, 6, 1), "列外不应命中");
        assert!(!selection_contains(&selection, 6, 5), "列外不应命中");
        assert!(!selection_contains(&selection, 4, 3), "行外不应命中");
    }

    #[test]
    fn alt_drag_starts_block_selection_even_with_mouse_reporting() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(id, b"\x1b[?1000h\x1b[?1006h");
        let rect = app.content_rect();

        let mut down = MouseEvent {
            x: rect.x + 2,
            y: rect.y + 1,
            alt: true,
            ..Default::default()
        };
        down.buttons = FROM_LEFT_1ST_BUTTON_PRESSED;
        assert!(
            app.on_mouse(&down).is_none(),
            "Alt+左键不应转发给子进程"
        );
        let selection = app.selection.expect("应创建块选区");
        assert!(selection.block);
        assert_eq!(selection.anchor.0, 2);
    }

    #[test]
    fn mark_mode_moves_selection_and_exits() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(id, b"hello world\r\nsecond line\r\n");

        let enter = KeyEvent::simple(0x4D, Some('m'), true, false, true);
        app.on_key(&enter);
        assert!(app.mark_mode, "Ctrl+Shift+M 应进入标记模式");
        let start = app.selection.expect("进入后应有零长度选区");
        assert_eq!(start.anchor, start.head);
        assert!(!start.block);

        let key = |vk| KeyEvent::simple(vk, None, false, false, false);
        app.on_key(&key(crate::input::VK_UP));
        app.on_key(&key(crate::input::VK_HOME));
        assert_eq!(app.selection.unwrap().head.0, 0, "Home 应回到行首");

        app.on_key(&key(crate::input::VK_END));
        assert_eq!(
            app.selection.unwrap().head.0,
            app.panes[&id].screen.cols - 1,
            "End 应到行尾"
        );

        app.on_key(&key(crate::input::VK_ESCAPE));
        assert!(!app.mark_mode);
        assert!(app.selection.is_none());
    }

    #[test]
    fn mark_mode_scrolls_to_keep_head_visible() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        let mut data = String::new();
        for i in 0..60 {
            data.push_str(&format!("line {i}\r\n"));
        }
        app.on_pane_output(id, data.as_bytes());
        assert!(app.panes[&id].screen.history_len() > 0);

        app.on_key(&KeyEvent::simple(0x4D, Some('m'), true, false, true));
        assert!(app.mark_mode);
        app.on_key(&KeyEvent::simple(
            crate::input::VK_HOME,
            None,
            true,
            false,
            false,
        ));
        assert_eq!(app.selection.unwrap().head, (0, 0));
        assert!(
            app.panes[&id].scroll_offset > 0,
            "选区头上移到回看缓冲时应自动滚动"
        );

        app.on_key(&KeyEvent::simple(
            crate::input::VK_END,
            None,
            true,
            false,
            false,
        ));
        assert_eq!(app.panes[&id].scroll_offset, 0, "回到末尾时滚到底部");
    }

    #[test]
    fn mark_mode_enter_on_empty_selection_reports_nothing() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(id, b"abc\r\n");
        app.on_key(&KeyEvent::simple(0x4D, Some('m'), true, false, true));
        app.on_key(&KeyEvent::simple(
            crate::input::VK_RETURN,
            Some('\r'),
            false,
            false,
            false,
        ));
        assert!(!app.mark_mode);
        assert!(app.status.as_ref().unwrap().0.contains("没有选中文本"));
    }

    #[test]
    fn mouse_click_exits_mark_mode() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(id, b"abc\r\n");
        app.on_key(&KeyEvent::simple(0x4D, Some('m'), true, false, true));
        assert!(app.mark_mode);

        let rect = app.content_rect();
        let mut ev = MouseEvent {
            x: rect.x + 1,
            y: rect.y + 1,
            ..Default::default()
        };
        ev.buttons = FROM_LEFT_1ST_BUTTON_PRESSED;
        app.on_mouse(&ev);
        assert!(!app.mark_mode, "鼠标按下应退出标记模式");
    }

    #[test]
    fn paint_draws_tab_bar_and_pane_content() {
        let (mut app, _rx) = make_app();
        let pane_id = app.focused_pane_id();
        app.on_pane_output(pane_id, b"hello\r\n");
        let bytes = app.paint();
        let text = String::from_utf8_lossy(&bytes).to_string();
        assert!(text.contains("hello"), "窗格内容应被绘制");
        assert!(
            text.contains(&format!("1:{}", app.config.default_profile)),
            "标签栏应显示编号与名称"
        );
    }

    #[test]
    fn closing_tab_asks_for_confirmation() {
        let (tx, _rx) = mpsc::channel();
        let mut app = App::new(Config::default(), 80, 24, tx);
        app.new_tab();
        assert!(app.config.behavior.confirm_close);
        app.close_tab();
        assert_eq!(app.tabs.len(), 2, "确认前不应关闭");
        match &app.overlay {
            Some(Overlay::Confirm { action, .. }) => {
                assert!(matches!(action, ConfirmAction::CloseTab(1)))
            }
            _ => panic!("应弹出确认框"),
        }
        let enter = KeyEvent::simple(crate::input::VK_RETURN, None, false, false, false);
        app.on_key(&enter);
        assert_eq!(app.tabs.len(), 1, "确认后关闭");
        assert!(app.overlay.is_none());
    }

    #[test]
    fn closing_tab_confirmation_can_be_cancelled() {
        let (tx, _rx) = mpsc::channel();
        let mut app = App::new(Config::default(), 80, 24, tx);
        app.close_tab();
        let esc = KeyEvent::simple(crate::input::VK_ESCAPE, None, false, false, false);
        app.on_key(&esc);
        assert_eq!(app.tabs.len(), 1);
        assert!(app.overlay.is_none());
    }

    #[test]
    fn multiline_paste_confirmation_sends_on_confirm() {
        let (mut app, rx) = make_app();
        app.overlay = Some(Overlay::Confirm {
            prompt: "粘贴 2 行？".into(),
            action: ConfirmAction::Paste {
                text: "a\r\nb".into(),
                bracketed: false,
            },
        });
        let enter = KeyEvent::simple(crate::input::VK_RETURN, None, false, false, false);
        app.on_key(&enter);
        let sent = frames(&rx);
        let data = sent
            .iter()
            .find(|(ty, _)| *ty == FrameType::Input)
            .map(|(_, data)| msg::PaneData::decode(data).unwrap().data);
        assert_eq!(data.as_deref(), Some(&b"a\r\nb"[..]));
        assert!(app.overlay.is_none());
    }

    #[test]
    fn osc_notification_marks_tab_and_status() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(id, b"\x1b]9;build finished\x07");
        assert!(app.tabs[0].bell, "通知应给标签打标记");
        let (status, _) = app.status.as_ref().expect("应显示状态栏提示");
        assert!(status.contains("build finished"), "{status}");

        app.on_pane_output(id, b"\x1b]777;notify;title;body\x07");
        assert!(app
            .panes
            .get(&id)
            .map(|p| p.screen.notifications.is_empty())
            .unwrap_or(false));
    }

    #[test]
    fn ctrl_click_link_hits_osc8_cell() {
        let (mut app, _rx) = make_app();
        let id = app.focused_pane_id();
        app.on_pane_output(
            id,
            b"\x1b]8;;https://example.com\x1b\\LINK\x1b]8;;\x1b\\",
        );
        let (panes, _) = app.pane_layout().unwrap();
        let rect = panes[0].1;
        assert_eq!(
            app.link_at_mouse(id, rect, rect.x, rect.y),
            Some("https://example.com".to_string())
        );
        assert_eq!(
            app.link_at_mouse(id, rect, rect.x + 4, rect.y),
            None,
            "链接结束后的字符不应命中"
        );
    }

    #[test]
    fn profile_picker_creates_tab_with_chosen_profile() {
        let (mut app, rx) = make_app();
        app.execute(Action::NewTabWithProfile);
        assert!(matches!(
            app.overlay,
            Some(Overlay::ProfilePicker { .. })
        ));
        let index = app
            .config
            .profiles
            .iter()
            .position(|p| p.name == "powershell")
            .expect("默认配置应含 powershell");
        let down = KeyEvent::simple(crate::input::VK_DOWN, None, false, false, false);
        for _ in 0..index {
            app.on_key(&down);
        }
        let enter = KeyEvent::simple(crate::input::VK_RETURN, None, false, false, false);
        app.on_key(&enter);
        assert_eq!(app.tabs.len(), 2);
        assert_eq!(app.tabs[1].title, "powershell");
        assert_eq!(app.active, 1);
        let sent = frames(&rx);
        let created = sent
            .iter()
            .filter(|(ty, _)| *ty == FrameType::CreatePane)
            .filter_map(|(_, data)| msg::CreatePane::decode(data).ok())
            .any(|create| create.profile == "powershell");
        assert!(created, "应按所选 profile 启动新窗格");
    }

    #[test]
    fn palette_profile_item_creates_tab() {
        let (mut app, _rx) = make_app();
        app.execute(Action::CommandPalette);
        for ch in "powershell".chars() {
            let key = KeyEvent::simple(0, Some(ch), false, false, false);
            app.on_key(&key);
        }
        let items = match &app.overlay {
            Some(Overlay::Palette(state)) => {
                palette::filter(&app.registry, &state.query, &app.profile_names())
            }
            _ => panic!("命令面板应打开"),
        };
        let target = items
            .iter()
            .position(|item| item.profile.as_deref() == Some("powershell"))
            .expect("应搜到 powershell 快捷项");
        if let Some(Overlay::Palette(state)) = &mut app.overlay {
            state.selected = target;
        }
        let enter = KeyEvent::simple(crate::input::VK_RETURN, None, false, false, false);
        app.on_key(&enter);
        assert_eq!(app.tabs.len(), 2);
        assert_eq!(app.tabs[1].title, "powershell");
    }
}

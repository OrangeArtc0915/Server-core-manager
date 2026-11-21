//! 把编辑器状态画到画布上（TUI 与 GUI 共用的唯一渲染代码）。

use crate::core::document::Document;
use crate::core::highlight::TokenKind;
use crate::core::unicode::char_width;
use crate::render::{Canvas, Color};
use crate::ui::app::{App, Overlay, Rect, SidebarMode, Tab};
use crate::ui::editor;
use crate::ui::theme::Theme;

impl App {
    pub fn render(&self) -> Canvas {
        let mut canvas = Canvas::new(
            self.layout.cols.max(1),
            self.layout.rows.max(1),
            self.theme.bg,
        );
        canvas.clear(self.theme.bg);
        // pane 之间的 1 列间隙用面板底色（sqlmux 的 gap）。
        if let Some(sidebar) = self.layout.sidebar {
            let y = sidebar.y;
            canvas.fill_rect(
                sidebar.right(),
                y,
                1,
                sidebar.bottom().saturating_sub(y),
                self.theme.panel_bg,
            );
        }
        self.draw_menu_bar(&mut canvas);
        self.draw_tabs_top(&mut canvas);
        self.draw_activity_bar(&mut canvas);
        self.draw_sidebar(&mut canvas);
        self.draw_editor(&mut canvas);
        let status_items = self.status_items();
        self.draw_status(&mut canvas, &status_items);
        self.draw_hints(&mut canvas, &status_items);
        if let Some(page) = &self.settings {
            self.draw_settings(&mut canvas, page);
        }
        self.draw_overlays(&mut canvas);
        if self.help_open {
            self.draw_help(&mut canvas);
        }
        canvas
    }

    /// 鼠标是否落在某个矩形内（用于悬停高亮）。
    fn hover(&self, rect: Rect) -> bool {
        self.mouse_pos
            .map(|(x, y)| rect.contains(x, y))
            .unwrap_or(false)
    }

    /// 三角波脉冲：在 [low, high] 间往返，用于轻量动效。
    fn pulse(&self, period: u64, low: u8, high: u8) -> u8 {
        let period = period.max(1);
        let phase = self.tick % (period * 2);
        let tri = if phase <= period {
            phase
        } else {
            period * 2 - phase
        };
        let span = high.saturating_sub(low) as u64;
        (low as u64 + span * tri / period) as u8
    }

    /// 模糊匹配到的字符下标（用于命令面板高亮）。
    fn fuzzy_positions(text: &str, needle: &str) -> Vec<usize> {
        let mut out = Vec::new();
        let targets: Vec<char> = needle.chars().collect();
        if targets.is_empty() {
            return out;
        }
        let mut index = 0;
        for (i, ch) in text.chars().enumerate() {
            if index >= targets.len() {
                break;
            }
            if ch.to_ascii_lowercase() == targets[index].to_ascii_lowercase() {
                out.push(i);
                index += 1;
            }
        }
        if index == targets.len() {
            out
        } else {
            Vec::new()
        }
    }

    /// 画标题并把模糊匹配到的字符染成强调色。
    fn title_highlighted(
        &self,
        canvas: &mut Canvas,
        x: usize,
        y: usize,
        max: usize,
        text: &str,
        query: &str,
        fg: Color,
        bg: Color,
    ) {
        let hits = Self::fuzzy_positions(text, query);
        if hits.is_empty() {
            canvas.text_max(x, y, max, text, fg, bg);
            return;
        }
        let mut column = 0;
        for (index, ch) in text.chars().enumerate() {
            let width = char_width(ch).max(1);
            if column + width > max || x + column + width > canvas.cols() {
                break;
            }
            let color = if hits.contains(&index) {
                self.theme.accent
            } else {
                fg
            };
            canvas.put(x + column, y, ch, color, bg);
            column += width;
        }
    }

    /// 圆角面板：标题嵌在顶边里，焦点面板用强调色。
    fn frame(&self, canvas: &mut Canvas, rect: Rect, title: &str, focused: bool, bg: Color) {
        if rect.w < 2 || rect.h < 2 {
            return;
        }
        let border = if focused {
            self.theme.accent
        } else {
            self.theme.border
        };
        let x = rect.x;
        let y = rect.y;
        let right = rect.right() - 1;
        let bottom = rect.bottom() - 1;
        canvas.put(x, y, '╭', border, bg);
        canvas.put(right, y, '╮', border, bg);
        canvas.put(x, bottom, '╰', border, bg);
        canvas.put(right, bottom, '╯', border, bg);
        canvas.hline(x + 1, y, rect.w.saturating_sub(2), '─', border, bg);
        canvas.hline(x + 1, bottom, rect.w.saturating_sub(2), '─', border, bg);
        canvas.vline(x, y + 1, rect.h.saturating_sub(2), '│', border, bg);
        canvas.vline(right, y + 1, rect.h.saturating_sub(2), '│', border, bg);
        if !title.is_empty() && rect.w > 10 {
            let text: String = title.chars().take(rect.w.saturating_sub(8)).collect();
            let label = format!(" {text} ");
            let color = if focused {
                self.theme.fg
            } else {
                self.theme.panel_fg
            };
            canvas.text(x + 2, y, &label, color, bg);
        }
    }

    /// 全屏设置页：左侧分类，右侧条目（当前值 + 说明），顶部搜索。
    fn draw_settings(&self, canvas: &mut Canvas, page: &crate::ui::app::SettingsPage) {
        let area = self.settings_area();
        canvas.fill_rect(area.x, area.y, area.w, area.h, self.theme.bg);
        self.frame(canvas, area, "设置", true, self.theme.bg);

        let category = self.settings_category_rect();
        for (index, (name, _)) in crate::ui::app::SETTING_CATEGORIES.iter().enumerate() {
            let y = category.y + index;
            if y >= category.bottom() {
                break;
            }
            let selected = index == page.category;
            let hovered = !selected
                && self.hover(Rect {
                    x: category.x,
                    y,
                    w: category.w,
                    h: 1,
                });
            let bg = if selected {
                self.theme.selection
            } else if hovered {
                self.theme.raised_bg()
            } else {
                self.theme.bg
            };
            canvas.fill_rect(category.x, y, category.w, 1, bg);
            if selected {
                canvas.put(category.x, y, '▎', self.theme.accent, bg);
            }
            canvas.text_max(
                category.x + 2,
                y,
                category.w.saturating_sub(2),
                name,
                if selected {
                    self.theme.fg
                } else {
                    self.theme.panel_fg
                },
                bg,
            );
        }
        let divider = category.right() + 1;
        canvas.vline(
            divider,
            area.y + 1,
            area.h.saturating_sub(2),
            '│',
            self.theme.border,
            self.theme.bg,
        );

        let list = self.settings_list_rect();
        let query = if page.query.is_empty() {
            "搜索：输入字母过滤…".to_string()
        } else {
            format!("搜索：{}▏", page.query)
        };
        canvas.fill_rect(list.x, area.y + 1, list.w, 1, self.theme.raised_bg());
        canvas.text_max(
            list.x + 1,
            area.y + 1,
            list.w.saturating_sub(1),
            &query,
            if page.query.is_empty() {
                self.theme.syntax.comment
            } else {
                self.theme.fg
            },
            self.theme.raised_bg(),
        );

        let rows = self.settings_rows();
        if rows.is_empty() {
            canvas.text_max(
                list.x,
                list.y,
                list.w,
                "没有匹配的设置",
                self.theme.syntax.comment,
                self.theme.bg,
            );
        }
        let label_w = 22.min(list.w / 3).max(8);
        let value_w = 12.min(list.w / 4).max(6);
        for (offset, row) in rows.iter().skip(page.scroll).take(list.h).enumerate() {
            let index = page.scroll + offset;
            let y = list.y + offset;
            let selected = index == page.selected;
            let hovered = !selected
                && self.hover(Rect {
                    x: list.x,
                    y,
                    w: list.w,
                    h: 1,
                });
            let bg = if selected {
                self.theme.selection
            } else if hovered {
                self.theme.raised_bg()
            } else {
                self.theme.bg
            };
            canvas.fill_rect(list.x, y, list.w, 1, bg);
            if selected {
                let bar = self
                    .theme
                    .accent
                    .blend(self.theme.selection, self.pulse(30, 0, 110));
                canvas.put(list.x, y, '▎', bar, bg);
            }
            canvas.text_max(
                list.x + 2,
                y,
                label_w,
                row.label,
                if selected {
                    self.theme.fg
                } else {
                    self.theme.panel_fg
                },
                bg,
            );
            let value_bg = if selected {
                bg
            } else {
                self.theme.bg.blend(self.theme.fg, 9)
            };
            canvas.fill_rect(list.x + label_w + 1, y, value_w, 1, value_bg);
            canvas.text_max(
                list.x + label_w + 1,
                y,
                value_w,
                &row.value,
                self.theme.accent,
                value_bg,
            );
            let desc_x = list.x + label_w + value_w + 2;
            canvas.text_max(
                desc_x,
                y,
                list.right().saturating_sub(desc_x),
                row.desc,
                self.theme.syntax.comment,
                bg,
            );
        }

        let hint = "↑↓ 选择 · ←→/Enter 调整 · Tab 切换分类 · 输入字母搜索 · Esc 返回";
        canvas.text_max(
            area.x + 2,
            area.bottom().saturating_sub(2),
            area.w.saturating_sub(4),
            hint,
            self.theme.syntax.comment,
            self.theme.bg,
        );
    }

    /// 浮层阴影：右下各一条，避免纯黑，保持柔和。
    fn shadow(&self, canvas: &mut Canvas, rect: Rect) {
        let shade = self.theme.bg.blend(Color::rgb(0, 0, 0), 96);
        if rect.bottom() < self.layout.rows {
            canvas.fill_rect(rect.x + 2, rect.bottom(), rect.w, 1, shade);
        }
        if rect.right() < self.layout.cols {
            canvas.fill_rect(rect.right(), rect.y + 1, 1, rect.h, shade);
        }
    }

    fn icon_set(&self) -> crate::ui::icons::Icons {
        crate::ui::icons::for_config(&self.config)
    }

    /// 编辑器 pane 底部的标签行（sqlmux 风格：标签不在顶部）。
    fn draw_editor_tabs(&self, canvas: &mut Canvas, rect: Rect, focused: bool) {
        if rect.w == 0 {
            return;
        }
        canvas.fill_rect(rect.x, rect.y, rect.w, 1, self.theme.tab_inactive_bg);
        let icons = self.icon_set();
        let mut cursor = rect.x;
        for (index, tab) in self.tabs.iter().enumerate() {
            let width = crate::render::canvas::text_width(&Self::tab_label(tab)) + 4;
            let x = cursor;
            cursor += width;
            if x >= rect.right() {
                break;
            }
            let width = width.min(rect.right().saturating_sub(x));
            if width < 4 {
                break;
            }
            let active = index == self.active && focused;
            let hovered = !active
                && self.hover(Rect {
                    x,
                    y: rect.y,
                    w: width,
                    h: 1,
                });
            let bg = if active {
                self.theme.tab_active_bg
            } else if hovered {
                self.theme.tab_inactive_bg.blend(self.theme.fg, 10)
            } else {
                self.theme.tab_inactive_bg
            };
            canvas.fill_rect(x, rect.y, width, 1, bg);
            if x > rect.x {
                canvas.put(x, rect.y, '│', self.theme.divider(), bg);
            }
            canvas.put(
                x + 1,
                rect.y,
                if active { '▎' } else { ' ' },
                if active {
                    self.theme.accent
                } else {
                    self.theme.tab_inactive_bg
                },
                bg,
            );
            let label = Self::tab_label(tab);
            let fg = if active {
                self.theme.fg
            } else if hovered {
                self.theme.panel_fg
            } else {
                self.theme.syntax.comment
            };
            let reserve = if tab.doc.is_dirty() { 2 } else { 1 };
            canvas.text_max_styled(
                x + 2,
                rect.y,
                width.saturating_sub(2 + reserve),
                &label,
                fg,
                bg,
                if active {
                    crate::render::grid::attr::BOLD
                } else {
                    0
                },
            );
            if tab.doc.is_dirty() {
                canvas.put(
                    x + width.saturating_sub(1),
                    rect.y,
                    icons.dirty,
                    self.theme.accent,
                    bg,
                );
            }
        }
        // 标签溢出：右侧显示 »，点击打开标签列表。
        if self.tabs_overflow(rect) && rect.w > 8 {
            let x = rect.right() - 3;
            canvas.fill_rect(x, rect.y, 3, 1, self.theme.tab_inactive_bg);
            canvas.text(
                x,
                rect.y,
                " » ",
                self.theme.accent,
                self.theme.tab_inactive_bg,
            );
        }
    }

    /// VSCode 布局：顶部菜单栏（品牌 + 菜单项 + 右侧工作区名）。
    fn draw_menu_bar(&self, canvas: &mut Canvas) {
        let Some(rect) = self.layout.menu else {
            return;
        };
        let bg = self.theme.tab_inactive_bg;
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, bg);
        let brand = "Textm";
        let brand_w = canvas.text_styled(
            rect.x + 1,
            rect.y,
            brand,
            self.theme.accent,
            bg,
            crate::render::grid::attr::BOLD,
        );
        canvas.put(
            rect.x + 1 + brand_w + 1,
            rect.y,
            '│',
            self.theme.divider(),
            bg,
        );
        for (index, item, title) in self.menu_bar_items() {
            let open = matches!(&self.overlay, Overlay::Menu(state) if state.index == index);
            let hovered = self.hover(item);
            if open || hovered {
                let item_bg = if open {
                    self.theme.selection
                } else {
                    self.theme.raised_bg()
                };
                canvas.fill_rect(item.x, item.y, item.w, item.h, item_bg);
            }
            let label = format!(" {title} ");
            canvas.text(
                item.x,
                item.y,
                &label,
                if open {
                    self.theme.fg
                } else {
                    self.theme.panel_fg
                },
                if open {
                    self.theme.selection
                } else if hovered {
                    self.theme.raised_bg()
                } else {
                    bg
                },
            );
        }
        let name = self
            .cwd
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| self.cwd.display().to_string());
        let chip = format!(" {} ", name);
        let chip_w = crate::render::canvas::text_width(&chip);
        let chip_x = rect.right().saturating_sub(chip_w + 1);
        if chip_x > rect.x + 20 {
            canvas.fill_rect(chip_x, rect.y, chip_w, 1, self.theme.raised_bg());
            canvas.text(
                chip_x,
                rect.y,
                &chip,
                self.theme.syntax.comment,
                self.theme.raised_bg(),
            );
        }
    }

    /// VSCode 布局：顶部标签栏（复用底部标签的绘制）。
    fn draw_tabs_top(&self, canvas: &mut Canvas) {
        let Some(rect) = self.layout.tabs_top else {
            return;
        };
        self.draw_editor_tabs(canvas, rect, true);
    }

    /// VSCode 布局：左侧活动栏（资源管理器 / 搜索 / Git，底部设置）。
    fn draw_activity_bar(&self, canvas: &mut Canvas) {
        let Some(rect) = self.layout.activity else {
            return;
        };
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.activity_bg);
        let icons = self.icon_set();
        let modes = [
            (SidebarMode::Explorer, icons.explorer),
            (SidebarMode::Search, icons.search),
            (SidebarMode::Git, icons.git),
        ];
        for (index, (mode, icon)) in modes.iter().enumerate() {
            let y = rect.y + 1 + index * 2;
            if y >= rect.bottom() {
                break;
            }
            let active = self.config.sidebar && self.sidebar.mode == *mode;
            let hovered = !active
                && self.hover(Rect {
                    x: rect.x,
                    y,
                    w: rect.w,
                    h: 1,
                });
            let bg = if active {
                self.theme.selection
            } else if hovered {
                self.theme.activity_bg.blend(self.theme.fg, 10)
            } else {
                self.theme.activity_bg
            };
            canvas.fill_rect(rect.x, y, rect.w, 1, bg);
            if active {
                canvas.put(rect.x, y, '▎', self.theme.accent, bg);
            }
            canvas.put(
                rect.x + 1,
                y,
                *icon,
                if active || hovered {
                    self.theme.accent
                } else {
                    self.theme.activity_fg.scale(0.72)
                },
                bg,
            );
        }
        if rect.h > 4 {
            let y = rect.bottom() - 1;
            let hovered = self.settings.is_none()
                && self.hover(Rect {
                    x: rect.x,
                    y,
                    w: rect.w,
                    h: 1,
                });
            let bg = if self.settings.is_some() {
                self.theme.selection
            } else if hovered {
                self.theme.activity_bg.blend(self.theme.fg, 10)
            } else {
                self.theme.activity_bg
            };
            canvas.fill_rect(rect.x, y, rect.w, 1, bg);
            canvas.put(
                rect.x + 1,
                y,
                '⚙',
                if hovered {
                    self.theme.accent
                } else {
                    self.theme.activity_fg.scale(0.72)
                },
                bg,
            );
        }
    }

    /// 侧栏 pane 底部的标签行：资源管理器 / 搜索 / Git。
    fn draw_sidebar_tabs(&self, canvas: &mut Canvas) {
        let rect = self.layout.sidebar_tabs;
        if rect.w < 3 {
            return;
        }
        canvas.fill_rect(rect.x, rect.y, rect.w, 1, self.theme.tab_inactive_bg);
        let icons = self.icon_set();
        let entries = [
            (SidebarMode::Explorer, icons.explorer, "资源"),
            (SidebarMode::Search, icons.search, "搜索"),
            (SidebarMode::Git, icons.git, "Git"),
        ];
        for (index, (mode, icon, name)) in entries.iter().enumerate() {
            let start = rect.x + rect.w * index / 3;
            let stop = rect.x + rect.w * (index + 1) / 3;
            let width = stop.saturating_sub(start);
            if width == 0 {
                continue;
            }
            let active = self.sidebar.mode == *mode;
            let hovered = !active
                && self.hover(Rect {
                    x: start,
                    y: rect.y,
                    w: width,
                    h: 1,
                });
            let (fg, bg) = if active {
                (self.theme.accent, self.theme.selection)
            } else if hovered {
                (self.theme.fg, self.theme.raised_bg())
            } else {
                (
                    self.theme.syntax.comment,
                    self.theme.tab_inactive_bg,
                )
            };
            canvas.fill_rect(start, rect.y, width, 1, bg);
            let label = if width >= 7 {
                format!(" {icon} {name} ")
            } else {
                format!(" {icon} ")
            };
            canvas.text_max(start, rect.y, width, &label, fg, bg);
            if index < 2 && stop > rect.x {
                canvas.put(
                    stop - 1,
                    rect.y,
                    '│',
                    self.theme.border,
                    self.theme.tab_inactive_bg,
                );
            }
        }
    }

    fn draw_sidebar(&self, canvas: &mut Canvas) {
        let Some(rect) = self.layout.sidebar else {
            return;
        };
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.panel_bg);
        let focused = matches!(self.focus, crate::ui::app::Focus::Sidebar);
        let title = match self.sidebar.mode {
            SidebarMode::Explorer => "资源管理器",
            SidebarMode::Search => "搜索",
            SidebarMode::Git => "Git",
        };
        self.frame(canvas, rect, title, focused, self.theme.panel_bg);
        let tabs = self.layout.sidebar_tabs;
        let inner = Rect {
            x: rect.x + 1,
            y: rect.y + 1,
            w: rect.w.saturating_sub(2),
            h: tabs.y.saturating_sub(rect.y + 1),
        };
        if inner.w < 2 || inner.h == 0 {
            return;
        }

        match self.sidebar.mode {
            SidebarMode::Explorer => self.draw_explorer(canvas, inner),
            SidebarMode::Search => {
                let mut flags = String::new();
                if self.workspace_case {
                    flags.push_str(" [Aa]");
                }
                if self.workspace_word {
                    flags.push_str(" [全词]");
                }
                if !self.config.workspace_ignore {
                    flags.push_str(" [不忽略]");
                }
                if !self.config.workspace_include.trim().is_empty() {
                    flags.push_str(" [包含]");
                }
                if !self.config.workspace_exclude.trim().is_empty() {
                    flags.push_str(" [排除]");
                }
                let query = if self.workspace_query.is_empty() {
                    format!("搜索：{flags}")
                } else if self.focus == crate::ui::app::Focus::Sidebar {
                    format!("搜索：{}▏{flags}", self.workspace_query)
                } else {
                    format!("搜索：{}{flags}", self.workspace_query)
                };
                canvas.text_max(
                    inner.x,
                    inner.y,
                    inner.w,
                    &query,
                    self.theme.fg,
                    self.theme.panel_bg,
                );
                let list_top = inner.y + 2;
                let note_rows = if self.workspace_note.is_empty() { 0 } else { 1 };
                let visible = inner.bottom().saturating_sub(list_top + note_rows);
                let start = if self.workspace_selected >= visible && visible > 0 {
                    self.workspace_selected + 1 - visible
                } else {
                    0
                };
                for (offset, hit) in self
                    .workspace_hits
                    .iter()
                    .skip(start)
                    .take(visible)
                    .enumerate()
                {
                    let index = start + offset;
                    let y = list_top + offset;
                    let selected = index == self.workspace_selected;
                    let hovered = !selected
                        && self.hover(Rect {
                            x: inner.x,
                            y,
                            w: inner.w,
                            h: 1,
                        });
                    let bg = if selected {
                        self.theme.selection
                    } else if hovered {
                        self.theme.hover_bg()
                    } else {
                        self.theme.panel_bg
                    };
                    canvas.fill_rect(inner.x, y, inner.w, 1, bg);
                    if selected {
                        canvas.put(inner.x, y, '▎', self.theme.accent, bg);
                    }
                    let relative = hit
                        .path
                        .strip_prefix(&self.cwd)
                        .unwrap_or(&hit.path)
                        .display()
                        .to_string();
                    let text = hit.text.trim();
                    let line = format!("{}:{}  {}", relative, hit.line + 1, text);
                    let color = if selected {
                        self.theme.fg
                    } else if text.is_empty() {
                        self.theme.syntax.comment
                    } else {
                        self.theme.syntax.string
                    };
                    canvas.text_max(inner.x + 1, y, inner.w.saturating_sub(1), &line, color, bg);
                }
                if !self.workspace_note.is_empty() {
                    let y = inner.bottom().saturating_sub(1);
                    canvas.text_max(
                        inner.x,
                        y,
                        inner.w,
                        &self.workspace_note,
                        self.theme.syntax.comment,
                        self.theme.panel_bg,
                    );
                }
            }
            SidebarMode::Git => {
                canvas.text_max(
                    inner.x,
                    inner.y,
                    inner.w,
                    &self.git.summary(),
                    self.theme.syntax.property,
                    self.theme.panel_bg,
                );
                let list_top = inner.y + 2;
                let visible = inner.bottom().saturating_sub(list_top + 1);
                let start = if self.git_selected >= visible && visible > 0 {
                    self.git_selected + 1 - visible
                } else {
                    0
                };
                for (offset, change) in self
                    .git
                    .changes
                    .iter()
                    .skip(start)
                    .take(visible)
                    .enumerate()
                {
                    let index = start + offset;
                    let y = list_top + offset;
                    let selected = index == self.git_selected;
                    let hovered = !selected
                        && self.hover(Rect {
                            x: inner.x,
                            y,
                            w: inner.w,
                            h: 1,
                        });
                    let bg = if selected {
                        self.theme.selection
                    } else if hovered {
                        self.theme.hover_bg()
                    } else {
                        self.theme.panel_bg
                    };
                    canvas.fill_rect(inner.x, y, inner.w, 1, bg);
                    if selected {
                        canvas.put(inner.x, y, '▎', self.theme.accent, bg);
                    }
                    let mark = if change.staged { "✓" } else { " " };
                    let line = format!("{mark} {} {}", change.status.trim(), change.path);
                    let color = if selected {
                        self.theme.fg
                    } else if change.status.contains('?') {
                        self.theme.syntax.comment
                    } else if change.staged {
                        self.theme.syntax.string
                    } else {
                        self.theme.syntax.property
                    };
                    canvas.text_max(inner.x + 1, y, inner.w.saturating_sub(1), &line, color, bg);
                }
                let hint = "Space 暂存  Enter 差异  c 提交  b 分支";
                canvas.text_max(
                    inner.x,
                    inner.bottom().saturating_sub(1),
                    inner.w,
                    hint,
                    self.theme.syntax.comment,
                    self.theme.panel_bg,
                );
            }
        }
        self.draw_sidebar_tabs(canvas);
    }

    fn draw_explorer(&self, canvas: &mut Canvas, rect: crate::ui::app::Rect) {
        let icons = self.icon_set();
        let visible = rect.h;
        let start = self
            .sidebar
            .selected
            .saturating_sub(visible.saturating_sub(1));
        for (offset, entry) in self
            .sidebar
            .entries
            .iter()
            .skip(start)
            .take(visible)
            .enumerate()
        {
            let index = start + offset;
            let y = rect.y + offset;
            let selected = index == self.sidebar.selected;
            let hovered = !selected
                && self.hover(Rect {
                    x: rect.x,
                    y,
                    w: rect.w,
                    h: 1,
                });
            let bg = if selected {
                self.theme.selection
            } else if hovered {
                self.theme.hover_bg()
            } else {
                self.theme.panel_bg
            };
            canvas.fill_rect(rect.x, y, rect.w, 1, bg);
            if selected {
                canvas.put(rect.x, y, '▎', self.theme.accent, bg);
            }
            let mut x = rect.x + 2 + entry.depth.min(10);
            let glyph = if entry.is_dir {
                if entry.expanded {
                    icons.folder_open
                } else {
                    icons.folder
                }
            } else {
                icons.file
            };
            let icon = format!("{glyph} ");
            let icon_color = if entry.is_dir {
                self.theme.accent
            } else {
                self.theme.syntax.comment
            };
            x += canvas.text(x, y, &icon, icon_color, bg);
            let name_color = if selected {
                self.theme.fg
            } else if entry.is_dir {
                self.theme.panel_fg
            } else {
                self.theme.fg
            };
            canvas.text_max(
                x,
                y,
                rect.right().saturating_sub(x),
                &entry.name,
                name_color,
                bg,
            );
        }
    }

    fn draw_editor(&self, canvas: &mut Canvas) {
        let views = self.pane_views();
        for (index, (tab_index, pane)) in views.iter().enumerate() {
            let Some(tab) = self.tabs.get(*tab_index) else {
                continue;
            };
            self.draw_editor_pane(canvas, tab, pane, index == self.group);
        }
        if views.is_empty() {
            let pane = self.layout.panes.first().copied().unwrap_or_default();
            if let Some(tab) = self.tabs.get(self.active) {
                self.draw_editor_pane(canvas, tab, &pane, true);
            }
        }
        self.draw_terminal(canvas);
    }

    fn draw_editor_pane(
        &self,
        canvas: &mut Canvas,
        tab: &Tab,
        pane: &crate::ui::app::PaneRects,
        focused: bool,
    ) {
        let rect = pane.editor;
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.bg);
        self.frame(canvas, rect, &Self::tab_title(tab), focused, self.theme.bg);
        self.draw_breadcrumbs(canvas, pane.breadcrumbs, tab);
        if let Some(image) = &tab.image {
            self.draw_image(canvas, image, pane.text);
        } else if tab.excel.is_some() {
            if let Some(minimap) = pane.minimap {
                canvas.fill_rect(minimap.x, minimap.y, minimap.w, minimap.h, self.theme.bg);
            }
            self.draw_excel_at(canvas, tab, pane.text);
        } else if Self::is_welcome_tab(tab) {
            self.draw_welcome(canvas, pane.text);
        } else {
            self.draw_gutter(canvas, tab, pane.editor, pane.text, pane.gutter);
            self.draw_text(canvas, tab, pane.text);
            if self.config.minimap {
                if let Some(minimap) = pane.minimap {
                    self.draw_minimap(canvas, tab, minimap);
                }
            }
        }
        self.draw_editor_tabs(canvas, pane.tabs, focused);
    }

    /// 空白文档的欢迎页：品牌、副标题与可点击的快捷入口。
    fn draw_welcome(&self, canvas: &mut Canvas, text: Rect) {
        let Some(welcome) = self.welcome(text) else {
            return;
        };
        let card = welcome.card;
        let bg = self.theme.bg.blend(self.theme.fg, 5);
        canvas.fill_rect(card.x, card.y, card.w, card.h, bg);
        self.frame(canvas, card, "", false, bg);
        canvas.text_styled(
            card.x + 3,
            card.y + 2,
            "Textm",
            self.theme.accent,
            bg,
            crate::render::grid::attr::BOLD,
        );
        canvas.text(card.x + 3 + 6, card.y + 2, "2.0", self.theme.syntax.comment, bg);
        canvas.text_max(
            card.x + 3,
            card.y + 3,
            card.w.saturating_sub(6),
            "终端里的文本编辑器 · 打开或输入",
            self.theme.syntax.comment,
            bg,
        );
        canvas.hline(
            card.x + 3,
            card.y + 4,
            card.w.saturating_sub(6),
            '─',
            self.theme.divider(),
            bg,
        );
        for (rect, label, shortcut, _) in &welcome.items {
            let hovered = self.hover(*rect);
            let row_bg = if hovered { self.theme.selection } else { bg };
            canvas.fill_rect(rect.x, rect.y, rect.w, 1, row_bg);
            canvas.put(
                rect.x + 1,
                rect.y,
                if hovered { '›' } else { '·' },
                if hovered {
                    self.theme.accent
                } else {
                    self.theme.divider()
                },
                row_bg,
            );
            canvas.text(
                rect.x + 3,
                rect.y,
                label,
                if hovered {
                    self.theme.fg
                } else {
                    self.theme.panel_fg
                },
                row_bg,
            );
            canvas.text_right(
                rect.right() - 2,
                rect.y,
                shortcut,
                if hovered {
                    self.theme.accent
                } else {
                    self.theme.syntax.comment
                },
                row_bg,
            );
        }
        canvas.text_max(
            card.x + 3,
            card.y + card.h - 2,
            card.w.saturating_sub(6),
            "直接输入即可开始编辑",
            self.theme.syntax.comment,
            bg,
        );
    }

    fn draw_breadcrumbs(&self, canvas: &mut Canvas, rect: Rect, tab: &Tab) {
        let hovered = self.hover(rect);
        let bg = if hovered {
            self.theme.bg.blend(self.theme.fg, 7)
        } else {
            self.theme.bg
        };
        canvas.fill_rect(rect.x, rect.y, rect.w, 1, bg);
        let chip_bg = bg.blend(self.theme.fg, 14);

        if let Some(book) = &tab.excel {
            let sheet = book.sheet();
            let reference = format!(
                "{}{}",
                crate::xlsx::column_name(self.excel_col),
                self.excel_row + 1
            );
            let input = if self.excel_editing {
                self.excel_input.clone()
            } else {
                sheet.cell_input(self.excel_row, self.excel_col)
            };
            let label = format!("{reference}  {input}");
            canvas.text_max(
                rect.x,
                rect.y,
                rect.w.saturating_sub(20),
                &label,
                self.theme.fg,
                bg,
            );
            let right = format!(" {} ", sheet.name);
            canvas.text_right(rect.right(), rect.y, &right, self.theme.accent, chip_bg);
            return;
        }

        let doc = &tab.doc;
        // 粘性滚动：滚动后在外层面包屑行显示当前所在作用域的首行，不遮挡代码。
        if self.config.sticky_scroll {
            if let Some(text) = sticky_line(tab) {
                let label = format!("⋯ {}", text);
                canvas.text_max(
                    rect.x,
                    rect.y,
                    rect.w.saturating_sub(12),
                    &label,
                    self.theme.syntax.property,
                    bg,
                );
                let right = format!(" {} ", tab.format_label());
                canvas.text_right(rect.right(), rect.y, &right, self.theme.syntax.comment, chip_bg);
                return;
            }
        }
        let path = doc
            .path
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "未命名".into());
        let mut x = rect.x;
        let parts: Vec<&str> = path.split(['\\', '/']).filter(|s| !s.is_empty()).collect();
        for (index, part) in parts.iter().enumerate() {
            if x >= rect.right().saturating_sub(2) {
                break;
            }
            let last = index + 1 == parts.len();
            let color = if last {
                self.theme.fg
            } else if hovered {
                self.theme.panel_fg
            } else {
                self.theme.syntax.comment
            };
            x += canvas.text_max(x, rect.y, rect.right().saturating_sub(x), part, color, bg);
            if !last && x + 3 < rect.right() {
                let chevron = if hovered {
                    self.theme.accent
                } else {
                    self.theme.divider()
                };
                x += canvas.text(x, rect.y, " › ", chevron, bg);
            }
        }
        let right = format!(" {} ", tab.format_label());
        canvas.text_right(rect.right(), rect.y, &right, self.theme.syntax.comment, chip_bg);
    }

    /// Excel 网格：可变列宽、合并单元格、冻结窗格、选区与单元格样式。
    fn draw_excel(&self, canvas: &mut Canvas, tab: &Tab) {
        self.draw_excel_at(canvas, tab, self.layout.text);
    }

    fn draw_excel_at(&self, canvas: &mut Canvas, tab: &Tab, rect: Rect) {
        let Some(book) = &tab.excel else {
            return;
        };
        let sheet = book.sheet();
        let active = book.active;
        let range = self.excel_range();
        let theme = &self.theme;
        let header_w = 5usize;
        if rect.w <= header_w + 2 || rect.h <= 2 {
            return;
        }

        // 可见列：冻结列固定在左侧，其余从 scroll_left 开始。
        let frozen_cols = sheet.freeze_cols.min(30);
        let mut columns: Vec<(usize, usize, usize)> = Vec::new();
        let mut x = rect.x + header_w;
        for col in 0..frozen_cols {
            if sheet.hidden_cols.contains(&col) {
                continue;
            }
            let width = excel_col_chars(sheet, col);
            if x + width >= rect.right() {
                break;
            }
            columns.push((col, x, width));
            x += width;
        }
        let first_col = tab.doc.scroll_left.max(frozen_cols);
        let mut col = first_col;
        let mut guard = 0;
        while x < rect.right() && guard < 4000 {
            guard += 1;
            if sheet.hidden_cols.contains(&col) {
                col += 1;
                continue;
            }
            let width = excel_col_chars(sheet, col).min(rect.right() - x);
            if width < 2 {
                break;
            }
            columns.push((col, x, width));
            x += width;
            col += 1;
        }

        // 可见行：冻结行固定在顶部，其余从 scroll_top 开始。
        let frozen_rows = sheet.freeze_rows.min(rect.h.saturating_sub(2));
        let mut rows: Vec<(usize, usize)> = Vec::new();
        let mut y = rect.y + 1;
        for row in 0..frozen_rows {
            if excel_row_hidden(sheet, row) {
                continue;
            }
            if y >= rect.bottom() {
                break;
            }
            rows.push((row, y));
            y += 1;
        }
        let first_row = tab.doc.scroll_top.max(frozen_rows);
        let mut row = first_row;
        let mut guard = 0;
        while y < rect.bottom() && guard < 200_000 {
            guard += 1;
            if excel_row_hidden(sheet, row) {
                row += 1;
                continue;
            }
            rows.push((row, y));
            y += 1;
            row += 1;
        }

        // 表头与行号
        canvas.fill_rect(rect.x, rect.y, header_w, rect.h, theme.panel_bg);
        canvas.fill_rect(rect.x + header_w, rect.y, rect.w - header_w, 1, theme.panel_bg);
        canvas.put(rect.x + header_w - 1, rect.y, '┼', theme.border, theme.panel_bg);
        for &(c, cx, cw) in &columns {
            let current = c == self.excel_col;
            let in_range = c >= range.c1 && c <= range.c2;
            let bg = if current { theme.selection } else { theme.panel_bg };
            canvas.fill_rect(cx, rect.y, cw, 1, bg);
            let fg = if current {
                theme.fg
            } else if in_range {
                theme.accent
            } else {
                theme.syntax.comment
            };
            canvas.text_max(
                cx + 1,
                rect.y,
                cw.saturating_sub(1),
                &crate::xlsx::column_name(c),
                fg,
                bg,
            );
        }

        for &(r, ry) in &rows {
            let current = r == self.excel_row;
            let head_bg = if current { theme.selection } else { theme.panel_bg };
            canvas.fill_rect(rect.x, ry, header_w, 1, head_bg);
            canvas.text_right(
                rect.x + header_w - 1,
                ry,
                &(r + 1).to_string(),
                if current { theme.fg } else { theme.gutter_fg },
                head_bg,
            );

            for &(c, cx, cw) in &columns {
                // 合并单元格只在左上角绘制，宽度覆盖所有可见列。
                let merge = sheet.merge_at(r, c);
                if let Some(merge) = merge {
                    if merge.r1 != r || merge.c1 != c {
                        continue;
                    }
                }
                let (start_x, width) = match merge {
                    Some(merge) => {
                        let mut start = None;
                        let mut total = 0usize;
                        for &(mc, mx, mw) in &columns {
                            if mc >= merge.c1 && mc <= merge.c2 {
                                if start.is_none() {
                                    start = Some(mx);
                                }
                                total += mw;
                            }
                        }
                        match start {
                            Some(start) => (start, total),
                            None => continue,
                        }
                    }
                    None => (cx, cw),
                };
                if width < 2 {
                    continue;
                }

                let selected =
                    r >= range.r1 && r <= range.r2 && c >= range.c1 && c <= range.c2;
                let style = book.style_at(active, r, c);
                let fill = excel_fill(style.fill, theme);
                let bg = if selected { theme.selection } else { fill };
                canvas.fill_rect(start_x, ry, width, 1, bg);

                let value = if selected
                    && self.excel_editing
                    && r == self.excel_row
                    && c == self.excel_col
                {
                    if self.cursor_visible {
                        format!("{}▏", self.excel_input)
                    } else {
                        self.excel_input.clone()
                    }
                } else {
                    book.display(active, r, c)
                };
                if !value.is_empty() {
                    let fg = if selected {
                        theme.fg
                    } else {
                        excel_text(style.text_color, style.fill, theme)
                    };
                    let shown = crate::core::unicode::truncate_width(&value, width.saturating_sub(2));
                    let align = if !style.h_align.is_empty() {
                        style.h_align.as_str()
                    } else if matches!(
                        book.value(active, r, c),
                        crate::xlsx::Value::Number(_)
                    ) {
                        "right"
                    } else {
                        "left"
                    };
                    if align == "right" {
                        canvas.text_right(start_x + width - 1, ry, &shown, fg, bg);
                    } else if align == "center" {
                        let text_w = crate::render::canvas::text_width(&shown);
                        let offset = width.saturating_sub(text_w) / 2;
                        canvas.text_max(start_x + offset.max(1), ry, width - 1, &shown, fg, bg);
                    } else {
                        canvas.text_max(start_x + 1, ry, width - 1, &shown, fg, bg);
                    }
                }
                canvas.put(start_x + width - 1, ry, '│', theme.border, bg);
            }
        }

        // 冻结窗格分隔线：只画竖向标记，避免覆盖冻结行文字。
        if sheet.freeze_cols > 0 && frozen_cols > 0 {
            if let Some(&(_, cx, _)) = columns.iter().find(|(c, _, _)| *c >= frozen_cols) {
                for &(_, ry) in &rows {
                    canvas.put(cx - 1, ry, '┃', theme.accent, theme.bg);
                }
            }
        }
    }

    fn draw_gutter(
        &self,
        canvas: &mut Canvas,
        tab: &Tab,
        editor: Rect,
        text: Rect,
        gutter: usize,
    ) {
        let doc = &tab.doc;
        let cursor_line = doc.primary().pos.line;
        let height = text.h;
        let bp_key = doc.path.as_ref().map(|p| crate::debug::normalize(p));
        let bp_lines = bp_key
            .as_ref()
            .and_then(|key| self.debug.breakpoints.get(key));
        let stopped_at: Option<(std::path::PathBuf, usize)> = if self.debug.stopped {
            self.debug.frames.first().and_then(|frame| {
                frame
                    .path
                    .as_ref()
                    .map(|path| (crate::debug::normalize(path), frame.line.saturating_sub(1)))
            })
        } else {
            None
        };
        let inner_x = editor.x + 1;
        let inner_w = editor.w.saturating_sub(2);
        for screen in 0..height {
            let row_index = tab.top_row + screen;
            let Some(row) = tab.rows.get(row_index) else {
                break;
            };
            let y = text.y + screen;
            let is_current = row.line == cursor_line;
            let bg = if is_current {
                self.theme.current_line_bg()
            } else {
                self.theme.bg
            };
            canvas.fill_rect(inner_x, y, inner_w, 1, bg);
            if row.first {
                let num = format!("{}", row.line + 1);
                let width = num.len();
                let area = gutter.saturating_sub(1);
                let start = inner_x + area.saturating_sub(width);
                canvas.text_styled(
                    start,
                    y,
                    &num,
                    if is_current {
                        self.theme.accent
                    } else {
                        self.theme.gutter_fg
                    },
                    bg,
                    if is_current {
                        crate::render::grid::attr::BOLD
                    } else {
                        0
                    },
                );
                if is_current {
                    canvas.put(inner_x, y, '▏', self.theme.accent, bg);
                }
                if doc.bookmarks.contains(&row.line) {
                    canvas.put(inner_x, y, '●', self.theme.accent, bg);
                }
                match tab.git_marks.get(row.line) {
                    Some(crate::core::diff::LineMark::Added) => {
                        canvas.put(inner_x, y, '▎', self.theme.added, bg);
                    }
                    Some(crate::core::diff::LineMark::DeletedAbove) => {
                        canvas.put(inner_x, y, '▁', self.theme.removed, bg);
                    }
                    Some(crate::core::diff::LineMark::Modified) => {
                        canvas.put(inner_x, y, '▎', self.theme.syntax.number, bg);
                    }
                    _ => {}
                }
                if tab.folds.fold_at(row.line) {
                    let marker = if tab.folds.is_collapsed(row.line) { '▸' } else { '▾' };
                    canvas.put(inner_x + 1, y, marker, self.theme.gutter_fg, bg);
                }
                if bp_lines.map(|lines| lines.contains(&row.line)).unwrap_or(false) {
                    canvas.put(inner_x, y, '●', self.theme.removed, bg);
                }
                if let Some((path, line)) = &stopped_at {
                    if *line == row.line && bp_key.as_ref() == Some(path) {
                        canvas.put(inner_x + 1, y, '▶', self.theme.accent, bg);
                    }
                }
            }
            // 行号槽与正文之间的低对比分隔线。
            let divider_x = text.x.saturating_sub(1);
            if divider_x >= inner_x && divider_x < editor.right() {
                canvas.put(divider_x, y, '│', self.theme.divider(), bg);
            }
        }
        let _ = canvas;
    }

    fn draw_text(&self, canvas: &mut Canvas, tab: &Tab, text_rect: Rect) {
        let doc = &tab.doc;
        let cursor_line = doc.primary().pos.line;
        let height = text_rect.h;
        let width = text_rect.w;
        let bracket_pair = doc.bracket_pair(doc.primary().pos);

        for screen in 0..height {
            let row_index = tab.top_row + screen;
            let Some(row) = tab.rows.get(row_index).copied() else {
                break;
            };
            let y = text_rect.y + screen;
            let is_current = row.line == cursor_line;
            let base_bg = if is_current {
                self.theme.current_line_bg()
            } else {
                self.theme.bg
            };
            canvas.fill_rect(text_rect.x, y, width, 1, base_bg);

            let line = doc.line(row.line);
            let chars: Vec<char> = line.chars().collect();
            // 彩虹括号：按嵌套深度着色（视觉行从逻辑行起点补齐深度）。
            let rainbow = self.config.rainbow_brackets;
            let mut depth: i32 = 0;
            if rainbow && row.start > 0 {
                for ch in chars.iter().take(row.start) {
                    match ch {
                        '(' | '[' | '{' => depth += 1,
                        ')' | ']' | '}' => depth -= 1,
                        _ => {}
                    }
                }
            }
            let tokens = tab.tokens(row.line);
            let selections = selection_ranges(doc, row.line);
            let indent_chars = editor::indent_end(line);
            let indent_display =
                editor::display_col(doc, row.line, indent_chars, doc.tab_width.max(1));
            let search_ranges = self
                .search_engine
                .as_ref()
                .map(|engine| {
                    let mut ranges = Vec::new();
                    let mut from = 0usize;
                    while let Some((start, end)) = engine.find_in_line(line, from) {
                        ranges.push((start, end));
                        from = if end > start { end } else { end + 1 };
                    }
                    ranges
                })
                .unwrap_or_default();
            // 内联提示：按列插入浅色文本，跟随本视觉行。
            let line_hints: Vec<(usize, &str)> = doc
                .path
                .as_ref()
                .and_then(|path| self.inlay_hints.get(path))
                .map(|list| {
                    list.iter()
                        .filter(|hint| {
                            // 光标所在行不画提示，避免与终端光标列对不齐。
                            row.line != cursor_line
                                && hint.line == row.line
                                && hint.col >= row.start
                                && hint.col <= row.end
                        })
                        .map(|hint| (hint.col, hint.label.as_str()))
                        .collect()
                })
                .unwrap_or_default();
            let mut hint_index = 0usize;

            let mut x = 0usize;
            let mut col = row.start;
            let mut token_index = 0usize;
            let mut display = editor::display_col(doc, row.line, row.start, doc.tab_width);
            while col < row.end && x < width {
                while let Some((hint_col, label)) = line_hints.get(hint_index).copied() {
                    if hint_col > col || x >= width {
                        break;
                    }
                    let drawn = canvas.text_max(
                        text_rect.x + x,
                        y,
                        width - x,
                        label,
                        self.theme.syntax.comment,
                        base_bg,
                    );
                    x += drawn;
                    display += drawn;
                    hint_index += 1;
                }
                if x >= width {
                    break;
                }
                let ch = chars.get(col).copied().unwrap_or(' ');
                while token_index < tokens.len() && tokens[token_index].end <= col {
                    token_index += 1;
                }
                let kind = tokens
                    .get(token_index)
                    .filter(|t| t.start <= col && col < t.end)
                    .map(|t| t.kind)
                    .unwrap_or(TokenKind::Operator);
                let mut fg = if tokens.get(token_index).map(|t| t.start <= col && col < t.end).unwrap_or(false) {
                    self.theme.token_color(kind)
                } else {
                    self.theme.fg
                };
                if rainbow {
                    match ch {
                        '(' | '[' | '{' => {
                            fg = rainbow_color(self.theme, depth);
                            depth += 1;
                        }
                        ')' | ']' | '}' => {
                            depth -= 1;
                            fg = rainbow_color(self.theme, depth);
                        }
                        _ => {}
                    }
                }
                // 空白字符
                let mut draw_ch = ch;
                let weight = char_width(ch).max(1);
                if ch == '\t' {
                    let stop = doc.tab_width.max(1);
                    let spaces = stop - (display % stop);
                    for i in 0..spaces {
                        if x + i >= width {
                            break;
                        }
                        let bg = selection_bg(&selections, col, &search_ranges, base_bg, self.theme.selection, self.theme.find_bg);
                        let cell = if self.show_whitespace { '→' } else { ' ' };
                        canvas.put(text_rect.x + x + i, y, cell, self.theme.syntax.comment, bg);
                    }
                    x += spaces;
                    display += spaces;
                    col += 1;
                    continue;
                }
                if ch == ' ' && self.show_whitespace {
                    fg = self.theme.syntax.comment;
                    draw_ch = '·';
                }
                let mut bg = selection_bg(&selections, col, &search_ranges, base_bg, self.theme.selection, self.theme.find_bg);
                // 缩进参考线：每级缩进画一条淡竖线。
                if self.config.indent_guides
                    && ch == ' '
                    && x < indent_display
                    && x % doc.tab_width.max(1) == 0
                {
                    canvas.put(text_rect.x + x, y, '│', self.theme.border, bg);
                    x += 1;
                    display += 1;
                    col += 1;
                    continue;
                }
                // 搜索命中优先显示
                if search_ranges.iter().any(|(s, e)| *s <= col && col < *e) {
                    bg = self.theme.find_bg;
                }
                if col == doc.primary().pos.col && row.line == cursor_line {
                    // 光标由控制台绘制，这里用呼吸底色标示位置。
                    let glow = self.pulse(22, 30, 58);
                    bg = self.theme.bg.blend(self.theme.accent, glow);
                }
                // 括号匹配：光标处括号与其配对位置使用强调底色。
                if let Some((first, second)) = bracket_pair {
                    if (row.line == first.line && col == first.col)
                        || (row.line == second.line && col == second.col)
                    {
                        bg = self.theme.bg.blend(self.theme.accent, 55);
                    }
                }
                canvas.put(text_rect.x + x, y, draw_ch, fg, bg);
                // 宽字符的第二个单元保持背景一致
                if weight == 2 && x + 1 < width {
                    canvas.set_cell_bg(text_rect.x + x + 1, y, bg);
                }
                x += weight;
                display += weight;
                col += 1;
            }
            // 行尾提示（列号等于行尾）在字符循环之后绘制。
            while let Some((_, label)) = line_hints.get(hint_index).copied() {
                if x >= width {
                    break;
                }
                let drawn = canvas.text_max(
                    text_rect.x + x,
                    y,
                    width - x,
                    label,
                    self.theme.syntax.comment,
                    base_bg,
                );
                x += drawn;
                hint_index += 1;
            }
            // 行尾之后用当前行背景填充（已经 fill_rect）
        }
    }

    /// 签名帮助面板：跟随触发位置，非模态，不拦截输入。
    fn draw_signature(&self, canvas: &mut Canvas) {
        let Some(state) = &self.signature_help else {
            return;
        };
        let tab = self.tab();
        let doc = &tab.doc;
        if doc.path.as_deref() != Some(state.path.as_path()) {
            return;
        }
        // 光标离开触发行后自动隐藏。
        if doc.primary().pos.line != state.line {
            return;
        }
        let Some((label, docs)) = state.signatures.get(state.active) else {
            return;
        };
        let text_rect = self.layout.text;
        let width = 56.min(text_rect.w.saturating_sub(2));
        if width < 24 {
            return;
        }
        let docs_line = docs.lines().next().unwrap_or("");
        let height = if docs_line.is_empty() { 3 } else { 4 };
        let row = editor::row_of_pos(&tab.rows, crate::core::document::Pos::new(state.line, state.col));
        if row < tab.top_row {
            return;
        }
        let screen = row - tab.top_row;
        if screen >= text_rect.h {
            return;
        }
        // 优先画在光标下一行，空间不足时翻到上方。
        let y = if screen + height < text_rect.h {
            text_rect.y + screen + 1
        } else if screen >= height {
            text_rect.y + screen - height
        } else {
            text_rect.y
        };
        let x = text_rect.x + 2;
        canvas.fill_rect(x, y, width, height, self.theme.panel_bg);
        canvas.border(x, y, width, height, self.theme.accent, self.theme.panel_bg);
        canvas.text_max(
            x + 2,
            y + 1,
            width - 4,
            &label,
            self.theme.fg,
            self.theme.panel_bg,
        );
        if !docs_line.is_empty() {
            canvas.text_max(
                x + 2,
                y + 2,
                width - 4,
                docs_line,
                self.theme.syntax.comment,
                self.theme.panel_bg,
            );
        }
        let footer = format!(
            "签名 {}/{} · 参数 {}",
            state.active + 1,
            state.signatures.len(),
            state.parameter + 1
        );
        canvas.text_right(
            x + width - 2,
            y + height - 1,
            &footer,
            self.theme.syntax.comment,
            self.theme.panel_bg,
        );
    }

    fn draw_minimap(&self, canvas: &mut Canvas, tab: &Tab, rect: Rect) {
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.minimap_bg);
        canvas.vline(rect.x, rect.y, rect.h, '│', self.theme.border, self.theme.minimap_bg);
        let rows = tab.rows.len().max(1);
        let visible = self.text_height().max(1);
        let top_ratio = tab.top_row as f32 / rows as f32;
        let bottom_ratio = (tab.top_row + visible) as f32 / rows as f32;
        for y in 0..rect.h {
            let ratio = y as f32 / rect.h.max(1) as f32;
            let row_index = (ratio * rows as f32) as usize;
            let Some(row) = tab.rows.get(row_index) else {
                continue;
            };
            let in_view = ratio >= top_ratio && ratio <= bottom_ratio;
            let bg = if in_view {
                self.theme.bg.blend(self.theme.fg, 16)
            } else {
                self.theme.minimap_bg
            };
            let line = tab.doc.line(row.line);
            let chars: Vec<char> = line.chars().take(rect.w * 4).collect();
            if chars.is_empty() {
                continue;
            }
            for column in 0..rect.w.saturating_sub(1) {
                let index = (column * chars.len()) / rect.w.saturating_sub(1).max(1);
                let ch = chars.get(index).copied().unwrap_or(' ');
                if ch == ' ' || ch == '\t' {
                    continue;
                }
                let color = self.theme.syntax.comment;
                canvas.put(rect.x + 1 + column, rect.y + y, '•', color, bg);
            }
        }
        // 视口范围：在左侧分隔线上用强调色标出。
        if rows > visible {
            let start_y = (top_ratio * rect.h as f32) as usize;
            let end_y = ((bottom_ratio * rect.h as f32) as usize).min(rect.h.saturating_sub(1));
            for y in start_y..=end_y {
                canvas.put(
                    rect.x,
                    rect.y + y,
                    '▏',
                    self.theme.accent,
                    self.theme.minimap_bg,
                );
            }
        }
    }

    fn draw_image(&self, canvas: &mut Canvas, image: &crate::image::Image, rect: Rect) {
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.bg);
        if image.pixels.is_empty() || image.width == 0 || image.height == 0 {
            canvas.text(rect.x, rect.y, "图片已打开，但当前无法解码该格式。", self.theme.syntax.comment, self.theme.bg);
            return;
        }
        // 半块字符：一个单元格显示上下两个像素
        let rows = rect.h * 2;
        let cols = rect.w;
        for y in 0..rect.h {
            for x in 0..cols {
                let top_y = (y * 2 * 1000) / 1000;
                let bottom_y = y * 2 + 1;
                let top = sample(image, x, cols, top_y, rows);
                let bottom = sample(image, x, cols, bottom_y, rows);
                canvas.put(rect.x + x, rect.y + y, '▀', top, bottom);
            }
        }
    }

    /// 底部终端面板。
    fn draw_terminal(&self, canvas: &mut Canvas) {
        let Some(rect) = self.layout.terminal else {
            return;
        };
        let Some(term) = self.terminal.as_ref() else {
            return;
        };
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.bg);
        self.frame(canvas, rect, "终端", self.term_focus, self.theme.bg);
        let hint = if self.term_focus == false {
            " Ctrl+` 聚焦 "
        } else {
            " Esc 返回编辑器 "
        };
        if rect.w > 30 {
            canvas.text_right(
                rect.right() - 2,
                rect.y,
                hint,
                self.theme.syntax.comment,
                self.theme.bg,
            );
        }
        let inner = Rect {
            x: rect.x + 1,
            y: rect.y + 1,
            w: rect.w.saturating_sub(2),
            h: rect.h.saturating_sub(2),
        };
        if inner.w == 0 || inner.h == 0 {
            return;
        }
        let focus = self.term_focus;
        let theme = self.theme;
        term.with_screen(|screen| {
            for y in 0..inner.h.min(screen.rows) {
                for x in 0..inner.w.min(screen.cols) {
                    let cell = screen.cell(x, y);
                    if cell.ch == '\u{0}' || cell.ch == ' ' {
                        let bg = cell.bg.unwrap_or(theme.bg);
                        canvas.fill_rect(inner.x + x, inner.y + y, 1, 1, bg);
                        continue;
                    }
                    let fg = cell.fg.unwrap_or(theme.fg);
                    let bg = cell.bg.unwrap_or(theme.bg);
                    canvas.put(inner.x + x, inner.y + y, cell.ch, fg, bg);
                }
            }
            if focus {
                let cx = inner.x + screen.cur_x.min(inner.w.saturating_sub(1));
                let cy = inner.y + screen.cur_y.min(inner.h.saturating_sub(1));
                canvas.set_cell_bg(cx, cy, theme.accent);
            }
        });
    }

    /// 底部 Ex / 搜索命令行。
    fn draw_cmdline(&self, canvas: &mut Canvas, state: &crate::ui::app::CmdlineState) {
        let rect = self.layout.status;
        canvas.fill_rect(rect.x, rect.y, rect.w, 1, self.theme.panel_bg);
        let text = format!("{}{}", state.prefix, state.input);
        let width = crate::render::canvas::text_width(&text);
        canvas.text_max(
            rect.x,
            rect.y,
            rect.w.saturating_sub(2),
            &text,
            self.theme.fg,
            self.theme.panel_bg,
        );
        let cursor = rect.x + width.min(rect.w.saturating_sub(2));
        canvas.put(cursor, rect.y, '▏', self.theme.accent, self.theme.panel_bg);
    }

    fn draw_status(&self, canvas: &mut Canvas, items: &[crate::ui::app::StatusItem]) {
        let rect = self.layout.status;
        let bg = self.theme.status_bg;
        canvas.fill_rect(rect.x, rect.y, rect.w, 1, bg);

        let pill_left = items
            .iter()
            .map(|item| item.rect.x)
            .min()
            .unwrap_or(rect.right());

        let (mode_text, mode_bg) = if self.config.vim {
            let label = format!(" {} ", self.vim.mode.label());
            let color = match self.vim.mode {
                crate::core::vim::Mode::Insert => self.theme.added,
                crate::core::vim::Mode::Replace => self.theme.removed,
                crate::core::vim::Mode::Visual
                | crate::core::vim::Mode::VisualLine
                | crate::core::vim::Mode::VisualBlock => self.theme.syntax.number,
                _ => self.theme.accent,
            };
            (label, color)
        } else {
            (" TEXTM ".to_string(), self.theme.accent)
        };
        canvas.text_styled(
            rect.x,
            rect.y,
            &mode_text,
            self.theme.status_fg,
            mode_bg,
            crate::render::grid::attr::BOLD,
        );
        let message_x = rect.x + crate::render::canvas::text_width(&mode_text) + 1;
        if self.status_visible() && message_x < pill_left {
            // 4 秒后开始淡出，8 秒完全让位给键位提示。
            let age = self.status_at.elapsed().as_secs_f32();
            let fade = if age <= 4.0 {
                1.0
            } else {
                ((8.0 - age) / 4.0).clamp(0.0, 1.0)
            };
            let t = (fade * 255.0) as u8;
            let base = if self.status_error {
                self.theme.removed
            } else {
                bg.blend(self.theme.accent, 14)
            };
            let message_bg = bg.blend(base, t);
            let message_fg = message_bg.blend(self.theme.status_fg, t);
            canvas.fill_rect(
                message_x,
                rect.y,
                pill_left.saturating_sub(message_x),
                1,
                message_bg,
            );
            if message_x > rect.x + 1 {
                canvas.put(
                    message_x - 1,
                    rect.y,
                    '│',
                    self.theme.divider(),
                    bg,
                );
            }
            canvas.text_max(
                message_x + 1,
                rect.y,
                pill_left.saturating_sub(message_x + 2),
                &self.status,
                message_fg,
                message_bg,
            );
        }
        // 没有消息时，左侧显示可点击的键位提示（见 draw_hints）。

        for item in items {
            if item.rect.x > rect.x {
                canvas.put(item.rect.x - 1, rect.y, '│', self.theme.divider(), bg);
            }
            let pill_bg = if self.hover(item.rect) {
                bg.blend(self.theme.accent, 30)
            } else {
                bg.blend(self.theme.fg, 12)
            };
            if let Some(warn) = item.label.find('⚠') {
                let (errors, warnings) = item.label.split_at(warn);
                let drawn = canvas.text(item.rect.x, rect.y, errors, self.theme.removed, pill_bg);
                canvas.text(
                    item.rect.x + drawn,
                    rect.y,
                    warnings,
                    self.theme.syntax.number,
                    pill_bg,
                );
                continue;
            }
            let color = if item.label.contains('ⓧ') {
                self.theme.removed
            } else {
                self.theme.status_fg
            };
            canvas.text(item.rect.x, rect.y, &item.label, color, pill_bg);
        }
    }

    /// 可点击提示条：面板标题右侧、标签行右侧、状态栏左侧。
    fn draw_hints(&self, canvas: &mut Canvas, items: &[crate::ui::app::StatusItem]) {
        let status_y = self.layout.status.y;
        for hint in self.hints_with(items) {
            let hovered = self
                .mouse_pos
                .map(|(x, y)| hint.rect.contains(x, y))
                .unwrap_or(false);
            let bg = if hovered {
                hint.bg.blend(self.theme.accent, 70)
            } else if hint.rect.y == status_y {
                hint.bg.blend(self.theme.fg, 14)
            } else {
                hint.bg
            };
            let fg = if hovered {
                self.theme.fg
            } else {
                self.theme.syntax.comment
            };
            let text = format!(" {} ", hint.label);
            canvas.fill_rect(hint.rect.x, hint.rect.y, hint.rect.w, 1, bg);
            canvas.text_max(
                hint.rect.x,
                hint.rect.y,
                hint.rect.w,
                &text,
                fg,
                bg,
            );
        }
    }

    fn draw_overlays(&self, canvas: &mut Canvas) {
        // 签名面板在浮层之下，列表 / 提示会遮住它。
        self.draw_signature(canvas);
        if let Overlay::Menu(state) = &self.overlay {
            self.draw_menu_overlay(canvas, state);
        }
        if let Overlay::Keys(_) = &self.overlay {
            self.draw_keys(canvas);
        }
        if let Overlay::Context(_) = &self.overlay {
            self.draw_context(canvas);
        }
        if let Overlay::Cmdline(state) = &self.overlay {
            self.draw_cmdline(canvas, state);
        }
        if let Overlay::List(state) = &self.overlay {
            self.draw_list(canvas, state);
        }
        if let Overlay::Find(state) = &self.overlay {
            self.draw_find(canvas, state);
        }
        if let Overlay::Prompt(state) = &self.overlay {
            self.draw_prompt(canvas, state);
        }
        if let Overlay::Confirm(state) = &self.overlay {
            self.draw_confirm(canvas, state);
        }
    }

    /// which-key：右下角的键位速查面板，按下列出的键即执行。
    fn draw_keys(&self, canvas: &mut Canvas) {
        let rect = self.keys_rect();
        self.shadow(canvas, rect);
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.panel_bg);
        self.frame(canvas, rect, "键位", true, self.theme.panel_bg);
        let close = " Esc 关闭 ";
        canvas.text_right(
            rect.right() - 2,
            rect.y,
            close,
            self.theme.syntax.comment,
            self.theme.panel_bg,
        );
        let hints = crate::ui::app::KEY_HINTS;
        let rows = (hints.len() + 1) / 2;
        let col_w = rect.w.saturating_sub(2) / 2;
        let key_w = 13.min(col_w.saturating_sub(6));
        for (index, hint) in hints.iter().enumerate() {
            let column = index / rows.max(1);
            let row = index % rows.max(1);
            let x = rect.x + 1 + column * col_w;
            let y = rect.y + 1 + row;
            if y >= rect.bottom().saturating_sub(1) || col_w < 8 {
                break;
            }
            canvas.text_max(x, y, key_w, hint.keys, self.theme.syntax.property, self.theme.panel_bg);
            canvas.text_max(
                x + key_w,
                y,
                col_w.saturating_sub(key_w + 1),
                hint.label,
                self.theme.fg,
                self.theme.panel_bg,
            );
        }
    }

    /// 右键上下文菜单。
    fn draw_context(&self, canvas: &mut Canvas) {
        let Overlay::Context(state) = &self.overlay else {
            return;
        };
        let rect = self.context_rect();
        if rect.w < 4 || rect.h < 3 {
            return;
        }
        self.shadow(canvas, rect);
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.panel_bg);
        self.frame(canvas, rect, "", true, self.theme.panel_bg);
        for (index, item) in state.items.iter().enumerate() {
            let y = rect.y + 1 + index;
            if y >= rect.bottom().saturating_sub(1) {
                break;
            }
            let selected = index == state.selected;
            let hovered = !selected
                && self.hover(Rect {
                    x: rect.x + 1,
                    y,
                    w: rect.w.saturating_sub(2),
                    h: 1,
                });
            let bg = if selected {
                self.theme.selection
            } else if hovered {
                self.theme.raised_bg()
            } else {
                self.theme.panel_bg
            };
            canvas.fill_rect(rect.x + 1, y, rect.w.saturating_sub(2), 1, bg);
            if selected {
                let bar = self
                    .theme
                    .accent
                    .blend(self.theme.selection, self.pulse(30, 0, 110));
                canvas.put(rect.x + 1, y, '▎', bar, bg);
            }
            canvas.text_max(
                rect.x + 3,
                y,
                rect.w.saturating_sub(5),
                &item.label,
                self.theme.fg,
                bg,
            );
        }
    }

    fn draw_menu_overlay(&self, canvas: &mut Canvas, state: &crate::ui::app::MenuState) {
        let rect = self.menu_rect(state.index);
        self.shadow(canvas, rect);
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.panel_bg);
        let menus = self.menus();
        let title = menus.get(state.index).map(|menu| menu.title).unwrap_or("");
        self.frame(canvas, rect, title, true, self.theme.panel_bg);
        let items = menus
            .get(state.index)
            .map(|menu| menu.items)
            .unwrap_or(&[]);
        for (index, item) in items.iter().enumerate() {
            let y = rect.y + 1 + index;
            if y >= rect.bottom().saturating_sub(1) {
                break;
            }
            let selected = index == state.selected;
            let hovered = !selected
                && self.hover(Rect {
                    x: rect.x + 1,
                    y,
                    w: rect.w.saturating_sub(2),
                    h: 1,
                });
            let bg = if selected {
                self.theme.selection
            } else if hovered {
                self.theme.raised_bg()
            } else {
                self.theme.panel_bg
            };
            canvas.fill_rect(rect.x + 1, y, rect.w.saturating_sub(2), 1, bg);
            if selected {
                let bar = self
                    .theme
                    .accent
                    .blend(self.theme.selection, self.pulse(30, 0, 110));
                canvas.put(rect.x + 1, y, '▎', bar, bg);
            }
            canvas.text_max(
                rect.x + 3,
                y,
                rect.w.saturating_sub(5),
                item.title,
                self.theme.fg,
                bg,
            );
            if !item.shortcut.is_empty() {
                canvas.text_right(
                    rect.right() - 2,
                    y,
                    item.shortcut,
                    if selected || hovered {
                        self.theme.panel_fg
                    } else {
                        self.theme.syntax.comment
                    },
                    bg,
                );
            }
        }
    }

    fn draw_list(&self, canvas: &mut Canvas, state: &crate::ui::app::ListState) {
        let rect = self.list_rect();
        self.shadow(canvas, rect);
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.panel_bg);
        self.frame(canvas, rect, "", true, self.theme.panel_bg);
        let title = if state.query.is_empty() {
            match state.kind {
                crate::ui::app::ListKind::Command => format!("{}：>", state.title),
                crate::ui::app::ListKind::QuickOpen => format!("{}：输入文件名", state.title),
                _ => state.title.clone(),
            }
        } else {
            format!("{}：{}", state.title, state.query)
        };
        canvas.text_max(
            rect.x + 2,
            rect.y + 1,
            rect.w.saturating_sub(4),
            &title,
            self.theme.fg,
            self.theme.panel_bg,
        );
        canvas.hline(
            rect.x + 1,
            rect.y + 2,
            rect.w.saturating_sub(2),
            '─',
            self.theme.border,
            self.theme.panel_bg,
        );
        let list_height = rect.h.saturating_sub(5);
        let selected = state.selected.min(state.filtered.len().saturating_sub(1));
        let scroll = selected.saturating_sub(list_height.saturating_sub(1));
        for (offset, index) in state
            .filtered
            .iter()
            .skip(scroll)
            .take(list_height)
            .enumerate()
        {
            let item = &state.items[*index];
            let y = rect.y + 3 + offset;
            let selected = scroll + offset == state.selected;
            let hovered = !selected
                && self.hover(Rect {
                    x: rect.x + 1,
                    y,
                    w: rect.w.saturating_sub(2),
                    h: 1,
                });
            let bg = if selected {
                self.theme.selection
            } else if hovered {
                self.theme.raised_bg()
            } else {
                self.theme.panel_bg
            };
            canvas.fill_rect(rect.x + 1, y, rect.w.saturating_sub(2), 1, bg);
            if selected {
                let bar = self
                    .theme
                    .accent
                    .blend(self.theme.selection, self.pulse(30, 0, 110));
                canvas.put(rect.x + 1, y, '▎', bar, bg);
            }
            let query = state.query.trim_start_matches(['>', '@', '#']).trim();
            if !query.is_empty()
                && matches!(
                    state.kind,
                    crate::ui::app::ListKind::Command | crate::ui::app::ListKind::QuickOpen
                )
            {
                self.title_highlighted(
                    canvas,
                    rect.x + 3,
                    y,
                    rect.w.saturating_sub(5),
                    &item.title,
                    query,
                    self.theme.fg,
                    bg,
                );
            } else {
                canvas.text_max(
                    rect.x + 3,
                    y,
                    rect.w.saturating_sub(5),
                    &item.title,
                    self.theme.fg,
                    bg,
                );
            }
            if !item.detail.is_empty() {
                let detail_color = if selected {
                    self.theme.fg
                } else {
                    self.theme.syntax.comment
                };
                canvas.text_right(rect.right() - 2, y, &item.detail, detail_color, bg);
            }
        }
        let footer_y = rect.bottom().saturating_sub(2);
        let help = if matches!(
            state.kind,
            crate::ui::app::ListKind::Command | crate::ui::app::ListKind::QuickOpen
        ) {
            "> 命令  @ 符号  # 工作区  : 行号  ·  ↑↓ 选择  Enter 确认  Esc 关闭"
        } else {
            "↑↓ 选择  Enter 确认  Esc 关闭"
        };
        canvas.text(
            rect.x + 2,
            footer_y,
            help,
            self.theme.syntax.comment,
            self.theme.panel_bg,
        );
        let footer = format!("{} 项 ", state.filtered.len());
        canvas.text_right(
            rect.right() - 2,
            footer_y,
            &footer,
            self.theme.syntax.comment,
            self.theme.panel_bg,
        );
    }

    fn draw_find(&self, canvas: &mut Canvas, state: &crate::ui::app::FindState) {
        let rect = self.find_rect();
        self.shadow(canvas, rect);
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.panel_bg);
        self.frame(canvas, rect, "", true, self.theme.panel_bg);
        let y = rect.y + 1;
        canvas.text(rect.x + 2, y, "查找 ", self.theme.syntax.comment, self.theme.panel_bg);
        let input_bg = if state.focus_query {
            self.theme.selection
        } else {
            self.theme.panel_bg.blend(self.theme.fg, 10)
        };
        canvas.fill_rect(rect.x + 7, y, rect.w - 9, 1, input_bg);
        canvas.text_max(rect.x + 8, y, rect.w - 11, &state.query, self.theme.fg, input_bg);
        if state.focus_query {
            canvas.put(
                rect.x + 8 + crate::render::canvas::text_width(&state.query),
                y,
                '▏',
                self.theme.accent,
                input_bg,
            );
        }
        if state.replace {
            let y = rect.y + 2;
            canvas.text(rect.x + 2, y, "替换 ", self.theme.syntax.comment, self.theme.panel_bg);
            let bg = if state.focus_query {
                self.theme.panel_bg.blend(self.theme.fg, 10)
            } else {
                self.theme.selection
            };
            canvas.fill_rect(rect.x + 7, y, rect.w - 9, 1, bg);
            canvas.text_max(rect.x + 8, y, rect.w - 11, &state.replacement, self.theme.fg, bg);
        }
        let options_y = rect.bottom().saturating_sub(2);
        let mut option = String::new();
        option.push_str(if state.options.case_sensitive { "[Aa]" } else { " Aa " });
        option.push(' ');
        option.push_str(if state.options.whole_word { "[全词]" } else { " 全词 " });
        option.push(' ');
        option.push_str(if state.options.regex { "[.*]" } else { " .* " });
        if state.replace && state.options.regex {
            option.push_str("  $1 替换");
        }
        canvas.text_max(
            rect.x + 2,
            options_y,
            rect.w.saturating_sub(4),
            &option,
            self.theme.syntax.property,
            self.theme.panel_bg,
        );
        let info = if let Some(error) = &state.error {
            error.clone()
        } else if state.query.is_empty() {
            String::new()
        } else {
            format!("{} 处", state.matches)
        };
        let color = if state.error.is_some() {
            self.theme.removed
        } else {
            self.theme.syntax.comment
        };
        canvas.text_right(rect.right() - 2, options_y, &info, color, self.theme.panel_bg);
    }

    fn draw_prompt(&self, canvas: &mut Canvas, state: &crate::ui::app::PromptState) {
        let rect = self.prompt_rect();
        self.shadow(canvas, rect);
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.panel_bg);
        self.frame(canvas, rect, "", true, self.theme.panel_bg);
        canvas.text_max(
            rect.x + 2,
            rect.y + 1,
            rect.w.saturating_sub(4),
            &state.title,
            self.theme.fg,
            self.theme.panel_bg,
        );
        let input_bg = self.theme.selection;
        canvas.fill_rect(rect.x + 2, rect.y + 2, rect.w.saturating_sub(4), 1, input_bg);
        canvas.put(rect.x + 2, rect.y + 2, '›', self.theme.accent, input_bg);
        canvas.text_max(
            rect.x + 4,
            rect.y + 2,
            rect.w.saturating_sub(6),
            &state.input,
            self.theme.fg,
            input_bg,
        );
        canvas.put(
            rect.x + 4 + crate::render::canvas::text_width(&state.input),
            rect.y + 2,
            '▏',
            self.theme.accent,
            input_bg,
        );
        canvas.text_max(
            rect.x + 2,
            rect.y + 4,
            rect.w.saturating_sub(4),
            &state.hint,
            self.theme.syntax.comment,
            self.theme.panel_bg,
        );
    }

    fn draw_confirm(&self, canvas: &mut Canvas, state: &crate::ui::app::ConfirmState) {
        let rect = self.confirm_rect();
        self.shadow(canvas, rect);
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.panel_bg);
        self.frame(canvas, rect, "确认", true, self.theme.panel_bg);
        canvas.text_max(
            rect.x + 2,
            rect.y + 1,
            rect.w.saturating_sub(4),
            &state.title,
            self.theme.fg,
            self.theme.panel_bg,
        );
        canvas.text_max(
            rect.x + 2,
            rect.y + 3,
            rect.w.saturating_sub(4),
            &state.message,
            self.theme.syntax.comment,
            self.theme.panel_bg,
        );
        let buttons = ["保存", "不保存", "取消"];
        let mut x = rect.x + 2;
        for (index, button) in buttons.iter().enumerate() {
            let label = format!(" {button} ");
            let selected = index == state.selected;
            let bg = if selected {
                self.theme.accent
            } else {
                self.theme.border.blend(self.theme.panel_bg, 60)
            };
            let fg = if selected { self.theme.status_fg } else { self.theme.fg };
            canvas.text(x, rect.bottom().saturating_sub(2), &label, fg, bg);
            x += label.chars().count() + 2;
        }
    }

    fn draw_help(&self, canvas: &mut Canvas) {
        let rect = self.layout.editor;
        self.shadow(canvas, rect);
        canvas.fill_rect(rect.x, rect.y, rect.w, rect.h, self.theme.panel_bg);
        self.frame(canvas, rect, "快捷键", true, self.theme.panel_bg);
        let lines = [
            "文件    Ctrl+N 新建   Ctrl+O 打开   Ctrl+S 保存   Ctrl+Shift+S 另存为",
            "        Ctrl+W 关闭标签   Ctrl+Q 退出   Ctrl+P 快速打开",
            "编辑    Ctrl+Z/Y 撤销/重做   Ctrl+C/X/V 复制/剪切/粘贴   Ctrl+A 全选",
            "        Ctrl+Shift+K 删除行   Alt+↑/↓ 移动行   Ctrl+/ 注释（复制行见命令面板）",
            "选择    Ctrl+D 选中下一个相同内容   Ctrl+L 选中当前行",
            "        Ctrl+Alt+↑/↓ 添加光标（多光标编辑）",
            "查找    Ctrl+F 查找   Ctrl+H 替换   F3/Shift+F3 下一个/上一个",
            "        Ctrl+Shift+F 工程搜索   Ctrl+Shift+H 工程替换",
            "        面板：Alt+C 大小写  Alt+W 全词  Alt+G .gitignore  ↑↓ 历史",
            "替换    $1..$9 捕获组   $& 整体匹配   $$ 字面量$   \\n 换行",
            "视图    Ctrl+B 资源管理器   Ctrl+Shift+P 命令面板   Alt+Z 自动换行",
            "        面板：F1 键位速查（按列出的键即执行）   F4 菜单   Shift+F1 本页",
            "        命令面板可切换自动保存 / 粘性滚动；括号匹配高亮始终启用",
            "        Ctrl+Shift+[ 折叠   Ctrl+Alt+[ 全部折叠   Ctrl+Alt+] 全部展开",
            "文件树  双击打开 / 展开   F2 重命名   Delete 删除",
            "Git     ↑↓ 选择  Space 暂存  Enter 差异  c 提交  b 分支  l 历史  D 丢弃",
            "Word    Alt+B/I/U 加粗/斜体/下划线   F6 页面/文本   Ctrl+滚轮 缩放",
            "Excel   方向键移动  Shift+方向键扩选  F2 编辑  Enter 下移  Ctrl+PgUp/PgDn 切表",
            "        Ctrl+Shift+M 合并  Ctrl+Shift+L 冻结  Ctrl+Shift+F 筛选",
            "        Ctrl+C/X/V 以 TSV 复制粘贴，可与 Excel/WPS 互通",
            "图片    PNG/JPEG/GIF/BMP；TUI 半块预览，GUI 直接显示位图",
            "LSP     Ctrl+Space 补全（无服务器时文档单词补全）  Ctrl+Shift+I 悬停  F12 定义",
            "        输入停顿自动补全 / 输入 ( , 显示签名  Ctrl+Shift+Space 签名  Ctrl+. 快速修复",
            "        内联提示（类型/参数名）随语言服务器显示，可在命令面板关闭",
            "        Ctrl+T 工作区符号   Shift+F12 引用   Ctrl+Shift+H 工程替换",
            "",
            "按 Esc 或 Shift+F1 关闭本页",
        ];
        for (index, line) in lines.iter().enumerate() {
            let y = rect.y + 1 + index;
            if y >= rect.bottom() - 1 {
                break;
            }
            canvas.text_max(rect.x + 2, y, rect.w - 4, line, self.theme.fg, self.theme.panel_bg);
        }
    }
}

/// 顶部固定的外层代码行：按缩进向上查找作用域首行。
fn sticky_line(tab: &Tab) -> Option<String> {
    if tab.top_row == 0 {
        return None;
    }
    let top = tab.rows.get(tab.top_row)?;
    let indent = leading_width(tab.doc.line(top.line));
    if indent == 0 {
        return None;
    }
    let mut line_no = top.line;
    for _ in 0..500 {
        if line_no == 0 {
            return None;
        }
        line_no -= 1;
        let text = tab.doc.line(line_no);
        if text.trim().is_empty() {
            continue;
        }
        if leading_width(text) < indent {
            return Some(text.trim_end().to_string());
        }
    }
    None
}

/// 行首空白宽度（制表符按 4 列计）。
fn leading_width(text: &str) -> usize {
    text.chars()
        .take_while(|ch| *ch == ' ' || *ch == '\t')
        .map(|ch| if ch == '\t' { 4 } else { 1 })
        .sum()
}

fn selection_ranges(doc: &Document, line: usize) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    for cursor in &doc.cursors {
        if let Some((start, end)) = cursor.selection() {
            if line < start.line || line > end.line {
                continue;
            }
            let from = if line == start.line { start.col } else { 0 };
            let to = if line == end.line {
                end.col
            } else {
                doc.line_chars(line) + 1
            };
            ranges.push((from, to));
        }
    }
    ranges
}

fn selection_bg(
    ranges: &[(usize, usize)],
    col: usize,
    search: &[(usize, usize)],
    base: Color,
    selection: Color,
    find: Color,
) -> Color {
    if search.iter().any(|(s, e)| *s <= col && col < *e) {
        return find;
    }
    if ranges.iter().any(|(s, e)| *s <= col && col < *e) {
        return base.blend(selection, 200);
    }
    base
}

fn sample(image: &crate::image::Image, x: usize, cols: usize, y: usize, rows: usize) -> Color {
    if cols == 0 || rows == 0 {
        return Color::rgb(0, 0, 0);
    }
    let px = ((x as u64 * image.width as u64) / cols as u64) as usize;
    let py = ((y as u64 * image.height as u64) / rows as u64) as usize;
    let index = (py.min(image.height - 1) * image.width + px.min(image.width - 1)) * 4;
    match image.pixels.get(index..index + 4) {
        Some(p) => Color::rgb(p[0], p[1], p[2]),
        None => Color::rgb(0, 0, 0),
    }
}

/// Excel 列宽（字符单位）换算成终端列数。
fn excel_col_chars(sheet: &crate::xlsx::Sheet, col: usize) -> usize {
    let width = sheet.col_width(col);
    ((width * 1.05).round() as usize).clamp(3, 48)
}

fn excel_row_hidden(sheet: &crate::xlsx::Sheet, row: usize) -> bool {
    sheet.hidden_rows.contains(&row) || sheet.filtered_rows.contains(&row)
}

/// 白色填充在终端里映射为编辑器背景，其余颜色原样显示。
fn excel_fill(color: Color, theme: &Theme) -> Color {
    if color.r > 247 && color.g > 247 && color.b > 247 {
        theme.bg
    } else {
        color
    }
}

fn excel_text(color: Color, fill: Color, theme: &Theme) -> Color {
    if color.r < 8 && color.g < 8 && color.b < 8 && fill.r > 247 && fill.g > 247 && fill.b > 247 {
        theme.fg
    } else {
        color
    }
}

/// 彩虹括号：按嵌套深度在 6 种语法色之间循环。
fn rainbow_color(theme: Theme, depth: i32) -> Color {
    let s = &theme.syntax;
    let palette = [
        s.keyword,
        s.type_,
        s.string,
        s.number,
        s.function,
        s.constant,
    ];
    palette[depth.rem_euclid(palette.len() as i32) as usize]
}


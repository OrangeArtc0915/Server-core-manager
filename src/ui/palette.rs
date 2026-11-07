//! 命令面板：模糊搜索所有已注册动作。

use crate::action::{Action, Registry};

pub struct PaletteState {
    pub query: String,
    pub selected: usize,
}

impl Default for PaletteState {
    fn default() -> Self {
        PaletteState::new()
    }
}

impl PaletteState {
    pub fn new() -> PaletteState {
        PaletteState {
            query: String::new(),
            selected: 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PaletteItem {
    pub action: Action,
    pub keys: Option<String>,
    pub score: i32,
    /// 指定时表示「用该 profile 新建标签页」，而不是执行 `action` 本身。
    pub profile: Option<String>,
}

/// 按查询过滤动作；空查询返回全部（动作在前，profile 快捷项在后）。
pub fn filter(registry: &Registry, query: &str, profiles: &[String]) -> Vec<PaletteItem> {
    let mut items: Vec<PaletteItem> = Action::all()
        .into_iter()
        .filter_map(|action| {
            let text = format!("{} {}", action.name(), action.id());
            let score = if query.is_empty() {
                0
            } else {
                fuzzy_score(query, &text)?
            };
            Some(PaletteItem {
                action,
                keys: registry.keys_for(action),
                score,
                profile: None,
            })
        })
        .collect();
    // 每个 profile 一条「新建标签页」快捷项，命令面板里可直接搜到。
    for name in profiles {
        let text = format!("新建标签页 profile {name}");
        let score = if query.is_empty() {
            0
        } else {
            match fuzzy_score(query, &text) {
                Some(score) => score - 5,
                None => continue,
            }
        };
        items.push(PaletteItem {
            action: Action::NewTab,
            keys: None,
            score,
            profile: Some(name.clone()),
        });
    }
    if !query.is_empty() {
        items.sort_by(|a, b| b.score.cmp(&a.score));
    }
    items
}

/// 子序列匹配：连续命中加分，单词首字母命中额外加分。
pub fn fuzzy_score(query: &str, text: &str) -> Option<i32> {
    let query: Vec<char> = query.to_lowercase().chars().collect();
    if query.is_empty() {
        return Some(0);
    }
    let hay: Vec<char> = text.to_lowercase().chars().collect();
    let mut score = 0;
    let mut qi = 0;
    let mut last_match: Option<usize> = None;

    for (i, ch) in hay.iter().enumerate() {
        if qi >= query.len() {
            break;
        }
        if *ch == query[qi] {
            score += 10;
            if let Some(last) = last_match {
                if last + 1 == i {
                    score += 15;
                }
            }
            if i == 0 || hay[i - 1] == ' ' {
                score += 20;
            }
            last_match = Some(i);
            qi += 1;
        }
    }

    if qi == query.len() {
        // 命中位置越靠前越好
        Some(score - hay.len() as i32 / 4)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::action::Registry;

    fn profiles() -> Vec<String> {
        vec!["scterm".to_string(), "pwsh".to_string()]
    }

    #[test]
    fn empty_query_lists_everything() {
        let items = filter(&Registry::defaults(), "", &profiles());
        assert_eq!(items.len(), Action::all().len() + 2);
        assert!(items
            .iter()
            .any(|i| i.profile.as_deref() == Some("pwsh")));
    }

    #[test]
    fn fuzzy_matches_subsequence() {
        assert!(fuzzy_score("sp", "左右分屏 splitPaneHorizontal").is_some());
        assert!(fuzzy_score("xyz", "左右分屏").is_none());
    }

    #[test]
    fn query_filters_and_ranks() {
        let items = filter(&Registry::defaults(), "分屏", &profiles());
        assert!(!items.is_empty());
        assert!(items.iter().all(|i| i.action.name().contains("分屏")));
        let first = &items[0];
        assert!(matches!(
            first.action,
            Action::SplitPane(_)
        ));
    }

    #[test]
    fn profile_shortcut_is_searchable() {
        let items = filter(&Registry::defaults(), "pwsh", &profiles());
        let hit = items
            .iter()
            .find(|i| i.profile.as_deref() == Some("pwsh"))
            .expect("profile 快捷项应能搜到");
        assert_eq!(hit.action, Action::NewTab);
    }

    #[test]
    fn binding_hint_is_shown() {
        let items = filter(&Registry::defaults(), "命令面板", &profiles());
        let item = items
            .iter()
            .find(|i| i.action == Action::CommandPalette)
            .expect("命令面板动作应在结果中");
        assert_eq!(item.keys.as_deref(), Some("Ctrl+Shift+p"));
    }
}

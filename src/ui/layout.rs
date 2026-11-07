//! 窗格树与布局计算。

use std::collections::HashMap;

use crate::action::Direction;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: usize,
    pub y: usize,
    pub w: usize,
    pub h: usize,
}

impl Rect {
    pub fn new(x: usize, y: usize, w: usize, h: usize) -> Rect {
        Rect { x, y, w, h }
    }

    pub fn right(&self) -> usize {
        self.x + self.w
    }

    pub fn bottom(&self) -> usize {
        self.y + self.h
    }

    pub fn center(&self) -> (usize, usize) {
        (self.x + self.w / 2, self.y + self.h / 2)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    /// 左右分（分隔线竖着）
    Horizontal,
    /// 上下分（分隔线横着）
    Vertical,
}

pub const MIN_W: usize = 2;
pub const MIN_H: usize = 1;

#[derive(Debug, Clone)]
pub enum Node {
    Leaf(u32),
    Split {
        axis: Axis,
        ratio: u16,
        first: Box<Node>,
        second: Box<Node>,
    },
}

impl Node {
    pub fn leaf(id: u32) -> Node {
        Node::Leaf(id)
    }

    /// 把 `target` 叶子替换成一次分割；返回是否成功。
    pub fn split_at(&mut self, target: u32, axis: Axis, new_id: u32, ratio: u16) -> bool {
        match self {
            Node::Leaf(id) if *id == target => {
                let old = Node::Leaf(*id);
                *self = Node::Split {
                    axis,
                    ratio,
                    first: Box::new(old),
                    second: Box::new(Node::Leaf(new_id)),
                };
                true
            }
            Node::Leaf(_) => false,
            Node::Split { first, second, .. } => {
                first.split_at(target, axis, new_id, ratio)
                    || second.split_at(target, axis, new_id, ratio)
            }
        }
    }

    /// 移除叶子，把父节点折叠成兄弟节点。
    pub fn remove(&mut self, target: u32) -> bool {
        match self {
            Node::Leaf(_) => false,
            Node::Split { first, second, .. } => {
                if matches!(**first, Node::Leaf(id) if id == target) {
                    let sibling = (**second).clone();
                    *self = sibling;
                    return true;
                }
                if matches!(**second, Node::Leaf(id) if id == target) {
                    let sibling = (**first).clone();
                    *self = sibling;
                    return true;
                }
                first.remove(target) || second.remove(target)
            }
        }
    }

    pub fn leaves(&self) -> Vec<u32> {
        let mut out = Vec::new();
        self.collect(&mut out);
        out
    }

    fn collect(&self, out: &mut Vec<u32>) {
        match self {
            Node::Leaf(id) => out.push(*id),
            Node::Split { first, second, .. } => {
                first.collect(out);
                second.collect(out);
            }
        }
    }

    pub fn first_leaf(&self) -> u32 {
        match self {
            Node::Leaf(id) => *id,
            Node::Split { first, .. } => first.first_leaf(),
        }
    }

    /// 命中分隔线：返回从根到该 Split 的路径（false=first，true=second）、
    /// 该 Split 的轴向与它所在的矩形（拖动时按鼠标位置换算比例）。
    pub fn find_separator(
        &self,
        rect: Rect,
        x: usize,
        y: usize,
    ) -> Option<(Vec<bool>, Axis, Rect)> {
        let Node::Split {
            axis,
            ratio,
            first,
            second,
        } = self
        else {
            return None;
        };
        match axis {
            Axis::Horizontal => {
                if rect.w < MIN_W * 2 + 1 {
                    return None;
                }
                let usable = rect.w - 1;
                let w1 = ((usable * (*ratio as usize)) / 100).clamp(MIN_W, usable - MIN_W);
                if x == rect.x + w1 && y >= rect.y && y < rect.bottom() {
                    return Some((Vec::new(), *axis, rect));
                }
                if let Some((mut path, hit_axis, hit_rect)) =
                    first.find_separator(Rect::new(rect.x, rect.y, w1, rect.h), x, y)
                {
                    path.insert(0, false);
                    return Some((path, hit_axis, hit_rect));
                }
                if let Some((mut path, hit_axis, hit_rect)) = second.find_separator(
                    Rect::new(rect.x + w1 + 1, rect.y, usable - w1, rect.h),
                    x,
                    y,
                ) {
                    path.insert(0, true);
                    return Some((path, hit_axis, hit_rect));
                }
                None
            }
            Axis::Vertical => {
                if rect.h < MIN_H * 2 + 1 {
                    return None;
                }
                let usable = rect.h - 1;
                let h1 = ((usable * (*ratio as usize)) / 100).clamp(MIN_H, usable - MIN_H);
                if y == rect.y + h1 && x >= rect.x && x < rect.right() {
                    return Some((Vec::new(), *axis, rect));
                }
                if let Some((mut path, hit_axis, hit_rect)) =
                    first.find_separator(Rect::new(rect.x, rect.y, rect.w, h1), x, y)
                {
                    path.insert(0, false);
                    return Some((path, hit_axis, hit_rect));
                }
                if let Some((mut path, hit_axis, hit_rect)) = second.find_separator(
                    Rect::new(rect.x, rect.y + h1 + 1, rect.w, usable - h1),
                    x,
                    y,
                ) {
                    path.insert(0, true);
                    return Some((path, hit_axis, hit_rect));
                }
                None
            }
        }
    }

    /// 按路径设置某个 Split 的比例（5%–95%）。
    pub fn set_ratio(&mut self, path: &[bool], ratio: u16) -> bool {
        let Node::Split {
            ratio: current,
            first,
            second,
            ..
        } = self
        else {
            return false;
        };
        match path.split_first() {
            None => {
                *current = ratio.clamp(5, 95);
                true
            }
            Some((false, rest)) => first.set_ratio(rest, ratio),
            Some((true, rest)) => second.set_ratio(rest, ratio),
        }
    }

    /// 交换两个叶子的位置；两个 id 都在树里才算成功。
    pub fn swap_leaves(&mut self, a: u32, b: u32) -> bool {
        if a == b || !self.contains(a) || !self.contains(b) {
            return false;
        }
        self.swap_ids(a, b);
        true
    }

    /// 一次性互换两个叶子 id（不能分两步替换，否则第二步会命中刚改过的那个）。
    fn swap_ids(&mut self, a: u32, b: u32) {
        match self {
            Node::Leaf(id) => {
                if *id == a {
                    *id = b;
                } else if *id == b {
                    *id = a;
                }
            }
            Node::Split { first, second, .. } => {
                first.swap_ids(a, b);
                second.swap_ids(a, b);
            }
        }
    }

    pub fn contains(&self, target: u32) -> bool {
        match self {
            Node::Leaf(id) => *id == target,
            Node::Split { first, second, .. } => {
                first.contains(target) || second.contains(target)
            }
        }
    }

    /// 调整包含 `target` 的最深层、且轴向匹配的 Split 比例。
    /// `delta` 为百分比增量（正数把分隔线向右/下移）。
    pub fn resize(&mut self, target: u32, axis: Axis, delta: i16) -> bool {
        let Node::Split {
            axis: current_axis,
            ratio,
            first,
            second,
        } = self
        else {
            return false;
        };
        // 优先找更靠近叶子的分割线，让方向键调整最贴近窗格的那一道。
        let in_first = first.contains(target);
        let in_second = second.contains(target);
        if in_first && first.resize(target, axis, delta) {
            return true;
        }
        if in_second && second.resize(target, axis, delta) {
            return true;
        }
        if (in_first || in_second) && *current_axis == axis {
            let next = (*ratio as i16 + delta).clamp(5, 95) as u16;
            if next != *ratio {
                *ratio = next;
                return true;
            }
        }
        false
    }

    fn layout(&self, rect: Rect, panes: &mut Vec<(u32, Rect)>, seps: &mut Vec<Rect>) {
        match self {
            Node::Leaf(id) => panes.push((*id, rect)),
            Node::Split {
                axis,
                ratio,
                first,
                second,
            } => match axis {
                Axis::Horizontal => {
                    if rect.w < MIN_W * 2 + 1 {
                        self.layout_degenerate(rect, panes);
                        return;
                    }
                    let usable = rect.w - 1;
                    let want = (usable * (*ratio as usize)) / 100;
                    let w1 = want.clamp(MIN_W, usable - MIN_W);
                    first.layout(Rect::new(rect.x, rect.y, w1, rect.h), panes, seps);
                    seps.push(Rect::new(rect.x + w1, rect.y, 1, rect.h));
                    second.layout(
                        Rect::new(rect.x + w1 + 1, rect.y, usable - w1, rect.h),
                        panes,
                        seps,
                    );
                }
                Axis::Vertical => {
                    if rect.h < MIN_H * 2 + 1 {
                        self.layout_degenerate(rect, panes);
                        return;
                    }
                    let usable = rect.h - 1;
                    let want = (usable * (*ratio as usize)) / 100;
                    let h1 = want.clamp(MIN_H, usable - MIN_H);
                    first.layout(Rect::new(rect.x, rect.y, rect.w, h1), panes, seps);
                    seps.push(Rect::new(rect.x, rect.y + h1, rect.w, 1));
                    second.layout(
                        Rect::new(rect.x, rect.y + h1 + 1, rect.w, usable - h1),
                        panes,
                        seps,
                    );
                }
            },
        }
    }

    /// 空间不足时退化为「只显示第一个窗格」，避免除零和负尺寸。
    fn layout_degenerate(&self, rect: Rect, panes: &mut Vec<(u32, Rect)>) {
        panes.push((self.first_leaf(), rect));
    }
}

/// 布局模板：叶是 profile 名，Split 带比例。
///
/// 文本写法：`h(pwsh,cmd)`、`v30(pwsh,h(cmd,pwsh))`；`h` = 左右分，`v` = 上下分，
/// 数字是第一个子节点的百分比（省略为 50）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutNode {
    Pane(String),
    Split {
        axis: Axis,
        ratio: u16,
        first: Box<LayoutNode>,
        second: Box<LayoutNode>,
    },
}

impl LayoutNode {
    pub fn parse(text: &str) -> Result<LayoutNode, String> {
        let mut parser = LayoutParser {
            chars: text.chars().collect(),
            pos: 0,
        };
        parser.skip_ws();
        let node = parser.node()?;
        parser.skip_ws();
        if parser.pos < parser.chars.len() {
            return Err(format!(
                "布局表达式末尾有多余字符「{}」",
                parser.chars[parser.pos]
            ));
        }
        Ok(node)
    }

    /// 表达式里出现的全部 profile 名（按出现顺序，含重复）。
    pub fn profiles(&self) -> Vec<&str> {
        let mut out = Vec::new();
        self.collect_profiles(&mut out);
        out
    }

    fn collect_profiles<'a>(&'a self, out: &mut Vec<&'a str>) {
        match self {
            LayoutNode::Pane(name) => out.push(name),
            LayoutNode::Split { first, second, .. } => {
                first.collect_profiles(out);
                second.collect_profiles(out);
            }
        }
    }
}

struct LayoutParser {
    chars: Vec<char>,
    pos: usize,
}

impl LayoutParser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn next(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.pos += 1;
        Some(ch)
    }

    fn skip_ws(&mut self) {
        while self.peek().map(char::is_whitespace).unwrap_or(false) {
            self.pos += 1;
        }
    }

    fn node(&mut self) -> Result<LayoutNode, String> {
        self.skip_ws();
        let Some(ch) = self.peek() else {
            return Err("布局表达式为空".to_string());
        };
        if ch == '"' {
            return self.quoted_pane();
        }
        // `h`/`v` 只有后面跟（可选数字和空白后）左括号时才当分割，
        // 否则可能是恰好以 h/v 开头的 profile 名。
        if ch == 'h' || ch == 'H' || ch == 'v' || ch == 'V' {
            let mut probe = self.pos + 1;
            while probe < self.chars.len() && self.chars[probe].is_ascii_digit() {
                probe += 1;
            }
            while probe < self.chars.len() && self.chars[probe].is_whitespace() {
                probe += 1;
            }
            if probe < self.chars.len() && self.chars[probe] == '(' {
                return self.split(ch);
            }
        }
        self.bare_pane(ch)
    }

    fn split(&mut self, axis_char: char) -> Result<LayoutNode, String> {
        self.pos += 1;
        let mut digits = String::new();
        while let Some(ch) = self.peek() {
            if ch.is_ascii_digit() {
                digits.push(ch);
                self.pos += 1;
            } else {
                break;
            }
        }
        let ratio = if digits.is_empty() {
            50
        } else {
            digits
                .parse::<u16>()
                .map_err(|_| format!("布局比例「{digits}」不是合法数字"))?
        };
        if !(5..=95).contains(&ratio) {
            return Err(format!("布局比例 {ratio} 超出 5–95"));
        }
        self.skip_ws();
        if self.peek() != Some('(') {
            return Err("布局缺少 `(`".to_string());
        }
        self.pos += 1;
        let first = self.node()?;
        self.skip_ws();
        if self.peek() != Some(',') {
            return Err("布局缺少 `,`".to_string());
        }
        self.pos += 1;
        let second = self.node()?;
        self.skip_ws();
        if self.peek() != Some(')') {
            return Err("布局缺少 `)`".to_string());
        }
        self.pos += 1;
        let axis = if axis_char == 'h' || axis_char == 'H' {
            Axis::Horizontal
        } else {
            Axis::Vertical
        };
        Ok(LayoutNode::Split {
            axis,
            ratio,
            first: Box::new(first),
            second: Box::new(second),
        })
    }

    fn quoted_pane(&mut self) -> Result<LayoutNode, String> {
        self.pos += 1;
        let mut name = String::new();
        loop {
            let Some(ch) = self.next() else {
                return Err("布局中的字符串缺少收尾双引号".to_string());
            };
            match ch {
                '"' => break,
                '\\' => {
                    let Some(escaped) = self.next() else {
                        return Err("布局中的字符串以反斜杠结尾".to_string());
                    };
                    name.push(match escaped {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        other => other,
                    });
                }
                other => name.push(other),
            }
        }
        if name.is_empty() {
            return Err("布局中的 profile 名不能为空".to_string());
        }
        Ok(LayoutNode::Pane(name))
    }

    fn bare_pane(&mut self, first: char) -> Result<LayoutNode, String> {
        let mut name = String::new();
        if !is_bare_char(first) {
            return Err(format!("无法识别的布局字符「{first}」"));
        }
        while let Some(ch) = self.peek() {
            if !is_bare_char(ch) {
                break;
            }
            name.push(ch);
            self.pos += 1;
        }
        Ok(LayoutNode::Pane(name))
    }
}

fn is_bare_char(ch: char) -> bool {
    !ch.is_whitespace() && !matches!(ch, ',' | '(' | ')' | '"')
}

/// 把窗格树写成布局表达式，`profiles` 提供叶子 id 对应的 profile 名。
pub fn node_to_spec(root: &Node, profiles: &HashMap<u32, String>) -> String {
    match root {
        Node::Leaf(id) => spec_name(
            profiles
                .get(id)
                .map(String::as_str)
                .unwrap_or("scterm"),
        ),
        Node::Split {
            axis,
            ratio,
            first,
            second,
        } => {
            let tag = if *axis == Axis::Horizontal { 'h' } else { 'v' };
            let ratio_text = if *ratio == 50 {
                String::new()
            } else {
                ratio.to_string()
            };
            format!(
                "{tag}{ratio_text}({},{})",
                node_to_spec(first, profiles),
                node_to_spec(second, profiles)
            )
        }
    }
}

fn spec_name(name: &str) -> String {
    let needs_quote = name.is_empty()
        || name
            .chars()
            .any(|ch| ch.is_whitespace() || matches!(ch, ',' | '(' | ')' | '"' | '\\'));
    if !needs_quote {
        return name.to_string();
    }
    let mut out = String::with_capacity(name.len() + 2);
    out.push('"');
    for ch in name.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

/// 计算窗格矩形与分隔线矩形。
pub fn compute(root: &Node, rect: Rect) -> (Vec<(u32, Rect)>, Vec<Rect>) {
    let mut panes = Vec::new();
    let mut seps = Vec::new();
    root.layout(rect, &mut panes, &mut seps);
    (panes, seps)
}

/// 按方向找相邻窗格（按中心点距离最近）。
pub fn neighbor(panes: &[(u32, Rect)], from: u32, dir: Direction) -> Option<u32> {
    let current = panes.iter().find(|(id, _)| *id == from)?.1;
    let (cx, cy) = current.center();
    let mut best: Option<(i64, u32)> = None;

    for (id, rect) in panes {
        if *id == from {
            continue;
        }
        let (px, py) = rect.center();
        let (dx, dy) = (px as i64 - cx as i64, py as i64 - cy as i64);
        let (along, across) = match dir {
            Direction::Left => (-dx, dy.abs()),
            Direction::Right => (dx, dy.abs()),
            Direction::Up => (-dy, dx.abs()),
            Direction::Down => (dy, dx.abs()),
        };
        if along <= 0 {
            continue;
        }
        let score = along * 4 + across;
        if best.map(|(s, _)| score < s).unwrap_or(true) {
            best = Some((score, *id));
        }
    }
    best.map(|(_, id)| id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_leaf_fills_rect() {
        let root = Node::leaf(1);
        let (panes, seps) = compute(&root, Rect::new(0, 1, 80, 24));
        assert_eq!(panes.len(), 1);
        assert_eq!(panes[0].1, Rect::new(0, 1, 80, 24));
        assert!(seps.is_empty());
    }

    #[test]
    fn horizontal_split_has_separator() {
        let mut root = Node::leaf(1);
        assert!(root.split_at(1, Axis::Horizontal, 2, 50));
        let (panes, seps) = compute(&root, Rect::new(0, 1, 81, 24));
        assert_eq!(panes.len(), 2);
        assert_eq!(panes[0].1, Rect::new(0, 1, 40, 24));
        assert_eq!(seps.len(), 1);
        assert_eq!(seps[0], Rect::new(40, 1, 1, 24));
        assert_eq!(panes[1].1, Rect::new(41, 1, 40, 24));
    }

    #[test]
    fn vertical_split_and_nesting() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 50);
        root.split_at(2, Axis::Vertical, 3, 50);
        let (panes, seps) = compute(&root, Rect::new(0, 0, 80, 25));
        assert_eq!(panes.len(), 3);
        assert_eq!(seps.len(), 2);
    }

    #[test]
    fn remove_collapses_parent() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 50);
        assert!(root.remove(2));
        assert_eq!(root.leaves(), vec![1]);
        // 移除后应恢复成单窗格占满
        let (panes, seps) = compute(&root, Rect::new(0, 0, 10, 5));
        assert_eq!(panes[0].1, Rect::new(0, 0, 10, 5));
        assert!(seps.is_empty());
    }

    #[test]
    fn neighbor_by_direction() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 50);
        let (panes, _) = compute(&root, Rect::new(0, 0, 80, 24));
        assert_eq!(neighbor(&panes, 1, Direction::Right), Some(2));
        assert_eq!(neighbor(&panes, 2, Direction::Left), Some(1));
        assert_eq!(neighbor(&panes, 1, Direction::Left), None);
    }

    #[test]
    fn too_narrow_falls_back_to_first_pane() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 50);
        let (panes, _) = compute(&root, Rect::new(0, 0, 3, 10));
        assert_eq!(panes.len(), 1);
        assert_eq!(panes[0].0, 1);
    }

    #[test]
    fn separator_hit_test_and_ratio_update() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 50);
        let rect = Rect::new(0, 1, 81, 24);
        let (path, axis, hit) = root.find_separator(rect, 40, 5).expect("应命中分隔线");
        assert!(path.is_empty());
        assert_eq!(axis, Axis::Horizontal);
        assert_eq!(hit, rect);

        assert!(root.set_ratio(&path, 25));
        let (panes, seps) = compute(&root, rect);
        assert_eq!(panes[0].1.w, 20);
        assert_eq!(seps[0].x, 20);
    }

    #[test]
    fn nested_separator_path() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 50);
        root.split_at(2, Axis::Vertical, 3, 50);
        let rect = Rect::new(0, 1, 81, 24);
        // 右侧窗格内再上下分：水平分隔线在 x=40，垂直分隔线在右半边。
        let hit = root.find_separator(rect, 60, 12);
        assert_eq!(hit.map(|(p, a, _)| (p, a)), Some((vec![true], Axis::Vertical)));
    }

    #[test]
    fn swap_leaves_keeps_tree_shape() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 50);
        assert!(root.swap_leaves(1, 2));
        assert_eq!(root.leaves(), vec![2, 1]);
        assert!(!root.swap_leaves(1, 9), "不存在的 id 不应改动树");
        assert_eq!(root.leaves(), vec![2, 1]);
    }

    #[test]
    fn resize_adjusts_nearest_matching_split() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 50);
        assert!(root.resize(2, Axis::Horizontal, 5));
        let (panes, _) = compute(&root, Rect::new(0, 1, 81, 24));
        assert_eq!(panes[0].1.w, 44, "左窗格应从 40 列扩到 44 列");
        assert_eq!(panes[1].1.x, 45);
        // 轴向不匹配时不改比例
        assert!(!root.resize(2, Axis::Vertical, 5));
    }

    #[test]
    fn resize_prefers_deeper_split() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 50);
        root.split_at(2, Axis::Vertical, 3, 50);
        // 焦点在 3：左右方向应调整外层（占 50%），上下方向调整内层。
        assert!(root.resize(3, Axis::Vertical, 5));
        let (panes, _) = compute(&root, Rect::new(0, 0, 80, 25));
        let height = |id: u32| {
            panes
                .iter()
                .find(|(pane, _)| *pane == id)
                .map(|(_, rect)| rect.h)
                .unwrap()
        };
        assert_eq!(height(1), 25, "外层左右分割不应被上下调整影响");
        assert_eq!(height(2), 13);
        assert_eq!(height(3), 11);
    }

    #[test]
    fn layout_spec_parses_single_and_nested() {
        let node = LayoutNode::parse("pwsh").unwrap();
        assert_eq!(node, LayoutNode::Pane("pwsh".into()));
        assert_eq!(node.profiles(), vec!["pwsh"]);

        let node = LayoutNode::parse(" h ( pwsh , v ( cmd , pwsh ) ) ").unwrap();
        match &node {
            LayoutNode::Split {
                axis: Axis::Horizontal,
                ratio: 50,
                first,
                second,
            } => {
                assert_eq!(**first, LayoutNode::Pane("pwsh".into()));
                match &**second {
                    LayoutNode::Split {
                        axis: Axis::Vertical,
                        ratio: 50,
                        ..
                    } => {}
                    other => panic!("内层应为上下分割：{other:?}"),
                }
            }
            other => panic!("外层应为左右分割：{other:?}"),
        }
        assert_eq!(node.profiles(), vec!["pwsh", "cmd", "pwsh"]);
    }

    #[test]
    fn layout_spec_ratio_and_quoted_names() {
        let node = LayoutNode::parse("v30(\"my profile\",h(命令行,pwsh))").unwrap();
        match &node {
            LayoutNode::Split { axis, ratio, first, .. } => {
                assert_eq!(*axis, Axis::Vertical);
                assert_eq!(*ratio, 30);
                assert_eq!(**first, LayoutNode::Pane("my profile".into()));
            }
            other => panic!("应为上下分割：{other:?}"),
        }
        assert_eq!(node.profiles(), vec!["my profile", "命令行", "pwsh"]);

        // 以 h/v 开头但后面不是括号的 profile 名应保持为叶。
        assert_eq!(
            LayoutNode::parse("vscode").unwrap(),
            LayoutNode::Pane("vscode".into())
        );
    }

    #[test]
    fn layout_spec_rejects_bad_input() {
        for text in ["", "h(pwsh,cmd", "h(pwsh cmd)", "h100(pwsh,cmd)", "x(pwsh,cmd)", "\"\""] {
            assert!(LayoutNode::parse(text).is_err(), "应拒绝：{text:?}");
        }
        assert!(LayoutNode::parse("h(pwsh,cmd) extra").is_err());
    }

    #[test]
    fn node_to_spec_roundtrips_tree() {
        let mut root = Node::leaf(1);
        root.split_at(1, Axis::Horizontal, 2, 30);
        root.split_at(2, Axis::Vertical, 3, 70);
        let mut profiles = HashMap::new();
        profiles.insert(1, "pwsh".to_string());
        profiles.insert(2, "my cmd".to_string());
        profiles.insert(3, "cmd.exe".to_string());
        let spec = node_to_spec(&root, &profiles);
        assert_eq!(spec, "h30(pwsh,v70(\"my cmd\",cmd.exe))");

        let parsed = LayoutNode::parse(&spec).unwrap();
        assert_eq!(parsed.profiles(), vec!["pwsh", "my cmd", "cmd.exe"]);
        match parsed {
            LayoutNode::Split {
                axis: Axis::Horizontal,
                ratio: 30,
                first,
                second,
            } => {
                assert_eq!(*first, LayoutNode::Pane("pwsh".into()));
                match *second {
                    LayoutNode::Split {
                        axis: Axis::Vertical,
                        ratio: 70,
                        ..
                    } => {}
                    other => panic!("内层应为上下分割：{other:?}"),
                }
            }
            other => panic!("外层应为左右分割：{other:?}"),
        }
    }

    #[test]
    fn node_to_spec_escapes_special_names() {
        let root = Node::leaf(7);
        let mut profiles = HashMap::new();
        profiles.insert(7, "a\"b\\c".to_string());
        let spec = node_to_spec(&root, &profiles);
        assert_eq!(spec, "\"a\\\"b\\\\c\"");
        match LayoutNode::parse(&spec).unwrap() {
            LayoutNode::Pane(name) => assert_eq!(name, "a\"b\\c"),
            other => panic!("应为单叶：{other:?}"),
        }
    }
}

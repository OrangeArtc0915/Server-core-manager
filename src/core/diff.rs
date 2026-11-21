//! 行级差异：Git 边条标记、与文件比较的统一 diff。

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LineMark {
    None,
    Added,
    Modified,
    /// 该行上方有被删除的行（Git 边条用短横线表示）。
    DeletedAbove,
}

/// 新旧文本的行差异。返回与 `new` 等长的标记数组。
pub fn line_marks(old: &[String], new: &[String]) -> Vec<LineMark> {
    let mut marks = vec![LineMark::None; new.len()];
    if old.is_empty() {
        return marks;
    }
    let (prefix, suffix) = common_edges(old, new);
    if prefix >= new.len() && suffix == 0 {
        return marks;
    }
    let old_mid = &old[prefix..old.len() - suffix];
    let new_mid = &new[prefix..new.len() - suffix];
    if old_mid.is_empty() {
        for mark in marks.iter_mut().skip(prefix).take(new_mid.len()) {
            *mark = LineMark::Added;
        }
        return marks;
    }
    if new_mid.is_empty() {
        if prefix > 0 {
            marks[prefix - 1] = LineMark::DeletedAbove;
        }
        return marks;
    }

    // 中间段较小才做 LCS；否则整体视为修改。
    if old_mid.len().saturating_mul(new_mid.len()) <= 4_000_000 {
        let pairs = lcs_pairs(old_mid, new_mid);
        let mut old_used = vec![false; old_mid.len()];
        let mut new_used = vec![false; new_mid.len()];
        for (i, j) in pairs {
            old_used[i] = true;
            new_used[j] = true;
        }
        for (j, used) in new_used.iter().enumerate() {
            if !used {
                marks[prefix + j] = LineMark::Added;
            }
        }
        // 删除行标在它上方最近的新行
        for (i, used) in old_used.iter().enumerate() {
            if !used {
                let target = prefix + i.min(new_mid.len().saturating_sub(1));
                if target < marks.len() && marks[target] == LineMark::None {
                    marks[target] = LineMark::DeletedAbove;
                }
            }
        }
    } else {
        for mark in marks.iter_mut().skip(prefix).take(new_mid.len()) {
            *mark = LineMark::Modified;
        }
    }
    marks
}

fn common_edges(old: &[String], new: &[String]) -> (usize, usize) {
    let mut prefix = 0usize;
    while prefix < old.len() && prefix < new.len() && old[prefix] == new[prefix] {
        prefix += 1;
    }
    let mut suffix = 0usize;
    while suffix < old.len() - prefix
        && suffix < new.len() - prefix
        && old[old.len() - 1 - suffix] == new[new.len() - 1 - suffix]
    {
        suffix += 1;
    }
    (prefix, suffix)
}

fn lcs_pairs(a: &[String], b: &[String]) -> Vec<(usize, usize)> {
    let n = a.len();
    let m = b.len();
    let mut table = vec![0u32; (n + 1) * (m + 1)];
    let stride = m + 1;
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            table[i * stride + j] = if a[i] == b[j] {
                table[(i + 1) * stride + j + 1] + 1
            } else {
                table[(i + 1) * stride + j].max(table[i * stride + j + 1])
            };
        }
    }
    let mut pairs = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if a[i] == b[j] {
            pairs.push((i, j));
            i += 1;
            j += 1;
        } else if table[(i + 1) * stride + j] >= table[i * stride + j + 1] {
            i += 1;
        } else {
            j += 1;
        }
    }
    pairs
}

/// 生成统一 diff 文本（用于「与文件比较」视图）。
pub fn unified_diff(
    old: &[String],
    new: &[String],
    old_name: &str,
    new_name: &str,
    context: usize,
) -> String {
    let mut out = String::new();
    out.push_str(&format!("--- {old_name}\n+++ {new_name}\n"));
    let n = old.len();
    let m = new.len();
    if n.saturating_mul(m) > 16_000_000 {
        out.push_str("@@ 文件过大，仅显示行数变化 @@\n");
        out.push_str(&format!("- {n} 行\n+ {m} 行\n"));
        return out;
    }
    // 逐行动态规划求编辑脚本（LCS 回溯）
    let stride = m + 1;
    let mut table = vec![0u32; (n + 1) * stride];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            table[i * stride + j] = if old[i] == new[j] {
                table[(i + 1) * stride + j + 1] + 1
            } else {
                table[(i + 1) * stride + j].max(table[i * stride + j + 1])
            };
        }
    }
    let mut script: Vec<(char, usize, usize)> = Vec::new(); // (' ', old, new) / ('-', old) / ('+', new)
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if old[i] == new[j] {
            script.push((' ', i, j));
            i += 1;
            j += 1;
        } else if table[(i + 1) * stride + j] >= table[i * stride + j + 1] {
            script.push(('-', i, 0));
            i += 1;
        } else {
            script.push(('+', 0, j));
            j += 1;
        }
    }
    while i < n {
        script.push(('-', i, 0));
        i += 1;
    }
    while j < m {
        script.push(('+', 0, j));
        j += 1;
    }

    // 提取带上下文的块：把间隔不超过 2*context 的改动合并成一个 hunk。
    let changes: Vec<usize> = script
        .iter()
        .enumerate()
        .filter(|(_, e)| e.0 != ' ')
        .map(|(i, _)| i)
        .collect();
    let mut cursor = 0usize;
    while cursor < changes.len() {
        let first = changes[cursor];
        let mut last = first;
        let mut probe = cursor + 1;
        while probe < changes.len() && changes[probe] <= last + 2 * context + 1 {
            last = changes[probe];
            probe += 1;
        }
        cursor = probe;
        let start = first.saturating_sub(context);
        let end = (last + context + 1).min(script.len());
        let mut old_start = 0usize;
        let mut new_start = 0usize;
        for entry in &script[..start] {
            match entry.0 {
                ' ' => {
                    old_start += 1;
                    new_start += 1;
                }
                '-' => old_start += 1,
                '+' => new_start += 1,
                _ => {}
            }
        }
        let old_count = script[start..end].iter().filter(|e| e.0 != '+').count();
        let new_count = script[start..end].iter().filter(|e| e.0 != '-').count();
        out.push_str(&format!(
            "@@ -{},{} +{},{} @@\n",
            old_start + 1,
            old_count,
            new_start + 1,
            new_count
        ));
        for entry in &script[start..end] {
            match entry.0 {
                ' ' => out.push_str(&format!(" {}\n", old[entry.1])),
                '-' => out.push_str(&format!("-{}\n", old[entry.1])),
                '+' => out.push_str(&format!("+{}\n", new[entry.2])),
                _ => {}
            }
        }
    }
    if out.lines().count() <= 2 {
        out.push_str("(没有差异)\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(text: &str) -> Vec<String> {
        text.split('\n').map(|s| s.to_string()).collect()
    }

    #[test]
    fn marks_detect_additions() {
        let old = lines("a\nb\nc");
        let new = lines("a\nb\nc\nd");
        let marks = line_marks(&old, &new);
        assert_eq!(marks[3], LineMark::Added);
        assert_eq!(marks[0], LineMark::None);
    }

    #[test]
    fn marks_detect_changes() {
        let old = lines("a\nb\nc");
        let new = lines("a\nX\nc");
        let marks = line_marks(&old, &new);
        assert_ne!(marks[1], LineMark::None);
    }

    #[test]
    fn unified_diff_has_hunks() {
        let old = lines("one\ntwo\nthree");
        let new = lines("one\n2\nthree\nfour");
        let text = unified_diff(&old, &new, "a", "b", 1);
        assert!(text.contains("@@"));
        assert!(text.contains("-two"));
        assert!(text.contains("+2"));
        assert!(text.contains("+four"));
    }
}

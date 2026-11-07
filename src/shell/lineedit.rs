//! 提示符下的行编辑：插入/删除、左右移动、历史、Tab 补全、Ctrl+C 取消、Ctrl+L 清屏。
//!
//! 重绘策略：每次按键都回到提示符所在行首，清掉整块输入区域后重画。
//! 这样多行（自动换行）输入、宽字符、中间插入都不会留下残影。

use std::collections::BTreeMap;

use super::complete;
use super::Shell;
use crate::emulation::screen::char_width;
use crate::input::{
    decode_record, KeyEvent, Record, VK_BACK, VK_DELETE, VK_DOWN, VK_END, VK_HOME, VK_LEFT,
    VK_RETURN, VK_RIGHT, VK_TAB, VK_UP,
};
use crate::platform::win32;

enum KeyOutcome {
    /// 内容变化，原地重绘。
    Changed,
    /// 光标已在新行行首（例如打印了补全候选），重绘时不能向上移动。
    Repaint,
    Cancel,
    Submit,
}

/// 读取一行；Ctrl+C 返回 `None`。
pub fn read_line(shell: &mut Shell, prompt: &str) -> Result<Option<String>, String> {
    let history = shell.history().to_vec();
    let aliases = shell.aliases().clone();
    let mut buf: Vec<char> = Vec::new();
    let mut cursor = 0usize;
    let mut hist_index = history.len();
    let mut saved_line: Vec<char> = Vec::new();
    let mut last_rows = 0usize;

    // OSC 7（当前目录）：客户端据此在标签栏显示所在路径；换目录后每条提示符都会更新。
    if let Ok(dir) = std::env::current_dir() {
        let mut path = dir.to_string_lossy().replace('\\', "/");
        if !path.starts_with('/') {
            path.insert(0, '/');
        }
        shell.write(format!("\x1b]7;file://{path}\x07").as_bytes())?;
    }
    // OSC 133（Shell 集成）：A 标记提示符开始、B 标记提示符结束，
    // 客户端据此实现「跳到上/下一条命令」。
    shell.write(b"\x1b]133;A\x07")?;
    shell.write(prompt.as_bytes())?;
    shell.write(b"\x1b]133;B\x07")?;

    loop {
        let mut records = [win32::INPUT_RECORD::default(); 32];
        let n = shell.read_records(&mut records)?;
        for rec in records.iter().take(n) {
            match decode_record(rec) {
                Some(Record::Resize(_, _)) => {
                    // 列数变了，旧画面按新列数无法精确回退，直接重置锚点。
                    last_rows = 0;
                }
                Some(Record::Key(ev)) => {
                    // 控制台会同时送按下与抬起；行编辑只关心按下。
                    if !ev.down {
                        continue;
                    }
                    let outcome = handle_key(
                        shell,
                        &ev,
                        &mut buf,
                        &mut cursor,
                        &mut hist_index,
                        &history,
                        &mut saved_line,
                        &aliases,
                    )?;
                    match outcome {
                        KeyOutcome::Cancel => return Ok(None),
                        KeyOutcome::Submit => return Ok(Some(buf.iter().collect())),
                        KeyOutcome::Repaint => last_rows = 0,
                        KeyOutcome::Changed => {}
                    }
                    redraw(shell, prompt, &buf, cursor, &mut last_rows)?;
                }
                // shell 本身不处理鼠标（窗格里的子进程会自己开鼠标模式）。
                Some(Record::Mouse(_)) => {}
                None => {}
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn handle_key(
    shell: &mut Shell,
    ev: &KeyEvent,
    buf: &mut Vec<char>,
    cursor: &mut usize,
    hist_index: &mut usize,
    history: &[String],
    saved_line: &mut Vec<char>,
    aliases: &BTreeMap<String, String>,
) -> Result<KeyOutcome, String> {
    if crate::platform::logging::is_verbose() {
        crate::platform::logging::debug(&format!(
            "按键：vk=0x{:02X} ch={:?} ctrl={} alt={}",
            ev.vk, ev.ch, ev.ctrl, ev.alt
        ));
    }
    // Ctrl+方向键按词移动，Ctrl+Backspace / Ctrl+Delete 按词删除（与 Windows 编辑习惯一致）。
    if ev.ctrl && !ev.alt {
        match ev.vk {
            VK_LEFT => {
                *cursor = word_start(buf, *cursor);
                return Ok(KeyOutcome::Changed);
            }
            VK_RIGHT => {
                *cursor = word_end(buf, *cursor);
                return Ok(KeyOutcome::Changed);
            }
            VK_BACK => {
                delete_word_left(buf, cursor);
                return Ok(KeyOutcome::Changed);
            }
            VK_DELETE => {
                delete_word_right(buf, cursor);
                return Ok(KeyOutcome::Changed);
            }
            _ => {}
        }
    }

    // 不同宿主可能把 Backspace 送成 0x7f / 0x08 字符（不带按键码），统一按退格处理。
    if matches!(ev.ch, Some('\x7f') | Some('\x08')) {
        if *cursor > 0 {
            buf.remove(*cursor - 1);
            *cursor -= 1;
        }
        return Ok(KeyOutcome::Changed);
    }

    // Ctrl+字母可能以「控制字符」形式到达（ConPTY 把 0x01..0x1a 原样转发），
    // 也可能带 ctrl 修饰位，两条路径都要识别。
    let control_char = ev
        .ch
        .filter(|c| c.is_control() && !matches!(*c, '\r' | '\n' | '\t' | '\x08' | '\x7f'))
        .map(|c| c as u32);
    if let Some(code) = control_char {
        match code {
            0x03 => {
                shell.write(b"^C\r\n")?;
                return Ok(KeyOutcome::Cancel);
            }
            0x0c => {
                shell.write(b"\x1b[2J\x1b[H")?;
                return Ok(KeyOutcome::Repaint);
            }
            0x01 => {
                *cursor = 0;
                return Ok(KeyOutcome::Changed);
            }
            0x05 => {
                *cursor = buf.len();
                return Ok(KeyOutcome::Changed);
            }
            0x15 => {
                buf.drain(..*cursor);
                *cursor = 0;
                return Ok(KeyOutcome::Changed);
            }
            0x0b => {
                buf.truncate(*cursor);
                return Ok(KeyOutcome::Changed);
            }
            0x17 => {
                delete_word(buf, cursor);
                return Ok(KeyOutcome::Changed);
            }
            _ => return Ok(KeyOutcome::Changed),
        }
    }

    if ev.ctrl && !ev.alt {
        let key = ev.ch.map(|c| c.to_ascii_lowercase());
        match key {
            Some('c') => {
                shell.write(b"^C\r\n")?;
                return Ok(KeyOutcome::Cancel);
            }
            Some('l') => {
                shell.write(b"\x1b[2J\x1b[H")?;
                return Ok(KeyOutcome::Repaint);
            }
            Some('a') => {
                *cursor = 0;
                return Ok(KeyOutcome::Changed);
            }
            Some('e') => {
                *cursor = buf.len();
                return Ok(KeyOutcome::Changed);
            }
            Some('u') => {
                buf.drain(..*cursor);
                *cursor = 0;
                return Ok(KeyOutcome::Changed);
            }
            Some('k') => {
                buf.truncate(*cursor);
                return Ok(KeyOutcome::Changed);
            }
            Some('w') => {
                delete_word(buf, cursor);
                return Ok(KeyOutcome::Changed);
            }
            // 其余 Ctrl 组合不插入字符（避免把控制码写进命令行）。
            _ => return Ok(KeyOutcome::Changed),
        }
    }

    match ev.vk {
        VK_RETURN => {
            shell.write(b"\r\n")?;
            return Ok(KeyOutcome::Submit);
        }
        // 0x7F 是终端里的 Backspace；ConPTY 有时把它作为 vk=0x7F 送来。
        VK_BACK | 0x7F => {
            if *cursor > 0 {
                buf.remove(*cursor - 1);
                *cursor -= 1;
            }
        }
        VK_DELETE => {
            if *cursor < buf.len() {
                buf.remove(*cursor);
            }
        }
        VK_LEFT => {
            if *cursor > 0 {
                *cursor -= 1;
            }
        }
        VK_RIGHT => {
            if *cursor < buf.len() {
                *cursor += 1;
            }
        }
        VK_HOME => *cursor = 0,
        VK_END => *cursor = buf.len(),
        VK_UP => {
            if *hist_index > 0 {
                if *hist_index == history.len() {
                    *saved_line = buf.clone();
                }
                *hist_index -= 1;
                *buf = history[*hist_index].chars().collect();
                *cursor = buf.len();
            }
        }
        VK_DOWN => {
            if *hist_index < history.len() {
                *hist_index += 1;
                *buf = if *hist_index == history.len() {
                    saved_line.clone()
                } else {
                    history[*hist_index].chars().collect()
                };
                *cursor = buf.len();
            }
        }
        VK_TAB => {
            let line: String = buf.iter().collect();
            let result = complete::complete(&line, *cursor, aliases);
            *buf = result.line.chars().collect();
            *cursor = result.cursor.min(buf.len());
            if result.candidates.len() > 1 {
                print_candidates(shell, &result.candidates)?;
                return Ok(KeyOutcome::Repaint);
            }
        }
        _ => {
            if let Some(ch) = ev.ch {
                if !ch.is_control() {
                    buf.insert(*cursor, ch);
                    *cursor += 1;
                }
            }
        }
    }
    Ok(KeyOutcome::Changed)
}

/// 单词字符：字母、数字、下划线（含 CJK 等字母类字符）。
fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// 光标左侧单词的起点（先跳过空白/标点，再跳过单词）。
fn word_start(buf: &[char], cursor: usize) -> usize {
    let mut i = cursor.min(buf.len());
    while i > 0 && !is_word_char(buf[i - 1]) {
        i -= 1;
    }
    while i > 0 && is_word_char(buf[i - 1]) {
        i -= 1;
    }
    i
}

/// 光标右侧单词的终点（先跳过空白/标点，再跳过单词）。
fn word_end(buf: &[char], cursor: usize) -> usize {
    let mut i = cursor.min(buf.len());
    while i < buf.len() && !is_word_char(buf[i]) {
        i += 1;
    }
    while i < buf.len() && is_word_char(buf[i]) {
        i += 1;
    }
    i
}

fn delete_word_left(buf: &mut Vec<char>, cursor: &mut usize) {
    let start = word_start(buf, *cursor);
    buf.drain(start..*cursor);
    *cursor = start;
}

fn delete_word_right(buf: &mut Vec<char>, cursor: &mut usize) {
    let end = word_end(buf, *cursor);
    buf.drain(*cursor..end);
}

fn delete_word(buf: &mut Vec<char>, cursor: &mut usize) {
    delete_word_left(buf, cursor);
}

/// 一次重画的绘图计划。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RedrawPlan {
    /// true = 输入比屏幕还高，只能从屏幕顶部重画最后一屏的尾部。
    tail: bool,
    /// 尾部模式下要跳过的单元格数（整行对齐）。
    skip_cells: usize,
    /// 光标相对绘图区首行的 (行, 列)。
    cursor: (usize, usize),
    /// 下一次重画需要向上移动的行数。
    last_rows: usize,
}

fn plan_redraw(cols: usize, rows: usize, prompt_w: usize, buf: &[char], cursor: usize) -> RedrawPlan {
    let cols = cols.max(1);
    let rows = rows.max(2);
    let total_cells = prompt_w + cells_width(buf);
    let cursor_cells = prompt_w + cells_width(&buf[..cursor]);
    let (end_row, _) = pos(total_cells, cols);

    // 输入比屏幕还高：上面的行已经滚出屏幕，若仍按「向上 last_rows 行再整块重画」，
    // 每次按键都会把整屏再滚一遍，看起来就是所有内容堆到最后一行。
    if end_row + 1 >= rows {
        let skip_rows = end_row + 1 - rows;
        let skip_cells = skip_rows * cols;
        let rel = cursor_cells.saturating_sub(skip_cells);
        let cursor_row_col = pos(rel, cols);
        return RedrawPlan {
            tail: true,
            skip_cells,
            cursor: cursor_row_col,
            last_rows: cursor_row_col.0,
        };
    }

    RedrawPlan {
        tail: false,
        skip_cells: 0,
        cursor: pos(cursor_cells, cols),
        last_rows: pos(cursor_cells, cols).0,
    }
}

fn redraw(
    shell: &mut Shell,
    prompt: &str,
    buf: &[char],
    cursor: usize,
    last_rows: &mut usize,
) -> Result<(), String> {
    let cols = shell.cols();
    let rows = shell.rows();
    let prompt_w = str_width(prompt);
    let plan = plan_redraw(cols, rows, prompt_w, buf, cursor);
    let (cur_row, cur_col) = plan.cursor;

    let mut out = String::new();
    if plan.tail {
        // 从屏幕左上角清到末尾，只画尾部；上面的部分已不可能再看到。
        out.push_str("\x1b[1;1H\x1b[J");
        let mut skipped = 0usize;
        for ch in prompt.chars().chain(buf.iter().copied()) {
            let width = char_width(ch).max(1);
            if skipped + width <= plan.skip_cells {
                skipped += width;
                continue;
            }
            if skipped < plan.skip_cells {
                // 宽字符跨过裁剪边界：整个跳过，补一个空格保持列对齐。
                out.push(' ');
                skipped += width;
                continue;
            }
            out.push(ch);
        }
    } else {
        if *last_rows > 0 {
            out.push_str(&format!("\x1b[{}A", *last_rows));
        }
        out.push('\r');
        out.push_str("\x1b[J");
        out.push_str(prompt);
        for ch in buf {
            out.push(*ch);
        }
        let (end_row, _) = pos(prompt_w + cells_width(buf), cols);
        if end_row > cur_row {
            out.push_str(&format!("\x1b[{}A", end_row - cur_row));
        }
    }

    out.push_str(&format!("\x1b[{};{}H", cur_row + 1, cur_col + 1));
    *last_rows = plan.last_rows;
    shell.write(out.as_bytes())
}

fn print_candidates(shell: &mut Shell, candidates: &[String]) -> Result<(), String> {
    let cols = shell.cols();
    let max_w = candidates.iter().map(|c| str_width(c)).max().unwrap_or(0);
    let cell_w = (max_w + 2).max(2);
    let per_row = (cols / cell_w).max(1);
    let mut out = String::from("\r\n");
    for (index, candidate) in candidates.iter().enumerate() {
        out.push_str(candidate);
        if (index + 1) % per_row == 0 || index + 1 == candidates.len() {
            out.push_str("\r\n");
        } else {
            for _ in 0..cell_w.saturating_sub(str_width(candidate)) {
                out.push(' ');
            }
        }
    }
    shell.write(out.as_bytes())
}

fn str_width(text: &str) -> usize {
    text.chars().map(char_width).sum()
}

fn cells_width(chars: &[char]) -> usize {
    chars.iter().map(|c| char_width(*c)).sum()
}

/// 已输出 `cells` 个单元格后光标所在的 (行, 列)。
fn pos(cells: usize, cols: usize) -> (usize, usize) {
    if cells == 0 {
        return (0, 0);
    }
    let row = (cells - 1) / cols;
    let col = ((cells - 1) % cols + 1).min(cols.saturating_sub(1));
    (row, col)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_position_wraps() {
        assert_eq!(pos(0, 80), (0, 0));
        assert_eq!(pos(1, 80), (0, 1));
        assert_eq!(pos(79, 80), (0, 79));
        assert_eq!(pos(80, 80), (0, 79));
        assert_eq!(pos(81, 80), (1, 1));
    }

    #[test]
    fn delete_word_removes_previous_word() {
        let mut buf: Vec<char> = "echo hello world".chars().collect();
        let mut cursor = buf.len();
        delete_word(&mut buf, &mut cursor);
        assert_eq!(buf.iter().collect::<String>(), "echo hello ");
        assert_eq!(cursor, 11);
    }

    #[test]
    fn redraw_plan_uses_tail_when_input_is_taller_than_screen() {
        // 10 列 3 行，提示符 2 列，输入 40 字符 = 42 单元格 = 5 行（比屏幕高）
        let buf: Vec<char> = "a".repeat(40).chars().collect();
        let plan = plan_redraw(10, 3, 2, &buf, 40);
        assert!(plan.tail, "输入比屏幕高时必须走尾部重画");
        assert_eq!(plan.skip_cells, 20, "5 行只保留最后 3 行，跳过 2 行");
        // 光标在末尾：42 - 20 = 22 → 第 3 行第 3 列（0 起）
        assert_eq!(plan.cursor, (2, 2));
        assert_eq!(plan.last_rows, 2);

        // 刚好放得下时仍用原来的相对重画
        let short: Vec<char> = "abc".chars().collect();
        let plan = plan_redraw(10, 3, 2, &short, 3);
        assert!(!plan.tail);
        assert_eq!(plan.skip_cells, 0);
        assert_eq!(plan.cursor, (0, 5));
    }

    #[test]
    fn word_motion_and_deletion() {
        let buf: Vec<char> = "echo hello world".chars().collect();
        // 行尾往左：落到 world 的起点
        assert_eq!(word_start(&buf, buf.len()), 11);
        // 再往左一次：落到 hello 的起点（跳过中间的空格）
        assert_eq!(word_start(&buf, 11), 5);
        // 行首往右：落到 echo 的词尾（Windows 行为：移动到当前词末）
        assert_eq!(word_end(&buf, 0), 4);
        assert_eq!(word_end(&buf, 5), 10);

        let mut buf = buf;
        let mut cursor = 5;
        delete_word_right(&mut buf, &mut cursor);
        assert_eq!(buf.iter().collect::<String>(), "echo  world");
        assert_eq!(cursor, 5);

        // 中文按词处理：一个汉字算单词字符
        let cjk: Vec<char> = "进入 目录".chars().collect();
        assert_eq!(word_start(&cjk, cjk.len()), 3);
    }
}

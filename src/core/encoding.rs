//! 编码识别与转换：UTF-8 / UTF-8 BOM / GBK / GB18030 / UTF-16 LE / BE。
//!
//! 全部通过 Win32 代码页 API 完成，不依赖第三方编码库；
//! 内部统一使用 UTF-8 字符串与 LF 换行，保存时再转回原编码。

use crate::platform::win32;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Encoding {
    Utf8,
    Utf8Bom,
    Gbk,
    Utf16Le,
    Utf16Be,
}

impl Encoding {
    pub fn label(self) -> &'static str {
        match self {
            Encoding::Utf8 => "UTF-8",
            Encoding::Utf8Bom => "UTF-8 BOM",
            Encoding::Gbk => "GBK",
            Encoding::Utf16Le => "UTF-16LE",
            Encoding::Utf16Be => "UTF-16BE",
        }
    }

    pub fn parse(text: &str) -> Option<Encoding> {
        match text.trim().to_ascii_lowercase().as_str() {
            "utf-8" | "utf8" => Some(Encoding::Utf8),
            "utf-8 bom" | "utf8bom" | "utf-8-bom" => Some(Encoding::Utf8Bom),
            "gbk" | "gb2312" | "gb18030" => Some(Encoding::Gbk),
            "utf-16le" | "utf16le" => Some(Encoding::Utf16Le),
            "utf-16be" | "utf16be" => Some(Encoding::Utf16Be),
            _ => None,
        }
    }

    pub fn all() -> &'static [Encoding] {
        &[
            Encoding::Utf8,
            Encoding::Utf8Bom,
            Encoding::Gbk,
            Encoding::Utf16Le,
            Encoding::Utf16Be,
        ]
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Eol {
    Lf,
    CrLf,
    Cr,
}

impl Eol {
    pub fn label(self) -> &'static str {
        match self {
            Eol::Lf => "LF",
            Eol::CrLf => "CRLF",
            Eol::Cr => "CR",
        }
    }

    pub fn parse(text: &str) -> Option<Eol> {
        match text.trim().to_ascii_uppercase().as_str() {
            "LF" | "\\N" => Some(Eol::Lf),
            "CRLF" | "\\R\\N" => Some(Eol::CrLf),
            "CR" | "\\R" => Some(Eol::Cr),
            _ => None,
        }
    }

    pub fn all() -> &'static [Eol] {
        &[Eol::Lf, Eol::CrLf, Eol::Cr]
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Eol::Lf => "\n",
            Eol::CrLf => "\r\n",
            Eol::Cr => "\r",
        }
    }
}

pub struct Decoded {
    /// 已规范化为 LF 的文本。
    pub text: String,
    pub encoding: Encoding,
    pub eol: Eol,
    /// 解码过程中出现过非法字节（按替换字符处理）。
    pub lossy: bool,
}

/// 识别并解码文件内容。
pub fn decode(bytes: &[u8]) -> Decoded {
    // 1. BOM
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        let text = String::from_utf8_lossy(&bytes[3..]).to_string();
        return finish(text, Encoding::Utf8Bom, false);
    }
    if bytes.starts_with(&[0xFF, 0xFE]) {
        return decode_utf16(&bytes[2..], false, Encoding::Utf16Le);
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        return decode_utf16(&bytes[2..], true, Encoding::Utf16Be);
    }

    // 2. 无 BOM 的 UTF-16：ASCII 文本会大量出现 NUL 字节，优先判断。
    if looks_utf16(bytes) {
        let le = bytes.iter().skip(1).step_by(2).filter(|b| **b == 0).count();
        let be = bytes.iter().step_by(2).filter(|b| **b == 0).count();
        if le >= be {
            return decode_utf16(bytes, false, Encoding::Utf16Le);
        }
        return decode_utf16(bytes, true, Encoding::Utf16Be);
    }

    // 3. 严格 UTF-8
    if let Ok(text) = std::str::from_utf8(bytes) {
        return finish(text.to_string(), Encoding::Utf8, false);
    }

    // 4. GBK（中文环境最常见）
    if let Some(text) = win32::decode_codepage(win32::CP_GBK, bytes, true) {
        return finish(text, Encoding::Gbk, false);
    }
    if let Some(text) = win32::decode_codepage(win32::CP_GBK, bytes, false) {
        return finish(text, Encoding::Gbk, true);
    }
    let text = String::from_utf8_lossy(bytes).to_string();
    finish(text, Encoding::Utf8, true)
}

fn decode_utf16(bytes: &[u8], big_endian: bool, encoding: Encoding) -> Decoded {
    let mut units = Vec::with_capacity(bytes.len() / 2);
    let mut lossy = bytes.len() % 2 == 1;
    let chunks = bytes.chunks_exact(2);
    for pair in chunks {
        let unit = if big_endian {
            u16::from_be_bytes([pair[0], pair[1]])
        } else {
            u16::from_le_bytes([pair[0], pair[1]])
        };
        units.push(unit);
    }
    if units.iter().any(|u| *u == 0xFFFD) {
        lossy = true;
    }
    let text = String::from_utf16_lossy(&units);
    finish(text, encoding, lossy)
}

/// 判断字节流是否为 UTF-16（含 BOM，或无 BOM 的启发式判断）。
pub fn is_utf16(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xFF, 0xFE]) || bytes.starts_with(&[0xFE, 0xFF]) || looks_utf16(bytes)
}

/// 空字节分布像 UTF-16（ASCII 文本奇数/偶数位大量为 0）。
fn looks_utf16(bytes: &[u8]) -> bool {
    if bytes.len() < 4 {
        return false;
    }
    let len = bytes.len().min(4096);
    let even_zero = bytes.iter().take(len).step_by(2).filter(|b| **b == 0).count();
    let odd_zero = bytes
        .iter()
        .skip(1)
        .take(len)
        .step_by(2)
        .filter(|b| **b == 0)
        .count();
    let half = len / 2;
    (even_zero * 2 > half || odd_zero * 2 > half) && (even_zero.min(odd_zero) * 8 < half)
}

fn finish(text: String, encoding: Encoding, lossy: bool) -> Decoded {
    let eol = detect_eol(&text);
    // 绝大多数文件已经是 LF，跳过两次整串复制。
    let text = if text.contains('\r') {
        text.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        text
    };
    Decoded {
        text,
        encoding,
        eol,
        lossy,
    }
}

/// 统计换行符，取出现最多的一种。
pub fn detect_eol(text: &str) -> Eol {
    let mut crlf = 0usize;
    let mut lf = 0usize;
    let mut cr = 0usize;
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\r' => {
                if bytes.get(i + 1) == Some(&b'\n') {
                    crlf += 1;
                    i += 2;
                    continue;
                }
                cr += 1;
            }
            b'\n' => lf += 1,
            _ => {}
        }
        i += 1;
    }
    if crlf >= lf && crlf >= cr {
        Eol::CrLf
    } else if lf >= cr {
        Eol::Lf
    } else {
        Eol::Cr
    }
}

/// 保存前把内部文本（LF）转换为目标编码与换行。
pub fn encode(text: &str, encoding: Encoding, eol: Eol) -> Vec<u8> {
    use std::borrow::Cow;
    // 先统一成 LF，避免调用方传入 CRLF 时出现 `\r\r\n`；
    // 已是 LF 时借用原串，省掉一次整串复制。
    let normalized: Cow<str> = if text.contains('\r') {
        Cow::Owned(text.replace("\r\n", "\n").replace('\r', "\n"))
    } else {
        Cow::Borrowed(text)
    };
    let converted: Cow<str> = if eol == Eol::Lf {
        normalized
    } else {
        let newline = eol.as_str();
        let mut out = String::with_capacity(normalized.len() + normalized.len() / 16);
        for ch in normalized.chars() {
            if ch == '\n' {
                out.push_str(newline);
            } else {
                out.push(ch);
            }
        }
        Cow::Owned(out)
    };

    match encoding {
        Encoding::Utf8 => converted.as_bytes().to_vec(),
        Encoding::Utf8Bom => {
            let mut out = Vec::with_capacity(converted.len() + 3);
            out.extend_from_slice(&[0xEF, 0xBB, 0xBF]);
            out.extend_from_slice(converted.as_bytes());
            out
        }
        Encoding::Gbk => win32::encode_codepage(win32::CP_GBK, &converted, false)
            .unwrap_or_else(|| converted.as_bytes().to_vec()),
        Encoding::Utf16Le => {
            let mut out = Vec::with_capacity(converted.len() * 2 + 2);
            for unit in converted.encode_utf16() {
                out.extend_from_slice(&unit.to_le_bytes());
            }
            out
        }
        Encoding::Utf16Be => {
            let mut out = Vec::with_capacity(converted.len() * 2 + 2);
            for unit in converted.encode_utf16() {
                out.extend_from_slice(&unit.to_be_bytes());
            }
            out
        }
    }
}

/// 把文本按任意换行符切分成行。
///
/// 末尾换行保留为一个空行（`"a\n" → ["a", ""]`），这样 `join("\n")`
/// 可以无损还原原文本，不需要额外的「末尾换行」标志。
pub fn split_lines(text: &str) -> Vec<String> {
    if text.is_empty() {
        return vec![String::new()];
    }
    let mut lines: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                lines.push(std::mem::take(&mut current));
            }
            '\n' => lines.push(std::mem::take(&mut current)),
            _ => current.push(ch),
        }
    }
    lines.push(current);
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_and_bom() {
        let d = decode("中文\nabc".as_bytes());
        assert_eq!(d.encoding, Encoding::Utf8);
        assert_eq!(d.text, "中文\nabc");

        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(b"hi");
        let d = decode(&bytes);
        assert_eq!(d.encoding, Encoding::Utf8Bom);
        assert_eq!(d.text, "hi");
    }

    #[test]
    fn gbk_roundtrip() {
        let text = "第一行\n第二行";
        let bytes = encode(text, Encoding::Gbk, Eol::CrLf);
        // 中文在 GBK 下每个字 2 字节，明显比带 BOM 的其它编码紧凑
        assert!(bytes.len() < text.len() * 2);
        let d = decode(&bytes);
        assert_eq!(d.encoding, Encoding::Gbk);
        assert_eq!(d.text, "第一行\n第二行");
        assert_eq!(d.eol, Eol::CrLf);
    }

    #[test]
    fn utf16_le_roundtrip() {
        let bytes = encode("ab中", Encoding::Utf16Le, Eol::Lf);
        let d = decode(&bytes);
        assert_eq!(d.encoding, Encoding::Utf16Le);
        assert_eq!(d.text, "ab中");
    }

    #[test]
    fn eol_detection() {
        assert_eq!(detect_eol("a\r\nb\r\nc"), Eol::CrLf);
        assert_eq!(detect_eol("a\nb\nc"), Eol::Lf);
        assert_eq!(detect_eol("a\rb\rc"), Eol::Cr);
        assert_eq!(split_lines("a\nb\n"), vec!["a", "b", ""]);
        assert_eq!(split_lines("a\nb"), vec!["a", "b"]);
        assert_eq!(split_lines(""), vec![""]);
    }
}

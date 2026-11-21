//! ZIP 读写（docx/xlsx 容器）+ 自研 DEFLATE 解压。
//!
//! 保存时统一用「存储」方式（method 0），不实现压缩器也能被 Office 正常打开；
//! 读取时支持系统生成的 deflate（method 8）。

use std::path::Path;

pub struct Entry {
    pub name: String,
    pub method: u16,
    /// 压缩后的原始字节（method 0 时即原文）。
    pub raw: Vec<u8>,
    pub crc: u32,
    pub size: u32,
}

pub struct Zip {
    pub entries: Vec<Entry>,
}

impl Zip {
    pub fn read_file(path: &Path) -> Result<Zip, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("读取失败：{e}"))?;
        Zip::read(&bytes)
    }

    pub fn read(bytes: &[u8]) -> Result<Zip, String> {
        let eocd = find_eocd(bytes).ok_or_else(|| "不是有效的 ZIP 文件（缺少目录尾）".to_string())?;
        let count = read_u16(bytes, eocd + 10) as usize;
        let cd_offset = read_u32(bytes, eocd + 16) as usize;
        let mut entries = Vec::with_capacity(count);
        let mut cursor = cd_offset;
        for _ in 0..count {
            if read_u32(bytes, cursor) != 0x02014b50 {
                return Err("ZIP 中央目录损坏".into());
            }
            let method = read_u16(bytes, cursor + 10);
            let crc = read_u32(bytes, cursor + 16);
            let compressed = read_u32(bytes, cursor + 20) as usize;
            let uncompressed = read_u32(bytes, cursor + 24);
            let name_len = read_u16(bytes, cursor + 28) as usize;
            let extra_len = read_u16(bytes, cursor + 30) as usize;
            let comment_len = read_u16(bytes, cursor + 32) as usize;
            let local_offset = read_u32(bytes, cursor + 42) as usize;
            let name = String::from_utf8_lossy(&bytes[cursor + 46..cursor + 46 + name_len])
                .to_string();
            cursor += 46 + name_len + extra_len + comment_len;
            if read_u32(bytes, local_offset) != 0x04034b50 {
                return Err("ZIP 本地文件头损坏".into());
            }
            let local_name_len = read_u16(bytes, local_offset + 26) as usize;
            let local_extra_len = read_u16(bytes, local_offset + 28) as usize;
            let data_start = local_offset + 30 + local_name_len + local_extra_len;
            if data_start + compressed > bytes.len() {
                return Err("ZIP 条目越界".into());
            }
            let raw = bytes[data_start..data_start + compressed].to_vec();
            entries.push(Entry {
                name,
                method,
                raw,
                crc,
                size: uncompressed,
            });
        }
        Ok(Zip { entries })
    }

    pub fn names(&self) -> Vec<&str> {
        self.entries.iter().map(|e| e.name.as_str()).collect()
    }

    pub fn get(&self, name: &str) -> Option<Vec<u8>> {
        let entry = self.entries.iter().find(|e| e.name == name)?;
        match entry.method {
            0 => Some(entry.raw.clone()),
            8 => inflate(&entry.raw, entry.size as usize).ok(),
            _ => None,
        }
    }

    pub fn get_text(&self, name: &str) -> Option<String> {
        self.get(name)
            .map(|bytes| String::from_utf8_lossy(&bytes).to_string())
    }

    /// 写入/覆盖一个条目（以存储方式保存）。
    pub fn set(&mut self, name: &str, data: &[u8]) {
        let crc = crc32(data);
        if let Some(entry) = self.entries.iter_mut().find(|e| e.name == name) {
            entry.method = 0;
            entry.crc = crc;
            entry.size = data.len() as u32;
            entry.raw = data.to_vec();
        } else {
            self.entries.push(Entry {
                name: name.to_string(),
                method: 0,
                raw: data.to_vec(),
                crc,
                size: data.len() as u32,
            });
        }
    }

    /// 删除一个条目。
    pub fn remove(&mut self, name: &str) {
        self.entries.retain(|entry| entry.name != name);
    }

    pub fn save_file(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        std::fs::write(path, self.write()).map_err(|e| format!("保存失败：{e}"))
    }

    pub fn write(&self) -> Vec<u8> {
        let mut out = Vec::new();
        let mut offsets = Vec::with_capacity(self.entries.len());
        for entry in &self.entries {
            offsets.push(out.len() as u32);
            let name = entry.name.as_bytes();
            out.extend_from_slice(&0x04034b50u32.to_le_bytes());
            out.extend_from_slice(&20u16.to_le_bytes()); // version needed
            out.extend_from_slice(&0x0800u16.to_le_bytes()); // UTF-8
            out.extend_from_slice(&entry.method.to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes()); // time
            out.extend_from_slice(&0u16.to_le_bytes()); // date
            out.extend_from_slice(&entry.crc.to_le_bytes());
            out.extend_from_slice(&(entry.raw.len() as u32).to_le_bytes());
            out.extend_from_slice(&entry.size.to_le_bytes());
            out.extend_from_slice(&(name.len() as u16).to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes()); // extra
            out.extend_from_slice(name);
            out.extend_from_slice(&entry.raw);
        }
        let cd_start = out.len() as u32;
        for (entry, offset) in self.entries.iter().zip(offsets.iter()) {
            let name = entry.name.as_bytes();
            out.extend_from_slice(&0x02014b50u32.to_le_bytes());
            out.extend_from_slice(&20u16.to_le_bytes()); // version made
            out.extend_from_slice(&20u16.to_le_bytes()); // version needed
            out.extend_from_slice(&0x0800u16.to_le_bytes());
            out.extend_from_slice(&entry.method.to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&entry.crc.to_le_bytes());
            out.extend_from_slice(&(entry.raw.len() as u32).to_le_bytes());
            out.extend_from_slice(&entry.size.to_le_bytes());
            out.extend_from_slice(&(name.len() as u16).to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes()); // extra
            out.extend_from_slice(&0u16.to_le_bytes()); // comment
            out.extend_from_slice(&0u16.to_le_bytes()); // disk
            out.extend_from_slice(&0u16.to_le_bytes()); // internal
            out.extend_from_slice(&0u32.to_le_bytes()); // external
            out.extend_from_slice(&offset.to_le_bytes());
            out.extend_from_slice(name);
        }
        let cd_end = out.len() as u32;
        out.extend_from_slice(&0x06054b50u32.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&(self.entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&(self.entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&(cd_end - cd_start).to_le_bytes());
        out.extend_from_slice(&cd_start.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out
    }
}

fn find_eocd(bytes: &[u8]) -> Option<usize> {
    if bytes.len() < 22 {
        return None;
    }
    let start = bytes.len().saturating_sub(65557);
    for index in (start..=bytes.len() - 22).rev() {
        if read_u32(bytes, index) == 0x06054b50 {
            return Some(index);
        }
    }
    None
}

fn read_u16(bytes: &[u8], at: usize) -> u16 {
    if at + 2 > bytes.len() {
        return 0;
    }
    u16::from_le_bytes([bytes[at], bytes[at + 1]])
}

fn read_u32(bytes: &[u8], at: usize) -> u32 {
    if at + 4 > bytes.len() {
        return 0;
    }
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

// ---------------------------------------------------------------- CRC32

pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for byte in data {
        crc ^= *byte as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

// ---------------------------------------------------------------- DEFLATE

struct Bits<'a> {
    data: &'a [u8],
    bit: usize,
}

impl<'a> Bits<'a> {
    fn new(data: &'a [u8]) -> Bits<'a> {
        Bits { data, bit: 0 }
    }

    fn read(&mut self, count: u8) -> Result<u32, String> {
        let mut value = 0u32;
        for i in 0..count {
            let byte = self.bit / 8;
            if byte >= self.data.len() {
                return Err("DEFLATE 数据不完整".into());
            }
            let bit = (self.data[byte] >> (self.bit % 8)) & 1;
            value |= (bit as u32) << i;
            self.bit += 1;
        }
        Ok(value)
    }

    fn align(&mut self) {
        if self.bit % 8 != 0 {
            self.bit += 8 - (self.bit % 8);
        }
    }
}

struct Huffman {
    counts: [u16; 16],
    symbols: Vec<u16>,
}

impl Huffman {
    fn new(lengths: &[u8]) -> Huffman {
        let mut counts = [0u16; 16];
        for length in lengths {
            counts[*length as usize] += 1;
        }
        counts[0] = 0;
        let mut offsets = [0u16; 16];
        for len in 1..16 {
            offsets[len] = offsets[len - 1] + counts[len - 1];
        }
        let mut symbols = vec![0u16; lengths.len()];
        for (symbol, length) in lengths.iter().enumerate() {
            if *length != 0 {
                symbols[offsets[*length as usize] as usize] = symbol as u16;
                offsets[*length as usize] += 1;
            }
        }
        Huffman { counts, symbols }
    }

    fn decode(&self, bits: &mut Bits) -> Result<u16, String> {
        let mut code = 0i32;
        let mut first = 0i32;
        let mut index = 0i32;
        for len in 1..=15 {
            code |= bits.read(1)? as i32;
            let count = self.counts[len] as i32;
            if code - first < count {
                return Ok(self.symbols[(index + code - first) as usize]);
            }
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        Err("DEFLATE Huffman 解码失败".into())
    }
}

const LENGTH_BASE: [u16; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
    131, 163, 195, 227, 258,
];
const LENGTH_EXTRA: [u8; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DIST_BASE: [u16; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DIST_EXTRA: [u8; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12,
    13, 13,
];

pub fn inflate(data: &[u8], expected: usize) -> Result<Vec<u8>, String> {
    let mut bits = Bits::new(data);
    let mut out: Vec<u8> = Vec::with_capacity(expected);
    loop {
        let last = bits.read(1)? == 1;
        let kind = bits.read(2)?;
        match kind {
            0 => {
                bits.align();
                let len = bits.read(16)? as usize;
                let _nlen = bits.read(16)?;
                for _ in 0..len {
                    out.push(bits.read(8)? as u8);
                }
            }
            1 => {
                let mut lengths = [0u8; 288];
                for (index, length) in lengths.iter_mut().enumerate() {
                    *length = match index {
                        0..=143 => 8,
                        144..=255 => 9,
                        256..=279 => 7,
                        _ => 8,
                    };
                }
                let literal = Huffman::new(&lengths);
                let distance = Huffman::new(&[5u8; 32]);
                decode_block(&mut bits, &literal, &distance, &mut out)?;
            }
            2 => {
                let hlit = bits.read(5)? as usize + 257;
                let hdist = bits.read(5)? as usize + 1;
                let hclen = bits.read(4)? as usize + 4;
                let order = [
                    16usize, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
                ];
                let mut code_lengths = [0u8; 19];
                for i in 0..hclen {
                    code_lengths[order[i]] = bits.read(3)? as u8;
                }
                let code_huffman = Huffman::new(&code_lengths);
                let mut lengths = vec![0u8; hlit + hdist];
                let mut index = 0usize;
                while index < lengths.len() {
                    let symbol = code_huffman.decode(&mut bits)?;
                    match symbol {
                        0..=15 => {
                            lengths[index] = symbol as u8;
                            index += 1;
                        }
                        16 => {
                            if index == 0 {
                                return Err("DEFLATE 重复长度无效".into());
                            }
                            let previous = lengths[index - 1];
                            let repeat = 3 + bits.read(2)? as usize;
                            for _ in 0..repeat {
                                if index >= lengths.len() {
                                    break;
                                }
                                lengths[index] = previous;
                                index += 1;
                            }
                        }
                        17 => {
                            let repeat = 3 + bits.read(3)? as usize;
                            index = (index + repeat).min(lengths.len());
                        }
                        18 => {
                            let repeat = 11 + bits.read(7)? as usize;
                            index = (index + repeat).min(lengths.len());
                        }
                        _ => return Err("DEFLATE 码长符号无效".into()),
                    }
                }
                let literal = Huffman::new(&lengths[..hlit]);
                let distance = Huffman::new(&lengths[hlit..]);
                decode_block(&mut bits, &literal, &distance, &mut out)?;
            }
            _ => return Err("DEFLATE 块类型无效".into()),
        }
        if last {
            break;
        }
    }
    Ok(out)
}

fn decode_block(
    bits: &mut Bits,
    literal: &Huffman,
    distance: &Huffman,
    out: &mut Vec<u8>,
) -> Result<(), String> {
    loop {
        let symbol = literal.decode(bits)?;
        match symbol {
            0..=255 => out.push(symbol as u8),
            256 => return Ok(()),
            257..=285 => {
                let index = (symbol - 257) as usize;
                let length = LENGTH_BASE[index] as usize + bits.read(LENGTH_EXTRA[index])? as usize;
                let distance_symbol = distance.decode(bits)? as usize;
                if distance_symbol >= DIST_BASE.len() {
                    return Err("DEFLATE 距离符号无效".into());
                }
                let dist = DIST_BASE[distance_symbol] as usize
                    + bits.read(DIST_EXTRA[distance_symbol])? as usize;
                if dist == 0 || dist > out.len() {
                    return Err("DEFLATE 回溯距离越界".into());
                }
                let start = out.len() - dist;
                for i in 0..length {
                    let byte = out[start + i];
                    out.push(byte);
                }
            }
            _ => return Err("DEFLATE 字面量符号无效".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc_matches_known_value() {
        assert_eq!(crc32(b"123456789"), 0xCBF43926);
    }

    #[test]
    fn zip_roundtrip() {
        let mut zip = Zip { entries: Vec::new() };
        zip.set("a.txt", b"hello");
        zip.set("dir/b.txt", "中文内容".as_bytes());
        let bytes = zip.write();
        let read = Zip::read(&bytes).unwrap();
        assert_eq!(read.get_text("a.txt").unwrap(), "hello");
        assert_eq!(read.get_text("dir/b.txt").unwrap(), "中文内容");
    }
}

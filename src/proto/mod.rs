//! 二进制帧协议：12 字节头 + payload。
//!
//! ```text
//! offset 0  magic  4B "SCTM"
//! offset 4  ver    1B 协议版本
//! offset 5  type   1B 帧类型
//! offset 6  flags  2B 保留，必须为 0
//! offset 8  length 4B payload 长度（<= 1 MiB）
//! offset 12 payload
//! ```

pub mod caps;
pub mod msg;

pub const MAGIC: [u8; 4] = *b"SCTM";
pub const PROTO_VERSION: u8 = 1;
pub const HEADER_LEN: usize = 12;
pub const MAX_PAYLOAD: u32 = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameType {
    Hello = 0x01,
    HelloAck = 0x02,
    CreatePane = 0x03,
    PaneCreated = 0x04,
    Input = 0x05,
    Output = 0x06,
    Resize = 0x07,
    PaneExited = 0x08,
    Ping = 0x09,
    Pong = 0x0A,
    Error = 0x0B,
    ClosePane = 0x0C,
}

impl FrameType {
    pub fn from_u8(v: u8) -> Option<FrameType> {
        use FrameType::*;
        Some(match v {
            0x01 => Hello,
            0x02 => HelloAck,
            0x03 => CreatePane,
            0x04 => PaneCreated,
            0x05 => Input,
            0x06 => Output,
            0x07 => Resize,
            0x08 => PaneExited,
            0x09 => Ping,
            0x0A => Pong,
            0x0B => Error,
            0x0C => ClosePane,
            _ => return None,
        })
    }
}

#[derive(Debug)]
pub struct Frame {
    pub ty: FrameType,
    pub payload: Vec<u8>,
}

/// 把帧编码成可直接写入管道的字节序列。
pub fn encode(ty: FrameType, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.extend_from_slice(&MAGIC);
    out.push(PROTO_VERSION);
    out.push(ty as u8);
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    out
}

/// 解析帧头，返回帧类型与 payload 长度。
pub fn decode_header(hdr: &[u8]) -> Result<(FrameType, usize), String> {
    if hdr.len() < HEADER_LEN {
        return Err("帧头长度不足".into());
    }
    if hdr[0..4] != MAGIC {
        return Err("帧魔数不匹配，连接的对端可能不是 scterm 服务".into());
    }
    let ver = hdr[4];
    if ver != PROTO_VERSION {
        return Err(format!(
            "协议版本不兼容：对端 {ver}，本端 {PROTO_VERSION}"
        ));
    }
    let ty = FrameType::from_u8(hdr[5]).ok_or_else(|| format!("未知帧类型 0x{:02X}", hdr[5]))?;
    let flags = u16::from_le_bytes([hdr[6], hdr[7]]);
    if flags != 0 {
        return Err(format!("帧保留字段非 0（{flags}）"));
    }
    let len = u32::from_le_bytes([hdr[8], hdr[9], hdr[10], hdr[11]]);
    if len > MAX_PAYLOAD {
        return Err(format!("帧过大：{len} 字节，超过上限 {MAX_PAYLOAD}"));
    }
    Ok((ty, len as usize))
}

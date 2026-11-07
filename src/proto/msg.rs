//! 各类帧的 payload 编解码。字符串统一为 `u32 长度 + UTF-8 字节`。

// 阶段 0 只用到了部分帧，其余编解码保留给后续阶段（标签页、窗格树、控制平面）。
#![allow(dead_code)]

/// 小端写入器。
#[derive(Default)]
pub struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Writer { buf: Vec::new() }
    }

    pub fn u8(&mut self, v: u8) -> &mut Self {
        self.buf.push(v);
        self
    }

    pub fn u16(&mut self, v: u16) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn i32(&mut self, v: i32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn u32(&mut self, v: u32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn u64(&mut self, v: u64) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn str(&mut self, s: &str) -> &mut Self {
        self.bytes(s.as_bytes())
    }

    pub fn bytes(&mut self, b: &[u8]) -> &mut Self {
        self.buf.extend_from_slice(&(b.len() as u32).to_le_bytes());
        self.buf.extend_from_slice(b);
        self
    }

    pub fn finish(self) -> Vec<u8> {
        self.buf
    }
}

/// 小端读取器，越界一律返回错误而不是 panic。
pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    fn need(&self, n: usize) -> Result<(), String> {
        if self.buf.len() - self.pos < n {
            Err(format!(
                "帧 payload 长度不足：需要 {n} 字节，剩余 {}",
                self.buf.len() - self.pos
            ))
        } else {
            Ok(())
        }
    }

    pub fn u8(&mut self) -> Result<u8, String> {
        self.need(1)?;
        let v = self.buf[self.pos];
        self.pos += 1;
        Ok(v)
    }

    pub fn u16(&mut self) -> Result<u16, String> {
        self.need(2)?;
        let v = u16::from_le_bytes([self.buf[self.pos], self.buf[self.pos + 1]]);
        self.pos += 2;
        Ok(v)
    }

    pub fn i32(&mut self) -> Result<i32, String> {
        self.need(4)?;
        let b = &self.buf[self.pos..self.pos + 4];
        self.pos += 4;
        Ok(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn u32(&mut self) -> Result<u32, String> {
        self.need(4)?;
        let b = &self.buf[self.pos..self.pos + 4];
        self.pos += 4;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn u64(&mut self) -> Result<u64, String> {
        self.need(8)?;
        let mut b = [0u8; 8];
        b.copy_from_slice(&self.buf[self.pos..self.pos + 8]);
        self.pos += 8;
        Ok(u64::from_le_bytes(b))
    }

    pub fn bytes(&mut self) -> Result<Vec<u8>, String> {
        let len = self.u32()? as usize;
        self.need(len)?;
        let v = self.buf[self.pos..self.pos + len].to_vec();
        self.pos += len;
        Ok(v)
    }

    pub fn str(&mut self) -> Result<String, String> {
        let raw = self.bytes()?;
        String::from_utf8(raw).map_err(|e| format!("字符串不是合法 UTF-8：{e}"))
    }
}

pub struct Hello {
    pub proto_ver: u16,
    pub build: u32,
    pub caps: u32,
    pub cols: u16,
    pub rows: u16,
    pub profile: String,
}

impl Hello {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u16(self.proto_ver)
            .u32(self.build)
            .u32(self.caps)
            .u16(self.cols)
            .u16(self.rows)
            .str(&self.profile);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(Hello {
            proto_ver: r.u16()?,
            build: r.u32()?,
            caps: r.u32()?,
            cols: r.u16()?,
            rows: r.u16()?,
            profile: r.str()?,
        })
    }
}

pub struct HelloAck {
    pub proto_ver: u16,
    pub build: u32,
    pub caps: u32,
    pub session_id: u64,
}

impl HelloAck {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u16(self.proto_ver)
            .u32(self.build)
            .u32(self.caps)
            .u64(self.session_id);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(HelloAck {
            proto_ver: r.u16()?,
            build: r.u32()?,
            caps: r.u32()?,
            session_id: r.u64()?,
        })
    }
}

pub struct CreatePane {
    pub pane_id: u32,
    pub profile: String,
    pub cols: u16,
    pub rows: u16,
}

impl CreatePane {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u32(self.pane_id)
            .str(&self.profile)
            .u16(self.cols)
            .u16(self.rows);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(CreatePane {
            pane_id: r.u32()?,
            profile: r.str()?,
            cols: r.u16()?,
            rows: r.u16()?,
        })
    }
}

pub struct PaneCreated {
    pub pane_id: u32,
    pub pid: u32,
}

impl PaneCreated {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u32(self.pane_id).u32(self.pid);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(PaneCreated {
            pane_id: r.u32()?,
            pid: r.u32()?,
        })
    }
}

pub struct PaneData {
    pub pane_id: u32,
    pub data: Vec<u8>,
}

impl PaneData {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u32(self.pane_id).bytes(&self.data);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(PaneData {
            pane_id: r.u32()?,
            data: r.bytes()?,
        })
    }
}

pub struct Resize {
    pub pane_id: u32,
    pub cols: u16,
    pub rows: u16,
}

impl Resize {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u32(self.pane_id).u16(self.cols).u16(self.rows);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(Resize {
            pane_id: r.u32()?,
            cols: r.u16()?,
            rows: r.u16()?,
        })
    }
}

pub struct PaneExited {
    pub pane_id: u32,
    pub exit_code: i32,
}

impl PaneExited {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u32(self.pane_id).i32(self.exit_code);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(PaneExited {
            pane_id: r.u32()?,
            exit_code: r.i32()?,
        })
    }
}

pub struct Token {
    pub value: u64,
}

impl Token {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u64(self.value);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(Token { value: r.u64()? })
    }
}

pub struct ErrorMsg {
    pub code: u16,
    pub message: String,
}

pub const ERR_PROTOCOL: u16 = 0x0001;
pub const ERR_PANE_CREATE: u16 = 0x0002;
pub const ERR_BAD_REQUEST: u16 = 0x0003;

impl ErrorMsg {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u16(self.code).str(&self.message);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(ErrorMsg {
            code: r.u16()?,
            message: r.str()?,
        })
    }
}

pub struct PaneId {
    pub pane_id: u32,
}

impl PaneId {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Writer::new();
        w.u32(self.pane_id);
        w.finish()
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let mut r = Reader::new(buf);
        Ok(PaneId { pane_id: r.u32()? })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::{decode_header, encode, FrameType};

    #[test]
    fn pane_data_roundtrip() {
        let msg = PaneData {
            pane_id: 7,
            data: b"hello \xe4\xb8\xad\xe6\x96\x87".to_vec(),
        };
        let decoded = PaneData::decode(&msg.encode()).unwrap();
        assert_eq!(decoded.pane_id, 7);
        assert_eq!(decoded.data, msg.data);
    }

    #[test]
    fn frame_header_roundtrip() {
        let payload = HelloAck {
            proto_ver: 1,
            build: 17763,
            caps: 5,
            session_id: 42,
        }
        .encode();
        let raw = encode(FrameType::HelloAck, &payload);
        let (ty, len) = decode_header(&raw[..12]).unwrap();
        assert_eq!(ty, FrameType::HelloAck);
        assert_eq!(len, payload.len());
        assert_eq!(raw.len(), 12 + payload.len());
    }

    #[test]
    fn truncated_payload_is_error_not_panic() {
        let buf = [1u8, 2, 3];
        assert!(PaneData::decode(&buf).is_err());
    }
}

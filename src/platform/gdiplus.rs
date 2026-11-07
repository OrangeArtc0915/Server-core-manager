//! GDI+ 动态加载：把背景图片解码成像素（零依赖、Server Core 优先）。
//!
//! `gdiplus.dll` 用 `LoadLibraryW` + `GetProcAddress` 现场绑定：
//! 精简版 Server Core 没有这个库时整块功能自动禁用，不影响终端启动。

use std::ffi::c_void;
use std::path::Path;
use std::sync::OnceLock;

use super::win32::{wide, GetProcAddress, LoadLibraryW};

#[repr(C)]
#[derive(Default)]
struct StartupInput {
    version: u32,
    callback: *mut c_void,
    suppress_background_thread: i32,
    suppress_external_codecs: i32,
}

#[repr(C)]
#[derive(Default)]
struct GpRect {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

#[repr(C)]
#[derive(Default)]
struct BitmapData {
    width: u32,
    height: u32,
    stride: i32,
    pixel_format: u32,
    scan0: *mut u8,
    reserved: usize,
}

type Status = i32;
type StartupFn = unsafe extern "system" fn(*mut usize, *mut StartupInput, *mut c_void) -> Status;
type CreateFromFileFn = unsafe extern "system" fn(*const u16, *mut *mut c_void) -> Status;
type GetSizeFn = unsafe extern "system" fn(*mut c_void, *mut u32) -> Status;
type LockBitsFn =
    unsafe extern "system" fn(*mut c_void, *const GpRect, i32, i32, *mut BitmapData) -> Status;
type UnlockBitsFn = unsafe extern "system" fn(*mut c_void, *mut BitmapData) -> Status;
type DisposeFn = unsafe extern "system" fn(*mut c_void) -> Status;

/// 绑定到的 GDI+ 函数表；`None` 表示这台机器没有 gdiplus.dll。
struct Api {
    create_from_file: CreateFromFileFn,
    get_width: GetSizeFn,
    get_height: GetSizeFn,
    lock_bits: LockBitsFn,
    unlock_bits: UnlockBitsFn,
    dispose_image: DisposeFn,
}

const IMAGE_LOCK_READ: i32 = 1;
const PIXEL_FORMAT_32BPP_ARGB: i32 = 0x0026_200A;

static API: OnceLock<Option<Api>> = OnceLock::new();

fn api() -> Option<&'static Api> {
    API.get_or_init(|| unsafe {
        let module = LoadLibraryW(wide("gdiplus.dll").as_ptr());
        if module.is_null() {
            return None;
        }
        let startup: StartupFn = resolve(module, "GdiplusStartup")?;
        let create_from_file: CreateFromFileFn =
            resolve(module, "GdipCreateBitmapFromFile")?;
        let get_width: GetSizeFn = resolve(module, "GdipGetImageWidth")?;
        let get_height: GetSizeFn = resolve(module, "GdipGetImageHeight")?;
        let lock_bits: LockBitsFn = resolve(module, "GdipBitmapLockBits")?;
        let unlock_bits: UnlockBitsFn = resolve(module, "GdipBitmapUnlockBits")?;
        let dispose_image: DisposeFn = resolve(module, "GdipDisposeImage")?;

        let mut token = 0usize;
        let mut input = StartupInput {
            version: 1,
            ..Default::default()
        };
        if startup(&mut token, &mut input, std::ptr::null_mut()) != 0 {
            return None;
        }
        Some(Api {
            create_from_file,
            get_width,
            get_height,
            lock_bits,
            unlock_bits,
            dispose_image,
        })
    })
    .as_ref()
}

unsafe fn resolve<T: Copy>(module: *mut c_void, name: &str) -> Option<T> {
    let ptr = GetProcAddress(module, wide(name).as_ptr());
    if ptr.is_null() {
        return None;
    }
    Some(std::mem::transmute_copy(&ptr))
}

/// 解码后的图片：RGBA8，行优先。
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

impl Image {
    /// 取某个像素的 RGBA（越界时返回全透明）。
    pub fn pixel(&self, x: usize, y: usize) -> (u8, u8, u8, u8) {
        if x >= self.width || y >= self.height {
            return (0, 0, 0, 0);
        }
        let index = (y * self.width + x) * 4;
        (
            self.pixels[index],
            self.pixels[index + 1],
            self.pixels[index + 2],
            self.pixels[index + 3],
        )
    }
}

/// 这台机器上 GDI+ 是否可用（设置页显示提示用）。
pub fn available() -> bool {
    api().is_some()
}

/// 读取图片文件；失败（文件不存在、格式不支持、无 GDI+）返回 `None`。
pub fn load(path: &Path) -> Option<Image> {
    let api = api()?;
    let name = wide(&path.to_string_lossy());
    unsafe {
        let mut bitmap: *mut c_void = std::ptr::null_mut();
        if (api.create_from_file)(name.as_ptr(), &mut bitmap) != 0 || bitmap.is_null() {
            return None;
        }
        let mut width = 0u32;
        let mut height = 0u32;
        let (width_ok, height_ok) = (
            (api.get_width)(bitmap, &mut width),
            (api.get_height)(bitmap, &mut height),
        );
        if width_ok != 0 || height_ok != 0 || width == 0 || height == 0 {
            (api.dispose_image)(bitmap);
            return None;
        }

        let rect = GpRect {
            x: 0,
            y: 0,
            width: width as i32,
            height: height as i32,
        };
        let mut data = BitmapData::default();
        if (api.lock_bits)(
            bitmap,
            &rect,
            IMAGE_LOCK_READ,
            PIXEL_FORMAT_32BPP_ARGB,
            &mut data,
        ) != 0
            || data.scan0.is_null()
        {
            (api.dispose_image)(bitmap);
            return None;
        }

        let (w, h) = (width as usize, height as usize);
        let stride = data.stride.unsigned_abs() as usize;
        let mut pixels = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let src = data.scan0.add(y * stride + x * 4);
                pixels.push(*src.add(2));
                pixels.push(*src.add(1));
                pixels.push(*src.add(0));
                pixels.push(*src.add(3));
            }
        }
        (api.unlock_bits)(bitmap, &mut data);
        (api.dispose_image)(bitmap);
        Some(Image {
            width: w,
            height: h,
            pixels,
        })
    }
}

/// 铺满 `cols × rows` 的单元格网格（cover + 居中裁切），返回每个格子的颜色。
///
/// 单元格不是正方形（约 1:2），所以按「列 1 单位、行 2 单位」的虚拟画布换算，
/// 保证图片不被拉伸变形，超出部分居中裁掉。
pub fn cover_cells(image: &Image, cols: usize, rows: usize) -> Vec<(u8, u8, u8)> {
    let mut out = vec![(0u8, 0u8, 0u8); cols * rows.max(1)];
    if image.width == 0 || image.height == 0 || cols == 0 || rows == 0 {
        return out;
    }
    let grid_w = cols as f32;
    let grid_h = (rows * 2) as f32;
    let scale = (grid_w / image.width as f32).max(grid_h / image.height as f32);
    let drawn_w = image.width as f32 * scale;
    let drawn_h = image.height as f32 * scale;
    let offset_x = (grid_w - drawn_w) / 2.0;
    let offset_y = (grid_h - drawn_h) / 2.0;
    for y in 0..rows {
        for x in 0..cols {
            let px = ((x as f32 + 0.5 - offset_x) / scale).floor();
            let py = (((y * 2) as f32 + 1.0 - offset_y) / scale).floor();
            if px < 0.0 || py < 0.0 || px >= image.width as f32 || py >= image.height as f32 {
                continue;
            }
            let (r, g, b, _) = image.pixel(px as usize, py as usize);
            out[y * cols + x] = (r, g, b);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(width: usize, height: usize, rgba: (u8, u8, u8, u8)) -> Image {
        let mut pixels = Vec::new();
        for _ in 0..width * height {
            pixels.extend_from_slice(&[rgba.0, rgba.1, rgba.2, rgba.3]);
        }
        Image {
            width,
            height,
            pixels,
        }
    }

    #[test]
    fn cover_cells_fills_every_cell() {
        let image = solid(4, 4, (10, 20, 30, 255));
        let cells = cover_cells(&image, 6, 3);
        assert_eq!(cells.len(), 18);
        assert!(cells.iter().all(|c| *c == (10, 20, 30)));
    }

    #[test]
    fn cover_cells_centers_and_crops() {
        // 宽图（8×2）铺 4×3 网格：横向被裁切，中间列取到左半的深色、右半的浅色。
        let mut image = solid(8, 2, (0, 0, 0, 255));
        for y in 0..2 {
            for x in 0..8 {
                let index = (y * 8 + x) * 4;
                let value = if x < 4 { 0 } else { 200 };
                image.pixels[index] = value;
                image.pixels[index + 1] = value;
                image.pixels[index + 2] = value;
            }
        }
        let cells = cover_cells(&image, 4, 3);
        // 网格高 6 单位、图高 2 像素 → 放大 3 倍，宽变成 24 单位，两侧各裁掉 10 单位：
        // 左边两列落在图片之外，右边两列才取到图右半的浅色。
        assert_eq!(cells[0], (0, 0, 0));
        assert_eq!(cells[1], (0, 0, 0));
        assert_eq!(cells[2], (200, 200, 200));
        assert_eq!(cells[3], (200, 200, 200));
    }

    #[test]
    fn empty_image_yields_black() {
        let image = solid(1, 1, (0, 0, 0, 0));
        let cells = cover_cells(&image, 2, 2);
        assert_eq!(cells.len(), 4);
    }

    /// 现场写一个 2×2 的 BMP 再读回来，验证 LoadLibraryW / GetProcAddress
    /// 绑定到的 GDI+ 函数签名与结构体布局都对得上。
    #[test]
    fn loads_bmp_file_when_gdiplus_available() {
        if !available() {
            return; // Server Core 精简版可能没有 gdiplus.dll
        }
        let dir = std::env::temp_dir().join("scterm-gdiplus-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("dot.bmp");

        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"BM");
        bytes.extend_from_slice(&(54u32 + 16).to_le_bytes()); // 文件大小
        bytes.extend_from_slice(&0u32.to_le_bytes()); // 保留
        bytes.extend_from_slice(&54u32.to_le_bytes()); // 像素数据偏移
        bytes.extend_from_slice(&40u32.to_le_bytes()); // 信息头大小
        bytes.extend_from_slice(&2i32.to_le_bytes()); // 宽
        bytes.extend_from_slice(&2i32.to_le_bytes()); // 高（正数 = 自下而上）
        bytes.extend_from_slice(&1u16.to_le_bytes()); // 平面数
        bytes.extend_from_slice(&24u16.to_le_bytes()); // 位深
        bytes.extend_from_slice(&0u32.to_le_bytes()); // 不压缩
        bytes.extend_from_slice(&16u32.to_le_bytes()); // 像素数据大小
        for _ in 0..4 {
            bytes.extend_from_slice(&0u32.to_le_bytes()); // 分辨率与调色板字段
        }
        // 底行：左蓝(255,0,0) 右绿(0,255,0)，行尾补齐到 4 字节
        bytes.extend_from_slice(&[255, 0, 0, 0, 255, 0, 0, 0]);
        // 顶行：左红(0,0,255) 右白(255,255,255)
        bytes.extend_from_slice(&[0, 0, 255, 255, 255, 255, 0, 0]);
        std::fs::write(&path, &bytes).expect("写入测试 BMP 失败");

        let image = load(&path).expect("应能解码 BMP");
        assert_eq!((image.width, image.height), (2, 2));
        assert_eq!(image.pixel(0, 0), (255, 0, 0, 255), "左上应为红色");
        assert_eq!(image.pixel(0, 1), (0, 0, 255, 255), "左下应为蓝色");
        let _ = std::fs::remove_file(&path);
    }
}

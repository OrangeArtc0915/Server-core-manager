//! 图片解码：动态加载系统 GDI+（零第三方依赖），支持 PNG/JPEG/GIF/BMP/TIFF。

use std::ffi::c_void;
use std::path::{Path, PathBuf};

use crate::platform::win32;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ImageKind {
    Png,
    Jpeg,
    Gif,
    Bmp,
    Tiff,
    Icon,
}

impl ImageKind {
    pub fn from_path(path: &Path) -> Option<ImageKind> {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        match ext.as_str() {
            "png" => Some(ImageKind::Png),
            "jpg" | "jpeg" => Some(ImageKind::Jpeg),
            "gif" => Some(ImageKind::Gif),
            "bmp" | "dib" => Some(ImageKind::Bmp),
            "tif" | "tiff" => Some(ImageKind::Tiff),
            "ico" => Some(ImageKind::Icon),
            _ => None,
        }
    }
}

pub struct Image {
    pub path: PathBuf,
    pub width: usize,
    pub height: usize,
    /// RGBA8，行优先。
    pub pixels: Vec<u8>,
}

#[repr(C)]
struct GdiplusStartupInput {
    gdiplus_version: u32,
    debug_event_callback: usize,
    suppress_background_thread: i32,
    suppress_external_codecs: i32,
}

#[repr(C)]
struct GpRect {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

#[repr(C)]
struct BitmapData {
    width: u32,
    height: u32,
    stride: i32,
    pixel_format: i32,
    scan0: *mut u8,
    reserved: usize,
}

type StartupFn = unsafe extern "system" fn(*mut usize, *const GdiplusStartupInput, *mut c_void) -> i32;
type ShutdownFn = unsafe extern "system" fn(usize);
type CreateBitmapFn = unsafe extern "system" fn(*const u16, *mut *mut c_void) -> i32;
type GetWidthFn = unsafe extern "system" fn(*mut c_void, *mut u32) -> i32;
type GetHeightFn = unsafe extern "system" fn(*mut c_void, *mut u32) -> i32;
type LockBitsFn = unsafe extern "system" fn(*mut c_void, *const GpRect, u32, i32, *mut BitmapData) -> i32;
type UnlockBitsFn = unsafe extern "system" fn(*mut c_void, *mut BitmapData) -> i32;
type DisposeImageFn = unsafe extern "system" fn(*mut c_void) -> i32;

struct Api {
    library: win32::HMODULE,
    startup: StartupFn,
    shutdown: ShutdownFn,
    create_bitmap: CreateBitmapFn,
    get_width: GetWidthFn,
    get_height: GetHeightFn,
    lock_bits: LockBitsFn,
    unlock_bits: UnlockBitsFn,
    dispose_image: DisposeImageFn,
}

impl Api {
    unsafe fn load() -> Option<Api> {
        let name = win32::wide("gdiplus.dll");
        let library = win32::LoadLibraryW(name.as_ptr());
        if library.is_null() {
            return None;
        }
        let get = |name: &str| -> *mut c_void {
            // GetProcAddress 接收 ANSI 名称（LPCSTR），不能传 UTF-16。
            let mut bytes = name.as_bytes().to_vec();
            bytes.push(0);
            win32::GetProcAddress(library, bytes.as_ptr())
        };
        let startup = get("GdiplusStartup");
        let shutdown = get("GdiplusShutdown");
        let create_bitmap = get("GdipCreateBitmapFromFile");
        let get_width = get("GdipGetImageWidth");
        let get_height = get("GdipGetImageHeight");
        let lock_bits = get("GdipBitmapLockBits");
        let unlock_bits = get("GdipBitmapUnlockBits");
        let dispose_image = get("GdipDisposeImage");
        if startup.is_null()
            || shutdown.is_null()
            || create_bitmap.is_null()
            || get_width.is_null()
            || get_height.is_null()
            || lock_bits.is_null()
            || unlock_bits.is_null()
            || dispose_image.is_null()
        {
            win32::FreeLibrary(library);
            return None;
        }
        Some(Api {
            library,
            startup: std::mem::transmute::<*mut c_void, StartupFn>(startup),
            shutdown: std::mem::transmute::<*mut c_void, ShutdownFn>(shutdown),
            create_bitmap: std::mem::transmute::<*mut c_void, CreateBitmapFn>(create_bitmap),
            get_width: std::mem::transmute::<*mut c_void, GetWidthFn>(get_width),
            get_height: std::mem::transmute::<*mut c_void, GetHeightFn>(get_height),
            lock_bits: std::mem::transmute::<*mut c_void, LockBitsFn>(lock_bits),
            unlock_bits: std::mem::transmute::<*mut c_void, UnlockBitsFn>(unlock_bits),
            dispose_image: std::mem::transmute::<*mut c_void, DisposeImageFn>(dispose_image),
        })
    }
}

impl Drop for Api {
    fn drop(&mut self) {
        unsafe {
            win32::FreeLibrary(self.library);
        }
    }
}

impl Image {
    pub fn load(path: &Path, _kind: ImageKind) -> Result<Image, String> {
        let api = unsafe { Api::load() }.ok_or_else(|| "系统缺少 gdiplus.dll，无法解码图片".to_string())?;
        unsafe {
            let mut token = 0usize;
            let input = GdiplusStartupInput {
                gdiplus_version: 1,
                debug_event_callback: 0,
                suppress_background_thread: 0,
                suppress_external_codecs: 0,
            };
            if (api.startup)(&mut token, &input, std::ptr::null_mut()) != 0 {
                return Err("GDI+ 初始化失败".into());
            }
            let result = Self::decode(&api, path);
            (api.shutdown)(token);
            result
        }
    }

    unsafe fn decode(api: &Api, path: &Path) -> Result<Image, String> {
        let wide = win32::wide(&path.to_string_lossy());
        let mut bitmap: *mut c_void = std::ptr::null_mut();
        let status = (api.create_bitmap)(wide.as_ptr(), &mut bitmap);
        if status != 0 || bitmap.is_null() {
            return Err(format!("无法解码图片（GDI+ 状态 {status}）：{}", path.display()));
        }
        let mut width = 0u32;
        let mut height = 0u32;
        (api.get_width)(bitmap, &mut width);
        (api.get_height)(bitmap, &mut height);
        if width == 0 || height == 0 {
            (api.dispose_image)(bitmap);
            return Err("图片尺寸为 0".into());
        }
        let rect = GpRect {
            x: 0,
            y: 0,
            width: width as i32,
            height: height as i32,
        };
        let mut data = BitmapData {
            width: 0,
            height: 0,
            stride: 0,
            pixel_format: 0,
            scan0: std::ptr::null_mut(),
            reserved: 0,
        };
        // ImageLockModeRead = 1，PixelFormat32bppARGB = 0x0026200A
        let status = (api.lock_bits)(bitmap, &rect, 1, 0x0026200A, &mut data);
        if status != 0 || data.scan0.is_null() {
            (api.dispose_image)(bitmap);
            return Err(format!("锁定图片像素失败（状态 {status}）"));
        }
        let stride = data.stride.unsigned_abs() as usize;
        let mut pixels = Vec::with_capacity(width as usize * height as usize * 4);
        for y in 0..height as usize {
            let row = data.scan0.add(y * stride);
            for x in 0..width as usize {
                let pixel = row.add(x * 4);
                // GDI+ 的 32bppARGB 在内存中是 BGRA
                let b = *pixel;
                let g = *pixel.add(1);
                let r = *pixel.add(2);
                let a = *pixel.add(3);
                if a == 0 {
                    pixels.extend_from_slice(&[255, 255, 255, 255]);
                } else {
                    pixels.extend_from_slice(&[r, g, b, a]);
                }
            }
        }
        (api.unlock_bits)(bitmap, &mut data);
        (api.dispose_image)(bitmap);

        Ok(Image {
            path: path.to_path_buf(),
            width: width as usize,
            height: height as usize,
            pixels,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_image_extensions() {
        assert_eq!(
            ImageKind::from_path(Path::new("a.PNG")),
            Some(ImageKind::Png)
        );
        assert_eq!(
            ImageKind::from_path(Path::new("a.jpeg")),
            Some(ImageKind::Jpeg)
        );
        assert_eq!(ImageKind::from_path(Path::new("a.txt")), None);
    }
}

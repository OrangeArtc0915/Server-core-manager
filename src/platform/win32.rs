//! 手写 Win32 FFI：不依赖任何第三方 crate，直接调用系统 DLL。
//!
//! 只声明本项目真正用到的函数与结构体，命名保持与 Windows SDK 一致，
//! 以便对照官方文档核对参数。

#![allow(non_snake_case, non_camel_case_types, dead_code)]

use std::ffi::c_void;

pub type HANDLE = *mut c_void;
pub type HWND = *mut c_void;
pub type HINSTANCE = *mut c_void;
pub type HMODULE = *mut c_void;
pub type HDC = *mut c_void;
pub type HBITMAP = *mut c_void;
pub type HGDIOBJ = *mut c_void;
pub type HBRUSH = *mut c_void;
pub type HPEN = *mut c_void;
pub type HMENU = *mut c_void;
pub type HCURSOR = *mut c_void;
pub type HICON = *mut c_void;
pub type HRGN = *mut c_void;
pub type FARPROC = *mut c_void;
pub type BOOL = i32;
pub type BYTE = u8;
pub type WORD = u16;
pub type DWORD = u32;
pub type LONG = i32;
pub type ULONG = u32;
pub type UINT = u32;
pub type WPARAM = usize;
pub type LPARAM = isize;
pub type LRESULT = isize;
pub type ATOM = u16;
pub type COLORREF = u32;
pub type UINT_PTR = usize;
pub type WCHAR = u16;

pub const STD_INPUT_HANDLE: DWORD = 0xFFFF_FFF6;
pub const STD_OUTPUT_HANDLE: DWORD = 0xFFFF_FFF5;
pub const STD_ERROR_HANDLE: DWORD = 0xFFFF_FFF4;

// ---------------------------------------------------------------- 控制台

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct COORD {
    pub X: i16,
    pub Y: i16,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SMALL_RECT {
    pub Left: i16,
    pub Top: i16,
    pub Right: i16,
    pub Bottom: i16,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct CONSOLE_SCREEN_BUFFER_INFO {
    pub dwSize: COORD,
    pub dwCursorPosition: COORD,
    pub wAttributes: WORD,
    pub srWindow: SMALL_RECT,
    pub dwMaximumWindowSize: COORD,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct CONSOLE_CURSOR_INFO {
    pub dwSize: DWORD,
    pub bVisible: BOOL,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct KEY_EVENT_RECORD {
    pub bKeyDown: BOOL,
    pub wRepeatCount: WORD,
    pub wVirtualKeyCode: WORD,
    pub wVirtualScanCode: WORD,
    pub uChar: WCHAR,
    pub dwControlKeyState: DWORD,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MOUSE_EVENT_RECORD {
    pub dwMousePosition: COORD,
    pub dwButtonState: DWORD,
    pub dwControlKeyState: DWORD,
    pub dwEventFlags: DWORD,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct WINDOW_BUFFER_SIZE_RECORD {
    pub dwSize: COORD,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MENU_EVENT_RECORD {
    pub dwCommandId: UINT,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct FOCUS_EVENT_RECORD {
    pub bSetFocus: BOOL,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union INPUT_EVENT {
    pub KeyEvent: KEY_EVENT_RECORD,
    pub MouseEvent: MOUSE_EVENT_RECORD,
    pub WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
    pub MenuEvent: MENU_EVENT_RECORD,
    pub FocusEvent: FOCUS_EVENT_RECORD,
}

impl Default for INPUT_EVENT {
    fn default() -> Self {
        INPUT_EVENT {
            MenuEvent: MENU_EVENT_RECORD::default(),
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct INPUT_RECORD {
    pub EventType: WORD,
    pub Event: INPUT_EVENT,
}

pub const KEY_EVENT: WORD = 0x0001;
pub const MOUSE_EVENT: WORD = 0x0002;
pub const WINDOW_BUFFER_SIZE_EVENT: WORD = 0x0004;
pub const MENU_EVENT: WORD = 0x0008;
pub const FOCUS_EVENT: WORD = 0x0010;

// 输入模式
pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
pub const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
pub const ENABLE_INSERT_MODE: DWORD = 0x0020;
pub const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
pub const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
// 输出模式
pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_WRAP_AT_EOL_OUTPUT: DWORD = 0x0002;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
pub const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;

// 虚拟键
pub const VK_BACK: u16 = 0x08;
pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_PAUSE: u16 = 0x13;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_SPACE: u16 = 0x20;
pub const VK_PRIOR: u16 = 0x21;
pub const VK_NEXT: u16 = 0x22;
pub const VK_END: u16 = 0x23;
pub const VK_HOME: u16 = 0x24;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_INSERT: u16 = 0x2D;
pub const VK_DELETE: u16 = 0x2E;
pub const VK_F1: u16 = 0x70;
pub const VK_F24: u16 = 0x87;
pub const VK_OEM_1: u16 = 0xBA;
pub const VK_OEM_PLUS: u16 = 0xBB;
pub const VK_OEM_COMMA: u16 = 0xBC;
pub const VK_OEM_MINUS: u16 = 0xBD;
pub const VK_OEM_PERIOD: u16 = 0xBE;
pub const VK_OEM_2: u16 = 0xBF;
pub const VK_OEM_3: u16 = 0xC0;
pub const VK_OEM_4: u16 = 0xDB;
pub const VK_OEM_5: u16 = 0xDC;
pub const VK_OEM_6: u16 = 0xDD;
pub const VK_OEM_7: u16 = 0xDE;
pub const VK_OEM_102: u16 = 0xE2;

// 控制键状态
pub const RIGHT_ALT_PRESSED: DWORD = 0x0001;
pub const LEFT_ALT_PRESSED: DWORD = 0x0002;
pub const RIGHT_CTRL_PRESSED: DWORD = 0x0004;
pub const LEFT_CTRL_PRESSED: DWORD = 0x0008;
pub const SHIFT_PRESSED: DWORD = 0x0010;
pub const CAPSLOCK_ON: DWORD = 0x0080;
pub const ENHANCED_KEY: DWORD = 0x0100;

// 鼠标
pub const FROM_LEFT_1ST_BUTTON_PRESSED: DWORD = 0x0001;
pub const RIGHTMOST_BUTTON_PRESSED: DWORD = 0x0002;
pub const FROM_LEFT_2ND_BUTTON_PRESSED: DWORD = 0x0004;
pub const MOUSE_MOVED: DWORD = 0x0001;
pub const DOUBLE_CLICK: DWORD = 0x0002;
pub const MOUSE_WHEELED: DWORD = 0x0004;
pub const MOUSE_HWHEELED: DWORD = 0x0008;

// 控制台代码页
pub const CP_ACP: UINT = 0;
pub const CP_OEMCP: UINT = 1;
pub const CP_UTF8: UINT = 65001;
pub const CP_GBK: UINT = 936;
pub const CP_GB18030: UINT = 54936;
pub const MB_ERR_INVALID_CHARS: DWORD = 0x00000008;

// ---------------------------------------------------------------- 剪贴板

pub const CF_TEXT: UINT = 1;
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

// ---------------------------------------------------------------- user32

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct POINT {
    pub x: i32,
    pub y: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct RECT {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MSG {
    pub hwnd: HWND,
    pub message: UINT,
    pub wParam: WPARAM,
    pub lParam: LPARAM,
    pub time: DWORD,
    pub pt: POINT,
}

#[link(name = "kernel32")]
extern "system" {
    pub fn GetStdHandle(nStdHandle: DWORD) -> HANDLE;
    pub fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *mut DWORD) -> BOOL;
    pub fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) -> BOOL;
    pub fn GetConsoleScreenBufferInfo(
        hConsoleOutput: HANDLE,
        lpConsoleScreenBufferInfo: *mut CONSOLE_SCREEN_BUFFER_INFO,
    ) -> BOOL;
    pub fn SetConsoleScreenBufferSize(hConsoleOutput: HANDLE, dwSize: COORD) -> BOOL;
    pub fn SetConsoleCursorPosition(hConsoleOutput: HANDLE, dwCursorPosition: COORD) -> BOOL;
    pub fn SetConsoleCursorInfo(
        hConsoleOutput: HANDLE,
        lpConsoleCursorInfo: *const CONSOLE_CURSOR_INFO,
    ) -> BOOL;
    pub fn WriteConsoleW(
        hConsoleOutput: HANDLE,
        lpBuffer: *const WCHAR,
        nNumberOfCharsToWrite: DWORD,
        lpNumberOfCharsWritten: *mut DWORD,
        lpReserved: *mut c_void,
    ) -> BOOL;
    pub fn ReadConsoleInputW(
        hConsoleInput: HANDLE,
        lpBuffer: *mut INPUT_RECORD,
        nLength: DWORD,
        lpNumberOfEventsRead: *mut DWORD,
    ) -> BOOL;
    pub fn GetNumberOfConsoleInputEvents(hConsoleInput: HANDLE, lpNumberOfEvents: *mut DWORD)
        -> BOOL;
    pub fn SetConsoleTitleW(lpConsoleTitle: *const WCHAR) -> BOOL;
    pub fn GetConsoleWindow() -> HWND;
    pub fn AllocConsole() -> BOOL;
    pub fn FreeConsole() -> BOOL;
    pub fn AttachConsole(dwProcessId: DWORD) -> BOOL;
    pub fn SetConsoleCP(wCodePageID: UINT) -> BOOL;
    pub fn SetConsoleOutputCP(wCodePageID: UINT) -> BOOL;
    pub fn GetACP() -> UINT;
    pub fn GetOEMCP() -> UINT;
    pub fn WideCharToMultiByte(
        CodePage: UINT,
        dwFlags: DWORD,
        lpWideCharStr: *const WCHAR,
        cchWideChar: i32,
        lpMultiByteStr: *mut BYTE,
        cbMultiByte: i32,
        lpDefaultChar: *const BYTE,
        lpUsedDefaultChar: *mut BOOL,
    ) -> i32;
    pub fn MultiByteToWideChar(
        CodePage: UINT,
        dwFlags: DWORD,
        lpMultiByteStr: *const BYTE,
        cbMultiByte: i32,
        lpWideCharStr: *mut WCHAR,
        cchWideChar: i32,
    ) -> i32;
    pub fn GetLastError() -> DWORD;
    pub fn GetTickCount64() -> u64;
    pub fn GetEnvironmentVariableW(
        lpName: *const WCHAR,
        lpBuffer: *mut WCHAR,
        nSize: DWORD,
    ) -> DWORD;
    pub fn GetCurrentDirectoryW(nBufferLength: DWORD, lpBuffer: *mut WCHAR) -> DWORD;
    pub fn SetCurrentDirectoryW(lpPathName: *const WCHAR) -> BOOL;
    pub fn Beep(dwFreq: DWORD, dwDuration: DWORD) -> BOOL;
    pub fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) -> DWORD;
    pub fn CloseHandle(hObject: HANDLE) -> BOOL;
    pub fn LoadLibraryW(lpLibFileName: *const WCHAR) -> HMODULE;
    pub fn GetProcAddress(hModule: HMODULE, lpProcName: *const BYTE) -> FARPROC;
    pub fn FreeLibrary(hLibModule: HMODULE) -> BOOL;
    pub fn GetModuleHandleW(lpModuleName: *const WCHAR) -> HMODULE;
    pub fn CreateMutexW(
        lpMutexAttributes: *const SECURITY_ATTRIBUTES,
        bInitialOwner: BOOL,
        lpName: *const WCHAR,
    ) -> HANDLE;
    pub fn ReleaseMutex(hMutex: HANDLE) -> BOOL;
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SECURITY_ATTRIBUTES {
    pub nLength: DWORD,
    pub lpSecurityDescriptor: *mut c_void,
    pub bInheritHandle: BOOL,
}

#[link(name = "user32")]
extern "system" {
    pub fn OpenClipboard(hWndNewOwner: HWND) -> BOOL;
    pub fn CloseClipboard() -> BOOL;
    pub fn EmptyClipboard() -> BOOL;
    pub fn IsClipboardFormatAvailable(format: UINT) -> BOOL;
    pub fn GetClipboardData(uFormat: UINT) -> HANDLE;
    pub fn SetClipboardData(uFormat: UINT, hMem: HANDLE) -> HANDLE;
    pub fn RegisterClipboardFormatW(lpszFormat: *const WCHAR) -> UINT;
    pub fn GetClipboardSequenceNumber() -> DWORD;
    pub fn MessageBoxW(
        hWnd: HWND,
        lpText: *const WCHAR,
        lpCaption: *const WCHAR,
        uType: UINT,
    ) -> i32;
    pub fn GetKeyState(nVirtKey: i32) -> i16;
    pub fn SetWindowTextW(hWnd: HWND, lpString: *const WCHAR) -> BOOL;
    pub fn GetSystemMetrics(nIndex: i32) -> i32;
    pub fn MessageBeep(uType: UINT) -> BOOL;
}

#[link(name = "shell32")]
extern "system" {
    pub fn ShellExecuteW(
        hwnd: HWND,
        lpOperation: *const WCHAR,
        lpFile: *const WCHAR,
        lpParameters: *const WCHAR,
        lpDirectory: *const WCHAR,
        nShowCmd: i32,
    ) -> HINSTANCE;
}

#[link(name = "advapi32")]
extern "system" {
    pub fn RegGetValueW(
        hkey: HANDLE,
        lpSubKey: *const WCHAR,
        lpValue: *const WCHAR,
        dwFlags: DWORD,
        pdwType: *mut DWORD,
        pvData: *mut c_void,
        pcbData: *mut DWORD,
    ) -> LONG;
}

// ---------------------------------------------------------------- 内存

#[link(name = "kernel32")]
extern "system" {
    pub fn GlobalAlloc(uFlags: UINT, dwBytes: usize) -> HANDLE;
    pub fn GlobalFree(hMem: HANDLE) -> HANDLE;
    pub fn GlobalLock(hMem: HANDLE) -> *mut c_void;
    pub fn GlobalUnlock(hMem: HANDLE) -> BOOL;
    pub fn GlobalSize(hMem: HANDLE) -> usize;
}

// ---------------------------------------------------------------- 工具函数

/// UTF-16 以 NUL 结尾，供 `*W` 接口使用。
pub fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 读取环境变量（UTF-8 字符串）。
pub fn env(name: &str) -> Option<String> {
    let name = wide(name);
    let mut buf = vec![0u16; 32768];
    let len = unsafe { GetEnvironmentVariableW(name.as_ptr(), buf.as_mut_ptr(), buf.len() as u32) };
    if len == 0 {
        return None;
    }
    buf.truncate(len as usize);
    Some(String::from_utf16_lossy(&buf))
}

/// UTF-16 切片转 String。
pub fn from_wide(buf: &[u16]) -> String {
    String::from_utf16_lossy(buf)
}

/// 系统 ANSI 代码页（中文系统为 936）。
pub fn ansi_codepage() -> u32 {
    unsafe { GetACP() }
}

/// 用指定代码页把宽字符串编码为字节；失败返回 `None`（严格模式）。
pub fn encode_codepage(code_page: u32, text: &str, strict: bool) -> Option<Vec<u8>> {
    let utf16: Vec<u16> = text.encode_utf16().collect();
    let flags = if strict { MB_ERR_INVALID_CHARS } else { 0 };
    let need = unsafe {
        WideCharToMultiByte(
            code_page,
            flags,
            utf16.as_ptr(),
            utf16.len() as i32,
            std::ptr::null_mut(),
            0,
            std::ptr::null(),
            std::ptr::null_mut(),
        )
    };
    if need <= 0 {
        return None;
    }
    let mut out = vec![0u8; need as usize];
    let written = unsafe {
        WideCharToMultiByte(
            code_page,
            flags,
            utf16.as_ptr(),
            utf16.len() as i32,
            out.as_mut_ptr(),
            need,
            std::ptr::null(),
            std::ptr::null_mut(),
        )
    };
    if written <= 0 || written != need {
        return None;
    }
    Some(out)
}

/// 用指定代码页解码字节；`strict` 时遇到非法字节返回 `None`。
pub fn decode_codepage(code_page: u32, bytes: &[u8], strict: bool) -> Option<String> {
    if bytes.is_empty() {
        return Some(String::new());
    }
    let flags = if strict { MB_ERR_INVALID_CHARS } else { 0 };
    let need = unsafe {
        MultiByteToWideChar(
            code_page,
            flags,
            bytes.as_ptr(),
            bytes.len() as i32,
            std::ptr::null_mut(),
            0,
        )
    };
    if need <= 0 {
        return None;
    }
    let mut out = vec![0u16; need as usize];
    let written = unsafe {
        MultiByteToWideChar(
            code_page,
            flags,
            bytes.as_ptr(),
            bytes.len() as i32,
            out.as_mut_ptr(),
            need,
        )
    };
    if written <= 0 {
        return None;
    }
    out.truncate(written as usize);
    Some(String::from_utf16_lossy(&out))
}

/// 控制台窗口是否真的存在（GUI 子系统下为 NULL）。
pub fn has_console() -> bool {
    unsafe { !GetConsoleWindow().is_null() }
}

// ---------------------------------------------------------------- 图形界面

pub type HFONT = *mut c_void;

pub type WndProc = unsafe extern "system" fn(HWND, UINT, WPARAM, LPARAM) -> LRESULT;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct WNDCLASSEXW {
    pub cbSize: UINT,
    pub style: UINT,
    pub lpfnWndProc: Option<WndProc>,
    pub cbClsExtra: i32,
    pub cbWndExtra: i32,
    pub hInstance: HINSTANCE,
    pub hIcon: HICON,
    pub hCursor: HCURSOR,
    pub hbrBackground: HBRUSH,
    pub lpszMenuName: *const u16,
    pub lpszClassName: *const u16,
    pub hIconSm: HICON,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct PAINTSTRUCT {
    pub hdc: HDC,
    pub fErase: BOOL,
    pub rcPaint: RECT,
    pub fRestore: BOOL,
    pub fIncUpdate: BOOL,
    pub rgbReserved: [u8; 32],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct TEXTMETRICW {
    pub tmHeight: i32,
    pub tmAscent: i32,
    pub tmDescent: i32,
    pub tmInternalLeading: i32,
    pub tmExternalLeading: i32,
    pub tmAveCharWidth: i32,
    pub tmMaxCharWidth: i32,
    pub tmWeight: i32,
    pub tmOverhang: i32,
    pub tmDigitizedAspectX: i32,
    pub tmDigitizedAspectY: i32,
    pub tmFirstChar: u16,
    pub tmLastChar: u16,
    pub tmDefaultChar: u16,
    pub tmBreakChar: u16,
    pub tmItalic: u8,
    pub tmUnderlined: u8,
    pub tmStruckOut: u8,
    pub tmPitchAndFamily: u8,
    pub tmCharSet: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SIZE {
    pub cx: i32,
    pub cy: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct RGBQUAD {
    pub rgbBlue: u8,
    pub rgbGreen: u8,
    pub rgbRed: u8,
    pub rgbReserved: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct BITMAPINFOHEADER {
    pub biSize: u32,
    pub biWidth: i32,
    pub biHeight: i32,
    pub biPlanes: u16,
    pub biBitCount: u16,
    pub biCompression: u32,
    pub biSizeImage: u32,
    pub biXPelsPerMeter: i32,
    pub biYPelsPerMeter: i32,
    pub biClrUsed: u32,
    pub biClrImportant: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct BITMAPINFO {
    pub bmiHeader: BITMAPINFOHEADER,
    pub bmiColors: [RGBQUAD; 1],
}

// 窗口消息
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_SETFOCUS: UINT = 0x0007;

pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_DBLCLKS: UINT = 0x0008;
pub const WS_OVERLAPPEDWINDOW: UINT = 0x00CF0000;
pub const CW_USEDEFAULT: i32 = -2147483648;
pub const SW_SHOW: i32 = 5;
pub const COLOR_WINDOW: usize = 5;
pub const IDC_ARROW: usize = 32512;
pub const GWLP_USERDATA: i32 = -21;
pub const GWL_STYLE: i32 = -16;

pub const TRANSPARENT: i32 = 1;
pub const OPAQUE: i32 = 2;
pub const ETO_OPAQUE: UINT = 0x0002;
pub const SRCCOPY: u32 = 0x00CC0020;
pub const DIB_RGB_COLORS: UINT = 0;
pub const BI_RGB: u32 = 0;
pub const ETO_CLIPPED: UINT = 0x0004;
pub const TA_LEFT: UINT = 0;
pub const TA_RIGHT: UINT = 2;
pub const TA_CENTER: UINT = 6;
pub const MK_LBUTTON: WPARAM = 0x0001;
pub const MK_RBUTTON: WPARAM = 0x0002;
pub const MK_MBUTTON: WPARAM = 0x0010;

pub const VK_SHIFT: i32 = 0x10;
pub const VK_CONTROL: i32 = 0x11;
pub const VK_MENU: i32 = 0x12;

#[link(name = "user32")]
extern "system" {
    pub fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) -> ATOM;
    pub fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: *const u16,
        lpWindowName: *const u16,
        dwStyle: DWORD,
        X: i32,
        Y: i32,
        nWidth: i32,
        nHeight: i32,
        hWndParent: HWND,
        hMenu: HMENU,
        hInstance: HINSTANCE,
        lpParam: *mut c_void,
    ) -> HWND;
    pub fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT;
    pub fn ShowWindow(hWnd: HWND, nCmdShow: i32) -> BOOL;
    pub fn UpdateWindow(hWnd: HWND) -> BOOL;
    pub fn DestroyWindow(hWnd: HWND) -> BOOL;
    pub fn GetMessageW(lpMsg: *mut MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT)
        -> BOOL;
    pub fn TranslateMessage(lpMsg: *const MSG) -> BOOL;
    pub fn DispatchMessageW(lpMsg: *const MSG) -> LRESULT;
    pub fn PostQuitMessage(nExitCode: i32);
    pub fn InvalidateRect(hWnd: HWND, lpRect: *const RECT, bErase: BOOL) -> BOOL;
    pub fn BeginPaint(hWnd: HWND, lpPaint: *mut PAINTSTRUCT) -> HDC;
    pub fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) -> BOOL;
    pub fn GetClientRect(hWnd: HWND, lpRect: *mut RECT) -> BOOL;
    pub fn GetDC(hWnd: HWND) -> HDC;
    pub fn ReleaseDC(hWnd: HWND, hDC: HDC) -> i32;
    pub fn LoadCursorW(hInstance: HINSTANCE, lpCursorName: *const u16) -> HCURSOR;
    pub fn SetTimer(hWnd: HWND, nIDEvent: UINT_PTR, uElapse: UINT, lpTimerFunc: *mut c_void)
        -> UINT_PTR;
    pub fn KillTimer(hWnd: HWND, uIDEvent: UINT_PTR) -> BOOL;
    pub fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) -> isize;
    pub fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) -> isize;
    pub fn SetCapture(hWnd: HWND) -> HWND;
    pub fn ReleaseCapture() -> BOOL;
    pub fn ScreenToClient(hWnd: HWND, lpPoint: *mut POINT) -> BOOL;
    pub fn SetProcessDPIAware() -> BOOL;
    pub fn SetForegroundWindow(hWnd: HWND) -> BOOL;
}

#[link(name = "gdi32")]
extern "system" {
    pub fn CreateFontW(
        cHeight: i32,
        cWidth: i32,
        cEscapement: i32,
        cOrientation: i32,
        cWeight: i32,
        bItalic: DWORD,
        bUnderline: DWORD,
        bStrikeOut: DWORD,
        iCharSet: DWORD,
        iOutPrecision: DWORD,
        iClipPrecision: DWORD,
        iQuality: DWORD,
        iPitchAndFamily: DWORD,
        pszFaceName: *const u16,
    ) -> HFONT;
    pub fn CreateCompatibleDC(hdc: HDC) -> HDC;
    pub fn CreateDIBSection(
        hdc: HDC,
        pbmi: *const BITMAPINFO,
        usage: UINT,
        ppvBits: *mut *mut c_void,
        hSection: HANDLE,
        offset: DWORD,
    ) -> HBITMAP;
    pub fn SelectObject(hdc: HDC, h: HGDIOBJ) -> HGDIOBJ;
    pub fn DeleteObject(h: HGDIOBJ) -> BOOL;
    pub fn DeleteDC(hdc: HDC) -> BOOL;
    pub fn BitBlt(
        hdcDest: HDC,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        hdcSrc: HDC,
        x1: i32,
        y1: i32,
        rop: u32,
    ) -> BOOL;
    pub fn StretchBlt(
        hdcDest: HDC,
        xDest: i32,
        yDest: i32,
        wDest: i32,
        hDest: i32,
        hdcSrc: HDC,
        xSrc: i32,
        ySrc: i32,
        wSrc: i32,
        hSrc: i32,
        rop: u32,
    ) -> BOOL;
    pub fn SetStretchBltMode(hdc: HDC, mode: i32) -> i32;
    pub fn SetBkMode(hdc: HDC, mode: i32) -> i32;
    pub fn SetBkColor(hdc: HDC, color: COLORREF) -> COLORREF;
    pub fn SetTextColor(hdc: HDC, color: COLORREF) -> COLORREF;
    pub fn ExtTextOutW(
        hdc: HDC,
        x: i32,
        y: i32,
        options: UINT,
        lprect: *const RECT,
        lpString: *const u16,
        c: i32,
        lpDx: *const i32,
    ) -> BOOL;
    pub fn GetTextMetricsW(hdc: HDC, lptm: *mut TEXTMETRICW) -> BOOL;
    pub fn GetTextExtentPoint32W(hdc: HDC, lpString: *const u16, c: i32, psizl: *mut SIZE) -> BOOL;
    pub fn FillRect(hdc: HDC, lprc: *const RECT, hbr: HBRUSH) -> i32;
    pub fn CreateSolidBrush(color: COLORREF) -> HBRUSH;
    pub fn GetStockObject(index: i32) -> HGDIOBJ;
    pub fn SaveDC(hdc: HDC) -> i32;
    pub fn RestoreDC(hdc: HDC, saved: i32) -> BOOL;
    pub fn IntersectClipRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32) -> i32;
    pub fn SetTextAlign(hdc: HDC, align: UINT) -> UINT;
}

/// COLORREF 是 0x00BBGGRR。
pub fn colorref(r: u8, g: u8, b: u8) -> COLORREF {
    (r as u32) | ((g as u32) << 8) | ((b as u32) << 16)
}


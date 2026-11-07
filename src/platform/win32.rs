//! 手写 Win32 FFI 声明（阶段 0 零依赖方案）。
//! 只声明 scterm 实际使用的 API，结构体布局与 Windows SDK 保持一致。

#![allow(non_snake_case, non_camel_case_types, dead_code)]

use std::ffi::c_void;

pub type BOOL = i32;
pub type DWORD = u32;
pub type WORD = u16;
pub type UINT = u32;
pub type HANDLE = *mut c_void;
pub type HPCON = *mut c_void;
pub type HRESULT = i32;
pub type NTSTATUS = i32;
pub type HLOCAL = *mut c_void;

pub const INVALID_HANDLE_VALUE: HANDLE = -1isize as HANDLE;

// ---------- 结构体 ----------

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
pub struct SECURITY_ATTRIBUTES {
    pub nLength: u32,
    pub lpSecurityDescriptor: *mut c_void,
    pub bInheritHandle: BOOL,
}

#[repr(C)]
#[derive(Default)]
pub struct STARTUPINFOW {
    pub cb: u32,
    pub lpReserved: *mut u16,
    pub lpDesktop: *mut u16,
    pub lpTitle: *mut u16,
    pub dwX: u32,
    pub dwY: u32,
    pub dwXSize: u32,
    pub dwYSize: u32,
    pub dwXCountChars: u32,
    pub dwYCountChars: u32,
    pub dwFillAttribute: u32,
    pub dwFlags: u32,
    pub wShowWindow: u16,
    pub cbReserved2: u16,
    pub lpReserved2: *mut u8,
    pub hStdInput: HANDLE,
    pub hStdOutput: HANDLE,
    pub hStdError: HANDLE,
}

#[repr(C)]
#[derive(Default)]
pub struct STARTUPINFOEXW {
    pub StartupInfo: STARTUPINFOW,
    pub lpAttributeList: *mut c_void,
}

#[repr(C)]
#[derive(Default)]
pub struct PROCESS_INFORMATION {
    pub hProcess: HANDLE,
    pub hThread: HANDLE,
    pub dwProcessId: u32,
    pub dwThreadId: u32,
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
pub struct SYSTEMTIME {
    pub wYear: WORD,
    pub wMonth: WORD,
    pub wDayOfWeek: WORD,
    pub wDay: WORD,
    pub wHour: WORD,
    pub wMinute: WORD,
    pub wSecond: WORD,
    pub wMilliseconds: WORD,
}

/// 控制台字体信息（CONSOLE_FONT_INFOEX）。
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CONSOLE_FONT_INFOEX {
    pub cbSize: u32,
    pub nFont: u32,
    pub dwFontSize: COORD,
    pub FontFamily: u32,
    pub FontWeight: u32,
    pub FaceName: [u16; 32],
}

impl Default for CONSOLE_FONT_INFOEX {
    fn default() -> Self {
        CONSOLE_FONT_INFOEX {
            cbSize: std::mem::size_of::<CONSOLE_FONT_INFOEX>() as u32,
            nFont: 0,
            dwFontSize: COORD { X: 0, Y: 0 },
            FontFamily: 0,
            FontWeight: 400,
            FaceName: [0; 32],
        }
    }
}

/// 屏幕坐标点（POINT）。
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct POINT {
    pub x: i32,
    pub y: i32,
}

/// 窗口消息（MSG）。
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MSG {
    pub hwnd: HANDLE,
    pub message: UINT,
    pub wParam: usize,
    pub lParam: isize,
    pub time: DWORD,
    pub pt: POINT,
    pub lPrivate: DWORD,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RTL_OSVERSIONINFOW {
    pub dwOSVersionInfoSize: u32,
    pub dwMajorVersion: u32,
    pub dwMinorVersion: u32,
    pub dwBuildNumber: u32,
    pub dwPlatformId: u32,
    pub szCSDVersion: [u16; 128],
}

#[repr(C)]
#[derive(Default)]
pub struct OVERLAPPED {
    pub Internal: usize,
    pub InternalHigh: usize,
    pub Offset: u32,
    pub OffsetHigh: u32,
    pub hEvent: HANDLE,
}

/// 控制台输入记录。`data` 是 16 字节的联合体，按事件类型解释：
/// - KEY_EVENT：`[bKeyDown, repeat|vk, scan|char, control_state]`
/// - WINDOW_BUFFER_SIZE_EVENT：`[coord]`
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct INPUT_RECORD {
    pub event_type: u16,
    pub _padding: u16,
    pub data: [u32; 4],
}

pub const KEY_EVENT: u16 = 0x0001;
pub const MOUSE_EVENT: u16 = 0x0002;
pub const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;

pub const RIGHT_ALT_PRESSED: u32 = 0x0001;
pub const LEFT_ALT_PRESSED: u32 = 0x0002;
pub const RIGHT_CTRL_PRESSED: u32 = 0x0004;
pub const LEFT_CTRL_PRESSED: u32 = 0x0008;
pub const SHIFT_PRESSED: u32 = 0x0010;

// ---------- 常量 ----------

pub const STD_INPUT_HANDLE: DWORD = -10i32 as DWORD;
pub const STD_OUTPUT_HANDLE: DWORD = -11i32 as DWORD;
pub const STD_ERROR_HANDLE: DWORD = -12i32 as DWORD;

pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
pub const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
pub const ENABLE_INSERT_MODE: DWORD = 0x0020;
pub const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
pub const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_WRAP_AT_EOL_OUTPUT: DWORD = 0x0002;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
pub const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;

pub const PIPE_ACCESS_DUPLEX: DWORD = 0x0000_0003;
pub const PIPE_ACCESS_INBOUND: DWORD = 0x0000_0001;
pub const PIPE_TYPE_BYTE: DWORD = 0x0000_0000;
pub const PIPE_READMODE_BYTE: DWORD = 0x0000_0000;
pub const PIPE_WAIT: DWORD = 0x0000_0000;
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x0000_0008;
pub const PIPE_UNLIMITED_INSTANCES: DWORD = 255;

pub const GENERIC_READ: DWORD = 0x8000_0000;
pub const GENERIC_WRITE: DWORD = 0x4000_0000;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x4000_0000;

pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x0008_0000;
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x0000_0400;
pub const DETACHED_PROCESS: DWORD = 0x0000_0008;
pub const CREATE_NEW_PROCESS_GROUP: DWORD = 0x0000_0200;

/// PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
/// = ProcThreadAttributeValue(ProcThreadAttributePseudoConsole(22), FALSE, TRUE, FALSE)
/// = 22 | PROC_THREAD_ATTRIBUTE_INPUT(0x00020000)
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x0002_0016;

pub const TOKEN_QUERY: DWORD = 0x0008;
pub const TOKEN_USER_CLASS: u32 = 1;
pub const SDDL_REVISION_1: DWORD = 1;

/// 剪贴板格式：UTF-16 文本。
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub const INFINITE: DWORD = 0xFFFF_FFFF;

pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_HANDLE_EOF: DWORD = 38;
pub const ERROR_BROKEN_PIPE: DWORD = 109;
pub const ERROR_ALREADY_EXISTS: DWORD = 183;
pub const ERROR_PIPE_BUSY: DWORD = 231;
pub const ERROR_OPERATION_ABORTED: DWORD = 995;
pub const ERROR_IO_PENDING: DWORD = 997;
pub const ERROR_PIPE_CONNECTED: DWORD = 535;
pub const ERROR_PIPE_NOT_CONNECTED: DWORD = 233;

// ---------- kernel32 ----------

#[link(name = "kernel32")]
extern "system" {
    pub fn GetLastError() -> DWORD;
    pub fn CloseHandle(h: HANDLE) -> BOOL;
    pub fn CreatePipe(read: *mut HANDLE, write: *mut HANDLE, sa: *const SECURITY_ATTRIBUTES, size: DWORD) -> BOOL;
    pub fn ReadFile(h: HANDLE, buf: *mut c_void, n: DWORD, read: *mut DWORD, ov: *mut c_void) -> BOOL;
    pub fn ReadConsoleInputW(
        h: HANDLE,
        records: *mut INPUT_RECORD,
        len: DWORD,
        read: *mut DWORD,
    ) -> BOOL;
    pub fn WriteFile(h: HANDLE, buf: *const c_void, n: DWORD, written: *mut DWORD, ov: *mut c_void) -> BOOL;
    pub fn GetStdHandle(kind: DWORD) -> HANDLE;
    pub fn SetStdHandle(kind: DWORD, h: HANDLE) -> BOOL;
    pub fn FreeConsole() -> BOOL;
    pub fn GetConsoleWindow() -> HANDLE;
    pub fn GetConsoleMode(h: HANDLE, mode: *mut DWORD) -> BOOL;
    pub fn SetConsoleMode(h: HANDLE, mode: DWORD) -> BOOL;
    pub fn GetConsoleScreenBufferInfo(h: HANDLE, info: *mut CONSOLE_SCREEN_BUFFER_INFO) -> BOOL;
    pub fn SetConsoleScreenBufferSize(h: HANDLE, size: COORD) -> BOOL;
    pub fn SetConsoleWindowInfo(h: HANDLE, absolute: BOOL, window: *const SMALL_RECT) -> BOOL;
    pub fn SetConsoleCP(cp: UINT) -> BOOL;
    pub fn SetConsoleOutputCP(cp: UINT) -> BOOL;
    pub fn SetConsoleTitleW(title: *const u16) -> BOOL;
    pub fn GetLocalTime(st: *mut SYSTEMTIME);
    pub fn GetVolumeInformationW(
        root: *const u16,
        volume_name: *mut u16,
        volume_len: DWORD,
        serial: *mut DWORD,
        max_component: *mut DWORD,
        flags: *mut DWORD,
        fs_name: *mut u16,
        fs_len: DWORD,
    ) -> BOOL;
    pub fn CreateEventW(sa: *const SECURITY_ATTRIBUTES, manual: BOOL, initial: BOOL, name: *const u16) -> HANDLE;
    pub fn SetEvent(h: HANDLE) -> BOOL;
    pub fn WaitForMultipleObjects(count: DWORD, handles: *const HANDLE, wait_all: BOOL, ms: DWORD) -> DWORD;
    pub fn WaitForSingleObject(h: HANDLE, ms: DWORD) -> DWORD;
    pub fn GetExitCodeProcess(h: HANDLE, code: *mut DWORD) -> BOOL;
    pub fn TerminateProcess(h: HANDLE, code: UINT) -> BOOL;
    pub fn CreateProcessW(
        app: *const u16,
        cmd: *mut u16,
        pa: *const SECURITY_ATTRIBUTES,
        ta: *const SECURITY_ATTRIBUTES,
        inherit: BOOL,
        flags: DWORD,
        env: *mut c_void,
        cwd: *const u16,
        si: *const STARTUPINFOW,
        pi: *mut PROCESS_INFORMATION,
    ) -> BOOL;
    pub fn InitializeProcThreadAttributeList(list: *mut c_void, count: DWORD, flags: DWORD, size: *mut usize) -> BOOL;
    pub fn UpdateProcThreadAttribute(
        list: *mut c_void,
        flags: DWORD,
        attr: usize,
        value: *mut c_void,
        size: usize,
        prev: *mut c_void,
        ret: *mut usize,
    ) -> BOOL;
    pub fn DeleteProcThreadAttributeList(list: *mut c_void);
    pub fn CreatePseudoConsole(size: COORD, input: HANDLE, output: HANDLE, flags: DWORD, pc: *mut HPCON) -> HRESULT;
    pub fn ResizePseudoConsole(pc: HPCON, size: COORD) -> HRESULT;
    pub fn ClosePseudoConsole(pc: HPCON);
    pub fn CreateNamedPipeW(
        name: *const u16,
        open_mode: DWORD,
        pipe_mode: DWORD,
        max_instances: DWORD,
        out_size: DWORD,
        in_size: DWORD,
        timeout: DWORD,
        sa: *const SECURITY_ATTRIBUTES,
    ) -> HANDLE;
    pub fn ConnectNamedPipe(h: HANDLE, ov: *mut c_void) -> BOOL;
    pub fn DisconnectNamedPipe(h: HANDLE) -> BOOL;
    pub fn WaitNamedPipeW(name: *const u16, timeout: DWORD) -> BOOL;
    pub fn CreateFileW(
        name: *const u16,
        access: DWORD,
        share: DWORD,
        sa: *const SECURITY_ATTRIBUTES,
        disposition: DWORD,
        flags: DWORD,
        template: HANDLE,
    ) -> HANDLE;
    pub fn CreateMutexW(sa: *const SECURITY_ATTRIBUTES, owner: BOOL, name: *const u16) -> HANDLE;
    pub fn GetCurrentProcess() -> HANDLE;
    pub fn LocalFree(h: HLOCAL) -> HLOCAL;
    pub fn GetTickCount64() -> u64;
    pub fn GetOverlappedResult(
        h: HANDLE,
        ov: *const OVERLAPPED,
        transferred: *mut DWORD,
        wait: BOOL,
    ) -> BOOL;
    pub fn CancelIoEx(h: HANDLE, ov: *const OVERLAPPED) -> BOOL;
    pub fn ResetEvent(h: HANDLE) -> BOOL;
    /// 注册/移除控制台控制事件处理函数；Shell 用它忽略自身收到的 Ctrl+C。
    pub fn SetConsoleCtrlHandler(
        handler: Option<unsafe extern "system" fn(DWORD) -> BOOL>,
        add: BOOL,
    ) -> BOOL;
    /// FILETIME（100 纳秒，自 1601）转本地系统时间，供 `dir` 显示修改时间。
    pub fn FileTimeToLocalFileTime(ft: *const u64, local: *mut u64) -> BOOL;
    pub fn FileTimeToSystemTime(ft: *const u64, st: *mut SYSTEMTIME) -> BOOL;
    pub fn GlobalAlloc(flags: UINT, bytes: usize) -> HANDLE;
    pub fn GlobalLock(mem: HANDLE) -> *mut c_void;
    pub fn GlobalUnlock(mem: HANDLE) -> BOOL;
    pub fn GlobalFree(mem: HANDLE) -> HANDLE;
    /// 读取 / 设置控制台窗口字体（受 conhost 可用字体限制）。
    pub fn GetCurrentConsoleFontEx(
        h: HANDLE,
        maximum: BOOL,
        info: *mut CONSOLE_FONT_INFOEX,
    ) -> BOOL;
    pub fn SetCurrentConsoleFontEx(
        h: HANDLE,
        maximum: BOOL,
        info: *const CONSOLE_FONT_INFOEX,
    ) -> BOOL;
}

// ---------- user32（剪贴板与窗口热键） ----------

pub const WM_HOTKEY: UINT = 0x0312;
pub const MOD_ALT: UINT = 0x0001;
pub const MOD_CONTROL: UINT = 0x0002;
pub const MOD_SHIFT: UINT = 0x0004;
pub const MOD_WIN: UINT = 0x0008;
pub const MOD_NOREPEAT: UINT = 0x4000;
pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;
pub const SW_RESTORE: i32 = 9;
pub const HWND_TOPMOST: HANDLE = -1isize as HANDLE;
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_SHOWWINDOW: UINT = 0x0040;

#[link(name = "user32")]
extern "system" {
    pub fn OpenClipboard(owner: HANDLE) -> BOOL;
    pub fn CloseClipboard() -> BOOL;
    pub fn EmptyClipboard() -> BOOL;
    pub fn GetClipboardData(format: UINT) -> HANDLE;
    pub fn SetClipboardData(format: UINT, mem: HANDLE) -> HANDLE;
    /// 注册全局热键；`hWnd` 为空时消息发到注册热键的线程队列。
    pub fn RegisterHotKey(hwnd: HANDLE, id: i32, modifiers: UINT, vk: UINT) -> BOOL;
    pub fn UnregisterHotKey(hwnd: HANDLE, id: i32) -> BOOL;
    pub fn GetMessageW(msg: *mut MSG, hwnd: HANDLE, min: UINT, max: UINT) -> BOOL;
    pub fn IsWindowVisible(hwnd: HANDLE) -> BOOL;
    pub fn IsIconic(hwnd: HANDLE) -> BOOL;
    pub fn ShowWindow(hwnd: HANDLE, cmd: i32) -> BOOL;
    pub fn SetForegroundWindow(hwnd: HANDLE) -> BOOL;
    pub fn BringWindowToTop(hwnd: HANDLE) -> BOOL;
    pub fn SetWindowPos(
        hwnd: HANDLE,
        after: HANDLE,
        x: i32,
        y: i32,
        cx: i32,
        cy: i32,
        flags: UINT,
    ) -> BOOL;
}

// ---------- advapi32 ----------

#[link(name = "advapi32")]
extern "system" {
    pub fn OpenProcessToken(process: HANDLE, access: DWORD, token: *mut HANDLE) -> BOOL;
    pub fn GetTokenInformation(
        token: HANDLE,
        class: u32,
        info: *mut c_void,
        len: DWORD,
        ret_len: *mut DWORD,
    ) -> BOOL;
    pub fn ConvertSidToStringSidW(sid: *mut c_void, out: *mut *mut u16) -> BOOL;
    pub fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl: *const u16,
        rev: DWORD,
        out: *mut *mut c_void,
        size: *mut DWORD,
    ) -> BOOL;
}

// ---------- ntdll ----------

#[link(name = "ntdll")]
extern "system" {
    pub fn RtlGetVersion(info: *mut RTL_OSVERSIONINFOW) -> NTSTATUS;
}

#[link(name = "shell32")]
extern "system" {
    pub fn ShellExecuteW(
        hwnd: HANDLE,
        op: *const u16,
        file: *const u16,
        params: *const u16,
        dir: *const u16,
        show: i32,
    ) -> HANDLE;
}

#[link(name = "kernel32")]
extern "system" {
    /// 动态加载 DLL（背景图片用的 gdiplus.dll 就是运行时按需加载的）。
    pub fn LoadLibraryW(name: *const u16) -> HANDLE;
    pub fn GetProcAddress(module: HANDLE, name: *const u16) -> *mut c_void;
    pub fn FreeLibrary(module: HANDLE) -> BOOL;
}

// ---------- 工具函数 ----------

/// 转为以 `\0` 结尾的 UTF-16 缓冲区，供 W 系列 API 使用。
pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 从以 `\0` 结尾的 UTF-16 指针读取 Rust 字符串。
///
/// # Safety
/// 指针必须指向合法的、以 `\0` 结尾的 UTF-16 数据。
pub unsafe fn from_wide_ptr(p: *const u16) -> String {
    if p.is_null() {
        return String::new();
    }
    let mut len = 0usize;
    while *p.add(len) != 0 {
        len += 1;
    }
    String::from_utf16_lossy(std::slice::from_raw_parts(p, len))
}

pub fn last_error() -> DWORD {
    unsafe { GetLastError() }
}

/// 用系统默认程序打开 URI / 路径（OSC 8 链接）。返回是否成功。
pub fn shell_open(target: &str) -> bool {
    unsafe {
        let op = wide("open");
        let file = wide(target);
        let result = ShellExecuteW(
            std::ptr::null_mut(),
            op.as_ptr(),
            file.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1,
        );
        result as isize > 32
    }
}

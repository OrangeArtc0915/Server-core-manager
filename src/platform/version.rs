//! Windows 版本与能力探测。

use super::win32;

/// ConPTY 鼠标上报缺陷的修复版本（Windows 10 1903）。
/// Server 2019 对应 build 17763，低于该值时必须关闭鼠标上报。
pub const CONPTY_MOUSE_FIX_BUILD: u32 = 18362;

/// 读取当前系统 build 号。使用 `RtlGetVersion` 以绕过兼容性清单对
/// `GetVersionEx` 的版本欺骗。
pub fn build_number() -> u32 {
    unsafe {
        let mut info = win32::RTL_OSVERSIONINFOW {
            dwOSVersionInfoSize: std::mem::size_of::<win32::RTL_OSVERSIONINFOW>() as u32,
            dwMajorVersion: 0,
            dwMinorVersion: 0,
            dwBuildNumber: 0,
            dwPlatformId: 0,
            szCSDVersion: [0; 128],
        };
        let status = win32::RtlGetVersion(&mut info);
        if status == 0 {
            info.dwBuildNumber
        } else {
            0
        }
    }
}

/// 当前 build 是否支持 ConPTY 鼠标上报。
pub fn mouse_report_supported(build: u32) -> bool {
    build >= CONPTY_MOUSE_FIX_BUILD
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_2019_build_has_no_mouse_report() {
        assert!(!mouse_report_supported(17763));
    }

    #[test]
    fn newer_builds_support_mouse_report() {
        assert!(mouse_report_supported(18362));
        assert!(mouse_report_supported(20348));
        assert!(mouse_report_supported(26100));
    }
}

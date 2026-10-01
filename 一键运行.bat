@echo off
REM ===========================================================================
REM  KEEP THIS FILE ASCII-ONLY, AND KEEP THE LINE ENDINGS AS CRLF.
REM
REM  This file is only a shim: it hands over to the PowerShell entry point, which
REM  does the elevation itself. Elevation must NOT live here -- cmd only sees
REM  Start-Process's exit code, and that is NOT reliable when the UAC prompt is
REM  cancelled, so the user gets "the window flashes and nothing happens" with no
REM  reason given. In PowerShell that failure is an exception we can catch, log
REM  (logs\launcher.log) and explain -- and we can still open the UI without
REM  elevation instead of leaving the user stuck.
REM
REM  ASCII only: cmd.exe parses .bat bytes with the OEM code page (936 on a zh-CN
REM  system) even though the file is stored as UTF-8. A non-ASCII byte flips the
REM  DBCS byte pairing, cmd stops seeing the line start ("REM ", "echo ") and
REM  starts EXECUTING fragments of the comment/echo lines. chcp 65001 does not
REM  help, because parsing uses the process code page, not the console one.
REM  All Chinese text belongs in the .ps1 files (UTF-8 with BOM).
REM
REM  CRLF: cmd needs CRLF. With LF-only endings the whole file is read as a
REM  single line and every word in it is run as a command.
REM ===========================================================================
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-GuiReadyApp.ps1"
if errorlevel 1 (
  echo.
  echo [!] The launcher returned an error. Details: logs\launcher.log
  pause
)
endlocal
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-GuiReadyApp.ps1"
if errorlevel 1 (
  echo.
  echo [!] The launcher returned an error. Details: logs\launcher.log
  pause
)
endlocal

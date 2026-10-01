@echo off
REM ===========================================================================
REM  KEEP THIS FILE ASCII-ONLY, AND KEEP THE LINE ENDINGS AS CRLF.
REM  This is only a shim; the elevation logic lives in the PowerShell entry point
REM  (see the header of the GUI launcher .bat for the full reasoning).
REM  cmd.exe parses .bat with the process OEM code page (936 on zh-CN) and needs
REM  CRLF endings; non-ASCII text or LF-only endings make it run fragments of
REM  comment/echo lines as commands. Chinese text belongs in the .ps1 files.
REM ===========================================================================
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-GuiReady.ps1"
if errorlevel 1 ( pause )
endlocal

@echo off
rem SCM Terminal launcher: UTF-8 console + MesloLGS Nerd Font + oh-my-posh (managed by ServerCoreManager)
setlocal
set "BIN=%~dp0"
set "FONT=MesloLGS NF"

rem NOTE: never redirect the font helper's stdout - a redirected stdout means the
rem process no longer owns a console handle and GetCurrentConsoleFontEx fails.

rem 1) switch this console to UTF-8; conhost refuses non-CJK fonts while the console code page is 936
chcp 65001 >nul

rem 2) apply the nerd font to THIS console window (silent, console-attached)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BIN%Set-ScmConsoleFont.ps1" -Face "%FONT%" -Size 18 -Quiet

if /I "%~1"=="--probe" goto :probe

rem 3) fastfetch banner (only when present). NOTE: fastfetch uses --key-width, not --key-length
if exist "%BIN%fastfetch.exe" (
    "%BIN%fastfetch.exe" --logo windows --key-width 14
)

rem 4) interactive shell; the PowerShell profile loads oh-my-posh
title SCM Terminal (UTF-8 + Nerd Font)
powershell.exe -NoExit -NoLogo
goto :eof

:probe
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BIN%Set-ScmConsoleFont.ps1" -Probe -Quiet -OutFile "%BIN%..\logs\console-probe.txt"
exit /b 0

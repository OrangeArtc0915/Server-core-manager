@echo off
rem SCM Terminal launcher: UTF-8 console + MesloLGS Nerd Font + oh-my-posh (managed by ServerCoreManager)
setlocal
set "BIN=%~dp0"
set "FONT=MesloLGS NF"

rem NOTE: never redirect the font helper's stdout - a redirected stdout means the
rem process no longer owns a console handle and GetCurrentConsoleFontEx fails.

rem 1) switch this console to UTF-8; conhost refuses non-CJK fonts while the console code page is 936
chcp 65001 >nul

if /I "%~1"=="--probe" goto :probe

rem 2) single PowerShell launch (startup speed): apply the font, show fastfetch, then stay interactive.
rem    Previously this started PowerShell twice (font helper + interactive shell), costing ~1s extra.
title SCM Terminal (UTF-8 + Nerd Font)
powershell.exe -NoLogo -ExecutionPolicy Bypass -NoExit -Command "& '%BIN%Set-ScmConsoleFont.ps1' -Face '%FONT%' -Size 18 -Quiet; if (Test-Path '%BIN%fastfetch.exe') { & '%BIN%fastfetch.exe' --logo windows --key-width 14 }"
goto :eof

:probe
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BIN%Set-ScmConsoleFont.ps1" -Probe -Quiet -OutFile "%BIN%..\logs\console-probe.txt"
exit /b 0

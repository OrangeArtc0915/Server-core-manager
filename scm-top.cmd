@echo off
rem scm-top: standalone TUI monitor for Windows Server Core
rem Usage: scm-top.cmd [interval-seconds]
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scm-top.ps1" %*
endlocal

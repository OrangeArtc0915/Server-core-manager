@echo off
chcp 65001 >nul
setlocal
echo.
echo   Server Core Manager - Windows Server 2008 R2 prerequisites
echo   This will install .NET Framework 4.6.2 and WMF 5.1 (PowerShell 5.1).
echo   Administrator rights are required. A reboot is needed afterwards.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-LegacyPrereq.ps1"
echo.
pause

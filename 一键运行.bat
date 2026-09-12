@echo off
setlocal
cd /d "%~dp0"
fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator privileges...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0Start-GuiReadyApp.ps1')"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-GuiReadyApp.ps1"
)
endlocal

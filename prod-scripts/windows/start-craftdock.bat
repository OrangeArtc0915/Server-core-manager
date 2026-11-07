@echo off
rem ============================================================
rem CraftDock launcher (single executable)
rem
rem Everything (JS bundle, dependencies, terminfo and the frpc clients
rem for Sakura Frp / OpenFrp / ChmlFrp) is embedded in craftdock.exe.
rem data/ and logs/ are created next to it on first run; lib/ is
rem recreated automatically from the embedded components.
rem ============================================================
chcp 65001 >nul
title CraftDock - mmm
cd /d "%~dp0"

if not exist "craftdock.exe" (
    echo [ERROR] craftdock.exe not found next to this script.
    pause
    exit /b 1
)

echo  CraftDock  -  original terminal server manager inspired by MCSManager
echo  Author: mmm    QQ group: 1131093424
echo  Site: https://orangeartc0915.github.io/Server-core-manager/projects/
echo.

rem Enlarge the console so the layout has enough rows/columns (best effort).
mode con: cols=120 lines=36 >nul 2>nul

"craftdock.exe" %*

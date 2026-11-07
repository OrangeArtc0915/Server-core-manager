@echo off
REM ============================================================
REM CraftDock release build (Windows, TUI only)
REM
REM BUNDLE=1 inlines the whole dependency tree into daemon\tui.js,
REM so the output runs with bare `node` (or the SEA executable)
REM and no npm install.
REM
REM Output:
REM   ./production-code/                       release directory
REM   ./craftdock-<version>-windows-amd64.zip
REM
REM Runtime data of a previous build is backed up to
REM ./production-data-backup/ before the release dir is rebuilt.
REM ============================================================
setlocal
set BASE_DIR=%~dp0

set BUNDLE=1

REM Back up runtime data of a previous release build before it is wiped.
if exist "%BASE_DIR%production-code\daemon\data" xcopy "%BASE_DIR%production-code\daemon\data" "%BASE_DIR%production-data-backup\daemon-data\" /E /I /H /Y >nul

REM Warn when a previous release is still running.
powershell -NoProfile -Command "if (Get-NetTCPConnection -State Listen -LocalPort 24444 -ErrorAction SilentlyContinue) { Write-Host 'WARNING: A release instance is still running on 24444. Close it first.' -ForegroundColor Yellow }"

call npm run preview-build

if exist "%BASE_DIR%production-code" rd /s /q "%BASE_DIR%production-code"
if exist "%BASE_DIR%daemon\dist" rd /s /q "%BASE_DIR%daemon\dist"
if exist "%BASE_DIR%daemon\production" rd /s /q "%BASE_DIR%daemon\production"

echo Build TUI...
cd "%BASE_DIR%daemon"
call npm run build:tui

echo Collecting files...
cd "%BASE_DIR%"

mkdir "%BASE_DIR%production-code"

REM Build the single-file TUI executable (Node.js SEA, terminfo embedded).
call "%BASE_DIR%prod-scripts\windows\build-tui-exe.bat"
if not exist "%BASE_DIR%daemon\production\craftdock.exe" (
    echo ERROR: TUI executable was not generated.
    exit /b 1
)
copy "%BASE_DIR%daemon\production\craftdock.exe" "%BASE_DIR%production-code\craftdock.exe" >nul

if exist "%BASE_DIR%daemon\production" rd /s /q "%BASE_DIR%daemon\production"
if exist "%BASE_DIR%daemon\dist" rd /s /q "%BASE_DIR%daemon\dist"

copy "%BASE_DIR%prod-scripts\windows\start-craftdock.bat" "%BASE_DIR%production-code\start-craftdock.bat" >nul

set ZIP_NAME=craftdock-10.18.3-windows-amd64.zip
tar -a -c -f "%BASE_DIR%%ZIP_NAME%" -C "%BASE_DIR%production-code" .

echo ------------
echo Compilation completed!
echo Output Directory: ./production-code/
echo Launch TUI    : production-code\start-craftdock.bat
echo Release Archive: %ZIP_NAME%
echo Previous runtime data backed up to ./production-data-backup/ (if any)
echo ------------
endlocal
if "%NOPAUSE%"=="" pause

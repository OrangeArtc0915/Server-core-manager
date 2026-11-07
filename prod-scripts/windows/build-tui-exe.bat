@echo off
rem ============================================================
rem Build a single-file TUI executable with Node.js SEA.
rem
rem Requires:
rem   - Node.js >= 20 (SEA support)
rem   - daemon/production/tui.js (run: npm run build:tui with BUNDLE=1)
rem   - postject (devDependency of daemon/)
rem
rem Output: daemon/production/craftdock.exe
rem The executable is fully self-contained: the JS bundle and the
rem xterm-256color terminfo used by blessed are embedded in the SEA.
rem Only data/ (created at runtime) and the optional lib/ (PTY / Zip
rem tools) live next to it.
rem ============================================================
setlocal
set BASE_DIR=%~dp0
set DAEMON_DIR=%BASE_DIR%..\..\daemon

if not exist "%DAEMON_DIR%\production\tui.js" (
    echo [ERROR] %DAEMON_DIR%\production\tui.js not found. Build the TUI first.
    exit /b 1
)

cd /d "%DAEMON_DIR%"

rem Fetch the embedded native components (7zr, PTY) and regenerate the SEA
rem asset list. Failures only drop the missing asset, the build still works.
node scripts\fetch-assets.js
if errorlevel 1 (
    echo [WARN] Failed to prepare optional components, continuing without them.
)

node --experimental-sea-config sea-tui.json
if errorlevel 1 (
    echo [ERROR] Failed to create the SEA blob.
    exit /b 1
)

node -e "require('fs').copyFileSync(process.execPath, 'production/craftdock.exe')"
if errorlevel 1 (
    echo [ERROR] Failed to copy node.exe.
    exit /b 1
)

npx --no-install postject production\craftdock.exe NODE_SEA_BLOB production\tui-sea.blob --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2
if errorlevel 1 (
    echo [ERROR] postject failed. Install it with: npm install -D postject
    exit /b 1
)

echo [OK] Built %DAEMON_DIR%\production\craftdock.exe
endlocal

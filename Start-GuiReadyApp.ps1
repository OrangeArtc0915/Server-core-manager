# GuiReady app entry: opens the GUI by default, console menu with -Console.
# This is what the one-word command (scm) launches.

param(
    [switch]$Console,
    [switch]$KeepConsole
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot

function Start-GuiReadyConsoleMenu {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Start-GuiReady.ps1')
}

if ($Console) {
    Start-GuiReadyConsoleMenu
    return
}

$gui = Join-Path $here 'gui\GuiReady.GuiApp.ps1'
if (Test-Path -LiteralPath $gui) {
    & $gui -KeepConsole:$KeepConsole
    return
}

Write-Host '没有找到图形界面模块，改用命令行菜单。' -ForegroundColor Yellow
Start-GuiReadyConsoleMenu

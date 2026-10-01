# GuiReady store query runner: runs the package-source detection / search in a separate
# process so the store page never blocks the UI thread (choco search is a network call and
# takes seconds; scoop --version has to spin up PowerShell).
#
# Writes the result as JSON, atomically (tmp + Move), so the GUI can poll for the file
# without ever reading a half-written one - same pattern as Run-GuiReadyProbe.ps1.
#
# Modes:
#   status  -> the package-source list (which package managers exist, versions, support level)
#   search  -> search result for -Source / -Query
#   local   -> the installed package list for -Source
#
# Keep this file ASCII-only: it ships inside the release zip and must parse under any
# console code page without depending on a BOM.

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$Source = 'choco',
    [string]$Query  = '',
    [string]$Package = '',
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

# One shared log file instead of one per query
$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-store.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Package.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 数据类参数（搜索词 / 包名）优先从 JSON 文件读。
# 为什么不走命令行：包名来自远程 feed，而 Start-Process 的 ArgumentList 需要手工拼引号，
# 名字里带引号就能往命令行里注入额外参数。走文件则完全绕开引号拼接。
# 读完立刻删除（文件里可能含用户输入的搜索词）。
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $a = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($a.Source)  { $Source  = [string]$a.Source }
        if ($a.Query)   { $Query   = [string]$a.Query }
        if ($a.Package) { $Package = [string]$a.Package }
    } catch { }
    try { Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue } catch { }
}

function Write-StoreResult {
    param($Items, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode    = $Mode
        Source  = $Source
        Query   = $Query
        Package = $Package
        Stamp   = (Get-Date).ToString('o')
        Error   = $ErrorText
        Items   = @($Items)
    }
    try {
        $json = $o | ConvertTo-Json -Depth 6 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    $items = @()
    switch ($Mode) {
        'status' { $items = @(Get-GuiReadyPackageSource) }
        'search' { $items = @(Search-GuiReadyPackage -Source $Source -Query $Query) }
        'local'  { $items = @(Get-GuiReadyInstalledPackage -Source $Source) }
        # 详情：单个对象也塞进 Items 数组，GUI 那边只认一种形状
        'info'   { $items = @(Get-GuiReadyPackageInfo -Source $Source -Package $Package) }
        default {
            Write-StoreResult -Items @() -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
    Write-StoreResult -Items $items
    exit 0
} catch {
    Write-StoreResult -Items @() -ErrorText $_.Exception.Message
    exit 1
}

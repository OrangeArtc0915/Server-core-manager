#Requires -Version 5.1
<#
  打包发布压缩包（给 GitHub Releases 用）

  产出两个文件到 dist\ ：
    ServerCoreManager.zip              固定名字。install.ps1 靠 releases/latest/download/ServerCoreManager.zip 取它，
                                       所以每次发版【必须】上传这个同名文件。
    ServerCoreManager-<版本>.zip       带版本号，给人看的。

  内容与仓库里公开的文件一致：排除 logs\ reports\ backup\ state\ payload\ 与所有 .exe/.msi
  （这些在 .gitignore 里，不该出现在发布包里）。

  用法：
    .\pack.ps1 -Version v1.0.0
#>
[CmdletBinding()]
param(
    [string]$Version = 'v0.0.0',
    [string]$OutDir = '',
    [switch]$KeepStage
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$files = @(
    'README.md', 'README.en.md', 'LICENSE',
    'install.ps1', 'pack.ps1', 'RELEASE_NOTES.md',
    'Start-GuiReadyApp.ps1', 'Start-GuiReady.ps1',
    'Install-GuiReadyCommand.ps1', 'Resume-GuiReadyPipeline.ps1',
    '一键运行.bat', '打开命令行菜单.bat', '安装一行命令.bat'
)
$dirs = @('gui', 'lib', 'launcher')

# 双保险：即使哪天把不该公开的东西挪进了上面这些目录，也不会被打进发布包
$denyDirs = @('logs', 'reports', 'backup', 'state', 'payload', 'dist', '.git')
$denyExt  = @('.exe', '.msi', '.zip')

$stage = Join-Path $env:TEMP ('scm-pack-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

foreach ($f in $files) {
    $p = Join-Path $root $f
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        Copy-Item -LiteralPath $p -Destination $stage -Force
    } else {
        Write-Warning ('缺少文件，已跳过: ' + $f)
    }
}

foreach ($d in $dirs) {
    $p = Join-Path $root $d
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { Write-Warning ('缺少目录，已跳过: ' + $d); continue }
    Get-ChildItem -LiteralPath $p -Recurse -File | ForEach-Object {
        $rel  = $_.FullName.Substring($root.Length).TrimStart('\')
        $skip = $false
        foreach ($seg in ($rel -split '\\')) { if ($denyDirs -contains $seg) { $skip = $true } }
        if ($denyExt -contains $_.Extension.ToLower()) { $skip = $true }
        if ($skip) { return }
        $to = Join-Path $stage $rel
        $toDir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
        Copy-Item -LiteralPath $_.FullName -Destination $to -Force
    }
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$plain   = Join-Path $OutDir 'ServerCoreManager.zip'
$versioned = Join-Path $OutDir ('ServerCoreManager-' + $Version + '.zip')
foreach ($z in @($plain, $versioned)) { if (Test-Path -LiteralPath $z) { Remove-Item -LiteralPath $z -Force } }

# ZipArchiveMode 在 System.IO.Compression 里，ZipFile 在 System.IO.Compression.FileSystem 里，两个都要加载
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

function New-ZipFromDirectory {
    param([string]$SourceDir, [string]$ZipPath)

    # 不能用 Compress-Archive：它在 PS 5.1 下把路径分隔符写成反斜杠，
    # 违反 ZIP 规范，7-Zip / Linux unzip 会把 "gui\a.ps1" 当成一个文件名解到根目录。
    # 这里手工建条目，强制用正斜杠。压缩算法与 Compress-Archive 相同（同一个 ZipArchive）。
    $fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $base = (Get-Item -LiteralPath $SourceDir).FullName.TrimEnd('\') + '\'
            Get-ChildItem -LiteralPath $SourceDir -Recurse -File | ForEach-Object {
                $rel = $_.FullName.Substring($base.Length).Replace('\', '/')
                $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $out = $entry.Open()
                try {
                    $in = [System.IO.File]::OpenRead($_.FullName)
                    try { $in.CopyTo($out) } finally { $in.Dispose() }
                } finally { $out.Dispose() }
            }
        } finally { $zip.Dispose() }
    } catch {
        # 别留下一个写坏了的 zip 冒充发布包
        try { $fs.Dispose() } catch { }
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
        throw
    }
    $fs.Dispose()
}

New-ZipFromDirectory -SourceDir $stage -ZipPath $plain
Copy-Item -LiteralPath $plain -Destination $versioned -Force

Write-Host ''
Write-Host '  打包完成' -ForegroundColor Green
Write-Host ''
foreach ($z in @($plain, $versioned)) {
    $kb = [math]::Round((Get-Item -LiteralPath $z).Length / 1KB, 1)
    Write-Host ('    {0,-46} {1,8} KB' -f (Split-Path $z -Leaf), $kb) -ForegroundColor Gray
}
$count = (Get-ChildItem -LiteralPath $stage -Recurse -File).Count
Write-Host ''
Write-Host ('  包内文件 {0} 个' -f $count) -ForegroundColor Gray

if ($KeepStage) { Write-Host ('  暂存目录保留在: ' + $stage) -ForegroundColor DarkGray }
else { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host '  上传到 Releases 时记得两个都传：ServerCoreManager.zip 必须用这个固定名字，' -ForegroundColor Yellow
Write-Host '  因为 install.ps1 是按 releases/latest/download/ServerCoreManager.zip 取的。' -ForegroundColor Yellow
Write-Host ''

#Requires -Version 5.1
<#
  打包发布压缩包（给 GitHub Releases 用）

  产出两个文件到 dist\ ：
    ServerCoreManager.zip              固定名字。install.ps1 靠 releases/latest/download/ServerCoreManager.zip 取它，
                                       所以每次发版【必须】上传这个同名文件。
    ServerCoreManager-<版本>.zip       带版本号，给人看的。

  内容与仓库里公开的文件一致：排除 logs\ reports\ backup\ state\ payload\ 与所有 .exe/.msi
  （这些在 .gitignore 里，不该出现在发布包里）。

  例外：setup\console\ 下的终端美化素材（Nerd Font / oh-my-posh / fastfetch）会【被打进】发布包，
  这样「更多 → 终端美化 → 一键美化终端」不需要联网。它们不进 git（见 .gitignore），
  但必须在打包机上存在，否则发布包会缺内置素材。

  用法：
    .\pack.ps1 -Version v1.0.0                     # 只打包（仍会生成 manifest.sha256 与 .sha256 侧车）
    .\pack.ps1 -Version v1.0.0 -Sign -Thumbprint <证书指纹>       # 顺便给包内脚本签名
    .\pack.ps1 -Version v1.0.0 -Sign -PfxPath .\签名\证书.pfx     # 用 pfx（密码读环境变量 SCM_PFX_PASSWORD）

  签名/校验的细节见 Sign-GuiReady.ps1。顺序永远是「先签名、后清单、再打包」——
  清单里存的是最终内容的哈希，签完再改文件就会对不上（这正是我们要能发现的事）。
#>
[CmdletBinding()]
param(
    [string]$Version = 'v0.0.0',
    [string]$OutDir = '',
    [switch]$KeepStage,
    # 给包内脚本签名（复用 Sign-GuiReady.ps1）
    [switch]$Sign,
    [string]$Thumbprint = '',
    [string]$PfxPath = '',
    # pfx 密码（不传则读环境变量 SCM_PFX_PASSWORD；再不行会交互提示）
    [string]$PfxPassword = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$files = @(
    'README.md', 'README.en.md', 'LICENSE',
    'install.ps1', 'pack.ps1', 'RELEASE_NOTES.md',
    'Sign-GuiReady.ps1',
    'Start-GuiReadyApp.ps1', 'Start-GuiReady.ps1',
    'Install-GuiReadyCommand.ps1', 'Resume-GuiReadyPipeline.ps1',
    '一键运行.bat', '打开命令行菜单.bat', '安装一行命令.bat'
)
$dirs = @('gui', 'lib', 'launcher', 'setup', 'docs')

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
        # setup\ 下的内置素材允许 exe（终端美化的 oh-my-posh / fastfetch 就是 exe），其它目录仍然拦住 exe/msi/zip
        $inSetup = (($rel -split '\\')[0] -eq 'setup')
        if (-not $inSetup -and $denyExt -contains $_.Extension.ToLower()) { $skip = $true }
        if ($skip) { return }
        $to = Join-Path $stage $rel
        $toDir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
        Copy-Item -LiteralPath $_.FullName -Destination $to -Force
    }
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ---------------------------------------------------------------- 签名 + 完整性清单
# 顺序不能变：先签名（改文件）→ 再生成清单（记录最终哈希）→ 最后打包。
# 如果清单在这之前生成，签名会把哈希改掉，用户侧校验就会报"文件被改过"（假警报）。
$integrityMod = Join-Path $root 'lib\GuiReady.Integrity.ps1'
$haveIntegrity = Test-Path -LiteralPath $integrityMod
if ($haveIntegrity) { . $integrityMod }

if ($Sign) {
    $signScript = Join-Path $root 'Sign-GuiReady.ps1'
    if (-not (Test-Path -LiteralPath $signScript)) {
        Write-Warning '找不到 Sign-GuiReady.ps1，跳过签名。'
    } else {
        Write-Host ''
        Write-Host '  给包内脚本签名 ...' -ForegroundColor Cyan
        # 在**暂存目录**里签，不动仓库里的文件
        $signArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $signScript, '-Root', $stage, '-Quiet')
        if ($Thumbprint)   { $signArgs += @('-Thumbprint', $Thumbprint) }
        if ($PfxPath)      { $signArgs += @('-PfxPath', $PfxPath) }
        if ($PfxPassword)  { $signArgs += @('-PfxPassword', $PfxPassword) }
        & powershell @signArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ('签名未成功（退出码 {0}）—— 本次仍会打包，但包内脚本没有签名。' -f $LASTEXITCODE)
        }
    }
}

# 清单：无论是否签名都要生成（用户侧靠它核对"文件是否被改过"）
if ($haveIntegrity) {
    $manPath = Join-Path $stage 'manifest.sha256'
    $manCount = New-GuiReadyManifest -Root $stage -OutFile $manPath
    Write-Host ('  已生成完整性清单: manifest.sha256（{0} 个文件）' -f $manCount) -ForegroundColor Green
} else {
    Write-Warning '找不到 lib\GuiReady.Integrity.ps1，本次发布包不含完整性清单。'
}

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

# ---------------------------------------------------------------- 发布包哈希（侧车文件）
# 生成 <zip>.sha256（sha256sum 兼容格式）。install.ps1 会尝试取这个侧车文件来校验下载到的包；
# 用户也可以拿它手工比对。发版时【要和 zip 一起上传】，否则校验链就断了。
if ($haveIntegrity) {
    Write-Host ''
    Write-Host '  发布包 SHA256（写进 Release 说明，并把 .sha256 侧车与 zip 一起上传）:' -ForegroundColor Cyan
    foreach ($z in @($plain, $versioned)) {
        $h = Get-GuiReadyFileHash -Path $z
        if (-not $h) { Write-Warning ('算不出哈希: ' + $z); continue }
        $side = $z + '.sha256'
        try {
            [System.IO.File]::WriteAllText($side, ($h + '  ' + (Split-Path $z -Leaf) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        } catch { Write-Warning ('写侧车文件失败: ' + $side + ' —— ' + $_.Exception.Message) }
        Write-Host ('    {0,-12} {1}' -f (Split-Path $z -Leaf), $h) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  用户侧核对完整性（解压后在该目录执行）:' -ForegroundColor Cyan
    Write-Host '    powershell -ExecutionPolicy Bypass -File Sign-GuiReady.ps1 -Verify' -ForegroundColor Gray
}

# 终端美化素材自检（Nerd Font + oh-my-posh + fastfetch + 启动器）
$conDir  = Join-Path $root 'setup\console'
$conPkgs = @()
if (Test-Path -LiteralPath $conDir) { $conPkgs = @(Get-ChildItem -LiteralPath $conDir -File -ErrorAction SilentlyContinue) }
$conFont  = @($conPkgs | Where-Object { $_.Extension -ieq '.ttf' })
$conPosh  = @($conPkgs | Where-Object { $_.Name -match '(?i)^(oh-my-posh|posh-windows).*\.exe$' })
$conTheme = @($conPkgs | Where-Object { $_.Name -match '(?i)\.omp\.json$' })
$conLau   = @($conPkgs | Where-Object { $_.Name -eq 'scm-term.cmd' })
$conThemesDir = Join-Path $conDir 'themes'
$conThemes = @()
if (Test-Path -LiteralPath $conThemesDir) {
    $conThemes = @(Get-ChildItem -LiteralPath $conThemesDir -File -Filter '*.omp.json' -ErrorAction SilentlyContinue)
}
if ($conFont.Count -gt 0 -and $conPosh.Count -gt 0 -and $conTheme.Count -gt 0 -and $conLau.Count -gt 0) {
    $mb2 = [math]::Round((($conPkgs | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
    Write-Host ('  内置美化素材: 已包含（{0} 个文件，{1} MB）' -f $conPkgs.Count, $mb2) -ForegroundColor Green
    if ($conThemes.Count -gt 0) {
        Write-Host ('  内置 oh-my-posh 主题: {0} 个（{1}）' -f $conThemes.Count, (($conThemes | ForEach-Object { $_.BaseName }) -join ', ')) -ForegroundColor Green
    } else {
        Write-Warning 'setup\console\themes 下没有主题文件，「一键美化终端」的主题下拉会退化成默认主题。'
    }
} else {
    Write-Warning ('setup\console 下缺少终端美化素材（需要 *.ttf + oh-my-posh.exe + *.omp.json + scm-term.cmd），' +
                   '本次发布包的「一键美化终端」会因找不到素材而失败。')
}

if ($KeepStage) { Write-Host ('  暂存目录保留在: ' + $stage) -ForegroundColor DarkGray }
else { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host '  上传到 Releases 时记得两个都传：ServerCoreManager.zip 必须用这个固定名字，' -ForegroundColor Yellow
Write-Host '  因为 install.ps1 是按 releases/latest/download/ServerCoreManager.zip 取的。' -ForegroundColor Yellow
Write-Host '  同时把 ServerCoreManager.zip.sha256 一起传上去 —— install.ps1 会用它校验下载到的包。' -ForegroundColor Yellow
Write-Host ''

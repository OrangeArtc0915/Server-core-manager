#Requires -Version 5.1
<#
  打包发布压缩包（给 GitHub Releases 用）

  产出两个文件到 dist\ ：
    ServerCoreManager.zip              固定名字。install.ps1 靠 releases/latest/download/ServerCoreManager.zip 取它，
                                       所以每次发版【必须】上传这个同名文件。
    ServerCoreManager-<版本>.zip       带版本号，给人看的。

  内容与仓库里公开的文件一致：排除 logs\ reports\ backup\ state\ payload\ 与所有 .exe/.msi
  （这些在 .gitignore 里，不该出现在发布包里）。

  例外：setup\dll\ 下的 .NET 依赖（*.dll）随包发布 —— 它们是我们自己的运行库，不联网也要能用。

  第三方程序与字体【不再内置】：setup\console\ 只带我们自己的文本资产
  （scm-term.cmd / Set-ScmConsoleFont.ps1 / themes\*.omp.json），
  oh-my-posh.exe / fastfetch.exe / MesloLGS NF 的 ttf 在安装时从官方源下载
  （见 lib\GuiReady.Console.ps1 的 Install-GuiReadyConsoleAssets）。

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
$dirs = @('gui', 'lib', 'launcher', 'setup', 'docs', 'store')

# 双保险：即使哪天把不该公开的东西挪进了上面这些目录，也不会被打进发布包
$denyDirs = @('logs', 'reports', 'backup', 'state', 'payload', 'dist', '.git',
              'runtimes', 'databases', 'data', 'reference', 'plugins')
$denyExt  = @('.exe', '.msi', '.zip')
# 本机数据不进包：catalog.user.json 是用户自己的实测记录，随人不同
$denyNames = @('catalog.user.json')

$stage = Join-Path $env:TEMP ('scm-pack-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# ---------------------------------------------------------------- 原生界面（C#）
# 发布包里的 ui\bin\ScmUi.exe 是打包时现编的：源码在 ui\*.cs，编译只要系统自带的 csc.exe。
# 编译失败不阻断打包 —— 启动器检测不到 exe 会自动回退到 PowerShell 版界面。
$uiBuild = Join-Path $root 'ui\build-ui.ps1'
$uiExe   = Join-Path $root 'ui\bin\ScmUi.exe'
if (Test-Path -LiteralPath $uiBuild) {
    Write-Host ''
    Write-Host '  编译原生界面 (ui\*.cs) ...' -ForegroundColor Cyan
    try {
        & $uiBuild
    } catch {
        Write-Warning ('原生界面编译失败，发布包只带 PowerShell 版界面：' + $_.Exception.Message)
    }
}

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
        if ($denyNames -contains $_.Name) { $skip = $true }
        # setup\dll 下的 .NET 依赖要进包（我们自己的运行库）；除此之外 exe/msi/zip 一律拦住
        $inDll = ($rel -match '(?i)^setup\\dll\\')
        if (-not $inDll -and $denyExt -contains $_.Extension.ToLower()) { $skip = $true }
        # 第三方程序与字体不再内置：装的时候从官方源下载
        if ($rel -match '(?i)^setup\\console\\[^\\]+\.(exe|ttf|otf)$') { $skip = $true }
        if ($skip) { return }
        $to = Join-Path $stage $rel
        $toDir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
        Copy-Item -LiteralPath $_.FullName -Destination $to -Force
    }
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# 原生界面的二进制单独放行：目录遍历里 .exe 一律被拦（防止误带第三方安装包），
# 但 ScmUi.exe 是我们自己的产物，必须进包。
if (Test-Path -LiteralPath $uiExe) {
    $to = Join-Path $stage 'ui\bin\ScmUi.exe'
    $toDir = Split-Path -Parent $to
    if (-not (Test-Path -LiteralPath $toDir)) { New-Item -ItemType Directory -Path $toDir -Force | Out-Null }
    Copy-Item -LiteralPath $uiExe -Destination $to -Force
    Write-Host ('  已纳入原生界面: ui\bin\ScmUi.exe（{0} KB）' -f [math]::Round((Get-Item -LiteralPath $uiExe).Length / 1KB, 1)) -ForegroundColor Green
} else {
    Write-Warning '没有 ui\bin\ScmUi.exe —— 这次发布包只有 PowerShell 版界面（启动器会自动回退）。'
}

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

# 终端美化素材自检：只检查随包发布的文本资产（第三方程序与字体改为联网下载，不在包里）
$conDir  = Join-Path $root 'setup\console'
$conPkgs = @()
if (Test-Path -LiteralPath $conDir) { $conPkgs = @(Get-ChildItem -LiteralPath $conDir -File -ErrorAction SilentlyContinue) }
$conTheme = @($conPkgs | Where-Object { $_.Name -match '(?i)\.omp\.json$' })
$conLau   = @($conPkgs | Where-Object { $_.Name -eq 'scm-term.cmd' })
$conFontScript = @($conPkgs | Where-Object { $_.Name -eq 'Set-ScmConsoleFont.ps1' })
$conThemesDir = Join-Path $conDir 'themes'
$conThemes = @()
if (Test-Path -LiteralPath $conThemesDir) {
    $conThemes = @(Get-ChildItem -LiteralPath $conThemesDir -File -Filter '*.omp.json' -ErrorAction SilentlyContinue)
}
$conMissing = @()
if ($conTheme.Count -eq 0)     { $conMissing += '*.omp.json' }
if ($conLau.Count -eq 0)       { $conMissing += 'scm-term.cmd' }
if ($conFontScript.Count -eq 0) { $conMissing += 'Set-ScmConsoleFont.ps1' }
if ($conMissing.Count -eq 0) {
    Write-Host '  终端美化文本资产: 已包含（第三方程序与字体改为联网下载，不在包里）' -ForegroundColor Green
    if ($conThemes.Count -gt 0) {
        Write-Host ('  内置 oh-my-posh 主题: {0} 个（{1}）' -f $conThemes.Count, (($conThemes | ForEach-Object { $_.BaseName }) -join ', ')) -ForegroundColor Green
    } else {
        Write-Warning 'setup\console\themes 下没有主题文件，「一键美化终端」的主题下拉会退化成默认主题。'
    }
} else {
    Write-Warning ('setup\console 下缺少文本资产：' + ($conMissing -join '、') +
                   '。这些必须随包发布，否则「一键美化终端」装不起来。')
}

if ($KeepStage) { Write-Host ('  暂存目录保留在: ' + $stage) -ForegroundColor DarkGray }
else { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host '  上传到 Releases 时记得两个都传：ServerCoreManager.zip 必须用这个固定名字，' -ForegroundColor Yellow
Write-Host '  因为 install.ps1 是按 releases/latest/download/ServerCoreManager.zip 取的。' -ForegroundColor Yellow
Write-Host '  同时把 ServerCoreManager.zip.sha256 一起传上去 —— install.ps1 会用它校验下载到的包。' -ForegroundColor Yellow
Write-Host ''

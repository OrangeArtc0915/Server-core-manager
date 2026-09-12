#Requires -Version 5.1
<#
  Server Core Manager —— 命令行一行安装

  推荐用法（在【管理员】PowerShell 里执行一行）：
      irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex

  因为 iex 没法传参数，需要改默认值时用环境变量：
      $env:SCM_DEST       = 'D:\SCM'    指定安装目录（默认 C:\Program Files\ServerCoreManager）
      $env:SCM_NO_COMMAND = '1'         不安装 scm 一行命令
      $env:SCM_BRANCH     = 'main'      指定分支（仅下载分支压缩包时用到）

  也可以先存成文件、再当普通脚本跑，这样能直接传参：
      .\install.ps1 -Dest 'D:\SCM' -NoCommand

  重复执行视为升级：只覆盖程序文件，不会删除你已有的程序列表（launcher\programs.json）、
  日志与断点状态（logs\ / reports\ / state\）。
#>
[CmdletBinding()]
param(
    [string]$Dest = '',
    [string]$Branch = '',
    [string]$CommandName = 'scm',
    [switch]$NoCommand
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Owner     = 'OrangeArtc0915'
$Repo      = 'Server-core-manager'
$AssetName = 'ServerCoreManager.zip'

# 用 irm | iex 运行时 $PSCommandPath 为空。这种情况下一律不能用 exit：
# 实测 exit 会直接终止宿主，把用户刚打开的 PowerShell 窗口关掉，报错信息根本来不及看。
# 所以 iex 场景用 return 结束脚本，文件场景保留非零退出码供脚本化调用判断。
$RunAsFile = [bool]$PSCommandPath

function Write-Step { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Red }

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor White
Write-Host '    Server Core Manager  ·  命令行安装' -ForegroundColor White
Write-Host ('    ' + $Owner + '/' + $Repo) -ForegroundColor DarkGray
Write-Host '  ============================================================' -ForegroundColor White
Write-Host ''

# ---------------------------------------------------------------- 前置检查

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal -ArgumentList $id).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

if (-not $isAdmin) {
    Write-Err '需要管理员权限。请用【以管理员身份运行】打开 PowerShell 后重试。'
    Write-Warn '提示：服务管理器（sconfig）里选 15 可以打开管理员 PowerShell。'
    if ($RunAsFile) { exit 1 } else { return }
}

# PS 5.1 默认可能不带 TLS 1.2，会导致访问 GitHub 直接失败
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not $Dest)   { if ($env:SCM_DEST) { $Dest = $env:SCM_DEST } }
if (-not $Branch) { if ($env:SCM_BRANCH) { $Branch = $env:SCM_BRANCH } else { $Branch = 'main' } }
if ($env:SCM_NO_COMMAND -eq '1') { $NoCommand = $true }
if (-not $Dest)   { $Dest = Join-Path $env:ProgramFiles 'ServerCoreManager' }

Write-Step ('安装目录 : ' + $Dest)
Write-Step ('下载分支 : ' + $Branch)
Write-Host ''

# ---------------------------------------------------------------- 下载

$tmp = Join-Path $env:TEMP ('scm-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'package.zip'

function Save-RemoteFile {
    param([string]$Url, [string]$Path)

    $curl = Join-Path (Join-Path $env:windir 'System32') 'curl.exe'
    if (Test-Path -LiteralPath $curl) {
        # Server Core 上 curl.exe 比 PS 自带的 HTTP 客户端稳（后者对 TLS 重协商处理不佳）
        & $curl -L --fail --retry 3 --retry-delay 3 --retry-all-errors -s -S -o $Path $Url 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 0) {
            return $true
        }
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
    try {
        # Server Core 没有 IE 引擎，必须加 -UseBasicParsing
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 300
        return ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 0)
    } catch {
        return $false
    }
}

$releaseUrl = ('https://github.com/{0}/{1}/releases/latest/download/{2}' -f $Owner, $Repo, $AssetName)
$branchUrl  = ('https://github.com/{0}/{1}/archive/refs/heads/{2}.zip' -f $Owner, $Repo, $Branch)

Write-Step '下载发布压缩包 ...'
$ok = Save-RemoteFile -Url $releaseUrl -Path $zip

if (-not $ok) {
    Write-Warn 'Releases 里没有找到压缩包，改从分支源码打包下载。'
    Write-Warn ('  ' + $branchUrl)
    $ok = Save-RemoteFile -Url $branchUrl -Path $zip
}

if (-not $ok) {
    Write-Err '下载失败。请检查网络（GitHub 在部分网络下不可达）。'
    Write-Warn '备选方案：用「压缩包安装」—— 手工下载 zip 解压后运行 一键运行.bat。'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($RunAsFile) { exit 1 } else { return }
}

Write-Ok ('已下载 {0:N0} KB' -f ((Get-Item -LiteralPath $zip).Length / 1KB))
Write-Host ''

# ---------------------------------------------------------------- 解压

Write-Step '解压 ...'
$stage = Join-Path $tmp 'stage'
try {
    Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force -ErrorAction Stop
} catch {
    Write-Err ('解压失败: ' + $_.Exception.Message)
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($RunAsFile) { exit 1 } else { return }
}

# Releases 压缩包是平铺的；分支源码压缩包外面套一层 Server-core-manager-main\。
# 靠入口文件定位真正的根目录，两种情况都能认。
$marker = Get-ChildItem -LiteralPath $stage -Recurse -Filter 'Start-GuiReadyApp.ps1' -File -ErrorAction SilentlyContinue |
          Sort-Object { $_.FullName.Length } | Select-Object -First 1
if (-not $marker) {
    Write-Err '压缩包里没有找到 Start-GuiReadyApp.ps1，文件可能不完整。'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($RunAsFile) { exit 1 } else { return }
}
$srcRoot = $marker.Directory.FullName
Write-Ok ('包根目录: ' + $srcRoot)
Write-Host ''

# ---------------------------------------------------------------- 安装

Write-Step ('安装到 ' + $Dest + ' ...')
if (-not (Test-Path -LiteralPath $Dest)) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
}

try {
    # 只覆盖、不删除：升级时保住 programs.json / logs / reports / state
    Copy-Item -Path (Join-Path $srcRoot '*') -Destination $Dest -Recurse -Force -ErrorAction Stop
} catch {
    Write-Err ('复制文件失败: ' + $_.Exception.Message)
    Write-Warn '如果提示文件被占用，请先关闭正在运行的本工具窗口再重试。'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($RunAsFile) { exit 1 } else { return }
}

# 从网上下来的 zip 会把文件标记为「来自 Internet」，PowerShell 默认拒绝运行这类脚本
Write-Step '解除文件锁定标记 ...'
$unblocked = 0
Get-ChildItem -LiteralPath $Dest -Recurse -Include '*.ps1', '*.bat', '*.cmd' -File -ErrorAction SilentlyContinue | ForEach-Object {
    try { Unblock-File -LiteralPath $_.FullName -ErrorAction Stop; $unblocked++ } catch { }
}
Write-Ok ('已解除 ' + $unblocked + ' 个文件')

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''

# ---------------------------------------------------------------- 一行命令

if (-not $NoCommand) {
    Write-Step ('安装一行命令 ' + $CommandName + ' ...')
    try {
        . (Join-Path $Dest 'lib\GuiReady.Common.ps1')
        . (Join-Path $Dest 'lib\GuiReady.Command.ps1')
        [void](Install-GuiReadyCommand -Name $CommandName)
    } catch {
        Write-Warn ('一行命令安装失败（不影响主程序）: ' + $_.Exception.Message)
    }
    Write-Host ''
}

# ---------------------------------------------------------------- 收尾

Write-Host '  ============================================================' -ForegroundColor Green
Write-Host '    安装完成' -ForegroundColor Green
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host ''
Write-Host ('    安装目录 : ' + $Dest) -ForegroundColor Gray
Write-Host ''
Write-Host '    接下来：' -ForegroundColor White
if (-not $NoCommand) {
    Write-Host ('      1) 在任意目录输入  ' + $CommandName + '  回车，打开图形界面') -ForegroundColor White
    Write-Host '         首次会弹一次提权确认（和 sconfig 一样）' -ForegroundColor DarkGray
} else {
    Write-Host ('      1) 运行  ' + (Join-Path $Dest '一键运行.bat')) -ForegroundColor White
}
Write-Host '      2) 在「环境」页点「一键补全」' -ForegroundColor White
Write-Host '         这会装官方 App Compatibility FOD（需要重启）' -ForegroundColor DarkGray
Write-Host '      3) 重启后回到「软件」页添加你的程序' -ForegroundColor White
Write-Host ''

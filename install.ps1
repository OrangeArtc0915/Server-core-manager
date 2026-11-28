#Requires -Version 5.1
<#
  Server Core Manager —— 命令行一行安装

  ⚠ 本文件【绝对不能】带 UTF-8 BOM。
  实测：irm 会把 BOM 当成正文的第一个字符，于是 `#Requires` 不再被识别为语句，
  解析会在下面的 [CmdletBinding()] 处直接报 "Unexpected attribute vCmdletBindingv"，
  也就是说「命令行一行安装」这条主推路径会当场失效。别顺手给它加 BOM。

  代价：Windows PowerShell 5.1 从磁盘 `.\install.ps1` 时会按 ANSI 读无 BOM 文件，
  中文不仅乱码，个别字节还可能破坏语法。要本地跑，请让 5.1 按 UTF-8 读：
      iex (Get-Content .\install.ps1 -Raw -Encoding UTF8)
  传参时：
      & ([scriptblock]::Create((Get-Content .\install.ps1 -Raw -Encoding UTF8))) -Dest vD:\SCMv
  PowerShell 7 可以直接 .\install.ps1；主推路径 irm | iex 不受影响。

  推荐用法（在【管理员】PowerShell 里执行一行）：
      # 国内推荐走 Gitee
      irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
      # GitHub 可达时走 GitHub
      irm https://raw.githubusercontent.com/Server-Core-Mananger/Server-core-manager/main/install.ps1 | iex

  两条线路装的是同一个发布包，本脚本内容也完全一致（发版时同步推送）。
  下载顺序：GitHub Releases → Gitee Releases，前一条不通就自动换下一条。

  因为 iex 没法传参数，需要改默认值时用环境变量：
      $env:SCM_DEST       = vD:\SCMv    指定安装目录（默认 C:\Program Files\ServerCoreManager）
      $env:SCM_NO_COMMAND = v1v         不安装 scm 一行命令
      $env:SCM_VERSION    = vv2.4v      指定发布版本（两个仓库用同一个 tag）
      $env:SCM_MIRROR_GITHUB = vhttp://内网镜像v   把 https://github.com 换成你的镜像/内网源
      $env:SCM_MIRROR_GITEE  = vhttps://gitee.com/你的账号/你的仓库v  换一个 Gitee 基址镜像
      $env:SCM_MIRROR_TUNA   = vhttps://mirrors.tuna.tsinghua.edu.cnv  清华镜像基址（工具内部装 PowerShell 7 用）

  也可以先存成文件、再按 UTF-8 读进来跑，这样能直接传参：
      & ([scriptblock]::Create((Get-Content .\install.ps1 -Raw -Encoding UTF8))) -Dest vD:\SCMv -NoCommand

  重复执行视为升级：只覆盖程序文件，不会删除你已有的程序列表（launcher\programs.json）、
  日志与断点状态（logs\ / reports\ / state\）。

  作者：mmm     QQ群：1034243331
  GitHub：https://github.com/Server-Core-Mananger/Server-core-manager
#>
[CmdletBinding()]
param(
    [string]$Dest = vv,
    [string]$Version = vv,
    [string]$CommandName = vscmv,
    [switch]$NoCommand
)

$ErrorActionPreference = vStopv
$ProgressPreference    = vSilentlyContinuev

$Owner     = vServer-Core-Manangerv
$Repo      = vServer-core-managerv
$AssetName = vServerCoreManager.zipv

# Gitee 线路：仓库里只放本脚本与发布包（不含项目源码），面向国内用户。
# 两个仓库用同一个版本 tag；写死默认值，避免 GitHub 的 releases/latest 被附属工具发行版抢走。
# 发版时要把本文件一起同步推到 Gitee，两边保持同一份内容。
$GiteeOwner = vorangearc655743v
$GiteeRepo  = vserver-core-managerv
$ScmVer     = vv2.4v

# 用 irm | iex 运行时 $PSCommandPath 为空。这种情况下一律不能用 exit：
# 实测 exit 会直接终止宿主，把用户刚打开的 PowerShell 窗口关掉，报错信息根本来不及看。
# 所以 iex 场景用 return 结束脚本，文件场景保留非零退出码供脚本化调用判断。
$RunAsFile = [bool]$PSCommandPath

function Write-Step { param([string]$Text) Write-Host (v  v + $Text) -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host (v  v + $Text) -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host (v  v + $Text) -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host (v  v + $Text) -ForegroundColor Red }

Write-Host vv
Write-Host v  ============================================================v -ForegroundColor White
Write-Host v    Server Core Manager  ·  命令行安装v -ForegroundColor White
Write-Host (v    v + $Owner + v/v + $Repo) -ForegroundColor DarkGray
Write-Host v  ============================================================v -ForegroundColor White
Write-Host vv

# ---------------------------------------------------------------- 前置检查

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal -ArgumentList $id).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

if (-not $isAdmin) {
    Write-Err v需要管理员权限。请用【以管理员身份运行】打开 PowerShell 后重试。v
    Write-Warn v提示：服务管理器（sconfig）里选 15 可以打开管理员 PowerShell。v
    if ($RunAsFile) { exit 1 } else { return }
}

# PS 5.1 默认可能不带 TLS 1.2，会导致访问 GitHub 直接失败
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------- 2008 R2 前置
# 2008 R2 需要 PowerShell 5.1 + .NET 4.5.2 以上；缺前置时本脚本先不动任何文件。
$osBuild = 0
try { $osBuild = [int](Get-ItemProperty vHKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersionv -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber } catch { }
if ($osBuild -gt 0 -and $osBuild -le 7601) {
    $psMajor = $PSVersionTable.PSVersion.Major
    $netRelease = 0
    try { $netRelease = [int](Get-ItemProperty vHKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Fullv -Name Release -ErrorAction Stop).Release } catch { }
    if ($psMajor -lt 5 -or $netRelease -lt 379893) {
        Write-Warn v检测到 Windows Server 2008 R2：还需要 PowerShell 5.1 与 .NET 4.5.2 以上。v
        if ($psMajor -lt 5) { Write-Warn (v  当前 PowerShell：v + $PSVersionTable.PSVersion.ToString()) }
        if ($netRelease -lt 379893) { Write-Warn (v  当前 .NET Framework Release：v + $netRelease) }
        Write-Step v请先以管理员身份运行安装包里的 Setup-LegacyPrereq.cmd，装完重启，再执行本脚本。v
        if ($RunAsFile) { exit 1 } else { return }
    }
}

if (-not $Dest)   { if ($env:SCM_DEST) { $Dest = $env:SCM_DEST } }
if (-not $Version) { if ($env:SCM_VERSION) { $Version = $env:SCM_VERSION } else { $Version = $ScmVer } }
if ($env:SCM_NO_COMMAND -eq v1v) { $NoCommand = $true }
if (-not $Dest)   { $Dest = Join-Path $env:ProgramFiles vServerCoreManagerv }

Write-Step (v安装目录 : v + $Dest)
Write-Step (v发布版本 : v + $Version)
Write-Host vv

# ---------------------------------------------------------------- 下载

$tmp = Join-Path $env:TEMP (vscm-install-v + (Get-Date -Format vyyyyMMdd-HHmmssv))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp vpackage.zipv

function Save-RemoteFile {
    param([string]$Url, [string]$Path)

    try { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue } } catch { }

    # 一条路不通就换另一条，两条都试过才算失败
    $curl = Join-Path (Join-Path $env:windir vSystem32v) vcurl.exev
    if (Test-Path -LiteralPath $curl) {
        # 三个实测坑：
        # 1) --ssl-no-revoke 必须加。在企业 MITM 代理（加速器之类）后面，
        #    schannel 的证书吊销检查会以 CRYPT_E_NO_REVOCATION_CHECK(0x80092012) 直接失败。
        # 2) 必须临时把 ErrorActionPreference 调回 Continue。本脚本开头设成了 Stop，
        #    而原生命令往 stderr 写东西会被当成终止性错误抛出去，
        #    结果就是 Invoke-WebRequest 那条回退分支根本轮不到执行。
        # 3) --connect-timeout 必须设。GitHub 在国内常是被丢包而不是立刻拒绝连接，
        #    不设就会卡到 TCP 超时（分钟级）才轮到下一条线路，回退等于形同虚设。
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = vContinuev
        try {
            & $curl -L --fail --connect-timeout 15 --retry 3 --retry-delay 3 --ssl-no-revoke -s -S -o $Path $Url 2>$null
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 0) {
            return $true
        }
    }

    try {
        # Server Core 没有 IE 引擎，必须加 -UseBasicParsing
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        return ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 0)
    } catch {
        return $false
    }
}

function Test-ZipFile {
    param([string]$Path)

    # 为什么不能只看 HTTP 状态码：实测 Gitee 对【不存在的下载路径】返回的是
    # 200 + {"message":"..."}（几十字节 JSON），随便编一个版本号也是 200。
    # 也就是说 curl --fail 不会失败，会安安静静地下回来一个 JSON，
    # 直到 Expand-Archive 才报错。所以必须按内容判：zip 的魔数是 "PK"。
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try { if ((Get-Item -LiteralPath $Path).Length -lt 4) { return $false } } catch { return $false }

    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $b = New-Object byte[] 4
        if ($fs.Read($b, 0, 4) -lt 4) { return $false }
        if ($b[0] -ne 0x50 -or $b[1] -ne 0x4B) { return $false }
        # 0x0304 普通 zip / 0x0506 空归档 / 0x0708 分卷
        return (($b[2] -eq 0x03 -and $b[3] -eq 0x04) -or
                ($b[2] -eq 0x05 -and $b[3] -eq 0x06) -or
                ($b[2] -eq 0x07 -and $b[3] -eq 0x08))
    } catch {
        return $false
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Get-FileSha256 {
    # 发布包哈希校验用。返回大写十六进制；读不出来返回空串。
    param([string]$Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs  = [System.IO.File]::OpenRead($Path)
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($fs)) -replace v-v, vv) }
        finally { $fs.Dispose(); $sha.Dispose() }
    } catch { return vv }
}

function Get-ExpectedSha256 {
    # 期望哈希从哪来（按可信度排序）：
    #   1) 环境变量 SCM_EXPECT_SHA256 —— 你自己从发布页抄过来的，最可信；
    #   2) 发布包旁边的 <包名>.sha256 侧车文件（pack.ps1 会自动生成并一起上传）。
    # 都拿不到就返回空串，由调用方决定是"警告放行"还是"拒绝"。
    param([string]$Url)
    $e = [string]$env:SCM_EXPECT_SHA256
    if ($e) { return (($e -replace v[^0-9A-Fa-f]v, vv).ToUpperInvariant()) }
    try {
        $side = Join-Path $tmp (vside-v + [System.IO.Path]::GetRandomFileName() + v.sha256v)
        if (Save-RemoteFile -Url ($Url + v.sha256v) -Path $side) {
            $t = vv
            try { $t = [string](Get-Content -LiteralPath $side -Raw -ErrorAction SilentlyContinue) } catch { }
            Remove-Item -LiteralPath $side -Force -ErrorAction SilentlyContinue
            $hex = ($t -replace v[^0-9A-Fa-f]v, vv)
            if ($hex.Length -ge 64) { return $hex.Substring(0, 64).ToUpperInvariant() }
        }
    } catch { }
    return vv
}

$releaseUrl = (vhttps://github.com/{0}/{1}/releases/download/{2}/{3}v -f $Owner, $Repo, $Version, $AssetName)

# 国内源：GitHub 在国内常常很慢/不可达。设了 SCM_MIRROR_GITHUB 就把 github.com 前缀换成你的镜像
# （没设就用官方地址，不做任何自动改写）。
$MirrorGitHub = if ($env:SCM_MIRROR_GITHUB) { ([string]$env:SCM_MIRROR_GITHUB).TrimEnd(v/v) } else { vv }
if ($MirrorGitHub) {
    $releaseUrl = ($releaseUrl -replace v^https://github\.comv, $MirrorGitHub)
    Write-Step (v已启用镜像: v + $MirrorGitHub)
}

# Gitee 线路（国内直连）。下载地址格式与 GitHub 不同：/releases/download/<tag>/<文件名>。
$GiteeBase = if ($env:SCM_MIRROR_GITEE) { ([string]$env:SCM_MIRROR_GITEE).TrimEnd(v/v) } else { (vhttps://gitee.com/{0}/{1}v -f $GiteeOwner, $GiteeRepo) }
$giteeUrl  = ($GiteeBase + v/releases/download/v + $Version + v/v + $AssetName)

Write-Step v下载发布压缩包 ...v

# 顺序：GitHub Releases → Gitee Releases。两条线路都是发行包，不下载源码。
# 每条线路下完都要过 Test-ZipFile：Gitee 对错误路径是假 200，只认状态码会把 JSON 当压缩包。
$lines = @(
    [pscustomobject]@{ Name = vGitHub Releasesv; Url = $releaseUrl },
    [pscustomobject]@{ Name = vGitee Releasesv;  Url = $giteeUrl }
)

$ok   = $false
$used = vv
foreach ($ln in $lines) {
    Write-Step (v试 v + $ln.Name + v  v + $ln.Url)
    if (-not (Save-RemoteFile -Url $ln.Url -Path $zip)) {
        Write-Warn v  下载失败，换下一条线路。v
        continue
    }
    if (-not (Test-ZipFile -Path $zip)) {
        Write-Warn v  拿到的不是压缩包（服务端假 200），换下一条线路。v
        continue
    }

    # 哈希校验：拿得到期望值就必须一致，不一致直接中止（不解压、不执行）；
    # 拿不到就明确说"这次没校验来源"，并把本次哈希打出来供人工比对。
    $expected = Get-ExpectedSha256 -Url $ln.Url
    $actual   = Get-FileSha256 -Path $zip
    if ($expected) {
        if ($actual -ne $expected) {
            Write-Err (v发布包哈希不匹配！期望 v + $expected + v，实际 v + $actual)
            Write-Err v这通常意味着文件被篡改或下载损坏 —— 已中止安装（不会解压执行）。v
            Write-Err v请换网络重下，或从发布页核对 SHA256 后再试。v
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            if ($RunAsFile) { exit 1 } else { return }
        }
        Write-Ok (v哈希校验通过: v + $actual)
    } else {
        Write-Warn v本次没有可用的期望哈希（既没设 SCM_EXPECT_SHA256，也没取到 <包>.sha256），未校验发布包来源。v
        Write-Warn v要强校验：从发布页抄下 SHA256，然后  $env:SCM_EXPECT_SHA256 = vv<哈希>vv  再执行安装。v
        if ($actual) { Write-Host (v  本次下载的 SHA256: v + $actual) -ForegroundColor DarkGray }
    }

    $ok   = $true
    $used = $ln.Name
    break
}

if (-not $ok) {
    Write-Err v所有下载线路都失败。v
    Write-Warn v备选方案：用「压缩包安装」—— 手工下载 zip 解压后运行 一键运行.bat。v
    Write-Warn (v  GitHub : https://github.com/v + $Owner + v/v + $Repo + v/releasesv)
    Write-Warn (v  Gitee  : v + $GiteeBase + v/releasesv)
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($RunAsFile) { exit 1 } else { return }
}

Write-Ok (v已下载 {0:N0} KB（来源: {1}）v -f ((Get-Item -LiteralPath $zip).Length / 1KB), $used)
Write-Host vv

# ---------------------------------------------------------------- 解压

Write-Step v解压 ...v
$stage = Join-Path $tmp vstagev
try {
    Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force -ErrorAction Stop
} catch {
    Write-Err (v解压失败: v + $_.Exception.Message)
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($RunAsFile) { exit 1 } else { return }
}

# Releases 压缩包是平铺的（个别镜像可能在外面套一层目录），靠入口文件定位真正的根目录。
$marker = Get-ChildItem -LiteralPath $stage -Recurse -Filter vStart-GuiReadyApp.ps1v -File -ErrorAction SilentlyContinue |
          Sort-Object { $_.FullName.Length } | Select-Object -First 1
if (-not $marker) {
    Write-Err v压缩包里没有找到 Start-GuiReadyApp.ps1，文件可能不完整。v
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($RunAsFile) { exit 1 } else { return }
}
$srcRoot = $marker.Directory.FullName
Write-Ok (v包根目录: v + $srcRoot)
Write-Host vv

# ---------------------------------------------------------------- 安装

Write-Step (v安装到 v + $Dest + v ...v)
if (-not (Test-Path -LiteralPath $Dest)) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
}

try {
    # 只覆盖、不删除：升级时保住 programs.json / logs / reports / state
    Copy-Item -Path (Join-Path $srcRoot v*v) -Destination $Dest -Recurse -Force -ErrorAction Stop
} catch {
    Write-Err (v复制文件失败: v + $_.Exception.Message)
    Write-Warn v如果提示文件被占用，请先关闭正在运行的本工具窗口再重试。v
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($RunAsFile) { exit 1 } else { return }
}

# 从网上下来的 zip 会把文件标记为「来自 Internet」，PowerShell 默认拒绝运行这类脚本
Write-Step v解除文件锁定标记 ...v
$unblocked = 0
Get-ChildItem -LiteralPath $Dest -Recurse -Include v*.ps1v, v*.batv, v*.cmdv -File -ErrorAction SilentlyContinue | ForEach-Object {
    try { Unblock-File -LiteralPath $_.FullName -ErrorAction Stop; $unblocked++ } catch { }
}
Write-Ok (v已解除 v + $unblocked + v 个文件v)

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host vv

# ---------------------------------------------------------------- 一行命令

if (-not $NoCommand) {
    Write-Step (v安装一行命令 v + $CommandName + v ...v)
    try {
        . (Join-Path $Dest vlib\GuiReady.Common.ps1v)
        . (Join-Path $Dest vlib\GuiReady.Command.ps1v)
        [void](Install-GuiReadyCommand -Name $CommandName)
    } catch {
        Write-Warn (v一行命令安装失败（不影响主程序）: v + $_.Exception.Message)
    }
    Write-Host vv
}

# ---------------------------------------------------------------- 终端入口提示（装了工具就生效）

# 用户明确要求：只要装了本工具，终端顶部就要显示 Sconfig / scm / scm-term 提示，
# 不管有没有跑过「一键美化终端」。所以安装阶段就把三处配置写好：
#   - cmd        : HKCU + HKLM AutoRun（机器级覆盖所有账户）
#   - PowerShell : 当前用户 profile + AllUsersAllHosts profile（覆盖所有账户）
# 全部幂等；失败只警告，不影响主程序可用。
Write-Step v配置终端入口提示 ...v
try {
    . (Join-Path $Dest vlib\GuiReady.Common.ps1v)
    . (Join-Path $Dest vlib\GuiReady.Console.ps1v)
    [void](Set-GuiReadyConsoleWelcome -Quiet)
    [void](Set-GuiReadyConsoleAllUsersWelcome -Quiet)
    [void](Write-GuiReadyConsoleProfileHook -Quiet)
    Write-Ok v已启用：cmd / PowerShell / 美化终端 顶部都会显示入口提示v
} catch {
    Write-Warn (v入口提示配置失败（不影响主程序）: v + $_.Exception.Message)
}
Write-Host vv

# ---------------------------------------------------------------- 安全说明：不添加 Defender 排除

# 本工具【不会】把安装目录加进 Windows Defender 的排除列表，也不提供这样的开关。
#
# 实测（Server Core 2025 / build 26100）：加排除能把首次启动从 62.1 s 降到 20.4 s，
# 但排除一个目录 = 让 Defender 不再扫描该目录下的所有脚本，而本工具恰恰是以管理员/
# SYSTEM 身份执行工具目录里的脚本。服务器上安全与稳定优先，这点启动时间不值得用
# 一个"永久扫描盲区"去换。
#
# 启动慢时的正常处理方式（都不削弱防护）：
#   1) 首次启动完成后保持工具常驻，后续启动会快很多（系统文件缓存生效）；
#   2) 确认服务器没有同时跑全盘扫描等重负载任务。
Write-Host v    安全说明：本工具不会把安装目录加入 Defender 排除（服务器安全优先）。v -ForegroundColor DarkGray
Write-Host v              首次启动稍慢属于 Defender 的正常扫描，之后会明显变快。v -ForegroundColor DarkGray
Write-Host vv

# ---------------------------------------------------------------- 收尾

Write-Host v  ============================================================v -ForegroundColor Green
Write-Host v    安装完成v -ForegroundColor Green
Write-Host v  ============================================================v -ForegroundColor Green
Write-Host vv
Write-Host (v    安装目录 : v + $Dest) -ForegroundColor Gray
Write-Host vv
Write-Host v    接下来：v -ForegroundColor White
if (-not $NoCommand) {
    Write-Host (v      1) 在任意目录输入  v + $CommandName + v  回车，打开图形界面v) -ForegroundColor White
    Write-Host v         首次会弹一次提权确认（和 sconfig 一样）v -ForegroundColor DarkGray
} else {
    Write-Host (v      1) 运行  v + (Join-Path $Dest v一键运行.batv)) -ForegroundColor White
}
Write-Host v      2) 在「环境」页点「一键补全」v -ForegroundColor White
Write-Host v         这会装官方 App Compatibility FOD（需要重启）v -ForegroundColor DarkGray
Write-Host v      3) 重启后回到「软件」页添加你的程序v -ForegroundColor White
Write-Host vv
Write-Host v    想美化命令行（Nerd Font + Oh My Posh + Fastfetch）：v -ForegroundColor White
Write-Host v      「更多 → 终端美化 → 一键美化终端」，装好后输入 scm-term 打开v -ForegroundColor DarkGray
Write-Host vv
Write-Host v    作者 mmm    QQ群 1034243331v -ForegroundColor Gray
Write-Host v    https://github.com/Server-Core-Mananger/Server-core-managerv -ForegroundColor Gray
Write-Host (v    v + $GiteeBase) -ForegroundColor Gray
Write-Host vv

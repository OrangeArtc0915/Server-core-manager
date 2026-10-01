# GuiReady common helpers: logging, privilege check, JSON report, backup

$script:GuiReadyRoot = Split-Path -Parent $PSScriptRoot
$script:LogDir       = Join-Path $script:GuiReadyRoot 'logs'
$script:ReportDir    = Join-Path $script:GuiReadyRoot 'reports'
$script:BackupDir    = Join-Path $script:GuiReadyRoot 'backup'

foreach ($d in @($script:LogDir, $script:ReportDir, $script:BackupDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

if (-not $Global:GuiReadyLogFile) {
    $Global:GuiReadyLogFile = Join-Path $script:LogDir ('guiready-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Write-Log {
    param(
        [Parameter(Position = 0)][string]$Message = '',
        [Parameter(Position = 1)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DRY', 'HEAD')][string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message

    $color = 'Gray'
    switch ($Level) {
        'OK'    { $color = 'Green' }
        'WARN'  { $color = 'Yellow' }
        'ERROR' { $color = 'Red' }
        'STEP'  { $color = 'Cyan' }
        'DRY'   { $color = 'Magenta' }
        'HEAD'  { $color = 'White' }
    }
    Write-Host $line -ForegroundColor $color

    try { Add-Content -LiteralPath $Global:GuiReadyLogFile -Value $line -Encoding UTF8 } catch { }
}

function Write-Head {
    param([Parameter(Position = 0)][string]$Title)
    Write-Log ''
    Write-Log ('=' * 62) 'HEAD'
    Write-Log ('  ' + $Title) 'HEAD'
    Write-Log ('=' * 62) 'HEAD'
}

function Test-IsAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal -ArgumentList $id
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-Administrator {
    if (Test-IsAdministrator) { return $true }
    Write-Log '当前不是管理员权限，该操作无法进行。请用“以管理员身份运行”重开。' 'ERROR'
    return $false
}

function Request-GuiReadyElevation {
    # 以管理员身份重启自己。返回值（调用方按这个决定下一步）：
    #   'Admin'      —— 当前已经是管理员，正常往下跑
    #   'Relaunched' —— 已拉起提权进程，调用方**必须立刻 return**（别在普通权限下再开一份）
    #   'Failed'     —— 提不起来（UAC 被取消 / 标准用户没输密码 / 被策略挡住），调用方自己决定怎么办
    #
    # 为什么这件事必须在 PowerShell 里做、不能留在 .bat 里（三个都实测/已知的坑）：
    #   1. cmd 只能看到 Start-Process 的返回码，而 UAC 被取消时这个返回码并不可靠 ——
    #      用户看到的只有"窗口闪一下、什么都没发生"，连原因都拿不到；
    #   2. PowerShell 里 Start-Process -Verb RunAs 失败会**抛异常**
    #      （例如 "The operation was canceled by the user"），能拿到准确原因；
    #   3. 只有拿到原因，才能退一步：**用普通权限照样把界面打开**（只读功能可用），
    #      而不是让用户"双击了打不开"。
    # 每次尝试都写一行到 logs\launcher.log —— 万一还是起不来，这个文件就是证据。
    param(
        [string]$EntryScript = '',
        [string]$What = '本工具'
    )

    if (Test-IsAdministrator) { return 'Admin' }

    # 调用方一般会显式传 -EntryScript $PSCommandPath；$PSCommandPath 在函数里也能取到
    # （它是脚本级自动变量），所以这里再兜一次，免得漏传时静默失败。
    if (-not $EntryScript) {
        try { $EntryScript = [string]$PSCommandPath } catch { }
    }

    $root = ''
    if ($EntryScript) { try { $root = Split-Path -Parent $EntryScript } catch { } }
    if (-not $root) { $root = [string]$script:GuiReadyRoot }
    # 日志路径要能容错：入口脚本路径万一不可用（盘符不存在等），也别让"写日志"本身炸掉，
    # 退回模块自己的 logs 目录。
    $log = ''
    try {
        $dir = Join-Path $root 'logs'
        $log = Join-Path $dir 'launcher.log'
    } catch { }
    if (-not $log) {
        try {
            $dir = [string]$script:LogDir
            if (-not $dir) { $dir = Join-Path $env:TEMP 'scm-logs' }
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $log = Join-Path $dir 'launcher.log'
        } catch { $log = '' }
    }

    Write-Host ''
    Write-Host ('  {0} 需要管理员权限（补环境、装软件、改服务都要）。' -f $What) -ForegroundColor Yellow
    Write-Host '  正在请求提权，请在弹出的 UAC 窗口里点「是」…' -ForegroundColor Yellow

    if (-not $EntryScript -or -not (Test-Path -LiteralPath $EntryScript)) {
        Write-Host ('  [X] 找不到入口脚本，没法提权重启: ' + $EntryScript) -ForegroundColor Red
        try { Add-Content -LiteralPath $log -Value ('{0} [ERROR] 入口脚本不存在: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $EntryScript) -Encoding UTF8 } catch { }
        return 'Failed'
    }

    try {
        # 路径带空格时 -ArgumentList 不会自动加引号，所以要自己加上；
        # 同时用 -WorkingDirectory 兜一层 —— 两种手段都给上，尽量不依赖子进程的初始工作目录。
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ErrorAction Stop `
            -WorkingDirectory $root `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $EntryScript + '"')) | Out-Null
        try { Add-Content -LiteralPath $log -Value ('{0} [OK] 已请求提权重启: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $EntryScript) -Encoding UTF8 } catch { }
        Write-Host '  提权进程已启动（新窗口），本窗口可以关掉了。' -ForegroundColor Gray
        return 'Relaunched'
    } catch {
        $msg = [string]$_.Exception.Message
        try { Add-Content -LiteralPath $log -Value ('{0} [WARN] 提权失败: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
        Write-Host ''
        Write-Host ('  [!] 提权失败：' + $msg) -ForegroundColor Red
        Write-Host '      常见原因：UAC 窗口里点了「否」；或者当前是标准用户（弹出来的是「输入管理员密码」）。' -ForegroundColor Yellow
        return 'Failed'
    }
}

function Get-GuiReadyLogFile { return $Global:GuiReadyLogFile }

# ============================ 下载源（国内镜像优先）============================
# 2026-09 实测结论，别凭印象改：
#   - 清华 TUNA 的 github-release 镜像里【确实有】PowerShell 的 Release 资产
#     （https://mirrors.tuna.tsinghua.edu.cn/github-release/PowerShell/PowerShell/LatestRelease/）
#   - 清华 / 阿里云【没有】.NET 运行时、oh-my-posh、fastfetch 的镜像：
#     路径要么 404，要么返回镜像站门户页（HTML），不是真文件
#   - 微软官方 CDN 在国内直连可用：测试机上实测 aka.ms ≈ 720 KB/s、builds.dotnet.microsoft.com ≈ 470 KB/s
#   - 所以：能内置就内置（终端美化素材随发布包分发，安装不联网）；
#     PowerShell 7 走清华；其余保持官方地址。
# 想接自己的内网源，设这两个环境变量即可：
#   SCM_MIRROR_GITHUB = 替换 https://github.com 前缀（内网 GitHub 代理）
#   SCM_MIRROR_TUNA   = 替换清华镜像基址（默认 https://mirrors.tuna.tsinghua.edu.cn）
$Global:GuiReadyMirrorTuna = if ($env:SCM_MIRROR_TUNA) { ([string]$env:SCM_MIRROR_TUNA).TrimEnd('/') } else { 'https://mirrors.tuna.tsinghua.edu.cn' }
$Global:GuiReadyMirrorGithub = if ($env:SCM_MIRROR_GITHUB) { ([string]$env:SCM_MIRROR_GITHUB).TrimEnd('/') } else { '' }
$Global:GuiReadyMirrorDotNet = if ($env:SCM_MIRROR_DOTNET) { ([string]$env:SCM_MIRROR_DOTNET).TrimEnd('/') } else { '' }

function Get-GuiReadyDownloadUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [switch]$PreferOfficial
    )
    if ($PreferOfficial) { return $Url }
    # PowerShell 的 GitHub Release → 清华镜像（实测可用）
    if ($Url -match '^https://github\.com/PowerShell/PowerShell/releases/download/([^/]+)/(.+)$') {
        return ('{0}/github-release/PowerShell/PowerShell/{1}/{2}' -f $Global:GuiReadyMirrorTuna, $Matches[1], $Matches[2])
    }
    # 其它 GitHub 地址 → 用户自建镜像（若配了 SCM_MIRROR_GITHUB）
    if ($Global:GuiReadyMirrorGithub -and $Url -match '^https://github\.com/') {
        return ($Url -replace '^https://github\.com', $Global:GuiReadyMirrorGithub)
    }
    # .NET 运行时：国内镜像站没有（实测 404/门户页），官方 CDN 国内实测 ~470 KB/s；
    # 如果要走内网源，用 SCM_MIRROR_DOTNET 替换 https://builds.dotnet.microsoft.com/dotnet 前缀
    if ($Global:GuiReadyMirrorDotNet -and $Url -match '^https://builds\.dotnet\.microsoft\.com/dotnet') {
        return ($Url -replace '^https://builds\.dotnet\.microsoft\.com/dotnet', $Global:GuiReadyMirrorDotNet)
    }
    return $Url
}

function Get-GuiReadyCurlPath {
    $c = Join-Path (Join-Path $env:windir 'System32') 'curl.exe'
    if (Test-Path -LiteralPath $c) { return $c }
    return 'curl.exe'
}

function Get-GuiReadyPowerShell7Latest {
    # 从清华镜像的 LatestRelease 目录取 x64 zip 名（顺带拿到版本号），不依赖 GitHub API（避开限流）
    $o = [ordered]@{ Ok = $false; Version = ''; Name = ''; Url = ''; FromMirror = $false; Note = '' }
    $idxUrl = '{0}/github-release/PowerShell/PowerShell/LatestRelease/' -f $Global:GuiReadyMirrorTuna
    try {
        $txt = (& (Get-GuiReadyCurlPath) -sL --ssl-no-revoke --max-time 30 $idxUrl 2>$null | Out-String)
        $m = [regex]::Match($txt, 'PowerShell-([\d\.]+)-win-x64\.zip')
        if ($m.Success) {
            $o.Version = $m.Groups[1].Value
            $o.Name = $m.Value
            $o.Url = $idxUrl + $o.Name
            $o.Ok = $true
            $o.FromMirror = $true
            $o.Note = '来自清华镜像 ' + $o.Name
            return [pscustomobject]$o
        }
        $o.Note = '清华镜像索引里没解析到 PowerShell-<版本>-win-x64.zip'
    } catch {
        $o.Note = '查询清华镜像失败: ' + $_.Exception.Message
    }
    # 回退：GitHub 官方（若配了 SCM_MIRROR_GITHUB 则走内网源）
    try {
        $api = Get-GuiReadyDownloadUrl -Url 'https://github.com/PowerShell/PowerShell'
        if ($api -notmatch '^https://github\.com') {
            $o.Note = $o.Note + '；已配置 SCM_MIRROR_GITHUB，但内网源无法自动探测版本，请手动指定 -Url'
            return [pscustomobject]$o
        }
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'ServerCoreManager' } -TimeoutSec 40
        $asset = @($rel.assets | Where-Object { $_.name -match '^PowerShell-[\d\.]+-win-x64\.zip$' } | Select-Object -First 1)
        if ($asset.Count -gt 0) {
            $o.Version = [string]$rel.tag_name
            $o.Name = [string]$asset[0].name
            $o.Url = [string]$asset[0].browser_download_url
            $o.Ok = $true
            $o.FromMirror = $false
            $o.Note = '清华镜像不可用，改用 GitHub 官方 ' + $o.Name
        } else {
            $o.Note = $o.Note + '；GitHub 官方也没有找到 x64 zip'
        }
    } catch {
        $o.Note = $o.Note + '；GitHub 官方查询失败: ' + $_.Exception.Message
    }
    return [pscustomobject]$o
}


function Save-JsonReport {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path  = Join-Path $script:ReportDir ('{0}-{1}.json' -f $Name, $stamp)
    try {
        $json = $Object | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($true)))
        Write-Log ('报告已保存: ' + $path) 'OK'
    } catch {
        Write-Log ('报告保存失败: ' + $_.Exception.Message) 'ERROR'
        return $null
    }
    return $path
}

function Invoke-Capture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $out  = & $FilePath @ArgumentList 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $code
        Output   = ($out | Out-String)
    }
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
    )
    foreach ($k in $keys) {
        if (Test-Path $k) { return $true }
    }
    return $false
}

function Get-RegValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    try {
        $v = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        return $v
    } catch {
        return $null
    }
}

function Get-RegValueNames {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $item = Get-Item -Path $Path -ErrorAction Stop
        return @($item.GetValueNames())
    } catch {
        return @()
    }
}

function New-GuiReadyBackup {
    param([Parameter(Mandatory = $true)][string]$Tag)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir   = Join-Path $script:BackupDir ('{0}-{1}' -f $Tag, $stamp)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $targets = @(
        'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon',
        'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services',
        'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server',
        'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    )
    foreach ($t in $targets) {
        $short = ($t -split '\\')[-1]
        $file  = Join-Path $dir ($short + '.reg')
        $r = Invoke-Capture 'reg.exe' @('export', $t, $file, '/y')
        if ($r.ExitCode -ne 0) {
            Write-Log ('注册表备份失败（可能键不存在）: ' + $t) 'WARN'
        }
    }

    Write-Log ('备份目录: ' + $dir) 'OK'
    return $dir
}

function Format-Bool {
    param($Value)
    if ($null -eq $Value) { return '未知' }
    if ($Value) { return '是' }
    return '否'
}

function Add-CheckResult {
    param(
        [Parameter(Mandatory = $true)]$List,
        [Parameter(Mandatory = $true)][string]$Item,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Detail = '',
        [string]$Fixability = ''
    )
    $List.Add([pscustomobject]@{
        Item       = $Item
        Status     = $Status
        Detail     = $Detail
        Fixability = $Fixability
    }) | Out-Null
}

function Test-GuiReadyAccessDenied {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($p in @('拒绝访问', 'Access is denied', 'Access Denied', '0x80070005', 'ERROR_ACCESS_DENIED')) {
        if ($Text -match [regex]::Escape($p)) { return $true }
    }
    return $false
}

function Get-GuiReadyExecutionContext {
    $o = [ordered]@{
        SessionId     = -1
        UserInteractive = $true
        IsSystem      = $false
        Note          = ''
    }
    try { $o.SessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch { }
    try { $o.UserInteractive = [Environment]::UserInteractive } catch { }
    try { $o.IsSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') } catch { }

    if ($o.IsSystem) {
        $o.Note = 'SYSTEM 上下文'
    } elseif ($o.SessionId -eq 0) {
        $o.Note = 'Session 0（远程/WinRM/服务上下文）：DISM 在线服务操作可能被拒绝，工具会自动改走提权计划任务'
    } else {
        $o.Note = '交互式会话（Session ' + $o.SessionId + '）'
    }
    return [pscustomobject]$o
}

function Get-GuiReadyPreamble {
    $root = $script:GuiReadyRoot
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Set-Location '$root'")
    foreach ($m in @('GuiReady.Common.ps1', 'GuiReady.Detect.ps1', 'GuiReady.PeInspect.ps1',
                     'GuiReady.Fod.ps1', 'GuiReady.GuiShell.ps1', 'GuiReady.RdpFix.ps1',
                     'GuiReady.DotNet.ps1', 'GuiReady.GuiTest.ps1', 'GuiReady.Matrix.ps1',
                     'GuiReady.Diag.ps1', 'GuiReady.Catalog.ps1', 'GuiReady.Pipeline.ps1',
                     'GuiReady.AutoLogon.ps1', 'GuiReady.Command.ps1', 'GuiReady.PhaseB.ps1', 'GuiReady.Wac.ps1',
                     'GuiReady.Console.ps1')) {
        [void]$sb.AppendLine(". '$root\lib\$m'")
    }
    return $sb.ToString()
}

function Test-GuiReadyToolDirSafe {
    # 判断「工具目录是否只有管理员能写」。
    #
    # 为什么这件事是安全前提：本工具的一切都以**管理员/SYSTEM**身份执行 ——
    #   lib\ / gui\ 下的脚本由提权后的界面拉起；
    #   logs\elevated\worker-*.ps1 会注册成 SYSTEM 计划任务执行；
    #   bin\scm-welcome.cmd 被 cmd 的 AutoRun 挂在**每个** cmd 窗口上。
    # 所以只要普通用户能往工具目录里写文件，他就能替换掉上面任何一个，从而拿到管理员/SYSTEM 权限。
    # 安装到 C:\Program Files 下是安全的；解压到桌面/下载目录再以管理员运行就不安全。
    param([string]$Path)

    $risky = @()
    $ok = $true
    try {
        $acl = Get-Acl -LiteralPath $Path
        # 允许写的主体里，除了下面这些，其余都算危险
        $safeSids = @(
            'S-1-5-18',      # SYSTEM
            'S-1-5-32-544',  # Administrators
            'S-1-3-0',       # CREATOR OWNER
            'S-1-3-4',       # OWNER RIGHTS
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'  # TrustedInstaller
        )
        try { $safeSids += [string]([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) } catch { }

        foreach ($rule in @($acl.Access)) {
            if ([string]$rule.AccessControlType -ne 'Allow') { continue }
            # 用字符串判断权限位：枚举的 ToString() 会给出 Modify / WriteData / FullControl 这类名字，
            # 比按位与组合枚举更直观，也不容易漏。
            if (([string]$rule.FileSystemRights) -notmatch 'Write|Modify|FullControl|Delete|ChangePermissions|TakeOwnership') { continue }
            $sid = ''
            try { $sid = [string]$rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = '' }
            if ($sid -and ($safeSids -contains $sid)) { continue }
            $ok = $false
            $risky += ('{0}（{1}）' -f $rule.IdentityReference, $(if ($sid) { $sid } else { '未知 SID' }))
        }
    } catch {
        return [pscustomobject]@{ Safe = $false; Known = $false; Reason = ('读不到目录 ACL: ' + $_.Exception.Message); Risky = @() }
    }

    $reason = ''
    if (-not $ok) {
        $reason = ('以下主体对工具目录有写权限: {0}' -f ($risky -join '、'))
    }
    return [pscustomobject]@{ Safe = $ok; Known = $true; Reason = $reason; Risky = $risky }
}

function Protect-GuiReadyDir {
    # 去掉继承、只留 SYSTEM 与 Administrators。用固定 SID 写，不受系统语言影响。
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        & icacls $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Get-GuiReadyElevatedWorkDir {
    # 以 SYSTEM/管理员身份执行的 worker 脚本放哪。
    # 默认放工具目录的 logs\elevated（可携带、好排查），**前提是工具目录只有管理员能写**；
    # 若工具目录普通用户可写（解压到桌面/下载目录再提权运行这种），就换 %ProgramData%：
    # 那里默认 ACL 只允许管理员与 SYSTEM 写，普通用户改不了我们的 worker。
    $toolRoot = Split-Path -Parent $PSScriptRoot
    $def = Join-Path (Join-Path $toolRoot 'logs') 'elevated'
    $safe = Test-GuiReadyToolDirSafe -Path $toolRoot
    if ($safe.Safe -and $safe.Known) {
        if (-not (Test-Path -LiteralPath $def)) { New-Item -ItemType Directory -Path $def -Force | Out-Null }
        [void](Protect-GuiReadyDir -Path $def)
        return $def
    }

    Write-Log ('工具目录不是管理员独占（{0}）—— 提权 worker 改用 %ProgramData% 存放。' -f $safe.Reason) 'WARN'
    $alt = Join-Path (Join-Path $env:ProgramData 'ServerCoreManager') 'elevated'
    try {
        if (-not (Test-Path -LiteralPath $alt)) { New-Item -ItemType Directory -Path $alt -Force | Out-Null }
        [void](Protect-GuiReadyDir -Path $alt)
    } catch { }
    return $alt
}

function Invoke-GuiReadyElevatedTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Body,
        [int]$TimeoutSeconds = 3600,
        [int]$PollSeconds = 15,
        [string]$AsUser = ''
    )

    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    # worker 目录：优先工具目录下的 logs\elevated，工具目录不安全时自动改用 %ProgramData%
    # （见 Get-GuiReadyElevatedWorkDir 的说明）—— 这个目录里的脚本是**以 SYSTEM 运行的**。
    $workDir = Get-GuiReadyElevatedWorkDir
    if (-not (Test-Path -LiteralPath $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

    # 文件名不可预测：抢在写入之前抢先占位同名文件、或猜名字替换内容，都是提权路径上的典型手法
    $rand    = [System.IO.Path]::GetRandomFileName()
    $worker  = Join-Path $workDir ('worker-{0}-{1}-{2}.ps1'    -f $Name, $stamp, $rand)
    $logFile = Join-Path $workDir ('worker-{0}-{1}-{2}.log'    -f $Name, $stamp, $rand)
    $resFile = Join-Path $workDir ('worker-{0}-{1}-{2}.result' -f $Name, $stamp, $rand)

    $workerContent = @"
`$ErrorActionPreference = 'Continue'
try {
    & {
$Body
    } *>&1 | Out-File -FilePath '$logFile' -Encoding UTF8
    'EXIT=OK' | Out-File -FilePath '$resFile' -Encoding UTF8
} catch {
    ('EXIT=FAIL ' + `$_.Exception.Message) | Out-File -FilePath '$logFile' -Encoding UTF8 -Append
    ('EXIT=FAIL ' + `$_.Exception.Message) | Out-File -FilePath '$resFile' -Encoding UTF8
}
"@
    [System.IO.File]::WriteAllText($worker, $workerContent, (New-Object System.Text.UTF8Encoding -ArgumentList $true))

    # 写完后复核：文件真的存在、非空，且只有管理员/SYSTEM 能改 —— 否则宁可不注册计划任务，
    # 也不要把一个可能被人替换过的脚本交给 SYSTEM 执行。
    try {
        $fi = Get-Item -LiteralPath $worker -ErrorAction Stop
        if ($fi.Length -lt 10) { Write-Log '提权 worker 脚本内容异常（过短），已中止。' 'ERROR'; return [pscustomobject]@{ Result = 'FAIL worker 脚本异常'; Log = ''; LogFile = ''; TimedOut = $false; WorkerScript = $worker } }
        $aclChk = Get-Acl -LiteralPath $worker
        foreach ($rule in @($aclChk.Access)) {
            if ([string]$rule.AccessControlType -ne 'Allow') { continue }
            if (([string]$rule.FileSystemRights) -notmatch 'Write|Modify|FullControl') { continue }
            $sid = ''
            try { $sid = [string]$rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { }
            if ($sid -and $sid -notin @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-3-4')) {
                Write-Log ('提权 worker 脚本可被 {0} 修改，已中止（这会变成普通用户提权到 SYSTEM 的入口）。' -f $rule.IdentityReference) 'ERROR'
                return [pscustomobject]@{ Result = 'FAIL worker 脚本权限不安全'; Log = ''; LogFile = ''; TimedOut = $false; WorkerScript = $worker }
            }
        }
    } catch {
        Write-Log ('提权 worker 复核失败: ' + $_.Exception.Message) 'ERROR'
        return [pscustomobject]@{ Result = 'FAIL worker 复核失败'; Log = ''; LogFile = ''; TimedOut = $false; WorkerScript = $worker }
    }

    $taskName = 'GuiReadyElevated-' + $Name
    if ($AsUser) { $taskName = 'GuiReadyInteractive-' + $Name }
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $worker)
        if ($AsUser) {
            $prin = New-ScheduledTaskPrincipal -UserId $AsUser -LogonType Interactive -RunLevel Highest
        } else {
            $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        }
        $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 600))
        Register-ScheduledTask -TaskName $taskName -Action $act -Principal $prin -Settings $set -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
    } catch {
        Write-Log ('创建计划任务失败: ' + $_.Exception.Message) 'ERROR'
        return [pscustomobject]@{ Result = 'FAIL 无法创建计划任务'; Log = ''; LogFile = ''; TimedOut = $false; WorkerScript = $worker }
    }

    if ($AsUser) {
        Write-Log ('已在用户交互会话中执行（{0} / Interactive / Highest）: {1}' -f $AsUser, $taskName) 'STEP'
    } else {
        Write-Log ('已改用提权计划任务执行（SYSTEM / 最高权限）: ' + $taskName) 'STEP'
    }
    Write-Log ('长时间操作，请耐心等待。每 {0} 秒检查一次，上限 {1} 分钟。' -f $PollSeconds, [int]($TimeoutSeconds / 60)) 'INFO'

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastNote = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        if (Test-Path -LiteralPath $resFile) { break }

        $state = ''
        try { $state = [string](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State } catch { }
        $logSize = 0
        try { $logSize = (Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue).Length } catch { }

        $note = ('任务状态={0}  日志={1} 字节' -f $state, $logSize)
        if ($note -ne $lastNote) {
            Write-Log ('  ' + $note) 'INFO'
            $lastNote = $note
        }
        if ($state -eq '' -or $state -eq 'Ready') {
            Start-Sleep -Seconds 3
            if (Test-Path -LiteralPath $resFile) { break }
        }
    }

    $result = 'TIMEOUT'
    if (Test-Path -LiteralPath $resFile) {
        try { $result = ([string](Get-Content -LiteralPath $resFile -Raw)).Trim() } catch { $result = 'UNKNOWN' }
    }
    $log = ''
    try { $log = [string](Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue) } catch { }

    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }

    # 内容已经读进内存（Log / Result），磁盘上的三件套（worker 脚本、日志、结果）全部销毁：
    # worker 脚本可能含敏感值（自动登录密码就在里面），日志/结果也没必要留在服务器上。
    foreach ($f in @($worker, $logFile, $resFile)) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
    }

    return [pscustomobject]@{
        Result       = $result
        Log          = $log
        LogFile      = $logFile
        TimedOut     = ($result -eq 'TIMEOUT')
        WorkerScript = $worker
    }
}

function Get-GuiReadyUac {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $o = [ordered]@{
        EnableLUA                  = Get-RegValue $k 'EnableLUA'
        ConsentPromptBehaviorAdmin = Get-RegValue $k 'ConsentPromptBehaviorAdmin'
        PromptOnSecureDesktop      = Get-RegValue $k 'PromptOnSecureDesktop'
        FilterAdministratorToken   = Get-RegValue $k 'FilterAdministratorToken'
        PendingReboot              = $false
        PromptsWillBlock           = $false
        Note                       = ''
    }
    if ($null -eq $o.EnableLUA) { $o.EnableLUA = 1 }
    if ($null -eq $o.ConsentPromptBehaviorAdmin) { $o.ConsentPromptBehaviorAdmin = 5 }
    if ($null -eq $o.PromptOnSecureDesktop) { $o.PromptOnSecureDesktop = 1 }

    if ($o.EnableLUA -eq 0) {
        $o.PromptsWillBlock = $false
        $o.Note = 'UAC 已完全关闭：带 requireAdministrator 清单的程序会直接以完整令牌启动，不会弹窗'
    } elseif ($o.ConsentPromptBehaviorAdmin -eq 0) {
        $o.PromptsWillBlock = $false
        $o.Note = 'ConsentPromptBehaviorAdmin=0：管理员会静默提权，不弹窗（这是为自动化临时改过的常见状态，注意安全影响）'
    } else {
        $o.PromptsWillBlock = $true
        $o.Note = ('UAC 会弹提权确认窗（ConsentPromptBehaviorAdmin={0}, PromptOnSecureDesktop={1}）。远程/无人值守下无法点确认，带 requireAdministrator 的安装器会报“操作已被用户取消”' -f $o.ConsentPromptBehaviorAdmin, $o.PromptOnSecureDesktop)
    }
    return [pscustomobject]$o
}

function Get-GuiReadySessionInfo {
    $raw = @()
    try { $raw = @(& query.exe session 2>&1 | ForEach-Object { [string]$_ }) } catch { }

    # 用表头的列位置切分，而不是按空格切分。
    # 原因：会话名为空的行（例如用户直接登录 console 时那一行）会让“用户名”落到第一列，
    # 按空格切分就会把用户名当成会话名，从而漏掉真实登录会话。
    $headerLine = ''
    foreach ($l in $raw) { if ($l.Trim()) { $headerLine = $l; break } }

    $userCol = -1
    $idCol   = -1
    if ($headerLine) {
        $userCol = $headerLine.IndexOf('用户名')
        if ($userCol -lt 0) { $userCol = $headerLine.IndexOf('USERNAME') }
        $idCol = $headerLine.IndexOf('ID')
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($line in $raw) {
        $t = $line.TrimEnd()
        if (-not $t.Trim()) { continue }
        if ($t -match '会话名|SESSIONNAME') { continue }
        if ($t -match '^\s*(用户名|USERNAME)') { continue }

        $cur = $false
        if ($t.StartsWith('>')) {
            $cur = $true
            # 用空格替换 '>' 以保持列对齐（其它行该位置本来就是空格）
            $t = ' ' + $t.Substring(1)
        }

        $name = ''; $user = ''; $sid = -1; $state = ''

        if ($userCol -ge 0 -and $idCol -gt $userCol -and $t.Length -gt $userCol) {
            $name = $t.Substring(0, [Math]::Min($userCol, $t.Length)).Trim()
            $userEnd = [Math]::Min($idCol, $t.Length)
            if ($userEnd -gt $userCol) { $user = $t.Substring($userCol, $userEnd - $userCol).Trim() }
            if ($t.Length -gt $idCol) {
                $rest = @([regex]::Split($t.Substring($idCol).Trim(), '\s{2,}') | Where-Object { $_ -ne '' })
                if ($rest.Count -ge 1) { [void][int]::TryParse($rest[0], [ref]$sid) }
                if ($rest.Count -ge 2) { $state = $rest[1] }
            }
        }

        if ($sid -lt 0) {
            # 表头解析不可用时的退化路径：按 2+ 空格切分
            $parts = @([regex]::Split($t.Trim(), '\s{2,}') | Where-Object { $_ -ne '' })
            if ($parts.Count -lt 3) { continue }
            if ($parts.Count -ge 4) {
                $name = $parts[0]; $user = $parts[1]; [void][int]::TryParse($parts[2], [ref]$sid); $state = $parts[3]
            } else {
                $name = $parts[0]; [void][int]::TryParse($parts[1], [ref]$sid); $state = $parts[2]
            }
        }
        if ($sid -lt 0) { continue }

        $isActive = ($state -match '运行中|Active')
        $isListening = ($state -match '侦听|Listen')

        # 判定“真的有用户登录”需要三个条件同时成立：
        #   1) 用户名字段非空
        #   2) 不是侦听会话（侦听行本来就没有用户，但会话名比用户名列长时切片会取到会话名的尾巴）
        #   3) 用户名看起来像账号名（必须含字母/中文，挡掉 '655'、'.' 这类切片垃圾）
        $plausibleUser = $false
        if (-not [string]::IsNullOrWhiteSpace($user) -and -not $isListening) {
            $plausibleUser = (($user -match '[\p{L}]') -and ($user -notmatch '^[\.\d]+$'))
        }

        [void]$rows.Add([pscustomobject]@{
            SessionName = $name
            User        = $user
            Id          = $sid
            State       = $state
            IsActive    = $isActive
            IsListening = $isListening
            HasUser     = $plausibleUser
            IsCurrent   = $cur
        })
    }

    $loggedOn = @($rows | Where-Object { $_.HasUser -and $_.Id -gt 0 })
    return [pscustomobject]@{
        Rows           = @($rows)
        Raw            = ($raw -join "`n")
        ColumnUser     = $userCol
        ColumnId       = $idCol
        LoggedOnCount  = $loggedOn.Count
        LoggedOn       = $loggedOn
        ActiveWithUser = @($loggedOn | Where-Object { $_.IsActive })
    }
}

function Start-GuiReadyPersistentProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExePath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [switch]$AtStartup,
        [string]$RunAsUser = 'SYSTEM',
        [switch]$WhatIf
    )

    if (-not (Test-Path -LiteralPath $ExePath)) {
        Write-Log ('可执行文件不存在: ' + $ExePath) 'ERROR'
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = Split-Path -Parent $ExePath
    }

    if ($WhatIf) {
        Write-Log ('将注册计划任务 {0} -> {1} {2}（工作目录 {3}，身份 {4}，开机自启={5}）' -f $Name, $ExePath, $Arguments, $WorkingDirectory, $RunAsUser, [bool]$AtStartup) 'DRY'
        return $true
    }

    try {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
        if ($Arguments) {
            $act = New-ScheduledTaskAction -Execute $ExePath -Argument $Arguments -WorkingDirectory $WorkingDirectory
        } else {
            $act = New-ScheduledTaskAction -Execute $ExePath -WorkingDirectory $WorkingDirectory
        }

        if ($RunAsUser -eq 'SYSTEM') {
            $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        } else {
            $prin = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Interactive -RunLevel Highest
        }

        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

        if ($AtStartup) {
            $trg = New-ScheduledTaskTrigger -AtStartup
            Register-ScheduledTask -TaskName $Name -Action $act -Principal $prin -Settings $set -Trigger $trg -Force | Out-Null
        } else {
            Register-ScheduledTask -TaskName $Name -Action $act -Principal $prin -Settings $set -Force | Out-Null
        }

        Start-ScheduledTask -TaskName $Name
        Start-Sleep -Seconds 5
        $state = [string](Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue).State
        Write-Log ('已注册并启动计划任务 {0}（状态 {1}）。这样启动的进程不会随远程会话结束被杀掉。' -f $Name, $state) 'OK'
        return $true
    } catch {
        Write-Log ('注册计划任务失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Stop-GuiReadyPersistentProcess {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$ProcessName = '')

    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($ProcessName) {
        Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Write-Log ('已停止并注销计划任务: ' + $Name) 'OK'
}

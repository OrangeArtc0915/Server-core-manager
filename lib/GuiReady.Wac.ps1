# GuiReady Windows Admin Center: 安装 / 自动配置 / 状态检查 / 服务控制
#
# 背景（含两个实测得出的坑，别再踩）：
#   1) WAC 有两代安装包，参数完全不同：
#      - 经典 MSI  : msiexec /i x.msi /qn SME_PORT=.. SSL_CERTIFICATE_OPTION=generate
#      - v2 / Inno : 安装包是 Inno Setup 打的 exe，用 /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=
#      用错那一套会直接失败，所以这里按文件类型分派。
#   2) 安装会重启 WinRM，会切断远程 PowerShell 会话；
#      所以安装必须走 SYSTEM 计划任务（脱离 WinRM 进程树），不能直接在当前会话里跑。
#   3) WAC v2 的 Web 入口是 /shell/，且登录页返回的 HTTP 状态码就是 403（未认证时的正常行为）。
#      用 curl / Invoke-WebRequest 探它会看到 403，很容易误判成“坏了”。判定标准应为：
#         /shell/ 返回 302  => 网关正常
#   4) PowerShell 5.1 访问本机 WAC 会因 schannel 重协商失败（客户端限制），
#      探测一律用 curl.exe，不用 Invoke-WebRequest。
#   5) 官方固定短链 https://aka.ms/WACDownload 会 301 到当前版本安装器（实测 139.96 MB），
#      本地没有安装包时默认从它下载；-NoDownload 可关掉，供离线/内网环境使用。

function Get-GuiReadyWacRegistryInfo {
    $out = [pscustomobject]@{
        DisplayName = ''; Version = ''; InstallLocation = ''; Uninstall = ''
        InstallerKind = ''      # Inno(即 v2) / Msi(经典)
        InnoSetupVersion = ''; InnoLanguage = ''; InnoMode = ''
    }
    try {
        $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
        foreach ($k in $keys) {
            $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -like '*Admin Center*' } | Select-Object -First 1
            if ($hit) {
                $out.DisplayName     = [string]$hit.DisplayName
                $out.Version         = [string]$hit.DisplayVersion
                $out.InstallLocation = [string]$hit.InstallLocation
                $out.Uninstall       = [string]$hit.UninstallString
                $props = $hit.PSObject.Properties
                if ($props['Inno Setup: Setup Version']) {
                    $out.InnoSetupVersion = [string]$props['Inno Setup: Setup Version'].Value
                    $out.InstallerKind    = 'Inno'
                } else {
                    $out.InstallerKind    = 'Msi'
                }
                if ($props['Inno Setup: Language']) { $out.InnoLanguage = [string]$props['Inno Setup: Language'].Value }
                if ($props['Inno Setup CodeFile: InstallationMode']) { $out.InnoMode = [string]$props['Inno Setup CodeFile: InstallationMode'].Value }
                break
            }
        }
    } catch { }
    return $out
}

function Find-GuiReadyWacInstaller {
    param([string]$Hint = '')
    $cands = New-Object System.Collections.ArrayList
    $dirs  = New-Object System.Collections.ArrayList
    if ($Hint) {
        if (Test-Path -LiteralPath $Hint -PathType Container) { [void]$dirs.Add($Hint) }
        elseif (Test-Path -LiteralPath $Hint -PathType Leaf) { [void]$cands.Add((Get-Item -LiteralPath $Hint)) }
    }
    foreach ($d in @($script:GuiReadyRoot, (Join-Path $script:GuiReadyRoot 'payload'), (Join-Path $script:GuiReadyRoot 'setup'))) {
        if (Test-Path -LiteralPath $d) { [void]$dirs.Add($d) }
    }
    foreach ($d in $dirs) {
        foreach ($pat in @('WindowsAdminCenter*.exe', 'WindowsAdminCenter*.msi', '*AdminCenter*.msi', '*AdminCenter*.exe')) {
            Get-ChildItem -LiteralPath $d -Filter $pat -File -ErrorAction SilentlyContinue | ForEach-Object { [void]$cands.Add($_) }
        }
    }
    $best = $null
    foreach ($c in ($cands | Sort-Object Length -Descending)) {
        # 只要够大的安装包（安装器通常上百 MB），避免误取到别的同名小文件
        if ($c.Length -gt 5MB) { $best = $c; break }
    }
    if (-not $best) { return '' }
    return $best.FullName
}

function Get-GuiReadyWacCurlPath {
    $curl = Join-Path (Join-Path $env:windir 'System32') 'curl.exe'
    if (Test-Path -LiteralPath $curl) { return $curl }
    return 'curl.exe'
}

function Get-GuiReadyWacDownloadInfo {
    # 官方固定短链，实测 301 到 download.microsoft.com 的当前版本安装器
    param([string]$Url = 'https://aka.ms/WACDownload', [int]$TimeoutSeconds = 60)
    $res = [pscustomobject]@{ Ok = $false; FileName = ''; TotalBytes = 0; Note = '' }
    try {
        $head = & (Get-GuiReadyWacCurlPath) -sIL --max-time $TimeoutSeconds --retry 3 --retry-delay 2 --retry-all-errors $Url 2>&1
        foreach ($line in @($head)) {
            $t = [string]$line
            if ($t -match '(?i)^content-disposition:.*filename="?([^";]+?)"?\s*$') { $res.FileName = $Matches[1].Trim() }
            elseif ($t -match '(?i)^content-length:\s*(\d+)') { if ([int64]$Matches[1] -gt $res.TotalBytes) { $res.TotalBytes = [int64]$Matches[1] } }
        }
        if ($res.TotalBytes -gt 0) { $res.Ok = $true } else { $res.Note = '拿不到下载信息（网络不通或被代理拦截）' }
    } catch {
        $res.Note = ('探测下载地址失败: ' + $_.Exception.Message)
    }
    if (-not $res.FileName) { $res.FileName = 'WindowsAdminCenter.exe' }
    return $res
}

function Save-GuiReadyWacInstaller {
    # 本地没有安装包时，从官方地址下载一份到 payload 目录
    param(
        [string]$Url = 'https://aka.ms/WACDownload',
        [string]$DestinationDir = ''
    )
    if (-not $DestinationDir) { $DestinationDir = Join-Path $script:GuiReadyRoot 'payload' }
    if (-not (Test-Path -LiteralPath $DestinationDir)) { New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null }

    Write-Log '本地没有安装包，尝试从官方地址下载...' 'STEP'
    $info = Get-GuiReadyWacDownloadInfo -Url $Url
    if (-not $info.Ok) {
        # 实测这个短链偶尔会超时，拿不到信息也照样试着下，成败由下载结果决定
        Write-Log ('  拿不到下载信息（{0}），仍尝试直接下载。' -f $info.Note) 'WARN'
    }

    $dest = Join-Path $DestinationDir $info.FileName
    if (Test-Path -LiteralPath $dest) {
        $have = (Get-Item -LiteralPath $dest).Length
        if ($info.TotalBytes -gt 0 -and $have -eq $info.TotalBytes) { Write-Log ('  已存在完整安装包，跳过下载: ' + $dest) 'OK'; return $dest }
        if ($info.TotalBytes -eq 0 -and $have -gt 5MB) { Write-Log ('  已存在安装包且大于 5 MB，跳过下载: ' + $dest) 'OK'; return $dest }
        Write-Log ('  已存在同名文件但大小不符（{0:N1} MB），重新下载。' -f ($have / 1MB)) 'WARN'
    }

    Write-Log ('  地址: ' + $Url) 'INFO'
    if ($info.TotalBytes -gt 0) { Write-Log ('  保存到: {0}（{1:N1} MB）' -f $dest, ($info.TotalBytes / 1MB)) 'INFO' }
    else { Write-Log ('  保存到: ' + $dest) 'INFO' }

    $curl    = Get-GuiReadyWacCurlPath
    # 诊断文件放 logs 下，别污染 payload（那是给用户放安装包的目录）
    $errDir  = Join-Path $script:LogDir 'wac'
    if (-not (Test-Path -LiteralPath $errDir)) { New-Item -ItemType Directory -Path $errDir -Force | Out-Null }
    $errFile = Join-Path $errDir 'wac-download.err.txt'
    $proc = $null
    try {
        if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
        $proc = Start-Process -FilePath $curl -PassThru -NoNewWindow -RedirectStandardError $errFile -ArgumentList @(
            '-L', '--fail', '--retry', '3', '--retry-delay', '3', '--retry-all-errors', '-s', '-S', '-o', $dest, $Url)
        $lastPct = -10
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 5
            if ($proc.HasExited) { break }
            $cur = 0
            try { $cur = (Get-Item -LiteralPath $dest -ErrorAction SilentlyContinue).Length } catch { }
            $pct = 0
            if ($info.TotalBytes -gt 0) { $pct = [int]($cur * 100 / $info.TotalBytes) }
            if ($pct -ge ($lastPct + 5)) {
                $lastPct = $pct
                Write-Log ('  下载中 {0:N1}/{1:N1} MB  {2}%' -f ($cur / 1MB), ($info.TotalBytes / 1MB), $pct) 'INFO'
            }
        }
        try { $proc.WaitForExit() } catch { }
    } catch {
        Write-Log ('  下载失败: ' + $_.Exception.Message) 'ERROR'
        return ''
    }

    $errText = ''
    try { if (Test-Path -LiteralPath $errFile) { $errText = ([string](Get-Content -LiteralPath $errFile -Raw)).Trim() } } catch { }
    $size = 0
    try { $size = (Get-Item -LiteralPath $dest -ErrorAction SilentlyContinue).Length } catch { }
    if ($errText) { Write-Log ('  curl: ' + $errText) 'WARN' }
    if ($size -lt 5MB) {
        Write-Log ('  下载结果不可用: 文件 {0:N1} MB。' -f ($size / 1MB)) 'ERROR'
        return ''
    }
    if ($info.TotalBytes -gt 0 -and $size -ne $info.TotalBytes) {
        Write-Log ('  下载不完整: {0:N1} / {1:N1} MB，请重试。' -f ($size / 1MB), ($info.TotalBytes / 1MB)) 'ERROR'
        return ''
    }
    Write-Log ('  下载完成: {0}（{1:N1} MB）' -f $dest, ($size / 1MB)) 'OK'
    return $dest
}

function Get-GuiReadyWacServices {
    try {
        return @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'WindowsAdminCenter*' })
    } catch { return @() }
}

function Get-GuiReadyWacPort {
    # 网关端口 = appsettings.json 里 Kestrel 的 Url 或 HttpSysUrls
    $guess = 443
    try {
        $cfg = Join-Path (Join-Path $env:ProgramFiles 'WindowsAdminCenter') 'Service\appsettings.json'
        if (Test-Path -LiteralPath $cfg) {
            $j = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            $u = $null
            if ($j.Kestrel -and $j.Kestrel.Endpoints) {
                foreach ($ep in $j.Kestrel.Endpoints.PSObject.Properties) {
                    if ($ep.Value.Url) { $u = [string]$ep.Value.Url; break }
                }
            }
            if (-not $u -and $j.WindowsAdminCenter.Http.HttpSysUrls) { $u = [string]$j.WindowsAdminCenter.Http.HttpSysUrls[0] }
            if ($u -and $u -match ':(\d+)') { $guess = [int]$Matches[1] }
        }
    } catch { }
    return $guess
}

function Get-GuiReadyWacEndpointFqdn {
    try {
        $cfg = Join-Path (Join-Path $env:ProgramFiles 'WindowsAdminCenter') 'Service\appsettings.json'
        if (Test-Path -LiteralPath $cfg) {
            $j = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.WindowsAdminCenter.Http.EndpointFqdn) { return [string]$j.WindowsAdminCenter.Http.EndpointFqdn }
        }
    } catch { }
    return $env:COMPUTERNAME
}

function Test-GuiReadyWacHttp {
    # 用 curl.exe 探测（PS 5.1 的内置客户端会因 TLS 重协商失败，别用）
    param([string]$Url, [int]$TimeoutSeconds = 15)
    $res = [pscustomobject]@{ Ok = $false; StatusCode = 0; Note = ''; Via = '' }
    $curl = Get-GuiReadyWacCurlPath
    try {
        $out = & $curl -k -s -S -o NUL -w '%{http_code}' --max-time $TimeoutSeconds $Url 2>&1
        $code = 0
        foreach ($line in @($out)) {
            $t = [string]$line
            if ($t -match '^\d{3}$') { $code = [int]$t }
        }
        $res.StatusCode = $code
        $res.Via = 'curl'
        if ($code -eq 302 -or $code -eq 301 -or $code -eq 200) { $res.Ok = $true; $res.Note = '网关响应正常' }
        elseif ($code -eq 403) { $res.Ok = $true; $res.Note = '返回 403：这是未登录时登录页的正常状态码' }
        elseif ($code -eq 0) { $res.Note = '连接失败（端口不通或服务未就绪）' }
        else { $res.Note = ('返回 HTTP ' + $code) }
    } catch {
        $res.Note = ('探测失败: ' + $_.Exception.Message)
    }
    return $res
}

function Get-GuiReadyWacStatus {
    param([switch]$SkipProbe)
    $reg  = Get-GuiReadyWacRegistryInfo
    $svcs = Get-GuiReadyWacServices
    $main = @($svcs | Where-Object { $_.Name -eq 'WindowsAdminCenter' })
    $port = Get-GuiReadyWacPort
    $fqdn = Get-GuiReadyWacEndpointFqdn

    $portOwner = ''
    try {
        $l = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($l) {
            $pr = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
            if ($pr) { $portOwner = ($pr.ProcessName + ' (PID ' + $pr.Id + ')') }
        }
    } catch { }

    $cert = $null
    try {
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -like '*WindowsAdminCenter*' } |
                Sort-Object NotAfter -Descending | Select-Object -First 1
    } catch { }

    $fw = @()
    try {
        $fw = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*Windows Admin Center*' -and $_.Direction -eq 'Inbound' })
    } catch { }

    $serving = $false
    try { $serving = ($main.Count -gt 0 -and $main[0].State -eq 'Running') } catch { }

    $probe = $null
    if ($serving -and -not $SkipProbe) { $probe = Test-GuiReadyWacHttp -Url ('https://127.0.0.1:{0}/shell/' -f $port) }

    $ip = ''
    try {
        $ip = [string]((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
              Select-Object -First 1).IPAddress)
    } catch { }

    return [pscustomobject]@{
        Installed     = ($reg.DisplayName -ne '')
        Version       = $reg.Version
        InstallerKind = $reg.InstallerKind
        InnoVersion   = $reg.InnoSetupVersion
        InstallMode   = $reg.InnoMode
        Language      = $reg.InnoLanguage
        InstallPath   = $reg.InstallLocation
        Uninstall     = $reg.Uninstall
        Services      = @($svcs)
        ServiceName   = $(if ($main.Count -gt 0) { [string]$main[0].Name } else { '' })
        ServiceState  = $(if ($main.Count -gt 0) { [string]$main[0].State } else { '' })
        Servicing     = $serving
        Port          = $port
        PortOwner     = $portOwner
        EndpointFqdn  = $fqdn
        CertSubject   = $(if ($cert) { [string]$cert.Subject } else { '' })
        CertThumb     = $(if ($cert) { [string]$cert.Thumbprint } else { '' })
        CertNotAfter  = $(if ($cert) { $cert.NotAfter } else { $null })
        FirewallRules = @($fw)
        Probe         = $probe
        UrlLocal      = ('https://127.0.0.1:{0}/shell/' -f $port)
        UrlIp         = $(if ($ip) { 'https://{0}:{1}/shell/' -f $ip, $port } else { '' })
        UrlHost       = ('https://{0}:{1}/shell/' -f $fqdn, $port)
    }
}

function Show-GuiReadyWacStatus {
    Write-Head 'Windows Admin Center 状态'
    $s = Get-GuiReadyWacStatus

    if (-not $s.Installed) {
        Write-Log '未安装 Windows Admin Center。' 'WARN'
        Write-Log '可以用「Windows Admin Center → 一键安装并配置」来装（需要安装包）。' 'INFO'
        return $s
    }

    Write-Log ('已安装: 版本 {0}   安装方式 {1}' -f $s.Version, $(if ($s.InstallerKind -eq 'Inno') { 'v2 / Inno Setup ' + $s.InnoVersion } else { '经典 MSI' })) 'OK'
    if ($s.InstallMode) { Write-Log ('安装时选择: {0}   语言: {1}' -f $s.InstallMode, $s.Language) 'INFO' }
    Write-Log ('安装目录: ' + $s.InstallPath) 'INFO'

    Write-Log '服务:' 'STEP'
    foreach ($sv in $s.Services) { Write-Log ('  {0,-38} {1,-8} 启动={2}' -f $sv.Name, $sv.State, $sv.StartMode) 'INFO' }

    Write-Log '网关:' 'STEP'
    Write-Log ('  端口 {0}   监听者: {1}' -f $s.Port, $(if ($s.PortOwner) { $s.PortOwner } else { '(无人监听)' })) 'INFO'
    Write-Log ('  端点 FQDN: ' + $s.EndpointFqdn) 'INFO'
    if ($s.CertSubject) {
        Write-Log ('  证书: {0}   到期 {1}' -f $s.CertSubject, $s.CertNotAfter) 'INFO'
        try {
            $days = [int]((New-TimeSpan -Start (Get-Date) -End $s.CertNotAfter).TotalDays)
            if ($days -lt 0) { Write-Log ('  证书已过期 {0} 天，Web 界面会报证书错误。' -f (-$days)) 'ERROR' }
            elseif ($days -lt 15) { Write-Log ('  证书还有 {0} 天到期，建议尽快更换。' -f $days) 'WARN' }
        } catch { }
    } else { Write-Log '  证书: 未找到（Web 界面可能无法访问）' 'WARN' }

    Write-Log ('防火墙入站规则: {0} 条' -f $s.FirewallRules.Count) 'INFO'

    Write-Log '连通性:' 'STEP'
    if ($s.Servicing -and $s.Probe) {
        if ($s.Probe.Ok) { Write-Log ('  /shell/ 探测: HTTP {0}  {1}' -f $s.Probe.StatusCode, $s.Probe.Note) 'OK' }
        else { Write-Log ('  /shell/ 探测: ' + $s.Probe.Note) 'ERROR' }
    } else {
        Write-Log '  服务未运行，跳过探测。' 'WARN'
    }

    Write-Log '访问地址（浏览器里打开）:' 'STEP'
    if ($s.UrlIp)   { Write-Log ('  ' + $s.UrlIp)   'OK' }
    Write-Log ('  ' + $s.UrlHost) 'OK'
    Write-Log '注意：入口是 /shell/，直接开根路径会看到 403；登录页本身就是 403 状态码，属正常现象。' 'WARN'
    Write-Log '首次访问浏览器会提示自签名证书不受信任，选择继续访问即可。' 'WARN'
    return $s
}

function Set-GuiReadyWacService {
    param([ValidateSet('Start', 'Stop', 'Restart', 'Auto')][string]$Action = 'Restart')
    $svc = 'WindowsAdminCenter'
    $cur = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $cur) { Write-Log ('未找到服务 ' + $svc + '（可能未安装 WAC）') 'ERROR'; return $false }
    try {
        switch ($Action) {
            'Start'   { Start-Service -Name $svc -ErrorAction Stop }
            'Stop'    { Stop-Service  -Name $svc -Force -ErrorAction Stop }
            'Restart' { Restart-Service -Name $svc -Force -ErrorAction Stop }
            'Auto'    { Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop }
        }
        Start-Sleep -Seconds 2
        $now = (Get-Service -Name $svc).Status
        Write-Log ('服务 {0} 执行 {1} 完成，当前状态: {2}' -f $svc, $Action, $now) 'OK'
        return $true
    } catch {
        Write-Log ('服务操作失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Add-GuiReadyWacFirewallRule {
    param([int]$Port = 443)
    try {
        $exists = Get-NetFirewallRule -DisplayName 'Windows Admin Center' -ErrorAction SilentlyContinue
        if ($exists) { Write-Log '防火墙规则已存在，跳过。' 'OK'; return $true }
        New-NetFirewallRule -DisplayName 'Windows Admin Center' -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null
        Write-Log ('已添加防火墙入站规则: TCP ' + $Port) 'OK'
        return $true
    } catch {
        Write-Log ('添加防火墙规则失败: ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function Open-GuiReadyWacUi {
    param([string]$Url = '')
    $s = Get-GuiReadyWacStatus
    if (-not $s.Installed) { Write-Log 'WAC 未安装，无法打开。' 'ERROR'; return $false }
    if (-not $Url) { $Url = $s.UrlLocal }

    # Server Core 没有默认浏览器；有桌面体验时才谈得上“打开”
    $hasBrowser = $false
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $prog = (Get-ItemProperty 'HKLM:\SOFTWARE\Classes\http\shell\open\command' -ErrorAction SilentlyContinue).'(default)'
        if ($prog) { $hasBrowser = $true }
    } catch { }

    if (-not $hasBrowser) {
        Write-Log '这台机器没有注册默认浏览器（Server Core 正常现象），无法在本机打开。' 'WARN'
        Write-Log ('请在另一台机器的浏览器里访问: ' + $Url) 'OK'
        $ipUrl = $s.UrlIp
        if ($ipUrl) { Write-Log ('  或: ' + $ipUrl) 'OK' }
        Write-Log '提示：入口是 /shell/；自签名证书需在浏览器里选择“继续访问”。' 'INFO'
        return $false
    }

    try {
        Start-Process $Url | Out-Null
        Write-Log ('已在默认浏览器打开: ' + $Url) 'OK'
        return $true
    } catch {
        Write-Log ('打开浏览器失败: ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function Install-GuiReadyWac {
    param(
        [string]$InstallerPath = '',
        [int]$Port = 443,
        [ValidateSet('Express', 'Custom')][string]$Mode = 'Express',
        [switch]$NoDownload,
        [switch]$SkipFirewall,
        [switch]$NoAutoStart,
        [switch]$SkipVerify,
        [switch]$Force,
        [switch]$WhatIf
    )

    Write-Head 'Windows Admin Center 一键安装并配置'

    $status = Get-GuiReadyWacStatus
    if ($status.Installed -and -not $Force) {
        Write-Log ('检测到已安装版本 {0}（安装目录 {1}）。' -f $status.Version, $status.InstallPath) 'WARN'
        Write-Log '为避免破坏现有配置，本次不做安装。' 'WARN'
        Write-Log '如需覆盖安装，请用 -Force；如需升级，建议用 WAC 自带的更新机制或先卸载。' 'INFO'
        Show-GuiReadyWacStatus | Out-Null
        return $false
    }

    $explicit = [bool]$InstallerPath
    if ($explicit -and -not (Test-Path -LiteralPath $InstallerPath)) {
        Write-Log ('指定的安装包不存在: ' + $InstallerPath) 'ERROR'
        return $false
    }
    if (-not $InstallerPath) { $InstallerPath = Find-GuiReadyWacInstaller }
    # 预览模式不能真去下 140MB，这里只标记“会下载”
    $willDownload = $false
    if (-not $InstallerPath -and -not $NoDownload) {
        if ($WhatIf) { $willDownload = $true }
        else { $InstallerPath = Save-GuiReadyWacInstaller }
    }
    if (-not $willDownload -and (-not $InstallerPath -or -not (Test-Path -LiteralPath $InstallerPath))) {
        Write-Log '没有找到安装包。' 'ERROR'
        if ($NoDownload) {
            Write-Log '已指定不自动下载。请把 WindowsAdminCenter.msi（经典版）或 WindowsAdminCenter.exe（v2 安装器）放到工具目录、payload 或 setup 子目录，或用 -InstallerPath 指定。' 'INFO'
        } else {
            Write-Log '自动下载也未成功。可手工从 https://aka.ms/WACDownload 下载后放到工具目录，再用 -InstallerPath 指定。' 'INFO'
        }
        return $false
    }

    $item = $null
    $isMsi = $false
    if ($willDownload) {
        Write-Log '本地没有安装包，将先从 https://aka.ms/WACDownload 下载（约 140 MB），再静默安装。' 'DRY'
    } else {
        $item  = Get-Item -LiteralPath $InstallerPath
        $isMsi = ($item.Extension -ieq '.msi')
        Write-Log ('安装包: {0}（{1:N1} MB）' -f $item.FullName, ($item.Length / 1MB)) 'OK'
        Write-Log ('类型判定: {0}' -f $(if ($isMsi) { 'MSI（经典版，用 msiexec + SME_ 参数）' } else { '可执行安装器（v2 / Inno Setup，用 /VERYSILENT 参数）' })) 'INFO'
        if (-not $isMsi -and $Port -ne 443) {
            Write-Log ('v2 安装器的“快速设置”固定使用 443 端口；你指定了 {0}，该值在 v2 静默安装下不生效。' -f $Port) 'WARN'
            Write-Log '如需自定义端口，请改用交互式安装或手工修改 Service\appsettings.json。' 'WARN'
        }
    }

    # 前置检查
    Write-Log '前置检查:' 'STEP'
    $blocking = $false
    if (-not (Test-IsAdministrator)) { Write-Log '  当前不是管理员，无法安装。' 'ERROR'; $blocking = $true } else { Write-Log '  管理员权限: 是' 'OK' }

    $freeGB = 0
    try { $freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1) } catch { }
    if ($freeGB -lt 5) { Write-Log ('  C: 可用空间仅 {0} GB，建议至少 5 GB。' -f $freeGB) 'WARN' } else { Write-Log ('  C: 可用空间 {0} GB' -f $freeGB) 'OK' }

    $portOwner = ''
    try {
        $l = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($l) {
            $pr = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
            if ($pr) { $portOwner = ($pr.ProcessName + ' (PID ' + $pr.Id + ')') }
        }
    } catch { }
    if ($portOwner) {
        if ($portOwner -like 'WindowsAdminCenter*') { Write-Log ('  端口 {0} 已由 WAC 自己占用（覆盖安装时会短暂释放）' -f $Port) 'INFO' }
        else { Write-Log ('  端口 {0} 已被 {1} 占用，安装后网关将无法监听，请先释放或改用其他端口。' -f $Port, $portOwner) 'ERROR'; $blocking = $true }
    } else { Write-Log ('  端口 {0} 空闲' -f $Port) 'OK' }

    if ($blocking) { Write-Log '前置检查未通过，已中止。' 'ERROR'; return $false }

    if ($WhatIf) {
        Write-Log '--- 预览模式，不实际安装 ---' 'DRY'
        if ($willDownload) {
            Write-Log '将执行: 下载完成后的安装器 /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG=<日志>' 'DRY'
        } else {
            Write-Log ('将执行: {0}' -f $(if ($isMsi) { 'msiexec /i "' + $item.FullName + '" /qn /L*v <日志> SME_PORT=' + $Port + ' SSL_CERTIFICATE_OPTION=generate RESTART_WINRM=0' } else { '"' + $item.FullName + '" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG=<日志>' })) 'DRY'
        }
        Write-Log '将通过 SYSTEM 计划任务执行（安装会重启 WinRM，必须脱离当前会话）。' 'DRY'
        if (-not $SkipFirewall) { Write-Log ('将确保防火墙放行 TCP ' + $Port) 'DRY' }
        if (-not $SkipVerify)   { Write-Log '将验证服务状态与 /shell/ 可达性，并输出访问地址。' 'DRY' }
        return $true
    }

    # 通过 SYSTEM 计划任务安装：WAC v2 安装过程会重启 WinRM，直接在当前（远程）会话里跑会中断。
    # 实测教训：VM 上装完服务是 Stopped，因为会话被杀后“后置配置”没机会跑。
    # 所以防火墙/自启/启动服务这些都放进 worker 里，让它在 SYSTEM 下自己收尾，不再依赖父进程存活。
    $logDir = Join-Path $script:LogDir 'wac'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $setupLog = Join-Path $logDir ('wac-setup-' + $stamp + '.log')

    $exe    = $item.FullName
    $root   = $script:GuiReadyRoot
    $wantFw = $(if ($SkipFirewall) { 0 } else { 1 })
    $wantAuto = $(if ($NoAutoStart) { 0 } else { 1 })

    $body = @'
$ErrorActionPreference = 'Continue'
. '__ROOT__\lib\GuiReady.Common.ps1'
. '__ROOT__\lib\GuiReady.Wac.ps1'
$exe = '__EXE__'
$setupLog = '__LOG__'
$port = __PORT__
if ($exe -like '*.msi') {
    $msiArgs = @('/i', $exe, '/qn', '/norestart', '/L*v', $setupLog, ('SME_PORT=' + $port), 'SSL_CERTIFICATE_OPTION=generate', 'RESTART_WINRM=0')
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -PassThru -Wait
} else {
    $innoArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/LOG=' + $setupLog))
    $p = Start-Process -FilePath $exe -ArgumentList $innoArgs -PassThru -Wait
}
'安装器退出码: ' + $p.ExitCode
if (__FW__ -eq 1) { Add-GuiReadyWacFirewallRule -Port $port | Out-Null }
if (__AUTO__ -eq 1) {
    Set-GuiReadyWacService -Action Auto | Out-Null
    $svcNow = Get-Service -Name 'WindowsAdminCenter' -ErrorAction SilentlyContinue
    if ($svcNow -and $svcNow.Status -ne 'Running') { Set-GuiReadyWacService -Action Start | Out-Null }
}
'@
    $body = $body.Replace('__ROOT__', $root).Replace('__EXE__', $exe).Replace('__LOG__', $setupLog).
                  Replace('__PORT__', [string]$Port).Replace('__FW__', [string]$wantFw).Replace('__AUTO__', [string]$wantAuto)

    Write-Log '开始安装（通过 SYSTEM 计划任务，安装会重启 WinRM，这是预期行为）...' 'STEP'
    $r = Invoke-GuiReadyElevatedTask -Name 'WacInstall' -Body $body -TimeoutSeconds 3600 -PollSeconds 20
    if ($r.Log) { foreach ($line in ($r.Log -split "`r?`n")) { if ($line.Trim()) { Write-Log ('  ' + $line) 'INFO' } } }
    Write-Log ('计划任务结果: ' + $r.Result) 'INFO'

    $exitCode = $null
    if ($r.Log -match '安装器退出码:\s*(-?\d+)') { $exitCode = [int]$Matches[1] }
    if ($null -ne $exitCode) {
        if ($exitCode -eq 0)    { Write-Log ('安装器返回 0，安装成功。' ) 'OK' }
        elseif ($exitCode -eq 3010) { Write-Log '安装器返回 3010，需要重启才能完成。' 'WARN' }
        elseif ($exitCode -eq 1641) { Write-Log '安装器返回 1641，已发起重启。' 'WARN' }
        else { Write-Log ('安装器返回 {0}，安装可能失败。安装日志: {1}' -f $exitCode, $setupLog) 'ERROR' }
    } else {
        Write-Log ('未能取得安装器退出码。安装器日志: ' + $setupLog) 'WARN'
    }

    # 后置配置
    Write-Log '后置配置:' 'STEP'
    if (-not $SkipFirewall) { [void](Add-GuiReadyWacFirewallRule -Port $Port) }
    if (-not $NoAutoStart) {
        $svc = Get-Service -Name 'WindowsAdminCenter' -ErrorAction SilentlyContinue
        if ($svc) {
            try { Set-Service -Name 'WindowsAdminCenter' -StartupType Automatic -ErrorAction Stop; Write-Log '已设为自动启动。' 'OK' } catch { Write-Log ('设置自启失败: ' + $_.Exception.Message) 'WARN' }
            if ($svc.Status -ne 'Running') {
                try { Start-Service -Name 'WindowsAdminCenter' -ErrorAction Stop; Write-Log '已启动服务。' 'OK' } catch { Write-Log ('启动服务失败: ' + $_.Exception.Message) 'WARN' }
            }
        } else { Write-Log '未找到 WindowsAdminCenter 服务，安装可能未完成。' 'WARN' }
    }

    if (-not $SkipVerify) {
        Write-Log '等待服务就绪...' 'STEP'
        $ok = $false
        for ($i = 1; $i -le 12; $i++) {
            Start-Sleep -Seconds 10
            $pr = Test-GuiReadyWacHttp -Url ('https://127.0.0.1:{0}/shell/' -f $Port) -TimeoutSeconds 10
            Write-Log ('  第 {0} 次探测: HTTP {1}  {2}' -f $i, $pr.StatusCode, $pr.Note) 'INFO'
            if ($pr.Ok) { $ok = $true; break }
        }
        if ($ok) { Write-Log '网关已就绪。' 'OK' } else { Write-Log '仍未探测到网关响应，请稍后用“状态检查”再看一次。' 'WARN' }
    }

    Write-Log ''
    Show-GuiReadyWacStatus | Out-Null
    return $true
}

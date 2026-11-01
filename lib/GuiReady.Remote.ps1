# GuiReady 远程执行：WinRM 会话、连通性测试、多机批量命令。
#
# 只用系统自带的 PowerShell Remoting，不安装 agent。
# 所有远程调用都带 Open/Operation/Cancel 三重超时，单台失败不会拖垮整批。
#
# 结果文件：state\remote\batch-<taskId>.json
# 每完成一台就原子重写一次，任务中途被取消也能看到已完成的主机。

$script:GuiReadyRemoteRoot = Split-Path -Parent $PSScriptRoot
$script:GuiReadyRemoteDir  = Join-Path $script:GuiReadyRemoteRoot 'state\remote'
$script:GuiReadyRemoteUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:GuiReadyRemoteOutputLimit = 20000

function Get-GuiReadyRemoteDir { return $script:GuiReadyRemoteDir }

function Ensure-GuiReadyRemoteDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function ConvertTo-GuiReadyRemoteSafeId {
    param([string]$Id)
    $s = [string]$Id
    $s = [regex]::Replace($s, '[^A-Za-z0-9._-]', '_')
    if (-not $s) { $s = 'batch-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') }
    return $s
}

function Get-GuiReadyRemoteBatchFile {
    param([Parameter(Mandatory = $true)][string]$TaskId)
    return (Join-Path $script:GuiReadyRemoteDir ('batch-' + (ConvertTo-GuiReadyRemoteSafeId -Id $TaskId) + '.json'))
}

function Write-GuiReadyRemoteBatchFile {
    param([Parameter(Mandatory = $true)]$Batch)
    $path = Get-GuiReadyRemoteBatchFile -TaskId ([string]$Batch.TaskId)
    Ensure-GuiReadyRemoteDir -Path $script:GuiReadyRemoteDir
    $json = $Batch | ConvertTo-Json -Depth 8
    $tmp  = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, $script:GuiReadyRemoteUtf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Read-GuiReadyRemoteBatchFile {
    param([Parameter(Mandatory = $true)][string]$TaskId)
    $path = Get-GuiReadyRemoteBatchFile -TaskId $TaskId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function ConvertTo-GuiReadyRemoteErrorText {
    # 把常见的英文 WinRM 异常翻成可操作的中文，同时保留原文供排查。
    param([string]$Message)
    $m = [string]$Message
    if (-not $m) { return '' }
    $hint = ''
    if ($m -match '(?i)access is denied|拒绝访问|unauthorized|401') {
        $hint = '认证失败：用户名/密码不对，或该账号没有远程登录权限。'
    } elseif ($m -match '(?i)cannot connect|无法连接|连接失败|network path|主机不可达|No route') {
        $hint = '连不上目标：请检查 IP、端口和网络连通性。'
    } elseif ($m -match '(?i)WinRM.*(cannot|未启用)|WS-Management|winrm service|服务未启动') {
        $hint = 'WinRM 未启用或端口不可达：请在目标上运行 Enable-PSRemoting -Force 并放通 5985/5986。'
    } elseif ($m -match '(?i)TrustedHosts') {
        $hint = '目标不在 TrustedHosts：工作组 HTTP 认证需要显式信任目标地址（本页「信任设置」）。'
    } elseif ($m -match '(?i)certificate|证书') {
        $hint = 'HTTPS 证书校验失败：可编辑该主机勾选「跳过证书校验」，或为 WinRM 配置受信任证书。'
    } elseif ($m -match '(?i)timeout|timed out|超时') {
        $hint = '操作超时：命令执行时间超过限制，或目标无响应。'
    } elseif ($m -match '(?i)credential|DPAPI|凭据') {
        $hint = '凭据不可用：请在主机编辑框重新填写用户名和密码。'
    }
    if ($hint) { return ($hint + ' 原始信息：' + $m) }
    return $m
}

function New-GuiReadyRemoteSessionOption {
    param([int]$TimeoutSec = 60, [bool]$AllowUntrusted = $false)
    if ($TimeoutSec -lt 10) { $TimeoutSec = 10 }
    if ($TimeoutSec -gt 1800) { $TimeoutSec = 1800 }
    $ms = $TimeoutSec * 1000
    $opt = @{
        OpenTimeout      = $ms
        OperationTimeout = $ms
        CancelTimeout    = 5000
        IdleTimeout      = 120000
    }
    if ($AllowUntrusted) {
        $opt['SkipCACheck']       = $true
        $opt['SkipCNCheck']       = $true
        $opt['SkipRevocationCheck'] = $true
    }
    return (New-PSSessionOption @opt)
}

function Get-GuiReadyRemoteConnectionParams {
    # 参数不能叫 Host：$Host 是 PowerShell 的只读自动变量（当前宿主对象），
    # 同名参数会在绑定时直接抛「无法覆盖变量 Host」。
    param(
        [Parameter(Mandatory = $true)]$Target,
        [int]$TimeoutSec = 60
    )
    $cp = @{
        ComputerName = [string]$Target.Address
        Port         = [int]$Target.Port
        SessionOption = (New-GuiReadyRemoteSessionOption -TimeoutSec $TimeoutSec -AllowUntrusted ([bool]$Target.AllowUntrusted))
        ErrorAction  = 'Stop'
    }
    if ([string]$Target.Protocol -eq 'Https') { $cp['UseSSL'] = $true }
    if ([string]$Target.Auth -eq 'Credential') {
        $cp['Credential'] = Get-GuiReadyHostCredential -Id ([string]$Target.Id)
    }
    return $cp
}

function New-GuiReadyRemoteResult {
    param($Target, [bool]$Ok, [string]$Output = '', [string]$ErrorText = '', [datetime]$Started = (Get-Date))
    $end = Get-Date
    return [pscustomobject][ordered]@{
        HostId      = [string]$Target.Id
        Name        = [string]$Target.Name
        Address     = [string]$Target.Address
        Status      = $(if ($Ok) { 'Succeeded' } else { 'Failed' })
        Ok          = $Ok
        Output      = [string]$Output
        Error       = [string]$ErrorText
        StartedAt   = $Started.ToString('o')
        EndedAt     = $end.ToString('o')
        DurationSec = [Math]::Round(($end - $Started).TotalSeconds, 1)
    }
}

function Invoke-GuiReadyRemoteCommand {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command,
        [int]$TimeoutSec = 60
    )
    $start = Get-Date
    if (-not $Command.Trim()) { return (New-GuiReadyRemoteResult -Target $Target -Ok $false -ErrorText '命令是空的。' -Started $start) }

    $session = $null
    $ps      = $null
    try {
        $cp = Get-GuiReadyRemoteConnectionParams -Target $Target -TimeoutSec $TimeoutSec
        $session = New-PSSession @cp

        # 为什么不用 Invoke-Command：实测它的 -OperationTimeout 只约束连接/接收底层操作，
        # 目标上一个 Start-Sleep 30 会老老实实等满 30 秒（超时 10 秒形同虚设）。
        # 这里直接借用 PSSession 的远程 Runspace 异步执行，本地自己计时，
        # 到点就 Stop() 并返回中文超时原因 —— 单台卡死不会拖住整批。
        $wrapper = @'
param($cmd)
$ErrorActionPreference = 'Continue'
$sb = [scriptblock]::Create($cmd)
& $sb 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { 'ERR: ' + $_.ToString() }
    else { [string]$_ }
}
'@
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $session.Runspace
        [void]$ps.AddScript($wrapper).AddArgument($Command)
        $handle = $ps.BeginInvoke()
        $ms = [Math]::Max(10000, $TimeoutSec * 1000)
        if (-not $handle.AsyncWaitHandle.WaitOne($ms)) {
            try { $ps.Stop() } catch { }
            return (New-GuiReadyRemoteResult -Target $Target -Ok $false `
                -ErrorText ('操作超时：超过 {0} 秒仍未返回（主机可能无响应，或命令执行时间过长）。' -f [int]($ms / 1000)) `
                -Started $start)
        }
        $raw = @($ps.EndInvoke($handle))
        $lines = @()
        foreach ($x in $raw) {
            if ($null -eq $x) { continue }
            $lines += [string]$x
        }
        $text = ($lines -join [Environment]::NewLine)
        if ($text.Length -gt $script:GuiReadyRemoteOutputLimit) {
            $text = $text.Substring(0, $script:GuiReadyRemoteOutputLimit) + [Environment]::NewLine + '…（已截断）'
        }
        return (New-GuiReadyRemoteResult -Target $Target -Ok $true -Output $text -Started $start)
    } catch {
        $msg = ConvertTo-GuiReadyRemoteErrorText -Message ([string]$_.Exception.Message)
        return (New-GuiReadyRemoteResult -Target $Target -Ok $false -ErrorText $msg -Started $start)
    } finally {
        if ($ps) { try { $ps.Dispose() } catch { } }
        if ($session) {
            try { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Update-GuiReadyRemoteTestAudit {
    param($Target, [bool]$Ok, [double]$DurationSec)
    if (Get-Command Write-GuiReadyAudit -ErrorAction SilentlyContinue) {
        try {
            Write-GuiReadyAudit -Event 'host-test' -Level $(if ($Ok) { 'Info' } else { 'Warn' }) `
                -Detail ('{0} = {1}，耗时 {2} 秒' -f [string]$Target.Name, $(if ($Ok) { 'OK' } else { 'Failed' }), $DurationSec)
        } catch { }
    }
}

function Test-GuiReadyHostConnections {
    param(
        [string]$HostSpec = '',
        [int]$TimeoutSec = 60
    )
    $hosts = @(Resolve-GuiReadyHostTargets -Spec $HostSpec)
    $results = New-Object System.Collections.ArrayList
    $ok = 0
    $failed = 0
    $probe = @'
$cn = $env:COMPUTERNAME
$os = ''
try { $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $os = '未知系统' }
'{0}|{1}|{2}' -f $cn, $os, $PSVersionTable.PSVersion.ToString()
'@
    foreach ($h in $hosts) {
        $r = Invoke-GuiReadyRemoteCommand -Target $h -Command $probe -TimeoutSec $TimeoutSec
        $detail = ''
        if ($r.Ok) {
            $line = ''
            foreach ($ln in ($r.Output -split "`r?`n")) {
                if ($ln -match '\|') { $line = $ln; break }
            }
            $parts = @($line -split '\|')
            if ($parts.Count -ge 1 -and $parts[0]) {
                $detail = [string]$parts[0]
                if ($parts.Count -ge 2 -and $parts[1]) { $detail += ' / ' + [string]$parts[1] }
                if ($parts.Count -ge 3 -and $parts[2]) { $detail += ' / PowerShell ' + [string]$parts[2] }
            } else {
                $detail = '连接成功。'
            }
            $ok++
        } else {
            $detail = [string]$r.Error
            $failed++
        }
        Update-GuiReadyHostTestResult -Id ([string]$h.Id) -Ok ([bool]$r.Ok) -Message $detail
        Update-GuiReadyRemoteTestAudit -Target $h -Ok ([bool]$r.Ok) -DurationSec ([double]$r.DurationSec)
        [void]$results.Add([pscustomobject][ordered]@{
            HostId      = [string]$h.Id
            Name        = [string]$h.Name
            Address     = [string]$h.Address
            Status      = $(if ($r.Ok) { 'OK' } else { 'Failed' })
            Detail      = $detail
            Output      = [string]$r.Output
            DurationSec = [double]$r.DurationSec
        })
    }
    return [pscustomobject][ordered]@{
        Total   = $hosts.Count
        Ok      = $ok
        Failed  = $failed
        Results = @($results.ToArray())
    }
}

function Invoke-GuiReadyRemoteBatch {
    param(
        [string]$HostSpec = '',
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command,
        [int]$TimeoutSec = 120,
        [bool]$ContinueOnError = $true,
        [string]$TaskId = ''
    )
    if (-not $Command.Trim()) { throw '命令是空的。' }
    $hosts = @(Resolve-GuiReadyHostTargets -Spec $HostSpec)
    if (-not $TaskId) { $TaskId = 'batch-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') }

    $started = (Get-Date).ToString('o')
    $cmdText = [string]$Command
    if ($cmdText.Length -gt 4000) { $cmdText = $cmdText.Substring(0, 4000) + '…（已截断）' }

    $results = New-Object System.Collections.ArrayList
    $stopped = $false
    $succeeded = 0
    $failed = 0

    $batch = [pscustomobject][ordered]@{
        TaskId    = $TaskId
        StartedAt = $started
        EndedAt   = ''
        Command   = $cmdText
        Total     = $hosts.Count
        Succeeded = 0
        Failed    = 0
        Skipped   = 0
        Results   = @()
    }
    $file = Write-GuiReadyRemoteBatchFile -Batch $batch

    foreach ($h in $hosts) {
        if ($stopped) {
            [void]$results.Add([pscustomobject][ordered]@{
                HostId      = [string]$h.Id
                Name        = [string]$h.Name
                Address     = [string]$h.Address
                Status      = 'Skipped'
                Output      = ''
                Error       = '前一台主机失败，已跳过（未勾选“出错继续”）。'
                StartedAt   = (Get-Date).ToString('o')
                EndedAt     = (Get-Date).ToString('o')
                DurationSec = 0
            })
            continue
        }

        $r = Invoke-GuiReadyRemoteCommand -Target $h -Command $Command -TimeoutSec $TimeoutSec
        [void]$results.Add([pscustomobject][ordered]@{
            HostId      = [string]$h.Id
            Name        = [string]$h.Name
            Address     = [string]$h.Address
            Status      = [string]$r.Status
            Output      = [string]$r.Output
            Error       = [string]$r.Error
            StartedAt   = [string]$r.StartedAt
            EndedAt     = [string]$r.EndedAt
            DurationSec = [double]$r.DurationSec
        })
        if ($r.Ok) { $succeeded++ } else { $failed++; if (-not $ContinueOnError) { $stopped = $true } }

        $skipped = @($results.ToArray() | Where-Object { $_.Status -eq 'Skipped' }).Count
        $batch.Succeeded = $succeeded
        $batch.Failed    = $failed
        $batch.Skipped   = $skipped
        $batch.Results   = @($results.ToArray())
        $file = Write-GuiReadyRemoteBatchFile -Batch $batch

        if (Get-Command Write-GuiReadyAudit -ErrorAction SilentlyContinue) {
            try {
                Write-GuiReadyAudit -Event 'remote-host' -Level $(if ($r.Ok) { 'Info' } else { 'Warn' }) -TaskId $TaskId `
                    -Detail ('{0}（{1}）= {2}，耗时 {3} 秒' -f [string]$h.Name, [string]$h.Address, [string]$r.Status, $r.DurationSec)
            } catch { }
        }
    }

    $batch.EndedAt   = (Get-Date).ToString('o')
    $batch.Succeeded = $succeeded
    $batch.Failed    = $failed
    $batch.Skipped   = @($results.ToArray() | Where-Object { $_.Status -eq 'Skipped' }).Count
    $batch.Results   = @($results.ToArray())
    $file = Write-GuiReadyRemoteBatchFile -Batch $batch

    if (Get-Command Write-GuiReadyAudit -ErrorAction SilentlyContinue) {
        try {
            Write-GuiReadyAudit -Event 'remote-batch' -Level $(if ($failed -eq 0 -and $batch.Skipped -eq 0) { 'Success' } elseif ($succeeded -gt 0) { 'Warn' } else { 'Error' }) `
                -TaskId $TaskId -Detail ('{0} 台：成功 {1}、失败 {2}、跳过 {3}' -f $hosts.Count, $succeeded, $failed, $batch.Skipped)
        } catch { }
    }

    $out = [pscustomobject][ordered]@{
        TaskId    = $TaskId
        File      = $file
        StartedAt = $batch.StartedAt
        EndedAt   = $batch.EndedAt
        Command   = $batch.Command
        Total     = $batch.Total
        Succeeded = $batch.Succeeded
        Failed    = $batch.Failed
        Skipped   = $batch.Skipped
        Results   = @($batch.Results)
    }
    return $out
}

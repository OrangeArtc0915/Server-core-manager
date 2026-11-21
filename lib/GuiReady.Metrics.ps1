# 性能历史、告警规则与事件订阅。
#
# 数据落地：state\metrics\samples-yyyyMM.csv（每分钟/5 分钟一行）
# 告警规则：state\alerts\rules.json；运行状态：state\alerts\state.json
# 报表：reports\metrics-*.html（内联 SVG，不依赖外网）

function Get-GuiReadyMetricsRoot {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'state\metrics'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-GuiReadyMetricsSample {
    $cpu = 0.0
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop |
             Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
        if ($p) { $cpu = [double]$p.PercentProcessorTime }
    } catch { }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $totalKB = if ($os) { [double]$os.TotalVisibleMemorySize } else { 0 }
    $freeKB = if ($os) { [double]$os.FreePhysicalMemory } else { 0 }
    $memPct = if ($totalKB -gt 0) { 100.0 * ($totalKB - $freeKB) / $totalKB } else { 0 }

    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $env:SystemDrive + "'") -ErrorAction SilentlyContinue
    $totalGB = if ($disk) { [double]$disk.Size / 1GB } else { 0 }
    $freeGB = if ($disk) { [double]$disk.FreeSpace / 1GB } else { 0 }
    $diskPct = if ($totalGB -gt 0) { 100.0 * ($totalGB - $freeGB) / $totalGB } else { 0 }

    $netIn = 0.0
    $netOut = 0.0
    try {
        $nics = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
                Where-Object { $_.Name -notmatch 'Loopback|isatap|Pseudo' }
        foreach ($n in @($nics)) {
            $netIn += [double]$n.BytesReceivedPersec
            $netOut += [double]$n.BytesSentPersec
        }
    } catch { }

    $procCount = 0
    try { $procCount = @(Get-Process -ErrorAction SilentlyContinue).Count } catch { }
    $uptime = 0.0
    try { if ($os) { $uptime = ((Get-Date) - $os.LastBootUpTime).TotalHours } } catch { }

    return [pscustomobject]@{
        Time        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        CpuPct      = [Math]::Round($cpu, 1)
        MemPct      = [Math]::Round($memPct, 1)
        DiskFreeGB  = [Math]::Round($freeGB, 1)
        DiskTotalGB = [Math]::Round($totalGB, 1)
        DiskPct     = [Math]::Round($diskPct, 1)
        NetInKB     = [Math]::Round($netIn / 1KB, 1)
        NetOutKB    = [Math]::Round($netOut / 1KB, 1)
        ProcCount   = $procCount
        UptimeHours = [Math]::Round($uptime, 1)
    }
}

function Save-GuiReadyMetricsSample {
    param($Sample)
    if (-not $Sample) { $Sample = Get-GuiReadyMetricsSample }
    $file = Join-Path (Get-GuiReadyMetricsRoot) ('samples-' + (Get-Date -Format 'yyyyMM') + '.csv')
    $isNew = -not (Test-Path -LiteralPath $file)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($isNew) {
        'Time,CpuPct,MemPct,DiskFreeGB,DiskTotalGB,DiskPct,NetInKB,NetOutKB,ProcCount,UptimeHours' |
            Out-File -LiteralPath $file -Encoding UTF8
    }
    $line = [string]::Format($inv, '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}',
        $Sample.Time, $Sample.CpuPct, $Sample.MemPct, $Sample.DiskFreeGB, $Sample.DiskTotalGB,
        $Sample.DiskPct, $Sample.NetInKB, $Sample.NetOutKB, $Sample.ProcCount, $Sample.UptimeHours)
    $line | Out-File -LiteralPath $file -Append -Encoding UTF8
    return $Sample
}

function Get-GuiReadyMetricsHistory {
    param([int]$Days = 7, [int]$Max = 20000)
    $days = [Math]::Max(1, $Days)
    $since = (Get-Date).Date.AddDays(-1 * $days)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $rows = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-GuiReadyMetricsRoot) -Filter 'samples-*.csv' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            foreach ($r in @(Import-Csv -LiteralPath $f.FullName -ErrorAction Stop)) {
                $t = [datetime]::MinValue
                if (-not [datetime]::TryParse([string]$r.Time, [ref]$t)) { continue }
                if ($t -lt $since) { continue }
                $val = { param($name) $d = 0.0; [double]::TryParse([string]$r.$name, [Globalization.NumberStyles]::Float, $inv, [ref]$d) | Out-Null; $d }
                [void]$rows.Add([pscustomobject]@{
                    Time        = $t
                    CpuPct      = (& $val 'CpuPct')
                    MemPct      = (& $val 'MemPct')
                    DiskFreeGB  = (& $val 'DiskFreeGB')
                    DiskTotalGB = (& $val 'DiskTotalGB')
                    DiskPct     = (& $val 'DiskPct')
                    NetInKB     = (& $val 'NetInKB')
                    NetOutKB    = (& $val 'NetOutKB')
                    ProcCount   = [int](& $val 'ProcCount')
                    UptimeHours = (& $val 'UptimeHours')
                })
            }
        } catch { }
    }
    return @($rows | Sort-Object Time | Select-Object -Last $Max)
}

function Get-GuiReadyMetricsSummary {
    param($Rows)
    $rows = @($Rows)
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ Count = 0; CpuAvg = 0; CpuMax = 0; MemAvg = 0; MemMax = 0; DiskFreeMin = 0; NetMax = 0; PeakTime = '' }
    }
    $cpu = $rows | Measure-Object CpuPct -Average -Maximum
    $mem = $rows | Measure-Object MemPct -Average -Maximum
    $disk = $rows | Measure-Object DiskFreeGB -Minimum
    $net = $rows | Measure-Object NetInKB -Maximum
    $peak = $rows | Sort-Object CpuPct -Descending | Select-Object -First 1
    return [pscustomobject]@{
        Count      = $rows.Count
        CpuAvg     = [Math]::Round([double]$cpu.Average, 1)
        CpuMax     = [Math]::Round([double]$cpu.Maximum, 1)
        MemAvg     = [Math]::Round([double]$mem.Average, 1)
        MemMax     = [Math]::Round([double]$mem.Maximum, 1)
        DiskFreeMin = [Math]::Round([double]$disk.Minimum, 1)
        NetMax     = [Math]::Round([double]$net.Maximum, 1)
        PeakTime   = if ($peak) { $peak.Time.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
    }
}

function New-GuiReadyMetricsReport {
    param([int]$Days = 7, [string]$OutFile = '')
    $rows = @(Get-GuiReadyMetricsHistory -Days $Days -Max 20000)
    $sum = Get-GuiReadyMetricsSummary -Rows $rows
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    if (-not $OutFile) {
        $dir = Join-Path $root 'reports'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $OutFile = Join-Path $dir ('metrics-{0}d-{1}.html' -f $Days, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    $points = @($rows | Select-Object -Last 120)
    function Svg($title, $values, $color, $min, $max) {
        $w = 900; $h = 160; $pad = 24
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append(('<svg viewBox="0 0 {0} {1}" width="100%" height="{1}">' -f $w, $h))
        [void]$sb.Append(('<text x="10" y="16" fill="#9ca3af" font-size="12">{0}</text>' -f $title))
        [void]$sb.Append(('<polyline fill="none" stroke="{0}" stroke-width="2" points="' -f $color))
        $n = $values.Count
        if ($n -gt 0) {
            $span = $max - $min
            if ($span -le 0) { $span = 1 }
            for ($i = 0; $i -lt $n; $i++) {
                $x = $pad + ($w - 2 * $pad) * ($(if ($n -gt 1) { $i / ($n - 1) } else { 0 }))
                $y = $h - $pad - (($values[$i] - $min) / $span) * ($h - 2 * $pad)
                [void]$sb.Append(('{0:N1},{1:N1} ' -f $x, $y))
            }
        }
        [void]$sb.Append('"/></svg>')
        return $sb.ToString()
    }
    $cpuVals = @($points | ForEach-Object { [double]$_.CpuPct })
    $memVals = @($points | ForEach-Object { [double]$_.MemPct })
    $diskVals = @($points | ForEach-Object { [double]$_.DiskFreeGB })
    $cpuMin = 0; $cpuMax = 100
    $memMin = 0; $memMax = 100
    $diskMin = 0; $diskMax = [Math]::Max(1, ($sum.DiskFreeMin + 10))

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>SCM 性能报表</title>')
    [void]$sb.Append('<style>body{background:#0a0a0c;color:#e5eaf3;font-family:Segoe UI,Microsoft YaHei,sans-serif;margin:24px}')
    [void]$sb.Append('h1{font-size:22px;margin:0 0 4px}.sub{color:#a3a6ad;font-size:12px;margin-bottom:20px}')
    [void]$sb.Append('.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:20px}')
    [void]$sb.Append('.card{background:#14161e;border:1px solid #2b2b2c;border-radius:8px;padding:12px 16px;min-width:150px}')
    [void]$sb.Append('.card b{display:block;font-size:20px;color:#66b1ff;margin-top:4px}')
    [void]$sb.Append('.chart{background:#14161e;border:1px solid #2b2b2c;border-radius:8px;padding:10px;margin-bottom:12px}')
    [void]$sb.Append('table{border-collapse:collapse;width:100%;font-size:12px;background:#14161e}')
    [void]$sb.Append('th,td{border-bottom:1px solid #22232a;padding:6px 8px;text-align:left}th{color:#a3a6ad}')
    [void]$sb.Append('</style></head><body>')
    [void]$sb.Append(('<h1>Server Core Manager · 性能报表（{0} 天）</h1>' -f $Days))
    [void]$sb.Append(('<div class="sub">生成时间 {0} ｜ 样本 {1} 条 ｜ 峰值时间 {2}</div>' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $sum.Count, $sum.PeakTime))
    [void]$sb.Append('<div class="cards">')
    [void]$sb.Append(('<div class="card">CPU 平均<b>{0}%</b>峰值 {1}%</div>' -f $sum.CpuAvg, $sum.CpuMax))
    [void]$sb.Append(('<div class="card">内存 平均<b>{0}%</b>峰值 {1}%</div>' -f $sum.MemAvg, $sum.MemMax))
    [void]$sb.Append(('<div class="card">系统盘最小可用<b>{0} GB</b></div>' -f $sum.DiskFreeMin))
    [void]$sb.Append(('<div class="card">入站峰值<b>{0} KB/s</b></div>' -f $sum.NetMax))
    [void]$sb.Append('</div>')
    [void]$sb.Append('<div class="chart">'); [void]$sb.Append((Svg 'CPU %' $cpuVals '#409EFF' $cpuMin $cpuMax)); [void]$sb.Append('</div>')
    [void]$sb.Append('<div class="chart">'); [void]$sb.Append((Svg '内存 %' $memVals '#C084FC' $memMin $memMax)); [void]$sb.Append('</div>')
    [void]$sb.Append('<div class="chart">'); [void]$sb.Append((Svg '系统盘可用 GB' $diskVals '#67C23A' $diskMin $diskMax)); [void]$sb.Append('</div>')
    [void]$sb.Append('<h2 style="font-size:16px;margin:18px 0 8px">最近样本</h2><table><thead><tr><th>时间</th><th>CPU%</th><th>内存%</th><th>系统盘可用 GB</th><th>进程数</th></tr></thead><tbody>')
    foreach ($r in @($rows | Select-Object -Last 60)) {
        [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f $r.Time.ToString('yyyy-MM-dd HH:mm:ss'), $r.CpuPct, $r.MemPct, $r.DiskFreeGB, $r.ProcCount))
    }
    [void]$sb.Append('</tbody></table></body></html>')
    [System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Log ('性能报表已生成：' + $OutFile) 'OK'
    return $OutFile
}

function Install-GuiReadyMetricsTask {
    param([int]$IntervalMin = 5, [switch]$DryRun)
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Register-GuiReadyPlusTask -TaskName 'ScmPlus-Metrics' `
        -Runner (Join-Path $root 'gui\Run-GuiReadyMetrics.ps1') -Mode 'sample' `
        -IntervalMin $IntervalMin -DryRun:$DryRun)
}

function Remove-GuiReadyMetricsTask {
    param([switch]$DryRun)
    Unregister-GuiReadyPlusTask -TaskName 'ScmPlus-Metrics' -DryRun:$DryRun
}

# ---------------------------------------------------------------- 告警
function Get-GuiReadyAlertRoot {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'state\alerts'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Save-GuiReadyAlertRules {
    param($Rules)
    $file = Join-Path (Get-GuiReadyAlertRoot) 'rules.json'
    $json = @($Rules) | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-GuiReadyAlertRules {
    $file = Join-Path (Get-GuiReadyAlertRoot) 'rules.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            return @($j)
        } catch { }
    }
    $defaults = @(
        [pscustomobject]@{ Id = 'cpu-high';  Name = 'CPU 持续过高';   Metric = 'cpu';      Operator = 'gt'; Threshold = 90;  DurationMin = 5;  EventId = ''; EventLog = 'System'; Action = 'notify'; ActionId = ''; CooldownMin = 30; Enabled = $true }
        [pscustomobject]@{ Id = 'mem-high';  Name = '内存持续过高';   Metric = 'mem';      Operator = 'gt'; Threshold = 90;  DurationMin = 5;  EventId = ''; EventLog = 'System'; Action = 'notify'; ActionId = ''; CooldownMin = 30; Enabled = $true }
        [pscustomobject]@{ Id = 'disk-low';  Name = '系统盘空间不足'; Metric = 'diskfree'; Operator = 'lt'; Threshold = 10;  DurationMin = 10; EventId = ''; EventLog = 'System'; Action = 'notify'; ActionId = ''; CooldownMin = 60; Enabled = $true }
        [pscustomobject]@{ Id = 'event-boot'; Name = '意外关机/服务崩溃'; Metric = 'event'; Operator = 'gt'; Threshold = 0; DurationMin = 0; EventId = '41,6008,7031'; EventLog = 'System,Application'; Action = 'notify'; ActionId = ''; CooldownMin = 5; Enabled = $true }
        [pscustomobject]@{ Id = 'logon-fail'; Name = '登录失败 (4625)'; Metric = 'event'; Operator = 'gt'; Threshold = 0; DurationMin = 0; EventId = '4625'; EventLog = 'Security'; Action = 'notify'; ActionId = ''; CooldownMin = 10; Enabled = $true }
    )
    Save-GuiReadyAlertRules $defaults
    return $defaults
}

function Add-GuiReadyAlertRule {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('cpu', 'mem', 'diskfree', 'diskpct', 'event')][string]$Metric,
        [ValidateSet('gt', 'lt')][string]$Operator = 'gt',
        [double]$Threshold = 0,
        [int]$DurationMin = 5,
        [string]$EventId = '',
        [string]$EventLog = 'System,Application',
        [ValidateSet('notify', 'action', 'none')][string]$Action = 'notify',
        [string]$ActionId = '',
        [int]$CooldownMin = 30
    )
    $rules = @(Get-GuiReadyAlertRules)
    $id = 'rule-' + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + (Get-Random -Minimum 100 -Maximum 999)
    $rule = [pscustomobject]@{
        Id = $id; Name = $Name; Metric = $Metric; Operator = $Operator; Threshold = $Threshold
        DurationMin = $DurationMin; EventId = $EventId; EventLog = $EventLog
        Action = $Action; ActionId = $ActionId; CooldownMin = $CooldownMin; Enabled = $true
    }
    $rules += $rule
    Save-GuiReadyAlertRules $rules
    Write-Log ('已添加告警规则：' + $Name + '（' + $id + '）') 'OK'
    return $rule
}

function Remove-GuiReadyAlertRule {
    param([Parameter(Mandatory = $true)][string]$Id)
    $rules = @(Get-GuiReadyAlertRules | Where-Object { [string]$_.Id -ne $Id })
    Save-GuiReadyAlertRules $rules
    Write-Log ('已删除告警规则 ' + $Id) 'OK'
}

function Set-GuiReadyAlertRuleEnabled {
    param([Parameter(Mandatory = $true)][string]$Id, [bool]$Enabled = $true)
    $rules = @(Get-GuiReadyAlertRules)
    foreach ($r in $rules) { if ([string]$r.Id -eq $Id) { $r.Enabled = $Enabled } }
    Save-GuiReadyAlertRules $rules
    Write-Log ('告警规则 {0} → {1}' -f $Id, $(if ($Enabled) { '启用' } else { '停用' })) 'OK'
}

function Get-GuiReadyAlertState {
    $file = Join-Path (Get-GuiReadyAlertRoot) 'state.json'
    $rules = @{}
    $last = ''
    if (Test-Path -LiteralPath $file) {
        try {
            $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.LastEventCheck) { $last = [string]$j.LastEventCheck }
            if ($j.Rules) {
                foreach ($p in $j.Rules.PSObject.Properties) {
                    $rules[$p.Name] = @{ FirstBreach = [string]$p.Value.FirstBreach; LastFired = [string]$p.Value.LastFired }
                }
            }
        } catch { }
    }
    return @{ Rules = $rules; LastEventCheck = $last }
}

function Save-GuiReadyAlertState {
    param($State)
    $file = Join-Path (Get-GuiReadyAlertRoot) 'state.json'
    $json = @{ LastEventCheck = [string]$State.LastEventCheck; Rules = $State.Rules } | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-GuiReadyAlertHistory {
    param([string]$RuleId, [string]$Name, [string]$Value, [string]$Message, [string]$Action)
    $file = Join-Path (Get-GuiReadyAlertRoot) 'history.jsonl'
    $o = [ordered]@{ Time = (Get-Date).ToString('o'); RuleId = $RuleId; Name = $Name; Value = $Value; Message = $Message; Action = $Action }
    ($o | ConvertTo-Json -Compress) | Out-File -LiteralPath $file -Append -Encoding UTF8
}

function Send-GuiReadyAlertFire {
    param($Rule, [string]$Value, [string]$Detail, [switch]$DryRun)
    $text = ('{0}：{1}（规则 {2}）' -f $Rule.Name, $Value, $Rule.Id)
    if ($Detail) { $text += "`n" + $Detail }
    if ($DryRun) {
        Write-Log ('[预览] 告警 ' + $text) 'DRY'
    } else {
        if ($Rule.Action -eq 'action' -and $Rule.ActionId) {
            try {
                $root = [string]$script:GuiReadyRoot
                if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
                $job = 'alert-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
                Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'gui\Run-GuiReadyAction.ps1'),
                    '-Action', [string]$Rule.ActionId, '-JobId', $job
                ) | Out-Null
                Write-Log ('告警动作已提交：' + $Rule.ActionId) 'INFO'
            } catch {
                Write-Log ('告警动作启动失败：' + $_.Exception.Message) 'WARN'
            }
        }
        if ($Rule.Action -ne 'none' -and (Get-Command Send-GuiReadyNotify -ErrorAction SilentlyContinue)) {
            try { Send-GuiReadyNotify -Title ('SCM 告警：' + $Rule.Name) -Text $text -Level 'Warn' | Out-Null } catch { }
        }
        Write-GuiReadyAlertHistory -RuleId ([string]$Rule.Id) -Name ([string]$Rule.Name) -Value $Value -Message $text -Action ([string]$Rule.Action)
    }
    Write-Log ('告警触发：' + $text) 'WARN'
}

function Get-GuiReadyMaintenancePath {
    return (Join-Path (Get-GuiReadyAlertRoot) 'maintenance.json')
}

function Get-GuiReadyMaintenanceWindow {
    $file = Get-GuiReadyMaintenancePath
    if (Test-Path -LiteralPath $file) {
        try {
            $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $end = [datetime]::MinValue
            if ($j.End) { [void][datetime]::TryParse([string]$j.End, [ref]$end) }
            $active = ($end -ne [datetime]::MinValue -and (Get-Date) -lt $end)
            return [pscustomobject]@{ Active = $active; Start = [string]$j.Start; End = [string]$j.End; Reason = [string]$j.Reason }
        } catch { }
    }
    return [pscustomobject]@{ Active = $false; Start = ''; End = ''; Reason = '' }
}

function Set-GuiReadyMaintenanceWindow {
    param([int]$Minutes = 60, [string]$Reason = '维护窗口')
    $m = [Math]::Max(1, [Math]::Min(1440, $Minutes))
    $start = Get-Date
    $end = $start.AddMinutes($m)
    [pscustomobject]@{ Start = $start.ToString('o'); End = $end.ToString('o'); Reason = $Reason } |
        ConvertTo-Json | Out-File -LiteralPath (Get-GuiReadyMaintenancePath) -Encoding UTF8
    Write-Log ('维护窗口已开启：{0} → {1}（{2}）' -f $start.ToString('HH:mm'), $end.ToString('HH:mm'), $Reason) 'OK'
    return (Get-GuiReadyMaintenanceWindow)
}

function Clear-GuiReadyMaintenanceWindow {
    $file = Get-GuiReadyMaintenancePath
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    Write-Log '维护窗口已关闭。' 'OK'
}

function Test-GuiReadyInMaintenance {
    return (Get-GuiReadyMaintenanceWindow).Active
}

function Invoke-GuiReadyAlertCheck {
    param([switch]$DryRun)
    $sample = Get-GuiReadyMetricsSample
    if (-not $DryRun) { [void](Save-GuiReadyMetricsSample $sample) }
    $rules = @(Get-GuiReadyAlertRules)
    $state = Get-GuiReadyAlertState
    $now = Get-Date
    $fired = New-Object System.Collections.ArrayList

    $maint = Get-GuiReadyMaintenanceWindow
    if ($maint.Active) {
        if (-not $DryRun) {
            $state.LastEventCheck = $now.ToString('o')
            Save-GuiReadyAlertState $state
        }
        Write-Log ('处于维护窗口（到 {0}，{1}），本次告警已静默。' -f $maint.End, $maint.Reason) 'INFO'
        return [pscustomobject]@{ CheckedAt = $now.ToString('o'); Fired = @(); Sample = $sample; Maintenance = $true; MaintenanceEnd = $maint.End }
    }

    foreach ($r in @($rules | Where-Object { $_.Enabled -and $_.Metric -ne 'event' })) {
        $key = [string]$r.Id
        if (-not $state.Rules.ContainsKey($key)) { $state.Rules[$key] = @{ FirstBreach = ''; LastFired = '' } }
        $st = $state.Rules[$key]
        $value = 0.0
        switch ([string]$r.Metric) {
            'cpu'      { $value = [double]$sample.CpuPct }
            'mem'      { $value = [double]$sample.MemPct }
            'diskfree' { $value = [double]$sample.DiskFreeGB }
            'diskpct'  { $value = [double]$sample.DiskPct }
        }
        $breach = $(if ($r.Operator -eq 'lt') { $value -lt [double]$r.Threshold } else { $value -gt [double]$r.Threshold })
        if (-not $breach) { $st.FirstBreach = ''; continue }
        if (-not $st.FirstBreach) { $st.FirstBreach = $now.ToString('o') }
        $first = [datetime]::MinValue
        [void][datetime]::TryParse([string]$st.FirstBreach, [ref]$first)
        $duration = if ($first -ne [datetime]::MinValue) { ($now - $first).TotalMinutes } else { 0 }
        $last = [datetime]::MinValue
        if ($st.LastFired) { [void][datetime]::TryParse([string]$st.LastFired, [ref]$last) }
        $cooled = ($last -eq [datetime]::MinValue) -or (($now - $last).TotalMinutes -ge [double]$r.CooldownMin)
        if ($duration -ge [double]$r.DurationMin -and $cooled) {
            Send-GuiReadyAlertFire -Rule $r -Value ('{0} {1} {2}' -f $r.Metric, $r.Operator, $r.Threshold) -Detail ('当前值 {0}，持续 {1:N0} 分钟' -f $value, $duration) -DryRun:$DryRun
            if (-not $DryRun) { $st.LastFired = $now.ToString('o') }
            [void]$fired.Add($r.Id)
        }
    }

    $since = $now.AddMinutes(-5)
    if ($state.LastEventCheck) { [void][datetime]::TryParse([string]$state.LastEventCheck, [ref]$since) }
    foreach ($r in @($rules | Where-Object { $_.Enabled -and $_.Metric -eq 'event' })) {
        $ids = @()
        foreach ($x in ([string]$r.EventId -split ',')) { $n = 0; if ([int]::TryParse($x.Trim(), [ref]$n)) { $ids += $n } }
        if ($ids.Count -eq 0) { continue }
        $logs = @(([string]$r.EventLog -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($logs.Count -eq 0) { $logs = @('System', 'Application') }
        $matched = New-Object System.Collections.ArrayList
        foreach ($log in $logs) {
            try {
                $evts = Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since; Id = $ids } -MaxEvents 20 -ErrorAction Stop
                foreach ($e in @($evts)) {
                    $msg = [string]$e.Message
                    if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) + '…' }
                    [void]$matched.Add(('[{0}] {1} ({2}): {3}' -f $log, $e.ProviderName, $e.Id, $msg))
                }
            } catch { }
        }
        if ($matched.Count -gt 0) {
            $key = [string]$r.Id
            $st = if ($state.Rules.ContainsKey($key)) { $state.Rules[$key] } else { @{ FirstBreach = ''; LastFired = '' } }
            $last = [datetime]::MinValue
            if ($st.LastFired) { [void][datetime]::TryParse([string]$st.LastFired, [ref]$last) }
            if (($last -eq [datetime]::MinValue) -or (($now - $last).TotalMinutes -ge [double]$r.CooldownMin)) {
                $detail = (@($matched | Select-Object -First 5) -join "`n")
                Send-GuiReadyAlertFire -Rule $r -Value ('匹配 {0} 条事件' -f $matched.Count) -Detail $detail -DryRun:$DryRun
                $st.LastFired = $now.ToString('o')
                $state.Rules[$key] = $st
                [void]$fired.Add($r.Id)
            }
        }
    }

    if (-not $DryRun) {
        $state.LastEventCheck = $now.ToString('o')
        Save-GuiReadyAlertState $state
    }
    return [pscustomobject]@{ CheckedAt = $now.ToString('o'); Fired = @($fired); Sample = $sample }
}

function Install-GuiReadyAlertTask {
    param([int]$IntervalMin = 2, [switch]$DryRun)
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Register-GuiReadyPlusTask -TaskName 'ScmPlus-Alerts' `
        -Runner (Join-Path $root 'gui\Run-GuiReadyMetrics.ps1') -Mode 'alert-check' `
        -IntervalMin $IntervalMin -LimitMinutes 10 -DryRun:$DryRun)
}

function Remove-GuiReadyAlertTask {
    param([switch]$DryRun)
    Unregister-GuiReadyPlusTask -TaskName 'ScmPlus-Alerts' -DryRun:$DryRun
}

function Get-GuiReadyAlertHistory {
    param([int]$Max = 100)
    $file = Join-Path (Get-GuiReadyAlertRoot) 'history.jsonl'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $rows = @()
    foreach ($line in @(Get-Content -LiteralPath $file -Tail $Max -Encoding UTF8)) {
        try { $rows += ($line | ConvertFrom-Json) } catch { }
    }
    return @($rows | Sort-Object Time -Descending)
}

function Get-GuiReadyCriticalEvents {
    param([int]$Hours = 24, [int]$Max = 200)
    $since = (Get-Date).AddHours(-1 * [Math]::Max(1, $Hours))
    $rows = New-Object System.Collections.ArrayList
    foreach ($log in @('System', 'Application')) {
        try {
            $evts = Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since; Level = 1, 2 } -MaxEvents $Max -ErrorAction Stop
            foreach ($e in @($evts)) {
                $msg = [string]$e.Message
                if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '…' }
                [void]$rows.Add([pscustomobject]@{
                    Time     = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                    Log      = $log
                    Provider = [string]$e.ProviderName
                    Id       = [int]$e.Id
                    Level    = [string]$e.LevelDisplayName
                    Message  = $msg
                })
            }
        } catch { }
    }
    return @($rows | Sort-Object Time -Descending | Select-Object -First $Max)
}

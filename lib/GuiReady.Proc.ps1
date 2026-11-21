# 进程与端口分析：列表 / 树 / 详情 / 快照 / 结束进程。

function Get-GuiReadyProcessList {
    param([int]$Top = 80)
    $svc = @{}
    try {
        foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
            $pid2 = [int]$s.ProcessId
            if ($pid2 -gt 0) {
                if (-not $svc.ContainsKey($pid2)) { $svc[$pid2] = @() }
                $svc[$pid2] += [string]$s.Name
            }
        }
    } catch { }
    $ports = @{}
    try {
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            $pid2 = [int]$c.OwningProcess
            if (-not $ports.ContainsKey($pid2)) { $ports[$pid2] = @() }
            $ports[$pid2] += [int]$c.LocalPort
        }
    } catch { }
    $cmd = @{}
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            $cmd[[int]$p.ProcessId] = [string]$p.CommandLine
        }
    } catch { }

    $rows = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $cpu = 0.0
        try { $cpu = [double]$p.CPU } catch { }
        $mem = [Math]::Round([double]$p.WorkingSet64 / 1MB, 1)
        $cmdLine = if ($cmd.ContainsKey($p.Id)) { [string]$cmd[$p.Id] } else { '' }
        if ($cmdLine.Length -gt 240) { $cmdLine = $cmdLine.Substring(0, 240) + '…' }
        $rows += [pscustomobject]@{
            Id = $p.Id; Name = $p.ProcessName; CpuSec = [Math]::Round($cpu, 1); MemMB = $mem
            Session = $p.SessionId
            Services = $(if ($svc.ContainsKey($p.Id)) { ($svc[$p.Id] -join ',') } else { '' })
            Ports = $(if ($ports.ContainsKey($p.Id)) { (($ports[$p.Id] | Sort-Object -Unique) -join ',') } else { '' })
            CommandLine = $cmdLine
        }
    }
    return @($rows | Sort-Object CpuSec, MemMB -Descending | Select-Object -First ([Math]::Max(1, $Top)))
}

function Get-GuiReadyProcessTree {
    param([int]$Max = 400)
    $procs = @{}
    try { foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $procs[[int]$p.ProcessId] = $p } } catch { }
    if ($procs.Count -eq 0) { return @() }
    $children = @{}
    foreach ($p in $procs.Values) {
        $pp = [int]$p.ParentProcessId
        if (-not $children.ContainsKey($pp)) { $children[$pp] = @() }
        $children[$pp] += $p
    }
    $rows = New-Object System.Collections.ArrayList
    function Walk($proc, $depth) {
        if ($rows.Count -ge $Max) { return }
        $pad = ('  ' * $depth)
        [void]$rows.Add([pscustomobject]@{
            Id = [int]$proc.ProcessId; Name = [string]$proc.Name; Depth = $depth
            Text = ($pad + [string]$proc.Name + ' (' + [int]$proc.ProcessId + ')')
            Parent = [int]$proc.ParentProcessId
        })
        $key = [int]$proc.ProcessId
        if ($children.ContainsKey($key)) {
            foreach ($c in @($children[$key] | Sort-Object ProcessId)) { Walk $c ($depth + 1) }
        }
    }
    $roots = @($procs.Values | Where-Object { -not $procs.ContainsKey([int]$_.ParentProcessId) } | Sort-Object ProcessId)
    foreach ($r in $roots) { Walk $r 0 }
    return @($rows)
}

function Get-GuiReadyProcessDetail {
    param([Parameter(Mandatory = $true)][int]$Id)
    $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $Id) -ErrorAction Stop
    $os = Get-Process -Id $Id -ErrorAction SilentlyContinue
    $svc = @(Get-CimInstance Win32_Service -Filter ("ProcessId=" + $Id) -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
    $ports = @(Get-NetTCPConnection -OwningProcess $Id -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.LocalAddress + ':' + [string]$_.LocalPort })
    return [pscustomobject]@{
        Id = $Id; Name = [string]$p.Name; ParentId = [int]$p.ParentProcessId
        CommandLine = [string]$p.CommandLine; ExecutablePath = [string]$p.ExecutablePath
        CpuSec = $(if ($os) { [Math]::Round([double]$os.CPU, 1) } else { 0 })
        MemMB = $(if ($os) { [Math]::Round([double]$os.WorkingSet64 / 1MB, 1) } else { 0 })
        Threads = [int]$p.ThreadCount; Handles = [int]$p.HandleCount
        Services = ($svc -join ','); Ports = ($ports -join ',')
        StartTime = $(if ($os -and $os.StartTime) { $os.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
    }
}

function Save-GuiReadyProcessSnapshot {
    $top = @(Get-GuiReadyProcessList -Top 10)
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'state\metrics'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ('top-' + (Get-Date -Format 'yyyyMM') + '.csv')
    $isNew = -not (Test-Path -LiteralPath $file)
    if ($isNew) { 'Time,Id,Name,CpuSec,MemMB,CommandLine' | Out-File -LiteralPath $file -Encoding UTF8 }
    $t = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($p in $top) {
        $cmd = ([string]$p.CommandLine -replace '[\r\n,]', ' ')
        ('{0},{1},{2},{3},{4},{5}' -f $t, $p.Id, $p.Name, $p.CpuSec, $p.MemMB, $cmd) | Out-File -LiteralPath $file -Append -Encoding UTF8
    }
    Write-Log ('已记录 Top {0} 进程快照。' -f $top.Count) 'OK'
    return [pscustomobject]@{ Count = $top.Count; File = $file }
}

function Get-GuiReadyProcessHistory {
    param([int]$Days = 7, [int]$Max = 500)
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'state\metrics'
    $since = (Get-Date).Date.AddDays(-1 * [Math]::Max(1, $Days))
    $rows = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'top-*.csv' -File -ErrorAction SilentlyContinue)) {
        try {
            foreach ($r in @(Import-Csv -LiteralPath $f.FullName -ErrorAction Stop)) {
                $t = [datetime]::MinValue
                if (-not [datetime]::TryParse([string]$r.Time, [ref]$t)) { continue }
                if ($t -lt $since) { continue }
                $rows += [pscustomobject]@{ Time = $t.ToString('yyyy-MM-dd HH:mm:ss'); Id = [int]$r.Id; Name = [string]$r.Name; CpuSec = [double]$r.CpuSec; MemMB = [double]$r.MemMB; CommandLine = [string]$r.CommandLine }
            }
        } catch { }
    }
    return @($rows | Sort-Object Time -Descending | Select-Object -First $Max)
}

function Stop-GuiReadyProcess {
    param([Parameter(Mandatory = $true)][int]$Id, [switch]$DryRun)
    $protect = @('System', 'Idle', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsm', 'svchost')
    $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if (-not $p) { throw ('进程不存在：' + $Id) }
    if ($Id -le 4 -or $Id -eq $PID) { throw '拒绝结束系统关键进程或当前进程。' }
    if ($protect -contains $p.ProcessName) { throw ('拒绝结束关键进程：' + $p.ProcessName) }
    if ($DryRun) { Write-Log ('[预览] 将结束进程 {0} ({1})' -f $p.ProcessName, $Id) 'DRY'; return }
    Stop-Process -Id $Id -Force -ErrorAction Stop
    Write-Log ('已结束进程 {0} ({1})' -f $p.ProcessName, $Id) 'OK'
}

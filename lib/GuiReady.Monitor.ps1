# GuiReady 系统监控：一次采集 CPU / 内存 / 磁盘 / 关键服务 / 最近错误事件 / 占内存进程。
#
# 规范见 想法.md（系统监控与诊断，P1）。全部只读，不改系统。
# 采集必须放子进程：Get-Counter 一次取样约 1 秒、Get-WinEvent 查系统日志也要数百毫秒到数秒，
# 在 Server Core 上更慢（见 README「启动性能」那节）。
#
# 调用方：gui\Run-GuiReadyMonitor.ps1（页面）、Run-GuiReadyAction.ps1（文本版动作）。

function Get-GuiReadyMonitorCpu {
    # 优先 Get-Counter（多核平均、更准），拿不到就退回 CIM 的 LoadPercentage（瞬时值、精度差）
    $r = [pscustomobject]@{ Percent = $null; Source = ''; Error = '' }
    try {
        $c = Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop
        $r.Percent = [Math]::Round([double]$c.CounterSamples[0].CookedValue, 1)
        $r.Source  = 'Get-Counter'
        return $r
    } catch {
        $r.Error = $_.Exception.Message
    }
    try {
        $lp = @(Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -ExpandProperty LoadPercentage)
        $vals = @($lp | Where-Object { $null -ne $_ })
        if ($vals.Count -gt 0) {
            $r.Percent = [Math]::Round((($vals | Measure-Object -Average).Average), 1)
            $r.Source  = 'CIM（估算）'
        }
    } catch { }
    return $r
}

function Get-GuiReadyMonitorSnapshot {
    param([int]$EventCount = 15, [int]$TopProcess = 8)

    $notes = New-Object System.Collections.ArrayList
    $snap = [ordered]@{
        Stamp     = (Get-Date).ToString('s')
        Cpu       = $null
        Memory    = $null
        Disks     = @()
        Services  = @()
        Events    = @()
        Processes = @()
        Notes     = @()
    }

    # ---- CPU ----
    $cpu = Get-GuiReadyMonitorCpu
    $snap.Cpu = $cpu
    if ($cpu.Error) { [void]$notes.Add('Get-Counter 不可用，CPU 为 CIM 估算值。') }

    # ---- 内存 ----
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalKb = [double]$os.TotalVisibleMemorySize
        $freeKb  = [double]$os.FreePhysicalMemory
        $usedKb  = $totalKb - $freeKb
        $snap.Memory = [pscustomobject]@{
            TotalGB     = [Math]::Round($totalKb / 1MB, 1)
            UsedGB      = [Math]::Round($usedKb / 1MB, 1)
            FreeGB      = [Math]::Round($freeKb / 1MB, 1)
            UsedPercent = $(if ($totalKb -gt 0) { [Math]::Round($usedKb / $totalKb * 100, 1) } else { 0 })
        }
    } catch {
        [void]$notes.Add('内存信息读取失败: ' + $_.Exception.Message)
    }

    # ---- 磁盘（只列本地固定盘，且跳过 Size=0 的挂载点/空读卡器，否则会出现「0 GB / 0 GB」这种行）----
    try {
        foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)) {
            $size = [double]$d.Size
            $free = [double]$d.FreeSpace
            if ($size -le 0) { continue }
            $snap.Disks += [pscustomobject]@{
                Name        = [string]$d.DeviceID
                Label       = [string]$d.VolumeName
                TotalGB     = [Math]::Round($size / 1GB, 1)
                FreeGB      = [Math]::Round($free / 1GB, 1)
                UsedPercent = [Math]::Round(($size - $free) / $size * 100, 1)
            }
        }
    } catch {
        [void]$notes.Add('磁盘信息读取失败: ' + $_.Exception.Message)
    }

    # ---- 关键服务（本机没有的直接跳过，不当成异常）----
    $want = @(
        @{ Name = 'EventLog';            Why = '事件日志' }
        @{ Name = 'RpcSs';               Why = '远程过程调用' }
        @{ Name = 'Dnscache';            Why = 'DNS 客户端' }
        @{ Name = 'LanmanServer';        Why = '文件共享服务端' }
        @{ Name = 'LanmanWorkstation';   Why = '文件共享客户端' }
        @{ Name = 'WinRM';               Why = '远程管理（PowerShell Remoting）' }
        @{ Name = 'TermService';         Why = '远程桌面' }
        @{ Name = 'W32Time';             Why = '时间同步' }
        @{ Name = 'WindowsAdminCenter';  Why = 'Windows Admin Center' }
    )
    foreach ($w in $want) {
        try {
            $s = Get-Service -Name $w.Name -ErrorAction Stop
            $snap.Services += [pscustomobject]@{
                Name    = $s.Name
                Display = [string]$s.DisplayName
                Why     = $w.Why
                Status  = [string]$s.Status
                Start   = [string]$s.StartType
            }
        } catch { }
    }

    # ---- 最近的系统错误/警告（事件日志里最能反映"机器不舒服"的信号）----
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2 } -MaxEvents $EventCount -ErrorAction Stop)
        foreach ($e in $ev) {
            $msg = ''
            try { $msg = ([string]$e.Message -replace "`r?`n", ' ') } catch { }
            if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + ' …' }
            $snap.Events += [pscustomobject]@{
                Time     = $e.TimeCreated.ToString('MM-dd HH:mm:ss')
                Level    = [string]$e.LevelDisplayName
                Provider = [string]$e.ProviderName
                Id       = [int]$e.Id
                Message  = $msg
            }
        }
    } catch {
        [void]$notes.Add('系统事件日志读取失败（可能是权限或日志为空）: ' + $_.Exception.Message)
    }

    # ---- 占内存最多的进程 ----
    try {
        foreach ($p in @(Get-Process -ErrorAction Stop | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First $TopProcess)) {
            $snap.Processes += [pscustomobject]@{
                Name    = $p.ProcessName
                Id      = $p.Id
                MemMB   = [Math]::Round($p.WorkingSet64 / 1MB, 1)
                CpuSec  = $(try { [Math]::Round($p.CPU, 1) } catch { $null })
            }
        }
    } catch {
        [void]$notes.Add('进程列表读取失败: ' + $_.Exception.Message)
    }

    $snap.Notes = @($notes)
    return [pscustomobject]$snap
}

function Invoke-GuiReadyServiceControl {
    # 启停单个服务。只做这一件事，不做依赖分析 —— 依赖链上的服务该不该跟着停是运维判断。
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('Start', 'Stop', 'Restart')][string]$Action = 'Restart',
        [switch]$WhatIf
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Log '服务名为空。' 'ERROR'
        return $false
    }

    $svc = $null
    try { $svc = Get-Service -Name $Name -ErrorAction Stop } catch {
        Write-Log ('找不到服务 {0}（用服务名而不是显示名，例如 WinRM / LanmanServer）。' -f $Name) 'ERROR'
        return $false
    }

    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        Write-Log ('服务 {0}（{1}）当前状态: {2}  启动类型: {3}' -f $svc.Name, $svc.DisplayName, $svc.Status, $svc.StartType) 'DRY'
        Write-Log ('将执行: {0}-Service -Name {1}{2}' -f $Action, $svc.Name, $(if ($Action -ne 'Start') { ' -Force' } else { '' })) 'DRY'
        return $true
    }

    $risky = @('WinRM', 'TermService', 'LanmanServer', 'RpcSs', 'EventLog', 'DcomLaunch')
    if ($Action -ne 'Start' -and ($risky -contains $svc.Name)) {
        Write-Log ('注意: {0} 是远程管理/基础服务，停掉它可能直接断开你的远程会话。' -f $svc.Name) 'WARN'
    }

    try {
        switch ($Action) {
            'Start'   { Start-Service   -Name $svc.Name -ErrorAction Stop }
            'Stop'    { Stop-Service    -Name $svc.Name -Force -ErrorAction Stop }
            'Restart' { Restart-Service -Name $svc.Name -Force -ErrorAction Stop }
        }
    } catch {
        Write-Log ('{0} 失败: {1}' -f $Action, $_.Exception.Message) 'ERROR'
        return $false
    }

    # 复核一次：Start-Service 返回不代表服务真起来了（比如它依赖的服务没跑）
    Start-Sleep -Milliseconds 600
    $after = $null
    try { $after = Get-Service -Name $svc.Name -ErrorAction Stop } catch { }
    if ($after) {
        Write-Log ('{0} 完成: {1} → {2}' -f $Action, $svc.Status, $after.Status) `
            $(if ([string]$after.Status -eq 'Running' -or $Action -eq 'Stop') { 'OK' } else { 'WARN' })
    } else {
        Write-Log ('{0} 已下发（读不回状态）。' -f $Action) 'WARN'
    }
    return $true
}

function Show-GuiReadyMonitorStatus {
    # 「更多」页里的只读动作：把快照打成文本
    Write-Head '系统监控快照'
    $s = Get-GuiReadyMonitorSnapshot

    if ($s.Cpu) {
        Write-Log ('CPU: {0}%   （来源: {1}）' -f $s.Cpu.Percent, $s.Cpu.Source) 'OK'
    }
    if ($s.Memory) {
        Write-Log ('内存: 已用 {0} GB / 共 {1} GB（{2}%）' -f $s.Memory.UsedGB, $s.Memory.TotalGB, $s.Memory.UsedPercent) `
            $(if ($s.Memory.UsedPercent -ge 90) { 'WARN' } else { 'OK' })
    }
    foreach ($d in $s.Disks) {
        Write-Log ('磁盘 {0} {1}: 已用 {2}%（剩余 {3} GB / 共 {4} GB）' -f $d.Name, $d.Label, $d.UsedPercent, $d.FreeGB, $d.TotalGB) `
            $(if ($d.UsedPercent -ge 90) { 'WARN' } else { 'OK' })
    }

    Write-Head '关键服务'
    $stopped = 0
    foreach ($sv in $s.Services) {
        if ([string]$sv.Status -ne 'Running') { $stopped++ }
        Write-Log ('{0,-20} {1,-9} {2,-8} {3}' -f $sv.Name, $sv.Status, $sv.Start, $sv.Why) `
            $(if ([string]$sv.Status -eq 'Running') { 'OK' } else { 'WARN' })
    }
    if ($stopped -gt 0) { Write-Log ('有 {0} 个关键服务没在运行（看上面标 WARN 的）。' -f $stopped) 'WARN' }

    Write-Head '占内存最多的进程'
    foreach ($p in $s.Processes) { Write-Log ('{0,-24} PID {1,-7} {2,8} MB' -f $p.Name, $p.Id, $p.MemMB) 'INFO' }

    Write-Head ('最近的系统错误/警告（{0} 条）' -f @($s.Events).Count)
    foreach ($e in $s.Events) { Write-Log ('{0}  [{1}] {2} (Id={3})  {4}' -f $e.Time, $e.Level, $e.Provider, $e.Id, $e.Message) 'INFO' }

    foreach ($n in $s.Notes) { Write-Log $n 'WARN' }
}

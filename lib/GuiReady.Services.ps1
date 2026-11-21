# GuiReady 服务管理：全量服务 / 启停 / 启动类型 / 失败恢复 / 依赖。
#
# 与「监控与诊断 → 服务控制」的分工：那条动作是单个服务的快捷操作；
# 这里是专题页用的批量能力，改完都会回读真实状态，不靠命令返回值猜。

function Get-GuiReadyServiceList {
    param([string]$Filter = '')
    $rows = @()
    try {
        foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction Stop | Sort-Object Name)) {
            if ($Filter) {
                $blob = [string]$s.Name + ' ' + [string]$s.DisplayName
                if ($blob -notmatch [regex]::Escape($Filter)) { continue }
            }
            $rows += [pscustomobject]@{
                Name        = [string]$s.Name
                DisplayName = [string]$s.DisplayName
                State       = [string]$s.State
                StartMode   = [string]$s.StartMode
                StartName   = [string]$s.StartName
                ProcessId   = [int]$s.ProcessId
                PathName    = [string]$s.PathName
                Description = [string]$s.Description
            }
        }
    } catch {
        Write-Log ('读取服务列表失败：' + $_.Exception.Message) 'ERROR'
    }
    return $rows
}

function Resolve-GuiReadyServiceNames {
    param([string]$Names)
    $list = @()
    foreach ($n in ([string]$Names -split '[;,]')) { if ($n.Trim()) { $list += $n.Trim() } }
    if ($list.Count -eq 0) { throw '服务名不能为空' }
    return $list
}

function Set-GuiReadyServiceAction {
    param([Parameter(Mandatory = $true)][string]$Names,
          [Parameter(Mandatory = $true)][ValidateSet('start', 'stop', 'restart', 'pause', 'resume')][string]$Action,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    $list = @(Resolve-GuiReadyServiceNames $Names)
    $protected = @('RpcSs', 'DcomLaunch', 'PlugPlay', 'Power', 'Winmgmt', 'LSM')
    $results = @()
    foreach ($n in $list) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Log ('服务不存在：' + $n) 'ERROR'
            $results += [pscustomobject]@{ Name = $n; Ok = $false; Message = '服务不存在'; State = '' }
            continue
        }
        $isProtected = $protected -contains $svc.Name
        if ($DryRun) {
            Write-Log ('[预览] {0}（{1}）→ {2}{3}' -f $svc.Name, $svc.DisplayName, $Action, $(if ($isProtected) { '（系统关键服务，执行时会再确认）' } else { '' })) 'DRY'
            $results += [pscustomobject]@{ Name = $svc.Name; Ok = $true; Message = '预览'; State = [string]$svc.Status }
            continue
        }
        if ($isProtected -and ($Action -eq 'stop' -or $Action -eq 'restart')) {
            Write-Log ('跳过系统关键服务 {0}（停掉可能让系统不可用）' -f $svc.Name) 'WARN'
            $results += [pscustomobject]@{ Name = $svc.Name; Ok = $false; Message = '系统关键服务，已跳过'; State = [string]$svc.Status }
            continue
        }
        $ok = $true
        $msg = ''
        try {
            switch ($Action) {
                'start' {
                    if ($svc.Status -eq 'Running') { $msg = '本来就在运行' }
                    else { Start-Service -Name $svc.Name -ErrorAction Stop }
                }
                'stop' {
                    if ($svc.Status -eq 'Stopped') { $msg = '本来就是停止的' }
                    else { Stop-Service -Name $svc.Name -Force -ErrorAction Stop }
                }
                'restart' {
                    if ($svc.Status -eq 'Running') { Restart-Service -Name $svc.Name -Force -ErrorAction Stop }
                    else { Start-Service -Name $svc.Name -ErrorAction Stop }
                }
                'pause'   { Suspend-Service -Name $svc.Name -ErrorAction Stop }
                'resume'  { Resume-Service -Name $svc.Name -ErrorAction Stop }
            }
        } catch {
            $ok = $false
            $msg = $_.Exception.Message
            Write-Log ('{0} {1} 失败：{2}' -f $Action, $svc.Name, $msg) 'ERROR'
        }
        Start-Sleep -Milliseconds 400
        $now = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        $state = if ($now) { [string]$now.Status } else { '' }
        if ($ok -and -not $msg) { Write-Log ('{0} → {1}（现在 {2}）' -f $svc.Name, $Action, $state) 'OK' }
        elseif ($ok) { Write-Log ('{0}：{1}（现在 {2}）' -f $svc.Name, $msg, $state) 'INFO' }
        $results += [pscustomobject]@{ Name = $svc.Name; Ok = $ok; Message = $msg; State = $state }
    }
    return $results
}

function Set-GuiReadyServiceStartup {
    param([Parameter(Mandatory = $true)][string]$Names,
          [Parameter(Mandatory = $true)][ValidateSet('auto', 'delayed', 'manual', 'disabled')][string]$Mode,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    $list = @(Resolve-GuiReadyServiceNames $Names)
    $map = @{ auto = 'auto'; delayed = 'delayed-auto'; manual = 'demand'; disabled = 'disabled' }
    foreach ($n in $list) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Log ('服务不存在：' + $n) 'ERROR'; continue }
        if ($DryRun) { Write-Log ('[预览] {0} 启动类型 → {1}' -f $n, $Mode) 'DRY'; continue }
        # sc.exe 的 "start=" 必须作为独立 token，用数组传参避免被 PowerShell 吃掉等号
        $out = & sc.exe @('config', $n, 'start=', $map[$Mode]) 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Log ('{0} 启动类型修改失败：{1}' -f $n, ($out -join ' ')) 'ERROR'; continue }
        $now = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $n) -ErrorAction SilentlyContinue
        Write-Log ('{0} 启动类型 → {1}（回读 {2}）' -f $n, $Mode, $(if ($now) { [string]$now.StartMode } else { '未知' })) 'OK'
    }
}

function Set-GuiReadyServiceRecovery {
    param([Parameter(Mandatory = $true)][string]$Names,
          [int]$ResetDays = 1,
          [int]$RestartMinutes = 1,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    $list = @(Resolve-GuiReadyServiceNames $Names)
    if ($ResetDays -lt 1) { $ResetDays = 1 }
    if ($RestartMinutes -lt 1) { $RestartMinutes = 1 }
    $resetSec = $ResetDays * 86400
    $restartMs = $RestartMinutes * 60000
    foreach ($n in $list) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Log ('服务不存在：' + $n) 'ERROR'; continue }
        if ($DryRun) {
            Write-Log ('[预览] {0} 失败恢复：{1} 分钟内重启，{2} 天后重置计数' -f $n, $RestartMinutes, $ResetDays) 'DRY'
            continue
        }
        $actions = ('restart/{0}/restart/{0}/""/0' -f $restartMs)
        $out = & sc.exe @('failure', $n, 'reset=', [string]$resetSec, 'actions=', $actions) 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Log ('{0} 失败恢复设置失败：{1}' -f $n, ($out -join ' ')) 'ERROR'; continue }
        Write-Log ('{0} 失败恢复已设置（重启 / {1} 分钟，{2} 天重置）' -f $n, $RestartMinutes, $ResetDays) 'OK'
    }
}

function Get-GuiReadyServiceDetail {
    param([Parameter(Mandatory = $true)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { throw ('服务不存在：' + $Name) }
    $cim = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue
    $deps = @($svc.ServicesDependedOn | ForEach-Object { [string]$_.Name })
    $dependents = @($svc.DependentServices | ForEach-Object { [string]$_.Name })
    $failure = ''
    try { $failure = (& sc.exe @('qfailure', $Name) 2>&1) -join "`r`n" } catch { }
    return [pscustomobject]@{
        Name        = [string]$svc.Name
        DisplayName = [string]$svc.DisplayName
        State       = [string]$svc.Status
        StartType   = $(if ($cim) { [string]$cim.StartMode } else { '' })
        Account     = $(if ($cim) { [string]$cim.StartName } else { '' })
        PathName    = $(if ($cim) { [string]$cim.PathName } else { '' })
        DependsOn   = ($deps -join ',')
        Dependents  = ($dependents -join ',')
        Failure     = $failure
    }
}

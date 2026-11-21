# 新版功能的通用计划任务助手。
# 与 GuiReady.Ops.ps1 的 Register-GuiReadyOpsTask 同一套做法，但任务指向任意 runner，
# 供性能采样、告警检查、备份、事件订阅共用。

function Get-GuiReadyPlusTaskRoot {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'state\plus-tasks'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-GuiReadyPlusTaskState {
    param([Parameter(Mandatory = $true)][string]$TaskName)
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return [pscustomobject]@{ Name = $TaskName; State = [string]$t.State; Exists = $true }
    } catch {
        return [pscustomobject]@{ Name = $TaskName; State = 'Missing'; Exists = $false }
    }
}

function Register-GuiReadyPlusTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Runner,
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$ExtraArgs = '',
        [ValidateSet('interval', 'daily', 'weekly')][string]$Schedule = 'interval',
        [int]$IntervalMin = 5,
        [string]$Time = '03:00',
        [string]$Weekday = 'Monday',
        [ValidateSet('system', 'user')][string]$RunAs = 'system',
        [int]$LimitMinutes = 30,
        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $Runner)) { throw ('找不到运行器：' + $Runner) }
    $outFile = Join-Path (Get-GuiReadyPlusTaskRoot) ($TaskName + '.json')
    $argLine = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode {1} -OutFile "{2}"' -f $Runner, $Mode, $outFile
    if ($ExtraArgs) { $argLine += ' ' + $ExtraArgs }

    if ($DryRun) {
        Write-Log ('[预览] 将注册计划任务 {0}（{1}）：{2}' -f $TaskName, $Schedule, $argLine) 'DRY'
        return [pscustomobject]@{ Name = $TaskName; State = 'DryRun'; Exists = $false }
    }
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw '本机没有 ScheduledTasks 模块，无法创建计划任务。'
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    if ($Schedule -eq 'daily') {
        $trigger = New-ScheduledTaskTrigger -Daily -At $Time
    } elseif ($Schedule -eq 'weekly') {
        $day = 'Monday'
        foreach ($d in @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')) {
            if ($Weekday -ieq $d.Substring(0, [Math]::Min(3, $Weekday.Length)) -or $Weekday -ieq $d) { $day = $d; break }
        }
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $Time
    } else {
        $every = $IntervalMin
        if ($every -lt 1) { $every = 5 }
        $trigger = New-ScheduledTaskTrigger -Daily -At '00:00'
        $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' `
            -RepetitionInterval (New-TimeSpan -Minutes $every) `
            -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
    }

    if ($RunAs -eq 'system') {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    } else {
        $who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Highest
    }

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $LimitMinutes)
    $settings.StopIfGoingOnBatteries = $false

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    } catch {
        $msg = [string]$_.Exception.Message.Trim()
        if ($msg -match 'Access is denied|拒绝访问') {
            throw ('注册计划任务失败：权限不足。创建「' + $TaskName + '」需要管理员权限。')
        }
        throw ('注册计划任务失败：' + $msg)
    }
    if (-not ((Get-GuiReadyPlusTaskState $TaskName).Exists)) {
        throw ('计划任务 {0} 没有注册成功（任务计划程序服务可能不可用）' -f $TaskName)
    }
    Write-Log ('已注册计划任务 {0}（{1} 分钟）' -f $TaskName, $IntervalMin) 'OK'
    return (Get-GuiReadyPlusTaskState $TaskName)
}

function Unregister-GuiReadyPlusTask {
    param([Parameter(Mandatory = $true)][string]$TaskName, [switch]$DryRun)
    if ($DryRun) { Write-Log ('[预览] 将删除计划任务 ' + $TaskName) 'DRY'; return }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log ('已删除计划任务 ' + $TaskName) 'OK'
    } catch {
        if ((Get-GuiReadyPlusTaskState $TaskName).Exists) { throw }
        Write-Log ('计划任务 ' + $TaskName + ' 本来就不存在') 'INFO'
    }
}

# GuiReady 系统计划任务：查看 / 启停 / 立即运行 / 删除。
#
# 与「自动化」页的区别：那边管理本工具自己建的 ScmOps-* 任务；
# 这里管理 Windows 里已有的计划任务（含系统自带），只读视图默认过滤掉 ScmOps-*。

function Get-GuiReadySystemTasks {
    param([string]$Filter = '', [int]$Max = 300)
    $rows = @()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Sort-Object TaskPath, TaskName)
        foreach ($t in $tasks) {
            $full = ([string]$t.TaskPath + [string]$t.TaskName)
            if ($Filter -and $full -notmatch [regex]::Escape($Filter)) { continue }
            $info = $null
            try { $info = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction SilentlyContinue } catch { }
            $actions = @($t.Actions | ForEach-Object {
                $exe = [string]$_.Execute
                $arg = [string]$_.Arguments
                if ($arg.Length -gt 60) { $arg = $arg.Substring(0, 60) + '…' }
                ($exe + ' ' + $arg).Trim()
            })
            $rows += [pscustomobject]@{
                Name        = [string]$t.TaskName
                Path        = [string]$t.TaskPath
                FullName    = $full
                State       = [string]$t.State
                Author      = [string]$t.Author
                Actions     = ($actions -join ' | ')
                LastRun     = $(if ($info -and $info.LastRunTime) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { '' })
                LastResult  = $(if ($info) { [long]$info.LastTaskResult } else { 0 })
                NextRun     = $(if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { '' })
                IsOwn       = ([string]$t.TaskName).StartsWith('ScmOps-')
            }
            if ($rows.Count -ge $Max) { break }
        }
    } catch {
        Write-Log ('读取系统计划任务失败：' + $_.Exception.Message) 'ERROR'
    }
    return $rows
}

function Get-GuiReadySystemTaskDetail {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$TaskPath = '\')
    $t = Get-ScheduledTask -TaskName $Name -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $t) { throw ('找不到计划任务：' + $TaskPath + $Name) }
    $info = Get-ScheduledTaskInfo -TaskName $Name -TaskPath $TaskPath -ErrorAction SilentlyContinue
    $triggers = @($t.Triggers | ForEach-Object { [string]$_.CimClass.CimClassName })
    $actions = @($t.Actions | ForEach-Object { ([string]$_.Execute + ' ' + [string]$_.Arguments).Trim() })
    return [pscustomobject]@{
        Name        = [string]$t.TaskName
        Path        = [string]$t.TaskPath
        State       = [string]$t.State
        Author      = [string]$t.Author
        Description = [string]$t.Description
        UserId      = [string]$t.Principal.UserId
        RunLevel    = [string]$t.Principal.RunLevel
        LogonType   = [string]$t.Principal.LogonType
        Triggers    = ($triggers -join ',')
        Actions     = ($actions -join ' | ')
        LastRun     = $(if ($info -and $info.LastRunTime) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
        LastResult  = $(if ($info) { [long]$info.LastTaskResult } else { 0 })
        NextRun     = $(if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
    }
}

function Set-GuiReadySystemTaskAction {
    param([Parameter(Mandatory = $true)][string]$Name,
          [string]$TaskPath = '\',
          [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable', 'run', 'stop', 'remove')][string]$Action,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    $t = Get-ScheduledTask -TaskName $Name -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $t) { throw ('找不到计划任务：' + $TaskPath + $Name) }
    # 本工具自己的任务不允许在这里删（要到「自动化」页删，才会一并清理记录）
    if ($Action -eq 'remove' -and ([string]$t.TaskName).StartsWith('ScmOps-')) {
        throw 'ScmOps-* 是本工具创建的任务，请到「自动化」页删除，否则会留下孤儿记录'
    }
    if ($DryRun) { Write-Log ('[预览] 计划任务 {0}{1} → {2}' -f $TaskPath, $Name, $Action) 'DRY'; return }
    switch ($Action) {
        'enable'  { Enable-ScheduledTask -TaskName $Name -TaskPath $TaskPath -ErrorAction Stop | Out-Null }
        'disable' { Disable-ScheduledTask -TaskName $Name -TaskPath $TaskPath -ErrorAction Stop | Out-Null }
        'run'     { Start-ScheduledTask -TaskName $Name -TaskPath $TaskPath -ErrorAction Stop }
        'stop'    { Stop-ScheduledTask -TaskName $Name -TaskPath $TaskPath -ErrorAction Stop }
        'remove'  { Unregister-ScheduledTask -TaskName $Name -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop }
    }
    $now = Get-ScheduledTask -TaskName $Name -TaskPath $TaskPath -ErrorAction SilentlyContinue
    Write-Log ('{0}{1} → {2}（现在 {3}）' -f $TaskPath, $Name, $Action, $(if ($now) { [string]$now.State } else { '已删除' })) 'OK'
}

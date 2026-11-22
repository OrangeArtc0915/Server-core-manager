# GuiReady 系统计划任务：查看 / 启停 / 立即运行 / 删除。
#
# 与「自动化」页的区别：那边管理本工具自己建的 ScmOps-* 任务；
# 这里管理 Windows 里已有的计划任务（含系统自带），只读视图默认过滤掉 ScmOps-*。

function Get-GuiReadySystemTasks {
    param([string]$Filter = '', [int]$Max = 300)
    if (Test-GuiReadyLegacyApi 'Get-ScheduledTask') {
        return @(Get-GuiReadyLegacySystemTasks -Filter $Filter -Max $Max)
    }
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
    if (Test-GuiReadyLegacyApi 'Get-ScheduledTask') {
        return (Get-GuiReadyLegacySystemTaskDetail -Name $Name -TaskPath $TaskPath)
    }
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
    if (Test-GuiReadyLegacyApi 'Get-ScheduledTask') {
        return (Set-GuiReadyLegacySystemTask -Name $Name -TaskPath $TaskPath -Action $Action -DryRun:$DryRun)
    }
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

# ---------------------------------------------------------------- 2008 R2 兼容路径
# 2008 R2 没有 ScheduledTasks 模块，改用任务计划 COM（Schedule.Service）。
# 相比解析 schtasks 的本地化文本，COM 返回的是结构化数据，中英文系统都一样。

function Get-GuiReadyTaskService {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    return $svc
}

function Convert-GuiReadyTaskState {
    param($State)
    switch ([int]$State) {
        0 { return 'Unknown' }
        1 { return 'Disabled' }
        2 { return 'Queued' }
        3 { return 'Ready' }
        4 { return 'Running' }
        default { return [string]$State }
    }
}

function Read-GuiReadyLegacyTaskRows {
    param($Folder, [string]$Path, [string]$Filter, [int]$Max, [System.Collections.ArrayList]$Rows)

    foreach ($t in @($Folder.GetTasks(1))) {
        $full = $Path + [string]$t.Name
        if ($Filter -and $full -notmatch [regex]::Escape($Filter)) { continue }

        $acts = @()
        try {
            foreach ($a in @($t.Definition.Actions)) {
                $line = ([string]$a.Path + ' ' + [string]$a.Arguments).Trim()
                if ($line.Length -gt 100) { $line = $line.Substring(0, 100) + '…' }
                $acts += $line
            }
        } catch { }

        $last = ''
        try { if ($t.LastRunTime -and ([datetime]$t.LastRunTime).Year -gt 1999) { $last = ([datetime]$t.LastRunTime).ToString('yyyy-MM-dd HH:mm') } } catch { }
        $next = ''
        try { if ($t.NextRunTime -and ([datetime]$t.NextRunTime).Year -gt 1999) { $next = ([datetime]$t.NextRunTime).ToString('yyyy-MM-dd HH:mm') } } catch { }

        [void]$Rows.Add([pscustomobject]@{
            Name       = [string]$t.Name
            Path       = $Path
            FullName   = $full
            State      = (Convert-GuiReadyTaskState $t.State)
            Author     = ''
            Actions    = ($acts -join ' | ')
            LastRun    = $last
            LastResult = [long]$t.LastTaskResult
            NextRun    = $next
            IsOwn      = ([string]$t.Name).StartsWith('ScmOps-')
        })
        if ($Rows.Count -ge $Max) { return }
    }

    foreach ($sub in @($Folder.GetFolders(0))) {
        if ($Rows.Count -ge $Max) { return }
        Read-GuiReadyLegacyTaskRows -Folder $sub -Path ($Path + [string]$sub.Name + '\') -Filter $Filter -Max $Max -Rows $Rows
    }
}

function Get-GuiReadyLegacySystemTasks {
    param([string]$Filter = '', [int]$Max = 300)
    $rows = New-Object System.Collections.ArrayList
    try {
        $svc = Get-GuiReadyTaskService
        Read-GuiReadyLegacyTaskRows -Folder $svc.GetFolder('\') -Path '\' -Filter $Filter -Max $Max -Rows $rows
    } catch {
        Write-Log ('读取系统计划任务失败：' + $_.Exception.Message) 'ERROR'
    }
    return @($rows)
}

function Get-GuiReadyLegacySystemTaskDetail {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$TaskPath = '\')

    $svc = Get-GuiReadyTaskService
    $folder = $svc.GetFolder($TaskPath)
    $t = $null
    try { $t = $folder.GetTask($Name) } catch { }
    if (-not $t) { throw ('找不到计划任务：' + $TaskPath + $Name) }

    $triggers = @()
    $triggerNames = @{
        1 = 'Time'; 2 = 'Daily'; 3 = 'Weekly'; 4 = 'Monthly'; 5 = 'MonthlyDOW';
        6 = 'Idle'; 7 = 'Registration'; 8 = 'Boot'; 9 = 'Logon'; 11 = 'SessionStateChange'
    }
    try {
        foreach ($tr in @($t.Definition.Triggers)) {
            $n = [int]$tr.Type
            $triggers += $(if ($triggerNames.ContainsKey($n)) { $triggerNames[$n] } else { ('Type' + $n) })
        }
    } catch { }

    $actions = @()
    try { foreach ($a in @($t.Definition.Actions)) { $actions += ([string]$a.Path + ' ' + [string]$a.Arguments).Trim() } } catch { }

    $author = ''
    try { $author = [string]$t.Definition.RegistrationInfo.Author } catch { }

    $last = ''
    try { if ($t.LastRunTime -and ([datetime]$t.LastRunTime).Year -gt 1999) { $last = ([datetime]$t.LastRunTime).ToString('yyyy-MM-dd HH:mm:ss') } } catch { }
    $next = ''
    try { if ($t.NextRunTime -and ([datetime]$t.NextRunTime).Year -gt 1999) { $next = ([datetime]$t.NextRunTime).ToString('yyyy-MM-dd HH:mm:ss') } } catch { }

    $state = ''
    try { $state = Convert-GuiReadyTaskState $t.State } catch { }

    return [pscustomobject]@{
        Name        = [string]$t.Name
        Path        = $TaskPath
        State       = $state
        Author      = $author
        Description = ''
        UserId      = ''
        RunLevel    = ''
        LogonType   = ''
        Triggers    = ($triggers -join ',')
        Actions     = ($actions -join ' | ')
        LastRun     = $last
        LastResult  = [long]$t.LastTaskResult
        NextRun     = $next
    }
}

function Set-GuiReadyLegacySystemTask {
    param([Parameter(Mandatory = $true)][string]$Name,
          [string]$TaskPath = '\',
          [Parameter(Mandatory = $true)][string]$Action,
          [switch]$DryRun)

    if ($Action -eq 'remove' -and $Name.StartsWith('ScmOps-')) {
        throw 'ScmOps-* 是本工具创建的任务，请到「自动化」页删除，否则会留下孤儿记录'
    }

    $svc = Get-GuiReadyTaskService
    $folder = $svc.GetFolder($TaskPath)
    $t = $null
    try { $t = $folder.GetTask($Name) } catch { }
    if (-not $t) { throw ('找不到计划任务：' + $TaskPath + $Name) }

    if ($DryRun) { Write-Log ('[预览] 计划任务 {0}{1} → {2}' -f $TaskPath, $Name, $Action) 'DRY'; return }

    switch ($Action) {
        'enable'  { $t.Enabled = $true }
        'disable' { $t.Enabled = $false }
        'run'     { $t.Run($null) | Out-Null }
        'stop'    { $t.Stop(0) | Out-Null }
        'remove'  { $folder.DeleteTask($Name, 0) }
    }

    if ($Action -eq 'remove') {
        Write-Log ('{0}{1} → 已删除' -f $TaskPath, $Name) 'OK'
        return
    }
    $now = $null
    try { $now = $folder.GetTask($Name) } catch { }
    Write-Log ('{0}{1} → {2}（现在 {3}）' -f $TaskPath, $Name, $Action, $(if ($now) { Convert-GuiReadyTaskState $now.State } else { '未知' })) 'OK'
}

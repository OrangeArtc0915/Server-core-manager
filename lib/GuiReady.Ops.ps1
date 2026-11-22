# GuiReady 运维自动化：进程守护 / 计划任务 / 目录备份 / 端口巡检 / 下载队列。
#
# 设计取舍：
#   * 全部状态落在一个 state\ops\ops.json 里（原子写），不碰注册表；
#   * 「定时」一律交给 Windows 计划任务（ScmOps-*），不常驻守护进程 ——
#     Server Core 上多一个常驻进程就多一份要维护的东西；
#   * 计划任务的动作链通过 Run-GuiReadyAction.ps1 串起来，任务记录与审计照常落盘；
#   * 端口巡检与下载队列是纯按需操作（页面点一下跑一次），不排期。
#
# 约定：所有写入都用 UTF-8 无 BOM，与其它模块一致。

function Get-GuiReadyOpsRoot {
    $root = $script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Join-Path $root 'state\ops')
}

function Get-GuiReadyOpsStorePath {
    return (Join-Path (Get-GuiReadyOpsRoot) 'ops.json')
}

function ConvertTo-GuiReadyOpsHash {
    param($Object)
    $h = [ordered]@{}
    if ($null -eq $Object) { return $h }
    foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Get-GuiReadyOpsStore {
    $store = [ordered]@{
        Version   = 1
        Guard     = @()
        Plans     = @()
        Backups   = @()
        Patrols   = @()
        Downloads = @()
    }
    $p = Get-GuiReadyOpsStorePath
    if (-not (Test-Path -LiteralPath $p)) { return $store }
    try {
        $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @('Guard', 'Plans', 'Backups', 'Patrols', 'Downloads')) {
            $list = @()
            foreach ($e in @($j.$k)) {
                if ($null -eq $e) { continue }
                $list += , (ConvertTo-GuiReadyOpsHash $e)
            }
            $store[$k] = $list
        }
    } catch {
        Write-Log ('运维配置读取失败，按空配置继续：' + $_.Exception.Message) 'WARN'
    }
    return $store
}

function Save-GuiReadyOpsStore {
    param($Store)
    $dir = Get-GuiReadyOpsRoot
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $p = Get-GuiReadyOpsStorePath
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $tmp = $p + '.tmp'
    $json = $Store | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($tmp, $json, $utf8)
    Move-Item -LiteralPath $tmp -Destination $p -Force
}

function New-GuiReadyOpsId {
    param([string]$Prefix)
    $chars = 'abcdefghijkmnpqrstuvwxyz23456789'
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 6; $i++) { [void]$sb.Append($chars[(Get-Random -Maximum $chars.Length)]) }
    return ('{0}-{1}' -f $Prefix, $sb.ToString())
}

# ---------------------------------------------------------------- 计划任务

function Get-GuiReadyOpsTaskName {
    param([string]$Kind, [string]$Id)
    return ('ScmOps-{0}-{1}' -f $Kind, $Id)
}

function Get-GuiReadyOpsTaskState {
    param([string]$TaskName)
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return [string]$t.State
    } catch {
        return ''
    }
}

function Register-GuiReadyOpsTask {
    param(
        [string]$TaskName,
        [string]$Mode,
        [string]$Id,
        [ValidateSet('interval', 'daily', 'weekly')][string]$Schedule = 'interval',
        [int]$IntervalMin = 5,
        [string]$Time = '03:00',
        [string]$Weekday = 'Monday',
        [ValidateSet('user', 'system')][string]$RunAs = 'user',
        [switch]$DryRun
    )

    $root = $script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $scriptPath = Join-Path $root 'gui\Run-GuiReadyOps.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw ('找不到运行器：' + $scriptPath) }

    $outFile = Join-Path (Get-GuiReadyOpsRoot) ('task-{0}.json' -f $TaskName)
    $argLine = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode {1} -Id {2} -OutFile "{3}"' -f `
        $scriptPath, $Mode, $Id, $outFile

    if ($DryRun) {
        Write-Log ('[预览] 将注册计划任务 {0}（{1}，{2}）：{3}' -f $TaskName, $Schedule, $RunAs, $argLine) 'DRY'
        return
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
        # 不用 -Once + [TimeSpan]::MaxValue：那个值会生成 P99999999DT23H59M59S，
        # 任务计划程序直接判「格式或范围不对」（实测 0x80041318）。
        # 改成「每天 0 点触发 + 重复 1 天」，等价于全天每 N 分钟一次，且每天自动续上。
        $trigger = New-ScheduledTaskTrigger -Daily -At '00:00'
        $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' `
            -RepetitionInterval (New-TimeSpan -Minutes $every) `
            -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
    }

    if ($RunAs -eq 'system') {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    } else {
        $who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        # Interactive：只在该用户登录时跑，任务落在用户会话里（GUI 程序才看得见）
        $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Highest
    }

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 60)
    $settings.StopIfGoingOnBatteries = $false

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    } catch {
        $msg = [string]$_.Exception.Message.Trim()
        if ($msg -match 'Access is denied|拒绝访问') {
            throw ('注册计划任务失败：权限不足。创建「' + $TaskName + '」需要管理员权限，请以管理员身份重开本工具。')
        }
        throw ('注册计划任务失败：' + $msg)
    }
    # 注册失败时 CIM 偶尔只写一条非终止错误，必须回查一遍，
    # 否则界面会显示「添加成功」但任务根本不存在。
    if (-not (Get-GuiReadyOpsTaskState $TaskName)) {
        throw ('计划任务 {0} 没有注册成功（任务计划程序服务可能不可用）' -f $TaskName)
    }
    Write-Log ('已注册计划任务 {0}（{1}）' -f $TaskName, $principal.UserId) 'OK'
}

function Unregister-GuiReadyOpsTask {
    param([string]$TaskName, [switch]$DryRun)
    if (-not $TaskName) { return }
    if ($DryRun) { Write-Log ('[预览] 将删除计划任务 ' + $TaskName) 'DRY'; return }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log ('已删除计划任务 ' + $TaskName) 'OK'
    } catch {
        Write-Log ('删除计划任务 {0} 失败（可能本来就不存在）：{1}' -f $TaskName, $_.Exception.Message) 'WARN'
    }
}

function Set-GuiReadyOpsTaskEnabled {
    param([string]$TaskName, [bool]$Enabled, [switch]$DryRun)
    if ($DryRun) { Write-Log ('[预览] 计划任务 {0} 将设为 {1}' -f $TaskName, $(if ($Enabled) { '启用' } else { '暂停' })) 'DRY'; return }
    try {
        if ($Enabled) { Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
    } catch {
        throw ('改计划任务状态失败：' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 进程守护

function Test-GuiReadyGuardProcess {
    param([string]$Exe)
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($Exe)
    if (-not $leaf) { return @() }
    $procs = @(Get-CimInstance Win32_Process -Filter ("Name='{0}.exe'" -f $leaf) -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }
    $want = [string]$Exe
    try { $want = [System.IO.Path]::GetFullPath($Exe) } catch { }
    $hit = @($procs | Where-Object {
        $p = $null
        try { $p = [string]$_.ExecutablePath } catch { }
        $p -and ($p.TrimEnd('\') -ieq $want.TrimEnd('\'))
    })
    if ($hit.Count -gt 0) { return $hit }
    return $procs
}

# 通知钩子：通知模块不在时安静跳过（Ops 不应依赖 Notify 才能跑）
function Send-GuiReadyOpsAlert {
    param([string]$Title, [string]$Text, [string]$Level = 'Warn')
    if (-not (Get-Command Send-GuiReadyNotify -ErrorAction SilentlyContinue)) { return }
    try { Send-GuiReadyNotify -Title $Title -Text $Text -Level $Level | Out-Null } catch { }
}

function New-GuiReadyGuard {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Args = '',
        [string]$WorkDir = '',
        [int]$IntervalMin = 1,
        [int]$DelaySec = 15,
        [ValidateSet('user', 'system')][string]$RunAs = 'user',
        [switch]$DryRun
    )

    $full = $Exe
    try { $full = [System.IO.Path]::GetFullPath($Exe) } catch { }
    if (-not (Test-Path -LiteralPath $full)) { throw ('找不到要守护的程序：' + $Exe) }
    if (-not $WorkDir) { $WorkDir = Split-Path -Parent $full }

    $id = New-GuiReadyOpsId 'guard'
    $task = Get-GuiReadyOpsTaskName 'Guard' $id
    Register-GuiReadyOpsTask -TaskName $task -Mode 'guard-check' -Id $id -Schedule 'interval' `
        -IntervalMin $IntervalMin -RunAs $RunAs -DryRun:$DryRun

    $entry = [ordered]@{
        Id           = $id
        Name         = $Name
        Exe          = $full
        Args         = $Args
        WorkDir      = $WorkDir
        IntervalMin  = $IntervalMin
        DelaySec     = $DelaySec
        RunAs        = $RunAs
        Enabled      = $true
        CreatedAt    = (Get-Date).ToString('o')
        LastCheck    = ''
        LastAction   = ''
        Failures     = 0
        NextAttempt  = ''
    }

    if (-not $DryRun) {
        $store = Get-GuiReadyOpsStore
        $store.Guard += , $entry
        Save-GuiReadyOpsStore $store
        Write-Log ('守护已添加：{0} → {1}（每 {2} 分钟检查，{3} 秒退避）' -f $Name, $full, $IntervalMin, $DelaySec) 'OK'
    } else {
        Write-Log ('[预览] 将添加守护：{0} → {1}（每 {2} 分钟检查，{3} 秒退避）' -f $Name, $full, $IntervalMin, $DelaySec) 'DRY'
    }
    return [pscustomobject]$entry
}

function Remove-GuiReadyGuard {
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DryRun)
    $store = Get-GuiReadyOpsStore
    $hit = @($store.Guard | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的守护') }
    Unregister-GuiReadyOpsTask -TaskName (Get-GuiReadyOpsTaskName 'Guard' $Id) -DryRun:$DryRun
    if ($DryRun) { return }
    $store.Guard = @($store.Guard | Where-Object { $_.Id -ne $Id })
    Save-GuiReadyOpsStore $store
    Write-Log ('守护已删除：' + $hit[0].Name) 'OK'
}

function Set-GuiReadyGuardEnabled {
    param([Parameter(Mandatory = $true)][string]$Id, [bool]$Enabled, [switch]$DryRun)
    $store = Get-GuiReadyOpsStore
    $hit = @($store.Guard | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的守护') }
    Set-GuiReadyOpsTaskEnabled -TaskName (Get-GuiReadyOpsTaskName 'Guard' $Id) -Enabled $Enabled -DryRun:$DryRun
    if ($DryRun) { return }
    $hit[0].Enabled = $Enabled
    Save-GuiReadyOpsStore $store
    Write-Log ('守护 {0} 已{1}' -f $hit[0].Name, $(if ($Enabled) { '启用' } else { '暂停' })) 'OK'
}

function Invoke-GuiReadyGuardCheck {
    param([string]$Id = '', [switch]$DryRun)

    $store = Get-GuiReadyOpsStore
    $results = @()
    $targets = @($store.Guard | Where-Object { (-not $Id) -or $_.Id -eq $Id })
    if ($Id -and $targets.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的守护') }

    foreach ($g in $targets) {
        $now = Get-Date
        $procs = @(Test-GuiReadyGuardProcess -Exe ([string]$g.Exe))
        $entry = [ordered]@{
            Id = $g.Id; Name = $g.Name; Running = $false; Action = 'none'; Message = ''; At = $now.ToString('o')
        }

        if ($procs.Count -gt 0) {
            $entry.Running = $true
            $entry.Action = 'running'
            $entry.Message = ('进程在运行（PID {0}）' -f $procs[0].ProcessId)
            $g.Failures = 0
            $g.NextAttempt = ''
        } else {
            $next = $null
            if ($g.NextAttempt) {
                try { $next = [datetime]::Parse([string]$g.NextAttempt) } catch { $next = $null }
            }
            if ($next -and $now -lt $next) {
                $entry.Action = 'backoff'
                $entry.Message = ('退避中，下次 {0}' -f $next.ToString('HH:mm:ss'))
            } elseif ($DryRun) {
                $entry.Action = 'dry'
                $entry.Message = ('[预览] 进程不在，将启动 ' + $g.Exe)
            } else {
                try {
                    $splat = @{ FilePath = [string]$g.Exe }
                    if ($g.Args) { $splat['ArgumentList'] = [string]$g.Args }
                    if ($g.WorkDir -and (Test-Path -LiteralPath ([string]$g.WorkDir))) { $splat['WorkingDirectory'] = [string]$g.WorkDir }
                    Start-Process @splat | Out-Null
                    $entry.Action = 'started'
                    $entry.Message = '进程不在，已重新拉起'
                    $g.Failures = 0
                    $g.NextAttempt = ''
                    Write-Log ('守护 {0}：进程不在，已启动 {1}' -f $g.Name, $g.Exe) 'OK'
                } catch {
                    $g.Failures = [int]$g.Failures + 1
                    $delay = [int]$g.DelaySec
                    if ($delay -le 0) { $delay = 15 }
                    $power = [Math]::Min(5, [Math]::Max(0, [int]$g.Failures - 1))
                    $backoff = [int][Math]::Min(300, $delay * [Math]::Pow(2, $power))
                    $g.NextAttempt = (Get-Date).AddSeconds($backoff).ToString('o')
                    $entry.Action = 'failed'
                    $entry.Message = ('启动失败（第 {0} 次），{1} 秒后再试：{2}' -f $g.Failures, $backoff, $_.Exception.Message)
                    Write-Log ('守护 {0}：' + $entry.Message) 'ERROR'
                    Send-GuiReadyOpsAlert -Title ('守护启动失败：' + $g.Name) -Text $entry.Message -Level 'Error'
                }
            }
        }

        $g.LastCheck = $entry.At
        $g.LastAction = $entry.Action
        $results += [pscustomobject]$entry
    }

    if (-not $DryRun) { Save-GuiReadyOpsStore $store }
    return $results
}

# ---------------------------------------------------------------- 计划任务（动作链）

function ConvertTo-GuiReadyPlanChain {
    param([string]$Chain)
    $list = @()
    foreach ($one in ([string]$Chain -split '[;,\r\n]+')) {
        $t = $one.Trim()
        if ($t) { $list += $t }
    }
    return $list
}

function New-GuiReadyPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Chain,
        [ValidateSet('interval', 'daily', 'weekly')][string]$Schedule = 'interval',
        [int]$IntervalMin = 60,
        [string]$Time = '03:00',
        [string]$Weekday = 'Monday',
        [ValidateSet('user', 'system')][string]$RunAs = 'user',
        [switch]$DryRun
    )

    $chainList = @(ConvertTo-GuiReadyPlanChain $Chain)
    if ($chainList.Count -eq 0) { throw '动作链是空的：至少填一个动作 Id（用 ; 分隔）' }

    $known = @()
    if (Get-Command Get-GuiReadyActions -ErrorAction SilentlyContinue) {
        $known = @(Get-GuiReadyActions | ForEach-Object { [string]$_.Id })
    }
    $unknown = @($chainList | Where-Object { $known.Count -gt 0 -and ($known -notcontains $_) })
    if ($unknown.Count -gt 0) { throw ('动作链里有不存在的动作：' + ($unknown -join '、')) }

    $id = New-GuiReadyOpsId 'plan'
    Register-GuiReadyOpsTask -TaskName (Get-GuiReadyOpsTaskName 'Plan' $id) -Mode 'plan-run' -Id $id `
        -Schedule $Schedule -IntervalMin $IntervalMin -Time $Time -Weekday $Weekday -RunAs $RunAs -DryRun:$DryRun

    $entry = [ordered]@{
        Id          = $id
        Name        = $Name
        Chain       = ($chainList -join ';')
        Schedule    = $Schedule
        IntervalMin = $IntervalMin
        Time        = $Time
        Weekday     = $Weekday
        RunAs       = $RunAs
        Enabled     = $true
        CreatedAt   = (Get-Date).ToString('o')
        LastRun     = ''
        LastResult  = ''
    }

    if (-not $DryRun) {
        $store = Get-GuiReadyOpsStore
        $store.Plans += , $entry
        Save-GuiReadyOpsStore $store
        Write-Log ('计划已添加：{0}（{1}，动作链 {2}）' -f $Name, $Schedule, ($chainList -join ' → ')) 'OK'
    } else {
        Write-Log ('[预览] 将添加计划：{0}（{1}，动作链 {2}）' -f $Name, $Schedule, ($chainList -join ' → ')) 'DRY'
    }
    return [pscustomobject]$entry
}

function Remove-GuiReadyPlan {
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DryRun)
    $store = Get-GuiReadyOpsStore
    $hit = @($store.Plans | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的计划') }
    Unregister-GuiReadyOpsTask -TaskName (Get-GuiReadyOpsTaskName 'Plan' $Id) -DryRun:$DryRun
    if ($DryRun) { return }
    $store.Plans = @($store.Plans | Where-Object { $_.Id -ne $Id })
    Save-GuiReadyOpsStore $store
    Write-Log ('计划已删除：' + $hit[0].Name) 'OK'
}

function Set-GuiReadyPlanEnabled {
    param([Parameter(Mandatory = $true)][string]$Id, [bool]$Enabled, [switch]$DryRun)
    $store = Get-GuiReadyOpsStore
    $hit = @($store.Plans | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的计划') }
    Set-GuiReadyOpsTaskEnabled -TaskName (Get-GuiReadyOpsTaskName 'Plan' $Id) -Enabled $Enabled -DryRun:$DryRun
    if ($DryRun) { return }
    $hit[0].Enabled = $Enabled
    Save-GuiReadyOpsStore $store
}

function Invoke-GuiReadyPlan {
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DryRun)

    $store = Get-GuiReadyOpsStore
    $hit = @($store.Plans | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的计划') }
    $plan = $hit[0]
    $chain = @(ConvertTo-GuiReadyPlanChain ([string]$plan.Chain))

    $root = $script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $runner = Join-Path $root 'gui\Run-GuiReadyAction.ps1'
    $log = Join-Path $root ('logs\ops-plan-{0}.log' -f $plan.Id)

    if ($DryRun) {
        Write-Log ('[预览] 计划 {0} 将依次执行：{1}' -f $plan.Name, ($chain -join ' → ')) 'DRY'
        return
    }

    Write-Log ('计划 {0} 开始：{1}' -f $plan.Name, ($chain -join ' → ')) 'STEP'
    $ok = 0
    $fail = 0
    foreach ($aid in $chain) {
        Write-Log ('→ 动作 ' + $aid) 'STEP'
        try {
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Action $aid -LogFile $log
            if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++ }
        } catch {
            $fail++
            Write-Log ('动作 {0} 启动失败：{1}' -f $aid, $_.Exception.Message) 'ERROR'
        }
    }

    $plan.LastRun = (Get-Date).ToString('o')
    $plan.LastResult = ('成功 {0} / 失败 {1}' -f $ok, $fail)
    Save-GuiReadyOpsStore $store
    Write-Log ('计划 {0} 结束：{1}' -f $plan.Name, $plan.LastResult) $(if ($fail -eq 0) { 'OK' } else { 'WARN' })
    return [pscustomobject]@{ Id = $plan.Id; Ok = $ok; Failed = $fail; LastRun = $plan.LastRun }
}

# ---------------------------------------------------------------- 目录备份 + 保留

function Get-GuiReadySafeName {
    param([string]$Text)
    $s = [string]$Text
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $s = $s.Replace([string]$c, '_') }
    $s = $s -replace '\s+', '-'
    if (-not $s) { $s = 'backup' }
    return $s
}

function New-GuiReadyBackupJob {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [ValidateSet('zip', 'copy')][string]$Mode = 'zip',
        [int]$Keep = 3,
        [string]$Time = '02:00',
        [ValidateSet('user', 'system')][string]$RunAs = 'user',
        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $Source)) { throw ('源目录不存在：' + $Source) }
    $src = [System.IO.Path]::GetFullPath($Source)
    $dst = [System.IO.Path]::GetFullPath($Target)
    if ($dst.TrimEnd('\') -ieq $src.TrimEnd('\')) { throw '目标目录不能和源目录相同' }
    if ($dst.ToLower().StartsWith($src.TrimEnd('\').ToLower() + '\')) {
        throw '目标目录不能放在源目录里面（会把备份本身也打包进去）'
    }
    if ($Keep -lt 1) { $Keep = 1 }

    $id = New-GuiReadyOpsId 'bak'
    Register-GuiReadyOpsTask -TaskName (Get-GuiReadyOpsTaskName 'Backup' $id) -Mode 'backup-run' -Id $id `
        -Schedule 'daily' -Time $Time -RunAs $RunAs -DryRun:$DryRun

    $entry = [ordered]@{
        Id         = $id
        Name       = $Name
        Source     = $src
        Target     = $dst
        Mode       = $Mode
        Keep       = $Keep
        Time       = $Time
        RunAs      = $RunAs
        Enabled    = $true
        CreatedAt  = (Get-Date).ToString('o')
        LastRun    = ''
        LastResult = ''
        LastFile   = ''
    }

    if (-not $DryRun) {
        $store = Get-GuiReadyOpsStore
        $store.Backups += , $entry
        Save-GuiReadyOpsStore $store
        Write-Log ('备份任务已添加：{0} → {1}（每天 {2}，保留 {3} 份）' -f $src, $dst, $Time, $Keep) 'OK'
    } else {
        Write-Log ('[预览] 将添加备份任务：{0} → {1}（每天 {2}，保留 {3} 份）' -f $src, $dst, $Time, $Keep) 'DRY'
    }
    return [pscustomobject]$entry
}

function Remove-GuiReadyBackupJob {
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DryRun)
    $store = Get-GuiReadyOpsStore
    $hit = @($store.Backups | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的备份任务') }
    Unregister-GuiReadyOpsTask -TaskName (Get-GuiReadyOpsTaskName 'Backup' $Id) -DryRun:$DryRun
    if ($DryRun) { return }
    $store.Backups = @($store.Backups | Where-Object { $_.Id -ne $Id })
    Save-GuiReadyOpsStore $store
    Write-Log ('备份任务已删除：' + $hit[0].Name) 'OK'
}

function Invoke-GuiReadyBackupJob {
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DryRun)

    $store = Get-GuiReadyOpsStore
    $hit = @($store.Backups | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的备份任务') }
    $job = $hit[0]

    if (-not (Test-Path -LiteralPath ([string]$job.Source))) { throw ('源目录不存在：' + $job.Source) }
    $safe = Get-GuiReadySafeName ([string]$job.Name)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = [string]$job.Target

    if ($DryRun) {
        Write-Log ('[预览] 将把 {0} 备份到 {1}（{2}，保留 {3} 份）' -f $job.Source, $target, $job.Mode, $job.Keep) 'DRY'
        return
    }

    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    $file = ''
    if ($job.Mode -eq 'copy') {
        $dest = Join-Path $target ('{0}-{1}' -f $safe, $stamp)
        Copy-Item -LiteralPath ([string]$job.Source) -Destination $dest -Recurse -Force
        $file = $dest
    } else {
        $dest = Join-Path $target ('{0}-{1}.zip' -f $safe, $stamp)
        try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
        [System.IO.Compression.ZipFile]::CreateFromDirectory([string]$job.Source, $dest)
        $file = $dest
    }
    Write-Log ('备份完成：' + $file) 'OK'

    # 保留策略：只留最新的 Keep 份（按修改时间倒序）
    $pattern = if ($job.Mode -eq 'copy') { $safe + '-*' } else { $safe + '-*.zip' }
    $old = @(Get-ChildItem -LiteralPath $target -Filter $pattern -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -Skip ([int]$job.Keep))
    foreach ($f in $old) {
        try {
            Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction Stop
            Write-Log ('已清理旧备份：' + $f.Name) 'INFO'
        } catch {
            Write-Log ('清理旧备份失败 {0}：{1}' -f $f.Name, $_.Exception.Message) 'WARN'
        }
    }

    $job.LastRun = (Get-Date).ToString('o')
    $job.LastFile = $file
    $size = 0
    try { $size = (Get-Item -LiteralPath $file).Length } catch { }
    $job.LastResult = ('{0}（{1} MB，清理 {2} 份）' -f [System.IO.Path]::GetFileName($file), [Math]::Round($size / 1MB, 1), $old.Count)
    Save-GuiReadyOpsStore $store
    return [pscustomobject]@{ Id = $job.Id; File = $file; SizeMB = [Math]::Round($size / 1MB, 1); Removed = $old.Count }
}

# ---------------------------------------------------------------- 端口巡检

function Test-GuiReadyTcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 1500)
    $client = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return [pscustomobject]@{ Open = $false; Ms = $TimeoutMs; Error = '连接超时' }
        }
        $client.EndConnect($iar)
        $sw.Stop()
        return [pscustomobject]@{ Open = $true; Ms = [int]$sw.ElapsedMilliseconds; Error = '' }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ Open = $false; Ms = [int]$sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

function Get-GuiReadyPortOwner {
    param([int]$Port)
    try {
        $c = @(Get-GuiReadyTcpListeners | Where-Object { [int]$_.LocalPort -eq $Port }) | Select-Object -First 1
        if ($c) {
            $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($p) { return [string]$p.ProcessName }
            return ('PID ' + $c.OwningProcess)
        }
    } catch { }
    return ''
}

function New-GuiReadyPatrol {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$TargetHost = '127.0.0.1',
        [Parameter(Mandatory = $true)][string]$Ports,
        [int]$TimeoutMs = 1500,
        [switch]$DryRun
    )

    $list = @()
    foreach ($one in ([string]$Ports -split '[;,\s]+')) {
        $t = $one.Trim()
        if (-not $t) { continue }
        $n = 0
        if (-not [int]::TryParse($t, [ref]$n) -or $n -lt 1 -or $n -gt 65535) {
            throw ('端口不合法：' + $t)
        }
        $list += $n
    }
    if ($list.Count -eq 0) { throw '至少填一个端口' }

    $entry = [ordered]@{
        Id         = (New-GuiReadyOpsId 'port')
        Name       = $Name
        Host       = $TargetHost
        Ports      = ($list -join ',')
        TimeoutMs  = $TimeoutMs
        CreatedAt  = (Get-Date).ToString('o')
        LastRun    = ''
        LastSummary = ''
    }
    if (-not $DryRun) {
        $store = Get-GuiReadyOpsStore
        $store.Patrols += , $entry
        Save-GuiReadyOpsStore $store
        Write-Log ('巡检目标已添加：{0} → {1}:{2}' -f $Name, $TargetHost, ($list -join ',')) 'OK'
    } else {
        Write-Log ('[预览] 将添加巡检目标：{0} → {1}:{2}' -f $Name, $TargetHost, ($list -join ',')) 'DRY'
    }
    return [pscustomobject]$entry
}

function Remove-GuiReadyPatrol {
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DryRun)
    $store = Get-GuiReadyOpsStore
    $hit = @($store.Patrols | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的巡检目标') }
    if ($DryRun) { Write-Log ('[预览] 将删除巡检目标 ' + $hit[0].Name) 'DRY'; return }
    $store.Patrols = @($store.Patrols | Where-Object { $_.Id -ne $Id })
    Save-GuiReadyOpsStore $store
    Write-Log ('巡检目标已删除：' + $hit[0].Name) 'OK'
}

function Invoke-GuiReadyPortPatrol {
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DryRun)

    $store = Get-GuiReadyOpsStore
    $hit = @($store.Patrols | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的巡检目标') }
    $item = $hit[0]
    $hostText = [string]$item.Host
    $ports = @(([string]$item.Ports -split ',') | ForEach-Object { [int]$_ } | Where-Object { $_ -gt 0 })
    $timeout = [int]$item.TimeoutMs
    if ($timeout -lt 200) { $timeout = 1500 }

    $localNames = @('127.0.0.1', 'localhost', '.', $env:COMPUTERNAME)
    $isLocal = ($localNames -contains $hostText)

    $rows = @()
    $open = 0
    foreach ($p in $ports) {
        if ($DryRun) {
            $rows += [pscustomobject]@{ Port = $p; Open = $null; Ms = 0; Note = '[预览] 未连接'; Owner = '' }
            continue
        }
        $r = Test-GuiReadyTcpPort -TargetHost $hostText -Port $p -TimeoutMs $timeout
        $owner = ''
        if ($isLocal) { $owner = Get-GuiReadyPortOwner -Port $p }
        if ($r.Open) { $open++ }
        $note = if ($r.Open) { '开放' } else { '不通' }
        if (-not $r.Open -and $r.Error) { $note = '不通（' + $r.Error + '）' }
        $rows += [pscustomobject]@{ Port = $p; Open = [bool]$r.Open; Ms = $r.Ms; Note = $note; Owner = $owner }
        Write-Log ('  {0}:{1} → {2} {3}ms {4}' -f $hostText, $p, $note, $r.Ms, $owner) $(if ($r.Open) { 'OK' } else { 'WARN' })
    }

    if (-not $DryRun) {
        $item.LastRun = (Get-Date).ToString('o')
        $item.LastSummary = ('{0}/{1} 开放' -f $open, $ports.Count)
        Save-GuiReadyOpsStore $store
        if ($open -lt $ports.Count) {
            $closed = @($rows | Where-Object { $_.Open -eq $false } | ForEach-Object { [string]$_.Port })
            Send-GuiReadyOpsAlert -Title ('端口巡检异常：' + $item.Name) -Text ('{0}:{1} 中不通的端口：{2}' -f $hostText, $item.Ports, ($closed -join ',')) -Level 'Warn'
        }
    }
    return $rows
}

# ---------------------------------------------------------------- 下载队列（BITS）

function Get-GuiReadyDownloadFolder {
    $root = $script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Join-Path $root 'payload\downloads')
}

function Get-GuiReadyBitsJob {
    param([string]$JobId)
    if (-not $JobId) { return $null }
    try { return (Get-BitsTransfer -JobId ([guid]$JobId) -ErrorAction Stop) } catch { return $null }
}

function Format-GuiReadyBitsState {
    param([string]$State)
    switch ($State) {
        'Transferring' { return '传输中' }
        'Transferred'  { return '已完成（待收尾）' }
        'Connecting'   { return '连接中' }
        'Queued'       { return '排队中' }
        'Suspended'    { return '已暂停' }
        'SuspendedError' { return '已暂停（出错）' }
        'TransientError' { return '临时错误（自动重试）' }
        'Error'        { return '失败' }
        'Cancelled'    { return '已取消' }
        default        { return $State }
    }
}

function Add-GuiReadyDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Folder = '',
        [string]$FileName = '',
        [switch]$DryRun
    )

    if (-not (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) {
        throw '本机没有 BITS（后台智能传输服务），无法使用下载队列'
    }
    $uri = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { throw ('URL 不合法：' + $Url) }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { throw '只支持 http / https 下载' }

    if (-not $Folder) { $Folder = Get-GuiReadyDownloadFolder }
    $Folder = [System.IO.Path]::GetFullPath($Folder)
    if (-not $FileName) {
        $FileName = [System.IO.Path]::GetFileName([string]$uri.AbsolutePath)
        if (-not $FileName) { $FileName = 'download-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bin' }
    }
    $dest = Join-Path $Folder $FileName

    if ($DryRun) {
        Write-Log ('[预览] 将把 {0} 下载到 {1}' -f $Url, $dest) 'DRY'
        return [pscustomobject]@{ Url = $Url; File = $dest }
    }

    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
    try {
        $job = Start-BitsTransfer -Source $Url -Destination $dest -Asynchronous -Priority Normal -Description 'SCM 下载队列'
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match '0x800704DD|has not logged on to the network') {
            throw 'BITS 需要交互式登录会话才能传输（当前进程没有用户登录上下文，例如通过计划任务 / SYSTEM 运行）。请在桌面会话里用本工具添加下载，或改用其它方式获取文件。'
        }
        throw ('加入下载队列失败：' + $msg)
    }

    $entry = [ordered]@{
        Id      = (New-GuiReadyOpsId 'dl')
        Url     = $Url
        Name    = $FileName
        Folder  = $Folder
        File    = $dest
        JobId   = [string]$job.JobId
        AddedAt = (Get-Date).ToString('o')
    }
    $store = Get-GuiReadyOpsStore
    $store.Downloads += , $entry
    Save-GuiReadyOpsStore $store
    Write-Log ('已加入下载队列：{0} → {1}' -f $Url, $dest) 'OK'
    return [pscustomobject]$entry
}

function Set-GuiReadyDownloadAction {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('pause', 'resume', 'cancel', 'complete', 'remove')][string]$Action,
        [switch]$DryRun
    )

    $store = Get-GuiReadyOpsStore
    $hit = @($store.Downloads | Where-Object { $_.Id -eq $Id })
    if ($hit.Count -eq 0) { throw ('没有编号为 ' + $Id + ' 的下载') }
    $item = $hit[0]
    $job = Get-GuiReadyBitsJob ([string]$item.JobId)

    if ($DryRun) {
        Write-Log ('[预览] 下载 {0} → {1}' -f $item.Name, $Action) 'DRY'
        return
    }

    switch ($Action) {
        'pause' {
            if (-not $job) { throw '找不到这个下载的后台任务' }
            Suspend-BitsTransfer -BitsJob $job -ErrorAction Stop
            Write-Log ('已暂停：' + $item.Name) 'OK'
        }
        'resume' {
            if (-not $job) { throw '找不到这个下载的后台任务' }
            Resume-BitsTransfer -BitsJob $job -Asynchronous -ErrorAction Stop
            Write-Log ('已继续：' + $item.Name) 'OK'
        }
        'cancel' {
            if ($job) {
                try { Remove-BitsTransfer -BitsJob $job -ErrorAction Stop } catch { }
            }
            $store.Downloads = @($store.Downloads | Where-Object { $_.Id -ne $Id })
            Save-GuiReadyOpsStore $store
            Write-Log ('已取消并移除：' + $item.Name) 'OK'
            return
        }
        'complete' {
            if (-not $job) { throw '找不到这个下载的后台任务' }
            Complete-BitsTransfer -BitsJob $job -ErrorAction Stop
            $store.Downloads = @($store.Downloads | Where-Object { $_.Id -ne $Id })
            Save-GuiReadyOpsStore $store
            Write-Log ('已完成并归档：' + $item.File) 'OK'
            return
        }
        'remove' {
            if ($job) {
                try { Remove-BitsTransfer -BitsJob $job -ErrorAction Stop } catch { }
            }
            $store.Downloads = @($store.Downloads | Where-Object { $_.Id -ne $Id })
            Save-GuiReadyOpsStore $store
            Write-Log ('已从队列移除：' + $item.Name) 'OK'
        }
    }
}

# ---------------------------------------------------------------- 汇总（给界面用）

function Format-GuiReadyOpsBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0} GB' -f [Math]::Round($Bytes / 1GB, 2)) }
    if ($Bytes -ge 1MB) { return ('{0} MB' -f [Math]::Round($Bytes / 1MB, 1)) }
    if ($Bytes -ge 1KB) { return ('{0} KB' -f [Math]::Round($Bytes / 1KB, 0)) }
    return ('{0} B' -f [int]$Bytes)
}

function Get-GuiReadyOpsOverview {
    $store = Get-GuiReadyOpsStore
    $items = @()

    foreach ($g in @($store.Guard)) {
        $taskState = Get-GuiReadyOpsTaskState (Get-GuiReadyOpsTaskName 'Guard' $g.Id)
        $running = @(Test-GuiReadyGuardProcess -Exe ([string]$g.Exe)).Count -gt 0
        $state = if (-not $g.Enabled) { '已暂停' } elseif (-not $taskState) { '任务缺失' } elseif ($running) { '运行中' } else { '待拉起' }
        $items += [ordered]@{
            Kind = 'guard'; Id = $g.Id; Name = $g.Name
            Target = ('{0} {1}' -f $g.Exe, $g.Args).Trim()
            Schedule = ('每 {0} 分钟' -f $g.IntervalMin)
            State = $state
            Running = [bool]$running
            Enabled = [bool]$g.Enabled
            Detail = ('退避 {0} 秒 · 连续失败 {1} 次 · 最近动作 {2}' -f $g.DelaySec, $g.Failures,
                      $(if ($g.LastAction) { [string]$g.LastAction } else { '—' }))
            LastTime = [string]$g.LastCheck
            RunAs = [string]$g.RunAs
            TaskState = $taskState
        }
    }

    foreach ($p in @($store.Plans)) {
        $taskState = Get-GuiReadyOpsTaskState (Get-GuiReadyOpsTaskName 'Plan' $p.Id)
        $scheduleText = if ($p.Schedule -eq 'daily') { '每天 ' + $p.Time }
                        elseif ($p.Schedule -eq 'weekly') { ('每周{0} {1}' -f $p.Weekday, $p.Time) }
                        else { ('每 {0} 分钟' -f $p.IntervalMin) }
        $state = if (-not $p.Enabled) { '已暂停' } elseif (-not $taskState) { '任务缺失' } else { '已启用' }
        $items += [ordered]@{
            Kind = 'plan'; Id = $p.Id; Name = $p.Name
            Target = [string]$p.Chain
            Schedule = $scheduleText
            State = $state
            Enabled = [bool]$p.Enabled
            Detail = if ($p.LastResult) { '最近：' + $p.LastResult } else { '还没跑过' }
            LastTime = [string]$p.LastRun
            RunAs = [string]$p.RunAs
            TaskState = $taskState
        }
    }

    foreach ($b in @($store.Backups)) {
        $taskState = Get-GuiReadyOpsTaskState (Get-GuiReadyOpsTaskName 'Backup' $b.Id)
        $state = if (-not $b.Enabled) { '已暂停' } elseif (-not $taskState) { '任务缺失' } else { '已排期' }
        $items += [ordered]@{
            Kind = 'backup'; Id = $b.Id; Name = $b.Name
            Target = ('{0} → {1}' -f $b.Source, $b.Target)
            Schedule = ('每天 {0} · {1} · 保留 {2} 份' -f $b.Time, $b.Mode, $b.Keep)
            State = $state
            Enabled = [bool]$b.Enabled
            Detail = if ($b.LastResult) { '最近：' + $b.LastResult } else { '还没跑过' }
            LastTime = [string]$b.LastRun
            RunAs = [string]$b.RunAs
            TaskState = $taskState
        }
    }

    foreach ($p in @($store.Patrols)) {
        $items += [ordered]@{
            Kind = 'patrol'; Id = $p.Id; Name = $p.Name
            Target = ('{0}:{1}' -f $p.Host, $p.Ports)
            Schedule = ('超时 {0} ms' -f $p.TimeoutMs)
            State = if ($p.LastSummary) { [string]$p.LastSummary } else { '未巡检' }
            Enabled = $true
            Detail = if ($p.LastSummary) { '上次：' + $p.LastSummary } else { '点「巡检一次」开始' }
            LastTime = [string]$p.LastRun
            RunAs = ''
            TaskState = ''
        }
    }

    foreach ($d in @($store.Downloads)) {
        $job = Get-GuiReadyBitsJob ([string]$d.JobId)
        $bitsState = if ($job) { [string]$job.JobState } else { 'Missing' }
        $total = 0; $done = 0
        if ($job) {
            try { $total = [double]$job.BytesTotal; $done = [double]$job.BytesTransferred } catch { }
        }
        $progress = if ($total -gt 0 -and $total -lt 1TB) { ('{0}%' -f [Math]::Round($done * 100.0 / $total)) } else { '—' }
        # BITS 在出错 / 大小未知时会把 BytesTotal 写成 UInt64.MaxValue（0xFFFFFFFFFFFFFFFF），
        # 直接换算会显示成「17179869184 GB」这种荒唐数字，这里当未知处理。
        $sizeText = if ($total -gt 0 -and $total -lt 1TB) { ('{0} / {1}' -f (Format-GuiReadyOpsBytes $done), (Format-GuiReadyOpsBytes $total)) } else { '—' }
        $stateText = if ($bitsState -eq 'Missing') { '任务丢失' } else { Format-GuiReadyBitsState $bitsState }
        # 失败时把 BITS 自己的错误原因带上，否则用户只看到「失败」两个字
        $errText = ''
        if ($job -and $bitsState -eq 'Error') {
            try { $errText = [string]$job.ErrorDescription } catch { }
        }
        $items += [ordered]@{
            Kind = 'download'; Id = $d.Id; Name = $d.Name
            Target = [string]$d.Url
            Schedule = $sizeText
            State = $stateText
            Enabled = $true
            Detail = $(if ($errText) { '失败原因：' + $errText } else { ('进度 {0} · {1}' -f $progress, $d.File) })
            LastTime = [string]$d.AddedAt
            RunAs = ''
            TaskState = $bitsState
            Progress = $progress
        }
    }

    $data = [ordered]@{
        Root  = Get-GuiReadyOpsRoot
        Store = Get-GuiReadyOpsStorePath
        Counts = [ordered]@{
            Guard     = @($store.Guard).Count
            Plans     = @($store.Plans).Count
            Backups   = @($store.Backups).Count
            Patrols   = @($store.Patrols).Count
            Downloads = @($store.Downloads).Count
        }
        BitsAvailable = [bool](Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)
        Admin = (Test-IsAdministrator)
    }
    return [pscustomobject]@{ Data = $data; Items = $items }
}

# GuiReady 平台骨架：任务中心 / 结构审计 / 通知收件箱 / 配置备份。
#
# 设计约束（和整个工具一致）：
#   1. 零第三方依赖：只用 PowerShell 5.1 + .NET Framework 自带能力；
#   2. 所有落盘都是「先写临时文件再原子替换」，GUI 与子进程同时读时不会读到半个 JSON；
#   3. 任务参数里的口令/令牌只保存脱敏后的 ***，这类任务也禁止一键重试；
#   4. 审计只追加、不修改 —— 出问题时它是唯一可信的时间线。
#
# 目录布局（都在工具根目录下，和现有 state / backup 保持一致）：
#   state\tasks\yyyyMM\task-<时间戳>.json     单条任务记录
#   state\audit\audit-yyyyMM.jsonl             审计事件（每行一条 JSON）
#   state\notify\notify.json                  通知收件箱（最近 200 条）
#   backup\config-<时间戳>.zip                配置备份（含 manifest.json）

$script:GuiReadyTaskRoot        = Split-Path -Parent $PSScriptRoot
$script:GuiReadyTasksDir        = Join-Path $script:GuiReadyTaskRoot 'state\tasks'
$script:GuiReadyAuditDir        = Join-Path $script:GuiReadyTaskRoot 'state\audit'
$script:GuiReadyNotifyDir       = Join-Path $script:GuiReadyTaskRoot 'state\notify'
$script:GuiReadyNotifyFile      = Join-Path $script:GuiReadyNotifyDir 'notify.json'
$script:GuiReadyConfigBackupDir = Join-Path $script:GuiReadyTaskRoot 'backup'
$script:GuiReadyUtf8NoBom       = New-Object System.Text.UTF8Encoding($false)

# 参数名命中这些词就按敏感处理：值不落盘，任务也不允许重试。
# 之所以按“名字”而不是按内容猜：猜内容既不可靠，又可能把普通路径误判成口令。
$script:GuiReadyTaskSensitivePattern = '(?i)(pass(word|wd)?$|^pwd$|secret|token|credential|api[-_]?key|private[-_]?key)'

# 配置备份只收「用户可重建的配置」，不含任何口令，也不收日志/缓存。
$script:GuiReadyConfigBackupItems = @(
    'lib\catalog.user.json'
    'launcher\programs.json'
    'state\pipeline.json'
    'state\role-cache.json'
    'state\hosts\hosts.json'
)

function Get-GuiReadyTaskRoot { return $script:GuiReadyTaskRoot }

function Ensure-GuiReadyTaskDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function ConvertTo-GuiReadyTaskTime {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [datetime]::MinValue }
    try { return [datetime]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture) } catch { return [datetime]::MinValue }
}

function Read-GuiReadyJsonFile {
    # 带重试的读取：另一个进程可能正好在“写临时文件 → 替换”之间。
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            return ($raw | ConvertFrom-Json)
        } catch {
            Start-Sleep -Milliseconds 60
        }
    }
    return $null
}

function Write-GuiReadyJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json
    )
    $dir = Split-Path -Parent $Path
    if ($dir) { Ensure-GuiReadyTaskDir -Path $dir }
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Json, $script:GuiReadyUtf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ============================ 任务记录 ============================

function ConvertTo-GuiReadyTaskSafeParams {
    # 返回可安全落盘的参数副本：敏感名 → ***；超长文本截断（并标记，禁止重试）。
    param([hashtable]$Params)
    $out       = [ordered]@{}
    $sensitive = $false
    $truncated = $false
    if ($Params) {
        foreach ($k in @($Params.Keys | Sort-Object)) {
            $name = [string]$k
            if ($name -eq 'DryRun') { continue }   # 由任务记录的 DryRun 字段表达
            if ($name -eq '__TaskId') { continue } # 内部注入，只给动作脚本用，不落盘
            $val = $Params[$k]
            if ($name -match $script:GuiReadyTaskSensitivePattern) {
                $out[$name] = '***'
                $sensitive = $true
                continue
            }
            if ($null -eq $val) { $out[$name] = ''; continue }
            if ($val -is [bool] -or $val -is [int] -or $val -is [long] -or $val -is [double]) { $out[$name] = $val; continue }
            $s = [string]$val
            if ($s.Length -gt 800) {
                $out[$name] = $s.Substring(0, 800) + '…（已截断）'
                $truncated = $true
            } else {
                $out[$name] = $s
            }
        }
    }
    return [pscustomobject]@{ Values = $out; Sensitive = $sensitive; Truncated = $truncated }
}

function New-GuiReadyTaskId {
    return ('task-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
}

function Get-GuiReadyTaskMonthDir {
    param([datetime]$Time = (Get-Date))
    $d = Join-Path $script:GuiReadyTasksDir $Time.ToString('yyyyMM')
    Ensure-GuiReadyTaskDir -Path $d
    return $d
}

function Get-GuiReadyTaskPath {
    param([Parameter(Mandatory = $true)][string]$Id)
    if (-not (Test-Path -LiteralPath $script:GuiReadyTasksDir)) { return '' }
    $hit = @(Get-ChildItem -LiteralPath $script:GuiReadyTasksDir -Filter ($Id + '.json') -Recurse -File -ErrorAction SilentlyContinue)
    if ($hit.Count -gt 0) { return [string]$hit[0].FullName }
    return ''
}

function Save-GuiReadyTaskRecord {
    param([Parameter(Mandatory = $true)]$Task)
    $when = ConvertTo-GuiReadyTaskTime -Text ([string]$Task.QueuedAt)
    if ($when -eq [datetime]::MinValue) { $when = Get-Date }
    $dir = Get-GuiReadyTaskMonthDir -Time $when
    $path = Join-Path $dir ([string]$Task.Id + '.json')
    Write-GuiReadyJsonFile -Path $path -Json ($Task | ConvertTo-Json -Depth 8)
    return $path
}

function New-GuiReadyTask {
    param(
        [Parameter(Mandatory = $true)][string]$ActionId,
        [string]$ActionName = '',
        [string]$Group = '',
        [hashtable]$Params = $null,
        [string]$LogPath = '',
        [string]$Id = '',
        [string]$RetryOf = '',
        [bool]$DryRun = $false
    )
    if (-not $Id) { $Id = New-GuiReadyTaskId }
    $safe  = ConvertTo-GuiReadyTaskSafeParams -Params $Params
    $user  = ''
    try { $user = (whoami) } catch { $user = [Environment]::UserName }
    $now   = (Get-Date).ToString('o')
    $task  = [pscustomobject][ordered]@{
        Id              = $Id
        ActionId        = $ActionId
        ActionName      = $ActionName
        Group           = $Group
        Params          = [pscustomobject]$safe.Values
        ParamsTruncated = [bool]$safe.Truncated
        Sensitive       = [bool]$safe.Sensitive
        CanRetry        = (-not $safe.Sensitive -and -not $safe.Truncated)
        Status          = 'Queued'
        DryRun          = $DryRun
        QueuedAt        = $now
        StartedAt       = ''
        EndedAt         = ''
        DurationSec     = 0
        ExitCode        = $null
        Message         = ''
        LogPath         = $LogPath
        Pid             = 0
        Machine         = $env:COMPUTERNAME
        User            = $user
        RetryOf         = $RetryOf
    }
    [void](Save-GuiReadyTaskRecord -Task $task)
    Write-GuiReadyAudit -Event 'task-queued' -Level 'Info' -ActionId $ActionId -TaskId $Id `
        -Detail ('参数 {0} 项{1}' -f @($safe.Values.Keys).Count, $(if ($safe.Sensitive) { '，含敏感项（已脱敏）' } else { '' }))
    return $task
}

function Get-GuiReadyTask {
    param([Parameter(Mandatory = $true)][string]$Id)
    $path = Get-GuiReadyTaskPath -Id $Id
    if (-not $path) { return $null }
    return (Read-GuiReadyJsonFile -Path $path)
}

function Get-GuiReadyTaskList {
    # 按月目录从新到旧扫，凑够 Limit 就停 —— 不遍历全部历史（几千条时切页会明显变慢）。
    param(
        [int]$Limit = 200,
        [int]$SinceHours = 0,
        [string]$Status = '',
        [string]$ActionId = '',
        [string]$Keyword = ''
    )
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $script:GuiReadyTasksDir)) { return @() }

    $cut = if ($SinceHours -gt 0) { (Get-Date).AddHours(-$SinceHours) } else { [datetime]::MinValue }
    $dirs = @(Get-ChildItem -LiteralPath $script:GuiReadyTasksDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)

    foreach ($d in $dirs) {
        if ($out.Count -ge $Limit) { break }
        $files = @(Get-ChildItem -LiteralPath $d.FullName -Filter 'task-*.json' -File -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)
        foreach ($f in $files) {
            if ($out.Count -ge $Limit) { break }
            if ($SinceHours -gt 0 -and $f.LastWriteTime -lt $cut) { continue }
            $t = Read-GuiReadyJsonFile -Path $f.FullName
            if (-not $t) { continue }
            if ($Status -and [string]$t.Status -ne $Status) { continue }
            if ($ActionId -and [string]$t.ActionId -ne $ActionId) { continue }
            if ($SinceHours -gt 0) {
                $when = ConvertTo-GuiReadyTaskTime -Text ([string]$t.QueuedAt)
                if ($when -ne [datetime]::MinValue -and $when -lt $cut) { continue }
            }
            if ($Keyword) {
                $hay = ('{0} {1} {2} {3}' -f [string]$t.ActionId, [string]$t.ActionName, [string]$t.Message, [string]$t.User)
                if ($hay -notmatch [regex]::Escape($Keyword)) { continue }
            }
            [void]$out.Add($t)
        }
    }
    return $out.ToArray()
}

function Get-GuiReadyTaskStats {
    param([object[]]$Items = @())
    $s = [ordered]@{
        Total = 0; Queued = 0; Running = 0; Succeeded = 0; Failed = 0; Canceled = 0; Interrupted = 0
        TodayTotal = 0; TodayFailed = 0
    }
    $today = (Get-Date).Date
    foreach ($t in @($Items)) {
        if (-not $t) { continue }
        $s.Total++
        $st = [string]$t.Status
        if ($s.Contains($st)) { $s[$st]++ }
        $when = ConvertTo-GuiReadyTaskTime -Text ([string]$t.QueuedAt)
        if ($when -ne [datetime]::MinValue -and $when.Date -eq $today) {
            $s.TodayTotal++
            if ($st -eq 'Failed') { $s.TodayFailed++ }
        }
    }
    return [pscustomobject]$s
}

function Update-GuiReadyTask {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Status = '',
        [object]$ExitCode = $null,
        [string]$Message = '',
        [string]$StartedAt = '',
        [string]$EndedAt = '',
        [int]$ProcessId = 0,
        [switch]$SetExitCode,
        [switch]$SetMessage
    )
    $t = Get-GuiReadyTask -Id $Id
    if (-not $t) { return $null }
    if ($Status) { $t.Status = $Status }
    if ($SetExitCode) { $t.ExitCode = $ExitCode }
    if ($SetMessage) { $t.Message = $Message }
    if ($StartedAt) { $t.StartedAt = $StartedAt }
    if ($EndedAt) { $t.EndedAt = $EndedAt }
    if ($ProcessId -gt 0) { $t.Pid = $ProcessId }

    if ([string]$t.StartedAt -and [string]$t.EndedAt) {
        $a = ConvertTo-GuiReadyTaskTime -Text ([string]$t.StartedAt)
        $b = ConvertTo-GuiReadyTaskTime -Text ([string]$t.EndedAt)
        if ($a -ne [datetime]::MinValue -and $b -ne [datetime]::MinValue) {
            $t.DurationSec = [Math]::Round(($b - $a).TotalSeconds, 1)
        }
    }
    [void](Save-GuiReadyTaskRecord -Task $t)
    return $t
}

function Complete-GuiReadyTask {
    # 统一收尾：写状态、写审计、失败时投递通知。runner / GUI / 清理任务共用。
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Status,
        [object]$ExitCode = $null,
        [string]$Message = '',
        [switch]$Quiet
    )
    $t = Get-GuiReadyTask -Id $Id
    if (-not $t) { return $null }

    $now = (Get-Date).ToString('o')
    if (-not [string]$t.StartedAt) { $t.StartedAt = $now }
    $t.Status     = $Status
    $t.ExitCode   = $ExitCode
    $t.Message    = $Message
    $t.EndedAt    = $now
    $a = ConvertTo-GuiReadyTaskTime -Text ([string]$t.StartedAt)
    $b = ConvertTo-GuiReadyTaskTime -Text ([string]$t.EndedAt)
    if ($a -ne [datetime]::MinValue -and $b -ne [datetime]::MinValue) {
        $t.DurationSec = [Math]::Round(($b - $a).TotalSeconds, 1)
    }
    [void](Save-GuiReadyTaskRecord -Task $t)

    $level = 'Info'
    switch ($Status) {
        'Succeeded'   { $level = 'Success' }
        'Failed'      { $level = 'Error' }
        'Canceled'    { $level = 'Warn' }
        'Interrupted' { $level = 'Warn' }
    }
    Write-GuiReadyAudit -Event 'task-finish' -Level $level -ActionId ([string]$t.ActionId) -TaskId $Id `
        -Detail ('{0}；退出码 {1}；耗时 {2} 秒{3}' -f $Status, $(if ($null -eq $ExitCode) { '-' } else { [string]$ExitCode }),
                 [string]$t.DurationSec, $(if ($Message) { '；' + $Message } else { '' }))

    if ($Status -eq 'Failed' -and -not $Quiet) {
        $title = '动作失败：' + $(if ([string]$t.ActionName) { [string]$t.ActionName } else { [string]$t.ActionId })
        [void](Add-GuiReadyNotification -Kind 'Failed' -Title $title -Text $Message -TaskId $Id)
    }
    return $t
}

function Update-GuiReadyStaleTasks {
    # 进程被杀 / 机器断电 / 远程会话断开时，任务会永远停在 Running。
    # 每次打开任务页顺手清理最近 12 小时内的这种记录，状态改成「已中断」。
    param([int]$ScanHours = 12)
    if (-not (Test-Path -LiteralPath $script:GuiReadyTasksDir)) { return 0 }
    $fixed = 0
    $cut   = (Get-Date).AddHours(-$ScanHours)
    $dirs  = @(Get-ChildItem -LiteralPath $script:GuiReadyTasksDir -Directory -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 3)
    foreach ($d in $dirs) {
        $files = @(Get-ChildItem -LiteralPath $d.FullName -Filter 'task-*.json' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -gt $cut } | Sort-Object LastWriteTime -Descending)
        foreach ($f in $files) {
            $t = Read-GuiReadyJsonFile -Path $f.FullName
            if (-not $t -or [string]$t.Status -ne 'Running') { continue }
            $started = ConvertTo-GuiReadyTaskTime -Text ([string]$t.StartedAt)
            if ($started -ne [datetime]::MinValue -and ((Get-Date) - $started).TotalSeconds -lt 30) { continue }
            $procId = 0
            try { $procId = [int]$t.Pid } catch { $procId = 0 }
            $alive = $false
            if ($procId -gt 0) {
                $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($p) {
                    try {
                        if ($started -eq [datetime]::MinValue -or [Math]::Abs(($p.StartTime - $started).TotalMinutes) -lt 5) { $alive = $true }
                    } catch { $alive = $true }
                }
            }
            if (-not $alive) {
                [void](Complete-GuiReadyTask -Id ([string]$t.Id) -Status 'Interrupted' -ExitCode (-1) `
                    -Message '进程已退出但没有写入结果（可能被手动停止、会话断开或崩溃）。' -Quiet)
                $fixed++
            }
        }
    }
    return $fixed
}

function Stop-GuiReadyTask {
    # 取消任务：只在能确认「这个进程就是它」时才终止，避免 PID 复用误杀别的程序。
    param([Parameter(Mandatory = $true)][string]$Id)
    $t = Get-GuiReadyTask -Id $Id
    if (-not $t) { return [pscustomobject]@{ Ok = $false; Killed = $false; Message = '找不到这个任务。' } }
    if ([string]$t.Status -ne 'Running' -and [string]$t.Status -ne 'Queued') {
        return [pscustomobject]@{ Ok = $false; Killed = $false; Message = ('任务已经结束（{0}），不需要取消。' -f (Get-GuiReadyTaskStatusText -Status ([string]$t.Status))) }
    }

    $procId = 0
    try { $procId = [int]$t.Pid } catch { $procId = 0 }
    $killed = $false
    if ($procId -gt 0) {
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($p) {
            $ours = $false
            try {
                $ci = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $procId) -ErrorAction SilentlyContinue
                $cmd = [string]$ci.CommandLine
                if ($cmd -match 'Run-GuiReadyAction\.ps1' -and $cmd -match [regex]::Escape($Id)) { $ours = $true }
            } catch { }
            if (-not $ours) {
                return [pscustomobject]@{ Ok = $false; Killed = $false; Message = '进程号已被其它程序复用，未终止。请用任务管理器确认后再处理。' }
            }
            try { Stop-Process -Id $procId -Force -ErrorAction Stop; $killed = $true } catch { }
        }
    }
    $msg = '用户取消'
    if ($killed) { $msg = '用户取消（进程已终止）' }
    $r = Complete-GuiReadyTask -Id $Id -Status 'Canceled' -ExitCode (-1) -Message $msg -Quiet
    return [pscustomobject]@{ Ok = $true; Killed = $killed; Task = $r; Message = '任务已取消。' }
}

function Get-GuiReadyTaskStatusText {
    param([string]$Status)
    switch ($Status) {
        'Queued'      { return '排队中' }
        'Running'     { return '运行中' }
        'Succeeded'   { return '成功' }
        'Failed'      { return '失败' }
        'Canceled'    { return '已取消' }
        'Interrupted' { return '已中断' }
        default       { return $(if ($Status) { $Status } else { '未知' }) }
    }
}

function Get-GuiReadyTaskStatusKind {
    param([string]$Status)
    switch ($Status) {
        'Succeeded' { return 'Success' }
        'Failed'    { return 'Danger' }
        'Running'   { return 'Info' }
        'Canceled'  { return 'Neutral' }
        'Interrupted' { return 'Warn' }
        default     { return 'Neutral' }
    }
}

# ============================ 结构审计 ============================

function Write-GuiReadyAudit {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Level = 'Info',
        [string]$ActionId = '',
        [string]$TaskId = '',
        [string]$Detail = ''
    )
    try {
        $dir = Join-Path $script:GuiReadyAuditDir ((Get-Date).ToString('yyyyMM'))
        Ensure-GuiReadyTaskDir -Path $dir
        $file = Join-Path $dir ('audit-' + (Get-Date).ToString('yyyyMM') + '.jsonl')
        $o = [ordered]@{
            Time     = (Get-Date).ToString('o')
            Event    = $Event
            Level    = $Level
            ActionId = $ActionId
            TaskId   = $TaskId
            User     = [Environment]::UserName
            Machine  = $env:COMPUTERNAME
            Detail   = $Detail
        }
        $line = ($o | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine
        [System.IO.File]::AppendAllText($file, $line, $script:GuiReadyUtf8NoBom)
    } catch { }
}

function Get-GuiReadyAuditList {
    param(
        [int]$Limit = 300,
        [int]$SinceHours = 0,
        [string]$Level = '',
        [string]$Event = '',
        [string]$TaskId = '',
        [string]$Keyword = ''
    )
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $script:GuiReadyAuditDir)) { return @() }
    $cut = if ($SinceHours -gt 0) { (Get-Date).AddHours(-$SinceHours) } else { [datetime]::MinValue }

    $files = @(Get-ChildItem -LiteralPath $script:GuiReadyAuditDir -Filter 'audit-*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 4)
    foreach ($f in $files) {
        if ($out.Count -ge $Limit) { break }
        $tail = [Math]::Max(200, ($Limit * 3))
        $lines = @()
        try { $lines = @(Get-Content -LiteralPath $f.FullName -Tail $tail -Encoding UTF8) } catch { continue }
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($out.Count -ge $Limit) { break }
            $e = $null
            try { $e = ($lines[$i] | ConvertFrom-Json) } catch { continue }
            if (-not $e) { continue }
            if ($Level -and [string]$e.Level -ne $Level) { continue }
            if ($Event -and ([string]$e.Event) -notlike ($Event + '*')) { continue }
            if ($TaskId -and [string]$e.TaskId -ne $TaskId) { continue }
            if ($SinceHours -gt 0) {
                $when = ConvertTo-GuiReadyTaskTime -Text ([string]$e.Time)
                if ($when -ne [datetime]::MinValue -and $when -lt $cut) { continue }
            }
            if ($Keyword) {
                $hay = ('{0} {1} {2} {3}' -f [string]$e.Event, [string]$e.ActionId, [string]$e.TaskId, [string]$e.Detail)
                if ($hay -notmatch [regex]::Escape($Keyword)) { continue }
            }
            [void]$out.Add($e)
        }
    }
    return $out.ToArray()
}

function Get-GuiReadyAuditEventText {
    param([string]$Event)
    switch ($Event) {
        'task-queued'   { return '提交任务' }
        'task-start'    { return '开始执行' }
        'task-finish'   { return '执行结束' }
        'config-export' { return '配置备份' }
        'config-import' { return '配置恢复' }
        'audit-export'  { return '审计导出' }
        default         { return $(if ($Event) { $Event } else { '事件' }) }
    }
}

function Export-GuiReadyAudit {
    param(
        [object[]]$Entries = @(),
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Format = 'Csv',
        [switch]$WhatIf
    )
    $fmt = 'Csv'
    if ($Format -match '^(?i)json') { $fmt = 'Jsonl' }
    $list = @($Entries)
    if ($WhatIf) { return [pscustomobject]@{ Path = $Path; Format = $fmt; Count = $list.Count } }

    if ($fmt -eq 'Jsonl') {
        $lines = @()
        foreach ($e in $list) { $lines += ($e | ConvertTo-Json -Compress -Depth 6) }
        [System.IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), $script:GuiReadyUtf8NoBom)
    } else {
        # CSV 用 UTF-8 BOM：Excel 打开中文才不乱码（和日志导出保持一致）
        $rows = @($list | Select-Object Time, Event, Level, ActionId, TaskId, User, Machine, Detail)
        $csv  = @($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
        [System.IO.File]::WriteAllText($Path, ($csv + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    }
    Write-GuiReadyAudit -Event 'audit-export' -Level 'Info' -Detail ('导出 {0} 条到 {1}（{2}）' -f $list.Count, $Path, $fmt)
    return [pscustomobject]@{ Path = $Path; Format = $fmt; Count = $list.Count }
}

# ============================ 通知收件箱 ============================

function Get-GuiReadyNotificationList {
    param([int]$Limit = 200, [switch]$UnreadOnly)
    $obj = Read-GuiReadyJsonFile -Path $script:GuiReadyNotifyFile
    $items = @()
    if ($obj) {
        # notify.json 用 { Version, Items } 包装，方便以后加字段而不破坏旧文件
        if ($obj.PSObject.Properties['Items']) { $items = @($obj.Items) }
        else { $items = @($obj) }
    }
    if ($UnreadOnly) { $items = @($items | Where-Object { -not [bool]$_.Read }) }
    if ($Limit -gt 0 -and $items.Count -gt $Limit) { $items = @($items[0..($Limit - 1)]) }
    return $items
}

function Save-GuiReadyNotificationList {
    param([object[]]$Items = @())
    $payload = [ordered]@{ Version = 1; Items = @($Items) }
    Write-GuiReadyJsonFile -Path $script:GuiReadyNotifyFile -Json ($payload | ConvertTo-Json -Depth 6)
}

function Add-GuiReadyNotification {
    param(
        [string]$Kind = 'Info',
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Text = '',
        [string]$TaskId = ''
    )
    try {
        $items = @(Get-GuiReadyNotificationList -Limit 400)
        $text  = [string]$Text
        if ($text.Length -gt 2000) { $text = $text.Substring(0, 2000) + '…' }
        $n = [pscustomobject][ordered]@{
            Id        = ('ntf-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            Kind      = $Kind
            Title     = $Title
            Text      = $text
            TaskId    = $TaskId
            CreatedAt = (Get-Date).ToString('o')
            Read      = $false
        }
        $items = @($n) + $items
        if ($items.Count -gt 200) { $items = @($items[0..199]) }
        Save-GuiReadyNotificationList -Items $items
        return $n
    } catch {
        return $null
    }
}

function Set-GuiReadyNotificationRead {
    param([string]$Id = '', [switch]$All)
    $items = @(Get-GuiReadyNotificationList -Limit 0)
    $changed = 0
    foreach ($n in $items) {
        if ($All -or ([string]$n.Id -eq $Id)) {
            if (-not [bool]$n.Read) { $n.Read = $true; $changed++ }
        }
    }
    if ($changed -gt 0) { Save-GuiReadyNotificationList -Items $items }
    return (Get-GuiReadyNotificationUnreadCount)
}

function Clear-GuiReadyNotifications {
    Save-GuiReadyNotificationList -Items @()
    return 0
}

function Get-GuiReadyNotificationUnreadCount {
    try { return @(Get-GuiReadyNotificationList -UnreadOnly -Limit 0).Count } catch { return 0 }
}

# ============================ 配置备份 ============================

function Get-GuiReadyConfigBackupItems { return @($script:GuiReadyConfigBackupItems) }

function Export-GuiReadyConfigBackup {
    # 把用户可重建的配置打成一个 zip（带 manifest.json），用于换机 / 重装前留档。
    param(
        [string]$Destination = '',
        [switch]$WhatIf
    )
    $root = $script:GuiReadyTaskRoot
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (-not $Destination) { $Destination = Join-Path $script:GuiReadyConfigBackupDir ('config-' + $stamp + '.zip') }

    $dst = $Destination
    if (Get-Command ConvertTo-GuiReadyFilePath -ErrorAction SilentlyContinue) {
        $dst = ConvertTo-GuiReadyFilePath -Path $Destination
    } else {
        $dst = [System.IO.Path]::GetFullPath($Destination)
    }
    if (-not $dst.ToLowerInvariant().EndsWith('.zip')) { throw ('备份目标必须以 .zip 结尾：' + $dst) }
    if (Test-Path -LiteralPath $dst) { throw ('备份文件已存在：' + $dst) }

    $present = @()
    foreach ($rel in @($script:GuiReadyConfigBackupItems)) {
        $src = Join-Path $root $rel
        if (Test-Path -LiteralPath $src -PathType Leaf) { $present += $rel }
    }
    if ($WhatIf) {
        return [pscustomobject]@{ Archive = $dst; Files = $present; Count = $present.Count; Planned = $true }
    }
    if ($present.Count -eq 0) { throw '没有找到可备份的配置文件（可能还没使用过相关功能）。' }

    $stage = Join-Path $env:TEMP ('scm-config-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Ensure-GuiReadyTaskDir -Path $stage
    try {
        foreach ($rel in $present) {
            $src = Join-Path $root $rel
            $tgt = Join-Path $stage $rel
            $tgtDir = Split-Path -Parent $tgt
            Ensure-GuiReadyTaskDir -Path $tgtDir
            Copy-Item -LiteralPath $src -Destination $tgt -Force
        }
        $manifest = [pscustomobject][ordered]@{
            Version   = 1
            CreatedAt = (Get-Date).ToString('o')
            Machine   = $env:COMPUTERNAME
            User      = [Environment]::UserName
            ToolRoot  = $root
            Files     = @($present)
            Note      = 'SCM 配置备份：只含可重建的用户配置，不含口令与日志。'
        }
        Write-GuiReadyJsonFile -Path (Join-Path $stage 'manifest.json') -Json ($manifest | ConvertTo-Json -Depth 5)

        $dstDir = Split-Path -Parent $dst
        if ($dstDir) { Ensure-GuiReadyTaskDir -Path $dstDir }
        if (Get-Command Compress-GuiReadyPath -ErrorAction SilentlyContinue) {
            $r = Compress-GuiReadyPath -Path $stage -Destination $dst
            [void]$r
        } else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $dst,
                [System.IO.Compression.CompressionLevel]::Optimal, $false)
        }
        Write-GuiReadyAudit -Event 'config-export' -Level 'Success' -Detail ('备份 {0} 个配置文件到 {1}' -f $present.Count, $dst)
        return [pscustomobject]@{ Archive = $dst; Files = @($present); Count = $present.Count; Planned = $false }
    } finally {
        try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Import-GuiReadyConfigBackup {
    # 从备份 zip 恢复配置。只认 allowlist 里的相对路径，清单外的条目一律拒绝。
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$WhatIf
    )
    $root = $script:GuiReadyTaskRoot
    $zip  = $Path
    if (Get-Command ConvertTo-GuiReadyFilePath -ErrorAction SilentlyContinue) { $zip = ConvertTo-GuiReadyFilePath -Path $Path }
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw ('备份文件不存在：' + $zip) }
    if (-not $zip.ToLowerInvariant().EndsWith('.zip')) { throw '只支持 .zip 备份包。' }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stage = Join-Path $env:TEMP ('scm-restore-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Ensure-GuiReadyTaskDir -Path $stage
    try {
        if (Get-Command Expand-GuiReadyArchive -ErrorAction SilentlyContinue) {
            [void](Expand-GuiReadyArchive -Path $zip -Destination $stage -Overwrite)
        } else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
        }

        $mfPath = Join-Path $stage 'manifest.json'
        if (-not (Test-Path -LiteralPath $mfPath -PathType Leaf)) { throw '备份包缺少 manifest.json，不是本工具生成的配置备份。' }
        $mf = Read-GuiReadyJsonFile -Path $mfPath
        if (-not $mf) { throw 'manifest.json 无法解析。' }

        $allowed = @($script:GuiReadyConfigBackupItems)
        $restore = @()
        foreach ($rel in @($mf.Files)) {
            $relNorm = ([string]$rel).TrimStart('\')
            if ($relNorm -match '(^|\\)\.\.(\\|$)') { throw ('备份清单包含越界路径：' + $relNorm) }
            if ($allowed -notcontains $relNorm) { throw ('备份清单包含不允许恢复的路径：' + $relNorm) }
            if (Test-Path -LiteralPath (Join-Path $stage $relNorm) -PathType Leaf) { $restore += $relNorm }
        }
        if ($restore.Count -eq 0) { throw '备份包里没有可恢复的配置文件。' }

        $backupDir = Join-Path $script:GuiReadyConfigBackupDir ('config-restore-' + $stamp)
        if ($WhatIf) {
            return [pscustomobject]@{ Archive = $zip; Files = @($restore); Count = $restore.Count; BackupDir = $backupDir; Planned = $true }
        }

        $done = 0
        foreach ($rel in $restore) {
            $src = Join-Path $stage $rel
            $tgt = Join-Path $root $rel
            $tgtDir = Split-Path -Parent $tgt
            Ensure-GuiReadyTaskDir -Path $tgtDir
            if (Test-Path -LiteralPath $tgt -PathType Leaf) {
                $bk = Join-Path $backupDir $rel
                $bkDir = Split-Path -Parent $bk
                Ensure-GuiReadyTaskDir -Path $bkDir
                Copy-Item -LiteralPath $tgt -Destination $bk -Force
            }
            Copy-Item -LiteralPath $src -Destination $tgt -Force
            $done++
        }
        Write-GuiReadyAudit -Event 'config-import' -Level 'Success' `
            -Detail ('从 {0} 恢复 {1} 个配置文件；原文件备份在 {2}' -f $zip, $done, $backupDir)
        return [pscustomobject]@{ Archive = $zip; Files = @($restore); Count = $done; BackupDir = $backupDir; Planned = $false }
    } finally {
        try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

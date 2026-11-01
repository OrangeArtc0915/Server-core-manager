# GuiReady 日志中心：Windows 事件日志与工具自身文件日志的统一读取、筛选、导出。
#
# 设计要点：
#   1. 事件查询全部在子进程里跑（Get-WinEvent 在 Server Core 上可能几百毫秒到几十秒）；
#   2. 文件日志只读末尾一段，不把几百 MB 的日志一次性读进内存；
#   3. 统一条目结构：Time / Level / Source / Id / Message，界面与导出共用。

$script:LogsToolRoot = Split-Path -Parent $PSScriptRoot

function Test-GuiReadyLogAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-GuiReadySinceTime {
    # 把界面的时间范围选项转成起始时间；all 返回 $null。
    param([string]$Since = '24h')

    switch ($Since) {
        '1h'  { return (Get-Date).AddHours(-1) }
        '6h'  { return (Get-Date).AddHours(-6) }
        '24h' { return (Get-Date).AddHours(-24) }
        '7d'  { return (Get-Date).AddDays(-7) }
        '30d' { return (Get-Date).AddDays(-30) }
        default { return $null }
    }
}

function Get-GuiReadyEventLevelName {
    param([int]$Level)

    switch ($Level) {
        1 { return '错误' }      # Critical
        2 { return '错误' }      # Error
        3 { return '警告' }
        4 { return '信息' }
        default { return '详细' }
    }
}

function Get-GuiReadyLogSourceList {
    # 事件日志固定四项 + 工具 logs 目录下的文本日志（最多 20 个）。
    $isAdmin = Test-GuiReadyLogAdmin
    $list = New-Object System.Collections.ArrayList

    foreach ($name in @('System', 'Application', 'Setup', 'Security')) {
        $detail = ''
        $count = -1
        try {
            $l = Get-WinEvent -ListLog $name -ErrorAction Stop
            $count = [long]$l.RecordCount
            $detail = ('{0} 条记录' -f $count.ToString('N0'))
        } catch {
            $detail = $_.Exception.Message
        }
        if ($name -eq 'Security' -and -not $isAdmin) {
            $detail = '需要管理员权限'
        }
        [void]$list.Add([pscustomobject]@{
            Id = ('event:' + $name); Kind = 'event'; Name = $name; Path = ''
            Detail = $detail
        })
    }

    $logsDir = Join-Path $script:LogsToolRoot 'logs'
    if (Test-Path -LiteralPath $logsDir -PathType Container) {
        try {
            $files = @(Get-ChildItem -LiteralPath $logsDir -File -ErrorAction Stop |
                Where-Object { $_.Extension -eq '.log' -or $_.Extension -eq '.txt' } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 20)
            foreach ($f in $files) {
                [void]$list.Add([pscustomobject]@{
                    Id = ('file:' + $f.FullName); Kind = 'file'; Name = $f.Name; Path = $f.FullName
                    Detail = ('{0:0.0} KB · {1}' -f ($f.Length / 1024.0), $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
                })
            }
        } catch { }
    }

    return @($list)
}

function Read-GuiReadyLogTailLines {
    # 高效读取文本文件末尾：大文件只读最后 MaxBytes，并丢掉第一条不完整的行。
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int64]$MaxBytes = 1048576
    )

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        $start = [int64][Math]::Max(0, ($len - $MaxBytes))
        $fs.Position = $start
        $buf = New-Object byte[] ([int]($len - $start))
        $read = 0
        while ($read -lt $buf.Length) {
            $k = $fs.Read($buf, $read, $buf.Length - $read)
            if ($k -le 0) { break }
            $read += $k
        }
    } finally { $fs.Dispose() }

    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = $strict.GetString($buf, 0, $read)
    } catch {
        $text = [System.Text.Encoding]::Default.GetString($buf, 0, $read)
    }

    if ($start -gt 0) {
        $i = $text.IndexOf("`n")
        if ($i -ge 0) { $text = $text.Substring($i + 1) }
    }
    return @($text -split "`r?`n")
}

function ConvertFrom-GuiReadyFileLogLine {
    # 解析常见文本日志行：[2026-10-22 10:00:00] [INFO] xxx / 2026-10-22 10:00:00 ERROR xxx
    param([string]$Line, [string]$SourceName)

    $t = ''
    $ts = [datetime]::MinValue
    $m = [regex]::Match($Line, '^\s*\[?(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})')
    if ($m.Success) {
        $t = $m.Groups[1].Value.Replace('T', ' ')
        $parsed = [datetime]::MinValue
        $formats = @('yyyy-MM-dd HH:mm:ss')
        if ([datetime]::TryParseExact($t, $formats, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $ts = $parsed
        }
    }

    $level = '信息'
    if ($Line -match '错误|FATAL|CRITICAL|\bERROR\b|\bERR\b') { $level = '错误' }
    elseif ($Line -match '警告|WARN|WARNING') { $level = '警告' }
    elseif ($Line -match '调试|DEBUG|TRACE') { $level = '详细' }
    elseif ($Line -match '信息|INFO') { $level = '信息' }

    return [pscustomobject]@{
        Time = $t; Level = $level; Source = $SourceName; Id = ''; Message = $Line; Stamp = $ts
    }
}

function Get-GuiReadyLogEntries {
    # 统一入口：返回最新的 N 条，按时间倒序。事件日志与文件日志都走这里。
    param(
        [string]$Source = 'event:System',
        [int]$Max = 300,
        [ValidateSet('All', 'Error', 'Warning', 'Information')][string]$Level = 'All',
        [string]$Since = '24h',
        [string]$Keyword = ''
    )

    if ($Max -lt 1) { $Max = 1 }
    if ($Max -gt 2000) { $Max = 2000 }
    $start = Get-GuiReadySinceTime -Since $Since
    $isAdmin = Test-GuiReadyLogAdmin

    $src = ([string]$Source).Trim()
    if (-not $src) { $src = 'event:System' }
    $isFile = $false
    $filePath = ''
    $logName = ''

    if ($src -match '^event:(.+)$') {
        $logName = $Matches[1]
    } elseif ($src -match '^file:(.+)$') {
        $isFile = $true; $filePath = $Matches[1]
    } elseif (Test-Path -LiteralPath $src -PathType Leaf) {
        $isFile = $true; $filePath = $src
    } else {
        $logName = $src
    }

    if ($isFile) {
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { throw ('日志文件不存在：' + $filePath) }
        $fi = New-Object System.IO.FileInfo($filePath)
        $maxBytes = [int64]1048576
        if ($fi.Length -le 8MB) { $maxBytes = [int64][Math]::Max(65536, $fi.Length) }
        $lines = @(Read-GuiReadyLogTailLines -Path $filePath -MaxBytes $maxBytes)

        $entries = New-Object System.Collections.ArrayList
        $srcName = $fi.Name
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $e = ConvertFrom-GuiReadyFileLogLine -Line $line -SourceName $srcName
            if ($Keyword -and $e.Message.IndexOf($Keyword, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            if ($start -and $e.Stamp -ne [datetime]::MinValue -and $e.Stamp -lt $start) { continue }
            if ($Level -ne 'All') {
                if ($Level -eq 'Error' -and $e.Level -ne '错误') { continue }
                if ($Level -eq 'Warning' -and $e.Level -ne '警告') { continue }
                if ($Level -eq 'Information' -and $e.Level -ne '信息') { continue }
            }
            [void]$entries.Add($e)
        }

        $truncated = ($entries.Count -gt $Max)
        $take = @($entries)
        if ($truncated) { $take = @($entries | Select-Object -Last $Max) }
        [array]::Reverse($take)
        $out = @()
        foreach ($e in $take) { $out += [pscustomobject]@{ Time = $e.Time; Level = $e.Level; Source = $e.Source; Id = $e.Id; Message = $e.Message } }
        return [pscustomobject]@{ Source = ('file:' + $filePath); Count = $out.Count; Truncated = $truncated; Entries = @($out) }
    }

    if (-not $logName) { $logName = 'System' }
    if ($logName -eq 'Security' -and -not $isAdmin) {
        throw '读取安全日志需要管理员权限。请以管理员身份运行本工具。'
    }

    $h = @{ LogName = $logName }
    if ($start) { $h['StartTime'] = $start }
    switch ($Level) {
        'Error'       { $h['Level'] = @(1, 2) }
        'Warning'     { $h['Level'] = @(3) }
        'Information' { $h['Level'] = @(4) }
    }

    try {
        $events = @(Get-WinEvent -FilterHashtable $h -MaxEvents $Max -ErrorAction Stop)
    } catch {
        $msg = [string]$_.Exception.Message
        if ($logName -eq 'Security' -and ($msg -match 'access|denied|拒绝|权限|privilege')) {
            throw '读取安全日志需要管理员权限。请以管理员身份运行本工具。'
        }
        throw ('读取事件日志失败：' + $msg)
    }

    $out = New-Object System.Collections.ArrayList
    foreach ($ev in $events) {
        $message = [string]$ev.Message
        if ($Keyword -and $message.IndexOf($Keyword, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $lvl = Get-GuiReadyEventLevelName -Level ([int]$ev.Level)
        if ($Level -ne 'All') {
            if ($Level -eq 'Error' -and $lvl -ne '错误') { continue }
            if ($Level -eq 'Warning' -and $lvl -ne '警告') { continue }
            if ($Level -eq 'Information' -and $lvl -ne '信息') { continue }
        }
        [void]$out.Add([pscustomobject]@{
            Time = $ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
            Level = $lvl
            Source = [string]$ev.ProviderName
            Id = [string]$ev.Id
            Message = $message
        })
    }

    return [pscustomobject]@{
        Source = ('event:' + $logName)
        Count = $out.Count
        Truncated = ($events.Count -ge $Max)
        Entries = @($out)
    }
}

function Export-GuiReadyLog {
    # 把条目导出为 CSV 或文本。事件日志可能有几千条，导出同样走动作子进程。
    param(
        [Parameter(Mandatory = $true)]$Entries,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Csv', 'Text')][string]$Format = 'Csv',
        [switch]$WhatIf
    )

    $p = [Environment]::ExpandEnvironmentVariables(([string]$Path).Trim())
    if (-not $p) { throw '导出路径不能为空。' }
    if ($p -match '^[A-Za-z]:(?![\\/])' -or -not [System.IO.Path]::IsPathRooted($p)) {
        throw ('请使用绝对路径导出：' + $p)
    }
    $full = [System.IO.Path]::GetFullPath($p)
    if (Test-Path -LiteralPath $full -PathType Container) { throw ('导出路径是目录：' + $full) }
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw ('导出目录不存在：' + $parent) }

    $rows = @($Entries | Where-Object { $_ })
    if ($WhatIf) { return [pscustomobject]@{ Path = $full; Rows = $rows.Count; Format = $Format } }

    if ($Format -eq 'Csv') {
        if ($rows.Count -eq 0) {
            [System.IO.File]::WriteAllText($full, "Time,Level,Source,Id,Message`r`n", (New-Object System.Text.UTF8Encoding($true)))
        } else {
            $rows | Select-Object Time, Level, Source, Id, Message |
                Export-Csv -LiteralPath $full -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        }
    } else {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("时间`t级别`t来源`t事件ID`t消息")
        foreach ($r in $rows) {
            $msg = ([string]$r.Message) -replace "`r?`n", ' | '
            [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}" -f $r.Time, $r.Level, $r.Source, $r.Id, $msg))
        }
        [System.IO.File]::WriteAllText($full, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    }

    return [pscustomobject]@{ Path = $full; Rows = $rows.Count; Format = $Format }
}

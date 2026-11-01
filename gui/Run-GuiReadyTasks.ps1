# GuiReady tasks query runner: task list / detail, audit trail, notification inbox
# and task cancellation, all executed in a separate process so scanning thousands
# of JSON records can never block the UI thread.
#
# Modes:
#   list         -> recent tasks + stats + unread notification count
#   detail       -> one task plus its audit trail
#   audit        -> audit events with level / event / time / keyword filters
#   audit-export -> same filters, written to a CSV or JSONL file
#   notify       -> notification inbox
#   notify-read  -> mark one (Id) or all (All) notifications as read
#   notify-clear -> empty the inbox
#   cancel       -> stop a running task (only when the process is verified as ours)
#
# All external values arrive through -ArgsFile as JSON.
#
# Keep this file ASCII-only: it ships inside the release zip and must parse under any
# console code page without depending on a BOM.

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-tasks.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Files.ps1', 'GuiReady.Tasks.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TasksResult {
    param($Data, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode   = $Mode
        Stamp  = (Get-Date).ToString('o')
        Error  = $ErrorText
        Data   = $Data
    }
    try {
        $json = $o | ConvertTo-Json -Depth 8 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

$A = @{}
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $raw = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $obj = $raw | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $A[$prop.Name] = $prop.Value }
        }
    } catch {
        Write-TasksResult -Data $null -ErrorText ('args parse failed: ' + $_.Exception.Message)
        exit 1
    }
}

function Get-ArgString {
    param([string]$Name, [string]$Default = '')
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return [string]$A[$Name] }
    return $Default
}

function Get-ArgInt {
    param([string]$Name, [int]$Default = 0)
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) {
        try { return [int]$A[$Name] } catch { return $Default }
    }
    return $Default
}

function Get-ArgBool {
    param([string]$Name, [bool]$Default = $false)
    if ($A.ContainsKey($Name)) {
        try { return [bool]$A[$Name] } catch { return $Default }
    }
    return $Default
}

try {
    switch ($Mode) {
        'list' {
            $limit = Get-ArgInt -Name 'Limit' -Default 200
            if ($limit -lt 1) { $limit = 200 }
            if ($limit -gt 1000) { $limit = 1000 }
            [void](Update-GuiReadyStaleTasks)
            $items = @(Get-GuiReadyTaskList -Limit $limit -SinceHours (Get-ArgInt -Name 'SinceHours') `
                          -Status (Get-ArgString -Name 'Status') -ActionId (Get-ArgString -Name 'ActionId') `
                          -Keyword (Get-ArgString -Name 'Keyword'))
            $data = [ordered]@{
                Items  = @($items)
                Stats  = (Get-GuiReadyTaskStats -Items $items)
                Unread = (Get-GuiReadyNotificationUnreadCount)
                Now    = (Get-Date).ToString('o')
            }
            Write-TasksResult -Data $data
            exit 0
        }
        'detail' {
            $id = Get-ArgString -Name 'Id'
            if (-not $id) { Write-TasksResult -Data $null -ErrorText 'Id is required'; exit 2 }
            $t = Get-GuiReadyTask -Id $id
            if (-not $t) { Write-TasksResult -Data $null -ErrorText ('task not found: ' + $id); exit 1 }
            $trail = @(Get-GuiReadyAuditList -TaskId $id -Limit 200)
            Write-TasksResult -Data ([ordered]@{ Task = $t; Trail = @($trail) })
            exit 0
        }
        'audit' {
            $limit = Get-ArgInt -Name 'Limit' -Default 300
            if ($limit -lt 1) { $limit = 300 }
            if ($limit -gt 2000) { $limit = 2000 }
            $items = @(Get-GuiReadyAuditList -Limit $limit -SinceHours (Get-ArgInt -Name 'SinceHours') `
                          -Level (Get-ArgString -Name 'Level') -Event (Get-ArgString -Name 'Event') `
                          -TaskId (Get-ArgString -Name 'TaskId') -Keyword (Get-ArgString -Name 'Keyword'))
            Write-TasksResult -Data ([ordered]@{ Items = @($items); Count = $items.Count })
            exit 0
        }
        'audit-export' {
            $path = Get-ArgString -Name 'Path'
            if (-not $path) { Write-TasksResult -Data $null -ErrorText 'Path is required'; exit 2 }
            if (-not [System.IO.Path]::IsPathRooted($path)) {
                Write-TasksResult -Data $null -ErrorText 'Path must be absolute'
                exit 2
            }
            $items = @(Get-GuiReadyAuditList -Limit (Get-ArgInt -Name 'Limit' -Default 5000) `
                          -SinceHours (Get-ArgInt -Name 'SinceHours') -Level (Get-ArgString -Name 'Level') `
                          -Event (Get-ArgString -Name 'Event') -Keyword (Get-ArgString -Name 'Keyword'))
            $r = Export-GuiReadyAudit -Entries $items -Path $path -Format (Get-ArgString -Name 'Format' -Default 'Csv') `
                    -WhatIf:(Get-ArgBool -Name 'DryRun')
            Write-TasksResult -Data ([ordered]@{ Path = $r.Path; Format = $r.Format; Count = $r.Count })
            exit 0
        }
        'notify' {
            $items = @(Get-GuiReadyNotificationList -Limit (Get-ArgInt -Name 'Limit' -Default 200) `
                          -UnreadOnly:(Get-ArgBool -Name 'UnreadOnly'))
            Write-TasksResult -Data ([ordered]@{ Items = @($items); Unread = (Get-GuiReadyNotificationUnreadCount) })
            exit 0
        }
        'notify-read' {
            $unread = Set-GuiReadyNotificationRead -Id (Get-ArgString -Name 'Id') -All:(Get-ArgBool -Name 'All')
            Write-TasksResult -Data ([ordered]@{ Unread = $unread })
            exit 0
        }
        'notify-clear' {
            $unread = Clear-GuiReadyNotifications
            Write-TasksResult -Data ([ordered]@{ Unread = $unread })
            exit 0
        }
        'cancel' {
            $id = Get-ArgString -Name 'Id'
            if (-not $id) { Write-TasksResult -Data $null -ErrorText 'Id is required'; exit 2 }
            $r = Stop-GuiReadyTask -Id $id
            Write-TasksResult -Data ([ordered]@{ Ok = $r.Ok; Killed = $r.Killed; Message = $r.Message })
            exit 0
        }
        default {
            Write-TasksResult -Data $null -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
} catch {
    Write-TasksResult -Data $null -ErrorText $_.Exception.Message
    exit 1
}

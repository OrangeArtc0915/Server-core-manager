# 性能历史 / 告警 / 事件的 runner。
# 封套与其它 runner 一致：-Mode <m> -OutFile <json> [-ArgsFile <json>]

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'
$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\metrics-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.TasksPlus.ps1', 'GuiReady.Notify.ps1', 'GuiReady.Metrics.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$A = @{}
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $obj = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) { $A[$prop.Name] = $prop.Value }
    } catch { }
    try { Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue } catch { }
}

function Get-Opt {
    param([string]$Name, $Default = '')
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return $A[$Name] }
    return $Default
}
function Get-OptInt {
    param([string]$Name, [int]$Default = 0)
    $n = 0
    if ([int]::TryParse([string](Get-Opt $Name ''), [ref]$n)) { return $n }
    return $Default
}
function Get-OptBool {
    param([string]$Name, [bool]$Default = $false)
    $v = Get-Opt $Name $null
    if ($null -eq $v) { return $Default }
    if ($v -is [bool]) { return $v }
    return ([string]$v -match '^(1|true|yes|on)$')
}

function Write-MetricsResult {
    param($Data, $Items, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode  = $Mode
        Stamp = (Get-Date).ToString('o')
        Error = $ErrorText
        Data  = $Data
        Items = @($Items)
    }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $json = $o | ConvertTo-Json -Depth 10 -Compress
        $tmp = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    switch ($Mode) {
        'sample' {
            $s = Save-GuiReadyMetricsSample
            Write-MetricsResult -Data $s -Items @()
        }
        'history' {
            $days = Get-OptInt 'Days' 7
            $rows = @(Get-GuiReadyMetricsHistory -Days $days)
            $items = @($rows | ForEach-Object {
                [pscustomobject]@{
                    Time = $_.Time.ToString('yyyy-MM-dd HH:mm:ss')
                    CpuPct = $_.CpuPct; MemPct = $_.MemPct
                    DiskFreeGB = $_.DiskFreeGB; DiskTotalGB = $_.DiskTotalGB; DiskPct = $_.DiskPct
                    NetInKB = $_.NetInKB; NetOutKB = $_.NetOutKB
                    ProcCount = $_.ProcCount; UptimeHours = $_.UptimeHours
                }
            })
            Write-MetricsResult -Data @{ Days = $days; Summary = (Get-GuiReadyMetricsSummary -Rows $rows) } -Items $items
        }
        'summary' {
            $days = Get-OptInt 'Days' 1
            $rows = @(Get-GuiReadyMetricsHistory -Days $days)
            Write-MetricsResult -Data (Get-GuiReadyMetricsSummary -Rows $rows) -Items @()
        }
        'report' {
            $days = Get-OptInt 'Days' 7
            $out = [string](Get-Opt 'OutFile' '')
            $file = New-GuiReadyMetricsReport -Days $days -OutFile $out
            Write-MetricsResult -Data @{ Days = $days; File = $file } -Items @()
        }
        'alert-list' {
            $rules = @(Get-GuiReadyAlertRules)
            Write-MetricsResult -Data @{ Count = $rules.Count } -Items $rules
        }
        'alert-add' {
            $r = Add-GuiReadyAlertRule -Name ([string](Get-Opt 'Name' '告警规则')) `
                -Metric ([string](Get-Opt 'Metric' 'cpu')) -Operator ([string](Get-Opt 'Operator' 'gt')) `
                -Threshold ([double](Get-Opt 'Threshold' 0)) -DurationMin (Get-OptInt 'DurationMin' 5) `
                -EventId ([string](Get-Opt 'EventId' '')) -EventLog ([string](Get-Opt 'EventLog' 'System,Application')) `
                -Action ([string](Get-Opt 'Action' 'notify')) -ActionId ([string](Get-Opt 'ActionId' '')) `
                -CooldownMin (Get-OptInt 'CooldownMin' 30)
            Write-MetricsResult -Data $r -Items @()
        }
        'alert-remove' {
            Remove-GuiReadyAlertRule -Id ([string](Get-Opt 'Id' ''))
            Write-MetricsResult -Data @{ Id = [string](Get-Opt 'Id' '') } -Items @()
        }
        'alert-toggle' {
            $enabled = Get-OptBool 'Enabled' $true
            Set-GuiReadyAlertRuleEnabled -Id ([string](Get-Opt 'Id' '')) -Enabled $enabled
            Write-MetricsResult -Data @{ Id = [string](Get-Opt 'Id' ''); Enabled = $enabled } -Items @()
        }
        'alert-check' {
            $r = Invoke-GuiReadyAlertCheck -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MetricsResult -Data $r -Items @()
        }
        'alert-history' {
            $items = @(Get-GuiReadyAlertHistory -Max (Get-OptInt 'Max' 100))
            Write-MetricsResult -Data @{ Count = $items.Count } -Items $items
        }
        'event-recent' {
            $items = @(Get-GuiReadyCriticalEvents -Hours (Get-OptInt 'Hours' 24) -Max (Get-OptInt 'Max' 200))
            Write-MetricsResult -Data @{ Hours = (Get-OptInt 'Hours' 24); Count = $items.Count } -Items $items
        }
        'event-subscribe' {
            $t = Install-GuiReadyAlertTask -IntervalMin (Get-OptInt 'IntervalMin' 2) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MetricsResult -Data $t -Items @()
        }
        'event-unsubscribe' {
            Remove-GuiReadyAlertTask -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MetricsResult -Data @{ Removed = $true } -Items @()
        }
        'metrics-task-install' {
            $t = Install-GuiReadyMetricsTask -IntervalMin (Get-OptInt 'IntervalMin' 5) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MetricsResult -Data $t -Items @()
        }
        'metrics-task-remove' {
            Remove-GuiReadyMetricsTask -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MetricsResult -Data @{ Removed = $true } -Items @()
        }
        'alert-task-install' {
            $t = Install-GuiReadyAlertTask -IntervalMin (Get-OptInt 'IntervalMin' 2) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MetricsResult -Data $t -Items @()
        }
        'alert-task-remove' {
            Remove-GuiReadyAlertTask -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MetricsResult -Data @{ Removed = $true } -Items @()
        }
        'maintenance-get' {
            Write-MetricsResult -Data (Get-GuiReadyMaintenanceWindow) -Items @()
        }
        'maintenance-start' {
            $m = Set-GuiReadyMaintenanceWindow -Minutes (Get-OptInt 'Minutes' 60) -Reason ([string](Get-Opt 'Reason' '维护窗口'))
            Write-MetricsResult -Data $m -Items @()
        }
        'maintenance-stop' {
            Clear-GuiReadyMaintenanceWindow
            Write-MetricsResult -Data @{ Active = $false } -Items @()
        }
        'task-status' {
            $m = Get-GuiReadyPlusTaskState 'ScmPlus-Metrics'
            $a = Get-GuiReadyPlusTaskState 'ScmPlus-Alerts'
            Write-MetricsResult -Data @{ Metrics = $m; Alerts = $a; Maintenance = (Get-GuiReadyMaintenanceWindow) } -Items @()
        }
        default { Write-MetricsResult -ErrorText ('未知模式：' + $Mode) }
    }
} catch {
    Write-Log ('metrics runner 失败：' + $_.Exception.Message) 'ERROR'
    Write-MetricsResult -ErrorText $_.Exception.Message
}

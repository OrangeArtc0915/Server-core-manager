# GuiReady 运维自动化 runner：进程守护 / 计划任务 / 目录备份 / 端口巡检 / 下载队列。
# 与其它 runner 同一套封套：-Mode <m> -OutFile <json> [-ArgsFile <json>]
#
# 计划任务（ScmOps-*）会直接调用这里的 guard-check / plan-run / backup-run，
# 所以这些模式不需要联网，也不依赖界面。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$Id = '',
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\ops-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Ops.ps1')) {
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
if (-not $Id -and $A['Id']) { $Id = [string]$A['Id'] }

function Get-Opt {
    param([string]$Name, $Default = '')
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return $A[$Name] }
    return $Default
}

function Get-OptInt {
    param([string]$Name, [int]$Default = 0)
    $v = Get-Opt $Name ''
    $n = 0
    if ([int]::TryParse([string]$v, [ref]$n)) { return $n }
    return $Default
}

function Write-OpsResult {
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
        'list' {
            $ov = Get-GuiReadyOpsOverview
            Write-OpsResult -Data $ov.Data -Items @($ov.Items)
        }

        # ---------------- 进程守护 ----------------
        'guard-add' {
            $r = New-GuiReadyGuard -Name ([string](Get-Opt 'Name' '守护项')) -Exe ([string](Get-Opt 'Exe')) `
                -Args ([string](Get-Opt 'Args' '')) -WorkDir ([string](Get-Opt 'WorkDir' '')) `
                -IntervalMin (Get-OptInt 'IntervalMin' 1) -DelaySec (Get-OptInt 'DelaySec' 15) `
                -RunAs ([string](Get-Opt 'RunAs' 'user')) -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $r.Id; Name = $r.Name; Exe = $r.Exe }) -Items @()
        }
        'guard-remove' {
            if (-not $Id) { throw '缺少参数：Id' }
            Remove-GuiReadyGuard -Id $Id -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $Id }) -Items @()
        }
        'guard-toggle' {
            if (-not $Id) { throw '缺少参数：Id' }
            $enabled = [bool](Get-Opt 'Enabled' $true)
            Set-GuiReadyGuardEnabled -Id $Id -Enabled $enabled -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $Id; Enabled = $enabled }) -Items @()
        }
        'guard-check' {
            $r = @(Invoke-GuiReadyGuardCheck -Id $Id -DryRun:([bool](Get-Opt 'DryRun' $false)))
            Write-OpsResult -Data ([pscustomobject]@{ Checked = $r.Count }) -Items $r
        }

        # ---------------- 计划任务 ----------------
        'plan-add' {
            $r = New-GuiReadyPlan -Name ([string](Get-Opt 'Name' '计划任务')) -Chain ([string](Get-Opt 'Chain' '')) `
                -Schedule ([string](Get-Opt 'Schedule' 'interval')) -IntervalMin (Get-OptInt 'IntervalMin' 60) `
                -Time ([string](Get-Opt 'Time' '03:00')) -Weekday ([string](Get-Opt 'Weekday' 'Monday')) `
                -RunAs ([string](Get-Opt 'RunAs' 'user')) `
                -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $r.Id; Name = $r.Name; Chain = $r.Chain }) -Items @()
        }
        'plan-remove' {
            if (-not $Id) { throw '缺少参数：Id' }
            Remove-GuiReadyPlan -Id $Id -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $Id }) -Items @()
        }
        'plan-toggle' {
            if (-not $Id) { throw '缺少参数：Id' }
            $enabled = [bool](Get-Opt 'Enabled' $true)
            Set-GuiReadyPlanEnabled -Id $Id -Enabled $enabled -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $Id; Enabled = $enabled }) -Items @()
        }
        'plan-run' {
            if (-not $Id) { throw '缺少参数：Id' }
            $r = Invoke-GuiReadyPlan -Id $Id -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data $r -Items @()
        }

        # ---------------- 目录备份 ----------------
        'backup-add' {
            $r = New-GuiReadyBackupJob -Name ([string](Get-Opt 'Name' '目录备份')) -Source ([string](Get-Opt 'Source' '')) `
                -Target ([string](Get-Opt 'Target' '')) -Mode ([string](Get-Opt 'BackupMode' 'zip')) `
                -Keep (Get-OptInt 'Keep' 3) -Time ([string](Get-Opt 'Time' '02:00')) `
                -RunAs ([string](Get-Opt 'RunAs' 'user')) -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $r.Id; Name = $r.Name; Target = $r.Target }) -Items @()
        }
        'backup-run' {
            if (-not $Id) { throw '缺少参数：Id' }
            $r = Invoke-GuiReadyBackupJob -Id $Id -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data $r -Items @()
        }
        'backup-remove' {
            if (-not $Id) { throw '缺少参数：Id' }
            Remove-GuiReadyBackupJob -Id $Id -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $Id }) -Items @()
        }

        # ---------------- 端口巡检 ----------------
        'patrol-add' {
            $r = New-GuiReadyPatrol -Name ([string](Get-Opt 'Name' '端口巡检')) -TargetHost ([string](Get-Opt 'Host' '127.0.0.1')) `
                -Ports ([string](Get-Opt 'Ports' '')) -TimeoutMs (Get-OptInt 'TimeoutMs' 1500) `
                -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $r.Id; Name = $r.Name; Ports = $r.Ports }) -Items @()
        }
        'patrol-run' {
            if (-not $Id) { throw '缺少参数：Id' }
            $r = @(Invoke-GuiReadyPortPatrol -Id $Id -DryRun:([bool](Get-Opt 'DryRun' $false)))
            Write-OpsResult -Data ([pscustomobject]@{ Checked = $r.Count }) -Items $r
        }
        'patrol-remove' {
            if (-not $Id) { throw '缺少参数：Id' }
            Remove-GuiReadyPatrol -Id $Id -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $Id }) -Items @()
        }

        # ---------------- 下载队列 ----------------
        'download-add' {
            $r = Add-GuiReadyDownload -Url ([string](Get-Opt 'Url' '')) -Folder ([string](Get-Opt 'Folder' '')) `
                -FileName ([string](Get-Opt 'FileName' '')) -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $(if ($r.Id) { $r.Id } else { '' }); File = $r.File }) -Items @()
        }
        'download-action' {
            if (-not $Id) { throw '缺少参数：Id' }
            $act = [string](Get-Opt 'Action' 'pause')
            Set-GuiReadyDownloadAction -Id $Id -Action $act -DryRun:([bool](Get-Opt 'DryRun' $false))
            Write-OpsResult -Data ([pscustomobject]@{ Id = $Id; Action = $act }) -Items @()
        }

        default {
            Write-OpsResult -Data $null -Items @() -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
    exit 0
} catch {
    Write-OpsResult -Data $null -Items @() -ErrorText $_.Exception.Message
    exit 1
}

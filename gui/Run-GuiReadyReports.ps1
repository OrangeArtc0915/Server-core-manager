# 报告中心 runner：列表 / 打包 / 发送 / 每日任务。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'
$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\reports-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.TasksPlus.ps1', 'GuiReady.Notify.ps1', 'GuiReady.Reports.ps1')) {
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
function Get-Opt { param([string]$Name, $Default = '') if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return $A[$Name] } return $Default }
function Get-OptBool { param([string]$Name, [bool]$Default = $false) $v = Get-Opt $Name $null; if ($null -eq $v) { return $Default }; if ($v -is [bool]) { return $v }; return ([string]$v -match '^(1|true|yes|on)$') }

function Write-ReportResult {
    param($Data, $Items, [string]$ErrorText = '')
    $o = [ordered]@{ Mode = $Mode; Stamp = (Get-Date).ToString('o'); Error = $ErrorText; Data = $Data; Items = @($Items) }
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
            $items = @(Get-GuiReadyReportList)
            Write-ReportResult -Data @{ Count = $items.Count; Root = (Get-GuiReadyReportsRoot) } -Items $items
        }
        'bundle' {
            $files = @()
            $raw = [string](Get-Opt 'Files' '')
            if ($raw) { $files = @($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            $b = New-GuiReadyReportBundle -Files $files -OutFile ([string](Get-Opt 'OutFile' ''))
            Write-ReportResult -Data $b -Items @()
        }
        'send' {
            $file = [string](Get-Opt 'File' '')
            if (-not $file) {
                $b = New-GuiReadyReportBundle
                $file = $b.File
            }
            $r = Send-GuiReadyNotify -Title ([string](Get-Opt 'Title' 'SCM 报告')) -Text ([string](Get-Opt 'Text' '报告包已生成')) `
                -Level 'Info' -Attachment $file -DryRun:(Get-OptBool 'DryRun' $false)
            Write-ReportResult -Data @{ File = $file; Notify = $r } -Items @()
        }
        'task-install' {
            $t = Install-GuiReadyReportTask -Send:(Get-OptBool 'Send' $false) -Time ([string](Get-Opt 'Time' '08:00')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-ReportResult -Data $t -Items @()
        }
        'task-remove' {
            Remove-GuiReadyReportTask -DryRun:(Get-OptBool 'DryRun' $false)
            Write-ReportResult -Data @{ Removed = $true } -Items @()
        }
        'task-status' {
            Write-ReportResult -Data @{ Task = (Get-GuiReadyPlusTaskState 'ScmPlus-Reports'); Config = (Get-GuiReadyReportConfig) } -Items @()
        }
        'auto' {
            $b = Invoke-GuiReadyReportAuto
            Write-ReportResult -Data $b -Items @()
        }
        default { Write-ReportResult -ErrorText ('未知模式：' + $Mode) }
    }
} catch {
    Write-Log ('reports runner 失败：' + $_.Exception.Message) 'ERROR'
    Write-ReportResult -ErrorText $_.Exception.Message
}

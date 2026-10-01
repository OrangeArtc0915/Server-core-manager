# GuiReady monitor query runner: collects one system snapshot in a separate process
# (Get-Counter takes ~1 s, Get-WinEvent several hundred ms and much more on Server Core).
#
# Modes:
#   snapshot -> CPU / memory / disks / key services / recent system errors / top processes
#
# Keep this file ASCII-only: it ships inside the release zip and must parse under any
# console code page without depending on a BOM.

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-monitor.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Monitor.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-MonitorResult {
    param($Snapshot, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode   = $Mode
        Stamp  = (Get-Date).ToString('o')
        Error  = $ErrorText
        Snap   = $Snapshot
    }
    try {
        $json = $o | ConvertTo-Json -Depth 6 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    switch ($Mode) {
        'snapshot' {
            $snap = Get-GuiReadyMonitorSnapshot
            Write-MonitorResult -Snapshot $snap
            exit 0
        }
        default {
            Write-MonitorResult -Snapshot $null -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
} catch {
    Write-MonitorResult -Snapshot $null -ErrorText $_.Exception.Message
    exit 1
}

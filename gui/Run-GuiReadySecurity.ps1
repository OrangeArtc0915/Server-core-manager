# GuiReady security audit runner: runs the local baseline checks in a separate process
# (secedit export, Get-NetFirewallProfile, Get-WinEvent on the Security log - all slow
# enough that the UI thread must not wait for them).
#
# Modes:
#   audit -> the baseline items + summary
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

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-security.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Security.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-SecurityResult {
    param($Items, $Summary, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode    = $Mode
        Stamp   = (Get-Date).ToString('o')
        Error   = $ErrorText
        Summary = $Summary
        Items   = @($Items)
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
        'audit' {
            $items = @(Get-GuiReadySecurityAudit)
            Write-SecurityResult -Items $items -Summary (Get-GuiReadySecuritySummary -Items $items)
            exit 0
        }
        default {
            Write-SecurityResult -Items @() -Summary $null -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
} catch {
    Write-SecurityResult -Items @() -Summary $null -ErrorText $_.Exception.Message
    exit 1
}

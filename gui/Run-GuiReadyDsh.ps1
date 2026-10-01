# GuiReady DeepSeek Harness (dsh-TUI) dependency probe runner.
#
# Runs in a separate process because it shells out to node / pnpm / dsh and (in deep mode)
# asks npm about the packages - each of those can take seconds.
#
# Modes:
#   status -> dependency rows (+ npm package existence when -DeepProbe is passed)
#
# Keep this file ASCII-only: it ships inside the release zip and must parse under any
# console code page without depending on a BOM.

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [switch]$DeepProbe
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-dsh.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Dsh.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-DshResult {
    param($Status, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode   = $Mode
        Stamp  = (Get-Date).ToString('o')
        Error  = $ErrorText
        Status = $Status
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
        'status' {
            $st = Get-GuiReadyDshStatus -DeepProbe:$DeepProbe
            Write-DshResult -Status $st
            exit 0
        }
        default {
            Write-DshResult -Status $null -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
} catch {
    Write-DshResult -Status $null -ErrorText $_.Exception.Message
    exit 1
}

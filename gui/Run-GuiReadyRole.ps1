# GuiReady role query runner: reads the Server role / feature list in a separate process.
#
# Why a separate process: Get-WindowsFeature is slow on Server Core (it talks to the CBS /
# DISM stack and takes seconds), and Install-WindowsFeature is minutes - the role page must
# never block on it. Same pattern as Run-GuiReadyProbe.ps1 / Run-GuiReadyStore.ps1.
#
# Modes:
#   support -> capability probe only (ServerManager / DISM / admin / OS type)
#   list    -> capability probe + the full role & feature list + counts
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

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-role.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Role.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-RoleResult {
    param($Support, $Summary, $Items, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode    = $Mode
        Stamp   = (Get-Date).ToString('o')
        Error   = $ErrorText
        Support = $Support
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
    $support = Get-GuiReadyRoleSupport
    $items   = @()
    if ($Mode -eq 'list' -or $Mode -eq 'support') {
        if ($support.ServerManager) { $items = @(Get-GuiReadyRoleList) }
    }
    $summary = Get-GuiReadyRoleSummary -Items $items
    Write-RoleResult -Support $support -Summary $summary -Items $items
    exit 0
} catch {
    Write-RoleResult -Support $null -Summary $null -Items @() -ErrorText $_.Exception.Message
    exit 1
}

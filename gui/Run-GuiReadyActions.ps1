# GuiReady actions metadata runner: exposes the action catalog (id / group / name / desc /
# dry-run flag / parameter descriptors) so the native UI can build the same form the
# PowerShell GUI builds in "All features".
#
# Modes:
#   list -> every action with its parameter metadata (script blocks are NOT serialized)
#
# The action scripts themselves still run through Run-GuiReadyAction.ps1; this runner only
# reads metadata, so it is safe and fast.
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

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-actions.log'

foreach ($f in @('GuiReady.Common.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}
# The action table lives next to this runner; it only defines functions, nothing runs at load.
. (Join-Path $PSScriptRoot 'GuiReady.Actions.ps1')

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-ActionsResult {
    param($Items, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode  = $Mode
        Stamp = (Get-Date).ToString('o')
        Error = $ErrorText
        Items = @($Items)
    }
    try {
        $json = $o | ConvertTo-Json -Depth 8 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    if ($Mode -ne 'list') {
        Write-ActionsResult -Items @() -ErrorText ('unknown mode: ' + $Mode)
        exit 2
    }

    $items = New-Object System.Collections.ArrayList
    foreach ($a in @(Get-GuiReadyActions)) {
        $ps = New-Object System.Collections.ArrayList
        foreach ($p in @($a.Params)) {
            if (-not $p) { continue }
            $opts = @()
            if ($p.ContainsKey('Options')) { $opts = @($p.Options) }
            $browse = ''
            if ($p.ContainsKey('Browse')) { $browse = [string]$p.Browse }
            $width = 0
            if ($p.ContainsKey('Width')) { $width = [int]$p.Width }
            $def = $null
            if ($p.ContainsKey('Default')) { $def = $p.Default }
            [void]$ps.Add([pscustomobject]@{
                Name    = [string]$p.Name
                Label   = [string]$p.Label
                Type    = [string]$p.Type
                Options = @($opts)
                Default = $def
                Width   = $width
                Browse  = $browse
                Req     = [bool]$p.Req
            })
        }
        [void]$items.Add([pscustomobject]@{
            Id     = [string]$a.Id
            Group  = [string]$a.Group
            Name   = [string]$a.Name
            Desc   = [string]$a.Desc
            DryRun = [bool]$a.DryRun
            Params = @($ps)
        })
    }
    Write-ActionsResult -Items @($items)
    exit 0
} catch {
    Write-ActionsResult -Items @() -ErrorText $_.Exception.Message
    exit 1
}

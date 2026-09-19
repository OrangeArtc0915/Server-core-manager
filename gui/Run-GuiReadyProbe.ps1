# GuiReady environment probe: runs the environment scan in a separate process so the GUI
# window never blocks on it (on Server Core the DISM / ServerManager queries take 5-7 s).
#
# Writes the result twice, as JSON, so the GUI can fill the fast part immediately:
#   stage=fast  quick checks only (OS info, DLL scan, .NET, sessions, UAC ...) - under 1 s
#               FOD state here is *inferred* from the GUI components (see Inferred=true)
#   stage=full  same data plus the exact DISM capability state and the WAC status
#
# Keep this file ASCII-only: it ships inside the release zip and must parse under any
# console code page without depending on a BOM.

param(
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$CacheFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

# One shared log file instead of one per probe run
$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-probe.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Detect.ps1', 'GuiReady.PeInspect.ps1',
                 'GuiReady.Fod.ps1', 'GuiReady.GuiShell.ps1', 'GuiReady.RdpFix.ps1',
                 'GuiReady.DotNet.ps1', 'GuiReady.GuiTest.ps1', 'GuiReady.Matrix.ps1',
                 'GuiReady.Diag.ps1', 'GuiReady.Catalog.ps1', 'GuiReady.Pipeline.ps1',
                 'GuiReady.AutoLogon.ps1', 'GuiReady.Command.ps1', 'GuiReady.PhaseB.ps1',
                 'GuiReady.Wac.ps1', 'GuiReady.Console.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-ProbeResult {
    param($Data, [string]$Stage, [string]$ErrorText = '')
    $o = [ordered]@{ Stage = $Stage; Stamp = (Get-Date).ToString('o'); Error = $ErrorText }
    foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] }
    try {
        $json = $o | ConvertTo-Json -Depth 8 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
        if ($Stage -eq 'full' -and $CacheFile) {
            try { [System.IO.File]::WriteAllText($CacheFile, $json, $utf8NoBom) } catch { }
        }
    } catch { }
}

$d = [ordered]@{
    Static = $null; Profile = $null; Cap = $null; DllScan = $null; DotNet = $null
    Sessions = $null; AutoLogon = $null; Uac = $null; Wac = $null
}

try {
    try { $d.Static    = Get-GuiReadyStatic } catch { }
    try { $d.Profile   = Get-GuiReadyOsProfile -Static $d.Static } catch { }
    try { $d.DllScan   = Get-GuiReadyDllScan } catch { }
    try { $d.DotNet    = Get-GuiReadyDotNetStatus -Fast } catch { }
    try { $d.Sessions  = Get-GuiReadySessionInfo } catch { }
    try { $d.AutoLogon = Get-GuiReadyAutoLogon } catch { }
    try { $d.Uac       = Get-GuiReadyUac } catch { }

    # Fast FOD verdict: the official DISM query costs ~3.7 s on the first call per process,
    # while the component scan we already have costs ~0.3 s. Infer from the components and
    # mark it as inferred; the exact DISM answer replaces it in stage=full.
    $has = @{}
    foreach ($x in @($d.DllScan)) { if ($x) { $has[[string]$x.Name] = [bool]$x.Exists } }
    $coreOk = [bool]($has['dwm.exe'] -and $has['dcomp.dll'] -and $has['dwrite.dll'])
    $d.Cap = [pscustomobject]@{
        Queried  = $true
        Inferred = $true
        Error    = ''
        Items    = @([pscustomobject]@{
            Name  = 'ServerCore.AppCompatibility'
            State = $(if ($coreOk) { 'Installed' } else { 'NotPresent' })
        })
    }
    Write-ProbeResult -Data $d -Stage 'fast'

    # DISM capability objects do not survive ConvertTo-Json (their Name comes out null),
    # so rebuild them into plain objects before serialising.
    try {
        $capRaw = Get-GuiReadyCapability
        $items  = @()
        foreach ($i in @($capRaw.Items)) {
            $items += [pscustomobject]@{ Name = [string]$i.Name; State = [string]$i.State }
        }
        $d.Cap = [pscustomobject]@{
            Queried  = [bool]$capRaw.Queried
            Inferred = $false
            Error    = [string]$capRaw.Error
            Items    = $items
        }
    } catch { }
    try { $d.Wac = Get-GuiReadyWacStatus -SkipProbe -Lite } catch { }
    Write-ProbeResult -Data $d -Stage 'full'
    exit 0
} catch {
    Write-ProbeResult -Data $d -Stage 'full' -ErrorText $_.Exception.Message
    exit 1
}

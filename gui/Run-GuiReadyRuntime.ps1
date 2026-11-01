# GuiReady runtime runner: list / install / switch / remove / path / probe.
# Same envelope as the other runners: -Mode <m> -OutFile <json> [-ArgsFile <json>]
# Request fields come through the JSON file (Id / Version / Url) so package names
# never end up on a command line.
#
# install can take minutes (download + unzip), the GUI gives it a 30 minute budget.

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$Id = '',
    [string]$Version = '',
    [string]$Url = '',
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-runtime.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Runtime.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $a = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($a.Id)      { $Id      = [string]$a.Id }
        if ($a.Lang)    { $Id      = [string]$a.Lang }
        if ($a.Version) { $Version = [string]$a.Version }
        if ($a.Url)     { $Url     = [string]$a.Url }
    } catch { }
    try { Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue } catch { }
}

function Write-RuntimeResult {
    param($Data, $Items, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode   = $Mode
        Stamp  = (Get-Date).ToString('o')
        Error  = $ErrorText
        Data   = $Data
        Items  = @($Items)
    }
    try {
        $json = $o | ConvertTo-Json -Depth 10 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    switch ($Mode) {
        'list' {
            $st = Get-GuiReadyRuntimeStatus
            Write-RuntimeResult -Data $st -Items @($st.Items)
        }
        'probe' {
            $st = Get-GuiReadyRuntimeStatus -DeepProbe
            Write-RuntimeResult -Data $st -Items @($st.Items)
        }
        'install' {
            if (-not $Id)      { throw '缺少参数：Id' }
            if (-not $Version) { throw '缺少参数：Version' }
            $r = Install-GuiReadyRuntime -Id $Id -Version $Version -Url $Url
            $st = Get-GuiReadyRuntimeStatus
            Write-RuntimeResult -Data ([pscustomobject]@{ Root = $st.Root; Items = @($st.Items) }) -Items @($r)
        }
        'switch' {
            if (-not $Id)      { throw '缺少参数：Id' }
            if (-not $Version) { throw '缺少参数：Version' }
            $r = Set-GuiReadyRuntimeCurrent -Id $Id -Version $Version
            $st = Get-GuiReadyRuntimeStatus
            Write-RuntimeResult -Data ([pscustomobject]@{ Root = $st.Root; Items = @($st.Items) }) -Items @($r)
        }
        'remove' {
            if (-not $Id) { throw '缺少参数：Id' }
            $r = Uninstall-GuiReadyRuntime -Id $Id -Version $Version
            $st = Get-GuiReadyRuntimeStatus
            Write-RuntimeResult -Data ([pscustomobject]@{ Root = $st.Root; Items = @($st.Items) }) -Items @($r)
        }
        'path' {
            $p = Update-GuiReadyRuntimePath
            Write-RuntimeResult -Data ([pscustomobject]@{
                Root    = (Get-GuiReadyRuntimeRoot)
                Changed = [bool]$p.Changed
                Added   = @($p.Added)
                Removed = @($p.Removed)
                Error   = [string]$p.Error
            }) -Items @()
        }
        default {
            Write-RuntimeResult -Data $null -Items @() -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
    exit 0
} catch {
    Write-RuntimeResult -Data $null -Items @() -ErrorText $_.Exception.Message
    exit 1
}

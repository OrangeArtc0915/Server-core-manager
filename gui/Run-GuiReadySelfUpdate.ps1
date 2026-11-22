# GuiReady self-update runner.
#
# Modes:
#   check   -> query GitHub / Gitee main tags, compare with the local install.ps1 $ScmVer
#   install -> download ServerCoreManager.zip (sha256 verified), stage it and hand over
#              to a detached apply script; the caller must exit the GUI afterwards.
#
# Envelope: { Mode, Stamp, Error, ... }. Bridge treats a non-empty Error as failure.

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir = Join-Path $toolRoot 'lib'
$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\self-update.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.SelfUpdate.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$in = $null
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try { $in = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $in = $null }
}
$source = 'auto'
if ($in -and $in.Source) { $source = [string]$in.Source }
$waitPid = 0
if ($in -and $in.WaitPid) { $waitPid = [int]$in.WaitPid }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-UpdateResult {
    param([hashtable]$Fields)
    $o = [ordered]@{
        Mode  = $Mode
        Stamp = (Get-Date).ToString('o')
        Error = ''
    }
    foreach ($k in $Fields.Keys) { $o[$k] = $Fields[$k] }
    try {
        $json = $o | ConvertTo-Json -Depth 6 -Compress
        $tmp = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    if (-not (Get-Command Invoke-GuiReadySelfUpdateCheck -ErrorAction SilentlyContinue)) {
        Write-UpdateResult @{ Error = 'self-update module not loaded' }
        exit 1
    }

    switch ($Mode) {
        'check' {
            $r = Invoke-GuiReadySelfUpdateCheck -Source $source
            if (-not $r.Ok) {
                Write-UpdateResult @{ Error = ('check failed: ' + $r.Error); Current = $r.Current }
                exit 1
            }
            Write-UpdateResult @{
                Current     = $r.Current
                Latest      = $r.Latest
                Tag         = $r.Tag
                Available   = [bool]$r.Available
                Source      = $r.Source
                ZipUrl      = $r.ZipUrl
                ShaUrl      = $r.ShaUrl
                ReleasePage = $r.ReleasePage
            }
            exit 0
        }

        'install' {
            $r = Invoke-GuiReadySelfUpdateCheck -Source $source
            if (-not $r.Ok) {
                Write-UpdateResult @{ Ok = $false; Failure = 'check'; Message = $r.Error }
                exit 1
            }
            if (-not $r.Available) {
                Write-UpdateResult @{ Ok = $false; Failure = 'no-update'; Message = $r.Current }
                exit 0
            }
            if ($waitPid -le 0) { $waitPid = $PID }
            $i = Invoke-GuiReadySelfUpdateInstall -Info $r -WaitPid $waitPid
            Write-UpdateResult @{
                Ok      = [bool]$i.Ok
                Failure = [string]$i.Error
                Message = [string]$i.Message
                Version = [string]$i.Version
            }
            if ($i.Ok) { exit 0 } else { exit 1 }
        }

        default {
            Write-UpdateResult @{ Error = ('unknown mode: ' + $Mode) }
            exit 1
        }
    }
} catch {
    Write-UpdateResult @{ Error = $_.Exception.Message }
    exit 1
}

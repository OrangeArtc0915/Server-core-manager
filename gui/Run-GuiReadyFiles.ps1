# GuiReady files query runner: lists a directory, returns path info or a text preview
# in a separate process (large directories and huge files must never block the UI).
#
# Modes:
#   list -> directory entries
#   info -> single path metadata
#   read -> text preview (binary detection included)
#
# All external values arrive through -ArgsFile as JSON. Command line arguments stay
# literal so no path or keyword ever needs shell quoting.
#
# Keep this file ASCII-only: it ships inside the release zip and must parse under any
# console code page without depending on a BOM.

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-files.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Files.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-FilesResult {
    param($Data, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode   = $Mode
        Stamp  = (Get-Date).ToString('o')
        Error  = $ErrorText
        Data   = $Data
    }
    try {
        $json = $o | ConvertTo-Json -Depth 8 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

$A = @{}
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $raw = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $obj = $raw | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $A[$prop.Name] = $prop.Value }
        }
    } catch {
        Write-FilesResult -Data $null -ErrorText ('args parse failed: ' + $_.Exception.Message)
        exit 1
    }
}

try {
    switch ($Mode) {
        'list' {
            $show = $false
            if ($A.ContainsKey('ShowHidden')) { $show = [bool]$A['ShowHidden'] }
            $data = Get-GuiReadyFileList -Path ([string]$A['Path']) -ShowHidden:$show
            Write-FilesResult -Data $data
            exit 0
        }
        'info' {
            $data = Get-GuiReadyFilePathInfo -Path ([string]$A['Path'])
            Write-FilesResult -Data $data
            exit 0
        }
        'read' {
            $maxKb = 256
            if ($A.ContainsKey('MaxKB')) { $maxKb = [int]$A['MaxKB'] }
            $data = Read-GuiReadyTextFile -Path ([string]$A['Path']) -MaxKB $maxKb
            Write-FilesResult -Data $data
            exit 0
        }
        default {
            Write-FilesResult -Data $null -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
} catch {
    Write-FilesResult -Data $null -ErrorText $_.Exception.Message
    exit 1
}

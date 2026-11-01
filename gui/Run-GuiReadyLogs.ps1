# GuiReady logs query runner: collects event log sources and filtered entries in a
# separate process (Get-WinEvent can take seconds on Server Core, especially Security).
#
# Modes:
#   sources -> event logs plus the tool's own logs\*.log|*.txt files
#   read    -> newest N entries matching level / time range / keyword
#
# All external values arrive through -ArgsFile as JSON.
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

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-logs.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Logs.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-LogsResult {
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
        Write-LogsResult -Data $null -ErrorText ('args parse failed: ' + $_.Exception.Message)
        exit 1
    }
}

try {
    switch ($Mode) {
        'sources' {
            $data = @(Get-GuiReadyLogSourceList)
            Write-LogsResult -Data $data
            exit 0
        }
        'read' {
            $source = 'event:System'
            if ($A.ContainsKey('Source') -and $A['Source']) { $source = [string]$A['Source'] }
            $max = 300
            if ($A.ContainsKey('Max')) { $max = [int]$A['Max'] }
            $level = 'All'
            if ($A.ContainsKey('Level') -and $A['Level']) { $level = [string]$A['Level'] }
            $since = '24h'
            if ($A.ContainsKey('Since') -and $A['Since']) { $since = [string]$A['Since'] }
            $keyword = ''
            if ($A.ContainsKey('Keyword')) { $keyword = [string]$A['Keyword'] }

            $data = Get-GuiReadyLogEntries -Source $source -Max $max -Level $level -Since $since -Keyword $keyword
            Write-LogsResult -Data $data
            exit 0
        }
        'export' {
            # Same filters as 'read', plus Path/Format: the UI can export exactly what it shows.
            $source = 'event:System'
            if ($A.ContainsKey('Source') -and $A['Source']) { $source = [string]$A['Source'] }
            $max = 2000
            if ($A.ContainsKey('Max')) { $max = [int]$A['Max'] }
            $level = 'All'
            if ($A.ContainsKey('Level') -and $A['Level']) { $level = [string]$A['Level'] }
            $since = '24h'
            if ($A.ContainsKey('Since') -and $A['Since']) { $since = [string]$A['Since'] }
            $keyword = ''
            if ($A.ContainsKey('Keyword')) { $keyword = [string]$A['Keyword'] }
            $path = ''
            if ($A.ContainsKey('Path')) { $path = [string]$A['Path'] }
            $format = 'Csv'
            if ($A.ContainsKey('Format') -and $A['Format']) { $format = [string]$A['Format'] }

            $bundle = Get-GuiReadyLogEntries -Source $source -Max $max -Level $level -Since $since -Keyword $keyword
            $r = Export-GuiReadyLog -Entries @($bundle.Entries) -Path $path -Format $format
            Write-LogsResult -Data ([ordered]@{ Path = $r.Path; Rows = $r.Rows; Format = $r.Format })
            exit 0
        }
        default {
            Write-LogsResult -Data $null -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
} catch {
    Write-LogsResult -Data $null -ErrorText $_.Exception.Message
    exit 1
}

# GuiReady catalog query runner: the program compatibility catalog (built-in + user entries)
# in a separate process, because reading two JSON files and resolving rules should never
# touch the UI thread.
#
# Modes:
#   list   -> all catalog entries (built-in first, then the user file)
#   add    -> upsert one user entry (Id / Name / ExeName / Verdict / Type / LaunchArgs / Notes)
#   remove -> delete one user entry by Id (built-in entries cannot be removed)
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

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-catalog.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.PeInspect.ps1', 'GuiReady.Catalog.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-CatalogResult {
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

$A = @{}
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $raw = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $obj = $raw | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $A[$prop.Name] = $prop.Value }
        }
    } catch {
        Write-CatalogResult -Items @() -ErrorText ('args parse failed: ' + $_.Exception.Message)
        exit 1
    }
}

function Get-ArgString {
    param([string]$Name, [string]$Default = '')
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return [string]$A[$Name] }
    return $Default
}

try {
    switch ($Mode) {
        'list' {
            $items = @(Get-GuiReadyCatalog | ForEach-Object {
                [pscustomobject]@{
                    Id              = [string]$_.Id
                    Name            = [string]$_.Name
                    Type            = [string]$_.Type
                    Verdict         = [string]$_.Verdict
                    LaunchArgs      = [string]$_.LaunchArgs
                    RequiredRuntime = (@($_.RequiredRuntime) -join '、')
                    Match           = (@($_.Match | ForEach-Object { [string]$_.pattern }) -join '、')
                    Notes           = [string]$_.Notes
                    VerifiedOn      = [string]$_.VerifiedOn
                    IsUserEntry     = [bool]$_.IsUserEntry
                    Source          = [string]$_.Source
                }
            })
            Write-CatalogResult -Items $items
            exit 0
        }
        'add' {
            $id = Get-ArgString -Name 'Id'
            $name = Get-ArgString -Name 'Name'
            $exe = Get-ArgString -Name 'ExeName'
            if (-not $id) { $id = 'user-' + ([DateTime]::Now.ToString('yyyyMMddHHmmss')) }
            if (-not $name) { Write-CatalogResult -Items @() -ErrorText 'Name is required'; exit 2 }
            if (-not $exe) { Write-CatalogResult -Items @() -ErrorText 'ExeName is required'; exit 2 }

            $verdict = Get-ArgString -Name 'Verdict' -Default '未知'
            if (@('可用', '可用（建议参数）', '不支持', '未知') -notcontains $verdict) { $verdict = '未知' }

            $ok = Add-GuiReadyCatalogEntry -Id $id -Name $name -ExeNamePattern $exe `
                    -Verdict $verdict -Type (Get-ArgString -Name 'Type') `
                    -LaunchArgs (Get-ArgString -Name 'LaunchArgs') -Notes (Get-ArgString -Name 'Notes')
            if (-not $ok) { Write-CatalogResult -Items @() -ErrorText '写入用户档案失败'; exit 1 }
            Write-CatalogResult -Items @([pscustomobject]@{ Id = $id; Name = $name })
            exit 0
        }
        'remove' {
            $id = Get-ArgString -Name 'Id'
            if (-not $id) { Write-CatalogResult -Items @() -ErrorText 'Id is required'; exit 2 }
            $file = $Global:GuiReadyUserCatalogFile
            if (-not (Test-Path -LiteralPath $file)) {
                Write-CatalogResult -Items @() -ErrorText '用户档案里没有可删除的条目'
                exit 1
            }
            $doc = (Get-Content -LiteralPath $file -Raw -Encoding UTF8) | ConvertFrom-Json
            $before = @($doc.entries)
            $keep = @($before | Where-Object { [string]$_.id -ne $id })
            if ($keep.Count -eq $before.Count) {
                Write-CatalogResult -Items @() -ErrorText ('用户档案里没有这个条目：' + $id)
                exit 1
            }
            $out = [ordered]@{
                version     = 1
                description = 'GuiReady 用户档案（你自己的实测结论，优先级高于内置档案）'
                entries     = $keep
            }
            [System.IO.File]::WriteAllText($file, ($out | ConvertTo-Json -Depth 8),
                                           (New-Object System.Text.UTF8Encoding($true)))
            Write-Log ('已从用户档案删除: ' + $id) 'OK'
            Write-CatalogResult -Items @([pscustomobject]@{ Id = $id })
            exit 0
        }
        default {
            Write-CatalogResult -Items @() -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
} catch {
    Write-CatalogResult -Items @() -ErrorText $_.Exception.Message
    exit 1
}

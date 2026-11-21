# 软件清单 / 卸载 / SMB 与 NTFS 权限 runner。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'
$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\software-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Software.ps1', 'GuiReady.Perms.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$A = @{}
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $obj = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) { $A[$prop.Name] = $prop.Value }
    } catch { }
    try { Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue } catch { }
}
function Get-Opt { param([string]$Name, $Default = '') if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return $A[$Name] } return $Default }
function Get-OptInt { param([string]$Name, [int]$Default = 0) $n = 0; if ([int]::TryParse([string](Get-Opt $Name ''), [ref]$n)) { return $n } return $Default }
function Get-OptBool { param([string]$Name, [bool]$Default = $false) $v = Get-Opt $Name $null; if ($null -eq $v) { return $Default }; if ($v -is [bool]) { return $v }; return ([string]$v -match '^(1|true|yes|on)$') }

function Write-SoftResult {
    param($Data, $Items, [string]$ErrorText = '')
    $o = [ordered]@{ Mode = $Mode; Stamp = (Get-Date).ToString('o'); Error = $ErrorText; Data = $Data; Items = @($Items) }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $json = $o | ConvertTo-Json -Depth 10 -Compress
        $tmp = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    switch ($Mode) {
        'list' {
            $items = @(Get-GuiReadySoftwareList)
            Write-SoftResult -Data @{ Count = $items.Count } -Items $items
        }
        'uninstall' {
            $r = Uninstall-GuiReadySoftware -Key ([string](Get-Opt 'Key' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SoftResult -Data $r -Items @()
        }
        'export' {
            $p = Export-GuiReadySoftwareList -Path ([string](Get-Opt 'Path' ''))
            Write-SoftResult -Data @{ Path = $p } -Items @()
        }
        'share-list' {
            $items = @(Get-GuiReadySmbShares)
            Write-SoftResult -Data @{ Count = $items.Count } -Items $items
        }
        'share-grant' {
            Set-GuiReadySmbShareAccess -Name ([string](Get-Opt 'Name' '')) -Account ([string](Get-Opt 'Account' '')) `
                -Access ([string](Get-Opt 'Access' 'Read')) -Action 'Grant' -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SoftResult -Data @{ Ok = $true } -Items @()
        }
        'share-revoke' {
            Set-GuiReadySmbShareAccess -Name ([string](Get-Opt 'Name' '')) -Account ([string](Get-Opt 'Account' '')) `
                -Access ([string](Get-Opt 'Access' 'Read')) -Action 'Revoke' -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SoftResult -Data @{ Ok = $true } -Items @()
        }
        'acl-list' {
            $items = @(Get-GuiReadyNtfsAcl -Path ([string](Get-Opt 'Path' '')))
            Write-SoftResult -Data @{ Count = $items.Count; Path = [string](Get-Opt 'Path' '') } -Items $items
        }
        'acl-set' {
            Set-GuiReadyNtfsAcl -Path ([string](Get-Opt 'Path' '')) -Account ([string](Get-Opt 'Account' '')) `
                -Rights ([string](Get-Opt 'Rights' 'Read')) -Type ([string](Get-Opt 'Type' 'Allow')) `
                -Inherit ([string](Get-Opt 'Inherit' 'ContainerInherit,ObjectInherit')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SoftResult -Data @{ Ok = $true } -Items @()
        }
        'effective' {
            $items = @(Get-GuiReadyEffectivePermissions -Path ([string](Get-Opt 'Path' '')) -Account ([string](Get-Opt 'Account' '')))
            Write-SoftResult -Data @{ Count = $items.Count } -Items $items
        }
        default { Write-SoftResult -ErrorText ('未知模式：' + $Mode) }
    }
} catch {
    Write-Log ('software runner 失败：' + $_.Exception.Message) 'ERROR'
    Write-SoftResult -ErrorText $_.Exception.Message
}

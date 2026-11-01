# GuiReady remote query runner: host inventory, connectivity test and batch result lookup.
# Runs in a separate process so WinRM handshakes can never block the UI thread.
#
# Modes:
#   hosts -> host inventory (no credential material) + TrustedHosts + store path
#   test  -> connect to one / many hosts and return per-host result
#   batch -> read state\remote\batch-<taskId>.json written by the remote-run action
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

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-remote.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Tasks.ps1', 'GuiReady.Hosts.ps1', 'GuiReady.Remote.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-RemoteResult {
    param($Data, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode  = $Mode
        Stamp = (Get-Date).ToString('o')
        Error = $ErrorText
        Data  = $Data
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
        Write-RemoteResult -Data $null -ErrorText ('args parse failed: ' + $_.Exception.Message)
        exit 1
    }
}

function Get-ArgString {
    param([string]$Name, [string]$Default = '')
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return [string]$A[$Name] }
    return $Default
}

function Get-ArgInt {
    param([string]$Name, [int]$Default = 0)
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) {
        try { return [int]$A[$Name] } catch { return $Default }
    }
    return $Default
}

function Get-ArgBool {
    param([string]$Name, [bool]$Default = $false)
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) {
        try { return [bool]$A[$Name] } catch { return $Default }
    }
    return $Default
}

try {
    switch ($Mode) {
        'hosts' {
            $store = Read-GuiReadyHostStore
            $trust = Get-GuiReadyTrustedHostsState
            $data = [ordered]@{
                Items        = @(Get-GuiReadyHostList)
                TrustedHosts = @($trust.Items)
                TrustedError = [string]$trust.Error
                StorePath    = (Get-GuiReadyHostStorePath)
                UpdatedAt    = [string]$store.UpdatedAt
                Now          = (Get-Date).ToString('o')
            }
            Write-RemoteResult -Data $data
            exit 0
        }
        'test' {
            $timeout = Get-ArgInt -Name 'TimeoutSec' -Default 60
            if ($timeout -lt 10) { $timeout = 10 }
            if ($timeout -gt 1800) { $timeout = 1800 }
            $r = Test-GuiReadyHostConnections -HostSpec (Get-ArgString -Name 'Hosts') -TimeoutSec $timeout
            Write-RemoteResult -Data $r
            exit 0
        }
        'batch' {
            $id = Get-ArgString -Name 'TaskId'
            if (-not $id) { Write-RemoteResult -Data $null -ErrorText 'TaskId is required'; exit 2 }
            $b = Read-GuiReadyRemoteBatchFile -TaskId $id
            if (-not $b) {
                Write-RemoteResult -Data $null -ErrorText ('batch result not found: ' + $id)
                exit 1
            }
            Write-RemoteResult -Data $b
            exit 0
        }
        'host-add' {
            $name = Get-ArgString -Name 'Name'
            $addr = Get-ArgString -Name 'Address'
            if (-not $name) { Write-RemoteResult -Data $null -ErrorText 'Name is required'; exit 2 }
            if (-not $addr) { Write-RemoteResult -Data $null -ErrorText 'Address is required'; exit 2 }
            $rec = New-GuiReadyHost -Name $name -Address $addr `
                     -Port (Get-ArgInt -Name 'Port') `
                     -Protocol (Get-ArgString -Name 'Protocol' -Default 'Http') `
                     -Auth (Get-ArgString -Name 'Auth' -Default 'Default') `
                     -Notes (Get-ArgString -Name 'Notes') `
                     -Enabled (-not (Get-ArgBool -Name 'Disabled'))
            Write-RemoteResult -Data ([ordered]@{ Ok = $true; Id = [string]$rec.Id; Name = [string]$rec.Name })
            exit 0
        }
        'host-update' {
            $id = Get-ArgString -Name 'Id'
            if (-not $id) { Write-RemoteResult -Data $null -ErrorText 'Id is required'; exit 2 }
            $enabled = $null
            if ($A.ContainsKey('Enabled')) { $enabled = [bool]$A['Enabled'] }
            $rec = Set-GuiReadyHost -Id $id `
                     -Name (Get-ArgString -Name 'Name') `
                     -Address (Get-ArgString -Name 'Address') `
                     -Port (Get-ArgInt -Name 'Port') `
                     -Protocol (Get-ArgString -Name 'Protocol') `
                     -Auth (Get-ArgString -Name 'Auth') `
                     -Notes (Get-ArgString -Name 'Notes') `
                     -Enabled $enabled
            Write-RemoteResult -Data ([ordered]@{ Ok = $true; Id = [string]$rec.Id; Name = [string]$rec.Name })
            exit 0
        }
        'host-remove' {
            $id = Get-ArgString -Name 'Id'
            if (-not $id) { Write-RemoteResult -Data $null -ErrorText 'Id is required'; exit 2 }
            $rec = Remove-GuiReadyHost -Id $id
            Write-RemoteResult -Data ([ordered]@{ Ok = $true; Id = [string]$rec.Id; Name = [string]$rec.Name })
            exit 0
        }
        'host-cred' {
            # Save a DPAPI-protected credential for one host. The password never leaves this
            # process except into the protected file (args.json is deleted by the caller).
            $id = Get-ArgString -Name 'Id'
            $user = Get-ArgString -Name 'UserName'
            $pass = Get-ArgString -Name 'Password'
            if (-not $id) { Write-RemoteResult -Data $null -ErrorText 'Id is required'; exit 2 }
            $ok = Set-GuiReadyHostCredential -Id $id -UserName $user -Password $pass
            Write-RemoteResult -Data ([ordered]@{ Ok = $true; Saved = [bool]$ok })
            exit 0
        }
        'host-trust-add' {
            $addr = Get-ArgString -Name 'Address'
            if (-not $addr) { Write-RemoteResult -Data $null -ErrorText 'Address is required'; exit 2 }
            $r = Add-GuiReadyTrustedHost -Address $addr
            Write-RemoteResult -Data ([ordered]@{ Ok = $true; Added = @($r.Added); Items = @($r.Items) })
            exit 0
        }
        'host-trust-remove' {
            $addr = Get-ArgString -Name 'Address'
            if (-not $addr) { Write-RemoteResult -Data $null -ErrorText 'Address is required'; exit 2 }
            $r = Remove-GuiReadyTrustedHost -Address $addr
            Write-RemoteResult -Data ([ordered]@{ Ok = $true; Removed = @($r.Removed); Items = @($r.Items) })
            exit 0
        }
        default {
            Write-RemoteResult -Data $null -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
} catch {
    Write-RemoteResult -Data $null -ErrorText $_.Exception.Message
    exit 1
}

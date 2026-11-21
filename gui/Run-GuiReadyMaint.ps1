# 系统维护 runner：证书 / 驱动 / 启动项 / 系统状态备份。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'
$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\maint-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.TasksPlus.ps1', 'GuiReady.Maintenance.ps1')) {
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

function Write-MaintResult {
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

function Get-StartupWithDisabled {
    $items = @(Get-GuiReadyStartupItems)
    $store = @(Get-GuiReadyStartupDisabledItems)
    $ids = @{}
    foreach ($i in $items) { $ids[[string]$i.Id] = $true }
    foreach ($s in $store) {
        $id = [string]$s.Id
        if ($ids.ContainsKey($id)) { continue }
        $type = ''
        $name = ''
        $cmd = ''
        $source = '已禁用'
        switch ([string]$s.Type) {
            'Registry' { $type = 'Registry'; $name = [string]$s.Name; $cmd = [string]$s.Value; $source = '已禁用（注册表）' }
            'File'     { $type = 'File'; $name = Split-Path -Leaf ([string]$s.OriginalPath); $cmd = [string]$s.OriginalPath; $source = '已禁用（启动文件夹）' }
            'Service'  { $type = 'Service'; $name = [string]$s.Name; $source = '已禁用（服务）' }
            default    { $type = 'Task'; $name = Split-Path -Leaf ([string]$s.Name); $source = '已禁用（计划任务）' }
        }
        $items += [pscustomobject]@{ Type = $type; Name = $name; Command = $cmd; Source = $source; Enabled = $false; Id = $id }
    }
    return @($items | Sort-Object Type, Name)
}

try {
    switch ($Mode) {
        'cert-list' {
            $loc = [string](Get-Opt 'Location' 'My')
            $items = @(Get-GuiReadyCertificateList -Location $loc)
            Write-MaintResult -Data @{ Location = $loc; Count = $items.Count } -Items $items
        }
        'cert-expiring' {
            $items = @(Get-GuiReadyCertExpiring -Days (Get-OptInt 'Days' 30))
            Write-MaintResult -Data @{ Days = (Get-OptInt 'Days' 30); Count = $items.Count } -Items $items
        }
        'cert-import' {
            Import-GuiReadyCertificate -Path ([string](Get-Opt 'Path' '')) -Password ([string](Get-Opt 'Password' '')) `
                -Location ([string](Get-Opt 'Location' 'My')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MaintResult -Data @{ Ok = $true } -Items @()
        }
        'cert-export' {
            Export-GuiReadyCertificate -Thumbprint ([string](Get-Opt 'Thumbprint' '')) -Path ([string](Get-Opt 'Path' '')) `
                -Format ([string](Get-Opt 'Format' 'cer')) -Password ([string](Get-Opt 'Password' '')) `
                -Location ([string](Get-Opt 'Location' 'My')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MaintResult -Data @{ Ok = $true; Path = [string](Get-Opt 'Path' '') } -Items @()
        }
        'cert-remove' {
            Remove-GuiReadyCertificate -Thumbprint ([string](Get-Opt 'Thumbprint' '')) `
                -Location ([string](Get-Opt 'Location' 'My')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MaintResult -Data @{ Ok = $true } -Items @()
        }
        'cert-iis' {
            $items = @(Get-GuiReadyIisCertBindings)
            Write-MaintResult -Data @{ Count = $items.Count } -Items $items
        }
        'driver-list' {
            $items = @(Get-GuiReadyDriverList)
            Write-MaintResult -Data @{ Count = $items.Count } -Items $items
        }
        'driver-problems' {
            $items = @(Get-GuiReadyProblemDevices)
            Write-MaintResult -Data @{ Count = $items.Count } -Items $items
        }
        'disk-health' {
            $items = @(Get-GuiReadyDiskHealth)
            Write-MaintResult -Data @{ Count = $items.Count } -Items $items
        }
        'driver-export' {
            $r = Export-GuiReadyDrivers -Path ([string](Get-Opt 'Path' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MaintResult -Data $r -Items @()
        }
        'driver-import' {
            $r = Import-GuiReadyDrivers -Path ([string](Get-Opt 'Path' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MaintResult -Data $r -Items @()
        }
        'startup-list' {
            $items = @(Get-StartupWithDisabled)
            Write-MaintResult -Data @{ Count = $items.Count } -Items $items
        }
        'startup-toggle' {
            Set-GuiReadyStartupItem -Id ([string](Get-Opt 'Id' '')) -Enabled (Get-OptBool 'Enabled' $true) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MaintResult -Data @{ Id = [string](Get-Opt 'Id' ''); Enabled = (Get-OptBool 'Enabled' $true) } -Items @()
        }
        'backup-list' {
            $items = @(Get-GuiReadySysBackupList)
            Write-MaintResult -Data @{ Count = $items.Count; Root = (Get-GuiReadySysBackupRoot) } -Items $items
        }
        'backup-create' {
            $r = New-GuiReadySysBackup -OutDir ([string](Get-Opt 'OutDir' '')) `
                -WithDrivers:(Get-OptBool 'WithDrivers' $false) -FullRegistry:(Get-OptBool 'FullRegistry' $false) `
                -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MaintResult -Data $r -Items @()
        }
        'backup-share' {
            $r = Copy-GuiReadySysBackupToShare -File ([string](Get-Opt 'File' '')) -Share ([string](Get-Opt 'Share' '')) `
                -Keep (Get-OptInt 'Keep' 5) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MaintResult -Data $r -Items @()
        }
        'backup-task-install' {
            $t = Install-GuiReadySysBackupTask -Share ([string](Get-Opt 'Share' '')) -Keep (Get-OptInt 'Keep' 5) `
                -WithDrivers:(Get-OptBool 'WithDrivers' $false) -FullRegistry:(Get-OptBool 'FullRegistry' $false) `
                -Time ([string](Get-Opt 'Time' '03:00')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-MaintResult -Data $t -Items @()
        }
        'backup-auto' {
            $r = Invoke-GuiReadySysBackupAuto
            Write-MaintResult -Data $r -Items @()
        }
        'task-status' {
            Write-MaintResult -Data @{ Backup = (Get-GuiReadyPlusTaskState 'ScmPlus-SysBackup') } -Items @()
        }
        default { Write-MaintResult -ErrorText ('未知模式：' + $Mode) }
    }
} catch {
    Write-Log ('maint runner 失败：' + $_.Exception.Message) 'ERROR'
    Write-MaintResult -ErrorText $_.Exception.Message
}

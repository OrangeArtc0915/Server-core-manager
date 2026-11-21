# 系统维护：证书、驱动与硬件健康、启动项、系统状态备份。

function Get-GuiReadyMaintRoot {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'state\maint'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# ---------------------------------------------------------------- 证书
function Get-GuiReadyCertificateList {
    param([ValidateSet('My', 'Root', 'CA', 'TrustedPeople', 'TrustedRootCA')][string]$Location = 'My')
    $loc = if ($Location -eq 'TrustedRootCA') { 'Root' } else { $Location }
    $path = 'Cert:\LocalMachine\' + $loc
    $rows = @()
    try {
        foreach ($c in @(Get-ChildItem -Path $path -ErrorAction Stop)) {
            $days = 0
            try { $days = [int][Math]::Floor(($c.NotAfter - (Get-Date)).TotalDays) } catch { }
            $rows += [pscustomobject]@{
                Subject      = [string]$c.Subject
                Issuer       = [string]$c.Issuer
                Thumbprint   = [string]$c.Thumbprint
                NotBefore    = $c.NotBefore.ToString('yyyy-MM-dd')
                NotAfter     = $c.NotAfter.ToString('yyyy-MM-dd')
                DaysLeft     = $days
                HasPrivateKey = [bool]$c.HasPrivateKey
                FriendlyName = [string]$c.FriendlyName
                Location     = $loc
                Expired      = ($days -lt 0)
                Expiring     = ($days -ge 0 -and $days -le 30)
            }
        }
    } catch { Write-Log ('读取证书失败：' + $_.Exception.Message) 'WARN' }
    return @($rows | Sort-Object NotAfter)
}

function Import-GuiReadyCertificate {
    param([Parameter(Mandatory = $true)][string]$Path,
          [string]$Password = '',
          [ValidateSet('My', 'Root', 'CA', 'TrustedPeople')][string]$Location = 'My',
          [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('证书文件不存在：' + $Path) }
    if ($DryRun) { Write-Log ('[预览] 将导入证书 ' + $Path + ' → LocalMachine\' + $Location) 'DRY'; return }
    $store = 'Cert:\LocalMachine\' + $Location
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.pfx' -or $ext -eq '.p12') {
        $sec = ConvertTo-SecureString -String $Password -AsPlainText -Force
        Import-PfxCertificate -FilePath $Path -CertStoreLocation $store -Password $sec -ErrorAction Stop | Out-Null
    } else {
        Import-Certificate -FilePath $Path -CertStoreLocation $store -ErrorAction Stop | Out-Null
    }
    Write-Log ('已导入证书：' + $Path + ' → ' + $store) 'OK'
}

function Export-GuiReadyCertificate {
    param([Parameter(Mandatory = $true)][string]$Thumbprint,
          [Parameter(Mandatory = $true)][string]$Path,
          [ValidateSet('pfx', 'cer')][string]$Format = 'cer',
          [string]$Password = '',
          [ValidateSet('My', 'Root', 'CA', 'TrustedPeople')][string]$Location = 'My',
          [switch]$DryRun)
    $certPath = 'Cert:\LocalMachine\' + $Location + '\' + $Thumbprint
    if (-not (Test-Path -LiteralPath $certPath)) { throw ('找不到证书：' + $Thumbprint) }
    if ($DryRun) { Write-Log ('[预览] 将导出证书 ' + $Thumbprint + ' → ' + $Path) 'DRY'; return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($Format -eq 'pfx') {
        $sec = ConvertTo-SecureString -String $Password -AsPlainText -Force
        Export-PfxCertificate -Cert $certPath -FilePath $Path -Password $sec -ErrorAction Stop | Out-Null
    } else {
        Export-Certificate -Cert $certPath -FilePath $Path -Type CERT -ErrorAction Stop | Out-Null
    }
    Write-Log ('已导出证书：' + $Path) 'OK'
}

function Remove-GuiReadyCertificate {
    param([Parameter(Mandatory = $true)][string]$Thumbprint,
          [ValidateSet('My', 'Root', 'CA', 'TrustedPeople')][string]$Location = 'My',
          [switch]$DryRun)
    $certPath = 'Cert:\LocalMachine\' + $Location + '\' + $Thumbprint
    if (-not (Test-Path -LiteralPath $certPath)) { throw ('找不到证书：' + $Thumbprint) }
    if ($DryRun) { Write-Log ('[预览] 将删除证书 ' + $Thumbprint) 'DRY'; return }
    Remove-Item -LiteralPath $certPath -Force -ErrorAction Stop
    Write-Log ('已删除证书 ' + $Thumbprint) 'OK'
}

function Get-GuiReadyCertExpiring {
    param([int]$Days = 30)
    $rows = @()
    foreach ($loc in @('My', 'Root', 'CA', 'TrustedPeople')) {
        foreach ($c in @(Get-GuiReadyCertificateList -Location $loc)) {
            if ($c.DaysLeft -le $Days) { $rows += $c }
        }
    }
    return @($rows | Sort-Object DaysLeft)
}

function Get-GuiReadyIisCertBindings {
    $rows = @()
    try {
        Import-Module WebAdministration -ErrorAction Stop
        foreach ($b in @(Get-WebBinding -ErrorAction Stop)) {
            $hash = ''
            try { $hash = [string]$b.certificateHash } catch { }
            $rows += [pscustomobject]@{
                Site   = [string]$b.ItemXPath.Split('/')[-2]
                Binding = [string]$b.bindingInformation
                Protocol = [string]$b.protocol
                CertHash = $hash
                CertName = $(if ($hash) { (Get-GuiReadyCertificateList -Location 'My' | Where-Object { $_.Thumbprint -eq $hash } | Select-Object -First 1).Subject } else { '' })
            }
        }
    } catch {
        Write-Log ('IIS 未安装或 WebAdministration 不可用：' + $_.Exception.Message) 'INFO'
    }
    return @($rows)
}

# ---------------------------------------------------------------- 驱动与硬件
function Get-GuiReadyDriverList {
    $rows = @()
    try {
        $devices = @{}
        foreach ($p in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)) {
            $devices[[string]$p.DeviceID] = $p
        }
        foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Sort-Object DeviceName)) {
            $p = $devices[[string]$d.DeviceID]
            $code = if ($p) { [int]$p.ConfigManagerErrorCode } else { 0 }
            $status = if ($code -eq 0) { 'OK' } else { '问题代码 ' + $code }
            $rows += [pscustomobject]@{
                Device    = [string]$d.DeviceName
                Class     = [string]$d.DeviceClass
                Version   = [string]$d.DriverVersion
                Date      = $(if ($d.DriverDate) { ([datetime]$d.DriverDate).ToString('yyyy-MM-dd') } else { '' })
                Provider  = [string]$d.DriverProviderName
                Inf       = [string]$d.InfName
                Signed    = [bool]$d.IsSigned
                Status    = $status
                DeviceId  = [string]$d.DeviceID
            }
        }
    } catch { Write-Log ('读取驱动失败：' + $_.Exception.Message) 'WARN' }
    return @($rows)
}

function Get-GuiReadyProblemDevices {
    $rows = @()
    try {
        foreach ($p in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -ne 0 })) {
            $rows += [pscustomobject]@{
                Device = [string]$p.Name
                Class  = [string]$p.PNPClass
                Code   = [int]$p.ConfigManagerErrorCode
                Status = [string]$p.Status
                DeviceId = [string]$p.DeviceID
            }
        }
    } catch { }
    return @($rows)
}

function Get-GuiReadyDiskHealth {
    $rows = @()
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
        foreach ($d in $disks) {
            $temp = ''; $wear = ''; $hours = ''; $readErr = ''
            try {
                $c = Get-StorageReliabilityCounter -PhysicalDisk $d -ErrorAction Stop
                $temp = $c.Temperature; $wear = $c.Wear; $hours = $c.PowerOnHours; $readErr = $c.ReadErrorsTotal
            } catch { }
            $rows += [pscustomobject]@{
                Disk = [string]$d.FriendlyName
                Media = [string]$d.MediaType
                SizeGB = [Math]::Round([double]$d.Size / 1GB, 1)
                Health = [string]$d.HealthStatus
                Operational = [string]$d.OperationalStatus
                Temperature = $temp
                Wear = $wear
                PowerOnHours = $hours
                ReadErrors = $readErr
            }
        }
    } catch {
        try {
            foreach ($d in @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)) {
                $rows += [pscustomobject]@{
                    Disk = [string]$d.Model; Media = [string]$d.MediaType
                    SizeGB = [Math]::Round([double]$d.Size / 1GB, 1)
                    Health = [string]$d.Status; Operational = ''; Temperature = ''; Wear = ''; PowerOnHours = ''; ReadErrors = ''
                }
            }
        } catch { }
    }
    return @($rows)
}

function Export-GuiReadyDrivers {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$DryRun)
    if ($DryRun) { Write-Log ('[预览] 将导出驱动到 ' + $Path) 'DRY'; return }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $out = & pnputil.exe /export-driver * $Path 2>&1
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
    Write-Log ('驱动已导出到 {0}（{1} 个 inf）' -f $Path, $files) 'OK'
    if ($out) { Write-Log (($out | Select-Object -Last 3) -join ' ') 'INFO' }
    return [pscustomobject]@{ Path = $Path; InfCount = $files }
}

function Import-GuiReadyDrivers {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('驱动目录不存在：' + $Path) }
    if ($DryRun) { Write-Log ('[预览] 将从 ' + $Path + ' 导入驱动') 'DRY'; return }
    $out = & pnputil.exe /add-driver (Join-Path $Path '*.inf') /subdirs /install 2>&1
    Write-Log (($out | Select-Object -Last 5) -join ' ') 'OK'
    return [pscustomobject]@{ Path = $Path; Output = (($out | Out-String).Trim()) }
}

# ---------------------------------------------------------------- 启动项
function Get-GuiReadyStartupStorePath { return (Join-Path (Get-GuiReadyMaintRoot) 'startup-disabled.json') }
function Get-GuiReadyStartupStore {
    $file = Get-GuiReadyStartupStorePath
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try { return @(Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @() }
}
function Save-GuiReadyStartupStore { param($Items) @($Items) | ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Get-GuiReadyStartupStorePath) -Encoding UTF8 }

function Get-GuiReadyStartupItems {
    $rows = @()
    $regKeys = @(
        @{ Hive = 'HKLM'; Key = 'Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'HKLM Run' },
        @{ Hive = 'HKLM'; Key = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'; Name = 'HKLM RunOnce' },
        @{ Hive = 'HKLM'; Key = 'Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run'; Name = 'HKLM Run (32)' },
        @{ Hive = 'HKLM'; Key = 'Software\Wow6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Name = 'HKLM RunOnce (32)' },
        @{ Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'HKCU Run' },
        @{ Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'; Name = 'HKCU RunOnce' }
    )
    foreach ($k in $regKeys) {
        $ps = $k.Hive + ':\' + $k.Key
        if (-not (Test-Path -LiteralPath $ps)) { continue }
        try {
            $props = Get-ItemProperty -LiteralPath $ps -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -match '^PS') { continue }
                $rows += [pscustomobject]@{
                    Type = 'Registry'; Name = [string]$p.Name; Command = [string]$p.Value
                    Source = [string]$k.Name; Enabled = $true
                    Id = 'reg::' + $k.Hive + '::' + $k.Key + '::' + $p.Name
                }
            }
        } catch { }
    }

    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup'); Name = '用户启动文件夹' },
        @{ Path = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'); Name = '公共启动文件夹' }
    )
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path -LiteralPath $f.Path)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue)) {
            $rows += [pscustomobject]@{
                Type = 'File'; Name = $file.Name; Command = $file.FullName
                Source = [string]$f.Name; Enabled = $true
                Id = 'file::' + $file.FullName
            }
        }
    }

    try {
        foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.StartMode -in @('Auto', 'Automatic', 'Disabled') })) {
            $rows += [pscustomobject]@{
                Type = 'Service'; Name = [string]$s.Name; Command = [string]$s.PathName
                Source = '服务（' + [string]$s.StartMode + '）'; Enabled = ([string]$s.StartMode -ne 'Disabled')
                Id = 'svc::' + [string]$s.Name
            }
        }
    } catch { }

    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            if ([string]$t.TaskPath -like '\Microsoft\*') { continue }
            $has = $false
            foreach ($tr in @($t.Triggers)) {
                if ([string]$tr.CimClass.CimClassName -match 'LogonTrigger|BootTrigger') { $has = $true; break }
            }
            if (-not $has) { continue }
            $rows += [pscustomobject]@{
                Type = 'Task'; Name = [string]$t.TaskName; Command = [string]$t.TaskPath
                Source = '计划任务'; Enabled = ([string]$t.State -ne 'Disabled')
                Id = 'task::' + [string]$t.TaskPath + [string]$t.TaskName
            }
        }
    } catch { }

    return @($rows | Sort-Object Type, Name)
}

function Set-GuiReadyStartupItem {
    param([Parameter(Mandatory = $true)][string]$Id, [bool]$Enabled = $true, [switch]$DryRun)
    $store = @(Get-GuiReadyStartupStore)
    $parts = $Id -split '::'
    $type = $parts[0]
    if ($type -eq 'reg') {
        $hive = $parts[1]; $key = $parts[2]; $name = ($parts[3..($parts.Count - 1)] -join '::')
        $ps = $hive + ':\' + $key
        if ($Enabled) {
            $entry = $store | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1
            if (-not $entry) { throw ('没有找到被禁用的启动项：' + $Id) }
            if ($DryRun) { Write-Log ('[预览] 恢复注册表启动项 ' + $name) 'DRY'; return }
            if (-not (Test-Path -LiteralPath $ps)) { New-Item -Path $ps -Force | Out-Null }
            Set-ItemProperty -LiteralPath $ps -Name $name -Value ([string]$entry.Value) -Force
            $store = @($store | Where-Object { [string]$_.Id -ne $Id })
        } else {
            if ($DryRun) { Write-Log ('[预览] 禁用注册表启动项 ' + $name) 'DRY'; return }
            $value = (Get-ItemProperty -LiteralPath $ps -Name $name -ErrorAction Stop).$name
            $store += [pscustomobject]@{ Id = $Id; Type = 'Registry'; Hive = $hive; Key = $key; Name = $name; Value = [string]$value }
            Remove-ItemProperty -LiteralPath $ps -Name $name -Force
        }
        Save-GuiReadyStartupStore $store
        Write-Log ('注册表启动项 {0} → {1}' -f $name, $(if ($Enabled) { '启用' } else { '禁用' })) 'OK'
        return
    }
    if ($type -eq 'file') {
        $path = ($parts[1..($parts.Count - 1)] -join '::')
        if ($Enabled) {
            $entry = $store | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1
            if (-not $entry) { throw ('没有找到被禁用的启动项：' + $Id) }
            if ($DryRun) { Write-Log ('[预览] 恢复启动文件 ' + $path) 'DRY'; return }
            $targetDir = Split-Path -Parent ([string]$entry.OriginalPath)
            if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            Move-Item -LiteralPath ([string]$entry.StoredPath) -Destination ([string]$entry.OriginalPath) -Force
            $store = @($store | Where-Object { [string]$_.Id -ne $Id })
        } else {
            if ($DryRun) { Write-Log ('[预览] 禁用启动文件 ' + $path) 'DRY'; return }
            $dir = Join-Path (Join-Path (Get-GuiReadyMaintRoot) 'startup-disabled') ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $stored = Join-Path $dir (Split-Path -Leaf $path)
            Move-Item -LiteralPath $path -Destination $stored -Force
            $store += [pscustomobject]@{ Id = $Id; Type = 'File'; OriginalPath = $path; StoredPath = $stored }
        }
        Save-GuiReadyStartupStore $store
        Write-Log ('启动文件 {0} → {1}' -f $path, $(if ($Enabled) { '启用' } else { '禁用' })) 'OK'
        return
    }
    if ($type -eq 'svc') {
        $name = ($parts[1..($parts.Count - 1)] -join '::')
        if ($DryRun) { Write-Log ('[预览] 服务启动类型 ' + $name + ' → ' + $(if ($Enabled) { 'Auto' } else { 'Disabled' })) 'DRY'; return }
        if ($Enabled) {
            $entry = $store | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1
            $mode = if ($entry) { [string]$entry.PreviousMode } else { 'Automatic' }
            Set-Service -Name $name -StartupType $mode -ErrorAction Stop
            $store = @($store | Where-Object { [string]$_.Id -ne $Id })
        } else {
            $svc = Get-CimInstance Win32_Service -Filter ("Name='" + $name.Replace("'", "''") + "'") -ErrorAction Stop
            $store += [pscustomobject]@{ Id = $Id; Type = 'Service'; Name = $name; PreviousMode = [string]$svc.StartMode }
            Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
        }
        Save-GuiReadyStartupStore $store
        Write-Log ('服务 {0} → {1}' -f $name, $(if ($Enabled) { '启用' } else { '禁用' })) 'OK'
        return
    }
    if ($type -eq 'task') {
        $full = ($parts[1..($parts.Count - 1)] -join '::')
        $ix = $full.LastIndexOf('\')
        $taskPath = if ($ix -ge 0) { $full.Substring(0, $ix + 1) } else { '\' }
        $taskName = if ($ix -ge 0) { $full.Substring($ix + 1) } else { $full }
        if ($DryRun) { Write-Log ('[预览] 计划任务 ' + $full + ' → ' + $(if ($Enabled) { '启用' } else { '禁用' })) 'DRY'; return }
        if ($Enabled) { Enable-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop | Out-Null }
        Write-Log ('计划任务 {0} → {1}' -f $full, $(if ($Enabled) { '启用' } else { '禁用' })) 'OK'
        return
    }
    throw ('未知启动项类型：' + $type)
}

function Get-GuiReadyStartupDisabledItems { return @(Get-GuiReadyStartupStore) }

# ---------------------------------------------------------------- 备份
function Get-GuiReadySysBackupRoot {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'backup\sysbackup'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-GuiReadySysBackupConfigPath { return (Join-Path (Get-GuiReadyMaintRoot) 'sysbackup.json') }

function Get-GuiReadySysBackupConfig {
    $file = Get-GuiReadySysBackupConfigPath
    if (Test-Path -LiteralPath $file) {
        try { return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ Share = ''; Keep = 5; WithDrivers = $false; FullRegistry = $false }
}

function Get-GuiReadyInstalledSoftware {
    $rows = @()
    $keys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        try {
            foreach ($p in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
                if (-not $p.DisplayName) { continue }
                $rows += [pscustomobject]@{
                    Name = [string]$p.DisplayName; Version = [string]$p.DisplayVersion
                    Publisher = [string]$p.Publisher; InstallDate = [string]$p.InstallDate
                }
            }
        } catch { }
    }
    return @($rows | Sort-Object Name)
}

function New-GuiReadySysBackup {
    param([string]$OutDir = '', [switch]$WithDrivers, [switch]$FullRegistry, [switch]$DryRun)
    if (-not $OutDir) { $OutDir = Get-GuiReadySysBackupRoot }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $work = Join-Path $env:TEMP ('scm-sysbackup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $parts = New-Object System.Collections.ArrayList
    try {
        foreach ($sub in @('registry', 'drivers', 'certs', 'tasks', 'firewall', 'inventory')) {
            New-Item -ItemType Directory -Path (Join-Path $work $sub) -Force | Out-Null
        }

        if (-not $DryRun) {
            if ($FullRegistry) {
                $regKeys = @('HKLM\SYSTEM', 'HKLM\SOFTWARE', 'HKLM\SAM', 'HKLM\SECURITY', 'HKCU')
            } else {
                # 默认只导出与配置/服务/启动项相关的分支，避免把整份 SOFTWARE（数百 MB）打进去
                $regKeys = @(
                    'HKLM\SYSTEM\CurrentControlSet\Services',
                    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion',
                    'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion',
                    'HKCU\Software\Microsoft\Windows\CurrentVersion'
                )
            }
            foreach ($k in $regKeys) {
                $safe = ($k -replace '\\', '_')
                $file = Join-Path (Join-Path $work 'registry') ($safe + '.reg')
                try {
                    $null = & reg.exe export $k $file /y 2>&1
                    if (Test-Path -LiteralPath $file) { [void]$parts.Add('registry/' + $safe + '.reg') }
                } catch { }
            }

            if ($WithDrivers) {
                try {
                    $drv = Join-Path $work 'drivers'
                    $null = & pnputil.exe /export-driver * $drv 2>&1
                    $inf = @(Get-ChildItem -LiteralPath $drv -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
                    [void]$parts.Add('drivers（' + $inf + ' 个 inf）')
                } catch { }
            } else {
                [void]$parts.Add('drivers（未包含，勾选「包含驱动」后导出）')
            }

            try {
                $certDir = Join-Path $work 'certs'
                $n = 0
                foreach ($c in @(Get-GuiReadyCertificateList -Location 'My')) {
                    try {
                        Export-Certificate -Cert ('Cert:\LocalMachine\My\' + $c.Thumbprint) -FilePath (Join-Path $certDir ($c.Thumbprint + '.cer')) -Type CERT -ErrorAction Stop | Out-Null
                        $n++
                    } catch { }
                }
                [void]$parts.Add('certs（' + $n + ' 个证书）')
            } catch { }

            try {
                $taskDir = Join-Path $work 'tasks'
                $n = 0
                foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { [string]$_.TaskPath -notlike '\Microsoft\*' })) {
                    try {
                        $xml = Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
                        $safe = (([string]$t.TaskPath + [string]$t.TaskName) -replace '[\\/:*?"<>|]', '_')
                        $xml | Out-File -LiteralPath (Join-Path $taskDir ($safe + '.xml')) -Encoding UTF8
                        $n++
                    } catch { }
                }
                [void]$parts.Add('tasks（' + $n + ' 个计划任务）')
            } catch { }

            try {
                $null = & netsh.exe advfirewall export (Join-Path $work 'firewall\firewall.wfw') 2>&1
                [void]$parts.Add('firewall/firewall.wfw')
            } catch { }

            try {
                $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                @{
                    Time = (Get-Date).ToString('o')
                    Computer = $env:COMPUTERNAME
                    OS = if ($os) { [string]$os.Caption } else { '' }
                    Version = if ($os) { [string]$os.Version } else { '' }
                    IP = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { $_.IPAddress })
                    Software = @(Get-GuiReadyInstalledSoftware)
                } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $work 'inventory\inventory.json') -Encoding UTF8
                [void]$parts.Add('inventory/inventory.json')
            } catch { }
        }

        $zip = Join-Path $OutDir ('scm-sysbackup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
        if ($DryRun) {
            Write-Log ('[预览] 将创建系统状态备份 ' + $zip) 'DRY'
            return [pscustomobject]@{ File = $zip; DryRun = $true; Parts = @($parts) }
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($work, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
        $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        $size = [Math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 2)
        Write-Log ('系统状态备份已生成：{0}（{1} MB）' -f $zip, $size) 'OK'
        return [pscustomobject]@{ File = $zip; SizeMB = $size; Sha256 = $sha; Parts = @($parts) }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Copy-GuiReadySysBackupToShare {
    param([Parameter(Mandatory = $true)][string]$File,
          [Parameter(Mandatory = $true)][string]$Share,
          [int]$Keep = 5,
          [switch]$DryRun)
    if (-not (Test-Path -LiteralPath $File)) { throw ('备份文件不存在：' + $File) }
    if (-not (Test-Path -LiteralPath $Share)) { throw ('共享目录不可访问：' + $Share) }
    $name = Split-Path -Leaf $File
    $dest = Join-Path $Share $name
    if ($DryRun) { Write-Log ('[预览] 将复制 ' + $File + ' → ' + $dest) 'DRY'; return }
    Copy-Item -LiteralPath $File -Destination $dest -Force
    $src = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLower()
    $dst = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()
    if ($src -ne $dst) { throw '复制后 SHA256 不一致，备份可能损坏。' }
    $old = @(Get-ChildItem -LiteralPath $Share -Filter 'scm-sysbackup-*.zip' -File | Sort-Object LastWriteTime -Descending)
    $remove = @($old | Select-Object -Skip ([Math]::Max(1, $Keep)))
    foreach ($f in $remove) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    Write-Log ('已复制到共享：{0}（保留 {1} 份，清理 {2} 份）' -f $dest, $Keep, $remove.Count) 'OK'
    return [pscustomobject]@{ Dest = $dest; Sha256 = $dst; Removed = $remove.Count }
}

function Set-GuiReadySysBackupConfig {
    param([string]$Share = '', [int]$Keep = 5, [bool]$WithDrivers = $false, [bool]$FullRegistry = $false)
    [pscustomobject]@{ Share = $Share; Keep = $Keep; WithDrivers = $WithDrivers; FullRegistry = $FullRegistry } |
        ConvertTo-Json | Out-File -LiteralPath (Get-GuiReadySysBackupConfigPath) -Encoding UTF8
}

function Install-GuiReadySysBackupTask {
    param([string]$Share = '', [int]$Keep = 5, [bool]$WithDrivers = $false, [bool]$FullRegistry = $false,
          [string]$Time = '03:00', [switch]$DryRun)
    if (-not $DryRun) { Set-GuiReadySysBackupConfig -Share $Share -Keep $Keep -WithDrivers $WithDrivers -FullRegistry $FullRegistry }
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Register-GuiReadyPlusTask -TaskName 'ScmPlus-SysBackup' `
        -Runner (Join-Path $root 'gui\Run-GuiReadyMaint.ps1') -Mode 'backup-auto' `
        -Schedule 'daily' -Time $Time -LimitMinutes 60 -DryRun:$DryRun)
}

function Invoke-GuiReadySysBackupAuto {
    $cfg = Get-GuiReadySysBackupConfig
    $b = New-GuiReadySysBackup -WithDrivers:([bool]$cfg.WithDrivers) -FullRegistry:([bool]$cfg.FullRegistry)
    if ($cfg.Share) {
        try { Copy-GuiReadySysBackupToShare -File $b.File -Share ([string]$cfg.Share) -Keep ([int]$cfg.Keep) | Out-Null } catch { Write-Log ('复制到共享失败：' + $_.Exception.Message) 'WARN' }
    }
    return $b
}

function Get-GuiReadySysBackupList {
    $rows = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-GuiReadySysBackupRoot) -Filter '*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $rows += [pscustomobject]@{
            File = $f.Name
            Time = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            SizeMB = [Math]::Round($f.Length / 1MB, 2)
            Path = $f.FullName
        }
    }
    return @($rows)
}

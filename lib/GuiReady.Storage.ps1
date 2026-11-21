# GuiReady 存储与备份：磁盘 / 卷 / 临时空间 / 卷影副本 / Windows Server Backup。
#
# 原则：破坏性操作（格式化、初始化磁盘）一律先 DryRun，界面里还要二次确认；
# 只做「扩展卷」这种不丢数据的操作时也先回读容量再动手。

function Get-GuiReadyStorageStatus {
    $disks = @()
    $volumes = @()
    try {
        foreach ($d in @(Get-Disk -ErrorAction Stop | Sort-Object Number)) {
            $disks += [pscustomobject]@{
                Number      = [int]$d.Number
                FriendlyName = [string]$d.FriendlyName
                SizeGB      = [Math]::Round([double]$d.Size / 1GB, 1)
                PartitionStyle = [string]$d.PartitionStyle
                OperationalStatus = (@($d.OperationalStatus) -join ',')
                HealthStatus = [string]$d.HealthStatus
                BusType     = [string]$d.BusType
                IsBoot      = [bool]$d.IsBoot
                IsSystem    = [bool]$d.IsSystem
            }
        }
    } catch {
        Write-Log ('读取磁盘失败：' + $_.Exception.Message) 'WARN'
    }

    try {
        foreach ($v in @(Get-Volume -ErrorAction Stop | Sort-Object DriveLetter)) {
            $sizeGB = 0; $freeGB = 0
            try { $sizeGB = [Math]::Round([double]$v.Size / 1GB, 1) } catch { }
            try { $freeGB = [Math]::Round([double]$v.SizeRemaining / 1GB, 1) } catch { }
            $pct = if ($sizeGB -gt 0) { [Math]::Round($freeGB * 100 / $sizeGB) } else { 0 }
            $volumes += [pscustomobject]@{
                DriveLetter = [string]$v.DriveLetter
                Label       = [string]$v.FileSystemLabel
                FileSystem  = [string]$v.FileSystem
                DriveType   = [string]$v.DriveType
                SizeGB      = $sizeGB
                FreeGB      = $freeGB
                FreePercent = $pct
                Health      = [string]$v.HealthStatus
            }
        }
    } catch {
        Write-Log ('读取卷失败：' + $_.Exception.Message) 'WARN'
    }

    $snapCount = 0
    try { $snapCount = @(Get-CimInstance Win32_ShadowCopy -ErrorAction Stop).Count } catch { }

    return [pscustomobject]@{
        Disks     = $disks
        Volumes   = $volumes
        Snapshots = $snapCount
        Computer  = $env:COMPUTERNAME
    }
}

function Set-GuiReadyVolumeAction {
    param([Parameter(Mandatory = $true)][ValidateSet('extend', 'format', 'initialize')][string]$Action,
          [string]$DriveLetter = '',
          [int]$DiskNumber = -1,
          [string]$FileSystem = 'NTFS',
          [string]$Label = '',
          [switch]$DryRun)
    Assert-Administrator | Out-Null

    switch ($Action) {
        'extend' {
            $letter = $DriveLetter.TrimEnd(':').ToUpper()
            if (-not $letter) { throw '扩展卷需要盘符（例如 D）' }
            $v = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            if (-not $v) { throw ('找不到卷：' + $letter) }
            $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $part) { throw ('找不到分区：' + $letter) }
            $size = 0
            try { $size = (Get-PartitionSupportedSize -DriveLetter $letter -ErrorAction Stop).SizeMax } catch { }
            if ($size -le $part.Size) { throw '这个卷已经用满磁盘，没有可扩展的空间' }
            if ($DryRun) {
                Write-Log ('[预览] 将把 {0}: 从 {1} GB 扩展到 {2} GB' -f $letter, [Math]::Round($part.Size / 1GB, 1), [Math]::Round($size / 1GB, 1)) 'DRY'
                return
            }
            Resize-Partition -DriveLetter $letter -Size $size -ErrorAction Stop
            Start-Sleep -Milliseconds 600
            $now = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            Write-Log ('{0}: 已扩展，现在 {1} GB（可用 {2} GB）' -f $letter, [Math]::Round($now.Size / 1GB, 1), [Math]::Round($now.SizeRemaining / 1GB, 1)) 'OK'
        }
        'format' {
            $letter = $DriveLetter.TrimEnd(':').ToUpper()
            if (-not $letter) { throw '格式化需要盘符（例如 D）' }
            $v = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            if (-not $v) { throw ('找不到卷：' + $letter) }
            if ($DryRun) {
                Write-Log ('[预览] 将格式化 {0}:（{1} GB）为 {2}{3} —— 卷上的数据会全部丢失' -f $letter, [Math]::Round($v.Size / 1GB, 1), $FileSystem, $(if ($Label) { '，卷标 ' + $Label } else { '' })) 'DRY'
                return
            }
            $p = @{ DriveLetter = $letter; FileSystem = $FileSystem; Confirm = $false }
            if ($Label) { $p['NewFileSystemLabel'] = $Label }
            Format-Volume @p -ErrorAction Stop | Out-Null
            Write-Log ('已格式化 {0}: 为 {1}' -f $letter, $FileSystem) 'OK'
        }
        'initialize' {
            if ($DiskNumber -lt 0) { throw '初始化磁盘需要磁盘编号（在「磁盘」列表里看）' }
            $d = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
            if (-not $d) { throw ('找不到磁盘 ' + $DiskNumber) }
            if ([string]$d.PartitionStyle -ne 'RAW') { throw ('磁盘 {0} 已经是 {1}，不需要初始化' -f $DiskNumber, $d.PartitionStyle) }
            if ($DryRun) { Write-Log ('[预览] 将把磁盘 {0}（{1}，{2} GB）初始化为 GPT' -f $DiskNumber, $d.FriendlyName, [Math]::Round($d.Size / 1GB, 1)) 'DRY'; return }
            Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop | Out-Null
            Write-Log ('磁盘 {0} 已初始化为 GPT' -f $DiskNumber) 'OK'
        }
    }
}

function Clear-GuiReadyTempSpace {
    param([int]$OlderThanDays = 1, [switch]$DryRun)
    Assert-Administrator | Out-Null
    $targets = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp'), (Join-Path $env:SystemRoot 'SoftwareDistribution\Download'))
    $cut = (Get-Date).AddDays(-1 * [Math]::Max(1, $OlderThanDays))
    $freed = 0
    $removed = 0
    foreach ($dir in $targets) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })
        foreach ($f in $files) {
            if ($DryRun) { $freed += $f.Length; $removed++; continue }
            try {
                $len = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $freed += $len; $removed++
            } catch { }
        }
    }
    $mb = [Math]::Round($freed / 1MB, 1)
    if ($DryRun) { Write-Log ('[预览] 将删除 {0} 个临时文件，约 {1} MB' -f $removed, $mb) 'DRY' }
    else { Write-Log ('已清理 {0} 个临时文件，释放约 {1} MB' -f $removed, $mb) 'OK' }
    return [pscustomobject]@{ Removed = $removed; MB = $mb }
}

# ---------------------------------------------------------------- 卷影副本（VSS）

function Get-GuiReadyShadowCopies {
    $rows = @()
    try {
        foreach ($s in @(Get-CimInstance Win32_ShadowCopy -ErrorAction Stop)) {
            $rows += [pscustomobject]@{
                Id          = [string]$s.ID
                Volume      = [string]$s.VolumeName
                Created     = [string]$s.InstallDate
                Device      = [string]$s.DeviceObject
                Provider    = [string]$s.ProviderName
            }
        }
    } catch {
        Write-Log ('读取卷影副本失败：' + $_.Exception.Message) 'WARN'
    }
    return $rows
}

function New-GuiReadyShadowCopy {
    param([string]$Volume = 'C:\', [switch]$DryRun)
    Assert-Administrator | Out-Null
    if ($DryRun) { Write-Log ('[预览] 将为 {0} 创建卷影副本' -f $Volume) 'DRY'; return }
    $class = [wmiclass]'root\cimv2:Win32_ShadowCopy'
    $r = $class.Create($Volume, 'ClientAccessible')
    if ([int]$r.ReturnValue -ne 0) { throw ('创建卷影副本失败，返回值 ' + $r.ReturnValue) }
    Write-Log ('已创建卷影副本：' + [string]$r.ShadowID) 'OK'
}

function Remove-GuiReadyShadowCopy {
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DryRun)
    Assert-Administrator | Out-Null
    $s = Get-CimInstance Win32_ShadowCopy -Filter ("ID='{0}'" -f $Id) -ErrorAction SilentlyContinue
    if (-not $s) { throw '找不到这个卷影副本' }
    if ($DryRun) { Write-Log ('[预览] 将删除卷影副本 ' + $Id) 'DRY'; return }
    Invoke-CimMethod -InputObject $s -MethodName Delete -ErrorAction Stop | Out-Null
    Write-Log ('已删除卷影副本：' + $Id) 'OK'
}

# ---------------------------------------------------------------- Windows Server Backup

function Test-GuiReadyWbModule {
    return [bool](Get-Command Get-WBSummary -ErrorAction SilentlyContinue)
}

function Get-GuiReadyWbStatus {
    $installed = Test-GuiReadyWbModule
    $data = [ordered]@{
        Installed   = $installed
        LastTime    = ''
        LastResult  = ''
        NextTime    = ''
        Versions    = 0
        Target      = ''
        Schedule    = ''
    }
    if ($installed) {
        try {
            $s = Get-WBSummary -ErrorAction Stop
            $data.LastTime = if ($s.LastBackupTime) { $s.LastBackupTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
            $data.LastResult = [string]$s.LastBackupResultHR
            $data.NextTime = if ($s.NextBackupTime) { $s.NextBackupTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
            $data.Versions = [int]$s.NumberOfVersions
        } catch { }
        try {
            $p = Get-WBPolicy -ErrorAction Stop
            if ($p) {
                $data.Target = (@($p.BackupTargets | ForEach-Object { [string]$_.Path }) -join ',')
                $data.Schedule = (@($p.Schedule | ForEach-Object { [string]$_.StartTime }) -join ',')
            }
        } catch { }
    }
    return [pscustomobject]$data
}

function Start-GuiReadyWbBackup {
    param([switch]$DryRun)
    Assert-Administrator | Out-Null
    if (-not (Test-GuiReadyWbModule)) { throw '本机没有安装 Windows Server Backup（可点「安装备份功能」）' }
    $policy = $null
    try { $policy = Get-WBPolicy -ErrorAction Stop } catch { }
    if (-not $policy) { throw '还没有备份策略：请先安装备份功能并在服务器管理里配置一次，或改用「系统备份（wbadmin）」参数目标盘' }
    if ($DryRun) { Write-Log '[预览] 将按现有策略立即执行一次备份' 'DRY'; return }
    Write-Log '开始执行 Windows Server Backup（后台作业）…' 'STEP'
    Start-WBBackup -Policy $policy -ErrorAction Stop
    Write-Log '备份作业已提交，可在状态里查看进度' 'OK'
}

function Get-GuiReadyWbHistory {
    param([int]$Max = 20)
    if (-not (Test-GuiReadyWbModule)) { return @() }
    try {
        return @(Get-WBBackupSet -ErrorAction Stop | Sort-Object BackupTime -Descending | Select-Object -First $Max |
                 ForEach-Object {
                     [pscustomobject]@{
                         Time   = $(if ($_.BackupTime) { $_.BackupTime.ToString('yyyy-MM-dd HH:mm') } else { '' })
                         Target = [string]$_.BackupTarget
                         Version = [string]$_.VersionId
                         Result = [string]$_.BackupResult
                     }
                 })
    } catch {
        Write-Log ('读取备份历史失败：' + $_.Exception.Message) 'WARN'
        return @()
    }
}

function Install-GuiReadyWbFeature {
    param([switch]$DryRun)
    Assert-Administrator | Out-Null
    if ($DryRun) { Write-Log '[预览] 将安装 Windows-Server-Backup 功能' 'DRY'; return }
    $r = Install-WindowsFeature -Name 'Windows-Server-Backup' -ErrorAction Stop
    Write-Log ('Windows-Server-Backup 安装结果：Success={0} 需要重启={1}' -f $r.Success, $r.RestartNeeded) 'OK'
}

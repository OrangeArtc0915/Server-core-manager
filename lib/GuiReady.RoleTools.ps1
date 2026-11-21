# GuiReady 角色工具：Hyper-V / IIS / 打印 / SMB 共享。
#
# 这些能力只有在对应角色装好后才存在，所以每个函数都先探测命令是否存在，
# 不存在就返回 Available=$false（界面据此隐藏或提示去「角色与功能」装）。

function Get-GuiReadyRoleToolsAvailability {
    return [pscustomobject]@{
        HyperV = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
        IIS    = [bool]((Get-Command Get-IISSite -ErrorAction SilentlyContinue) -or (Get-Command Get-WebSite -ErrorAction SilentlyContinue))
        Print  = [bool](Get-Command Get-Printer -ErrorAction SilentlyContinue)
        Smb    = [bool](Get-Command Get-SmbShare -ErrorAction SilentlyContinue)
    }
}

# ---------------------------------------------------------------- Hyper-V

function Get-GuiReadyVmList {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return @() }
    $rows = @()
    try {
        foreach ($v in @(Get-VM -ErrorAction Stop | Sort-Object Name)) {
            $rows += [pscustomobject]@{
                Name      = [string]$v.Name
                State     = [string]$v.State
                CPU       = [int]$v.CPUUsage
                MemoryMB  = [Math]::Round([double]$v.MemoryAssigned / 1MB, 0)
                Uptime    = $(if ($v.Uptime) { $v.Uptime.ToString('d\.hh\:mm') } else { '' })
                Generation = [int]$v.Generation
                Version   = [string]$v.Version
            }
        }
    } catch {
        Write-Log ('读取虚拟机失败：' + $_.Exception.Message) 'WARN'
    }
    return $rows
}

function Set-GuiReadyVmAction {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][ValidateSet('start', 'stop', 'shutdown', 'save', 'restart', 'pause', 'resume')][string]$Action,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw '本机没有 Hyper-V（先在「角色与功能」里装 Hyper-V）' }
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { throw ('找不到虚拟机：' + $Name) }
    if ($DryRun) { Write-Log ('[预览] 虚拟机 {0}（{1}）→ {2}' -f $Name, $vm.State, $Action) 'DRY'; return }
    switch ($Action) {
        'start'    { Start-VM -Name $Name -ErrorAction Stop }
        'stop'     { Stop-VM -Name $Name -TurnOff -Force -ErrorAction Stop }
        'shutdown' { Stop-VM -Name $Name -Force -ErrorAction Stop }
        'save'     { Save-VM -Name $Name -ErrorAction Stop }
        'restart'  { Restart-VM -Name $Name -Force -ErrorAction Stop }
        'pause'    { Suspend-VM -Name $Name -ErrorAction Stop }
        'resume'   { Resume-VM -Name $Name -ErrorAction Stop }
    }
    Start-Sleep -Milliseconds 600
    $now = Get-VM -Name $Name -ErrorAction SilentlyContinue
    Write-Log ('虚拟机 {0} 现在：{1}' -f $Name, $(if ($now) { [string]$now.State } else { '未知' })) 'OK'
}

function Get-GuiReadyVmSnapshots {
    param([string]$VmName = '')
    if (-not (Get-Command Get-VMSnapshot -ErrorAction SilentlyContinue)) { return @() }
    try {
        $list = @()
        if ($VmName) {
            $list = @(Get-VMSnapshot -VMName $VmName -ErrorAction Stop)
        } else {
            # 不带 -VMName 的 Get-VMSnapshot 在「没有虚拟机 / 没有权限」时实测会卡住
            # （不返回也不报错）。先拿 VM 列表，没有就跳过。
            $names = @(Get-VM -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
            if ($names.Count -eq 0) { return @() }
            foreach ($n in $names) {
                $list += @(Get-VMSnapshot -VMName $n -ErrorAction SilentlyContinue)
            }
        }
        return @($list | Sort-Object CreationTime -Descending | ForEach-Object {
            [pscustomobject]@{
                Name     = [string]$_.Name
                VM       = [string]$_.VMName
                Created  = $(if ($_.CreationTime) { $_.CreationTime.ToString('yyyy-MM-dd HH:mm') } else { '' })
                Parent   = [string]$_.ParentSnapshotName
            }
        })
    } catch { return @() }
}

function Invoke-GuiReadyVmSnapshot {
    param([Parameter(Mandatory = $true)][ValidateSet('create', 'apply', 'remove')][string]$Action,
          [Parameter(Mandatory = $true)][string]$VmName,
          [Parameter(Mandatory = $true)][string]$SnapshotName,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (-not (Get-Command Checkpoint-VM -ErrorAction SilentlyContinue)) { throw '本机没有 Hyper-V' }
    if ($DryRun) { Write-Log ('[预览] 虚拟机 {0} 快照「{1}」→ {2}' -f $VmName, $SnapshotName, $Action) 'DRY'; return }
    switch ($Action) {
        'create' { Checkpoint-VM -VMName $VmName -SnapshotName $SnapshotName -ErrorAction Stop }
        'apply'  { Restore-VMSnapshot -VMName $VmName -Name $SnapshotName -Confirm:$false -ErrorAction Stop }
        'remove' { Remove-VMSnapshot -VMName $VmName -Name $SnapshotName -Confirm:$false -ErrorAction Stop }
    }
    Write-Log ('快照「{0}」{1} 完成' -f $SnapshotName, $Action) 'OK'
}

# ---------------------------------------------------------------- IIS

function Get-GuiReadyIisSites {
    $sites = @()
    $pools = @()
    if (Get-Command Get-IISSite -ErrorAction SilentlyContinue) {
        try {
            foreach ($s in @(Get-IISSite -ErrorAction Stop)) {
                $bindings = @($s.Bindings | ForEach-Object { [string]$_ })
                $sites += [pscustomobject]@{
                    Name     = [string]$s.Name
                    State    = [string]$s.State
                    Path     = [string]$s.PhysicalPath
                    Bindings = ($bindings -join ' ; ')
                }
            }
        } catch { Write-Log ('读取 IIS 站点失败：' + $_.Exception.Message) 'WARN' }
        try {
            foreach ($p in @(Get-IISAppPool -ErrorAction Stop)) {
                $pools += [pscustomobject]@{ Name = [string]$p.Name; State = [string]$p.State; Runtime = [string]$p.ManagedRuntimeVersion }
            }
        } catch { }
    } elseif (Get-Command Get-WebSite -ErrorAction SilentlyContinue) {
        try {
            foreach ($s in @(Get-WebSite -ErrorAction Stop)) {
                $bindings = @()
                try { $bindings = @(Get-WebBinding -Name $s.Name -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.bindingInformation }) } catch { }
                $sites += [pscustomobject]@{
                    Name = [string]$s.Name; State = [string]$s.State; Path = [string]$s.PhysicalPath; Bindings = ($bindings -join ' ; ')
                }
            }
            foreach ($p in @(Get-ChildItem 'IIS:\AppPools' -ErrorAction SilentlyContinue)) {
                $pools += [pscustomobject]@{ Name = [string]$p.Name; State = [string]$p.State; Runtime = [string]$p.ManagedRuntimeVersion }
            }
        } catch { Write-Log ('读取 IIS 站点失败：' + $_.Exception.Message) 'WARN' }
    }
    return [pscustomobject]@{ Sites = $sites; Pools = $pools }
}

function Set-GuiReadyIisAction {
    param([Parameter(Mandatory = $true)][ValidateSet('site-start', 'site-stop', 'site-restart', 'pool-recycle', 'pool-start', 'pool-stop')][string]$Action,
          [Parameter(Mandatory = $true)][string]$Name,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    if ($DryRun) { Write-Log ('[预览] IIS {0}：{1}' -f $Action, $Name) 'DRY'; return }
    if (Get-Command Start-IISSite -ErrorAction SilentlyContinue) {
        switch ($Action) {
            'site-start'   { Start-IISSite -Name $Name -ErrorAction Stop }
            'site-stop'    { Stop-IISSite -Name $Name -Confirm:$false -ErrorAction Stop }
            'site-restart' { Restart-IISSite -Name $Name -Confirm:$false -ErrorAction Stop }
            'pool-recycle' { Restart-IISAppPool -Name $Name -ErrorAction Stop }
            'pool-start'   { Start-IISAppPool -Name $Name -ErrorAction Stop }
            'pool-stop'    { Stop-IISAppPool -Name $Name -ErrorAction Stop }
        }
    } else {
        Import-Module WebAdministration -ErrorAction Stop
        switch ($Action) {
            'site-start'   { Start-Website -Name $Name -ErrorAction Stop }
            'site-stop'    { Stop-Website -Name $Name -ErrorAction Stop }
            'site-restart' { Stop-Website -Name $Name -ErrorAction Stop; Start-Sleep -Milliseconds 500; Start-Website -Name $Name -ErrorAction Stop }
            'pool-recycle' { Restart-WebAppPool -Name $Name -ErrorAction Stop }
            'pool-start'   { Start-WebAppPool -Name $Name -ErrorAction Stop }
            'pool-stop'    { Stop-WebAppPool -Name $Name -ErrorAction Stop }
        }
    }
    Write-Log ('IIS {0} 完成：{1}' -f $Action, $Name) 'OK'
}

# ---------------------------------------------------------------- 打印

function Get-GuiReadyPrinters {
    if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) { return @() }
    $rows = @()
    try {
        foreach ($p in @(Get-Printer -ErrorAction Stop | Sort-Object Name)) {
            $rows += [pscustomobject]@{
                Name     = [string]$p.Name
                Driver   = [string]$p.DriverName
                Port     = [string]$p.PortName
                Status   = [string]$p.PrinterStatus
                Shared   = [bool]$p.Shared
                ShareName = [string]$p.ShareName
                Jobs     = $(try { @(Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue).Count } catch { 0 })
            }
        }
    } catch {
        Write-Log ('读取打印机失败：' + $_.Exception.Message) 'WARN'
    }
    return $rows
}

function Set-GuiReadyPrinterAction {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][ValidateSet('pause', 'resume', 'clear-jobs')][string]$Action,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    $p = Get-Printer -Name $Name -ErrorAction SilentlyContinue
    if (-not $p) { throw ('找不到打印机：' + $Name) }
    if ($DryRun) { Write-Log ('[预览] 打印机 {0} → {1}' -f $Name, $Action) 'DRY'; return }
    switch ($Action) {
        'pause'  { Suspend-Printer -Name $Name -ErrorAction Stop }
        'resume' { Resume-Printer -Name $Name -ErrorAction Stop }
        'clear-jobs' {
            $jobs = @(Get-PrintJob -PrinterName $Name -ErrorAction SilentlyContinue)
            foreach ($j in $jobs) { try { Remove-PrintJob -PrinterName $Name -ID $j.Id -ErrorAction Stop } catch { } }
            Write-Log ('已清空 {0} 个打印作业' -f $jobs.Count) 'OK'
        }
    }
    Write-Log ('打印机 {0}：{1} 完成' -f $Name, $Action) 'OK'
}

# ---------------------------------------------------------------- SMB 共享

function Get-GuiReadySmbShares {
    if (-not (Get-Command Get-SmbShare -ErrorAction SilentlyContinue)) { return @() }
    $rows = @()
    try {
        foreach ($s in @(Get-SmbShare -ErrorAction Stop | Sort-Object Name)) {
            $rows += [pscustomobject]@{
                Name        = [string]$s.Name
                Path        = [string]$s.Path
                Description = [string]$s.Description
                Special     = [bool]$s.Special
                Users       = $(try { [int]$s.CurrentUsers } catch { 0 })
            }
        }
    } catch {
        Write-Log ('读取共享失败：' + $_.Exception.Message) 'WARN'
    }
    return $rows
}

function New-GuiReadySmbShare {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][string]$Path,
          [string]$Description = '',
          [string]$FullAccess = 'Administrators',
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) { throw ('目录不存在：' + $Path) }
    if (Get-SmbShare -Name $Name -ErrorAction SilentlyContinue) { throw ('同名共享已存在：' + $Name) }
    if ($DryRun) { Write-Log ('[预览] 将共享 {0} → {1}（完全控制：{2}）' -f $Name, $Path, $FullAccess) 'DRY'; return }
    $p = @{ Name = $Name; Path = $Path; FullAccess = $FullAccess }
    if ($Description) { $p['Description'] = $Description }
    New-SmbShare @p -ErrorAction Stop | Out-Null
    Write-Log ('已创建共享：{0} → {1}' -f $Name, $Path) 'OK'
}

function Remove-GuiReadySmbShare {
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$DryRun)
    Assert-Administrator | Out-Null
    $s = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { throw ('找不到共享：' + $Name) }
    if ($s.Special) { throw '这是系统特殊共享（如 C$ / IPC$），不能删除' }
    if ($DryRun) { Write-Log ('[预览] 将删除共享 ' + $Name) 'DRY'; return }
    Remove-SmbShare -Name $Name -Force -ErrorAction Stop
    Write-Log ('已删除共享：' + $Name) 'OK'
}

function Get-GuiReadySmbSessions {
    $rows = @()
    if (-not (Get-Command Get-SmbSession -ErrorAction SilentlyContinue)) { return $rows }
    try {
        foreach ($s in @(Get-SmbSession -ErrorAction Stop)) {
            $rows += [pscustomobject]@{
                Client     = [string]$s.ClientComputerName
                User       = [string]$s.ClientUserName
                Opens      = [int]$s.NumOpens
                Dialect    = [string]$s.Dialect
            }
        }
    } catch { }
    return $rows
}

function Get-GuiReadySmbOpenFiles {
    $rows = @()
    if (-not (Get-Command Get-SmbOpenFile -ErrorAction SilentlyContinue)) { return $rows }
    try {
        foreach ($f in @(Get-SmbOpenFile -ErrorAction Stop)) {
            $rows += [pscustomobject]@{
                FileId = [string]$f.FileId
                Client = [string]$f.ClientComputerName
                User   = [string]$f.ClientUserName
                Path   = [string]$f.Path
            }
        }
    } catch { }
    return $rows
}

function Close-GuiReadySmbOpenFile {
    param([Parameter(Mandatory = $true)][string]$FileId, [switch]$DryRun)
    Assert-Administrator | Out-Null
    if ($DryRun) { Write-Log ('[预览] 将断开打开的文件句柄 ' + $FileId) 'DRY'; return }
    Close-SmbOpenFile -FileId $FileId -Force -ErrorAction Stop
    Write-Log ('已断开句柄：' + $FileId) 'OK'
}

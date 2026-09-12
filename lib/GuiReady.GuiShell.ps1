# GuiReady GuiShell: restore Server-Gui-Shell from matching install media (non-official route)

function Get-WindowsImageList {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    try {
        Import-Module Dism -ErrorAction Stop
    } catch { }

    try {
        return @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)
    } catch {
        Write-Log ('读取 WIM 失败: ' + $_.Exception.Message) 'ERROR'
        return @()
    }
}

function Select-GuiShellSourceIndex {
    param(
        [Parameter(Mandatory = $true)][string]$WimPath,
        [Parameter(Mandatory = $true)][int]$CurrentBuild,
        [string]$CurrentEdition = ''
    )

    $result = [ordered]@{
        Ok         = $false
        Index      = 0
        ImageName  = ''
        Reason     = ''
        AllImages  = @()
    }

    $list = Get-WindowsImageList -ImagePath $WimPath
    if ($list.Count -eq 0) {
        $result.Reason = '无法枚举镜像索引（文件损坏或不是 WIM/ESD）'
        return $result
    }

    # Get-WindowsImage without -Index returns only header metadata (Version/InstallationType often empty),
    # so each candidate must be queried per index to obtain Build / InstallationType / EditionId.
    $details = New-Object System.Collections.ArrayList
    Write-Log '介质中的镜像索引:' 'INFO'
    foreach ($i in $list) {
        $d = $null
        try { $d = Get-WindowsImage -ImagePath $WimPath -Index $i.ImageIndex -ErrorAction Stop } catch { }
        if (-not $d) { $d = $i }

        $build = 0
        if ($d.Build) {
            $build = [int]$d.Build
        } elseif ($d.Version) {
            $p = ([string]$d.Version) -split '\.'
            if ($p.Count -ge 3) { $build = [int]$p[2] }
        }

        $item = [pscustomobject]@{
            ImageIndex       = [int]$i.ImageIndex
            ImageName        = [string]$d.ImageName
            InstallationType = [string]$d.InstallationType
            Build            = $build
            SPBuild          = [string]$d.SPBuild
            Version          = [string]$d.Version
            EditionId        = [string]$d.EditionId
        }
        [void]$details.Add($item)
        Write-Log ('  [{0}] {1} | Type={2} | Build={3} {4} | Edition={5}' -f $item.ImageIndex, $item.ImageName, $item.InstallationType, $item.Build, $item.SPBuild, $item.EditionId) 'INFO'
    }
    $result.AllImages = @($details)

    $match = @()
    foreach ($d in $details) {
        $isDesktop = ($d.InstallationType -eq 'Server')
        if (-not $isDesktop -and $d.ImageName -match 'Desktop Experience') { $isDesktop = $true }
        if (-not $isDesktop) { continue }
        if ($d.Build -ne $CurrentBuild) { continue }
        $match += $d
    }

    if ($match.Count -eq 0) {
        $seen = @()
        foreach ($d in $details) { $seen += ('{0}(build {1})' -f $d.ImageName, $d.Build) }
        $result.Reason = ('介质里没有 build {0} 的桌面体验镜像。介质内容: {1}。build 不一致时安装一定失败，已中止。' -f $CurrentBuild, ($seen -join '; '))
        return $result
    }

    $pick = $match[0]
    if ($match.Count -gt 1 -and $CurrentEdition) {
        $ed = @($match | Where-Object { $_.EditionId -eq $CurrentEdition })
        if ($ed.Count -gt 0) { $pick = $ed[0] }
    }
    if ($match.Count -gt 1) {
        Write-Log ('匹配到 {0} 个桌面体验镜像，选用 [{1}] {2}' -f $match.Count, $pick.ImageIndex, $pick.ImageName) 'WARN'
    }

    $result.Ok        = $true
    $result.Index     = $pick.ImageIndex
    $result.ImageName = $pick.ImageName
    $result.Reason    = ('匹配成功: [{0}] {1} (Build {2}.{3}, Edition {4})' -f $pick.ImageIndex, $pick.ImageName, $pick.Build, $pick.SPBuild, $pick.EditionId)
    return $result
}

function Get-GuiShellState {
    try {
        Import-Module ServerManager -ErrorAction Stop
        $f = @(Get-WindowsFeature -Name 'Server-Gui-Shell', 'Server-Gui-Mgmt-Infra' -ErrorAction Stop)
        $out = [ordered]@{
            QueryOk     = $true
            Shell       = ''
            Mgmt        = ''
            ShellExists = $false
            MgmtExists  = $false
            Error       = ''
        }
        foreach ($i in $f) {
            if ($i.Name -eq 'Server-Gui-Shell')      { $out.Shell = [string]$i.InstallState; $out.ShellExists = $true }
            if ($i.Name -eq 'Server-Gui-Mgmt-Infra') { $out.Mgmt  = [string]$i.InstallState; $out.MgmtExists  = $true }
        }
        return $out
    } catch {
        return [ordered]@{ QueryOk = $false; Shell = ''; Mgmt = ''; ShellExists = $false; MgmtExists = $false; Error = $_.Exception.Message }
    }
}

function Install-GuiReadyGuiShell {
    param(
        [Parameter(Mandatory = $true)][string]$WimPath,
        [int]$ImageIndex = 0,
        [switch]$WhatIf,
        [switch]$Confirm
    )

    Write-Head '用安装介质补全 Server-Gui-Shell（非官方路线，高风险）'

    if (-not (Assert-Administrator)) { return }

    $static = Get-GuiReadyStatic
    if (-not $static.IsServerCore) {
        Write-Log '当前不是 Server Core，无需补 Server-Gui-Shell，已中止。' 'ERROR'
        return
    }

    $state = Get-GuiShellState
    if (-not $state.QueryOk) {
        Write-Log ('读取功能状态失败: ' + $state.Error) 'ERROR'
        return
    }
    Write-Log ('Server-Gui-Shell      : {0}  （功能存在: {1}）' -f $state.Shell, (Format-Bool $state.ShellExists)) 'INFO'
    Write-Log ('Server-Gui-Mgmt-Infra : {0}  （功能存在: {1}）' -f $state.Mgmt, (Format-Bool $state.MgmtExists))  'INFO'

    if (-not $state.ShellExists -and -not $state.MgmtExists) {
        Write-Log '本机 Windows 功能列表中不存在 Server-Gui-Shell / Server-Gui-Mgmt-Infra，Install-WindowsFeature 无从安装。已中止。' 'ERROR'
        Write-Log '这是真正的 Server Core SKU 的正常表现（不是 Removed，是根本没有）。' 'WARN'
        Write-Log '可行路线：A 官方 FOD（得 MMC/事件查看器/资源管理器）；C 用 Hyper-V 跑桌面体验虚拟机；D 从桌面体验 WIM 提取包用 Add-WindowsPackage 注入（实验性）。' 'WARN'
        return
    }

    if ($state.Shell -eq 'Installed' -and $state.Mgmt -eq 'Installed') {
        Write-Log '两个功能都已安装，无需操作。' 'OK'
        return
    }
    if ($state.Shell -eq 'Available' -and $state.Mgmt -eq 'Available') {
        Write-Log '状态为 Available（不是 Removed），说明可以直接安装。这种情况源可以更灵活。' 'INFO'
    }

    if ([string]::IsNullOrWhiteSpace($WimPath)) {
        Write-Log '必须提供 -WimPath（与本机 build 一致的 install.wim 或 install.esd）。已中止。' 'ERROR'
        return
    }
    if (-not (Test-Path -LiteralPath $WimPath)) {
        Write-Log ('介质不存在: ' + $WimPath) 'ERROR'
        return
    }

    $currentBuild = [int]$static.Build

    $sel = [ordered]@{ Ok = $false; Index = 0; ImageName = ''; Reason = '' }
    if ($ImageIndex -gt 0) {
        $sel.Ok        = $true
        $sel.Index     = $ImageIndex
        $sel.ImageName = '(用户指定)'
        $sel.Reason    = ('使用用户指定的索引 {0}（跳过 build 自动校验）' -f $ImageIndex)
    } else {
        $sel = Select-GuiShellSourceIndex -WimPath $WimPath -CurrentBuild $currentBuild -CurrentEdition $static.EditionID
    }

    Write-Log $sel.Reason $(if ($sel.Ok) { 'OK' } else { 'ERROR' })
    if (-not $sel.Ok) {
        Write-Log '前置校验未通过，已中止。这一步的校验就是为了避免把系统搞坏。' 'ERROR'
        return
    }

    $source = ('wim:{0}:{1}' -f $WimPath, $sel.Index)

    Write-Log ''
    Write-Log '即将执行:' 'HEAD'
    Write-Log ('  Install-WindowsFeature -Name Server-Gui-Mgmt-Infra, Server-Gui-Shell -Source "{0}"' -f $source) 'DRY'
    Write-Log ''
    Write-Log '风险说明：' 'WARN'
    Write-Log '  1. 微软官方不支持在 Server Core 上补桌面体验组件，此操作属于非官方路线。' 'WARN'
    Write-Log '  2. build 不一致会失败，可能导致组件存储进入 pending 状态，需要 dism /revertpendingactions。' 'WARN'
    Write-Log '  3. 必须重启，重启期间不要强制断电。' 'WARN'
    Write-Log '  4. 装完后签名/更新行为与官方支持的桌面体验版仍可能有差异。' 'WARN'

    if ($WhatIf -or -not $Confirm) {
        Write-Log ''
        Write-Log '预览模式（未执行）。确认要执行时，请选择菜单中的“执行”并用 -Confirm 调用。' 'DRY'
        return
    }

    $backup = New-GuiReadyBackup -Tag 'guiShell'
    Save-JsonReport -Object ([ordered]@{
        When            = (Get-Date).ToString('s')
        Build           = $currentBuild
        WimPath         = $WimPath
        ImageIndex      = $sel.Index
        ImageName       = $sel.ImageName
        ShellStateBefore= $state.Shell
        MgmtStateBefore = $state.Mgmt
        BackupDir       = $backup
    }) -Name 'guishell-prestate' | Out-Null

    Write-Log '开始安装，耗时可能较长，请勿中断...' 'STEP'
    $out    = ''
    $ok     = $false
    try {
        $r = Install-WindowsFeature -Name 'Server-Gui-Mgmt-Infra', 'Server-Gui-Shell' -Source $source -Restart:$false -ErrorAction Stop
        $out = ($r | Out-String)
        $ok  = $true
    } catch {
        $out = ($_ | Out-String)
        Write-Log ('安装失败: ' + $_.Exception.Message) 'ERROR'
    }

    if ($out) { Write-Log ('原始输出: ' + ($out -replace '\s+', ' ').Trim()) 'INFO' }

    if ((-not $ok) -and (-not $ForceDirect) -and (Test-GuiReadyAccessDenied $out)) {
        Write-Log 'DISM 在线服务操作被拒绝（网络登录令牌限制）。自动改用提权计划任务（SYSTEM）重试。' 'WARN'

        $safeWim  = $WimPath.Replace("'", "''")
        $body  = (Get-GuiReadyPreamble)
        $body += "Install-GuiReadyGuiShell -WimPath '$safeWim' -ImageIndex $($sel.Index) -Confirm -ForceDirect`r`n"

        $t = Invoke-GuiReadyElevatedTask -Name 'GuiShell' -Body $body -TimeoutSeconds 5400 -PollSeconds 20
        if ($t.Log) {
            Write-Log '--- 提权任务输出 ---' 'HEAD'
            foreach ($l in ($t.Log -split "`r?`n")) {
                if ($l.Trim()) { Write-Host $l }
            }
        }
        Write-Log ('提权任务结果: ' + $t.Result) $(if ($t.Result -like 'EXIT=OK*') { 'OK' } else { 'ERROR' })
        if ($t.TimedOut) { Write-Log ('提权任务超时，日志文件: ' + $t.LogFile) 'WARN' }
        return
    }

    foreach ($h in (Get-DismErrorHint $out)) {
        Write-Log ('处置建议: ' + $h) 'WARN'
    }

    $after = Get-GuiShellState
    Write-Log ('安装后 Server-Gui-Shell      : {0}' -f $after.Shell) 'INFO'
    Write-Log ('安装后 Server-Gui-Mgmt-Infra : {0}' -f $after.Mgmt)  'INFO'

    if ($ok) {
        Write-Log '命令执行成功。必须重启服务器才能生效，重启后重新跑环境探测确认。' 'OK'
    } else {
        Write-Log ('安装未成功。回滚方式：菜单里的“回滚 Server-Gui-Shell”，或手动执行 dism /online /cleanup-image /revertpendingactions') 'WARN'
    }
}

function Uninstall-GuiReadyGuiShell {
    param([switch]$WhatIf, [switch]$Confirm)

    Write-Head '回滚 Server-Gui-Shell / Server-Gui-Mgmt-Infra'

    if (-not (Assert-Administrator)) { return }

    $static = Get-GuiReadyStatic
    if (-not $static.IsServerCore) {
        Write-Log '当前不是 Server Core，已中止。' 'ERROR'
        return
    }

    $state = Get-GuiShellState
    Write-Log ('Server-Gui-Shell      : {0}' -f $state.Shell) 'INFO'
    Write-Log ('Server-Gui-Mgmt-Infra : {0}' -f $state.Mgmt)  'INFO'

    if ($state.Shell -ne 'Installed' -and $state.Mgmt -ne 'Installed') {
        Write-Log '两个功能都未安装，无需回滚。' 'OK'
        return
    }

    $cmdline = 'Uninstall-WindowsFeature -Name Server-Gui-Shell, Server-Gui-Mgmt-Infra'

    if ($WhatIf -or -not $Confirm) {
        Write-Log '预览模式（未执行），将运行:' 'DRY'
        Write-Log ('  ' + $cmdline) 'DRY'
        Write-Log '  dism /online /cleanup-image /revertpendingactions' 'DRY'
        return
    }

    New-GuiReadyBackup -Tag 'guiShellRollback' | Out-Null

    $out = ''
    try {
        $r = Uninstall-WindowsFeature -Name 'Server-Gui-Shell', 'Server-Gui-Mgmt-Infra' -Restart:$false -ErrorAction Stop
        $out = ($r | Out-String)
        Write-Log '卸载命令已返回。' 'OK'
    } catch {
        $out = ($_ | Out-String)
        Write-Log ('卸载失败: ' + $_.Exception.Message) 'ERROR'
    }
    if ($out) { Write-Log ('原始输出: ' + ($out -replace '\s+', ' ').Trim()) 'INFO' }

    Write-Log '如果组件存储卡在 pending 状态，请执行: dism /online /cleanup-image /revertpendingactions' 'WARN'
    Write-Log '完成后必须重启。' 'WARN'
}

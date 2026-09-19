# GuiReady RDP: make the remote desktop session usable on Server Core

$Global:GuiReadyRdpTcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$Global:GuiReadyTsPath     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$Global:GuiReadyRdpPolPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$Global:GuiReadyWinlogon   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Show-GuiReadyRdpStatus {
    Write-Head 'RDP 会话状态'

    $static = Get-GuiReadyStatic
    Write-Log ('系统: {0}   安装类型: {1}' -f $static.FriendlyName, $static.InstallationType) 'INFO'
    Write-Log ('Winlogon Shell: {0}' -f $static.WinlogonShell) 'INFO'

    $rdp = Get-GuiReadyRdp
    Write-Log ('允许远程连接 (fDenyTSConnections=0): {0}' -f (Format-Bool $rdp.RdpEnabled)) 'INFO'
    Write-Log ('监听端口: {0}    3389 监听中: {1}' -f $rdp.Port, (Format-Bool $rdp.Listening3389)) 'INFO'
    Write-Log ('要求 NLA: {0}' -f (Format-Bool $rdp.NlaRequired)) 'INFO'
    Write-Log ('策略键存在: {0}' -f (Format-Bool $rdp.PolicyKeyExists)) 'INFO'
    if ($rdp.WddmPolicyValue -ne $null) {
        Write-Log ('策略 UseWddmGraphicsDisplayDriver = {0}  （0 表示已禁用 WDDM 驱动，用于规避远程黑屏）' -f $rdp.WddmPolicyValue) 'INFO'
    } else {
        Write-Log '策略 UseWddmGraphicsDisplayDriver 未设置（系统默认值）' 'INFO'
    }
    if ($rdp.RdpTcpWddmValues.Count -gt 0) {
        Write-Log ('RDP-Tcp 下 wddm 相关值: ' + ($rdp.RdpTcpWddmValues -join '; ')) 'INFO'
    }

    foreach ($s in (Get-GuiReadyServices)) {
        Write-Log ('  服务 {0,-22} {1,-10} {2}' -f $s.Name, $s.Status, $s.Start) 'INFO'
    }

    Write-Log '当前会话:' 'INFO'
    if ($rdp.ActiveSessions.Count -eq 0) {
        Write-Log '  （无）没有活动会话时，阶段 B 的代理无法用 WTSQueryUserToken 拿到用户令牌' 'WARN'
    } else {
        foreach ($l in $rdp.ActiveSessions) { Write-Log ('  ' + $l) 'INFO' }
    }

    Write-Log '' 
    Write-Log '登录会话（结构化）:' 'INFO'
    $sess = Get-GuiReadySessionInfo
    foreach ($r in $sess.Rows) {
        Write-Log ('    {0,-18} 用户={1,-14} ID={2,-5} 状态={3,-8} 活动={4}' -f $r.SessionName, $r.User, $r.Id, $r.State, $r.IsActive) 'INFO'
    }
    Write-Log ('  已登录用户会话 {0} 个（活动 {1} 个）' -f $sess.LoggedOnCount, $sess.ActiveWithUser.Count) 'INFO'
    if ($sess.LoggedOnCount -eq 0) {
        Write-Log '  没有已登录用户：GUI 自检做不了，进程也别指望在桌面上显示' 'WARN'
    }

    Write-Log ''
    Write-Log 'UAC 状态:' 'INFO'
    $uac = Get-GuiReadyUac
    Write-Log ('  EnableLUA={0}  ConsentPromptBehaviorAdmin={1}  PromptOnSecureDesktop={2}  FilterAdministratorToken={3}' -f $uac.EnableLUA, $uac.ConsentPromptBehaviorAdmin, $uac.PromptOnSecureDesktop, $uac.FilterAdministratorToken) 'INFO'
    Write-Log ('  ' + $uac.Note) $(if ($uac.PromptsWillBlock) { 'WARN' } else { 'INFO' })
    if ($uac.PromptsWillBlock) {
        Write-Log '  处置选择：a) 人工 RDP 进去点一下确认  b) 以 SYSTEM 计划任务运行  c) 用 CreateProcess 绕过 ShellExecute（不触发 UAC）  d) 临时设 ConsentPromptBehaviorAdmin=0' 'WARN'
    }

    Write-Log ''
    Write-Log '.NET 运行时:' 'INFO'
    if (Get-Command Get-GuiReadyDotNetStatus -ErrorAction SilentlyContinue) {
        $dn = Get-GuiReadyDotNetStatus
        Write-Log ('  dotnet.exe: {0}' -f (Format-Bool $dn.DotNetExe)) 'INFO'
        if ($dn.Frameworks.Count -gt 0) {
            foreach ($f in ($dn.Frameworks | Sort-Object Name, Version)) { Write-Log ('    {0} {1}' -f $f.Name, $f.Version) 'INFO' }
        } else {
            Write-Log '    未安装任何 .NET 运行时（菜单第 5 项可自动补齐）' 'WARN'
        }
    } else {
        Write-Log '  （DotNet 模块未加载）' 'WARN'
    }
}

function Enable-GuiReadyRdp {
    param([switch]$WhatIf)

    Write-Head '启用远程桌面'

    if (-not (Assert-Administrator)) { return }

    $steps = @(
        @{ Desc = '允许远程桌面连接 (fDenyTSConnections=0)'; Key = $Global:GuiReadyTsPath;     Name = 'fDenyTSConnections'; Value = 0;  Type = 'DWord' },
        @{ Desc = '确保 RDP-Tcp 监听器启用 (fEnableWinStation=1)'; Key = $Global:GuiReadyRdpTcpPath; Name = 'fEnableWinStation';  Value = 1;  Type = 'DWord' }
    )

    if ($WhatIf) {
        foreach ($s in $steps) {
            Write-Log ('将写入 {0} -> {1} = {2}' -f $s.Key, $s.Name, $s.Value) 'DRY'
        }
        Write-Log '将启用防火墙“远程桌面”规则组，并确保 TermService 已启动' 'DRY'
        return
    }

    New-GuiReadyBackup -Tag 'rdpEnable' | Out-Null

    foreach ($s in $steps) {
        try {
            if (-not (Test-Path $s.Key)) { New-Item -Path $s.Key -Force | Out-Null }
            New-ItemProperty -Path $s.Key -Name $s.Name -Value $s.Value -PropertyType $s.Type -Force | Out-Null
            Write-Log $s.Desc 'OK'
        } catch {
            Write-Log ('失败: {0} :: {1}' -f $s.Desc, $_.Exception.Message) 'ERROR'
        }
    }

    try {
        # DisplayGroup 是【本地化】字符串：中文系统上是“远程桌面”，只按英文名找必然失败（实测踩过）。
        # 顺序：英文组名 → 中文组名 → 按显示名/端口兜底 → 一条都没有就自己建一条。
        $rules = @()
        foreach ($g in @('Remote Desktop', '远程桌面')) {
            try { $rules += @(Get-NetFirewallRule -DisplayGroup $g -ErrorAction Stop) } catch { }
        }
        if ($rules.Count -eq 0) {
            $rules = @(Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -match '(?i)remote desktop|远程桌面|3389' })
        }
        if ($rules.Count -gt 0) {
            $rules | Enable-NetFirewallRule -ErrorAction Stop
            Write-Log ('已启用防火墙“远程桌面”规则组（{0} 条）' -f $rules.Count) 'OK'
        } else {
            New-NetFirewallRule -DisplayName 'Remote Desktop (3389, ServerCoreManager)' -Direction Inbound `
                -Protocol TCP -LocalPort 3389 -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Write-Log '未找到系统自带规则，已新建一条放行 TCP 3389 的入站规则' 'OK'
        }
    } catch {
        Write-Log ('启用防火墙规则失败（可能本就放行，或用 netsh 手动处理）: ' + $_.Exception.Message) 'WARN'
    }

    try {
        $svc = Get-Service -Name 'TermService' -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            Start-Service -Name 'TermService' -ErrorAction Stop
            Write-Log '已启动 TermService' 'OK'
        } else {
            Write-Log 'TermService 已在运行' 'OK'
        }
    } catch {
        Write-Log ('启动 TermService 失败: ' + $_.Exception.Message) 'ERROR'
    }

    Write-Log '完成后请用 mstsc 或 WAC 远程桌面连接验证。' 'INFO'
}

function Disable-GuiReadyWddmForRdp {
    param([switch]$WhatIf)

    Write-Head '关闭 RDP 的 WDDM 图形驱动（规避远程黑屏）'

    if (-not (Assert-Administrator)) { return }

    Write-Log '依据：组策略“对远程桌面连接使用 WDDM 图形显示驱动”，禁用后 RDP 会话回退到较老的显示驱动模型，' 'INFO'
    Write-Log '      这是远程会话黑屏/无法渲染时的常规排错手段。' 'INFO'

    if ($WhatIf) {
        Write-Log ('将写入 {0} -> UseWddmGraphicsDisplayDriver = 0' -f $Global:GuiReadyRdpPolPath) 'DRY'
        return
    }

    New-GuiReadyBackup -Tag 'rdpWddm' | Out-Null

    try {
        if (-not (Test-Path $Global:GuiReadyRdpPolPath)) {
            New-Item -Path $Global:GuiReadyRdpPolPath -Force | Out-Null
        }
        New-ItemProperty -Path $Global:GuiReadyRdpPolPath -Name 'UseWddmGraphicsDisplayDriver' -Value 0 -PropertyType DWord -Force | Out-Null
        $readBack = Get-RegValue $Global:GuiReadyRdpPolPath 'UseWddmGraphicsDisplayDriver'
        Write-Log ('已写入并回读: UseWddmGraphicsDisplayDriver = {0}' -f $readBack) 'OK'
        Write-Log '需要重启或重启 TermService 后生效。' 'WARN'
    } catch {
        Write-Log ('写入失败: ' + $_.Exception.Message) 'ERROR'
    }
}

function Restore-GuiReadyWddmForRdp {
    param([switch]$WhatIf)

    Write-Head '恢复 RDP 的 WDDM 图形驱动设置'

    if (-not (Assert-Administrator)) { return }

    if ($WhatIf) {
        Write-Log ('将删除 {0} 下的 UseWddmGraphicsDisplayDriver' -f $Global:GuiReadyRdpPolPath) 'DRY'
        return

    New-GuiReadyBackup -Tag 'rdpWddmRestore' | Out-Null
    }

    try {
        if (Test-Path $Global:GuiReadyRdpPolPath) {
            Remove-ItemProperty -Path $Global:GuiReadyRdpPolPath -Name 'UseWddmGraphicsDisplayDriver' -Force -ErrorAction SilentlyContinue
            Write-Log '已删除该策略值，系统回到默认行为。' 'OK'
        } else {
            Write-Log '策略键不存在，无需恢复。' 'OK'
        }
    } catch {
        Write-Log ('恢复失败: ' + $_.Exception.Message) 'ERROR'
    }
}

function Set-GuiReadyShell {
    param(
        [ValidateSet('Explorer', 'Launcher', 'Cmd', 'SConfig', 'Restore', 'Default')][string]$Mode = 'Default',
        [switch]$WhatIf
    )

    Write-Head ('设置 Winlogon Shell 为: ' + $Mode)

    if (-not (Assert-Administrator)) { return }

    $current = Get-RegValue $Global:GuiReadyWinlogon 'Shell'
    Write-Log ('当前 Shell: {0}' -f $(if ($current) { $current } else { '(未设置)' })) 'INFO'

    # 从工具的备份里恢复（backup\shell-*\Winlogon.reg）
    if ($Mode -eq 'Restore') {
        $bk = @(Get-ChildItem -LiteralPath $script:BackupDir -Directory -Filter 'shell-*' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        if ($bk.Count -eq 0) {
            Write-Log ('没有找到 shell 备份（' + (Join-Path $script:BackupDir 'shell-*') + '），无法恢复。') 'ERROR'
            return
        }
        $reg = Join-Path $bk[0].FullName 'Winlogon.reg'
        if (-not (Test-Path -LiteralPath $reg)) {
            Write-Log ('备份目录里没有 Winlogon.reg: ' + $bk[0].Name) 'ERROR'
            return
        }
        if ($WhatIf) { Write-Log ('将导入备份: ' + $reg) 'DRY'; return }
        $r = Invoke-Capture 'reg.exe' @('import', $reg)
        if ($r.ExitCode -eq 0) {
            $backNow = Get-RegValue $Global:GuiReadyWinlogon 'Shell'
            Write-Log ('已从备份恢复: Shell = ' + $(if ($backNow) { $backNow } else { '(未设置)' })) 'OK'
        } else {
            Write-Log ('恢复失败（reg import 退出码 ' + $r.ExitCode + '）') 'ERROR'
        }
        return
    }

    $target = ''
    switch ($Mode) {
        'Explorer' { $target = 'explorer.exe' }
        'Cmd'      { $target = 'cmd.exe' }
        'Default'  { $target = 'cmd.exe' }
        'SConfig'  {
            # Server Core 原生：登录后直接进 sconfig 菜单（servercoreshelllaunch.bat 就是干这个的）。
            # 注意 Shell 的值由 Winlogon 直接 CreateProcess，.bat 不能直接执行，必须经 cmd.exe 承载。
            $bat = Join-Path (Join-Path $env:windir 'system32') 'servercoreshelllaunch.bat'
            if (-not (Test-Path -LiteralPath $bat)) {
                Write-Log '本机没有 servercoreshelllaunch.bat（这不是 Server Core？），已中止。' 'ERROR'
                return
            }
            $target = 'cmd.exe /c ' + $bat
        }
        'Launcher' {
            $lp = Join-Path $script:GuiReadyRoot 'launcher\Start-Launcher.ps1'
            $target = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File "{0}"' -f $lp)
        }
    }

    if ($Mode -eq 'Explorer') {
        $expl = Join-Path $env:windir 'explorer.exe'
        if (-not (Test-Path -LiteralPath $expl)) {
            Write-Log 'explorer.exe 不存在。需要先装 App Compatibility FOD，否则登录后会是黑屏加一个错误框。已中止。' 'ERROR'
            return
        }
    }
    if ($Mode -eq 'Launcher') {
        $lp = Join-Path $script:GuiReadyRoot 'launcher\Start-Launcher.ps1'
        if (-not (Test-Path -LiteralPath $lp)) {
            Write-Log ('启动器脚本不存在: ' + $lp) 'ERROR'
            return
        }
    }

    if ($WhatIf) {
        Write-Log ('将写入 {0} -> Shell = "{1}"' -f $Global:GuiReadyWinlogon, $target) 'DRY'
        return
    }

    New-GuiReadyBackup -Tag 'shell' | Out-Null

    try {
        New-ItemProperty -Path $Global:GuiReadyWinlogon -Name 'Shell' -Value $target -PropertyType String -Force | Out-Null
        $readBack = Get-RegValue $Global:GuiReadyWinlogon 'Shell'
        Write-Log ('已写入并回读: Shell = {0}' -f $readBack) 'OK'
        Write-Log '下次登录生效。' 'INFO'
        Write-Log '若登录后界面异常，可用远程 PowerShell 执行: 菜单 -> 设置 Shell -> Cmd 恢复。' 'WARN'
    } catch {
        Write-Log ('写入失败: ' + $_.Exception.Message) 'ERROR'
    }
}

function Invoke-GuiReadyRdpQuickFix {
    param([switch]$WhatIf)

    Write-Head '远程会话一键修复（启用 RDP + 关闭 WDDM 驱动）'

    Enable-GuiReadyRdp -WhatIf:$WhatIf
    Disable-GuiReadyWddmForRdp -WhatIf:$WhatIf

    if (-not $WhatIf) {
        try {
            Restart-Service -Name 'TermService' -Force -ErrorAction Stop
            Write-Log '已重启 TermService 以让策略生效。' 'OK'
        } catch {
            Write-Log ('重启 TermService 失败，请手动重启服务器: ' + $_.Exception.Message) 'WARN'
        }
        Write-Log '注意：重启 TermService 会断开当前所有 RDP 会话。' 'WARN'
    }
}

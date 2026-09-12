# GuiReady detection: read-only environment probe

$Global:GuiReadyDllGroups = [ordered]@{
    'Core基线'     = @(
        'user32.dll', 'gdi32.dll', 'gdi32full.dll', 'msvcrt.dll', 'advapi32.dll',
        'shell32.dll', 'shlwapi.dll', 'ole32.dll', 'oleaut32.dll', 'combase.dll',
        'comctl32.dll', 'comdlg32.dll', 'uxtheme.dll', 'shcore.dll', 'version.dll',
        'imm32.dll', 'msimg32.dll', 'winspool.drv', 'winmm.dll', 'msftedit.dll', 'riched20.dll'
    )
    'FOD提供'      = @(
        'mmc.exe', 'mmcbase.dll', 'mmcndmgr.dll', 'explorer.exe',
        'perfmon.exe', 'resmon.exe', 'eventvwr.exe'
    )
    '桌面体验专属' = @(
        'dwm.exe', 'uDWM.dll', 'dwmcore.dll', 'dwmredir.dll', 'dwmapi.dll',
        'dcomp.dll', 'dwrite.dll', 'd2d1.dll', 'd3d11.dll', 'dxgi.dll',
        'd3d10warp.dll', 'D3DCompiler_47.dll', 'DXCore.dll',
        'themeui.dll', 'themeservice.dll',
        'twinui.dll', 'twinapi.appcore.dll', 'Windows.UI.Immersive.dll',
        'CoreMessaging.dll', 'CoreUIComponents.dll', 'DispBroker.dll',
        'UIAnimation.dll', 'wuceffects.dll'
    )
}

function Get-BuildFriendlyName {
    param([string]$Build)
    switch ($Build) {
        '14393' { return 'Windows Server 2016' }
        '17763' { return 'Windows Server 2019' }
        '20348' { return 'Windows Server 2022' }
        '26100' { return 'Windows Server 2025' }
        '20349' { return 'Windows Server 2022 (21H2)' }
        default { return ('未识别的版本 (Build ' + $Build + ')') }
    }
}

function Get-GuiReadyStatic {
    $o  = [ordered]@{}
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

    $o.ProductName      = [string]$cv.ProductName
    $o.EditionID        = [string]$cv.EditionID
    $o.DisplayVersion   = [string]$cv.DisplayVersion
    $o.Build            = [string]$cv.CurrentBuildNumber
    $o.UBR              = [string]$cv.UBR
    $o.InstallationType = [string]$cv.InstallationType
    $o.OSVersion        = [System.Environment]::OSVersion.Version.ToString()
    $o.FriendlyName     = Get-BuildFriendlyName $o.Build
    $o.IsServerCore     = ($o.InstallationType -eq 'Server Core')
    $o.PendingReboot    = Test-PendingReboot
    $o.IsAdministrator  = Test-IsAdministrator
    $o.MachineName      = $env:COMPUTERNAME

    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    $o.WinlogonShell = [string]$wl.Shell
    $o.Userinit      = [string]$wl.Userinit
    if ([string]::IsNullOrWhiteSpace($o.WinlogonShell)) { $o.WinlogonShell = '(未设置，默认 cmd.exe)' }

    return $o
}

function Get-GuiReadyDllScan {
    $items = New-Object System.Collections.ArrayList
    $sys32 = Join-Path $env:windir 'System32'
    $sys64 = Join-Path $env:windir 'SysWOW64'

    foreach ($group in $Global:GuiReadyDllGroups.Keys) {
        foreach ($name in $Global:GuiReadyDllGroups[$group]) {
            $p32 = Join-Path $sys32 $name
            $p64 = Join-Path $sys64 $name
            $pRoot = Join-Path $env:windir $name
            $found = ''
            if (Test-Path -LiteralPath $p32) { $found = $p32 } elseif (Test-Path -LiteralPath $pRoot) { $found = $pRoot }
            $exists = ($found -ne '')
            $size = 0
            $ver  = ''
            if ($exists) {
                try {
                    $fi   = Get-Item -LiteralPath $found -ErrorAction Stop
                    $size = $fi.Length
                    $ver  = $fi.VersionInfo.FileVersion
                } catch { }
            }
            $items.Add([pscustomobject]@{
                Name       = $name
                Group      = $group
                Exists     = $exists
                SizeBytes  = $size
                FileVersion= $ver
                ExistsWow64= (Test-Path -LiteralPath $p64)
            }) | Out-Null
        }
    }
    return $items
}

function Get-GuiReadyFeatures {
    $result = [ordered]@{
        Available              = $false
        Error                  = ''
        Gui                    = @()
        HyperV                 = $null
        GuiShellFeatureExists  = $false
        GuiMgmtFeatureExists   = $false
        FeatureCount           = 0
        InstalledCount         = 0
    }
    try {
        Import-Module ServerManager -ErrorAction Stop
        $all = @(Get-WindowsFeature -ErrorAction Stop)
        $result.Available      = $true
        $result.FeatureCount   = $all.Count
        $result.InstalledCount = @($all | Where-Object { $_.Installed }).Count

        foreach ($f in $all) {
            if ($f.Name -like 'Server-Gui*' -or $f.Name -eq 'Desktop-Experience') {
                $result.Gui += [pscustomobject]@{
                    Name         = $f.Name
                    DisplayName  = $f.DisplayName
                    InstallState = [string]$f.InstallState
                    Installed    = [bool]$f.Installed
                }
            }
        }

        $names = @($all | ForEach-Object { $_.Name })
        $result.GuiShellFeatureExists = ($names -contains 'Server-Gui-Shell')
        $result.GuiMgmtFeatureExists  = ($names -contains 'Server-Gui-Mgmt-Infra')

        $hv = $all | Where-Object { $_.Name -eq 'Hyper-V' } | Select-Object -First 1
        if ($hv) { $result.HyperV = [string]$hv.InstallState }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Get-GuiReadyCapability {
    $result = [ordered]@{
        Queried = $false
        Error   = ''
        Items   = @()
    }
    try {
        $names = @('ServerCore.AppCompatibility~~~~0.0.1.0')
        foreach ($n in $names) {
            try {
                $c = Get-WindowsCapability -Online -Name $n -ErrorAction Stop
                foreach ($item in @($c)) {
                    $result.Items += [pscustomobject]@{
                        Name  = $item.Name
                        State = [string]$item.State
                    }
                }
            } catch {
                $result.Error = $_.Exception.Message
            }
        }
        $result.Queried = $true
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Get-GuiReadyRdp {
    $o = [ordered]@{}
    $tsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $tcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

    $deny = Get-RegValue $tsPath 'fDenyTSConnections'
    $o.RdpEnabled = $null
    if ($null -ne $deny) { $o.RdpEnabled = ([int]$deny -eq 0) }

    $o.Port          = Get-RegValue $tcpPath 'PortNumber'
    $o.NlaRequired   = Get-RegValue $tcpPath 'UserAuthentication'
    $o.ColorDepth    = Get-RegValue $tcpPath 'ColorDepth'
    $o.WinStationOn  = Get-RegValue $tcpPath 'fEnableWinStation'

    $polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $o.PolicyKeyExists   = Test-Path $polPath
    $o.PolicyValueNames  = @(Get-RegValueNames $polPath)
    $o.WddmPolicyValue   = Get-RegValue $polPath 'UseWddmGraphicsDisplayDriver'

    $wddmLike = @()
    foreach ($n in (Get-RegValueNames $tcpPath)) {
        if ($n -match 'wddm') {
            $wddmLike += ('{0}={1}' -f $n, (Get-RegValue $tcpPath $n))
        }
    }
    $o.RdpTcpWddmValues = $wddmLike

    $o.Listening3389 = $false
    try {
        $conn = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
        if ($conn) { $o.Listening3389 = $true }
    } catch { }

    $o.ActiveSessions   = @()
    $o.SessionQueryError= ''
    try {
        $q = & query.exe session 2>&1
        $o.ActiveSessions = @($q | ForEach-Object { [string]$_ })
    } catch {
        $o.SessionQueryError = $_.Exception.Message
    }

    return $o
}

function Get-GuiReadyServices {
    $names = @('TermService', 'UmRdpService', 'SessionEnv', 'Themes', 'Audiosrv', 'AudioEndpointBuilder')
    $out = @()
    foreach ($n in $names) {
        try {
            $s = Get-Service -Name $n -ErrorAction Stop
            $out += [pscustomobject]@{
                Name    = $s.Name
                Display = $s.DisplayName
                Status  = [string]$s.Status
                Start   = [string]$s.StartType
            }
        } catch {
            $out += [pscustomobject]@{
                Name    = $n
                Display = ''
                Status  = 'NotPresent'
                Start   = ''
            }
        }
    }
    return $out
}

function Get-GuiReadyDwmProcess {
    try {
        $p = Get-Process -Name 'dwm' -ErrorAction SilentlyContinue
        return [bool]$p
    } catch {
        return $false
    }
}

function Get-GuiReadyMedia {
    $found = New-Object System.Collections.ArrayList
    $probe = @('sources\install.wim', 'sources\install.esd', 'LanguagesAndOptionalFeatures', 'sources\sxs')

    # 只用 DriveInfo，并且跳过“未就绪”的驱动器。
    # 空光驱或未就绪的卷上做 Test-Path / 目录枚举会长时间阻塞（实测：开机后以 SYSTEM 运行会卡死数分钟）。
    # 也不再使用 Get-DiskImage —— 它依赖 Virtual Disk Service，服务未就绪时会挂住。
    $roots      = @()
    $cdromReady = @()
    $cdromEmpty = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            $type  = ''
            $ready = $false
            try { $type = [string]$d.DriveType; $ready = $d.IsReady } catch { continue }
            if ($type -eq 'CDRom') {
                if ($ready) { $cdromReady += $d.Name } else { $cdromEmpty += $d.Name }
                continue
            }
            if (-not $ready) { continue }
            if ($type -eq 'Fixed' -or $type -eq 'Removable' -or $type -eq 'Network') { $roots += $d.Name }
        }
    } catch { }

    foreach ($extra in @('C:\SetupFiles', 'C:\ISO', 'C:\temp', 'C:\Temp')) {
        try { if ([System.IO.Directory]::Exists($extra)) { $roots += $extra } } catch { }
    }

    foreach ($r in $roots) {
        foreach ($p in $probe) {
            $full = Join-Path $r $p
            $exists = $false
            try {
                $exists = ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full))
            } catch { $exists = $false }
            if ($exists) {
                $isFile = $false
                try { $isFile = -not (Get-Item -LiteralPath $full).PSIsContainer } catch { }
                [void]$found.Add([pscustomobject]@{
                    Path = $full
                    Kind = $(if ($isFile) { 'Image' } else { 'Folder' })
                })
            }
        }
    }

    return [pscustomobject]@{
        Candidates    = $found
        MountedImages = @($cdromReady | ForEach-Object { $_ + ' (有介质的光驱，可能是已挂载的 ISO)' })
        CdRomReady    = @($cdromReady)
        CdRomEmpty    = @($cdromEmpty)
        ScannedRoots  = @($roots)
    }
}

function Get-GuiReadyAssessment {
    param($Static, $Features, $Capability, $DllScan, $Media)

    $a = [ordered]@{}

    $fodState = 'NotPresent'
    foreach ($i in $Capability.Items) {
        if ($i.Name -like 'ServerCore.AppCompatibility*') { $fodState = $i.State }
    }
    $a.FodState = $fodState
    $a.FodInstalled = ($fodState -eq 'Installed')

    $shellState = 'Unknown'
    $mgmtState  = 'Unknown'
    foreach ($f in $Features.Gui) {
        if ($f.Name -eq 'Server-Gui-Shell')      { $shellState = $f.InstallState }
        if ($f.Name -eq 'Server-Gui-Mgmt-Infra') { $mgmtState  = $f.InstallState }
    }
    $a.GuiShellState = $shellState
    $a.GuiMgmtState  = $mgmtState

    $desktopMissing = @($DllScan | Where-Object { $_.Group -eq '桌面体验专属' -and -not $_.Exists } | ForEach-Object { $_.Name })
    $fodMissing     = @($DllScan | Where-Object { $_.Group -eq 'FOD提供'      -and -not $_.Exists } | ForEach-Object { $_.Name })
    $coreMissing    = @($DllScan | Where-Object { $_.Group -eq 'Core基线'     -and -not $_.Exists } | ForEach-Object { $_.Name })

    $a.DesktopMissing = $desktopMissing
    $a.FodMissing     = $fodMissing
    $a.CoreMissing    = $coreMissing

    $a.RouteA_FodReady = ($Static.IsServerCore -and -not $a.FodInstalled)
    $a.RouteA_Note = ''
    if (-not $Static.IsServerCore) {
        $a.RouteA_Note = '当前不是 Server Core，FOD 仅能装在 Server Core 上，跳过'
    } elseif ($a.FodInstalled) {
        $a.RouteA_Note = 'App Compatibility FOD 已安装'
    } else {
        $a.RouteA_Note = '可执行：装 FOD 后可获得 MMC / 事件查看器 / 磁盘管理 / 性能监视器 等'
    }

    $wim = @($Media.Candidates | Where-Object { $_.Kind -eq 'Image' })
    $a.RouteB_MediaFound = ($wim.Count -gt 0)
    $a.RouteB_Viable     = $false
    $a.GuiShellFeatureExists = $Features.GuiShellFeatureExists

    if ($Static.IsServerCore) {
        if (-not $Features.GuiShellFeatureExists -and -not $Features.GuiMgmtFeatureExists) {
            $a.RouteB_Note = '不可行：本机 Windows 功能列表中不存在 Server-Gui-Shell / Server-Gui-Mgmt-Infra（不是 Removed 状态，是根本没有这两个功能）。真正的 Server Core SKU 无法用 Install-WindowsFeature 补桌面体验；社区里“装 Server-Gui-Shell”的做法只适用于“桌面体验版被卸载过”的场景。'
        } elseif ($shellState -eq 'Installed') {
            $a.RouteB_Note = 'Server-Gui-Shell 已安装，桌面体验组件齐备'
            $a.RouteB_Viable = $true
        } elseif ($shellState -eq 'Removed') {
            $a.RouteB_Note = ('Server-Gui-Shell 状态为 Removed：需要匹配 build {0} 的安装介质作源才能补回，属非官方路线' -f $Static.Build)
            $a.RouteB_Viable = $true
        } elseif ($shellState -eq 'Available') {
            $a.RouteB_Note = 'Server-Gui-Shell 状态为 Available：可直接安装'
            $a.RouteB_Viable = $true
        } else {
            $a.RouteB_Note = ('未能读取 Server-Gui-Shell 状态（功能存在性: Shell={0} Mgmt={1}）' -f $Features.GuiShellFeatureExists, $Features.GuiMgmtFeatureExists)
        }
    } else {
        $a.RouteB_Note = '当前不是 Server Core，无需补 Server-Gui-Shell'
    }

    $a.RouteD_Note = '实验性：从桌面体验版 WIM 中提取 Microsoft-Windows-Server-Shell-Package 等包，用 Add-WindowsPackage 逐个注入到 Core。成功率未知，CBS 很可能以“包不适用于此映像”拒绝，属于需要单独验证的路线。'

    $a.RouteC_HyperVState = $Features.HyperV
    $a.RouteC_Note = '在 Server Core 上用 Hyper-V 跑一个带桌面体验的虚拟机，由 Windows Admin Center 连接该 VM。适合需要 UWP/XAML、完整主题外观或绝对稳定隔离的场景。注意：实测表明装了官方 FOD 后 WPF/WinForms 已能在 Server Core 本机运行，所以这条路不再是唯一选择。'

    $a.Conclusion = ''
    $hasDwm    = @($DllScan | Where-Object { $_.Name -eq 'dwm.exe'    -and $_.Exists }).Count -gt 0
    $hasDcomp  = @($DllScan | Where-Object { $_.Name -eq 'dcomp.dll'  -and $_.Exists }).Count -gt 0
    $hasDwrite = @($DllScan | Where-Object { $_.Name -eq 'dwrite.dll' -and $_.Exists }).Count -gt 0
    $hasTwinUI = @($DllScan | Where-Object { $_.Name -eq 'twinui.dll' -and $_.Exists }).Count -gt 0
    $a.RenderStackReady = ($hasDwm -and $hasDcomp -and $hasDwrite)
    $a.HasDwm    = $hasDwm
    $a.HasDcomp  = $hasDcomp
    $a.HasDwrite = $hasDwrite
    $a.HasTwinUI = $hasTwinUI

    if (-not $Static.IsServerCore) {
        $a.Conclusion = '当前系统不是 Server Core，本工具主要动作不适用；探测报告仍可用于对比。'
    } elseif ($a.RenderStackReady) {
        $a.Conclusion = ('现代渲染管线已就位（dwm.exe / dcomp.dll / dwrite.dll 均在）。实测结论：WinForms 与 WPF 能创建窗口并渲染，MMC / 事件查看器 / 记事本等可用。Electron/Chromium 类程序建议先加 --disable-gpu --disable-software-rasterizer（实测启动快约 3 倍）。仍缺 {0} 个组件（{1}），主要影响 UWP/XAML 类应用与主题外观。' -f $desktopMissing.Count, ($desktopMissing -join ', '))
    } elseif ($a.FodInstalled) {
        $a.Conclusion = ('已装 FOD，但渲染关键组件不齐（dwm={0} dcomp={1} dwrite={2}）。纯 Win32/GDI 程序可用；WPF/Electron 类需实跑验证。' -f (Format-Bool $hasDwm), (Format-Bool $hasDcomp), (Format-Bool $hasDwrite))
    } else {
        $a.Conclusion = '尚未安装 App Compatibility FOD。先执行菜单第 3 项，再重新探测，之后的结论才准确。'
    }

    return $a
}

function Invoke-GuiReadyDetect {
    param([switch]$Quiet)

    Write-Head '环境探测（只读）'

    $static = Get-GuiReadyStatic

    Write-Log ('系统      : {0}' -f $static.FriendlyName) 'INFO'
    Write-Log ('版本      : {0}  Build {1}.{2}  ({3})' -f $static.DisplayVersion, $static.Build, $static.UBR, $static.OSVersion) 'INFO'
    Write-Log ('EditionID : {0}' -f $static.EditionID) 'INFO'
    Write-Log ('安装类型  : {0}' -f $static.InstallationType) 'INFO'
    Write-Log ('Winlogon Shell : {0}' -f $static.WinlogonShell) 'INFO'
    Write-Log ('管理员权限: {0}   待重启: {1}' -f (Format-Bool $static.IsAdministrator), (Format-Bool $static.PendingReboot) ) 'INFO'

    if ($static.IsServerCore) {
        Write-Log '判定：这是 Server Core，标准图形界面未安装。' 'OK'
    } else {
        Write-Log '判定：这不是 Server Core（可能是带桌面体验的服务器或客户端系统）。' 'WARN'
    }

    Write-Log '读取 Windows 功能状态...' 'STEP'
    $features = Get-GuiReadyFeatures
    if (-not $features.Available) {
        Write-Log ('ServerManager 模块不可用: ' + $features.Error) 'WARN'
    } else {
        foreach ($f in $features.Gui) {
            Write-Log ('  {0,-26} {1}' -f $f.Name, $f.InstallState) 'INFO'
        }
        Write-Log ('  Hyper-V 状态: {0}' -f (Format-Bool $features.HyperV)) 'INFO'
    }

    Write-Log '读取 App Compatibility FOD 状态...' 'STEP'
    $cap = Get-GuiReadyCapability
    if ($cap.Error) { Write-Log ('  查询出错: ' + $cap.Error) 'WARN' }
    if ($cap.Items.Count -eq 0) {
        Write-Log '  ServerCore.AppCompatibility 未安装' 'WARN'
    } else {
        foreach ($i in $cap.Items) { Write-Log ('  {0} -> {1}' -f $i.Name, $i.State) 'INFO' }
    }

    Write-Log '扫描 GUI 相关系统模块...' 'STEP'
    $dlls = Get-GuiReadyDllScan
    $deskMissing = @($dlls | Where-Object { $_.Group -eq '桌面体验专属' -and -not $_.Exists })
    $fodMissing  = @($dlls | Where-Object { $_.Group -eq 'FOD提供'      -and -not $_.Exists })
    $coreMissing = @($dlls | Where-Object { $_.Group -eq 'Core基线'     -and -not $_.Exists })
    Write-Log ('  Core基线      : {0}/{1} 存在' -f (($dlls | Where-Object { $_.Group -eq 'Core基线' -and $_.Exists }).Count), $Global:GuiReadyDllGroups['Core基线'].Count) 'INFO'
    Write-Log ('  FOD提供       : {0}/{1} 存在' -f (($dlls | Where-Object { $_.Group -eq 'FOD提供'  -and $_.Exists }).Count), $Global:GuiReadyDllGroups['FOD提供'].Count) 'INFO'
    Write-Log ('  桌面体验专属  : {0}/{1} 存在' -f (($dlls | Where-Object { $_.Group -eq '桌面体验专属' -and $_.Exists }).Count), $Global:GuiReadyDllGroups['桌面体验专属'].Count) 'INFO'
    if ($coreMissing.Count -gt 0) {
        Write-Log ('  缺失的核心模块（异常）: ' + (($coreMissing | ForEach-Object { $_.Name }) -join ', ')) 'ERROR'
    }
    if ($fodMissing.Count -gt 0) {
        Write-Log ('  缺失的 FOD 组件: ' + (($fodMissing | ForEach-Object { $_.Name }) -join ', ')) 'WARN'
    }
    if ($deskMissing.Count -gt 0) {
        Write-Log ('  缺失的桌面体验组件: ' + (($deskMissing | ForEach-Object { $_.Name }) -join ', ')) 'WARN'
    }

    Write-Log '读取远程桌面（RDP）配置...' 'STEP'
    $rdp = Get-GuiReadyRdp
    Write-Log ('  允许连接 fDenyTSConnections=0 : {0}' -f (Format-Bool $rdp.RdpEnabled)) 'INFO'
    Write-Log ('  端口 : {0}    监听中 : {1}' -f $rdp.Port, (Format-Bool $rdp.Listening3389)) 'INFO'
    Write-Log ('  NLA(UserAuthentication) : {0}    色深 : {1}' -f $rdp.NlaRequired, $rdp.ColorDepth) 'INFO'
    Write-Log ('  会话列表 :') 'INFO'
    if ($rdp.ActiveSessions.Count -eq 0) {
        Write-Log '    （无输出）注意：没有任何活动会话时，阶段 B 的代理服务拿不到用户令牌' 'WARN'
    } else {
        foreach ($l in $rdp.ActiveSessions) { Write-Log ('    ' + $l) 'INFO' }
    }
    if ($rdp.WddmPolicyValue -ne $null) {
        Write-Log ('  策略 UseWddmGraphicsDisplayDriver = {0}' -f $rdp.WddmPolicyValue) 'WARN'
    }
    if ($rdp.RdpTcpWddmValues.Count -gt 0) {
        Write-Log ('  RDP-Tcp 中 wddm 相关值: ' + ($rdp.RdpTcpWddmValues -join '; ')) 'INFO'
    }

    Write-Log '检查关键服务...' 'STEP'
    foreach ($s in (Get-GuiReadyServices)) {
        Write-Log ('  {0,-22} {1,-12} {2}' -f $s.Name, $s.Status, $s.Start) 'INFO'
    }
    Write-Log ('  dwm.exe 进程运行中: {0}' -f (Format-Bool (Get-GuiReadyDwmProcess))) 'INFO'

    Write-Log '读取 .NET 运行时状态...' 'STEP'
    $dotnet = $null
    if (Get-Command Get-GuiReadyDotNetStatus -ErrorAction SilentlyContinue) {
        $dotnet = Get-GuiReadyDotNetStatus
        if ($dotnet.DotNetExe) {
            Write-Log ('  dotnet.exe 存在: ' + (Join-Path $dotnet.Root 'dotnet.exe')) 'OK'
        } else {
            Write-Log '  未检测到 C:\Program Files\dotnet\dotnet.exe（.NET 程序会报 You must install .NET）' 'WARN'
        }
        if ($dotnet.Frameworks.Count -gt 0) {
            foreach ($f in ($dotnet.Frameworks | Sort-Object Name, Version)) {
                Write-Log ('  已装 {0} {1}' -f $f.Name, $f.Version) 'INFO'
            }
        } else {
            Write-Log '  没有任何已安装的 .NET 运行时' 'WARN'
        }
    } else {
        Write-Log '  （DotNet 模块未加载，跳过）' 'WARN'
    }

    Write-Log '读取 UAC 与登录会话...' 'STEP'
    $uac = Get-GuiReadyUac
    Write-Log ('  UAC: EnableLUA={0}  ConsentPromptBehaviorAdmin={1}  PromptOnSecureDesktop={2}' -f $uac.EnableLUA, $uac.ConsentPromptBehaviorAdmin, $uac.PromptOnSecureDesktop) 'INFO'
    Write-Log ('  ' + $uac.Note) $(if ($uac.PromptsWillBlock) { 'WARN' } else { 'INFO' })

    $sess = Get-GuiReadySessionInfo
    Write-Log ('  已登录用户会话: {0} 个，其中活动: {1} 个' -f $sess.LoggedOnCount, $sess.ActiveWithUser.Count) 'INFO'
    foreach ($r in $sess.Rows) {
        Write-Log ('    {0,-16} 用户={1,-12} ID={2,-4} 状态={3}' -f $r.SessionName, $r.User, $r.Id, $r.State) 'INFO'
    }
    if ($sess.LoggedOnCount -eq 0) {
        Write-Log '  没有任何已登录用户：GUI 自检无法进行；阶段 B 的 WTSQueryUserToken 也拿不到令牌' 'WARN'
    }
    if ($uac.PromptsWillBlock -and $sess.LoggedOnCount -eq 0) {
        Write-Log '  组合风险：无人登录 + UAC 会弹窗 → 带 requireAdministrator 的安装器在远程执行时会报“操作已被用户取消”' 'WARN'
    }

    $auto = $null
    if (Get-Command Get-GuiReadyAutoLogon -ErrorAction SilentlyContinue) {
        $auto = Get-GuiReadyAutoLogon
        Write-Log '读取开机自动登录配置...' 'STEP'
        Write-Log ('  ' + $auto.Verdict) $(if ($auto.Enabled) { 'OK' } else { 'WARN' })
        Write-Log ('  密码存储方式: {0}   LSA 机密={1}   注册表明文={2}' -f $(if ($auto.Method) { $auto.Method } else { '(无)' }), (Format-Bool $auto.HasLsaSecret), (Format-Bool $auto.HasRegPlaintext)) $(if ($auto.Method -eq 'RegistryPlaintext') { 'WARN' } else { 'INFO' })
        Write-Log ('  AutoLogonCount: ' + $auto.AutoLogonCountState) 'INFO'
        if ($auto.MustFix) { Write-Log ('  需要处理: ' + $auto.MustFix) 'WARN' }
        if (-not $auto.Enabled -and $sess.LoggedOnCount -eq 0) {
            Write-Log '  建议：当前既没开自动登录也没有已登录用户，重启后不会自动出现会话。可开启自动登录（菜单 5 -> 4）。' 'WARN'
        }
    }

    Write-Log '查找安装介质（install.wim / FOD 目录）...' 'STEP'
    $media = Get-GuiReadyMedia
    if ($media.Candidates.Count -eq 0) {
        Write-Log '  未找到。若要走非官方 GUI 补全，需要挂载与当前 build 一致的 Windows Server 安装 ISO。' 'WARN'
    } else {
        foreach ($c in $media.Candidates) { Write-Log ('  ' + $c.Path) 'OK' }
    }
    if ($media.MountedImages.Count -gt 0) {
        Write-Log ('  已挂载镜像: ' + ($media.MountedImages -join '; ')) 'INFO'
    }
    if ($media.CdRomEmpty.Count -gt 0) {
        Write-Log ('  跳过的空光驱（未就绪，探测会阻塞）: ' + ($media.CdRomEmpty -join ', ')) 'INFO'
    }
    if ($media.ScannedRoots.Count -gt 0) {
        Write-Log ('  已扫描的根: ' + ($media.ScannedRoots -join ', ')) 'INFO'
    }

    $assess = Get-GuiReadyAssessment -Static $static -Features $features -Capability $cap -DllScan $dlls -Media $media

    Write-Head '结论'
    Write-Log ('FOD 状态          : {0}' -f $assess.FodState) 'INFO'
    $gsText = [string]$assess.GuiShellState
    if (-not $assess.GuiShellFeatureExists) { $gsText = '功能不存在（2022 Core 无法用 Install-WindowsFeature 补装）' }
    Write-Log ('Server-Gui-Shell  : {0}' -f $gsText) 'INFO'
    Write-Log ('渲染管线          : dwm={0}  dcomp={1}  dwrite={2}  twinui={3}' -f (Format-Bool $assess.HasDwm), (Format-Bool $assess.HasDcomp), (Format-Bool $assess.HasDwrite), (Format-Bool $assess.HasTwinUI)) 'INFO'
    Write-Log ('路线A（官方 FOD） : {0}' -f $assess.RouteA_Note) 'INFO'
    Write-Log ('路线B（补 Gui-Shell）: {0}' -f $assess.RouteB_Note) 'INFO'
    Write-Log ('路线C（虚拟机回退）: {0}' -f $assess.RouteC_Note) 'INFO'
    Write-Log ('路线D（注入桌面体验包）: {0}' -f $assess.RouteD_Note) 'WARN'
    Write-Log ''
    Write-Log $assess.Conclusion 'OK'

    $report = [ordered]@{
        Static     = $static
        Features   = $features
        Capability = $cap
        DllScan    = $dlls
        Rdp        = $rdp
        Services   = @(Get-GuiReadyServices)
        Media      = $media
        DotNet     = $dotnet
        Uac        = $uac
        Sessions   = $sess
        AutoLogon  = $auto
        Assessment = $assess
    }

    if (-not $Quiet) {
        $p = Save-JsonReport -Object $report -Name 'detect'
        if ($p) { Write-Log '把上面这份报告（或 reports 目录里的 JSON）发回来，我就能按真实数据继续。' 'INFO' }
    }

    $Global:GuiReadyReport = $report
    return $report
}

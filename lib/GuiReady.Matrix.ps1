# GuiReady matrix: per-version / per-SKU knowledge and capability-gap mapping

# Entries marked Verified=$true were measured on a real machine during development.
# Entries marked Verified=$false are整理自官方文档，未在本工具开发环境实测，使用前请以实际探测为准。
$Global:GuiReadyOsMatrix = @(
    [pscustomobject]@{
        Build        = 14393
        Name         = 'Windows Server 2016'
        Short        = '2016'
        Verified     = $false
        FodOfflineSubPath = ''
        FodOfflineNote    = '离线源用 FOD 光盘根目录'
        FodProvides       = '设备管理器/磁盘管理/事件查看器/故障转移群集管理器/文件资源管理器/MMC/性能监视器/资源监视器/PowerShell ISE'
        FodMissing        = '任务计划程序、Hyper-V 管理器自 2022 起才随 FOD 提供'
        ExtraNote         = 'IddCx 版本需在目标机上用 IddCxGetVersion 运行时探测'
    }
    [pscustomobject]@{
        Build        = 17763
        Name         = 'Windows Server 2019'
        Short        = '2019'
        Verified     = $false
        FodOfflineSubPath = ''
        FodOfflineNote    = '离线源用 FOD 光盘根目录'
        FodProvides       = '设备管理器/磁盘管理/事件查看器/故障转移群集管理器/文件资源管理器/MMC/性能监视器/资源监视器/PowerShell ISE'
        FodMissing        = '任务计划程序、Hyper-V 管理器自 2022 起才随 FOD 提供'
        ExtraNote         = 'Server Core 首次发布 App Compatibility FOD 的版本'
    }
    [pscustomobject]@{
        Build        = 20348
        Name         = 'Windows Server 2022'
        Short        = '2022'
        Verified     = $true
        FodOfflineSubPath = 'LanguagesAndOptionalFeatures'
        FodOfflineNote    = '离线源需要 Languages and Optional Features ISO 的 \LanguagesAndOptionalFeatures\ 目录'
        FodProvides       = '设备管理器/磁盘管理/事件查看器/故障转移群集管理器/文件资源管理器/MMC/性能监视器/资源监视器/PowerShell ISE/任务计划程序/Hyper-V 管理器'
        FodMissing        = 'twinui.dll（UWP/XAML）、themeservice.dll、themeui.dll、DispBroker.dll 不随 FOD 提供'
        ExtraNote         = '需 2022-01 累积更新 KB5009608 或更高，否则 RDP 连接可能黑屏；IddCx 版本为 0x1700(IDDCX_VERSION_IRON)'
    }
    [pscustomobject]@{
        Build        = 26100
        Name         = 'Windows Server 2025'
        Short        = '2025'
        Verified     = $false
        FodOfflineSubPath = 'LanguagesAndOptionalFeatures'
        FodOfflineNote    = '与 2022 相同，用 Languages and Optional Features ISO'
        FodProvides       = '同 2022 的可选功能清单（MMC/事件查看器/磁盘管理/性能监视器/资源监视器/任务计划程序/Hyper-V 管理器/explorer/ISE）'
        FodMissing        = '需在实际机器上确认（预期与 2022 类似，UWP/XAML 与主题组件不在 FOD 内）'
        ExtraNote         = '默认自带 OpenSSH 服务端；Server Core 同样需要 FOD 才有 MMC 等图形管理工具'
    }
)

$Global:GuiReadyCapabilityRules = @(
    [pscustomobject]@{ Kind='File';    Key='dwm.exe';        Capability='桌面窗口管理器（DWM）合成';       Impact='窗口无合成；依赖 DWM 的现代程序可能启动失败';                 Fix='装 App Compatibility FOD' }
    [pscustomobject]@{ Kind='File';    Key='dcomp.dll';      Capability='DirectComposition';               Impact='WPF / Electron / Chromium 类程序渲染失败';                   Fix='装 App Compatibility FOD' }
    [pscustomobject]@{ Kind='File';    Key='dwrite.dll';     Capability='DirectWrite 文本渲染';            Impact='现代文本渲染不可用，WPF 文字显示异常';                       Fix='装 App Compatibility FOD' }
    [pscustomobject]@{ Kind='File';    Key='uDWM.dll';       Capability='DWM 用户态组件';                  Impact='同 DWM 合成';                                               Fix='装 App Compatibility FOD' }
    [pscustomobject]@{ Kind='File';    Key='dwmcore.dll';    Capability='DWM 核心';                        Impact='同 DWM 合成';                                               Fix='装 App Compatibility FOD' }
    [pscustomobject]@{ Kind='File';    Key='dwmredir.dll';   Capability='DWM 重定向';                      Impact='同 DWM 合成';                                               Fix='装 App Compatibility FOD' }
    [pscustomobject]@{ Kind='File';    Key='explorer.exe';   Capability='文件资源管理器 / 桌面外壳';       Impact='无法浏览文件、无桌面与任务栏';                               Fix='装 App Compatibility FOD' }
    [pscustomobject]@{ Kind='File';    Key='mmc.exe';        Capability='Microsoft 管理控制台';            Impact='所有 .msc 管理单元（磁盘管理/设备管理器/服务）都打不开';     Fix='装 App Compatibility FOD' }
    [pscustomobject]@{ Kind='File';    Key='twinui.dll';     Capability='UWP / XAML 运行时';               Impact='UWP 应用、部分新版设置界面无法运行';                         Fix='官方未提供；需完整桌面体验或改用虚拟机方案' }
    [pscustomobject]@{ Kind='File';    Key='themeservice.dll'; Capability='主题服务（视觉样式）';          Impact='界面为经典无主题外观（程序能用，但外观旧）';                 Fix='官方未提供；非功能性缺失' }
    [pscustomobject]@{ Kind='File';    Key='themeui.dll';    Capability='主题 API';                        Impact='同主题服务';                                                 Fix='官方未提供；非功能性缺失' }
    [pscustomobject]@{ Kind='File';    Key='DispBroker.dll'; Capability='显示配置代理';                    Impact='分辨率/多显示器相关的高级设置受限';                          Fix='官方未提供；RDP 场景影响有限' }
    [pscustomobject]@{ Kind='File';    Key='d3d10warp.dll';  Capability='WARP 软件光栅化';                 Impact='无 GPU 时的软件渲染回退不可用，Chromium 类更依赖 --disable-software-rasterizer'; Fix='装 App Compatibility FOD' }
    [pscustomobject]@{ Kind='Service'; Key='Audiosrv';       Capability='Windows 音频服务';                Impact='QQ 语音/视频、系统提示音、音视频播放的音频输出不可用';       Fix='把 Audiosrv 与 AudioEndpointBuilder 设为自动并启动；远程会话还需 RDP 音频重定向' }
    [pscustomobject]@{ Kind='Service'; Key='AudioEndpointBuilder'; Capability='音频端点枚举';             Impact='同音频服务：音频设备不可用';                                 Fix='同上' }
    [pscustomobject]@{ Kind='Service'; Key='Themes';         Capability='主题服务进程';                    Impact='视觉样式不生效（经典外观）';                                 Fix='随 App Compatibility FOD 提供，Server Core 上通常仍缺失' }
    [pscustomobject]@{ Kind='Service'; Key='Spooler';        Capability='打印后台处理';                    Impact='无法在本机打印';                                             Fix='启动 Print Spooler 服务' }
)

function Get-GuiReadyOsProfile {
    param($Static)

    if (-not $Static) { $Static = Get-GuiReadyStatic }

    $build = 0
    try { $build = [int]$Static.Build } catch { }

    $hit = $null
    foreach ($m in $Global:GuiReadyOsMatrix) {
        if ($m.Build -eq $build) { $hit = $m; break }
    }

    $o = [ordered]@{
        Build          = $build
        Known          = ($null -ne $hit)
        Name           = ''
        Short          = ''
        Verified       = $false
        IsServerCore   = [bool]$Static.IsServerCore
        InstallationType = [string]$Static.InstallationType
        FodOfflineSubPath = ''
        FodOfflineNote    = ''
        FodProvides       = ''
        FodMissing        = ''
        ExtraNote         = ''
        ApplyNote         = ''
    }

    if ($hit) {
        $o.Name                = $hit.Name
        $o.Short               = $hit.Short
        $o.Verified            = $hit.Verified
        $o.FodOfflineSubPath   = $hit.FodOfflineSubPath
        $o.FodOfflineNote      = $hit.FodOfflineNote
        $o.FodProvides         = $hit.FodProvides
        $o.FodMissing          = $hit.FodMissing
        $o.ExtraNote           = $hit.ExtraNote
    } else {
        $o.Name  = ('未收录的版本 (Build {0})' -f $build)
        $o.Short = [string]$build
        $o.ApplyNote = '该 build 不在内置矩阵里，工具会按“通用规则”处理：FOD 能力名用 ServerCore.AppCompatibility，离线源优先找 LanguagesAndOptionalFeatures 目录，找不到再退回 ISO 根目录。'
    }

    if (-not $o.IsServerCore) {
        $o.ApplyNote = '当前是带桌面体验（或客户端）系统，不需要装 FOD；请直接用菜单第 3 项做 GUI 能力自检确认 GUI 可用性。'
    }
    if ($o.Verified) {
        $o.ApplyNote = '本版本的结论已在真实机器上实测验证过。'
    }
    return [pscustomobject]$o
}

function Get-GuiReadyCapabilityGap {
    param(
        $DllScan,
        $Services,
        [string[]]$ExtraFiles = @()
    )

    $rows = New-Object System.Collections.ArrayList

    $dllMap = @{}
    if ($DllScan) { foreach ($d in $DllScan) { $dllMap[$d.Name] = [bool]$d.Exists } }
    $svcMap = @{}
    if ($Services) { foreach ($s in $Services) { $svcMap[$s.Name] = [string]$s.Status } }
    $svcLive = @{}

    foreach ($r in $Global:GuiReadyCapabilityRules) {
        $present = $null
        if ($r.Kind -eq 'File') {
            if ($dllMap.ContainsKey($r.Key)) { $present = $dllMap[$r.Key] }
            else { $present = (Test-Path -LiteralPath (Join-Path (Join-Path $env:windir 'System32') $r.Key)) }
        } elseif ($r.Kind -eq 'Service') {
            $st = ''
            if ($svcMap.ContainsKey($r.Key)) {
                $st = [string]$svcMap[$r.Key]
            } else {
                # 探测的服务清单里没有这一项，就现场查一次，避免把“没扫描到”误判成“不存在”
                try {
                    $svc = Get-Service -Name $r.Key -ErrorAction Stop
                    $st = [string]$svc.Status
                } catch {
                    $st = 'NotPresent'
                }
                $svcLive[$r.Key] = $st
            }
            $present = ($st -ne 'NotPresent' -and $st -ne '')
        }
        if ($null -eq $present) { continue }

        [void]$rows.Add([pscustomobject]@{
            Kind       = $r.Kind
            Key        = $r.Key
            Present    = [bool]$present
            Capability = $r.Capability
            Impact     = $r.Impact
            Fix        = $r.Fix
        })
    }

    foreach ($f in $ExtraFiles) {
        $nm = Split-Path $f -Leaf
        [void]$rows.Add([pscustomobject]@{
            Kind       = 'File'
            Key        = $nm
            Present    = (Test-Path -LiteralPath $f)
            Capability = '自定义检查项'
            Impact     = '由调用方指定'
            Fix        = ''
        })
    }

    $lost = @($rows | Where-Object { -not $_.Present })
    return [pscustomobject]@{
        All      = @($rows)
        Present  = @($rows | Where-Object { $_.Present })
        Lost     = $lost
        LostCount= $lost.Count
    }
}

function Show-GuiReadyMatrix {
    param($Static, $DllScan, $Services, $Sessions, $Uac)

    if (-not $Static) { $Static = Get-GuiReadyStatic }
    $prof = Get-GuiReadyOsProfile -Static $Static

    Write-Head '版本 / SKU 适配矩阵'
    Write-Log ('检测到: {0}  Build {1}  安装类型={2}' -f $prof.Name, $prof.Build, $prof.InstallationType) 'INFO'
    Write-Log ('矩阵收录: {0}   结论依据: {1}' -f (Format-Bool $prof.Known), $(if ($prof.Verified) { '本机实测验证' } else { '按官方文档整理（未实测）' })) 'INFO'
    if ($prof.ApplyNote) { Write-Log ('  ' + $prof.ApplyNote) 'INFO' }

    Write-Log '' 
    Write-Log '本版本 FOD 离线源规则:' 'INFO'
    if ($prof.FodOfflineSubPath) {
        Write-Log ('  用 <ISO盘符>:\{0}\' -f $prof.FodOfflineSubPath) 'INFO'
    } else {
        Write-Log '  用 <FOD光盘盘符>:\（根目录）' 'INFO'
    }
    if ($prof.FodOfflineNote) { Write-Log ('  说明: ' + $prof.FodOfflineNote) 'INFO' }
    if ($prof.ExtraNote)      { Write-Log ('  注意: ' + $prof.ExtraNote) 'INFO' }

    if ($prof.IsServerCore -and $prof.FodProvides) {
        Write-Log ''
        Write-Log 'FOD 提供:' 'INFO'
        Write-Log ('  ' + $prof.FodProvides) 'INFO'
        Write-Log 'FOD 不提供（官方范围内无法补齐）:' 'WARN'
        Write-Log ('  ' + $prof.FodMissing) 'WARN'
    }

    Write-Log ''
    Write-Log '能力差距（组件/服务 → 受影响的真实功能）:' 'HEAD'
    $gap = Get-GuiReadyCapabilityGap -DllScan $DllScan -Services $Services

    foreach ($g in $gap.Lost) {
        Write-Log ('  [缺失] {0,-22} → {1}' -f $g.Key, $g.Capability) 'WARN'
        Write-Log ('           影响: {0}' -f $g.Impact) 'INFO'
        if ($g.Fix) { Write-Log ('           处置: {0}' -f $g.Fix) 'INFO' }
    }
    if ($gap.LostCount -eq 0) {
        Write-Log '  没有检测到能力缺失项。' 'OK'
    } else {
        Write-Log ('  共 {0} 项缺失，其中属于“官方无法补齐”的请看上面的 FOD 不提供清单。' -f $gap.LostCount) 'WARN'
    }

    if ($Sessions) {
        Write-Log ''
        Write-Log '会话相关适配:' 'INFO'
        Write-Log ('  已登录用户会话 {0} 个（活动 {1} 个）' -f $Sessions.LoggedOnCount, $Sessions.ActiveWithUser.Count) 'INFO'
        if ($Sessions.LoggedOnCount -eq 0) {
            Write-Log '  没有已登录用户 → 图形程序无法在桌面上显示；请先 RDP 或控制台登录' 'WARN'
        }
        $rdpclip = @($Services | Where-Object { $_.Name -eq 'TermService' })
        Write-Log '  剪贴板重定向（rdpclip）随 RDP 会话自动启动，只在 RDP 连接时可用' 'INFO'
    }

    if ($Uac -and $Uac.PromptsWillBlock) {
        Write-Log ''
        Write-Log '提权适配:' 'WARN'
        Write-Log '  UAC 会弹确认窗，远程无人值守时带 requireAdministrator 的安装器会失败。' 'WARN'
        Write-Log '  可选处置: a) 人工 RDP 点确认  b) 以 SYSTEM 计划任务运行  c) 用 CreateProcess 绕过 ShellExecute  d) 临时改 ConsentPromptBehaviorAdmin=0' 'WARN'
    }

    return [pscustomobject]@{ Profile = $prof; Gap = $gap }
}

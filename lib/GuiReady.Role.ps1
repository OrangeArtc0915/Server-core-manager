# GuiReady 角色与功能管理：图形化封装 Install-WindowsFeature / Uninstall-WindowsFeature。
#
# 规范见 想法.md（角色与功能管理，P0）。取舍：
#   - 只做「列出 → 安装 / 移除」这条最短闭环，不做配置向导；结果（是否需要重启）如实回报。
#   - ServerManager 模块（Get-WindowsFeature）是 Server 系专有；客户端 Windows 只有 DISM 的
#     按需功能（FOD）。两条路都能被精简掉，所以先探测能力再把结论讲清楚，不要假装能装。
#   - FOD 的安装逻辑在 lib\GuiReady.Fod.ps1 里（有它自己的错误码处置），本模块不重复实现，
#     只在页面上把状态显示出来并指向「更多 → 补给」。
#
# 调用方：gui\Run-GuiReadyRole.ps1（列表 / 能力探测）、Run-GuiReadyAction.ps1（安装 / 移除）。

function Get-GuiReadyRoleSupport {
    # 判断本机能不能管角色与功能，以及原因（页面上要如实说明，不能只给一个空列表）
    $serverMgr = $false
    try { $serverMgr = [bool](Get-Module -ListAvailable -Name ServerManager) } catch { }

    $dism = $false
    try { $dism = [bool](Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue) } catch { }

    # ProductType 读注册表比 CIM 快得多：WinNT=客户端、ServerNT=成员服务器、LanmanNT=域控
    $productType = 'Unknown'
    try {
        $productType = [string](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -Name ProductType -ErrorAction Stop).ProductType
    } catch { }

    $serverOs = ($productType -eq 'ServerNT' -or $productType -eq 'LanmanNT')

    $note = ''
    if (-not $serverOs) {
        $note = '当前是客户端 Windows，没有 ServerManager，角色/功能不适用；按需功能（FOD）检测可用。'
    } elseif (-not $serverMgr) {
        $note = '是 Server 系系统，但找不到 ServerManager 模块（可能被精简）。可用 DISM 直接查按需功能。'
    } elseif (-not (Test-IsAdministrator)) {
        $note = '有 ServerManager，但当前不是管理员，只能看不能装。'
    }

    return [pscustomobject]@{
        ServerManager = $serverMgr
        Dism          = $dism
        Administrator = (Test-IsAdministrator)
        ProductType   = $productType
        ServerOs      = $serverOs
        CanManage     = ($serverMgr -and (Test-IsAdministrator))
        Note          = $note
    }
}

function Get-GuiReadyRoleProp {
    # 取属性但不假定它一定存在（Feature 对象的属性集随系统版本略有差异）
    param($Object, [string]$Name, $Default = '')
    try {
        $p = $Object.PSObject.Properties[$Name]
        if ($p -and $null -ne $p.Value) { return $p.Value }
    } catch { }
    return $Default
}

function Get-GuiReadyRoleList {
    # Server 角色 / 功能清单。没有 ServerManager 时返回空数组 ——
    # 「为什么空」由 Get-GuiReadyRoleSupport 的 Note 负责说明，不要在这里编数据。
    param([switch]$InstalledOnly)

    if (-not (Get-GuiReadyRoleSupport).ServerManager) { return @() }

    $items = @()
    try {
        Import-Module ServerManager -ErrorAction Stop
        foreach ($f in @(Get-WindowsFeature)) {
            $installed = [bool](Get-GuiReadyRoleProp $f 'Installed' $false)
            if ($InstalledOnly -and -not $installed) { continue }

            $dep = @()
            try {
                foreach ($d in @(Get-GuiReadyRoleProp $f 'DependsOn' @())) { if ($d) { $dep += [string]$d } }
            } catch { }

            $items += [pscustomobject]@{
                Name         = [string](Get-GuiReadyRoleProp $f 'Name')
                DisplayName  = [string](Get-GuiReadyRoleProp $f 'DisplayName')
                Installed    = $installed
                InstallState = [string](Get-GuiReadyRoleProp $f 'InstallState')
                FeatureType  = [string](Get-GuiReadyRoleProp $f 'FeatureType')
                Parent       = [string](Get-GuiReadyRoleProp $f 'Parent')
                DependsOn    = $dep
                Note         = [string](Get-GuiReadyRoleProp $f 'Description')
            }
        }
    } catch {
        Write-Log ('读取角色列表失败: ' + $_.Exception.Message) 'ERROR'
    }
    return $items
}

function Get-GuiReadyRoleSummary {
    # 给页面上那排胶囊用的统计
    param($Items)
    $all      = @($Items)
    $installed = @($all | Where-Object { $_.Installed })
    $roles     = @($all | Where-Object { $_.FeatureType -eq 'Role' })
    return [pscustomobject]@{
        Total     = $all.Count
        Installed = $installed.Count
        Roles     = $roles.Count
        Available = ($all.Count - $installed.Count)
    }
}

function Install-GuiReadyRole {
    # 装一个 Server 角色/功能。
    #
    # 关于「管理工具」：默认不装 —— Server Core 上装了 MMC 管理单元也用不了（没有 GUI），
    # 常规做法是把 RSAT 装到管理端。需要时用 -WithManagementTools 显式打开。
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$WithManagementTools,
        [switch]$WhatIf
    )

    # 预览放在最前面：即使本机装不了，也要能看清「真跑会执行什么命令」
    $cmdOk = $false
    try { $cmdOk = [bool](Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) } catch { }

    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        Write-Log ('将执行: Install-WindowsFeature -Name {0}{1}' -f $Name, $(if ($WithManagementTools) { ' -IncludeManagementTools' } else { '' })) 'DRY'
        Write-Log '角色安装可能需要重启，安装完我会把「是否需要重启」报给你。' 'DRY'
        if (-not (Get-GuiReadyRoleSupport).ServerManager) { Write-Log '注意：本机没有 ServerManager 模块，这里只是给你看命令。' 'WARN' }
        elseif (-not $cmdOk) { Write-Log '注意：本机找不到 Install-WindowsFeature，这里只是给你看命令。' 'WARN' }
        return $true
    }

    if (-not (Get-GuiReadyRoleSupport).ServerManager) {
        Write-Log '本机没有 ServerManager 模块，装不了 Server 角色/功能。' 'ERROR'
        return $false
    }
    if (-not $cmdOk) {
        Write-Log '找不到 Install-WindowsFeature。' 'ERROR'
        return $false
    }

    if (-not (Test-IsAdministrator)) {
        Write-Log '安装角色需要管理员权限。' 'ERROR'
        return $false
    }

    Write-Log ('安装角色/功能: {0}' -f $Name) 'STEP'
    try {
        $r = Install-WindowsFeature -Name $Name -IncludeManagementTools:$WithManagementTools -ErrorAction Stop
        $ok = [bool](Get-GuiReadyRoleProp $r 'Success' $false)
        $restart = [bool](Get-GuiReadyRoleProp $r 'RestartNeeded' $false)
        $exit = Get-GuiReadyRoleProp $r 'ExitCode' '?'
        Write-Log ('结果: 成功={0}  需要重启={1}  退出码={2}' -f (Format-Bool $ok), (Format-Bool $restart), $exit) $(if ($ok) { 'OK' } else { 'ERROR' })
        if ($restart) { Write-Log '这次安装需要重启才会生效。' 'WARN' }
        return $ok
    } catch {
        Write-Log ('安装失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Remove-GuiReadyRole {
    # 移除一个 Server 角色/功能。默认不重启：先回报，重启交给用户决定。
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$WhatIf
    )

    $cmdOk = $false
    try { $cmdOk = [bool](Get-Command Uninstall-WindowsFeature -ErrorAction SilentlyContinue) } catch { }

    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        Write-Log ('将执行: Uninstall-WindowsFeature -Name {0}（不带 -Restart，是否重启由你决定）' -f $Name) 'DRY'
        if (-not (Get-GuiReadyRoleSupport).ServerManager) { Write-Log '注意：本机没有 ServerManager 模块，这里只是给你看命令。' 'WARN' }
        elseif (-not $cmdOk) { Write-Log '注意：本机找不到 Uninstall-WindowsFeature，这里只是给你看命令。' 'WARN' }
        return $true
    }

    if (-not (Get-GuiReadyRoleSupport).ServerManager) {
        Write-Log '本机没有 ServerManager 模块，管不了 Server 角色/功能。' 'ERROR'
        return $false
    }
    if (-not $cmdOk) {
        Write-Log '找不到 Uninstall-WindowsFeature。' 'ERROR'
        return $false
    }

    if (-not (Test-IsAdministrator)) {
        Write-Log '移除角色需要管理员权限。' 'ERROR'
        return $false
    }

    Write-Log ('移除角色/功能: {0}' -f $Name) 'STEP'
    try {
        $r = Uninstall-WindowsFeature -Name $Name -ErrorAction Stop
        $ok = [bool](Get-GuiReadyRoleProp $r 'Success' $false)
        $restart = [bool](Get-GuiReadyRoleProp $r 'RestartNeeded' $false)
        Write-Log ('结果: 成功={0}  需要重启={1}' -f (Format-Bool $ok), (Format-Bool $restart)) $(if ($ok) { 'OK' } else { 'ERROR' })
        if ($restart) { Write-Log '移除需要重启才会彻底生效。' 'WARN' }
        return $ok
    } catch {
        Write-Log ('移除失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Show-GuiReadyRoleStatus {
    # 「更多」页里的只读动作
    Write-Head '角色与功能：状态'

    $sup = Get-GuiReadyRoleSupport
    Write-Log ('系统类型: {0}（ProductType={1}）' -f $(if ($sup.ServerOs) { 'Windows Server' } else { '客户端 Windows' }), $sup.ProductType) 'INFO'
    Write-Log ('ServerManager 模块: {0}    按需功能(DISM): {1}    管理员: {2}' -f `
        (Format-Bool $sup.ServerManager), (Format-Bool $sup.Dism), (Format-Bool $sup.Administrator)) 'INFO'
    if ($sup.Note) { Write-Log $sup.Note 'WARN' }

    if (-not $sup.ServerManager) {
        Write-Log '没有 ServerManager，跳过角色列表。' 'WARN'
        Write-Log '客户端系统上只有「按需功能」：用「更多 → 补给 → 安装 App Compatibility FOD」那一项。' 'INFO'
        return
    }

    $items = @(Get-GuiReadyRoleList)
    $sum = Get-GuiReadyRoleSummary -Items $items
    Write-Log ('角色/功能共 {0} 项：角色 {1} 项，已安装 {2} 项，未安装 {3} 项。' -f $sum.Total, $sum.Roles, $sum.Installed, $sum.Available) 'OK'

    Write-Log '已安装的角色/功能（最多列 40 项）:' 'HEAD'
    foreach ($i in @($items | Where-Object { $_.Installed } | Select-Object -First 40)) {
        Write-Log ('  [已装] {0,-28} {1}' -f $i.Name, $i.DisplayName) 'OK'
    }
    Write-Log '未安装的角色（最多列 20 项，装之前先看依赖）:' 'HEAD'
    foreach ($i in @($items | Where-Object { -not $_.Installed -and $_.FeatureType -eq 'Role' } | Select-Object -First 20)) {
        Write-Log ('  [未装] {0,-28} {1}' -f $i.Name, $i.DisplayName) 'INFO'
    }
}

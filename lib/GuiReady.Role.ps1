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
    #
    # 缓存：Get-WindowsFeature 在真机上首次要 5~30 秒（用户反馈"读取角色列表好慢"）。
    # 结果写入 state\roles-cache.json，6 小时内直接复用；安装/卸载角色后主动失效。
    param([switch]$InstalledOnly, [switch]$Force)

    if (-not (Get-GuiReadyRoleSupport).ServerManager) { return @() }

    $cacheFile = Join-Path $script:GuiReadyRoot 'state\roles-cache.json'
    if (-not $Force -and (Test-Path -LiteralPath $cacheFile)) {
        try {
            $age = ((Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime).TotalHours
            if ($age -lt 6) {
                # 注意：不要写成 `@(ConvertFrom-Json ...)` ——
                # PowerShell 5.1 把顶层 JSON 数组作为**单个输出对象**返回，
                # @(命令) 不会展开它，208 条读回来会变成 1 条（实测踩到两次）。
                # 必须先赋值给变量，再用 @($var) 展开。
                $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8)
                $cached = @($parsed)
                if ($cached.Count -gt 0) {
                    if ($InstalledOnly) { return @($cached | Where-Object { $_.Installed }) }
                    return $cached
                }
            }
        } catch { }
    }

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

        # 只有拿到完整列表才写缓存（失败时不要用空列表覆盖旧缓存）。
        if ($items.Count -gt 0 -and -not $InstalledOnly) {
            try {
                $dir = Split-Path -Parent $cacheFile
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [System.IO.File]::WriteAllText($cacheFile,
                    (ConvertTo-Json -InputObject @($items) -Depth 5 -Compress),
                    (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
        }
    } catch {
        Write-Log ('读取角色列表失败: ' + $_.Exception.Message) 'ERROR'
    }
    return $items
}

function Clear-GuiReadyRoleCache {
    # 角色安装/卸载后让缓存失效，下次读取会重新枚举。
    try {
        $f = Join-Path $script:GuiReadyRoot 'state\roles-cache.json'
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Write-GuiReadyRoleProgress {
    # 把批量安装/移除的进度写进 state\role-progress.json，供 GUI 的界面轮询。
    #
    # 为什么用文件而不是 IPC：动作跑在独立子进程里（这是硬约束，见项目架构），
    # GUI 只能靠磁盘上的文件知道「现在装到第几项」。写入用 tmp + Move，读的一方不会读到半个 JSON。
    param(
        [string]$Stage = 'install',          # install | remove | done
        [int]$Total = 0,
        [int]$Current = 0,
        [string]$CurrentName = '',
        [string[]]$Succeeded = @(),
        [string[]]$Failed = @(),
        [string[]]$RestartItems = @(),
        [bool]$RestartNeeded = $false,
        [string]$Note = ''
    )
    try {
        $p = Join-Path $script:GuiReadyRoot 'state\role-progress.json'
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $o = [ordered]@{
            Updated      = (Get-Date).ToString('o')
            Stage        = $Stage
            Total        = $Total
            Current      = $Current
            CurrentName  = $CurrentName
            Succeeded    = @($Succeeded)
            Failed       = @($Failed)
            RestartItems = @($RestartItems)
            RestartNeeded = $RestartNeeded
            Note         = $Note
        }
        $tmp = $p + '.tmp'
        [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $o -Depth 4 -Compress),
            (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $p -Force
    } catch { }
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

    # 供批量循环汇总「哪些项需要重启」：Install-WindowsFeature 的返回值里没有可累计的字段
    $script:GuiReadyRoleLastRestart = $false

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
        if ($restart) {
            $script:GuiReadyRoleLastRestart = $true
            Write-Log '这次安装需要重启才会生效。' 'WARN'
        }
        if ($ok) { Clear-GuiReadyRoleCache }
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

    $script:GuiReadyRoleLastRestart = $false

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
        if ($restart) {
            $script:GuiReadyRoleLastRestart = $true
            Write-Log '移除需要重启才会彻底生效。' 'WARN'
        }
        if ($ok) { Clear-GuiReadyRoleCache }
        return $ok
    } catch {
        Write-Log ('移除失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function ConvertTo-GuiReadyRoleNameList {
    # 把界面传来的逗号分隔字符串 / 数组统一成去重后的名字列表。
    # 角色名只允许字母、数字、点、下划线、连字符（实测 Get-WindowsFeature 的 Name 都是这种）。
    param([string[]]$Name)

    $out = New-Object System.Collections.ArrayList
    foreach ($raw in @($Name)) {
        foreach ($one in (([string]$raw) -split ',')) {
            $n = $one.Trim()
            if (-not $n) { continue }
            if ($n -notmatch '^[A-Za-z0-9._-]+$') {
                Write-Log ('跳过非法角色名: ' + $n) 'ERROR'
                continue
            }
            if (-not ($out -contains $n)) { [void]$out.Add($n) }
        }
    }
    return @($out)
}

function Resolve-GuiReadyRoleClosure {
    # 把 DependsOn 递归展开，得到「依赖在前、请求项在后」的安装顺序。
    #
    # 为什么要自己做一遍：Get-WindowsFeature 只给直接依赖，界面以前只把它显示出来、
    # 并没有代装（想法.md 里记的已知缺口）。批量装时先装依赖，失败点更清楚。
    # 已安装的项由调用方跳过；这里只负责展开与排序。
    param([string[]]$Name)

    $all = @(Get-GuiReadyRoleList)
    $map = @{}
    foreach ($i in $all) {
        $k = ([string]$i.Name).ToLower()
        if ($k) { $map[$k] = $i }
    }

    $order   = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $seen    = @{}

    # 递归用 scriptblock（PowerShell 的嵌套函数会随作用域丢失，scriptblock 读父作用域变量可靠）。
    $visit = $null
    $visit = {
        param([string]$n)
        $k = $n.ToLower()
        if ($seen.ContainsKey($k)) { return }
        $seen[$k] = $true
        if (-not $map.ContainsKey($k)) {
            # 清单里没有（读列表失败 / 名称拼错）：仍放进安装顺序，让 Install-WindowsFeature 给出准确结论
            [void]$missing.Add($n)
            [void]$order.Add($n)
            return
        }
        foreach ($d in @($map[$k].DependsOn)) {
            $dn = ([string]$d).Trim()
            if ($dn) { & $visit $dn }
        }
        [void]$order.Add($n)
    }

    foreach ($n in @($Name)) {
        $t = ([string]$n).Trim()
        if ($t) { & $visit $t }
    }

    return [pscustomobject]@{
        Order   = @($order)
        Missing = @($missing)
        ByName  = $map
    }
}

function Install-GuiReadyRoleBatch {
    # 批量安装角色/功能：依赖自动补齐、依赖先装、单个失败不中断。
    # 单个安装（界面的「安装」按钮）也走这里 —— 这样依赖同样会被显式展开并记进日志。
    param(
        [Parameter(Mandatory = $true)][string[]]$Name,
        [switch]$WithManagementTools,
        [switch]$WhatIf
    )

    $names = @(ConvertTo-GuiReadyRoleNameList -Name $Name)
    if ($names.Count -eq 0) {
        Write-Log '没有要安装的角色/功能（名称是空的）。' 'ERROR'
        return $false
    }

    $plan = Resolve-GuiReadyRoleClosure -Name $names
    $todo = New-Object System.Collections.ArrayList
    $skip = New-Object System.Collections.ArrayList
    foreach ($n in @($plan.Order)) {
        $k = ([string]$n).ToLower()
        $it = $null
        if ($plan.ByName.ContainsKey($k)) { $it = $plan.ByName[$k] }
        if ($it -and [bool]$it.Installed) { [void]$skip.Add($n) } else { [void]$todo.Add($n) }
    }
    foreach ($m in @($plan.Missing)) {
        Write-Log ('注意：本机角色清单里没有 {0}，仍会尝试安装。' -f $m) 'WARN'
    }

    Write-Head ('安装角色/功能: {0}（依赖已自动展开）' -f (@($names) -join ', '))
    if ($skip.Count -gt 0) { Write-Log ('已安装，跳过: ' + (@($skip) -join ', ')) 'INFO' }
    if ($todo.Count -eq 0) {
        Write-Log '这些角色/功能都已安装，无需操作。' 'OK'
        Write-GuiReadyRoleProgress -Stage 'done' -Total 0 -Current 0 -Note '全部已安装' -RestartNeeded $false
        return $true
    }
    Write-Log ('将依次安装 {0} 项（依赖在前）: {1}' -f $todo.Count, (@($todo) -join ', ')) 'INFO'

    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        $i = 0
        foreach ($n in $todo) {
            $i++
            Write-Log ('  [{0}/{1}] Install-WindowsFeature -Name {2}{3}' -f $i, $todo.Count, $n, $(if ($WithManagementTools) { ' -IncludeManagementTools' } else { '' })) 'DRY'
        }
        return $true
    }

    # 进度文件：GUI 在「执行中」阶段轮询它显示 3/17（18%）：当前项
    Write-GuiReadyRoleProgress -Stage 'install' -Total $todo.Count -Current 0 -Note ((@($names)) -join ',')

    $done = @()
    $failed = @()
    $restartItems = @()
    $needRestart = $false
    $i = 0
    foreach ($n in $todo) {
        $i++
        Write-GuiReadyRoleProgress -Stage 'install' -Total $todo.Count -Current $i -CurrentName $n `
            -Succeeded $done -Failed $failed -RestartItems $restartItems -RestartNeeded $needRestart
        Write-Log ('[{0}/{1}] {2}' -f $i, $todo.Count, $n) 'STEP'
        $ok = $false
        try {
            $ok = [bool](Install-GuiReadyRole -Name $n -WithManagementTools:$WithManagementTools)
        } catch {
            Write-Log ('安装异常: ' + $_.Exception.Message) 'ERROR'
            $ok = $false
        }
        if ($ok) {
            $done += $n
            if ($script:GuiReadyRoleLastRestart) {
                $needRestart = $true
                $restartItems += $n
            }
        } else {
            $failed += $n
        }
        Write-GuiReadyRoleProgress -Stage 'install' -Total $todo.Count -Current $i -CurrentName $n `
            -Succeeded $done -Failed $failed -RestartItems $restartItems -RestartNeeded $needRestart
    }

    Write-Head '安装结果'
    Write-Log ('成功 {0} 项，失败 {1} 项。' -f $done.Count, $failed.Count) $(if ($failed.Count -eq 0) { 'OK' } else { 'ERROR' })
    foreach ($f in $failed) { Write-Log ('  失败: ' + $f) 'ERROR' }
    if ($needRestart) {
        Write-Log ('需要重启才能生效（{0} 项）: {1}' -f @($restartItems).Count, (@($restartItems) -join ', ')) 'WARN'
    }
    Write-GuiReadyRoleProgress -Stage 'done' -Total $todo.Count -Current $todo.Count `
        -Succeeded $done -Failed $failed -RestartItems $restartItems -RestartNeeded $needRestart
    return ($failed.Count -eq 0)
}

function Remove-GuiReadyRoleBatch {
    # 批量移除角色/功能：单个失败不中断（被其它角色依赖时会失败，属于预期）。
    param(
        [Parameter(Mandatory = $true)][string[]]$Name,
        [switch]$WhatIf
    )

    $names = @(ConvertTo-GuiReadyRoleNameList -Name $Name)
    if ($names.Count -eq 0) {
        Write-Log '没有要移除的角色/功能（名称是空的）。' 'ERROR'
        return $false
    }

    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        foreach ($n in $names) { Write-Log ('将执行: Uninstall-WindowsFeature -Name ' + $n) 'DRY' }
        return $true
    }

    $done = @()
    $failed = @()
    $restartItems = @()
    $needRestart = $false
    $i = 0
    Write-GuiReadyRoleProgress -Stage 'remove' -Total $names.Count -Current 0 -Note (($names) -join ',')
    foreach ($n in $names) {
        $i++
        Write-GuiReadyRoleProgress -Stage 'remove' -Total $names.Count -Current $i -CurrentName $n `
            -Succeeded $done -Failed $failed -RestartItems $restartItems -RestartNeeded $needRestart
        Write-Log ('[{0}/{1}] {2}' -f $i, $names.Count, $n) 'STEP'
        $ok = $false
        try { $ok = [bool](Remove-GuiReadyRole -Name $n) } catch { $ok = $false }
        if ($ok) {
            $done += $n
            if ($script:GuiReadyRoleLastRestart) {
                $needRestart = $true
                $restartItems += $n
            }
        } else {
            $failed += $n
        }
        Write-GuiReadyRoleProgress -Stage 'remove' -Total $names.Count -Current $i -CurrentName $n `
            -Succeeded $done -Failed $failed -RestartItems $restartItems -RestartNeeded $needRestart
    }

    Write-Head '移除结果'
    Write-Log ('成功 {0} 项，失败 {1} 项。' -f $done.Count, $failed.Count) $(if ($failed.Count -eq 0) { 'OK' } else { 'ERROR' })
    foreach ($f in $failed) { Write-Log ('  失败: ' + $f) 'ERROR' }
    if ($needRestart) {
        Write-Log ('需要重启才能彻底生效（{0} 项）: {1}' -f @($restartItems).Count, (@($restartItems) -join ', ')) 'WARN'
    }
    Write-GuiReadyRoleProgress -Stage 'done' -Total $names.Count -Current $names.Count `
        -Succeeded $done -Failed $failed -RestartItems $restartItems -RestartNeeded $needRestart
    return ($failed.Count -eq 0)
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

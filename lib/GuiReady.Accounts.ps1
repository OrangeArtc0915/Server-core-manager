# GuiReady 本地账户：用户 / 组 / 组成员 / 登录会话。
#
# 密码只在本进程内用 SecureString 交给 New-LocalUser / Set-LocalUser，
# 不写日志、不进任务记录（动作参数文件解析后立刻删除，由执行器保证）。
# 删除用户前会挡住两种危险情况：最后一个可用的管理员、当前登录用户。

function Get-GuiReadyLocalAccounts {
    if (Test-GuiReadyLegacyApi 'Get-LocalUser') { return (Get-GuiReadyLegacyLocalAccounts) }
    $users = @()
    $groups = @()
    # 先枚举组和成员，再给用户回填「属于哪些组」：
    # 每个用户逐个组去查成员是 O(用户×组) 次 CIM 调用，实测能拖到十几秒。
    $memberMap = @{}
    try {
        foreach ($g in @(Get-LocalGroup -ErrorAction Stop | Sort-Object Name)) {
            $members = @()
            try {
                $members = @(Get-LocalGroupMember -Group $g.Name -ErrorAction SilentlyContinue)
            } catch { }
            $names = @($members | ForEach-Object { [string]$_.Name })
            $groups += [pscustomobject]@{
                Name        = [string]$g.Name
                Description = [string]$g.Description
                Count       = $names.Count
                Members     = ($names -join ',')
            }
            foreach ($n in $names) {
                $short = ($n -split '\\')[-1].ToLower()
                if (-not $memberMap.ContainsKey($short)) { $memberMap[$short] = @() }
                $memberMap[$short] += [string]$g.Name
            }
        }
    } catch {
        Write-Log ('读取本地组失败：' + $_.Exception.Message) 'WARN'
    }

    try {
        foreach ($u in @(Get-LocalUser -ErrorAction Stop | Sort-Object Name)) {
            $groupsOf = @()
            if ($memberMap.ContainsKey(([string]$u.Name).ToLower())) { $groupsOf = @($memberMap[([string]$u.Name).ToLower()]) }
            $users += [pscustomobject]@{
                Name        = [string]$u.Name
                FullName    = [string]$u.FullName
                Description = [string]$u.Description
                Enabled     = [bool]$u.Enabled
                LastLogon   = $(if ($u.LastLogon) { $u.LastLogon.ToString('yyyy-MM-dd HH:mm') } else { '从未登录' })
                LockedOut   = [bool]$u.LockedOut
                PasswordSet = $(if ($null -ne $u.PasswordLastSet) { $u.PasswordLastSet.ToString('yyyy-MM-dd') } else { '' })
                Groups      = ($groupsOf -join ',')
            }
        }
    } catch {
        Write-Log ('读取本地用户失败：' + $_.Exception.Message) 'WARN'
    }

    $admin = @(); $rdp = @()
    try { $admin = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | ForEach-Object { [string]$_.Name }) } catch { }
    try { $rdp = @(Get-LocalGroupMember -Group 'Remote Desktop Users' -ErrorAction Stop | ForEach-Object { [string]$_.Name }) } catch { }

    return [pscustomobject]@{
        Users     = $users
        Groups    = $groups
        Admins    = $admin
        RdpUsers  = $rdp
        Computer  = $env:COMPUTERNAME
    }
}

function New-GuiReadyLocalUser {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][string]$Password,
          [string]$Description = '',
          [string]$Groups = '',
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (Test-GuiReadyLegacyApi 'Get-LocalUser') {
        return (New-GuiReadyLegacyLocalUser -Name $Name -Password $Password -Description $Description -Groups $Groups -DryRun:$DryRun)
    }
    if ($Name -notmatch '^[A-Za-z0-9._-]{1,20}$') { throw '用户名只允许字母 / 数字 / . _ -，且不超过 20 个字符' }
    if ($Password.Length -lt 6) { throw '密码至少 6 位' }
    if (-not $DryRun -and (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)) { throw ('用户已存在：' + $Name) }

    $groupList = @()
    foreach ($g in ([string]$Groups -split '[;,]')) { if ($g.Trim()) { $groupList += $g.Trim() } }

    if ($DryRun) {
        Write-Log ('[预览] 将创建用户 {0}（描述：{1}），并加入组：{2}' -f $Name, $(if ($Description) { $Description } else { '无' }), $(if ($groupList.Count) { $groupList -join ', ' } else { '无' })) 'DRY'
        return
    }

    $sec = ConvertTo-SecureString $Password -AsPlainText -Force
    $p = @{ Name = $Name; Password = $sec; AccountNeverExpires = $true; PasswordNeverExpires = $true }
    if ($Description) { $p['Description'] = $Description }
    New-LocalUser @p -ErrorAction Stop | Out-Null
    Write-Log ('已创建用户：' + $Name) 'OK'

    foreach ($g in $groupList) {
        try {
            Add-LocalGroupMember -Group $g -Member $Name -ErrorAction Stop
            Write-Log ('  已加入组：' + $g) 'OK'
        } catch {
            Write-Log ('  加入组 {0} 失败：{1}' -f $g, $_.Exception.Message) 'WARN'
        }
    }
}

function Set-GuiReadyLocalUser {
    param([Parameter(Mandatory = $true)][string]$Name,
          [string]$Enabled = '',
          [string]$Password = '',
          [string]$Description = '',
          [string]$Groups = '',
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (Test-GuiReadyLegacyApi 'Get-LocalUser') {
        return (Set-GuiReadyLegacyLocalUser -Name $Name -Enabled $Enabled -Password $Password -Description $Description -Groups $Groups -DryRun:$DryRun)
    }
    $u = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if (-not $u) { throw ('用户不存在：' + $Name) }

    if ($Password -and $Password.Length -lt 6) { throw '密码至少 6 位' }

    if ($DryRun) {
        $what = @()
        if ($Enabled -ne '') { $what += ('启用状态 → ' + $Enabled) }
        if ($Password) { $what += '重设密码' }
        if ($Description) { $what += '改描述' }
        if ($Groups) { $what += ('组成员 → ' + $Groups) }
        Write-Log ('[预览] 用户 {0}：{1}' -f $Name, ($what -join '；')) 'DRY'
        return
    }

    if ($Enabled -ne '') {
        if ($Enabled -eq 'true') { Enable-LocalUser -Name $Name -ErrorAction Stop; Write-Log ('已启用用户：' + $Name) 'OK' }
        else { Disable-LocalUser -Name $Name -ErrorAction Stop; Write-Log ('已禁用用户：' + $Name) 'OK' }
    }
    if ($Password) {
        $sec = ConvertTo-SecureString $Password -AsPlainText -Force
        Set-LocalUser -Name $Name -Password $sec -ErrorAction Stop
        Write-Log ('已重设密码：' + $Name) 'OK'
    }
    if ($Description) {
        Set-LocalUser -Name $Name -Description $Description -ErrorAction Stop
        Write-Log '已更新描述' 'OK'
    }
    if ($Groups) {
        $want = @()
        foreach ($g in ([string]$Groups -split '[;,]')) { if ($g.Trim()) { $want += $g.Trim() } }
        $current = @()
        foreach ($g in @(Get-LocalGroup -ErrorAction SilentlyContinue)) {
            $hit = @(Get-LocalGroupMember -Group $g.Name -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ('*\' + $Name) -or $_.Name -eq $Name })
            if ($hit.Count -gt 0) { $current += [string]$g.Name }
        }
        foreach ($g in $current) {
            if ($want -notcontains $g) {
                try { Remove-LocalGroupMember -Group $g -Member $Name -ErrorAction Stop; Write-Log ('  已移出组：' + $g) 'OK' } catch { Write-Log ('  移出组 {0} 失败：{1}' -f $g, $_.Exception.Message) 'WARN' }
            }
        }
        foreach ($g in $want) {
            if ($current -notcontains $g) {
                try { Add-LocalGroupMember -Group $g -Member $Name -ErrorAction Stop; Write-Log ('  已加入组：' + $g) 'OK' } catch { Write-Log ('  加入组 {0} 失败：{1}' -f $g, $_.Exception.Message) 'WARN' }
            }
        }
    }
}

function Remove-GuiReadyLocalUser {
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (Test-GuiReadyLegacyApi 'Get-LocalUser') {
        return (Remove-GuiReadyLegacyLocalUser -Name $Name -DryRun:$DryRun)
    }
    $u = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if (-not $u) { throw ('用户不存在：' + $Name) }
    if ($env:USERNAME -ieq $Name) { throw '不能删除当前正在使用的账户' }

    $admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
    $isAdmin = @($admins | Where-Object { $_ -like ('*\' + $Name) -or $_ -eq $Name }).Count -gt 0
    if ($isAdmin) {
        $enabledAdmins = 0
        foreach ($a in $admins) {
            $short = ($a -split '\\')[-1]
            $au = Get-LocalUser -Name $short -ErrorAction SilentlyContinue
            if ($au -and $au.Enabled) { $enabledAdmins++ }
        }
        if ($enabledAdmins -le 1) { throw '这是他唯一的可用管理员账户，删除后就再也登不进来了' }
    }

    if ($DryRun) { Write-Log ('[预览] 将删除用户：' + $Name) 'DRY'; return }
    Remove-LocalUser -Name $Name -ErrorAction Stop
    Write-Log ('已删除用户：' + $Name) 'OK'
}

function Get-GuiReadySessions {
    $rows = @()
    try {
        $out = @(quser 2>&1)
        $started = $false
        foreach ($line in $out) {
            $s = [string]$line
            if (-not $started) { if ($s -match '用户名|USERNAME') { $started = $true }; continue }
            if (-not $s.Trim()) { continue }
            # 会话名可能带空格；用固定宽度切不稳，改为按关键列提取
            if ($s -match '^\s*>?\s*(\S+)\s+(\S*)\s+(\d+)\s+(\S+)\s+(.*)$') {
                $rows += [pscustomobject]@{
                    User    = $Matches[1]
                    Session = $Matches[2]
                    Id      = [int]$Matches[3]
                    State   = $Matches[4]
                    Idle    = ($Matches[5] -split '\s{2,}')[0]
                    Current = $s.TrimStart().StartsWith('>')
                }
            }
        }
    } catch { }
    if ($rows.Count -eq 0) {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.UserName) {
            $rows += [pscustomobject]@{ User = [string]$cs.UserName; Session = 'console'; Id = 0; State = 'Active'; Idle = ''; Current = $true }
        }
    }
    return $rows
}

# ---------------------------------------------------------------- 2008 R2 兼容路径
# 2008 R2 没有 LocalAccounts 模块（2016+ 才有），改用 WMI 读取 + net user / net localgroup 写。

function Get-GuiReadyLegacyLocalAccounts {
    $users = @()
    $groups = @()
    $memberMap = @{}
    $byGroup = @{}

    try {
        foreach ($gu in @(Get-WmiObject Win32_GroupUser -ErrorAction Stop)) {
            $g = [string]$gu.GroupComponent
            $p = [string]$gu.PartComponent
            $gm = [regex]::Match($g, 'Name="([^"]+)"')
            $pm = [regex]::Match($p, 'Name="([^"]+)"')
            if (-not $gm.Success -or -not $pm.Success) { continue }
            $gn = $gm.Groups[1].Value
            $pn = $pm.Groups[1].Value
            if (-not $byGroup.ContainsKey($gn)) { $byGroup[$gn] = @() }
            $byGroup[$gn] += $pn
        }
    } catch { }

    try {
        foreach ($g in @(Get-WmiObject Win32_Group -Filter 'LocalAccount=True' -ErrorAction Stop | Sort-Object Name)) {
            $names = @()
            if ($byGroup.ContainsKey([string]$g.Name)) { $names = @($byGroup[[string]$g.Name]) }
            $groups += [pscustomobject]@{
                Name        = [string]$g.Name
                Description = [string]$g.Description
                Count       = $names.Count
                Members     = ($names -join ',')
            }
            foreach ($n in $names) {
                $k = ([string]$n).ToLower()
                if (-not $memberMap.ContainsKey($k)) { $memberMap[$k] = @() }
                $memberMap[$k] += [string]$g.Name
            }
        }
    } catch {
        Write-Log ('读取本地组失败：' + $_.Exception.Message) 'WARN'
    }

    try {
        foreach ($u in @(Get-WmiObject Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop | Sort-Object Name)) {
            $k = ([string]$u.Name).ToLower()
            $groupsOf = @()
            if ($memberMap.ContainsKey($k)) { $groupsOf = @($memberMap[$k]) }
            $users += [pscustomobject]@{
                Name        = [string]$u.Name
                FullName    = [string]$u.FullName
                Description = [string]$u.Description
                Enabled     = (-not [bool]$u.Disabled)
                LastLogon   = ''
                LockedOut   = [bool]$u.Lockout
                PasswordSet = ''
                Groups      = ($groupsOf -join ',')
            }
        }
    } catch {
        Write-Log ('读取本地用户失败：' + $_.Exception.Message) 'WARN'
    }

    $admin = @()
    $rdp = @()
    if ($byGroup.ContainsKey('Administrators')) { $admin = @($byGroup['Administrators']) }
    if ($byGroup.ContainsKey('Remote Desktop Users')) { $rdp = @($byGroup['Remote Desktop Users']) }

    return [pscustomobject]@{
        Users    = $users
        Groups   = $groups
        Admins   = $admin
        RdpUsers = $rdp
        Computer = $env:COMPUTERNAME
    }
}

function Invoke-GuiReadyLegacyNet {
    param([string[]]$Argv)
    $out = @(& net.exe @Argv 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out -join [Environment]::NewLine) }
}

function Test-GuiReadyLegacyUserExists {
    param([string]$Name)
    $r = Invoke-GuiReadyLegacyNet @('user', $Name)
    return ($r.Code -eq 0)
}

function New-GuiReadyLegacyLocalUser {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][string]$Password,
          [string]$Description = '',
          [string]$Groups = '',
          [switch]$DryRun)

    if ($Name -notmatch '^[A-Za-z0-9._-]{1,20}$') { throw '用户名只允许字母 / 数字 / . _ -，且不超过 20 个字符' }
    if ($Password.Length -lt 6) { throw '密码至少 6 位' }
    if (-not $DryRun -and (Test-GuiReadyLegacyUserExists -Name $Name)) { throw ('用户已存在：' + $Name) }

    $groupList = @()
    foreach ($g in ([string]$Groups -split '[;,]')) { if ($g.Trim()) { $groupList += $g.Trim() } }

    if ($DryRun) {
        Write-Log ('[预览] 将创建用户 {0}（描述：{1}），并加入组：{2}' -f $Name, $(if ($Description) { $Description } else { '无' }), $(if ($groupList.Count) { $groupList -join ', ' } else { '无' })) 'DRY'
        return
    }

    $argv = @('user', $Name, $Password, '/add', '/expires:never')
    if ($Description) { $argv += ('/comment:' + $Description) }
    $r = Invoke-GuiReadyLegacyNet $argv
    if ($r.Code -ne 0) { throw ('创建用户失败：' + $r.Output) }
    Write-Log ('已创建用户：' + $Name) 'OK'

    foreach ($g in $groupList) {
        $rg = Invoke-GuiReadyLegacyNet @('localgroup', $g, $Name, '/add')
        if ($rg.Code -eq 0) { Write-Log ('  已加入组：' + $g) 'OK' }
        else { Write-Log ('  加入组 {0} 失败：{1}' -f $g, $rg.Output) 'WARN' }
    }
}

function Set-GuiReadyLegacyLocalUser {
    param([Parameter(Mandatory = $true)][string]$Name,
          [string]$Enabled = '',
          [string]$Password = '',
          [string]$Description = '',
          [string]$Groups = '',
          [switch]$DryRun)

    if (-not (Test-GuiReadyLegacyUserExists -Name $Name)) { throw ('用户不存在：' + $Name) }
    if ($Password -and $Password.Length -lt 6) { throw '密码至少 6 位' }

    if ($DryRun) {
        $what = @()
        if ($Enabled -ne '') { $what += ('启用状态 → ' + $Enabled) }
        if ($Password) { $what += '重设密码' }
        if ($Description) { $what += '改描述' }
        if ($Groups) { $what += ('组成员 → ' + $Groups) }
        Write-Log ('[预览] 用户 {0}：{1}' -f $Name, ($what -join '；')) 'DRY'
        return
    }

    if ($Enabled -ne '') {
        $flag = if ($Enabled -eq 'true') { '/active:yes' } else { '/active:no' }
        $r = Invoke-GuiReadyLegacyNet @('user', $Name, $flag)
        if ($r.Code -ne 0) { throw ('修改启用状态失败：' + $r.Output) }
        Write-Log ('已{0}用户：{1}' -f $(if ($Enabled -eq 'true') { '启用' } else { '禁用' }), $Name) 'OK'
    }
    if ($Password) {
        $r = Invoke-GuiReadyLegacyNet @('user', $Name, $Password)
        if ($r.Code -ne 0) { throw ('重设密码失败：' + $r.Output) }
        Write-Log ('已重设密码：' + $Name) 'OK'
    }
    if ($Description) {
        $r = Invoke-GuiReadyLegacyNet @('user', $Name, ('/comment:' + $Description))
        if ($r.Code -ne 0) { throw ('更新描述失败：' + $r.Output) }
        Write-Log '已更新描述' 'OK'
    }
    if ($Groups) {
        $want = @()
        foreach ($g in ([string]$Groups -split '[;,]')) { if ($g.Trim()) { $want += $g.Trim() } }
        $snap = Get-GuiReadyLegacyLocalAccounts
        $current = @()
        foreach ($u in @($snap.Users)) {
            if ([string]$u.Name -ieq $Name) {
                foreach ($g in ([string]$u.Groups -split ',')) { if ($g.Trim()) { $current += $g.Trim() } }
                break
            }
        }
        foreach ($g in $current) {
            if ($want -notcontains $g) {
                $r = Invoke-GuiReadyLegacyNet @('localgroup', $g, $Name, '/delete')
                if ($r.Code -eq 0) { Write-Log ('  已移出组：' + $g) 'OK' }
                else { Write-Log ('  移出组 {0} 失败：{1}' -f $g, $r.Output) 'WARN' }
            }
        }
        foreach ($g in $want) {
            if ($current -notcontains $g) {
                $r = Invoke-GuiReadyLegacyNet @('localgroup', $g, $Name, '/add')
                if ($r.Code -eq 0) { Write-Log ('  已加入组：' + $g) 'OK' }
                else { Write-Log ('  加入组 {0} 失败：{1}' -f $g, $r.Output) 'WARN' }
            }
        }
    }
}

function Remove-GuiReadyLegacyLocalUser {
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$DryRun)

    if (-not (Test-GuiReadyLegacyUserExists -Name $Name)) { throw ('用户不存在：' + $Name) }
    if ($env:USERNAME -ieq $Name) { throw '不能删除当前正在使用的账户' }

    $snap = Get-GuiReadyLegacyLocalAccounts
    $isAdmin = @($snap.Admins | Where-Object { $_ -like ('*\' + $Name) -or $_ -ieq $Name }).Count -gt 0
    if ($isAdmin) {
        $enabledAdmins = 0
        foreach ($a in @($snap.Admins)) {
            $short = ($a -split '\\')[-1]
            $u = @($snap.Users | Where-Object { [string]$_.Name -ieq $short }) | Select-Object -First 1
            if ($u -and $u.Enabled) { $enabledAdmins++ }
        }
        if ($enabledAdmins -le 1) { throw '这是他唯一的可用管理员账户，删除后就再也登不进来了' }
    }

    if ($DryRun) { Write-Log ('[预览] 将删除用户：' + $Name) 'DRY'; return }
    $r = Invoke-GuiReadyLegacyNet @('user', $Name, '/delete')
    if ($r.Code -ne 0) { throw ('删除失败：' + $r.Output) }
    Write-Log ('已删除用户：' + $Name) 'OK'
}

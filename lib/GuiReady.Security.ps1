# GuiReady 安全与合规：基线检查 + 有限度的一键修复 + 最近的安全事件。
#
# 规范见 想法.md（安全与合规中心，P0）。这一版只做「能在本机直接验证」的项，
# 不做 CIS/STIG 那种几百条的全量基线（那是 MSCT / Windows-Security-Audit-Project 的活）。
#
# 两条硬规矩：
#   1. 只自动修「安全且可逆」的项（防火墙、SMBv1、来宾账户、Defender 实时保护、RDP 的 NLA、
#      密码策略）。改 UAC 这类可能把人锁在门外的项只给建议，不代改。
#   2. 所有判断必须有原始证据（EnableLUA=0、EnableSMB1Protocol=True 这种），
#      不做"看起来不安全"的猜测。
#
# 调用方：gui\Run-GuiReadySecurity.ps1（页面）、Run-GuiReadyAction.ps1（审计 / 修复）。

function New-GuiReadySecurityItem {
    param(
        [string]$Id, [string]$Title, [string]$Category,
        [string]$Status,          # OK | Warn | Fail | Unknown
        [string]$Detail = '', [string]$Advice = '', [string]$Fix = ''
    )
    return [pscustomobject]@{
        Id = $Id; Title = $Title; Category = $Category
        Status = $Status; Detail = $Detail; Advice = $Advice; Fix = $Fix
    }
}

function Get-GuiReadySecurityPolicy {
    # 用 secedit 把本地安全策略导出成 INF 再解析。
    # 为什么不用 net accounts：它的行名是本地化的（中文系统上写「最小密码长度」），
    # 解析字符串会被语言绑定；secedit 导出的是固定英文键名。
    param()
    $out = @{}
    $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    $tmp = Join-Path $env:TEMP ('scm-secpol-{0}.inf' -f $stamp)
    try {
        & secedit /export /cfg $tmp /quiet 2>$null | Out-Null
        if (Test-Path -LiteralPath $tmp) {
            foreach ($line in @(Get-Content -LiteralPath $tmp -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
                    $k = $Matches[1]; $v = $Matches[2]
                    if ($k) { $out[$k] = ([string]$v).Trim('"') }
                }
            }
        }
    } catch { } finally {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
    }
    return $out
}

function Get-GuiReadySecurityAudit {
    param([int]$LogonFailuresLimit = 50)

    $items = @()

    # ---- 1. 防火墙 ----
    try {
        $prof = @(Get-NetFirewallProfile -ErrorAction Stop)
        $off  = @($prof | Where-Object { -not $_.Enabled })
        $detail = (@($prof | ForEach-Object { '{0}={1}' -f $_.Name, $(if ($_.Enabled) { '启用' } else { '关闭' }) }) -join '  ')
        if ($off.Count -eq 0) {
            $items += New-GuiReadySecurityItem -Id 'firewall' -Title 'Windows 防火墙（三个配置文件都开着）' -Category '网络' `
                -Status 'OK' -Detail $detail
        } else {
            $items += New-GuiReadySecurityItem -Id 'firewall' -Title 'Windows 防火墙（三个配置文件都开着）' -Category '网络' `
                -Status 'Fail' -Detail $detail -Advice '有配置文件被关闭，入站连接不再被默认拦截。' -Fix 'firewall'
        }
    } catch {
        $items += New-GuiReadySecurityItem -Id 'firewall' -Title 'Windows 防火墙（三个配置文件都开着）' -Category '网络' `
            -Status 'Unknown' -Detail $_.Exception.Message -Advice '读不到防火墙状态，可能缺 NetSecurity 模块（Server Core 上装 FOD 后才有）。'
    }

    # ---- 2. Defender 实时保护 ----
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $rt = [bool]$mp.RealTimeProtectionEnabled
        $av = [bool]$mp.AntivirusEnabled
        $detail = 'RealTimeProtectionEnabled={0}  AntivirusEnabled={1}' -f $rt, $av
        if ($rt -and $av) {
            $items += New-GuiReadySecurityItem -Id 'defender-rt' -Title 'Defender 实时保护' -Category '恶意软件' `
                -Status 'OK' -Detail $detail
        } else {
            $items += New-GuiReadySecurityItem -Id 'defender-rt' -Title 'Defender 实时保护' -Category '恶意软件' `
                -Status 'Fail' -Detail $detail -Advice '实时保护没开。如果本机用的是第三方杀软，这条可以忽略。' -Fix 'defender-rt'
        }
    } catch {
        $items += New-GuiReadySecurityItem -Id 'defender-rt' -Title 'Defender 实时保护' -Category '恶意软件' `
            -Status 'Unknown' -Detail '取不到 Defender 状态（本机可能没装 Defender 组件）' -Advice 'Server Core 上 Defender 通常随 FOD/角色一起装；没装就用第三方防护或按需安装。'
    }

    # ---- 3. UAC ----
    try {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $lua   = [int](Get-ItemProperty -LiteralPath $k -Name EnableLUA -ErrorAction Stop).EnableLUA
        $cba   = [int](Get-ItemProperty -LiteralPath $k -Name ConsentPromptBehaviorAdmin -ErrorAction Stop).ConsentPromptBehaviorAdmin
        $desk  = [int](Get-ItemProperty -LiteralPath $k -Name PromptOnSecureDesktop -ErrorAction Stop).PromptOnSecureDesktop
        $detail = 'EnableLUA={0}  ConsentPromptBehaviorAdmin={1}  PromptOnSecureDesktop={2}' -f $lua, $cba, $desk
        if ($lua -eq 1) {
            $st = $(if ($cba -eq 0) { 'Warn' } else { 'OK' })
            $items += New-GuiReadySecurityItem -Id 'uac' -Title 'UAC 提权确认' -Category '提权' -Status $st -Detail $detail `
                -Advice $(if ($cba -eq 0) { 'UAC 开着但管理员提权不弹确认（ConsentPromptBehaviorAdmin=0），等于形同虚设。' } else { '' })
        } else {
            $items += New-GuiReadySecurityItem -Id 'uac' -Title 'UAC 提权确认' -Category '提权' -Status 'Fail' -Detail $detail `
                -Advice 'UAC 被整个关掉了。**不建议在本工具里自动打开** —— 远程会话下改这项可能重启后进不去，请用 sconfig 或组策略在能碰到机器的前提下改。'
        }
    } catch {
        $items += New-GuiReadySecurityItem -Id 'uac' -Title 'UAC 提权确认' -Category '提权' -Status 'Unknown' -Detail $_.Exception.Message
    }

    # ---- 4. SMBv1 ----
    try {
        $smb = Get-SmbServerConfiguration -ErrorAction Stop
        $v1 = [bool]$smb.EnableSMB1Protocol
        $items += New-GuiReadySecurityItem -Id 'smbv1' -Title 'SMBv1 协议' -Category '网络' `
            -Status $(if ($v1) { 'Fail' } else { 'OK' }) -Detail ('EnableSMB1Protocol={0}' -f $v1) `
            -Advice $(if ($v1) { 'SMBv1 是已废弃的协议（EternalBlue 那批漏洞的入口），除非有老设备必须用，应该关掉。' } else { '' }) `
            -Fix $(if ($v1) { 'smbv1' } else { '' })
    } catch {
        $items += New-GuiReadySecurityItem -Id 'smbv1' -Title 'SMBv1 协议' -Category '网络' -Status 'Unknown' -Detail $_.Exception.Message
    }

    # ---- 5. 来宾账户 ----
    try {
        $guest = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -like '*-501' })
        if ($guest.Count -eq 0) {
            $items += New-GuiReadySecurityItem -Id 'guest' -Title '来宾账户（Guest）' -Category '账户' -Status 'OK' -Detail '本机没有 Guest 账户'
        } else {
            $g = $guest[0]
            $items += New-GuiReadySecurityItem -Id 'guest' -Title '来宾账户（Guest）' -Category '账户' `
                -Status $(if ($g.Enabled) { 'Fail' } else { 'OK' }) -Detail ('{0} 已启用={1}' -f $g.Name, $g.Enabled) `
                -Advice $(if ($g.Enabled) { '来宾账户能无密码登录，应该禁用。' } else { '' }) `
                -Fix $(if ($g.Enabled) { 'guest' } else { '' })
        }
    } catch {
        $items += New-GuiReadySecurityItem -Id 'guest' -Title '来宾账户（Guest）' -Category '账户' -Status 'Unknown' -Detail $_.Exception.Message
    }

    # ---- 6. 管理员组成员 ----
    try {
        # 用固定 SID（S-1-5-32-544）取组，避免中文系统上组名是「Administrators / 管理员」的差异
        $grp = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
        $mem = @(Get-LocalGroupMember -Group $grp.Name -ErrorAction Stop)
        $detail = (@($mem | ForEach-Object { [string]$_.Name }) -join '、')
        $items += New-GuiReadySecurityItem -Id 'admin-count' -Title '本地管理员组成员' -Category '账户' `
            -Status $(if ($mem.Count -le 2) { 'OK' } else { 'Warn' }) -Detail ('共 {0} 个: {1}' -f $mem.Count, $detail) `
            -Advice $(if ($mem.Count -gt 2) { '管理员越多，被横向移动的风险越大 —— 保留必要的最小集合。' } else { '' })
    } catch {
        $items += New-GuiReadySecurityItem -Id 'admin-count' -Title '本地管理员组成员' -Category '账户' -Status 'Unknown' -Detail $_.Exception.Message
    }

    # ---- 7. 共享文件夹 ----
    try {
        $shares = @(Get-SmbShare -ErrorAction Stop | Where-Object { $_.Name -notlike '*$' })
        if ($shares.Count -eq 0) {
            $items += New-GuiReadySecurityItem -Id 'shares' -Title '网络共享（不含默认管理共享）' -Category '网络' -Status 'OK' -Detail '没有额外的共享'
        } else {
            $detail = (@($shares | ForEach-Object { '{0} → {1}' -f $_.Name, $_.Path }) -join '；')
            $items += New-GuiReadySecurityItem -Id 'shares' -Title '网络共享（不含默认管理共享）' -Category '网络' -Status 'Warn' `
                -Detail ('共 {0} 个: {1}' -f $shares.Count, $detail) -Advice '确认每个共享的权限都收敛过（共享权限 + NTFS 权限是叠加的）。'
        }
    } catch {
        $items += New-GuiReadySecurityItem -Id 'shares' -Title '网络共享（不含默认管理共享）' -Category '网络' -Status 'Unknown' -Detail $_.Exception.Message
    }

    # ---- 8. 远程桌面 + NLA ----
    try {
        $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $deny = [int](Get-ItemProperty -LiteralPath $ts -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections
        $nla = $null
        try {
            $nla = [int](Get-ItemProperty -LiteralPath ($ts + '\WinStations\RDP-Tcp') -Name UserAuthentication -ErrorAction Stop).UserAuthentication
        } catch { }
        $detail = 'fDenyTSConnections={0}  UserAuthentication(NLA)={1}' -f $deny, $nla
        if ($deny -eq 1) {
            $items += New-GuiReadySecurityItem -Id 'rdp' -Title '远程桌面' -Category '远程访问' -Status 'OK' -Detail $detail -Advice 'RDP 已关闭。'
        } elseif ($nla -eq 1) {
            $items += New-GuiReadySecurityItem -Id 'rdp' -Title '远程桌面' -Category '远程访问' -Status 'OK' -Detail $detail -Advice 'RDP 开着且启用了 NLA。'
        } else {
            $items += New-GuiReadySecurityItem -Id 'rdp' -Title '远程桌面' -Category '远程访问' -Status 'Warn' -Detail $detail `
                -Advice 'RDP 开着但没强制 NLA，连接阶段不会先要求认证。' -Fix 'rdp-nla'
        }
    } catch {
        $items += New-GuiReadySecurityItem -Id 'rdp' -Title '远程桌面' -Category '远程访问' -Status 'Unknown' -Detail $_.Exception.Message
    }

    # ---- 9. 密码策略（secedit 导出的英文键名）----
    try {
        $pol = Get-GuiReadySecurityPolicy
        if ($pol.Count -eq 0) {
            $items += New-GuiReadySecurityItem -Id 'password-policy' -Title '本地密码与锁定策略' -Category '账户' `
                -Status 'Unknown' -Detail 'secedit 没导出内容（需要管理员权限）'
        } else {
            $minLen  = [int]$(if ($pol.ContainsKey('MinimumPasswordLength')) { $pol['MinimumPasswordLength'] } else { -1 })
            $cx      = [int]$(if ($pol.ContainsKey('PasswordComplexity')) { $pol['PasswordComplexity'] } else { -1 })
            $lockout = [int]$(if ($pol.ContainsKey('LockoutBadCount')) { $pol['LockoutBadCount'] } else { -1 })
            $detail = 'MinimumPasswordLength={0}  PasswordComplexity={1}  LockoutBadCount={2}' -f $minLen, $cx, $lockout
            $bad = @()
            if ($minLen -lt 8)  { $bad += ('最小长度 {0} 小于 8' -f $minLen) }
            if ($cx -ne 1)      { $bad += '未启用复杂度要求' }
            if ($lockout -le 0) { $bad += '没有账户锁定阈值（可无限猜密码）' }
            if ($bad.Count -eq 0) {
                $items += New-GuiReadySecurityItem -Id 'password-policy' -Title '本地密码与锁定策略' -Category '账户' -Status 'OK' -Detail $detail
            } else {
                $items += New-GuiReadySecurityItem -Id 'password-policy' -Title '本地密码与锁定策略' -Category '账户' -Status 'Fail' `
                    -Detail $detail -Advice ((@($bad) -join '；') + '。（域机器上这条会被域策略覆盖，改了也没用。）') -Fix 'password-policy'
            }
        }
    } catch {
        $items += New-GuiReadySecurityItem -Id 'password-policy' -Title '本地密码与锁定策略' -Category '账户' -Status 'Unknown' -Detail $_.Exception.Message
    }

    # ---- 10. 最近 24 小时的登录失败（安全日志，事件 4625）----
    try {
        $since = (Get-Date).AddDays(-1)
        $fail = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = $since } `
                  -MaxEvents $LogonFailuresLimit -ErrorAction Stop)
        $items += New-GuiReadySecurityItem -Id 'logon-failures' -Title '最近 24 小时登录失败' -Category '审计' `
            -Status $(if ($fail.Count -eq 0) { 'OK' } else { 'Warn' }) `
            -Detail ('事件 4625 共 {0} 条（最多取 {1} 条）' -f $fail.Count, $LogonFailuresLimit) `
            -Advice $(if ($fail.Count -gt 0) { '失败的登录可能是暴力破解，也可能只是有人敲错密码；结合来源 IP 看。' } else { '' })
    } catch {
        $items += New-GuiReadySecurityItem -Id 'logon-failures' -Title '最近 24 小时登录失败' -Category '审计' `
            -Status 'Unknown' -Detail '读不到安全日志（需要管理员，且审核登录事件要开着）' `
            -Advice '如果审核策略没开，安全日志里不会有 4625 这类事件 —— 这是审计本身的缺口。'
    }

    return $items
}

function Get-GuiReadySecuritySummary {
    param($Items)
    $all = @($Items)
    return [pscustomobject]@{
        Total   = $all.Count
        Ok      = @($all | Where-Object { $_.Status -eq 'OK' }).Count
        Warn    = @($all | Where-Object { $_.Status -eq 'Warn' }).Count
        Fail    = @($all | Where-Object { $_.Status -eq 'Fail' }).Count
        Unknown = @($all | Where-Object { $_.Status -eq 'Unknown' }).Count
        Fixable = @($all | Where-Object { $_.Fix -and $_.Fix -ne '' }).Count
    }
}

function Invoke-GuiReadySecurityFix {
    # 只处理白名单里的项；其余一律回「请人工处理」。
    # 每个 fix 都要能说清"改了什么"，并且尽量可回退（注册表项先读原值写进日志）。
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [switch]$WhatIf
    )

    $id = $Id.Trim().ToLowerInvariant()

    if ($id -eq 'firewall') {
        if ($WhatIf) {
            Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
            Write-Log '将执行: Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True' 'DRY'
            return $true
        }
        try {
            Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True -ErrorAction Stop
            Write-Log '已把三个防火墙配置文件都打开。' 'OK'
            return $true
        } catch { Write-Log ('设置失败: ' + $_.Exception.Message) 'ERROR'; return $false }
    }

    if ($id -eq 'defender-rt') {
        if ($WhatIf) {
            Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
            Write-Log '将执行: Set-MpPreference -DisableRealtimeMonitoring $false' 'DRY'
            return $true
        }
        try {
            Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
            Write-Log '已打开 Defender 实时保护。' 'OK'
            return $true
        } catch { Write-Log ('设置失败: ' + $_.Exception.Message) 'ERROR'; return $false }
    }

    if ($id -eq 'smbv1') {
        if ($WhatIf) {
            Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
            Write-Log '将执行: Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force' 'DRY'
            Write-Log '注意：彻底生效需要重启；老旧的扫描仪/NAS 可能依赖 SMBv1，关之前先确认。' 'DRY'
            return $true
        }
        try {
            Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
            Write-Log '已关闭 SMBv1 服务端协议（重启后彻底生效）。' 'OK'
            return $true
        } catch { Write-Log ('设置失败: ' + $_.Exception.Message) 'ERROR'; return $false }
    }

    if ($id -eq 'guest') {
        if ($WhatIf) {
            Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
            Write-Log '将执行: Disable-LocalUser（SID 以 -501 结尾的来宾账户）' 'DRY'
            return $true
        }
        try {
            $g = @(Get-LocalUser | Where-Object { $_.SID.Value -like '*-501' })
            if ($g.Count -eq 0) { Write-Log '本机没有来宾账户，无需处理。' 'WARN'; return $true }
            foreach ($u in $g) { Disable-LocalUser -Name $u.Name -ErrorAction Stop }
            Write-Log ('已禁用来宾账户: ' + (@($g | ForEach-Object { $_.Name }) -join '、')) 'OK'
            return $true
        } catch { Write-Log ('设置失败: ' + $_.Exception.Message) 'ERROR'; return $false }
    }

    if ($id -eq 'rdp-nla') {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        if ($WhatIf) {
            Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
            Write-Log ('将把 {0} 的 UserAuthentication 设为 1（强制 NLA）' -f $path) 'DRY'
            return $true
        }
        try {
            $old = '未知'
            try { $old = [string](Get-ItemProperty -LiteralPath $path -Name UserAuthentication -ErrorAction Stop).UserAuthentication } catch { }
            Set-ItemProperty -LiteralPath $path -Name UserAuthentication -Value 1 -Type DWord -ErrorAction Stop
            Write-Log ('已开启 RDP 的 NLA（原值 {0} → 1）。' -f $old) 'OK'
            return $true
        } catch { Write-Log ('设置失败: ' + $_.Exception.Message) 'ERROR'; return $false }
    }

    if ($id -eq 'password-policy') {
        $inf = Join-Path $env:TEMP ('scm-secpol-set-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.inf')
        $db  = Join-Path $env:TEMP ('scm-secpol-set-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.sdb')
        $body = @"
[Unicode]
Unicode=yes
[System Access]
MinimumPasswordLength = 8
PasswordComplexity = 1
LockoutBadCount = 5
LockoutDuration = 15
ResetLockoutCount = 15
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
        if ($WhatIf) {
            Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
            Write-Log '将导出并应用以下本地安全策略（只动 System Access 这一区，不碰别的）:' 'DRY'
            foreach ($l in ($body -split "`r?`n")) { Write-Log ('    ' + $l) 'DRY' }
            Write-Log '说明：锁定 5 次失败 → 锁 15 分钟（**必须带上 LockoutDuration，否则 Windows 的默认是"锁到管理员解锁"**，单管理员机器上会把自己关在门外）。' 'DRY'
            Write-Log '注意：域机器上本地策略会被域策略覆盖。' 'DRY'
            return $true
        }
        try {
            [System.IO.File]::WriteAllText($inf, $body, (New-Object System.Text.UTF8Encoding($false)))
            & secedit /configure /db $db /cfg $inf /areas SECURITYPOLICY /quiet 2>$null | Out-Null
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                Write-Log '已应用：最小密码长度 8、启用复杂度、失败 5 次锁定。' 'OK'
                return $true
            }
            Write-Log ('secedit 返回退出码 {0}。' -f $code) 'ERROR'
            return $false
        } catch {
            Write-Log ('设置失败: ' + $_.Exception.Message) 'ERROR'
            return $false
        } finally {
            try { Remove-Item -LiteralPath $inf -Force -ErrorAction SilentlyContinue } catch { }
            try { Remove-Item -LiteralPath $db  -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    Write-Log ('检查项 {0} 不在可自动修复的白名单里 —— 请按建议人工处理。' -f $Id) 'WARN'
    return $false
}

function Show-GuiReadySecurityAudit {
    # 「更多」页里的只读动作
    Write-Head '安全基线审计（本地可验证项）'
    $items = @(Get-GuiReadySecurityAudit)
    $sum = Get-GuiReadySecuritySummary -Items $items
    Write-Log ('共 {0} 项: 通过 {1}  警告 {2}  不合格 {3}  无法判断 {4}（其中 {5} 项可一键修复）' -f `
        $sum.Total, $sum.Ok, $sum.Warn, $sum.Fail, $sum.Unknown, $sum.Fixable) `
        $(if ($sum.Fail -gt 0) { 'WARN' } else { 'OK' })

    foreach ($c in @($items | Where-Object { $_.Status -ne 'OK' })) {
        $tag = $(switch ($c.Status) { 'Fail' { '不合格' } 'Warn' { '警告' } default { '未知' } })
        Write-Log ('[{0}] {1}' -f $tag, $c.Title) 'WARN'
        if ($c.Detail)  { Write-Log ('     证据: ' + $c.Detail) 'INFO' }
        if ($c.Advice)  { Write-Log ('     建议: ' + $c.Advice) 'INFO' }
        if ($c.Fix)     { Write-Log ('     可修复: 动作里用 security-fix 选 ' + $c.Fix) 'INFO' }
    }
    Write-Log '（通过项已省略；要看全部请跑 GUI 的「安全」页。）' 'INFO'
}

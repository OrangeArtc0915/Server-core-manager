# GuiReady 防火墙：规则列表 / 开放端口 / 启停 / 删除。
#
# 只做入站规则的常用操作；不做「一键关闭防火墙」这类危险开关。
# 规则按 Enabled 与方向过滤，列表限 300 条 —— 服务器上的规则动辄几百条，
# 全量读取（每条都要再查端口过滤器）会把子进程拖到十几秒。

function Get-GuiReadyFirewallRules {
    param([ValidateSet('Inbound', 'Outbound', 'All')][string]$Direction = 'Inbound',
          [string]$Filter = '',
          [int]$Max = 300)
    if (Test-GuiReadyLegacyApi 'Get-NetFirewallRule') {
        return @(Get-GuiReadyLegacyFirewallRules -Direction $Direction -Filter $Filter -Max $Max)
    }
    $rows = @()
    try {
        $rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object {
            ($Direction -eq 'All' -or [string]$_.Direction -eq $Direction) -and
            (-not $Filter -or [string]$_.DisplayName -match [regex]::Escape($Filter) -or [string]$_.Name -match [regex]::Escape($Filter))
        } | Sort-Object DisplayName | Select-Object -First $Max)

        foreach ($r in $rules) {
            $port = ''
            $proto = ''
            try {
                $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
                if ($pf) { $port = (@($pf.LocalPort) -join ','); $proto = [string]$pf.Protocol }
            } catch { }
            $profile = ''
            try { $profile = (@($r.Profile) -join ',') } catch { }
            $rows += [pscustomobject]@{
                Name        = [string]$r.Name
                DisplayName = [string]$r.DisplayName
                Enabled     = ([string]$r.Enabled -eq 'True')
                Direction   = [string]$r.Direction
                Action      = [string]$r.Action
                Profile     = $profile
                Protocol    = $proto
                LocalPort   = $port
                Description = [string]$r.Description
            }
        }
    } catch {
        # 非管理员读防火墙规则会被拒（实测 Access is denied）；明确抛给 runner，
        # 界面才能显示「需要管理员」而不是一个空列表。
        throw ('读取防火墙规则失败（需要管理员权限）：' + $_.Exception.Message)
    }
    return $rows
}

function New-GuiReadyFirewallPort {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][string]$Port,
          [ValidateSet('TCP', 'UDP')][string]$Protocol = 'TCP',
          [ValidateSet('Allow', 'Block')][string]$Action = 'Allow',
          [string]$Profile = 'Any',
          [string]$RemoteAddress = 'Any',
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (Test-GuiReadyLegacyApi 'New-NetFirewallRule') {
        return (New-GuiReadyLegacyFirewallPort -Name $Name -Port $Port -Protocol $Protocol -Action $Action -Profile $Profile -RemoteAddress $RemoteAddress -DryRun:$DryRun)
    }
    $ports = @()
    foreach ($p in ([string]$Port -split '[;,\s]+')) {
        if (-not $p.Trim()) { continue }
        $n = 0
        if (-not [int]::TryParse($p.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt 65535) { throw ('端口不合法：' + $p) }
        $ports += $n
    }
    if ($ports.Count -eq 0) { throw '至少填一个端口' }
    if (-not $Name) { throw '规则名不能为空' }

    if ($DryRun) {
        Write-Log ('[预览] 新建入站规则「{0}」：{1} {2} → {3}（配置文件 {4}，来源 {5}）' -f $Name, $Protocol, ($ports -join ','), $Action, $Profile, $RemoteAddress) 'DRY'
        return
    }
    $exist = Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue
    if ($exist) { throw ('同名规则已存在：' + $Name) }
    New-NetFirewallRule -DisplayName $Name -Direction Inbound -Protocol $Protocol -LocalPort $ports `
        -Action $Action -Profile $Profile -RemoteAddress $RemoteAddress -ErrorAction Stop | Out-Null
    Write-Log ('已新建入站规则「{0}」：{1} {2} → {3}' -f $Name, $Protocol, ($ports -join ','), $Action) 'OK'
    Start-Sleep -Milliseconds 400
    $now = Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue
    Write-Log ('回读规则状态：' + $(if ($now) { [string]$now.Enabled } else { '未找到（可能被组策略覆盖）' })) 'INFO'
}

function Set-GuiReadyFirewallRuleEnabled {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][bool]$Enabled,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (Test-GuiReadyLegacyApi 'Get-NetFirewallRule') {
        return (Set-GuiReadyLegacyFirewallRule -Name $Name -Enabled $Enabled -Remove:$false -DryRun:$DryRun)
    }
    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if (-not $rule) { $rule = Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $rule) { throw ('找不到规则：' + $Name) }
    if ($DryRun) { Write-Log ('[预览] 规则「{0}」→ {1}' -f $rule.DisplayName, $(if ($Enabled) { '启用' } else { '禁用' })) 'DRY'; return }
    if ($Enabled) { Enable-NetFirewallRule -Name $rule.Name -ErrorAction Stop }
    else { Disable-NetFirewallRule -Name $rule.Name -ErrorAction Stop }
    $now = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
    Write-Log ('规则「{0}」现在：{1}' -f $rule.DisplayName, $(if ($now) { [string]$now.Enabled } else { '未知' })) 'OK'
}

function Remove-GuiReadyFirewallRule {
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (Test-GuiReadyLegacyApi 'Get-NetFirewallRule') {
        return (Set-GuiReadyLegacyFirewallRule -Name $Name -Enabled $false -Remove -DryRun:$DryRun)
    }
    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if (-not $rule) { throw ('找不到规则：' + $Name) }
    if ($DryRun) { Write-Log ('[预览] 删除规则「' + $rule.DisplayName + '」') 'DRY'; return }
    Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
    Write-Log ('已删除规则：' + $rule.DisplayName) 'OK'
}

function Get-GuiReadyFirewallProfile {
    if (Test-GuiReadyLegacyApi 'Get-NetFirewallProfile') { return @(Get-GuiReadyLegacyFirewallProfile) }
    $rows = @()
    try {
        foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) {
            $rows += [pscustomobject]@{
                Name    = [string]$p.Name
                Enabled = [bool]$p.Enabled
                Inbound = [string]$p.DefaultInboundAction
                Outbound = [string]$p.DefaultOutboundAction
            }
        }
    } catch { }
    return $rows
}

# ---------------------------------------------------------------- 2008 R2 兼容路径
# 2008 R2 没有 NetSecurity 模块，改用防火墙 COM（HNetCfg.FwPolicy2）+ netsh。
# 规则对象字段与新版对齐，页面不用分叉。

function Convert-GuiReadyFwProfiles {
    param($Mask)
    $m = [int]$Mask
    if ($m -eq 0x7FFFFFFF -or $m -eq -1) { return 'Any' }
    $names = @()
    if ($m -band 1) { $names += 'Domain' }
    if ($m -band 2) { $names += 'Private' }
    if ($m -band 4) { $names += 'Public' }
    if ($names.Count -eq 0) { return 'Any' }
    return ($names -join ',')
}

function Convert-GuiReadyFwProtocol {
    param($Protocol)
    switch ([int]$Protocol) {
        1 { return 'ICMPv4' }
        6 { return 'TCP' }
        17 { return 'UDP' }
        58 { return 'ICMPv6' }
        256 { return 'Any' }
        default { return [string]$Protocol }
    }
}

function New-GuiReadyFwPolicy {
    $fw = New-Object -ComObject HNetCfg.FwPolicy2
    return $fw
}

function Find-GuiReadyLegacyFirewallRule {
    param($Fw, [string]$Name)
    foreach ($r in @($Fw.Rules)) {
        if ([string]$r.Name -eq $Name -or [string]$r.DisplayName -eq $Name) { return $r }
    }
    return $null
}

function Get-GuiReadyLegacyFirewallRules {
    param([string]$Direction = 'Inbound', [string]$Filter = '', [int]$Max = 300)
    $rows = @()
    try {
        $fw = New-GuiReadyFwPolicy
        foreach ($r in @($fw.Rules)) {
            $dir = if ([int]$r.Direction -eq 1) { 'Inbound' } else { 'Outbound' }
            if ($Direction -ne 'All' -and $dir -ne $Direction) { continue }
            $name = [string]$r.Name
            $disp = [string]$r.DisplayName
            if (-not $disp) { $disp = $name }
            if ($Filter -and $disp -notmatch [regex]::Escape($Filter) -and $name -notmatch [regex]::Escape($Filter)) { continue }
            $rows += [pscustomobject]@{
                Name        = $name
                DisplayName = $disp
                Enabled     = [bool]$r.Enabled
                Direction   = $dir
                Action      = $(if ([int]$r.Action -eq 1) { 'Allow' } else { 'Block' })
                Profile     = (Convert-GuiReadyFwProfiles $r.Profiles)
                Protocol    = (Convert-GuiReadyFwProtocol $r.Protocol)
                LocalPort   = [string]$r.LocalPorts
                Description = [string]$r.Description
            }
            if ($rows.Count -ge $Max) { break }
        }
    } catch {
        throw ('读取防火墙规则失败（需要管理员权限）：' + $_.Exception.Message)
    }
    return $rows
}

function New-GuiReadyLegacyFirewallPort {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][string]$Port,
          [ValidateSet('TCP', 'UDP')][string]$Protocol = 'TCP',
          [ValidateSet('Allow', 'Block')][string]$Action = 'Allow',
          [string]$Profile = 'Any',
          [string]$RemoteAddress = 'Any',
          [switch]$DryRun)

    $ports = @()
    foreach ($p in ([string]$Port -split '[;,\s]+')) {
        if (-not $p.Trim()) { continue }
        $n = 0
        if (-not [int]::TryParse($p.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt 65535) { throw ('端口不合法：' + $p) }
        $ports += $n
    }
    if ($ports.Count -eq 0) { throw '至少填一个端口' }
    if (-not $Name) { throw '规则名不能为空' }

    if ($DryRun) {
        Write-Log ('[预览] 新建入站规则「{0}」：{1} {2} → {3}（配置文件 {4}，来源 {5}）' -f $Name, $Protocol, ($ports -join ','), $Action, $Profile, $RemoteAddress) 'DRY'
        return
    }

    $fw = New-GuiReadyFwPolicy
    if (Find-GuiReadyLegacyFirewallRule -Fw $fw -Name $Name) { throw ('同名规则已存在：' + $Name) }

    $act = if ($Action -eq 'Allow') { 'allow' } else { 'block' }
    $prof = 'any'
    switch ($Profile) {
        'Domain'  { $prof = 'domain' }
        'Private' { $prof = 'private' }
        'Public'  { $prof = 'public' }
        default   { $prof = 'any' }
    }
    $remote = if ($RemoteAddress) { $RemoteAddress } else { 'any' }

    & netsh advfirewall firewall add rule name="$Name" dir=in action=$act protocol=$Protocol localport=($ports -join ',') remoteip=$remote profile=$prof | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('netsh 新建规则失败，退出码 ' + $LASTEXITCODE) }
    Write-Log ('已新建入站规则「{0}」：{1} {2} → {3}' -f $Name, $Protocol, ($ports -join ','), $Action) 'OK'
    Start-Sleep -Milliseconds 400
    $now = Find-GuiReadyLegacyFirewallRule -Fw (New-GuiReadyFwPolicy) -Name $Name
    Write-Log ('回读规则状态：' + $(if ($now) { [string]$now.Enabled } else { '未找到（可能被组策略覆盖）' })) 'INFO'
}

function Set-GuiReadyLegacyFirewallRule {
    param([Parameter(Mandatory = $true)][string]$Name,
          [bool]$Enabled = $false,
          [switch]$Remove,
          [switch]$DryRun)

    $fw = New-GuiReadyFwPolicy
    $rule = Find-GuiReadyLegacyFirewallRule -Fw $fw -Name $Name
    if (-not $rule) { throw ('找不到规则：' + $Name) }

    if ($DryRun) {
        if ($Remove) { Write-Log ('[预览] 删除规则「' + [string]$rule.DisplayName + '」') 'DRY' }
        else { Write-Log ('[预览] 规则「{0}」→ {1}' -f $rule.DisplayName, $(if ($Enabled) { '启用' } else { '禁用' })) 'DRY' }
        return
    }

    if ($Remove) {
        $fw.Rules.Remove([string]$rule.Name)
        Write-Log ('已删除规则：' + [string]$rule.DisplayName) 'OK'
        return
    }

    $rule.Enabled = [bool]$Enabled
    $now = Find-GuiReadyLegacyFirewallRule -Fw (New-GuiReadyFwPolicy) -Name $Name
    Write-Log ('规则「{0}」现在：{1}' -f $rule.DisplayName, $(if ($now) { [string]$now.Enabled } else { '未知' })) 'OK'
}

function Get-GuiReadyLegacyFirewallProfile {
    $rows = @()
    try {
        $fw = New-GuiReadyFwPolicy
        $map = @{ 1 = 'Domain'; 2 = 'Private'; 4 = 'Public' }
        foreach ($p in @(1, 2, 4)) {
            $rows += [pscustomobject]@{
                Name     = $map[$p]
                Enabled  = [bool]$fw.FirewallEnabled($p)
                Inbound  = ''
                Outbound = ''
            }
        }
    } catch { }
    return $rows
}

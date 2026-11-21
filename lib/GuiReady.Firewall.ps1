# GuiReady 防火墙：规则列表 / 开放端口 / 启停 / 删除。
#
# 只做入站规则的常用操作；不做「一键关闭防火墙」这类危险开关。
# 规则按 Enabled 与方向过滤，列表限 300 条 —— 服务器上的规则动辄几百条，
# 全量读取（每条都要再查端口过滤器）会把子进程拖到十几秒。

function Get-GuiReadyFirewallRules {
    param([ValidateSet('Inbound', 'Outbound', 'All')][string]$Direction = 'Inbound',
          [string]$Filter = '',
          [int]$Max = 300)
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
    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if (-not $rule) { throw ('找不到规则：' + $Name) }
    if ($DryRun) { Write-Log ('[预览] 删除规则「' + $rule.DisplayName + '」') 'DRY'; return }
    Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
    Write-Log ('已删除规则：' + $rule.DisplayName) 'OK'
}

function Get-GuiReadyFirewallProfile {
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

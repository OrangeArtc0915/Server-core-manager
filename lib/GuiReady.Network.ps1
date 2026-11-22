# GuiReady 网络配置：网卡 / IP / 网关 / DNS / 路由 / 解析测试。
#
# 改 IP 是最容易「把自己关在门外」的操作，所以：
#   * 任何写操作前先把当前配置（Get-NetIPConfiguration + netsh 文本）存到 backup\；
#   * 日志里明确写出「改的是哪块网卡、从什么改成什么」；
#   * 动作支持 -DryRun，先看清要做什么。

function Get-GuiReadyNetAdapters {
    if (Test-GuiReadyLegacyApi 'Get-NetAdapter') { return @(Get-GuiReadyLegacyNetAdapters) }
    $rows = @()
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object ifIndex)
    foreach ($a in $adapters) {
        $ips = @()
        $prefix = ''
        $gw = @()
        $dns = @()
        $dhcp = ''
        try {
            foreach ($ip in @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                $ips += ('{0}/{1}' -f $ip.IPAddress, $ip.PrefixLength)
            }
        } catch { }
        try {
            $cfg = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction Stop
            if ($cfg.IPv4DefaultGateway) { $gw += [string]$cfg.IPv4DefaultGateway.NextHop }
            foreach ($d in @($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 })) {
                foreach ($x in @($d.ServerAddresses)) { if ($x -and ($x -notmatch ':')) { $dns += [string]$x } }
            }
        } catch { }
        try { $dhcp = [string](Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop).Dhcp } catch { }

        $rows += [pscustomobject]@{
            Name        = [string]$a.Name
            Description = [string]$a.InterfaceDescription
            ifIndex     = [int]$a.ifIndex
            Status      = [string]$a.Status
            LinkSpeed   = [string]$a.LinkSpeed
            Mac         = [string]$a.MacAddress
            Ip          = ($ips -join ' ')
            Gateway     = ($gw -join ',')
            Dns         = ($dns -join ',')
            Dhcp        = $dhcp
        }
    }
    return $rows
}

function Get-GuiReadyNetworkStatus {
    $adapters = @(Get-GuiReadyNetAdapters)
    $routes = @()
    if (Test-GuiReadyLegacyApi 'Get-NetRoute') {
        $routes = @(Get-GuiReadyLegacyDefaultRoutes)
    } else {
    try {
        $routes = @(Get-NetRoute -ErrorAction Stop | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
                   Select-Object -First 10 | ForEach-Object {
                       [pscustomobject]@{ IfIndex = [int]$_.ifIndex; NextHop = [string]$_.NextHop; Metric = [int]$_.RouteMetric; IfMetric = [int]$_.InterfaceMetric }
                   })
    } catch { }
    }
    return [pscustomobject]@{
        Adapters = $adapters
        Routes   = $routes
        Hostname = $env:COMPUTERNAME
        DnsCache = $(try { (Get-DnsClientCache -ErrorAction Stop | Measure-Object).Count } catch { 0 })
    }
}

# 把改之前的配置留一份，出问题能照着抄回去
function Save-GuiReadyNetworkBackup {
    param([string]$Tag = 'network')
    $root = $script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'backup'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ('{0}-{1}.txt' -f $Tag, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $lines = @()
    $lines += '# ' + (Get-Date).ToString('o')
    $lines += (Get-GuiReadyNetworkStatus | ConvertTo-Json -Depth 6)
    $lines += ''
    $lines += (netsh interface ipv4 show config 2>&1 | Out-String)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($file, ($lines -join "`r`n"), $utf8)
    Write-Log ('已备份当前网络配置：' + $file) 'INFO'
    return $file
}

function Set-GuiReadyNetworkIp {
    param(
        [Parameter(Mandatory = $true)][string]$Adapter,
        [switch]$Dhcp,
        [string]$Ip = '',
        [int]$PrefixLength = 24,
        [string]$Gateway = '',
        [string]$Dns = '',
        [switch]$DryRun
    )
    Assert-Administrator | Out-Null
    if (Test-GuiReadyLegacyApi 'Get-NetAdapter') {
        return (Set-GuiReadyLegacyNetworkIp -Adapter $Adapter -Dhcp:$Dhcp -Ip $Ip -PrefixLength $PrefixLength -Gateway $Gateway -Dns $Dns -DryRun:$DryRun)
    }
    $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Adapter -or [string]$_.ifIndex -eq $Adapter } | Select-Object -First 1
    if (-not $a) { throw ('找不到网卡：' + $Adapter) }

    $before = @(Get-GuiReadyNetAdapters | Where-Object { $_.ifIndex -eq $a.ifIndex })
    $dnsList = @()
    foreach ($x in ([string]$Dns -split '[;,\s]+')) { if ($x.Trim()) { $dnsList += $x.Trim() } }

    if ($DryRun) {
        Write-Log ('[预览] 网卡 {0}（ifIndex {1}）' -f $a.Name, $a.ifIndex) 'DRY'
        if ($Dhcp) {
            Write-Log '  将切换为 DHCP（自动获取 IP 与 DNS）' 'DRY'
        } else {
            if (-not $Ip) { throw '静态地址模式下 Ip 不能为空' }
            Write-Log ('  将设为 {0}/{1}，网关 {2}' -f $Ip, $PrefixLength, $(if ($Gateway) { $Gateway } else { '（无）' })) 'DRY'
            if ($dnsList.Count -gt 0) { Write-Log ('  DNS：' + ($dnsList -join ', ')) 'DRY' }
        }
        return [pscustomobject]@{ Adapter = $a.Name; Planned = $true; Before = $before }
    }

    Save-GuiReadyNetworkBackup -Tag ('network-' + $a.Name) | Out-Null

    if ($Dhcp) {
        Write-Log ('把 {0} 切到 DHCP…' -f $a.Name) 'STEP'
        foreach ($ip in @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            try { Remove-NetIPAddress -IPAddress $ip.IPAddress -InterfaceIndex $a.ifIndex -Confirm:$false -ErrorAction Stop } catch { Write-Log ('  移除旧地址失败（继续）：' + $_.Exception.Message) 'WARN' }
        }
        try { Remove-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    } else {
        if (-not $Ip) { throw '静态地址模式下 Ip 不能为空' }
        Write-Log ('把 {0} 设为 {1}/{2}…' -f $a.Name, $Ip, $PrefixLength) 'STEP'
        try { Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue } catch { }
        foreach ($old in @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            if ([string]$old.IPAddress -ne $Ip) {
                try { Remove-NetIPAddress -IPAddress $old.IPAddress -InterfaceIndex $a.ifIndex -Confirm:$false -ErrorAction SilentlyContinue } catch { }
            }
        }
        $exist = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $Ip })
        if ($exist.Count -eq 0) {
            if ($Gateway) {
                New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $Ip -PrefixLength $PrefixLength -DefaultGateway $Gateway -ErrorAction Stop | Out-Null
            } else {
                New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $Ip -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null
            }
        }
        if ($dnsList.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $dnsList -ErrorAction Stop
        }
    }

    Start-Sleep -Milliseconds 800
    $after = @(Get-GuiReadyNetAdapters | Where-Object { $_.ifIndex -eq $a.ifIndex })
    foreach ($x in $after) { Write-Log ('  现在：{0} / IP {1} / 网关 {2} / DNS {3} / DHCP {4}' -f $x.Name, $x.Ip, $x.Gateway, $x.Dns, $x.Dhcp) 'OK' }
    return [pscustomobject]@{ Adapter = $a.Name; Before = $before; After = $after }
}

function Set-GuiReadyNetworkAdapter {
    param([Parameter(Mandatory = $true)][string]$Adapter,
          [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable', 'restart')][string]$Action,
          [switch]$DryRun)
    Assert-Administrator | Out-Null
    if (Test-GuiReadyLegacyApi 'Get-NetAdapter') {
        return (Set-GuiReadyLegacyAdapterState -Adapter $Adapter -Action $Action -DryRun:$DryRun)
    }
    $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Adapter -or [string]$_.ifIndex -eq $Adapter } | Select-Object -First 1
    if (-not $a) { throw ('找不到网卡：' + $Adapter) }
    if ($DryRun) { Write-Log ('[预览] 网卡 {0} → {1}' -f $a.Name, $Action) 'DRY'; return }
    Write-Log ('网卡 {0} → {1}' -f $a.Name, $Action) 'STEP'
    switch ($Action) {
        'enable'  { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop }
        'disable' { Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop }
        'restart' { Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop }
    }
    Start-Sleep -Milliseconds 800
    $now = Get-NetAdapter -Name $a.Name -ErrorAction SilentlyContinue
    Write-Log ('现在状态：' + [string]$now.Status) 'OK'
}

function Test-GuiReadyDns {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Server = '')
    if (Test-GuiReadyLegacyApi 'Resolve-DnsName') {
        return (Test-GuiReadyLegacyDns -Name $Name -Server $Server)
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rows = @()
    try {
        if ($Server) {
            $r = @(Resolve-DnsName -Name $Name -Server $Server -ErrorAction Stop)
        } else {
            $r = @(Resolve-DnsName -Name $Name -ErrorAction Stop)
        }
        foreach ($x in $r) {
            $rows += [pscustomobject]@{
                Name    = [string]$x.Name
                Type    = [string]$x.Type
                Value   = $(if ($x.IPAddress) { [string]$x.IPAddress } elseif ($x.NameHost) { [string]$x.NameHost } else { [string]$x.Strings })
                Ttl     = $(if ($x.TTL) { [int]$x.TTL } else { 0 })
                Server  = $Server
            }
        }
    } catch {
        throw ('解析失败：' + $_.Exception.Message)
    } finally {
        $sw.Stop()
    }
    Write-Log ('解析 {0}：{1} 条记录，{2} ms' -f $Name, $rows.Count, $sw.ElapsedMilliseconds) 'OK'
    return [pscustomobject]@{ Items = $rows; Ms = [int]$sw.ElapsedMilliseconds }
}

function Get-GuiReadyRoutes {
    param([int]$Max = 60)
    if (Test-GuiReadyLegacyApi 'Get-NetRoute') { return @(Get-GuiReadyLegacyRoutes -Max $Max) }
    try {
        return @(Get-NetRoute -ErrorAction Stop | Sort-Object DestinationPrefix |
                 Select-Object -First $Max | ForEach-Object {
                     [pscustomobject]@{
                         Destination = [string]$_.DestinationPrefix
                         NextHop     = [string]$_.NextHop
                         Interface   = [string]$_.InterfaceAlias
                         Metric      = [int]$_.RouteMetric
                     }
                 })
    } catch { return @() }
}

# ---------------------------------------------------------------- 2008 R2 兼容路径
# 2008 R2 没有 NetAdapter / NetTCPIP 模块，用 WMI + netsh 做同一件事。
# 返回结构与新版保持一致，页面不用分叉。

function Convert-GuiReadyMaskToPrefix {
    param([string]$Mask)
    if (-not $Mask) { return 24 }
    $bits = 0
    foreach ($o in ([string]$Mask).Split('.')) {
        if (-not $o) { continue }
        $v = [int]$o
        while ($v -gt 0) { $bits += ($v -band 1); $v = $v -shr 1 }
    }
    return $bits
}

function Convert-GuiReadyPrefixToMask {
    param([int]$Prefix)
    if ($Prefix -le 0) { return '0.0.0.0' }
    if ($Prefix -ge 32) { return '255.255.255.255' }
    $m = [uint32]0
    for ($i = 0; $i -lt $Prefix; $i++) { $m = $m -bor ([uint32]1 -shl (31 - $i)) }
    $b = [BitConverter]::GetBytes($m)
    [Array]::Reverse($b)
    return ([System.Net.IPAddress]::new($b)).ToString()
}

function Get-GuiReadyLegacyNic {
    param([string]$Adapter)
    $cfgs = @(Get-WmiObject Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPEnabled })
    foreach ($c in $cfgs) {
        $nic = $null
        try { $nic = Get-WmiObject Win32_NetworkAdapter -Filter ("InterfaceIndex=" + [int]$c.InterfaceIndex) -ErrorAction SilentlyContinue } catch { }
        $name = ''
        if ($nic) { $name = [string]$nic.NetConnectionID }
        if ($name -eq $Adapter -or [string]$c.InterfaceIndex -eq $Adapter) {
            return [pscustomobject]@{ Config = $c; Nic = $nic; Name = $name; Index = [int]$c.InterfaceIndex }
        }
    }
    return $null
}

function Get-GuiReadyLegacyNetAdapters {
    $rows = @()
    $cfgs = @(Get-WmiObject Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPEnabled })
    foreach ($c in $cfgs) {
        $nic = $null
        try { $nic = Get-WmiObject Win32_NetworkAdapter -Filter ("InterfaceIndex=" + [int]$c.InterfaceIndex) -ErrorAction SilentlyContinue } catch { }
        $ips = @()
        $ipArr = @($c.IPAddress)
        $maskArr = @($c.IPSubnet)
        for ($i = 0; $i -lt $ipArr.Count; $i++) {
            $ip = [string]$ipArr[$i]
            if (-not $ip -or $ip -match ':') { continue }
            $mask = ''
            if ($i -lt $maskArr.Count) { $mask = [string]$maskArr[$i] }
            $ips += ('{0}/{1}' -f $ip, (Convert-GuiReadyMaskToPrefix $mask))
        }
        $status = 'Unknown'
        if ($nic) {
            switch ([int]$nic.NetConnectionStatus) {
                2 { $status = 'Up' }
                7 { $status = 'Disconnected' }
                0 { $status = 'Disconnected' }
                default { $status = [string]$nic.NetConnectionStatus }
            }
        }
        $speed = ''
        if ($nic -and $nic.Speed) {
            $bps = [double]$nic.Speed
            if ($bps -ge 1GB) { $speed = ('{0:0.#} Gbps' -f ($bps / 1GB)) }
            elseif ($bps -gt 0) { $speed = ('{0:0} Mbps' -f ($bps / 1MB)) }
        }
        $gw4 = @(@($c.DefaultIPGateway) | Where-Object { $_ -and $_ -notmatch ':' })
        $dns4 = @(@($c.DNSServerSearchOrder) | Where-Object { $_ -and $_ -notmatch ':' })
        $rows += [pscustomobject]@{
            Name        = $(if ($nic) { [string]$nic.NetConnectionID } else { [string]$c.Description })
            Description = [string]$c.Description
            ifIndex     = [int]$c.InterfaceIndex
            Status      = $status
            LinkSpeed   = $speed
            Mac         = [string]$c.MACAddress
            Ip          = ($ips -join ' ')
            Gateway     = ($gw4 -join ',')
            Dns         = ($dns4 -join ',')
            Dhcp        = $(if ($c.DHCPEnabled) { 'Enabled' } else { 'Disabled' })
        }
    }
    return $rows
}

function Get-GuiReadyLegacyDefaultRoutes {
    $rows = @()
    try {
        foreach ($r in @(Get-WmiObject Win32_IP4RouteTable -ErrorAction Stop |
                         Where-Object { $_.Destination -eq '0.0.0.0' } | Select-Object -First 10)) {
            $rows += [pscustomobject]@{
                IfIndex  = [int]$r.InterfaceIndex
                NextHop  = [string]$r.NextHop
                Metric   = [int]$r.Metric1
                IfMetric = 0
            }
        }
    } catch { }
    return $rows
}

function Set-GuiReadyLegacyNetworkIp {
    param([Parameter(Mandatory = $true)][string]$Adapter,
          [switch]$Dhcp,
          [string]$Ip = '',
          [int]$PrefixLength = 24,
          [string]$Gateway = '',
          [string]$Dns = '',
          [switch]$DryRun)

    $hit = Get-GuiReadyLegacyNic -Adapter $Adapter
    if (-not $hit -or -not $hit.Name) { throw ('找不到网卡：' + $Adapter) }
    $name = $hit.Name

    $before = @(Get-GuiReadyNetAdapters | Where-Object { $_.ifIndex -eq $hit.Index })
    $dnsList = @()
    foreach ($x in ([string]$Dns -split '[;,\s]+')) { if ($x.Trim()) { $dnsList += $x.Trim() } }

    if ($DryRun) {
        Write-Log ('[预览] 网卡 {0}（ifIndex {1}）' -f $name, $hit.Index) 'DRY'
        if ($Dhcp) { Write-Log '  将切换为 DHCP（自动获取 IP 与 DNS）' 'DRY' }
        else {
            if (-not $Ip) { throw '静态地址模式下 Ip 不能为空' }
            Write-Log ('  将设为 {0}/{1}，网关 {2}' -f $Ip, $PrefixLength, $(if ($Gateway) { $Gateway } else { '（无）' })) 'DRY'
            if ($dnsList.Count -gt 0) { Write-Log ('  DNS：' + ($dnsList -join ', ')) 'DRY' }
        }
        return [pscustomobject]@{ Adapter = $name; Planned = $true; Before = $before }
    }

    Save-GuiReadyNetworkBackup -Tag ('network-' + $name) | Out-Null

    if ($Dhcp) {
        Write-Log ('把 {0} 切到 DHCP…' -f $name) 'STEP'
        & netsh interface ipv4 set address name="$name" source=dhcp | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('netsh 设置 DHCP 失败，退出码 ' + $LASTEXITCODE) }
        & netsh interface ipv4 set dns name="$name" source=dhcp | Out-Null
    } else {
        if (-not $Ip) { throw '静态地址模式下 Ip 不能为空' }
        $mask = Convert-GuiReadyPrefixToMask -Prefix $PrefixLength
        Write-Log ('把 {0} 设为 {1}/{2}（掩码 {3}）…' -f $name, $Ip, $PrefixLength, $mask) 'STEP'
        if ($Gateway) {
            & netsh interface ipv4 set address name="$name" source=static address=$Ip mask=$mask gateway=$Gateway | Out-Null
        } else {
            & netsh interface ipv4 set address name="$name" source=static address=$Ip mask=$mask gateway=none | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { throw ('netsh 设置地址失败，退出码 ' + $LASTEXITCODE) }
        if ($dnsList.Count -gt 0) {
            & netsh interface ipv4 set dns name="$name" source=static address=$dnsList[0] register=primary | Out-Null
            for ($i = 1; $i -lt $dnsList.Count; $i++) {
                & netsh interface ipv4 add dns name="$name" address=$dnsList[$i] index=($i + 1) | Out-Null
            }
        }
    }

    Start-Sleep -Milliseconds 800
    $after = @(Get-GuiReadyNetAdapters | Where-Object { $_.ifIndex -eq $hit.Index })
    foreach ($x in $after) {
        Write-Log ('  现在：{0} / IP {1} / 网关 {2} / DNS {3} / DHCP {4}' -f $x.Name, $x.Ip, $x.Gateway, $x.Dns, $x.Dhcp) 'OK'
    }
    return [pscustomobject]@{ Adapter = $name; Before = $before; After = $after }
}

function Set-GuiReadyLegacyAdapterState {
    param([Parameter(Mandatory = $true)][string]$Adapter,
          [Parameter(Mandatory = $true)][string]$Action,
          [switch]$DryRun)

    $hit = Get-GuiReadyLegacyNic -Adapter $Adapter
    if (-not $hit -or -not $hit.Name) { throw ('找不到网卡：' + $Adapter) }
    if ($DryRun) { Write-Log ('[预览] 网卡 {0} → {1}' -f $hit.Name, $Action) 'DRY'; return }

    Write-Log ('网卡 {0} → {1}' -f $hit.Name, $Action) 'STEP'
    switch ($Action) {
        'enable'  { & netsh interface set interface name="$($hit.Name)" admin=enabled | Out-Null }
        'disable' { & netsh interface set interface name="$($hit.Name)" admin=disabled | Out-Null }
        'restart' {
            & netsh interface set interface name="$($hit.Name)" admin=disabled | Out-Null
            Start-Sleep -Seconds 2
            & netsh interface set interface name="$($hit.Name)" admin=enabled | Out-Null
        }
    }
    if ($LASTEXITCODE -ne 0) { throw ('netsh 修改网卡状态失败，退出码 ' + $LASTEXITCODE) }
    Start-Sleep -Milliseconds 800
    $now = @(Get-GuiReadyNetAdapters | Where-Object { $_.ifIndex -eq $hit.Index })
    if ($now.Count -gt 0) { Write-Log ('现在状态：' + $now[0].Status) 'OK' }
}

function Test-GuiReadyLegacyDns {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Server = '')

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rows = @()
    $out = @()
    try {
        if ($Server) { $out = @(nslookup $Name $Server 2>&1 | ForEach-Object { [string]$_ }) }
        else { $out = @(nslookup $Name 2>&1 | ForEach-Object { [string]$_ }) }
    } catch {
        throw ('解析失败：' + $_.Exception.Message)
    } finally { $sw.Stop() }

    $seen = @{}
    foreach ($line in $out) {
        foreach ($m in [regex]::Matches($line, '\b([0-9]{1,3}(\.[0-9]{1,3}){3})\b')) {
            $ip = $m.Value
            if ($Server -and $ip -eq $Server) { continue }
            if ($ip -eq '127.0.0.1') { continue }
            if ($seen.ContainsKey($ip)) { continue }
            $seen[$ip] = $true
            $rows += [pscustomobject]@{ Name = $Name; Type = 'A'; Value = $ip; Ttl = 0; Server = $Server }
        }
    }
    if ($rows.Count -eq 0) { throw ('解析失败：nslookup 没有返回地址（' + ($out -join ' ').Trim() + '）') }
    Write-Log ('解析 {0}：{1} 条记录，{2} ms' -f $Name, $rows.Count, $sw.ElapsedMilliseconds) 'OK'
    return [pscustomobject]@{ Items = $rows; Ms = [int]$sw.ElapsedMilliseconds }
}

function Get-GuiReadyLegacyRoutes {
    param([int]$Max = 60)
    $rows = @()
    try {
        foreach ($r in @(Get-WmiObject Win32_IP4RouteTable -ErrorAction Stop |
                         Sort-Object Destination | Select-Object -First $Max)) {
            $prefix = Convert-GuiReadyMaskToPrefix ([string]$r.Mask)
            $alias = ''
            try {
                $nic = Get-WmiObject Win32_NetworkAdapter -Filter ("Index=" + [int]$r.InterfaceIndex) -ErrorAction SilentlyContinue
                if ($nic) { $alias = [string]$nic.NetConnectionID }
            } catch { }
            $rows += [pscustomobject]@{
                Destination = ('{0}/{1}' -f $r.Destination, $prefix)
                NextHop     = [string]$r.NextHop
                Interface   = $alias
                Metric      = [int]$r.Metric1
            }
        }
    } catch { }
    return $rows
}

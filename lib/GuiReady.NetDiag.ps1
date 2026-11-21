# 网络诊断：端口扫描 / 监听端口 / DNS / 代理 / 连通性 / pktmon 抓包。

function Expand-GuiReadyPortSpec {
    param([string]$Spec)
    $ports = New-Object System.Collections.ArrayList
    foreach ($raw in ([string]$Spec -split '[,;，；\s]+')) {
        $t = $raw.Trim()
        if (-not $t) { continue }
        if ($t -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            for ($p = $a; $p -le $b -and $ports.Count -lt 500; $p++) { [void]$ports.Add($p) }
        } else {
            $n = 0
            if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le 65535) { [void]$ports.Add($n) }
            if ($ports.Count -ge 500) { break }
        }
    }
    return @($ports | Select-Object -Unique)
}

function Get-GuiReadyListeningPorts {
    $rows = @()
    try {
        $procs = @{}
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $procs[$p.Id] = $p.ProcessName }
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            $rows += [pscustomobject]@{
                Protocol = 'TCP'; Address = [string]$c.LocalAddress; Port = [int]$c.LocalPort
                PID = [int]$c.OwningProcess
                Process = if ($procs.ContainsKey([int]$c.OwningProcess)) { $procs[[int]$c.OwningProcess] } else { '' }
            }
        }
    } catch { }
    try {
        foreach ($u in @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
            $rows += [pscustomobject]@{
                Protocol = 'UDP'; Address = [string]$u.LocalAddress; Port = [int]$u.LocalPort
                PID = [int]$u.OwningProcess; Process = ''
            }
        }
    } catch { }
    return @($rows | Sort-Object Port)
}

function Test-GuiReadyPortScan {
    param([string]$Target = '127.0.0.1', [string]$Ports = '80,443,3389', [int]$TimeoutMs = 800)
    $list = @(Expand-GuiReadyPortSpec -Spec $Ports)
    if ($list.Count -eq 0) { throw '端口列表为空或格式不对（示例 80,443,1000-1010）。' }
    $owners = @{}
    try {
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            $owners[[int]$c.LocalPort] = [int]$c.OwningProcess
        }
    } catch { }
    $rows = @()
    foreach ($p in $list) {
        $open = $false
        $ms = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect($Target, $p, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                $client.EndConnect($iar)
                $open = $true
            }
        } catch { }
        finally {
            try { $client.Close() } catch { }
            $sw.Stop(); $ms = [int]$sw.ElapsedMilliseconds
        }
        $pid2 = if ($owners.ContainsKey($p)) { [int]$owners[$p] } else { 0 }
        $pname = ''
        if ($pid2 -gt 0) { try { $pname = (Get-Process -Id $pid2 -ErrorAction SilentlyContinue).ProcessName } catch { } }
        $rows += [pscustomobject]@{ Port = $p; Open = $open; LatencyMs = $ms; PID = $pid2; Process = $pname }
    }
    return @($rows)
}

function Resolve-GuiReadyDns {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Server = '')
    $rows = @()
    try {
        if ($Server) { $res = @(Resolve-DnsName -Name $Name -Server $Server -ErrorAction Stop) }
        else { $res = @(Resolve-DnsName -Name $Name -ErrorAction Stop) }
        foreach ($r in $res) {
            $rows += [pscustomobject]@{
                Name = [string]$r.Name; Type = [string]$r.Type
                Value = $(if ($r.IPAddress) { [string]$r.IPAddress } elseif ($r.NameHost) { [string]$r.NameHost } else { [string]$r.String })
                TTL = $(if ($null -ne $r.TTL) { [int]$r.TTL } else { 0 })
            }
        }
    } catch {
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($Name)
            foreach ($a in $addrs) { $rows += [pscustomobject]@{ Name = $Name; Type = 'A/AAAA'; Value = [string]$a; TTL = 0 } }
        } catch { throw ('DNS 解析失败：' + $_.Exception.Message) }
    }
    return @($rows)
}

function Get-GuiReadyProxyInfo {
    $out = @()
    try { $out += (& netsh.exe winhttp show proxy 2>&1 | Out-String) } catch { }
    try {
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        $out += ('ProxyEnable=' + [string]$p.ProxyEnable + ' ProxyServer=' + [string]$p.ProxyServer + ' AutoConfigURL=' + [string]$p.AutoConfigURL)
    } catch { }
    return ($out -join [Environment]::NewLine)
}

function Test-GuiReadyConnectivity {
    param([string]$Targets = '127.0.0.1:445')
    $rows = @()
    foreach ($raw in ([string]$Targets -split '[,;，；\s]+')) {
        $t = $raw.Trim()
        if (-not $t) { continue }
        $host2 = $t; $port = 0
        if ($t -match '^(.*):(\d+)$') { $host2 = $Matches[1]; $port = [int]$Matches[2] }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = $false
        if ($port -gt 0) {
            $c = New-Object System.Net.Sockets.TcpClient
            try {
                $iar = $c.BeginConnect($host2, $port, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(1500)) { $c.EndConnect($iar); $ok = $true }
            } catch { } finally { try { $c.Close() } catch { } }
        } else {
            try { $ok = Test-Connection -ComputerName $host2 -Count 1 -Quiet -ErrorAction Stop } catch { }
        }
        $sw.Stop()
        $rows += [pscustomobject]@{ Target = $t; Ok = $ok; LatencyMs = [int]$sw.ElapsedMilliseconds }
    }
    return @($rows)
}

function Get-GuiReadyCaptureDir {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'reports\netdiag'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Start-GuiReadyPacketCapture {
    param([int]$Seconds = 30, [switch]$DryRun)
    if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $env:windir 'System32\pktmon.exe'))) {
        throw '本机没有 pktmon.exe（Windows Server 2019+ 才自带）。'
    }
    $sec = [Math]::Max(3, [Math]::Min(300, $Seconds))
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $etl = Join-Path (Get-GuiReadyCaptureDir) ('capture-' + $stamp + '.etl')
    $pcap = Join-Path (Get-GuiReadyCaptureDir) ('capture-' + $stamp + '.pcapng')
    if ($DryRun) {
        Write-Log ('[预览] 将抓包 {0} 秒 → {1}' -f $sec, $pcap) 'DRY'
        return [pscustomobject]@{ DryRun = $true; Seconds = $sec; File = $pcap }
    }
    $null = & pktmon.exe start --capture --pkt-size 128 --file $etl 2>&1
    Start-Sleep -Seconds $sec
    $null = & pktmon.exe stop 2>&1
    $conv = & pktmon.exe etl2pcap $etl --out $pcap 2>&1
    if (-not (Test-Path -LiteralPath $pcap)) {
        $conv2 = & pktmon.exe etl2pcap $etl -o $pcap 2>&1
        if (-not (Test-Path -LiteralPath $pcap)) { throw ('抓包已停止，但转换 pcapng 失败：' + (($conv + $conv2) -join ' ')) }
    }
    Write-Log ('抓包完成：' + $pcap) 'OK'
    return [pscustomobject]@{ Seconds = $sec; File = $pcap; Etl = $etl; SizeMB = [Math]::Round((Get-Item -LiteralPath $pcap).Length / 1MB, 2) }
}

function Stop-GuiReadyPacketCapture {
    if (Get-Command pktmon.exe -ErrorAction SilentlyContinue) { $null = & pktmon.exe stop 2>&1 }
    Write-Log '已停止 pktmon 抓包（如果有）。' 'OK'
}

function Get-GuiReadyCaptureFiles {
    $rows = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-GuiReadyCaptureDir) -File -Filter 'capture-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $rows += [pscustomobject]@{ File = $f.Name; SizeMB = [Math]::Round($f.Length / 1MB, 2); Time = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); Path = $f.FullName }
    }
    return @($rows)
}

# GuiReady 内置 TUI 监控（scm-top）
#
# 为什么要有内置版：Server Core 上 btop / glances 都不是系统自带，而它们的 choco 包要从
# GitHub 下载 —— 受限网络里会因证书/代理失败（实测 172.26.154.134：choco 包源可访问，
# github.com 的 TLS 校验失败）。内置版只依赖系统自带的 Get-Counter / CIM，零依赖、离线可用。
#
# 启动方式：仪表盘「TUI 监控」按钮（优先已装的 pstop/htop/btm，没有就启动本脚本）。
# 退出：按 q。

param([int]$IntervalSec = 2)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { [Console]::CursorVisible = $false } catch { }

function Get-ColorByPercent {
    param([double]$Percent)
    if ($Percent -ge 90) { return 'Red' }
    if ($Percent -ge 70) { return 'Yellow' }
    return 'Green'
}

function Write-Bar {
    param([double]$Percent, [int]$Width = 26, [string]$Color = 'Green')
    $p = [Math]::Max(0, [Math]::Min(100, $Percent))
    $n = [int][Math]::Round($p / 100.0 * $Width)
    $bar = ('#' * $n) + ('-' * ($Width - $n))
    Write-Host ('[' + $bar + ']') -NoNewline -ForegroundColor $Color
}

function Get-CpuSamples {
    # 优先 Get-Counter（能拿到每个核心）；失败就退回 CIM 的总负载（精度差但不会空屏）
    $r = [pscustomobject]@{ Total = $null; Cores = @(); Source = '' }
    try {
        $c = Get-Counter '\Processor(*)\% Processor Time' -ErrorAction Stop
        $cores = @()
        foreach ($s in @($c.CounterSamples)) {
            $inst = [string]$s.InstanceName
            $val  = [Math]::Round([double]$s.CookedValue, 1)
            if ($inst -eq '_Total') { $r.Total = $val }
            elseif ($inst -match '^\d+$') { $cores += [pscustomobject]@{ Index = [int]$inst; Percent = $val } }
        }
        $r.Cores  = @($cores | Sort-Object -Property Index)
        $r.Source = 'Get-Counter'
        if ($null -ne $r.Total) { return $r }
    } catch { }

    try {
        $lp = @(Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -ExpandProperty LoadPercentage)
        $vals = @($lp | Where-Object { $null -ne $_ })
        if ($vals.Count -gt 0) {
            $r.Total  = [Math]::Round((($vals | Measure-Object -Average).Average), 1)
            $r.Source = 'CIM（估算）'
        }
    } catch { }
    return $r
}

function Get-MemoryInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalKb = [double]$os.TotalVisibleMemorySize
        $freeKb  = [double]$os.FreePhysicalMemory
        $usedKb  = $totalKb - $freeKb
        return [pscustomobject]@{
            TotalGB = [Math]::Round($totalKb / 1MB, 1)
            UsedGB  = [Math]::Round($usedKb / 1MB, 1)
            Percent = $(if ($totalKb -gt 0) { [Math]::Round($usedKb / $totalKb * 100, 1) } else { 0 })
        }
    } catch { return $null }
}

function Get-DiskInfo {
    $out = @()
    try {
        foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)) {
            $size = [double]$d.Size
            $free = [double]$d.FreeSpace
            if ($size -le 0) { continue }
            $out += [pscustomobject]@{
                Name    = [string]$d.DeviceID
                TotalGB = [Math]::Round($size / 1GB, 1)
                FreeGB  = [Math]::Round($free / 1GB, 1)
                Percent = [Math]::Round(($size - $free) / $size * 100, 1)
            }
        }
    } catch { }
    return @($out)
}

function Get-TopProcess {
    param([int]$Count = 10)
    $out = @()
    try {
        foreach ($p in @(Get-Process -ErrorAction Stop | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First $Count)) {
            $cpu = $null
            try { $cpu = [Math]::Round($p.CPU, 1) } catch { }
            $out += [pscustomobject]@{
                Name  = [string]$p.ProcessName
                Id    = [int]$p.Id
                MemMB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
                CpuSec = $cpu
            }
        }
    } catch { }
    return @($out)
}

function Show-Screen {
    $cpu  = Get-CpuSamples
    $mem  = Get-MemoryInfo
    $disk = @(Get-DiskInfo)
    $proc = @(Get-TopProcess -Count 10)

    try { [Console]::Clear() } catch { }
    Write-Host ''
    Write-Host ('  SCM 内置 TUI 监控   ·   ' + $env:COMPUTERNAME + '   ·   ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ('  每 {0} 秒刷新   ·   按 q 退出' -f $IntervalSec) -ForegroundColor DarkGray
    Write-Host ''

    # ---- CPU ----
    Write-Host '  CPU' -NoNewline -ForegroundColor White
    if ($null -ne $cpu.Total) {
        Write-Host ('  {0,5:0.0} %  ' -f $cpu.Total) -NoNewline -ForegroundColor (Get-ColorByPercent $cpu.Total)
        Write-Bar -Percent $cpu.Total -Color (Get-ColorByPercent $cpu.Total)
        Write-Host ('   ' + $cpu.Source) -ForegroundColor DarkGray
    } else {
        Write-Host '  不可用（取不到 CPU 计数器）' -ForegroundColor Red
    }

    if (@($cpu.Cores).Count -gt 0) {
        $shown = @($cpu.Cores | Select-Object -First 16)
        for ($i = 0; $i -lt $shown.Count; $i += 2) {
            $line = '  '
            foreach ($core in @($shown[$i], $(if ($i + 1 -lt $shown.Count) { $shown[$i + 1] } else { $null }))) {
                if (-not $core) { continue }
                $line += ('核心 {0,-2} ' -f $core.Index)
                Write-Host $line -NoNewline -ForegroundColor DarkGray
                Write-Bar -Percent ([double]$core.Percent) -Width 14 -Color (Get-ColorByPercent $core.Percent)
                Write-Host (' {0,5:0.0}%   ' -f $core.Percent) -NoNewline -ForegroundColor (Get-ColorByPercent $core.Percent)
                $line = '  '
            }
            Write-Host ''
        }
        if (@($cpu.Cores).Count -gt 16) { Write-Host ('  （共 {0} 个核心，只显示前 16 个）' -f @($cpu.Cores).Count) -ForegroundColor DarkGray }
    }
    Write-Host ''

    # ---- 内存 ----
    Write-Host '  内存' -NoNewline -ForegroundColor White
    if ($mem) {
        Write-Host ('  已用 {0,5:0.0} / {1,5:0.0} GB  ' -f $mem.UsedGB, $mem.TotalGB) -NoNewline -ForegroundColor (Get-ColorByPercent $mem.Percent)
        Write-Bar -Percent $mem.Percent -Color (Get-ColorByPercent $mem.Percent)
        Write-Host ('   {0:0.0} %' -f $mem.Percent) -ForegroundColor (Get-ColorByPercent $mem.Percent)
    } else {
        Write-Host '  不可用' -ForegroundColor Red
    }
    Write-Host ''

    # ---- 磁盘 ----
    foreach ($d in $disk) {
        Write-Host ('  磁盘 {0,-3}' -f $d.Name) -NoNewline -ForegroundColor White
        Write-Host ('  已用 {0,5:0.0} %  ' -f $d.Percent) -NoNewline -ForegroundColor (Get-ColorByPercent $d.Percent)
        Write-Bar -Percent $d.Percent -Color (Get-ColorByPercent $d.Percent)
        Write-Host ('   剩余 {0:0.0} / {1:0.0} GB' -f $d.FreeGB, $d.TotalGB) -ForegroundColor DarkGray
    }
    Write-Host ''

    # ---- 进程 ----
    Write-Host '  占内存最多的进程' -ForegroundColor White
    Write-Host ('  {0,-8} {1,10} {2,10}   {3}' -f 'PID', '内存(MB)', 'CPU(秒)', '名称') -ForegroundColor DarkGray
    foreach ($p in $proc) {
        $cpuText = $(if ($null -ne $p.CpuSec) { ('{0:0.0}' -f $p.CpuSec) } else { '-' })
        Write-Host ('  {0,-8} {1,10:0.0} {2,10}   {3}' -f $p.Id, $p.MemMB, $cpuText, $p.Name) -ForegroundColor Gray
    }
    Write-Host ''
}

$quit = $false
try {
    while (-not $quit) {
        Show-Screen
        $deadline = (Get-Date).AddSeconds($IntervalSec)
        while ((Get-Date) -lt $deadline) {
            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Q' -or $k.Key -eq 'Escape') { $quit = $true; break }
                }
            } catch { }
            Start-Sleep -Milliseconds 150
        }
    }
} finally {
    try { [Console]::CursorVisible = $true } catch { }
    try { [Console]::Clear() } catch { }
}

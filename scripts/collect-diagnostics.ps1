# @scm-id collect-diagnostics
# @scm-name 收集诊断包
# @scm-desc 收集系统信息、服务、最近错误事件、网络配置与已装软件，打包到 reports\diagnostics-*.zip。
# @scm-risk low

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$reports = Join-Path $root 'reports'
if (-not (Test-Path -LiteralPath $reports)) { New-Item -ItemType Directory -Path $reports -Force | Out-Null }
$work = Join-Path $env:TEMP ('scm-diag-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        Time = (Get-Date).ToString('o')
        OS = if ($os) { [string]$os.Caption } else { '' }
        Version = if ($os) { [string]$os.Version } else { '' }
        Build = if ($os) { [string]$os.BuildNumber } else { '' }
        LastBoot = if ($os) { [string]$os.LastBootUpTime } else { '' }
    } | ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $work 'system.json') -Encoding UTF8

    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, State, StartMode, PathName |
        Export-Csv -LiteralPath (Join-Path $work 'services.csv') -NoTypeInformation -Encoding UTF8

    Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Select-Object DeviceID, VolumeName, FileSystem, Size, FreeSpace |
        Export-Csv -LiteralPath (Join-Path $work 'disks.csv') -NoTypeInformation -Encoding UTF8

    $since = (Get-Date).AddHours(-24)
    $events = @()
    foreach ($log in @('System', 'Application')) {
        try {
            foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since; Level = 1, 2 } -MaxEvents 200 -ErrorAction Stop)) {
                $events += [pscustomobject]@{
                    Time = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); Log = $log
                    Provider = [string]$e.ProviderName; Id = [int]$e.Id; Level = [string]$e.LevelDisplayName
                    Message = ([string]$e.Message -replace "`r?`n", ' ')
                }
            }
        } catch { }
    }
    $events | Export-Csv -LiteralPath (Join-Path $work 'events.csv') -NoTypeInformation -Encoding UTF8

    Get-NetIPConfiguration -ErrorAction SilentlyContinue | Out-File -LiteralPath (Join-Path $work 'network.txt') -Encoding UTF8
    Get-NetRoute -ErrorAction SilentlyContinue | Out-File -LiteralPath (Join-Path $work 'routes.txt') -Encoding UTF8

    $soft = @()
    foreach ($k in @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($p in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
            if ($p.DisplayName) { $soft += [pscustomobject]@{ Name = $p.DisplayName; Version = $p.DisplayVersion; Publisher = $p.Publisher } }
        }
    }
    $soft | Sort-Object Name -Unique | Export-Csv -LiteralPath (Join-Path $work 'software.csv') -NoTypeInformation -Encoding UTF8

    $zip = Join-Path $reports ('diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($work, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    "诊断包已生成：$zip"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

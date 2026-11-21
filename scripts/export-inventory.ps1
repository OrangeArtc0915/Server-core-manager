# @scm-id export-inventory
# @scm-name 导出资产清单
# @scm-desc 导出已装软件、硬件、磁盘、网络与系统信息到 reports\inventory-* 目录。
# @scm-risk low

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$reports = Join-Path $root 'reports'
$dir = Join-Path $reports ('inventory-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$soft = @()
foreach ($k in @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    foreach ($p in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
        if ($p.DisplayName) {
            $soft += [pscustomobject]@{
                Name = $p.DisplayName; Version = $p.DisplayVersion
                Publisher = $p.Publisher; InstallDate = $p.InstallDate
            }
        }
    }
}
$soft | Sort-Object Name -Unique | Export-Csv -LiteralPath (Join-Path $dir 'software.csv') -NoTypeInformation -Encoding UTF8

Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue |
    Select-Object Manufacturer, Model, TotalPhysicalMemory, Domain, UserName |
    ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $dir 'computer.json') -Encoding UTF8

Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue |
    Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed |
    ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $dir 'cpu.json') -Encoding UTF8

Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue |
    Select-Object Manufacturer, PartNumber, Capacity, Speed |
    ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $dir 'memory.json') -Encoding UTF8

Get-PhysicalDisk -ErrorAction SilentlyContinue |
    Select-Object FriendlyName, MediaType, Size, HealthStatus, OperationalStatus |
    ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $dir 'disks.json') -Encoding UTF8

Get-NetIPConfiguration -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, InterfaceDescription, IPv4Address, IPv4DefaultGateway, DNSServer |
    ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $dir 'network.json') -Encoding UTF8

"资产清单已导出：$dir"

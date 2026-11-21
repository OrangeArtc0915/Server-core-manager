# @scm-id check-disk
# @scm-name 磁盘健康检查
# @scm-desc 读取物理磁盘健康、可靠性计数，并对系统盘执行只读的 chkdsk /scan。
# @scm-risk low

$ErrorActionPreference = 'Continue'

Write-Output '=== 物理磁盘 ==='
try {
    Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus, Size |
        Format-Table -AutoSize | Out-String | Write-Output
} catch {
    Write-Output ('Get-PhysicalDisk 不可用：' + $_.Exception.Message)
}

Write-Output '=== 可靠性计数 ==='
try {
    Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
        try {
            $c = Get-StorageReliabilityCounter -PhysicalDisk $_ -ErrorAction Stop
            [pscustomobject]@{
                Disk = $_.FriendlyName; Temperature = $c.Temperature; Wear = $c.Wear
                PowerOnHours = $c.PowerOnHours; ReadErrors = $c.ReadErrorsTotal; WriteErrors = $c.WriteErrorsTotal
            }
        } catch { }
    } | Format-Table -AutoSize | Out-String | Write-Output
} catch { }

Write-Output '=== chkdsk /scan（只读，可能需要几分钟）==='
$p = Start-Process -FilePath 'chkdsk.exe' -ArgumentList @($env:SystemDrive, '/scan') -NoNewWindow -Wait -PassThru
Write-Output ('chkdsk 退出码：' + $p.ExitCode)

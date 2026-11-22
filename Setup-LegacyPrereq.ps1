# Server Core Manager — Windows Server 2008 R2 前置安装
#
# 2008 R2 默认只有 PowerShell 2.0 / .NET 3.5，而本工具需要：
#   * .NET Framework 4.5.2 以上（WMF 5.1 的前置，也是原生界面的运行库）
#   * Windows Management Framework 5.1（PowerShell 5.1）
#
# 本脚本刻意用 PowerShell 2.0 兼容语法写，方便在刚装好的 2008 R2 上直接跑。
# 下载不下来的话，按提示手动装这两个包即可。

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$temp = Join-Path $env:TEMP 'scm-prereq'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Write-Step { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Yellow }

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Download-File {
    param([string]$Url, [string]$File)
    Write-Step ('下载：' + $Url)
    $client = New-Object System.Net.WebClient
    $client.Headers.Add('User-Agent', 'SCM-Prereq/2.4')
    $client.DownloadFile($Url, $File)
    if (-not (Test-Path -LiteralPath $File)) { throw ('下载失败：' + $File) }
    $size = (Get-Item -LiteralPath $File).Length
    if ($size -lt 1024) { throw ('下载到的文件太小，可能是错误页：' + $File) }
    Write-Ok ('  已下载 ' + [Math]::Round($size / 1MB, 1) + ' MB')
}

function Expand-ZipCom {
    param([string]$Zip, [string]$Dest)
    if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    $shell = New-Object -ComObject Shell.Application
    $src = $shell.NameSpace($Zip)
    $dst = $shell.NameSpace($Dest)
    foreach ($item in $src.Items()) { $dst.CopyHere($item, 16) }
    for ($i = 0; $i -lt 30; $i++) {
        if (@(Get-ChildItem -LiteralPath $Dest -ErrorAction SilentlyContinue).Count -gt 0) { break }
        Start-Sleep -Seconds 1
    }
}

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor White
Write-Host '    Server Core Manager  ·  Server 2008 R2 前置安装' -ForegroundColor White
Write-Host '  ============================================================' -ForegroundColor White
Write-Host ''

$build = 0
try { $build = [int](Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch { }
Write-Step ('系统 build：' + $build)
if ($build -gt 7601) {
    Write-Ok '当前系统不需要这个脚本（本脚本只用于 Windows Server 2008 R2）。'
    exit 0
}

$psMajor = $PSVersionTable.PSVersion.Major
Write-Step ('PowerShell：' + $PSVersionTable.PSVersion.ToString())

$netRelease = 0
$v = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' 'Release'
if ($v) { $netRelease = [int]$v }
Write-Step (' .NET Framework Release：' + $netRelease)

if (-not (Test-Path -LiteralPath $temp)) { New-Item -ItemType Directory -Path $temp -Force | Out-Null }

$reboot = $false

# 4.5.2 = 379893；4.6.2 = 394254
if ($netRelease -lt 379893) {
    $exe = Join-Path $temp 'NDP462-KB3151800-x86-x64-AllOS-ENU.exe'
    Download-File 'https://go.microsoft.com/fwlink/?LinkId=780600' $exe
    Write-Step '安装 .NET Framework 4.6.2（静默，几分钟）…'
    $p = Start-Process -FilePath $exe -ArgumentList @('/quiet', '/norestart') -Wait -PassThru
    Write-Step ('  退出码：' + $p.ExitCode)
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Warn ' .NET 安装没有返回成功；可以手动运行上面的安装包。'
    } else {
        $reboot = $true
    }
} else {
    Write-Ok ' .NET Framework 已满足（4.5.2 以上）'
}

if ($psMajor -lt 5) {
    $zip = Join-Path $temp 'Win7AndW2K8R2-KB3191566-x64.zip'
    Download-File 'https://go.microsoft.com/fwlink/?linkid=839516' $zip
    $dir = Join-Path $temp 'wmf51'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Expand-ZipCom $zip $dir
    $msu = @(Get-ChildItem -LiteralPath $dir -Filter '*.msu' -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $msu) { throw 'WMF 压缩包里没有找到 .msu' }
    Write-Step ('安装 WMF 5.1：' + $msu.Name + '（静默）…')
    $p = Start-Process -FilePath 'wusa.exe' -ArgumentList @($msu.FullName, '/quiet', '/norestart') -Wait -PassThru
    Write-Step ('  退出码：' + $p.ExitCode)
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Warn ' WMF 安装没有返回成功；可以手动运行解压出来的 .msu。'
    } else {
        $reboot = $true
    }
} else {
    Write-Ok ' PowerShell 5.1 已满足'
}

Write-Host ''
if ($reboot) {
    Write-Warn '前置组件已安装，必须重启服务器后才能继续。'
    Write-Step '重启后：以管理员身份重新打开 PowerShell（或运行一键安装），再执行 install.ps1。'
} else {
    Write-Ok '前置组件都已满足，可以直接运行一键安装。'
}
Write-Host ''

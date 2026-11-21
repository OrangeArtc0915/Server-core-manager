# 软件清单与静默卸载（注册表 Uninstall）。

function Get-GuiReadySoftwareList {
    $rows = @()
    $roots = @(
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Source = 'HKLM' },
        @{ Path = 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Source = 'HKLM32' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Source = 'HKCU' }
    )
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r.Path)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $r.Path -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop
                if (-not $p.DisplayName) { continue }
                $rows += [pscustomobject]@{
                    Name = [string]$p.DisplayName
                    Version = [string]$p.DisplayVersion
                    Publisher = [string]$p.Publisher
                    InstallDate = [string]$p.InstallDate
                    InstallLocation = [string]$p.InstallLocation
                    UninstallString = [string]$p.UninstallString
                    QuietUninstallString = [string]$p.QuietUninstallString
                    Source = [string]$r.Source
                    Key = [string]$sub.PSPath
                }
            } catch { }
        }
    }
    return @($rows | Sort-Object Name)
}

function Find-GuiReadySoftware {
    param([Parameter(Mandatory = $true)][string]$Key)
    $item = @(Get-GuiReadySoftwareList | Where-Object { [string]$_.Key -eq $Key }) | Select-Object -First 1
    if (-not $item) { throw ('软件清单里没有这个条目：' + $Key) }
    return $item
}

function Uninstall-GuiReadySoftware {
    param([Parameter(Mandatory = $true)][string]$Key, [switch]$DryRun)
    $item = Find-GuiReadySoftware -Key $Key
    $cmd = ''
    if ($item.QuietUninstallString) {
        $cmd = [string]$item.QuietUninstallString
    } else {
        $raw = [string]$item.UninstallString
        if ($raw -match '\{[0-9A-Fa-f\-]{36}\}') {
            $cmd = 'msiexec.exe /x ' + $Matches[0] + ' /qn /norestart'
        } elseif ($raw) {
            throw ('「' + $item.Name + '」没有静默卸载命令，请手动卸载。原命令：' + $raw)
        } else {
            throw ('「' + $item.Name + '」没有卸载命令。')
        }
    }
    if ($DryRun) { Write-Log ('[预览] 静默卸载 ' + $item.Name + '：' + $cmd) 'DRY'; return [pscustomobject]@{ Name = $item.Name; Command = $cmd; DryRun = $true } }

    $exe = 'msiexec.exe'
    $args = $cmd
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $args = $Matches[2] }
    elseif ($cmd -match '^\s*(\S+)\s+(.*)$') { $exe = $Matches[1]; $args = $Matches[2] }
    Write-Log ('开始卸载：' + $item.Name) 'STEP'
    $p = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -ErrorAction Stop
    Write-Log ('卸载进程退出码：' + $p.ExitCode) $(if ($p.ExitCode -eq 0) { 'OK' } else { 'WARN' })
    return [pscustomobject]@{ Name = $item.Name; ExitCode = $p.ExitCode; Command = $cmd }
}

function Export-GuiReadySoftwareList {
    param([Parameter(Mandatory = $true)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Get-GuiReadySoftwareList | Select-Object Name, Version, Publisher, InstallDate, InstallLocation, Source |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    Write-Log ('软件清单已导出：' + $Path) 'OK'
    return $Path
}

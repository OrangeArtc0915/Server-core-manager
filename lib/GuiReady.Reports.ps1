# 报告中心：列出 reports\ 下的报表，打包、发送、每日任务。

function Get-GuiReadyReportsRoot {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'reports'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-GuiReadyReportList {
    param([int]$Max = 300)
    $root = Get-GuiReadyReportsRoot
    $rows = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -in @('.html', '.zip', '.csv', '.json', '.pcapng', '.txt') } |
                     Sort-Object LastWriteTime -Descending | Select-Object -First $Max)) {
        $rows += [pscustomobject]@{
            File = $f.Name
            Type = $f.Extension.TrimStart('.').ToUpperInvariant()
            SizeKB = [Math]::Round($f.Length / 1KB, 1)
            Time = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            Path = $f.FullName
        }
    }
    return @($rows)
}

function New-GuiReadyReportBundle {
    param([string[]]$Files = @(), [string]$OutFile = '')
    if (-not $OutFile) { $OutFile = Join-Path (Get-GuiReadyReportsRoot) ('bundle-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip') }
    $picked = @()
    if ($Files -and $Files.Count -gt 0) {
        foreach ($f in $Files) { if (Test-Path -LiteralPath $f) { $picked += (Get-Item -LiteralPath $f) } }
    } else {
        $picked = @(Get-ChildItem -LiteralPath (Get-GuiReadyReportsRoot) -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in @('.html', '.zip', '.csv', '.json') -and $_.FullName -notlike '*bundle-*' } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 20)
    }
    if ($picked.Count -eq 0) { throw '没有可打包的报表。' }
    $work = Join-Path $env:TEMP ('scm-report-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        foreach ($f in $picked) {
            $safe = (([string]$f.FullName).Replace(':', '').Replace('\', '_'))
            if ($safe.Length -gt 120) { $safe = $safe.Substring($safe.Length - 120) }
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $work $safe) -Force
        }
        $dir = Split-Path -Parent $OutFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($work, $OutFile, [IO.Compression.CompressionLevel]::Optimal, $false)
        $sha = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLower()
        Write-Log ('报告包已生成：{0}（{1} 个文件）' -f $OutFile, $picked.Count) 'OK'
        return [pscustomobject]@{ File = $OutFile; Count = $picked.Count; SizeKB = [Math]::Round((Get-Item -LiteralPath $OutFile).Length / 1KB, 1); Sha256 = $sha }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-GuiReadyReportConfigPath {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Join-Path $root 'state\reports.json')
}

function Get-GuiReadyReportConfig {
    $file = Get-GuiReadyReportConfigPath
    if (Test-Path -LiteralPath $file) { try { return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
    return [pscustomobject]@{ Send = $false; Time = '08:00' }
}

function Install-GuiReadyReportTask {
    param([bool]$Send = $false, [string]$Time = '08:00', [switch]$DryRun)
    if (-not $DryRun) {
        [pscustomobject]@{ Send = $Send; Time = $Time } | ConvertTo-Json | Out-File -LiteralPath (Get-GuiReadyReportConfigPath) -Encoding UTF8
    }
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Register-GuiReadyPlusTask -TaskName 'ScmPlus-Reports' `
        -Runner (Join-Path $root 'gui\Run-GuiReadyReports.ps1') -Mode 'auto' `
        -Schedule 'daily' -Time $Time -LimitMinutes 30 -DryRun:$DryRun)
}

function Remove-GuiReadyReportTask {
    param([switch]$DryRun)
    Unregister-GuiReadyPlusTask -TaskName 'ScmPlus-Reports' -DryRun:$DryRun
}

function Invoke-GuiReadyReportAuto {
    $cfg = Get-GuiReadyReportConfig
    $b = New-GuiReadyReportBundle
    if ([bool]$cfg.Send -and (Get-Command Send-GuiReadyNotify -ErrorAction SilentlyContinue)) {
        try {
            Send-GuiReadyNotify -Title '每日报表包' -Text ('已生成报告包：' + $b.File) -Level 'Info' -Attachment $b.File | Out-Null
        } catch { Write-Log ('发送报告包失败：' + $_.Exception.Message) 'WARN' }
    }
    return $b
}

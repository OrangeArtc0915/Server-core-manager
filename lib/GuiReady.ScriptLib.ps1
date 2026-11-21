# 脚本插件库：读取 scripts\*.ps1 的元数据、预览、校验并执行。

function Get-GuiReadyScriptRoot {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $root 'scripts'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-GuiReadyScriptLibrary {
    $rows = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-GuiReadyScriptRoot) -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $meta = @{}
        try {
            $head = @(Get-Content -LiteralPath $f.FullName -TotalCount 30 -Encoding UTF8)
            foreach ($line in $head) {
                if ($line -match '^#\s*@scm-([A-Za-z]+)\s+(.+)$') { $meta[$Matches[1].ToLowerInvariant()] = $Matches[2].Trim() }
            }
        } catch { }
        $id = if ($meta['id']) { [string]$meta['id'] } else { [IO.Path]::GetFileNameWithoutExtension($f.Name) }
        $sha = ''
        try { $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower() } catch { }
        $rows += [pscustomobject]@{
            Id = $id
            Name = if ($meta['name']) { [string]$meta['name'] } else { $id }
            Desc = if ($meta['desc']) { [string]$meta['desc'] } else { '' }
            Risk = if ($meta['risk']) { [string]$meta['risk'] } else { 'medium' }
            File = $f.Name
            Path = $f.FullName
            SizeKB = [Math]::Round($f.Length / 1KB, 1)
            Modified = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            Sha256 = $sha
        }
    }
    return @($rows)
}

function Get-GuiReadyScriptItem {
    param([Parameter(Mandatory = $true)][string]$Id)
    $item = @(Get-GuiReadyScriptLibrary | Where-Object { [string]$_.Id -eq $Id }) | Select-Object -First 1
    if (-not $item) { throw ('脚本库里没有：' + $Id) }
    return $item
}

function Get-GuiReadyScriptPreview {
    param([Parameter(Mandatory = $true)][string]$Id, [int]$Lines = 80)
    $item = Get-GuiReadyScriptItem -Id $Id
    $text = Get-Content -LiteralPath $item.Path -TotalCount $Lines -Encoding UTF8
    return [pscustomobject]@{ Id = $item.Id; Name = $item.Name; Risk = $item.Risk; Sha256 = $item.Sha256; Text = (@($text) -join [Environment]::NewLine) }
}

function Invoke-GuiReadyScript {
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DryRun, [int]$TimeoutSec = 600)
    $item = Get-GuiReadyScriptItem -Id $Id
    if ($DryRun) {
        Write-Log ('[预览] 脚本 ' + $item.Name + '（' + $item.Id + '，风险 ' + $item.Risk + '）') 'DRY'
        Write-Log ('SHA256 ' + $item.Sha256) 'DRY'
        return [pscustomobject]@{ Id = $item.Id; DryRun = $true; Path = $item.Path; Risk = $item.Risk; Sha256 = $item.Sha256 }
    }
    $work = Join-Path $env:TEMP ('scm-script-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $stdout = Join-Path $work 'out.txt'
    $stderr = Join-Path $work 'err.txt'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $p = Start-Process -FilePath 'powershell.exe' -WorkingDirectory (Split-Path -Parent $item.Path) `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $item.Path + '"')) `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
        $done = $p.WaitForExit([Math]::Max(10, $TimeoutSec) * 1000)
        if (-not $done) {
            try { $p.Kill() } catch { }
            throw ('脚本超过 {0} 秒仍未结束，已终止。' -f $TimeoutSec)
        }
        $p.WaitForExit()
        $code = -1
        try { $code = [int]$p.ExitCode } catch { }
        $sw.Stop()
        # 子进程是 Windows PowerShell 5.1，重定向输出默认按系统 ANSI/OEM 编码写出
        $out = if (Test-Path -LiteralPath $stdout) { [IO.File]::ReadAllText($stdout, [Text.Encoding]::Default) } else { '' }
        $err = if (Test-Path -LiteralPath $stderr) { [IO.File]::ReadAllText($stderr, [Text.Encoding]::Default) } else { '' }
        Write-Log ('脚本 {0} 结束，退出码 {1}，用时 {2:N1} 秒' -f $item.Name, $code, $sw.Elapsed.TotalSeconds) $(if ($code -eq 0) { 'OK' } else { 'WARN' })
        return [pscustomobject]@{
            Id = $item.Id; Name = $item.Name; Ok = ($code -eq 0); ExitCode = $code
            Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1); Output = $out.Trim(); Error = $err.Trim()
            Sha256 = $item.Sha256; Risk = $item.Risk
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# GuiReady command: install a single-word console command that opens this tool, like sconfig
#
# SConfig works because C:\Windows\System32\sconfig.cmd exists and System32 is in PATH.
# This module installs a small .cmd with the same idea, with the tool path baked in,
# and does the same self-elevation SConfig does.

$Global:GuiReadyCommandMarker = 'GuiReady-Command:'

function Get-GuiReadyCommandTemplate {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [string]$Name = 'scm')

    # 生成的 .cmd 保持纯 ASCII：cmd.exe 按控制台代码页读取批处理文件，
    # 非 ASCII 内容在不同代码页下会变乱码。所有中文提示都交给 PowerShell 侧输出。
    $lines = @()
    $lines += '@echo off'
    $lines += 'setlocal EnableExtensions'
    $lines += ('title Server Core GUI Readiness Tool (' + $Name + ')')
    $lines += ('set "GRROOT=' + $ToolRoot + '"')
    $lines += 'set "GENTRY=%GRROOT%\Start-GuiReadyApp.ps1"'
    $lines += 'if not exist "%GENTRY%" set "GENTRY=%GRROOT%\Start-GuiReady.ps1"'
    $lines += 'if not exist "%GENTRY%" ('
    $lines += '  echo.'
    $lines += '  echo [ERROR] Tool entry not found: %GENTRY%'
    $lines += '  echo         The tool folder may have been moved or renamed.'
    $lines += '  echo         Re-install by running install-command.bat in the tool folder.'
    $lines += '  echo.'
    $lines += '  pause'
    $lines += '  exit /b 1'
    $lines += ')'
    $lines += 'rem Same idea as sconfig: needs admin, so re-launch itself elevated'
    $lines += 'fltmc >nul 2>&1'
    $lines += 'if %errorlevel% NEQ 0 ('
    $lines += '  echo Requesting administrator privileges...'
    $lines += '  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ComSpec -ArgumentList ''/c'',[char]34+''%~f0''+[char]34 -Verb RunAs"'
    $lines += '  exit /b'
    $lines += ')'
    $lines += 'powershell -NoProfile -ExecutionPolicy Bypass -NoLogo -File "%GENTRY%" %*'
    $lines += 'exit /b %errorlevel%'
    return ($lines -join "`r`n")
}

function Install-GuiReadyCommand {
    param(
        [string]$Name = 'scm',
        [string]$Directory = '',
        [switch]$WhatIf
    )

    Write-Head ('安装一行命令: ' + $Name)

    if (-not (Assert-Administrator)) { return $null }
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = Join-Path $env:windir 'System32' }

    $toolRoot = $script:GuiReadyRoot
    $entry    = Join-Path $toolRoot 'Start-GuiReady.ps1'
    if (-not (Test-Path -LiteralPath $entry)) {
        Write-Log ('工具入口不存在: ' + $entry) 'ERROR'
        return $null
    }

    if (-not (Test-Path -LiteralPath $Directory)) {
        Write-Log ('目标目录不存在: ' + $Directory) 'ERROR'
        return $null
    }

    $target = Join-Path $Directory ($Name + '.cmd')

    # 目标目录必须在 PATH 里，否则"输入一条指令"就不成立
    $inPath = $false
    foreach ($p in ($env:Path -split ';')) {
        if ($p.TrimEnd('\') -ieq $Directory.TrimEnd('\')) { $inPath = $true; break }
    }
    if (-not $inPath) {
        Write-Log ('注意: {0} 不在 PATH 里，装完可能无法直接输命令调用' -f $Directory) 'WARN'
    }

    Write-Log ('工具目录 : {0}' -f $toolRoot) 'INFO'
    Write-Log ('命令文件 : {0}' -f $target) 'INFO'
    Write-Log ('在 PATH  : {0}' -f (Format-Bool $inPath)) 'INFO'

    $content = Get-GuiReadyCommandTemplate -ToolRoot $toolRoot -Name $Name

    if ($WhatIf) {
        Write-Log '将写入以下内容（不实际落盘）:' 'DRY'
        foreach ($l in ($content -split "`r`n")) { Write-Log ('    ' + $l) 'DRY' }
        return [pscustomobject]@{ Ok = $true; DryRun = $true; Target = $target }
    }

    try {
        # 用 ASCII 写：cmd 对 UTF-8 无 BOM 的中文处理不稳，所以模板里不放中文以外的花活
        [System.IO.File]::WriteAllText($target, $content, [System.Text.Encoding]::Default)
        Write-Log ('已写入命令文件: ' + $target) 'OK'
    } catch {
        Write-Log ('写入失败: ' + $_.Exception.Message) 'ERROR'
        return $null
    }

    Write-Log ''
    Write-Log '用法（在任意目录、cmd 或 PowerShell 里）:' 'OK'
    Write-Log ('    ' + $Name) 'INFO'
    Write-Log '  首次运行会弹一次提权确认（和 sconfig 一样自己提权）' 'INFO'
    Write-Log ''
    Write-Log ('想卸载: 运行 Install-GuiReadyCommand.ps1 -Name {0} -Uninstall' -f $Name) 'INFO'
    Write-Log '想换名字: 用 -Name 指定其它名字即可，也可以直接装多个名字' 'INFO'

    return [pscustomobject]@{ Ok = $true; Target = $target; Name = $Name; ToolRoot = $toolRoot }
}

function Uninstall-GuiReadyCommand {
    param([string]$Name = 'scm', [string]$Directory = '', [switch]$WhatIf)

    Write-Head ('卸载一行命令: ' + $Name)
    if (-not (Assert-Administrator)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = Join-Path $env:windir 'System32' }

    $target = Join-Path $Directory ($Name + '.cmd')
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Log ('没有找到: ' + $target) 'WARN'
        return $false
    }

    # 只删我们自己装的，避免误删用户自建的同名文件
    $head = ''
    try { $head = (Get-Content -LiteralPath $target -TotalCount 3 -Encoding Default) -join "`n" } catch { }
    if ($head -notmatch 'Server Core GUI Readiness Tool') {
        Write-Log ('这个文件看起来不是本工具装的，为安全起见不删除: ' + $target) 'WARN'
        return $false
    }

    if ($WhatIf) {
        Write-Log ('将删除: ' + $target) 'DRY'
        return $true
    }

    try {
        Remove-Item -LiteralPath $target -Force -ErrorAction Stop
        Write-Log ('已删除: ' + $target) 'OK'
        return $true
    } catch {
        Write-Log ('删除失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Get-GuiReadyCommandStatus {
    param([string[]]$Names = @('scm'), [string]$Directory = '')

    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = Join-Path $env:windir 'System32' }
    $rows = New-Object System.Collections.ArrayList
    foreach ($n in $Names) {
        $t = Join-Path $Directory ($n + '.cmd')
        $exists = Test-Path -LiteralPath $t
        $isOurs = $false
        if ($exists) {
            try { $h = (Get-Content -LiteralPath $t -TotalCount 3 -Encoding Default) -join "`n"; $isOurs = ($h -match 'Server Core GUI Readiness Tool') } catch { }
        }
        [void]$rows.Add([pscustomobject]@{ Name = $n; Path = $t; Exists = $exists; IsOurs = $isOurs })
    }
    return @($rows)
}

function Show-GuiReadyCommandStatus {
    Write-Head '一行命令安装状态'
    $rows = Get-GuiReadyCommandStatus
    foreach ($r in $rows) {
        $mark = '未安装'
        if ($r.Exists -and $r.IsOurs) { $mark = '已安装（本工具）' }
        elseif ($r.Exists) { $mark = '存在但不是本工具装的' }
        Write-Log ('  {0,-10} {1,-24} {2}' -f $r.Name, $mark, $r.Path) $(if ($r.Exists -and $r.IsOurs) { 'OK' } else { 'INFO' })
    }
    Write-Log ''
    Write-Log '安装/卸载: 双击工具目录里的"安装一行命令.bat"，或用 Install-GuiReadyCommand.ps1' 'INFO'
    return $rows
}

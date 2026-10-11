# GuiReady command: install a single-word console command that opens this tool, like sconfig
#
# SConfig works because C:\Windows\System32\sconfig.cmd exists and System32 is in PATH.
# This module installs a small .cmd with the same idea, with the tool path baked in,
# and does the same self-elevation SConfig does.

$Global:GuiReadyCommandMarker = 'GuiReady-Command:'

# ============================ 给自定义程序绑终端命令 ============================
# 需求：在程序档案里给某个程序绑一个词（例如微信绑 "wx"），终端里敲 wx 就能打开它。
#
# 为什么用「往 System32 写 <别名>.cmd 垫片」而不是改 profile / AutoRun：
#   1. cmd 与 PowerShell 都认 PATH 里的 .cmd，一次写好两边通用；
#   2. 不动 profile —— 改 profile 要连带处理执行策略，之前踩过"禁止运行脚本"那个坑；
#   3. 与 scm / scm-term 是同一套做法，行为一致，卸载路径也一致。

function Get-GuiReadyProgramCommandPath {
    param([string]$Alias)
    return (Join-Path (Join-Path $env:windir 'System32') ([string]$Alias + '.cmd'))
}

function Test-GuiReadyCommandAlias {
    # 这个值最终会变成"一个文件名 + .cmd 正文里的一段"，所以字符集必须收紧：
    # 只允许 A-Za-z0-9._+-（与包名校验同一条规则），长度 <= 32。
    # 另外挡掉系统命令与工具自己的入口，免得把 cmd / powershell / scm 盖掉。
    param([string]$Alias)
    if ([string]::IsNullOrWhiteSpace($Alias)) { return 'AliasEmpty' }
    $a = ([string]$Alias).Trim()
    if ($a.Length -gt 32) { return 'AliasTooLong' }
    if ($a -notmatch '^[A-Za-z0-9._+-]+$') { return 'AliasBadChar' }
    $reserved = @('scm', 'scm-term', 'sconfig', 'cmd', 'powershell', 'pwsh', 'exit', 'start',
                  'call', 'echo', 'set', 'rem', 'type', 'copy', 'del', 'dir', 'cd', 'md', 'rd',
                  'path', 'title', 'pause', 'cls', 'ver', 'vol')
    if ($reserved -contains $a.ToLower()) { return 'AliasReserved' }
    return 'OK'
}

function Install-GuiReadyProgramCommand {
    # 写一个 <别名>.cmd 垫片。返回 [pscustomobject]@{ Ok; Code; Target }。
    param(
        [Parameter(Mandatory = $true)][string]$Alias,
        [Parameter(Mandatory = $true)][string]$ExePath,
        [string]$Arguments = ''
    )
    $code = Test-GuiReadyCommandAlias -Alias $Alias
    if ($code -ne 'OK') { return [pscustomobject]@{ Ok = $false; Code = $code; Target = '' } }
    if (-not (Test-Path -LiteralPath $ExePath)) { return [pscustomobject]@{ Ok = $false; Code = 'ExeMissing'; Target = '' } }

    $name   = ([string]$Alias).Trim()
    $target = Get-GuiReadyProgramCommandPath -Alias $name

    # 同名文件存在、且不是本工具写的 → 不覆盖（可能是用户自己的命令）
    if (Test-Path -LiteralPath $target) {
        $cur = ''
        try { $cur = [System.IO.File]::ReadAllText($target) } catch { }
        if ($cur -notmatch 'ServerCoreManager: program command') {
            return [pscustomobject]@{ Ok = $false; Code = 'Occupied'; Target = $target }
        }
    }

    # start 的第一个参数必须是空标题 ""，否则 start 会把带引号的路径当成窗口标题
    $cmd = 'start "" "' + $ExePath + '"'
    if ($Arguments) { $cmd = $cmd + ' ' + $Arguments }
    $lines = @(
        '@echo off',
        'rem ServerCoreManager: program command (managed by ServerCoreManager)',
        ('rem bound-to: ' + $ExePath),
        $cmd
    )
    # 与 scm.cmd 一样用 ANSI 写：cmd 按进程代码页解析批处理，中文路径必须落在系统 ANSI 页里
    $content = ($lines -join "`r`n") + "`r`n"
    try {
        [System.IO.File]::WriteAllText($target, $content, [System.Text.Encoding]::Default)
        return [pscustomobject]@{ Ok = $true; Code = 'OK'; Target = $target }
    } catch {
        return [pscustomobject]@{ Ok = $false; Code = 'WriteFailed'; Target = $target }
    }
}

function Remove-GuiReadyProgramCommand {
    # 只删本工具写的垫片；不是我们的（没有标记行）一律不碰。
    param([Parameter(Mandatory = $true)][string]$Alias)
    $name = ([string]$Alias).Trim()
    if (-not $name) { return $true }
    $target = Get-GuiReadyProgramCommandPath -Alias $name
    if (-not (Test-Path -LiteralPath $target)) { return $true }
    try {
        $cur = [System.IO.File]::ReadAllText($target)
        if ($cur -notmatch 'ServerCoreManager: program command') { return $false }
        Remove-Item -LiteralPath $target -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

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

    # ---- 装了 scm 就必须能看到入口提示，不依赖「一键美化终端」 ----
    # 之前提示只由美化那条链路安装，于是"只跑了一行命令安装"的机器上终端里什么都不显示。
    # 这里补上：PowerShell 走 profile 的托管块，cmd 走 AutoRun → bin\scm-welcome.cmd。
    # 元数据与撤销路径都复用 Console 模块（「一键还原」能一并清掉），不另起一套。
    try {
        if (-not (Get-Command Write-GuiReadyConsoleProfileHook -ErrorAction SilentlyContinue)) {
            # Command 模块可能被单独加载（例如 install.ps1 只 dot-source 了 Common + Command），
            # 所以这里按需把同目录的 Console 模块补进来
            $consoleLib = Join-Path $PSScriptRoot 'GuiReady.Console.ps1'
            if (Test-Path -LiteralPath $consoleLib) { . $consoleLib }
        }
        if (Get-Command Write-GuiReadyConsoleProfileHook -ErrorAction SilentlyContinue) {
            Write-GuiReadyConsoleProfileHook -Quiet | Out-Null
            if (Get-Command Set-GuiReadyConsoleWelcome -ErrorAction SilentlyContinue) {
                Set-GuiReadyConsoleWelcome -Quiet | Out-Null
            }
            Write-Log '已一并装好终端入口提示（新开一个 cmd / PowerShell 窗口就能看到）。' 'OK'
        } else {
            Write-Log '未能加载 Console 模块，跳过入口提示（scm 命令本身已可用）。' 'WARN'
        }
    } catch {
        # 提示装不上不能影响 scm 命令本身 —— 它已经写好了
        Write-Log ('安装终端入口提示失败（不影响 scm 命令本身）: ' + $_.Exception.Message) 'WARN'
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

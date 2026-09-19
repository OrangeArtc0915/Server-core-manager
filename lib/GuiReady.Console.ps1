# GuiReady 控制台美化：Nerd Font + Oh My Posh + Fastfetch（面向 Windows Server Core 的 conhost）
#
# 结论都来自 2026-09 在 Windows Server 2025 Core（26100.32230）上的实测，别凭直觉改：
#   1) 中文控制台的代码页是 936，conhost 在该代码页下【只接受自带中文字形的字体】：
#     实测 MesloLGS NF 与 Consolas 都被拒（SetCurrentConsoleFontEx 返回 True 但 conhost 回退到“新宋体”）。
#   2) 把控制台切到 UTF-8（chcp 65001）后，同一个 Nerd Font 立刻被接受（GetCurrentConsoleFontEx 回读 face=MesloLGS NF）。
#      —— 所以美化终端必须走我们自己的启动器 scm-term.cmd：先 chcp 65001，再应用字体。
#   3) HKCU\Console\CodePage 对“新建控制台”不生效；按标题记忆的 HKCU\Console\<标题> 也不生效（都实测过）。
#   4) 字体要能被控制台选中，除了装进 C:\Windows\Fonts，还要写
#      HKLM\...\Console\TrueTypeFont（中文代码页用 0936 这种键名）+ FontLink\SystemLink 做中文回退。
#   5) 给字体辅助脚本千万别重定向 stdout：stdout 变成文件句柄后进程就“不再拥有控制台”，GetCurrentConsoleFontEx 会失败。
#   6) 系统级 UTF-8（OEMCP=65001）能让所有控制台直接用 Nerd Font，但会影响老式 ANSI 程序，本模块不做，只作为提示。

$Global:GuiReadyConsoleAssetDir = 'setup\console'
$Global:GuiReadyConsoleFontFace = 'MesloLGS NF'
$Global:GuiReadyConsoleFontSize = 18
$Global:GuiReadyConsoleManagedTag = 'ServerCoreManager console theme'

function Get-GuiReadyConsoleRoot {
    return (Join-Path $script:GuiReadyRoot 'bin')
}

function Get-GuiReadyConsoleAssetDirs {
    $cands = @(
        (Join-Path $script:GuiReadyRoot $Global:GuiReadyConsoleAssetDir),
        (Join-Path $script:GuiReadyRoot 'payload'),
        (Join-Path $script:GuiReadyRoot 'setup'),
        $script:GuiReadyRoot
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($d in $cands) {
        if (Test-Path -LiteralPath $d -PathType Container) {
            $full = (Get-Item -LiteralPath $d).FullName
            if (-not $out.Contains($full)) { [void]$out.Add($full) }
        }
    }
    return @($out)
}

function Find-GuiReadyConsoleAssets {
    # 离线素材：字体 ttf、oh-my-posh.exe、fastfetch.exe、主题 json、字体辅助脚本、启动器
    $o = [ordered]@{
        Dir         = ''
        Fonts       = @()
        Posh        = ''
        Fastfetch   = ''
        Theme       = ''
        ThemesDir   = ''
        Themes      = @()
        FontScript  = ''
        Launcher    = ''
        Missing     = @()
    }
    $dirs = @()
    if ($script:GuiReadyConsoleAssetDirUsed) { $dirs += $script:GuiReadyConsoleAssetDirUsed }
    $dirs += (Get-GuiReadyConsoleAssetDirs)

    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
            $n = $f.Name
            if ($n -match '(?i)\.ttf$') { $o.Fonts += $f.FullName; if (-not $o.Dir) { $o.Dir = $d } }
            elseif (-not $o.Posh -and $n -match '(?i)^(oh-my-posh|posh-windows)\S*\.exe$') { $o.Posh = $f.FullName; if (-not $o.Dir) { $o.Dir = $d } }
            elseif (-not $o.Fastfetch -and $n -match '(?i)^fastfetch\S*\.exe$') { $o.Fastfetch = $f.FullName; if (-not $o.Dir) { $o.Dir = $d } }
            elseif (-not $o.Theme -and $n -match '(?i)\.omp\.json$') { $o.Theme = $f.FullName; if (-not $o.Dir) { $o.Dir = $d } }
            elseif (-not $o.FontScript -and $n -eq 'Set-ScmConsoleFont.ps1') { $o.FontScript = $f.FullName }
            elseif (-not $o.Launcher -and $n -eq 'scm-term.cmd') { $o.Launcher = $f.FullName }
        }
    }
    # fastfetch 有时以 zip 形式随包分发，这里只在 bin 里找 exe；zip 的处理放到安装动作里说明

    # 内置主题集合（可选）：素材目录下的 themes\*.omp.json，安装时会一起带上，方便随时切换
    if ($o.Dir) {
        $td = Join-Path $o.Dir 'themes'
        if (Test-Path -LiteralPath $td) {
            $o.ThemesDir = $td
            $o.Themes = @(Get-ChildItem -LiteralPath $td -File -Filter '*.omp.json' -ErrorAction SilentlyContinue |
                          Sort-Object Name | ForEach-Object { $_.FullName })
        }
    }

    $miss = New-Object System.Collections.ArrayList
    if ($o.Fonts.Count -eq 0)        { [void]$miss.Add('MesloLGS NF 的 ttf 字体文件（*.ttf）') }
    if (-not $o.Posh)                { [void]$miss.Add('oh-my-posh.exe') }
    if (-not $o.Theme)               { [void]$miss.Add('oh-my-posh 主题（*.omp.json）') }
    if (-not $o.FontScript)          { [void]$miss.Add('Set-ScmConsoleFont.ps1') }
    if (-not $o.Launcher)            { [void]$miss.Add('scm-term.cmd') }
    $o.Missing = @($miss)
    return [pscustomobject]$o
}

function Test-GuiReadyConsoleFont {
    # 字体是否已装进系统（按字体族名问 GDI，而不是只看文件在不在）
    $o = [ordered]@{ Installed = $false; Resolved = ''; Note = '' }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $fam = @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
        $o.Installed = ($fam -contains $Global:GuiReadyConsoleFontFace)
        $f = New-Object System.Drawing.Font($Global:GuiReadyConsoleFontFace, 10)
        $o.Resolved = $f.Name
        if (-not $o.Installed) { $o.Note = '字体族未安装（或名字不对）' }
        elseif ($o.Resolved -ne $Global:GuiReadyConsoleFontFace) { $o.Note = 'GDI 做了字体替换，实际解析为 ' + $o.Resolved }
        else { $o.Note = '字体已安装且可解析' }
    } catch {
        $o.Note = '检查失败: ' + $_.Exception.Message
    }
    return [pscustomobject]$o
}

function Get-GuiReadyConsoleFontKeys {
    # 控制台字体白名单 + 中文回退
    $ttfKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Console\TrueTypeFont'
    $linkKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink'
    $whitelist = @()
    try {
        $k = Get-Item -LiteralPath $ttfKey -ErrorAction SilentlyContinue
        if ($k) {
            foreach ($n in $k.GetValueNames()) {
                if ([string]$k.GetValue($n) -eq $Global:GuiReadyConsoleFontFace) { $whitelist += $n }
            }
        }
    } catch { }
    $linked = $false
    try {
        $lk = Get-Item -LiteralPath $linkKey -ErrorAction SilentlyContinue
        if ($lk -and ($lk.GetValueNames() -contains $Global:GuiReadyConsoleFontFace)) { $linked = $true }
    } catch { }
    return [pscustomobject]@{ WhitelistKeys = @($whitelist); FontLinked = $linked }
}

function Get-GuiReadyConsoleUserSettings {
    $o = [ordered]@{ FaceName = ''; FontFamily = 0; FontSize = 0; VT = $null; ForceV2 = $null; Colors = 0 }
    try {
        $c = Get-ItemProperty 'HKCU:\Console' -ErrorAction SilentlyContinue
        if ($c) {
            $o.FaceName = [string]$c.FaceName
            $o.FontFamily = [int]$c.FontFamily
            $o.FontSize = [int]$c.FontSize
            $o.VT = $c.VirtualTerminalLevel
            $o.ForceV2 = $c.ForceV2
            $n = 0
            foreach ($i in 0..15) { if ($null -ne $c.('ColorTable{0:D2}' -f $i)) { $n++ } }
            $o.Colors = $n
        }
    } catch { }
    return [pscustomobject]$o
}

function Test-GuiReadyConsoleProfileHook {
    $o = [ordered]@{ Path = ''; Hooked = $false }
    try {
        $o.Path = [string]$PROFILE.CurrentUserAllHosts
        if ($o.Path -and (Test-Path -LiteralPath $o.Path)) {
            $txt = [System.IO.File]::ReadAllText($o.Path)
            $o.Hooked = ($txt -match [regex]::Escape($Global:GuiReadyConsoleManagedTag))
        }
    } catch { }
    return [pscustomobject]$o
}

function Invoke-GuiReadyConsoleProbe {
    # 用启动器的 --probe 实测“新开的美化终端”到底拿到了什么字体与代码页
    param([int]$TimeoutSeconds = 40)

    $bin = Get-GuiReadyConsoleRoot
    $launcher = Join-Path $bin 'scm-term.cmd'
    $probeFile = Join-Path $script:LogDir 'console-probe.txt'
    $o = [ordered]@{ Ok = $false; Result = ''; Note = ''; Launcher = $launcher }
    if (-not (Test-Path -LiteralPath $launcher)) { $o.Note = '找不到启动器 scm-term.cmd'; return [pscustomobject]$o }
    try { if (Test-Path -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue } } catch { }
    try {
        # 注意：这里不能用重定向，否则子进程拿不到控制台句柄
        Start-Process -FilePath $launcher -ArgumentList '--probe' -Wait -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1
        if (Test-Path -LiteralPath $probeFile) { $o.Result = ([string](Get-Content -LiteralPath $probeFile -Raw)).Trim() }
        if ($o.Result -match [regex]::Escape($Global:GuiReadyConsoleFontFace)) { $o.Ok = $true }
        else { $o.Note = '启动器没能应用 Nerd Font' }
    } catch {
        $o.Note = '探针执行失败: ' + $_.Exception.Message
    }
    return [pscustomobject]$o
}

function Get-GuiReadyPowerShell7Paths {
    $o = [ordered]@{ Installed = $false; Exe = ''; Dir = ''; Version = '' }
    $cands = @()
    if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe') }
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe') }
    try {
        $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($cmd) { $cands += $cmd.Source }
    } catch { }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            $o.Installed = $true; $o.Exe = $c; $o.Dir = Split-Path -Parent $c
            try { $o.Version = ((& $c -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1) -as [string]) } catch { }
            break
        }
    }
    return [pscustomobject]$o
}

function Get-GuiReadyConsoleProfilePaths {
    # PowerShell 5.1 与 7 的 profile 路径不同，两边都要写，否则只在 5.1 里有效果
    $paths = New-Object System.Collections.ArrayList
    try {
        $cur = [string]$PROFILE.CurrentUserAllHosts
        if ($cur) { [void]$paths.Add($cur) }
    } catch { }
    try {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        if ($docs) {
            [void]$paths.Add((Join-Path $docs 'PowerShell\profile.ps1'))                              # PowerShell 7
            [void]$paths.Add((Join-Path $docs 'WindowsPowerShell\profile.ps1'))                       # PowerShell 5.1
        }
    } catch { }
    return @($paths | Where-Object { $_ } | Select-Object -Unique)
}

function Write-GuiReadyConsoleProfileHook {
    param([switch]$Remove, [switch]$Quiet)

    $bin   = Get-GuiReadyConsoleRoot
    $posh  = Join-Path $bin 'oh-my-posh.exe'
    $theme = Join-Path $bin 'theme.omp.json'
    $tag   = $Global:GuiReadyConsoleManagedTag
    $pattern = '(?s)\r?\n?# --- ' + [regex]::Escape($tag) + '.*?# --- end managed block ---\r?\n?'
    # 用【单引号】here-string + 占位符替换：完全不涉及转义，
    # 生成的 PowerShell 代码里可以有 $ompInit / $_ 这种变量而不会被这里提前展开
    # （之前用双引号 here-string + 反引号转义，实测把 $_.Exception.Message 的 $_ 吃掉了，
    #   写出来的 profile 直接语法错误，PowerShell 一启动就报错）
    $block = @'

# --- __TAG__ (managed block) ---
# 两个入口提示：只在真终端里显示（输出被重定向时保持安静，免得污染脚本抓取的输出）
function Show-ScmWelcome {
    Write-Host '  输入 "Sconfig" 返回服务器菜单' -ForegroundColor Yellow
    Write-Host '  输入 "scm" 打开 GUI 工具' -ForegroundColor Yellow
}
# 清屏后把提示重新打到最上面（cls / clear 都是 Clear-Host 的别名）
function global:Clear-Host {
    # 别用“模块限定名”去调 Clear-Host 兜底：实测 PowerShell 5.1 里那个模块没有这个命令，
    # 会抛 CouldNotAutoLoadModule 并刷一屏错误。直接用 .NET 的 [Console]::Clear()，
    # 无模块依赖、也不会递归回到本函数。
    try { [Console]::Clear() } catch { }
    if (-not [Console]::IsOutputRedirected) { Show-ScmWelcome }
}
if (-not [Console]::IsOutputRedirected) { Show-ScmWelcome }
if (Test-Path '__POSH__') {
    # 初始化失败绝不能让 PowerShell 变得不可用（否则会看到“窗口里什么都没有”）
    try {
        $ompInit = & '__POSH__' init pwsh --config '__THEME__' 2>$null
        if ($ompInit) { $ompInit | Invoke-Expression }
    } catch {
        Write-Host ('[scm] oh-my-posh 初始化失败，已回退默认提示符: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}
# --- end managed block ---

'@
    $block = $block.Replace('__TAG__', $tag).Replace('__POSH__', $posh).Replace('__THEME__', $theme)

    $done = New-Object System.Collections.ArrayList
    foreach ($p in (Get-GuiReadyConsoleProfilePaths)) {
        try {
            $dir = Split-Path -Parent $p
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $cur = ''
            if (Test-Path -LiteralPath $p) { $cur = [System.IO.File]::ReadAllText($p) }
            if ($Remove) {
                $new = [regex]::Replace($cur, $pattern, '')
                if ($new -ne $cur) {
                    [System.IO.File]::WriteAllText($p, $new, (New-Object System.Text.UTF8Encoding($true)))
                    [void]$done.Add('已移除 ' + $p)
                }
            } else {
                # 逐行过滤掉所有历史 block，然后统一追加一份最新版（幂等）。
                # 这里踩过两个坑，所以用“状态机 + 特征行”双保险：
                #   1) 正则替换清不干净，会出现新旧共存；
                #   2) 历史上被写坏的 block（例如 $_ 被展开掉）会留下没有开始标记的“孤儿尾巴”，
                #      状态机识别不到 —— 坏 profile 会让 PowerShell 一启动就报语法错误。
                $oursPat = (@(
                    [regex]::Escape($tag),
                    '# --- end managed block ---',
                    '\[Console\]::IsOutputRedirected',
                    '\[scm\] oh-my-posh 初始化失败',
                    'init pwsh --config',
                    '^\s*\.Exception\.Message\).*ForegroundColor\s+Yellow\s*$'
                ) -join '|')
                $keep = New-Object System.Collections.ArrayList
                $inBlock = $false
                foreach ($ln in ($cur -split "`r?`n")) {
                    if ($ln -match [regex]::Escape($tag)) { $inBlock = $true; continue }
                    if ($inBlock) {
                        if ($ln -match '# --- end managed block ---') { $inBlock = $false }
                        continue
                    }
                    if ($ln -match $oursPat) { continue }   # 孤儿残留行
                    [void]$keep.Add($ln)
                }
                $new = (($keep -join "`r`n").TrimEnd("`r", "`n")) + "`r`n" + $block.TrimEnd("`r", "`n") + "`r`n"
                if ($new -ne $cur) {
                    [System.IO.File]::WriteAllText($p, $new, (New-Object System.Text.UTF8Encoding($true)))
                    [void]$done.Add('已写入/更新 ' + $p)
                } else {
                    [void]$done.Add('已是最新 ' + $p)
                }
            }
        } catch {
            [void]$done.Add('失败 ' + $p + ': ' + $_.Exception.Message)
        }
    }
    if (-not $Quiet) { foreach ($d in $done) { Write-Log ('profile: ' + $d) 'OK' } }
    return @($done)
}

function Set-GuiReadyConsoleWelcome {
    # 让「任何终端窗口」都显示两个入口提示（用户要求）：
    #   cmd        → HKCU\Software\Microsoft\Command Processor\AutoRun 指向 bin\scm-welcome.cmd
    #   PowerShell → profile 的 managed block 里直接 Write-Host（见 Write-GuiReadyConsoleProfileHook）
    # 注意：两者都要在“非交互”场景安静 —— cmd /c 时 bat 自己判断，PowerShell 用 IsOutputRedirected。
    param([switch]$Remove, [switch]$Quiet)

    $bin    = Get-GuiReadyConsoleRoot
    $script:path = Join-Path $bin 'scm-welcome.cmd'
    $cpKey  = 'HKCU:\Software\Microsoft\Command Processor'
    $valName = 'AutoRun'
    $ok = $true

    try {
        if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
        if (-not (Test-Path $cpKey)) { New-Item -Path $cpKey -Force | Out-Null }
        $old = [string](Get-ItemProperty -Path $cpKey -Name $valName -ErrorAction SilentlyContinue).$valName

        if ($Remove) {
            if ($old -and $old -like '*scm-welcome.cmd*') {
                Remove-ItemProperty -Path $cpKey -Name $valName -Force -ErrorAction SilentlyContinue
                if (-not $Quiet) { Write-Log '已移除 cmd 启动提示（AutoRun）' 'OK' }
            } elseif ($old) {
                if (-not $Quiet) { Write-Log ('AutoRun 是别的程序设置的，保留不动: ' + $old) 'WARN' }
            }
            if (Test-Path -LiteralPath $script:path) { Remove-Item -LiteralPath $script:path -Force -ErrorAction SilentlyContinue }
            return $true
        }

        # 备份原 AutoRun（便于人工回退）
        if ($old -and $old -notlike '*scm-welcome.cmd*') {
            try {
                $bkDir = Join-Path $script:BackupDir ('cmdAutoRun-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $bkDir 'AutoRun.txt'), $old, (New-Object System.Text.UTF8Encoding($true)))
                if (-not $Quiet) { Write-Log ('已备份原 AutoRun: ' + $old) 'OK' }
            } catch { }
        }

        # 用系统 ANSI 编码写 .cmd（cmd 按 ANSI 读取批处理，用 UTF-8 会让中文变乱码）
        # ⚠ 安全要求（踩过的坑，务必保持）：
        #   1) 只用 cmd 内建命令，绝不能出现管道或外部命令（例如 echo X | find /i "/c"）——
        #      AutoRun 对**每个新 cmd 实例**都生效，管道会拉起子 cmd，子 cmd 又跑 AutoRun，
        #      实测直接造成几千个 cmd/find 无限递归，把机器拖死。
        #   2) 第一件事就用环境变量打标记，子 cmd 继承该变量后立刻退出（双保险，防任何未来改动引入递归）。
        #   3) 判断是否交互式：先把 CMDCMDLINE 里的引号去掉再比较（CMDCMDLINE 自带引号，
        #      例如 "C:\Windows\System32\cmd.exe" /c "echo hi"，直接塞进 if 的引号比较会让 cmd 报
        #      "… was unexpected at this time"），然后用纯字符串替换判断有没有 /c。
        #   4) 必须写成 CRLF 换行：cmd 的批处理解析器要求 CRLF，LF-only 的 .cmd 会被解析得乱七八糟
        #      （实测每行被拆断、报一堆 "xxx is not recognized"）。本仓库源文件是 LF，
        #      here-string 里的换行也是 LF，所以这里必须显式归一化。
        $bat = @"
@echo off
rem ServerCoreManager: welcome note for interactive cmd (managed by ServerCoreManager)
rem --force: called by the "cls" doskey macro - always print, skip the guards below
if "%~1"=="--force" goto :show
rem guard: AutoRun runs for every new cmd instance - this flag makes sure it runs only once
if defined SCM_WELCOME_DONE exit /b 0
set SCM_WELCOME_DONE=1
rem stay silent for non-interactive calls (cmd /c ...) - no pipes, no external commands
set "SCM_CL=%CMDCMDLINE:"=%"
if not "%SCM_CL:/c=%"=="%SCM_CL%" exit /b 0
rem make "cls" print the note again: doskey macros are per-process, so register on every start
rem (must stay freestanding - no pipe, no external command, or AutoRun recursion comes back)
doskey cls=cls `$T "%~f0" --force >nul 2>&1
:show
echo.
echo   __ESC__[93m输入 "Sconfig" 返回服务器菜单__ESC__[0m
echo   __ESC__[93m输入 "scm" 打开 GUI 工具__ESC__[0m
echo.
"@
        # ANSI 亮黄（93）需要 VT 支持 —— 「一键美化终端」会设置 HKCU\Console\VirtualTerminalLevel=1
        $bat = $bat.Replace('__ESC__', [string][char]27)
        $bat = ($bat -replace "`r?`n", "`r`n")
        [System.IO.File]::WriteAllText($script:path, $bat, [System.Text.Encoding]::Default)

        # 写后自检：必须有 CRLF，否则宁可放弃也不留下一个会让 cmd 错乱的脚本
        $chk = [System.IO.File]::ReadAllBytes($script:path)
        $hasCrlf = $false
        for ($i = 0; $i -lt ($chk.Length - 1); $i++) { if ($chk[$i] -eq 13 -and $chk[$i + 1] -eq 10) { $hasCrlf = $true; break } }
        if (-not $hasCrlf) {
            Remove-Item -LiteralPath $script:path -Force -ErrorAction SilentlyContinue
            Write-Log '生成的 cmd 提示脚本缺少 CRLF（cmd 会解析错乱），已取消设置 AutoRun。' 'ERROR'
            return $false
        }

        Set-ItemProperty -Path $cpKey -Name $valName -Value ('"' + $script:path + '"') -Type String -Force
        $rb = [string](Get-ItemProperty -Path $cpKey -Name $valName -ErrorAction SilentlyContinue).$valName
        if (-not $Quiet) { Write-Log ('cmd 启动提示已启用（AutoRun = ' + $rb + '）') 'OK' }
    } catch {
        $ok = $false
        if (-not $Quiet) { Write-Log ('写 cmd 启动提示失败: ' + $_.Exception.Message) 'WARN' }
    }
    return $ok
}

function Test-GuiReadyConsoleWelcome {
    $o = [ordered]@{ CmdHook = $false; ScriptExists = $false; ProfileNote = $false }
    try {
        $val = [string](Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Command Processor' -Name 'AutoRun' -ErrorAction SilentlyContinue).AutoRun
        $o.CmdHook = ($val -like '*scm-welcome.cmd*')
    } catch { }
    try { $o.ScriptExists = (Test-Path -LiteralPath (Join-Path (Get-GuiReadyConsoleRoot) 'scm-welcome.cmd')) } catch { }
    try {
        $h = Test-GuiReadyConsoleProfileHook
        if ($h.Hooked -and $h.Path -and (Test-Path -LiteralPath $h.Path)) {
            $o.ProfileNote = ([System.IO.File]::ReadAllText($h.Path) -match 'Sconfig')
        }
    } catch { }
    return [pscustomobject]$o
}

function Install-GuiReadyPowerShell7 {
    param(
        [string]$Url = '',
        [string]$ZipPath = '',
        [switch]$SkipProfile,
        [switch]$SkipPath,
        [switch]$WhatIf
    )

    Write-Head '安装 PowerShell 7（zip 免安装，国内源优先）'
    if (-not (Assert-Administrator)) { return $false }

    $info = $null
    if ($ZipPath) {
        if (-not (Test-Path -LiteralPath $ZipPath)) { Write-Log ('本地 zip 不存在: ' + $ZipPath) 'ERROR'; return $false }
        $info = [pscustomobject]@{ Ok = $true; Version = '(本地包)'; Name = (Split-Path $ZipPath -Leaf); Url = ''; FromMirror = $false; Note = '使用本地 zip' }
    } elseif ($Url) {
        $info = [pscustomobject]@{ Ok = $true; Version = '(指定链接)'; Name = (Split-Path $Url -Leaf); Url = $Url; FromMirror = ($Url -match 'tuna|mirror'); Note = '用户指定链接' }
    } else {
        Write-Log ('查询最新版本（优先清华镜像 ' + $Global:GuiReadyMirrorTuna + '，避开 GitHub 限流）...') 'STEP'
        $info = Get-GuiReadyPowerShell7Latest
    }
    if (-not $info.Ok) {
        Write-Log ('拿不到 PowerShell 7 的下载信息：' + $info.Note) 'ERROR'
        Write-Log '可以在参数里直接给一个 zip 路径或下载链接（内网源也行）。' 'INFO'
        return $false
    }
    Write-Log ('版本 ' + $info.Version + '，包 ' + $info.Name) 'OK'
    Write-Log ('来源 ' + $info.Note) 'INFO'

    $target = Join-Path $env:ProgramFiles 'PowerShell\7'
    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        Write-Log ('将下载并解压到 ' + $target) 'DRY'
        Write-Log '将把该目录加入系统 PATH' 'DRY'
        Write-Log '将给 PowerShell 5.1 与 7 都写 oh-my-posh 初始化（若已做过美化）' 'DRY'
        return $true
    }

    $zip = $ZipPath
    if (-not $zip) {
        $dlDir = Join-Path $script:LogDir 'powershell7'
        if (-not (Test-Path -LiteralPath $dlDir)) { New-Item -ItemType Directory -Path $dlDir -Force | Out-Null }
        $dl = Join-Path $dlDir $info.Name
        if ((Test-Path -LiteralPath $dl) -and ((Get-Item -LiteralPath $dl).Length -gt 20MB)) {
            Write-Log ('已存在下载好的包，跳过下载: ' + $dl) 'OK'
        } else {
            $useUrl = Get-GuiReadyDownloadUrl -Url $info.Url
            Write-Log ('下载: ' + $useUrl) 'STEP'
            & (Get-GuiReadyCurlPath) -L --ssl-no-revoke --retry 4 --retry-delay 3 --retry-all-errors -s -S -o $dl $useUrl 2>$null
            if (-not (Test-Path -LiteralPath $dl) -or (Get-Item -LiteralPath $dl).Length -lt 20MB) {
                Write-Log '镜像没下下来，回退官方地址再试一次...' 'WARN'
                & (Get-GuiReadyCurlPath) -L --ssl-no-revoke --retry 3 --retry-delay 3 --retry-all-errors -s -S -o $dl $info.Url 2>$null
            }
            if (-not (Test-Path -LiteralPath $dl) -or (Get-Item -LiteralPath $dl).Length -lt 20MB) {
                Write-Log '下载失败（网络或镜像不可用）。' 'ERROR'
                return $false
            }
        }
        $zip = $dl
    }
    Write-Log ('包大小 ' + [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1) + ' MB') 'OK'

    Expand-GuiReadyZipOverwrite -ZipPath $zip -TargetDir $target | Out-Null
    $exe = Join-Path $target 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Write-Log '解压后没找到 pwsh.exe，可能包不完整。' 'ERROR'; return $false }
    Write-Log ('已解压到 ' + $target) 'OK'

    if (-not $SkipPath) {
        try {
            $cur = [string][Environment]::GetEnvironmentVariable('Path', 'Machine')
            if ($cur -notlike ('*' + $target + '*')) {
                [Environment]::SetEnvironmentVariable('Path', ($cur.TrimEnd(';') + ';' + $target), 'Machine')
                Write-Log '已加入系统 PATH（新开的窗口里可直接输入 pwsh）' 'OK'
            } else {
                Write-Log '系统 PATH 里已有该目录' 'OK'
            }
        } catch { Write-Log ('PATH 写入失败: ' + $_.Exception.Message) 'WARN' }
    }

    if (-not $SkipProfile) { Write-GuiReadyConsoleProfileHook | Out-Null }

    try {
        $v = ((& $exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1) -as [string])
        Write-Log ('实测 pwsh 版本: ' + $v) 'OK'
    } catch { Write-Log ('pwsh 启动失败: ' + $_.Exception.Message) 'WARN' }

    Write-Log 'PowerShell 7 装好了：新开窗口输入 pwsh 即可（scm-term 里也没问题）。' 'INFO'
    Save-JsonReport -Object (Get-GuiReadyConsoleStatus) -Name 'console-ps7' | Out-Null
    return $true
}

function Get-GuiReadyConsoleStatus {
    $assets = Find-GuiReadyConsoleAssets
    $font = Test-GuiReadyConsoleFont
    $keys = Get-GuiReadyConsoleFontKeys
    $user = Get-GuiReadyConsoleUserSettings
    $hook = Test-GuiReadyConsoleProfileHook
    $ps7 = Get-GuiReadyPowerShell7Paths
    $bin = Get-GuiReadyConsoleRoot

    # 当前生效的主题（从 profile 的 --config 读回来）+ bin\themes 里可切换的主题数
    $themeCur = ''
    try {
        if ($hook.Hooked -and $hook.Path -and (Test-Path -LiteralPath $hook.Path)) {
            $txt = [System.IO.File]::ReadAllText($hook.Path)
            $m = [regex]::Match($txt, "--config '([^']+)'")
            if ($m.Success) { $themeCur = Split-Path -Leaf $m.Groups[1].Value }
        }
    } catch { }
    $themesAvail = @(Get-ChildItem -LiteralPath (Join-Path $bin 'themes') -File -Filter '*.omp.json' -ErrorAction SilentlyContinue).Count

    $o = [ordered]@{
        AssetDir        = $assets.Dir
        AssetMissing    = @($assets.Missing)
        FontFace        = $Global:GuiReadyConsoleFontFace
        FontInstalled   = $font.Installed
        FontNote        = $font.Note
        FontWhitelist   = @($keys.WhitelistKeys)
        FontLinked      = $keys.FontLinked
        BinDir          = $bin
        PoshInstalled   = (Test-Path -LiteralPath (Join-Path $bin 'oh-my-posh.exe'))
        FastfetchInstalled = (Test-Path -LiteralPath (Join-Path $bin 'fastfetch.exe'))
        LauncherInstalled  = (Test-Path -LiteralPath (Join-Path $bin 'scm-term.cmd'))
        ProfilePath     = $hook.Path
        ProfileHooked   = $hook.Hooked
        PowerShell7     = $ps7.Installed
        PowerShell7Ver  = $ps7.Version
        PowerShell7Exe  = $ps7.Exe
        ThemeCurrent    = $themeCur
        ThemesAvailable = $themesAvail
        MirrorTuna      = $Global:GuiReadyMirrorTuna
        MirrorGithub    = $Global:GuiReadyMirrorGithub
        UserFaceName    = $user.FaceName
        UserVT          = $user.VT
        UserForceV2     = $user.ForceV2
        UserColors      = $user.Colors
        Conclusion      = ''
    }

    if (-not $font.Installed) {
        $o.Conclusion = '还没美化：Nerd Font 未安装。用「终端美化 → 一键美化终端」安装（素材随发布包内置，不联网）。'
    } elseif ($keys.WhitelistKeys.Count -eq 0) {
        $o.Conclusion = '字体装了但没进控制台白名单：conhost 不会列出它。请重跑一次「一键美化终端」。'
    } elseif (-not $o.LauncherInstalled) {
        $o.Conclusion = '字体与白名单就绪，但缺启动器 scm-term.cmd（美化终端靠它切 UTF-8 并应用字体）。请重跑一次「一键美化终端」。'
    } else {
        $o.Conclusion = '已就绪：用「终端美化 → 打开美化终端」（或命令行输入 scm-term）即可；中文代码页 936 下 conhost 不接受拉丁 Nerd Font，所以必须走这个入口。'
    }
    return [pscustomobject]$o
}

function Show-GuiReadyConsoleStatus {
    param([switch]$DeepProbe)

    Write-Head '终端美化状态（Nerd Font + Oh My Posh + Fastfetch）'
    $s = Get-GuiReadyConsoleStatus

    Write-Log ('字体        : {0}  {1}' -f $s.FontFace, $s.FontNote) $(if ($s.FontInstalled) { 'OK' } else { 'WARN' })
    Write-Log ('控制台白名单: {0}' -f $(if ($s.FontWhitelist.Count -gt 0) { ($s.FontWhitelist -join ', ') } else { '(没有)' })) $(if ($s.FontWhitelist.Count -gt 0) { 'OK' } else { 'WARN' })
    Write-Log ('中文回退    : {0}' -f $(if ($s.FontLinked) { '已配置（FontLink）' } else { '(未配置)' })) $(if ($s.FontLinked) { 'OK' } else { 'WARN' })
    Write-Log ('oh-my-posh  : {0}' -f $(if ($s.PoshInstalled) { '已安装' } else { '未安装' })) $(if ($s.PoshInstalled) { 'OK' } else { 'WARN' })
    Write-Log ('fastfetch   : {0}' -f $(if ($s.FastfetchInstalled) { '已安装' } else { '未安装' })) $(if ($s.FastfetchInstalled) { 'OK' } else { 'WARN' })
    Write-Log ('启动器      : scm-term.cmd  {0}' -f $(if ($s.LauncherInstalled) { '已就绪' } else { '缺失' })) $(if ($s.LauncherInstalled) { 'OK' } else { 'WARN' })
    Write-Log ('PowerShell profile: {0}' -f $(if ($s.ProfileHooked) { '已写入初始化（' + $s.ProfilePath + '）' } else { '未写入' })) $(if ($s.ProfileHooked) { 'OK' } else { 'WARN' })
    Write-Log ('控制台外观（HKCU）: FaceName={0}  VT={1}  ForceV2={2}  配色={3}/16' -f $s.UserFaceName, $s.UserVT, $s.UserForceV2, $s.UserColors) 'INFO'
    Write-Log ('PowerShell 7: {0}' -f $(if ($s.PowerShell7) { '已安装 ' + $s.PowerShell7Ver } else { '未安装（可选，装了体验更好）' })) $(if ($s.PowerShell7) { 'OK' } else { 'INFO' })
    Write-Log ('oh-my-posh 主题: {0}（bin\themes 可切换 {1} 个）' -f $(if ($s.ThemeCurrent) { $s.ThemeCurrent } else { '默认 theme.omp.json' }), $s.ThemesAvailable) 'INFO'
    $wel = Test-GuiReadyConsoleWelcome
    Write-Log ('入口提示    : cmd {0} / PowerShell {1}（"Sconfig" 返回服务器菜单、"scm" 打开 GUI）' -f `
        $(if ($wel.CmdHook) { '已启用' } else { '未启用' }), $(if ($wel.ProfileNote) { '已启用' } else { '未启用' })) 'INFO'
    Write-Log ('下载源      : PowerShell 7 走清华镜像 {0}' -f $s.MirrorTuna) 'INFO'
    if ($s.MirrorGithub) { Write-Log ('              GitHub 走自建源 {0}' -f $s.MirrorGithub) 'INFO' }

    if ($s.AssetMissing.Count -gt 0) {
        Write-Log ('离线素材缺失: ' + ($s.AssetMissing -join '，')) 'WARN'
        Write-Log ('把它们放进 ' + (Join-Path $script:GuiReadyRoot $Global:GuiReadyConsoleAssetDir) + '（发布包内应已自带）') 'INFO'
    } else {
        Write-Log ('离线素材: 完整（' + $s.AssetDir + '）') 'OK'
    }

    if ($DeepProbe -and $s.LauncherInstalled) {
        Write-Log '实测：用 scm-term 新开一个控制台并回读实际字体...' 'STEP'
        $p = Invoke-GuiReadyConsoleProbe
        if ($p.Ok) { Write-Log ('  ' + $p.Result) 'OK' }
        else { Write-Log ('  失败：' + $p.Note + '  ' + $p.Result) 'ERROR' }
    }

    Write-Log ''
    Write-Log $s.Conclusion $(if ($s.FontInstalled -and $s.FontWhitelist.Count -gt 0 -and $s.LauncherInstalled) { 'OK' } else { 'WARN' })
    return $s
}

function Install-GuiReadyConsoleTheme {
    param(
        [string]$AssetDir = '',
        [string]$Theme = '',
        [switch]$SkipPosh,
        [switch]$SkipFastfetch,
        [switch]$SkipAppearance,
        [switch]$SkipProbe,
        [switch]$WhatIf
    )

    Write-Head '一键美化终端（Nerd Font + Oh My Posh + Fastfetch）'

    if (-not (Assert-Administrator)) { return $false }
    if ($AssetDir) { $script:GuiReadyConsoleAssetDirUsed = $AssetDir }

    $assets = Find-GuiReadyConsoleAssets
    if ($assets.Missing.Count -gt 0) {
        Write-Log ('离线素材不完整，缺少: ' + ($assets.Missing -join '，')) 'ERROR'
        Write-Log ('应该放在: ' + (Join-Path $script:GuiReadyRoot $Global:GuiReadyConsoleAssetDir)) 'INFO'
        Write-Log '需要的文件：MesloLGS NF 的 ttf、oh-my-posh.exe、主题 *.omp.json、Set-ScmConsoleFont.ps1、scm-term.cmd' 'INFO'
        return $false
    }
    Write-Log ('素材目录: ' + $assets.Dir) 'OK'

    # 主题：默认用素材里的 theme.omp.json；-Theme 指定时从内置主题集合里挑一个作为当前主题
    $themeSrc  = $assets.Theme
    $themeNote = '默认主题'
    if ($Theme) {
        $want = [string]$Theme
        if ($want -notmatch '(?i)\.omp\.json$') { $want = $want + '.omp.json' }
        $hit = @($assets.Themes | Where-Object { (Split-Path -Leaf $_) -ieq $want })
        if ($hit.Count -gt 0) {
            $themeSrc  = $hit[0]
            $themeNote = '内置主题 ' + (Split-Path -Leaf $hit[0])
            Write-Log ('使用主题: ' + $themeNote) 'OK'
        } else {
            Write-Log ('没有找到主题 "{0}"，改用默认主题。可用: {1}' -f $Theme, ((@($assets.Themes | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))) 'WARN'
        }
    }
    if ($assets.Themes.Count -gt 0) {
        Write-Log ('内置主题 {0} 个: {1}' -f $assets.Themes.Count,
            ((@($assets.Themes | ForEach-Object { (Split-Path -Leaf $_) -replace '\.omp\.json$', '' }) -join ', '))) 'INFO'
    }

    $bin = Get-GuiReadyConsoleRoot
    $fontDirS = Join-Path $env:windir 'Fonts'
    $regFonts = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $ttfKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Console\TrueTypeFont'
    $linkKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink'

    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        Write-Log ('将安装字体 {0} 个 → {1}，并写 Fonts / TrueTypeFont(0936) / FontLink 注册表' -f $assets.Fonts.Count, $fontDirS) 'DRY'
        Write-Log ('将复制到 bin: oh-my-posh.exe、fastfetch.exe、主题、Set-ScmConsoleFont.ps1、scm-term.cmd') 'DRY'
        Write-Log ('将使用的主题: {0}（另有 {1} 个内置主题会一起复制到 bin\themes）' -f $themeNote, $assets.Themes.Count) 'DRY'
        Write-Log ('将写 HKCU\Console: VirtualTerminalLevel=1、ForceV2=1、FaceName/字号/配色（先备份原值到 backup 目录）') 'DRY'
        Write-Log ('将往 PowerShell profile 写入 oh-my-posh 初始化（可撤销的 managed 块）') 'DRY'
        Write-Log '将给 cmd（AutoRun）与 PowerShell（profile）都加上入口提示：输入 "Sconfig" 返回服务器菜单 / 输入 "scm" 打开 GUI 工具' 'DRY'
        Write-Log ('将把 scm-term.cmd 放进 PATH，方便任意目录输入 scm-term') 'DRY'
        return $true
    }

    # 1) 备份用户当前控制台外观，便于还原
    try {
        $backup = [ordered]@{}
        $c = Get-ItemProperty 'HKCU:\Console' -ErrorAction SilentlyContinue
        if ($c) {
            foreach ($n in @('FaceName','FontFamily','FontSize','FontWeight','VirtualTerminalLevel','ForceV2','ScreenColors','PopupColors','CodePage')) {
                if ($null -ne $c.$n) { $backup[$n] = $c.$n }
            }
            foreach ($i in 0..15) { $k = 'ColorTable{0:D2}' -f $i; if ($null -ne $c.$k) { $backup[$k] = $c.$k } }
        }
        $bp = Join-Path $script:BackupDir ('console-hkcu-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        [System.IO.File]::WriteAllText($bp, ($backup | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($true)))
        Write-Log ('已备份当前控制台外观: ' + $bp) 'OK'
    } catch { Write-Log ('备份失败（继续）: ' + $_.Exception.Message) 'WARN' }

    # 2) 安装字体（全机）
    #    注意：字体文件被系统加载（user-mapped section）时无法覆盖，这是正常现象，
    #    此时只要文件已在、注册表项在，就算装好了（实测报错原文：cannot be performed on a file with a user-mapped section open）。
    $ok = $true
    foreach ($f in $assets.Fonts) {
        $src = Get-Item -LiteralPath $f
        $dst = Join-Path $fontDirS $src.Name
        $already = $false
        if (Test-Path -LiteralPath $dst) {
            try { $already = ((Get-Item -LiteralPath $dst).Length -eq $src.Length) } catch { $already = $true }
        }
        if ($already) {
            Write-Log ('字体已就位（跳过覆盖）: ' + $src.Name) 'OK'
        } else {
            try {
                Copy-Item -LiteralPath $src.FullName -Destination $dst -Force -ErrorAction Stop
                Write-Log ('字体就位: ' + $src.Name) 'OK'
            } catch {
                if (Test-Path -LiteralPath $dst) {
                    Write-Log ('字体已在系统中（被加载中无法覆盖，跳过）: ' + $src.Name) 'OK'
                } else {
                    Write-Log ('字体安装失败 ' + $src.Name + ': ' + $_.Exception.Message) 'ERROR'
                    $ok = $false
                    continue
                }
            }
        }
        try {
            New-ItemProperty -Path $regFonts -Name ($src.Name + ' (TrueType)') -Value $src.Name -PropertyType String -Force | Out-Null
        } catch {
            Write-Log ('字体注册表写入失败 ' + $src.Name + ': ' + $_.Exception.Message) 'WARN'
        }
    }
    if (-not $ok) { return $false }

    # 3) 控制台字体白名单（中文代码页用 0936；再补 936 与拉丁键，兼容不同控制台）
    foreach ($k in @('0936', '936', '0', '00')) {
        try {
            $cur = [string]((Get-Item -LiteralPath $ttfKey -ErrorAction SilentlyContinue).GetValue($k))
            if ([string]::IsNullOrEmpty($cur)) {
                New-ItemProperty -Path $ttfKey -Name $k -Value $Global:GuiReadyConsoleFontFace -PropertyType String -Force | Out-Null
                Write-Log ('控制台白名单 ' + $k + ' → ' + $Global:GuiReadyConsoleFontFace) 'OK'
            }
        } catch { Write-Log ('白名单 ' + $k + ' 写入失败: ' + $_.Exception.Message) 'WARN' }
    }

    # 4) 中文回退（否则中文会走默认字体/方块）
    try {
        $vals = @('msyh.ttc,Microsoft YaHei', 'msyh.ttc,Microsoft YaHei UI', 'simsun.ttc,SimSun')
        New-ItemProperty -Path $linkKey -Name $Global:GuiReadyConsoleFontFace -Value $vals -PropertyType MultiString -Force | Out-Null
        Write-Log '中文回退（FontLink → 微软雅黑）已配置' 'OK'
    } catch { Write-Log ('FontLink 写入失败: ' + $_.Exception.Message) 'WARN' }

    # 5) 复制程序与脚本到 bin
    if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
    $copyMap = @()
    if (-not $SkipPosh -and $assets.Posh) { $copyMap += @{ Src = $assets.Posh; Name = 'oh-my-posh.exe' } }
    if (-not $SkipFastfetch -and $assets.Fastfetch) { $copyMap += @{ Src = $assets.Fastfetch; Name = 'fastfetch.exe' } }
    if ($themeSrc) { $copyMap += @{ Src = $themeSrc; Name = 'theme.omp.json' } }
    if ($assets.FontScript) { $copyMap += @{ Src = $assets.FontScript; Name = 'Set-ScmConsoleFont.ps1' } }
    if ($assets.Launcher) { $copyMap += @{ Src = $assets.Launcher; Name = 'scm-term.cmd' } }
    foreach ($m in $copyMap) {
        try {
            Copy-Item -LiteralPath $m.Src -Destination (Join-Path $bin $m.Name) -Force -ErrorAction Stop
            Write-Log ('已复制: ' + $m.Name) 'OK'
        } catch { Write-Log ('复制失败 ' + $m.Name + ': ' + $_.Exception.Message) 'ERROR' }
    }

    # 内置主题集合也一起带上（bin\themes\*.omp.json）：想换风格时改 profile 里的 --config 即可
    if ($assets.Themes.Count -gt 0) {
        $themeDst = Join-Path $bin 'themes'
        if (-not (Test-Path -LiteralPath $themeDst)) { New-Item -ItemType Directory -Path $themeDst -Force | Out-Null }
        $nOk = 0
        foreach ($t in $assets.Themes) {
            try {
                Copy-Item -LiteralPath $t -Destination (Join-Path $themeDst (Split-Path -Leaf $t)) -Force -ErrorAction Stop
                $nOk++
            } catch { Write-Log ('主题复制失败 ' + (Split-Path -Leaf $t) + ': ' + $_.Exception.Message) 'WARN' }
        }
        Write-Log ('已复制内置主题 {0}/{1} 个 → {2}' -f $nOk, $assets.Themes.Count, $themeDst) 'OK'
    }

    # fastfetch 若以 zip 形式提供，提示手动解包（避免在安装动作里做静默解压）
    if (-not $SkipFastfetch -and -not $assets.Fastfetch) {
        Write-Log '未找到 fastfetch.exe（若素材是 zip，请解包后把 exe 放到 setup\console\）—— 跳过首屏 banner。' 'WARN'
    }

    # 6) 用户级控制台外观（VT 是 oh-my-posh 颜色的前提）
    if (-not $SkipAppearance) {
        try {
            if (-not (Test-Path 'HKCU:\Console')) { New-Item -Path 'HKCU:\Console' -Force | Out-Null }
            Set-ItemProperty -Path 'HKCU:\Console' -Name 'VirtualTerminalLevel' -Value 1 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKCU:\Console' -Name 'ForceV2' -Value 1 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKCU:\Console' -Name 'FaceName' -Value $Global:GuiReadyConsoleFontFace -Type String -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKCU:\Console' -Name 'FontFamily' -Value 54 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKCU:\Console' -Name 'FontWeight' -Value 400 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKCU:\Console' -Name 'FontSize' -Value 0x00120000 -Type DWord -ErrorAction SilentlyContinue
            $colors = @(0x001E1E1E, 0x00562A2A, 0x004E6B2E, 0x00A0A000, 0x00355A8C, 0x00834E9E, 0x0000A0A0, 0x00D4D4D4,
                        0x00808080, 0x00E05757, 0x0072C554, 0x00E5E510, 0x004F9CF0, 0x00C678DD, 0x0000D7D7, 0x00FFFFFF)
            for ($i = 0; $i -lt 16; $i++) {
                Set-ItemProperty -Path 'HKCU:\Console' -Name ('ColorTable{0:D2}' -f $i) -Value $colors[$i] -Type DWord -ErrorAction SilentlyContinue
            }
            Set-ItemProperty -Path 'HKCU:\Console' -Name 'ScreenColors' -Value 0x0007 -Type DWord -ErrorAction SilentlyContinue
            Write-Log '控制台外观已设置（打开 ANSI/VT、Nerd Font、One Dark 配色）' 'OK'
        } catch { Write-Log ('控制台外观写入失败: ' + $_.Exception.Message) 'WARN' }
    }

    # 7) PowerShell profile：入口提示 + oh-my-posh 初始化（同一段 managed block，幂等）
    #    即使 SkipPosh（不装 oh-my-posh），也写提示 —— 用户要求任何终端窗口都能看到两个入口。
    Write-GuiReadyConsoleProfileHook | Out-Null

    # 7.5) cmd 的启动提示：写 HKCU\Software\Microsoft\Command Processor\AutoRun（原值会备份）
    Set-GuiReadyConsoleWelcome | Out-Null

    # 8) 把启动器放进 PATH（任意目录输入 scm-term 就能开美化终端）
    try {
        $sys32 = Join-Path $env:windir 'System32'
        $target = Join-Path $sys32 'scm-term.cmd'
        $srcLauncher = Join-Path $bin 'scm-term.cmd'
        if (Test-Path -LiteralPath $srcLauncher) {
            $content = @(
                '@echo off',
                'rem launcher installed by ServerCoreManager - do not edit',
                'call "' + $srcLauncher + '" %*'
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.ASCIIEncoding))
            Write-Log ('已安装命令: scm-term  （' + $target + '）') 'OK'
        }
    } catch { Write-Log ('安装 scm-term 命令失败: ' + $_.Exception.Message) 'WARN' }

    # 9) 实测
    if (-not $SkipProbe) {
        Write-Log '实测：用启动器新开控制台并回读 conhost 实际字体...' 'STEP'
        $p = Invoke-GuiReadyConsoleProbe
        if ($p.Ok) { Write-Log ('  ' + $p.Result) 'OK' }
        else { Write-Log ('  失败：' + $p.Note + '  ' + $p.Result) 'ERROR' }
    }

    Write-Log ''
    Write-Log '完成后用「终端美化 → 打开美化终端」（或命令行 scm-term）打开即可看到效果。' 'INFO'
    Write-Log '注意：中文代码页 936 下 conhost 不接受拉丁 Nerd Font，所以普通 cmd 窗口还是老样子，美化终端必须走 scm-term 入口。' 'WARN'
    Save-JsonReport -Object (Get-GuiReadyConsoleStatus) -Name 'console-theme' | Out-Null
    return $true
}

function Restore-GuiReadyConsoleTheme {
    param(
        [switch]$KeepFonts,     # 默认连字体一起卸掉
        [switch]$KeepFiles,     # 默认删掉 bin 里的程序与脚本
        [switch]$WhatIf
    )

    Write-Head '还原终端美化'

    if (-not (Assert-Administrator)) { return $false }

    $bin = Get-GuiReadyConsoleRoot
    $ttfKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Console\TrueTypeFont'
    $linkKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink'
    $regFonts = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $fontDirS = Join-Path $env:windir 'Fonts'

    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        Write-Log '将把 HKCU\Console 恢复为安装前的备份值（backup\console-hkcu-*.json）' 'DRY'
        Write-Log '将删除 profile 里的 managed 初始化块' 'DRY'
        if (-not $KeepFonts) { Write-Log ('将删除字体文件与 Fonts / TrueTypeFont / FontLink 里的相关项') 'DRY' }
        if (-not $KeepFiles) { Write-Log ('将删除 ' + $bin + ' 下的 oh-my-posh/fastfetch/脚本') 'DRY' }
        Write-Log '将删除 PATH 里的 scm-term.cmd' 'DRY'
        return $true
    }

    # 1) 恢复 HKCU\Console（取最近的备份）
    try {
        $bp = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'console-hkcu-*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($bp.Count -gt 0) {
            $obj = Get-Content -LiteralPath $bp[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) {
                Set-ItemProperty -Path 'HKCU:\Console' -Name $p.Name -Value $p.Value -ErrorAction SilentlyContinue
            }
            Write-Log ('已恢复控制台外观（来自 ' + $bp[0].Name + '）') 'OK'
        } else {
            Write-Log '没有找到控制台外观备份，跳过恢复 HKCU\Console。' 'WARN'
        }
    } catch { Write-Log ('恢复 HKCU\Console 失败: ' + $_.Exception.Message) 'WARN' }

    # 2) 删 profile managed 块（5.1 与 7 两边都清）
    Write-GuiReadyConsoleProfileHook -Remove | Out-Null

    # 3) 字体与注册表
    if (-not $KeepFonts) {
        foreach ($k in @('0936', '936', '0', '00')) {
            try {
                $cur = [string]((Get-Item -LiteralPath $ttfKey -ErrorAction SilentlyContinue).GetValue($k))
                if ($cur -eq $Global:GuiReadyConsoleFontFace) { Remove-ItemProperty -Path $ttfKey -Name $k -Force -ErrorAction SilentlyContinue; Write-Log ('已移除白名单 ' + $k) 'OK' }
            } catch { }
        }
        try { Remove-ItemProperty -Path $linkKey -Name $Global:GuiReadyConsoleFontFace -Force -ErrorAction SilentlyContinue } catch { }
        try {
            $names = @()
            $k = Get-Item -LiteralPath $regFonts -ErrorAction SilentlyContinue
            if ($k) { foreach ($n in $k.GetValueNames()) { if ([string]$k.GetValue($n) -match '(?i)^MesloLGS') { $names += $n } } }
            foreach ($n in $names) {
                $file = [string]$k.GetValue($n)
                Remove-ItemProperty -Path $regFonts -Name $n -Force -ErrorAction SilentlyContinue
                try { Remove-Item -LiteralPath (Join-Path $fontDirS $file) -Force -ErrorAction SilentlyContinue } catch { }
                Write-Log ('已移除字体: ' + $file) 'OK'
            }
        } catch { Write-Log ('字体清理失败: ' + $_.Exception.Message) 'WARN' }
    }

    # 3.5) 移除 cmd 启动提示（AutoRun 只在指向本工具脚本时才动，别人的设置不碰）
    if (-not $KeepFiles) { Set-GuiReadyConsoleWelcome -Remove -Quiet | Out-Null }

    # 4) bin 与 PATH 里的命令
    if (-not $KeepFiles) {
        foreach ($n in @('oh-my-posh.exe', 'fastfetch.exe', 'theme.omp.json', 'Set-ScmConsoleFont.ps1', 'scm-term.cmd')) {
            try { Remove-Item -LiteralPath (Join-Path $bin $n) -Force -ErrorAction SilentlyContinue } catch { }
        }
        try { Remove-Item -LiteralPath (Join-Path $bin 'themes') -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        Write-Log ('已清理 ' + $bin) 'OK'
    }
    try {
        $target = Join-Path (Join-Path $env:windir 'System32') 'scm-term.cmd'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue; Write-Log '已移除命令 scm-term' 'OK' }
    } catch { }

    Write-Log '还原完成。已打开的窗口需要关掉重开才会恢复旧外观。' 'INFO'
    return $true
}

function Start-GuiReadyConsoleTheme {
    # 打开美化终端（在当前会话；Session 0 时切到已登录用户的会话）
    Write-Head '打开美化终端'
    $bin = Get-GuiReadyConsoleRoot
    $launcher = Join-Path $bin 'scm-term.cmd'
    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-Log '还没安装美化终端（缺 scm-term.cmd）。先做「一键美化终端」。' 'ERROR'
        return $false
    }
    $ctx = Get-GuiReadyExecutionContext
    if ($ctx.SessionId -gt 0) {
        try {
            # 不要重定向 stdout：启动器需要控制台句柄
            Start-Process -FilePath $launcher -ErrorAction Stop | Out-Null
            Write-Log ('已在当前会话打开美化终端: ' + $launcher) 'OK'
            return $true
        } catch {
            Write-Log ('打开失败: ' + $_.Exception.Message) 'ERROR'
            return $false
        }
    }
    $sess = Get-GuiReadySessionInfo
    $cand = @($sess.ActiveWithUser | Select-Object -First 1)
    if ($cand.Count -eq 0) { $cand = @($sess.LoggedOn | Select-Object -First 1) }
    if ($cand.Count -eq 0) { Write-Log '当前是 Session 0，且没有已登录用户会话，无法打开窗口。' 'ERROR'; return $false }
    $target = [string]$cand[0].User
    Write-Log ('当前是 Session 0，改到用户 {0} 的会话里打开。' -f $target) 'STEP'
    $body  = (Get-GuiReadyPreamble)
    $body += ('Start-Process -FilePath ''{0}''' -f $launcher)
    $t = Invoke-GuiReadyElevatedTask -Name 'ConsoleOpen' -Body $body -AsUser $target -TimeoutSeconds 180 -PollSeconds 5
    Write-Log ('任务结果: ' + $t.Result) $(if ($t.Result -like 'EXIT=OK*') { 'OK' } else { 'ERROR' })
    return ($t.Result -like 'EXIT=OK*')
}

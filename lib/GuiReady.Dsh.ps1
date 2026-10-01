# GuiReady 的 DeepSeek Harness（dsh-TUI）集成。
#
# 规范见 想法.md 第七节：指定集成 ccch1mneyyy/dsh-TUI（npm 包 @deepseek-harness-tui/dsh-tui），
# 依赖 Node.js ≥ 22.19 / pnpm ≥ 10 / @deepseek-ai/dsh / DEEPSEEK_API_KEY。
#
# 一条重要原则：**npm 包到底存不存在，由 npm 自己回答**。本模块只负责把要执行的命令摆出来、
# 把 npm 的真实输出原样写进日志，不替它下"能装"的结论 —— 仓库里那串包名来自需求文档，
# 谁也不能凭记忆保证它还在。状态里的 PackageExists 就是 `npm view` 的实测结果。
#
# 调用方：gui\Run-GuiReadyDsh.ps1（状态）、Run-GuiReadyAction.ps1（安装 / 启动）。

function Resolve-GuiReadyDshExe {
    # 先 PATH，再回退到已知位置 —— 刚用 npm -g 装完的东西，当前进程 PATH 里还没有
    # （和 Chocolatey 那次踩的是同一个坑，见 GuiReady.Package.ps1 里的说明）。
    param([string]$Id)

    $c = $null
    try { $c = Get-Command $Id -ErrorAction SilentlyContinue } catch { }
    if ($c) { try { return [string]$c.Source } catch { } }

    $cands = @()
    switch ($Id) {
        'node' { $cands += 'C:\Program Files\nodejs\node.exe' }
        'npm'  { $cands += 'C:\Program Files\nodejs\npm.cmd' }
        'pnpm' { if ($env:APPDATA) { $cands += (Join-Path $env:APPDATA 'npm\pnpm.cmd') } }
        'dsh'  { if ($env:APPDATA) { $cands += (Join-Path $env:APPDATA 'npm\dsh.cmd') } }
        'dsh-tui' { if ($env:APPDATA) { $cands += (Join-Path $env:APPDATA 'npm\dsh-tui.cmd') } }
    }
    foreach ($x in $cands) {
        try { if ($x -and (Test-Path -LiteralPath $x)) { return [string]$x } } catch { }
    }
    return ''
}

function Add-GuiReadyDshPath {
    # 把 dsh 生态需要的目录补进当前进程的 PATH（子进程会继承），返回实际加进去的目录。
    #
    # 为什么必须做（都是实测踩到的）：
    #   1. npm 依赖的构建脚本用 `node ./xxx.cjs`，node 不在 PATH 里就报
    #      "'node' is not recognized" 让安装以 exit 1 结束；
    #   2. dsh-tui 启动时会自己去找 dsh CLI，找不到就直接退出并打印
    #      「[dsh-tui] 未检测到 dsh CLI」—— 而 dsh.cmd 装在 %APPDATA%\npm，
    #      这个目录同样可能不在当前进程的 PATH 里（node/npm 是本工具刚装的）。
    param()

    $dirs = @()
    $node = Resolve-GuiReadyDshExe -Id 'node'
    if ($node) { $dirs += (Split-Path -Parent $node) }
    $npm = Resolve-GuiReadyDshExe -Id 'npm'
    if ($npm) { $dirs += (Split-Path -Parent $npm) }
    if ($env:APPDATA)      { $dirs += (Join-Path $env:APPDATA 'npm') }
    if ($env:LOCALAPPDATA) { $dirs += (Join-Path $env:LOCALAPPDATA 'pnpm') }

    $added = @()
    foreach ($d in $dirs) {
        if (-not $d) { continue }
        try {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            if ($env:PATH -notlike ('*' + $d + '*')) {
                $env:PATH = $d + ';' + $env:PATH
                $added += $d
            }
        } catch { }
    }
    return $added
}

function Get-GuiReadyDshNpmPackage {
    # 问 npm：这两个包在不在、最新版本是多少。查不到就是查不到，不编。
    param([string[]]$Packages = @('@deepseek-ai/dsh', '@deepseek-harness-tui/dsh-tui'))

    $npm = Resolve-GuiReadyDshExe -Id 'npm'
    $out = @()
    foreach ($p in $Packages) {
        $item = [pscustomobject]@{ Package = $p; Exists = $false; Version = ''; Error = '' }
        if (-not $npm) { $item.Error = '本机没有 npm'; $out += $item; continue }
        try {
            $v = @(& $npm view $p version 2>&1) | Select-Object -First 1
            if ($LASTEXITCODE -eq 0 -and $v -and ([string]$v -notmatch '^(npm )?(ERR|WARN)')) {
                $item.Exists = $true
                $item.Version = ([string]$v).Trim()
            } else {
                $item.Error = ([string]$v).Trim()
            }
        } catch {
            $item.Error = $_.Exception.Message
        }
        $out += $item
    }
    return $out
}

function Get-GuiReadyDshStatus {
    # 依赖清单：每项带「装没装 / 版本 / 怎么装」。页面与动作共用这一份判断。
    param([switch]$DeepProbe)

    $rows = @()

    $node = Resolve-GuiReadyDshExe -Id 'node'
    $nodeVer = ''
    if ($node) { try { $nodeVer = (([string](& $node -v 2>$null))).Trim() } catch { } }
    $nodeOk = $false
    if ($nodeVer -match '^v?(\d+)\.') { $nodeOk = ([int]$Matches[1] -ge 22) }
    $rows += [pscustomobject]@{
        Id = 'node'; Name = 'Node.js'; Required = '≥ 22.19 或 ≥ 24'
        Installed = [bool]$node; Version = $nodeVer; Ok = $nodeOk
        Detail = $(if ($node) { $node } else { '未安装' })
        Advice = $(if (-not $node) { '用「商店」页或 choco install nodejs 装。' } elseif (-not $nodeOk) { '版本偏低，dsh-TUI 要求 Node 22.19+。' } else { '' })
    }

    $pnpm = Resolve-GuiReadyDshExe -Id 'pnpm'
    $pnpmVer = ''
    if ($pnpm) { try { $pnpmVer = (([string](& $pnpm -v 2>$null))).Trim() } catch { } }
    $pnpmOk = $false
    if ($pnpmVer -match '^(\d+)\.') { $pnpmOk = ([int]$Matches[1] -ge 10) }
    $rows += [pscustomobject]@{
        Id = 'pnpm'; Name = 'pnpm'; Required = '≥ 10'
        Installed = [bool]$pnpm; Version = $pnpmVer; Ok = $pnpmOk
        Detail = $(if ($pnpm) { $pnpm } else { '未安装' })
        Advice = $(if (-not $pnpm) { '一键安装会用 npm install -g pnpm 处理。' } elseif (-not $pnpmOk) { '版本偏低，建议升级到 10 以上。' } else { '' })
    }

    $dsh = Resolve-GuiReadyDshExe -Id 'dsh'
    $dshVer = ''
    if ($dsh) { try { $dshVer = (([string](& $dsh --version 2>$null))).Trim() } catch { } }
    $rows += [pscustomobject]@{
        Id = 'dsh'; Name = 'DSH 官方 CLI（@deepseek-ai/dsh）'; Required = '官方 CLI'
        Installed = [bool]$dsh; Version = $dshVer; Ok = [bool]$dsh
        Detail = $(if ($dsh) { $dsh } else { '未安装' })
        Advice = $(if (-not $dsh) { '一键安装会用 npm install -g @deepseek-ai/dsh 处理。' } else { '' })
    }

    $tui = Resolve-GuiReadyDshExe -Id 'dsh-tui'
    $rows += [pscustomobject]@{
        Id = 'dsh-tui'; Name = 'dsh-TUI（@deepseek-harness-tui/dsh-tui）'; Required = '本项目指定集成'
        Installed = [bool]$tui; Version = ''; Ok = [bool]$tui
        Detail = $(if ($tui) { $tui } else { '未安装' })
        Advice = $(if (-not $tui) { '一键安装会用 npm install -g @deepseek-harness-tui/dsh-tui 处理。' } else { '' })
    }

    $keySet = -not [string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)
    $rows += [pscustomobject]@{
        Id = 'api-key'; Name = 'DEEPSEEK_API_KEY'; Required = '必需（密钥）'
        Installed = $keySet; Version = $(if ($keySet) { '已设置（值不显示）' } else { '' }); Ok = $keySet
        Detail = $(if ($keySet) { '当前会话可见' } else { '未设置' })
        Advice = $(if (-not $keySet) { '密钥要用户自己设：setx DEEPSEEK_API_KEY "sk-..."，然后重开工具。工具不会把你的密钥写进脚本。' } else { '' })
    }

    $pkgs = @()
    if ($DeepProbe) { $pkgs = @(Get-GuiReadyDshNpmPackage) }

    return [pscustomobject]@{
        Stamp    = (Get-Date).ToString('s')
        Items    = $rows
        Npm      = $pkgs
        Ready    = (@($rows | Where-Object { -not $_.Ok }).Count -eq 0)
        NodePath = $node
        NpmPath  = (Resolve-GuiReadyDshExe -Id 'npm')
    }
}

function Install-GuiReadyDsh {
    # 按顺序：{没有 Node.js 就先自动装} → npm install -g pnpm → npm install -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui
    # 输出全部原样进日志（包括 npm 的报错）—— 包名对不对，以 npm 的回答为准。
    param([switch]$SkipPnpm, [switch]$WhatIf)

    $npm = Resolve-GuiReadyDshExe -Id 'npm'
    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        if (-not (Resolve-GuiReadyDshExe -Id 'node')) {
            Write-Log '本机没有 Node.js —— 真跑时会**先自动装包管理器并 choco install nodejs**，再往下走。' 'DRY'
        }
        if (-not $SkipPnpm) { Write-Log '将执行: npm install -g pnpm' 'DRY' }
        Write-Log '将执行: npm install -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui' 'DRY'
        Write-Log '将复核 node / pnpm / dsh / dsh-tui 是否可用（刚装完当前进程 PATH 可能还没刷新，会走回退路径）' 'DRY'
        Write-Log '不会碰 DEEPSEEK_API_KEY：密钥由你自己 setx 设置。' 'DRY'
        return $true
    }

    # Server Core 上什么都没有：Node.js 由工具自己装（先确保有包管理器）
    if (-not $npm) {
        Write-Log '本机没有 Node.js —— dsh-TUI 依赖它，先自动装上。' 'STEP'
        if (-not (Ensure-GuiReadyPackageManager)) { return $false }
        [void](Install-GuiReadyPackage -Source 'choco' -Package 'nodejs')
        $npm = Resolve-GuiReadyDshExe -Id 'npm'
        if (-not $npm) {
            Write-Log '装完 Node.js 但仍解析不到 npm —— 请重开本工具再试（新装的 PATH 需要新进程）。' 'ERROR'
            return $false
        }
        Write-Log 'Node.js 已就绪，继续安装 dsh-TUI 依赖。' 'OK'
    }

    # 把 node / npm / npm 全局 bin 补进 PATH（理由见 Add-GuiReadyDshPath 的注释）
    $added = Add-GuiReadyDshPath
    if (@($added).Count -gt 0) { Write-Log ('已临时加入本次安装的 PATH: ' + (@($added) -join '; ')) 'INFO' }

    if (-not $SkipPnpm) {
        Write-Log '安装 pnpm: npm install -g pnpm' 'STEP'
        try {
            & $npm install -g pnpm 2>&1 | ForEach-Object { Write-Log ([string]$_) 'INFO' }
            if ($LASTEXITCODE -ne 0) { Write-Log ('pnpm 安装返回退出码 {0}（继续装 dsh）。' -f $LASTEXITCODE) 'WARN' }
        } catch { Write-Log ('pnpm 安装异常: ' + $_.Exception.Message) 'WARN' }
    }

    Write-Log '安装 DSH CLI 与 dsh-TUI: npm install -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui' 'STEP'
    $npmOut = New-Object System.Collections.ArrayList
    try {
        & $npm install -g '@deepseek-ai/dsh' '@deepseek-harness-tui/dsh-tui' 2>&1 | ForEach-Object {
            $l = [string]$_
            [void]$npmOut.Add($l)
            Write-Log $l 'INFO'
        }
        $code = $LASTEXITCODE
    } catch {
        Write-Log ('安装异常: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
    $npmText = ($npmOut -join "`n")

    # npm 11 起默认拦下依赖的 install/postinstall 脚本（这是它的安全默认值）。
    # 结果：包装上了、命令也在，但 koffi / node-pty 这类原生模块没编译 —— 可能"能启动、跑起来报错"。
    # 工具不替用户放开脚本执行（那是安全决定），但必须把后果和确切的补救命令讲清楚。
    if ($npmText -match 'allowScripts|not yet covered by allowScripts') {
        Write-Log '注意：本次安装有依赖的构建脚本被 npm 拦下了（npm 11+ 的默认安全行为）。' 'WARN'
        Write-Log '     受影响的是 koffi / node-pty 这类原生模块，dsh-TUI 启动后可能报模块缺失。' 'WARN'
        Write-Log '     要放开的话（请自行判断是否接受这些包执行脚本）：' 'WARN'
        Write-Log '       npm config set allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs --location=user' 'WARN'
        Write-Log '     然后重跑一次本动作。' 'WARN'
    }

    # 复核：以「命令能不能解析到」为准，而不是只看退出码
    $st = Get-GuiReadyDshStatus
    foreach ($i in @($st.Items | Where-Object { $_.Id -in @('pnpm', 'dsh', 'dsh-tui') })) {
        $mark = $(if ($i.Ok) { 'OK' } else { 'WARN' })
        Write-Log ('{0,-10} {1}  {2}' -f $i.Name, $(if ($i.Ok) { '可用 ' + $i.Version } else { '仍不可用' }), $i.Detail) $mark
    }

    if ($code -ne 0) {
        Write-Log ('npm 返回退出码 {0} —— 具体原因看上面 npm 的输出。' -f $code) 'ERROR'
        Write-Log '  404 / Not found        = 该包名在 npm 上不存在，以官方仓库为准，别照抄文档里的包名。' 'WARN'
        Write-Log '  EPERM / EBUSY          = 有文件被占用（常见于工具正在运行时重装），关掉相关程序重试。' 'WARN'
        Write-Log "  'node' is not recognized = 依赖的构建脚本找不到 node（本模块已自动把 node 目录加进 PATH，若仍报这条请重开工具）。" 'WARN'
        return $false
    }
    if (-not (Resolve-GuiReadyDshExe -Id 'dsh-tui')) {
        Write-Log 'npm 装完了但没找到 dsh-tui 命令，请重开工具再看。' 'WARN'
        return $false
    }
    Write-Log 'dsh-TUI 已就绪。启动前记得设好 DEEPSEEK_API_KEY。' 'OK'
    return $true
}

function Start-GuiReadyDsh {
    # dsh-TUI 是交互式 TUI，必须有真正的控制台窗口 —— 这里起一个 cmd 窗口跑它
    # （Server Core 上 conhost 是可用的；要好看的字体/配色用「美化终端」那套）。
    param([switch]$Resume, [switch]$WhatIf)

    $tui = Resolve-GuiReadyDshExe -Id 'dsh-tui'
    $arg = $(if ($Resume) { '--resume' } else { '' })

    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        Write-Log ('将执行: dsh-tui {0}' -f $arg) 'DRY'
        if (-not $tui) { Write-Log '注意：本机还没装 dsh-tui。' 'WARN' }
        return $true
    }
    if (-not $tui) {
        Write-Log '没有 dsh-tui 命令，先在上面点「一键安装依赖」。' 'ERROR'
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)) {
        Write-Log '没有检测到 DEEPSEEK_API_KEY —— dsh-TUI 起来后会用不了。先 setx DEEPSEEK_API_KEY "sk-..." 再重开。' 'WARN'
    }

    Write-Log ('启动: ' + $tui + ' ' + $arg) 'STEP'
    try {
        # 启动的子进程继承本进程的 PATH；dsh-tui 会自己去找 dsh CLI，
    # 找不到就报「未检测到 dsh CLI」退出（实测踩到），所以先把相关目录补进 PATH。
        $added = Add-GuiReadyDshPath
        if (@($added).Count -gt 0) { Write-Log ('已把这些目录临时加入启动用的 PATH: ' + (@($added) -join '; ')) 'INFO' }
        # cmd /k 让窗口等程序退出后仍然留着，方便看最后的报错。
        # 注意：Start-Process 不接受 ArgumentList 里有空字符串 —— 不 resume 时 $arg 是 ''，
        # 直接塞进去会报 "The argument is null or empty"（实测踩到，默认启动必挂）。
        $cmdArgs = @('/k', ('"' + $tui + '"'))
        if ($arg) { $cmdArgs += $arg }
        Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs | Out-Null
        Write-Log '已在新窗口里启动 dsh-TUI。' 'OK'
        return $true
    } catch {
        Write-Log ('启动失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Show-GuiReadyDshStatus {
    # 「更多」页里的只读动作：把依赖状态 + npm 实查结果打出来
    Write-Head 'DeepSeek Harness（dsh-TUI）依赖检查'
    $st = Get-GuiReadyDshStatus -DeepProbe
    foreach ($i in $st.Items) {
        $mark = $(if ($i.Ok) { 'OK' } else { 'WARN' })
        Write-Log ('{0,-42} {1}' -f $i.Name, $(if ($i.Installed) { '已就绪 ' + $i.Version } else { '缺失' })) $mark
        if ($i.Detail) { Write-Log ('    ' + $i.Detail) 'INFO' }
        if ($i.Advice) { Write-Log ('    ' + $i.Advice) 'INFO' }
    }
    Write-Log ('就绪: ' + (Format-Bool $st.Ready)) $(if ($st.Ready) { 'OK' } else { 'WARN' })

    Write-Head 'npm 上的包（实测）'
    if (@($st.Npm).Count -eq 0) {
        Write-Log '没有 npm，跳过实查。' 'WARN'
    } else {
        foreach ($p in $st.Npm) {
            if ($p.Exists) { Write-Log ('{0} → 最新版本 {1}' -f $p.Package, $p.Version) 'OK' }
            else { Write-Log ('{0} → 查不到（{1}）' -f $p.Package, $p.Error) 'ERROR' }
        }
        if (@($st.Npm | Where-Object { -not $_.Exists }).Count -gt 0) {
            Write-Log '查不到的包名不要照抄 —— 以官方仓库/README 为准。' 'WARN'
        }
    }
}

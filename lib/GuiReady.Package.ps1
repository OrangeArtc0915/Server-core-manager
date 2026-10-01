# GuiReady 应用商店：包管理器（源）的检测、搜索、安装、卸载。
#
# 规范见 想法.md（应用商店 2.0，P0）。本轮的取舍：
#   - 只封装「有把握的机器可读输出 / 稳定命令」。拼不准的地方宁可标成「未接入」，
#     不拿猜出来的命令去动用户的机器 —— 这与项目里"实测证据优先"的原则一致。
#   - 主线是 Chocolatey（想法.md 里的 Server Core 首选，`choco search --limit-output`
#     输出稳定的 名称|版本 格式）。Scoop 只做安装/卸载（搜索输出格式随版本变化）。
#   - 所有会改系统的函数都支持 -WhatIf（GUI 的「仅预览」）。
#
# 调用方：gui\Run-GuiReadyStore.ps1（检测 / 搜索）、Run-GuiReadyAction.ps1（安装 / 卸载）。
# 依赖 lib\GuiReady.Common.ps1 的 Write-Log / Write-Head / Test-IsAdministrator / Format-Bool。

function Resolve-GuiReadyPackageExe {
    # 找包管理器的可执行文件：先看 PATH，再回退到已知安装位置。
    #
    # 为什么必须有回退（实测踩到）：装完 Chocolatey 后，已经运行的进程里 PATH 还是旧的
    # （Windows 不会给已启动的进程刷新环境变量），于是工具会一直显示「未安装」、
    # 搜索按钮也点不动，用户只能重启工具 —— 这里靠回退路径把这段救回来。
    param([string]$Id)

    $cmd = $null
    try { $cmd = Get-Command $Id -ErrorAction SilentlyContinue } catch { }
    if ($cmd) { try { return [string]$cmd.Source } catch { } }

    $cands = @()
    switch ($Id) {
        'choco' {
            if ($env:ProgramData) { $cands += (Join-Path $env:ProgramData 'chocolatey\bin\choco.exe') }
            $cands += 'C:\ProgramData\chocolatey\bin\choco.exe'
        }
        'scoop' {
            if ($env:SCOOP) { $cands += (Join-Path $env:SCOOP 'shims\scoop.cmd') }
            if ($env:USERPROFILE) { $cands += (Join-Path $env:USERPROFILE 'scoop\shims\scoop.cmd') }
            $cands += 'C:\ProgramData\scoop\shims\scoop.cmd'
        }
    }
    foreach ($c in $cands) {
        try { if ($c -and (Test-Path -LiteralPath $c)) { return [string]$c } } catch { }
    }
    return ''
}

function Get-GuiReadyPackageSource {
    # 只读检测：本机有哪些包管理器、版本多少、我们支持到哪一步。
    # 版本号是真把命令跑一遍（choco ~0.3s，scoop 要起 PowerShell ~1-3s），
    # 所以只在子进程里调用（见 Run-GuiReadyStore.ps1）。
    param([switch]$SkipVersion)

    $defs = @(
        [pscustomobject]@{
            Id = 'choco'; Name = 'Chocolatey'; Exe = 'choco'; Search = $true; Install = $true
            Note = '主线：搜索 / 安装 / 卸载。装它需要管理员与联网'
        }
        [pscustomobject]@{
            Id = 'scoop'; Name = 'Scoop'; Exe = 'scoop'; Search = $false; Install = $true
            Note = '安装 / 卸载 / 列表可用；搜索未接入（输出格式随版本变化）'
        }
        [pscustomobject]@{
            Id = 'npm'; Name = 'npm'; Exe = 'npm'; Search = $false; Install = $false
            Note = '语言生态，本轮只做检测'
        }
        [pscustomobject]@{
            Id = 'pip'; Name = 'pip'; Exe = 'pip'; Search = $false; Install = $false
            Note = '语言生态，本轮只做检测'
        }
    )

    $out = @()
    foreach ($d in $defs) {
        $path = Resolve-GuiReadyPackageExe -Id $d.Id
        $installed = [bool]$path
        $ver  = ''
        if ($installed -and -not $SkipVersion) {
            try {
                $raw = @(& $path --version 2>$null) | Select-Object -First 1
                if ($raw) { $ver = ([string]$raw).Trim() }
            } catch { }
        }
        $out += [pscustomobject]@{
            Id         = $d.Id
            Name       = $d.Name
            Exe        = $d.Exe
            Installed  = $installed
            Version    = $ver
            Path       = $path
            CanSearch  = ($installed -and $d.Search)
            CanInstall = ($installed -and $d.Install)
            Note       = $d.Note
        }
    }
    return $out
}

function ConvertFrom-GuiReadyPipeList {
    # 解析「名称|版本」逐行的机器可读输出，顺手把横幅/警告/空行过滤掉。
    # choco 的 --limit-output 是这个格式；解析不出来就返回空数组，不猜。
    param([string[]]$Lines)

    $out = @()
    foreach ($l in @($Lines)) {
        $t = ([string]$l).Trim()
        if (-not $t) { continue }
        if ($t.IndexOf('|') -lt 0) { continue }
        $parts = $t -split '\|'
        if ($parts.Count -lt 2) { continue }
        $n = $parts[0].Trim()
        if (-not $n) { continue }
        $out += [pscustomobject]@{ Id = $n; Version = $parts[1].Trim(); Source = '' }
    }
    return $out
}

function Search-GuiReadyPackage {
    # 搜索可安装的包。目前只支持 Chocolatey：`choco search <q> --limit-output`
    # 输出每行「名称|版本」，是长期稳定的机器可读格式（不加 --limit-output 会带表格与进度）。
    param(
        [string]$Source = 'choco',
        [string]$Query = '',
        [int]$Limit = 40
    )

    if ([string]::IsNullOrWhiteSpace($Query)) { return @() }
    # 搜索词会被拼进 choco 的命令行，挡掉前导 '-'（会被当成选项）与换行
    if ($Query -match '^-' -or $Query -match '[\r\n]') {
        Write-Log '搜索词不能以 - 开头，也不能含换行。' 'ERROR'
        return @()
    }

    if ($Source -ne 'choco') {
        Write-Log ('源 {0} 的搜索暂未接入（输出格式随版本变化，解析不可靠）。' -f $Source) 'WARN'
        return @()
    }
    $exe = Resolve-GuiReadyPackageExe -Id 'choco'
    if (-not $exe) {
        Write-Log '本机没有 choco 命令，先安装 Chocolatey（商店页有入口）。' 'ERROR'
        return @()
    }

    Write-Log ('搜索: choco search {0} --limit-output' -f $Query) 'STEP'
    $raw = @()
    try { $raw = @(& $exe search $Query --limit-output 2>$null) } catch {
        Write-Log ('搜索失败: ' + $_.Exception.Message) 'ERROR'
        return @()
    }

    $items = @(ConvertFrom-GuiReadyPipeList -Lines $raw)
    foreach ($i in $items) { $i.Source = 'choco' }
    if ($items.Count -eq 0) {
        Write-Log '没有匹配的包，或者源不可达（内网环境常见）。' 'WARN'
        return @()
    }
    Write-Log ('命中 {0} 个包。' -f $items.Count) 'OK'
    if ($items.Count -gt $Limit) { $items = $items[0..($Limit - 1)] }
    return $items
}

function Get-GuiReadyInstalledPackage {
    # 本机已装的包（用来在商店页标「已安装」）。
    param([string]$Source = 'choco')

    if ($Source -ne 'choco') {
        Write-Log ('源 {0} 的本地列表暂未接入。' -f $Source) 'WARN'
        return @()
    }
    $exe = Resolve-GuiReadyPackageExe -Id 'choco'
    if (-not $exe) { return @() }

    # choco 2.x 的 `choco list` 默认就是本地已装列表，1.x 需要 --local-only。两种都试一遍。
    $tries = @(
        @('list', '--limit-output'),
        @('list', '--local-only', '--limit-output')
    )
    foreach ($argv in $tries) {
        $raw = @()
        try { $raw = @(& $exe @argv 2>$null) } catch { $raw = @() }
        $items = @(ConvertFrom-GuiReadyPipeList -Lines $raw)
        if ($items.Count -gt 0) {
            foreach ($i in $items) { $i.Source = 'choco' }
            return $items
        }
    }
    return @()
}

function Invoke-GuiReadyPackageCommand {
    # 统一「跑一条包管理器命令并把输出实时转成日志」的地方，安装/卸载共用。
    # 输出走 Write-Log 是为了让它出现在 GUI 的日志面板里（子进程 stdout）。
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string[]]$Argv
    )

    Write-Log ('执行: {0} {1}' -f $DisplayName, ($Argv -join ' ')) 'STEP'
    $code = -1
    try {
        & $Exe @Argv 2>&1 | ForEach-Object { Write-Log ([string]$_) 'INFO' }
        $code = $LASTEXITCODE
    } catch {
        Write-Log ('命令执行异常: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
    if ($code -eq 0) {
        Write-Log '命令成功（退出码 0）。' 'OK'
        return $true
    }
    Write-Log ('命令返回退出码 {0}。' -f $code) 'ERROR'
    return $false
}

function Ensure-GuiReadyPackageManager {
    # 「包管理器由工具自己装」——目标场景是刚装好的 Server Core，机上什么都没有。
    #
    # 只要调用方要装东西，就先过这里：有 choco 直接用；没有就自动装（默认 Chocolatey，
    # 因为它是 Server Core 上唯一官方支持、又不需要 MSIX/WinGet 的源）。
    # 装完会**复核**一次（路径解析带已知位置回退，见 Resolve-GuiReadyPackageExe）。
    param(
        [string]$Id = 'choco',
        [string]$Url = '',
        [switch]$AllowInsecure,
        [switch]$WhatIf
    )

    if (Resolve-GuiReadyPackageExe -Id $Id) { return $true }

    if ($Id -ne 'choco') {
        Write-Log ('本机没有 {0}，且本工具只自动部署 Chocolatey（其它源请手动装）。' -f $Id) 'ERROR'
        return $false
    }

    if ($WhatIf) {
        Write-Log '本机还没有包管理器 —— 下面是"真跑时会先做的事"：' 'DRY'
        [void](Install-GuiReadyPackageManager -Id 'choco' -Url $Url -AllowInsecure:$AllowInsecure -WhatIf)
        return $false
    }

    Write-Log '本机没有包管理器，先自动安装 Chocolatey（Server Core 首选源，装完再继续）。' 'STEP'
    if (-not (Install-GuiReadyPackageManager -Id 'choco' -Url $Url -AllowInsecure:$AllowInsecure)) {
        Write-Log 'Chocolatey 自动安装失败，后续步骤没法继续。' 'ERROR'
        return $false
    }
    if (-not (Resolve-GuiReadyPackageExe -Id 'choco')) {
        Write-Log 'Chocolatey 装完了但命令还解析不到 —— 请重开本工具再试一次。' 'WARN'
        return $false
    }
    Write-Log 'Chocolatey 已就绪，继续原来的操作。' 'OK'
    return $true
}

function Install-GuiReadyPackage {
    param(
        [string]$Source = 'choco',
        [string]$Package = '',
        [switch]$WhatIf
    )

    if ([string]::IsNullOrWhiteSpace($Package)) {
        Write-Log '包名为空。' 'ERROR'
        return $false
    }
    if (-not (Test-GuiReadyPackageId -Id $Package)) {
        Write-Log ('包名含非法字符: {0}（只允许字母数字与 . _ + -）' -f $Package) 'ERROR'
        return $false
    }

    $argv = @()
    switch ($Source) {
        'choco' { $argv = @('install', $Package, '-y', '--no-progress') }
        'scoop' { $argv = @('install', $Package) }
        default { Write-Log ('源 {0} 暂不支持安装。' -f $Source) 'ERROR'; return $false }
    }

    $exe = Resolve-GuiReadyPackageExe -Id $Source
    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        if (-not $exe) {
            Write-Log ('本机没有 {0} —— 真跑时会**先自动装包管理器**，再执行下面这条：' -f $Source) 'DRY'
            # 注意：不要写成 [void](...) | Out-Null —— 管道接到 [void] 会报
            # "Argument type cannot be System.Void"（实测踩到）
            [void](Ensure-GuiReadyPackageManager -Id $Source -WhatIf)
        }
        Write-Log ('将执行: {0} {1}' -f $Source, ($Argv -join ' ')) 'DRY'
        if ($Source -eq 'choco') { Write-Log 'Chocolatey 安装写 C:\ProgramData\chocolatey，需要管理员权限。' 'DRY' }
        return $true
    }

    # 没有包管理器就先装上 —— 用户不需要自己去折腾（Server Core 上本来什么都没有）
    if (-not $exe) {
        [void](Ensure-GuiReadyPackageManager -Id $Source)
        $exe = Resolve-GuiReadyPackageExe -Id $Source
        if (-not $exe) { return $false }
    }
    # scoop 是用户级安装，不需要管理员；choco 需要
    if ($Source -eq 'choco' -and -not (Test-IsAdministrator)) {
        Write-Log 'Chocolatey 安装包需要管理员权限。' 'ERROR'
        return $false
    }
    return (Invoke-GuiReadyPackageCommand -Exe $exe -DisplayName $Source -Argv $argv)
}

function Uninstall-GuiReadyPackage {
    param(
        [string]$Source = 'choco',
        [string]$Package = '',
        [switch]$WhatIf
    )

    if ([string]::IsNullOrWhiteSpace($Package)) {
        Write-Log '包名为空。' 'ERROR'
        return $false
    }
    if (-not (Test-GuiReadyPackageId -Id $Package)) {
        Write-Log ('包名含非法字符: {0}（只允许字母数字与 . _ + -）' -f $Package) 'ERROR'
        return $false
    }

    $argv = @()
    switch ($Source) {
        'choco' { $argv = @('uninstall', $Package, '-y', '--no-progress') }
        'scoop' { $argv = @('uninstall', $Package) }
        default { Write-Log ('源 {0} 暂不支持卸载。' -f $Source) 'ERROR'; return $false }
    }

    $exe = Resolve-GuiReadyPackageExe -Id $Source
    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        Write-Log ('将执行: {0} {1}' -f $Source, ($Argv -join ' ')) 'DRY'
        if (-not $exe) { Write-Log ('注意：本机现在没有 {0} 命令。' -f $Source) 'WARN' }
        return $true
    }

    if (-not $exe) {
        Write-Log ('本机没有 {0} 命令。' -f $Source) 'ERROR'
        return $false
    }
    if ($Source -eq 'choco' -and -not (Test-IsAdministrator)) {
        Write-Log 'Chocolatey 卸载包需要管理员权限。' 'ERROR'
        return $false
    }
    return (Invoke-GuiReadyPackageCommand -Exe $exe -DisplayName $Source -Argv $argv)
}

function Install-GuiReadyPackageManager {
    # 装包管理器本体。目前只做 Chocolatey：走官方安装脚本，
    # 但先下载到临时文件再执行（不用 iex），这样出问题时有文件可查；
    # 内网环境可以用 -Url 指向自己的脚本副本。
    #
    # 安全约束（这个函数会以管理员身份执行**远程内容**，是本工具最敏感的一处）：
    #   1. 默认必须是 https —— 明文 http 下载再执行等于把管理员权限挂在网络上；
    #      内网确实只有 http 时才用 -AllowInsecure 显式放开，并且会打警告。
    #   2. 下载完先看内容像不像 PowerShell 脚本（大小 + 关键字），不像就拒绝执行，
    #      避免把「404 的 HTML 页面」当脚本跑。
    #   3. 把实际生效的地址（含重定向后的）打进日志，出问题能追。
    param(
        [string]$Id = 'choco',
        [string]$Url = '',
        [switch]$AllowInsecure,
        [switch]$WhatIf
    )

    if ($Id -ne 'choco') {
        Write-Log ('暂不支持自动安装 {0}，请按官方文档安装。' -f $Id) 'ERROR'
        return $false
    }
    if (Resolve-GuiReadyPackageExe -Id 'choco') {
        Write-Log 'Chocolatey 已经装好了。' 'OK'
        return $true
    }
    if (-not $Url) { $Url = 'https://community.chocolatey.org/install.ps1' }

    $insecure = ($Url -notmatch '^https://')
    if ($insecure -and -not $AllowInsecure) {
        Write-Log ('拒绝执行非 https 的安装脚本地址: {0}' -f $Url) 'ERROR'
        Write-Log '  这条链会以管理员身份执行下载到的内容，明文 http 等于把权限交给网络中间人。' 'ERROR'
        Write-Log '  内网确实只有 http 时，加 -AllowInsecure 显式放开（会打警告）。' 'INFO'
        return $false
    }

    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        Write-Log ('将下载安装脚本: ' + $Url) 'DRY'
        if ($insecure) { Write-Log '注意：该地址不是 https（已用 -AllowInsecure 放开）。' 'WARN' }
        Write-Log '将用 PowerShell 执行它（等价于官方的一行安装），装到 C:\ProgramData\chocolatey' 'DRY'
        Write-Log '下载后会先检查内容像不像 PowerShell 脚本，不像就拒绝执行' 'DRY'
        Write-Log '需要管理员权限与联网；内网环境请用 -Url 指向内网副本' 'DRY'
        return $true
    }

    if (-not (Test-IsAdministrator)) {
        Write-Log '安装 Chocolatey 需要管理员权限（工具本身以管理员运行时没问题）。' 'ERROR'
        return $false
    }

    $tmp = Join-Path $env:TEMP ('choco-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.ps1')
    Write-Log ('下载安装脚本: ' + $Url) 'STEP'
    if ($insecure) { Write-Log '该地址不是 https（已用 -AllowInsecure 放开）—— 内容不可信，请自行确认来源。' 'WARN' }
    $finalUrl = ''
    try {
        $resp = Invoke-WebRequest -Uri $Url -OutFile $tmp -TimeoutSec 300 -UseBasicParsing -PassThru -ErrorAction Stop
        try { $finalUrl = [string]$resp.BaseResponse.ResponseUri.AbsoluteUri } catch { }
    } catch {
        Write-Log ('下载失败: ' + $_.Exception.Message) 'ERROR'
        Write-Log '国内网络下可以改用内网/自建副本：动作参数里填 Url。' 'WARN'
        return $false
    }
    if ($finalUrl -and $finalUrl -ne $Url) { Write-Log ('实际下载地址（含重定向）: ' + $finalUrl) 'INFO' }

    # 内容体检：大小 + 像不像 PowerShell。避免把 404 页面 / 一段 JSON 当脚本执行。
    $head = ''
    $len = 0
    try {
        $len = (Get-Item -LiteralPath $tmp).Length
        if ($len -gt 0) { $head = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8) }
    } catch { }
    if ($len -lt 200) {
        Write-Log ('下载到的内容只有 {0} 字节，不像安装脚本，已拒绝执行。' -f $len) 'ERROR'
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
        return $false
    }
    if ($head -notmatch '(?m)^\s*(#|param|function|\$|\<#)' ) {
        Write-Log '下载到的内容不像 PowerShell 脚本（开头没有注释/param/变量），已拒绝执行。' 'ERROR'
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
        return $false
    }

    Write-Log '执行安装脚本…' 'STEP'
    $ok = $false
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
        $ok = ($LASTEXITCODE -eq 0)
    } catch {
        Write-Log ('安装脚本执行异常: ' + $_.Exception.Message) 'ERROR'
    }
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }

    # 装完复核一次：脚本成功但当前进程 PATH 还没刷新是很常见的情况（实测就是）
    $onPath = $false
    try { $onPath = [bool](Get-Command choco -ErrorAction SilentlyContinue) } catch { }
    if ($onPath) {
        Write-Log 'Chocolatey 安装完成，可以直接搜包了。' 'OK'
        return $true
    }
    $exe = Resolve-GuiReadyPackageExe -Id 'choco'
    if ($exe) {
        Write-Log ('已装到 {0}，但当前进程的 PATH 还没刷新 —— 工具会自动用这个路径，不用重开。' -f $exe) 'WARN'
        return $true
    }
    Write-Log '安装脚本跑完了，但没检测到 choco。请重开一个终端再试。' 'WARN'
    return $ok
}

function Test-GuiReadyPackageId {
    # 包名合法性检查。为什么要卡这一道：
    #   1. 包名来自**远程 feed**（choco search 的返回），会被拼进命令行、日志、JSON；
    #   2. Windows 下 Start-Process 的 ArgumentList 不会自动加引号，要靠手工拼引号 ——
    #      名字里带一个 '"' 就能把额外参数注入到我们启动的进程命令行里（实测确认这个形状）；
    #   3. 社区仓库本身也只允许 [A-Za-z0-9._+-]，所以拒绝这些字符不会误伤正常包名。
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    return [bool]($Id -match '^[A-Za-z0-9][A-Za-z0-9\._\+\-]{0,63}$')
}

function Get-GuiReadyPackageInfo {
    # 解析 `choco info <包>` 的输出（工具详情页的数据源）。
    #
    # 实测格式（Chocolatey 2.7.4 原始输出）：
    #   Chocolatey v2.7.4                       <- 横幅，跳过
    #   7zip 26.3.0 [Approved]                  <- 包名 版本 [状态]
    #    Title: 7-Zip | Published: 2026/9/4     <- 缩进一格的 Key: value
    #    Package url https://...                 <- 注意这行没有冒号
    #    Summary: ...
    #    Description: ...                        <- 后面多行是描述正文（缩进更深）
    #
    # 所以：按「缩进 + 已知键名」切块，不假定键的顺序与存在性；
    # 认不出的行只要处在描述块里就并入描述 —— 宁可多留，也别把内容丢掉。
    param([string]$Source = 'choco', [string]$Package = '')

    $out = [ordered]@{
        Id = $Package; Version = ''; Title = ''; Published = ''; Summary = ''
        Description = ''; Tags = ''; Site = ''; License = ''; Url = ''; Downloads = ''
        Source = $Source; Error = ''
    }
    if ([string]::IsNullOrWhiteSpace($Package)) { $out.Error = '包名为空'; return [pscustomobject]$out }
    if (-not (Test-GuiReadyPackageId -Id $Package)) { $out.Error = '包名含非法字符（只允许字母数字与 . _ + -）'; return [pscustomobject]$out }
    if ($Source -ne 'choco') { $out.Error = '目前只有 Chocolatey 支持详情查询'; return [pscustomobject]$out }

    $exe = Resolve-GuiReadyPackageExe -Id 'choco'
    if (-not $exe) { $out.Error = '本机没有 choco，先在商店页装 Chocolatey'; return [pscustomobject]$out }

    $raw = @()
    try { $raw = @(& $exe info $Package --no-color 2>&1) } catch {
        $out.Error = $_.Exception.Message; return [pscustomobject]$out
    }
    if ($raw.Count -eq 0) { $out.Error = 'choco info 没有输出'; return [pscustomobject]$out }

    $known = @('Title', 'Published', 'Summary', 'Description', 'Tags', 'Software Site', 'Software License',
               'Package url', 'Number of Downloads', 'Author', 'Owners', 'Release Notes', 'Package Checksum',
               'Chocolatey Package Source', 'Documentation', 'Mailing List', 'Issues')

    # 先收成「原始键 → 值」，最后再映射到字段。
    # 为什么绕这一道：实测 choco 会**把多个键塞进同一行**，用 ' | ' 分隔：
    #   " Title: 7-Zip | Published: 2026/9/4"
    #   " Number of Downloads: 35538182 | Downloads for this version: 84"
    # 所以按 ' | ' 切开，能认出是已知键的就当新键，否则拼回上一个值
    #（真实值里也可能含 ' | '，这样不会误切）。
    $map = [ordered]@{}
    $desc = New-Object System.Collections.ArrayList
    $inDesc = $false
    $headerDone = $false
    $curKey = ''

    foreach ($line in $raw) {
        $t = ([string]$line).TrimEnd()
        if (-not $t.Trim()) { if ($inDesc) { [void]$desc.Add('') }; continue }
        if ($t -match '^Chocolatey v') { continue }

        # 包头：非缩进行 = 名称 版本 [状态]
        if (-not $headerDone -and $t -notmatch '^\s') {
            $headerDone = $true
            $mh = [regex]::Match($t, '^(\S+)\s+([0-9][^\s\[]*)\s*(.*)$')
            if ($mh.Success) { $out.Id = $mh.Groups[1].Value; $out.Version = $mh.Groups[2].Value }
            continue
        }

        # 没有冒号的特例：Package url https://...
        $mu = [regex]::Match($t, '^\s+Package url\s+(https?://\S+)\s*$')
        if ($mu.Success) { $map['Package url'] = $mu.Groups[1].Value; $curKey = 'Package url'; $inDesc = $false; continue }

        if ($t -match '^\s+[A-Za-z]') {
            $idx = 0
            foreach ($seg in @((($t.Trim()) -split ' \| '))) {
                $idx++
                $s2 = $seg.Trim()
                if (-not $s2) { continue }
                $mk = [regex]::Match($s2, '^([A-Za-z][A-Za-z0-9 ./_\-]{1,40}?)\s*:\s*(.*)$')
                $k = ''
                if ($mk.Success) {
                    $cand = $mk.Groups[1].Value.Trim()
                    if ($known -contains $cand) { $k = $cand }
                }
                if ($k) {
                    $v = $mk.Groups[2].Value.Trim()
                    if ($k -eq 'Description') {
                        $inDesc = $true
                        if ($v) { [void]$desc.Add($v) }
                    } else {
                        $inDesc = $false
                        $map[$k] = $v
                    }
                    $curKey = $k
                    continue
                }
                # 认不出是键：
                #  - 同一条物理行里排在键后面的片段，可能是值的一部分（Title 里本来就可能含 " | "）→ 拼回去
                #  - 行首就不是键的行（例如 " Package approved as a trusted package on ..."）是元信息噪音 → 丢掉
                if ($idx -gt 1) {
                    if ($inDesc) { [void]$desc.Add($s2) }
                    elseif ($curKey -and $curKey -ne 'Description') { $map[$curKey] = ([string]$map[$curKey] + ' | ' + $s2) }
                } elseif ($inDesc) {
                    [void]$desc.Add($s2)
                }
            }
            continue
        }

        if ($inDesc) { [void]$desc.Add($t.Trim()) }
    }

    if ($map.Contains('Title'))     { $out.Title = [string]$map['Title'] }
    if ($map.Contains('Published')) { $out.Published = [string]$map['Published'] }
    if ($map.Contains('Summary'))   { $out.Summary = [string]$map['Summary'] }
    if ($map.Contains('Tags'))      { $out.Tags = [string]$map['Tags'] }
    if ($map.Contains('Software Site')) { $out.Site = [string]$map['Software Site'] }
    if ($map.Contains('Software License')) { $out.License = [string]$map['Software License'] }
    if ($map.Contains('Package url')) { $out.Url = [string]$map['Package url'] }
    if ($map.Contains('Number of Downloads')) { $out.Downloads = [string]$map['Number of Downloads'] }
    $out.Description = ((@($desc) -join "`n").Trim())

    # 什么都没解出来 = 这个包大概率不存在（choco 会把 "not found" 之类的提示打给 stderr，
    # 上面已被 2>&1 收进来但没有可解析的键）。明确报出来，别让详情页显示一堆空格子。
    if (-not $out.Title -and -not $out.Summary -and -not $out.Description) {
        $out.Error = ('没找到包 {0}（choco info 没返回可解析内容）。确认包名拼写，或换个源试试。' -f $Package)
    }
    return [pscustomobject]$out
}

function Show-GuiReadyPackageInfo {
    # 「更多」页里的只读动作：把详情打成文本（页面用不到这个，它是给人看的）
    param([string]$Package = '')

    Write-Head ('软件包详情: ' + $Package)
    $i = Get-GuiReadyPackageInfo -Package $Package
    if ($i.Error) { Write-Log $i.Error 'ERROR'; return }

    Write-Log ('{0}  {1}' -f $i.Title, $i.Version) 'OK'
    if ($i.Published) { Write-Log ('发布时间: ' + $i.Published) 'INFO' }
    if ($i.Downloads) { Write-Log ('下载量: ' + $i.Downloads) 'INFO' }
    if ($i.Summary)   { Write-Log ('摘要: ' + $i.Summary) 'INFO' }
    if ($i.Tags)      { Write-Log ('标签: ' + $i.Tags) 'INFO' }
    if ($i.Site)      { Write-Log ('官网: ' + $i.Site) 'INFO' }
    if ($i.License)   { Write-Log ('许可证: ' + $i.License) 'INFO' }
    if ($i.Url)       { Write-Log ('包页面: ' + $i.Url) 'INFO' }

    if ($i.Description) {
        Write-Log '描述:' 'HEAD'
        $n = 0
        foreach ($l in ($i.Description -split "`n")) {
            if ($n -ge 40) { Write-Log ('  …（还有更多，共 {0} 行；GUI 里看完整描述）' -f ($i.Description -split "`n").Count) 'INFO'; break }
            Write-Log ('  ' + $l) 'INFO'
            $n++
        }
    }
}

function Show-GuiReadyPackageSourceStatus {
    # 「更多」页里的只读动作：把各源的状态打出来
    Write-Head '应用商店：包管理器状态'
    $src = @(Get-GuiReadyPackageSource)
    foreach ($s in $src) {
        $state = $(if ($s.Installed) { '已安装 ' + $s.Version } else { '未安装' })
        Write-Log ('{0,-12} {1}' -f $s.Name, $state) $(if ($s.Installed) { 'OK' } else { 'INFO' })
        if ($s.Installed -and $s.Path) { Write-Log ('             ' + $s.Path) 'INFO' }
        Write-Log ('             搜索={0}  安装/卸载={1}  {2}' -f (Format-Bool $s.CanSearch), (Format-Bool $s.CanInstall), $s.Note) 'INFO'
    }
    $searchable = @($src | Where-Object { $_.CanSearch })
    if ($searchable.Count -eq 0) {
        Write-Log '当前没有可用于搜索的源：先在「商店」页点「安装 Chocolatey」。' 'WARN'
    } else {
        Write-Log ('可用于搜索的源: ' + (($searchable | ForEach-Object { $_.Name }) -join '、')) 'OK'
    }
}

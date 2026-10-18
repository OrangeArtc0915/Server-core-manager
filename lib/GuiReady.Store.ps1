# GuiReady 应用商店：本地索引 + 搜索（后端）
#
# 数据源：store\catalog.json（手工精选）。定位见设计文档：应用商店不是"软件下载站"，
# 而是 Server Core 环境下 GUI 程序的兼容性安装器。
#
# 为什么先只做后端、不碰界面：
#   1. 纯函数，没有副作用，可以单独验证 —— 界面那层等索引对了再接；
#   2. 索引与排序规则是这个功能的"判断逻辑"，界面只是展示。先把判断做对。
#
# 实测前提（Server Core 2025 / 26100）：winget 不存在，choco / npm 可用 ——
# 所以 catalog 里的 install.type 以 choco 为主，界面文案不要写 winget。

$Global:GuiReadyStoreVersion = 1

function Get-GuiReadyStoreCatalogPath {
    # 按【本模块文件自己所在的位置】定位数据，不依赖调用方作用域的变量。
    #
    # 踩过的坑：上一版写的是 Join-Path $script:GuiReadyRoot 'store\catalog.json'。
    # 本模块被 dot-source 进 GUI 的脚本作用域后，那里定义的是 $toolRoot，
    # 并没有 $GuiReadyRoot —— 于是路径解析成相对路径、文件不存在、索引静默为空，
    # 表现就是"商店页一行精选都没铺出来"，而且不报错、查不出来。
    # 用 $PSScriptRoot（模块文件所在目录）就与调用方无关了。
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if ($here) {
        $p = Join-Path (Split-Path -Parent $here) 'store\catalog.json'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    # 兜底：控制台侧 / 单测里可能设了 $script:GuiReadyRoot
    if ($script:GuiReadyRoot) { return (Join-Path $script:GuiReadyRoot 'store\catalog.json') }
    return (Join-Path $here 'store\catalog.json')
}

function Get-GuiReadyCompatRank {
    # 排序用：数字越小越靠前。verified 优先，unsupported 垫底（对齐设计文档第五节）。
    param([string]$Compat)
    switch ([string]$Compat) {
        'verified'    { return 0 }
        'partial'     { return 1 }
        'unverified'  { return 2 }
        'unsupported' { return 3 }
        default       { return 4 }
    }
}

function Import-GuiReadyStoreCatalog {
    # 读一次就缓存到内存；-Reload 强制重读。
    # 缓存的是原始对象数组 + 一张 id -> entry 的哈希表，查询 O(1)。
    param([switch]$Reload)

    if (-not $Reload -and $script:StoreCatalog) { return $script:StoreCatalog }

    $o = [pscustomobject]@{
        Ok        = $false
        Path      = (Get-GuiReadyStoreCatalogPath)
        Apps      = @()
        ById      = @{}
        Categories = @()
        Error     = ''
    }

    try {
        $path = Get-GuiReadyStoreCatalogPath
        if (-not (Test-Path -LiteralPath $path)) {
            $o.Error = '找不到数据文件: ' + $path
            $script:StoreCatalog = $o
            return $o
        }
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $json = $raw | ConvertFrom-Json

        $apps = @($json.apps)
        $byId = @{}
        foreach ($a in $apps) {
            $id = ([string]$a.id).Trim().ToLower()
            if ($id) { $byId[$id] = $a }
        }

        $o.Apps       = $apps
        $o.ById       = $byId
        $o.Categories = @($json.categories)
        $o.Ok         = $true
    } catch {
        $o.Error = $_.Exception.Message
    }
    $script:StoreCatalog = $o
    return $o
}

function Get-GuiReadyStoreEntry {
    # 按 id 取条目（O(1)）。找不到返回 $null。
    param([Parameter(Mandatory = $true)][string]$Id)
    $c = Import-GuiReadyStoreCatalog
    if (-not $c.Ok) { return $null }
    $k = $Id.Trim().ToLower()
    if ($c.ById.ContainsKey($k)) { return $c.ById[$k] }
    return $null
}

function Get-GuiReadyStoreScore {
    # 相关度打分。刻意做成显式阶梯而不是模糊匹配 —— 用户敲 "vscode" 时，
    # 应该精确命中 vscode，而不是被某个 tags 里带 vscode 的条目抢在前面。
    param($Entry, [string]$Kw)

    if (-not $Kw) { return 1 }
    $id   = ([string]$Entry.id).ToLower()
    $name = ([string]$Entry.name).ToLower()
    $zh   = ([string]$Entry.name_zh).ToLower()
    $tags = @($Entry.tags) | ForEach-Object { ([string]$_).ToLower() }

    if ($id -eq $Kw)                  { return 100 }
    if ($name -eq $Kw -or $zh -eq $Kw) { return 80 }
    if ($id.StartsWith($Kw))          { return 60 }
    if ($name.StartsWith($Kw) -or $zh.StartsWith($Kw)) { return 50 }
    foreach ($t in $tags) { if ($t -eq $Kw) { return 45 } }
    if ($id.Contains($Kw))            { return 30 }
    if ($name.Contains($Kw) -or $zh.Contains($Kw)) { return 25 }
    foreach ($t in $tags) { if ($t.Contains($Kw)) { return 20 } }
    # 最后兜底：分类 id 或 install.id 命中（搜 "choco"、搜 "dev" 也能出东西）
    if (([string]$Entry.category).ToLower().Contains($Kw)) { return 10 }
    if (([string]$Entry.install.id).ToLower().Contains($Kw)) { return 10 }
    return 0
}

function Search-GuiReadyStore {
    # 关键词 + 场景分类 + 界面类型 + 兼容性 多重过滤。
    # Keyword 为空表示"浏览"（按兼容性 + 热度排）。
    # 返回对象数组（已按"相关度 -> 兼容性 -> 热度"排好）。
    param(
        [string]$Keyword = '',
        [string]$Category = '',
        [string]$Compatibility = '',
        # 界面类型：'' 全部 | cli | tui | gui。这是商店页那排筛选按钮传进来的值。
        # 之所以单独开一维、而不是塞进 Category：Category 是"场景"（系统/开发/网络…），
        # Ui 是"跑起来要不要图形环境"，两者是正交的，用户在商店里更常按后者筛。
        [string]$Ui = '',
        [int]$Limit = 200
    )

    $c = Import-GuiReadyStoreCatalog
    if (-not $c.Ok) { return @() }

    $kw = ([string]$Keyword).Trim().ToLower()
    $cat = ([string]$Category).Trim().ToLower()
    $cmp = ([string]$Compatibility).Trim().ToLower()
    $ui = ([string]$Ui).Trim().ToLower()

    $hits = New-Object System.Collections.ArrayList
    foreach ($a in $c.Apps) {
        if ($cat -and ([string]$a.category).ToLower() -ne $cat) { continue }
        if ($cmp -and ([string]$a.compatibility).ToLower() -ne $cmp) { continue }
        if ($ui -and ([string]$a.ui).ToLower() -ne $ui) { continue }
        $s = Get-GuiReadyStoreScore -Entry $a -Kw $kw
        if ($s -le 0) { continue }
        $pop = 0
        try { if ($a.PSObject.Properties['popularity'] -and $a.popularity) { $pop = [int]$a.popularity } } catch { }
        [void]$hits.Add([pscustomobject]@{
            Score = $s
            Rank  = (Get-GuiReadyCompatRank -Compat $a.compatibility)
            Pop   = $pop
            Entry = $a
        })
    }

    $sorted = @($hits | Sort-Object -Property @{Expression='Score';Descending=$true},
                                                @{Expression='Rank';Descending=$false},
                                                @{Expression='Pop';Descending=$true})
    if ($Limit -gt 0 -and $sorted.Count -gt $Limit) { $sorted = $sorted[0..($Limit-1)] }
    return @($sorted | ForEach-Object { $_.Entry })
}

function Resolve-GuiReadyStoreAlternatives {
    # 把 alternatives 里的 id 换成人话（"NewApp（名称）"），给"不兼容 → 推荐替代"用。
    param($Entry)
    $out = New-Object System.Collections.ArrayList
    if (-not $Entry) { return @() }
    foreach ($id in @($Entry.alternatives)) {
        $s = ([string]$id).Trim()
        if (-not $s) { continue }
        $alt = Get-GuiReadyStoreEntry -Id $s
        if ($alt) { [void]$out.Add(('{0}（{1}）' -f [string]$alt.name, $s)) } else { [void]$out.Add($s) }
    }
    return @($out)
}

function Get-GuiReadyStoreStats {
    # 给界面用的统计：总数 / 各兼容性档数量 / 各分类数量 / 各界面类型数量。
    $c = Import-GuiReadyStoreCatalog
    if (-not $c.Ok) { return [pscustomobject]@{ Total = 0; ByCompat = @{}; ByCategory = @{}; ByUi = @{}; Source = $c.Error } }
    $bc = @{}; $bcat = @{}; $bui = @{}
    foreach ($a in $c.Apps) {
        $k = [string]$a.compatibility
        if ($bc.ContainsKey($k)) { $bc[$k]++ } else { $bc[$k] = 1 }
        $k2 = [string]$a.category
        if ($bcat.ContainsKey($k2)) { $bcat[$k2]++ } else { $bcat[$k2] = 1 }
        $k3 = [string]$a.ui
        if ($bui.ContainsKey($k3)) { $bui[$k3]++ } else { $bui[$k3] = 1 }
    }
    return [pscustomobject]@{ Total = @($c.Apps).Count; ByCompat = $bc; ByCategory = $bcat; ByUi = $bui; Source = '' }
}

function Install-GuiReadyStoreApp {
    # 按精选库条目做「完整安装」：兼容性 → FOD → 功能依赖 → 主安装 → 验证。
    #
    # 与裸 pkg-install 的区别：这里读 catalog 的 fod_required / runtime_deps / launch，
    # 把「装完为什么用不了」的常见坑提前处理掉（例如 Docker Engine 需要 Containers 功能）。
    # 不在精选库里的包名会回退成裸 choco 安装。
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [switch]$WhatIf
    )

    $e = Get-GuiReadyStoreEntry -Id $Id
    if (-not $e) {
        Write-Log ('精选库里没有 {0}，按裸包安装处理。' -f $Id) 'INFO'
        return (Install-GuiReadyPackage -Source 'choco' -Package $Id -WhatIf:$WhatIf)
    }

    $title = [string]$e.id
    if ($e.name_zh) { $title = [string]$e.name_zh }
    Write-Head ('安装精选应用: ' + $title + ' (' + [string]$e.id + ')')

    # 1) 兼容性
    $compat = [string]$e.compatibility
    if ($compat -eq 'unsupported') {
        Write-Log '该应用在当前系统上不兼容，已停止安装。' 'ERROR'
        foreach ($k in @($e.known_issues)) { if ($k) { Write-Log ('  ' + [string]$k) 'INFO' } }
        foreach ($a in @($e.alternatives)) { if ($a) { Write-Log ('  替代方案: ' + [string]$a) 'INFO' } }
        return $false
    }
    if ($compat -eq 'unverified') {
        Write-Log '该条目尚未在真机实测（unverified），安装后请自行验证。' 'WARN'
    }

    # 2) FOD（只有 GUI 应用才可能非空）
    foreach ($cap in @($e.fod_required)) {
        if ([string]::IsNullOrWhiteSpace([string]$cap)) { continue }
        $state = 'Unknown'
        try {
            $c = Get-WindowsCapability -Online -Name ([string]$cap) -ErrorAction Stop
            if ($c) { $state = [string]$c.State }
        } catch { }
        if ($state -ne 'Installed') {
            Write-Log ('需要 FOD 组件 {0}（当前 {1}）。请先在「环境补全」里安装并重启。' -f $cap, $state) 'ERROR'
            return $false
        }
        Write-Log ('FOD 已就绪: ' + [string]$cap) 'OK'
    }

    # 3) 运行库 / Windows 功能依赖
    foreach ($dep in @($e.runtime_deps)) {
        if ([string]::IsNullOrWhiteSpace([string]$dep)) { continue }
        if ([string]$dep -match 'Containers') {
            $f = $null
            try { $f = Get-WindowsFeature -Name Containers -ErrorAction SilentlyContinue } catch { }
            if ($f -and [string]$f.InstallState -ne 'Installed') {
                if ($WhatIf) {
                    Write-Log '将启用 Windows 功能: Containers' 'DRY'
                } else {
                    Write-Log '启用 Windows 功能: Containers（Docker Engine 需要）' 'INFO'
                    try {
                        $r = Install-WindowsFeature Containers -ErrorAction Stop
                        Write-Log ('已启用 Containers（RestartNeeded={0}）' -f $r.RestartNeeded) 'OK'
                    } catch {
                        Write-Log ('启用 Containers 失败: ' + $_.Exception.Message) 'ERROR'
                        return $false
                    }
                }
            } else {
                Write-Log 'Windows 功能 Containers 已就绪。' 'OK'
            }
        } else {
            Write-Log ('依赖提示: ' + [string]$dep + '（请确认已满足）') 'WARN'
        }
    }

    # 4) 主安装
    $itype = [string]$e.install.type
    $ipkg = [string]$e.install.id
    $ok = $false
    switch ($itype) {
        'choco' {
            $ok = Install-GuiReadyPackage -Source 'choco' -Package $ipkg -WhatIf:$WhatIf
        }
        'npm' {
            if ($WhatIf) {
                Write-Log ('将执行: npm install -g ' + $ipkg) 'DRY'
                $ok = $true
            } else {
                try {
                    & npm install -g $ipkg 2>&1 | ForEach-Object { Write-Log ([string]$_) 'INFO' }
                    $ok = ($LASTEXITCODE -eq 0)
                } catch {
                    Write-Log ('npm 安装失败: ' + $_.Exception.Message) 'ERROR'
                    $ok = $false
                }
            }
        }
        default {
            Write-Log ('该条目的安装方式暂不支持: ' + $itype + '（可参考 known_issues 手动安装）') 'ERROR'
            $ok = $false
        }
    }
    if (-not $ok) {
        Write-Log '安装失败。' 'ERROR'
        foreach ($k in @($e.known_issues)) { if ($k) { Write-Log ('  ' + [string]$k) 'INFO' } }
        return $false
    }
    if ($WhatIf) { return $true }

    # 5) 安装后验证：launch.exe 是否已经能在 PATH 里找到
    $exe = [string]$e.launch.exe
    if ($exe) {
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Log ('验证通过: ' + $exe + ' → ' + [string]$cmd.Source) 'OK'
        } else {
            Write-Log ('安装完成，但 PATH 里还找不到 ' + $exe + '。可能需要重开终端（或重启）。') 'WARN'
        }
    } else {
        Write-Log '安装完成。' 'OK'
    }
    return $true
}

function Get-GuiReadyStoreQueueStatePath {
    return (Join-Path $script:GuiReadyRoot 'state\store-queue.json')
}

function Install-GuiReadyStoreQueue {
    # 批量安装队列：按顺序逐个装，**单个失败不中断**，最后把失败项写进
    # state\store-queue.json —— 界面的「重试失败」只重跑这些条目。
    #
    # 为什么不做并行：choco 自己会锁安装目录，两个 choco 同时跑必然有一个报锁冲突；
    # 而且角色/功能那类前置（Containers 等）也不适合并发。
    param(
        [Parameter(Mandatory = $true)][string[]]$Ids,
        [switch]$WhatIf
    )

    # 包名来自界面 / 远程 feed：只接受保守字符集，且用 JSON 参数文件传进来（不拼命令行）。
    # 只按逗号分隔 —— 不能把空格也当分隔符，否则 "bad name" 会被拆成两个合法包名。
    $list = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($raw in @($Ids)) {
        foreach ($one in (([string]$raw) -split ',')) {
            $id = $one.Trim()
            if (-not $id) { continue }
            if ($id -notmatch '^[A-Za-z0-9._+-]+$') {
                Write-Log ('跳过非法包名: ' + $id) 'ERROR'
                continue
            }
            $k = $id.ToLower()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            [void]$list.Add($id)
        }
    }

    if ($list.Count -eq 0) {
        Write-Log '安装队列是空的。' 'ERROR'
        return $false
    }

    Write-Head ('安装队列: {0} 个应用' -f $list.Count)
    if ($WhatIf) {
        Write-Log '--- 预览模式，不做任何改动 ---' 'DRY'
        $n = 0
        foreach ($id in $list) { $n++; Write-Log ('  [{0}/{1}] {2}' -f $n, $list.Count, $id) 'DRY' }
        Write-Log '真跑时会逐个安装；某个失败不会中断后面的条目。' 'DRY'
        return $true
    }

    $done = @()
    $failed = @()
    $i = 0
    foreach ($id in $list) {
        $i++
        Write-Log ('[{0}/{1}] {2}' -f $i, $list.Count, $id) 'STEP'
        $ok = $false
        try {
            $ok = [bool](Install-GuiReadyStoreApp -Id $id)
        } catch {
            Write-Log ('安装异常: ' + $_.Exception.Message) 'ERROR'
            $ok = $false
        }
        if ($ok) {
            $done += $id
        } else {
            $failed += [pscustomobject]@{ Id = $id; Reason = '安装未完成，详见上方日志' }
        }
    }

    Write-Head '安装队列结果'
    Write-Log ('成功 {0} 个，失败 {1} 个。' -f $done.Count, $failed.Count) $(if ($failed.Count -eq 0) { 'OK' } else { 'WARN' })
    foreach ($f in $failed) { Write-Log ('  失败: {0}（{1}）' -f $f.Id, $f.Reason) 'ERROR' }

    # 失败清单落盘，供界面「重试失败」使用；全成功也写（Failed 为空 → 按钮隐藏）
    try {
        $p = Get-GuiReadyStoreQueueStatePath
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $state = [ordered]@{
            Updated   = (Get-Date).ToString('o')
            Total     = $list.Count
            Succeeded = @($done)
            Failed    = @($failed)
        }
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $state -Depth 4 -Compress),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Log ('写入队列状态失败: ' + $_.Exception.Message) 'WARN'
    }

    return ($failed.Count -eq 0)
}

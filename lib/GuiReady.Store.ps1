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
    # 发布包里是 <工具根>\store\catalog.json；开发树上就是仓库里的 store\catalog.json
    $p = Join-Path $script:GuiReadyRoot 'store\catalog.json'
    return $p
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
    # 关键词 + 分类 + 兼容性三重过滤。Keyword 为空表示"浏览"（按兼容性 + 热度排）。
    # 返回对象数组（已按"相关度 -> 兼容性 -> 热度"排好）。
    param(
        [string]$Keyword = '',
        [string]$Category = '',
        [string]$Compatibility = '',
        [int]$Limit = 200
    )

    $c = Import-GuiReadyStoreCatalog
    if (-not $c.Ok) { return @() }

    $kw = ([string]$Keyword).Trim().ToLower()
    $cat = ([string]$Category).Trim().ToLower()
    $cmp = ([string]$Compatibility).Trim().ToLower()

    $hits = New-Object System.Collections.ArrayList
    foreach ($a in $c.Apps) {
        if ($cat -and ([string]$a.category).ToLower() -ne $cat) { continue }
        if ($cmp -and ([string]$a.compatibility).ToLower() -ne $cmp) { continue }
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
    # 给界面用的统计：总数 / 各兼容性档数量 / 各分类数量。
    $c = Import-GuiReadyStoreCatalog
    if (-not $c.Ok) { return [pscustomobject]@{ Total = 0; ByCompat = @{}; ByCategory = @{}; Source = $c.Error } }
    $bc = @{}; $bcat = @{}
    foreach ($a in $c.Apps) {
        $k = [string]$a.compatibility
        if ($bc.ContainsKey($k)) { $bc[$k]++ } else { $bc[$k] = 1 }
        $k2 = [string]$a.category
        if ($bcat.ContainsKey($k2)) { $bcat[$k2]++ } else { $bcat[$k2] = 1 }
    }
    return [pscustomobject]@{ Total = @($c.Apps).Count; ByCompat = $bc; ByCategory = $bcat; Source = '' }
}

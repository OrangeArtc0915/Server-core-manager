# GuiReady store query runner: runs the package-source detection / search in a separate
# process so the store page never blocks the UI thread (choco search is a network call and
# takes seconds; scoop --version has to spin up PowerShell).
#
# Writes the result as JSON, atomically (tmp + Move), so the GUI can poll for the file
# without ever reading a half-written one - same pattern as Run-GuiReadyProbe.ps1.
#
# Modes:
#   status  -> the package-source list (which package managers exist, versions, support level)
#   search  -> search result for -Source / -Query
#   searchall -> aggregate search: Chocolatey first, npm second
#   local   -> the installed package list for -Source
#
# Keep this file ASCII-only: it ships inside the release zip and must parse under any
# console code page without depending on a BOM.

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$Source = 'choco',
    [string]$Query  = '',
    [string]$Package = '',
    [string]$AppId = '',
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

# One shared log file instead of one per query
$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-store.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Package.ps1', 'GuiReady.Store.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 数据类参数（搜索词 / 包名）优先从 JSON 文件读。
# 为什么不走命令行：包名来自远程 feed，而 Start-Process 的 ArgumentList 需要手工拼引号，
# 名字里带引号就能往命令行里注入额外参数。走文件则完全绕开引号拼接。
# 读完立刻删除（文件里可能含用户输入的搜索词）。
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $a = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($a.Source)  { $Source  = [string]$a.Source }
        if ($a.Query)   { $Query   = [string]$a.Query }
        if ($a.Package) { $Package = [string]$a.Package }
        if ($a.AppId)   { $AppId   = [string]$a.AppId }
    } catch { }
    try { Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue } catch { }
}

function Write-StoreResult {
    param($Items, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode    = $Mode
        Source  = $Source
        Query   = $Query
        Package = $Package
        Stamp   = (Get-Date).ToString('o')
        Error   = $ErrorText
        Items   = @($Items)
    }
    try {
        $json = $o | ConvertTo-Json -Depth 6 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    $items = @()
    switch ($Mode) {
        'status' { $items = @(Get-GuiReadyPackageSource) }
        'search' { $items = @(Search-GuiReadyPackage -Source $Source -Query $Query) }
        # 多源聚合：Chocolatey 优先 + npm 补充（Scoop 搜索未接入，pip search 上游已停用）
        'searchall' { $items = @(Search-GuiReadyPackageAll -Query $Query) }
        'local'  { $items = @(Get-GuiReadyInstalledPackage -Source $Source) }
        'outdated' { $items = @(Get-GuiReadyOutdatedPackage -Source $Source) }
        # 详情：单个对象也塞进 Items 数组，GUI 那边只认一种形状
        'info'   { $items = @(Get-GuiReadyPackageInfo -Source $Source -Package $Package) }
        # 精选库（store\catalog.json）：商店页的默认列表，带兼容性标记
        'curated' {
            if (Get-Command Import-GuiReadyStoreCatalog -ErrorAction SilentlyContinue) {
                $cat = Import-GuiReadyStoreCatalog
                $catName = @{}
                foreach ($c in @($cat.Categories)) { $catName[[string]$c.id] = [string]$c.name }
                $items = @($cat.Apps |
                    Sort-Object -Property @{ Expression = { - [int]$_.popularity } }, @{ Expression = { [string]$_.id } } |
                    ForEach-Object {
                        [pscustomobject]@{
                            Id          = [string]$_.install.id
                            CatalogId   = [string]$_.id
                            Name        = $(if ($_.name_zh) { [string]$_.name_zh } else { [string]$_.name })
                            NameEn      = [string]$_.name
                            Version     = ''
                            Source      = $(if ($_.source) { [string]$_.source } else { 'choco' })
                            Category    = [string]$_.category
                            CategoryName = $(if ($catName.ContainsKey([string]$_.category)) { $catName[[string]$_.category] } else { [string]$_.category })
                            Ui          = [string]$_.ui
                            Compat      = [string]$_.compatibility
                            CompatNote  = [string]$_.compatibility_note
                            Popularity  = [int]$_.popularity
                            Tags        = @($_.tags)
                            KnownIssues = @($_.known_issues)
                            Fod         = @($_.fod_required)
                            RuntimeDeps = @($_.runtime_deps)
                            Alternatives = @($_.alternatives)
                            TestedOn    = @($_.tested_on)
                            InstallType = [string]$_.install.type
                            InstallId   = [string]$_.install.id
                            InstallArgs = [string]$_.install.silent_args
                            LaunchExe   = [string]$_.launch.exe
                            LaunchArgs  = [string]$_.launch.args
                        }
                    })
            }
        }
        # 安装前预检：已装？包管理器在不在？要不要 FOD / 运行库？
        'precheck' {
            $cat = Import-GuiReadyStoreCatalog
            if (-not $cat.Ok) { throw ('精选库读取失败：' + $cat.Error) }
            $key = ([string]$AppId).Trim().ToLower()
            $app = $null
            if ($key -and $cat.ById.ContainsKey($key)) { $app = $cat.ById[$key] }
            if (-not $app) { throw ('精选库里没有这个条目：' + $AppId) }

            $installId = [string]$app.install.id
            $chocoReady = $false
            $chocoVersion = ''
            $npmReady = $false
            $npmVersion = ''
            foreach ($s in @(Get-GuiReadyPackageSource)) {
                if ([string]$s.Id -eq 'choco') {
                    $chocoReady = [bool]$s.Installed
                    $chocoVersion = [string]$s.Version
                } elseif ([string]$s.Id -eq 'npm') {
                    $npmReady = [bool]$s.Installed
                    $npmVersion = [string]$s.Version
                }
            }
            $installed = $false
            $installedVersion = ''
            if ($chocoReady) {
                foreach ($p in @(Get-GuiReadyInstalledPackage -Source 'choco')) {
                    $pkgId = [string]$p.Id
                    $pkgName = [string]$p.Name
                    if ($pkgId -ieq $installId -or $pkgName -ieq $installId) {
                        $installed = $true
                        $installedVersion = [string]$p.Version
                        break
                    }
                }
            }
            # npm 包用 npm ls -g 判已装（choco 的本地列表看不到它们）
            if (-not $installed -and $npmReady -and [string]$app.install.type -eq 'npm') {
                try {
                    $raw = @(& npm ls -g --depth=0 2>$null)
                    $pat = [regex]::Escape($installId) + '@([0-9][\w\.\-\+]*)'
                    foreach ($l in $raw) {
                        $m = [regex]::Match([string]$l, $pat)
                        if ($m.Success) { $installed = $true; $installedVersion = $m.Groups[1].Value; break }
                    }
                } catch { }
            }
            $fod = @($app.fod_required | Where-Object { $_ })
            $fodState = ''
            if ($fod.Count -gt 0) { $fodState = [string](Get-FodState) }

            $notes = New-Object System.Collections.ArrayList
            if ($installed) { [void]$notes.Add(('已经安装（{0}）——再点安装会走升级/重装' -f $installedVersion)) }
            if ([string]$app.install.type -eq 'npm') {
                if (-not $npmReady) { [void]$notes.Add('本机没有 npm，装不了这个 npm 包；先在「运行库」页装 Node.js') }
            } elseif (-not $chocoReady) {
                [void]$notes.Add('本机没有 Chocolatey，安装会失败；先点「装 Chocolatey」')
            }
            if ($fod.Count -gt 0 -and $fodState -notmatch 'Installed') {
                [void]$notes.Add(('需要 App Compatibility FOD（当前 {0}）；「环境补全」页可一键补' -f $fodState))
            }
            if ([string]$app.compatibility -eq 'unsupported') { [void]$notes.Add('精选库标记为『不支持』，请确认真的要在 Server Core 上装') }
            if ([string]$app.compatibility -eq 'unverified') { [void]$notes.Add('尚未实测；装完建议先跑一次命令验证') }
            foreach ($dep in @($app.runtime_deps | Where-Object { $_ })) {
                $d = [string]$dep
                if ($d -match '环境变量|API_KEY') { [void]$notes.Add('需要设置 ' + $d) }
                elseif ($d -match '(?i)pnpm') { [void]$notes.Add('依赖 ' + $d + '：可用 npm i -g pnpm 安装') }
                else { [void]$notes.Add('运行库依赖：' + $d + '（运行库页可装）') }
            }

            $items = @([pscustomobject]@{
                CatalogId        = [string]$app.id
                Name             = $(if ($app.name_zh) { [string]$app.name_zh } else { [string]$app.name })
                InstallId        = $installId
                InstallType      = [string]$app.install.type
                Installed        = $installed
                InstalledVersion = $installedVersion
                ChocoReady       = $chocoReady
                ChocoVersion     = $chocoVersion
                NpmReady         = $npmReady
                NpmVersion       = $npmVersion
                Compat           = [string]$app.compatibility
                Fod              = $fod
                FodState         = $fodState
                RuntimeDeps      = @($app.runtime_deps | Where-Object { $_ })
                Notes            = @($notes)
            })
        }
        # 上次批量安装队列的结果（供界面「重试失败」用）；同样只回一个对象
        'queue-state' {
            $p = Join-Path $toolRoot 'state\store-queue.json'
            if (Test-Path -LiteralPath $p) {
                try {
                    $s = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
                    $items = @([pscustomobject]@{
                        Updated   = [string]$s.Updated
                        Total     = [int]$s.Total
                        Failed    = @($s.Failed | ForEach-Object { [string]$_.Id })
                        Succeeded = @($s.Succeeded | ForEach-Object { [string]$_ })
                    })
                } catch { $items = @() }
            }
        }
        default {
            Write-StoreResult -Items @() -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
    Write-StoreResult -Items $items
    exit 0
} catch {
    Write-StoreResult -Items @() -ErrorText $_.Exception.Message
    exit 1
}

# GuiReady 附属工具（TUI_TOOL）：清单、本地状态、GitHub / Gitee 双线路下载。
#
# 约定：
#   - 每个工具的源码放在主仓库的独立分支 tool/<id>，main 分支不带这些源码；
#   - GitHub 与 Gitee 用同一条分支名，下载地址只有域名不同；
#   - 下载后先校验 zip 魔数，再解压到临时目录，成功后才替换旧版本（失败保留旧版本）；
#   - 安装位置 payload\plugins\<id>（payload 不进打包，属于本机安装状态）。

function Get-GuiReadyPluginRoot {
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Join-Path $root 'payload\plugins')
}

function Get-GuiReadyPluginCatalog {
    $gh = 'https://github.com/Server-Core-Mananger/Server-core-manager'
    $gt = 'https://gitee.com/orangearc655743/server-core-manager'
    # GitHub / Gitee 两条线路都下载发行包（编译好的 zip），不下载源码。
    return @(
        [pscustomobject]@{
            Id         = 'scterm'
            Title      = 'scterm'
            Kind       = '终端'
            Branch     = 'tool/scterm'
            Desc       = 'Rust 单文件终端多路复用，Server Core 可直接运行（发行包内含 scterm.exe）。'
            GitHubZip  = $gh + '/releases/download/scterm-v0.1.0/scterm-v0.1.0-win-x64.zip'
            GiteeZip   = $gt + '/releases/download/scterm-v0.1.0/scterm-v0.1.0-win-x64.zip'
            BranchPage = $gh + '/releases/tag/scterm-v0.1.0'
            GiteePage  = $gt + '/releases/tag/scterm-v0.1.0'
        }
        [pscustomobject]@{
            Id         = 'tuimonitor'
            Title      = 'scm-top'
            Kind       = 'TUI 监控'
            Branch     = 'tool/tuimonitor'
            Desc       = '零依赖 TUI 监控（Get-Counter / CIM），离线可用；发行包内含 scm-top.ps1 / .cmd。'
            GitHubZip  = $gh + '/releases/download/scm-top-v0.1.0/scm-top-v0.1.0.zip'
            GiteeZip   = $gt + '/releases/download/scm-top-v0.1.0/scm-top-v0.1.0.zip'
            BranchPage = $gh + '/releases/tag/scm-top-v0.1.0'
            GiteePage  = $gt + '/releases/tag/scm-top-v0.1.0'
        }
        [pscustomobject]@{
            Id         = 'textm'
            Title      = 'Textm'
            Kind       = '文本 / 代码编辑'
            Branch     = 'tool/textm'
            Desc       = '终端 / 图形双模式编辑器（Rust，单文件）；发行包内含 textm.exe、使用说明与技术文档。'
            GitHubZip  = $gh + '/releases/download/textm-v2.0.0/textm-v2.0.0-win-x64.zip'
            GiteeZip   = $gt + '/releases/download/textm-v2.0.0/textm-v2.0.0-win-x64.zip'
            BranchPage = $gh + '/releases/tag/textm-v2.0.0'
            GiteePage  = $gt + '/releases/tag/textm-v2.0.0'
        }
        [pscustomobject]@{
            Id         = 'craftdock'
            Title      = 'CraftDock'
            Kind       = '终端服务器管理'
            Branch     = 'tool/craftdock'
            Desc       = 'TypeScript 终端服务器管理面板；发行包内含 craftdock.exe。'
            GitHubZip  = $gh + '/releases/download/craftdock-v1.0.0/craftdock-v1.0.0-win-x64.zip'
            GiteeZip   = $gt + '/releases/download/craftdock-v1.0.0/craftdock-v1.0.0-win-x64.zip'
            BranchPage = $gh + '/releases/tag/craftdock-v1.0.0'
            GiteePage  = $gt + '/releases/tag/craftdock-v1.0.0'
        }
    )
}

function Get-GuiReadyPluginLocalState {
    param([Parameter(Mandatory = $true)]$Item)

    $dir = Join-Path (Get-GuiReadyPluginRoot) ([string]$Item.Id)
    $markerPath = Join-Path $dir '.scm-plugin.json'
    $marker = $null
    if (Test-Path -LiteralPath $markerPath) {
        try { $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }

    $count = 0
    $bytes = 0
    if (Test-Path -LiteralPath $dir) {
        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)
        $count = $files.Count
        if ($count -gt 0) { $bytes = [double](($files | Measure-Object -Property Length -Sum).Sum) }
    }

    return [pscustomobject]@{
        Path        = $dir
        Installed   = ($count -gt 0)
        FileCount   = $count
        SizeMB      = [Math]::Round($bytes / 1MB, 2)
        InstalledAt = $(if ($marker) { [string]$marker.InstalledAt } else { '' })
        Source      = $(if ($marker) { [string]$marker.Source } else { '' })
        Url         = $(if ($marker) { [string]$marker.Url } else { '' })
        Sha256      = $(if ($marker) { [string]$marker.Sha256 } else { '' })
    }
}

function Get-GuiReadyPluginStatus {
    $rows = @()
    foreach ($it in @(Get-GuiReadyPluginCatalog)) {
        $s = Get-GuiReadyPluginLocalState -Item $it
        $rows += [pscustomobject]@{
            Id          = [string]$it.Id
            Name        = [string]$it.Title
            Kind        = [string]$it.Kind
            Desc        = [string]$it.Desc
            Branch      = [string]$it.Branch
            GitHubZip   = [string]$it.GitHubZip
            GiteeZip    = [string]$it.GiteeZip
            BranchPage  = [string]$it.BranchPage
            GiteePage   = [string]$it.GiteePage
            LocalPath   = [string]$s.Path
            LocalState  = $(if ($s.Installed) { '已下载' } else { '未下载' })
            LocalSizeMB = [double]$s.SizeMB
            FileCount   = [int]$s.FileCount
            InstalledAt = [string]$s.InstalledAt
            Source      = [string]$s.Source
            Sha256      = [string]$s.Sha256
        }
    }
    return $rows
}

function Install-GuiReadyPlugin {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('github', 'gitee')][string]$Source,
        [switch]$DryRun
    )

    $item = @(Get-GuiReadyPluginCatalog | Where-Object { [string]$_.Id -eq $Id }) | Select-Object -First 1
    if (-not $item) { throw ('未知附属工具：' + $Id) }

    $url = $(if ($Source -eq 'gitee') { [string]$item.GiteeZip } else { [string]$item.GitHubZip })
    $root = Get-GuiReadyPluginRoot
    $target = Join-Path $root $Id

    Write-Log ('附属工具 {0}（{1} 线路）' -f $item.Title, $Source) 'STEP'
    Write-Log ('下载地址：' + $url) 'INFO'
    Write-Log ('安装目录：' + $target) 'INFO'

    if ($DryRun) {
        Write-Log ('[预览] 将下载并解压到 ' + $target + '（已安装时整体替换，失败保留旧版本）') 'DRY'
        return [pscustomobject]@{ Id = $Id; Source = $Source; Url = $url; Path = $target; DryRun = $true; Ok = $true }
    }

    $work = Join-Path $env:TEMP ('scm-plugin-' + $Id + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $zip = Join-Path $work ($Id + '.zip')
    $extract = Join-Path $work 'extract'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Log ('开始下载（' + $Source + '）…') 'INFO'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        $sw.Stop()

        if (-not (Test-Path -LiteralPath $zip)) { throw '下载失败：没有生成文件' }
        $fi = Get-Item -LiteralPath $zip
        if ($fi.Length -lt 1024) { throw ('下载内容异常（只有 {0} 字节，可能是不存在分支的错误页）' -f $fi.Length) }

        # zip 魔数 PK：被登录页 / 错误页 / 代理拦截时，这里能第一时间拦住
        $fs = [System.IO.File]::OpenRead($zip)
        try { $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte() } finally { $fs.Close() }
        if (-not ($b1 -eq 0x50 -and $b2 -eq 0x4B)) {
            throw '下载到的不是 zip（文件头不是 PK），可能被登录页或代理拦截了'
        }

        $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        $sizeText = $(if ($fi.Length -ge 1MB) { '{0:N2} MB' -f ($fi.Length / 1MB) } else { '{0:N0} KB' -f ($fi.Length / 1KB) })
        Write-Log ('下载完成：{0}，用时 {1:N1} 秒，SHA256 {2}' -f $sizeText, $sw.Elapsed.TotalSeconds, $sha) 'OK'

        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force -ErrorAction Stop

        # GitHub / Gitee 的 zip 都只有一个顶层目录
        $top = @(Get-ChildItem -LiteralPath $extract -Force)
        $src = $extract
        if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $src = $top[0].FullName }

        $files = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { throw '压缩包里没有文件' }

        $stage = Join-Path $work 'stage'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $stage -Recurse -Force

        [ordered]@{
            Id          = $Id
            Branch      = [string]$item.Branch
            Source      = $Source
            Url         = $url
            Sha256      = $sha
            InstalledAt = (Get-Date).ToString('o')
            FileCount   = $files.Count
        } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $stage '.scm-plugin.json') -Encoding UTF8

        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }

        $backup = $null
        if (Test-Path -LiteralPath $target) {
            $backup = $target + '.old-' + (Get-Date -Format 'yyyyMMddHHmmss')
            Move-Item -LiteralPath $target -Destination $backup -Force
        }
        try {
            Move-Item -LiteralPath $stage -Destination $target -Force
        } catch {
            if ($backup -and (Test-Path -LiteralPath $backup)) {
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
                Move-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue
                Write-Log '新版本落位失败，已恢复旧版本' 'WARN'
            }
            throw
        }
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Log ('已安装到 ' + $target + '（' + $files.Count + ' 个文件）') 'OK'
        return [pscustomobject]@{
            Id = $Id; Source = $Source; Url = $url; Path = $target
            DryRun = $false; Ok = $true; FileCount = $files.Count; Sha256 = $sha
        }
    } finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

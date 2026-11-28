# GuiReady self-update: check tags on GitHub / Gitee, download the release zip,
# stage it and hand over to a detached apply script.
#
# 设计要点：
#   - 仓库里同时有主程序 tag（v2.3）和附属工具 tag（textm-v2.0.0 等），
#     所以不能用 releases/latest，必须过滤成 ^v<数字>.<数字>(.<数字>)?$ 再比大小。
#   - 下载的是整包 ServerCoreManager.zip；替换时保留用户数据目录，
#     并且不能覆盖 launcher\programs.json（用户的程序列表）。
#   - 替换脚本在 state\update\ 下运行，等主进程退出后再动文件，失败会回滚并留下标记。

$Global:GuiReadyUpdateRepos = @{
    github = 'Server-Core-Mananger/Server-core-manager'
    gitee  = 'orangearc655743/server-core-manager'
}
$Global:GuiReadyUpdateAsset = 'ServerCoreManager.zip'

function Get-GuiReadyLocalVersion {
    # install.ps1 里的 $ScmVer 是发版时唯一会改的地方，直接拿它当当前版本
    $p = Join-Path $script:GuiReadyRoot 'install.ps1'
    if (Test-Path -LiteralPath $p) {
        try {
            $m = Select-String -LiteralPath $p -Pattern '\$ScmVer\s*=\s*''(v[0-9][0-9.]*)''' | Select-Object -First 1
            if ($m) { return [string]$m.Matches[0].Groups[1].Value }
        } catch { }
    }
    return 'v0.0.0'
}

function ConvertTo-GuiReadyVersion([string]$Tag) {
    $t = ([string]$Tag).Trim() -replace '^[vV]', ''
    $parts = @($t.Split('.'))
    while ($parts.Count -lt 3) { $parts += '0' }
    try { return [version]($parts[0..2] -join '.') } catch { return [version]'0.0.0' }
}

function Select-GuiReadyMainTag {
    param([string[]]$Tags)
    $main = @($Tags | Where-Object { $_ -match '^v\d+\.\d+(\.\d+)?$' })
    if ($main.Count -eq 0) { return '' }
    return ($main | Sort-Object { ConvertTo-GuiReadyVersion $_ } -Descending | Select-Object -First 1)
}

function Invoke-GuiReadyWeb {
    param([string]$Url, [string]$Accept = '')
    $headers = @{ 'User-Agent' = 'SCM-Updater/2.4 (+https://github.com/Server-Core-Mananger/Server-core-manager)' }
    if ($Accept) { $headers['Accept'] = $Accept }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    return Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 30
}

function Get-GuiReadyUpdateTags {
    param([ValidateSet('github', 'gitee')][string]$Source)
    $repo = $Global:GuiReadyUpdateRepos[$Source]
    $tags = @()
    $err = ''

    if ($Source -eq 'github') {
        try {
            $html = (Invoke-GuiReadyWeb ('https://github.com/' + $repo + '/releases')).Content
            foreach ($m in [regex]::Matches($html, '/releases/tag/([^"/?#]+)')) {
                $tags += [Uri]::UnescapeDataString($m.Groups[1].Value)
            }
        } catch { $err = $_.Exception.Message }
    } else {
        # Gitee 先走公开接口；接口不可用时退回发行页 HTML
        try {
            $json = (Invoke-GuiReadyWeb ('https://gitee.com/api/v5/repos/' + $repo + '/releases?per_page=100') 'application/json').Content
            # PS 5.1 的 ConvertFrom-Json 把顶层数组当成一个对象输出，直接 foreach 会拿到「整个数组」
            # （$tags 被拼成一整串，tag 过滤就永远不命中）。这里先摊平。
            $parsed = $json | ConvertFrom-Json
            if ($parsed -isnot [array]) { $parsed = @($parsed) }
            foreach ($r in $parsed) { if ($r.tag_name) { $tags += [string]$r.tag_name } }
        } catch { $err = $_.Exception.Message }
        if ($tags.Count -eq 0) {
            try {
                $html = (Invoke-GuiReadyWeb ('https://gitee.com/' + $repo + '/releases')).Content
                foreach ($m in [regex]::Matches($html, '/releases/tag/([^"/?#]+)')) {
                    $tags += [Uri]::UnescapeDataString($m.Groups[1].Value)
                }
            } catch { $err = $_.Exception.Message }
        }
    }

    [pscustomobject]@{
        Ok    = ($tags.Count -gt 0)
        Tags  = @($tags | Sort-Object -Unique)
        Error = $err
    }
}

function Invoke-GuiReadySelfUpdateCheck {
    param([string]$Source = 'auto')

    $order = if ($Source -eq 'gitee') { @('gitee', 'github') } else { @('github', 'gitee') }
    $current = Get-GuiReadyLocalVersion
    $errors = @()

    foreach ($src in $order) {
        $r = Get-GuiReadyUpdateTags -Source $src
        if (-not $r.Ok) {
            if ($r.Error) { $errors += ($src + ': ' + $r.Error) }
            continue
        }
        $tag = Select-GuiReadyMainTag -Tags $r.Tags
        if (-not $tag) { continue }

        $repo = $Global:GuiReadyUpdateRepos[$src]
        $base = if ($src -eq 'github') { 'https://github.com/' + $repo } else { 'https://gitee.com/' + $repo }
        $available = ((ConvertTo-GuiReadyVersion $tag) -gt (ConvertTo-GuiReadyVersion $current))

        return [pscustomobject]@{
            Ok           = $true
            Available    = $available
            Current      = $current
            Latest       = $tag
            Tag          = $tag
            Source       = $src
            ZipUrl       = ($base + '/releases/download/' + $tag + '/' + $Global:GuiReadyUpdateAsset)
            ShaUrl       = ($base + '/releases/download/' + $tag + '/' + $Global:GuiReadyUpdateAsset + '.sha256')
            ReleasePage  = ($base + '/releases/tag/' + $tag)
            Error        = ''
        }
    }

    [pscustomobject]@{
        Ok          = $false
        Available   = $false
        Current     = $current
        Latest      = ''
        Tag         = ''
        Source      = ''
        ZipUrl      = ''
        ShaUrl      = ''
        ReleasePage = ''
        Error       = ($errors -join ' | ')
    }
}

function Test-GuiReadyAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# 替换脚本模板。全部 ASCII：它会在任意控制台代码页下运行，且不依赖 BOM。
$Global:GuiReadyApplyScriptTemplate = @'
param([string]$Root, [string]$NewDir, [int]$WaitPid, [string]$Restart, [string]$Marker)

$ErrorActionPreference = 'Stop'
$work = Split-Path $NewDir -Parent
$log = Join-Path $work 'apply.log'

function L($m) {
    try { Add-Content -LiteralPath $log -Value ((Get-Date -Format 's') + ' ' + $m) -Encoding UTF8 } catch { }
}

function Copy-Tree($src, $dst, [switch]$SkipPrograms) {
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    foreach ($c in Get-ChildItem -LiteralPath $src) {
        if ($SkipPrograms -and $c.Name -eq 'programs.json') { L 'keep user programs.json'; continue }
        $t = Join-Path $dst $c.Name
        if ($c.PSIsContainer) { Copy-Tree $c.FullName $t }
        else { Copy-Item -LiteralPath $c.FullName -Destination $t -Force }
    }
}

function Restart-App {
    try {
        if ($Restart -and (Test-Path -LiteralPath $Restart)) {
            Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $Restart + '"') -WindowStyle Hidden
            L 'restarted'
        }
    } catch { L ('restart failed: ' + $_.Exception.Message) }
}

try {
    L ('waiting for pid ' + $WaitPid)
    for ($i = 0; $i -lt 180; $i++) {
        if (-not (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Seconds 1
    }
    if (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) {
        L 'timeout waiting for app exit'
        Set-Content -LiteralPath $Marker -Value 'timeout' -Encoding ASCII
        exit 2
    }

    $rollback = Join-Path $work 'rollback'
    if (Test-Path -LiteralPath $rollback) { Remove-Item -LiteralPath $rollback -Recurse -Force }

    # 1) backup only what this package replaces
    New-Item -ItemType Directory -Path $rollback -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $NewDir) {
        $target = Join-Path $Root $item.Name
        if (-not (Test-Path -LiteralPath $target)) { continue }
        if ($item.PSIsContainer) {
            Copy-Tree $target (Join-Path $rollback $item.Name)
        } else {
            Copy-Item -LiteralPath $target -Destination (Join-Path $rollback $item.Name) -Force
        }
    }
    L 'backup done'

    # 2) apply
    try {
        foreach ($item in Get-ChildItem -LiteralPath $NewDir) {
            if ($item.Name -eq 'launcher') {
                Copy-Tree $item.FullName (Join-Path $Root 'launcher') -SkipPrograms
            } elseif ($item.PSIsContainer) {
                Copy-Tree $item.FullName (Join-Path $Root $item.Name)
            } else {
                Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Root $item.Name) -Force
            }
        }
        L 'copy done'
    } catch {
        L ('copy failed: ' + $_.Exception.Message)
        try {
            foreach ($item in Get-ChildItem -LiteralPath $rollback) {
                if ($item.PSIsContainer) { Copy-Tree $item.FullName (Join-Path $Root $item.Name) }
                else { Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Root $item.Name) -Force }
            }
            L 'rolled back'
        } catch { L ('rollback failed: ' + $_.Exception.Message) }
        Set-Content -LiteralPath $Marker -Value 'failed' -Encoding ASCII
        Restart-App
        exit 1
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Root 'install.ps1'))) {
        L 'verify failed: install.ps1 missing'
        Set-Content -LiteralPath $Marker -Value 'broken' -Encoding ASCII
        Restart-App
        exit 3
    }

    if (Test-Path -LiteralPath $Marker) { Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $NewDir -Recurse -Force -ErrorAction SilentlyContinue
    L 'update ok'
    Restart-App
    exit 0
} catch {
    L ('fatal: ' + $_.Exception.Message)
    try { Set-Content -LiteralPath $Marker -Value 'failed' -Encoding ASCII } catch { }
    Start-Sleep -Seconds 2
    Restart-App
    exit 4
}
'@

function Invoke-GuiReadySelfUpdateInstall {
    param($Info, [int]$WaitPid)

    $root = $script:GuiReadyRoot
    if (-not (Test-GuiReadyAdministrator)) {
        return [pscustomobject]@{ Ok = $false; Error = 'elevation-required'; Version = ''; Message = '' }
    }
    if (-not $Info -or -not $Info.Tag -or -not $Info.ZipUrl) {
        return [pscustomobject]@{ Ok = $false; Error = 'no-update-info'; Version = ''; Message = '' }
    }

    $work = Join-Path $root 'state\update'
    $newDir = Join-Path $work 'new'
    $zip = Join-Path $work ('ServerCoreManager-' + $Info.Tag + '.zip')
    $marker = Join-Path $work 'failed.txt'

    try {
        if (Test-Path -LiteralPath $work) {
            foreach ($x in @($zip, ($zip + '.sha256'))) {
                if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue }
            }
            if (Test-Path -LiteralPath $newDir) { Remove-Item -LiteralPath $newDir -Recurse -Force }
        }
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }

        Write-Log ('下载更新包: ' + $Info.ZipUrl) 'INFO'
        Invoke-WebRequest -Uri $Info.ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 600

        # 侧车哈希必须存在且一致；对不上就中止，绝不解压
        $shaOk = $false
        try {
            $txt = (Invoke-WebRequest -Uri $Info.ShaUrl -UseBasicParsing -TimeoutSec 60).Content
            $expect = ([string]$txt -split '\s+')[0]
            if ($expect -match '^[0-9A-Fa-f]{64}$') {
                $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
                if ($actual -ieq $expect) { $shaOk = $true }
                else { throw ('hash mismatch: expected ' + $expect + ', actual ' + $actual) }
            } else {
                throw 'sha256 sidecar has unexpected content'
            }
        } catch {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Ok = $false; Error = 'hash'; Version = $Info.Tag; Message = $_.Exception.Message }
        }
        if (-not $shaOk) {
            return [pscustomobject]@{ Ok = $false; Error = 'hash'; Version = $Info.Tag; Message = 'hash not verified' }
        }
        Write-Log '更新包哈希校验通过' 'OK'

        Expand-Archive -LiteralPath $zip -DestinationPath $newDir -Force
        foreach ($need in @('install.ps1', 'gui\GuiReady.GuiApp.ps1', 'ui\bin\ScmUi.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $newDir $need))) {
                return [pscustomobject]@{ Ok = $false; Error = 'package'; Version = $Info.Tag; Message = ('missing ' + $need) }
            }
        }

        $apply = Join-Path $work ('apply-' + $Info.Tag + '.ps1')
        [IO.File]::WriteAllText($apply, $Global:GuiReadyApplyScriptTemplate, (New-Object System.Text.UTF8Encoding($false)))

        $restart = Join-Path $root 'Start-GuiReadyApp.ps1'
        $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $apply + '" -Root "' + $root + '" -NewDir "' + $newDir +
                '" -WaitPid ' + $WaitPid + ' -Restart "' + $restart + '" -Marker "' + $marker + '"'
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden | Out-Null
        Write-Log ('已交棒给替换脚本，等待主进程退出: ' + $apply) 'INFO'

        return [pscustomobject]@{ Ok = $true; Error = ''; Version = $Info.Tag; Message = '' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = 'download'; Version = $Info.Tag; Message = $_.Exception.Message }
    }
}

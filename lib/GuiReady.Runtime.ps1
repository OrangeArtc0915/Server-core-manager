# GuiReady 运行库：在 Windows Server Core 上做「多版本运行时」管理。
#
# 为什么不是 Docker：
#   XMP 的做法是拉 node / python / mysql 容器，Server Core 没有容器平台可依赖
#   （Windows 容器要求 Host Process / Hyper-V 隔离，且镜像不是官方 Linux 镜像）。
#   这里换成 Windows 原生的等价形态：官方 zip 解压到 <root>\runtimes\<语言>\<版本>，
#   再用目录 junction 把 <root>\runtimes\<语言>\current 指到当前版本，
#   机器 PATH 只挂 current —— 切版本就是换 junction，不用改任何脚本。
#
# 约定：
#   - 只动「机器 PATH」，不碰用户 PATH；改动后新开的进程才看得到。
#   - 所有版本目录由本模块管理；删除版本前先摘掉 current 链接，避免误删目标。
#   - 下载地址全部为官方 zip（2026-11 实测可访问），不引入第三方安装器。

function Get-GuiReadyRuntimeRoot {
    # 允许用环境变量改位置（例如放到 D 盘或共享目录）
    if ($env:SCM_RUNTIME_ROOT) {
        try { return [System.IO.Path]::GetFullPath([string]$env:SCM_RUNTIME_ROOT) } catch { return [string]$env:SCM_RUNTIME_ROOT }
    }
    $root = $script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Join-Path $root 'runtimes')
}

# ---------------------------------------------------------------- 版本清单
# PathSub：可执行文件相对「版本目录」的子目录（Go 在 go\bin 里，Java 在 bin 里）
# Exe    ：用来探测版本的可执行文件名
# Probe  ：传给 exe 的参数
function Get-GuiReadyRuntimeCatalog {
    return @(
        [pscustomobject]@{
            Id = 'node'; Name = 'Node.js'; Category = '语言运行时'; Exe = 'node.exe'; Probe = '-v'; PathSub = ''
            Note = '前端 / 脚本工具链的底座；装完直接 node -v、npm -v。'
            Versions = @(
                @{ Version = '22.11.0'; Size = '约 30 MB'; Url = 'https://nodejs.org/dist/v22.11.0/node-v22.11.0-win-x64.zip'
                   Mirrors = @('https://npmmirror.com/mirrors/node/v22.11.0/node-v22.11.0-win-x64.zip') }
                @{ Version = '20.18.1'; Size = '约 28 MB'; Url = 'https://nodejs.org/dist/v20.18.1/node-v20.18.1-win-x64.zip'
                   Mirrors = @('https://npmmirror.com/mirrors/node/v20.18.1/node-v20.18.1-win-x64.zip') }
            )
        }
        [pscustomobject]@{
            Id = 'python'; Name = 'Python'; Category = '语言运行时'; Exe = 'python.exe'; Probe = '--version'; PathSub = ''
            Note = '官方 embed 版（不带 pip / Tcl）；site-packages 已打开，装包用 get-pip.py 或改用完整安装包。'
            Versions = @(
                @{ Version = '3.12.7'; Size = '约 11 MB'; Url = 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-embed-amd64.zip'
                   Mirrors = @('https://mirrors.huaweicloud.com/python/3.12.7/python-3.12.7-embed-amd64.zip') }
                @{ Version = '3.11.9'; Size = '约 10 MB'; Url = 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip'
                   Mirrors = @('https://mirrors.huaweicloud.com/python/3.11.9/python-3.11.9-embed-amd64.zip') }
            )
        }
        [pscustomobject]@{
            Id = 'go'; Name = 'Go'; Category = '语言运行时'; Exe = 'go.exe'; Probe = 'version'; PathSub = 'bin'
            Note = '解压即用；GOPATH 默认在用户目录，无需额外配置。'
            Versions = @(
                @{ Version = '1.23.4'; Size = '约 70 MB'; Url = 'https://go.dev/dl/go1.23.4.windows-amd64.zip'
                   Mirrors = @('https://mirrors.aliyun.com/golang/go1.23.4.windows-amd64.zip') }
                @{ Version = '1.22.10'; Size = '约 68 MB'; Url = 'https://go.dev/dl/go1.22.10.windows-amd64.zip'
                   Mirrors = @('https://mirrors.aliyun.com/golang/go1.22.10.windows-amd64.zip') }
            )
        }
        [pscustomobject]@{
            Id = 'java'; Name = 'Java (Temurin)'; Category = '语言运行时'; Exe = 'java.exe'; Probe = '-version'; PathSub = 'bin'
            Note = 'Eclipse Temurin JDK；java -version 输出在 stderr，属正常现象。'
            Versions = @(
                @{ Version = '21.0.5'; Size = '约 190 MB'; Url = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_x64_windows_hotspot_21.0.5_11.zip' }
                @{ Version = '17.0.13'; Size = '约 180 MB'; Url = 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_windows_hotspot_17.0.13_11.zip' }
            )
        }
        [pscustomobject]@{
            Id = 'php'; Name = 'PHP'; Category = '语言运行时'; Exe = 'php.exe'; Probe = '-v'; PathSub = ''
            Note = 'NTS 线程安全版；依赖 VC++ 2015-2022 x64 运行库（环境补全页可装）。'
            Versions = @(
                @{ Version = '8.1.34'; Size = '约 30 MB'; Url = 'https://windows.php.net/downloads/releases/php-8.1.34-nts-Win32-vs16-x64.zip' }
            )
        }
        [pscustomobject]@{
            Id = 'bun'; Name = 'Bun'; Category = '语言运行时'; Exe = 'bun.exe'; Probe = '-v'; PathSub = ''
            Note = '单文件 JS 运行时（含包管理器）；Server Core 上无需额外依赖。'
            Versions = @(
                @{ Version = '1.1.38'; Size = '约 90 MB'; Url = 'https://github.com/oven-sh/bun/releases/download/bun-v1.1.38/bun-windows-x64.zip' }
            )
        }
    )
}

function Get-GuiReadyRuntimeEntry {
    param([Parameter(Mandatory = $true)][string]$Id)
    foreach ($e in (Get-GuiReadyRuntimeCatalog)) {
        if ($e.Id -eq $Id) { return $e }
    }
    return $null
}

function Get-GuiReadyRuntimeLangDir {
    param([Parameter(Mandatory = $true)][string]$Id)
    return (Join-Path (Get-GuiReadyRuntimeRoot) $Id)
}

function Get-GuiReadyRuntimeVersionDir {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$Version)
    return (Join-Path (Get-GuiReadyRuntimeLangDir $Id) $Version)
}

function Get-GuiReadyRuntimeCurrentLink {
    param([Parameter(Mandatory = $true)][string]$Id)
    return (Join-Path (Get-GuiReadyRuntimeLangDir $Id) 'current')
}

function Get-GuiReadyRuntimePathEntry {
    # 这个语言应该在 PATH 里出现的条目（junction 下的子目录）
    param([Parameter(Mandatory = $true)]$Entry)
    $link = Get-GuiReadyRuntimeCurrentLink ([string]$Entry.Id)
    $sub  = [string]$Entry.PathSub
    if ($sub) { return (Join-Path $link $sub) }
    return $link
}

function Get-GuiReadyRuntimeSortKey {
    param([string]$Version)
    $m = [regex]::Match([string]$Version, '^(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $m.Success) { return '000000000' }
    return ('{0:D4}{1:D4}{2:D4}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value)
}

function Get-GuiReadyRuntimeLinkTarget {
    param([Parameter(Mandatory = $true)][string]$Link)
    try {
        $item = Get-Item -LiteralPath $Link -Force -ErrorAction Stop
        $t = $item.Target
        if ($t) {
            if ($t -is [array]) { $t = $t[0] }
            return [string]$t
        }
    } catch { }
    return ''
}

function Remove-GuiReadyRuntimeLink {
    param([Parameter(Mandatory = $true)][string]$Link)
    if (-not (Test-Path -LiteralPath $Link)) { return }
    try {
        # 目录 junction 用 Directory.Delete(false) 只摘链接，不会跟进目标目录
        [System.IO.Directory]::Delete($Link, $false)
    } catch {
        try { Remove-Item -LiteralPath $Link -Force -Recurse } catch { }
    }
}

function New-GuiReadyRuntimeLink {
    param(
        [Parameter(Mandatory = $true)][string]$Link,
        [Parameter(Mandatory = $true)][string]$Target
    )
    Remove-GuiReadyRuntimeLink -Link $Link
    $parent = Split-Path -Parent $Link
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    # 优先用 .NET 的 mklink 等价物：New-Item -ItemType Junction 在 5.1 上可用，
    # 但个别精简系统把该 provider 裁掉了，失败时退回 cmd 的 mklink /J。
    $ok = $false
    try {
        New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null
        $ok = $true
    } catch {
        try {
            & cmd.exe /c ('mklink /J "{0}" "{1}"' -f $Link, $Target) | Out-Null
            $ok = (Test-Path -LiteralPath $Link)
        } catch { $ok = $false }
    }
    if (-not $ok) { throw ('创建 junction 失败：' + $Link) }
}

# ---------------------------------------------------------------- 安装 / 卸载
function Get-GuiReadyRuntimeInstalledVersion {
    # 某个语言下已经装好的版本目录（不含 current）
    param([Parameter(Mandatory = $true)][string]$Id)
    $dir = Get-GuiReadyRuntimeLangDir $Id
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $dir) {
        foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($d.Name -ieq 'current') { continue }
            if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            [void]$list.Add($d.Name)
        }
    }
    return @($list | Sort-Object -Property { Get-GuiReadyRuntimeSortKey $_ } -Descending)
}

function Get-GuiReadyRuntimeCurrentVersion {
    param([Parameter(Mandatory = $true)][string]$Id)
    $link = Get-GuiReadyRuntimeCurrentLink $Id
    if (-not (Test-Path -LiteralPath $link)) { return '' }
    $target = Get-GuiReadyRuntimeLinkTarget -Link $link
    if ($target) { return (Split-Path -Leaf $target.TrimEnd('\')) }
    return ''
}

function Get-GuiReadyRuntimeVersionMeta {
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)][string]$Version)
    foreach ($v in @($Entry.Versions)) {
        if ([string]$v.Version -eq $Version) { return $v }
    }
    return $null
}

function Get-GuiReadyRuntimeVersionUrl {
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)][string]$Version)
    $m = Get-GuiReadyRuntimeVersionMeta -Entry $Entry -Version $Version
    if ($m) { return [string]$m.Url }
    return ''
}

function Invoke-GuiReadyRuntimeExe {
    param([string]$ExePath, [string]$Arguments = '--version', [int]$TimeoutMs = 8000)
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { return '' }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ExePath
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return ''
        }
        $out = ''
        try { $out = $p.StandardOutput.ReadToEnd() } catch { }
        if (-not $out) { try { $out = $p.StandardError.ReadToEnd() } catch { } }
        $line = @($out -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
        if ($line.Count -eq 0) { return '' }
        return $line[0].Trim()
    } catch {
        return ''
    }
}

function Get-GuiReadyRuntimeDetected {
    # 本工具装的（current）优先，其次系统 PATH 里已有的
    param([Parameter(Mandatory = $true)]$Entry)
    $exe = [string]$Entry.Exe
    $sub = [string]$Entry.PathSub
    $cur = Get-GuiReadyRuntimeCurrentLink ([string]$Entry.Id)
    $cand = if ($sub) { Join-Path $cur $sub } else { $cur }
    $probePath = Join-Path $cand $exe
    if (Test-Path -LiteralPath $probePath) {
        return (Invoke-GuiReadyRuntimeExe -ExePath $probePath -Arguments ([string]$Entry.Probe))
    }
    $cmd = Get-Command $exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return (Invoke-GuiReadyRuntimeExe -ExePath $cmd.Source -Arguments ([string]$Entry.Probe))
    }
    return ''
}

function Test-GuiReadyRuntimeOnPath {
    param([Parameter(Mandatory = $true)]$Entry)
    $want = (Get-GuiReadyRuntimePathEntry -Entry $Entry).TrimEnd('\')
    $machine = [string][Environment]::GetEnvironmentVariable('Path', 'Machine')
    foreach ($p in ($machine -split ';')) {
        if ($p.Trim().TrimEnd('\') -ieq $want) { return $true }
    }
    return $false
}

function Save-GuiReadyRuntimeFile {
    # 依次尝试：国内镜像 → 官方地址。任一成功即返回实际用的 URL。
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string[]]$Mirrors = @(),
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $curl = 'curl.exe'
    if (Get-Command Get-GuiReadyCurlPath -ErrorAction SilentlyContinue) { $curl = Get-GuiReadyCurlPath }

    $list = @()
    foreach ($m in @($Mirrors)) { if ($m) { $list += [string]$m } }
    if ($Url) { $list += $Url }

    $last = ''
    foreach ($raw in $list) {
        $uri = $raw
        if (Get-Command Get-GuiReadyDownloadUrl -ErrorAction SilentlyContinue) {
            try { $uri = Get-GuiReadyDownloadUrl -Url $raw } catch { $uri = $raw }
        }
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        Write-Log ('下载 {0}' -f $uri) 'STEP'
        $start = Get-Date
        & $curl -L --ssl-no-revoke --fail --retry 1 --retry-delay 2 --connect-timeout 20 --max-time 1800 -sS -o $OutFile $uri
        $code = $LASTEXITCODE
        if ($code -eq 0 -and (Test-Path -LiteralPath $OutFile)) {
            $len = (Get-Item -LiteralPath $OutFile).Length
            if ($len -ge 1024) {
                Write-Log ('下载完成 {0:N1} MB，用时 {1:N1} 秒' -f ($len / 1MB), ((Get-Date) - $start).TotalSeconds) 'OK'
                return $uri
            }
            $last = ('文件只有 {0} 字节' -f $len)
        } else {
            $last = ('curl 退出码 {0}' -f $code)
        }
        Write-Log ('这个源不可用（{0}），换下一个' -f $last) 'WARN'
    }
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    throw ('下载失败：{0}' -f $last)
}

function Expand-GuiReadyRuntimeZip {
    param([Parameter(Mandatory = $true)][string]$ZipPath, [Parameter(Mandatory = $true)][string]$TargetDir)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch { }

    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('scm-rt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $stage)
        $topDirs  = @(Get-ChildItem -LiteralPath $stage -Directory -Force)
        $topFiles = @(Get-ChildItem -LiteralPath $stage -File -Force)
        $src = $stage
        # 官方包基本都是一个顶层目录（node-v22.11.0-win-x64、jdk-21.0.5+11、go…），
        # 把里面的东西直接摊到版本目录，后面 PATH 才好写。
        if ($topDirs.Count -eq 1 -and $topFiles.Count -eq 0) { $src = $topDirs[0].FullName }

        if (-not (Test-Path -LiteralPath $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
        foreach ($c in (Get-ChildItem -LiteralPath $src -Force)) {
            $dest = Join-Path $TargetDir $c.Name
            if ($c.PSIsContainer) { [System.IO.Directory]::Move($c.FullName, $dest) }
            else { [System.IO.File]::Move($c.FullName, $dest) }
        }
    } finally {
        try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Enable-GuiReadyRuntimePythonSite {
    # embed 版默认不加载 site-packages（pythonXY._pth 里 #import site 是注释），
    # 不打开的话 pip 装的东西永远 import 不到。
    param([Parameter(Mandatory = $true)][string]$Dir)
    $pth = @(Get-ChildItem -LiteralPath $Dir -Filter 'python*._pth' -File -Force -ErrorAction SilentlyContinue)
    if ($pth.Count -eq 0) { return }
    foreach ($f in $pth) {
        try {
            $txt = [System.IO.File]::ReadAllText($f.FullName)
            $new = $txt -replace '(?m)^\s*#\s*import site\s*$', 'import site'
            if ($new -ne $txt) {
                [System.IO.File]::WriteAllText($f.FullName, $new, (New-Object System.Text.UTF8Encoding($false)))
                Write-Log ('已启用 site-packages：' + $f.Name) 'INFO'
            }
        } catch {
            Write-Log ('改写 ' + $f.Name + ' 失败: ' + $_.Exception.Message) 'WARN'
        }
    }
}

function Update-GuiReadyRuntimePath {
    # 把机器 PATH 里属于运行库根目录的条目全部重算：
    # 去掉失效的，按「有 current 链接的语言」补上。返回改动摘要。
    $root = (Get-GuiReadyRuntimeRoot).TrimEnd('\')
    $prefix = $root + '\'
    $machine = [string][Environment]::GetEnvironmentVariable('Path', 'Machine')

    $keep = New-Object System.Collections.ArrayList
    $removed = New-Object System.Collections.ArrayList
    foreach ($p in ($machine -split ';')) {
        $t = $p.Trim()
        if (-not $t) { continue }
        if ($t.TrimEnd('\') -ieq $root -or $t.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$removed.Add($t)
            continue
        }
        [void]$keep.Add($t)
    }

    $added = New-Object System.Collections.ArrayList
    foreach ($e in (Get-GuiReadyRuntimeCatalog)) {
        $entry = Get-GuiReadyRuntimePathEntry -Entry $e
        if (Test-Path -LiteralPath $entry) { [void]$added.Add($entry) }
    }

    $seen = @{}
    $all = New-Object System.Collections.ArrayList
    foreach ($p in (@($keep) + @($added))) {
        $k = $p.Trim().TrimEnd('\').ToLowerInvariant()
        if ($k -and -not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$all.Add($p.Trim()) }
    }

    $new = ($all -join ';')
    $changed = ($new -ne $machine)
    $o = [pscustomobject]@{
        Changed = $changed
        Added   = @($added)
        Removed = @($removed)
        Machine = $new
        Error   = ''
    }
    if (-not $changed) { return $o }

    try {
        [Environment]::SetEnvironmentVariable('Path', $new, 'Machine')
    } catch {
        $o.Error = $_.Exception.Message
        $o.Changed = $false
        Write-Log ('写机器 PATH 失败（需要管理员）：' + $_.Exception.Message) 'WARN'
        return $o
    }

    # 当前进程也同步一份，装完马上探测版本 / 跑命令就能用
    $proc = [string][Environment]::GetEnvironmentVariable('Path', 'Process')
    $procKeep = New-Object System.Collections.ArrayList
    foreach ($p in ($proc -split ';')) {
        $t = $p.Trim()
        if (-not $t) { continue }
        if ($t.TrimEnd('\') -ieq $root -or $t.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        [void]$procKeep.Add($t)
    }
    $procAll = @($procKeep) + @($added)
    try { $env:Path = ($procAll -join ';') } catch { }
    return $o
}

function Install-GuiReadyRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$Url = '',
        [switch]$DryRun
    )
    $e = Get-GuiReadyRuntimeEntry -Id $Id
    if (-not $e) { throw ('未知运行时：' + $Id) }
    if (-not $Url) { $Url = Get-GuiReadyRuntimeVersionUrl -Entry $e -Version $Version }
    if (-not $Url) { throw ('清单里没有 {0} {1} 的下载地址；可手动用 -Url 指定。' -f $e.Name, $Version) }

    $target = Get-GuiReadyRuntimeVersionDir -Id $Id -Version $Version
    $already = Test-Path -LiteralPath $target
    if ($already) {
        Write-Log ('{0} {1} 已存在，跳过下载；如需重装先卸载。' -f $e.Name, $Version) 'WARN'
    } else {
        if ($DryRun) {
            Write-Log ('[试运行] 将下载 {0} {1}：{2}' -f $e.Name, $Version, $Url) 'DRY'
            Write-Log ('[试运行] 解压到 {0}' -f $target) 'DRY'
            return [pscustomobject]@{ Id = $Id; Version = $Version; Installed = $false; DryRun = $true; Url = $Url }
        }
        $zip = Join-Path (Join-Path ([System.IO.Path]::GetTempPath()) 'scm-runtime') ('{0}-{1}.zip' -f $Id, $Version)
        $meta = Get-GuiReadyRuntimeVersionMeta -Entry $e -Version $Version
        $mirrors = @()
        if ($meta -and $meta.Mirrors) { $mirrors = @($meta.Mirrors) }
        Save-GuiReadyRuntimeFile -Url $Url -Mirrors $mirrors -OutFile $zip
        Write-Log ('解压到 {0}' -f $target) 'STEP'
        Expand-GuiReadyRuntimeZip -ZipPath $zip -TargetDir $target
        try { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } catch { }

        if ($Id -eq 'python') { Enable-GuiReadyRuntimePythonSite -Dir $target }
    }

    $cur = Get-GuiReadyRuntimeCurrentVersion -Id $Id
    if (-not $cur) {
        New-GuiReadyRuntimeLink -Link (Get-GuiReadyRuntimeCurrentLink $Id) -Target $target
        Write-Log ('已把 {0} current 指向 {1}' -f $e.Name, $Version) 'OK'
    }
    $p = Update-GuiReadyRuntimePath
    if ($p.Changed) { Write-Log '已更新机器 PATH（新开的命令行才生效）' 'OK' }

    $sub = [string]$e.PathSub
    $exe = Join-Path (Join-Path (Get-GuiReadyRuntimeCurrentLink $Id) $sub) ([string]$e.Exe)
    $ver = Invoke-GuiReadyRuntimeExe -ExePath $exe -Arguments ([string]$e.Probe)
    if ($ver) { Write-Log ('版本探测：' + $ver) 'OK' }
    else { Write-Log ('装好了，但探测版本失败：' + $exe) 'WARN' }

    return [pscustomobject]@{
        Id = $Id; Version = $Version; Installed = $true; DryRun = $false
        Current = (Get-GuiReadyRuntimeCurrentVersion $Id); Detected = $ver
        PathChanged = [bool]$p.Changed; PathError = [string]$p.Error
    }
}

function Set-GuiReadyRuntimeCurrent {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Version
    )
    $e = Get-GuiReadyRuntimeEntry -Id $Id
    if (-not $e) { throw ('未知运行时：' + $Id) }
    $target = Get-GuiReadyRuntimeVersionDir -Id $Id -Version $Version
    if (-not (Test-Path -LiteralPath $target)) { throw ('还没装 {0} {1}' -f $e.Name, $Version) }

    New-GuiReadyRuntimeLink -Link (Get-GuiReadyRuntimeCurrentLink $Id) -Target $target
    Write-Log ('{0} current -> {1}' -f $e.Name, $Version) 'OK'
    $p = Update-GuiReadyRuntimePath
    if ($p.Changed) { Write-Log '已更新机器 PATH（新开的命令行才生效）' 'OK' }

    $sub = [string]$e.PathSub
    $exe = Join-Path (Join-Path (Get-GuiReadyRuntimeCurrentLink $Id) $sub) ([string]$e.Exe)
    $ver = Invoke-GuiReadyRuntimeExe -ExePath $exe -Arguments ([string]$e.Probe)
    if ($ver) { Write-Log ('版本探测：' + $ver) 'OK' }
    return [pscustomobject]@{
        Id = $Id; Version = $Version; Current = $Version; Detected = $ver
        PathChanged = [bool]$p.Changed; PathError = [string]$p.Error
    }
}

function Uninstall-GuiReadyRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Version = '',
        [switch]$DryRun
    )
    $e = Get-GuiReadyRuntimeEntry -Id $Id
    if (-not $e) { throw ('未知运行时：' + $Id) }
    $installed = Get-GuiReadyRuntimeInstalledVersion -Id $Id
    if ($installed.Count -eq 0) { throw ('{0} 没有装任何版本' -f $e.Name) }
    if (-not $Version) { $Version = Get-GuiReadyRuntimeCurrentVersion -Id $Id }
    if (-not $Version) { $Version = $installed[0] }

    $cur = Get-GuiReadyRuntimeCurrentVersion -Id $Id
    if ($DryRun) {
        Write-Log ('[试运行] 将卸载 {0} {1}' -f $e.Name, $Version) 'DRY'
        return [pscustomobject]@{ Id = $Id; Version = $Version; Removed = $false; DryRun = $true }
    }

    if ($cur -and $cur -ieq $Version) {
        Remove-GuiReadyRuntimeLink -Link (Get-GuiReadyRuntimeCurrentLink $Id)
        Write-Log ('已摘掉 current 链接（原指向 {0}）' -f $cur) 'INFO'
    }
    $dir = Get-GuiReadyRuntimeVersionDir -Id $Id -Version $Version
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
        Write-Log ('已删除 {0}' -f $dir) 'OK'
    }

    # 还有别的版本时，把 current 顺手指到最新的那个；一个都不剩就清 PATH
    $left = Get-GuiReadyRuntimeInstalledVersion -Id $Id
    if ($left.Count -gt 0) {
        New-GuiReadyRuntimeLink -Link (Get-GuiReadyRuntimeCurrentLink $Id) -Target (Get-GuiReadyRuntimeVersionDir -Id $Id -Version $left[0])
        Write-Log ('current 改指向 {0}' -f $left[0]) 'INFO'
    }
    $p = Update-GuiReadyRuntimePath
    if ($p.Changed) { Write-Log '已更新机器 PATH（新开的命令行才生效）' 'OK' }

    return [pscustomobject]@{
        Id = $Id; Version = $Version; Removed = $true
        Current = (Get-GuiReadyRuntimeCurrentVersion $Id); Left = @($left)
        PathChanged = [bool]$p.Changed; PathError = [string]$p.Error
    }
}

# ---------------------------------------------------------------- 状态
function Get-GuiReadyRuntimeStatus {
    param([switch]$DeepProbe)

    $root = Get-GuiReadyRuntimeRoot
    $items = New-Object System.Collections.ArrayList
    foreach ($e in (Get-GuiReadyRuntimeCatalog)) {
        $installed = @(Get-GuiReadyRuntimeInstalledVersion -Id $e.Id)
        $current   = Get-GuiReadyRuntimeCurrentVersion -Id $e.Id
        $onPath    = Test-GuiReadyRuntimeOnPath -Entry $e
        $detected  = Get-GuiReadyRuntimeDetected -Entry $e

        $versions = New-Object System.Collections.ArrayList
        foreach ($v in @($e.Versions)) {
            $probe = ''
            if ($DeepProbe) {
                $code = 0
                try {
                    $curl = 'curl.exe'
                    if (Get-Command Get-GuiReadyCurlPath -ErrorAction SilentlyContinue) { $curl = Get-GuiReadyCurlPath }
                    $uri = [string]$v.Url
                    if (Get-Command Get-GuiReadyDownloadUrl -ErrorAction SilentlyContinue) { $uri = Get-GuiReadyDownloadUrl -Url $uri }
                    $raw = & $curl -sIL --ssl-no-revoke --max-time 20 -o NUL -w '%{http_code}' $uri 2>$null
                    $code = [int]$raw
                } catch { $code = 0 }
                $probe = if ($code -ge 200 -and $code -lt 300) { 'ok' } else { ('http ' + $code) }
            }
            [void]$versions.Add([pscustomobject]@{
                Version     = [string]$v.Version
                Url         = [string]$v.Url
                Size        = [string]$v.Size
                Installed   = ($installed -contains [string]$v.Version)
                Current     = ($current -eq [string]$v.Version)
                Probe       = $probe
            })
        }
        # 清单之外的本地版本（手工拷进来的）也要列出来
        foreach ($v in $installed) {
            $known = $false
            foreach ($k in $versions) { if ($k.Version -eq $v) { $known = $true; break } }
            if ($known) { continue }
            [void]$versions.Add([pscustomobject]@{
                Version = [string]$v; Url = ''; Size = ''; Installed = $true; Current = ($current -eq $v); Probe = ''
            })
        }

        [void]$items.Add([pscustomobject]@{
            Id        = $e.Id
            Name      = $e.Name
            Category  = $e.Category
            Exe       = $e.Exe
            PathSub   = $e.PathSub
            Note      = $e.Note
            Root      = (Get-GuiReadyRuntimeLangDir $e.Id)
            Installed = @($installed)
            Current   = $current
            OnPath    = $onPath
            Detected  = $detected
            Versions  = @($versions)
        })
    }

    return [pscustomobject]@{
        Root      = $root
        Exists    = (Test-Path -LiteralPath $root)
        DeepProbe = [bool]$DeepProbe
        Items     = @($items)
    }
}

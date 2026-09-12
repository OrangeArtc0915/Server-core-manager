# GuiReady dotnet: detect required .NET runtime and deploy it without an installer

$Global:GuiReadyDotNetRoot = 'C:\Program Files\dotnet'
$Global:GuiReadyDotNetMeta = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/{0}/releases.json'

$Global:GuiReadyDotNetSection = @{
    'Microsoft.NETCore.App'        = 'runtime'
    'Microsoft.AspNetCore.App'     = 'aspnetcore-runtime'
    'Microsoft.WindowsDesktop.App' = 'windowsdesktop'
}

function Get-GuiReadyDotNetStatus {
    $o = [ordered]@{
        Root      = $Global:GuiReadyDotNetRoot
        RootExists= (Test-Path -LiteralPath $Global:GuiReadyDotNetRoot)
        DotNetExe = (Test-Path -LiteralPath (Join-Path $Global:GuiReadyDotNetRoot 'dotnet.exe'))
        Frameworks= @()
        ListOutput= ''
        InPath    = $false
        DotNetRoot= [string]$env:DOTNET_ROOT
        RegistryInstallLocation = [string](Get-RegValue 'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64' 'InstallLocation')
    }

    try {
        $cmd = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        if ($cmd) { $o.InPath = $true }
    } catch { }

    $shared = Join-Path $Global:GuiReadyDotNetRoot 'shared'
    if (Test-Path -LiteralPath $shared) {
        foreach ($fw in (Get-ChildItem -LiteralPath $shared -Directory -ErrorAction SilentlyContinue)) {
            foreach ($ver in (Get-ChildItem -LiteralPath $fw.FullName -Directory -ErrorAction SilentlyContinue)) {
                $o.Frameworks += [pscustomobject]@{
                    Name    = $fw.Name
                    Version = $ver.Name
                    Major   = [int](($ver.Name -split '\.')[0])
                }
            }
        }
    }

    if ($o.DotNetExe) {
        try { $o.ListOutput = ((& (Join-Path $Global:GuiReadyDotNetRoot 'dotnet.exe') --list-runtimes 2>&1) | Out-String).Trim() } catch { }
    }
    return [pscustomobject]$o
}

function Get-GuiReadyRequiredRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [int]$ScanMegabytes = 64
    )

    $o = [ordered]@{ Ok = $false; Frameworks = @(); Note = ''; ScannedBytes = 0 }
    $fi = Get-Item -LiteralPath $ExePath -ErrorAction SilentlyContinue
    if (-not $fi) { $o.Note = '文件不存在'; return [pscustomobject]$o }

    # Single-file .NET apps embed runtimeconfig.json; scan head and tail of the file for it.
    $limit = $ScanMegabytes * 1MB
    $text = ''
    try {
        $fs = [System.IO.File]::OpenRead($ExePath)
        try {
            $len = $fs.Length
            $buf = New-Object byte[] ([Math]::Min($limit, $len))
            $n = $fs.Read($buf, 0, $buf.Length)
            $text += [System.Text.Encoding]::GetEncoding(28591).GetString($buf, 0, $n)
            $o.ScannedBytes = $n
            if ($len -gt $limit) {
                $fs.Position = [Math]::Max(0, $len - $limit)
                $buf2 = New-Object byte[] ([Math]::Min($limit, $len))
                $n2 = $fs.Read($buf2, 0, $buf2.Length)
                $text += [System.Text.Encoding]::GetEncoding(28591).GetString($buf2, 0, $n2)
                $o.ScannedBytes += $n2
            }
        } finally { $fs.Dispose() }
    } catch {
        $o.Note = '读取失败: ' + $_.Exception.Message
        return [pscustomobject]$o
    }

    $re = [regex]'"name"\s*:\s*"([^"]+)"\s*,\s*"version"\s*:\s*"([^"]+)"'
    $seen = @{}
    foreach ($m in $re.Matches($text)) {
        $nm  = $m.Groups[1].Value
        $ver = $m.Groups[2].Value
        if (-not $Global:GuiReadyDotNetSection.ContainsKey($nm)) { continue }
        if ($seen.ContainsKey($nm)) { continue }
        $seen[$nm] = $true
        $o.Frameworks += [pscustomobject]@{
            Name    = $nm
            Version = $ver
            Major   = [int](($ver -split '\.')[0])
            Section = $Global:GuiReadyDotNetSection[$nm]
        }
    }

    if ($o.Frameworks.Count -gt 0) {
        $o.Ok = $true
        $o.Note = ('从 exe 内嵌的 runtimeconfig 里识别到 {0} 个框架需求' -f $o.Frameworks.Count)
    } else {
        $o.Note = '未能从 exe 里识别 .NET 框架需求（可能不是 .NET 程序、是自包含发布、或 runtimeconfig 被压缩）。若确认是 .NET 程序，请手动指定版本。'
    }
    return [pscustomobject]$o
}

function Get-GuiReadyDotNetReleaseInfo {
    param(
        [Parameter(Mandatory = $true)][string]$MajorMinor,
        [Parameter(Mandatory = $true)][string]$Section,
        [string]$Rid = 'win-x64'
    )

    $o = [ordered]@{ Ok = $false; Version = ''; Url = ''; FileName = ''; Note = '' }
    $url = $Global:GuiReadyDotNetMeta -f $MajorMinor
    try {
        $meta = Invoke-RestMethod -Uri $url -TimeoutSec 60 -ErrorAction Stop
    } catch {
        $o.Note = '获取发布元数据失败: ' + $_.Exception.Message
        return [pscustomobject]$o
    }

    if (-not $meta.releases -or $meta.releases.Count -eq 0) {
        $o.Note = ('元数据里没有 {0} 的发布记录' -f $MajorMinor)
        return [pscustomobject]$o
    }

    $rel = $meta.releases[0]
    $o.Version = [string]$rel.'release-version'

    $node = $rel.$Section
    if (-not $node) {
        $keys = @($rel | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name })
        $o.Note = ('元数据里没有 "{0}" 段。可用段: {1}' -f $Section, ($keys -join ', '))
        return [pscustomobject]$o
    }

    $files = @($node.files | Where-Object { $_.rid -eq $Rid -and $_.name -like '*.zip' -and $_.name -notlike '*apphost*' })
    if ($files.Count -eq 0) {
        $o.Note = ('{0} 段里没有 {1} 的 zip 包' -f $Section, $Rid)
        return [pscustomobject]$o
    }

    $pick = $files[0]
    $pref = @($files | Where-Object { $_.name -match ('^' + ($Section -replace '-runtime$','') + '-runtime-') })
    if ($pref.Count -gt 0) { $pick = $pref[0] }

    $o.Ok       = $true
    $o.Url      = [string]$pick.url
    $o.FileName = [string]$pick.name
    $o.Note     = ('{0} 最新补丁版本 {1}，包名 {2}' -f $MajorMinor, $o.Version, $o.FileName)
    return [pscustomobject]$o
}

function Expand-GuiReadyZipOverwrite {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$TargetDir
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $n = 0
    try {
        foreach ($e in $zip.Entries) {
            if ([string]::IsNullOrEmpty($e.Name)) { continue }
            $dest = Join-Path $TargetDir ($e.FullName -replace '/', '\')
            $dir  = Split-Path $dest -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
            $n++
        }
    } finally { $zip.Dispose() }
    return $n
}

function Install-GuiReadyDotNetRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Framework,
        [Parameter(Mandatory = $true)][string]$MajorMinor,
        [string]$TargetDir = '',
        [string]$DownloadDir = '',
        [switch]$WhatIf
    )

    Write-Head ('部署 .NET 运行时: {0} {1}' -f $Framework, $MajorMinor)

    if (-not (Assert-Administrator)) { return $null }

    if (-not $Global:GuiReadyDotNetSection.ContainsKey($Framework)) {
        Write-Log ('不支持的框架名: {0}。可选: {1}' -f $Framework, (($Global:GuiReadyDotNetSection.Keys) -join ', ')) 'ERROR'
        return $null
    }
    $section = $Global:GuiReadyDotNetSection[$Framework]

    if ([string]::IsNullOrWhiteSpace($TargetDir)) { $TargetDir = $Global:GuiReadyDotNetRoot }
    if ([string]::IsNullOrWhiteSpace($DownloadDir)) {
        $DownloadDir = Join-Path $script:LogDir 'dotnet'
        if (-not (Test-Path -LiteralPath $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null }
    }

    if ($Framework -eq 'Microsoft.WindowsDesktop.App') {
        Write-Log '注意：Windows Desktop Runtime 不支持 Server Core（它需要完整桌面体验）。本项一般无法部署成功。' 'WARN'
    }

    $info = Get-GuiReadyDotNetReleaseInfo -MajorMinor $MajorMinor -Section $section
    Write-Log $info.Note $(if ($info.Ok) { 'INFO' } else { 'ERROR' })
    if (-not $info.Ok) { return $null }

    $zip = Join-Path $DownloadDir $info.FileName

    if ($WhatIf) {
        Write-Log ('将下载 {0}' -f $info.Url) 'DRY'
        Write-Log ('将解包到 {0}' -f $TargetDir) 'DRY'
        return [pscustomobject]@{ Ok = $true; Version = $info.Version; Zip = $zip; Target = $TargetDir }
    }

    if (-not (Test-Path -LiteralPath $zip)) {
        Write-Log ('下载 {0} ...' -f $info.FileName) 'STEP'
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $old = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $info.Url -OutFile $zip -TimeoutSec 1800 -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = $old
            $sw.Stop()
            Write-Log ('下载完成 {0:N1} MB，用时 {1:N1} 秒' -f ((Get-Item -LiteralPath $zip).Length / 1MB), $sw.Elapsed.TotalSeconds) 'OK'
        } catch {
            Write-Log ('下载失败: ' + $_.Exception.Message) 'ERROR'
            return $null
        }
    } else {
        Write-Log ('已有缓存包: ' + $zip) 'INFO'
    }

    Write-Log ('解包到 {0}' -f $TargetDir) 'STEP'
    try {
        $n = Expand-GuiReadyZipOverwrite -ZipPath $zip -TargetDir $TargetDir
        Write-Log ('解出 {0} 个文件' -f $n) 'OK'
    } catch {
        Write-Log ('解包失败: ' + $_.Exception.Message) 'ERROR'
        return $null
    }

    $st = Get-GuiReadyDotNetStatus
    $hit = @($st.Frameworks | Where-Object { $_.Name -eq $Framework } | Sort-Object Version -Descending)
    if ($hit.Count -gt 0) {
        Write-Log ('当前已装 {0}: {1}' -f $Framework, (($hit | ForEach-Object { $_.Version }) -join ', ')) 'OK'
    } else {
        Write-Log ('解包完成，但未在 {0} 下看到 {1}，请检查包内容' -f $TargetDir, $Framework) 'WARN'
    }
    if ($st.DotNetExe) {
        Write-Log ('dotnet.exe --list-runtimes:' ) 'INFO'
        foreach ($l in ($st.ListOutput -split "`r?`n")) { if ($l.Trim()) { Write-Log ('  ' + $l) 'INFO' } }
    }

    return [pscustomobject]@{ Ok = $true; Version = $info.Version; Zip = $zip; Target = $TargetDir; FileCount = $n }
}

function Invoke-GuiReadyDotNetFix {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [switch]$WhatIf
    )

    Write-Head '按程序需求补齐 .NET 运行时'

    $req = Get-GuiReadyRequiredRuntime -ExePath $ExePath
    Write-Log ('目标程序: ' + $ExePath) 'INFO'
    Write-Log ('识别结果: ' + $req.Note) 'INFO'

    $st = Get-GuiReadyDotNetStatus
    Write-Log ('dotnet 根目录: {0}（存在={1}）' -f $st.Root, $st.RootExists) 'INFO'
    if ($st.Frameworks.Count -gt 0) {
        foreach ($f in ($st.Frameworks | Sort-Object Name, Version)) {
            Write-Log ('  已装 {0} {1}' -f $f.Name, $f.Version) 'INFO'
        }
    } else {
        Write-Log '  当前没有检测到任何已装的 .NET 运行时' 'WARN'
    }

    if (-not $req.Ok) {
        Write-Log '无法自动识别需要的版本。请用 -Framework / -MajorMinor 手动指定，例如:' 'WARN'
        Write-Log '  Install-GuiReadyDotNetRuntime -Framework Microsoft.AspNetCore.App -MajorMinor 10.0' 'WARN'
        return
    }

    $todo = New-Object System.Collections.ArrayList
    foreach ($need in $req.Frameworks) {
        $installed = @($st.Frameworks | Where-Object { $_.Name -eq $need.Name -and $_.Major -ge $need.Major })
        if ($installed.Count -eq 0) {
            Write-Log ('缺少 {0}（程序需要 {1}）' -f $need.Name, $need.Version) 'WARN'
            [void]$todo.Add([pscustomobject]@{ Name = $need.Name; Major = $need.Major; Section = $need.Section })
        } else {
            Write-Log ('已满足 {0}（程序需要 {1}，本机有 {2}）' -f $need.Name, $need.Version, (($installed | ForEach-Object { $_.Version }) -join ', ')) 'OK'
        }
    }

    if ($todo.Count -eq 0) {
        Write-Log '所有 .NET 依赖都已满足，无需部署。' 'OK'
        return
    }

    if ($todo | Where-Object { $_.Name -eq 'Microsoft.AspNetCore.App' }) {
        Write-Log '提示：部署 ASP.NET Core Runtime 会同时提供 Microsoft.NETCore.App。' 'INFO'
    }

    $done = New-Object System.Collections.ArrayList
    foreach ($t in $todo) {
        if ($t.Name -eq 'Microsoft.NETCore.App') {
            $already = @($done | Where-Object { $_ -eq 'Microsoft.AspNetCore.App' })
            if ($already.Count -gt 0) {
                Write-Log 'Microsoft.NETCore.App 已随 ASP.NET Core Runtime 一起提供，跳过。' 'INFO'
                continue
            }
        }
        $mm = ('{0}.{1}' -f $t.Major, 0)
        $r = Install-GuiReadyDotNetRuntime -Framework $t.Name -MajorMinor $mm -WhatIf:$WhatIf
        if ($r -and $r.Ok) { [void]$done.Add($t.Name) }
    }

    Write-Log ('完成，处理了 {0} 项' -f $done.Count) 'OK'
}

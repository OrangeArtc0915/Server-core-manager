# GuiReady 文件管理：目录浏览、文本读写、复制/移动/删除、ZIP 压缩解压。
#
# 设计原则：
#   1. 所有路径先规范化（绝对路径、消除 ..），再按操作类型过安全守卫；
#   2. 所有写操作支持 -WhatIf，动作层再由 GUI 的 DryRun 兜一层；
#   3. 不依赖第三方组件，压缩只用 .NET Framework 自带的 System.IO.Compression；
#   4. 不接受相对路径 —— 当前工作目录在服务/计划任务里不可预测，相对路径等于隐式风险。

$script:FilesToolRoot = Split-Path -Parent $PSScriptRoot

function ConvertTo-GuiReadyFilePath {
    # 规范化用户输入的路径：展开环境变量、拒绝相对路径、消除 .. 和末尾分隔符。
    # 只做字符串处理，不要求路径存在（存在性由各调用方按需检查）。
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path
    )

    $p = $Path
    if ($null -eq $p) { throw '路径不能为空。' }
    $p = $p.Trim()
    if (-not $p) { throw '路径不能为空。' }

    try { $p = [Environment]::ExpandEnvironmentVariables($p) } catch { }

    # 文件名/路径里不可能出现的字符：控制字符、< > " | 以及通配符。
    # 过滤通配符是有意的：这里的路径一律当字面量处理，* 和 ? 交给 -Filter。
    if ($p -match '[\x00-\x1F<>"|*?]') {
        throw ('路径包含非法字符：' + $p)
    }

    # C: 这种"盘符相对路径"也是 IsPathRooted=true，但含义依赖当前目录，必须拒绝。
    if ($p -match '^[A-Za-z]:(?![\\/])') {
        throw ('请给出完整路径（例如 C:\Windows），不要用盘符相对路径：' + $p)
    }
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        throw ('请使用绝对路径（例如 C:\Windows）：' + $p)
    }

    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($p) } catch {
        throw ('路径无法解析：' + $_.Exception.Message)
    }

    # 盘符根保留 `C:\`，其他路径去掉末尾分隔符，避免同一个目录出现两种写法。
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length -and ($full.EndsWith('\') -or $full.EndsWith('/'))) {
        $full = $full.Substring(0, $full.Length - 1)
    }
    return $full
}

function Assert-GuiReadyPathGuard {
    # 按操作类型做安全守卫，返回规范化后的完整路径。
    # Read   ：只要求路径合法；
    # Write  ：额外要求上级目录已存在（防止误写到拼错的盘符/共享）；
    # Delete / Rename：拒绝盘符根与系统关键根目录本身。
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Read', 'Write', 'Delete', 'Rename')][string]$Operation = 'Read'
    )

    $full = ConvertTo-GuiReadyFilePath -Path $Path
    $root = [System.IO.Path]::GetPathRoot($full)

    if ($full -eq $root -and $Operation -ne 'Read') {
        throw ('不允许对盘符根执行 {0} 操作：{1}' -f $Operation, $full)
    }

    if ($Operation -eq 'Delete' -or $Operation -eq 'Rename') {
        # 只拦"根目录本身"，子目录仍可操作 —— 否则连 C:\Windows\Temp 都删不了，
        # 运维场景下这种限制没有意义。盘符根已在上面永久禁止。
        $protected = @()
        foreach ($x in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $script:FilesToolRoot)) {
            if ([string]::IsNullOrWhiteSpace($x)) { continue }
            try { $protected += (ConvertTo-GuiReadyFilePath -Path $x).TrimEnd('\') } catch { }
        }
        $cmp = $full.TrimEnd('\')
        foreach ($x in $protected) {
            if ($cmp -eq $x) {
                throw ('这是受保护的系统目录，不允许 {0}：{1}' -f $Operation, $full)
            }
        }
    }

    if ($Operation -eq 'Write') {
        $parent = [System.IO.Path]::GetDirectoryName($full)
        if (-not $parent) { throw ('无法确定上级目录：' + $full) }
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw ('上级目录不存在：' + $parent)
        }
    }

    return $full
}

function Format-GuiReadyByteSize {
    # 统一的体积显示。目录不计算体积（递归统计会把大目录的列举拖垮）。
    param([long]$Bytes)

    if ($Bytes -lt 1024) { return ('{0} B' -f $Bytes) }
    if ($Bytes -lt 1048576) { return ('{0:0.0} KB' -f ($Bytes / 1024.0)) }
    if ($Bytes -lt 1073741824) { return ('{0:0.0} MB' -f ($Bytes / 1048576.0)) }
    return ('{0:0.0} GB' -f ($Bytes / 1073741824.0))
}

function Get-GuiReadyAttributeText {
    # 用字母标记属性，和资源管理器一致（R/H/S/A/D/L）。
    param([System.IO.FileAttributes]$Attributes)

    $s = ''
    if (($Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { $s += 'R' }
    if (($Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0) { $s += 'H' }
    if (($Attributes -band [System.IO.FileAttributes]::System) -ne 0) { $s += 'S' }
    if (($Attributes -band [System.IO.FileAttributes]::Archive) -ne 0) { $s += 'A' }
    if (($Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { $s += 'D' }
    if (($Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $s += 'L' }
    if (-not $s) { $s = '-' }
    return $s
}

function Get-GuiReadyFileList {
    # 列目录。目录在前、名称升序；最多返回 2000 项，超出标记 Truncated。
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$ShowHidden,
        [string]$Filter = '*'
    )

    $full = Assert-GuiReadyPathGuard -Path $Path -Operation 'Read'
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw ('目录不存在：' + $full)
    }

    $di = New-Object System.IO.DirectoryInfo($full)
    $entries = @($di.GetFileSystemInfos())
    if ($Filter -and $Filter -ne '*') {
        $entries = @($entries | Where-Object { $_.Name -like $Filter })
    }

    $list = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        $attr = $e.Attributes
        $isHidden = ((($attr -band [System.IO.FileAttributes]::Hidden) -ne 0) -or
                     (($attr -band [System.IO.FileAttributes]::System) -ne 0))
        if (-not $ShowHidden -and $isHidden) { continue }

        $isDir = ($e -is [System.IO.DirectoryInfo])
        $isLink = (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        $size = [long]0
        $sizeText = '—'
        if (-not $isDir) {
            $size = [long]$e.Length
            $sizeText = Format-GuiReadyByteSize -Bytes $size
        }

        $type = '文件'
        if ($isDir) {
            $type = '文件夹'
        } elseif ($isLink) {
            $type = '链接'
        } elseif ($e.Extension) {
            $type = $e.Extension.TrimStart('.').ToUpperInvariant() + ' 文件'
        }

        [void]$list.Add([pscustomobject]@{
            Name        = [string]$e.Name
            FullName    = [string]$e.FullName
            IsDir       = [bool]$isDir
            IsLink      = [bool]$isLink
            Size        = $size
            SizeText    = $sizeText
            Type        = $type
            Modified    = $e.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            Attributes  = (Get-GuiReadyAttributeText -Attributes $attr)
            Hidden      = [bool]$isHidden
        })
    }

    $sorted = @($list | Sort-Object @{ Expression = { if ($_.IsDir) { 0 } else { 1 } } },
                                      @{ Expression = { $_.Name.ToLowerInvariant() } })
    $total = $sorted.Count
    $truncated = $false
    if ($total -gt 2000) {
        $sorted = @($sorted | Select-Object -First 2000)
        $truncated = $true
    }

    return [pscustomobject]@{
        Path      = $full
        Parent    = [string]([System.IO.Path]::GetDirectoryName($full))
        Total     = $total
        Truncated = $truncated
        Items     = @($sorted)
    }
}

function Get-GuiReadyFilePathInfo {
    # 单个路径的信息。路径不存在时返回 Exists=false，不抛异常（预览区要用）。
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = ConvertTo-GuiReadyFilePath -Path $Path
    $exists = Test-Path -LiteralPath $full
    if (-not $exists) {
        return [pscustomobject]@{
            Exists = $false; FullName = $full; Parent = [string]([System.IO.Path]::GetDirectoryName($full))
            IsDir = $false; IsReparsePoint = $false; Size = [long]0; SizeText = ''
            Created = ''; Modified = ''; Accessed = ''; Attributes = ''; Owner = ''
        }
    }

    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    $isDir = ($item -is [System.IO.DirectoryInfo])
    $size = [long]0
    $sizeText = '—'
    if (-not $isDir) {
        $size = [long]$item.Length
        $sizeText = Format-GuiReadyByteSize -Bytes $size
    }
    $owner = ''
    try { $owner = [string](Get-Acl -LiteralPath $full -ErrorAction Stop).Owner } catch { }

    return [pscustomobject]@{
        Exists        = $true
        FullName      = [string]$full
        Parent        = [string]([System.IO.Path]::GetDirectoryName($full))
        IsDir         = [bool]$isDir
        IsReparsePoint = ((($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))
        Size          = $size
        SizeText      = $sizeText
        Created       = $item.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
        Modified      = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Accessed      = $item.LastAccessTime.ToString('yyyy-MM-dd HH:mm:ss')
        Attributes    = (Get-GuiReadyAttributeText -Attributes $item.Attributes)
        Owner         = $owner
    }
}

function Read-GuiReadyTextFile {
    # 读取文本预览。二进制（前 8KB 含 0x00）直接拒绝，避免把整个 exe 塞进 JSON。
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxKB = 256
    )

    $full = Assert-GuiReadyPathGuard -Path $Path -Operation 'Read'
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        if (Test-Path -LiteralPath $full -PathType Container) { throw '这是目录，不能按文本预览。' }
        throw ('文件不存在：' + $full)
    }

    if ($MaxKB -lt 1) { $MaxKB = 1 }
    if ($MaxKB -gt 4096) { $MaxKB = 4096 }

    $fi = New-Object System.IO.FileInfo($full)
    $size = [long]$fi.Length
    $fs = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $headLen = [int][Math]::Min(8192, $size)
        $head = New-Object byte[] $headLen
        $n = 0
        if ($headLen -gt 0) { $n = $fs.Read($head, 0, $headLen) }

        $binary = $false
        for ($i = 0; $i -lt $n; $i++) { if ($head[$i] -eq 0) { $binary = $true; break } }
        if ($binary) {
            return [pscustomobject]@{
                Path = $full; Text = ''; Binary = $true; Truncated = $false
                Size = $size; Encoding = '二进制'; Lines = 0
            }
        }

        $enc = $null
        $encName = 'UTF-8'
        if ($n -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
            $enc = New-Object System.Text.UTF8Encoding($true); $encName = 'UTF-8 (BOM)'
        } elseif ($n -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) {
            $enc = New-Object System.Text.UnicodeEncoding($false, $true); $encName = 'UTF-16 LE'
        } elseif ($n -ge 2 -and $head[0] -eq 0xFE -and $head[1] -eq 0xFF) {
            $enc = New-Object System.Text.UnicodeEncoding($true, $true); $encName = 'UTF-16 BE'
        } else {
            # 无 BOM：先按严格 UTF-8 解头部，失败就回退系统 ANSI（中文系统即 GBK）。
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            try {
                if ($n -gt 0) { [void]$strict.GetString($head, 0, $n) }
                $enc = New-Object System.Text.UTF8Encoding($false); $encName = 'UTF-8'
            } catch {
                $enc = [System.Text.Encoding]::Default; $encName = 'ANSI'
            }
        }

        $fs.Position = 0
        $reader = New-Object System.IO.StreamReader($fs, $enc, $true)
        try {
            $charLimit = [int64]$MaxKB * 1024
            if ($charLimit -gt [int]::MaxValue) { $charLimit = [int]::MaxValue }
            $buf = New-Object char[] ([int]$charLimit)
            $read = 0
            while ($read -lt $buf.Length) {
                $want = [Math]::Min(4096, $buf.Length - $read)
                $k = $reader.Read($buf, $read, $want)
                if ($k -le 0) { break }
                $read += $k
            }
            $truncated = ($reader.Peek() -ne -1)
        } finally { $reader.Dispose() }

        $text = New-Object string($buf, 0, $read)
        $lines = 1
        if ($text.Length -gt 0) { $lines = ($text -split "`n").Count }
        return [pscustomobject]@{
            Path = $full; Text = $text; Binary = $false; Truncated = $truncated
            Size = $size; Encoding = $encName; Lines = $lines
        }
    } finally {
        $fs.Dispose()
    }
}

function Save-GuiReadyTextFile {
    # 原子写文本：同目录临时文件 + 替换。原文件有 UTF-8 BOM 就保留，避免把脚本文件的 BOM 写丢。
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [switch]$WhatIf
    )

    $full = Assert-GuiReadyPathGuard -Path $Path -Operation 'Write'
    if (Test-Path -LiteralPath $full -PathType Container) { throw ('目标是目录，不能写文本：' + $full) }

    $hasBom = $false
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $fs = $null
        try {
            $fs = [System.IO.File]::OpenRead($full)
            $b = New-Object byte[] 3
            $n = $fs.Read($b, 0, 3)
            $hasBom = ($n -eq 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        } catch { } finally { if ($fs) { $fs.Dispose() } }
    }

    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    $bytes = [long]$enc.GetByteCount($Text)
    if ($WhatIf) {
        return [pscustomobject]@{ Path = $full; Bytes = $bytes; Written = $false }
    }

    $dir = [System.IO.Path]::GetDirectoryName($full)
    $tmp = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($full) + '.tmp-' + $PID)
    [System.IO.File]::WriteAllText($tmp, $Text, $enc)
    try {
        if (Test-Path -LiteralPath $full) {
            try { [System.IO.File]::Replace($tmp, $full, $null) }
            catch { Move-Item -LiteralPath $tmp -Destination $full -Force -ErrorAction Stop }
        } else {
            Move-Item -LiteralPath $tmp -Destination $full -Force -ErrorAction Stop
        }
    } catch {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
        throw
    }

    return [pscustomobject]@{ Path = $full; Bytes = $bytes; Written = $true }
}

function New-GuiReadyFolder {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$WhatIf
    )

    $full = Assert-GuiReadyPathGuard -Path $Path -Operation 'Write'
    if (Test-Path -LiteralPath $full) { throw ('目标已存在：' + $full) }
    if ($WhatIf) { return [pscustomobject]@{ Path = $full; Created = $false } }

    [void][System.IO.Directory]::CreateDirectory($full)
    return [pscustomobject]@{ Path = $full; Created = $true }
}

function Rename-GuiReadyPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewName,
        [switch]$WhatIf
    )

    $full = Assert-GuiReadyPathGuard -Path $Path -Operation 'Rename'
    if (-not (Test-Path -LiteralPath $full)) { throw ('路径不存在：' + $full) }

    $name = $NewName.Trim()
    if (-not $name) { throw '新名称不能为空。' }
    if ($name -eq '.' -or $name -eq '..') { throw '新名称不能是 . 或 ..。' }
    if ($name.Length -gt 255) { throw '新名称不能超过 255 个字符。' }
    if ($name -match '[\\/:*?"<>|]') { throw ('新名称包含非法字符：' + $name) }

    $parent = [System.IO.Path]::GetDirectoryName($full)
    $dest = Join-Path $parent $name
    if (Test-Path -LiteralPath $dest) { throw ('目标名称已存在：' + $dest) }
    if ($WhatIf) { return [pscustomobject]@{ Path = $full; NewPath = $dest } }

    Rename-Item -LiteralPath $full -NewName $name -ErrorAction Stop
    return [pscustomobject]@{ Path = $full; NewPath = $dest }
}

function Resolve-GuiReadyCopyTarget {
    # 复制/移动共用的目标解析：
    #   目标是已存在目录 -> 放进该目录下同名项；
    #   否则把目标当成新路径本身。
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $src = Assert-GuiReadyPathGuard -Path $Source -Operation 'Read'
    if (-not (Test-Path -LiteralPath $src)) { throw ('源路径不存在：' + $src) }

    $dst = ConvertTo-GuiReadyFilePath -Path $Destination
    $target = $dst
    if (Test-Path -LiteralPath $dst -PathType Container) {
        $target = Join-Path $dst ([System.IO.Path]::GetFileName($src.TrimEnd('\')))
    }
    [void](Assert-GuiReadyPathGuard -Path $target -Operation 'Write')

    $srcIsDir = Test-Path -LiteralPath $src -PathType Container
    if ($srcIsDir) {
        $srcNorm = $src.TrimEnd('\') + '\'
        $tgtNorm = $target.TrimEnd('\') + '\'
        if ($tgtNorm.StartsWith($srcNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ('不能把目录复制/移动到它自身或子目录：' + $src)
        }
    }

    return [pscustomobject]@{ Source = $src; Target = $target }
}

function Copy-GuiReadyPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Overwrite,
        [switch]$WhatIf
    )

    $r = Resolve-GuiReadyCopyTarget -Source $Path -Destination $Destination
    if (Test-Path -LiteralPath $r.Target) {
        if (-not $Overwrite) { throw ('目标已存在：' + $r.Target + '（勾选覆盖后重试）') }
        if (-not $WhatIf) { Remove-Item -LiteralPath $r.Target -Recurse -Force -ErrorAction Stop }
    }
    if ($WhatIf) { return [pscustomobject]@{ Path = $r.Source; Destination = $r.Target } }

    Copy-Item -LiteralPath $r.Source -Destination $r.Target -Recurse -Force -ErrorAction Stop
    return [pscustomobject]@{ Path = $r.Source; Destination = $r.Target }
}

function Move-GuiReadyPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Overwrite,
        [switch]$WhatIf
    )

    $r = Resolve-GuiReadyCopyTarget -Source $Path -Destination $Destination
    if (Test-Path -LiteralPath $r.Target) {
        if (-not $Overwrite) { throw ('目标已存在：' + $r.Target + '（勾选覆盖后重试）') }
        if (-not $WhatIf) { Remove-Item -LiteralPath $r.Target -Recurse -Force -ErrorAction Stop }
    }
    if ($WhatIf) { return [pscustomobject]@{ Path = $r.Source; Destination = $r.Target } }

    Move-Item -LiteralPath $r.Source -Destination $r.Target -Force -ErrorAction Stop
    return [pscustomobject]@{ Path = $r.Source; Destination = $r.Target }
}

function Remove-GuiReadyPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Recurse,
        [switch]$Force,
        [switch]$WhatIf
    )

    $full = Assert-GuiReadyPathGuard -Path $Path -Operation 'Delete'
    if (-not (Test-Path -LiteralPath $full)) { throw ('路径不存在：' + $full) }

    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    $isDir = ($item -is [System.IO.DirectoryInfo])
    $isLink = ((($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))

    # 目录联接/符号链接：只删链接本身，绝不能顺着 -Recurse 删到目标内容。
    if ($isDir -and $isLink) {
        if ($WhatIf) { return [pscustomobject]@{ Path = $full; Removed = $false } }
        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
        return [pscustomobject]@{ Path = $full; Removed = $true }
    }

    if ($isDir -and -not $Recurse) {
        $hasChild = $false
        try {
            $en = [System.IO.Directory]::EnumerateFileSystemEntries($full).GetEnumerator()
            try { $hasChild = $en.MoveNext() } finally { $en.Dispose() }
        } catch { }
        if ($hasChild) { throw '目录非空，需要递归删除。' }
    }

    if ($WhatIf) { return [pscustomobject]@{ Path = $full; Removed = $false } }
    Remove-Item -LiteralPath $full -Recurse:$Recurse -Force:$Force -ErrorAction Stop
    return [pscustomobject]@{ Path = $full; Removed = $true }
}

function Get-GuiReadyArchiveEntryCount {
    param([string]$Archive)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $z = [System.IO.Compression.ZipFile]::OpenRead($Archive)
        try { return $z.Entries.Count } finally { $z.Dispose() }
    } catch { return 0 }
}

function Compress-GuiReadyPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Destination = '',
        [switch]$WhatIf
    )

    $src = Assert-GuiReadyPathGuard -Path $Path -Operation 'Read'
    if (-not (Test-Path -LiteralPath $src)) { throw ('源路径不存在：' + $src) }
    $srcIsDir = Test-Path -LiteralPath $src -PathType Container

    if (-not $Destination) {
        $parent = [System.IO.Path]::GetDirectoryName($src)
        $leaf = [System.IO.Path]::GetFileName($src.TrimEnd('\'))
        if ($srcIsDir) { $leaf = [System.IO.Path]::GetFileName($src.TrimEnd('\')) }
        if (-not $leaf) { throw '无法从源路径推导压缩包名称，请显式指定目标。' }
        if (-not $leaf.ToLowerInvariant().EndsWith('.zip')) { $leaf = $leaf + '.zip' }
        $Destination = Join-Path $parent $leaf
    }
    $dst = ConvertTo-GuiReadyFilePath -Path $Destination
    if (-not $dst.ToLowerInvariant().EndsWith('.zip')) { throw ('压缩包目标必须以 .zip 结尾：' + $dst) }
    if (Test-Path -LiteralPath $dst) { throw ('压缩包已存在：' + $dst) }
    [void](Assert-GuiReadyPathGuard -Path $dst -Operation 'Write')

    if ($srcIsDir) {
        $srcNorm = $src.TrimEnd('\') + '\'
        $dstNorm = $dst.TrimEnd('\')
        if ($dstNorm.StartsWith($srcNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw '不能把压缩包放进被压缩的目录里。'
        }
    }

    if ($WhatIf) { return [pscustomobject]@{ Archive = $dst; Entries = 0 } }

    $zipOk = $true
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { $zipOk = $false }

    if ($zipOk) {
        if ($srcIsDir) {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $dst,
                [System.IO.Compression.CompressionLevel]::Optimal, $false)
        } else {
            $z = [System.IO.Compression.ZipFile]::Open($dst, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $z, $src, [System.IO.Path]::GetFileName($src),
                    [System.IO.Compression.CompressionLevel]::Optimal)
            } finally { $z.Dispose() }
        }
    } else {
        # 兜底：PowerShell 5.1 自带 Compress-Archive（对空目录支持较弱，但比直接失败好）
        Compress-Archive -LiteralPath $src -DestinationPath $dst -CompressionLevel Optimal -Force -ErrorAction Stop
    }

    return [pscustomobject]@{ Archive = $dst; Entries = (Get-GuiReadyArchiveEntryCount -Archive $dst) }
}

function Expand-GuiReadyArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Overwrite,
        [switch]$WhatIf
    )

    $zipPath = Assert-GuiReadyPathGuard -Path $Path -Operation 'Read'
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw ('压缩包不存在：' + $zipPath) }
    if (-not $zipPath.ToLowerInvariant().EndsWith('.zip')) { throw '当前只支持 .zip 压缩包。' }

    $dst = ConvertTo-GuiReadyFilePath -Path $Destination
    if (Test-Path -LiteralPath $dst -PathType Leaf) { throw ('解压目标已存在且是文件：' + $dst) }
    [void](Assert-GuiReadyPathGuard -Path $dst -Operation 'Write')

    $zip = $null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    } catch {
        throw ('当前系统缺少 ZIP 支持，无法解压：' + $_.Exception.Message)
    }

    try {
        $destRoot = [System.IO.Path]::GetFullPath($dst).TrimEnd('\')
        $plan = @()
        foreach ($e in $zip.Entries) {
            $rel = ([string]$e.FullName) -replace '/', '\'
            if ($rel -match '(^|\\)\.\.(\\|$)') { throw ('压缩包包含越界路径，已拒绝解压：' + $e.FullName) }
            $target = [System.IO.Path]::GetFullPath((Join-Path $destRoot $rel))
            if ($target -ne $destRoot -and -not $target.StartsWith($destRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ('压缩包包含越界路径，已拒绝解压：' + $e.FullName)
            }
            $plan += [pscustomobject]@{ Entry = $e; Target = $target; IsDir = [string]::IsNullOrEmpty($e.Name) }
        }

        # 先查冲突再落盘：避免解到一半才发现同名文件，留下半成品。
        if (-not $Overwrite) {
            $conflicts = @()
            foreach ($p in $plan) {
                if (-not $p.IsDir -and (Test-Path -LiteralPath $p.Target)) { $conflicts += $p.Target }
            }
            if ($conflicts.Count -gt 0) {
                $show = @($conflicts | Select-Object -First 3) -join '；'
                throw ('目标已存在 {0} 个同名文件，未解压（勾选覆盖后重试）：{1}' -f $conflicts.Count, $show)
            }
        }

        if ($WhatIf) { return [pscustomobject]@{ Destination = $dst; Entries = $plan.Count } }

        [void][System.IO.Directory]::CreateDirectory($dst)
        $n = 0
        foreach ($p in $plan) {
            if ($p.IsDir) {
                [void][System.IO.Directory]::CreateDirectory($p.Target)
            } else {
                $dir = [System.IO.Path]::GetDirectoryName($p.Target)
                if ($dir) { [void][System.IO.Directory]::CreateDirectory($dir) }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($p.Entry, $p.Target, $true)
                $n++
            }
        }
        return [pscustomobject]@{ Destination = $dst; Entries = $n }
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

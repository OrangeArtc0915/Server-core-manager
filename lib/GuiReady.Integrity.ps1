# GuiReady 完整性校验：文件清单（哈希）+ 脚本 Authenticode 签名 + 目录权限。
#
# 为什么需要它：这个工具以管理员/SYSTEM 身份执行自己的脚本。如果安装目录里的脚本被人改过
# （同机普通用户能写工具目录时这是现实威胁），我们却"照常运行"，就等于替攻击者执行代码。
# 所以：
#   - 打包时生成 manifest.sha256（清单），安装后可以逐个文件核对哈希；
#   - 脚本可以用 Authenticode 签名（Set-AuthenticodeSignature），能直接看出"被改过"；
#   - 目录 ACL 由 Test-GuiReadyToolDirSafe 负责（见 GuiReady.Common.ps1）。
#
# 注意：清单只能证明"文件与发布时一致"，不能证明"发布包来源可信"——后者要靠签名/哈希发布。

# 清单只覆盖代码与配置，不覆盖运行时产物与二进制素材（那些本来就会变）
$Global:GuiReadyIntegrityExtensions = @('.ps1', '.psm1', '.psd1', '.cmd', '.bat', '.json', '.md', '.txt')
# 这些目录不参与"多余文件"判定（运行时产物 / 仓库 / 打包中转）
$Global:GuiReadyIntegritySkipDirs = @(
    '.git', 'logs', 'reports', 'state', 'backup', 'payload', 'bin',
    'dist', 'site', 'node_modules', '签名'
)

function Get-GuiReadyFileHash {
    # SHA256（大写十六进制）。文件读不出来返回空串。
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs  = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') }
        finally { $fs.Dispose(); $sha.Dispose() }
    } catch { return '' }
}

function Get-GuiReadyIntegrityFiles {
    # 列出应该纳入清单的文件（相对路径，正斜杠）。$Root 下的代码与配置文件。
    param([Parameter(Mandatory = $true)][string]$Root)
    $out = @()
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
            $skip = $false
            foreach ($d in $Global:GuiReadyIntegritySkipDirs) {
                if ($rel -eq $d -or $rel.StartsWith($d + '/')) { $skip = $true; break }
            }
            if ($skip) { continue }
            if ($Global:GuiReadyIntegrityExtensions -notcontains $f.Extension.ToLowerInvariant()) { continue }
            $out += $rel
        }
    } catch { }
    return @($out | Sort-Object)
}

function New-GuiReadyManifest {
    # 生成清单：一行一个「SHA256<TAB>相对路径」。用 TAB 分隔，路径里带空格也不怕。
    # 为什么带生成时间注释：排查时能一眼看出这份清单是什么时候打的包。
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    $files = @(Get-GuiReadyIntegrityFiles -Root $Root)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('# ServerCoreManager 文件完整性清单（SHA256<TAB>相对路径）')
    [void]$lines.Add('# 生成时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$lines.Add('# 校验: powershell -File Sign-GuiReady.ps1 -Verify -Root <目录>')
    $n = 0
    foreach ($rel in $files) {
        $h = Get-GuiReadyFileHash -Path (Join-Path $Root $rel)
        if (-not $h) { continue }
        [void]$lines.Add(($h + "`t" + $rel))
        $n++
    }
    try {
        [System.IO.File]::WriteAllLines($OutFile, @($lines), (New-Object System.Text.UTF8Encoding($false)))
    } catch { return 0 }
    return $n
}

function Read-GuiReadyManifest {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $map }
    try {
        foreach ($line in @(Get-Content -LiteralPath $ManifestPath -Encoding UTF8 -ErrorAction Stop)) {
            $t = [string]$line
            if (-not $t -or $t.StartsWith('#')) { continue }
            $parts = $t -split "`t"
            if ($parts.Count -lt 2) { continue }
            $map[$parts[1].Trim()] = $parts[0].Trim().ToUpperInvariant()
        }
    } catch { }
    return $map
}

function Test-GuiReadyManifest {
    # 逐文件核对清单。返回 Modified / Missing / Extra / Ok。
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$ManifestPath = ''
    )
    if (-not $ManifestPath) { $ManifestPath = Join-Path $Root 'manifest.sha256' }
    $o = [pscustomobject]@{
        ManifestPath = $ManifestPath
        Exists = (Test-Path -LiteralPath $ManifestPath)
        Count = 0; Modified = @(); Missing = @(); Extra = @(); Ok = $false
    }
    if (-not $o.Exists) { return $o }

    $map = Read-GuiReadyManifest -ManifestPath $ManifestPath
    $o.Count = $map.Count
    foreach ($rel in $map.Keys) {
        $full = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full)) { $o.Missing += $rel; continue }
        $h = Get-GuiReadyFileHash -Path $full
        if (-not $h) { $o.Missing += $rel; continue }
        if ($h -ne $map[$rel]) { $o.Modified += $rel }
    }

    # 多余文件：只关心代码类扩展名（运行时产物、素材、仓库目录都不算）
    $known = @($map.Keys)
    foreach ($rel in @(Get-GuiReadyIntegrityFiles -Root $Root)) {
        if ($known -notcontains $rel) { $o.Extra += $rel }
    }

    $o.Ok = (($o.Modified.Count + $o.Missing.Count + $o.Extra.Count) -eq 0)
    return $o
}

function Test-GuiReadyScriptSignature {
    # 逐个脚本看 Authenticode 签名。状态含义：
    #   Valid        —— 签名有效且证书受信任
    #   UnknownError —— 签名本身有效，但证书链不受信任（自签名证书的常见结果）
    #   NotSigned    —— 没签名（开发检出就是这样，不算错）
    #   HashMismatch —— **文件被改过**（这是真正要报警的状态）
    #   NotTrusted   —— 其它不受信任情形
    param([Parameter(Mandatory = $true)][string]$Root, [string]$ManifestPath = '')

    if (-not $ManifestPath) { $ManifestPath = Join-Path $Root 'manifest.sha256' }
    $map = Read-GuiReadyManifest -ManifestPath $ManifestPath
    $targets = @()
    if ($map.Count -gt 0) {
        $targets = @($map.Keys | Where-Object { $_ -like '*.ps1' -or $_ -like '*.psm1' -or $_ -like '*.psd1' })
    } else {
        # 没有清单也要能查：退化成"扫一遍 .ps1"
        $targets = @(Get-GuiReadyIntegrityFiles -Root $Root | Where-Object { $_ -like '*.ps1' })
    }

    $bad = @(); $untrustedList = @(); $unsigned = 0; $trusted = 0; $untrusted = 0; $total = 0
    foreach ($rel in $targets) {
        $full = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $total++
        $sig = $null
        try { $sig = Get-AuthenticodeSignature -LiteralPath $full -ErrorAction Stop } catch { continue }
        $st = [string]$sig.Status
        if ($st -eq 'NotSigned') {
            # 文件里还留着**完整的签名块**、但已经不是有效状态 —— 典型情形是"签完又被改了"：
            # 在签名块后面追加内容会破坏块尾标记，于是它看起来"没签名"，其实被动过。
            # 判定必须要求块**尾**标记（真实签名块以它收尾）；只看块首会被源码里出现的
            # 同样字符串骗到（本模块自己就中过这个误报，实测踩到）。
            try {
                $len = (Get-Item -LiteralPath $full).Length
                if ($len -gt 0) {
                    $tailLen = [int][Math]::Min(1024, $len)
                    $fs = [System.IO.File]::OpenRead($full)
                    try {
                        [void]$fs.Seek(($len - $tailLen), [System.IO.SeekOrigin]::Begin)
                        $buf = New-Object byte[] $tailLen
                        [void]$fs.Read($buf, 0, $tailLen)
                        $tail = [System.Text.Encoding]::UTF8.GetString($buf)
                        # 标记字符串用拼接构造：避免本文件自身源码里出现字面量而被自己匹配到
                        $endMark = '# SIG # ' + 'End ' + 'signature block'
                        if ($tail -match ('(?m)^' + [regex]::Escape($endMark) + '\s*$')) { $st = 'HashMismatch' }
                    } finally { $fs.Dispose() }
                }
            } catch { }
        }
        switch ($st) {
            'Valid'        { $trusted++ }
            'NotSigned'    { $unsigned++ }
            'HashMismatch' { $bad += ('{0}（签名与内容不匹配，文件被改过）' -f $rel) }
            # 签名本身有效，只是证书链不受信任（自签名证书的常见结果）——
            # 这属于"信任问题"而不是"文件被改过"，单独统计，不当成篡改。
            'UnknownError' { $untrusted++; $untrustedList += $rel }
            default        { $bad += ('{0}（{1}）' -f $rel, $st) }
        }
    }
    return [pscustomobject]@{
        Total = $total; Trusted = $trusted; Untrusted = $untrusted; NotSigned = $unsigned
        Problems = @($bad); UntrustedFiles = @($untrustedList)
    }
}

function Get-GuiReadyIntegrityReport {
    # 汇总：目录权限 + 清单 + 签名。页面/动作都用这一份。
    param([string]$Root = '')

    if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }   # lib\ 的上一级 = 工具根

    # 目录权限检查在 GuiReady.Common.ps1 里；没加载就先跳过（不编造结论）
    $dirSafe = [pscustomobject]@{ Safe = $true; Known = $false; Reason = '未加载 GuiReady.Common.ps1，跳过目录权限检查'; Risky = @() }
    if (Get-Command Test-GuiReadyToolDirSafe -ErrorAction SilentlyContinue) {
        $dirSafe = Test-GuiReadyToolDirSafe -Path $Root
    }
    $man     = Test-GuiReadyManifest -Root $Root
    $sig     = Test-GuiReadyScriptSignature -Root $Root
    $verdict = 'ok'
    $notes   = New-Object System.Collections.ArrayList

    if ($dirSafe.Known -and -not $dirSafe.Safe) {
        $verdict = 'warn'
        [void]$notes.Add('工具目录不是管理员独占：' + $dirSafe.Reason)
    }
    if (-not $man.Exists) {
        if ($verdict -eq 'ok') { $verdict = 'info' }
        [void]$notes.Add('没有 manifest.sha256（开发检出或不是发布包）—— 无法核对文件是否被改过。')
    } elseif (-not $man.Ok) {
        $verdict = 'fail'
        if ($man.Modified.Count -gt 0) { [void]$notes.Add(('{0} 个文件与清单不一致（被改过）: {1}' -f $man.Modified.Count, ($man.Modified -join '、'))) }
        if ($man.Missing.Count  -gt 0) { [void]$notes.Add(('{0} 个文件缺失: {1}' -f $man.Missing.Count, ($man.Missing -join '、'))) }
        if ($man.Extra.Count    -gt 0) { [void]$notes.Add(('{0} 个清单外的脚本文件: {1}' -f $man.Extra.Count, ($man.Extra -join '、'))) }
    }
    if ($sig.Problems.Count -gt 0) {
        $verdict = 'fail'
        [void]$notes.Add(('{0} 个脚本的签名有问题: {1}' -f $sig.Problems.Count, ($sig.Problems -join '；')))
    } elseif ($sig.Untrusted -gt 0) {
        if ($verdict -eq 'ok') { $verdict = 'info' }
        [void]$notes.Add(('{0} 个脚本的签名有效但证书不受信任（自签名证书：把这台机器的 .cer 导入"受信任的根证书颁发机构"后即为"有效"）' -f $sig.Untrusted))
    } elseif ($sig.Total -gt 0 -and $sig.Trusted -eq 0) {
        if ($verdict -eq 'ok') { $verdict = 'info' }
        [void]$notes.Add('脚本都没有签名。发布包建议带签名，用户可据此判断来源。')
    }

    return [pscustomobject]@{
        Root = $Root; Verdict = $verdict; Notes = @($notes)
        DirSafe = $dirSafe; Manifest = $man; Signature = $sig
        Stamp = (Get-Date).ToString('s')
    }
}

function Show-GuiReadyIntegrityReport {
    # 文本版报告（动作 selfcheck 用；页面用 Get-GuiReadyIntegrityReport 自己渲染）
    Write-Head '本工具自身完整性自检'
    $r = Get-GuiReadyIntegrityReport

    Write-Log ('工具目录: ' + $r.Root) 'INFO'
    Write-Log ('目录权限: ' + $(if ($r.DirSafe.Safe) { '管理员独占（安全）' } else { '存在非管理员可写主体（不安全）' })) `
        $(if ($r.DirSafe.Safe) { 'OK' } else { 'WARN' })
    if ($r.DirSafe.Reason) { Write-Log ('  ' + $r.DirSafe.Reason) 'WARN' }

    if ($r.Manifest.Exists) {
        $m = $r.Manifest
        Write-Log ('文件清单: 共 {0} 项；不一致 {1}、缺失 {2}、清单外 {3}' -f $m.Count, $m.Modified.Count, $m.Missing.Count, $m.Extra.Count) `
            $(if ($m.Ok) { 'OK' } else { 'ERROR' })
        foreach ($x in $m.Modified) { Write-Log ('  被改过: ' + $x) 'ERROR' }
        foreach ($x in $m.Missing)  { Write-Log ('  缺失: ' + $x)   'ERROR' }
        foreach ($x in $m.Extra)    { Write-Log ('  清单外: ' + $x) 'WARN' }
    } else {
        Write-Log '文件清单: 没有 manifest.sha256（开发检出或非发布包）' 'WARN'
    }

    $s = $r.Signature
    Write-Log ('脚本签名: 共 {0} 个；受信任 {1}、不受信任 {2}、未签名 {3}' -f $s.Total, $s.Trusted, $s.Untrusted, $s.NotSigned) `
        $(if ($s.Problems.Count -eq 0) { 'OK' } else { 'ERROR' })
    foreach ($p in $s.Problems) { Write-Log ('  ' + $p) 'ERROR' }

    foreach ($n in $r.Notes) { Write-Log $n 'WARN' }
    Write-Log ('结论: ' + $(switch ($r.Verdict) { 'ok' { '未发现问题' } 'info' { '可用，但有可改进项' } 'warn' { '存在风险项' } default { '发现问题，建议按上面处理' } })) `
        $(if ($r.Verdict -eq 'ok') { 'OK' } elseif ($r.Verdict -eq 'fail') { 'ERROR' } else { 'WARN' })
}

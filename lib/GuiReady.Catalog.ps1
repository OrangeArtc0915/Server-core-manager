# GuiReady catalog: built-in + user program compatibility catalog with rule matching

$Global:GuiReadyCatalogFile     = Join-Path $PSScriptRoot 'catalog.json'
$Global:GuiReadyUserCatalogFile = Join-Path $PSScriptRoot 'catalog.user.json'

function Get-GuiReadyCatalog {
    $all = New-Object System.Collections.ArrayList

    foreach ($f in @($Global:GuiReadyCatalogFile, $Global:GuiReadyUserCatalogFile)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $raw = Get-Content -LiteralPath $f -Raw -Encoding UTF8
            $obj = $raw | ConvertFrom-Json
            foreach ($e in $obj.entries) {
                $isUser = ($f -eq $Global:GuiReadyUserCatalogFile)
                [void]$all.Add([pscustomobject]@{
                    Id            = [string]$e.id
                    Name          = [string]$e.name
                    Match         = @($e.match)
                    Type          = [string]$e.type
                    Verdict       = [string]$e.verdict
                    RequiredRuntime = @($e.requiredRuntime)
                    LaunchArgs    = [string]$e.launchArgs
                    VerifiedOn    = [string]$e.verifiedOn
                    Notes         = [string]$e.notes
                    Evidence      = [string]$e.evidence
                    IsUserEntry   = $isUser
                    Source        = (Split-Path $f -Leaf)
                })
            }
        } catch {
            Write-Log ('读取档案失败 {0}: {1}' -f $f, $_.Exception.Message) 'WARN'
        }
    }
    return @($all)
}

function Get-GuiReadyCatalogContext {
    param([Parameter(Mandatory = $true)][string]$ExePath)

    $ctx = [ordered]@{
        Exists        = $false
        FullPath      = ''
        FileName      = ''
        ExeName       = ''
        Dir           = ''
        ProductName   = ''
        FileDescription = ''
        KindTag       = ''
        Subsystem     = ''
        IsDotNet      = $false
        RequiredRuntime = ''
        FileInside    = ''
    }

    if (-not (Test-Path -LiteralPath $ExePath)) { return [pscustomobject]$ctx }
    $full = (Resolve-Path -LiteralPath $ExePath).ProviderPath
    $ctx.Exists      = $true
    $ctx.FullPath    = $full
    $ctx.FileName    = [System.IO.Path]::GetFileName($full)
    $ctx.ExeName     = [System.IO.Path]::GetFileNameWithoutExtension($full)
    $ctx.Dir         = Split-Path -Parent $full

    try {
        $vi = (Get-Item -LiteralPath $full).VersionInfo
        $ctx.ProductName     = [string]$vi.ProductName
        $ctx.FileDescription = [string]$vi.FileDescription
    } catch { }

    if (Get-Command Get-PeImageInfo -ErrorAction SilentlyContinue) {
        try {
            $pe = Get-PeImageInfo -Path $full
            $ctx.Subsystem = [string]$pe.SubsystemName
            $ctx.IsDotNet  = [bool]$pe.IsDotNet
            if (Get-Command Get-FileKindTag -ErrorAction SilentlyContinue) {
                $ctx.KindTag = [string](Get-FileKindTag -Path $full -PeInfo $pe)
            }
        } catch { }
    }

    if (Get-Command Get-GuiReadyRequiredRuntime -ErrorAction SilentlyContinue) {
        try {
            $req = Get-GuiReadyRequiredRuntime -ExePath $full
            if ($req.Ok) { $ctx.RequiredRuntime = (($req.Frameworks | ForEach-Object { $_.Name }) -join ',') }
        } catch { }
    }

    try {
        $names = New-Object System.Collections.ArrayList
        $lvl1 = @(Get-ChildItem -LiteralPath $ctx.Dir -ErrorAction SilentlyContinue | Select-Object -First 40)
        foreach ($f1 in $lvl1) { [void]$names.Add($f1.Name) }
        foreach ($f1 in @($lvl1 | Where-Object { $_.PSIsContainer } | Select-Object -First 15)) {
            $lvl2 = @(Get-ChildItem -LiteralPath $f1.FullName -ErrorAction SilentlyContinue | Select-Object -First 40)
            foreach ($f2 in $lvl2) { [void]$names.Add($f2.Name) }
        }
        $ctx.FileInside = ($names -join '|')
    } catch { }

    return [pscustomobject]$ctx
}

function Test-GuiReadyCatalogRule {
    param($Rule, $Ctx)

    $field = [string]$Rule.field
    $pat   = [string]$Rule.pattern

    switch ($field) {
        'ExeName'         { return ($Ctx.ExeName -match $pat) }
        'FileName'        { return ($Ctx.FileName -match $pat) }
        'ProductName'     { return ($Ctx.ProductName -match $pat) }
        'FileDescription' { return ($Ctx.FileDescription -match $pat) }
        'KindTag'         { return ($Ctx.KindTag -match $pat) }
        'DirContains'     { return ($Ctx.Dir -match $pat) }
        'FullPath'        { return ($Ctx.FullPath -match $pat) }
        'Subsystem'       { return ($Ctx.Subsystem -match $pat) }
        'RequiredRuntime' { return ($Ctx.RequiredRuntime -match $pat) }
        'FileInside'      { return ($Ctx.FileInside -match $pat) }
        default           { return $false }
    }
}

function Get-GuiReadyCatalogEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        $Context
    )

    if (-not $Context) { $Context = Get-GuiReadyCatalogContext -ExePath $ExePath }
    if (-not $Context.Exists) { return $null }

    foreach ($e in (Get-GuiReadyCatalog)) {
        if (-not $e.Match -or $e.Match.Count -eq 0) { continue }
        $all = $true
        foreach ($r in $e.Match) {
            $hit = $false
            try { $hit = Test-GuiReadyCatalogRule -Rule $r -Ctx $Context } catch { $hit = $false }
            if (-not $hit) { $all = $false; break }
        }
        if ($all) { return $e }
    }
    return $null
}

function Show-GuiReadyCatalogEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [switch]$Quiet
    )

    $ctx = Get-GuiReadyCatalogContext -ExePath $ExePath
    if (-not $ctx.Exists) {
        if (-not $Quiet) { Write-Log ('文件不存在: ' + $ExePath) 'ERROR' }
        return $null
    }

    $e = Get-GuiReadyCatalogEntry -ExePath $ExePath -Context $ctx

    if (-not $Quiet) {
        Write-Head ('程序兼容档案: ' + $ctx.FileName)
        Write-Log ('路径      : {0}' -f $ctx.FullPath) 'INFO'
        Write-Log ('类型特征  : 子系统={0}  .NET={1}  标签={2}' -f $ctx.Subsystem, $ctx.IsDotNet, $(if ($ctx.KindTag) { $ctx.KindTag } else { '(未识别)' })) 'INFO'
        if ($ctx.RequiredRuntime) { Write-Log ('运行时需求: {0}' -f $ctx.RequiredRuntime) 'INFO' }
    }

    if (-not $e) {
        if (-not $Quiet) {
            Write-Log '档案里没有匹配条目。可以用 Add-GuiReadyCatalogEntry 把它记下来。' 'WARN'
        }
        return [pscustomobject]@{ Context = $ctx; Entry = $null }
    }

    if (-not $Quiet) {
        Write-Log ''
        Write-Log ('条目      : {0}  [{1}]' -f $e.Name, $e.Id) 'OK'
        Write-Log ('来源      : {0}{1}' -f $e.Source, $(if ($e.IsUserEntry) { '（你自己的记录）' } else { '（内置）' })) 'INFO'
        Write-Log ('类型      : {0}' -f $e.Type) 'INFO'
        Write-Log ('结论      : {0}' -f $e.Verdict) $(if ($e.Verdict -match '不支持') { 'ERROR' } elseif ($e.Verdict -match '建议参数') { 'WARN' } else { 'OK' })
        if ($e.LaunchArgs) {
            Write-Log ('推荐启动参数: {0}' -f $e.LaunchArgs) 'OK'
            Write-Log ('  例如: & "{0}" {1}' -f $ctx.FullPath, $e.LaunchArgs) 'INFO'
        }
        if ($e.VerifiedOn) { Write-Log ('实测系统 build: {0}' -f $e.VerifiedOn) 'INFO' }
        if ($e.Notes)    { Write-Log ('注意      : {0}' -f $e.Notes) 'INFO' }
        if ($e.Evidence) { Write-Log ('实测证据  : {0}' -f $e.Evidence) 'INFO' }
    }

    return [pscustomobject]@{ Context = $ctx; Entry = $e }
}

function Add-GuiReadyCatalogEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExeNamePattern,
        [ValidateSet('可用', '可用（建议参数）', '不支持', '未知')][string]$Verdict = '未知',
        [string]$Type = '',
        [string]$LaunchArgs = '',
        [string]$Notes = '',
        [string]$Evidence = '',
        [string]$VerifiedOn = ''
    )

    $entries = @()
    $doc = $null
    if (Test-Path -LiteralPath $Global:GuiReadyUserCatalogFile) {
        try { $doc = (Get-Content -LiteralPath $Global:GuiReadyUserCatalogFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { $doc = $null }
    }
    if ($doc -and $doc.entries) { $entries = @($doc.entries) }

    $entries = @($entries | Where-Object { $_.id -ne $Id })
    $entries += [pscustomobject]@{
        id        = $Id
        name      = $Name
        match     = @(@{ field = 'ExeName'; pattern = $ExeNamePattern })
        type      = $Type
        verdict   = $Verdict
        requiredRuntime = @()
        launchArgs= $LaunchArgs
        verifiedOn= $VerifiedOn
        notes     = $Notes
        evidence  = $Evidence
    }

    $out = [ordered]@{
        version     = 1
        description = 'GuiReady 用户档案（你自己的实测结论，优先级高于内置档案）'
        entries     = $entries
    }
    try {
        [System.IO.File]::WriteAllText($Global:GuiReadyUserCatalogFile, ($out | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding -ArgumentList $true))
        Write-Log ('已写入用户档案: {0}（条目 {1}）' -f $Global:GuiReadyUserCatalogFile, $entries.Count) 'OK'
        return $true
    } catch {
        Write-Log ('写入用户档案失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Get-GuiReadyCatalogLaunchArgs {
    param([Parameter(Mandatory = $true)][string]$ExePath)
    $r = Show-GuiReadyCatalogEntry -ExePath $ExePath -Quiet
    if ($r -and $r.Entry -and $r.Entry.LaunchArgs) { return [string]$r.Entry.LaunchArgs }
    return ''
}

function Show-GuiReadyCatalogList {
    param([string]$Filter = '')

    Write-Head '程序兼容档案（内置 + 用户）'
    $all = Get-GuiReadyCatalog
    foreach ($e in $all) {
        if ($Filter -and $e.Name -notmatch $Filter -and $e.Id -notmatch $Filter) { continue }
        Write-Log ('[{0}] {1}' -f $e.Id, $e.Name) 'OK'
        Write-Log ('    来源={0}  类型={1}  结论={2}' -f $e.Source, $e.Type, $e.Verdict) 'INFO'
        $pats = @($e.Match | ForEach-Object { $_.field + '~' + $_.pattern })
        Write-Log ('    匹配规则: {0}' -f ($pats -join ' ; ')) 'INFO'
        if ($e.LaunchArgs) { Write-Log ('    推荐参数: {0}' -f $e.LaunchArgs) 'INFO' }
        if ($e.VerifiedOn) { Write-Log ('    实测于 build {0}' -f $e.VerifiedOn) 'INFO' }
    }
    Write-Log ('共 {0} 条' -f $all.Count) 'INFO'
    return $all
}

# GuiReady program list runner: the "程序管理" page's storage + command binding.
#
# Stores launcher\programs.json in the same shape the PowerShell GUI uses:
#   [ { "Name": "...", "Path": "...", "Args": "...", "Cmd": "..." } ]
#
# Modes:
#   list   -> all programs
#   add    -> add one program by Path (dedupe by Path; Name/Args optional)
#   update -> change Name/Args/Cmd of an existing program (keyed by Path)
#   remove -> drop one program by Path
#   bind   -> bind/unbind a terminal command (empty Alias = unbind)
#   catalog-> look up the compatibility catalog entry for one exe
#
# Keep launching itself in the UI (Process.Start); this runner only touches files.

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'
$store    = Join-Path $toolRoot 'launcher\programs.json'

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-programs.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.PeInspect.ps1', 'GuiReady.Catalog.ps1', 'GuiReady.Command.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-ProgramsResult {
    param($Data, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode  = $Mode
        Stamp = (Get-Date).ToString('o')
        Error = $ErrorText
        Data  = $Data
    }
    try {
        $json = $o | ConvertTo-Json -Depth 8 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

function Read-Programs {
    if (-not (Test-Path -LiteralPath $store)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $store -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = ConvertFrom-Json -InputObject $raw
        return @($parsed)
    } catch { return @() }
}

function Save-Programs {
    param($Items)
    $dir = Split-Path -Parent $store
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $list = @($Items)
    [System.IO.File]::WriteAllText($store, (ConvertTo-Json -InputObject @($list) -Depth 5),
                                   (New-Object System.Text.UTF8Encoding($true)))
}

function Get-ProgramsArray {
    # Normalise into plain objects so JSON round-trips without extra properties.
    $out = @()
    foreach ($p in @(Read-Programs)) {
        if (-not $p) { continue }
        $out += [pscustomobject]@{
            Name = [string]$p.Name
            Path = [string]$p.Path
            Args = [string]$p.Args
            Cmd  = [string]$p.Cmd
        }
    }
    return @($out)
}

$A = @{}
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $raw = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $obj = $raw | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $A[$prop.Name] = $prop.Value }
        }
    } catch {
        Write-ProgramsResult -Data $null -ErrorText ('args parse failed: ' + $_.Exception.Message)
        exit 1
    }
}

function Get-ArgString {
    param([string]$Name, [string]$Default = '')
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return [string]$A[$Name] }
    return $Default
}

try {
    switch ($Mode) {
        'list' {
            # 顺带把兼容结论算出来（档案匹配是纯内存操作，整批判定一次就够，
            # 免得界面为每个程序各起一个子进程）。
            $items = @()
            foreach ($it in @(Get-ProgramsArray)) {
                $verdict = ''
                $exists = Test-Path -LiteralPath ([string]$it.Path) -PathType Leaf
                if (-not $exists) {
                    $verdict = '文件不存在'
                } else {
                    try {
                        $ce = Show-GuiReadyCatalogEntry -ExePath ([string]$it.Path) -Quiet
                        if ($ce -and $ce.Entry) { $verdict = [string]$ce.Entry.Verdict }
                    } catch { }
                }
                $items += [pscustomobject]@{
                    Name = [string]$it.Name
                    Path = [string]$it.Path
                    Args = [string]$it.Args
                    Cmd  = [string]$it.Cmd
                    Verdict = $verdict
                    Exists = $exists
                }
            }
            Write-ProgramsResult -Data ([ordered]@{ Items = @($items); Store = $store })
            exit 0
        }
        'add' {
            $path = Get-ArgString -Name 'Path'
            if (-not $path) { Write-ProgramsResult -Data $null -ErrorText 'Path is required'; exit 2 }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-ProgramsResult -Data $null -ErrorText ('文件不存在：' + $path)
                exit 1
            }
            $full = (Resolve-Path -LiteralPath $path).ProviderPath
            $name = Get-ArgString -Name 'Name'
            if (-not $name) { $name = [System.IO.Path]::GetFileNameWithoutExtension($full) }
            $args = Get-ArgString -Name 'Args'

            $items = @(Get-ProgramsArray)
            if (-not $args) {
                # 没给参数时自动带入档案里的推荐启动参数
                try {
                    $ce = Show-GuiReadyCatalogEntry -ExePath $full -Quiet
                    if ($ce -and $ce.Entry -and $ce.Entry.LaunchArgs) { $args = [string]$ce.Entry.LaunchArgs }
                } catch { }
            }

            $exists = $false
            foreach ($it in $items) {
                if ([string]$it.Path -ieq $full) { $exists = $true; break }
            }
            if (-not $exists) {
                $items += [pscustomobject]@{ Name = $name; Path = $full; Args = $args; Cmd = '' }
                Save-Programs -Items $items
            }
            Write-ProgramsResult -Data ([ordered]@{ Items = @(Get-ProgramsArray); Added = (-not $exists); Args = $args })
            exit 0
        }
        'update' {
            $path = Get-ArgString -Name 'Path'
            if (-not $path) { Write-ProgramsResult -Data $null -ErrorText 'Path is required'; exit 2 }
            $items = @(Get-ProgramsArray)
            $hit = $false
            foreach ($it in $items) {
                if ([string]$it.Path -ine $path) { continue }
                if ($A.ContainsKey('Name')) { $it.Name = [string]$A['Name'] }
                if ($A.ContainsKey('Args')) { $it.Args = [string]$A['Args'] }
                if ($A.ContainsKey('Cmd'))  { $it.Cmd  = [string]$A['Cmd'] }
                $hit = $true
                break
            }
            if (-not $hit) { Write-ProgramsResult -Data $null -ErrorText ('找不到程序：' + $path); exit 1 }
            Save-Programs -Items $items
            Write-ProgramsResult -Data ([ordered]@{ Items = @(Get-ProgramsArray) })
            exit 0
        }
        'remove' {
            $path = Get-ArgString -Name 'Path'
            if (-not $path) { Write-ProgramsResult -Data $null -ErrorText 'Path is required'; exit 2 }
            $items = @(Get-ProgramsArray)
            $keep = @($items | Where-Object { [string]$_.Path -ine $path })
            if ($keep.Count -eq $items.Count) {
                Write-ProgramsResult -Data $null -ErrorText ('找不到程序：' + $path)
                exit 1
            }
            # 顺便解绑它占用的终端命令，别留下指向已删程序的垫片
            foreach ($it in $items) {
                if ([string]$it.Path -ine $path) { continue }
                if ([string]$it.Cmd) {
                    try { [void](Remove-GuiReadyProgramCommand -Alias ([string]$it.Cmd)) } catch { }
                }
            }
            Save-Programs -Items $keep
            Write-ProgramsResult -Data ([ordered]@{ Items = @(Get-ProgramsArray) })
            exit 0
        }
        'bind' {
            $path  = Get-ArgString -Name 'Path'
            $alias = (Get-ArgString -Name 'Alias').Trim()
            if (-not $path) { Write-ProgramsResult -Data $null -ErrorText 'Path is required'; exit 2 }

            $items = @(Get-ProgramsArray)
            $target = $null
            foreach ($it in $items) { if ([string]$it.Path -ieq $path) { $target = $it; break } }
            if (-not $target) { Write-ProgramsResult -Data $null -ErrorText ('找不到程序：' + $path); exit 1 }

            if (-not $alias) {
                if ([string]$target.Cmd) {
                    try { [void](Remove-GuiReadyProgramCommand -Alias ([string]$target.Cmd)) } catch { }
                }
                $target.Cmd = ''
                Save-Programs -Items $items
                Write-ProgramsResult -Data ([ordered]@{ Ok = $true; Cmd = '' })
                exit 0
            }

            $old = [string]$target.Cmd
            if ($old -and $old -ne $alias) {
                try { [void](Remove-GuiReadyProgramCommand -Alias $old) } catch { }
            }
            $r = Install-GuiReadyProgramCommand -Alias $alias -ExePath ([string]$target.Path) -Arguments ([string]$target.Args)
            if (-not $r.Ok) {
                Write-ProgramsResult -Data ([ordered]@{ Ok = $false; Code = [string]$r.Code })
                exit 1
            }
            $target.Cmd = $alias
            Save-Programs -Items $items
            Write-ProgramsResult -Data ([ordered]@{ Ok = $true; Cmd = $alias; Target = [string]$r.Target })
            exit 0
        }
        'catalog' {
            $path = Get-ArgString -Name 'Path'
            if (-not $path) { Write-ProgramsResult -Data $null -ErrorText 'Path is required'; exit 2 }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-ProgramsResult -Data $null -ErrorText ('文件不存在：' + $path)
                exit 1
            }
            $r = Show-GuiReadyCatalogEntry -ExePath $path -Quiet
            $entry = $null
            if ($r -and $r.Entry) {
                $entry = [pscustomobject]@{
                    Id         = [string]$r.Entry.Id
                    Name       = [string]$r.Entry.Name
                    Verdict    = [string]$r.Entry.Verdict
                    Type       = [string]$r.Entry.Type
                    LaunchArgs = [string]$r.Entry.LaunchArgs
                    Notes      = [string]$r.Entry.Notes
                    Evidence   = [string]$r.Entry.Evidence
                    IsUserEntry= [bool]$r.Entry.IsUserEntry
                }
            }
            $ctx = $null
            if ($r -and $r.Context) {
                $ctx = [pscustomobject]@{
                    Subsystem = [string]$r.Context.Subsystem
                    IsDotNet  = [bool]$r.Context.IsDotNet
                    KindTag   = [string]$r.Context.KindTag
                    ProductName = [string]$r.Context.ProductName
                }
            }
            Write-ProgramsResult -Data ([ordered]@{ Entry = $entry; Context = $ctx })
            exit 0
        }
        default {
            Write-ProgramsResult -Data $null -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
} catch {
    Write-ProgramsResult -Data $null -ErrorText $_.Exception.Message
    exit 1
}

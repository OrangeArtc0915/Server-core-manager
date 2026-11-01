# GuiReady database runner: PostgreSQL 安装 / 初始化 / 服务 / 备份 / 状态。
# 接口与其它 runner 一致：-Mode <m> -OutFile <json> [-ArgsFile <json>]
# 参数走 JSON 文件（里面可能有数据库密码，读完立即删除）。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$Version = '',
    [string]$Engine = '',
    [int]$Port = 0,
    [string]$Password = '',
    [string]$Id = '',
    [string]$Action = '',
    [string]$Database = '',
    [string]$File = '',
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

$Global:GuiReadyLogFile = Join-Path $toolRoot 'logs\gui-database.log'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Database.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$dry = $false
$removeData = $false
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $a = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($a.Version)    { $Version    = [string]$a.Version }
        if ($a.Engine)     { $Engine     = [string]$a.Engine }
        if ($a.Port)       { $Port       = [int]$a.Port }
        if ($a.Password)   { $Password   = [string]$a.Password }
        if ($a.Id)         { $Id         = [string]$a.Id }
        if ($a.Action)     { $Action     = [string]$a.Action }
        if ($a.Database)   { $Database   = [string]$a.Database }
        if ($a.File)       { $File       = [string]$a.File }
        if ($a.DryRun)     { $dry        = [bool]$a.DryRun }
        if ($a.RemoveData) { $removeData = [bool]$a.RemoveData }
    } catch { }
    try { Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue } catch { }
}

function Write-DbResult {
    param($Data, $Items, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode  = $Mode
        Stamp = (Get-Date).ToString('o')
        Error = $ErrorText
        Data  = $Data
        Items = @($Items)
    }
    try {
        $json = $o | ConvertTo-Json -Depth 10 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    switch ($Mode) {
        'list' {
            $st = Get-GuiReadyDatabaseStatus
            Write-DbResult -Data $st -Items @($st.Items)
        }
        'install' {
            if (-not $Version) { throw '缺少参数：Version' }
            if (-not $Engine) { $Engine = 'postgresql' }
            $r = Install-GuiReadyDatabaseEngine -Engine $Engine -Version $Version -DryRun:$dry
            Write-DbResult -Data (Get-GuiReadyDatabaseStatus) -Items @($r)
        }
        'init' {
            if (-not $Version) { throw '缺少参数：Version' }
            if (-not $Engine) { $Engine = 'postgresql' }
            if ($Port -le 0) {
                if ($Engine -eq 'mysql') { $Port = Get-GuiReadyFreePort -Start 3306 }
                else { $Port = Get-GuiReadyFreePort -Start 5432 }
            }
            if (-not $Password -and -not $dry) { throw '缺少参数：Password' }
            $r = Initialize-GuiReadyDatabaseInstance -Engine $Engine -Version $Version -Port $Port -Password $Password -DryRun:$dry
            Write-DbResult -Data (Get-GuiReadyDatabaseStatus) -Items @($r)
        }
        'service' {
            if (-not $Id) { throw '缺少参数：Id（实例编号）' }
            $act = [string]$Action
            if (-not $act) { $act = 'start' }
            $rawAct = $act
            # 动作台传的是下拉序号（1 基），界面对外则用文本
            $map = @{ '1' = 'start'; '2' = 'register'; '3' = 'start'; '4' = 'stop'; '5' = 'restart'; '6' = 'unregister'; '7' = 'unregister' }
            if ($map.ContainsKey($act)) { $act = $map[$act] }
            if ($rawAct -eq '7') { $removeData = $true }
            $r = $null
            switch ($act.ToLower()) {
                'start'      { $r = Register-GuiReadyDatabaseService -Id $Id -Start -DryRun:$dry }
                'register'   { $r = Register-GuiReadyDatabaseService -Id $Id -DryRun:$dry }
                'stop'       { $r = Set-GuiReadyDbServiceState -Id $Id -Action 'Stop' }
                'restart'    { $r = Set-GuiReadyDbServiceState -Id $Id -Action 'Restart' }
                'unregister' { $r = Unregister-GuiReadyDbService -Id $Id -RemoveData:$removeData -DryRun:$dry }
                default      { throw ('未知操作：' + $act) }
            }
            Write-DbResult -Data (Get-GuiReadyDatabaseStatus) -Items @($r)
        }
        'backup' {
            if (-not $Id) { throw '缺少参数：Id（实例编号）' }
            if (-not $Database) { $Database = '' }
            $r = Backup-GuiReadyDatabase -Id $Id -Database $Database -DryRun:$dry
            Write-DbResult -Data (Get-GuiReadyDatabaseStatus) -Items @($r)
        }
        'createdb' {
            if (-not $Id) { throw '缺少参数：Id（实例编号）' }
            if (-not $Database) { throw '缺少参数：Database（要新建的库名）' }
            $r = New-GuiReadyDatabase -Id $Id -Database $Database -DryRun:$dry
            Write-DbResult -Data (Get-GuiReadyDatabaseStatus) -Items @($r)
        }
        'restore' {
            if (-not $Id) { throw '缺少参数：Id（实例编号）' }
            if (-not $File) { throw '缺少参数：File（备份文件）' }
            $r = Restore-GuiReadyDatabase -Id $Id -File $File -Database $Database -DryRun:$dry
            Write-DbResult -Data (Get-GuiReadyDatabaseStatus) -Items @($r)
        }
        default {
            Write-DbResult -Data $null -Items @() -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
    exit 0
} catch {
    Write-DbResult -Data $null -Items @() -ErrorText $_.Exception.Message
    exit 1
}

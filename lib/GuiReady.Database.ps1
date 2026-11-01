# GuiReady 数据库：Windows Server Core 上的 PostgreSQL 落地。
#
# XMP 那边是「MySQL / PostgreSQL 容器 + 面板」，Server Core 没有容器平台，
# 这里换成原生形态：
#   1. 官方 binaries zip 解压到 <工具目录>\databases\postgresql\<版本>（不跑安装器）
#   2. initdb 建实例（数据目录在 <工具目录>\data\postgresql\<版本>-<端口>）
#   3. pg_ctl register 注册成 Windows 服务，账号用 NT AUTHORITY\NetworkService
#      （postgres.exe 拒绝以管理员身份运行，服务账号也顺带解决开机自启）
#   4. 备份用 pg_dump -Fc，落在 <工具目录>\backup\postgresql\
#
# 密码不明文落盘：实例记录里存的是 DPAPI(LocalMachine) 加密后的 Base64，
# 只有本机管理员能解开 —— 备份/维护要用它去连库。

try { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue } catch { }

# ---------------------------------------------------------------- 位置
function Get-GuiReadyDatabaseRoot {
    if ($env:SCM_DATABASE_ROOT) {
        try { return [System.IO.Path]::GetFullPath([string]$env:SCM_DATABASE_ROOT) } catch { return [string]$env:SCM_DATABASE_ROOT }
    }
    return (Join-Path (Get-GuiReadyRuntimeRootBase) 'databases')
}

function Get-GuiReadyRuntimeRootBase {
    # 与运行库共用同一个「工具根目录」推导规则
    $root = $script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return $root
}

function Get-GuiReadyDatabaseDataRoot {
    if ($env:SCM_DATABASE_DATA_ROOT) {
        try { return [System.IO.Path]::GetFullPath([string]$env:SCM_DATABASE_DATA_ROOT) } catch { return [string]$env:SCM_DATABASE_DATA_ROOT }
    }
    return (Join-Path (Get-GuiReadyRuntimeRootBase) 'data\postgresql')
}

function Get-GuiReadyDatabaseStatePath {
    return (Join-Path (Get-GuiReadyRuntimeRootBase) 'state\database-instances.json')
}

# ---------------------------------------------------------------- 清单
function Get-GuiReadyPostgresCatalog {
    return @(
        [pscustomobject]@{ Version = '16.4-1'; Major = '16'; Size = '约 320 MB'
            Url = 'https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64-binaries.zip'
            Note = 'EDB 官方 Windows binaries zip；解压即用，不含 pgAdmin。' }
        [pscustomobject]@{ Version = '17.0-1'; Major = '17'; Size = '约 330 MB'
            Url = 'https://get.enterprisedb.com/postgresql/postgresql-17.0-1-windows-x64-binaries.zip'
            Note = '较新大版本；老客户端驱动兼容性需自行确认。' }
    )
}

function Get-GuiReadyPostgresEntry {
    param([Parameter(Mandatory = $true)][string]$Version)
    foreach ($e in (Get-GuiReadyPostgresCatalog)) { if ($e.Version -eq $Version) { return $e } }
    return $null
}

function Get-GuiReadyPostgresVersionDir {
    param([Parameter(Mandatory = $true)][string]$Version)
    return (Join-Path (Join-Path (Get-GuiReadyDatabaseRoot) 'postgresql') $Version)
}

function Get-GuiReadyPostgresBin {
    param([Parameter(Mandatory = $true)][string]$Version)
    return (Join-Path (Get-GuiReadyPostgresVersionDir $Version) 'bin')
}

function Get-GuiReadyPostgresInstalledVersion {
    $dir = Join-Path (Get-GuiReadyDatabaseRoot) 'postgresql'
    $out = @()
    if (Test-Path -LiteralPath $dir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($d.Name -ieq 'current') { continue }
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'bin\initdb.exe')) { $out += $d.Name }
        }
    }
    return @($out | Sort-Object)
}

function Test-GuiReadyPostgresInstalled {
    param([Parameter(Mandatory = $true)][string]$Version)
    return (Test-Path -LiteralPath (Join-Path (Get-GuiReadyPostgresBin $Version) 'initdb.exe'))
}

function Invoke-GuiReadyPgTool {
    # 跑数据库自带 exe，返回 @{ Code; Out; Err }
    # -StdinFile：把文件喂给标准输入（MySQL 的还原就是 mysql < dump.sql）
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Arguments = '',
        [int]$TimeoutMs = 600000,
        [hashtable]$Env = @{},
        [string]$StdinFile = ''
    )
    $o = [pscustomobject]@{ Code = -1; Out = ''; Err = '' }
    if (-not (Test-Path -LiteralPath $Exe)) { $o.Err = '找不到 ' + $Exe; return $o }
    $old = @{}
    foreach ($k in $Env.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Env[$k]) }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($StdinFile) { $psi.RedirectStandardInput = $true }
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = Split-Path -Parent $Exe
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if ($StdinFile) {
            # 和 stdout/stderr 的异步读取同时进行，避免管道写满互相卡死
            try {
                $fs = [System.IO.File]::OpenRead($StdinFile)
                try { $fs.CopyTo($p.StandardInput.BaseStream) } finally { $fs.Dispose() }
            } catch {
                $o.Err = '读取输入文件失败: ' + $_.Exception.Message
            } finally {
                try { $p.StandardInput.Close() } catch { }
            }
        }
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            $o.Err = '执行超时'
            return $o
        }
        $o.Code = $p.ExitCode
        $o.Out = $outTask.Result
        $o.Err = $errTask.Result
    } catch {
        $o.Err = $_.Exception.Message
    } finally {
        foreach ($k in $old.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
    }
    return $o
}

function Get-GuiReadyMySQLCatalog {
    return @(
        [pscustomobject]@{ Version = '8.4.3'; Major = '8.4'; Size = '约 300 MB'
            Url = 'https://dev.mysql.com/get/Downloads/MySQL-8.4/mysql-8.4.3-winx64.zip'
            Note = '8.4 LTS；mysql_native_password 已移除，客户端需支持 caching_sha2_password。' }
        [pscustomobject]@{ Version = '8.0.40'; Major = '8.0'; Size = '约 300 MB'
            Url = 'https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-8.0.40-winx64.zip'
            Note = '8.0 稳定线；老客户端 / 老驱动兼容性最好。' }
    )
}

function Get-GuiReadyMySQLVersionDir {
    param([Parameter(Mandatory = $true)][string]$Version)
    return (Join-Path (Join-Path (Get-GuiReadyDatabaseRoot) 'mysql') $Version)
}

function Get-GuiReadyMySQLBin {
    param([Parameter(Mandatory = $true)][string]$Version)
    return (Join-Path (Get-GuiReadyMySQLVersionDir $Version) 'bin')
}

function Test-GuiReadyMySQLInstalled {
    param([Parameter(Mandatory = $true)][string]$Version)
    return (Test-Path -LiteralPath (Join-Path (Get-GuiReadyMySQLBin $Version) 'mysqld.exe'))
}

function Get-GuiReadyMySQLInstalledVersion {
    $dir = Join-Path (Get-GuiReadyDatabaseRoot) 'mysql'
    $out = @()
    if (Test-Path -LiteralPath $dir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($d.Name -ieq 'current') { continue }
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'bin\mysqld.exe')) { $out += $d.Name }
        }
    }
    return @($out | Sort-Object)
}

# ---------------------------------------------------------------- 实例记录
function Read-GuiReadyDbInstances {
    $path = Get-GuiReadyDatabaseStatePath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if (-not $raw.Trim()) { return @() }
        $o = $raw | ConvertFrom-Json
        return @($o.Instances)
    } catch {
        Write-Log ('实例记录读取失败: ' + $_.Exception.Message) 'WARN'
        return @()
    }
}

function Save-GuiReadyDbInstances {
    param([object[]]$Instances = @())
    $path = Get-GuiReadyDatabaseStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $o = [ordered]@{
        Updated   = (Get-Date).ToString('o')
        Instances = @($Instances)
    }
    $json = $o | ConvertTo-Json -Depth 8
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-GuiReadyDbInstance {
    param([string]$Id)
    foreach ($i in (Read-GuiReadyDbInstances)) {
        if (-not $Id -or [string]$i.Id -eq $Id) { return $i }
    }
    return $null
}

function Remove-GuiReadyDbInstanceRecord {
    param([Parameter(Mandatory = $true)][string]$Id)
    $keep = @()
    foreach ($i in (Read-GuiReadyDbInstances)) {
        if ([string]$i.Id -ne $Id) { $keep += $i }
    }
    Save-GuiReadyDbInstances -Instances $keep
}

# ---------------------------------------------------------------- 密码
function Protect-GuiReadyDbSecret {
    param([Parameter(Mandatory = $true)][string]$Plain)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [Convert]::ToBase64String($enc)
    } catch {
        Write-Log ('密码加密失败（不落盘）：' + $_.Exception.Message) 'WARN'
        return ''
    }
}

function Unprotect-GuiReadyDbSecret {
    param([string]$Cipher)
    if (-not $Cipher) { return '' }
    try {
        $bytes = [Convert]::FromBase64String($Cipher)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch {
        return ''
    }
}

# ---------------------------------------------------------------- 下载 / 解压
function Save-GuiReadyDbFile {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$OutFile)
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    $curl = 'curl.exe'
    if (Get-Command Get-GuiReadyCurlPath -ErrorAction SilentlyContinue) { $curl = Get-GuiReadyCurlPath }
    Write-Log ('下载 {0}' -f $Url) 'STEP'
    $start = Get-Date
    & $curl -L --ssl-no-revoke --fail --retry 2 --retry-delay 3 --connect-timeout 20 --max-time 3600 -sS -o $OutFile $Url
    $code = $LASTEXITCODE
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $OutFile)) { throw ('下载失败（curl 退出码 {0}）' -f $code) }
    $len = (Get-Item -LiteralPath $OutFile).Length
    if ($len -lt 1024 * 1024) { throw ('下载到的文件只有 {0:N1} MB，不像完整安装包' -f ($len / 1MB)) }
    Write-Log ('下载完成 {0:N1} MB，用时 {1:N1} 秒' -f ($len / 1MB), ((Get-Date) - $start).TotalSeconds) 'OK'
}

function Expand-GuiReadyDbZip {
    param([Parameter(Mandatory = $true)][string]$ZipPath, [Parameter(Mandatory = $true)][string]$TargetDir)
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch { }
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('scm-db-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $stage)
        $topDirs  = @(Get-ChildItem -LiteralPath $stage -Directory -Force)
        $topFiles = @(Get-ChildItem -LiteralPath $stage -File -Force)
        $src = $stage
        # binaries zip 里只有一层 pgsql\
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

# ---------------------------------------------------------------- 端口
function Test-GuiReadyPortInUse {
    param([Parameter(Mandatory = $true)][int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(400)) { return $false }   # 连不上 = 端口空着
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-GuiReadyFreePort {
    param([int]$Start = 5432)
    for ($p = $Start; $p -lt $Start + 50; $p++) {
        if (-not (Test-GuiReadyPortInUse -Port $p)) {
            # 还要排除已被我们记录的实例（服务没起来但端口已占位）
            $used = $false
            foreach ($i in (Read-GuiReadyDbInstances)) { if ([int]$i.Port -eq $p) { $used = $true; break } }
            if (-not $used) { return $p }
        }
    }
    return $Start
}

# ---------------------------------------------------------------- 安装
function Install-GuiReadyPostgres {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$DryRun
    )
    $e = Get-GuiReadyPostgresEntry -Version $Version
    if (-not $e) { throw ('清单里没有 PostgreSQL ' + $Version) }
    $target = Get-GuiReadyPostgresVersionDir $Version

    if (Test-Path -LiteralPath (Join-Path $target 'bin\initdb.exe')) {
        Write-Log ('PostgreSQL {0} 已经解压好了：{1}' -f $Version, $target) 'WARN'
        return [pscustomobject]@{ Kind = 'version'; Version = $Version; Installed = $true; InstalledNow = $false; BinDir = (Get-GuiReadyPostgresBin $Version) }
    }
    if ($DryRun) {
        Write-Log ('[试运行] 将下载 {0}' -f $e.Url) 'DRY'
        Write-Log ('[试运行] 解压到 {0}' -f $target) 'DRY'
        return [pscustomobject]@{ Kind = 'version'; Version = $Version; Installed = $false; DryRun = $true }
    }

    $zip = Join-Path (Join-Path ([System.IO.Path]::GetTempPath()) 'scm-database') ('postgresql-{0}.zip' -f $Version)
    Save-GuiReadyDbFile -Url $e.Url -OutFile $zip
    Write-Log ('解压到 {0}（约 1-2 分钟）' -f $target) 'STEP'
    Expand-GuiReadyDbZip -ZipPath $zip -TargetDir $target
    try { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } catch { }

    $bin = Get-GuiReadyPostgresBin $Version
    if (-not (Test-Path -LiteralPath (Join-Path $bin 'initdb.exe'))) { throw ('解压后没找到 initdb.exe：' + $bin) }
    $v = Invoke-GuiReadyPgTool -Exe (Join-Path $bin 'postgres.exe') -Arguments '--version' -TimeoutMs 20000
    if ($v.Out) { Write-Log ('版本探测：' + $v.Out.Trim()) 'OK' }

    return [pscustomobject]@{ Kind = 'version'; Version = $Version; Installed = $true; InstalledNow = $true; BinDir = $bin }
}

# ---------------------------------------------------------------- 初始化实例
function Initialize-GuiReadyPostgres {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [int]$Port = 5432,
        # 试运行时允许为空，真正初始化必须给密码
        [string]$Password = '',
        [string]$InstanceName = '',
        [switch]$DryRun
    )
    if (-not (Test-GuiReadyPostgresInstalled -Version $Version)) { throw ('PostgreSQL {0} 还没解压，先安装版本' -f $Version) }
    if (-not $DryRun -and $Password.Length -lt 6) { throw '密码至少 6 位（PostgreSQL 默认要求，太短会初始化失败）' }
    if ($Port -lt 1024 -or $Port -gt 65535) { throw '端口要在 1024-65535 之间' }
    if (Test-GuiReadyPortInUse -Port $Port) { throw ('端口 {0} 已被占用，换一个' -f $Port) }

    $dataDir = Join-Path (Get-GuiReadyDatabaseDataRoot) ('{0}-{1}' -f $Version, $Port)
    $id = ('pg-{0}-{1}' -f $Version, $Port)
    $service = ('SCM-PostgreSQL-{0}' -f $Port)
    $name = if ($InstanceName) { $InstanceName } else { ('PostgreSQL {0} ({1})' -f $Version, $Port) }

    if ((Test-Path -LiteralPath $dataDir) -and @(Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        throw ('数据目录已存在且非空：' + $dataDir)
    }

    $bin = Get-GuiReadyPostgresBin $Version
    if ($DryRun) {
        Write-Log ('[试运行] initdb -D "{0}" -U postgres --auth=scram-sha-256 --encoding=UTF8 --locale=C --pwfile=<临时文件>' -f $dataDir) 'DRY'
        Write-Log ('[试运行] 追加 postgresql.conf：port={0}、listen_addresses=localhost、开启 logging_collector' -f $Port) 'DRY'
        Write-Log ('[试运行] 服务名 {0}，账号 NT AUTHORITY\NetworkService' -f $service) 'DRY'
        return [pscustomobject]@{ Kind = 'instance'; Id = $id; DryRun = $true }
    }

    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    $pwFile = Join-Path ([System.IO.Path]::GetTempPath()) ('scm-pg-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    [System.IO.File]::WriteAllText($pwFile, $Password, (New-Object System.Text.UTF8Encoding($false)))
    try {
        Write-Log '正在 initdb（约 10-30 秒）…' 'STEP'
        $r = Invoke-GuiReadyPgTool -Exe (Join-Path $bin 'initdb.exe') `
                -Arguments ('-D "{0}" -U postgres --auth=scram-sha-256 --encoding=UTF8 --locale=C --pwfile="{1}"' -f $dataDir, $pwFile)
        if ($r.Code -ne 0) {
            $tail = ((@($r.Err, $r.Out) -join "`n") -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' / '
            throw ('initdb 失败（退出码 {0}）：{1}' -f $r.Code, $tail)
        }
        Write-Log 'initdb 完成' 'OK'
    } finally {
        try { Remove-Item -LiteralPath $pwFile -Force -ErrorAction SilentlyContinue } catch { }
    }

    # 端口与日志：写进 postgresql.conf，服务和手工启动都用这套
    $conf = Join-Path $dataDir 'postgresql.conf'
    $append = @(
        ''
        '# ---------------- SCM 追加 ----------------'
        ('port = ' + $Port)
        "listen_addresses = 'localhost'"
        'logging_collector = on'
        "log_directory = 'log'"
        "log_filename = 'postgresql-%Y-%m-%d.log'"
    ) -join "`r`n"
    try { Add-Content -LiteralPath $conf -Value $append -Encoding UTF8 } catch { Write-Log ('写 postgresql.conf 失败: ' + $_.Exception.Message) 'WARN' }

    # 服务账号是 NetworkService，数据目录必须让它可写
    try {
        & icacls.exe $dataDir /grant '*S-1-5-20:(OI)(CI)F' /T /C /Q 2>$null | Out-Null
    } catch { Write-Log ('给 NetworkService 授权失败: ' + $_.Exception.Message) 'WARN' }

    $instances = @(Read-GuiReadyDbInstances)
    $instances += [pscustomobject]@{
        Id        = $id
        Engine    = 'postgresql'
        Name      = $name
        Version   = $Version
        Port      = $Port
        DataDir   = $dataDir
        Service   = $service
        Account   = 'NT AUTHORITY\NetworkService'
        DbUser    = 'postgres'
        Password  = (Protect-GuiReadyDbSecret -Plain $Password)
        CreatedAt = (Get-Date).ToString('o')
    }
    Save-GuiReadyDbInstances -Instances $instances
    Write-Log ('实例已登记：{0}（{1}）' -f $name, $id) 'OK'

    return [pscustomobject]@{
        Kind = 'instance'; Id = $id; Version = $Version; Port = $Port; Service = $service
        DataDir = $dataDir; ServiceState = 'NotInstalled'
    }
}

# ---------------------------------------------------------------- 服务
function Register-GuiReadyDbService {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [switch]$Start,
        [switch]$DryRun
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    if (-not (Test-Path -LiteralPath (Join-Path $inst.DataDir 'PG_VERSION'))) { throw ('数据目录没初始化：' + $inst.DataDir) }

    $pgCtl = Join-Path (Get-GuiReadyPostgresBin ([string]$inst.Version)) 'pg_ctl.exe'
    $svc = [string]$inst.Service
    $existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log ('服务 {0} 已存在（{1}），不重复注册' -f $svc, $existing.Status) 'WARN'
    } else {
        if ($DryRun) {
            Write-Log ('[试运行] pg_ctl register -N {0} -D "{1}" -S auto -U "NT AUTHORITY\NetworkService"' -f $svc, $inst.DataDir) 'DRY'
            if ($Start) { Write-Log ('[试运行] Start-Service {0}' -f $svc) 'DRY' }
            return [pscustomobject]@{ Kind = 'service'; Id = $Id; Service = $svc; Registered = $false; DryRun = $true }
        }
        Write-Log ('注册服务 {0}（账号 NetworkService）' -f $svc) 'STEP'
        $r = Invoke-GuiReadyPgTool -Exe $pgCtl -Arguments ('register -N "{0}" -D "{1}" -S auto -U "NT AUTHORITY\NetworkService"' -f $svc, $inst.DataDir) -TimeoutMs 60000
        if ($r.Code -ne 0) {
            throw ('服务注册失败（需要管理员）：{0}' -f ((($r.Err + $r.Out) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / '))
        }
        Write-Log ('服务已注册：' + $svc) 'OK'
    }

    if ($Start) {
        if ($DryRun) { return [pscustomobject]@{ Kind = 'service'; Id = $Id; Service = $svc; Registered = $true; DryRun = $true } }
        try {
            Write-Log ('启动服务 {0}' -f $svc) 'STEP'
            Start-Service -Name $svc -ErrorAction Stop
            $ok = $false
            for ($i = 0; $i -lt 30; $i++) {
                Start-Sleep -Milliseconds 500
                if (Test-GuiReadyPortInUse -Port ([int]$inst.Port)) { $ok = $true; break }
            }
            if ($ok) { Write-Log ('服务已启动，端口 {0} 可连接' -f $inst.Port) 'OK' }
            else { Write-Log ('服务已启动，但端口 {0} 30 秒内没通，去看日志：{1}\log' -f $inst.Port, $inst.DataDir) 'WARN' }
        } catch {
            throw ('服务启动失败：' + $_.Exception.Message)
        }
    }

    $state = 'Unknown'
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) { $state = [string]$s.Status }
    return [pscustomobject]@{ Kind = 'service'; Id = $Id; Service = $svc; Registered = $true; ServiceState = $state; DryRun = $false }
}

function Set-GuiReadyDbServiceState {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [ValidateSet('Start', 'Stop', 'Restart')][string]$Action = 'Start'
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    $svc = [string]$inst.Service
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { throw ('服务 {0} 还没注册' -f $svc) }

    if ($Action -eq 'Stop') {
        Stop-Service -Name $svc -Force -ErrorAction Stop
        Write-Log ('已停止服务 ' + $svc) 'OK'
    } elseif ($Action -eq 'Restart') {
        Restart-Service -Name $svc -Force -ErrorAction Stop
        Write-Log ('已重启服务 ' + $svc) 'OK'
    } else {
        Start-Service -Name $svc -ErrorAction Stop
        Write-Log ('已启动服务 ' + $svc) 'OK'
    }
    Start-Sleep -Milliseconds 600
    $s2 = Get-Service -Name $svc -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Kind = 'service'; Id = $Id; Service = $svc; ServiceState = $(if ($s2) { [string]$s2.Status } else { 'Unknown' }) }
}

function Unregister-GuiReadyDbService {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [switch]$RemoveData,
        [switch]$DryRun
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    $svc = [string]$inst.Service
    $isMysql = ([string]$inst.Engine -eq 'mysql')
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue

    if ($DryRun) {
        if ($s) { Write-Log ('[试运行] 停止并注销服务 {0}' -f $svc) 'DRY' }
        if ($RemoveData) { Write-Log ('[试运行] 删除数据目录 {0}' -f $inst.DataDir) 'DRY' }
        Write-Log ('[试运行] 删除实例记录 ' + $Id) 'DRY'
        return [pscustomobject]@{ Kind = 'service'; Id = $Id; DryRun = $true }
    }

    if ($s) {
        try {
            if ($s.Status -ne 'Stopped') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
        } catch { }
        if ($isMysql) {
            $mysqld = Join-Path (Get-GuiReadyMySQLBin ([string]$inst.Version)) 'mysqld.exe'
            $r = Invoke-GuiReadyPgTool -Exe $mysqld -Arguments ('--remove {0}' -f $svc) -TimeoutMs 60000
        } else {
            $pgCtl = Join-Path (Get-GuiReadyPostgresBin ([string]$inst.Version)) 'pg_ctl.exe'
            $r = Invoke-GuiReadyPgTool -Exe $pgCtl -Arguments ('unregister -N "{0}"' -f $svc) -TimeoutMs 60000
        }
        if ($r.Code -ne 0) {
            # 各自的卸载器失败时，统一退回 sc delete
            & sc.exe delete $svc 2>$null | Out-Null
        }
        $still = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($still) { throw ('服务 {0} 还在，可能没权限删除（需要管理员）' -f $svc) }
        Write-Log ('服务已注销：' + $svc) 'OK'
    }

    if ($RemoveData -and (Test-Path -LiteralPath $inst.DataDir)) {
        Remove-Item -LiteralPath $inst.DataDir -Recurse -Force -ErrorAction Stop
        Write-Log ('已删除数据目录 ' + $inst.DataDir) 'OK'
    }
    # MySQL 的 my.ini 放在数据目录旁边，跟着一起删
    if ($RemoveData -and $isMysql) {
        $ini = [string]$inst.IniFile
        if ($ini -and (Test-Path -LiteralPath $ini)) {
            Remove-Item -LiteralPath $ini -Force -ErrorAction SilentlyContinue
            Write-Log ('已删除 ' + $ini) 'OK'
        }
    }
    Remove-GuiReadyDbInstanceRecord -Id $Id
    Write-Log ('实例记录已删除 ' + $Id) 'OK'
    return [pscustomobject]@{ Kind = 'service'; Id = $Id; Service = $svc; Removed = $true }
}

# ---------------------------------------------------------------- 备份
function Backup-GuiReadyPostgres {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Database = 'postgres',
        [switch]$DryRun
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    $svc = Get-Service -Name ([string]$inst.Service) -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        if (-not (Test-GuiReadyPortInUse -Port ([int]$inst.Port))) { throw '服务没在运行，先启动再备份' }
    }

    $dir = Join-Path (Join-Path (Get-GuiReadyRuntimeRootBase) 'backup') 'postgresql'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ('{0}-{1}.dump' -f $inst.Id, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    if ($DryRun) {
        Write-Log ('[试运行] pg_dump -h 127.0.0.1 -p {0} -U postgres -Fc -d {1} -f "{2}"' -f $inst.Port, $Database, $file) 'DRY'
        return [pscustomobject]@{ Kind = 'backup'; Id = $Id; File = $file; DryRun = $true }
    }

    $pw = Unprotect-GuiReadyDbSecret -Cipher ([string]$inst.Password)
    if (-not $pw) { throw '实例密码解不开（换过机器/账号？），无法自动备份' }
    $pgDump = Join-Path (Get-GuiReadyPostgresBin ([string]$inst.Version)) 'pg_dump.exe'
    Write-Log ('备份 {0} 的库 {1} → {2}' -f $inst.Id, $Database, $file) 'STEP'
    $r = Invoke-GuiReadyPgTool -Exe $pgDump -Env @{ PGPASSWORD = $pw } -TimeoutMs 1800000 `
            -Arguments ('-h 127.0.0.1 -p {0} -U postgres -Fc -d {1} -f "{2}"' -f $inst.Port, $Database, $file)
    if ($r.Code -ne 0) { throw ('pg_dump 失败（退出码 {0}）：{1}' -f $r.Code, (($r.Err -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' / ')) }
    $size = (Get-Item -LiteralPath $file).Length
    Write-Log ('备份完成 {0:N1} MB' -f ($size / 1MB)) 'OK'
    return [pscustomobject]@{ Kind = 'backup'; Id = $Id; File = $file; SizeMB = [math]::Round($size / 1MB, 2) }
}

# ---------------------------------------------------------------- MySQL 8
function Install-GuiReadyMySQL {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$DryRun
    )
    $entry = $null
    foreach ($e in (Get-GuiReadyMySQLCatalog)) { if ($e.Version -eq $Version) { $entry = $e; break } }
    if (-not $entry) { throw ('清单里没有 MySQL ' + $Version) }
    $target = Get-GuiReadyMySQLVersionDir $Version

    if (Test-Path -LiteralPath (Join-Path $target 'bin\mysqld.exe')) {
        Write-Log ('MySQL {0} 已经解压好了：{1}' -f $Version, $target) 'WARN'
        return [pscustomobject]@{ Kind = 'version'; Engine = 'mysql'; Version = $Version; Installed = $true; InstalledNow = $false; BinDir = (Get-GuiReadyMySQLBin $Version) }
    }
    if ($DryRun) {
        Write-Log ('[试运行] 将下载 {0}' -f $entry.Url) 'DRY'
        Write-Log ('[试运行] 解压到 {0}' -f $target) 'DRY'
        return [pscustomobject]@{ Kind = 'version'; Engine = 'mysql'; Version = $Version; Installed = $false; DryRun = $true }
    }

    $zip = Join-Path (Join-Path ([System.IO.Path]::GetTempPath()) 'scm-database') ('mysql-{0}.zip' -f $Version)
    Save-GuiReadyDbFile -Url $entry.Url -OutFile $zip
    Write-Log ('解压到 {0}（约 1-2 分钟）' -f $target) 'STEP'
    Expand-GuiReadyDbZip -ZipPath $zip -TargetDir $target
    try { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } catch { }

    $bin = Get-GuiReadyMySQLBin $Version
    if (-not (Test-Path -LiteralPath (Join-Path $bin 'mysqld.exe'))) { throw ('解压后没找到 mysqld.exe：' + $bin) }
    $v = Invoke-GuiReadyPgTool -Exe (Join-Path $bin 'mysqld.exe') -Arguments '--version' -TimeoutMs 20000
    if ($v.Out) { Write-Log ('版本探测：' + $v.Out.Trim()) 'OK' }
    # MySQL 的 Windows 包依赖 VC++ 2015-2022 x64 运行库，缺了 mysqld 起不来
    $vc = Join-Path $env:windir 'System32\vcruntime140_1.dll'
    if (-not (Test-Path -LiteralPath $vc)) {
        Write-Log '没检测到 VC++ 2015-2022 x64 运行库（vcruntime140_1.dll），mysqld 可能起不来；到「环境补全」页补一下。' 'WARN'
    }

    return [pscustomobject]@{ Kind = 'version'; Engine = 'mysql'; Version = $Version; Installed = $true; InstalledNow = $true; BinDir = $bin }
}

function Get-GuiReadyMySQLIniPath {
    param([Parameter(Mandatory = $true)][string]$Id)
    return (Join-Path (Get-GuiReadyDatabaseDataRoot) ($Id + '.ini'))
}

function Initialize-GuiReadyMySQL {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [int]$Port = 3306,
        [string]$Password = '',
        [string]$InstanceName = '',
        [switch]$DryRun
    )
    if (-not (Test-GuiReadyMySQLInstalled -Version $Version)) { throw ('MySQL {0} 还没解压，先安装版本' -f $Version) }
    if (-not $DryRun -and $Password.Length -lt 6) { throw '密码至少 6 位' }
    if ($Port -lt 1024 -or $Port -gt 65535) { throw '端口要在 1024-65535 之间' }
    if (Test-GuiReadyPortInUse -Port $Port) { throw ('端口 {0} 已被占用，换一个' -f $Port) }

    $dataDir = Join-Path (Get-GuiReadyDatabaseDataRoot) ('{0}-{1}' -f $Version, $Port)
    $id = ('my-{0}-{1}' -f $Version, $Port)
    $service = ('SCM-MySQL-{0}' -f $Port)
    $name = if ($InstanceName) { $InstanceName } else { ('MySQL {0} ({1})' -f $Version, $Port) }
    $ini = Get-GuiReadyMySQLIniPath $id

    if ((Test-Path -LiteralPath $dataDir) -and @(Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        throw ('数据目录已存在且非空：' + $dataDir)
    }

    $bin = Get-GuiReadyMySQLBin $Version
    if ($DryRun) {
        Write-Log ('[试运行] mysqld --defaults-file="{0}" --initialize-insecure（root 空密码建库）' -f $ini) 'DRY'
        Write-Log ('[试运行] 临时启动 mysqld → 设置 root 密码 → mysqladmin shutdown' ) 'DRY'
        Write-Log ('[试运行] 数据目录 {0}' -f $dataDir) 'DRY'
        return [pscustomobject]@{ Kind = 'instance'; Engine = 'mysql'; Id = $id; DryRun = $true }
    }

    if (-not (Test-Path -LiteralPath (Get-GuiReadyDatabaseDataRoot))) {
        New-Item -ItemType Directory -Path (Get-GuiReadyDatabaseDataRoot) -Force | Out-Null
    }
    # my.ini 放在数据目录旁边：--initialize 要求 datadir 是空的
    # 注意：MySQL 的选项文件会解析 \s \t \n 这类转义，Windows 路径必须写正斜杠
    $baseDirSlash = (Get-GuiReadyMySQLVersionDir $Version).TrimEnd('\') -replace '\\', '/'
    $dataDirSlash = $dataDir.TrimEnd('\') -replace '\\', '/'
    $errLogSlash  = (Join-Path $dataDir 'mysql-error.log') -replace '\\', '/'
    $iniText = @(
        '[mysqld]'
        ('basedir="{0}"' -f $baseDirSlash)
        ('datadir="{0}"' -f $dataDirSlash)
        ('port={0}' -f $Port)
        'bind-address=127.0.0.1'
        'character-set-server=utf8mb4'
        'collation-server=utf8mb4_0900_ai_ci'
        'default-storage-engine=INNODB'
        ('log-error="{0}"' -f $errLogSlash)
        'mysqlx=0'
        '[client]'
        ('port={0}' -f $Port)
        'host=127.0.0.1'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($ini, $iniText, (New-Object System.Text.UTF8Encoding($false)))

    $mysqld = Join-Path $bin 'mysqld.exe'
    Write-Log '正在初始化 MySQL 数据目录（约 20-60 秒）…' 'STEP'
    $r = Invoke-GuiReadyPgTool -Exe $mysqld -TimeoutMs 600000 `
            -Arguments ('--defaults-file="{0}" --initialize-insecure' -f $ini)
    if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $dataDir 'mysql'))) {
        $tail = ((@($r.Err, $r.Out) -join "`n") -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' / '
        throw ('MySQL 初始化失败（退出码 {0}）：{1}' -f $r.Code, $tail)
    }
    Write-Log '数据目录初始化完成' 'OK'

    # 用临时进程（不是服务）把 root 密码设好：这一步不需要管理员
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $mysqld
        $psi.Arguments = ('--defaults-file="{0}"' -f $ini)
        $psi.UseShellExecute = $true
        $psi.WindowStyle = 'Hidden'
        $proc = [System.Diagnostics.Process]::Start($psi)
        Write-Log '临时启动 mysqld 设置 root 密码…' 'STEP'

        $up = $false
        for ($i = 0; $i -lt 90; $i++) {
            Start-Sleep -Milliseconds 1000
            if ($proc.HasExited) { break }
            if (Test-GuiReadyPortInUse -Port $Port) { $up = $true; break }
        }
        if (-not $up) {
            $errLog = Join-Path $dataDir 'mysql-error.log'
            $tail = ''
            if (Test-Path -LiteralPath $errLog) {
                $tail = ((Get-Content -LiteralPath $errLog -Tail 6 -ErrorAction SilentlyContinue) -join ' / ')
            }
            throw ('mysqld 没有起来：{0}' -f $tail)
        }

        $escaped = $Password.Replace("'", "''")
        $mysql = Join-Path $bin 'mysql.exe'
        $sql = "ALTER USER 'root'@'localhost' IDENTIFIED BY '{0}';" -f $escaped
        $q = Invoke-GuiReadyPgTool -Exe $mysql -TimeoutMs 30000 `
                -Arguments ('--defaults-file="{0}" -u root --protocol=TCP --connect-timeout=10 -e "{1}"' -f $ini, $sql.Replace('"', '\"'))
        if ($q.Code -ne 0) {
            throw ('设置 root 密码失败：{0}' -f (($q.Err -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' / '))
        }
        Write-Log 'root 密码已设置' 'OK'

        $mysqladmin = Join-Path $bin 'mysqladmin.exe'
        $s = Invoke-GuiReadyPgTool -Exe $mysqladmin -TimeoutMs 60000 -Env @{ MYSQL_PWD = $Password } `
                -Arguments ('--defaults-file="{0}" -u root --protocol=TCP shutdown' -f $ini)
        if ($s.Code -ne 0) { Write-Log ('mysqladmin shutdown 返回 {0}，稍后由服务接管' -f $s.Code) 'WARN' }
        try { $proc.WaitForExit(20000) | Out-Null } catch { }
    } finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
    }

    $instances = @(Read-GuiReadyDbInstances)
    $instances += [pscustomobject]@{
        Id        = $id
        Engine    = 'mysql'
        Name      = $name
        Version   = $Version
        Port      = $Port
        DataDir   = $dataDir
        IniFile   = $ini
        Service   = $service
        Account   = 'LocalSystem'
        DbUser    = 'root'
        Password  = (Protect-GuiReadyDbSecret -Plain $Password)
        CreatedAt = (Get-Date).ToString('o')
    }
    Save-GuiReadyDbInstances -Instances $instances
    Write-Log ('实例已登记：{0}（{1}）' -f $name, $id) 'OK'

    return [pscustomobject]@{
        Kind = 'instance'; Engine = 'mysql'; Id = $id; Version = $Version; Port = $Port
        Service = $service; DataDir = $dataDir; ServiceState = 'NotInstalled'
    }
}

function Register-GuiReadyMySQLService {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [switch]$Start,
        [switch]$DryRun
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    if (-not (Test-Path -LiteralPath (Join-Path $inst.DataDir 'mysql'))) { throw ('数据目录没初始化：' + $inst.DataDir) }

    $mysqld = Join-Path (Get-GuiReadyMySQLBin ([string]$inst.Version)) 'mysqld.exe'
    $svc = [string]$inst.Service
    $ini = [string]$inst.IniFile
    if (-not $ini) { $ini = Get-GuiReadyMySQLIniPath $Id }

    $existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log ('服务 {0} 已存在（{1}），不重复注册' -f $svc, $existing.Status) 'WARN'
    } else {
        if ($DryRun) {
            Write-Log ('[试运行] mysqld --install {0} --defaults-file="{1}"' -f $svc, $ini) 'DRY'
            if ($Start) { Write-Log ('[试运行] Start-Service {0}' -f $svc) 'DRY' }
            return [pscustomobject]@{ Kind = 'service'; Engine = 'mysql'; Id = $Id; Service = $svc; Registered = $false; DryRun = $true }
        }
        Write-Log ('注册 MySQL 服务 {0}' -f $svc) 'STEP'
        $r = Invoke-GuiReadyPgTool -Exe $mysqld -TimeoutMs 120000 -Arguments ('--install {0} --defaults-file="{1}"' -f $svc, $ini)
        if ($r.Code -ne 0) {
            $tail = ((@($r.Err, $r.Out) -join "`n") -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / '
            throw ('服务注册失败（需要管理员）：{0}' -f $tail)
        }
        if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
            throw ('mysqld --install 返回 0，但服务 {0} 不存在（可能没权限）' -f $svc)
        }
        Write-Log ('服务已注册：' + $svc) 'OK'
    }

    if ($Start) {
        if ($DryRun) { return [pscustomobject]@{ Kind = 'service'; Engine = 'mysql'; Id = $Id; Service = $svc; Registered = $true; DryRun = $true } }
        Write-Log ('启动服务 {0}' -f $svc) 'STEP'
        Start-Service -Name $svc -ErrorAction Stop
        $ok = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-GuiReadyPortInUse -Port ([int]$inst.Port)) { $ok = $true; break }
        }
        if ($ok) { Write-Log ('服务已启动，端口 {0} 可连接' -f $inst.Port) 'OK' }
        else { Write-Log ('服务已启动，但端口 {0} 30 秒内没通，去看 {1}\mysql-error.log' -f $inst.Port, $inst.DataDir) 'WARN' }
    }

    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Kind = 'service'; Engine = 'mysql'; Id = $Id; Service = $svc; Registered = $true
        ServiceState = $(if ($s) { [string]$s.Status } else { 'Unknown' }); DryRun = $false
    }
}

function Backup-GuiReadyMySQL {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Database = 'mysql',
        [switch]$DryRun
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    $svc = Get-Service -Name ([string]$inst.Service) -ErrorAction SilentlyContinue
    if ((-not $svc -or $svc.Status -ne 'Running') -and -not (Test-GuiReadyPortInUse -Port ([int]$inst.Port))) {
        throw '服务没在运行，先启动再备份'
    }
    if (-not $Database) { $Database = 'mysql' }

    $dir = Join-Path (Join-Path (Get-GuiReadyRuntimeRootBase) 'backup') 'mysql'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ('{0}-{1}.sql' -f $inst.Id, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    if ($DryRun) {
        Write-Log ('[试运行] mysqldump -u root -h 127.0.0.1 -P {0} --single-transaction --routines --events --databases {1} --result-file="{2}"' -f $inst.Port, $Database, $file) 'DRY'
        return [pscustomobject]@{ Kind = 'backup'; Engine = 'mysql'; Id = $Id; File = $file; DryRun = $true }
    }

    $pw = Unprotect-GuiReadyDbSecret -Cipher ([string]$inst.Password)
    if (-not $pw) { throw '实例密码解不开（换过机器/账号？），无法自动备份' }
    $dump = Join-Path (Get-GuiReadyMySQLBin ([string]$inst.Version)) 'mysqldump.exe'
    Write-Log ('备份 {0} 的库 {1} → {2}' -f $inst.Id, $Database, $file) 'STEP'
    $r = Invoke-GuiReadyPgTool -Exe $dump -Env @{ MYSQL_PWD = $pw } -TimeoutMs 1800000 `
            -Arguments ('--defaults-file="{0}" -u root -h 127.0.0.1 --protocol=TCP --single-transaction --routines --events --databases {1} --result-file="{2}"' -f (Get-GuiReadyMySQLIniPath $Id), $Database, $file)
    if ($r.Code -ne 0) {
        $tail = (($r.Err -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' / ')
        throw ('mysqldump 失败（退出码 {0}）：{1}' -f $r.Code, $tail)
    }
    $size = (Get-Item -LiteralPath $file).Length
    Write-Log ('备份完成 {0:N1} MB' -f ($size / 1MB)) 'OK'
    return [pscustomobject]@{ Kind = 'backup'; Engine = 'mysql'; Id = $Id; File = $file; SizeMB = [math]::Round($size / 1MB, 2) }
}

# ---------------------------------------------------------------- 统一入口
function Resolve-GuiReadyDatabaseEntry {
    param([Parameter(Mandatory = $true)][string]$Engine, [Parameter(Mandatory = $true)][string]$Version)
    if ($Engine -eq 'mysql') {
        foreach ($e in (Get-GuiReadyMySQLCatalog)) { if ($e.Version -eq $Version) { return $e } }
    } else {
        foreach ($e in (Get-GuiReadyPostgresCatalog)) { if ($e.Version -eq $Version) { return $e } }
    }
    return $null
}

function Install-GuiReadyDatabaseEngine {
    param(
        [Parameter(Mandatory = $true)][string]$Engine,
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$DryRun
    )
    if ($Engine -eq 'mysql') { return (Install-GuiReadyMySQL -Version $Version -DryRun:$DryRun) }
    return (Install-GuiReadyPostgres -Version $Version -DryRun:$DryRun)
}

function Initialize-GuiReadyDatabaseInstance {
    param(
        [Parameter(Mandatory = $true)][string]$Engine,
        [Parameter(Mandatory = $true)][string]$Version,
        [int]$Port = 0,
        [string]$Password = '',
        [switch]$DryRun
    )
    if ($Port -le 0) {
        if ($Engine -eq 'mysql') { $Port = Get-GuiReadyFreePort -Start 3306 }
        else { $Port = Get-GuiReadyFreePort -Start 5432 }
    }
    if ($Engine -eq 'mysql') {
        return (Initialize-GuiReadyMySQL -Version $Version -Port $Port -Password $Password -DryRun:$DryRun)
    }
    return (Initialize-GuiReadyPostgres -Version $Version -Port $Port -Password $Password -DryRun:$DryRun)
}

function Register-GuiReadyDatabaseService {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [switch]$Start,
        [switch]$DryRun
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    if ([string]$inst.Engine -eq 'mysql') { return (Register-GuiReadyMySQLService -Id $Id -Start:$Start -DryRun:$DryRun) }
    return (Register-GuiReadyDbService -Id $Id -Start:$Start -DryRun:$DryRun)
}

function Backup-GuiReadyDatabase {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Database = '',
        [switch]$DryRun
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    if ([string]$inst.Engine -eq 'mysql') {
        if (-not $Database) { $Database = 'mysql' }
        return (Backup-GuiReadyMySQL -Id $Id -Database $Database -DryRun:$DryRun)
    }
    if (-not $Database) { $Database = 'postgres' }
    return (Backup-GuiReadyPostgres -Id $Id -Database $Database -DryRun:$DryRun)
}

# ---------------------------------------------------------------- 建库 / 还原
function Test-GuiReadyDatabaseName {
    # 只放行字母 / 数字 / 下划线 / 短横线：库名会拼进 SQL，不做白名单就等于开注入口子
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $t = $Name.Trim()
    if ($t.Length -gt 63) { return $false }
    return ($t -match '^[A-Za-z0-9_][A-Za-z0-9_\-]{0,62}$')
}

function New-GuiReadyDatabase {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Database,
        [switch]$DryRun
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    $name = ([string]$Database).Trim()
    if (-not (Test-GuiReadyDatabaseName $name)) {
        throw '库名只能用字母 / 数字 / 下划线 / 短横线，且以字母数字下划线开头（最长 63）'
    }
    $isMysql = ([string]$inst.Engine -eq 'mysql')
    $svc = Get-Service -Name ([string]$inst.Service) -ErrorAction SilentlyContinue
    if ((-not $svc -or $svc.Status -ne 'Running') -and -not (Test-GuiReadyPortInUse -Port ([int]$inst.Port))) {
        throw '服务没在运行，先启动再建库'
    }

    if ($isMysql) {
        $sql = 'CREATE DATABASE IF NOT EXISTS `' + $name + '` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;'
        $tool = Join-Path (Get-GuiReadyMySQLBin ([string]$inst.Version)) 'mysql.exe'
        $toolArgs = ('--defaults-file="{0}" -u root --protocol=TCP -e "{1}"' -f (Get-GuiReadyMySQLIniPath $Id), $sql)
    } else {
        $tool = Join-Path (Get-GuiReadyPostgresBin ([string]$inst.Version)) 'createdb.exe'
        $toolArgs = ('-h 127.0.0.1 -p {0} -U postgres "{1}"' -f $inst.Port, $name)
    }

    if ($DryRun) {
        Write-Log ('[试运行] ' + (Split-Path -Leaf $tool) + ' ' + $toolArgs) 'DRY'
        return [pscustomobject]@{ Kind = 'database'; Engine = [string]$inst.Engine; Id = $Id; Database = $name; DryRun = $true }
    }

    $pw = Unprotect-GuiReadyDbSecret -Cipher ([string]$inst.Password)
    if (-not $pw) { throw '实例密码解不开（换过机器/账号？），无法自动建库' }
    Write-Log ('在 {0} 上建库 {1}' -f $inst.Id, $name) 'STEP'
    if ($isMysql) {
        $r = Invoke-GuiReadyPgTool -Exe $tool -Arguments $toolArgs -TimeoutMs 120000 -Env @{ MYSQL_PWD = $pw }
    } else {
        $r = Invoke-GuiReadyPgTool -Exe $tool -Arguments $toolArgs -TimeoutMs 120000 -Env @{ PGPASSWORD = $pw }
    }
    if ($r.Code -ne 0) {
        $tail = ((@($r.Err, $r.Out) -join "`n") -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' / '
        throw ('建库失败（退出码 {0}）：{1}' -f $r.Code, $tail)
    }
    Write-Log ('库 {0} 已就绪' -f $name) 'OK'
    return [pscustomobject]@{ Kind = 'database'; Engine = [string]$inst.Engine; Id = $Id; Database = $name; Created = $true }
}

function Restore-GuiReadyDatabase {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$File,
        [string]$Database = '',
        [switch]$DryRun
    )
    $inst = Get-GuiReadyDbInstance -Id $Id
    if (-not $inst) { throw ('找不到实例：' + $Id) }
    if (-not $File -or -not (Test-Path -LiteralPath $File)) { throw ('备份文件不存在：' + $File) }
    $isMysql = ([string]$inst.Engine -eq 'mysql')
    $target = ([string]$Database).Trim()
    if ($target -and -not (Test-GuiReadyDatabaseName $target)) {
        throw '库名只能用字母 / 数字 / 下划线 / 短横线，且以字母数字下划线开头（最长 63）'
    }

    $svc = Get-Service -Name ([string]$inst.Service) -ErrorAction SilentlyContinue
    if ((-not $svc -or $svc.Status -ne 'Running') -and -not (Test-GuiReadyPortInUse -Port ([int]$inst.Port))) {
        throw '服务没在运行，先启动再还原'
    }

    $sizeMB = [math]::Round((Get-Item -LiteralPath $File).Length / 1MB, 2)
    if ($isMysql) {
        $tool = Join-Path (Get-GuiReadyMySQLBin ([string]$inst.Version)) 'mysql.exe'
        $toolArgs = ('--defaults-file="{0}" -u root --protocol=TCP' -f (Get-GuiReadyMySQLIniPath $Id))
        if ($target) { $toolArgs += (' "{0}"' -f $target) }
        if ($DryRun) {
            Write-Log ('[试运行] mysql {0} < "{1}"（{2} MB）' -f $toolArgs, $File, $sizeMB) 'DRY'
            return [pscustomobject]@{ Kind = 'restore'; Engine = 'mysql'; Id = $Id; File = $File; Database = $target; DryRun = $true }
        }
        $pw = Unprotect-GuiReadyDbSecret -Cipher ([string]$inst.Password)
        if (-not $pw) { throw '实例密码解不开（换过机器/账号？），无法自动还原' }
        Write-Log ('还原 {0} ← {1}（{2} MB）' -f $inst.Id, (Split-Path -Leaf $File), $sizeMB) 'STEP'
        $r = Invoke-GuiReadyPgTool -Exe $tool -Arguments $toolArgs -StdinFile $File -TimeoutMs 3600000 -Env @{ MYSQL_PWD = $pw }
    } else {
        if (-not $target) { $target = 'postgres' }
        $tool = Join-Path (Get-GuiReadyPostgresBin ([string]$inst.Version)) 'pg_restore.exe'
        $toolArgs = ('-h 127.0.0.1 -p {0} -U postgres --clean --if-exists --no-owner -d "{1}" "{2}"' -f $inst.Port, $target, $File)
        if ($DryRun) {
            Write-Log ('[试运行] pg_restore {0}（{1} MB）' -f $toolArgs, $sizeMB) 'DRY'
            return [pscustomobject]@{ Kind = 'restore'; Engine = 'postgresql'; Id = $Id; File = $File; Database = $target; DryRun = $true }
        }
        $pw = Unprotect-GuiReadyDbSecret -Cipher ([string]$inst.Password)
        if (-not $pw) { throw '实例密码解不开（换过机器/账号？），无法自动还原' }
        Write-Log ('还原 {0} → 库 {1} ← {2}（{3} MB）' -f $inst.Id, $target, (Split-Path -Leaf $File), $sizeMB) 'STEP'
        $r = Invoke-GuiReadyPgTool -Exe $tool -Arguments $toolArgs -TimeoutMs 3600000 -Env @{ PGPASSWORD = $pw }
    }

    if ($r.Code -ne 0) {
        $tail = ((@($r.Err, $r.Out) -join "`n") -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 4) -join ' / '
        throw ('还原失败（退出码 {0}）：{1}' -f $r.Code, $tail)
    }
    Write-Log '还原完成' 'OK'
    return [pscustomobject]@{ Kind = 'restore'; Engine = $(if ($isMysql) { 'mysql' } else { 'postgresql' }); Id = $Id; File = $File; Database = $target; Restored = $true }
}

# ---------------------------------------------------------------- 状态
function Get-GuiReadyDatabaseStatus {
    $items = New-Object System.Collections.ArrayList
    $instances = @(Read-GuiReadyDbInstances)

    foreach ($e in (Get-GuiReadyPostgresCatalog)) {
        $installed = Test-GuiReadyPostgresInstalled -Version $e.Version
        $mine = @($instances | Where-Object { [string]$_.Engine -eq 'postgresql' -and [string]$_.Version -eq $e.Version })
        [void]$items.Add([pscustomobject]@{
            Kind      = 'version'
            Engine    = 'postgresql'
            Name      = ('PostgreSQL {0}' -f $e.Version)
            Version   = $e.Version
            Major     = $e.Major
            Size      = $e.Size
            Url       = $e.Url
            Note      = $e.Note
            Installed = $installed
            BinDir    = $(if ($installed) { Get-GuiReadyPostgresBin $e.Version } else { '' })
            DataRoot  = (Join-Path (Get-GuiReadyDatabaseDataRoot) ('{0}-<端口>' -f $e.Version))
            Instances = [int]$mine.Count
        })
    }
    foreach ($e in (Get-GuiReadyMySQLCatalog)) {
        $installed = Test-GuiReadyMySQLInstalled -Version $e.Version
        $mine = @($instances | Where-Object { [string]$_.Engine -eq 'mysql' -and [string]$_.Version -eq $e.Version })
        [void]$items.Add([pscustomobject]@{
            Kind      = 'version'
            Engine    = 'mysql'
            Name      = ('MySQL {0}' -f $e.Version)
            Version   = $e.Version
            Major     = $e.Major
            Size      = $e.Size
            Url       = $e.Url
            Note      = $e.Note
            Installed = $installed
            BinDir    = $(if ($installed) { Get-GuiReadyMySQLBin $e.Version } else { '' })
            DataRoot  = (Join-Path (Get-GuiReadyDatabaseDataRoot) ('{0}-<端口>' -f $e.Version))
            Instances = [int]$mine.Count
        })
    }

    foreach ($i in $instances) {
        $isMysql = ([string]$i.Engine -eq 'mysql')
        $svc = Get-Service -Name ([string]$i.Service) -ErrorAction SilentlyContinue
        $state = '未注册'
        if ($svc) { $state = [string]$svc.Status }
        $marker = if ($isMysql) { 'mysql' } else { 'PG_VERSION' }
        $dataOk = Test-Path -LiteralPath (Join-Path ([string]$i.DataDir) $marker)
        # 端口能连上就算在线：手工 pg_ctl start / mysqld 起来的实例也应该显示为可用
        $online = Test-GuiReadyPortInUse -Port ([int]$i.Port)
        if (-not $svc -and $online) { $state = '手工运行' }
        $sizeMB = 0
        if (Test-Path -LiteralPath ([string]$i.DataDir)) {
            try {
                $sum = (Get-ChildItem -LiteralPath ([string]$i.DataDir) -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum).Sum
                if ($sum) { $sizeMB = [math]::Round($sum / 1MB, 1) }
            } catch { }
        }
        $backups = 0
        $lastBackup = ''
        $engineDir = if ($isMysql) { 'mysql' } else { 'postgresql' }
        $pattern = if ($isMysql) { [string]$i.Id + '-*.sql' } else { [string]$i.Id + '-*.dump' }
        $bdir = Join-Path (Join-Path (Get-GuiReadyRuntimeRootBase) 'backup') $engineDir
        if (Test-Path -LiteralPath $bdir) {
            $files = @(Get-ChildItem -LiteralPath $bdir -Filter $pattern -File -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime -Descending)
            $backups = $files.Count
            if ($files.Count -gt 0) { $lastBackup = $files[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        }
        [void]$items.Add([pscustomobject]@{
            Kind         = 'instance'
            Engine       = $(if ($isMysql) { 'mysql' } else { 'postgresql' })
            Id           = [string]$i.Id
            Name         = [string]$i.Name
            Version      = [string]$i.Version
            Port         = [int]$i.Port
            Service      = [string]$i.Service
            ServiceState = $state
            Online       = $online
            DataDir      = [string]$i.DataDir
            DataOk       = $dataOk
            SizeMB       = $sizeMB
            DbUser       = [string]$i.DbUser
            Backups      = $backups
            LastBackup   = $lastBackup
            CreatedAt    = [string]$i.CreatedAt
        })
    }

    return [pscustomobject]@{
        Root     = (Get-GuiReadyDatabaseRoot)
        DataRoot = (Get-GuiReadyDatabaseDataRoot)
        IsAdmin  = (Test-IsAdministrator)
        FreePort = (Get-GuiReadyFreePort)
        Items    = @($items)
    }
}

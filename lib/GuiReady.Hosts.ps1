# GuiReady 远程主机清单：主机 CRUD、标签、DPAPI 凭据、TrustedHosts。
#
# 设计约束（与整个工具一致）：
#   1. 零第三方依赖，只用 PowerShell 5.1 + .NET Framework；
#   2. hosts.json 原子写：临时文件 + Move-Item，GUI 与查询子进程同时读不会读到半个文件；
#   3. 密码只用 DPAPI(CurrentUser) 加密成二进制文件，绝不进入 hosts.json / 审计 / 日志；
#   4. TrustedHosts 只提供显式读写函数，任何调用方都不会“顺手”修改它。
#
# 目录布局：
#   state\hosts\hosts.json                 主机清单（不含凭据）
#   state\hosts\credentials\<Id>.dat       DPAPI 加密的 {User,Password}

$script:GuiReadyHostRoot        = Split-Path -Parent $PSScriptRoot
$script:GuiReadyHostDir         = Join-Path $script:GuiReadyHostRoot 'state\hosts'
$script:GuiReadyHostStoreFile   = Join-Path $script:GuiReadyHostDir 'hosts.json'
$script:GuiReadyHostCredDir     = Join-Path $script:GuiReadyHostDir 'credentials'
$script:GuiReadyHostUtf8NoBom   = New-Object System.Text.UTF8Encoding($false)
$script:GuiReadyHostEntropy     = [System.Text.Encoding]::UTF8.GetBytes('GuiReady.Hosts.v1')

function Get-GuiReadyHostRoot { return $script:GuiReadyHostRoot }
function Get-GuiReadyHostStorePath { return $script:GuiReadyHostStoreFile }
function Get-GuiReadyHostCredentialDir { return $script:GuiReadyHostCredDir }

function Ensure-GuiReadyHostDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Read-GuiReadyHostJson {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            return ($raw | ConvertFrom-Json)
        } catch {
            Start-Sleep -Milliseconds 60
        }
    }
    return $null
}

function Write-GuiReadyHostJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json
    )
    $dir = Split-Path -Parent $Path
    if ($dir) { Ensure-GuiReadyHostDir -Path $dir }
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Json, $script:GuiReadyHostUtf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-GuiReadyHostAudit {
    # 查询子进程与 GUI 都会加载 Tasks 模块；万一单独使用本模块，审计静默跳过。
    param([string]$Event, [string]$Level = 'Info', [string]$Detail = '')
    if (Get-Command Write-GuiReadyAudit -ErrorAction SilentlyContinue) {
        try { Write-GuiReadyAudit -Event $Event -Level $Level -Detail $Detail } catch { }
    }
}

function ConvertTo-GuiReadyHostHashtable {
    # 注意：参数名不能叫 Input —— PowerShell 5.1 的函数里 $Input 是自动变量
    #（管道输入的枚举器），同名的参数会被自动变量顶掉，实测拿到的永远是空枚举器。
    param($Value)
    $h = @{}
    if ($null -eq $Value) { return $h }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) { $h[[string]$k] = $Value[$k] }
        return $h
    }
    foreach ($p in @($Value.PSObject.Properties)) { $h[[string]$p.Name] = $p.Value }
    return $h
}

function ConvertTo-GuiReadyHostTags {
    param($Tags)
    $out   = New-Object System.Collections.ArrayList
    $seen  = @{}
    $parts = New-Object System.Collections.ArrayList
    if ($null -ne $Tags) {
        if ($Tags -is [string]) {
            foreach ($x in ([string]$Tags -split '[,;，；]')) { [void]$parts.Add($x) }
        } else {
            foreach ($t in @($Tags)) {
                foreach ($x in ([string]$t -split '[,;，；]')) { [void]$parts.Add($x) }
            }
        }
    }
    foreach ($x in $parts) {
        $t = ([string]$x).Trim()
        if (-not $t) { continue }
        if ($t.Length -gt 24) { throw ('标签过长（最多 24 个字符）：' + $t) }
        $k = $t.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        [void]$out.Add($t)
    }
    if ($out.Count -gt 8) { throw '一台主机最多 8 个标签。' }
    return @($out.ToArray())
}

function New-GuiReadyHostId {
    for ($i = 0; $i -lt 20; $i++) {
        $id = 'h-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
        if (-not (Test-Path -LiteralPath (Join-Path $script:GuiReadyHostCredDir ($id + '.dat')))) { return $id }
    }
    return ('h-' + [guid]::NewGuid().ToString('N'))
}

function ConvertTo-GuiReadyHostRecord {
    # 规范化 + 校验单台主机；输入可以是哈希表或 PSCustomObject。
    param(
        [Parameter(Mandatory = $true)]$Value,
        [string]$Id = '',
        [string]$CreatedAt = '',
        [int]$DefaultPort = 0
    )
    $h = ConvertTo-GuiReadyHostHashtable -Value $Value

    $name = ([string]$h['Name']).Trim()
    if (-not $name) { throw '主机名称不能为空。' }
    if ($name.Length -gt 64) { throw '主机名称过长（最多 64 个字符）。' }

    $address = ([string]$h['Address']).Trim()
    if (-not $address) { throw '主机地址不能为空。' }
    if ($address.StartsWith('\\')) { throw '主机地址不支持 UNC 路径，请填 IP 或主机名。' }
    if ($address -notmatch '^[A-Za-z0-9.\-:]+$') { throw ('主机地址含非法字符：' + $address) }
    if ($address.Length -gt 255) { throw '主机地址过长。' }

    $protocol = ([string]$h['Protocol']).Trim()
    if (-not $protocol) { $protocol = 'Http' }
    switch ($protocol.ToLowerInvariant()) {
        'http'  { $protocol = 'Http' }
        'https' { $protocol = 'Https' }
        default { throw ('协议只支持 Http 或 Https：' + $protocol) }
    }

    $port = 0
    if ($null -ne $h['Port'] -and [string]$h['Port'] -ne '') {
        try { $port = [int]$h['Port'] } catch { $port = 0 }
        # 0 = 用协议默认端口（5985/5986），不是非法值
        if ($port -lt 0 -or $port -gt 65535) { throw ('端口必须在 1-65535 之间：' + [string]$h['Port']) }
    }
    if ($port -le 0) {
        if ($DefaultPort -gt 0) { $port = $DefaultPort }
        elseif ($protocol -eq 'Https') { $port = 5986 }
        else { $port = 5985 }
    }

    $auth = ([string]$h['Auth']).Trim()
    if (-not $auth) { $auth = 'Default' }
    switch ($auth.ToLowerInvariant()) {
        'default'    { $auth = 'Default' }
        'current'    { $auth = 'Default' }
        'credential' { $auth = 'Credential' }
        default      { throw ('认证方式只支持 Default（当前用户）或 Credential（保存的凭据）：' + $auth) }
    }

    $untrusted = $false
    if ($null -ne $h['AllowUntrusted']) { $untrusted = [bool]$h['AllowUntrusted'] }
    $enabled = $true
    if ($null -ne $h['Enabled']) { $enabled = [bool]$h['Enabled'] }

    $notes = [string]$h['Notes']
    if ($notes.Length -gt 2000) { $notes = $notes.Substring(0, 2000) }

    $when = (Get-Date).ToString('o')
    if (-not $CreatedAt) { $CreatedAt = [string]$h['CreatedAt'] }
    if (-not $CreatedAt) { $CreatedAt = $when }
    if (-not $Id) { $Id = [string]$h['Id'] }
    if (-not $Id) { $Id = New-GuiReadyHostId }

    return [pscustomobject][ordered]@{
        Id             = $Id
        Name           = $name
        Address        = $address
        Port           = $port
        Protocol       = $protocol
        Auth           = $auth
        AllowUntrusted = $untrusted
        Enabled        = $enabled
        Tags           = @(ConvertTo-GuiReadyHostTags -Tags $h['Tags'])
        Notes          = $notes
        CreatedAt      = $CreatedAt
        UpdatedAt      = $when
        LastTestAt     = [string]$h['LastTestAt']
        LastTestStatus = [string]$h['LastTestStatus']
        LastTestMessage = [string]$h['LastTestMessage']
    }
}

function Read-GuiReadyHostStore {
    param()
    $doc = Read-GuiReadyHostJson -Path $script:GuiReadyHostStoreFile
    $hosts = @()
    if ($doc -and $doc.PSObject.Properties['Hosts'] -and $doc.Hosts) { $hosts = @($doc.Hosts) }
    return [pscustomobject][ordered]@{
        Version   = 1
        UpdatedAt = $(if ($doc) { [string]$doc.UpdatedAt } else { '' })
        Hosts     = $hosts
    }
}

function Get-GuiReadyHostList {
    param([switch]$EnabledOnly, [switch]$WithCredentialUser)
    $store = Read-GuiReadyHostStore
    $out   = New-Object System.Collections.ArrayList
    foreach ($raw in @($store.Hosts)) {
        if (-not $raw) { continue }
        $id = [string]$raw.Id
        if (-not $id) { continue }
        $enabled = $true
        if ($null -ne $raw.Enabled) { $enabled = [bool]$raw.Enabled }
        if ($EnabledOnly -and -not $enabled) { continue }
        $cp   = Join-Path $script:GuiReadyHostCredDir ($id + '.dat')
        $has  = Test-Path -LiteralPath $cp -PathType Leaf
        $user = ''
        if ($has -and $WithCredentialUser) {
            $r = Test-GuiReadyHostCredential -Id $id
            if ($r.Ok) { $user = [string]$r.User }
        }
        [void]$out.Add([pscustomobject][ordered]@{
            Id              = $id
            Name            = [string]$raw.Name
            Address         = [string]$raw.Address
            Port            = [int]$raw.Port
            Protocol        = [string]$raw.Protocol
            Auth            = [string]$raw.Auth
            AllowUntrusted  = [bool]$raw.AllowUntrusted
            Enabled         = $enabled
            Tags            = @($raw.Tags)
            Notes           = [string]$raw.Notes
            CreatedAt       = [string]$raw.CreatedAt
            UpdatedAt       = [string]$raw.UpdatedAt
            LastTestAt      = [string]$raw.LastTestAt
            LastTestStatus  = [string]$raw.LastTestStatus
            LastTestMessage = [string]$raw.LastTestMessage
            HasCredential   = $has
            CredentialUser  = $user
        })
    }
    return @($out.ToArray())
}

function Save-GuiReadyHostList {
    param([object[]]$Hosts = @())
    $clean = New-Object System.Collections.ArrayList
    foreach ($h in @($Hosts)) {
        if (-not $h) { continue }
        [void]$clean.Add([ordered]@{
            Id              = [string]$h.Id
            Name            = [string]$h.Name
            Address         = [string]$h.Address
            Port            = [int]$h.Port
            Protocol        = [string]$h.Protocol
            Auth            = [string]$h.Auth
            AllowUntrusted  = [bool]$h.AllowUntrusted
            Enabled         = [bool]$h.Enabled
            Tags            = @($h.Tags)
            Notes           = [string]$h.Notes
            CreatedAt       = [string]$h.CreatedAt
            UpdatedAt       = [string]$h.UpdatedAt
            LastTestAt      = [string]$h.LastTestAt
            LastTestStatus  = [string]$h.LastTestStatus
            LastTestMessage = [string]$h.LastTestMessage
        })
    }
    $doc = [ordered]@{
        Version   = 1
        UpdatedAt = (Get-Date).ToString('o')
        Hosts     = @($clean.ToArray())
    }
    Write-GuiReadyHostJson -Path $script:GuiReadyHostStoreFile -Json ($doc | ConvertTo-Json -Depth 6)
    return $script:GuiReadyHostStoreFile
}

function Get-GuiReadyHost {
    param([Parameter(Mandatory = $true)][string]$IdOrAddress)
    $key = $IdOrAddress.Trim()
    if (-not $key) { return $null }
    foreach ($h in @(Get-GuiReadyHostList)) {
        if ([string]$h.Id -eq $key) { return $h }
    }
    foreach ($h in @(Get-GuiReadyHostList)) {
        if ([string]$h.Address -eq $key) { return $h }
        if ([string]$h.Name -eq $key) { return $h }
    }
    return $null
}

function Resolve-GuiReadyHostTargets {
    # 空 / all / * = 全部启用主机；否则按 Id、名称、地址解析（逗号或分号分隔）。
    param([string]$Spec)
    $all = @(Get-GuiReadyHostList)
    $s = ([string]$Spec).Trim()
    if (-not $s -or $s -eq 'all' -or $s -eq '*') {
        $enabled = @($all | Where-Object { [bool]$_.Enabled })
        if ($enabled.Count -eq 0) { throw '主机清单里没有启用的主机。' }
        return $enabled
    }
    $picked = New-Object System.Collections.ArrayList
    $seen   = @{}
    $missing = New-Object System.Collections.ArrayList
    foreach ($raw in ($s -split '[,;，；]')) {
        $t = $raw.Trim()
        if (-not $t) { continue }
        $hit = $null
        foreach ($h in $all) {
            if ([string]$h.Id -eq $t -or [string]$h.Address -eq $t -or [string]$h.Name -eq $t) { $hit = $h; break }
        }
        if (-not $hit) { [void]$missing.Add($t); continue }
        if ($seen.ContainsKey([string]$hit.Id)) { continue }
        $seen[[string]$hit.Id] = $true
        [void]$picked.Add($hit)
    }
    if ($missing.Count -gt 0) { throw ('找不到主机：' + ($missing.ToArray() -join '、') + '。请检查名称、地址或 Id。') }
    if ($picked.Count -eq 0) { throw '没有选中任何主机。' }
    return @($picked.ToArray())
}

function New-GuiReadyHost {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Address,
        [int]$Port = 0,
        [string]$Protocol = 'Http',
        [string]$Auth = 'Default',
        [switch]$AllowUntrusted,
        [object]$Tags = $null,
        [string]$Notes = '',
        [bool]$Enabled = $true
    )
    $list = @(Get-GuiReadyHostList)
    $rec  = ConvertTo-GuiReadyHostRecord -Value ([ordered]@{
        Name = $Name; Address = $Address; Port = $Port; Protocol = $Protocol; Auth = $Auth
        AllowUntrusted = [bool]$AllowUntrusted; Tags = $Tags; Notes = $Notes; Enabled = $Enabled
    })
    foreach ($h in $list) {
        if ([string]$h.Name -eq [string]$rec.Name) { throw ('主机名称已存在：' + $rec.Name) }
    }
    $list += $rec
    [void](Save-GuiReadyHostList -Hosts $list)
    Write-GuiReadyHostAudit -Event 'host-add' -Level 'Info' -Detail ('{0}（{1}:{2}）' -f $rec.Name, $rec.Address, $rec.Port)
    return $rec
}

function Set-GuiReadyHost {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Name = '',
        [string]$Address = '',
        [int]$Port = 0,
        [string]$Protocol = '',
        [string]$Auth = '',
        [object]$AllowUntrusted = $null,
        [object]$Tags = $null,
        [string]$Notes = $null,
        [object]$Enabled = $null
    )
    $list = @(Get-GuiReadyHostList)
    $idx  = -1
    for ($i = 0; $i -lt $list.Count; $i++) { if ([string]$list[$i].Id -eq $Id) { $idx = $i; break } }
    if ($idx -lt 0) { throw ('找不到主机：' + $Id) }
    $old = $list[$idx]

    $merge = [ordered]@{
        Id = $old.Id; Name = $old.Name; Address = $old.Address; Port = $old.Port
        Protocol = $old.Protocol; Auth = $old.Auth; AllowUntrusted = $old.AllowUntrusted
        Tags = @($old.Tags); Notes = $old.Notes; Enabled = $old.Enabled
        CreatedAt = $old.CreatedAt
        LastTestAt = $old.LastTestAt; LastTestStatus = $old.LastTestStatus; LastTestMessage = $old.LastTestMessage
    }
    if ($Name) { $merge['Name'] = $Name }
    if ($Address) { $merge['Address'] = $Address }
    if ($Port -gt 0) { $merge['Port'] = $Port }
    if ($Protocol) { $merge['Protocol'] = $Protocol }
    if ($Auth) { $merge['Auth'] = $Auth }
    if ($null -ne $AllowUntrusted) { $merge['AllowUntrusted'] = [bool]$AllowUntrusted }
    if ($null -ne $Tags) { $merge['Tags'] = $Tags }
    if ($null -ne $Notes) { $merge['Notes'] = $Notes }
    if ($null -ne $Enabled) { $merge['Enabled'] = [bool]$Enabled }

    $rec = ConvertTo-GuiReadyHostRecord -Value $merge -Id $old.Id -CreatedAt $old.CreatedAt -DefaultPort $old.Port
    foreach ($h in $list) {
        if ([string]$h.Id -ne [string]$rec.Id -and [string]$h.Name -eq [string]$rec.Name) {
            throw ('主机名称已存在：' + $rec.Name)
        }
    }
    $list[$idx] = $rec
    [void](Save-GuiReadyHostList -Hosts $list)
    Write-GuiReadyHostAudit -Event 'host-update' -Level 'Info' -Detail ('{0}（{1}:{2}）' -f $rec.Name, $rec.Address, $rec.Port)
    return $rec
}

function Remove-GuiReadyHost {
    param([Parameter(Mandatory = $true)][string]$Id)
    $list = @(Get-GuiReadyHostList)
    $keep = @($list | Where-Object { [string]$_.Id -ne $Id })
    if ($keep.Count -eq $list.Count) { throw ('找不到主机：' + $Id) }
    $removed = @($list | Where-Object { [string]$_.Id -eq $Id })[0]
    [void](Save-GuiReadyHostList -Hosts $keep)
    $cp = Join-Path $script:GuiReadyHostCredDir ($Id + '.dat')
    try { if (Test-Path -LiteralPath $cp) { Remove-Item -LiteralPath $cp -Force -ErrorAction Stop } } catch { }
    Write-GuiReadyHostAudit -Event 'host-remove' -Level 'Warn' -Detail ('{0}（{1}:{2}）' -f $removed.Name, $removed.Address, $removed.Port)
    return $removed
}

function Update-GuiReadyHostTestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [bool]$Ok = $false,
        [string]$Message = ''
    )
    $list = @(Get-GuiReadyHostList)
    $idx  = -1
    for ($i = 0; $i -lt $list.Count; $i++) { if ([string]$list[$i].Id -eq $Id) { $idx = $i; break } }
    if ($idx -lt 0) { return }
    $h = $list[$idx]
    $msg = [string]$Message
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
    $obj = [ordered]@{
        Id = $h.Id; Name = $h.Name; Address = $h.Address; Port = $h.Port
        Protocol = $h.Protocol; Auth = $h.Auth; AllowUntrusted = $h.AllowUntrusted
        Enabled = $h.Enabled; Tags = @($h.Tags); Notes = $h.Notes
        CreatedAt = $h.CreatedAt; UpdatedAt = $h.UpdatedAt
        LastTestAt = (Get-Date).ToString('o')
        LastTestStatus = $(if ($Ok) { 'OK' } else { 'Failed' })
        LastTestMessage = $msg
    }
    $list[$idx] = [pscustomobject]$obj
    [void](Save-GuiReadyHostList -Hosts $list)
}

# ============================ DPAPI 凭据 ============================

function Initialize-GuiReadyProtectedData {
    if ('System.Security.Cryptography.ProtectedData' -as [type]) { return }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    } catch {
        throw '当前系统缺少 DPAPI 支持（System.Security），无法保存凭据。'
    }
}

function Get-GuiReadyHostCredentialPath {
    param([Parameter(Mandatory = $true)][string]$Id)
    return (Join-Path $script:GuiReadyHostCredDir ($Id + '.dat'))
}

function Set-GuiReadyHostCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $h = Get-GuiReadyHost -IdOrAddress $Id
    if (-not $h) { throw ('找不到主机：' + $Id) }
    $u = $UserName.Trim()
    if (-not $u) { throw '用户名不能为空。' }
    if (-not $Password) { throw '密码不能为空。' }

    Initialize-GuiReadyProtectedData
    Ensure-GuiReadyHostDir -Path $script:GuiReadyHostCredDir
    $plain = $null
    try {
        $plain = ([ordered]@{ User = $u; Password = $Password } | ConvertTo-Json -Compress)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
        $blob  = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $script:GuiReadyHostEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $path = Get-GuiReadyHostCredentialPath -Id $h.Id
        $tmp  = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.tmp'
        [System.IO.File]::WriteAllBytes($tmp, $blob)
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        $plain   = $null
        $bytes   = $null
    }
    Write-GuiReadyHostAudit -Event 'host-credential-set' -Level 'Info' -Detail ('主机 ' + $h.Id + ' 已保存凭据（DPAPI 加密）')
    return $true
}

function Get-GuiReadyHostCredential {
    param([Parameter(Mandatory = $true)][string]$Id)
    $path = Get-GuiReadyHostCredentialPath -Id $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '这台主机没有保存凭据，请先填写用户名和密码。'
    }
    Initialize-GuiReadyProtectedData
    try {
        $blob  = [System.IO.File]::ReadAllBytes($path)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $blob, $script:GuiReadyHostEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $plain = [System.Text.Encoding]::UTF8.GetString($bytes)
        $obj   = $plain | ConvertFrom-Json
        $user  = [string]$obj.User
        $pass  = [string]$obj.Password
        if (-not $user -or -not $pass) { throw '凭据内容不完整。' }
        $sec = New-Object System.Security.SecureString
        foreach ($ch in $pass.ToCharArray()) { $sec.AppendChar($ch) }
        $sec.MakeReadOnly()
        $pass  = $null
        $plain = $null
        return (New-Object System.Management.Automation.PSCredential($user, $sec))
    } catch {
        $m = [string]$_.Exception.Message
        if ($m -match '凭据内容不完整') { throw '凭据内容不完整，请重新填写用户名和密码。' }
        throw ('已保存的凭据无法解密（DPAPI 仅限原用户原机器），请重新填写用户名和密码。原始信息：' + $m)
    }
}

function Test-GuiReadyHostCredential {
    param([Parameter(Mandatory = $true)][string]$Id)
    $path = Get-GuiReadyHostCredentialPath -Id $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ Ok = $false; User = ''; Message = '未保存凭据。' }
    }
    try {
        $cred = Get-GuiReadyHostCredential -Id $Id
        return [pscustomobject][ordered]@{ Ok = $true; User = $cred.UserName; Message = '凭据可正常解密。' }
    } catch {
        return [pscustomobject][ordered]@{ Ok = $false; User = ''; Message = [string]$_.Exception.Message }
    }
}

function Remove-GuiReadyHostCredential {
    param([Parameter(Mandatory = $true)][string]$Id)
    $path = Get-GuiReadyHostCredentialPath -Id $Id
    $had  = Test-Path -LiteralPath $path -PathType Leaf
    if ($had) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    Write-GuiReadyHostAudit -Event 'host-credential-clear' -Level 'Warn' -Detail ('主机 ' + $Id + ' 的凭据已清除')
    return (-not (Test-Path -LiteralPath $path))
}

# ============================ TrustedHosts ============================

function Get-GuiReadyTrustedHostsState {
    $items = @()
    $err   = ''
    try {
        if (-not (Test-Path -LiteralPath 'WSMan:\localhost\Client\TrustedHosts')) {
            $err = '当前系统没有 WSMan 客户端配置（WinRM 可能未安装）。'
            return [pscustomobject][ordered]@{ Items = @(); Error = $err }
        }
        $value = (Get-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value
        if ($value) {
            foreach ($x in ([string]$value -split ',')) {
                $t = $x.Trim()
                if ($t) { $items += $t }
            }
        }
    } catch {
        $err = [string]$_.Exception.Message
    }
    return [pscustomobject][ordered]@{ Items = @($items); Error = $err }
}

function Get-GuiReadyTrustedHosts {
    return @((Get-GuiReadyTrustedHostsState).Items)
}

function Split-GuiReadyTrustedHostInput {
    param([string]$Address)
    $out = New-Object System.Collections.ArrayList
    foreach ($x in ([string]$Address -split '[,;，；\s]+')) {
        $t = $x.Trim()
        if ($t) { [void]$out.Add($t) }
    }
    return @($out.ToArray())
}

function Save-GuiReadyTrustedHosts {
    param([string[]]$Items = @())
    $clean = @()
    foreach ($x in @($Items)) { $t = ([string]$x).Trim(); if ($t) { $clean += $t } }
    # WinRM 的规则：* 表示信任所有主机，必须单独存在。
    # 先自己拦住并给中文原因，别把 WinRM 那句「主机名模式无效」原样甩给用户。
    if (($clean -contains '*') -and $clean.Count -gt 1) {
        throw 'TrustedHosts 里的 * 表示信任所有主机，只能单独使用；请先移除 *，再按地址逐个管理。'
    }
    $value = ($clean -join ',')
    try {
        Set-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -Value $value -Force -ErrorAction Stop
    } catch {
        throw ('修改 TrustedHosts 失败（通常需要管理员权限）：' + $_.Exception.Message)
    }
    return (Get-GuiReadyTrustedHostsState)
}

function Add-GuiReadyTrustedHost {
    param([Parameter(Mandatory = $true)][string]$Address)
    $state = Get-GuiReadyTrustedHostsState
    if ($state.Error) { throw $state.Error }
    if (@($state.Items) -contains '*') {
        throw '当前 TrustedHosts 是 *（信任所有主机），已无需再添加单个地址；如需按地址管理，请先移除 *。'
    }
    $items = New-Object System.Collections.ArrayList
    foreach ($x in @($state.Items)) { [void]$items.Add([string]$x) }
    $seen = @{}
    foreach ($x in $items) { $seen[$x.ToLowerInvariant()] = $true }
    $added = New-Object System.Collections.ArrayList
    foreach ($t in (Split-GuiReadyTrustedHostInput -Address $Address)) {
        if ($t -eq '*') {
            throw '不能通过「添加」加入 *（信任所有主机）；请先清空现有地址，再单独设为 *。'
        }
        $k = $t.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        [void]$items.Add($t)
        [void]$added.Add($t)
    }
    if ($added.Count -eq 0) { return $state }
    $new = Save-GuiReadyTrustedHosts -Items @($items.ToArray())
    Write-GuiReadyHostAudit -Event 'trustedhosts-add' -Level 'Warn' -Detail ('加入 TrustedHosts：' + ($added.ToArray() -join '、'))
    return $new
}

function Remove-GuiReadyTrustedHost {
    param([Parameter(Mandatory = $true)][string]$Address)
    $state = Get-GuiReadyTrustedHostsState
    if ($state.Error) { throw $state.Error }
    $remove = @{}
    foreach ($t in (Split-GuiReadyTrustedHostInput -Address $Address)) { $remove[$t.ToLowerInvariant()] = $true }
    if ($remove.Count -eq 0) { throw '请填写要移除的地址。' }
    if ((@($state.Items) -contains '*') -and -not $remove.ContainsKey('*')) {
        throw '当前 TrustedHosts 是 *（信任所有主机），不包含单条地址；如需删除具体地址，请先移除 *。'
    }
    $keep = New-Object System.Collections.ArrayList
    $gone = New-Object System.Collections.ArrayList
    foreach ($x in @($state.Items)) {
        if ($remove.ContainsKey(([string]$x).ToLowerInvariant())) { [void]$gone.Add([string]$x) }
        else { [void]$keep.Add([string]$x) }
    }
    if ($gone.Count -eq 0) { return $state }
    $new = Save-GuiReadyTrustedHosts -Items @($keep.ToArray())
    Write-GuiReadyHostAudit -Event 'trustedhosts-remove' -Level 'Warn' -Detail ('移出 TrustedHosts：' + ($gone.ToArray() -join '、'))
    return $new
}

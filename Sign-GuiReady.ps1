<#
  Sign-GuiReady.ps1 —— 给本工具签名 / 生成完整性清单 / 校验。

  为什么需要它：这个工具以管理员（部分步骤以 SYSTEM）身份执行自己目录里的脚本。
  签名 + 清单能让用户判断"手上的这份是不是发布的那份、有没有被人改过"。

  与「签名\」目录里那两个 .cmd 的区别（那两条是给 .exe 用的 signtool 包装）：
    - 它们依赖 Windows SDK 的 makecert/certmgr/cert2spc/pvk2pfx/signtool，本机没有 SDK 就跑不了；
    - 它们只签 .exe，而本项目发布的是 .ps1 + zip；
    - 它们是交互式问答，没法进 CI。
  所以这里用 PowerShell 原生链路（New-SelfSignedCertificate + Set-AuthenticodeSignature），
  同一个 .pfx 证书两边都能用：将来要签 .exe 仍可以用「签名\仅签名（需要现成的证书）.cmd」。

  用法：

    # 1) 校验（用户侧最常用；没有证书也能跑）
    powershell -ExecutionPolicy Bypass -File Sign-GuiReady.ps1 -Verify

    # 2) 用已有证书签名（证书在证书存储里，按指纹选）
    powershell -File Sign-GuiReady.ps1 -Thumbprint <证书指纹>

    # 3) 用 .pfx 签名（密码优先从环境变量 SCM_PFX_PASSWORD 取，避免出现在命令行里）
    $env:SCM_PFX_PASSWORD = '******'
    powershell -File Sign-GuiReady.ps1 -PfxPath .\签名\证书.pfx

    # 4) 没有证书：先生成一个自签名证书（会导出 .pfx 与 .cer）
    powershell -File Sign-GuiReady.ps1 -CreateSelfSigned
    #   证书里的"颁发给 / 作者"默认就是 mmm；要换名字用 -Subject 'CN=别的名字'

  签名之后会自动重建 manifest.sha256（清单），所以顺序永远是「先签名、后清单」。
  自签名证书的签名在别的机器上会显示「签名有效但证书不受信任」——需要把那台机器导入 .cer
  （受信任的根证书颁发机构）才会变成「有效」。对外分发建议用受信任 CA 的代码签名证书。
#>
[CmdletBinding()]
param(
    # 要处理的目录（默认本脚本所在目录）
    [string]$Root = '',
    # 校验模式：只报告，不改任何文件
    [switch]$Verify,
    # 证书来源一：证书存储里的指纹
    [string]$Thumbprint = '',
    # 证书来源二：.pfx 文件
    [string]$PfxPath = '',
    # pfx 密码（不传则读环境变量 SCM_PFX_PASSWORD，再不行就问一次）
    [string]$PfxPassword = '',
    # 生成自签名代码签名证书（native，不需要 Windows SDK）
    [switch]$CreateSelfSigned,
    # 证书主题里的作者名（Windows 证书界面显示为"颁发给"）
    [string]$Subject = 'CN=mmm',
    # 自签名证书有效期（年）与导出位置
    [int]$Years = 3,
    [string]$PfxOut = '',
    # 时间戳服务（可选；长时间有效的证书建议开）。留空则不盖时间戳。
    [string]$TimestampUrl = '',
    # 只签这些扩展名（默认 ps1/psm1/psd1）
    [string[]]$Extensions = @('.ps1', '.psm1', '.psd1'),
    # 静音（只输出汇总）
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not $Root) { $Root = $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

Write-Host ''
Write-Host ('== Sign-GuiReady ==  目录: ' + $Root)

# 加载公共模块与完整性模块（清单 + 校验 + 目录权限检查都靠它们）
$common    = Join-Path (Join-Path $Root 'lib') 'GuiReady.Common.ps1'
if (Test-Path -LiteralPath $common) { . $common }
$integrity = Join-Path (Join-Path $Root 'lib') 'GuiReady.Integrity.ps1'
$haveIntegrity = Test-Path -LiteralPath $integrity
if ($haveIntegrity) { . $integrity }

# ---------------------------------------------------------------- 生成自签名证书
if ($CreateSelfSigned) {
    try {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
                    -KeyUsage DigitalSignature -KeyExportPolicy Exportable `
                    -NotAfter (Get-Date).AddYears([Math]::Max(1, $Years)) `
                    -CertStoreLocation 'Cert:\CurrentUser\My' -ErrorAction Stop
        Say ('已创建自签名代码签名证书: ' + $cert.Subject) 'Green'
        Say ('  指纹: ' + $cert.Thumbprint)

        if (-not $PfxPassword) {
            if ($env:SCM_PFX_PASSWORD) { $PfxPassword = $env:SCM_PFX_PASSWORD }
            else {
                # 随机口令，避免弱口令；只显示这一次，请自己存好。
                # 这一行**不受 -Quiet 影响**：口令丢了就等于 pfx 丢了。
                $PfxPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
                Write-Host ('  已生成 pfx 口令（请立刻保存，丢失后无法再导入这个 pfx）: ' + $PfxPassword) -ForegroundColor Yellow
            }
        }
        if (-not $PfxOut) { $PfxOut = Join-Path $Root '证书.pfx' }
        $secure = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
        Export-PfxCertificate -Cert $cert -FilePath $PfxOut -Password $secure -ErrorAction Stop | Out-Null
        Say ('  已导出私钥: ' + $PfxOut) 'Green'

        $cerOut = [System.IO.Path]::ChangeExtension($PfxOut, '.cer')
        Export-Certificate -Cert $cert -FilePath $cerOut -Force -ErrorAction SilentlyContinue | Out-Null
        Say ('  已导出公钥: ' + $cerOut + '   （目标机器导入"受信任的根证书颁发机构"后，签名才会显示"有效"）') 'Green'
        Say '  提醒：自签名证书只能证明"这份包没被改过"，不能证明"是我发的"；对外分发请用受信任 CA 的证书。' 'Yellow'

        $Thumbprint = $cert.Thumbprint
    } catch {
        Write-Host ('创建证书失败: ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------- 取证书对象
function Get-SignCert {
    if (-not $Thumbprint) { return $null }
    $tp = ($Thumbprint -replace '\s', '').ToUpperInvariant()
    foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
        try {
            $c = Get-ChildItem -Path $store -CodeSigningCert -ErrorAction SilentlyContinue |
                 Where-Object { $_.Thumbprint -eq $tp }
            if ($c) { return $c[0] }
        } catch { }
    }
    return $null
}

function Get-PfxCert {
    if (-not $PfxPath) { return $null }
    if (-not (Test-Path -LiteralPath $PfxPath)) {
        Write-Host ('pfx 不存在: ' + $PfxPath) -ForegroundColor Red
        return $null
    }
    # 密码来源：参数 → 环境变量 → 交互输入（SecureString，不回显）
    if (-not $PfxPassword) { $PfxPassword = [string]$env:SCM_PFX_PASSWORD }
    try {
        if ($PfxPassword) {
            $secure = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
            return (Get-PfxCertificate -FilePath $PfxPath -Password $secure -ErrorAction Stop)
        }
        # -Password 不传时 Get-PfxCertificate 会弹一个不回显的输入框
        return (Get-PfxCertificate -FilePath $PfxPath -ErrorAction Stop)
    } catch {
        Write-Host ('读取 pfx 失败（密码不对？）: ' + $_.Exception.Message) -ForegroundColor Red
        return $null
    }
}

# ---------------------------------------------------------------- 校验模式
if ($Verify) {
    if (-not $haveIntegrity) {
        Write-Host '找不到 lib\GuiReady.Integrity.ps1，无法校验。' -ForegroundColor Red
        exit 1
    }
    Show-GuiReadyIntegrityReport
    $rep = Get-GuiReadyIntegrityReport -Root $Root
    switch ($rep.Verdict) {
        'ok'   { exit 0 }
        'info' { exit 0 }
        'warn' { exit 2 }
        default { exit 1 }
    }
}

# ---------------------------------------------------------------- 签名
$cert = $null
if ($PfxPath)  { $cert = Get-PfxCert }
if (-not $cert -and $Thumbprint) { $cert = Get-SignCert }

if (-not $cert) {
    Write-Host ''
    Write-Host '没有可用的签名证书。三种做法：' -ForegroundColor Yellow
    Write-Host '  1) 生成自签名证书：  .\Sign-GuiReady.ps1 -CreateSelfSigned'
    Write-Host '  2) 用已有 pfx：      $env:SCM_PFX_PASSWORD='"'"'******'"'"'; .\Sign-GuiReady.ps1 -PfxPath .\签名\证书.pfx'
    Write-Host '  3) 用证书存储里的：  .\Sign-GuiReady.ps1 -Thumbprint <指纹>'
    Write-Host ''
    Write-Host '（如果只想核对完整性，不加证书直接跑 -Verify 即可。）' -ForegroundColor Gray
    exit 1
}

Say ('使用证书: ' + $cert.Subject) 'Green'
Say ('  指纹: ' + $cert.Thumbprint)
if ($PfxPassword -and -not $env:SCM_PFX_PASSWORD) {
    Say '  注意：本次密码是从命令行参数传的，可能残留在进程列表/命令历史里；建议改用环境变量 SCM_PFX_PASSWORD。' 'Yellow'
}

# 只签自己的代码文件（按扩展名过滤；跳过运行时目录）
$skipDirs = @('.git', 'logs', 'reports', 'state', 'backup', 'payload', 'bin', 'dist', 'site', 'node_modules')
$files = @()
foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
    $skip = $false
    foreach ($d in $skipDirs) { if ($rel -eq $d -or $rel.StartsWith($d + '/')) { $skip = $true; break } }
    if ($skip) { continue }
    if ($Extensions -notcontains $f.Extension.ToLowerInvariant()) { continue }
    $files += $f.FullName
}
$files = @($files | Sort-Object)
Say ('待签文件: {0} 个' -f $files.Count)

$okCount = 0; $failCount = 0
foreach ($f in $files) {
    $rel = $f.Substring($Root.Length).TrimStart('\', '/')
    try {
        $p = @{ LiteralPath = $f; Certificate = $cert; HashAlgorithm = 'SHA256'; ErrorAction = 'Stop' }
        if ($TimestampUrl) { $p['TimestampServer'] = $TimestampUrl }
        $r = Set-AuthenticodeSignature @p
        if ([string]$r.Status -in @('Valid', 'UnknownError')) {
            $okCount++
            Say ('  已签名: ' + $rel + '  ' + [string]$r.Status) 'Gray'
        } else {
            $failCount++
            Write-Host ('  签名异常: {0}  {1}' -f $rel, [string]$r.Status) -ForegroundColor Red
        }
    } catch {
        $failCount++
        Write-Host ('  签名失败: {0}  {1}' -f $rel, $_.Exception.Message) -ForegroundColor Red
    }
}
Write-Host ('签名结果: 成功 {0}，失败 {1}' -f $okCount, $failCount) -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

# ---------------------------------------------------------------- 重建清单（必须在签名之后）
if ($haveIntegrity) {
    $man = Join-Path $Root 'manifest.sha256'
    $n = New-GuiReadyManifest -Root $Root -OutFile $man
    Say ('已重建清单: {0}  （{1} 个文件）' -f $man, $n) 'Green'
    $t = Test-GuiReadyManifest -Root $Root
    Say ('清单自检: {0}' -f $(if ($t.Ok) { '一致' } else { ('不一致（改了 {0}、缺 {1}、多 {2}）' -f $t.Modified.Count, $t.Missing.Count, $t.Extra.Count) })) `
        $(if ($t.Ok) { 'Green' } else { 'Red' })
}

Write-Host ''
Write-Host '完成。用户侧校验：  powershell -ExecutionPolicy Bypass -File Sign-GuiReady.ps1 -Verify' -ForegroundColor Cyan
exit $(if ($failCount -eq 0) { 0 } else { 1 })

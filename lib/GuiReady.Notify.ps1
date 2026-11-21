# GuiReady 通知：SMTP / Webhook（钉钉 / 飞书 / 企业微信 / 通用 JSON）。
#
# 配置在 state\notify\notify.json；SMTP 密码用 DPAPI **LocalMachine** 加密
# （计划任务以 SYSTEM 运行时也能解出来；CurrentUser 范围在 SYSTEM 下会失败）。
# 发送失败只记日志，不影响调用方（守护 / 巡检 / 备份都不该因为发不出通知而失败）。

function Get-GuiReadyNotifyRoot {
    $root = $script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    return (Join-Path $root 'state\notify')
}

function Get-GuiReadyNotifyPath { return (Join-Path (Get-GuiReadyNotifyRoot) 'notify.json') }
function Get-GuiReadyNotifyLogPath { return (Join-Path (Get-GuiReadyNotifyRoot) 'notify.log') }

function Protect-GuiReadyNotifySecret {
    param([string]$Text)
    if (-not $Text) { return '' }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'LocalMachine')
        return [Convert]::ToBase64String($enc)
    } catch { return '' }
}

function Unprotect-GuiReadyNotifySecret {
    param([string]$Cipher)
    if (-not $Cipher) { return '' }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $bytes = [Convert]::FromBase64String($Cipher)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'LocalMachine')
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch { return '' }
}

function Get-GuiReadyNotifyConfig {
    $default = [ordered]@{
        Enabled      = $false
        SmtpServer   = ''
        SmtpPort     = 587
        SmtpSsl      = $true
        SmtpUser     = ''
        SmtpPassword = ''
        SmtpFrom     = ''
        SmtpTo       = ''
        WebhookType  = 'generic'
        WebhookUrl   = ''
        QuietFrom    = ''
        QuietTo      = ''
    }
    $p = Get-GuiReadyNotifyPath
    if (Test-Path -LiteralPath $p) {
        try {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($default.Keys)) {
                if ($null -ne $j.$k -and [string]$j.$k -ne '') { $default[$k] = $j.$k }
            }
        } catch { }
    }
    return $default
}

function Set-GuiReadyNotifyConfig {
    param(
        [string]$Enabled = '',
        [string]$SmtpServer = '',
        [string]$SmtpPort = '',
        [string]$SmtpSsl = '',
        [string]$SmtpUser = '',
        [string]$SmtpPassword = '',
        [switch]$ClearPassword,
        [string]$SmtpFrom = '',
        [string]$SmtpTo = '',
        [string]$WebhookType = '',
        [string]$WebhookUrl = '',
        [string]$QuietFrom = '',
        [string]$QuietTo = '',
        [switch]$DryRun
    )
    $cfg = Get-GuiReadyNotifyConfig
    if ($Enabled -ne '') { $cfg.Enabled = ($Enabled -eq 'true' -or $Enabled -eq '1') }
    if ($SmtpServer) { $cfg.SmtpServer = $SmtpServer }
    if ($SmtpPort) { $cfg.SmtpPort = [int]$SmtpPort }
    if ($SmtpSsl -ne '') { $cfg.SmtpSsl = ($SmtpSsl -eq 'true' -or $SmtpSsl -eq '1') }
    if ($SmtpUser) { $cfg.SmtpUser = $SmtpUser }
    if ($SmtpFrom) { $cfg.SmtpFrom = $SmtpFrom }
    if ($SmtpTo) { $cfg.SmtpTo = $SmtpTo }
    if ($WebhookType) { $cfg.WebhookType = $WebhookType }
    if ($WebhookUrl) { $cfg.WebhookUrl = $WebhookUrl }
    if ($QuietFrom) { $cfg.QuietFrom = $QuietFrom }
    if ($QuietTo) { $cfg.QuietTo = $QuietTo }
    if ($ClearPassword) { $cfg.SmtpPassword = '' }
    elseif ($SmtpPassword) { $cfg.SmtpPassword = (Protect-GuiReadyNotifySecret $SmtpPassword) }

    if ($DryRun) {
        Write-Log ('[预览] 通知配置：启用={0} SMTP={1}:{2} 收件人={3} Webhook={4}' -f $cfg.Enabled, $cfg.SmtpServer, $cfg.SmtpPort, $cfg.SmtpTo, $cfg.WebhookType) 'DRY'
        return [pscustomobject]$cfg
    }

    $dir = Get-GuiReadyNotifyRoot
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $tmp = (Get-GuiReadyNotifyPath) + '.tmp'
    [System.IO.File]::WriteAllText($tmp, ($cfg | ConvertTo-Json -Depth 5), $utf8)
    Move-Item -LiteralPath $tmp -Destination (Get-GuiReadyNotifyPath) -Force
    Write-Log ('通知配置已保存（启用={0}）' -f $cfg.Enabled) 'OK'
    return [pscustomobject]$cfg
}

function Test-GuiReadyQuietHour {
    param($Cfg)
    if (-not $Cfg.QuietFrom -or -not $Cfg.QuietTo) { return $false }
    try {
        $now = (Get-Date).TimeOfDay
        $from = [TimeSpan]::Parse([string]$Cfg.QuietFrom)
        $to = [TimeSpan]::Parse([string]$Cfg.QuietTo)
        if ($from -le $to) { return ($now -ge $from -and $now -lt $to) }
        return ($now -ge $from -or $now -lt $to)
    } catch { return $false }
}

function Write-GuiReadyNotifyLog {
    param([string]$Line)
    try {
        $dir = Get-GuiReadyNotifyRoot
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath (Get-GuiReadyNotifyLogPath) -Value $Line -Encoding UTF8
    } catch { }
}

function Send-GuiReadyNotify {
    param([Parameter(Mandatory = $true)][string]$Title,
          [string]$Text = '',
          [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info',
          [string]$Attachment = '',
          [switch]$IgnoreQuiet,
          [switch]$DryRun)
    $cfg = Get-GuiReadyNotifyConfig
    $result = [ordered]@{ Sent = $false; Channels = @(); Error = '' }

    if (-not $cfg.Enabled) { $result.Error = '通知未启用'; return [pscustomobject]$result }
    if (-not $IgnoreQuiet -and (Test-GuiReadyQuietHour $cfg)) {
        $result.Error = '处于静默时段'
        return [pscustomobject]$result
    }
    if ($DryRun) {
        Write-Log ('[预览] 通知：{0}（{1}）' -f $Title, $Level) 'DRY'
        $result.Error = '预览'
        return [pscustomobject]$result
    }

    $body = '[SCM] {0}' -f $Title
    if ($Text) { $body += "`r`n" + $Text }
    if ($Attachment) { $body += "`r`n附件：" + $Attachment }
    $body += "`r`n主机：$env:COMPUTERNAME  时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $channels = @()

    # ---- SMTP
    if ($cfg.SmtpServer -and $cfg.SmtpTo) {
        try {
            $from = if ($cfg.SmtpFrom) { [string]$cfg.SmtpFrom } else { [string]$cfg.SmtpUser }
            if (-not $from) { throw '未填发件人' }
            Add-Type -AssemblyName System.Net.Mail -ErrorAction SilentlyContinue
            $mail = New-Object System.Net.Mail.MailMessage
            $mail.From = New-Object System.Net.Mail.MailAddress($from)
            foreach ($to in ([string]$cfg.SmtpTo -split '[;,]')) { if ($to.Trim()) { $mail.To.Add($to.Trim()) } }
            $mail.Subject = '[SCM] ' + $Title
            $mail.Body = $body
            $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
            $mail.BodyEncoding = [System.Text.Encoding]::UTF8
            if ($Attachment -and (Test-Path -LiteralPath $Attachment)) {
                $mail.Attachments.Add((New-Object System.Net.Mail.Attachment($Attachment)))
            }
            $smtp = New-Object System.Net.Mail.SmtpClient([string]$cfg.SmtpServer, [int]$cfg.SmtpPort)
            $smtp.EnableSsl = [bool]$cfg.SmtpSsl
            $smtp.Timeout = 20000
            if ($cfg.SmtpUser) {
                $pw = Unprotect-GuiReadyNotifySecret ([string]$cfg.SmtpPassword)
                $smtp.Credentials = New-Object System.Net.NetworkCredential([string]$cfg.SmtpUser, $pw)
            }
            $smtp.Send($mail)
            $smtp.Dispose(); $mail.Dispose()
            $channels += 'smtp'
            Write-Log ('通知已发邮件：' + $Title) 'OK'
        } catch {
            Write-Log ('邮件通知失败：' + $_.Exception.Message) 'WARN'
            $result.Error = '邮件：' + $_.Exception.Message
        }
    }

    # ---- Webhook
    if ($cfg.WebhookUrl) {
        try {
            $payload = switch ([string]$cfg.WebhookType) {
                'dingtalk' { @{ msgtype = 'text'; text = @{ content = $body } } | ConvertTo-Json -Depth 5 -Compress }
                'feishu'   { @{ msg_type = 'text'; content = @{ text = $body } } | ConvertTo-Json -Depth 5 -Compress }
                'wecom'    { @{ msgtype = 'text'; text = @{ content = $body } } | ConvertTo-Json -Depth 5 -Compress }
                default    { @{ title = $Title; text = $Text; level = $Level; host = $env:COMPUTERNAME; time = (Get-Date).ToString('o') } | ConvertTo-Json -Depth 5 -Compress }
            }
            $resp = Invoke-WebRequest -Uri ([string]$cfg.WebhookUrl) -Method Post -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $channels += ('webhook(' + $cfg.WebhookType + ')')
            Write-Log ('通知已发 Webhook（HTTP {0}）：{1}' -f $resp.StatusCode, $Title) 'OK'
        } catch {
            Write-Log ('Webhook 通知失败：' + $_.Exception.Message) 'WARN'
            if (-not $result.Error) { $result.Error = 'Webhook：' + $_.Exception.Message }
        }
    }

    $result.Sent = $channels.Count -gt 0
    $result.Channels = $channels
    if (-not $channels -and -not $result.Error) { $result.Error = '没有可用的通知渠道（SMTP 或 Webhook 都没配全）' }
    Write-GuiReadyNotifyLog ((@{ time = (Get-Date).ToString('o'); level = $Level; title = $Title; text = $Text; sent = $result.Sent; channels = $channels; error = $result.Error } | ConvertTo-Json -Compress))
    return [pscustomobject]$result
}

function Get-GuiReadyNotifyLog {
    param([int]$Max = 50)
    $rows = @()
    $p = Get-GuiReadyNotifyLogPath
    if (-not (Test-Path -LiteralPath $p)) { return $rows }
    try {
        $lines = @(Get-Content -LiteralPath $p -Encoding UTF8 -Tail $Max)
        foreach ($l in $lines) {
            try {
                $j = $l | ConvertFrom-Json
                $rows += [pscustomobject]@{
                    Time     = [string]$j.time
                    Level    = [string]$j.level
                    Title    = [string]$j.title
                    Text     = [string]$j.text
                    Sent     = [bool]$j.sent
                    Channels = (@($j.channels) -join ',')
                    Error    = [string]$j.error
                }
            } catch { }
        }
    } catch { }
    return $rows
}

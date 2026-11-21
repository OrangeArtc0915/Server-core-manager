# GuiReady 系统管理 runner：Windows Update / 网络 / 账户 / 服务 / 防火墙 /
# 存储与备份 / 系统计划任务 / 角色工具（Hyper-V、IIS、打印、SMB）/ 通知。
#
# 封套与其它 runner 一致：-Mode <m> -OutFile <json> [-ArgsFile <json>]
# 写操作默认都是 DryRun=false，只有界面或动作显式传 DryRun=true 才预览。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$Id = '',
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\sys-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Update.ps1', 'GuiReady.Network.ps1',
                 'GuiReady.Accounts.ps1', 'GuiReady.Services.ps1', 'GuiReady.Firewall.ps1',
                 'GuiReady.Storage.ps1', 'GuiReady.SysTasks.ps1', 'GuiReady.RoleTools.ps1',
                 'GuiReady.Notify.ps1', 'GuiReady.Ops.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$A = @{}
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $obj = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) { $A[$prop.Name] = $prop.Value }
    } catch { }
    try { Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue } catch { }
}
if (-not $Id -and $A['Id']) { $Id = [string]$A['Id'] }

function Get-Opt { param([string]$Name, $Default = '') if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return $A[$Name] } return $Default }
function Get-OptInt { param([string]$Name, [int]$Default = 0) $n = 0; if ([int]::TryParse([string](Get-Opt $Name ''), [ref]$n)) { return $n } return $Default }
function Get-OptBool { param([string]$Name, [bool]$Default = $false) $v = Get-Opt $Name ''; if ($v -eq '' -or $null -eq $v) { return $Default }; return [bool]($v -eq $true -or [string]$v -eq 'true' -or [string]$v -eq '1') }

function Write-SysResult {
    param($Data, $Items, [string]$ErrorText = '')
    $o = [ordered]@{ Mode = $Mode; Stamp = (Get-Date).ToString('o'); Error = $ErrorText; Data = $Data; Items = @($Items) }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $json = $o | ConvertTo-Json -Depth 10 -Compress
        $tmp = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    switch ($Mode) {
        # ---------------------------------------------------------- Windows Update
        'update-list' {
            $r = Get-GuiReadyPendingUpdate
            Write-SysResult -Data ([pscustomobject]@{
                Auto = $r.Auto; Error = $r.Error; Seconds = $r.Seconds; Count = @($r.Items).Count; LastChange = $r.LastChange
            }) -Items $r.Items
        }
        'update-install' {
            $raw = [string](Get-Opt 'Indexes' '')
            $idx = @()
            foreach ($x in ($raw -split '[;,\s]+')) { if ($x.Trim()) { $idx += [int]$x.Trim() } }
            if ($idx.Count -eq 0 -and -not (Get-OptBool 'All' $false)) { throw '没有选中更新；要全部安装请把 All 设为 true' }
            $rows = @(Install-GuiReadyUpdate -Indexes $idx -DryRun:(Get-OptBool 'DryRun' $false))
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count }) -Items $rows
        }
        'update-history' {
            $rows = @(Get-GuiReadyUpdateHistory -Max (Get-OptInt 'Max' 30))
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count }) -Items $rows
        }
        'update-auto' {
            $m = [string](Get-Opt 'AutoMode' 'manual')
            Set-GuiReadyUpdateAuto -Mode $m -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject](Get-GuiReadyUpdateAutoState)) -Items @()
        }

        # ---------------------------------------------------------- 网络
        'network-list' {
            $st = Get-GuiReadyNetworkStatus
            Write-SysResult -Data ([pscustomobject]@{ Hostname = $st.Hostname; Routes = $st.Routes; Count = @($st.Adapters).Count }) -Items $st.Adapters
        }
        'network-set' {
            $r = Set-GuiReadyNetworkIp -Adapter ([string](Get-Opt 'Adapter' '')) -Dhcp:(Get-OptBool 'Dhcp' $false) `
                -Ip ([string](Get-Opt 'Ip' '')) -PrefixLength (Get-OptInt 'PrefixLength' 24) `
                -Gateway ([string](Get-Opt 'Gateway' '')) -Dns ([string](Get-Opt 'Dns' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data $r -Items @()
        }
        'network-adapter' {
            Set-GuiReadyNetworkAdapter -Adapter ([string](Get-Opt 'Adapter' '')) -Action ([string](Get-Opt 'Action' 'restart')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'network-dns' {
            $r = Test-GuiReadyDns -Name ([string](Get-Opt 'Name' '')) -Server ([string](Get-Opt 'Server' ''))
            Write-SysResult -Data ([pscustomobject]@{ Ms = $r.Ms; Count = @($r.Items).Count }) -Items $r.Items
        }
        'network-routes' {
            $rows = @(Get-GuiReadyRoutes -Max (Get-OptInt 'Max' 60))
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count }) -Items $rows
        }

        # ---------------------------------------------------------- 本地账户
        'account-list' {
            $st = Get-GuiReadyLocalAccounts
            Write-SysResult -Data ([pscustomobject]@{ Computer = $st.Computer; Admins = $st.Admins; RdpUsers = $st.RdpUsers; Groups = $st.Groups }) -Items $st.Users
        }
        'account-groups' {
            $st = Get-GuiReadyLocalAccounts
            Write-SysResult -Data ([pscustomobject]@{ Admins = $st.Admins; RdpUsers = $st.RdpUsers }) -Items $st.Groups
        }
        'account-add' {
            New-GuiReadyLocalUser -Name ([string](Get-Opt 'Name' '')) -Password ([string](Get-Opt 'Password' '')) `
                -Description ([string](Get-Opt 'Description' '')) -Groups ([string](Get-Opt 'Groups' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'account-update' {
            Set-GuiReadyLocalUser -Name ([string](Get-Opt 'Name' '')) -Enabled ([string](Get-Opt 'Enabled' '')) `
                -Password ([string](Get-Opt 'Password' '')) -Description ([string](Get-Opt 'Description' '')) `
                -Groups ([string](Get-Opt 'Groups' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'account-remove' {
            Remove-GuiReadyLocalUser -Name ([string](Get-Opt 'Name' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'session-list' {
            $rows = @(Get-GuiReadySessions)
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count }) -Items $rows
        }

        # ---------------------------------------------------------- 服务
        'service-list' {
            $rows = @(Get-GuiReadyServiceList -Filter ([string](Get-Opt 'Filter' '')))
            $running = @($rows | Where-Object { $_.State -eq 'Running' }).Count
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count; Running = $running }) -Items $rows
        }
        'service-action' {
            $rows = @(Set-GuiReadyServiceAction -Names ([string](Get-Opt 'Names' '')) -Action ([string](Get-Opt 'Action' 'restart')) -DryRun:(Get-OptBool 'DryRun' $false))
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count; Failed = @($rows | Where-Object { -not $_.Ok }).Count }) -Items $rows
        }
        'service-startup' {
            Set-GuiReadyServiceStartup -Names ([string](Get-Opt 'Names' '')) -Mode ([string](Get-Opt 'Mode' 'auto')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'service-recovery' {
            Set-GuiReadyServiceRecovery -Names ([string](Get-Opt 'Names' '')) -ResetDays (Get-OptInt 'ResetDays' 1) `
                -RestartMinutes (Get-OptInt 'RestartMinutes' 1) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'service-detail' {
            $d = Get-GuiReadyServiceDetail -Name ([string](Get-Opt 'Name' ''))
            Write-SysResult -Data $d -Items @()
        }

        # ---------------------------------------------------------- 防火墙
        'firewall-list' {
            $rows = @(Get-GuiReadyFirewallRules -Direction ([string](Get-Opt 'Direction' 'Inbound')) -Filter ([string](Get-Opt 'Filter' '')))
            $profiles = @(Get-GuiReadyFirewallProfile)
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count; Profiles = $profiles }) -Items $rows
        }
        'firewall-port' {
            New-GuiReadyFirewallPort -Name ([string](Get-Opt 'Name' '')) -Port ([string](Get-Opt 'Port' '')) `
                -Protocol ([string](Get-Opt 'Protocol' 'TCP')) -Action ([string](Get-Opt 'RuleAction' 'Allow')) `
                -Profile ([string](Get-Opt 'Profile' 'Any')) -RemoteAddress ([string](Get-Opt 'RemoteAddress' 'Any')) `
                -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'firewall-toggle' {
            Set-GuiReadyFirewallRuleEnabled -Name ([string](Get-Opt 'Name' '')) -Enabled:(Get-OptBool 'Enabled' $true) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'firewall-remove' {
            Remove-GuiReadyFirewallRule -Name ([string](Get-Opt 'Name' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }

        # ---------------------------------------------------------- 存储与备份
        'storage-list' {
            $st = Get-GuiReadyStorageStatus
            Write-SysResult -Data ([pscustomobject]@{ Computer = $st.Computer; Volumes = $st.Volumes; Snapshots = $st.Snapshots }) -Items $st.Disks
        }
        'storage-volume' {
            Set-GuiReadyVolumeAction -Action ([string](Get-Opt 'VolumeAction' 'extend')) -DriveLetter ([string](Get-Opt 'DriveLetter' '')) `
                -DiskNumber (Get-OptInt 'DiskNumber' -1) -FileSystem ([string](Get-Opt 'FileSystem' 'NTFS')) `
                -Label ([string](Get-Opt 'Label' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'storage-cleanup' {
            $r = Clear-GuiReadyTempSpace -OlderThanDays (Get-OptInt 'OlderThanDays' 1) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data $r -Items @()
        }
        'vss-list' {
            $rows = @(Get-GuiReadyShadowCopies)
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count }) -Items $rows
        }
        'vss-create' {
            New-GuiReadyShadowCopy -Volume ([string](Get-Opt 'Volume' 'C:\')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'vss-remove' {
            Remove-GuiReadyShadowCopy -Id ([string](Get-Opt 'ShadowId' $Id)) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'wb-status' {
            Write-SysResult -Data (Get-GuiReadyWbStatus) -Items @()
        }
        'wb-start' {
            Start-GuiReadyWbBackup -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'wb-history' {
            $rows = @(Get-GuiReadyWbHistory -Max (Get-OptInt 'Max' 20))
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count }) -Items $rows
        }
        'wb-install' {
            Install-GuiReadyWbFeature -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }

        # ---------------------------------------------------------- 系统计划任务
        'systask-list' {
            $rows = @(Get-GuiReadySystemTasks -Filter ([string](Get-Opt 'Filter' '')))
            if (-not (Get-OptBool 'IncludeOwn' $false)) { $rows = @($rows | Where-Object { -not $_.IsOwn }) }
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count }) -Items $rows
        }
        'systask-detail' {
            Write-SysResult -Data (Get-GuiReadySystemTaskDetail -Name ([string](Get-Opt 'Name' '')) -TaskPath ([string](Get-Opt 'TaskPath' '\'))) -Items @()
        }
        'systask-action' {
            Set-GuiReadySystemTaskAction -Name ([string](Get-Opt 'Name' '')) -TaskPath ([string](Get-Opt 'TaskPath' '\')) `
                -Action ([string](Get-Opt 'TaskAction' 'run')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }

        # ---------------------------------------------------------- 角色工具
        'role-tools' {
            Write-SysResult -Data (Get-GuiReadyRoleToolsAvailability) -Items @()
        }
        'hyperv-list' {
            $rows = @(Get-GuiReadyVmList)
            $snaps = @(Get-GuiReadyVmSnapshots)
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count; Snapshots = $snaps; Available = (Get-GuiReadyRoleToolsAvailability).HyperV }) -Items $rows
        }
        'hyperv-action' {
            Set-GuiReadyVmAction -Name ([string](Get-Opt 'Name' '')) -Action ([string](Get-Opt 'VmAction' 'start')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'hyperv-snapshot' {
            Invoke-GuiReadyVmSnapshot -Action ([string](Get-Opt 'SnapshotAction' 'create')) -VmName ([string](Get-Opt 'VmName' '')) `
                -SnapshotName ([string](Get-Opt 'SnapshotName' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'iis-list' {
            $r = Get-GuiReadyIisSites
            Write-SysResult -Data ([pscustomobject]@{ Pools = $r.Pools; Available = (Get-GuiReadyRoleToolsAvailability).IIS }) -Items $r.Sites
        }
        'iis-action' {
            Set-GuiReadyIisAction -Action ([string](Get-Opt 'IisAction' 'site-restart')) -Name ([string](Get-Opt 'Name' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'print-list' {
            $rows = @(Get-GuiReadyPrinters)
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count; Available = (Get-GuiReadyRoleToolsAvailability).Print }) -Items $rows
        }
        'print-action' {
            Set-GuiReadyPrinterAction -Name ([string](Get-Opt 'Name' '')) -Action ([string](Get-Opt 'PrintAction' 'clear-jobs')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'share-list' {
            $rows = @(Get-GuiReadySmbShares)
            $sessions = @(Get-GuiReadySmbSessions)
            $files = @(Get-GuiReadySmbOpenFiles)
            Write-SysResult -Data ([pscustomobject]@{ Sessions = $sessions; OpenFiles = $files; Available = (Get-GuiReadyRoleToolsAvailability).Smb }) -Items $rows
        }
        'share-add' {
            New-GuiReadySmbShare -Name ([string](Get-Opt 'Name' '')) -Path ([string](Get-Opt 'Path' '')) `
                -Description ([string](Get-Opt 'Description' '')) -FullAccess ([string](Get-Opt 'FullAccess' 'Administrators')) `
                -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'share-remove' {
            Remove-GuiReadySmbShare -Name ([string](Get-Opt 'Name' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }
        'share-close' {
            Close-GuiReadySmbOpenFile -FileId ([string](Get-Opt 'FileId' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Ok = $true }) -Items @()
        }

        # ---------------------------------------------------------- 通知
        'notify-status' {
            $cfg = Get-GuiReadyNotifyConfig
            $safe = [ordered]@{}
            foreach ($k in @($cfg.Keys)) { $safe[$k] = $cfg[$k] }
            if ($safe['SmtpPassword']) { $safe['SmtpPassword'] = '******' }
            $safe['HasPassword'] = [bool]$cfg.SmtpPassword
            Write-SysResult -Data ([pscustomobject]$safe) -Items @(Get-GuiReadyNotifyLog -Max 20)
        }
        'notify-save' {
            $cfg = Set-GuiReadyNotifyConfig -Enabled ([string](Get-Opt 'Enabled' '')) -SmtpServer ([string](Get-Opt 'SmtpServer' '')) `
                -SmtpPort ([string](Get-Opt 'SmtpPort' '')) -SmtpSsl ([string](Get-Opt 'SmtpSsl' '')) `
                -SmtpUser ([string](Get-Opt 'SmtpUser' '')) -SmtpPassword ([string](Get-Opt 'SmtpPassword' '')) `
                -ClearPassword:(Get-OptBool 'ClearPassword' $false) -SmtpFrom ([string](Get-Opt 'SmtpFrom' '')) `
                -SmtpTo ([string](Get-Opt 'SmtpTo' '')) -WebhookType ([string](Get-Opt 'WebhookType' '')) `
                -WebhookUrl ([string](Get-Opt 'WebhookUrl' '')) -QuietFrom ([string](Get-Opt 'QuietFrom' '')) `
                -QuietTo ([string](Get-Opt 'QuietTo' '')) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-SysResult -Data ([pscustomobject]@{ Enabled = $cfg.Enabled }) -Items @()
        }
        'notify-test' {
            $r = Send-GuiReadyNotify -Title ('测试通知（' + $env:COMPUTERNAME + '）') -Text '如果你看到这条消息，说明通知渠道配置正确。' -Level 'Info' -IgnoreQuiet
            Write-SysResult -Data $r -Items @()
        }
        'notify-send' {
            $r = Send-GuiReadyNotify -Title ([string](Get-Opt 'Title' 'SCM 通知')) -Text ([string](Get-Opt 'Text' '')) -Level ([string](Get-Opt 'Level' 'Info'))
            Write-SysResult -Data $r -Items @()
        }
        'notify-log' {
            $rows = @(Get-GuiReadyNotifyLog -Max (Get-OptInt 'Max' 50))
            Write-SysResult -Data ([pscustomobject]@{ Count = $rows.Count }) -Items $rows
        }

        default {
            Write-SysResult -Data $null -Items @() -ErrorText ('unknown mode: ' + $Mode)
            exit 2
        }
    }
    exit 0
} catch {
    Write-SysResult -Data $null -Items @() -ErrorText $_.Exception.Message
    exit 1
}

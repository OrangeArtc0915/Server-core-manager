# Server Core Manager 命令行入口。
# 用法：scm <verb> [options] [--json]

$script:CliJson = $false
$script:CliArgv = @()

function Get-CliOpt {
    param([string]$Name, $Default = '')
    for ($i = 0; $i -lt $script:CliArgv.Count; $i++) {
        if ([string]$script:CliArgv[$i] -eq ('--' + $Name) -and ($i + 1) -lt $script:CliArgv.Count) { return [string]$script:CliArgv[$i + 1] }
    }
    return $Default
}
function Get-CliInt {
    param([string]$Name, [int]$Default = 0)
    $n = 0
    if ([int]::TryParse((Get-CliOpt $Name ''), [ref]$n)) { return $n }
    return $Default
}
function Has-CliFlag { param([string]$Name) return (@($script:CliArgv) -contains ('--' + $Name)) }

function Write-CliResult {
    param([string]$Verb, $Data, [string]$Text = '')
    if ($script:CliJson) {
        [ordered]@{ ok = $true; verb = $Verb; data = $Data } | ConvertTo-Json -Depth 10
    } elseif ($PSBoundParameters.ContainsKey('Text')) {
        $Text
    } else {
        $Data | Format-List | Out-String
    }
}
function Write-CliError {
    param([string]$Verb, [string]$Message)
    if ($script:CliJson) {
        [ordered]@{ ok = $false; verb = $Verb; error = $Message } | ConvertTo-Json -Depth 5
    } else {
        'ERROR: ' + $Message
    }
}

function Invoke-GuiReadyCli {
    param([string[]]$CliArgs)

    $script:CliJson = (@($CliArgs) -contains '--json')
    $script:CliArgv = @($CliArgs | Where-Object { $_ -ne '--json' })
    $script:CliExitCode = 0
    $verb = if ($script:CliArgv.Count -gt 0) { ([string]$script:CliArgv[0]).ToLowerInvariant() } else { 'help' }

    try {
        switch ($verb) {
            'help' {
                $text = @'
Server Core Manager CLI

  scm status                         系统概览（CPU / 内存 / 磁盘 / 运行时长）
  scm metrics [--days 7] [--report]  性能历史；--report 生成 HTML 报表
  scm alerts [list|check|history]    告警规则与立即检查
  scm backup [--share \\host\share] [--drivers] [--full-registry]
  scm update [--install]            检查 / 安装 Windows 更新
  scm run <actionId> [--set k=v ...] 运行动作（有任务记录与审计）
  scm tools list | download <id> [--source github|gitee]
  scm certs [list] [--location My|Root|CA]
  scm drivers [list|problems|disks]
  scm startup [list|toggle <id> on|off]
  scm batch exec --hosts <spec> --command <cmd>
  scm batch collect --hosts <spec>
  scm batch install --hosts <spec> --package <pkg> [--manager choco|winget]
  scm scripts [list|run <id>]

  所有命令都支持 --json，输出 { ok, verb, data }。
'@
                Write-CliResult -Verb 'help' -Data @{ Version = '2.4' } -Text $text.Trim()
            }

            'status' {
                $s = Get-GuiReadyMetricsSample
                $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                $data = [pscustomobject]@{
                    Computer = $env:COMPUTERNAME
                    OS = if ($os) { [string]$os.Caption } else { '' }
                    Version = if ($os) { [string]$os.Version } else { '' }
                    Time = $s.Time; CpuPct = $s.CpuPct; MemPct = $s.MemPct
                    DiskFreeGB = $s.DiskFreeGB; DiskTotalGB = $s.DiskTotalGB
                    ProcCount = $s.ProcCount; UptimeHours = $s.UptimeHours
                }
                $text = @(
                    ('计算机 : ' + $data.Computer),
                    ('系统   : ' + $data.OS + ' ' + $data.Version),
                    ('CPU    : ' + $data.CpuPct + ' %'),
                    ('内存   : ' + $data.MemPct + ' %'),
                    ('系统盘 : ' + $data.DiskFreeGB + ' / ' + $data.DiskTotalGB + ' GB 可用'),
                    ('进程   : ' + $data.ProcCount),
                    ('运行   : ' + $data.UptimeHours + ' 小时')
                ) -join [Environment]::NewLine
                Write-CliResult -Verb 'status' -Data $data -Text $text
            }

            'metrics' {
                $days = Get-CliInt 'days' 7
                if (Has-CliFlag 'report') {
                    $file = New-GuiReadyMetricsReport -Days $days
                    Write-CliResult -Verb 'metrics' -Data @{ Days = $days; Report = $file } -Text ('报表已生成：' + $file)
                } else {
                    $rows = @(Get-GuiReadyMetricsHistory -Days $days)
                    $sum = Get-GuiReadyMetricsSummary -Rows $rows
                    $text = ('样本 {0} 条 ｜ CPU 平均 {1}% 峰值 {2}% ｜ 内存平均 {3}% 峰值 {4}% ｜ 系统盘最小可用 {5} GB' -f $sum.Count, $sum.CpuAvg, $sum.CpuMax, $sum.MemAvg, $sum.MemMax, $sum.DiskFreeMin)
                    Write-CliResult -Verb 'metrics' -Data @{ Days = $days; Summary = $sum } -Text $text
                }
            }

            'alerts' {
                $sub = if ($script:CliArgv.Count -gt 1) { ([string]$script:CliArgv[1]).ToLowerInvariant() } else { 'list' }
                if ($sub -eq 'check') {
                    $r = Invoke-GuiReadyAlertCheck
                    Write-CliResult -Verb 'alerts' -Data $r -Text ('告警检查完成，触发 ' + @($r.Fired).Count + ' 条')
                } elseif ($sub -eq 'history') {
                    $items = @(Get-GuiReadyAlertHistory -Max (Get-CliInt 'max' 50))
                    Write-CliResult -Verb 'alerts' -Data @{ Count = $items.Count; Items = $items } -Text (($items | ForEach-Object { '{0}  {1}  {2}' -f $_.Time, $_.Name, $_.Value }) -join [Environment]::NewLine)
                } else {
                    $items = @(Get-GuiReadyAlertRules)
                    $text = (($items | ForEach-Object { '{0,-16} {1,-10} {2} {3}  {4}' -f $_.Id, $_.Metric, $_.Operator, $_.Threshold, $_.Name }) -join [Environment]::NewLine)
                    Write-CliResult -Verb 'alerts' -Data @{ Count = $items.Count; Items = $items } -Text $text
                }
            }

            'backup' {
                $b = New-GuiReadySysBackup -WithDrivers:(Has-CliFlag 'drivers') -FullRegistry:(Has-CliFlag 'full-registry')
                $share = Get-CliOpt 'share' ''
                if ($share) {
                    Copy-GuiReadySysBackupToShare -File $b.File -Share $share -Keep (Get-CliInt 'keep' 5) | Out-Null
                }
                $text = ('备份完成：{0}（{1} MB）' -f $b.File, $b.SizeMB)
                if ($share) { $text += [Environment]::NewLine + '已复制到：' + $share }
                Write-CliResult -Verb 'backup' -Data $b -Text $text
            }

            'update' {
                if (Has-CliFlag 'install') {
                    $r = @(Install-GuiReadyUpdate -Indexes @())
                    Write-CliResult -Verb 'update' -Data @{ Installed = $r.Count; Items = $r } -Text ('已安装 ' + $r.Count + ' 个更新。')
                } else {
                    $p = Get-GuiReadyPendingUpdate -TimeoutMin (Get-CliInt 'timeout' 8)
                    $text = ('待安装更新：{0} 个 ｜ 检查用时 {1} 秒' -f @($p.Items).Count, $p.Seconds)
                    if ($p.Error) { $text = $p.Error }
                    Write-CliResult -Verb 'update' -Data $p -Text $text
                }
            }

            'run' {
                if ($script:CliArgv.Count -lt 2) { throw '用法：scm run <actionId> [--set k=v ...]' }
                $id = [string]$script:CliArgv[1]
                $pairs = @{}
                for ($i = 0; $i -lt $script:CliArgv.Count; $i++) {
                    if ([string]$script:CliArgv[$i] -eq '--set' -and ($i + 1) -lt $script:CliArgv.Count) {
                        $kv = [string]$script:CliArgv[$i + 1]
                        $ix = $kv.IndexOf('=')
                        if ($ix -gt 0) { $pairs[$kv.Substring(0, $ix)] = $kv.Substring($ix + 1) }
                        $i++
                    }
                }
                $root = [string]$script:GuiReadyRoot
                if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
                $tmp = Join-Path $env:TEMP ('scm-cli-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                $argsFile = Join-Path $tmp 'args.json'
                ($pairs | ConvertTo-Json -Compress) | Out-File -LiteralPath $argsFile -Encoding UTF8
                $logFile = Join-Path $tmp 'run.log'
                $jobId = 'cli-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'gui\Run-GuiReadyAction.ps1') `
                    -Action $id -ArgsFile $argsFile -LogFile $logFile -JobId $jobId | Out-Null
                $code = $LASTEXITCODE
                $tail = if (Test-Path -LiteralPath $logFile) { @(Get-Content -LiteralPath $logFile -Tail 30 -Encoding UTF8) -join [Environment]::NewLine } else { '' }
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
                Write-CliResult -Verb 'run' -Data @{ ActionId = $id; JobId = $jobId; ExitCode = $code; Log = $tail } -Text (('动作 {0} 结束，退出码 {1}' -f $id, $code) + [Environment]::NewLine + $tail)
                if ($code -ne 0) { $script:CliExitCode = 1 }
            }

            'tools' {
                $sub = if ($script:CliArgv.Count -gt 1) { ([string]$script:CliArgv[1]).ToLowerInvariant() } else { 'list' }
                if ($sub -eq 'download') {
                    if ($script:CliArgv.Count -lt 3) { throw '用法：scm tools download <id> [--source github|gitee]' }
                    $r = Install-GuiReadyPlugin -Id ([string]$script:CliArgv[2]) -Source ([string](Get-CliOpt 'source' 'github'))
                    Write-CliResult -Verb 'tools' -Data $r -Text ('已下载 ' + $r.Id + ' → ' + $r.Path)
                } else {
                    $items = @(Get-GuiReadyPluginStatus)
                    $text = (($items | ForEach-Object { '{0,-12} {1,-8} {2}' -f $_.Id, $_.LocalState, $_.Branch }) -join [Environment]::NewLine)
                    Write-CliResult -Verb 'tools' -Data @{ Count = $items.Count; Items = $items } -Text $text
                }
            }

            'certs' {
                $loc = Get-CliOpt 'location' 'My'
                $items = @(Get-GuiReadyCertificateList -Location $loc)
                $text = (($items | ForEach-Object { '{0}  {1}  {2} 天  {3}' -f $_.NotAfter, $_.Subject, $_.DaysLeft, $_.Thumbprint }) -join [Environment]::NewLine)
                Write-CliResult -Verb 'certs' -Data @{ Location = $loc; Count = $items.Count; Items = $items } -Text $text
            }

            'drivers' {
                $sub = if ($script:CliArgv.Count -gt 1) { ([string]$script:CliArgv[1]).ToLowerInvariant() } else { 'list' }
                if ($sub -eq 'problems') {
                    $items = @(Get-GuiReadyProblemDevices)
                    Write-CliResult -Verb 'drivers' -Data @{ Count = $items.Count; Items = $items } -Text (($items | ForEach-Object { '{0}  {1}  code={2}' -f $_.Device, $_.Class, $_.Code }) -join [Environment]::NewLine)
                } elseif ($sub -eq 'disks') {
                    $items = @(Get-GuiReadyDiskHealth)
                    Write-CliResult -Verb 'drivers' -Data @{ Count = $items.Count; Items = $items } -Text (($items | ForEach-Object { '{0}  {1}  {2} GB  {3}' -f $_.Disk, $_.Media, $_.SizeGB, $_.Health }) -join [Environment]::NewLine)
                } else {
                    $items = @(Get-GuiReadyDriverList)
                    Write-CliResult -Verb 'drivers' -Data @{ Count = $items.Count; Items = $items } -Text (($items | ForEach-Object { '{0}  {1}  {2}' -f $_.Device, $_.Version, $_.Status }) -join [Environment]::NewLine)
                }
            }

            'startup' {
                $sub = if ($script:CliArgv.Count -gt 1) { ([string]$script:CliArgv[1]).ToLowerInvariant() } else { 'list' }
                if ($sub -eq 'toggle' -and $script:CliArgv.Count -ge 4) {
                    $id = [string]$script:CliArgv[2]
                    $enabled = ([string]$script:CliArgv[3] -match '^(on|enable|true|1)$')
                    Set-GuiReadyStartupItem -Id $id -Enabled $enabled
                    Write-CliResult -Verb 'startup' -Data @{ Id = $id; Enabled = $enabled } -Text ('启动项 {0} → {1}' -f $id, $(if ($enabled) { '启用' } else { '禁用' }))
                } else {
                    $items = @(Get-GuiReadyStartupItems)
                    Write-CliResult -Verb 'startup' -Data @{ Count = $items.Count; Items = $items } -Text (($items | ForEach-Object { '{0,-8} {1,-30} {2}' -f $_.Type, $_.Name, $_.Source }) -join [Environment]::NewLine)
                }
            }

            'batch' {
                $sub = if ($script:CliArgv.Count -gt 1) { ([string]$script:CliArgv[1]).ToLowerInvariant() } else { 'collect' }
                $spec = Get-CliOpt 'hosts' ''
                if ($sub -eq 'exec') {
                    $r = Invoke-GuiReadyBatchExec -Spec $spec -Command (Get-CliOpt 'command' '') -TimeoutSec (Get-CliInt 'timeout' 120)
                } elseif ($sub -eq 'install') {
                    $r = Invoke-GuiReadyBatchInstall -Spec $spec -Package (Get-CliOpt 'package' '') -Manager (Get-CliOpt 'manager' 'choco')
                } else {
                    $r = Invoke-GuiReadyBatchCollect -Spec $spec
                }
                Write-CliResult -Verb 'batch' -Data $r -Text ('任务 {0}：成功 {1} / 失败 {2} / 共 {3}' -f $r.TaskId, $r.Succeeded, $r.Failed, $r.Total)
            }

            'scripts' {
                $sub = if ($script:CliArgv.Count -gt 1) { ([string]$script:CliArgv[1]).ToLowerInvariant() } else { 'list' }
                if ($sub -eq 'run' -and $script:CliArgv.Count -ge 3) {
                    $r = Invoke-GuiReadyScript -Id ([string]$script:CliArgv[2])
                    Write-CliResult -Verb 'scripts' -Data $r -Text $r.Output
                } else {
                    $items = @(Get-GuiReadyScriptLibrary)
                    Write-CliResult -Verb 'scripts' -Data @{ Count = $items.Count; Items = $items } -Text (($items | ForEach-Object { '{0,-20} {1,-8} {2}' -f $_.Id, $_.Risk, $_.Name }) -join [Environment]::NewLine)
                }
            }

            default {
                Write-CliError -Verb $verb -Message ('未知命令：' + $verb + '。运行 scm help 查看用法。')
                $script:CliExitCode = 1
            }
        }
    } catch {
        Write-CliError -Verb $verb -Message $_.Exception.Message
        $script:CliExitCode = 1
    }
}

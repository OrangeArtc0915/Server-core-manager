# GuiReady pipeline: one-click end-to-end run with resume across reboots

$Global:GuiReadyPipelineStateFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\pipeline.json'
$Global:GuiReadyPipelineResumeTask = 'GuiReadyPipelineResume'
$Global:GuiReadyResumeScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Resume-GuiReadyPipeline.ps1'

function Get-GuiReadyPipelineSteps {
    return @(
        [pscustomobject]@{ Name = 'Detect';   Title = '环境探测' }
        [pscustomobject]@{ Name = 'Matrix';   Title = '版本适配矩阵与能力差距' }
        [pscustomobject]@{ Name = 'Fod';      Title = '安装 App Compatibility FOD（按需）' }
        [pscustomobject]@{ Name = 'Reboot';   Title = '重启以让 FOD 生效（按需）' }
        [pscustomobject]@{ Name = 'Verify';   Title = '重启后复核' }
        [pscustomobject]@{ Name = 'DotNet';   Title = '按需补齐 .NET 运行时' }
        [pscustomobject]@{ Name = 'Catalog';  Title = '程序兼容档案匹配' }
        [pscustomobject]@{ Name = 'Diagnose'; Title = '对指定程序做启动诊断' }
        [pscustomobject]@{ Name = 'GuiTest';  Title = 'GUI 能力自检' }
        [pscustomobject]@{ Name = 'Summary';  Title = '汇总报告' }
    )
}

function Get-GuiReadyPipelineState {
    if (-not (Test-Path -LiteralPath $Global:GuiReadyPipelineStateFile)) { return $null }
    try {
        return ((Get-Content -LiteralPath $Global:GuiReadyPipelineStateFile -Raw -Encoding UTF8) | ConvertFrom-Json)
    } catch {
        Write-Log ('读取流程状态失败: ' + $_.Exception.Message) 'WARN'
        return $null
    }
}

function Save-GuiReadyPipelineState {
    param([Parameter(Mandatory = $true)]$State)

    $dir = Split-Path -Parent $Global:GuiReadyPipelineStateFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try {
        $State.UpdatedAt = (Get-Date).ToString('s')
        [System.IO.File]::WriteAllText($Global:GuiReadyPipelineStateFile, ($State | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding -ArgumentList $true))
        return $true
    } catch {
        Write-Log ('保存流程状态失败: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function New-GuiReadyPipelineState {
    param([string[]]$AppPaths = @(), [switch]$AutoReboot, [int]$MaxReboots = 3)

    $steps = @()
    foreach ($s in (Get-GuiReadyPipelineSteps)) {
        # DurationMs：本步耗时（毫秒）。0 表示还没跑过。
        # 存进 state 而不是只打日志：重启续跑后，前面已跑的步骤耗时仍然保留。
        $steps += [pscustomobject]@{ Name = $s.Name; Title = $s.Title; Status = 'pending'; Note = ''; At = ''; DurationMs = 0 }
    }
    return [pscustomobject]@{
        StartedAt   = (Get-Date).ToString('s')
        UpdatedAt   = (Get-Date).ToString('s')
        StepIndex   = 0
        Steps       = $steps
        RebootCount = 0
        MaxReboots  = $MaxReboots
        AutoReboot  = [bool]$AutoReboot
        AppPaths    = @($AppPaths)
        Finished    = $false
        Result      = ''
        MachineName = $env:COMPUTERNAME
    }
}

function Set-GuiReadyPipelineStep {
    param($State, [string]$Name, [string]$Status, [string]$Note = '')

    foreach ($s in $State.Steps) {
        if ($s.Name -eq $Name) {
            $s.Status = $Status
            if ($Note) { $s.Note = $Note }
            $s.At = (Get-Date).ToString('s')
            break
        }
    }
    Save-GuiReadyPipelineState -State $State | Out-Null
}

function Register-GuiReadyPipelineResumeTask {
    if (-not (Test-Path -LiteralPath $Global:GuiReadyResumeScript)) {
        Write-Log ('续跑脚本不存在: ' + $Global:GuiReadyResumeScript) 'ERROR'
        return $false
    }
    try {
        Unregister-ScheduledTask -TaskName $Global:GuiReadyPipelineResumeTask -Confirm:$false -ErrorAction SilentlyContinue
        $arg  = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Global:GuiReadyResumeScript)
        $act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $trg  = New-ScheduledTaskTrigger -AtStartup
        $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -ExecutionTimeLimit (New-TimeSpan -Hours 2) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 2)
        Register-ScheduledTask -TaskName $Global.GuiReadyPipelineResumeTask -Action $act -Principal $prin -Settings $set -Trigger $trg -Force -ErrorAction Stop | Out-Null
        Write-Log ('已注册开机续跑任务: {0}（重启后自动继续，跑完会自己注销）' -f $Global:GuiReadyPipelineResumeTask) 'OK'
        return $true
    } catch {
        # 上面那行有意的属性写法在部分环境会失败，这里用标准写法兜底
        try {
            Register-ScheduledTask -TaskName $Global:GuiReadyPipelineResumeTask -Action $act -Principal $prin -Settings $set -Trigger $trg -Force | Out-Null
            Write-Log ('已注册开机续跑任务: {0}' -f $Global:GuiReadyPipelineResumeTask) 'OK'
            return $true
        } catch {
            Write-Log ('注册续跑任务失败: ' + $_.Exception.Message) 'ERROR'
            return $false
        }
    }
}

function Unregister-GuiReadyPipelineResumeTask {
    try {
        Unregister-ScheduledTask -TaskName $Global:GuiReadyPipelineResumeTask -Confirm:$false -ErrorAction SilentlyContinue
    } catch { }
}

function Show-GuiReadyPipelineState {
    $st = Get-GuiReadyPipelineState
    Write-Head '流程状态'
    if (-not $st) {
        Write-Log '没有进行中的流程（或没有状态文件）。' 'INFO'
        return $null
    }
    Write-Log ('开始时间  : {0}' -f $st.StartedAt) 'INFO'
    Write-Log ('最后更新  : {0}' -f $st.UpdatedAt) 'INFO'
    Write-Log ('当前步骤  : {0}/{1}' -f ($st.StepIndex + 1), $st.Steps.Count) 'INFO'
    Write-Log ('重启次数  : {0} / 上限 {1}' -f $st.RebootCount, $st.MaxReboots) 'INFO'
    Write-Log ('已结束    : {0}   结果: {1}' -f $st.Finished, $st.Result) 'INFO'
    if ($st.AppPaths -and $st.AppPaths.Count -gt 0) { Write-Log ('关注程序  : {0}' -f ($st.AppPaths -join '; ')) 'INFO' }
    Write-Log ''
    foreach ($s in $st.Steps) {
        $mark = switch ($s.Status) {
            'done'       { '[完成]' }
            'skipped'    { '[跳过]' }
            'failed'     { '[失败]' }
            'waiting'    { '[待续]' }
            'running'    { '[进行]' }
            default      { '[待做]' }
        }
        Write-Log ('  {0} {1,-10} {2}  {3}  {4}' -f $mark, $s.Title,
            $(if ($s.DurationMs -gt 0) { '{0:N1}s' -f ($s.DurationMs / 1000) } else { '-' }),
            $s.At, $s.Note) 'INFO'
    }
    $task = Get-ScheduledTask -TaskName $Global:GuiReadyPipelineResumeTask -ErrorAction SilentlyContinue
    if ($task) { Write-Log ('续跑任务: 已注册（状态 {0}）' -f $task.State) 'WARN' } else { Write-Log '续跑任务: 未注册' 'INFO' }
    return $st
}

function Stop-GuiReadyPipeline {
    Unregister-GuiReadyPipelineResumeTask
    if (Test-Path -LiteralPath $Global:GuiReadyPipelineStateFile) {
        Remove-Item -LiteralPath $Global:GuiReadyPipelineStateFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log '已终止流程并注销续跑任务。' 'OK'
}

function Invoke-GuiReadyPipeline {
    param(
        [string[]]$AppPaths = @(),
        [switch]$AutoReboot,
        [switch]$Resume,
        [switch]$SkipReboot,
        [int]$MaxReboots = 3
    )

    $steps = Get-GuiReadyPipelineSteps

    $state = $null
    if ($Resume) {
        $state = Get-GuiReadyPipelineState
        if (-not $state) {
            Write-Log '没有可续跑的状态文件。' 'ERROR'
            return
        }
    }
    if (-not $state) {
        $state = New-GuiReadyPipelineState -AppPaths $AppPaths -AutoReboot:([bool]$AutoReboot) -MaxReboots $MaxReboots
        Save-GuiReadyPipelineState -State $state | Out-Null
    }

    $modeText = '新建'
    if ($Resume) { $modeText = '续跑' }
    Write-Head ('一键 GUI 就绪流程（' + $modeText + '）')
    Write-Log ('机器={0}  步骤数={1}  从第 {2} 步开始' -f $state.MachineName, $state.Steps.Count, ($state.StepIndex + 1)) 'INFO'
    if ($state.AppPaths -and $state.AppPaths.Count -gt 0) { Write-Log ('关注程序: {0}' -f ($state.AppPaths -join '; ')) 'INFO' }

    $detect = $null
    $needReboot = $false
    $rebootReason = ''

    while ($state.StepIndex -lt $state.Steps.Count) {
        $step = $state.Steps[$state.StepIndex]
        if ($step.Status -eq 'done' -or $step.Status -eq 'skipped') {
            $state.StepIndex++
            Save-GuiReadyPipelineState -State $state | Out-Null
            continue
        }

        Write-Log ''
        Write-Log ('===== 步骤 {0}/{1}: {2} =====' -f ($state.StepIndex + 1), $state.Steps.Count, $step.Title) 'HEAD'
        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'running'
        $stepStart = Get-Date

        try {
            switch ($step.Name) {
                'Detect' {
                    $detect = Invoke-GuiReadyDetect -Quiet
                    Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note ('FOD=' + $detect.Assessment.FodState)
                }
                'Matrix' {
                    if (-not $detect) { $detect = Invoke-GuiReadyDetect -Quiet }
                    $m = Show-GuiReadyMatrix -Static $detect.Static -DllScan $detect.DllScan -Services $detect.Services -Sessions $detect.Sessions -Uac $detect.Uac
                    Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note ('能力缺失 ' + $m.Gap.LostCount + ' 项')
                }
                'Fod' {
                    if (-not $detect) { $detect = Invoke-GuiReadyDetect -Quiet }
                    if ($detect.Assessment.FodState -eq 'Installed') {
                        Write-Log 'FOD 已安装，跳过。' 'OK'
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'skipped' -Note '已安装'
                    } else {
                        Install-GuiReadyFod
                        $needReboot = $true
                        $rebootReason = 'App Compatibility FOD 需要重启才生效'
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note '已安装，待重启'
                    }
                }
                'Reboot' {
                    if (-not $needReboot) {
                        Write-Log '本次不需要重启，跳过。' 'OK'
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'skipped' -Note '无需重启'
                    } elseif ($SkipReboot) {
                        Write-Log '已指定 -SkipReboot，暂停在这里；请手动重启后运行续跑。' 'WARN'
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'waiting' -Note $rebootReason
                        Register-GuiReadyPipelineResumeTask | Out-Null
                        $state.StepIndex++
                        Save-GuiReadyPipelineState -State $state | Out-Null
                        return $state
                    } else {
                        $state.RebootCount++
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note ($rebootReason + '（第 ' + $state.RebootCount + ' 次重启）')
                        if ($state.RebootCount -gt $state.MaxReboots) {
                            Write-Log ('重启次数超过上限 {0}，中止流程。' -f $state.MaxReboots) 'ERROR'
                            $state.Finished = $true
                            $state.Result = '重启次数超限'
                            Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'failed' -Note '重启超限'
                            Save-GuiReadyPipelineState -State $state | Out-Null
                            return $state
                        }
                        if (-not (Register-GuiReadyPipelineResumeTask)) {
                            Write-Log '注册续跑任务失败，为保证不中断，改为暂停：请手动重启后运行续跑。' 'ERROR'
                            $state.StepIndex++
                            Save-GuiReadyPipelineState -State $state | Out-Null
                            return $state
                        }
                        $state.StepIndex++
                        Save-GuiReadyPipelineState -State $state | Out-Null
                        Write-Log ('准备重启：{0}' -f $rebootReason) 'WARN'
                        Write-Log '重启后会自动继续剩余步骤，不需要你操作。' 'OK'
                        try { Restart-Computer -Force -ErrorAction Stop } catch { Write-Log ('重启命令失败: ' + $_.Exception.Message) 'ERROR' }
                        return $state
                    }
                }
                'Verify' {
                    $detect = Invoke-GuiReadyDetect -Quiet
                    $fodOk = ($detect.Assessment.FodState -eq 'Installed')
                    $mmcOk = @($detect.DllScan | Where-Object { $_.Name -eq 'mmc.exe' -and $_.Exists }).Count -gt 0
                    $renderOk = $detect.Assessment.RenderStackReady
                    Write-Log ('FOD={0}  MMC={1}  渲染管线={2}' -f (Format-Bool $fodOk), (Format-Bool $mmcOk), (Format-Bool $renderOk)) $(if ($fodOk -and $mmcOk) { 'OK' } else { 'WARN' })
                    Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note ('FOD=' + (Format-Bool $fodOk) + ' MMC=' + (Format-Bool $mmcOk))
                }
                'DotNet' {
                    if (-not $state.AppPaths -or $state.AppPaths.Count -eq 0) {
                        Write-Log '未指定关注程序，跳过 .NET 补齐。' 'OK'
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'skipped' -Note '无关注程序'
                    } else {
                        foreach ($p in $state.AppPaths) {
                            if (Test-Path -LiteralPath $p) {
                                Write-Log ('处理: ' + $p) 'STEP'
                                Invoke-GuiReadyDotNetFix -ExePath $p
                            } else {
                                Write-Log ('跳过不存在的路径: ' + $p) 'WARN'
                            }
                        }
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note ('处理 ' + $state.AppPaths.Count + ' 个程序')
                    }
                }
                'Catalog' {
                    if (-not $state.AppPaths -or $state.AppPaths.Count -eq 0) {
                        Show-GuiReadyCatalogList | Out-Null
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note '仅列出档案'
                    } else {
                        foreach ($p in $state.AppPaths) {
                            if (Test-Path -LiteralPath $p) { Show-GuiReadyCatalogEntry -ExePath $p | Out-Null }
                        }
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note ('匹配 ' + $state.AppPaths.Count + ' 个程序')
                    }
                }
                'Diagnose' {
                    if (-not $state.AppPaths -or $state.AppPaths.Count -eq 0) {
                        Write-Log '未指定关注程序，跳过诊断。' 'OK'
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'skipped' -Note '无关注程序'
                    } else {
                        foreach ($p in $state.AppPaths) {
                            if (Test-Path -LiteralPath $p) {
                                Invoke-GuiReadyLaunchAndDiagnose -ExePath $p -WatchSeconds 20 | Out-Null
                            }
                        }
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note '已采集'
                    }
                }
                'GuiTest' {
                    if (Get-Command Start-GuiReadyGuiSelfTest -ErrorAction SilentlyContinue) {
                        Start-GuiReadyGuiSelfTest -IncludeApps | Out-Null
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note '已自检'
                    } else {
                        Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'skipped' -Note 'GuiTest 模块未加载'
                    }
                }
                'Summary' {
                    if (-not $detect) { $detect = Invoke-GuiReadyDetect -Quiet }
                    Write-Head '流程汇总'
                    foreach ($s in $state.Steps) {
                        $dur = $(if ($s.DurationMs -gt 0) { '{0,6:N1}s' -f ($s.DurationMs / 1000) } else { '     -' })
                        Write-Log ('  {0,-9} {1}  {2}  {3}' -f $s.Status, $dur, $s.Title, $s.Note) 'INFO'
                    }
                    # 只列真正跑过的步骤，按耗时倒序取前 3 —— 想在"补环境慢"上提速，
                    # 先得看清时间到底花在哪一段（通常是 FOD 联网下载）。
                    $slow = @($state.Steps | Where-Object { $_.DurationMs -gt 0 } |
                              Sort-Object DurationMs -Descending | Select-Object -First 3)
                    if ($slow.Count -gt 0) {
                        Write-Log ('  最慢步骤: ' + (($slow | ForEach-Object { '{0} {1:N1}s' -f $_.Title, ($_.DurationMs / 1000) }) -join ' · ')) 'INFO'
                    }
                    Write-Log ''
                    Write-Log $detect.Assessment.Conclusion $(if ($detect.Assessment.RenderStackReady) { 'OK' } else { 'WARN' })
                    Save-JsonReport -Object ([ordered]@{ State = $state; Assessment = $detect.Assessment }) -Name 'pipeline-summary' | Out-Null
                    Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'done' -Note '已汇总'
                }
                default {
                    Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'skipped' -Note '未知步骤'
                }
            }
        } catch {
            Write-Log ('步骤 {0} 异常: {1}' -f $step.Title, $_.Exception.Message) 'ERROR'
            Set-GuiReadyPipelineStep -State $state -Name $step.Name -Status 'failed' -Note $_.Exception.Message
        }

        # 每步耗时：慢的时候要能一眼看出卡在哪一段（例如 FOD 下载 vs 环境探测），
        # 而不是只有一句"补环境很慢"。小于 50ms 的不打日志，免得刷屏。
        try {
            $sec = ((Get-Date) - $stepStart).TotalSeconds
            $step.DurationMs = [int]($sec * 1000)
            if ($sec -ge 0.05) { Write-Log ('  ↳ 本步耗时 {0:N1}s' -f $sec) 'INFO' }
            Save-GuiReadyPipelineState -State $state | Out-Null
        } catch { }

        $state.StepIndex++
        Save-GuiReadyPipelineState -State $state | Out-Null
    }

    $state.Finished = $true
    $failed = @($state.Steps | Where-Object { $_.Status -eq 'failed' })
    $state.Result = if ($failed.Count -eq 0) { '全部完成' } else { ('有 {0} 步失败' -f $failed.Count) }
    Save-GuiReadyPipelineState -State $state | Out-Null
    Unregister-GuiReadyPipelineResumeTask
    $totalSec = 0
    try { $totalSec = [double]((($state.Steps | Measure-Object -Property DurationMs -Sum).Sum) / 1000) } catch { }
    Write-Log ('流程结束: {0}（各步合计 {1:N1}s，不含重启等待）' -f $state.Result, $totalSec) $(if ($failed.Count -eq 0) { 'OK' } else { 'WARN' })
    return $state
}

function Resume-GuiReadyPipeline {
    $state = Get-GuiReadyPipelineState
    if (-not $state) {
        Write-Log '没有可续跑的状态（可能流程已结束）。' 'WARN'
        Unregister-GuiReadyPipelineResumeTask
        return $null
    }
    if ($state.Finished) {
        Write-Log '流程已结束，无需续跑。' 'OK'
        Unregister-GuiReadyPipelineResumeTask
        return $state
    }
    Write-Log ('检测到未完成的流程（第 {0}/{1} 步），继续执行。' -f ($state.StepIndex + 1), $state.Steps.Count) 'OK'
    return Invoke-GuiReadyPipeline -Resume
}

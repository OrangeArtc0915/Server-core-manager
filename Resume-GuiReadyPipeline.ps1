# GuiReady resume entry point.
# Registered as an AtStartup scheduled task by the pipeline; runs after a reboot to continue.

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot

$logDir = Join-Path $here 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$Global:GuiReadyLogFile = Join-Path $logDir ('resume-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Detect.ps1', 'GuiReady.PeInspect.ps1',
                 'GuiReady.Fod.ps1', 'GuiReady.GuiShell.ps1', 'GuiReady.RdpFix.ps1',
                 'GuiReady.DotNet.ps1', 'GuiReady.GuiTest.ps1', 'GuiReady.Matrix.ps1',
                 'GuiReady.Diag.ps1', 'GuiReady.Catalog.ps1', 'GuiReady.Pipeline.ps1',
                 'GuiReady.AutoLogon.ps1', 'GuiReady.Command.ps1', 'GuiReady.PhaseB.ps1', 'GuiReady.Wac.ps1')) {
    $p = Join-Path $here ('lib\' + $f)
    if (Test-Path -LiteralPath $p) { . $p }
}

Write-Log '=== 开机续跑入口启动 ===' 'HEAD'
Write-Log ('时间: {0}' -f (Get-Date).ToString('s')) 'INFO'

# 等系统服务与磁盘稳定，避免刚开机就操作组件存储
Write-Log '等待系统稳定（60 秒）...' 'STEP'
Start-Sleep -Seconds 60

try {
    $st = Get-GuiReadyPipelineState
    if (-not $st) {
        Write-Log '没有流程状态文件，说明流程已完成或已被清理。注销自身。' 'WARN'
        Unregister-GuiReadyPipelineResumeTask
    } elseif ($st.Finished) {
        Write-Log '流程已标记完成。注销自身。' 'OK'
        Unregister-GuiReadyPipelineResumeTask
    } else {
        Write-Log ('发现未完成流程：第 {0}/{1} 步，继续执行。' -f ($st.StepIndex + 1), $st.Steps.Count) 'OK'
        $r = Resume-GuiReadyPipeline
        if ($r -and $r.Finished) {
            Write-Log ('续跑完成，结果: {0}' -f $r.Result) 'OK'
        } else {
            Write-Log '续跑已执行，请查看上面的步骤结果。' 'INFO'
        }
    }
} catch {
    Write-Log ('续跑异常: ' + $_.Exception.Message) 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
}

Write-Log ('=== 续跑入口结束，日志: {0} ===' -f $Global:GuiReadyLogFile) 'HEAD'

# GuiReady action runner: headless entry used by the GUI.
# The GUI starts this in a separate process per action, so a long or crashing action
# can never freeze or take down the GUI window.
#
# 每次执行都会落一条任务记录（state\tasks\yyyyMM\task-*.json）并写审计事件；
# 失败时同时投递一条通知到收件箱。记录失败绝不影响动作本身继续跑。

param(
    [Parameter(Mandatory = $true)][string]$Action,
    [string]$ArgsFile = '',
    [string]$LogFile  = '',
    # 任务编号由 GUI 生成（界面上先显示“排队中”，进程启动后用同一个编号落盘）。
    [string]$JobId = '',
    # 重试来源：记录是哪一条任务重新提交的，审计里能串起前后两次。
    [string]$RetryOf = ''
)

$ErrorActionPreference = 'Continue'
# 让重定向出去的输出是 UTF-8，GUI 端按 UTF-8 读取就不会乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

if ($LogFile) { $Global:GuiReadyLogFile = $LogFile }

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Detect.ps1', 'GuiReady.PeInspect.ps1',
                 'GuiReady.Fod.ps1', 'GuiReady.GuiShell.ps1', 'GuiReady.RdpFix.ps1',
                 'GuiReady.DotNet.ps1', 'GuiReady.GuiTest.ps1', 'GuiReady.Matrix.ps1',
                 'GuiReady.Diag.ps1', 'GuiReady.Catalog.ps1', 'GuiReady.Pipeline.ps1',
                 'GuiReady.AutoLogon.ps1', 'GuiReady.Command.ps1', 'GuiReady.PhaseB.ps1', 'GuiReady.Wac.ps1',
                 'GuiReady.Console.ps1', 'GuiReady.Package.ps1', 'GuiReady.Store.ps1', 'GuiReady.Role.ps1',
                 'GuiReady.Monitor.ps1', 'GuiReady.Security.ps1', 'GuiReady.Dsh.ps1',
                 'GuiReady.Files.ps1', 'GuiReady.Logs.ps1', 'GuiReady.Integrity.ps1',
                 'GuiReady.Tasks.ps1', 'GuiReady.Hosts.ps1', 'GuiReady.Remote.ps1', 'GuiReady.Runtime.ps1',
                 'GuiReady.Database.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}
. (Join-Path $PSScriptRoot 'GuiReady.Actions.ps1')

$P = @{}
if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
    try {
        $json = Get-Content -LiteralPath $ArgsFile -Raw -Encoding UTF8
        $obj  = $json | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) { $P[$prop.Name] = $prop.Value }
    } catch {
        Write-Log ('参数文件解析失败: ' + $_.Exception.Message) 'WARN'
    }
    # 参数文件里可能有敏感值（最典型的是「开机自动登录」的密码）—— 解析完立刻删除，
    # 不要让它留在磁盘上等下一次清理。GUI 侧在动作结束后也会删整个临时目录（双保险）。
    try { Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue } catch { }
}

$sid = -1
try { $sid = (Get-Process -Id $PID).SessionId } catch { }
Write-Log ('动作: {0}' -f $Action) 'STEP'
Write-Log ('会话={0}  用户={1}  管理员={2}' -f $sid, (whoami), (Format-Bool (Test-IsAdministrator))) 'INFO'

$act = @(Get-GuiReadyActions | Where-Object { $_.Id -eq $Action })
if ($act.Count -eq 0) {
    Write-Log ('未知动作: ' + $Action) 'ERROR'
    try { Write-GuiReadyAudit -Event 'action-unknown' -Level 'Error' -ActionId $Action -Detail '动作清单里没有这个 Id' } catch { }
    exit 2
}

# ---- 任务记录：先落“排队中”，执行前改“运行中”，结束再落最终状态 ----
$script:RunTask = $null
function Complete-RunTask {
    param([string]$Status, [object]$ExitCode = $null, [string]$Message = '')
    if (-not $script:RunTask) { return }
    try {
        [void](Complete-GuiReadyTask -Id ([string]$script:RunTask.Id) -Status $Status -ExitCode $ExitCode -Message $Message)
    } catch {
        Write-Log ('任务记录写入失败: ' + $_.Exception.Message) 'WARN'
    }
}

if (Get-Command New-GuiReadyTask -ErrorAction SilentlyContinue) {
    try {
        $script:RunTask = New-GuiReadyTask -ActionId $Action -ActionName ([string]$act[0].Name) `
            -Group ([string]$act[0].Group) -Params $P -LogPath $LogFile -Id $JobId -RetryOf $RetryOf `
            -DryRun ([bool]$P['DryRun'])
        Write-Log ('任务编号: {0}' -f $script:RunTask.Id) 'INFO'
        [void](Update-GuiReadyTask -Id ([string]$script:RunTask.Id) -Status 'Running' `
            -StartedAt ((Get-Date).ToString('o')) -ProcessId $PID)
        Write-GuiReadyAudit -Event 'task-start' -Level 'Info' -ActionId $Action -TaskId ([string]$script:RunTask.Id) `
            -Detail ('PID {0}，会话 {1}' -f $PID, $sid)
    } catch {
        Write-Log ('任务记录创建失败（动作继续执行）: ' + $_.Exception.Message) 'WARN'
        $script:RunTask = $null
    }
}

# 必填项校验（标记见 GuiReady.Actions.ps1 的 Set-GuiReadyActionRequirements）：
# 空值放任不管的话，脚本会以 "Cannot bind argument to parameter 'X' because it is an
# empty string" 收场 —— 用户只看到一句英文报错。这里先说清楚缺哪一项。
$missing = @()
foreach ($pd in @($act[0].Params)) {
    if (-not ($pd.ContainsKey('Req') -and [bool]$pd.Req)) { continue }
    $n = [string]$pd.Name
    $v = ''
    if ($P.ContainsKey($n)) { $v = [string]$P[$n] }
    if ([string]::IsNullOrWhiteSpace($v)) { $missing += [string]$pd.Label }
}
if ($missing.Count -gt 0) {
    $msg = ('缺少必填项：{0} —— 请填好之后再运行。' -f ($missing -join '、'))
    Write-Log $msg 'ERROR'
    Complete-RunTask -Status 'Failed' -ExitCode 3 -Message $msg
    exit 3
}

$runStart = Get-Date
# 远程批量等动作要把当前任务编号写进结果文件；只注入内存参数，不进入任务记录。
if ($script:RunTask) { $P['__TaskId'] = [string]$script:RunTask.Id }
try {
    & $act[0].Script $P
    Write-Log '动作执行完成。' 'OK'
    Complete-RunTask -Status 'Succeeded' -ExitCode 0 -Message ('用时 {0} 秒' -f [Math]::Round(((Get-Date) - $runStart).TotalSeconds, 1))
    exit 0
} catch {
    $m = [string]$_.Exception.Message
    if ($m -match "Cannot bind argument to parameter '([^']+)' because it is an empty string") {
        # 兜底：万一有没标进必填表、但底层 cmdlet 又要求非空的参数，也翻译成人话
        $m = ('参数「{0}」是空的，这个功能需要它 —— 请在界面上填好再运行。' -f $Matches[1])
    }
    Write-Log ('动作执行失败: ' + $m) 'ERROR'
    try { Write-Log ($_.ScriptStackTrace) 'ERROR' } catch { }
    Complete-RunTask -Status 'Failed' -ExitCode 1 -Message $m
    exit 1
}

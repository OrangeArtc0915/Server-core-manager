# GuiReady action runner: headless entry used by the GUI.
# The GUI starts this in a separate process per action, so a long or crashing action
# can never freeze or take down the GUI window.

param(
    [Parameter(Mandatory = $true)][string]$Action,
    [string]$ArgsFile = '',
    [string]$LogFile  = ''
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
                 'GuiReady.AutoLogon.ps1', 'GuiReady.Command.ps1', 'GuiReady.PhaseB.ps1', 'GuiReady.Wac.ps1')) {
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
}

$sid = -1
try { $sid = (Get-Process -Id $PID).SessionId } catch { }
Write-Log ('动作: {0}' -f $Action) 'STEP'
Write-Log ('会话={0}  用户={1}  管理员={2}' -f $sid, (whoami), (Format-Bool (Test-IsAdministrator))) 'INFO'

$act = @(Get-GuiReadyActions | Where-Object { $_.Id -eq $Action })
if ($act.Count -eq 0) {
    Write-Log ('未知动作: ' + $Action) 'ERROR'
    exit 2
}

try {
    & $act[0].Script $P
    Write-Log '动作执行完成。' 'OK'
    exit 0
} catch {
    Write-Log ('动作执行失败: ' + $_.Exception.Message) 'ERROR'
    try { Write-Log ($_.ScriptStackTrace) 'ERROR' } catch { }
    exit 1
}

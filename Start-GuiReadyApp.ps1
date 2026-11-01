# GuiReady app entry: opens the GUI by default, console menu with -Console.
# This is what the one-word command (scm) launches.

param(
    [switch]$Console,
    [switch]$KeepConsole,
    # 强制走 PowerShell 版界面（原生界面出问题时的手动开关）
    [switch]$PowerShellGui
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot

# 提权重启会拉起一个新进程；用环境变量把「这次要走 PowerShell 版界面」带过去
# （Start-Process -Verb RunAs 不会带命令行参数，只有环境会被继承）。
if ($PowerShellGui) { $env:SCM_FORCE_PS_GUI = '1' }

# 提权放在这里做，不放在 .bat 里。理由（也是这次"双击打不开"的根因）：
#   .bat 只能看到 Start-Process 的返回码，UAC 被取消时它不可靠，于是用户只会看到
#   "窗口闪一下、什么都没发生"，连原因都没有；而在 PowerShell 里失败会抛异常，
#   能拿到准确原因 —— 拿到原因之后就能**退一步用普通权限照样把界面打开**，
#   而不是把用户挡在门外。详见 lib\GuiReady.Common.ps1 的 Request-GuiReadyElevation。
$__common = Join-Path $here 'lib\GuiReady.Common.ps1'
if (Test-Path -LiteralPath $__common) {
    . $__common
    switch (Request-GuiReadyElevation -EntryScript $PSCommandPath -What '图形界面') {
        'Relaunched' {
            # 提权进程已经接管，本进程直接退出（否则会出现两个界面）
            return
        }
        'Failed' {
            Write-Host '  现在用普通权限打开界面：补环境 / 装软件 / 改服务这些会被系统拒绝，' -ForegroundColor Yellow
            Write-Host '  环境查看、仪表盘、日志、程序档案这些只读功能照常可用。' -ForegroundColor Yellow
            Write-Host '  想要完整功能：关掉本窗口，右键「一键运行.bat」→ 以管理员身份运行。' -ForegroundColor Yellow
            Write-Host ''
        }
    }
}

function Start-GuiReadyConsoleMenu {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Start-GuiReady.ps1')
}

if ($Console) {
    Start-GuiReadyConsoleMenu
    exit 0
}

# ---------------------------------------------------------------- 原生界面优先
# ui\bin\ScmUi.exe 是 C# 版界面（启动 ~150ms，PowerShell 版约 2s）。
# 原则：能开就开；开不起来就安静回退到 PowerShell 版 —— 两条路都在包里，用户不会打不开。
# 手动跳过原生界面：-PowerShellGui 或环境变量 SCM_FORCE_PS_GUI=1
$nativeExe = Join-Path $here 'ui\bin\ScmUi.exe'
$forcePs = $PowerShellGui -or ($env:SCM_FORCE_PS_GUI -eq '1')
if (-not $forcePs -and (Test-Path -LiteralPath $nativeExe)) {
    $nativeCode = $null
    $nativeError = ''
    try {
        $proc = Start-Process -FilePath $nativeExe -PassThru
        $proc.WaitForExit()
        $nativeCode = $proc.ExitCode
    } catch {
        $nativeError = $_.Exception.Message
    }

    if (-not $nativeError -and $nativeCode -eq 0) { exit 0 }

    if ($nativeError) {
        Write-Host ('原生界面启动失败：' + $nativeError) -ForegroundColor Yellow
    } else {
        Write-Host ('原生界面异常退出（退出码 {0}），改用 PowerShell 版界面。' -f $nativeCode) -ForegroundColor Yellow
        $errFile = Join-Path $here 'logs\ui-error.log'
        # 老版本把崩溃日志写在 ui\bin\error.txt，这里兼容一下
        if (-not (Test-Path -LiteralPath $errFile)) { $errFile = Join-Path $here 'ui\bin\error.txt' }
        if (Test-Path -LiteralPath $errFile) {
            Write-Host ('  最近一次错误（完整内容在 ' + $errFile + '）：') -ForegroundColor Yellow
            Get-Content -LiteralPath $errFile -Tail 12 | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }
        }
    }
    Write-Host ''
}

$gui = Join-Path $here 'gui\GuiReady.GuiApp.ps1'
if (Test-Path -LiteralPath $gui) {
    # 失败要让用户看得见：之前如果界面脚本抛异常，窗口会一闪而过、什么都不显示，
    # 看起来就是"双击没反应"。这里兜住异常、打印原因并等一次回车。
    $failed = $false
    try {
        & $gui -KeepConsole:$KeepConsole
    } catch {
        $failed = $true
        Write-Host ''
        Write-Host ('图形界面启动失败: ' + $_.Exception.Message) -ForegroundColor Red
        if ($_.ScriptStackTrace) { Write-Host ('  位置: ' + ($_.ScriptStackTrace -split "`n")[0]) -ForegroundColor DarkGray }
        Write-Host '（详细日志在 logs\ 目录；按回车关闭本窗口）' -ForegroundColor Yellow
        [void](Read-Host)
    }
    # 显式定退出码。不写的话 `powershell -File 本脚本` 会把**最后一个子进程**的退出码
    # 当成自己的 —— 界面里起的查询子进程常常以非 0 收场，于是界面正常关闭之后
    # 一键运行.bat 还会多打一行 "The launcher returned an error"，明明什么都没错。
    if ($failed) { exit 1 }
    exit 0
}

Write-Host '没有找到图形界面模块，改用命令行菜单。' -ForegroundColor Yellow
Start-GuiReadyConsoleMenu

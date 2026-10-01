# GuiReady app entry: opens the GUI by default, console menu with -Console.
# This is what the one-word command (scm) launches.

param(
    [switch]$Console,
    [switch]$KeepConsole
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot

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

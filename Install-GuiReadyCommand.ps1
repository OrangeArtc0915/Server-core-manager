# GuiReady command installer (CLI + interactive).
# Installs a single-word console command so the tool can be opened like sconfig.

param(
    [string]$Name = 'scm',
    [string]$Directory = '',
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Interactive,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'
try { [Console]::Title = 'Server Core GUI 就绪工具 - 一行命令安装' } catch { }

$here = $PSScriptRoot
foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Detect.ps1', 'GuiReady.PeInspect.ps1',
                 'GuiReady.Fod.ps1', 'GuiReady.GuiShell.ps1', 'GuiReady.RdpFix.ps1',
                 'GuiReady.DotNet.ps1', 'GuiReady.GuiTest.ps1', 'GuiReady.Matrix.ps1',
                 'GuiReady.Diag.ps1', 'GuiReady.Catalog.ps1', 'GuiReady.Pipeline.ps1',
                 'GuiReady.AutoLogon.ps1', 'GuiReady.Command.ps1', 'GuiReady.PhaseB.ps1', 'GuiReady.Wac.ps1')) {
    $p = Join-Path $here ('lib\' + $f)
    if (Test-Path -LiteralPath $p) { . $p }
}

if ($Interactive) {
    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor Cyan
    Write-Host '   一行命令启动：装完之后在任意目录输入一个词就能打开本工具' -ForegroundColor Cyan
    Write-Host '   （原理与 sconfig 相同：把一个 .cmd 放进 PATH 目录里）' -ForegroundColor Cyan
    Write-Host '  ================================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('   默认命令名: {0}     默认安装位置: {1}' -f $Name, (Join-Path $env:windir 'System32')) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   [1] 安装'
    Write-Host '   [2] 卸载'
    Write-Host '   [3] 查看状态'
    Write-Host '   [4] 换一个命令名再安装'
    Write-Host '   [0] 退出'
    Write-Host ''
    $sel = Read-Host '  请选择'
    switch ($sel) {
        '1' { Install-GuiReadyCommand -Name $Name -Directory $Directory | Out-Null }
        '2' { Uninstall-GuiReadyCommand -Name $Name -Directory $Directory | Out-Null }
        '3' { Show-GuiReadyCommandStatus | Out-Null }
        '4' {
            $n = Read-Host ('  新的命令名 [回车用 ' + $Name + ']')
            if (-not [string]::IsNullOrWhiteSpace($n)) { $Name = $n.Trim() }
            Install-GuiReadyCommand -Name $Name -Directory $Directory | Out-Null
        }
        default { Write-Log '已退出。' 'INFO' }
    }
    Write-Host ''
    [void](Read-Host '  按回车关闭')
    return
}

if ($Status)       { Show-GuiReadyCommandStatus | Out-Null }
elseif ($Uninstall){ Uninstall-GuiReadyCommand -Name $Name -Directory $Directory -WhatIf:$WhatIf | Out-Null }
else               { Install-GuiReadyCommand -Name $Name -Directory $Directory -WhatIf:$WhatIf | Out-Null }

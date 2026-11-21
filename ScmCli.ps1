# Server Core Manager 命令行入口（由 scm <verb> 调用）。
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath
$lib = Join-Path $here 'lib'

$modules = @(
    'GuiReady.Common.ps1', 'GuiReady.TasksPlus.ps1', 'GuiReady.Notify.ps1',
    'GuiReady.Metrics.ps1', 'GuiReady.Maintenance.ps1',
    'GuiReady.Hosts.ps1', 'GuiReady.Remote.ps1', 'GuiReady.Batch.ps1',
    'GuiReady.Plugins.ps1', 'GuiReady.ScriptLib.ps1', 'GuiReady.Update.ps1',
    'GuiReady.Cli.ps1'
)
foreach ($f in $modules) {
    $p = Join-Path $lib $f
    if (Test-Path -LiteralPath $p) { . $p }
}

Invoke-GuiReadyCli -CliArgs $CliArgs
exit ([int]$script:CliExitCode)

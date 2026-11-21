# 脚本库 runner：列表 / 预览 / 执行。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'
$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\scripts-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.ScriptLib.ps1')) {
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
function Get-Opt { param([string]$Name, $Default = '') if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return $A[$Name] } return $Default }
function Get-OptInt { param([string]$Name, [int]$Default = 0) $n = 0; if ([int]::TryParse([string](Get-Opt $Name ''), [ref]$n)) { return $n } return $Default }
function Get-OptBool { param([string]$Name, [bool]$Default = $false) $v = Get-Opt $Name $null; if ($null -eq $v) { return $Default }; if ($v -is [bool]) { return $v }; return ([string]$v -match '^(1|true|yes|on)$') }

function Write-ScriptResult {
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
        'list' {
            $items = @(Get-GuiReadyScriptLibrary)
            Write-ScriptResult -Data @{ Count = $items.Count; Root = (Get-GuiReadyScriptRoot) } -Items $items
        }
        'preview' {
            $p = Get-GuiReadyScriptPreview -Id ([string](Get-Opt 'Id' '')) -Lines (Get-OptInt 'Lines' 80)
            Write-ScriptResult -Data $p -Items @()
        }
        'run' {
            $r = Invoke-GuiReadyScript -Id ([string](Get-Opt 'Id' '')) -DryRun:(Get-OptBool 'DryRun' $false) -TimeoutSec (Get-OptInt 'TimeoutSec' 600)
            Write-ScriptResult -Data $r -Items @()
        }
        'root' {
            Write-ScriptResult -Data @{ Root = (Get-GuiReadyScriptRoot) } -Items @()
        }
        default { Write-ScriptResult -ErrorText ('未知模式：' + $Mode) }
    }
} catch {
    Write-Log ('scripts runner 失败：' + $_.Exception.Message) 'ERROR'
    Write-ScriptResult -ErrorText $_.Exception.Message
}

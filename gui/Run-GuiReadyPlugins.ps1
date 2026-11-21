# GuiReady 附属工具 runner：清单 / 本地状态 / 下载安装。
# 与其它 runner 同一套封套：-Mode <m> -OutFile <json> [-ArgsFile <json>]
#
# GitHub 线路下载源码分支 zip；Gitee 线路下载 Release 里的编译产物。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\plugins-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Plugins.ps1')) {
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

function Get-Opt {
    param([string]$Name, $Default = '')
    if ($A.ContainsKey($Name) -and $null -ne $A[$Name]) { return $A[$Name] }
    return $Default
}

function Write-PluginResult {
    param($Data, $Items, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode  = $Mode
        Stamp = (Get-Date).ToString('o')
        Error = $ErrorText
        Data  = $Data
        Items = @($Items)
    }
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
            $items = @(Get-GuiReadyPluginStatus)
            Write-PluginResult -Data ([pscustomobject]@{
                Root  = (Get-GuiReadyPluginRoot)
                Count = $items.Count
            }) -Items $items
        }
        'install' {
            $id = [string](Get-Opt 'Id' '')
            $source = [string](Get-Opt 'Source' 'github')
            if (-not $id) { throw '缺少参数 Id' }
            if ($source -ne 'gitee') { $source = 'github' }
            $dry = [bool](Get-Opt 'DryRun' $false)
            $r = Install-GuiReadyPlugin -Id $id -Source $source -DryRun:$dry
            Write-PluginResult -Data $r -Items @()
        }
        default {
            Write-PluginResult -ErrorText ('未知模式：' + $Mode)
        }
    }
} catch {
    Write-Log ('runner 失败：' + $_.Exception.Message) 'ERROR'
    Write-PluginResult -ErrorText $_.Exception.Message
}

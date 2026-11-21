# 批量管理 runner：主机清单 / 批量执行 / 批量采集 / 批量装包。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'
$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\batch-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Hosts.ps1', 'GuiReady.Remote.ps1', 'GuiReady.Batch.ps1')) {
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

function Write-BatchResult {
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
        'hosts' {
            $items = @(Get-GuiReadyHostList)
            Write-BatchResult -Data @{ Count = $items.Count } -Items $items
        }
        'list' {
            $items = @(Get-GuiReadyBatchList)
            Write-BatchResult -Data @{ Count = $items.Count } -Items $items
        }
        'last' {
            $d = Get-GuiReadyBatchLast
            Write-BatchResult -Data $d -Items @($d.Results)
        }
        'exec' {
            $d = Invoke-GuiReadyBatchExec -Spec ([string](Get-Opt 'HostSpec' '')) -Command ([string](Get-Opt 'Command' '')) `
                -TimeoutSec (Get-OptInt 'TimeoutSec' 120) -ContinueOnError (Get-OptBool 'ContinueOnError' $true)
            Write-BatchResult -Data $d -Items @($d.Results)
        }
        'collect' {
            $d = Invoke-GuiReadyBatchCollect -Spec ([string](Get-Opt 'HostSpec' '')) -TimeoutSec (Get-OptInt 'TimeoutSec' 90)
            Write-BatchResult -Data $d -Items @($d.Results)
        }
        'upload' {
            $d = Send-GuiReadyBatchFile -Spec ([string](Get-Opt 'HostSpec' '')) -LocalPath ([string](Get-Opt 'LocalPath' '')) `
                -RemotePath ([string](Get-Opt 'RemotePath' 'C:\Windows\Temp'))
            Write-BatchResult -Data $d -Items @($d.Results)
        }
        'download' {
            $d = Receive-GuiReadyBatchFile -Spec ([string](Get-Opt 'HostSpec' '')) -RemotePath ([string](Get-Opt 'RemotePath' '')) `
                -OutDir ([string](Get-Opt 'OutDir' ''))
            Write-BatchResult -Data $d -Items @($d.Results)
        }
        'script' {
            $d = Invoke-GuiReadyBatchScript -Spec ([string](Get-Opt 'HostSpec' '')) -LocalScript ([string](Get-Opt 'LocalScript' '')) `
                -TimeoutSec (Get-OptInt 'TimeoutSec' 300)
            Write-BatchResult -Data $d -Items @($d.Results)
        }
        'install' {
            $d = Invoke-GuiReadyBatchInstall -Spec ([string](Get-Opt 'HostSpec' '')) -Package ([string](Get-Opt 'Package' '')) `
                -Manager ([string](Get-Opt 'Manager' 'choco')) -TimeoutSec (Get-OptInt 'TimeoutSec' 600)
            Write-BatchResult -Data $d -Items @($d.Results)
        }
        default { Write-BatchResult -ErrorText ('未知模式：' + $Mode) }
    }
} catch {
    Write-Log ('batch runner 失败：' + $_.Exception.Message) 'ERROR'
    Write-BatchResult -ErrorText $_.Exception.Message
}

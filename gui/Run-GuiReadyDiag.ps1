# 网络与进程诊断 runner。

param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'
$Global:GuiReadyLogFile = Join-Path $toolRoot ('logs\diagplus-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.NetDiag.ps1', 'GuiReady.Proc.ps1')) {
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

function Write-DiagResult {
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
        'listening' {
            $items = @(Get-GuiReadyListeningPorts)
            Write-DiagResult -Data @{ Count = $items.Count } -Items $items
        }
        'scan' {
            $items = @(Test-GuiReadyPortScan -Target ([string](Get-Opt 'Target' '127.0.0.1')) -Ports ([string](Get-Opt 'Ports' '80,443,3389')) -TimeoutMs (Get-OptInt 'TimeoutMs' 800))
            Write-DiagResult -Data @{ Count = $items.Count; Target = [string](Get-Opt 'Target' '127.0.0.1') } -Items $items
        }
        'dns' {
            $items = @(Resolve-GuiReadyDns -Name ([string](Get-Opt 'Name' '')) -Server ([string](Get-Opt 'Server' '')))
            Write-DiagResult -Data @{ Count = $items.Count; Name = [string](Get-Opt 'Name' '') } -Items $items
        }
        'proxy' {
            $t = Get-GuiReadyProxyInfo
            Write-DiagResult -Data @{ Text = $t } -Items @()
        }
        'connectivity' {
            $items = @(Test-GuiReadyConnectivity -Targets ([string](Get-Opt 'Targets' '127.0.0.1:445')))
            Write-DiagResult -Data @{ Count = $items.Count } -Items $items
        }
        'capture' {
            $r = Start-GuiReadyPacketCapture -Seconds (Get-OptInt 'Seconds' 30) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-DiagResult -Data $r -Items @()
        }
        'capture-stop' {
            Stop-GuiReadyPacketCapture
            Write-DiagResult -Data @{ Stopped = $true } -Items @()
        }
        'captures' {
            $items = @(Get-GuiReadyCaptureFiles)
            Write-DiagResult -Data @{ Count = $items.Count } -Items $items
        }
        'proc-list' {
            $items = @(Get-GuiReadyProcessList -Top (Get-OptInt 'Top' 80))
            Write-DiagResult -Data @{ Count = $items.Count } -Items $items
        }
        'proc-tree' {
            $items = @(Get-GuiReadyProcessTree)
            Write-DiagResult -Data @{ Count = $items.Count } -Items $items
        }
        'proc-detail' {
            $d = Get-GuiReadyProcessDetail -Id (Get-OptInt 'Id' 0)
            Write-DiagResult -Data $d -Items @()
        }
        'proc-snapshot' {
            $d = Save-GuiReadyProcessSnapshot
            Write-DiagResult -Data $d -Items @()
        }
        'proc-history' {
            $items = @(Get-GuiReadyProcessHistory -Days (Get-OptInt 'Days' 7))
            Write-DiagResult -Data @{ Count = $items.Count } -Items $items
        }
        'proc-kill' {
            Stop-GuiReadyProcess -Id (Get-OptInt 'Id' 0) -DryRun:(Get-OptBool 'DryRun' $false)
            Write-DiagResult -Data @{ Id = (Get-OptInt 'Id' 0) } -Items @()
        }
        default { Write-DiagResult -ErrorText ('未知模式：' + $Mode) }
    }
} catch {
    Write-Log ('diag runner 失败：' + $_.Exception.Message) 'ERROR'
    Write-DiagResult -ErrorText $_.Exception.Message
}

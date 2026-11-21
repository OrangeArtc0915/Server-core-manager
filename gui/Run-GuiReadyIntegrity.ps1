# GuiReady integrity runner: 启动时静默核对 manifest.sha256。
# 只读，不改文件；界面拿结果在日志里报警（关于页的「完整性自检」仍然看完整报告）。

param(
    [string]$Mode = 'status',
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $toolRoot 'lib'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Integrity.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-IntegrityResult {
    param($Data, [string]$ErrorText = '')
    $o = [ordered]@{
        Mode  = $Mode
        Stamp = (Get-Date).ToString('o')
        Error = $ErrorText
        Data  = $Data
        Items = @()
    }
    try {
        $json = $o | ConvertTo-Json -Depth 8 -Compress
        $tmp  = $OutFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
}

try {
    $r = Test-GuiReadyManifest -Root $toolRoot
    $data = [pscustomobject]@{
        ManifestExists = [bool]$r.Exists
        Count          = [int]$r.Count
        Ok             = [bool]$r.Ok
        Modified       = @($r.Modified)
        Missing        = @($r.Missing)
        Extra          = @($r.Extra)
    }
    Write-IntegrityResult -Data $data
    exit 0
} catch {
    Write-IntegrityResult -Data $null -ErrorText $_.Exception.Message
    exit 1
}

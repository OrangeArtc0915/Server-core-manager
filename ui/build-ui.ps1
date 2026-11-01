$ErrorActionPreference = 'Stop'
$srcDir = $PSScriptRoot
$bin    = Join-Path $srcDir 'bin'
if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
$exe    = Join-Path $bin 'ScmUi.exe'

# csc.exe ships with .NET Framework (Server 2019+). No SDK, no network needed.
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw 'csc.exe not found - .NET Framework 4.x is required.' }

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$sources = New-Object System.Collections.ArrayList
foreach ($f in @(Get-ChildItem -LiteralPath $srcDir -Filter '*.cs' | Sort-Object Name)) {
    # csc parses non-ASCII source only when the file has a BOM
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        [System.IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
        Write-Host ('  + BOM ' + $f.Name)
    }
    [void]$sources.Add($f.FullName)
}
if ($sources.Count -eq 0) { throw 'no .cs files found' }

$fw = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319'
if (-not (Test-Path (Join-Path $fw 'System.Windows.Forms.dll'))) { $fw = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319' }

$cscArgs = New-Object System.Collections.ArrayList
foreach ($a in @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    ('/out:' + $exe),
    ('/r:' + (Join-Path $fw 'System.Windows.Forms.dll')),
    ('/r:' + (Join-Path $fw 'System.Drawing.dll')),
    ('/r:' + (Join-Path $fw 'System.Web.Extensions.dll')),
    # 进程内采样用：ServiceController（服务状态）与 EventLogReader（系统事件）
    ('/r:' + (Join-Path $fw 'System.ServiceProcess.dll')),
    ('/r:' + (Join-Path $fw 'System.Core.dll')),
    '/r:System.dll')) { [void]$cscArgs.Add($a) }
foreach ($s in $sources) { [void]$cscArgs.Add($s) }

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw ('compile failed, exit ' + $LASTEXITCODE) }
Write-Host ('built: ' + $exe + '  ' + [math]::Round((Get-Item $exe).Length / 1KB, 1) + ' KB  (' + $sources.Count + ' files)')

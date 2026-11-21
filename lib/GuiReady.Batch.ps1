# 多机批量管理：批量采集 / 批量执行 / 批量装包。
# 复用 GuiReady.Remote.ps1 的并发批处理与主机凭据。

function Get-GuiReadyBatchList {
    $dir = Get-GuiReadyRemoteDir
    $rows = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'batch-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $b = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $rows += [pscustomobject]@{
                TaskId = [string]$b.TaskId; StartedAt = [string]$b.StartedAt; EndedAt = [string]$b.EndedAt
                Command = [string]$b.Command; Total = [int]$b.Total
                Succeeded = [int]$b.Succeeded; Failed = [int]$b.Failed; Skipped = [int]$b.Skipped
                File = $f.FullName
            }
        } catch { }
    }
    return @($rows)
}

function Get-GuiReadyBatchLast {
    return (@(Get-GuiReadyBatchList) | Select-Object -First 1)
}

function Invoke-GuiReadyBatchExec {
    param([string]$Spec = '', [Parameter(Mandatory = $true)][string]$Command,
          [int]$TimeoutSec = 120, [bool]$ContinueOnError = $true, [string]$TaskId = '')
    return (Invoke-GuiReadyRemoteBatch -HostSpec $Spec -Command $Command -TimeoutSec $TimeoutSec `
        -ContinueOnError $ContinueOnError -TaskId $TaskId)
}

function Invoke-GuiReadyBatchCollect {
    param([string]$Spec = '', [int]$TimeoutSec = 90)
    $cmd = @'
$os = Get-CimInstance Win32_OperatingSystem
$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$mem = 0
if ($os.TotalVisibleMemorySize -gt 0) { $mem = [Math]::Round(100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize, 1) }
[pscustomobject]@{
    Host = $env:COMPUTERNAME
    OS = [string]$os.Caption
    Build = [string]$os.Version
    CpuPct = [Math]::Round([double]$cpu, 1)
    MemPct = $mem
    DiskFreeGB = $(if ($d) { [Math]::Round([double]$d.FreeSpace / 1GB, 1) } else { 0 })
    UptimeHours = [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
} | ConvertTo-Json -Compress
'@
    $b = Invoke-GuiReadyRemoteBatch -HostSpec $Spec -Command $cmd -TimeoutSec $TimeoutSec -ContinueOnError $true
    $rows = @()
    foreach ($r in @($b.Results)) {
        $o = $null
        if ([string]$r.Status -eq 'OK') { try { $o = $r.Output.Trim() | ConvertFrom-Json } catch { } }
        $rows += [pscustomobject]@{
            Host = [string]$r.Name; Address = [string]$r.Address; Status = [string]$r.Status
            OS = $(if ($o) { [string]$o.OS } else { '' })
            Build = $(if ($o) { [string]$o.Build } else { '' })
            CpuPct = $(if ($o) { [double]$o.CpuPct } else { 0 })
            MemPct = $(if ($o) { [double]$o.MemPct } else { 0 })
            DiskFreeGB = $(if ($o) { [double]$o.DiskFreeGB } else { 0 })
            UptimeHours = $(if ($o) { [double]$o.UptimeHours } else { 0 })
            Output = [string]$r.Output; Error = [string]$r.Error; DurationSec = [double]$r.DurationSec
        }
    }
    return [pscustomobject]@{ TaskId = [string]$b.TaskId; Total = [int]$b.Total; Succeeded = [int]$b.Succeeded; Failed = [int]$b.Failed; Results = @($rows) }
}

function Send-GuiReadyBatchFile {
    param([string]$Spec = '', [Parameter(Mandatory = $true)][string]$LocalPath,
          [string]$RemotePath = 'C:\Windows\Temp')
    if (-not (Test-Path -LiteralPath $LocalPath)) { throw ('本地文件不存在：' + $LocalPath) }
    $hosts = @(Resolve-GuiReadyHostTargets -Spec $Spec)
    $rows = @()
    foreach ($h in $hosts) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'Failed'; $out = ''; $err = ''
        $session = $null
        try {
            $cp = Get-GuiReadyRemoteConnectionParams -Target $h -TimeoutSec 60
            $session = New-PSSession @cp -ErrorAction Stop
            $dest = Join-Path $RemotePath (Split-Path -Leaf $LocalPath)
            Copy-Item -LiteralPath $LocalPath -Destination $dest -ToSession $session -Force -ErrorAction Stop
            $status = 'OK'; $out = $dest
        } catch {
            $err = ConvertTo-GuiReadyRemoteErrorText -Message ([string]$_.Exception.Message)
        } finally {
            if ($session) { try { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } catch { } }
            $sw.Stop()
        }
        $rows += [pscustomobject]@{ Host = [string]$h.Name; Address = [string]$h.Address; Status = $status; Output = $out; Error = $err; DurationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    return [pscustomobject]@{ Total = $hosts.Count; Succeeded = @($rows | Where-Object { $_.Status -eq 'OK' }).Count; Failed = @($rows | Where-Object { $_.Status -ne 'OK' }).Count; Results = @($rows) }
}

function Receive-GuiReadyBatchFile {
    param([string]$Spec = '', [Parameter(Mandatory = $true)][string]$RemotePath,
          [Parameter(Mandatory = $true)][string]$OutDir)
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $hosts = @(Resolve-GuiReadyHostTargets -Spec $Spec)
    $rows = @()
    foreach ($h in $hosts) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'Failed'; $out = ''; $err = ''
        $session = $null
        try {
            $cp = Get-GuiReadyRemoteConnectionParams -Target $h -TimeoutSec 60
            $session = New-PSSession @cp -ErrorAction Stop
            $sub = Join-Path $OutDir ([string]$h.Name)
            if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null }
            Copy-Item -FromSession $session -LiteralPath $RemotePath -Destination $sub -Recurse -Force -ErrorAction Stop
            $status = 'OK'; $out = $sub
        } catch {
            $err = ConvertTo-GuiReadyRemoteErrorText -Message ([string]$_.Exception.Message)
        } finally {
            if ($session) { try { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } catch { } }
            $sw.Stop()
        }
        $rows += [pscustomobject]@{ Host = [string]$h.Name; Address = [string]$h.Address; Status = $status; Output = $out; Error = $err; DurationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    return [pscustomobject]@{ Total = $hosts.Count; Succeeded = @($rows | Where-Object { $_.Status -eq 'OK' }).Count; Failed = @($rows | Where-Object { $_.Status -ne 'OK' }).Count; Results = @($rows) }
}

function Invoke-GuiReadyBatchScript {
    param([string]$Spec = '', [Parameter(Mandatory = $true)][string]$LocalScript, [int]$TimeoutSec = 300)
    if (-not (Test-Path -LiteralPath $LocalScript)) { throw ('脚本不存在：' + $LocalScript) }
    $name = 'scm-' + (Split-Path -Leaf $LocalScript)
    $up = Send-GuiReadyBatchFile -Spec $Spec -LocalPath $LocalScript -RemotePath 'C:\Windows\Temp'
    $remote = 'C:\Windows\Temp\' + $name
    $run = Invoke-GuiReadyRemoteBatch -HostSpec $Spec -Command ('& ''' + $remote + '''') -TimeoutSec $TimeoutSec -ContinueOnError $true
    $rows = @()
    foreach ($r in @($run.Results)) {
        $rows += [pscustomobject]@{ Host = [string]$r.Name; Address = [string]$r.Address; Status = [string]$r.Status; Output = [string]$r.Output; Error = [string]$r.Error; DurationSec = [double]$r.DurationSec }
    }
    return [pscustomobject]@{ TaskId = [string]$run.TaskId; Total = [int]$run.Total; Succeeded = [int]$run.Succeeded; Failed = [int]$run.Failed; Upload = $up; Results = @($rows); RemoteScript = $remote }
}

function Invoke-GuiReadyBatchInstall {
    param([string]$Spec = '', [Parameter(Mandatory = $true)][string]$Package,
          [ValidateSet('choco', 'winget')][string]$Manager = 'choco', [int]$TimeoutSec = 600)
    if ($Package -notmatch '^[A-Za-z0-9._+-]+$') { throw '包名只允许字母、数字、点、下划线、加号、减号。' }
    if ($Manager -eq 'winget') {
        $cmd = 'if (Get-Command winget -ErrorAction SilentlyContinue) { & winget install --id "' + $Package + '" -e --silent --accept-package-agreements --accept-source-agreements; if ($LASTEXITCODE -ne 0) { throw ("winget exit " + $LASTEXITCODE) } } else { throw "winget 未安装" }'
    } else {
        $cmd = 'if (Get-Command choco -ErrorAction SilentlyContinue) { & choco install "' + $Package + '" -y --no-progress; if ($LASTEXITCODE -ne 0) { throw ("choco exit " + $LASTEXITCODE) } } else { throw "Chocolatey 未安装" }'
    }
    $b = Invoke-GuiReadyRemoteBatch -HostSpec $Spec -Command $cmd -TimeoutSec $TimeoutSec -ContinueOnError $true
    $rows = @()
    foreach ($r in @($b.Results)) {
        $rows += [pscustomobject]@{
            Host = [string]$r.Name; Address = [string]$r.Address; Status = [string]$r.Status
            Output = [string]$r.Output; Error = [string]$r.Error; DurationSec = [double]$r.DurationSec
        }
    }
    return [pscustomobject]@{ TaskId = [string]$b.TaskId; Total = [int]$b.Total; Succeeded = [int]$b.Succeeded; Failed = [int]$b.Failed; Results = @($rows); Package = $Package; Manager = $Manager }
}

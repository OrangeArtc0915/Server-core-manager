# GuiReady Windows Update：检查 / 安装 / 历史 / 自动更新开关。
#
# 只用系统自带的 COM（Microsoft.Update.Session），不依赖 PSWindowsUpdate 之类的
# 第三方模块 —— Server Core 上装模块本身就是个门槛。搜索是网络操作，可能跑几分钟；
# 界面在子进程里等，不会卡住主窗口。

function Get-GuiReadyUpdateAutoState {
    $au = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $noAuto = 0
    $auOptions = 0
    try { $v = (Get-ItemProperty -Path $pol -Name NoAutoUpdate -ErrorAction Stop).NoAutoUpdate; if ($null -ne $v) { $noAuto = [int]$v } } catch { }
    try { $v = (Get-ItemProperty -Path $au -Name AUOptions -ErrorAction Stop).AUOptions; if ($null -ne $v) { $auOptions = [int]$v } } catch { }

    $text = '未配置（系统默认）'
    switch ($auOptions) {
        1 { $text = '已关闭（从不检查）' }
        2 { $text = '仅通知，由管理员安装' }
        3 { $text = '自动下载，手动安装' }
        4 { $text = '自动下载并安装' }
    }
    if ($noAuto -eq 1) { $text = '已关闭（策略）' }
    $svc = ''
    try { $svc = [string](Get-Service -Name wuauserv -ErrorAction Stop).Status } catch { }

    return [pscustomobject]@{
        NoAutoUpdate = $noAuto
        AUOptions    = $auOptions
        Text         = $text
        Service      = $svc
        PolicyPath   = $pol
    }
}

function Set-GuiReadyUpdateAuto {
    param([ValidateSet('auto', 'notify', 'manual', 'off')][string]$Mode, [switch]$DryRun)
    Assert-Administrator | Out-Null
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $map = @{ auto = @{ NoAutoUpdate = 0; AUOptions = 4 }; notify = @{ NoAutoUpdate = 0; AUOptions = 2 }
              manual = @{ NoAutoUpdate = 0; AUOptions = 3 }; off = @{ NoAutoUpdate = 1; AUOptions = 1 } }
    $want = $map[$Mode]
    if ($DryRun) {
        Write-Log ('[预览] 自动更新将设为：{0}（NoAutoUpdate={1} / AUOptions={2}）' -f $Mode, $want.NoAutoUpdate, $want.AUOptions) 'DRY'
        return
    }
    if (-not (Test-Path -LiteralPath $pol)) { New-Item -Path $pol -Force | Out-Null }
    New-ItemProperty -Path $pol -Name NoAutoUpdate -Value $want.NoAutoUpdate -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $pol -Name AUOptions -Value $want.AUOptions -PropertyType DWord -Force | Out-Null
    $st = Get-GuiReadyUpdateAutoState
    Write-Log ('自动更新已设为：{0}（{1}）' -f $Mode, $st.Text) 'OK'
}

function Get-GuiReadyPendingUpdate {
    param([int]$TimeoutMin = 8)
    $list = @()
    $err = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        # 默认搜索在线 Windows Update 源；组策略指到 WSUS 时也走同一个入口
        $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u = $result.Updates.Item($i)
            $kb = @()
            try { foreach ($k in $u.KBArticleIDs) { $kb += ('KB' + [string]$k) } } catch { }
            $cats = @()
            try { for ($c = 0; $c -lt $u.Categories.Count; $c++) { $cats += [string]$u.Categories.Item($c).Name } } catch { }
            $sev = ''
            try { $sev = [string]$u.MsrcSeverity } catch { }
            $list += [pscustomobject]@{
                Index      = $i
                Title      = [string]$u.Title
                Kb         = ($kb -join ',')
                SizeMB     = [Math]::Round(([double]$u.MaxDownloadSize) / 1MB, 1)
                Downloaded = [bool]$u.IsDownloaded
                Reboot     = [bool]$u.IsRebootRequired
                Severity   = $sev
                Categories = ($cats -join ',')
            }
        }
    } catch {
        $err = '检查更新失败：' + $_.Exception.Message
        Write-Log $err 'ERROR'
    }
    $sw.Stop()
    return [pscustomobject]@{
        Items      = $list
        Error      = $err
        Seconds    = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        Auto       = (Get-GuiReadyUpdateAutoState)
        LastChange = (Get-GuiReadyUpdateLastChange)
    }
}

function Get-GuiReadyUpdateLastChange {
    try {
        $items = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Detect' -ErrorAction SilentlyContinue)
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Detect'
        $v = (Get-ItemProperty -Path $key -Name LastSuccessTime -ErrorAction Stop).LastSuccessTime
        return [string]$v
    } catch { return '' }
}

function Install-GuiReadyUpdate {
    param([int[]]$Indexes = @(), [switch]$DryRun)
    Assert-Administrator | Out-Null

    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    Write-Log '正在检查可用更新（可能要几十秒）…' 'STEP'
    $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
    if ($result.Updates.Count -eq 0) {
        Write-Log '没有待安装的更新。' 'OK'
        return @()
    }

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    $picked = @()
    for ($i = 0; $i -lt $result.Updates.Count; $i++) {
        if ($Indexes.Count -gt 0 -and ($Indexes -notcontains $i)) { continue }
        $u = $result.Updates.Item($i)
        try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch { }
        [void]$coll.Add($u)
        $picked += $u
    }
    if ($coll.Count -eq 0) { throw '选中的更新编号都不存在（先重新检查一次）' }

    if ($DryRun) {
        Write-Log ('[预览] 将下载并安装 {0} 个更新：' -f $coll.Count) 'DRY'
        foreach ($u in $picked) { Write-Log ('  - ' + [string]$u.Title) 'DRY' }
        return @()
    }

    Write-Log ('开始下载 {0} 个更新…' -f $coll.Count) 'STEP'
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $coll
    $dr = $downloader.Download()
    Write-Log ('下载结果码 {0}（2/3 = 成功，4 = 已下载，5 = 需要重启）' -f $dr.ResultCode) 'INFO'

    $need = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $picked) { if ($u.IsDownloaded) { [void]$need.Add($u) } }
    if ($need.Count -eq 0) { throw '下载没有成功，未进入安装阶段' }

    Write-Log ('开始安装 {0} 个更新…' -f $need.Count) 'STEP'
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $need
    $ir = $installer.Install()

    $rows = @()
    for ($i = 0; $i -lt $need.Count; $i++) {
        $per = $null
        try { $per = $installer.GetUpdateResult($i) } catch { }
        $title = [string]$need.Item($i).Title
        $code = 0
        $hr = ''
        if ($per) { $code = [int]$per.ResultCode; $hr = [string]$per.HResult }
        $text = switch ($code) { 2 { '成功' } 3 { '成功（需重启）' } 4 { '失败' } 5 { '已取消' } default { '结果码 ' + $code } }
        $level = if ($code -eq 2 -or $code -eq 3) { 'OK' } else { 'ERROR' }
        Write-Log ('  {0} → {1} {2}' -f $title, $text, $hr) $level
        $rows += [pscustomobject]@{ Title = $title; ResultCode = $code; Text = $text; HResult = $hr }
    }
    Write-Log ('安装结束：需要重启={0}' -f $ir.RebootRequired) $(if ($ir.RebootRequired) { 'WARN' } else { 'OK' })
    return $rows
}

function Get-GuiReadyUpdateHistory {
    param([int]$Max = 30)
    $rows = @()
    try {
        $rows = @(Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First $Max |
                  ForEach-Object {
                      [pscustomobject]@{
                          Kb          = [string]$_.HotFixID
                          Description = [string]$_.Description
                          InstalledOn = $(if ($_.InstalledOn) { $_.InstalledOn.ToString('yyyy-MM-dd') } else { '' })
                          InstalledBy = [string]$_.InstalledBy
                      }
                  })
    } catch {
        Write-Log ('读取更新历史失败：' + $_.Exception.Message) 'WARN'
    }
    return $rows
}

# GuiReady diag: collect runtime evidence when a program fails to launch or show a window

$Global:GuiReadyErrorSignatures = @(
    [pscustomobject]@{ Match='拒绝访问|Access is denied|0x80070005'; Cause='权限/提权不足'; Advice='程序清单要求管理员提权，但当前是过滤令牌且 UAC 无法确认。用 CreateProcess 绕过、或改走 SYSTEM 计划任务、或人工 RDP 点确认。' }
    [pscustomobject]@{ Match='0xc0000135|找不到指定的模块|The specified module could not be found'; Cause='缺少依赖 DLL'; Advice='用菜单第 2 项 exe 兼容性预检找出缺失模块；常见是 VC++ 运行库或桌面体验组件缺失。' }
    [pscustomobject]@{ Match='0xc000007b'; Cause='架构不匹配'; Advice='32/64 位或依赖 DLL 架构不一致，换成对应架构的版本。' }
    [pscustomobject]@{ Match='You must install \.NET|framework.{0,20}not found|hostfxr'; Cause='缺少 .NET 运行时'; Advice='用菜单第 5 项按程序需求自动补齐 .NET 运行时。' }
    [pscustomobject]@{ Match='SideBySide|并行配置不正确|SxS'; Cause='SxS/VC++ 运行库缺失或清单错误'; Advice='安装对应版本的 Visual C++ Redistributable。' }
    [pscustomobject]@{ Match='0xc0000142|DLL 初始化失败'; Cause='DLL 初始化失败'; Advice='多为缺少 GUI 子系统或运行库；先确认 FOD 已安装并重启过。' }
    [pscustomobject]@{ Match='0x8007007e|找不到模块'; Cause='找不到模块'; Advice='依赖链缺文件，用 exe 兼容性预检确认。' }
    [pscustomobject]@{ Match='GPU|gpu process|swiftshader|ANGLE'; Cause='GPU/渲染进程问题'; Advice='Electron/Chromium 程序加 --disable-gpu --disable-software-rasterizer 再试。' }
    [pscustomobject]@{ Match='0xc0000005|c0000005|Access Violation|BEX64'; Cause='内存访问违规（程序自身缺陷或与系统不兼容）'; Advice='优先看“故障模块”是谁：若是程序自己的 dll 则是该程序 bug，换版本；若是系统 dll 则可能是系统组件缺失或版本不匹配。也可尝试加 --disable-gpu 等兼容参数。' }
    [pscustomobject]@{ Match='AppHang|Hang Signature|挂起'; Cause='程序无响应挂起'; Advice='多为死锁或等待设备/网络超时。确认 GUI 组件是否齐全（用 GUI 能力自检），必要时用诊断里的事件日志定位挂起前的最后动作。' }
    [pscustomobject]@{ Match='0x80070002|系统找不到指定的文件'; Cause='文件缺失'; Advice='程序安装不完整或被杀软隔离，检查安装目录完整性。' }
)

function Get-GuiReadyRecentAppErrors {
    param([int]$Minutes = 30, [int]$MaxEvents = 60, [string]$NameFilter = '')

    $out = New-Object System.Collections.ArrayList
    $providers = @('Application Error', 'Windows Error Reporting', '.NET Runtime', 'Application Hang', 'SideBySide', 'Application Popup')

    try {
        $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2, 3; StartTime = (Get-Date).AddMinutes(-1 * $Minutes) } -MaxEvents $MaxEvents -ErrorAction Stop)
    } catch {
        return @()
    }

    foreach ($e in $evs) {
        $isTarget = $false
        foreach ($p in $providers) { if ($e.ProviderName -eq $p) { $isTarget = $true; break } }
        if (-not $isTarget) { continue }

        $msg = ''
        try { $msg = [string]$e.Message } catch { }
        $flat = ($msg -replace '\s+', ' ').Trim()
        if ($flat.Length -gt 700) { $flat = $flat.Substring(0, 700) }

        $related = $true
        if ($NameFilter) { $related = ($msg -match [regex]::Escape($NameFilter)) }

        [void]$out.Add([pscustomobject]@{
            Time         = $e.TimeCreated.ToString('MM-dd HH:mm:ss')
            Level        = [string]$e.LevelDisplayName
            Provider     = $e.ProviderName
            Id           = $e.Id
            Related      = $related
            MessageBrief = $flat
            MessageRaw   = $msg
        })
    }
    return @($out)
}

function Get-GuiReadyWerReports {
    param([int]$MaxReports = 8, [string]$AppNameFilter = '')

    $roots = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
    )
    $out = New-Object System.Collections.ArrayList

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $MaxReports)
        foreach ($d in $dirs) {
            $wer = Join-Path $d.FullName 'Report.wer'
            if (-not (Test-Path -LiteralPath $wer)) { continue }

            $text = ''
            try {
                $a = [System.IO.File]::ReadAllText($wer, [System.Text.Encoding]::Unicode)
                $b = [System.IO.File]::ReadAllText($wer, [System.Text.Encoding]::Default)
                $text = if ((($a -split "`n").Count) -ge (($b -split "`n").Count)) { $a } else { $b }
            } catch { continue }

            $kv = @{}
            foreach ($line in ($text -split "`r?`n")) {
                if ($line -match '^\s*([A-Za-z0-9_\[\]\.]+)\s*=\s*(.*)$') {
                    $k = $Matches[1]
                    if (-not $kv.ContainsKey($k)) { $kv[$k] = $Matches[2] }
                }
            }

            # WER 的字段名随系统语言变化，关键信息都在 Sig[n].Name / Sig[n].Value 里
            $sigMap = @{}
            $sig = @()
            for ($i = 0; $i -lt 16; $i++) {
                $kn  = 'Sig[' + $i + '].Name'
                $kvv = 'Sig[' + $i + '].Value'
                if ($kv.ContainsKey($kn) -and $kv.ContainsKey($kvv)) {
                    $nm = [string]$kv[$kn]
                    $vl = [string]$kv[$kvv]
                    $sigMap[$nm] = $vl
                    $sig += ($nm + '=' + $vl)
                }
            }
            $exCode = ''
            $fault  = ''
            $appVer = ''
            $hangSig = ''
            foreach ($k in @($sigMap.Keys)) {
                if ($k -match '异常代码|Exception Code')                 { $exCode = $sigMap[$k] }
                elseif ($k -match '故障模块名称|Fault Module Name')      { $fault = $sigMap[$k] }
                elseif ($k -match '应用程序版本|Application Version')    { $appVer = $sigMap[$k] }
                elseif ($k -match 'Hang Signature|挂起签名')             { $hangSig = $sigMap[$k] }
            }

            $related = $true
            if ($AppNameFilter) {
                $related = ([string]$kv['AppName'] -match [regex]::Escape($AppNameFilter))
            }

            [void]$out.Add([pscustomobject]@{
                Time          = $d.LastWriteTime.ToString('MM-dd HH:mm:ss')
                Folder        = $d.Name
                EventType     = [string]$kv['EventType']
                AppName       = [string]$kv['AppName']
                AppPath       = [string]$kv['AppPath']
                AppVersion    = $appVer
                ExceptionCode = $exCode
                FaultModule   = $fault
                HangSignature = $hangSig
                ReportId      = [string]$kv['ReportIdentifier']
                Related       = $related
                Signatures    = ($sig -join ' | ')
            })
        }
    }
    return @($out)
}

function Get-GuiReadyProcessSnapshot {
    param([string]$ProcessName = '', [string]$ExePath = '')

    $out = New-Object System.Collections.ArrayList
    $procs = @()
    if ($ProcessName) {
        $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    } elseif ($ExePath) {
        $n = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
        $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
    }
    foreach ($p in $procs) {
        $threads = 0
        try { $threads = $p.Threads.Count } catch { }
        [void]$out.Add([pscustomobject]@{
            Name            = $p.ProcessName
            Id              = $p.Id
            SessionId       = $p.SessionId
            Responding      = $p.Responding
            HasExited       = $p.HasExited
            MainWindowHandle= [int64]$p.MainWindowHandle
            MainWindowTitle = $p.MainWindowTitle
            ThreadCount     = $threads
            WorkingSetMB    = [math]::Round($p.WorkingSet64 / 1MB, 1)
            StartTime       = $(try { $p.StartTime.ToString('MM-dd HH:mm:ss') } catch { '' })
        })
    }
    return @($out)
}

function Get-GuiReadyAppDiagnostics {
    param(
        [string]$ExePath = '',
        [string]$ProcessName = '',
        [int]$Minutes = 30,
        [switch]$NoReport
    )

    Write-Head '程序兼容性排障采集'

    if (-not $ProcessName -and $ExePath) { $ProcessName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath) }
    Write-Log ('目标: exe={0}  进程名={1}  时间窗={2} 分钟' -f $ExePath, $ProcessName, $Minutes) 'INFO'

    $res = [ordered]@{
        Timestamp   = (Get-Date).ToString('s')
        ExePath     = $ExePath
        ProcessName = $ProcessName
        Minutes     = $Minutes
        PeInfo      = $null
        MissingPkg  = @()
        Processes   = @()
        ProcessErrors= @()
        EventErrors = @()
        EventUnrelated = @()
        WerReports  = @()
        WerMatching = @()
        WerUnrelated= @()
        Context     = $null
        Findings    = @()
        Conclusion  = ''
    }

    if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
        $pe = Get-PeImageInfo -Path $ExePath
        $kind = Get-FileKindTag -Path $ExePath -PeInfo $pe
        $res.PeInfo = $pe
        Write-Log ('架构={0}  子系统={1}  .NET={2}  类型={3}' -f $pe.MachineName, $pe.SubsystemName, $pe.IsDotNet, $(if ($kind) { $kind } else { '未识别' })) 'INFO'

        $appDir = Split-Path -Parent $ExePath
        $miss = New-Object System.Collections.ArrayList
        foreach ($m in @($pe.Imports + $pe.DelayImports | Sort-Object -Unique)) {
            if ($m -match '^(api-ms-win-|ext-ms-win-)') { continue }
            if (-not (Test-ModuleResolvable -Name $m -AppDir $appDir)) { [void]$miss.Add($m) }
        }
        $res.MissingPkg = @($miss)
        if ($miss.Count -gt 0) { Write-Log ('缺失依赖: ' + ($miss -join ', ')) 'WARN' } else { Write-Log '缺失依赖: 无' 'OK' }
    }

    $ctx = [ordered]@{
        SessionId   = -1
        SessionInfo = $null
        Uac         = $null
        DotNet      = $null
    }
    try { $ctx.SessionId = (Get-Process -Id $PID).SessionId } catch { }
    $ctx.SessionInfo = Get-GuiReadySessionInfo
    $ctx.Uac = Get-GuiReadyUac
    if (Get-Command Get-GuiReadyDotNetStatus -ErrorAction SilentlyContinue) { $ctx.DotNet = Get-GuiReadyDotNetStatus }
    $res.Context = $ctx

    $res.Processes = @(Get-GuiReadyProcessSnapshot -ProcessName $ProcessName -ExePath $ExePath)
    Write-Log ('当前同名进程: {0} 个' -f $res.Processes.Count) 'INFO'
    foreach ($p in $res.Processes) {
        Write-Log ('  PID={0} 会话={1} 响应={2} 窗口={3} 标题={4} 内存={5}MB' -f $p.Id, $p.SessionId, $p.Responding, $p.MainWindowHandle, $p.MainWindowTitle, $p.WorkingSetMB) 'INFO'
    }

    $evAll = @(Get-GuiReadyRecentAppErrors -Minutes $Minutes -NameFilter $ProcessName)
    $res.EventErrors    = @($evAll | Where-Object { $_.Related })
    $res.EventUnrelated = @($evAll | Where-Object { -not $_.Related })

    if ($res.EventErrors.Count -gt 0) {
        Write-Log ('应用事件日志（提到本程序）: {0} 条' -f $res.EventErrors.Count) 'WARN'
        foreach ($e in ($res.EventErrors | Select-Object -First 8)) {
            Write-Log ('  [{0}] {1} (Id={2})  {3}' -f $e.Time, $e.Provider, $e.Id, $e.MessageBrief.Substring(0, [Math]::Min(220, $e.MessageBrief.Length))) 'WARN'
        }
    } else {
        Write-Log '应用事件日志: 时间窗内没有提到本程序的错误/警告' 'OK'
    }
    if ($res.EventUnrelated.Count -gt 0) {
        Write-Log ('  另有 {0} 条其它程序的错误日志，与本程序无关，不作为推断依据' -f $res.EventUnrelated.Count) 'INFO'
    }

    $werAll = @(Get-GuiReadyWerReports -AppNameFilter $ProcessName)
    $res.WerMatching  = @($werAll | Where-Object { $_.Related })
    $res.WerUnrelated = @($werAll | Where-Object { -not $_.Related })
    $res.WerReports   = $res.WerMatching

    if ($res.WerMatching.Count -gt 0) {
        Write-Log ('WER 崩溃报告（属于本程序）: {0} 份' -f $res.WerMatching.Count) 'WARN'
        foreach ($w in ($res.WerMatching | Select-Object -First 5)) {
            Write-Log ('  [{0}] {1}  App={2} {3}  异常码={4}  故障模块={5}' -f $w.Time, $w.EventType, $w.AppName, $w.AppVersion, $w.ExceptionCode, $w.FaultModule) 'WARN'
            if ($w.Signatures) { Write-Log ('      ' + $w.Signatures.Substring(0, [Math]::Min(300, $w.Signatures.Length))) 'INFO' }
        }
    } else {
        Write-Log 'WER 崩溃报告: 没有属于本程序的记录（说明它没崩过，或崩溃未被记录）' 'OK'
        if ($res.WerUnrelated.Count -gt 0) {
            Write-Log ('  另有 {0} 份其它程序的崩溃报告，与本程序无关，不作为推断依据' -f $res.WerUnrelated.Count) 'INFO'
        }
    }

    Write-Log ''
    Write-Log '推断:' 'HEAD'
    $findings = New-Object System.Collections.ArrayList

    $corpus = ''
    foreach ($e in $res.EventErrors) { $corpus += ' ' + $e.MessageRaw }
    foreach ($w in $res.WerReports) { $corpus += ' ' + $w.EventType + ' ' + $w.ExceptionCode + ' ' + $w.FaultModule + ' ' + $w.Signatures }
    foreach ($p in $res.Processes) { $corpus += ' ' + $p.MainWindowTitle }

    if ($res.PeInfo -and $res.PeInfo.IsPe -and $res.MissingPkg.Count -gt 0) {
        [void]$findings.Add([pscustomobject]@{ Cause = '静态依赖缺失'; Advice = ('缺: ' + ($res.MissingPkg -join ', ')) })
    }
    foreach ($r in $Global:GuiReadyErrorSignatures) {
        if ($corpus -match $r.Match) {
            [void]$findings.Add([pscustomobject]@{ Cause = $r.Cause; Advice = $r.Advice })
        }
    }
    if ($res.PeInfo -and $res.PeInfo.SubsystemName -eq 'GUI' -and $res.Processes.Count -gt 0) {
        $withWin = @($res.Processes | Where-Object { $_.MainWindowHandle -ne 0 })
        if ($withWin.Count -eq 0) {
            [void]$findings.Add([pscustomobject]@{ Cause = '进程在运行但没有窗口'; Advice = '可能在 Session 0 或非交互会话启动；确认用交互会话（RDP/控制台）运行，或检查是否缺 GUI 组件。' })
        }
    }
    if ($ctx.Uac.PromptsWillBlock) {
        [void]$findings.Add([pscustomobject]@{ Cause = 'UAC 会弹确认窗'; Advice = '远程/无人值守时带 requireAdministrator 的程序会失败。用 CreateProcess 绕过、改 SYSTEM 计划任务、或人工点确认。' })
    }
    if ($ctx.SessionInfo.LoggedOnCount -eq 0) {
        [void]$findings.Add([pscustomobject]@{ Cause = '没有已登录用户会话'; Advice = '先 RDP 或控制台登录一个用户，否则图形界面无处显示。' })
    }
    if ($res.Processes.Count -eq 0 -and $res.EventErrors.Count -eq 0 -and $res.WerReports.Count -eq 0 -and $res.MissingPkg.Count -eq 0) {
        [void]$findings.Add([pscustomobject]@{ Cause = '没有采集到失败证据'; Advice = '进程未在运行且时间窗内没有错误日志。如果是“双击没反应”，请用菜单里的“启动并诊断”让它记录启动过程。' })
    }

    $res.Findings = @($findings)
    if ($findings.Count -eq 0) {
        Write-Log '  未发现异常特征。' 'OK'
        $res.Conclusion = '未发现异常特征：进程状态正常、依赖齐全、时间窗内没有错误日志。'
    } else {
        foreach ($f in $findings) {
            Write-Log ('  可能原因: {0}' -f $f.Cause) 'WARN'
            Write-Log ('  建议    : {0}' -f $f.Advice) 'INFO'
        }
        $res.Conclusion = (($findings | ForEach-Object { $_.Cause }) -join '；')
    }

    if (-not $NoReport) { Save-JsonReport -Object $res -Name 'diag' | Out-Null }
    return [pscustomobject]$res
}

function Test-PeRequiresElevation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$ChunkMB = 4
    )

    $o = [ordered]@{ Checked = $false; RequiresElevation = $false; HighestAvailable = $false; Evidence = ''; Note = '' }
    if (-not (Test-Path -LiteralPath $Path)) { $o.Note = '文件不存在'; return [pscustomobject]$o }

    # 提权清单以明文 XML 存在 PE 资源里。按 头部 -> 尾部 -> 中间 的顺序扫描，
    # 多数程序在头尾就能命中，避免为一个大安装包做全量扫描。
    $patterns  = @('requireAdministrator', 'highestAvailable')
    $chunkSize = $ChunkMB * 1MB
    $edge      = 8MB

    $len = 0
    try { $len = (Get-Item -LiteralPath $Path).Length } catch { $o.Note = '读取大小失败: ' + $_.Exception.Message; return [pscustomobject]$o }

    $ranges = New-Object System.Collections.ArrayList
    if ($len -le ($edge * 2)) {
        [void]$ranges.Add(@(0, $len))
    } else {
        [void]$ranges.Add(@(0, $edge))
        [void]$ranges.Add(@(($len - $edge), $edge))
        [void]$ranges.Add(@($edge, ($len - $edge * 2)))
    }

    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            foreach ($rg in $ranges) {
                $start     = [long]$rg[0]
                $remaining = [long]$rg[1]
                if ($remaining -le 0) { continue }
                $fs.Position = $start
                $buf   = New-Object byte[] ($chunkSize + 64)
                $carry = 0
                while ($remaining -gt 0) {
                    $want = [int][Math]::Min([long]$chunkSize, $remaining)
                    $read = $fs.Read($buf, $carry, $want)
                    if ($read -le 0) { break }
                    $remaining -= $read
                    $total = $carry + $read
                    $text  = [System.Text.Encoding]::ASCII.GetString($buf, 0, $total)
                    foreach ($p in $patterns) {
                        if ($text.IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            $o.Checked = $true
                            $o.RequiresElevation = $true
                            $o.HighestAvailable  = ($p -eq 'highestAvailable')
                            $o.Evidence = $p
                            $o.Note = ('清单里找到 "' + $p + '"')
                            return [pscustomobject]$o
                        }
                    }
                    if ($total -gt 64) { [Array]::Copy($buf, $total - 64, $buf, 0, 64) }
                    $carry = 64
                }
            }
        } finally { $fs.Dispose() }
        $o.Checked = $true
        $o.Note = '清单里没有 requireAdministrator / highestAvailable'
    } catch {
        $o.Note = '读取失败: ' + $_.Exception.Message
    }
    return [pscustomobject]$o
}

function Invoke-GuiReadyLaunchAndDiagnose {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [string]$Arguments = '',
        [int]$WatchSeconds = 20,
        [switch]$UseShellExecute,
        [switch]$ForceShellExecute,
        [int]$LaunchTimeoutSeconds = 20,
        [switch]$NoReport
    )

    Write-Head '启动并诊断（记录启动全过程）'

    if (-not (Test-Path -LiteralPath $ExePath)) {
        Write-Log ('文件不存在: ' + $ExePath) 'ERROR'
        return $null
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    $before = @(Get-GuiReadyProcessSnapshot -ProcessName $name -ExePath $ExePath)
    Write-Log ('启动前同名进程: {0} 个' -f $before.Count) 'INFO'

    # 先静态判断这个程序要不要提权，避免 ShellExecute 卡在 UAC 确认窗上（UAC 不会自己超时）
    $elev = $null
    if (Get-Command Test-PeRequiresElevation -ErrorAction SilentlyContinue) {
        $elev = Test-PeRequiresElevation -Path $ExePath
        if ($elev.RequiresElevation) {
            Write-Log ('静态探测: 该程序要求提权（清单命中 "' + $elev.Evidence + '"）') 'WARN'
        } else {
            Write-Log ('静态探测: 未发现提权要求（' + $elev.Note + '）') 'INFO'
        }
    }

    $uac = $null
    if (Get-Command Get-GuiReadyUac -ErrorAction SilentlyContinue) { $uac = Get-GuiReadyUac }

    if ($UseShellExecute -and $elev -and $elev.RequiresElevation -and $uac -and $uac.PromptsWillBlock -and -not $ForceShellExecute) {
        Write-Log '' 
        Write-Log '已阻止本次启动（否则工具会挂死在这里）:' 'ERROR'
        Write-Log '  ShellExecute 启动一个要求提权的程序会去弹 UAC 确认窗，而 UAC 默认不会自动超时，' 'WARN'
        Write-Log '  在远程/无人值守会话里没人点击，Process.Start 就会一直阻塞。' 'WARN'
        Write-Log '' 
        Write-Log '可选处置:' 'HEAD'
        Write-Log '  a) 去掉 -UseShellExecute（改用 CreateProcess 绕过 UAC）—— 推荐，菜单里选 [2]' 'INFO'
        Write-Log '  b) 人工 RDP 进会话，自己点确认' 'INFO'
        Write-Log '  c) 用 SYSTEM 计划任务方式运行（菜单：持久化启动）' 'INFO'
        Write-Log '  d) 临时把 ConsentPromptBehaviorAdmin 设为 0（安全降低，用完改回）' 'INFO'
        Write-Log '  确实要在无人点击的情况下强行尝试，加 -ForceShellExecute（会带超时保护）' 'INFO'

        $d0 = Get-GuiReadyAppDiagnostics -ExePath $ExePath -ProcessName $name -NoReport:$NoReport
        return [pscustomobject]@{
            Launched       = $false
            Blocked        = $true
            BlockReason    = ('程序要求提权（' + $elev.Evidence + '）且 UAC 会弹确认窗')
            StartError     = 'BlockedByUacGuard'
            Diagnostics    = $d0
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    if ($Arguments) { $psi.Arguments = $Arguments }
    $psi.WorkingDirectory = Split-Path -Parent $ExePath

    if ($UseShellExecute) {
        $psi.UseShellExecute = $true
        Write-Log '启动方式: ShellExecute（会走 UAC，可能弹提权确认）' 'INFO'
    } else {
        $psi.UseShellExecute = $false
        Write-Log '启动方式: CreateProcess（不走 UAC，不会被提权确认拦下）' 'INFO'
    }

    $proc = $null
    if ($UseShellExecute -and $ForceShellExecute) {
        # 强制走 ShellExecute 时用后台作业加超时保护，卡住也能收回控制权
        Write-Log ('强制尝试 ShellExecute，带 {0} 秒超时保护' -f $LaunchTimeoutSeconds) 'WARN'
        $job = Start-Job -ScriptBlock {
            param($f, $a, $wd)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $f
            if ($a) { $psi.Arguments = $a }
            $psi.WorkingDirectory = $wd
            $psi.UseShellExecute = $true
            try {
                $p = [System.Diagnostics.Process]::Start($psi)
                'PID=' + $p.Id
            } catch {
                'ERR=' + $_.Exception.Message
            }
        } -ArgumentList $ExePath, $Arguments, (Split-Path -Parent $ExePath)

        $finished = Wait-Job $job -Timeout $LaunchTimeoutSeconds
        if (-not $finished) {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            Write-Log ('超过 {0} 秒仍未返回 —— 确认卡在 UAC 确认窗上。已收回控制权。' -f $LaunchTimeoutSeconds) 'ERROR'
            Write-Log '请改用 CreateProcess（去掉 -UseShellExecute），或用菜单里的持久化启动。' 'WARN'
            $dTimeout = Get-GuiReadyAppDiagnostics -ExePath $ExePath -ProcessName $name -NoReport:$NoReport
            return [pscustomobject]@{
                Launched       = $false
                Blocked        = $true
                BlockReason    = ('ShellExecute 卡在 UAC 确认窗，超过 ' + $LaunchTimeoutSeconds + ' 秒')
                StartError     = 'UacPromptBlocked'
                Diagnostics    = $dTimeout
            }
        }
        $out = ((Receive-Job $job) | Out-String).Trim()
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Write-Log ('  ShellExecute 返回: ' + $out) 'INFO'
        if ($out -match '^ERR=(.+)$') {
            $msg = $Matches[1]
            Write-Log ('启动失败: ' + $msg) 'ERROR'
            if ($msg -match '操作已被用户取消|cancelled by the user') {
                Write-Log '这正是 UAC 提权被拒的典型表现。改用 CreateProcess（去掉 -UseShellExecute）重试。' 'WARN'
            }
            $dErr = Get-GuiReadyAppDiagnostics -ExePath $ExePath -ProcessName $name -NoReport:$NoReport
            return [pscustomobject]@{ Launched = $false; StartError = $msg; Diagnostics = $dErr }
        }
        $pid2 = 0
        if ($out -match '^PID=(\d+)$') { $pid2 = [int]$Matches[1] }
        try { $proc = Get-Process -Id $pid2 -ErrorAction Stop } catch { $proc = $null }
        Write-Log ('已启动 PID=' + $pid2) 'OK'
    } else {
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
            Write-Log ('已启动 PID=' + $proc.Id) 'OK'
        } catch {
            $msg = $_.Exception.GetType().FullName + ' :: ' + $_.Exception.Message
            Write-Log ('启动失败: ' + $msg) 'ERROR'
            if ($msg -match '操作已被用户取消|cancelled by the user') {
                Write-Log '这正是 UAC 提权被拒的典型表现。改用 CreateProcess（去掉 -UseShellExecute）重试。' 'WARN'
            }
            $d = Get-GuiReadyAppDiagnostics -ExePath $ExePath -ProcessName $name -NoReport:$NoReport
            return [pscustomobject]@{ Launched = $false; StartError = $msg; Diagnostics = $d }
        }
    }

    if (-not $proc) {
        Write-Log '进程句柄未取到，改为按名称监视。' 'WARN'
    }

    $firstWindow = -1
    $t0 = Get-Date
    $sawExit = $false
    for ($i = 1; $i -le [Math]::Max(1, [int]($WatchSeconds / 2)); $i++) {
        Start-Sleep -Seconds 2
        $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

        if ($proc) {
            $proc.Refresh()
            if ($proc.HasExited) {
                Write-Log ('  t={0}s 进程已退出 ExitCode={1} (0x{1:X})' -f $sec, $proc.ExitCode) 'WARN'
                $sawExit = $true
                break
            }
            $h = 0; $t = ''
            try { $h = [int64]$proc.MainWindowHandle; $t = $proc.MainWindowTitle } catch { }
        } else {
            # 没拿到进程句柄（例如经后台作业启动），改为按名称轮询
            $snap = @(Get-GuiReadyProcessSnapshot -ProcessName $name)
            if ($snap.Count -eq 0) {
                Write-Log ('  t={0}s 按名称未找到进程，视为已退出' -f $sec) 'WARN'
                $sawExit = $true
                break
            }
            $h = [int64]$snap[0].MainWindowHandle
            $t = [string]$snap[0].MainWindowTitle
        }

        if ($firstWindow -lt 0 -and $h -ne 0) {
            $firstWindow = $sec
            Write-Log ('  t={0}s 首个窗口出现 句柄={1} 标题={2}' -f $sec, $h, $t) 'OK'
            break
        }
        if ($i % 3 -eq 0) { Write-Log ('  t={0}s 运行中，尚无窗口' -f $sec) 'INFO' }
    }

    $diag = Get-GuiReadyAppDiagnostics -ExePath $ExePath -ProcessName $name -NoReport:$NoReport

    $verdict = ''
    if ($sawExit) { $verdict = '启动后很快退出，请看下面的事件日志/WER 采集结果定位原因。' }
    elseif ($firstWindow -lt 0) { $verdict = ('观察 {0} 秒内没有出现窗口。程序可能仍在初始化、或窗口创建失败，请看“进程在运行但没有窗口”的推断。' -f $WatchSeconds) }
    else { $verdict = ('首个窗口用时 {0} 秒，程序可以正常显示界面。' -f $firstWindow) }

    Write-Log ''
    Write-Log ('结论: ' + $verdict) $(if ($firstWindow -ge 0) { 'OK' } else { 'WARN' })

    $pidOut = 0
    if ($proc) { $pidOut = $proc.Id }
    elseif ($pid2) { $pidOut = $pid2 }

    return [pscustomobject]@{
        Launched       = $true
        Pid            = $pidOut
        FirstWindowSec = $firstWindow
        Exited         = $sawExit
        Verdict        = $verdict
        Diagnostics    = $diag
    }
}

# GuiReady entry point: console menu (two-level)

$ErrorActionPreference = 'Continue'
try { [Console]::Title = 'Server Core GUI 就绪工具' } catch { }

$here = $PSScriptRoot
foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Detect.ps1', 'GuiReady.PeInspect.ps1',
                 'GuiReady.Fod.ps1', 'GuiReady.GuiShell.ps1', 'GuiReady.RdpFix.ps1',
                 'GuiReady.DotNet.ps1', 'GuiReady.GuiTest.ps1', 'GuiReady.Matrix.ps1',
                 'GuiReady.Diag.ps1', 'GuiReady.Catalog.ps1', 'GuiReady.Pipeline.ps1',
                 'GuiReady.AutoLogon.ps1', 'GuiReady.Command.ps1', 'GuiReady.PhaseB.ps1', 'GuiReady.Wac.ps1')) {
    $p = Join-Path $here ('lib\' + $f)
    if (Test-Path -LiteralPath $p) {
        . $p
    } else {
        Write-Host ('缺少模块: ' + $p) -ForegroundColor Red
        return
    }
}

function Show-Banner {
    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor Cyan
    Write-Host '   Server Core GUI 就绪工具' -ForegroundColor Cyan
    Write-Host '   目标：在 Windows Server Core 上把带界面的程序跑起来、看得见' -ForegroundColor Cyan
    Write-Host '   作者 mmm   QQ群 1034243331' -ForegroundColor Cyan
    Write-Host '   https://github.com/OrangeArtc0915/Server-core-manager' -ForegroundColor Cyan
    Write-Host '  ================================================================' -ForegroundColor Cyan
    $admin = '否'
    if (Test-IsAdministrator) { $admin = '是' }
    $prof = $null
    try { $prof = Get-GuiReadyOsProfile } catch { }
    $osText = '未知'
    if ($prof) { $osText = ('{0}  Build {1}  {2}' -f $prof.Name, $prof.Build, $prof.InstallationType) }
    Write-Host ('   系统: {0}' -f $osText) -ForegroundColor DarkGray
    Write-Host ('   管理员权限: {0}    日志: {1}' -f $admin, $Global:GuiReadyLogFile) -ForegroundColor DarkGray
    $st = $null
    try { $st = Get-GuiReadyPipelineState } catch { }
    if ($st -and -not $st.Finished) {
        Write-Host ('   提示: 有一个未完成的流程（第 {0}/{1} 步），可在菜单 1 -> 3 续跑' -f ($st.StepIndex + 1), $st.Steps.Count) -ForegroundColor Yellow
    }
    Write-Host ''
}

function Show-Menu {
    Write-Host '  [1] 一键流程' -ForegroundColor Yellow
    Write-Host '      新建 / 续跑 / 查看状态 / 终止（断点续跑，可跨重启）'
    Write-Host ''
    Write-Host '  [2] 探测与诊断' -ForegroundColor Yellow
    Write-Host '      环境探测 / 版本适配矩阵 / exe 兼容性预检 / GUI 能力自检 / 启动并诊断'
    Write-Host ''
    Write-Host '  [3] 补给' -ForegroundColor Yellow
    Write-Host '      装 App Compatibility FOD / 按需补齐 .NET / 补 Server-Gui-Shell'
    Write-Host ''
    Write-Host '  [4] 程序兼容档案' -ForegroundColor Yellow
    Write-Host '      查询某个程序 / 列出全部 / 添加你自己的结论'
    Write-Host ''
    Write-Host '  [5] 会话与使用' -ForegroundColor Yellow
    Write-Host '      RDP 状态 / 会话修复 / 登录 Shell / 图形启动器 / 持久化启动 / 日志报告'
    Write-Host ''
    Write-Host '  [6] 阶段 B（IDD 远程渲染）准备指引'
    Write-Host ''
    Write-Host '  [0] 退出'
    Write-Host ''
}

function Show-SubMenu {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][array]$Items
    )

    while ($true) {
        Write-Host ''
        Write-Host ('  ' + $Title) -ForegroundColor Cyan
        Write-Host ('  ' + ('-' * 52)) -ForegroundColor DarkGray
        foreach ($it in $Items) {
            Write-Host ('    {0,2}. {1}' -f $it.Key, $it.Text)
        }
        Write-Host '     0. 返回上级'
        Write-Host ''
        $sel = Read-Host '  请选择'
        if ([string]::IsNullOrWhiteSpace($sel) -or $sel -eq '0') { return }
        $hit = @($Items | Where-Object { [string]$_.Key -eq $sel })
        if ($hit.Count -gt 0) {
            try { & $hit[0].Action } catch {
                Write-Log ('操作异常: {0} @ {1}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) 'ERROR'
                Write-Host ('  操作异常: ' + $_.Exception.Message) -ForegroundColor Red
            }
        } else {
            Write-Log ('无效选项: ' + $sel) 'WARN'
        }
        Write-Host ''
        [void](Read-Host '  按回车继续')
    }
}

# ---------------- 1. 一键流程 ----------------

function Invoke-MenuPipelineStart {
    param([switch]$AutoReboot, [switch]$SkipReboot)

    Write-Host ''
    Write-Host '  可以指定要关注的程序（会按需求补 .NET、查档案、做启动诊断）。' -ForegroundColor Yellow
    Write-Host '  多个用分号分隔；直接回车表示不指定。' -ForegroundColor Yellow
    $in = Read-Host '  程序路径'
    $apps = @()
    if (-not [string]::IsNullOrWhiteSpace($in)) {
        foreach ($p in ($in -split ';')) {
            $t = $p.Trim().Trim('"')
            if ($t) { $apps += $t }
        }
    }
    Write-Host ''
    Write-Host '  [1] 确认开始  [0] 取消' -ForegroundColor Yellow
    $m = Read-Host '  选择'
    if ($m -ne '1') { Write-Log '已取消。' 'WARN'; return }

    Invoke-GuiReadyPipeline -AppPaths $apps -AutoReboot:$AutoReboot -SkipReboot:$SkipReboot | Out-Null
}

function Invoke-MenuPipeline {
    $items = @(
        @{ Key = 1; Text = '新建并跑完整个流程（按需装 FOD、自动重启、复核、补 .NET、自检、汇总）'; Action = { Invoke-MenuPipelineStart -AutoReboot } },
        @{ Key = 2; Text = '新建但不自动重启（需要重启时暂停，等你手动重启后走第 3 项）'; Action = { Invoke-MenuPipelineStart -SkipReboot } },
        @{ Key = 3; Text = '续跑未完成的流程'; Action = { Resume-GuiReadyPipeline | Out-Null } },
        @{ Key = 4; Text = '查看流程状态'; Action = { Show-GuiReadyPipelineState | Out-Null } },
        @{ Key = 5; Text = '终止流程（清状态 + 注销续跑任务）'; Action = { Stop-GuiReadyPipeline } }
    )
    Show-SubMenu -Title '一键流程' -Items $items
}

# ---------------- 2. 探测与诊断 ----------------

function Invoke-MenuPeCheck {
    Write-Host ''
    Write-Host '  输入 exe 的完整路径，或一个目录（会检查该目录下前 40 个 exe）' -ForegroundColor Yellow
    $p = Read-Host '  路径'
    if ([string]::IsNullOrWhiteSpace($p)) { Write-Log '未提供路径，已取消。' 'WARN'; return }
    if (-not (Test-Path -LiteralPath $p)) { Write-Log ('路径不存在: ' + $p) 'ERROR'; return }
    Invoke-GuiReadyPeCheck -Path $p | Out-Null
}

function Invoke-MenuGuiTest {
    Write-Host ''
    Write-Host '  [1] 只测 WinForms / WPF 建窗与抓图' -ForegroundColor Yellow
    Write-Host '  [2] 同时启动 记事本 / MMC / 性能监视器 实测' -ForegroundColor Yellow
    Write-Host '  [0] 取消' -ForegroundColor Yellow
    $m = Read-Host '  选择'
    switch ($m) {
        '1' { Start-GuiReadyGuiSelfTest | Out-Null }
        '2' { Start-GuiReadyGuiSelfTest -IncludeApps | Out-Null }
        default { Write-Log '已取消。' 'WARN' }
    }
}

function Invoke-MenuMatrix {
    $rep = $null
    if ($Global:GuiReadyReport) { $rep = $Global:GuiReadyReport } else { $rep = Invoke-GuiReadyDetect -Quiet }
    Show-GuiReadyMatrix -Static $rep.Static -DllScan $rep.DllScan -Services $rep.Services -Sessions $rep.Sessions -Uac $rep.Uac | Out-Null
}

function Invoke-MenuLaunchDiag {
    Write-Host ''
    $p = Read-Host '  程序 exe 完整路径'
    if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path -LiteralPath $p)) { Write-Log '路径无效，已取消。' 'WARN'; return }
    $a = Read-Host '  启动参数（可留空）'
    Write-Host '  [1] 只采集诊断信息（不启动）' -ForegroundColor Yellow
    Write-Host '  [2] 启动并诊断（CreateProcess，不走 UAC，推荐）' -ForegroundColor Yellow
    Write-Host '  [3] 启动并诊断（ShellExecute，会走 UAC）' -ForegroundColor Yellow
    Write-Host '      说明：若该程序要求提权且 UAC 会弹窗，工具会先静态探测到并拒绝启动，' -ForegroundColor DarkGray
    Write-Host '            避免卡在无人点击的确认窗上（UAC 不会自动超时）。' -ForegroundColor DarkGray
    Write-Host '  [0] 取消' -ForegroundColor Yellow
    $m = Read-Host '  选择'
    switch ($m) {
        '1' { Get-GuiReadyAppDiagnostics -ExePath $p | Out-Null }
        '2' { Invoke-GuiReadyLaunchAndDiagnose -ExePath $p -Arguments $a | Out-Null }
        '3' { Invoke-GuiReadyLaunchAndDiagnose -ExePath $p -Arguments $a -UseShellExecute | Out-Null }
        default { Write-Log '已取消。' 'WARN' }
    }
}

function Invoke-MenuCatalogAdd {
    Write-Host ''
    $exe = Read-Host '  程序 exe 完整路径（用来取默认值，可留空）'
    $defName = ''
    $defPattern = ''
    if (-not [string]::IsNullOrWhiteSpace($exe) -and (Test-Path -LiteralPath $exe)) {
        $defName = [System.IO.Path]::GetFileNameWithoutExtension($exe)
        $defPattern = '^' + [regex]::Escape($defName) + '$'
    }
    $id = Read-Host ('  条目 id [回车用 ' + $defName + ']')
    if ([string]::IsNullOrWhiteSpace($id)) { $id = $defName }
    if ([string]::IsNullOrWhiteSpace($id)) { Write-Log '未提供 id，已取消。' 'WARN'; return }
    $nm = Read-Host ('  显示名称 [回车用 ' + $defName + ']')
    if ([string]::IsNullOrWhiteSpace($nm)) { $nm = $defName }
    $pat = Read-Host ('  匹配进程名正则 [回车用 ' + $defPattern + ']')
    if ([string]::IsNullOrWhiteSpace($pat)) { $pat = $defPattern }
    if ([string]::IsNullOrWhiteSpace($pat)) { Write-Log '未提供匹配规则，已取消。' 'WARN'; return }

    Write-Host '  结论: [1] 可用  [2] 可用（建议参数）  [3] 不支持  [4] 未知' -ForegroundColor Yellow
    $v = Read-Host '  选择'
    $verdict = '未知'
    if ($v -eq '1') { $verdict = '可用' }
    elseif ($v -eq '2') { $verdict = '可用（建议参数）' }
    elseif ($v -eq '3') { $verdict = '不支持' }

    $la = Read-Host '  推荐启动参数（可留空）'
    $notes = Read-Host '  备注（可留空）'
    $ev = Read-Host '  实测证据（可留空）'
    $vo = Read-Host ('  实测系统 build [回车用当前 ' + (Get-GuiReadyStatic).Build + ']')
    if ([string]::IsNullOrWhiteSpace($vo)) { $vo = (Get-GuiReadyStatic).Build }

    Add-GuiReadyCatalogEntry -Id $id -Name $nm -ExeNamePattern $pat -Verdict $verdict `
        -LaunchArgs $la -Notes $notes -Evidence $ev -VerifiedOn $vo | Out-Null
}

function Invoke-MenuCatalog {
    $items = @(
        @{ Key = 1; Text = '按 exe 查询档案（含推荐启动参数与实测证据）'; Action = {
                $p = Read-Host '  程序 exe 完整路径'
                if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) { Show-GuiReadyCatalogEntry -ExePath $p | Out-Null }
                else { Write-Log '路径无效。' 'WARN' }
            } },
        @{ Key = 2; Text = '列出全部档案条目'; Action = { Show-GuiReadyCatalogList | Out-Null } },
        @{ Key = 3; Text = '添加你自己的档案条目（下次自动命中）'; Action = { Invoke-MenuCatalogAdd } }
    )
    Show-SubMenu -Title '程序兼容档案' -Items $items
}

function Invoke-MenuDetectDiag {
    $items = @(
        @{ Key = 1; Text = '环境探测（只读，建议第一步）'; Action = { Invoke-GuiReadyDetect | Out-Null } },
        @{ Key = 2; Text = '版本适配矩阵与能力差距报告'; Action = { Invoke-MenuMatrix } },
        @{ Key = 3; Text = 'exe 兼容性预检（静态依赖 + 类型识别）'; Action = { Invoke-MenuPeCheck } },
        @{ Key = 4; Text = 'GUI 能力自检（真的建窗 + 抓图取证）'; Action = { Invoke-MenuGuiTest } },
        @{ Key = 5; Text = '启动并诊断（程序没反应/起不来时用）'; Action = { Invoke-MenuLaunchDiag } },
        @{ Key = 6; Text = '程序兼容档案：查询 / 列出 / 添加'; Action = { Invoke-MenuCatalog } }
    )
    Show-SubMenu -Title '探测与诊断' -Items $items
}

# ---------------- 3. 补给 ----------------

function Invoke-MenuFod {
    Write-Host ''
    Write-Host '  [1] 走 Windows Update 在线安装' -ForegroundColor Yellow
    Write-Host '  [2] 用离线介质安装（需要 FOD ISO 或 LanguagesAndOptionalFeatures 目录）' -ForegroundColor Yellow
    Write-Host '  [3] 只预览' -ForegroundColor Yellow
    Write-Host '  [0] 取消' -ForegroundColor Yellow
    $m = Read-Host '  选择'
    switch ($m) {
        '1' { Install-GuiReadyFod }
        '2' {
            $sp = Read-Host '  FOD ISO 路径或目录'
            if ([string]::IsNullOrWhiteSpace($sp)) { Write-Log '未提供路径，已取消。' 'WARN'; return }
            Install-GuiReadyFod -SourcePath $sp
        }
        '3' {
            $sp = Read-Host '  （可选）FOD ISO 路径或目录，直接回车表示在线方式'
            Install-GuiReadyFod -SourcePath $sp -WhatIf
        }
        default { Write-Log '已取消。' 'WARN' }
    }
}

function Invoke-MenuDotNetFix {
    Write-Host ''
    Write-Host '  输入那个“跑不起来”的程序 exe 路径，我会识别它需要哪个 .NET 版本并自动补齐' -ForegroundColor Yellow
    $p = Read-Host '  exe 路径'
    if ([string]::IsNullOrWhiteSpace($p)) { Write-Log '未提供路径，已取消。' 'WARN'; return }
    if (-not (Test-Path -LiteralPath $p)) { Write-Log ('路径不存在: ' + $p) 'ERROR'; return }
    Write-Host '  [1] 只预览  [2] 确认下载并部署  [0] 取消' -ForegroundColor Yellow
    $m = Read-Host '  选择'
    if ($m -eq '1') { Invoke-GuiReadyDotNetFix -ExePath $p -WhatIf }
    elseif ($m -eq '2') { Invoke-GuiReadyDotNetFix -ExePath $p }
    else { Write-Log '已取消。' 'WARN' }
}

function Invoke-MenuGuiShell {
    Write-Host ''
    Write-Host '  请提供与本机 build 一致的安装介质（install.wim / install.esd）。' -ForegroundColor Yellow
    Write-Host '  找不到的话，把 Windows Server 安装 ISO 挂载或解压后指向 \sources\install.wim。' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  提示：真正的 Server Core SKU（2016+）功能列表里没有 Server-Gui-Shell，本操作会直接判定不可行。' -ForegroundColor Yellow
    Write-Host ''

    $media = Get-GuiReadyMedia
    $guess = ''
    foreach ($c in $media.Candidates) {
        if ($c.Kind -eq 'Image') { $guess = $c.Path; break }
    }

    $prompt = '  WIM/ESD 路径'
    if ($guess) { $prompt += (' [回车使用 ' + $guess + ']') }
    $in = Read-Host $prompt
    $wim = $in
    if ([string]::IsNullOrWhiteSpace($wim)) { $wim = $guess }
    if ([string]::IsNullOrWhiteSpace($wim)) { Write-Log '未提供介质路径，已取消。' 'WARN'; return }

    Write-Host ''
    Write-Host '  [1] 只预览（不修改系统）  [2] 确认执行  [0] 取消' -ForegroundColor Yellow
    $mode = Read-Host '  选择'
    switch ($mode) {
        '1' { Install-GuiReadyGuiShell -WimPath $wim -WhatIf }
        '2' {
            $c = Read-Host '  这是非官方操作，输入 YES 确认执行'
            if ($c -eq 'YES') { Install-GuiReadyGuiShell -WimPath $wim -Confirm } else { Write-Log '已取消。' 'WARN' }
        }
        default { Write-Log '已取消。' 'WARN' }
    }
}

function Invoke-MenuSupply {
    $items = @(
        @{ Key = 1; Text = '安装 App Compatibility FOD（官方路线，低风险）'; Action = { Invoke-MenuFod } },
        @{ Key = 2; Text = '按程序需求补齐 .NET 运行时（免安装方式）'; Action = { Invoke-MenuDotNetFix } },
        @{ Key = 3; Text = '用安装介质补全 Server-Gui-Shell（非官方，高风险）'; Action = { Invoke-MenuGuiShell } },
        @{ Key = 4; Text = '回滚 Server-Gui-Shell'; Action = {
                Write-Host '  [1] 只预览  [2] 确认回滚  [0] 取消' -ForegroundColor Yellow
                $m = Read-Host '  选择'
                if ($m -eq '1') { Uninstall-GuiReadyGuiShell -WhatIf }
                elseif ($m -eq '2') { Uninstall-GuiReadyGuiShell -Confirm }
                else { Write-Log '已取消。' 'WARN' }
            } }
    )
    Show-SubMenu -Title '补给' -Items $items
}

# ---------------- 5. 会话与使用 ----------------

function Invoke-MenuShell {
    Write-Host ''
    Write-Host '  [1] explorer.exe（需要先装 FOD，否则登录后是黑屏）' -ForegroundColor Yellow
    Write-Host '  [2] 本工具的图形启动器' -ForegroundColor Yellow
    Write-Host '  [3] cmd.exe（Server Core 默认）' -ForegroundColor Yellow
    Write-Host '  [0] 取消' -ForegroundColor Yellow
    $m = Read-Host '  选择'
    switch ($m) {
        '1' { Set-GuiReadyShell -Mode Explorer }
        '2' { Set-GuiReadyShell -Mode Launcher }
        '3' { Set-GuiReadyShell -Mode Cmd }
        default { Write-Log '已取消。' 'WARN' }
    }
}

function Invoke-MenuPersistent {
    Write-Host ''
    Write-Host '  通过计划任务启动程序，这样进程不会随远程会话断开而被杀掉（守护进程/服务类程序用）' -ForegroundColor Yellow
    $exe = Read-Host '  程序 exe 完整路径'
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) { Write-Log '路径无效，已取消。' 'WARN'; return }
    $defName = [System.IO.Path]::GetFileNameWithoutExtension($exe)
    $name = Read-Host ('  任务名称 [回车用 ' + $defName + ']')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $defName }
    $defArgs = Get-GuiReadyCatalogLaunchArgs -ExePath $exe
    if ($defArgs) { Write-Host ('  档案推荐参数: ' + $defArgs) -ForegroundColor Green }
    $a = Read-Host ('  启动参数 [回车用推荐值' + $(if ($defArgs) { '' } else { '，无' }) + ']')
    if ([string]::IsNullOrWhiteSpace($a)) { $a = $defArgs }
    $wd = Read-Host '  工作目录（可留空，默认用 exe 所在目录）'
    Write-Host '  [1] 只启动  [2] 启动并设为开机自启  [0] 取消' -ForegroundColor Yellow
    $m = Read-Host '  选择'
    if ($m -eq '1') { Start-GuiReadyPersistentProcess -Name $name -ExePath $exe -Arguments $a -WorkingDirectory $wd | Out-Null }
    elseif ($m -eq '2') { Start-GuiReadyPersistentProcess -Name $name -ExePath $exe -Arguments $a -WorkingDirectory $wd -AtStartup | Out-Null }
    else { Write-Log '已取消。' 'WARN' }
}

function Invoke-MenuAutoLogon {
    Write-Host ''
    Write-Host '  开机自动登录：让机器重启后自动建立用户会话。' -ForegroundColor Yellow
    Write-Host '  需要它的原因：没有用户会话时，GUI 程序无处显示，阶段 B 的 WTSQueryUserToken 也拿不到令牌。' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  密码存储方式：' -ForegroundColor Yellow
    Write-Host '    [1] LSA 机密（推荐）：密码存为 LSA 私有数据，不写注册表明文' -ForegroundColor Green
    Write-Host '    [2] 注册表明文：照 MS KB324737 写 DefaultPassword，可被 Authenticated Users 远程读取' -ForegroundColor DarkYellow
    Write-Host '    [0] 取消' -ForegroundColor Yellow
    $m = Read-Host '  选择'
    if ($m -ne '1' -and $m -ne '2') { Write-Log '已取消。' 'WARN'; return }

    $defUser = ''
    try { $defUser = [Environment]::UserName } catch { }
    $u = Read-Host ('  要自动登录的账户名 [回车用 ' + $defUser + ']')
    if ([string]::IsNullOrWhiteSpace($u)) { $u = $defUser }
    if ([string]::IsNullOrWhiteSpace($u)) { Write-Log '未提供账户名，已取消。' 'WARN'; return }

    Write-Host ('  域/计算机名 [回车用本机 ' + $env:COMPUTERNAME + ']') -ForegroundColor Yellow
    $d = Read-Host '  '
    if ([string]::IsNullOrWhiteSpace($d)) { $d = $env:COMPUTERNAME }

    $sec = Read-Host '  密码（输入时不显示）' -AsSecureString
    $plain = ''
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { Write-Log ('读取密码失败: ' + $_.Exception.Message) 'ERROR'; return }
    if ([string]::IsNullOrEmpty($plain)) { Write-Log '密码为空，无法自动登录，已取消。' 'ERROR'; return }

    Write-Host ''
    Write-Host '  自动登录次数 [回车=每次重启都自动登录；也可填正整数，例如 3 表示只自动登录 3 次]' -ForegroundColor Yellow
    $c = Read-Host '  次数'
    $cnt = 0
    if (-not [string]::IsNullOrWhiteSpace($c)) { [void][int]::TryParse($c, [ref]$cnt) }

    Write-Host ''
    Write-Host ('  [1] 只预览  [2] 确认启用（{0}）  [0] 取消' -f $(if ($m -eq '1') { 'LSA 机密方式' } else { '注册表明文方式' })) -ForegroundColor Yellow
    $go = Read-Host '  选择'
    if ($go -eq '1') {
        Set-GuiReadyAutoLogon -User $u -Password $plain -Domain $d -AutoLogonCount $cnt -UseRegistryPlaintext:($m -eq '2') -WhatIf | Out-Null
    } elseif ($go -eq '2') {
        Set-GuiReadyAutoLogon -User $u -Password $plain -Domain $d -AutoLogonCount $cnt -UseRegistryPlaintext:($m -eq '2') | Out-Null
    } else { Write-Log '已取消。' 'WARN' }
    $plain = $null
    [GC]::Collect()
}

function Invoke-MenuSession {
    $items = @(
        @{ Key = 1; Text = '查看 RDP / 会话 / UAC / .NET 状态'; Action = { Show-GuiReadyRdpStatus } },
        @{ Key = 2; Text = '远程会话一键修复（启用 RDP + 关闭 WDDM 驱动）'; Action = {
                Write-Host '  [1] 只预览  [2] 确认执行（会断开当前 RDP 会话）  [0] 取消' -ForegroundColor Yellow
                $m = Read-Host '  选择'
                if ($m -eq '1') { Invoke-GuiReadyRdpQuickFix -WhatIf }
                elseif ($m -eq '2') { Invoke-GuiReadyRdpQuickFix }
                else { Write-Log '已取消。' 'WARN' }
            } },
        @{ Key = 3; Text = '开机自动登录：查看状态'; Action = { Show-GuiReadyAutoLogonStatus | Out-Null } },
        @{ Key = 4; Text = '开机自动登录：启用 / 预览'; Action = { Invoke-MenuAutoLogon } },
        @{ Key = 5; Text = '开机自动登录：关闭（清理密码与注册表项）'; Action = {
                Write-Host '  [1] 只预览  [2] 确认关闭  [0] 取消' -ForegroundColor Yellow
                $m = Read-Host '  选择'
                if ($m -eq '1') { Disable-GuiReadyAutoLogon -WhatIf | Out-Null }
                elseif ($m -eq '2') { Disable-GuiReadyAutoLogon | Out-Null }
                else { Write-Log '已取消。' 'WARN' }
            } },
        @{ Key = 6; Text = '设置登录 Shell（explorer / 启动器 / cmd）'; Action = { Invoke-MenuShell } },
        @{ Key = 7; Text = '启动图形启动器'; Action = {
                $lp = Join-Path $here 'launcher\Start-Launcher.ps1'
                if (Test-Path -LiteralPath $lp) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lp }
                else { Write-Log ('启动器不存在: ' + $lp) 'ERROR' }
            } },
        @{ Key = 8; Text = '持久化启动程序（计划任务，不会被会话杀掉）'; Action = { Invoke-MenuPersistent } },
        @{ Key = 9; Text = '打开日志目录'; Action = { Start-Process -FilePath (Join-Path $here 'logs') | Out-Null } },
        @{ Key = 10; Text = '打开报告目录'; Action = { Start-Process -FilePath (Join-Path $here 'reports') | Out-Null } },
        @{ Key = 11; Text = '一行命令启动：查看状态'; Action = { Show-GuiReadyCommandStatus | Out-Null } },
        @{ Key = 12; Text = '一行命令启动：安装 / 卸载（像 sconfig 那样一个词打开本工具）'; Action = {
                $sys32 = Join-Path $env:windir 'System32'
                Write-Host ''
                Write-Host ('   默认命令名: scm     安装位置: ' + $sys32) -ForegroundColor Yellow
                Write-Host '   装完后在任意目录（cmd 或 PowerShell）输入 scm 就能打开本工具，' -ForegroundColor Yellow
                Write-Host '   和 sconfig 的原理一样：把一个 .cmd 放进 PATH 目录里，命令自己会提权。' -ForegroundColor Yellow
                Write-Host ''
                Write-Host '   [1] 安装' -ForegroundColor Yellow
                Write-Host '   [2] 卸载' -ForegroundColor Yellow
                Write-Host '   [3] 换个命令名安装' -ForegroundColor Yellow
                Write-Host '   [0] 取消' -ForegroundColor Yellow
                $m = Read-Host '  选择'
                switch ($m) {
                    '1' { Install-GuiReadyCommand | Out-Null }
                    '2' { Uninstall-GuiReadyCommand | Out-Null }
                    '3' {
                            $n = Read-Host '  新的命令名'
                            if (-not [string]::IsNullOrWhiteSpace($n)) { Install-GuiReadyCommand -Name $n.Trim() | Out-Null }
                            else { Write-Log '未提供命令名，已取消。' 'WARN' }
                        }
                    default { Write-Log '已取消。' 'WARN' }
                }
            } }
    )
    Show-SubMenu -Title '会话与使用' -Items $items
}

# ---------------- 6. 阶段 B 指引 ----------------

function Show-PhaseBGuide {
    Show-GuiReadyPhaseBGuide
}
# ---------------- 主菜单 ----------------

function Invoke-Menu {
    while ($true) {
        Show-Menu
        $sel = Read-Host '  请选择'
        Write-Host ''
        switch ($sel) {
            '1' { Invoke-MenuPipeline }
            '2' { Invoke-MenuDetectDiag }
            '3' { Invoke-MenuSupply }
            '4' { Invoke-MenuCatalog }
            '5' { Invoke-MenuSession }
            '6' { Show-PhaseBGuide }
            '0' { return }
            default { Write-Log ('无效选项: ' + $sel) 'WARN' }
        }
        Write-Host ''
        [void](Read-Host '  按回车继续')
    }
}

Show-Banner
try {
    Invoke-Menu
} catch {
    Write-Host ''
    Write-Host ('  发生未处理的错误: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('  位置: ' + $_.InvocationInfo.PositionMessage) -ForegroundColor Red
    Write-Host ('  日志: ' + $Global:GuiReadyLogFile) -ForegroundColor Red
    Write-Log ('未处理错误: {0} @ {1}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) 'ERROR'
    [void](Read-Host '  按回车退出')
}

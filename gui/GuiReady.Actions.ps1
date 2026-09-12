# GuiReady actions: single source of truth shared by the GUI and the headless runner.
# Each action runs with a hashtable of parameters: the GUI builds it, the runner passes it in.
# Script blocks take param($P) so lookups are explicit and scope-safe.

function Get-GuiReadyActions {
    return @(
        # ---------------- 一键流程 ----------------
        [pscustomobject]@{
            Id    = 'pipeline-auto'
            Group = '一键流程'
            Name  = '一键就绪（按需装 FOD + 自动重启 + 续跑）'
            Desc  = '探测 → 按需装 App Compatibility FOD → 自动重启 → 重启后自动续跑 → 复核 → 补 .NET → 查档案 → 诊断 → GUI 自检 → 汇总。全程无需干预。'
            Params = @(
                @{ Name = 'Apps'; Label = '关注程序路径（可空，多个用分号分隔）'; Type = 'Text'; Width = 520 }
            )
            DryRun = $false
            Script = {
                param($P)
                $apps = @()
                if ($P['Apps']) { foreach ($x in ([string]$P['Apps'] -split ';')) { $t = $x.Trim().Trim('"'); if ($t) { $apps += $t } } }
                Invoke-GuiReadyPipeline -AppPaths $apps -AutoReboot | Out-Null
            }
        }
        [pscustomobject]@{
            Id    = 'pipeline-noReboot'
            Group = '一键流程'
            Name  = '一键就绪（需要重启时暂停，不自动重启）'
            Desc  = '与上面相同，但遇到需要重启的步骤会停下来，等你自己重启后到本页点“续跑”。'
            Params = @(
                @{ Name = 'Apps'; Label = '关注程序路径（可空，多个用分号分隔）'; Type = 'Text'; Width = 520 }
            )
            DryRun = $false
            Script = {
                param($P)
                $apps = @()
                if ($P['Apps']) { foreach ($x in ([string]$P['Apps'] -split ';')) { $t = $x.Trim().Trim('"'); if ($t) { $apps += $t } } }
                Invoke-GuiReadyPipeline -AppPaths $apps -SkipReboot | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'pipeline-resume'; Group = '一键流程'; Name = '续跑未完成的流程'
            Desc = '读取状态文件，从上次中断的步骤继续。重启后也可以用它手动接着跑。'
            Params = @(); DryRun = $false
            Script = { param($P) Resume-GuiReadyPipeline | Out-Null }
        }
        [pscustomobject]@{
            Id = 'pipeline-status'; Group = '一键流程'; Name = '查看流程状态'
            Desc = '显示每个步骤的状态、重启次数、是否已注册开机续跑任务。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyPipelineState | Out-Null }
        }
        [pscustomobject]@{
            Id = 'pipeline-stop'; Group = '一键流程'; Name = '终止流程（清状态 + 注销续跑任务）'
            Desc = '清掉状态文件并注销 GuiReadyPipelineResume 计划任务，不会再自动续跑。'
            Params = @(); DryRun = $true
            Script = { param($P) Stop-GuiReadyPipeline }
        }

        # ---------------- 探测与诊断 ----------------
        [pscustomobject]@{
            Id = 'detect'; Group = '探测与诊断'; Name = '环境探测（只读）'
            Desc = '读取系统版本/SKU、FOD 状态、GUI 相关模块、RDP、关键服务、.NET、UAC、登录会话、自动登录，并给出结论与可用路线。'
            Params = @(); DryRun = $false
            Script = { param($P) Invoke-GuiReadyDetect | Out-Null }
        }
        [pscustomobject]@{
            Id = 'matrix'; Group = '探测与诊断'; Name = '版本适配矩阵与能力差距'
            Desc = '按当前 build 给出该版本的专属结论（FOD 离线源规则、FOD 提供/不提供什么），并把“缺哪个组件 → 哪类功能不可用”逐条列清。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $d = Invoke-GuiReadyDetect -Quiet
                Show-GuiReadyMatrix -Static $d.Static -DllScan $d.DllScan -Services $d.Services -Sessions $d.Sessions -Uac $d.Uac | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'pecheck'; Group = '探测与诊断'; Name = 'exe 兼容性预检'
            Desc = '静态解析 PE：架构、子系统、.NET、类型标签（Electron/WPF/WinForms/UWP），并检查导入模块在本机能否解析。可填文件或目录。'
            Params = @(
                @{ Name = 'Path'; Label = 'exe 路径或目录'; Type = 'Text'; Width = 520; Browse = 'Any' }
            )
            DryRun = $false
            Script = { param($P) Invoke-GuiReadyPeCheck -Path $P['Path'] | Out-Null }
        }
        [pscustomobject]@{
            Id = 'guitest'; Group = '探测与诊断'; Name = 'GUI 能力自检（真的建窗 + 抓图取证）'
            Desc = '在本机交互会话里实际创建 WinForms/WPF 窗口，可选启动记事本/MMC/性能监视器，并抓图做像素统计，给出“GUI 可用/不可用”的结论。'
            Params = @(
                @{ Name = 'IncludeApps'; Label = '同时启动真实程序（记事本 / MMC / 性能监视器）'; Type = 'Check'; Default = $true }
            )
            DryRun = $false
            Script = {
                param($P)
                $inc = $false
                if ($P['IncludeApps']) { $inc = [bool]$P['IncludeApps'] }
                Start-GuiReadyGuiSelfTest -IncludeApps:$inc | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'diag'; Group = '探测与诊断'; Name = '启动并诊断（程序起不来时用）'
            Desc = '启动目标程序并观察：首窗口耗时、是否闪退；同时采集事件日志、WER 崩溃报告、缺失依赖、退出码，推断最可能的原因并给建议。'
            Params = @(
                @{ Name = 'Path';      Label = '程序 exe 路径'; Type = 'Text'; Width = 520; Browse = 'File' }
                @{ Name = 'Arguments'; Label = '启动参数（可空）'; Type = 'Text'; Width = 520 }
                @{ Name = 'Launch';    Label = '启动方式'; Type = 'Combo'; Options = @('只采集诊断（不启动）', '启动并诊断（CreateProcess，不走 UAC）', '启动并诊断（ShellExecute，会走 UAC）'); Default = 1 }
            )
            DryRun = $false
            Script = {
                param($P)
                $mode = 1
                if ($P['Launch']) { $mode = [int]$P['Launch'] }
                switch ($mode) {
                    1 {
                        $d = Get-GuiReadyAppDiagnostics -ExePath $P['Path'] -Minutes 60
                        Write-Head '诊断结论'
                        if ($d.Findings.Count -gt 0) { foreach ($f in $d.Findings) { Write-Log ('可能原因: ' + $f.Cause) 'WARN'; Write-Log ('建议    : ' + $f.Advice) 'INFO' } }
                        else { Write-Log '未发现异常特征。' 'OK' }
                    }
                    2 { Invoke-GuiReadyLaunchAndDiagnose -ExePath $P['Path'] -Arguments $P['Arguments'] | Out-Null }
                    3 { Invoke-GuiReadyLaunchAndDiagnose -ExePath $P['Path'] -Arguments $P['Arguments'] -UseShellExecute | Out-Null }
                    default { Write-Log '无效的启动方式。' 'ERROR' }
                }
            }
        }

        # ---------------- 程序档案 ----------------
        [pscustomobject]@{
            Id = 'catalog-query'; Group = '程序档案'; Name = '查询某个程序的兼容档案'
            Desc = '按 exe 匹配内置档案，给出类型、结论、推荐启动参数与实测证据。'
            Params = @( @{ Name = 'Path'; Label = '程序 exe 路径'; Type = 'Text'; Width = 520; Browse = 'File' } )
            DryRun = $false
            Script = { param($P) Show-GuiReadyCatalogEntry -ExePath $P['Path'] | Out-Null }
        }
        [pscustomobject]@{
            Id = 'catalog-list'; Group = '程序档案'; Name = '列出全部档案条目'
            Desc = '列出内置 + 你自己的档案条目，含匹配规则与结论。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyCatalogList | Out-Null }
        }
        [pscustomobject]@{
            Id = 'catalog-add'; Group = '程序档案'; Name = '添加你自己的档案条目'
            Desc = '把你自己实测的结论记下来，以后自动命中（写入 lib\catalog.user.json，优先级高于内置档案）。'
            Params = @(
                @{ Name = 'Id';        Label = '条目 id（英文短名，如 myapp）'; Type = 'Text'; Width = 260 }
                @{ Name = 'Name';      Label = '显示名称'; Type = 'Text'; Width = 420 }
                @{ Name = 'Pattern';   Label = '匹配进程名正则（如 ^MyApp$）'; Type = 'Text'; Width = 300 }
                @{ Name = 'Verdict';   Label = '结论'; Type = 'Combo'; Options = @('可用', '可用（建议参数）', '不支持', '未知'); Default = 1 }
                @{ Name = 'LaunchArgs'; Label = '推荐启动参数（可空）'; Type = 'Text'; Width = 420 }
                @{ Name = 'Notes';     Label = '备注（可空）'; Type = 'Text'; Width = 520 }
                @{ Name = 'Evidence';  Label = '实测证据（可空）'; Type = 'Text'; Width = 520 }
            )
            DryRun = $false
            Script = {
                param($P)
                $vs = @('可用', '可用（建议参数）', '不支持', '未知')
                $v = '未知'
                if ($P['Verdict']) { $i = [int]$P['Verdict']; if ($i -ge 1 -and $i -le $vs.Count) { $v = $vs[$i - 1] } }
                $vo = (Get-GuiReadyStatic).Build
                Add-GuiReadyCatalogEntry -Id $P['Id'] -Name $P['Name'] -ExeNamePattern $P['Pattern'] -Verdict $v `
                    -LaunchArgs $P['LaunchArgs'] -Notes $P['Notes'] -Evidence $P['Evidence'] -VerifiedOn $vo | Out-Null
            }
        }

        # ---------------- 补给 ----------------
        [pscustomobject]@{
            Id = 'fod'; Group = '补给'; Name = '安装 App Compatibility FOD（官方路线）'
            Desc = '官方支持的方式，补齐 MMC/事件查看器/磁盘管理/explorer 等图形组件。装完必须重启才生效。在线安装较慢（20-40 分钟）且可能超时，重试有效。'
            Params = @(
                @{ Name = 'Mode';   Label = '安装方式'; Type = 'Combo'; Options = @('在线（Windows Update）', '离线（ISO 或目录）'); Default = 1 }
                @{ Name = 'Source'; Label = '离线源路径（选离线时填）'; Type = 'Text'; Width = 520; Browse = 'Any' }
            )
            DryRun = $true
            Script = {
                param($P)
                $dry = [bool]$P['DryRun']
                $mode = 1
                if ($P['Mode']) { $mode = [int]$P['Mode'] }
                if ($mode -eq 1) { Install-GuiReadyFod -WhatIf:$dry | Out-Null }
                else { Install-GuiReadyFod -SourcePath $P['Source'] -WhatIf:$dry | Out-Null }
            }
        }
        [pscustomobject]@{
            Id = 'dotnet'; Group = '补给'; Name = '按程序需求补齐 .NET 运行时'
            Desc = '从 exe 内嵌的 runtimeconfig 识别它需要哪个 .NET 框架，再用官方 zip 免安装部署到 C:\Program Files\dotnet（避开 MSI 在远程令牌下的失败）。'
            Params = @( @{ Name = 'Path'; Label = '程序 exe 路径'; Type = 'Text'; Width = 520; Browse = 'File' } )
            DryRun = $true
            Script = { param($P) Invoke-GuiReadyDotNetFix -ExePath $P['Path'] -WhatIf:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'guishell'; Group = '补给'; Name = '用安装介质补全 Server-Gui-Shell（非官方，高风险）'
            Desc = '需要一个与本机 build 一致的 install.wim/esd。注意：真正的 Server Core SKU 功能列表里没有 Server-Gui-Shell，本操作通常会直接判定不可行。'
            Params = @( @{ Name = 'Wim'; Label = 'install.wim / install.esd 路径'; Type = 'Text'; Width = 520; Browse = 'Any' } )
            DryRun = $true
            Script = {
                param($P)
                if ([bool]$P['DryRun']) { Install-GuiReadyGuiShell -WimPath $P['Wim'] -WhatIf | Out-Null }
                else { Install-GuiReadyGuiShell -WimPath $P['Wim'] -Confirm | Out-Null }
            }
        }
        [pscustomobject]@{
            Id = 'guishell-rollback'; Group = '补给'; Name = '回滚 Server-Gui-Shell'
            Desc = '卸载之前注入的包并恢复 Winlogon Shell。'
            Params = @(); DryRun = $true
            Script = {
                param($P)
                if ([bool]$P['DryRun']) { Uninstall-GuiReadyGuiShell -WhatIf | Out-Null }
                else { Uninstall-GuiReadyGuiShell -Confirm | Out-Null }
            }
        }

        # ---------------- 会话与登录 ----------------
        [pscustomobject]@{
            Id = 'session-status'; Group = '会话与登录'; Name = '查看 RDP / 会话 / UAC / .NET 状态'
            Desc = '一次看全会话列表、UAC 是否会拦提权、已装 .NET 框架、RDP 监听情况。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyRdpStatus }
        }
        [pscustomobject]@{
            Id = 'rdp-fix'; Group = '会话与登录'; Name = '远程会话一键修复'
            Desc = '启用 RDP、关闭 WDDM 强制驱动（解决远程会话黑屏）。执行会断开当前 RDP 连接。'
            Params = @(); DryRun = $true
            Script = {
                param($P)
                if ([bool]$P['DryRun']) { Invoke-GuiReadyRdpQuickFix -WhatIf } else { Invoke-GuiReadyRdpQuickFix }
            }
        }
        [pscustomobject]@{
            Id = 'autologon-status'; Group = '会话与登录'; Name = '开机自动登录：查看状态'
            Desc = '看是否启用了自动登录、密码存在哪里（LSA 机密 / 注册表明文）、AutoLogonCount 是否会把它弄失效。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyAutoLogonStatus | Out-Null }
        }
        [pscustomobject]@{
            Id = 'autologon-enable'; Group = '会话与登录'; Name = '开机自动登录：启用'
            Desc = '重启后自动登录指定账户，从而自动建立用户会话（无头场景下 GUI 程序才有地方显示，阶段 B 的 WTSQueryUserToken 也才有令牌）。默认用 LSA 机密存密码，不写注册表明文。'
            Params = @(
                @{ Name = 'User';     Label = '要自动登录的账户名'; Type = 'Text'; Width = 260 }
                @{ Name = 'Domain';   Label = '域 / 计算机名（空=本机名）'; Type = 'Text'; Width = 260 }
                @{ Name = 'Password'; Label = '密码'; Type = 'Password'; Width = 260 }
                @{ Name = 'Count';    Label = '自动登录次数（0=每次都自动登录）'; Type = 'Text'; Width = 220; Default = '0' }
                @{ Name = 'Method';   Label = '密码存储方式'; Type = 'Combo'; Options = @('LSA 机密（推荐，不写注册表明文）', '注册表明文（KB324737 方式，可被远程读取）'); Default = 1 }
            )
            DryRun = $true
            Script = {
                param($P)
                $plain = $false
                if ($P['Method'] -and [int]$P['Method'] -eq 2) { $plain = $true }
                $cnt = 0
                if ($P['Count']) { [void][int]::TryParse([string]$P['Count'], [ref]$cnt) }
                $dom = [string]$P['Domain']
                if ([string]::IsNullOrWhiteSpace($dom)) { $dom = $env:COMPUTERNAME }
                Set-GuiReadyAutoLogon -User $P['User'] -Password ([string]$P['Password']) -Domain $dom `
                    -AutoLogonCount $cnt -UseRegistryPlaintext:$plain -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'autologon-disable'; Group = '会话与登录'; Name = '开机自动登录：关闭'
            Desc = '设置 AutoAdminLogon=0，删除注册表里的 DefaultPassword 与 AutoLogonCount，并删除 LSA 机密。'
            Params = @(); DryRun = $true
            Script = {
                param($P)
                if ([bool]$P['DryRun']) { Disable-GuiReadyAutoLogon -WhatIf | Out-Null } else { Disable-GuiReadyAutoLogon | Out-Null }
            }
        }
        [pscustomobject]@{
            Id = 'command-status'; Group = '会话与登录'; Name = '一行命令：查看状态'
            Desc = '看 scm 这类命令是否已装、装在哪个 PATH 目录里。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyCommandStatus | Out-Null }
        }
        [pscustomobject]@{
            Id = 'command-install'; Group = '会话与登录'; Name = '一行命令：安装'
            Desc = '把一个命令文件放进 PATH 目录，之后在任意目录输入这个命令就能打开本工具（原理与 sconfig 相同，命令会自己提权）。'
            Params = @( @{ Name = 'Name'; Label = '命令名'; Type = 'Text'; Width = 220; Default = 'scm' } )
            DryRun = $true
            Script = { param($P) Install-GuiReadyCommand -Name $P['Name'] -WhatIf:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'command-uninstall'; Group = '会话与登录'; Name = '一行命令：卸载'
            Desc = '只删除本工具装的命令文件；如果同名文件不是本工具装的，会拒绝删除。'
            Params = @( @{ Name = 'Name'; Label = '命令名'; Type = 'Text'; Width = 220; Default = 'scm' } )
            DryRun = $true
            Script = { param($P) Uninstall-GuiReadyCommand -Name $P['Name'] -WhatIf:([bool]$P['DryRun']) | Out-Null }
        }

        # ---------------- 使用与工具 ----------------
        [pscustomobject]@{
            Id = 'persistent-run'; Group = '使用与工具'; Name = '持久化启动程序（计划任务）'
            Desc = '用 SYSTEM 计划任务启动程序，这样进程不会随远程会话断开而被杀掉。守护进程/服务类程序用这个。'
            Params = @(
                @{ Name = 'Path';    Label = '程序 exe 路径'; Type = 'Text'; Width = 520; Browse = 'File' }
                @{ Name = 'Name';    Label = '任务名称（空=用文件名）'; Type = 'Text'; Width = 300 }
                @{ Name = 'Args';    Label = '启动参数（空=用档案推荐参数）'; Type = 'Text'; Width = 520 }
                @{ Name = 'WorkDir'; Label = '工作目录（可空）'; Type = 'Text'; Width = 420; Browse = 'Folder' }
                @{ Name = 'AtStartup'; Label = '同时设为开机自启'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                $n = [string]$P['Name']
                if ([string]::IsNullOrWhiteSpace($n)) { $n = [System.IO.Path]::GetFileNameWithoutExtension([string]$P['Path']) }
                $a = [string]$P['Args']
                if ([string]::IsNullOrWhiteSpace($a)) { $a = Get-GuiReadyCatalogLaunchArgs -ExePath ([string]$P['Path']) }
                Start-GuiReadyPersistentProcess -Name $n -ExePath $P['Path'] -Arguments $a -WorkingDirectory $P['WorkDir'] -AtStartup:([bool]$P['AtStartup']) -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'launcher'; Group = '使用与工具'; Name = '启动图形启动器（旧版小面板）'
            Desc = '一个轻量的 WinForms 面板：系统工具按钮 + 我的程序列表（支持启动参数、持久化启动）。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $lp = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'launcher\Start-Launcher.ps1'
                Write-Log '该操作需要在桌面会话里直接打开，请用“使用与工具 → 打开启动器”按钮。' 'WARN'
            }
        }
        [pscustomobject]@{
            Id = 'phase-b'; Group = '使用与工具'; Name = '阶段 B（IDD 远程渲染）准备指引'
            Desc = '显示阶段 B 的必要条件、推荐的开源基线、以及参考文档里的 4 处 API 用法错误。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyPhaseBGuide }
        }

        # ---------------- Windows Admin Center ----------------
        [pscustomobject]@{
            Id = 'wac-status'; Group = 'Windows Admin Center'; Name = '状态检查与访问地址'
            Desc = '检查 WAC 是否安装、版本、服务、端口、证书、防火墙与连通性，并给出浏览器访问地址。注意入口是 /shell/，登录页返回 403 是正常现象。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyWacStatus | Out-Null }
        }
        [pscustomobject]@{
            Id = 'wac-install'; Group = 'Windows Admin Center'; Name = '一键安装并自动配置'
            Desc = '自动识别安装包类型（经典 MSI 用 msiexec+SME_ 参数；v2 用 Inno 的 /VERYSILENT），装完自动配防火墙、设服务自启并验证 /shell/ 可达。本地没有安装包时会从官方地址自动下载。安装会重启 WinRM，所以通过 SYSTEM 计划任务执行。'
            Params = @(
                @{ Name = 'InstallerPath'; Label = '安装包路径（留空则自动找，找不到就自动下载）'; Type = 'Text'; Width = 480; Browse = 'Any' }
                @{ Name = 'Port';          Label = '端口（v2 快速设置固定 443）'; Type = 'Text'; Width = 120; Default = '443' }
                @{ Name = 'Force';         Label = '已安装时也强制覆盖安装'; Type = 'Check'; Default = $false }
                @{ Name = 'NoDownload';    Label = '不自动下载（离线 / 内网环境用）'; Type = 'Check'; Default = $false }
                @{ Name = 'SkipFirewall';  Label = '跳过防火墙配置'; Type = 'Check'; Default = $false }
                @{ Name = 'NoAutoStart';   Label = '不设为自动启动'; Type = 'Check'; Default = $false }
                @{ Name = 'SkipVerify';    Label = '跳过安装后验证'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                $port = 443
                if ($P['Port']) { [void][int]::TryParse([string]$P['Port'], [ref]$port) }
                $path = ''
                if ($P['InstallerPath']) { $path = ([string]$P['InstallerPath']).Trim().Trim('"') }
                Install-GuiReadyWac -InstallerPath $path -Port $port `
                    -Force:([bool]$P['Force']) -NoDownload:([bool]$P['NoDownload']) `
                    -SkipFirewall:([bool]$P['SkipFirewall']) `
                    -NoAutoStart:([bool]$P['NoAutoStart']) -SkipVerify:([bool]$P['SkipVerify']) `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'wac-service'; Group = 'Windows Admin Center'; Name = '服务控制（启动 / 停止 / 重启 / 设为自启）'
            Desc = '控制 WindowsAdminCenter 服务。服务停止后 Web 界面即不可访问。'
            Params = @(
                @{ Name = 'Action'; Label = '操作'; Type = 'Combo'; Options = @('重启服务', '启动服务', '停止服务', '设为自动启动'); Default = 1 }
            )
            DryRun = $false
            Script = {
                param($P)
                $map = @('Restart', 'Start', 'Stop', 'Auto')
                $i = 1
                if ($P['Action']) { $i = [int]$P['Action'] }
                if ($i -lt 1 -or $i -gt $map.Count) { $i = 1 }
                [void](Set-GuiReadyWacService -Action $map[$i - 1])
            }
        }
        [pscustomobject]@{
            Id = 'wac-open'; Group = 'Windows Admin Center'; Name = '打开 WAC 界面'
            Desc = '在本机浏览器打开 WAC。Server Core 没有浏览器时会列出可用访问地址。'
            Params = @( @{ Name = 'Url'; Label = '访问地址（留空用本机默认）'; Type = 'Text'; Width = 420 } )
            DryRun = $false
            Script = { param($P) [void](Open-GuiReadyWacUi -Url ([string]$P['Url'])) }
        }
    )
}

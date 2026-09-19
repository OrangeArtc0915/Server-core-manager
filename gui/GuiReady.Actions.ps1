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

        # ---------------- 探测与诊断 ----------------
        [pscustomobject]@{
            Id = 'detect'; Group = '探测与诊断'; Name = '环境探测（只读）'
            Desc = '读取系统版本/SKU、FOD 状态、GUI 相关模块、RDP、关键服务、.NET、UAC、登录会话、自动登录，并给出结论与可用路线。'
            Params = @(); DryRun = $false
            Script = { param($P) Invoke-GuiReadyDetect | Out-Null }
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
        # ---------------- 终端美化 ----------------
        [pscustomobject]@{
            Id = 'console-status'; Group = '终端美化'; Name = '终端美化：状态检查'
            Desc = '检查 Nerd Font（MesloLGS NF）是否安装、是否进了控制台字体白名单、中文回退是否配置、oh-my-posh / fastfetch / 启动器 / profile 初始化是否就位、控制台是否开了 ANSI(VT) 与配色。'
            Params = @(
                @{ Name = 'DeepProbe'; Label = '同时实测：用 scm-term 新开控制台并回读真实字体'; Type = 'Check'; Default = $true }
            )
            DryRun = $false
            Script = {
                param($P)
                $dp = $false
                if ($P['DeepProbe']) { $dp = [bool]$P['DeepProbe'] }
                Show-GuiReadyConsoleStatus -DeepProbe:$dp | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'console-install'; Group = '终端美化'; Name = '一键美化终端（Nerd Font + Oh My Posh + Fastfetch）'
            Desc = '装 MesloLGS NF（全机：字体文件 + 控制台白名单 + 中文回退到雅黑）、oh-my-posh（写 PowerShell profile）、fastfetch（首屏信息）、One Dark 配色并打开 ANSI/VT，最后生成 scm-term 启动器并实测。素材随发布包内置，不联网。注意：中文代码页 936 下 conhost 不接受拉丁 Nerd Font，所以美化终端要用 scm-term 打开（它会先切 UTF-8）。'
            Params = @(
                @{ Name = 'AssetDir';   Label = '素材目录（留空用 setup\console\）'; Type = 'Text'; Width = 480; Browse = 'Folder' }
                @{ Name = 'Theme';      Label = 'oh-my-posh 主题'; Type = 'Combo'; Options = @('默认（One Dark 自带）', '1_shell', 'atomic', 'catppuccin_frappe', 'dracula', 'emodipt-extend', 'zash') }
                @{ Name = 'SkipPosh';      Label = '不安装 oh-my-posh（不写 profile）'; Type = 'Check'; Default = $false }
                @{ Name = 'SkipFastfetch'; Label = '不安装 fastfetch'; Type = 'Check'; Default = $false }
                @{ Name = 'SkipAppearance'; Label = '不改控制台配色/字体等外观设置'; Type = 'Check'; Default = $false }
                @{ Name = 'SkipProbe';     Label = '跳过装完的实测'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                # 主题下拉是 1 基索引：1=默认主题，2..7 对应 setup\console\themes 里的内置主题
                $themeNames = @('', '1_shell', 'atomic', 'catppuccin_frappe', 'dracula', 'emodipt-extend', 'zash')
                $ti = [int]$P['Theme']
                $theme = ''
                if ($ti -ge 2 -and $ti -le $themeNames.Count) { $theme = $themeNames[$ti - 1] }
                Install-GuiReadyConsoleTheme -AssetDir ([string]$P['AssetDir']) -Theme $theme `
                    -SkipPosh:([bool]$P['SkipPosh']) -SkipFastfetch:([bool]$P['SkipFastfetch']) `
                    -SkipAppearance:([bool]$P['SkipAppearance']) -SkipProbe:([bool]$P['SkipProbe']) `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'console-open'; Group = '终端美化'; Name = '终端美化：打开美化终端'
            Desc = '打开一个 UTF-8 + Nerd Font + oh-my-posh 的控制台（等价于在命令行输入 scm-term）。'
            Params = @(); DryRun = $false
            Script = { param($P) Start-GuiReadyConsoleTheme | Out-Null }
        }
        [pscustomobject]@{
            Id = 'console-restore'; Group = '终端美化'; Name = '终端美化：一键还原'
            Desc = '把控制台外观恢复为安装前的备份值、移除 profile 里的初始化块、删掉字体与控制台白名单/中文回退项、清理 bin 与 PATH 里的 scm-term。'
            Params = @(
                @{ Name = 'KeepFonts'; Label = '保留字体（不卸载）'; Type = 'Check'; Default = $false }
                @{ Name = 'KeepFiles'; Label = '保留 bin 里的程序与脚本'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Restore-GuiReadyConsoleTheme -KeepFonts:([bool]$P['KeepFonts']) -KeepFiles:([bool]$P['KeepFiles']) `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'console-ps7'; Group = '终端美化'; Name = '安装 PowerShell 7（zip 免安装，国内源优先）'
            Desc = '从清华 TUNA 镜像取 PowerShell 7 的 win-x64 zip（拿不到时自动回退 GitHub 官方），解压到 C:\Program Files\PowerShell\7 并加入系统 PATH，同时给 PowerShell 5.1 / 7 都写 oh-my-posh 初始化。也可以指定本地 zip 或自建源地址。'
            Params = @(
                @{ Name = 'Url';     Label = '指定下载链接（留空=清华镜像取最新；内网源也行）'; Type = 'Text'; Width = 520 }
                @{ Name = 'ZipPath'; Label = '指定本地 zip（留空=联网下载）'; Type = 'Text'; Width = 420; Browse = 'File' }
                @{ Name = 'SkipProfile'; Label = '不写 oh-my-posh 初始化'; Type = 'Check'; Default = $false }
                @{ Name = 'SkipPath';    Label = '不改系统 PATH'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Install-GuiReadyPowerShell7 -Url ([string]$P['Url']) -ZipPath ([string]$P['ZipPath']) `
                    -SkipProfile:([bool]$P['SkipProfile']) -SkipPath:([bool]$P['SkipPath']) `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
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
            Id = 'login-shell'; Group = '会话与登录'; Name = '设置登录 Shell（cmd / 自动进 sconfig / 恢复原值）'
            Desc = '改 Winlogon 的 Shell 值。cmd.exe = 登录后是命令行；自动进 sconfig = 登录后直接进 Server Core 配置菜单（Server Core 原生行为，靠 servercoreshelllaunch.bat 拉起）。写入前会自动备份（backup\shell-*，reg export），可用「恢复原值」回退。注意：Server Core 上把 Shell 设成 explorer.exe 会导致从 sconfig 选“退出到命令行”之后黑屏/什么都没有。'
            Params = @(
                @{ Name = 'Mode'; Label = '登录 Shell'; Type = 'Combo'; Options = @('自动进 sconfig（Server Core 原生）', 'cmd.exe（登录后命令行）', '恢复原值（从备份导入）', '启动器（旧版小面板）', 'explorer.exe（仅带桌面体验的系统）') }
            )
            DryRun = $true
            Script = {
                param($P)
                # 下拉是 1 基索引
                $modes = @('SConfig', 'Cmd', 'Restore', 'Launcher', 'Explorer')
                $i = [int]$P['Mode']
                if ($i -lt 1 -or $i -gt $modes.Count) { $i = 1 }
                Set-GuiReadyShell -Mode $modes[$i - 1] -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
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

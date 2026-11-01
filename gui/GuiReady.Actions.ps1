# GuiReady actions: single source of truth shared by the GUI and the headless runner.
# Each action runs with a hashtable of parameters: the GUI builds it, the runner passes it in.
# Script blocks take param($P) so lookups are explicit and scope-safe.

function Get-GuiReadyActions {
    return Set-GuiReadyActionRequirements -Actions @(
        # ---------------- 一键流程 ----------------
        [pscustomobject]@{
            Id    = 'pipeline-auto'
            Group = '一键流程'
            Name  = '一键就绪（按需装 FOD + 自动重启 + 续跑）'
            Desc  = '探测 → 按需装 App Compatibility FOD → 自动重启 → 重启后自动续跑 → 复核 → 补 .NET → 查档案 → 诊断 → 汇总。全程无需干预（GUI 自检默认跳过，需要时在参数里勾选）。'
            Params = @(
                @{ Name = 'Apps'; Label = '关注程序路径（可空，多个用分号分隔）'; Type = 'Text'; Width = 520 }
                @{ Name = 'GuiTest'; Label = '包含 GUI 能力自检（会建窗口、明显更慢）'; Type = 'Check'; Default = $false }
            )
            DryRun = $false
            Script = {
                param($P)
                $apps = @()
                if ($P['Apps']) { foreach ($x in ([string]$P['Apps'] -split ';')) { $t = $x.Trim().Trim('"'); if ($t) { $apps += $t } } }
                Invoke-GuiReadyPipeline -AppPaths $apps -AutoReboot -SkipGuiTest:(-not [bool]$P['GuiTest']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id    = 'pipeline-noReboot'
            Group = '一键流程'
            Name  = '一键就绪（需要重启时暂停，不自动重启）'
            Desc  = '与上面相同，但遇到需要重启的步骤会停下来，等你自己重启后到本页点“续跑”（GUI 自检默认跳过）。'
            Params = @(
                @{ Name = 'Apps'; Label = '关注程序路径（可空，多个用分号分隔）'; Type = 'Text'; Width = 520 }
                @{ Name = 'GuiTest'; Label = '包含 GUI 能力自检（会建窗口、明显更慢）'; Type = 'Check'; Default = $false }
            )
            DryRun = $false
            Script = {
                param($P)
                $apps = @()
                if ($P['Apps']) { foreach ($x in ([string]$P['Apps'] -split ';')) { $t = $x.Trim().Trim('"'); if ($t) { $apps += $t } } }
                Invoke-GuiReadyPipeline -AppPaths $apps -SkipReboot -SkipGuiTest:(-not [bool]$P['GuiTest']) | Out-Null
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
        [pscustomobject]@{
            Id = 'dll-patch'; Group = '补给'; Name = '补齐桌面体验 DLL（twinui / themeui / themeservice）'
            Desc = '装了 App Compatibility FOD 后仍可能缺这几个桌面组件。从发布包内置的同版本 DLL 复制到 System32（版本必须与系统一致），已有文件会先备份；主题/XAML 组件需重启或注销后生效。'
            Params = @()
            DryRun = $true
            Script = { param($P) Install-GuiReadyDesktopDlls -WhatIf:([bool]$P['DryRun']) | Out-Null }
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
            Desc = '装 MesloLGS NF（全机：字体文件 + 控制台白名单 + 中文回退到雅黑）、oh-my-posh（写 PowerShell profile）、fastfetch（首屏信息）、One Dark 配色并打开 ANSI/VT，最后生成 scm-term 启动器并实测。发布包不内置第三方程序与字体：缺什么会从 GitHub / Nerd Fonts 官方源下载（离线环境可勾「不联网下载」并自行放入 setup\console）。注意：中文代码页 936 下 conhost 不接受拉丁 Nerd Font，所以美化终端要用 scm-term 打开（它会先切 UTF-8）。'
            Params = @(
                @{ Name = 'AssetDir';   Label = '素材目录（留空用 setup\console\）'; Type = 'Text'; Width = 480; Browse = 'Folder' }
                @{ Name = 'Theme';      Label = 'oh-my-posh 主题'; Type = 'Combo'; Options = @('默认（One Dark 自带）', '1_shell', 'atomic', 'catppuccin_frappe', 'dracula', 'emodipt-extend', 'zash') }
                @{ Name = 'NoDownload'; Label = '不联网下载素材（离线环境，自行放入 setup\console）'; Type = 'Check'; Default = $false }
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
                    -NoDownload:([bool]$P['NoDownload']) `
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

        # ---------------- 应用商店 ----------------
        [pscustomobject]@{
            Id = 'pkg-source-status'; Group = '应用商店'; Name = '包管理器状态（只读）'
            Desc = '检测本机有哪些包管理器（Chocolatey / Scoop / npm / pip）、版本、路径，以及我们支持到哪一步。目前搜索只接了 Chocolatey。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyPackageSourceStatus | Out-Null }
        }
        [pscustomobject]@{
            Id = 'pkg-install-choco'; Group = '应用商店'; Name = '安装 Chocolatey（包管理器本体）'
            Desc = '下载官方安装脚本并执行（先落盘再运行，不用 iex，出问题有文件可查），装到 C:\ProgramData\chocolatey。需要管理员权限与联网；内网环境可以在参数里把地址换成内网副本。安全限制：默认只接受 https（这条链会以管理员身份执行下载到的内容），下载后还会检查内容像不像 PowerShell 脚本。'
            Params = @(
                @{ Name = 'Url'; Label = '安装脚本地址（留空=官方 community.chocolatey.org）'; Type = 'Text'; Width = 520 }
                @{ Name = 'AllowInsecure'; Label = '允许非 https 地址（内网确实只有 http 时才勾）'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Install-GuiReadyPackageManager -Id 'choco' -Url ([string]$P['Url']) `
                    -AllowInsecure:([bool]$P['AllowInsecure']) -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'pkg-install'; Group = '应用商店'; Name = '安装软件包'
            Desc = '从包管理器安装软件包并把输出实时打进日志。Chocolatey 走 choco install -y --no-progress；Scoop 走 scoop install。拿不准就先按「仅预览」看要执行哪条命令。'
            Params = @(
                @{ Name = 'Source';  Label = '包管理器'; Type = 'Combo'; Options = @('Chocolatey', 'Scoop', 'npm'); Default = 1 }
                @{ Name = 'Package'; Label = '包名（如 7zip / git）'; Type = 'Text'; Width = 320 }
            )
            DryRun = $true
            Script = {
                param($P)
                $src = 'choco'
                if ([int]$P['Source'] -eq 2) { $src = 'scoop' }
                elseif ([int]$P['Source'] -eq 3) { $src = 'npm' }
                Install-GuiReadyPackage -Source $src -Package ([string]$P['Package']) -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'store-install'; Group = '应用商店'; Name = '安装精选应用（含前置检查）'
            Desc = '按商店精选库条目安装：先检查兼容性、FOD 与 Windows 功能依赖（例如 Docker Engine 需要 Containers），再调用对应的包管理器安装，最后验证命令是否可用。不在精选库里的包名会回退成裸 choco 安装。'
            Params = @( @{ Name = 'AppId'; Label = '应用 ID（catalog.json 的 id，如 docker-engine）'; Type = 'Text'; Width = 360 } )
            DryRun = $true
            Script = { param($P) Install-GuiReadyStoreApp -Id ([string]$P['AppId']) -WhatIf:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'store-queue'; Group = '应用商店'; Name = '批量安装所选应用（队列）'
            Desc = '把多个应用按顺序装完：单个失败不会中断后面的条目，结束后把失败清单写进 state\store-queue.json。界面的「重试失败」只重跑这些失败项。'
            Params = @( @{ Name = 'AppIds'; Label = '应用 ID（逗号分隔，如 7zip,git）'; Type = 'Text'; Width = 520 } )
            DryRun = $true
            Script = { param($P) Install-GuiReadyStoreQueue -Ids @([string]$P['AppIds']) -WhatIf:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'manifest-export'; Group = '应用商店'; Name = '导出已装软件清单'
            Desc = '用 choco export 把本机已装软件导出成 packages.config（含版本），默认写到 reports 目录。换机器时用「导入已装软件清单」一次还原。'
            Params = @( @{ Name = 'Path'; Label = '导出路径（留空 = reports\packages-时间.config）'; Type = 'Text'; Width = 520 } )
            DryRun = $false
            Script = { param($P) [void](Export-GuiReadyInstalledManifest -Path ([string]$P['Path'])) }
        }
        [pscustomobject]@{
            Id = 'manifest-import'; Group = '应用商店'; Name = '导入已装软件清单'
            Desc = '从 packages.config 还原软件（choco install <清单> -y）。依赖由 choco 自己处理；建议先按「仅预览」看要执行哪条命令。'
            Params = @( @{ Name = 'Path'; Label = 'packages.config 路径'; Type = 'Text'; Width = 520; Browse = 'File' } )
            DryRun = $true
            Script = { param($P) Import-GuiReadyInstalledManifest -Path ([string]$P['Path']) -WhatIf:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'pkg-info'; Group = '应用商店'; Name = '查看软件包详情（只读）'
            Desc = '等价于 choco info <包>：把标题/版本/发布时间/下载量/摘要/标签/官网/许可证/描述解析出来（解析规则按 Chocolatey 2.7.4 的实测输出写，见 lib\GuiReady.Package.ps1）。'
            Params = @( @{ Name = 'Package'; Label = '包名（如 7zip）'; Type = 'Text'; Width = 320 } )
            DryRun = $false
            Script = { param($P) Show-GuiReadyPackageInfo -Package ([string]$P['Package']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'pkg-uninstall'; Group = '应用商店'; Name = '卸载软件包'
            Desc = '从包管理器卸载软件包。Chocolatey 走 choco uninstall -y --no-progress；Scoop 走 scoop uninstall。'
            Params = @(
                @{ Name = 'Source';  Label = '包管理器'; Type = 'Combo'; Options = @('Chocolatey', 'Scoop', 'npm'); Default = 1 }
                @{ Name = 'Package'; Label = '包名'; Type = 'Text'; Width = 320 }
            )
            DryRun = $true
            Script = {
                param($P)
                $src = 'choco'
                if ([int]$P['Source'] -eq 2) { $src = 'scoop' }
                elseif ([int]$P['Source'] -eq 3) { $src = 'npm' }
                Uninstall-GuiReadyPackage -Source $src -Package ([string]$P['Package']) -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }

        # ---------------- 运行库 ----------------
        [pscustomobject]@{
            Id = 'runtime-status'; Group = '运行库'; Name = '运行库状态（只读）'
            Desc = '列出内置清单里的运行时（Node / Python / Go / Java / PHP / Bun）：已装版本、当前链接、是否在机器 PATH、以及本机探测到的版本。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $t = Get-GuiReadyRuntimeStatus | ForEach-Object { $_.Items } | Format-Table Name, Current, OnPath, Detected -AutoSize | Out-String
                Write-Log $t
            }
        }
        [pscustomobject]@{
            Id = 'runtime-install'; Group = '运行库'; Name = '安装运行时版本'
            Desc = '下载官方 zip（优先国内镜像）解压到 <工具目录>\runtimes\<语言>\<版本>；没有 current 时自动指向新版本，并把 PATH 条目补进机器 PATH。'
            Params = @(
                @{ Name = 'Lang';    Label = '运行时'; Type = 'Combo'; Options = @('Node.js', 'Python', 'Go', 'Java (Temurin)', 'PHP', 'Bun'); Default = 1 }
                @{ Name = 'Version'; Label = '版本（留空 = 清单里最新的）'; Type = 'Text'; Width = 240 }
            )
            DryRun = $true
            Script = {
                param($P)
                $ids = @('node', 'python', 'go', 'java', 'php', 'bun')
                $i = [int]$P['Lang']
                if ($i -lt 1 -or $i -gt $ids.Count) { $i = 1 }
                $id = $ids[$i - 1]
                $ver = [string]$P['Version']
                if (-not $ver) {
                    $e = Get-GuiReadyRuntimeEntry -Id $id
                    $ver = [string]@($e.Versions)[0].Version
                }
                Install-GuiReadyRuntime -Id $id -Version $ver -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'runtime-switch'; Group = '运行库'; Name = '切换当前版本'
            Desc = '把 <语言>\current 这个 junction 指向指定版本，并同步机器 PATH。已经开的进程不受影响，新开的命令行才生效。'
            Params = @(
                @{ Name = 'Lang';    Label = '运行时'; Type = 'Combo'; Options = @('Node.js', 'Python', 'Go', 'Java (Temurin)', 'PHP', 'Bun'); Default = 1 }
                @{ Name = 'Version'; Label = '版本（已装的）'; Type = 'Text'; Width = 240 }
            )
            DryRun = $false
            Script = {
                param($P)
                $ids = @('node', 'python', 'go', 'java', 'php', 'bun')
                $i = [int]$P['Lang']
                if ($i -lt 1 -or $i -gt $ids.Count) { $i = 1 }
                Set-GuiReadyRuntimeCurrent -Id $ids[$i - 1] -Version ([string]$P['Version']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'runtime-remove'; Group = '运行库'; Name = '卸载运行时版本'
            Desc = '删除指定版本目录；如果删的是当前版本会先摘掉 current，并把 current 改指向剩下的最新版本。'
            Params = @(
                @{ Name = 'Lang';    Label = '运行时'; Type = 'Combo'; Options = @('Node.js', 'Python', 'Go', 'Java (Temurin)', 'PHP', 'Bun'); Default = 1 }
                @{ Name = 'Version'; Label = '版本（留空 = 当前版本）'; Type = 'Text'; Width = 240 }
            )
            DryRun = $true
            Script = {
                param($P)
                $ids = @('node', 'python', 'go', 'java', 'php', 'bun')
                $i = [int]$P['Lang']
                if ($i -lt 1 -or $i -gt $ids.Count) { $i = 1 }
                Uninstall-GuiReadyRuntime -Id $ids[$i - 1] -Version ([string]$P['Version']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'runtime-path'; Group = '运行库'; Name = '修复运行库 PATH'
            Desc = '把机器 PATH 里所有指向 runtimes 目录的条目重算一遍：删掉失效的，按 current 链接补上应有的条目。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $t = Update-GuiReadyRuntimePath | Format-List Changed, Added, Removed, Error | Out-String
                Write-Log $t
            }
        }

        # ---------------- 数据库 ----------------
        [pscustomobject]@{
            Id = 'db-status'; Group = '数据库'; Name = '数据库状态（只读）'
            Desc = '列出内置的 PostgreSQL 版本、是否已解压、已初始化的实例（端口 / 服务状态 / 数据目录大小 / 备份数量）。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $st = Get-GuiReadyDatabaseStatus
                $t  = $st.Items | Where-Object { $_.Kind -eq 'version' } |
                      Format-Table Version, Installed, BinDir -AutoSize | Out-String
                $t += $st.Items | Where-Object { $_.Kind -eq 'instance' } |
                      Format-Table Id, Port, Service, ServiceState, Online, SizeMB, Backups -AutoSize | Out-String
                Write-Log $t
            }
        }
        [pscustomobject]@{
            Id = 'db-install'; Group = '数据库'; Name = '安装数据库（解压官方 zip）'
            Desc = '下载官方 Windows zip 并解压：PostgreSQL 走 EDB binaries（databases\postgresql\<版本>），MySQL 8 走 dev.mysql.com（databases\mysql\<版本>）。不跑安装器、不写注册表。'
            Params = @(
                @{ Name = 'Target'; Label = '数据库与版本'; Type = 'Combo'; Default = 1; Options = @(
                    'PostgreSQL 16.4-1', 'PostgreSQL 17.0-1', 'MySQL 8.4.3', 'MySQL 8.0.40') }
            )
            DryRun = $true
            Script = {
                param($P)
                $engines  = @('postgresql', 'postgresql', 'mysql', 'mysql')
                $versions = @('16.4-1', '17.0-1', '8.4.3', '8.0.40')
                $i = [int]$P['Target']
                if ($i -lt 1 -or $i -gt $versions.Count) { $i = 1 }
                Install-GuiReadyDatabaseEngine -Engine $engines[$i - 1] -Version $versions[$i - 1] -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'db-init'; Group = '数据库'; Name = '初始化数据库实例'
            Desc = 'PostgreSQL：initdb + SCRAM 密码 + NetworkService 授权。MySQL：--initialize-insecure，再临时起 mysqld 设置 root 密码（这一步不需要管理员）。密码都用 DPAPI 加密后存进实例记录。'
            Params = @(
                @{ Name = 'Target';   Label = '数据库与版本'; Type = 'Combo'; Default = 1; Options = @(
                    'PostgreSQL 16.4-1', 'PostgreSQL 17.0-1', 'MySQL 8.4.3', 'MySQL 8.0.40') }
                @{ Name = 'Port';     Label = '端口（留空 = 自动挑空闲端口）'; Type = 'Text'; Width = 120; Default = '' }
                @{ Name = 'Password'; Label = '管理员密码（至少 6 位）'; Type = 'Password'; Width = 240 }
            )
            DryRun = $true
            Script = {
                param($P)
                $engines  = @('postgresql', 'postgresql', 'mysql', 'mysql')
                $versions = @('16.4-1', '17.0-1', '8.4.3', '8.0.40')
                $i = [int]$P['Target']
                if ($i -lt 1 -or $i -gt $versions.Count) { $i = 1 }
                $port = 0
                if ($P['Port']) { $port = [int]$P['Port'] }
                Initialize-GuiReadyDatabaseInstance -Engine $engines[$i - 1] -Version $versions[$i - 1] `
                    -Port $port -Password ([string]$P['Password']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'db-service'; Group = '数据库'; Name = '数据库服务（注册 / 启停 / 注销）'
            Desc = 'PostgreSQL 用 pg_ctl register（账号 NetworkService），MySQL 用 mysqld --install（LocalSystem）；可启动 / 停止 / 重启 / 注销。注册与注销需要管理员。'
            Params = @(
                @{ Name = 'Id';     Label = '实例编号（在「数据库状态」里看，形如 pg-16.4-1-5432 / my-8.4.3-3306）'; Type = 'Text'; Width = 320 }
                @{ Name = 'Action'; Label = '操作'; Type = 'Combo'; Options = @('注册并启动', '只注册', '启动', '停止', '重启', '注销（保留数据）', '注销并删除数据'); Default = 1 }
            )
            DryRun = $true
            Script = {
                param($P)
                $acts = @('start', 'register', 'start', 'stop', 'restart', 'unregister', 'unregister')
                $i = [int]$P['Action']
                if ($i -lt 1 -or $i -gt $acts.Count) { $i = 1 }
                $id = [string]$P['Id']
                $dry = [bool]$P['DryRun']
                switch ($acts[$i - 1]) {
                    'start'      { Register-GuiReadyDatabaseService -Id $id -Start -DryRun:$dry | Out-Null }
                    'register'   { Register-GuiReadyDatabaseService -Id $id -DryRun:$dry | Out-Null }
                    'stop'       { Set-GuiReadyDbServiceState -Id $id -Action 'Stop' | Out-Null }
                    'restart'    { Set-GuiReadyDbServiceState -Id $id -Action 'Restart' | Out-Null }
                    'unregister' {
                        $rm = ($i -eq 7)
                        Unregister-GuiReadyDbService -Id $id -RemoveData:$rm -DryRun:$dry | Out-Null
                    }
                }
            }
        }
        [pscustomobject]@{
            Id = 'db-backup'; Group = '数据库'; Name = '备份数据库实例'
            Desc = 'PostgreSQL 用 pg_dump -Fc（backup\postgresql\*.dump），MySQL 用 mysqldump --single-transaction（backup\mysql\*.sql）。密码从实例记录里 DPAPI 解出，不出现在命令行。'
            Params = @(
                @{ Name = 'Id';       Label = '实例编号'; Type = 'Text'; Width = 320 }
                @{ Name = 'Database'; Label = '库名（留空 = 默认库：postgres / mysql）'; Type = 'Text'; Width = 240 }
            )
            DryRun = $true
            Script = {
                param($P)
                Backup-GuiReadyDatabase -Id ([string]$P['Id']) -Database ([string]$P['Database']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }

        [pscustomobject]@{
            Id = 'db-createdb'; Group = '数据库'; Name = '新建数据库（建库）'
            Desc = '在指定实例上建一个空库：PostgreSQL 走 createdb（UTF8 继承模板），MySQL 走 CREATE DATABASE ... utf8mb4。库名只允许字母 / 数字 / 下划线 / 短横线。'
            Params = @(
                @{ Name = 'Id';       Label = '实例编号'; Type = 'Text'; Width = 320 }
                @{ Name = 'Database'; Label = '新库名'; Type = 'Text'; Width = 240 }
            )
            DryRun = $true
            Script = {
                param($P)
                New-GuiReadyDatabase -Id ([string]$P['Id']) -Database ([string]$P['Database']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'db-restore'; Group = '数据库'; Name = '还原数据库（从备份文件）'
            Desc = 'PostgreSQL 用 pg_restore --clean --if-exists 还原 .dump；MySQL 用 mysql < .sql 导入。注意：会覆盖目标库里同名对象，生产库请先备份。'
            Params = @(
                @{ Name = 'Id';       Label = '实例编号'; Type = 'Text'; Width = 320 }
                @{ Name = 'File';     Label = '备份文件（.dump / .sql）'; Type = 'Text'; Width = 520; Browse = 'File' }
                @{ Name = 'Database'; Label = '目标库名（PostgreSQL 留空 = postgres；MySQL 留空 = 按备份里的库名）'; Type = 'Text'; Width = 320 }
            )
            DryRun = $true
            Script = {
                param($P)
                Restore-GuiReadyDatabase -Id ([string]$P['Id']) -File ([string]$P['File']) `
                    -Database ([string]$P['Database']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }

        # ---------------- 角色与功能 ----------------
        [pscustomobject]@{
            Id = 'role-status'; Group = '角色与功能'; Name = '角色/功能状态（只读）'
            Desc = '探测本机能不能管角色与功能（ServerManager / DISM / 管理员 / 系统类型），并在可用时列出已安装的角色与未安装的角色。客户端 Windows 上会说明「不适用」并指向按需功能。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyRoleStatus | Out-Null }
        }
        [pscustomobject]@{
            Id = 'role-install'; Group = '角色与功能'; Name = '安装角色/功能'
            Desc = '等价于 Install-WindowsFeature -Name <名称>。会先按 DependsOn 递归展开依赖、把未安装的依赖先装好（依赖自动补齐）；默认不包含管理工具 —— Server Core 上装了 MMC 管理单元也用不了，管理工具建议装在管理端的 RSAT 上。安装可能需要重启，是否需要会写进日志。'
            Params = @(
                @{ Name = 'Name';                 Label = '角色/功能名称（如 Web-Server / DNS / Hyper-V）'; Type = 'Text'; Width = 360 }
                @{ Name = 'WithManagementTools';  Label = '同时包含管理工具（-IncludeManagementTools）'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Install-GuiReadyRoleBatch -Name @([string]$P['Name']) -WithManagementTools:([bool]$P['WithManagementTools']) `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'role-batch-install'; Group = '角色与功能'; Name = '批量安装角色/功能（队列）'
            Desc = '多个角色/功能按「依赖在前」的顺序依次安装：依赖自动补齐，单个失败不中断后面的条目。'
            Params = @(
                @{ Name = 'Names';                Label = '角色/功能名称（逗号分隔，如 DNS,DHCP）'; Type = 'Text'; Width = 520 }
                @{ Name = 'WithManagementTools';  Label = '同时包含管理工具（-IncludeManagementTools）'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Install-GuiReadyRoleBatch -Name @([string]$P['Names']) -WithManagementTools:([bool]$P['WithManagementTools']) `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'role-remove'; Group = '角色与功能'; Name = '移除角色/功能'
            Desc = '等价于 Uninstall-WindowsFeature -Name <名称>（不带 -Restart，是否重启由你决定）。'
            Params = @(
                @{ Name = 'Name'; Label = '角色/功能名称'; Type = 'Text'; Width = 360 }
            )
            DryRun = $true
            Script = { param($P) Remove-GuiReadyRole -Name ([string]$P['Name']) -WhatIf:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'role-batch-remove'; Group = '角色与功能'; Name = '批量移除角色/功能'
            Desc = '多个角色/功能依次移除，单个失败不中断（被其它角色依赖时会失败，属于预期）。不带 -Restart。'
            Params = @(
                @{ Name = 'Names'; Label = '角色/功能名称（逗号分隔）'; Type = 'Text'; Width = 520 }
            )
            DryRun = $true
            Script = { param($P) Remove-GuiReadyRoleBatch -Name @([string]$P['Names']) -WhatIf:([bool]$P['DryRun']) | Out-Null }
        }

        # ---------------- 监控与诊断 ----------------
        [pscustomobject]@{
            Id = 'monitor-snapshot'; Group = '监控与诊断'; Name = '系统快照（只读）'
            Desc = '一次采集 CPU / 内存 / 磁盘 / 关键服务 / 占内存最多的进程 / 最近的系统错误与警告事件。全只读，不改系统。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyMonitorStatus | Out-Null }
        }
        [pscustomobject]@{
            Id = 'monitor-service'; Group = '监控与诊断'; Name = '服务控制（启动 / 停止 / 重启）'
            Desc = '控制单个 Windows 服务，做完会复核一次真实状态（Start-Service 返回不代表服务真起来了）。填的是服务名而不是显示名，例如 WinRM / LanmanServer / TermService。'
            Params = @(
                @{ Name = 'Name';   Label = '服务名（如 WinRM）'; Type = 'Text'; Width = 280 }
                @{ Name = 'Action'; Label = '操作'; Type = 'Combo'; Options = @('启动', '停止', '重启'); Default = 1 }
            )
            DryRun = $true
            Script = {
                param($P)
                $map = @('Start', 'Stop', 'Restart')
                $i = 1
                if ($P['Action']) { $i = [int]$P['Action'] }
                if ($i -lt 1 -or $i -gt $map.Count) { $i = 1 }
                # 必须把失败抛出去：以前这里 | Out-Null 丢掉返回值，服务没停/没起也照样
                # 显示"成功"，任务中心和审计里就成了一条假记录（网页提交同样受影响）。
                $ok = Invoke-GuiReadyServiceControl -Name ([string]$P['Name']) -Action $map[$i - 1] -WhatIf:([bool]$P['DryRun'])
                if (-not $ok) { throw ('服务控制失败：{0} / {1}' -f [string]$P['Name'], $map[$i - 1]) }
            }
        }

        # ---------------- 安全与合规 ----------------
        [pscustomobject]@{
            Id = 'security-audit'; Group = '安全与合规'; Name = '安全基线审计（只读）'
            Desc = '只做「能在本机直接验证」的 10 项：防火墙、Defender 实时保护、UAC、SMBv1、来宾账户、管理员组成员、网络共享、RDP 与 NLA、本地密码与锁定策略、最近 24 小时的登录失败。每项都带原始证据。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadySecurityAudit | Out-Null }
        }
        [pscustomobject]@{
            Id = 'selfcheck'; Group = '安全与合规'; Name = '本工具完整性自检（只读）'
            Desc = '检查本工具自身：安装目录是否只有管理员能写、文件是否与发布清单（manifest.sha256）一致、脚本签名是否有效。回答的是"我手上这份工具被人改过没有"。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyIntegrityReport | Out-Null }
        }
        [pscustomobject]@{
            Id = 'security-fix'; Group = '安全与合规'; Name = '安全基线一键修复（只修安全可逆的项）'
            Desc = '只处理白名单里的项：打开防火墙、打开 Defender 实时保护、关闭 SMBv1、禁用来宾账户、开启 RDP 的 NLA、收紧本地密码与锁定策略。改 UAC、删管理员这类可能把人锁在门外的项只给建议，不代改。'
            Params = @(
                @{ Name = 'Fix'; Label = '要修复的项'; Type = 'Combo'; Options = @(
                        '打开 Windows 防火墙（三个配置文件）',
                        '打开 Defender 实时保护',
                        '关闭 SMBv1 协议',
                        '禁用来宾账户（Guest）',
                        '开启远程桌面的 NLA',
                        '收紧本地密码与锁定策略'
                    ); Default = 1 }
            )
            DryRun = $true
            Script = {
                param($P)
                $map = @('firewall', 'defender-rt', 'smbv1', 'guest', 'rdp-nla', 'password-policy')
                $i = 1
                if ($P['Fix']) { $i = [int]$P['Fix'] }
                if ($i -lt 1 -or $i -gt $map.Count) { $i = 1 }
                Invoke-GuiReadySecurityFix -Id $map[$i - 1] -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }

        # ---------------- AI 辅助 ----------------
        [pscustomobject]@{
            Id = 'dsh-status'; Group = 'AI 辅助'; Name = 'DeepSeek Harness 依赖检查（只读）'
            Desc = '检查 Node.js / pnpm / dsh CLI / dsh-TUI / DEEPSEEK_API_KEY，并**真的问一次 npm** 这两个包存不存在（包名以 npm 的回答为准，不照抄文档）。'
            Params = @(); DryRun = $false
            Script = { param($P) Show-GuiReadyDshStatus | Out-Null }
        }
        [pscustomobject]@{
            Id = 'dsh-install'; Group = 'AI 辅助'; Name = '安装 dsh-TUI 依赖'
            Desc = 'npm install -g pnpm，再 npm install -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui，输出原样进日志；装完复核命令是否可用（刚装完当前进程 PATH 可能没刷新，会走回退路径）。不会碰你的 API Key。'
            Params = @(
                @{ Name = 'SkipPnpm'; Label = '跳过 pnpm（已经装过）'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = { param($P) Install-GuiReadyDsh -SkipPnpm:([bool]$P['SkipPnpm']) -WhatIf:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'dsh-launch'; Group = 'AI 辅助'; Name = '启动 dsh-TUI'
            Desc = '在独立的控制台窗口里启动 dsh-TUI（交互式 TUI 需要真控制台）。没设 DEEPSEEK_API_KEY 时会先提醒。'
            Params = @(
                @{ Name = 'Resume'; Label = '恢复上次会话（--resume）'; Type = 'Check'; Default = $false }
            )
            DryRun = $false
            Script = { param($P) Start-GuiReadyDsh -Resume:([bool]$P['Resume']) | Out-Null }
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
            Id = 'reboot'; Group = '会话与登录'; Name = '重启服务器（延时，可取消）'
            Desc = 'shutdown /r /t <延时> /f。所有会话会断开；延时期间可在命令行执行 shutdown /a 取消。角色安装后需要重启时，角色页会自动出现这个入口。'
            Params = @( @{ Name = 'DelaySec'; Label = '延时（秒，默认 20，最小 5）'; Type = 'Text'; Width = 120 } )
            DryRun = $true
            Script = {
                param($P)
                $d = 20
                try { $t = [int]([string]$P['DelaySec']); if ($t -gt 0) { $d = $t } } catch { }
                Invoke-GuiReadySystemReboot -DelaySec $d -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'reboot-cancel'; Group = '会话与登录'; Name = '取消已计划的重启'
            Desc = '等价于 shutdown /a：取消由本工具或其它程序排定的延时重启。'
            Params = @(); DryRun = $false
            Script = { param($P) Invoke-GuiReadySystemRebootCancel | Out-Null }
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

        # ---------------- 文件与日志 ----------------
        [pscustomobject]@{
            Id = 'file-mkdir'; Group = '文件与日志'; Name = '新建文件夹'
            Desc = '在指定目录下新建一个文件夹。名称不能包含路径分隔符，避免借"名称"跳到别的目录。'
            Params = @(
                @{ Name = 'Path'; Label = '所在目录（绝对路径）'; Type = 'Text'; Width = 520 }
                @{ Name = 'Name'; Label = '新文件夹名称'; Type = 'Text'; Width = 260 }
            )
            DryRun = $true
            Script = {
                param($P)
                $name = ([string]$P['Name']).Trim()
                if (-not $name) { throw '文件夹名称不能为空。' }
                if ($name -eq '.' -or $name -eq '..' -or $name -match '[\\/:*?"<>|]') {
                    throw ('文件夹名称包含非法字符：' + $name)
                }
                $base = ([string]$P['Path']).TrimEnd('\')
                New-GuiReadyFolder -Path (Join-Path $base $name) -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'file-rename'; Group = '文件与日志'; Name = '重命名'
            Desc = '重命名文件或文件夹。只改名称，不改变所在目录。'
            Params = @(
                @{ Name = 'Path'; Label = '要重命名的路径'; Type = 'Text'; Width = 520 }
                @{ Name = 'NewName'; Label = '新名称'; Type = 'Text'; Width = 260 }
            )
            DryRun = $true
            Script = {
                param($P)
                Rename-GuiReadyPath -Path ([string]$P['Path']) -NewName ([string]$P['NewName']) `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'file-delete'; Group = '文件与日志'; Name = '删除'
            Desc = '删除文件或文件夹。非空文件夹必须勾选递归；盘符根和系统关键目录本身会被拒绝。'
            Params = @(
                @{ Name = 'Path';    Label = '要删除的路径'; Type = 'Text'; Width = 520 }
                @{ Name = 'Recurse'; Label = '递归删除非空文件夹'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Remove-GuiReadyPath -Path ([string]$P['Path']) -Recurse:([bool]$P['Recurse']) -Force `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'file-save'; Group = '文件与日志'; Name = '保存文本文件'
            Desc = '把文本写入指定文件（原子替换）。目标不存在时要求上级目录已存在；原文件有 UTF-8 BOM 会保留。'
            Params = @(
                @{ Name = 'Path'; Label = '文件路径'; Type = 'Text'; Width = 520 }
                @{ Name = 'Text'; Label = '文件内容'; Type = 'Multi' }
            )
            DryRun = $true
            Script = {
                param($P)
                Save-GuiReadyTextFile -Path ([string]$P['Path']) -Text ([string]$P['Text']) `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'file-copy'; Group = '文件与日志'; Name = '复制到'
            Desc = '复制文件或文件夹。目标是已存在目录时复制到该目录下；禁止把目录复制到自身或子目录。'
            Params = @(
                @{ Name = 'Path';        Label = '源路径'; Type = 'Text'; Width = 520 }
                @{ Name = 'Destination'; Label = '目标路径或目标目录'; Type = 'Text'; Width = 520 }
                @{ Name = 'Overwrite';   Label = '目标已存在时覆盖'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Copy-GuiReadyPath -Path ([string]$P['Path']) -Destination ([string]$P['Destination']) `
                    -Overwrite:([bool]$P['Overwrite']) -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'file-move'; Group = '文件与日志'; Name = '移动到'
            Desc = '移动文件或文件夹（跨盘由系统复制后删除）。目标是已存在目录时移动进该目录。'
            Params = @(
                @{ Name = 'Path';        Label = '源路径'; Type = 'Text'; Width = 520 }
                @{ Name = 'Destination'; Label = '目标路径或目标目录'; Type = 'Text'; Width = 520 }
                @{ Name = 'Overwrite';   Label = '目标已存在时覆盖'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Move-GuiReadyPath -Path ([string]$P['Path']) -Destination ([string]$P['Destination']) `
                    -Overwrite:([bool]$P['Overwrite']) -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'file-compress'; Group = '文件与日志'; Name = '压缩为 ZIP'
            Desc = '把文件或文件夹压缩成 ZIP。目标留空时在同级生成同名 .zip；压缩包不能放进被压缩目录内。'
            Params = @(
                @{ Name = 'Path';        Label = '要压缩的路径'; Type = 'Text'; Width = 520 }
                @{ Name = 'Destination'; Label = '压缩包路径（留空自动命名）'; Type = 'Text'; Width = 520 }
            )
            DryRun = $true
            Script = {
                param($P)
                Compress-GuiReadyPath -Path ([string]$P['Path']) -Destination ([string]$P['Destination']) `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'file-expand'; Group = '文件与日志'; Name = '解压 ZIP'
            Desc = '解压 ZIP 到指定目录。逐项校验路径，压缩包里的 ..\ 条目会被拒绝（防目录穿越）。'
            Params = @(
                @{ Name = 'Path';        Label = 'ZIP 文件路径'; Type = 'Text'; Width = 520 }
                @{ Name = 'Destination'; Label = '解压到（目录）'; Type = 'Text'; Width = 520 }
                @{ Name = 'Overwrite';   Label = '覆盖同名文件'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Expand-GuiReadyArchive -Path ([string]$P['Path']) -Destination ([string]$P['Destination']) `
                    -Overwrite:([bool]$P['Overwrite']) -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'log-export'; Group = '文件与日志'; Name = '导出日志'
            Desc = '按源 / 级别 / 时间范围 / 关键词读取日志并导出为 CSV 或文本。事件日志与工具文件日志都支持。'
            Params = @(
                @{ Name = 'Source';  Label = '日志源（event:System 或 file:完整路径）'; Type = 'Text'; Width = 420; Default = 'event:System' }
                @{ Name = 'Level';   Label = '级别'; Type = 'Combo'; Options = @('全部', '错误', '警告', '信息'); Default = 1 }
                @{ Name = 'Since';   Label = '时间范围'; Type = 'Combo'; Options = @('1 小时', '6 小时', '24 小时', '7 天', '30 天', '全部'); Default = 3 }
                @{ Name = 'Keyword'; Label = '关键词（可空）'; Type = 'Text'; Width = 300 }
                @{ Name = 'Path';    Label = '导出文件路径（绝对路径）'; Type = 'Text'; Width = 520 }
                @{ Name = 'Format';  Label = '格式'; Type = 'Combo'; Options = @('CSV', '文本'); Default = 1 }
            )
            DryRun = $true
            Script = {
                param($P)
                $levels = @('All', 'Error', 'Warning', 'Information')
                $i = 1
                if ($P['Level']) { $i = [int]$P['Level'] }
                if ($i -lt 1 -or $i -gt $levels.Count) { $i = 1 }

                $ranges = @('1h', '6h', '24h', '7d', '30d', 'all')
                $s = 3
                if ($P['Since']) { $s = [int]$P['Since'] }
                if ($s -lt 1 -or $s -gt $ranges.Count) { $s = 3 }

                $formats = @('Csv', 'Text')
                $f = 1
                if ($P['Format']) { $f = [int]$P['Format'] }
                if ($f -lt 1 -or $f -gt $formats.Count) { $f = 1 }

                $r = Get-GuiReadyLogEntries -Source ([string]$P['Source']) -Max 2000 `
                        -Level $levels[$i - 1] -Since $ranges[$s - 1] -Keyword ([string]$P['Keyword'])
                Export-GuiReadyLog -Entries $r.Entries -Path ([string]$P['Path']) -Format $formats[$f - 1] `
                    -WhatIf:([bool]$P['DryRun']) | Out-Null
            }
        }

        # ---------------- 配置备份 ----------------
        [pscustomobject]@{
            Id = 'backup-export'; Group = '配置备份'; Name = '导出配置备份（ZIP）'
            Desc = '把用户档案、受管程序清单、流程状态与角色缓存打包成 ZIP（含 manifest.json，不含口令与日志）。留空时存到 backup\config-<时间戳>.zip。'
            Params = @(
                @{ Name = 'Destination'; Label = '备份包路径（留空自动命名）'; Type = 'Text'; Width = 520 }
            )
            DryRun = $true
            Script = {
                param($P)
                $r = Export-GuiReadyConfigBackup -Destination ([string]$P['Destination']) -WhatIf:([bool]$P['DryRun'])
                Write-Head '配置备份'
                if ($r.Planned) {
                    Write-Log ('将要以 {0} 个文件写入: {1}' -f $r.Count, $r.Archive) 'INFO'
                } else {
                    Write-Log ('已备份 {0} 个文件到 {1}' -f $r.Count, $r.Archive) 'OK'
                }
                foreach ($f in @($r.Files)) { Write-Log ('  包含: ' + $f) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'backup-import'; Group = '配置备份'; Name = '从配置备份恢复'
            Desc = '从本工具生成的 ZIP 恢复配置。只接受 manifest.json 清单内的固定路径；恢复前会把现有文件另存到 backup\config-restore-<时间戳>。'
            Params = @(
                @{ Name = 'Path'; Label = '备份包路径（.zip）'; Type = 'Text'; Width = 520; Browse = 'File' }
            )
            DryRun = $true
            Script = {
                param($P)
                $r = Import-GuiReadyConfigBackup -Path ([string]$P['Path']) -WhatIf:([bool]$P['DryRun'])
                Write-Head '配置恢复'
                if ($r.Planned) {
                    Write-Log ('将要从 {0} 恢复 {1} 个文件' -f $r.Archive, $r.Count) 'INFO'
                } else {
                    Write-Log ('已从 {0} 恢复 {1} 个文件；原文件在 {2}' -f $r.Archive, $r.Count, $r.BackupDir) 'OK'
                }
                foreach ($f in @($r.Files)) { Write-Log ('  ' + $f) 'INFO' }
            }
        }
        # ---------------- 远程运维 ----------------
        [pscustomobject]@{
            Id    = 'remote-run'
            Group = '远程运维'
            Name  = '远程批量执行命令'
            Desc  = '把一段 PowerShell 命令分别送到多台主机执行，逐机留结果；主机留空表示全部启用的主机。凭据使用主机清单里保存的 DPAPI 凭据。'
            Params = @(
                @{ Name = 'Hosts'; Label = '主机（Id/名称/地址，逗号分隔；留空=全部启用）'; Type = 'Text'; Width = 520 }
                @{ Name = 'Command'; Label = '要执行的 PowerShell 命令'; Type = 'Multi'; Width = 520 }
                @{ Name = 'TimeoutSec'; Label = '每台超时秒数（10-1800）'; Type = 'Text'; Default = '120'; Width = 120 }
                @{ Name = 'ContinueOnError'; Label = '某台失败后继续执行其它主机'; Type = 'Check'; Default = $true }
            )
            DryRun = $true
            Script = {
                param($P)
                $spec = [string]$P['Hosts']
                $cmd  = [string]$P['Command']
                $tmo  = 120
                if ($P['TimeoutSec']) { [void][int]::TryParse([string]$P['TimeoutSec'], [ref]$tmo) }
                if ($tmo -lt 10) { $tmo = 10 }
                if ($tmo -gt 1800) { $tmo = 1800 }
                $cont = $true
                if ($P.ContainsKey('ContinueOnError')) { $cont = [bool]$P['ContinueOnError'] }
                $taskId = ''
                if ($P.ContainsKey('__TaskId')) { $taskId = [string]$P['__TaskId'] }

                if ([bool]$P['DryRun']) {
                    $hosts = @(Resolve-GuiReadyHostTargets -Spec $spec)
                    Write-Head '远程批量（预览）'
                    Write-Log ('将要对 {0} 台主机执行命令：' -f $hosts.Count) 'INFO'
                    foreach ($h in $hosts) {
                        Write-Log ('  {0}  {1}:{2}  认证={3}' -f $h.Name, $h.Address, $h.Port, $h.Auth) 'INFO'
                    }
                    Write-Log ('命令：' + $cmd) 'DRY'
                    return
                }

                $r = Invoke-GuiReadyRemoteBatch -HostSpec $spec -Command $cmd -TimeoutSec $tmo `
                        -ContinueOnError $cont -TaskId $taskId
                Write-Head '远程批量结果'
                Write-Log ('主机 {0} 台：成功 {1}、失败 {2}、跳过 {3}' -f $r.Total, $r.Succeeded, $r.Failed, $r.Skipped) `
                    $(if ($r.Failed -gt 0) { 'WARN' } else { 'OK' })
                foreach ($x in @($r.Results)) {
                    Write-Log ('----- {0}（{1}） {2}  {3} 秒 -----' -f $x.Name, $x.Address, $x.Status, $x.DurationSec) 'INFO'
                    if ($x.Output) {
                        foreach ($ln in ([string]$x.Output -split "`r?`n")) { Write-Log ('  ' + $ln) 'INFO' }
                    }
                    if ($x.Error) { Write-Log ('  ' + [string]$x.Error) 'ERROR' }
                }
                Write-Log ('逐机结果文件：' + $r.File) 'INFO'
                if ($r.Failed -gt 0) { throw ('{0} 台主机执行失败，详见 {1}' -f $r.Failed, $r.File) }
            }
        }
    )
}

function Set-GuiReadyActionRequirements {
    # 必填参数表。
    #
    # 为什么要有它：这些参数一旦为空，动作脚本就会以
    #   "Cannot bind argument to parameter 'Path' because it is an empty string"
    # 收场 —— 用户看到的就是一句看不懂的英文报错，还以为是"这个功能坏了"。
    # 标上 Req 之后，GUI 与 runner 都会在开跑前拦住，并明确说"哪一项没填"。
    # 表放在这里而不是散在各条动作里，是为了"哪些字段必填"一眼能看完、也只改一处。
    param([object[]]$Actions)

    $required = @{
        'pecheck'          = @('Path')
        'diag'             = @('Path')
        'catalog-query'    = @('Path')
        'catalog-add'      = @('Id', 'Name', 'Pattern')
        'dotnet'           = @('Path')
        'pkg-install'      = @('Package')
        'pkg-info'         = @('Package')
        'pkg-uninstall'    = @('Package')
        'store-queue'      = @('AppIds')
        'role-install'     = @('Name')
        'role-batch-install' = @('Names')
        'role-remove'      = @('Name')
        'role-batch-remove' = @('Names')
        'monitor-service'  = @('Name')
        'autologon-enable' = @('User', 'Password')
        'persistent-run'   = @('Path')
        'file-mkdir'       = @('Path', 'Name')
        'file-rename'      = @('Path', 'NewName')
        'file-delete'      = @('Path')
        'file-save'        = @('Path', 'Text')
        'file-copy'        = @('Path', 'Destination')
        'file-move'        = @('Path', 'Destination')
        'file-compress'    = @('Path')
        'file-expand'      = @('Path', 'Destination')
        'log-export'       = @('Source', 'Path')
        'backup-import'    = @('Path')
        'remote-run'       = @('Command')
    }

    foreach ($a in @($Actions)) {
        if (-not $a) { continue }
        $id = [string]$a.Id
        if (-not $required.ContainsKey($id)) { continue }
        $keys = @($required[$id])
        foreach ($pd in @($a.Params)) {
            if ($keys -contains [string]$pd.Name) { $pd['Req'] = $true }
        }
    }
    return $Actions
}

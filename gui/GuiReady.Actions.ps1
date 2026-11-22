# GuiReady actions: single source of truth shared by the GUI and the headless runner.
# Each action runs with a hashtable of parameters: the GUI builds it, the runner passes it in.
# Script blocks take param($P) so lookups are explicit and scope-safe.

function Get-GuiReadyActions {
    $actions = @(
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

        # ---------------- 守护与计划 ----------------
        [pscustomobject]@{
            Id = 'guard-add'; Group = '守护与计划'; Name = '添加进程守护（崩溃自动拉起）'
            Desc = '登记一个程序，并注册每 N 分钟检查一次的计划任务：进程不在就用原参数拉起；连续启动失败按 15→30→60→120→240→300 秒退避，不会疯狂重试。用户会话模式下任务只在该用户登录时跑（GUI 程序才看得见）；后台服务请选 SYSTEM。'
            Params = @(
                @{ Name = 'Name';        Label = '名称（例如 Minecraft 服务端）'; Type = 'Text'; Width = 320 }
                @{ Name = 'Exe';         Label = '程序路径（exe）'; Type = 'Text'; Width = 520; Browse = 'File' }
                @{ Name = 'Args';        Label = '启动参数（可空）'; Type = 'Text'; Width = 480 }
                @{ Name = 'WorkDir';     Label = '工作目录（留空 = exe 所在目录）'; Type = 'Text'; Width = 480; Browse = 'Folder' }
                @{ Name = 'IntervalMin'; Label = '检查间隔（分钟，最小 1）'; Type = 'Text'; Default = '1'; Width = 120 }
                @{ Name = 'DelaySec';    Label = '启动失败退避基数（秒）'; Type = 'Text'; Default = '15'; Width = 120 }
                @{ Name = 'RunAs';       Label = '运行身份'; Type = 'Combo'; Default = 1; Options = @(
                    '当前登录用户（交互会话）', '系统账户 SYSTEM（无窗口）') }
            )
            DryRun = $true
            Script = {
                param($P)
                $interval = 1; [void][int]::TryParse([string]$P['IntervalMin'], [ref]$interval)
                $delay = 15;   [void][int]::TryParse([string]$P['DelaySec'], [ref]$delay)
                $runAs = if ([int]$P['RunAs'] -eq 2) { 'system' } else { 'user' }
                New-GuiReadyGuard -Name ([string]$P['Name']) -Exe ([string]$P['Exe']) -Args ([string]$P['Args']) `
                    -WorkDir ([string]$P['WorkDir']) -IntervalMin $interval -DelaySec $delay -RunAs $runAs `
                    -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'guard-check'; Group = '守护与计划'; Name = '立即检查守护进程'
            Desc = '马上按守护规则检查一次（进程在 = 放行；不在 = 拉起或进入退避）。留空编号表示全部检查。计划任务每 N 分钟跑的就是这一步。'
            Params = @( @{ Name = 'Id'; Label = '守护编号（留空 = 全部）'; Type = 'Text'; Width = 260 } )
            DryRun = $true
            Script = {
                param($P)
                $r = @(Invoke-GuiReadyGuardCheck -Id ([string]$P['Id']) -DryRun:([bool]$P['DryRun']))
                Write-Head '守护检查'
                foreach ($x in $r) {
                    $lvl = switch ($x.Action) { 'running' { 'OK' } 'started' { 'OK' } 'failed' { 'ERROR' } default { 'INFO' } }
                    Write-Log ('{0}：{1}（{2}）' -f $x.Name, $x.Message, $x.Action) $lvl
                }
            }
        }
        [pscustomobject]@{
            Id = 'guard-toggle'; Group = '守护与计划'; Name = '启用 / 暂停守护'
            Desc = '暂停只是停掉对应的计划任务（ScmOps-Guard-*），守护记录与参数都保留，随时可以再启用。'
            Params = @(
                @{ Name = 'Id';      Label = '守护编号'; Type = 'Text'; Width = 260 }
                @{ Name = 'Enabled'; Label = '操作'; Type = 'Combo'; Default = 1; Options = @('启用', '暂停') }
            )
            DryRun = $false
            Script = {
                param($P)
                $enabled = ([int]$P['Enabled'] -eq 1)
                Set-GuiReadyGuardEnabled -Id ([string]$P['Id']) -Enabled $enabled -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'guard-remove'; Group = '守护与计划'; Name = '删除进程守护'
            Desc = '删除守护记录并注销对应计划任务（不会动被守护的程序本身）。'
            Params = @( @{ Name = 'Id'; Label = '守护编号'; Type = 'Text'; Width = 260 } )
            DryRun = $true
            Script = { param($P) Remove-GuiReadyGuard -Id ([string]$P['Id']) -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'plan-add'; Group = '守护与计划'; Name = '添加计划任务（动作链）'
            Desc = '按间隔、每天或每周定时，依次执行一串已有动作（用分号分隔，例如 reboot;backup-export）。每一步都走正常的动作执行器，任务记录与审计照常落盘。动作链里的动作请用不需要额外参数的那些。'
            Params = @(
                @{ Name = 'Name';        Label = '名称'; Type = 'Text'; Width = 320 }
                @{ Name = 'Chain';       Label = '动作链（动作 Id，; 分隔）'; Type = 'Text'; Width = 520; Default = 'backup-export' }
                @{ Name = 'Schedule';    Label = '频率'; Type = 'Combo'; Default = 1; Options = @('按间隔重复', '每天定时', '每周定时') }
                @{ Name = 'IntervalMin'; Label = '间隔（分钟）'; Type = 'Text'; Default = '60'; Width = 120 }
                @{ Name = 'Time';        Label = '执行时间（HH:mm）'; Type = 'Text'; Default = '03:00'; Width = 120 }
                @{ Name = 'Weekday';     Label = '每周几（仅「每周定时」用）'; Type = 'Combo'; Default = 1; Options = @(
                    '周一', '周二', '周三', '周四', '周五', '周六', '周日') }
                @{ Name = 'RunAs';       Label = '运行身份'; Type = 'Combo'; Default = 2; Options = @(
                    '当前登录用户（交互会话）', '系统账户 SYSTEM（无窗口）') }
            )
            DryRun = $true
            Script = {
                param($P)
                $schedule = if ([int]$P['Schedule'] -eq 3) { 'weekly' } elseif ([int]$P['Schedule'] -eq 2) { 'daily' } else { 'interval' }
                $interval = 60; [void][int]::TryParse([string]$P['IntervalMin'], [ref]$interval)
                $days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
                $di = [int]$P['Weekday']; if ($di -lt 1 -or $di -gt 7) { $di = 1 }
                $runAs = if ([int]$P['RunAs'] -eq 2) { 'system' } else { 'user' }
                New-GuiReadyPlan -Name ([string]$P['Name']) -Chain ([string]$P['Chain']) -Schedule $schedule `
                    -IntervalMin $interval -Time ([string]$P['Time']) -Weekday $days[$di - 1] `
                    -RunAs $runAs -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'plan-run'; Group = '守护与计划'; Name = '立即执行计划'
            Desc = '不管排期，马上按动作链跑一遍（用于验证配置对不对）。'
            Params = @( @{ Name = 'Id'; Label = '计划编号'; Type = 'Text'; Width = 260 } )
            DryRun = $true
            Script = {
                param($P)
                $r = Invoke-GuiReadyPlan -Id ([string]$P['Id']) -DryRun:([bool]$P['DryRun'])
                if ($r) { Write-Log ('成功 {0} 步 / 失败 {1} 步' -f $r.Ok, $r.Failed) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'plan-toggle'; Group = '守护与计划'; Name = '启用 / 暂停计划'
            Desc = '暂停只停计划任务，记录保留。'
            Params = @(
                @{ Name = 'Id';      Label = '计划编号'; Type = 'Text'; Width = 260 }
                @{ Name = 'Enabled'; Label = '操作'; Type = 'Combo'; Default = 1; Options = @('启用', '暂停') }
            )
            DryRun = $false
            Script = {
                param($P)
                $enabled = ([int]$P['Enabled'] -eq 1)
                Set-GuiReadyPlanEnabled -Id ([string]$P['Id']) -Enabled $enabled -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'plan-remove'; Group = '守护与计划'; Name = '删除计划任务'
            Desc = '删除计划记录并注销对应的计划任务（ScmOps-Plan-*）。'
            Params = @( @{ Name = 'Id'; Label = '计划编号'; Type = 'Text'; Width = 260 } )
            DryRun = $true
            Script = { param($P) Remove-GuiReadyPlan -Id ([string]$P['Id']) -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- 备份与巡检 ----------------
        [pscustomobject]@{
            Id = 'backup-add'; Group = '备份与巡检'; Name = '添加目录备份（保留 N 份）'
            Desc = '把源目录打包成 <名称>-<时间戳>.zip（或整目录复制）放到目标目录，每天定时执行，并只保留最新 N 份。目标目录不能放在源目录里面。'
            Params = @(
                @{ Name = 'Name';       Label = '名称'; Type = 'Text'; Width = 320 }
                @{ Name = 'Source';     Label = '源目录'; Type = 'Text'; Width = 480; Browse = 'Folder' }
                @{ Name = 'Target';     Label = '备份存放目录'; Type = 'Text'; Width = 480; Browse = 'Folder' }
                @{ Name = 'BackupMode'; Label = '方式'; Type = 'Combo'; Default = 1; Options = @('zip（压缩包）', 'copy（整目录复制）') }
                @{ Name = 'Keep';       Label = '保留份数'; Type = 'Text'; Default = '3'; Width = 120 }
                @{ Name = 'Time';       Label = '每天执行时间（HH:mm）'; Type = 'Text'; Default = '02:00'; Width = 120 }
                @{ Name = 'RunAs';      Label = '运行身份'; Type = 'Combo'; Default = 2; Options = @(
                    '当前登录用户（交互会话）', '系统账户 SYSTEM（无窗口）') }
            )
            DryRun = $true
            Script = {
                param($P)
                $mode = if ([int]$P['BackupMode'] -eq 2) { 'copy' } else { 'zip' }
                $keep = 3; [void][int]::TryParse([string]$P['Keep'], [ref]$keep)
                $runAs = if ([int]$P['RunAs'] -eq 2) { 'system' } else { 'user' }
                New-GuiReadyBackupJob -Name ([string]$P['Name']) -Source ([string]$P['Source']) `
                    -Target ([string]$P['Target']) -Mode $mode -Keep $keep -Time ([string]$P['Time']) `
                    -RunAs $runAs -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'backup-run'; Group = '备份与巡检'; Name = '立即执行目录备份'
            Desc = '马上按备份任务跑一次，并按保留策略清理旧包。'
            Params = @( @{ Name = 'Id'; Label = '备份编号'; Type = 'Text'; Width = 260 } )
            DryRun = $true
            Script = {
                param($P)
                $r = Invoke-GuiReadyBackupJob -Id ([string]$P['Id']) -DryRun:([bool]$P['DryRun'])
                if ($r) { Write-Log ('已生成 {0}（{1} MB），清理 {2} 份旧备份' -f $r.File, $r.SizeMB, $r.Removed) 'OK' }
            }
        }
        [pscustomobject]@{
            Id = 'backup-remove'; Group = '备份与巡检'; Name = '删除目录备份任务'
            Desc = '删除备份记录并注销计划任务；已经生成的备份文件不会被删除。'
            Params = @( @{ Name = 'Id'; Label = '备份编号'; Type = 'Text'; Width = 260 } )
            DryRun = $true
            Script = { param($P) Remove-GuiReadyBackupJob -Id ([string]$P['Id']) -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'patrol-add'; Group = '备份与巡检'; Name = '添加端口巡检目标'
            Desc = '登记一组要盯的端口（可填主机名/IP + 端口列表）。本机端口会顺便显示监听进程。巡检不排期，需要时点「巡检一次」。'
            Params = @(
                @{ Name = 'Name';      Label = '名称'; Type = 'Text'; Width = 320 }
                @{ Name = 'Host';      Label = '主机（留空 = 127.0.0.1）'; Type = 'Text'; Default = '127.0.0.1'; Width = 260 }
                @{ Name = 'Ports';     Label = '端口（逗号分隔，例如 80,443,3389）'; Type = 'Text'; Width = 320 }
                @{ Name = 'TimeoutMs'; Label = '单端口超时（毫秒）'; Type = 'Text'; Default = '1500'; Width = 120 }
            )
            DryRun = $true
            Script = {
                param($P)
                $tmo = 1500; [void][int]::TryParse([string]$P['TimeoutMs'], [ref]$tmo)
                New-GuiReadyPatrol -Name ([string]$P['Name']) -TargetHost ([string]$P['Host']) `
                    -Ports ([string]$P['Ports']) -TimeoutMs $tmo -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'patrol-run'; Group = '备份与巡检'; Name = '巡检端口'
            Desc = '逐个端口做一次 TCP 连接（带超时），本机端口额外查监听进程；结果写回巡检记录。'
            Params = @( @{ Name = 'Id'; Label = '巡检编号'; Type = 'Text'; Width = 260 } )
            DryRun = $true
            Script = {
                param($P)
                $rows = @(Invoke-GuiReadyPortPatrol -Id ([string]$P['Id']) -DryRun:([bool]$P['DryRun']))
                Write-Head '端口巡检'
                foreach ($r in $rows) {
                    Write-Log ('{0} → {1}  {2} ms  {3}' -f $r.Port, $r.Note, $r.Ms, $r.Owner) $(if ($r.Open -eq $false) { 'WARN' } else { 'INFO' })
                }
            }
        }
        [pscustomobject]@{
            Id = 'patrol-remove'; Group = '备份与巡检'; Name = '删除巡检目标'
            Desc = '只删除登记项，不影响任何服务。'
            Params = @( @{ Name = 'Id'; Label = '巡检编号'; Type = 'Text'; Width = 260 } )
            DryRun = $false
            Script = { param($P) Remove-GuiReadyPatrol -Id ([string]$P['Id']) -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- 下载队列 ----------------
        [pscustomobject]@{
            Id = 'download-add'; Group = '下载队列'; Name = '添加下载（BITS 后台传输）'
            Desc = '用 Windows 自带的 BITS 后台传输下载 http/https 文件：断点续传、可暂停、关掉界面也继续。默认存到 payload\downloads。'
            Params = @(
                @{ Name = 'Url';      Label = '下载地址（http / https）'; Type = 'Text'; Width = 520 }
                @{ Name = 'Folder';   Label = '保存目录（留空 = payload\downloads）'; Type = 'Text'; Width = 480; Browse = 'Folder' }
                @{ Name = 'FileName'; Label = '另存文件名（留空 = 用 URL 里的文件名）'; Type = 'Text'; Width = 320 }
            )
            DryRun = $true
            Script = {
                param($P)
                $r = Add-GuiReadyDownload -Url ([string]$P['Url']) -Folder ([string]$P['Folder']) `
                    -FileName ([string]$P['FileName']) -DryRun:([bool]$P['DryRun'])
                if ($r -and $r.File) { Write-Log ('目标文件：' + $r.File) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'download-pause'; Group = '下载队列'; Name = '暂停下载'
            Desc = '暂停一条 BITS 传输；已下载的部分保留，继续时接着下。'
            Params = @( @{ Name = 'Id'; Label = '下载编号'; Type = 'Text'; Width = 260 } )
            DryRun = $false
            Script = { param($P) Set-GuiReadyDownloadAction -Id ([string]$P['Id']) -Action 'pause' -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'download-resume'; Group = '下载队列'; Name = '继续下载'
            Desc = '继续被暂停的 BITS 传输。'
            Params = @( @{ Name = 'Id'; Label = '下载编号'; Type = 'Text'; Width = 260 } )
            DryRun = $false
            Script = { param($P) Set-GuiReadyDownloadAction -Id ([string]$P['Id']) -Action 'resume' -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'download-complete'; Group = '下载队列'; Name = '收尾下载（完成）'
            Desc = '对「已完成（待收尾）」的 BITS 任务做 Complete，文件正式落地并移出队列。'
            Params = @( @{ Name = 'Id'; Label = '下载编号'; Type = 'Text'; Width = 260 } )
            DryRun = $false
            Script = { param($P) Set-GuiReadyDownloadAction -Id ([string]$P['Id']) -Action 'complete' -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'download-cancel'; Group = '下载队列'; Name = '取消下载'
            Desc = '取消 BITS 传输并从队列里移除（未完成的临时文件会被清掉）。'
            Params = @( @{ Name = 'Id'; Label = '下载编号'; Type = 'Text'; Width = 260 } )
            DryRun = $false
            Script = { param($P) Set-GuiReadyDownloadAction -Id ([string]$P['Id']) -Action 'cancel' -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'download-remove'; Group = '下载队列'; Name = '从队列移除（保留文件）'
            Desc = '只把记录从队列里拿掉；已经下载到磁盘的文件保留。'
            Params = @( @{ Name = 'Id'; Label = '下载编号'; Type = 'Text'; Width = 260 } )
            DryRun = $false
            Script = { param($P) Set-GuiReadyDownloadAction -Id ([string]$P['Id']) -Action 'remove' -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- Windows 更新 ----------------
        [pscustomobject]@{
            Id = 'update-check'; Group = 'Windows 更新'; Name = '检查可用更新'
            Desc = '用系统自带的 Windows Update COM 接口在线检查（不依赖 PSWindowsUpdate）。可能要几十秒；组策略指向 WSUS 时走同一个入口。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $r = Get-GuiReadyPendingUpdate
                Write-Head 'Windows Update'
                Write-Log ('自动更新：' + $r.Auto.Text + ' · 服务 ' + $r.Auto.Service) 'INFO'
                Write-Log ('检查用时 {0} 秒，可用更新 {1} 个' -f $r.Seconds, @($r.Items).Count) 'OK'
                foreach ($u in $r.Items) {
                    Write-Log ('  [{0}] {1}  {2}  {3} MB' -f $u.Index, $u.Title, $u.Kb, $u.SizeMB) 'INFO'
                }
                if ($r.Error) { throw $r.Error }
            }
        }
        [pscustomobject]@{
            Id = 'update-install'; Group = 'Windows 更新'; Name = '安装更新'
            Desc = '下载并安装选中的更新（编号来自「检查可用更新」），也可以全装。安装可能触发重启；工具不会自动重启，只会在日志里提示。'
            Params = @(
                @{ Name = 'Indexes'; Label = '更新编号（逗号分隔，例如 0,2）'; Type = 'Text'; Width = 320 }
                @{ Name = 'All';     Label = '安装全部可用更新'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                $idx = @()
                foreach ($x in ([string]$P['Indexes'] -split '[;,\s]+')) { if ($x.Trim()) { $idx += [int]$x.Trim() } }
                $all = $false
                if ($P.ContainsKey('All')) { $all = [bool]$P['All'] }
                if ($idx.Count -eq 0 -and -not $all) { throw '没有选中更新：填编号，或勾上「安装全部」' }
                $rows = @(Install-GuiReadyUpdate -Indexes $idx -DryRun:([bool]$P['DryRun']))
                Write-Head '更新安装结果'
                foreach ($r in $rows) { Write-Log ('  {0} → {1}' -f $r.Title, $r.Text) $(if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) { 'OK' } else { 'ERROR' }) }
            }
        }
        [pscustomobject]@{
            Id = 'update-history'; Group = 'Windows 更新'; Name = '已安装更新（历史）'
            Desc = '读取已安装的补丁（Get-HotFix），按安装日期倒序，最多 30 条。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadyUpdateHistory -Max 30)
                Write-Head '已安装更新'
                foreach ($r in $rows) { Write-Log ('  {0}  {1}  {2}' -f $r.Kb, $r.InstalledOn, $r.Description) 'INFO' }
                if ($rows.Count -eq 0) { Write-Log '没有读到更新记录' 'WARN' }
            }
        }
        [pscustomobject]@{
            Id = 'update-auto'; Group = 'Windows 更新'; Name = '设置自动更新'
            Desc = '写 Windows Update 的 AU 策略：自动下载并安装 / 仅通知 / 自动下载手动安装 / 关闭。改完会回读一次。'
            Params = @( @{ Name = 'Mode'; Label = '自动更新策略'; Type = 'Combo'; Default = 1; Options = @(
                '自动下载并安装（推荐服务器）', '自动下载，手动安装', '仅通知，由管理员安装', '关闭自动更新') } )
            DryRun = $true
            Script = {
                param($P)
                $modes = @('auto', 'manual', 'notify', 'off')
                $i = [int]$P['Mode']; if ($i -lt 1 -or $i -gt 4) { $i = 1 }
                Set-GuiReadyUpdateAuto -Mode $modes[$i - 1] -DryRun:([bool]$P['DryRun'])
            }
        }

        # ---------------- 网络配置 ----------------
        [pscustomobject]@{
            Id = 'net-status'; Group = '网络配置'; Name = '网络状态（网卡 / IP / 网关 / DNS）'
            Desc = '列出所有网卡的 IP、网关、DNS、DHCP 状态与默认路由。只读。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $st = Get-GuiReadyNetworkStatus
                Write-Head ('网络状态 · ' + $st.Hostname)
                foreach ($a in $st.Adapters) {
                    Write-Log ('{0}（ifIndex {1}）：{2} / {3} / IP {4} / 网关 {5} / DNS {6} / DHCP {7}' -f `
                        $a.Name, $a.ifIndex, $a.Status, $a.LinkSpeed, $a.Ip, $a.Gateway, $a.Dns, $a.Dhcp) 'INFO'
                }
                foreach ($r in $st.Routes) { Write-Log ('默认路由：ifIndex {0} → {1}（metric {2}）' -f $r.IfIndex, $r.NextHop, $r.Metric) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'net-set-ip'; Group = '网络配置'; Name = '设置 IP / DNS（可能断开远程连接）'
            Desc = '把指定网卡切换为 DHCP 或静态地址。改之前会先把当前配置存到 backup\；远程操作时改错地址会立刻断线，请确认你还有其它入口。'
            Params = @(
                @{ Name = 'Adapter';      Label = '网卡名（如 Ethernet）'; Type = 'Text'; Width = 260 }
                @{ Name = 'Dhcp';         Label = '使用 DHCP（勾上则忽略下面的地址）'; Type = 'Check'; Default = $false }
                @{ Name = 'Ip';           Label = 'IP 地址'; Type = 'Text'; Width = 200 }
                @{ Name = 'PrefixLength'; Label = '子网前缀长度（24 = 255.255.255.0）'; Type = 'Text'; Default = '24'; Width = 120 }
                @{ Name = 'Gateway';      Label = '默认网关（可空）'; Type = 'Text'; Width = 200 }
                @{ Name = 'Dns';          Label = 'DNS 服务器（逗号分隔，可空）'; Type = 'Text'; Width = 320 }
            )
            DryRun = $true
            Script = {
                param($P)
                $prefix = 24; [void][int]::TryParse([string]$P['PrefixLength'], [ref]$prefix)
                $dhcp = $false; if ($P.ContainsKey('Dhcp')) { $dhcp = [bool]$P['Dhcp'] }
                Set-GuiReadyNetworkIp -Adapter ([string]$P['Adapter']) -Dhcp:$dhcp -Ip ([string]$P['Ip']) `
                    -PrefixLength $prefix -Gateway ([string]$P['Gateway']) -Dns ([string]$P['Dns']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'net-adapter'; Group = '网络配置'; Name = '网卡启用 / 禁用 / 重启'
            Desc = '对指定网卡做启用、禁用或重启。禁用正在使用的网卡会让远程会话断开。'
            Params = @(
                @{ Name = 'Adapter'; Label = '网卡名'; Type = 'Text'; Width = 260 }
                @{ Name = 'Action';  Label = '操作'; Type = 'Combo'; Default = 3; Options = @('启用', '禁用', '重启') }
            )
            DryRun = $true
            Script = {
                param($P)
                $acts = @('enable', 'disable', 'restart')
                $i = [int]$P['Action']; if ($i -lt 1 -or $i -gt 3) { $i = 3 }
                Set-GuiReadyNetworkAdapter -Adapter ([string]$P['Adapter']) -Action $acts[$i - 1] -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'net-dns-test'; Group = '网络配置'; Name = 'DNS 解析测试'
            Desc = '解析一个域名，可指定 DNS 服务器；输出记录类型、值与耗时。'
            Params = @(
                @{ Name = 'Name';   Label = '域名（如 www.microsoft.com）'; Type = 'Text'; Width = 320 }
                @{ Name = 'Server'; Label = 'DNS 服务器（留空 = 系统默认）'; Type = 'Text'; Width = 220 }
            )
            DryRun = $false
            Script = {
                param($P)
                $r = Test-GuiReadyDns -Name ([string]$P['Name']) -Server ([string]$P['Server'])
                Write-Head 'DNS 解析'
                foreach ($x in $r.Items) { Write-Log ('{0}  {1}  {2}  TTL {3}' -f $x.Name, $x.Type, $x.Value, $x.Ttl) 'INFO' }
                Write-Log ('用时 {0} ms' -f $r.Ms) 'OK'
            }
        }
        [pscustomobject]@{
            Id = 'net-routes'; Group = '网络配置'; Name = '路由表'
            Desc = '列出本机路由（最多 60 条）：目标网段、下一跳、接口与 metric。只读。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadyRoutes)
                Write-Head '路由表'
                foreach ($r in $rows) { Write-Log ('{0,-20} {1,-16} {2,-16} metric {3}' -f $r.Destination, $r.NextHop, $r.Interface, $r.Metric) 'INFO' }
            }
        }

        # ---------------- 本地账户 ----------------
        [pscustomobject]@{
            Id = 'account-status'; Group = '本地账户'; Name = '本地用户（只读）'
            Desc = '列出本地用户、启用状态、最近登录、所属组。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $st = Get-GuiReadyLocalAccounts
                Write-Head ('本地用户 · ' + $st.Computer)
                foreach ($u in $st.Users) {
                    Write-Log ('{0,-20} 启用={1,-5} 最近={2,-18} 组={3}' -f $u.Name, $u.Enabled, $u.LastLogon, $u.Groups) 'INFO'
                }
                Write-Log ('管理员组成员：' + ($st.Admins -join ', ')) 'INFO'
                Write-Log ('远程桌面用户：' + ($st.RdpUsers -join ', ')) 'INFO'
            }
        }
        [pscustomobject]@{
            Id = 'account-groups'; Group = '本地账户'; Name = '本地组（只读）'
            Desc = '列出本地组与成员。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $st = Get-GuiReadyLocalAccounts
                Write-Head '本地组'
                foreach ($g in $st.Groups) { Write-Log ('{0,-28} {1,3} 人：{2}' -f $g.Name, $g.Count, $g.Members) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'account-add'; Group = '本地账户'; Name = '新建本地用户'
            Desc = '创建本地用户并可选加入组（多个组用逗号分隔）。密码只在本进程内使用，不写日志。'
            Params = @(
                @{ Name = 'Name';        Label = '用户名'; Type = 'Text'; Width = 220 }
                @{ Name = 'Password';    Label = '密码（至少 6 位）'; Type = 'Password'; Width = 260 }
                @{ Name = 'Description'; Label = '描述（可空）'; Type = 'Text'; Width = 320 }
                @{ Name = 'Groups';      Label = '加入组（如 Administrators, Remote Desktop Users）'; Type = 'Text'; Width = 420 }
            )
            DryRun = $true
            Script = {
                param($P)
                New-GuiReadyLocalUser -Name ([string]$P['Name']) -Password ([string]$P['Password']) `
                    -Description ([string]$P['Description']) -Groups ([string]$P['Groups']) -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'account-update'; Group = '本地账户'; Name = '修改本地用户（启停 / 改密 / 组）'
            Desc = '启用或禁用用户、重设密码、改描述、调整所属组。留空的项目保持不动。'
            Params = @(
                @{ Name = 'Name';        Label = '用户名'; Type = 'Text'; Width = 220 }
                @{ Name = 'Enabled';     Label = '启用状态'; Type = 'Combo'; Default = 1; Options = @('保持不变', '启用', '禁用') }
                @{ Name = 'Password';    Label = '新密码（留空不改）'; Type = 'Password'; Width = 260 }
                @{ Name = 'Description'; Label = '新描述（留空不改）'; Type = 'Text'; Width = 320 }
                @{ Name = 'Groups';      Label = '新的组列表（留空不改；逗号分隔）'; Type = 'Text'; Width = 420 }
            )
            DryRun = $true
            Script = {
                param($P)
                $en = ''
                switch ([int]$P['Enabled']) { 2 { $en = 'true' } 3 { $en = 'false' } }
                Set-GuiReadyLocalUser -Name ([string]$P['Name']) -Enabled $en -Password ([string]$P['Password']) `
                    -Description ([string]$P['Description']) -Groups ([string]$P['Groups']) -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'account-remove'; Group = '本地账户'; Name = '删除本地用户'
            Desc = '删除本地用户。会挡住两种危险情况：当前正在使用的账户、最后一个可用的管理员。'
            Params = @( @{ Name = 'Name'; Label = '用户名'; Type = 'Text'; Width = 220 } )
            DryRun = $true
            Script = { param($P) Remove-GuiReadyLocalUser -Name ([string]$P['Name']) -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'session-list'; Group = '本地账户'; Name = '登录会话（只读）'
            Desc = '读取当前登录会话（quser）。没有交互会话时退回 Win32_ComputerSystem。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadySessions)
                Write-Head '登录会话'
                foreach ($s in $rows) { Write-Log ('{0} / 会话 {1} / ID {2} / {3} / 空闲 {4}' -f $s.User, $s.Session, $s.Id, $s.State, $s.Idle) 'INFO' }
                if ($rows.Count -eq 0) { Write-Log '没有读到登录会话' 'WARN' }
            }
        }

        # ---------------- 服务管理 ----------------
        [pscustomobject]@{
            Id = 'service-status'; Group = '服务管理'; Name = '服务列表（只读）'
            Desc = '列出全部服务及状态、启动类型、运行账户；可按名称/显示名过滤。'
            Params = @( @{ Name = 'Filter'; Label = '过滤关键词（可空）'; Type = 'Text'; Width = 240 } )
            DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadyServiceList -Filter ([string]$P['Filter']))
                Write-Head ('服务 · ' + $rows.Count + ' 条')
                foreach ($s in $rows) { Write-Log ('{0,-40} {1,-10} {2,-10} {3}' -f $s.Name, $s.State, $s.StartMode, $s.DisplayName) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'service-action'; Group = '服务管理'; Name = '服务启停 / 重启'
            Desc = '对一组服务执行启动 / 停止 / 重启 / 暂停 / 继续（逗号分隔）。系统关键服务（RpcSs 等）会被跳过。'
            Params = @(
                @{ Name = 'Names';  Label = '服务名（逗号分隔）'; Type = 'Text'; Width = 420 }
                @{ Name = 'Action'; Label = '操作'; Type = 'Combo'; Default = 3; Options = @('启动', '停止', '重启', '暂停', '继续') }
            )
            DryRun = $true
            Script = {
                param($P)
                $acts = @('start', 'stop', 'restart', 'pause', 'resume')
                $i = [int]$P['Action']; if ($i -lt 1 -or $i -gt 5) { $i = 3 }
                Set-GuiReadyServiceAction -Names ([string]$P['Names']) -Action $acts[$i - 1] -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'service-startup'; Group = '服务管理'; Name = '设置服务启动类型'
            Desc = '把一组服务设为自动 / 自动（延迟）/ 手动 / 禁用，改完回读。'
            Params = @(
                @{ Name = 'Names'; Label = '服务名（逗号分隔）'; Type = 'Text'; Width = 420 }
                @{ Name = 'Mode';  Label = '启动类型'; Type = 'Combo'; Default = 1; Options = @(
                    '自动', '自动（延迟启动）', '手动', '禁用') }
            )
            DryRun = $true
            Script = {
                param($P)
                $modes = @('auto', 'delayed', 'manual', 'disabled')
                $i = [int]$P['Mode']; if ($i -lt 1 -or $i -gt 4) { $i = 1 }
                Set-GuiReadyServiceStartup -Names ([string]$P['Names']) -Mode $modes[$i - 1] -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'service-recovery'; Group = '服务管理'; Name = '设置服务失败恢复'
            Desc = '服务崩溃后自动重启（sc.exe failure）。默认第一次失败 1 分钟后重启，1 天重置计数。'
            Params = @(
                @{ Name = 'Names';           Label = '服务名（逗号分隔）'; Type = 'Text'; Width = 420 }
                @{ Name = 'RestartMinutes';  Label = '失败后等待分钟数'; Type = 'Text'; Default = '1'; Width = 120 }
                @{ Name = 'ResetDays';       Label = '计数重置天数'; Type = 'Text'; Default = '1'; Width = 120 }
            )
            DryRun = $true
            Script = {
                param($P)
                $rm = 1; [void][int]::TryParse([string]$P['RestartMinutes'], [ref]$rm)
                $rd = 1; [void][int]::TryParse([string]$P['ResetDays'], [ref]$rd)
                Set-GuiReadyServiceRecovery -Names ([string]$P['Names']) -RestartMinutes $rm -ResetDays $rd -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'service-detail'; Group = '服务管理'; Name = '服务详情（依赖 / 失败策略）'
            Desc = '查看单个服务的路径、账户、依赖与被依赖、失败恢复配置。只读。'
            Params = @( @{ Name = 'Name'; Label = '服务名'; Type = 'Text'; Width = 240 } )
            DryRun = $false
            Script = {
                param($P)
                $d = Get-GuiReadyServiceDetail -Name ([string]$P['Name'])
                Write-Head ('服务 · ' + $d.Name)
                Write-Log ('显示名：' + $d.DisplayName) 'INFO'
                Write-Log ('状态：{0} / 启动类型：{1} / 账户：{2}' -f $d.State, $d.StartType, $d.Account) 'INFO'
                Write-Log ('路径：' + $d.PathName) 'INFO'
                Write-Log ('依赖：' + $d.DependsOn) 'INFO'
                Write-Log ('被依赖：' + $d.Dependents) 'INFO'
                Write-Log ('失败策略：' + $d.Failure) 'INFO'
            }
        }

        # ---------------- 防火墙 ----------------
        [pscustomobject]@{
            Id = 'firewall-status'; Group = '防火墙'; Name = '防火墙规则（只读）'
            Desc = '列出防火墙规则（默认入站，最多 300 条）与三个配置文件的开关状态。需要管理员。'
            Params = @(
                @{ Name = 'Direction'; Label = '方向'; Type = 'Combo'; Default = 1; Options = @('入站', '出站', '全部') }
                @{ Name = 'Filter';    Label = '关键词过滤（可空）'; Type = 'Text'; Width = 240 }
            )
            DryRun = $false
            Script = {
                param($P)
                $dirs = @('Inbound', 'Outbound', 'All')
                $i = [int]$P['Direction']; if ($i -lt 1 -or $i -gt 3) { $i = 1 }
                $rows = @(Get-GuiReadyFirewallRules -Direction $dirs[$i - 1] -Filter ([string]$P['Filter']))
                Write-Head ('防火墙规则 · ' + $rows.Count + ' 条')
                foreach ($r in $rows) {
                    Write-Log ('{0,-5} {1,-45} {2,-6} {3,-6} {4}' -f $(if ($r.Enabled) { '开' } else { '关' }), $r.DisplayName, $r.Action, $r.Protocol, $r.LocalPort) 'INFO'
                }
                foreach ($p in @(Get-GuiReadyFirewallProfile)) { Write-Log ('配置文件 {0}：启用={1} 入站默认={2}' -f $p.Name, $p.Enabled, $p.Inbound) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'firewall-open-port'; Group = '防火墙'; Name = '开放端口（新建入站规则）'
            Desc = '新建一条入站放行规则（TCP/UDP，可指定来源地址）。只放行端口，不会关闭防火墙。'
            Params = @(
                @{ Name = 'Name';          Label = '规则名'; Type = 'Text'; Width = 280 }
                @{ Name = 'Port';          Label = '端口（逗号分隔）'; Type = 'Text'; Width = 220 }
                @{ Name = 'Protocol';      Label = '协议'; Type = 'Combo'; Default = 1; Options = @('TCP', 'UDP') }
                @{ Name = 'RuleAction';    Label = '动作'; Type = 'Combo'; Default = 1; Options = @('允许', '阻止') }
                @{ Name = 'Profile';       Label = '配置文件'; Type = 'Combo'; Default = 1; Options = @('Any', 'Domain', 'Private', 'Public') }
                @{ Name = 'RemoteAddress'; Label = '来源地址（默认 Any）'; Type = 'Text'; Default = 'Any'; Width = 240 }
            )
            DryRun = $true
            Script = {
                param($P)
                $proto = if ([int]$P['Protocol'] -eq 2) { 'UDP' } else { 'TCP' }
                $ruleAction = if ([int]$P['RuleAction'] -eq 2) { 'Block' } else { 'Allow' }
                $profiles = @('Any', 'Domain', 'Private', 'Public')
                $pi = [int]$P['Profile']; if ($pi -lt 1 -or $pi -gt 4) { $pi = 1 }
                New-GuiReadyFirewallPort -Name ([string]$P['Name']) -Port ([string]$P['Port']) -Protocol $proto `
                    -Action $ruleAction -Profile $profiles[$pi - 1] -RemoteAddress ([string]$P['RemoteAddress']) -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'firewall-toggle'; Group = '防火墙'; Name = '启用 / 禁用防火墙规则'
            Desc = '按规则名启用或禁用一条规则（不删除）。'
            Params = @(
                @{ Name = 'Name';    Label = '规则名（显示名或内部名）'; Type = 'Text'; Width = 360 }
                @{ Name = 'Enabled'; Label = '操作'; Type = 'Combo'; Default = 1; Options = @('启用', '禁用') }
            )
            DryRun = $false
            Script = {
                param($P)
                Set-GuiReadyFirewallRuleEnabled -Name ([string]$P['Name']) -Enabled ([int]$P['Enabled'] -eq 1) -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'firewall-remove'; Group = '防火墙'; Name = '删除防火墙规则'
            Desc = '按内部名删除一条防火墙规则。系统自带规则删了可能影响功能，请确认后再删。'
            Params = @( @{ Name = 'Name'; Label = '规则内部名'; Type = 'Text'; Width = 360 } )
            DryRun = $true
            Script = { param($P) Remove-GuiReadyFirewallRule -Name ([string]$P['Name']) -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- 存储与备份 ----------------
        [pscustomobject]@{
            Id = 'storage-status'; Group = '存储与备份'; Name = '磁盘与卷（只读）'
            Desc = '列出磁盘、分区样式、健康状态与各卷容量 / 可用空间，以及卷影副本数量。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $st = Get-GuiReadyStorageStatus
                Write-Head '磁盘与卷'
                foreach ($d in $st.Disks) {
                    Write-Log ('磁盘 {0}: {1} / {2} GB / {3} / {4} / {5}' -f $d.Number, $d.FriendlyName, $d.SizeGB, $d.PartitionStyle, $d.HealthStatus, $d.BusType) 'INFO'
                }
                foreach ($v in $st.Volumes) {
                    Write-Log ('卷 {0}: {1} / {2} / {3} GB（可用 {4} GB，{5}%）' -f $v.DriveLetter, $v.Label, $v.FileSystem, $v.SizeGB, $v.FreeGB, $v.FreePercent) 'INFO'
                }
                Write-Log ('卷影副本：{0} 个' -f $st.Snapshots) 'INFO'
            }
        }
        [pscustomobject]@{
            Id = 'storage-extend'; Group = '存储与备份'; Name = '扩展卷（吃掉未分配空间）'
            Desc = '把指定盘符的分区扩展到磁盘可用最大值（Resize-Partition）。不会丢数据，但建议先备份。'
            Params = @( @{ Name = 'DriveLetter'; Label = '盘符（如 D）'; Type = 'Text'; Width = 120 } )
            DryRun = $true
            Script = { param($P) Set-GuiReadyVolumeAction -Action 'extend' -DriveLetter ([string]$P['DriveLetter']) -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'storage-format'; Group = '存储与备份'; Name = '格式化卷（会清空数据）'
            Desc = '格式化指定盘符为 NTFS / ReFS，可选卷标。这是破坏性操作，请确认盘符没有弄错。'
            Params = @(
                @{ Name = 'DriveLetter'; Label = '盘符（如 D）'; Type = 'Text'; Width = 120 }
                @{ Name = 'FileSystem';  Label = '文件系统'; Type = 'Combo'; Default = 1; Options = @('NTFS', 'ReFS', 'exFAT') }
                @{ Name = 'Label';       Label = '卷标（可空）'; Type = 'Text'; Width = 240 }
            )
            DryRun = $true
            Script = {
                param($P)
                $fsList = @('NTFS', 'ReFS', 'exFAT')
                $i = [int]$P['FileSystem']; if ($i -lt 1 -or $i -gt 3) { $i = 1 }
                Set-GuiReadyVolumeAction -Action 'format' -DriveLetter ([string]$P['DriveLetter']) -FileSystem $fsList[$i - 1] `
                    -Label ([string]$P['Label']) -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'storage-init'; Group = '存储与备份'; Name = '初始化磁盘（GPT）'
            Desc = '把 RAW 磁盘初始化为 GPT（新加的空盘常见）。已经有分区表的磁盘会被拒绝。'
            Params = @( @{ Name = 'DiskNumber'; Label = '磁盘编号'; Type = 'Text'; Width = 120 } )
            DryRun = $true
            Script = {
                param($P)
                $n = -1; [void][int]::TryParse([string]$P['DiskNumber'], [ref]$n)
                Set-GuiReadyVolumeAction -Action 'initialize' -DiskNumber $n -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'storage-cleanup'; Group = '存储与备份'; Name = '清理临时文件'
            Desc = '清理 %TEMP%、Windows\Temp 与 SoftwareDistribution\Download 里超过 N 天没动过的文件，返回释放空间。'
            Params = @( @{ Name = 'OlderThanDays'; Label = '只清理 N 天前的文件'; Type = 'Text'; Default = '1'; Width = 120 } )
            DryRun = $true
            Script = {
                param($P)
                $d = 1; [void][int]::TryParse([string]$P['OlderThanDays'], [ref]$d)
                Clear-GuiReadyTempSpace -OlderThanDays $d -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'vss-list'; Group = '存储与备份'; Name = '卷影副本（只读）'
            Desc = '列出本机卷影副本（VSS）：来源卷、创建时间、设备路径。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadyShadowCopies)
                Write-Head ('卷影副本 · ' + $rows.Count + ' 个')
                foreach ($s in $rows) { Write-Log ('{0}  {1}  {2}' -f $s.Created, $s.Volume, $s.Device) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'vss-create'; Group = '存储与备份'; Name = '创建卷影副本'
            Desc = '为指定卷（默认 C:\）创建一份 ClientAccessible 卷影副本，可用来取回误删文件。'
            Params = @( @{ Name = 'Volume'; Label = '卷（如 C:\）'; Type = 'Text'; Default = 'C:\'; Width = 120 } )
            DryRun = $true
            Script = { param($P) New-GuiReadyShadowCopy -Volume ([string]$P['Volume']) -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'vss-remove'; Group = '存储与备份'; Name = '删除卷影副本'
            Desc = '按 ID 删除一份卷影副本（ID 在「卷影副本」列表里看）。'
            Params = @( @{ Name = 'ShadowId'; Label = '卷影副本 ID'; Type = 'Text'; Width = 420 } )
            DryRun = $true
            Script = { param($P) Remove-GuiReadyShadowCopy -Id ([string]$P['ShadowId']) -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'wb-status'; Group = '存储与备份'; Name = 'Windows 备份状态（只读）'
            Desc = '读取 Windows Server Backup 的上次 / 下次备份、版本数与目标盘；没装功能时会如实说明。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $s = Get-GuiReadyWbStatus
                Write-Head 'Windows Server Backup'
                if (-not $s.Installed) { Write-Log '本机没有安装 Windows Server Backup（可用「安装备份功能」）' 'WARN'; return }
                Write-Log ('上次备份：{0}  结果码 {1}' -f $s.LastTime, $s.LastResult) 'INFO'
                Write-Log ('下次备份：{0} / 版本数 {1}' -f $s.NextTime, $s.Versions) 'INFO'
                Write-Log ('目标：{0} / 计划：{1}' -f $s.Target, $s.Schedule) 'INFO'
            }
        }
        [pscustomobject]@{
            Id = 'wb-start'; Group = '存储与备份'; Name = '立即执行 Windows 备份'
            Desc = '按现有备份策略立即跑一次（Start-WBBackup）。需要先装功能并配置过策略。'
            Params = @(); DryRun = $true
            Script = { param($P) Start-GuiReadyWbBackup -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'wb-history'; Group = '存储与备份'; Name = 'Windows 备份历史（只读）'
            Desc = '读取最近的备份版本（时间、目标、结果）。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadyWbHistory -Max 20)
                Write-Head '备份历史'
                foreach ($r in $rows) { Write-Log ('{0}  {1}  {2}' -f $r.Time, $r.Target, $r.Result) 'INFO' }
                if ($rows.Count -eq 0) { Write-Log '没有读到备份记录' 'WARN' }
            }
        }
        [pscustomobject]@{
            Id = 'wb-install'; Group = '存储与备份'; Name = '安装备份功能'
            Desc = '安装 Windows-Server-Backup 功能（不会自动配置策略）。'
            Params = @(); DryRun = $true
            Script = { param($P) Install-GuiReadyWbFeature -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- 系统任务 ----------------
        [pscustomobject]@{
            Id = 'systask-status'; Group = '系统任务'; Name = '系统计划任务（只读）'
            Desc = '列出 Windows 计划任务（默认隐藏本工具自建的 ScmOps-*），含状态、最近运行与结果码。'
            Params = @(
                @{ Name = 'Filter';     Label = '关键词过滤（可空）'; Type = 'Text'; Width = 240 }
                @{ Name = 'IncludeOwn'; Label = '包含本工具自建任务'; Type = 'Check'; Default = $false }
            )
            DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadySystemTasks -Filter ([string]$P['Filter']))
                $own = $false; if ($P.ContainsKey('IncludeOwn')) { $own = [bool]$P['IncludeOwn'] }
                if (-not $own) { $rows = @($rows | Where-Object { -not $_.IsOwn }) }
                Write-Head ('系统计划任务 · ' + $rows.Count + ' 条')
                foreach ($t in $rows) { Write-Log ('{0,-10} {1}{2}' -f $t.State, $t.Path, $t.Name) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'systask-detail'; Group = '系统任务'; Name = '计划任务详情'
            Desc = '查看任务触发器、动作、运行账户、最近结果。'
            Params = @(
                @{ Name = 'Name';     Label = '任务名'; Type = 'Text'; Width = 320 }
                @{ Name = 'TaskPath'; Label = '路径（默认 \）'; Type = 'Text'; Default = '\'; Width = 200 }
            )
            DryRun = $false
            Script = {
                param($P)
                $d = Get-GuiReadySystemTaskDetail -Name ([string]$P['Name']) -TaskPath ([string]$P['TaskPath'])
                Write-Head ('计划任务 · ' + $d.Path + $d.Name)
                Write-Log ('状态：{0} / 账户：{1} / 权限：{2}' -f $d.State, $d.UserId, $d.RunLevel) 'INFO'
                Write-Log ('触发器：' + $d.Triggers) 'INFO'
                Write-Log ('动作：' + $d.Actions) 'INFO'
                Write-Log ('最近：{0}（结果 {1}） / 下次：{2}' -f $d.LastRun, $d.LastResult, $d.NextRun) 'INFO'
            }
        }
        [pscustomobject]@{
            Id = 'systask-action'; Group = '系统任务'; Name = '系统计划任务操作'
            Desc = '启用 / 禁用 / 立即运行 / 停止 / 删除系统计划任务。ScmOps-* 不允许在这里删（会留下孤儿记录）。'
            Params = @(
                @{ Name = 'Name';       Label = '任务名'; Type = 'Text'; Width = 320 }
                @{ Name = 'TaskPath';   Label = '路径（默认 \）'; Type = 'Text'; Default = '\'; Width = 200 }
                @{ Name = 'TaskAction'; Label = '操作'; Type = 'Combo'; Default = 3; Options = @('启用', '禁用', '立即运行', '停止', '删除') }
            )
            DryRun = $true
            Script = {
                param($P)
                $acts = @('enable', 'disable', 'run', 'stop', 'remove')
                $i = [int]$P['TaskAction']; if ($i -lt 1 -or $i -gt 5) { $i = 3 }
                Set-GuiReadySystemTaskAction -Name ([string]$P['Name']) -TaskPath ([string]$P['TaskPath']) `
                    -Action $acts[$i - 1] -DryRun:([bool]$P['DryRun'])
            }
        }

        # ---------------- 角色工具 ----------------
        [pscustomobject]@{
            Id = 'roletools-status'; Group = '角色工具'; Name = '检测 Hyper-V / IIS / 打印 / 共享'
            Desc = '检查本机装了哪些角色工具（只读），界面据此显示或隐藏对应视图。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $a = Get-GuiReadyRoleToolsAvailability
                Write-Head '角色工具可用性'
                Write-Log ('Hyper-V={0} / IIS={1} / 打印={2} / SMB 共享={3}' -f $a.HyperV, $a.IIS, $a.Print, $a.Smb) 'INFO'
            }
        }
        [pscustomobject]@{
            Id = 'hyperv-status'; Group = '角色工具'; Name = 'Hyper-V 虚拟机（只读）'
            Desc = '列出虚拟机状态、CPU、内存与运行时长，以及快照。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadyVmList)
                Write-Head ('Hyper-V 虚拟机 · ' + $rows.Count)
                foreach ($v in $rows) { Write-Log ('{0,-24} {1,-10} CPU {2}% MEM {3} MB {4}' -f $v.Name, $v.State, $v.CPU, $v.MemoryMB, $v.Uptime) 'INFO' }
                foreach ($s in @(Get-GuiReadyVmSnapshots)) { Write-Log ('快照：{0} / {1} / {2}' -f $s.VM, $s.Name, $s.Created) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'hyperv-action'; Group = '角色工具'; Name = 'Hyper-V 虚拟机操作'
            Desc = '启动 / 关机 / 强制关闭 / 保存 / 重启 / 暂停 / 恢复。'
            Params = @(
                @{ Name = 'Name';     Label = '虚拟机名'; Type = 'Text'; Width = 280 }
                @{ Name = 'VmAction'; Label = '操作'; Type = 'Combo'; Default = 1; Options = @('启动', '关机', '强制关闭', '保存', '重启', '暂停', '恢复') }
            )
            DryRun = $true
            Script = {
                param($P)
                $acts = @('start', 'shutdown', 'stop', 'save', 'restart', 'pause', 'resume')
                $i = [int]$P['VmAction']; if ($i -lt 1 -or $i -gt 7) { $i = 1 }
                Set-GuiReadyVmAction -Name ([string]$P['Name']) -Action $acts[$i - 1] -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'hyperv-snapshot'; Group = '角色工具'; Name = 'Hyper-V 快照'
            Desc = '创建 / 应用（还原）/ 删除虚拟机快照。'
            Params = @(
                @{ Name = 'SnapshotAction'; Label = '操作'; Type = 'Combo'; Default = 1; Options = @('创建', '应用（还原）', '删除') }
                @{ Name = 'VmName';         Label = '虚拟机名'; Type = 'Text'; Width = 260 }
                @{ Name = 'SnapshotName';   Label = '快照名'; Type = 'Text'; Width = 260 }
            )
            DryRun = $true
            Script = {
                param($P)
                $acts = @('create', 'apply', 'remove')
                $i = [int]$P['SnapshotAction']; if ($i -lt 1 -or $i -gt 3) { $i = 1 }
                Invoke-GuiReadyVmSnapshot -Action $acts[$i - 1] -VmName ([string]$P['VmName']) `
                    -SnapshotName ([string]$P['SnapshotName']) -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'iis-status'; Group = '角色工具'; Name = 'IIS 站点与应用池（只读）'
            Desc = '列出 IIS 站点（状态、物理路径、绑定）与应用池。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $r = Get-GuiReadyIisSites
                Write-Head ('IIS 站点 · ' + @($r.Sites).Count)
                foreach ($s in $r.Sites) { Write-Log ('{0,-24} {1,-10} {2}' -f $s.Name, $s.State, $s.Bindings) 'INFO' }
                foreach ($p in $r.Pools) { Write-Log ('应用池 {0,-20} {1}' -f $p.Name, $p.State) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'iis-action'; Group = '角色工具'; Name = 'IIS 站点 / 应用池操作'
            Desc = '启动 / 停止 / 重启站点，回收 / 启动 / 停止应用池。'
            Params = @(
                @{ Name = 'IisAction'; Label = '操作'; Type = 'Combo'; Default = 3; Options = @(
                    '启动站点', '停止站点', '重启站点', '回收应用池', '启动应用池', '停止应用池') }
                @{ Name = 'Name';      Label = '站点或应用池名'; Type = 'Text'; Width = 280 }
            )
            DryRun = $true
            Script = {
                param($P)
                $acts = @('site-start', 'site-stop', 'site-restart', 'pool-recycle', 'pool-start', 'pool-stop')
                $i = [int]$P['IisAction']; if ($i -lt 1 -or $i -gt 6) { $i = 3 }
                Set-GuiReadyIisAction -Action $acts[$i - 1] -Name ([string]$P['Name']) -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'print-status'; Group = '角色工具'; Name = '打印机与队列（只读）'
            Desc = '列出打印机、驱动、端口、共享状态与待处理作业数。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadyPrinters)
                Write-Head ('打印机 · ' + $rows.Count)
                foreach ($p in $rows) { Write-Log ('{0,-28} {1,-12} 作业 {2} 共享={3}' -f $p.Name, $p.Status, $p.Jobs, $p.Shared) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'print-action'; Group = '角色工具'; Name = '打印机操作'
            Desc = '暂停 / 恢复打印机，或清空打印队列。'
            Params = @(
                @{ Name = 'Name';        Label = '打印机名'; Type = 'Text'; Width = 280 }
                @{ Name = 'PrintAction'; Label = '操作'; Type = 'Combo'; Default = 3; Options = @('暂停', '恢复', '清空队列') }
            )
            DryRun = $true
            Script = {
                param($P)
                $acts = @('pause', 'resume', 'clear-jobs')
                $i = [int]$P['PrintAction']; if ($i -lt 1 -or $i -gt 3) { $i = 3 }
                Set-GuiReadyPrinterAction -Name ([string]$P['Name']) -Action $acts[$i - 1] -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'share-status'; Group = '角色工具'; Name = 'SMB 共享 / 会话 / 打开文件（只读）'
            Desc = '列出共享（含路径与在线用户）、当前会话和打开的文件句柄。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $rows = @(Get-GuiReadySmbShares)
                Write-Head ('SMB 共享 · ' + $rows.Count)
                foreach ($s in $rows) { Write-Log ('{0,-24} {1,-40} 用户 {2}' -f $s.Name, $s.Path, $s.Users) 'INFO' }
                foreach ($x in @(Get-GuiReadySmbSessions)) { Write-Log ('会话：{0} / {1} / 打开 {2}' -f $x.Client, $x.User, $x.Opens) 'INFO' }
                foreach ($f in @(Get-GuiReadySmbOpenFiles)) { Write-Log ('打开：{0} / {1} / {2}' -f $f.Client, $f.User, $f.Path) 'INFO' }
            }
        }
        [pscustomobject]@{
            Id = 'share-add'; Group = '角色工具'; Name = '新建 SMB 共享'
            Desc = '把目录共享出去，默认给 Administrators 完全控制。'
            Params = @(
                @{ Name = 'Name';        Label = '共享名'; Type = 'Text'; Width = 220 }
                @{ Name = 'Path';        Label = '目录'; Type = 'Text'; Width = 420; Browse = 'Folder' }
                @{ Name = 'Description'; Label = '描述（可空）'; Type = 'Text'; Width = 320 }
                @{ Name = 'FullAccess';  Label = '完全控制（账户或组）'; Type = 'Text'; Default = 'Administrators'; Width = 260 }
            )
            DryRun = $true
            Script = {
                param($P)
                New-GuiReadySmbShare -Name ([string]$P['Name']) -Path ([string]$P['Path']) `
                    -Description ([string]$P['Description']) -FullAccess ([string]$P['FullAccess']) -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'share-remove'; Group = '角色工具'; Name = '删除 SMB 共享'
            Desc = '删除共享（不动目录内容）。系统特殊共享（C$ / IPC$ 等）会被拒绝。'
            Params = @( @{ Name = 'Name'; Label = '共享名'; Type = 'Text'; Width = 240 } )
            DryRun = $true
            Script = { param($P) Remove-GuiReadySmbShare -Name ([string]$P['Name']) -DryRun:([bool]$P['DryRun']) }
        }
        [pscustomobject]@{
            Id = 'share-close'; Group = '角色工具'; Name = '断开 SMB 打开的文件'
            Desc = '按 FileId 强制关闭一个被占用的文件句柄（解决「文件正在使用」）。'
            Params = @( @{ Name = 'FileId'; Label = 'FileId（在共享列表里看）'; Type = 'Text'; Width = 320 } )
            DryRun = $true
            Script = { param($P) Close-GuiReadySmbOpenFile -FileId ([string]$P['FileId']) -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- 通知 ----------------
        [pscustomobject]@{
            Id = 'notify-status'; Group = '通知'; Name = '通知配置与最近记录（只读）'
            Desc = '查看 SMTP / Webhook 配置（密码不回显）与最近 20 条通知记录。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $c = Get-GuiReadyNotifyConfig
                Write-Head '通知配置'
                Write-Log ('启用={0} SMTP={1}:{2} 收件人={3}' -f $c.Enabled, $c.SmtpServer, $c.SmtpPort, $c.SmtpTo) 'INFO'
                Write-Log ('Webhook={0} 静默时段={1}-{2}' -f $c.WebhookType, $c.QuietFrom, $c.QuietTo) 'INFO'
                foreach ($l in @(Get-GuiReadyNotifyLog -Max 10)) {
                    Write-Log ('{0} [{1}] {2} → {3}' -f $l.Time, $l.Level, $l.Title, $(if ($l.Sent) { $l.Channels } else { '未发送：' + $l.Error })) 'INFO'
                }
            }
        }
        [pscustomobject]@{
            Id = 'notify-config'; Group = '通知'; Name = '保存通知配置'
            Desc = '配置 SMTP 与 / 或 Webhook。密码用 DPAPI（LocalMachine）加密保存；留空的项保持原值。'
            Params = @(
                @{ Name = 'Enabled';     Label = '启用通知'; Type = 'Combo'; Default = 1; Options = @('保持不变', '启用', '禁用') }
                @{ Name = 'SmtpServer';  Label = 'SMTP 服务器'; Type = 'Text'; Width = 260 }
                @{ Name = 'SmtpPort';    Label = 'SMTP 端口'; Type = 'Text'; Default = '587'; Width = 100 }
                @{ Name = 'SmtpSsl';     Label = '使用 SSL'; Type = 'Combo'; Default = 1; Options = @('保持不变', '是', '否') }
                @{ Name = 'SmtpUser';    Label = 'SMTP 用户名'; Type = 'Text'; Width = 260 }
                @{ Name = 'SmtpPassword'; Label = 'SMTP 密码（留空不改）'; Type = 'Password'; Width = 260 }
                @{ Name = 'SmtpFrom';    Label = '发件人'; Type = 'Text'; Width = 260 }
                @{ Name = 'SmtpTo';      Label = '收件人（逗号分隔）'; Type = 'Text'; Width = 360 }
                @{ Name = 'WebhookType'; Label = 'Webhook 类型'; Type = 'Combo'; Default = 1; Options = @(
                    '保持不变', 'generic（通用 JSON）', 'dingtalk（钉钉）', 'feishu（飞书）', 'wecom（企业微信）') }
                @{ Name = 'WebhookUrl';  Label = 'Webhook 地址'; Type = 'Text'; Width = 480 }
                @{ Name = 'QuietFrom';   Label = '静默开始（HH:mm，可空）'; Type = 'Text'; Width = 120 }
                @{ Name = 'QuietTo';     Label = '静默结束（HH:mm，可空）'; Type = 'Text'; Width = 120 }
            )
            DryRun = $true
            Script = {
                param($P)
                $en = ''
                switch ([int]$P['Enabled']) { 2 { $en = 'true' } 3 { $en = 'false' } }
                $ssl = ''
                switch ([int]$P['SmtpSsl']) { 2 { $ssl = 'true' } 3 { $ssl = 'false' } }
                $types = @('', 'generic', 'dingtalk', 'feishu', 'wecom')
                $ti = [int]$P['WebhookType']; if ($ti -lt 1 -or $ti -gt 5) { $ti = 1 }
                Set-GuiReadyNotifyConfig -Enabled $en -SmtpServer ([string]$P['SmtpServer']) -SmtpPort ([string]$P['SmtpPort']) `
                    -SmtpSsl $ssl -SmtpUser ([string]$P['SmtpUser']) -SmtpPassword ([string]$P['SmtpPassword']) `
                    -SmtpFrom ([string]$P['SmtpFrom']) -SmtpTo ([string]$P['SmtpTo']) `
                    -WebhookType $types[$ti - 1] -WebhookUrl ([string]$P['WebhookUrl']) `
                    -QuietFrom ([string]$P['QuietFrom']) -QuietTo ([string]$P['QuietTo']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'notify-test'; Group = '通知'; Name = '发送测试通知'
            Desc = '按当前配置发一条测试消息（忽略静默时段）。'
            Params = @(); DryRun = $false
            Script = {
                param($P)
                $r = Send-GuiReadyNotify -Title ('测试通知（' + $env:COMPUTERNAME + '）') -Text '如果你看到这条消息，说明通知渠道配置正确。' -Level 'Info' -IgnoreQuiet
                Write-Head '测试通知'
                if ($r.Sent) { Write-Log ('已通过 ' + ($r.Channels -join ', ') + ' 发送') 'OK' }
                else { Write-Log ('未发送：' + $r.Error) 'WARN' }
            }
        }
        [pscustomobject]@{
            Id = 'notify-send'; Group = '通知'; Name = '发送自定义通知'
            Desc = '把一条消息发到已配置的渠道（钉钉 / 飞书 / 企业微信 / 通用 Webhook / 邮件）。'
            Params = @(
                @{ Name = 'Title'; Label = '标题'; Type = 'Text'; Width = 320; Default = 'SCM 通知' }
                @{ Name = 'Text';  Label = '正文'; Type = 'Multi'; Width = 480 }
                @{ Name = 'Level'; Label = '级别'; Type = 'Combo'; Default = 1; Options = @('Info', 'Warn', 'Error') }
            )
            DryRun = $false
            Script = {
                param($P)
                $levels = @('Info', 'Warn', 'Error')
                $i = [int]$P['Level']; if ($i -lt 1 -or $i -gt 3) { $i = 1 }
                $r = Send-GuiReadyNotify -Title ([string]$P['Title']) -Text ([string]$P['Text']) -Level $levels[$i - 1]
                if ($r.Sent) { Write-Log ('已发送：' + ($r.Channels -join ', ')) 'OK' }
                else { Write-Log ('未发送：' + $r.Error) 'WARN' }
            }
        }

        # ---------------- SCM附属（TUI_TOOL） ----------------
        [pscustomobject]@{
            Id = 'plugin-download-github'; Group = 'SCM附属'; Name = '下载附属工具发行包（GitHub 线路）'
            Desc = '从 GitHub Releases 下载对应工具的发行包 zip（scterm.exe / scm-top 脚本 / textm.exe / craftdock.exe），校验 zip 魔数后解压到 payload\plugins\<工具>；已安装时整体替换，失败保留旧版本。不下载源码。'
            Params = @(
                @{ Name = 'Id'; Label = '工具'; Type = 'Combo'; Default = 1; Options = @('scterm（终端）', 'scm-top（TUI 监控）', 'Textm（文本 / 代码编辑）', 'CraftDock（终端服务器管理）') }
            )
            DryRun = $true
            Script = {
                param($P)
                $ids = @('scterm', 'tuimonitor', 'textm', 'craftdock')
                $v = [string]$P['Id']
                $n = 0
                $id = $(if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le $ids.Count) { $ids[$n - 1] } else { $v })
                if ($ids -notcontains $id) { $id = 'scterm' }
                Install-GuiReadyPlugin -Id $id -Source 'github' -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'plugin-download-gitee'; Group = 'SCM附属'; Name = '下载附属工具发行包（Gitee 线路）'
            Desc = '从 Gitee Releases 下载对应工具的发行包 zip（scterm.exe / scm-top 脚本 / textm.exe / craftdock.exe），校验后解压到 payload\plugins\<工具>。Gitee 仓库不放源码，两条线路下载的都是发行包。'
            Params = @(
                @{ Name = 'Id'; Label = '工具'; Type = 'Combo'; Default = 1; Options = @('scterm（终端）', 'scm-top（TUI 监控）', 'Textm（文本 / 代码编辑）', 'CraftDock（终端服务器管理）') }
            )
            DryRun = $true
            Script = {
                param($P)
                $ids = @('scterm', 'tuimonitor', 'textm', 'craftdock')
                $v = [string]$P['Id']
                $n = 0
                $id = $(if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le $ids.Count) { $ids[$n - 1] } else { $v })
                if ($ids -notcontains $id) { $id = 'scterm' }
                Install-GuiReadyPlugin -Id $id -Source 'gitee' -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        # ---------------- 性能历史 ----------------
        [pscustomobject]@{
            Id = 'metrics-sample'; Group = '性能历史'; Name = '采集一次性能样本'
            Desc = '采集 CPU / 内存 / 系统盘 / 网络 / 进程数，追加到 state\metrics\samples-yyyyMM.csv。'
            Params = @(); DryRun = $false
            Script = { param($P) Save-GuiReadyMetricsSample | Out-Null }
        }
        [pscustomobject]@{
            Id = 'metrics-report'; Group = '性能历史'; Name = '生成性能报表（HTML）'
            Desc = '按最近 N 天的样本生成内联 SVG 的 HTML 报表，保存到 reports\metrics-*.html。'
            Params = @(@{ Name = 'Days'; Label = '统计天数'; Type = 'Text'; Width = 120; Default = '7' })
            DryRun = $false
            Script = { param($P) $d = 7; [void][int]::TryParse([string]$P['Days'], [ref]$d); New-GuiReadyMetricsReport -Days $d | Out-Null }
        }
        [pscustomobject]@{
            Id = 'metrics-task-install'; Group = '性能历史'; Name = '安装性能采样计划任务'
            Desc = '注册 ScmPlus-Metrics，按指定间隔在后台采样（SYSTEM 身份）。'
            Params = @(@{ Name = 'IntervalMin'; Label = '采样间隔（分钟）'; Type = 'Text'; Width = 120; Default = '5' })
            DryRun = $true
            Script = { param($P) $m = 5; [void][int]::TryParse([string]$P['IntervalMin'], [ref]$m); Install-GuiReadyMetricsTask -IntervalMin $m -DryRun:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'metrics-task-remove'; Group = '性能历史'; Name = '移除性能采样计划任务'
            Desc = '删除 ScmPlus-Metrics。'
            Params = @(); DryRun = $true
            Script = { param($P) Remove-GuiReadyMetricsTask -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- 告警规则 ----------------
        [pscustomobject]@{
            Id = 'alert-rule-add'; Group = '告警规则'; Name = '添加告警规则'
            Desc = '按指标阈值或事件 ID 添加规则；触发后发通知，或执行指定动作。'
            Params = @(
                @{ Name = 'Name';      Label = '规则名称'; Type = 'Text'; Width = 260 }
                @{ Name = 'Metric';    Label = '指标'; Type = 'Combo'; Default = 1; Options = @('CPU %', '内存 %', '系统盘可用 GB', '系统盘使用率 %', '事件日志') }
                @{ Name = 'Operator';  Label = '条件'; Type = 'Combo'; Default = 1; Options = @('大于 gt', '小于 lt') }
                @{ Name = 'Threshold'; Label = '阈值'; Type = 'Text'; Width = 120; Default = '90' }
                @{ Name = 'DurationMin'; Label = '持续分钟'; Type = 'Text'; Width = 120; Default = '5' }
                @{ Name = 'EventId';   Label = '事件 ID（逗号分隔，事件规则用）'; Type = 'Text'; Width = 320 }
                @{ Name = 'CooldownMin'; Label = '冷却分钟'; Type = 'Text'; Width = 120; Default = '30' }
                @{ Name = 'ActionId';  Label = '触发动作 ID（留空 = 仅通知）'; Type = 'Text'; Width = 320 }
            )
            DryRun = $false
            Script = {
                param($P)
                $metrics = @('cpu', 'mem', 'diskfree', 'diskpct', 'event')
                $mi = [int]$P['Metric']; if ($mi -lt 1 -or $mi -gt 5) { $mi = 1 }
                $op = if ([int]$P['Operator'] -eq 2) { 'lt' } else { 'gt' }
                $th = 0.0; [void][double]::TryParse([string]$P['Threshold'], [ref]$th)
                $dur = 5; [void][int]::TryParse([string]$P['DurationMin'], [ref]$dur)
                $cool = 30; [void][int]::TryParse([string]$P['CooldownMin'], [ref]$cool)
                $actionId = [string]$P['ActionId']
                Add-GuiReadyAlertRule -Name ([string]$P['Name']) -Metric $metrics[$mi - 1] -Operator $op `
                    -Threshold $th -DurationMin $dur -EventId ([string]$P['EventId']) `
                    -Action $(if ($actionId) { 'action' } else { 'notify' }) -ActionId $actionId -CooldownMin $cool | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'alert-rule-remove'; Group = '告警规则'; Name = '删除告警规则'
            Desc = '按规则 Id 删除。'
            Params = @(@{ Name = 'Id'; Label = '规则 Id'; Type = 'Text'; Width = 260 })
            DryRun = $true
            Script = { param($P) Remove-GuiReadyAlertRule -Id ([string]$P['Id']) }
        }
        [pscustomobject]@{
            Id = 'alert-rule-toggle'; Group = '告警规则'; Name = '启用 / 停用告警规则'
            Desc = '切换规则的启用状态。'
            Params = @(
                @{ Name = 'Id'; Label = '规则 Id'; Type = 'Text'; Width = 260 }
                @{ Name = 'Enabled'; Label = '启用'; Type = 'Check'; Default = $true }
            )
            DryRun = $true
            Script = { param($P) Set-GuiReadyAlertRuleEnabled -Id ([string]$P['Id']) -Enabled ([bool]$P['Enabled']) }
        }
        [pscustomobject]@{
            Id = 'alert-check'; Group = '告警规则'; Name = '立即检查告警'
            Desc = '按当前规则检查指标与事件；触发时发通知或执行动作。'
            Params = @(); DryRun = $true
            Script = { param($P) Invoke-GuiReadyAlertCheck -DryRun:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'alert-task-install'; Group = '告警规则'; Name = '安装告警检查计划任务'
            Desc = '注册 ScmPlus-Alerts，按间隔检查指标与事件。'
            Params = @(@{ Name = 'IntervalMin'; Label = '检查间隔（分钟）'; Type = 'Text'; Width = 120; Default = '2' })
            DryRun = $true
            Script = { param($P) $m = 2; [void][int]::TryParse([string]$P['IntervalMin'], [ref]$m); Install-GuiReadyAlertTask -IntervalMin $m -DryRun:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'event-subscribe'; Group = '告警规则'; Name = '订阅关键事件'
            Desc = '安装 ScmPlus-Alerts，定期检查意外关机、服务崩溃、登录失败等事件并通知。'
            Params = @(@{ Name = 'IntervalMin'; Label = '检查间隔（分钟）'; Type = 'Text'; Width = 120; Default = '2' })
            DryRun = $true
            Script = { param($P) $m = 2; [void][int]::TryParse([string]$P['IntervalMin'], [ref]$m); Install-GuiReadyAlertTask -IntervalMin $m -DryRun:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'event-unsubscribe'; Group = '告警规则'; Name = '取消事件订阅'
            Desc = '删除 ScmPlus-Alerts（同时停止指标告警检查）。'
            Params = @(); DryRun = $true
            Script = { param($P) Remove-GuiReadyAlertTask -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- 证书管理 ----------------
        [pscustomobject]@{
            Id = 'cert-import'; Group = '证书管理'; Name = '导入证书'
            Desc = '导入 .pfx/.p12（需密码）或 .cer 到本机证书存储。'
            Params = @(
                @{ Name = 'Path'; Label = '证书文件'; Type = 'Text'; Width = 520; Browse = 'File' }
                @{ Name = 'Password'; Label = '密码（pfx 用）'; Type = 'Password'; Width = 260 }
                @{ Name = 'Location'; Label = '存储'; Type = 'Combo'; Default = 1; Options = @('My（个人）', 'Root（受信任根）', 'CA（中间 CA）', 'TrustedPeople（受信任人）') }
            )
            DryRun = $true
            Script = {
                param($P)
                $locs = @('My', 'Root', 'CA', 'TrustedPeople')
                $li = [int]$P['Location']; if ($li -lt 1 -or $li -gt 4) { $li = 1 }
                Import-GuiReadyCertificate -Path ([string]$P['Path']) -Password ([string]$P['Password']) -Location $locs[$li - 1] -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'cert-export'; Group = '证书管理'; Name = '导出证书'
            Desc = '按指纹导出为 .cer（公钥）或 .pfx（含私钥，需要密码）。'
            Params = @(
                @{ Name = 'Thumbprint'; Label = '指纹'; Type = 'Text'; Width = 360 }
                @{ Name = 'Path'; Label = '保存到'; Type = 'Text'; Width = 520; Browse = 'File' }
                @{ Name = 'Format'; Label = '格式'; Type = 'Combo'; Default = 1; Options = @('cer（公钥）', 'pfx（含私钥）') }
                @{ Name = 'Password'; Label = 'pfx 密码'; Type = 'Password'; Width = 260 }
                @{ Name = 'Location'; Label = '存储'; Type = 'Combo'; Default = 1; Options = @('My（个人）', 'Root（受信任根）', 'CA（中间 CA）', 'TrustedPeople（受信任人）') }
            )
            DryRun = $true
            Script = {
                param($P)
                $locs = @('My', 'Root', 'CA', 'TrustedPeople')
                $li = [int]$P['Location']; if ($li -lt 1 -or $li -gt 4) { $li = 1 }
                $fmt = if ([int]$P['Format'] -eq 2) { 'pfx' } else { 'cer' }
                Export-GuiReadyCertificate -Thumbprint ([string]$P['Thumbprint']) -Path ([string]$P['Path']) -Format $fmt `
                    -Password ([string]$P['Password']) -Location $locs[$li - 1] -DryRun:([bool]$P['DryRun'])
            }
        }
        [pscustomobject]@{
            Id = 'cert-remove'; Group = '证书管理'; Name = '删除证书'
            Desc = '从本机证书存储删除指定指纹的证书（不可撤销）。'
            Params = @(
                @{ Name = 'Thumbprint'; Label = '指纹'; Type = 'Text'; Width = 360 }
                @{ Name = 'Location'; Label = '存储'; Type = 'Combo'; Default = 1; Options = @('My（个人）', 'Root（受信任根）', 'CA（中间 CA）', 'TrustedPeople（受信任人）') }
            )
            DryRun = $true
            Script = {
                param($P)
                $locs = @('My', 'Root', 'CA', 'TrustedPeople')
                $li = [int]$P['Location']; if ($li -lt 1 -or $li -gt 4) { $li = 1 }
                Remove-GuiReadyCertificate -Thumbprint ([string]$P['Thumbprint']) -Location $locs[$li - 1] -DryRun:([bool]$P['DryRun'])
            }
        }

        # ---------------- 驱动与硬件 ----------------
        [pscustomobject]@{
            Id = 'driver-export'; Group = '驱动与硬件'; Name = '导出驱动'
            Desc = '用 pnputil 把驱动导出到目录，便于重装或迁移。'
            Params = @(@{ Name = 'Path'; Label = '导出目录'; Type = 'Text'; Width = 520; Browse = 'Folder' })
            DryRun = $true
            Script = { param($P) Export-GuiReadyDrivers -Path ([string]$P['Path']) -DryRun:([bool]$P['DryRun']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'driver-import'; Group = '驱动与硬件'; Name = '导入驱动'
            Desc = '用 pnputil /add-driver 从目录安装驱动。'
            Params = @(@{ Name = 'Path'; Label = '驱动目录'; Type = 'Text'; Width = 520; Browse = 'Folder' })
            DryRun = $true
            Script = { param($P) Import-GuiReadyDrivers -Path ([string]$P['Path']) -DryRun:([bool]$P['DryRun']) | Out-Null }
        }

        # ---------------- 启动项 ----------------
        [pscustomobject]@{
            Id = 'startup-toggle'; Group = '启动项'; Name = '启用 / 禁用启动项'
            Desc = '支持注册表 Run/RunOnce、启动文件夹、服务、计划任务；禁用时会备份原值，可恢复。'
            Params = @(
                @{ Name = 'Id'; Label = '启动项 Id（从列表复制）'; Type = 'Text'; Width = 520 }
                @{ Name = 'Enabled'; Label = '启用'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = { param($P) Set-GuiReadyStartupItem -Id ([string]$P['Id']) -Enabled ([bool]$P['Enabled']) -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- 备份增强 ----------------
        [pscustomobject]@{
            Id = 'sysbackup-create'; Group = '备份增强'; Name = '创建系统状态备份'
            Desc = '打包注册表关键分支、证书、计划任务、防火墙策略与资产清单；驱动体积大，默认不包含。'
            Params = @(
                @{ Name = 'OutDir'; Label = '输出目录（留空 = backup\sysbackup）'; Type = 'Text'; Width = 420 }
                @{ Name = 'WithDrivers'; Label = '包含驱动（体积大）'; Type = 'Check'; Default = $false }
                @{ Name = 'FullRegistry'; Label = '导出完整注册表（含 SOFTWARE）'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                New-GuiReadySysBackup -OutDir ([string]$P['OutDir']) -WithDrivers:([bool]$P['WithDrivers']) `
                    -FullRegistry:([bool]$P['FullRegistry']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'sysbackup-share'; Group = '备份增强'; Name = '复制备份到共享'
            Desc = '复制指定备份到 SMB/NAS 目录，校验 SHA256，并按保留份数清理旧备份。'
            Params = @(
                @{ Name = 'File'; Label = '备份文件'; Type = 'Text'; Width = 520; Browse = 'File' }
                @{ Name = 'Share'; Label = '共享目录（如 \\nas\backup）'; Type = 'Text'; Width = 420 }
                @{ Name = 'Keep'; Label = '保留份数'; Type = 'Text'; Width = 100; Default = '5' }
            )
            DryRun = $true
            Script = {
                param($P)
                $k = 5; [void][int]::TryParse([string]$P['Keep'], [ref]$k)
                Copy-GuiReadySysBackupToShare -File ([string]$P['File']) -Share ([string]$P['Share']) -Keep $k -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'sysbackup-task'; Group = '备份增强'; Name = '安装每日备份计划任务'
            Desc = '每天定时创建系统状态备份；填了共享目录时自动复制并保留 N 份。'
            Params = @(
                @{ Name = 'Share'; Label = '共享目录（可空）'; Type = 'Text'; Width = 420 }
                @{ Name = 'Keep'; Label = '保留份数'; Type = 'Text'; Width = 100; Default = '5' }
                @{ Name = 'Time'; Label = '每天时间（HH:mm）'; Type = 'Text'; Width = 100; Default = '03:00' }
                @{ Name = 'WithDrivers'; Label = '包含驱动'; Type = 'Check'; Default = $false }
                @{ Name = 'FullRegistry'; Label = '完整注册表'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                $k = 5; [void][int]::TryParse([string]$P['Keep'], [ref]$k)
                Install-GuiReadySysBackupTask -Share ([string]$P['Share']) -Keep $k -Time ([string]$P['Time']) `
                    -WithDrivers:([bool]$P['WithDrivers']) -FullRegistry:([bool]$P['FullRegistry']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }

        # ---------------- 批量管理 ----------------
        [pscustomobject]@{
            Id = 'batch-exec'; Group = '批量管理'; Name = '批量执行命令'
            Desc = '在选中的远程主机上并发执行 PowerShell 命令，逐台回传输出与错误。'
            Params = @(
                @{ Name = 'HostSpec'; Label = '主机（留空 = 全部启用）'; Type = 'Text'; Width = 320 }
                @{ Name = 'Command'; Label = '命令'; Type = 'Multi'; Width = 520 }
                @{ Name = 'TimeoutSec'; Label = '超时（秒）'; Type = 'Text'; Width = 100; Default = '120' }
            )
            DryRun = $false
            Script = {
                param($P)
                $t = 120; [void][int]::TryParse([string]$P['TimeoutSec'], [ref]$t)
                Invoke-GuiReadyBatchExec -Spec ([string]$P['HostSpec']) -Command ([string]$P['Command']) -TimeoutSec $t | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'batch-collect'; Group = '批量管理'; Name = '批量采集状态'
            Desc = '采集每台主机的 OS、CPU、内存、系统盘与运行时长。'
            Params = @(
                @{ Name = 'HostSpec'; Label = '主机（留空 = 全部启用）'; Type = 'Text'; Width = 320 }
                @{ Name = 'TimeoutSec'; Label = '超时（秒）'; Type = 'Text'; Width = 100; Default = '90' }
            )
            DryRun = $false
            Script = {
                param($P)
                $t = 90; [void][int]::TryParse([string]$P['TimeoutSec'], [ref]$t)
                Invoke-GuiReadyBatchCollect -Spec ([string]$P['HostSpec']) -TimeoutSec $t | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'batch-install'; Group = '批量管理'; Name = '批量安装软件包'
            Desc = '用 Chocolatey 或 winget 在远程主机上安装指定包。'
            Params = @(
                @{ Name = 'HostSpec'; Label = '主机（留空 = 全部启用）'; Type = 'Text'; Width = 320 }
                @{ Name = 'Package'; Label = '包名'; Type = 'Text'; Width = 260 }
                @{ Name = 'Manager'; Label = '包管理器'; Type = 'Combo'; Default = 1; Options = @('Chocolatey', 'winget') }
            )
            DryRun = $false
            Script = {
                param($P)
                $mgr = if ([int]$P['Manager'] -eq 2) { 'winget' } else { 'choco' }
                Invoke-GuiReadyBatchInstall -Spec ([string]$P['HostSpec']) -Package ([string]$P['Package']) -Manager $mgr | Out-Null
            }
        }

        [pscustomobject]@{
            Id = 'batch-upload'; Group = '批量管理'; Name = '批量上传文件'
            Desc = '把本机文件复制到远程主机的指定目录（经 SMB 管理共享）。'
            Params = @(
                @{ Name = 'HostSpec'; Label = '主机（留空 = 全部启用）'; Type = 'Text'; Width = 320 }
                @{ Name = 'LocalPath'; Label = '本地文件'; Type = 'Text'; Width = 520; Browse = 'File' }
                @{ Name = 'RemotePath'; Label = '远程目录'; Type = 'Text'; Width = 320; Default = 'C:\Windows\Temp' }
            )
            DryRun = $false
            Script = {
                param($P)
                Send-GuiReadyBatchFile -Spec ([string]$P['HostSpec']) -LocalPath ([string]$P['LocalPath']) `
                    -RemotePath ([string]$P['RemotePath']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'batch-download'; Group = '批量管理'; Name = '批量下载文件'
            Desc = '从远程主机复制指定文件到本机目录（留空目录 = reports\batch）。'
            Params = @(
                @{ Name = 'HostSpec'; Label = '主机（留空 = 全部启用）'; Type = 'Text'; Width = 320 }
                @{ Name = 'RemotePath'; Label = '远程文件路径'; Type = 'Text'; Width = 520 }
                @{ Name = 'OutDir'; Label = '本地目录（可空）'; Type = 'Text'; Width = 420; Browse = 'Folder' }
            )
            DryRun = $false
            Script = {
                param($P)
                Receive-GuiReadyBatchFile -Spec ([string]$P['HostSpec']) -RemotePath ([string]$P['RemotePath']) `
                    -OutDir ([string]$P['OutDir']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'batch-script'; Group = '批量管理'; Name = '批量分发脚本'
            Desc = '把本地 PowerShell 脚本上传到远程临时目录并执行，回传输出。'
            Params = @(
                @{ Name = 'HostSpec'; Label = '主机（留空 = 全部启用）'; Type = 'Text'; Width = 320 }
                @{ Name = 'LocalScript'; Label = '本地脚本'; Type = 'Text'; Width = 520; Browse = 'File' }
                @{ Name = 'TimeoutSec'; Label = '超时（秒）'; Type = 'Text'; Width = 100; Default = '300' }
            )
            DryRun = $false
            Script = {
                param($P)
                $t = 300; [void][int]::TryParse([string]$P['TimeoutSec'], [ref]$t)
                Invoke-GuiReadyBatchScript -Spec ([string]$P['HostSpec']) -LocalScript ([string]$P['LocalScript']) `
                    -TimeoutSec $t | Out-Null
            }
        }

        # ---------------- 网络诊断 ----------------
        [pscustomobject]@{
            Id = 'netdiag-scan'; Group = '网络诊断'; Name = '端口扫描'
            Desc = '从本机对目标主机做 TCP 连接探测，端口支持逗号与范围（最多 500 个）。'
            Params = @(
                @{ Name = 'Target'; Label = '目标主机 / IP'; Type = 'Text'; Width = 320; Default = '127.0.0.1' }
                @{ Name = 'Ports'; Label = '端口（如 80,443,1000-1010）'; Type = 'Text'; Width = 320; Default = '80,443,3389' }
                @{ Name = 'TimeoutMs'; Label = '超时（毫秒）'; Type = 'Text'; Width = 100; Default = '800' }
            )
            DryRun = $false
            Script = {
                param($P)
                $t = 800; [void][int]::TryParse([string]$P['TimeoutMs'], [ref]$t)
                Test-GuiReadyPortScan -Target ([string]$P['Target']) -Ports ([string]$P['Ports']) -TimeoutMs $t | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'netdiag-dns'; Group = '网络诊断'; Name = 'DNS 解析'
            Desc = '解析域名（可指定 DNS 服务器），列出 A / AAAA / CNAME 等记录。'
            Params = @(
                @{ Name = 'Name'; Label = '域名 / 主机名'; Type = 'Text'; Width = 320 }
                @{ Name = 'Server'; Label = 'DNS 服务器（可空）'; Type = 'Text'; Width = 240 }
            )
            DryRun = $false
            Script = { param($P) Resolve-GuiReadyDns -Name ([string]$P['Name']) -Server ([string]$P['Server']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'netdiag-connectivity'; Group = '网络诊断'; Name = '连通性测试'
            Desc = '对 host:port 做 TCP 探测，或对纯主机名做 ICMP，汇总通 / 不通与延迟。'
            Params = @(
                @{ Name = 'Targets'; Label = '目标列表（逗号分隔）'; Type = 'Text'; Width = 520; Default = '127.0.0.1:445' }
            )
            DryRun = $false
            Script = { param($P) Test-GuiReadyConnectivity -Targets ([string]$P['Targets']) | Out-Null }
        }
        [pscustomobject]@{
            Id = 'netdiag-capture'; Group = '网络诊断'; Name = '抓包（pktmon）'
            Desc = '用系统自带 pktmon 抓包并转换成 pcapng，保存到 reports\netdiag；需要 Windows Server 2019+。'
            Params = @(@{ Name = 'Seconds'; Label = '抓包时长（秒，3-300）'; Type = 'Text'; Width = 120; Default = '30' })
            DryRun = $true
            Script = {
                param($P)
                $s = 30; [void][int]::TryParse([string]$P['Seconds'], [ref]$s)
                Start-GuiReadyPacketCapture -Seconds $s -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'netdiag-capture-stop'; Group = '网络诊断'; Name = '停止抓包'
            Desc = '停止正在进行的 pktmon 抓包。'
            Params = @(); DryRun = $true
            Script = { param($P) if ([bool]$P['DryRun']) { Write-Log '[预览] 将停止 pktmon 抓包' 'DRY' } else { Stop-GuiReadyPacketCapture } }
        }

        # ---------------- 进程分析 ----------------
        [pscustomobject]@{
            Id = 'proc-snapshot'; Group = '进程分析'; Name = '记录进程快照'
            Desc = '把当前 Top 10 进程（PID / CPU / 内存 / 命令行）追加到 state\metrics\top-yyyyMM.csv。'
            Params = @(); DryRun = $false
            Script = { param($P) Save-GuiReadyProcessSnapshot | Out-Null }
        }
        [pscustomobject]@{
            Id = 'proc-kill'; Group = '进程分析'; Name = '结束进程'
            Desc = '按 PID 结束进程；System / Idle / lsass / svchost 等关键进程会被拒绝。'
            Params = @(@{ Name = 'Id'; Label = 'PID'; Type = 'Text'; Width = 120 })
            DryRun = $true
            Script = {
                param($P)
                $id = 0; [void][int]::TryParse([string]$P['Id'], [ref]$id)
                Stop-GuiReadyProcess -Id $id -DryRun:([bool]$P['DryRun'])
            }
        }

        # ---------------- 软件管理 ----------------
        [pscustomobject]@{
            Id = 'software-uninstall'; Group = '软件管理'; Name = '静默卸载软件'
            Desc = '按注册表条目静默卸载（优先 QuietUninstallString，其次 MSI 产品码）；没有静默命令会拒绝执行。'
            Params = @(@{ Name = 'Key'; Label = '注册表条目（来自软件清单）'; Type = 'Text'; Width = 520 })
            DryRun = $true
            Script = {
                param($P)
                Uninstall-GuiReadySoftware -Key ([string]$P['Key']) -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'software-export'; Group = '软件管理'; Name = '导出软件清单'
            Desc = '把已安装软件清单导出为 CSV（UTF-8，Excel 可直接打开）。'
            Params = @(@{ Name = 'Path'; Label = '保存到'; Type = 'Text'; Width = 520; Browse = 'File' })
            DryRun = $true
            Script = {
                param($P)
                if ([bool]$P['DryRun']) { Write-Log ('[预览] 将导出软件清单到 ' + [string]$P['Path']) 'DRY' }
                else { Export-GuiReadySoftwareList -Path ([string]$P['Path']) | Out-Null }
            }
        }

        # ---------------- 共享与权限 ----------------
        [pscustomobject]@{
            Id = 'smb-grant'; Group = '共享与权限'; Name = '授予 SMB 共享权限'
            Desc = '给账户授予指定共享的 Full / Change / Read 权限。'
            Params = @(
                @{ Name = 'Name'; Label = '共享名'; Type = 'Text'; Width = 240 }
                @{ Name = 'Account'; Label = '账户（DOMAIN\user 或 Everyone）'; Type = 'Text'; Width = 320 }
                @{ Name = 'Access'; Label = '权限'; Type = 'Combo'; Default = 3; Options = @('Full', 'Change', 'Read') }
            )
            DryRun = $true
            Script = {
                param($P)
                $map = @{ 1 = 'Full'; 2 = 'Change'; 3 = 'Read' }
                $acc = $map[[int]$P['Access']]; if (-not $acc) { $acc = 'Read' }
                Set-GuiReadySmbShareAccess -Name ([string]$P['Name']) -Account ([string]$P['Account']) `
                    -Access $acc -Action 'Grant' -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'smb-revoke'; Group = '共享与权限'; Name = '收回 SMB 共享权限'
            Desc = '移除指定账户在共享上的授权。'
            Params = @(
                @{ Name = 'Name'; Label = '共享名'; Type = 'Text'; Width = 240 }
                @{ Name = 'Account'; Label = '账户'; Type = 'Text'; Width = 320 }
            )
            DryRun = $true
            Script = {
                param($P)
                Set-GuiReadySmbShareAccess -Name ([string]$P['Name']) -Account ([string]$P['Account']) `
                    -Action 'Revoke' -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'ntfs-set'; Group = '共享与权限'; Name = '设置 NTFS 权限'
            Desc = '给路径添加一条 ACL 规则（账户 / 权限 / Allow 或 Deny / 继承）。'
            Params = @(
                @{ Name = 'Path'; Label = '路径'; Type = 'Text'; Width = 420; Browse = 'Folder' }
                @{ Name = 'Account'; Label = '账户'; Type = 'Text'; Width = 320 }
                @{ Name = 'Rights'; Label = '权限'; Type = 'Combo'; Default = 1; Options = @('FullControl', 'Modify', 'ReadAndExecute', 'Read', 'Write') }
                @{ Name = 'Type'; Label = '类型'; Type = 'Combo'; Default = 1; Options = @('Allow', 'Deny') }
                @{ Name = 'Inherit'; Label = '继承'; Type = 'Combo'; Default = 1; Options = @('ContainerInherit,ObjectInherit', 'ContainerInherit', 'ObjectInherit', 'None') }
            )
            DryRun = $true
            Script = {
                param($P)
                $r = @{ 1 = 'FullControl'; 2 = 'Modify'; 3 = 'ReadAndExecute'; 4 = 'Read'; 5 = 'Write' }[[int]$P['Rights']]
                if (-not $r) { $r = 'Read' }
                $t = if ([int]$P['Type'] -eq 2) { 'Deny' } else { 'Allow' }
                $inh = @{ 1 = 'ContainerInherit,ObjectInherit'; 2 = 'ContainerInherit'; 3 = 'ObjectInherit'; 4 = 'None' }[[int]$P['Inherit']]
                if (-not $inh) { $inh = 'ContainerInherit,ObjectInherit' }
                Set-GuiReadyNtfsAcl -Path ([string]$P['Path']) -Account ([string]$P['Account']) `
                    -Rights $r -Type $t -Inherit $inh -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }

        # ---------------- 维护窗口 ----------------
        [pscustomobject]@{
            Id = 'maintenance-start'; Group = '维护窗口'; Name = '开始维护窗口'
            Desc = '窗口内告警检查静默（不触发通知 / 动作），到时间自动恢复。'
            Params = @(
                @{ Name = 'Minutes'; Label = '时长（分钟）'; Type = 'Text'; Width = 120; Default = '60' }
                @{ Name = 'Reason'; Label = '原因'; Type = 'Text'; Width = 320; Default = '维护窗口' }
            )
            DryRun = $true
            Script = {
                param($P)
                $m = 60; [void][int]::TryParse([string]$P['Minutes'], [ref]$m)
                if ([bool]$P['DryRun']) { Write-Log ('[预览] 将开始 {0} 分钟维护窗口：{1}' -f $m, [string]$P['Reason']) 'DRY' }
                else { Set-GuiReadyMaintenanceWindow -Minutes $m -Reason ([string]$P['Reason']) | Out-Null }
            }
        }
        [pscustomobject]@{
            Id = 'maintenance-stop'; Group = '维护窗口'; Name = '结束维护窗口'
            Desc = '立即结束维护窗口，恢复告警检查。'
            Params = @(); DryRun = $true
            Script = {
                param($P)
                if ([bool]$P['DryRun']) { Write-Log '[预览] 将结束维护窗口' 'DRY' }
                else { Clear-GuiReadyMaintenanceWindow }
            }
        }

        # ---------------- 报告中心 ----------------
        [pscustomobject]@{
            Id = 'report-bundle'; Group = '报告中心'; Name = '打包最近报表'
            Desc = '把 reports\ 下最近的 HTML / CSV / JSON 报表打成 ZIP，并给出 SHA256。'
            Params = @(@{ Name = 'OutFile'; Label = '输出文件（可空 = reports\bundle-*.zip）'; Type = 'Text'; Width = 520; Browse = 'File' })
            DryRun = $true
            Script = {
                param($P)
                if ([bool]$P['DryRun']) { Write-Log ('[预览] 将打包最近报表到 ' + [string]$P['OutFile']) 'DRY' }
                else { New-GuiReadyReportBundle -OutFile ([string]$P['OutFile']) | Out-Null }
            }
        }
        [pscustomobject]@{
            Id = 'report-send'; Group = '报告中心'; Name = '打包并发送报告'
            Desc = '先生成报告包，再通过「通知」页配置的 SMTP 作为附件发出去。'
            Params = @(
                @{ Name = 'Title'; Label = '标题'; Type = 'Text'; Width = 320; Default = 'SCM 报告' }
                @{ Name = 'Text'; Label = '说明'; Type = 'Multi'; Width = 520 }
            )
            DryRun = $true
            Script = {
                param($P)
                $b = New-GuiReadyReportBundle
                Send-GuiReadyNotify -Title ([string]$P['Title']) -Text ([string]$P['Text']) `
                    -Level 'Info' -Attachment $b.File -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'report-task-install'; Group = '报告中心'; Name = '安装每日报告任务'
            Desc = '注册 ScmPlus-Reports，每天定时打包（可选发送邮件）。'
            Params = @(
                @{ Name = 'Time'; Label = '每天时间（HH:mm）'; Type = 'Text'; Width = 120; Default = '08:00' }
                @{ Name = 'Send'; Label = '打包后发送邮件'; Type = 'Check'; Default = $false }
            )
            DryRun = $true
            Script = {
                param($P)
                Install-GuiReadyReportTask -Send:([bool]$P['Send']) -Time ([string]$P['Time']) `
                    -DryRun:([bool]$P['DryRun']) | Out-Null
            }
        }
        [pscustomobject]@{
            Id = 'report-task-remove'; Group = '报告中心'; Name = '取消每日报告任务'
            Desc = '删除 ScmPlus-Reports 计划任务。'
            Params = @(); DryRun = $true
            Script = { param($P) Remove-GuiReadyReportTask -DryRun:([bool]$P['DryRun']) }
        }

        # ---------------- 脚本库 ----------------
        [pscustomobject]@{
            Id = 'script-run'; Group = '脚本库'; Name = '运行维护脚本'
            Desc = '运行 scripts\ 下的内置脚本（清理临时文件 / 诊断包 / 网络重置 / 磁盘检查 / 资产清单）。'
            Params = @(@{ Name = 'Id'; Label = '脚本 Id'; Type = 'Text'; Width = 260 })
            DryRun = $true
            Script = { param($P) Invoke-GuiReadyScript -Id ([string]$P['Id']) -DryRun:([bool]$P['DryRun']) | Out-Null }
        }
    )

    # 版本策略：与界面共用 state\ui-settings.json。
    #   2019+：隐藏与 Windows Admin Center 重复的 8 组动作（界面里也隐藏对应页面）。
    #   2019-：隐藏依赖 App Compatibility FOD / 补全 DLL / WAC 的动作 —— 实测在 2016 及更早版本不可用。
    $policy = Get-GuiReadyUiPolicy
    $wacGroups = @('Windows 更新', '网络配置', '本地账户', '服务管理', '防火墙', '存储与备份', '系统任务', '文件与日志')
    $legacyGroups = @('一键流程', '探测与诊断', '程序档案', '补给', 'Windows Admin Center')
    # 2008 R2 没有 Storage 模块：扩展 / 格式化 / 初始化这三个写操作不展示
    $oldStorageIds = @('storage-extend', 'storage-format', 'storage-init')

    return @(Set-GuiReadyActionRequirements -Actions $actions | Where-Object {
        $group = [string]$_.Group
        if ($policy.HideWac -and ($wacGroups -contains $group)) { return $false }
        if ($policy.HideWac -and [string]$_.Id -eq 'monitor-service') { return $false }
        if ($policy.HideUnsupported -and ($legacyGroups -contains $group)) { return $false }
        if ($policy.IsOld -and ($oldStorageIds -contains [string]$_.Id)) { return $false }
        return $true
    })
}

function Get-GuiReadyUiPolicy {
    # 读 state\ui-settings.json；没有这个文件时按「自动识别 + 两个隐藏都开」处理，
    # 与原生界面首次启动后的默认值保持一致（命令行 / 无界面场景也能得到同样的目录）。
    $root = [string]$script:GuiReadyRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $file = Join-Path $root 'state\ui-settings.json'
    $tier = 'auto'
    $hideWac = $true
    $hideUnsupported = $true

    if (Test-Path -LiteralPath $file) {
        try {
            $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.VersionTier) { $tier = [string]$j.VersionTier }
            if ($null -ne $j.HideWacDuplicates) { $hideWac = [bool]$j.HideWacDuplicates }
            if ($null -ne $j.HideUnsupported) { $hideUnsupported = [bool]$j.HideUnsupported }
        } catch { }
    }

    $build = 0
    try { $build = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber } catch { $build = [Environment]::OSVersion.Version.Build }
    $modern = ($tier -eq 'modern') -or ($tier -ne 'legacy' -and $tier -ne 'old' -and $build -ge 17763)
    $isOld = ($tier -eq 'old') -or (($tier -eq 'auto') -and $build -gt 0 -and $build -le 7601)

    [pscustomobject]@{
        Tier            = $tier
        Build           = $build
        Modern          = $modern
        IsOld           = $isOld
        HideWac         = ($hideWac -and $modern)
        HideUnsupported = ($hideUnsupported -and (-not $modern))
    }
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
        'guard-add'        = @('Name', 'Exe')
        'guard-toggle'     = @('Id')
        'guard-remove'     = @('Id')
        'plan-add'         = @('Name', 'Chain')
        'plan-run'         = @('Id')
        'plan-toggle'      = @('Id')
        'plan-remove'      = @('Id')
        'backup-add'       = @('Name', 'Source', 'Target')
        'backup-run'       = @('Id')
        'backup-remove'    = @('Id')
        'patrol-add'       = @('Name', 'Ports')
        'patrol-run'       = @('Id')
        'patrol-remove'    = @('Id')
        'download-add'     = @('Url')
        'download-pause'   = @('Id')
        'download-resume'  = @('Id')
        'download-complete' = @('Id')
        'download-cancel'  = @('Id')
        'download-remove'  = @('Id')
        'net-set-ip'       = @('Adapter')
        'net-adapter'      = @('Adapter')
        'net-dns-test'     = @('Name')
        'account-add'      = @('Name', 'Password')
        'account-update'   = @('Name')
        'account-remove'   = @('Name')
        'service-action'   = @('Names')
        'service-startup'  = @('Names')
        'service-recovery' = @('Names')
        'service-detail'   = @('Name')
        'firewall-open-port' = @('Name', 'Port')
        'firewall-toggle'  = @('Name')
        'firewall-remove'  = @('Name')
        'storage-extend'   = @('DriveLetter')
        'storage-format'   = @('DriveLetter')
        'storage-init'     = @('DiskNumber')
        'vss-remove'       = @('ShadowId')
        'systask-detail'   = @('Name')
        'systask-action'   = @('Name')
        'hyperv-action'    = @('Name')
        'hyperv-snapshot'  = @('VmName', 'SnapshotName')
        'iis-action'       = @('Name')
        'print-action'     = @('Name')
        'share-add'        = @('Name', 'Path')
        'share-remove'     = @('Name')
        'share-close'      = @('FileId')
        'batch-upload'     = @('LocalPath')
        'batch-download'   = @('RemotePath')
        'batch-script'     = @('LocalScript')
        'netdiag-scan'     = @('Ports')
        'netdiag-dns'      = @('Name')
        'netdiag-connectivity' = @('Targets')
        'proc-kill'        = @('Id')
        'software-uninstall' = @('Key')
        'software-export'  = @('Path')
        'smb-grant'        = @('Name', 'Account')
        'smb-revoke'       = @('Name', 'Account')
        'ntfs-set'         = @('Path', 'Account')
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

# GuiReady FOD: install App Compatibility Feature on Demand (official Microsoft path)

$Global:GuiReadyFodName = 'ServerCore.AppCompatibility~~~~0.0.1.0'

function Get-DismErrorHint {
    param([string]$Text)

    $hints = @()
    $map = @(
        @{ Code = '0x800f0954'; Hint = '无法从 Windows Update 取包（通常是被组策略/WU 源限制）。改用离线介质：-Source 指向 FOD ISO 的 LanguagesAndOptionalFeatures 目录并加 -LimitAccess。' },
        @{ Code = '0x800f081f'; Hint = '找不到源文件。检查 -Source 路径是否正确、介质版本是否与本机一致。' },
        @{ Code = '0x800f0906'; Hint = '源文件无法下载。多半是网络或 WU 不可达，改用离线介质。' },
        @{ Code = '0x800f0907'; Hint = '策略禁止按需功能安装（“指定可选组件安装和组件修复的设置”）。需要先在组策略中放行或指向本地源。' },
        @{ Code = '0x800f0831'; Hint = '包与当前映像不匹配。你用的介质版本与本机 build 不一致，换匹配的介质。' },
        @{ Code = '0x800f0922'; Hint = '系统保留分区空间不足，或 .NET 组件安装失败。清理 WinSxS / 释放系统盘后重试。' },
        @{ Code = '0x80240021'; Hint = 'Windows Update 下载超时（WU_E_TIME_OUT）。FOD 走 UUP 下载，体积大且对网络敏感。处置：直接重试（已下载部分会被复用）；或改用离线 Languages and Optional Features ISO 配 -Source 与 -LimitAccess。' },
        @{ Code = '0x8024402c'; Hint = 'Windows Update 网络连接失败。检查代理/DNS，或改用离线介质。' },
        @{ Code = '0x80072ee2'; Hint = '连接 Windows Update 超时。改用离线介质。' },
        @{ Code = '0x80072efe'; Hint = '与 Windows Update 的连接被中断。改用离线介质。' }
    )
    if ($Text) {
        foreach ($m in $map) {
            if ($Text -match [regex]::Escape($m.Code)) { $hints += $m.Hint }
        }
    }
    return $hints
}

function Get-FodState {
    try {
        $c = Get-WindowsCapability -Online -Name $Global:GuiReadyFodName -ErrorAction Stop
        $item = @($c) | Select-Object -First 1
        if ($item) { return [string]$item.State }
    } catch {
        return 'QueryFailed: ' + $_.Exception.Message
    }
    return 'NotPresent'
}

function Resolve-FodSource {
    param([string]$SourcePath)

    $result = [ordered]@{
        Ok      = $false
        Source  = ''
        Note    = ''
        Mounted = $null
    }

    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        $result.Note = '未指定 -SourcePath，将尝试走 Windows Update'
        return $result
    }

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        $result.Note = '指定的 -SourcePath 不存在: ' + $SourcePath
        return $result
    }

    $item = Get-Item -LiteralPath $SourcePath
    $root = $null

    if ($item.PSIsContainer) {
        $root = $item.FullName
    } elseif ($item.Extension -match '^\.(iso|img)$') {
        Write-Log ('挂载镜像: ' + $item.FullName) 'STEP'
        try {
            $mount = Mount-DiskImage -ImagePath $item.FullName -PassThru -ErrorAction Stop
            Start-Sleep -Seconds 2
            $vol = $mount | Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Select-Object -First 1
            if (-not $vol) {
                $result.Note = '镜像已挂载但拿不到盘符'
                return $result
            }
            $root = ($vol.DriveLetter + ':\')
            $result.Mounted = $item.FullName
        } catch {
            $result.Note = '挂载失败: ' + $_.Exception.Message
            return $result
        }
    } else {
        $result.Note = '无法识别的 -SourcePath（需要目录、ISO 或 IMG）: ' + $SourcePath
        return $result
    }

    $cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = [int]$cv.CurrentBuildNumber

    $candidates = @()
    if ($build -ge 20348) {
        $candidates += (Join-Path $root 'LanguagesAndOptionalFeatures')
    }
    $candidates += $root
    $candidates += (Join-Path $root 'sources\sxs')

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            $result.Ok     = $true
            $result.Source = $c
            if ($c -match 'sources\\sxs$') {
                $result.Note = ('build {0} 使用源目录: {1}（注意：主安装 ISO 的 sources\sxs 通常只含 IE/NetFx3 等包，不含 ServerCore.AppCompatibility 载荷；FOD 需要单独的 Languages and Optional Features ISO）' -f $build, $c)
            } else {
                $result.Note = ('build {0} 使用源目录: {1}' -f $build, $c)
            }
            return $result
        }
    }

    $result.Note = ('在 {0} 下找不到可用的按需功能源目录' -f $root)
    return $result
}

function Install-GuiReadyFod {
    param(
        [string]$SourcePath = '',
        [switch]$WhatIf,
        [switch]$ForceDirect
    )

    Write-Head '安装 App Compatibility FOD（微软官方路线）'

    if (-not (Assert-Administrator)) { return }

    $ctx = Get-GuiReadyExecutionContext
    Write-Log ('执行上下文: Session {0} / Interactive={1} / {2}' -f $ctx.SessionId, $ctx.UserInteractive, $ctx.Note) 'INFO'

    $static = Get-GuiReadyStatic
    if (-not $static.IsServerCore) {
        Write-Log '当前不是 Server Core。FOD 只能装在 Server Core 上，已中止。' 'ERROR'
        return
    }

    $state = Get-FodState
    Write-Log ('当前 FOD 状态: {0}' -f $state) 'INFO'
    if ($state -eq 'Installed') {
        Write-Log 'App Compatibility FOD 已安装，无需重复操作。' 'OK'
        $probe = Join-Path $env:windir 'System32\mmc.exe'
        Write-Log ('mmc.exe 是否存在: {0}' -f (Format-Bool (Test-Path -LiteralPath $probe))) 'INFO'
        return
    }
    if ($state -like 'QueryFailed*') {
        Write-Log ('无法确认 FOD 状态，但继续尝试安装。原因: ' + ($state -replace '^QueryFailed: ', '')) 'WARN'
    }

    $src = Resolve-FodSource -SourcePath $SourcePath
    Write-Log $src.Note 'INFO'

    $args = @{
        Online = $true
        Name   = $Global:GuiReadyFodName
    }
    if ($src.Ok) {
        $args['Source']      = $src.Source
        $args['LimitAccess'] = $true
    }

    $cmdline = 'Add-WindowsCapability -Online -Name ''{0}''' -f $Global:GuiReadyFodName
    if ($src.Ok) { $cmdline += (' -Source ''{0}'' -LimitAccess' -f $src.Source) }

    if ($WhatIf) {
        Write-Log '预览模式，未执行。将运行:' 'DRY'
        Write-Log ('  ' + $cmdline) 'DRY'
        Write-Log '说明：安装完成后需要重启服务器才能生效。' 'DRY'
        if ($src.Mounted) { Write-Log ('提示：预览模式未挂载镜像，实际执行时会自动挂载 ' + $src.Mounted) 'DRY' }
        return
    }

    Write-Log ('执行: ' + $cmdline) 'STEP'
    $out    = ''
    $failed = $false
    try {
        $r = Add-WindowsCapability @args -ErrorAction Stop
        $out = ($r | Out-String)
        Write-Log '安装命令已返回。' 'OK'
    } catch {
        $failed = $true
        $out = ($_ | Out-String)
        Write-Log ('安装失败: ' + $_.Exception.Message) 'ERROR'
    }

    if ($out) { Write-Log ('原始输出: ' + ($out -replace '\s+', ' ').Trim()) 'INFO' }

    foreach ($h in (Get-DismErrorHint $out)) {
        Write-Log ('处置建议: ' + $h) 'WARN'
    }

    if (-not $failed) {
        $restart = $false
        if ($out -match 'RestartNeeded\s*:\s*True') { $restart = $true }
        $newState = Get-FodState
        Write-Log ('安装后 FOD 状态: {0}' -f $newState) 'INFO'

        $mmc  = Join-Path $env:windir 'System32\mmc.exe'
        $expl = Join-Path $env:windir 'explorer.exe'
        Write-Log ('mmc.exe      存在: {0}' -f (Format-Bool (Test-Path -LiteralPath $mmc)))   'INFO'
        Write-Log ('explorer.exe 存在: {0}' -f (Format-Bool (Test-Path -LiteralPath $expl)))  'INFO'

        if ($restart -or $newState -eq 'Installed') {
            Write-Log '需要重启服务器才能让 FOD 生效。重启后请重新跑一次环境探测。' 'WARN'
        }
    }

    if ($src.Mounted) {
        try {
            Dismount-DiskImage -ImagePath $src.Mounted -ErrorAction SilentlyContinue | Out-Null
            Write-Log ('已卸载镜像: ' + $src.Mounted) 'INFO'
        } catch { }
    }
}

function Install-GuiReadyDesktopDlls {
    # 补齐 Server Core 缺失的桌面体验 DLL。
    #
    # 背景（真机实测 Server 2025 / 26100）：装了 App Compatibility FOD 之后，
    # twinui.dll / themeui.dll / themeservice.dll 仍然可能不在 System32 —— FOD 只覆盖
    # MMC / 事件查看器等一部分，主题与 XAML 相关的组件要另外补。
    #
    # 源：发布包内置的 setup\dll\amd64（从同版本桌面体验 ISO 的 install.wim 提取）。
    # 版本必须与当前系统主版本一致，否则拒绝复制（避免把 19041 的文件塞进 26100）。
    param([switch]$WhatIf, [switch]$Force)

    $names   = @('twinui.dll', 'themeui.dll', 'themeservice.dll', 'DispBroker.dll')
    $osBuild = [Environment]::OSVersion.Version.Build
    $dstDir  = Join-Path $env:SystemRoot 'System32'
    # 多版本目录：Server 2019 / 2022 / 2025 的 DLL 版本不同，必须用同 build 的文件。
    # 约定：setup\dll\<build>\amd64 放该版本专用；setup\dll\amd64 是默认（当前为 26100）。
    $cands = @(
        (Join-Path $script:GuiReadyRoot ('setup\dll\' + $osBuild + '\amd64')),
        (Join-Path $script:GuiReadyRoot 'setup\dll\amd64')
    )
    $srcDir = ''
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) { $srcDir = $c; break }
    }
    if (-not $srcDir) {
        Write-Log ('找不到 DLL 源目录（试过 setup\dll\' + $osBuild + '\amd64 与 setup\dll\amd64）。') 'ERROR'
        return $false
    }
    $ok = $true
    $copied = 0
    $backup = Join-Path $script:BackupDir ('dll-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

    Write-Head '补齐桌面体验 DLL'
    Write-Log ('源目录: ' + $srcDir) 'INFO'
    Write-Log ('系统版本: build ' + $osBuild) 'INFO'

    foreach ($n in $names) {
        $src = Join-Path $srcDir $n
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Log ('源文件不存在，跳过: ' + $n) 'WARN'
            continue
        }
        $sv = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($src)
        if ([int]$sv.FileBuildPart -ne [int]$osBuild) {
            Write-Log ('版本不匹配，拒绝复制 {0}: 文件 build={1}，系统 build={2}' -f $n, $sv.FileBuildPart, $osBuild) 'ERROR'
            Write-Log ('  请把 build {0} 的同版本 DLL 放到: setup\dll\{0}\amd64' -f $osBuild) 'INFO'
            $ok = $false
            continue
        }

        $dst = Join-Path $dstDir $n
        if (Test-Path -LiteralPath $dst) {
            $dv = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dst)
            # 版本一致就跳过 —— 即使 -Force 也不覆盖：
            # DispBroker.dll 这类文件可能正被系统（DWM/桌面组件）加载，覆盖会 Access denied，
            # 而且同版本覆盖没有任何意义。
            if ($dv.FileVersion -eq $sv.FileVersion) {
                Write-Log ('已存在且版本一致: ' + $n) 'OK'
                continue
            }
            if ($WhatIf) {
                Write-Log ('将备份并覆盖: {0}（当前 {1} -> {2}）' -f $n, $dv.FileVersion, $sv.FileVersion) 'DRY'
                continue
            }
            if (-not (Test-Path -LiteralPath $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }
            try { Copy-Item -LiteralPath $dst -Destination (Join-Path $backup $n) -Force -ErrorAction Stop } catch { }
        } elseif ($WhatIf) {
            Write-Log ('将新增: {0} {1}' -f $n, $sv.FileVersion) 'DRY'
            continue
        }

        try {
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            Write-Log ('已补齐: {0}  {1}' -f $n, $sv.FileVersion) 'OK'
            $copied++
        } catch {
            Write-Log ('复制失败 {0}: {1}（若文件正被系统占用，请重启后再运行本动作）' -f $n, $_.Exception.Message) 'ERROR'
            $ok = $false
        }
    }

    if ($WhatIf) { return $ok }
    if ($copied -gt 0) {
        Write-Log ('补齐完成：{0} 个文件。主题/XAML 相关组件需要重启或注销后生效。' -f $copied) 'INFO'
    }
    return $ok
}

function Remove-GuiReadyFod {
    param([switch]$WhatIf)

    Write-Head '卸载 App Compatibility FOD'

    if (-not (Assert-Administrator)) { return }

    if ($WhatIf) {
        Write-Log ('预览模式，未执行。将运行: Remove-WindowsCapability -Online -Name ''{0}''' -f $Global:GuiReadyFodName) 'DRY'
        return
    }

    try {
        Remove-WindowsCapability -Online -Name $Global:GuiReadyFodName -ErrorAction Stop | Out-Null
        Write-Log '卸载命令已返回，需要重启才能生效。' 'OK'
    } catch {
        Write-Log ('卸载失败: ' + $_.Exception.Message) 'ERROR'
    }
}

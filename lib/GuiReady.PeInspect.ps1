# GuiReady PE inspector: pure PowerShell PE import reader + GUI compatibility verdict

$Global:GuiReadyDesktopOnlyModules = @(
    'dwmapi.dll', 'dcomp.dll', 'dwrite.dll', 'd2d1.dll', 'd3d11.dll', 'dxgi.dll',
    'd3d10warp.dll', 'd3dcompiler_47.dll', 'dxcore.dll', 'twindow.dll',
    'twinui.dll', 'twinapi.dll', 'twinapi.appcore.dll', 'windows.ui.immersive.dll',
    'coremessaging.dll', 'coreuicomponents.dll', 'themeservice.dll', 'themeui.dll',
    'udwm.dll', 'dwmcore.dll', 'wuceffects.dll', 'uianimation.dll'
)

$Global:GuiReadyFodModules = @(
    'mmc.exe', 'mmcbase.dll', 'mmcndmgr.dll', 'explorer.exe', 'perfmon.exe', 'resmon.exe'
)

function ConvertTo-Latin1String {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
}

function Get-PeImageInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    $info = [ordered]@{
        Path          = $Path
        IsPe          = $false
        Error         = ''
        Machine       = 0
        MachineName   = ''
        Is64Bit       = $false
        Subsystem     = 0
        SubsystemName = ''
        IsDotNet      = $false
        Imports       = @()
        DelayImports  = @()
        FileSize      = 0
    }

    $full = ''
    try { $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath } catch {
        $info.Error = '路径不存在: ' + $Path
        return [pscustomobject]$info
    }
    $info.Path = $full

    $fs = $null
    $br = $null
    try {
        $fi = Get-Item -LiteralPath $full -ErrorAction Stop
        $info.FileSize = $fi.Length
        if ($fi.Length -lt 0x40) { throw '文件太小，不是 PE 镜像' }

        $fs = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $br = New-Object System.IO.BinaryReader($fs)

        $fs.Position = 0
        if ($br.ReadUInt16() -ne 0x5A4D) { throw '缺少 MZ 头，不是 PE 镜像' }

        $fs.Position = 0x3C
        $peOff = $br.ReadUInt32()
        if ($peOff -le 0 -or $peOff -gt ($fs.Length - 24)) { throw 'e_lfanew 非法' }

        $fs.Position = $peOff
        if ($br.ReadUInt32() -ne 0x00004550) { throw '缺少 PE 签名' }

        $machine = $br.ReadUInt16()
        $numSections = $br.ReadUInt16()
        [void]$br.ReadUInt32()
        [void]$br.ReadUInt32()
        [void]$br.ReadUInt32()
        $optSize = $br.ReadUInt16()
        [void]$br.ReadUInt16()

        $optStart = $peOff + 24
        $fs.Position = $optStart
        $magic = $br.ReadUInt16()
        if ($magic -ne 0x10B -and $magic -ne 0x20B) { throw '不支持的 Optional Header Magic' }
        $is64 = ($magic -eq 0x20B)

        $info.Machine = $machine
        $info.Is64Bit = $is64
        switch ($machine) {
            0x8664  { $info.MachineName = 'x64' }
            0x14C   { $info.MachineName = 'x86' }
            0xAA64  { $info.MachineName = 'ARM64' }
            default { $info.MachineName = ('0x{0:X}' -f $machine) }
        }

        $fs.Position = $optStart + 68
        $subsystem = $br.ReadUInt16()
        $info.Subsystem = $subsystem
        switch ($subsystem) {
            2 { $info.SubsystemName = 'GUI' }
            3 { $info.SubsystemName = 'Console' }
            default { $info.SubsystemName = ('其他(' + $subsystem + ')') }
        }

        $numRvaOff = $optStart + 92
        $ddOff     = $optStart + 96
        if ($is64) {
            $numRvaOff = $optStart + 108
            $ddOff     = $optStart + 112
        }
        $fs.Position = $numRvaOff
        $numRva = $br.ReadUInt32()

        $dirs = @{}
        $count = [Math]::Min([int]$numRva, 16)
        for ($i = 0; $i -lt $count; $i++) {
            $fs.Position = $ddOff + ($i * 8)
            $rva = $br.ReadUInt32()
            $sz  = $br.ReadUInt32()
            $dirs[$i] = @($rva, $sz)
        }

        $secStart = $optStart + $optSize
        $sections = @()
        for ($i = 0; $i -lt $numSections; $i++) {
            $pos = $secStart + ($i * 40)
            if ($pos + 40 -gt $fs.Length) { break }
            $fs.Position = $pos
            $nameBytes = $br.ReadBytes(8)
            $vsize  = $br.ReadUInt32()
            $vaddr  = $br.ReadUInt32()
            $rawSz  = $br.ReadUInt32()
            $rawPtr = $br.ReadUInt32()
            $name = ([System.Text.Encoding]::ASCII.GetString($nameBytes)).TrimEnd([char]0)
            $sections += [pscustomobject]@{
                Name             = $name
                VirtualAddress   = $vaddr
                VirtualSize      = $vsize
                SizeOfRawData    = $rawSz
                PointerToRawData = $rawPtr
            }
        }

        $toOffset = {
            param([uint32]$rva)
            foreach ($s in $sections) {
                $span = [Math]::Max([int]$s.VirtualSize, [int]$s.SizeOfRawData)
                if ($rva -ge $s.VirtualAddress -and $rva -lt ($s.VirtualAddress + $span)) {
                    return [int]($rva - $s.VirtualAddress + $s.PointerToRawData)
                }
            }
            return -1
        }

        $readAsciiz = {
            param([int]$offset)
            if ($offset -le 0 -or $offset -ge $fs.Length) { return '' }
            $fs.Position = $offset
            $sb = New-Object System.Text.StringBuilder
            while ($fs.Position -lt $fs.Length) {
                $b = $br.ReadByte()
                if ($b -eq 0) { break }
                [void]$sb.Append([char]$b)
                if ($sb.Length -gt 260) { break }
            }
            return $sb.ToString()
        }

        $imports = New-Object System.Collections.ArrayList
        if ($dirs.ContainsKey(1)) {
            $importRva = [uint32]$dirs[1][0]
            if ($importRva -gt 0) {
                $descPos = & $toOffset $importRva
                if ($descPos -gt 0) {
                    while (($descPos + 20) -le $fs.Length) {
                        $fs.Position = $descPos
                        $oft     = $br.ReadUInt32()
                        [void]$br.ReadUInt32()
                        [void]$br.ReadUInt32()
                        $nameRva = $br.ReadUInt32()
                        $ft      = $br.ReadUInt32()
                        if ($oft -eq 0 -and $nameRva -eq 0 -and $ft -eq 0) { break }
                        $descPos += 20
                        if ($nameRva -gt 0) {
                            $nOff = & $toOffset $nameRva
                            $n = & $readAsciiz $nOff
                            if ($n) { $imports.Add($n) | Out-Null }
                        }
                    }
                }
            }
        }
        $info.Imports = @($imports | Sort-Object -Unique)

        $delay = New-Object System.Collections.ArrayList
        if ($dirs.ContainsKey(13)) {
            $dlRva = [uint32]$dirs[13][0]
            if ($dlRva -gt 0) {
                $descPos = & $toOffset $dlRva
                if ($descPos -gt 0) {
                    while (($descPos + 32) -le $fs.Length) {
                        $fs.Position = $descPos
                        [void]$br.ReadUInt32()
                        $nameRva = $br.ReadUInt32()
                        if ($nameRva -eq 0) { break }
                        $descPos += 32
                        $nOff = & $toOffset $nameRva
                        $n = & $readAsciiz $nOff
                        if ($n) { $delay.Add($n) | Out-Null }
                    }
                }
            }
        }
        $info.DelayImports = @($delay | Sort-Object -Unique)

        if ($dirs.ContainsKey(14)) {
            $info.IsDotNet = ([uint32]$dirs[14][0] -gt 0)
        }

        $info.IsPe = $true
    } catch {
        $info.Error = $_.Exception.Message
    } finally {
        if ($br) { try { $br.Close() } catch { } }
        if ($fs) { try { $fs.Dispose() } catch { } }
    }

    return [pscustomobject]$info
}

function Get-FileKindTag {
    param([Parameter(Mandatory = $true)][string]$Path, $PeInfo)

    $tags = New-Object System.Collections.ArrayList
    $dir = Split-Path -Parent $Path

    foreach ($marker in @('resources\app.asar', 'resources\app', 'resources.pak', 'icudtl.dat', 'v8_context_snapshot.bin', 'libEGL.dll', 'libGLESv2.dll')) {
        $m = Join-Path $dir $marker
        if (Test-Path -LiteralPath $m) { $tags.Add('Electron/Chromium') | Out-Null; break }
    }

    # 兼容 QQ NT 这类“启动器 + versions\<版本>\resources\app”的两层嵌套布局（增量更新产物）
    if ($tags.Count -eq 0) {
        $leafs = @('resources\app', 'resources\app.asar', 'resources.pak', 'icudtl.dat', 'v8_context_snapshot.bin')
        $lvl1 = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Select-Object -First 10)
        foreach ($s1 in $lvl1) {
            foreach ($leaf in $leafs) {
                if (Test-Path -LiteralPath (Join-Path $s1.FullName $leaf)) { $tags.Add('Electron/Chromium') | Out-Null; break }
            }
            if ($tags.Count -gt 0) { break }

            $lvl2 = @(Get-ChildItem -LiteralPath $s1.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 10)
            foreach ($s2 in $lvl2) {
                foreach ($leaf in $leafs) {
                    if (Test-Path -LiteralPath (Join-Path $s2.FullName $leaf)) { $tags.Add('Electron/Chromium') | Out-Null; break }
                }
                if ($tags.Count -gt 0) { break }
            }
            if ($tags.Count -gt 0) { break }
        }
    }

    if ($PeInfo -and $PeInfo.IsDotNet -and -not $PeInfo.Error) {
        $text = ''
        try {
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            if ($bytes.Length -le 67108864) { $text = ConvertTo-Latin1String $bytes }
        } catch { }

        if ($text) {
            $wpfHits = 0
            foreach ($m in @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'ReachFramework')) {
                if ($text.IndexOf($m, [System.StringComparison]::Ordinal) -ge 0) { $wpfHits++ }
            }
            if ($wpfHits -ge 2) { $tags.Add('WPF') | Out-Null }

            if ($text.IndexOf('System.Windows.Forms', [System.StringComparison]::Ordinal) -ge 0) {
                $tags.Add('WinForms') | Out-Null
            }
            if ($text.IndexOf('Avalonia', [System.StringComparison]::Ordinal) -ge 0) {
                $tags.Add('Avalonia') | Out-Null
            }
        }
    }

    if ($tags.Count -eq 0) { return '' }
    return ($tags -join ' + ')
}

function Test-ModuleResolvable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$AppDir,
        [switch]$PreferSys32
    )
    $cands = @(
        (Join-Path $AppDir $Name),
        (Join-Path (Join-Path $env:windir 'System32') $Name)
    )
    if (-not $PreferSys32) {
        $cands += (Join-Path (Join-Path $env:windir 'SysWOW64') $Name)
    }
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) { return $true }
    }
    $sysDir = Join-Path $env:windir 'System32'
    if ($env:PATH) {
        foreach ($p in ($env:PATH -split ';')) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            try {
                if (Test-Path -LiteralPath (Join-Path $p $Name)) { return $true }
            } catch { }
        }
    }
    return $false
}

function Invoke-GuiReadyPeCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $targets = @()
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $targets = @(Get-ChildItem -LiteralPath $Path -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 40)
    } else {
        $targets = @(Get-Item -LiteralPath $Path -ErrorAction Stop)
    }

    if ($targets.Count -eq 0) {
        Write-Log '没有找到可检查的 exe 文件。' 'WARN'
        return
    }

    $results = New-Object System.Collections.ArrayList

    foreach ($t in $targets) {
        $pe = Get-PeImageInfo -Path $t.FullName
        Write-Head ('兼容性预检: ' + $t.Name)

        if (-not $pe.IsPe) {
            Write-Log ('不是有效的 PE 文件: ' + $pe.Error) 'ERROR'
            continue
        }

        $kind = Get-FileKindTag -Path $pe.Path -PeInfo $pe

        Write-Log ('路径        : {0}' -f $pe.Path) 'INFO'
        Write-Log ('架构        : {0}    子系统: {1}' -f $pe.MachineName, $pe.SubsystemName) 'INFO'
        Write-Log ('.NET 程序集 : {0}' -f (Format-Bool $pe.IsDotNet)) 'INFO'
        Write-Log ('类型标签    : {0}' -f $(if ($kind) { $kind } else { '(未识别为 WPF/WinForms/Electron/Avalonia)' })) 'INFO'
        Write-Log ('导入模块数  : {0}    延迟导入: {1}' -f $pe.Imports.Count, $pe.DelayImports.Count) 'INFO'

        $appDir = Split-Path -Parent $pe.Path
        $allModules = @($pe.Imports + $pe.DelayImports | Sort-Object -Unique)

        $apiSets  = @()
        $missing  = @()

        foreach ($m in $allModules) {
            if ($m -match '^(api-ms-win-|ext-ms-win-)') { $apiSets += $m; continue }
            if (-not (Test-ModuleResolvable -Name $m -AppDir $appDir)) { $missing += $m }
        }

        if ($apiSets.Count -gt 0) {
            Write-Log ('  API Set 导入 {0} 个（由系统按 ApiSet Schema 解析，静态检查看不出缺失，需实跑验证）' -f $apiSets.Count) 'INFO'
        }

        if ($missing.Count -eq 0) {
            Write-Log '  未发现缺失的静态导入模块。' 'OK'
        } else {
            Write-Log ('  缺失 {0} 个模块:' -f $missing.Count) 'WARN'
            foreach ($m in $missing) {
                $group = '未知来源'
                if ($Global:GuiReadyDesktopOnlyModules -contains $m.ToLower()) { $group = '桌面体验专属' }
                elseif ($Global:GuiReadyFodModules -contains $m.ToLower()) { $group = 'FOD 提供' }
                Write-Log ('    - {0,-30} [{1}]' -f $m, $group) 'WARN'
            }
        }

        $verdict = ''
        $risk = '低'
        if ($missing.Count -eq 0) {
            $verdict = '静态依赖齐全，可以直接尝试运行。'
        } else {
            $desk = @($missing | Where-Object { $Global:GuiReadyDesktopOnlyModules -contains $_.ToLower() })
            if ($desk.Count -gt 0) {
                $risk = '高'
                $verdict = ('缺少桌面体验专属组件（{0}）。纯 Win32/GDI 程序通常还能跑，但该程序依赖现代渲染管线，装 FOD 也大概率起不来：建议走 Server-Gui-Shell 补全或虚拟机路线。' -f (($desk | Select-Object -First 5) -join ', '))
            } else {
                $risk = '中'
                $verdict = '缺少第三方或运行库模块，需要先补齐这些 DLL / 运行库再试。'
            }
        }

        if ($kind -match 'WPF' -and $risk -eq '低') {
            $risk = '中'
            $verdict += ' 注意：这是 WPF 程序，WPF 渲染依赖 DWrite/DirectComposition，即使在静态依赖齐全的情况下也需要实跑验证。'
        }
        if ($kind -match 'Electron' -and $risk -eq '低') {
            $risk = '中'
            $verdict += ' 注意：这是 Electron/Chromium 程序。Server Core 没有 GPU 驱动与完整 DWM 合成，实测加上 --disable-gpu --disable-software-rasterizer 后启动快约 3 倍、CPU 降低约 85%（QQ 9.9.35 实测：首窗口 18.2s→6.0s，CPU 30.5s→4.6s）。'
        }

        Write-Log ''
        Write-Log ('风险等级: {0}' -f $risk) $(if ($risk -eq '高') { 'ERROR' } elseif ($risk -eq '中') { 'WARN' } else { 'OK' })
        Write-Log ('结论    : {0}' -f $verdict) 'INFO'

        $results.Add([pscustomobject]@{
            File     = $pe.Path
            Arch     = $pe.MachineName
            Subsystem= $pe.SubsystemName
            IsDotNet = $pe.IsDotNet
            Kind     = $kind
            Missing  = $missing
            ApiSets  = $apiSets.Count
            Risk     = $risk
            Verdict  = $verdict
        }) | Out-Null
    }

    if ($results.Count -gt 0) {
        Save-JsonReport -Object @($results) -Name 'pecheck' | Out-Null
    }
    return $results
}

# GuiReady launcher: a minimal WinForms shell for RDP sessions on Server Core

param(
    [switch]$Console,
    [switch]$NoHideConsole,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'

$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Detect.ps1', 'GuiReady.PeInspect.ps1',
                 'GuiReady.Catalog.ps1', 'GuiReady.Diag.ps1', 'GuiReady.DotNet.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}

$script:ProgramStore = Join-Path $PSScriptRoot 'programs.json'
$script:ToolRoot = Split-Path -Parent $PSScriptRoot

$script:ToolList = @(
    @{ Name = '命令提示符';        Target = 'cmd.exe' },
    @{ Name = 'PowerShell';        Target = 'powershell.exe' },
    @{ Name = '记事本';            Target = 'notepad.exe' },
    @{ Name = '任务管理器';        Target = 'taskmgr.exe' },
    @{ Name = '注册表编辑器';      Target = 'regedit.exe' },
    @{ Name = 'MMC 控制台';        Target = 'mmc.exe' },
    @{ Name = '事件查看器';        Target = 'eventvwr.msc' },
    @{ Name = '磁盘管理';          Target = 'diskmgmt.msc' },
    @{ Name = '设备管理器';        Target = 'devmgmt.msc' },
    @{ Name = '服务';              Target = 'services.msc' },
    @{ Name = '性能监视器';        Target = 'perfmon.exe' },
    @{ Name = '资源监视器';        Target = 'resmon.exe' },
    @{ Name = '任务计划程序';      Target = 'taskschd.msc' },
    @{ Name = 'Hyper-V 管理器';    Target = 'virtmgmt.msc' },
    @{ Name = 'PowerShell ISE';    Target = 'powershell_ise.exe' },
    @{ Name = '文件资源管理器';    Target = 'explorer.exe' }
)

function Resolve-SystemTool {
    param([string]$Target)
    $sys32 = Join-Path $env:windir 'System32'
    $p = Join-Path $sys32 $Target
    if (Test-Path -LiteralPath $p) { return $p }
    try {
        $c = Get-Command $Target -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    } catch { }
    return $null
}

function Get-SavedPrograms {
    if (-not (Test-Path -LiteralPath $script:ProgramStore)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $script:ProgramStore -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        return @($obj)
    } catch {
        return @()
    }
}

function Save-Programs {
    param($Items)
    try {
        $json = [string](ConvertTo-Json -InputObject @($Items) -Depth 4)
        [System.IO.File]::WriteAllText($script:ProgramStore, $json, (New-Object System.Text.UTF8Encoding -ArgumentList $true))
    } catch { }
}

function Start-Target {
    param([string]$Target, [string]$AppDir, [string]$Arguments = '')

    $resolved = $Target
    if (-not (Test-Path -LiteralPath $Target)) {
        $r = Resolve-SystemTool $Target
        if ($r) { $resolved = $r }
    }

    if (-not (Test-Path -LiteralPath $resolved)) {
        [System.Windows.Forms.MessageBox]::Show(('找不到目标: ' + $Target), '启动失败', 'OK', 'Warning') | Out-Null
        return
    }

    if ($resolved -match '\.exe$') {
        try {
            $pe = Get-PeImageInfo -Path $resolved
            if ($pe.IsPe) {
                $dir = Split-Path -Parent $resolved
                $missing = @()
                foreach ($m in @($pe.Imports + $pe.DelayImports | Sort-Object -Unique)) {
                    if ($m -match '^(api-ms-win-|ext-ms-win-)') { continue }
                    if (-not (Test-ModuleResolvable -Name $m -AppDir $dir)) { $missing += $m }
                }
                $desk = @($missing | Where-Object { $Global:GuiReadyDesktopOnlyModules -contains $_.ToLower() })
                if ($desk.Count -gt 0) {
                    $msg = '这个程序依赖桌面体验专属组件，在当前系统上很可能启动失败:' + [Environment]::NewLine +
                           [Environment]::NewLine + (($desk | Select-Object -First 8) -join [Environment]::NewLine) +
                           [Environment]::NewLine + [Environment]::NewLine + '仍然要继续启动吗？'
                    $r = [System.Windows.Forms.MessageBox]::Show($msg, '兼容性预检', 'YesNo', 'Warning')
                    if ($r -ne 'Yes') { return }
                }
            }
        } catch { }
    }

    try {
        if ($resolved -match '\.msc$') {
            $mmc = Resolve-SystemTool 'mmc.exe'
            if ($mmc) {
                Start-Process -FilePath $mmc -ArgumentList ('"' + $resolved + '"') | Out-Null
            } else {
                [System.Windows.Forms.MessageBox]::Show('mmc.exe 不存在，需要先安装 App Compatibility FOD。', '无法启动', 'OK', 'Warning') | Out-Null
            }
        } elseif ($Arguments) {
            Start-Process -FilePath $resolved -ArgumentList $Arguments -WorkingDirectory (Split-Path -Parent $resolved) | Out-Null
            Write-Log ('已启动: {0}  参数: {1}' -f $resolved, $Arguments) 'OK'
        } else {
            Start-Process -FilePath $resolved | Out-Null
            Write-Log ('已启动: ' + $resolved) 'OK'
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
    }
}

function Get-SelectedItem {
    if ($lstOwn.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show('请先在列表里选中一个程序。', '提示', 'OK', 'Information') | Out-Null
        return $null
    }
    return $script:OwnItems[$lstOwn.SelectedIndex]
}

function Refresh-OwnList {
    $lstOwn.Items.Clear()
    foreach ($it in $script:OwnItems) {
        $args = ''
        if ($it.PSObject.Properties['Args'] -and $it.Args) { $args = '   [参数: ' + $it.Args + ']' }
        [void]$lstOwn.Items.Add($it.Name + '  |  ' + $it.Path + $args)
    }
}

function Show-EnvironmentSummary {
    $lines = @()
    try {
        $s = Get-GuiReadyStatic
        $lines += ('系统        : {0}  Build {1}.{2}' -f $s.FriendlyName, $s.Build, $s.UBR)
        $lines += ('安装类型    : {0}' -f $s.InstallationType)
        $lines += ('Winlogon Shell : {0}' -f $s.WinlogonShell)

        $cap = Get-GuiReadyCapability
        $fod = 'NotPresent'
        foreach ($i in $cap.Items) { if ($i.Name -like 'ServerCore.AppCompatibility*') { $fod = $i.State } }
        $lines += ('App Compat FOD : {0}' -f $fod)

        $dlls = Get-GuiReadyDllScan
        $miss = @($dlls | Where-Object { $_.Group -eq '桌面体验专属' -and -not $_.Exists })
        $lines += ('桌面体验组件   : 缺 {0} / 共 {1}' -f $miss.Count, ($dlls | Where-Object { $_.Group -eq '桌面体验专属' }).Count)
        if ($miss.Count -gt 0) {
            $lines += ('  缺失清单    : ' + (($miss | Select-Object -First 10 | ForEach-Object { $_.Name }) -join ', '))
        }

        $rdp = Get-GuiReadyRdp
        $lines += ('RDP 允许连接   : {0}    3389 监听: {1}' -f (Format-Bool $rdp.RdpEnabled), (Format-Bool $rdp.Listening3389))
        $lines += ('活动会话数     : {0}' -f $rdp.ActiveSessions.Count)

        if (Get-Command Get-GuiReadyUac -ErrorAction SilentlyContinue) {
            $u = Get-GuiReadyUac
            $lines += ('UAC 会拦提权   : {0}' -f (Format-Bool $u.PromptsWillBlock))
        }
        if (Get-Command Get-GuiReadyDotNetStatus -ErrorAction SilentlyContinue) {
            $dn = Get-GuiReadyDotNetStatus
            $lines += ('已装 .NET 框架 : {0} 个' -f $dn.Frameworks.Count)
        }
    } catch {
        $lines += ('探测出错: ' + $_.Exception.Message)
    }

    [System.Windows.Forms.MessageBox]::Show(($lines -join [Environment]::NewLine), '环境状态', 'OK', 'Information') | Out-Null
}

function Start-ConsoleFallback {
    Write-Head '图形界面不可用，回退到命令行菜单'
    Write-Log 'WinForms 无法加载。这通常说明系统还缺 GUI 组件（先装 App Compatibility FOD）。' 'WARN'
    while ($true) {
        Write-Host ''
        Write-Host '可用工具:' -ForegroundColor Cyan
        $i = 1
        foreach ($t in $script:ToolList) {
            $p = Resolve-SystemTool $t.Target
            $mark = '缺少'
            if ($p) { $mark = '可用' }
            Write-Host ('  {0,2}. {1,-18} [{2}] {3}' -f $i, $t.Name, $mark, $t.Target)
            $i++
        }
        Write-Host '   0. 退出'
        $sel = Read-Host '选择要启动的编号'
        if ($sel -eq '0' -or [string]::IsNullOrWhiteSpace($sel)) { return }
        $idx = 0
        if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $script:ToolList.Count) {
            Start-Target -Target $script:ToolList[$idx - 1].Target
        }
    }
}

if (-not $Console) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        Start-ConsoleFallback
        return
    }
} else {
    Start-ConsoleFallback
    return
}

if (-not $NoHideConsole) {
    try {
        Add-Type -Namespace GrNative -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        $h = [GrNative.Win]::GetConsoleWindow()
        if ($h -ne [System.IntPtr]::Zero) { [void][GrNative.Win]::ShowWindow($h, 0) }
    } catch { }
}

[void][System.Windows.Forms.Application]::EnableVisualStyles()

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Server Core 图形启动器'
$form.Size            = New-Object System.Drawing.Size(980, 720)
$form.StartPosition   = 'CenterScreen'
$form.MinimumSize     = New-Object System.Drawing.Size(820, 620)

try {
    $form.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 9
} catch { }

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock    = 'Top'
$topPanel.Height  = 78
$topPanel.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 4)
$form.Controls.Add($topPanel)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.AutoSize = $true
$lblTitle.Font     = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 12, ([System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(12, 8)
$lblTitle.Text     = 'Server Core 图形启动器'
$topPanel.Controls.Add($lblTitle)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.AutoSize  = $false
$lblInfo.Location  = New-Object System.Drawing.Point(14, 38)
$lblInfo.Size      = New-Object System.Drawing.Size(930, 34)
try {
    $s = Get-GuiReadyStatic
    $fod = '未知'
    try {
        $cap = Get-GuiReadyCapability
        $fod = 'NotPresent'
        foreach ($i in $cap.Items) { if ($i.Name -like 'ServerCore.AppCompatibility*') { $fod = $i.State } }
        if ($cap.Error) { $fod = '未知(需管理员)' }
    } catch { $fod = '未知(需管理员)' }
    $missCount = '未知'
    try {
        $dlls = Get-GuiReadyDllScan
        $missCount = @($dlls | Where-Object { $_.Group -eq '桌面体验专属' -and -not $_.Exists }).Count
    } catch { }
    $dotnetText = '-'
    try {
        if (Get-Command Get-GuiReadyDotNetStatus -ErrorAction SilentlyContinue) {
            $dn = Get-GuiReadyDotNetStatus
            $dotnetText = [string]$dn.Frameworks.Count
        }
    } catch { }
    $lblInfo.Text = ('{0}  Build {1}  安装类型={2}   FOD={3}   缺失桌面组件={4}   已装 .NET 框架={5}' -f $s.MachineName, $s.Build, $s.InstallationType, $fod, $missCount, $dotnetText)
} catch {
    $lblInfo.Text = '环境信息读取失败: ' + $_.Exception.Message
}
$topPanel.Controls.Add($lblInfo)

$grpTools = New-Object System.Windows.Forms.GroupBox
$grpTools.Text     = '系统工具'
$grpTools.Location = New-Object System.Drawing.Point(12, 84)
$grpTools.Size     = New-Object System.Drawing.Size(950, 226)
$grpTools.Anchor   = 'Top,Left,Right'
$form.Controls.Add($grpTools)

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock          = 'Fill'
$flow.Padding       = New-Object System.Windows.Forms.Padding(8)
$flow.WrapContents  = $true
$flow.AutoScroll    = $true
$grpTools.Controls.Add($flow)

foreach ($t in $script:ToolList) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text   = $t.Name
    $btn.Size   = New-Object System.Drawing.Size(168, 40)
    $btn.Margin = New-Object System.Windows.Forms.Padding(4)
    $target = $t.Target
    $exists = [bool](Resolve-SystemTool $target)
    if (-not $exists) {
        $btn.Enabled = $false
        $btn.Text    = $t.Name + ' (缺失)'
    }
    $btn.Add_Click({ Start-Target -Target $target }.GetNewClosure())
    $flow.Controls.Add($btn)
}

$grpOwn = New-Object System.Windows.Forms.GroupBox
$grpOwn.Text     = '我的程序（支持启动参数，Electron 类会自动带入推荐参数）'
$grpOwn.Location = New-Object System.Drawing.Point(12, 316)
$grpOwn.Size     = New-Object System.Drawing.Size(950, 246)
$grpOwn.Anchor   = 'Top,Left,Right'
$form.Controls.Add($grpOwn)

$lstOwn = New-Object System.Windows.Forms.ListBox
$lstOwn.Location = New-Object System.Drawing.Point(10, 22)
$lstOwn.Size     = New-Object System.Drawing.Size(592, 208)
$grpOwn.Controls.Add($lstOwn)

$script:BtnX1 = 612
$script:BtnX2 = 758
$script:BtnW  = 140
$script:BtnH  = 32

function New-OwnButton {
    param([string]$Text, [int]$X, [int]$Y, [scriptblock]$OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text     = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size     = New-Object System.Drawing.Size($script:BtnW, $script:BtnH)
    $b.Add_Click($OnClick)
    $grpOwn.Controls.Add($b)
    return $b
}

$btnAdd   = New-OwnButton -Text '添加程序...'     -X $script:BtnX1 -Y 22  -OnClick {}
$btnRun   = New-OwnButton -Text '启动选中项'      -X $script:BtnX1 -Y 58  -OnClick {}
$btnRunR  = New-OwnButton -Text '用推荐参数启动'  -X $script:BtnX1 -Y 94  -OnClick {}
$btnArgs  = New-OwnButton -Text '设置启动参数...' -X $script:BtnX1 -Y 130 -OnClick {}
$btnPers  = New-OwnButton -Text '持久化启动'      -X $script:BtnX1 -Y 166 -OnClick {}
$btnDiag  = New-OwnButton -Text '诊断选中项'      -X $script:BtnX2 -Y 22  -OnClick {}
$btnCata  = New-OwnButton -Text '查档案'          -X $script:BtnX2 -Y 58  -OnClick {}
$btnDel   = New-OwnButton -Text '移除选中项'      -X $script:BtnX2 -Y 94  -OnClick {}
$btnPick  = New-OwnButton -Text '浏览并检查...'   -X $script:BtnX2 -Y 130 -OnClick {}

$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock   = 'Bottom'
$bottom.Height = 60
$form.Controls.Add($bottom)

function New-BottomButton {
    param([string]$Text, [int]$X, [scriptblock]$OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text     = $Text
    $b.Location = New-Object System.Drawing.Point($X, 12)
    $b.Size     = New-Object System.Drawing.Size(150, 34)
    $b.Add_Click($OnClick)
    $bottom.Controls.Add($b)
    return $b
}

[void](New-BottomButton -Text '环境状态'   -X 12  -OnClick { Show-EnvironmentSummary })
[void](New-BottomButton -Text '运行探测'   -X 170 -OnClick {
        $r = Invoke-GuiReadyDetect
        [System.Windows.Forms.MessageBox]::Show('探测完成，报告已写入 reports 目录。', '完成', 'OK', 'Information') | Out-Null
    })
[void](New-BottomButton -Text 'GUI 自检'   -X 328 -OnClick {
        $r = [System.Windows.Forms.MessageBox]::Show('将实际创建窗口并抓图取证，约需 30 秒。继续吗？', 'GUI 能力自检', 'YesNo', 'Question')
        if ($r -eq 'Yes') {
            try {
                $res = Start-GuiReadyGuiSelfTest -IncludeApps
                $msg = '自检完成，结论见 logs 目录里的日志。'
                if ($res -and $res.Conclusion) { $msg = $res.Conclusion }
                [System.Windows.Forms.MessageBox]::Show($msg, 'GUI 能力自检', 'OK', 'Information') | Out-Null
            } catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '自检失败', 'OK', 'Error') | Out-Null
            }
        }
    })
[void](New-BottomButton -Text '打开日志'   -X 486 -OnClick { Start-Process -FilePath (Join-Path $script:ToolRoot 'logs') | Out-Null })
[void](New-BottomButton -Text '打开报告'   -X 644 -OnClick { Start-Process -FilePath (Join-Path $script:ToolRoot 'reports') | Out-Null })
[void](New-BottomButton -Text '注销当前用户' -X 802 -OnClick {
        $r = [System.Windows.Forms.MessageBox]::Show('确定要注销当前用户吗？', '确认', 'YesNo', 'Question')
        if ($r -eq 'Yes') { Start-Process -FilePath 'logoff.exe' | Out-Null }
    })

$script:OwnItems = @(Get-SavedPrograms)
Refresh-OwnList

$btnAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $args = ''
        $note = ''
        try {
            if (Get-Command Get-GuiReadyCatalogLaunchArgs -ErrorAction SilentlyContinue) {
                $args = Get-GuiReadyCatalogLaunchArgs -ExePath $dlg.FileName
            }
        } catch { }
        try {
            if (Get-Command Show-GuiReadyCatalogEntry -ErrorAction SilentlyContinue) {
                $ce = Show-GuiReadyCatalogEntry -ExePath $dlg.FileName -Quiet
                if ($ce -and $ce.Entry) {
                    $note = ('档案命中: {0}{1}结论: {2}' -f $ce.Entry.Name, [Environment]::NewLine, $ce.Entry.Verdict)
                }
            }
        } catch { }

        $item = [pscustomobject]@{
            Name = [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
            Path = $dlg.FileName
            Args = $args
        }
        $script:OwnItems += $item
        Refresh-OwnList
        Save-Programs -Items $script:OwnItems

        if ($note -or $args) {
            $m = $note
            if ($args) { $m += ([Environment]::NewLine + [Environment]::NewLine + '已自动带入推荐启动参数: ' + $args) }
            [System.Windows.Forms.MessageBox]::Show($m, '兼容档案', 'OK', 'Information') | Out-Null
        }
    }
})

$btnDel.Add_Click({
    if ($lstOwn.SelectedIndex -ge 0) {
        $i = $lstOwn.SelectedIndex
        $list = New-Object System.Collections.ArrayList
        for ($k = 0; $k -lt $script:OwnItems.Count; $k++) { if ($k -ne $i) { [void]$list.Add($script:OwnItems[$k]) } }
        $script:OwnItems = @($list)
        Refresh-OwnList
        Save-Programs -Items $script:OwnItems
    }
})

$btnRun.Add_Click({
    $it = Get-SelectedItem
    if (-not $it) { return }
    $a = ''
    if ($it.PSObject.Properties['Args']) { $a = [string]$it.Args }
    Start-Target -Target $it.Path -Arguments $a
})

$btnRunR.Add_Click({
    $it = Get-SelectedItem
    if (-not $it) { return }
    $a = ''
    try { $a = Get-GuiReadyCatalogLaunchArgs -ExePath $it.Path } catch { }
    if (-not $a) {
        [System.Windows.Forms.MessageBox]::Show('档案里没有这个程序的推荐参数。可以手动用“设置启动参数...”填写。', '无推荐参数', 'OK', 'Information') | Out-Null
        return
    }
    Start-Target -Target $it.Path -Arguments $a
})

$btnArgs.Add_Click({
    $it = Get-SelectedItem
    if (-not $it) { return }
    $cur = ''
    if ($it.PSObject.Properties['Args']) { $cur = [string]$it.Args }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { }
    $new = $cur
    try {
        $new = [Microsoft.VisualBasic.Interaction]::InputBox('启动参数（留空表示不带参数）:', ('启动参数 - ' + $it.Name), $cur)
    } catch {
        [System.Windows.Forms.MessageBox]::Show('无法弹出输入框，请在 programs.json 里手工添加 Args 字段。', '提示', 'OK', 'Warning') | Out-Null
        return
    }
    $it.Args = [string]$new
    Refresh-OwnList
    Save-Programs -Items $script:OwnItems
    Write-Log ('已保存启动参数: {0} -> "{1}"' -f $it.Name, $it.Args) 'OK'
})

$btnPers.Add_Click({
    $it = Get-SelectedItem
    if (-not $it) { return }
    if (-not (Get-Command Start-GuiReadyPersistentProcess -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show('Common 模块未加载，无法注册计划任务。', '不可用', 'OK', 'Warning') | Out-Null
        return
    }
    $a = ''
    if ($it.PSObject.Properties['Args']) { $a = [string]$it.Args }
    $msg = '将通过计划任务以 SYSTEM 身份启动它，这样进程不会随远程会话断开被杀掉。' + [Environment]::NewLine + [Environment]::NewLine +
           ('程序: {0}' -f $it.Path) + [Environment]::NewLine + ('参数: {0}' -f $(if ($a) { $a } else { '(无)' })) + [Environment]::NewLine + [Environment]::NewLine +
           '点“是”只启动；点“否”取消。'
    $r = [System.Windows.Forms.MessageBox]::Show($msg, '持久化启动', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $ok = Start-GuiReadyPersistentProcess -Name ('App-' + $it.Name) -ExePath $it.Path -Arguments $a
    if ($ok) {
        [System.Windows.Forms.MessageBox]::Show('已注册并启动计划任务: App-' + $it.Name, '完成', 'OK', 'Information') | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show('注册计划任务失败，详情见日志。', '失败', 'OK', 'Warning') | Out-Null
    }
})

$btnDiag.Add_Click({
    $it = Get-SelectedItem
    if (-not $it) { return }
    if (-not (Get-Command Get-GuiReadyAppDiagnostics -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show('Diag 模块未加载。', '不可用', 'OK', 'Warning') | Out-Null
        return
    }
    $d = Get-GuiReadyAppDiagnostics -ExePath $it.Path -Minutes 60
    $m = ('进程数: {0}    事件日志(相关): {1}    WER(相关): {2}    缺失依赖: {3}' -f $d.Processes.Count, $d.EventErrors.Count, $d.WerMatching.Count, $d.MissingPkg.Count) + [Environment]::NewLine + [Environment]::NewLine
    if ($d.Findings.Count -gt 0) {
        $m += '可能原因与建议:' + [Environment]::NewLine
        foreach ($f in $d.Findings) { $m += ('  · ' + $f.Cause) + [Environment]::NewLine + ('    ' + $f.Advice) + [Environment]::NewLine }
    } else {
        $m += '未发现异常特征。'
    }
    [System.Windows.Forms.MessageBox]::Show($m, '诊断结果', 'OK', 'Information') | Out-Null
})

$btnCata.Add_Click({
    $it = Get-SelectedItem
    if (-not $it) { return }
    if (-not (Get-Command Show-GuiReadyCatalogEntry -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show('Catalog 模块未加载。', '不可用', 'OK', 'Warning') | Out-Null
        return
    }
    $ce = Show-GuiReadyCatalogEntry -ExePath $it.Path -Quiet
    if (-not $ce -or -not $ce.Entry) {
        [System.Windows.Forms.MessageBox]::Show('档案里没有这个程序。可以在命令行菜单 4 -> 3 添加你自己的结论。', '无档案条目', 'OK', 'Information') | Out-Null
        return
    }
    $e = $ce.Entry
    $m = ('条目: {0}' -f $e.Name) + [Environment]::NewLine
    $m += ('类型: {0}' -f $e.Type) + [Environment]::NewLine
    $m += ('结论: {0}' -f $e.Verdict) + [Environment]::NewLine
    if ($e.LaunchArgs) { $m += ('推荐参数: {0}' -f $e.LaunchArgs) + [Environment]::NewLine }
    if ($e.VerifiedOn) { $m += ('实测 build: {0}' -f $e.VerifiedOn) + [Environment]::NewLine }
    $m += [Environment]::NewLine + $e.Notes
    [System.Windows.Forms.MessageBox]::Show($m, '程序兼容档案', 'OK', 'Information') | Out-Null
})

$btnPick.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $pe = Get-PeImageInfo -Path $dlg.FileName
        if (-not $pe.IsPe) {
            [System.Windows.Forms.MessageBox]::Show('不是有效的 PE 文件: ' + $pe.Error, '检查结果', 'OK', 'Warning') | Out-Null
            return
        }
        $dir = Split-Path -Parent $dlg.FileName
        $missing = @()
        foreach ($m in @($pe.Imports + $pe.DelayImports | Sort-Object -Unique)) {
            if ($m -match '^(api-ms-win-|ext-ms-win-)') { continue }
            if (-not (Test-ModuleResolvable -Name $m -AppDir $dir)) { $missing += $m }
        }
        $kind = Get-FileKindTag -Path $dlg.FileName -PeInfo $pe
        $msg  = ('架构: {0}    子系统: {1}' -f $pe.MachineName, $pe.SubsystemName) + [Environment]::NewLine
        $msg += ('.NET: {0}    类型: {1}' -f (Format-Bool $pe.IsDotNet), $(if ($kind) { $kind } else { '未识别' })) + [Environment]::NewLine
        if ($missing.Count -eq 0) {
            $msg += '静态依赖齐全，可以尝试运行。'
        } else {
            $msg += ('缺失 {0} 个模块:' -f $missing.Count) + [Environment]::NewLine + (($missing | Select-Object -First 12) -join ', ')
        }
        try {
            $ce = Show-GuiReadyCatalogEntry -ExePath $dlg.FileName -Quiet
            if ($ce -and $ce.Entry) {
                $msg += [Environment]::NewLine + [Environment]::NewLine + ('档案结论: {0}' -f $ce.Entry.Verdict)
                if ($ce.Entry.LaunchArgs) { $msg += [Environment]::NewLine + ('推荐参数: {0}' -f $ce.Entry.LaunchArgs) }
            }
        } catch { }
        [System.Windows.Forms.MessageBox]::Show($msg, '兼容性检查', 'OK', 'Information') | Out-Null
    }
})

Write-Log '图形启动器已启动' 'OK'

if ($SelfTest) {
    try {
        $form.CreateControl()
        $n = $flow.Controls.Count
        $b = $bottom.Controls.Count
        $o = 0
        foreach ($c in $grpOwn.Controls) { if ($c -is [System.Windows.Forms.Button]) { $o++ } }
        Write-Host ('SELFTEST OK: 工具按钮 {0} 个, 我的程序按钮 {1} 个, 底部按钮 {2} 个, 窗体尺寸 {3}' -f $n, $o, $b, $form.Size.ToString()) -ForegroundColor Green
        $form.Dispose()
        Write-Log '自检通过' 'OK'
    } catch {
        Write-Host ('SELFTEST FAIL: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Log ('自检失败: ' + $_.Exception.Message) 'ERROR'
    }
    return
}

[void]$form.ShowDialog()
Write-Log '图形启动器已退出' 'INFO'

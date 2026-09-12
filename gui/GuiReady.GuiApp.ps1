# GuiReady GUI: 环境补全 + 软件管理，界面重做。
# 主页面只有两个：环境 / 软件；完整能力收在「更多」里，不干扰主流程。
# 每个动作在独立子进程执行，界面不卡；日志按级别着色。

param(
    [switch]$SelfTest,
    [switch]$LayoutDump,
    [string]$StartPage = 'env',
    [switch]$KeepConsole
)

$ErrorActionPreference = 'Continue'

$guiDir   = $PSScriptRoot
$toolRoot = Split-Path -Parent $guiDir
$libDir   = Join-Path $toolRoot 'lib'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Detect.ps1', 'GuiReady.PeInspect.ps1',
                 'GuiReady.Fod.ps1', 'GuiReady.GuiShell.ps1', 'GuiReady.RdpFix.ps1',
                 'GuiReady.DotNet.ps1', 'GuiReady.GuiTest.ps1', 'GuiReady.Matrix.ps1',
                 'GuiReady.Diag.ps1', 'GuiReady.Catalog.ps1', 'GuiReady.Pipeline.ps1',
                 'GuiReady.AutoLogon.ps1', 'GuiReady.Command.ps1', 'GuiReady.PhaseB.ps1', 'GuiReady.Wac.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}
. (Join-Path $guiDir 'GuiReady.Actions.ps1')

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    Write-Host '无法加载 WinForms，改用命令行菜单。' -ForegroundColor Yellow
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolRoot 'Start-GuiReady.ps1')
    return
}

$script:Actions       = @(Get-GuiReadyActions)
$script:CurrentAction = $null
$script:ParamControls = @{}
$script:Proc          = $null
$script:OutFile       = ''
$script:ErrFile       = ''
$script:RunLogFile    = ''
$script:ReadLines     = 0
$script:RunStart      = $null
$script:RunnerPath    = Join-Path $guiDir 'Run-GuiReadyAction.ps1'
$script:ProgramStore  = Join-Path $toolRoot 'launcher\programs.json'
$script:Programs      = @()
$script:Cards         = @()
$script:NavButtons    = @()
$script:Pages         = @{}
$script:CurrentPage   = ''

$script:HidConsole = [System.IntPtr]::Zero
if (-not $KeepConsole) {
    try {
        Add-Type -Namespace GrGui -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        $script:HidConsole = [GrGui.Win]::GetConsoleWindow()
        if ($script:HidConsole -ne [System.IntPtr]::Zero) { [void][GrGui.Win]::ShowWindow($script:HidConsole, 0) }
    } catch { }
}

[void][System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ============================ 配色与工具函数 ============================

# 参考 PCL2 / PCL-CE 的做法：主题色不是写死的一堆色值，而是由 HSL 生成一整套色阶，
# 这样主色、悬停、按下、浅底、语义色之间是协调的。这里以 210° 蓝为主色。
function Convert-HslToColor {
    param([double]$Hue, [double]$Sat, [double]$Light)
    $h = ((($Hue % 360) + 360) % 360) / 360.0
    $s = [Math]::Min(1.0, [Math]::Max(0.0, $Sat))
    $l = [Math]::Min(1.0, [Math]::Max(0.0, $Light))
    $r = 0.0; $g = 0.0; $b = 0.0
    if ($s -eq 0) {
        $r = $l; $g = $l; $b = $l
    } else {
        $q = 0.0
        if ($l -lt 0.5) { $q = $l * (1 + $s) } else { $q = $l + $s - $l * $s }
        $p = 2 * $l - $q
        for ($i = 0; $i -le 2; $i++) {
            $t = $h + (1 - $i) / 3.0
            if ($t -lt 0) { $t += 1 } elseif ($t -gt 1) { $t -= 1 }
            $v = 0.0
            if ($t -lt (1 / 6)) { $v = $p + ($q - $p) * 6 * $t }
            elseif ($t -lt (1 / 2)) { $v = $q }
            elseif ($t -lt (2 / 3)) { $v = $p + ($q - $p) * ((2 / 3) - $t) * 6 }
            else { $v = $p }
            if ($i -eq 0) { $r = $v } elseif ($i -eq 1) { $g = $v } else { $b = $v }
        }
    }
    return [System.Drawing.Color]::FromArgb(
        [int][Math]::Round($r * 255), [int][Math]::Round($g * 255), [int][Math]::Round($b * 255))
}

$Pal = @{
    # 主题色阶（越往下越浅）
    Accent1   = Convert-HslToColor 210 0.72 0.34   # 按下 / 描边
    Accent2   = Convert-HslToColor 210 0.78 0.46   # 主色
    Accent3   = Convert-HslToColor 210 0.74 0.56   # 悬停（比主色更亮）
    Accent4   = Convert-HslToColor 210 0.82 0.93   # 选中项浅底
    Accent5   = Convert-HslToColor 210 0.85 0.88   # 更浅的底

    # 语义色
    Ok        = Convert-HslToColor 145 0.62 0.40
    Warn      = Convert-HslToColor 35  0.88 0.46
    Err       = Convert-HslToColor 0   0.70 0.50
    OkBg      = Convert-HslToColor 145 0.55 0.94
    WarnBg    = Convert-HslToColor 35  0.90 0.94
    ErrBg     = Convert-HslToColor 0   0.75 0.95

    # 背景与文字（比上一版更亮、更通透，且不用渐变）
    Bg        = Convert-HslToColor 210 0.22 0.976
    Card      = [System.Drawing.Color]::White
    Border    = Convert-HslToColor 210 0.16 0.885
    NavBg     = Convert-HslToColor 210 0.28 0.966
    Text      = Convert-HslToColor 215 0.25 0.15
    SubText   = Convert-HslToColor 215 0.13 0.44
    Hint      = Convert-HslToColor 215 0.10 0.62

    # 日志面板（深色，偏主题色相，看起来是一个整体）
    LogBg     = Convert-HslToColor 215 0.30 0.13
    LogBarBg  = Convert-HslToColor 215 0.26 0.18
    LogText   = Convert-HslToColor 210 0.18 0.90

    # 兼容旧命名
    Accent    = Convert-HslToColor 210 0.78 0.46
    AccentHi  = Convert-HslToColor 210 0.74 0.56
}

function New-Font {
    param([string]$Family = 'Microsoft YaHei UI', [double]$Size = 9.5, [string]$Style = 'Regular')
    $st = [System.Drawing.FontStyle]::$Style
    return New-Object System.Drawing.Font -ArgumentList $Family, $Size, $st
}

function Set-Rounded {
    param([System.Windows.Forms.Control]$Control, [int]$Radius = 10)
    try {
        $w = $Control.Width; $h = $Control.Height
        if ($w -le 0 -or $h -le 0) { return }
        $r = [Math]::Min($Radius, [Math]::Min($w, $h) / 2)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $r, $r, 180, 90)
        $path.AddArc(($w - $r - 1), 0, $r, $r, 270, 90)
        $path.AddArc(($w - $r - 1), ($h - $r - 1), $r, $r, 0, 90)
        $path.AddArc(0, ($h - $r - 1), $r, $r, 90, 90)
        $path.CloseAllFigures()
        $Control.Region = New-Object System.Drawing.Region -ArgumentList $path
    } catch { }
}

function New-FlatButton {
    param(
        [string]$Text,
        [int]$Width = 132,
        [int]$Height = 36,
        [string]$Kind = 'Normal',      # Normal | Primary | Danger
        [int]$Radius = 8,
        [scriptblock]$OnClick = $null
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Size      = New-Object System.Drawing.Size($Width, $Height)
    $b.FlatStyle = 'Flat'
    $b.Font      = New-Font -Size 9.5
    $b.Cursor    = 'Hand'
    $b.FlatAppearance.BorderSize = 1
    switch ($Kind) {
        'Primary' {
            # 对应 PCL 的 ColorType=Highlight：实心主题色，悬停更亮、按下更深
            $b.BackColor = $Pal.Accent2
            $b.ForeColor = [System.Drawing.Color]::White
            $b.FlatAppearance.BorderColor = $Pal.Accent2
            $b.FlatAppearance.MouseOverBackColor = $Pal.Accent3
            $b.FlatAppearance.MouseDownBackColor = $Pal.Accent1
        }
        'Danger' {
            $b.BackColor = [System.Drawing.Color]::White
            $b.ForeColor = $Pal.Err
            $b.FlatAppearance.BorderColor = $Pal.ErrBg
            $b.FlatAppearance.MouseOverBackColor = $Pal.ErrBg
            $b.FlatAppearance.MouseDownBackColor = $Pal.ErrBg
        }
        default {
            $b.BackColor = [System.Drawing.Color]::White
            $b.ForeColor = $Pal.Text
            $b.FlatAppearance.BorderColor = $Pal.Border
            $b.FlatAppearance.MouseOverBackColor = $Pal.Accent4
            $b.FlatAppearance.MouseDownBackColor = $Pal.Accent5
        }
    }
    Set-Rounded -Control $b -Radius $Radius
    if ($OnClick) { $b.Add_Click($OnClick) }
    return $b
}

function New-HintBar {
    # 对应 PCL 的 MyHint：浅色底 + 左侧色条，用于说明性文字
    param([string]$Text, [string]$Kind = 'Blue', [int]$Width = 600)
    $bg = $Pal.Accent4
    $bar = $Pal.Accent2
    switch ($Kind) {
        'Green'  { $bg = $Pal.OkBg;   $bar = $Pal.Ok }
        'Yellow' { $bg = $Pal.WarnBg; $bar = $Pal.Warn }
        'Red'    { $bg = $Pal.ErrBg;  $bar = $Pal.Err }
    }
    $host_ = New-Object System.Windows.Forms.Panel
    $host_.Size      = New-Object System.Drawing.Size($Width, 30)
    $host_.BackColor = $bg
    $edge = New-Object System.Windows.Forms.Panel
    $edge.Size      = New-Object System.Drawing.Size(3, 30)
    $edge.Location  = New-Object System.Drawing.Point(0, 0)
    $edge.BackColor = $bar
    $host_.Controls.Add($edge)
    $lb = New-Label -Text $Text -Size 9 -Color 'SubText'
    $lb.Location = New-Object System.Drawing.Point(12, 6)
    $lb.AutoSize = $false
    $lb.Size = New-Object System.Drawing.Size(($Width - 20), 20)
    $host_.Controls.Add($lb)
    Set-Rounded -Control $host_ -Radius 6
    Set-Rounded -Control $edge -Radius 3
    $host_.Tag = $lb      # 便于自适应布局时同步改内部文字宽度
    return $host_
}

function New-Label {
    param([string]$Text, [double]$Size = 9.5, [string]$Color = 'Text', [string]$Style = 'Regular', [int]$Width = 0)
    $l = New-Object System.Windows.Forms.Label
    $l.Text    = $Text
    $l.Font    = New-Font -Size $Size -Style $Style
    # 注意：PowerShell 变量名不区分大小写，所以配色表叫 $Pal 而不是 $C，
    # 免得被本地的 $c/$card 之类覆盖掉。这里再做一次兜底，取不到颜色也不至于让界面报错。
    $col = $Pal[$Color]
    if ($null -eq $col) { $col = $Pal['Text'] }
    $l.ForeColor = $col
    $l.BackColor = [System.Drawing.Color]::Transparent
    if ($Width -gt 0) { $l.AutoSize = $false; $l.Size = New-Object System.Drawing.Size($Width, 20) } else { $l.AutoSize = $true }
    return $l
}

# ============================ 窗体骨架 ============================

$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'Server Core GUI 就绪工具'
$form.Size          = New-Object System.Drawing.Size(1160, 780)
$form.MinimumSize   = New-Object System.Drawing.Size(1000, 660)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $Pal.Bg
$form.Font          = New-Font -Size 9.5
$form.KeyPreview    = $true

# ---- 顶部标题栏 ----
$pnlHead           = New-Object System.Windows.Forms.Panel
$pnlHead.Dock      = 'Top'
$pnlHead.Height    = 68
$pnlHead.BackColor = $Pal.Card
$form.Controls.Add($pnlHead)

$lblTitle          = New-Label -Text 'Server Core GUI 就绪工具' -Size 15 -Style Bold
$lblTitle.Location = New-Object System.Drawing.Point(22, 12)
$pnlHead.Controls.Add($lblTitle)

$lblSub          = New-Label -Text '把带界面的程序在 Server Core 上跑起来' -Size 9.5 -Color Hint
$lblSub.Location = New-Object System.Drawing.Point(24, 42)
$pnlHead.Controls.Add($lblSub)

$pnlHeadLine           = New-Object System.Windows.Forms.Panel
$pnlHeadLine.Dock      = 'Bottom'
$pnlHeadLine.Height    = 1
$pnlHeadLine.BackColor = $Pal.Border
$pnlHead.Controls.Add($pnlHeadLine)

$btnExitBack           = New-FlatButton -Text '退出（返回命令行）' -Width 168 -Kind Danger
$btnExitBack.Anchor    = 'Top,Right'
$btnExitBack.Location  = New-Object System.Drawing.Point(($form.ClientSize.Width - 190), 18)
$pnlHead.Controls.Add($btnExitBack)

# ---- 左侧导航 ----
$pnlNav           = New-Object System.Windows.Forms.Panel
$pnlNav.Dock      = 'Left'
$pnlNav.Width     = 196
$pnlNav.BackColor = $Pal.NavBg
$form.Controls.Add($pnlNav)

$pnlNavLine           = New-Object System.Windows.Forms.Panel
$pnlNavLine.Dock      = 'Right'
$pnlNavLine.Width     = 1
$pnlNavLine.BackColor = $Pal.Border
$pnlNav.Controls.Add($pnlNavLine)

$pnlNavTop           = New-Object System.Windows.Forms.Panel
$pnlNavTop.Dock      = 'Top'
$pnlNavTop.Height    = 218
$pnlNavTop.BackColor = [System.Drawing.Color]::Transparent
$pnlNav.Controls.Add($pnlNavTop)

function New-NavItem {
    # 参考 PCL 的左侧导航：选中项是一块圆角的主题浅色底，而不是默认按钮那种方框
    param([string]$Text, [string]$PageKey, [int]$Y)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Size      = New-Object System.Drawing.Size(172, 44)
    $b.Location  = New-Object System.Drawing.Point(12, $Y)
    $b.FlatStyle = 'Flat'
    $b.TextAlign = 'MiddleLeft'
    $b.Padding   = New-Object System.Windows.Forms.Padding(20, 0, 0, 0)
    $b.Font      = New-Font -Size 11
    $b.BackColor = $Pal.NavBg
    $b.ForeColor = $Pal.SubText
    $b.Cursor    = 'Hand'
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $Pal.Accent5
    $b.FlatAppearance.MouseDownBackColor = $Pal.Accent4
    Set-Rounded -Control $b -Radius 8
    $b.Tag = @{ Page = $PageKey }
    $b.Add_Click({
        $info = $this.Tag
        Show-GuiPage -Key $info.Page
    })
    $pnlNavTop.Controls.Add($b)
    return $b
}

$navEnv  = New-NavItem -Text '环境'     -PageKey 'env'  -Y 10
$navApp  = New-NavItem -Text '软件'     -PageKey 'app'  -Y 60
$navTool = New-NavItem -Text '工具'     -PageKey 'tool' -Y 110
$navMore = New-NavItem -Text '更多'     -PageKey 'more' -Y 160
$script:NavButtons = @($navEnv, $navApp, $navTool, $navMore)

$lblVer = New-Label -Text ('v1.0  ' + (Get-Date -Format 'yyyy-MM-dd')) -Size 8.5 -Color Hint
$lblVer.Dock = 'Bottom'
$lblVer.Height = 26
$lblVer.TextAlign = 'MiddleLeft'
$lblVer.Padding = New-Object System.Windows.Forms.Padding(20, 0, 0, 0)
$pnlNav.Controls.Add($lblVer)

# ---- 右侧内容 + 日志 ----
$pnlRight = New-Object System.Windows.Forms.Panel
$pnlRight.Dock      = 'Fill'
$pnlRight.BackColor = $Pal.Bg
$pnlRight.Padding   = New-Object System.Windows.Forms.Padding(16, 12, 16, 8)
$form.Controls.Add($pnlRight)

$pnlLog           = New-Object System.Windows.Forms.Panel
$pnlLog.Dock      = 'Bottom'
$pnlLog.Height    = 216
$pnlLog.BackColor = $Pal.LogBg
$pnlLog.Padding   = New-Object System.Windows.Forms.Padding(1)
$pnlRight.Controls.Add($pnlLog)
Set-Rounded -Control $pnlLog -Radius 8

$pnlLogBar           = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlLogBar.Dock      = 'Top'
$pnlLogBar.Height    = 32
$pnlLogBar.Padding   = New-Object System.Windows.Forms.Padding(10, 3, 8, 0)
$pnlLogBar.BackColor = $Pal.LogBarBg
$pnlLog.Controls.Add($pnlLogBar)

$lblLogTitle          = New-Label -Text '执行日志' -Size 9.5 -Color LogText
$lblLogTitle.Margin   = New-Object System.Windows.Forms.Padding(0, 7, 16, 0)
$pnlLogBar.Controls.Add($lblLogTitle)

function New-LogBtn {
    param([string]$Text, [scriptblock]$OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Size      = New-Object System.Drawing.Size(92, 24)
    $b.Margin    = New-Object System.Windows.Forms.Padding(3, 3, 3, 0)
    $b.FlatStyle = 'Flat'
    $b.ForeColor = $Pal.LogText
    $b.BackColor = $Pal.Accent1
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $Pal.Accent2
    $b.Cursor = 'Hand'
    Set-Rounded -Control $b -Radius 6
    $b.Add_Click($OnClick)
    $pnlLogBar.Controls.Add($b)
    return $b
}

[void](New-LogBtn -Text '清空' -OnClick { $txtLog.Clear(); $script:ReadLines = 0 })
[void](New-LogBtn -Text '打开日志文件' -OnClick {
        if ($script:RunLogFile -and (Test-Path -LiteralPath $script:RunLogFile)) { Start-Process -FilePath $script:RunLogFile | Out-Null }
        else { [System.Windows.Forms.MessageBox]::Show('本次还没有日志文件。', '提示', 'OK', 'Information') | Out-Null }
    })
[void](New-LogBtn -Text '打开报告目录' -OnClick { Start-Process -FilePath (Join-Path $toolRoot 'reports') | Out-Null })

$btnStopTop        = New-LogBtn -Text '停止当前动作' -OnClick {
    if ($script:Proc) {
        try { Stop-Process -Id $script:Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        Append-GuiLog -Line '[WARN] 已按你的要求停止动作。'
        Finish-GuiAction -ExitCode -1
    }
}

$txtLog              = New-Object System.Windows.Forms.RichTextBox
$txtLog.Dock         = 'Fill'
$txtLog.ReadOnly     = $true
$txtLog.BorderStyle  = 'None'
$txtLog.BackColor    = $Pal.LogBg
$txtLog.ForeColor    = $Pal.LogText
$txtLog.WordWrap     = $false
$txtLog.HideSelection = $false
$txtLog.Font         = New-Font -Family Consolas -Size 9.5
$pnlLog.Controls.Add($txtLog)
$txtLog.BringToFront()

$pnlContent = New-Object System.Windows.Forms.Panel
$pnlContent.Dock      = 'Fill'
$pnlContent.BackColor = $Pal.Bg
$pnlRight.Controls.Add($pnlContent)
$pnlContent.BringToFront()

# ============================ 环境页 ============================

$pageEnv           = New-Object System.Windows.Forms.Panel
$pageEnv.Dock      = 'Fill'
$pageEnv.BackColor = $Pal.Bg
$pageEnv.AutoScroll = $true     # 窗口很小的时候宁可出滚动条，也不要裁掉内容
$script:Pages['env'] = $pageEnv
$pnlContent.Controls.Add($pageEnv)

$lblEnvHead          = New-Label -Text '环境补全' -Size 12 -Style Bold
$lblEnvHead.Location = New-Object System.Drawing.Point(2, 2)
$pageEnv.Controls.Add($lblEnvHead)

$lblEnvDesc          = New-Label -Text '先看这台机器缺什么，再一键补齐。补齐后 Server Core 就能运行带界面的程序。' -Size 9.5 -Color SubText
$lblEnvDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageEnv.Controls.Add($lblEnvDesc)

$pnlCards           = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlCards.Location  = New-Object System.Drawing.Point(0, 56)
$pnlCards.Size      = New-Object System.Drawing.Size(900, 150)
$pnlCards.Anchor    = 'Top,Left,Right'
$pnlCards.BackColor = $Pal.Bg
$pnlCards.WrapContents = $true
$pageEnv.Controls.Add($pnlCards)

$pnlEnvActions           = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlEnvActions.Location  = New-Object System.Drawing.Point(0, 216)
$pnlEnvActions.Size      = New-Object System.Drawing.Size(900, 56)
$pnlEnvActions.Anchor    = 'Top,Left,Right'
$pnlEnvActions.BackColor = $Pal.Bg
$pageEnv.Controls.Add($pnlEnvActions)

$btnFill = New-FlatButton -Text '一键补全' -Width 140 -Height 42 -Kind Primary
$btnFill.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$btnFill.Add_Click({ Start-GuiActionById -Id 'pipeline-auto' -DryRun $false })
$pnlEnvActions.Controls.Add($btnFill)

$btnDetect = New-FlatButton -Text '重新探测' -Width 96 -Height 42
$btnDetect.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$btnDetect.Add_Click({ Start-GuiActionById -Id 'detect' -DryRun $false })
$pnlEnvActions.Controls.Add($btnDetect)

$btnSelfTest = New-FlatButton -Text 'GUI 自检' -Width 110 -Height 42
$btnSelfTest.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$btnSelfTest.Add_Click({ Start-GuiActionById -Id 'guitest' -DryRun $false })
$pnlEnvActions.Controls.Add($btnSelfTest)

$btnMatrix = New-FlatButton -Text '结论路线' -Width 110 -Height 42
$btnMatrix.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$btnMatrix.Add_Click({ Start-GuiActionById -Id 'matrix' -DryRun $false })
$pnlEnvActions.Controls.Add($btnMatrix)

$btnAutoLogon = New-FlatButton -Text '自动登录' -Width 100 -Height 42
$btnAutoLogon.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$btnAutoLogon.Add_Click({ Start-GuiActionById -Id 'autologon-status' -DryRun $false })
$pnlEnvActions.Controls.Add($btnAutoLogon)

$btnWac = New-FlatButton -Text 'Windows Admin Center' -Width 170 -Height 42
$btnWac.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$btnWac.Add_Click({ Start-GuiActionById -Id 'wac-status' -DryRun $false })
$pnlEnvActions.Controls.Add($btnWac)

$hintEnv = New-HintBar -Text '提示：一键补全会按需安装官方 FOD、补齐 .NET 运行时；需要重启时会自动重启并接着跑完。' -Kind Blue -Width 900
$hintEnv.Location = New-Object System.Drawing.Point(0, 330)
$pageEnv.Controls.Add($hintEnv)

# ============================ 软件页 ============================

$pageApp           = New-Object System.Windows.Forms.Panel
$pageApp.Dock      = 'Fill'
$pageApp.BackColor = $Pal.Bg
$script:Pages['app'] = $pageApp
$pnlContent.Controls.Add($pageApp)

$lblAppHead          = New-Label -Text '软件管理' -Size 12 -Style Bold
$lblAppHead.Location = New-Object System.Drawing.Point(2, 2)
$pageApp.Controls.Add($lblAppHead)

$lblAppDesc          = New-Label -Text '把你需要的程序加进来，双击即可启动。加程序时会自动带入实测推荐参数（例如 Electron 类程序会带上禁用 GPU 的参数）。' -Size 9.5 -Color SubText
$lblAppDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageApp.Controls.Add($lblAppDesc)

$lstApps           = New-Object System.Windows.Forms.ListView
$lstApps.Location  = New-Object System.Drawing.Point(0, 56)
$lstApps.Size      = New-Object System.Drawing.Size(900, 236)
$lstApps.Anchor    = 'Top,Left,Right'
$lstApps.View      = 'Details'
$lstApps.FullRowSelect = $true
$lstApps.GridLines = $false
$lstApps.BorderStyle = 'FixedSingle'
$lstApps.HideSelection = $false
$lstApps.Font      = New-Font -Size 9.5
[void]$lstApps.Columns.Add('名称', 170)
[void]$lstApps.Columns.Add('路径', 400)
[void]$lstApps.Columns.Add('启动参数', 190)
[void]$lstApps.Columns.Add('兼容结论', 120)
$pageApp.Controls.Add($lstApps)

$pnlAppActions           = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlAppActions.Location  = New-Object System.Drawing.Point(0, 300)
$pnlAppActions.Size      = New-Object System.Drawing.Size(900, 100)
$pnlAppActions.Anchor    = 'Top,Left,Right'
$pnlAppActions.BackColor = $Pal.Bg
$pageApp.Controls.Add($pnlAppActions)

$btnAppAdd = New-FlatButton -Text '添加程序…' -Width 110 -Height 38 -Kind Primary
$btnAppAdd.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$pnlAppActions.Controls.Add($btnAppAdd)

$btnAppRun = New-FlatButton -Text '启动' -Width 88 -Height 38
$btnAppRun.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$pnlAppActions.Controls.Add($btnAppRun)

$btnAppArgs = New-FlatButton -Text '设置参数…' -Width 110 -Height 38
$btnAppArgs.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$pnlAppActions.Controls.Add($btnAppArgs)

$btnAppPersist = New-FlatButton -Text '后台常驻' -Width 110 -Height 38
$btnAppPersist.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$pnlAppActions.Controls.Add($btnAppPersist)

$btnAppDiag = New-FlatButton -Text '启动诊断' -Width 100 -Height 38
$btnAppDiag.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$pnlAppActions.Controls.Add($btnAppDiag)

$btnAppCatalog = New-FlatButton -Text '查看档案' -Width 100 -Height 38
$btnAppCatalog.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$pnlAppActions.Controls.Add($btnAppCatalog)

$btnAppDel = New-FlatButton -Text '移除' -Width 80 -Height 38 -Kind Danger
$btnAppDel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$pnlAppActions.Controls.Add($btnAppDel)

$hintApp = New-HintBar -Text '说明：“后台常驻”会用 SYSTEM 计划任务启动，进程不会随远程会话断开被杀掉——守护类程序用这个。' -Kind Blue -Width 900
$hintApp.Location = New-Object System.Drawing.Point(0, 404)
$pageApp.Controls.Add($hintApp)

# ============================ 系统工具页 ============================
# Server Core 默认没有这些图形工具，装了官方 App Compatibility FOD 才会出现。
# 所以这里不藏起来，而是列全并灰显缺失的 —— 用户能直接看到“缺什么、去环境页补”。

$script:ToolGroups = @(
    [pscustomobject]@{ Group = '常用'; Items = @(
        @{ Name = '记事本';         Target = 'notepad.exe' },
        @{ Name = '文件资源管理器'; Target = 'explorer.exe' },
        @{ Name = '命令提示符';     Target = 'cmd.exe' },
        @{ Name = 'PowerShell';     Target = 'powershell.exe' }
    ) }
    [pscustomobject]@{ Group = '系统管理'; Items = @(
        @{ Name = '任务管理器';     Target = 'taskmgr.exe' },
        @{ Name = 'MMC 控制台';     Target = 'mmc.exe' },
        @{ Name = '服务';           Target = 'services.msc' },
        @{ Name = '设备管理器';     Target = 'devmgmt.msc' },
        @{ Name = '磁盘管理';       Target = 'diskmgmt.msc' },
        @{ Name = '任务计划程序';   Target = 'taskschd.msc' }
    ) }
    [pscustomobject]@{ Group = '安全与账户'; Items = @(
        @{ Name = '本地用户和组';   Target = 'lusrmgr.msc' },
        @{ Name = '证书管理';       Target = 'certmgr.msc' },
        @{ Name = '防火墙高级安全'; Target = 'wf.msc' },
        @{ Name = '注册表编辑器';   Target = 'regedit.exe' }
    ) }
    [pscustomobject]@{ Group = '诊断与信息'; Items = @(
        @{ Name = '事件查看器';     Target = 'eventvwr.msc' },
        @{ Name = '性能监视器';     Target = 'perfmon.exe' },
        @{ Name = '资源监视器';     Target = 'resmon.exe' },
        @{ Name = '系统信息';       Target = 'msinfo32.exe' }
    ) }
    [pscustomobject]@{ Group = '虚拟化与脚本'; Items = @(
        @{ Name = 'Hyper-V 管理器'; Target = 'virtmgmt.msc' },
        @{ Name = 'PowerShell ISE'; Target = 'powershell_ise.exe' }
    ) }
)

function Resolve-SystemToolPath {
    param([string]$Target)
    # 先找 System32；explorer.exe 这类其实在 Windows 根目录，所以再走一次 PATH 解析
    $p = Join-Path (Join-Path $env:windir 'System32') $Target
    if (Test-Path -LiteralPath $p) { return $p }
    try {
        $c = Get-Command $Target -ErrorAction SilentlyContinue
        if ($c) { return [string]$c.Source }
    } catch { }
    return ''
}

function Start-SystemTool {
    param([string]$Target, [string]$Name)

    $resolved = Resolve-SystemToolPath -Target $Target
    if (-not $resolved) {
        $msg = ('找不到 ' + $Target + '。' + [Environment]::NewLine + [Environment]::NewLine +
                '这类图形工具需要先安装官方 App Compatibility FOD，' + [Environment]::NewLine +
                '可以在左侧「环境」页点“一键补全环境”。' + [Environment]::NewLine + [Environment]::NewLine +
                '现在用命令提示符代替打开吗？')
        if ([System.Windows.Forms.MessageBox]::Show($msg, ('工具不可用 - ' + $Name), 'YesNo', 'Warning') -eq 'Yes') {
            try { Start-Process -FilePath (Join-Path (Join-Path $env:windir 'System32') 'cmd.exe') -WorkingDirectory $env:USERPROFILE | Out-Null } catch { }
        }
        return
    }

    try {
        if ($resolved -match '\.msc$') {
            # .msc 是管理单元，必须由 mmc.exe 承载
            $mmc = Resolve-SystemToolPath -Target 'mmc.exe'
            if (-not $mmc) {
                [System.Windows.Forms.MessageBox]::Show('这个管理单元需要 mmc.exe，但当前系统上没有。请先在「环境」页补全环境（安装 FOD）。', '缺少 mmc.exe', 'OK', 'Warning') | Out-Null
                return
            }
            Start-Process -FilePath $mmc -ArgumentList ('"' + $resolved + '"') | Out-Null
        } else {
            Start-Process -FilePath $resolved -WorkingDirectory (Split-Path -Parent $resolved) | Out-Null
        }
        Append-GuiLog -Line ('[OK] 已启动系统工具: ' + $Name + '   (' + $resolved + ')')
    } catch {
        Append-GuiLog -Line ('[ERROR] 启动 ' + $Name + ' 失败: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, ('启动失败 - ' + $Name), 'OK', 'Error') | Out-Null
    }
}

function Update-ToolButtons {
    foreach ($tb in $script:ToolButtons) {
        $r = Resolve-SystemToolPath -Target $tb.Target
        if ($r) {
            $tb.Button.Enabled = $true
            $tb.Button.Text    = $tb.Name
        } else {
            $tb.Button.Enabled = $false
            $tb.Button.Text    = $tb.Name + '（缺失）'
        }
    }
}

$pageTool           = New-Object System.Windows.Forms.Panel
$pageTool.Dock      = 'Fill'
$pageTool.BackColor = $Pal.Bg
$pageTool.Padding   = New-Object System.Windows.Forms.Padding(0, 56, 0, 6)
$script:Pages['tool'] = $pageTool
$pnlContent.Controls.Add($pageTool)

$lblToolHead          = New-Label -Text '系统工具' -Size 12 -Style Bold
$lblToolHead.Location = New-Object System.Drawing.Point(2, 2)
$pageTool.Controls.Add($lblToolHead)

$lblToolDesc          = New-Label -Text 'Server Core 默认没有这些图形工具，装了官方 App Compatibility FOD 才会出现；灰显的表示当前机器上还没有。' -Size 9.5 -Color SubText
$lblToolDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageTool.Controls.Add($lblToolDesc)

$script:ToolButtons = New-Object System.Collections.ArrayList
$script:ToolRows    = New-Object System.Collections.ArrayList

# 先放 Fill 的容器，再放 Bottom 的提示条：WinForms 里这样排才是“提示条贴底、容器占剩余”
$pnlTools                = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlTools.Dock           = 'Fill'
$pnlTools.FlowDirection  = 'TopDown'
$pnlTools.WrapContents   = $false
$pnlTools.AutoScroll     = $true
$pnlTools.BackColor      = $Pal.Bg
$pageTool.Controls.Add($pnlTools)

foreach ($g in $script:ToolGroups) {
    $hdr = New-Label -Text $g.Group -Size 10 -Style Bold -Color SubText
    $hdr.Margin = New-Object System.Windows.Forms.Padding(2, 4, 0, 2)
    $pnlTools.Controls.Add($hdr)

    $row = New-Object System.Windows.Forms.FlowLayoutPanel
    $row.Size          = New-Object System.Drawing.Size(880, 40)
    $row.Margin        = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
    $row.WrapContents  = $true
    $row.BackColor     = $Pal.Bg
    foreach ($it in $g.Items) {
        $b = New-FlatButton -Text $it.Name -Width 132 -Height 34
        $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 4)
        $target   = $it.Target
        $nm       = $it.Name
        $b.Add_Click({ Start-SystemTool -Target $target -Name $nm }.GetNewClosure())
        $row.Controls.Add($b)
        [void]$script:ToolButtons.Add([pscustomobject]@{ Button = $b; Target = $target; Name = $nm })
    }
    $pnlTools.Controls.Add($row)
    [void]$script:ToolRows.Add([pscustomobject]@{ Row = $row; Count = @($g.Items).Count })
}

$hintTool = New-HintBar -Text '提示：灰显＝本机没有。多数工具来自官方 FOD（可在«环境»页补全）；个别管理单元（服务、证书）Server Core 不提供，请用命令行替代。' -Kind Blue -Width 900
$hintTool.Dock = 'Bottom'
$hintTool.Height = 30
$pageTool.Controls.Add($hintTool)

# ============================ 更多页 ============================

$pageMore           = New-Object System.Windows.Forms.Panel
$pageMore.Dock      = 'Fill'
$pageMore.BackColor = $Pal.Bg
$script:Pages['more'] = $pageMore
$pnlContent.Controls.Add($pageMore)

$lblMoreHead          = New-Label -Text '更多功能' -Size 12 -Style Bold
$lblMoreHead.Location = New-Object System.Drawing.Point(2, 2)
$pageMore.Controls.Add($lblMoreHead)

$lblMoreDesc          = New-Label -Text '完整能力都在这里（探测/诊断/补给/会话/档案）。日常只用「环境」和「软件」两页就够。' -Size 9.5 -Color SubText
$lblMoreDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageMore.Controls.Add($lblMoreDesc)

$tree           = New-Object System.Windows.Forms.TreeView
$tree.Location  = New-Object System.Drawing.Point(0, 56)
$tree.Size      = New-Object System.Drawing.Size(268, 296)
$tree.Anchor    = 'Top,Left,Bottom'
$tree.BorderStyle = 'FixedSingle'
$tree.HideSelection = $false
$tree.ItemHeight = 24
$tree.ShowLines = $false
$tree.ShowRootLines = $false
$tree.FullRowSelect = $true
$tree.Font      = New-Font -Size 9.5
$pageMore.Controls.Add($tree)

$pnlMoreRight           = New-Object System.Windows.Forms.Panel
$pnlMoreRight.Location  = New-Object System.Drawing.Point(280, 56)
$pnlMoreRight.Size      = New-Object System.Drawing.Size(620, 296)
$pnlMoreRight.Anchor    = 'Top,Left,Right,Bottom'
$pnlMoreRight.BackColor = $Pal.Card
$pnlMoreRight.Padding   = New-Object System.Windows.Forms.Padding(14)
$pageMore.Controls.Add($pnlMoreRight)

$lblActTitle          = New-Label -Text '从左侧选一个功能' -Size 11 -Style Bold
$lblActTitle.Location = New-Object System.Drawing.Point(14, 12)
$pnlMoreRight.Controls.Add($lblActTitle)

$lblActDesc          = New-Label -Text '' -Size 9 -Color SubText -Width 570
$lblActDesc.Location = New-Object System.Drawing.Point(16, 38)
$lblActDesc.Height   = 44
$pnlMoreRight.Controls.Add($lblActDesc)

$pnlParams           = New-Object System.Windows.Forms.Panel
$pnlParams.Location  = New-Object System.Drawing.Point(14, 88)
$pnlParams.Size      = New-Object System.Drawing.Size(590, 118)
$pnlParams.Anchor    = 'Top,Left,Right'
$pnlParams.AutoScroll = $true
$pnlParams.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 253)
$pnlMoreRight.Controls.Add($pnlParams)

$btnRun = New-FlatButton -Text '运行' -Width 110 -Height 36 -Kind Primary
$btnRun.Location = New-Object System.Drawing.Point(14, 216)
$btnRun.Anchor   = 'Bottom,Left'
$pnlMoreRight.Controls.Add($btnRun)

$btnDry = New-FlatButton -Text '仅预览' -Width 100 -Height 36
$btnDry.Location = New-Object System.Drawing.Point(132, 216)
$btnDry.Anchor   = 'Bottom,Left'
$pnlMoreRight.Controls.Add($btnDry)

# ============================ 自适应布局 ============================
# 之前内容区写死 900 宽，而下面的日志面板是全宽，导致右边空出一大条、看着就是“错位”。
# 这里统一按父容器实际宽度重排；标题栏与导航的顺序也在下面纠正。

# 页面自身的尺寸也会变（Dock 排布在窗口显示后才定下来），必须跟着重算，
# 否则会出现“卡片按旧宽度排好、面板却已变宽/变窄”的不一致。
foreach ($k in $script:Pages.Keys) {
    try { $script:Pages[$k].Add_Resize({ Update-PageLayout }) } catch { }
}

function Update-PageLayout {
    try {
        # 隐藏的页面不会参与 Dock 排布，尺寸会停在创建时的旧值；
        # 这里强制把每个页面同步到内容区大小，否则切页时会用错误的宽度算布局。
        try {
            $cs = $pnlContent.ClientSize
            foreach ($k in $script:Pages.Keys) {
                $pg = $script:Pages[$k]
                if ($pg.Width -ne $cs.Width -or $pg.Height -ne $cs.Height) {
                    $pg.Size = New-Object System.Drawing.Size($cs.Width, $cs.Height)
                }
            }
        } catch { }

        # ---- 环境页 ----
        # 关键：每行几张要由“实际可用宽度”反算，不能写死。
        # 否则窗口一窄，卡片仍按旧宽度排，就会溢出（之前实测到过 215 宽卡片塞进 720 宽面板）。
        $w = [Math]::Max(360, $pageEnv.ClientSize.Width)
        $gap = 10
        $minCardW = 170
        if ($script:Cards.Count -gt 0) {
            $perRow = [Math]::Max(1, [Math]::Floor(($w + $gap) / ($minCardW + $gap)))
            $cardW  = [Math]::Floor(($w - ($perRow - 1) * $gap) / $perRow) - 6
            if ($cardW -lt $minCardW) { $cardW = $minCardW }
            # 卡片宽被抬高后，重新反算每行到底能放几张，并据此算高度
            $perRow = [Math]::Max(1, [Math]::Floor(($w + $gap) / ($cardW + $gap)))
            foreach ($cd in $script:Cards) {
                $cd.Panel.Width = $cardW
                $cd.Value.Width = $cardW - 42
                $cd.Sub.Width   = $cardW - 42
                Set-Rounded -Control $cd.Panel -Radius 10
            }
            $rows  = [Math]::Ceiling($script:Cards.Count / $perRow)
            $cardH = $script:Cards[0].Panel.Height + $gap
            $pnlCards.Width  = $w
            $pnlCards.Height = [int]($rows * $cardH) + 4
            $pnlEnvActions.Top = $pnlCards.Top + $pnlCards.Height + 8
        }

        # 按钮区高度也要按实际换行算（窄窗口下按钮会换行，写死高度会裁掉第二行）
        $pnlEnvActions.Width = $w
        $rowsBtn = 1
        $rowW = 0
        foreach ($b in $pnlEnvActions.Controls) {
            $need = $b.Width + $b.Margin.Left + $b.Margin.Right
            if ($rowW -gt 0 -and ($rowW + $need) -gt $w) { $rowsBtn++; $rowW = $need }
            else { $rowW += $need }
        }
        $pnlEnvActions.Height = [int]($rowsBtn * 50) + 6

        $hintEnv.Width = $w
        if ($hintEnv.Tag) { $hintEnv.Tag.Width = $w - 20 }
        $hintEnv.Top   = $pnlEnvActions.Top + $pnlEnvActions.Height + 4

        # ---- 软件页 ----
        $w2 = [Math]::Max(360, $pageApp.ClientSize.Width)
        $lstApps.Width       = $w2
        $pnlAppActions.Width = $w2
        # 按钮区高度按实际换行算，窄窗口下不会被裁
        $rowsAppBtn = 1
        $rowW2 = 0
        foreach ($b in $pnlAppActions.Controls) {
            $need = $b.Width + $b.Margin.Left + $b.Margin.Right
            if ($rowW2 -gt 0 -and ($rowW2 + $need) -gt $w2) { $rowsAppBtn++; $rowW2 = $need }
            else { $rowW2 += $need }
        }
        $pnlAppActions.Height = [int]($rowsAppBtn * 46) + 8
        $lstApps.Height      = [Math]::Max(120, ($pnlAppActions.Top - $lstApps.Top) - 12)
        $hintApp.Width = $w2
        if ($hintApp.Tag) { $hintApp.Tag.Width = $w2 - 20 }
        $hintApp.Top   = $pnlAppActions.Top + $pnlAppActions.Height + 4
        if ($lstApps.Columns.Count -ge 4 -and $w2 -gt 620) {
            $lstApps.Columns[0].Width = 170
            $lstApps.Columns[2].Width = 200
            $lstApps.Columns[3].Width = 110
            $lstApps.Columns[1].Width = [Math]::Max(220, ($w2 - 170 - 200 - 110 - 24))
        }

        # ---- 更多页 ----
        $w3 = [Math]::Max(600, $pageMore.ClientSize.Width)
        $h3 = [Math]::Max(240, $pageMore.ClientSize.Height)
        $tree.Height         = [Math]::Max(140, ($h3 - $tree.Top) - 4)
        $pnlMoreRight.Left   = $tree.Width + 12
        $pnlMoreRight.Width  = [Math]::Max(360, $w3 - $pnlMoreRight.Left)
        $pnlMoreRight.Height = [Math]::Max(200, ($h3 - $pnlMoreRight.Top) - 4)
        $innerW = $pnlMoreRight.ClientSize.Width
        $innerH = $pnlMoreRight.ClientSize.Height
        $lblActDesc.Width  = [Math]::Max(200, $innerW - 32)
        $pnlParams.Width   = [Math]::Max(200, $innerW - 28)
        $pnlParams.Height  = [Math]::Max(48, $innerH - 88 - 52)
        $btnRun.Top        = $innerH - 46
        $btnDry.Top        = $btnRun.Top
        # 参数控件右对齐到新的宽度
        foreach ($k in $script:ParamControls.Keys) {
            $ctl = $script:ParamControls[$k]
            if ($null -eq $ctl) { continue }
            $pw = 320
            if ($ctl.Tag -ne $null) { $pw = [int]$ctl.Tag }
            $nx = [Math]::Max(230, ($pnlParams.Width - $pw - 50))
            $ctl.Left = $nx
            foreach ($sib in $pnlParams.Controls) {
                if ($sib -is [System.Windows.Forms.Button] -and $sib.Tag -eq $ctl) { $sib.Left = $nx + $pw + 6 }
            }
        }

        # ---- 工具页 ----
        $w4 = [Math]::Max(600, $pageTool.ClientSize.Width)
        $hintTool.Width = $w4
        if ($hintTool.Tag) { $hintTool.Tag.Width = $w4 - 20 }
        $perRowTool = [Math]::Max(1, [Math]::Floor(($w4 - 12) / 140))
        foreach ($tr in $script:ToolRows) {
            $tr.Row.Width  = [Math]::Max(200, $w4 - 16)
            $rowsNeeded    = [Math]::Ceiling($tr.Count / $perRowTool)
            $tr.Row.Height = [int]($rowsNeeded * 40) + 2
        }
    } catch { }
}

# ============================ 通用逻辑 ============================

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 400

function Append-GuiLog {
    param([string]$Line)
    $color = $Pal.LogText
    if     ($Line -match '\[OK\]')    { $color = [System.Drawing.Color]::FromArgb(134, 239, 172) }
    elseif ($Line -match '\[WARN\]')  { $color = [System.Drawing.Color]::FromArgb(253, 224, 71) }
    elseif ($Line -match '\[ERROR\]') { $color = [System.Drawing.Color]::FromArgb(252, 165, 165) }
    elseif ($Line -match '\[STEP\]')  { $color = [System.Drawing.Color]::FromArgb(147, 197, 253) }
    elseif ($Line -match '\[DRY\]')   { $color = [System.Drawing.Color]::FromArgb(216, 180, 254) }
    elseif ($Line -match '\[HEAD\]')  { $color = [System.Drawing.Color]::White }
    try {
        $txtLog.SelectionStart  = $txtLog.TextLength
        $txtLog.SelectionLength = 0
        $txtLog.SelectionColor  = $color
        $txtLog.AppendText($Line + "`r`n")
        $txtLog.SelectionColor  = $txtLog.ForeColor
        $txtLog.ScrollToCaret()
    } catch { }
}

function Show-GuiPage {
    param([string]$Key)
    if (-not $script:Pages.ContainsKey($Key)) { return }
    $script:CurrentPage = $Key
    foreach ($k in $script:Pages.Keys) { $script:Pages[$k].Visible = ($k -eq $Key) }
    foreach ($b in $script:NavButtons) {
        $info = $b.Tag
        if ($info.Page -eq $Key) {
            $b.BackColor = $Pal.Accent4
            $b.ForeColor = $Pal.Accent2
            $b.Font = New-Font -Size 11 -Style Bold
        } else {
            $b.BackColor = $Pal.NavBg
            $b.ForeColor = $Pal.SubText
            $b.Font = New-Font -Size 11
        }
    }
    if ($Key -eq 'env') { Update-EnvCards }
    if ($Key -eq 'tool') { Update-ToolButtons }
    Update-PageLayout
}

function New-StatusCard {
    param([string]$Title, [int]$Width = 208)
    $card = New-Object System.Windows.Forms.Panel
    $card.Size      = New-Object System.Drawing.Size($Width, 68)
    $card.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 10, 10)
    $card.BackColor = $Pal.Card
    $card.BorderStyle = 'FixedSingle'

    $dot = New-Label -Text '●' -Size 11 -Color Hint
    $dot.Location = New-Object System.Drawing.Point(10, 8)
    $card.Controls.Add($dot)

    $lt = New-Label -Text $Title -Size 8.5 -Color Hint
    $lt.Location = New-Object System.Drawing.Point(30, 10)
    $card.Controls.Add($lt)

    $lv = New-Label -Text '—' -Size 10 -Style Bold -Color Text -Width ($Width - 42)
    $lv.Location = New-Object System.Drawing.Point(30, 28)
    $lv.Height   = 22
    $card.Controls.Add($lv)

    $ls = New-Label -Text '' -Size 8.5 -Color SubText -Width ($Width - 42)
    $ls.Location = New-Object System.Drawing.Point(30, 48)
    $ls.Height   = 16
    $card.Controls.Add($ls)

    Set-Rounded -Control $card -Radius 10
    $pnlCards.Controls.Add($card)
    return [pscustomobject]@{ Panel = $card; Title = $lt; Value = $lv; Sub = $ls; Dot = $dot }
}

function Update-EnvCards {
    if ($script:Cards.Count -eq 0) {
        $script:Cards = @(
            (New-StatusCard -Title '系统'),
            (New-StatusCard -Title '图形组件'),
            (New-StatusCard -Title '渲染管线'),
            (New-StatusCard -Title 'NET 运行时'),
            (New-StatusCard -Title '登录会话'),
            (New-StatusCard -Title '提权 UAC'),
            (New-StatusCard -Title 'Web 管理 (WAC)')
        )
    }
    try {
        $s = Get-GuiReadyStatic
        $prof = Get-GuiReadyOsProfile -Static $s
        $card = $script:Cards[0]
        $card.Dot.ForeColor = $Pal.Ok
        $card.Value.Text = ('{0} Build {1}' -f $prof.Short, $prof.Build)
        $card.Sub.Text   = [string]$prof.InstallationType
    } catch { }

    try {
        $fod = 'Unknown'
        $cap = Get-GuiReadyCapability
        foreach ($i in $cap.Items) { if ($i.Name -like 'ServerCore.AppCompatibility*') { $fod = $i.State } }
        $miss = 0; $total = 0
        $dlls = Get-GuiReadyDllScan
        $grp = @($dlls | Where-Object { $_.Group -eq '桌面体验专属' })
        $total = $grp.Count
        $miss = @($grp | Where-Object { -not $_.Exists }).Count
        $card = $script:Cards[1]
        if ($fod -eq 'Installed') {
            $card.Dot.ForeColor = $(if ($miss -le 4) { $Pal.Ok } else { $Pal.Warn })
            $card.Value.Text = 'FOD 已安装'
            $card.Sub.Text   = ('还缺 {0}/{1} 个桌面组件' -f $miss, $total)
        } else {
            $card.Dot.ForeColor = $Pal.Err
            $card.Value.Text = ('FOD: ' + $fod)
            $card.Sub.Text   = '需要补全环境'
        }
    } catch {
        $card = $script:Cards[1]; $card.Dot.ForeColor = $Pal.Hint; $card.Value.Text = '需管理员'; $card.Sub.Text = ''
    }

    try {
        $dlls = Get-GuiReadyDllScan
        $has = @{}
        foreach ($d in $dlls) { $has[$d.Name] = [bool]$d.Exists }
        $ok = ($has['dwm.exe'] -and $has['dcomp.dll'] -and $has['dwrite.dll'])
        $card = $script:Cards[2]
        $card.Dot.ForeColor = $(if ($ok) { $Pal.Ok } else { $Pal.Err })
        $card.Value.Text = $(if ($ok) { '已就绪' } else { '未就绪' })
        $card.Sub.Text   = ('dwm={0} dcomp={1} dwrite={2}' -f (Format-Bool $has['dwm.exe']), (Format-Bool $has['dcomp.dll']), (Format-Bool $has['dwrite.dll']))
    } catch { }

    try {
        $dn = Get-GuiReadyDotNetStatus
        $card = $script:Cards[3]
        $card.Dot.ForeColor = $(if ($dn.Frameworks.Count -gt 0) { $Pal.Ok } else { $Pal.Warn })
        $card.Value.Text = ('{0} 个框架' -f $dn.Frameworks.Count)
        $top = @($dn.Frameworks | Where-Object { $_.Name -eq 'Microsoft.NETCore.App' } | Sort-Object Version -Descending | Select-Object -First 1)
        $card.Sub.Text = $(if ($top.Count -gt 0) { 'NETCore.App ' + $top[0].Version } else { '.NET 程序会报缺运行时' })
    } catch { }

    try {
        $s2 = Get-GuiReadySessionInfo
        $card = $script:Cards[4]
        $card.Dot.ForeColor = $(if ($s2.LoggedOnCount -gt 0) { $Pal.Ok } else { $Pal.Err })
        $card.Value.Text = ('已登录 {0} 个' -f $s2.LoggedOnCount)
        try {
            $a = Get-GuiReadyAutoLogon
            $card.Sub.Text = $(if ($a.Enabled) { '自动登录: 已启用' } else { '自动登录: 未启用' })
        } catch { $card.Sub.Text = '' }
    } catch { }

    try {
        $u = Get-GuiReadyUac
        $card = $script:Cards[5]
        $card.Dot.ForeColor = $(if ($u.PromptsWillBlock) { $Pal.Warn } else { $Pal.Ok })
        $card.Value.Text = $(if ($u.PromptsWillBlock) { '会弹确认窗' } else { '不会拦截' })
        $card.Sub.Text   = $(if ($u.PromptsWillBlock) { '无人值守时装软件可能失败' } else { '' })
    } catch { }

    try {
        # 用 -SkipProbe：卡片刷新很频繁，不要每次都等 HTTP 探测
        $wac = Get-GuiReadyWacStatus -SkipProbe
        $card = $script:Cards[6]
        if ($wac.Installed) {
            $running = ($wac.ServiceState -eq 'Running')
            $card.Dot.ForeColor = $(if ($running) { $Pal.Ok } else { $Pal.Warn })
            $card.Value.Text = ('已装 v' + $wac.Version)
            $card.Sub.Text   = $(if ($running) { ('运行中 · 端口 ' + $wac.Port) } else { '服务未运行' })
        } else {
            $card.Dot.ForeColor = $Pal.Hint
            $card.Value.Text = '未安装'
            $card.Sub.Text   = '可一键安装并配置'
        }
    } catch {
        $card = $script:Cards[6]
        $card.Dot.ForeColor = $Pal.Hint
        $card.Value.Text = '未知'
        $card.Sub.Text = ''
    }
}

function Clear-ParamControls {
    foreach ($ctl in @($pnlParams.Controls)) { $ctl.Dispose() }
    $pnlParams.Controls.Clear()
    $script:ParamControls = @{}
}

function Select-GuiAction {
    param($Action)
    $script:CurrentAction = $Action
    $lblActTitle.Text = $Action.Name
    $lblActDesc.Text  = $Action.Desc
    Clear-ParamControls

    $y = 6
    foreach ($pd in @($Action.Params)) {
        $lb = New-Label -Text $pd.Label -Size 9 -Color SubText
        $lb.Location = New-Object System.Drawing.Point(8, ($y + 4))
        $pnlParams.Controls.Add($lb)

        $w = 320
        if ($pd.ContainsKey('Width')) { $w = [int]$pd.Width }
        $x = [Math]::Max(230, ($pnlParams.Width - $w - 60))
        $ctl = $null
        switch ([string]$pd.Type) {
            'Check' {
                $ctl = New-Object System.Windows.Forms.CheckBox
                $ctl.Size = New-Object System.Drawing.Size(($w + 40), 24)
                if ($pd.ContainsKey('Default')) { $ctl.Checked = [bool]$pd.Default }
            }
            'Combo' {
                $ctl = New-Object System.Windows.Forms.ComboBox
                $ctl.DropDownStyle = 'DropDownList'
                $ctl.Size = New-Object System.Drawing.Size($w, 24)
                foreach ($o in @($pd.Options)) { [void]$ctl.Items.Add([string]$o) }
                $idx = 0
                if ($pd.ContainsKey('Default')) { $idx = [int]$pd.Default - 1 }
                if ($idx -ge 0 -and $idx -lt $ctl.Items.Count) { $ctl.SelectedIndex = $idx }
            }
            'Password' {
                $ctl = New-Object System.Windows.Forms.TextBox
                $ctl.UseSystemPasswordChar = $true
                $ctl.Size = New-Object System.Drawing.Size($w, 24)
                if ($pd.ContainsKey('Default')) { $ctl.Text = [string]$pd.Default }
            }
            default {
                $ctl = New-Object System.Windows.Forms.TextBox
                $ctl.Size = New-Object System.Drawing.Size($w, 24)
                if ($pd.ContainsKey('Default')) { $ctl.Text = [string]$pd.Default }
            }
        }
        $ctl.Location = New-Object System.Drawing.Point($x, $y)
        $ctl.Tag      = $w      # 记住期望宽度，自适应布局时用它右对齐
        $pnlParams.Controls.Add($ctl)
        $script:ParamControls[[string]$pd.Name] = $ctl

        if ($pd.ContainsKey('Browse')) {
            $kind = [string]$pd.Browse
            $bb = New-FlatButton -Text '…' -Width 32 -Height 24
            $bb.Location = New-Object System.Drawing.Point(($x + $w + 6), $y)
            $bb.Tag      = $ctl      # 跟随该输入框移动
            $target = $ctl
            $bb.Add_Click({
                if ($kind -eq 'Folder') {
                    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                    if ($dlg.ShowDialog() -eq 'OK') { $target.Text = $dlg.SelectedPath }
                } else {
                    $dlg = New-Object System.Windows.Forms.OpenFileDialog
                    if ($kind -eq 'File') { $dlg.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*' }
                    else { $dlg.Filter = '所有文件 (*.*)|*.*' }
                    if ($dlg.ShowDialog() -eq 'OK') { $target.Text = $dlg.FileName }
                }
            })
            $pnlParams.Controls.Add($bb)
        }
        $y += 30
    }
    $btnDry.Enabled = [bool]$Action.DryRun
}

function Get-ParamValues {
    $P = @{}
    if (-not $script:CurrentAction) { return $P }
    foreach ($pd in @($script:CurrentAction.Params)) {
        $n = [string]$pd.Name
        $ctl = $script:ParamControls[$n]
        if (-not $ctl) { continue }
        switch ([string]$pd.Type) {
            'Check' { $P[$n] = [bool]$ctl.Checked }
            'Combo' { $P[$n] = [int]$ctl.SelectedIndex + 1 }
            default { $P[$n] = [string]$ctl.Text }
        }
    }
    return $P
}

function Read-GuiNewOutput {
    if (-not $script:OutFile) { return }
    if (-not (Test-Path -LiteralPath $script:OutFile)) { return }
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $script:OutFile -Encoding UTF8 -ErrorAction Stop) } catch { return }
    while ($script:ReadLines -lt $lines.Count) {
        Append-GuiLog -Line ([string]$lines[$script:ReadLines])
        $script:ReadLines++
    }
}

function Finish-GuiAction {
    param([int]$ExitCode = -999)
    $script:Timer.Stop()
    Read-GuiNewOutput
    $elapsed = 0
    if ($script:RunStart) { $elapsed = [math]::Round(((Get-Date) - $script:RunStart).TotalSeconds, 1) }
    if ($ExitCode -eq -999) {
        if ($script:Proc) { try { $ExitCode = $script:Proc.ExitCode } catch { $ExitCode = -1 } } else { $ExitCode = -1 }
    }
    if ($script:ErrFile -and (Test-Path -LiteralPath $script:ErrFile)) {
        try {
            $errTxt = (Get-Content -LiteralPath $script:ErrFile -Raw -Encoding UTF8)
            if ($errTxt -and $errTxt.Trim()) { foreach ($l in ($errTxt -split "`r?`n")) { if ($l.Trim()) { Append-GuiLog -Line ('[stderr] ' + $l) } } }
        } catch { }
    }
    if ($ExitCode -eq 0) { Append-GuiLog -Line ('[OK] 完成，用时 {0} 秒' -f $elapsed) }
    else { Append-GuiLog -Line ('[ERROR] 结束，退出码 {0}，用时 {1} 秒' -f $ExitCode, $elapsed) }
    $btnFill.Enabled = $true
    $btnRun.Enabled = $true
    $script:Proc = $null
    Update-EnvCards
    Refresh-ProgramList
}

$script:Timer.Add_Tick({
    if (-not $script:Proc) { return }
    Read-GuiNewOutput
    $script:Proc.Refresh()
    if ($script:Proc.HasExited) { Finish-GuiAction -ExitCode $script:Proc.ExitCode }
})

function Start-GuiActionById {
    param([string]$Id, [bool]$DryRun = $false)
    $a = @($script:Actions | Where-Object { $_.Id -eq $Id })
    if ($a.Count -eq 0) { Append-GuiLog -Line ('[ERROR] 未找到功能: ' + $Id); return }
    Select-GuiAction -Action $a[0]
    Start-GuiAction -DryRun $DryRun
}

function Start-GuiAction {
    param([bool]$DryRun = $false)

    if (-not $script:CurrentAction) { return }
    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请先等它结束或点“停止当前动作”。', '提示', 'OK', 'Information') | Out-Null
        return
    }

    $P = Get-ParamValues
    $P['DryRun'] = [bool]$DryRun

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tmpDir = Join-Path $env:TEMP ('gui-ready-' + $stamp)
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $argsFile = Join-Path $tmpDir 'args.json'
    $script:OutFile    = Join-Path $tmpDir 'stdout.txt'
    $script:ErrFile    = Join-Path $tmpDir 'stderr.txt'
    $script:RunLogFile = Join-Path (Join-Path $toolRoot 'logs') ('gui-{0}-{1}.log' -f $script:CurrentAction.Id, $stamp)
    try {
        [System.IO.File]::WriteAllText($argsFile, ($P | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding -ArgumentList $true))
    } catch {
        Append-GuiLog -Line ('[ERROR] 参数序列化失败: ' + $_.Exception.Message); return
    }

    $script:ReadLines = 0
    Append-GuiLog -Line ''
    Append-GuiLog -Line ('[STEP] ==== {0} {1} ====' -f $script:CurrentAction.Name, $(if ($DryRun) { '（仅预览）' } else { '' }))
    $btnFill.Enabled = $false
    $btnRun.Enabled  = $false
    $script:RunStart = Get-Date

    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:RunnerPath + '"'),
                     '-Action', $script:CurrentAction.Id,
                     '-ArgsFile', ('"' + $argsFile + '"'),
                     '-LogFile', ('"' + $script:RunLogFile + '"'))
        $script:Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden `
                        -RedirectStandardOutput $script:OutFile -RedirectStandardError $script:ErrFile
        $script:Timer.Start()
    } catch {
        Append-GuiLog -Line ('[ERROR] 无法启动动作进程: ' + $_.Exception.Message)
        $btnFill.Enabled = $true; $btnRun.Enabled = $true
        $script:Proc = $null
    }
}

$btnRun.Add_Click({ Start-GuiAction -DryRun $false })
$btnDry.Add_Click({ Start-GuiAction -DryRun $true })

$tree.Add_AfterSelect({
    $n = $tree.SelectedNode
    if ($n -and $n.Tag) { Select-GuiAction -Action $n.Tag }
})

$groups = @($script:Actions | Group-Object Group)
foreach ($g in $groups) {
    $node = New-Object System.Windows.Forms.TreeNode($g.Name)
    $node.NodeFont = New-Font -Size 9.5 -Style Bold
    foreach ($a in $g.Group) {
        $child = New-Object System.Windows.Forms.TreeNode($a.Name)
        $child.Tag = $a
        [void]$node.Nodes.Add($child)
    }
    [void]$tree.Nodes.Add($node)
    $node.Expand()
}

# ============================ 软件管理逻辑 ============================

function Load-Programs {
    $script:Programs = @()
    if (-not (Test-Path -LiteralPath $script:ProgramStore)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:ProgramStore -Raw -Encoding UTF8
        if ($raw -and $raw.Trim()) { $script:Programs = @($raw | ConvertFrom-Json) }
    } catch { }
}

function Save-Programs {
    try {
        $dir = Split-Path -Parent $script:ProgramStore
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($script:ProgramStore, ([string](ConvertTo-Json -InputObject @($script:Programs) -Depth 5)), (New-Object System.Text.UTF8Encoding -ArgumentList $true))
    } catch { }
}

function Get-ProgramArg {
    param($Item)
    if ($Item -and $Item.PSObject.Properties['Args'] -and $Item.Args) { return [string]$Item.Args }
    return ''
}

function Refresh-ProgramList {
    $lstApps.BeginUpdate()
    $lstApps.Items.Clear()
    foreach ($p in $script:Programs) {
        $verdict = ''
        $exists = Test-Path -LiteralPath ([string]$p.Path)
        if (-not $exists) {
            $verdict = '文件不存在'
        } else {
            try {
                $ce = Show-GuiReadyCatalogEntry -ExePath ([string]$p.Path) -Quiet
                if ($ce -and $ce.Entry) { $verdict = [string]$ce.Entry.Verdict }
            } catch { }
        }
        $it = New-Object System.Windows.Forms.ListViewItem([string]$p.Name)
        [void]$it.SubItems.Add([string]$p.Path)
        [void]$it.SubItems.Add((Get-ProgramArg -Item $p))
        [void]$it.SubItems.Add($verdict)
        if ($verdict -match '不支持') { $it.ForeColor = $Pal.Err }
        elseif ($verdict -match '建议参数' -or $verdict -match '不存在') { $it.ForeColor = $Pal.Warn }
        $it.Tag = $p
        [void]$lstApps.Items.Add($it)
    }
    $lstApps.EndUpdate()
}

function Get-SelectedProgram {
    if ($lstApps.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先在列表里选中一个程序。', '提示', 'OK', 'Information') | Out-Null
        return $null
    }
    return $lstApps.SelectedItems[0].Tag
}

function Start-ProgramItem {
    param($Item, [string]$ArgsOverride = $null)
    $exe = [string]$Item.Path
    if (-not (Test-Path -LiteralPath $exe)) {
        [System.Windows.Forms.MessageBox]::Show(('文件不存在: ' + $exe), '无法启动', 'OK', 'Warning') | Out-Null
        return
    }
    $args = $(if ($null -ne $ArgsOverride) { $ArgsOverride } else { Get-ProgramArg -Item $Item })

    # 启动前做一次静态预检：缺桌面专属组件就提醒
    try {
        $pe = Get-PeImageInfo -Path $exe
        if ($pe.IsPe) {
            $dir = Split-Path -Parent $exe
            $miss = @()
            foreach ($m in @($pe.Imports + $pe.DelayImports | Sort-Object -Unique)) {
                if ($m -match '^(api-ms-win-|ext-ms-win-)') { continue }
                if (-not (Test-ModuleResolvable -Name $m -AppDir $dir)) { $miss += $m }
            }
            $desk = @($miss | Where-Object { $Global:GuiReadyDesktopOnlyModules -contains $_.ToLower() })
            if ($desk.Count -gt 0) {
                $msg = '这个程序依赖桌面体验专属组件，可能启动失败：' + [Environment]::NewLine + [Environment]::NewLine +
                       (($desk | Select-Object -First 6) -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine +
                       '仍然要继续吗？'
                if ([System.Windows.Forms.MessageBox]::Show($msg, '兼容性预检', 'YesNo', 'Warning') -ne 'Yes') { return }
            }
        }
    } catch { }

    try {
        $wd = Split-Path -Parent $exe
        if ($args) { Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $wd | Out-Null }
        else { Start-Process -FilePath $exe -WorkingDirectory $wd | Out-Null }
        Append-GuiLog -Line ('[OK] 已启动: {0} {1}' -f $exe, $args)
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
        Append-GuiLog -Line ('[ERROR] 启动失败: ' + $_.Exception.Message)
    }
}

$lstApps.Add_DoubleClick({ $it = Get-SelectedProgram; if ($it) { Start-ProgramItem -Item $it } })

$btnAppAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
    $dlg.Title  = '选择要加入的程序'
    if ($dlg.ShowDialog() -ne 'OK') { return }

    $rec = ''
    $verdict = ''
    try {
        $ce = Show-GuiReadyCatalogEntry -ExePath $dlg.FileName -Quiet
        if ($ce -and $ce.Entry) { $verdict = [string]$ce.Entry.Verdict; $rec = [string]$ce.Entry.LaunchArgs }
    } catch { }

    $script:Programs += [pscustomobject]@{
        Name = [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
        Path = $dlg.FileName
        Args = $rec
    }
    Save-Programs
    Refresh-ProgramList

    if ($verdict) {
        $m = ('已加入：{0}' -f [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)) + [Environment]::NewLine + ('兼容结论：{0}' -f $verdict)
        if ($rec) { $m += [Environment]::NewLine + [Environment]::NewLine + '已自动带入实测推荐参数：' + [Environment]::NewLine + $rec }
        [System.Windows.Forms.MessageBox]::Show($m, '添加完成', 'OK', 'Information') | Out-Null
    }
    Append-GuiLog -Line ('[OK] 已加入程序: {0}   推荐参数: {1}' -f $dlg.FileName, $(if ($rec) { $rec } else { '(无)' }))
})

$btnAppRun.Add_Click({
    $it = Get-SelectedProgram
    if ($it) { Start-ProgramItem -Item $it }
})

$btnAppArgs.Add_Click({
    $it = Get-SelectedProgram
    if (-not $it) { return }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { }
    $cur = Get-ProgramArg -Item $it
    try {
        $new = [Microsoft.VisualBasic.Interaction]::InputBox('启动参数（留空表示不带参数）：', ('启动参数 - ' + $it.Name), $cur)
    } catch {
        [System.Windows.Forms.MessageBox]::Show('无法弹出输入框。', '提示', 'OK', 'Warning') | Out-Null
        return
    }
    $it.Args = [string]$new
    Save-Programs
    Refresh-ProgramList
    Append-GuiLog -Line ('[OK] 已保存启动参数: {0} -> "{1}"' -f $it.Name, $it.Args)
})

$btnAppPersist.Add_Click({
    $it = Get-SelectedProgram
    if (-not $it) { return }
    if (-not (Get-Command Start-GuiReadyPersistentProcess -ErrorAction SilentlyContinue)) { return }
    $a = Get-ProgramArg -Item $it
    $m = '将用 SYSTEM 计划任务启动它，这样进程不会随远程会话断开被杀掉。' + [Environment]::NewLine + [Environment]::NewLine +
         ('程序：{0}' -f $it.Path) + [Environment]::NewLine + ('参数：{0}' -f $(if ($a) { $a } else { '(无)' }))
    if ([System.Windows.Forms.MessageBox]::Show($m, '设为后台常驻', 'YesNo', 'Question') -ne 'Yes') { return }
    $ok = Start-GuiReadyPersistentProcess -Name ('App-' + $it.Name) -ExePath $it.Path -Arguments $a
    if ($ok) { Append-GuiLog -Line ('[OK] 已注册并启动计划任务: App-' + $it.Name) }
})

$btnAppDiag.Add_Click({
    $it = Get-SelectedProgram
    if (-not $it) { return }
    Start-GuiActionById -Id 'diag' -DryRun $false
    $card = $script:ParamControls['Path']
    if ($card) { $card.Text = [string]$it.Path }
    Append-GuiLog -Line '[INFO] 已把该程序填入「更多 → 启动并诊断」的参数，切到「更多」页点运行即可。'
})

$btnAppCatalog.Add_Click({
    $it = Get-SelectedProgram
    if (-not $it) { return }
    try {
        $ce = Show-GuiReadyCatalogEntry -ExePath ([string]$it.Path) -Quiet
        if ($ce -and $ce.Entry) {
            $e = $ce.Entry
            $m = ('条目：{0}' -f $e.Name) + [Environment]::NewLine + ('类型：{0}' -f $e.Type) + [Environment]::NewLine +
                 ('结论：{0}' -f $e.Verdict) + [Environment]::NewLine
            if ($e.LaunchArgs) { $m += ('推荐参数：{0}' -f $e.LaunchArgs) + [Environment]::NewLine }
            if ($e.VerifiedOn) { $m += ('实测 build：{0}' -f $e.VerifiedOn) + [Environment]::NewLine }
            $m += [Environment]::NewLine + $e.Notes
            [System.Windows.Forms.MessageBox]::Show($m, '程序兼容档案', 'OK', 'Information') | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show('档案里没有这个程序。可以在「更多 → 程序档案」里添加你自己的结论。', '无档案', 'OK', 'Information') | Out-Null
        }
    } catch { }
})

$btnAppDel.Add_Click({
    $it = Get-SelectedProgram
    if (-not $it) { return }
    $rest = @($script:Programs | Where-Object { $_.Path -ne $it.Path })
    $script:Programs = $rest
    Save-Programs
    Refresh-ProgramList
    Append-GuiLog -Line ('[OK] 已移除: ' + $it.Name)
})

# ============================ 退出（返回命令行） ============================

function Exit-ToCommandLine {
    if ($script:Proc) {
        try { Stop-Process -Id $script:Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    try { $script:Timer.Stop(); $script:Timer.Dispose() } catch { }
    try {
        # 返回命令行：在工具目录新开一个命令行窗口
        Start-Process -FilePath 'cmd.exe' -WorkingDirectory $toolRoot | Out-Null
    } catch { }
    $form.Close()
}

$btnExitBack.Add_Click({ Exit-ToCommandLine })
$form.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Exit-ToCommandLine }
})

# ============================ 启动 ============================

function Update-Chrome {
    # 头部横贯全宽：WinForms 里“最后加入的边栏控件”排布最优先。
    # 实测顺序 Fill→Left→Top 才能得到 头部全宽 + 导航在其下方；当前是 Top→Left→Fill，
    # 所以把 Fill 提到最前、把 Top 放到最后，等价于那个顺序。
    try { $pnlRight.BringToFront(); $pnlHead.SendToBack() } catch { }
    try { $btnExitBack.Location = New-Object System.Drawing.Point(($pnlHead.ClientSize.Width - 190), 18) } catch { }
    Set-Rounded -Control $pnlLog -Radius 8
    Update-PageLayout
}

$form.Add_Shown({
    Update-Chrome
    $first = $StartPage
    if (-not $script:Pages.ContainsKey($first)) { $first = 'env' }
    Show-GuiPage -Key $first
    Update-ToolButtons
    Load-Programs
    Refresh-ProgramList
    Append-GuiLog -Line ('Server Core GUI 就绪工具已启动  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Append-GuiLog -Line ('工具目录: ' + $toolRoot)
    Append-GuiLog -Line '左侧「环境」用于补全；「软件」管理你要跑的程序；「工具」打开系统自带图形工具；完整能力在「更多」。'
})

$form.Add_Resize({ Update-Chrome })

if ($LayoutDump) {
    # 布局体检：把控件树的真实坐标打出来，并标出越界/可疑的控件，用来定位“UI 错位”
    $rep = New-Object System.Collections.ArrayList
    function Dump-Tree {
        param($Parent, [int]$Depth = 0)
        foreach ($ctl in $Parent.Controls) {
            $pad  = ('  ' * $Depth)
            $txt  = [string]$ctl.Text
            if ($txt.Length -gt 16) { $txt = $txt.Substring(0, 16) + '…' }
            $txt  = $txt -replace "`r?`n", ' '
            [void]$rep.Add(('{0}{1,-12} {2,-18} dock={3,-9} anchor={4,-20} ({5,4},{6,4}) {7,4}x{8,-4} vis={9} "{10}"' -f `
                $pad, $ctl.GetType().Name, '', [string]$ctl.Dock, [string]$ctl.Anchor, `
                $ctl.Left, $ctl.Top, $ctl.Width, $ctl.Height, $ctl.Visible, $txt))
            if ($ctl.Parent) {
                $pc = $ctl.Parent.ClientSize
                if ($ctl.Right -gt $pc.Width -or $ctl.Bottom -gt $pc.Height -or $ctl.Left -lt 0 -or $ctl.Top -lt 0) {
                    $scrolls = $false
                    try { $scrolls = [bool]$ctl.Parent.AutoScroll } catch { }
                    if ($scrolls -and $ctl.Left -ge 0 -and $ctl.Top -ge 0) {
                        # 可滚动容器里的纵向超出是设计允许的（会出滚动条），不算错位
                    } else {
                        [void]$rep.Add(('{0}   !! 越界: 控件 {1}x{2} @({3},{4}) 超出父客户区 {5}x{6}' -f $pad, $ctl.Width, $ctl.Height, $ctl.Left, $ctl.Top, $pc.Width, $pc.Height))
                    }
                }
            }
            if ($ctl.HasChildren) { Dump-Tree -Parent $ctl -Depth ($Depth + 1) }
        }
    }
    try {
        $form.CreateControl()
        Show-GuiPage -Key 'env'
        Update-EnvCards
        Update-Chrome
        $form.PerformLayout()
        Dump-Tree -Parent $form

        # 逐页检查：切到每一页，把该页的错误量出来
        foreach ($k in @('env', 'app', 'tool', 'more')) {
            Show-GuiPage -Key $k
            $form.PerformLayout()
            $pg = $script:Pages[$k]
            $need = 0
            foreach ($c in $pg.Controls) { if ($c.Visible) { $need = [Math]::Max($need, $c.Bottom) } }
            [void]$rep.Add(('页 {0}: 客户区 {1}x{2}   内容最低到 y={3}   {4}' -f $k, $pg.ClientSize.Width, $pg.ClientSize.Height, $need,
                $(if ($need -gt $pg.ClientSize.Height) { '!! 内容超出，会被裁掉' } else { 'OK' })))
        }

        # 系统工具可用性一览（Server Core 上这些依赖 FOD）
        Update-ToolButtons
        $avail = @($script:ToolButtons | Where-Object { $_.Button.Enabled })
        [void]$rep.Add(('系统工具: 共 {0} 个，当前可用 {1} 个，缺失 {2} 个' -f $script:ToolButtons.Count, $avail.Count, ($script:ToolButtons.Count - $avail.Count)))
        foreach ($tb in $script:ToolButtons) {
            if (-not $tb.Button.Enabled) { [void]$rep.Add(('    缺失: {0}  ({1})' -f $tb.Name, $tb.Target)) }
        }
        $needH = 0
        foreach ($c in $pnlTools.Controls) { $needH += ($c.Height + $c.Margin.Top + $c.Margin.Bottom) }
        [void]$rep.Add(('工具页内容高 {0}  可视高 {1}  {2}' -f $needH, $pnlTools.ClientSize.Height,
            $(if ($needH -gt $pnlTools.ClientSize.Height) { '会出滚动条' } else { '一屏放得下' })))

        $cards = $script:Cards
        if ($cards.Count -gt 0) {
            $cardH = $cards[0].Panel.Height + $cards[0].Panel.Margin.Bottom
            $perRow = [Math]::Floor(($pnlCards.ClientSize.Width + 10) / ($cards[0].Panel.Width + 10))
            $rows = [Math]::Ceiling($cards.Count / [Math]::Max(1, $perRow))
            [void]$rep.Add(('状态卡片: {0} 张  每行 {1} 张  共 {2} 行  每行高 {3}  需要 {4}  面板高 {5}  {6}' -f `
                $cards.Count, $perRow, $rows, $cardH, ($rows * $cardH), $pnlCards.Height, `
                $(if (($rows * $cardH) -gt $pnlCards.Height) { '!! 高度不够会裁掉' } else { 'OK' })))
        }
        $rep | ForEach-Object { Write-Host $_ }
        $form.Dispose()
    } catch {
        Write-Host ('LAYOUTDUMP FAIL: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
    }
    return
}

if ($SelfTest) {
    try {
        $form.CreateControl()
        $form.PerformLayout()
        Show-GuiPage -Key 'env'
        Update-EnvCards
        $nodeCount = 0
        foreach ($g in $tree.Nodes) { $nodeCount += $g.Nodes.Count }
        $cardCount = $script:Cards.Count
        $envVals = @($script:Cards | ForEach-Object { $_.Value.Text })
        Select-GuiAction -Action $script:Actions[0]
        $ctlCount = $pnlParams.Controls.Count
        Update-ToolButtons
        $toolAvail = @($script:ToolButtons | Where-Object { $_.Button.Enabled }).Count
        Write-Host ('GUI SELFTEST OK: 页面 {0} 个 / 状态卡片 {1} 个 / 系统工具 {2} 个(可用 {3}) / 更多里功能 {4} 个 / 参数控件 {5} 个 / 窗体 {6}' -f `
            $script:Pages.Count, $cardCount, $script:ToolButtons.Count, $toolAvail, $nodeCount, $ctlCount, $form.Size.ToString()) -ForegroundColor Green
        Write-Host ('  卡片值: ' + ($envVals -join ' | ')) -ForegroundColor Green
        $script:Timer.Dispose()
        $form.Dispose()
    } catch {
        Write-Host ('GUI SELFTEST FAIL: ' + $_.Exception.Message) -ForegroundColor Red
    }
    return
}

[void]$form.ShowDialog()
try { $script:Timer.Dispose() } catch { }

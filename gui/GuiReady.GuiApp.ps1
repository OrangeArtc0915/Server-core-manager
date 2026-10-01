# GuiReady GUI: 环境补全 + 软件管理，界面重做。
# 主页面：环境 / 软件 / 工具 / 更多 / 关于；完整能力收在「更多」里，不干扰主流程。
# 每个动作在独立子进程执行，界面不卡；日志按级别着色。

param(
    [switch]$SelfTest,
    [switch]$LayoutDump,
    # UI 审计：把每个页面、每个动作都"点"一遍（只建界面不执行），再做控件重叠扫描。
    # 用来复现"点进去报错 / 这块压住那块"这类只有真的点一遍才会暴露的问题。
    [switch]$UiAudit,
    # 把窗口渲染成 PNG 后退出（给"界面长什么样"留证据，对齐参考文档 §六 的 SL_CAPTURE）
    [string]$UiShot = '',
    [string]$StartPage = 'env',
    [switch]$KeepConsole
)

$ErrorActionPreference = 'Continue'

# 诊断模式下不要触发页面自己的后台查询（否则审计会顺手起一堆子进程）
$SkipPageHooks = [bool]($SelfTest -or $LayoutDump -or $UiAudit -or $UiShot)

$guiDir   = $PSScriptRoot
$toolRoot = Split-Path -Parent $guiDir
$libDir   = Join-Path $toolRoot 'lib'

# 启动耗时诊断：设了 SCM_BOOT_TRACE=1 就把各阶段耗时追加到 state\boot-trace.txt
$script:BootT0 = Get-Date
function Add-BootTrace {
    param([string]$Stage)
    if ($env:SCM_BOOT_TRACE -ne '1') { return }
    try {
        $d = Join-Path $toolRoot 'state'
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $ms = [int]((Get-Date) - $script:BootT0).TotalMilliseconds
        Add-Content -LiteralPath (Join-Path $d 'boot-trace.txt') -Value ('{0,7} ms  {1}' -f $ms, $Stage) -Encoding UTF8
    } catch { }
}
Add-BootTrace '脚本开始（PowerShell + 解析后）'

foreach ($f in @('GuiReady.Common.ps1', 'GuiReady.Detect.ps1', 'GuiReady.PeInspect.ps1',
                 'GuiReady.Fod.ps1', 'GuiReady.GuiShell.ps1', 'GuiReady.RdpFix.ps1',
                 'GuiReady.DotNet.ps1', 'GuiReady.GuiTest.ps1', 'GuiReady.Matrix.ps1',
                 'GuiReady.Diag.ps1', 'GuiReady.Catalog.ps1', 'GuiReady.Pipeline.ps1',
                 'GuiReady.AutoLogon.ps1', 'GuiReady.Command.ps1', 'GuiReady.PhaseB.ps1', 'GuiReady.Wac.ps1',
                 'GuiReady.Console.ps1', 'GuiReady.Package.ps1', 'GuiReady.Role.ps1',
                 'GuiReady.Monitor.ps1', 'GuiReady.Security.ps1', 'GuiReady.Dsh.ps1',
                 'GuiReady.Integrity.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) { . $p }
}
. (Join-Path $guiDir 'GuiReady.Actions.ps1')
# 设计系统组件库（卡片 / 输入框 / 胶囊 / 进度条 / 圆角路径），规范见 想法.md 第四节。
# 里面只定义函数，但必须在下方第一次调用它们之前加载。
. (Join-Path $guiDir 'GuiReady.Ui.ps1')

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    Write-Host '无法加载 WinForms，改用命令行菜单。' -ForegroundColor Yellow
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolRoot 'Start-GuiReady.ps1')
    return
}

# 自绘按钮 / 无边框外壳窗口这两个类型（见 GuiReady.Ui.ps1）。
# 编译失败时整个界面降级：按钮退回系统按钮、窗口退回有边框窗口 —— 功能不受影响，
# 绝不因为"美化"把工具本身弄成打不开。
$script:UiTypesReady = Initialize-GuiUiTypes

$script:Actions       = @(Get-GuiReadyActions)
Add-BootTrace 'lib 模块与动作清单加载完成'
$script:CurrentAction = $null
$script:ParamControls = @{}
$script:Proc          = $null
$script:OutFile       = ''
$script:ErrFile       = ''
$script:RunLogFile    = ''
$script:OutReader     = $null      # 增量读动作输出用的 StreamReader（保持在文件末尾）
$script:OutReaderPath = ''
$script:LogLines      = 0          # 日志面板当前行数（超过上限时删掉最旧的）
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

# 兜底：任何一个点击处理里漏了 try/catch 的异常，都不再弹出系统的"未处理异常"崩溃框。
# 默认行为是把异常交给 .NET 的未处理异常对话框 —— 用户看到的就是那句
# 「有关调用实时(JIT)调试而不是此对话框的详细信息…」，然后以为整个工具坏了。
# 这里改成：写进日志面板 + 弹一句人话提示，界面继续能用。
# 必须在创建任何窗口之前设好模式。
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        $msg = ''
        try { $msg = [string]$e.Exception.Message } catch { }
        try { Append-GuiLog -Line ('[ERROR] 界面操作出错（已拦下，界面没有崩）: ' + $msg) } catch { }
        try {
            $stk = [string]$e.Exception.StackTrace
            if ($stk) { foreach ($l in (($stk -split "`r?`n") | Select-Object -First 4)) { Append-GuiLog -Line ('[ERROR]   ' + $l.Trim()) } }
        } catch { }
        # 同时落盘：弹框一闪就没了、或者用户说不清报什么错的时候，这个文件就是证据。
        try {
            $errLog = Join-Path $toolRoot 'logs\ui-error.log'
            $stk = ''
            try { $stk = [string]$e.Exception.StackTrace } catch { }
            Add-Content -LiteralPath $errLog -Encoding UTF8 -Value (
                '===== {0} ====={1}{2}{1}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), [Environment]::NewLine, $msg, $stk)
        } catch { }
        try {
            [System.Windows.Forms.MessageBox]::Show($form,
                ("这一步出错了：`r`n`r`n" + $msg + "`r`n`r`n详细信息在下方日志里（右侧「执行日志」面板），" +
                 "也写在 logs\ui-error.log。这一步没有改动系统，可以换个方式再试。"),
                '操作出错', 'OK', 'Error') | Out-Null
        } catch { }
    })
} catch { }

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
    # ============================== 深色主题（唯一主题）==============================
    # 为什么只做深色：
    #   1. 目标场景是 Server Core —— 运维就在深色终端里干活，界面跟终端同调不刺眼；
    #   2. Server Core 常年缺主题服务/显示个性化组件，浅色界面在远桌面里更晃眼；
    #   3. 这就是 想法.md 里最早定的那套深色 Token（Base/Surface/Elevated/Overlay + 靛紫主色）。
    # 取值与 想法.md 4.3 的对应关系写在每行注释里；改色请只改这里，组件一律走 Token。

    # 主色（靛紫系，往下越亮）
    Accent1   = Convert-HslToColor 243 0.75 0.59   # 按下 / 描边        ≈ #4F46E5
    Accent2   = Convert-HslToColor 239 0.84 0.67   # 主色（主按钮底）   ≈ #6366F1
    Accent3   = Convert-HslToColor 230 0.94 0.82   # 提亮（悬停/选中文字）≈ #A5B4FC
    Accent4   = Convert-HslToColor 244 0.47 0.20   # 选中项底（深靛）   ≈ #1E1B4B
    Accent5   = Convert-HslToColor 240 0.30 0.15   # 悬停底 / 更浅的底  ≈ #1B1B33

    # 语义色（深色背景上要比浅色主题更亮才够对比）
    Ok        = Convert-HslToColor 160 0.64 0.52   # ≈ #34D399
    Warn      = Convert-HslToColor 43  0.96 0.56   # ≈ #FBBF24
    Err       = Convert-HslToColor 0   0.91 0.71   # ≈ #F87171
    OkBg      = Convert-HslToColor 160 0.40 0.11   # 胶囊/提示条的深色底
    WarnBg    = Convert-HslToColor 43  0.45 0.12
    ErrBg     = Convert-HslToColor 0   0.40 0.13

    # 背景层次：Base → Surface → Elevated → Overlay
    Bg        = Convert-HslToColor 240 0.24 0.05   # Base     ≈ #0A0A0F
    Sunken    = Convert-HslToColor 240 0.26 0.03   # 凹陷面：输入框底、进度条轨道
    Card      = Convert-HslToColor 240 0.20 0.08   # Surface  ≈ #12121A
    CardHover = Convert-HslToColor 240 0.18 0.12   # Elevated ≈ #1A1A24（hover 提亮）
    Border    = Convert-HslToColor 240 0.16 0.16   # 常规描边
    BorderStrong = Convert-HslToColor 240 0.15 0.27
    NavBg     = Convert-HslToColor 240 0.22 0.06   # 侧栏（比 Base 略亮，分出面）
    Text      = Convert-HslToColor 240 0.20 0.92   # 正文
    SubText   = Convert-HslToColor 240 0.12 0.65   # 次要文字
    Hint      = Convert-HslToColor 240 0.10 0.46   # 提示/占位

    # 日志面板（比页面更深，读起来是一块独立的"终端区域"）
    LogBg     = Convert-HslToColor 240 0.24 0.04
    LogBarBg  = Convert-HslToColor 240 0.20 0.09
    LogText   = Convert-HslToColor 240 0.15 0.87

    # ============================== 外壳与导航（对齐 技术架构与UI实现.md §5.1 / §5.4）==============================
    # 这一组是"窗口外壳 + 侧栏"专用：圆角浮动卡片之外是更暗的一圈留白（Frame），
    # 留白里叠投影；卡片里再分标题栏 / 侧栏 / 内容三层。
    Frame     = Convert-HslToColor 240 0.20 0.075  # 卡片外的留白（比卡片略亮，投影才看得出来）≈ #0F0F17
    ShellBg   = Convert-HslToColor 240 0.24 0.05   # 圆角卡片本体（= Bg）
    ShellLine = Convert-HslToColor 240 0.16 0.20   # 卡片 1px 描边
    TitleBg   = Convert-HslToColor 240 0.22 0.07   # 标题栏
    TitleLine = Convert-HslToColor 240 0.16 0.15   # 标题栏下沿 1px

    # 导航项三态 + 左侧选中竖条（原来的 New-NavItem 用系统按钮画不出这套观感）
    NavActiveBg = Convert-HslToColor 244 0.47 0.20   # 选中底（= Accent4）
    NavHoverBg  = Convert-HslToColor 240 0.30 0.15   # 悬停底（= Accent5）
    NavText     = Convert-HslToColor 240 0.14 0.76   # 未选中文字（侧栏要看得清，往亮里给）
    NavTextHi   = Convert-HslToColor 230 0.94 0.82   # 选中文字（= Accent3）
    NavBar      = Convert-HslToColor 230 0.94 0.82   # 选中竖条

    # 兼容旧命名
    Accent    = Convert-HslToColor 239 0.84 0.67
    AccentHi  = Convert-HslToColor 230 0.94 0.82
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
        # 圆角几何统一在 GuiReady.Ui.ps1 的 New-UiRoundPath 里，自绘描边用的是同一个路径
        $Control.Region = New-Object System.Drawing.Region -ArgumentList (New-UiRoundPath -Width $w -Height $h -Radius $Radius)
    } catch { }
}

function New-FlatButton {
    # 四档语气（对齐参考文档 §5.2 的 OutlineButton）：
    #   Normal → Outline（描边按钮，次要操作）
    #   Primary → Solid（实心强调色，主操作）
    #   Danger  → 危险（红字红底，只给"移除/还原"这类破坏性操作）
    #   Plain   → 纯文字（标题栏里的轻量按钮）
    # 外观全部由 GrGui.UiButton 自绘（圆角 + 三态），样式存在强类型字段里而不是 .Tag，
    # 所以业务代码随便覆盖 .Tag 都不会把按钮样式弄丢（工具按钮 / 商店行按钮都覆盖 Tag）。
    param(
        [string]$Text,
        [int]$Width = 132,
        [int]$Height = 36,
        [string]$Kind = 'Normal',      # Normal | Primary | Danger | Plain
        [int]$Radius = 8,
        [scriptblock]$OnClick = $null
    )

    $b = $null
    if ($script:UiTypesReady) {
        $b = New-Object GrGui.UiButton
        $b.Radius = $Radius
        switch ($Kind) {
            'Primary' {
                $b.BackNormal   = $Pal.Accent2
                $b.BackHover    = $Pal.Accent3
                $b.BackPress    = $Pal.Accent1
                $b.BackIdle     = $Pal.Accent4
                $b.BorderColor  = $Pal.Accent2
                $b.BorderIdle   = $Pal.Accent4
                $b.ForeNormal   = [System.Drawing.Color]::White
                $b.ForeHover    = [System.Drawing.Color]::White
                $b.ForeIdle     = $Pal.Hint
            }
            'Danger' {
                $b.BackNormal   = $Pal.Card
                $b.BackHover    = $Pal.ErrBg
                $b.BackPress    = $Pal.ErrBg
                $b.BackIdle     = $Pal.Card
                $b.BorderColor  = $Pal.ErrBg
                $b.BorderIdle   = $Pal.Border
                $b.ForeNormal   = $Pal.Err
                $b.ForeHover    = $Pal.Err
                $b.ForeIdle     = $Pal.Hint
            }
            'Plain' {
                # 标题栏里的窗口按钮 / 轻量文字按钮：平时没有底和边，悬停才浮出一层
                $b.BackNormal   = $Pal.TitleBg
                $b.BackHover    = $Pal.Accent5
                $b.BackPress    = $Pal.Accent4
                $b.BackIdle     = $Pal.TitleBg
                $b.BorderColor  = [System.Drawing.Color]::FromArgb(0, 0, 0, 0)
                $b.BorderIdle   = [System.Drawing.Color]::FromArgb(0, 0, 0, 0)
                $b.BorderWidth  = 0
                $b.ForeNormal   = $Pal.SubText
                $b.ForeHover    = $Pal.Text
                $b.ForeIdle     = $Pal.Hint
            }
            default {
                $b.BackNormal   = $Pal.Card
                $b.BackHover    = $Pal.CardHover
                $b.BackPress    = $Pal.Accent4
                $b.BackIdle     = $Pal.Card
                $b.BorderColor  = $Pal.BorderStrong
                $b.BorderIdle   = $Pal.Border
                $b.ForeNormal   = $Pal.Text
                $b.ForeHover    = $Pal.Text
                $b.ForeIdle     = $Pal.Hint
            }
        }
        $b.BackColor = $b.BackNormal
    } else {
        # 降级路径：自绘类型没编译出来时用系统按钮，界面还能用
        $b = New-Object System.Windows.Forms.Button
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 1
        $b.BackColor = $(if ($Kind -eq 'Primary') { $Pal.Accent2 } else { $Pal.Card })
        $b.ForeColor = $(if ($Kind -eq 'Primary') { [System.Drawing.Color]::White } elseif ($Kind -eq 'Danger') { $Pal.Err } else { $Pal.Text })
        $b.FlatAppearance.BorderColor = $Pal.Border
    }

    $b.Text   = $Text
    $b.Size   = New-Object System.Drawing.Size($Width, $Height)
    $b.Font   = New-Font -Size 9.5
    $b.Cursor = 'Hand'
    Set-Rounded -Control $b -Radius $Radius
    if ($OnClick) { $b.Add_Click($OnClick) }
    return $b
}

function New-IconButton {
    # 圆角图标按钮（对齐参考文档 §5.2 的 RoundIconButton）。
    # 图标是自绘的（Draw-UiIcon），所以不依赖图标字体、也不依赖任何 SVG 运行时。
    # 配色一律走返回值上的 .Tag（Base / Fore / HoverBack / HoverFore），
    # 需要特殊语气（例如关闭按钮悬停变红）时由调用方改 .Tag 里的值即可 ——
    # 不把 Color 做成参数，是因为 PowerShell 里 [System.Drawing.Color] 参数没法用 $null 当默认值
    # （会直接抛 "Cannot convert null to type System.Drawing.Color"）。
    param(
        [string]$Icon,
        [int]$Size = 34,
        [int]$Radius = 8,
        [string]$Tip = '',
        [scriptblock]$OnClick = $null,
        [System.Windows.Forms.Control]$Parent = $null
    )
    $bg = $Pal.TitleBg

    $p = New-Object System.Windows.Forms.Panel
    $p.Size      = New-Object System.Drawing.Size($Size, $Size)
    $p.BackColor = $bg
    $p.Cursor    = 'Hand'
    $p.Tag       = @{
        Radius = $Radius; Base = $bg; Hover = $false
        Fore = $Pal.SubText; HoverBack = $Pal.Accent5; HoverFore = $Pal.Text
        Icon = $Icon; IconSize = [int]($Size * 0.52)
    }
    Enable-UiDoubleBuffer -Control $p
    Set-Rounded -Control $p -Radius $Radius

    $p.Add_Paint({
        param($s, $e)
        try {
            $t = $s.Tag
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $base = $t.Base
            $fore = $t.Fore
            if ($t.Hover) { $base = $t.HoverBack; $fore = $t.HoverFore }
            $path  = New-UiRoundPath -Width $s.Width -Height $s.Height -Radius $t.Radius
            $brush = New-Object System.Drawing.SolidBrush($base)
            try { $g.FillPath($brush, $path) } finally { $brush.Dispose(); $path.Dispose() }
            $isz = [int]$t.IconSize
            if ($isz -le 0) { $isz = 16 }
            Draw-UiIcon -Graphics $g -Name ([string]$t.Icon) -X ([int](($s.Width - $isz) / 2)) -Y ([int](($s.Height - $isz) / 2)) `
                -Size $isz -Color $fore
        } catch { }
    })
    $p.Add_MouseEnter({ $this.Tag.Hover = $true;  $this.Invalidate() })
    $p.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Invalidate() })
    if ($OnClick) { $p.Add_Click($OnClick) }
    if ($Tip) {
        try {
            if (-not $script:UiToolTip) {
                $script:UiToolTip = New-Object System.Windows.Forms.ToolTip
                $script:UiToolTip.AutoPopDelay = 12000
                $script:UiToolTip.InitialDelay = 400
                $script:UiToolTip.ReshowDelay = 200
            }
            $script:UiToolTip.SetToolTip($p, $Tip)
        } catch { }
    }
    if ($Parent) { $Parent.Controls.Add($p) }
    return $p
}

function New-HintBar {
    # 说明条：语义浅色底 + 左侧色条（对应 PCL 的 MyHint）。
    # 注意：返回值上的 .Tag 必须是内层 Label —— 自适应布局靠它同步文字宽度
    #（见 Update-PageLayout 里 `$hintEnv.Tag.Width = ...`），别再往 .Tag 上挂别的东西。
    param([string]$Text, [string]$Kind = 'Blue', [int]$Width = 600, [int]$Height = 34)
    $bg = $Pal.Accent4
    $bar = $Pal.Accent2
    switch ($Kind) {
        'Green'  { $bg = $Pal.OkBg;   $bar = $Pal.Ok }
        'Yellow' { $bg = $Pal.WarnBg; $bar = $Pal.Warn }
        'Red'    { $bg = $Pal.ErrBg;  $bar = $Pal.Err }
    }
    $host_ = New-Object System.Windows.Forms.Panel
    $host_.Size      = New-Object System.Drawing.Size($Width, $Height)
    $host_.BackColor = $bg
    $edge = New-Object System.Windows.Forms.Panel
    $edge.Size      = New-Object System.Drawing.Size(3, [Math]::Max(8, $Height - 12))
    $edge.Location  = New-Object System.Drawing.Point(1, 6)
    $edge.BackColor = $bar
    Set-Rounded -Control $edge -Radius 2
    $host_.Controls.Add($edge)
    $lb = New-Label -Text $Text -Size 9 -Color SubText
    $lb.Location = New-Object System.Drawing.Point(14, [int](($Height - 18) / 2))
    $lb.AutoSize = $false
    $lb.Size = New-Object System.Drawing.Size(($Width - 24), 18)
    $host_.Controls.Add($lb)
    Set-Rounded -Control $host_ -Radius 8
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

function New-StatusCard {
    # 状态卡片：● + 标题 + 大值 + 副行。环境页（7 张）与仪表盘（4 张）共用。
    # 必须在页面创建之前定义 —— 仪表盘页在加载时就要用它建卡片。
    param([string]$Title, [int]$Width = 208, [System.Windows.Forms.Control]$Parent = $null)
    # 卡片统一走设计系统的 New-Card（Token 描边 + 圆角 10），不再用系统的 FixedSingle 灰边
    $card = New-Card -Width $Width -Height 68 -Radius 10
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 10)

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

    # 默认挂在环境页的卡片区；仪表盘等其它页面用 -Parent 指定自己的容器
    $target = $pnlCards
    if ($Parent) { $target = $Parent }
    $target.Controls.Add($card)
    # 把内部文字与卡片一起登记进 Tag：窗口变窄时要连内部文字一起改宽，否则文字会被裁成半截
    #（真机 1024x768 实测：仪表盘 4 张指标卡挤成 3+1 两行，容器高度却是写死的 1 行，第 4 张整个看不见）
    $card.Tag.CardParts = @{ Title = $lt; Value = $lv; Sub = $ls; Dot = $dot }
    return [pscustomobject]@{ Panel = $card; Title = $lt; Value = $lv; Sub = $ls; Dot = $dot }
}

function Set-CardRowLayout {
    # 把一行状态卡片按"实际可用宽度"摊平：先算每行几张，再把卡片和卡片内部文字一起改宽。
    # 环境页（7 张，窄屏会换行）与仪表盘（4 张，尽量一行放下）共用这一套，
    # 不再各写一份 —— 之前写死宽度/高度，窄屏下就是"溢出 + 第二行被裁"。
    param(
        [System.Windows.Forms.FlowLayoutPanel]$Panel,
        [int]$Width,
        [int]$Gap = 10,
        [int]$MinCardW = 150
    )
    try {
        $cards = @($Panel.Controls | Where-Object {
                $_ -and ($_.Tag -is [hashtable]) -and $_.Tag.ContainsKey('CardParts')
            })
        if ($cards.Count -eq 0) { return }

        $perRow = [Math]::Max(1, [Math]::Floor(($Width + $Gap) / ($MinCardW + $Gap)))
        if ($perRow -gt $cards.Count) { $perRow = $cards.Count }
        $cardW = [Math]::Floor(($Width - ($perRow - 1) * $Gap) / $perRow) - 6
        if ($cardW -lt $MinCardW) { $cardW = $MinCardW }
        # 卡片宽被抬高后重新反算每行到底能放几张（否则会比可用宽度宽出去）
        $perRow = [Math]::Max(1, [Math]::Floor(($Width + $Gap) / ($cardW + $Gap)))

        foreach ($cd in $cards) {
            $cd.Width = $cardW
            $parts = $cd.Tag.CardParts
            if ($parts) {
                if ($parts.Value) { $parts.Value.Width = $cardW - 42 }
                if ($parts.Sub)   { $parts.Sub.Width   = $cardW - 42 }
            }
            Set-Rounded -Control $cd -Radius 10
        }
    } catch { }
}

function Get-FlowWrappedHeight {
    # 算一个会换行的 FlowLayoutPanel 需要多高才装得下所有子控件。
    # 用来替换"写死一行高度" —— 否则窄屏换行后的第二行会被容器裁掉。
    param([System.Windows.Forms.FlowLayoutPanel]$Panel, [int]$Width)
    try {
        $x = 0; $rows = 1; $rowH = 0
        foreach ($c in $Panel.Controls) {
            # 不跳过不可见的子控件：布局体检（-LayoutDump）时整个窗口都没显示、Visible 全是 False，
            # 一跳过就会算出 0，容器高度就永远算不出来（实测踩到）。
            # 卡片/按钮这类容器里的项本来就是常显的，多算一行的代价也可接受。
            $iw = $c.Width + $c.Margin.Left + $c.Margin.Right
            $ih = $c.Height + $c.Margin.Top + $c.Margin.Bottom
            if ($x -gt 0 -and ($x + $iw) -gt $Width) { $rows++; $x = 0 }
            $x += $iw
            if ($ih -gt $rowH) { $rowH = $ih }
        }
        if ($rowH -le 0) { return 0 }
        return [int]($Panel.Padding.Top + $Panel.Padding.Bottom + $rows * $rowH + 4)
    } catch { return 0 }
}

# ============================ 窗体骨架 ============================
# 外壳照 docs\技术架构与UI实现.md §5.1 的思路，但换成 WinForms 能实现的形式：
#   无边框窗口 → 最外圈留白（Frame 色）里自绘一圈投影 → 中间一张 12px 圆角卡片；
#   卡片内部再分三层：标题栏（Top，横贯全宽）/ 左侧导航（Left）/ 内容 + 日志（Fill）。
# 拖动、边缘拖拽缩放、最小化 / 最大化 / 关闭都在 GrGui.ShellForm 里（见 GuiReady.Ui.ps1），
# 只用到 user32 的拖动消息与 dwmapi 的圆角偏好 —— 不依赖 WPF、不依赖任何第三方库，
# Server Core（只有 GDI+）上可用；就算 Add-Type 被策略挡掉，也会自动退回有边框窗口。

$script:ShellMargin = 12
$script:ShellRadius = 12

if ($script:UiTypesReady) {
    $form = New-Object GrGui.ShellForm
} else {
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'Sizable'
    $script:ShellMargin = 0
}

$form.Text          = 'Server Core GUI 就绪工具'
# 尺寸要**跟着屏幕走**，不能写死。Server Core 上最常见的就是 1024x768（Hyper-V 默认显示适配器），
# 真机实测：写死 1240x820 + 最小 1080x700 时，窗口比屏幕还大，右侧和底部直接被切掉，
# 而且"最小宽度 1080 > 屏幕 1024"意味着用户连缩都缩不小。
# 现在按主屏可用区域取小值：屏幕够大就还是 1240x820 那套，屏幕小就恰好铺满、一点都不溢出。
$__wa       = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$__wantW    = 1240
$__wantH    = 820
if ($__wa.Width  -gt 0) { $__wantW = [Math]::Min($__wantW, $__wa.Width) }
if ($__wa.Height -gt 0) { $__wantH = [Math]::Min($__wantH, $__wa.Height) }
$form.Size          = New-Object System.Drawing.Size($__wantW, $__wantH)
$form.MinimumSize   = New-Object System.Drawing.Size([Math]::Min(1080, $__wantW), [Math]::Min(660, $__wantH))
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $(if ($script:ShellMargin -gt 0) { $Pal.Frame } else { $Pal.Bg })
$form.Font          = New-Font -Size 9.5
$form.KeyPreview    = $true

$script:DragActive = $false

function Start-ShellDrag {
    # 拖动窗口：自己跟踪鼠标增量来移动窗口。
    # 为什么不用系统的标题栏拖动消息（SendMessage WM_NCLBUTTONDOWN/HTCAPTION）：
    # 那条路要靠 P/Invoke 在运行时解析成功，一旦解析不到，表现就是"窗口拖不动"，
    # 而用户除了干瞪眼没有别的办法。自己算增量完全在掌控里，代价只是没有 Aero Snap
    #（Server Core 上基本用不到贴边分屏）。
    # 拖动期间把鼠标捕获交给标题栏，光标滑出去也不会丢 MouseMove（否则"拖着拖着就断"）。
    try {
        $script:DragActive      = $true
        $script:DragStartCursor = [System.Windows.Forms.Cursor]::Position
        $script:DragStartForm   = $form.Location
        $pnlTitle.Capture       = $true
    } catch { }
}

function Update-ShellDrag {
    if (-not $script:DragActive) { return }
    try {
        $cur = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object System.Drawing.Point(
            ($script:DragStartForm.X + ($cur.X - $script:DragStartCursor.X)),
            ($script:DragStartForm.Y + ($cur.Y - $script:DragStartCursor.Y)))
    } catch { }
}

function Stop-ShellDrag {
    $script:DragActive = $false
    try { $pnlTitle.Capture = $false } catch { }
}

function Toggle-ShellMax {
    if ($script:UiTypesReady) { try { $form.ToggleMax(); Layout-Shell; Update-PageLayout } catch { } }
}

if ($script:ShellMargin -gt 0) {
    $form.Add_Paint({
        param($s, $e)
        try {
            Invoke-UiShellShadow -Graphics $e.Graphics -Width $s.ClientSize.Width -Height $s.ClientSize.Height `
                -Band $script:ShellMargin -Radius $script:ShellRadius
        } catch { }
    })
}

# ---- 外壳卡片：12px 圆角 + 1px 描边，Padding 留 1px 让描边不被子控件盖掉 ----
$pnlShell           = New-Object System.Windows.Forms.Panel
$pnlShell.BackColor = $Pal.Bg
$pnlShell.Padding   = New-Object System.Windows.Forms.Padding(1)
$pnlShell.Tag       = @{ Radius = $script:ShellRadius; Line = $Pal.ShellLine }
Enable-UiDoubleBuffer -Control $pnlShell
$pnlShell.Add_Paint({
    param($s, $e)
    try {
        Invoke-UiPaintFrame -Graphics $e.Graphics -Width $s.Width -Height $s.Height `
            -Radius $s.Tag.Radius -Fill $s.BackColor -Border $s.Tag.Line
    } catch { }
})
$form.Controls.Add($pnlShell)
# ---- 标题栏（自绘：图标 + 标题 + 副标题 + 右侧动作 / 窗口按钮）----
$pnlTitle           = New-Object System.Windows.Forms.Panel
$pnlTitle.Dock      = 'Top'
$pnlTitle.Height    = 54
$pnlTitle.BackColor = $Pal.TitleBg
Enable-UiDoubleBuffer -Control $pnlTitle
$pnlTitle.Add_Paint({
    param($s, $e)
    try { Draw-UiIcon -Graphics $e.Graphics -Name 'env' -X 18 -Y 17 -Size 21 -Color $Pal.Accent3 } catch { }
})
$pnlTitle.Add_MouseDown({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-ShellDrag } })
$pnlTitle.Add_MouseMove({ Update-ShellDrag })
$pnlTitle.Add_MouseUp({ Stop-ShellDrag })
$pnlTitle.Add_DoubleClick({ Toggle-ShellMax })
$pnlShell.Controls.Add($pnlTitle)

$lblTitle          = New-Label -Text 'Server Core GUI 就绪工具' -Size 12.5 -Style Bold
$lblTitle.Location = New-Object System.Drawing.Point(50, 9)
$lblTitle.Add_MouseDown({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-ShellDrag } })
$lblTitle.Add_DoubleClick({ Toggle-ShellMax })
$pnlTitle.Controls.Add($lblTitle)

$lblSub          = New-Label -Text '给 Windows Server Core 补上图形化管理能力' -Size 8.5 -Color Hint
$lblSub.Location = New-Object System.Drawing.Point(52, 30)
$lblSub.Add_MouseDown({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-ShellDrag } })
$pnlTitle.Controls.Add($lblSub)

# 退出（会打开终端）：原来那个大块红色按钮太抢眼，收成标题栏右侧的轻量按钮
$btnExitBack           = New-FlatButton -Text '打开终端并退出' -Width 120 -Height 30 -Kind Plain
$pnlTitle.Controls.Add($btnExitBack)

# 窗口按钮：最小化 / 最大化 / 关闭 —— 位置在 Layout-Shell 里按标题栏宽度右对齐
$btnWinClose = New-IconButton -Icon 'window-close' -Size 32 -Radius 7 -Tip '关闭（会自动打开终端）' -OnClick { Exit-ToCommandLine }
$btnWinClose.Tag.HoverBack = $Pal.ErrBg
$btnWinClose.Tag.HoverFore = $Pal.Err
$btnWinMax   = New-IconButton -Icon 'window-max' -Size 32 -Radius 7 -Tip '最大化 / 还原' -OnClick { Toggle-ShellMax }
$btnWinMin   = New-IconButton -Icon 'window-min' -Size 32 -Radius 7 -Tip '最小化' -OnClick { $form.WindowState = 'Minimized' }
$pnlTitle.Controls.Add($btnWinClose)
$pnlTitle.Controls.Add($btnWinMax)
$pnlTitle.Controls.Add($btnWinMin)

$pnlTitleLine           = New-Object System.Windows.Forms.Panel
$pnlTitleLine.Dock      = 'Bottom'
$pnlTitleLine.Height    = 1
$pnlTitleLine.BackColor = $Pal.TitleLine
$pnlTitle.Controls.Add($pnlTitleLine)

# ---- 左侧导航 ----
# 导航项不是系统按钮，而是一块自绘的面板：圆角底 + 左侧 3px 竖条 + 线性图标 + 文字。
# 选中态由三样共同表达（底 / 图标与文字颜色 / 左侧竖条），这是参考文档 §5.2 NavItem 的做法；
# 用系统 Button 画不出这套观感（系统按钮的默认渲染不受 FlatAppearance 完全控制）。
$pnlNav           = New-Object System.Windows.Forms.Panel
$pnlNav.Dock      = 'Left'
$pnlNav.Width     = 208
$pnlNav.BackColor = $Pal.NavBg
$pnlShell.Controls.Add($pnlNav)

$script:NavItemH = 40
$script:NavStep  = 44
$pnlNavTop           = New-Object System.Windows.Forms.Panel
$pnlNavTop.Dock      = 'Top'
# 11 个导航项，每项 40 高、步进 44：最后一项 Y=448 + 40 = 488，面板留 496。
# （页面多，项就得压缩 —— 再高的那套在最小窗口高度下会放不下。）
$pnlNavTop.Height    = 496
$pnlNavTop.BackColor = $Pal.NavBg
$pnlNav.Controls.Add($pnlNavTop)

function New-NavItem {
    param([string]$Text, [string]$PageKey, [int]$Y, [string]$Icon)
    $w = 184
    $h = $script:NavItemH
    $p = New-Object System.Windows.Forms.Panel
    $p.Size      = New-Object System.Drawing.Size($w, $h)
    $p.Location  = New-Object System.Drawing.Point(12, $Y)
    $p.BackColor = $Pal.NavBg
    $p.Cursor    = 'Hand'
    $p.Tag       = @{ Page = $PageKey; Icon = $Icon; Text = $Text; Active = $false; Hover = $false; Radius = 9 }
    Enable-UiDoubleBuffer -Control $p
    Set-Rounded -Control $p -Radius 9

    $p.Add_Paint({
        param($s, $e)
        try {
            $t = $s.Tag
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

            $bg = $null
            if ($t.Active)     { $bg = $Pal.NavActiveBg }
            elseif ($t.Hover)  { $bg = $Pal.NavHoverBg }
            if ($bg) {
                $path  = New-UiRoundPath -Width $s.Width -Height $s.Height -Radius $t.Radius
                $brush = New-Object System.Drawing.SolidBrush($bg)
                try { $g.FillPath($brush, $path) } finally { $brush.Dispose(); $path.Dispose() }
            }
            # 选中竖条：3px 圆角小条，贴左内边
            if ($t.Active) {
                $bp = New-UiRoundPath -Width 3 -Height 18 -Radius 2
                $bb = New-Object System.Drawing.SolidBrush($Pal.NavBar)
                try {
                    $g.TranslateTransform(6, [int](($s.Height - 18) / 2))
                    $g.FillPath($bb, $bp)
                    $g.TranslateTransform(-6, -[int](($s.Height - 18) / 2))
                } finally { $bb.Dispose(); $bp.Dispose() }
            }

            $fore = $(if ($t.Active) { $Pal.NavTextHi } else { $Pal.NavText })
            $isz  = 18
            Draw-UiIcon -Graphics $g -Name ([string]$t.Icon) -X 18 -Y ([int](($s.Height - $isz) / 2)) -Size $isz -Color $fore

            # ⚠ 这里必须先把每个实参算进变量，再调用 DrawText。
            # 直接写 `DrawText($g, $txt, $font, $rect, (FLAGS -bor FLAGS), $color)` 是不行的：
            # PowerShell 里逗号是**数组运算符**，`(… -bor …), $color` 会被当成"一个数组实参"，
            # 于是实参整体错位、foreColor 收到的是 TextFormatFlags → 抛类型转换异常，
            # 而异常被 catch 吞掉的表现就是"图标画出来了、文字一个字都没有"（实测踩到）。
            $txt   = [string]$t.Text
            $font  = $(if ($t.Active) { $script:NavFontBold } else { $script:NavFont })
            $rect  = New-Object System.Drawing.Rectangle(46, 0, ($s.Width - 54), $s.Height)
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor `
                     [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                     [System.Windows.Forms.TextFormatFlags]::SingleLine -bor `
                     [System.Windows.Forms.TextFormatFlags]::NoPadding
            [System.Windows.Forms.TextRenderer]::DrawText($g, $txt, $font, $rect, $fore, $flags)
        } catch { }
    })
    $p.Add_MouseEnter({ $this.Tag.Hover = $true;  $this.Invalidate() })
    $p.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Invalidate() })
    $p.Add_Click({ Show-GuiPage -Key ([string]$this.Tag.Page) })
    $pnlNavTop.Controls.Add($p)
    return $p
}

$script:NavFont     = New-Font -Size 10.5
$script:NavFontBold = New-Font -Size 10.5 -Style Bold

$navEnv    = New-NavItem -Text '环境'    -PageKey 'env'      -Y 8   -Icon 'env'
$navApp    = New-NavItem -Text '软件'    -PageKey 'app'      -Y 52  -Icon 'app'
$navStore  = New-NavItem -Text '商店'    -PageKey 'store'    -Y 96  -Icon 'store'
$navRole   = New-NavItem -Text '角色'    -PageKey 'role'     -Y 140 -Icon 'role'
$navMon    = New-NavItem -Text '仪表盘'  -PageKey 'monitor'  -Y 184 -Icon 'monitor'
$navSec    = New-NavItem -Text '安全'    -PageKey 'security' -Y 228 -Icon 'security'
$navBeauty = New-NavItem -Text '美化'    -PageKey 'beauty'   -Y 272 -Icon 'beauty'
$navDsh    = New-NavItem -Text 'AI'      -PageKey 'dsh'      -Y 316 -Icon 'dsh'
$navTool   = New-NavItem -Text '工具'    -PageKey 'tool'     -Y 360 -Icon 'tool'
$navMore   = New-NavItem -Text '更多'    -PageKey 'more'     -Y 404 -Icon 'more'
$navAbout  = New-NavItem -Text '关于'    -PageKey 'about'    -Y 448 -Icon 'about'
$script:NavButtons = @($navEnv, $navApp, $navStore, $navRole, $navMon, $navSec, $navBeauty, $navDsh, $navTool, $navMore, $navAbout)

$lblVer = New-Label -Text ('v1.0  ·  ' + (Get-Date -Format 'yyyy-MM-dd')) -Size 8.5 -Color Hint
$lblVer.Dock = 'Bottom'
$lblVer.Height = 30
$lblVer.TextAlign = 'MiddleLeft'
$lblVer.Padding = New-Object System.Windows.Forms.Padding(20, 0, 0, 0)
$pnlNav.Controls.Add($lblVer)

# 侧栏右侧的 1px 分隔线：必须在 lblVer 之后加 —— 后加的先停靠，
# 这样它是"整条竖线"（Right 停靠拿到的是整个侧栏高度），而不是被底部版本号截断。
$pnlNavLine           = New-Object System.Windows.Forms.Panel
$pnlNavLine.Dock      = 'Right'
$pnlNavLine.Width     = 1
$pnlNavLine.BackColor = $Pal.TitleLine
$pnlNav.Controls.Add($pnlNavLine)

# ---- 右侧内容 + 日志 ----
# 内容区与日志都在同一个内边距里（18/14），日志默认 190 高、可折叠到只剩标题栏。
$pnlRight = New-Object System.Windows.Forms.Panel
$pnlRight.Dock      = 'Fill'
$pnlRight.BackColor = $Pal.Bg
$pnlRight.Padding   = New-Object System.Windows.Forms.Padding(18, 14, 18, 14)
$pnlShell.Controls.Add($pnlRight)

# 日志面板（自绘圆角 + 描边；区域靠 Region 裁）
$pnlLog           = New-Object System.Windows.Forms.Panel
$pnlLog.Dock      = 'Bottom'
$pnlLog.Height    = 190
$pnlLog.BackColor = $Pal.LogBg
$pnlLog.Padding   = New-Object System.Windows.Forms.Padding(1)
$pnlLog.Tag       = @{ Radius = 10; Line = $Pal.Border }
Enable-UiDoubleBuffer -Control $pnlLog
Set-Rounded -Control $pnlLog -Radius 10
$pnlLog.Add_Paint({
    param($s, $e)
    try {
        Invoke-UiPaintFrame -Graphics $e.Graphics -Width $s.Width -Height $s.Height `
            -Radius $s.Tag.Radius -Fill $s.BackColor -Border $s.Tag.Line
    } catch { }
})

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

$pnlLogBar           = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlLogBar.Dock      = 'Top'
$pnlLogBar.Height    = 32
$pnlLogBar.Padding   = New-Object System.Windows.Forms.Padding(6, 3, 8, 0)
$pnlLogBar.BackColor = $Pal.LogBarBg
$pnlLog.Controls.Add($pnlLogBar)

function Open-GuiFolder {
    # 打开一个目录：不存在就先建出来（logs / reports 本来就是我们自己的目录），
    # 失败只提示、不抛异常 —— 从点击处理里抛出去会变成系统的"未处理异常"崩溃框
    #（就是那句"有关调用实时(JIT)调试…"），用户会以为整个工具坏了。
    param([string]$Path, [string]$Label = '目录')
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        Start-Process -FilePath $Path | Out-Null
    } catch {
        Append-GuiLog -Line ('[WARN] 打不开{0}（{1}）: {2}' -f $Label, $Path, $_.Exception.Message)
        try {
            [System.Windows.Forms.MessageBox]::Show($form,
                ("打不开{0}：`r`n{1}`r`n`r`n{2}" -f $Label, $Path, $_.Exception.Message),
                '打不开', 'OK', 'Warning') | Out-Null
        } catch { }
    }
}

function Open-GuiUrl {
    # 打开网址。Server Core 上常常没有浏览器 —— 这是常态而不是错误，
    # 所以失败时把地址原样列出来让用户拿到别的机器上打开，而不是弹崩溃框。
    param([string]$Url)
    try {
        Start-Process $Url | Out-Null
        Append-GuiLog -Line ('[OK] 已用默认浏览器打开: ' + $Url)
    } catch {
        Append-GuiLog -Line ('[WARN] 本机打不开浏览器: ' + $Url)
        try {
            [System.Windows.Forms.MessageBox]::Show($form,
                ("本机没有可用的默认浏览器（Server Core 上很常见）。`r`n`r`n地址：`r`n{0}`r`n`r`n可以复制到别的机器上打开。" -f $Url),
                '没有浏览器', 'OK', 'Information') | Out-Null
        } catch { }
    }
}

function New-LogBtn {
    param([string]$Text, [scriptblock]$OnClick)
    $b = New-FlatButton -Text $Text -Width 96 -Height 24 -Radius 6 -OnClick $OnClick
    $b.Font   = New-Font -Size 9
    $b.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 0)
    $pnlLogBar.Controls.Add($b)
    return $b
}

# 折叠 / 展开日志：占位最靠左，图标在折叠状态会翻过来
$script:BtnLogToggle = New-IconButton -Icon 'chevron-down' -Size 24 -Radius 6 -Tip '收起 / 展开日志'
$script:BtnLogToggle.Margin = New-Object System.Windows.Forms.Padding(2, 4, 2, 0)
$pnlLogBar.Controls.Add($script:BtnLogToggle)

$lblLogTitle          = New-Label -Text '执行日志' -Size 9.5 -Color LogText
$lblLogTitle.Margin   = New-Object System.Windows.Forms.Padding(0, 7, 16, 0)
$pnlLogBar.Controls.Add($lblLogTitle)

$script:LogExpandedH = 190
$script:LogCollapsed = $false

function Set-LogCollapsed {
    param([bool]$On)
    try {
        $script:LogCollapsed = $On
        if ($On) {
            $txtLog.Visible = $false
            $pnlLog.Height  = 34
            if ($script:BtnLogToggle) { $script:BtnLogToggle.Tag.Icon = 'chevron-up'; $script:BtnLogToggle.Invalidate() }
        } else {
            $txtLog.Visible = $true
            $pnlLog.Height  = $script:LogExpandedH
            if ($script:BtnLogToggle) { $script:BtnLogToggle.Tag.Icon = 'chevron-down'; $script:BtnLogToggle.Invalidate() }
        }
        Update-Chrome
    } catch { }
}

$script:BtnLogToggle.Add_Click({ Set-LogCollapsed -On (-not $script:LogCollapsed) })

[void](New-LogBtn -Text '清空' -OnClick { $txtLog.Clear(); $script:LogLines = 0 })
[void](New-LogBtn -Text '打开日志文件' -OnClick {
        if ($script:RunLogFile -and (Test-Path -LiteralPath $script:RunLogFile)) {
            try { Start-Process -FilePath $script:RunLogFile | Out-Null }
            catch {
                # .log 在本机可能没有关联程序（Server Core 上没有记事本很常见）→ 退一步打开它所在的目录
                Append-GuiLog -Line '[WARN] 本机没有能打开 .log 的程序，改为打开它所在的目录。'
                Open-GuiFolder -Path (Split-Path -Parent $script:RunLogFile) -Label '日志目录'
            }
        }
        else { [System.Windows.Forms.MessageBox]::Show('本次还没有日志文件。', '提示', 'OK', 'Information') | Out-Null }
    })
[void](New-LogBtn -Text '打开报告目录' -OnClick { Open-GuiFolder -Path (Join-Path $toolRoot 'reports') -Label '报告目录' })

$btnStopTop        = New-LogBtn -Text '停止当前动作' -OnClick {
    if ($script:Proc) {
        try { Stop-Process -Id $script:Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        Append-GuiLog -Line '[WARN] 已按你的要求停止动作。'
        Finish-GuiAction -ExitCode -1
    }
}

$pnlContent = New-Object System.Windows.Forms.Panel
$pnlContent.Dock      = 'Fill'
$pnlContent.BackColor = $Pal.Bg

# 日志与内容之间留一道 12px 的空隙：Dock 不吃 Margin，所以用一个空面板当"撑杆"。
# 加进 $pnlRight 的顺序决定停靠优先级（后加的先停靠），所以顺序必须是：
#   内容(Fill) → 空隙(Bottom) → 日志(Bottom)
$pnlGapLog           = New-Object System.Windows.Forms.Panel
$pnlGapLog.Dock      = 'Bottom'
$pnlGapLog.Height    = 12
$pnlGapLog.BackColor = $Pal.Bg

$pnlRight.Controls.Add($pnlContent)
$pnlRight.Controls.Add($pnlGapLog)
$pnlRight.Controls.Add($pnlLog)

# 停靠优先级 = 集合里"后加的先停靠"，所以这里再钉一次关系：
#   标题栏（Top，横贯全宽）→ 侧栏（Left，在标题栏下方）→ 内容 + 日志（Fill）
$pnlRight.BringToFront()
$pnlTitle.SendToBack()

# ============================ 环境页 ============================

$pageEnv           = New-Object System.Windows.Forms.Panel
$pageEnv.Dock      = 'Fill'
$pageEnv.BackColor = $Pal.Bg
$pageEnv.AutoScroll = $true     # 窗口很小的时候宁可出滚动条，也不要裁掉内容
$script:Pages['env'] = $pageEnv
$pnlContent.Controls.Add($pageEnv)

$lblEnvHead          = New-Label -Text '环境补全' -Size 14 -Style Bold
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

$btnAutoLogon = New-FlatButton -Text '自动登录' -Width 110 -Height 42
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

$lblAppHead          = New-Label -Text '软件管理' -Size 14 -Style Bold
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
$lstApps.BorderStyle = 'None'      # 系统边框在深色主题里是一条浅灰线，很扎眼
$lstApps.HideSelection = $false
$lstApps.Font      = New-Font -Size 9.5
$lstApps.BackColor = $Pal.Card
$lstApps.ForeColor = $Pal.Text
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

# 工具页分两组：
#   1) 默认显示的：Windows Admin Center 里没有的（记事本 / 命令提示符 / 美化终端 /
#      MMC 控制台 / 资源监视器 / 系统信息 / PowerShell ISE）
#   2) 「Windows Admin Center 里也有」：与 WAC 重复的管理工具（默认收起，避免页面臃肿；
#      检测到本机装了 WAC 且服务在运行时，整组隐藏 —— 那些直接在 WAC 里操作即可）
# WAC 工具清单依据官方文档：Certificates / Devices / Events / Files / Firewall / Installed apps /
# Local users & groups / Networks / Performance Monitor / PowerShell / Processes / Registry /
# Scheduled tasks / Services / Storage / Updates / Virtual machines 等。
$script:ToolGroups = @(
    [pscustomobject]@{ Group = '常用'; Items = @(
        @{ Name = '记事本';         Target = 'notepad.exe' },
        @{ Name = '命令提示符';     Target = 'cmd.exe' },
        @{ Name = '美化终端';       Target = 'scm-term.cmd';
           Hint = '还没安装美化终端。可以在「更多 → 终端美化 → 一键美化终端」里装（Nerd Font + Oh My Posh + Fastfetch，素材内置不联网）。装好后任意目录输入 scm-term 就能打开 UTF-8 + Nerd Font 的控制台。' }
    ) }
    [pscustomobject]@{ Group = '诊断与脚本'; Items = @(
        @{ Name = 'MMC 控制台';     Target = 'mmc.exe' },
        @{ Name = '资源监视器';     Target = 'resmon.exe' },
        @{ Name = '系统信息';       Target = 'msinfo32.exe' },
        @{ Name = 'PowerShell ISE'; Target = 'powershell_ise.exe' }
    ) }
)

$script:ToolGroupsWac = @(
    @{ Name = '文件资源管理器'; Target = 'explorer.exe' },
    @{ Name = 'PowerShell';     Target = 'powershell.exe' },
    @{ Name = '任务管理器';     Target = 'taskmgr.exe' },
    @{ Name = '服务';           Target = 'services.msc' },
    @{ Name = '设备管理器';     Target = 'devmgmt.msc' },
    @{ Name = '磁盘管理';       Target = 'diskmgmt.msc' },
    @{ Name = '任务计划程序';   Target = 'taskschd.msc' },
    @{ Name = '本地用户和组';   Target = 'lusrmgr.msc' },
    @{ Name = '证书管理';       Target = 'certmgr.msc' },
    @{ Name = '防火墙高级安全'; Target = 'wf.msc' },
    @{ Name = '注册表编辑器';   Target = 'regedit.exe' },
    @{ Name = '事件查看器';     Target = 'eventvwr.msc' },
    @{ Name = '性能监视器';     Target = 'perfmon.exe' },
    @{ Name = 'Hyper-V 管理器'; Target = 'virtmgmt.msc' }
)

function Resolve-SystemToolPath {
    param([string]$Target)
    # 先找 System32；explorer.exe 这类其实在 Windows 根目录，所以再走一次 PATH 解析
    $p = Join-Path (Join-Path $env:windir 'System32') $Target
    if (Test-Path -LiteralPath $p) { return $p }
    # 打包应用（MSIX）的入口是每用户的执行别名，例如 wt.exe 在 WindowsApps 下，不在 PATH 里也能这样找到
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $alias = Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $Target)
            if (Test-Path -LiteralPath $alias) { return $alias }
        }
    } catch { }
    try {
        $c = Get-Command $Target -ErrorAction SilentlyContinue
        if ($c) { return [string]$c.Source }
    } catch { }
    return ''
}

function Start-SystemTool {
    param([string]$Target, [string]$Name, [string]$Hint = '')

    # UI 审计模式：只走一遍回调，不真的启动外部程序
    if ($script:AuditMode) { Append-GuiLog -Line ('[INFO] 审计模式：跳过启动 ' + $Name); return }

    # 点击先落一行日志：万一界面"点了没反应"，日志能立刻区分是"处理函数没被调用"还是"启动失败"。
    # 之前 Resolve-SystemToolPath 抛异常会让整个点击处理静默死掉，所以下面整段都包在 try 里。
    Append-GuiLog -Line ('[STEP] 点击工具: ' + $Name + '  (' + $Target + ')')

    $resolved = ''
    try {
        $resolved = [string](Resolve-SystemToolPath -Target $Target)
    } catch {
        Append-GuiLog -Line ('[ERROR] 解析 ' + $Target + ' 的路径出错: ' + $_.Exception.Message)
    }

    if (-not $resolved) {
        Append-GuiLog -Line ('[WARN] 本机没有 ' + $Target + '（' + $Name + '）')
        $tail = '这类图形工具需要先安装官方 App Compatibility FOD，' + [Environment]::NewLine +
                '可以在左侧「环境」页点“一键补全环境”。'
        if ($Hint) { $tail = $Hint }
        $msg = ('找不到 ' + $Target + '。' + [Environment]::NewLine + [Environment]::NewLine +
                $tail + [Environment]::NewLine + [Environment]::NewLine +
                '现在用命令提示符代替打开吗？')
        try {
            if ([System.Windows.Forms.MessageBox]::Show($msg, ('工具不可用 - ' + $Name), 'YesNo', 'Warning') -eq 'Yes') {
                Start-Process -FilePath (Join-Path (Join-Path $env:windir 'System32') 'cmd.exe') -WorkingDirectory $env:USERPROFILE | Out-Null
            }
        } catch { }
        return
    }

    Append-GuiLog -Line ('[INFO] 已解析到: ' + $resolved)
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
        try { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, ('启动失败 - ' + $Name), 'OK', 'Error') | Out-Null } catch { }
    }
}

$script:ToolCache     = @{}
$script:ToolCacheTime = [datetime]::MinValue

function Set-ToolButtonClick {
    # 给工具按钮挂点击处理。参数通过 $Button.Tag 传，**绝不能用 GetNewClosure()**：
    # GetNewClosure 会新建一个模块作用域，在里面看不到本脚本定义的函数，调用 Start-SystemTool 时报
    # "The term 'Start-SystemTool' is not recognized..."。从 scm 启动的真实链路是
    # Start-GuiReadyApp.ps1 用 & 调用本脚本，本脚本的函数属于脚本作用域，
    # 闭包模块里解析不到 —— 实测（真实链路 + 模拟点击）就是这个报错/静默失败。
    # 普通 scriptblock 会保留创建时的作用域，因此能正常解析并调用本脚本的函数。
    param([System.Windows.Forms.Button]$Button, [string]$Target, [string]$Name, [string]$Hint)
    $Button.Tag = @{ Target = $Target; Name = $Name; Hint = $Hint }
    $Button.Add_Click({
        $info = $this.Tag
        try {
            Start-SystemTool -Target $info.Target -Name $info.Name -Hint $info.Hint
        } catch {
            $m = $_.Exception.Message
            try { Append-GuiLog -Line ('[ERROR] 工具点击处理异常（' + $info.Name + '）: ' + $m) } catch { }
            try { [System.Windows.Forms.MessageBox]::Show($m, ('工具出错 - ' + $info.Name), 'OK', 'Error') | Out-Null } catch { }
        }
    })
}

function Update-ToolButtons {
    param([switch]$Force)
    # 解析工具的路径要查 System32 + WindowsApps + PATH，缺的还会走一遍 PATH 搜索。
    # 同一 TTL 内复用结果，切页不再重复解析。
    $useCache = (-not $Force -and $script:ToolCacheTime -ne [datetime]::MinValue -and
                 ((Get-Date) - $script:ToolCacheTime).TotalSeconds -lt $script:EnvCacheTtlSec)
    $miss = New-Object System.Collections.ArrayList
    foreach ($tb in $script:ToolButtons) {
        # 单个工具解析失败不能让整页按钮都停摆（之前点击无反应的排查点之一）
        $r = ''
        try {
            if ($useCache -and $script:ToolCache.ContainsKey($tb.Target)) { $r = [string]$script:ToolCache[$tb.Target] }
            else {
                $r = [string](Resolve-SystemToolPath -Target $tb.Target)
                $script:ToolCache[$tb.Target] = $r
            }
        } catch {
            $r = ''
            $tb.Button.Enabled = $true      # 解析出错时保持可点，点了会给出明确提示
            $tb.Button.Text    = $tb.Name
            Append-GuiLog -Line ('[WARN] 解析 ' + $tb.Target + ' 出错: ' + $_.Exception.Message)
            continue
        }
        if ($r) {
            $tb.Button.Enabled   = $true
            $tb.Button.ForeColor = $Pal.Text
            $tb.Button.Text      = $tb.Name
            $tb.Missing          = $false
        } else {
            # 缺失的**保持可点**：点下去会弹出“缺什么、去哪补、要不要用命令提示符代替”。
            # 之前这里设成灰显不可点，用户看到的就是“按钮点了没反应”。
            $tb.Button.Enabled   = $true
            $tb.Button.ForeColor = $Pal.Hint
            $tb.Button.Text      = $tb.Name + '（缺失）'
            $tb.Missing          = $true
            [void]$miss.Add($tb.Name)
        }
    }
    if (-not $useCache) { $script:ToolCacheTime = Get-Date }
    if ($miss.Count -gt 0) {
        Append-GuiLog -Line ('[INFO] 工具页: 共 {0} 个，可用 {1} 个，缺失 {2} 个（{3}）' -f `
            $script:ToolButtons.Count, ($script:ToolButtons.Count - $miss.Count), $miss.Count, (($miss | Select-Object -First 6) -join '、'))
    } else {
        Append-GuiLog -Line ('[INFO] 工具页: 共 {0} 个，全部可用' -f $script:ToolButtons.Count)
    }
}

function Get-WacInstalledRunning {
    # 只判断“装了 WAC 且服务在运行”。
    # 缓存没就绪时直接返回 false（不去查）—— 真正的 WAC 查询由后台探测负责，
    # 界面线程一次同步查询要 0.25~1 秒，不值得卡在这里。探测回来后会重新判断一次。
    if ($script:EnvCacheData -and $script:EnvCacheData.Wac -and
        ((Get-Date) - $script:EnvCacheTime).TotalSeconds -lt $script:EnvCacheTtlSec) {
        $w = $script:EnvCacheData.Wac
        return ([bool]$w.Installed -and ($w.ServiceState -eq 'Running'))
    }
    return $false
}

function Get-WacToggleText {
    return ('Windows Admin Center 里也有（{0}）{1}' -f @($script:ToolGroupsWac).Count, $(if ($script:WacToolsExpanded) { '▼' } else { '▶' }))
}

function Toggle-WacToolGroup {
    if ($script:WacToolsSuppressed) { return }
    $script:WacToolsExpanded = (-not $script:WacToolsExpanded)
    $script:PnlWacTools.Visible = $script:WacToolsExpanded
    $script:BtnWacToggle.Text   = Get-WacToggleText
    Update-PageLayout
}

function Update-WacToolGroup {
    # 没装 WAC：整组默认收起（点标题展开）
    # 装了 WAC 且服务在运行：整组连标题一起隐藏（那些工具直接在 WAC 里用即可）
    $installed = Get-WacInstalledRunning
    $script:WacToolsSuppressed = $installed
    if ($installed) {
        $script:WacToolsExpanded    = $false
        $script:BtnWacToggle.Visible = $false
        $script:PnlWacTools.Visible  = $false
    } else {
        $script:BtnWacToggle.Visible = $true
        $script:PnlWacTools.Visible  = $script:WacToolsExpanded
        $script:BtnWacToggle.Text    = Get-WacToggleText
    }
    try {
        $hintTool.Text = $(if ($installed) {
            '提示：本机已装 Windows Admin Center 并在运行 —— 服务、事件、磁盘、注册表这些管理工具在 WAC 里都有，工具页不再重复列出。标「（缺失）」＝本机没有（多数来自官方 FOD，可在«环境»页补全），点它会告诉你怎么补。'
        } else {
            '提示：标「（缺失）」＝本机没有，点它会说明怎么补；「Windows Admin Center 里也有」那组默认收起，想用本机工具点一下展开。多数工具来自官方 FOD（可在«环境»页补全）。'
        })
    } catch { }
    Update-PageLayout
}

$pageTool           = New-Object System.Windows.Forms.Panel
$pageTool.Dock      = 'Fill'
$pageTool.BackColor = $Pal.Bg
$pageTool.Padding   = New-Object System.Windows.Forms.Padding(0, 56, 0, 6)
$script:Pages['tool'] = $pageTool
$pnlContent.Controls.Add($pageTool)

$lblToolHead          = New-Label -Text '系统工具' -Size 14 -Style Bold
$lblToolHead.Location = New-Object System.Drawing.Point(2, 2)
$pageTool.Controls.Add($lblToolHead)

$lblToolDesc          = New-Label -Text 'Server Core 默认没有这些图形工具，装了官方 App Compatibility FOD 才会出现；标了「（缺失）」的表示当前机器上还没有 —— 点它可以直接开始补。' -Size 9.5 -Color SubText
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
        $hnt      = [string]$it.Hint
        Set-ToolButtonClick -Button $b -Target $target -Name $nm -Hint $hnt
        $row.Controls.Add($b)
        [void]$script:ToolButtons.Add([pscustomobject]@{ Button = $b; Target = $target; Name = $nm; Missing = $false })
    }
    $pnlTools.Controls.Add($row)
    [void]$script:ToolRows.Add([pscustomobject]@{ Row = $row; Count = @($g.Items).Count })
}

# 「Windows Admin Center 里也有」那一组：标题按钮 + 可折叠的按钮行
# 注意：标题按钮必须放在可折叠面板【外面】，否则一收起就再也点不开了
$script:WacToolsExpanded   = $false
$script:WacToolsSuppressed = $false

$script:BtnWacToggle = New-FlatButton -Text (Get-WacToggleText) -Width 250 -Height 30
$script:BtnWacToggle.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
$script:BtnWacToggle.Add_Click({ Toggle-WacToolGroup })
$pnlTools.Controls.Add($script:BtnWacToggle)

$script:PnlWacTools = New-Object System.Windows.Forms.FlowLayoutPanel
$script:PnlWacTools.FlowDirection = 'LeftToRight'
$script:PnlWacTools.WrapContents  = $true
$script:PnlWacTools.AutoSize      = $true
$script:PnlWacTools.AutoSizeMode  = 'GrowAndShrink'
# 宽度卡在 880（跟其它行同宽），高度按换行自动长
$script:PnlWacTools.MaximumSize   = New-Object System.Drawing.Size(880, 0)
$script:PnlWacTools.BackColor     = $Pal.Bg
$script:PnlWacTools.Margin        = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
$script:PnlWacTools.Visible       = $false          # 默认收起

foreach ($it in $script:ToolGroupsWac) {
    $b = New-FlatButton -Text $it.Name -Width 132 -Height 34
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 4)
    $target   = $it.Target
    $nm       = $it.Name
    $hnt      = [string]$it.Hint
    Set-ToolButtonClick -Button $b -Target $target -Name $nm -Hint $hnt
    $script:PnlWacTools.Controls.Add($b)
    [void]$script:ToolButtons.Add([pscustomobject]@{ Button = $b; Target = $target; Name = $nm; Missing = $false })
}
$pnlTools.Controls.Add($script:PnlWacTools)
[void]$script:ToolRows.Add([pscustomobject]@{ Row = $script:PnlWacTools; Count = @($script:ToolGroupsWac).Count })

$hintTool = New-HintBar -Text '提示：标「（缺失）」＝本机没有，点它会说明怎么补。多数工具来自官方 FOD（可在«环境»页补全）；「美化终端」需要先在«更多 → 终端美化»里装；个别管理单元（服务、证书）Server Core 不提供，请用命令行替代。' -Kind Blue -Width 900
$hintTool.Dock = 'Bottom'
$hintTool.Height = 30
$pageTool.Controls.Add($hintTool)

# ============================ 更多页 ============================

$pageMore           = New-Object System.Windows.Forms.Panel
$pageMore.Dock      = 'Fill'
$pageMore.BackColor = $Pal.Bg
$script:Pages['more'] = $pageMore
$pnlContent.Controls.Add($pageMore)

$lblMoreHead          = New-Label -Text '更多功能' -Size 14 -Style Bold
$lblMoreHead.Location = New-Object System.Drawing.Point(2, 2)
$pageMore.Controls.Add($lblMoreHead)

$lblMoreDesc          = New-Label -Text '完整能力都在这里（探测/诊断/补给/会话/档案）。日常只用「环境」和「软件」两页就够。' -Size 9.5 -Color SubText
$lblMoreDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageMore.Controls.Add($lblMoreDesc)

$tree           = New-Object System.Windows.Forms.TreeView
$tree.Location  = New-Object System.Drawing.Point(0, 56)
$tree.Size      = New-Object System.Drawing.Size(268, 296)
$tree.Anchor    = 'Top,Left,Bottom'
$tree.BorderStyle = 'None'         # 同上：系统边框在深色主题里是一条浅灰线
$tree.HideSelection = $false
$tree.ItemHeight = 24
$tree.ShowLines = $false
$tree.ShowRootLines = $false
$tree.FullRowSelect = $true
$tree.Font      = New-Font -Size 9.5
$tree.BackColor = $Pal.Card
$tree.ForeColor = $Pal.Text
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
$pnlParams.BackColor = $Pal.Bg
$pnlMoreRight.Controls.Add($pnlParams)

$btnRun = New-FlatButton -Text '运行' -Width 110 -Height 36 -Kind Primary
$btnRun.Location = New-Object System.Drawing.Point(14, 216)
$btnRun.Anchor   = 'Bottom,Left'
$pnlMoreRight.Controls.Add($btnRun)

$btnDry = New-FlatButton -Text '仅预览' -Width 100 -Height 36
$btnDry.Location = New-Object System.Drawing.Point(132, 216)
$btnDry.Anchor   = 'Bottom,Left'
$pnlMoreRight.Controls.Add($btnDry)

# ============================ 应用商店页 ============================
# 「应用商店 2.0」的第一步：Chocolatey 主线（搜索 / 安装 / 卸载），Scoop 只做安装与卸载，
# npm / pip 先只做检测。能力在 lib\GuiReady.Package.ps1，规范见 想法.md 第三节、第四节。
#
# 一切慢查询都在子进程里做（choco search 是网络调用，几秒起步），页面只负责显示：
# 走的还是「环境卡片」那套套路 —— 子进程写 JSON → 定时器轮询 → 回填界面。

$pageStore              = New-Object System.Windows.Forms.Panel
$pageStore.Dock         = 'Fill'
$pageStore.BackColor    = $Pal.Bg
$script:Pages['store']  = $pageStore
$pnlContent.Controls.Add($pageStore)

$lblStoreHead          = New-Label -Text '应用商店' -Size 14 -Style Bold
$lblStoreHead.Location = New-Object System.Drawing.Point(2, 2)
$pageStore.Controls.Add($lblStoreHead)

$lblStoreDesc          = New-Label -Text '从包管理器装工具。主线是 Chocolatey（搜索 / 安装 / 卸载）；Scoop 可安装与卸载（搜索未接入）；npm / pip 先只做检测。' -Size 9.5 -Color SubText -Width 880
$lblStoreDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageStore.Controls.Add($lblStoreDesc)

# ---- 源状态行（胶囊由 Update-StoreSourceRow 动态生成）----
$pnlStoreSrc           = New-Object System.Windows.Forms.Panel
$pnlStoreSrc.Location  = New-Object System.Drawing.Point(0, 56)
$pnlStoreSrc.Size      = New-Object System.Drawing.Size(900, 34)
$pnlStoreSrc.Anchor    = 'Top,Left,Right'
$pnlStoreSrc.BackColor = $Pal.Bg
$pageStore.Controls.Add($pnlStoreSrc)

$lblStoreSrcHint          = New-Label -Text '正在检测本机的包管理器…' -Size 9.5 -Color Hint
$lblStoreSrcHint.Location = New-Object System.Drawing.Point(4, 8)
$pnlStoreSrc.Controls.Add($lblStoreSrcHint)

# ---- 搜索行 ----
$pnlStoreSearch           = New-Object System.Windows.Forms.Panel
$pnlStoreSearch.Location  = New-Object System.Drawing.Point(0, 98)
$pnlStoreSearch.Size      = New-Object System.Drawing.Size(900, 40)
$pnlStoreSearch.Anchor    = 'Top,Left,Right'
$pnlStoreSearch.BackColor = $Pal.Bg
$pageStore.Controls.Add($pnlStoreSearch)

$txtStoreQuery = New-TextBox -Width 340 -Height 34
$txtStoreQuery.Panel.Location = New-Object System.Drawing.Point(0, 2)
$pnlStoreSearch.Controls.Add($txtStoreQuery.Panel)

$cmbStoreSrc               = New-Object System.Windows.Forms.ComboBox
$cmbStoreSrc.DropDownStyle = 'DropDownList'
$cmbStoreSrc.Location      = New-Object System.Drawing.Point(352, 9)
$cmbStoreSrc.Size          = New-Object System.Drawing.Size(150, 24)
$cmbStoreSrc.Font          = New-Font -Size 9.5
# 深色主题：ComboBox/ListView/TreeView 是系统原生控件，不显式给色就是白的
$cmbStoreSrc.BackColor     = $Pal.Sunken
$cmbStoreSrc.ForeColor     = $Pal.Text
$pnlStoreSearch.Controls.Add($cmbStoreSrc)

$btnStoreSearch          = New-FlatButton -Text '搜索' -Kind Primary -Width 96 -Height 34
$btnStoreSearch.Location = New-Object System.Drawing.Point(512, 2)
$pnlStoreSearch.Controls.Add($btnStoreSearch)

$pillStoreState          = New-Pill -Text '就绪' -Kind 'Neutral'
$pillStoreState.Location = New-Object System.Drawing.Point(618, 8)
$pnlStoreSearch.Controls.Add($pillStoreState)

$hintStore = New-HintBar -Text '目标场景是刚装好的 Server Core（机上什么都没有），所以本机没有包管理器时**工具会自动先装 Chocolatey**（点搜索就会触发，装完接着搜）。所有安装动作都会写进下方日志；不确定就先按「仅预览」看要执行什么命令。' -Kind 'Blue' -Width 900
$hintStore.Location = New-Object System.Drawing.Point(0, 144)
$pageStore.Controls.Add($hintStore)

$barStore           = New-ProgressBar -Width 420 -Height 6 -Indeterminate
$barStore.Location  = New-Object System.Drawing.Point(0, 182)
$barStore.Visible   = $false
$pageStore.Controls.Add($barStore)

$pnlStoreResults             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlStoreResults.Location    = New-Object System.Drawing.Point(0, 196)
$pnlStoreResults.Size        = New-Object System.Drawing.Size(896, 248)
$pnlStoreResults.Anchor      = 'Top,Left,Right,Bottom'
$pnlStoreResults.FlowDirection = 'TopDown'
$pnlStoreResults.WrapContents = $false
$pnlStoreResults.AutoScroll  = $true
$pnlStoreResults.BackColor   = $Pal.Bg
$pageStore.Controls.Add($pnlStoreResults)

$lblStoreEmpty          = New-Label -Text '输入关键词后点「搜索」。' -Size 9.5 -Color Hint
$lblStoreEmpty.Location = New-Object System.Drawing.Point(4, 6)
$pnlStoreResults.Controls.Add($lblStoreEmpty)

# ---- 商店页状态 ----
$script:StoreSources     = @()      # 包管理器检测结果
$script:StorePills       = @()      # 源状态行的胶囊（重建时一并释放）
$script:StoreLocal       = @()      # 本机已装的包名（用来标「已安装」）
$script:StoreRows        = @()      # 结果行
$script:StoreDetailRows  = @()      # 工具详情的行（与结果行共用同一块区域）
# 自动装包管理器之后要接着做的那次搜索（Stage: '' → after-action → after-status → ''）
$script:StoreAutoSearch  = @{ Query = ''; Stage = '' }
$script:StoreLastItems   = @()      # 上一次的搜索结果（本地列表回来后要重绘）
$script:StoreComboMap    = @()      # 搜索源下拉的 索引 -> 源 id
$script:StoreTask        = ''       # '' | status | local | search | watch
$script:StoreProc        = $null
$script:StoreRunDir      = ''
$script:StoreOutFile     = ''
$script:StoreSearchSrc   = 'choco'
$script:StoreRunner      = Join-Path $guiDir 'Run-GuiReadyStore.ps1'
# 与 pkg-install / pkg-uninstall 里 Source 下拉的 1 基索引保持一致
$script:StoreSourceIndex = @{ choco = 1; scoop = 2 }

$script:StoreTimer = New-Object System.Windows.Forms.Timer
$script:StoreTimer.Interval = 250
$script:StoreTimer.Add_Tick({ Update-StoreTick })

function Get-StoreSourceName {
    param([string]$Id)
    if ($Id -eq 'choco') { return 'Chocolatey' }
    if ($Id -eq 'scoop') { return 'Scoop' }
    if ($Id -eq 'npm')   { return 'npm' }
    if ($Id -eq 'pip')   { return 'pip' }
    return $Id
}

function Import-GuiJsonFile {
    # 读子进程写出来的 JSON（写入是 tmp + Move，所以不会读到半个文件）
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Set-StoreBusy {
    # 状态胶囊 + 进度条；传空字符串表示回到空闲
    param([string]$Text, [string]$Kind = 'Info')
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) {
            $barStore.Visible = $false
            Set-Pill -Pill $pillStoreState -Text '就绪' -Kind 'Neutral'
            return
        }
        Set-Pill -Pill $pillStoreState -Text $Text -Kind $Kind
        $barStore.Visible = $true
        $barStore.Invalidate()
    } catch { }
}

function Stop-StoreTask {
    $script:StoreTask = ''
    $script:StoreProc = $null
    try { $script:StoreTimer.Stop() } catch { }
    # 查询临时目录用完就删（result.json / args.json 里的搜索词不需要留在服务器上）
    if ($script:StoreRunDir) { try { Remove-Item -LiteralPath $script:StoreRunDir -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
    $script:StoreRunDir = ''
    Set-StoreBusy ''
}

function Start-StoreQuery {
    # 起一个子进程去查（status / local / search），页面只等结果
    param([string]$Mode, [string]$Source = 'choco', [string]$Query = '')

    if ($script:StoreTask) {
        Append-GuiLog -Line '[INFO] 商店还有一个查询在跑，等它结束再试。'
        return
    }
    if (-not (Test-Path -LiteralPath $script:StoreRunner)) {
        Append-GuiLog -Line '[ERROR] 找不到 gui\Run-GuiReadyStore.ps1。'
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $env:TEMP ('gui-store-{0}-{1}' -f $Mode, $stamp)
    try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    $script:StoreOutFile   = Join-Path $dir 'result.json'
    $script:StoreRunDir    = $dir
    $script:StoreSearchSrc = $Source

    try {
        # 搜索词走 JSON 文件传参：命令行要靠手工拼引号，而值可能来自外部
        # （搜索词是用户输入的，包名是远程 feed 的）—— 拼引号就能被注入额外参数。
        $af = Join-Path $dir 'args.json'
        [System.IO.File]::WriteAllText($af, (@{ Source = $Source; Query = $Query } | ConvertTo-Json -Compress),
                                       (New-Object System.Text.UTF8Encoding($false)))
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                     '-File', ('"' + $script:StoreRunner + '"'),
                     '-Mode', $Mode,
                     '-OutFile', ('"' + $script:StoreOutFile + '"'),
                     '-ArgsFile', ('"' + $af + '"'))
        $script:StoreProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden
    } catch {
        Append-GuiLog -Line ('[ERROR] 商店查询启动失败: ' + $_.Exception.Message)
        $script:StoreTask = ''
        return
    }

    $script:StoreTask = $Mode
    switch ($Mode) {
        'search' { Set-StoreBusy -Text ('正在搜索 ' + $Query + ' …') -Kind 'Info' }
        'local'  { Set-StoreBusy -Text '正在读取已装清单…' -Kind 'Info' }
        default  { Set-StoreBusy -Text '正在检测包管理器…' -Kind 'Info' }
    }
    $script:StoreTimer.Start()
}

function Clear-StoreRows {
    foreach ($r in $script:StoreRows) {
        try { $pnlStoreResults.Controls.Remove($r.Panel); $r.Panel.Dispose() } catch { }
    }
    $script:StoreRows = @()
}

function Get-StoreRowWidth {
    $w = $pnlStoreResults.ClientSize.Width
    if ($w -le 0) { $w = $pnlStoreResults.Width }
    return [Math]::Max(420, ($w - 26))
}

function Add-StoreRow {
    param($Item)

    $rowW = Get-StoreRowWidth
    $row  = New-Card -Width $rowW -Height 56 -Radius 10
    $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

    $lbName = New-Label -Text ([string]$Item.Id) -Size 10 -Style Bold -Width ($rowW - 220)
    $lbName.Location = New-Object System.Drawing.Point(14, 9)
    $row.Controls.Add($lbName)

    $ver  = [string]$Item.Version
    $meta = ('{0}   ·   来自 {1}' -f $(if ($ver) { 'v' + $ver } else { '版本未知' }), (Get-StoreSourceName ([string]$Item.Source)))
    $lbMeta = New-Label -Text $meta -Size 8.5 -Color Hint -Width ($rowW - 220)
    $lbMeta.Location = New-Object System.Drawing.Point(14, 31)
    $row.Controls.Add($lbMeta)

    $installed = ($script:StoreLocal -contains [string]$Item.Id)
    $pill = $null
    if ($installed) {
        $pill = New-Pill -Text '已安装' -Kind 'Success'
        $row.Controls.Add($pill)
    }

    $btnIns = New-FlatButton -Text '安装' -Kind Primary -Width 80 -Height 30
    $btnIns.Tag = @{ Pkg = [string]$Item.Id; Src = [string]$Item.Source }
    $btnIns.Add_Click({
        Start-StoreAction -Id 'pkg-install' -Params @{
            Source  = $script:StoreSourceIndex[[string]$this.Tag.Src]
            Package = [string]$this.Tag.Pkg
        }
    })
    $row.Controls.Add($btnIns)

    $btnUn = New-FlatButton -Text '卸载' -Width 80 -Height 30
    $btnUn.Enabled = $installed
    $btnUn.Tag = @{ Pkg = [string]$Item.Id; Src = [string]$Item.Source }
    $btnUn.Add_Click({
        Start-StoreAction -Id 'pkg-uninstall' -Params @{
            Source  = $script:StoreSourceIndex[[string]$this.Tag.Src]
            Package = [string]$this.Tag.Pkg
        }
    })
    $row.Controls.Add($btnUn)

    # 「详情」：在同一个结果区里换成详情视图（choco info 的输出，见 Get-GuiReadyPackageInfo）
    $btnInfo = New-FlatButton -Text '详情' -Width 64 -Height 30
    $btnInfo.Tag = @{ Pkg = [string]$Item.Id; Src = [string]$Item.Source }
    $btnInfo.Add_Click({
        Show-StoreDetail -Package ([string]$this.Tag.Pkg) -Source ([string]$this.Tag.Src)
    })
    $row.Controls.Add($btnInfo)

    $pnlStoreResults.Controls.Add($row)
    $script:StoreRows += [pscustomobject]@{ Panel = $row; Name = $lbName; Meta = $lbMeta; Install = $btnIns; Uninstall = $btnUn; Info = $btnInfo; Pill = $pill }
}

function Update-StoreRowLayout {
    # 结果行的宽度和按钮都右对齐，窗口一改就得跟着挪
    $rowW = Get-StoreRowWidth
    foreach ($r in $script:StoreRows) {
        try {
            $r.Panel.Width = $rowW
            $r.Name.Width  = $rowW - 300
            $r.Meta.Width  = $rowW - 300
            $r.Install.Location   = New-Object System.Drawing.Point(($rowW - 256), 13)
            $r.Uninstall.Location = New-Object System.Drawing.Point(($rowW - 168), 13)
            if ($r.Info) { $r.Info.Location = New-Object System.Drawing.Point(($rowW - 96), 13) }
            if ($r.Pill) { $r.Pill.Location = New-Object System.Drawing.Point(($rowW - 266 - $r.Pill.Width), 17) }
            Set-Rounded -Control $r.Panel -Radius 10
        } catch { }
    }
    # 详情视图的行也要跟着排
    Update-UiRowLayout -Rows @($script:StoreDetailRows) -RowWidth $rowW
}

# ---- 工具详情 ----
# 数据来自 choco info（解析规则见 lib\GuiReady.Package.ps1 的 Get-GuiReadyPackageInfo），
# 慢查询照旧走子进程；视图与结果列表共用同一块区域，靠「返回列表」切回。

function Clear-StoreDetail {
    foreach ($r in @($script:StoreDetailRows)) {
        try { $pnlStoreResults.Controls.Remove($r.Panel); $r.Panel.Dispose() } catch { }
    }
    $script:StoreDetailRows = @()
}

function Render-StoreDetail {
    param($Obj)
    if ($null -eq $Obj) { return }
    Clear-StoreRows
    Clear-StoreDetail

    $it = $null
    if ($Obj.Items) { $it = @($Obj.Items)[0] }
    $lblStoreEmpty.Visible = $false

    if (-not $it) {
        $lblStoreEmpty.Visible = $true
        $lblStoreEmpty.Text = '没有拿到详情，看下方日志。'
        return
    }

    $pk = [string]$Obj.Package
    $src = [string]$Obj.Source
    $srcIdx = 1
    if ($script:StoreSourceIndex.ContainsKey($src)) { $srcIdx = [int]$script:StoreSourceIndex[$src] }

    # 顶部：返回 + 安装/卸载
    $script:StoreDetailRows += (Add-UiRow -Container $pnlStoreResults -Title ('{0}  {1}' -f $(if ($it.Title) { [string]$it.Title } else { $pk }), $(if ($it.Version) { 'v' + [string]$it.Version } else { '' })) `
        -Meta ('来源 {0}   ·   {1}' -f (Get-StoreSourceName $src), $(if ($it.Published) { '发布 ' + [string]$it.Published } else { '' })) `
        -PillText $(if ($script:StoreLocal -contains $pk) { '已安装' } else { '未安装' }) -PillKind $(if ($script:StoreLocal -contains $pk) { 'Success' } else { 'Neutral' }) `
        -Height 58 -BtnText '返回列表' -BtnTag @{ Act = 'back' } `
        -BtnClick { Show-StoreResult -Items $script:StoreLastItems })

    if ($it.Error) {
        $script:StoreDetailRows += (Add-UiRow -Container $pnlStoreResults -Title '详情查询失败' -Meta ([string]$it.Error) -PillText '失败' -PillKind 'Danger' -Height 50)
        Update-PageLayout
        return
    }

    $fields = @(
        @{ T = '摘要'; M = [string]$it.Summary }
        @{ T = '标签'; M = [string]$it.Tags }
        @{ T = '官网'; M = [string]$it.Site }
        @{ T = '许可证'; M = [string]$it.License }
        @{ T = '包页面'; M = [string]$it.Url }
        @{ T = '下载量'; M = [string]$it.Downloads }
    )
    foreach ($f in $fields) {
        if ([string]::IsNullOrWhiteSpace($f.M)) { continue }
        $script:StoreDetailRows += (Add-UiRow -Container $pnlStoreResults -Title $f.T -Meta $f.M -Height 46 -MarginBottom 4)
    }

    # 描述：可能很长（7zip 那条有几十行），截断并注明
    $desc = [string]$it.Description
    if (-not [string]::IsNullOrWhiteSpace($desc)) {
        $lines = @($desc -split "`n")
        $shown = @($lines | Select-Object -First 12)
        $body = ($shown -join '   ')
        $note = $(if ($lines.Count -gt 12) { ('（共 {0} 行，这里显示前 12 行 —— 完整内容在下方日志里）' -f $lines.Count) } else { '' })
        $script:StoreDetailRows += (Add-UiRow -Container $pnlStoreResults -Title '描述' -Meta ($body + '   ' + $note) -Height 96 -MarginBottom 4)
    }

    $script:StoreDetailRows += (Add-UiRow -Container $pnlStoreResults -Title '将执行的命令' `
        -Meta ('{0} install {1} -y --no-progress' -f $(if ($src -eq 'scoop') { 'scoop' } else { 'choco' }), $pk) -PillText '预览' -PillKind 'Info' -Height 46)

    Update-PageLayout
}

$script:QStoreInfo = New-GuiQueryHost -Name 'store-info' -Runner (Join-Path $guiDir 'Run-GuiReadyStore.ps1') -TimeoutSec 90 `
    -OnResult { param($obj) Render-StoreDetail -Obj $obj } `
    -OnBusyStart { param($t) Set-StoreBusy -Text $t -Kind 'Info' } `
    -OnBusyEnd { }

function Show-StoreDetail {
    param([string]$Package, [string]$Source = 'choco')
    if ([string]::IsNullOrWhiteSpace($Package)) { return }
    # 包名来自远程 feed —— 只走 JSON 文件传参，绝不拼进命令行（见 Run-GuiReadyStore.ps1 的说明）
    Start-GuiQueryHost -Query $script:QStoreInfo -Task 'info' -BusyText ('读取 ' + $Package + ' 的详情…') `
        -ArgsJson @{ Source = $Source; Package = $Package } | Out-Null
}

function Show-StoreResult {
    param($Items)
    # 只保留「我们真的会装」的源 —— 免得出现一个点下去不知道跑什么命令的结果行
    $script:StoreLastItems = @($Items | Where-Object { $script:StoreSourceIndex.ContainsKey([string]$_.Source) })
    Clear-StoreRows
    Clear-StoreDetail      # 从详情视图切回列表时，把详情行也收掉
    $lblStoreEmpty.Visible = ($script:StoreLastItems.Count -eq 0)
    if ($script:StoreLastItems.Count -eq 0) {
        $lblStoreEmpty.Text = '没有结果。换个关键词，或者看下方日志里源返回了什么。'
        return
    }
    foreach ($i in $script:StoreLastItems) { Add-StoreRow -Item $i }
    Update-StoreRowLayout
}

function Update-StoreSourceCombo {
    # 下拉只列「能搜索」的源（目前只有 Chocolatey）。
    try {
        $cmbStoreSrc.Items.Clear()
        $script:StoreComboMap = @()
        foreach ($s in $script:StoreSources) {
            if ($s.CanSearch) {
                [void]$cmbStoreSrc.Items.Add([string]$s.Name)
                $script:StoreComboMap += [string]$s.Id
            }
        }
        if ($script:StoreComboMap.Count -gt 0) {
            $cmbStoreSrc.SelectedIndex = 0
        }
        # 关键：**一个可搜索的源都没有时也不能禁用搜索按钮**。
        # 刚装好的 Server Core 上就是这个状态（机上什么都没有），而"点搜索 → 问要不要现在
        # 装包管理器 → 装完自动接着搜"这条路正是给这种情况准备的（见 $btnStoreSearch.Add_Click）。
        # 一旦把按钮禁掉，那条路就被堵死了，用户看到的是"搜索按钮点不动、商店用不了"。
        $btnStoreSearch.Enabled = $true
        if ($script:StoreComboMap.Count -eq 0 -and $script:StoreSources.Count -gt 0) {
            Set-Pill -Pill $pillStoreState -Text '还没有包管理器，点搜索会先装' -Kind 'Warn'
        }
    } catch { }
}

function Update-StoreSourceRow {
    # 重建源状态行：[Chocolatey 2.2.2] [Scoop 未安装] … [重新检测] [安装 Chocolatey]
    foreach ($c in @($pnlStoreSrc.Controls)) {
        if ($c -ne $lblStoreSrcHint) {
            try { $pnlStoreSrc.Controls.Remove($c); $c.Dispose() } catch { }
        }
    }
    $script:StorePills = @()

    if ($script:StoreSources.Count -eq 0) {
        $lblStoreSrcHint.Visible = $true
        $lblStoreSrcHint.Text    = '正在检测本机的包管理器…'
        return
    }
    $lblStoreSrcHint.Visible = $false

    $x = 0
    foreach ($s in $script:StoreSources) {
        # 语义：可用且能搜索=绿；已装但只支持部分操作=黄；没装=灰
        $kind = 'Neutral'
        $text = ('{0} 未安装' -f $s.Name)
        if ($s.Installed) {
            $v = [string]$s.Version
            $text = $(if ($v) { ('{0} {1}' -f $s.Name, $v) } else { [string]$s.Name })
            if ($s.CanSearch) { $kind = 'Success' } elseif ($s.CanInstall) { $kind = 'Warn' }
        }
        $p = New-Pill -Text $text -Kind $kind
        $p.Location = New-Object System.Drawing.Point($x, 6)
        $pnlStoreSrc.Controls.Add($p)
        $script:StorePills += $p
        $x += $p.Width + 8
    }

    $btnRecheck = New-FlatButton -Text '重新检测' -Width 92 -Height 30
    $btnRecheck.Location = New-Object System.Drawing.Point($x, 2)
    $btnRecheck.Add_Click({ Start-StoreQuery -Mode 'status' })
    $pnlStoreSrc.Controls.Add($btnRecheck)
    $x += 100

    $choco = @($script:StoreSources | Where-Object { $_.Id -eq 'choco' })
    if ($choco.Count -gt 0 -and -not $choco[0].Installed) {
        # 目标场景是刚装好的 Server Core（机上什么都没有），所以这里默认就是主按钮：
        # 不装包管理器就没法装任何软件，工具自己把它装上（点搜索时也会自动触发）。
        $btnGet = New-FlatButton -Text '自动安装 Chocolatey' -Width 170 -Height 30 -Kind Primary
        $btnGet.Location = New-Object System.Drawing.Point($x, 2)
        $btnGet.Add_Click({ Start-StoreAction -Id 'pkg-install-choco' -Params @{} })
        $pnlStoreSrc.Controls.Add($btnGet)
    }

    Update-StoreSourceCombo
}

function Update-StoreTick {
    # 一次 tick 只做一件事：等查询结果，或者盯已启动的动作什么时候跑完
    if ($script:StoreTask -eq 'watch') {
        $running = $false
        try {
            if ($script:Proc) {
                $script:Proc.Refresh()
                $running = -not $script:Proc.HasExited
            }
        } catch { }
        if ($running) {
            try { $barStore.Invalidate() } catch { }
            return
        }
        Stop-StoreTask
        Append-GuiLog -Line '[INFO] 商店：动作已结束，可以重新搜索刷新列表。'
        # 装/卸之后本机的已装清单变了，顺手刷一次，把「已安装」标记更新过来
        $choco = @($script:StoreSources | Where-Object { $_.Id -eq 'choco' -and $_.Installed })
        if ($choco.Count -gt 0) { Start-StoreQuery -Mode 'local' -Source 'choco' }
        # 自动装包管理器之后：重查源状态（查完由 status 分支接着把搜索做完）
        if ($script:StoreAutoSearch.Stage -eq 'after-action') {
            $script:StoreAutoSearch.Stage = 'after-status'
            Start-StoreQuery -Mode 'status'
        }
        return
    }

    if (-not $script:StoreTask) {
        try { $script:StoreTimer.Stop() } catch { }
        return
    }

    # 超时保护：查询卡住时不能让界面永远停在「正在…」
    try {
        if ($script:StoreProc) {
            $script:StoreProc.Refresh()
            if (((Get-Date) - $script:StoreProc.StartTime).TotalSeconds -gt 120 -and -not (Test-Path -LiteralPath $script:StoreOutFile)) {
                Append-GuiLog -Line '[WARN] 商店查询超过 120 秒没有结果，已放弃。'
                Stop-StoreTask
                return
            }
        }
        $barStore.Invalidate()
    } catch { }

    $obj = Import-GuiJsonFile -Path $script:StoreOutFile
    if (-not $obj) { return }

    $task = $script:StoreTask
    $err  = [string]$obj.Error
    $items = @($obj.Items)
    Stop-StoreTask
    if ($err) { Append-GuiLog -Line ('[WARN] 商店查询返回错误: ' + $err) }

    switch ($task) {
        'status' {
            $script:StoreSources = $items
            Update-StoreSourceRow
            $choco = @($items | Where-Object { $_.Id -eq 'choco' -and $_.Installed })
            if ($choco.Count -gt 0) { Start-StoreQuery -Mode 'local' -Source 'choco' }
            # 「工具自己装包管理器」：装完 choco 后重新检测了源，把用户原来那次搜索接着做完
            if ($script:StoreAutoSearch.Stage -eq 'after-status') {
                $script:StoreAutoSearch.Stage = ''
                $q = [string]$script:StoreAutoSearch.Query
                if ($q -and $script:StoreComboMap.Count -gt 0) {
                    $sid = [string]$script:StoreComboMap[0]
                    Append-GuiLog -Line ('[INFO] 包管理器已就绪，继续刚才的搜索: ' + $q)
                    Start-StoreQuery -Mode 'search' -Source $sid -Query $q
                }
            }
        }
        'local' {
            $script:StoreLocal = @($items | ForEach-Object { [string]$_.Id })
            if ($script:StoreLastItems.Count -gt 0) { Show-StoreResult -Items $script:StoreLastItems }
        }
        'search' { Show-StoreResult -Items $items }
    }
}

function Start-StoreAction {
    # 装/卸走既有的动作机制（子进程 + 全局日志面板），参数直接写进「更多」页那张表单，
    # 这样用户点开「更多 → 应用商店」能看到刚刚用的到底是什么参数。
    param([string]$Id, [hashtable]$Params = @{})

    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请先等它结束。', '提示', 'OK', 'Information') | Out-Null
        return
    }

    # 装/卸软件包都得先有包管理器：没有就问一句（用户选择下载 → 之后自动安装并继续）。
    # 选“是”之后由动作链自己把包管理器装好再装你要的包，用户不用额外操作。
    if ($Id -in @('pkg-install', 'pkg-uninstall', 'pkg-info') -and -not (Resolve-GuiReadyPackageExe -Id 'choco')) {
        $name = [string]$Params['Package']
        if (-not (Confirm-GuiPackageManager -Why ('你刚要操作的软件包是「' + $name + '」，得先有包管理器。'))) {
            Append-GuiLog -Line '[INFO] 你取消了自动安装包管理器，本次操作没有执行。'
            return
        }
    }

    $a = @($script:Actions | Where-Object { $_.Id -eq $Id })
    if ($a.Count -eq 0) { Append-GuiLog -Line ('[ERROR] 未找到功能: ' + $Id); return }

    Select-GuiAction -Action $a[0]
    Set-ParamValues -Values $Params
    Start-GuiAction -DryRun $false

    if ($script:Proc) {
        $script:StoreTask = 'watch'
        Set-StoreBusy -Text '执行中（看下方日志）' -Kind 'Info'
        $script:StoreTimer.Start()
    }
}

function Show-StorePage {
    # 进页面：没有源数据就后台检测一次；有数据就直接显示，不重复探测
    if ($SkipPageHooks) { return }
    if ($script:StoreSources.Count -eq 0 -and -not $script:StoreTask) {
        Start-StoreQuery -Mode 'status'
    } else {
        Update-StoreSourceRow
    }
}

function Confirm-GuiPackageManager {
    # 「用户选择下载 → 之后全自动安装」。
    # 凡是需要包管理器的地方（搜索、安装软件包、装 dsh 依赖）都先问一句：
    # 用户点「是」之后，下载、安装、复核、以及原来那步操作的续跑全部自动完成，他不用再管。
    # 返回 $true 表示"现在可以用包管理器了"。
    param([string]$Why = '')
    if (Resolve-GuiReadyPackageExe -Id 'choco') { return $true }

    $msg = "本机还没有包管理器（Chocolatey）。`r`n`r`n" +
           $(if ($Why) { $Why + "`r`n`r`n" } else { '' }) +
           "Chocolatey 是 Server Core 上官方支持的软件源，本工具用它来下载并安装你要的软件。`r`n`r`n" +
           "现在下载并自动安装吗？（需要联网 + 管理员权限，通常 1-2 分钟；装完会自动继续刚才的操作）"
    try {
        $r = [System.Windows.Forms.MessageBox]::Show($form, $msg, '需要包管理器', 'YesNo', 'Question')
        return ($r -eq 'Yes')
    } catch {
        return $false
    }
}

$btnStoreSearch.Add_Click({
    $q = [string]$txtStoreQuery.Box.Text
    if ([string]::IsNullOrWhiteSpace($q)) { Set-Pill -Pill $pillStoreState -Text '先输入关键词' -Kind 'Warn'; return }
    if ($cmbStoreSrc.SelectedIndex -lt 0 -or $script:StoreComboMap.Count -eq 0) {
        # 一个源都没有 —— 刚装好的 Server Core 上就是这情况。
        # 先让用户**自己选择**是否下载包管理器；选了之后下载+安装+继续搜索全自动。
        if (-not (Resolve-GuiReadyPackageExe -Id 'choco')) {
            if (-not (Confirm-GuiPackageManager -Why '你要搜索软件包，得先有包管理器。')) {
                Set-Pill -Pill $pillStoreState -Text '已取消（可随时点上方「自动安装 Chocolatey」）' -Kind 'Warn'
                Append-GuiLog -Line '[INFO] 你取消了自动安装包管理器，这次搜索没有执行。'
                return
            }
            Set-Pill -Pill $pillStoreState -Text '正在自动安装包管理器…' -Kind 'Info'
            Append-GuiLog -Line '[STEP] 按你的选择：下载并自动安装 Chocolatey，装完会接着搜索。'
            $script:StoreAutoSearch.Query = $q
            $script:StoreAutoSearch.Stage = 'after-action'
            Start-StoreAction -Id 'pkg-install-choco' -Params @{}
            return
        }
        Set-Pill -Pill $pillStoreState -Text '源状态还在检测，稍等一下' -Kind 'Warn'
        return
    }
    $sid = [string]$script:StoreComboMap[$cmbStoreSrc.SelectedIndex]
    Append-GuiLog -Line ('[INFO] 商店搜索: ' + $q)
    Start-StoreQuery -Mode 'search' -Source $sid -Query $q
})

$txtStoreQuery.Box.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $btnStoreSearch.PerformClick() }
})

# ============================ 角色与功能页 ============================
# 「角色与功能管理」（想法.md 第三节 P0）：图形化封装 Install-WindowsFeature / Uninstall-WindowsFeature。
#
# 两个前提决定了这页怎么写：
#   1. ServerManager 是 Server 系专有，客户端 Windows 上根本没有 —— 那种情况下页面要如实说明
#      并给出替代路径，而不是给一个空列表让人以为「本机没有任何功能」。
#   2. 角色列表读取要几秒、安装要几分钟，所以列表和安装都走子进程（和环境卡片、商店同一套路）。
# 按需功能（FOD）的安装逻辑在更多 → 补给里，这页只显示状态并指过去，不重复实现。

$pageRole              = New-Object System.Windows.Forms.Panel
$pageRole.Dock         = 'Fill'
$pageRole.BackColor    = $Pal.Bg
$script:Pages['role']  = $pageRole
$pnlContent.Controls.Add($pageRole)

$lblRoleHead          = New-Label -Text '角色与功能' -Size 14 -Style Bold
$lblRoleHead.Location = New-Object System.Drawing.Point(2, 2)
$pageRole.Controls.Add($lblRoleHead)

$lblRoleDesc          = New-Label -Text '图形化装 Windows Server 角色与功能（等价于 Install-WindowsFeature）。安装需要管理员；装完是否需要重启会写进下方日志。' -Size 9.5 -Color SubText -Width 880
$lblRoleDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageRole.Controls.Add($lblRoleDesc)

$pnlRoleStatus           = New-Object System.Windows.Forms.Panel
$pnlRoleStatus.Location  = New-Object System.Drawing.Point(0, 56)
$pnlRoleStatus.Size      = New-Object System.Drawing.Size(900, 34)
$pnlRoleStatus.Anchor    = 'Top,Left,Right'
$pnlRoleStatus.BackColor = $Pal.Bg
$pageRole.Controls.Add($pnlRoleStatus)

$lblRoleStatusHint          = New-Label -Text '正在探测本机能力…' -Size 9.5 -Color Hint
$lblRoleStatusHint.Location = New-Object System.Drawing.Point(4, 8)
$pnlRoleStatus.Controls.Add($lblRoleStatusHint)

$pnlRoleFilter           = New-Object System.Windows.Forms.Panel
$pnlRoleFilter.Location  = New-Object System.Drawing.Point(0, 98)
$pnlRoleFilter.Size      = New-Object System.Drawing.Size(900, 40)
$pnlRoleFilter.Anchor    = 'Top,Left,Right'
$pnlRoleFilter.BackColor = $Pal.Bg
$pageRole.Controls.Add($pnlRoleFilter)

$txtRoleQuery = New-TextBox -Width 300 -Height 34
$txtRoleQuery.Panel.Location = New-Object System.Drawing.Point(0, 2)
$pnlRoleFilter.Controls.Add($txtRoleQuery.Panel)

$cmbRoleFilter               = New-Object System.Windows.Forms.ComboBox
$cmbRoleFilter.DropDownStyle = 'DropDownList'
$cmbRoleFilter.Location      = New-Object System.Drawing.Point(312, 9)
$cmbRoleFilter.Size          = New-Object System.Drawing.Size(170, 24)
$cmbRoleFilter.Font          = New-Font -Size 9.5
$cmbRoleFilter.BackColor     = $Pal.Sunken
$cmbRoleFilter.ForeColor     = $Pal.Text
foreach ($o in @('全部', '仅已安装', '仅未安装', '仅角色（未装）')) { [void]$cmbRoleFilter.Items.Add($o) }
$cmbRoleFilter.SelectedIndex = 0
$pnlRoleFilter.Controls.Add($cmbRoleFilter)

$btnRoleFilter = New-FlatButton -Text '筛选' -Kind Primary -Width 84 -Height 34
$btnRoleFilter.Location = New-Object System.Drawing.Point(492, 2)
$pnlRoleFilter.Controls.Add($btnRoleFilter)

$pillRoleCount          = New-Pill -Text '—' -Kind 'Neutral'
$pillRoleCount.Location = New-Object System.Drawing.Point(588, 8)
$pnlRoleFilter.Controls.Add($pillRoleCount)

$hintRole = New-HintBar -Text '提示：Server Core 上装了角色也没有图形管理工具可用（管理工具建议装在管理端的 RSAT 上），所以默认不勾选「包含管理工具」。按需功能（如 App Compatibility FOD）请用「更多 → 补给」。' -Kind 'Blue' -Width 900
$hintRole.Location = New-Object System.Drawing.Point(0, 144)
$pageRole.Controls.Add($hintRole)

$barRole          = New-ProgressBar -Width 420 -Height 6 -Indeterminate
$barRole.Location = New-Object System.Drawing.Point(0, 182)
$barRole.Visible  = $false
$pageRole.Controls.Add($barRole)

$pnlRoleResults              = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlRoleResults.Location     = New-Object System.Drawing.Point(0, 196)
$pnlRoleResults.Size         = New-Object System.Drawing.Size(896, 248)
$pnlRoleResults.Anchor       = 'Top,Left,Right,Bottom'
$pnlRoleResults.FlowDirection = 'TopDown'
$pnlRoleResults.WrapContents = $false
$pnlRoleResults.AutoScroll   = $true
$pnlRoleResults.BackColor    = $Pal.Bg
$pageRole.Controls.Add($pnlRoleResults)

$lblRoleEmpty          = New-Label -Text '正在读取角色与功能…' -Size 9.5 -Color Hint
$lblRoleEmpty.Location = New-Object System.Drawing.Point(4, 6)
$pnlRoleResults.Controls.Add($lblRoleEmpty)

# ---- 角色页状态 ----
$script:RoleSupport  = $null
$script:RoleItems    = @()
$script:RoleRows     = @()
$script:RolePills    = @()
$script:RoleTask     = ''      # '' | support | list | watch
$script:RoleProc     = $null
$script:RoleRunDir   = ''
$script:RoleOutFile  = ''
$script:RoleRunner   = Join-Path $guiDir 'Run-GuiReadyRole.ps1'
$script:RoleRowLimit = 120     # 一屏渲染上限，超出的让用户用筛选缩小（符合"宁可少画也不要卡"）

$script:RoleTimer = New-Object System.Windows.Forms.Timer
$script:RoleTimer.Interval = 300
$script:RoleTimer.Add_Tick({ Update-RoleTick })

function Set-RoleBusy {
    param([string]$Text, [string]$Kind = 'Info')
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) {
            $barRole.Visible = $false
            Set-Pill -Pill $pillRoleCount -Text '—' -Kind 'Neutral'
            return
        }
        Set-Pill -Pill $pillRoleCount -Text $Text -Kind $Kind
        $barRole.Visible = $true
        $barRole.Invalidate()
    } catch { }
}

function Stop-RoleTask {
    $script:RoleTask = ''
    $script:RoleProc = $null
    try { $script:RoleTimer.Stop() } catch { }
    if ($script:RoleRunDir) { try { Remove-Item -LiteralPath $script:RoleRunDir -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
    $script:RoleRunDir = ''
    Set-RoleBusy ''
}

function Start-RoleQuery {
    param([string]$Mode = 'list')
    if ($script:RoleTask) { Append-GuiLog -Line '[INFO] 角色查询还在跑，等它结束。'; return }
    if (-not (Test-Path -LiteralPath $script:RoleRunner)) {
        Append-GuiLog -Line '[ERROR] 找不到 gui\Run-GuiReadyRole.ps1。'
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $env:TEMP ('gui-role-{0}-{1}' -f $Mode, $stamp)
    try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    $script:RoleOutFile = Join-Path $dir 'result.json'
    $script:RoleRunDir  = $dir

    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                     '-File', ('"' + $script:RoleRunner + '"'),
                     '-Mode', $Mode,
                     '-OutFile', ('"' + $script:RoleOutFile + '"'))
        $script:RoleProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden
    } catch {
        Append-GuiLog -Line ('[ERROR] 角色查询启动失败: ' + $_.Exception.Message)
        $script:RoleTask = ''
        return
    }
    $script:RoleTask = $Mode
    Set-RoleBusy -Text $(if ($Mode -eq 'list') { '读取角色列表…' } else { '探测能力…' })
    $script:RoleTimer.Start()
}

function Clear-RoleRows {
    foreach ($r in $script:RoleRows) {
        try { $pnlRoleResults.Controls.Remove($r.Panel); $r.Panel.Dispose() } catch { }
    }
    $script:RoleRows = @()
}

function Get-RoleFilteredItems {
    $items = @($script:RoleItems)
    $mode = 1
    try { $mode = [int]$cmbRoleFilter.SelectedIndex + 1 } catch { }
    switch ($mode) {
        2 { $items = @($items | Where-Object { $_.Installed }) }
        3 { $items = @($items | Where-Object { -not $_.Installed }) }
        4 { $items = @($items | Where-Object { -not $_.Installed -and $_.FeatureType -eq 'Role' }) }
    }
    $q = ''
    try { $q = ([string]$txtRoleQuery.Box.Text).Trim() } catch { }
    if ($q) {
        $items = @($items | Where-Object {
            ([string]$_.Name -like ('*' + $q + '*')) -or ([string]$_.DisplayName -like ('*' + $q + '*'))
        })
    }
    return $items
}

function Get-RoleRowWidth {
    $w = $pnlRoleResults.ClientSize.Width
    if ($w -le 0) { $w = $pnlRoleResults.Width }
    return [Math]::Max(420, ($w - 26))
}

function Add-RoleRow {
    param($Item)
    $rowW = Get-RoleRowWidth
    $row  = New-Card -Width $rowW -Height 58 -Radius 10
    $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

    $title = [string]$Item.DisplayName
    if ([string]::IsNullOrWhiteSpace($title)) { $title = [string]$Item.Name }
    $lbName = New-Label -Text $title -Size 10 -Style Bold -Width ($rowW - 240)
    $lbName.Location = New-Object System.Drawing.Point(14, 9)
    $row.Controls.Add($lbName)

    $kind = [string]$Item.FeatureType
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = '—' }
    $dep = ''
    if (@($Item.DependsOn).Count -gt 0) { $dep = '   依赖: ' + (@($Item.DependsOn) -join ', ') }
    $meta = ('{0}   ·   {1}{2}' -f [string]$Item.Name, $kind, $dep)
    $lbMeta = New-Label -Text $meta -Size 8.5 -Color Hint -Width ($rowW - 240)
    $lbMeta.Location = New-Object System.Drawing.Point(14, 32)
    $row.Controls.Add($lbMeta)

    $pill = $null
    if ($Item.Installed) {
        $pill = New-Pill -Text '已安装' -Kind 'Success'
        $row.Controls.Add($pill)
    }

    $btnIns = New-FlatButton -Text '安装' -Kind Primary -Width 80 -Height 30
    $btnIns.Tag = @{ Name = [string]$Item.Name }
    $btnIns.Add_Click({ Start-RoleAction -Id 'role-install' -Params @{ Name = [string]$this.Tag.Name } })
    $row.Controls.Add($btnIns)

    $btnRem = New-FlatButton -Text '移除' -Width 80 -Height 30
    $btnRem.Enabled = [bool]$Item.Installed
    $btnRem.Tag = @{ Name = [string]$Item.Name }
    $btnRem.Add_Click({ Start-RoleAction -Id 'role-remove' -Params @{ Name = [string]$this.Tag.Name } })
    $row.Controls.Add($btnRem)

    $pnlRoleResults.Controls.Add($row)
    $script:RoleRows += [pscustomobject]@{ Panel = $row; Name = $lbName; Meta = $lbMeta; Install = $btnIns; Remove = $btnRem; Pill = $pill }
}

function Update-RoleRowLayout {
    $rowW = Get-RoleRowWidth
    foreach ($r in $script:RoleRows) {
        try {
            $r.Panel.Width = $rowW
            $r.Name.Width  = $rowW - 240
            $r.Meta.Width  = $rowW - 240
            $r.Install.Location = New-Object System.Drawing.Point(($rowW - 184), 14)
            $r.Remove.Location  = New-Object System.Drawing.Point(($rowW - 96), 14)
            if ($r.Pill) { $r.Pill.Location = New-Object System.Drawing.Point(($rowW - 194 - $r.Pill.Width), 18) }
            Set-Rounded -Control $r.Panel -Radius 10
        } catch { }
    }
}

function Show-RoleResult {
    $items = @(Get-RoleFilteredItems)
    Clear-RoleRows

    if ($script:RoleItems.Count -eq 0) {
        # 空列表必须带原因：没有 ServerManager 和「真的一个功能都没有」是两回事
        $lblRoleEmpty.Visible = $true
        $sup = $script:RoleSupport
        if ($sup -and -not $sup.ServerManager) {
            $lblRoleEmpty.Text = $(if ($sup.Note) { $sup.Note } else { '本机没有 ServerManager 模块，角色/功能不适用。' }) + '  按需功能请看「更多 → 补给」。'
        } else {
            $lblRoleEmpty.Text = '没有可显示的角色/功能。'
        }
        Set-Pill -Pill $pillRoleCount -Text '0 项' -Kind 'Neutral'
        return
    }

    $lblRoleEmpty.Visible = ($items.Count -eq 0)
    if ($items.Count -eq 0) {
        $lblRoleEmpty.Text = '当前筛选条件下没有匹配项。'
        Set-Pill -Pill $pillRoleCount -Text '0 项' -Kind 'Neutral'
        return
    }

    $shown = $items
    $cut = $false
    if ($shown.Count -gt $script:RoleRowLimit) {
        $shown = $shown[0..($script:RoleRowLimit - 1)]
        $cut = $true
    }
    foreach ($i in $shown) { Add-RoleRow -Item $i }
    Update-RoleRowLayout

    $sum = Get-GuiReadyRoleSummary -Items $script:RoleItems
    Set-Pill -Pill $pillRoleCount -Text ('已装 {0} / 共 {1}，显示 {2}' -f $sum.Installed, $sum.Total, $shown.Count) -Kind 'Info'
    if ($cut) { $lblRoleEmpty.Visible = $true; $lblRoleEmpty.Text = ('匹配 {0} 项，只画了前 {1} 项 —— 用筛选缩小范围。' -f $items.Count, $script:RoleRowLimit) }
}

function Update-RoleStatusRow {
    foreach ($c in @($pnlRoleStatus.Controls)) {
        if ($c -ne $lblRoleStatusHint) { try { $pnlRoleStatus.Controls.Remove($c); $c.Dispose() } catch { } }
    }
    $script:RolePills = @()
    $sup = $script:RoleSupport
    if (-not $sup) {
        $lblRoleStatusHint.Visible = $true
        return
    }
    $lblRoleStatusHint.Visible = $false

    $specs = @(
        @{ Text = $(if ($sup.ServerOs) { 'Windows Server' } else { '客户端 Windows（无角色管理）' }); Kind = $(if ($sup.ServerOs) { 'Success' } else { 'Warn' }) }
        @{ Text = ('ServerManager ' + $(if ($sup.ServerManager) { '可用' } else { '不可用' })); Kind = $(if ($sup.ServerManager) { 'Success' } else { 'Neutral' }) }
        @{ Text = ('按需功能(DISM) ' + $(if ($sup.Dism) { '可用' } else { '不可用' })); Kind = $(if ($sup.Dism) { 'Success' } else { 'Neutral' }) }
        @{ Text = $(if ($sup.Administrator) { '管理员' } else { '非管理员（只能看）' }); Kind = $(if ($sup.Administrator) { 'Success' } else { 'Warn' }) }
    )
    $x = 0
    foreach ($s in $specs) {
        $p = New-Pill -Text $s.Text -Kind $s.Kind
        $p.Location = New-Object System.Drawing.Point($x, 6)
        $pnlRoleStatus.Controls.Add($p)
        $script:RolePills += $p
        $x += $p.Width + 8
    }
    $btn = New-FlatButton -Text '刷新' -Width 76 -Height 30
    $btn.Location = New-Object System.Drawing.Point($x, 2)
    $btn.Add_Click({ Start-RoleQuery -Mode 'list' })
    $pnlRoleStatus.Controls.Add($btn)
}

function Update-RoleTick {
    if ($script:RoleTask -eq 'watch') {
        $running = $false
        try { if ($script:Proc) { $script:Proc.Refresh(); $running = -not $script:Proc.HasExited } } catch { }
        if ($running) { try { $barRole.Invalidate() } catch { }; return }
        Stop-RoleTask
        Append-GuiLog -Line '[INFO] 角色动作已结束 —— 点「刷新」看最新状态（需要重启的会写在日志里）。'
        return
    }
    if (-not $script:RoleTask) { try { $script:RoleTimer.Stop() } catch { }; return }

    try {
        if ($script:RoleProc) {
            $script:RoleProc.Refresh()
            if (((Get-Date) - $script:RoleProc.StartTime).TotalSeconds -gt 180 -and -not (Test-Path -LiteralPath $script:RoleOutFile)) {
                Append-GuiLog -Line '[WARN] 角色查询超过 180 秒没有结果，已放弃。'
                Stop-RoleTask
                return
            }
        }
        $barRole.Invalidate()
    } catch { }

    $obj = Import-GuiJsonFile -Path $script:RoleOutFile
    if (-not $obj) { return }

    $task = $script:RoleTask
    $err  = [string]$obj.Error
    Stop-RoleTask
    if ($err) { Append-GuiLog -Line ('[WARN] 角色查询返回错误: ' + $err) }

    $script:RoleSupport = $obj.Support
    $script:RoleItems   = @($obj.Items)
    Update-RoleStatusRow
    Show-RoleResult
    if ($task -eq 'list' -and $script:RoleItems.Count -gt 0) {
        Append-GuiLog -Line ('[INFO] 角色与功能共 {0} 项，已装 {1} 项。' -f $script:RoleItems.Count, @($script:RoleItems | Where-Object { $_.Installed }).Count)
    }
}

function Start-RoleAction {
    param([string]$Id, [hashtable]$Params = @{})
    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请先等它结束。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $a = @($script:Actions | Where-Object { $_.Id -eq $Id })
    if ($a.Count -eq 0) { Append-GuiLog -Line ('[ERROR] 未找到功能: ' + $Id); return }

    Select-GuiAction -Action $a[0]
    Set-ParamValues -Values $Params
    Start-GuiAction -DryRun $false

    if ($script:Proc) {
        $script:RoleTask = 'watch'
        Set-RoleBusy -Text '执行中（看下方日志）'
        $script:RoleTimer.Start()
    }
}

function Show-RolePage {
    if ($SkipPageHooks) { return }
    if (-not $script:RoleSupport -and -not $script:RoleTask) {
        Start-RoleQuery -Mode 'list'
    } else {
        Update-RoleStatusRow
        Show-RoleResult
    }
}

$btnRoleFilter.Add_Click({ Show-RoleResult })
$txtRoleQuery.Box.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Show-RoleResult }
})
$cmbRoleFilter.Add_SelectedIndexChanged({ Show-RoleResult })

# ============================ 仪表盘页 ============================
# 「系统监控与诊断」（想法.md 第三节 P1）。数据全在子进程里采集：
# CPU 取样要 1 秒、系统事件日志查询要几百毫秒以上，不能在界面线程上等。

$pageMon                = New-Object System.Windows.Forms.Panel
$pageMon.Dock           = 'Fill'
$pageMon.BackColor      = $Pal.Bg
$script:Pages['monitor'] = $pageMon
$pnlContent.Controls.Add($pageMon)

$lblMonHead          = New-Label -Text '仪表盘' -Size 14 -Style Bold
$lblMonHead.Location = New-Object System.Drawing.Point(2, 2)
$pageMon.Controls.Add($lblMonHead)

$lblMonDesc          = New-Label -Text '本机资源、关键服务、最近的系统错误、占内存最多的进程。全只读；服务按钮走下面的动作机制（子进程执行，日志在下方）。' -Size 9.5 -Color SubText -Width 880
$lblMonDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageMon.Controls.Add($lblMonDesc)

$pnlMonCards             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlMonCards.Location    = New-Object System.Drawing.Point(0, 56)
$pnlMonCards.Size        = New-Object System.Drawing.Size(896, 78)
$pnlMonCards.Anchor      = 'Top,Left,Right'
$pnlMonCards.WrapContents = $true
$pnlMonCards.BackColor   = $Pal.Bg
$pageMon.Controls.Add($pnlMonCards)

$script:MonCards = @{}
foreach ($spec in @(@{ K = 'cpu'; T = 'CPU' }, @{ K = 'mem'; T = '内存' }, @{ K = 'disk'; T = '系统盘' }, @{ K = 'svc'; T = '关键服务' })) {
    $script:MonCards[$spec.K] = New-StatusCard -Title $spec.T -Width 208 -Parent $pnlMonCards
}

$pnlMonBar           = New-Object System.Windows.Forms.Panel
$pnlMonBar.Location  = New-Object System.Drawing.Point(0, 140)
$pnlMonBar.Size      = New-Object System.Drawing.Size(900, 34)
$pnlMonBar.Anchor    = 'Top,Left,Right'
$pnlMonBar.BackColor = $Pal.Bg
$pageMon.Controls.Add($pnlMonBar)

# 刷新按钮在左、状态胶囊在右 —— 两个都放 x=0 会叠在一起（UI 审计抓到的重叠）
$btnMonRefresh          = New-FlatButton -Text '刷新' -Kind Primary -Width 76 -Height 30
$btnMonRefresh.Location = New-Object System.Drawing.Point(0, 2)
$pnlMonBar.Controls.Add($btnMonRefresh)

$pillMonSum          = New-Pill -Text '还未采集' -Kind 'Neutral'
$pillMonSum.Location = New-Object System.Drawing.Point(86, 6)
$pnlMonBar.Controls.Add($pillMonSum)

$hintMon = New-HintBar -Text '提示：服务名要填服务名而不是显示名（例如 WinRM / LanmanServer / TermService）。停关键服务可能断开你的远程会话，动作里会先警告。' -Kind 'Blue' -Width 900
$hintMon.Location = New-Object System.Drawing.Point(0, 176)
$pageMon.Controls.Add($hintMon)

$barMon          = New-ProgressBar -Width 420 -Height 6 -Indeterminate
$barMon.Location = New-Object System.Drawing.Point(0, 214)
$barMon.Visible  = $false
$pageMon.Controls.Add($barMon)

$pnlMonRows              = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlMonRows.Location     = New-Object System.Drawing.Point(0, 228)
$pnlMonRows.Size         = New-Object System.Drawing.Size(896, 220)
$pnlMonRows.Anchor       = 'Top,Left,Right,Bottom'
$pnlMonRows.FlowDirection = 'TopDown'
$pnlMonRows.WrapContents = $false
$pnlMonRows.AutoScroll   = $true
$pnlMonRows.BackColor    = $Pal.Bg
$pageMon.Controls.Add($pnlMonRows)

$lblMonEmpty          = New-Label -Text '点「刷新」采集一次快照。' -Size 9.5 -Color Hint
$lblMonEmpty.Location = New-Object System.Drawing.Point(4, 6)
$pnlMonRows.Controls.Add($lblMonEmpty)

$script:MonRows = @()

function Add-MonSection {
    param([string]$Text)
    $l = New-Label -Text $Text -Size 10 -Style Bold
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 6)
    $pnlMonRows.Controls.Add($l)
}

function Clear-MonRows {
    foreach ($r in $script:MonRows) { try { $pnlMonRows.Controls.Remove($r.Panel); $r.Panel.Dispose() } catch { } }
    $script:MonRows = @()
    foreach ($c in @($pnlMonRows.Controls)) {
        if ($c -is [System.Windows.Forms.Label] -and $c -ne $lblMonEmpty) { try { $pnlMonRows.Controls.Remove($c); $c.Dispose() } catch { } }
    }
}

function Render-Monitor {
    param($Obj)
    if ($null -eq $Obj) {
        # 动作跑完的回调：服务可能被启停过，重新采一次
        Start-GuiQueryHost -Query $script:QMon -Task 'snapshot' -BusyText '重新采集…' | Out-Null
        return
    }

    Clear-MonRows
    if (-not $Obj.Snap) {
        $lblMonEmpty.Visible = $true
        $lblMonEmpty.Text = '采集失败，看下方日志。'
        Set-Pill -Pill $pillMonSum -Text '采集失败' -Kind 'Danger'
        return
    }
    $lblMonEmpty.Visible = $false
    $s = $Obj.Snap

    # ---- 指标卡片 ----
    $c = $script:MonCards['cpu']
    if ($s.Cpu -and $null -ne $s.Cpu.Percent) {
        $p = [double]$s.Cpu.Percent
        $c.Dot.ForeColor = $(if ($p -ge 85) { $Pal.Err } elseif ($p -ge 60) { $Pal.Warn } else { $Pal.Ok })
        $c.Value.Text = ('{0} %' -f $p)
        $c.Sub.Text   = [string]$s.Cpu.Source
    } else {
        $c.Dot.ForeColor = $Pal.Hint
        $c.Value.Text = '不可用'
        $c.Sub.Text   = '取不到 CPU 计数器'
    }

    $c = $script:MonCards['mem']
    if ($s.Memory) {
        $p = [double]$s.Memory.UsedPercent
        $c.Dot.ForeColor = $(if ($p -ge 90) { $Pal.Err } elseif ($p -ge 75) { $Pal.Warn } else { $Pal.Ok })
        $c.Value.Text = ('已用 {0} / {1} GB' -f $s.Memory.UsedGB, $s.Memory.TotalGB)
        $c.Sub.Text   = ('{0} %' -f $p)
    } else {
        $c.Dot.ForeColor = $Pal.Hint; $c.Value.Text = '不可用'; $c.Sub.Text = ''
    }

    $c = $script:MonCards['disk']
    $disks = @($s.Disks)
    if ($disks.Count -gt 0) {
        $d0 = $disks[0]
        $worst = @($disks | Sort-Object -Property UsedPercent -Descending)[0]
        $c.Dot.ForeColor = $(if ([double]$worst.UsedPercent -ge 90) { $Pal.Err } elseif ([double]$worst.UsedPercent -ge 80) { $Pal.Warn } else { $Pal.Ok })
        $c.Value.Text = ('{0} 已用 {1}%' -f $d0.Name, $d0.UsedPercent)
        $c.Sub.Text   = ('剩余 {0} GB / 共 {1} GB{2}' -f $d0.FreeGB, $d0.TotalGB, $(if ($disks.Count -gt 1) { ('（共 {0} 个盘）' -f $disks.Count) } else { '' }))
    } else {
        $c.Dot.ForeColor = $Pal.Hint; $c.Value.Text = '不可用'; $c.Sub.Text = ''
    }

    $svcs   = @($s.Services)
    $down   = @($svcs | Where-Object { [string]$_.Status -ne 'Running' })
    $c = $script:MonCards['svc']
    $c.Dot.ForeColor = $(if ($down.Count -gt 0) { $Pal.Warn } else { $Pal.Ok })
    $c.Value.Text = $(if ($down.Count -gt 0) { ('{0} / {1} 未运行' -f $down.Count, $svcs.Count) } else { ('全部运行（{0} 个）' -f $svcs.Count) })
    $c.Sub.Text = $(if ($down.Count -gt 0) { (@($down | ForEach-Object { $_.Name }) -join ', ') } else { '' })

    Set-Pill -Pill $pillMonSum -Text ('采集于 {0}' -f [string]$s.Stamp) -Kind $(if ($down.Count -gt 0) { 'Warn' } else { 'Success' })

    # ---- 服务 ----
    Add-MonSection ('关键服务（{0} 个，其中 {1} 个未运行）' -f $svcs.Count, $down.Count)
    foreach ($sv in $svcs) {
        $running = ([string]$sv.Status -eq 'Running')
        $script:MonRows += (Add-UiRow -Container $pnlMonRows -Title ([string]$sv.Display) `
            -Meta ('{0}   ·   {1}   ·   {2}   ·   启动: {3}' -f $sv.Name, $sv.Status, $sv.Why, $sv.Start) `
            -PillText $(if ($running) { '运行中' } else { [string]$sv.Status }) -PillKind $(if ($running) { 'Success' } else { 'Warn' }) `
            -BtnText '重启' -BtnTag @{ Name = [string]$sv.Name } `
            -BtnClick { Invoke-PageAction -Id 'monitor-service' -Params @{ Name = [string]$this.Tag.Name; Action = 3 } -Query $script:QMon | Out-Null })
    }

    # ---- 最近事件 ----
    $evs = @($s.Events)
    Add-MonSection ('最近的系统错误/警告（{0} 条）' -f $evs.Count)
    if ($evs.Count -eq 0) {
        $script:MonRows += (Add-UiRow -Container $pnlMonRows -Title '没有错误或警告' -Meta '系统日志里最近没有 Level=1/2 的事件' -PillText '干净' -PillKind 'Success' -Height 44)
    } else {
        foreach ($e in $evs) {
            $isErr = ([string]$e.Level -match '错误|Error')
            $script:MonRows += (Add-UiRow -Container $pnlMonRows -Title ('{0}  {1} (Id={2})' -f $e.Time, $e.Provider, $e.Id) -Meta ([string]$e.Message) `
                -PillText ([string]$e.Level) -PillKind $(if ($isErr) { 'Danger' } else { 'Warn' }) -Height 56)
        }
    }

    # ---- 进程 ----
    $procs = @($s.Processes)
    Add-MonSection ('占内存最多的进程（前 {0} 个）' -f $procs.Count)
    foreach ($p in $procs) {
        $script:MonRows += (Add-UiRow -Container $pnlMonRows -Title ([string]$p.Name) -Meta ('PID {0}   ·   CPU 时间 {1} 秒' -f $p.Id, $p.CpuSec) `
            -PillText ('{0} MB' -f $p.MemMB) -PillKind 'Info' -Height 44)
    }

    foreach ($n in @($s.Notes)) { Append-GuiLog -Line ('[WARN] 仪表盘: ' + [string]$n) }
    Update-PageLayout
}

$script:QMon = New-GuiQueryHost -Name 'monitor' -Runner (Join-Path $guiDir 'Run-GuiReadyMonitor.ps1') -TimeoutSec 90 `
    -OnResult { param($obj) Render-Monitor -Obj $obj } `
    -OnBusyStart { param($t) Set-Pill -Pill $pillMonSum -Text $t -Kind 'Info'; $barMon.Visible = $true; $barMon.Invalidate() } `
    -OnBusyEnd { $barMon.Visible = $false }

$btnMonRefresh.Add_Click({ Start-GuiQueryHost -Query $script:QMon -Task 'snapshot' -BusyText '采集快照…' | Out-Null })

function Show-MonPage {
    if ($SkipPageHooks) { return }
    if (-not $script:MonLoaded) {
        $script:MonLoaded = $true
        Start-GuiQueryHost -Query $script:QMon -Task 'snapshot' -BusyText '采集快照…' | Out-Null
    }
}
$script:MonLoaded = $false

# ============================ 安全页 ============================
# 「安全与合规中心」（想法.md 第三节 P0）。只做能在本机直接验证的项，修也只修安全可逆的项。

$pageSec                = New-Object System.Windows.Forms.Panel
$pageSec.Dock           = 'Fill'
$pageSec.BackColor      = $Pal.Bg
$script:Pages['security'] = $pageSec
$pnlContent.Controls.Add($pageSec)

$lblSecHead          = New-Label -Text '安全与合规' -Size 14 -Style Bold
$lblSecHead.Location = New-Object System.Drawing.Point(2, 2)
$pageSec.Controls.Add($lblSecHead)

$lblSecDesc          = New-Label -Text '本地可验证的安全基线（10 项，每项都带原始证据）。修复只覆盖安全且可逆的项；改 UAC、删管理员这类可能把人锁在门外的操作只给建议。' -Size 9.5 -Color SubText -Width 880
$lblSecDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageSec.Controls.Add($lblSecDesc)

$pnlSecBar           = New-Object System.Windows.Forms.Panel
$pnlSecBar.Location  = New-Object System.Drawing.Point(0, 56)
$pnlSecBar.Size      = New-Object System.Drawing.Size(900, 34)
$pnlSecBar.Anchor    = 'Top,Left,Right'
$pnlSecBar.BackColor = $Pal.Bg
$pageSec.Controls.Add($pnlSecBar)

$lblSecHint          = New-Label -Text '正在审计…' -Size 9.5 -Color Hint
$lblSecHint.Location = New-Object System.Drawing.Point(4, 8)
$pnlSecBar.Controls.Add($lblSecHint)

$pnlSecFilter           = New-Object System.Windows.Forms.Panel
$pnlSecFilter.Location  = New-Object System.Drawing.Point(0, 98)
$pnlSecFilter.Size      = New-Object System.Drawing.Size(900, 36)
$pnlSecFilter.Anchor    = 'Top,Left,Right'
$pnlSecFilter.BackColor = $Pal.Bg
$pageSec.Controls.Add($pnlSecFilter)

$cmbSecFilter               = New-Object System.Windows.Forms.ComboBox
$cmbSecFilter.DropDownStyle = 'DropDownList'
$cmbSecFilter.Location      = New-Object System.Drawing.Point(0, 6)
$cmbSecFilter.Size          = New-Object System.Drawing.Size(180, 24)
$cmbSecFilter.Font          = New-Font -Size 9.5
$cmbSecFilter.BackColor     = $Pal.Sunken
$cmbSecFilter.ForeColor     = $Pal.Text
foreach ($o in @('全部', '只看问题项（不合格/警告/未知）', '只看不合格')) { [void]$cmbSecFilter.Items.Add($o) }
$cmbSecFilter.SelectedIndex = 1
$pnlSecFilter.Controls.Add($cmbSecFilter)

$pillSecSum          = New-Pill -Text '—' -Kind 'Neutral'
$pillSecSum.Location = New-Object System.Drawing.Point(192, 8)
$pnlSecFilter.Controls.Add($pillSecSum)

$hintSec = New-HintBar -Text '本页只覆盖「本机能直接验证」的项，不是 CIS/STIG 全量基线；要看全量基线请用微软的 Security Compliance Toolkit 或 Windows-Security-Audit-Project。' -Kind 'Blue' -Width 900
$hintSec.Location = New-Object System.Drawing.Point(0, 142)
$pageSec.Controls.Add($hintSec)

$barSec          = New-ProgressBar -Width 420 -Height 6 -Indeterminate
$barSec.Location = New-Object System.Drawing.Point(0, 180)
$barSec.Visible  = $false
$pageSec.Controls.Add($barSec)

$pnlSecRows              = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlSecRows.Location     = New-Object System.Drawing.Point(0, 194)
$pnlSecRows.Size         = New-Object System.Drawing.Size(896, 254)
$pnlSecRows.Anchor       = 'Top,Left,Right,Bottom'
$pnlSecRows.FlowDirection = 'TopDown'
$pnlSecRows.WrapContents = $false
$pnlSecRows.AutoScroll   = $true
$pnlSecRows.BackColor    = $Pal.Bg
$pageSec.Controls.Add($pnlSecRows)

$lblSecEmpty          = New-Label -Text '' -Size 9.5 -Color Hint
$lblSecEmpty.Location = New-Object System.Drawing.Point(4, 6)
$pnlSecRows.Controls.Add($lblSecEmpty)

$script:SecItems = @()
$script:SecRows  = @()
# 「修复」按钮的下拉索引（与 security-fix 动作里的 Options 顺序一致，1 基）
$script:SecFixIndex = @{ 'firewall' = 1; 'defender-rt' = 2; 'smbv1' = 3; 'guest' = 4; 'rdp-nla' = 5; 'password-policy' = 6 }

function Clear-SecRows {
    foreach ($r in $script:SecRows) { try { $pnlSecRows.Controls.Remove($r.Panel); $r.Panel.Dispose() } catch { } }
    $script:SecRows = @()
}

function Render-Security {
    param($Obj)
    if ($null -eq $Obj) {
        # 修复动作跑完 → 重新审计
        Start-GuiQueryHost -Query $script:QSec -Task 'audit' -BusyText '重新审计…' | Out-Null
        return
    }

    Clear-SecRows
    $script:SecItems = @($Obj.Items)
    $sum = $Obj.Summary
    if (-not $sum -or @($script:SecItems).Count -eq 0) {
        $lblSecHint.Visible = $true
        $lblSecHint.Text = '审计没拿到结果，看下方日志。'
        Set-Pill -Pill $pillSecSum -Text '审计失败' -Kind 'Danger'
        return
    }
    $lblSecHint.Visible = $false
    $script:SecSummary = $sum
    Set-Pill -Pill $pillSecSum -Text ('通过 {0} / 警告 {1} / 不合格 {2} / 未知 {3}，可修复 {4}' -f `
        $sum.Ok, $sum.Warn, $sum.Fail, $sum.Unknown, $sum.Fixable) `
        -Kind $(if ([int]$sum.Fail -gt 0) { 'Danger' } elseif ([int]$sum.Warn -gt 0) { 'Warn' } else { 'Success' })

    $mode = 1
    try { $mode = [int]$cmbSecFilter.SelectedIndex + 1 } catch { }
    $items = @($script:SecItems)
    if ($mode -eq 2) { $items = @($items | Where-Object { $_.Status -ne 'OK' }) }
    elseif ($mode -eq 3) { $items = @($items | Where-Object { $_.Status -eq 'Fail' }) }

    $lblSecEmpty.Visible = ($items.Count -eq 0)
    if ($items.Count -eq 0) { $lblSecEmpty.Text = '按当前筛选没有要显示的项目。'; return }

    foreach ($c in $items) {
        $kind = switch ([string]$c.Status) {
            'OK'   { 'Success' }
            'Warn' { 'Warn' }
            'Fail' { 'Danger' }
            default { 'Neutral' }
        }
        $tag = switch ([string]$c.Status) { 'OK' { '通过' } 'Warn' { '警告' } 'Fail' { '不合格' } default { '未知' } }
        $meta = [string]$c.Detail
        if ($c.Advice) { $meta = $meta + '    → ' + [string]$c.Advice }

        $btnText = ''; $btnTag = $null
        if ($c.Fix -and $c.Fix -ne '' -and $script:SecFixIndex.ContainsKey([string]$c.Fix)) {
            $btnText = '修复'
            $btnTag = @{ Id = 'security-fix'; Index = [int]$script:SecFixIndex[[string]$c.Fix] }
        }

        $script:SecRows += (Add-UiRow -Container $pnlSecRows -Title ('{0}（{1}）' -f $c.Title, $c.Category) -Meta $meta `
            -PillText $tag -PillKind $kind -Height 58 `
            -BtnText $btnText -BtnKind $(if ($btnText) { 'Primary' } else { 'Normal' }) -BtnTag $btnTag `
            -BtnClick { if ($this.Tag) { Invoke-PageAction -Id 'security-fix' -Params @{ Fix = [int]$this.Tag.Index } -Query $script:QSec | Out-Null } })
    }
    Update-PageLayout
}

$script:QSec = New-GuiQueryHost -Name 'security' -Runner (Join-Path $guiDir 'Run-GuiReadySecurity.ps1') -TimeoutSec 180 `
    -OnResult { param($obj) Render-Security -Obj $obj } `
    -OnBusyStart { param($t) Set-Pill -Pill $pillSecSum -Text $t -Kind 'Info'; $barSec.Visible = $true; $barSec.Invalidate() } `
    -OnBusyEnd { $barSec.Visible = $false }

$cmbSecFilter.Add_SelectedIndexChanged({
    if ($script:SecItems.Count -gt 0) { Render-Security -Obj ([pscustomobject]@{ Items = $script:SecItems; Summary = $script:SecSummary }) }
})

function Show-SecPage {
    if ($SkipPageHooks) { return }
    if (-not $script:SecLoaded) {
        $script:SecLoaded = $true
        Start-GuiQueryHost -Query $script:QSec -Task 'audit' -BusyText '审计中…' | Out-Null
    }
}
$script:SecLoaded = $false
$script:SecSummary = $null

# ============================ 美化页 ============================
# 「美化与个性化」（想法.md 第三节 P1）。这里不新增能力 —— 终端美化的实现在
# lib\GuiReady.Console.ps1（Nerd Font + Oh My Posh + Fastfetch，含一键还原），
# 这一页只是把它图形化：状态一眼可见、主题能选、按钮能点。
#
# 状态是同步读的（只看注册表与本地文件，不联网、不起子进程），所以不需要查询宿主。

$pageBeauty              = New-Object System.Windows.Forms.Panel
$pageBeauty.Dock         = 'Fill'
$pageBeauty.BackColor    = $Pal.Bg
$script:Pages['beauty']  = $pageBeauty
$pnlContent.Controls.Add($pageBeauty)

$lblBeautyHead          = New-Label -Text '美化与个性化' -Size 14 -Style Bold
$lblBeautyHead.Location = New-Object System.Drawing.Point(2, 2)
$pageBeauty.Controls.Add($lblBeautyHead)

$lblBeautyDesc          = New-Label -Text '把 Server Core 的 conhost 打扮好看：Nerd Font + Oh My Posh 提示符 + Fastfetch 首屏信息。素材随发布包内置，安装过程不联网。' -Size 9.5 -Color SubText -Width 880
$lblBeautyDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageBeauty.Controls.Add($lblBeautyDesc)

$pnlBeautyStatus           = New-Object System.Windows.Forms.Panel
$pnlBeautyStatus.Location  = New-Object System.Drawing.Point(0, 56)
$pnlBeautyStatus.Size      = New-Object System.Drawing.Size(900, 34)
$pnlBeautyStatus.Anchor    = 'Top,Left,Right'
$pnlBeautyStatus.BackColor = $Pal.Bg
$pageBeauty.Controls.Add($pnlBeautyStatus)

$lblBeautyHint          = New-Label -Text '正在读取状态…' -Size 9.5 -Color Hint
$lblBeautyHint.Location = New-Object System.Drawing.Point(4, 8)
$pnlBeautyStatus.Controls.Add($lblBeautyHint)

$pnlBeautyTheme           = New-Object System.Windows.Forms.Panel
$pnlBeautyTheme.Location  = New-Object System.Drawing.Point(0, 98)
$pnlBeautyTheme.Size      = New-Object System.Drawing.Size(900, 40)
$pnlBeautyTheme.Anchor    = 'Top,Left,Right'
$pnlBeautyTheme.BackColor = $Pal.Bg
$pageBeauty.Controls.Add($pnlBeautyTheme)

$lblBeautyTheme          = New-Label -Text '提示符主题' -Size 9.5 -Color SubText
$lblBeautyTheme.Location = New-Object System.Drawing.Point(2, 11)
$pnlBeautyTheme.Controls.Add($lblBeautyTheme)

$cmbBeautyTheme               = New-Object System.Windows.Forms.ComboBox
$cmbBeautyTheme.DropDownStyle = 'DropDownList'
$cmbBeautyTheme.Location      = New-Object System.Drawing.Point(78, 8)
$cmbBeautyTheme.Size          = New-Object System.Drawing.Size(200, 24)
$cmbBeautyTheme.Font          = New-Font -Size 9.5
$cmbBeautyTheme.BackColor     = $Pal.Sunken
$cmbBeautyTheme.ForeColor     = $Pal.Text
# 顺序必须与 console-install 动作里 Theme 下拉一致（1 = 自带 One Dark 主题）
foreach ($o in @('默认（One Dark 自带）', '1_shell', 'atomic', 'catppuccin_frappe', 'dracula', 'emodipt-extend', 'zash')) {
    [void]$cmbBeautyTheme.Items.Add($o)
}
$cmbBeautyTheme.SelectedIndex = 0
$pnlBeautyTheme.Controls.Add($cmbBeautyTheme)

$lblBeautyThemeNote          = New-Label -Text '（安装时选哪个主题；已装过想换主题就再点一次「一键美化」）' -Size 8.5 -Color Hint
$lblBeautyThemeNote.Location = New-Object System.Drawing.Point(288, 12)
$pnlBeautyTheme.Controls.Add($lblBeautyThemeNote)

$pnlBeautyActions           = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlBeautyActions.Location  = New-Object System.Drawing.Point(0, 146)
$pnlBeautyActions.Size      = New-Object System.Drawing.Size(900, 44)
$pnlBeautyActions.Anchor    = 'Top,Left,Right'
$pnlBeautyActions.BackColor = $Pal.Bg
# 必须允许换行：窄屏（1024 宽的内容区只有 ~754）放不下 5 个按钮，不换行的话最后一个直接被切没
$pnlBeautyActions.WrapContents = $true
$pageBeauty.Controls.Add($pnlBeautyActions)

$hintBeauty = New-HintBar -Text '为什么必须走 scm-term：中文代码页 936 下 conhost 只接受自带中文字形的字体，实测把控制台切到 UTF-8（chcp 65001）后 Nerd Font 才会被接受 —— scm-term 就是替你做这件事的入口。' -Kind 'Blue' -Width 900
$hintBeauty.Location = New-Object System.Drawing.Point(0, 198)
$pageBeauty.Controls.Add($hintBeauty)

$pnlBeautyRows              = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlBeautyRows.Location     = New-Object System.Drawing.Point(0, 236)
$pnlBeautyRows.Size         = New-Object System.Drawing.Size(896, 212)
$pnlBeautyRows.Anchor       = 'Top,Left,Right,Bottom'
$pnlBeautyRows.FlowDirection = 'TopDown'
$pnlBeautyRows.WrapContents = $false
$pnlBeautyRows.AutoScroll   = $true
$pnlBeautyRows.BackColor    = $Pal.Bg
$pageBeauty.Controls.Add($pnlBeautyRows)

$script:BeautyRows = @()
$script:QBeauty    = $null      # 美化页不用子进程查询；动作跑完只刷新状态

function Clear-BeautyRows {
    foreach ($r in $script:BeautyRows) { try { $pnlBeautyRows.Controls.Remove($r.Panel); $r.Panel.Dispose() } catch { } }
    $script:BeautyRows = @()
}

function Update-BeautyView {
    # 状态全部来自 Get-GuiReadyConsoleStatus（读注册表与本地文件，很快），不联网
    $st = $null
    try { $st = Get-GuiReadyConsoleStatus } catch {
        $lblBeautyHint.Visible = $true
        $lblBeautyHint.Text = '读取终端美化状态失败: ' + $_.Exception.Message
        return
    }
    $lblBeautyHint.Visible = $false

    foreach ($c in @($pnlBeautyStatus.Controls)) {
        if ($c -ne $lblBeautyHint) { try { $pnlBeautyStatus.Controls.Remove($c); $c.Dispose() } catch { } }
    }
    $pills = @(
        @{ T = $(if ($st.FontInstalled) { 'Nerd Font 已装' } else { 'Nerd Font 未装' }); K = $(if ($st.FontInstalled) { 'Success' } else { 'Danger' }) }
        @{ T = $(if ($st.FontLinked) { '中文回退已配' } else { '中文回退未配' }); K = $(if ($st.FontLinked) { 'Success' } else { 'Warn' }) }
        @{ T = $(if ($st.PoshInstalled) { 'oh-my-posh 已装' } else { 'oh-my-posh 未装' }); K = $(if ($st.PoshInstalled) { 'Success' } else { 'Neutral' }) }
        @{ T = $(if ($st.FastfetchInstalled) { 'fastfetch 已装' } else { 'fastfetch 未装' }); K = $(if ($st.FastfetchInstalled) { 'Success' } else { 'Neutral' }) }
        @{ T = $(if ($st.LauncherInstalled) { 'scm-term 已就绪' } else { 'scm-term 缺失' }); K = $(if ($st.LauncherInstalled) { 'Success' } else { 'Warn' }) }
        @{ T = ('主题: ' + $(if ($st.ThemeCurrent) { [string]$st.ThemeCurrent } else { '未设置' })); K = 'Info' }
        @{ T = $(if ($st.PowerShell7) { 'PowerShell 7 ' + [string]$st.PowerShell7Ver } else { 'PowerShell 7 未装' }); K = $(if ($st.PowerShell7) { 'Success' } else { 'Neutral' }) }
    )
    $x = 0
    foreach ($p in $pills) {
        $pp = New-Pill -Text $p.T -Kind $p.K
        $pp.Location = New-Object System.Drawing.Point($x, 6)
        $pnlBeautyStatus.Controls.Add($pp)
        $x += $pp.Width + 8
    }
    $btn = New-FlatButton -Text '刷新状态' -Width 88 -Height 30
    $btn.Location = New-Object System.Drawing.Point($x, 2)
    $btn.Add_Click({ Update-BeautyView })
    $pnlBeautyStatus.Controls.Add($btn)

    Clear-BeautyRows
    $rows = @(
        @{ T = 'Nerd Font（MesloLGS NF）'; M = $(if ($st.FontInstalled) { '全局已安装；控制台白名单 ' + @($st.FontWhitelist).Count + ' 项' } else { '未安装 —— 点「一键美化终端」' }) ; P = $(if ($st.FontInstalled) { '就绪' } else { '缺失' }); K = $(if ($st.FontInstalled) { 'Success' } else { 'Danger' }) }
        @{ T = 'PowerShell profile 初始化'; M = $(if ($st.ProfileHooked) { [string]$st.ProfilePath } else { 'profile 里还没有 oh-my-posh 初始化块' }); P = $(if ($st.ProfileHooked) { '已写入' } else { '未写入' }); K = $(if ($st.ProfileHooked) { 'Success' } else { 'Warn' }) }
        @{ T = '控制台用户设置'; M = ('字体={0}   ANSI(VT)={1}   ForceV2={2}' -f $(if ($st.UserFaceName) { [string]$st.UserFaceName } else { '默认' }), $st.UserVT, $st.UserForceV2); P = '当前值'; K = 'Info' }
        @{ T = '素材目录'; M = [string]$st.AssetDir; P = $(if (@($st.AssetMissing).Count -eq 0) { '完整' } else { ('缺 ' + @($st.AssetMissing).Count + ' 项') }); K = $(if (@($st.AssetMissing).Count -eq 0) { 'Success' } else { 'Warn' }) }
    )
    foreach ($r in $rows) {
        $script:BeautyRows += (Add-UiRow -Container $pnlBeautyRows -Title $r.T -Meta $r.M -PillText $r.P -PillKind $r.K -Height 54 -MarginBottom 6)
    }

    if ($st.Conclusion) { Append-GuiLog -Line ('[INFO] 美化状态: ' + [string]$st.Conclusion) }
    Update-PageLayout
}

# 动作按钮：都是既有动作，参数与「更多 → 终端美化」里的一致
function New-BeautyButton {
    param([string]$Text, [string]$ActionId, [hashtable]$Params, [string]$Kind = 'Normal')
    $b = New-FlatButton -Text $Text -Kind $Kind -Width 150 -Height 36
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $b.Tag = @{ Id = $ActionId; Params = $Params }
    $b.Add_Click({
        Invoke-PageAction -Id ([string]$this.Tag.Id) -Params ([hashtable]$this.Tag.Params) | Out-Null
    })
    $pnlBeautyActions.Controls.Add($b)
    return $b
}

[void](New-BeautyButton -Text '一键美化终端' -ActionId 'console-install' -Kind 'Primary' -Params @{ Theme = 1 })
[void](New-BeautyButton -Text '打开美化终端' -ActionId 'console-open'    -Params @{})
[void](New-BeautyButton -Text '状态检查（实测）' -ActionId 'console-status' -Params @{ DeepProbe = $true })
[void](New-BeautyButton -Text '安装 PowerShell 7' -ActionId 'console-ps7' -Params @{})
[void](New-BeautyButton -Text '一键还原' -ActionId 'console-restore' -Params @{})

$cmbBeautyTheme.Add_SelectedIndexChanged({
    # 让「一键美化终端」按当前选中的主题跑（索引与动作里的 Options 一致）
    $idx = 1
    try { $idx = [int]$cmbBeautyTheme.SelectedIndex + 1 } catch { }
    foreach ($b in @($pnlBeautyActions.Controls)) {
        if ($b.Tag -and $b.Tag.Id -eq 'console-install') { $b.Tag.Params = @{ Theme = $idx } }
    }
})

function Show-BeautyPage {
    if ($SkipPageHooks) { return }
    Update-BeautyView
}

# ============================ AI（DeepSeek Harness）页 ============================
# 想法.md 第七节：指定集成 ccch1mneyyy/dsh-TUI。这页只做三件事：查依赖、装依赖、启动。
# npm 包到底存不存在由 npm 回答（页面里那两行就是 npm view 的实测结果），不照抄文档下结论。

$pageDsh                = New-Object System.Windows.Forms.Panel
$pageDsh.Dock           = 'Fill'
$pageDsh.BackColor      = $Pal.Bg
$script:Pages['dsh']    = $pageDsh
$pnlContent.Controls.Add($pageDsh)

$lblDshHead          = New-Label -Text 'AI 辅助（DeepSeek Harness）' -Size 14 -Style Bold
$lblDshHead.Location = New-Object System.Drawing.Point(2, 2)
$pageDsh.Controls.Add($lblDshHead)

$lblDshDesc          = New-Label -Text '指定的集成是 ccch1mneyyy/dsh-TUI（npm 包 @deepseek-harness-tui/dsh-tui），依赖 Node.js ≥ 22.19 / pnpm ≥ 10 / 官方 CLI @deepseek-ai/dsh。' -Size 9.5 -Color SubText -Width 880
$lblDshDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageDsh.Controls.Add($lblDshDesc)

$pnlDshStatus           = New-Object System.Windows.Forms.Panel
$pnlDshStatus.Location  = New-Object System.Drawing.Point(0, 56)
$pnlDshStatus.Size      = New-Object System.Drawing.Size(900, 34)
$pnlDshStatus.Anchor    = 'Top,Left,Right'
$pnlDshStatus.BackColor = $Pal.Bg
$pageDsh.Controls.Add($pnlDshStatus)

$pillDshSum          = New-Pill -Text '正在检查依赖…' -Kind 'Neutral'
$pillDshSum.Location = New-Object System.Drawing.Point(0, 6)
$pnlDshStatus.Controls.Add($pillDshSum)

$hintDsh = New-HintBar -Text '密钥由你自己设：setx DEEPSEEK_API_KEY "sk-..."，然后重开工具 —— 本工具不会把密钥写进任何脚本或配置文件。' -Kind 'Blue' -Width 900
$hintDsh.Location = New-Object System.Drawing.Point(0, 98)
$pageDsh.Controls.Add($hintDsh)

$barDsh          = New-ProgressBar -Width 420 -Height 6 -Indeterminate
$barDsh.Location = New-Object System.Drawing.Point(0, 136)
$barDsh.Visible  = $false
$pageDsh.Controls.Add($barDsh)

$pnlDshActions           = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlDshActions.Location  = New-Object System.Drawing.Point(0, 152)
$pnlDshActions.Size      = New-Object System.Drawing.Size(900, 44)
$pnlDshActions.Anchor    = 'Top,Left,Right'
$pnlDshActions.BackColor = $Pal.Bg
# 同美化页：窄屏放不下就换行，不能让按钮跑到可视区外面
$pnlDshActions.WrapContents = $true
$pageDsh.Controls.Add($pnlDshActions)

$pnlDshRows              = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlDshRows.Location     = New-Object System.Drawing.Point(0, 204)
$pnlDshRows.Size         = New-Object System.Drawing.Size(896, 244)
$pnlDshRows.Anchor       = 'Top,Left,Right,Bottom'
$pnlDshRows.FlowDirection = 'TopDown'
$pnlDshRows.WrapContents = $false
$pnlDshRows.AutoScroll   = $true
$pnlDshRows.BackColor    = $Pal.Bg
$pageDsh.Controls.Add($pnlDshRows)

$lblDshEmpty          = New-Label -Text '正在检查依赖…' -Size 9.5 -Color Hint
$lblDshEmpty.Location = New-Object System.Drawing.Point(4, 6)
$pnlDshRows.Controls.Add($lblDshEmpty)

$script:DshRows = @()

function Clear-DshRows {
    foreach ($r in $script:DshRows) { try { $pnlDshRows.Controls.Remove($r.Panel); $r.Panel.Dispose() } catch { } }
    $script:DshRows = @()
}

function Render-Dsh {
    param($Obj)
    if ($null -eq $Obj) {
        # 装完依赖 / 启动完之后重新检查一次
        Start-GuiQueryHost -Query $script:QDsh -Task 'status' -ExtraArgs @('-DeepProbe') -BusyText '重新检查依赖…' | Out-Null
        return
    }
    if (-not $Obj.Status) {
        Set-Pill -Pill $pillDshSum -Text '检查失败（看日志）' -Kind 'Danger'
        return
    }

    $st = $Obj.Status
    Clear-DshRows
    $lblDshEmpty.Visible = $false

    $missing = @($st.Items | Where-Object { -not $_.Ok })
    Set-Pill -Pill $pillDshSum -Text $(if ($st.Ready) { '依赖齐了，可以启动' } else { ('还差 {0} 项' -f $missing.Count) }) `
        -Kind $(if ($st.Ready) { 'Success' } else { 'Warn' })

    foreach ($i in @($st.Items)) {
        $meta = [string]$i.Detail
        if ($i.Advice) { $meta = $meta + '    → ' + [string]$i.Advice }
        $script:DshRows += (Add-UiRow -Container $pnlDshRows -Title ('{0}   需要 {1}' -f $i.Name, $i.Required) -Meta $meta `
            -PillText $(if ($i.Ok) { '就绪' } else { '缺失' }) -PillKind $(if ($i.Ok) { 'Success' } else { 'Danger' }) -Height 54)
    }

    # npm 实查结果（包名以 npm 的回答为准）
    $pkgs = @($st.Npm)
    if ($pkgs.Count -gt 0) {
        foreach ($p in $pkgs) {
            $meta = $(if ($p.Exists) { 'npm 上存在，最新版本 ' + [string]$p.Version } else { 'npm 查不到：' + [string]$p.Error })
            $script:DshRows += (Add-UiRow -Container $pnlDshRows -Title ('npm 包 ' + [string]$p.Package) -Meta $meta `
                -PillText $(if ($p.Exists) { '存在' } else { '查不到' }) -PillKind $(if ($p.Exists) { 'Success' } else { 'Danger' }) -Height 50)
        }
    }
    Update-PageLayout
}

$script:QDsh = New-GuiQueryHost -Name 'dsh' -Runner (Join-Path $guiDir 'Run-GuiReadyDsh.ps1') -TimeoutSec 180 `
    -OnResult { param($obj) Render-Dsh -Obj $obj } `
    -OnBusyStart { param($t) Set-Pill -Pill $pillDshSum -Text $t -Kind 'Info'; $barDsh.Visible = $true; $barDsh.Invalidate() } `
    -OnBusyEnd { $barDsh.Visible = $false }

function New-DshButton {
    param([string]$Text, [string]$ActionId, [hashtable]$Params, [string]$Kind = 'Normal')
    $b = New-FlatButton -Text $Text -Kind $Kind -Width 150 -Height 36
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $b.Tag = @{ Id = $ActionId; Params = $Params }
    $b.Add_Click({
        $id = [string]$this.Tag.Id
        # 装 dsh-TUI 依赖会连带装包管理器 + Node.js：先让用户自己选择，选完就一路自动装完
        if ($id -eq 'dsh-install' -and -not (Resolve-GuiReadyDshExe -Id 'node')) {
            if (-not (Confirm-GuiPackageManager -Why 'dsh-TUI 依赖 Node.js，而本机还没有 Node.js。')) {
                Append-GuiLog -Line '[INFO] 你取消了自动安装，本次依赖安装没有执行。'
                return
            }
        }
        Invoke-PageAction -Id $id -Params ([hashtable]$this.Tag.Params) -Query $script:QDsh | Out-Null
    })
    $pnlDshActions.Controls.Add($b)
    return $b
}

[void](New-DshButton -Text '一键安装依赖' -ActionId 'dsh-install' -Kind 'Primary' -Params @{ SkipPnpm = $false })
[void](New-DshButton -Text '启动 dsh-TUI'  -ActionId 'dsh-launch'   -Params @{ Resume = $false })
[void](New-DshButton -Text '重新检查'      -ActionId 'dsh-status'   -Params @{})

function Show-DshPage {
    if ($SkipPageHooks) { return }
    if (-not $script:DshLoaded) {
        $script:DshLoaded = $true
        Start-GuiQueryHost -Query $script:QDsh -Task 'status' -ExtraArgs @('-DeepProbe') -BusyText '检查依赖（含 npm 实查）…' | Out-Null
    }
}
$script:DshLoaded = $false

# ============================ 自适应布局 ============================
# 之前内容区写死 900 宽，而下面的日志面板是全宽，导致右边空出一大条、看着就是“错位”。
# 这里统一按父容器实际宽度重排；标题栏与导航的顺序也在下面纠正。

# 页面自身的尺寸也会变（Dock 排布在窗口显示后才定下来），必须跟着重算，
# 否则会出现“卡片按旧宽度排好、面板却已变宽/变窄”的不一致。
foreach ($k in $script:Pages.Keys) {
    try { $script:Pages[$k].Add_Resize({ Update-PageLayout }) } catch { }
}

function Update-PageLayout {
    # 启动时会把布局调用挂起，最后统一算一次 —— 一次布局要遍历所有页面/卡片/工具行，
    # 之前 Shown 里被连着调 3 次，纯属白等。
    if ($script:LayoutSuspended) { $script:LayoutPending = $true; return }
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
        # 每行几张、卡片多宽、容器多高，全部由 Set-CardRowLayout + Get-FlowWrappedHeight 按实际
        # 可用宽度算（仪表盘走的是同一套）。写死宽度/高度在窄屏下必然溢出或被裁 —— 真机踩过。
        $w = [Math]::Max(360, $pageEnv.ClientSize.Width)
        if ($script:Cards.Count -gt 0) {
            Set-CardRowLayout -Panel $pnlCards -Width $w
            $rowsN = Get-FlowWrappedHeight -Panel $pnlCards -Width $w
            $pnlCards.Width  = $w
            if ($rowsN -gt 0) { $pnlCards.Height = $rowsN }
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
        # 说明文字限宽：AutoSize 的标签直接改 Width 无效，先关掉自动尺寸再限宽，
        # 超长就用省略号收尾 —— 否则窄屏下这句话会顶出客户区被硬切（真机 1024 宽实测 908 > 754）。
        if ($lblToolDesc.AutoSize) { $lblToolDesc.AutoSize = $false; $lblToolDesc.AutoEllipsis = $true }
        $lblToolDesc.Width = $w4 - 12
        $hintTool.Width = $w4
        if ($hintTool.Tag) { $hintTool.Tag.Width = $w4 - 20 }
        $perRowTool = [Math]::Max(1, [Math]::Floor(($w4 - 12) / 140))
        foreach ($tr in $script:ToolRows) {
            $tr.Row.Width  = [Math]::Max(200, $w4 - 16)
            $rowsNeeded    = [Math]::Ceiling($tr.Count / $perRowTool)
            $tr.Row.Height = [int]($rowsNeeded * 40) + 2
        }

        # ---- 关于页 ----
        # 卡片宽度跟着内容区走；卡片里的文字与按钮都在左侧固定位置，不受影响。
        try {
            $w5 = [Math]::Max(560, $pageAbout.ClientSize.Width)
            $cardAbout.Width = $w5
            $cardAbout.Height = [Math]::Max(250, ($pageAbout.ClientSize.Height - $cardAbout.Top - 8))
            Set-Rounded -Control $cardAbout -Radius 12
        } catch { }

        # ---- 商店页 ----
        Update-StoreLayout

        # ---- 角色页 ----
        Update-RoleLayout

        # ---- 仪表盘 / 安全 / 美化 / AI（四页骨架一样，统一走一个函数）----
        Update-RayPageLayout -Page $pageMon -Rows $pnlMonRows -Wide @($lblMonDesc, $pnlMonCards, $pnlMonBar, $hintMon)
        Update-RayPageLayout -Page $pageSec -Rows $pnlSecRows -Wide @($lblSecDesc, $pnlSecBar, $pnlSecFilter, $hintSec)
        Update-RayPageLayout -Page $pageBeauty -Rows $pnlBeautyRows -Wide @($lblBeautyDesc, $pnlBeautyStatus, $pnlBeautyTheme, $pnlBeautyActions, $hintBeauty)
        Update-RayPageLayout -Page $pageDsh -Rows $pnlDshRows -Wide @($lblDshDesc, $pnlDshStatus, $hintDsh, $pnlDshActions)
    } catch { }
}

function Update-RayPageLayout {
    # 这四页的骨架一致：标题 + 说明 + 若干横向容器 + 结果区（吃剩余高度）。
    # 提示条（New-HintBar）要连内层文字一起改宽，否则文字会被裁掉。
    param(
        [System.Windows.Forms.Control]$Page,
        [System.Windows.Forms.Control]$Rows,
        [object[]]$Wide = @()
    )
    try {
        $w = [Math]::Max(560, $Page.ClientSize.Width)
        $h = [Math]::Max(320, $Page.ClientSize.Height)

        foreach ($c in @($Wide)) {
            if (-not $c) { continue }
            if (($c -is [System.Windows.Forms.Panel]) -and ($c.Tag -is [System.Windows.Forms.Label])) {
                # 提示条：外层 + 内层文字一起改宽（内层按 New-HintBar 的算法留 20px）
                $c.Width = $w - 8
                $c.Tag.Width = $w - 28
            } elseif ($c -is [System.Windows.Forms.Label]) {
                # 说明文字。**AutoSize 的标签改 Width 是无效的** —— 必须先把自动尺寸关掉再限宽，
                # 否则窄屏下长句子会顶出客户区被硬切（真机 1024 宽实测：工具页说明文字 908 > 可用 754）。
                if ($c.AutoSize) { $c.AutoSize = $false; $c.AutoEllipsis = $true }
                $c.Width = $w - 12
            } elseif ($c -is [System.Windows.Forms.FlowLayoutPanel]) {
                $c.Width = $w
                if ($c.WrapContents) {
                    # 先把卡片按可用宽度摊平（能一行放下就一行放下），再按实际行数给容器定高。
                    # 缺了这一步，窄屏下第二行会被容器裁掉（实测：仪表盘第 4 张指标卡整个看不见）。
                    Set-CardRowLayout -Panel $c -Width $w
                    $need = Get-FlowWrappedHeight -Panel $c -Width $w
                    if ($need -gt 0) { $c.Height = $need }
                }
            } else {
                $c.Width = $w
            }
        }

        # 结果区要顶在"上面那一摞"的下面：上面某个容器换行长高了，这里必须跟着往下挪，
        # 否则会被压住。
        # 规则：**只往下推、不往上提**；并且跳过本来就在结果区下方的项（贴底的提示条），
        # 否则会把它顶下去、还会把结果区排到它下面。
        $y = 0
        foreach ($c in @($Wide)) {
            if (-not $c) { continue }
            if ($c.Top -ge $Rows.Top) { continue }
            if ($y -gt 0 -and $c.Top -lt $y) { $c.Top = $y }
            $y = $c.Top + $c.Height + 6
        }
        if ($y -gt 0 -and ($y - 6) -gt $Rows.Top) { $Rows.Top = $y }

        $Rows.Width  = $w - 4
        $Rows.Height = [Math]::Max(120, ($h - $Rows.Top - 10))
    } catch { }
}

function Update-RoleLayout {
    try {
        $w = [Math]::Max(560, $pageRole.ClientSize.Width)
        $h = [Math]::Max(320, $pageRole.ClientSize.Height)

        $lblRoleDesc.Width  = $w - 12
        $pnlRoleStatus.Width = $w
        $pnlRoleFilter.Width = $w
        $hintRole.Width = $w - 8
        if ($hintRole.Tag) { $hintRole.Tag.Width = $w - 28 }

        $pnlRoleResults.Width  = $w - 4
        $pnlRoleResults.Height = [Math]::Max(120, ($h - $pnlRoleResults.Top - 10))

        Update-RoleRowLayout
    } catch { }
}

function Update-StoreLayout {
    # 源状态行、搜索行、提示条都要跟着内容区宽度走；结果行整行右对齐（按钮贴右边）
    try {
        $w = [Math]::Max(560, $pageStore.ClientSize.Width)
        $h = [Math]::Max(320, $pageStore.ClientSize.Height)

        $lblStoreDesc.Width = $w - 12
        $pnlStoreSrc.Width  = $w
        $pnlStoreSearch.Width = $w
        $hintStore.Width = $w - 8
        if ($hintStore.Tag) { $hintStore.Tag.Width = $w - 28 }

        $pnlStoreResults.Width  = $w - 4
        $pnlStoreResults.Height = [Math]::Max(120, ($h - $pnlStoreResults.Top - 10))

        Update-StoreRowLayout
    } catch { }
}

# ============================ 通用逻辑 ============================

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 400

function Append-GuiLog {
    param([string]$Line)
    # curl、MSI、原生 exe 这类输出常带不带换行的进度（单独一个 `r 回车）。直接塞进 RichTextBox
    # 会让光标回到行首反复覆盖，看起来就是“日志乱码 + 一直滚”；超长行还会让面板卡住。
    # 这里统一：回车去掉、超长截断。
    try {
        if ($Line) {
            if ($Line.IndexOf("`r") -ge 0) { $Line = $Line.Replace("`r", '') }
            if ($Line.Length -gt 2000) { $Line = $Line.Substring(0, 2000) + ' …（本行过长已截断）' }
        }
    } catch { }
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
        # 面板最多留 3500 行：RichTextBox 行数上万以后重绘/滚动会明显拖慢界面。
        # 用计数器判断，别每次都去数 Lines（那本身也要遍历全文）。
        $script:LogLines++
        if ($script:LogLines -gt 3500) {
            $ro = $txtLog.ReadOnly
            try {
                $txtLog.ReadOnly = $false
                $txtLog.SelectionStart  = 0
                $txtLog.SelectionLength = $txtLog.GetFirstCharIndexFromLine(500)
                $txtLog.SelectedText    = ''
            } finally {
                $txtLog.ReadOnly = $ro
                $script:LogLines -= 500
            }
        }
        $txtLog.ScrollToCaret()
    } catch { }
}

function Show-GuiPage {
    param([string]$Key, [switch]$SkipCards)
    if (-not $script:Pages.ContainsKey($Key)) { return }
    $script:CurrentPage = $Key
    foreach ($k in $script:Pages.Keys) { $script:Pages[$k].Visible = ($k -eq $Key) }
    # 导航项是自绘面板：只改 Tag 里的状态再重画，不做控件重建
    foreach ($b in $script:NavButtons) {
        try {
            $on = ([string]$b.Tag.Page -eq $Key)
            if ($b.Tag.Active -ne $on) { $b.Tag.Active = $on; $b.Invalidate() }
        } catch { }
    }
    if ($Key -eq 'env' -and -not $SkipCards) { Refresh-EnvCards }
    if ($Key -eq 'store') { Show-StorePage }
    if ($Key -eq 'role') { Show-RolePage }
    if ($Key -eq 'monitor') { Show-MonPage }
    if ($Key -eq 'security') { Show-SecPage }
    if ($Key -eq 'beauty') { Show-BeautyPage }
    if ($Key -eq 'dsh') { Show-DshPage }
    if ($Key -eq 'tool') { Update-ToolButtons; Update-WacToolGroup }
    # 页头淡入（对齐参考文档 §5.5 的"进入页面有过渡"；RDP 下只做 5 帧，不费帧）
    if (-not $SkipPageHooks) {
        $hdrs = @()
        try {
            $pg = $script:Pages[$Key]
            foreach ($c in @($pg.Controls)) {
                if ($c -is [System.Windows.Forms.Label]) { $hdrs += $c }
                if ($hdrs.Count -ge 2) { break }
            }
        } catch { }
        if ($hdrs.Count -gt 0) { Invoke-UiPageFadeIn -Controls $hdrs -Frames 5 }
    }
    Update-PageLayout
}

# ---- 环境页数据缓存 ----
# 之前每次切到「环境」页、以及每个动作跑完，都会在 UI 线程上同步重跑一遍重查询。
# 在 Server Core 上实测单次开销：DISM 能力查询 ~0.8s、WAC 防火墙/证书 ~2.0s、
# dotnet --list-runtimes ~0.7s、DLL 扫描 0.3s（还被调了两次），合计 2~4 秒界面冻住。
# 现在统一缓存，TTL 内直接用缓存；切页只刷新显示，不再重新查询。
$script:EnvCacheTtlSec = 45
$script:EnvCacheTime   = [datetime]::MinValue
$script:EnvCacheData   = $null

function Clear-EnvCache {
    $script:EnvCacheTime  = [datetime]::MinValue
    $script:EnvCacheData  = $null
    $script:ToolCacheTime = [datetime]::MinValue
}

function Get-EnvCardData {
    param([switch]$Force)

    if (-not $Force -and $script:EnvCacheData -and ((Get-Date) - $script:EnvCacheTime).TotalSeconds -lt $script:EnvCacheTtlSec) {
        return $script:EnvCacheData
    }

    $d = [ordered]@{
        Static = $null; Profile = $null; Cap = $null; DllScan = $null
        DotNet = $null; Sessions = $null; AutoLogon = $null; Uac = $null; Wac = $null
    }
    try { $d.Static    = Get-GuiReadyStatic } catch { }
    try { $d.Profile   = Get-GuiReadyOsProfile -Static $d.Static } catch { }
    try { $d.Cap       = Get-GuiReadyCapability } catch { }
    try { $d.DllScan   = Get-GuiReadyDllScan } catch { }          # 只扫一次，两张卡片共用
    try { $d.DotNet    = Get-GuiReadyDotNetStatus -Fast } catch { }
    try { $d.Sessions  = Get-GuiReadySessionInfo } catch { }
    try { $d.AutoLogon = Get-GuiReadyAutoLogon } catch { }
    try { $d.Uac       = Get-GuiReadyUac } catch { }
    try { $d.Wac       = Get-GuiReadyWacStatus -SkipProbe -Lite } catch { }

    $script:EnvCacheData = [pscustomobject]$d
    $script:EnvCacheTime = Get-Date
    return $script:EnvCacheData
}

function Update-EnvCards {
    param([switch]$Force, $Data)
    Initialize-EnvCards
    # $Data 是后台探测（或磁盘缓存）的结果；没传就同步查一次（自检 / 布局诊断用这条路）
    if ($null -eq $Data) {
        $Data = Get-EnvCardData -Force:$Force
    } else {
        # 让其它读缓存的地方（例如工具页判断 WAC 是否在跑）也拿到同一份数据
        $script:EnvCacheData = $Data
        $script:EnvCacheTime = Get-Date
    }
    $d = $Data
    try {
        $s = $d.Static
        $prof = $d.Profile
        $card = $script:Cards[0]
        $card.Dot.ForeColor = $Pal.Ok
        $card.Value.Text = ('{0} Build {1}' -f $prof.Short, $prof.Build)
        $card.Sub.Text   = [string]$prof.InstallationType
    } catch { }

    try {
        $fod = 'Unknown'
        $cap = $d.Cap
        foreach ($i in @($cap.Items)) { if ($i.Name -like 'ServerCore.AppCompatibility*') { $fod = $i.State } }
        # 后台探测的 fast 阶段是「按组件推断」的结论，必须标出来，不能冒充 DISM 的精确结果
        $fodTag = $(if ($cap.Inferred) { '（推断）' } else { '' })
        $miss = 0; $total = 0
        $dlls = $d.DllScan
        $grp = @($dlls | Where-Object { $_.Group -eq '桌面体验专属' })
        $total = $grp.Count
        $miss = @($grp | Where-Object { -not $_.Exists }).Count
        $card = $script:Cards[1]
        if ($fod -eq 'Installed') {
            $card.Dot.ForeColor = $(if ($miss -le 4) { $Pal.Ok } else { $Pal.Warn })
            $card.Value.Text = 'FOD 已安装' + $fodTag
            $card.Sub.Text   = ('还缺 {0}/{1} 个桌面组件' -f $miss, $total)
        } else {
            $card.Dot.ForeColor = $Pal.Err
            $card.Value.Text = ('FOD: ' + $fod + $fodTag)
            $card.Sub.Text   = '需要补全环境'
        }
    } catch {
        $card = $script:Cards[1]; $card.Dot.ForeColor = $Pal.Hint; $card.Value.Text = '需管理员'; $card.Sub.Text = ''
    }

    try {
        $dlls = $d.DllScan
        $has = @{}
        foreach ($x in @($dlls)) { if ($x) { $has[[string]$x.Name] = [bool]$x.Exists } }
        $ok = ($has['dwm.exe'] -and $has['dcomp.dll'] -and $has['dwrite.dll'])
        $card = $script:Cards[2]
        $card.Dot.ForeColor = $(if ($ok) { $Pal.Ok } else { $Pal.Err })
        $card.Value.Text = $(if ($ok) { '已就绪' } else { '未就绪' })
        $card.Sub.Text   = ('dwm={0} dcomp={1} dwrite={2}' -f (Format-Bool $has['dwm.exe']), (Format-Bool $has['dcomp.dll']), (Format-Bool $has['dwrite.dll']))
    } catch { }

    try {
        $dn = $d.DotNet
        $card = $script:Cards[3]
        $card.Dot.ForeColor = $(if ($dn.Frameworks.Count -gt 0) { $Pal.Ok } else { $Pal.Warn })
        $card.Value.Text = ('{0} 个框架' -f $dn.Frameworks.Count)
        $top = @($dn.Frameworks | Where-Object { $_.Name -eq 'Microsoft.NETCore.App' } | Sort-Object Version -Descending | Select-Object -First 1)
        $card.Sub.Text = $(if ($top.Count -gt 0) { 'NETCore.App ' + $top[0].Version } else { '.NET 程序会报缺运行时' })
    } catch { }

    try {
        $s2 = $d.Sessions
        $card = $script:Cards[4]
        $card.Dot.ForeColor = $(if ($s2.LoggedOnCount -gt 0) { $Pal.Ok } else { $Pal.Err })
        $card.Value.Text = ('已登录 {0} 个' -f $s2.LoggedOnCount)
        try {
            $a = $d.AutoLogon
            $card.Sub.Text = $(if ($a.Enabled) { '自动登录: 已启用' } else { '自动登录: 未启用' })
        } catch { $card.Sub.Text = '' }
    } catch { }

    try {
        $u = $d.Uac
        $card = $script:Cards[5]
        $card.Dot.ForeColor = $(if ($u.PromptsWillBlock) { $Pal.Warn } else { $Pal.Ok })
        $card.Value.Text = $(if ($u.PromptsWillBlock) { '会弹确认窗' } else { '不会拦截' })
        $card.Sub.Text   = $(if ($u.PromptsWillBlock) { '无人值守时装软件可能失败' } else { '' })
    } catch { }

    try {
        # 用 -SkipProbe：卡片刷新很频繁，不要每次都等 HTTP 探测
        $wac = $d.Wac
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

# ---------------- 环境探测：放后台进程，界面线程不做任何阻塞查询 ----------------
# 实测（Server Core 2025）：一次同步探测要 5~6.5 秒 —— 其中 DISM 查 FOD 状态 3.7 秒、
# 组件扫描 0.3 秒、.NET/会话/自动登录/UAC 约 0.65 秒。放在界面线程上就是「窗口出现了但点不动」。
# 现在改成：子进程探测 → 分两次写 JSON（fast / full）→ 界面定时读文件刷新卡片。
$script:StateDir       = Join-Path $toolRoot 'state'
$script:ProbeOutFile   = Join-Path $script:StateDir 'probe.json'
$script:ProbeCacheFile = Join-Path $script:StateDir 'env-cache.json'
$script:ProbeProc      = $null
$script:ProbeStamp     = ''
$script:ProbeRunning   = $false

function Initialize-EnvProbePaths {
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
}

function Initialize-EnvCards {
    if ($script:Cards.Count -gt 0) { return }
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

function Set-EnvCardsPending {
    Initialize-EnvCards
    foreach ($c in $script:Cards) {
        $c.Dot.ForeColor = $Pal.Hint
        $c.Value.Text    = '探测中…'
        $c.Sub.Text      = ''
    }
}

function Read-EnvProbeResult {
    param([switch]$FromCache)
    $f = $(if ($FromCache) { $script:ProbeCacheFile } else { $script:ProbeOutFile })
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $json = Get-Content -LiteralPath $f -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

function Start-EnvProbe {
    # 只负责起进程 + 起定时器；卡片显示由调用方决定（有旧数据就先显示旧数据）
    Initialize-EnvProbePaths
    if ($script:ProbeRunning) { return }
    $script:ProbeRunning = $true
    $script:ProbeStamp   = ''
    try { if (Test-Path -LiteralPath $script:ProbeOutFile) { Remove-Item -LiteralPath $script:ProbeOutFile -Force } } catch { }
    try {
        $probe = Join-Path $guiDir 'Run-GuiReadyProbe.ps1'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $probe + '"'),
                     '-OutFile', ('"' + $script:ProbeOutFile + '"'),
                     '-CacheFile', ('"' + $script:ProbeCacheFile + '"'))
        $script:ProbeProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden
        $script:ProbeTimer.Start()
        Append-GuiLog -Line '[INFO] 环境探测已在后台开始，卡片会自动刷新（期间界面照常可操作）。'
    } catch {
        $script:ProbeRunning = $false
        Append-GuiLog -Line ('[WARN] 后台探测启动失败，退回同步探测: ' + $_.Exception.Message)
        Update-EnvCards -Force
    }
}

function Update-EnvCardsFromProbe {
    # 探测进程可能意外退出（没写出任何文件）—— 超过 90 秒就放弃，别让界面永远停在“探测中”
    if ($script:ProbeRunning -and $script:ProbeProc) {
        try {
            $script:ProbeProc.Refresh()
            if (((Get-Date) - $script:ProbeProc.StartTime).TotalSeconds -gt 90) {
                $script:ProbeRunning = $false
                try { $script:ProbeTimer.Stop() } catch { }
                Append-GuiLog -Line '[WARN] 后台探测 90 秒没出结果，已放弃（可点「环境探测」重试）。'
                return
            }
        } catch { }
    }
    if (-not (Test-Path -LiteralPath $script:ProbeOutFile)) { return }
    $obj = Read-EnvProbeResult
    if (-not $obj) { return }
    $stamp = ([string]$obj.Stage + '|' + [string]$obj.Stamp)
    if ($stamp -eq $script:ProbeStamp) { return }
    $script:ProbeStamp = $stamp
    Update-EnvCards -Data $obj
    if ([string]$obj.Stage -eq 'fast') {
        Append-GuiLog -Line '[INFO] 环境卡片已刷新（快照；FOD 状态是组件推断值，精确结果稍后到）。'
    } else {
        $script:ProbeRunning = $false
        try { $script:ProbeTimer.Stop() } catch { }
        Append-GuiLog -Line '[INFO] 环境探测完成（含 FOD 精确状态与 WAC 状态）。'
        # 探测回来的 WAC 状态会决定工具页那组要不要隐藏
        try { Update-WacToolGroup } catch { }
    }
}

function Refresh-EnvCards {
    # 自检 / 布局诊断要的是同步、真实的数据，不能起后台进程
    if ($SelfTest -or $LayoutDump) { Update-EnvCards -Force; return }
    # 切到「环境」页：先用后台/缓存里的数据渲染，绝不在这里做同步探测
    $obj = Read-EnvProbeResult
    if (-not $obj) { $obj = Read-EnvProbeResult -FromCache }
    if ($obj) { Update-EnvCards -Data $obj; return }
    if (-not $script:ProbeRunning) { Set-EnvCardsPending; Start-EnvProbe } else { Set-EnvCardsPending }
}

$script:ProbeTimer = New-Object System.Windows.Forms.Timer
$script:ProbeTimer.Interval = 500
$script:ProbeTimer.Add_Tick({ Update-EnvCardsFromProbe })

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
        # 必填项在标签后面加个 * —— 与 Start-GuiAction 开跑前的校验是同一套标记（Req）
        $req = ($pd.ContainsKey('Req') -and [bool]$pd.Req)
        $lbText = [string]$pd.Label
        if ($req) { $lbText = $lbText + '  *' }
        $lb = New-Label -Text $lbText -Size 9 -Color $(if ($req) { 'Accent3' } else { 'SubText' })
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
        # 深色主题：这些是系统原生控件（ComboBox/TextBox/CheckBox），不设颜色就是白的。
        # 主题覆盖自检会盯着这一条，漏了会在界面上留白块。
        try {
            $ctl.BackColor = $Pal.Sunken
            $ctl.ForeColor = $Pal.Text
            if ($ctl -is [System.Windows.Forms.CheckBox]) {
                $ctl.BackColor = $Pal.Bg
                $ctl.ForeColor = $Pal.Text
            }
        } catch { }
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
            # ⚠ .GetNewClosure()：这段代码在**函数**里，而 PowerShell 的事件回调不是闭包，
            # 不加的话 $kind / $target 在点击时都会解析成 $null（点了没反应或直接抛异常）。
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
            }.GetNewClosure())
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

function Set-ParamValues {
    # 与 Get-ParamValues 对称：按参数名把值写回控件。
    # Combo 传 1 基索引，Check 传布尔，其余当文本。
    # 「商店」页点安装时用它把包名/源填进表单，这样「更多」页看到的和实际跑的一致。
    param([hashtable]$Values = @{})
    foreach ($k in $Values.Keys) {
        if (-not $script:ParamControls.ContainsKey($k)) { continue }
        if ($null -eq $Values[$k]) { continue }
        $ctl = $script:ParamControls[$k]
        try {
            if ($ctl -is [System.Windows.Forms.ComboBox]) { $ctl.SelectedIndex = [int]$Values[$k] - 1 }
            elseif ($ctl -is [System.Windows.Forms.CheckBox]) { $ctl.Checked = [bool]$Values[$k] }
            else { $ctl.Text = [string]$Values[$k] }
        } catch { }
    }
}

function Close-GuiOutReader {
    if ($script:OutReader) { try { $script:OutReader.Dispose() } catch { } }
    $script:OutReader     = $null
    $script:OutReaderPath = ''
}

function Read-GuiNewOutput {
    # 只读“上次之后新增的行”，不再每次读整个文件。
    # 以前是每 400ms 用 Get-Content 读整个 stdout：实测 3 万行（2.5 MB）一次要 190~330ms，
    # 而 WAC 安装这类长任务会把输出写到几 MB —— 界面线程一半以上时间在读文件，越跑越卡直到假死。
    if (-not $script:OutFile) { return }
    if (-not (Test-Path -LiteralPath $script:OutFile)) { return }
    if ($null -eq $script:OutReader -or $script:OutReaderPath -ne $script:OutFile) {
        Close-GuiOutReader
        try {
            # FileShare.ReadWrite：允许 runner 继续写这个文件
            $fs = New-Object System.IO.FileStream($script:OutFile, [System.IO.FileMode]::Open,
                                                  [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $script:OutReader     = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $script:OutReaderPath = $script:OutFile
        } catch {
            Close-GuiOutReader
            return
        }
    }
    $added = 0
    try {
        while (-not $script:OutReader.EndOfStream) {
            $line = $script:OutReader.ReadLine()
            if ($null -eq $line) { break }
            Append-GuiLog -Line $line
            $added++
            if ($added -ge 300) { break }   # 一次最多追加 300 行，剩下的下个 tick 继续（不让界面被刷爆）
        }
    } catch { }
}

function Finish-GuiAction {
    param([int]$ExitCode = -999)
    $script:Timer.Stop()
    # 动作结束后把剩下没读的输出读干净（单次上限 300 行，所以循环几轮）
    for ($i = 0; $i -lt 40; $i++) {
        Read-GuiNewOutput
        if (-not $script:OutReader -or $script:OutReader.EndOfStream) { break }
    }
    Close-GuiOutReader
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

    # 清掉这次动作的临时目录：里面的 args.json 含**全部参数**，自动登录那类动作的密码就在里面。
    # 读到 stdout/stderr 之后才删，所以不受影响（runner 自己也会在解析完参数后立刻删 args.json）。
    if ($script:ActionTempDir) {
        try { Remove-Item -LiteralPath $script:ActionTempDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        $script:ActionTempDir = ''
    }

    $btnFill.Enabled = $true
    $btnRun.Enabled = $true
    $script:Proc = $null
    Clear-EnvCache          # 动作可能改了环境状态
    # 只有正在看「环境」页时才重新探测；探测在后台跑，界面不卡
    if ($script:CurrentPage -eq 'env') { Start-EnvProbe }
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
    # UI 审计模式：只走一遍回调，不真的执行动作（审计要能安全地"点"每一个按钮）
    if ($script:AuditMode) {
        Append-GuiLog -Line ('[INFO] 审计模式：跳过执行 ' + $script:CurrentAction.Id)
        return
    }
    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请先等它结束或点“停止当前动作”。', '提示', 'OK', 'Information') | Out-Null
        return
    }

    $P = Get-ParamValues
    $P['DryRun'] = [bool]$DryRun

    # 必填项校验：空值直接跑下去，动作脚本会以"参数绑定失败"收场，
    # 用户看到的就是一句英文报错（还以为功能坏了）。这里先拦住，明确说缺什么。
    $missing = @()
    foreach ($pd in @($script:CurrentAction.Params)) {
        if (-not ($pd.ContainsKey('Req') -and [bool]$pd.Req)) { continue }
        $n = [string]$pd.Name
        $v = ''
        if ($P.ContainsKey($n)) { $v = [string]$P[$n] }
        if ([string]::IsNullOrWhiteSpace($v)) { $missing += ('· ' + [string]$pd.Label) }
    }
    if ($missing.Count -gt 0) {
        try {
            [System.Windows.Forms.MessageBox]::Show($form,
                ("还有必填项没有填：`r`n`r`n" + ($missing -join "`r`n") + "`r`n`r`n填好之后再点一次运行。"),
                '缺少参数', 'OK', 'Warning') | Out-Null
        } catch { }
        Append-GuiLog -Line ('[WARN] 没有运行：缺少必填项 ' + (($missing -replace '^· ', '') -join '、'))
        return
    }

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tmpDir = Join-Path $env:TEMP ('gui-ready-' + $stamp)
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $script:ActionTempDir = $tmpDir    # 动作结束后整目录删除（args.json 里可能有密码）
    $argsFile = Join-Path $tmpDir 'args.json'
    $script:OutFile    = Join-Path $tmpDir 'stdout.txt'
    $script:ErrFile    = Join-Path $tmpDir 'stderr.txt'
    $script:RunLogFile = Join-Path (Join-Path $toolRoot 'logs') ('gui-{0}-{1}.log' -f $script:CurrentAction.Id, $stamp)
    try {
        [System.IO.File]::WriteAllText($argsFile, ($P | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding -ArgumentList $true))
    } catch {
        Append-GuiLog -Line ('[ERROR] 参数序列化失败: ' + $_.Exception.Message); return
    }

    Close-GuiOutReader          # 新动作会写新的 stdout.txt，重新开流从头读
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
    if ($script:AuditMode) { Append-GuiLog -Line ('[INFO] 审计模式：跳过启动 ' + [string]$Item.Name); return }
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

# ============================ 关于页 ============================

$pageAbout             = New-Object System.Windows.Forms.Panel
$pageAbout.Dock        = 'Fill'
$pageAbout.BackColor   = $Pal.Bg
$script:Pages['about'] = $pageAbout
$pnlContent.Controls.Add($pageAbout)

$lblAboutHead          = New-Label -Text '关于' -Size 14 -Style Bold
$lblAboutHead.Location = New-Object System.Drawing.Point(2, 2)
$pageAbout.Controls.Add($lblAboutHead)

$lblAboutDesc          = New-Label -Text 'Server Core GUI 就绪工具 —— 让带界面的程序在 Windows Server Core 上真正跑起来。' -Size 9.5 -Color SubText
$lblAboutDesc.Location = New-Object System.Drawing.Point(3, 28)
$pageAbout.Controls.Add($lblAboutDesc)

$cardAbout              = New-Card -Width 900 -Height 250 -Radius 12
$cardAbout.Location     = New-Object System.Drawing.Point(0, 56)
# 不用 Anchor 拉伸：页面在创建时的宽度还不是最终宽度，Anchor 会按"创建时 → 最终"的
# 差值一路把卡片拉宽（实测拉到 1916，直接越界）。宽度统一交给 Update-PageLayout 算。
$cardAbout.Anchor       = 'Top,Left'
$pageAbout.Controls.Add($cardAbout)

$lblAuAuthor           = New-Label -Text '作者：mmm' -Size 10 -Style Bold
$lblAuAuthor.Location  = New-Object System.Drawing.Point(20, 16)
$cardAbout.Controls.Add($lblAuAuthor)

$lblAuQQ               = New-Label -Text 'QQ 群：1034243331' -Size 10
$lblAuQQ.Location      = New-Object System.Drawing.Point(20, 46)
$cardAbout.Controls.Add($lblAuQQ)

$lblAuVer              = New-Label -Text ('版本：v1.0    构建 ' + (Get-Date -Format 'yyyy-MM-dd')) -Size 10
$lblAuVer.Location     = New-Object System.Drawing.Point(20, 76)
$cardAbout.Controls.Add($lblAuVer)

$lblAuGitTag           = New-Label -Text 'GitHub：' -Size 10 -Color Hint
$lblAuGitTag.Location  = New-Object System.Drawing.Point(20, 106)
$cardAbout.Controls.Add($lblAuGitTag)

$lnkAuGit              = New-Object System.Windows.Forms.LinkLabel
$lnkAuGit.Text         = 'https://github.com/OrangeArtc0915/Server-core-manager'
$lnkAuGit.Font         = New-Font -Size 10
$lnkAuGit.AutoSize     = $true
$lnkAuGit.LinkColor    = $Pal.Accent2
$lnkAuGit.ActiveLinkColor = $Pal.Accent1
$lnkAuGit.LinkBehavior = 'HoverUnderline'
$lnkAuGit.Location     = New-Object System.Drawing.Point(90, 106)
$lnkAuGit.Add_LinkClicked({ Open-GuiUrl 'https://github.com/OrangeArtc0915/Server-core-manager' })
$cardAbout.Controls.Add($lnkAuGit)

$lblAuSiteTag          = New-Label -Text '项目主页：' -Size 10 -Color Hint
$lblAuSiteTag.Location = New-Object System.Drawing.Point(20, 136)
$lblAuSiteTag.Width    = 64
$cardAbout.Controls.Add($lblAuSiteTag)

$lnkAuSite             = New-Object System.Windows.Forms.LinkLabel
$lnkAuSite.Text        = 'https://orangeartc0915.github.io/Server-core-manager/'
$lnkAuSite.Font        = New-Font -Size 10
$lnkAuSite.AutoSize    = $true
$lnkAuSite.LinkColor   = $Pal.Accent2
$lnkAuSite.ActiveLinkColor = $Pal.Accent1
$lnkAuSite.LinkBehavior = 'HoverUnderline'
# 108 而不是 90：左边「项目主页：」这个 Label 实际宽 79（AutoSize），90 会压住 9px
#（UI 审计抓到的重叠；标签是 AutoSize 的，改它的 Width 没用）
$lnkAuSite.Location    = New-Object System.Drawing.Point(108, 136)
$lnkAuSite.Add_LinkClicked({ Open-GuiUrl 'https://orangeartc0915.github.io/Server-core-manager/' })
$cardAbout.Controls.Add($lnkAuSite)

$lblAuTips             = New-Label -Text '用着有问题、或者想要哪个功能：到 QQ 群里说一声。工具里所有“实测”结论都来自真机验证。' -Size 9.5 -Color SubText
$lblAuTips.Location    = New-Object System.Drawing.Point(20, 168)
$cardAbout.Controls.Add($lblAuTips)

$btnAuGit              = New-FlatButton -Text '打开 GitHub' -Width 130 -Height 34
$btnAuGit.Location     = New-Object System.Drawing.Point(20, 196)
$btnAuGit.Add_Click({ Open-GuiUrl 'https://github.com/OrangeArtc0915/Server-core-manager' })
$cardAbout.Controls.Add($btnAuGit)

$btnAuSite             = New-FlatButton -Text '打开项目主页' -Width 130 -Height 34
$btnAuSite.Location    = New-Object System.Drawing.Point(160, 196)
$btnAuSite.Add_Click({ Open-GuiUrl 'https://orangeartc0915.github.io/Server-core-manager/' })
$cardAbout.Controls.Add($btnAuSite)

$btnAuLog              = New-FlatButton -Text '打开日志目录' -Width 130 -Height 34
$btnAuLog.Location     = New-Object System.Drawing.Point(300, 196)
$btnAuLog.Add_Click({ Open-GuiFolder -Path (Join-Path $toolRoot 'logs') -Label '日志目录' })
$cardAbout.Controls.Add($btnAuLog)

$btnAuRep              = New-FlatButton -Text '打开报告目录' -Width 130 -Height 34
$btnAuRep.Location     = New-Object System.Drawing.Point(440, 196)
$btnAuRep.Add_Click({ Open-GuiFolder -Path (Join-Path $toolRoot 'reports') -Label '报告目录' })
$cardAbout.Controls.Add($btnAuRep)

# ============================ 退出时自动打开终端 ============================
# 行为（用户确认的结论）：点「退出（打开终端）」按钮、按 Esc、或直接点窗口 X —— 三种关闭方式**统一**：
#   装了美化终端 → 起 scm-term（UTF-8 + Nerd Font + oh-my-posh 的美化 PowerShell）
#   没装         → 起普通 PowerShell（-NoExit，工作目录为工具目录）
# 不弹的情况：
#   - -SelfTest / -LayoutDump（自检与布局诊断，弹窗会干扰）
#   - Session 0（没有桌面，弹不出来，只在日志里留一行）

$script:ExitShellOpened = $false

function Get-GuiExitShell {
    # 优先美化终端；找不到就退回普通 PowerShell
    $o = [ordered]@{ Kind = 'PowerShell'; File = 'powershell.exe'; Args = @('-NoLogo', '-NoExit'); WorkDir = $toolRoot }
    foreach ($c in @((Join-Path $toolRoot 'bin\scm-term.cmd'),
                     (Join-Path (Join-Path $env:windir 'System32') 'scm-term.cmd'))) {
        if (Test-Path -LiteralPath $c) {
            $o.Kind    = '美化终端 scm-term'
            $o.File    = $c
            $o.Args    = @()
            $o.WorkDir = $toolRoot
            break
        }
    }
    return [pscustomobject]$o
}

function Open-GuiExitShell {
    param([switch]$Quiet)
    if ($script:ExitShellOpened) { return }      # 三个入口只弹一次
    $script:ExitShellOpened = $true
    if ($SkipPageHooks) { return }
    $sess = 0
    try { $sess = (Get-Process -Id $PID).SessionId } catch { }
    if ($sess -le 0) {
        if (-not $Quiet) { Append-GuiLog '[INFO] 当前是 Session 0，没有桌面，跳过自动打开终端。' }
        return
    }
    $sh = Get-GuiExitShell
    try {
        $wd = [string]$sh.WorkDir
        if (-not $wd -or -not (Test-Path -LiteralPath $wd)) { $wd = $toolRoot }
        if (@($sh.Args).Count -gt 0) {
            Start-Process -FilePath $sh.File -ArgumentList $sh.Args -WorkingDirectory $wd | Out-Null
        } else {
            Start-Process -FilePath $sh.File -WorkingDirectory $wd | Out-Null
        }
        if (-not $Quiet) { Append-GuiLog ('[OK] 已自动打开 ' + $sh.Kind + '。') }
    } catch {
        if (-not $Quiet) { Append-GuiLog ('[WARN] 自动打开终端失败: ' + $_.Exception.Message) }
    }
}

function Exit-ToCommandLine {
    if ($script:Proc) {
        try { Stop-Process -Id $script:Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    try { $script:Timer.Stop(); $script:Timer.Dispose() } catch { }
    try { $script:ProbeTimer.Stop(); $script:ProbeTimer.Dispose() } catch { }
    try { $script:StoreTimer.Stop(); $script:StoreTimer.Dispose() } catch { }
    try { $script:RoleTimer.Stop(); $script:RoleTimer.Dispose() } catch { }
    foreach ($q in @($script:QMon, $script:QSec, $script:QDsh, $script:QStoreInfo)) { if ($q) { Close-GuiQueryHost -Query $q } }
    Open-GuiExitShell -Quiet
    $form.Close()
}

$btnExitBack.Add_Click({ Exit-ToCommandLine })
$form.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Exit-ToCommandLine }
})

# 点窗口 X / Alt+F4：也自动弹终端。这里**不**动后台 runner —— 关窗不该打断正在跑的任务
# （任务日志会继续写到 logs\，重开界面能接着看）。
$form.Add_FormClosing({
    Open-GuiExitShell -Quiet
})

# ============================ 启动 ============================
Add-BootTrace '全部控件创建完成'

function Layout-Shell {
    # 窗口尺寸变了就重算外壳：留白宽度、卡片圆角、标题栏右侧按钮的位置。
    # 最大化时留白归零（否则窗口边框会有一圈缝），圆角也归零（贴屏不该有圆角）。
    try {
        $maxed = $false
        try { $maxed = ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized) } catch { }
        $m = 0
        if (-not $maxed) { $m = $script:ShellMargin }
        if ($script:UiTypesReady) {
            try { $form.ResizeBand = $(if ($maxed) { 0 } else { 10 }) } catch { }
        }

        $cs = $form.ClientSize
        $rad = $(if ($maxed) { 0 } else { $script:ShellRadius })
        $pnlShell.Bounds = New-Object System.Drawing.Rectangle($m, $m,
            [Math]::Max(240, ($cs.Width  - 2 * $m)),
            [Math]::Max(160, ($cs.Height - 2 * $m)))
        if ($pnlShell.Tag) { $pnlShell.Tag.Radius = $rad }
        Set-Rounded -Control $pnlShell -Radius $rad
        $pnlShell.Invalidate()

        # 标题栏右侧：窗口按钮从右往左排，退出按钮在它们左边
        $right = $pnlTitle.ClientSize.Width - 10
        $top   = [int](($pnlTitle.ClientSize.Height - 32) / 2)
        foreach ($b in @($btnWinClose, $btnWinMax, $btnWinMin)) {
            if (-not $b) { continue }
            $right -= ($b.Width + 2)
            $b.Location = New-Object System.Drawing.Point($right, $top)
        }
        $right -= 14
        if ($btnExitBack) {
            $btnExitBack.Location = New-Object System.Drawing.Point(($right - $btnExitBack.Width), ($top + 1))
        }
    } catch { }
}

function Update-Chrome {
    Layout-Shell
    Set-Rounded -Control $pnlLog -Radius 10
    try { $pnlLog.Invalidate() } catch { }
    Update-PageLayout
}

# 启动时不再同步查卡片数据（那会在界面线程上跑 5~6.5 秒）。
# 顺序：先用上次的探测缓存秒显 → 再起后台探测 → 结果回来了自动刷新。
$form.Add_Shown({
    Add-BootTrace '窗口可见（Shown 触发）'
    $script:LayoutSuspended = $true        # 先挂起布局，等工作都做完再统一算一次
    Update-Chrome
    $first = $StartPage
    if (-not $script:Pages.ContainsKey($first)) { $first = 'env' }
    Show-GuiPage -Key $first -SkipCards
    # 工具页的路径解析（21 个工具）挪到真正要看工具页时再做，别拖慢启动
    if ($script:CurrentPage -eq 'tool') { Update-ToolButtons }
    Update-WacToolGroup
    Load-Programs
    Refresh-ProgramList
    Append-GuiLog -Line ('Server Core GUI 就绪工具已启动  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Append-GuiLog -Line ('工具目录: ' + $toolRoot)

    # 安全前提检查：本工具的一切都以管理员/SYSTEM 身份执行，工具目录必须只有管理员能写。
    # 解压到桌面/下载目录再提权运行是常见做法，但那样同机普通用户就能替换我们的脚本/计划任务 →
    # 直接拿到管理员权限。这里如实报出来，并把提权 worker 目录收紧。
    #
    # 弹窗的处理见本段末尾的 $script:PendingDirWarning：
    #   - **不能**在这里弹：Shown 里后面还有卡片刷新等初始化，模态框会把它们全卡住，
    #     看起来就像"界面开了但没反应"（实测被误当成打不开）；
    #   - **必须**带 owner（$form）：不带 owner 的 MessageBox 会跑到主窗口后面，用户根本看不见。
    $script:PendingDirWarning = ''
    try {
        $dirSafe = Test-GuiReadyToolDirSafe -Path $toolRoot
        if ($dirSafe.Known -and $dirSafe.Safe) {
            # 目录本身安全时，顺手把包含提权 worker 与备份的目录再收紧一层
            if (Test-IsAdministrator) {
                [void](Protect-GuiReadyDir -Path (Join-Path $toolRoot 'logs'))
                [void](Protect-GuiReadyDir -Path (Join-Path $toolRoot 'backup'))
            }
        } else {
            Append-GuiLog -Line '[WARN] ==== 安全提示：工具目录不是管理员独占 ===='
            if ($dirSafe.Reason) { Append-GuiLog -Line ('[WARN] ' + $dirSafe.Reason) }
            Append-GuiLog -Line '[WARN] 本工具以管理员（部分步骤以 SYSTEM）身份运行，工具目录可被普通用户写入，'
            Append-GuiLog -Line '[WARN] 等于给他们一条提权通道：替换 lib/gui 下的脚本、bin 下的 .cmd（cmd 的 AutoRun 会跑它）、'
            Append-GuiLog -Line '[WARN] 或抢占提权用的 worker 脚本。建议把工具移到 C:\Program Files\ServerCoreManager，'
            Append-GuiLog -Line '[WARN] 或收紧该目录权限：icacls "<工具目录>" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F"'
            Append-GuiLog -Line '[WARN] 提权 worker 已自动改用 %ProgramData%\ServerCoreManager\elevated 存放。'
            $script:PendingDirWarning = [string]$dirSafe.Reason
        }
    } catch { }

    # 完整性：发布包里带 manifest.sha256，用它核对"文件有没有被改过"（开发检出没有清单，跳过）
    try {
        if (Test-Path -LiteralPath (Join-Path $toolRoot 'manifest.sha256')) {
            $man = Test-GuiReadyManifest -Root $toolRoot
            if ($man.Ok) {
                Append-GuiLog -Line ('[INFO] 完整性清单核对通过（{0} 个文件与发布时一致）。' -f $man.Count)
            } else {
                Append-GuiLog -Line '[WARN] ==== 完整性告警：工具有文件与发布清单不一致 ===='
                foreach ($x in $man.Modified) { Append-GuiLog -Line ('[WARN] 被改过: ' + $x) }
                foreach ($x in $man.Missing)  { Append-GuiLog -Line ('[WARN] 缺失: ' + $x) }
                foreach ($x in $man.Extra)    { Append-GuiLog -Line ('[WARN] 清单外新增的脚本: ' + $x) }
                Append-GuiLog -Line '[WARN] 如果不是你自己改的，这份工具可能被人动过 —— 建议从发布页重新下载并核对 SHA256。'
            }
        }
    } catch { }
    Append-GuiLog -Line '左侧「环境」用于补全；「软件」管理你要跑的程序；「工具」打开系统自带图形工具；完整能力在「更多」。'
    Append-GuiLog -Line '关闭本窗口会自动打开终端（装了美化终端就是 scm-term）。'
    # 卡片：有上次结果就先显示，然后后台刷新
    $cache = Read-EnvProbeResult -FromCache
    if ($cache) {
        Update-EnvCards -Data $cache
        Append-GuiLog -Line '[INFO] 卡片先用上次探测结果，正在后台刷新…'
    } else {
        Set-EnvCardsPending
    }
    Start-EnvProbe
    $script:LayoutSuspended = $false
    Update-PageLayout
    Add-BootTrace 'Shown 处理完成（可交互）'

    # 安全提示弹窗放在最后：界面已经初始化完、也不会挡着初始化。
    # 带 owner（$form）才会显示在主窗口上面；同一个原因只在第一次提示（状态存 state\dir-warning.txt），
    # 免得每次启动都弹一次把人烦到、或者被误当成"卡住了"。
    if ($script:PendingDirWarning) {
        $warnFile = Join-Path (Join-Path $toolRoot 'state') 'dir-warning.txt'
        $lastWarn = ''
        try { if (Test-Path -LiteralPath $warnFile) { $lastWarn = [string](Get-Content -LiteralPath $warnFile -Raw -ErrorAction SilentlyContinue) } } catch { }
        if ($lastWarn.Trim() -ne $script:PendingDirWarning.Trim()) {
            try {
                [void][System.Windows.Forms.MessageBox]::Show($form,
                    ("检测到工具目录不是管理员独占，存在提权风险：`r`n`r`n" + $script:PendingDirWarning +
                     "`r`n`r`n本工具以管理员（部分步骤以 SYSTEM）身份运行，工具目录可被普通用户写入就等于给出一条提权通道。`r`n`r`n" +
                     "建议把工具移到 C:\Program Files\ServerCoreManager 下，或按日志里的 icacls 命令收紧权限。`r`n`r`n" +
                     "（提权 worker 已自动改用 %ProgramData% 存放；这条提示同一个原因只弹一次，日志里每次都会写）"),
                    '安全提示', 'OK', 'Warning')
            } catch { }
            try {
                if (-not (Test-Path -LiteralPath (Split-Path -Parent $warnFile))) { New-Item -ItemType Directory -Path (Split-Path -Parent $warnFile) -Force | Out-Null }
                [System.IO.File]::WriteAllText($warnFile, $script:PendingDirWarning, (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
        }
    }
})

$form.Add_Resize({ Update-Chrome })

if ($UiAudit) {
    # ---------------- UI 审计 ----------------
    # 为什么要有它：SelfTest 只验证"页面能渲染"，但用户真正遇到的是**点进去**才炸
    #（进页面走的是 Show-*Page、点动作走的是 Select-GuiAction 重建参数控件，这两条路径
    #  以前只在真人操作时才跑到）。这里把 11 个页面、45 个动作全部走一遍，只建界面不执行，
    # 再把每个页面的同级控件两两求交集，抓"这块压住那块"。
    $auditFail = 0
    $auditNotes = New-Object System.Collections.ArrayList

    # 必须先把窗口真的显示出来：不显示的话所有控件的 Visible 都是 false，
    # 重叠扫描会"扫描 0 个控件、无重叠"—— 假通过（实测第一版就是这样）。
    try { $form.Show(); [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 400 } catch { }

    Write-Host ''
    Write-Host '=== 1) 进入每个页面 ===' -ForegroundColor Cyan
    foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'tool', 'more', 'about')) {
        try {
            Show-GuiPage -Key $k
            [System.Windows.Forms.Application]::DoEvents()
            Write-Host ('  {0,-9} OK' -f $k) -ForegroundColor Green
        } catch {
            $auditFail++
            Write-Host ('  {0,-9} !! {1}' -f $k, $_.Exception.Message) -ForegroundColor Red
            Write-Host ('      at ' + (($_.ScriptStackTrace -split "`n")[0])) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '=== 2) 进入每个动作（只构建参数界面，不执行）===' -ForegroundColor Cyan
    foreach ($act in $script:Actions) {
        try {
            Select-GuiAction -Action $act
            [System.Windows.Forms.Application]::DoEvents()
            # 注意：$script:ParamControls 是哈希表，直接用 .Count 会被"名为 Count 的参数"顶掉
            # （autologon-enable 就有一个叫 Count 的参数，实测踩到），必须走 .Keys
            $n = @($script:ParamControls.Keys).Count
            $want = @($act.Params).Count
            $flag = $(if ($n -eq $want) { 'OK' } else { '控件数不符' })
            if ($n -ne $want) { $auditFail++; [void]$auditNotes.Add(('{0}: 参数 {1} 个，实际建出 {2} 个' -f $act.Id, $want, $n)) }
            Write-Host ('  {0,-20} 参数 {1}/{2} {3}' -f $act.Id, $n, $want, $flag) -ForegroundColor $(if ($n -eq $want) { 'Green' } else { 'Yellow' })
        } catch {
            $auditFail++
            Write-Host ('  {0,-20} !! {1}' -f $act.Id, $_.Exception.Message) -ForegroundColor Red
            Write-Host ('      at ' + (($_.ScriptStackTrace -split "`n")[0])) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '=== 3) 控件重叠扫描（同级控件两两求交集）===' -ForegroundColor Cyan
    foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'tool', 'more', 'about')) {
        # 必须先把这一页切成当前页：非当前页整页 Visible=false，同级扫描会一个控件都取不到
        #（第一版就是这样，11 页全报"无重叠"—— 假通过）
        try { Show-GuiPage -Key $k -SkipCards:$true; [System.Windows.Forms.Application]::DoEvents() } catch { }
        $page = $script:Pages[$k]
        if (-not $page) { continue }
        $pairs = New-Object System.Collections.ArrayList
        $scanned = 0
        $stack = New-Object System.Collections.Stack
        $stack.Push($page)
        while ($stack.Count -gt 0) {
            $parent = $stack.Pop()
            try { foreach ($c in $parent.Controls) { $stack.Push($c) } } catch { }
            $kids = @()
            try { foreach ($c in $parent.Controls) { if ($c.Visible -and $c.Width -gt 4 -and $c.Height -gt 4) { $kids += $c } } } catch { }
            $scanned += $kids.Count
            for ($i = 0; $i -lt $kids.Count; $i++) {
                for ($j = $i + 1; $j -lt $kids.Count; $j++) {
                    $a = $kids[$i]; $b = $kids[$j]
                    $ix = [Math]::Max($a.Left, $b.Left)
                    $iy = [Math]::Max($a.Top, $b.Top)
                    $ax = [Math]::Min($a.Right, $b.Right)
                    $ay = [Math]::Min($a.Bottom, $b.Bottom)
                    $ow = $ax - $ix; $oh = $ay - $iy
                    if ($ow -gt 4 -and $oh -gt 4) {
                        $an = ([string]$a.Text -replace "`r?`n", ' ')
                        $bn = ([string]$b.Text -replace "`r?`n", ' ')
                        if ($an.Length -gt 14) { $an = $an.Substring(0, 14) }
                        if ($bn.Length -gt 14) { $bn = $bn.Substring(0, 14) }
                        [void]$pairs.Add(('{0}({1},{2},{3}x{4}) × {5}({6},{7},{8}x{9}) 交叠 {10}x{11}' -f `
                            $a.GetType().Name, $a.Left, $a.Top, $a.Width, $a.Height,
                            $b.GetType().Name, $b.Left, $b.Top, $b.Width, $b.Height, $ow, $oh))
                    }
                }
            }
        }
        if ($pairs.Count -eq 0) {
            Write-Host ('  {0,-9} 扫描 {1} 个同级控件，无重叠' -f $k, $scanned) -ForegroundColor Green
        } else {
            $auditFail++
            Write-Host ('  {0,-9} 扫描 {1} 个控件，{2} 处重叠:' -f $k, $scanned, $pairs.Count) -ForegroundColor Red
            $pairs | Select-Object -First 6 | ForEach-Object { Write-Host ('      ' + $_) -ForegroundColor Yellow }
        }
    }

    Write-Host ''
    Write-Host '=== 4) 全量按钮点击 + 下拉切换（真正调一遍回调）===' -ForegroundColor Cyan
    # 除"会启动外部程序 / 弹文件选择框 / 会改系统"的按钮外，**全部点一遍**。
    # 动作用 $script:AuditMode 挡住（只记日志不执行），所以点"执行"也不会动系统。
    $script:AuditMode = $true
    $skipTexts = @('打开', '启动', '运行', '执行', '安装', '卸载', '修复', '还原', '美化', '添加',
                   '移除', '删除', '保存', '导出', '导入', '退出', '关闭', '停止', '重启',
                   'GitHub', '项目主页', '日志目录', '报告目录', '…')
    $clicked = 0; $skipped = 0
    foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'tool', 'more', 'about')) {
        try { Show-GuiPage -Key $k -SkipCards:$true; [System.Windows.Forms.Application]::DoEvents() } catch { }
        $ws = New-Object System.Collections.Stack
        $ws.Push($script:Pages[$k])
        while ($ws.Count -gt 0) {
            $c = $ws.Pop()
            try { foreach ($cc in $c.Controls) { $ws.Push($cc) } } catch { }
            if ($c -is [System.Windows.Forms.Button] -and $c.Enabled) {
                $txt = [string]$c.Text
                $skipIt = $false
                foreach ($s in $skipTexts) { if ($txt -like ('*' + $s + '*')) { $skipIt = $true; break } }
                if ($skipIt) { $skipped++; continue }
                try {
                    $c.PerformClick()
                    [System.Windows.Forms.Application]::DoEvents()
                    $clicked++
                } catch {
                    # 非交互会话（session 0 / 远程 WinRM / 计划任务里跑的界面进程）下
                    # MessageBox.Show 会抛 "当应用程序不是以 UserInteractive 模式运行时
                    # 显示模式对话框或窗体是无效操作"。这是**环境限制**，不是功能坏了 ——
                    # 真机上人坐在控制台/RDP 前就是交互会话，弹框正常。这里如实标成"跳过"，
                    # 免得真机审计里出现一条永远消不掉的假红线。
                    if ([string]$_.Exception.Message -match 'UserInteractive') {
                        $skipped++
                        Write-Host ('  {0} 页按钮 "{1}" 跳过（非交互会话不能弹框）' -f $k, $txt) -ForegroundColor DarkGray
                    } else {
                        $auditFail++
                        Write-Host ('  {0} 页按钮 "{1}" 点击报错: {2}' -f $k, $txt, $_.Exception.Message) -ForegroundColor Red
                        Write-Host ('      at ' + (($_.ScriptStackTrace -split "`n")[0])) -ForegroundColor DarkGray
                    }
                }
            }
            # 下拉：每个选项都切一次（过滤/主题切换都是在这里崩的）
            if ($c -is [System.Windows.Forms.ComboBox] -and $c.Items.Count -gt 1) {
                for ($i = 0; $i -lt $c.Items.Count; $i++) {
                    try {
                        $c.SelectedIndex = $i
                        [System.Windows.Forms.Application]::DoEvents()
                        $clicked++
                    } catch {
                        $auditFail++
                        Write-Host ('  {0} 页下拉 "{1}" 选第 {2} 项报错: {3}' -f $k, [string]$c.Text, ($i + 1), $_.Exception.Message) -ForegroundColor Red
                        Write-Host ('      at ' + (($_.ScriptStackTrace -split "`n")[0])) -ForegroundColor DarkGray
                    }
                }
            }
        }
    }
    $script:AuditMode = $false
    Write-Host ('  触发 {0} 次交互（跳过会启动外部程序/弹框的 {1} 个按钮）' -f $clicked, $skipped) -ForegroundColor Green

    Write-Host ''
    Write-Host '=== 5) 窗口外壳：拖动 / 最大化 / 缩放 ===' -ForegroundColor Cyan
    # 外壳换成无边框自绘之后，"窗口能不能拖、能不能缩放"就成了必须验的东西 ——
    # 这类问题在界面上点不出来（要真的按住拖），所以在这里按增量算法验一遍。
    try {
        # 拖动：验证"窗口按鼠标增量移动"。
        # 容差 ±8px：这段会读两次真实鼠标坐标，两次之间只要鼠标动一格就差 1px，
        # 在 RDP/虚拟机里实测能差到 5px。它拦的是"拖动彻底坏了/方向反了"，不是像素级精度，
        # 所以宁可放宽也不要做成一个随机失败的红灯。
        $before = $form.Location
        $cur    = [System.Windows.Forms.Cursor]::Position
        $script:DragStartCursor = New-Object System.Drawing.Point(($cur.X - 30), ($cur.Y - 20))
        $script:DragStartForm   = $before
        $script:DragActive      = $true
        Update-ShellDrag
        $after = $form.Location
        $dx = $after.X - $before.X
        $dy = $after.Y - $before.Y
        $okDrag = ([Math]::Abs($dx - 30) -le 8 -and [Math]::Abs($dy - 20) -le 8)
        Write-Host ('  拖动: {0}  （{1} → {2}，期望 +30/+20）' -f $(if ($okDrag) { 'OK' } else { '!! 增量不对' }), $before, $after) `
            -ForegroundColor $(if ($okDrag) { 'Green' } else { 'Red' })
        if (-not $okDrag) { $auditFail++ }
        $form.Location = $before
        Stop-ShellDrag

        if ($script:UiTypesReady) {
            $form.ToggleMax(); [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250
            Layout-Shell
            $maxed    = ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized)
            $marginOk = ($pnlShell.Left -eq 0 -and [int]$pnlShell.Tag.Radius -eq 0)
            Write-Host ('  最大化: 状态={0}  留白归零={1}' -f $(if ($maxed) { 'OK' } else { '!! 没最大化' }), $(if ($marginOk) { 'OK' } else { '!! 留白没归零' })) `
                -ForegroundColor $(if ($maxed -and $marginOk) { 'Green' } else { 'Red' })
            if (-not ($maxed -and $marginOk)) { $auditFail++ }

            $form.ToggleMax(); [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250
            Layout-Shell
            $backOk = ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal -and $pnlShell.Left -eq $script:ShellMargin)
            Write-Host ('  还原: {0}' -f $(if ($backOk) { 'OK' } else { '!! 没回到原样' })) -ForegroundColor $(if ($backOk) { 'Green' } else { 'Red' })
            if (-not $backOk) { $auditFail++ }
        }

        # 缩放：**不能拿"当前宽度 +60"当预期** —— 屏幕只有 1024 宽时那个尺寸超出屏幕，
        # 会被系统钳制，于是真机上出现一条假红线（实测）。改成先算一个"一定装得进屏幕"的
        # 目标尺寸，再验证设置生效、以及缩到 200x150 时被 MinimumSize 挡住。
        $wa  = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $b0  = $form.Size
        $min = $form.MinimumSize
        $tgtW = [Math]::Min($wa.Width,  [Math]::Max($min.Width,  ($wa.Width  - 80)))
        $tgtH = [Math]::Min($wa.Height, [Math]::Max($min.Height, ($wa.Height - 80)))
        $form.Size = New-Object System.Drawing.Size($tgtW, $tgtH)
        $grew = ($form.Width -eq $tgtW -and $form.Height -eq $tgtH)
        $form.Size = New-Object System.Drawing.Size(200, 150)
        $clamped = ($form.Width -ge $min.Width -and $form.Height -ge $min.Height)
        Write-Host ('  缩放: 设定尺寸({0}x{1})生效={2}  最小尺寸保护={3}' -f $tgtW, $tgtH, $(if ($grew) { 'OK' } else { '!!' }), $(if ($clamped) { 'OK' } else { '!!' })) `
            -ForegroundColor $(if ($grew -and $clamped) { 'Green' } else { 'Red' })
        if (-not ($grew -and $clamped)) { $auditFail++ }
        $form.Size = $b0
        Layout-Shell
    } catch {
        $auditFail++
        Write-Host ('  外壳检查出错: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('      at ' + (($_.ScriptStackTrace -split "`n")[0])) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '=== 6) 进入页面时真正跑一遍页面钩子（查询宿主 / 定时器）===' -ForegroundColor Cyan
    # 为什么必须有这一段：前面所有阶段都在 $SkipPageHooks = $true 下跑，
    # 而 Show-MonPage / Show-SecPage / Show-DshPage 的**整个函数体**都在这道开关后面 ——
    # 于是"仪表盘 / 安全 / AI 进去就报错"这类问题在审计里**永远是绿的**（假通过，实测踩到）。
    # 这里把开关临时打开，逐页真跑一次钩子，并等查询宿主把结果回填到界面，
    # 任何异常都能在这里被抓住。
    # 放在最后一个阶段：钩子会把真实数据填进列表，列表行上的"安装/卸载"按钮不在本阶段的
    # 点击范围内（阶段 4 早已结束），所以不会误触发真实动作。
    # 只统计本阶段**新产生**的 WARN/ERROR：启动时那几条"工具目录不是管理员独占"的提示是
    # 设计内的（安全功能正常工作就会打它们），把它们算进来这段检查就永远是红的。
    $logMark = 0
    try { $logMark = [int]$txtLog.TextLength } catch { }
    foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'tool', 'more', 'about')) {
        try {
            $script:MonLoaded = $false
            $script:SecLoaded = $false
            $script:DshLoaded = $false
            $script:SkipPageHooks = $false
            Show-GuiPage -Key $k -SkipCards:$true
            # 等后台查询回来并回填（轮询把消息泵转起来，否则定时器根本不触发）
            # 上限给足：Server Core 上安全审计要跑十几秒（真机实测 12 秒不够，会误报"没跑完"）
            $until = (Get-Date).AddSeconds(45)
            while ((Get-Date) -lt $until) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 120
                $busy = $false
                foreach ($q in @($script:QMon, $script:QSec, $script:QDsh)) {
                    if ($q -and $q.Task) { $busy = $true }
                }
                if (-not $busy) { break }
            }
            [System.Windows.Forms.Application]::DoEvents()
            # 光"没抛异常"不算通过：还要确认查询真的回来了、界面真的回填了。
            # 卡在"正在…"、或者查询返回错误，以前在审计里同样看不出来。
            $busyList = @()
            foreach ($q in @($script:QMon, $script:QSec, $script:QDsh)) {
                if ($q -and $q.Task) { $busyList += ($q.Name + '=' + $q.Task) }
            }
            $info = ''
            switch ($k) {
                'monitor'  { $info = ('进程行 ' + @($script:MonRows).Count + ' · 汇总[' + [string]$pillMonSum.Tag.Text + ']') }
                'security' { $info = ('检查行 ' + @($script:SecRows).Count + ' · 汇总[' + [string]$pillSecSum.Tag.Text + ']') }
                'dsh'      { $info = ('依赖行 ' + @($script:DshRows).Count) }
            }
            if ($busyList.Count -gt 0) {
                $auditFail++
                Write-Host ('  {0,-9} !! 查询没跑完: {1}' -f $k, ($busyList -join ',')) -ForegroundColor Red
            } else {
                Write-Host ('  {0,-9} 钩子执行 OK   {1}' -f $k, $info) -ForegroundColor Green
            }
        } catch {
            $auditFail++
            Write-Host ('  {0,-9} !! {1}' -f $k, $_.Exception.Message) -ForegroundColor Red
            Write-Host ('      at ' + (($_.ScriptStackTrace -split "`n")[0])) -ForegroundColor DarkGray
        } finally {
            $script:SkipPageHooks = $true
            foreach ($q in @($script:QMon, $script:QSec, $script:QDsh)) {
                try { if ($q) { Stop-GuiQueryHost -Query $q } } catch { }
            }
            try { if ($script:Timer) { $script:Timer.Stop() } } catch { }
        }
    }

    Write-Host ''
    # 页面钩子跑完，把本阶段新冒出来的 WARN/ERROR 捞出来 —— 查询失败、渲染报错都写在这里，
    # 而"进去以后报错"最可能就是这类行（以前审计只看异常，看不到这类）。
    try {
        $newLog = ''
        if ([int]$txtLog.TextLength -gt $logMark) { $newLog = [string]$txtLog.Text.Substring($logMark) }
        $logLines = @(($newLog -split "`r?`n") | Where-Object { $_ -match '\[(WARN|ERROR)\]' })
        if ($logLines.Count -gt 0) {
            Write-Host ('  页面钩子阶段新增了 {0} 条 WARN/ERROR：' -f $logLines.Count) -ForegroundColor Yellow
            foreach ($l in ($logLines | Select-Object -Last 12)) { Write-Host ('    ' + $l) -ForegroundColor Yellow }
            $auditFail++
        } else {
            Write-Host '  页面钩子阶段没有新增 WARN/ERROR' -ForegroundColor Green
        }
    } catch { }
    Write-Host ''
    if ($auditNotes.Count -gt 0) { foreach ($n in $auditNotes) { Write-Host ('  · ' + $n) -ForegroundColor Yellow } }
    Write-Host ('UI 审计结束：{0}' -f $(if ($auditFail -eq 0) { '未发现问题' } else { ('发现 {0} 处问题（见上）' -f $auditFail) })) `
        -ForegroundColor $(if ($auditFail -eq 0) { 'Green' } else { 'Red' })
    try { $form.Close(); $form.Dispose() } catch { }
    exit $(if ($auditFail -eq 0) { 0 } else { 1 })
}

if ($UiShot) {
    # 把窗口真渲染成 PNG 存盘（对齐参考文档 §六 的 SL_CAPTURE）。
    # 用 DrawToBitmap 直接渲染视觉树，不受遮挡影响 —— 用来给"界面现在到底长什么样"留一份证据，
    # 报界面问题的时候带上这张图比文字描述准得多。
    try {
        $form.CreateControl()
        Update-Chrome
        Show-GuiPage -Key $StartPage -SkipCards
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 700
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($UiShot, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Host ('UI 截图已保存: ' + $UiShot) -ForegroundColor Green
    } catch {
        Write-Host ('UI 截图失败: ' + $_.Exception.Message) -ForegroundColor Red
    }
    try { $script:Timer.Dispose() } catch { }
    try { $form.Close(); $form.Dispose() } catch { }
    return
}

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
        foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'tool', 'more', 'about')) {
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
        Update-WacToolGroup
        $avail = @($script:ToolButtons | Where-Object { -not $_.Missing })
        [void]$rep.Add(('系统工具: 共 {0} 个，当前可用 {1} 个，缺失 {2} 个' -f $script:ToolButtons.Count, $avail.Count, ($script:ToolButtons.Count - $avail.Count)))
        [void]$rep.Add(('WAC 重复组: {0}（WAC 已装且运行={1}，展开={2}）' -f `
            $(if ($script:WacToolsSuppressed) { '已隐藏（WAC 里有）' } elseif ($script:PnlWacTools.Visible) { '已展开' } else { '默认收起' }),
            $script:WacToolsSuppressed, $script:WacToolsExpanded))
        foreach ($tb in $script:ToolButtons) {
            if ($tb.Missing) { [void]$rep.Add(('    缺失: {0}  ({1})' -f $tb.Name, $tb.Target)) }
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
        Update-WacToolGroup
        $toolAvail = @($script:ToolButtons | Where-Object { -not $_.Missing }).Count
        Write-Host ('GUI SELFTEST OK: 页面 {0} 个 / 状态卡片 {1} 个 / 系统工具 {2} 个(可用 {3}) / 更多里功能 {4} 个 / 参数控件 {5} 个 / 窗体 {6}' -f `
            $script:Pages.Count, $cardCount, $script:ToolButtons.Count, $toolAvail, $nodeCount, $ctlCount, $form.Size.ToString()) -ForegroundColor Green
        Write-Host ('  WAC 重复组: {0}   卡片值: {1}' -f `
            $(if ($script:WacToolsSuppressed) { '已隐藏（WAC 里有）' } else { '默认收起' }), ($envVals -join ' | ')) -ForegroundColor Green
        # 再用后台探测产出的 JSON 渲染一遍：确认反序列化后的字段/类型都能被渲染代码正常消费
        $probe = Read-EnvProbeResult -FromCache
        if ($probe) {
            Update-EnvCards -Data $probe
            $envVals2 = @($script:Cards | ForEach-Object { $_.Value.Text })
            $probeOk = (@($envVals2 | Where-Object { $_ -and $_ -ne '探测中…' }).Count -eq $script:Cards.Count)
            Write-Host ('  探测数据渲染: {0}' -f ($envVals2 -join ' | ')) -ForegroundColor Green
            if (-not $probeOk) { Write-Host '  !! 探测数据渲染有空白卡片' -ForegroundColor Red }
        } else {
            Write-Host '  （没有 state\env-cache.json，跳过探测数据渲染验证）' -ForegroundColor Yellow
        }
        # 商店页：把「子进程写 JSON → 界面反序列化 → 渲染」这条真实路径跑一遍（自检不联网、不起子进程）
        Show-GuiPage -Key 'store'
        $storeTmp = Join-Path $env:TEMP 'gui-store-selftest.json'
        $storeJson = '{"Mode":"status","Error":"","Items":[' +
            '{"Id":"choco","Name":"Chocolatey","Installed":true,"Version":"2.2.2","Path":"C:\\ProgramData\\chocolatey\\bin\\choco.exe","CanSearch":true,"CanInstall":true,"Note":"自检假数据"},' +
            '{"Id":"scoop","Name":"Scoop","Installed":false,"Version":"","Path":"","CanSearch":false,"CanInstall":false,"Note":"自检假数据"}]}'
        try {
            [System.IO.File]::WriteAllText($storeTmp, $storeJson, (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
        $storeObj = Import-GuiJsonFile -Path $storeTmp
        if ($storeObj) {
            $script:StoreSources = @($storeObj.Items)
            $script:StoreLocal   = @('git')
            Update-StoreSourceRow
            Show-StoreResult -Items @(
                [pscustomobject]@{ Id = '7zip'; Version = '23.01';  Source = 'choco' }
                [pscustomobject]@{ Id = 'git';  Version = '2.47.0'; Source = 'choco' }
            )
            $storeRowsN = @($script:StoreRows).Count
            # 工具详情：换一份 info 形状的 JSON 再渲染一次
            $infoJson = '{"Mode":"info","Source":"choco","Package":"7zip","Error":"","Items":[{"Id":"7zip","Version":"26.3.0",' +
                '"Title":"7-Zip","Published":"2026/9/4","Summary":"file archiver","Description":"line1\nline2","Tags":"7zip zip",' +
                '"Site":"http://www.7-zip.org/","License":"http://www.7-zip.org/license.txt","Url":"https://community.chocolatey.org/packages/7zip/26.3.0","Downloads":"35538182","Error":""}]}'
            try { [System.IO.File]::WriteAllText($storeTmp, $infoJson, (New-Object System.Text.UTF8Encoding($false))) } catch { }
            $infoObj = Import-GuiJsonFile -Path $storeTmp
            Render-StoreDetail -Obj $infoObj
            Write-Host ('  商店页: 源胶囊 {0} 个 / 结果行 {1} 行 / 详情行 {2} 行 / 搜索源 {3} 个' -f `
                $script:StorePills.Count, $storeRowsN, @($script:StoreDetailRows).Count, $script:StoreComboMap.Count) -ForegroundColor Green
            # 回到列表视图，别让自检把页面留在详情态
            Show-StoreResult -Items $script:StoreLastItems
        } else {
            Write-Host '  !! 商店页自检：子进程 JSON 读不回来（Import-GuiJsonFile 有问题）' -ForegroundColor Red
        }
        try { Remove-Item -LiteralPath $storeTmp -Force -ErrorAction SilentlyContinue } catch { }

        # 角色页：同样跑一遍「子进程 JSON → 反序列化 → 渲染」，这份假数据是 Server 的形状
        Show-GuiPage -Key 'role'
        $roleTmp = Join-Path $env:TEMP 'gui-role-selftest.json'
        $roleJson = '{"Mode":"list","Error":"","Support":{"ServerManager":true,"Dism":true,"Administrator":true,"ProductType":"ServerNT","ServerOs":true,"CanManage":true,"Note":""},"Summary":{},"Items":[' +
            '{"Name":"DNS","DisplayName":"DNS Server","Installed":true,"InstallState":"Installed","FeatureType":"Role","Parent":"","DependsOn":[],"Note":""},' +
            '{"Name":"Web-Server","DisplayName":"Web Server (IIS)","Installed":false,"InstallState":"Available","FeatureType":"Role","Parent":"","DependsOn":["WAS"],"Note":""}]}'
        try {
            [System.IO.File]::WriteAllText($roleTmp, $roleJson, (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
        $roleObj = Import-GuiJsonFile -Path $roleTmp
        if ($roleObj) {
            $script:RoleSupport = $roleObj.Support
            $script:RoleItems   = @($roleObj.Items)
            Update-RoleStatusRow
            Show-RoleResult
            $roleAll = $script:RoleRows.Count
            $cmbRoleFilter.SelectedIndex = 2      # 仅未安装
            Show-RoleResult
            $roleNotInstalled = $script:RoleRows.Count
            $cmbRoleFilter.SelectedIndex = 0
            Write-Host ('  角色页: 能力胶囊 {0} 个 / 全部 {1} 行 / 仅未安装筛选 {2} 行' -f `
                $script:RolePills.Count, $roleAll, $roleNotInstalled) -ForegroundColor Green
        } else {
            Write-Host '  !! 角色页自检：子进程 JSON 读不回来' -ForegroundColor Red
        }
        try { Remove-Item -LiteralPath $roleTmp -Force -ErrorAction SilentlyContinue } catch { }

        # 仪表盘 / 安全 / 美化 / AI：同样把「JSON → 反序列化 → 渲染」跑一遍
        Show-GuiPage -Key 'monitor'
        $monTmp = Join-Path $env:TEMP 'gui-monitor-selftest.json'
        $monJson = '{"Mode":"snapshot","Error":"","Snap":{"Stamp":"2026-09-30T00:00:00",' +
            '"Cpu":{"Percent":12.5,"Source":"Get-Counter","Error":""},' +
            '"Memory":{"TotalGB":16.0,"UsedGB":6.0,"FreeGB":10.0,"UsedPercent":37.5},' +
            '"Disks":[{"Name":"C:","Label":"","TotalGB":200.0,"FreeGB":120.0,"UsedPercent":40.0}],' +
            '"Services":[{"Name":"WinRM","Display":"Windows Remote Management","Why":"x","Status":"Running","Start":"Automatic"},' +
            '{"Name":"W32Time","Display":"Windows Time","Why":"x","Status":"Stopped","Start":"Manual"}],' +
            '"Events":[{"Time":"09-30 10:00:00","Level":"错误","Provider":"SelfTest","Id":1,"Message":"假数据"}],' +
            '"Processes":[{"Name":"powershell","Id":1,"MemMB":100.0,"CpuSec":1.0}],"Notes":[]}}'
        try { [System.IO.File]::WriteAllText($monTmp, $monJson, (New-Object System.Text.UTF8Encoding($false))) } catch { }
        $monObj = Import-GuiJsonFile -Path $monTmp
        if ($monObj) {
            Render-Monitor -Obj $monObj
            Write-Host ('  仪表盘: 指标卡 {0} 张 / 列表行 {1} 行 / CPU={2}' -f $script:MonCards.Count, $script:MonRows.Count, $script:MonCards['cpu'].Value.Text) -ForegroundColor Green
        } else {
            Write-Host '  !! 仪表盘自检：JSON 读不回来' -ForegroundColor Red
        }
        try { Remove-Item -LiteralPath $monTmp -Force -ErrorAction SilentlyContinue } catch { }

        Show-GuiPage -Key 'security'
        $secTmp = Join-Path $env:TEMP 'gui-security-selftest.json'
        $secJson = '{"Mode":"audit","Error":"","Summary":{"Total":2,"Ok":1,"Warn":0,"Fail":1,"Unknown":0,"Fixable":1},' +
            '"Items":[{"Id":"firewall","Title":"Windows 防火墙","Category":"网络","Status":"OK","Detail":"Domain=启用","Advice":"","Fix":""},' +
            '{"Id":"smbv1","Title":"SMBv1 协议","Category":"网络","Status":"Fail","Detail":"EnableSMB1Protocol=True","Advice":"应该关掉","Fix":"smbv1"}]}'
        try { [System.IO.File]::WriteAllText($secTmp, $secJson, (New-Object System.Text.UTF8Encoding($false))) } catch { }
        $secObj = Import-GuiJsonFile -Path $secTmp
        if ($secObj) {
            Render-Security -Obj $secObj
            $secRowsProblem = [int]@($script:SecRows).Count
            $cmbSecFilter.SelectedIndex = 0      # 全部
            Render-Security -Obj $secObj
            $secRowsAll = [int]@($script:SecRows).Count
            Write-Host ('  安全页: 只看问题项 ' + $secRowsProblem + ' 行 / 全部 ' + $secRowsAll + ' 行 / 汇总胶囊 ' + [string]$pillSecSum.Tag.Text) -ForegroundColor Green
        } else {
            Write-Host '  !! 安全页自检：JSON 读不回来' -ForegroundColor Red
        }
        try { Remove-Item -LiteralPath $secTmp -Force -ErrorAction SilentlyContinue } catch { }

        Show-GuiPage -Key 'dsh'
        $dshTmp = Join-Path $env:TEMP 'gui-dsh-selftest.json'
        $dshJson = '{"Mode":"status","Error":"","Status":{"Ready":false,"Items":[' +
            '{"Id":"node","Name":"Node.js","Required":"22.19+","Installed":true,"Version":"v26.10.0","Ok":true,"Detail":"C:\\Program Files\\nodejs\\node.exe","Advice":""},' +
            '{"Id":"api-key","Name":"DEEPSEEK_API_KEY","Required":"必需","Installed":false,"Version":"","Ok":false,"Detail":"未设置","Advice":"setx 设置"}],' +
            '"Npm":[{"Package":"@deepseek-ai/dsh","Exists":true,"Version":"1.0.0","Error":""}]}}'
        try { [System.IO.File]::WriteAllText($dshTmp, $dshJson, (New-Object System.Text.UTF8Encoding($false))) } catch { }
        $dshObj = Import-GuiJsonFile -Path $dshTmp
        if ($dshObj) {
            Render-Dsh -Obj $dshObj
            Write-Host ('  AI 页: 依赖行 + 包行 {0} 行 / 汇总胶囊 {1}' -f $script:DshRows.Count, $pillDshSum.Tag.Text) -ForegroundColor Green
        } else {
            Write-Host '  !! AI 页自检：JSON 读不回来' -ForegroundColor Red
        }
        try { Remove-Item -LiteralPath $dshTmp -Force -ErrorAction SilentlyContinue } catch { }

        Show-GuiPage -Key 'beauty'
        Update-BeautyView
        Write-Host ('  美化页: 状态胶囊 {0} 个 / 信息行 {1} 行' -f @($pnlBeautyStatus.Controls).Count, $script:BeautyRows.Count) -ForegroundColor Green

        # ---- 查询宿主的**真实**链路：定时器 → 子进程 → JSON 回填 ----
        # 这一段以前只在真人点界面时才会跑到，于是漏掉了"事件回调里看不到函数局部变量"的崩溃
        # （Timer 一跳就抛 ParameterBindingValidationException，界面直接弹 JIT 异常框）。
        # 自检必须把这条链路真跑一遍：起子进程、泵消息、等结果回填。
        $script:QMon.Task = ''
        if (Start-GuiQueryHost -Query $script:QMon -Task 'snapshot' -BusyText '自检：采集快照…') {
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $deadline -and $script:QMon.Task) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 120
            }
            $cpuText = [string]$script:MonCards['cpu'].Value.Text
            $rowN    = @($script:MonRows).Count
            $done    = (-not $script:QMon.Task)
            if ($done -and $cpuText -and $cpuText -ne '—') {
                Write-Host ('  查询链路: 定时器+子进程+回填 OK（CPU={0} / 列表 {1} 行）' -f $cpuText, $rowN) -ForegroundColor Green
            } else {
                Write-Host ('  !! 查询链路有问题: 收尾={0} CPU卡片=[{1}] 行数={2}' -f $done, $cpuText, $rowN) -ForegroundColor Red
            }
        } else {
            Write-Host '  !! 查询链路: 查询没能启动' -ForegroundColor Red
        }
        # 同样把"安全页"的查询宿主也起一次（它用的是同一个宿主，顺手确认真能跑）
        $script:QSec.Task = ''
        if (Start-GuiQueryHost -Query $script:QSec -Task 'audit' -BusyText '自检：安全审计…') {
            $deadline = (Get-Date).AddSeconds(90)
            while ((Get-Date) -lt $deadline -and $script:QSec.Task) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 120
            }
            Write-Host ('  安全页查询链路: 收尾={0} / 胶囊=[{1}]' -f (-not $script:QSec.Task), [string]$pillSecSum.Tag.Text) -ForegroundColor Green
        }
        # 主题覆盖自检：把 11 个页面的控件全走一遍，找出"没走 Token、还是浅色"的控件。
        # 为什么需要它：深色主题最常见的问题就是某个容器/下拉框漏改，肉眼不一定马上发现，
        # 而它会在深色界面上留一块刺眼的白。这里结构化地查一遍，以后加控件也不会漏。
        $themeBad = @()
        foreach ($tk in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'tool', 'more', 'about')) {
            $page = $script:Pages[$tk]
            if (-not $page) { continue }
            $stack = New-Object System.Collections.Stack
            $stack.Push($page)
            while ($stack.Count -gt 0) {
                $c = $stack.Pop()
                try {
                    $bc = $c.BackColor
                    # 跳过透明（色值会读成 255,255,255，会误报）。
                    # 注意**不能**再用 $c.Visible 过滤：非当前页整页都是 Visible=false，
                    # 那样只会查当前这一页 —— 第一次写就是这么漏的。
                    if ($bc -ne [System.Drawing.Color]::Transparent) {
                        if ($bc.R -gt 200 -and $bc.G -gt 200 -and $bc.B -gt 200) {
                            $themeBad += ('{0} 页 / {1} "{2}"  BackColor=#{3:X2}{4:X2}{5:X2}' -f `
                                $tk, $c.GetType().Name, ([string]$c.Text -replace "`r?`n", ' '), $bc.R, $bc.G, $bc.B)
                        }
                    }
                } catch { }
                try { foreach ($cc in $c.Controls) { $stack.Push($cc) } } catch { }
            }
        }
        if ($themeBad.Count -eq 0) {
            Write-Host '  主题覆盖: 全部页面控件都走了深色 Token' -ForegroundColor Green
        } else {
            Write-Host ('  !! 主题覆盖: {0} 个控件还是浅色（深色界面上会留白块）' -f $themeBad.Count) -ForegroundColor Red
            $themeBad | Select-Object -First 15 | ForEach-Object { Write-Host ('     ' + $_) -ForegroundColor Yellow }
        }

        # 设计系统组件自检：把每个组件在屏幕外真画一遍再取样，确认 Paint 真的出了东西
        $uiResults = Test-GuiUiComponents
        $uiFail = @($uiResults | Where-Object { -not $_.Ok }).Count
        Write-Host ('  组件自检: {0}' -f (($uiResults | ForEach-Object { '{0}={1}' -f $_.Name, $(if ($_.Ok) { 'OK' } else { 'FAIL' }) }) -join '  ')) `
            -ForegroundColor $(if ($uiFail -eq 0) { 'Green' } else { 'Red' })
        foreach ($r in $uiResults) {
            if (-not $r.Ok) { Write-Host ('    !! {0} 没画出内容（取样像素 {1}）{2}' -f $r.Name, $r.Pixels, $r.Error) -ForegroundColor Red }
        }
        $script:Timer.Dispose()
        try { $script:ProbeTimer.Dispose() } catch { }
        try { $script:StoreTimer.Dispose() } catch { }
        try { $script:RoleTimer.Dispose() } catch { }
        foreach ($q in @($script:QMon, $script:QSec, $script:QDsh, $script:QStoreInfo)) { if ($q) { Close-GuiQueryHost -Query $q } }
        $form.Dispose()
    } catch {
        Write-Host ('GUI SELFTEST FAIL: ' + $_.Exception.Message) -ForegroundColor Red
    }
    return
}

[void]$form.ShowDialog()
try { $script:Timer.Dispose() } catch { }

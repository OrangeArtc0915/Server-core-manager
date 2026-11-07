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
    # 截图前等待页面数据加载的毫秒数（0 = 旧行为，不等；列表要出内容时传 6000 左右）
    [int]$UiShotWait = 0,
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
                 'GuiReady.Files.ps1', 'GuiReady.Logs.ps1',
                 'GuiReady.Integrity.ps1', 'GuiReady.Store.ps1', 'GuiReady.Tasks.ps1',
                 'GuiReady.Hosts.ps1', 'GuiReady.Remote.ps1', 'GuiReady.Runtime.ps1', 'GuiReady.Database.ps1')) {
    $p = Join-Path $libDir $f
    if (Test-Path -LiteralPath $p) {
        $__t0 = Get-Date
        . $p
        $__ms = [int]((Get-Date) - $__t0).TotalMilliseconds
        if ($__ms -ge 25) { Add-BootTrace ('  lib ' + $f + ' = ' + $__ms + ' ms') }
    }
}
. (Join-Path $guiDir 'GuiReady.Actions.ps1')
# 设计系统组件库（卡片 / 输入框 / 胶囊 / 进度条 / 圆角路径），Token 与尺寸见 gui\GuiReady.Ui.ps1。
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
$script:ActiveParamMap = $null   # 非空 = 当前动作来自「高级设置」对话框自己的控件表
$script:Proc          = $null
$script:CurrentJobId  = ''       # 当前动作对应的任务编号（停止时用它把任务标记为已取消）
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
# 页面内容按需构建（page lazy build）：
#   $script:PageBuilders['<key>'] = '<函数名>'  —— 该页控件还没建时调用它
#   $script:PageBuilt['<key>']    = $true       —— 已建过，不再重复
# 启动时只建 Panel（1 个控件）；控件、事件绑定、首次数据填充都在第一次显示该页时做。
$script:PageBuilders  = @{}
$script:PageBuilt     = @{}
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

# HMOL 深色变体（唯一主题）
#
# 色值来源（照抄，不自己发挥）：
#   D:\F\MO\HMOL\src\HMOL.App\Resources\Colors.xaml        浅色基准令牌
#   D:\F\MO\HMOL\src\HMOL.App\Theme\ThemeService.cs        深色推导公式（BuildBrushes / DerivePalette）
# 深色推导公式：
#   Deep   = Mix(preset.Deep, black, 0.15)   Base = Lighten(preset.Base, 0.18)
#   Bright = preset.Bright                   Hover = Lighten(preset.Bright, 0.08)
#   Soft   = Mix(preset.Base, #20262F, 0.42) Faint = Mix(preset.Base, #20262F, 0.20)
#   Mix(c,t,p)      = c*(1-p) + t*p
#   Lighten(c,t)    = Mix(c, white, t)
# 强调色预设取 Default（Deep #2A3A6B / Base #3B55A0 / Bright #4F6FD8）。
#
# 字号对照（WPF 用 DIP＝1/96 英寸，WinForms 用 pt＝1/72 英寸，pt = DIP × 0.75）：
#   HMOL 18 Bold ≈ 13.5pt ｜ 13.5 Bold ≈ 10pt ｜ 12.5 SemiBold ≈ 9.4pt
#   12 ≈ 9pt ｜ 11.5 ≈ 8.6pt ｜ 11 ≈ 8.25pt ｜ 10.5 SemiBold ≈ 7.9pt
#
# 改色只改这里；组件一律走 Token（键名保持不变，页面代码不用动）。
function Convert-HexToColor {
    param([string]$Hex)
    $h = $Hex.TrimStart('#')
    return [System.Drawing.Color]::FromArgb(
        [Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16))
}

$Pal = @{
    # ---- 强调色（直接采用 XMP 的 Element Plus 深色主题：#409EFF）----
    Accent1   = Convert-HexToColor '#2B5F9E'   # Deep   按下
    Accent2   = Convert-HexToColor '#409EFF'   # Bright 主色
    Accent3   = Convert-HexToColor '#66B1FF'   # Hover  提亮
    Accent4   = Convert-HexToColor '#1B2A3D'   # 选中底（蓝 14% 叠在卡片上）
    Accent5   = Convert-HexToColor '#1A1C24'   # 悬停底
    AccentFaint = Convert-HexToColor '#1B2A44'
    AccentSoft  = Convert-HexToColor '#1A2537'
    AccentBase  = Convert-HexToColor '#79BBFF'

    # ---- 语义状态（Element Plus：#67C23A / #E6A23C / #F56C6C）----
    Ok        = Convert-HexToColor '#67C23A'
    Warn      = Convert-HexToColor '#E6A23C'
    Err       = Convert-HexToColor '#F56C6C'
    OkBg      = Convert-HexToColor '#1C2B1B'
    WarnBg    = Convert-HexToColor '#2E2618'
    ErrBg     = Convert-HexToColor '#2E1D1D'

    # ---- 承载面（XMP 实测：--el-bg-color rgba(20,22,30,.98) / overlay rgba(26,28,36,.93)）----
    # 页面底用 Element Plus 的 bg-color-page（近黑），卡片抬一档，层次立刻出来。
    Bg        = Convert-HexToColor '#0A0A0C'   # 页面底
    BgTop     = Convert-HexToColor '#08080A'
    GlowBlue  = Convert-HexToColor '#1B2735'   # 星空径向渐变的内圈（XMP 的 starry-sky）
    GlowTeal  = Convert-HexToColor '#1B2735'
    Sunken    = Convert-HexToColor '#111116'   # 输入框底
    Card      = Convert-HexToColor '#14161E'   # 卡片 / 侧栏（bg-color）
    CardHover = Convert-HexToColor '#1A1C24'   # 悬停 / 浮层（bg-color-overlay）
    Border    = Convert-HexToColor '#2B2B2C'   # border-color-extra-light
    BorderStrong = Convert-HexToColor '#363637'  # border-color-lighter
    NavBg     = Convert-HexToColor '#14161E'

    # ---- 文字（Element Plus 深色：primary #E5EAF3 / regular #CFD3DC / secondary #A3A6AD）----
    # 之前的 Hint 太暗（#767E8C），小字在深底上糊成一片 —— 这是"看着不如人家清爽"的主因之一。
    Text      = Convert-HexToColor '#E5EAF3'
    SubText   = Convert-HexToColor '#CFD3DC'
    Hint      = Convert-HexToColor '#A3A6AD'

    # ---- 日志面板 ----
    LogBg     = Convert-HexToColor '#0A0A0C'
    LogBarBg  = Convert-HexToColor '#14161E'
    LogText   = Convert-HexToColor '#E5EAF3'

    # ---- 外壳与导航 ----
    Frame     = Convert-HexToColor '#101016'
    ShellBg   = Convert-HexToColor '#0A0A0C'
    ShellLine = Convert-HexToColor '#2B2B2C'
    TitleBg   = Convert-HexToColor '#14161E'
    TitleLine = Convert-HexToColor '#2B2B2C'

    # 导航项三态 + 左侧选中竖条
    NavActiveBg = Convert-HexToColor '#1B2A3D'
    NavHoverBg  = Convert-HexToColor '#1A1C24'
    NavText     = Convert-HexToColor '#CFD3DC'
    NavTextHi   = Convert-HexToColor '#FFFFFF'
    NavBar      = Convert-HexToColor '#409EFF'

    # 兼容旧命名
    Accent    = Convert-HexToColor '#409EFF'
    AccentHi  = Convert-HexToColor '#66B1FF'
}

function New-Font {
    # 字体对象按 (字族, 字号, 字形) 缓存复用：16 个页面有几百个标签，逐个 New-Object Font
    # 既慢又占 GDI 句柄（启动实测这一段是控件创建里最稳定的开销之一）。
    # Font 实例是不可变的，多个控件共用同一个实例完全安全（控件 Dispose 不会释放它）。
    param([string]$Family = 'Microsoft YaHei UI', [double]$Size = 9.5, [string]$Style = 'Regular')
    if (-not $script:FontCache) { $script:FontCache = @{} }
    $key = $Family + '|' + $Size.ToString('0.##') + '|' + $Style
    if ($script:FontCache.ContainsKey($key)) { return $script:FontCache[$key] }
    $st = [System.Drawing.FontStyle]::$Style
    $f = New-Object System.Drawing.Font -ArgumentList $Family, $Size, $st
    $script:FontCache[$key] = $f
    return $f
}

# ---- 圆角 Region：可延迟 ----
# 这套 UI 里最贵的单次调用不是控件构造，也不是圆角路径计算，而是
#     $Control.Region = New-Object Region (path)
# 真机（Server Core 纯软件渲染）实测：启动的"控件创建"段占 15.5s，占"可交互"的 76%；
# 而本机量出「建控件 0.6ms/个」「圆角路径 0.53ms/个」，量级远不足以解释它 ——
# 所以大头落在这条 Region 赋值上。
# 做法：建页面期间只登记(控件,半径)，等该页面第一次真正显示时再统一补上。
# 这样启动只服务首页，其余页面的成本推迟到各自首次显示（用户不为没看过的页付钱）。
$script:RoundDefer = $false
$script:RoundQueue = New-Object System.Collections.ArrayList

function Set-Rounded {
    param([System.Windows.Forms.Control]$Control, [int]$Radius = 10)
    try {
        $w = $Control.Width; $h = $Control.Height
        if ($w -le 0 -or $h -le 0) { return }
        if ($script:RoundDefer) {
            # 只登记。注意这里存的是"控件的引用"而不是值，所以控件之后被改尺寸也没关系：
            # 补 Region 时会用当时的实际宽高重算。
            [void]$script:RoundQueue.Add([pscustomobject]@{ Ctl = $Control; Radius = $Radius })
            return
        }
        # 圆角几何统一在 GuiReady.Ui.ps1 的 New-UiRoundPath 里，自绘描边用的是同一个路径
        $Control.Region = New-Object System.Drawing.Region -ArgumentList (New-UiRoundPath -Width $w -Height $h -Radius $Radius)
    } catch { }
}

function Apply-DeferredRounds {
    # 把一个页面里所有"登记过但还没设 Region"的控件补上。
    # 先把该页面的后代控件收成一个 HashSet，再单趟扫队列 —— O(n+m)，不做逐控件线性查找。
    param([System.Windows.Forms.Control]$Root)
    if (-not $Root -or $script:RoundQueue.Count -eq 0) { return }
    try {
        $inPage = New-Object 'System.Collections.Generic.HashSet[System.Windows.Forms.Control]'
        $stack  = New-Object System.Collections.Stack
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $c = $stack.Pop()
            [void]$inPage.Add($c)
            try { foreach ($k in $c.Controls) { $stack.Push($k) } } catch { }
        }
        $i = 0
        while ($i -lt $script:RoundQueue.Count) {
            $rec = $script:RoundQueue[$i]
            if ($inPage.Contains($rec.Ctl)) {
                try {
                    $c = $rec.Ctl
                    if ($c.Width -gt 0 -and $c.Height -gt 0) {
                        $c.Region = New-Object System.Drawing.Region -ArgumentList (New-UiRoundPath -Width $c.Width -Height $c.Height -Radius $rec.Radius)
                    }
                } catch { }
                $script:RoundQueue.RemoveAt($i)
            } else {
                $i++
            }
        }
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
                # Solid（HMOL OutlineButton）：底 Accent.Bright、悬停 Accent.Hover、白字
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
                # Danger（HMOL）：实心红底白字，悬停 DangerHover = (R+24, G-14, B-14)
                $b.BackNormal   = $Pal.Err
                $b.BackHover    = [System.Drawing.Color]::FromArgb(
                                      [Math]::Min(255, [int]$Pal.Err.R + 24),
                                      [Math]::Max(0,   [int]$Pal.Err.G - 14),
                                      [Math]::Max(0,   [int]$Pal.Err.B - 14))
                $b.BackPress    = $Pal.ErrBg
                $b.BackIdle     = $Pal.ErrBg
                $b.BorderColor  = $Pal.Err
                $b.BorderIdle   = $Pal.ErrBg
                $b.ForeNormal   = [System.Drawing.Color]::White
                $b.ForeHover    = [System.Drawing.Color]::White
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
                # Outline（HMOL OutlineButton）：底 Surface.Card、描边 Border.Strong；
                # 悬停 底 Surface.CardHover、文字转 Accent.Base
                $b.BackNormal   = $Pal.Card
                $b.BackHover    = $Pal.CardHover
                $b.BackPress    = $Pal.Accent4
                $b.BackIdle     = $Pal.Card
                $b.BorderColor  = $Pal.BorderStrong
                $b.BorderIdle   = $Pal.Border
                $b.ForeNormal   = $Pal.Text
                $b.ForeHover    = $Pal.Accent2
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
    # HMOL OutlineButton 文字 13 DIP ≈ 9.75pt；按下缩到 0.975（HMOL 80ms OutFluent，这里直接到位）
    $b.Font   = New-Font -Size 9.75
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
        Radius = $Radius; Base = $bg; Hover = $false; Press = $false
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
            # 按下缩到 0.85（HMOL RoundIconButton），只缩放绘制、不动控件尺寸
            if ($t.Press) {
                $g.TranslateTransform(($s.Width / 2), ($s.Height / 2))
                $g.ScaleTransform(0.85, 0.85)
                $g.TranslateTransform(-($s.Width / 2), -($s.Height / 2))
            }
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
    $p.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Tag.Press = $false; $this.Invalidate() })
    $p.Add_MouseDown({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $this.Tag.Press = $true;  $this.Invalidate() } })
    $p.Add_MouseUp({   $this.Tag.Press = $false; $this.Invalidate() })
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
    # 说明条，照 HMOL 的样式：整条淡色底（Accent.Faint）+ Radius.Item=10，
    # 左侧没有色条（HMOL 的提示条就是一整条淡底），文字 11.5 DIP ≈ 8.6pt。
    # 注意：返回值上的 .Tag 必须是内层 Label —— 自适应布局靠它同步文字宽度
    #（见 Update-PageLayout 里 `$hintEnv.Tag.Width = ...`），别再往 .Tag 上挂别的东西。
    param([string]$Text, [string]$Kind = 'Blue', [int]$Width = 600, [int]$Height = 38)
    $bg = $Pal.AccentFaint
    switch ($Kind) {
        'Green'  { $bg = $Pal.OkBg }
        'Yellow' { $bg = $Pal.WarnBg }
        'Red'    { $bg = $Pal.ErrBg }
    }
    $host_ = New-Object System.Windows.Forms.Panel
    $host_.Size      = New-Object System.Drawing.Size($Width, $Height)
    $host_.BackColor = $bg
    $lb = New-Label -Text $Text -Size 8.6 -Color SubText
    $lb.Location = New-Object System.Drawing.Point(12, [int](($Height - 17) / 2))
    $lb.AutoSize = $false
    $lb.Size = New-Object System.Drawing.Size(($Width - 24), 17)
    $host_.Controls.Add($lb)
    Set-Rounded -Control $host_ -Radius 10
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
    # -Big：仪表盘那种"大数字"卡片（对齐 XMP 的 40px 指标数字观感，96 高）。
    param(
        [string]$Title,
        [int]$Width = 208,
        [switch]$Big,
        [string]$AccentHex = '',
        [System.Windows.Forms.Control]$Parent = $null
    )
    $ch = $(if ($Big) { 104 } else { 76 })
    $card = New-Card -Width $Width -Height $ch -Radius 8 -AccentHex $AccentHex
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 12)
    $accent = $Pal.Accent2
    if ($AccentHex) { try { $accent = Convert-HexToColor $AccentHex } catch { } }

    if ($Big) {
        # 标题在上、数字居中、说明在下：XMP 指标卡的"标签 → 大数 → 注释"三段式
        $dot = New-Label -Text '●' -Size 11 -Color Text
        $dot.ForeColor = $accent
        $dot.Location = New-Object System.Drawing.Point(14, 10)
        $card.Controls.Add($dot)

        $lt = New-Label -Text $Title -Size 9 -Color Hint
        $lt.Location = New-Object System.Drawing.Point(34, 12)
        $card.Controls.Add($lt)

        $lv = New-Label -Text '—' -Size 17 -Style Bold -Color Text -Width ($Width - 28)
        $lv.Font = New-Object System.Drawing.Font('Consolas', 17, [System.Drawing.FontStyle]::Bold)
        $lv.Location = New-Object System.Drawing.Point(14, 33)
        $lv.Height   = 40
        $card.Controls.Add($lv)

        $ls = New-Label -Text '' -Size 8.5 -Color SubText -Width ($Width - 28)
        $ls.Location = New-Object System.Drawing.Point(14, 78)
        $ls.Height   = 16
        $card.Controls.Add($ls)
    } else {
        $dot = New-Label -Text '●' -Size 11 -Color Text
        $dot.ForeColor = $accent
        $dot.Location = New-Object System.Drawing.Point(12, 10)
        $card.Controls.Add($dot)

        $lt = New-Label -Text $Title -Size 8.5 -Color Hint
        $lt.Location = New-Object System.Drawing.Point(32, 12)
        $card.Controls.Add($lt)

        $lv = New-Label -Text '—' -Size 11 -Style Bold -Color Text -Width ($Width - 46)
        $lv.Location = New-Object System.Drawing.Point(32, 32)
        $lv.Height   = 24
        $card.Controls.Add($lv)

        $ls = New-Label -Text '' -Size 8.5 -Color SubText -Width ($Width - 46)
        $ls.Location = New-Object System.Drawing.Point(32, 54)
        $ls.Height   = 16
        $card.Controls.Add($ls)
    }

    # 默认挂在环境页的卡片区；仪表盘等其它页面用 -Parent 指定自己的容器
    $target = $pnlCards
    if ($Parent) { $target = $Parent }
    $target.Controls.Add($card)
    # 把内部文字与卡片一起登记进 Tag：窗口变窄时要连内部文字一起改宽，否则文字会被裁成半截
    #（真机 1024x768 实测：仪表盘 4 张指标卡挤成 3+1 两行，容器高度却是写死的 1 行，第 4 张整个看不见）
    $card.Tag.CardParts = @{ Title = $lt; Value = $lv; Sub = $ls; Dot = $dot }
    $card.Tag.PadX = $(if ($Big) { 28 } else { 46 })
    return [pscustomobject]@{ Panel = $card; Title = $lt; Value = $lv; Sub = $ls; Dot = $dot }
}

function Set-CardRowLayout {
    # 把一行状态卡片按"实际可用宽度"摊平：先算每行几张，再把卡片和卡片内部文字一起改宽。
    # 环境页（7 张，窄屏会换行）与仪表盘（4 张，尽量一行放下）共用这一套，
    # 不再各写一份 —— 之前写死宽度/高度，窄屏下就是"溢出 + 第二行被裁"。
    param(
        [System.Windows.Forms.FlowLayoutPanel]$Panel,
        [int]$Width,
        [int]$Gap = 12,
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
            $padX = 42
            if ($cd.Tag.ContainsKey('PadX')) { $padX = [int]$cd.Tag.PadX }
            $parts = $cd.Tag.CardParts
            if ($parts) {
                if ($parts.Value) { $parts.Value.Width = $cardW - $padX }
                if ($parts.Sub)   { $parts.Sub.Width   = $cardW - $padX }
            }
            Set-Rounded -Control $cd -Radius 8
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

# 留白 8px（HMOL PanBack.Margin=8）、圆角 12px（HMOL RectForm RadiusX/Y=12）
$script:ShellMargin = 8
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
# 标题栏 44px（HMOL MainWindow 的 Row0 Height=44）
$pnlTitle.Height    = 44
$pnlTitle.BackColor = $Pal.TitleBg
Enable-UiDoubleBuffer -Control $pnlTitle
$pnlTitle.Add_Paint({
    param($s, $e)
    # 左侧图标：24x24 块内放 20x20（HMOL Margin=16,0,12,0）
    try { Draw-UiIcon -Graphics $e.Graphics -Name 'env' -X 16 -Y 12 -Size 20 -Color $Pal.Accent2 } catch { }
})
$pnlTitle.Add_MouseDown({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-ShellDrag } })
$pnlTitle.Add_MouseMove({ Update-ShellDrag })
$pnlTitle.Add_MouseUp({ Stop-ShellDrag })
$pnlTitle.Add_DoubleClick({ Toggle-ShellMax })
$pnlShell.Controls.Add($pnlTitle)

# 标题：应用名（HMOL 14 SemiBold ≈ 10.5pt），右侧跟版本号（11.5 ≈ 8.6pt，Text.Tertiary）
$lblTitle          = New-Label -Text 'Server Core GUI 就绪工具' -Size 10.5 -Style Bold
$lblTitle.Location = New-Object System.Drawing.Point(50, 12)
$lblTitle.Add_MouseDown({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-ShellDrag } })
$lblTitle.Add_DoubleClick({ Toggle-ShellMax })
$pnlTitle.Controls.Add($lblTitle)

$lblTitleVer          = New-Label -Text 'v2.0' -Size 8.6 -Color Hint
$lblTitleVer.Location = New-Object System.Drawing.Point(220, 16)
$lblTitleVer.Add_MouseDown({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-ShellDrag } })
$pnlTitle.Controls.Add($lblTitleVer)

# 退出（会打开终端）：原来那个大块红色按钮太抢眼，收成标题栏右侧的轻量按钮
$btnExitBack           = New-FlatButton -Text '打开终端并退出' -Width 120 -Height 30 -Kind Plain
$pnlTitle.Controls.Add($btnExitBack)

# 窗口按钮：最小化 / 最大化 / 关闭 —— 位置在 Layout-Shell 里按标题栏宽度右对齐
# 窗口按钮：32x32 + Radius.Pill + 图标 15（HMOL TitleBar 右侧 RoundIconButton Tone=Plain）
$btnWinClose = New-IconButton -Icon 'window-close' -Size 32 -Radius 16 -Tip '关闭（会自动打开终端）' -OnClick { Exit-ToCommandLine }
$btnWinClose.Tag.HoverBack = $Pal.ErrBg
$btnWinClose.Tag.HoverFore = $Pal.Err
$btnWinMax   = New-IconButton -Icon 'window-max' -Size 32 -Radius 16 -Tip '最大化 / 还原' -OnClick { Toggle-ShellMax }
$btnWinMin   = New-IconButton -Icon 'window-min' -Size 32 -Radius 16 -Tip '最小化' -OnClick { $form.WindowState = 'Minimized' }
foreach ($b in @($btnWinClose, $btnWinMax, $btnWinMin)) { $b.Tag.IconSize = 15 }
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
# 侧栏宽 200（HMOL 内容区 Col0 Width=200）
$pnlNav           = New-Object System.Windows.Forms.Panel
$pnlNav.Dock      = 'Left'
$pnlNav.Width     = 200
$pnlNav.BackColor = $Pal.NavBg
$pnlShell.Controls.Add($pnlNav)

# 导航项：行高 42、上下 Margin 2 → 步进 46（HMOL NavItem 模板高 42 / Margin=8,2）
$script:NavItemH = 40
$script:NavStep  = 44
$pnlNavTop           = New-Object System.Windows.Forms.Panel
$pnlNavTop.Dock      = 'Top'
# 9 个模块 × 44 + 首项上边距 8 = 404，面板留 412
$pnlNavTop.Height    = 412
$pnlNavTop.BackColor = $Pal.NavBg
$pnlNav.Controls.Add($pnlNavTop)

function New-NavItem {
    param(
        [string]$Text,
        [int]$Y,
        [string]$Icon,
        [string]$PageKey = '',            # 页面项：点了走 Show-GuiPage
        [string]$ModuleKey = '',          # 模块项：点了进模块（模块有子页就顶替成分类列）
        [scriptblock]$OnClick = $null,    # 纯动作项（例如分类列顶部的「返回模块」）
        [System.Windows.Forms.Control]$Parent = $null
    )
    # 侧栏 200、左右各留 8（HMOL NavItem Margin=8,2）→ 项宽 184
    $w = 184
    $h = $script:NavItemH
    $p = New-Object System.Windows.Forms.Panel
    $p.Size      = New-Object System.Drawing.Size($w, $h)
    $p.Location  = New-Object System.Drawing.Point(8, $Y)
    $p.BackColor = $Pal.NavBg
    $p.Cursor    = 'Hand'
    # Radius.Item = 10（HMOL）
    $p.Tag       = @{ Page = $PageKey; Module = $ModuleKey; Act = $OnClick; Icon = $Icon; Text = $Text; Active = $false; Hover = $false; Radius = 8 }
    Enable-UiDoubleBuffer -Control $p
    Set-Rounded -Control $p -Radius 8

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
            # 选中指示条：3x18 圆角小条，贴项的左内边（HMOL 模板第 0 列就是这 3px）
            if ($t.Active) {
                $bp = New-UiRoundPath -Width 3 -Height 18 -Radius 2
                $bb = New-Object System.Drawing.SolidBrush($Pal.NavBar)
                try {
                    $g.TranslateTransform(1, [int](($s.Height - 18) / 2))
                    $g.FillPath($bb, $bp)
                    $g.TranslateTransform(-1, -[int](($s.Height - 18) / 2))
                } finally { $bb.Dispose(); $bp.Dispose() }
            }

            $fore = $(if ($t.Active) { $Pal.NavTextHi } else { $Pal.NavText })
            # 图标 17、左边距 12（前面是 3px 指示条列）
            $isz  = 17
            Draw-UiIcon -Graphics $g -Name ([string]$t.Icon) -X 15 -Y ([int](($s.Height - $isz) / 2)) -Size $isz -Color $fore

            # ⚠ 这里必须先把每个实参算进变量，再调用 DrawText。
            # 直接写 `DrawText($g, $txt, $font, $rect, (FLAGS -bor FLAGS), $color)` 是不行的：
            # PowerShell 里逗号是**数组运算符**，`(… -bor …), $color` 会被当成"一个数组实参"，
            # 于是实参整体错位、foreColor 收到的是 TextFormatFlags → 抛类型转换异常，
            # 而异常被 catch 吞掉的表现就是"图标画出来了、文字一个字都没有"（实测踩到）。
            $txt   = [string]$t.Text
            # HMOL 的 NavItem 选中态只换颜色与指示条，文字不加粗
            $font  = $script:NavFont
            # 文字起点 43 = 指示条 3 + 图标左距 12 + 图标 18 + 文字左距 10（HMOL 模板三列）
            $rect  = New-Object System.Drawing.Rectangle(43, 0, ($s.Width - 55), $s.Height)
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor `
                     [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                     [System.Windows.Forms.TextFormatFlags]::SingleLine -bor `
                     [System.Windows.Forms.TextFormatFlags]::NoPadding
            [System.Windows.Forms.TextRenderer]::DrawText($g, $txt, $font, $rect, $fore, $flags)
        } catch { }
    })
    $p.Add_MouseEnter({ $this.Tag.Hover = $true;  $this.Invalidate() })
    $p.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Invalidate() })
    $p.Add_Click({
        try {
            $t = $this.Tag
            if ($t.Page)       { Show-GuiPage -Key ([string]$t.Page) }
            elseif ($t.Module) { Enter-GuiModule -Key ([string]$t.Module) }
            elseif ($t.Act)    { & $t.Act }
        } catch { }
    })
    if ($Parent) { $Parent.Controls.Add($p) } else { $pnlNavTop.Controls.Add($p) }
    return $p
}

function Add-PageAdvancedButton {
    # 在 PageHeader 右侧挂一个「高级设置」入口。
    # 点击后由 Show-ActionsDialog 按页面传入的分组过滤动作 —— 这样「更多」页就不再是
    # 一个装着全部动作的大杂烩，各功能回到各自页面（用户第 37 条的要求）。
    param(
        [System.Windows.Forms.Control]$Header,
        [string]$Title = '高级设置',
        [string[]]$Groups = @()
    )
    if (-not $Header) { return $null }
    $b = New-FlatButton -Text '高级设置' -Width 92 -Height 28
    $b.Location = New-Object System.Drawing.Point([Math]::Max(0, ($Header.Width - 94)), 6)
    $b.Anchor   = 'Top,Right'
    # 动作分组存进 Tag：点击时读 $this.Tag，不依赖函数局部变量（回调在函数返回后执行）
    $b.Tag      = @{ Title = $Title; Groups = $Groups }
    $b.Add_Click({
        Show-ActionsDialog -Title ([string]$this.Tag.Title) -Groups @($this.Tag.Groups)
    })
    $Header.Controls.Add($b)
    $Header.Tag.Advanced = $b
    return $b
}

# HMOL NavItem 文字 13.5 DIP ≈ 10.1pt
$script:NavFont     = New-Font -Size 10
$script:NavFontBold = New-Font -Size 10 -Style Bold

# ---- 7 大模块（路线图第二节 + 运维面板第一批）----
# 16 个页面按模块归组；模块有多个子页时，点进去侧栏「顶替」成分类列表
#（HMOL 的 PanNav ↔ PanSetupNav 那套：只翻 Visibility，不新建第二个侧栏）。
$script:GuiPageMeta = @{
    'monitor'  = @{ Text = '总览';       Icon = 'monitor'  }
    'store'    = @{ Text = '应用商店';   Icon = 'store'    }
    'env'      = @{ Text = '环境补全';   Icon = 'env'      }
    'role'     = @{ Text = '角色与功能'; Icon = 'role'     }
    'security' = @{ Text = '安全基线';   Icon = 'security' }
    'app'      = @{ Text = '程序档案';   Icon = 'app'      }
    'tool'     = @{ Text = '系统工具';   Icon = 'tool'     }
    'beauty'   = @{ Text = '终端美化';   Icon = 'beauty'   }
    'dsh'      = @{ Text = 'AI 辅助';    Icon = 'dsh'      }
    'logs'     = @{ Text = '日志中心';   Icon = 'logs'     }
    'tasks'    = @{ Text = '任务中心';   Icon = 'tasks'    }
    'audit'    = @{ Text = '结构审计';   Icon = 'audit'    }
    'hosts'    = @{ Text = '远程主机';   Icon = 'hosts'    }
    'more'     = @{ Text = '全部功能';   Icon = 'more'     }
    'about'    = @{ Text = '关于';       Icon = 'about'    }
}
$script:GuiModules = @(
    @{ Key = 'dash';  Text = '仪表盘';   Icon = 'monitor'; Pages = @('monitor') }
    @{ Key = 'store'; Text = '应用商店'; Icon = 'store';   Pages = @('store') }
    @{ Key = 'env';   Text = '环境管理'; Icon = 'env';     Pages = @('env', 'role', 'security') }
    # 程序管理：程序档案 / 系统工具 / 终端美化 / AI 辅助（美化与 AI 从「设置」挪过来 —— 它们都是"装东西"）
    @{ Key = 'prog';  Text = '程序管理'; Icon = 'app';     Pages = @('app', 'tool', 'beauty', 'dsh') }
    # 运维面板第一批：日志 + 任务 + 审计（文件管理已移除：装过 FOD 的机器自带资源管理器）
    @{ Key = 'ops';   Text = '运行日志'; Icon = 'logs';    Pages = @('logs') }
    @{ Key = 'run';   Text = '任务与审计'; Icon = 'tasks'; Pages = @('tasks', 'audit') }
    # 运维面板第二批：WinRM 多主机（后续批次的远程终端也挂在这一组）
    @{ Key = 'remote'; Text = '远程运维'; Icon = 'hosts'; Pages = @('hosts') }
    @{ Key = 'set';   Text = '设置';     Icon = 'more';    Pages = @('more', 'about') }
)
$script:GuiModuleOfPage   = @{}
$script:GuiModuleLastPage = @{}
foreach ($__m in $script:GuiModules) { foreach ($__p in $__m.Pages) { $script:GuiModuleOfPage[$__p] = $__m.Key } }

function Get-GuiModule {
    param([string]$Key)
    foreach ($m in $script:GuiModules) { if ([string]$m.Key -eq $Key) { return $m } }
    return $null
}

function Get-GuiModuleOfPage {
    param([string]$PageKey)
    if ($script:GuiModuleOfPage.ContainsKey($PageKey)) { return [string]$script:GuiModuleOfPage[$PageKey] }
    return ''
}

function Sync-GuiNav {
    # 模块项按「当前页属于哪个模块」高亮；分类项按「是不是当前页」高亮。
    param([string]$PageKey)
    $modKey = Get-GuiModuleOfPage -PageKey $PageKey
    foreach ($b in @($script:NavButtons)) {
        try {
            $on = ([string]$b.Tag.Module -eq $modKey)
            if ($b.Tag.Active -ne $on) { $b.Tag.Active = $on; $b.Invalidate() }
        } catch { }
    }
    foreach ($b in @($script:CatButtons)) {
        try {
            $on = ([string]$b.Tag.Page -eq $PageKey)
            if ($b.Tag.Active -ne $on) { $b.Tag.Active = $on; $b.Invalidate() }
        } catch { }
    }
}

function Set-GuiSidebarMode {
    # 侧栏两种形态二选一：模块列表 / 某模块的分类列表。只翻 Visibility，不新建侧栏。
    param([string]$Mode, [string]$PageKey = '')
    try {
        $mod = $null
        if ($Mode -eq 'cats') {
            $mod = Get-GuiModule -Key (Get-GuiModuleOfPage -PageKey $PageKey)
            # 只有单个子页的模块不值得再点一层，直接留在模块列表
            if (-not $mod -or @($mod.Pages).Count -le 1) { $Mode = 'modules' }
        }

        if ($Mode -ne 'cats') {
            $pnlNavCats.Visible = $false
            $pnlNavTop.Visible  = $true
            return
        }

        # 同一个模块内部切页时不要重建分类列。
        # 每次重建都要 Dispose/新建一批自绘 Panel 并重设 Region，而 Region 走的是 GDI+
        # 路径计算 —— 在 Server Core 的软件渲染下这一下很明显（实测"切页卡"的一条来源）。
        $__want = [string]$mod.Key
        if ($pnlNavCats.Visible -and ([string]$script:CatsModule) -eq $__want) { return }
        $script:CatsModule = $__want

        # 重建分类项：最多 5 项，代价可忽略；省掉一堆「哪个模块的第几项」索引状态
        foreach ($c in @($pnlNavCats.Controls)) { try { $c.Dispose() } catch { } }
        $script:CatButtons = @()
        $y = 8
        $back = New-NavItem -Text '返回模块' -Y $y -Icon 'chevron-left' `
                    -OnClick { Set-GuiSidebarMode -Mode 'modules' -PageKey $script:CurrentPage } `
                    -Parent $pnlNavCats
        $y += $script:NavStep
        foreach ($pg in @($mod.Pages)) {
            $meta = $script:GuiPageMeta[$pg]
            if (-not $meta) { continue }
            $it = New-NavItem -Text ([string]$meta.Text) -Y $y -Icon ([string]$meta.Icon) -PageKey $pg -Parent $pnlNavCats
            $script:CatButtons += $it
            $y += $script:NavStep
        }
        $pnlNavCats.Height  = $y
        $pnlNavTop.Visible  = $false
        $pnlNavCats.Visible = $true
    } catch { }
}

function Enter-GuiModule {
    # 进模块：有子页就顶替成分类列，并回到「上次停留的那个分类」（HMOL 的做法）。
    param([string]$Key)
    $mod = Get-GuiModule -Key $Key
    if (-not $mod) { return }
    $last = [string]$script:GuiModuleLastPage[$Key]
    if (-not $last -or (@($mod.Pages) -notcontains $last)) { $last = [string]@($mod.Pages)[0] }
    Show-GuiPage -Key $last
}

$script:NavButtons = @()
$script:CatButtons = @()
$script:GuiModuleLastPage = @{}
$script:CatsModule = ''      # 分类侧栏当前正在显示哪个模块（用来避免同模块内切页时重建）

# 侧栏顶部的分类面板：与模块列表同处一格，靠显隐互斥（HMOL 的做法）
$pnlNavCats           = New-Object System.Windows.Forms.Panel
$pnlNavCats.Dock      = 'Top'
$pnlNavCats.Height    = 236
$pnlNavCats.BackColor = $Pal.NavBg
$pnlNavCats.Visible   = $false
$pnlNav.Controls.Add($pnlNavCats)

$__y = 8
foreach ($__mod in $script:GuiModules) {
    $script:NavButtons += (New-NavItem -Text ([string]$__mod.Text) -Y $__y -Icon ([string]$__mod.Icon) -ModuleKey ([string]$__mod.Key))
    $__y += $script:NavStep
}
$pnlNavTop.Height = $__y

$lblVer = New-Label -Text ('v2.0  ·  ' + (Get-Date -Format 'yyyy-MM-dd')) -Size 8.25 -Color Hint
$lblVer.Dock = 'Bottom'
$lblVer.Height = 30
$lblVer.TextAlign = 'MiddleLeft'
$lblVer.Padding = New-Object System.Windows.Forms.Padding(16, 0, 0, 0)
$pnlNav.Controls.Add($lblVer)

# 侧栏右侧的 1px 分隔线：必须在 lblVer 之后加 —— 后加的先停靠，
# 这样它是"整条竖线"（Right 停靠拿到的是整个侧栏高度），而不是被底部版本号截断。
$pnlNavLine           = New-Object System.Windows.Forms.Panel
$pnlNavLine.Dock      = 'Right'
$pnlNavLine.Width     = 1
$pnlNavLine.BackColor = $Pal.TitleLine
$pnlNav.Controls.Add($pnlNavLine)

# ---- 右侧内容 + 日志 ----
# 内容区与日志都在同一个内边距里（24/16，对齐 HMOL 页面的 24,20,24,16），日志默认 190 高、可折叠到只剩标题栏。
$pnlRight = New-Object System.Windows.Forms.Panel
$pnlRight.Dock      = 'Fill'
$pnlRight.BackColor = $Pal.Bg
$pnlRight.Padding   = New-Object System.Windows.Forms.Padding(24, 16, 24, 16)
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
        $jid = [string]$script:CurrentJobId
        try { Stop-Process -Id $script:Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        # 进程被杀后 runner 没有机会写结果，这里把任务记录补成“已取消”，任务页才不会一直显示运行中。
        if ($jid) {
            try { [void](Complete-GuiReadyTask -Id $jid -Status 'Canceled' -ExitCode (-1) -Message '用户停止当前动作' -Quiet) } catch { }
        }
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
# ⚠ 从这里开始到最后一页注册完成为止，全部走"延迟设 Region"（见 Set-Rounded 的说明）。
# 外壳 / 标题栏 / 侧栏 / 日志面板在上一段已经建完，它们必须立即设 Region ——
# 那些控件不在任何页面里，不会被 Show-GuiPage 的补钩子扫到，延迟了就永远是方角。
$script:RoundDefer = $true

$pageEnv           = New-Object System.Windows.Forms.Panel
$pageEnv.Dock      = 'Fill'
$pageEnv.BackColor = $Pal.Bg
$pageEnv.AutoScroll = $true     # 窗口很小的时候宁可出滚动条，也不要裁掉内容
$script:Pages['env'] = $pageEnv
$pnlContent.Controls.Add($pageEnv)

# HMOL PageHeader：38px 图标块 + 13.5pt 粗标题 + 9pt 副标题（右侧留给本页操作按钮）
$hdrEnv = New-PageHeader -Title '环境补全' -Subtitle '先看这台机器缺什么，再一键补齐。补齐后 Server Core 就能运行带界面的程序。' -Icon 'env' -Width 900
$pageEnv.Controls.Add($hdrEnv)
$lblEnvHead = $hdrEnv.Tag.Title
$lblEnvDesc = $hdrEnv.Tag.Sub
[void](Add-PageAdvancedButton -Header $hdrEnv -Title '环境补全' -Groups @('一键流程', '补给'))

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

# 软件页控件按需构建（首次显示本页时执行）：页头、程序列表、按钮区与提示条
function Build-AppPage {
$hdrApp = New-PageHeader -Title '软件管理' -Subtitle '把你需要的程序加进来，双击即可启动。加程序时会自动带入实测推荐参数（例如 Electron 类程序会带上禁用 GPU 的参数）。' -Icon 'app' -Width 900
$pageApp.Controls.Add($hdrApp)
$lblAppHead = $hdrApp.Tag.Title
$lblAppDesc = $hdrApp.Tag.Sub
[void](Add-PageAdvancedButton -Header $hdrApp -Title '程序档案' -Groups @('程序档案'))

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
[void]$lstApps.Columns.Add('命令', 90)
$pageApp.Controls.Add($lstApps)
Enable-GuiListViewSkin -List $lstApps

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

# 给这个程序绑一个终端命令（例如微信绑 wx，敲 wx 就打开它）
$btnAppCmd = New-FlatButton -Text '绑定命令…' -Width 110 -Height 38
$btnAppCmd.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
$pnlAppActions.Controls.Add($btnAppCmd)

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

# 写回脚本作用域：布局函数、Refresh-ProgramList、Get-SelectedProgram 以及本页事件绑定都要用
$script:hdrApp         = $hdrApp
$script:lstApps        = $lstApps
$script:pnlAppActions  = $pnlAppActions
$script:hintApp        = $hintApp
$script:btnAppAdd      = $btnAppAdd
$script:btnAppRun      = $btnAppRun
$script:btnAppArgs     = $btnAppArgs
$script:btnAppCmd      = $btnAppCmd
$script:btnAppPersist  = $btnAppPersist
$script:btnAppDiag     = $btnAppDiag
$script:btnAppCatalog  = $btnAppCatalog
$script:btnAppDel      = $btnAppDel
Bind-AppEvents
# 首次数据填充：启动时不再建这页的列表，切过来时读一次程序清单
Load-Programs
Refresh-ProgramList
}
$script:PageBuilders['app'] = 'Build-AppPage'

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
           Hint = '还没安装美化终端。可以在「更多 → 终端美化 → 一键美化终端」里装（Nerd Font + Oh My Posh + Fastfetch，素材按需下载，需要联网）。装好后任意目录输入 scm-term 就能打开 UTF-8 + Nerd Font 的控制台。' }
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

# HMOL PageHeader：38px 图标块 + 13.5pt 粗标题 + 9pt 副标题（右侧留给本页操作按钮）
$hdrTool = New-PageHeader -Title '系统工具' -Subtitle 'Server Core 默认没有这些图形工具，装了官方 App Compatibility FOD 才会出现；标了「（缺失）」的表示当前机器上还没有 —— 点它可以直接开始补。' -Icon 'tool' -Width 900
$pageTool.Controls.Add($hdrTool)
$lblToolHead = $hdrTool.Tag.Title
$lblToolDesc = $hdrTool.Tag.Sub
[void](Add-PageAdvancedButton -Header $hdrTool -Title '系统工具' -Groups @('Windows Admin Center'))

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

# 设置页控件按需构建（首次显示本页时执行）：页头、左侧功能树、右侧参数面板与运行按钮
function Build-MorePage {
$hdrMore = New-PageHeader -Title '设置' -Subtitle '开机与登录、持久化启动、登录 Shell。其它高级功能已按功能域放到各自页面的「高级设置」里。' -Icon 'more' -Width 900
$pageMore.Controls.Add($hdrMore)
$lblMoreHead = $hdrMore.Tag.Title
$lblMoreDesc = $hdrMore.Tag.Sub

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

# 写回脚本作用域：布局函数、Select-GuiAction、Start-GuiAction 都要用这些控件
$script:hdrMore     = $hdrMore
$script:tree        = $tree
$script:pnlMoreRight = $pnlMoreRight
$script:lblActTitle = $lblActTitle
$script:lblActDesc  = $lblActDesc
$script:pnlParams   = $pnlParams
$script:btnRun      = $btnRun
$script:btnDry      = $btnDry
Bind-MoreEvents
}
$script:PageBuilders['more'] = 'Build-MorePage'

# ============================ 应用商店页 ============================
# 「应用商店 2.0」的第一步：Chocolatey 主线（搜索 / 安装 / 卸载），Scoop 只做安装与卸载，
# npm / pip 先只做检测。能力在 lib\GuiReady.Package.ps1。
#
# 一切慢查询都在子进程里做（choco search 是网络调用，几秒起步），页面只负责显示：
# 走的还是「环境卡片」那套套路 —— 子进程写 JSON → 定时器轮询 → 回填界面。

$pageStore              = New-Object System.Windows.Forms.Panel
$pageStore.Dock         = 'Fill'
$pageStore.BackColor    = $Pal.Bg
$script:Pages['store']  = $pageStore
$pnlContent.Controls.Add($pageStore)

# 商店页控件按需构建（首次显示本页时执行）：页头、源状态行、搜索行、筛选行、结果区与轮询定时器
function Build-StorePage {
# HMOL PageHeader：38px 图标块 + 13.5pt 粗标题 + 9pt 副标题（右侧留给本页操作按钮）
$hdrStore = New-PageHeader -Title '应用商店' -Subtitle '从包管理器装工具。主线是 Chocolatey（搜索 / 安装 / 卸载）；Scoop 可安装与卸载（搜索未接入）；npm / pip 先只做检测。' -Icon 'store' -Width 900
$pageStore.Controls.Add($hdrStore)
$lblStoreHead = $hdrStore.Tag.Title
$lblStoreDesc = $hdrStore.Tag.Sub

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

# ---- 界面类型筛选行（按钮由 Update-StoreUiFilter 动态生成）----
# 用户要求：商店里的工具再按"跑起来要不要图形环境"分一次类（CLI / TUI / GUI）。
# cli/tui 在 Server Core 上本来就能跑，gui 才需要 FOD —— 这一维比场景分类更贴近"能不能用"。
$pnlStoreFilter           = New-Object System.Windows.Forms.Panel
$pnlStoreFilter.Location  = New-Object System.Drawing.Point(0, 144)
$pnlStoreFilter.Size      = New-Object System.Drawing.Size(900, 32)
$pnlStoreFilter.Anchor    = 'Top,Left,Right'
$pnlStoreFilter.BackColor = $Pal.Bg
$pageStore.Controls.Add($pnlStoreFilter)

$lblStoreFilter          = New-Label -Text '界面类型' -Size 9.5 -Color Hint
$lblStoreFilter.Location = New-Object System.Drawing.Point(4, 6)
$pnlStoreFilter.Controls.Add($lblStoreFilter)

# ---- 批量安装队列 ----
# 行左侧有勾选框（Add-StoreRow），这里放两个入口：
#   安装选中：按勾选顺序排队安装（单个失败不中断）
#   重试失败：只重跑上次队列里失败的条目（state\store-queue.json）
$btnStoreQueue          = New-FlatButton -Text '安装选中' -Kind Primary -Width 104 -Height 30
$btnStoreQueue.Location = New-Object System.Drawing.Point(460, 1)
$btnStoreQueue.Enabled  = $false
$pnlStoreFilter.Controls.Add($btnStoreQueue)

$btnStoreRetry          = New-FlatButton -Text '重试失败' -Width 96 -Height 30
$btnStoreRetry.Location = New-Object System.Drawing.Point(572, 1)
$btnStoreRetry.Visible  = $false
$pnlStoreFilter.Controls.Add($btnStoreRetry)

$hintStore = New-HintBar -Text '目标场景是刚装好的 Server Core（机上什么都没有），所以本机没有包管理器时**工具会自动先装 Chocolatey**（点搜索就会触发，装完接着搜）。搜索源选「全部源」会同时查 Chocolatey 与 npm（npm 走 registry、约 10 秒；Scoop 搜索与 pip search 未接入）。批量队列只收 Chocolatey 条目；npm 结果请逐条安装。所有安装动作都会写进下方日志；不确定就先按「仅预览」看要执行什么命令。' -Kind 'Blue' -Width 900
$hintStore.Location = New-Object System.Drawing.Point(0, 180)
$pageStore.Controls.Add($hintStore)

$barStore           = New-ProgressBar -Width 420 -Height 6 -Indeterminate
$barStore.Location  = New-Object System.Drawing.Point(0, 218)
$barStore.Visible   = $false
$pageStore.Controls.Add($barStore)

$pnlStoreResults             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlStoreResults.Location    = New-Object System.Drawing.Point(0, 232)
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
$script:StoreUiFilter    = ''       # 界面类型筛选：'' 全部 | cli | tui | gui
$script:StoreUiBtns      = @()      # 界面类型筛选按钮（重建时一并释放）
$script:StoreLocalHits   = @()      # 本次搜索命中的本地精选（与上游结果合并时精选优先）
$script:StoreLocal       = @()      # 本机已装的包名（用来标「已安装」）
$script:StoreOutdated    = @{}      # 可更新的包：id -> { Current; Available }（choco outdated）
$script:StoreChecked     = @{}      # 勾选待批量安装的包：id -> $true（重建行时回填）
$script:StoreQueueFailed = @()      # 上次队列的失败项（state\store-queue.json）
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
$script:StoreSourceIndex = @{ choco = 1; scoop = 2; npm = 3 }

$script:StoreTimer = New-Object System.Windows.Forms.Timer
$script:StoreTimer.Interval = 250
$script:StoreTimer.Add_Tick({ Update-StoreTick })

# 写回脚本作用域：布局函数、Show-StoreResult/Update-StoreSourceRow 以及本页事件绑定都要用这些控件
$script:hdrStore        = $hdrStore
$script:lblStoreDesc    = $lblStoreDesc
$script:pnlStoreSrc     = $pnlStoreSrc
$script:lblStoreSrcHint = $lblStoreSrcHint
$script:pnlStoreSearch  = $pnlStoreSearch
$script:txtStoreQuery   = $txtStoreQuery
$script:cmbStoreSrc     = $cmbStoreSrc
$script:btnStoreSearch  = $btnStoreSearch
$script:pillStoreState  = $pillStoreState
$script:pnlStoreFilter  = $pnlStoreFilter
$script:btnStoreQueue   = $btnStoreQueue
$script:btnStoreRetry   = $btnStoreRetry
$script:hintStore       = $hintStore
$script:barStore        = $barStore
$script:pnlStoreResults = $pnlStoreResults
$script:lblStoreEmpty   = $lblStoreEmpty
Bind-StoreEvents
}
$script:PageBuilders['store'] = 'Build-StorePage'

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
        'searchall' { Set-StoreBusy -Text ('正在搜索全部源 ' + $Query + ' …（npm 较慢）') -Kind 'Info' }
        'local'  { Set-StoreBusy -Text '正在读取已装清单…' -Kind 'Info' }
        'outdated' { Set-StoreBusy -Text '正在检查可更新…' -Kind 'Info' }
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

    $title = [string]$Item.Id
    if ($Item.PSObject.Properties['DisplayName'] -and $Item.DisplayName) { $title = [string]$Item.DisplayName }

    # 勾选框：批量安装队列用。勾选状态存在 $script:StoreChecked，列表重绘（已装/可更新刷新）后回填。
    # 只给 Chocolatey / 精选条目：队列按包名走 choco，npm 包（尤其 @scope/name）塞进去会装错源。
    $chk = $null
    if ([string]$Item.Source -eq 'choco') {
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Location  = New-Object System.Drawing.Point(10, 18)
        $chk.Size      = New-Object System.Drawing.Size(18, 18)
        $chk.FlatStyle = 'Flat'
        $chk.BackColor = $Pal.Card
        $chk.ForeColor = $Pal.Text
        $chk.Tag       = [string]$Item.Id
        $chk.Checked   = $script:StoreChecked.ContainsKey([string]$Item.Id)
        $chk.Add_Click({
            $id = [string]$this.Tag
            if ($this.Checked) { $script:StoreChecked[$id] = $true } else { $script:StoreChecked.Remove($id) }
            Update-StoreQueueUi
        })
        $row.Controls.Add($chk)
    }

    $lbName = New-Label -Text $title -Size 10 -Style Bold -Width ($rowW - 330)
    $lbName.Location = New-Object System.Drawing.Point(38, 9)
    $row.Controls.Add($lbName)

    $ver  = [string]$Item.Version
    $srcName = Get-StoreSourceName ([string]$Item.Source)
    if ($Item.PSObject.Properties['Label'] -and $Item.Label) { $srcName = [string]$Item.Label }
    $meta = ('{0}   ·   来自 {1}' -f $(if ($ver) { 'v' + $ver } else { '版本未知' }), $srcName)
    # 精选条目带兼容性标记（✅/⚠️/❌），把设计文档里那三档文案显式摆出来
    if ($Item.PSObject.Properties['Marker'] -and $Item.Marker) { $meta = ([string]$Item.Marker + '   ·   ' + $meta) }
    # 可更新：choco outdated 的结果（后台查，拿到后重绘时生效）
    $pkgId = [string]$Item.Id
    $upd = $null
    if ($script:StoreOutdated -and $script:StoreOutdated.ContainsKey($pkgId)) { $upd = $script:StoreOutdated[$pkgId] }
    if ($upd) { $meta = ('🔄 可更新 {0} → {1}   ·   {2}' -f [string]$upd.Current, [string]$upd.Available, $meta) }
    # npm 搜索结果带一句描述（choco 的 --limit-output 没有描述）
    if ($Item.PSObject.Properties['Description'] -and $Item.Description) {
        $desc = ([string]$Item.Description -replace "`r?`n", ' ').Trim()
        if ($desc.Length -gt 90) { $desc = $desc.Substring(0, 90) + '…' }
        $meta = $meta + '   ·   ' + $desc
    }
    $lbMeta = New-Label -Text $meta -Size 8.5 -Color Hint -Width ($rowW - 330)
    $lbMeta.Location = New-Object System.Drawing.Point(38, 31)
    $row.Controls.Add($lbMeta)

    $installed = ($script:StoreLocal -contains $pkgId)
    $pill = $null
    if ($upd) {
        $pill = New-Pill -Text '可更新' -Kind 'Warn'
        $row.Controls.Add($pill)
    } elseif ($installed) {
        $pill = New-Pill -Text '已安装' -Kind 'Success'
        $row.Controls.Add($pill)
    }

    $btnIns = New-FlatButton -Text $(if ($upd) { '更新' } else { '安装' }) -Kind Primary -Width 80 -Height 30
    # Cat=精选库条目：只有精选条目才走 store-install（带 FOD / Containers 前置检查）。
    # 不能只按包名判断 —— npm 上的包名可能刚好和精选库某个 id 重名（例如 nodejs）。
    $btnIns.Tag = @{ Pkg = [string]$Item.Id; Src = [string]$Item.Source; Cat = ([string]$Item.Label -eq '精选') }
    $btnIns.Add_Click({
        $pkg = [string]$this.Tag.Pkg
        if ([bool]$this.Tag.Cat) {
            Start-StoreAction -Id 'store-install' -Params @{ AppId = $pkg }
        } else {
            Start-StoreAction -Id 'pkg-install' -Params @{
                Source  = $script:StoreSourceIndex[[string]$this.Tag.Src]
                Package = $pkg
            }
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

    # 「详情」：在同一个结果区里换成详情视图（choco info 的输出，见 Get-GuiReadyPackageInfo）。
    # npm 结果没有 choco info 可查，索性不摆这个按钮，免得点下去只得到一句"不支持"。
    $btnInfo = $null
    if ([string]$Item.Source -eq 'choco') {
        $btnInfo = New-FlatButton -Text '详情' -Width 64 -Height 30
        $btnInfo.Tag = @{ Pkg = [string]$Item.Id; Src = [string]$Item.Source }
        $btnInfo.Add_Click({
            Show-StoreDetail -Package ([string]$this.Tag.Pkg) -Source ([string]$this.Tag.Src)
        })
        $row.Controls.Add($btnInfo)
    }

    $pnlStoreResults.Controls.Add($row)
    $script:StoreRows += [pscustomobject]@{ Panel = $row; Name = $lbName; Meta = $lbMeta; Check = $chk; Install = $btnIns; Uninstall = $btnUn; Info = $btnInfo; Pill = $pill }
}

function ConvertTo-StoreRowItem {
    # 把 catalog 里的一条精选记录，转成 Add-StoreRow 认识的"结果行"形状。
    # 只有 install.type = choco 的条目才转：安装按钮把 Source 当作 $script:StoreSourceIndex
    # 的键，索引里只有 choco=1/scoop=2，npm/pip 会传错源。转不了返回 $null。
    param($Entry)
    if (-not $Entry) { return $null }
    if (([string]$Entry.install.type).ToLower() -ne 'choco') { return $null }
    $pkg = [string]$Entry.install.id
    if (-not $pkg) { return $null }

    $mark = '⚠️ 未验证'
    switch ([string]$Entry.compatibility) {
        'verified'    { $mark = '✅ 精选 · 实测可用' }
        'partial'     { $mark = '⚠️ 可用 · 部分功能受限' }
        'unsupported' { $mark = '❌ 不兼容 · 见替代方案' }
    }
    return [pscustomobject]@{
        Id          = $pkg
        Version     = ''
        Source      = 'choco'
        Label       = '精选'
        DisplayName = $(if ($Entry.name_zh) { [string]$Entry.name_zh } else { [string]$Entry.name })
        Marker      = $mark
    }
}

function Update-StoreUiFilter {
    # 重建 [全部][CLI][TUI][GUI] 四个筛选按钮，当前选中的那个用 Primary 高亮。
    # 数据来自 catalog 的 ui 字段：它决定这个工具"跑起来要不要图形环境"，
    # 是本项目在 Server Core 上最该让用户先看到的一维（比场景分类更贴近"能不能用"）。
    # 注意：按钮上的值先存进 $btn.Tag，点击时读 $this.Tag —— 直接在脚本块里用循环变量 $d
    # 会被最后一个值覆盖（PowerShell 脚本块按引用捕获变量）。
    try {
        foreach ($b in @($script:StoreUiBtns)) { try { $b.Dispose() } catch { } }
        $script:StoreUiBtns = @()
        $defs = @(
            @{ T = '全部'; V = '' },
            @{ T = 'CLI';  V = 'cli' },
            @{ T = 'TUI';  V = 'tui' },
            @{ T = 'GUI';  V = 'gui' }
        )
        $x = 76
        foreach ($d in $defs) {
            $sel = ($script:StoreUiFilter -eq [string]$d.V)
            $btn = New-FlatButton -Text $d.T -Kind $(if ($sel) { 'Primary' } else { 'Normal' }) -Width 66 -Height 30
            $btn.Location = New-Object System.Drawing.Point($x, 1)
            $btn.Tag      = [string]$d.V
            $btn.Add_Click({
                $script:StoreUiFilter = [string]$this.Tag
                Update-StoreUiFilter
                Add-StoreCatalogRows | Out-Null
            })
            $pnlStoreFilter.Controls.Add($btn)
            $script:StoreUiBtns += $btn
            $x += 74
        }
    } catch { }
}

function Add-StoreCatalogRows {
    # 把本地精选库铺成结果行（按当前"界面类型"筛选 + 热度排序）。返回铺了几行。
    #
    # 为什么只铺 install.type = choco 的条目：
    #   安装按钮把 Item.Source 当作 $script:StoreSourceIndex 的键（choco=1 / scoop=2），
    #   而索引里没有 npm/pip —— 铺出来点了"安装"会往动作里传错源。
    #   npm 那些条目先不铺（要铺得先把 npm 接进索引与动作，属下一步）。
    #
    # 每次先清空：这个函数会被那排"界面类型"筛选按钮反复调用，不清就会一行行叠上去。
    Clear-StoreRows
    Clear-StoreDetail
    $c = Import-GuiReadyStoreCatalog
    if (-not $c.Ok) {
        # 不静默：这里曾经什么都不做也不报错，结果"商店页没铺出精选"查了很久
        try { Append-GuiLog -Line ('[WARN] 精选库不可用: ' + $c.Error + '  path=' + $c.Path) } catch { }
        $lblStoreEmpty.Visible = $true
        $lblStoreEmpty.Text    = '精选库不可用（见下方日志）。'
        return 0
    }

    $n = 0
    # -Ui 传 $script:StoreUiFilter（'' 全部 / cli / tui / gui）；无关键词时后端按兼容性+热度排，
    # 所以"全部"= 热门优先，正好是用户要的"自动展示热度较高的工具"。
    foreach ($e in @(Search-GuiReadyStore -Ui $script:StoreUiFilter -Limit 60)) {
        $item = ConvertTo-StoreRowItem -Entry $e
        if (-not $item) { continue }
        Add-StoreRow -Item $item
        $n++
    }
    # 空状态：整个库里没有这个类型，或者被筛没了 —— 要给一句话，不能留一片空白
    $lblStoreEmpty.Visible = ($n -eq 0)
    if ($n -eq 0) { $lblStoreEmpty.Text = '这个界面类型下暂时没有精选条目，换个筛选看看。' }
    Update-StoreRowLayout
    return $n
}

function Update-StoreRowLayout {
    # 结果行的宽度和按钮都右对齐，窗口一改就得跟着挪
    $rowW = Get-StoreRowWidth
    foreach ($r in $script:StoreRows) {
        try {
            $r.Panel.Width = $rowW
            $r.Name.Width  = $rowW - 330
            $r.Meta.Width  = $rowW - 330
            # 三个按钮从右往左排、间距统一 8px：
            #   详情 [rowW-96, rowW-32] · 卸载 [rowW-184, rowW-104] · 安装 [rowW-272, rowW-192]
            # 上一版是 -256/-168/-96，卸载右边界 rowW-88 压住详情左边界 rowW-96（交叠 8px）。
            # 之所以一直没暴露：商店页以前没有真实行，重叠扫描扫不到；铺出 12 行精选后就报了 24 处。
            $r.Install.Location   = New-Object System.Drawing.Point(($rowW - 272), 13)
            $r.Uninstall.Location = New-Object System.Drawing.Point(($rowW - 184), 13)
            if ($r.Info) { $r.Info.Location = New-Object System.Drawing.Point(($rowW - 96), 13) }
            if ($r.Pill) { $r.Pill.Location = New-Object System.Drawing.Point(($rowW - 280 - $r.Pill.Width), 17) }
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

    # 安装入口：精选库条目走完整流程（含前置检查），其他包走裸安装
    $hit = Get-GuiReadyStoreEntry -Id $pk
    if ($hit) {
        $hitName = [string]$pk
        if ($hit.name_zh) { $hitName = [string]$hit.name_zh }
        $script:StoreDetailRows += (Add-UiRow -Container $pnlStoreResults -Title '安装' `
            -Meta ('按精选库完整流程安装：' + $hitName + '（兼容性 / FOD / 功能依赖检查）') `
            -Height 50 -BtnText '安装' -BtnTag @{ App = $pk } `
            -BtnClick { Start-StoreAction -Id 'store-install' -Params @{ AppId = [string]$this.Tag.App } })
    } else {
        $script:StoreDetailRows += (Add-UiRow -Container $pnlStoreResults -Title '安装' `
            -Meta ('裸包安装：{0} install {1} -y --no-progress' -f $(if ($src -eq 'scoop') { 'scoop' } else { 'choco' }), $pk) `
            -Height 50 -BtnText '安装' -BtnTag @{ Pkg = $pk; Src = $src } `
            -BtnClick { Start-StoreAction -Id 'pkg-install' -Params @{ Source = $script:StoreSourceIndex[[string]$this.Tag.Src]; Package = [string]$this.Tag.Pkg } })
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
    $upstream = @($Items | Where-Object { $script:StoreSourceIndex.ContainsKey([string]$_.Source) })

    # 与本地精选库合并，按 install.id 去重、精选优先。
    # 用户搜 "7zip" 时：本地精选库毫秒级就能给出 7-Zip，choco 的搜索结果要好几秒；
    # 两边命中同一个包时只留精选那条（它有中文名、兼容性标记，还能点「详情」）。
    $seen = @{}
    $merged = New-Object System.Collections.ArrayList
    foreach ($h in @($script:StoreLocalHits)) {
        $k = ([string]$h.Id).ToLower()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$merged.Add($h) }
    }
    foreach ($i in $upstream) {
        $k = ([string]$i.Id).ToLower()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$merged.Add($i) }
    }

    $script:StoreLastItems = @($merged)
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
    # 下拉列「全部源」+ 每个可搜索的源（目前 Chocolatey / npm）。
    # 只有一个源时不加「全部源」，避免同一份结果出现两条入口。
    try {
        $cmbStoreSrc.Items.Clear()
        $script:StoreComboMap = @()
        $searchable = @($script:StoreSources | Where-Object { $_.CanSearch })
        if ($searchable.Count -gt 1) {
            [void]$cmbStoreSrc.Items.Add('全部源')
            $script:StoreComboMap += 'all'
        }
        foreach ($s in $searchable) {
            [void]$cmbStoreSrc.Items.Add([string]$s.Name)
            $script:StoreComboMap += [string]$s.Id
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
        Update-StoreQueueUi
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
                    $mode = $(if ($sid -eq 'all') { 'searchall' } else { 'search' })
                    Append-GuiLog -Line ('[INFO] 包管理器已就绪，继续刚才的搜索: ' + $q)
                    Start-StoreQuery -Mode $mode -Source $sid -Query $q
                }
            }
        }
        'local' {
            $script:StoreLocal = @($items | ForEach-Object { [string]$_.Id })
            if ($script:StoreLastItems.Count -gt 0) { Show-StoreResult -Items $script:StoreLastItems }
            # 已装清单拿到后，接着查可更新（choco outdated 要联网，放后台）
            $choco = @($script:StoreSources | Where-Object { $_.Id -eq 'choco' -and $_.Installed })
            if ($choco.Count -gt 0) { Start-StoreQuery -Mode 'outdated' -Source 'choco' }
        }
        'outdated' {
            $script:StoreOutdated = @{}
            foreach ($i in $items) { $script:StoreOutdated[[string]$i.Id] = $i }
            if ($script:StoreLastItems.Count -gt 0) {
                Show-StoreResult -Items $script:StoreLastItems
            } else {
                Show-StorePage
            }
        }
        'search'    { Show-StoreResult -Items $items }
        'searchall' { Show-StoreResult -Items $items }
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
    # npm 源没有「自动装 Node.js」这条路（代价太大），缺 npm 就如实拒绝。
    if ($Id -in @('pkg-install', 'pkg-uninstall', 'pkg-info', 'store-install', 'store-queue')) {
        $srcId = 'choco'
        if ([int]$Params['Source'] -eq 3) { $srcId = 'npm' }
        if (-not (Resolve-GuiReadyPackageExe -Id $srcId)) {
            if ($srcId -ne 'choco') {
                Append-GuiLog -Line '[ERROR] 本机没有 npm，装不了 npm 源上的包。请先在商店安装 Node.js（nodejs）。'
                return
            }
            $name = [string]$Params['Package']
            if (-not $name -and $Params['AppId']) { $name = [string]$Params['AppId'] }
            if (-not $name -and $Params['AppIds']) { $name = '批量安装队列' }
            if (-not (Confirm-GuiPackageManager -Why ('你刚要操作的软件包是「' + $name + '」，得先有包管理器。'))) {
                Append-GuiLog -Line '[INFO] 你取消了自动安装包管理器，本次操作没有执行。'
                return
            }
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

function Read-StoreQueueState {
    # 读 state\store-queue.json（批量安装结束时由 lib\GuiReady.Store.ps1 写入）
    try {
        $p = Join-Path (Join-Path $toolRoot 'state') 'store-queue.json'
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Update-StoreQueueUi {
    # 刷新「安装选中 (N)」与「重试失败 (N)」两个按钮的状态
    $n = 0
    try { $n = @($script:StoreChecked.Keys).Count } catch { }
    try {
        $btnStoreQueue.Text    = $(if ($n -gt 0) { ('安装选中 ({0})' -f $n) } else { '安装选中' })
        $btnStoreQueue.Enabled = ($n -gt 0 -and -not $script:Proc)
    } catch { }

    $failed = @()
    $st = Read-StoreQueueState
    if ($st -and $st.PSObject.Properties['Failed']) {
        $failed = @($st.Failed | Where-Object { $_ -and $_.Id })
    }
    $script:StoreQueueFailed = $failed
    try {
        $btnStoreRetry.Visible = ($failed.Count -gt 0)
        $btnStoreRetry.Text    = ('重试失败 ({0})' -f $failed.Count)
        $btnStoreRetry.Enabled = ($failed.Count -gt 0 -and -not $script:Proc)
    } catch { }
}

function Start-StoreQueue {
    # 把勾选的行排成队列，交给后台动作顺序安装（单个失败不中断）
    $ids = @($script:StoreChecked.Keys | Sort-Object)
    if ($ids.Count -eq 0) { return }
    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请先等它结束。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    Append-GuiLog -Line ('[INFO] 批量安装 {0} 个应用: {1}' -f $ids.Count, ($ids -join ', '))
    Start-StoreAction -Id 'store-queue' -Params @{ AppIds = ($ids -join ',') }
    # 只有真的起来了才清勾选；被取消（比如拒绝装包管理器）时保留，用户可直接再点一次
    if ($script:Proc) {
        $script:StoreChecked = @{}
        foreach ($r in @($script:StoreRows)) { try { if ($r.Check) { $r.Check.Checked = $false } } catch { } }
        Update-StoreQueueUi
    }
}

function Retry-StoreQueue {
    # 只重跑上次队列里失败的条目
    $ids = @($script:StoreQueueFailed | ForEach-Object { [string]$_.Id } | Where-Object { $_ })
    if ($ids.Count -eq 0) { return }
    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请先等它结束。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    Append-GuiLog -Line ('[INFO] 重试上次失败的应用: ' + ($ids -join ', '))
    Start-StoreAction -Id 'store-queue' -Params @{ AppIds = ($ids -join ',') }
}

function Show-StorePage {
    # 进页面：先用本地精选库立刻铺一屏（毫秒级），再后台检测包管理器（要起子进程，秒级）。
    # 顺序很重要：以前是空列表等检测，现在是**立刻有内容**。
    $script:StoreLocalHits = @()   # 回到"精选浏览"，清掉上次搜索残留的本地命中
    Update-StoreUiFilter
    Add-StoreCatalogRows | Out-Null
    Update-StoreQueueUi
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

function Bind-StoreEvents {
    # 商店页的事件绑定；页面首次显示时由 Build-StorePage 调用
$btnStoreQueue.Add_Click({ Start-StoreQueue })
$btnStoreRetry.Add_Click({ Retry-StoreQueue })
$btnStoreSearch.Add_Click({
    $q = [string]$txtStoreQuery.Box.Text
    if ([string]::IsNullOrWhiteSpace($q)) { Set-Pill -Pill $pillStoreState -Text '先输入关键词' -Kind 'Warn'; return }
    # 本地精选库先出结果（毫秒级），别让用户盯着空列表等 choco 的网络往返（秒级）。
    # 上游结果回来后走 Show-StoreResult：与本地按 install.id 合并去重，精选优先。
    $hits = @(Search-GuiReadyStore -Keyword $q -Limit 40)
    $script:StoreLocalHits = @($hits | ForEach-Object { ConvertTo-StoreRowItem -Entry $_ } | Where-Object { $_ })
    if ($script:StoreLocalHits.Count -gt 0) { Show-StoreResult -Items @() }
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
    $mode = $(if ($sid -eq 'all') { 'searchall' } else { 'search' })
    Append-GuiLog -Line ('[INFO] 商店搜索[{0}]: {1}' -f $(if ($sid -eq 'all') { '全部源' } else { $sid }), $q)
    Start-StoreQuery -Mode $mode -Source $sid -Query $q
})

$txtStoreQuery.Box.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $btnStoreSearch.PerformClick() }
})
}

# ============================ 角色与功能页 ============================
# 「角色与功能管理」：图形化封装 Install-WindowsFeature / Uninstall-WindowsFeature。
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

# 角色页控件按需构建（首次显示本页时执行）：页头、状态行、筛选行、结果区与轮询定时器
function Build-RolePage {
$hdrRole = New-PageHeader -Title '角色与功能' -Subtitle '图形化装 Windows Server 角色与功能（等价于 Install-WindowsFeature）。安装需要管理员；装完是否需要重启会写进下方日志。' -Icon 'role' -Width 900
$pageRole.Controls.Add($hdrRole)
$lblRoleHead = $hdrRole.Tag.Title
$lblRoleDesc = $hdrRole.Tag.Sub
[void](Add-PageAdvancedButton -Header $hdrRole -Title '角色与功能' -Groups @('角色与功能'))

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
$pnlRoleFilter.Size      = New-Object System.Drawing.Size(900, 76)
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

# 第二行：批量操作（行左侧有勾选框，见 Add-RoleRow）
$btnRoleBatchIns          = New-FlatButton -Text '安装选中' -Kind Primary -Width 118 -Height 30
$btnRoleBatchIns.Location = New-Object System.Drawing.Point(4, 44)
$btnRoleBatchIns.Enabled  = $false
$pnlRoleFilter.Controls.Add($btnRoleBatchIns)

$btnRoleBatchRem          = New-FlatButton -Text '移除选中' -Width 118 -Height 30
$btnRoleBatchRem.Location = New-Object System.Drawing.Point(130, 44)
$btnRoleBatchRem.Enabled  = $false
$pnlRoleFilter.Controls.Add($btnRoleBatchRem)

$lblRoleBatchHint          = New-Label -Text '勾选后可批量操作；安装会先按 DependsOn 自动补齐依赖。' -Size 8.5 -Color Hint
$lblRoleBatchHint.Location = New-Object System.Drawing.Point(262, 50)
$pnlRoleFilter.Controls.Add($lblRoleBatchHint)

$hintRole = New-HintBar -Text '提示：Server Core 上装了角色也没有图形管理工具可用（管理工具建议装在管理端的 RSAT 上），所以默认不勾选「包含管理工具」。按需功能（如 App Compatibility FOD）请用「更多 → 补给」。' -Kind 'Blue' -Width 900
$hintRole.Location = New-Object System.Drawing.Point(0, 180)
$pageRole.Controls.Add($hintRole)

$barRole          = New-ProgressBar -Width 420 -Height 6 -Indeterminate
$barRole.Location = New-Object System.Drawing.Point(0, 218)
$barRole.Visible  = $false
$pageRole.Controls.Add($barRole)

$pnlRoleResults              = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlRoleResults.Location     = New-Object System.Drawing.Point(0, 232)
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
$script:RoleChecked  = @{}      # 勾选待批量操作的角色：Name -> Installed（勾选时的安装态）
$script:RoleRestartNeeded = $false   # 最近一次角色动作是否需要重启
$script:RoleRestartItems  = @()      # 需要重启才生效的角色/功能名
$script:RolePills    = @()
$script:RoleTask     = ''      # '' | support | list | watch
$script:RoleProc     = $null
$script:RoleRunDir   = ''
$script:RoleOutFile  = ''
$script:RoleRunner   = Join-Path $guiDir 'Run-GuiReadyRole.ps1'
$script:RoleRowLimit = 120     # 一屏渲染上限，超出的让用户用筛选缩小（符合"宁可少画也不要卡"）

$script:RoleTimer = New-Object System.Windows.Forms.Timer
$script:RoleTimer.Interval = 300

# 写回脚本作用域：布局函数、Show-RolePage/Show-RoleResult 以及本页事件绑定都要用这些控件
$script:hdrRole           = $hdrRole
$script:lblRoleDesc       = $lblRoleDesc
$script:pnlRoleStatus     = $pnlRoleStatus
$script:lblRoleStatusHint = $lblRoleStatusHint
$script:pnlRoleFilter     = $pnlRoleFilter
$script:txtRoleQuery      = $txtRoleQuery
$script:cmbRoleFilter     = $cmbRoleFilter
$script:btnRoleFilter     = $btnRoleFilter
$script:pillRoleCount     = $pillRoleCount
$script:btnRoleBatchIns   = $btnRoleBatchIns
$script:btnRoleBatchRem   = $btnRoleBatchRem
$script:hintRole          = $hintRole
$script:barRole           = $barRole
$script:pnlRoleResults    = $pnlRoleResults
$script:lblRoleEmpty      = $lblRoleEmpty
Bind-RoleEvents
}
$script:PageBuilders['role'] = 'Build-RolePage'

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

    # 勾选框：批量安装 / 移除（状态存 $script:RoleChecked，列表重绘后回填）
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Location  = New-Object System.Drawing.Point(10, 20)
    $chk.Size      = New-Object System.Drawing.Size(18, 18)
    $chk.FlatStyle = 'Flat'
    $chk.BackColor = $Pal.Card
    $chk.ForeColor = $Pal.Text
    $chk.Tag       = @{ Name = [string]$Item.Name; Installed = [bool]$Item.Installed }
    $chk.Checked   = $script:RoleChecked.ContainsKey([string]$Item.Name)
    $chk.Add_Click({
        $n = [string]$this.Tag.Name
        if ($this.Checked) { $script:RoleChecked[$n] = [bool]$this.Tag.Installed } else { $script:RoleChecked.Remove($n) }
        Update-RoleQueueUi
    })
    $row.Controls.Add($chk)

    $lbName = New-Label -Text $title -Size 10 -Style Bold -Width ($rowW - 330)
    $lbName.Location = New-Object System.Drawing.Point(38, 9)
    $row.Controls.Add($lbName)

    $kind = [string]$Item.FeatureType
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = '—' }
    $dep = ''
    if (@($Item.DependsOn).Count -gt 0) { $dep = '   依赖: ' + (@($Item.DependsOn) -join ', ') }
    $meta = ('{0}   ·   {1}{2}' -f [string]$Item.Name, $kind, $dep)
    $lbMeta = New-Label -Text $meta -Size 8.5 -Color Hint -Width ($rowW - 330)
    $lbMeta.Location = New-Object System.Drawing.Point(38, 32)
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
    $script:RoleRows += [pscustomobject]@{ Panel = $row; Name = $lbName; Meta = $lbMeta; Check = $chk; Install = $btnIns; Remove = $btnRem; Pill = $pill }
}

function Update-RoleRowLayout {
    $rowW = Get-RoleRowWidth
    foreach ($r in $script:RoleRows) {
        try {
            $r.Panel.Width = $rowW
            $r.Name.Width  = $rowW - 330
            $r.Meta.Width  = $rowW - 330
            $r.Install.Location = New-Object System.Drawing.Point(($rowW - 184), 14)
            $r.Remove.Location  = New-Object System.Drawing.Point(($rowW - 96), 14)
            if ($r.Pill) { $r.Pill.Location = New-Object System.Drawing.Point(($rowW - 194 - $r.Pill.Width), 18) }
            Set-Rounded -Control $r.Panel -Radius 10
        } catch { }
    }
}

function Update-RoleQueueUi {
    # 「安装选中 (N)」「移除选中 (N)」的状态：移除只统计勾选时已安装的项
    $all = 0
    $inst = 0
    try {
        $all  = @($script:RoleChecked.Keys).Count
        $inst = @($script:RoleChecked.Keys | Where-Object { $script:RoleChecked[$_] }).Count
    } catch { }
    try {
        $btnRoleBatchIns.Text    = $(if ($all -gt 0) { ('安装选中 ({0})' -f $all) } else { '安装选中' })
        $btnRoleBatchIns.Enabled = ($all -gt 0 -and -not $script:Proc)
        $btnRoleBatchRem.Text    = $(if ($inst -gt 0) { ('移除选中 ({0})' -f $inst) } else { '移除选中' })
        $btnRoleBatchRem.Enabled = ($inst -gt 0 -and -not $script:Proc)
    } catch { }
}

function Start-RoleQueue {
    # 批量安装 / 移除勾选的角色。依赖展开与「失败不中断」都在 lib\GuiReady.Role.ps1 里。
    param([string]$Mode = 'install')

    $names = @()
    if ($Mode -eq 'remove') {
        $names = @($script:RoleChecked.Keys | Where-Object { $script:RoleChecked[$_] } | Sort-Object)
    } else {
        $names = @($script:RoleChecked.Keys | Sort-Object)
    }
    if ($names.Count -eq 0) { return }
    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请先等它结束。', '提示', 'OK', 'Information') | Out-Null
        return
    }

    $verb = $(if ($Mode -eq 'remove') { '移除' } else { '安装' })
    Append-GuiLog -Line ('[INFO] 批量{0} {1} 项角色/功能: {2}' -f $verb, $names.Count, ($names -join ', '))
    $id = $(if ($Mode -eq 'remove') { 'role-batch-remove' } else { 'role-batch-install' })
    Start-RoleAction -Id $id -Params @{ Names = ($names -join ',') }

    if ($script:Proc) {
        $script:RoleChecked = @{}
        foreach ($r in @($script:RoleRows)) { try { if ($r.Check) { $r.Check.Checked = $false } } catch { } }
        Update-RoleQueueUi
    }
}

function Read-RoleProgress {
    # 读 state\role-progress.json（动作子进程每装/卸一项就写一次）
    try {
        $p = Join-Path (Join-Path $toolRoot 'state') 'role-progress.json'
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Confirm-RoleReboot {
    # 「需要重启」时的唯一入口：先把要生效的项说清楚，再走延时重启（可取消）
    if ($script:AuditMode) { Append-GuiLog -Line '[INFO] 审计模式：跳过重启确认'; return }
    $items = @($script:RoleRestartItems)
    $who = $(if ($items.Count -gt 0) { ($items -join '、') } else { '最近一次角色变更' })
    $msg = "以下变更需要重启才会生效：`r`n`r`n  $who`r`n`r`n现在重启服务器吗？所有会话会断开。`r`n`r`n真跑时会延时 20 秒，期间可在命令行执行 shutdown /a 取消。"
    try {
        $r = [System.Windows.Forms.MessageBox]::Show($form, $msg, '重启服务器', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        Append-GuiLog -Line '[WARN] 已计划重启：20 秒后执行（取消：shutdown /a）'
        Start-RoleAction -Id 'reboot' -Params @{ DelaySec = 20 }
    } catch { }
}

function Show-RoleResult {
    $items = @(Get-RoleFilteredItems)
    Clear-RoleRows
    Update-RoleQueueUi

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
    $x += 84

    # 需要重启时出现在这一行：把「待生效的项」说清楚，再走延时重启（可取消）
    if ($script:RoleRestartNeeded) {
        $n = @($script:RoleRestartItems).Count
        $btnRb = New-FlatButton -Text $(if ($n -gt 0) { ('重启服务器（{0} 项待生效）' -f $n) } else { '重启服务器' }) -Kind Primary -Width 200 -Height 30
        $btnRb.Location = New-Object System.Drawing.Point($x, 2)
        $btnRb.Add_Click({ Confirm-RoleReboot })
        $pnlRoleStatus.Controls.Add($btnRb)
    }
}

function Update-RoleTick {
    if ($script:RoleTask -eq 'watch') {
        $running = $false
        try { if ($script:Proc) { $script:Proc.Refresh(); $running = -not $script:Proc.HasExited } } catch { }
        if ($running) {
            # 进度：动作子进程每装/卸一项写一次 state\role-progress.json
            $pr = Read-RoleProgress
            if ($pr -and [int]$pr.Total -gt 0 -and [string]$pr.Stage -ne 'done') {
                $cur = [int]$pr.Current
                $tot = [int]$pr.Total
                $pct = [int][Math]::Floor(100.0 * $cur / $tot)
                $verb = $(if ([string]$pr.Stage -eq 'remove') { '移除' } else { '安装' })
                $txt = ('{0} {1}/{2}（{3}%）' -f $verb, $cur, $tot, $pct)
                if ($pr.CurrentName) { $txt += '：' + [string]$pr.CurrentName }
                Set-Pill -Pill $pillRoleCount -Text $txt -Kind 'Info'
            }
            try { $barRole.Invalidate() } catch { }
            return
        }
        Stop-RoleTask
        # 收尾：把「是否需要重启」连同具体项一起记下来，状态行会出现重启按钮
        $pr = Read-RoleProgress
        if ($pr) {
            $script:RoleRestartNeeded = [bool]$pr.RestartNeeded
            $script:RoleRestartItems  = @($pr.RestartItems | Where-Object { $_ })
        }
        Update-RoleQueueUi
        Update-RoleStatusRow
        Append-GuiLog -Line '[INFO] 角色动作已结束，正在刷新列表（需要重启的项会写在日志里）。'
        # 安装/卸载后缓存已失效，自动重读一次，页面不会停在旧状态
        Start-RoleQuery -Mode 'list'
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
    Apply-RoleResult -Obj $obj
    Update-RoleQueueUi
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

function Read-RoleCache {
    # 读 state\role-cache.json（Run-GuiReadyRole.ps1 每次成功查询后写入）。
    # 目的：进入角色页先秒显上次结果，不用每次都等子进程（启动 + 查询实测约 2~4 秒）。
    try {
        $p = Join-Path (Join-Path $toolRoot 'state') 'role-cache.json'
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Apply-RoleResult {
    # 把一份查询结果（子进程返回 / 磁盘缓存）应用到界面
    param($Obj)
    if (-not $Obj) { return }
    $script:RoleSupport = $Obj.Support
    $script:RoleItems   = @($Obj.Items)
    Update-RoleStatusRow
    Show-RoleResult
}

function Restore-RoleRestartState {
    # GUI 关掉再打开后，「需要重启」仍然要提示 —— 但不能把重启前的旧记录当成新的：
    # 只认「本次开机之后」写下的进度文件（用 TickCount64 推算开机时间）。
    try {
        if ($script:RoleRestartNeeded) { return }
        $pr = Read-RoleProgress
        if (-not $pr -or [string]$pr.Stage -ne 'done' -or -not [bool]$pr.RestartNeeded) { return }
        $ts = [datetime]::MinValue
        try { $ts = [datetime]::Parse([string]$pr.Updated) } catch { return }
        $boot = (Get-Date).AddMilliseconds(-[double][Environment]::TickCount64)
        if ($ts -lt $boot) { return }
        $script:RoleRestartNeeded = $true
        $script:RoleRestartItems = @($pr.RestartItems | Where-Object { $_ })
    } catch { }
}

function Show-RolePage {
    if ($SkipPageHooks) { return }
    Restore-RoleRestartState
    if (-not $script:RoleSupport -and -not $script:RoleTask) {
        # 先用磁盘缓存秒显，再后台刷新 —— 用户反馈"读取角色列表好慢"。
        $cache = Read-RoleCache
        if ($cache -and @($cache.Items).Count -gt 0) {
            Apply-RoleResult -Obj $cache
            Append-GuiLog -Line ('[INFO] 角色列表先用上次结果（{0} 项），正在后台刷新…' -f @($cache.Items).Count)
        }
        Start-RoleQuery -Mode 'list'
    } else {
        Update-RoleStatusRow
        Show-RoleResult
    }
}

function Bind-RoleEvents {
    # 角色页的事件绑定；页面首次显示时由 Build-RolePage 调用
    $btnRoleBatchIns.Add_Click({ Start-RoleQueue -Mode 'install' })
    $btnRoleBatchRem.Add_Click({ Start-RoleQueue -Mode 'remove' })
    $script:RoleTimer.Add_Tick({ Update-RoleTick })

$btnRoleFilter.Add_Click({ Show-RoleResult })
$txtRoleQuery.Box.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Show-RoleResult }
})
$cmbRoleFilter.Add_SelectedIndexChanged({ Show-RoleResult })
}

# ============================ 仪表盘页 ============================
# 「系统监控与诊断」。数据全在子进程里采集：
# CPU 取样要 1 秒、系统事件日志查询要几百毫秒以上，不能在界面线程上等。

$pageMon                = New-Object System.Windows.Forms.Panel
$pageMon.Dock           = 'Fill'
$pageMon.BackColor      = $Pal.Bg
$script:Pages['monitor'] = $pageMon
$pnlContent.Controls.Add($pageMon)

# 仪表盘页控件按需构建（首次显示本页时执行）：页头、指标卡、趋势图、控制行与结果区
function Build-MonitorPage {
# HMOL PageHeader：38px 图标块 + 13.5pt 粗标题 + 9pt 副标题（右侧留给本页操作按钮）
$hdrMon = New-PageHeader -Title '仪表盘' -Subtitle '本机资源、关键服务、最近的系统错误、占内存最多的进程。全只读；服务按钮走下面的动作机制（子进程执行，日志在下方）。' -Icon 'monitor' -Width 900
$pageMon.Controls.Add($hdrMon)
$lblMonHead = $hdrMon.Tag.Title
$lblMonDesc = $hdrMon.Tag.Sub
[void](Add-PageAdvancedButton -Header $hdrMon -Title '仪表盘' -Groups @('监控与诊断', '探测与诊断'))

$pnlMonCards             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlMonCards.Location    = New-Object System.Drawing.Point(0, 56)
$pnlMonCards.Size        = New-Object System.Drawing.Size(896, 116)
$pnlMonCards.Anchor      = 'Top,Left,Right'
$pnlMonCards.WrapContents = $true
$pnlMonCards.BackColor   = $Pal.Bg
$pageMon.Controls.Add($pnlMonCards)

$script:MonCards = @{}
foreach ($spec in @(
        @{ K = 'cpu';  T = 'CPU 占用'; A = '#409EFF' },
        @{ K = 'mem';  T = '内存占用'; A = '#22D3EE' },
        @{ K = 'disk'; T = '系统盘';   A = '#FBBF24' },
        @{ K = 'svc';  T = '关键服务'; A = '#34D399' })) {
    $script:MonCards[$spec.K] = New-StatusCard -Title $spec.T -Width 208 -Big -AccentHex $spec.A -Parent $pnlMonCards
}

# ---- 趋势曲线（CPU / 内存 / 系统盘）----
# 采样走独立的轻量查询（Run-GuiReadyMonitor.ps1 -Mode metrics，约 1 秒），每 5 秒一次；
# 历史只留在内存里（最多 120 点 ≈ 10 分钟），不落盘 —— 服务器上不堆无用的时序文件。
$script:MonHistory    = New-Object System.Collections.ArrayList
$script:MonHistoryMax = 120
$script:MonAlarm      = @{ cpu = $false; mem = $false; disk = $false }   # 告警边沿检测（只在跨阈值时写日志）
$script:MonTrendFont      = New-Font -Size 8.5 -Style Bold
$script:MonTrendFontSmall = New-Font -Size 8

$pnlMonTrend           = New-Object System.Windows.Forms.Panel
$pnlMonTrend.Location  = New-Object System.Drawing.Point(0, 140)
$pnlMonTrend.Size      = New-Object System.Drawing.Size(896, 104)
$pnlMonTrend.Anchor    = 'Top,Left,Right'
$pnlMonTrend.BackColor = $Pal.Bg
Enable-UiDoubleBuffer -Control $pnlMonTrend
$pageMon.Controls.Add($pnlMonTrend)

$pnlMonBar           = New-Object System.Windows.Forms.Panel
$pnlMonBar.Location  = New-Object System.Drawing.Point(0, 252)
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

# TUI 监控：优先用本机已有的 pstop / htop / btm，没有就启动内置版（零依赖）。
# 在后台起一个真实控制台窗口 —— TUI 需要真的控制台，不能画在 GUI 里。
$btnMonTui          = New-FlatButton -Text 'TUI 监控' -Width 96 -Height 30
$btnMonTui.Location = New-Object System.Drawing.Point(260, 2)
$pnlMonBar.Controls.Add($btnMonTui)

# 告警阈值：CPU / 内存 / 磁盘的百分比，存 state\monitor-thresholds.json
$btnMonThresh          = New-FlatButton -Text '告警阈值' -Width 96 -Height 30
$btnMonThresh.Location = New-Object System.Drawing.Point(366, 2)
$pnlMonBar.Controls.Add($btnMonThresh)

$hintMon = New-HintBar -Text '提示：服务名要填服务名而不是显示名（例如 WinRM / LanmanServer / TermService）。停关键服务可能断开你的远程会话，动作里会先警告。「TUI 监控」优先打开已装的 pstop / htop / btm，没有就用内置的 scm-top（零依赖，按 q 退出）。' -Kind 'Blue' -Width 900
$hintMon.Location = New-Object System.Drawing.Point(0, 288)
$pageMon.Controls.Add($hintMon)

$barMon          = New-ProgressBar -Width 420 -Height 6 -Indeterminate
$barMon.Location = New-Object System.Drawing.Point(0, 326)
$barMon.Visible  = $false
$pageMon.Controls.Add($barMon)

$pnlMonRows              = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlMonRows.Location     = New-Object System.Drawing.Point(0, 340)
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

# 写回脚本作用域：布局函数、Render-Monitor/Add-MonSection 以及本页事件绑定都要用这些控件
$script:hdrMon       = $hdrMon
$script:lblMonDesc   = $lblMonDesc
$script:pnlMonCards  = $pnlMonCards
$script:pnlMonTrend  = $pnlMonTrend
$script:pnlMonBar    = $pnlMonBar
$script:btnMonRefresh = $btnMonRefresh
$script:pillMonSum   = $pillMonSum
$script:btnMonTui    = $btnMonTui
$script:btnMonThresh = $btnMonThresh
$script:hintMon      = $hintMon
$script:barMon       = $barMon
$script:pnlMonRows   = $pnlMonRows
$script:lblMonEmpty  = $lblMonEmpty
Bind-MonitorEvents
}
$script:PageBuilders['monitor'] = 'Build-MonitorPage'

function Bind-MonitorEvents {
    # 仪表盘页的事件绑定；页面首次显示时由 Build-MonitorPage 调用
    $pnlMonTrend.Add_Paint({ param($s, $e) Render-MonTrend -Graphics $e.Graphics -Width $s.Width -Height $s.Height })
    $btnMonTui.Add_Click({ Start-MonitorTui })
    $btnMonThresh.Add_Click({ Show-MonitorThresholdDialog })
    $btnMonRefresh.Add_Click({ Start-GuiQueryHost -Query $script:QMon -Task 'snapshot' -BusyText '采集快照…' | Out-Null })
}

function Draw-MonTrendCell {
    # 一格：标题（左上）+ 最新值（右上）+ 0~100% 的曲线（含浅色填充）
    param($Graphics, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title, $Values, $Color)

    [System.Windows.Forms.TextRenderer]::DrawText($Graphics, $Title, $script:MonTrendFont,
        (New-Object System.Drawing.Point($X, $Y)), $Pal.SubText)

    $last = $null
    foreach ($v in @($Values)) { if ($null -ne $v) { $last = [double]$v } }
    $valText = '—'
    if ($null -ne $last) { $valText = ('{0:0.0} %' -f $last) }
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($valText, $script:MonTrendFontSmall)
    [System.Windows.Forms.TextRenderer]::DrawText($Graphics, $valText, $script:MonTrendFontSmall,
        (New-Object System.Drawing.Point(($X + $W - $sz.Width), $Y)), $Pal.Text)

    $py = $Y + 20
    $ph = $H - 24
    if ($ph -lt 18) { return }

    # 25 / 50 / 75 三条参考线：不画文字，避免小图里噪音太大
    $penGrid = New-Object System.Drawing.Pen($Pal.Border, 1)
    try {
        foreach ($pct in @(25, 50, 75)) {
            $gy = $py + $ph - [int]($ph * $pct / 100)
            $Graphics.DrawLine($penGrid, $X, $gy, ($X + $W), $gy)
        }
    } finally { $penGrid.Dispose() }

    $vals = @()
    foreach ($v in @($Values)) {
        if ($null -eq $v) { continue }
        $f = [double]$v
        if ($f -lt 0) { $f = 0 }
        if ($f -gt 100) { $f = 100 }
        $vals += $f
    }
    if ($vals.Count -lt 2) {
        [System.Windows.Forms.TextRenderer]::DrawText($Graphics, '正在积累样本…', $script:MonTrendFontSmall,
            (New-Object System.Drawing.Point($X, ($py + 4))), $Pal.Hint)
        return
    }

    # 最新点贴右边：X 轴按固定容量（120 点）铺，样本少时曲线从右侧长出来
    $step = [double]$W / [Math]::Max(1, ($script:MonHistoryMax - 1))
    $x0 = $X + [double]($script:MonHistoryMax - $vals.Count) * $step
    $pts = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $vals.Count; $i++) {
        $px = $x0 + $i * $step
        $pyy = $py + $ph - ($vals[$i] / 100.0 * $ph)
        [void]$pts.Add([System.Drawing.PointF]::new([float]$px, [float]$pyy))
    }
    $arr = [System.Drawing.PointF[]]$pts.ToArray()

    $penLine = New-Object System.Drawing.Pen($Color, 1.6)
    $brushFill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(38, $Color))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    try {
        # 面积填充：曲线 + 右侧垂线 + 底边 + 左侧垂线，闭合成多边形
        $bottomY = [float]($py + $ph)
        $poly = New-Object System.Collections.ArrayList
        foreach ($p in $arr) { [void]$poly.Add($p) }
        [void]$poly.Add([System.Drawing.PointF]::new([float]$arr[$arr.Length - 1].X, $bottomY))
        [void]$poly.Add([System.Drawing.PointF]::new([float]$arr[0].X, $bottomY))
        $path.AddPolygon([System.Drawing.PointF[]]$poly.ToArray())
        $Graphics.FillPath($brushFill, $path)
    } catch { }
    try { $Graphics.DrawLines($penLine, $arr) } catch { }
    try { $path.Dispose(); $penLine.Dispose(); $brushFill.Dispose() } catch { }
}

function Render-MonTrend {
    param($Graphics, [int]$Width, [int]$Height)
    if (-not $Graphics -or $Width -lt 40 -or $Height -lt 40) { return }
    Invoke-UiPaintFrame -Graphics $Graphics -Width $Width -Height $Height -Radius 10 -Fill $Pal.Card -Border $Pal.Border

    $hist = @($script:MonHistory)
    if ($hist.Count -eq 0) {
        [System.Windows.Forms.TextRenderer]::DrawText($Graphics, '趋势还在积累（每 5 秒采样一次）…', $script:MonTrendFontSmall,
            (New-Object System.Drawing.Point(14, 14)), $Pal.Hint)
        return
    }

    $cpuVals = @(); $memVals = @(); $diskVals = @()
    foreach ($s in $hist) {
        $cpuVals  += $(if ($null -ne $s.Cpu)  { [double]$s.Cpu }  else { $null })
        $memVals  += $(if ($null -ne $s.Mem)  { [double]$s.Mem }  else { $null })
        $diskVals += $(if ($null -ne $s.Disk) { [double]$s.Disk } else { $null })
    }

    $pad = 12
    $gap = 10
    $cellW = [int](($Width - 2 * $pad - 2 * $gap) / 3)
    $cellH = $Height - 14
    Draw-MonTrendCell -Graphics $Graphics -X $pad -Y 7 -W $cellW -H $cellH -Title 'CPU %'  -Values $cpuVals  -Color $Pal.Accent3
    Draw-MonTrendCell -Graphics $Graphics -X ($pad + $cellW + $gap) -Y 7 -W $cellW -H $cellH -Title '内存 %' -Values $memVals  -Color $Pal.Ok
    Draw-MonTrendCell -Graphics $Graphics -X ($pad + 2 * ($cellW + $gap)) -Y 7 -W $cellW -H $cellH -Title '系统盘 %' -Values $diskVals -Color $Pal.Warn
}

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

    # 快照也记进趋势：页面刚打开时曲线不至于空白（2 秒内的 metrics 点会自动去重）
    $seedCpu = $null; $seedMem = $null; $seedDisk = $null
    try { if ($s.Cpu -and $null -ne $s.Cpu.Percent) { $seedCpu = [double]$s.Cpu.Percent } } catch { }
    try { if ($s.Memory) { $seedMem = [double]$s.Memory.UsedPercent } } catch { }
    try { $ds = @($s.Disks); if ($ds.Count -gt 0) { $seedDisk = [double]$ds[0].UsedPercent } } catch { }
    Add-MonTrendPoint -Cpu $seedCpu -Mem $seedMem -Disk $seedDisk

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

    # 越限时把汇总胶囊换成告警（比"采集于"更重要）
    $alarm = Update-MonitorAlarm -Cpu $seedCpu -Mem $seedMem -Disk $seedDisk
    if ($alarm) { Set-Pill -Pill $pillMonSum -Text ('告警：' + $alarm) -Kind 'Danger' }

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

# ---- 趋势采样 ----
# 独立的轻量查询（Mode=metrics），每 5 秒一次；只在仪表盘可见且窗口未最小化时跑。
$script:QMonTrend = New-GuiQueryHost -Name 'monitor-trend' -Runner (Join-Path $guiDir 'Run-GuiReadyMonitor.ps1') -TimeoutSec 30 `
    -OnResult { param($obj) if ($obj -and $obj.Snap) { Add-MonTrendPoint -Cpu $obj.Snap.Cpu -Mem $obj.Snap.MemPct -Disk $obj.Snap.DiskPct } }

function Get-MonitorThresholds {
    # 告警阈值（百分比）。默认 90/90/90，存 state\monitor-thresholds.json。
    $t = @{ Cpu = 90; Mem = 90; Disk = 90 }
    try {
        $p = Join-Path (Join-Path $toolRoot 'state') 'monitor-thresholds.json'
        if (Test-Path -LiteralPath $p) {
            $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $o = $raw | ConvertFrom-Json
                foreach ($k in @('Cpu', 'Mem', 'Disk')) {
                    $v = 0
                    try { $v = [int]$o.$k } catch { }
                    if ($v -ge 1 -and $v -le 100) { $t[$k] = $v }
                }
            }
        }
    } catch { }
    return $t
}

function Set-MonitorThresholds {
    param([int]$Cpu = 90, [int]$Mem = 90, [int]$Disk = 90)
    try {
        $p = Join-Path (Join-Path $toolRoot 'state') 'monitor-thresholds.json'
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $o = [ordered]@{ Cpu = $Cpu; Mem = $Mem; Disk = $Disk }
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $o -Compress),
            (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Update-MonitorAlarm {
    # 用最新样本判断是否越限，并做「边沿检测」：
    # 只在「从正常跨到越限」和「从越限回落到正常」时各写一行日志，避免每 5 秒刷屏。
    # 返回越限描述（多段用；分隔），没有越限返回 $null。
    param($Cpu, $Mem, $Disk)
    $th = Get-MonitorThresholds
    $specs = @(
        @{ K = 'cpu';  T = 'CPU';  V = $Cpu;  L = [double]$th.Cpu },
        @{ K = 'mem';  T = '内存'; V = $Mem;  L = [double]$th.Mem },
        @{ K = 'disk'; T = '磁盘'; V = $Disk; L = [double]$th.Disk }
    )
    $hits = @()
    foreach ($s in $specs) {
        if ($null -eq $s.V) { continue }
        $on = ([double]$s.V -ge $s.L)
        if ($on) { $hits += ('{0} {1:0.0}% ≥ {2}%' -f $s.T, [double]$s.V, $s.L) }
        if ($on -and -not $script:MonAlarm[$s.K]) {
            Append-GuiLog -Line ('[WARN] 告警：{0} 使用率 {1:0.0}% 已达到阈值 {2}%（仪表盘「告警阈值」可调）。' -f $s.T, [double]$s.V, $s.L)
        } elseif (-not $on -and $script:MonAlarm[$s.K]) {
            Append-GuiLog -Line ('[INFO] 告警解除：{0} 回落到 {1:0.0}%（阈值 {2}%）。' -f $s.T, [double]$s.V, $s.L)
        }
        $script:MonAlarm[$s.K] = $on
    }
    if ($hits.Count -gt 0) { return ($hits -join '；') }
    return $null
}

function Show-MonitorThresholdDialog {
    if ($script:AuditMode) { Append-GuiLog -Line '[INFO] 审计模式：跳过告警阈值对话框'; return }
    $th = Get-MonitorThresholds
    $dlg = New-Object System.Windows.Forms.Form
    try {
        $dlg.Text = '告警阈值'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        $dlg.StartPosition = 'CenterParent'
        $dlg.ClientSize = New-Object System.Drawing.Size(340, 200)
        $dlg.BackColor = $Pal.Bg
        $dlg.ForeColor = $Pal.Text
        $dlg.Font = New-Font -Size 9.5

        $specs = @(
            @{ K = 'Cpu';  T = 'CPU 使用率（%）';  V = $th.Cpu;  Y = 16 },
            @{ K = 'Mem';  T = '内存使用率（%）'; V = $th.Mem;  Y = 52 },
            @{ K = 'Disk'; T = '磁盘使用率（%）'; V = $th.Disk; Y = 88 }
        )
        $spins = @{}
        foreach ($s in $specs) {
            $l = New-Label -Text $s.T -Size 9.5
            $l.Location = New-Object System.Drawing.Point(18, ($s.Y + 4))
            $dlg.Controls.Add($l)
            $sp = New-Object System.Windows.Forms.NumericUpDown
            $sp.Minimum = 1
            $sp.Maximum = 100
            $sp.Value = [decimal][int]$s.V
            $sp.Location = New-Object System.Drawing.Point(196, $s.Y)
            $sp.Size = New-Object System.Drawing.Size(110, 26)
            $sp.BackColor = $Pal.Sunken
            $sp.ForeColor = $Pal.Text
            $dlg.Controls.Add($sp)
            $spins[$s.K] = $sp
        }

        $btnOk = New-FlatButton -Text '保存' -Kind Primary -Width 88 -Height 30
        $btnOk.Location = New-Object System.Drawing.Point(112, 140)
        $btnOk.Add_Click({ $f = $this.FindForm(); if ($f) { $f.DialogResult = [System.Windows.Forms.DialogResult]::OK } })
        $dlg.Controls.Add($btnOk)

        $btnCancel = New-FlatButton -Text '取消' -Width 88 -Height 30
        $btnCancel.Location = New-Object System.Drawing.Point(212, 140)
        $btnCancel.Add_Click({ $f = $this.FindForm(); if ($f) { $f.DialogResult = [System.Windows.Forms.DialogResult]::Cancel } })
        $dlg.Controls.Add($btnCancel)

        $r = $dlg.ShowDialog($form)
        if ($r -eq [System.Windows.Forms.DialogResult]::OK) {
            $ok = Set-MonitorThresholds -Cpu ([int]$spins['Cpu'].Value) -Mem ([int]$spins['Mem'].Value) -Disk ([int]$spins['Disk'].Value)
            if ($ok) {
                Append-GuiLog -Line ('[INFO] 告警阈值已更新：CPU {0}% / 内存 {1}% / 磁盘 {2}%' -f `
                    [int]$spins['Cpu'].Value, [int]$spins['Mem'].Value, [int]$spins['Disk'].Value)
                # 立刻重采一次：胶囊与告警状态都会按新阈值重算
                Start-GuiQueryHost -Query $script:QMon -Task 'snapshot' -BusyText '重新采集…' | Out-Null
            } else {
                Append-GuiLog -Line '[WARN] 告警阈值保存失败（看日志目录权限）。'
            }
        }
    } finally {
        try { $dlg.Dispose() } catch { }
    }
}

function Add-MonTrendPoint {
    # 往内存里的趋势环里放一个点。同一时刻的快照与 metrics 可能只差几百毫秒，
    # 2 秒内不再重复记（否则曲线会出现两条几乎重合的竖线）。
    param($Cpu, $Mem, $Disk)
    try {
        # 先按最新样本判一次告警（即使因去重没记曲线点，告警状态也要更新）
        $alarm = Update-MonitorAlarm -Cpu $Cpu -Mem $Mem -Disk $Disk
        if (-not $script:QMon.Task -and -not $script:QMonTrend.Task) {
            if ($alarm) {
                try { Set-Pill -Pill $pillMonSum -Text ('告警：' + $alarm) -Kind 'Danger' } catch { }
            } elseif ($pillMonSum.Tag -and ([string]$pillMonSum.Tag.Text) -like '告警：*') {
                # 告警已解除：别让红色胶囊一直挂着（用户不点刷新也能看到恢复）
                try { Set-Pill -Pill $pillMonSum -Text ('采样于 ' + (Get-Date -Format 'HH:mm:ss')) -Kind 'Neutral' } catch { }
            }
        }
        if ($script:MonHistory.Count -gt 0) {
            $lastP = $script:MonHistory[$script:MonHistory.Count - 1]
            if (((Get-Date) - $lastP.T).TotalSeconds -lt 2) { return }
        }
        [void]$script:MonHistory.Add([pscustomobject]@{
            T    = (Get-Date)
            Cpu  = $(if ($null -ne $Cpu)  { [double]$Cpu }  else { $null })
            Mem  = $(if ($null -ne $Mem)  { [double]$Mem }  else { $null })
            Disk = $(if ($null -ne $Disk) { [double]$Disk } else { $null })
        })
        while ($script:MonHistory.Count -gt $script:MonHistoryMax) { $script:MonHistory.RemoveAt(0) }
        try { $pnlMonTrend.Invalidate() } catch { }
    } catch { }
}

$script:MonTrendTimer = New-Object System.Windows.Forms.Timer
$script:MonTrendTimer.Interval = 5000
$script:MonTrendTimer.Add_Tick({
    try {
        if (-not $pageMon.Visible) { return }
        if ($form.WindowState -eq 'Minimized') { return }
        if ($script:QMonTrend.Task) { return }   # 上一次还没回来就跳过，避免日志刷屏
        Start-GuiQueryHost -Query $script:QMonTrend -Task 'metrics' -BusyText '' | Out-Null
    } catch { }
})

function Resolve-MonitorTui {
    # 优先已装的外部 TUI；choco 的 shim 路径兜底（装完不用重启工具也能找到）
    foreach ($exe in @('pstop.exe', 'htop.exe', 'btm.exe', 'ntop.exe')) {
        $c = Get-Command $exe -ErrorAction SilentlyContinue
        if ($c) { return [string]$c.Source }
    }
    $dirs = @()
    if ($env:ProgramData) { $dirs += (Join-Path $env:ProgramData 'chocolatey\bin') }
    $dirs += 'C:\ProgramData\chocolatey\bin'
    foreach ($d in $dirs) {
        foreach ($exe in @('pstop.exe', 'htop.exe', 'btm.exe', 'ntop.exe')) {
            $p = Join-Path $d $exe
            try { if (Test-Path -LiteralPath $p) { return $p } } catch { }
        }
    }
    return ''
}

function Start-MonitorTui {
    # TUI 必须跑在真实控制台里：用 Start-Process 起一个新窗口，不占用 GUI 进程。
    # 优先用本机已装的 pstop / htop / btm；都没有就启动内置版（零依赖，离线可用）。
    if ($script:AuditMode) { Append-GuiLog -Line '[INFO] 审计模式：跳过打开 TUI 监控'; return }
    $exe = Resolve-MonitorTui
    if ($exe) {
        Append-GuiLog -Line ('[INFO] 打开 TUI 监控: ' + $exe)
        try {
            Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) | Out-Null
        } catch {
            Append-GuiLog -Line ('[ERROR] 打开 TUI 监控失败: ' + $_.Exception.Message)
        }
        return
    }

    # 内置版：只依赖系统自带的 Get-Counter / CIM。
    # 外部的 pstop / bottom 都要从 GitHub 下载，受限网络里会因 TLS/代理失败（实测踩到）。
    $builtin = Join-Path $guiDir 'GuiReady.TuiMonitor.ps1'
    if (-not (Test-Path -LiteralPath $builtin)) {
        Append-GuiLog -Line '[ERROR] 找不到内置 TUI 监控脚本: ' + $builtin
        return
    }
    Append-GuiLog -Line '[INFO] 未找到 pstop / htop / btm，打开内置 TUI 监控（scm-top，按 q 退出）'
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $builtin + '"')) | Out-Null
    } catch {
        Append-GuiLog -Line ('[ERROR] 打开内置 TUI 监控失败: ' + $_.Exception.Message)
    }
}

function Show-MonPage {
    if ($SkipPageHooks) { return }
    if (-not $script:MonLoaded) {
        $script:MonLoaded = $true
        Start-GuiQueryHost -Query $script:QMon -Task 'snapshot' -BusyText '采集快照…' | Out-Null
    }
    try { $script:MonTrendTimer.Start() } catch { }
}
$script:MonLoaded = $false

# ============================ 安全页 ============================
# 「安全与合规中心」。只做能在本机直接验证的项，修也只修安全可逆的项。

$pageSec                = New-Object System.Windows.Forms.Panel
$pageSec.Dock           = 'Fill'
$pageSec.BackColor      = $Pal.Bg
$script:Pages['security'] = $pageSec
$pnlContent.Controls.Add($pageSec)

# 安全页控件按需构建（首次显示本页时执行）：页头、状态/筛选行、结果区与进度条
function Build-SecPage {
$hdrSec = New-PageHeader -Title '安全与合规' -Subtitle '本地可验证的安全基线（10 项，每项都带原始证据）。修复只覆盖安全且可逆的项；改 UAC、删管理员这类可能把人锁在门外的操作只给建议。' -Icon 'security' -Width 900
$pageSec.Controls.Add($hdrSec)
$lblSecHead = $hdrSec.Tag.Title
$lblSecDesc = $hdrSec.Tag.Sub
[void](Add-PageAdvancedButton -Header $hdrSec -Title '安全基线' -Groups @('安全与合规'))

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

# 写回脚本作用域：布局函数、Render-Security 以及本页事件绑定都要用这些控件
$script:hdrSec       = $hdrSec
$script:lblSecDesc   = $lblSecDesc
$script:pnlSecBar    = $pnlSecBar
$script:lblSecHint   = $lblSecHint
$script:pnlSecFilter = $pnlSecFilter
$script:cmbSecFilter = $cmbSecFilter
$script:pillSecSum   = $pillSecSum
$script:hintSec      = $hintSec
$script:barSec       = $barSec
$script:pnlSecRows   = $pnlSecRows
$script:lblSecEmpty  = $lblSecEmpty
Bind-SecEvents
}
$script:PageBuilders['security'] = 'Build-SecPage'

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

function Bind-SecEvents {
    # 安全页的事件绑定；页面首次显示时由 Build-SecPage 调用
$cmbSecFilter.Add_SelectedIndexChanged({
    if ($script:SecItems.Count -gt 0) { Render-Security -Obj ([pscustomobject]@{ Items = $script:SecItems; Summary = $script:SecSummary }) }
})
}

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
# 「美化与个性化」。这里不新增能力 —— 终端美化的实现在
# lib\GuiReady.Console.ps1（Nerd Font + Oh My Posh + Fastfetch，含一键还原），
# 这一页只是把它图形化：状态一眼可见、主题能选、按钮能点。
#
# 状态是同步读的（只看注册表与本地文件，不联网、不起子进程），所以不需要查询宿主。

$pageBeauty              = New-Object System.Windows.Forms.Panel
$pageBeauty.Dock         = 'Fill'
$pageBeauty.BackColor    = $Pal.Bg
$script:Pages['beauty']  = $pageBeauty
$pnlContent.Controls.Add($pageBeauty)

# 美化页控件按需构建（首次显示本页时执行）：页头、状态行、主题行、动作区与结果区
function Build-BeautyPage {
# HMOL PageHeader：38px 图标块 + 13.5pt 粗标题 + 9pt 副标题（右侧留给本页操作按钮）
$hdrBeauty = New-PageHeader -Title '美化与个性化' -Subtitle '把 Server Core 的 conhost 打扮好看：Nerd Font + Oh My Posh 提示符 + Fastfetch 首屏信息。素材按需从官方源下载（发布包不再内置）。' -Icon 'beauty' -Width 900
$pageBeauty.Controls.Add($hdrBeauty)
$lblBeautyHead = $hdrBeauty.Tag.Title
$lblBeautyDesc = $hdrBeauty.Tag.Sub
[void](Add-PageAdvancedButton -Header $hdrBeauty -Title '终端美化' -Groups @('终端美化'))

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

# 动作按钮：都是既有动作，参数与「更多 → 终端美化」里的一致
[void](New-BeautyButton -Text '一键美化终端' -ActionId 'console-install' -Kind 'Primary' -Params @{ Theme = 1 })
[void](New-BeautyButton -Text '打开美化终端' -ActionId 'console-open'    -Params @{})
[void](New-BeautyButton -Text '状态检查（实测）' -ActionId 'console-status' -Params @{ DeepProbe = $true })
[void](New-BeautyButton -Text '安装 PowerShell 7' -ActionId 'console-ps7' -Params @{})
[void](New-BeautyButton -Text '一键还原' -ActionId 'console-restore' -Params @{})

# 写回脚本作用域：布局函数、Update-BeautyView 以及本页事件绑定都要用这些控件
$script:hdrBeauty        = $hdrBeauty
$script:lblBeautyDesc    = $lblBeautyDesc
$script:pnlBeautyStatus  = $pnlBeautyStatus
$script:lblBeautyHint    = $lblBeautyHint
$script:pnlBeautyTheme   = $pnlBeautyTheme
$script:lblBeautyTheme   = $lblBeautyTheme
$script:cmbBeautyTheme   = $cmbBeautyTheme
$script:lblBeautyThemeNote = $lblBeautyThemeNote
$script:pnlBeautyActions = $pnlBeautyActions
$script:hintBeauty       = $hintBeauty
$script:pnlBeautyRows    = $pnlBeautyRows
Bind-BeautyEvents
}
$script:PageBuilders['beauty'] = 'Build-BeautyPage'

function Bind-BeautyEvents {
    # 美化页的事件绑定；页面首次显示时由 Build-BeautyPage 调用
    $cmbBeautyTheme.Add_SelectedIndexChanged({
        # 让「一键美化终端」按当前选中的主题跑（索引与动作里的 Options 一致）
        $idx = 1
        try { $idx = [int]$cmbBeautyTheme.SelectedIndex + 1 } catch { }
        foreach ($b in @($pnlBeautyActions.Controls)) {
            if ($b.Tag -and $b.Tag.Id -eq 'console-install') { $b.Tag.Params = @{ Theme = $idx } }
        }
    })
}

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

function Show-BeautyPage {
    if ($SkipPageHooks) { return }
    Update-BeautyView
}

# ============================ AI（DeepSeek Harness）页 ============================
# 集成 ccch1mneyyy/dsh-TUI。这页只做三件事：查依赖、装依赖、启动。
# npm 包到底存不存在由 npm 回答（页面里那两行就是 npm view 的实测结果），不照抄文档下结论。

$pageDsh                = New-Object System.Windows.Forms.Panel
$pageDsh.Dock           = 'Fill'
$pageDsh.BackColor      = $Pal.Bg
$script:Pages['dsh']    = $pageDsh
$pnlContent.Controls.Add($pageDsh)

# AI 页控件按需构建（首次显示本页时执行）：页头、状态行、提示条、动作区与结果区
function Build-DshPage {
# HMOL PageHeader：38px 图标块 + 13.5pt 粗标题 + 9pt 副标题（右侧留给本页操作按钮）
$hdrDsh = New-PageHeader -Title 'AI 辅助（DeepSeek Harness）' -Subtitle '指定的集成是 ccch1mneyyy/dsh-TUI（npm 包 @deepseek-harness-tui/dsh-tui），依赖 Node.js ≥ 22.19 / pnpm ≥ 10 / 官方 CLI @deepseek-ai/dsh。' -Icon 'dsh' -Width 900
$pageDsh.Controls.Add($hdrDsh)
$lblDshHead = $hdrDsh.Tag.Title
$lblDshDesc = $hdrDsh.Tag.Sub
[void](Add-PageAdvancedButton -Header $hdrDsh -Title 'AI 辅助' -Groups @('AI 辅助'))

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

# 动作按钮（按钮的点击回调在 New-DshButton 里绑定，随控件一起建）
[void](New-DshButton -Text '一键安装依赖' -ActionId 'dsh-install' -Kind 'Primary' -Params @{ SkipPnpm = $false })
[void](New-DshButton -Text '启动 dsh-TUI'  -ActionId 'dsh-launch'   -Params @{ Resume = $false })
[void](New-DshButton -Text '重新检查'      -ActionId 'dsh-status'   -Params @{})

# 写回脚本作用域：布局函数、Render-Dsh 以及查询宿主的忙碌回调都要用这些控件
$script:hdrDsh        = $hdrDsh
$script:lblDshDesc    = $lblDshDesc
$script:pnlDshStatus  = $pnlDshStatus
$script:pillDshSum    = $pillDshSum
$script:hintDsh       = $hintDsh
$script:barDsh        = $barDsh
$script:pnlDshActions = $pnlDshActions
$script:pnlDshRows    = $pnlDshRows
$script:lblDshEmpty   = $lblDshEmpty
}
$script:PageBuilders['dsh'] = 'Build-DshPage'

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
        # 每页独立 try：某页控件还没建（懒加载）时只跳过它自己那一段，后面的页面照常布局。
        try {
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
        } catch { }

        # ---- 软件页 ----
        # 这一页按需构建：控件还没建时跳过本段，别让后面的页面布局一起被跳掉
        if ($lstApps) {
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
        }

        # ---- 更多页 ----
        # 同上：设置页按需构建，未建过时跳过
        if ($tree) {
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
        }

        # ---- 工具页 ----
        try {
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
        } catch { }

        # ---- 关于页 ----
        # 卡片宽度跟着内容区走；卡片里的文字与按钮都在左侧固定位置，不受影响。
        try {
            $w5 = [Math]::Max(560, $pageAbout.ClientSize.Width)
            $cardAbout.Width = $w5
            $cardAbout.Height = [Math]::Max(250, ($pageAbout.ClientSize.Height - $cardAbout.Top - 8))
            Set-Rounded -Control $cardAbout -Radius 12
        } catch { }

        # ---- 商店页 ----
        # 商店页按需构建：单独 try，未建过时只跳过本页
        try { Update-StoreLayout } catch { }

        # ---- 角色页 ----
        try { Update-RoleLayout } catch { }

        # ---- 仪表盘 / 安全 / 美化 / AI（四页骨架一样，统一走一个函数）----
        # 四页各自按需构建：结果区（Rows）为 $null 说明该页还没建过，跳过它这一页即可，
        # 不能因为前一页没建就把后面几页一起漏掉。
        if ($pnlMonRows) { Update-RayPageLayout -Page $pageMon -Rows $pnlMonRows -Wide @($lblMonDesc, $pnlMonCards, $pnlMonTrend, $pnlMonBar, $hintMon) }
        if ($pnlSecRows) { Update-RayPageLayout -Page $pageSec -Rows $pnlSecRows -Wide @($lblSecDesc, $pnlSecBar, $pnlSecFilter, $hintSec) }
        if ($pnlBeautyRows) { Update-RayPageLayout -Page $pageBeauty -Rows $pnlBeautyRows -Wide @($lblBeautyDesc, $pnlBeautyStatus, $pnlBeautyTheme, $pnlBeautyActions, $hintBeauty) }
        if ($pnlDshRows) { Update-RayPageLayout -Page $pageDsh -Rows $pnlDshRows -Wide @($lblDshDesc, $pnlDshStatus, $hintDsh, $pnlDshActions) }

        # ---- 文件页 ----
        # 左列 = 路径栏(40) + 列表(Fill) + 工具栏(Bottom)，右列 = 信息栏(40) + 预览(Fill) + 保存栏(42)。
        # 拆分条按可用宽度取 55%，下限 280 且右列至少留 240 —— 窄屏（1024）下预览不能被挤没。
        try {
            $wF = [Math]::Max(560, $pageFiles.ClientSize.Width)
            $hF = [Math]::Max(320, $pageFiles.ClientSize.Height)
            $pnlFilesBody.Width  = $wF
            $pnlFilesBody.Height = [Math]::Max(200, ($hF - $pnlFilesBody.Top - 8))

            $fBodyW  = [Math]::Max(320, $pnlFilesBody.ClientSize.Width)
            $fSplit  = [int][Math]::Round($fBodyW * 0.55)
            $fSplit  = [Math]::Max(280, [Math]::Min(($fBodyW - 240), $fSplit))
            $splitFiles.SplitterDistance = $fSplit

            # 路径栏：三个按钮贴右，输入框吃掉剩下的宽度
            $fBarW = [Math]::Max(300, $splitFiles.Panel1.ClientSize.Width)
            $fBtnW = 64; $fGap = 6
            $txtFilePath.Width   = [Math]::Max(120, ($fBarW - ($fBtnW * 3) - ($fGap * 3) - 4))
            $btnFileUp.Left      = [Math]::Max(0, ($fBarW - $fBtnW - 2))
            $btnFileRefresh.Left = [Math]::Max(0, ($fBarW - ($fBtnW * 2) - $fGap - 2))
            $btnFileGo.Left      = [Math]::Max(0, ($fBarW - ($fBtnW * 3) - ($fGap * 2) - 2))
            foreach ($b in @($btnFileGo, $btnFileRefresh, $btnFileUp)) { $b.Top = 6 }

            # 预览栏：编辑按钮贴右，说明文字收住不压按钮
            $fPrevW = [Math]::Max(240, $splitFiles.Panel2.ClientSize.Width)
            $btnFileEdit.Left  = [Math]::Max(0, ($fPrevW - $btnFileEdit.Width - 2))
            $lblFileInfo.Width = [Math]::Max(80, ($fPrevW - $btnFileEdit.Width - 14))

            $lstFiles.Columns[0].Width = [Math]::Max(150, ($fSplit - 84 - 104 - 132 - 66 - 24))
            $lstFiles.Columns[1].Width = 84
            $lstFiles.Columns[2].Width = 104
            $lstFiles.Columns[3].Width = 132
            $lstFiles.Columns[4].Width = 66
        } catch { }

        # ---- 日志页 ----
        # 筛选行固定 58 高；列表与详情按剩余高度 68:32 分配，最低各留 100 / 90。
        try {
            $wL = [Math]::Max(560, $pageLogs.ClientSize.Width)
            $hL = [Math]::Max(320, $pageLogs.ClientSize.Height)

            $pnlLogFilter.Width  = [Math]::Max(400, ($wL - 4))
            $pnlLogFilter.Height = 58
            # TableLayoutPanel 不会把 Dock=Fill 的 FlowLayoutPanel 纵向拉伸（实测停在默认 100 高），
            # 必须显式给高度；两行合计 58，扣掉上下 Margin 2+2 后留 34。
            $pnlLogButtons.Height = 34

            $lListTop = $pnlLogFilter.Top + $pnlLogFilter.Height + 8
            $lDetailH = [Math]::Max(90, [int](($hL - $lListTop - 16) * 0.32))
            $lListH   = [Math]::Max(100, ($hL - $lListTop - $lDetailH - 12))

            $lstLogs.Left   = 0
            $lstLogs.Top    = $lListTop
            $lstLogs.Width  = [Math]::Max(400, ($wL - 4))
            $lstLogs.Height = $lListH

            $txtLogDetail.Left   = 0
            $txtLogDetail.Top    = $lstLogs.Top + $lstLogs.Height + 4
            $txtLogDetail.Width  = [Math]::Max(400, ($wL - 4))
            $txtLogDetail.Height = [Math]::Max(80, ($hL - $txtLogDetail.Top - 8))

            $lstLogs.Columns[0].Width = 136
            $lstLogs.Columns[1].Width = 56
            $lstLogs.Columns[2].Width = [Math]::Max(120, [int](($wL - 4) * 0.18))
            $lstLogs.Columns[3].Width = 60
            $lstLogs.Columns[4].Width = [Math]::Max(160, ($wL - 4 - 136 - 56 - $lstLogs.Columns[2].Width - 60 - 24))
        } catch { }

        # ---- 任务页 ----
        # 筛选行 58 高；列表与详情按剩余高度 68:32 分配，和日志页保持同一套比例。
        try {
            $wT = [Math]::Max(560, $pageTasks.ClientSize.Width)
            $hT = [Math]::Max(320, $pageTasks.ClientSize.Height)

            $pnlTaskFilter.Width   = [Math]::Max(400, ($wT - 4))
            $pnlTaskFilter.Height  = 58
            $pnlTaskButtons.Height = 34

            $tListTop = $pnlTaskFilter.Top + $pnlTaskFilter.Height + 8
            $tDetailH = [Math]::Max(90, [int](($hT - $tListTop - 16) * 0.32))
            $tListH   = [Math]::Max(100, ($hT - $tListTop - $tDetailH - 12))

            $lstTasks.Left   = 0
            $lstTasks.Top    = $tListTop
            $lstTasks.Width  = [Math]::Max(400, ($wT - 4))
            $lstTasks.Height = $tListH

            $txtTaskDetail.Left   = 0
            $txtTaskDetail.Top    = $lstTasks.Top + $lstTasks.Height + 4
            $txtTaskDetail.Width  = [Math]::Max(400, ($wT - 4))
            $txtTaskDetail.Height = [Math]::Max(80, ($hT - $txtTaskDetail.Top - 8))

            $lstTasks.Columns[0].Width = 126
            $lstTasks.Columns[1].Width = [Math]::Max(140, ($wT - 4 - 126 - 64 - 60 - 56 - 130 - 150 - 24))
            $lstTasks.Columns[2].Width = 64
            $lstTasks.Columns[3].Width = 60
            $lstTasks.Columns[4].Width = 56
            $lstTasks.Columns[5].Width = 130
            $lstTasks.Columns[6].Width = 150
        } catch { }

        # ---- 审计页 ----
        try {
            $wA = [Math]::Max(560, $pageAudit.ClientSize.Width)
            $hA = [Math]::Max(320, $pageAudit.ClientSize.Height)

            $pnlAuditFilter.Width   = [Math]::Max(400, ($wA - 4))
            $pnlAuditFilter.Height  = 58
            $pnlAuditButtons.Height = 34

            $aListTop = $pnlAuditFilter.Top + $pnlAuditFilter.Height + 8
            $aDetailH = [Math]::Max(90, [int](($hA - $aListTop - 16) * 0.32))
            $aListH   = [Math]::Max(100, ($hA - $aListTop - $aDetailH - 12))

            $lstAudit.Left   = 0
            $lstAudit.Top    = $aListTop
            $lstAudit.Width  = [Math]::Max(400, ($wA - 4))
            $lstAudit.Height = $aListH

            $txtAuditDetail.Left   = 0
            $txtAuditDetail.Top    = $lstAudit.Top + $lstAudit.Height + 4
            $txtAuditDetail.Width  = [Math]::Max(400, ($wA - 4))
            $txtAuditDetail.Height = [Math]::Max(80, ($hA - $txtAuditDetail.Top - 8))

            $lstAudit.Columns[0].Width = 126
            $lstAudit.Columns[1].Width = 84
            $lstAudit.Columns[2].Width = 52
            $lstAudit.Columns[3].Width = 120
            $lstAudit.Columns[4].Width = 150
            $lstAudit.Columns[5].Width = [Math]::Max(160, ($wA - 4 - 126 - 84 - 52 - 120 - 150 - 24))
        } catch { }

        # ---- 远程主机页 ----
        # 筛选行 58 + 工具行 34；列表与详情按剩余高度 68:32 分配。
        try {
            $wH = [Math]::Max(560, $pageHosts.ClientSize.Width)
            $hH = [Math]::Max(320, $pageHosts.ClientSize.Height)

            $pnlHostFilter.Width  = [Math]::Max(400, ($wH - 4))
            $pnlHostFilter.Height = 58
            $pnlHostButtons.Height = 34

            $pnlHostBar.Left   = 0
            $pnlHostBar.Top    = $pnlHostFilter.Top + $pnlHostFilter.Height + 4
            $pnlHostBar.Width  = [Math]::Max(400, ($wH - 4))
            $pnlHostBar.Height = 34

            $hListTop = $pnlHostBar.Top + $pnlHostBar.Height + 6
            $hDetailH = [Math]::Max(90, [int](($hH - $hListTop - 16) * 0.32))
            $hListH   = [Math]::Max(100, ($hH - $hListTop - $hDetailH - 12))

            $lstHosts.Left   = 0
            $lstHosts.Top    = $hListTop
            $lstHosts.Width  = [Math]::Max(400, ($wH - 4))
            $lstHosts.Height = $hListH

            $txtHostDetail.Left   = 0
            $txtHostDetail.Top    = $lstHosts.Top + $lstHosts.Height + 4
            $txtHostDetail.Width  = [Math]::Max(400, ($wH - 4))
            $txtHostDetail.Height = [Math]::Max(80, ($hH - $txtHostDetail.Top - 8))

            $lstHosts.Columns[0].Width = 150
            $lstHosts.Columns[1].Width = 150
            $lstHosts.Columns[2].Width = 56
            $lstHosts.Columns[3].Width = 60
            $lstHosts.Columns[4].Width = 76
            $lstHosts.Columns[5].Width = 56
            $lstHosts.Columns[6].Width = 110
            $lstHosts.Columns[7].Width = 126
            $lstHosts.Columns[8].Width = 60
            $lstHosts.Columns[9].Width = [Math]::Max(120, ($wH - 4 - 150 - 150 - 56 - 60 - 76 - 56 - 110 - 126 - 60 - 24))
        } catch { }

        # 控制行 34 + 状态框 110 + 日志尾撑满剩余；窄屏只压宽度，不动纵向节奏。
        try {




        } catch { }

        # ---- PageHeader 收尾同步（必须放在最后）----
        # 上面各页的 -Wide 列表会按"页面宽度"去撑副标题，而副标题现在是页头的子控件，
        # 撑过头就会画出页头右边界（实测 962 > 900）。这里按页头的实际宽度重算一次：
        # 页头横贯内容区，副标题在它内部收住（超出部分省略号）。
        foreach ($h in @($hdrEnv, $hdrApp, $hdrTool, $hdrMore, $hdrStore, $hdrRole,
                         $hdrMon, $hdrSec, $hdrBeauty, $hdrDsh, $hdrAbout, $hdrFiles, $hdrLogs,
                         $hdrTasks, $hdrAudit, $hdrHosts)) {
            if (-not $h -or -not $h.Parent) { continue }
            $hw = [Math]::Max(240, $h.Parent.ClientSize.Width)
            $h.Width = $hw
            if ($h.Tag -and $h.Tag.Advanced) {
                # 右侧挂了「高级设置」按钮：副标题要让出按钮宽度，
                # 否则窄屏下长句子会压到按钮上（和之前压出页头边界是同一类问题）。
                $adv = $h.Tag.Advanced
                $adv.Left = [Math]::Max(0, ($hw - $adv.Width - 2))
                if ($h.Tag.Sub) {
                    $h.Tag.Sub.Width = [Math]::Max(80, ($hw - [int]$h.Tag.GapX - $adv.Width - 14))
                }
            } elseif ($h.Tag -and $h.Tag.Sub) {
                $h.Tag.Sub.Width = [Math]::Max(80, ($hw - [int]$h.Tag.GapX - 10))
            }
        }
        # 日志页的汇总胶囊挂在页头右侧，跟着页头宽度贴右边；副标题要让出胶囊的位置
        try {
            $pillLogSum.Left = [Math]::Max(0, ($hdrLogs.Width - $pillLogSum.Width - 8))
            $lblLogsDesc.Width = [Math]::Max(80, ($hdrLogs.Width - [int]$hdrLogs.Tag.GapX - $pillLogSum.Width - 16))
        } catch { }
        # 任务页右侧同时挂了「高级设置」「通知」「汇总胶囊」，从右往左依次排；
        # 副标题右边界跟着最左边那个控件收住，窄屏下不会被压住。
        try {
            $tRight = $hdrTasks.Width - 2
            foreach ($c in @($btnTaskAdv, $btnTaskNotify, $pillTaskSum)) {
                if (-not $c) { continue }
                $c.Left = [Math]::Max(0, ($tRight - $c.Width))
                $tRight = $c.Left - 6
            }
            $lblTasksDesc.Width = [Math]::Max(80, ($pillTaskSum.Left - [int]$hdrTasks.Tag.GapX - 12))
            $pillAuditSum.Left = [Math]::Max(0, ($hdrAudit.Width - $pillAuditSum.Width - 8))
            $lblAuditDesc.Width = [Math]::Max(80, ($hdrAudit.Width - [int]$hdrAudit.Tag.GapX - $pillAuditSum.Width - 16))
        } catch { }
        # 远程主机页：汇总胶囊靠右，副标题让位。
        try {
            $pillHostSum.Left = [Math]::Max(0, ($hdrHosts.Width - $pillHostSum.Width - 8))
            $lblHostsDesc.Width = [Math]::Max(80, ($hdrHosts.Width - [int]$hdrHosts.Tag.GapX - $pillHostSum.Width - 16))
        } catch { }
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
        # 下限只留一行提示的高度：矮窗口（LayoutDump 的 1024x600 客户区只有 524 高）里，
        # 指标卡加高后结果区 Top 会被推到 472，此时 80 的下限会让它探出底边（真机扫描报越界）。
        # 正常高度（1240x820）下这条分支根本走不到，结果区仍然是"撑满剩余"。
        $avail = $h - $Rows.Top - 8
        if ($avail -lt 32) { $avail = 32 }
        $Rows.Height = [int]$avail
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
        $pnlStoreFilter.Width = $w
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
    # 这一页的控件还没建过：先建（builder 由各页面段末尾注册），再走显示与布局。
    $__builder = [string]$script:PageBuilders[$Key]
    if ($__builder -and -not $script:PageBuilt[$Key]) {
        $script:PageBuilt[$Key] = $true
        & $__builder
    }
    foreach ($k in $script:Pages.Keys) { $script:Pages[$k].Visible = ($k -eq $Key) }
    # 这一页第一次显示时，把它里面登记过的圆角 Region 补上（延迟 Region 的兑现点）。
    # 必须是"页面已可见"之后：控件的实际宽高要到这时才是最终值。
    Apply-DeferredRounds -Root $script:Pages[$Key]
    # 同一时机给页面铺氛围底、把系统部件刷成深色（滚动条/下拉/文本框）。
    # 只做一次：之后切页不再重复遍历控件树。
    try {
        if (-not $script:UiPreparedPages) { $script:UiPreparedPages = New-Object 'System.Collections.Generic.HashSet[System.Windows.Forms.Control]' }
        if (-not $script:UiPreparedPages.Contains($script:Pages[$Key])) {
            [void]$script:UiPreparedPages.Add($script:Pages[$Key])
            Add-UiAmbientBackdrop -Control $script:Pages[$Key]
            Enable-UiDarkChildren -Root $script:Pages[$Key]
        }
    } catch { }
    # 导航：记住模块归属 → 侧栏按需要顶替成分类列 → 同步两边选中态。
    # 导航项都是自绘面板，只改 Tag 里的状态再重画，不做控件重建。
    $__modKey = Get-GuiModuleOfPage -PageKey $Key
    if ($__modKey) { $script:GuiModuleLastPage[$__modKey] = $Key }
    $__mod = Get-GuiModule -Key $__modKey
    if ($__mod -and @($__mod.Pages).Count -gt 1) { Set-GuiSidebarMode -Mode 'cats' -PageKey $Key }
    else { Set-GuiSidebarMode -Mode 'modules' -PageKey $Key }
    Sync-GuiNav -PageKey $Key
    if ($Key -eq 'env' -and -not $SkipCards) { Refresh-EnvCards }
    if ($Key -eq 'store') { Show-StorePage }
    if ($Key -eq 'role') { Show-RolePage }
    if ($Key -eq 'monitor') { Show-MonPage }
    if ($Key -eq 'security') { Show-SecPage }
    if ($Key -eq 'beauty') { Show-BeautyPage }
    if ($Key -eq 'dsh') { Show-DshPage }
    if ($Key -eq 'files') { Show-FilesPage }
    if ($Key -eq 'logs') { Show-LogsPage }
    if ($Key -eq 'tasks') { Show-TasksPage }
    if ($Key -eq 'audit') { Show-AuditPage }
    if ($Key -eq 'hosts') { Show-HostsPage }
    if ($Key -eq 'tool') { Update-ToolButtons; Update-WacToolGroup }
    # 页头错峰淡入（HMOL：单块 280ms、步长 22ms、OutFluent）
    if (-not $SkipPageHooks) {
        $hdrs = @()
        try {
            $pg = $script:Pages[$Key]
            foreach ($c in @($pg.Controls)) {
                if ($c -is [System.Windows.Forms.Label]) { $hdrs += $c }
                if ($hdrs.Count -ge 4) { break }
            }
        } catch { }
        if ($hdrs.Count -gt 0) { Invoke-UiPageFadeIn -Controls $hdrs }
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
    param([switch]$Force, [switch]$Fast)

    if (-not $Force -and $script:EnvCacheData -and ((Get-Date) - $script:EnvCacheTime).TotalSeconds -lt $script:EnvCacheTtlSec) {
        return $script:EnvCacheData
    }

    $d = [ordered]@{
        Static = $null; Profile = $null; Cap = $null; DllScan = $null
        DotNet = $null; Sessions = $null; AutoLogon = $null; Uac = $null; Wac = $null
    }
    try { $d.Static    = Get-GuiReadyStatic } catch { }
    try { $d.Profile   = Get-GuiReadyOsProfile -Static $d.Static } catch { }
    try { $d.DllScan   = Get-GuiReadyDllScan } catch { }
    if ($Fast) {
        # 快速路径（自检 / 布局诊断）：DISM 的 Get-WindowsCapability 首次查询在这台
        # Server Core 上实测 >90s（通配符更久），会把自检拖到超时。这里用已经拿到的
        # 组件扫描结果推断 FOD 状态，并标 Inferred=true —— 与后台探测 fast 阶段同一套规则。
        $has = @{}
        foreach ($x in @($d.DllScan)) { if ($x) { $has[[string]$x.Name] = [bool]$x.Exists } }
        $coreOk = [bool]($has['dwm.exe'] -and $has['dcomp.dll'] -and $has['dwrite.dll'])
        $d.Cap = [pscustomobject]@{
            Queried  = $true
            Inferred = $true
            Error    = ''
            Items    = @([pscustomobject]@{
                Name  = 'ServerCore.AppCompatibility'
                State = $(if ($coreOk) { 'Installed' } else { 'NotPresent' })
            })
        }
    } else {
        try { $d.Cap = Get-GuiReadyCapability } catch { }
    }
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
    param([switch]$Force, [switch]$Fast, $Data)
    Initialize-EnvCards
    # $Data 是后台探测（或磁盘缓存）的结果；没传就同步查一次（自检 / 布局诊断用这条路）
    if ($null -eq $Data) {
        $Data = Get-EnvCardData -Force:$Force -Fast:$Fast
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
    # 自检 / 布局诊断要的是同步、真实的数据，不能起后台进程。
    # 但 DISM 的 FOD 精确查询在 Server Core 上首次可能 >90s（实测），会把自检拖到超时；
    # 这里走快速推断（与后台探测 fast 阶段同规则），精确结果留给正常进入页面时的后台 full 阶段。
    if ($SelfTest -or $LayoutDump) { Update-EnvCards -Fast; return }
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
    param($Panel = $null, $Map = $null)
    if (-not $Panel) { $Panel = $pnlParams }
    if (-not $Map)   { $Map   = $script:ParamControls }
    foreach ($ctl in @($Panel.Controls)) { $ctl.Dispose() }
    $Panel.Controls.Clear()
    # 用 Clear() 而不是换新实例：外部（Start-GuiAction）持有的是同一个 hashtable 引用
    if ($Map -is [hashtable]) { $Map.Clear() }
}

function Select-GuiAction {
    # 参数容器可外部传入：设置页用默认（$lblActTitle/$pnlParams/...），
    # 「高级设置」对话框传自己的一套 —— 同一套渲染逻辑服务两处，不复制参数控件代码。
    param(
        $Action,
        $TitleLabel = $null,
        $DescLabel  = $null,
        $ParamPanel = $null,
        $DryButton  = $null,
        $ParamMap   = $null
    )
    # 默认参数面板/运行按钮都在「设置」页。设置页是按需构建的，从别的页触发动作时先把它建出来，
    # 否则 $pnlParams / $btnRun 还是 $null，动作界面点不出来（只在用户点动作时发生，不影响启动）。
    $__moreBuilder = [string]$script:PageBuilders['more']
    if ($__moreBuilder -and -not $script:PageBuilt['more']) {
        $script:PageBuilt['more'] = $true
        & $__moreBuilder
    }
    if (-not $TitleLabel) { $TitleLabel = $lblActTitle }
    if (-not $DescLabel)  { $DescLabel  = $lblActDesc }
    if (-not $ParamPanel) { $ParamPanel = $pnlParams }
    if (-not $DryButton)  { $DryButton  = $btnDry }
    if (-not $ParamMap)   { $ParamMap   = $script:ParamControls }

    $script:CurrentAction  = $Action
    $script:ActiveParamMap = $ParamMap
    $TitleLabel.Text = $Action.Name
    $DescLabel.Text  = $Action.Desc
    Clear-ParamControls -Panel $ParamPanel -Map $ParamMap

    $y = 6
    foreach ($pd in @($Action.Params)) {
        # 必填项在标签后面加个 * —— 与 Start-GuiAction 开跑前的校验是同一套标记（Req）
        $req = ($pd.ContainsKey('Req') -and [bool]$pd.Req)
        $lbText = [string]$pd.Label
        if ($req) { $lbText = $lbText + '  *' }
        $lb = New-Label -Text $lbText -Size 9 -Color $(if ($req) { 'Accent3' } else { 'SubText' })
        $lb.Location = New-Object System.Drawing.Point(8, ($y + 4))
        $ParamPanel.Controls.Add($lb)

        $w = 320
        if ($pd.ContainsKey('Width')) { $w = [int]$pd.Width }
        $x = [Math]::Max(230, ($ParamPanel.Width - $w - 60))
        # 标签限宽：AutoSize 的长标签会压到右侧输入框上（审计实测 244 > 230-8）。
        # 关掉自动尺寸、超长用省略号收住，右边界让到输入框左侧 8px。
        $lb.AutoSize     = $false
        $lb.AutoEllipsis = $true
        $lb.Width        = [Math]::Max(60, ($x - 16))
        $lb.Height       = 20
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
            'Multi' {
                # 多行参数（例如整段文件内容）：单行 TextBox 装不下，也不便于核对。
                $ctl = New-Object System.Windows.Forms.TextBox
                $ctl.Multiline   = $true
                $ctl.AcceptsReturn = $true
                $ctl.ScrollBars  = 'Vertical'
                $ctl.Size        = New-Object System.Drawing.Size($w, 120)
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
        $ParamPanel.Controls.Add($ctl)
        $ParamMap[[string]$pd.Name] = $ctl

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
            $ParamPanel.Controls.Add($bb)
        }
        if ([string]$pd.Type -eq 'Multi') { $y += 126 } else { $y += 30 }
    }
    $DryButton.Enabled = [bool]$Action.DryRun
}

function Get-ParamValues {
    param($Map = $null)
    # 没指定就用"当前动作来自哪套控件"：设置页 = $script:ParamControls，
    # 「高级设置」对话框 = 它自己的 hashtable（Select-GuiAction 时记进 ActiveParamMap）。
    if (-not $Map) {
        $Map = $(if ($script:ActiveParamMap) { $script:ActiveParamMap } else { $script:ParamControls })
    }
    $P = @{}
    if (-not $script:CurrentAction) { return $P }
    foreach ($pd in @($script:CurrentAction.Params)) {
        $n = [string]$pd.Name
        $ctl = $Map[$n]
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
    $script:CurrentJobId = ''
    Clear-EnvCache          # 动作可能改了环境状态
    # 只有正在看「环境」页时才重新探测；探测在后台跑，界面不卡
    if ($script:CurrentPage -eq 'env') { Start-EnvProbe }
    Refresh-ProgramList
    # 任务 / 审计页正开着就刷新一次，动作结束后不用手点「刷新」。
    if ($script:CurrentPage -eq 'tasks') { Start-TasksQuery }
    if ($script:CurrentPage -eq 'audit') { Start-AuditQuery }
    if ($script:CurrentPage -eq 'tasks') { Update-NotifyButton }
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
    param([bool]$DryRun = $false, [string]$RetryOf = '')

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
    $jobId = ''
    try { $jobId = New-GuiReadyTaskId } catch { $jobId = ('task-' + $stamp) }
    $script:CurrentJobId = $jobId
    Append-GuiLog -Line ''
    Append-GuiLog -Line ('[STEP] ==== {0} {1} ====' -f $script:CurrentAction.Name, $(if ($DryRun) { '（仅预览）' } else { '' }))
    Append-GuiLog -Line ('[INFO] 任务编号: ' + $jobId)
    if ($RetryOf) { Append-GuiLog -Line ('[INFO] 重试来源: ' + $RetryOf) }
    $btnFill.Enabled = $false
    $btnRun.Enabled  = $false
    $script:RunStart = Get-Date

    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:RunnerPath + '"'),
                     '-Action', $script:CurrentAction.Id,
                     '-ArgsFile', ('"' + $argsFile + '"'),
                     '-LogFile', ('"' + $script:RunLogFile + '"'),
                     '-JobId', ('"' + $jobId + '"'))
        if ($RetryOf) { $argList += @('-RetryOf', ('"' + $RetryOf + '"')) }
        $script:Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden `
                        -RedirectStandardOutput $script:OutFile -RedirectStandardError $script:ErrFile
        $script:Timer.Start()
    } catch {
        Append-GuiLog -Line ('[ERROR] 无法启动动作进程: ' + $_.Exception.Message)
        $btnFill.Enabled = $true; $btnRun.Enabled = $true
        $script:Proc = $null
        $script:CurrentJobId = ''
    }
}

function Bind-MoreEvents {
    # 设置页的事件绑定 + 左侧功能树填充；页面首次显示时由 Build-MorePage 调用
    $btnRun.Add_Click({ Start-GuiAction -DryRun $false })
    $btnDry.Add_Click({ Start-GuiAction -DryRun $true })

    $tree.Add_AfterSelect({
        $n = $tree.SelectedNode
        if ($n -and $n.Tag) { Select-GuiAction -Action $n.Tag }
    })

    # 设置页只保留「开机与登录」这类系统级设置（用户要求：设置里改成开机自启动之类的）。
    # 其余动作按功能域拆到各页的「高级设置」对话框里，见 Add-PageAdvancedButton。
    $script:SettingsGroups = @('会话与登录', '使用与工具')
    $groups = @($script:Actions | Group-Object Group |
        Where-Object { $script:SettingsGroups -contains [string]$_.Name })
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
}

$script:AdvDialog = $null
function Show-ActionsDialog {
    # 各页「高级设置」的共用面板：按页面传入的动作分组过滤，非模态（不挡住主界面的日志）。
    param([string]$Title = '高级设置', [string[]]$Groups = @())

    # 自检 / 布局导出 / UI 审计时不真开窗：审计会"点"每个按钮，
    # 真开一个窗口会让它在模态循环里卡住，而且也没必要。
    if ($SkipPageHooks -or $script:AuditMode) { return }
    if ($script:AdvDialog -and -not $script:AdvDialog.IsDisposed) {
        try { $script:AdvDialog.Activate() } catch { }
        return
    }
    $acts = @($script:Actions | Where-Object { $Groups -contains [string]$_.Group })
    if ($acts.Count -eq 0) { return }

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = $Title + ' · 高级设置'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.ShowInTaskbar   = $false
    $dlg.BackColor       = $Pal.Bg
    $dlg.ForeColor       = $Pal.Text
    $dlg.Font            = New-Font -Size 9.5
    $dlg.ClientSize      = New-Object System.Drawing.Size(840, 470)
    try { $dlg.Owner = $form } catch { }

    $lst                 = New-Object System.Windows.Forms.ListBox
    $lst.Location        = New-Object System.Drawing.Point(0, 0)
    $lst.Size            = New-Object System.Drawing.Size(250, 470)
    $lst.BorderStyle     = 'None'
    $lst.BackColor       = $Pal.Card
    $lst.ForeColor       = $Pal.Text
    $lst.Font            = New-Font -Size 9.5
    $lst.IntegralHeight  = $false
    foreach ($a in $acts) { [void]$lst.Items.Add([string]$a.Name) }
    $dlg.Controls.Add($lst)

    $right           = New-Object System.Windows.Forms.Panel
    $right.Location  = New-Object System.Drawing.Point(262, 0)
    $right.Size      = New-Object System.Drawing.Size(578, 470)
    $right.BackColor = $Pal.Card
    $right.Padding   = New-Object System.Windows.Forms.Padding(14)
    $dlg.Controls.Add($right)

    $lblT          = New-Label -Text '从左侧选一个功能' -Size 11 -Style Bold
    $lblT.Location = New-Object System.Drawing.Point(14, 14)
    $right.Controls.Add($lblT)

    $lblD          = New-Label -Text '' -Size 9 -Color SubText -Width 548
    $lblD.Location = New-Object System.Drawing.Point(16, 42)
    $lblD.Height   = 54
    $right.Controls.Add($lblD)

    $pnlP            = New-Object System.Windows.Forms.Panel
    $pnlP.Location   = New-Object System.Drawing.Point(14, 100)
    $pnlP.Size       = New-Object System.Drawing.Size(548, 110)
    $pnlP.AutoScroll = $true
    $pnlP.BackColor  = $Pal.Bg
    $right.Controls.Add($pnlP)

    $btnGo          = New-FlatButton -Text '运行' -Width 100 -Height 34 -Kind Primary
    $btnGo.Location = New-Object System.Drawing.Point(14, 222)
    $right.Controls.Add($btnGo)

    $btnDryAdv          = New-FlatButton -Text '仅预览' -Width 90 -Height 34
    $btnDryAdv.Location = New-Object System.Drawing.Point(122, 222)
    $right.Controls.Add($btnDryAdv)

    $btnClose          = New-FlatButton -Text '关闭' -Width 80 -Height 34
    $btnClose.Location = New-Object System.Drawing.Point(220, 222)
    $btnClose.Add_Click({ try { $script:AdvDialog.Close() } catch { } })
    $right.Controls.Add($btnClose)

    # 用脚本级变量而不是 .GetNewClosure()：事件回调在函数返回后才执行，局部变量已经没了；
    # 而 GetNewClosure() 会新建模块作用域，脚本里定义的函数（Select-GuiAction 等）在里面看不见。
    $script:AdvDialog = $dlg
    $script:AdvActs   = $acts
    $script:AdvList   = $lst
    $script:AdvTitle  = $lblT
    $script:AdvDesc   = $lblD
    $script:AdvPanel  = $pnlP
    $script:AdvDry    = $btnDryAdv
    $script:AdvMap    = @{}

    $lst.Add_SelectedIndexChanged({
        $i = [int]$script:AdvList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:AdvActs.Count) { return }
        Select-GuiAction -Action $script:AdvActs[$i] -TitleLabel $script:AdvTitle `
            -DescLabel $script:AdvDesc -ParamPanel $script:AdvPanel `
            -DryButton $script:AdvDry -ParamMap $script:AdvMap
    })
    $btnGo.Add_Click({ Start-GuiAction -DryRun $false })
    $btnDryAdv.Add_Click({ Start-GuiAction -DryRun $true })
    $dlg.Add_FormClosed({
        $script:AdvDialog = $null
        # 关掉对话框后，把动作上下文还给设置页当前选中的节点，
        # 免得主窗口的「运行」还在指向对话框里选过的动作。
        $script:ActiveParamMap = $null
        try {
            if ($tree.SelectedNode -and $tree.SelectedNode.Tag) {
                Select-GuiAction -Action $tree.SelectedNode.Tag
            }
        } catch { }
    })

    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = 0 }
    $dlg.Show()
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

function Get-ProgramCmd {
    # 绑定的终端命令（别名）。没绑过就返回空串。
    param($Item)
    if ($Item -and $Item.PSObject.Properties['Cmd'] -and $Item.Cmd) { return [string]$Item.Cmd }
    return ''
}

function Refresh-ProgramList {
    if (-not $lstApps) { return }   # 软件页还没按需构建：没有列表可刷，等页面建好时自己会填
    $lstApps.BeginUpdate()
    $lstApps.Items.Clear()
    foreach ($p in $script:Programs) {
        $verdict = ''
        # 只绑了命令、没有 exe 路径的条目 Path 是空串：Test-Path -LiteralPath '' 会直接抛
        # （界面自检就是这么挂的），这里必须先判空。
        $exePath = ([string]$p.Path).Trim()
        $exists = if ($exePath) { Test-Path -LiteralPath $exePath } else { $false }
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
        [void]$it.SubItems.Add((Get-ProgramCmd -Item $p))
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

function Bind-AppEvents {
    # 软件页的事件绑定；页面首次显示时由 Build-AppPage 调用
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

$btnAppCmd.Add_Click({
    # 绑/解绑终端命令：往 System32 写（或删）一个 <别名>.cmd 垫片。
    # 实现见 lib\GuiReady.Command.ps1 的 Install/Remove-GuiReadyProgramCommand。
    $it = Get-SelectedProgram
    if (-not $it) { return }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { }
    $cur = Get-ProgramCmd -Item $it

    $tip = '在终端里输入什么就能打开它？' + [Environment]::NewLine +
           '只允许字母、数字、点、下划线、加号、减号（例如 wx、ps、notepad2）；留空表示解除绑定。' + [Environment]::NewLine + [Environment]::NewLine +
           ('程序：' + $it.Path)
    try {
        $new = [Microsoft.VisualBasic.Interaction]::InputBox($tip, ('绑定终端命令 - ' + $it.Name), $cur)
    } catch {
        [System.Windows.Forms.MessageBox]::Show('无法弹出输入框。', '提示', 'OK', 'Warning') | Out-Null
        return
    }
    $new = ([string]$new).Trim()

    # 别名换了 → 先把旧的解除掉，免得留一个指向本程序的僵尸命令
    if ($cur -and $cur -ne $new) { [void](Remove-GuiReadyProgramCommand -Alias $cur) }

    if (-not $new) {
        $it.Cmd = ''
        Save-Programs
        Refresh-ProgramList
        Append-GuiLog -Line ('[OK] 已解除终端命令绑定: ' + $it.Name)
        return
    }

    $r = Install-GuiReadyProgramCommand -Alias $new -ExePath ([string]$it.Path) -Arguments (Get-ProgramArg -Item $it)
    if (-not $r.Ok) {
        $msg = '绑定失败。'
        switch ([string]$r.Code) {
            'AliasEmpty'    { $msg = '命令名不能为空。' }
            'AliasTooLong'  { $msg = '命令名太长（上限 32 个字符）。' }
            'AliasBadChar'  { $msg = '命令名只能包含字母、数字、点、下划线、加号、减号。' }
            'AliasReserved' { $msg = '这是系统/工具的保留命令名（如 cmd、powershell、scm、sconfig），换一个。' }
            'ExeMissing'    { $msg = '程序文件不存在，先确认路径。' }
            'Occupied'      { $msg = ('System32 里已经有同名的 ' + $new + '.cmd，而且不是本工具写的，不覆盖。') }
            default         { $msg = ('写入失败：' + $r.Code) }
        }
        [System.Windows.Forms.MessageBox]::Show($msg, '绑定失败', 'OK', 'Warning') | Out-Null
        Append-GuiLog -Line ('[WARN] 绑定终端命令失败(' + $r.Code + '): ' + $new)
        return
    }

    $it.Cmd = $new
    Save-Programs
    Refresh-ProgramList
    Append-GuiLog -Line ('[OK] 已绑定终端命令: 输入 "' + $new + '" 即可打开 ' + $it.Name)
    Append-GuiLog -Line ('     命令文件: ' + $r.Target)
    try {
        [System.Windows.Forms.MessageBox]::Show(
            ('绑好了：在 cmd 或 PowerShell 里输入 ' + $new + ' 回车就会打开它。' + [Environment]::NewLine + [Environment]::NewLine +
             ('命令文件：' + $r.Target) + [Environment]::NewLine +
             '（刚绑的命令要新开一个终端窗口才生效；同一个窗口里刷新 PATH 不会重新扫命令表。）'),
            '绑定成功', 'OK', 'Information') | Out-Null
    } catch { }
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
}

# ============================ 文件管理页 ============================
# 浏览 / 预览 / 编辑 / 新建 / 重命名 / 复制 / 移动 / 删除 / 压缩 / 解压。
# 读取走查询宿主，写操作走动作机制：两边都是子进程，UI 线程只负责画结果。

$pageFiles             = New-Object System.Windows.Forms.Panel
$pageFiles.Dock        = 'Fill'
$pageFiles.BackColor   = $Pal.Bg
$script:Pages['files'] = $pageFiles
$pnlContent.Controls.Add($pageFiles)

# 文件页控件按需构建（首次显示本页时执行）：页头、左右分栏、列表、预览栏与右键菜单
function Build-FilesPage {
$hdrFiles = New-PageHeader -Title '文件管理' -Subtitle '浏览服务器文件系统，预览/编辑文本，压缩解压与整理目录。所有写操作都会记入全局日志。' -Icon 'files' -Width 900
$pageFiles.Controls.Add($hdrFiles)
$lblFilesHead = $hdrFiles.Tag.Title
$lblFilesDesc = $hdrFiles.Tag.Sub

$script:FilesPath          = $toolRoot
$script:FilesItems         = @()
$script:FilesPreviewPath   = ''
$script:FilesPreviewBinary = $false
$script:FilesPreviewTrunc  = $false
$script:FilesPreviewDirty  = $false
$script:FilesRefreshPending = $false
$script:FilesReloadPreview  = $false

$pnlFilesBody = New-Object System.Windows.Forms.Panel
$pnlFilesBody.Location  = New-Object System.Drawing.Point(0, 56)
$pnlFilesBody.BackColor = $Pal.Bg
$pageFiles.Controls.Add($pnlFilesBody)

$splitFiles                  = New-Object System.Windows.Forms.SplitContainer
$splitFiles.Dock             = 'Fill'
$splitFiles.Orientation      = 'Vertical'
$splitFiles.SplitterWidth    = 8
$splitFiles.BackColor        = $Pal.Bg
$splitFiles.Panel1.BackColor = $Pal.Bg
$splitFiles.Panel2.BackColor = $Pal.Bg
$pnlFilesBody.Controls.Add($splitFiles)

# ---- 左：路径栏 + 列表 + 工具栏 ----
$lstFiles                 = New-Object System.Windows.Forms.ListView
$lstFiles.Dock            = 'Fill'
$lstFiles.View            = 'Details'
$lstFiles.FullRowSelect   = $true
$lstFiles.HideSelection   = $false
$lstFiles.MultiSelect     = $false
$lstFiles.GridLines       = $false
$lstFiles.BorderStyle     = 'None'
$lstFiles.BackColor       = $Pal.Card
$lstFiles.ForeColor       = $Pal.Text
$lstFiles.Font            = New-Font -Size 9.5
[void]$lstFiles.Columns.Add('名称', 240)
[void]$lstFiles.Columns.Add('大小', 84)
[void]$lstFiles.Columns.Add('类型', 104)
[void]$lstFiles.Columns.Add('修改时间', 132)
[void]$lstFiles.Columns.Add('属性', 66)
$splitFiles.Panel1.Controls.Add($lstFiles)
Enable-GuiListViewSkin -List $lstFiles -RowHeight 40

$pnlFileTools             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlFileTools.Dock        = 'Bottom'
$pnlFileTools.AutoSize    = $true
$pnlFileTools.AutoSizeMode = 'GrowAndShrink'
$pnlFileTools.WrapContents = $true
$pnlFileTools.FlowDirection = 'LeftToRight'
$pnlFileTools.BackColor   = $Pal.Bg
$pnlFileTools.Padding     = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$splitFiles.Panel1.Controls.Add($pnlFileTools)

$btnFileNew     = New-FlatButton -Text '新建文件夹' -Width 96 -Height 30
$btnFileRename  = New-FlatButton -Text '重命名' -Width 76 -Height 30
$btnFileDelete  = New-FlatButton -Text '删除' -Width 64 -Height 30 -Kind Danger
$btnFileCopy    = New-FlatButton -Text '复制到' -Width 76 -Height 30
$btnFileMove    = New-FlatButton -Text '移动到' -Width 76 -Height 30
$btnFileZip     = New-FlatButton -Text '压缩' -Width 64 -Height 30
$btnFileUnzip   = New-FlatButton -Text '解压' -Width 64 -Height 30
foreach ($b in @($btnFileNew, $btnFileRename, $btnFileDelete, $btnFileCopy, $btnFileMove, $btnFileZip, $btnFileUnzip)) {
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 6)
    $pnlFileTools.Controls.Add($b)
}

$pnlFilePath             = New-Object System.Windows.Forms.Panel
$pnlFilePath.Dock        = 'Top'
$pnlFilePath.Height      = 40
$pnlFilePath.BackColor   = $Pal.Bg
$splitFiles.Panel1.Controls.Add($pnlFilePath)

$txtFilePath             = New-Object System.Windows.Forms.TextBox
$txtFilePath.Location    = New-Object System.Drawing.Point(0, 5)
$txtFilePath.Size        = New-Object System.Drawing.Size(340, 26)
$txtFilePath.Anchor      = 'Top,Left,Right'
$txtFilePath.BackColor   = $Pal.Sunken
$txtFilePath.ForeColor   = $Pal.Text
$txtFilePath.BorderStyle = 'FixedSingle'
$txtFilePath.Font        = New-Font -Size 9.5
$pnlFilePath.Controls.Add($txtFilePath)

$btnFileGo      = New-FlatButton -Text '转到' -Width 64 -Height 28
$btnFileRefresh = New-FlatButton -Text '刷新' -Width 64 -Height 28
$btnFileUp      = New-FlatButton -Text '上级' -Width 64 -Height 28
foreach ($b in @($btnFileGo, $btnFileRefresh, $btnFileUp)) {
    $b.Anchor = 'Top,Right'
    $pnlFilePath.Controls.Add($b)
}

# ---- 右：预览 + 信息 ----
$txtFilePreview           = New-Object System.Windows.Forms.TextBox
$txtFilePreview.Dock      = 'Fill'
$txtFilePreview.Multiline = $true
$txtFilePreview.ReadOnly  = $true
$txtFilePreview.ScrollBars = 'Both'
$txtFilePreview.WordWrap  = $false
$txtFilePreview.BackColor = $Pal.Sunken
$txtFilePreview.ForeColor = $Pal.Text
$txtFilePreview.BorderStyle = 'None'
$txtFilePreview.Font      = New-Font -Size 9.5
$splitFiles.Panel2.Controls.Add($txtFilePreview)

$pnlFilePreviewBar             = New-Object System.Windows.Forms.Panel
$pnlFilePreviewBar.Dock        = 'Top'
$pnlFilePreviewBar.Height      = 40
$pnlFilePreviewBar.BackColor   = $Pal.Bg
$splitFiles.Panel2.Controls.Add($pnlFilePreviewBar)

$lblFileInfo = New-Label -Text '选择文件查看预览' -Size 8.8 -Color SubText -Width 220
$lblFileInfo.Location   = New-Object System.Drawing.Point(2, 10)
$lblFileInfo.AutoEllipsis = $true
$pnlFilePreviewBar.Controls.Add($lblFileInfo)

$btnFileEdit = New-FlatButton -Text '编辑' -Width 64 -Height 28
$btnFileEdit.Anchor = 'Top,Right'
$btnFileEdit.Location = New-Object System.Drawing.Point(226, 4)
$pnlFilePreviewBar.Controls.Add($btnFileEdit)
$btnFileEdit.Enabled = $false

$pnlFilePreviewBottom             = New-Object System.Windows.Forms.Panel
$pnlFilePreviewBottom.Dock        = 'Bottom'
$pnlFilePreviewBottom.Height      = 42
$pnlFilePreviewBottom.BackColor   = $Pal.Bg
$splitFiles.Panel2.Controls.Add($pnlFilePreviewBottom)

$btnFileSave = New-FlatButton -Text '保存修改' -Width 96 -Height 30 -Kind Primary
$btnFileSave.Location = New-Object System.Drawing.Point(0, 5)
$pnlFilePreviewBottom.Controls.Add($btnFileSave)
$btnFileSave.Enabled = $false

# ---- 右键菜单 ----
$menuFiles                = New-Object System.Windows.Forms.ContextMenuStrip
$menuFiles.BackColor      = $Pal.Card
$menuFiles.ForeColor      = $Pal.Text
$menuFiles.ShowImageMargin = $false
foreach ($spec in @(
    @{ T = '预览/编辑'; K = 'preview' }, @{ T = '重命名'; K = 'rename' },
    @{ T = '删除'; K = 'delete' }, @{ T = '复制到…'; K = 'copy' },
    @{ T = '移动到…'; K = 'move' }, @{ T = '压缩为 ZIP…'; K = 'zip' },
    @{ T = '解压 ZIP…'; K = 'unzip' }, @{ T = '属性'; K = 'props' }
)) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($spec.T)
    $mi.BackColor = $Pal.Card
    $mi.ForeColor = $Pal.Text
    $mi.Tag = $spec.K
    $menuFiles.Items.Add($mi) | Out-Null
}
$lstFiles.ContextMenuStrip = $menuFiles

# 写回脚本作用域：布局函数、列表/预览渲染函数以及本页事件绑定都要用这些控件
$script:hdrFiles       = $hdrFiles
$script:pnlFilesBody   = $pnlFilesBody
$script:splitFiles     = $splitFiles
$script:lstFiles       = $lstFiles
$script:btnFileNew     = $btnFileNew
$script:btnFileRename  = $btnFileRename
$script:btnFileDelete  = $btnFileDelete
$script:btnFileCopy    = $btnFileCopy
$script:btnFileMove    = $btnFileMove
$script:btnFileZip     = $btnFileZip
$script:btnFileUnzip   = $btnFileUnzip
$script:pnlFilePath    = $pnlFilePath
$script:txtFilePath    = $txtFilePath
$script:btnFileGo      = $btnFileGo
$script:btnFileRefresh = $btnFileRefresh
$script:btnFileUp      = $btnFileUp
$script:txtFilePreview = $txtFilePreview
$script:lblFileInfo    = $lblFileInfo
$script:btnFileEdit    = $btnFileEdit
$script:btnFileSave    = $btnFileSave
$script:menuFiles      = $menuFiles
Bind-FilesEvents
}
$script:PageBuilders['files'] = 'Build-FilesPage'

function Get-FilesSelectedItem {
    if ($lstFiles.SelectedItems.Count -eq 0) { return $null }
    return $lstFiles.SelectedItems[0].Tag
}

function Update-FilesButtons {
    $it = Get-FilesSelectedItem
    $has = ($null -ne $it)
    $btnFileRename.Enabled = $has
    $btnFileDelete.Enabled = $has
    $btnFileCopy.Enabled   = $has
    $btnFileMove.Enabled   = $has
    $btnFileZip.Enabled    = $has
    $btnFileUnzip.Enabled  = [bool]($has -and (-not $it.IsDir) -and ([string]$it.Name).ToLowerInvariant().EndsWith('.zip'))
    $btnFileEdit.Enabled   = [bool]($script:FilesPreviewPath -and -not $script:FilesPreviewBinary -and -not $script:FilesPreviewTrunc -and $txtFilePreview.ReadOnly)
    $btnFileSave.Enabled   = [bool]($script:FilesPreviewDirty -and -not $txtFilePreview.ReadOnly)
}

function Start-FilesQuery {
    param([string]$Mode, [hashtable]$Params)
    [void](Start-GuiQueryHost -Query $script:QFiles -Task $Mode -ArgsJson $Params -BusyText '读取文件…')
}

function Start-FilesAction {
    # 写操作统一走动作机制：参数先填进全局参数控件，再启动动作子进程；
    # 动作跑完后盯住 QFiles 拿到回调，自动刷新列表与预览。
    param([string]$Id, [hashtable]$Params)

    $a = @($script:Actions | Where-Object { $_.Id -eq $Id })
    if ($a.Count -eq 0) {
        Append-GuiLog -Line ('[ERROR] 未找到功能: ' + $Id)
        return
    }
    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请稍后再试。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    Select-GuiAction -Action $a[0]
    Set-ParamValues -Values $Params
    Start-GuiAction -DryRun $false
    if ($script:Proc) {
        if (-not $script:QFiles.Task) { Start-GuiQueryWatch -Query $script:QFiles }
        else { $script:FilesRefreshPending = $true }
    }
}

function Set-FilesLocation {
    param([string]$Path)

    $txtFilePreview.ReadOnly = $true
    $txtFilePreview.Text     = ''
    $btnFileEdit.Text        = '编辑'
    $script:FilesPreviewPath   = ''
    $script:FilesPreviewDirty  = $false
    $script:FilesPreviewBinary = $false
    $script:FilesPreviewTrunc  = $false
    $lblFileInfo.Text          = '读取中…'
    Start-FilesQuery -Mode 'list' -Params @{ Path = $Path; ShowHidden = $false }
}

function Show-FilesList {
    $lstFiles.BeginUpdate()
    try {
        $lstFiles.Items.Clear()
        foreach ($it in @($script:FilesItems)) {
            $li = New-Object System.Windows.Forms.ListViewItem([string]$it.Name)
            [void]$li.SubItems.Add([string]$it.SizeText)
            [void]$li.SubItems.Add([string]$it.Type)
            [void]$li.SubItems.Add([string]$it.Modified)
            [void]$li.SubItems.Add([string]$it.Attributes)
            $li.Tag = $it
            if ($it.IsDir) { $li.ForeColor = $Pal.Accent3 } else { $li.ForeColor = $Pal.Text }
            [void]$lstFiles.Items.Add($li)
        }
    } finally { $lstFiles.EndUpdate() }
    Update-FilesButtons
}

function Show-FilePreview {
    param([string]$Path)

    $script:FilesPreviewPath = $Path
    $txtFilePreview.ReadOnly = $true
    $btnFileEdit.Text        = '编辑'
    $script:FilesPreviewDirty = $false
    $lblFileInfo.Text        = '读取预览…'
    Start-FilesQuery -Mode 'read' -Params @{ Path = $Path; MaxKB = 256 }
}

function Receive-FilesResult {
    param($Obj)

    if ($null -eq $Obj) {
        # 动作结束的回调：刷新列表；之前若因查询忙而挂起，这里一并补上。
        $script:FilesRefreshPending = $false
        $script:FilesReloadPreview  = [bool]$script:FilesPreviewPath
        Start-FilesQuery -Mode 'list' -Params @{ Path = $script:FilesPath; ShowHidden = $false }
        return
    }

    if ($Obj.Error) {
        $lblFileInfo.Text = ('读取失败：' + [string]$Obj.Error)
        Append-GuiLog -Line ('[WARN] 文件查询: ' + [string]$Obj.Error)
        return
    }

    if ($Obj.Mode -eq 'list') {
        $data = $Obj.Data
        $script:FilesPath  = [string]$data.Path
        $script:FilesItems = @($data.Items)
        $txtFilePath.Text  = $script:FilesPath
        $lblFileInfo.Text  = ('{0} 项{1}' -f $data.Total, $(if ($data.Truncated) { '（仅显示前 2000 项）' } else { '' }))
        Show-FilesList
        if ($script:FilesRefreshPending) {
            $script:FilesRefreshPending = $false
            Start-FilesQuery -Mode 'list' -Params @{ Path = $script:FilesPath; ShowHidden = $false }
        } elseif ($script:FilesReloadPreview -and $script:FilesPreviewPath) {
            $script:FilesReloadPreview = $false
            Start-FilesQuery -Mode 'read' -Params @{ Path = $script:FilesPreviewPath; MaxKB = 256 }
        }
        return
    }

    if ($Obj.Mode -eq 'read') {
        $data = $Obj.Data
        $script:FilesPreviewPath   = [string]$data.Path
        $script:FilesPreviewBinary = [bool]$data.Binary
        $script:FilesPreviewTrunc  = [bool]$data.Truncated
        $script:FilesPreviewDirty  = $false
        $script:FilesPreviewSize   = [long]$data.Size
        $txtFilePreview.ReadOnly   = $true
        $btnFileEdit.Text          = '编辑'
        if ($data.Binary) {
            $txtFilePreview.Text = ('[二进制文件，不提供文本预览]' + "`r`n" + '大小：' + (Format-GuiReadyByteSize -Bytes $data.Size))
            $lblFileInfo.Text    = '二进制文件'
        } else {
            $txtFilePreview.Text = [string]$data.Text
            $tail = ''
            if ($data.Truncated) { $tail = ' · 已截断（仅预览前 256 KB，编辑已禁用）' }
            $lblFileInfo.Text = ('{0} · {1} · {2} 行 · {3}{4}' -f [System.IO.Path]::GetFileName($data.Path), $data.Encoding, $data.Lines, (Format-GuiReadyByteSize -Bytes $data.Size), $tail)
        }
        $txtFilePreview.SelectionStart = 0
        Update-FilesButtons
    }
}

$script:QFiles = New-GuiQueryHost -Name 'files' -Runner (Join-Path $guiDir 'Run-GuiReadyFiles.ps1') -TimeoutSec 60 `
    -OnResult { param($obj) Receive-FilesResult -Obj $obj } `
    -OnBusyStart { param($t) $lblFileInfo.Text = $t } `
    -OnBusyEnd { }

function Bind-FilesEvents {
    # 文件页的事件绑定；页面首次显示时由 Build-FilesPage 调用
$btnFileGo.Add_Click({ Set-FilesLocation -Path $txtFilePath.Text })
$btnFileRefresh.Add_Click({ Set-FilesLocation -Path $script:FilesPath })
$btnFileUp.Add_Click({
    $parent = [System.IO.Path]::GetDirectoryName($script:FilesPath)
    if ($parent) { Set-FilesLocation -Path $parent }
})
$txtFilePath.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Set-FilesLocation -Path $txtFilePath.Text }
})
$lstFiles.Add_SelectedIndexChanged({
    $it = Get-FilesSelectedItem
    Update-FilesButtons
    if ($it -and -not $it.IsDir) {
        $lblFileInfo.Text = ('{0} · {1} · {2}' -f $it.Name, $it.SizeText, $it.Modified)
    }
})
$lstFiles.Add_DoubleClick({
    $it = Get-FilesSelectedItem
    if (-not $it) { return }
    if ($it.IsDir) { Set-FilesLocation -Path $it.FullName } else { Show-FilePreview -Path $it.FullName }
})
$lstFiles.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $it = Get-FilesSelectedItem
        if (-not $it) { return }
        if ($it.IsDir) { Set-FilesLocation -Path $it.FullName } else { Show-FilePreview -Path $it.FullName }
    }
})
$txtFilePreview.Add_TextChanged({
    if (-not $txtFilePreview.ReadOnly) {
        $script:FilesPreviewDirty = $true
        $btnFileSave.Enabled = $true
    }
})

$btnFileNew.Add_Click({
    $name = Show-GuiInputDialog -Title '新建文件夹' -Label ('在以下目录新建：' + $script:FilesPath) -Default '新建文件夹'
    if ($null -eq $name -or -not $name.Trim()) { return }
    Start-FilesAction -Id 'file-mkdir' -Params @{ Path = $script:FilesPath; Name = $name.Trim() }
})
$btnFileRename.Add_Click({
    $it = Get-FilesSelectedItem
    if (-not $it) { return }
    $name = Show-GuiInputDialog -Title '重命名' -Label ('当前名称：' + $it.Name) -Default $it.Name
    if ($null -eq $name -or -not $name.Trim()) { return }
    Start-FilesAction -Id 'file-rename' -Params @{ Path = $it.FullName; NewName = $name.Trim() }
})
$btnFileDelete.Add_Click({
    $it = Get-FilesSelectedItem
    if (-not $it) { return }
    $kind = $(if ($it.IsDir) { '文件夹（含其中全部内容）' } else { '文件' })
    $r = [System.Windows.Forms.MessageBox]::Show(('确定删除这个{0}吗？`r`n`r`n{1}' -f $kind, $it.FullName), '确认删除', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    Start-FilesAction -Id 'file-delete' -Params @{ Path = $it.FullName; Recurse = [bool]$it.IsDir }
})
$btnFileCopy.Add_Click({
    $it = Get-FilesSelectedItem
    if (-not $it) { return }
    $dest = Show-GuiInputDialog -Title '复制到' -Label '目标路径或已存在的目标目录：' -Default $script:FilesPath
    if ($null -eq $dest -or -not $dest.Trim()) { return }
    Start-FilesAction -Id 'file-copy' -Params @{ Path = $it.FullName; Destination = $dest.Trim(); Overwrite = $false }
})
$btnFileMove.Add_Click({
    $it = Get-FilesSelectedItem
    if (-not $it) { return }
    $dest = Show-GuiInputDialog -Title '移动到' -Label '目标路径或已存在的目标目录：' -Default $script:FilesPath
    if ($null -eq $dest -or -not $dest.Trim()) { return }
    Start-FilesAction -Id 'file-move' -Params @{ Path = $it.FullName; Destination = $dest.Trim(); Overwrite = $false }
})
$btnFileZip.Add_Click({
    $it = Get-FilesSelectedItem
    if (-not $it) { return }
    $leaf = [System.IO.Path]::GetFileName($it.FullName.TrimEnd('\'))
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = '压缩为 ZIP'
    $dlg.Filter = 'ZIP 压缩包|*.zip'
    $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($it.FullName)
    $dlg.FileName = $(if ($leaf.ToLowerInvariant().EndsWith('.zip')) { $leaf } else { $leaf + '.zip' })
    if ($dlg.ShowDialog() -ne 'OK') { return }
    Start-FilesAction -Id 'file-compress' -Params @{ Path = $it.FullName; Destination = $dlg.FileName }
})
$btnFileUnzip.Add_Click({
    $it = Get-FilesSelectedItem
    if (-not $it) { return }
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = '选择解压目标目录'
    $fbd.SelectedPath = $script:FilesPath
    $fbd.ShowNewFolderButton = $true
    if ($fbd.ShowDialog() -ne 'OK') { return }
    Start-FilesAction -Id 'file-expand' -Params @{ Path = $it.FullName; Destination = $fbd.SelectedPath; Overwrite = $false }
})
$btnFileEdit.Add_Click({
    if (-not $script:FilesPreviewPath) { return }
    if ($txtFilePreview.ReadOnly) {
        if ($script:FilesPreviewBinary -or $script:FilesPreviewTrunc) { return }
        $txtFilePreview.ReadOnly = $false
        $btnFileEdit.Text = '取消编辑'
        $btnFileSave.Enabled = $false
        $script:FilesPreviewDirty = $false
        $txtFilePreview.Focus()
    } else {
        $txtFilePreview.ReadOnly = $true
        $btnFileEdit.Text = '编辑'
        $btnFileSave.Enabled = $false
        $script:FilesPreviewDirty = $false
        Start-FilesQuery -Mode 'read' -Params @{ Path = $script:FilesPreviewPath; MaxKB = 256 }
    }
})
$btnFileSave.Add_Click({
    if (-not $script:FilesPreviewPath) { return }
    Start-FilesAction -Id 'file-save' -Params @{ Path = $script:FilesPreviewPath; Text = $txtFilePreview.Text }
    $script:FilesPreviewDirty = $false
    $btnFileSave.Enabled = $false
})

$menuFiles.Add_ItemClicked({
    param($s, $e)
    $it = Get-FilesSelectedItem
    switch ([string]$e.ClickedItem.Tag) {
        'preview' { if ($it -and -not $it.IsDir) { Show-FilePreview -Path $it.FullName } }
        'rename'  { if ($it) { $btnFileRename.PerformClick() } }
        'delete'  { if ($it) { $btnFileDelete.PerformClick() } }
        'copy'    { if ($it) { $btnFileCopy.PerformClick() } }
        'move'    { if ($it) { $btnFileMove.PerformClick() } }
        'zip'     { if ($it) { $btnFileZip.PerformClick() } }
        'unzip'   { if ($it -and $btnFileUnzip.Enabled) { $btnFileUnzip.PerformClick() } }
        'props'   {
            if (-not $it) { return }
            try {
                $info = Get-GuiReadyFilePathInfo -Path $it.FullName
                $msg = ("路径：{0}`r`n类型：{1}`r`n大小：{2}`r`n创建：{3}`r`n修改：{4}`r`n访问：{5}`r`n属性：{6}`r`n所有者：{7}" -f
                    $info.FullName, $(if ($info.IsDir) { '文件夹' } else { '文件' }), $info.SizeText,
                    $info.Created, $info.Modified, $info.Accessed, $info.Attributes, $info.Owner)
                [System.Windows.Forms.MessageBox]::Show($msg, '属性', 'OK', 'Information') | Out-Null
            } catch { Append-GuiLog -Line ('[WARN] 读取属性失败: ' + $_.Exception.Message) }
        }
    }
})
}

function Show-FilesPage {
    if ($SkipPageHooks) { return }
    $txtFilePath.Text = $script:FilesPath
    if ($script:FilesItems.Count -eq 0 -and -not $script:QFiles.Task) {
        Start-FilesQuery -Mode 'list' -Params @{ Path = $script:FilesPath; ShowHidden = $false }
    } else {
        Show-FilesList
    }
}

# ============================ 日志中心页 ============================
# 事件日志（System/Application/Setup/Security）与工具自身 logs 目录下的文件日志统一查看。

$pageLogs             = New-Object System.Windows.Forms.Panel
$pageLogs.Dock        = 'Fill'
$pageLogs.BackColor   = $Pal.Bg
$script:Pages['logs'] = $pageLogs
$pnlContent.Controls.Add($pageLogs)

# 日志页控件按需构建（首次显示本页时执行）：页头、筛选栏、日志列表与详情框
function Build-LogsPage {
$hdrLogs = New-PageHeader -Title '日志中心' -Subtitle '统一查看 Windows 事件日志与工具自身日志，按级别/时间/关键词筛选后可导出 CSV 或文本。' -Icon 'logs' -Width 900
$pageLogs.Controls.Add($hdrLogs)
$lblLogsHead = $hdrLogs.Tag.Title
$lblLogsDesc = $hdrLogs.Tag.Sub

$pillLogSum = New-Pill -Text '待查询' -Kind 'Neutral'
$pillLogSum.Anchor = 'Top,Right'
$pillLogSum.Location = New-Object System.Drawing.Point(816, 11)
$hdrLogs.Controls.Add($pillLogSum)

$script:LogSourceIds    = @()
$script:LogSourcesReady = $false
$script:LogEntries      = @()
$script:LogsRefreshPending = $false
$script:LogLastParams   = @{ Source = 'event:System'; Max = 300; Level = 'All'; Since = '24h'; Keyword = '' }

$pnlLogFilter             = New-Object System.Windows.Forms.TableLayoutPanel
$pnlLogFilter.Location    = New-Object System.Drawing.Point(0, 56)
$pnlLogFilter.BackColor   = $Pal.Bg
$pnlLogFilter.ColumnCount = 5
$pnlLogFilter.RowCount    = 2
$pnlLogFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null
$pnlLogFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 96))) | Out-Null
$pnlLogFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110))) | Out-Null
$pnlLogFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
$pnlLogFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 176))) | Out-Null
$pnlLogFilter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 18))) | Out-Null
$pnlLogFilter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
$pageLogs.Controls.Add($pnlLogFilter)

foreach ($spec in @(
    @{ C = 0; T = '日志源' }, @{ C = 1; T = '级别' }, @{ C = 2; T = '时间范围' }, @{ C = 3; T = '关键词' }
)) {
    $l = New-Label -Text $spec.T -Size 8.5 -Color Hint
    $l.Dock = 'Fill'
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $pnlLogFilter.Controls.Add($l, $spec.C, 0)
}

$cmbLogSource             = New-Object System.Windows.Forms.ComboBox
$cmbLogSource.Dock        = 'Fill'
$cmbLogSource.DropDownStyle = 'DropDownList'
$cmbLogSource.FlatStyle   = 'Flat'
$cmbLogSource.BackColor   = $Pal.Sunken
$cmbLogSource.ForeColor   = $Pal.Text
$cmbLogSource.Font        = New-Font -Size 9
$cmbLogSource.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$pnlLogFilter.Controls.Add($cmbLogSource, 0, 1)

$cmbLogLevel              = New-Object System.Windows.Forms.ComboBox
$cmbLogLevel.Dock         = 'Fill'
$cmbLogLevel.DropDownStyle = 'DropDownList'
$cmbLogLevel.FlatStyle    = 'Flat'
$cmbLogLevel.BackColor    = $Pal.Sunken
$cmbLogLevel.ForeColor    = $Pal.Text
$cmbLogLevel.Font         = New-Font -Size 9
$cmbLogLevel.Margin       = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
foreach ($x in @('全部', '错误', '警告', '信息')) { [void]$cmbLogLevel.Items.Add($x) }
$cmbLogLevel.SelectedIndex = 0
$pnlLogFilter.Controls.Add($cmbLogLevel, 1, 1)

$cmbLogSince              = New-Object System.Windows.Forms.ComboBox
$cmbLogSince.Dock         = 'Fill'
$cmbLogSince.DropDownStyle = 'DropDownList'
$cmbLogSince.FlatStyle    = 'Flat'
$cmbLogSince.BackColor    = $Pal.Sunken
$cmbLogSince.ForeColor    = $Pal.Text
$cmbLogSince.Font         = New-Font -Size 9
$cmbLogSince.Margin       = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
foreach ($x in @('1 小时', '6 小时', '24 小时', '7 天', '30 天', '全部')) { [void]$cmbLogSince.Items.Add($x) }
$cmbLogSince.SelectedIndex = 2
$pnlLogFilter.Controls.Add($cmbLogSince, 2, 1)

$txtLogKeyword             = New-Object System.Windows.Forms.TextBox
$txtLogKeyword.Dock        = 'Fill'
$txtLogKeyword.BackColor   = $Pal.Sunken
$txtLogKeyword.ForeColor   = $Pal.Text
$txtLogKeyword.BorderStyle = 'FixedSingle'
$txtLogKeyword.Font        = New-Font -Size 9
$txtLogKeyword.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$pnlLogFilter.Controls.Add($txtLogKeyword, 3, 1)

$pnlLogButtons             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlLogButtons.Dock        = 'Fill'
$pnlLogButtons.FlowDirection = 'LeftToRight'
$pnlLogButtons.WrapContents = $false
$pnlLogButtons.BackColor   = $Pal.Bg
$pnlLogButtons.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
$btnLogQuery  = New-FlatButton -Text '查询' -Width 76 -Height 30 -Kind Primary
$btnLogExport = New-FlatButton -Text '导出' -Width 76 -Height 30
foreach ($b in @($btnLogQuery, $btnLogExport)) {
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
    $pnlLogButtons.Controls.Add($b)
}
$pnlLogFilter.Controls.Add($pnlLogButtons, 4, 1)
$pnlLogFilter.SetRowSpan($pnlLogButtons, 2)

$lstLogs                 = New-Object System.Windows.Forms.ListView
$lstLogs.Location        = New-Object System.Drawing.Point(0, 150)
$lstLogs.View            = 'Details'
$lstLogs.FullRowSelect   = $true
$lstLogs.HideSelection   = $false
$lstLogs.MultiSelect     = $false
$lstLogs.GridLines       = $false
$lstLogs.BorderStyle     = 'None'
$lstLogs.BackColor       = $Pal.Card
$lstLogs.ForeColor       = $Pal.Text
$lstLogs.Font            = New-Font -Size 9
$lstLogs.Anchor          = 'Top,Left,Right'
[void]$lstLogs.Columns.Add('时间', 136)
[void]$lstLogs.Columns.Add('级别', 56)
[void]$lstLogs.Columns.Add('来源', 170)
[void]$lstLogs.Columns.Add('事件ID', 60)
[void]$lstLogs.Columns.Add('消息', 380)
$pageLogs.Controls.Add($lstLogs)
Enable-GuiListViewSkin -List $lstLogs

$txtLogDetail             = New-Object System.Windows.Forms.TextBox
$txtLogDetail.Location    = New-Object System.Drawing.Point(0, 400)
$txtLogDetail.Multiline   = $true
$txtLogDetail.ReadOnly    = $true
$txtLogDetail.ScrollBars  = 'Vertical'
$txtLogDetail.BackColor   = $Pal.Sunken
$txtLogDetail.ForeColor   = $Pal.Text
$txtLogDetail.BorderStyle = 'FixedSingle'
$txtLogDetail.Font        = New-Font -Size 9
$txtLogDetail.Anchor      = 'Top,Bottom,Left,Right'
$pageLogs.Controls.Add($txtLogDetail)

# 写回脚本作用域：布局函数、日志渲染函数以及本页事件绑定都要用这些控件
$script:hdrLogs       = $hdrLogs
$script:lblLogsDesc   = $lblLogsDesc
$script:pillLogSum    = $pillLogSum
$script:pnlLogFilter  = $pnlLogFilter
$script:pnlLogButtons = $pnlLogButtons
$script:cmbLogSource  = $cmbLogSource
$script:cmbLogLevel   = $cmbLogLevel
$script:cmbLogSince   = $cmbLogSince
$script:txtLogKeyword = $txtLogKeyword
$script:btnLogQuery   = $btnLogQuery
$script:btnLogExport  = $btnLogExport
$script:lstLogs       = $lstLogs
$script:txtLogDetail  = $txtLogDetail
Bind-LogsEvents
}
$script:PageBuilders['logs'] = 'Build-LogsPage'

function Start-LogsQuerySources {
    [void](Start-GuiQueryHost -Query $script:QLogs -Task 'sources' -BusyText '读取日志源…')
}

function Start-LogsQuery {
    $idx = $cmbLogSource.SelectedIndex
    $src = 'event:System'
    if ($idx -ge 0 -and $idx -lt $script:LogSourceIds.Count) { $src = [string]$script:LogSourceIds[$idx] }

    $levels = @('All', 'Error', 'Warning', 'Information')
    $ranges = @('1h', '6h', '24h', '7d', '30d', 'all')
    $li = [Math]::Max(0, [Math]::Min(3, $cmbLogLevel.SelectedIndex))
    $si = [Math]::Max(0, [Math]::Min(5, $cmbLogSince.SelectedIndex))

    $p = @{
        Source  = $src
        Max     = 300
        Level   = $levels[$li]
        Since   = $ranges[$si]
        Keyword = $txtLogKeyword.Text.Trim()
    }
    $script:LogLastParams = $p
    [void](Start-GuiQueryHost -Query $script:QLogs -Task 'read' -ArgsJson $p -BusyText '读取日志…')
}

function Start-LogsExport {
    $p = $script:LogLastParams
    $levels = @('All', 'Error', 'Warning', 'Information')
    $ranges = @('1h', '6h', '24h', '7d', '30d', 'all')
    $li = [Array]::IndexOf($levels, [string]$p.Level)
    if ($li -lt 0) { $li = 0 }
    $si = [Array]::IndexOf($ranges, [string]$p.Since)
    if ($si -lt 0) { $si = 2 }

    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = '导出日志'
    $dlg.Filter = 'CSV|*.csv|文本|*.txt'
    $dlg.FileName = ('scm-logs-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    if ($dlg.ShowDialog() -ne 'OK') { return }

    $fmt = $(if ($dlg.FileName.ToLowerInvariant().EndsWith('.txt')) { 2 } else { 1 })
    Start-LogsAction -Id 'log-export' -Params @{
        Source = $p.Source; Level = ($li + 1); Since = ($si + 1)
        Keyword = $p.Keyword; Path = $dlg.FileName; Format = $fmt
    }
}

function Start-LogsAction {
    param([string]$Id, [hashtable]$Params)

    $a = @($script:Actions | Where-Object { $_.Id -eq $Id })
    if ($a.Count -eq 0) { Append-GuiLog -Line ('[ERROR] 未找到功能: ' + $Id); return }
    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请稍后再试。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    Select-GuiAction -Action $a[0]
    Set-ParamValues -Values $Params
    Start-GuiAction -DryRun $false
    if ($script:Proc) {
        if (-not $script:QLogs.Task) { Start-GuiQueryWatch -Query $script:QLogs }
        else { $script:LogsRefreshPending = $true }
    }
}

function Show-LogsList {
    $lstLogs.BeginUpdate()
    try {
        $lstLogs.Items.Clear()
        foreach ($e in @($script:LogEntries)) {
            $li = New-Object System.Windows.Forms.ListViewItem([string]$e.Time)
            [void]$li.SubItems.Add([string]$e.Level)
            [void]$li.SubItems.Add([string]$e.Source)
            [void]$li.SubItems.Add([string]$e.Id)
            [void]$li.SubItems.Add((([string]$e.Message) -replace "`r?`n", ' '))
            $li.Tag = $e
            switch ([string]$e.Level) {
                '错误' { $li.ForeColor = $Pal.Err }
                '警告' { $li.ForeColor = $Pal.Warn }
                default { $li.ForeColor = $Pal.Text }
            }
            [void]$lstLogs.Items.Add($li)
        }
    } finally { $lstLogs.EndUpdate() }
}

function Receive-LogsResult {
    param($Obj)

    if ($null -eq $Obj) {
        $script:LogsRefreshPending = $false
        Start-LogsQuery
        return
    }

    if ($Obj.Error) {
        Set-Pill -Pill $pillLogSum -Text '读取失败' -Kind 'Danger'
        $txtLogDetail.Text = [string]$Obj.Error
        Append-GuiLog -Line ('[WARN] 日志查询: ' + [string]$Obj.Error)
        return
    }

    if ($Obj.Mode -eq 'sources') {
        $list = @($Obj.Data)
        $cmbLogSource.Items.Clear()
        $script:LogSourceIds = @()
        foreach ($s in $list) {
            $script:LogSourceIds += [string]$s.Id
            $label = [string]$s.Name
            if ([string]$s.Kind -eq 'file') { $label = '[文件] ' + $label }
            [void]$cmbLogSource.Items.Add($label)
        }
        $script:LogSourcesReady = $true
        if ($script:LogSourceIds.Count -eq 0) {
            Set-Pill -Pill $pillLogSum -Text '没有可用日志源' -Kind 'Warn'
            return
        }
        $pref = [Array]::IndexOf($script:LogSourceIds, [string]$script:LogLastParams.Source)
        if ($pref -lt 0) { $pref = [Array]::IndexOf($script:LogSourceIds, 'event:System') }
        if ($pref -lt 0) { $pref = 0 }
        $cmbLogSource.SelectedIndex = $pref
        Start-LogsQuery
        return
    }

    if ($Obj.Mode -eq 'read') {
        $data = $Obj.Data
        $script:LogEntries = @($data.Entries)
        Show-LogsList
        $txtLogDetail.Text = ''
        $tail = ''
        if ($data.Truncated) { $tail = '（已截断）' }
        Set-Pill -Pill $pillLogSum -Text ('{0} 条{1}' -f $data.Count, $tail) -Kind $(if ($data.Count -gt 0) { 'Success' } else { 'Neutral' })
        if ($script:LogsRefreshPending) {
            $script:LogsRefreshPending = $false
            Start-LogsQuery
        }
    }
}

$script:QLogs = New-GuiQueryHost -Name 'logs' -Runner (Join-Path $guiDir 'Run-GuiReadyLogs.ps1') -TimeoutSec 120 `
    -OnResult { param($obj) Receive-LogsResult -Obj $obj } `
    -OnBusyStart { param($t) Set-Pill -Pill $pillLogSum -Text $t -Kind 'Info' } `
    -OnBusyEnd { }

function Bind-LogsEvents {
    # 日志页的事件绑定；页面首次显示时由 Build-LogsPage 调用
$btnLogQuery.Add_Click({ Start-LogsQuery })
$btnLogExport.Add_Click({ Start-LogsExport })
$txtLogKeyword.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Start-LogsQuery }
})
$cmbLogSource.Add_SelectedIndexChanged({
    # 只切源不自动查：避免用户用方向键浏览时连续拉起 Get-WinEvent。
})
$lstLogs.Add_SelectedIndexChanged({
    if ($lstLogs.SelectedItems.Count -eq 0) { return }
    $e = $lstLogs.SelectedItems[0].Tag
    if (-not $e) { return }
    $txtLogDetail.Text = ("时间：{0}`r`n级别：{1}`r`n来源：{2}`r`n事件 ID：{3}`r`n{4}`r`n{5}" -f
        $e.Time, $e.Level, $e.Source, $e.Id, ('-' * 60), $e.Message)
    $txtLogDetail.SelectionStart = 0
})
}

function Show-LogsPage {
    if ($SkipPageHooks) { return }
    if (-not $script:LogSourcesReady) {
        if (-not $script:QLogs.Task) { Start-LogsQuerySources }
    } elseif ($script:LogEntries.Count -eq 0 -and -not $script:QLogs.Task) {
        Start-LogsQuery
    }
}

# ============================ 任务中心 / 结构审计 ============================
# 任务中心：每次动作执行都有编号、状态、耗时、退出码和日志路径，支持取消与重试。
# 结构审计：提交 / 开始 / 结束 / 配置备份恢复等事件只追加记录，可筛选、可导出。
# 两个列表都交给独立查询进程（Run-GuiReadyTasks.ps1）读，界面线程只负责渲染。

$script:TaskItems           = @()
$script:TaskStats           = $null
$script:TaskUnread          = 0
$script:TaskRefreshPending  = $false
$script:AuditItems          = @()
$script:AuditRefreshPending = $false

$pageTasks             = New-Object System.Windows.Forms.Panel
$pageTasks.Dock        = 'Fill'
$pageTasks.BackColor   = $Pal.Bg
$script:Pages['tasks'] = $pageTasks
$pnlContent.Controls.Add($pageTasks)

# 任务页控件按需构建（首次显示本页时执行）：页头、筛选栏、任务列表与详情框
function Build-TasksPage {
$hdrTasks = New-PageHeader -Title '任务中心' -Subtitle '每个动作都有编号、状态、耗时、退出码和日志；失败的会进入通知收件箱，可直接重试或取消。' -Icon 'tasks' -Width 900
$pageTasks.Controls.Add($hdrTasks)
$lblTasksHead = $hdrTasks.Tag.Title
$lblTasksDesc = $hdrTasks.Tag.Sub

$pillTaskSum = New-Pill -Text '待查询' -Kind 'Neutral'
$pillTaskSum.Anchor = 'Top,Right'
$pillTaskSum.Location = New-Object System.Drawing.Point(816, 11)
$hdrTasks.Controls.Add($pillTaskSum)

$btnTaskNotify = New-FlatButton -Text '通知 0' -Width 86 -Height 30
$btnTaskNotify.Location = New-Object System.Drawing.Point(700, 5)
$btnTaskNotify.Anchor = 'Top,Right'
$hdrTasks.Controls.Add($btnTaskNotify)

$btnTaskAdv = New-FlatButton -Text '高级设置' -Width 96 -Height 30
$btnTaskAdv.Location = New-Object System.Drawing.Point(794, 5)
$btnTaskAdv.Anchor = 'Top,Right'
$hdrTasks.Controls.Add($btnTaskAdv)

$pnlTaskFilter             = New-Object System.Windows.Forms.TableLayoutPanel
$pnlTaskFilter.Location    = New-Object System.Drawing.Point(0, 56)
$pnlTaskFilter.BackColor   = $Pal.Bg
$pnlTaskFilter.ColumnCount = 4
$pnlTaskFilter.RowCount    = 2
$pnlTaskFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 124))) | Out-Null
$pnlTaskFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110))) | Out-Null
$pnlTaskFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$pnlTaskFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 330))) | Out-Null
$pnlTaskFilter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 18))) | Out-Null
$pnlTaskFilter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
$pageTasks.Controls.Add($pnlTaskFilter)

foreach ($spec in @(@{ C = 0; T = '状态' }, @{ C = 1; T = '时间范围' }, @{ C = 2; T = '关键词' })) {
    $l = New-Label -Text $spec.T -Size 8.5 -Color Hint
    $l.Dock = 'Fill'
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $pnlTaskFilter.Controls.Add($l, $spec.C, 0)
}

$cmbTaskStatus              = New-Object System.Windows.Forms.ComboBox
$cmbTaskStatus.Dock         = 'Fill'
$cmbTaskStatus.DropDownStyle = 'DropDownList'
$cmbTaskStatus.FlatStyle    = 'Flat'
$cmbTaskStatus.BackColor    = $Pal.Sunken
$cmbTaskStatus.ForeColor    = $Pal.Text
$cmbTaskStatus.Font         = New-Font -Size 9
$cmbTaskStatus.Margin       = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
foreach ($x in @('全部', '运行中', '成功', '失败', '已取消', '已中断')) { [void]$cmbTaskStatus.Items.Add($x) }
$cmbTaskStatus.SelectedIndex = 0
$pnlTaskFilter.Controls.Add($cmbTaskStatus, 0, 1)

$cmbTaskSince               = New-Object System.Windows.Forms.ComboBox
$cmbTaskSince.Dock          = 'Fill'
$cmbTaskSince.DropDownStyle = 'DropDownList'
$cmbTaskSince.FlatStyle     = 'Flat'
$cmbTaskSince.BackColor     = $Pal.Sunken
$cmbTaskSince.ForeColor     = $Pal.Text
$cmbTaskSince.Font          = New-Font -Size 9
$cmbTaskSince.Margin        = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
foreach ($x in @('今天', '7 天', '30 天', '全部')) { [void]$cmbTaskSince.Items.Add($x) }
$cmbTaskSince.SelectedIndex = 1
$pnlTaskFilter.Controls.Add($cmbTaskSince, 1, 1)

$txtTaskKeyword             = New-Object System.Windows.Forms.TextBox
$txtTaskKeyword.Dock        = 'Fill'
$txtTaskKeyword.BackColor   = $Pal.Sunken
$txtTaskKeyword.ForeColor   = $Pal.Text
$txtTaskKeyword.BorderStyle = 'FixedSingle'
$txtTaskKeyword.Font        = New-Font -Size 9
$txtTaskKeyword.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$pnlTaskFilter.Controls.Add($txtTaskKeyword, 2, 1)

$pnlTaskButtons             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlTaskButtons.Dock        = 'Fill'
$pnlTaskButtons.FlowDirection = 'LeftToRight'
$pnlTaskButtons.WrapContents = $false
$pnlTaskButtons.BackColor   = $Pal.Bg
$pnlTaskButtons.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
$btnTaskRefresh = New-FlatButton -Text '刷新' -Width 72 -Height 30 -Kind Primary
$btnTaskRetry   = New-FlatButton -Text '重试' -Width 72 -Height 30
$btnTaskCancel  = New-FlatButton -Text '取消' -Width 72 -Height 30
$btnTaskLog     = New-FlatButton -Text '查看日志' -Width 88 -Height 30
foreach ($b in @($btnTaskRefresh, $btnTaskRetry, $btnTaskCancel, $btnTaskLog)) {
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
    $pnlTaskButtons.Controls.Add($b)
}
$pnlTaskFilter.Controls.Add($pnlTaskButtons, 3, 1)
$pnlTaskFilter.SetRowSpan($pnlTaskButtons, 2)

$lstTasks                 = New-Object System.Windows.Forms.ListView
$lstTasks.Location        = New-Object System.Drawing.Point(0, 150)
$lstTasks.View            = 'Details'
$lstTasks.FullRowSelect   = $true
$lstTasks.HideSelection   = $false
$lstTasks.MultiSelect     = $false
$lstTasks.GridLines       = $false
$lstTasks.BorderStyle     = 'None'
$lstTasks.BackColor       = $Pal.Card
$lstTasks.ForeColor       = $Pal.Text
$lstTasks.Font            = New-Font -Size 9
$lstTasks.Anchor          = 'Top,Left,Right'
[void]$lstTasks.Columns.Add('开始时间', 126)
[void]$lstTasks.Columns.Add('任务', 220)
[void]$lstTasks.Columns.Add('状态', 64)
[void]$lstTasks.Columns.Add('耗时', 60)
[void]$lstTasks.Columns.Add('退出码', 56)
[void]$lstTasks.Columns.Add('用户', 130)
[void]$lstTasks.Columns.Add('任务编号', 150)
$pageTasks.Controls.Add($lstTasks)
Enable-GuiListViewSkin -List $lstTasks

$txtTaskDetail             = New-Object System.Windows.Forms.TextBox
$txtTaskDetail.Location    = New-Object System.Drawing.Point(0, 400)
$txtTaskDetail.Multiline   = $true
$txtTaskDetail.ReadOnly    = $true
$txtTaskDetail.ScrollBars  = 'Vertical'
$txtTaskDetail.BackColor   = $Pal.Sunken
$txtTaskDetail.ForeColor   = $Pal.Text
$txtTaskDetail.BorderStyle = 'FixedSingle'
$txtTaskDetail.Font        = New-Object System.Drawing.Font('Consolas', 9)
$txtTaskDetail.Anchor      = 'Top,Bottom,Left,Right'
$pageTasks.Controls.Add($txtTaskDetail)

# 写回脚本作用域：布局函数、任务渲染/通知函数以及本页事件绑定都要用这些控件
$script:hdrTasks      = $hdrTasks
$script:lblTasksDesc  = $lblTasksDesc
$script:pillTaskSum   = $pillTaskSum
$script:btnTaskNotify = $btnTaskNotify
$script:btnTaskAdv    = $btnTaskAdv
$script:pnlTaskFilter = $pnlTaskFilter
$script:cmbTaskStatus = $cmbTaskStatus
$script:cmbTaskSince  = $cmbTaskSince
$script:txtTaskKeyword = $txtTaskKeyword
$script:pnlTaskButtons = $pnlTaskButtons
$script:btnTaskRefresh = $btnTaskRefresh
$script:btnTaskRetry   = $btnTaskRetry
$script:btnTaskCancel  = $btnTaskCancel
$script:btnTaskLog     = $btnTaskLog
$script:lstTasks      = $lstTasks
$script:txtTaskDetail = $txtTaskDetail
Bind-TasksEvents
}
$script:PageBuilders['tasks'] = 'Build-TasksPage'

# ---- 结构审计页 ----

$pageAudit             = New-Object System.Windows.Forms.Panel
$pageAudit.Dock        = 'Fill'
$pageAudit.BackColor   = $Pal.Bg
$script:Pages['audit'] = $pageAudit
$pnlContent.Controls.Add($pageAudit)

# 结构审计页控件按需构建（首次显示本页时执行）：页头、筛选行、列表与详情
function Build-AuditPage {
$hdrAudit = New-PageHeader -Title '结构审计' -Subtitle '提交、执行、配置备份与恢复全在这里留痕；审计只追加、不修改，可按级别/时间/关键词筛选后导出。' -Icon 'audit' -Width 900
$pageAudit.Controls.Add($hdrAudit)
$lblAuditHead = $hdrAudit.Tag.Title
$lblAuditDesc = $hdrAudit.Tag.Sub

$pillAuditSum = New-Pill -Text '待查询' -Kind 'Neutral'
$pillAuditSum.Anchor = 'Top,Right'
$pillAuditSum.Location = New-Object System.Drawing.Point(816, 11)
$hdrAudit.Controls.Add($pillAuditSum)

$pnlAuditFilter             = New-Object System.Windows.Forms.TableLayoutPanel
$pnlAuditFilter.Location    = New-Object System.Drawing.Point(0, 56)
$pnlAuditFilter.BackColor   = $Pal.Bg
$pnlAuditFilter.ColumnCount = 4
$pnlAuditFilter.RowCount    = 2
$pnlAuditFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110))) | Out-Null
$pnlAuditFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110))) | Out-Null
$pnlAuditFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$pnlAuditFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 176))) | Out-Null
$pnlAuditFilter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 18))) | Out-Null
$pnlAuditFilter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
$pageAudit.Controls.Add($pnlAuditFilter)

foreach ($spec in @(@{ C = 0; T = '级别' }, @{ C = 1; T = '时间范围' }, @{ C = 2; T = '关键词' })) {
    $l = New-Label -Text $spec.T -Size 8.5 -Color Hint
    $l.Dock = 'Fill'
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $pnlAuditFilter.Controls.Add($l, $spec.C, 0)
}

$cmbAuditLevel              = New-Object System.Windows.Forms.ComboBox
$cmbAuditLevel.Dock         = 'Fill'
$cmbAuditLevel.DropDownStyle = 'DropDownList'
$cmbAuditLevel.FlatStyle    = 'Flat'
$cmbAuditLevel.BackColor    = $Pal.Sunken
$cmbAuditLevel.ForeColor    = $Pal.Text
$cmbAuditLevel.Font         = New-Font -Size 9
$cmbAuditLevel.Margin       = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
foreach ($x in @('全部', '成功', '信息', '警告', '错误')) { [void]$cmbAuditLevel.Items.Add($x) }
$cmbAuditLevel.SelectedIndex = 0
$pnlAuditFilter.Controls.Add($cmbAuditLevel, 0, 1)

$cmbAuditSince               = New-Object System.Windows.Forms.ComboBox
$cmbAuditSince.Dock          = 'Fill'
$cmbAuditSince.DropDownStyle = 'DropDownList'
$cmbAuditSince.FlatStyle     = 'Flat'
$cmbAuditSince.BackColor     = $Pal.Sunken
$cmbAuditSince.ForeColor     = $Pal.Text
$cmbAuditSince.Font          = New-Font -Size 9
$cmbAuditSince.Margin        = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
foreach ($x in @('今天', '7 天', '30 天', '全部')) { [void]$cmbAuditSince.Items.Add($x) }
$cmbAuditSince.SelectedIndex = 1
$pnlAuditFilter.Controls.Add($cmbAuditSince, 1, 1)

$txtAuditKeyword             = New-Object System.Windows.Forms.TextBox
$txtAuditKeyword.Dock        = 'Fill'
$txtAuditKeyword.BackColor   = $Pal.Sunken
$txtAuditKeyword.ForeColor   = $Pal.Text
$txtAuditKeyword.BorderStyle = 'FixedSingle'
$txtAuditKeyword.Font        = New-Font -Size 9
$txtAuditKeyword.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$pnlAuditFilter.Controls.Add($txtAuditKeyword, 2, 1)

$pnlAuditButtons             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlAuditButtons.Dock        = 'Fill'
$pnlAuditButtons.FlowDirection = 'LeftToRight'
$pnlAuditButtons.WrapContents = $false
$pnlAuditButtons.BackColor   = $Pal.Bg
$pnlAuditButtons.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
$btnAuditRefresh = New-FlatButton -Text '刷新' -Width 72 -Height 30 -Kind Primary
$btnAuditExport  = New-FlatButton -Text '导出' -Width 88 -Height 30
foreach ($b in @($btnAuditRefresh, $btnAuditExport)) {
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
    $pnlAuditButtons.Controls.Add($b)
}
$pnlAuditFilter.Controls.Add($pnlAuditButtons, 3, 1)
$pnlAuditFilter.SetRowSpan($pnlAuditButtons, 2)

$lstAudit                 = New-Object System.Windows.Forms.ListView
$lstAudit.Location        = New-Object System.Drawing.Point(0, 150)
$lstAudit.View            = 'Details'
$lstAudit.FullRowSelect   = $true
$lstAudit.HideSelection   = $false
$lstAudit.MultiSelect     = $false
$lstAudit.GridLines       = $false
$lstAudit.BorderStyle     = 'None'
$lstAudit.BackColor       = $Pal.Card
$lstAudit.ForeColor       = $Pal.Text
$lstAudit.Font            = New-Font -Size 9
$lstAudit.Anchor          = 'Top,Left,Right'
[void]$lstAudit.Columns.Add('时间', 126)
[void]$lstAudit.Columns.Add('事件', 84)
[void]$lstAudit.Columns.Add('级别', 52)
[void]$lstAudit.Columns.Add('动作', 120)
[void]$lstAudit.Columns.Add('任务编号', 150)
[void]$lstAudit.Columns.Add('详情', 380)
$pageAudit.Controls.Add($lstAudit)
Enable-GuiListViewSkin -List $lstAudit

$txtAuditDetail             = New-Object System.Windows.Forms.TextBox
$txtAuditDetail.Location    = New-Object System.Drawing.Point(0, 400)
$txtAuditDetail.Multiline   = $true
$txtAuditDetail.ReadOnly    = $true
$txtAuditDetail.ScrollBars  = 'Vertical'
$txtAuditDetail.BackColor   = $Pal.Sunken
$txtAuditDetail.ForeColor   = $Pal.Text
$txtAuditDetail.BorderStyle = 'FixedSingle'
$txtAuditDetail.Font        = New-Object System.Drawing.Font('Consolas', 9)
$txtAuditDetail.Anchor      = 'Top,Bottom,Left,Right'
$pageAudit.Controls.Add($txtAuditDetail)

# 写回脚本作用域：布局函数、Show-AuditList/Update-AuditChrome 以及本页事件绑定都要用这些控件
$script:hdrAudit        = $hdrAudit
$script:lblAuditDesc    = $lblAuditDesc
$script:pillAuditSum    = $pillAuditSum
$script:pnlAuditFilter  = $pnlAuditFilter
$script:cmbAuditLevel   = $cmbAuditLevel
$script:cmbAuditSince   = $cmbAuditSince
$script:txtAuditKeyword = $txtAuditKeyword
$script:pnlAuditButtons = $pnlAuditButtons
$script:btnAuditRefresh = $btnAuditRefresh
$script:btnAuditExport  = $btnAuditExport
$script:lstAudit        = $lstAudit
$script:txtAuditDetail  = $txtAuditDetail
Bind-AuditEvents
}
$script:PageBuilders['audit'] = 'Build-AuditPage'

# ============================ 远程主机 ============================
# 主机清单、连通性测试、批量命令、TrustedHosts。凭据只在 GUI 进程内经 DPAPI 落盘，
# 密码不进参数文件、不进日志、不进任务记录；测试/批量分别走查询子进程和动作 runner。

$script:HostItems            = @()
$script:HostTags             = @()
$script:HostTrusted          = @()
$script:HostTrustedError     = ''
$script:HostRefreshPending   = $false
$script:HostTagLoading       = $false
$script:HostLastInfo         = ''
$script:HostBatch            = $null
$script:HostBatchJobId       = ''
$script:HostBatchBusy        = $false
$script:HostBatchPendingWatch = $false

$pageHosts             = New-Object System.Windows.Forms.Panel
$pageHosts.Dock        = 'Fill'
$pageHosts.BackColor   = $Pal.Bg
$script:Pages['hosts'] = $pageHosts
$pnlContent.Controls.Add($pageHosts)

# 远程主机页控件按需构建（首次显示本页时执行）：页头、筛选行、工具行、列表与详情
function Build-HostsPage {
$hdrHosts = New-PageHeader -Title '远程主机' -Subtitle '维护 WinRM 主机清单、测试连通性、对多台主机批量执行 PowerShell 命令；保存的凭据用 DPAPI 加密在本机，测试与批量都不占用界面线程。' -Icon 'hosts' -Width 900
$pageHosts.Controls.Add($hdrHosts)
$lblHostsHead = $hdrHosts.Tag.Title
$lblHostsDesc = $hdrHosts.Tag.Sub

$pillHostSum = New-Pill -Text '待查询' -Kind 'Neutral'
$pillHostSum.Anchor = 'Top,Right'
$pillHostSum.Location = New-Object System.Drawing.Point(816, 11)
$hdrHosts.Controls.Add($pillHostSum)

$pnlHostFilter             = New-Object System.Windows.Forms.TableLayoutPanel
$pnlHostFilter.Location    = New-Object System.Drawing.Point(0, 56)
$pnlHostFilter.BackColor   = $Pal.Bg
$pnlHostFilter.ColumnCount = 3
$pnlHostFilter.RowCount    = 2
$pnlHostFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$pnlHostFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150))) | Out-Null
$pnlHostFilter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 372))) | Out-Null
$pnlHostFilter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 18))) | Out-Null
$pnlHostFilter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
$pageHosts.Controls.Add($pnlHostFilter)

foreach ($spec in @(@{ C = 0; T = '关键词（名称/地址/备注）' }, @{ C = 1; T = '标签' }, @{ C = 2; T = '操作' })) {
    $l = New-Label -Text $spec.T -Size 8.5 -Color Hint
    $l.Dock = 'Fill'
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $pnlHostFilter.Controls.Add($l, $spec.C, 0)
}

$txtHostKeyword             = New-Object System.Windows.Forms.TextBox
$txtHostKeyword.Dock        = 'Fill'
$txtHostKeyword.BackColor   = $Pal.Sunken
$txtHostKeyword.ForeColor   = $Pal.Text
$txtHostKeyword.BorderStyle = 'FixedSingle'
$txtHostKeyword.Font        = New-Font -Size 9
$txtHostKeyword.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$pnlHostFilter.Controls.Add($txtHostKeyword, 0, 1)

$cmbHostTag                  = New-Object System.Windows.Forms.ComboBox
$cmbHostTag.Dock             = 'Fill'
$cmbHostTag.DropDownStyle    = 'DropDownList'
$cmbHostTag.FlatStyle        = 'Flat'
$cmbHostTag.BackColor        = $Pal.Sunken
$cmbHostTag.ForeColor        = $Pal.Text
$cmbHostTag.Font             = New-Font -Size 9
$cmbHostTag.Margin           = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
[void]$cmbHostTag.Items.Add('全部标签')
$cmbHostTag.SelectedIndex = 0
$pnlHostFilter.Controls.Add($cmbHostTag, 1, 1)

$pnlHostButtons             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlHostButtons.Dock        = 'Fill'
$pnlHostButtons.FlowDirection = 'LeftToRight'
$pnlHostButtons.WrapContents = $false
$pnlHostButtons.BackColor   = $Pal.Bg
$pnlHostButtons.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
$btnHostRefresh = New-FlatButton -Text '刷新' -Width 72 -Height 30 -Kind Primary
$btnHostTest    = New-FlatButton -Text '测试连接' -Width 88 -Height 30
$btnHostBatch   = New-FlatButton -Text '批量命令' -Width 96 -Height 30
$btnHostTrust   = New-FlatButton -Text '信任设置' -Width 88 -Height 30
foreach ($b in @($btnHostRefresh, $btnHostTest, $btnHostBatch, $btnHostTrust)) {
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
    $pnlHostButtons.Controls.Add($b)
}
$pnlHostFilter.Controls.Add($pnlHostButtons, 2, 1)
$pnlHostFilter.SetRowSpan($pnlHostButtons, 2)

$pnlHostBar             = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlHostBar.Location    = New-Object System.Drawing.Point(0, 118)
$pnlHostBar.FlowDirection = 'LeftToRight'
$pnlHostBar.WrapContents = $false
$pnlHostBar.BackColor   = $Pal.Bg
$btnHostAdd    = New-FlatButton -Text '添加' -Width 72 -Height 30
$btnHostEdit   = New-FlatButton -Text '编辑' -Width 72 -Height 30
$btnHostDelete = New-FlatButton -Text '删除' -Width 72 -Height 30 -Kind Danger
foreach ($b in @($btnHostAdd, $btnHostEdit, $btnHostDelete)) {
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
    $pnlHostBar.Controls.Add($b)
}
$lblHostHint = New-Label -Text '批量命令会进入任务中心；保存凭据用当前用户的 DPAPI，换用户/换机器无法解密。' -Size 8.5 -Color Hint
$lblHostHint.Margin = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
$pnlHostBar.Controls.Add($lblHostHint)
$pageHosts.Controls.Add($pnlHostBar)

$lstHosts                 = New-Object System.Windows.Forms.ListView
$lstHosts.Location        = New-Object System.Drawing.Point(0, 158)
$lstHosts.View            = 'Details'
$lstHosts.FullRowSelect   = $true
$lstHosts.HideSelection   = $false
$lstHosts.MultiSelect     = $true
$lstHosts.GridLines       = $false
$lstHosts.BorderStyle     = 'None'
$lstHosts.BackColor       = $Pal.Card
$lstHosts.ForeColor       = $Pal.Text
$lstHosts.Font            = New-Font -Size 9
$lstHosts.Anchor          = 'Top,Left,Right'
[void]$lstHosts.Columns.Add('名称', 150)
[void]$lstHosts.Columns.Add('地址', 150)
[void]$lstHosts.Columns.Add('端口', 56)
[void]$lstHosts.Columns.Add('协议', 60)
[void]$lstHosts.Columns.Add('认证', 76)
[void]$lstHosts.Columns.Add('凭据', 56)
[void]$lstHosts.Columns.Add('标签', 110)
[void]$lstHosts.Columns.Add('最近测试', 126)
[void]$lstHosts.Columns.Add('状态', 60)
[void]$lstHosts.Columns.Add('备注', 200)
$pageHosts.Controls.Add($lstHosts)
Enable-GuiListViewSkin -List $lstHosts

$txtHostDetail             = New-Object System.Windows.Forms.TextBox
$txtHostDetail.Location    = New-Object System.Drawing.Point(0, 400)
$txtHostDetail.Multiline   = $true
$txtHostDetail.ReadOnly    = $true
$txtHostDetail.ScrollBars  = 'Vertical'
$txtHostDetail.BackColor   = $Pal.Sunken
$txtHostDetail.ForeColor   = $Pal.Text
$txtHostDetail.BorderStyle = 'FixedSingle'
$txtHostDetail.Font        = New-Object System.Drawing.Font('Consolas', 9)
$txtHostDetail.Anchor      = 'Top,Bottom,Left,Right'
$pageHosts.Controls.Add($txtHostDetail)

$txtHostDetail.Text = '选择一台主机查看详情；「添加」新建，「编辑」修改，选中两台以上可用「批量命令」一次下发。'

# 写回脚本作用域：布局函数、Show-HostsList/Update-HostsSummary 以及本页事件绑定都要用这些控件
$script:hdrHosts       = $hdrHosts
$script:lblHostsDesc   = $lblHostsDesc
$script:pillHostSum    = $pillHostSum
$script:pnlHostFilter  = $pnlHostFilter
$script:txtHostKeyword = $txtHostKeyword
$script:cmbHostTag     = $cmbHostTag
$script:pnlHostButtons = $pnlHostButtons
$script:btnHostRefresh = $btnHostRefresh
$script:btnHostTest    = $btnHostTest
$script:btnHostBatch   = $btnHostBatch
$script:btnHostTrust   = $btnHostTrust
$script:pnlHostBar     = $pnlHostBar
$script:btnHostAdd     = $btnHostAdd
$script:btnHostEdit    = $btnHostEdit
$script:btnHostDelete  = $btnHostDelete
$script:lblHostHint    = $lblHostHint
$script:lstHosts       = $lstHosts
$script:txtHostDetail  = $txtHostDetail
Bind-HostsEvents
}
$script:PageBuilders['hosts'] = 'Build-HostsPage'

function Get-HostTestStatusText {
    param([string]$Status)
    switch ([string]$Status) {
        'OK'     { return '正常' }
        'Failed' { return '失败' }
        default  { return '未测试' }
    }
}

function Get-HostAuthText {
    param([string]$Auth)
    if ([string]$Auth -eq 'Credential') { return '保存凭据' }
    return '当前用户'
}

function Get-HostRemoteStatusText {
    param([string]$Status)
    switch ([string]$Status) {
        'Succeeded' { return '成功' }
        'Failed'    { return '失败' }
        'Skipped'   { return '已跳过' }
        default     { return [string]$Status }
    }
}

function Format-HostDetail {
    param($Item)
    if (-not $Item) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('名称：' + [string]$Item.Name)
    [void]$sb.AppendLine(('地址：{0}:{1}（{2}）' -f [string]$Item.Address, [int]$Item.Port, ([string]$Item.Protocol).ToUpper()))
    [void]$sb.AppendLine('认证：' + (Get-HostAuthText ([string]$Item.Auth)) + '    凭据：' + $(if ([bool]$Item.HasCredential) { '已保存（用户名不回显）' } else { '未保存' }))
    $tags = @($Item.Tags)
    [void]$sb.AppendLine('标签：' + $(if ($tags.Count -gt 0) { $tags -join '、' } else { '（无）' }))
    [void]$sb.AppendLine('启用：' + $(if ([bool]$Item.Enabled) { '是' } else { '否' }) + '    创建：' + (Format-GuiTaskTime ([string]$Item.CreatedAt)))
    $st = [string]$Item.LastTestStatus
    [void]$sb.AppendLine(('最近测试：{0}  {1}' -f (Format-GuiTaskTime ([string]$Item.LastTestAt)), (Get-HostTestStatusText $st)))
    if ([string]$Item.LastTestMessage) { [void]$sb.AppendLine('  ' + [string]$Item.LastTestMessage) }
    if ([string]$Item.Notes) {
        [void]$sb.AppendLine(('-' * 60))
        [void]$sb.AppendLine([string]$Item.Notes)
    }
    return $sb.ToString()
}

function Format-HostTestSummary {
    param($Data)
    if (-not $Data) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('连通性测试：{0} 台，成功 {1}，失败 {2}' -f [int]$Data.Total, [int]$Data.Ok, [int]$Data.Failed))
    [void]$sb.AppendLine(('-' * 72))
    foreach ($r in @($Data.Results)) {
        $mark = '[未测]'
        if ([string]$r.Status -eq 'OK') { $mark = '[ OK ]' }
        elseif ([string]$r.Status -eq 'Failed') { $mark = '[FAIL]' }
        [void]$sb.AppendLine(('{0} {1}（{2}） {3} 秒' -f $mark, [string]$r.Name, [string]$r.Address, [double]$r.DurationSec))
        if ([string]$r.Detail) { [void]$sb.AppendLine('       ' + [string]$r.Detail) }
    }
    return $sb.ToString()
}

function Format-HostBatchSummary {
    param($Batch)
    if (-not $Batch) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('批量任务：' + [string]$Batch.TaskId)
    [void]$sb.AppendLine(('开始：{0}    结束：{1}' -f (Format-GuiTaskTime ([string]$Batch.StartedAt)), (Format-GuiTaskTime ([string]$Batch.EndedAt))))
    $cmd = ([string]$Batch.Command) -replace "`r?`n", ' ; '
    if ($cmd.Length -gt 200) { $cmd = $cmd.Substring(0, 200) + '…' }
    [void]$sb.AppendLine('命令：' + $cmd)
    [void]$sb.AppendLine(('主机 {0} 台：成功 {1}、失败 {2}、跳过 {3}' -f [int]$Batch.Total, [int]$Batch.Succeeded, [int]$Batch.Failed, [int]$Batch.Skipped))
    [void]$sb.AppendLine(('-' * 72))
    foreach ($r in @($Batch.Results)) {
        [void]$sb.AppendLine(('[{0}] {1}（{2}） {3} 秒' -f (Get-HostRemoteStatusText ([string]$r.Status)), [string]$r.Name, [string]$r.Address, [double]$r.DurationSec))
        if ([string]$r.Output) {
            $first = (([string]$r.Output -split "`r?`n") | Select-Object -First 4) -join ' | '
            [void]$sb.AppendLine('       ' + $first)
        }
        if ([string]$r.Error) { [void]$sb.AppendLine('       错误：' + [string]$r.Error) }
    }
    return $sb.ToString()
}

function Update-HostTagCombo {
    $keep = ''
    if ($cmbHostTag.SelectedIndex -gt 0) { $keep = [string]$cmbHostTag.SelectedItem }
    $script:HostTagLoading = $true
    try {
        $cmbHostTag.BeginUpdate()
        try {
            $cmbHostTag.Items.Clear()
            [void]$cmbHostTag.Items.Add('全部标签')
            $all = New-Object System.Collections.ArrayList
            $seen = @{}
            foreach ($h in @($script:HostItems)) {
                foreach ($t in @($h.Tags)) {
                    $s = [string]$t
                    if (-not $s) { continue }
                    $k = $s.ToLowerInvariant()
                    if ($seen.ContainsKey($k)) { continue }
                    $seen[$k] = $true
                    [void]$all.Add($s)
                }
            }
            foreach ($t in @($all.ToArray() | Sort-Object)) { [void]$cmbHostTag.Items.Add($t) }
        } finally { $cmbHostTag.EndUpdate() }
        $idx = 0
        if ($keep) {
            for ($i = 0; $i -lt $cmbHostTag.Items.Count; $i++) {
                if ([string]$cmbHostTag.Items[$i] -eq $keep) { $idx = $i; break }
            }
        }
        $cmbHostTag.SelectedIndex = $idx
    } finally { $script:HostTagLoading = $false }
}

function Show-HostsList {
    $kw  = $txtHostKeyword.Text.Trim()
    $tag = ''
    if ($cmbHostTag.SelectedIndex -gt 0) { $tag = [string]$cmbHostTag.SelectedItem }
    $lstHosts.BeginUpdate()
    try {
        $lstHosts.Items.Clear()
        foreach ($h in @($script:HostItems)) {
            if ($kw) {
                $hay = ('{0} {1} {2} {3}' -f [string]$h.Name, [string]$h.Address, [string]$h.Notes, (@($h.Tags) -join ' '))
                if ($hay -notmatch [regex]::Escape($kw)) { continue }
            }
            if ($tag) {
                $tags = @($h.Tags)
                if (-not ($tags -contains $tag)) { continue }
            }
            $li = New-Object System.Windows.Forms.ListViewItem([string]$h.Name)
            [void]$li.SubItems.Add([string]$h.Address)
            [void]$li.SubItems.Add([string]$h.Port)
            [void]$li.SubItems.Add(([string]$h.Protocol).ToUpper())
            [void]$li.SubItems.Add((Get-HostAuthText ([string]$h.Auth)))
            [void]$li.SubItems.Add($(if ([bool]$h.HasCredential) { '有' } else { '无' }))
            $tags = @($h.Tags)
            [void]$li.SubItems.Add($(if ($tags.Count -gt 0) { $tags -join '、' } else { '' }))
            [void]$li.SubItems.Add((Format-GuiTaskTime ([string]$h.LastTestAt)))
            [void]$li.SubItems.Add((Get-HostTestStatusText ([string]$h.LastTestStatus)))
            [void]$li.SubItems.Add((([string]$h.Notes) -replace "`r?`n", ' '))
            $li.Tag = $h
            if (-not [bool]$h.Enabled) { $li.ForeColor = $Pal.Hint }
            elseif ([string]$h.LastTestStatus -eq 'Failed') { $li.ForeColor = $Pal.Err }
            elseif ([string]$h.LastTestStatus -eq 'OK') { $li.ForeColor = $Pal.Text }
            else { $li.ForeColor = $Pal.Text }
            [void]$lstHosts.Items.Add($li)
        }
    } finally { $lstHosts.EndUpdate() }
}

function Update-HostsSummary {
    $total   = @($script:HostItems).Count
    $enabled = @($script:HostItems | Where-Object { [bool]$_.Enabled }).Count
    $failed  = @($script:HostItems | Where-Object { [string]$_.LastTestStatus -eq 'Failed' }).Count
    if ($total -eq 0) {
        Set-Pill -Pill $pillHostSum -Text '0 台' -Kind 'Neutral'
    } elseif ($failed -gt 0) {
        Set-Pill -Pill $pillHostSum -Text ('{0} 台 · 启用 {1} · 失败 {2}' -f $total, $enabled, $failed) -Kind 'Warn'
    } else {
        Set-Pill -Pill $pillHostSum -Text ('{0} 台 · 启用 {1}' -f $total, $enabled) -Kind $(if ($enabled -gt 0) { 'Success' } else { 'Neutral' })
    }
    Update-HostsChrome
}

function Update-HostsChrome {
    try {
        $hw = [Math]::Max(240, $hdrHosts.Parent.ClientSize.Width)
        $pillHostSum.Left = [Math]::Max(0, ($hw - $pillHostSum.Width - 8))
        if ($hdrHosts.Tag -and $hdrHosts.Tag.Sub) {
            $hdrHosts.Tag.Sub.Width = [Math]::Max(80, ($pillHostSum.Left - [int]$hdrHosts.Tag.GapX - 12))
        }
    } catch { }
}

function Start-HostsQuery {
    if ($SkipPageHooks -or -not $script:QHosts) { return }
    if ($script:QHosts.Task) { $script:HostRefreshPending = $true; return }
    [void](Start-GuiQueryHost -Query $script:QHosts -Task 'hosts' -BusyText '读取主机清单…')
}

function Start-HostsTest {
    if ($SkipPageHooks -or $script:AuditMode) { return }
    if ($script:QHosts.Task) { Append-GuiLog -Line '[WARN] 主机查询还在跑，等它结束再测试。'; return }
    $ids = New-Object System.Collections.ArrayList
    foreach ($li in @($lstHosts.SelectedItems)) { [void]$ids.Add([string]$li.Tag.Id) }
    if ($ids.Count -eq 0) {
        foreach ($h in @($script:HostItems)) { if ([bool]$h.Enabled) { [void]$ids.Add([string]$h.Id) } }
    }
    if ($ids.Count -eq 0) {
        Append-GuiLog -Line '[WARN] 没有可测试的主机；先在清单里添加并启用主机。'
        return
    }
    Set-Pill -Pill $pillHostSum -Text ('测试 {0} 台主机…' -f $ids.Count) -Kind 'Info'
    $p = @{ Hosts = ($ids.ToArray() -join ','); TimeoutSec = 60 }
    [void](Start-GuiQueryHost -Query $script:QHosts -Task 'test' -ArgsJson $p -BusyText ('测试 {0} 台主机…' -f $ids.Count))
}

function Complete-HostPendingWatch {
    if ($script:HostBatchPendingWatch -and -not $script:QHosts.Task) {
        $script:HostBatchPendingWatch = $false
        Start-GuiQueryWatch -Query $script:QHosts
    }
}

function Receive-HostsResult {
    param($Obj)
    if ($null -eq $Obj) {
        if ($script:HostBatchBusy) {
            $taskId = [string]$script:HostBatchJobId
            if (-not $taskId) {
                $script:HostBatchBusy = $false
                Set-Pill -Pill $pillHostSum -Text '批量任务编号丢失' -Kind 'Danger'
                return
            }
            $ok = Start-GuiQueryHost -Query $script:QHosts -Task 'batch' -ArgsJson @{ TaskId = $taskId } -BusyText '读取批量结果…'
            if (-not $ok) { $script:HostBatchBusy = $false }
            return
        }
        if ($script:HostRefreshPending) {
            $script:HostRefreshPending = $false
            Start-HostsQuery
        }
        return
    }
    if ([string]$Obj.Error) {
        $script:HostBatchBusy = $false
        Set-Pill -Pill $pillHostSum -Text '读取失败' -Kind 'Danger'
        $txtHostDetail.Text = [string]$Obj.Error
        Append-GuiLog -Line ('[WARN] 主机查询失败：' + [string]$Obj.Error)
        Update-HostsChrome
        if ($script:HostRefreshPending) { $script:HostRefreshPending = $false; Start-HostsQuery }
        return
    }
    if ($Obj.Mode -eq 'hosts') {
        $data = $Obj.Data
        $script:HostItems        = @($data.Items)
        $script:HostTrusted      = @($data.TrustedHosts)
        $script:HostTrustedError = [string]$data.TrustedError
        Update-HostTagCombo
        Show-HostsList
        Update-HostsSummary
        if ($lstHosts.SelectedItems.Count -eq 0 -and -not $script:HostBatchBusy -and $script:HostLastInfo) {
            $txtHostDetail.Text = $script:HostLastInfo
        }
        if ($script:HostRefreshPending) {
            $script:HostRefreshPending = $false
            Start-HostsQuery
            return
        }
        Complete-HostPendingWatch
    } elseif ($Obj.Mode -eq 'test') {
        $data = $Obj.Data
        $script:HostLastInfo = Format-HostTestSummary -Data $data
        $txtHostDetail.Text = $script:HostLastInfo
        Set-Pill -Pill $pillHostSum -Text ('测试 {0} 台：成功 {1} / 失败 {2}' -f [int]$data.Total, [int]$data.Ok, [int]$data.Failed) `
            -Kind $(if ([int]$data.Failed -gt 0) { 'Warn' } else { 'Success' })
        foreach ($r in @($data.Results)) {
            if ([string]$r.Status -eq 'OK') {
                Append-GuiLog -Line ('[OK] {0}（{1}）：{2}' -f [string]$r.Name, [string]$r.Address, [string]$r.Detail)
            } else {
                Append-GuiLog -Line ('[WARN] {0}（{1}）：{2}' -f [string]$r.Name, [string]$r.Address, [string]$r.Detail)
            }
        }
        Update-HostsChrome
        Start-HostsQuery
    } elseif ($Obj.Mode -eq 'batch') {
        $b = $Obj.Data
        $script:HostBatch = $b
        $script:HostBatchBusy = $false
        $script:HostLastInfo = Format-HostBatchSummary -Batch $b
        $txtHostDetail.Text = $script:HostLastInfo
        Set-Pill -Pill $pillHostSum -Text ('批量 {0} 台：成功 {1} / 失败 {2}' -f [int]$b.Total, [int]$b.Succeeded, [int]$b.Failed) `
            -Kind $(if ([int]$b.Failed -gt 0 -or [int]$b.Skipped -gt 0) { 'Warn' } else { 'Success' })
        Append-GuiLog -Line ('[OK] 批量结果已写入 ' + (Get-GuiReadyRemoteBatchFile -TaskId ([string]$b.TaskId)))
        foreach ($r in @($b.Results)) {
            $lvl = 'INFO'
            if ([string]$r.Status -eq 'Failed') { $lvl = 'ERROR' }
            elseif ([string]$r.Status -eq 'Skipped') { $lvl = 'WARN' }
            Append-GuiLog -Line ('[{0}] {1}（{2}） {3} 秒' -f (Get-HostRemoteStatusText ([string]$r.Status)), [string]$r.Name, [string]$r.Address, [double]$r.DurationSec) $lvl
        }
        Update-HostsChrome
        if ($script:HostRefreshPending) { $script:HostRefreshPending = $false; Start-HostsQuery }
    }
}

function Show-HostsPage {
    if ($SkipPageHooks) { return }
    Update-HostsChrome
    if ($script:HostItems.Count -eq 0) { Start-HostsQuery }
    elseif (-not $script:QHosts.Task) { Start-HostsQuery }
    else { $script:HostRefreshPending = $true }
}

$script:QHosts = New-GuiQueryHost -Name 'hosts' -Runner (Join-Path $guiDir 'Run-GuiReadyRemote.ps1') -TimeoutSec 240 `
    -OnResult { param($obj) Receive-HostsResult -Obj $obj } `
    -OnBusyStart { param($t) Set-Pill -Pill $pillHostSum -Text $t -Kind 'Info'; Update-HostsChrome } `
    -OnBusyEnd { }

function New-HostFormLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 100)
    $l = New-Label -Text $Text -Size 9 -Color Text
    $l.AutoSize = $false
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, 22)
    $l.TextAlign = 'MiddleLeft'
    return $l
}

function New-HostFormInput {
    param([int]$X, [int]$Y, [int]$W, [int]$H = 24, [switch]$Multi)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location    = New-Object System.Drawing.Point($X, $Y)
    $t.Size        = New-Object System.Drawing.Size($W, $H)
    $t.BackColor   = $Pal.Sunken
    $t.ForeColor   = $Pal.Text
    $t.BorderStyle = 'FixedSingle'
    $t.Font        = New-Font -Size 9
    if ($Multi) {
        $t.Multiline  = $true
        $t.ScrollBars = 'Vertical'
        $t.Font       = New-Object System.Drawing.Font('Consolas', 9)
    }
    return $t
}

function New-HostFormCombo {
    param([int]$X, [int]$Y, [int]$W)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location      = New-Object System.Drawing.Point($X, $Y)
    $c.Size          = New-Object System.Drawing.Size($W, 24)
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle     = 'Flat'
    $c.BackColor     = $Pal.Sunken
    $c.ForeColor     = $Pal.Text
    $c.Font          = New-Font -Size 9
    return $c
}

function Show-HostEditDialog {
    # 参数名不能叫 Host：$Host 是 PowerShell 的只读自动变量（当前宿主对象），
    # 同名参数在 Show-HostEditDialog -Host ... 绑定时会直接抛「无法覆盖变量 Host」。
    param($Target = $null)
    if ($SkipPageHooks -or $script:AuditMode) { return }
    $editing = $Target

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = $(if ($editing) { '编辑主机' } else { '添加主机' })
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.ShowInTaskbar   = $false
    $dlg.BackColor       = $Pal.Bg
    $dlg.ForeColor       = $Pal.Text
    $dlg.Font            = New-Font -Size 9
    $dlg.ClientSize      = New-Object System.Drawing.Size(620, 560)
    try { $dlg.Owner = $form } catch { }

    $dlg.Controls.Add((New-HostFormLabel -Text '名称' -X 14 -Y 16))
    $txtName = New-HostFormInput -X 120 -Y 12 -W 470
    $dlg.Controls.Add($txtName)

    $dlg.Controls.Add((New-HostFormLabel -Text '地址（IP/主机名）' -X 14 -Y 50 -W 100))
    $txtAddr = New-HostFormInput -X 120 -Y 46 -W 340
    $dlg.Controls.Add($txtAddr)
    $dlg.Controls.Add((New-HostFormLabel -Text '端口' -X 470 -Y 50 -W 36))
    $txtPort = New-HostFormInput -X 510 -Y 46 -W 80
    $dlg.Controls.Add($txtPort)

    $dlg.Controls.Add((New-HostFormLabel -Text '协议' -X 14 -Y 84 -W 60))
    $cmbProto = New-HostFormCombo -X 120 -Y 80 -W 150
    foreach ($x in @('Http', 'Https')) { [void]$cmbProto.Items.Add($x) }
    $cmbProto.SelectedIndex = 0
    $dlg.Controls.Add($cmbProto)
    $dlg.Controls.Add((New-HostFormLabel -Text '认证' -X 300 -Y 84 -W 60))
    $cmbAuth = New-HostFormCombo -X 370 -Y 80 -W 220
    foreach ($x in @('当前用户（Negotiate）', '保存的凭据')) { [void]$cmbAuth.Items.Add($x) }
    $cmbAuth.SelectedIndex = 0
    $dlg.Controls.Add($cmbAuth)

    $lblCredState = New-HostFormLabel -Text '' -X 14 -Y 114 -W 580
    $dlg.Controls.Add($lblCredState)

    $dlg.Controls.Add((New-HostFormLabel -Text '用户名' -X 14 -Y 148 -W 100))
    $txtUser = New-HostFormInput -X 120 -Y 144 -W 220
    $dlg.Controls.Add($txtUser)
    $dlg.Controls.Add((New-HostFormLabel -Text '密码' -X 360 -Y 148 -W 50))
    $txtPass = New-HostFormInput -X 420 -Y 144 -W 170
    $txtPass.UseSystemPasswordChar = $true
    $dlg.Controls.Add($txtPass)
    $chkClear = New-Object System.Windows.Forms.CheckBox
    $chkClear.Text     = '清除已保存的凭据'
    $chkClear.Location = New-Object System.Drawing.Point(120, 180)
    $chkClear.Size     = New-Object System.Drawing.Size(220, 24)
    $chkClear.ForeColor = $Pal.Text
    $dlg.Controls.Add($chkClear)

    $dlg.Controls.Add((New-HostFormLabel -Text '标签' -X 14 -Y 214 -W 100))
    $txtTags = New-HostFormInput -X 120 -Y 210 -W 470
    $dlg.Controls.Add($txtTags)
    $dlg.Controls.Add((New-HostFormLabel -Text '备注' -X 14 -Y 248 -W 100))
    $txtNotes = New-HostFormInput -X 120 -Y 244 -W 470 -H 78 -Multi
    $dlg.Controls.Add($txtNotes)

    $chkEnabled = New-Object System.Windows.Forms.CheckBox
    $chkEnabled.Text     = '启用（参与“全部主机”的批量与测试）'
    $chkEnabled.Location = New-Object System.Drawing.Point(120, 330)
    $chkEnabled.Size     = New-Object System.Drawing.Size(320, 24)
    $chkEnabled.ForeColor = $Pal.Text
    $chkEnabled.Checked  = $true
    $dlg.Controls.Add($chkEnabled)

    $chkUntrusted = New-Object System.Windows.Forms.CheckBox
    $chkUntrusted.Text     = '跳过证书校验（仅 HTTPS 自签证书时使用）'
    $chkUntrusted.Location = New-Object System.Drawing.Point(120, 358)
    $chkUntrusted.Size     = New-Object System.Drawing.Size(340, 24)
    $chkUntrusted.ForeColor = $Pal.Text
    $dlg.Controls.Add($chkUntrusted)

    $lblHint = New-HostFormLabel -Text '提示：当前用户认证走 Negotiate；工作组环境下的 HTTP 需要目标在 TrustedHosts。密码只在本机用 DPAPI 加密保存，不回显、不进日志。' -X 14 -Y 392 -W 590
    $lblHint.AutoSize = $false
    $lblHint.Height   = 54
    $dlg.Controls.Add($lblHint)

    $btnCancel = New-FlatButton -Text '取消' -Width 80 -Height 30
    $btnCancel.Location = New-Object System.Drawing.Point(416, 508)
    $dlg.Controls.Add($btnCancel)
    $btnSave = New-FlatButton -Text '保存' -Width 100 -Height 30 -Kind Primary
    $btnSave.Location = New-Object System.Drawing.Point(506, 508)
    $dlg.Controls.Add($btnSave)

    # 回填
    if ($editing) {
        $txtName.Text = [string]$editing.Name
        $txtAddr.Text = [string]$editing.Address
        $txtPort.Text = [string]$editing.Port
        $cmbProto.SelectedIndex = $(if ([string]$editing.Protocol -eq 'Https') { 1 } else { 0 })
        $cmbAuth.SelectedIndex  = $(if ([string]$editing.Auth -eq 'Credential') { 1 } else { 0 })
        $txtTags.Text  = (@($editing.Tags) -join '、')
        $txtNotes.Text = [string]$editing.Notes
        $chkEnabled.Checked   = [bool]$editing.Enabled
        $chkUntrusted.Checked = [bool]$editing.AllowUntrusted
        $lblCredState.Text = $(if ([bool]$editing.HasCredential) { '已保存凭据：是（用户名不回显；重新填写即覆盖）' } else { '已保存凭据：否' })
    } else {
        $txtPort.Text = '5985'
        $lblCredState.Text = '尚未保存凭据。'
    }

    $applyAuth = {
        $on = ($cmbAuth.SelectedIndex -eq 1)
        $txtUser.Enabled  = $on
        $txtPass.Enabled  = $on
        $chkClear.Enabled = ($on -and [bool]$editing)
        if (-not $on) {
            $txtUser.Text = ''
            $txtPass.Text = ''
            $chkClear.Checked = $false
        }
    }.GetNewClosure()
    $cmbAuth.Add_SelectedIndexChanged($applyAuth)

    $cmbProto.Add_SelectedIndexChanged({
        $p = 5985
        if ($cmbProto.SelectedIndex -eq 1) { $p = 5986 }
        if ($txtPort.Text -eq '5985' -or $txtPort.Text -eq '5986' -or -not $txtPort.Text.Trim()) { $txtPort.Text = [string]$p }
    }.GetNewClosure())

    & $applyAuth

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())
    $btnSave.Add_Click({
        try {
            $name = $txtName.Text.Trim()
            if (-not $name) { throw '主机名称不能为空。' }
            $addr = $txtAddr.Text.Trim()
            if (-not $addr) { throw '主机地址不能为空。' }
            $port = 0
            if (-not [int]::TryParse($txtPort.Text.Trim(), [ref]$port)) { throw '端口必须是数字（1-65535）。' }
            if ($port -lt 1 -or $port -gt 65535) { throw '端口必须在 1-65535 之间。' }
            $proto = [string]$cmbProto.SelectedItem
            $auth  = $(if ($cmbAuth.SelectedIndex -eq 1) { 'Credential' } else { 'Default' })
            $tags  = @(([string]$txtTags.Text -split '[,;，；、]') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $u = $txtUser.Text.Trim()
            $pw = $txtPass.Text
            if ([bool]$chkClear.Checked) { $pw = '' }
            $willClear = [bool]$chkClear.Checked
            $hasExisting = $false
            if ($editing -and [bool]$editing.HasCredential -and -not $willClear) { $hasExisting = $true }
            if ($auth -eq 'Credential' -and -not $hasExisting -and -not ($u -and $pw)) {
                throw '认证方式是“保存的凭据”，请填写用户名和密码。'
            }
            if (($u -and -not $pw) -or ($pw -and -not $u)) { throw '用户名和密码需要同时填写。' }

            $rec = $null
            if ($editing) {
                $rec = Set-GuiReadyHost -Id ([string]$editing.Id) -Name $name -Address $addr -Port $port `
                        -Protocol $proto -Auth $auth -AllowUntrusted ([bool]$chkUntrusted.Checked) `
                        -Tags $tags -Notes $txtNotes.Text -Enabled ([bool]$chkEnabled.Checked)
            } else {
                $rec = New-GuiReadyHost -Name $name -Address $addr -Port $port `
                        -Protocol $proto -Auth $auth -AllowUntrusted:([bool]$chkUntrusted.Checked) `
                        -Tags $tags -Notes $txtNotes.Text -Enabled ([bool]$chkEnabled.Checked)
            }
            if ($willClear) { [void](Remove-GuiReadyHostCredential -Id ([string]$rec.Id)) }
            if ($u -and $pw) {
                [void](Set-GuiReadyHostCredential -Id ([string]$rec.Id) -UserName $u -Password $pw)
            }
            $txtPass.Text = ''
            Append-GuiLog -Line ('[OK] 已保存主机：{0}（{1}:{2}，认证 {3}）' -f [string]$rec.Name, [string]$rec.Address, [int]$rec.Port, (Get-HostAuthText ([string]$rec.Auth)))
            $dlg.Close()
            Start-HostsQuery
        } catch {
            [System.Windows.Forms.MessageBox]::Show($dlg, $_.Exception.Message, '保存失败', 'OK', 'Warning') | Out-Null
        }
    }.GetNewClosure())

    [void]$dlg.ShowDialog($form)
}

function Remove-SelectedHost {
    if ($SkipPageHooks -or $script:AuditMode) { return }
    if ($lstHosts.SelectedItems.Count -eq 0) { Append-GuiLog -Line '[WARN] 先在列表里选一台主机。'; return }
    $h = $lstHosts.SelectedItems[0].Tag
    if (-not $h) { return }
    $r = [System.Windows.Forms.MessageBox]::Show($form,
        ('删除主机“{0}”（{1}:{2}）？该主机的已保存凭据也会一起删除。' -f [string]$h.Name, [string]$h.Address, [int]$h.Port),
        '确认删除', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    try {
        [void](Remove-GuiReadyHost -Id ([string]$h.Id))
        Append-GuiLog -Line ('[OK] 已删除主机：{0}（{1}）' -f [string]$h.Name, [string]$h.Address)
        $script:HostLastInfo = ''
        $txtHostDetail.Text = ''
        Start-HostsQuery
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '删除失败', 'OK', 'Warning') | Out-Null
    }
}

function Show-HostBatchDialog {
    if ($SkipPageHooks -or $script:AuditMode) { return }
    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show($form, '上一个动作还在运行，请先等它结束。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $enabled = @($script:HostItems | Where-Object { [bool]$_.Enabled })
    if ($enabled.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show($form, '主机清单里没有启用的主机，请先添加并启用。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $selIds = @{}
    foreach ($li in @($lstHosts.SelectedItems)) { $selIds[[string]$li.Tag.Id] = $true }

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = '批量执行命令'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.ShowInTaskbar   = $false
    $dlg.BackColor       = $Pal.Bg
    $dlg.ForeColor       = $Pal.Text
    $dlg.Font            = New-Font -Size 9
    $dlg.ClientSize      = New-Object System.Drawing.Size(640, 560)
    try { $dlg.Owner = $form } catch { }

    $lblTarget = New-HostFormLabel -Text '目标主机（仅列启用的；默认勾选列表里选中的主机）' -X 14 -Y 12 -W 600
    $dlg.Controls.Add($lblTarget)

    $chkHosts = New-Object System.Windows.Forms.CheckedListBox
    $chkHosts.Location        = New-Object System.Drawing.Point(14, 38)
    $chkHosts.Size            = New-Object System.Drawing.Size(600, 150)
    $chkHosts.CheckOnClick    = $true
    $chkHosts.BackColor       = $Pal.Sunken
    $chkHosts.ForeColor       = $Pal.Text
    $chkHosts.BorderStyle     = 'FixedSingle'
    $chkHosts.Font            = New-Font -Size 9
    for ($i = 0; $i -lt $enabled.Count; $i++) {
        $h = $enabled[$i]
        $checked = $true
        if ($selIds.Count -gt 0) { $checked = $selIds.ContainsKey([string]$h.Id) }
        [void]$chkHosts.Items.Add(('{0}  {1}:{2}' -f [string]$h.Name, [string]$h.Address, [int]$h.Port), $checked)
    }
    $dlg.Controls.Add($chkHosts)

    $dlg.Controls.Add((New-HostFormLabel -Text '命令（在每台主机上用 PowerShell 执行）' -X 14 -Y 198 -W 600))
    $txtCmd = New-HostFormInput -X 14 -Y 222 -W 600 -H 120 -Multi
    $txtCmd.Text = '$env:COMPUTERNAME'
    $dlg.Controls.Add($txtCmd)

    $dlg.Controls.Add((New-HostFormLabel -Text '每台超时（秒）' -X 14 -Y 354 -W 100))
    $txtTimeout = New-HostFormInput -X 120 -Y 350 -W 70
    $txtTimeout.Text = '120'
    $dlg.Controls.Add($txtTimeout)

    $chkContinue = New-Object System.Windows.Forms.CheckBox
    $chkContinue.Text     = '某台失败后继续执行其它主机'
    $chkContinue.Location = New-Object System.Drawing.Point(220, 350)
    $chkContinue.Size     = New-Object System.Drawing.Size(300, 24)
    $chkContinue.ForeColor = $Pal.Text
    $chkContinue.Checked  = $true
    $dlg.Controls.Add($chkContinue)

    $lblHint = New-HostFormLabel -Text '批量命令会作为任务进入任务中心，逐机结果写入 state\remote；关闭本窗口不会中断执行。输出按主机保留，单台失败不影响其它主机。' -X 14 -Y 386 -W 600
    $lblHint.Height = 54
    $dlg.Controls.Add($lblHint)

    $btnCancel = New-FlatButton -Text '取消' -Width 80 -Height 30
    $btnCancel.Location = New-Object System.Drawing.Point(436, 508)
    $dlg.Controls.Add($btnCancel)
    $btnRun = New-FlatButton -Text '运行' -Width 100 -Height 30 -Kind Primary
    $btnRun.Location = New-Object System.Drawing.Point(526, 508)
    $dlg.Controls.Add($btnRun)

    $btnCancel.Add_Click({ $dlg.Close() }.GetNewClosure())
    $btnRun.Add_Click({
        try {
            $picked = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $chkHosts.Items.Count; $i++) {
                if ($chkHosts.GetItemChecked($i)) { [void]$picked.Add([string]$enabled[$i].Id) }
            }
            if ($picked.Count -eq 0) { throw '至少勾选一台主机。' }
            $cmd = $txtCmd.Text.Trim()
            if (-not $cmd) { throw '命令不能为空。' }
            $tmo = 120
            if (-not [int]::TryParse($txtTimeout.Text.Trim(), [ref]$tmo)) { throw '超时必须是数字（10-1800 秒）。' }
            if ($tmo -lt 10) { $tmo = 10 }
            if ($tmo -gt 1800) { $tmo = 1800 }

            $a = @($script:Actions | Where-Object { [string]$_.Id -eq 'remote-run' })
            if ($a.Count -eq 0) { throw '动作清单里没有 remote-run，无法提交批量任务。' }
            Select-GuiAction -Action $a[0]
            Set-ParamValues -Values @{
                Hosts           = ($picked.ToArray() -join ';')
                Command         = $cmd
                TimeoutSec      = [string]$tmo
                ContinueOnError = [bool]$chkContinue.Checked
            }
            Start-GuiAction -DryRun $false
            if (-not $script:Proc) { throw '动作没有启动成功，请查看日志。' }

            $script:HostBatchJobId        = [string]$script:CurrentJobId
            $script:HostBatchBusy         = $true
            $script:HostBatch             = $null
            $script:HostBatchPendingWatch = $false
            $script:HostLastInfo          = ('批量任务已提交（{0} 台），等待执行结束…' -f $picked.Count)
            $txtHostDetail.Text           = $script:HostLastInfo
            Set-Pill -Pill $pillHostSum -Text '批量执行中…' -Kind 'Info'
            if ($script:QHosts.Task) { $script:HostBatchPendingWatch = $true }
            else { Start-GuiQueryWatch -Query $script:QHosts }
            Append-GuiLog -Line ('[STEP] 远程批量已提交：{0} 台，任务 {1}' -f $picked.Count, $script:HostBatchJobId)
            $dlg.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show($dlg, $_.Exception.Message, '无法提交', 'OK', 'Warning') | Out-Null
        }
    }.GetNewClosure())

    [void]$dlg.ShowDialog($form)
}

function Show-HostTrustDialog {
    if ($SkipPageHooks -or $script:AuditMode) { return }
    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'WinRM 信任设置（TrustedHosts）'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.ShowInTaskbar   = $false
    $dlg.BackColor       = $Pal.Bg
    $dlg.ForeColor       = $Pal.Text
    $dlg.Font            = New-Font -Size 9
    $dlg.ClientSize      = New-Object System.Drawing.Size(620, 420)
    try { $dlg.Owner = $form } catch { }

    $dlg.Controls.Add((New-HostFormLabel -Text '当前 TrustedHosts（本机 WinRM 客户端）' -X 14 -Y 12 -W 590))
    $txtCurrent = New-HostFormInput -X 14 -Y 38 -W 590 -H 110 -Multi
    $txtCurrent.ReadOnly = $true
    $dlg.Controls.Add($txtCurrent)

    $lblHint = New-HostFormLabel -Text '只有在工作组、HTTP + 当前用户认证时才需要把目标地址加入 TrustedHosts；本工具不会自动修改，每次添加/移除都会写入结构审计。' -X 14 -Y 156 -W 590
    $lblHint.Height = 54
    $dlg.Controls.Add($lblHint)

    $dlg.Controls.Add((New-HostFormLabel -Text '地址（逗号/分号分隔，支持 * 通配）' -X 14 -Y 216 -W 590))
    $prefill = ''
    if ($lstHosts.SelectedItems.Count -gt 0) { $prefill = [string]$lstHosts.SelectedItems[0].Tag.Address }
    $txtInput = New-HostFormInput -X 14 -Y 242 -W 590
    $txtInput.Text = $prefill
    $dlg.Controls.Add($txtInput)

    $btnClose = New-FlatButton -Text '关闭' -Width 80 -Height 30
    $btnClose.Location = New-Object System.Drawing.Point(336, 366)
    $dlg.Controls.Add($btnClose)
    $btnRemove = New-FlatButton -Text '移除' -Width 80 -Height 30
    $btnRemove.Location = New-Object System.Drawing.Point(424, 366)
    $dlg.Controls.Add($btnRemove)
    $btnAdd = New-FlatButton -Text '添加' -Width 100 -Height 30 -Kind Primary
    $btnAdd.Location = New-Object System.Drawing.Point(504, 366)
    $dlg.Controls.Add($btnAdd)

    $refreshTrust = {
        try {
            $s = Get-GuiReadyTrustedHostsState
            if ($s.Error) { $txtCurrent.Text = '读取失败：' + [string]$s.Error }
            elseif (@($s.Items).Count -eq 0) { $txtCurrent.Text = '（空）' }
            else { $txtCurrent.Text = (@($s.Items) -join "`r`n") }
            $script:HostTrusted = @($s.Items)
            $script:HostTrustedError = [string]$s.Error
        } catch {
            $txtCurrent.Text = '读取失败：' + $_.Exception.Message
        }
    }.GetNewClosure()
    & $refreshTrust

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $btnAdd.Add_Click({
        try {
            $addr = $txtInput.Text.Trim()
            if (-not $addr) { throw '请填写要信任的地址。' }
            $s = Add-GuiReadyTrustedHost -Address $addr
            & $refreshTrust
            Append-GuiLog -Line ('[OK] 已加入 TrustedHosts：' + $addr)
            if ($s.Error) { Append-GuiLog -Line ('[WARN] ' + [string]$s.Error) 'WARN' }
        } catch {
            [System.Windows.Forms.MessageBox]::Show($dlg, $_.Exception.Message, '添加失败', 'OK', 'Warning') | Out-Null
        }
    }.GetNewClosure())
    $btnRemove.Add_Click({
        try {
            $addr = $txtInput.Text.Trim()
            if (-not $addr) { throw '请填写要移除的地址。' }
            $s = Remove-GuiReadyTrustedHost -Address $addr
            & $refreshTrust
            Append-GuiLog -Line ('[OK] 已移出 TrustedHosts：' + $addr)
            if ($s.Error) { Append-GuiLog -Line ('[WARN] ' + [string]$s.Error) 'WARN' }
        } catch {
            [System.Windows.Forms.MessageBox]::Show($dlg, $_.Exception.Message, '移除失败', 'OK', 'Warning') | Out-Null
        }
    }.GetNewClosure())

    [void]$dlg.ShowDialog($form)
}

function Bind-HostsEvents {
    # 远程主机页的事件绑定；页面首次显示时由 Build-HostsPage 调用
$btnHostRefresh.Add_Click({ Start-HostsQuery })
$btnHostTest.Add_Click({ Start-HostsTest })
$btnHostBatch.Add_Click({ Show-HostBatchDialog })
$btnHostTrust.Add_Click({ Show-HostTrustDialog })
$btnHostAdd.Add_Click({ Show-HostEditDialog -Target $null })
$btnHostEdit.Add_Click({
    if ($lstHosts.SelectedItems.Count -eq 0) { Append-GuiLog -Line '[WARN] 先在列表里选一台主机。'; return }
    Show-HostEditDialog -Target $lstHosts.SelectedItems[0].Tag
})
$btnHostDelete.Add_Click({ Remove-SelectedHost })
$txtHostKeyword.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Start-HostsQuery }
})
$txtHostKeyword.Add_TextChanged({ if (-not $script:HostTagLoading) { Show-HostsList } })
$cmbHostTag.Add_SelectedIndexChanged({ if (-not $script:HostTagLoading) { Show-HostsList } })
$lstHosts.Add_SelectedIndexChanged({
    if ($lstHosts.SelectedItems.Count -eq 0) { $txtHostDetail.Text = $script:HostLastInfo; return }
    $txtHostDetail.Text = Format-HostDetail -Item $lstHosts.SelectedItems[0].Tag
})
}

# ---- 任务页辅助函数 ----

function Format-GuiTaskTime {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '-' }
    $t = [datetime]::MinValue
    try { $t = [datetime]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
    if ($t -eq [datetime]::MinValue) { return '-' }
    return $t.ToString('MM-dd HH:mm:ss')
}

function Format-GuiTaskDetail {
    param($Task)
    if (-not $Task) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('任务编号：' + [string]$Task.Id)
    [void]$sb.AppendLine('动作：' + [string]$Task.ActionName + '（' + [string]$Task.ActionId + '）    分组：' + [string]$Task.Group)
    [void]$sb.AppendLine('状态：' + (Get-GuiReadyTaskStatusText -Status ([string]$Task.Status)) + '    退出码：' + $(if ($null -eq $Task.ExitCode) { '-' } else { [string]$Task.ExitCode }) + '    耗时：' + [string]$Task.DurationSec + ' 秒')
    [void]$sb.AppendLine('排队：' + (Format-GuiTaskTime ([string]$Task.QueuedAt)) + '    开始：' + (Format-GuiTaskTime ([string]$Task.StartedAt)) + '    结束：' + (Format-GuiTaskTime ([string]$Task.EndedAt)))
    [void]$sb.AppendLine('机器：' + [string]$Task.Machine + '    用户：' + [string]$Task.User + '    进程：' + $(if ([int]$Task.Pid -gt 0) { [string]$Task.Pid } else { '-' }))
    if ([bool]$Task.DryRun) { [void]$sb.AppendLine('执行方式：仅预览（DryRun）') }
    if ([bool]$Task.Sensitive) { [void]$sb.AppendLine('敏感参数：有（已脱敏保存，禁止一键重试）') }
    if ([bool]$Task.ParamsTruncated) { [void]$sb.AppendLine('参数：过长已截断，禁止一键重试') }
    if ($Task.RetryOf) { [void]$sb.AppendLine('重试来源：' + [string]$Task.RetryOf) }
    [void]$sb.AppendLine('日志：' + [string]$Task.LogPath)
    [void]$sb.AppendLine(('-' * 72))
    if ($Task.Message) { [void]$sb.AppendLine('结果说明：' + [string]$Task.Message); [void]$sb.AppendLine('') }
    [void]$sb.AppendLine('参数：')
    $props = @()
    try { $props = @($Task.Params.PSObject.Properties) } catch { }
    if ($props.Count -eq 0) { [void]$sb.AppendLine('  （无）') }
    else { foreach ($p in $props) { [void]$sb.AppendLine(('  {0} = {1}' -f $p.Name, [string]$p.Value)) } }
    return $sb.ToString()
}

function Format-GuiAuditDetail {
    param($Entry)
    if (-not $Entry) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('时间：' + (Format-GuiTaskTime ([string]$Entry.Time)))
    [void]$sb.AppendLine('事件：' + (Get-GuiReadyAuditEventText -Event ([string]$Entry.Event)) + '（' + [string]$Entry.Event + '）    级别：' + [string]$Entry.Level)
    [void]$sb.AppendLine('动作：' + [string]$Entry.ActionId + '    任务编号：' + [string]$Entry.TaskId)
    [void]$sb.AppendLine('用户：' + [string]$Entry.User + '    机器：' + [string]$Entry.Machine)
    [void]$sb.AppendLine(('-' * 72))
    [void]$sb.AppendLine([string]$Entry.Detail)
    return $sb.ToString()
}

function Get-GuiTaskStatusFilter {
    $idx = [Math]::Max(0, [Math]::Min(5, $cmbTaskStatus.SelectedIndex))
    return @('', 'Running', 'Succeeded', 'Failed', 'Canceled', 'Interrupted')[$idx]
}

function Get-GuiAuditLevelFilter {
    $idx = [Math]::Max(0, [Math]::Min(4, $cmbAuditLevel.SelectedIndex))
    return @('', 'Success', 'Info', 'Warn', 'Error')[$idx]
}

function Get-GuiTaskSinceHours {
    param($Combo)
    $idx = [Math]::Max(0, [Math]::Min(3, $Combo.SelectedIndex))
    return @(24, 168, 720, 0)[$idx]
}

function Start-TasksQuery {
    if ($SkipPageHooks -or -not $script:QTasks) { return }
    if ($script:QTasks.Task) { $script:TaskRefreshPending = $true; return }
    $p = @{
        Limit      = 300
        SinceHours = (Get-GuiTaskSinceHours -Combo $cmbTaskSince)
        Status     = (Get-GuiTaskStatusFilter)
        Keyword    = $txtTaskKeyword.Text.Trim()
    }
    [void](Start-GuiQueryHost -Query $script:QTasks -Task 'list' -ArgsJson $p -BusyText '读取任务…')
}

function Start-AuditQuery {
    if ($SkipPageHooks -or -not $script:QAudit) { return }
    if ($script:QAudit.Task) { $script:AuditRefreshPending = $true; return }
    $p = @{
        Limit      = 300
        SinceHours = (Get-GuiTaskSinceHours -Combo $cmbAuditSince)
        Level      = (Get-GuiAuditLevelFilter)
        Keyword    = $txtAuditKeyword.Text.Trim()
    }
    [void](Start-GuiQueryHost -Query $script:QAudit -Task 'audit' -ArgsJson $p -BusyText '读取审计…')
}

function Show-TasksList {
    $lstTasks.BeginUpdate()
    try {
        $lstTasks.Items.Clear()
        foreach ($t in @($script:TaskItems)) {
            $li = New-Object System.Windows.Forms.ListViewItem((Format-GuiTaskTime ([string]$t.QueuedAt)))
            [void]$li.SubItems.Add($(if ([bool]$t.DryRun) { '[预览] ' } else { '' }) + [string]$t.ActionName)
            [void]$li.SubItems.Add((Get-GuiReadyTaskStatusText -Status ([string]$t.Status)))
            [void]$li.SubItems.Add(([string]$t.DurationSec + ' 秒'))
            [void]$li.SubItems.Add($(if ($null -eq $t.ExitCode) { '-' } else { [string]$t.ExitCode }))
            [void]$li.SubItems.Add([string]$t.User)
            [void]$li.SubItems.Add([string]$t.Id)
            $li.Tag = $t
            switch ([string]$t.Status) {
                'Failed'      { $li.ForeColor = $Pal.Err }
                'Canceled'    { $li.ForeColor = $Pal.Warn }
                'Interrupted' { $li.ForeColor = $Pal.Warn }
                'Running'     { $li.ForeColor = $Pal.Accent2 }
                default       { $li.ForeColor = $Pal.Text }
            }
            [void]$lstTasks.Items.Add($li)
        }
    } finally { $lstTasks.EndUpdate() }
}

function Show-AuditList {
    $lstAudit.BeginUpdate()
    try {
        $lstAudit.Items.Clear()
        foreach ($e in @($script:AuditItems)) {
            $li = New-Object System.Windows.Forms.ListViewItem((Format-GuiTaskTime ([string]$e.Time)))
            [void]$li.SubItems.Add((Get-GuiReadyAuditEventText -Event ([string]$e.Event)))
            $lv = '信息'
            switch ([string]$e.Level) {
                'Success' { $lv = '成功' }
                'Warn'    { $lv = '警告' }
                'Error'   { $lv = '错误' }
            }
            [void]$li.SubItems.Add($lv)
            [void]$li.SubItems.Add([string]$e.ActionId)
            [void]$li.SubItems.Add([string]$e.TaskId)
            [void]$li.SubItems.Add((([string]$e.Detail) -replace "`r?`n", ' '))
            $li.Tag = $e
            switch ([string]$e.Level) {
                'Error'   { $li.ForeColor = $Pal.Err }
                'Warn'    { $li.ForeColor = $Pal.Warn }
                'Success' { $li.ForeColor = $Pal.Ok }
                default   { $li.ForeColor = $Pal.Text }
            }
            [void]$lstAudit.Items.Add($li)
        }
    } finally { $lstAudit.EndUpdate() }
}

function Update-TaskChrome {
    try {
        $hw = [Math]::Max(240, $hdrTasks.Parent.ClientSize.Width)
        $right = $hw - 2
        foreach ($c in @($btnTaskAdv, $btnTaskNotify, $pillTaskSum)) {
            if (-not $c) { continue }
            $c.Left = [Math]::Max(0, ($right - $c.Width))
            $right = $c.Left - 6
        }
        if ($hdrTasks.Tag -and $hdrTasks.Tag.Sub) {
            $hdrTasks.Tag.Sub.Width = [Math]::Max(80, ($pillTaskSum.Left - [int]$hdrTasks.Tag.GapX - 12))
        }
    } catch { }
}

function Update-AuditChrome {
    try {
        $hw = [Math]::Max(240, $hdrAudit.Parent.ClientSize.Width)
        $pillAuditSum.Left = [Math]::Max(0, ($hw - $pillAuditSum.Width - 8))
        if ($hdrAudit.Tag -and $hdrAudit.Tag.Sub) {
            $hdrAudit.Tag.Sub.Width = [Math]::Max(80, ($pillAuditSum.Left - [int]$hdrAudit.Tag.GapX - 12))
        }
    } catch { }
}

function Update-NotifyButton {
    param([int]$Count = -1)
    if ($Count -lt 0) {
        try { $Count = Get-GuiReadyNotificationUnreadCount } catch { $Count = 0 }
    }
    $script:TaskUnread = $Count
    try { $btnTaskNotify.Text = ('通知 {0}' -f $Count) } catch { }
    Update-TaskChrome
}

function Update-TaskSummary {
    $s = $script:TaskStats
    if (-not $s) {
        Set-Pill -Pill $pillTaskSum -Text '待查询' -Kind 'Neutral'
        Update-TaskChrome
        return
    }
    if ($s.Running -gt 0) {
        Set-Pill -Pill $pillTaskSum -Text ('运行中 {0} · 今日 {1}' -f $s.Running, $s.TodayTotal) -Kind 'Info'
    } elseif ($s.TodayFailed -gt 0) {
        Set-Pill -Pill $pillTaskSum -Text ('今日失败 {0}' -f $s.TodayFailed) -Kind 'Danger'
    } else {
        Set-Pill -Pill $pillTaskSum -Text ('今日 {0} 条' -f $s.TodayTotal) -Kind 'Neutral'
    }
    Update-TaskChrome
}

function Receive-TasksResult {
    param($Obj)
    if ($null -eq $Obj) {
        $script:TaskRefreshPending = $false
        Start-TasksQuery
        return
    }
    if ([string]$Obj.Error) {
        Set-Pill -Pill $pillTaskSum -Text '读取失败' -Kind 'Danger'
        $txtTaskDetail.Text = [string]$Obj.Error
        Update-TaskChrome
        return
    }
    if ($Obj.Mode -eq 'list') {
        $data = $Obj.Data
        $script:TaskItems  = @($data.Items)
        $script:TaskStats  = $data.Stats
        $script:TaskUnread = [int]$data.Unread
        Show-TasksList
        Update-TaskSummary
        Update-NotifyButton -Count $script:TaskUnread
        if ($script:TaskRefreshPending) {
            $script:TaskRefreshPending = $false
            Start-TasksQuery
        }
    }
}

function Receive-AuditResult {
    param($Obj)
    if ($null -eq $Obj) {
        $script:AuditRefreshPending = $false
        Start-AuditQuery
        return
    }
    if ([string]$Obj.Error) {
        Set-Pill -Pill $pillAuditSum -Text '读取失败' -Kind 'Danger'
        $txtAuditDetail.Text = [string]$Obj.Error
        Update-AuditChrome
        return
    }
    if ($Obj.Mode -eq 'audit') {
        $script:AuditItems = @($Obj.Data.Items)
        Show-AuditList
        Set-Pill -Pill $pillAuditSum -Text ('{0} 条' -f $script:AuditItems.Count) -Kind $(if ($script:AuditItems.Count -gt 0) { 'Success' } else { 'Neutral' })
        Update-AuditChrome
        if ($script:AuditRefreshPending) {
            $script:AuditRefreshPending = $false
            Start-AuditQuery
        }
    } elseif ($Obj.Mode -eq 'audit-export') {
        $data = $Obj.Data
        Append-GuiLog -Line ('[OK] 审计已导出 {0} 条到 {1}' -f [int]$data.Count, [string]$data.Path)
        Set-Pill -Pill $pillAuditSum -Text ('已导出 {0} 条' -f [int]$data.Count) -Kind 'Success'
        Update-AuditChrome
    }
}

function Start-GuiTaskRetry {
    param([string]$TaskId)
    if ($SkipPageHooks -or $script:AuditMode) { return }
    if ($script:Proc) {
        Append-GuiLog -Line '[WARN] 上一个动作还在运行，等它结束后再重试。'
        return
    }
    $t = Get-GuiReadyTask -Id $TaskId
    if (-not $t) { Append-GuiLog -Line '[WARN] 找不到这条任务记录。'; return }
    if (-not [bool]$t.CanRetry) {
        Append-GuiLog -Line '[WARN] 这条任务含敏感参数或参数已截断，不能一键重试；请到「全部功能」重新填写。'
        return
    }
    $a = @($script:Actions | Where-Object { $_.Id -eq [string]$t.ActionId })
    if ($a.Count -eq 0) { Append-GuiLog -Line ('[WARN] 动作已不存在：' + [string]$t.ActionId); return }

    $vals = @{}
    try { foreach ($p in @($t.Params.PSObject.Properties)) { $vals[$p.Name] = $p.Value } } catch { }
    Select-GuiAction -Action $a[0]
    Set-ParamValues -Values $vals
    Start-GuiAction -DryRun $false -RetryOf ([string]$t.Id)
    if ($script:Proc) {
        if (-not $script:QTasks.Task) { Start-GuiQueryWatch -Query $script:QTasks }
        else { $script:TaskRefreshPending = $true }
    }
}

function Stop-SelectedGuiTask {
    if ($SkipPageHooks -or $script:AuditMode) { return }
    if ($lstTasks.SelectedItems.Count -eq 0) { Append-GuiLog -Line '[WARN] 先在列表里选一条任务。'; return }
    $t = $lstTasks.SelectedItems[0].Tag
    if (-not $t) { return }
    $st = [string]$t.Status
    if ($st -ne 'Running' -and $st -ne 'Queued') {
        Append-GuiLog -Line ('[WARN] 任务已经结束（{0}），不需要取消。' -f (Get-GuiReadyTaskStatusText -Status $st))
        return
    }
    $r = Stop-GuiReadyTask -Id ([string]$t.Id)
    Append-GuiLog -Line ('[WARN] ' + [string]$r.Message)
    if ($r.Ok) { Start-TasksQuery }
}

function Start-AuditExport {
    if ($SkipPageHooks -or $script:AuditMode) { return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = '导出审计记录'
    $dlg.Filter = 'CSV|*.csv|JSON Lines|*.jsonl'
    $dlg.FileName = ('scm-audit-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $fmt = $(if ($dlg.FileName.ToLowerInvariant().EndsWith('.jsonl')) { 'Jsonl' } else { 'Csv' })
    $p = @{
        Path       = $dlg.FileName
        Format     = $fmt
        Limit      = 5000
        SinceHours = (Get-GuiTaskSinceHours -Combo $cmbAuditSince)
        Level      = (Get-GuiAuditLevelFilter)
        Keyword    = $txtAuditKeyword.Text.Trim()
    }
    [void](Start-GuiQueryHost -Query $script:QAudit -Task 'audit-export' -ArgsJson $p -BusyText '导出审计…')
}

function Update-GuiNotifyList {
    param($ListView)
    if (-not $ListView) { return }
    $ListView.BeginUpdate()
    try {
        $ListView.Items.Clear()
        foreach ($n in @(Get-GuiReadyNotificationList -Limit 200)) {
            $li = New-Object System.Windows.Forms.ListViewItem((Format-GuiTaskTime ([string]$n.CreatedAt)))
            $kind = '信息'
            switch ([string]$n.Kind) {
                'Failed'  { $kind = '失败' }
                'Success' { $kind = '成功' }
            }
            [void]$li.SubItems.Add($kind)
            [void]$li.SubItems.Add([string]$n.Title)
            [void]$li.SubItems.Add((([string]$n.Text) -replace "`r?`n", ' '))
            if (-not [bool]$n.Read) { $li.Font = New-Font -Size 9 -Style Bold }
            if ([string]$n.Kind -eq 'Failed') { $li.ForeColor = $Pal.Err }
            [void]$ListView.Items.Add($li)
        }
    } finally { $ListView.EndUpdate() }
}

function Show-GuiNotifyDialog {
    if ($SkipPageHooks -or $script:AuditMode) { return }
    $items = @(Get-GuiReadyNotificationList -Limit 200)
    if ($items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('通知收件箱是空的。', '通知', 'OK', 'Information') | Out-Null
        return
    }

    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = '通知收件箱'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.ShowInTaskbar   = $false
    $dlg.BackColor       = $Pal.Bg
    $dlg.ForeColor       = $Pal.Text
    $dlg.Font            = New-Font -Size 9
    $dlg.ClientSize      = New-Object System.Drawing.Size(820, 460)
    try { $dlg.Owner = $form } catch { }

    $lst                 = New-Object System.Windows.Forms.ListView
    $lst.Dock            = 'Fill'
    $lst.View            = 'Details'
    $lst.FullRowSelect   = $true
    $lst.HideSelection   = $false
    $lst.MultiSelect     = $false
    $lst.GridLines       = $false
    $lst.BorderStyle     = 'None'
    $lst.BackColor       = $Pal.Card
    $lst.ForeColor       = $Pal.Text
    $lst.Font            = New-Font -Size 9
    [void]$lst.Columns.Add('时间', 126)
    [void]$lst.Columns.Add('类型', 56)
    [void]$lst.Columns.Add('标题', 250)
    [void]$lst.Columns.Add('详情', 360)
    Enable-GuiListViewSkin -List $lst -RowHeight 40

    $pnl                 = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnl.Dock            = 'Bottom'
    $pnl.Height          = 50
    $pnl.Padding         = New-Object System.Windows.Forms.Padding(8, 7, 8, 7)
    $pnl.FlowDirection   = 'LeftToRight'
    $pnl.WrapContents    = $false
    $pnl.BackColor       = $Pal.Bg

    $btnClose  = New-FlatButton -Text '关闭' -Width 76 -Height 30
    $btnAllRead = New-FlatButton -Text '全部标为已读' -Width 112 -Height 30 -Kind Primary
    $btnClear  = New-FlatButton -Text '清空' -Width 76 -Height 30 -Kind Danger
    foreach ($b in @($btnClose, $btnAllRead, $btnClear)) {
        $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
        $pnl.Controls.Add($b)
    }

    $dlg.Controls.Add($lst)
    $dlg.Controls.Add($pnl)
    Update-GuiNotifyList -ListView $lst

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $btnAllRead.Add_Click({
        [void](Set-GuiReadyNotificationRead -All)
        Update-GuiNotifyList -ListView $lst
        Update-NotifyButton -Count 0
    }.GetNewClosure())
    $btnClear.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show($dlg, '清空全部通知？此操作不可撤销。', '确认', 'YesNo', 'Warning')
        if ($r -eq 'Yes') {
            [void](Clear-GuiReadyNotifications)
            Update-GuiNotifyList -ListView $lst
            Update-NotifyButton -Count 0
        }
    }.GetNewClosure())

    [void]$dlg.ShowDialog($form)
    Update-NotifyButton
}

function Show-TasksPage {
    if ($SkipPageHooks) { return }
    Update-TaskChrome
    Update-NotifyButton
    if (-not $script:QTasks.Task) { Start-TasksQuery } else { $script:TaskRefreshPending = $true }
}

function Show-AuditPage {
    if ($SkipPageHooks) { return }
    Update-AuditChrome
    if (-not $script:QAudit.Task) { Start-AuditQuery } else { $script:AuditRefreshPending = $true }
}

$script:QTasks = New-GuiQueryHost -Name 'tasks' -Runner (Join-Path $guiDir 'Run-GuiReadyTasks.ps1') -TimeoutSec 120 `
    -OnResult { param($obj) Receive-TasksResult -Obj $obj } `
    -OnBusyStart { param($t) Set-Pill -Pill $pillTaskSum -Text $t -Kind 'Info'; Update-TaskChrome } `
    -OnBusyEnd { }

$script:QAudit = New-GuiQueryHost -Name 'audit' -Runner (Join-Path $guiDir 'Run-GuiReadyTasks.ps1') -TimeoutSec 120 `
    -OnResult { param($obj) Receive-AuditResult -Obj $obj } `
    -OnBusyStart { param($t) Set-Pill -Pill $pillAuditSum -Text $t -Kind 'Info'; Update-AuditChrome } `
    -OnBusyEnd { }

function Bind-TasksEvents {
    # 任务页的事件绑定；页面首次显示时由 Build-TasksPage 调用
$btnTaskRefresh.Add_Click({ Start-TasksQuery })
$btnTaskRetry.Add_Click({
    if ($lstTasks.SelectedItems.Count -eq 0) { Append-GuiLog -Line '[WARN] 先在列表里选一条任务。'; return }
    Start-GuiTaskRetry -TaskId ([string]$lstTasks.SelectedItems[0].Tag.Id)
})
$btnTaskCancel.Add_Click({ Stop-SelectedGuiTask })
$btnTaskLog.Add_Click({
    if ($SkipPageHooks -or $script:AuditMode) { return }
    if ($lstTasks.SelectedItems.Count -eq 0) { Append-GuiLog -Line '[WARN] 先在列表里选一条任务。'; return }
    $t = $lstTasks.SelectedItems[0].Tag
    $lp = [string]$t.LogPath
    if ($lp -and (Test-Path -LiteralPath $lp)) {
        try { Start-Process -FilePath $lp | Out-Null }
        catch { Append-GuiLog -Line ('[WARN] 打不开日志：' + $_.Exception.Message) }
    } else {
        Append-GuiLog -Line '[WARN] 这条任务没有留下日志文件。'
    }
})
$btnTaskAdv.Add_Click({ Show-ActionsDialog -Title '配置备份' -Groups @('配置备份') })
$btnTaskNotify.Add_Click({ Show-GuiNotifyDialog })

$lstTasks.Add_SelectedIndexChanged({
    if ($lstTasks.SelectedItems.Count -eq 0) { $txtTaskDetail.Text = ''; return }
    $txtTaskDetail.Text = Format-GuiTaskDetail -Task $lstTasks.SelectedItems[0].Tag
})
$txtTaskKeyword.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Start-TasksQuery }
})
}

function Bind-AuditEvents {
    # 结构审计页的事件绑定；页面首次显示时由 Build-AuditPage 调用
$lstAudit.Add_SelectedIndexChanged({
    if ($lstAudit.SelectedItems.Count -eq 0) { $txtAuditDetail.Text = ''; return }
    $txtAuditDetail.Text = Format-GuiAuditDetail -Entry $lstAudit.SelectedItems[0].Tag
})

$btnAuditRefresh.Add_Click({ Start-AuditQuery })
$btnAuditExport.Add_Click({ Start-AuditExport })
$txtAuditKeyword.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Start-AuditQuery }
})
}

# ============================ 关于页 ============================

$pageAbout             = New-Object System.Windows.Forms.Panel
$pageAbout.Dock        = 'Fill'
$pageAbout.BackColor   = $Pal.Bg
$script:Pages['about'] = $pageAbout
# 页面全部建完，关掉延迟：之后（对话框、动态行、参数面板）一律立即设 Region
$script:RoundDefer = $false
$pnlContent.Controls.Add($pageAbout)

# 关于页控件按需构建（首次显示本页时执行）：页头与信息卡片
function Build-AboutPage {
# HMOL PageHeader：38px 图标块 + 13.5pt 粗标题 + 9pt 副标题（右侧留给本页操作按钮）
$hdrAbout = New-PageHeader -Title '关于' -Subtitle 'Server Core GUI 就绪工具 —— 让带界面的程序在 Windows Server Core 上真正跑起来。' -Icon 'about' -Width 900
$pageAbout.Controls.Add($hdrAbout)
$lblAboutHead = $hdrAbout.Tag.Title
$lblAboutDesc = $hdrAbout.Tag.Sub

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

$lblAuVer              = New-Label -Text ('版本：v2.0    构建 ' + (Get-Date -Format 'yyyy-MM-dd')) -Size 10
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

# 写回脚本作用域：布局函数与 PageHeader 收尾同步要用这两个控件
$script:hdrAbout  = $hdrAbout
$script:cardAbout = $cardAbout
}
$script:PageBuilders['about'] = 'Build-AboutPage'

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
    try { $script:MonTrendTimer.Stop(); $script:MonTrendTimer.Dispose() } catch { }
    foreach ($q in @($script:QMon, $script:QMonTrend, $script:QSec, $script:QDsh, $script:QStoreInfo, $script:QFiles, $script:QLogs, $script:QTasks, $script:QAudit, $script:QHosts)) { if ($q) { Close-GuiQueryHost -Query $q } }
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

        # 标题栏右侧：窗口按钮从右往左排（HMOL 右侧 Margin=0,0,12,0、按钮间距 4）
        $right = $pnlTitle.ClientSize.Width - 12
        $top   = [int](($pnlTitle.ClientSize.Height - 32) / 2)
        foreach ($b in @($btnWinClose, $btnWinMax, $btnWinMin)) {
            if (-not $b) { continue }
            $right -= ($b.Width + 4)
            $b.Location = New-Object System.Drawing.Point($right, $top)
        }
        $right -= 10
        if ($btnExitBack) {
            $btnExitBack.Location = New-Object System.Drawing.Point(($right - $btnExitBack.Width), ($top + 2))
        }
        # 版本号跟在应用名后面（HMOL：应用名与版本号同一行，间距 8）
        if ($lblTitleVer -and $lblTitle) {
            $lblTitleVer.Location = New-Object System.Drawing.Point(($lblTitle.Right + 8), 16)
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
    # 下面三件事都跟"窗口能不能点"无关：WAC 组要查防火墙/证书，程序清单要读 JSON 再扫目录。
    # 投到消息队列，窗口先出来，用户看到界面时它们再在后台补上（BeginInvoke 按 FIFO 执行）。
    $form.BeginInvoke([Action]{
        try { Update-WacToolGroup } catch { }
        try { Load-Programs; Refresh-ProgramList } catch { }
    }) | Out-Null
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
    # 目录安全检查走 icacls、完整性核对要算全部文件的 SHA256 —— 两者都可能几百毫秒。
    # 一起投到消息队列：窗口先可交互，结果回来再补日志 / 弹提示。
    $form.BeginInvoke([Action]{
    try {
        $dirSafe = Test-GuiReadyToolDirSafe -Path $toolRoot
        if ($dirSafe.Known -and $dirSafe.Safe) {
            # 目录本身安全时，顺手把包含提权 worker 与备份的目录再收紧一层。
            # ⚠ 这两步走的是 icacls（文件系统），和"窗口能不能点"毫无关系，却卡在 Shown 里 ——
            # 实测 Shown 段占 1092ms，"可交互"被它硬生生推迟。改用 BeginInvoke 把它投到消息队列，
            # Shown 返回、界面可点之后再跑；失败只吞掉（安全加固失败不该影响用户操作）。
            if (Test-IsAdministrator) {
                try {
                    $form.BeginInvoke([Action]{
                        try {
                            [void](Protect-GuiReadyDir -Path (Join-Path $toolRoot 'logs'))
                            [void](Protect-GuiReadyDir -Path (Join-Path $toolRoot 'backup'))
                        } catch { }
                    }) | Out-Null
                } catch { }
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
    }) | Out-Null
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

    # 入口提示自愈：用户要求"任何时候都显示"。
    # 实测踩过：安装以 mmm 身份跑、用户却用 Administrator 登录 RDP，结果他那边一条提示都没有。
    # 这里在窗口可见后异步补一次（幂等、失败只吞掉，绝不拖慢启动）：
    #   - cmd：HKCU + HKLM AutoRun（机器级覆盖所有账户）
    #   - PowerShell：当前用户 profile + AllUsersAllHosts profile（覆盖所有账户）
    if (-not $SkipPageHooks) {
        try {
            $form.BeginInvoke([Action]{
                try { Set-GuiReadyConsoleWelcome -Quiet | Out-Null } catch { }
                try { Set-GuiReadyConsoleAllUsersWelcome -Quiet | Out-Null } catch { }
                try { Write-GuiReadyConsoleProfileHook -Quiet | Out-Null } catch { }
            }) | Out-Null
        } catch { }
    }

    # 安全提示弹窗放在最后：界面已经初始化完、也不会挡着初始化。
    # 带 owner（$form）才会显示在主窗口上面；同一个原因只在第一次提示（状态存 state\dir-warning.txt），
    # 免得每次启动都弹一次把人烦到、或者被误当成"卡住了"。
    # 诊断模式（-SelfTest / -LayoutDump / -UiAudit / -UiShot）一律不弹：
    # 这些都是无人值守跑一遍就退出的，弹一个模态框会把进程永久卡在那里
    #（-UiShot 走 $form.Show()，实测就是被这个框卡住的）。
    $form.BeginInvoke([Action]{
    if ($script:PendingDirWarning -and -not $SkipPageHooks) {
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
    }) | Out-Null
})

$form.Add_Resize({ Update-Chrome })

if ($UiAudit) {
    # ---------------- UI 审计 ----------------
    # 为什么要有它：SelfTest 只验证"页面能渲染"，但用户真正遇到的是**点进去**才炸
    #（进页面走的是 Show-*Page、点动作走的是 Select-GuiAction 重建参数控件，这两条路径
    #  以前只在真人操作时才跑到）。这里把 16 个页面、全部动作走一遍，只建界面不执行，
    # 再把每个页面的同级控件两两求交集，抓"这块压住那块"。
    $auditFail = 0
    $auditNotes = New-Object System.Collections.ArrayList

    # 必须先把窗口真的显示出来：不显示的话所有控件的 Visible 都是 false，
    # 重叠扫描会"扫描 0 个控件、无重叠"—— 假通过（实测第一版就是这样）。
    try { $form.Show(); [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 400 } catch { }

    Write-Host ''
    Write-Host '=== 1) 进入每个页面 ===' -ForegroundColor Cyan
    foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'files', 'logs', 'tasks', 'audit', 'hosts', 'tool', 'more', 'about')) {
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
    foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'files', 'logs', 'tasks', 'audit', 'hosts', 'tool', 'more', 'about')) {
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
    foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'files', 'logs', 'tasks', 'audit', 'hosts', 'tool', 'more', 'about')) {
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
                # 点之前先打印：审计万一卡在某个按钮弹出的模态框上，
                # 日志的最后一行就是"最后点的是哪个按钮"（实测卡过一次，当时完全没有线索）。
                Write-Host ('  [{0}] 点击 "{1}"' -f $k, $txt)
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
    foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'files', 'logs', 'tasks', 'audit', 'hosts', 'tool', 'more', 'about')) {
        try {
            $script:MonLoaded = $false
            $script:SecLoaded = $false
            $script:DshLoaded = $false
            $script:SkipPageHooks = $false
            Show-GuiPage -Key $k -SkipCards:$true
            # 等后台查询回来并回填（轮询把消息泵转起来，否则定时器根本不触发）
            # 上限给足：Server Core 上安全审计要跑十几秒；dsh 状态查询实测 41.6s
            #（node / pnpm / dsh 三个 npm 命令各自启动都要几秒）。原来给 45s 会误报"没跑完"。
            $until = (Get-Date).AddSeconds(90)
            while ((Get-Date) -lt $until) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 120
                $busy = $false
                foreach ($q in @($script:QMon, $script:QSec, $script:QDsh, $script:QFiles, $script:QLogs, $script:QTasks, $script:QAudit, $script:QHosts)) {
                    if ($q -and $q.Task) { $busy = $true }
                }
                if (-not $busy) { break }
            }
            [System.Windows.Forms.Application]::DoEvents()
            # 光"没抛异常"不算通过：还要确认查询真的回来了、界面真的回填了。
            # 卡在"正在…"、或者查询返回错误，以前在审计里同样看不出来。
            $busyList = @()
            foreach ($q in @($script:QMon, $script:QSec, $script:QDsh, $script:QFiles, $script:QLogs, $script:QHosts)) {
                if ($q -and $q.Task) { $busyList += ($q.Name + '=' + $q.Task) }
            }
            $info = ''
            switch ($k) {
                'monitor'  { $info = ('进程行 ' + @($script:MonRows).Count + ' · 汇总[' + [string]$pillMonSum.Tag.Text + ']') }
                'security' { $info = ('检查行 ' + @($script:SecRows).Count + ' · 汇总[' + [string]$pillSecSum.Tag.Text + ']') }
                'dsh'      { $info = ('依赖行 ' + @($script:DshRows).Count) }
                'files'    { $info = ('文件项 ' + @($script:FilesItems).Count + ' · ' + [string]$script:FilesPath) }
                'logs'     { $info = ('日志行 ' + @($script:LogEntries).Count + ' · [' + [string]$pillLogSum.Tag.Text + ']') }
                'tasks'    { $info = ('任务行 ' + @($script:TaskItems).Count + ' · [' + [string]$pillTaskSum.Tag.Text + ']') }
                'audit'    { $info = ('审计行 ' + @($script:AuditItems).Count + ' · [' + [string]$pillAuditSum.Tag.Text + ']') }
                'hosts'    { $info = ('主机行 ' + @($script:HostItems).Count + ' · [' + [string]$pillHostSum.Tag.Text + ']') }
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
            foreach ($q in @($script:QMon, $script:QSec, $script:QDsh, $script:QFiles, $script:QLogs, $script:QHosts)) {
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
        if ($UiShotWait -gt 0) {
            # 截图要看到"列表里有数据"的样子时，必须放行页面钩子并等查询回来。
            # 默认 0 保持旧行为（只拍骨架，不起子进程），避免日常截图顺手拉起一堆查询。
            $script:SkipPageHooks = $false
            Show-GuiPage -Key $StartPage -SkipCards
            $until = (Get-Date).AddMilliseconds($UiShotWait)
            while ((Get-Date) -lt $until) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 120
            }
        } else {
            Show-GuiPage -Key $StartPage -SkipCards
        }
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
        foreach ($k in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'files', 'logs', 'tasks', 'audit', 'hosts', 'tool', 'more', 'about')) {
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
        # 自检要数全部页面的控件（高级设置入口、设置页功能树等）：按需构建的页面在这里一次建出来
        foreach ($__k in @($script:Pages.Keys)) {
            if ($script:PageBuilders[$__k] -and -not $script:PageBuilt[$__k]) { Show-GuiPage -Key $__k }
        }
        $nodeCount = 0
        foreach ($g in $tree.Nodes) { $nodeCount += $g.Nodes.Count }
        $cardCount = $script:Cards.Count
        $envVals = @($script:Cards | ForEach-Object { $_.Value.Text })
        Select-GuiAction -Action $script:Actions[0]
        $ctlCount = $pnlParams.Controls.Count
        Update-ToolButtons
        Update-WacToolGroup
        $toolAvail = @($script:ToolButtons | Where-Object { -not $_.Missing }).Count
        # 「高级设置」入口：每个有动作的功能页都应挂一个（设置/商店/关于除外）
        $advCount = 0
        foreach ($pg in @($script:Pages.Values)) {
            foreach ($c in @($pg.Controls)) {
                if ($c.Tag -and $c.Tag.Advanced) { $advCount++ }
            }
        }
        Write-Host ('GUI SELFTEST OK: 页面 {0} 个 / 状态卡片 {1} 个 / 系统工具 {2} 个(可用 {3}) / 设置里功能 {4} 个 / 高级设置入口 {5} 个 / 参数控件 {6} 个 / 窗体 {7}' -f `
            $script:Pages.Count, $cardCount, $script:ToolButtons.Count, $toolAvail, $nodeCount, $advCount, $ctlCount, $form.Size.ToString()) -ForegroundColor Green
        if ($advCount -lt 8) {
            Write-Host ('  !! 高级设置入口只有 {0} 个（应为 8：环境/程序/工具/角色/仪表盘/安全/美化/AI）' -f $advCount) -ForegroundColor Red
        }
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
        # 精选行要在 Show-StoreResult 之前数：它内部会 Clear-StoreRows 再只填自检假数据，
        # 之后数出来的永远是 2 —— 上一版就是拿这个"2"当"精选没铺出来"的证据，口径错了。
        $storeCatalogN = @($script:StoreRows).Count
        # 界面类型筛选：把 CLI / TUI / GUI 逐个"点"一遍，验证铺行数按 catalog 的 ui 字段收缩。
        # 全部 = 12（13 条里 Windows Terminal 不是 choco，铺不出来）；cli/gui 各占一半；tui 目前为 0。
        $storeUiCounts = @{}
        foreach ($uv in @('cli', 'tui', 'gui')) {
            $script:StoreUiFilter = $uv
            $storeUiCounts[$uv] = [int](Add-StoreCatalogRows)
        }
        $script:StoreUiFilter = ''
        $storeCatalogN = [int](Add-StoreCatalogRows)
        Write-Host ('  商店筛选: 全部 {0} / CLI {1} / TUI {2} / GUI {3}' -f `
            $storeCatalogN, $storeUiCounts['cli'], $storeUiCounts['tui'], $storeUiCounts['gui']) -ForegroundColor Green
        if (($storeUiCounts['cli'] + $storeUiCounts['tui'] + $storeUiCounts['gui']) -ne $storeCatalogN) {
            Write-Host '  !! 商店筛选自检：三个类型之和 ≠ 全部（ui 过滤把条目丢了或重复了）' -ForegroundColor Red
        }
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
            # 合并去重验证：本地精选命中 7zip，上游又回 7zip + curl —— 期望合并后 2 行
            # （7zip 只留精选那条，curl 是上游补充的），而不是 3 行（同一包出现两次）。
            $script:StoreLocalHits = @(
                [pscustomobject]@{ Id = '7zip'; Version = ''; Source = 'choco'; Label = '精选'; DisplayName = '7-Zip'; Marker = '⚠️ 未验证' }
            )
            Show-StoreResult -Items @(
                [pscustomobject]@{ Id = '7zip'; Version = '26.3.0'; Source = 'choco' }
                [pscustomobject]@{ Id = 'curl'; Version = '8.10.0'; Source = 'choco' }
            )
            $storeRowsN   = @($script:StoreRows).Count
            $storeMergeOk = ($storeRowsN -eq 2 -and ([string]$script:StoreRows[0].Name.Text) -eq '7-Zip')
            $script:StoreLocalHits = @()
            # 工具详情：换一份 info 形状的 JSON 再渲染一次
            $infoJson = '{"Mode":"info","Source":"choco","Package":"7zip","Error":"","Items":[{"Id":"7zip","Version":"26.3.0",' +
                '"Title":"7-Zip","Published":"2026/9/4","Summary":"file archiver","Description":"line1\nline2","Tags":"7zip zip",' +
                '"Site":"http://www.7-zip.org/","License":"http://www.7-zip.org/license.txt","Url":"https://community.chocolatey.org/packages/7zip/26.3.0","Downloads":"35538182","Error":""}]}'
            try { [System.IO.File]::WriteAllText($storeTmp, $infoJson, (New-Object System.Text.UTF8Encoding($false))) } catch { }
            $infoObj = Import-GuiJsonFile -Path $storeTmp
            Render-StoreDetail -Obj $infoObj
            Write-Host ('  商店页: 源胶囊 {0} 个 / 精选行 {1} 行 / 结果行 {2} 行 / 详情行 {3} 行 / 搜索源 {4} 个' -f `
                $script:StorePills.Count, $storeCatalogN, $storeRowsN, @($script:StoreDetailRows).Count, $script:StoreComboMap.Count) -ForegroundColor Green
            Write-Host ('  商店合并: {0}（本地精选优先 + 上游补充，按 install.id 去重）' -f `
                $(if ($storeMergeOk) { 'OK' } else { '异常' })) -ForegroundColor $(if ($storeMergeOk) { 'Green' } else { 'Red' })
            if ($storeCatalogN -le 0) {
                Write-Host '  !! 商店页自检：本地精选库一行都没铺出来（查 store\catalog.json 是否存在、路径解析是否正确）' -ForegroundColor Red
            }
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
        # 主题覆盖自检：把 16 个页面的控件全走一遍，找出"没走 Token、还是浅色"的控件。
        # 为什么需要它：深色主题最常见的问题就是某个容器/下拉框漏改，肉眼不一定马上发现，
        # 而它会在深色界面上留一块刺眼的白。这里结构化地查一遍，以后加控件也不会漏。
        $themeBad = @()
        foreach ($tk in @('env', 'app', 'store', 'role', 'monitor', 'security', 'beauty', 'dsh', 'files', 'logs', 'tasks', 'audit', 'hosts', 'tool', 'more', 'about')) {
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
        try { $script:MonTrendTimer.Dispose() } catch { }
        foreach ($q in @($script:QMon, $script:QMonTrend, $script:QSec, $script:QDsh, $script:QStoreInfo, $script:QFiles, $script:QLogs, $script:QTasks, $script:QAudit, $script:QHosts)) { if ($q) { Close-GuiQueryHost -Query $q } }
        $form.Dispose()
    } catch {
        Write-Host ('GUI SELFTEST FAIL: ' + $_.Exception.Message) -ForegroundColor Red
    }
    return
}

[void]$form.ShowDialog()
try { $script:Timer.Dispose() } catch { }

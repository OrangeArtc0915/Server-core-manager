# GuiReady 设计系统：统一封装的自绘组件。
#
# 规范来源：想法.md 第四节「UI 设计规范」（4.3 Token / 4.4 尺寸 / 4.5 组件）
# 依赖（同一脚本作用域，定义在 GuiReady.GuiApp.ps1）：$Pal / New-Font / Set-Rounded
# 本文件加载时只定义函数、不创建控件；GuiApp 必须在这几个函数被调用之前 dot-source 它。
#
# 为什么自绘而不引第三方 UI 库：目标是 Server Core，只保证 GDI 可用，
# 第三方库普遍依赖现代渲染栈或额外运行时（依据见 想法.md 4.1 / 4.2）。

# ============================ 基础设施 ============================

function New-UiRoundPath {
    # 圆角矩形路径。几何算法与 GuiApp 的 Set-Rounded 完全一致 ——
    # 控件的 Region 与自绘描边必须对得上，改这里就要同步改那边。
    param([int]$Width, [int]$Height, [int]$Radius = 8)

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($Width -le 0 -or $Height -le 0) { return $path }

    # Radius 是"圆角半径"，不是直径：AddArc 的宽高参数是椭圆的**外接矩形**，
    # 所以这里要传 2r。传 r 的话实际圆角只有一半，而且会和 C# 那边自绘按钮的
    # 圆角（GrGui.UiButton.RoundRect 用的是标准半径）对不上 —— 描边会被 Region 切掉。
    $r = [Math]::Min($Radius, [Math]::Min($Width, $Height) / 2)
    if ($r -le 0) {
        $path.AddRectangle((New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)))
        return $path
    }
    $d = $r * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc(($Width - $d - 1), 0, $d, $d, 270, 90)
    $path.AddArc(($Width - $d - 1), ($Height - $d - 1), $d, $d, 0, 90)
    $path.AddArc(0, ($Height - $d - 1), $d, $d, 90, 90)
    $path.CloseAllFigures()
    return $path
}

function Enable-UiDoubleBuffer {
    # SetStyle 是 protected，PowerShell 直接调不到，只能反射。
    # 自绘控件必须开：UserPaint 关掉系统背景绘制后，没有双缓冲会闪。
    param([System.Windows.Forms.Control]$Control)
    try {
        $flags = [System.Windows.Forms.ControlStyles]::UserPaint -bor `
                 [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
                 [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer
        $m = [System.Windows.Forms.Control].GetMethod('SetStyle',
                ([System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic))
        if ($m) { $m.Invoke($Control, @($flags, $true)) | Out-Null }
    } catch { }
}

function Invoke-UiPaintFrame {
    # 「圆角填充 + 1px 圆角描边」，卡片与输入框共用。
    # 描边整体平移 0.5px，让 1px 线落在像素中心，边缘不糊。
    param(
        $Graphics,
        [int]$Width,
        [int]$Height,
        [int]$Radius,
        [System.Drawing.Color]$Fill,
        [System.Drawing.Color]$Border,
        [double]$BorderWidth = 1
    )

    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path  = New-UiRoundPath -Width ($Width - 1) -Height ($Height - 1) -Radius $Radius
    $brush = New-Object System.Drawing.SolidBrush($Fill)
    $pen   = New-Object System.Drawing.Pen($Border, $BorderWidth)
    try {
        $Graphics.FillPath($brush, $path)
        $Graphics.TranslateTransform(0.5, 0.5)
        $Graphics.DrawPath($pen, $path)
    } finally {
        $brush.Dispose(); $pen.Dispose(); $path.Dispose()
    }
}

# ============================ 卡片 ============================

function New-Card {
    param(
        [int]$Width = 240,
        [int]$Height = 120,
        [string]$Title = '',
        [int]$Radius = 12,
        [switch]$Hover,
        [switch]$StrongBorder
    )

    $card = New-Object System.Windows.Forms.Panel
    $card.Size      = New-Object System.Drawing.Size($Width, $Height)
    $card.BackColor = $Pal.Card
    Enable-UiDoubleBuffer -Control $card
    Set-Rounded -Control $card -Radius $Radius

    $card.Tag = @{
        Radius  = $Radius
        Border  = $(if ($StrongBorder) { $Pal.BorderStrong } else { $Pal.Border })
        Base    = $Pal.Card
        HoverBg = $(if ($Hover) { $Pal.CardHover } else { $Pal.Card })
    }

    $card.Add_Paint({
        param($s, $e)
        try {
            Invoke-UiPaintFrame -Graphics $e.Graphics -Width $s.Width -Height $s.Height `
                -Radius $s.Tag.Radius -Fill $s.BackColor -Border $s.Tag.Border
        } catch { }
    })

    if ($Hover) {
        # 注意：鼠标移到卡片里的子控件（标签等）上会触发 MouseLeave，hover 态会掉。
        # 需要「整卡 hover」时，卡片内不要再放会吃掉鼠标的子控件。
        $card.Add_MouseEnter({ $this.BackColor = $this.Tag.HoverBg; $this.Invalidate() })
        $card.Add_MouseLeave({ $this.BackColor = $this.Tag.Base;    $this.Invalidate() })
    }

    if ($Title) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text      = $Title
        $lbl.Font      = New-Font -Size 11 -Style Bold
        $lbl.ForeColor = $Pal.Text
        $lbl.BackColor = [System.Drawing.Color]::Transparent
        $lbl.AutoSize  = $true
        $lbl.Location  = New-Object System.Drawing.Point(14, 13)
        $card.Controls.Add($lbl)
        $card.Tag.Title = $lbl
    }
    return $card
}

# ============================ 胶囊 / 状态标签 ============================

function Get-UiPillColors {
    # 胶囊的语义配色（New-Pill 与 Set-Pill 共用，改配色只改这里）
    param([string]$Kind = 'Info')
    switch ($Kind) {
        'Success' { return @{ Fore = $Pal.Ok;      Back = $Pal.OkBg } }
        'Warn'    { return @{ Fore = $Pal.Warn;    Back = $Pal.WarnBg } }
        'Danger'  { return @{ Fore = $Pal.Err;     Back = $Pal.ErrBg } }
        'Neutral' { return @{ Fore = $Pal.SubText; Back = $Pal.Sunken } }
        # Info/默认：底是深靛（Accent4），文字要用提亮色 Accent3 才够对比
        default   { return @{ Fore = $Pal.Accent3; Back = $Pal.Accent4 } }
    }
}

function New-Pill {
    param(
        [string]$Text,
        [string]$Kind = 'Info',      # Info | Success | Warn | Danger | Neutral
        [int]$Height = 22
    )

    $c = Get-UiPillColors -Kind $Kind
    $fg = $c.Fore; $bg = $c.Back

    $font = New-Font -Size 8.5
    $w    = [int]([System.Windows.Forms.TextRenderer]::MeasureText($Text, $font).Width) + 20
    $r    = [int]($Height / 2)

    $pill = New-Object System.Windows.Forms.Panel
    $pill.Size      = New-Object System.Drawing.Size($w, $Height)
    $pill.BackColor = $bg
    $pill.Font      = $font
    $pill.Tag       = @{ Radius = $r; Text = $Text; Fore = $fg }
    Enable-UiDoubleBuffer -Control $pill
    Set-Rounded -Control $pill -Radius $r

    $pill.Add_Paint({
        param($s, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $path  = New-UiRoundPath -Width $s.Width -Height $s.Height -Radius $s.Tag.Radius
            $brush = New-Object System.Drawing.SolidBrush($s.BackColor)
            $g.FillPath($brush, $path)
            $brush.Dispose(); $path.Dispose()
            # ⚠ 每个实参先算进变量再调用。写成
            #     DrawText($g, $txt, $font, (New-Object …Rectangle…), (FLAGS -bor FLAGS), $color)
            # 是不行的：PowerShell 里逗号是数组运算符，`(…), $color` 会被当成一个数组实参，
            # 实参整体错位 → foreColor 收到 TextFormatFlags → 类型转换异常被 catch 吞掉，
            # 表现就是"胶囊底色画出来了、字一个都没有"。导航栏踩过同一个坑。
            $txt   = [string]$s.Tag.Text
            $fnt   = $s.Font
            $rect  = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
            $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor `
                     [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                     [System.Windows.Forms.TextFormatFlags]::SingleLine -bor `
                     [System.Windows.Forms.TextFormatFlags]::NoPadding
            [System.Windows.Forms.TextRenderer]::DrawText($g, $txt, $fnt, $rect, $s.Tag.Fore, $flags)
        } catch { }
    })
    return $pill
}

function Set-Pill {
    # 动态改胶囊的文字（宽度按新文字重算）、可选换语义色。
    # 换肤/换状态这类"就地更新"必须走这里，不能只改 Tag —— 绘制读的是 Tag 与尺寸。
    param(
        [System.Windows.Forms.Control]$Pill,
        [string]$Text,
        [string]$Kind = ''
    )
    if (-not $Pill -or $Pill.Tag -isnot [hashtable]) { return }
    try {
        if ($Kind) {
            $c = Get-UiPillColors -Kind $Kind
            $Pill.BackColor = $c.Back
            $Pill.Tag.Fore  = $c.Fore
        }
        $Pill.Tag.Text = [string]$Text
        $w = [int]([System.Windows.Forms.TextRenderer]::MeasureText([string]$Text, $Pill.Font).Width) + 20
        $Pill.Size = New-Object System.Drawing.Size($w, $Pill.Height)
        Set-Rounded -Control $Pill -Radius ([int]($Pill.Height / 2))
        $Pill.Invalidate()
    } catch { }
}

# ============================ 输入框 ============================

function New-TextBox {
    # 圆角输入框：Panel 画底与描边，里面放一个 BorderStyle=None 的 TextBox。
    # 返回 { Panel; Box }：布局用 Panel，取值/赋值用 Box。
    param(
        [int]$Width = 320,
        [int]$Height = 34,
        [string]$Text = '',
        [switch]$Password,
        [switch]$ReadOnly
    )

    $host_ = New-Object System.Windows.Forms.Panel
    $host_.Size      = New-Object System.Drawing.Size($Width, $Height)
    $host_.BackColor = $Pal.Card
    $host_.Tag       = @{ Radius = 8; Focused = $false }
    Enable-UiDoubleBuffer -Control $host_
    Set-Rounded -Control $host_ -Radius 8

    $host_.Add_Paint({
        param($s, $e)
        try {
            $border  = $(if ($s.Tag.Focused) { $Pal.Accent2 } else { $Pal.Border })
            $width   = $(if ($s.Tag.Focused) { 1.6 } else { 1 })
            Invoke-UiPaintFrame -Graphics $e.Graphics -Width $s.Width -Height $s.Height `
                -Radius $s.Tag.Radius -Fill $s.BackColor -Border $border -BorderWidth $width
        } catch { }
    })

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = 'None'
    $tb.Font        = New-Font -Size 9.5
    $tb.ForeColor   = $Pal.Text
    $tb.BackColor   = $Pal.Card
    $tb.Width       = $Width - 24
    $tb.Location    = New-Object System.Drawing.Point(12, [int](($Height - 20) / 2))
    if ($Text) { $tb.Text = $Text }
    if ($Password) { $tb.UseSystemPasswordChar = $true }
    if ($ReadOnly) { $tb.ReadOnly = $true; $tb.ForeColor = $Pal.SubText }

    # 聚焦时描边转强调色（见 4.5）
    $tb.Tag = $host_
    $tb.Add_GotFocus({
        $h = $this.Tag; $h.Tag.Focused = $true;  $h.Invalidate()
    })
    $tb.Add_LostFocus({
        $h = $this.Tag; $h.Tag.Focused = $false; $h.Invalidate()
    })
    $host_.Controls.Add($tb)

    return [pscustomobject]@{ Panel = $host_; Box = $tb }
}

# ============================ 进度条 ============================

function New-ProgressBar {
    param(
        [int]$Width = 320,
        [int]$Height = 8,
        [double]$Value = 0,
        [switch]$Indeterminate
    )

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Size      = New-Object System.Drawing.Size($Width, $Height)
    $bar.BackColor = $Pal.Sunken
    $bar.Tag       = @{
        Radius        = [int]($Height / 2)
        Value         = [Math]::Max(0, [Math]::Min(100, $Value))
        Indeterminate = [bool]$Indeterminate
    }
    Enable-UiDoubleBuffer -Control $bar
    Set-Rounded -Control $bar -Radius ([int]($Height / 2))

    $bar.Add_Paint({
        param($s, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $r = $s.Tag.Radius

            # 轨道
            $path  = New-UiRoundPath -Width $s.Width -Height $s.Height -Radius $r
            $brush = New-Object System.Drawing.SolidBrush($s.BackColor)
            $g.FillPath($brush, $path)
            $brush.Dispose()

            $fill = New-Object System.Drawing.SolidBrush($Pal.Accent2)
            if ($s.Tag.Indeterminate) {
                # 不确定进度：位置由系统计时器推出，调用方只要定时 Invalidate 就会自己动。
                # 用轨道做裁剪，流动块不会溢出圆角。
                $fw = [int]($s.Width * 0.3)
                $phase = ([Environment]::TickCount % 1400) / 1400.0
                $fx = [int](($s.Width + $fw) * $phase) - $fw
                $g.SetClip($path)
                $g.FillRectangle($fill, (New-Object System.Drawing.Rectangle($fx, 0, $fw, $s.Height)))
                $g.ResetClip()
            } elseif ($s.Tag.Value -gt 0) {
                $fw = [int]($s.Width * ($s.Tag.Value / 100.0))
                if ($fw -lt (2 * $r)) { $fw = [Math]::Min($s.Width, 2 * $r) }
                $fp = New-UiRoundPath -Width $fw -Height $s.Height -Radius $r
                $g.FillPath($fill, $fp)
                $fp.Dispose()
            }
            $fill.Dispose(); $path.Dispose()
        } catch { }
    })
    return $bar
}

function Set-ProgressBar {
    param(
        [System.Windows.Forms.Control]$Bar,
        [double]$Value,
        [switch]$Indeterminate
    )
    if (-not $Bar -or $Bar.Tag -isnot [hashtable]) { return }
    try {
        if ($PSBoundParameters.ContainsKey('Value')) {
            $Bar.Tag.Value = [Math]::Max(0, [Math]::Min(100, $Value))
        }
        if ($PSBoundParameters.ContainsKey('Indeterminate')) {
            $Bar.Tag.Indeterminate = [bool]$Indeterminate
        }
        $Bar.Invalidate()
    } catch { }
}

# ============================ 子进程查询宿主 ============================
# 「起子进程 → 轮询它写出的 JSON → 回填界面」这套流程，现在有六处在用
# （环境卡片 / 商店 / 角色 / 仪表盘 / 安全 / AI）。这里把这套流程抽出来，
# 页面只需提供 Runner、超时和渲染回调，不用再各写一遍定时器与超时保护。
#
# 用法：
#   $script:QMon = New-GuiQueryHost -Name 'monitor' -Runner (Join-Path $guiDir 'Run-GuiReadyMonitor.ps1') `
#                    -OnResult { param($obj) ...渲染... }
#   Start-GuiQueryHost -Query $script:QMon -Task 'snapshot' -BusyText '采集快照…'
#   Start-GuiQueryWatch -Query $script:QMon        # 等一个已启动的动作跑完
#
# 依赖（同一脚本作用域）：Append-GuiLog、Import-GuiJsonFile（定义在 GuiReady.GuiApp.ps1）。

# ---- 查询宿主的推进器：**一个**脚本级定时器驱动所有宿主 ----
#
# 为什么不用"每个宿主一个定时器 + .GetNewClosure()"（这是踩过的坑，别再改回去）：
#   PowerShell 的 scriptblock 不是闭包，回调里看不到外层**函数**的局部变量，所以之前用
#   .GetNewClosure() 把 $query 带进来。但 GetNewClosure() 会**新建一个模块作用域**，
#   脚本里定义的函数（Update-GuiQueryHost 等）在里面**看不见** —— 定时器一跳就是
#   "无法将…Update-GuiQueryHost…识别为 cmdlet、函数、脚本文件或可运行程序的名称"。
#
#   更阴的是它只在**被别的脚本 & 调用**时才发作：
#     一键运行.bat → Start-GuiReadyApp.ps1 → & gui\GuiReady.GuiApp.ps1   ← 闭包里找不到函数
#     直接 powershell -File gui\GuiReady.GuiApp.ps1                        ← 反而正常
#   于是"直接跑自检全绿、双击一键运行就报错"。实测复现：仪表盘 / 安全 / AI 三页
#   （正好是仅有的三个用查询宿主的页面）进去就报错，其他页面没事。
#
# 现在的做法：宿主注册到一张表里，由脚本级定时器统一推进。回调是**普通 scriptblock**
# （不是闭包），函数解析走脚本作用域，怎么调用都不会丢。空闲时定时器自己停下，不空转。
if (-not $script:GuiQueryHosts) { $script:GuiQueryHosts = New-Object System.Collections.ArrayList }
if (-not $script:GuiQueryTimer) { $script:GuiQueryTimer = $null }

function Register-GuiQueryHost {
    param([Parameter(Mandatory = $true)][hashtable]$Query)
    if (-not $script:GuiQueryHosts.Contains($Query)) { [void]$script:GuiQueryHosts.Add($Query) }
}

function Update-AllGuiQueryHosts {
    # 推进所有"正在跑"的宿主；一个都不忙就把定时器停掉（空闲不空转）。
    $busy = 0
    foreach ($q in @($script:GuiQueryHosts)) {
        if ($q -and $q.Task) {
            $busy++
            # 这里必须 catch：一个宿主出错不能把整条推进链打断（否则别的页面也一起卡住）。
            # 但**绝对不能**吞掉 —— 吞掉的表现是"页面停在正在…什么都没说"，
            # 正是最难查的那种（实测踩到：仪表盘的汇总胶囊一直停在"采集快照…"）。
            try {
                Update-GuiQueryHost -Query $q
            } catch {
                try { Append-GuiLog -Line ('[ERROR] {0} 页面回填出错: {1}' -f $q.Name, $_.Exception.Message) } catch { }
                try {
                    $stk = [string]$_.ScriptStackTrace
                    if ($stk) { Append-GuiLog -Line ('[ERROR]   ' + ($stk -split "`r?`n")[0]) }
                } catch { }
                try { Stop-GuiQueryHost -Query $q } catch { }
            }
        }
    }
    if ($busy -eq 0) { try { if ($script:GuiQueryTimer) { $script:GuiQueryTimer.Stop() } } catch { } }
}

function Start-GuiQueryTicker {
    try {
        if (-not $script:GuiQueryTimer) {
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = 400
            # 普通 scriptblock：函数解析走脚本作用域（换成 .GetNewClosure() 就会失效，见上）
            $t.Add_Tick({ Update-AllGuiQueryHosts })
            $script:GuiQueryTimer = $t
        }
        $script:GuiQueryTimer.Start()
    } catch { }
}

function New-GuiQueryHost {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Runner,
        [Parameter(Mandatory = $true)][scriptblock]$OnResult,
        [scriptblock]$OnBusyStart = $null,
        [scriptblock]$OnBusyEnd = $null,
        [int]$IntervalMs = 300,
        [int]$TimeoutSec = 120
    )

    $query = @{
        Name = $Name; Runner = $Runner; OnResult = $OnResult
        OnBusyStart = $OnBusyStart; OnBusyEnd = $OnBusyEnd
        TimeoutSec = $TimeoutSec
        Task = ''; Proc = $null; OutFile = ''; RunDir = ''; Extra = @()
    }
    Register-GuiQueryHost -Query $query
    return $query
}

function Start-GuiQueryHost {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Query,
        [string]$Task = 'query',
        [string[]]$ExtraArgs = $null,
        [hashtable]$ArgsJson = $null,
        [string]$BusyText = '正在查询…'
    )

    if ($Query.Task) {
        Append-GuiLog -Line ('[INFO] {0} 查询还在跑，等它结束。' -f $Query.Name)
        return $false
    }
    if (-not (Test-Path -LiteralPath $Query.Runner)) {
        Append-GuiLog -Line ('[ERROR] 找不到查询脚本: ' + $Query.Runner)
        return $false
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $env:TEMP ('gui-{0}-{1}-{2}' -f $Query.Name, $Task, $stamp)
    try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    $Query.OutFile   = Join-Path $dir 'result.json'
    $Query.RunDir    = $dir

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                 '-File', ('"' + $Query.Runner + '"'),
                 '-Mode', $Task,
                 '-OutFile', ('"' + $Query.OutFile + '"'))

    # 数据类参数一律走 JSON 文件（见 Run-GuiReadyStore.ps1 里的说明）：
    # 命令行传值要手工拼引号，而值可能来自远程 feed。
    if ($ArgsJson) {
        $af = Join-Path $dir 'args.json'
        try {
            [System.IO.File]::WriteAllText($af, ($ArgsJson | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
            $argList += @('-ArgsFile', ('"' + $af + '"'))
        } catch {
            Append-GuiLog -Line ('[ERROR] 参数文件写入失败: ' + $_.Exception.Message)
            return $false
        }
    }
    # ExtraArgs 只允许**代码里写死的字面量**（比如 -DeepProbe），绝不要塞外部数据。
    if ($ExtraArgs) { $argList += $ExtraArgs }

    try {
        $Query.Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden
    } catch {
        Append-GuiLog -Line ('[ERROR] {0} 查询启动失败: {1}' -f $Query.Name, $_.Exception.Message)
        $Query.Proc = $null
        return $false
    }

    $Query.Task = $Task
    if ($Query.OnBusyStart) { & $Query.OnBusyStart $BusyText }
    Start-GuiQueryTicker
    return $true
}

function Start-GuiQueryWatch {
    # 盯一个已经启动的动作（$script:Proc）什么时候跑完；跑完会调 OnResult($null)
    param([Parameter(Mandatory = $true)][hashtable]$Query)
    $Query.Task = 'watch'
    $Query.Proc = $null
    Start-GuiQueryTicker
}

function Update-GuiQueryHost {
    param([Parameter(Mandatory = $true)][hashtable]$Query)

    if ($Query.Task -eq 'watch') {
        $running = $false
        try {
            if ($script:Proc) {
                $script:Proc.Refresh()
                if (-not $script:Proc.HasExited) { $running = $true }
            }
        } catch { }
        if ($running) { return }
        Stop-GuiQueryHost -Query $Query
        if ($Query.OnResult) { & $Query.OnResult $null }
        return
    }

    if (-not $Query.Task) {
        # 没在跑就什么都不用做；空闲时由 Update-AllGuiQueryHosts 统一把定时器停下
        return
    }

    # 超时保护：查询卡住时不能让界面永远停在「正在…」
    try {
        if ($Query.Proc) {
            $Query.Proc.Refresh()
            if (((Get-Date) - $Query.Proc.StartTime).TotalSeconds -gt $Query.TimeoutSec -and
                -not (Test-Path -LiteralPath $Query.OutFile)) {
                Append-GuiLog -Line ('[WARN] {0} 查询超过 {1} 秒没有结果，已放弃。' -f $Query.Name, $Query.TimeoutSec)
                Stop-GuiQueryHost -Query $Query
                return
            }
        }
    } catch { }

    $obj = Import-GuiJsonFile -Path $Query.OutFile
    if (-not $obj) { return }

    $err = ''
    try { $err = [string]$obj.Error } catch { }
    Stop-GuiQueryHost -Query $Query
    if ($err) { Append-GuiLog -Line ('[WARN] {0} 查询返回错误: {1}' -f $Query.Name, $err) }
    if ($Query.OnResult) { & $Query.OnResult $obj }
}

function Stop-GuiQueryHost {
    param([Parameter(Mandatory = $true)][hashtable]$Query)
    $Query.Task = ''
    $Query.Proc = $null
    # 定时器是所有宿主共用的，这里不停它：Update-AllGuiQueryHosts 发现一个都不忙会自己停，
    # 而且此刻别的宿主可能还在跑，停掉就把人家也带停了。
    # 查询用的临时目录（result.json / args.json）用完就删：不给服务器留垃圾文件
    if ($Query.RunDir) { try { Remove-Item -LiteralPath $Query.RunDir -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
    if ($Query.OnBusyEnd) { try { & $Query.OnBusyEnd } catch { } }
}

function Close-GuiQueryHost {
    # 窗口退出 / 自检结束时调：把宿主从共用定时器的表里摘掉，并停一次定时器。
    param([Parameter(Mandatory = $true)][hashtable]$Query)
    try { $Query.Task = ''; $Query.Proc = $null } catch { }
    try { if ($script:GuiQueryHosts) { $script:GuiQueryHosts.Remove($Query) } } catch { }
    try { if ($script:GuiQueryTimer) { $script:GuiQueryTimer.Stop() } } catch { }
}


# ============================ 列表行 ============================
# 「一张卡片一行、右边贴按钮和胶囊」在仪表盘/安全/AI 三个页面里都要用，这里统一造。

function Get-UiRowWidth {
    param([System.Windows.Forms.Control]$Container, [int]$Min = 420)
    $w = $Container.ClientSize.Width
    if ($w -le 0) { $w = $Container.Width }
    return [Math]::Max($Min, ($w - 26))
}

function Update-UiRowLayout {
    # 行内元素全部右对齐：从右往左依次摆 按钮 → 胶囊
    param([object[]]$Rows, [int]$RowWidth)
    foreach ($r in @($Rows)) {
        try {
            if (-not $r) { continue }
            if ($r.Panel) {
                $r.Panel.Width = $RowWidth
                Set-Rounded -Control $r.Panel -Radius 10
            }
            if ($r.Title) { $r.Title.Width = $RowWidth - 240 }
            if ($r.Meta)  { $r.Meta.Width  = $RowWidth - 240 }

            $x = $RowWidth - 12
            if ($r.Btn) {
                $x -= $r.Btn.Width
                $r.Btn.Location = New-Object System.Drawing.Point($x, [int](($r.Panel.Height - $r.Btn.Height) / 2))
                $x -= 10
            }
            if ($r.Pill) {
                $x -= $r.Pill.Width
                $r.Pill.Location = New-Object System.Drawing.Point($x, [int](($r.Panel.Height - $r.Pill.Height) / 2))
            }
        } catch { }
    }
}

function Add-UiRow {
    # 造一行：标题 + 可选副行 + 可选胶囊 + 可选按钮。返回记录对象，页面把它收进数组，
    # 窗口尺寸变化时整批传给 Update-UiRowLayout 重排。
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Control]$Container,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Meta = '',
        [string]$PillText = '', [string]$PillKind = 'Neutral',
        [string]$BtnText = '', [string]$BtnKind = 'Normal',
        [hashtable]$BtnTag = $null, [scriptblock]$BtnClick = $null,
        [int]$Height = 52,
        [double]$TitleSize = 9.5,
        [int]$MarginBottom = 6
    )

    $rowW = Get-UiRowWidth -Container $Container
    $row  = New-Card -Width $rowW -Height $Height -Radius 10
    $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, $MarginBottom)

    $lb = New-Label -Text $Title -Size $TitleSize -Style Bold -Width ($rowW - 240)
    $lb.Location = New-Object System.Drawing.Point(12, [int][Math]::Max(6, (($Height - 34) / 2)))
    $row.Controls.Add($lb)

    $lm = $null
    if ($Meta) {
        $lm = New-Label -Text $Meta -Size 8.5 -Color Hint -Width ($rowW - 240)
        $lm.Height = 34
        $lm.Location = New-Object System.Drawing.Point(12, ($lb.Top + 20))
        $row.Controls.Add($lm)
    }

    $pill = $null
    if ($PillText) {
        $pill = New-Pill -Text $PillText -Kind $PillKind
        $row.Controls.Add($pill)
    }

    $btn = $null
    if ($BtnText) {
        $btn = New-FlatButton -Text $BtnText -Kind $BtnKind -Width 76 -Height 28
        if ($BtnTag)    { $btn.Tag = $BtnTag }
        if ($BtnClick)  { $btn.Add_Click($BtnClick) }
        $row.Controls.Add($btn)
    }

    $Container.Controls.Add($row)
    $rec = [pscustomobject]@{ Panel = $row; Title = $lb; Meta = $lm; Pill = $pill; Btn = $btn }
    Update-UiRowLayout -Rows @($rec) -RowWidth $rowW
    return $rec
}

function Invoke-PageAction {
    # 页面上的按钮 → 走既有的动作机制（子进程 + 全局日志面板），参数同时写回「更多」页的表单，
    # 这样用户点开「更多」能看到刚才是用什么参数跑的。
    # 传了 -Query 的话，动作跑完那一刻会回调那个查询宿主的 OnResult（用来刷新页面数据）。
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [hashtable]$Params = @{},
        [hashtable]$Query = $null
    )

    if ($script:Proc) {
        [System.Windows.Forms.MessageBox]::Show('上一个动作还在运行，请先等它结束。', '提示', 'OK', 'Information') | Out-Null
        return $false
    }
    $a = @($script:Actions | Where-Object { $_.Id -eq $Id })
    if ($a.Count -eq 0) {
        Append-GuiLog -Line ('[ERROR] 未找到功能: ' + $Id)
        return $false
    }

    Select-GuiAction -Action $a[0]
    Set-ParamValues -Values $Params
    Start-GuiAction -DryRun $false

    if ($script:Proc -and $Query) { Start-GuiQueryWatch -Query $Query }
    return [bool]$script:Proc
}

# ============================ 组件自检 ============================

function Get-UiPaintedPixels {
    # 数「与背景色不同的像素」，用来判断控件是不是真的画出了东西。
    param(
        [System.Windows.Forms.Control]$Control,
        [System.Drawing.Color]$Background,
        [int]$Tolerance = 40
    )
    if ($Control.Width -le 0 -or $Control.Height -le 0) { return -1 }

    $bmp = New-Object System.Drawing.Bitmap($Control.Width, $Control.Height)
    $n = 0
    try {
        $Control.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $Control.Width, $Control.Height)))
        for ($y = 0; $y -lt $bmp.Height; $y += 2) {
            for ($x = 0; $x -lt $bmp.Width; $x += 2) {
                $c = $bmp.GetPixel($x, $y)
                $diff = [Math]::Abs($c.R - $Background.R) + [Math]::Abs($c.G - $Background.G) + [Math]::Abs($c.B - $Background.B)
                if ($diff -gt $Tolerance) { $n++ }
            }
        }
    } catch {
        $n = -1
    } finally {
        $bmp.Dispose()
    }
    return $n
}

function Test-GuiUiComponents {
    # 把每个组件在屏幕外真画一遍再取样。
    # 抓的是「控件建出来了 / 底色画出来了，但**文字一个字都没有**」这类只在真机上才暴露的问题
    #（和 catalog / 自检的取证思路一致，见 README「GUI 能力自检」）。
    #
    # 「文字」这一项为什么要单独验：底色画出来 ≠ 文字画出来。文字是用
    # TextRenderer.DrawText 走 GDI 画的，一旦那次调用的实参被 PowerShell 的数组运算符
    # 弄错位（见 New-Pill / 导航项里的说明），就会抛类型转换异常并被 catch 吞掉 ——
    # 界面上看到的是一块块"只有底色没有字"的胶囊，而原来的自检照样全绿。实测踩过。
    # 验法：造一个底色与取样基准色**相同**的样本，那么非背景像素就只可能来自文字。
    $results = New-Object System.Collections.ArrayList

    $probe = New-Object System.Windows.Forms.Form
    $probe.FormBorderStyle = 'None'
    $probe.ShowInTaskbar   = $false
    $probe.StartPosition   = 'Manual'
    $probe.Location        = New-Object System.Drawing.Point(-4000, -4000)
    $probe.Size            = New-Object System.Drawing.Size(640, 360)
    # 取样基准必须用**主题背景色**而不是白色：深色主题下若拿白色当"没画东西"的基准，
    # 卡片本身的深底也会被算成"画过了"，这个自检就失去意义。
    $probe.BackColor       = $Pal.Bg

    try {
        $probe.Show()

        $pill = New-Pill -Text '文字渲染检查' -Kind 'Neutral'   # Neutral 底 = Sunken，正好当取样基准
        $probes = @(
            [pscustomobject]@{ Name = '卡片';   Ctl = (New-Card -Width 240 -Height 72 -Title '示例卡片'); Base = $Pal.Bg },
            [pscustomobject]@{ Name = '输入框'; Ctl = (New-TextBox -Width 240).Panel;                    Base = $Pal.Bg },
            [pscustomobject]@{ Name = '胶囊';   Ctl = (New-Pill -Text '可用' -Kind Success);             Base = $Pal.Bg },
            [pscustomobject]@{ Name = '文字';   Ctl = $pill;                                             Base = $pill.BackColor },
            [pscustomobject]@{ Name = '进度条'; Ctl = (New-ProgressBar -Width 240 -Height 8 -Value 60);  Base = $Pal.Bg }
        )

        $y = 12
        foreach ($p in $probes) {
            $p.Ctl.Location = New-Object System.Drawing.Point(12, $y)
            $probe.Controls.Add($p.Ctl)
            $y += $p.Ctl.Height + 14
        }
        $probe.PerformLayout()

        foreach ($p in $probes) {
            $n = Get-UiPaintedPixels -Control $p.Ctl -Background $p.Base
            [void]$results.Add([pscustomobject]@{ Name = $p.Name; Ok = ($n -ge 6); Pixels = $n; Error = '' })
        }
    } catch {
        [void]$results.Add([pscustomobject]@{ Name = '组件自检'; Ok = $false; Pixels = -1; Error = $_.Exception.Message })
    } finally {
        try { $probe.Close(); $probe.Dispose() } catch { }
    }
    return $results
}

# ============================ 自绘控件类型（C#）============================
# 为什么用 C# 而不是纯 PowerShell：
#   1. 按钮要在 OnPaint 里自己画，还要跟踪 hover/press —— PowerShell 的 Paint 回调
#      能画，但状态只能塞进 .Tag，而业务代码到处在覆盖按钮的 .Tag（工具按钮、商店行按钮、
#      参数浏览按钮…），一覆盖样式就丢。派生一个类、把样式做成强类型字段，这个冲突就没了。
#   2. 窗口外壳要无边框 + 自绘投影 + 边缘拖拽缩放，必须重写 WndProc / 鼠标消息，
#      这在 PowerShell 里做不了（SetStyle 是 protected）。
# 两个类都只依赖 System.Windows.Forms / System.Drawing（GDI+），Server Core 上可用，
# 不引入任何第三方库，也不需要 WPF（WPF 在 Server Core 上要额外组件，见 想法.md 4.1）。

$script:UiTypesSource = @'
namespace GrGui
{
    // 自绘按钮：四档语气（Outline / Solid / Danger / Plain）+ 圆角 + hover/press 三态。
    public class UiButton : System.Windows.Forms.Button
    {
        public int Radius = 8;
        public int BorderWidth = 1;
        public string Align = "Center";       // Center | Left | Right
        public System.Drawing.Color BackNormal;
        public System.Drawing.Color BackHover;
        public System.Drawing.Color BackPress;
        public System.Drawing.Color BackIdle;
        public System.Drawing.Color BorderColor;
        public System.Drawing.Color BorderIdle;
        public System.Drawing.Color ForeNormal;
        public System.Drawing.Color ForeHover;
        public System.Drawing.Color ForeIdle;

        private bool hover;
        private bool pressed;

        public UiButton()
        {
            this.SetStyle(System.Windows.Forms.ControlStyles.UserPaint
                | System.Windows.Forms.ControlStyles.AllPaintingInWmPaint
                | System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer
                | System.Windows.Forms.ControlStyles.ResizeRedraw, true);
            this.FlatStyle = System.Windows.Forms.FlatStyle.Flat;
            this.FlatAppearance.BorderSize = 0;
            this.UseVisualStyleBackColor = false;
            this.Cursor = System.Windows.Forms.Cursors.Hand;
            this.BackColor = System.Drawing.Color.FromArgb(24, 24, 34);
            this.BackNormal = System.Drawing.Color.FromArgb(24, 24, 34);
            this.BackHover = System.Drawing.Color.FromArgb(34, 34, 48);
            this.BackPress = System.Drawing.Color.FromArgb(20, 20, 30);
            this.BackIdle = System.Drawing.Color.FromArgb(16, 16, 22);
            this.BorderColor = System.Drawing.Color.FromArgb(48, 48, 64);
            this.BorderIdle = System.Drawing.Color.FromArgb(32, 32, 42);
            this.ForeNormal = System.Drawing.Color.FromArgb(228, 228, 240);
            this.ForeHover = System.Drawing.Color.White;
            this.ForeIdle = System.Drawing.Color.FromArgb(110, 110, 130);
        }

        public static System.Drawing.Drawing2D.GraphicsPath RoundRect(System.Drawing.Rectangle r, int radius)
        {
            var path = new System.Drawing.Drawing2D.GraphicsPath();
            int d = radius * 2;
            if (d <= 0 || r.Width <= d || r.Height <= d) { path.AddRectangle(r); return path; }
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseAllFigures();
            return path;
        }

        protected override void OnMouseEnter(System.EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(System.EventArgs e) { hover = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(System.Windows.Forms.MouseEventArgs e)
        {
            if (e.Button == System.Windows.Forms.MouseButtons.Left) { pressed = true; Invalidate(); }
            base.OnMouseDown(e);
        }
        protected override void OnMouseUp(System.Windows.Forms.MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(System.EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(System.Windows.Forms.PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            System.Drawing.Color back, fore, border;
            if (!Enabled) { back = BackIdle; fore = ForeIdle; border = BorderIdle; }
            else if (pressed) { back = BackPress; fore = ForeHover; border = BorderColor; }
            else if (hover) { back = BackHover; fore = ForeHover; border = BorderColor; }
            else { back = BackNormal; fore = ForeNormal; border = BorderColor; }

            var rect = new System.Drawing.Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = RoundRect(rect, Radius))
            {
                using (var br = new System.Drawing.SolidBrush(back)) { g.FillPath(br, path); }
                if (BorderWidth > 0 && border.A > 0)
                {
                    using (var pen = new System.Drawing.Pen(border, BorderWidth))
                    {
                        g.TranslateTransform(0.5f, 0.5f);
                        g.DrawPath(pen, path);
                        g.TranslateTransform(-0.5f, -0.5f);
                    }
                }
            }

            var flags = System.Windows.Forms.TextFormatFlags.VerticalCenter
                | System.Windows.Forms.TextFormatFlags.NoPadding
                | System.Windows.Forms.TextFormatFlags.EndEllipsis;
            System.Drawing.Rectangle tr;
            if (Align == "Left") { flags |= System.Windows.Forms.TextFormatFlags.Left; tr = new System.Drawing.Rectangle(12, 0, Width - 18, Height); }
            else if (Align == "Right") { flags |= System.Windows.Forms.TextFormatFlags.Right; tr = new System.Drawing.Rectangle(6, 0, Width - 18, Height); }
            else { flags |= System.Windows.Forms.TextFormatFlags.HorizontalCenter; tr = new System.Drawing.Rectangle(0, 0, Width, Height); }
            System.Windows.Forms.TextRenderer.DrawText(g, Text, Font, tr, fore, flags);
        }
    }

    // 无边框外壳窗口：边缘留白里画投影、内容是一张圆角卡片。
    // 拖动与缩放都由 PowerShell 侧驱动（见 GuiApp 的 Start-ShellDrag / 本类的鼠标消息重载）：
    // 拖动故意**不**用 SendMessage(WM_NCLBUTTONDOWN, HTCAPTION) 那条系统拖动循环 ——
    // 它依赖 P/Invoke 在运行时解析成功，解析不到时的表现是"窗口拖不动"，用户只能干瞪眼。
    public class ShellForm : System.Windows.Forms.Form
    {
        public int ResizeBand = 10;
        public int MarginFull = 12;

        [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);

        private bool resizing;
        private int dir;
        private System.Drawing.Point dragOrigin;
        private System.Drawing.Rectangle dragBounds;

        public ShellForm()
        {
            this.FormBorderStyle = System.Windows.Forms.FormBorderStyle.None;
            this.SetStyle(System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer, true);
            this.SetStyle(System.Windows.Forms.ControlStyles.AllPaintingInWmPaint, true);
        }

        protected override void OnHandleCreated(System.EventArgs e)
        {
            base.OnHandleCreated(e);
            try
            {
                var sc = System.Windows.Forms.Screen.FromHandle(this.Handle);
                this.MaximizedBounds = sc.WorkingArea;
            }
            catch { }
            try { int pref = 2; DwmSetWindowAttribute(this.Handle, 33, ref pref, 4); } catch { }
        }

        public bool IsMaxed { get { return this.WindowState == System.Windows.Forms.FormWindowState.Maximized; } }

        public void ToggleMax()
        {
            if (this.IsMaxed) { this.WindowState = System.Windows.Forms.FormWindowState.Normal; }
            else { this.WindowState = System.Windows.Forms.FormWindowState.Maximized; }
        }

        private int HitDir(System.Drawing.Point p)
        {
            int b = this.ResizeBand;
            if (b <= 0) { return 0; }
            bool l = p.X < b, r = p.X >= this.ClientSize.Width - b;
            bool t = p.Y < b, bo = p.Y >= this.ClientSize.Height - b;
            int d = 0;
            if (l) { d |= 1; } else if (r) { d |= 2; }
            if (t) { d |= 4; } else if (bo) { d |= 8; }
            return d;
        }

        private System.Windows.Forms.Cursor CursorFor(int d)
        {
            if ((d & (1 | 4)) == (1 | 4)) { return System.Windows.Forms.Cursors.SizeNWSE; }
            if ((d & (2 | 4)) == (2 | 4)) { return System.Windows.Forms.Cursors.SizeNESW; }
            if ((d & (1 | 8)) == (1 | 8)) { return System.Windows.Forms.Cursors.SizeNESW; }
            if ((d & (2 | 8)) == (2 | 8)) { return System.Windows.Forms.Cursors.SizeNWSE; }
            if ((d & (1 | 2)) != 0) { return System.Windows.Forms.Cursors.SizeWE; }
            if ((d & (4 | 8)) != 0) { return System.Windows.Forms.Cursors.SizeNS; }
            return System.Windows.Forms.Cursors.Default;
        }

        protected override void OnMouseDown(System.Windows.Forms.MouseEventArgs e)
        {
            int d = HitDir(e.Location);
            if (e.Button == System.Windows.Forms.MouseButtons.Left && d != 0 && !this.IsMaxed)
            {
                resizing = true;
                dir = d;
                dragOrigin = this.PointToScreen(e.Location);
                dragBounds = this.Bounds;
                this.Capture = true;
            }
            base.OnMouseDown(e);
        }

        protected override void OnMouseMove(System.Windows.Forms.MouseEventArgs e)
        {
            if (resizing)
            {
                System.Drawing.Point cur = this.PointToScreen(e.Location);
                int dx = cur.X - dragOrigin.X;
                int dy = cur.Y - dragOrigin.Y;
                System.Drawing.Rectangle r = dragBounds;
                int minW = this.MinimumSize.Width; if (minW <= 0) { minW = 240; }
                int minH = this.MinimumSize.Height; if (minH <= 0) { minH = 160; }

                if ((dir & 1) != 0)
                {
                    int nl = r.Left + dx;
                    int nw = r.Right - nl;
                    if (nw < minW) { nl = r.Right - minW; nw = minW; }
                    this.SetBounds(nl, this.Top, nw, this.Height);
                }
                else if ((dir & 2) != 0)
                {
                    int nw = r.Width + dx;
                    if (nw < minW) { nw = minW; }
                    this.Width = nw;
                }
                if ((dir & 4) != 0)
                {
                    int nt = r.Top + dy;
                    int nh = r.Bottom - nt;
                    if (nh < minH) { nt = r.Bottom - minH; nh = minH; }
                    this.SetBounds(this.Left, nt, this.Width, nh);
                }
                else if ((dir & 8) != 0)
                {
                    int nh = r.Height + dy;
                    if (nh < minH) { nh = minH; }
                    this.Height = nh;
                }
            }
            else
            {
                this.Cursor = CursorFor(HitDir(e.Location));
            }
            base.OnMouseMove(e);
        }

        protected override void OnMouseUp(System.Windows.Forms.MouseEventArgs e)
        {
            if (resizing)
            {
                resizing = false;
                dir = 0;
                this.Capture = false;
                this.Cursor = System.Windows.Forms.Cursors.Default;
            }
            base.OnMouseUp(e);
        }
    }
}
'@

function Initialize-GuiUiTypes {
    # 注册 GrGui.UiButton / GrGui.ShellForm。重复调用（同一会话里再 dot-source 一次）会
    # 报“类型已存在”，这里吞掉即可 —— 关键是不能让重复注册把界面启动打断。
    if ($script:UiTypesReady) { return $true }
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { return $false }
    try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { return $false }
    try {
        Add-Type -TypeDefinition $script:UiTypesSource `
            -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing', 'System') -ErrorAction Stop
    } catch {
        try { Add-Type -TypeDefinition $script:UiTypesSource -ErrorAction Stop } catch { }
    }
    try {
        $script:UiTypesReady = [bool]([type]::GetType('GrGui.UiButton, ' + [System.Reflection.Assembly]::GetAssembly([System.Windows.Forms.Form]).FullName, $false) -ne $null)
    } catch { $script:UiTypesReady = $false }
    if (-not $script:UiTypesReady) {
        try { $script:UiTypesReady = ([System.Management.Automation.PSTypeName]'GrGui.UiButton').Type -ne $null } catch { }
    }
    return $script:UiTypesReady
}

# ============================ 图标（自绘，不依赖字体 / 图标库）============================
# 全部按 24x24 viewBox 描边设计，运行时按目标尺寸等比缩放 —— 和参考项目的 SVG 图标一个思路，
# 但只用 GDI+ 的直线 / 多边形 / 椭圆拼，因为 Server Core 上不能假设有哪个图标字体、
# 也不该为一个图标引第三方库。找不到的名字画一个空框，不抛异常。

function Draw-UiIcon {
    param(
        [System.Drawing.Graphics]$Graphics,
        [string]$Name,
        [int]$X,
        [int]$Y,
        [int]$Size,
        [System.Drawing.Color]$Color,
        [double]$Stroke = 1.7
    )
    if (-not $Graphics -or $Size -le 0) { return }
    $g = $Graphics
    $saved = $g.Save()
    $pen = $null
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TranslateTransform($X, $Y)
        $k = $Size / 24.0
        $g.ScaleTransform($k, $k)
        # 缩放之后线宽也会被放大，所以要先除回去，线看起来才是 Stroke 像素
        $pen = New-Object System.Drawing.Pen($Color, ($Stroke / $k))
        $pen.StartCap = 'Round'
        $pen.EndCap   = 'Round'
        $pen.LineJoin = 'Round'

        $pts = { param([object[]]$a) $o = New-Object System.Collections.ArrayList; foreach ($p in $a) { [void]$o.Add((New-Object System.Drawing.PointF([single]$p[0], [single]$p[1]))) }; return [System.Drawing.PointF[]]$o.ToArray() }

        switch ($Name) {
            'env' {
                $g.DrawRectangle($pen, 2, 3, 20, 14)
                $g.DrawLine($pen, 8, 21, 16, 21)
                $g.DrawLine($pen, 12, 17, 12, 21)
            }
            'app' {
                $g.DrawPolygon($pen, (& $pts @(@(12, 2), @(21, 7), @(21, 17), @(12, 22), @(3, 17), @(3, 7))))
                $g.DrawLine($pen, 3, 7, 12, 12)
                $g.DrawLine($pen, 21, 7, 12, 12)
                $g.DrawLine($pen, 12, 12, 12, 22)
            }
            'store' {
                $g.DrawRectangle($pen, 3, 4, 18, 16)
                $g.DrawLine($pen, 12, 8, 12, 15)
                $g.DrawLine($pen, 9, 12, 12, 15)
                $g.DrawLine($pen, 15, 12, 12, 15)
            }
            'role' {
                $g.DrawPolygon($pen, (& $pts @(@(12, 2), @(22, 7), @(12, 12), @(2, 7))))
                $g.DrawLines($pen, (& $pts @(@(2, 12), @(12, 17), @(22, 12))))
                $g.DrawLines($pen, (& $pts @(@(2, 17), @(12, 22), @(22, 17))))
            }
            'monitor' {
                $g.DrawLines($pen, (& $pts @(@(22, 12), @(18, 12), @(15, 21), @(9, 3), @(6, 12), @(2, 12))))
            }
            'security' {
                $g.DrawPolygon($pen, (& $pts @(@(12, 2), @(20, 5), @(20, 12), @(12, 22), @(4, 12), @(4, 5))))
            }
            'beauty' {
                $g.DrawPolygon($pen, (& $pts @(@(12, 2.5), @(13.9, 8.1), @(19.5, 10), @(13.9, 11.9), @(12, 17.5), @(10.1, 11.9), @(4.5, 10), @(10.1, 8.1))))
                $g.DrawLine($pen, 19, 16.5, 19, 21.5)
                $g.DrawLine($pen, 16.5, 19, 21.5, 19)
            }
            'dsh' {
                $g.DrawRectangle($pen, 4, 6, 16, 14)
                $g.DrawRectangle($pen, 9, 11, 6, 6)
                $g.DrawLine($pen, 12, 2, 12, 6)
                $g.DrawLine($pen, 2, 9, 4, 9)
                $g.DrawLine($pen, 2, 15, 4, 15)
                $g.DrawLine($pen, 20, 9, 22, 9)
                $g.DrawLine($pen, 20, 15, 22, 15)
                $g.DrawLine($pen, 9, 20, 9, 22)
                $g.DrawLine($pen, 15, 20, 15, 22)
            }
            'tool' {
                $g.DrawLine($pen, 4, 7, 7, 7);   $g.DrawEllipse($pen, 7, 5, 4, 4);   $g.DrawLine($pen, 11, 7, 20, 7)
                $g.DrawLine($pen, 4, 12, 13, 12); $g.DrawEllipse($pen, 13, 10, 4, 4); $g.DrawLine($pen, 17, 12, 20, 12)
                $g.DrawLine($pen, 4, 17, 6, 17);  $g.DrawEllipse($pen, 6, 15, 4, 4);  $g.DrawLine($pen, 10, 17, 20, 17)
            }
            'more' {
                $g.DrawRectangle($pen, 3, 3, 7, 7)
                $g.DrawRectangle($pen, 14, 3, 7, 7)
                $g.DrawRectangle($pen, 14, 14, 7, 7)
                $g.DrawRectangle($pen, 3, 14, 7, 7)
            }
            'about' {
                $g.DrawEllipse($pen, 3, 3, 18, 18)
                $g.DrawLine($pen, 12, 11, 12, 16.5)
                $br = New-Object System.Drawing.SolidBrush($Color)
                try { $g.FillEllipse($br, 11.1, 6.8, 1.8, 1.8) } finally { $br.Dispose() }
            }
            'window-min' { $g.DrawLine($pen, 6, 12, 18, 12) }
            'window-max' { $g.DrawRectangle($pen, 6, 6, 12, 12) }
            'window-close' {
                $g.DrawLine($pen, 7, 7, 17, 17)
                $g.DrawLine($pen, 17, 7, 7, 17)
            }
            'chevron-up'   { $g.DrawLines($pen, (& $pts @(@(6, 15), @(12, 9), @(18, 15)))) }
            'chevron-down' { $g.DrawLines($pen, (& $pts @(@(6, 9), @(12, 15), @(18, 9)))) }
            default {
                $g.DrawRectangle($pen, 3, 3, 18, 18)
            }
        }
    } catch {
    } finally {
        if ($pen) { $pen.Dispose() }
        try { $g.Restore($saved) } catch { }
    }
}

# ============================ 窗口投影 ============================
function Invoke-UiShellShadow {
    # 在窗体的留白区里画一圈由外向内加深的投影，让中间的圆角卡片"浮"起来。
    # 做法是把若干层同心圆角矩形由大到小叠上去（每层一层黑、透明度递增），
    # 纯 GDI+，没有 DWM / 位图特效依赖 —— Server Core 上也能跑。
    param(
        [System.Drawing.Graphics]$Graphics,
        [int]$Width,
        [int]$Height,
        [int]$Band,
        [int]$Radius = 12,
        [int]$MaxAlpha = 26
    )
    if (-not $Graphics -or $Band -le 0 -or $Width -le 2 -or $Height -le 2) { return }
    try {
        $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        # i=0 是最外圈（几乎看不见），越靠近卡片叠的层越多、越深 —— 所以透明度随 i 递增。
        # 每层都很淡（MaxAlpha 是"每层"的上限），叠起来才是一圈柔和的渐变，不会出现硬边。
        for ($i = 0; $i -lt $Band; $i++) {
            $t = ($i + 1) / [double]$Band
            $a = [int]([Math]::Round($MaxAlpha * $t * $t))
            if ($a -le 0) { continue }
            $rect = New-Object System.Drawing.Rectangle($i, $i, ($Width - 2 * $i), ($Height - 2 * $i))
            if ($rect.Width -le 2 -or $rect.Height -le 2) { continue }
            $path = New-UiRoundPath -Width ($rect.Width - 1) -Height ($rect.Height - 1) -Radius ($Radius + ($Band - $i))
            $br   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($a, 0, 0, 0))
            try {
                $Graphics.TranslateTransform($rect.X, $rect.Y)
                $Graphics.FillPath($br, $path)
                $Graphics.TranslateTransform(-$rect.X, -$rect.Y)
            } finally {
                $br.Dispose(); $path.Dispose()
            }
        }
    } catch { }
}

# ============================ 页面进入动画 ============================
# 参考项目是"错峰淡入 + 轻微上移"。这里只做**页头文字淡入**：
#   - WinForms 的普通控件没有 Opacity，做整页淡入要么自绘整页（代价大、还容易闪）、
#     要么逐帧改子控件位置（会和自适应布局打架）；
#   - 更要紧的是目标环境是 Server Core，多数时候通过 RDP 看，逐帧动画只会更卡。
# 所以只保留"看得见又不费帧"的这一层：5 帧之内把页头的标题/说明由底色渐变回本色。

function Initialize-UiFadeTimer {
    # 定时器只建一次、只挂一个 Tick 处理器（每次进页面都 Add_Tick 会越挂越多）。
    # 处理器只认 $script: 作用域里的那几个变量 —— scriptblock 不是闭包，
    # 函数里的局部变量在回调里会解析成 $null（这个坑在查询宿主那边踩过）。
    if ($script:UiFadeTimer) { return }
    try {
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 22
        $t.Add_Tick({
            try {
                $items = @($script:UiFadeItems)
                if ($items.Count -eq 0) { $script:UiFadeTimer.Stop(); return }
                $frames = [int]$script:UiFadeFrames
                if ($frames -lt 1) { $frames = 5 }
                $script:UiFadeStep++
                $p = [Math]::Min(1.0, $script:UiFadeStep / [double]$frames)
                foreach ($it in $items) {
                    $a = $it.Ctl.ForeColor
                    $b = $it.Target
                    $it.Ctl.ForeColor = [System.Drawing.Color]::FromArgb(
                        [int]($a.R + ($b.R - $a.R) * $p),
                        [int]($a.G + ($b.G - $a.G) * $p),
                        [int]($a.B + ($b.B - $a.B) * $p))
                }
                if ($p -ge 1.0) {
                    $script:UiFadeTimer.Stop()
                    foreach ($it in $items) { $it.Ctl.ForeColor = $it.Target }
                }
            } catch { try { $script:UiFadeTimer.Stop() } catch { } }
        })
        $script:UiFadeTimer = $t
    } catch { }
}

function Invoke-UiPageFadeIn {
    param(
        [System.Windows.Forms.Control[]]$Controls,
        [int]$Frames = 5
    )
    try {
        if (-not $Controls -or $Controls.Count -eq 0) { return }
        $items = @()
        foreach ($c in $Controls) {
            if ($c -and $c.Parent) { $items += [pscustomobject]@{ Ctl = $c; Target = $c.ForeColor } }
        }
        if ($items.Count -eq 0) { return }
        Initialize-UiFadeTimer
        if (-not $script:UiFadeTimer) { return }
        $script:UiFadeItems  = $items
        $script:UiFadeFrames = [Math]::Max(1, $Frames)
        $script:UiFadeStep   = 0
        foreach ($it in $items) { $it.Ctl.ForeColor = $Pal.Bg }
        $script:UiFadeTimer.Stop()
        $script:UiFadeTimer.Start()
    } catch { }
}

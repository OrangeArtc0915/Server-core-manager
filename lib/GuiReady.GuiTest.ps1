# GuiReady GUI self-test: prove on the real machine whether GUI windows can be created and rendered

$Global:GuiReadyCapNativeLoaded = $false

function Initialize-GuiReadyCaptureNative {
    if ($Global:GuiReadyCapNativeLoaded) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class GuiReadyCap {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@ -ErrorAction Stop
        $Global:GuiReadyCapNativeLoaded = $true
        return $true
    } catch {
        Write-Log ('加载抓图 P/Invoke 失败: ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function Get-GuiReadyImageStats {
    param([Parameter(Mandatory = $true)]$Bitmap, [int]$Step = 8)

    $nonBlack = 0
    $samples  = 0
    $colors   = @{}
    for ($y = 0; $y -lt $Bitmap.Height; $y += $Step) {
        for ($x = 0; $x -lt $Bitmap.Width; $x += $Step) {
            $c = $Bitmap.GetPixel($x, $y)
            $samples++
            if ($c.R -gt 12 -or $c.G -gt 12 -or $c.B -gt 12) { $nonBlack++ }
            $k = '{0},{1},{2}' -f $c.R, $c.G, $c.B
            if ($colors.ContainsKey($k)) { $colors[$k]++ } else { $colors[$k] = 1 }
        }
    }
    $ratio = 0
    if ($samples -gt 0) { $ratio = [math]::Round(100 * $nonBlack / $samples, 1) }
    return [pscustomobject]@{
        Samples       = $samples
        NonBlack      = $nonBlack
        NonBlackRatio = $ratio
        DistinctColors= $colors.Count
    }
}

function Get-GuiReadyWindowList {
    param(
        [int]$SessionId = -1,
        [string]$ProcessMatch = ''
    )

    if (-not (Initialize-GuiReadyCaptureNative)) { return @() }
    $list = New-Object System.Collections.ArrayList

    $cb = [GuiReadyCap+EnumWindowsProc]{
        param([IntPtr]$h, [IntPtr]$p)
        if (-not [GuiReadyCap]::IsWindowVisible($h)) { return $true }

        $wpid = 0
        [void][GuiReadyCap]::GetWindowThreadProcessId($h, [ref]$wpid)
        $pr = $null
        try { $pr = Get-Process -Id $wpid -ErrorAction SilentlyContinue } catch { }
        if (-not $pr) { return $true }
        if ($SessionId -ge 0 -and $pr.SessionId -ne $SessionId) { return $true }
        if ($ProcessMatch -and $pr.ProcessName -notmatch $ProcessMatch) { return $true }

        $sb = New-Object System.Text.StringBuilder 512
        [void][GuiReadyCap]::GetWindowText($h, $sb, 512)
        $title = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($title)) { return $true }

        $r = New-Object GuiReadyCap+RECT
        [void][GuiReadyCap]::GetWindowRect($h, [ref]$r)
        [void]$list.Add([pscustomobject]@{
            Hwnd    = $h
            Pid     = $wpid
            Process = $pr.ProcessName
            Session = $pr.SessionId
            Title   = $title
            Width   = ($r.Right - $r.Left)
            Height  = ($r.Bottom - $r.Top)
        })
        return $true
    }
    [void][GuiReadyCap]::EnumWindows($cb, [IntPtr]::Zero)
    return @($list)
}

function Save-GuiReadyWindowCapture {
    param(
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    if (-not (Initialize-GuiReadyCaptureNative)) { return $null }
    if ($Window.Width -le 40 -or $Window.Height -le 40) { return $null }

    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $safe = ($Window.Title -replace '[^\w\u4e00-\u9fa5\-]', '_')
    if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
    $file = Join-Path $Directory ('{0}-{1}-{2}x{3}.png' -f $Window.Process, $safe, $Window.Width, $Window.Height)

    try {
        $bmp = New-Object System.Drawing.Bitmap($Window.Width, $Window.Height)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        $ok  = [GuiReadyCap]::PrintWindow($Window.Hwnd, $hdc, [uint32]2)
        $g.ReleaseHdc($hdc)
        $g.Dispose()
        $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
        $stats = Get-GuiReadyImageStats -Bitmap $bmp
        $bmp.Dispose()
        return [pscustomobject]@{
            Path          = $file
            PrintWindowOk = [bool]$ok
            SizeKB        = [math]::Round((Get-Item -LiteralPath $file).Length / 1KB, 1)
            Title         = $Window.Title
            Process       = $Window.Process
            Width         = $Window.Width
            Height        = $Window.Height
            Stats         = $stats
        }
    } catch {
        Write-Log ('抓图失败（{0}）: {1}' -f $Window.Title, $_.Exception.Message) 'WARN'
        return $null
    }
}

function Invoke-GuiReadyGuiSelfTest {
    param(
        [switch]$IncludeApps,
        [switch]$NoReport
    )

    Write-Head 'GUI 能力自检（在本机会话里实际创建窗口并抓图取证）'

    $res = [ordered]@{
        Timestamp      = (Get-Date).ToString('s')
        SessionId      = -1
        User           = ''
        UserInteractive= $false
        SessionName    = ''
        ScreenWidth    = 0
        ScreenHeight   = 0
        WinFormsOk     = $false
        WinFormsDetail = ''
        WpfOk          = $false
        WpfDetail      = ''
        Apps           = @()
        ScreenCaptureOk= $false
        ScreenCaptureDetail = ''
        Windows        = @()
        Captures       = @()
        GuiUsable      = $false
        Conclusion     = ''
    }

    try { $res.SessionId = (Get-Process -Id $PID).SessionId } catch { }
    try { $res.UserInteractive = [Environment]::UserInteractive } catch { }
    try { $res.User = (whoami) } catch { }
    try { $res.SessionName = [string][System.Environment]::GetEnvironmentVariable('SESSIONNAME') } catch { }
    try { [void][GuiReadyCap]::SetProcessDPIAware() } catch { }

    Write-Log ('会话ID={0}  用户={1}  UserInteractive={2}  SESSIONNAME={3}' -f $res.SessionId, $res.User, $res.UserInteractive, $res.SessionName) 'INFO'

    $sess = Get-GuiReadySessionInfo
    foreach ($r in $sess.Rows) {
        Write-Log ('  会话 {0,-14} 用户={1,-12} ID={2,-4} 状态={3} 活动={4}' -f $r.SessionName, $r.User, $r.Id, $r.State, $r.IsActive) 'INFO'
    }

    $formsLoaded = $false
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $formsLoaded = $true
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $res.ScreenWidth  = $vs.Width
        $res.ScreenHeight = $vs.Height
        Write-Log ('屏幕尺寸: {0}x{1}' -f $vs.Width, $vs.Height) 'INFO'
    } catch {
        $res.ScreenCaptureDetail = 'System.Windows.Forms 加载失败: ' + $_.Exception.Message
        Write-Log ('System.Windows.Forms 加载失败: ' + $_.Exception.Message) 'ERROR'
    }

    Write-Log '--- 测试 1/3：WinForms 建窗 ---' 'STEP'
    if ($formsLoaded) {
        try {
            $f = New-Object System.Windows.Forms.Form
            $f.Text = 'GuiReady WinForms 自检'
            $f.Width = 420
            $f.Height = 220
            $f.StartPosition = 'CenterScreen'
            $h = $f.Handle
            $f.Show()
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 700
            [System.Windows.Forms.Application]::DoEvents()
            $res.WinFormsOk = ($h -ne [IntPtr]::Zero -and $f.Visible)
            $res.WinFormsDetail = ('句柄={0} 可见={1} 尺寸={2}x{3}' -f $h, $f.Visible, $f.Width, $f.Height)
            Write-Log ('  WinForms: OK  ' + $res.WinFormsDetail) 'OK'
            $f.Close()
            $f.Dispose()
        } catch {
            $res.WinFormsOk = $false
            $res.WinFormsDetail = $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message
            Write-Log ('  WinForms: 失败  ' + $res.WinFormsDetail) 'ERROR'
        }
    } else {
        $res.WinFormsDetail = 'System.Windows.Forms 不可用'
        Write-Log '  WinForms: 跳过（Forms 不可用）' 'WARN'
    }

    Write-Log '--- 测试 2/3：WPF 建窗 ---' 'STEP'
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        $w = New-Object System.Windows.Window
        $w.Title = 'GuiReady WPF 自检'
        $w.Width = 420
        $w.Height = 220
        $w.Show()
        Start-Sleep -Milliseconds 900
        $res.WpfOk = [bool]$w.IsVisible
        $res.WpfDetail = ('可见={0} 渲染尺寸={1}' -f $w.IsVisible, $w.RenderSize.ToString())
        Write-Log ('  WPF: OK  ' + $res.WpfDetail) 'OK'
        $w.Close()
    } catch {
        $res.WpfOk = $false
        $res.WpfDetail = $_.Exception.GetType().FullName + ' :: ' + $_.Exception.Message
        Write-Log ('  WPF: 失败  ' + $res.WpfDetail) 'ERROR'
    }

    if ($IncludeApps) {
        Write-Log '--- 测试 3/3：启动真实 GUI 程序 ---' 'STEP'
        foreach ($p in @('notepad.exe', 'mmc.exe', 'perfmon.exe')) {
            $path = Join-Path (Join-Path $env:windir 'System32') $p
            $item = [ordered]@{ Name = $p; Exists = (Test-Path -LiteralPath $path); HasExited = $null; WindowHandle = 0; Title = ''; Note = '' }
            if (-not $item.Exists) {
                $item.Note = '文件不存在'
                Write-Log ('  {0,-14} 文件不存在' -f $p) 'WARN'
                $res.Apps += [pscustomobject]$item
                continue
            }
            try {
                $proc = Start-Process -FilePath $path -PassThru
                Start-Sleep -Seconds 5
                $proc.Refresh()
                if ($proc.HasExited) {
                    $item.HasExited = $true
                    $item.Note = 'ExitCode=' + $proc.ExitCode
                    Write-Log ('  {0,-14} 已退出 {1}' -f $p, $item.Note) 'WARN'
                } else {
                    $item.HasExited = $false
                    $item.WindowHandle = [int64]$proc.MainWindowHandle
                    $item.Title = $proc.MainWindowTitle
                    Write-Log ('  {0,-14} 运行中 PID={1} 窗口句柄={2} 标题={3}' -f $p, $proc.Id, $proc.MainWindowHandle, $proc.MainWindowTitle) 'OK'
                    [void]$proc.CloseMainWindow()
                    Start-Sleep -Seconds 2
                }
            } catch {
                $item.Note = $_.Exception.Message
                Write-Log ('  {0,-14} 启动异常 {1}' -f $p, $_.Exception.Message) 'ERROR'
            }
            $res.Apps += [pscustomobject]$item
        }
    }

    Write-Log '--- 抓图取证 ---' 'STEP'
    $capDir = $script:ReportDir
    if ($formsLoaded -and $res.ScreenWidth -gt 0 -and $res.ScreenHeight -gt 0) {
        try {
            $bmp = New-Object System.Drawing.Bitmap($res.ScreenWidth, $res.ScreenHeight)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
            $g.Dispose()
            $f = Join-Path $capDir ('guitest-screen-{0}.png' -f (Get-Date -Format 'HHmmss'))
            $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
            $st = Get-GuiReadyImageStats -Bitmap $bmp
            $bmp.Dispose()
            $res.ScreenCaptureOk = $true
            $res.ScreenCaptureDetail = ('已保存 {0}  非黑 {1}%  不同颜色 {2}' -f (Split-Path $f -Leaf), $st.NonBlackRatio, $st.DistinctColors)
            $res.Captures += [pscustomobject]@{ Kind = 'Screen'; Path = $f; NonBlackRatio = $st.NonBlackRatio; DistinctColors = $st.DistinctColors }
            Write-Log ('  整屏截图: ' + $res.ScreenCaptureDetail) 'OK'
        } catch {
            $res.ScreenCaptureOk = $false
            $res.ScreenCaptureDetail = $_.Exception.GetType().Name + ' :: ' + $_.Exception.Message
            Write-Log ('  整屏截图失败（会话可能没有活动显示设备）: ' + $res.ScreenCaptureDetail) 'WARN'
        }
    }

    $myProc = @(Get-Process -Id $PID -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
    $wins = Get-GuiReadyWindowList -SessionId $res.SessionId
    $res.Windows = @($wins)
    Write-Log ('  本会话可见顶层窗口: {0} 个' -f $wins.Count) 'INFO'
    foreach ($x in $wins) {
        Write-Log ('    {0,-22} {1,-34} {2}x{3}' -f $x.Process, $x.Title, $x.Width, $x.Height) 'INFO'
    }

    if (-not $res.ScreenCaptureOk) {
        Write-Log '  整屏截图不可用，改用 PrintWindow 逐窗口抓图（同会话内有效）' 'STEP'
        foreach ($x in $wins) {
            $c = Save-GuiReadyWindowCapture -Window $x -Directory $capDir
            if ($c) {
                $res.Captures += [pscustomobject]@{ Kind = 'Window'; Path = $c.Path; Title = $c.Title; Process = $c.Process; NonBlackRatio = $c.Stats.NonBlackRatio; DistinctColors = $c.Stats.DistinctColors; PrintWindowOk = $c.PrintWindowOk }
                Write-Log ('    {0,-18} {1,4}x{2,-4} {3,7:N1} KB  非黑 {4}%  颜色 {5}  {6}' -f $c.Process, $c.Width, $c.Height, $c.SizeKB, $c.Stats.NonBlackRatio, $c.Stats.DistinctColors, $c.Title) 'OK'
            }
        }
    }
    if ($res.Captures.Count -eq 0) {
        Write-Log '  没有拿到任何截图证据' 'WARN'
    }

    $anyRender = $false
    foreach ($c in $res.Captures) {
        if ($c.NonBlackRatio -ge 5 -and $c.DistinctColors -ge 3) { $anyRender = $true; break }
    }
    $windowOk = ($res.WinFormsOk -or $res.WpfOk)
    $res.GuiUsable = ($windowOk -and $anyRender)

    if (-not $windowOk) {
        $res.Conclusion = 'GUI 不可用：WinForms 与 WPF 都无法创建窗口。常见原因是没有安装 App Compatibility FOD，或当前不在交互式会话里。'
    } elseif (-not $anyRender) {
        $res.Conclusion = '窗口能创建，但抓图没有拿到有效渲染证据（可能是会话无活动显示设备 / RDP 已断开）。建议 RDP 连接后再测一次。'
    } else {
        $res.Conclusion = 'GUI 可用：窗口能创建并真实渲染（有截图与像素证据）。可以运行带界面的程序。'
    }

    Write-Head '自检结论'
    Write-Log ('WinForms : {0}' -f (Format-Bool $res.WinFormsOk)) 'INFO'
    Write-Log ('WPF      : {0}' -f (Format-Bool $res.WpfOk)) 'INFO'
    Write-Log ('整屏截图 : {0}' -f (Format-Bool $res.ScreenCaptureOk)) 'INFO'
    Write-Log ('抓图证据 : {0} 份' -f $res.Captures.Count) 'INFO'
    Write-Log ''
    Write-Log $res.Conclusion $(if ($res.GuiUsable) { 'OK' } else { 'WARN' })

    if (-not $NoReport) {
        Save-JsonReport -Object $res -Name 'guitest' | Out-Null
    }
    return $res
}

function Start-GuiReadyGuiSelfTest {
    param(
        [switch]$IncludeApps,
        [string]$AsUser = ''
    )

    $ctx = Get-GuiReadyExecutionContext
    $sess = Get-GuiReadySessionInfo

    if ($ctx.SessionId -gt 0) {
        Write-Log ('当前已在交互式会话（Session {0}），直接本机自检。' -f $ctx.SessionId) 'INFO'
        return Invoke-GuiReadyGuiSelfTest -IncludeApps:$IncludeApps
    }

    $target = $AsUser
    if (-not $target) {
        $cand = @($sess.ActiveWithUser | Select-Object -First 1)
        if ($cand.Count -eq 0) { $cand = @($sess.LoggedOn | Select-Object -First 1) }
        if ($cand.Count -gt 0) { $target = $cand[0].User }
    }

    if (-not $target) {
        Write-Log '当前在 Session 0（远程/服务上下文），而且没有任何已登录的用户会话，无法做 GUI 自检。' 'ERROR'
        Write-Log '请先通过 RDP 或控制台登录一个用户，再重试。' 'WARN'
        return $null
    }

    Write-Log ('当前在 Session 0，改到用户 {0} 的交互会话里执行自检。' -f $target) 'STEP'
    $body  = (Get-GuiReadyPreamble)
    $body += ('Invoke-GuiReadyGuiSelfTest -IncludeApps:$' + $IncludeApps.ToString().ToLower() + "`r`n")

    $t = Invoke-GuiReadyElevatedTask -Name 'GuiSelfTest' -Body $body -AsUser $target -TimeoutSeconds 600 -PollSeconds 10
    if ($t.Log) {
        Write-Log '--- 交互会话里的自检输出 ---' 'HEAD'
        foreach ($l in ($t.Log -split "`r?`n")) { if ($l.Trim()) { Write-Host $l } }
    }
    Write-Log ('自检任务结果: ' + $t.Result) $(if ($t.Result -like 'EXIT=OK*') { 'OK' } else { 'ERROR' })
    return $t
}

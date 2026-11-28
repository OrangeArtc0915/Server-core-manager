using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 页头：40px 图标块 + 标题 + 副标题，右侧留给本页操作按钮。
    // ============================================================
    internal sealed class PageHeader : UiControl
    {
        public string TitleText = vv;
        public string SubText = vv;
        public string Glyph = vv;
        public Color Accent = Theme.Accent;
        public readonly Panel Slot;   // 右侧操作区
        public int RightReserve;      // 「高级」按钮占掉的宽度，标题区要让开

        public PageHeader()
        {
            Height = 64;
            BackColor = Theme.Bg;
            Slot = new Panel { BackColor = Color.Transparent, Location = new Point(0, 12), Height = 34 };
            Slot.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            Controls.Add(Slot);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            // 构造期间 Height = 64 就会触发一次 OnResize，此时 Slot 还没建好
            if (Slot == null) return;
            Slot.Left = Math.Max(0, Width - Slot.Width - 4);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            // 页头也铺背景，别在整窗口的雾气中间留一块死黑
            var bd = Backdrop.Current;
            if (bd != null)
            {
                var form = FindForm();
                Size win = form != null ? form.ClientSize : ClientSize;
                bd.DrawAt(g, Backdrop.AbsoluteLocation(this), ClientSize, win);
            }

            var tile = new Rectangle(0, 10, 40, 40);
            using (var path = Draw.Round(tile, Theme.RButton))
            {
                using (var b = new SolidBrush(Theme.Mix(Theme.Bg, Accent, 0.20f))) g.FillPath(b, path);
                using (var pen = new Pen(Color.FromArgb(70, Accent), 1)) g.DrawPath(pen, path);
            }
            Icons.Draw(g, Glyph, new Rectangle(10, 20, 20, 20),
                       Theme.Mix(Accent, Color.White, 0.35f), 1.6f);

            int textW = Math.Max(80, Width - 52 - (Slot.Width > 0 ? Slot.Width + 12 : 0) - RightReserve);
            Draw.Text(g, TitleText, Theme.Font(15f, true), Theme.Text,
                      new Rectangle(52, 2, textW, 34));
            Draw.Text(g, SubText, Theme.Font(9.5f), Theme.Sub,
                      new Rectangle(52, 34, textW, 22));
        }
    }

    // ============================================================
    // 页面基类：统一页头 + 星空底 + 懒构建 + 响应式重排。
    // ============================================================
    internal abstract class PageBase : UiControl
    {
        public string Key = vv;
        public string TitleText = vv;
        public string Subtitle = vv;
        public string Glyph = vv;
        public Color Accent = Theme.Accent;
        public readonly PageHeader Head;

        // 「高级设置」：本页对应「全部功能」里的哪个动作分组（空 = 不显示按钮）
        private static readonly Dictionary<string, string> AdvancedMap = new Dictionary<string, string>
        {
            { vmonitorv,  v监控与诊断v },
            { vstorev,    v应用商店v },
            { venvv,      v探测与诊断v },
            { vrolev,     v角色与功能v },
            { vsecurityv, v安全与合规v },
            { vappv,      v使用与工具v },
            { vcatalogv,  v程序档案v },
            { vtoolsv,    vSCM附属v },
            { vruntimev,  v运行库v },
            { vdatabasev, v数据库v },
            { vtoolv,     v使用与工具v },
            { vbeautyv,   v终端美化v },
            { vupdatev,   vWindows 更新v },
            { vnetworkv,  v网络配置v },
            { vaccountsv, v本地账户v },
            { vservicesv, v服务管理v },
            { vfirewallv, v防火墙v },
            { vstoragev,  v存储与备份v },
            { vsystasksv, v系统任务v },
            { vlogsv,     v文件与日志v },
            { vroletoolsv, v角色工具v },
            { vnotifyv,   v通知v },
            { vmaintv,    v证书管理v },
            { vmetricsv,  v告警规则v },
            { vbatchv,    v批量管理v },
            { vscriptsv,  v脚本库v },
            { vdiagv,     v网络诊断v },
            { vsoftv,     v软件管理v },
            { vreportsv,  v报告中心v },
            { vtasksv,    v一键流程v },
            { vopsv,      v守护与计划v },
            { vauditv,    v配置备份v },
            { vhostsv,    v远程运维v },
            { vaboutv,    v安全与合规v }
        };

        // 由 Shell 注入：跳到「全部功能」并定位到某个动作分组
        public Action<string> OpenActionGroup;
        private UiButton _adv;
        private string _advGroup = vv;

        private bool _built;
        public Action<string> Logger;

        protected PageBase()
        {
            BackColor = Theme.Bg;
            Head = new PageHeader
            {
                TitleText = TitleText,
                SubText = Subtitle,
                Glyph = Glyph,
                Accent = Accent,
                Location = new Point(0, 0),
                Width = 900
            };
            Controls.Add(Head);

            _adv = new UiButton(v高级v, ButtonKind.Ghost, 58, 26);
            _adv.Visible = false;
            _adv.Click += (s, e) => OpenAdvanced();
            Head.Controls.Add(_adv);
            // 页面自己会改 Slot.Width（放状态胶囊），按钮位置跟着挪
            Head.Slot.SizeChanged += (s, e) => PlaceAdvanced();
        }

        private void PlaceAdvanced()
        {
            if (_adv == null) return;
            // 和页头右侧 Slot（Top=12 高 34，中心 29）对齐：26 高的按钮要落在 Top=16
            _adv.Top = 16;
            _adv.Left = Math.Max(0, Head.Width - Head.Slot.Width - 12 - _adv.Width);
            Head.RightReserve = _adv.Visible ? _adv.Width + 16 : 0;
        }

        private void OpenAdvanced()
        {
            if (_advGroup.Length == 0) return;
            Log(v[STEP] 本页高级设置：v + _advGroup);
            // 就地弹窗（不离开当前页）：内容就是「全部功能」的动作台，定位到本页对应的分组
            using (var dlg = new ActionDialog(_advGroup))
                dlg.ShowDialog(FindForm());
        }

        public void EnsureBuild()
        {
            if (_built) return;
            _built = true;
            Head.TitleText = TitleText;
            Head.SubText = Subtitle;
            Head.Glyph = Glyph;
            Head.Accent = Accent;

            string group;
            _advGroup = AdvancedMap.TryGetValue(Key, out group) ? group : vv;
            _adv.Visible = _advGroup.Length > 0;
            PlaceAdvanced();

            BuildContent();
        }

        // 每次切到本页都会触发（和 PowerShell 版一致：切页就重新拉数据）。
        // 各页的 OnActivated 都只做「读数据 + 刷新视图」，重复调用是安全的。
        // 但 A→B→A 连点会在 1 秒内起两个同样的子进程，加一个 1.5 秒节流。
        // CacheSeconds > 0 的页面（只读列表）在新鲜期内不再重复起子进程 ——
        // 各页自己的「刷新 / 重新审计 / 查询」按钮仍然立即取最新值。
        public int CacheSeconds;
        private long _lastActivateMs;
        public void Activate()
        {
            long now = Environment.TickCount;
            if (_lastActivateMs != 0 && now >= _lastActivateMs)
            {
                long elapsed = now - _lastActivateMs;
                if (elapsed < 1500) return;
                if (CacheSeconds > 0 && elapsed < CacheSeconds * 1000L) return;
            }
            _lastActivateMs = now;
            OnActivated();
        }

        protected virtual void OnActivated() { }

        // 后台线程回调切回 UI 线程；页面已释放时静默丢弃
        protected void SafeInvoke(Action action)
        {
            try
            {
                if (action == null || IsDisposed) return;
                if (InvokeRequired) BeginInvoke(action);
                else action();
            }
            catch { }
        }

        public void Relayout()
        {
            Head.Width = Math.Max(240, Width - 4);
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
            PlaceAdvanced();
            OnLayout();
        }

        protected abstract void BuildContent();
        protected virtual void OnLayout() { }

        // 一排按钮：放不下就自动换行，返回这一排一共多高。
        // 窄窗（1024×768）下按钮行会挤出右边界，统一走这里。
        protected static int LayoutButtonRow(List<UiButton> buttons, int width, int startTop,
                                             int gapX = 10, int gapY = 8)
        {
            if (buttons == null || buttons.Count == 0) return 0;
            int bx = 0, row = 0;
            foreach (var b in buttons)
            {
                if (!b.Visible) continue;
                if (bx > 0 && bx + b.Width > width) { bx = 0; row++; }
                b.Left = bx;
                b.Top = startTop + row * (b.Height + gapY);
                bx += b.Width + gapX;
            }
            return (row + 1) * (buttons[0].Height + gapY);
        }

        // 页面被 Dock 拉大 / 缩小时也要重排：ShowPage 里那次 Relayout 拿到的可能还是
        // 上一次的尺寸（首次显示的页面 Width 还是 0），不补这一手，页头会停在 240 宽。
        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (Head != null && Width > 0) Relayout();
        }

        // 入场：页头不动，内容块从下往上错峰升起（每块 12px，间隔 24ms）
        public void PlayEnter()
        {
            var targets = new List<Control>();
            var bases = new Dictionary<Control, int>();
            foreach (Control c in Controls)
            {
                if (c is PageHeader) continue;
                targets.Add(c);
                bases[c] = c.Top;
            }
            // 只让最上面 5 块参与入场：每多动一个控件，每帧就多一次窗口重绘
            // （实测每块约 1ms × 13 帧）。5 块已经足够看出「内容浮上来」。
            int count = Math.Min(targets.Count, 5);
            for (int i = 0; i < count; i++)
            {
                Control c = targets[i];
                int b = bases[c];
                int delay = i * 18;
                const int dur = 170;
                Anim.Run(dur + delay, v =>
                {
                    double raw = (v * (dur + delay) - delay) / (double)dur;
                    if (raw < 0) raw = 0;
                    double e = Ease.OutCubic(raw);
                    c.Top = b + (int)(10 * (1 - e));
                }, () => { if (!c.IsDisposed) c.Top = b; }, Ease.Linear);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var bd = Backdrop.Current;
            if (bd == null) { Draw.Starfield(e.Graphics, ClientRectangle); return; }
            var form = FindForm();
            Size win = form != null ? form.ClientSize : ClientSize;
            bd.DrawAt(e.Graphics, Backdrop.AbsoluteLocation(this), ClientSize, win);
        }

        protected void Log(string line)
        {
            if (Logger != null) Logger(line);
        }
    }

    // ============================================================
    // 主窗口：无边框 + 圆角 + 投影 + 标题栏 + 侧栏 + 页面宿主 + 日志栏
    // ============================================================
    internal sealed class Shell : Form
    {
        private const int MarginPx = 8;
        private const int TitleH = 46;
        private const int NavW = 208;
        private const int LogH = 156;

        private readonly Panel _title;
        private readonly Panel _nav;
        private readonly Panel _host;
        private readonly Panel _log;
        private UiButton _stopBtn;
        private UiButton _clearBtn, _copyBtn, _openBtn, _dirBtn, _foldBtn;
        private bool _logFolded;
        private bool _logSelecting;
        private int _logSelA = -1, _logSelB = -1;
        private int _logScroll;   // 0 = 停在最新一行；>0 表示往上翻了 N 行
        private readonly Timer _logTimer = new Timer { Interval = 50 };
        private bool _logDirty;
        private readonly Backdrop _backdrop;
        private readonly List<NavItem> _navItems = new List<NavItem>();
        private readonly Dictionary<string, PageBase> _pages = new Dictionary<string, PageBase>();
        private readonly List<string> _logLines = new List<string>();
        private PageBase _current;
        private string _currentKey = vv;
        private readonly string _startPage;

        private sealed class NavSpec
        {
            public string Key, Text, Glyph, Group;
            public NavSpec(string key, string text, string glyph, string group = vv)
            {
                Key = key; Text = text; Glyph = glyph; Group = group;
            }
        }

        // 与 PowerShell 版一致的页面，按工作流分组。
        private static readonly NavSpec[] NavSpecs =
        {
            new NavSpec(vmonitorv,  v总览v,         vmonitorv,  v工作区v),
            new NavSpec(vstorev,    v应用商店v,     vstorev,    v工作区v),
            new NavSpec(venvv,      v环境补全v,     venvv,      v环境与安全v),
            new NavSpec(vrolev,     v角色与功能v,   vrolev,     v环境与安全v),
            new NavSpec(vsecurityv, v安全基线v,     vsecurityv, v环境与安全v),
            new NavSpec(vappv,      v程序管理v,     vappv,      v程序v),
            new NavSpec(vtoolsv,    vSCM附属v,      vtoolv,     v程序v),
            new NavSpec(vcatalogv,  v兼容档案v,     vappv,      v程序v),
            new NavSpec(vruntimev,  v运行库v,       vruntimev,  v程序v),
            new NavSpec(vdatabasev, v数据库v,       vdatabasev, v程序v),
            new NavSpec(vtoolv,     v系统工具v,     vtoolv,     v程序v),
            new NavSpec(vbeautyv,   v终端美化v,     vbeautyv,   v程序v),
            new NavSpec(vupdatev,   v系统更新v,     vupdatev,   v系统管理v),
            new NavSpec(vnetworkv,  v网络配置v,     vnetworkv,  v系统管理v),
            new NavSpec(vdiagv,     v诊断工具v,     vnetworkv,  v系统管理v),
            new NavSpec(vaccountsv, v本地账户v,     vaccountsv, v系统管理v),
            new NavSpec(vservicesv, v服务管理v,     vservicesv, v系统管理v),
            new NavSpec(vsoftv,     v软件与权限v,   vsecurityv, v系统管理v),
            new NavSpec(vfirewallv, v防火墙v,       vsecurityv, v系统管理v),
            new NavSpec(vstoragev,  v存储与备份v,   vstoragev,  v系统管理v),
            new NavSpec(vsystasksv, v系统任务v,     vtasksv,    v系统管理v),
            new NavSpec(vroletoolsv,v角色工具v,     vrolev,     v系统管理v),
            new NavSpec(vnotifyv,   v通知v,         vnotifyv,   v系统管理v),
            new NavSpec(vmaintv,    v系统维护v,     vtoolv,     v系统管理v),
            new NavSpec(vlogsv,     v日志中心v,     vlogsv,     v运维v),
            new NavSpec(vmetricsv,  v监控告警v,     vmonitorv,  v运维v),
            new NavSpec(vbatchv,    v批量管理v,     vhostsv,    v运维v),
            new NavSpec(vscriptsv,  v脚本库v,       vtoolv,     v运维v),
            new NavSpec(vreportsv,  v报告中心v,     vlogsv,     v运维v),
            new NavSpec(vtasksv,    v任务中心v,     vtasksv,    v运维v),
            new NavSpec(vopsv,      v自动化v,       vopsv,      v运维v),
            new NavSpec(vauditv,    v操作审计v,     vauditv,    v运维v),
            new NavSpec(vhostsv,    v远程主机v,     vhostsv,    v运维v),
            new NavSpec(vmorev,     v全部功能v,     vmorev,     v系统v),
            new NavSpec(vsettingsv, v设置v,         vtoolv,     v系统v),
            new NavSpec(vaboutv,    v关于v,         vaboutv,    v系统v)
        };

        public Shell(string startPage = vmonitorv)
        {
            _startPage = string.IsNullOrEmpty(startPage) ? vmonitorv : startPage;
            Text = vSCM 运维控制台v;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Theme.Frame;
            DoubleBuffered = true;
            KeyPreview = true;
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);

            var wa = Screen.PrimaryScreen.WorkingArea;
            Width = Math.Min(1240, wa.Width);
            Height = Math.Min(820, wa.Height);
            MinimumSize = new Size(Math.Min(980, Width), Math.Min(640, Height));

            _title = new Panel { Dock = DockStyle.Top, Height = TitleH, BackColor = Theme.Panel };
            _nav   = new Panel { Dock = DockStyle.Left, Width = NavW, BackColor = Theme.Panel };
            _log   = new Panel { Dock = DockStyle.Bottom, Height = LogH, BackColor = Theme.Bg };
            _host  = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Bg };

            Controls.Add(_host);
            Controls.Add(_log);
            Controls.Add(_nav);
            Controls.Add(_title);

            _backdrop = new Backdrop();
            _backdrop.Tick = () =>
            {
                if (!Visible || WindowState == FormWindowState.Minimized) return;
                // 只重绘页面本身。标题栏 / 侧栏 / 日志栏的内容是静态的（卡片底不透明），
                // 跟着每 150ms 重画一次纯粹在白烧 CPU：实测三项合计 0.64+1.38+2.96ms/帧。
                if (_current != null) _current.Invalidate();
            };
            // 背景大图就绪后补一次全量重绘：首帧画布还没生成，标题/侧栏/日志栏
            // 当时只画了纯色底，不补这一手那几块就永远看不到背景图。
            _backdrop.Built = () =>
            {
                try
                {
                    BeginInvoke((Action)(() =>
                    {
                        _title.Invalidate();
                        _nav.Invalidate();
                        _log.Invalidate();
                        if (_current != null) _current.Invalidate();
                    }));
                }
                catch { }
            };

            EnableDoubleBuffer(_title);
            EnableDoubleBuffer(_nav);
            EnableDoubleBuffer(_log);
            EnableDoubleBuffer(_host);

            BuildTitle();
            BuildNav();
            BuildLog();
            RegisterPages();

            // 启动时的自动更新检查：先补上次失败的提示，再按设置决定要不要联网
            Shown += (s, e) => SelfUpdate.OnStartup(this);

            Paint += (s, e) =>
            {
                e.Graphics.Clear(Theme.Frame);
                var body = new Rectangle(MarginPx, MarginPx, Width - MarginPx * 2, Height - MarginPx * 2);
                Draw.ShellShadow(e.Graphics, body, Theme.RShell, 4);
                using (var path = Draw.Round(body, Theme.RShell))
                using (var pen = new Pen(Theme.BorderHi))
                    e.Graphics.DrawPath(pen, path);
            };

            Resize += (s, e) => { SetShellRegion(); if (_current != null) _current.Relayout(); };
            // 背景层只在窗口激活时跑，失焦停掉（后台不吃 CPU）
            Activated += (s, e) => { _backdrop.Start(); _log.Invalidate(); };
            Deactivate += (s, e) => _backdrop.Stop();
            FormClosed += (s, e) =>
            {
                Actions.Changed -= OnActionsChanged;
                try { _logTimer.Stop(); _logTimer.Dispose(); } catch { }
                _backdrop.Dispose();
            };
            Actions.Changed += OnActionsChanged;
            // 关窗留痕：排查「界面自己消失」时唯一能拿到的线索（正常关闭也会记一行）；
            // 另外有动作在跑时先确认一次 —— 点错关闭按钮会直接掐掉正在执行的任务。
            FormClosing += (s, e) =>
            {
                if (Actions.Busy && e.CloseReason == CloseReason.UserClosing)
                {
                    if (!Dialogs.Confirm(this, v还有动作在运行v,
                        v当前动作：v + Actions.CurrentId + v\n\n现在退出会终止它（连同子进程）。确定退出？v,
                        v退出v))
                    {
                        e.Cancel = true;
                        return;
                    }
                }
                try
                {
                    string dir = System.IO.Path.GetFullPath(
                        System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @v..\..\logsv));
                    System.IO.Directory.CreateDirectory(dir);
                    System.IO.File.AppendAllText(System.IO.Path.Combine(dir, vui-close.logv),
                        DateTime.Now.ToString(vyyyy-MM-dd HH:mm:ssv) + v  reason=v + e.CloseReason +
                        v  action=v + (Actions.Busy ? Actions.CurrentId : v-v) + v\r\nv);
                }
                catch { }

                // 关窗 = 回到命令行：界面关掉之后如果没有 shell，Server Core 会话看起来就像v死v了。
                // 三种关法（X / Alt+F4 / Esc）走同一处，系统关机 / 注销时不弹。
                if (!e.Cancel && !SelfUpdate.PendingRestart &&
                    e.CloseReason != CloseReason.WindowsShutDown &&
                    e.CloseReason != CloseReason.TaskManagerClosing)
                {
                    ExitShell.Open();
                }
            };

            // Esc 退出（和旧版一致）；对话框是独立窗口，不会抢这个键
            KeyPreview = true;
            KeyDown += (s, e) =>
            {
                if (e.Control && e.KeyCode == Keys.K)
                {
                    OpenPalette();
                    e.Handled = true;
                    return;
                }
                if (e.Control && e.KeyCode == Keys.C)
                {
                    CopyLogSelection();
                    e.Handled = true;
                    return;
                }
                if (e.KeyCode == Keys.Escape && !e.Handled)
                {
                    e.Handled = true;
                    Close();
                }
            };
            Shown += (s, e) =>
            {
                SetShellRegion();
                ShowPage(_startPage, false);
                _backdrop.Start();
                try
                {
                    // 诊断文件写到 state\，不要写进 ui\bin\ —— 那个目录在完整性清单范围内，
                    // 自己写一个清单外的文件会让用户一启动就v自检不通过v。
                    string dir = System.IO.Path.GetFullPath(
                        System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @v..\..\statev));
                    System.IO.Directory.CreateDirectory(dir);
                    System.IO.File.WriteAllText(System.IO.Path.Combine(dir, vstartup-ms.txtv),
                        (Environment.TickCount - Program.StartTick).ToString());
                }
                catch { }

                // 启动静默核对文件清单（旧界面每次启动都做，C# 版原来只有关于页手动按钮）。
                // 通过就安静；不通过才在日志里报警 —— 别每次开都刷两行。
                Bridge.Run(@vgui\Run-GuiReadyIntegrity.ps1v, vstatusv, null,
                    d =>
                    {
                        var data = d.ContainsKey(vDatav) ? d[vDatav] : null;
                        var map = data as Dictionary<string, object>;
                        if (map == null) return;
                        // 开发目录里没有 manifest.sha256（打包时才生成），这种情况不该报警
                        if (!Bridge.Bool(map, vManifestExistsv)) return;
                        bool ok = Bridge.Bool(map, vOkv);
                        int mod = Bridge.StrList(map, vModifiedv).Count;
                        int miss = Bridge.StrList(map, vMissingv).Count;
                        int extra = Bridge.StrList(map, vExtrav).Count;
                        if (!ok)
                            BeginInvoke((Action)(() => AppendLog(
                                v[WARN] 文件清单核对未通过：修改 v + mod + v / 缺失 v + miss +
                                v / 多出 v + extra + v；到「关于 → 完整性自检」看详情v)));
                    },
                    err => { }, 120000);
            };
        }

        // Ctrl+K：页面跳转面板（按组显示，可输入关键词过滤）
        private void OpenPalette()
        {
            var items = new List<KeyValuePair<string, string>>();
            foreach (var spec in NavSpecs)
            {
                if (!AppSettings.IsPageVisible(spec.Key)) continue;
                items.Add(new KeyValuePair<string, string>(spec.Key, spec.Group + v / v + spec.Text));
            }
            items.Add(new KeyValuePair<string, string>(vmorev, v系统 / 全部功能（动作台）v));
            using (var dlg = new PaletteDialog(items))
            {
                dlg.ShowDialog(this);
                if (!string.IsNullOrEmpty(dlg.SelectedKey)) ShowPage(dlg.SelectedKey, true);
            }
        }

        private void SetShellRegion()
        {
            using (var path = Draw.Round(new Rectangle(MarginPx, MarginPx,
                       Width - MarginPx * 2, Height - MarginPx * 2), Theme.RShell))
                Region = new Region(path);
        }

        // ---------------------------------------------------------- 标题栏
        private void BuildTitle()
        {
            var close = new IconButton(vaboutv, 30) { Location = new Point(Width - 44, 8) };
            close.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            close.Glyph = vaboutv;
            close.Click += (s, e) => Close();

            var max = new IconButton(vmorev, 30) { Location = new Point(Width - 82, 8) };
            max.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            max.Click += (s, e) => WindowState = WindowState == FormWindowState.Maximized
                                        ? FormWindowState.Normal : FormWindowState.Maximized;

            var min = new IconButton(vstopv, 30) { Location = new Point(Width - 120, 8) };
            min.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            min.Click += (s, e) => WindowState = FormWindowState.Minimized;

            _title.Controls.Add(close);
            _title.Controls.Add(max);
            _title.Controls.Add(min);

            Point dragStart = Point.Empty;
            bool dragging = false;
            _title.MouseDown += (s, e) => { dragging = true; dragStart = e.Location; };
            _title.MouseMove += (s, e) => { if (dragging) { Left += e.X - dragStart.X; Top += e.Y - dragStart.Y; } };
            _title.MouseUp += (s, e) => { dragging = false; };
            _title.DoubleClick += (s, e) =>
                WindowState = WindowState == FormWindowState.Maximized
                    ? FormWindowState.Normal : FormWindowState.Maximized;
            _title.Paint += (s, e) =>
            {
                var g = e.Graphics;
                PaintGlass(g, _title, 232);
                using (var pen = new Pen(Theme.Border))
                    g.DrawLine(pen, 0, _title.Height - 1, _title.Width, _title.Height - 1);
                using (var b = new SolidBrush(Theme.Accent))
                    g.FillRectangle(b, 18, 16, 3, 14);
                Draw.Text(g, vSCM 运维控制台v, Theme.Font(10f, true), Theme.Text,
                          new Rectangle(28, 0, 240, _title.Height));
                Draw.Text(g, vWindows Server Corev, Theme.Font(8.5f), Theme.Hint,
                          new Rectangle(152, 0, 220, _title.Height));
                if (_title.Width > 560)
                    Draw.Text(g, vv2.4v, Theme.Font(8.5f), Theme.Hint,
                              new Rectangle(_title.Width - 210, 0, 50, _title.Height),
                              ContentAlignment.MiddleRight);
            };
        }

        // 面板玻璃底：先取整窗背景的对应区域，再盖一层近乎不透明的面板色，
        // 这样背景雾气会从标题栏 / 侧栏 / 日志栏里隐约透出来（HMOL 的层次感）
        private static void PaintGlass(Graphics g, Control panel, int alpha)
        {
            var bd = Backdrop.Current;
            if (bd != null)
            {
                var form = panel.FindForm();
                Size win = form != null ? form.ClientSize : panel.ClientSize;
                bd.DrawAt(g, Backdrop.AbsoluteLocation(panel), panel.ClientSize, win);
            }
            using (var b = new SolidBrush(Color.FromArgb(alpha, Theme.Panel)))
                g.FillRectangle(b, 0, 0, panel.Width, panel.Height);
        }

        // Control.DoubleBuffered 是 protected，这里用反射给面板打开（背景每帧重绘，不开会闪）
        private static void EnableDoubleBuffer(Control c)
        {
            try
            {
                var pi = typeof(Control).GetProperty(vDoubleBufferedv,
                    System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                if (pi != null) pi.SetValue(c, true, null);
            }
            catch { }
        }

        // ---------------------------------------------------------- 侧栏
        private void BuildNav()
        {
            _nav.AutoScroll = true;
            _nav.Paint += (s, e) => PaintGlass(e.Graphics, _nav, 236);
            int y = 10;
            string lastGroup = null;

            foreach (var spec in NavSpecs)
            {
                if (!AppSettings.IsPageVisible(spec.Key)) continue;
                if (spec.Group != lastGroup)
                {
                    lastGroup = spec.Group;
                    var caption = new Label
                    {
                        Text = spec.Group,
                        Location = new Point(18, y),
                        AutoSize = true,
                        ForeColor = Theme.Hint,
                        BackColor = Theme.Panel,
                        Font = Theme.Font(8.25f)
                    };
                    _nav.Controls.Add(caption);
                    y += 22;
                }

                var item = new NavItem(spec.Text, spec.Glyph, spec.Key)
                {
                    Location = new Point(8, y),
                    Width = NavW - 16,
                    Height = 34
                };
                string key = spec.Key;
                item.Click += (s, e) => ShowPage(key);
                _navItems.Add(item);
                _nav.Controls.Add(item);
                y += 38;
            }
        }

        // 设置页改完版本策略后调用：清掉侧栏重画一遍，当前页被隐藏就回总览。
        public void RebuildNav()
        {
            for (int i = _nav.Controls.Count - 1; i >= 0; i--)
            {
                var c = _nav.Controls[i];
                _nav.Controls.RemoveAt(i);
                c.Dispose();
            }
            _navItems.Clear();
            BuildNav();
            _nav.Invalidate();

            if (!string.IsNullOrEmpty(_currentKey) && !AppSettings.IsPageVisible(_currentKey))
            {
                ShowPage(vmonitorv, false);
            }
            else
            {
                foreach (var n in _navItems) { n.Active = (n.PageKey == _currentKey); n.Invalidate(); }
            }
        }

        // ---------------------------------------------------------- 日志栏
        private void BuildLog()
        {
            _stopBtn = new UiButton(v停止v, ButtonKind.Danger, 60, 24) { Visible = false };
            _stopBtn.Click += (s, e) =>
            {
                Actions.Cancel();
                AppendLog(v[WARN] 已请求停止当前动作（连同子进程一起终止）v);
            };
            _log.Controls.Add(_stopBtn);

            // 日志工具条（PowerShell 版有、C# 版最早缺的那几个）
            _clearBtn = new UiButton(v清空v, ButtonKind.Ghost, 52, 24);
            _clearBtn.Click += (s, e) =>
            {
                _logLines.Clear();
                _logScroll = 0;
                _logSelA = _logSelB = -1;
                _log.Invalidate();
            };
            _copyBtn = new UiButton(v复制v, ButtonKind.Ghost, 52, 24);
            _copyBtn.Click += (s, e) => CopyLogSelection();
            _openBtn = new UiButton(v打开日志v, ButtonKind.Ghost, 76, 24);
            _openBtn.Click += (s, e) => OpenLatestLog();
            _dirBtn = new UiButton(v日志目录v, ButtonKind.Ghost, 76, 24);
            _dirBtn.Click += (s, e) => OpenLogFolder();
            _foldBtn = new UiButton(v收起v, ButtonKind.Ghost, 52, 24);
            _foldBtn.Click += (s, e) =>
            {
                _logFolded = !_logFolded;
                _foldBtn.Text = _logFolded ? v展开v : v收起v;
                _foldBtn.Invalidate();
                _log.Height = _logFolded ? 34 : LogH;
                _log.Invalidate();
                if (_current != null) _current.Relayout();
            };
            _log.Controls.Add(_clearBtn);
            _log.Controls.Add(_copyBtn);
            _log.Controls.Add(_openBtn);
            _log.Controls.Add(_dirBtn);
            _log.Controls.Add(_foldBtn);

            // 日志重绘合并：一批新行只画一次
            _logTimer.Tick += (s, e) =>
            {
                _logTimer.Stop();
                if (!_logDirty) return;
                _logDirty = false;
                _log.Invalidate();
            };

            _log.Resize += (s, e) => LayoutLogTools();

            // 滚轮回溯历史；按住左键拖选多行（Ctrl+C / 「复制」按钮拿走），双击复制单行
            _log.MouseWheel += (s, e) =>
            {
                int max = Math.Max(0, _logLines.Count - LogVisibleLines());
                int next = _logScroll + (e.Delta > 0 ? 1 : -1);
                if (next < 0) next = 0;
                if (next > max) next = max;
                if (next != _logScroll) { _logScroll = next; _log.Invalidate(); }
            };
            _log.MouseDown += (s, e) =>
            {
                if (e.Button != MouseButtons.Left) return;
                int idx = LogIndexAt(e.Y);
                if (idx < 0) return;
                _logSelA = _logSelB = idx;
                _logSelecting = true;
                _log.Invalidate();
            };
            _log.MouseMove += (s, e) =>
            {
                if (!_logSelecting) return;
                int idx = LogIndexAt(e.Y);
                if (idx >= 0 && idx != _logSelB) { _logSelB = idx; _log.Invalidate(); }
            };
            _log.MouseUp += (s, e) => _logSelecting = false;
            _log.MouseDoubleClick += (s, e) =>
            {
                int idx = LogIndexAt(e.Y);
                if (idx < 0 || idx >= _logLines.Count) return;
                try
                {
                    Clipboard.SetText(_logLines[idx]);
                    AppendLog(v[INFO] 已复制该行到剪贴板v);
                }
                catch { }
            };

            _log.Paint += (s, e) =>
            {
                var g = e.Graphics;
                PaintGlass(g, _log, 236);
                using (var pen = new Pen(Theme.Border))
                    g.DrawLine(pen, 0, 0, _log.Width, 0);
                Draw.Text(g, v运行日志v, Theme.Font(9f, true), Theme.Hint,
                          new Rectangle(16, 6, 90, 22));

                if (Actions.Busy)
                {
                    int right = _stopBtn.Visible ? _stopBtn.Left - 12 : _log.Width - 16;
                    Draw.Text(g, v动作运行中 · v + Actions.CurrentId,
                              Theme.Font(9f), Theme.AccentHi,
                              new Rectangle(Math.Max(120, right - 380), 6, 380, 22),
                              ContentAlignment.MiddleRight);
                }

                if (_logFolded) return;

                int y = 34;
                int width = Math.Max(80, _log.Width - 32);
                int start = Math.Max(0, _logLines.Count - LogVisibleLines() - _logScroll);
                int selFrom = Math.Min(_logSelA, _logSelB);
                int selTo = Math.Max(_logSelA, _logSelB);
                for (int i = start; i < _logLines.Count && y + 20 <= _log.Height; i++)
                {
                    var rect = new Rectangle(16, y, width, 20);
                    if (_logSelA >= 0 && i >= selFrom && i <= selTo)
                        using (var b = new SolidBrush(Theme.AccentDim))
                            g.FillRectangle(b, 8, y - 1, _log.Width - 16, 21);
                    DrawLogLine(g, _logLines[i], rect);
                    y += 21;
                }
            };
        }

        private const int LogRowH = 21;

        private int LogVisibleLines()
        {
            return Math.Max(1, (_log.Height - 38) / LogRowH);
        }

        private int LogIndexAt(int y)
        {
            if (_logFolded || y < 34) return -1;
            int start = Math.Max(0, _logLines.Count - LogVisibleLines() - _logScroll);
            int idx = start + (y - 34) / LogRowH;
            return (idx >= 0 && idx < _logLines.Count) ? idx : -1;
        }

        private void LayoutLogTools()
        {
            int right = _log.Width - 14;
            foreach (var b in new[] { _foldBtn, _dirBtn, _openBtn, _copyBtn, _clearBtn })
            {
                if (b == null) continue;
                right -= b.Width;
                b.Location = new Point(Math.Max(8, right), 5);
                right -= 6;
            }
            _stopBtn.Location = new Point(Math.Max(8, right - _stopBtn.Width), 5);
        }

        // 复制选中的日志行；没选就复制当前可见的全部（排障时经常要整段贴出来）
        private void CopyLogSelection()
        {
            if (_logLines.Count == 0) return;
            int from, to;
            if (_logSelA >= 0)
            {
                from = Math.Min(_logSelA, _logSelB);
                to = Math.Max(_logSelA, _logSelB);
            }
            else
            {
                from = 0;
                to = _logLines.Count - 1;
            }
            try
            {
                var sb = new System.Text.StringBuilder();
                for (int i = from; i <= to && i < _logLines.Count; i++) sb.AppendLine(_logLines[i]);
                Clipboard.SetText(sb.ToString());
                AppendLog(v[INFO] 已复制 v + (to - from + 1) + v 行日志到剪贴板v);
            }
            catch { }
        }

        // 打开 logs\ 里最新的一个日志文件（每次动作都会写 gui-<动作>-<时间>.log）
        private void OpenLatestLog()
        {
            string dir = BridgeLogDir();
            try
            {
                var files = new System.IO.DirectoryInfo(dir).GetFiles(v*.logv);
                if (files.Length == 0) { OpenLogFolder(); return; }
                System.IO.FileInfo newest = files[0];
                foreach (var f in files) if (f.LastWriteTime > newest.LastWriteTime) newest = f;
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = newest.FullName,
                    UseShellExecute = true
                });
                AppendLog(v[INFO] 已打开 v + newest.Name);
            }
            catch (Exception ex)
            {
                AppendLog(v[WARN] 打开日志失败: v + ex.Message);
            }
        }

        private void OpenLogFolder()
        {
            try
            {
                System.Diagnostics.Process.Start(vexplorer.exev, BridgeLogDir());
            }
            catch (Exception ex)
            {
                AppendLog(v[WARN] 打开日志目录失败: v + ex.Message);
            }
        }

        private static string BridgeLogDir()
        {
            string dir = System.IO.Path.Combine(Bridge.Root, vlogsv);
            try { System.IO.Directory.CreateDirectory(dir); } catch { }
            return dir;
        }

        // [18:02:11] [STEP] 消息 -> 时间灰、级别按语义着色、消息浅色
        private static void DrawLogLine(Graphics g, string line, Rectangle r)
        {
            string stamp = vv;
            string level = vv;
            string msg = line;
            if (line != null && line.Length > 4 && line[0] == '[')
            {
                int p1 = line.IndexOf(v] [v, StringComparison.Ordinal);
                if (p1 > 0)
                {
                    stamp = line.Substring(1, p1 - 1);
                    int p2 = line.IndexOf(v] v, p1 + 2, StringComparison.Ordinal);
                    if (p2 > 0)
                    {
                        level = line.Substring(p1 + 3, p2 - p1 - 3);
                        msg = line.Substring(p2 + 2);
                    }
                }
            }

            int x = r.X;
            if (stamp.Length > 0)
            {
                Draw.Text(g, stamp, Theme.Mono(8.5f), Theme.Hint, new Rectangle(x, r.Y, 62, r.Height));
                x += 66;
                Draw.Text(g, level, Theme.Mono(8.5f, true), LogLevelColor(level),
                          new Rectangle(x, r.Y, 48, r.Height));
                x += 52;
            }
            Draw.Text(g, msg, Theme.Mono(8.75f),
                      level == vERRORv ? Theme.Err : Theme.Sub,
                      new Rectangle(x, r.Y, Math.Max(20, r.Right - x), r.Height));
        }

        private static Color LogLevelColor(string level)
        {
            switch (level)
            {
                case vOKv: return Theme.Ok;
                case vWARNv: return Theme.Warn;
                case vERRORv: return Theme.Err;
                case vSTEPv: return Theme.AccentHi;
                case vHEADv: return Theme.Text;
                case vDRYv: return Theme.Hex(v#C084FCv);
                default: return Theme.Hint;
            }
        }

        private void OnActionsChanged()
        {
            try
            {
                if (IsDisposed || !IsHandleCreated) return;
                BeginInvoke((Action)(() =>
                {
                    bool busy = Actions.Busy;
                    if (_stopBtn.Visible != busy)
                    {
                        _stopBtn.Visible = busy;
                        if (busy) _stopBtn.BringToFront();
                    }
                    _log.Invalidate();
                }));
            }
            catch { }
        }

        public void AppendLog(string line)
        {
            _logLines.Add(line);
            // 3500 行 ≈ 旧 PowerShell 版的历史深度：动作输出几百行也不会把前面的冲掉
            if (_logLines.Count > 3500)
            {
                _logLines.RemoveAt(0);
                // 行号整体前移一位，选中区间跟着挪，否则高亮会错位
                if (_logSelA > 0) _logSelA--;
                if (_logSelB > 0) _logSelB--;
                if (_logSelA == 0 && _logSelB == 0) _logSelA = _logSelB = -1;
            }
            if (_logScroll > 0) _logScroll++;          // 用户正翻旧行时保持视口不动
            if (_logScroll > Math.Max(0, _logLines.Count - LogVisibleLines()))
                _logScroll = Math.Max(0, _logLines.Count - LogVisibleLines());
            // 动作输出是逐行回来的，一条一重绘会白烧 CPU（每帧约 3ms）。
            // 这里合并成最多 20fps：新行只置脏，50ms 后统一画一次。
            _logDirty = true;
            if (!_logTimer.Enabled) _logTimer.Start();
        }

        // ---------------------------------------------------------- 页面
        // 页面改成「第一次进入才构造」：16 个页面一次性建完要 60-70ms，
        // 而绝大多数会话只会打开其中几页，启动时没必要把这些控件全建出来。
        private readonly Dictionary<string, Func<PageBase>> _factories =
            new Dictionary<string, Func<PageBase>>();

        private void RegisterPages()
        {
            Register(vmonitorv,  () => new OverviewPage());
            Register(venvv,      () => new EnvPage());
            Register(vtasksv,    () => new TasksPage());
            Register(vopsv,      () => new OpsPage());
            Register(vstorev,    () => new StorePage());
            Register(vappv,      () => new AppPage());
            Register(vtoolsv,    () => new ToolsPage());
            Register(vcatalogv,  () => new CatalogPage());
            Register(vruntimev,  () => new RuntimePage());
            Register(vdatabasev, () => new DatabasePage());
            Register(vauditv,    () => new AuditPage());
            Register(vhostsv,    () => new HostsPage());
            Register(vrolev,     () => new RolePage());
            Register(vsecurityv, () => new SecurityPage());
            Register(vtoolv,     () => new ToolPage());
            Register(vbeautyv,   () => new BeautyPage());
            Register(vupdatev,   () => new UpdatePage());
            Register(vnetworkv,  () => new NetworkPage());
            Register(vaccountsv, () => new AccountsPage());
            Register(vservicesv, () => new ServicesPage());
            Register(vfirewallv, () => new FirewallPage());
            Register(vstoragev,  () => new StoragePage());
            Register(vsystasksv, () => new SysTasksPage());
            Register(vlogsv,     () => new LogsPage());
            Register(vroletoolsv, () => new RoleToolsPage());
            Register(vnotifyv,   () => new NotifyPage());
            Register(vmaintv,    () => new MaintPage());
            Register(vmetricsv,  () => new MetricsPage());
            Register(vbatchv,    () => new BatchPage());
            Register(vscriptsv,  () => new ScriptsPage());
            Register(vdiagv,     () => new DiagPage());
            Register(vsoftv,     () => new SoftwarePage());
            Register(vreportsv,  () => new ReportsPage());
            Register(vmorev,     () => new MorePage());
            Register(vsettingsv, () => new SettingsPage());
            Register(vaboutv,    () => new AboutPage());
        }

        private void Register(string key, Func<PageBase> factory)
        {
            _factories[key] = factory;
        }

        // 只读列表页的新鲜期（秒）：在这段时间内切回来直接用上次数据，
        // 不再起子进程重查（角色列表一次 DISM 查询约 1-2 秒）。
        // 总览页要实时，所以是 0。
        private static int CacheSecondsFor(string key)
        {
            switch (key)
            {
                case vrolev: return 10;
                case vsecurityv: return 20;
                case vlogsv: return 10;
                case vtasksv: return 10;
                case vopsv: return 10;
                case vauditv: return 10;
                case vhostsv: return 10;
                case vappv: return 15;
                case vtoolsv: return 30;
                case vcatalogv: return 15;
                case vruntimev: return 20;
                case vdatabasev: return 15;
                case vstorev: return 20;
                case venvv: return 20;
                case vbeautyv: return 30;
                case vupdatev: return 60;
                case vnetworkv: return 15;
                case vaccountsv: return 15;
                case vservicesv: return 20;
                case vfirewallv: return 30;
                case vstoragev: return 20;
                case vsystasksv: return 20;
                case vroletoolsv: return 30;
                case vnotifyv: return 15;
                case vmaintv: return 30;
                case vmetricsv: return 15;
                case vbatchv: return 30;
                case vscriptsv: return 60;
                case vdiagv: return 15;
                case vsoftv: return 20;
                case vreportsv: return 30;
                case vtoolv: return 60;
                case vmorev: return 60;
                default: return 0;
            }
        }

        private PageBase EnsurePage(string key)
        {
            PageBase page;
            if (_pages.TryGetValue(key, out page)) return page;

            Func<PageBase> factory;
            if (!_factories.TryGetValue(key, out factory)) return null;

            page = factory();
            page.CacheSeconds = CacheSecondsFor(key);
            page.Visible = false;
            page.Dock = DockStyle.Fill;
            page.Logger = AppendLog;
            page.OpenActionGroup = OpenActionGroup;
            _pages[key] = page;
            _host.Controls.Add(page);
            return page;
        }

        // 页头「高级」按钮：跳到「全部功能」并定位到对应分组
        public void OpenActionGroup(string group)
        {
            var page = EnsurePage(vmorev);
            if (page == null) return;
            ShowPage(vmorev);
            var more = page as MorePage;
            if (more != null) more.FocusGroup(group);
        }

        public void ShowPage(string key, bool animate = true)
        {
            var page = EnsurePage(key);
            if (page == null) return;
            if (_current == page) return;

            page.EnsureBuild();
            foreach (var kv in _pages) kv.Value.Visible = false;
            page.Visible = true;
            page.BringToFront();
            _current = page;
            _currentKey = key;

            foreach (var n in _navItems) { n.Active = (n.PageKey == key); n.Invalidate(); }

            page.Relayout();
            page.Activate();
            // 页面本身是 Dock=Fill，动 Top 会被布局抵消；入场交给内容块的错峰上浮
            if (animate) page.PlayEnter();
        }

        protected override void WndProc(ref Message m)
        {
            const int WM_NCHITTEST = 0x84;
            const int HTCLIENT = 1;

            if (m.Msg == WM_NCHITTEST && WindowState == FormWindowState.Normal)
            {
                base.WndProc(ref m);
                if ((int)m.Result == HTCLIENT)
                {
                    var p = PointToClient(new Point(m.LParam.ToInt32()));
                    int band = 6;
                    bool left = p.X <= band, right = p.X >= ClientSize.Width - band;
                    bool top = p.Y <= band, bottom = p.Y >= ClientSize.Height - band;
                    if (left && top) m.Result = (IntPtr)13;
                    else if (right && top) m.Result = (IntPtr)14;
                    else if (left && bottom) m.Result = (IntPtr)16;
                    else if (right && bottom) m.Result = (IntPtr)17;
                    else if (left) m.Result = (IntPtr)10;
                    else if (right) m.Result = (IntPtr)11;
                    else if (top) m.Result = (IntPtr)12;
                    else if (bottom) m.Result = (IntPtr)15;
                }
                return;
            }
            base.WndProc(ref m);
        }
    }

    internal static class Program
    {
        public static long StartTick;

        [STAThread]
        private static void Main(string[] args)
        {
            StartTick = Environment.TickCount;
            // 崩溃日志写到 logs\（清单覆盖 ui\bin\，往里写文件会让用户的完整性自检永远报警）
            string log = System.IO.Path.GetFullPath(
                System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @v..\..\logs\ui-error.logv));
            try
            {
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(log));
            }
            catch
            {
                log = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, verror.txtv);
            }
            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.ThreadException += (s, e) => Dump(log, e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => Dump(log, e.ExceptionObject as Exception);

                // 版本策略：首次启动问一次 2019+ / 2019-，之后读 state\ui-settings.json
                AppSettings.Load();
                if (!AppSettings.FirstRunDone)
                {
                    string pick = vv;
                    using (var dlg = new FirstRunDialog())
                    {
                        dlg.ShowDialog();
                        pick = dlg.Result;
                    }
                    // 关窗视为采用高亮默认项：按探测结果走
                    if (!string.IsNullOrEmpty(pick)) AppSettings.Tier = pick;
                    else AppSettings.Tier = AppSettings.DetectedBuild >= AppSettings.ModernBuild
                                                ? AppSettings.Modern
                                                : (AppSettings.DetectedBuild > 0 && AppSettings.DetectedBuild <= AppSettings.OldBuild
                                                    ? AppSettings.Old : AppSettings.Legacy);
                    AppSettings.HideWacDuplicates = AppSettings.IsModern;
                    AppSettings.FirstRunDone = true;
                    AppSettings.Save();
                }

                Application.Run(new Shell(args != null && args.Length > 0 ? args[0] : vmonitorv));
            }
            catch (Exception ex)
            {
                Dump(log, ex);
            }
        }

        private static void Dump(string path, Exception ex)
        {
            try
            {
                System.IO.File.AppendAllText(path,
                    DateTime.Now.ToString(vHH:mm:ssv) + v v +
                    (ex == null ? v(null)v : ex.ToString()) + Environment.NewLine + Environment.NewLine);
            }
            catch { }
        }
    }

    // ============================================================
    // 退出界面 = 回到命令行。
    // Server Core 没有桌面，界面关掉之后如果什么都不剩，会话看起来就像v死了v。
    // 装了美化终端就起 scm-term，没装就起普通 PowerShell（-NoExit，工作目录是工具目录）。
    // ============================================================
    internal static class ExitShell
    {
        private static bool _opened;

        public static void Open()
        {
            if (_opened) return;
            _opened = true;
            try
            {
                if (Environment.GetEnvironmentVariable(vSCM_NO_EXIT_TERMv) == v1v) return;
                if (System.Diagnostics.Process.GetCurrentProcess().SessionId <= 0) return;

                string root = Bridge.Root;
                string term = System.IO.Path.Combine(root, @vbin\scm-term.cmdv);
                string sysTerm = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows), @vSystem32\scm-term.cmdv);

                string file, args;
                if (System.IO.File.Exists(term)) { file = term; args = vv; }
                else if (System.IO.File.Exists(sysTerm)) { file = sysTerm; args = vv; }
                else { file = vpowershell.exev; args = v-NoLogo -NoExitv; }

                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(file)
                {
                    Arguments = args,
                    WorkingDirectory = root,
                    UseShellExecute = true
                });
            }
            catch { }
        }
    }
}

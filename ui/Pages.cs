using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 页面：阶段 1 先做 4 个（总览 / 环境 / 日志 / 任务），
    // 其余页在阶段 2 用同一套 PageBase 补齐。
    // 数据暂时是示例值，阶段 3 用 runner 子进程回填。
    // ============================================================
    internal sealed class OverviewPage : PageBase
    {
        private readonly List<StatCard> _cards = new List<StatCard>();
        private readonly TrendStrip[] _trends = new TrendStrip[3];
        private readonly DataTable _table;
        private readonly Pill _live;
        private readonly Panel _bar;
        private readonly Panel _views;
        private readonly List<UiButton> _barButtons = new List<UiButton>();
        private readonly UiButton[] _viewButtons = new UiButton[3];
        private int _thCpu = 90;
        private int _thMem = 90;
        private int _thDisk = 90;
        // 实时刷新：PowerShell 版是 5 秒一轮，C# 版最初只在进页面时取一次，
        // 结果就是「数字不动、趋势永远一条直线」。
        private readonly Timer _timer = new Timer { Interval = 5000 };
        private bool _refreshing;
        // 快照（服务 / 事件 / 进程）比 metrics 重得多：进页取一次，之后每 12 轮
        // 轻量采样（60 秒）补一次，也可以手动点「刷新」。
        private bool _snapBusy;
        private int _ticks;
        private int _view;                    // 0=关键服务 1=最近事件 2=占用进程
        private string _svcSig = "";
        private readonly List<Dictionary<string, object>> _services = new List<Dictionary<string, object>>();
        private readonly List<Dictionary<string, object>> _events = new List<Dictionary<string, object>>();
        private readonly List<Dictionary<string, object>> _procs = new List<Dictionary<string, object>>();
        private readonly Dictionary<string, bool> _alertOn = new Dictionary<string, bool>();

        public OverviewPage()
        {
            Key = "monitor";
            TitleText = "总览";
            Subtitle = "CPU / 内存 / 磁盘 / 关键服务的实时快照，数据每 5 秒刷新一次。";
            Glyph = "monitor";
            Accent = Theme.AccentOf("monitor");

            _live = new Pill("采集中", "Info");
            Head.Slot.Controls.Add(_live);
            Head.Slot.Width = 90;
            _live.Left = 0;

            string[][] stats =
            {
                new[] { "CPU 占用", "—",  "#409EFF", "8 核 · 采样 1s" },
                new[] { "内存占用", "—",  "#22D3EE", "物理内存占用率" },
                new[] { "系统盘",   "—",  "#FBBF24", "系统盘已用" },
                new[] { "关键服务", "—",  "#34D399", "WinRM · LanmanServer" }
            };
            foreach (var s in stats)
            {
                var c = new StatCard(s[0], s[1], Theme.Hex(s[2]), s[3]);
                _cards.Add(c);
                Controls.Add(c);
            }

            // 趋势条（与 PowerShell 版一致：CPU / 内存 / 系统盘 三条曲线）
            string[] tCaps = { "CPU 趋势", "内存趋势", "系统盘趋势" };
            Color[] tCols = { Theme.Accent, Theme.Hex("#22D3EE"), Theme.Warn };
            for (int i = 0; i < _trends.Length; i++)
            {
                _trends[i] = new TrendStrip(tCaps[i], tCols[i]);
                Controls.Add(_trends[i]);
            }

            _bar = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_bar);
            // 刷新 = 轻量指标 + 完整快照一起重取（PowerShell 版的手动刷新）
            AddBarButton("刷新", ButtonKind.Primary, 88, () => { RefreshMetrics(); LoadSnapshot(true); });
            // 服务操作作用于「关键服务」视图里选中的那一行
            AddBarButton("启动", ButtonKind.Normal, 88, () => ServiceAction("Start", 1));
            AddBarButton("重启", ButtonKind.Normal, 88, () => ServiceAction("Restart", 3));
            AddBarButton("停止", ButtonKind.Danger, 88, () => ServiceAction("Stop", 2));
            AddBarButton("TUI 监控", ButtonKind.Normal, 100, OpenTui);
            AddBarButton("告警阈值", ButtonKind.Normal, 100, EditThresholds);

            // 视图切换：关键服务 / 最近事件 / 占用进程（同一块表换列，窄窗也不会挤）
            _views = new Panel { Height = 36, BackColor = Color.Transparent };
            Controls.Add(_views);
            string[] vNames = { "关键服务", "最近事件", "占用进程" };
            for (int i = 0; i < vNames.Length; i++)
            {
                int idx = i;
                var b = new UiButton(vNames[i], ButtonKind.Ghost, 104, 32) { Location = new Point(0, 0) };
                b.Click += (s, e) => SetView(idx);
                _viewButtons[i] = b;
                _views.Controls.Add(b);
            }

            _table = new DataTable { Location = new Point(0, 200), Height = 300 };
            _table.RowActivated += ShowRow;
            Controls.Add(_table);
            SetView(0);

            _timer.Tick += (s, e) =>
            {
                RefreshMetrics();
                _ticks++;
                if (_ticks % 12 == 0) LoadSnapshot(false);   // 60 秒补一次快照
            };
        }

        private void AddBarButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 2) };
            b.Click += (s, e) => onClick();
            _barButtons.Add(b);
            _bar.Controls.Add(b);
        }

        private void SetView(int view)
        {
            _view = view;
            for (int i = 0; i < _viewButtons.Length; i++)
            {
                _viewButtons[i].Kind = i == view ? ButtonKind.Primary : ButtonKind.Ghost;
                _viewButtons[i].Invalidate();
            }
            BuildColumns();
            FillTable(false);
        }

        // 服务视图双击 = 重启（行内操作）；事件/进程双击看完整内容
        private void ShowRow(int idx)
        {
            if (_view == 0)
            {
                ServiceAction("Restart", 3);
                return;
            }
            if (_view == 1)
            {
                if (idx < 0 || idx >= _events.Count) return;
                var e = _events[idx];
                string body = "时间：" + Bridge.Str(e, "Time") + "\r\n" +
                              "级别：" + Bridge.Str(e, "Level") + "\r\n" +
                              "来源：" + Bridge.Str(e, "Provider") + "\r\n" +
                              "事件 ID：" + Bridge.Num(e, "Id", 0).ToString("0") + "\r\n" +
                              new string('-', 60) + "\r\n" + Bridge.Str(e, "Message");
                Dialogs.Text(FindForm(), "系统事件详情", Bridge.Str(e, "Provider"), body);
                return;
            }
            if (idx < 0 || idx >= _procs.Count) return;
            var p = _procs[idx];
            Dialogs.Text(FindForm(), "进程详情", Bridge.Str(p, "Name"),
                "进程：  " + Bridge.Str(p, "Name") + "\r\n" +
                "PID：   " + Bridge.Num(p, "Id", 0).ToString("0") + "\r\n" +
                "内存：  " + Bridge.Num(p, "MemMB", 0).ToString("0.0") + " MB\r\n" +
                "CPU 秒：" + (Bridge.Num(p, "CpuSec", -1) < 0 ? "—" : Bridge.Num(p, "CpuSec", 0).ToString("0.0")) +
                "\r\n\r\n按内存占用排序，取前 8 个进程。");
        }

        // Running / Stopped 这类英文状态在中文界面里很突兀，统一翻译一下
        private static string ServiceStatusText(string s)
        {
            switch (s)
            {
                case "Running": return "运行中";
                case "Stopped": return "已停止";
                case "StartPending": return "启动中";
                case "StopPending": return "停止中";
                case "Paused": return "已暂停";
                case "PausePending": return "暂停中";
                case "ContinuePending": return "恢复中";
                default: return string.IsNullOrEmpty(s) ? "未知" : s;
            }
        }

        private static string ServiceStartText(string s)
        {
            switch (s)
            {
                case "Automatic": return "自动";
                case "Auto": return "自动";
                case "Manual": return "手动";
                case "Disabled": return "已禁用";
                case "Boot": return "引导";
                case "System": return "系统";
                default: return string.IsNullOrEmpty(s) ? "—" : s;
            }
        }

        private void BuildColumns()
        {
            _table.Columns.Clear();
            if (_view == 0)
            {
                _table.Columns.Add(new DataColumn("服务名", 160));
                _table.Columns.Add(new DataColumn("显示名", 220));
                _table.Columns.Add(new DataColumn("状态", 90));
                _table.Columns.Add(new DataColumn("启动类型", 100));
                _table.Columns.Add(new DataColumn("用途", 260));
            }
            else if (_view == 1)
            {
                _table.Columns.Add(new DataColumn("时间", 130));
                _table.Columns.Add(new DataColumn("级别", 80));
                _table.Columns.Add(new DataColumn("来源", 190));
                _table.Columns.Add(new DataColumn("事件 ID", 90, true));
                _table.Columns.Add(new DataColumn("消息", 480));
            }
            else
            {
                _table.Columns.Add(new DataColumn("进程", 190));
                _table.Columns.Add(new DataColumn("PID", 90, true));
                _table.Columns.Add(new DataColumn("内存 MB", 110, true));
                _table.Columns.Add(new DataColumn("CPU 秒", 100, true));
                _table.Columns.Add(new DataColumn("说明", 300));
            }
        }

        private void FillTable(bool keepScroll)
        {
            var rows = new List<string[]>();
            if (_view == 0)
            {
                foreach (var s in _services)
                    rows.Add(new[]
                    {
                        Bridge.Str(s, "Name"), Bridge.Str(s, "Display"),
                        ServiceStatusText(Bridge.Str(s, "Status")), ServiceStartText(Bridge.Str(s, "Start")),
                        Bridge.Str(s, "Why")
                    });
            }
            else if (_view == 1)
            {
                foreach (var e in _events)
                    rows.Add(new[]
                    {
                        Bridge.Str(e, "Time"), Bridge.Str(e, "Level"), Bridge.Str(e, "Provider"),
                        Bridge.Num(e, "Id", 0).ToString("0"), Bridge.Str(e, "Message")
                    });
            }
            else
            {
                foreach (var p in _procs)
                    rows.Add(new[]
                    {
                        Bridge.Str(p, "Name"), Bridge.Num(p, "Id", 0).ToString("0"),
                        Bridge.Num(p, "MemMB", 0).ToString("0.0"),
                        Bridge.Num(p, "CpuSec", -1) < 0 ? "—" : Bridge.Num(p, "CpuSec", 0).ToString("0.0"),
                        "占内存最多"
                    });
            }
            _table.SetRows(rows, keepScroll);
            for (int i = 0; i < _viewButtons.Length; i++)
            {
                int n = i == 0 ? _services.Count : (i == 1 ? _events.Count : _procs.Count);
                string name = i == 0 ? "关键服务" : (i == 1 ? "最近事件" : "占用进程");
                _viewButtons[i].Text = name + " " + n;
            }
        }

        // 服务控制：走既有动作 monitor-service（1 启动 / 2 停止 / 3 重启），
        // 危险操作先确认；WinRM 这类停掉会断远程会话的由动作层再提醒一次。
        private void ServiceAction(string mode, int code)
        {
            if (_view != 0)
            {
                Log("[WARN] 服务操作只在「关键服务」视图可用，先切到该视图");
                return;
            }
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _services.Count)
            {
                Log("[WARN] 先在下表选中要操作的服务");
                return;
            }
            string name = Bridge.Str(_services[idx], "Name");
            if (name.Length == 0) return;

            if (mode != "Start")
            {
                string tip = mode == "Stop"
                    ? "停止服务会立即中断它提供的功能；WinRM / LanmanServer 这类基础服务停掉可能断开你的远程会话。"
                    : "重启服务会短暂中断它提供的功能（远程会话可能卡一下）。";
                if (!Dialogs.Confirm(FindForm(), mode == "Stop" ? "停止服务" : "重启服务",
                    tip + "\n\n目标服务：" + name + "（" + Bridge.Str(_services[idx], "Display") + "）",
                    mode == "Stop" ? "停止" : "重启")) return;
            }

            var args = new Dictionary<string, object>();
            args["Name"] = name;
            args["Action"] = code;
            args["DryRun"] = false;
            bool started = Actions.RunAction("monitor-service", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + name + " " + mode + "结束，退出码 " + r.ExitCode);
                    LoadSnapshot(true);
                }),
                err => SafeInvoke(() => Log("[WARN] 服务控制未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 " + mode + " 服务 " + name + "（monitor-service）");
        }

        // 快照：进程内采样（Snapshot.cs），失败才回退到 runner 子进程
        private void LoadSnapshot(bool manual)
        {
            if (_snapBusy) return;
            _snapBusy = true;
            if (manual) SetLive("采集快照…");

            Snapshot.LoadAsync(15, 8,
                s => SafeInvoke(() =>
                {
                    _snapBusy = false;
                    ApplySnapshot(s.Services, s.Events, s.Processes, manual);
                }),
                err => SafeInvoke(() =>
                {
                    Log("[INFO] 本机快照不可用（" + err + "），回退到 runner");
                    LoadSnapshotViaRunner(manual);
                }));
        }

        // 回退路径：Run-GuiReadyMonitor.ps1 -Mode snapshot
        private void LoadSnapshotViaRunner(bool manual)
        {
            Bridge.Run(@"gui\Run-GuiReadyMonitor.ps1", "snapshot", null,
                d =>
                {
                    var snap = Bridge.Dict(d.ContainsKey("Snap") ? d["Snap"] : null);
                    SafeInvoke(() =>
                    {
                        _snapBusy = false;
                        if (snap == null) { SetLive("快照无数据", "Warn"); return; }
                        ApplySnapshot(
                            Bridge.List(snap.ContainsKey("Services") ? snap["Services"] : null),
                            Bridge.List(snap.ContainsKey("Events") ? snap["Events"] : null),
                            Bridge.List(snap.ContainsKey("Processes") ? snap["Processes"] : null),
                            manual);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _snapBusy = false;
                    SetLive("快照失败", "Warn");
                    Log("[WARN] 快照读取失败: " + err);
                }), 180000);
        }

        // CPU / 内存 / 磁盘卡片由 Metrics 负责，这里只管服务 / 事件 / 进程
        private void ApplySnapshot(List<Dictionary<string, object>> services,
                                   List<Dictionary<string, object>> events,
                                   List<Dictionary<string, object>> procs,
                                   bool manual)
        {
            _services.Clear();
            _services.AddRange(services);
            _events.Clear();
            _events.AddRange(events);
            _procs.Clear();
            _procs.AddRange(procs);

            // 关键服务卡：运行数 + 掉线的服务名
            if (_cards.Count > 3 && _services.Count > 0)
            {
                int run = 0;
                var down = new List<string>();
                foreach (var s in _services)
                {
                    if (Bridge.Str(s, "Status") == "Running") run++;
                    else down.Add(Bridge.Str(s, "Name"));
                }
                _cards[3].Set(run + " / " + _services.Count,
                    down.Count == 0 ? "全部运行中" : "未运行：" + string.Join("、", down.ToArray()));
                _cards[3].Accent = down.Count == 0 ? Theme.Ok : (run > 0 ? Theme.Warn : Theme.Err);
                _cards[3].Invalidate();

                string sig = string.Join(",", down.ToArray());
                if (sig != _svcSig)
                {
                    _svcSig = sig;
                    if (down.Count > 0)
                        Log("[WARN] 关键服务未运行：" + sig);
                    else
                        Log("[OK] 关键服务全部运行中");
                }
            }

            FillTable(true);
            SetLive("已更新 " + DateTime.Now.ToString("HH:mm:ss"));
            if (manual)
                Log("[INFO] 快照已刷新：服务 " + _services.Count + " · 事件 " + _events.Count +
                    " · 进程 " + _procs.Count);
        }

        // 只在本页可见时轮询；切走就停，别在后台白耗 CPU
        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (Visible) _timer.Start();
            else _timer.Stop();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { try { _timer.Stop(); _timer.Dispose(); } catch { } }
            base.Dispose(disposing);
        }

        protected override void BuildContent() { }

        protected override void OnActivated()
        {
            LoadThresholds();
            RefreshMetrics();
            LoadSnapshot(false);   // 服务 / 事件 / 进程跟着进页刷新一次
            _ticks = 0;
            _timer.Start();
        }

        // ---- 告警阈值（与 PowerShell 版同一个文件：state\monitor-thresholds.json）
        private void LoadThresholds()
        {
            try
            {
                string p = System.IO.Path.Combine(Bridge.StatePath, "monitor-thresholds.json");
                if (!System.IO.File.Exists(p)) return;
                string raw = System.IO.File.ReadAllText(p, System.Text.Encoding.UTF8);
                var ser = new System.Web.Script.Serialization.JavaScriptSerializer();
                var d = ser.Deserialize<Dictionary<string, object>>(raw);
                if (d == null) return;
                _thCpu = (int)Bridge.Num(d, "Cpu", 90);
                _thMem = (int)Bridge.Num(d, "Mem", 90);
                _thDisk = (int)Bridge.Num(d, "Disk", 90);
            }
            catch { }
        }

        private void SaveThresholds()
        {
            try
            {
                string p = System.IO.Path.Combine(Bridge.StatePath, "monitor-thresholds.json");
                string json = "{\"Cpu\":" + _thCpu + ",\"Mem\":" + _thMem + ",\"Disk\":" + _thDisk + "}";
                System.IO.File.WriteAllText(p, json, new System.Text.UTF8Encoding(false));
            }
            catch (Exception ex)
            {
                Log("[WARN] 保存告警阈值失败: " + ex.Message);
            }
        }

        private void EditThresholds()
        {
            var fields = new List<PromptField>
            {
                new PromptField("CPU 阈值（%）", _thCpu.ToString(), false, "1-100，默认 90"),
                new PromptField("内存阈值（%）", _thMem.ToString(), false, "1-100，默认 90"),
                new PromptField("磁盘阈值（%）", _thDisk.ToString(), false, "1-100，默认 90")
            };
            var v = Dialogs.Prompt(FindForm(), "告警阈值",
                "使用率到达阈值时，会在下方运行日志里标红提醒（不会弹窗）。",
                fields, "保存");
            if (v == null) return;

            int c, m, d;
            _thCpu = int.TryParse(v[0].Trim(), out c) && c >= 1 && c <= 100 ? c : _thCpu;
            _thMem = int.TryParse(v[1].Trim(), out m) && m >= 1 && m <= 100 ? m : _thMem;
            _thDisk = int.TryParse(v[2].Trim(), out d) && d >= 1 && d <= 100 ? d : _thDisk;
            SaveThresholds();
            Log("[INFO] 告警阈值已更新：CPU " + _thCpu + "% / 内存 " + _thMem + "% / 磁盘 " + _thDisk + "%");
        }

        // 边沿检测：只有「跨过阈值」和「回落」各记一条，
        // 否则每 5 秒采样一次会把运行日志刷满同一句告警。
        private void CheckAlert(string name, double value, int threshold)
        {
            if (value < 0 || threshold < 1) return;
            bool on = value >= threshold;
            bool was;
            _alertOn.TryGetValue(name, out was);
            if (on == was) return;
            _alertOn[name] = on;
            if (on)
                Log("[WARN] 告警：" + name + " 使用率 " + value.ToString("0.0") +
                    "% 已达到阈值 " + threshold + "%");
            else
                Log("[OK] " + name + " 已回落至 " + value.ToString("0.0") + "%（阈值 " + threshold + "%）");
        }

        // 优先用本机已有的 pstop / htop / btm，没有就用内置 scm-top（零依赖）
        private void OpenTui()
        {
            string builtin = System.IO.Path.Combine(Bridge.Root, @"gui\GuiReady.TuiMonitor.ps1");
            string exe = "";
            foreach (var name in new[] { "pstop", "htop", "btm" })
            {
                foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
                {
                    if (string.IsNullOrWhiteSpace(dir)) continue;
                    try
                    {
                        string p = System.IO.Path.Combine(dir.Trim(), name + ".exe");
                        if (System.IO.File.Exists(p)) { exe = p; break; }
                    }
                    catch { }
                }
                if (exe.Length > 0) break;
            }

            try
            {
                if (exe.Length > 0)
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = exe,
                        UseShellExecute = true
                    });
                    Log("[OK] 已打开 TUI 监控: " + exe);
                    return;
                }
                if (!System.IO.File.Exists(builtin))
                {
                    Log("[WARN] 找不到内置 TUI 监控脚本: " + builtin);
                    return;
                }
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + builtin + "\"",
                    UseShellExecute = true
                });
                Log("[OK] 未找到 pstop / htop / btm，已打开内置 TUI 监控（scm-top，按 q 退出）");
            }
            catch (Exception ex)
            {
                Log("[WARN] 打开 TUI 监控失败: " + ex.Message);
            }
        }

        // 页头胶囊：文字一变宽窄就变，Slot 要跟着重算，否则会压出页头
        private void SetLive(string text, string kind = null)
        {
            _live.SetText(text);
            if (kind != null) _live.SetKind(kind);
            Head.Slot.Width = _live.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        // 走进程内采样（Metrics.cs）；极端系统上取不到时回退到 runner 子进程
        public void RefreshMetrics()
        {
            if (_refreshing) return;   // 上一轮还没回来就跳过，别堆进程
            _refreshing = true;
            SetLive("采集中");
            Metrics.SampleAsync(
                s => SafeInvoke(() =>
                {
                    _refreshing = false;
                    ApplyMetricValues(s.Cpu, s.MemPct, s.DiskPct, s.CpuSrc, s.DiskName,
                                      s.MemUsedGB, s.MemTotalGB, s.DiskFreeGB);
                }),
                err => SafeInvoke(() =>
                {
                    Log("[INFO] 本机采样不可用（" + err + "），回退到 runner");
                    RefreshMetricsViaRunner();
                }));
        }

        // 回退路径：Run-GuiReadyMonitor.ps1 -Mode metrics -> {Mode,Stamp,Error,Snap}
        private void RefreshMetricsViaRunner()
        {
            Bridge.Run(@"gui\Run-GuiReadyMonitor.ps1", "metrics", null,
                d =>
                {
                    var snap = Bridge.Dict(d.ContainsKey("Snap") ? d["Snap"] : null);
                    SafeInvoke(() =>
                    {
                        _refreshing = false;
                        if (snap == null) { SetLive("无数据"); return; }
                        ApplyMetricValues(Bridge.Num(snap, "Cpu", -1), Bridge.Num(snap, "MemPct", -1),
                                          Bridge.Num(snap, "DiskPct", -1),
                                          Bridge.Str(snap, "CpuSrc", "采样 1s"),
                                          Bridge.Str(snap, "DiskName", "系统盘"),
                                          -1, -1, -1);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _refreshing = false;
                    SetLive("读取失败", "Danger");
                    Log("[WARN] 指标读取失败: " + err);
                }));
        }

        private void ApplyMetricValues(double cpu, double mem, double disk, string cpuSrc, string diskName,
                                       double memUsed, double memTotal, double diskFree)
        {
            if (_cards.Count >= 3)
            {
                _cards[0].Set(cpu < 0 ? "—" : cpu.ToString("0.0") + " %", cpuSrc);
                _cards[1].Set(mem < 0 ? "—" : mem.ToString("0.0") + " %",
                    memTotal > 0 ? (memUsed.ToString("0.0") + " GB / " + memTotal.ToString("0.0") + " GB")
                                 : "物理内存占用率");
                string diskNote = diskFree > 0
                    ? (string.IsNullOrEmpty(diskName) ? "系统盘" : diskName) + " 剩余 " + diskFree.ToString("0.0") + " GB"
                    : diskName + " 已用";
                _cards[2].Set(disk < 0 ? "—" : disk.ToString("0.0") + " %", diskNote);
            }
            _trends[0].Push(cpu);
            _trends[1].Push(mem);
            _trends[2].Push(disk);
            CheckAlert("CPU", cpu, _thCpu);
            CheckAlert("内存", mem, _thMem);
            CheckAlert("磁盘", disk, _thDisk);
            SetLive("已更新 " + DateTime.Now.ToString("HH:mm:ss"), "Info");
            try
            {
                // 写 state\ 而不是 ui\bin\：ui\bin 在完整性清单范围内，
                // 自己往里写清单外文件会让用户的「完整性自检」一直报警。
                string dir = System.IO.Path.GetFullPath(
                    System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"..\..\state"));
                System.IO.Directory.CreateDirectory(dir);
                System.IO.File.WriteAllText(
                    System.IO.Path.Combine(dir, "last-metrics.txt"),
                    "cpu=" + cpu + " mem=" + mem + " disk=" + disk +
                    " src=" + cpuSrc + " disk=" + diskName);
            }
            catch { }
        }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            int gap = 12;
            // 1024×700 下页面可用宽只有 816：按 162 一列算，四张卡仍能挤成一行，
            // 否则卡片换行会把下面的表格压到只剩一条缝。
            int perRow = Math.Max(1, Math.Min(_cards.Count, (w + gap) / (150 + gap)));
            int cardW = (w - (perRow - 1) * gap - 4) / perRow;
            if (cardW < 150) cardW = 150;
            for (int i = 0; i < _cards.Count; i++)
            {
                var c = _cards[i];
                c.Width = cardW;
                c.Left = (i % perRow) * (cardW + gap);
                c.Top = 76 + (i / perRow) * (c.Height + gap);
            }
            int rows = (_cards.Count + perRow - 1) / perRow;
            int barTop = 76 + rows * (_cards[0].Height + gap) + 2;

            // 趋势条：卡片下面一行三块。
            // 高度不能压太狠 —— 66 高时绘图区只剩 26px，1024×700 下更是只有 12px，
            // 曲线看着就像被折叠成一条线。52 高时直接隐藏曲线，改为给表格让位。
            int trendH = ClientSize.Height < 560 ? 74 : 88;
            int tw = Math.Max(120, (w - 4 - gap * 2) / 3);
            for (int i = 0; i < _trends.Length; i++)
            {
                var t = _trends[i];
                if (t == null) continue;
                t.Width = tw;
                t.Height = trendH;
                t.Left = i * (tw + gap);
                t.Top = barTop;
            }
            barTop += trendH + 6;

            // 操作栏：按钮多了就换行，窄窗不会挤出右边界
            int aw = Math.Max(200, w - 4);
            _bar.Left = 0;
            _bar.Top = barTop;
            _bar.Width = aw;
            const int bGap = 10;
            int bx = 0, bRow = 0;
            foreach (var b in _barButtons)
            {
                if (bx > 0 && bx + b.Width > aw) { bx = 0; bRow++; }
                b.Left = bx;
                b.Top = 2 + bRow * (b.Height + 6);
                bx += b.Width + bGap;
            }
            _bar.Height = 2 + (bRow + 1) * (36 + 6);

            // 视图切换条
            int vy = barTop + _bar.Height + 2;
            _views.Left = 0;
            _views.Top = vy;
            _views.Width = aw;
            int vx = 0;
            foreach (var b in _viewButtons)
            {
                if (b == null) continue;
                b.Left = vx;
                vx += b.Width + 8;
            }
            _views.Visible = ClientSize.Height - vy >= 40;

            int tableTop = vy + 38;
            _table.Left = 0;
            _table.Top = tableTop;
            _table.Width = aw;
            _table.Height = Math.Max(60, ClientSize.Height - tableTop - 8);
        }
    }

    internal sealed class EnvPage : PageBase
    {
        private readonly List<StatCard> _cards = new List<StatCard>();
        private readonly Panel _actions;
        private readonly Panel _hint;
        private readonly Pill _state;
        private readonly UiButton _detect;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private bool _busy;

        public EnvPage()
        {
            Key = "env";
            TitleText = "环境补全";
            Subtitle = "先看这台机器缺什么，再一键补齐；补齐后 Server Core 就能运行带界面的程序。";
            Glyph = "env";
            Accent = Theme.AccentOf("env");

            _state = new Pill("未探测", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            string[][] items =
            {
                new[] { "系统版本", "—",     "#22D3EE", "构建号" },
                new[] { "桌面体验", "—",     "#34D399", "FOD · ServerCore.AppCompatibility" },
                new[] { ".NET 运行时", "—",  "#409EFF", "dotnet --list-runtimes" },
                new[] { "交互登录", "—",     "#C084FC", "已登录会话" },
                new[] { "管理员权限", "—",   "#FBBF24", "补全需要提升" },
                new[] { "WAC",      "—",     "#94A3B8", "可选组件" },
                new[] { "桌面 DLL", "—",     "#F0ABFC", "twinui / themeui / themeservice" }
            };
            foreach (var s in items)
            {
                var c = new StatCard(s[0], s[1], Theme.Hex(s[2]), s[3]);
                _cards.Add(c);
                Controls.Add(c);
            }

            _actions = new Panel { Height = 46, BackColor = Color.Transparent };
            Controls.Add(_actions);

            var fill = AddButton("一键补全", ButtonKind.Primary, 132);
            _detect = AddButton("重新探测", ButtonKind.Normal, 100);
            var selftest = AddButton("GUI 自检", ButtonKind.Normal, 100);
            var autologon = AddButton("自动登录", ButtonKind.Normal, 100);
            var wac = AddButton("WAC 状态", ButtonKind.Normal, 100);
            var wacInstall = AddButton("安装 WAC", ButtonKind.Primary, 112);
            var dllPatch = AddButton("补齐 DLL", ButtonKind.Normal, 100);

            fill.Click += (s, e) => RunAction("pipeline-auto", "一键补全");
            _detect.Click += (s, e) => Probe();
            selftest.Click += (s, e) => RunAction("guitest", "GUI 自检");
            autologon.Click += (s, e) => RunAction("autologon-status", "开机自动登录状态");
            wac.Click += (s, e) => RunAction("wac-status", "Windows Admin Center 状态");
            wacInstall.Click += (s, e) => InstallWac();
            dllPatch.Click += (s, e) => PatchDesktopDlls();

            _hint = new Panel { Height = 46, BackColor = Theme.Mix(Theme.Bg, Theme.Accent, 0.10f) };
            _hint.Paint += (s, e) =>
            {
                Draw.TextBlock(e.Graphics,
                    "提示：一键补全会按需装官方 FOD、补齐 .NET 运行时，并自动补齐桌面体验 DLL（twinui / themeui / themeservice）；需要重启时会自动重启并接着跑完。\n" +
                    "只想补 DLL 时用右侧「补齐 DLL」；要装 Windows Admin Center 用「安装 WAC」（支持填本地安装包，走内网）。",
                    Theme.Font(9.5f), Theme.Sub, new Rectangle(12, 4, _hint.Width - 24, _hint.Height - 8));
            };
            Controls.Add(_hint);
        }

        private UiButton AddButton(string text, ButtonKind kind, int width)
        {
            var b = new UiButton(text, kind, width, 38) { Location = new Point(0, 4) };
            _buttons.Add(b);
            _actions.Controls.Add(b);
            return b;
        }

        // WAC 一键安装：可填本地安装包（内网），留空则自动下载；装完自动打开 WAC
        private void InstallWac()
        {
            var v = Dialogs.Prompt(FindForm(), "安装 Windows Admin Center",
                "会自动下载官方安装包、配置防火墙、设为自动启动，装完自动打开 WAC 界面。\n" +
                "离线 / 内网环境在下面填本地安装包（.msi 或 .exe）的完整路径，留空则联网下载。",
                new List<PromptField> { new PromptField("安装包路径（可空 = 自动下载）", "") }, "开始安装");
            if (v == null) return;

            string installer = v[0].Trim().Trim('"');
            var args = new Dictionary<string, object>();
            args["DryRun"] = false;
            args["Port"] = "443";
            args["InstallerPath"] = installer;
            if (installer.Length > 0) args["NoDownload"] = true;

            bool started = Actions.RunAction("wac-install", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "安装 WAC 结束，退出码 " + r.ExitCode +
                        "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    Probe();
                    if (r.ExitCode == 0) OpenWac();
                }),
                err => SafeInvoke(() => Log("[WARN] 安装 WAC 未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 一键安装并自动配置 WAC（wac-install）");
        }

        private void OpenWac()
        {
            Log("[STEP] 打开 WAC 界面");
            bool started = Actions.RunAction("wac-open",
                new Dictionary<string, object> { { "DryRun", false } },
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() => Log((r.ExitCode == 0 ? "[OK] " : "[WARN] ") + "打开 WAC 结束，退出码 " + r.ExitCode)),
                err => SafeInvoke(() => Log("[WARN] 打开 WAC 未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 打开 WAC 界面（wac-open）");
        }

        // 桌面体验 DLL 单独入口（一键补全里也会做，这里给「只想补这几个 DLL」的场景）
        private void PatchDesktopDlls()
        {
            if (!Dialogs.Confirm(FindForm(), "补齐桌面体验 DLL",
                "从发布包内置的同版本 DLL 复制到 System32（twinui / themeui / themeservice），已有文件会先备份，主题/XAML 组件需重启或注销后生效。\n\n" +
                "这一步在「一键补全」里也会自动执行；只有确认缺这几个组件时才需要单独跑。", "开始补齐")) return;
            RunAction("dll-patch", "补齐桌面体验 DLL");
        }

        protected override void OnActivated()
        {
            UpdateDllCard();
            Probe();
        }

        // 桌面体验 DLL：twinui / themeui / themeservice / DispBroker
        // 只查 System32 是否存在 —— 和「补齐 DLL」动作的判断口径一致，秒出结果。
        private void UpdateDllCard()
        {
            if (_cards.Count < 7) return;
            string[] names = { "twinui.dll", "themeui.dll", "themeservice.dll", "DispBroker.dll" };
            int have = 0;
            var miss = new List<string>();
            foreach (var n in names)
            {
                bool ok = false;
                try { ok = System.IO.File.Exists(System.IO.Path.Combine(Environment.SystemDirectory, n)); } catch { }
                if (ok) have++; else miss.Add(n);
            }
            string note = miss.Count == 0 ? "全部就位" : ("缺 " + string.Join("、", miss.ToArray()));
            _cards[6].Set(have + " / " + names.Length, note);
            _cards[6].Accent = have == names.Length ? Theme.Ok : (have > 0 ? Theme.Warn : Theme.Err);
            _cards[6].Invalidate();
        }

        // 走既有 runner：Run-GuiReadyProbe.ps1（先写 stage=fast，再写 stage=full）
        private void Probe()
        {
            if (_busy) return;
            _busy = true;
            SetState("探测中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadyProbe.ps1", null, null,
                d =>
                {
                    var st = Bridge.Dict(d.ContainsKey("Static") ? d["Static"] : null);
                    var cap = Bridge.Dict(d.ContainsKey("Cap") ? d["Cap"] : null);
                    var net = Bridge.Dict(d.ContainsKey("DotNet") ? d["DotNet"] : null);
                    var ses = Bridge.Dict(d.ContainsKey("Sessions") ? d["Sessions"] : null);
                    var wac = Bridge.Dict(d.ContainsKey("Wac") ? d["Wac"] : null);
                    string stage = Bridge.Str(d, "Stage");

                    SafeInvoke(() =>
                    {
                        _busy = false;

                        string build = Bridge.Str(st, "Build", "—");
                        string product = Bridge.Str(st, "ProductName");
                        string disp = Bridge.Str(st, "DisplayVersion");
                        string note = product;
                        if (disp.Length > 0) note += (note.Length > 0 ? " · " : "") + disp;
                        if (Bridge.Bool(st, "PendingReboot")) note += " · 待重启";
                        _cards[0].Set(build, note);

                        var caps = Bridge.List(cap != null && cap.ContainsKey("Items") ? cap["Items"] : null);
                        string capState = "";
                        foreach (var it in caps)
                        {
                            if (Bridge.Str(it, "Name").IndexOf("AppCompatibility",
                                    StringComparison.OrdinalIgnoreCase) < 0) continue;
                            capState = Bridge.Str(it, "State");
                            break;
                        }
                        string capNote;
                        if (Bridge.Bool(cap, "Inferred")) capNote = "组件扫描推断";
                        else if (capState.Length == 0)
                        {
                            string ce = Bridge.Str(cap, "Error", "未查询到").Trim();
                            if (ce.IndexOf("elevation", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                ce.IndexOf("access", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                ce.IndexOf("权限", StringComparison.Ordinal) >= 0)
                                capNote = "需要管理员权限";
                            else capNote = ce;
                        }
                        else capNote = "DISM 实测";
                        if (capState == "Installed") _cards[1].Set("已安装", capNote);
                        else if (capState == "NotPresent") _cards[1].Set("未安装", capNote);
                        else _cards[1].Set("未知", capNote);

                        var fw = Bridge.List(net != null && net.ContainsKey("Frameworks") ? net["Frameworks"] : null);
                        _cards[2].Set(fw.Count + " 个框架",
                            Bridge.Bool(net, "RootExists") ? "dotnet 已就绪" : "未找到 dotnet 目录");

                        var logged = Bridge.List(ses != null && ses.ContainsKey("LoggedOn") ? ses["LoggedOn"] : null);
                        var names = new List<string>();
                        foreach (var item in logged)
                        {
                            string u = Bridge.Str(item, "User");
                            if (u.Length > 0 && !names.Contains(u)) names.Add(u);
                        }
                        _cards[3].Set((int)Bridge.Num(ses, "LoggedOnCount") + " 个会话",
                            names.Count > 0 ? string.Join("、", names.ToArray()) : "当前无交互登录");

                        bool admin = Bridge.Bool(st, "IsAdministrator");
                        _cards[4].Set(admin ? "是" : "否",
                            admin ? "已提升，可执行补全" : "未提升，补全会失败");

                        if (Bridge.Bool(wac, "Installed"))
                            _cards[5].Set(Bridge.Str(wac, "Version", "已安装"), Bridge.Str(wac, "InstallPath", "已安装"));
                        else
                            _cards[5].Set("未安装", "可选组件");

                        SetState(stage == "full" ? "已更新 " + DateTime.Now.ToString("HH:mm:ss") : "快速结果", "Info");
                        Log("[INFO] 环境探测完成（stage=" + stage + "，.NET 框架 " + fw.Count + "）");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("探测失败", "Danger");
                    Log("[WARN] 环境探测失败: " + err);
                }), 180000);
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        // 动作层：真正的系统改动交给 Run-GuiReadyAction.ps1 子进程，日志实时回到下方运行日志栏
        private void RunAction(string id, string name)
        {
            var args = new Dictionary<string, object>();
            args["DryRun"] = false;

            bool started = Actions.RunAction(id, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + name + "结束，退出码 " + r.ExitCode +
                        "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    // 动作可能改了环境（装了 FOD / .NET / DLL），回到卡片时重新探测一次
                    UpdateDllCard();
                    Probe();
                }),
                err => SafeInvoke(() => Log("[WARN] " + name + "未启动: " + err)));

            if (started) Log("[STEP] 已提交动作 " + name + "（" + id + "）");
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            int gap = 12;
            int perRow = Math.Max(1, (w + gap) / (208 + gap));
            int cardW = (w - (perRow - 1) * gap - 4) / perRow;
            if (cardW < 150) cardW = 150;
            for (int i = 0; i < _cards.Count; i++)
            {
                var c = _cards[i];
                c.Width = cardW;
                c.Left = (i % perRow) * (cardW + gap);
                c.Top = 76 + (i / perRow) * (c.Height + gap);
            }
            int rows = (_cards.Count + perRow - 1) / perRow;
            int y = 76 + rows * (_cards[0].Height + gap) + 6;
            int aw = Math.Max(200, w - 4);
            _actions.Left = 0;
            _actions.Top = y;
            _actions.Width = aw;

            // 按钮多了就换行，窄窗（1024×768）下不会挤出右边界
            const int bGap = 10;
            int bx = 0, row = 0;
            foreach (var b in _buttons)
            {
                if (bx > 0 && bx + b.Width > aw) { bx = 0; row++; }
                b.Left = bx;
                b.Top = 4 + row * (b.Height + 8);
                bx += b.Width + bGap;
            }
            _actions.Height = 4 + (row + 1) * (38 + 8);
            y += _actions.Height + 6;
            _hint.Left = 0;
            int avail = ClientSize.Height - y - 8;
            _hint.Visible = avail >= 24;
            if (_hint.Visible)
            {
                _hint.Top = y;
                _hint.Height = Math.Max(24, Math.Min(46, avail));
            }
            _hint.Width = aw;
        }
    }

    internal sealed class LogsPage : PageBase
    {
        private sealed class LogSource
        {
            public string Id;
            public string Name;
            public LogSource(string id, string name) { Id = id; Name = name; }
        }

        private static readonly string[] LevelIds = { "All", "Error", "Warning", "Information" };
        private static readonly string[] LevelNames = { "全部级别", "仅错误", "仅警告", "仅信息" };
        private static readonly string[] SinceIds = { "1h", "6h", "24h", "7d", "30d" };
        private static readonly string[] SinceNames = { "近 1 小时", "近 6 小时", "近 24 小时", "近 7 天", "近 30 天" };

        private readonly List<LogSource> _sources = new List<LogSource>();
        private readonly List<Dictionary<string, object>> _entries = new List<Dictionary<string, object>>();
        private readonly UiButton _srcBtn;
        private readonly UiButton _levelBtn;
        private readonly UiButton _sinceBtn;
        private readonly UiInput _search;
        private readonly UiButton _query;
        private readonly UiButton _export;
        private readonly Pill _status;
        private readonly DataTable _table;
        private int _srcIndex;
        private int _levelIndex;
        private int _sinceIndex = 2;
        private bool _busy;

        public LogsPage()
        {
            Key = "logs";
            TitleText = "日志中心";
            Subtitle = "Windows 事件日志与工具自身日志的统一读取、筛选、导出；双击一行看完整消息。";
            Glyph = "logs";
            Accent = Theme.AccentOf("logs");

            _status = new Pill("未查询", "Neutral");
            Head.Slot.Controls.Add(_status);
            Head.Slot.Width = _status.Width;
            _status.Left = 0;

            _srcBtn = new UiButton("来源：系统", ButtonKind.Normal, 140, 32);
            _srcBtn.Click += (s, e) => ChooseSource();
            _levelBtn = new UiButton(LevelNames[0], ButtonKind.Normal, 104, 32);
            _levelBtn.Click += (s, e) =>
            {
                _levelIndex = (_levelIndex + 1) % LevelIds.Length;
                _levelBtn.Text = LevelNames[_levelIndex];
                Query();
            };
            _search = new UiInput(280);
            _search.Box.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; Query(); }
            };
            _sinceBtn = new UiButton(SinceNames[_sinceIndex], ButtonKind.Normal, 108, 32);
            _sinceBtn.Click += (s, e) =>
            {
                _sinceIndex = (_sinceIndex + 1) % SinceIds.Length;
                _sinceBtn.Text = SinceNames[_sinceIndex];
                Query();
            };
            _query = new UiButton("查询", ButtonKind.Primary, 88, 32);
            _query.Click += (s, e) => Query();
            _export = new UiButton("导出", ButtonKind.Normal, 80, 32);
            _export.Click += (s, e) => ExportCurrent();

            Controls.Add(_srcBtn);
            Controls.Add(_levelBtn);
            Controls.Add(_sinceBtn);
            Controls.Add(_search);
            Controls.Add(_query);
            Controls.Add(_export);

            _table = new DataTable { Location = new Point(0, 116) };
            _table.Columns.Add(new DataColumn("时间", 150));
            _table.Columns.Add(new DataColumn("级别", 64));
            _table.Columns.Add(new DataColumn("来源", 200));
            _table.Columns.Add(new DataColumn("事件 ID", 80, true));
            _table.Columns.Add(new DataColumn("消息", 460));
            _table.RowActivated += ShowEntry;
            // 详情是弹窗，单击只选中，双击才弹，避免误触打断浏览
            _table.ActivateOnDoubleClick = true;
            Controls.Add(_table);
        }

        // 双击一行看整条消息（表格里只放得下一行，事件日志的多行正文要能看全）
        private void ShowEntry(int idx)
        {
            if (idx < 0 || idx >= _entries.Count) return;
            var e = _entries[idx];
            string msg = Bridge.Str(e, "Message");
            string head = Bridge.Str(e, "Time") + " · " + Bridge.Str(e, "Level") +
                          " · " + Bridge.Str(e, "Source");
            string body = "来源：" + Bridge.Str(e, "Source") + "\r\n" +
                          "时间：" + Bridge.Str(e, "Time") + "\r\n" +
                          "级别：" + Bridge.Str(e, "Level") + "\r\n" +
                          "事件 ID：" + Bridge.Str(e, "Id") + "\r\n" +
                          new string('-', 60) + "\r\n" + msg;
            Dialogs.Text(FindForm(), "日志详情", head, body);
        }

        // 先问 runner 有哪些来源（事件日志 + logs 目录下的文本日志），再拉条目
        protected override void OnActivated()
        {
            Bridge.Run(@"gui\Run-GuiReadyLogs.ps1", "sources", null,
                d =>
                {
                    var list = Bridge.List(d.ContainsKey("Data") ? d["Data"] : null);
                    SafeInvoke(() =>
                    {
                        _sources.Clear();
                        foreach (var it in list)
                        {
                            string id = Bridge.Str(it, "Id");
                            if (id.Length == 0) continue;
                            _sources.Add(new LogSource(id, Bridge.Str(it, "Name", id)));
                        }
                        if (_sources.Count == 0) _sources.Add(new LogSource("event:System", "System"));
                        _srcIndex = _sources.FindIndex(x => x.Id == "event:System");
                        if (_srcIndex < 0) _srcIndex = 0;
                        UpdateSourceText();
                        Query();
                    });
                },
                err => SafeInvoke(() =>
                {
                    if (_sources.Count == 0) _sources.Add(new LogSource("event:System", "System"));
                    UpdateSourceText();
                    Log("[WARN] 日志来源读取失败: " + err);
                    Query();
                }));
        }

        // 来源多了以后「点一下换一个」很难找；改成下拉列表直接选
        private void ChooseSource()
        {
            if (_sources.Count == 0) return;
            var menu = new ContextMenuStrip { Font = Theme.Font(9.5f) };
            for (int i = 0; i < _sources.Count; i++)
            {
                int pick = i;
                menu.Items.Add((i == _srcIndex ? "✓ " : "    ") + _sources[i].Name, null,
                    (s, e) =>
                    {
                        _srcIndex = pick;
                        UpdateSourceText();
                        Query();
                    });
            }
            menu.Show(_srcBtn, new Point(0, _srcBtn.Height));
        }

        private void UpdateSourceText()
        {
            if (_sources.Count == 0) return;
            string text = "来源：" + _sources[_srcIndex].Name;
            _srcBtn.Text = text;
            // 长来源名（如 Microsoft-Windows-...）按钮要跟着变宽，否则被截成一半
            var sz = TextRenderer.MeasureText(text, Theme.Font(9.75f));
            int w = Math.Max(140, Math.Min(300, sz.Width + 28));
            if (w != _srcBtn.Width)
            {
                _srcBtn.Width = w;
                Relayout();
            }
        }

        private void SetStatus(string text, string kind)
        {
            _status.SetText(text);
            _status.SetKind(kind);
            Head.Slot.Width = _status.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        public void Query()
        {
            if (_busy) return;
            if (_sources.Count == 0) return;
            _busy = true;
            SetStatus("读取中…", "Info");

            var args = new Dictionary<string, object>();
            args["Source"] = _sources[_srcIndex].Id;
            args["Max"] = 300;
            args["Level"] = LevelIds[_levelIndex];
            args["Since"] = SinceIds[_sinceIndex];
            string kw = _search.ValueText.Trim();
            if (kw.Length > 0) args["Keyword"] = kw;

            Bridge.Run(@"gui\Run-GuiReadyLogs.ps1", "read", args,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    var entries = Bridge.List(data != null && data.ContainsKey("Entries") ? data["Entries"] : null);
                    int count = (int)Bridge.Num(data, "Count", entries.Count);
                    bool truncated = Bridge.Bool(data, "Truncated");
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _entries.Clear();
                        _entries.AddRange(entries);
                        var rows = new List<string[]>();
                        foreach (var e in entries)
                            rows.Add(new[]
                            {
                                Bridge.Str(e, "Time"),
                                Bridge.Str(e, "Level"),
                                Bridge.Str(e, "Source"),
                                Bridge.Str(e, "Id"),
                                OneLine(Bridge.Str(e, "Message"))
                            });
                        _table.SetRows(rows);
                        SetStatus(truncated ? ("最新 " + count + " 条") : (count + " 条"),
                                  count > 0 ? "Info" : "Neutral");
                        Log("[INFO] 日志 " + _sources[_srcIndex].Name + "：" + count + " 条");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    _table.SetRows(new string[0][]);
                    SetStatus("读取失败", "Danger");
                    Log("[WARN] 日志读取失败: " + err);
                }), 180000);
        }

        // 导出当前筛选结果（走 logs runner 的 export 模式，筛选条件与界面完全一致）
        private void ExportCurrent()
        {
            if (_sources.Count == 0) { Log("[WARN] 还没读到日志来源，先点一次查询"); return; }
            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            string def = System.IO.Path.Combine(Bridge.StatePath, "logs-" + stamp + ".csv");

            var v = Dialogs.Prompt(FindForm(), "导出日志",
                "把当前来源 / 级别 / 时间范围 / 关键词下的条目导出（最多 2000 条）。\n格式填 Csv 或 Text（Text = 纯文本，便于直接看）。",
                new List<PromptField>
                {
                    new PromptField("导出文件（绝对路径）", def),
                    new PromptField("格式", "Csv")
                }, "导出");
            if (v == null || v[0].Trim().Length == 0) return;

            string fmt = v.Length > 1 && v[1].Trim().Length > 0 ? v[1].Trim() : "Csv";
            if (!fmt.Equals("Text", StringComparison.OrdinalIgnoreCase)) fmt = "Csv";

            var args = new Dictionary<string, object>();
            args["Source"] = _sources[_srcIndex].Id;
            args["Max"] = 2000;
            args["Level"] = LevelIds[_levelIndex];
            args["Since"] = SinceIds[_sinceIndex];
            string kw = _search.ValueText.Trim();
            if (kw.Length > 0) args["Keyword"] = kw;
            args["Path"] = v[0].Trim();
            args["Format"] = fmt;

            SetStatus("导出中…", "Info");
            Bridge.Run(@"gui\Run-GuiReadyLogs.ps1", "export", args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    int rows = (int)Bridge.Num(data, "Rows");
                    SetStatus(rows + " 条已导出", "Info");
                    Log("[OK] 日志已导出：" + Bridge.Str(data, "Path") + "（" + rows + " 行）");
                }),
                err => SafeInvoke(() =>
                {
                    SetStatus("导出失败", "Danger");
                    Log("[WARN] 日志导出失败: " + err);
                }), 180000);
        }

        // 事件消息经常带多行，表格只显示一行
        private static string OneLine(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            s = s.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");
            while (s.IndexOf("  ") >= 0) s = s.Replace("  ", " ");
            return s.Trim();
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            int x = 0;
            _srcBtn.Top = 72;
            _srcBtn.Left = x;
            x += _srcBtn.Width + 8;
            _levelBtn.Top = 72;
            _levelBtn.Left = x;
            x += _levelBtn.Width + 8;
            _sinceBtn.Top = 72;
            _sinceBtn.Left = x;
            x += _sinceBtn.Width + 8;

            int tail = 8 + _query.Width + 8 + _export.Width + 4;
            int searchW = Math.Max(120, Math.Min(300, w - x - tail));
            _search.Width = searchW;
            _search.Top = 72;
            _search.Left = x;
            x += searchW + 8;
            _query.Top = 72;
            _query.Left = x;
            x += _query.Width + 8;
            _export.Top = 72;
            _export.Left = x;

            _table.Left = 0;
            _table.Top = 116;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(120, ClientSize.Height - 124);
        }
    }

    internal sealed class TasksPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Pill _sum;
        private readonly UiButton _refresh;
        private readonly UiButton _cancel;
        private readonly UiButton _detail;
        private readonly UiButton _retry;
        private readonly UiButton _notify;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private bool _busy;
        private bool _detailBusy;

        public TasksPage()
        {
            Key = "tasks";
            TitleText = "任务中心";
            Subtitle = "每个动作都有任务编号、起止时间、退出码与完整日志；双击任务看详情与审计轨迹。";
            Glyph = "tasks";
            Accent = Theme.AccentOf("tasks");

            _sum = new Pill("读取中", "Neutral");
            Head.Slot.Controls.Add(_sum);
            Head.Slot.Width = _sum.Width;

            _refresh = new UiButton("刷新", ButtonKind.Normal, 88, 32);
            _refresh.Click += (s, e) => RefreshList();
            Controls.Add(_refresh);

            _cancel = new UiButton("取消任务", ButtonKind.Danger, 96, 32);
            _cancel.Click += (s, e) => CancelSelected();
            Controls.Add(_cancel);

            _detail = new UiButton("任务详情", ButtonKind.Normal, 96, 32);
            _detail.Click += (s, e) => ShowDetail();
            Controls.Add(_detail);

            _retry = new UiButton("重试", ButtonKind.Normal, 80, 32);
            _retry.Click += (s, e) => RetrySelected();
            Controls.Add(_retry);

            _notify = new UiButton("通知", ButtonKind.Normal, 88, 32);
            _notify.Click += (s, e) => ShowNotifications();
            Controls.Add(_notify);

            _table = new DataTable { Location = new Point(0, 116) };
            _table.Columns.Add(new DataColumn("排队时间", 140));
            _table.Columns.Add(new DataColumn("动作", 220));
            _table.Columns.Add(new DataColumn("状态", 88));
            _table.Columns.Add(new DataColumn("耗时", 74, true));
            _table.Columns.Add(new DataColumn("退出码", 74, true));
            _table.Columns.Add(new DataColumn("用户", 150));
            _table.Columns.Add(new DataColumn("任务编号", 210));
            _table.RowActivated += idx => ShowDetail();
            _table.ActivateOnDoubleClick = true;
            Controls.Add(_table);
        }

        protected override void OnActivated()
        {
            RefreshList();
        }

        // 页头胶囊：宽度跟着文字走，否则长文案会溢出页头
        private void SetSum(string text, string kind)
        {
            _sum.SetText(text);
            _sum.SetKind(kind);
            Head.Slot.Width = _sum.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        public void RefreshList()
        {
            if (_busy) return;
            _busy = true;
            SetSum("读取中", "Neutral");

            var args = new Dictionary<string, object>();
            args["Limit"] = 300;

            Bridge.Run(@"gui\Run-GuiReadyTasks.ps1", "list", args,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    var items = Bridge.List(data != null && data.ContainsKey("Items") ? data["Items"] : null);
                    var stats = Bridge.Dict(data != null && data.ContainsKey("Stats") ? data["Stats"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);
                        var rows = new List<string[]>();
                        foreach (var t in items)
                        {
                            string status = Bridge.Str(t, "Status");
                            object exit;
                            string exitText = "-";
                            if (t.TryGetValue("ExitCode", out exit) && exit != null) exitText = exit.ToString();
                            string action = Bridge.Str(t, "ActionName");
                            if (action.Length == 0) action = Bridge.Str(t, "ActionId");
                            if (Bridge.Bool(t, "DryRun")) action = "[预览] " + action;
                            rows.Add(new[]
                            {
                                TaskTime(Bridge.Str(t, "QueuedAt")),
                                action,
                                StatusText(status),
                                Bridge.Num(t, "DurationSec").ToString("0.#") + " 秒",
                                exitText,
                                Bridge.Str(t, "User"),
                                Bridge.Str(t, "Id")
                            });
                        }
                        _table.SetRows(rows);

                        int today = (int)Bridge.Num(stats, "TodayTotal");
                        int fail = (int)Bridge.Num(stats, "TodayFailed");
                        int running = (int)Bridge.Num(stats, "Running");
                        if (running > 0) SetSum("运行中 " + running + " · 今日 " + today + " 条",
                                                fail > 0 ? "Warn" : "Info");
                        else SetSum("今日 " + today + " 条 · 失败 " + fail,
                                    fail > 0 ? "Warn" : "Neutral");

                        Log("[INFO] 任务列表：" + rows.Count + " 条（今日 " + today + "，失败 " + fail + "）");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    _table.SetRows(new string[0][]);
                    SetSum("读取失败", "Danger");
                    Log("[WARN] 任务列表读取失败: " + err);
                }), 120000);
        }

        // 走既有 runner：Run-GuiReadyTasks.ps1 -Mode detail（任务本体 + 审计轨迹）
        private void ShowDetail()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _table.Rows.Count)
            {
                Log("[WARN] 先在列表里选中一条任务");
                return;
            }
            string id = _table.Rows[idx][6];
            if (_detailBusy) return;
            _detailBusy = true;
            Log("[STEP] 读取任务详情 " + id + " …");
            var args = new Dictionary<string, object>();
            args["Id"] = id;
            Bridge.Run(@"gui\Run-GuiReadyTasks.ps1", "detail", args,
                d => SafeInvoke(() =>
                {
                    _detailBusy = false;
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    var task = Bridge.Dict(data != null && data.ContainsKey("Task") ? data["Task"] : null);
                    if (task == null) { Log("[WARN] 任务不存在：" + id); return; }

                    var sb = new System.Text.StringBuilder();
                    sb.AppendLine("任务编号：" + Bridge.Str(task, "Id"));
                    sb.AppendLine("动作：    " + Bridge.Str(task, "ActionName") +
                                  "（" + Bridge.Str(task, "ActionId") + "）");
                    sb.AppendLine("分组：    " + Bridge.Str(task, "Group"));
                    sb.AppendLine("状态：    " + StatusText(Bridge.Str(task, "Status")) +
                                  " · 退出码 " + (task.ContainsKey("ExitCode") && task["ExitCode"] != null
                                                       ? task["ExitCode"].ToString() : "-"));
                    sb.AppendLine("耗时：    " + Bridge.Num(task, "DurationSec").ToString("0.#") + " 秒");
                    sb.AppendLine("排队：    " + TaskTime(Bridge.Str(task, "QueuedAt")));
                    sb.AppendLine("用户：    " + Bridge.Str(task, "User"));
                    if (Bridge.Bool(task, "DryRun")) sb.AppendLine("模式：    仅预览（未做实际改动）");
                    string retryOf = Bridge.Str(task, "RetryOf");
                    if (retryOf.Length > 0) sb.AppendLine("重试来源：" + retryOf);
                    string msg = Bridge.Str(task, "Message");
                    if (msg.Length > 0) sb.AppendLine("备注：    " + msg);

                    var ps = Bridge.Dict(task.ContainsKey("Params") ? task["Params"] : null);
                    if (ps != null && ps.Count > 0)
                    {
                        sb.AppendLine();
                        sb.AppendLine("参数");
                        foreach (var kv in ps)
                            sb.AppendLine("  " + kv.Key + " = " + (kv.Value == null ? "" : kv.Value.ToString()));
                    }

                    string logPath = Bridge.Str(task, "LogPath");
                    if (logPath.Length > 0)
                    {
                        sb.AppendLine();
                        sb.AppendLine("日志文件");
                        sb.AppendLine("  " + logPath);
                    }

                    var trail = Bridge.List(data.ContainsKey("Trail") ? data["Trail"] : null);
                    if (trail.Count > 0)
                    {
                        sb.AppendLine();
                        sb.AppendLine("审计轨迹");
                        foreach (var e in trail)
                            sb.AppendLine("  " + Bridge.Str(e, "Time") + "  " +
                                          Bridge.Str(e, "Event") + "  " + Bridge.Str(e, "Detail"));
                    }

                    string act = Dialogs.Text(FindForm(), "任务详情", id, sb.ToString(),
                        logPath.Length > 0 ? logPath : null);
                    if (act == "open" && logPath.Length > 0)
                    {
                        try
                        {
                            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                            {
                                FileName = logPath,
                                UseShellExecute = true
                            });
                            Log("[INFO] 已打开任务日志：" + logPath);
                        }
                        catch (Exception ex)
                        {
                            Log("[WARN] 打开任务日志失败: " + ex.Message);
                        }
                    }
                }),
                err => SafeInvoke(() =>
                {
                    _detailBusy = false;
                    Log("[WARN] 读取任务详情失败: " + err);
                }), 60000);
        }

        // 重试：用原任务的 ActionId + 参数重跑，并把 RetryOf 传下去（审计里能串起来）
        private void RetrySelected()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _items.Count) { Log("[WARN] 先选中一条任务"); return; }
            var t = _items[idx];
            string id = Bridge.Str(t, "Id");
            string actionId = Bridge.Str(t, "ActionId");
            if (actionId.Length == 0) { Log("[WARN] 这条任务没有记录动作 Id，无法重试"); return; }
            if (!Dialogs.Confirm(FindForm(), "重试任务",
                "按原动作重跑一次？\n\n动作：" + Bridge.Str(t, "ActionName", actionId) +
                "\n原任务：" + id, "重试")) return;

            var args = new Dictionary<string, object>();
            var ps = Bridge.Dict(t.ContainsKey("Params") ? t["Params"] : null);
            if (ps != null)
                foreach (var kv in ps)
                {
                    if (kv.Key == "__TaskId") continue;
                    args[kv.Key] = kv.Value;
                }
            args["DryRun"] = false;

            bool started = Actions.RunAction(actionId, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "重试结束，退出码 " + r.ExitCode +
                        "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    RefreshList();
                }),
                err => SafeInvoke(() => Log("[WARN] 重试未启动: " + err)), id);
            if (started) Log("[STEP] 已提交重试（" + actionId + "，来源 " + id + "）");
        }

        // 通知收件箱：列表 → 全部已读 / 清空
        private void ShowNotifications()
        {
            Bridge.Run(@"gui\Run-GuiReadyTasks.ps1", "notify",
                new Dictionary<string, object> { { "Limit", 100 } },
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    var items = Bridge.List(data != null && data.ContainsKey("Items") ? data["Items"] : null);
                    int unread = (int)Bridge.Num(data, "Unread");
                    SafeInvoke(() =>
                    {
                        var lines = new List<string>();
                        foreach (var n in items)
                        {
                            bool read = Bridge.Bool(n, "Read");
                            lines.Add((read ? "  " : "● ") +
                                      NoticeTime(Bridge.Str(n, "CreatedAt")) + "  " +
                                      Bridge.Str(n, "Title") + "：" +
                                      Bridge.Str(n, "Text"));
                        }
                        if (lines.Count == 0) lines.Add("（收件箱是空的）");

                        string act = Dialogs.Notice(FindForm(), "通知收件箱", lines, unread);
                        if (act == "readAll")
                            Bridge.Run(@"gui\Run-GuiReadyTasks.ps1", "notify-read",
                                new Dictionary<string, object> { { "All", true } },
                                x => SafeInvoke(() => Log("[OK] 已全部标为已读")),
                                e2 => SafeInvoke(() => Log("[WARN] 标记已读失败: " + e2)), 60000);
                        else if (act == "clear")
                            Bridge.Run(@"gui\Run-GuiReadyTasks.ps1", "notify-clear", null,
                                x => SafeInvoke(() => Log("[OK] 通知已清空")),
                                e2 => SafeInvoke(() => Log("[WARN] 清空通知失败: " + e2)), 60000);
                    });
                },
                err => SafeInvoke(() => Log("[WARN] 读取通知失败: " + err)), 60000);
        }

        private static string NoticeTime(string iso)
        {
            if (string.IsNullOrEmpty(iso)) return "";
            DateTime t;
            if (!DateTime.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.RoundtripKind, out t)) return iso;
            return t.ToString("MM-dd HH:mm");
        }

        // 走既有 runner：Run-GuiReadyTasks.ps1 -Mode cancel
        private void CancelSelected()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _table.Rows.Count)
            {
                Log("[WARN] 先在列表里选中一条任务");
                return;
            }
            string id = _table.Rows[idx][6];
            Log("[STEP] 取消任务 " + id);

            var args = new Dictionary<string, object>();
            args["Id"] = id;
            Bridge.Run(@"gui\Run-GuiReadyTasks.ps1", "cancel", args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    string msg = Bridge.Str(data, "Message", "已处理");
                    Log((Bridge.Bool(data, "Ok") ? "[OK] " : "[WARN] ") + msg);
                    RefreshList();
                }),
                err => SafeInvoke(() => Log("[WARN] 取消失败: " + err)), 60000);
        }

        private static string TaskTime(string iso)
        {
            if (string.IsNullOrEmpty(iso)) return "-";
            DateTime t;
            if (!DateTime.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.RoundtripKind, out t)) return "-";
            return t.ToString("MM-dd HH:mm:ss");
        }

        private static string StatusText(string s)
        {
            switch (s)
            {
                case "Queued": return "排队中";
                case "Running": return "运行中";
                case "Succeeded": return "成功";
                case "Failed": return "失败";
                case "Canceled": return "已取消";
                case "Interrupted": return "已中断";
                default: return string.IsNullOrEmpty(s) ? "未知" : s;
            }
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _refresh.Left = 0;
            _refresh.Top = 72;
            _cancel.Left = _refresh.Width + 8;
            _cancel.Top = 72;
            _detail.Left = _cancel.Right + 8;
            _detail.Top = 72;
            _retry.Left = _detail.Right + 8;
            _retry.Top = 72;
            _notify.Left = _retry.Right + 8;
            _notify.Top = 72;
            _table.Left = 0;
            _table.Top = 116;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(120, ClientSize.Height - 124);
        }
    }

    // ------------------------------------------------------------ 趋势条
    // PowerShell 版总览页有三条迷你曲线（CPU / 内存 / 系统盘），C# 版一开始漏了，这里补回来。
    internal sealed class TrendStrip : UiControl
    {
        public string Caption = "";
        public Color Accent = Theme.Accent;
        public string Suffix = " %";

        private readonly List<double> _values = new List<double>();
        private PointF[] _pts;               // 复用的点数组，避免每帧分配
        private const int MaxPoints = 60;

        public TrendStrip(string caption, Color accent)
        {
            Caption = caption;
            Accent = accent;
            BackColor = Theme.Card;
        }

        public void Push(double v)
        {
            // 取不到值时（-1）直接不记：宁可曲线断一截，也不要画一个假的 0
            if (double.IsNaN(v) || v < 0) return;
            _values.Add(v);
            while (_values.Count > MaxPoints) _values.RemoveAt(0);
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width, Height);
            Draw.GlassCard(g, r, Theme.RCard, Theme.Card, Theme.Border);

            Draw.Text(g, Caption, Theme.Font(9f, true), Theme.Hint,
                      new Rectangle(14, 6, Math.Max(40, Width - 100), 20));
            string last = _values.Count == 0 ? "—" : _values[_values.Count - 1].ToString("0.0") + Suffix;
            Draw.Text(g, last, Theme.Font(10.5f, true), Accent,
                      new Rectangle(Math.Max(20, Width - 96), 6, 82, 20), ContentAlignment.MiddleRight);

            var plot = new Rectangle(14, 30, Math.Max(20, Width - 28), Math.Max(12, Height - 38));
            using (var pen = new Pen(Theme.Divider))
                g.DrawLine(pen, plot.Left, plot.Bottom, plot.Right, plot.Bottom);
            if (_values.Count == 0) return;

            if (_values.Count == 1)
            {
                // 只有一个采样点时画一个点，别让面板看起来是空的
                double one = _values[0];
                if (one > 100) one = 100;
                float py = plot.Bottom - (float)(one / 100.0 * plot.Height);
                using (var b = new SolidBrush(Accent))
                    g.FillEllipse(b, plot.Left + plot.Width / 2f - 2.5f, py - 2.5f, 5, 5);
                return;
            }

            if (_pts == null || _pts.Length != _values.Count) _pts = new PointF[_values.Count];
            var pts = _pts;
            float stepX = plot.Width / (float)(_values.Count - 1);
            for (int i = 0; i < _values.Count; i++)
            {
                double v = _values[i];
                if (v > 100) v = 100;
                pts[i] = new PointF(plot.Left + i * stepX, plot.Bottom - (float)(v / 100.0 * plot.Height));
            }

            // 曲线下方的柔和填充：2 个点时也能一眼看出这是张趋势图
            using (var path = new GraphicsPath())
            {
                path.AddLines(pts);
                path.AddLine(pts[pts.Length - 1].X, plot.Bottom, pts[0].X, plot.Bottom);
                path.CloseFigure();
                using (var lg = new LinearGradientBrush(
                           new Rectangle(plot.Left, plot.Top, Math.Max(1, plot.Width), Math.Max(1, plot.Height)),
                           Color.FromArgb(70, Accent), Color.FromArgb(4, Accent),
                           LinearGradientMode.Vertical))
                    g.FillPath(lg, path);
            }
            using (var pen = new Pen(Accent, 1.6f)) g.DrawLines(pen, pts);
        }
    }
}

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 自动化：进程守护 / 计划任务 / 目录备份 / 端口巡检 / 下载队列。
    // 五个视图共用一张表，切换视图只换列与按钮（不重建页面，切回来不用重新加载）。
    // 数据来自 gui\Run-GuiReadyOps.ps1 -Mode list：
    //   定时的事都交给 Windows 计划任务（ScmOps-*），界面关掉也照跑；
    //   端口巡检与下载队列是按需操作，不排期。
    // ============================================================
    internal sealed class OpsPage : PageBase
    {
        private sealed class Item
        {
            public string Kind = "";
            public string Id = "";
            public string Name = "";
            public string Target = "";
            public string Schedule = "";
            public string State = "";
            public string Detail = "";
            public string LastTime = "";
            public string TaskState = "";
            public bool Enabled = true;
            public bool Running;
        }

        private static readonly string[] Modes = { "guard", "plan", "backup", "patrol", "download" };
        private static readonly string[] ModeText = { "进程守护", "计划任务", "目录备份", "端口巡检", "下载队列" };

        private readonly DataTable _table;
        private readonly Panel _tabs;
        private readonly Panel _bar;
        private readonly Pill _state;
        private readonly List<UiButton> _tabButtons = new List<UiButton>();
        private readonly List<UiButton> _barButtons = new List<UiButton>();
        private readonly Dictionary<string, List<UiButton>> _viewButtons = new Dictionary<string, List<UiButton>>();
        private readonly List<Item> _all = new List<Item>();
        private readonly List<Item> _view = new List<Item>();
        private string _mode = "guard";
        private bool _busy;

        public OpsPage()
        {
            Key = "ops";
            TitleText = "自动化";
            Subtitle = "进程守护、计划任务、目录备份、端口巡检与下载队列：定时的事交给 Windows 计划任务，界面关掉也照跑。";
            Glyph = "ops";
            Accent = Theme.AccentOf("ops");
            CacheSeconds = 10;

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _tabs = new Panel { BackColor = Color.Transparent, Location = new Point(0, 72) };
            Controls.Add(_tabs);
            for (int i = 0; i < Modes.Length; i++)
            {
                string mode = Modes[i];
                var b = new UiButton(ModeText[i], ButtonKind.Normal, 104, 32) { Location = new Point(0, 0) };
                b.Click += (s, e) => Switch(mode);
                _tabButtons.Add(b);
                _tabs.Controls.Add(b);
            }

            _table = new DataTable { Location = new Point(0, 112), RowHeight = 46 };
            Controls.Add(_table);

            _bar = new Panel { BackColor = Color.Transparent };
            Controls.Add(_bar);

            AddBar("guard", "添加守护", ButtonKind.Primary, 100, AddGuard);
            AddBar("guard", "立即检查", ButtonKind.Normal, 96, () => RunSelected("guard-check", "检查守护", true));
            AddBar("guard", "启用 / 暂停", ButtonKind.Normal, 100, ToggleSelected);
            AddBar("guard", "删除", ButtonKind.Danger, 76, () => RemoveSelected("guard-remove", "守护"));
            AddBar("guard", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBar("plan", "添加计划", ButtonKind.Primary, 100, AddPlan);
            AddBar("plan", "立即执行", ButtonKind.Normal, 96, () => RunSelected("plan-run", "执行计划", false));
            AddBar("plan", "启用 / 暂停", ButtonKind.Normal, 100, ToggleSelected);
            AddBar("plan", "删除", ButtonKind.Danger, 76, () => RemoveSelected("plan-remove", "计划"));
            AddBar("plan", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBar("backup", "添加备份", ButtonKind.Primary, 100, AddBackup);
            AddBar("backup", "立即备份", ButtonKind.Normal, 96, () => RunSelected("backup-run", "执行备份", false));
            AddBar("backup", "删除", ButtonKind.Danger, 76, () => RemoveSelected("backup-remove", "备份任务"));
            AddBar("backup", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBar("patrol", "添加巡检", ButtonKind.Primary, 100, AddPatrol);
            AddBar("patrol", "巡检一次", ButtonKind.Normal, 96, () => RunSelected("patrol-run", "端口巡检", false));
            AddBar("patrol", "删除", ButtonKind.Danger, 76, () => RemoveSelected("patrol-remove", "巡检目标"));
            AddBar("patrol", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBar("download", "添加下载", ButtonKind.Primary, 100, AddDownload);
            AddBar("download", "暂停", ButtonKind.Normal, 72, () => DownloadAction("download-pause", "暂停下载"));
            AddBar("download", "继续", ButtonKind.Normal, 72, () => DownloadAction("download-resume", "继续下载"));
            AddBar("download", "完成", ButtonKind.Normal, 72, () => DownloadAction("download-complete", "收尾下载"));
            AddBar("download", "取消", ButtonKind.Danger, 72, () => DownloadAction("download-cancel", "取消下载"));
            AddBar("download", "移除", ButtonKind.Ghost, 88, () => DownloadAction("download-remove", "移除记录"));
            AddBar("download", "刷新", ButtonKind.Ghost, 72, () => Load());

            ApplyView();
        }

        private void AddBar(string mode, string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 34) { Location = new Point(0, 0), Visible = false };
            b.Click += (s, e) => onClick();
            List<UiButton> list;
            if (!_viewButtons.TryGetValue(mode, out list)) { list = new List<UiButton>(); _viewButtons[mode] = list; }
            list.Add(b);
            _barButtons.Add(b);
            _bar.Controls.Add(b);
        }

        protected override void BuildContent() { }

        protected override void OnActivated()
        {
            Load();
        }

        // ---------------------------------------------------------- 读取
        private void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState("读取中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadyOps.ps1", "list", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        Fill(items);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 自动化数据读取失败: " + err);
                }), 120000);
        }

        private void Fill(List<Dictionary<string, object>> items)
        {
            _all.Clear();
            int guard = 0, plan = 0, backup = 0, patrol = 0, download = 0;
            foreach (var d in items)
            {
                var it = new Item
                {
                    Kind = Bridge.Str(d, "Kind"),
                    Id = Bridge.Str(d, "Id"),
                    Name = Bridge.Str(d, "Name"),
                    Target = Bridge.Str(d, "Target"),
                    Schedule = Bridge.Str(d, "Schedule"),
                    State = Bridge.Str(d, "State"),
                    Detail = Bridge.Str(d, "Detail"),
                    LastTime = Bridge.Str(d, "LastTime"),
                    TaskState = Bridge.Str(d, "TaskState"),
                    Enabled = Bridge.Bool(d, "Enabled", true),
                    Running = Bridge.Bool(d, "Running")
                };
                _all.Add(it);
                switch (it.Kind)
                {
                    case "guard": guard++; break;
                    case "plan": plan++; break;
                    case "backup": backup++; break;
                    case "patrol": patrol++; break;
                    case "download": download++; break;
                }
            }
            Log("[INFO] 自动化：" + guard + " 个守护 · " + plan + " 条计划 · " + backup + " 个备份 · " +
                patrol + " 个巡检 · " + download + " 个下载");
            ApplyView();
        }

        // ---------------------------------------------------------- 视图
        private void Switch(string mode)
        {
            if (_mode == mode) return;
            _mode = mode;
            ApplyView();
        }

        private void ApplyView()
        {
            for (int i = 0; i < _tabButtons.Count; i++)
            {
                // 选中的页签用主色，其余保持普通按钮
                _tabButtons[i].Kind = Modes[i] == _mode ? ButtonKind.Primary : ButtonKind.Normal;
                _tabButtons[i].Invalidate();
            }

            _table.Columns.Clear();
            switch (_mode)
            {
                case "guard":
                    _table.Columns.Add(new DataColumn("名称", 170));
                    _table.Columns.Add(new DataColumn("程序", 330));
                    _table.Columns.Add(new DataColumn("检查", 100));
                    _table.Columns.Add(new DataColumn("状态", 96));
                    _table.Columns.Add(new DataColumn("最近", 210));
                    break;
                case "plan":
                    _table.Columns.Add(new DataColumn("名称", 170));
                    _table.Columns.Add(new DataColumn("动作链", 280));
                    _table.Columns.Add(new DataColumn("频率", 120));
                    _table.Columns.Add(new DataColumn("状态", 96));
                    _table.Columns.Add(new DataColumn("最近结果", 240));
                    break;
                case "backup":
                    _table.Columns.Add(new DataColumn("名称", 150));
                    _table.Columns.Add(new DataColumn("源 → 目标", 360));
                    _table.Columns.Add(new DataColumn("计划", 210));
                    _table.Columns.Add(new DataColumn("状态", 90));
                    _table.Columns.Add(new DataColumn("最近结果", 210));
                    break;
                case "patrol":
                    _table.Columns.Add(new DataColumn("名称", 170));
                    _table.Columns.Add(new DataColumn("目标", 260));
                    _table.Columns.Add(new DataColumn("超时", 100));
                    _table.Columns.Add(new DataColumn("最近结果", 140));
                    _table.Columns.Add(new DataColumn("说明", 240));
                    break;
                default:
                    _table.Columns.Add(new DataColumn("文件", 220));
                    _table.Columns.Add(new DataColumn("大小", 150));
                    _table.Columns.Add(new DataColumn("状态", 120));
                    _table.Columns.Add(new DataColumn("进度", 300));
                    _table.Columns.Add(new DataColumn("来源", 300));
                    break;
            }

            _view.Clear();
            var rows = new List<string[]>();
            foreach (var it in _all)
            {
                if (it.Kind != _mode) continue;
                _view.Add(it);
                rows.Add(Cells(it));
            }
            _table.SetRows(rows);

            switch (_mode)
            {
                case "guard":
                    SetState(_view.Count + " 个守护 · 运行中 " + CountRunning() + " 个", _view.Count > 0 ? "Info" : "Neutral");
                    break;
                case "plan":
                    SetState(_view.Count + " 条计划", _view.Count > 0 ? "Info" : "Neutral");
                    break;
                case "backup":
                    SetState(_view.Count + " 个备份任务", _view.Count > 0 ? "Info" : "Neutral");
                    break;
                case "patrol":
                    SetState(_view.Count + " 个巡检目标", _view.Count > 0 ? "Info" : "Neutral");
                    break;
                default:
                    SetState(_view.Count + " 条下载", _view.Count > 0 ? "Info" : "Neutral");
                    break;
            }

            foreach (var kv in _viewButtons)
            {
                bool on = kv.Key == _mode;
                foreach (var b in kv.Value) b.Visible = on;
            }
            LayoutButtons();
        }

        private int CountRunning()
        {
            int n = 0;
            foreach (var it in _view) if (it.Running) n++;
            return n;
        }

        private static string[] Cells(Item it)
        {
            switch (it.Kind)
            {
                case "guard":
                    return new[] { it.Name, it.Target, it.Schedule, it.State, ShortTime(it.LastTime) + " · " + it.Detail };
                case "plan":
                    return new[] { it.Name, it.Target, it.Schedule, it.State, it.Detail };
                case "backup":
                    return new[] { it.Name, it.Target, it.Schedule, it.State, it.Detail };
                case "patrol":
                    return new[] { it.Name, it.Target, it.Schedule, it.State, it.Detail };
                default:
                    return new[] { it.Name, it.Schedule, it.State, it.Detail, it.Target };
            }
        }

        private static string ShortTime(string iso)
        {
            if (string.IsNullOrEmpty(iso)) return "还没跑过";
            DateTime t;
            if (DateTime.TryParse(iso, out t)) return t.ToString("MM-dd HH:mm");
            return iso;
        }

        // ---------------------------------------------------------- 选择
        private Item Selected()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _view.Count) return null;
            return _view[idx];
        }

        private Item RequireSelected()
        {
            var it = Selected();
            if (it == null) Log("[WARN] 先在列表里选一行");
            return it;
        }

        // ---------------------------------------------------------- 进程守护
        private void AddGuard()
        {
            var fields = new List<PromptField>
            {
                new PromptField("名称（例如 Minecraft 服务端）", ""),
                new PromptField("程序路径（exe）", ""),
                new PromptField("启动参数（可空）", ""),
                new PromptField("工作目录（留空 = exe 所在目录）", ""),
                new PromptField("检查间隔（分钟，最小 1）", "1"),
                new PromptField("启动失败退避基数（秒）", "15"),
                new PromptField("运行身份", "", new List<string> { "当前登录用户（交互会话）", "系统账户 SYSTEM（无窗口）" })
            };
            var v = Dialogs.Prompt(FindForm(), "添加进程守护",
                "每 N 分钟检查一次：进程不在就用原参数拉起；连续启动失败按退避重试（最多 5 分钟一次）。\r\n" +
                "要守护有窗口的程序请选「当前登录用户」；后台服务选 SYSTEM。", fields, "添加", 560);
            if (v == null) return;
            if (v[0].Trim().Length == 0 || v[1].Trim().Length == 0)
            {
                Log("[WARN] 名称和程序路径都要填");
                return;
            }

            var args = new Dictionary<string, object>
            {
                { "Name", v[0].Trim() },
                { "Exe", v[1].Trim() },
                { "Args", v[2].Trim() },
                { "WorkDir", v[3].Trim() },
                { "IntervalMin", v[4].Trim() },
                { "DelaySec", v[5].Trim() },
                { "RunAs", v[6].StartsWith("系统") ? "system" : "user" }
            };
            RunAction("guard-add", args, "添加守护");
        }

        private void AddPlan()
        {
            var fields = new List<PromptField>
            {
                new PromptField("名称", "每日配置备份"),
                new PromptField("动作链（动作 Id，; 分隔）", "backup-export"),
                new PromptField("频率", "", new List<string> { "按间隔重复", "每天定时", "每周定时" }),
                new PromptField("每周几（仅「每周定时」用）", "", new List<string>
                {
                    "周一", "周二", "周三", "周四", "周五", "周六", "周日"
                }),
                new PromptField("间隔（分钟）", "60"),
                new PromptField("执行时间（HH:mm）", "03:00"),
                new PromptField("运行身份", "", new List<string> { "当前登录用户（交互会话）", "系统账户 SYSTEM（无窗口）" })
            };
            var v = Dialogs.Prompt(FindForm(), "添加计划任务",
                "按间隔、每天或每周定时，依次执行一串已有动作。动作 Id 可以到「全部功能」里看（例如 backup-export、reboot、log-export）。\r\n" +
                "动作链里的动作请选不需要额外参数的那些。", fields, "添加", 580);
            if (v == null) return;
            if (v[0].Trim().Length == 0 || v[1].Trim().Length == 0)
            {
                Log("[WARN] 名称和动作链都要填");
                return;
            }

            var args = new Dictionary<string, object>
            {
                { "Name", v[0].Trim() },
                { "Chain", v[1].Trim() },
                { "Schedule", v[2].StartsWith("每周") ? "weekly" : (v[2].StartsWith("每天") ? "daily" : "interval") },
                { "Weekday", WeekdayOf(v[3]) },
                { "IntervalMin", v[4].Trim() },
                { "Time", v[5].Trim() },
                { "RunAs", v[6].StartsWith("系统") ? "system" : "user" }
            };
            RunAction("plan-add", args, "添加计划");
        }

        private static string WeekdayOf(string text)
        {
            if (text.StartsWith("周二")) return "Tuesday";
            if (text.StartsWith("周三")) return "Wednesday";
            if (text.StartsWith("周四")) return "Thursday";
            if (text.StartsWith("周五")) return "Friday";
            if (text.StartsWith("周六")) return "Saturday";
            if (text.StartsWith("周日")) return "Sunday";
            return "Monday";
        }

        private void ToggleSelected()
        {
            var it = RequireSelected();
            if (it == null) return;
            string action = _mode == "guard" ? "guard-toggle" : "plan-toggle";
            var args = new Dictionary<string, object>
            {
                { "Id", it.Id },
                { "Enabled", it.Enabled ? 0 : 1 }
            };
            RunAction(action, args, (it.Enabled ? "暂停 " : "启用 ") + it.Name);
        }

        // ---------------------------------------------------------- 备份 / 巡检
        private void AddBackup()
        {
            var fields = new List<PromptField>
            {
                new PromptField("名称", ""),
                new PromptField("源目录", ""),
                new PromptField("备份存放目录", ""),
                new PromptField("方式", "", new List<string> { "zip（压缩包）", "copy（整目录复制）" }),
                new PromptField("保留份数", "3"),
                new PromptField("每天执行时间（HH:mm）", "02:00"),
                new PromptField("运行身份", "", new List<string> { "当前登录用户（交互会话）", "系统账户 SYSTEM（无窗口）" })
            };
            var v = Dialogs.Prompt(FindForm(), "添加目录备份",
                "把源目录打包成 <名称>-<时间戳>.zip 放到备份目录，每天定时执行，只保留最新 N 份。\r\n" +
                "目标目录不能放在源目录里面。", fields, "添加", 580);
            if (v == null) return;
            if (v[0].Trim().Length == 0 || v[1].Trim().Length == 0 || v[2].Trim().Length == 0)
            {
                Log("[WARN] 名称、源目录、备份目录都要填");
                return;
            }

            var args = new Dictionary<string, object>
            {
                { "Name", v[0].Trim() },
                { "Source", v[1].Trim() },
                { "Target", v[2].Trim() },
                { "BackupMode", v[3].StartsWith("copy") ? "copy" : "zip" },
                { "Keep", v[4].Trim() },
                { "Time", v[5].Trim() },
                { "RunAs", v[6].StartsWith("系统") ? "system" : "user" }
            };
            RunAction("backup-add", args, "添加目录备份");
        }

        private void AddPatrol()
        {
            var fields = new List<PromptField>
            {
                new PromptField("名称", ""),
                new PromptField("主机（留空 = 127.0.0.1）", "127.0.0.1"),
                new PromptField("端口（逗号分隔，例如 80,443,3389）", ""),
                new PromptField("单端口超时（毫秒）", "1500")
            };
            var v = Dialogs.Prompt(FindForm(), "添加端口巡检目标",
                "登记一组要盯的端口。本机端口会顺便显示监听进程；巡检不排期，需要时点「巡检一次」。", fields, "添加", 540);
            if (v == null) return;
            if (v[0].Trim().Length == 0 || v[2].Trim().Length == 0)
            {
                Log("[WARN] 名称和端口都要填");
                return;
            }

            var args = new Dictionary<string, object>
            {
                { "Name", v[0].Trim() },
                { "Host", v[1].Trim().Length == 0 ? "127.0.0.1" : v[1].Trim() },
                { "Ports", v[2].Trim() },
                { "TimeoutMs", v[3].Trim() }
            };
            RunAction("patrol-add", args, "添加巡检目标");
        }

        // ---------------------------------------------------------- 下载
        private void AddDownload()
        {
            var fields = new List<PromptField>
            {
                new PromptField("下载地址（http / https）", ""),
                new PromptField("保存目录（留空 = payload\\downloads）", ""),
                new PromptField("另存文件名（留空 = 用 URL 里的文件名）", "")
            };
            var v = Dialogs.Prompt(FindForm(), "添加下载",
                "用 Windows 自带的 BITS 后台传输：断点续传、可暂停，关掉界面也继续下载。", fields, "开始下载", 600);
            if (v == null) return;
            if (v[0].Trim().Length == 0)
            {
                Log("[WARN] 下载地址不能为空");
                return;
            }

            var args = new Dictionary<string, object>
            {
                { "Url", v[0].Trim() },
                { "Folder", v[1].Trim() },
                { "FileName", v[2].Trim() }
            };
            RunAction("download-add", args, "添加下载");
        }

        private void DownloadAction(string action, string title)
        {
            var it = RequireSelected();
            if (it == null) return;
            if (!Dialogs.Confirm(FindForm(), title, it.Name + "\r\n\r\n" + it.Target, title)) return;
            RunAction(action, new Dictionary<string, object> { { "Id", it.Id } }, title + " " + it.Name);
        }

        // ---------------------------------------------------------- 删除 / 通用执行
        private void RemoveSelected(string action, string what)
        {
            var it = RequireSelected();
            if (it == null) return;
            string extra = what == "备份任务" ? "\r\n\r\n已经生成的备份文件不会删除。" : "";
            if (!Dialogs.Confirm(FindForm(), "删除" + what,
                "删除「" + it.Name + "」？" + extra, "删除")) return;
            RunAction(action, new Dictionary<string, object> { { "Id", it.Id } }, "删除" + what);
        }

        // allowEmptyId：guard-check 留空表示全部检查
        private void RunSelected(string action, string title, bool allowEmptyId)
        {
            var it = Selected();
            if (it == null && !allowEmptyId) { Log("[WARN] 先在列表里选一行"); return; }
            var args = new Dictionary<string, object>();
            if (it != null) args["Id"] = it.Id;
            RunAction(action, args, title);
        }

        private void RunAction(string actionId, Dictionary<string, object> args, string title)
        {
            SetState(title + "…", "Info");
            bool started = Actions.RunAction(actionId, args,
                line => SafeInvoke(() => Log(line)),
                res => SafeInvoke(() =>
                {
                    Log((res.ExitCode == 0 ? "[OK] " : "[ERROR] ") + title + "结束，退出码 " +
                        res.ExitCode + "，用时 " + res.Seconds.ToString("0.0") + " 秒");
                    if (res.ExitCode != 0) SetState(title + "失败", "Danger");
                    Load();
                }),
                err => SafeInvoke(() =>
                {
                    SetState("未启动", "Warn");
                    Log("[WARN] " + title + "未启动: " + err);
                }));
            if (!started) SetState("已有动作在跑", "Warn");
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        // ---------------------------------------------------------- 布局
        private void LayoutButtons()
        {
            int x = 0;
            foreach (var b in _tabButtons)
            {
                b.Left = x;
                b.Top = 0;
                x += b.Width + 8;
            }
        }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _tabs.Left = 0;
            _tabs.Top = 72;
            _tabs.Width = Math.Max(200, w - 4);
            _tabs.Height = 32;
            LayoutButtons();

            _table.Left = 0;
            _table.Top = 112;
            _table.Width = Math.Max(200, w - 4);

            _bar.Left = 0;
            _bar.Width = Math.Max(200, w - 4);
            var visible = new List<UiButton>();
            foreach (var b in _barButtons) if (b.Visible) visible.Add(b);
            int bh = LayoutButtonRow(visible, _bar.Width, 0);
            _bar.Height = bh;
            _table.Height = Math.Max(110, ClientSize.Height - 112 - bh - 22);
            _bar.Top = _table.Bottom + 6;
        }
    }
}

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 阶段 2/3：补齐剩余页面（商店 / 程序 / 文件 / 审计 / 主机 /
    // 角色 / 安全 / 工具 / 美化 / AI / 全部功能 / 关于）。
    // 除「程序档案」外都已接真实 runner 或本机检测。
    // 排版约定与 Pages.cs 一致：内容从 Top = 76 开始，表格宽 = 宽 - 4。
    // ============================================================


    // ------------------------------------------------------------ 程序管理（运行清单）
    internal sealed class AppPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private bool _busy;

        public AppPage()
        {
            Key = "app";
            TitleText = "程序管理";
            Subtitle = "把要运行的程序加进来：双击启动，启动参数自动带入档案推荐值；可绑定终端命令或设为后台常驻。";
            Glyph = "app";
            Accent = Theme.AccentOf("app");

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn("名称", 150));
            _table.Columns.Add(new DataColumn("路径", 320));
            _table.Columns.Add(new DataColumn("启动参数", 170));
            _table.Columns.Add(new DataColumn("兼容结论", 160));
            _table.Columns.Add(new DataColumn("命令", 80));
            _table.ActivateOnDoubleClick = true;
            _table.RowActivated += idx => LaunchSelected();
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);
            AddButton("添加程序…", ButtonKind.Primary, 116, AddProgram);
            AddButton("启动", ButtonKind.Normal, 80, LaunchSelected);
            AddButton("设置参数…", ButtonKind.Normal, 110, EditArgs);
            AddButton("绑定命令…", ButtonKind.Normal, 110, BindCommand);
            AddButton("后台常驻", ButtonKind.Normal, 104, Persist);
            AddButton("启动诊断", ButtonKind.Normal, 100, Diagnose);
            AddButton("查看档案", ButtonKind.Normal, 96, ShowCatalog);
            AddButton("移除", ButtonKind.Danger, 80, RemoveProgram);
        }

        private void AddButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 0) };
            b.Click += (s, e) => onClick();
            _buttons.Add(b);
            _actions.Controls.Add(b);
        }

        protected override void OnActivated()
        {
            Load();
        }

        // Run-GuiReadyPrograms.ps1 -Mode list -> Data.Items（含兼容结论）
        public void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState("读取中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadyPrograms.ps1", "list", null,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    var items = Bridge.List(data != null && data.ContainsKey("Items") ? data["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);

                        var rows = new List<string[]>();
                        foreach (var it in items)
                        {
                            rows.Add(new[]
                            {
                                Bridge.Str(it, "Name"),
                                Bridge.Str(it, "Path"),
                                Bridge.Str(it, "Args"),
                                Bridge.Str(it, "Verdict"),
                                Bridge.Str(it, "Cmd")
                            });
                        }
                        _table.SetRows(rows);
                        SetState(rows.Count + " 个程序", rows.Count > 0 ? "Info" : "Neutral");
                        Log("[INFO] 程序清单：" + rows.Count + " 个");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 程序清单读取失败: " + err);
                }), 120000);
        }

        private Dictionary<string, object> Selected()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _items.Count) return null;
            return _items[idx];
        }

        private void AddProgram()
        {
            string path;
            using (var dlg = new OpenFileDialog())
            {
                dlg.Title = "选择要加入的程序";
                dlg.Filter = "可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*";
                if (dlg.ShowDialog(FindForm()) != DialogResult.OK) return;
                path = dlg.FileName;
            }

            var args = new Dictionary<string, object>();
            args["Path"] = path;
            Log("[STEP] 加入程序 " + path);
            Bridge.Run(@"gui\Run-GuiReadyPrograms.ps1", "add", args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    string rec = Bridge.Str(data, "Args");
                    Log((Bridge.Bool(data, "Added", true) ? "[OK] 已加入：" : "[INFO] 已在清单里：") + path);
                    if (rec.Length > 0) Log("[INFO] 已自动带入档案推荐参数：" + rec);
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] 加入失败: " + err)), 60000);
        }

        private void LaunchSelected()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先选中一个程序"); return; }

            string path = Bridge.Str(it, "Path");
            string args = Bridge.Str(it, "Args");
            if (!System.IO.File.Exists(path))
            {
                Log("[WARN] 文件不存在：" + path);
                return;
            }
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = path,
                    Arguments = args,
                    UseShellExecute = true,
                    WorkingDirectory = System.IO.Path.GetDirectoryName(path)
                };
                System.Diagnostics.Process.Start(psi);
                Log("[OK] 已启动 " + Bridge.Str(it, "Name") + (args.Length > 0 ? " " + args : ""));
            }
            catch (Exception ex)
            {
                Log("[WARN] 启动失败: " + ex.Message);
            }
        }

        private void EditArgs()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先选中一个程序"); return; }

            var v = Dialogs.Prompt(FindForm(), "设置启动参数",
                "留空表示不带参数。档案里的推荐参数已经预填。",
                new List<PromptField> { new PromptField("启动参数", Bridge.Str(it, "Args")) }, "保存");
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args["Path"] = Bridge.Str(it, "Path");
            args["Args"] = v[0];
            Bridge.Run(@"gui\Run-GuiReadyPrograms.ps1", "update", args,
                d => SafeInvoke(() =>
                {
                    Log("[OK] 已保存启动参数：" + Bridge.Str(it, "Name"));
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] 保存参数失败: " + err)), 60000);
        }

        private void BindCommand()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先选中一个程序"); return; }

            var v = Dialogs.Prompt(FindForm(), "绑定终端命令",
                "只允许字母、数字、点、下划线、加号、减号；留空表示解除绑定。\n" +
                "写入 System32 需要管理员权限。",
                new List<PromptField> { new PromptField("命令名（如 wx）", Bridge.Str(it, "Cmd")) }, "绑定");
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args["Path"] = Bridge.Str(it, "Path");
            args["Alias"] = v[0].Trim();
            Bridge.Run(@"gui\Run-GuiReadyPrograms.ps1", "bind", args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    if (Bridge.Bool(data, "Ok"))
                    {
                        string cmd = Bridge.Str(data, "Cmd");
                        if (cmd.Length == 0) Log("[OK] 已解除终端命令绑定");
                        else Log("[OK] 已绑定命令 " + cmd + " → " + Bridge.Str(it, "Name"));
                    }
                    else
                    {
                        Log("[WARN] 绑定失败：" + BindError(Bridge.Str(data, "Code")));
                    }
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] 绑定失败: " + err)), 60000);
        }

        private static string BindError(string code)
        {
            switch (code)
            {
                case "AliasEmpty": return "命令名不能为空";
                case "AliasTooLong": return "命令名太长（上限 32 个字符）";
                case "AliasBadChar": return "命令名只能包含字母、数字、点、下划线、加号、减号";
                case "AliasReserved": return "这是系统或工具的保留命令名，换一个";
                case "ExeMissing": return "程序文件不存在";
                case "Occupied": return "System32 里已有同名 .cmd，且不是本工具写的，不覆盖";
                default: return string.IsNullOrEmpty(code) ? "写入失败" : ("写入失败：" + code);
            }
        }

        private void Persist()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先选中一个程序"); return; }
            string path = Bridge.Str(it, "Path");
            if (!Dialogs.Confirm(FindForm(), "设为后台常驻",
                "会用 SYSTEM 计划任务启动它，进程不会随远程会话断开被杀掉。\n\n程序：" + path, "设为常驻"))
                return;

            var args = new Dictionary<string, object>();
            args["Path"] = path;
            args["Name"] = "";
            args["Args"] = Bridge.Str(it, "Args");
            args["WorkDir"] = "";
            args["AtStartup"] = false;
            args["DryRun"] = false;
            bool started = Actions.RunAction("persistent-run", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() => Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") +
                                         "后台常驻设置结束，退出码 " + r.ExitCode)),
                err => SafeInvoke(() => Log("[WARN] 后台常驻未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 持久化启动程序（persistent-run）");
        }

        private void Diagnose()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先选中一个程序"); return; }

            var args = new Dictionary<string, object>();
            args["Path"] = Bridge.Str(it, "Path");
            args["DryRun"] = false;
            bool started = Actions.RunAction("diag", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() => Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") +
                                         "诊断结束，退出码 " + r.ExitCode)),
                err => SafeInvoke(() => Log("[WARN] 诊断未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 启动并诊断（diag）");
        }

        private void ShowCatalog()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先选中一个程序"); return; }

            var args = new Dictionary<string, object>();
            args["Path"] = Bridge.Str(it, "Path");
            Bridge.Run(@"gui\Run-GuiReadyPrograms.ps1", "catalog", args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    var entry = Bridge.Dict(data != null && data.ContainsKey("Entry") ? data["Entry"] : null);
                    var ctx = Bridge.Dict(data != null && data.ContainsKey("Context") ? data["Context"] : null);
                    if (ctx != null)
                        Log("[INFO] 类型：子系统 " + Bridge.Str(ctx, "Subsystem") +
                            " · .NET " + (Bridge.Bool(ctx, "IsDotNet") ? "是" : "否") +
                            (Bridge.Str(ctx, "KindTag").Length > 0 ? " · " + Bridge.Str(ctx, "KindTag") : ""));
                    if (entry == null) { Log("[WARN] 档案里没有匹配条目"); return; }
                    Log("[OK] " + Bridge.Str(entry, "Name") + "（" + Bridge.Str(entry, "Id") + "）");
                    Log("[INFO] 结论：" + Bridge.Str(entry, "Verdict") + " · 类型 " + Bridge.Str(entry, "Type"));
                    if (Bridge.Str(entry, "LaunchArgs").Length > 0)
                        Log("[INFO] 推荐参数：" + Bridge.Str(entry, "LaunchArgs"));
                    if (Bridge.Str(entry, "Notes").Length > 0) Log("[INFO] " + Bridge.Str(entry, "Notes"));
                    if (Bridge.Str(entry, "Evidence").Length > 0) Log("[INFO] 证据：" + Bridge.Str(entry, "Evidence"));
                }),
                err => SafeInvoke(() => Log("[WARN] 读取档案失败: " + err)), 60000);
        }

        private void RemoveProgram()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先选中一个程序"); return; }
            string name = Bridge.Str(it, "Name");
            if (!Dialogs.Confirm(FindForm(), "移除程序",
                "只从清单里移除「" + name + "」，不会删除磁盘上的文件。绑定的终端命令也会一起解绑。", "移除"))
                return;

            var args = new Dictionary<string, object>();
            args["Path"] = Bridge.Str(it, "Path");
            Bridge.Run(@"gui\Run-GuiReadyPrograms.ps1", "remove", args,
                d => SafeInvoke(() =>
                {
                    Log("[OK] 已移除 " + name);
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] 移除失败: " + err)), 60000);
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _table.Left = 0;
            _table.Top = 76;
            _table.Width = Math.Max(200, w - 4);

            _actions.Left = 0;
            _actions.Width = Math.Max(200, w - 4);
            int bh = LayoutButtonRow(_buttons, _actions.Width, 0);
            _actions.Height = bh;
            _table.Height = Math.Max(110, ClientSize.Height - 76 - bh - 22);
            _actions.Top = _table.Bottom + 6;
        }
    }

    // ------------------------------------------------------------ 程序档案（兼容知识库）
    internal sealed class CatalogPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private bool _busy;

        public CatalogPage()
        {
            Key = "catalog";
            TitleText = "SCM附属";
            Subtitle = "SCM 的附属工具与扩展（内容待定）；目前先沿用内置程序兼容档案：程序在 Server Core 上能不能跑、要补什么运行时、推荐哪些启动参数。";
            Glyph = "app";
            Accent = Theme.AccentOf("app");

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn("名称", 230));
            _table.Columns.Add(new DataColumn("匹配", 150));
            _table.Columns.Add(new DataColumn("结论", 100));
            _table.Columns.Add(new DataColumn("推荐参数", 170));
            _table.Columns.Add(new DataColumn("来源", 80));
            _table.Columns.Add(new DataColumn("备注", 290));
            _table.RowActivated += ShowDetail;
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton("添加档案…", ButtonKind.Primary, 116, AddEntry);
            AddButton("删除选中", ButtonKind.Danger, 104, RemoveEntry);
            AddButton("刷新", ButtonKind.Normal, 80, Load);
        }

        private void AddButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 0) };
            b.Click += (s, e) => onClick();
            _buttons.Add(b);
            _actions.Controls.Add(b);
        }

        protected override void OnActivated()
        {
            Load();
        }

        // Run-GuiReadyCatalog.ps1 -Mode list -> 顶层 Items
        public void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState("读取中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadyCatalog.ps1", "list", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);

                        var rows = new List<string[]>();
                        int user = 0;
                        foreach (var it in items)
                        {
                            if (Bridge.Bool(it, "IsUserEntry")) user++;
                            rows.Add(new[]
                            {
                                Bridge.Str(it, "Name", Bridge.Str(it, "Id")),
                                Clean(Bridge.Str(it, "Match")),
                                Bridge.Str(it, "Verdict"),
                                Clean(Bridge.Str(it, "LaunchArgs")),
                                Bridge.Bool(it, "IsUserEntry") ? "自建" : "内置",
                                Clean(Bridge.Str(it, "Notes"))
                            });
                        }
                        _table.SetRows(rows);
                        SetState(rows.Count + " 条 · 自建 " + user, rows.Count > 0 ? "Info" : "Neutral");
                        Log("[INFO] 程序档案：" + rows.Count + " 条（自建 " + user + " 条）");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 程序档案读取失败: " + err);
                }), 60000);
        }

        // 档案里的「空」有很多种写法，统一收一下
        private static string Clean(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            s = s.Trim(' ', '、', ',', ';');
            return s;
        }

        private void ShowDetail(int idx)
        {
            if (idx < 0 || idx >= _items.Count) return;
            var it = _items[idx];
            Log("[INFO] " + Bridge.Str(it, "Name") +
                " · 结论 " + Bridge.Str(it, "Verdict") +
                " · 匹配 " + Clean(Bridge.Str(it, "Match")) +
                (Clean(Bridge.Str(it, "LaunchArgs")).Length > 0
                    ? " · 参数 " + Clean(Bridge.Str(it, "LaunchArgs")) : ""));
            string notes = Clean(Bridge.Str(it, "Notes"));
            if (notes.Length > 0) Log("[INFO] " + notes);
        }

        private void AddEntry()
        {
            var win = FindForm();
            var fields = new List<PromptField>
            {
                new PromptField("名称", "", false, "例如：VS Code（Electron）"),
                new PromptField("匹配的 exe 名（正则）", "", false, @"例如：^Code\.exe$"),
                new PromptField("结论", "可用", false, "可选：可用 / 可用（建议参数）/ 不支持 / 未知"),
                new PromptField("推荐启动参数", "", false, "例如：--disable-gpu --no-sandbox"),
                new PromptField("备注", "", true, "补充说明：要补的运行时、已知问题…")
            };
            string[] v = Dialogs.Prompt(win, "添加程序档案",
                "写进你自己的用户档案，优先级高于内置条目；Id 会自动生成。", fields, "写入");
            if (v == null) return;
            if (v[0].Trim().Length == 0 || v[1].Trim().Length == 0)
            {
                Log("[WARN] 名称和匹配规则都不能为空");
                return;
            }

            var args = new Dictionary<string, object>();
            args["Name"] = v[0].Trim();
            args["ExeName"] = v[1].Trim();
            args["Verdict"] = v[2].Trim();
            args["LaunchArgs"] = v[3].Trim();
            args["Notes"] = v[4].Trim();

            Log("[STEP] 写入用户档案：" + v[0].Trim());
            Bridge.Run(@"gui\Run-GuiReadyCatalog.ps1", "add", args,
                d => SafeInvoke(() =>
                {
                    Log("[OK] 已写入档案");
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] 写入档案失败: " + err)), 60000);
        }

        private void RemoveEntry()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _items.Count)
            {
                Log("[WARN] 先选中一条档案");
                return;
            }
            var it = _items[idx];
            if (!Bridge.Bool(it, "IsUserEntry"))
            {
                Log("[WARN] 内置条目不能删除；要改就在下面「添加档案」里同名覆盖成自建条目");
                return;
            }
            string name = Bridge.Str(it, "Name");
            string id = Bridge.Str(it, "Id");
            if (!Dialogs.Confirm(FindForm(), "删除档案", "确定从用户档案里删除「" + name + "」？", "删除")) return;

            var args = new Dictionary<string, object>();
            args["Id"] = id;
            Bridge.Run(@"gui\Run-GuiReadyCatalog.ps1", "remove", args,
                d => SafeInvoke(() =>
                {
                    Log("[OK] 已删除 " + name);
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] 删除失败: " + err)), 60000);
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _table.Left = 0;
            _table.Top = 76;
            _table.Width = Math.Max(200, w - 4);

            _actions.Left = 0;
            _actions.Width = Math.Max(200, w - 4);
            int bh = LayoutButtonRow(_buttons, _actions.Width, 0);
            _actions.Height = bh;
            _table.Height = Math.Max(110, ClientSize.Height - 76 - bh - 22);
            _actions.Top = _table.Bottom + 6;
        }
    }

    // ------------------------------------------------------------ 结构审计
    internal sealed class AuditPage : PageBase
    {
        private static readonly string[] Levels = { "全部", "信息", "成功", "警告", "错误" };
        private static readonly string[] RangeTexts = { "全部时间", "近 24 小时", "近 7 天", "近 30 天" };
        private static readonly int[] RangeHours = { 0, 24, 168, 720 };

        private readonly Panel _bar;
        private readonly List<Pill> _pills = new List<Pill>();
        private readonly UiInput _kw;
        private readonly UiButton _range;
        private readonly UiButton _refresh;
        private readonly UiButton _export;
        private readonly DataTable _table;
        private readonly string[] _levelRow;
        private readonly List<string[]> _allRows = new List<string[]>();
        private readonly List<Dictionary<string, object>> _allRaw = new List<Dictionary<string, object>>();
        private readonly List<Dictionary<string, object>> _viewRaw = new List<Dictionary<string, object>>();
        private readonly List<DateTime?> _rowTime = new List<DateTime?>();
        private string _level = "全部";
        private int _rangeIdx;
        private bool _busy;

        public AuditPage()
        {
            Key = "audit";
            TitleText = "结构审计";
            Subtitle = "提交、执行、配置备份与恢复全在这里留痕；审计只追加、不修改，可按级别/时间/关键词筛选后导出。";
            Glyph = "audit";
            Accent = Theme.AccentOf("audit");

            _bar = new Panel { Height = 32, BackColor = Color.Transparent };
            Controls.Add(_bar);

            _levelRow = Levels;
            foreach (var lv in Levels)
            {
                var p = new Pill(lv, lv == "全部" ? "Info" : "Neutral");
                string captured = lv;
                p.Cursor = Cursors.Hand;
                p.Click += (s, e) => SetLevel(captured);
                _pills.Add(p);
                _bar.Controls.Add(p);
            }

            _refresh = new UiButton("刷新", ButtonKind.Normal, 84, 32) { Location = new Point(0, 0) };
            _refresh.Click += (s, e) => Reload();
            _bar.Controls.Add(_refresh);

            _export = new UiButton("导出", ButtonKind.Normal, 84, 32) { Location = new Point(0, 0) };
            _export.Click += (s, e) => ExportAudit();
            _bar.Controls.Add(_export);

            // 关键词：在已取到的记录里即时过滤，不用等子进程
            _kw = new UiInput(190) { Location = new Point(0, 0) };
            _kw.Box.TextChanged += (s, e) => ApplyFilter();
            _bar.Controls.Add(_kw);

            // 时间窗：换窗口要重新取数（Limit 是本窗口里的前 300 条），所以点一下直接 Reload
            _range = new UiButton(RangeTexts[0], ButtonKind.Normal, 104, 32) { Location = new Point(0, 0) };
            _range.Click += (s, e) =>
            {
                _rangeIdx = (_rangeIdx + 1) % RangeTexts.Length;
                _range.Text = RangeTexts[_rangeIdx];
                _range.Invalidate();
                Reload();
            };
            _bar.Controls.Add(_range);

            _table = new DataTable { Location = new Point(0, 116) };
            _table.Columns.Add(new DataColumn("时间", 140));
            _table.Columns.Add(new DataColumn("级别", 60));
            _table.Columns.Add(new DataColumn("事件", 110));
            _table.Columns.Add(new DataColumn("动作", 130));
            _table.Columns.Add(new DataColumn("任务", 170));
            _table.Columns.Add(new DataColumn("详情", 320));
            _table.RowActivated += ShowDetail;
            _table.ActivateOnDoubleClick = true;
            Controls.Add(_table);
        }

        // 双击看完整详情（表格里详情列会截断，导出前想确认内容时用这个）
        private void ShowDetail(int idx)
        {
            if (idx < 0 || idx >= _viewRaw.Count) return;
            var e = _viewRaw[idx];
            if (e == null) return;
            string body = "时间：" + TaskTime(Bridge.Str(e, "Time")) + "\r\n" +
                          "级别：" + LevelText(Bridge.Str(e, "Level")) + "\r\n" +
                          "事件：" + EventText(Bridge.Str(e, "Event")) + "（" + Bridge.Str(e, "Event") + "）\r\n" +
                          "动作：" + Bridge.Str(e, "ActionId") + "\r\n" +
                          "任务：" + Bridge.Str(e, "TaskId") + "\r\n" +
                          "用户：" + Bridge.Str(e, "User") + "\r\n" +
                          "机器：" + Bridge.Str(e, "Machine") + "\r\n" +
                          new string('-', 60) + "\r\n" + Bridge.Str(e, "Detail");
            Dialogs.Text(FindForm(), "审计详情", Bridge.Str(e, "TaskId"), body);
        }

        protected override void OnActivated()
        {
            Reload();
        }

        // 走既有 runner：Run-GuiReadyTasks.ps1 -Mode audit -> {Data:{Items,Count}}
        public void Reload()
        {
            if (_busy) return;
            _busy = true;

            var args = new Dictionary<string, object>();
            args["Limit"] = 300;
            if (RangeHours[_rangeIdx] > 0) args["SinceHours"] = RangeHours[_rangeIdx];

            Bridge.Run(@"gui\Run-GuiReadyTasks.ps1", "audit", args,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    var items = Bridge.List(data != null && data.ContainsKey("Items") ? data["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _allRows.Clear();
                        _allRaw.Clear();
                        _rowTime.Clear();
                        foreach (var e in items)
                        {
                            string detail = Bridge.Str(e, "Detail").Replace("\r", " ").Replace("\n", " ");
                            string iso = Bridge.Str(e, "Time");
                            _rowTime.Add(ParseTime(iso));
                            _allRaw.Add(e);
                            _allRows.Add(new[]
                            {
                                TaskTime(iso),
                                LevelText(Bridge.Str(e, "Level")),
                                EventText(Bridge.Str(e, "Event")),
                                Bridge.Str(e, "ActionId"),
                                Bridge.Str(e, "TaskId"),
                                detail
                            });
                        }
                        ApplyFilter();
                        Log("[INFO] 审计记录：" + _allRows.Count + " 条（" + RangeTexts[_rangeIdx] + "）");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    Log("[WARN] 审计记录读取失败: " + err);
                }), 120000);
        }

        private void SetLevel(string level)
        {
            _level = level;
            for (int i = 0; i < _pills.Count; i++)
            {
                _pills[i].Kind = (_levelRow[i] == level) ? "Info" : "Neutral";
                _pills[i].Invalidate();
            }
            ApplyFilter();
        }

        // 导出当前级别的审计记录（走 tasks runner 的 audit-export，会顺带写一条审计）
        private void ExportAudit()
        {
            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            string def = System.IO.Path.Combine(Bridge.StatePath, "audit-" + stamp + ".csv");
            var v = Dialogs.Prompt(FindForm(), "导出审计记录",
                "导出「" + _level + " · " + RangeTexts[_rangeIdx] +
                (_kw.ValueText.Trim().Length > 0 ? " · 关键词 " + _kw.ValueText.Trim() : "") +
                "」的记录（最多 5000 条）。\n格式填 Csv 或 Jsonl。",
                new List<PromptField>
                {
                    new PromptField("导出文件（绝对路径）", def),
                    new PromptField("格式（Csv / Jsonl）", "Csv")
                }, "导出");
            if (v == null || v[0].Trim().Length == 0) return;

            string fmt = v.Length > 1 && v[1].Trim().Length > 0 ? v[1].Trim() : "Csv";
            if (fmt.IndexOf("json", StringComparison.OrdinalIgnoreCase) >= 0) fmt = "Jsonl";
            else fmt = "Csv";

            var args = new Dictionary<string, object>();
            args["Path"] = v[0].Trim();
            args["Format"] = fmt;
            args["Limit"] = 5000;
            if (_level == "信息") args["Level"] = "Info";
            else if (_level == "成功") args["Level"] = "Success";
            else if (_level == "警告") args["Level"] = "Warn";
            else if (_level == "错误") args["Level"] = "Error";
            // 导出的内容要和屏幕上看到的一致：时间窗 + 关键词一起带上
            if (RangeHours[_rangeIdx] > 0) args["SinceHours"] = RangeHours[_rangeIdx];
            string kw = _kw.ValueText.Trim();
            if (kw.Length > 0) args["Keyword"] = kw;

            Bridge.Run(@"gui\Run-GuiReadyTasks.ps1", "audit-export", args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    Log("[OK] 审计已导出：" + Bridge.Str(data, "Path") +
                        "（" + (int)Bridge.Num(data, "Count") + " 条）");
                }),
                err => SafeInvoke(() => Log("[WARN] 审计导出失败: " + err)), 120000);
        }

        private void ApplyFilter()
        {
            string kw = _kw == null ? "" : _kw.ValueText.Trim();
            DateTime? since = null;
            int hours = RangeHours[_rangeIdx];
            if (hours > 0) since = DateTime.Now.AddHours(-hours);

            var list = new List<string[]>();
            _viewRaw.Clear();
            for (int i = 0; i < _allRows.Count; i++)
            {
                var r = _allRows[i];
                if (_level != "全部" && r[1] != _level) continue;
                if (since.HasValue)
                {
                    // 时间解析不出来的（极少）保留，别让一条脏数据把整行藏掉
                    if (i < _rowTime.Count && _rowTime[i].HasValue && _rowTime[i].Value < since.Value) continue;
                }
                if (kw.Length > 0 && !RowMatches(r, kw)) continue;
                list.Add(r);
                _viewRaw.Add(i < _allRaw.Count ? _allRaw[i] : null);
            }
            _table.SetRows(list);
        }

        private static bool RowMatches(string[] row, string kw)
        {
            foreach (var cell in row)
                if (cell != null && cell.IndexOf(kw, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            return false;
        }

        private static DateTime? ParseTime(string iso)
        {
            if (string.IsNullOrEmpty(iso)) return null;
            DateTime t;
            if (!DateTime.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.RoundtripKind, out t)) return null;
            return t;
        }

        private static string TaskTime(string iso)
        {
            var t = ParseTime(iso);
            return t.HasValue ? t.Value.ToString("MM-dd HH:mm:ss") : "-";
        }

        private static string LevelText(string s)
        {
            switch (s)
            {
                case "Info": return "信息";
                case "Warn": return "警告";
                case "Error": return "错误";
                case "Success": return "成功";
                default: return string.IsNullOrEmpty(s) ? "信息" : s;
            }
        }

        private static string EventText(string s)
        {
            switch (s)
            {
                case "task-queued": return "提交任务";
                case "task-start": return "开始执行";
                case "task-finish": return "执行结束";
                case "config-export": return "配置备份";
                case "config-import": return "配置恢复";
                case "audit-export": return "审计导出";
                default: return string.IsNullOrEmpty(s) ? "事件" : s;
            }
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _bar.Left = 0;
            _bar.Top = 76;
            _bar.Width = Math.Max(200, w - 4);

            int x = 0;
            foreach (var p in _pills)
            {
                p.Top = 4;
                p.Left = x;
                x += p.Width + 8;
            }
            _kw.Top = 0;
            _kw.Left = x;
            x += _kw.Width + 8;
            _range.Top = 0;
            _range.Left = x;
            x += _range.Width + 8;
            _refresh.Left = Math.Max(x, _bar.Width - _refresh.Width - 4);
            _refresh.Top = 0;
            _export.Left = Math.Max(x, _refresh.Left - _export.Width - 8);
            _export.Top = 0;

            _table.Left = 0;
            _table.Top = 116;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(120, ClientSize.Height - 124);
        }
    }

    // ------------------------------------------------------------ 远程主机
    internal sealed class HostsPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _bar;
        private readonly UiInput _kw;
        private readonly UiButton _tagBtn;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _sum;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private readonly List<Dictionary<string, object>> _view = new List<Dictionary<string, object>>();
        private readonly List<string> _tags = new List<string>();
        private readonly List<string> _trusted = new List<string>();
        private int _tagIdx;
        private bool _busy;

        public HostsPage()
        {
            Key = "hosts";
            TitleText = "远程主机";
            Subtitle = "维护 WinRM 主机清单、测试连通性、批量执行命令；凭据用 DPAPI 加密，双击看完整信息。";
            Glyph = "hosts";
            Accent = Theme.AccentOf("hosts");

            _sum = new Pill("读取中", "Neutral");
            Head.Slot.Controls.Add(_sum);
            Head.Slot.Width = _sum.Width;

            _bar = new Panel { Height = 32, BackColor = Color.Transparent };
            Controls.Add(_bar);

            _kw = new UiInput(200) { Location = new Point(0, 0) };
            _kw.Box.TextChanged += (s, e) => ApplyFilter();
            _bar.Controls.Add(_kw);

            _tagBtn = new UiButton("标签：全部", ButtonKind.Normal, 130, 32) { Location = new Point(0, 0) };
            _tagBtn.Click += (s, e) =>
            {
                if (_tags.Count == 0) return;
                _tagIdx = (_tagIdx + 1) % _tags.Count;
                _tagBtn.Text = _tagIdx == 0 ? "标签：全部" : "标签：" + _tags[_tagIdx];
                _tagBtn.Invalidate();
                ApplyFilter();
            };
            _bar.Controls.Add(_tagBtn);

            _table = new DataTable { Location = new Point(0, 118) };
            _table.Columns.Add(new DataColumn("名称", 100));
            _table.Columns.Add(new DataColumn("地址", 130));
            _table.Columns.Add(new DataColumn("端口", 50, true));
            _table.Columns.Add(new DataColumn("协议", 70));
            _table.Columns.Add(new DataColumn("认证", 90));
            _table.Columns.Add(new DataColumn("凭据", 60));
            _table.Columns.Add(new DataColumn("标签", 100));
            _table.Columns.Add(new DataColumn("最近测试", 120));
            _table.Columns.Add(new DataColumn("状态", 70));
            _table.Columns.Add(new DataColumn("备注", 150));
            _table.RowActivated += ShowHostDetail;
            _table.ActivateOnDoubleClick = true;
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton("添加主机", ButtonKind.Primary, 104, AddHost);
            AddButton("刷新", ButtonKind.Normal, 80, Reload);
            AddButton("编辑", ButtonKind.Normal, 80, EditHost);
            AddButton("删除", ButtonKind.Danger, 80, RemoveHost);
            AddButton("测试连接", ButtonKind.Normal, 104, TestSelected);
            AddButton("批量命令", ButtonKind.Normal, 104, BatchCommand);
            AddButton("保存凭据", ButtonKind.Normal, 104, SaveCredential);
            AddButton("启用/禁用", ButtonKind.Normal, 104, ToggleEnabled);
            AddButton("信任设置", ButtonKind.Normal, 104, TrustSettings);
        }

        private void AddButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 0) };
            b.Click += (s, e) => onClick();
            _buttons.Add(b);
            _actions.Controls.Add(b);
        }

        // 走既有 runner：Run-GuiReadyRemote.ps1 -Mode test（会顺带回写主机的最近测试结果）
        private void TestSelected()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _table.Rows.Count)
            {
                Log("[WARN] 先在列表里选中一台主机");
                return;
            }
            string address = _table.Rows[idx][1];
            Log("[STEP] 测试连接 " + address + "（最多 30 秒）");

            var args = new Dictionary<string, object>();
            args["Hosts"] = address;
            args["TimeoutSec"] = 30;
            Bridge.Run(@"gui\Run-GuiReadyRemote.ps1", "test", args,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    var results = Bridge.List(data != null && data.ContainsKey("Results") ? data["Results"] : null);
                    SafeInvoke(() =>
                    {
                        foreach (var r in results)
                        {
                            bool ok = Bridge.Str(r, "Status") == "OK";
                            Log((ok ? "[OK] " : "[ERROR] ") + Bridge.Str(r, "Name") +
                                "（" + Bridge.Str(r, "Address") + "）" +
                                Bridge.Str(r, "Detail") + " · " +
                                Bridge.Num(r, "DurationSec").ToString("0.0") + " 秒");
                        }
                        Reload();
                    });
                },
                err => SafeInvoke(() => Log("[WARN] 连接测试失败: " + err)), 180000);
        }

        private Dictionary<string, object> SelectedHost()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _view.Count) return null;
            return _view[idx];
        }

        private void AddHost()
        {
            var fields = new List<PromptField>
            {
                new PromptField("名称", "", false, "清单里显示的名字，不能重复"),
                new PromptField("地址", "", false, "IP 或主机名"),
                new PromptField("端口", "5985", false, "HTTP 5985 / HTTPS 5986，留空按协议默认"),
                new PromptField("备注", "", false, "可选")
            };
            string[] v = Dialogs.Prompt(FindForm(), "添加主机",
                "凭据不在这里填：先在「全部功能 → 远程批量执行」里跑一次，或在 PowerShell 版里保存。",
                fields, "添加");
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args["Name"] = v[0].Trim();
            args["Address"] = v[1].Trim();
            int port;
            args["Port"] = int.TryParse(v[2].Trim(), out port) ? port : 0;
            args["Notes"] = v[3].Trim();

            Bridge.Run(@"gui\Run-GuiReadyRemote.ps1", "host-add", args,
                d => SafeInvoke(() =>
                {
                    Log("[OK] 已添加主机 " + v[0].Trim());
                    Reload();
                }),
                err => SafeInvoke(() => Log("[WARN] 添加主机失败: " + err)), 60000);
        }

        private void EditHost()
        {
            var h = SelectedHost();
            if (h == null) { Log("[WARN] 先选中一台主机"); return; }

            var fields = new List<PromptField>
            {
                new PromptField("名称", Bridge.Str(h, "Name")),
                new PromptField("地址", Bridge.Str(h, "Address")),
                new PromptField("端口", ((int)Bridge.Num(h, "Port")).ToString()),
                new PromptField("备注", Bridge.Str(h, "Notes"))
            };
            string[] v = Dialogs.Prompt(FindForm(), "编辑主机", "改完点保存，会写回主机清单。", fields, "保存");
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(h, "Id");
            args["Name"] = v[0].Trim();
            args["Address"] = v[1].Trim();
            int port;
            args["Port"] = int.TryParse(v[2].Trim(), out port) ? port : 0;
            args["Notes"] = v[3].Trim();

            Bridge.Run(@"gui\Run-GuiReadyRemote.ps1", "host-update", args,
                d => SafeInvoke(() =>
                {
                    Log("[OK] 已保存主机 " + v[0].Trim());
                    Reload();
                }),
                err => SafeInvoke(() => Log("[WARN] 保存主机失败: " + err)), 60000);
        }

        private void RemoveHost()
        {
            var h = SelectedHost();
            if (h == null) { Log("[WARN] 先选中一台主机"); return; }
            string name = Bridge.Str(h, "Name");
            if (!Dialogs.Confirm(FindForm(), "删除主机",
                "确定从清单里删除「" + name + "」？保存的凭据也会一起删掉。", "删除")) return;

            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(h, "Id");
            Bridge.Run(@"gui\Run-GuiReadyRemote.ps1", "host-remove", args,
                d => SafeInvoke(() =>
                {
                    Log("[OK] 已删除主机 " + name);
                    Reload();
                }),
                err => SafeInvoke(() => Log("[WARN] 删除主机失败: " + err)), 60000);
        }

        // 保存 DPAPI 凭据（密码只在进程内传递，runner 读完 args.json 会立刻删掉）
        private void SaveCredential()
        {
            var h = SelectedHost();
            if (h == null) { Log("[WARN] 先选中一台主机"); return; }

            var user = new PromptField("用户名", "", false, @"格式：域\用户 或 主机名\用户");
            var pass = new PromptField("密码", "");
            pass.Secret = true;
            var v = Dialogs.Prompt(FindForm(), "保存凭据",
                "凭据用 DPAPI 加密保存在本机，只有本机本用户能解出明文。",
                new List<PromptField> { user, pass }, "保存");
            if (v == null) return;
            if (v[0].Trim().Length == 0 || v[1].Length == 0)
            {
                Log("[WARN] 用户名和密码都不能为空");
                return;
            }

            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(h, "Id");
            args["UserName"] = v[0].Trim();
            args["Password"] = v[1];

            Bridge.Run(@"gui\Run-GuiReadyRemote.ps1", "host-cred", args,
                d => SafeInvoke(() =>
                {
                    Log("[OK] 已保存凭据：" + Bridge.Str(h, "Name"));
                    Reload();
                }),
                err => SafeInvoke(() => Log("[WARN] 保存凭据失败: " + err)), 60000);
        }

        // 启用/禁用：影响批量命令默认目标（留空时只跑启用的主机）
        private void ToggleEnabled()
        {
            var h = SelectedHost();
            if (h == null) { Log("[WARN] 先选中一台主机"); return; }
            bool on = Bridge.Bool(h, "Enabled", true);

            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(h, "Id");
            args["Enabled"] = !on;
            Bridge.Run(@"gui\Run-GuiReadyRemote.ps1", "host-update", args,
                d => SafeInvoke(() =>
                {
                    Log("[OK] " + Bridge.Str(h, "Name") + " 已" + (on ? "禁用" : "启用"));
                    Reload();
                }),
                err => SafeInvoke(() => Log("[WARN] 切换启用状态失败: " + err)), 60000);
        }

        // TrustedHosts：WinRM 默认只信任域内主机，工作组环境要显式加地址
        private void TrustSettings()
        {
            var fields = new List<PromptField>
            {
                new PromptField("添加地址", "", false, "可填 IP / 主机名 / 网段，多个用逗号分隔"),
                new PromptField("移除地址", "", false, "填要移除的条目；两项都留空则只看不改")
            };
            string current = _trusted.Count > 0
                ? string.Join("、", _trusted.ToArray())
                : "（空）";
            string[] v = Dialogs.Prompt(FindForm(), "WinRM 信任设置",
                "当前 TrustedHosts：" + current + "\n\n注意：改成 * 表示信任所有主机（风险自担）。",
                fields, "应用");
            if (v == null) return;

            string add = v[0].Trim();
            string remove = v[1].Trim();
            if (add.Length == 0 && remove.Length == 0) return;

            if (add.Length > 0)
                Bridge.Run(@"gui\Run-GuiReadyRemote.ps1", "host-trust-add",
                    new Dictionary<string, object> { { "Address", add } },
                    d => SafeInvoke(() =>
                    {
                        Log("[OK] 已加入 TrustedHosts：" + add);
                        if (remove.Length > 0) TrustRemove(remove); else Reload();
                    }),
                    err => SafeInvoke(() => Log("[WARN] 加入信任失败: " + err)), 60000);
            else
                TrustRemove(remove);
        }

        private void TrustRemove(string address)
        {
            Bridge.Run(@"gui\Run-GuiReadyRemote.ps1", "host-trust-remove",
                new Dictionary<string, object> { { "Address", address } },
                d => SafeInvoke(() =>
                {
                    Log("[OK] 已从 TrustedHosts 移除：" + address);
                    Reload();
                }),
                err => SafeInvoke(() => Log("[WARN] 移除信任失败: " + err)), 60000);
        }

        private void BatchCommand()
        {
            var h = SelectedHost();
            string spec = h == null ? "" : Bridge.Str(h, "Address");
            var fields = new List<PromptField>
            {
                new PromptField("目标主机", spec, false, "留空 = 全部启用的主机；也可填名称/地址，逗号分隔"),
                new PromptField("要执行的 PowerShell 命令", "", true, "多行命令会被当成一段脚本送到每台主机")
            };
            string[] v = Dialogs.Prompt(FindForm(), "批量执行命令", "结果会逐台写进运行日志。", fields, "执行");
            if (v == null) return;
            if (v[1].Trim().Length == 0) { Log("[WARN] 命令不能为空"); return; }

            var args = new Dictionary<string, object>();
            args["Hosts"] = v[0].Trim();
            args["Command"] = v[1];
            args["TimeoutSec"] = 120;
            args["ContinueOnError"] = true;
            args["DryRun"] = false;

            bool started = Actions.RunAction("remote-run", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "批量命令结束，退出码 " + r.ExitCode +
                        "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    Reload();
                }),
                err => SafeInvoke(() => Log("[WARN] 批量命令未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 远程批量执行命令（remote-run）");
        }

        protected override void OnActivated()
        {
            Reload();
        }

        // 页头胶囊：文字一变宽窄就变，Slot 要跟着重算，否则胶囊会溢出页头
        private void SetSum(string text, string kind)
        {
            _sum.SetText(text);
            _sum.SetKind(kind);
            Head.Slot.Width = _sum.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        // 走既有 runner：Run-GuiReadyRemote.ps1 -Mode hosts
        public void Reload()
        {
            if (_busy) return;
            _busy = true;
            SetSum("读取中", "Neutral");

            Bridge.Run(@"gui\Run-GuiReadyRemote.ps1", "hosts", null,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    var items = Bridge.List(data != null && data.ContainsKey("Items") ? data["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);
                        _trusted.Clear();
                        _trusted.AddRange(Bridge.StrList(data, "TrustedHosts"));

                        // 标签候选（按出现顺序去重；第 0 项留给「全部」）
                        _tags.Clear();
                        _tags.Add("全部");
                        foreach (var h in items)
                            foreach (var t in Bridge.StrList(h, "Tags"))
                                if (!_tags.Exists(x => string.Equals(x, t, StringComparison.OrdinalIgnoreCase)))
                                    _tags.Add(t);
                        if (_tagIdx >= _tags.Count) _tagIdx = 0;
                        _tagBtn.Text = _tagIdx == 0 ? "标签：全部" : "标签：" + _tags[_tagIdx];
                        _tagBtn.Invalidate();

                        int enabled = 0, failed = 0;
                        foreach (var h in items)
                        {
                            if (Bridge.Bool(h, "Enabled", true)) enabled++;
                            if (Bridge.Str(h, "LastTestStatus") == "Failed") failed++;
                        }
                        ApplyFilter();

                        if (items.Count == 0) SetSum("0 台", "Neutral");
                        else if (failed > 0) SetSum(items.Count + " 台 · 启用 " + enabled + " · 失败 " + failed, "Warn");
                        else SetSum(items.Count + " 台 · 启用 " + enabled, enabled > 0 ? "Success" : "Neutral");

                        Log("[INFO] 主机清单：" + items.Count + " 台");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    _view.Clear();
                    _table.SetRows(new string[0][]);
                    _sum.SetText("读取失败");
                    _sum.SetKind("Danger");
                    Head.Slot.Width = _sum.Width;
                    Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
                    Log("[WARN] 主机清单读取失败: " + err);
                }), 120000);
        }

        // 双击看完整主机信息（表格十列挤在一起，端口/凭据/测试结果都得能看清）
        private void ShowHostDetail(int idx)
        {
            if (idx < 0 || idx >= _view.Count) return;
            var h = _view[idx];
            var tags = Bridge.StrList(h, "Tags");
            string test = Bridge.Str(h, "LastTestStatus");
            string body = "名称：  " + Bridge.Str(h, "Name") + "\r\n" +
                          "地址：  " + Bridge.Str(h, "Address") + ":" + ((int)Bridge.Num(h, "Port")) + "\r\n" +
                          "协议：  " + Bridge.Str(h, "Protocol").ToUpperInvariant() + "\r\n" +
                          "认证：  " + (Bridge.Str(h, "Auth") == "Credential" ? "保存的凭据" : "当前用户") + "\r\n" +
                          "凭据：  " + (Bridge.Bool(h, "HasCredential") ? "已保存（DPAPI 加密）" : "未保存") + "\r\n" +
                          "启用：  " + (Bridge.Bool(h, "Enabled", true) ? "是" : "否") + "\r\n" +
                          "免证书：" + (Bridge.Bool(h, "AllowUntrusted") ? "是（不校验证书）" : "否") + "\r\n" +
                          "标签：  " + (tags.Count > 0 ? string.Join("、", tags.ToArray()) : "（无）") + "\r\n" +
                          "最近测试：" + TaskTime(Bridge.Str(h, "LastTestAt")) + " · " +
                          (test == "OK" ? "正常" : (test == "Failed" ? "失败" : "未测试")) + "\r\n" +
                          new string('-', 60) + "\r\n" +
                          "备注\r\n" + Bridge.Str(h, "Notes", "（无）");
            Dialogs.Text(FindForm(), "主机详情", Bridge.Str(h, "Name"), body);
        }

        // 关键词（名称/地址/备注/标签）+ 标签筛选，都在本地做，改一个字符就见效
        private void ApplyFilter()
        {
            string kw = _kw == null ? "" : _kw.ValueText.Trim();
            string tag = (_tagIdx > 0 && _tagIdx < _tags.Count) ? _tags[_tagIdx] : "";

            _view.Clear();
            var rows = new List<string[]>();
            foreach (var h in _items)
            {
                var tagNames = Bridge.StrList(h, "Tags");
                string name = Bridge.Str(h, "Name");
                string address = Bridge.Str(h, "Address");
                string notes = Bridge.Str(h, "Notes");

                if (tag.Length > 0)
                {
                    bool hit = false;
                    foreach (var t in tagNames)
                        if (string.Equals(t, tag, StringComparison.OrdinalIgnoreCase)) { hit = true; break; }
                    if (!hit) continue;
                }
                if (kw.Length > 0)
                {
                    string blob = name + " " + address + " " + notes + " " + string.Join(" ", tagNames.ToArray());
                    if (blob.IndexOf(kw, StringComparison.OrdinalIgnoreCase) < 0) continue;
                }

                _view.Add(h);
                string test = Bridge.Str(h, "LastTestStatus");
                rows.Add(new[]
                {
                    name,
                    address,
                    ((int)Bridge.Num(h, "Port")).ToString(),
                    Bridge.Str(h, "Protocol").ToUpperInvariant(),
                    Bridge.Str(h, "Auth") == "Credential" ? "保存凭据" : "当前用户",
                    Bridge.Bool(h, "HasCredential") ? "有" : "无",
                    tagNames.Count > 0 ? string.Join("、", tagNames.ToArray()) : "",
                    TaskTime(Bridge.Str(h, "LastTestAt")),
                    test == "OK" ? "正常" : (test == "Failed" ? "失败" : "未测试"),
                    notes.Replace("\r", " ").Replace("\n", " ")
                });
            }
            _table.SetRows(rows);
        }

        private static string TaskTime(string iso)
        {
            if (string.IsNullOrEmpty(iso)) return "未测试";
            DateTime t;
            if (!DateTime.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.RoundtripKind, out t)) return "未测试";
            return t.ToString("MM-dd HH:mm");
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _bar.Left = 0;
            _bar.Top = 76;
            _bar.Width = Math.Max(200, w - 4);
            _kw.Top = 0;
            _kw.Left = 0;
            _tagBtn.Top = 0;
            _tagBtn.Left = _kw.Width + 8;

            _table.Left = 0;
            _table.Top = 118;
            _table.Width = Math.Max(200, w - 4);

            _actions.Left = 0;
            _actions.Width = Math.Max(200, w - 4);
            int bh = LayoutButtonRow(_buttons, _actions.Width, 0);
            _actions.Height = bh;
            _table.Height = Math.Max(100, ClientSize.Height - 118 - bh - 22);
            _actions.Top = _table.Bottom + 6;
        }
    }

    // ------------------------------------------------------------ 角色与功能
    internal sealed class RolePage : PageBase
    {
        private readonly Panel _bar;
        private readonly UiInput _filter;
        private readonly UiButton _scan;
        private readonly UiButton _dep;
        private readonly UiButton _install;
        private readonly UiButton _remove;
        private readonly UiButton _mode;
        private readonly UiButton _reboot;
        private readonly DataTable _table;
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _all = new List<Dictionary<string, object>>();
        private int _modeIdx;          // 0=全部 1=仅已装 2=仅未装
        private bool _busy;

        public RolePage()
        {
            Key = "role";
            TitleText = "角色与功能";
            Subtitle = "图形化装 Windows Server 角色与功能（等价于 Install-WindowsFeature）。安装需要管理员；装完是否需要重启会写进日志。";
            Glyph = "role";
            Accent = Theme.AccentOf("role");

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _bar = new Panel { Height = 36, BackColor = Color.Transparent };
            Controls.Add(_bar);

            _filter = new UiInput(320) { Location = new Point(0, 2) };
            _filter.Box.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; ApplyFilter(); }
            };
            _scan = new UiButton("筛选", ButtonKind.Primary, 84, 32) { Location = new Point(0, 2) };
            _dep = new UiButton("分析依赖", ButtonKind.Normal, 104, 32) { Location = new Point(0, 2) };
            _scan.Click += (s, e) => ApplyFilter();
            _dep.Click += (s, e) => ShowDependencies();
            _install = new UiButton("安装选中", ButtonKind.Normal, 104, 32) { Location = new Point(0, 2) };
            _install.Click += (s, e) => InstallSelected();
            _remove = new UiButton("卸载选中", ButtonKind.Danger, 104, 32) { Location = new Point(0, 2) };
            _remove.Click += (s, e) => RemoveSelected();

            // 勾选多个后「安装选中」自动走批量队列；只看某一类时用这个模式按钮
            _mode = new UiButton("全部", ButtonKind.Normal, 92, 32) { Location = new Point(0, 2) };
            _mode.Click += (s, e) =>
            {
                _modeIdx = (_modeIdx + 1) % 3;
                _mode.Text = _modeIdx == 0 ? "全部" : (_modeIdx == 1 ? "仅已装" : "仅未装");
                _mode.Invalidate();
                ApplyFilter();
            };

            _reboot = new UiButton("重启服务器", ButtonKind.Normal, 108, 32) { Location = new Point(0, 2) };
            _reboot.Click += (s, e) => RebootServer();
            _bar.Controls.Add(_filter);
            _bar.Controls.Add(_scan);
            _bar.Controls.Add(_dep);
            _bar.Controls.Add(_install);
            _bar.Controls.Add(_remove);
            _bar.Controls.Add(_mode);
            _bar.Controls.Add(_reboot);

            _table = new DataTable { Location = new Point(0, 120) };
            _table.Columns.Add(new DataColumn("选", 40));
            _table.Columns.Add(new DataColumn("名称", 200));
            _table.Columns.Add(new DataColumn("显示名", 220));
            _table.Columns.Add(new DataColumn("状态", 90));
            _table.Columns.Add(new DataColumn("说明", 320));
            _table.CheckColumn = 0;
            _table.RowActivated += idx =>
            {
                var r = _table.Rows[idx];
                Log("[INFO] 选中角色 " + r[1]);
            };
            Controls.Add(_table);
        }

        protected override void OnActivated()
        {
            Load();
        }

        // Run-GuiReadyRole.ps1 -Mode list -> {Support,Summary,Items}
        public void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState("读取中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadyRole.ps1", "list", null,
                d =>
                {
                    var support = Bridge.Dict(d.ContainsKey("Support") ? d["Support"] : null);
                    var summary = Bridge.Dict(d.ContainsKey("Summary") ? d["Summary"] : null);
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _all.Clear();
                        _all.AddRange(items);

                        if (!Bridge.Bool(support, "ServerManager"))
                        {
                            SetState("不适用", "Warn");
                            _table.SetRows(new string[0][]);
                            string note = Bridge.Str(support, "Note", "当前系统没有 ServerManager，角色/功能不适用。");
                            Log("[WARN] " + note);
                            return;
                        }

                        int installed = (int)Bridge.Num(summary, "Installed");
                        int total = (int)Bridge.Num(summary, "Total", _all.Count);
                        SetState("已装 " + installed + " / " + total,
                                 Bridge.Bool(support, "CanManage") ? "Info" : "Warn");
                        if (!Bridge.Bool(support, "Administrator"))
                            Log("[WARN] 当前未以管理员运行，只能查看，安装会失败");
                        ApplyFilter();
                        Log("[INFO] 角色与功能：" + total + " 项，已装 " + installed + " 项");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 角色列表读取失败: " + err);
                }), 180000);
        }

        private void ApplyFilter()
        {
            string q = _filter.ValueText.Trim();
            var rows = new List<string[]>();
            foreach (var it in _all)
            {
                string name = Bridge.Str(it, "Name");
                string display = Bridge.Str(it, "DisplayName");
                if (q.Length > 0 &&
                    name.IndexOf(q, StringComparison.OrdinalIgnoreCase) < 0 &&
                    display.IndexOf(q, StringComparison.OrdinalIgnoreCase) < 0) continue;

                bool on = Bridge.Bool(it, "Installed");
                if (_modeIdx == 1 && !on) continue;
                if (_modeIdx == 2 && on) continue;
                string state = on ? "已安装" : Bridge.Str(it, "InstallState", "未安装");
                rows.Add(new[] { "", name, display, on ? "已安装" : StateText(state), Bridge.Str(it, "Note") });
            }
            _table.SetRows(rows);
        }

        private static string StateText(string state)
        {
            switch (state)
            {
                case "Installed": return "已安装";
                case "Available": return "可安装";
                case "Removed": return "已移除";
                default: return string.IsNullOrEmpty(state) ? "未安装" : state;
            }
        }

        private void ShowDependencies()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _table.Rows.Count)
            {
                Log("[WARN] 先选中一个角色");
                return;
            }
            string name = _table.Rows[idx][1];
            foreach (var it in _all)
            {
                if (Bridge.Str(it, "Name") != name) continue;
                var deps = Bridge.StrList(it, "DependsOn");
                Dialogs.Text(FindForm(), "依赖分析", name,
                    "角色/功能：" + name + "（" + Bridge.Str(it, "DisplayName") + "）\r\n" +
                    "当前状态：" + (_table.Rows[idx][3]) + "\r\n\r\n" +
                    "直接依赖：" + (deps.Count > 0 ? string.Join("、", deps.ToArray()) : "无") + "\r\n\r\n" +
                    "安装时工具会按 DependsOn 递归展开，先把未安装的依赖装上（依赖自动补齐），" +
                    "不需要你手工按顺序装。");
                return;
            }
        }

        // 选中的角色名（勾选优先：勾了多个就是批量）
        private string SelectedRole()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _table.Rows.Count) return "";
            return _table.Rows[idx][1];
        }

        private List<string> CheckedRoles()
        {
            var names = new List<string>();
            foreach (var i in _table.Checked)
            {
                if (i < 0 || i >= _table.Rows.Count) continue;
                string n = _table.Rows[i][1];
                if (n.Length > 0 && !names.Contains(n)) names.Add(n);
            }
            return names;
        }

        private void InstallSelected()
        {
            var batch = CheckedRoles();
            if (batch.Count > 1)
            {
                string list = string.Join(",", batch.ToArray());
                if (!Dialogs.Confirm(FindForm(), "批量安装角色/功能",
                    "按依赖顺序依次安装这 " + batch.Count + " 项（单个失败不中断后面的）：\n\n" +
                    list + "\n\n耗时可能较长，是否需要重启会写进日志。", "开始安装")) return;

                var bargs = new Dictionary<string, object>();
                bargs["Names"] = list;
                bargs["WithManagementTools"] = false;
                bargs["DryRun"] = false;
                bool bstarted = Actions.RunAction("role-batch-install", bargs,
                    line => SafeInvoke(() => Log(line)),
                    r => SafeInvoke(() =>
                    {
                        Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "批量安装结束，退出码 " + r.ExitCode +
                            "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                        Load();
                    }),
                    err => SafeInvoke(() => Log("[WARN] 批量安装未启动: " + err)));
                if (bstarted) Log("[STEP] 已提交动作 批量安装角色/功能（role-batch-install）：" + batch.Count + " 项");
                return;
            }

            string name = batch.Count == 1 ? batch[0] : SelectedRole();
            if (name.Length == 0) { Log("[WARN] 先选中（或勾选）一个角色/功能"); return; }
            if (!Dialogs.Confirm(FindForm(), "安装角色/功能",
                "安装「" + name + "」？会先按依赖顺序补齐，耗时可能较长；是否需要重启会写进日志。",
                "安装")) return;

            var args = new Dictionary<string, object>();
            args["Name"] = name;
            args["WithManagementTools"] = false;
            args["DryRun"] = false;
            bool started = Actions.RunAction("role-install", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "安装 " + name +
                        "结束，退出码 " + r.ExitCode + "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    Log("[INFO] 如日志提示需要重启，可用工具栏「重启服务器」");
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] 安装未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 安装角色/功能（role-install）：" + name);
        }

        private void RemoveSelected()
        {
            var batch = CheckedRoles();
            if (batch.Count > 1)
            {
                string list = string.Join(",", batch.ToArray());
                if (!Dialogs.Confirm(FindForm(), "批量移除角色/功能",
                    "依次移除这 " + batch.Count + " 项（被其它角色依赖的会失败，属于预期）：\n\n" +
                    list + "\n\n不会自动重启。", "开始移除")) return;

                var bargs = new Dictionary<string, object>();
                bargs["Names"] = list;
                bargs["DryRun"] = false;
                bool bstarted = Actions.RunAction("role-batch-remove", bargs,
                    line => SafeInvoke(() => Log(line)),
                    r => SafeInvoke(() =>
                    {
                        Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "批量移除结束，退出码 " + r.ExitCode +
                            "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                        Load();
                    }),
                    err => SafeInvoke(() => Log("[WARN] 批量移除未启动: " + err)));
                if (bstarted) Log("[STEP] 已提交动作 批量移除角色/功能（role-batch-remove）：" + batch.Count + " 项");
                return;
            }

            string name = batch.Count == 1 ? batch[0] : SelectedRole();
            if (name.Length == 0) { Log("[WARN] 先选中（或勾选）一个角色/功能"); return; }
            if (!Dialogs.Confirm(FindForm(), "移除角色/功能",
                "确定移除「" + name + "」？不会自动重启，是否重启由你决定。", "移除")) return;

            var args = new Dictionary<string, object>();
            args["Name"] = name;
            args["DryRun"] = false;
            bool started = Actions.RunAction("role-remove", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "移除 " + name +
                        "结束，退出码 " + r.ExitCode + "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] 移除未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 移除角色/功能（role-remove）：" + name);
        }

        // 角色装完常需要重启；延时 20 秒，期间可在命令行 shutdown /a 取消
        private void RebootServer()
        {
            var v = Dialogs.Prompt(FindForm(), "重启服务器",
                "所有会话会断开。默认 20 秒后重启，期间可在命令行执行 shutdown /a 取消。",
                new List<PromptField> { new PromptField("延时（秒）", "20", false, "最小 5") }, "重启");
            if (v == null) return;

            int delay;
            if (!int.TryParse(v[0].Trim(), out delay) || delay < 5) delay = 20;

            var args = new Dictionary<string, object>();
            args["DelaySec"] = delay;
            args["DryRun"] = false;
            bool started = Actions.RunAction("reboot", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() => Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") +
                                          "重启命令已下发，退出码 " + r.ExitCode)),
                err => SafeInvoke(() => Log("[WARN] 重启未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 重启服务器（reboot）：" + delay + " 秒后");
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _bar.Left = 0;
            _bar.Top = 76;
            _bar.Width = Math.Max(200, w - 4);

            int x = 0;
            int reserved = 8 + _scan.Width + 8 + _dep.Width + 8 + _install.Width + 8 +
                           _remove.Width + 8 + _mode.Width + 8 + _reboot.Width;
            _filter.Width = Math.Max(140, Math.Min(300, _bar.Width - reserved - 4));
            _filter.Top = 2;
            _filter.Left = x;
            x += _filter.Width + 8;
            _scan.Top = 2;
            _scan.Left = x;
            x += _scan.Width + 8;
            _dep.Top = 2;
            _dep.Left = x;
            x += _dep.Width + 8;
            _install.Top = 2;
            _install.Left = x;
            x += _install.Width + 8;
            _remove.Top = 2;
            _remove.Left = x;
            x += _remove.Width + 8;
            _mode.Top = 2;
            _mode.Left = x;
            x += _mode.Width + 8;
            _reboot.Top = 2;
            _reboot.Left = x;

            _table.Left = 0;
            _table.Top = 120;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(120, ClientSize.Height - 128);
        }
    }

    // ------------------------------------------------------------ 安全基线
    internal sealed class SecurityPage : PageBase
    {
        private readonly List<StatCard> _cards = new List<StatCard>();
        private readonly DataTable _table;
        private readonly Panel _bar;
        private readonly Pill _state;
        private readonly UiButton _fix;
        private readonly UiButton _fixSel;
        private readonly UiButton _modeBtn;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private readonly List<Dictionary<string, object>> _view = new List<Dictionary<string, object>>();
        private int _mode;   // 0=全部 1=只看问题 2=只看不合格
        private bool _busy;

        public SecurityPage()
        {
            Key = "security";
            TitleText = "安全基线";
            Subtitle = "本地可验证的 10 项安全基线；修复只覆盖安全可逆项，双击看证据与建议。";
            Glyph = "security";
            Accent = Theme.AccentOf("security");

            _state = new Pill("未审计", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            string[][] stats =
            {
                new[] { "通过", "—", "#67C23A", "符合基线" },
                new[] { "警告", "—", "#E6A23C", "需要人工确认" },
                new[] { "不合格", "—", "#F56C6C", "可安全修复" },
                new[] { "未知", "—", "#94A3B8", "无法本机验证" }
            };
            foreach (var s in stats)
            {
                var c = new StatCard(s[0], s[1], Theme.Hex(s[2]), s[3]);
                _cards.Add(c);
                Controls.Add(c);
            }

            _bar = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_bar);

            var audit = new UiButton("重新审计", ButtonKind.Normal, 100, 36) { Location = new Point(0, 2) };
            audit.Click += (s, e) => Audit();
            _fix = new UiButton("全部可修项", ButtonKind.Primary, 108, 36) { Location = new Point(108, 2) };
            _fix.Click += (s, e) => RunFix(0);
            _fixSel = new UiButton("修复选中", ButtonKind.Normal, 100, 36) { Location = new Point(224, 2) };
            _fixSel.Click += (s, e) => RunFix(SelectedFixIndex());
            _modeBtn = new UiButton("全部", ButtonKind.Normal, 92, 36) { Location = new Point(332, 2) };
            _modeBtn.Click += (s, e) =>
            {
                _mode = (_mode + 1) % 3;
                _modeBtn.Text = _mode == 0 ? "全部" : (_mode == 1 ? "只看问题" : "只看不合格");
                _modeBtn.Invalidate();
                Fill();
            };
            _bar.Controls.Add(audit);
            _bar.Controls.Add(_fix);
            _bar.Controls.Add(_fixSel);
            _bar.Controls.Add(_modeBtn);

            _table = new DataTable { Location = new Point(0, 192) };
            _table.Columns.Add(new DataColumn("检查项", 240));
            _table.Columns.Add(new DataColumn("结果", 80));
            _table.Columns.Add(new DataColumn("证据 / 建议", 480));
            _table.RowActivated += ShowItem;
            _table.ActivateOnDoubleClick = true;
            Controls.Add(_table);
        }

        // 双击看完整证据 + 建议（表格里两者挤一列，长证据会被截断）
        private void ShowItem(int idx)
        {
            if (idx < 0 || idx >= _view.Count) return;
            var it = _view[idx];
            string fix = Bridge.Str(it, "Fix");
            string body = "检查项：" + Bridge.Str(it, "Title") + "\r\n" +
                          "分类：" + Bridge.Str(it, "Category") + "\r\n" +
                          "结果：" + StatusText(Bridge.Str(it, "Status")) + "\r\n" +
                          "可自动修复：" + (fix.Length > 0 ? "是（" + fix + "）" : "否，只给建议") + "\r\n" +
                          new string('-', 60) + "\r\n" +
                          "证据\r\n" + Bridge.Str(it, "Detail") + "\r\n\r\n" +
                          "建议\r\n" + Bridge.Str(it, "Advice", "（无）");
            Dialogs.Text(FindForm(), "安全检查详情", Bridge.Str(it, "Title"), body);
        }

        protected override void OnActivated()
        {
            Audit();
        }

        // Run-GuiReadySecurity.ps1 -Mode audit -> {Summary, Items}
        public void Audit()
        {
            if (_busy) return;
            _busy = true;
            SetState("审计中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadySecurity.ps1", "audit", null,
                d =>
                {
                    var summary = Bridge.Dict(d.ContainsKey("Summary") ? d["Summary"] : null);
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);
                        Fill();

                        int ok = (int)Bridge.Num(summary, "Ok");
                        int warn = (int)Bridge.Num(summary, "Warn");
                        int fail = (int)Bridge.Num(summary, "Fail");
                        int unknown = (int)Bridge.Num(summary, "Unknown");
                        _cards[0].Set(ok.ToString(), "符合基线");
                        _cards[1].Set(warn.ToString(), "需要人工确认");
                        _cards[2].Set(fail.ToString(), "可安全修复 " + (int)Bridge.Num(summary, "Fixable") + " 项");
                        _cards[3].Set(unknown.ToString(), "无法本机验证");

                        int total = (int)Bridge.Num(summary, "Total", _items.Count);
                        SetState(ok + " / " + total + " 通过", fail > 0 ? "Danger" : (warn > 0 ? "Warn" : "Success"));
                        Log("[INFO] 安全基线：" + total + " 项，通过 " + ok + "，警告 " + warn + "，不合格 " + fail);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("审计失败", "Danger");
                    Log("[WARN] 安全审计失败: " + err);
                }), 180000);
        }

        // 证据和建议都留在同一列：以前只显示建议，原始证据就丢了
        private void Fill()
        {
            _view.Clear();
            var rows = new List<string[]>();
            foreach (var it in _items)
            {
                string status = Bridge.Str(it, "Status");
                if (_mode == 1 && status != "Warn" && status != "Fail" && status != "Unknown") continue;
                if (_mode == 2 && status != "Fail") continue;

                string detail = Bridge.Str(it, "Detail");
                string advice = Bridge.Str(it, "Advice");
                string cell = detail;
                if (advice.Length > 0) cell = (cell.Length > 0 ? cell + "  |  " : "") + "建议：" + advice;
                rows.Add(new[] { Bridge.Str(it, "Title"), StatusText(status), cell });
                _view.Add(it);
            }
            _table.SetRows(rows);
        }

        // 选中项对应的 security-fix 编号（1..6）；没有自动修复则返回 0
        private int SelectedFixIndex()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _view.Count)
            {
                Log("[WARN] 先在表里选中一条检查项");
                return -1;
            }
            string fix = Bridge.Str(_view[idx], "Fix");
            string[] map = { "firewall", "defender-rt", "smbv1", "guest", "rdp-nla", "password-policy" };
            int i = Array.IndexOf(map, fix);
            if (i < 0)
            {
                Dialogs.Text(FindForm(), "这一项没有自动修复",
                    Bridge.Str(_view[idx], "Title"),
                    "该项属于「改了可能把人锁在门外」或「需要人工判断」的范围，工具不会代改。\n\n" +
                    "证据：\n" + Bridge.Str(_view[idx], "Detail") + "\n\n" +
                    "建议：\n" + Bridge.Str(_view[idx], "Advice", "（无）"));
                return -1;
            }
            return i + 1;
        }

        private static string StatusText(string s)
        {
            switch (s)
            {
                case "OK": return "通过";
                case "Warn": return "警告";
                case "Fail": return "不合格";
                case "Unknown": return "未知";
                default: return string.IsNullOrEmpty(s) ? "未知" : s;
            }
        }

        // fix = 0 表示「全部可修项」，1..6 表示只修选中的那一项
        private void RunFix(int fix)
        {
            if (fix < 0) return;
            var args = new Dictionary<string, object>();
            if (fix > 0) args["Fix"] = fix;
            args["DryRun"] = false;

            string label = fix > 0 ? "单项安全修复（第 " + fix + " 项）" : "安全基线一键修复";
            bool started = Actions.RunAction("security-fix", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + label + "结束，退出码 " + r.ExitCode +
                        "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    Audit();
                }),
                err => SafeInvoke(() => Log("[WARN] 安全修复未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 " + label + "（security-fix）");
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            int gap = 12;
            int perRow = Math.Max(1, Math.Min(_cards.Count, (w + gap) / (208 + gap)));
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
            int y = 76 + rows * (_cards[0].Height + gap) + 2;

            _bar.Left = 0;
            _bar.Top = y;
            _bar.Width = Math.Max(200, w - 4);
            y += _bar.Height + 2;

            _table.Left = 0;
            _table.Top = y;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(120, ClientSize.Height - y - 8);
        }
    }

    // ------------------------------------------------------------ 系统工具
    // 与老版 PowerShell 界面逐项对齐：21 个工具分三组（常用 3 / 诊断与脚本 4 /
    // Windows Admin Center 里也有 14）。本机缺的置灰但仍可点 —— 点了会说缺什么、去哪补。
    internal sealed class ToolPage : PageBase
    {
        private sealed class Tool
        {
            public string Name;
            public string Exe;
            public string Args = "";
            public string Hint = "";
            public string Group = "";
            public UiButton Button;
            public bool Available;
            public Tool(string group, string name, string exe, string args = "", string hint = "")
            {
                Group = group; Name = name; Exe = exe; Args = args; Hint = hint;
            }
        }

        private sealed class Group
        {
            public string Title;
            public Tool[] Items;
            public int CaptionTop;
            public Group(string title, Tool[] items) { Title = title; Items = items; }
        }

        private readonly List<Tool> _tools = new List<Tool>();
        private readonly Group[] _groups;
        private readonly Pill _state;
        private readonly UiButton _wacToggle;
        private bool _wacExpanded = true;
        private bool _wacInstalled;

        private const int CaptionH = 24;
        private const int RowGap = 10;
        private const int BtnH = 38;

        public ToolPage()
        {
            Key = "tool";
            TitleText = "系统工具";
            Subtitle = "Server Core 默认没有这些图形工具，装了官方 App Compatibility FOD 才会出现；缺失的会置灰，点一下会告诉你怎么补。";
            Glyph = "tool";
            Accent = Theme.AccentOf("tool");

            _state = new Pill("未检测", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _groups = new Group[]
            {
                new Group("常用", new[]
                {
                    Add("常用", "记事本",         "notepad.exe"),
                    Add("常用", "命令提示符",     "cmd.exe"),
                    Add("常用", "美化终端",       "scm-term.cmd", "",
                        "还没安装美化终端。到「终端美化」页点「一键美化终端」装上（Nerd Font + Oh My Posh + Fastfetch），之后任意目录输入 scm-term 就能打开 UTF-8 + Nerd Font 的控制台。")
                }),
                new Group("诊断与脚本", new[]
                {
                    Add("诊断与脚本", "MMC 控制台",     "mmc.exe"),
                    Add("诊断与脚本", "资源监视器",     "resmon.exe"),
                    Add("诊断与脚本", "系统信息",       "msinfo32.exe"),
                    Add("诊断与脚本", "PowerShell ISE", "powershell_ise.exe")
                }),
                new Group("Windows Admin Center 里也有", new[]
                {
                    Add("wac", "文件资源管理器", "explorer.exe"),
                    Add("wac", "PowerShell",     "powershell.exe"),
                    Add("wac", "任务管理器",     "taskmgr.exe"),
                    Add("wac", "服务",           "services.msc"),
                    Add("wac", "设备管理器",     "devmgmt.msc"),
                    Add("wac", "磁盘管理",       "diskmgmt.msc"),
                    Add("wac", "任务计划程序",   "taskschd.msc"),
                    Add("wac", "本地用户和组",   "lusrmgr.msc"),
                    Add("wac", "证书管理",       "certmgr.msc"),
                    Add("wac", "防火墙高级安全", "wf.msc"),
                    Add("wac", "注册表编辑器",   "regedit.exe"),
                    Add("wac", "事件查看器",     "eventvwr.msc"),
                    Add("wac", "性能监视器",     "perfmon.exe"),
                    Add("wac", "Hyper-V 管理器", "virtmgmt.msc")
                })
            };

            _wacToggle = new UiButton("收起", ButtonKind.Ghost, 72, 24);
            _wacToggle.Click += (s, e) =>
            {
                _wacExpanded = !_wacExpanded;
                _wacToggle.Text = _wacExpanded ? "收起" : "展开";
                _wacToggle.Invalidate();
                Relayout();
            };
            Controls.Add(_wacToggle);

            foreach (var g in _groups)
                foreach (var t in g.Items)
                    if (t.Button != null) Controls.Add(t.Button);

            RefreshAvailability();
        }

        private Tool Add(string group, string name, string exe, string args = "", string hint = "")
        {
            var t = new Tool(group, name, exe, args, hint);
            t.Button = new UiButton(name, ButtonKind.Normal, 132, BtnH);
            t.Button.Click += (s, e) => Launch(t);
            _tools.Add(t);
            return t;
        }

        protected override void OnActivated()
        {
            RefreshAvailability();
        }

        // 本机有没有这个工具：缺失的置灰、名字后加「（缺失）」
        private void RefreshAvailability()
        {
            int ok = 0;
            foreach (var t in _tools)
            {
                t.Available = ResolveTool(t.Exe).Length > 0;
                if (t.Available) ok++;
                t.Button.Dim = !t.Available;
                t.Button.Text = t.Available ? t.Name : t.Name + "（缺失）";
                t.Button.Invalidate();
            }
            _wacInstalled = WacInstalled();
            _state.SetText(ok + " / " + _tools.Count + " 可用");
            _state.SetKind(ok == _tools.Count ? "Success" : (ok > 0 ? "Warn" : "Danger"));
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
            Relayout();
        }

        private void Launch(Tool tool)
        {
            string path = ResolveTool(tool.Exe);
            if (path.Length == 0)
            {
                string extra = tool.Hint.Length > 0 ? ("  " + tool.Hint)
                    : "  Server Core 默认不带它，到「环境补全」页点「一键补全」装官方桌面体验（FOD），装完重启再试。";
                Log("[WARN] 找不到 " + tool.Name + "（" + tool.Exe + "）。" + extra);
                return;
            }
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = path,
                    Arguments = tool.Args,
                    UseShellExecute = true
                };
                System.Diagnostics.Process.Start(psi);
                Log("[OK] 已打开 " + tool.Name);
            }
            catch (Exception ex)
            {
                Log("[WARN] 打开 " + tool.Name + " 失败: " + ex.Message);
            }
        }

        // System32 -> Windows 目录 -> WindowsApps 别名 -> PATH（老版就是这么找的）
        private static string ResolveTool(string exe)
        {
            if (string.IsNullOrEmpty(exe)) return "";
            string p = System.IO.Path.Combine(Environment.SystemDirectory, exe);
            if (System.IO.File.Exists(p)) return p;
            p = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), exe);
            if (System.IO.File.Exists(p)) return p;
            try
            {
                string alias = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    @"Microsoft\WindowsApps\" + exe);
                if (System.IO.File.Exists(alias)) return alias;
            }
            catch { }
            try
            {
                string pathVar = Environment.GetEnvironmentVariable("PATH") ?? "";
                foreach (var d in pathVar.Split(';'))
                {
                    if (string.IsNullOrWhiteSpace(d)) continue;
                    try
                    {
                        string f = System.IO.Path.Combine(d.Trim(), exe);
                        if (System.IO.File.Exists(f)) return f;
                    }
                    catch { }
                }
            }
            catch { }
            return "";
        }

        // WAC 装没装：只看服务注册项，不联网、不起子进程
        private static bool WacInstalled()
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                           @"SYSTEM\CurrentControlSet\Services\WindowsAdminCenter"))
                    return k != null;
            }
            catch { return false; }
        }

        protected override void BuildContent() { }

        // 分组标题画在页面自身上：它跟着背景一起重绘，不会留下「透明控件下的旧像素」
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            foreach (var grp in _groups)
            {
                bool wac = grp.Title.StartsWith("Windows Admin Center");
                bool hidden = wac && !_wacExpanded;
                string title = grp.Title + "（" + grp.Items.Length + "）";
                if (wac && _wacInstalled && !hidden)
                    title += " · 本机已装 WAC，这些在 WAC 里也能用";
                if (hidden) title = grp.Title + "（已收起）";
                Draw.Text(g, title, Theme.Font(9f, true), Theme.Hint,
                          new Rectangle(0, grp.CaptionTop, Math.Max(200, Width - 120), CaptionH));
            }
        }

        protected override void OnLayout()
        {
            int w = Math.Max(200, ClientSize.Width - 4);
            const int gap = 10;
            int perRow = Math.Max(2, Math.Min(4, (w + gap) / (150 + gap)));
            int bw = (w - (perRow - 1) * gap) / perRow;
            if (bw < 130) bw = 130;

            int y = 76;
            foreach (var grp in _groups)
            {
                grp.CaptionTop = y;
                bool wac = grp.Title.StartsWith("Windows Admin Center");
                bool hidden = wac && !_wacExpanded;

                _wacToggle.Visible = wac;
                if (wac)
                {
                    _wacToggle.Left = Math.Max(0, w - _wacToggle.Width);
                    _wacToggle.Top = y + 1;
                }
                y += CaptionH + 2;

                int i = 0;
                foreach (var t in grp.Items)
                {
                    t.Button.Visible = !hidden;
                    if (hidden) continue;
                    t.Button.Width = bw;
                    t.Button.Left = (i % perRow) * (bw + gap);
                    t.Button.Top = y + (i / perRow) * (BtnH + RowGap);
                    i++;
                }
                if (hidden) continue;
                int rows = (grp.Items.Length + perRow - 1) / perRow;
                y += rows * (BtnH + RowGap) + 8;
            }
        }
    }

    // ------------------------------------------------------------ 终端美化
    internal sealed class BeautyPage : PageBase
    {
        private static readonly string[] Themes =
        {
            "默认（One Dark 自带）", "1_shell", "atomic", "catppuccin_frappe",
            "dracula", "emodipt-extend", "zash"
        };

        private readonly List<StatCard> _cards = new List<StatCard>();
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly UiButton _theme;
        private readonly UiButton _apply;
        private readonly UiButton _status;
        private readonly UiButton _open;
        private readonly UiButton _restore;
        private readonly UiButton _ps7;
        private readonly Pill _state;
        private int _themeIndex;

        public BeautyPage()
        {
            Key = "beauty";
            TitleText = "终端美化";
            Subtitle = "把 Server Core 的 conhost 打扮好看：Nerd Font + Oh My Posh 提示符 + Fastfetch 首屏信息。装的时候缺什么就从官方源下载（可用环境变量 SCM_CONSOLE_MIRROR 换源）。";
            Glyph = "beauty";
            Accent = Theme.AccentOf("beauty");

            _state = new Pill("未检查", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            string[][] items =
            {
                new[] { "Nerd Font", "—", "#34D399", "MesloLGS NF" },
                new[] { "oh-my-posh", "—", "#409EFF", "提示符" },
                new[] { "fastfetch", "—", "#E6A23C", "首屏信息（可选）" },
                new[] { "PowerShell 7", "—", "#C084FC", "pwsh（可选）" }
            };
            foreach (var s in items)
            {
                var c = new StatCard(s[0], s[1], Theme.Hex(s[2]), s[3]);
                _cards.Add(c);
                Controls.Add(c);
            }

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            _theme = new UiButton(ThemeText(), ButtonKind.Normal, 240, 36) { Location = new Point(0, 0) };
            _theme.Click += (s, e) => CycleTheme();
            _apply = new UiButton("一键美化终端", ButtonKind.Primary, 132, 36) { Location = new Point(0, 0) };
            _apply.Click += (s, e) => RunAction("console-install", "一键美化终端",
                                               new Dictionary<string, object> { { "Theme", _themeIndex + 1 } });
            _status = new UiButton("状态检查", ButtonKind.Normal, 96, 36) { Location = new Point(0, 0) };
            _status.Click += (s, e) => Check();
            _open = new UiButton("打开美化终端", ButtonKind.Normal, 124, 36) { Location = new Point(0, 0) };
            _open.Click += (s, e) => RunAction("console-open", "打开美化终端", null);
            _restore = new UiButton("一键还原", ButtonKind.Normal, 96, 36) { Location = new Point(0, 0) };
            _restore.Click += (s, e) => RunAction("console-restore", "终端一键还原", null);
            // 美化默认用 PowerShell 5.1；想用 7 的提示符/主题在这里装（zip 免安装）
            _ps7 = new UiButton("安装 PowerShell 7", ButtonKind.Normal, 140, 36) { Location = new Point(0, 0) };
            _ps7.Click += (s, e) => RunAction("console-ps7", "安装 PowerShell 7", null);
            _actions.Controls.Add(_theme);
            _actions.Controls.Add(_apply);
            _actions.Controls.Add(_status);
            _actions.Controls.Add(_open);
            _actions.Controls.Add(_restore);
            _actions.Controls.Add(_ps7);
            _buttons.Add(_theme);
            _buttons.Add(_apply);
            _buttons.Add(_status);
            _buttons.Add(_open);
            _buttons.Add(_restore);
            _buttons.Add(_ps7);
        }

        protected override void OnActivated()
        {
            Check();
        }

        // 本机自查（不跑子进程，纯文件系统 + PATH）
        private void Check()
        {
            bool font = FontInstalled();
            string posh = OnPath("oh-my-posh.exe",
                                 System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                                        @"Programs\oh-my-posh\bin\oh-my-posh.exe"),
                                 System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                                                        @"oh-my-posh\bin\oh-my-posh.exe"));
            string ff = OnPath("fastfetch.exe",
                               System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                                      @"Microsoft\WinGet\Links\fastfetch.exe"));

            _cards[0].Set(font ? "已安装" : "未安装", "MesloLGS NF");
            _cards[0].Accent = font ? Theme.Ok : Theme.Warn;
            _cards[0].Invalidate();

            _cards[1].Set(posh.Length > 0 ? "已安装" : "未安装", posh.Length > 0 ? posh : "oh-my-posh");
            _cards[1].Accent = posh.Length > 0 ? Theme.Ok : Theme.Warn;
            _cards[1].Invalidate();

            _cards[2].Set(ff.Length > 0 ? "已安装" : "未安装", ff.Length > 0 ? ff : "fastfetch（可选）");
            _cards[2].Accent = ff.Length > 0 ? Theme.Ok : Theme.Hint;
            _cards[2].Invalidate();

            string pwsh = OnPath("pwsh.exe",
                                 System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                                                        @"PowerShell\7\pwsh.exe"));
            _cards[3].Set(pwsh.Length > 0 ? "已安装" : "未安装", pwsh.Length > 0 ? pwsh : "可选：装 7 用新语法");
            _cards[3].Accent = pwsh.Length > 0 ? Theme.Ok : Theme.Hint;
            _cards[3].Invalidate();

            bool ready = font && posh.Length > 0;
            SetState(ready ? "已美化" : "未就绪", ready ? "Success" : "Warn");
            Log("[INFO] 终端美化状态：字体 " + (font ? "有" : "无") +
                "，oh-my-posh " + (posh.Length > 0 ? "有" : "无") +
                "，fastfetch " + (ff.Length > 0 ? "有" : "无") +
                "，pwsh " + (pwsh.Length > 0 ? "有" : "无"));
        }

        private static bool FontInstalled()
        {
            try
            {
                string dir = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Fonts");
                return System.IO.Directory.GetFiles(dir, "Meslo*").Length > 0;
            }
            catch { return false; }
        }

        private static string OnPath(string exe, params string[] candidates)
        {
            foreach (var c in candidates)
            {
                try { if (!string.IsNullOrEmpty(c) && System.IO.File.Exists(c)) return c; }
                catch { }
            }
            string[] dirs;
            try { dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'); }
            catch { return ""; }
            foreach (var d in dirs)
            {
                if (string.IsNullOrWhiteSpace(d)) continue;
                try
                {
                    string p = System.IO.Path.Combine(d.Trim(), exe);
                    if (System.IO.File.Exists(p)) return p;
                }
                catch { }
            }
            return "";
        }

        private void RunAction(string id, string name, Dictionary<string, object> extra)
        {
            var args = new Dictionary<string, object>();
            args["DryRun"] = false;
            if (extra != null) foreach (var kv in extra) args[kv.Key] = kv.Value;

            bool started = Actions.RunAction(id, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + name + "结束，退出码 " + r.ExitCode +
                        "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    Check();
                }),
                err => SafeInvoke(() => Log("[WARN] " + name + "未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 " + name + "（" + id + "）");
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        private string ThemeText()
        {
            return "提示符主题：" + Themes[_themeIndex] + "  ⇄";
        }

        private void CycleTheme()
        {
            _themeIndex = (_themeIndex + 1) % Themes.Length;
            _theme.Text = ThemeText();
            _theme.Invalidate();
            Log("[INFO] 提示符主题切换为 " + Themes[_themeIndex]);
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            int gap = 12;
            int perRow = Math.Max(1, Math.Min(_cards.Count, (w + gap) / (208 + gap)));
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
            int y = 76 + rows * (_cards[0].Height + gap) + 4;

            _actions.Left = 0;
            _actions.Top = y;
            _actions.Width = Math.Max(200, w - 4);
            // 六个按钮在 1024×700 下放不下一行，统一走换行布局
            _actions.Height = LayoutButtonRow(_buttons, _actions.Width, 0);
        }
    }


    // 「全部功能」页在 ActionConsole.cs 里实现（通用动作控制台）

    // ------------------------------------------------------------ 关于
    internal sealed class AboutPage : PageBase
    {
        private readonly AboutCard _card;
        private readonly UiButton _site;
        private readonly UiButton _update;
        private readonly UiButton _openLogs;
        private readonly UiButton _openReports;

        public AboutPage()
        {
            Key = "about";
            TitleText = "关于";
            Subtitle = "Server Core GUI 就绪工具 —— 让带界面的程序在 Windows Server Core 上真正跑起来。";
            Glyph = "about";
            Accent = Theme.AccentOf("about");

            _card = new AboutCard { HoverGlow = false, Accent = Accent };
            Controls.Add(_card);

            _site = new UiButton("打开项目主页", ButtonKind.Primary, 132, 34) { Location = new Point(0, 0) };
            _update = new UiButton("完整性自检", ButtonKind.Normal, 112, 34) { Location = new Point(0, 0) };
            _site.Click += (s, e) => OpenHome();
            _update.Click += (s, e) =>
            {
                bool started = Actions.RunAction("selfcheck", null,
                    line => SafeInvoke(() => Log(line)),
                    r => SafeInvoke(() => Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") +
                                             "完整性自检结束，退出码 " + r.ExitCode)),
                    err => SafeInvoke(() => Log("[WARN] 自检未启动: " + err)));
                if (started) Log("[STEP] 已提交动作 本工具完整性自检（selfcheck）");
            };
            _card.Controls.Add(_site);
            _card.Controls.Add(_update);

            _openLogs = new UiButton("打开日志目录", ButtonKind.Normal, 116, 34) { Location = new Point(0, 0) };
            _openLogs.Click += (s, e) => OpenFolder("logs");
            _openReports = new UiButton("打开报告目录", ButtonKind.Normal, 116, 34) { Location = new Point(0, 0) };
            _openReports.Click += (s, e) => OpenFolder("reports");
            _card.Controls.Add(_openLogs);
            _card.Controls.Add(_openReports);
        }

        private void OpenFolder(string name)
        {
            try
            {
                string dir = System.IO.Path.Combine(Bridge.Root, name);
                if (!System.IO.Directory.Exists(dir))
                    System.IO.Directory.CreateDirectory(dir);
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = dir,
                    UseShellExecute = true
                });
                Log("[OK] 已打开目录 " + dir);
            }
            catch (Exception ex)
            {
                Log("[WARN] 打开目录失败: " + ex.Message);
            }
        }

        private void OpenHome()
        {
            const string url = "https://orangeartc0915.github.io/Server-core-manager/";
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = url,
                    UseShellExecute = true
                });
                Log("[OK] 已在浏览器打开项目主页");
            }
            catch (Exception ex)
            {
                Log("[INFO] 项目主页 " + url + "（打开失败: " + ex.Message + "）");
            }
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _card.Left = 0;
            _card.Top = 76;
            _card.Width = Math.Max(240, w - 4);

            // 四个按钮排在「作者/QQ/版本/GitHub/官网」和底部说明的下面，统一换行布局。
            // 以前是右下角固定 + 左下角固定，卡片一窄就互相压住，底部说明还会被按钮盖掉。
            int pad = 16;
            var btns = new List<UiButton> { _openLogs, _openReports, _site, _update };
            int bh = LayoutButtonRow(btns, _card.Width - pad * 2, 0);
            const int top = 226;

            int avail = ClientSize.Height - 84;
            int needH = top + bh + pad;
            int h = Math.Min(320, Math.Max(needH, avail));
            _card.Height = h;

            // 放不下就把整行往上收一点（仍然在说明文字下方）
            int y = top;
            if (y + bh > h - pad) y = Math.Max(200, h - pad - bh);
            LayoutButtonRow(btns, _card.Width - pad * 2, y);
            foreach (var b in btns) b.Left += pad;
        }
    }

    // ============================================================
    // 关于卡片：继承 SurfaceCard，只重写 OnPaintContent（玻璃底由基类负责）。
    // ============================================================

    internal sealed class AboutCard : SurfaceCard
    {
        // 构建日期按 exe 的写入时间算，别写死 —— 写死的日期放两周就对不上了
        private static string BuildStamp()
        {
            try
            {
                return System.IO.File.GetLastWriteTime(
                    System.Windows.Forms.Application.ExecutablePath).ToString("yyyy-MM-dd");
            }
            catch { return "—"; }
        }

        protected override void OnPaintContent(Graphics g, Rectangle r)
        {
            Draw.Text(g, "SCM 运维控制台", Theme.Font(16f, true), Theme.Text,
                      new Rectangle(22, 16, Math.Max(120, r.Width - 44), 34));
            Draw.Text(g, "Windows Server Core 上的原生图形界面", Theme.Font(9.5f), Theme.Hint,
                      new Rectangle(22, 44, Math.Max(120, r.Width - 44), 20));

            int y = 76;
            string[][] rows =
            {
                new[] { "作者：", "mmm" },
                new[] { "QQ 群：", "1034243331" },
                new[] { "版本：", "v2.0　构建 " + BuildStamp() },
                new[] { "GitHub：", "https://github.com/OrangeArtc0915/Server-core-manager" },
                new[] { "官网：", "https://orangeartc0915.github.io/Server-core-manager/" }
            };
            foreach (var row in rows)
            {
                if (y > 176) break;
                bool link = row[0] == "GitHub：" || row[0] == "官网：";
                Draw.Text(g, row[0], Theme.Font(10f), Theme.Hint,
                          new Rectangle(22, y, 80, 22));
                Draw.Text(g, row[1], Theme.Font(10f, row[0] == "作者："), link ? Theme.AccentHi : Theme.Sub,
                          new Rectangle(96, y, Math.Max(60, r.Width - 120), 22));
                if (link)
                {
                    // 下划一条线，告诉用户这行能点（点了直接开浏览器）
                    var sz = TextRenderer.MeasureText(row[1], Theme.Font(10f));
                    int lineW = Math.Min(sz.Width, Math.Max(60, r.Width - 126));
                    using (var pen = new Pen(Color.FromArgb(120, Theme.AccentHi)))
                        g.DrawLine(pen, 96, y + 19, 96 + lineW, y + 19);
                }
                y += 24;
            }
            // 说明文字固定在按钮上方（以前按 r.Height 锚在底部，正好被按钮压住）
            if (r.Height >= 216)
                Draw.Text(g, "用着有问题、或者想要哪个功能：到 QQ 群里说一声。", Theme.Font(9f), Theme.Hint,
                          new Rectangle(22, 200, Math.Max(60, r.Width - 44), 20));
        }

        private const string GithubUrl = "https://github.com/OrangeArtc0915/Server-core-manager";
        private const string SiteUrl = "https://orangeartc0915.github.io/Server-core-manager/";

        // GitHub 是第 4 行（y = 76 + 3 * 24），官网是第 5 行
        private static Rectangle GithubHit(int width)
        {
            return new Rectangle(22, 76 + 3 * 24, Math.Max(80, width - 44), 22);
        }

        private static Rectangle SiteHit(int width)
        {
            return new Rectangle(22, 76 + 4 * 24, Math.Max(80, width - 44), 22);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            bool onLink = GithubHit(Width).Contains(e.Location) || SiteHit(Width).Contains(e.Location);
            Cursor = onLink ? Cursors.Hand : Cursors.Default;
            base.OnMouseMove(e);
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            string url = "";
            if (e.Button == MouseButtons.Left)
            {
                if (GithubHit(Width).Contains(e.Location)) url = GithubUrl;
                else if (SiteHit(Width).Contains(e.Location)) url = SiteUrl;
            }
            if (url.Length > 0)
            {
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = url,
                        UseShellExecute = true
                    });
                }
                catch { }
            }
            base.OnMouseClick(e);
        }
    }
}

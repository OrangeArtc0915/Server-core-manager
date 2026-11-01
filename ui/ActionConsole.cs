using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 全部功能 = 通用动作控制台（PowerShell 版「更多」页的同款能力）。
    // 左边分组、中间动作、右边参数表单；参数类型与 PowerShell 版一致：
    //   Text / Multi / Check / Combo（1 基索引）/ Browse（文件或目录）。
    // 66 条动作全部由 gui\Run-GuiReadyActions.ps1 -Mode list 提供，
    // 新增动作只要改 GuiReady.Actions.ps1，这里不用跟着改。
    // ============================================================
    internal sealed class MorePage : PageBase
    {
        private sealed class ParamRow
        {
            public string Name;
            public string Label;
            public string Type;
            public string Browse;
            public bool Required;
            public UiInput Input;
            public UiCheck Check;
            public UiButton Combo;
            public List<string> Options;
            public int ComboIndex;
        }

        private readonly DataTable _groups;
        private readonly DataTable _actions;
        private readonly Panel _form;
        private readonly Panel _bar;
        private readonly UiButton _run;
        private readonly UiButton _dry;
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _all = new List<Dictionary<string, object>>();
        private readonly List<Dictionary<string, object>> _groupItems = new List<Dictionary<string, object>>();
        private readonly List<ParamRow> _rows = new List<ParamRow>();
        private readonly List<string> _groupNames = new List<string>();
        private Dictionary<string, object> _current;
        private int _formWidth = -1;
        private bool _busy;
        private long _lastLoadMs;
        private string _pendingGroup = "";

        // 其它页的「高级」按钮会调这个：切到本页并定位到指定分组
        public void FocusGroup(string group)
        {
            _pendingGroup = group == null ? "" : group;
            if (_groupNames.Count > 0) SelectPendingGroup();
        }

        private void SelectPendingGroup()
        {
            if (_pendingGroup.Length == 0) return;
            int idx = _groupNames.IndexOf(_pendingGroup);
            if (idx < 0) return;
            SelectGroup(idx);
            _groups.SetSelected(idx);
            _pendingGroup = "";
        }

        public MorePage()
        {
            Key = "more";
            TitleText = "全部功能";
            Subtitle = "所有动作的入口：左边选分组，中间选动作，右边填参数后运行（可先「仅预览」看要执行什么）。";
            Glyph = "more";
            Accent = Theme.AccentOf("more");

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _groups = new DataTable { Location = new Point(0, 76) };
            _groups.Columns.Add(new DataColumn("分组", 150));
            _groups.RowActivated += SelectGroup;
            Controls.Add(_groups);

            _actions = new DataTable { Location = new Point(0, 76) };
            _actions.Columns.Add(new DataColumn("动作", 250));
            _actions.RowActivated += SelectAction;
            Controls.Add(_actions);

            _form = new Panel { BackColor = Theme.Bg, AutoScroll = true };
            Controls.Add(_form);

            _bar = new Panel { BackColor = Color.Transparent };
            Controls.Add(_bar);

            _dry = new UiButton("仅预览", ButtonKind.Normal, 96, 34) { Location = new Point(0, 0) };
            _dry.Click += (s, e) => Run(true);
            _run = new UiButton("运行", ButtonKind.Primary, 96, 34) { Location = new Point(0, 0) };
            _run.Click += (s, e) => Run(false);
            _bar.Controls.Add(_dry);
            _bar.Controls.Add(_run);
        }

        protected override void OnActivated()
        {
            // 动作清单来自 gui\GuiReady.Actions.ps1，一份进程要 400ms+ 才读得完。
            // 清单本身在运行期不会变，60 秒内重复进页直接复用上次结果。
            long now = Environment.TickCount;
            if (_all.Count > 0 && _lastLoadMs != 0 && now - _lastLoadMs < 60000 && now >= _lastLoadMs)
            {
                SetState("已缓存 " + _all.Count + " 条动作", "Neutral");
                return;
            }
            Load();
        }

        // Run-GuiReadyActions.ps1 -Mode list -> 顶层 Items
        public void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState("读取中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadyActions.ps1", "list", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _all.Clear();
                        _all.AddRange(items);
                        _lastLoadMs = Environment.TickCount;

                        _groupNames.Clear();
                        foreach (var it in items)
                        {
                            string g = Bridge.Str(it, "Group", "其他");
                            if (!_groupNames.Contains(g)) _groupNames.Add(g);
                        }

                        var rows = new List<string[]>();
                        foreach (var g in _groupNames)
                        {
                            int n = 0;
                            foreach (var it in items) if (Bridge.Str(it, "Group", "其他") == g) n++;
                            rows.Add(new[] { g + "（" + n + "）" });
                        }
                        _groups.SetRows(rows);
                        SetState(items.Count + " 个动作 · " + _groupNames.Count + " 组",
                                 items.Count > 0 ? "Info" : "Neutral");
                        Log("[INFO] 动作清单：" + items.Count + " 个，分 " + _groupNames.Count + " 组");

                        if (_groupNames.Count > 0)
                        {
                            if (_pendingGroup.Length > 0) SelectPendingGroup();
                            else SelectGroup(0);
                        }
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 动作清单读取失败: " + err);
                }), 60000);
        }

        private void SelectGroup(int index)
        {
            if (index < 0 || index >= _groupNames.Count) return;
            string group = _groupNames[index];

            _groupItems.Clear();
            var rows = new List<string[]>();
            foreach (var it in _all)
            {
                if (Bridge.Str(it, "Group", "其他") != group) continue;
                _groupItems.Add(it);
                string name = Bridge.Str(it, "Name");
                if (Bridge.Bool(it, "DryRun")) name += "（默认预览）";
                rows.Add(new[] { name });
            }
            _actions.SetRows(rows);
            if (_groupItems.Count > 0) SelectAction(0);
            else { _current = null; BuildForm(); }
        }

        private void SelectAction(int index)
        {
            if (index < 0 || index >= _groupItems.Count) return;
            _current = _groupItems[index];
            BuildForm();
        }

        // ---------------- 参数表单
        private void BuildForm()
        {
            ClearForm();
            _rows.Clear();
            if (_current == null)
            {
                _dry.Dim = true;
                _dry.Invalidate();
                return;
            }

            // 只有声明了 DryRun 的动作才有预览语义；否则点「仅预览」会被误解成安全模式
            _dry.Dim = !Bridge.Bool(_current, "DryRun");
            _dry.Invalidate();

            int width = Math.Max(260, _form.ClientSize.Width - 26);
            _formWidth = _form.ClientSize.Width;
            int y = 6;

            string name = Bridge.Str(_current, "Name");
            string desc = Bridge.Str(_current, "Desc");

            var title = new Label
            {
                Text = name,
                AutoSize = false,
                ForeColor = Theme.Text,
                BackColor = Theme.Bg,
                Font = Theme.Font(10.5f, true),
                Location = new Point(0, y),
                Size = new Size(width, 46)
            };
            _form.Controls.Add(title);
            y += 48;

            if (desc.Length > 0)
            {
                var sz = TextRenderer.MeasureText(desc, Theme.Font(9f),
                    new Size(width, 2000), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                var sub = new Label
                {
                    Text = desc,
                    AutoSize = false,
                    ForeColor = Theme.Hint,
                    BackColor = Theme.Bg,
                    Font = Theme.Font(9f),
                    Location = new Point(0, y),
                    Size = new Size(width, Math.Min(220, sz.Height + 8))
                };
                _form.Controls.Add(sub);
                y += Math.Min(220, sz.Height + 8) + 8;
            }

            if (Bridge.Bool(_current, "DryRun"))
            {
                var hint = new Label
                {
                    Text = "这条动作默认只做预览；确认无误后用「运行」真正执行。",
                    AutoSize = false,
                    ForeColor = Theme.Warn,
                    BackColor = Theme.Bg,
                    Font = Theme.Font(8.75f),
                    Location = new Point(0, y),
                    Size = new Size(width, 20)
                };
                _form.Controls.Add(hint);
                y += 26;
            }

            var ps = Bridge.List(_current.ContainsKey("Params") ? _current["Params"] : null);
            foreach (var p in ps)
            {
                string type = Bridge.Str(p, "Type", "Text");
                var row = new ParamRow
                {
                    Name = Bridge.Str(p, "Name"),
                    Label = Bridge.Str(p, "Label", Bridge.Str(p, "Name")),
                    Type = type,
                    Browse = Bridge.Str(p, "Browse"),
                    Required = Bridge.Bool(p, "Req"),
                    Options = Bridge.StrList(p, "Options")
                };

                string label = row.Label + (row.Required ? " *" : "");
                var lbl = new Label
                {
                    Text = label,
                    AutoSize = false,
                    ForeColor = row.Required ? Theme.Sub : Theme.Hint,
                    BackColor = Theme.Bg,
                    Font = Theme.Font(9f),
                    Location = new Point(0, y),
                    Size = new Size(width, 20)
                };
                _form.Controls.Add(lbl);
                y += 22;

                if (type == "Check")
                {
                    row.Check = new UiCheck("", Bridge.Bool(p, "Default"));
                    row.Check.Location = new Point(0, y);
                    row.Check.Width = width;
                    _form.Controls.Add(row.Check);
                    y += 30;
                }
                else if (type == "Combo")
                {
                    row.ComboIndex = 0;
                    row.Combo = new UiButton(ComboText(row), ButtonKind.Normal,
                                             Math.Min(width, 300), 32);
                    var captured = row;
                    // 弹真下拉菜单，而不是循环点 —— 选项多的时候循环点根本找不到
                    row.Combo.Click += (s, e) =>
                    {
                        if (captured.Options.Count == 0) return;
                        var menu = new ContextMenuStrip { Font = Theme.Font(9.5f) };
                        for (int oi = 0; oi < captured.Options.Count; oi++)
                        {
                            int pick = oi;
                            bool current = oi == captured.ComboIndex;
                            menu.Items.Add((current ? "✓ " : "    ") + captured.Options[oi], null,
                                (ms, me) =>
                                {
                                    captured.ComboIndex = pick;
                                    captured.Combo.Text = ComboText(captured);
                                    captured.Combo.Invalidate();
                                });
                        }
                        menu.Show(captured.Combo, new Point(0, captured.Combo.Height));
                    };
                    row.Combo.Location = new Point(0, y);
                    _form.Controls.Add(row.Combo);
                    y += 38;
                }
                else if (type == "Multi")
                {
                    row.Input = new UiInput(width, "", 96, true)
                    {
                        Location = new Point(0, y)
                    };
                    row.Input.ValueText = Bridge.Str(p, "Default");
                    _form.Controls.Add(row.Input);
                    y += 102;
                }
                else
                {
                    int boxW = width;
                    bool browse = row.Browse.Length > 0;
                    if (browse) boxW = Math.Max(120, width - 40);

                    row.Input = new UiInput(boxW) { Location = new Point(0, y) };
                    row.Input.ValueText = Bridge.Str(p, "Default");
                    // 密码类参数（自动登录密码等）别在界面上明文显示
                    if (type == "Password") row.Input.Box.UseSystemPasswordChar = true;
                    _form.Controls.Add(row.Input);

                    if (browse)
                    {
                        var btn = new UiButton("…", ButtonKind.Normal, 32, 32)
                        {
                            Location = new Point(boxW + 6, y)
                        };
                        var captured = row;
                        btn.Click += (s, e) => Browse(captured);
                        _form.Controls.Add(btn);
                    }
                    y += 38;
                }
                _rows.Add(row);
                y += 4;
            }

            _form.AutoScrollMinSize = new Size(0, y + 10);
        }

        private static string ComboText(ParamRow row)
        {
            if (row.Options == null || row.Options.Count == 0) return "（无选项）";
            int i = row.ComboIndex;
            if (i < 0 || i >= row.Options.Count) i = 0;
            return row.Options[i] + "  ⇄";
        }

        private void Browse(ParamRow row)
        {
            if (row.Browse == "Folder")
            {
                using (var dlg = new FolderBrowserDialog())
                {
                    dlg.Description = row.Label;
                    if (dlg.ShowDialog(FindForm()) == DialogResult.OK)
                        row.Input.ValueText = dlg.SelectedPath;
                }
            }
            else
            {
                using (var dlg = new OpenFileDialog())
                {
                    dlg.Title = row.Label;
                    dlg.Filter = "所有文件 (*.*)|*.*";
                    dlg.CheckFileExists = false;
                    if (dlg.ShowDialog(FindForm()) == DialogResult.OK)
                        row.Input.ValueText = dlg.FileName;
                }
            }
        }

        private void ClearForm()
        {
            while (_form.Controls.Count > 0)
            {
                var c = _form.Controls[0];
                _form.Controls.RemoveAt(0);
                c.Dispose();
            }
        }

        // ---------------- 运行
        private void Run(bool dryRun)
        {
            if (_current == null)
            {
                Log("[WARN] 先在左边选一个分组和动作");
                return;
            }
            if (Actions.Busy)
            {
                Log("[WARN] 已有动作在运行：" + Actions.CurrentId + "，等它结束再试");
                return;
            }
            if (dryRun && !Bridge.Bool(_current, "DryRun"))
            {
                Log("[WARN] 这条动作不支持预览，请直接用「运行」");
                return;
            }

            var args = new Dictionary<string, object>();
            var missing = new List<string>();
            foreach (var row in _rows)
            {
                if (row.Type == "Check")
                {
                    args[row.Name] = row.Check != null && row.Check.Checked;
                    continue;
                }
                if (row.Type == "Combo")
                {
                    args[row.Name] = row.ComboIndex + 1;
                    continue;
                }
                string value = row.Input == null ? "" : row.Input.ValueText;
                args[row.Name] = value;
                if (row.Required && value.Trim().Length == 0) missing.Add(row.Label);
            }
            args["DryRun"] = dryRun;

            if (missing.Count > 0)
            {
                Log("[WARN] 还有必填项没有填：" + string.Join("、", missing.ToArray()));
                return;
            }

            string id = Bridge.Str(_current, "Id");
            string name = Bridge.Str(_current, "Name");
            bool started = Actions.RunAction(id, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + name + "结束，退出码 " + r.ExitCode +
                        "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                }),
                err => SafeInvoke(() => Log("[WARN] " + name + "未启动: " + err)));

            if (started)
                Log("[STEP] 已提交动作 " + name + "（" + id + (dryRun ? " · 仅预览" : "") + "）");
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
            int h = Math.Max(160, ClientSize.Height - 80);

            int groupW = Math.Max(120, Math.Min(170, w / 6));
            int actionW = Math.Max(180, Math.Min(280, w / 4));
            int gap = 10;
            int formW = Math.Max(200, w - groupW - actionW - gap * 2 - 4);

            _groups.Left = 0;
            _groups.Top = 76;
            _groups.Width = groupW;
            _groups.Height = h;

            _actions.Left = groupW + gap;
            _actions.Top = 76;
            _actions.Width = actionW;
            _actions.Height = h;

            _form.Left = groupW + actionW + gap * 2;
            _form.Top = 76;
            _form.Width = formW;
            _form.Height = Math.Max(120, h - 46);

            _bar.Left = _form.Left;
            _bar.Top = _form.Bottom + 6;
            _bar.Width = formW;
            _bar.Height = 38;
            _dry.Top = 2;
            _dry.Left = Math.Max(0, formW - _dry.Width - _run.Width - 12);
            _run.Top = 2;
            _run.Left = Math.Max(0, formW - _run.Width - 4);

            if (_current != null && _formWidth != _form.ClientSize.Width) BuildForm();
        }
    }
}

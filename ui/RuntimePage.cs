using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 运行库：Windows 原生多版本运行时管理。
    // 列表来自 gui\Run-GuiReadyRuntime.ps1 -Mode list：
    //   每个运行时 × 每个版本一行，状态分「当前 / 已装 / 可安装」。
    // 安装 / 切换 / 卸载走 actions（runtime-install/switch/remove），
    // 这样日志能实时回到下方运行日志栏，任务记录与审计也不会漏。
    // ============================================================
    internal sealed class RuntimePage : PageBase
    {
        private sealed class Row
        {
            public string Lang = "";
            public string Name = "";
            public string Version = "";
            public bool Installed;
            public bool Current;
            public bool OnPath;
            public string Note = "";
        }

        // 动作里的下拉顺序必须与 GuiReady.Runtime.ps1 的清单一致
        private static readonly Dictionary<string, int> LangIndex = new Dictionary<string, int>
        {
            { "node", 1 }, { "python", 2 }, { "go", 3 }, { "java", 4 }, { "php", 5 }, { "bun", 6 }
        };

        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Row> _rows = new List<Row>();
        private readonly Dictionary<string, string> _langNote = new Dictionary<string, string>();
        private readonly Dictionary<string, string> _detected = new Dictionary<string, string>();
        private string _root = "";
        private bool _busy;

        public RuntimePage()
        {
            Key = "runtime";
            TitleText = "运行库";
            Subtitle = "Node / Python / Go / Java / PHP / Bun 多版本共存：官方 zip 解压到 runtimes 目录，current 用 junction 指路，机器 PATH 只挂 current —— 切版本不用改脚本。";
            Glyph = "runtime";
            Accent = Theme.AccentOf("runtime");

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn("运行时", 140));
            _table.Columns.Add(new DataColumn("版本", 110));
            _table.Columns.Add(new DataColumn("状态", 90));
            _table.Columns.Add(new DataColumn("机器 PATH", 90));
            _table.Columns.Add(new DataColumn("说明", 420));
            _table.ActivateOnDoubleClick = true;
            _table.RowActivated += ActivateRow;
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton("安装选中", ButtonKind.Primary, 106, InstallSelected);
            AddButton("切换为当前", ButtonKind.Normal, 110, SwitchSelected);
            AddButton("卸载选中", ButtonKind.Danger, 104, UninstallSelected);
            AddButton("刷新", ButtonKind.Normal, 80, () => Load(false));
            AddButton("修复 PATH", ButtonKind.Normal, 100, RepairPath);
            AddButton("联网校验", ButtonKind.Normal, 100, () => Load(true));
            AddButton("打开目录", ButtonKind.Ghost, 100, OpenDir);
        }

        private void AddButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 0) };
            b.Click += (s, e) => onClick();
            _buttons.Add(b);
            _actions.Controls.Add(b);
        }

        protected override void BuildContent() { }

        protected override void OnActivated()
        {
            Load(false);
        }

        // ---------------------------------------------------------- 读取
        private void Load(bool probe)
        {
            if (_busy) return;
            _busy = true;
            SetState(probe ? "联网校验中…" : "读取中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadyRuntime.ps1", probe ? "probe" : "list", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    string root = Bridge.Str(data, "Root");
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        Fill(items, root);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 运行库状态读取失败: " + err);
                }), probe ? 300000 : 120000);
        }

        private void Fill(List<Dictionary<string, object>> items, string root)
        {
            if (root.Length > 0) _root = root;
            _rows.Clear();
            _langNote.Clear();
            _detected.Clear();

            var rows = new List<string[]>();
            int installedCount = 0, currentCount = 0, langs = 0;
            foreach (var it in items)
            {
                langs++;
                string id = Bridge.Str(it, "Id");
                string name = Bridge.Str(it, "Name", id);
                bool onPath = Bridge.Bool(it, "OnPath");
                string detected = Bridge.Str(it, "Detected");
                string note = Bridge.Str(it, "Note");
                if (id.Length > 0)
                {
                    _langNote[id] = note;
                    _detected[id] = detected;
                }

                foreach (var v in Bridge.List(it.ContainsKey("Versions") ? it["Versions"] : null))
                {
                    var row = new Row
                    {
                        Lang = id,
                        Name = name,
                        Version = Bridge.Str(v, "Version"),
                        Installed = Bridge.Bool(v, "Installed"),
                        Current = Bridge.Bool(v, "Current"),
                        OnPath = onPath
                    };
                    string size = Bridge.Str(v, "Size");
                    string probeText = Bridge.Str(v, "Probe");

                    if (row.Current)
                    {
                        currentCount++;
                        installedCount++;
                        row.Note = detected.Length > 0 ? "current 指向这里 · 探测到 " + detected : "current 指向这里";
                    }
                    else if (row.Installed)
                    {
                        installedCount++;
                        row.Note = "已装，可切换为当前版本";
                    }
                    else
                    {
                        row.Note = size.Length > 0 ? "可安装（" + size + "，官方 zip）" : "可安装";
                    }
                    if (probeText.Length > 0)
                        row.Note += probeText == "ok" ? " · 源可用" : " · 源不可用（" + probeText + "）";

                    string path = row.Current ? (onPath ? "已挂载" : "未写入") : "—";
                    rows.Add(new[] { name, row.Version, StatusText(row), path, row.Note });
                    _rows.Add(row);
                }
            }

            _table.SetRows(rows, true);
            if (rows.Count == 0)
            {
                SetState("清单为空", "Warn");
                Log("[WARN] 运行库清单为空，检查 lib\\GuiReady.Runtime.ps1 是否随包分发");
                return;
            }
            string text = langs + " 个运行时 · 已装 " + installedCount + " 个版本 · 当前 " + currentCount + " 个";
            SetState(text, installedCount > 0 ? "Success" : "Neutral");
            Log("[INFO] 运行库：" + text + "；目录 " + _root);
        }

        private static string StatusText(Row r)
        {
            if (r.Current) return "当前";
            if (r.Installed) return "已装";
            return "可安装";
        }

        // ---------------------------------------------------------- 操作
        private void ActivateRow(int idx)
        {
            if (idx < 0 || idx >= _rows.Count) return;
            var r = _rows[idx];
            if (r.Current)
            {
                string note;
                if (_langNote.TryGetValue(r.Lang, out note) && note.Length > 0) Log("[INFO] " + r.Name + "：" + note);
                return;
            }
            if (r.Installed) SwitchSelected();
            else InstallSelected();
        }

        private Row Selected()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _rows.Count) return null;
            return _rows[idx];
        }

        private void InstallSelected()
        {
            var r = Selected();
            if (r == null) { Log("[WARN] 先在列表里选一行"); return; }
            if (r.Installed) { Log("[WARN] " + r.Name + " " + r.Version + " 已经装好了；要换版本用「切换为当前」"); return; }

            string note;
            _langNote.TryGetValue(r.Lang, out note);
            string msg = "下载并安装 " + r.Name + " " + r.Version + "？\r\n\r\n" +
                         "安装位置：" + _root + "\\" + r.Lang + "\\" + r.Version + "\r\n" +
                         "下载源：国内镜像优先，失败自动回退官方地址。\r\n" +
                         "下载大小见列表说明，服务器上可能要等一会儿。";
            if (!Dialogs.Confirm(FindForm(), "安装运行时", msg, "开始安装")) return;

            var args = new Dictionary<string, object>();
            args["Lang"] = LangIndexOf(r.Lang);
            args["Version"] = r.Version;
            RunAction("runtime-install", args, "安装 " + r.Name + " " + r.Version);
        }

        private void SwitchSelected()
        {
            var r = Selected();
            if (r == null) { Log("[WARN] 先在列表里选一行"); return; }
            if (!r.Installed) { Log("[WARN] " + r.Name + " " + r.Version + " 还没装，先安装"); return; }
            if (r.Current) { Log("[INFO] " + r.Name + " " + r.Version + " 已经是当前版本"); return; }

            var args = new Dictionary<string, object>();
            args["Lang"] = LangIndexOf(r.Lang);
            args["Version"] = r.Version;
            Log("[STEP] 切换 " + r.Name + " current -> " + r.Version + "（只影响新开的命令行）");
            RunAction("runtime-switch", args, "切换 " + r.Name + " 到 " + r.Version);
        }

        private void UninstallSelected()
        {
            var r = Selected();
            if (r == null) { Log("[WARN] 先在列表里选一行"); return; }
            if (!r.Installed) { Log("[WARN] " + r.Name + " " + r.Version + " 本来就没装"); return; }

            string extra = r.Current ? "\r\n\r\n这是当前版本：会先摘掉 current，再指向剩下的最新版本。" : "";
            if (!Dialogs.Confirm(FindForm(), "卸载运行时",
                "删除 " + r.Name + " " + r.Version + " 的整个版本目录？" + extra, "删除")) return;

            var args = new Dictionary<string, object>();
            args["Lang"] = LangIndexOf(r.Lang);
            args["Version"] = r.Version;
            RunAction("runtime-remove", args, "卸载 " + r.Name + " " + r.Version);
        }

        private void RepairPath()
        {
            Log("[STEP] 重算机器 PATH 里的运行库条目");
            RunAction("runtime-path", new Dictionary<string, object>(), "修复 PATH");
        }

        private void OpenDir()
        {
            try
            {
                if (_root.Length == 0) { Log("[WARN] 还没读到运行库目录"); return; }
                Log("[INFO] 运行库目录：" + _root);
                if (!System.IO.Directory.Exists(_root))
                {
                    Log("[INFO] 目录还没建出来（装第一个运行时时会自动创建）");
                    return;
                }
                // Server Core 上 explorer.exe 可能起不来，失败就把路径留在日志里
                Process.Start("explorer.exe", "\"" + _root + "\"");
            }
            catch (Exception ex)
            {
                Log("[WARN] 打开资源管理器失败（Server Core 常见）：" + ex.Message);
            }
        }

        private static int LangIndexOf(string id)
        {
            int i;
            return LangIndex.TryGetValue(id, out i) ? i : 1;
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
                    Load(false);
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
}

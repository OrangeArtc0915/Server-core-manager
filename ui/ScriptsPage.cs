using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 脚本库：scripts\*.ps1 的元数据、预览与执行。
    // 执行走动作执行器（script-run），有任务记录与审计。
    // ============================================================
    internal sealed class ScriptsPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private string _root = "";
        private bool _busy;

        public ScriptsPage()
        {
            Key = "scripts";
            TitleText = "脚本库";
            Subtitle = "内置维护脚本：清理临时文件、收集诊断包、重置网络、磁盘检查、导出资产清单。运行前可预览，执行有审计。";
            Glyph = "tool";
            Accent = Theme.AccentOf("tool");
            CacheSeconds = 60;

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn("ID", 140));
            _table.Columns.Add(new DataColumn("名称", 170));
            _table.Columns.Add(new DataColumn("说明", 400));
            _table.Columns.Add(new DataColumn("风险", 70));
            _table.Columns.Add(new DataColumn("大小 KB", 80, true));
            _table.Columns.Add(new DataColumn("修改时间", 130));
            _table.RowActivated += idx => Preview();
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton("预览", ButtonKind.Primary, 80, Preview);
            AddButton("运行", ButtonKind.Normal, 80, RunScript);
            AddButton("打开目录", ButtonKind.Normal, 96, OpenFolder);
            AddButton("刷新", ButtonKind.Ghost, 72, Load);
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
            Load();
        }

        public void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState("读取中…", "Info");
            Bridge.Run(@"gui\Run-GuiReadyScripts.ps1", "list", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _root = Bridge.Str(data, "Root");
                        _items.Clear();
                        _items.AddRange(items);
                        var rows = new List<string[]>();
                        foreach (var it in items)
                        {
                            rows.Add(new[]
                            {
                                Bridge.Str(it, "Id"),
                                Bridge.Str(it, "Name"),
                                Bridge.Str(it, "Desc"),
                                Bridge.Str(it, "Risk"),
                                Bridge.Num(it, "SizeKB").ToString("0.0"),
                                Bridge.Str(it, "Modified")
                            });
                        }
                        _table.SetRows(rows);
                        SetState(rows.Count + " 个脚本", rows.Count > 0 ? "Info" : "Neutral");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 脚本库读取失败: " + err);
                }), 60000);
        }

        private Dictionary<string, object> Selected()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _items.Count) return null;
            return _items[idx];
        }

        private void Preview()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先选中一个脚本"); return; }
            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(it, "Id");
            args["Lines"] = 80;
            Bridge.Run(@"gui\Run-GuiReadyScripts.ps1", "preview", args,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    SafeInvoke(() => Dialogs.Text(FindForm(), "脚本预览 · " + Bridge.Str(data, "Name"),
                        "SHA256 " + Bridge.Str(data, "Sha256"), Bridge.Str(data, "Text")));
                },
                err => SafeInvoke(() => Log("[WARN] 预览失败: " + err)), 60000);
        }

        private void RunScript()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先选中一个脚本"); return; }
            string risk = Bridge.Str(it, "Risk");
            string warn = risk == "high"
                ? "这个脚本风险较高，可能会重置网络并需要重启。确定运行？"
                : "确定运行脚本「" + Bridge.Str(it, "Name") + "」？";
            if (!Dialogs.Confirm(FindForm(), "运行脚本", warn)) return;

            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(it, "Id");
            args["DryRun"] = false;
            Log("[STEP] 运行脚本 " + Bridge.Str(it, "Id"));
            bool started = Actions.RunAction("script-run", args,
                line => SafeInvoke(() => Log(line)),
                res => SafeInvoke(() =>
                {
                    Log((res.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "脚本结束，退出码 " + res.ExitCode +
                        "，用时 " + res.Seconds.ToString("0.0") + " 秒");
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] 脚本未启动: " + err)));
            if (!started) SetState("已有动作在跑", "Warn");
        }

        private void OpenFolder()
        {
            if (string.IsNullOrEmpty(_root) || !Directory.Exists(_root))
            {
                Log("[WARN] 脚本目录还不存在");
                return;
            }
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "\"" + _root + "\"",
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                Log("[WARN] 打开目录失败: " + ex.Message);
            }
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _actions.Left = 0;
            _actions.Width = Math.Max(200, w - 4);
            int bh = LayoutButtonRow(_buttons, _actions.Width, 0);
            _actions.Height = bh;
            _actions.Top = 72;

            _table.Left = 0;
            _table.Top = _actions.Top + bh + 6;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(110, ClientSize.Height - _table.Top - 18);
        }
    }
}

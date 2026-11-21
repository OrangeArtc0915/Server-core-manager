using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 报告中心：reports\ 下的性能报表 / 诊断包 / 导出文件，
    // 一键打包、发邮件（附件）、注册每日自动打包任务。
    // ============================================================
    internal sealed class ReportsPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private string _root = "";
        private bool _busy;

        public ReportsPage()
        {
            Key = "reports";
            TitleText = "报告中心";
            Subtitle = "性能报表、诊断包与各类导出统一在这里：打包成 ZIP、作为附件发送、或注册每日自动打包任务。";
            Glyph = "logs";
            Accent = Theme.AccentOf("logs");
            CacheSeconds = 30;

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn("文件", 340));
            _table.Columns.Add(new DataColumn("类型", 80));
            _table.Columns.Add(new DataColumn("大小 KB", 90, true));
            _table.Columns.Add(new DataColumn("修改时间", 150));
            _table.Columns.Add(new DataColumn("路径", 380));
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton("打包最近报表", ButtonKind.Primary, 116, Bundle);
            AddButton("发送…", ButtonKind.Normal, 82, SendReport);
            AddButton("每日任务…", ButtonKind.Normal, 96, InstallTask);
            AddButton("取消任务", ButtonKind.Danger, 88, RemoveTask);
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
            Bridge.Run(@"gui\Run-GuiReadyReports.ps1", "list", null,
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
                                Bridge.Str(it, "File"),
                                Bridge.Str(it, "Type"),
                                Bridge.Num(it, "SizeKB").ToString("0.0"),
                                Bridge.Str(it, "Time"),
                                Bridge.Str(it, "Path")
                            });
                        }
                        _table.SetRows(rows);
                        SetState(rows.Count + " 个报告文件", rows.Count > 0 ? "Info" : "Neutral");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 报告列表读取失败: " + err);
                }), 60000);
        }

        private void Bundle()
        {
            Log("[STEP] 打包最近的报表");
            Bridge.Run(@"gui\Run-GuiReadyReports.ps1", "bundle", null,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    string file = Bridge.Str(data, "File");
                    int count = (int)Bridge.Num(data, "Count");
                    double size = Bridge.Num(data, "SizeKB");
                    SafeInvoke(() =>
                    {
                        Log("[OK] 报告包已生成：" + file);
                        Dialogs.Text(FindForm(), "报告包",
                            count + " 个文件 · " + size.ToString("0.0") + " KB · SHA256 " + Bridge.Str(data, "Sha256"),
                            file, file);
                        Load();
                    });
                },
                err => SafeInvoke(() => Log("[WARN] 打包失败: " + err)), 180000);
        }

        private void SendReport()
        {
            var v = Dialogs.Prompt(FindForm(), "发送报告",
                "先打包最近的报表，再通过「通知」页配置的 SMTP 作为附件发出。",
                new List<PromptField>
                {
                    new PromptField("标题", "SCM 报告"),
                    new PromptField("说明", "报告包已生成", true)
                }, "发送", 520);
            if (v == null) return;
            if (!Dialogs.Confirm(FindForm(), "发送报告", "确定按当前通知配置发送报告邮件？")) return;
            var a = new Dictionary<string, object>();
            a["Title"] = v[0];
            a["Text"] = v[1];
            a["DryRun"] = false;
            RunAction("report-send", a, "发送报告");
        }

        private void InstallTask()
        {
            var v = Dialogs.Prompt(FindForm(), "每日报告任务",
                "每天定时打包最近报表（ScmPlus-Reports，SYSTEM 身份）。",
                new List<PromptField>
                {
                    new PromptField("每天时间（HH:mm）", "08:00"),
                    new PromptField("打包后发送邮件（是 / 否）", "否")
                }, "安装任务", 500);
            if (v == null) return;
            var a = new Dictionary<string, object>();
            a["Time"] = v[0];
            a["Send"] = v[1] == "是";
            RunAction("report-task-install", a, "安装每日报告任务");
        }

        private void RemoveTask()
        {
            if (!Dialogs.Confirm(FindForm(), "取消每日报告任务", "确定删除 ScmPlus-Reports 计划任务？")) return;
            RunAction("report-task-remove", null, "取消每日报告任务");
        }

        private void RunAction(string actionId, Dictionary<string, object> args, string label)
        {
            SetState(label + "…", "Info");
            bool started = Actions.RunAction(actionId, args,
                line => SafeInvoke(() => Log(line)),
                res => SafeInvoke(() =>
                {
                    Log((res.ExitCode == 0 ? "[OK] " : "[ERROR] ") + label + "结束，退出码 " + res.ExitCode +
                        "，用时 " + res.Seconds.ToString("0.0") + " 秒");
                    Load();
                }),
                err => SafeInvoke(() =>
                {
                    SetState("未启动", "Warn");
                    Log("[WARN] " + label + "未启动: " + err);
                }));
            if (!started) SetState("已有动作在跑", "Warn");
        }

        private void OpenFolder()
        {
            if (string.IsNullOrEmpty(_root) || !Directory.Exists(_root))
            {
                Log("[WARN] 报告目录还不存在");
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

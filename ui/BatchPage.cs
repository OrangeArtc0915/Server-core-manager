using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 批量管理：对「远程主机」里启用的主机做批量采集 / 执行 / 装包。
    // 结果显示最近一次批量任务；写操作走动作执行器。
    // ============================================================
    internal sealed class BatchPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private bool _busy;

        public BatchPage()
        {
            Key = "batch";
            TitleText = "批量管理";
            Subtitle = "对「远程主机」里启用的主机批量采集状态、执行命令或安装软件包；结果汇总在下方。";
            Glyph = "hosts";
            Accent = Theme.AccentOf("hosts");
            CacheSeconds = 30;

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn("主机", 160));
            _table.Columns.Add(new DataColumn("地址", 150));
            _table.Columns.Add(new DataColumn("状态", 90));
            _table.Columns.Add(new DataColumn("耗时(s)", 80, true));
            _table.Columns.Add(new DataColumn("结果", 500));
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton("批量采集", ButtonKind.Primary, 96, () => RunBatch("batch-collect", null, "批量采集"));
            AddButton("批量执行…", ButtonKind.Normal, 96, RunCommandDialog);
            AddButton("批量装包…", ButtonKind.Normal, 96, RunInstallDialog);
            AddButton("上传文件…", ButtonKind.Normal, 96, UploadDialog);
            AddButton("下载文件…", ButtonKind.Normal, 96, DownloadDialog);
            AddButton("分发脚本…", ButtonKind.Normal, 96, ScriptDialog);
            AddButton("主机清单", ButtonKind.Ghost, 90, ShowHosts);
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
            Bridge.Run(@"gui\Run-GuiReadyBatch.ps1", "last", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    if (items.Count > 0)
                    {
                        SafeInvoke(() =>
                        {
                            _busy = false;
                            Fill(items, data);
                        });
                        return;
                    }
                    // 还没有批量任务：退回到主机清单
                    Bridge.Run(@"gui\Run-GuiReadyBatch.ps1", "hosts", null,
                        h =>
                        {
                            var hosts = Bridge.List(h.ContainsKey("Items") ? h["Items"] : null);
                            SafeInvoke(() =>
                            {
                                _busy = false;
                                _items.Clear();
                                var rows = new List<string[]>();
                                foreach (var x in hosts)
                                {
                                    rows.Add(new[]
                                    {
                                        Bridge.Str(x, "Name"), Bridge.Str(x, "Address"),
                                        Bridge.Bool(x, "Enabled", true) ? "启用" : "停用", "", "尚未执行批量任务"
                                    });
                                }
                                _table.SetRows(rows);
                                SetState(rows.Count + " 台主机 · 尚未执行", "Neutral");
                            });
                        },
                        err => SafeInvoke(() =>
                        {
                            _busy = false;
                            SetState("读取失败", "Danger");
                            Log("[WARN] 主机清单读取失败: " + err);
                        }), 60000);
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 批量结果读取失败: " + err);
                }), 60000);
        }

        private void Fill(List<Dictionary<string, object>> items, Dictionary<string, object> data)
        {
            _items.Clear();
            _items.AddRange(items);
            var rows = new List<string[]>();
            foreach (var it in items)
            {
                string output = Bridge.Str(it, "Output");
                string error = Bridge.Str(it, "Error");
                string summary = output.Length > 0 ? output : error;
                summary = summary.Replace("\r", " ").Replace("\n", " ");
                if (summary.Length > 400) summary = summary.Substring(0, 400) + "…";
                rows.Add(new[]
                {
                    Bridge.Str(it, "Host"),
                    Bridge.Str(it, "Address"),
                    Bridge.Str(it, "Status"),
                    Bridge.Num(it, "DurationSec").ToString("0.0"),
                    summary
                });
            }
            _table.SetRows(rows);
            int total = (int)Bridge.Num(data, "Total", rows.Count);
            int ok = (int)Bridge.Num(data, "Succeeded");
            int fail = (int)Bridge.Num(data, "Failed");
            SetState(total + " 台 · 成功 " + ok + " / 失败 " + fail,
                     fail > 0 ? "Warn" : (total > 0 ? "Success" : "Neutral"));
            Log("[INFO] 批量任务 " + Bridge.Str(data, "TaskId") + "：" + total + " 台，成功 " + ok + "，失败 " + fail);
        }

        private void RunBatch(string actionId, Dictionary<string, object> args, string label)
        {
            Log("[STEP] " + label);
            bool started = Actions.RunAction(actionId, args,
                line => SafeInvoke(() => Log(line)),
                res => SafeInvoke(() =>
                {
                    Log((res.ExitCode == 0 ? "[OK] " : "[ERROR] ") + label + "结束，退出码 " + res.ExitCode +
                        "，用时 " + res.Seconds.ToString("0.0") + " 秒");
                    Load();
                }),
                err => SafeInvoke(() => Log("[WARN] " + label + "未启动: " + err)));
            if (!started) SetState("已有动作在跑", "Warn");
        }

        private void RunCommandDialog()
        {
            var v = Dialogs.Prompt(FindForm(), "批量执行命令",
                "在启用的远程主机上并发执行 PowerShell 命令。留空主机 = 全部启用主机。",
                new List<PromptField>
                {
                    new PromptField("主机（留空 = 全部启用）", ""),
                    new PromptField("命令", "", true),
                    new PromptField("超时（秒）", "120")
                }, "执行", 560);
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["HostSpec"] = v[0];
            args["Command"] = v[1];
            args["TimeoutSec"] = v[2];
            RunBatch("batch-exec", args, "批量执行");
        }

        private void RunInstallDialog()
        {
            var managers = new List<string> { "Chocolatey", "winget" };
            var v = Dialogs.Prompt(FindForm(), "批量安装软件包",
                "在启用的远程主机上安装指定包。留空主机 = 全部启用主机。",
                new List<PromptField>
                {
                    new PromptField("主机（留空 = 全部启用）", ""),
                    new PromptField("包名（如 7zip / Microsoft.PowerShell）", ""),
                    new PromptField("包管理器", managers[0], managers)
                }, "安装", 560);
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["HostSpec"] = v[0];
            args["Package"] = v[1];
            args["Manager"] = Math.Max(0, managers.IndexOf(v[2])) + 1;
            RunBatch("batch-install", args, "批量装包");
        }

        private void UploadDialog()
        {
            var v = Dialogs.Prompt(FindForm(), "批量上传文件",
                "把本机文件复制到远程主机的指定目录（经 SMB 管理共享）。",
                new List<PromptField>
                {
                    new PromptField("主机（留空 = 全部启用）", ""),
                    new PromptField("本地文件", ""),
                    new PromptField("远程目录", @"C:\Windows\Temp")
                }, "上传", 560);
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["HostSpec"] = v[0];
            args["LocalPath"] = v[1];
            args["RemotePath"] = v[2];
            RunBatch("batch-upload", args, "批量上传");
        }

        private void DownloadDialog()
        {
            var v = Dialogs.Prompt(FindForm(), "批量下载文件",
                "从远程主机复制指定文件到本机目录（留空目录 = reports\batch）。",
                new List<PromptField>
                {
                    new PromptField("主机（留空 = 全部启用）", ""),
                    new PromptField("远程文件路径", ""),
                    new PromptField("本地目录（可空）", "")
                }, "下载", 560);
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["HostSpec"] = v[0];
            args["RemotePath"] = v[1];
            args["OutDir"] = v[2];
            RunBatch("batch-download", args, "批量下载");
        }

        private void ScriptDialog()
        {
            var v = Dialogs.Prompt(FindForm(), "批量分发脚本",
                "把本地 PowerShell 脚本上传到远程临时目录并执行，回传输出。",
                new List<PromptField>
                {
                    new PromptField("主机（留空 = 全部启用）", ""),
                    new PromptField("本地脚本", ""),
                    new PromptField("超时（秒）", "300")
                }, "执行", 560);
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["HostSpec"] = v[0];
            args["LocalScript"] = v[1];
            args["TimeoutSec"] = v[2];
            RunBatch("batch-script", args, "批量分发脚本");
        }

        private void ShowHosts()
        {
            Bridge.Run(@"gui\Run-GuiReadyBatch.ps1", "hosts", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        var sb = new System.Text.StringBuilder();
                        foreach (var it in items)
                            sb.AppendLine((Bridge.Bool(it, "Enabled", true) ? "[启用] " : "[停用] ") +
                                          Bridge.Str(it, "Name") + "  " + Bridge.Str(it, "Address"));
                        Dialogs.Text(FindForm(), "远程主机", "在「远程主机」页维护主机清单。",
                                     sb.Length == 0 ? "还没有配置远程主机。" : sb.ToString());
                    });
                },
                err => SafeInvoke(() => Log("[WARN] 主机清单读取失败: " + err)), 60000);
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

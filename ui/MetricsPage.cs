using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 监控告警：性能历史 / 告警规则 / 事件订阅。
    // 读走 Run-GuiReadyMetrics.ps1，写走动作执行器（有审计）。
    // ============================================================
    internal sealed class MetricsPage : SysPage
    {
        protected override string RunnerScript { get { return @"gui\Run-GuiReadyMetrics.ps1"; } }

        public MetricsPage()
            : base("metrics", "监控告警", "性能历史采样、阈值 / 事件告警与关键事件订阅；规则触发后可发通知或自动执行动作。", "monitor")
        {
            AddTab("overview", "概览", 84);
            AddTab("rules", "规则", 84);
            AddTab("events", "事件", 84);

            AddBtn("overview", "采样一次", ButtonKind.Primary, 96, () => RunAction("metrics-sample", null, "采样"));
            AddBtn("overview", "生成报表", ButtonKind.Normal, 92, Report);
            AddBtn("overview", "维护窗口…", ButtonKind.Normal, 100, StartMaintenance);
            AddBtn("overview", "结束维护", ButtonKind.Ghost, 96, () => RunAction("maintenance-stop", null, "结束维护"));
            AddBtn("overview", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBtn("rules", "添加规则…", ButtonKind.Primary, 106, AddRule);
            AddBtn("rules", "启用/停用", ButtonKind.Normal, 96, ToggleRule);
            AddBtn("rules", "删除", ButtonKind.Danger, 72, RemoveRule);
            AddBtn("rules", "立即检查", ButtonKind.Normal, 96, () => RunAction("alert-check", null, "检查告警"));
            AddBtn("rules", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBtn("events", "刷新", ButtonKind.Ghost, 72, () => Load());
            AddBtn("events", "订阅提醒", ButtonKind.Normal, 96, () => RunAction("event-subscribe", IntervalArgs(2), "订阅事件"));
            AddBtn("events", "取消订阅", ButtonKind.Ghost, 96, () => RunAction("event-unsubscribe", null, "取消订阅"));

            SetView("overview");
        }

        private static Dictionary<string, object> IntervalArgs(int minutes)
        {
            var a = new Dictionary<string, object>();
            a["IntervalMin"] = minutes.ToString();
            return a;
        }

        protected override void BuildColumns()
        {
            switch (ViewKey)
            {
                case "rules":
                    AddCol("规则名称", 210);
                    AddCol("指标", 100);
                    AddCol("条件", 90);
                    AddCol("持续", 80, true);
                    AddCol("冷却", 80, true);
                    AddCol("动作", 170);
                    AddCol("状态", 70);
                    break;
                case "events":
                    AddCol("时间", 150);
                    AddCol("日志", 90);
                    AddCol("来源", 180);
                    AddCol("ID", 70, true);
                    AddCol("级别", 80);
                    AddCol("消息", 420);
                    break;
                default:
                    AddCol("时间", 160);
                    AddCol("CPU %", 80, true);
                    AddCol("内存 %", 80, true);
                    AddCol("系统盘可用 GB", 120, true);
                    AddCol("进程数", 80, true);
                    AddCol("入站 KB/s", 100, true);
                    AddCol("出站 KB/s", 100, true);
                    break;
            }
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            switch (ViewKey)
            {
                case "rules":
                    return new[]
                    {
                        Bridge.Str(d, "Name"),
                        Bridge.Str(d, "Metric"),
                        Bridge.Str(d, "Operator") + " " + Bridge.Str(d, "Threshold"),
                        Bridge.Str(d, "DurationMin") + " 分",
                        Bridge.Str(d, "CooldownMin") + " 分",
                        ActionText(d),
                        Bridge.Bool(d, "Enabled") ? "启用" : "停用"
                    };
                case "events":
                    return new[]
                    {
                        Bridge.Str(d, "Time"),
                        Bridge.Str(d, "Log"),
                        Bridge.Str(d, "Provider"),
                        Bridge.Str(d, "Id"),
                        Bridge.Str(d, "Level"),
                        Bridge.Str(d, "Message")
                    };
                default:
                    return new[]
                    {
                        Bridge.Str(d, "Time"),
                        Bridge.Num(d, "CpuPct").ToString("0.0"),
                        Bridge.Num(d, "MemPct").ToString("0.0"),
                        Bridge.Num(d, "DiskFreeGB").ToString("0.0"),
                        Bridge.Str(d, "ProcCount"),
                        Bridge.Num(d, "NetInKB").ToString("0.0"),
                        Bridge.Num(d, "NetOutKB").ToString("0.0")
                    };
            }
        }

        private static string ActionText(Dictionary<string, object> d)
        {
            string act = Bridge.Str(d, "Action");
            string id = Bridge.Str(d, "ActionId");
            if (act == "action") return "执行 " + id;
            if (act == "none") return "不通知";
            return "通知";
        }

        protected override void Load()
        {
            if (ViewKey == "rules")
                RunList("alert-list", null, 60000);
            else if (ViewKey == "events")
            {
                var a = new Dictionary<string, object>();
                a["Hours"] = 24;
                RunList("event-recent", a, 60000);
            }
            else
            {
                var a = new Dictionary<string, object>();
                a["Days"] = 1;
                RunList("history", a, 60000);
            }
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            if (ViewKey == "rules")
            {
                SetSum(Items.Count + " 条规则", Items.Count > 0 ? "Info" : "Neutral");
                return;
            }
            if (ViewKey == "events")
            {
                SetSum(Items.Count + " 条关键事件（24h）", Items.Count > 0 ? "Warn" : "Success");
                return;
            }
            var sum = Bridge.Dict(data != null && data.ContainsKey("Summary") ? data["Summary"] : null);
            int n = (int)Bridge.Num(sum, "Count");
            if (n == 0)
            {
                SetSum("还没有样本 · 点「采样一次」", "Neutral");
                return;
            }
            SetSum(n + " 条 · CPU 峰值 " + Bridge.Num(sum, "CpuMax").ToString("0.0") +
                   "% · 内存峰值 " + Bridge.Num(sum, "MemMax").ToString("0.0") + "%",
                   "Info");
        }

        private void Report()
        {
            var a = new Dictionary<string, object>();
            a["Days"] = 7;
            Log("[STEP] 生成最近 7 天的性能报表");
            Bridge.Run(RunnerScript, "report", a,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    string file = Bridge.Str(data, "File");
                    SafeInvoke(() =>
                    {
                        Log("[OK] 报表已生成：" + file);
                        Dialogs.Text(FindForm(), "性能报表", "已生成 HTML 报表，可直接打开：", file, file);
                    });
                },
                err => SafeInvoke(() => Log("[WARN] 生成报表失败: " + err)), 120000);
        }

        private void StartMaintenance()
        {
            var v = Dialogs.Prompt(FindForm(), "维护窗口",
                "维护窗口内告警检查会被静默（不触发通知 / 动作），窗口结束后自动恢复。",
                new List<PromptField>
                {
                    new PromptField("时长（分钟）", "60"),
                    new PromptField("原因", "维护窗口")
                }, "开始", 480);
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["Minutes"] = v[0];
            args["Reason"] = v[1];
            RunAction("maintenance-start", args, "开始维护窗口");
        }

        private void AddRule()
        {
            var metrics = new List<string> { "CPU %", "内存 %", "系统盘可用 GB", "系统盘使用率 %", "事件日志" };
            var ops = new List<string> { "大于 gt", "小于 lt" };
            var fields = new List<PromptField>
            {
                new PromptField("规则名称", ""),
                new PromptField("指标", metrics[0], metrics),
                new PromptField("条件", ops[0], ops),
                new PromptField("阈值", "90"),
                new PromptField("持续分钟", "5"),
                new PromptField("事件 ID（事件规则用，逗号分隔）", ""),
                new PromptField("冷却分钟", "30"),
                new PromptField("触发动作 ID（留空 = 仅通知）", "")
            };
            var v = Dialogs.Prompt(FindForm(), "添加告警规则",
                "指标规则按持续时间和阈值触发；事件规则按事件 ID 触发。", fields, "添加", 540);
            if (v == null) return;

            int mi = Math.Max(0, metrics.IndexOf(v[1]));
            int oi = Math.Max(0, ops.IndexOf(v[2]));
            var args = new Dictionary<string, object>();
            args["Name"] = v[0];
            args["Metric"] = mi + 1;
            args["Operator"] = oi + 1;
            args["Threshold"] = v[3];
            args["DurationMin"] = v[4];
            args["EventId"] = v[5];
            args["CooldownMin"] = v[6];
            args["ActionId"] = v[7];
            RunAction("alert-rule-add", args, "添加规则");
        }

        private void ToggleRule()
        {
            var it = NeedSelected();
            if (it == null) return;
            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(it, "Id");
            args["Enabled"] = !Bridge.Bool(it, "Enabled", true);
            RunAction("alert-rule-toggle", args, "切换规则");
        }

        private void RemoveRule()
        {
            var it = NeedSelected();
            if (it == null) return;
            if (!Dialogs.Confirm(FindForm(), "删除规则", "确定删除规则「" + Bridge.Str(it, "Name") + "」？")) return;
            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(it, "Id");
            RunAction("alert-rule-remove", args, "删除规则");
        }
    }
}

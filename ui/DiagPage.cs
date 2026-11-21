using System;
using System.Collections.Generic;
using System.Text;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 诊断工具：网络（监听端口 / 扫描 / DNS / 连通性 / 代理 / 抓包）
    // 与进程（列表 / 树 / 详情 / 快照 / 结束）。
    // 读走 Run-GuiReadyDiag.ps1，写走动作执行器（有审计）。
    // ============================================================
    internal sealed class DiagPage : SysPage
    {
        protected override string RunnerScript { get { return @"gui\Run-GuiReadyDiag.ps1"; } }

        public DiagPage()
            : base("diag", "诊断工具", "网络端口 / DNS / 连通性 / pktmon 抓包，以及进程、端口占用与历史快照；写操作走动作执行器。", "network")
        {
            AddTab("net", "网络", 84);
            AddTab("proc", "进程", 84);
            AddTab("hist", "快照历史", 96);

            AddBtn("net", "端口扫描…", ButtonKind.Primary, 100, ScanDialog);
            AddBtn("net", "DNS 解析…", ButtonKind.Normal, 96, DnsDialog);
            AddBtn("net", "连通性…", ButtonKind.Normal, 88, ConnectivityDialog);
            AddBtn("net", "代理信息", ButtonKind.Normal, 88, ShowProxy);
            AddBtn("net", "抓包…", ButtonKind.Normal, 78, CaptureDialog);
            AddBtn("net", "停止抓包", ButtonKind.Ghost, 88, StopCapture);
            AddBtn("net", "抓包文件", ButtonKind.Ghost, 88, ShowCaptures);
            AddBtn("net", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBtn("proc", "详情", ButtonKind.Primary, 72, Detail);
            AddBtn("proc", "进程树", ButtonKind.Normal, 84, Tree);
            AddBtn("proc", "快照", ButtonKind.Normal, 72, Snapshot);
            AddBtn("proc", "结束进程…", ButtonKind.Danger, 104, KillDialog);
            AddBtn("proc", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBtn("hist", "刷新", ButtonKind.Ghost, 72, () => Load());

            Table.RowActivated += idx => { if (ViewKey == "proc") Detail(); };

            SetView("net");
        }

        protected override void BuildColumns()
        {
            switch (ViewKey)
            {
                case "proc":
                    AddCol("PID", 70, true);
                    AddCol("进程", 170);
                    AddCol("CPU 秒", 80, true);
                    AddCol("内存 MB", 90, true);
                    AddCol("会话", 60, true);
                    AddCol("服务", 160);
                    AddCol("监听端口", 150);
                    AddCol("命令行", 300);
                    break;
                case "hist":
                    AddCol("时间", 150);
                    AddCol("PID", 70, true);
                    AddCol("进程", 170);
                    AddCol("CPU 秒", 80, true);
                    AddCol("内存 MB", 90, true);
                    AddCol("命令行", 420);
                    break;
                default:
                    AddCol("协议", 70);
                    AddCol("本地地址", 190);
                    AddCol("端口", 80, true);
                    AddCol("PID", 80, true);
                    AddCol("进程", 190);
                    break;
            }
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            switch (ViewKey)
            {
                case "proc":
                    return new[]
                    {
                        Bridge.Str(d, "Id"),
                        Bridge.Str(d, "Name"),
                        Bridge.Num(d, "CpuSec").ToString("0.0"),
                        Bridge.Num(d, "MemMB").ToString("0.0"),
                        Bridge.Str(d, "Session"),
                        Bridge.Str(d, "Services"),
                        Bridge.Str(d, "Ports"),
                        Bridge.Str(d, "CommandLine")
                    };
                case "hist":
                    return new[]
                    {
                        Bridge.Str(d, "Time"),
                        Bridge.Str(d, "Id"),
                        Bridge.Str(d, "Name"),
                        Bridge.Num(d, "CpuSec").ToString("0.0"),
                        Bridge.Num(d, "MemMB").ToString("0.0"),
                        Bridge.Str(d, "CommandLine")
                    };
                default:
                    return new[]
                    {
                        Bridge.Str(d, "Protocol"),
                        Bridge.Str(d, "Address"),
                        Bridge.Str(d, "Port"),
                        Bridge.Str(d, "PID"),
                        Bridge.Str(d, "Process")
                    };
            }
        }

        protected override void Load()
        {
            if (ViewKey == "proc")
            {
                var a = new Dictionary<string, object>();
                a["Top"] = 120;
                RunList("proc-list", a, 90000);
            }
            else if (ViewKey == "hist")
            {
                var a = new Dictionary<string, object>();
                a["Days"] = 7;
                RunList("proc-history", a, 60000);
            }
            else RunList("listening", null, 60000);
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            if (ViewKey == "proc") SetSum(Items.Count + " 个进程（按 CPU / 内存排序）", Items.Count > 0 ? "Info" : "Neutral");
            else if (ViewKey == "hist") SetSum(Items.Count + " 条进程快照（最近 7 天）", Items.Count > 0 ? "Info" : "Neutral");
            else SetSum(Items.Count + " 个监听端口", Items.Count > 0 ? "Success" : "Neutral");
        }

        // ---------------------------------------------------------- 网络
        private void ScanDialog()
        {
            var v = Dialogs.Prompt(FindForm(), "端口扫描",
                "TCP 连接探测；端口支持逗号与范围（如 80,443,1000-1010），最多 500 个。",
                new List<PromptField>
                {
                    new PromptField("目标主机 / IP", "127.0.0.1"),
                    new PromptField("端口", "80,443,3389"),
                    new PromptField("超时（毫秒）", "800")
                }, "开始扫描", 520);
            if (v == null) return;
            var a = new Dictionary<string, object>();
            a["Target"] = v[0];
            a["Ports"] = v[1];
            a["TimeoutMs"] = v[2];
            ShowText("scan", a, "端口扫描 · " + v[0], (items, data) =>
            {
                var sb = new StringBuilder();
                int open = 0;
                foreach (var it in items)
                {
                    bool o = Bridge.Bool(it, "Open");
                    if (o) open++;
                    sb.AppendLine((o ? "[开放] " : "[关闭] ") + Bridge.Str(it, "Port") + "  " +
                                  Bridge.Num(it, "LatencyMs").ToString("0") + " ms" +
                                  (Bridge.Str(it, "Process").Length > 0
                                      ? "  " + Bridge.Str(it, "Process") + " (" + Bridge.Str(it, "PID") + ")"
                                      : ""));
                }
                sb.Insert(0, "目标 " + Bridge.Str(data, "Target") + "：开放 " + open + " / " + items.Count + "\r\n\r\n");
                return sb.ToString();
            }, 120000);
        }

        private void DnsDialog()
        {
            var v = Dialogs.Prompt(FindForm(), "DNS 解析",
                "留空 DNS 服务器 = 用系统当前 DNS。",
                new List<PromptField>
                {
                    new PromptField("域名 / 主机名", ""),
                    new PromptField("DNS 服务器（可空）", "")
                }, "解析", 480);
            if (v == null) return;
            var a = new Dictionary<string, object>();
            a["Name"] = v[0];
            a["Server"] = v[1];
            ShowText("dns", a, "DNS 解析 · " + v[0], (items, data) =>
            {
                var sb = new StringBuilder();
                foreach (var it in items)
                    sb.AppendLine(Bridge.Str(it, "Type") + "\t" + Bridge.Str(it, "Value") + "\tTTL " + Bridge.Str(it, "TTL"));
                return sb.Length == 0 ? "没有解析结果。" : sb.ToString();
            }, 60000);
        }

        private void ConnectivityDialog()
        {
            var v = Dialogs.Prompt(FindForm(), "连通性测试",
                "每项写成 host:port 走 TCP 探测；只写 host 时用 ICMP。",
                new List<PromptField>
                {
                    new PromptField("目标列表（逗号分隔）", "127.0.0.1:445"),
                }, "测试", 520);
            if (v == null) return;
            var a = new Dictionary<string, object>();
            a["Targets"] = v[0];
            ShowText("connectivity", a, "连通性测试", (items, data) =>
            {
                var sb = new StringBuilder();
                foreach (var it in items)
                    sb.AppendLine((Bridge.Bool(it, "Ok") ? "[通] " : "[不通] ") + Bridge.Str(it, "Target") +
                                  "  " + Bridge.Num(it, "LatencyMs").ToString("0") + " ms");
                return sb.Length == 0 ? "没有目标。" : sb.ToString();
            }, 90000);
        }

        private void ShowProxy()
        {
            ShowText("proxy", null, "代理设置", (items, data) => Bridge.Str(data, "Text"), 30000);
        }

        private void CaptureDialog()
        {
            var v = Dialogs.Prompt(FindForm(), "抓包",
                "用系统自带 pktmon 抓包并转换成 pcapng（需要 Windows Server 2019+）。抓包期间界面会等待。",
                new List<PromptField>
                {
                    new PromptField("时长（秒，3-300）", "30")
                }, "开始抓包", 480);
            if (v == null) return;
            var a = new Dictionary<string, object>();
            a["Seconds"] = v[0];
            RunAction("netdiag-capture", a, "抓包");
        }

        private void StopCapture()
        {
            RunAction("netdiag-capture-stop", null, "停止抓包");
        }

        private void ShowCaptures()
        {
            ShowText("captures", null, "抓包文件", (items, data) =>
            {
                var sb = new StringBuilder();
                foreach (var it in items)
                    sb.AppendLine(Bridge.Str(it, "Time") + "  " + Bridge.Str(it, "File") +
                                  "  " + Bridge.Num(it, "SizeMB").ToString("0.00") + " MB");
                return sb.Length == 0 ? "还没有抓包文件。" : sb.ToString();
            }, 30000);
        }

        // ---------------------------------------------------------- 进程
        private void Detail()
        {
            var it = NeedSelected();
            if (it == null) return;
            var a = new Dictionary<string, object>();
            a["Id"] = Bridge.Str(it, "Id");
            ShowText("proc-detail", a, "进程详情 · " + Bridge.Str(it, "Name"), (items, data) =>
            {
                var sb = new StringBuilder();
                sb.AppendLine("PID：" + Bridge.Str(data, "Id"));
                sb.AppendLine("名称：" + Bridge.Str(data, "Name"));
                sb.AppendLine("父进程：" + Bridge.Str(data, "ParentId"));
                sb.AppendLine("启动时间：" + Bridge.Str(data, "StartTime"));
                sb.AppendLine("CPU 秒：" + Bridge.Num(data, "CpuSec").ToString("0.0"));
                sb.AppendLine("内存 MB：" + Bridge.Num(data, "MemMB").ToString("0.0"));
                sb.AppendLine("线程 / 句柄：" + Bridge.Str(data, "Threads") + " / " + Bridge.Str(data, "Handles"));
                sb.AppendLine("服务：" + Bridge.Str(data, "Services"));
                sb.AppendLine("端口：" + Bridge.Str(data, "Ports"));
                sb.AppendLine("可执行文件：" + Bridge.Str(data, "ExecutablePath"));
                sb.AppendLine();
                sb.AppendLine("命令行：");
                sb.AppendLine(Bridge.Str(data, "CommandLine"));
                return sb.ToString();
            }, 60000);
        }

        private void Tree()
        {
            ShowText("proc-tree", null, "进程树", (items, data) =>
            {
                var sb = new StringBuilder();
                foreach (var it in items) sb.AppendLine(Bridge.Str(it, "Text"));
                return sb.ToString();
            }, 90000);
        }

        private void Snapshot()
        {
            RunAction("proc-snapshot", null, "记录进程快照");
        }

        private void KillDialog()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            string pid = Bridge.Str(it, "Id");
            if (!Dialogs.Confirm(FindForm(), "结束进程",
                    "确定结束进程「" + name + "」(" + pid + ")？未保存的数据会丢失。", "结束进程")) return;
            var a = new Dictionary<string, object>();
            a["Id"] = pid;
            a["DryRun"] = false;
            RunAction("proc-kill", a, "结束进程 " + name);
        }
    }
}

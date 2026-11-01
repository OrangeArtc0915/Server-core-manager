using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.ServiceProcess;
using System.Threading;

namespace ScmUi
{
    // ============================================================
    // 快照采样（进程内）：关键服务 / 最近系统事件 / 占内存最多的进程。
    // 以前这三块走 Run-GuiReadyMonitor.ps1 -Mode snapshot，每次进页面或每 60 秒
    // 起一个 powershell.exe（约 1.5 秒 CPU、100MB 峰值）。这里用
    // ServiceController / EventLogReader / Process 直接取，约 100ms，
    // 而且不产生子进程。任一环节异常时调用方回退到 runner。
    // ============================================================
    internal sealed class SnapshotSample
    {
        public readonly List<Dictionary<string, object>> Services = new List<Dictionary<string, object>>();
        public readonly List<Dictionary<string, object>> Events = new List<Dictionary<string, object>>();
        public readonly List<Dictionary<string, object>> Processes = new List<Dictionary<string, object>>();
    }

    internal static class Snapshot
    {
        // 关键服务（与 PowerShell 版同一份清单：本机没有的直接跳过）
        private static readonly string[,] Want =
        {
            { "EventLog", "事件日志" },
            { "RpcSs", "远程过程调用" },
            { "Dnscache", "DNS 客户端" },
            { "LanmanServer", "文件共享服务端" },
            { "LanmanWorkstation", "文件共享客户端" },
            { "WinRM", "远程管理（PowerShell Remoting）" },
            { "TermService", "远程桌面" },
            { "W32Time", "时间同步" },
            { "WindowsAdminCenter", "Windows Admin Center" }
        };

        public static void LoadAsync(int eventCount, int topProcess,
                                     Action<SnapshotSample> done, Action<string> fail)
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    var s = new SnapshotSample();
                    CollectServices(s);
                    CollectEvents(s, eventCount);
                    CollectProcesses(s, topProcess);
                    if (done != null) done(s);
                }
                catch (Exception ex)
                {
                    if (fail != null) fail(ex.Message);
                }
            });
        }

        private static void CollectServices(SnapshotSample s)
        {
            int n = Want.GetLength(0);
            for (int i = 0; i < n; i++)
            {
                string name = Want[i, 0];
                string why = Want[i, 1];
                try
                {
                    using (var sc = new ServiceController(name))
                    {
                        var d = new Dictionary<string, object>();
                        d["Name"] = name;
                        d["Display"] = sc.DisplayName;
                        d["Why"] = why;
                        d["Status"] = sc.Status.ToString();
                        d["Start"] = sc.StartType.ToString();
                        s.Services.Add(d);
                    }
                }
                catch
                {
                    // 本机没有这个服务（Server Core 上很常见），跳过，不算异常
                }
            }
        }

        private static void CollectEvents(SnapshotSample s, int count)
        {
            // XPath：System 日志里 Level 1（错误）/ 2（警告）
            var q = new EventLogQuery("System", PathType.LogName, "*[System[(Level=1 or Level=2)]]");
            q.TolerateQueryErrors = true;
            using (var reader = new EventLogReader(q))
            {
                for (int i = 0; i < count; i++)
                {
                    EventRecord rec = reader.ReadEvent();
                    if (rec == null) break;
                    try
                    {
                        string msg = "";
                        try { msg = rec.FormatDescription() ?? ""; } catch { }
                        msg = msg.Replace("\r", " ").Replace("\n", " ").Trim();
                        while (msg.IndexOf("  ", StringComparison.Ordinal) >= 0)
                            msg = msg.Replace("  ", " ");
                        if (msg.Length > 200) msg = msg.Substring(0, 200) + " …";

                        string level = "";
                        try { level = rec.LevelDisplayName; } catch { }
                        if (string.IsNullOrEmpty(level)) level = rec.Level == 1 ? "错误" : "警告";

                        var d = new Dictionary<string, object>();
                        d["Time"] = rec.TimeCreated.HasValue
                            ? rec.TimeCreated.Value.ToString("MM-dd HH:mm:ss") : "";
                        d["Level"] = level;
                        d["Provider"] = rec.ProviderName ?? "";
                        d["Id"] = rec.Id;
                        d["Message"] = msg;
                        s.Events.Add(d);
                    }
                    finally
                    {
                        rec.Dispose();
                    }
                }
            }
        }

        private static void CollectProcesses(SnapshotSample s, int top)
        {
            var all = new List<Process>();
            try
            {
                foreach (var p in Process.GetProcesses())
                {
                    try
                    {
                        long ws = p.WorkingSet64;   // 访问不到的进程会在这里抛
                        all.Add(p);
                    }
                    catch
                    {
                        try { p.Dispose(); } catch { }
                    }
                }
                all.Sort((a, b) =>
                {
                    try { return b.WorkingSet64.CompareTo(a.WorkingSet64); }
                    catch { return 0; }
                });

                int n = Math.Min(top, all.Count);
                for (int i = 0; i < n; i++)
                {
                    var p = all[i];
                    var d = new Dictionary<string, object>();
                    d["Name"] = p.ProcessName;
                    d["Id"] = p.Id;
                    try { d["MemMB"] = Math.Round(p.WorkingSet64 / 1048576.0, 1); }
                    catch { d["MemMB"] = 0; }
                    d["CpuSec"] = -1;      // 进程 CPU 时间要计数器/子进程，这里不给假值
                    s.Processes.Add(d);
                }
            }
            finally
            {
                foreach (var p in all) { try { p.Dispose(); } catch { } }
            }
        }
    }
}

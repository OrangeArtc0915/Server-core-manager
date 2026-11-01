using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace ScmUi
{
    internal sealed class ActionRunResult
    {
        public string ActionId = "";
        public string JobId = "";
        public string LogPath = "";
        public int ExitCode = -1;
        public double Seconds;
    }

    // ============================================================
    // 动作层：界面只负责“点一下”，真正的系统改动仍由 Run-GuiReadyAction.ps1 在子进程里做。
    // 这里补上 PowerShell 版 GUI 已经有的三件事：
    //   1. 任务编号（先给界面看，进程启动后用同一个编号落盘）
    //   2. 边跑边把日志尾部喂回主界面的运行日志栏（不读整个文件，只增量读新字节）
    //   3. 取消（taskkill /T 连子进程一起收掉）
    // 同一时间只允许一个动作 —— 和 PowerShell 版一致，避免两个动作同时改系统。
    // ============================================================
    internal static class Actions
    {
        private sealed class Run
        {
            public Process Proc;
            public ActionRunResult Result;
            public string TempDir;
            public DateTime Start;
            public bool Canceled;
        }

        private static readonly object Gate = new object();
        private static Run _run;

        // 后台线程触发；订阅方自己切回 UI 线程
        public static event Action Changed;

        public static bool Busy
        {
            get { lock (Gate) return _run != null; }
        }

        public static string CurrentId
        {
            get { lock (Gate) return _run == null ? "" : _run.Result.ActionId; }
        }

        public static string CurrentJobId
        {
            get { lock (Gate) return _run == null ? "" : _run.Result.JobId; }
        }

        // 返回 false 表示已有动作在跑（调用方应提示用户）
        public static bool RunAction(string actionId, Dictionary<string, object> args,
                                     Action<string> onLine, Action<ActionRunResult> onDone,
                                     Action<string> onFail, string retryOf = "")
        {
            string busyId;
            lock (Gate) busyId = _run == null ? null : _run.Result.ActionId;
            if (busyId != null)
            {
                if (onFail != null) onFail("已有动作在运行：" + busyId);
                return false;
            }

            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            string jobId = "task-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff");
            string root = Bridge.Root;
            string logDir = Path.Combine(root, "logs");
            string tempDir = Path.Combine(Path.GetTempPath(), "scm-ui-action-" + stamp + "-" +
                                          Guid.NewGuid().ToString("N").Substring(0, 5));
            var result = new ActionRunResult
            {
                ActionId = actionId,
                JobId = jobId,
                LogPath = Path.Combine(logDir, "gui-" + actionId + "-" + stamp + ".log")
            };

            Run run = null;
            try
            {
                Directory.CreateDirectory(logDir);
                Directory.CreateDirectory(tempDir);
                string argsFile = Path.Combine(tempDir, "args.json");
                string json = "{}";
                if (args != null && args.Count > 0)
                    json = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(args);
                File.WriteAllText(argsFile, json, new UTF8Encoding(true));

                var sb = new StringBuilder();
                sb.Append("-NoProfile -ExecutionPolicy Bypass -File \"")
                  .Append(Path.Combine(root, @"gui\Run-GuiReadyAction.ps1")).Append('"');
                sb.Append(" -Action ").Append(actionId);
                sb.Append(" -ArgsFile \"").Append(argsFile).Append('"');
                sb.Append(" -LogFile \"").Append(result.LogPath).Append('"');
                sb.Append(" -JobId ").Append(jobId);
                if (!string.IsNullOrEmpty(retryOf)) sb.Append(" -RetryOf ").Append(retryOf);

                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = sb.ToString(),
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    WorkingDirectory = root
                };

                var proc = Process.Start(psi);
                if (proc == null) throw new Exception("无法启动动作进程");

                run = new Run
                {
                    Proc = proc,
                    Result = result,
                    TempDir = tempDir,
                    Start = DateTime.Now
                };
                lock (Gate)
                {
                    if (_run != null)
                    {
                        try { proc.Kill(); } catch { }
                        throw new Exception("已有动作在运行：" + _run.Result.ActionId);
                    }
                    _run = run;
                }
            }
            catch (Exception ex)
            {
                try { Directory.Delete(tempDir, true); } catch { }
                if (onFail != null) onFail(ex.Message);
                return false;
            }

            Raise();
            ThreadPool.QueueUserWorkItem(_ => Pump(run, onLine, onDone, onFail));
            return true;
        }

        // 后台线程：增量读日志 + 等进程退出
        private static void Pump(Run run, Action<string> onLine, Action<ActionRunResult> onDone,
                                 Action<string> onFail)
        {
            if (run == null) return;

            long pos = 0;
            var pending = new StringBuilder();
            string error = "";
            try
            {
                while (true)
                {
                    bool exited;
                    try { exited = run.Proc.HasExited; }
                    catch { exited = true; }
                    pos = ReadNewLines(run.Result.LogPath, pos, pending, onLine);
                    if (exited) break;
                    Thread.Sleep(140);
                }
                try { run.Proc.WaitForExit(); } catch { }
                ReadNewLines(run.Result.LogPath, pos, pending, onLine);
                if (pending.Length > 0) { Emit(onLine, pending.ToString()); pending.Length = 0; }

                try { run.Result.ExitCode = run.Proc.ExitCode; }
                catch { run.Result.ExitCode = -1; }
                run.Result.Seconds = (DateTime.Now - run.Start).TotalSeconds;
            }
            catch (Exception ex)
            {
                error = ex.Message;
            }
            finally
            {
                try { run.Proc.Dispose(); } catch { }
                lock (Gate) { _run = null; }
                try { Directory.Delete(run.TempDir, true); } catch { }
                Raise();
            }

            if (error.Length > 0)
            {
                if (onFail != null) onFail(error);
                return;
            }
            if (onDone != null) onDone(run.Result);
        }

        // 从上次位置继续读，按行回调；不完整的最后一行留在 pending 里等下一次
        private static long ReadNewLines(string path, long pos, StringBuilder pending, Action<string> onLine)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return pos;
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    if (fs.Length <= pos) return pos;
                    fs.Position = pos;
                    int take = (int)Math.Min(fs.Length - pos, 4 * 1024 * 1024);
                    var buf = new byte[take];
                    int read = fs.Read(buf, 0, take);
                    if (read <= 0) return pos;
                    pending.Append(Encoding.UTF8.GetString(buf, 0, read));
                    pos += read;
                }
            }
            catch { return pos; }

            string all = pending.ToString();
            int start = 0;
            for (int i = 0; i < all.Length; i++)
            {
                if (all[i] != '\n') continue;
                string line = all.Substring(start, i - start).TrimEnd('\r');
                start = i + 1;
                if (line.Length > 0) Emit(onLine, line);
            }
            pending.Length = 0;
            if (start < all.Length) pending.Append(all.Substring(start));
            return pos;
        }

        private static void Emit(Action<string> onLine, string line)
        {
            if (onLine == null || string.IsNullOrEmpty(line)) return;
            // PowerShell 写的日志文件带 UTF-8 BOM，第一行会粘上 \uFEFF
            line = line.TrimStart('\uFEFF');
            if (line.Length == 0) return;
            try { onLine(line); } catch { }
        }

        public static void Cancel()
        {
            Run run;
            lock (Gate) run = _run;
            if (run == null) return;
            run.Canceled = true;
            int pid = 0;
            try { pid = run.Proc.Id; } catch { }
            if (pid <= 0) return;
            // 只杀 powershell 会留下 DISM / 安装程序子进程，必须带 /T
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "taskkill.exe",
                    Arguments = "/PID " + pid + " /T /F",
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                Process.Start(psi);
            }
            catch
            {
                try { run.Proc.Kill(); } catch { }
            }
        }

        private static void Raise()
        {
            var h = Changed;
            if (h == null) return;
            try { h(); } catch { }
        }
    }
}

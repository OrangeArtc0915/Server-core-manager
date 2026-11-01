using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace ScmUi
{
    // ============================================================
    // C# ↔ PowerShell 桥：界面只负责显示，所有系统操作仍走既有 runner。
    //   Bridge.Run("gui\\Run-GuiReadyMonitor.ps1", "metrics", null, d => {...});
    // runner 的约定没变：-Mode <mode> -OutFile <json> [-ArgsFile <json>]，
    // 结果封套 {Mode, Stamp, Error, Snap|Data}。回调在后台线程，调用方自己切回 UI。
    // ============================================================
    internal static class Bridge
    {
        private static readonly JavaScriptSerializer Ser = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        private static string _root;

        public static string Root
        {
            get
            {
                if (_root == null)
                {
                    // exe 在 <root>\ui\bin\ScmUi.exe
                    _root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"..\.."));
                }
                return _root;
            }
        }

        public static string StatePath
        {
            get { return Path.Combine(Root, "state"); }
        }

        public static void Run(string scriptRel, string mode, Dictionary<string, object> args,
                               Action<Dictionary<string, object>> done, Action<string> fail = null,
                               int timeoutMs = 120000, string switches = null)
        {
            string work = Path.Combine(Path.GetTempPath(), "scm-ui-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    Directory.CreateDirectory(work);
                    string outFile = Path.Combine(work, "result.json");
                    var psi = new ProcessStartInfo
                    {
                        FileName = "powershell.exe",
                        CreateNoWindow = true,
                        UseShellExecute = false,
                        WindowStyle = ProcessWindowStyle.Hidden
                    };
                    string script = Path.Combine(Root, scriptRel);
                    var sb = new StringBuilder();
                    sb.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(script).Append('"');
                    // 个别 runner（环境探测）没有 -Mode，只需要 -OutFile
                    if (!string.IsNullOrEmpty(mode)) sb.Append(" -Mode ").Append(mode);
                    sb.Append(" -OutFile \"").Append(outFile).Append('"');
                    // 少量开关参数（例如 dsh 的 -DeepProbe）走这里，避免为它们改 runner 接口
                    if (!string.IsNullOrEmpty(switches)) sb.Append(' ').Append(switches);

                    if (args != null && args.Count > 0)
                    {
                        string af = Path.Combine(work, "args.json");
                        File.WriteAllText(af, Ser.Serialize(args), new UTF8Encoding(false));
                        sb.Append(" -ArgsFile \"").Append(af).Append('"');
                    }
                    psi.Arguments = sb.ToString();

                    var p = Process.Start(psi);
                    if (p != null && !p.WaitForExit(timeoutMs))
                    {
                        try { p.Kill(); } catch { }
                        throw new TimeoutException("runner 超过 " + (timeoutMs / 1000) + " 秒没有返回");
                    }
                    if (!File.Exists(outFile)) throw new Exception("runner 没有写出结果文件");

                    string json = File.ReadAllText(outFile, Encoding.UTF8);
                    var dict = Ser.Deserialize<Dictionary<string, object>>(json);
                    if (dict == null) throw new Exception("结果不是合法 JSON");

                    object err;
                    if (dict.TryGetValue("Error", out err) && err != null && err.ToString().Length > 0)
                        throw new Exception(err.ToString());

                    if (done != null) done(dict);
                }
                catch (Exception ex)
                {
                    if (fail != null) fail(ex.Message);
                }
                finally
                {
                    try { Directory.Delete(work, true); } catch { }
                }
            });
        }

        // ---------------- JSON 取值帮助 ----------------
        public static Dictionary<string, object> Dict(object o)
        {
            return o as Dictionary<string, object>;
        }

        public static List<Dictionary<string, object>> List(object o)
        {
            var list = new List<Dictionary<string, object>>();
            if (o == null || o is string) return list;
            // 泛型反序列化把 JSON 数组还原成 ArrayList（不是 object[]），两种都要认
            var seq = o as System.Collections.IEnumerable;
            if (seq == null) return list;
            foreach (var item in seq)
            {
                var d = item as Dictionary<string, object>;
                if (d != null) list.Add(d);
            }
            return list;
        }

        public static string Str(Dictionary<string, object> d, string key, string def = "")
        {
            if (d == null) return def;
            object v;
            if (!d.TryGetValue(key, out v) || v == null) return def;
            return v.ToString();
        }

        // 读取字符串数组（例如主机的 Tags），兼容 "单个字符串" 与 JSON 数组两种写法
        public static List<string> StrList(Dictionary<string, object> d, string key)
        {
            var result = new List<string>();
            if (d == null) return result;
            object v;
            if (!d.TryGetValue(key, out v) || v == null) return result;
            if (v is string)
            {
                string one = (string)v;
                if (one.Length > 0) result.Add(one);
                return result;
            }
            var seq = v as System.Collections.IEnumerable;
            if (seq == null) return result;
            foreach (var item in seq)
            {
                if (item == null) continue;
                string s = item.ToString();
                if (s.Length > 0) result.Add(s);
            }
            return result;
        }

        public static double Num(Dictionary<string, object> d, string key, double def = 0)
        {
            if (d == null) return def;
            object v;
            if (!d.TryGetValue(key, out v) || v == null) return def;
            double r;
            if (double.TryParse(v.ToString(), out r)) return r;
            return def;
        }

        public static bool Bool(Dictionary<string, object> d, string key, bool def = false)
        {
            if (d == null) return def;
            object v;
            if (!d.TryGetValue(key, out v) || v == null) return def;
            bool r;
            if (bool.TryParse(v.ToString(), out r)) return r;
            return def;
        }
    }
}

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 程序自更新：检查 GitHub / Gitee 的主程序 tag，下载整包，交给替换脚本。
    // 与 HMOL 的启动器更新同一套思路，区别是 SCM 是整目录程序：
    // 替换时保留 logs / reports / state / payload / runtimes 等用户数据，
    // 并且跳过 launcher\programs.json（用户的程序列表）。
    // ============================================================
    internal static class SelfUpdate
    {
        // 替换脚本在等本进程退出；关窗时不要再拉起终端
        public static bool PendingRestart;

        private static bool _busy;
        private static string _current;

        public static string CurrentVersion
        {
            get
            {
                if (_current != null) return _current;
                _current = "v0.0.0";
                try
                {
                    string p = Path.Combine(Bridge.Root, "install.ps1");
                    if (File.Exists(p))
                    {
                        var m = Regex.Match(File.ReadAllText(p), @"\$ScmVer\s*=\s*'([^']+)'");
                        if (m.Success) _current = m.Groups[1].Value.Trim();
                    }
                }
                catch { }
                return _current;
            }
        }

        public static string UpdateDir
        {
            get { return Path.Combine(Bridge.StatePath, "update"); }
        }

        private static string FailureNotePath
        {
            get { return Path.Combine(UpdateDir, "failed.txt"); }
        }

        // ---------------------------------------------------------- 启动检查
        public static void OnStartup(Shell owner)
        {
            ShowFailureNote(owner);

            if (!AppSettings.UpdateCheckOnStartup) return;
            if (CheckedWithinDay()) return;

            // 让首屏先画出来，再起子进程查网络
            var timer = new Timer { Interval = 2600 };
            timer.Tick += (s, e) =>
            {
                timer.Stop();
                timer.Dispose();
                RunCheck(owner, false, null);
            };
            timer.Start();
        }

        // ---------------------------------------------------------- 手动检查
        public static void CheckManual(Control owner, Action<Dictionary<string, object>> onResult = null)
        {
            RunCheck(owner, true, onResult);
        }

        // ---------------------------------------------------------- 内部
        private static bool CheckedWithinDay()
        {
            DateTime last;
            if (!DateTime.TryParse(AppSettings.LastUpdateCheck, out last)) return false;
            return (DateTime.Now - last).TotalHours < 24;
        }

        private static void RunCheck(Control owner, bool manual, Action<Dictionary<string, object>> onResult)
        {
            if (_busy) return;
            _busy = true;

            Trace("check manual=" + manual + " source=" + AppSettings.UpdateSource);

            var args = new Dictionary<string, object> { { "Source", AppSettings.UpdateSource } };

            Bridge.Run(@"gui\Run-GuiReadySelfUpdate.ps1", "check", args,
                d =>
                {
                    _busy = false;
                    AppSettings.LastUpdateCheck = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
                    AppSettings.Save();

                    bool available = Bridge.Bool(d, "Available");
                    string latest = Bridge.Str(d, "Latest");
                    string source = Bridge.Str(d, "Source");
                    string tag = Bridge.Str(d, "Tag");
                    Trace("check result available=" + available + " latest=" + latest);

                    Ui(owner, () =>
                    {
                        if (onResult != null) onResult(d);

                        if (!available)
                        {
                            if (manual)
                                Dialogs.Confirm(owner, "检查更新",
                                    "当前已是最新版本（" + CurrentVersion + "）。", "知道了");
                            return;
                        }

                        bool go = Dialogs.Confirm(owner, "发现新版本 " + latest,
                            "当前 " + CurrentVersion + "　｜　最新 " + latest +
                            "（来自 " + SourceName(source) + "）。\n" +
                            "更新只替换程序文件：日志、报告、配置、运行库与程序列表都会保留。\n" +
                            "更新时程序会自动关闭，替换完成后重新打开。",
                            "现在更新");
                        if (go) InstallUpdate(owner, tag, source);
                    });
                },
                err =>
                {
                    _busy = false;
                    Trace("check failed: " + err);
                    if (manual)
                        Ui(owner, () => Dialogs.Confirm(owner, "检查更新失败",
                            err + "\n\n可以换一条线路再试，或到发布页手动下载。", "知道了"));
                },
                90000);
        }

        public static void InstallUpdate(Control owner, string tag, string source)
        {
            if (_busy) return;
            _busy = true;

            Trace("install tag=" + tag + " source=" + source);
            var args = new Dictionary<string, object>
            {
                { "Source", source },
                { "WaitPid", Process.GetCurrentProcess().Id }
            };

            Bridge.Run(@"gui\Run-GuiReadySelfUpdate.ps1", "install", args,
                d =>
                {
                    _busy = false;
                    bool ok = Bridge.Bool(d, "Ok");

                    if (ok)
                    {
                        PendingRestart = true;
                        Ui(owner, () =>
                        {
                            Dialogs.Confirm(owner, "更新准备就绪",
                                "更新包已下载并完成 SHA256 校验。\n" +
                                "点「好」之后程序会退出，替换完成后自动重新打开（约几秒）。",
                                "好，立即更新");
                            var form = owner != null ? owner.FindForm() : null;
                            if (form != null) form.Close();
                            else Application.Exit();
                        });
                        return;
                    }

                    string failure = Bridge.Str(d, "Failure");
                    string message = Bridge.Str(d, "Message");
                    Ui(owner, () => Dialogs.Confirm(owner, "更新没有完成",
                        FailureText(failure, message) +
                        "\n\n可以稍后再试，或到发布页手动下载压缩包覆盖安装。", "知道了"));
                },
                err =>
                {
                    _busy = false;
                    Ui(owner, () => Dialogs.Confirm(owner, "更新没有完成",
                        err + "\n\n可以到发布页手动下载压缩包覆盖安装。", "知道了"));
                },
                900000);
        }

        private static string FailureText(string failure, string message)
        {
            switch ((failure ?? "").Trim())
            {
                case "elevation-required":
                    return "需要管理员权限才能替换程序文件。\n请关掉本窗口，用管理员身份重新打开后再更新。";
                case "hash":
                    return "更新包校验失败（SHA256 不一致或侧车缺失），已中止，没有改动任何文件。\n" +
                           "可能是下载不完整，请稍后重试。" +
                           (string.IsNullOrEmpty(message) ? "" : "\n（" + message + "）");
                case "package":
                    return "更新包内容不完整（缺少 install.ps1 / 界面文件），已中止。";
                case "download":
                    return "下载更新包失败。" +
                           (string.IsNullOrEmpty(message) ? "" : "\n（" + message + "）");
                case "no-update":
                    return "检查时已经没有可用的新版本了。";
                case "check":
                    return "获取更新信息失败，请检查网络或换一条线路。";
                default:
                    return "更新过程中出现意外错误。" +
                           (string.IsNullOrEmpty(message) ? "" : "\n（" + failure + "：" + message + "）");
            }
        }

        private static void ShowFailureNote(Control owner)
        {
            try
            {
                if (!File.Exists(FailureNotePath)) return;
                string marker = File.ReadAllText(FailureNotePath).Trim();
                File.Delete(FailureNotePath);

                string text;
                switch (marker)
                {
                    case "timeout":
                        text = "上一次自动更新等待超时（程序在 3 分钟内没有退出），本次没有改动任何文件。";
                        break;
                    case "failed":
                        text = "上一次自动更新替换失败，已还原旧版本。若仍不正常，请到发布页手动下载覆盖安装。";
                        break;
                    case "broken":
                        text = "上一次自动更新替换后校验没通过，请到发布页手动下载最新版本覆盖安装。";
                        break;
                    default:
                        text = "上一次自动更新没有完成（标记：" + marker + "）。";
                        break;
                }
                Dialogs.Confirm(owner, "上次更新没有完成", text, "知道了");
            }
            catch { }
        }

        private static string SourceName(string source)
        {
            if (source == "gitee") return "Gitee";
            if (source == "github") return "GitHub";
            return "自动线路";
        }

        private static void Ui(Control owner, Action action)
        {
            try
            {
                if (owner == null) { action(); return; }
                if (owner.IsDisposed) return;
                if (owner.IsHandleCreated && owner.InvokeRequired) owner.BeginInvoke(action);
                else action();
            }
            catch { }
        }

        // 自更新自己的留痕：检查 / 安装的起点与结果各记一行，排查「点了没反应」时用
        private static void Trace(string text)
        {
            try
            {
                string dir = Path.Combine(Bridge.Root, "logs");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "self-update-ui.log"),
                    DateTime.Now.ToString("HH:mm:ss") + " " + text + Environment.NewLine);
            }
            catch { }
        }
    }
}

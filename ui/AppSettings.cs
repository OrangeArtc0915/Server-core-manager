using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace ScmUi
{
    // ============================================================
    // 界面设置：版本档位与显示策略，落在 state\ui-settings.json。
    // 界面（原生 / PowerShell 回退）与动作清单（Get-GuiReadyActions）读同一份文件，
    // 避免出现「导航里没有、动作台里还在」的错位。
    // ============================================================
    internal static class AppSettings
    {
        public const string Auto = "auto";
        public const string Modern = "modern";   // 2019 及以上
        public const string Legacy = "legacy";   // 2012 R2 – 2016
        public const string Old = "old";         // 2008 R2

        // Server Core 的 App Compatibility FOD 从 2019（17763）开始提供
        public const int ModernBuild = 17763;
        // 2008 R2 是最后一个还支持 WMF 5.1 的旧系统（2008 SP2 装不了）
        public const int OldBuild = 7601;

        public static string Tier = Auto;
        public static bool HideWacDuplicates = true;
        public static bool HideUnsupported = true;
        public static bool FirstRunDone;
        public static int DetectedBuild;
        public static string DetectedName = "";

        // 程序自更新（不是「系统更新」页那个 Windows Update）
        public static bool UpdateCheckOnStartup = true;
        public static string UpdateSource = "auto";        // auto / github / gitee
        public static string LastUpdateCheck = "";         // yyyy-MM-dd HH:mm:ss

        private static readonly JavaScriptSerializer Ser = new JavaScriptSerializer();

        // 与 Windows Admin Center 重复的页面：2019+ 默认隐藏
        private static readonly HashSet<string> WacPages = new HashSet<string>
        {
            "update", "network", "accounts", "services",
            "firewall", "storage", "systasks", "logs"
        };

        // 依赖 App Compatibility FOD / 补全 DLL 的页面：2019 以下实测不可用
        private static readonly HashSet<string> LegacyPages = new HashSet<string>
        {
            "env", "app", "catalog", "tool"
        };

        public static string FilePath
        {
            get { return Path.Combine(Bridge.StatePath, "ui-settings.json"); }
        }

        public static bool IsModern
        {
            get
            {
                if (Tier == Modern) return true;
                if (Tier == Legacy || Tier == Old) return false;
                return DetectedBuild >= ModernBuild;
            }
        }

        // 2008 R2：缺 NetAdapter / NetSecurity / Storage / ScheduledTasks，存储页只读
        public static bool IsOld
        {
            get
            {
                if (Tier == Old) return true;
                if (Tier == Modern || Tier == Legacy) return false;
                return DetectedBuild > 0 && DetectedBuild <= OldBuild;
            }
        }

        public static void Detect()
        {
            int build = 0;
            string product = "";
            try
            {
                using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (var key = baseKey.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    if (key != null)
                    {
                        int.TryParse(Convert.ToString(key.GetValue("CurrentBuildNumber")), out build);
                        product = Convert.ToString(key.GetValue("ProductName")) ?? "";
                    }
                }
            }
            catch { }
            if (build <= 0)
            {
                try { build = Environment.OSVersion.Version.Build; } catch { build = 0; }
            }
            DetectedBuild = build;
            DetectedName = FriendlyName(build, product);
        }

        private static string FriendlyName(int build, string product)
        {
            // 客户端系统（Windows 10/11）按原始名称显示，别再套 Server 的名字
            if (!string.IsNullOrEmpty(product) &&
                product.IndexOf("Server", StringComparison.OrdinalIgnoreCase) < 0 &&
                product.IndexOf("Hyper-V", StringComparison.OrdinalIgnoreCase) < 0)
                return product;

            if (build >= 26100) return "Windows Server 2025";
            if (build >= 20348) return "Windows Server 2022";
            if (build >= 17763) return "Windows Server 2019";
            if (build >= 14393) return "Windows Server 2016";
            if (build >= 9600) return "Windows Server 2012 R2";
            if (build >= 9200) return "Windows Server 2012";
            if (build >= 7601) return "Windows Server 2008 R2";
            if (build >= 6002) return "Windows Server 2008";
            if (!string.IsNullOrEmpty(product)) return product;
            return "未知系统";
        }

        public static string TierText
        {
            get
            {
                if (Tier == Modern) return "2019 及以上（手动指定）";
                if (Tier == Legacy) return "2012 R2 – 2016（手动指定）";
                if (Tier == Old) return "2008 R2（手动指定）";
                return "自动识别 · 当前按 " + (IsModern ? "2019+" : (IsOld ? "2008 R2" : "2012 R2 – 2016")) + " 处理";
            }
        }

        public static void Load()
        {
            Detect();
            Tier = Auto;
            HideWacDuplicates = true;
            HideUnsupported = true;
            FirstRunDone = false;
            UpdateCheckOnStartup = true;
            UpdateSource = "auto";
            LastUpdateCheck = "";

            try
            {
                if (File.Exists(FilePath))
                {
                    var map = Ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(FilePath));
                    if (map != null)
                    {
                        object v;
                        if (map.TryGetValue("VersionTier", out v) && v != null)
                        {
                            string t = Convert.ToString(v);
                            if (t == Modern || t == Legacy || t == Old || t == Auto) Tier = t;
                        }
                        if (map.TryGetValue("HideWacDuplicates", out v) && v != null)
                            HideWacDuplicates = Convert.ToBoolean(v);
                        if (map.TryGetValue("HideUnsupported", out v) && v != null)
                            HideUnsupported = Convert.ToBoolean(v);
                        if (map.TryGetValue("FirstRunDone", out v) && v != null)
                            FirstRunDone = Convert.ToBoolean(v);
                        if (map.TryGetValue("UpdateCheckOnStartup", out v) && v != null)
                            UpdateCheckOnStartup = Convert.ToBoolean(v);
                        if (map.TryGetValue("UpdateSource", out v) && v != null)
                        {
                            string s = Convert.ToString(v);
                            if (s == "github" || s == "gitee" || s == "auto") UpdateSource = s;
                        }
                        if (map.TryGetValue("LastUpdateCheck", out v) && v != null)
                            LastUpdateCheck = Convert.ToString(v);
                    }
                }
            }
            catch { }
        }

        public static void Save()
        {
            try
            {
                Directory.CreateDirectory(Bridge.StatePath);
                var map = new Dictionary<string, object>
                {
                    { "VersionTier", Tier },
                    { "HideWacDuplicates", HideWacDuplicates },
                    { "HideUnsupported", HideUnsupported },
                    { "FirstRunDone", FirstRunDone },
                    { "UpdateCheckOnStartup", UpdateCheckOnStartup },
                    { "UpdateSource", UpdateSource },
                    { "LastUpdateCheck", LastUpdateCheck },
                    { "DetectedBuild", DetectedBuild },
                    { "DetectedName", DetectedName },
                    { "SavedAt", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") }
                };
                File.WriteAllText(FilePath, Ser.Serialize(map));
            }
            catch { }
        }

        // 导航与快捷跳转共用：判断某个页面在当前策略下是否显示
        public static bool IsPageVisible(string key)
        {
            if (string.IsNullOrEmpty(key)) return false;
            if (HideWacDuplicates && IsModern && WacPages.Contains(key)) return false;
            if (HideUnsupported && !IsModern && LegacyPages.Contains(key)) return false;
            return true;
        }
    }
}

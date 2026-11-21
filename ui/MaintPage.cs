using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 系统维护：证书 / 驱动与硬件 / 启动项 / 系统状态备份。
    // 读走 Run-GuiReadyMaint.ps1，写走动作执行器。
    // ============================================================
    internal sealed class MaintPage : SysPage
    {
        protected override string RunnerScript { get { return @"gui\Run-GuiReadyMaint.ps1"; } }

        public MaintPage()
            : base("maint", "系统维护", "证书、驱动与硬件健康、启动项、系统状态备份——服务器日常维护的四个入口。", "tool")
        {
            AddTab("certs", "证书", 76);
            AddTab("drivers", "驱动", 76);
            AddTab("startup", "启动项", 88);
            AddTab("backup", "备份", 76);

            AddBtn("certs", "导入…", ButtonKind.Primary, 80, ImportCert);
            AddBtn("certs", "导出…", ButtonKind.Normal, 80, ExportCert);
            AddBtn("certs", "删除", ButtonKind.Danger, 72, RemoveCert);
            AddBtn("certs", "即将过期", ButtonKind.Normal, 92, ShowExpiring);
            AddBtn("certs", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBtn("drivers", "导出驱动…", ButtonKind.Primary, 106, ExportDrivers);
            AddBtn("drivers", "导入驱动…", ButtonKind.Normal, 106, ImportDrivers);
            AddBtn("drivers", "问题设备", ButtonKind.Normal, 92, ShowProblems);
            AddBtn("drivers", "磁盘健康", ButtonKind.Normal, 92, ShowDiskHealth);
            AddBtn("drivers", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBtn("startup", "启用/禁用", ButtonKind.Primary, 96, ToggleStartup);
            AddBtn("startup", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBtn("backup", "新建备份", ButtonKind.Primary, 96, NewBackup);
            AddBtn("backup", "复制到共享…", ButtonKind.Normal, 106, ShareBackup);
            AddBtn("backup", "每日备份…", ButtonKind.Normal, 96, BackupTask);
            AddBtn("backup", "刷新", ButtonKind.Ghost, 72, () => Load());

            SetView("certs");
        }

        protected override void BuildColumns()
        {
            switch (ViewKey)
            {
                case "drivers":
                    AddCol("设备", 300);
                    AddCol("类别", 110);
                    AddCol("版本", 150);
                    AddCol("日期", 100);
                    AddCol("厂商", 150);
                    AddCol("状态", 100);
                    break;
                case "startup":
                    AddCol("类型", 80);
                    AddCol("名称", 220);
                    AddCol("命令 / 路径", 420);
                    AddCol("来源", 150);
                    AddCol("状态", 70);
                    break;
                case "backup":
                    AddCol("文件", 360);
                    AddCol("时间", 160);
                    AddCol("大小 MB", 90, true);
                    break;
                default:
                    AddCol("主题", 320);
                    AddCol("颁发者", 260);
                    AddCol("到期", 100);
                    AddCol("剩余天数", 90, true);
                    AddCol("私钥", 60);
                    AddCol("指纹", 220);
                    break;
            }
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            switch (ViewKey)
            {
                case "drivers":
                    return new[]
                    {
                        Bridge.Str(d, "Device"),
                        Bridge.Str(d, "Class"),
                        Bridge.Str(d, "Version"),
                        Bridge.Str(d, "Date"),
                        Bridge.Str(d, "Provider"),
                        Bridge.Str(d, "Status")
                    };
                case "startup":
                    return new[]
                    {
                        Bridge.Str(d, "Type"),
                        Bridge.Str(d, "Name"),
                        Bridge.Str(d, "Command"),
                        Bridge.Str(d, "Source"),
                        Bridge.Bool(d, "Enabled", true) ? "启用" : "已禁用"
                    };
                case "backup":
                    return new[]
                    {
                        Bridge.Str(d, "File"),
                        Bridge.Str(d, "Time"),
                        Bridge.Num(d, "SizeMB").ToString("0.0")
                    };
                default:
                    return new[]
                    {
                        Bridge.Str(d, "Subject"),
                        Bridge.Str(d, "Issuer"),
                        Bridge.Str(d, "NotAfter"),
                        Bridge.Str(d, "DaysLeft"),
                        Bridge.Bool(d, "HasPrivateKey") ? "有" : "",
                        Bridge.Str(d, "Thumbprint")
                    };
            }
        }

        protected override void Load()
        {
            switch (ViewKey)
            {
                case "drivers":
                    RunList("driver-list", null, 120000);
                    break;
                case "startup":
                    RunList("startup-list", null, 120000);
                    break;
                case "backup":
                    RunList("backup-list", null, 60000);
                    break;
                default:
                    var a = new Dictionary<string, object>();
                    a["Location"] = "My";
                    RunList("cert-list", a, 60000);
                    break;
            }
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            if (ViewKey == "drivers") SetSum(Items.Count + " 个设备", "Info");
            else if (ViewKey == "startup") SetSum(Items.Count + " 个启动项", "Info");
            else if (ViewKey == "backup") SetSum(Items.Count + " 份备份", Items.Count > 0 ? "Success" : "Neutral");
            else
            {
                int exp = 0;
                foreach (var it in Items) if (Bridge.Num(it, "DaysLeft") <= 30) exp++;
                SetSum(Items.Count + " 张证书" + (exp > 0 ? " · " + exp + " 张即将过期" : ""), exp > 0 ? "Warn" : "Info");
            }
        }

        // ---------------------------------------------------------- 证书
        private void ImportCert()
        {
            string path = Dialogs.OpenFile(FindForm(), "选择证书文件",
                "证书 (*.pfx;*.p12;*.cer)|*.pfx;*.p12;*.cer|所有文件 (*.*)|*.*");
            if (string.IsNullOrEmpty(path)) return;
            var locs = new List<string> { "My（个人）", "Root（受信任根）", "CA（中间 CA）", "TrustedPeople（受信任人）" };
            var v = Dialogs.Prompt(FindForm(), "导入证书", path,
                new List<PromptField>
                {
                    new PromptField("pfx 密码（.cer 留空）", "", false, ""),
                    new PromptField("存储位置", locs[0], locs)
                }, "导入");
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["Path"] = path;
            args["Password"] = v[0];
            args["Location"] = Math.Max(0, locs.IndexOf(v[1])) + 1;
            RunAction("cert-import", args, "导入证书");
        }

        private void ExportCert()
        {
            var it = NeedSelected();
            if (it == null) return;
            string thumb = Bridge.Str(it, "Thumbprint");
            string def = thumb.Length > 8 ? thumb.Substring(0, 8) + ".cer" : "cert.cer";
            string path = Dialogs.SaveFile(FindForm(), "导出证书", "证书 (*.cer)|*.cer|PFX (*.pfx)|*.pfx", def);
            if (string.IsNullOrEmpty(path)) return;
            var fmts = new List<string> { "cer（公钥）", "pfx（含私钥）" };
            var locs = new List<string> { "My（个人）", "Root（受信任根）", "CA（中间 CA）", "TrustedPeople（受信任人）" };
            var v = Dialogs.Prompt(FindForm(), "导出证书", "导出 " + Bridge.Str(it, "Subject"),
                new List<PromptField>
                {
                    new PromptField("格式", fmts[0], fmts),
                    new PromptField("pfx 密码（cer 留空）", ""),
                    new PromptField("存储位置", locs[0], locs)
                }, "导出");
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["Thumbprint"] = thumb;
            args["Path"] = path;
            args["Format"] = Math.Max(0, fmts.IndexOf(v[0])) + 1;
            args["Password"] = v[1];
            args["Location"] = Math.Max(0, locs.IndexOf(v[2])) + 1;
            RunAction("cert-export", args, "导出证书");
        }

        private void RemoveCert()
        {
            var it = NeedSelected();
            if (it == null) return;
            if (!Dialogs.Confirm(FindForm(), "删除证书",
                "确定从本机证书存储删除？\n" + Bridge.Str(it, "Subject") + "\n" + Bridge.Str(it, "Thumbprint"))) return;
            var args = new Dictionary<string, object>();
            args["Thumbprint"] = Bridge.Str(it, "Thumbprint");
            args["Location"] = 1;
            RunAction("cert-remove", args, "删除证书");
        }

        private void ShowExpiring()
        {
            var a = new Dictionary<string, object>();
            a["Days"] = 30;
            ShowMaintText("cert-expiring", a, "即将过期的证书", items =>
            {
                var sb = new System.Text.StringBuilder();
                foreach (var it in items)
                    sb.AppendLine(Bridge.Str(it, "NotAfter") + "  " + Bridge.Str(it, "DaysLeft") + " 天  " + Bridge.Str(it, "Subject"));
                return sb.ToString();
            });
        }

        // ---------------------------------------------------------- 驱动
        private void ExportDrivers()
        {
            string path = Dialogs.Folder(FindForm(), "选择驱动导出目录");
            if (string.IsNullOrEmpty(path)) return;
            var args = new Dictionary<string, object>();
            args["Path"] = path;
            RunAction("driver-export", args, "导出驱动");
        }

        private void ImportDrivers()
        {
            string path = Dialogs.Folder(FindForm(), "选择驱动目录（含 .inf）");
            if (string.IsNullOrEmpty(path)) return;
            if (!Dialogs.Confirm(FindForm(), "导入驱动", "将从该目录安装驱动：\n" + path)) return;
            var args = new Dictionary<string, object>();
            args["Path"] = path;
            RunAction("driver-import", args, "导入驱动");
        }

        private void ShowProblems()
        {
            ShowMaintText("driver-problems", null, "问题设备", items =>
            {
                var sb = new System.Text.StringBuilder();
                foreach (var it in items)
                    sb.AppendLine(Bridge.Str(it, "Device") + "  [" + Bridge.Str(it, "Class") + "]  代码 " + Bridge.Str(it, "Code"));
                return sb.Length == 0 ? "没有发现问题设备。" : sb.ToString();
            });
        }

        private void ShowDiskHealth()
        {
            ShowMaintText("disk-health", null, "磁盘健康", items =>
            {
                var sb = new System.Text.StringBuilder();
                foreach (var it in items)
                {
                    sb.AppendLine(Bridge.Str(it, "Disk") + "  " + Bridge.Str(it, "Media") + "  " +
                                  Bridge.Num(it, "SizeGB").ToString("0.0") + " GB  " + Bridge.Str(it, "Health"));
                    string temp = Bridge.Str(it, "Temperature");
                    string wear = Bridge.Str(it, "Wear");
                    string hours = Bridge.Str(it, "PowerOnHours");
                    if (temp.Length > 0 || wear.Length > 0 || hours.Length > 0)
                        sb.AppendLine("    温度 " + temp + "  磨损 " + wear + "  通电 " + hours + " 小时");
                }
                return sb.Length == 0 ? "没有读取到磁盘信息。" : sb.ToString();
            });
        }

        // ---------------------------------------------------------- 启动项
        private void ToggleStartup()
        {
            var it = NeedSelected();
            if (it == null) return;
            bool enabled = Bridge.Bool(it, "Enabled", true);
            string action = enabled ? "禁用" : "启用";
            if (!Dialogs.Confirm(FindForm(), action + "启动项",
                action + "「" + Bridge.Str(it, "Name") + "」？\n" + Bridge.Str(it, "Command"))) return;
            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(it, "Id");
            args["Enabled"] = !enabled;
            RunAction("startup-toggle", args, action + "启动项");
        }

        // ---------------------------------------------------------- 备份
        private void NewBackup()
        {
            if (!Dialogs.Confirm(FindForm(), "新建系统状态备份",
                "将打包注册表关键分支、证书、计划任务、防火墙与资产清单。\n默认不包含驱动（体积很大）。继续？")) return;
            var args = new Dictionary<string, object>();
            args["OutDir"] = "";
            args["WithDrivers"] = false;
            args["FullRegistry"] = false;
            RunAction("sysbackup-create", args, "创建备份");
        }

        private void ShareBackup()
        {
            var it = NeedSelected();
            if (it == null) return;
            var v = Dialogs.Prompt(FindForm(), "复制备份到共享",
                "备份：" + Bridge.Str(it, "File"),
                new List<PromptField>
                {
                    new PromptField("共享目录（如 \\\\nas\\backup）", ""),
                    new PromptField("保留份数", "5")
                }, "复制");
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["File"] = Bridge.Str(it, "Path");
            args["Share"] = v[0];
            args["Keep"] = v[1];
            RunAction("sysbackup-share", args, "复制备份");
        }

        private void BackupTask()
        {
            var v = Dialogs.Prompt(FindForm(), "每日备份计划任务",
                "每天定时创建系统状态备份；共享目录可留空。",
                new List<PromptField>
                {
                    new PromptField("共享目录（可空）", ""),
                    new PromptField("保留份数", "5"),
                    new PromptField("每天时间（HH:mm）", "03:00")
                }, "安装");
            if (v == null) return;
            var args = new Dictionary<string, object>();
            args["Share"] = v[0];
            args["Keep"] = v[1];
            args["Time"] = v[2];
            args["WithDrivers"] = false;
            args["FullRegistry"] = false;
            RunAction("sysbackup-task", args, "安装备份任务");
        }

        // ---------------------------------------------------------- 只读文本窗口
        private void ShowMaintText(string mode, Dictionary<string, object> args, string title,
                                   Func<List<Dictionary<string, object>>, string> render)
        {
            SetSum("读取中…", "Info");
            Bridge.Run(RunnerScript, mode, args,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        SetSum(title + "：" + items.Count + " 条", "Info");
                        Dialogs.Text(FindForm(), title, "", render == null ? "" : render(items));
                    });
                },
                err => SafeInvoke(() =>
                {
                    SetSum("读取失败", "Danger");
                    Log("[WARN] " + title + "读取失败: " + err);
                }), 120000);
        }
    }
}

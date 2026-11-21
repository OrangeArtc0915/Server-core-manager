using System;
using System.Collections.Generic;
using System.IO;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 软件与权限：已安装软件清单 / 静默卸载 / SMB 共享授权 / NTFS ACL。
    // 读走 Run-GuiReadySoftware.ps1，写走动作执行器（有审计）。
    // ============================================================
    internal sealed class SoftwarePage : SysPage
    {
        private string _aclPath = @"C:\";

        protected override string RunnerScript { get { return @"gui\Run-GuiReadySoftware.ps1"; } }

        public SoftwarePage()
            : base("soft", "软件与权限", "注册表软件清单与静默卸载、SMB 共享授权、NTFS ACL 查询与设置；写操作走动作执行器。", "security")
        {
            AddTab("soft", "软件清单", 96);
            AddTab("share", "共享权限", 96);
            AddTab("ntfs", "NTFS 权限", 100);

            AddBtn("soft", "导出清单…", ButtonKind.Normal, 106, ExportList);
            AddBtn("soft", "卸载…", ButtonKind.Danger, 82, Uninstall);
            AddBtn("soft", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBtn("share", "授权…", ButtonKind.Primary, 82, GrantShare);
            AddBtn("share", "收回…", ButtonKind.Danger, 82, RevokeShare);
            AddBtn("share", "刷新", ButtonKind.Ghost, 72, () => Load());

            AddBtn("ntfs", "查询路径…", ButtonKind.Normal, 100, QueryAcl);
            AddBtn("ntfs", "设置权限…", ButtonKind.Primary, 106, SetAcl);
            AddBtn("ntfs", "刷新", ButtonKind.Ghost, 72, () => Load());

            SetView("soft");
        }

        protected override void BuildColumns()
        {
            switch (ViewKey)
            {
                case "share":
                    AddCol("共享", 140);
                    AddCol("账户", 200);
                    AddCol("权限", 90);
                    AddCol("类型", 80);
                    AddCol("路径", 260);
                    AddCol("说明", 200);
                    break;
                case "ntfs":
                    AddCol("账户", 240);
                    AddCol("权限", 260);
                    AddCol("类型", 80);
                    AddCol("继承", 70);
                    AddCol("继承标志", 180);
                    AddCol("传播", 110);
                    break;
                default:
                    AddCol("名称", 300);
                    AddCol("版本", 100);
                    AddCol("发布者", 200);
                    AddCol("来源", 80);
                    AddCol("安装日期", 100);
                    AddCol("卸载命令", 320);
                    break;
            }
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            switch (ViewKey)
            {
                case "share":
                    return new[]
                    {
                        Bridge.Str(d, "Share"),
                        Bridge.Str(d, "Account"),
                        Bridge.Str(d, "Access"),
                        Bridge.Str(d, "Type"),
                        Bridge.Str(d, "Path"),
                        Bridge.Str(d, "Description")
                    };
                case "ntfs":
                    return new[]
                    {
                        Bridge.Str(d, "Account"),
                        Bridge.Str(d, "Rights"),
                        Bridge.Str(d, "Type"),
                        Bridge.Bool(d, "Inherited") ? "是" : "否",
                        Bridge.Str(d, "InheritFlags"),
                        Bridge.Str(d, "Propagation")
                    };
                default:
                    return new[]
                    {
                        Bridge.Str(d, "Name"),
                        Bridge.Str(d, "Version"),
                        Bridge.Str(d, "Publisher"),
                        Bridge.Str(d, "Source"),
                        Bridge.Str(d, "InstallDate"),
                        Bridge.Str(d, "QuietUninstallString").Length > 0
                            ? Bridge.Str(d, "QuietUninstallString")
                            : Bridge.Str(d, "UninstallString")
                    };
            }
        }

        protected override void Load()
        {
            if (ViewKey == "share") RunList("share-list", null, 60000);
            else if (ViewKey == "ntfs")
            {
                var a = new Dictionary<string, object>();
                a["Path"] = _aclPath;
                RunList("acl-list", a, 60000);
            }
            else RunList("list", null, 90000);
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            if (ViewKey == "share") SetSum(Items.Count + " 条共享授权", Items.Count > 0 ? "Info" : "Neutral");
            else if (ViewKey == "ntfs") SetSum(Items.Count + " 条 ACL · " + _aclPath, Items.Count > 0 ? "Info" : "Neutral");
            else SetSum(Items.Count + " 个已安装软件", Items.Count > 0 ? "Info" : "Neutral");
        }

        // ---------------------------------------------------------- 软件
        private void ExportList()
        {
            string dir = Path.Combine(Bridge.Root, "reports");
            string path = Dialogs.SaveFile(FindForm(), "导出软件清单",
                "CSV 文件 (*.csv)|*.csv|所有文件 (*.*)|*.*",
                "software-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".csv", dir);
            if (string.IsNullOrEmpty(path)) return;
            var a = new Dictionary<string, object>();
            a["Path"] = path;
            a["DryRun"] = false;
            RunAction("software-export", a, "导出软件清单");
        }

        private void Uninstall()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            if (!Dialogs.Confirm(FindForm(), "静默卸载",
                    "确定静默卸载「" + name + "」？只有提供静默命令的软件才会执行。", "卸载")) return;
            var a = new Dictionary<string, object>();
            a["Key"] = Bridge.Str(it, "Key");
            a["DryRun"] = false;
            RunAction("software-uninstall", a, "卸载 " + name);
        }

        // ---------------------------------------------------------- 共享
        private void GrantShare()
        {
            var it = Selected();
            var access = new List<string> { "Full", "Change", "Read" };
            var v = Dialogs.Prompt(FindForm(), "共享授权",
                "给账户授予 SMB 共享权限（Grant-SmbShareAccess）。",
                new List<PromptField>
                {
                    new PromptField("共享名", it == null ? "" : Bridge.Str(it, "Share")),
                    new PromptField("账户（如 DOMAIN\\user 或 Everyone）", ""),
                    new PromptField("权限", access[2], access)
                }, "授权", 520);
            if (v == null) return;
            var a = new Dictionary<string, object>();
            a["Name"] = v[0];
            a["Account"] = v[1];
            a["Access"] = Math.Max(0, access.IndexOf(v[2])) + 1;
            a["DryRun"] = false;
            RunAction("smb-grant", a, "共享授权");
        }

        private void RevokeShare()
        {
            var it = Selected();
            var v = Dialogs.Prompt(FindForm(), "收回共享权限",
                "移除指定账户在该共享上的授权。",
                new List<PromptField>
                {
                    new PromptField("共享名", it == null ? "" : Bridge.Str(it, "Share")),
                    new PromptField("账户", "")
                }, "收回", 500);
            if (v == null) return;
            var a = new Dictionary<string, object>();
            a["Name"] = v[0];
            a["Account"] = v[1];
            a["DryRun"] = false;
            RunAction("smb-revoke", a, "收回共享权限");
        }

        // ---------------------------------------------------------- NTFS
        private void QueryAcl()
        {
            var v = Dialogs.Prompt(FindForm(), "查询 NTFS 权限",
                "填目录或文件的绝对路径。",
                new List<PromptField>
                {
                    new PromptField("路径", _aclPath)
                }, "查询", 520);
            if (v == null) return;
            _aclPath = v[0];
            Load();
        }

        private void SetAcl()
        {
            var rights = new List<string> { "FullControl", "Modify", "ReadAndExecute", "Read", "Write" };
            var types = new List<string> { "Allow", "Deny" };
            var inherits = new List<string> { "ContainerInherit,ObjectInherit", "ContainerInherit", "ObjectInherit", "None" };
            var v = Dialogs.Prompt(FindForm(), "设置 NTFS 权限",
                "添加一条 ACL 规则。Deny 优先，确认账户与路径再执行。",
                new List<PromptField>
                {
                    new PromptField("路径", _aclPath),
                    new PromptField("账户", ""),
                    new PromptField("权限", rights[0], rights),
                    new PromptField("类型", types[0], types),
                    new PromptField("继承", inherits[0], inherits)
                }, "设置", 540);
            if (v == null) return;
            if (!Dialogs.Confirm(FindForm(), "确认设置权限",
                    v[2] + " " + v[3] + " " + v[1] + " 对 " + v[0] + "？")) return;
            _aclPath = v[0];
            var a = new Dictionary<string, object>();
            a["Path"] = v[0];
            a["Account"] = v[1];
            a["Rights"] = Math.Max(0, rights.IndexOf(v[2])) + 1;
            a["Type"] = Math.Max(0, types.IndexOf(v[3])) + 1;
            a["Inherit"] = Math.Max(0, inherits.IndexOf(v[4])) + 1;
            a["DryRun"] = false;
            RunAction("ntfs-set", a, "设置 NTFS 权限");
        }
    }
}

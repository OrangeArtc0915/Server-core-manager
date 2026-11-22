using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Text;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 系统更新（Windows Update）
    // ============================================================
    internal sealed class UpdatePage : SysPage
    {
        private Dictionary<string, object> _auto;

        public UpdatePage()
            : base("update", "系统更新", "Windows Update：检查 / 安装 / 历史 / 自动更新策略（走系统自带 COM，不依赖第三方模块）。", "update")
        {
            AddBtn("main", "检查更新", ButtonKind.Primary, 100, () => Load());
            AddBtn("main", "安装选中", ButtonKind.Normal, 96, InstallSelected);
            AddBtn("main", "全部安装", ButtonKind.Normal, 96, InstallAll);
            AddBtn("main", "已安装历史", ButtonKind.Ghost, 104, ShowHistory);
            AddBtn("main", "自动更新", ButtonKind.Normal, 96, SetAuto);
            AddBtn("main", "刷新", ButtonKind.Ghost, 72, () => Load());
            SetView("main");
            Table.ActivateOnDoubleClick = true;
            Table.RowActivated += idx => InstallSelected();
        }

        protected override void BuildColumns()
        {
            AddCol("更新标题", 560);
            AddCol("KB", 110);
            AddCol("大小(MB)", 90, true);
            AddCol("状态", 100);
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            return new[]
            {
                Bridge.Str(d, "Title"),
                Bridge.Str(d, "Kb"),
                Bridge.Num(d, "SizeMB").ToString("0.0"),
                Bridge.Bool(d, "Downloaded") ? "已下载" : "待下载"
            };
        }

        protected override void Load()
        {
            SetSum("检查中（可能要几十秒）…", "Info");
            RunList("update-list", null, 600000);
        }

        // 在线检查一次要几十秒，不该每次切进本页都自动跑一遍：
        // 进页只提示「点检查更新」，由用户决定什么时候查。
        protected override void OnActivated()
        {
            if (Items.Count == 0 && !Busy)
                SetSum("尚未检查 · 点「检查更新」开始（在线检查可能要几十秒）", "Neutral");
        }

        protected override void OnLoaded(Dictionary<string, object> data)
        {
            _auto = Bridge.Dict(data != null && data.ContainsKey("Auto") ? data["Auto"] : null);
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            string err = Bridge.Str(data, "Error");
            if (err.Length > 0) { SetSum("检查失败：" + Short(err), "Danger"); return; }
            string auto = _auto == null ? "未知" : Bridge.Str(_auto, "Text", "未知");
            int n = Items.Count;
            SetSum(n + " 个待安装 · 自动更新：" + auto, n > 0 ? "Warn" : "Success");
        }

        private static string Short(string s)
        {
            return s.Length > 60 ? s.Substring(0, 60) + "…" : s;
        }

        private void InstallSelected()
        {
            var it = NeedSelected();
            if (it == null) return;
            string index = Bridge.Str(it, "Index");
            if (!Dialogs.Confirm(FindForm(), "安装更新",
                "安装「" + Bridge.Str(it, "Title") + "」？\n\n下载并安装可能要几分钟；需要重启时工具不会自动重启。", "安装"))
                return;
            RunAction("update-install", new Dictionary<string, object> { { "Indexes", index } }, "安装更新");
        }

        private void InstallAll()
        {
            if (Items.Count == 0) { Log("[WARN] 没有待安装的更新，先点「检查更新」"); return; }
            if (!Dialogs.Confirm(FindForm(), "安装全部更新",
                "安装全部 " + Items.Count + " 个更新？\n\n安装期间请不要关闭工具；需要重启时会提示。", "全部安装"))
                return;
            RunAction("update-install", new Dictionary<string, object> { { "All", true } }, "安装全部更新");
        }

        private void ShowHistory()
        {
            ShowText("update-history", null, "已安装更新", (items, data) =>
            {
                var sb = new StringBuilder();
                foreach (var d in items)
                    sb.AppendLine(Bridge.Str(d, "Kb") + "  " + Bridge.Str(d, "InstalledOn") + "  " + Bridge.Str(d, "Description"));
                return sb.Length == 0 ? "没有读到更新记录。" : sb.ToString();
            });
        }

        private void SetAuto()
        {
            int sel = 0;
            int au = _auto == null ? 0 : (int)Bridge.Num(_auto, "AUOptions");
            if (au == 4) sel = 0;
            else if (au == 3) sel = 1;
            else if (au == 2) sel = 2;
            else if (au == 1) sel = 3;
            var v = Dialogs.Prompt(FindForm(), "自动更新策略",
                "当前：" + (_auto == null ? "未知" : Bridge.Str(_auto, "Text", "未知")),
                new List<PromptField>
                {
                    new PromptField("策略", "", new List<string>
                    {
                        "自动下载并安装", "自动下载，手动安装", "仅通知，由管理员安装", "关闭自动更新"
                    }, sel)
                }, "应用");
            if (v == null) return;
            int mode = 1;
            if (v[0].StartsWith("自动下载，")) mode = 2;
            else if (v[0].StartsWith("仅通知")) mode = 3;
            else if (v[0].StartsWith("关闭")) mode = 4;
            RunAction("update-auto", new Dictionary<string, object> { { "Mode", mode } }, "设置自动更新");
        }
    }

    // ============================================================
    // 网络配置
    // ============================================================
    internal sealed class NetworkPage : SysPage
    {
        public NetworkPage()
            : base("network", "网络配置", "网卡 / IP / 网关 / DNS / 路由。改 IP 前会自动把当前配置备份到 backup\\，远程操作请确认还有其它入口。", "network")
        {
            AddBtn("main", "设为 DHCP", ButtonKind.Primary, 96, UseDhcp);
            AddBtn("main", "设置静态 IP", ButtonKind.Normal, 110, SetStatic);
            AddBtn("main", "启用 / 禁用", ButtonKind.Normal, 100, ToggleAdapter);
            AddBtn("main", "重启网卡", ButtonKind.Normal, 92, RestartAdapter);
            AddBtn("main", "DNS 测试", ButtonKind.Ghost, 92, DnsTest);
            AddBtn("main", "路由表", ButtonKind.Ghost, 80, Routes);
            AddBtn("main", "刷新", ButtonKind.Ghost, 72, () => Load());
            SetView("main");
        }

        protected override void BuildColumns()
        {
            AddCol("网卡", 150);
            AddCol("状态", 90);
            AddCol("IP", 190);
            AddCol("网关", 130);
            AddCol("DNS", 190);
            AddCol("DHCP", 70);
            AddCol("速率", 100);
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            return new[]
            {
                Bridge.Str(d, "Name"), Bridge.Str(d, "Status"), Bridge.Str(d, "Ip"),
                Bridge.Str(d, "Gateway"), Bridge.Str(d, "Dns"), Bridge.Str(d, "Dhcp"), Bridge.Str(d, "LinkSpeed")
            };
        }

        protected override void Load() { RunList("network-list", null, 180000); }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            int up = 0;
            foreach (var it in Items) if (Bridge.Str(it, "Status") == "Up") up++;
            SetSum(Items.Count + " 块网卡 · 已连接 " + up, up > 0 ? "Success" : "Warn");
        }

        private string SelName()
        {
            var it = NeedSelected();
            return it == null ? "" : Bridge.Str(it, "Name");
        }

        private void UseDhcp()
        {
            string name = SelName();
            if (name.Length == 0) return;
            if (!Dialogs.Confirm(FindForm(), "切换为 DHCP",
                "把「" + name + "」切换为 DHCP（自动获取 IP / 网关 / DNS）？\n\n如果这是你正在使用的远程连接网卡，切换后可能立刻断线。", "切换"))
                return;
            RunAction("net-set-ip", new Dictionary<string, object> { { "Adapter", name }, { "Dhcp", true } }, "切换为 DHCP");
        }

        private void SetStatic()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            string currentIp = Bridge.Str(it, "Ip");
            // 去掉 /24 后缀，只把地址本身作为默认值
            int slash = currentIp.IndexOf('/');
            if (slash > 0) currentIp = currentIp.Substring(0, slash);
            var v = Dialogs.Prompt(FindForm(), "设置静态 IP",
                "改的是「" + name + "」。远程操作请确认改错了还能通过其它方式进来 —— 工具会先把当前配置备份到 backup\\。",
                new List<PromptField>
                {
                    new PromptField("网卡", name),
                    new PromptField("IP 地址", currentIp),
                    new PromptField("子网前缀长度（24 = 255.255.255.0）", "24"),
                    new PromptField("默认网关（可空）", Bridge.Str(it, "Gateway")),
                    new PromptField("DNS（逗号分隔，可空）", Bridge.Str(it, "Dns"))
                }, "应用");
            if (v == null) return;
            if (v[1].Trim().Length == 0) { Log("[WARN] IP 地址不能为空"); return; }
            int prefix;
            if (!int.TryParse(v[2].Trim(), out prefix) || prefix < 1 || prefix > 32) prefix = 24;
            RunAction("net-set-ip", new Dictionary<string, object>
            {
                { "Adapter", v[0].Trim() }, { "Dhcp", false }, { "Ip", v[1].Trim() },
                { "PrefixLength", prefix }, { "Gateway", v[3].Trim() }, { "Dns", v[4].Trim() }
            }, "设置静态 IP");
        }

        private void ToggleAdapter()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            bool up = Bridge.Str(it, "Status") == "Up";
            string act = up ? "禁用" : "启用";
            if (!Dialogs.Confirm(FindForm(), act + "网卡", "对「" + name + "」执行" + act + "？", act)) return;
            RunAction("net-adapter", new Dictionary<string, object>
            {
                { "Adapter", name }, { "Action", up ? "disable" : "enable" }
            }, act + "网卡");
        }

        private void RestartAdapter()
        {
            string name = SelName();
            if (name.Length == 0) return;
            if (!Dialogs.Confirm(FindForm(), "重启网卡", "重启「" + name + "」？期间会短暂断开。", "重启")) return;
            RunAction("net-adapter", new Dictionary<string, object> { { "Adapter", name }, { "Action", "restart" } }, "重启网卡");
        }

        private void DnsTest()
        {
            var v = Dialogs.Prompt(FindForm(), "DNS 解析测试", "输入域名；DNS 服务器留空表示用系统配置。",
                new List<PromptField>
                {
                    new PromptField("域名", "www.microsoft.com"),
                    new PromptField("DNS 服务器（可空）", "")
                }, "解析", 520);
            if (v == null || v[0].Trim().Length == 0) return;
            ShowText("network-dns", new Dictionary<string, object> { { "Name", v[0].Trim() }, { "Server", v[1].Trim() } },
                "DNS 解析结果", (items, data) =>
                {
                    var sb = new StringBuilder();
                    sb.AppendLine("用时 " + Bridge.Num(data, "Ms") + " ms");
                    foreach (var d in items)
                        sb.AppendLine(Bridge.Str(d, "Name") + "  " + Bridge.Str(d, "Type") + "  " + Bridge.Str(d, "Value"));
                    return sb.ToString();
                }, 60000);
        }

        private void Routes()
        {
            ShowText("network-routes", null, "路由表", (items, data) =>
            {
                var sb = new StringBuilder();
                foreach (var d in items)
                    sb.AppendLine(Bridge.Str(d, "Destination").PadRight(22) + Bridge.Str(d, "NextHop").PadRight(18) +
                                  Bridge.Str(d, "Interface").PadRight(18) + "metric " + Bridge.Num(d, "Metric"));
                return sb.ToString();
            });
        }
    }

    // ============================================================
    // 本地账户
    // ============================================================
    internal sealed class AccountsPage : SysPage
    {
        private Dictionary<string, object> _data;

        public AccountsPage()
            : base("accounts", "本地账户", "本地用户与组：新建 / 启停 / 改密 / 调整组 / 删除，以及登录会话。密码只在本进程内使用。", "accounts")
        {
            AddBtn("main", "新建用户", ButtonKind.Primary, 96, AddUser);
            AddBtn("main", "启用 / 禁用", ButtonKind.Normal, 100, ToggleUser);
            AddBtn("main", "重置密码", ButtonKind.Normal, 92, ResetPassword);
            AddBtn("main", "修改组", ButtonKind.Normal, 84, ChangeGroups);
            AddBtn("main", "删除用户", ButtonKind.Danger, 92, RemoveUser);
            AddBtn("main", "查看本地组", ButtonKind.Ghost, 100, ShowGroups);
            AddBtn("main", "登录会话", ButtonKind.Ghost, 92, ShowSessions);
            AddBtn("main", "刷新", ButtonKind.Ghost, 72, () => Load());
            SetView("main");
            Table.ActivateOnDoubleClick = true;
            Table.RowActivated += idx => ToggleUser();
        }

        protected override void BuildColumns()
        {
            AddCol("用户名", 150);
            AddCol("启用", 70);
            AddCol("最近登录", 160);
            AddCol("所属组", 300);
            AddCol("描述", 280);
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            return new[]
            {
                Bridge.Str(d, "Name"), Bridge.Bool(d, "Enabled") ? "是" : "否",
                Bridge.Str(d, "LastLogon"), Bridge.Str(d, "Groups"), Bridge.Str(d, "Description")
            };
        }

        protected override void Load() { RunList("account-list", null, 180000); }

        protected override void OnLoaded(Dictionary<string, object> data) { _data = data; }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            int disabled = 0;
            foreach (var it in Items) if (!Bridge.Bool(it, "Enabled")) disabled++;
            SetSum(Items.Count + " 个用户 · 禁用 " + disabled, disabled > 0 ? "Warn" : "Success");
        }

        private void AddUser()
        {
            var v = Dialogs.Prompt(FindForm(), "新建本地用户", "密码至少 6 位；组可以留空。",
                new List<PromptField>
                {
                    new PromptField("用户名", ""),
                    new PromptField("密码", "") { Secret = true },
                    new PromptField("描述（可空）", ""),
                    new PromptField("加入组（逗号分隔，可空）", "Remote Desktop Users")
                }, "创建", 560);
            if (v == null) return;
            if (v[0].Trim().Length == 0 || v[1].Length < 6) { Log("[WARN] 用户名不能为空、密码至少 6 位"); return; }
            RunAction("account-add", new Dictionary<string, object>
            {
                { "Name", v[0].Trim() }, { "Password", v[1] },
                { "Description", v[2].Trim() }, { "Groups", v[3].Trim() }
            }, "新建用户");
        }

        private void ToggleUser()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            bool on = Bridge.Bool(it, "Enabled");
            if (!Dialogs.Confirm(FindForm(), on ? "禁用用户" : "启用用户",
                (on ? "禁用" : "启用") + "「" + name + "」？", on ? "禁用" : "启用")) return;
            RunAction("account-update", new Dictionary<string, object>
            {
                { "Name", name }, { "Enabled", on ? "false" : "true" }
            }, (on ? "禁用" : "启用") + "用户");
        }

        private void ResetPassword()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            var v = Dialogs.Prompt(FindForm(), "重置密码", "为「" + name + "」设置新密码（至少 6 位）。",
                new List<PromptField> { new PromptField("新密码", "") { Secret = true } }, "保存", 460);
            if (v == null || v[0].Length < 6) { Log("[WARN] 密码至少 6 位"); return; }
            RunAction("account-update", new Dictionary<string, object> { { "Name", name }, { "Password", v[0] } }, "重置密码");
        }

        private void ChangeGroups()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            var v = Dialogs.Prompt(FindForm(), "修改所属组",
                "当前组：" + Bridge.Str(it, "Groups", "（无）") + "\n\n填新的组列表（逗号分隔）。留空表示不修改；写 \"\" 以外的组会被移出未列出的组。",
                new List<PromptField> { new PromptField("组列表", Bridge.Str(it, "Groups")) }, "保存", 560);
            if (v == null) return;
            RunAction("account-update", new Dictionary<string, object>
            {
                { "Name", name }, { "Groups", v[0].Trim() }
            }, "修改组");
        }

        private void RemoveUser()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            if (!Dialogs.Confirm(FindForm(), "删除用户",
                "从本机删除「" + name + "」？\n\n当前账户与最后一个可用管理员会被拒绝。", "删除")) return;
            RunAction("account-remove", new Dictionary<string, object> { { "Name", name } }, "删除用户");
        }

        private void ShowGroups()
        {
            var groups = _data == null ? new List<Dictionary<string, object>>() : Bridge.List(_data.ContainsKey("Groups") ? _data["Groups"] : null);
            var sb = new StringBuilder();
            sb.AppendLine("管理员组：" + string.Join("、", Bridge.StrList(_data, "Admins").ToArray()));
            sb.AppendLine("远程桌面用户：" + string.Join("、", Bridge.StrList(_data, "RdpUsers").ToArray()));
            sb.AppendLine();
            foreach (var g in groups)
                sb.AppendLine(Bridge.Str(g, "Name") + "（" + Bridge.Num(g, "Count") + " 人）：" + Bridge.Str(g, "Members"));
            Dialogs.Text(FindForm(), "本地组", "来源：本页最近一次读取", sb.ToString());
        }

        private void ShowSessions()
        {
            ShowText("session-list", null, "登录会话", (items, data) =>
            {
                if (items.Count == 0) return "没有读到登录会话。";
                var sb = new StringBuilder();
                foreach (var d in items)
                    sb.AppendLine(Bridge.Str(d, "User") + " / 会话 " + Bridge.Str(d, "Session") +
                                  " / ID " + Bridge.Num(d, "Id") + " / " + Bridge.Str(d, "State") +
                                  " / 空闲 " + Bridge.Str(d, "Idle"));
                return sb.ToString();
            }, 60000);
        }
    }

    // ============================================================
    // 服务管理
    // ============================================================
    internal sealed class ServicesPage : SysPage
    {
        private string _filter = "";

        public ServicesPage()
            : base("services", "服务管理", "全量服务：启停 / 启动类型 / 失败恢复 / 依赖。改完都会回读真实状态。", "services")
        {
            AddBtn("main", "启动", ButtonKind.Primary, 76, () => ServiceAction("start", "启动"));
            AddBtn("main", "停止", ButtonKind.Normal, 76, () => ServiceAction("stop", "停止"));
            AddBtn("main", "重启", ButtonKind.Normal, 76, () => ServiceAction("restart", "重启"));
            AddBtn("main", "启动类型", ButtonKind.Normal, 92, SetStartup);
            AddBtn("main", "失败恢复", ButtonKind.Normal, 92, SetRecovery);
            AddBtn("main", "详情", ButtonKind.Ghost, 72, Detail);
            AddBtn("main", "筛选", ButtonKind.Ghost, 72, SetFilter);
            AddBtn("main", "刷新", ButtonKind.Ghost, 72, () => Load());
            SetView("main");
            Table.ActivateOnDoubleClick = true;
            Table.RowActivated += idx => Detail();
        }

        protected override void BuildColumns()
        {
            AddCol("服务名", 230);
            AddCol("状态", 90);
            AddCol("启动类型", 110);
            AddCol("运行账户", 180);
            AddCol("显示名", 300);
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            return new[]
            {
                Bridge.Str(d, "Name"), Bridge.Str(d, "State"), Bridge.Str(d, "StartMode"),
                Bridge.Str(d, "StartName"), Bridge.Str(d, "DisplayName")
            };
        }

        protected override void Load()
        {
            var args = _filter.Length > 0 ? new Dictionary<string, object> { { "Filter", _filter } } : null;
            RunList("service-list", args, 180000);
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            int running = 0;
            foreach (var it in Items) if (Bridge.Str(it, "State") == "Running") running++;
            SetSum(Items.Count + " 个服务 · 运行 " + running + (_filter.Length > 0 ? " · 筛选：" + _filter : ""),
                   running > 0 ? "Info" : "Neutral");
        }

        private void ServiceAction(string act, string title)
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            if (!Dialogs.Confirm(FindForm(), title + "服务", title + "「" + name + "」？", title)) return;
            RunAction("service-action", new Dictionary<string, object> { { "Names", name }, { "Action", act } }, title + "服务");
        }

        private void SetStartup()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            var v = Dialogs.Prompt(FindForm(), "设置启动类型",
                "当前：" + Bridge.Str(it, "StartMode") + "（" + name + "）",
                new List<PromptField>
                {
                    new PromptField("启动类型", "", new List<string> { "自动", "自动（延迟启动）", "手动", "禁用" }, 0)
                }, "应用", 500);
            if (v == null) return;
            string mode = "auto";
            if (v[0].StartsWith("自动（")) mode = "delayed";
            else if (v[0] == "手动") mode = "manual";
            else if (v[0] == "禁用") mode = "disabled";
            RunAction("service-startup", new Dictionary<string, object> { { "Names", name }, { "Mode", mode } }, "设置启动类型");
        }

        private void SetRecovery()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            var v = Dialogs.Prompt(FindForm(), "设置失败恢复",
                "服务崩溃后自动重启（" + name + "）。",
                new List<PromptField>
                {
                    new PromptField("失败后等待（分钟）", "1"),
                    new PromptField("计数重置（天）", "1")
                }, "应用", 500);
            if (v == null) return;
            int rm, rd;
            if (!int.TryParse(v[0].Trim(), out rm) || rm < 1) rm = 1;
            if (!int.TryParse(v[1].Trim(), out rd) || rd < 1) rd = 1;
            RunAction("service-recovery", new Dictionary<string, object>
            {
                { "Names", name }, { "RestartMinutes", rm }, { "ResetDays", rd }
            }, "设置失败恢复");
        }

        private void Detail()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            ShowText("service-detail", new Dictionary<string, object> { { "Name", name } }, "服务详情：" + name,
                (items, data) =>
                {
                    var sb = new StringBuilder();
                    sb.AppendLine("显示名：" + Bridge.Str(data, "DisplayName"));
                    sb.AppendLine("状态：" + Bridge.Str(data, "State") + " / 启动类型：" + Bridge.Str(data, "StartType"));
                    sb.AppendLine("账户：" + Bridge.Str(data, "Account"));
                    sb.AppendLine("路径：" + Bridge.Str(data, "PathName"));
                    sb.AppendLine();
                    sb.AppendLine("依赖：" + Bridge.Str(data, "DependsOn", "（无）"));
                    sb.AppendLine("被依赖：" + Bridge.Str(data, "Dependents", "（无）"));
                    sb.AppendLine();
                    sb.AppendLine("失败恢复：");
                    sb.AppendLine(Bridge.Str(data, "Failure"));
                    return sb.ToString();
                }, 60000);
        }

        private void SetFilter()
        {
            var v = Dialogs.Prompt(FindForm(), "筛选服务", "按名称或显示名过滤；留空显示全部。",
                new List<PromptField> { new PromptField("关键词", _filter) }, "应用", 460);
            if (v == null) return;
            _filter = v[0].Trim();
            Load();
        }
    }

    // ============================================================
    // 防火墙
    // ============================================================
    internal sealed class FirewallPage : SysPage
    {
        private string _direction = "Inbound";
        private string _filter = "";
        private UiButton _dirBtn;

        public FirewallPage()
            : base("firewall", "防火墙", "入站 / 出站规则：查看、开放端口、启停、删除。需要管理员权限。", "security")
        {
            _dirBtn = AddBtn("main", "方向：入站", ButtonKind.Normal, 104, ToggleDirection);
            AddBtn("main", "开放端口", ButtonKind.Primary, 96, OpenPort);
            AddBtn("main", "启用 / 禁用", ButtonKind.Normal, 100, ToggleRule);
            AddBtn("main", "删除规则", ButtonKind.Danger, 92, RemoveRule);
            AddBtn("main", "筛选", ButtonKind.Ghost, 72, SetFilter);
            AddBtn("main", "刷新", ButtonKind.Ghost, 72, () => Load());
            SetView("main");
        }

        protected override void BuildColumns()
        {
            AddCol("开关", 60);
            AddCol("规则名", 340);
            AddCol("动作", 80);
            AddCol("协议", 80);
            AddCol("端口", 160);
            AddCol("配置文件", 140);
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            return new[]
            {
                Bridge.Bool(d, "Enabled") ? "开" : "关",
                Bridge.Str(d, "DisplayName"), Bridge.Str(d, "Action"),
                Bridge.Str(d, "Protocol"), Bridge.Str(d, "LocalPort"), Bridge.Str(d, "Profile")
            };
        }

        protected override void Load()
        {
            var args = new Dictionary<string, object> { { "Direction", _direction } };
            if (_filter.Length > 0) args["Filter"] = _filter;
            RunList("firewall-list", args, 180000);
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            int on = 0;
            foreach (var it in Items) if (Bridge.Bool(it, "Enabled")) on++;
            SetSum(Items.Count + " 条规则 · 启用 " + on + " · " + (_direction == "Inbound" ? "入站" : "出站"),
                   Items.Count > 0 ? "Info" : "Warn");
        }

        private void ToggleDirection()
        {
            _direction = _direction == "Inbound" ? "Outbound" : "Inbound";
            _dirBtn.Text = "方向：" + (_direction == "Inbound" ? "入站" : "出站");
            _dirBtn.Invalidate();
            Load();
        }

        private void OpenPort()
        {
            var v = Dialogs.Prompt(FindForm(), "开放端口",
                "新建一条入站规则。只放行端口，不会关闭防火墙。",
                new List<PromptField>
                {
                    new PromptField("规则名", "SCM 开放端口 " + DateTime.Now.ToString("MMdd-HHmm")),
                    new PromptField("端口（逗号分隔）", ""),
                    new PromptField("协议", "", new List<string> { "TCP", "UDP" }, 0),
                    new PromptField("动作", "", new List<string> { "允许", "阻止" }, 0),
                    new PromptField("来源地址", "Any")
                }, "创建", 560);
            if (v == null || v[1].Trim().Length == 0) { Log("[WARN] 端口不能为空"); return; }
            RunAction("firewall-open-port", new Dictionary<string, object>
            {
                { "Name", v[0].Trim() }, { "Port", v[1].Trim() },
                { "Protocol", v[2] == "UDP" ? "UDP" : "TCP" },
                { "RuleAction", v[3] == "阻止" ? "Block" : "Allow" },
                { "RemoteAddress", v[4].Trim() }
            }, "开放端口");
        }

        private void ToggleRule()
        {
            var it = NeedSelected();
            if (it == null) return;
            bool on = Bridge.Bool(it, "Enabled");
            RunAction("firewall-toggle", new Dictionary<string, object>
            {
                { "Name", Bridge.Str(it, "Name") }, { "Enabled", !on }
            }, (on ? "禁用" : "启用") + "规则");
        }

        private void RemoveRule()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "DisplayName");
            if (!Dialogs.Confirm(FindForm(), "删除防火墙规则", "删除「" + name + "」？", "删除")) return;
            RunAction("firewall-remove", new Dictionary<string, object> { { "Name", Bridge.Str(it, "Name") } }, "删除规则");
        }

        private void SetFilter()
        {
            var v = Dialogs.Prompt(FindForm(), "筛选防火墙规则", "按显示名或内部名过滤；留空显示全部。",
                new List<PromptField> { new PromptField("关键词", _filter) }, "应用", 460);
            if (v == null) return;
            _filter = v[0].Trim();
            Load();
        }
    }

    // ============================================================
    // 存储与备份
    // ============================================================
    internal sealed class StoragePage : SysPage
    {
        private readonly List<Dictionary<string, object>> _volumes = new List<Dictionary<string, object>>();

        public StoragePage()
            : base("storage", "存储与备份", "磁盘 / 卷 / 临时空间 / 卷影副本 / Windows Server Backup。格式化与初始化都是破坏性操作，会二次确认。", "storage")
        {
            AddTab("disk", "磁盘", 84);
            AddTab("vol", "卷", 84);
            AddTab("vss", "卷影副本", 100);
            var initDisk = AddBtn("disk", "初始化磁盘", ButtonKind.Primary, 100, InitDisk);
            AddBtn("disk", "清理临时文件", ButtonKind.Normal, 110, Cleanup);
            AddBtn("disk", "刷新", ButtonKind.Ghost, 72, () => Load());
            var extendVol = AddBtn("vol", "扩展卷", ButtonKind.Primary, 84, ExtendVolume);
            var formatVol = AddBtn("vol", "格式化", ButtonKind.Danger, 84, FormatVolume);
            AddBtn("vol", "刷新", ButtonKind.Ghost, 72, () => Load());
            AddBtn("vss", "创建快照", ButtonKind.Primary, 96, CreateSnapshot);
            AddBtn("vss", "删除快照", ButtonKind.Danger, 96, RemoveSnapshot);
            AddBtn("vss", "刷新", ButtonKind.Ghost, 72, () => Load());
            // 2008 R2 没有 Storage 模块：这三个写操作直接不展示
            if (AppSettings.IsOld)
            {
                RemoveBtn("disk", initDisk);
                RemoveBtn("vol", extendVol);
                RemoveBtn("vol", formatVol);
                Subtitle = "磁盘 / 卷 / 卷影副本的只读视图（2008 R2 缺 Storage 模块，写操作不可用）。";
            }
            SetView("disk");
            RestyleTabs();
        }

        protected override void BuildColumns()
        {
            if (ViewKey == "vol")
            {
                AddCol("盘符", 70);
                AddCol("卷标", 160);
                AddCol("文件系统", 100);
                AddCol("容量(GB)", 100, true);
                AddCol("可用(GB)", 100, true);
                AddCol("可用%", 80, true);
                AddCol("健康", 100);
            }
            else if (ViewKey == "vss")
            {
                AddCol("创建时间", 180);
                AddCol("来源卷", 200);
                AddCol("设备路径", 420);
            }
            else
            {
                AddCol("编号", 60);
                AddCol("磁盘", 260);
                AddCol("容量(GB)", 100, true);
                AddCol("分区样式", 110);
                AddCol("健康", 100);
                AddCol("总线", 100);
            }
        }

        protected override bool InView(Dictionary<string, object> item)
        {
            return Bridge.Str(item, "Kind") == ViewKey;
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            string kind = Bridge.Str(d, "Kind");
            if (kind == "vol")
                return new[]
                {
                    Bridge.Str(d, "DriveLetter"), Bridge.Str(d, "Label"), Bridge.Str(d, "FileSystem"),
                    Bridge.Num(d, "SizeGB").ToString("0.0"), Bridge.Num(d, "FreeGB").ToString("0.0"),
                    Bridge.Num(d, "FreePercent").ToString("0") + "%", Bridge.Str(d, "Health")
                };
            if (kind == "vss")
                return new[] { Bridge.Str(d, "Created"), Bridge.Str(d, "Volume"), Bridge.Str(d, "Device") };
            return new[]
            {
                Bridge.Num(d, "Number").ToString("0"), Bridge.Str(d, "FriendlyName"),
                Bridge.Num(d, "SizeGB").ToString("0.0"), Bridge.Str(d, "PartitionStyle"),
                Bridge.Str(d, "HealthStatus"), Bridge.Str(d, "BusType")
            };
        }

        protected override void Load()
        {
            if (ViewKey == "vss") { RunList("vss-list", null, 120000); return; }
            SetSum("读取磁盘与卷…", "Info");
            RunList("storage-list", null, 180000);
        }

        protected override void OnLoaded(Dictionary<string, object> data)
        {
            _volumes.Clear();
            _volumes.AddRange(Bridge.List(data != null && data.ContainsKey("Volumes") ? data["Volumes"] : null));
            // storage-list 的 Items 是磁盘，卷在 Data.Volumes：合并成统一列表再按视图过滤
            if (data != null && data.ContainsKey("Volumes"))
            {
                var disks = new List<Dictionary<string, object>>(Items);
                Items.Clear();
                foreach (var d in disks) { d["Kind"] = "disk"; Items.Add(d); }
                foreach (var v in _volumes) { v["Kind"] = "vol"; Items.Add(v); }
            }
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            if (ViewKey == "vss") { SetSum(Items.Count + " 个卷影副本", Items.Count > 0 ? "Info" : "Neutral"); return; }
            int low = 0;
            foreach (var v in _volumes) if (Bridge.Num(v, "FreePercent") > 0 && Bridge.Num(v, "FreePercent") < 10) low++;
            SetSum(_volumes.Count + " 个卷" + (low > 0 ? " · " + low + " 个可用空间不足 10%" : ""), low > 0 ? "Warn" : "Success");
        }

        private void InitDisk()
        {
            var it = NeedSelected();
            if (it == null) return;
            int num = (int)Bridge.Num(it, "Number", -1);
            if (!Dialogs.Confirm(FindForm(), "初始化磁盘",
                "把磁盘 " + num + "（" + Bridge.Str(it, "FriendlyName") + "）初始化为 GPT？\n\n已有分区表的磁盘会被拒绝，数据不会被动。", "初始化")) return;
            RunAction("storage-volume", new Dictionary<string, object> { { "VolumeAction", "initialize" }, { "DiskNumber", num } }, "初始化磁盘");
        }

        private void Cleanup()
        {
            if (!Dialogs.Confirm(FindForm(), "清理临时文件",
                "清理 %TEMP%、Windows\\Temp 与 SoftwareDistribution\\Download 里 1 天前的文件？", "清理")) return;
            RunAction("storage-cleanup", new Dictionary<string, object> { { "OlderThanDays", 1 } }, "清理临时文件");
        }

        private void ExtendVolume()
        {
            var it = NeedSelected();
            if (it == null) return;
            string letter = Bridge.Str(it, "DriveLetter");
            if (letter.Length == 0) { Log("[WARN] 这个卷没有盘符，无法扩展"); return; }
            if (!Dialogs.Confirm(FindForm(), "扩展卷", "把 " + letter + ": 扩展到磁盘可用最大值？", "扩展")) return;
            RunAction("storage-volume", new Dictionary<string, object> { { "VolumeAction", "extend" }, { "DriveLetter", letter } }, "扩展卷");
        }

        private void FormatVolume()
        {
            var it = NeedSelected();
            if (it == null) return;
            string letter = Bridge.Str(it, "DriveLetter");
            if (letter.Length == 0) { Log("[WARN] 这个卷没有盘符，无法格式化"); return; }
            var v = Dialogs.Prompt(FindForm(), "格式化 " + letter + ":",
                "这会清空 " + letter + ": 上的全部数据，无法撤销。",
                new List<PromptField>
                {
                    new PromptField("文件系统", "", new List<string> { "NTFS", "ReFS", "exFAT" }, 0),
                    new PromptField("卷标（可空）", Bridge.Str(it, "Label"))
                }, "格式化", 520);
            if (v == null) return;
            if (!Dialogs.Confirm(FindForm(), "确认格式化", "再确认一次：格式化 " + letter + ": 会清空全部数据。", "格式化")) return;
            RunAction("storage-volume", new Dictionary<string, object>
            {
                { "VolumeAction", "format" }, { "DriveLetter", letter },
                { "FileSystem", v[0] }, { "Label", v[1].Trim() }
            }, "格式化卷");
        }

        private void CreateSnapshot()
        {
            var v = Dialogs.Prompt(FindForm(), "创建卷影副本", "为哪个卷创建快照？",
                new List<PromptField> { new PromptField("卷", "C:\\") }, "创建", 460);
            if (v == null) return;
            RunAction("vss-create", new Dictionary<string, object> { { "Volume", v[0].Trim() } }, "创建卷影副本");
        }

        private void RemoveSnapshot()
        {
            var it = NeedSelected();
            if (it == null) return;
            string id = Bridge.Str(it, "Id");
            if (!Dialogs.Confirm(FindForm(), "删除卷影副本", "删除卷影副本 " + id + "？", "删除")) return;
            RunAction("vss-remove", new Dictionary<string, object> { { "ShadowId", id } }, "删除卷影副本");
        }
    }

    // ============================================================
    // 系统计划任务
    // ============================================================
    internal sealed class SysTasksPage : SysPage
    {
        private string _filter = "";

        public SysTasksPage()
            : base("systasks", "系统任务", "Windows 计划任务：启停 / 立即运行 / 停止 / 删除 / 详情。本工具自建的 ScmOps-* 请到「自动化」页管理。", "tasks")
        {
            AddBtn("main", "立即运行", ButtonKind.Primary, 96, () => TaskAction("run", "运行"));
            AddBtn("main", "启用", ButtonKind.Normal, 72, () => TaskAction("enable", "启用"));
            AddBtn("main", "禁用", ButtonKind.Normal, 72, () => TaskAction("disable", "禁用"));
            AddBtn("main", "停止", ButtonKind.Normal, 72, () => TaskAction("stop", "停止"));
            AddBtn("main", "删除", ButtonKind.Danger, 72, () => TaskAction("remove", "删除"));
            AddBtn("main", "详情", ButtonKind.Ghost, 72, Detail);
            AddBtn("main", "筛选", ButtonKind.Ghost, 72, SetFilter);
            AddBtn("main", "刷新", ButtonKind.Ghost, 72, () => Load());
            SetView("main");
            Table.ActivateOnDoubleClick = true;
            Table.RowActivated += idx => Detail();
        }

        protected override void BuildColumns()
        {
            AddCol("状态", 90);
            AddCol("路径", 200);
            AddCol("任务名", 380);
            AddCol("最近运行", 150);
            AddCol("结果", 100, true);
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            return new[]
            {
                Bridge.Str(d, "State"), Bridge.Str(d, "Path"), Bridge.Str(d, "Name"),
                Bridge.Str(d, "LastRun"), Bridge.Num(d, "LastResult").ToString("0")
            };
        }

        protected override void Load()
        {
            var args = new Dictionary<string, object>();
            if (_filter.Length > 0) args["Filter"] = _filter;
            RunList("systask-list", args, 180000);
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            SetSum(Items.Count + " 个任务" + (_filter.Length > 0 ? " · 筛选：" + _filter : ""), Items.Count > 0 ? "Info" : "Neutral");
        }

        private void TaskAction(string act, string title)
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            string path = Bridge.Str(it, "TaskPath", "\\");
            if (act == "remove" && !Dialogs.Confirm(FindForm(), "删除计划任务", "删除「" + path + name + "」？", "删除")) return;
            if (act == "run" && !Dialogs.Confirm(FindForm(), "立即运行", "立即运行「" + path + name + "」？", "运行")) return;
            RunAction("systask-action", new Dictionary<string, object>
            {
                { "Name", name }, { "TaskPath", path }, { "TaskAction", act }
            }, title + "计划任务");
        }

        private void Detail()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            string path = Bridge.Str(it, "TaskPath", "\\");
            ShowText("systask-detail", new Dictionary<string, object> { { "Name", name }, { "TaskPath", path } },
                "计划任务详情：" + name, (items, data) =>
                {
                    var sb = new StringBuilder();
                    sb.AppendLine("路径：" + Bridge.Str(data, "Path") + Bridge.Str(data, "Name"));
                    sb.AppendLine("状态：" + Bridge.Str(data, "State") + " / 账户：" + Bridge.Str(data, "UserId") +
                                  " / 权限：" + Bridge.Str(data, "RunLevel"));
                    sb.AppendLine("触发器：" + Bridge.Str(data, "Triggers"));
                    sb.AppendLine("动作：" + Bridge.Str(data, "Actions"));
                    sb.AppendLine("最近运行：" + Bridge.Str(data, "LastRun") + "（结果 " + Bridge.Str(data, "LastResult") + "）");
                    sb.AppendLine("下次运行：" + Bridge.Str(data, "NextRun"));
                    return sb.ToString();
                }, 60000);
        }

        private void SetFilter()
        {
            var v = Dialogs.Prompt(FindForm(), "筛选计划任务", "按任务名或路径过滤；留空显示全部。",
                new List<PromptField> { new PromptField("关键词", _filter) }, "应用", 460);
            if (v == null) return;
            _filter = v[0].Trim();
            Load();
        }
    }

    // ============================================================
    // 角色工具（Hyper-V / IIS / 打印 / SMB 共享）
    // ============================================================
    internal sealed class RoleToolsPage : SysPage
    {
        private bool _available = true;
        private List<Dictionary<string, object>> _pools = new List<Dictionary<string, object>>();
        private List<Dictionary<string, object>> _sessions = new List<Dictionary<string, object>>();
        private List<Dictionary<string, object>> _openFiles = new List<Dictionary<string, object>>();

        public RoleToolsPage()
            : base("roletools", "角色工具", "Hyper-V / IIS / 打印 / SMB 共享：只显示本机装了的角色；没装会提示去「角色与功能」补。", "role")
        {
            AddTab("hyperv", "Hyper-V", 96);
            AddTab("iis", "IIS", 72);
            AddTab("print", "打印", 72);
            AddTab("share", "SMB 共享", 92);
            AddBtn("hyperv", "启动", ButtonKind.Primary, 72, () => Vm("start", "启动"));
            AddBtn("hyperv", "关机", ButtonKind.Normal, 72, () => Vm("shutdown", "关机"));
            AddBtn("hyperv", "强制关闭", ButtonKind.Danger, 92, () => Vm("stop", "强制关闭"));
            AddBtn("hyperv", "保存", ButtonKind.Normal, 72, () => Vm("save", "保存"));
            AddBtn("hyperv", "快照", ButtonKind.Ghost, 72, Snapshot);
            AddBtn("hyperv", "刷新", ButtonKind.Ghost, 72, () => Load());
            AddBtn("iis", "启动站点", ButtonKind.Primary, 88, () => Iis("site-start", "启动站点"));
            AddBtn("iis", "停止站点", ButtonKind.Normal, 88, () => Iis("site-stop", "停止站点"));
            AddBtn("iis", "重启站点", ButtonKind.Normal, 88, () => Iis("site-restart", "重启站点"));
            AddBtn("iis", "应用池", ButtonKind.Ghost, 84, ShowPools);
            AddBtn("iis", "刷新", ButtonKind.Ghost, 72, () => Load());
            AddBtn("print", "暂停", ButtonKind.Normal, 72, () => Printer("pause", "暂停打印机"));
            AddBtn("print", "恢复", ButtonKind.Normal, 72, () => Printer("resume", "恢复打印机"));
            AddBtn("print", "清空队列", ButtonKind.Danger, 92, () => Printer("clear-jobs", "清空打印队列"));
            AddBtn("print", "刷新", ButtonKind.Ghost, 72, () => Load());
            AddBtn("share", "新建共享", ButtonKind.Primary, 96, AddShare);
            AddBtn("share", "删除共享", ButtonKind.Danger, 92, RemoveShare);
            AddBtn("share", "会话 / 打开文件", ButtonKind.Ghost, 130, ShowSessions);
            AddBtn("share", "刷新", ButtonKind.Ghost, 72, () => Load());
            SetView("hyperv");
            RestyleTabs();
        }

        protected override void BuildColumns()
        {
            switch (ViewKey)
            {
                case "iis":
                    AddCol("站点", 240);
                    AddCol("状态", 100);
                    AddCol("绑定", 420);
                    break;
                case "print":
                    AddCol("打印机", 240);
                    AddCol("状态", 120);
                    AddCol("驱动", 220);
                    AddCol("端口", 140);
                    AddCol("作业", 70, true);
                    break;
                case "share":
                    AddCol("共享名", 160);
                    AddCol("路径", 340);
                    AddCol("在线用户", 90, true);
                    AddCol("说明", 220);
                    break;
                default:
                    AddCol("虚拟机", 200);
                    AddCol("状态", 110);
                    AddCol("CPU%", 70, true);
                    AddCol("内存(MB)", 90, true);
                    AddCol("运行时长", 120);
                    AddCol("代", 60);
                    break;
            }
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            switch (ViewKey)
            {
                case "iis":
                    return new[] { Bridge.Str(d, "Name"), Bridge.Str(d, "State"), Bridge.Str(d, "Bindings") };
                case "print":
                    return new[]
                    {
                        Bridge.Str(d, "Name"), Bridge.Str(d, "Status"), Bridge.Str(d, "Driver"),
                        Bridge.Str(d, "Port"), Bridge.Num(d, "Jobs").ToString("0")
                    };
                case "share":
                    return new[]
                    {
                        Bridge.Str(d, "Name"), Bridge.Str(d, "Path"),
                        Bridge.Num(d, "Users").ToString("0"), Bridge.Str(d, "Description")
                    };
                default:
                    return new[]
                    {
                        Bridge.Str(d, "Name"), Bridge.Str(d, "State"), Bridge.Num(d, "CPU").ToString("0"),
                        Bridge.Num(d, "MemoryMB").ToString("0"), Bridge.Str(d, "Uptime"), Bridge.Num(d, "Generation").ToString("0")
                    };
            }
        }

        protected override void Load()
        {
            // 不在页面里再套一层「先检测角色、再读列表」的链式调用：
            // 每个列表 runner 本身就会返回 Available，一次子进程拿全。
            LoadView();
        }

        private void LoadView()
        {
            _pools.Clear();
            _sessions.Clear();
            _openFiles.Clear();
            switch (ViewKey)
            {
                case "iis": RunList("iis-list", null, 120000); break;
                case "print": RunList("print-list", null, 120000); break;
                case "share": RunList("share-list", null, 120000); break;
                default: RunList("hyperv-list", null, 180000); break;
            }
        }

        protected override void OnLoaded(Dictionary<string, object> data)
        {
            if (data == null) return;
            _available = Bridge.Bool(data, "Available", true);
            if (data.ContainsKey("Pools")) _pools = Bridge.List(data["Pools"]);
            if (data.ContainsKey("Sessions")) _sessions = Bridge.List(data["Sessions"]);
            if (data.ContainsKey("OpenFiles")) _openFiles = Bridge.List(data["OpenFiles"]);
        }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            if (!_available)
            {
                SetSum("本机未安装该角色（角色与功能页可装）", "Warn");
                return;
            }
            SetSum(Items.Count + " 条", Items.Count > 0 ? "Info" : "Neutral");
        }

        private void Vm(string act, string title)
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            if (!Dialogs.Confirm(FindForm(), title + "虚拟机", title + "「" + name + "」？", title)) return;
            RunAction("hyperv-action", new Dictionary<string, object> { { "Name", name }, { "VmAction", act } }, title + "虚拟机");
        }

        private void Snapshot()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            var v = Dialogs.Prompt(FindForm(), "虚拟机快照",
                "对「" + name + "」创建快照。",
                new List<PromptField>
                {
                    new PromptField("操作", "", new List<string> { "创建", "应用（还原）", "删除" }, 0),
                    new PromptField("快照名", "SCM-" + DateTime.Now.ToString("MMdd-HHmm"))
                }, "执行", 520);
            if (v == null) return;
            string act = v[0].StartsWith("应用") ? "apply" : (v[0] == "删除" ? "remove" : "create");
            RunAction("hyperv-snapshot", new Dictionary<string, object>
            {
                { "SnapshotAction", act }, { "VmName", name }, { "SnapshotName", v[1].Trim() }
            }, "虚拟机快照");
        }

        private void Iis(string act, string title)
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            if (!Dialogs.Confirm(FindForm(), title, title + "「" + name + "」？", title)) return;
            RunAction("iis-action", new Dictionary<string, object> { { "IisAction", act }, { "Name", name } }, title);
        }

        private void ShowPools()
        {
            if (_pools.Count == 0) { Log("[INFO] 没有读到应用池"); return; }
            var sb = new StringBuilder();
            foreach (var p in _pools) sb.AppendLine(Bridge.Str(p, "Name") + "  " + Bridge.Str(p, "State") + "  " + Bridge.Str(p, "Runtime"));
            Dialogs.Text(FindForm(), "IIS 应用池", "回收 / 启停请在「全部功能 → 角色工具」里执行", sb.ToString());
        }

        private void Printer(string act, string title)
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            if (!Dialogs.Confirm(FindForm(), title, title + "「" + name + "」？", title)) return;
            RunAction("print-action", new Dictionary<string, object> { { "Name", name }, { "PrintAction", act } }, title);
        }

        private void AddShare()
        {
            var v = Dialogs.Prompt(FindForm(), "新建 SMB 共享", "目录必须已存在；默认给 Administrators 完全控制。",
                new List<PromptField>
                {
                    new PromptField("共享名", ""),
                    new PromptField("目录", ""),
                    new PromptField("描述（可空）", ""),
                    new PromptField("完全控制（账户或组）", "Administrators")
                }, "创建", 560);
            if (v == null || v[0].Trim().Length == 0 || v[1].Trim().Length == 0) { Log("[WARN] 共享名和目录都要填"); return; }
            RunAction("share-add", new Dictionary<string, object>
            {
                { "Name", v[0].Trim() }, { "Path", v[1].Trim() },
                { "Description", v[2].Trim() }, { "FullAccess", v[3].Trim() }
            }, "新建共享");
        }

        private void RemoveShare()
        {
            var it = NeedSelected();
            if (it == null) return;
            string name = Bridge.Str(it, "Name");
            if (!Dialogs.Confirm(FindForm(), "删除共享", "删除共享「" + name + "」？（目录内容不动）", "删除")) return;
            RunAction("share-remove", new Dictionary<string, object> { { "Name", name } }, "删除共享");
        }

        private void ShowSessions()
        {
            var sb = new StringBuilder();
            sb.AppendLine("会话：");
            foreach (var s in _sessions)
                sb.AppendLine("  " + Bridge.Str(s, "Client") + " / " + Bridge.Str(s, "User") + " / 打开 " + Bridge.Num(s, "Opens"));
            sb.AppendLine();
            sb.AppendLine("打开的文件：");
            foreach (var f in _openFiles)
                sb.AppendLine("  " + Bridge.Str(f, "Client") + " / " + Bridge.Str(f, "User") + " / " + Bridge.Str(f, "Path"));
            Dialogs.Text(FindForm(), "SMB 会话与打开文件", "要强制断开请到「全部功能 → 角色工具 → 断开 SMB 打开的文件」", sb.ToString());
        }
    }

    // ============================================================
    // 通知
    // ============================================================
    internal sealed class NotifyPage : SysPage
    {
        private Dictionary<string, object> _cfg;

        public NotifyPage()
            : base("notify", "通知", "SMTP / Webhook（钉钉 / 飞书 / 企业微信 / 通用 JSON）。守护启动失败、端口巡检异常会自动发通知。", "notify")
        {
            AddBtn("main", "配置通知", ButtonKind.Primary, 100, Configure);
            AddBtn("main", "发送测试", ButtonKind.Normal, 96, () => RunAction("notify-test", new Dictionary<string, object>(), "发送测试通知"));
            AddBtn("main", "发送自定义", ButtonKind.Normal, 104, SendCustom);
            AddBtn("main", "刷新", ButtonKind.Ghost, 72, () => Load());
            SetView("main");
        }

        protected override void BuildColumns()
        {
            AddCol("时间", 190);
            AddCol("级别", 80);
            AddCol("标题", 330);
            AddCol("结果", 300);
        }

        protected override string[] Cells(Dictionary<string, object> d)
        {
            return new[]
            {
                Bridge.Str(d, "Time").Replace("T", " "), Bridge.Str(d, "Level"), Bridge.Str(d, "Title"),
                Bridge.Bool(d, "Sent") ? Bridge.Str(d, "Channels") : "未发送：" + Bridge.Str(d, "Error")
            };
        }

        protected override void Load() { RunList("notify-status", null, 60000); }

        protected override void OnLoaded(Dictionary<string, object> data) { _cfg = data; }

        protected override void ApplyState(Dictionary<string, object> data)
        {
            bool on = data != null && Bridge.Bool(data, "Enabled");
            SetSum((on ? "已启用" : "未启用") + " · 最近 " + Items.Count + " 条", on ? "Success" : "Warn");
        }

        private void Configure()
        {
            string curType = _cfg == null ? "generic" : Bridge.Str(_cfg, "WebhookType", "generic");
            int typeIdx = 1;
            if (curType == "dingtalk") typeIdx = 2;
            else if (curType == "feishu") typeIdx = 3;
            else if (curType == "wecom") typeIdx = 4;

            var v = Dialogs.Prompt(FindForm(), "通知配置",
                "留空的项保持原值；密码不会回显。Webhook 类型选「保持不变」表示不改。",
                new List<PromptField>
                {
                    new PromptField("通知开关", "", new List<string> { "保持不变", "启用", "禁用" },
                                    _cfg != null && Bridge.Bool(_cfg, "Enabled") ? 1 : 0),
                    new PromptField("SMTP 服务器", _cfg == null ? "" : Bridge.Str(_cfg, "SmtpServer")),
                    new PromptField("SMTP 端口", _cfg == null ? "587" : Bridge.Str(_cfg, "SmtpPort", "587")),
                    new PromptField("SMTP SSL", "", new List<string> { "保持不变", "是", "否" },
                                    _cfg != null && Bridge.Bool(_cfg, "SmtpSsl") ? 1 : 0),
                    new PromptField("SMTP 用户名", _cfg == null ? "" : Bridge.Str(_cfg, "SmtpUser")),
                    new PromptField("SMTP 密码（留空不改）", "") { Secret = true },
                    new PromptField("发件人", _cfg == null ? "" : Bridge.Str(_cfg, "SmtpFrom")),
                    new PromptField("收件人（逗号分隔）", _cfg == null ? "" : Bridge.Str(_cfg, "SmtpTo")),
                    new PromptField("Webhook 类型", "", new List<string>
                    {
                        "保持不变", "generic（通用 JSON）", "dingtalk（钉钉）", "feishu（飞书）", "wecom（企业微信）"
                    }, typeIdx),
                    new PromptField("Webhook 地址", _cfg == null ? "" : Bridge.Str(_cfg, "WebhookUrl")),
                    new PromptField("静默开始（HH:mm）", _cfg == null ? "" : Bridge.Str(_cfg, "QuietFrom")),
                    new PromptField("静默结束（HH:mm）", _cfg == null ? "" : Bridge.Str(_cfg, "QuietTo"))
                }, "保存", 620);
            if (v == null) return;

            string enabled = "";
            if (v[0] == "启用") enabled = "true";
            else if (v[0] == "禁用") enabled = "false";
            string ssl = "";
            if (v[3] == "是") ssl = "true";
            else if (v[3] == "否") ssl = "false";
            string type = "";
            if (v[8].StartsWith("generic")) type = "generic";
            else if (v[8].StartsWith("dingtalk")) type = "dingtalk";
            else if (v[8].StartsWith("feishu")) type = "feishu";
            else if (v[8].StartsWith("wecom")) type = "wecom";

            var args = new Dictionary<string, object>
            {
                { "Enabled", enabled }, { "SmtpServer", v[1].Trim() }, { "SmtpPort", v[2].Trim() },
                { "SmtpSsl", ssl }, { "SmtpUser", v[4].Trim() }, { "SmtpPassword", v[5] },
                { "SmtpFrom", v[6].Trim() }, { "SmtpTo", v[7].Trim() },
                { "WebhookType", type }, { "WebhookUrl", v[9].Trim() },
                { "QuietFrom", v[10].Trim() }, { "QuietTo", v[11].Trim() }
            };
            RunAction("notify-config", args, "保存通知配置");
        }

        private void SendCustom()
        {
            var v = Dialogs.Prompt(FindForm(), "发送自定义通知", "会发到已配置的所有渠道。",
                new List<PromptField>
                {
                    new PromptField("标题", "SCM 通知"),
                    new PromptField("正文", "", true),
                    new PromptField("级别", "", new List<string> { "Info", "Warn", "Error" }, 0)
                }, "发送", 540);
            if (v == null) return;
            RunAction("notify-send", new Dictionary<string, object>
            {
                { "Title", v[0].Trim() }, { "Text", v[1] }, { "Level", v[2] }
            }, "发送通知");
        }
    }
}

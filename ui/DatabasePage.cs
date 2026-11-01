using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 数据库：PostgreSQL 的 Windows 原生落地（无容器、无安装器）。
    // 列表来自 gui\Run-GuiReadyDatabase.ps1 -Mode list，行分三种：
    //   可安装的版本 / 已解压待初始化的版本 / 已初始化的实例。
    // 安装、初始化、服务、备份都走 actions（db-*），日志实时回到下方日志栏。
    // ============================================================
    internal sealed class DatabasePage : PageBase
    {
        private sealed class Row
        {
            public string Kind = "";        // version / instance
            public string Engine = "";      // postgresql / mysql
            public string Version = "";
            public string Id = "";
            public string Service = "";
            public string ServiceState = "";
            public int Port;
            public bool Online;
            public bool Installed;
            public bool HasInstance;
            public string DataDir = "";
            public string Note = "";
            public string Label = "";
        }

        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Row> _rows = new List<Row>();
        private string _dataRoot = "";
        private string _root = "";
        private bool _busy;

        public DatabasePage()
        {
            Key = "database";
            TitleText = "数据库";
            Subtitle = "PostgreSQL / MySQL 8 原生落地：官方 zip 解压即用，initdb / initialize 建实例，注册成 Windows 服务 —— 不用容器，也不用安装器。";
            Glyph = "database";
            Accent = Theme.AccentOf("database");

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn("实例 / 版本", 210));
            _table.Columns.Add(new DataColumn("版本", 100));
            _table.Columns.Add(new DataColumn("端口", 70));
            _table.Columns.Add(new DataColumn("服务", 180));
            _table.Columns.Add(new DataColumn("状态", 150));
            _table.Columns.Add(new DataColumn("说明", 380));
            _table.ActivateOnDoubleClick = true;
            _table.RowActivated += ActivateRow;
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton("安装版本", ButtonKind.Primary, 100, InstallSelected);
            AddButton("初始化实例", ButtonKind.Primary, 112, InitSelected);
            AddButton("启动服务", ButtonKind.Normal, 96, () => ServiceSelected(1));
            AddButton("停止服务", ButtonKind.Normal, 96, () => ServiceSelected(4));
            AddButton("备份", ButtonKind.Normal, 80, BackupSelected);
            AddButton("还原…", ButtonKind.Normal, 88, RestoreSelected);
            AddButton("建库…", ButtonKind.Normal, 88, CreateDbSelected);
            AddButton("注销服务", ButtonKind.Danger, 100, UnregisterSelected);
            AddButton("刷新", ButtonKind.Normal, 80, Load);
            AddButton("打开数据目录", ButtonKind.Ghost, 116, OpenDataDir);
        }

        private void AddButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 0) };
            b.Click += (s, e) => onClick();
            _buttons.Add(b);
            _actions.Controls.Add(b);
        }

        protected override void BuildContent() { }

        protected override void OnActivated()
        {
            Load();
        }

        // ---------------------------------------------------------- 读取
        private void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState("读取中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadyDatabase.ps1", "list", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        Fill(items, data);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 数据库状态读取失败: " + err);
                }), 180000);
        }

        private void Fill(List<Dictionary<string, object>> items, Dictionary<string, object> data)
        {
            string root = Bridge.Str(data, "Root");
            string dataRoot = Bridge.Str(data, "DataRoot");
            if (root.Length > 0) _root = root;
            if (dataRoot.Length > 0) _dataRoot = dataRoot;

            _rows.Clear();
            var rows = new List<string[]>();
            int instances = 0, running = 0, installed = 0;

            // 先放实例行，再放版本行 —— 用户最关心「我的库在哪、服务在不在跑」
            foreach (var it in items)
            {
                if (Bridge.Str(it, "Kind") != "instance") continue;
                instances++;
                string state = ServiceText(Bridge.Str(it, "ServiceState"));
                bool online = Bridge.Bool(it, "Online");
                bool live = Bridge.Str(it, "ServiceState") == "Running" || Bridge.Str(it, "ServiceState") == "手工运行";
                if (live) running++;
                string stateText = state + (live ? (online ? " · 可连接" : " · 端口不通") : "");

                double size = Bridge.Num(it, "SizeMB");
                int backups = (int)Bridge.Num(it, "Backups");
                string last = Bridge.Str(it, "LastBackup");
                string note = size > 0 ? size.ToString("0.0") + " MB" : "空";
                note += " · 备份 " + backups + " 个";
                if (last.Length > 0) note += "（最近 " + last + "）";
                string dataDir = Bridge.Str(it, "DataDir");
                if (dataDir.Length > 0) note += " · " + dataDir;

                var r = new Row
                {
                    Kind = "instance",
                    Engine = Bridge.Str(it, "Engine"),
                    Id = Bridge.Str(it, "Id"),
                    Version = Bridge.Str(it, "Version"),
                    Label = Bridge.Str(it, "Name", Bridge.Str(it, "Id")),
                    Port = (int)Bridge.Num(it, "Port"),
                    Service = Bridge.Str(it, "Service"),
                    ServiceState = Bridge.Str(it, "ServiceState"),
                    Online = online,
                    Installed = true,
                    HasInstance = true,
                    DataDir = dataDir,
                    Note = note
                };
                rows.Add(new[] { r.Label, r.Version, r.Port > 0 ? r.Port.ToString() : "", r.Service, stateText, note });
                _rows.Add(r);
            }

            foreach (var it in items)
            {
                if (Bridge.Str(it, "Kind") != "version") continue;
                bool ok = Bridge.Bool(it, "Installed");
                if (ok) installed++;
                int count = (int)Bridge.Num(it, "Instances");
                string ver = Bridge.Str(it, "Version");
                string label = Bridge.Str(it, "Name", "PostgreSQL " + ver);
                string state = ok ? "已解压" : "未安装";
                if (ok && count == 0) state = "待初始化";
                string note = ok ? Bridge.Str(it, "BinDir") : (Bridge.Str(it, "Size") + " · " + Bridge.Str(it, "Note"));

                var r = new Row
                {
                    Kind = "version",
                    Engine = Bridge.Str(it, "Engine"),
                    Version = ver,
                    Label = label,
                    Installed = ok,
                    HasInstance = count > 0,
                    Note = note
                };
                rows.Add(new[] { label, r.Version, "—", "—", state, note });
                _rows.Add(r);
            }

            _table.SetRows(rows, true);
            if (rows.Count == 0)
            {
                SetState("清单为空", "Warn");
                return;
            }
            string text = instances > 0
                ? instances + " 个实例 · " + running + " 个在运行 · 已解压 " + installed + " 个版本"
                : "未初始化实例 · 已解压 " + installed + " 个版本";
            SetState(text, running > 0 ? "Success" : (instances > 0 ? "Info" : "Neutral"));
            Log("[INFO] 数据库：" + text + "；目录 " + _root);
        }

        private static string ServiceText(string state)
        {
            switch (state)
            {
                case "Running": return "运行中";
                case "Stopped": return "已停止";
                case "StartPending": return "启动中";
                case "StopPending": return "停止中";
                case "未注册": return "未注册";
                case "": return "未注册";
                default: return state;
            }
        }

        // ---------------------------------------------------------- 操作
        private void ActivateRow(int idx)
        {
            var r = RowAt(idx);
            if (r == null) return;
            if (r.Kind == "instance")
                Log("[INFO] " + r.Label + "：" + r.Service + " · 端口 " + r.Port + " · " + r.DataDir);
            else
                Log("[INFO] " + r.Label + "：" + (r.Installed ? "已解压（" + r.Note + "）" : "未安装（" + r.Note + "）"));
        }

        private Row RowAt(int idx)
        {
            if (idx < 0 || idx >= _rows.Count) return null;
            return _rows[idx];
        }

        private Row Selected()
        {
            return RowAt(_table.SelectedIndex);
        }

        private void InstallSelected()
        {
            var r = Selected();
            if (r == null) { Log("[WARN] 先在列表里选一个数据库版本"); return; }
            if (r.Installed) { Log("[INFO] " + r.Label + " 已经解压好了"); return; }

            string msg = "下载并解压 " + r.Label + "？\r\n\r\n" +
                         "位置：" + _root + "\\" + (r.Engine == "mysql" ? "mysql" : "postgresql") + "\\" + r.Version + "\r\n" +
                         "安装包约 250-330 MB（官方源），服务器上可能要等几分钟。\r\n" +
                         "解压完还需要「初始化实例」才算能用。";
            if (!Dialogs.Confirm(FindForm(), "安装数据库", msg, "开始下载")) return;

            var args = new Dictionary<string, object>();
            args["Engine"] = r.Engine;
            args["Version"] = r.Version;
            RunAction("db-install", args, "安装 " + r.Label);
        }

        private void InitSelected()
        {
            var r = Selected();
            if (r == null) { Log("[WARN] 先在列表里选一个已解压的版本"); return; }
            if (r.Kind == "instance") { Log("[WARN] 这一行已经是实例了；先选「" + r.Label + "」上面那个版本行"); return; }
            if (!r.Installed) { Log("[WARN] " + r.Label + " 还没解压，先点「安装版本」"); return; }

            bool mysql = r.Engine == "mysql";
            var fields = new List<PromptField>
            {
                new PromptField("端口", "", false, mysql ? "例如 3306；留空 = 自动挑一个空闲端口" : "例如 5432；留空 = 自动挑一个空闲端口"),
                new PromptField(mysql ? "root 用户密码" : "postgres 用户密码", "", false, "至少 6 位；用 DPAPI 加密后存进实例记录")
            };
            fields[1].Secret = true;
            string[] v = Dialogs.Prompt(FindForm(), "初始化 " + r.Label,
                mysql
                    ? "会在 data\\mysql\\" + r.Version + "-<端口> 建数据目录并生成 my.ini；MySQL 服务账号是 LocalSystem。"
                    : "会在 data\\postgresql\\" + r.Version + "-<端口> 建数据目录，并给 NetworkService 授权。",
                fields, "初始化");
            if (v == null) return;
            if (v[1].Length < 6) { Log("[WARN] 密码至少 6 位"); return; }

            int port = 0;
            if (v[0].Trim().Length > 0 && !int.TryParse(v[0].Trim(), out port))
            {
                Log("[WARN] 端口要填数字");
                return;
            }

            var args = new Dictionary<string, object>();
            args["Engine"] = r.Engine;
            args["Version"] = r.Version;
            args["Port"] = port;
            args["Password"] = v[1];
            RunAction("db-init", args, "初始化 " + r.Label);
        }

        private void ServiceSelected(int actionIndex)
        {
            var r = Selected();
            if (r == null || r.Kind != "instance") { Log("[WARN] 先选中一个实例行"); return; }
            if (actionIndex == 4 && r.ServiceState != "Running")
            {
                Log("[INFO] 服务当前是「" + ServiceText(r.ServiceState) + "」，不用停");
                return;
            }
            var args = new Dictionary<string, object>();
            args["Id"] = r.Id;
            args["Action"] = actionIndex;
            string title = actionIndex == 4 ? "停止服务 " : "启动服务 ";
            RunAction("db-service", args, title + r.Label);
        }

        private void UnregisterSelected()
        {
            var r = Selected();
            if (r == null || r.Kind != "instance") { Log("[WARN] 先选中一个实例行"); return; }

            string msg = "注销服务 " + r.Service + " 并删除实例记录？\r\n\r\n" +
                         "数据目录会保留：" + r.DataDir + "\r\n" +
                         "要连数据一起删，请手动删除该目录（工具不代劳，避免误删）。";
            if (!Dialogs.Confirm(FindForm(), "注销服务", msg, "注销")) return;

            var args = new Dictionary<string, object>();
            args["Id"] = r.Id;
            args["Action"] = 6;
            RunAction("db-service", args, "注销服务 " + r.Label);
        }

        private void BackupSelected()
        {
            var r = Selected();
            if (r == null || r.Kind != "instance") { Log("[WARN] 先选中一个实例行"); return; }

            bool mysql = r.Engine == "mysql";
            string defDb = mysql ? "mysql" : "postgres";
            var fields = new List<PromptField> { new PromptField("库名", defDb, false, "要备份的数据库名") };
            string[] v = Dialogs.Prompt(FindForm(), "备份 " + r.Label,
                mysql
                    ? "导出到 backup\\mysql\\" + r.Id + "-<时间>.sql（mysqldump，含建库语句）。"
                    : "导出到 backup\\postgresql\\" + r.Id + "-<时间>.dump（pg_dump 自定义格式）。",
                fields, "开始备份");
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args["Id"] = r.Id;
            args["Database"] = v[0].Trim().Length > 0 ? v[0].Trim() : defDb;
            RunAction("db-backup", args, "备份 " + r.Label);
        }

        private void CreateDbSelected()
        {
            var r = Selected();
            if (r == null || r.Kind != "instance") { Log("[WARN] 先选中一个实例行"); return; }

            var fields = new List<PromptField>
            {
                new PromptField("新库名", "", false, "字母 / 数字 / 下划线 / 短横线，最长 63")
            };
            string[] v = Dialogs.Prompt(FindForm(), "新建数据库 · " + r.Label,
                "会在实例 " + r.Id + " 上建一个空库" +
                (r.Engine == "mysql" ? "（utf8mb4）" : "（继承 UTF8 模板）") + "。", fields, "创建");
            if (v == null) return;
            string name = v[0].Trim();
            if (name.Length == 0) { Log("[WARN] 库名不能为空"); return; }

            var args = new Dictionary<string, object>();
            args["Id"] = r.Id;
            args["Database"] = name;
            RunAction("db-createdb", args, "建库 " + name);
        }

        private void RestoreSelected()
        {
            var r = Selected();
            if (r == null || r.Kind != "instance") { Log("[WARN] 先选中一个实例行"); return; }
            bool mysql = r.Engine == "mysql";

            string dir = System.IO.Path.Combine(Bridge.Root, "backup", mysql ? "mysql" : "postgresql");
            string filter = mysql
                ? "MySQL 备份 (*.sql)|*.sql|所有文件 (*.*)|*.*"
                : "PostgreSQL 备份 (*.dump)|*.dump|所有文件 (*.*)|*.*";
            using (var dlg = new OpenFileDialog())
            {
                dlg.Title = "选择备份文件";
                dlg.Filter = filter;
                dlg.CheckFileExists = true;
                if (System.IO.Directory.Exists(dir)) dlg.InitialDirectory = dir;
                if (dlg.ShowDialog(FindForm()) != DialogResult.OK) return;
                string file = dlg.FileName;

                var fields = new List<PromptField>
                {
                    new PromptField("目标库名", mysql ? "" : "postgres",
                        false, mysql ? "留空 = 按备份里的库名（dump 里带 CREATE DATABASE 时）" : "还原到哪个库；同名对象会被覆盖")
                };
                string[] v = Dialogs.Prompt(FindForm(), "还原 · " + r.Label,
                    "备份文件：" + System.IO.Path.GetFileName(file) + "（" +
                    (new System.IO.FileInfo(file).Length / 1024.0 / 1024.0).ToString("0.0") + " MB）\r\n" +
                    "会覆盖目标库里同名对象，生产库请先备份。", fields, "开始还原");
                if (v == null) return;

                var args = new Dictionary<string, object>();
                args["Id"] = r.Id;
                args["File"] = file;
                args["Database"] = v[0].Trim();
                RunAction("db-restore", args, "还原 " + System.IO.Path.GetFileName(file));
            }
        }

        private void OpenDataDir()
        {
            try
            {
                if (_dataRoot.Length == 0) { Log("[WARN] 还没读到数据目录"); return; }
                Log("[INFO] 数据目录：" + _dataRoot);
                if (!System.IO.Directory.Exists(_dataRoot))
                {
                    Log("[INFO] 目录还没建出来（初始化实例时会自动创建）");
                    return;
                }
                Process.Start("explorer.exe", "\"" + _dataRoot + "\"");
            }
            catch (Exception ex)
            {
                Log("[WARN] 打开资源管理器失败（Server Core 常见）：" + ex.Message);
            }
        }

        private void RunAction(string actionId, Dictionary<string, object> args, string title)
        {
            SetState(title + "…", "Info");
            bool started = Actions.RunAction(actionId, args,
                line => SafeInvoke(() => Log(line)),
                res => SafeInvoke(() =>
                {
                    Log((res.ExitCode == 0 ? "[OK] " : "[ERROR] ") + title + "结束，退出码 " +
                        res.ExitCode + "，用时 " + res.Seconds.ToString("0.0") + " 秒");
                    if (res.ExitCode != 0) SetState(title + "失败", "Danger");
                    Load();
                }),
                err => SafeInvoke(() =>
                {
                    SetState("未启动", "Warn");
                    Log("[WARN] " + title + "未启动: " + err);
                }));
            if (!started) SetState("已有动作在跑", "Warn");
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        // ---------------------------------------------------------- 布局
        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _table.Left = 0;
            _table.Top = 76;
            _table.Width = Math.Max(200, w - 4);

            _actions.Left = 0;
            _actions.Width = Math.Max(200, w - 4);
            int bh = LayoutButtonRow(_buttons, _actions.Width, 0);
            _actions.Height = bh;
            _table.Height = Math.Max(110, ClientSize.Height - 76 - bh - 22);
            _actions.Top = _table.Bottom + 6;
        }
    }
}

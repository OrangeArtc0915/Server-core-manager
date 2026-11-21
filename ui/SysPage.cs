using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 系统管理类页面的公共骨架：
    //   页头胶囊 + 数据表 + 底部按钮行 + 多视图切换。
    // 子类只负责：列、行内容、按钮、按视图加载哪个 runner 模式。
    // 所有写操作都走动作执行器（有任务记录与审计），读走 Run-GuiReadySys.ps1。
    // ============================================================
    internal abstract class SysPage : PageBase
    {
        protected const int TopY = 76;

        protected readonly DataTable Table;
        protected readonly Panel Bar;
        protected readonly Panel Tabs;
        protected readonly Pill Sum;
        protected readonly List<UiButton> AllButtons = new List<UiButton>();
        protected readonly Dictionary<string, List<UiButton>> ViewButtons = new Dictionary<string, List<UiButton>>();
        private readonly Dictionary<string, UiButton> _tabButtons = new Dictionary<string, UiButton>();
        protected readonly List<Dictionary<string, object>> Items = new List<Dictionary<string, object>>();
        protected readonly List<Dictionary<string, object>> View = new List<Dictionary<string, object>>();
        protected string ViewKey = "";
        protected bool Busy;
        protected int TopOffset = TopY;

        // 新功能页可以指向自己的 runner；系统管理页默认仍用 Run-GuiReadySys.ps1
        protected virtual string RunnerScript { get { return @"gui\Run-GuiReadySys.ps1"; } }

        protected SysPage(string key, string title, string subtitle, string glyph)
        {
            Key = key;
            TitleText = title;
            Subtitle = subtitle;
            Glyph = glyph;
            Accent = Theme.AccentOf(key);
            CacheSeconds = 15;

            Sum = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(Sum);
            Head.Slot.Width = Sum.Width;

            Tabs = new Panel { BackColor = Color.Transparent, Location = new Point(0, 72), Height = 32, Visible = false };
            Controls.Add(Tabs);

            Table = new DataTable { Location = new Point(0, TopOffset), RowHeight = 40 };
            Controls.Add(Table);

            Bar = new Panel { BackColor = Color.Transparent };
            Controls.Add(Bar);

            var export = new UiButton("导出 CSV", ButtonKind.Ghost, 90, 34) { Visible = true };
            export.Click += (s, e) => ExportCsv();
            AllButtons.Add(export);
            Bar.Controls.Add(export);
        }

        // 当前列表导出 CSV（UTF-8 BOM，Excel 直接打开不乱码）
        private void ExportCsv()
        {
            if (Table.Rows.Count == 0) { Log("[WARN] 当前列表没有数据"); return; }
            string dir = Path.Combine(Bridge.Root, "reports");
            string def = Key + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".csv";
            string path = Dialogs.SaveFile(FindForm(), "导出 CSV", "CSV 文件 (*.csv)|*.csv|所有文件 (*.*)|*.*", def, dir);
            if (string.IsNullOrEmpty(path)) return;

            var sb = new StringBuilder();
            var headers = new List<string>();
            foreach (var c in Table.Columns) headers.Add(c.Header);
            sb.AppendLine(string.Join(",", headers.ToArray()));
            foreach (var row in Table.Rows)
            {
                var cells = new List<string>();
                foreach (var cell in row) cells.Add(Quote(cell));
                sb.AppendLine(string.Join(",", cells.ToArray()));
            }
            try
            {
                File.WriteAllText(path, sb.ToString(), new UTF8Encoding(true));
                Log("[OK] 已导出 " + Table.Rows.Count + " 行到 " + path);
            }
            catch (Exception ex)
            {
                Log("[ERROR] 导出失败：" + ex.Message);
            }
        }

        private static string Quote(string s)
        {
            s = s ?? "";
            if (s.IndexOfAny(new[] { ',', '"', '\n', '\r' }) < 0) return s;
            return "\"" + s.Replace("\"", "\"\"") + "\"";
        }

        // ---------------------------------------------------------- 子类接口
        protected override void BuildContent() { }

        protected abstract void BuildColumns();
        protected abstract string[] Cells(Dictionary<string, object> item);
        protected virtual bool InView(Dictionary<string, object> item) { return true; }
        protected virtual void OnLoaded(Dictionary<string, object> data) { }
        protected virtual void OnSwitchView() { }
        protected virtual void Load() { }

        protected void AddCol(string header, int width, bool right = false)
        {
            Table.Columns.Add(new DataColumn(header, width, right));
        }

        protected UiButton AddBtn(string view, string text, ButtonKind kind, int width, Action act)
        {
            var b = new UiButton(text, kind, width, 34) { Visible = false };
            b.Click += (s, e) => act();
            List<UiButton> list;
            if (!ViewButtons.TryGetValue(view, out list)) { list = new List<UiButton>(); ViewButtons[view] = list; }
            list.Add(b);
            AllButtons.Add(b);
            Bar.Controls.Add(b);
            return b;
        }

        // 页内视图切换（磁盘/卷/卷影、Hyper-V/IIS/打印/共享）
        protected void AddTab(string view, string text, int width = 92)
        {
            var b = new UiButton(text, ButtonKind.Normal, width, 32);
            b.Click += (s, e) => SwitchTab(view);
            _tabButtons[view] = b;
            Tabs.Controls.Add(b);
            Tabs.Visible = true;
            TopOffset = 112;
            Table.Top = TopOffset;
        }

        protected void SwitchTab(string view)
        {
            if (ViewKey != view) { SetView(view); Load(); }
            RestyleTabs();
        }

        protected void RestyleTabs()
        {
            foreach (var kv in _tabButtons)
            {
                kv.Value.Kind = kv.Key == ViewKey ? ButtonKind.Primary : ButtonKind.Normal;
                kv.Value.Invalidate();
            }
        }

        protected override void OnActivated()
        {
            Load();
        }

        protected void SetView(string view)
        {
            ViewKey = view;
            // 视图切换要重建列：不先清空的话，来回切几次表头会一路叠加
            Table.Columns.Clear();
            BuildColumns();
            OnSwitchView();
            ApplyRows();
        }

        protected void ApplyRows()
        {
            View.Clear();
            var rows = new List<string[]>();
            foreach (var it in Items)
            {
                if (!InView(it)) continue;
                View.Add(it);
                rows.Add(Cells(it));
            }
            Table.SetRows(rows, true);
            foreach (var kv in ViewButtons)
            {
                bool on = kv.Key == ViewKey;
                foreach (var b in kv.Value) b.Visible = on;
            }
            LayoutBar();
        }

        // ---------------------------------------------------------- 读取
        protected void RunList(string mode, Dictionary<string, object> args, int timeoutMs = 120000)
        {
            if (Busy) return;
            Busy = true;
            SetSum("读取中…", "Info");
            Log("[STEP] 读取 " + mode);
            Bridge.Run(RunnerScript, mode, args,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    SafeInvoke(() =>
                    {
                        Log("[INFO] " + mode + " 返回 " + items.Count + " 条");
                        Busy = false;
                        Items.Clear();
                        Items.AddRange(items);
                        try
                        {
                            OnLoaded(data);
                            ApplyRows();
                            ApplyState(data);
                        }
                        catch (Exception ex)
                        {
                            // 渲染异常不要静默吞掉：以前会停在「读取中…」，看不出原因
                            SetSum("渲染失败", "Danger");
                            Log("[WARN] 列表渲染失败：" + ex.Message);
                        }
                    });
                },
                err => SafeInvoke(() =>
                {
                    Busy = false;
                    SetSum("读取失败", "Danger");
                    Log("[WARN] 读取失败：" + err);
                }), timeoutMs);
        }

        // 读一份数据但直接弹只读窗口（历史、详情、路由表这类）
        protected void ShowText(string mode, Dictionary<string, object> args, string title,
                                Func<List<Dictionary<string, object>>, Dictionary<string, object>, string> render,
                                int timeoutMs = 120000)
        {
            SetSum("读取中…", "Info");
            Bridge.Run(RunnerScript, mode, args,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    var data = Bridge.Dict(d.ContainsKey("Data") ? d["Data"] : null);
                    SafeInvoke(() =>
                    {
                        SetSum("就绪", "Neutral");
                        string text = render == null ? "" : render(items, data);
                        Log("[INFO] " + title + "：" + items.Count + " 条");
                        Dialogs.Text(FindForm(), title, "", text);
                    });
                },
                err => SafeInvoke(() =>
                {
                    SetSum("读取失败", "Danger");
                    Log("[WARN] " + title + "读取失败：" + err);
                }), timeoutMs);
        }

        protected virtual void ApplyState(Dictionary<string, object> data)
        {
            SetSum(Items.Count + " 条", Items.Count > 0 ? "Info" : "Neutral");
        }

        protected Dictionary<string, object> Selected()
        {
            int i = Table.SelectedIndex;
            return (i >= 0 && i < View.Count) ? View[i] : null;
        }

        protected Dictionary<string, object> NeedSelected()
        {
            var it = Selected();
            if (it == null) Log("[WARN] 先在列表里选一行");
            return it;
        }

        // ---------------------------------------------------------- 动作
        protected void RunAction(string actionId, Dictionary<string, object> args, string title)
        {
            SetSum(title + "…", "Info");
            bool started = Actions.RunAction(actionId, args,
                line => SafeInvoke(() => Log(line)),
                res => SafeInvoke(() =>
                {
                    Log((res.ExitCode == 0 ? "[OK] " : "[ERROR] ") + title + "结束，退出码 " +
                        res.ExitCode + "，用时 " + res.Seconds.ToString("0.0") + " 秒");
                    if (res.ExitCode != 0) SetSum(title + "失败", "Danger");
                    Load();
                }),
                err => SafeInvoke(() =>
                {
                    SetSum("未启动", "Warn");
                    Log("[WARN] " + title + "未启动: " + err);
                }));
            if (!started) SetSum("已有动作在跑", "Warn");
        }

        protected void SetSum(string text, string kind)
        {
            Sum.SetText(text);
            Sum.SetKind(kind);
            Head.Slot.Width = Sum.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        // ---------------------------------------------------------- 布局
        private int LayoutBar()
        {
            var vis = new List<UiButton>();
            foreach (var b in AllButtons) if (b.Visible) vis.Add(b);
            int width = Bar.Width > 0 ? Bar.Width : Math.Max(200, ClientSize.Width - 4);
            int bh = LayoutButtonRow(vis, width, 0);
            Bar.Height = bh;
            return bh;
        }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            Tabs.Left = 0;
            Tabs.Top = 72;
            Tabs.Width = Math.Max(200, w - 4);
            int tx = 0;
            foreach (var kv in _tabButtons)
            {
                var b = kv.Value;
                b.Left = tx;
                b.Top = 0;
                tx += b.Width + 8;
            }

            Table.Left = 0;
            Table.Top = TopOffset;
            Table.Width = Math.Max(200, w - 4);

            Bar.Left = 0;
            Bar.Width = Math.Max(200, w - 4);
            int bh = LayoutBar();
            Table.Height = Math.Max(110, ClientSize.Height - TopOffset - bh - 22);
            Bar.Top = Table.Bottom + 6;
        }
    }
}

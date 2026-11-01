using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 应用商店：Server Core 兼容性安装器 + 卡片墙。
    //   · 默认精选视图（store\catalog.json，22 条），按热度排序
    //   · 分类 / 兼容性筛选（全部 / 实测可用 / 部分可用 / 未实测 / 不支持）
    //   · 安装前预检（choco 在不在、已装没、要不要 FOD / 运行库）
    //   · 详情弹窗列实测凭据、已知问题、启动参数、替代应用
    //   · 搜索仍走 Chocolatey / npm，结果沿用卡片，可批量勾选安装
    // ============================================================
    internal sealed class StorePage : PageBase
    {
        private static readonly string[,] CategoryDefs = new string[,]
        {
            { "", "全部" },
            { "container", "容器与编排" },
            { "web", "Web 与反向代理" },
            { "data", "数据与缓存" },
            { "ops", "运维与诊断" },
            { "monitor", "监控与告警" },
            { "dev", "开发运行时" },
            { "ai", "AI 辅助" },
            { "media", "媒体处理" },
            { "network", "网络工具" }
        };

        private static readonly string[,] CompatDefs = new string[,]
        {
            { "", "全部兼容性" },
            { "verified", "实测可用" },
            { "partial", "部分可用" },
            { "unverified", "未实测" },
            { "unsupported", "不支持" }
        };

        private readonly Panel _searchBar;
        private readonly Panel _filters;
        private readonly Panel _actions;
        private readonly UiInput _query;
        private readonly UiButton _search;
        private readonly UiButton _curatedBtn;
        private readonly StoreGrid _grid;
        private readonly Pill _state;
        private readonly List<UiButton> _catButtons = new List<UiButton>();
        private readonly List<UiButton> _compatButtons = new List<UiButton>();
        private readonly List<UiButton> _actionButtons = new List<UiButton>();
        private readonly List<StoreCard> _all = new List<StoreCard>();
        private readonly HashSet<string> _installed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        private string _category = "";
        private string _compat = "";
        private string _chocoText = "";
        private bool _busy;
        private bool _curated = true;

        public StorePage()
        {
            Key = "store";
            TitleText = "应用商店";
            Subtitle = "Server Core 兼容性安装器：精选服务器常用工具，标注实测状态 / FOD / 运行库依赖；安装前先预检，详情里能看到已知问题。";
            Glyph = "store";
            Accent = Theme.AccentOf("store");

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _searchBar = new Panel { Height = 36, BackColor = Color.Transparent };
            Controls.Add(_searchBar);

            _query = new UiInput(320) { Location = new Point(0, 2) };
            _query.ValueText = "";
            _query.Box.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; Search(); }
            };
            _search = new UiButton("搜索", ButtonKind.Primary, 88, 32) { Location = new Point(0, 2) };
            _search.Click += (s, e) => Search();
            _curatedBtn = new UiButton("精选应用", ButtonKind.Normal, 100, 32) { Location = new Point(0, 2) };
            _curatedBtn.Click += (s, e) => LoadCurated();
            _searchBar.Controls.Add(_query);
            _searchBar.Controls.Add(_search);
            _searchBar.Controls.Add(_curatedBtn);

            _filters = new Panel { Height = 72, BackColor = Color.Transparent };
            Controls.Add(_filters);
            for (int i = 0; i < CategoryDefs.GetLength(0); i++)
            {
                string id = CategoryDefs[i, 0];
                string text = CategoryDefs[i, 1];
                var b = new UiButton(text, id.Length == 0 ? ButtonKind.Primary : ButtonKind.Ghost, 0, 30);
                b.Width = ChipWidth(text);
                b.Click += (s, e) => { _category = id; RestyleChips(); ApplyFilter(false); };
                _catButtons.Add(b);
                _filters.Controls.Add(b);
            }
            for (int i = 0; i < CompatDefs.GetLength(0); i++)
            {
                string id = CompatDefs[i, 0];
                string text = CompatDefs[i, 1];
                var b = new UiButton(text, id.Length == 0 ? ButtonKind.Primary : ButtonKind.Ghost, 0, 30);
                b.Width = ChipWidth(text);
                b.Click += (s, e) => { _compat = id; RestyleChips(); ApplyFilter(false); };
                _compatButtons.Add(b);
                _filters.Controls.Add(b);
            }

            _grid = new StoreGrid { Location = new Point(0, 152) };
            _grid.SelectionChanged += idx =>
            {
                var c = _grid.SelectedCard;
                if (c != null) Log("[INFO] " + c.Name + (c.Installed ? "（已安装）" : "") +
                                   (c.CompatNote.Length > 0 ? " · " + c.CompatNote : ""));
            };
            _grid.RowActivated += idx =>
            {
                var c = (idx >= 0 && idx < _grid.Cards.Count) ? _grid.Cards[idx] : null;
                if (c != null) InstallCard(c);
            };
            _grid.CheckChanged += (key, on) => UpdateBatchButton();
            Controls.Add(_grid);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);
            AddButton("安装选中", ButtonKind.Primary, 96, InstallSelected);
            AddButton("卸载选中", ButtonKind.Danger, 92, UninstallSelected);
            AddButton("查看详情", ButtonKind.Normal, 88, ShowDetail);
            _batch = AddButton("批量安装", ButtonKind.Normal, 96, InstallChecked);
            AddButton("重试失败", ButtonKind.Normal, 88, RetryFailed);
            AddButton("导出清单", ButtonKind.Normal, 88, ExportManifest);
            AddButton("导入清单", ButtonKind.Normal, 88, ImportManifest);
            AddButton("装 Chocolatey", ButtonKind.Normal, 118, InstallChoco);
            AddButton("可升级", ButtonKind.Normal, 80, ShowOutdated);
            AddButton("清空勾选", ButtonKind.Ghost, 88, ClearChecked);
        }

        private UiButton _batch;

        private static int ChipWidth(string text)
        {
            var sz = TextRenderer.MeasureText(text, Theme.Font(9.25f), new Size(4000, 100),
                TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            return Math.Max(56, sz.Width + 26);
        }

        private UiButton AddButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 0) };
            b.Click += (s, e) => onClick();
            _actionButtons.Add(b);
            _actions.Controls.Add(b);
            return b;
        }

        protected override void BuildContent() { }

        protected override void OnActivated()
        {
            LoadStatus();
            LoadCurated();
            LoadInstalled();
        }

        // ---------------------------------------------------------- 数据
        private void LoadStatus()
        {
            Bridge.Run(@"gui\Run-GuiReadyStore.ps1", "status", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        var parts = new List<string>();
                        foreach (var s in items)
                        {
                            bool ok = Bridge.Bool(s, "Installed");
                            string nm = Bridge.Str(s, "Name", Bridge.Str(s, "Id"));
                            string ver = Bridge.Str(s, "Version");
                            parts.Add(nm + (ok ? (ver.Length > 0 ? " " + ver : "") : " 未安装"));
                            if (Bridge.Str(s, "Id") == "choco")
                                _chocoText = ok ? (ver.Length > 0 ? ver : "可用") : "未安装";
                        }
                        UpdateState();
                        Log("[INFO] 包管理器：" + string.Join(" · ", parts.ToArray()));
                    });
                },
                err => SafeInvoke(() => Log("[WARN] 包管理器状态读取失败: " + err)), 120000);
        }

        private void LoadInstalled()
        {
            var args = new Dictionary<string, object>();
            args["Source"] = "choco";
            Bridge.Run(@"gui\Run-GuiReadyStore.ps1", "local", args,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _installed.Clear();
                        foreach (var it in items)
                        {
                            string id = Bridge.Str(it, "Id", Bridge.Str(it, "Name"));
                            if (id.Length > 0) _installed.Add(id);
                            string nm = Bridge.Str(it, "Name");
                            if (nm.Length > 0) _installed.Add(nm);
                        }
                        MarkInstalled();
                        _grid.Invalidate();
                    });
                },
                err => SafeInvoke(() => Log("[WARN] 已装列表读取失败: " + err)), 180000);
        }

        private void MarkInstalled()
        {
            foreach (var c in _all)
            {
                c.Installed = _installed.Contains(c.PackageId) || _installed.Contains(c.Key) ||
                              (c.CatalogId.Length > 0 && _installed.Contains(c.CatalogId));
            }
        }

        // 精选库（store\catalog.json）：默认视图
        private void LoadCurated()
        {
            SetState("读取精选库…", "Info");
            Bridge.Run(@"gui\Run-GuiReadyStore.ps1", "curated", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _curated = true;
                        _all.Clear();
                        foreach (var it in items)
                        {
                            var c = new StoreCard
                            {
                                Key = Bridge.Str(it, "CatalogId", Bridge.Str(it, "Id")),
                                CatalogId = Bridge.Str(it, "CatalogId"),
                                Name = Bridge.Str(it, "Name", Bridge.Str(it, "Id")),
                                NameEn = Bridge.Str(it, "NameEn"),
                                PackageId = Bridge.Str(it, "InstallId", Bridge.Str(it, "Id")),
                                Source = Bridge.Str(it, "Source", "choco"),
                                Category = Bridge.Str(it, "Category"),
                                CategoryName = Bridge.Str(it, "CategoryName", Bridge.Str(it, "Category")),
                                Compat = Bridge.Str(it, "Compat"),
                                CompatNote = Bridge.Str(it, "CompatNote"),
                                Ui = Bridge.Str(it, "Ui"),
                                Curated = true,
                                Raw = it
                            };
                            _all.Add(c);
                        }
                        MarkInstalled();
                        ApplyFilter(false);
                        Log("[INFO] 精选库：" + _all.Count + " 个条目");
                    });
                },
                err => SafeInvoke(() =>
                {
                    SetState("精选库读取失败", "Warn");
                    Log("[WARN] 精选库读取失败: " + err);
                }), 60000);
        }

        private void Search()
        {
            if (_busy) return;
            string q = _query.ValueText.Trim();
            if (q.Length == 0) { Log("[WARN] 先输入要搜索的名字"); return; }
            _busy = true;
            SetState("搜索中…", "Info");
            Log("[STEP] 搜索 " + q + "（Chocolatey 优先，npm 补充）");

            var args = new Dictionary<string, object>();
            args["Query"] = q;
            Bridge.Run(@"gui\Run-GuiReadyStore.ps1", "searchall", args,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _curated = false;
                        _category = "";
                        _compat = "";
                        RestyleChips();
                        _all.Clear();
                        foreach (var it in items)
                        {
                            string id = Bridge.Str(it, "Id", Bridge.Str(it, "Name"));
                            string src = Bridge.Str(it, "Source", "choco");
                            _all.Add(new StoreCard
                            {
                                Key = src + ":" + id,
                                Name = id,
                                NameEn = Bridge.Str(it, "Description", Bridge.Str(it, "Note")),
                                PackageId = id,
                                Version = Bridge.Str(it, "Version"),
                                Source = src,
                                CategoryName = src,
                                Curated = false
                            });
                        }
                        MarkInstalled();
                        ApplyFilter(false);
                        Log("[OK] 搜索 " + q + "：" + _all.Count + " 个结果");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("搜索失败", "Danger");
                    Log("[WARN] 搜索失败: " + err);
                }), 180000);
        }

        private void ShowOutdated()
        {
            if (_busy) return;
            _busy = true;
            SetState("检查可升级…", "Info");

            var args = new Dictionary<string, object>();
            args["Source"] = "choco";
            Bridge.Run(@"gui\Run-GuiReadyStore.ps1", "outdated", args,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _curated = false;
                        _category = "";
                        _compat = "";
                        RestyleChips();
                        _all.Clear();
                        foreach (var it in items)
                        {
                            string id = Bridge.Str(it, "Id", Bridge.Str(it, "Name"));
                            _all.Add(new StoreCard
                            {
                                Key = "choco:" + id,
                                Name = id,
                                NameEn = Bridge.Str(it, "Description"),
                                PackageId = id,
                                Version = Bridge.Str(it, "Available", Bridge.Str(it, "Version")),
                                Source = "choco",
                                CategoryName = "可升级",
                                Curated = false,
                                Installed = true
                            });
                        }
                        ApplyFilter(false);
                        Log("[INFO] 可升级：" + _all.Count + " 个");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("检查失败", "Danger");
                    Log("[WARN] 可升级检查失败: " + err);
                }), 180000);
        }

        // ---------------------------------------------------------- 过滤 / 状态
        private void ApplyFilter(bool keepScroll)
        {
            var view = new List<StoreCard>();
            foreach (var c in _all)
            {
                if (_category.Length > 0 && c.Category != _category) continue;
                if (_compat.Length > 0 && c.Compat != _compat) continue;
                view.Add(c);
            }
            _grid.SetCards(view, keepScroll);
            UpdateState();
            UpdateBatchButton();
        }

        private void RestyleChips()
        {
            for (int i = 0; i < _catButtons.Count; i++)
            {
                bool on = CategoryDefs[i, 0] == _category;
                _catButtons[i].Kind = on ? ButtonKind.Primary : ButtonKind.Ghost;
                _catButtons[i].Invalidate();
            }
            for (int i = 0; i < _compatButtons.Count; i++)
            {
                bool on = CompatDefs[i, 0] == _compat;
                _compatButtons[i].Kind = on ? ButtonKind.Primary : ButtonKind.Ghost;
                _compatButtons[i].Invalidate();
            }
        }

        private void UpdateState()
        {
            string text;
            if (_curated) text = "精选 " + _all.Count + " 个 · 显示 " + _grid.Cards.Count;
            else text = _busy ? "查询中…" : "结果 " + _grid.Cards.Count + " 个";
            if (_chocoText.Length > 0) text += " · choco " + _chocoText;
            SetState(text, _chocoText.Length > 0 && _chocoText != "未安装" ? "Info" : "Neutral");
        }

        private void UpdateBatchButton()
        {
            if (_batch == null) return;
            int n = _grid.CheckedCount;
            _batch.Text = n > 0 ? "批量安装 (" + n + ")" : "批量安装";
            _batch.Invalidate();
        }

        private void ClearChecked()
        {
            _grid.ClearChecked();
            UpdateBatchButton();
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        // ---------------------------------------------------------- 详情
        private void ShowDetail()
        {
            var c = _grid.SelectedCard;
            if (c == null) { Log("[WARN] 先选一张卡片"); return; }
            if (c.Curated) { Dialogs.Text(FindForm(), c.Name, "应用详情 · " + c.CategoryName, BuildDetail(c)); return; }
            ShowPackageInfo(c.PackageId, c.Source);
        }

        private static string BuildDetail(StoreCard c)
        {
            var raw = c.Raw;
            var lines = new List<string>();
            lines.Add("英文名    " + Bridge.Str(raw, "NameEn", c.Name));
            lines.Add("目录 ID   " + c.CatalogId);
            lines.Add("分类      " + c.CategoryName);
            lines.Add("界面类型  " + Bridge.Str(raw, "Ui", "cli") + "（gui 才需要 App Compatibility FOD）");
            lines.Add("兼容性    " + CompatText(c.Compat));
            lines.Add("凭据      " + (c.CompatNote.Length > 0 ? c.CompatNote : "无"));
            lines.Add("");
            lines.Add("安装方式  " + Bridge.Str(raw, "InstallType", "choco") + " / " + Bridge.Str(raw, "InstallId", c.PackageId));
            string args = Bridge.Str(raw, "InstallArgs");
            if (args.Length > 0) lines.Add("静默参数  " + args);
            string exe = Bridge.Str(raw, "LaunchExe");
            if (exe.Length > 0) lines.Add("启动命令  " + exe + " " + Bridge.Str(raw, "LaunchArgs"));
            lines.Add("");

            var fod = Bridge.StrList(raw, "Fod");
            lines.Add("FOD 依赖  " + (fod.Count > 0 ? string.Join("、", fod.ToArray()) : "无"));
            var deps = Bridge.StrList(raw, "RuntimeDeps");
            lines.Add("运行库    " + (deps.Count > 0 ? string.Join("、", deps.ToArray()) : "无"));

            var issues = Bridge.StrList(raw, "KnownIssues");
            if (issues.Count > 0)
            {
                lines.Add("");
                lines.Add("已知问题：");
                foreach (var s in issues) lines.Add("  - " + s);
            }
            var alts = Bridge.StrList(raw, "Alternatives");
            if (alts.Count > 0) lines.Add("替代应用  " + string.Join("、", alts.ToArray()));
            var tested = Bridge.StrList(raw, "TestedOn");
            lines.Add("实测系统  " + (tested.Count > 0 ? string.Join("、", tested.ToArray()) : "尚未实测"));
            return string.Join("\r\n", lines.ToArray());
        }

        private void ShowPackageInfo(string pkg, string source)
        {
            var args = new Dictionary<string, object>();
            args["Source"] = string.IsNullOrEmpty(source) ? "choco" : source;
            args["Package"] = pkg;
            Log("[STEP] 读取包详情 " + pkg);
            Bridge.Run(@"gui\Run-GuiReadyStore.ps1", "info", args,
                d => SafeInvoke(() =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    if (items.Count == 0) { Log("[WARN] 没有拿到详情"); return; }
                    var it = items[0];
                    string err = Bridge.Str(it, "Error");
                    if (err.Length > 0) { Log("[WARN] " + err); return; }

                    var lines = new List<string>();
                    lines.Add("标题      " + Bridge.Str(it, "Title", pkg));
                    lines.Add("版本      " + Bridge.Str(it, "Version"));
                    lines.Add("发布      " + Bridge.Str(it, "Published"));
                    lines.Add("下载量    " + Bridge.Str(it, "Downloads"));
                    lines.Add("许可      " + Bridge.Str(it, "License"));
                    string site = Bridge.Str(it, "Site");
                    if (site.Length == 0) site = Bridge.Str(it, "Url");
                    if (site.Length > 0) lines.Add("官网      " + site);
                    string tags = Bridge.Str(it, "Tags");
                    if (tags.Length > 0) lines.Add("标签      " + tags);
                    string summary = Bridge.Str(it, "Summary");
                    if (summary.Length > 0) { lines.Add(""); lines.Add(summary); }
                    Dialogs.Text(FindForm(), pkg, "包详情 · " + (source.Length > 0 ? source : "choco"),
                                 string.Join("\r\n", lines.ToArray()));
                }),
                err2 => SafeInvoke(() => Log("[WARN] 详情读取失败: " + err2)), 180000);
        }

        private static string CompatText(string c)
        {
            switch (c)
            {
                case "verified": return "实测可用";
                case "partial": return "部分可用";
                case "unsupported": return "不支持";
                default: return "未实测";
            }
        }

        // ---------------------------------------------------------- 安装 / 卸载
        private void InstallSelected()
        {
            var c = _grid.SelectedCard;
            if (c == null) { Log("[WARN] 先选一张卡片"); return; }
            InstallCard(c);
        }

        private void InstallCard(StoreCard c)
        {
            if (!c.Curated)
            {
                if (!Dialogs.Confirm(FindForm(), "安装软件包",
                    "通过 " + (c.Source.Length > 0 ? c.Source : "choco") + " 安装「" + c.PackageId + "」？\n\n" +
                    "会联网下载并写入系统，需要管理员权限。", "安装")) return;
                RunPackageAction("pkg-install", "安装 " + c.PackageId, c.PackageId, c.Source);
                return;
            }

            SetState("预检中…", "Info");
            var args = new Dictionary<string, object>();
            args["AppId"] = c.CatalogId;
            Bridge.Run(@"gui\Run-GuiReadyStore.ps1", "precheck", args,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        UpdateState();
                        if (items.Count == 0) { Log("[WARN] 预检没有返回结果"); return; }
                        var p = items[0];
                        var lines = new List<string>();
                        lines.Add("安装方式：" + Bridge.Str(p, "InstallType", "choco") + " / " + Bridge.Str(p, "InstallId", c.PackageId));
                        lines.Add(Bridge.Bool(p, "Installed")
                            ? "当前状态：已安装 " + Bridge.Str(p, "InstalledVersion")
                            : "当前状态：未安装");
                        foreach (var n in Bridge.StrList(p, "Notes")) lines.Add("· " + n);
                        if (lines.Count == 2) lines.Add("· 预检通过，没有需要额外注意的项");

                        string msg = "「" + c.Name + "」\n\n" + string.Join("\n", lines.ToArray()) + "\n\n继续安装？";
                        if (!Dialogs.Confirm(FindForm(), "安装前预检", msg, "继续安装")) return;
                        RunCuratedInstall(c);
                    });
                },
                err => SafeInvoke(() =>
                {
                    UpdateState();
                    Log("[WARN] 预检失败: " + err);
                    if (Dialogs.Confirm(FindForm(), "预检失败",
                        "预检没跑成功：\n" + err + "\n\n仍然继续安装？", "继续")) RunCuratedInstall(c);
                }), 120000);
        }

        private void RunCuratedInstall(StoreCard c)
        {
            var args = new Dictionary<string, object>();
            args["AppId"] = c.CatalogId;
            args["DryRun"] = false;
            bool started = Actions.RunAction("store-install", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "安装 " + c.Name + " 结束，退出码 " +
                        r.ExitCode + "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    LoadInstalled();
                }),
                err => SafeInvoke(() => Log("[WARN] 精选安装未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 安装精选应用（store-install）：" + c.CatalogId);
        }

        private void UninstallSelected()
        {
            var c = _grid.SelectedCard;
            if (c == null) { Log("[WARN] 先选一张卡片"); return; }
            if (!c.Installed) { Log("[WARN] 这张卡没有标记为已安装，无法卸载"); return; }
            if (!Dialogs.Confirm(FindForm(), "卸载软件包",
                "确定卸载「" + c.PackageId + "」？这一步会真的删掉已安装的程序。", "卸载")) return;
            RunPackageAction("pkg-uninstall", "卸载 " + c.PackageId, c.PackageId, c.Source);
        }

        private void InstallChecked()
        {
            var cards = _grid.CheckedCards();
            if (cards.Count == 0)
            {
                Log("[WARN] 先点卡片右上角的方块勾选要安装的应用");
                return;
            }
            var ids = new List<string>();
            foreach (var c in cards) if (!ids.Contains(c.PackageId)) ids.Add(c.PackageId);
            if (!Dialogs.Confirm(FindForm(), "批量安装",
                "按顺序安装 " + ids.Count + " 个包：\n\n" + string.Join("、", ids.ToArray()) +
                "\n\n单个失败不会中断后面的条目；失败清单会写进 state\\store-queue.json。", "开始安装")) return;
            RunQueue(string.Join(",", ids.ToArray()), ids.Count);
        }

        private void RunQueue(string appIds, int count)
        {
            var args = new Dictionary<string, object>();
            args["AppIds"] = appIds;
            args["DryRun"] = false;

            bool started = Actions.RunAction("store-queue", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[WARN] ") + "批量安装结束（" + count + " 个），退出码 " +
                        r.ExitCode + "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    LoadInstalled();
                }),
                err => SafeInvoke(() => Log("[WARN] 批量安装未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 批量安装队列（store-queue）：" + count + " 个");
        }

        private void RetryFailed()
        {
            Bridge.Run(@"gui\Run-GuiReadyStore.ps1", "queue-state", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        if (items.Count == 0)
                        {
                            Log("[INFO] 还没有队列记录：先勾选应用跑一次「批量安装」");
                            return;
                        }
                        var failed = Bridge.StrList(items[0], "Failed");
                        if (failed.Count == 0) { Log("[OK] 上次队列没有失败项"); return; }
                        if (!Dialogs.Confirm(FindForm(), "重试失败的包",
                            "上次失败 " + failed.Count + " 个：\n\n" + string.Join("、", failed.ToArray()) +
                            "\n\n现在重试？", "重试")) return;
                        RunQueue(string.Join(",", failed.ToArray()), failed.Count);
                    });
                },
                err => SafeInvoke(() => Log("[WARN] 读取队列记录失败: " + err)), 30000);
        }

        private void RunPackageAction(string actionId, string title, string package, string source)
        {
            var args = new Dictionary<string, object>();
            args["Source"] = SourceIndex(source);
            args["Package"] = package;
            args["DryRun"] = false;

            bool started = Actions.RunAction(actionId, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + title + "结束，退出码 " + r.ExitCode +
                        "，用时 " + r.Seconds.ToString("0.0") + " 秒");
                    LoadInstalled();
                }),
                err => SafeInvoke(() => Log("[WARN] " + title + "未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 " + title + "（" + actionId + "）");
        }

        // Combo 是 1 基索引：1=Chocolatey 2=Scoop 3=npm
        private static int SourceIndex(string source)
        {
            if (string.Equals(source, "scoop", StringComparison.OrdinalIgnoreCase)) return 2;
            if (string.Equals(source, "npm", StringComparison.OrdinalIgnoreCase)) return 3;
            return 1;
        }

        private void InstallChoco()
        {
            if (!Dialogs.Confirm(FindForm(), "安装 Chocolatey",
                "会从官方源安装 Chocolatey（需要管理员与联网）。确定开始？", "安装")) return;

            bool started = Actions.RunAction("pkg-install-choco",
                new Dictionary<string, object> { { "DryRun", false } },
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "Chocolatey 安装结束，退出码 " + r.ExitCode);
                    LoadStatus();
                    LoadInstalled();
                }),
                err => SafeInvoke(() => Log("[WARN] 安装未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 安装 Chocolatey（pkg-install-choco）");
        }

        private void ExportManifest()
        {
            var v = Dialogs.Prompt(FindForm(), "导出已装软件清单",
                "用 choco export 生成 packages.config；路径留空会自动写到 reports 目录。",
                new List<PromptField> { new PromptField("导出路径（可空）") }, "导出");
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args["Path"] = v[0].Trim();
            args["DryRun"] = false;
            bool started = Actions.RunAction("manifest-export", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() => Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") +
                                         "清单导出结束，退出码 " + r.ExitCode)),
                err => SafeInvoke(() => Log("[WARN] 清单导出未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 导出已装软件清单（manifest-export）");
        }

        private void ImportManifest()
        {
            var v = Dialogs.Prompt(FindForm(), "导入已装软件清单",
                "选择 packages.config（或 .config）后会把里面的软件全部装上。",
                new List<PromptField> { new PromptField("packages.config 路径") }, "导入");
            if (v == null || v[0].Trim().Length == 0) return;
            if (!Dialogs.Confirm(FindForm(), "确认导入",
                "会按清单逐个安装软件，耗时较长。确定开始？", "开始安装")) return;

            var args = new Dictionary<string, object>();
            args["Path"] = v[0].Trim();
            args["DryRun"] = false;
            bool started = Actions.RunAction("manifest-import", args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? "[OK] " : "[ERROR] ") + "清单导入结束，退出码 " + r.ExitCode);
                    LoadInstalled();
                }),
                err => SafeInvoke(() => Log("[WARN] 清单导入未启动: " + err)));
            if (started) Log("[STEP] 已提交动作 导入已装软件清单（manifest-import）");
        }

        // ---------------------------------------------------------- 布局
        protected override void OnLayout()
        {
            int w = Math.Max(200, ClientSize.Width - 4);

            _searchBar.Left = 0;
            _searchBar.Top = 76;
            _searchBar.Width = w;
            _query.Top = 2;
            _query.Left = 0;
            _query.Width = Math.Max(120, Math.Min(360, w - _search.Width - _curatedBtn.Width - 24));
            _search.Top = 2;
            _search.Left = _query.Width + 8;
            _curatedBtn.Top = 2;
            _curatedBtn.Left = _search.Left + _search.Width + 8;

            _filters.Left = 0;
            _filters.Top = _searchBar.Top + _searchBar.Height + 6;
            _filters.Width = w;
            int h1 = LayoutButtonRow(_catButtons, w, 0, 8, 8);
            int h2 = LayoutButtonRow(_compatButtons, w, h1, 8, 8);
            _filters.Height = h1 + h2;

            _actions.Left = 0;
            _actions.Width = w;
            int bh = LayoutButtonRow(_actionButtons, w, 0);
            _actions.Height = bh;

            _grid.Left = 0;
            _grid.Top = _filters.Top + _filters.Height + 4;
            _grid.Width = w;
            _actions.Top = Math.Max(_grid.Top + 80, ClientSize.Height - bh - 6);
            _grid.Height = Math.Max(120, _actions.Top - _grid.Top - 6);
        }
    }
}

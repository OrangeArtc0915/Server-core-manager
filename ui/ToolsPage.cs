﻿using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // SCM附属：TUI_TOOL 里的附属工具。
    //   GitHub 线路 = 源码分支 zip（tool/<id>）
    //   Gitee 线路  = Release 里的编译产物（Gitee 不放源码）
    // 下载走动作执行器（有任务记录与审计），安装位置 payload\plugins\<id>。
    // ============================================================
    internal sealed class ToolsPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private bool _busy;

        public ToolsPage()
        {
            Key = "tools";
            TitleText = "SCM附属";
            Subtitle = "支持切换 GitHub 和 Gitee 发行包，双线路下载；安装到 payload\\plugins\\<工具>。";
            Glyph = "tool";
            Accent = Theme.AccentOf("tool");
            CacheSeconds = 30;

            _state = new Pill("未读取", "Neutral");
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn("工具", 130));
            _table.Columns.Add(new DataColumn("类型", 120));
            _table.Columns.Add(new DataColumn("说明", 330));
            _table.Columns.Add(new DataColumn("分支", 120));
            _table.Columns.Add(new DataColumn("本地状态", 110));
            _table.Columns.Add(new DataColumn("大小", 80, true));
            _table.Columns.Add(new DataColumn("下载时间", 140));
            _table.RowActivated += idx => OpenDir();
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton("GitHub 下载", ButtonKind.Primary, 110, () => Download("github"));
            AddButton("Gitee 下载", ButtonKind.Normal, 110, () => Download("gitee"));
            AddButton("打开目录", ButtonKind.Normal, 96, OpenDir);
            AddButton("打开发布页", ButtonKind.Ghost, 106, OpenBranch);
            AddButton("刷新", ButtonKind.Ghost, 76, Load);
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

        // Run-GuiReadyPlugins.ps1 -Mode list -> Items（工具 + 本地状态）
        public void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState("读取中…", "Info");

            Bridge.Run(@"gui\Run-GuiReadyPlugins.ps1", "list", null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey("Items") ? d["Items"] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);

                        var rows = new List<string[]>();
                        int installed = 0;
                        foreach (var it in items)
                        {
                            bool has = Bridge.Str(it, "LocalState") == "已下载";
                            if (has) installed++;
                            double size = Bridge.Num(it, "LocalSizeMB");
                            rows.Add(new[]
                            {
                                Bridge.Str(it, "Name"),
                                Bridge.Str(it, "Kind"),
                                Bridge.Str(it, "Desc"),
                                Bridge.Str(it, "Branch"),
                                Bridge.Str(it, "LocalState"),
                                has && size > 0 ? SizeText(size) : "",
                                FormatTime(Bridge.Str(it, "InstalledAt"))
                            });
                        }
                        _table.SetRows(rows);
                        SetState(rows.Count + " 个工具 · 已下载 " + installed,
                                 installed > 0 ? "Success" : "Neutral");
                        Log("[INFO] 附属工具：" + rows.Count + " 个（已下载 " + installed + " 个）");
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState("读取失败", "Danger");
                    Log("[WARN] 附属工具读取失败: " + err);
                }), 60000);
        }

        // 小于 1 MB 用 KB 显示，别让 scm-top 这种小包显示成 0.0 MB
        private static string SizeText(double mb)
        {
            return mb >= 1 ? mb.ToString("0.0") + " MB" : (mb * 1024).ToString("0") + " KB";
        }

        // 标记文件里是 ISO 时间；无效/空值显示成空，别显示 0001-01-01
        private static string FormatTime(string iso)
        {
            DateTime t;
            if (string.IsNullOrEmpty(iso) || !DateTime.TryParse(iso, out t)) return "";
            return t.ToString("yyyy-MM-dd HH:mm");
        }

        private Dictionary<string, object> Selected()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _items.Count) return null;
            return _items[idx];
        }

        private void Download(string source)
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先在列表里选一个工具"); return; }

            string name = Bridge.Str(it, "Name", Bridge.Str(it, "Id"));
            string label = source == "gitee" ? "Gitee 下载" : "GitHub 下载";
            string actionId = source == "gitee" ? "plugin-download-gitee" : "plugin-download-github";

            var args = new Dictionary<string, object>();
            args["Id"] = Bridge.Str(it, "Id");
            args["DryRun"] = false;

            Log("[STEP] 下载 " + name + "（" + label + "）");
            bool started = Actions.RunAction(actionId, args,
                line => SafeInvoke(() => Log(line)),
                res => SafeInvoke(() =>
                {
                    Log((res.ExitCode == 0 ? "[OK] " : "[ERROR] ") + name + " " + label +
                        "结束，退出码 " + res.ExitCode + "，用时 " + res.Seconds.ToString("0.0") + " 秒");
                    SetState(res.ExitCode == 0 ? "下载完成" : "下载失败",
                             res.ExitCode == 0 ? "Success" : "Danger");
                    Load();
                }),
                err => SafeInvoke(() =>
                {
                    SetState("未启动", "Warn");
                    Log("[WARN] " + label + "未启动: " + err);
                }));
            if (!started) SetState("已有动作在跑", "Warn");
        }

        private void OpenDir()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先在列表里选一个工具"); return; }

            string path = Bridge.Str(it, "LocalPath");
            if (string.IsNullOrEmpty(path) || !Directory.Exists(path))
            {
                Log("[WARN] 还没有下载到本地，先点「GitHub 下载」或「Gitee 下载」");
                return;
            }
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = "\"" + path + "\"",
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                Log("[WARN] 打开目录失败: " + ex.Message);
            }
        }

        private void OpenBranch()
        {
            var it = Selected();
            if (it == null) { Log("[WARN] 先在列表里选一个工具"); return; }

            string url = Bridge.Str(it, "BranchPage");
            if (url.Length == 0) return;
            try
            {
                Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
                Log("[OK] 已打开发布页：" + url);
            }
            catch (Exception ex)
            {
                Log("[WARN] 打开浏览器失败: " + ex.Message);
            }
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;

            // 下载按钮放在表格上方：这页的主要操作就是「选一行 → 下载」，
            // 放底部在小窗口里容易看不见。
            _actions.Left = 0;
            _actions.Width = Math.Max(200, w - 4);
            int bh = LayoutButtonRow(_buttons, _actions.Width, 0);
            _actions.Height = bh;
            _actions.Top = 72;

            _table.Left = 0;
            _table.Top = _actions.Top + bh + 6;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(110, ClientSize.Height - _table.Top - 18);
        }
    }
}

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 阶段 2/3：补齐剩余页面（商店 / 程序 / 文件 / 审计 / 主机 /
    // 角色 / 安全 / 工具 / 美化 / AI / 全部功能 / 关于）。
    // 除「程序档案」外都已接真实 runner 或本机检测。
    // 排版约定与 Pages.cs 一致：内容从 Top = 76 开始，表格宽 = 宽 - 4。
    // ============================================================


    // ------------------------------------------------------------ 程序管理（运行清单）
    internal sealed class AppPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private bool _busy;

        public AppPage()
        {
            Key = vappv;
            TitleText = v程序管理v;
            Subtitle = v把要运行的程序加进来：双击启动，启动参数自动带入档案推荐值；可绑定终端命令或设为后台常驻。v;
            Glyph = vappv;
            Accent = Theme.AccentOf(vappv);

            _state = new Pill(v未读取v, vNeutralv);
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn(v名称v, 150));
            _table.Columns.Add(new DataColumn(v路径v, 320));
            _table.Columns.Add(new DataColumn(v启动参数v, 170));
            _table.Columns.Add(new DataColumn(v兼容结论v, 160));
            _table.Columns.Add(new DataColumn(v命令v, 80));
            _table.ActivateOnDoubleClick = true;
            _table.RowActivated += idx => LaunchSelected();
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);
            AddButton(v添加程序…v, ButtonKind.Primary, 116, AddProgram);
            AddButton(v启动v, ButtonKind.Normal, 80, LaunchSelected);
            AddButton(v设置参数…v, ButtonKind.Normal, 110, EditArgs);
            AddButton(v绑定命令…v, ButtonKind.Normal, 110, BindCommand);
            AddButton(v后台常驻v, ButtonKind.Normal, 104, Persist);
            AddButton(v启动诊断v, ButtonKind.Normal, 100, Diagnose);
            AddButton(v查看档案v, ButtonKind.Normal, 96, ShowCatalog);
            AddButton(v移除v, ButtonKind.Danger, 80, RemoveProgram);
        }

        private void AddButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 0) };
            b.Click += (s, e) => onClick();
            _buttons.Add(b);
            _actions.Controls.Add(b);
        }

        protected override void OnActivated()
        {
            Load();
        }

        // Run-GuiReadyPrograms.ps1 -Mode list -> Data.Items（含兼容结论）
        public void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState(v读取中…v, vInfov);

            Bridge.Run(@vgui\Run-GuiReadyPrograms.ps1v, vlistv, null,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey(vDatav) ? d[vDatav] : null);
                    var items = Bridge.List(data != null && data.ContainsKey(vItemsv) ? data[vItemsv] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);

                        var rows = new List<string[]>();
                        foreach (var it in items)
                        {
                            rows.Add(new[]
                            {
                                Bridge.Str(it, vNamev),
                                Bridge.Str(it, vPathv),
                                Bridge.Str(it, vArgsv),
                                Bridge.Str(it, vVerdictv),
                                Bridge.Str(it, vCmdv)
                            });
                        }
                        _table.SetRows(rows);
                        SetState(rows.Count + v 个程序v, rows.Count > 0 ? vInfov : vNeutralv);
                        Log(v[INFO] 程序清单：v + rows.Count + v 个v);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState(v读取失败v, vDangerv);
                    Log(v[WARN] 程序清单读取失败: v + err);
                }), 120000);
        }

        private Dictionary<string, object> Selected()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _items.Count) return null;
            return _items[idx];
        }

        private void AddProgram()
        {
            string path;
            using (var dlg = new OpenFileDialog())
            {
                dlg.Title = v选择要加入的程序v;
                dlg.Filter = v可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*v;
                if (dlg.ShowDialog(FindForm()) != DialogResult.OK) return;
                path = dlg.FileName;
            }

            var args = new Dictionary<string, object>();
            args[vPathv] = path;
            Log(v[STEP] 加入程序 v + path);
            Bridge.Run(@vgui\Run-GuiReadyPrograms.ps1v, vaddv, args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey(vDatav) ? d[vDatav] : null);
                    string rec = Bridge.Str(data, vArgsv);
                    Log((Bridge.Bool(data, vAddedv, true) ? v[OK] 已加入：v : v[INFO] 已在清单里：v) + path);
                    if (rec.Length > 0) Log(v[INFO] 已自动带入档案推荐参数：v + rec);
                    Load();
                }),
                err => SafeInvoke(() => Log(v[WARN] 加入失败: v + err)), 60000);
        }

        private void LaunchSelected()
        {
            var it = Selected();
            if (it == null) { Log(v[WARN] 先选中一个程序v); return; }

            string path = Bridge.Str(it, vPathv);
            string args = Bridge.Str(it, vArgsv);
            if (!System.IO.File.Exists(path))
            {
                Log(v[WARN] 文件不存在：v + path);
                return;
            }
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = path,
                    Arguments = args,
                    UseShellExecute = true,
                    WorkingDirectory = System.IO.Path.GetDirectoryName(path)
                };
                System.Diagnostics.Process.Start(psi);
                Log(v[OK] 已启动 v + Bridge.Str(it, vNamev) + (args.Length > 0 ? v v + args : vv));
            }
            catch (Exception ex)
            {
                Log(v[WARN] 启动失败: v + ex.Message);
            }
        }

        private void EditArgs()
        {
            var it = Selected();
            if (it == null) { Log(v[WARN] 先选中一个程序v); return; }

            var v = Dialogs.Prompt(FindForm(), v设置启动参数v,
                v留空表示不带参数。档案里的推荐参数已经预填。v,
                new List<PromptField> { new PromptField(v启动参数v, Bridge.Str(it, vArgsv)) }, v保存v);
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args[vPathv] = Bridge.Str(it, vPathv);
            args[vArgsv] = v[0];
            Bridge.Run(@vgui\Run-GuiReadyPrograms.ps1v, vupdatev, args,
                d => SafeInvoke(() =>
                {
                    Log(v[OK] 已保存启动参数：v + Bridge.Str(it, vNamev));
                    Load();
                }),
                err => SafeInvoke(() => Log(v[WARN] 保存参数失败: v + err)), 60000);
        }

        private void BindCommand()
        {
            var it = Selected();
            if (it == null) { Log(v[WARN] 先选中一个程序v); return; }

            var v = Dialogs.Prompt(FindForm(), v绑定终端命令v,
                v只允许字母、数字、点、下划线、加号、减号；留空表示解除绑定。\nv +
                v写入 System32 需要管理员权限。v,
                new List<PromptField> { new PromptField(v命令名（如 wx）v, Bridge.Str(it, vCmdv)) }, v绑定v);
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args[vPathv] = Bridge.Str(it, vPathv);
            args[vAliasv] = v[0].Trim();
            Bridge.Run(@vgui\Run-GuiReadyPrograms.ps1v, vbindv, args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey(vDatav) ? d[vDatav] : null);
                    if (Bridge.Bool(data, vOkv))
                    {
                        string cmd = Bridge.Str(data, vCmdv);
                        if (cmd.Length == 0) Log(v[OK] 已解除终端命令绑定v);
                        else Log(v[OK] 已绑定命令 v + cmd + v → v + Bridge.Str(it, vNamev));
                    }
                    else
                    {
                        Log(v[WARN] 绑定失败：v + BindError(Bridge.Str(data, vCodev)));
                    }
                    Load();
                }),
                err => SafeInvoke(() => Log(v[WARN] 绑定失败: v + err)), 60000);
        }

        private static string BindError(string code)
        {
            switch (code)
            {
                case vAliasEmptyv: return v命令名不能为空v;
                case vAliasTooLongv: return v命令名太长（上限 32 个字符）v;
                case vAliasBadCharv: return v命令名只能包含字母、数字、点、下划线、加号、减号v;
                case vAliasReservedv: return v这是系统或工具的保留命令名，换一个v;
                case vExeMissingv: return v程序文件不存在v;
                case vOccupiedv: return vSystem32 里已有同名 .cmd，且不是本工具写的，不覆盖v;
                default: return string.IsNullOrEmpty(code) ? v写入失败v : (v写入失败：v + code);
            }
        }

        private void Persist()
        {
            var it = Selected();
            if (it == null) { Log(v[WARN] 先选中一个程序v); return; }
            string path = Bridge.Str(it, vPathv);
            if (!Dialogs.Confirm(FindForm(), v设为后台常驻v,
                v会用 SYSTEM 计划任务启动它，进程不会随远程会话断开被杀掉。\n\n程序：v + path, v设为常驻v))
                return;

            var args = new Dictionary<string, object>();
            args[vPathv] = path;
            args[vNamev] = vv;
            args[vArgsv] = Bridge.Str(it, vArgsv);
            args[vWorkDirv] = vv;
            args[vAtStartupv] = false;
            args[vDryRunv] = false;
            bool started = Actions.RunAction(vpersistent-runv, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() => Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) +
                                         v后台常驻设置结束，退出码 v + r.ExitCode)),
                err => SafeInvoke(() => Log(v[WARN] 后台常驻未启动: v + err)));
            if (started) Log(v[STEP] 已提交动作 持久化启动程序（persistent-run）v);
        }

        private void Diagnose()
        {
            var it = Selected();
            if (it == null) { Log(v[WARN] 先选中一个程序v); return; }

            var args = new Dictionary<string, object>();
            args[vPathv] = Bridge.Str(it, vPathv);
            args[vDryRunv] = false;
            bool started = Actions.RunAction(vdiagv, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() => Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) +
                                         v诊断结束，退出码 v + r.ExitCode)),
                err => SafeInvoke(() => Log(v[WARN] 诊断未启动: v + err)));
            if (started) Log(v[STEP] 已提交动作 启动并诊断（diag）v);
        }

        private void ShowCatalog()
        {
            var it = Selected();
            if (it == null) { Log(v[WARN] 先选中一个程序v); return; }

            var args = new Dictionary<string, object>();
            args[vPathv] = Bridge.Str(it, vPathv);
            Bridge.Run(@vgui\Run-GuiReadyPrograms.ps1v, vcatalogv, args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey(vDatav) ? d[vDatav] : null);
                    var entry = Bridge.Dict(data != null && data.ContainsKey(vEntryv) ? data[vEntryv] : null);
                    var ctx = Bridge.Dict(data != null && data.ContainsKey(vContextv) ? data[vContextv] : null);
                    if (ctx != null)
                        Log(v[INFO] 类型：子系统 v + Bridge.Str(ctx, vSubsystemv) +
                            v · .NET v + (Bridge.Bool(ctx, vIsDotNetv) ? v是v : v否v) +
                            (Bridge.Str(ctx, vKindTagv).Length > 0 ? v · v + Bridge.Str(ctx, vKindTagv) : vv));
                    if (entry == null) { Log(v[WARN] 档案里没有匹配条目v); return; }
                    Log(v[OK] v + Bridge.Str(entry, vNamev) + v（v + Bridge.Str(entry, vIdv) + v）v);
                    Log(v[INFO] 结论：v + Bridge.Str(entry, vVerdictv) + v · 类型 v + Bridge.Str(entry, vTypev));
                    if (Bridge.Str(entry, vLaunchArgsv).Length > 0)
                        Log(v[INFO] 推荐参数：v + Bridge.Str(entry, vLaunchArgsv));
                    if (Bridge.Str(entry, vNotesv).Length > 0) Log(v[INFO] v + Bridge.Str(entry, vNotesv));
                    if (Bridge.Str(entry, vEvidencev).Length > 0) Log(v[INFO] 证据：v + Bridge.Str(entry, vEvidencev));
                }),
                err => SafeInvoke(() => Log(v[WARN] 读取档案失败: v + err)), 60000);
        }

        private void RemoveProgram()
        {
            var it = Selected();
            if (it == null) { Log(v[WARN] 先选中一个程序v); return; }
            string name = Bridge.Str(it, vNamev);
            if (!Dialogs.Confirm(FindForm(), v移除程序v,
                v只从清单里移除「v + name + v」，不会删除磁盘上的文件。绑定的终端命令也会一起解绑。v, v移除v))
                return;

            var args = new Dictionary<string, object>();
            args[vPathv] = Bridge.Str(it, vPathv);
            Bridge.Run(@vgui\Run-GuiReadyPrograms.ps1v, vremovev, args,
                d => SafeInvoke(() =>
                {
                    Log(v[OK] 已移除 v + name);
                    Load();
                }),
                err => SafeInvoke(() => Log(v[WARN] 移除失败: v + err)), 60000);
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void BuildContent() { }

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

    // ------------------------------------------------------------ 程序档案（兼容知识库）
    internal sealed class CatalogPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private bool _busy;

        public CatalogPage()
        {
            Key = vcatalogv;
            TitleText = v兼容档案v;
            Subtitle = v程序在 Server Core 上能不能跑、要补什么运行时、推荐哪些启动参数；这里是内置与自建的程序兼容档案。v;
            Glyph = vappv;
            Accent = Theme.AccentOf(vappv);

            _state = new Pill(v未读取v, vNeutralv);
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _table = new DataTable { Location = new Point(0, 76) };
            _table.Columns.Add(new DataColumn(v名称v, 230));
            _table.Columns.Add(new DataColumn(v匹配v, 150));
            _table.Columns.Add(new DataColumn(v结论v, 100));
            _table.Columns.Add(new DataColumn(v推荐参数v, 170));
            _table.Columns.Add(new DataColumn(v来源v, 80));
            _table.Columns.Add(new DataColumn(v备注v, 290));
            _table.RowActivated += ShowDetail;
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton(v添加档案…v, ButtonKind.Primary, 116, AddEntry);
            AddButton(v删除选中v, ButtonKind.Danger, 104, RemoveEntry);
            AddButton(v刷新v, ButtonKind.Normal, 80, Load);
        }

        private void AddButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 0) };
            b.Click += (s, e) => onClick();
            _buttons.Add(b);
            _actions.Controls.Add(b);
        }

        protected override void OnActivated()
        {
            Load();
        }

        // Run-GuiReadyCatalog.ps1 -Mode list -> 顶层 Items
        public void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState(v读取中…v, vInfov);

            Bridge.Run(@vgui\Run-GuiReadyCatalog.ps1v, vlistv, null,
                d =>
                {
                    var items = Bridge.List(d.ContainsKey(vItemsv) ? d[vItemsv] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);

                        var rows = new List<string[]>();
                        int user = 0;
                        foreach (var it in items)
                        {
                            if (Bridge.Bool(it, vIsUserEntryv)) user++;
                            rows.Add(new[]
                            {
                                Bridge.Str(it, vNamev, Bridge.Str(it, vIdv)),
                                Clean(Bridge.Str(it, vMatchv)),
                                Bridge.Str(it, vVerdictv),
                                Clean(Bridge.Str(it, vLaunchArgsv)),
                                Bridge.Bool(it, vIsUserEntryv) ? v自建v : v内置v,
                                Clean(Bridge.Str(it, vNotesv))
                            });
                        }
                        _table.SetRows(rows);
                        SetState(rows.Count + v 条 · 自建 v + user, rows.Count > 0 ? vInfov : vNeutralv);
                        Log(v[INFO] 程序档案：v + rows.Count + v 条（自建 v + user + v 条）v);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState(v读取失败v, vDangerv);
                    Log(v[WARN] 程序档案读取失败: v + err);
                }), 60000);
        }

        // 档案里的「空」有很多种写法，统一收一下
        private static string Clean(string s)
        {
            if (string.IsNullOrEmpty(s)) return vv;
            s = s.Trim(' ', '、', ',', ';');
            return s;
        }

        private void ShowDetail(int idx)
        {
            if (idx < 0 || idx >= _items.Count) return;
            var it = _items[idx];
            Log(v[INFO] v + Bridge.Str(it, vNamev) +
                v · 结论 v + Bridge.Str(it, vVerdictv) +
                v · 匹配 v + Clean(Bridge.Str(it, vMatchv)) +
                (Clean(Bridge.Str(it, vLaunchArgsv)).Length > 0
                    ? v · 参数 v + Clean(Bridge.Str(it, vLaunchArgsv)) : vv));
            string notes = Clean(Bridge.Str(it, vNotesv));
            if (notes.Length > 0) Log(v[INFO] v + notes);
        }

        private void AddEntry()
        {
            var win = FindForm();
            var fields = new List<PromptField>
            {
                new PromptField(v名称v, vv, false, v例如：VS Code（Electron）v),
                new PromptField(v匹配的 exe 名（正则）v, vv, false, @v例如：^Code\.exe$v),
                new PromptField(v结论v, v可用v, false, v可选：可用 / 可用（建议参数）/ 不支持 / 未知v),
                new PromptField(v推荐启动参数v, vv, false, v例如：--disable-gpu --no-sandboxv),
                new PromptField(v备注v, vv, true, v补充说明：要补的运行时、已知问题…v)
            };
            string[] v = Dialogs.Prompt(win, v添加程序档案v,
                v写进你自己的用户档案，优先级高于内置条目；Id 会自动生成。v, fields, v写入v);
            if (v == null) return;
            if (v[0].Trim().Length == 0 || v[1].Trim().Length == 0)
            {
                Log(v[WARN] 名称和匹配规则都不能为空v);
                return;
            }

            var args = new Dictionary<string, object>();
            args[vNamev] = v[0].Trim();
            args[vExeNamev] = v[1].Trim();
            args[vVerdictv] = v[2].Trim();
            args[vLaunchArgsv] = v[3].Trim();
            args[vNotesv] = v[4].Trim();

            Log(v[STEP] 写入用户档案：v + v[0].Trim());
            Bridge.Run(@vgui\Run-GuiReadyCatalog.ps1v, vaddv, args,
                d => SafeInvoke(() =>
                {
                    Log(v[OK] 已写入档案v);
                    Load();
                }),
                err => SafeInvoke(() => Log(v[WARN] 写入档案失败: v + err)), 60000);
        }

        private void RemoveEntry()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _items.Count)
            {
                Log(v[WARN] 先选中一条档案v);
                return;
            }
            var it = _items[idx];
            if (!Bridge.Bool(it, vIsUserEntryv))
            {
                Log(v[WARN] 内置条目不能删除；要改就在下面「添加档案」里同名覆盖成自建条目v);
                return;
            }
            string name = Bridge.Str(it, vNamev);
            string id = Bridge.Str(it, vIdv);
            if (!Dialogs.Confirm(FindForm(), v删除档案v, v确定从用户档案里删除「v + name + v」？v, v删除v)) return;

            var args = new Dictionary<string, object>();
            args[vIdv] = id;
            Bridge.Run(@vgui\Run-GuiReadyCatalog.ps1v, vremovev, args,
                d => SafeInvoke(() =>
                {
                    Log(v[OK] 已删除 v + name);
                    Load();
                }),
                err => SafeInvoke(() => Log(v[WARN] 删除失败: v + err)), 60000);
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void BuildContent() { }

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

    // ------------------------------------------------------------ 结构审计
    internal sealed class AuditPage : PageBase
    {
        private static readonly string[] Levels = { v全部v, v信息v, v成功v, v警告v, v错误v };
        private static readonly string[] RangeTexts = { v全部时间v, v近 24 小时v, v近 7 天v, v近 30 天v };
        private static readonly int[] RangeHours = { 0, 24, 168, 720 };

        private readonly Panel _bar;
        private readonly List<Pill> _pills = new List<Pill>();
        private readonly UiInput _kw;
        private readonly UiButton _range;
        private readonly UiButton _refresh;
        private readonly UiButton _export;
        private readonly DataTable _table;
        private readonly string[] _levelRow;
        private readonly List<string[]> _allRows = new List<string[]>();
        private readonly List<Dictionary<string, object>> _allRaw = new List<Dictionary<string, object>>();
        private readonly List<Dictionary<string, object>> _viewRaw = new List<Dictionary<string, object>>();
        private readonly List<DateTime?> _rowTime = new List<DateTime?>();
        private string _level = v全部v;
        private int _rangeIdx;
        private bool _busy;

        public AuditPage()
        {
            Key = vauditv;
            TitleText = v操作审计v;
            Subtitle = v提交、执行、配置备份与恢复全在这里留痕；只追加、不修改，可按级别/时间/关键词筛选后导出。目录与文件完整性检查在「关于 → 完整性自检」。v;
            Glyph = vauditv;
            Accent = Theme.AccentOf(vauditv);

            _bar = new Panel { Height = 32, BackColor = Color.Transparent };
            Controls.Add(_bar);

            _levelRow = Levels;
            foreach (var lv in Levels)
            {
                var p = new Pill(lv, lv == v全部v ? vInfov : vNeutralv);
                string captured = lv;
                p.Cursor = Cursors.Hand;
                p.Click += (s, e) => SetLevel(captured);
                _pills.Add(p);
                _bar.Controls.Add(p);
            }

            _refresh = new UiButton(v刷新v, ButtonKind.Normal, 84, 32) { Location = new Point(0, 0) };
            _refresh.Click += (s, e) => Reload();
            _bar.Controls.Add(_refresh);

            _export = new UiButton(v导出v, ButtonKind.Normal, 84, 32) { Location = new Point(0, 0) };
            _export.Click += (s, e) => ExportAudit();
            _bar.Controls.Add(_export);

            // 关键词：在已取到的记录里即时过滤，不用等子进程
            _kw = new UiInput(190) { Location = new Point(0, 0) };
            _kw.Box.TextChanged += (s, e) => ApplyFilter();
            _bar.Controls.Add(_kw);

            // 时间窗：换窗口要重新取数（Limit 是本窗口里的前 300 条），所以点一下直接 Reload
            _range = new UiButton(RangeTexts[0], ButtonKind.Normal, 104, 32) { Location = new Point(0, 0) };
            _range.Click += (s, e) =>
            {
                _rangeIdx = (_rangeIdx + 1) % RangeTexts.Length;
                _range.Text = RangeTexts[_rangeIdx];
                _range.Invalidate();
                Reload();
            };
            _bar.Controls.Add(_range);

            _table = new DataTable { Location = new Point(0, 116) };
            _table.Columns.Add(new DataColumn(v时间v, 140));
            _table.Columns.Add(new DataColumn(v级别v, 60));
            _table.Columns.Add(new DataColumn(v事件v, 110));
            _table.Columns.Add(new DataColumn(v动作v, 130));
            _table.Columns.Add(new DataColumn(v任务v, 170));
            _table.Columns.Add(new DataColumn(v详情v, 320));
            _table.RowActivated += ShowDetail;
            _table.ActivateOnDoubleClick = true;
            Controls.Add(_table);
        }

        // 双击看完整详情（表格里详情列会截断，导出前想确认内容时用这个）
        private void ShowDetail(int idx)
        {
            if (idx < 0 || idx >= _viewRaw.Count) return;
            var e = _viewRaw[idx];
            if (e == null) return;
            string body = v时间：v + TaskTime(Bridge.Str(e, vTimev)) + v\r\nv +
                          v级别：v + LevelText(Bridge.Str(e, vLevelv)) + v\r\nv +
                          v事件：v + EventText(Bridge.Str(e, vEventv)) + v（v + Bridge.Str(e, vEventv) + v）\r\nv +
                          v动作：v + Bridge.Str(e, vActionIdv) + v\r\nv +
                          v任务：v + Bridge.Str(e, vTaskIdv) + v\r\nv +
                          v用户：v + Bridge.Str(e, vUserv) + v\r\nv +
                          v机器：v + Bridge.Str(e, vMachinev) + v\r\nv +
                          new string('-', 60) + v\r\nv + Bridge.Str(e, vDetailv);
            Dialogs.Text(FindForm(), v审计详情v, Bridge.Str(e, vTaskIdv), body);
        }

        protected override void OnActivated()
        {
            Reload();
        }

        // 走既有 runner：Run-GuiReadyTasks.ps1 -Mode audit -> {Data:{Items,Count}}
        public void Reload()
        {
            if (_busy) return;
            _busy = true;

            var args = new Dictionary<string, object>();
            args[vLimitv] = 300;
            if (RangeHours[_rangeIdx] > 0) args[vSinceHoursv] = RangeHours[_rangeIdx];

            Bridge.Run(@vgui\Run-GuiReadyTasks.ps1v, vauditv, args,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey(vDatav) ? d[vDatav] : null);
                    var items = Bridge.List(data != null && data.ContainsKey(vItemsv) ? data[vItemsv] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _allRows.Clear();
                        _allRaw.Clear();
                        _rowTime.Clear();
                        foreach (var e in items)
                        {
                            string detail = Bridge.Str(e, vDetailv).Replace(v\rv, v v).Replace(v\nv, v v);
                            string iso = Bridge.Str(e, vTimev);
                            _rowTime.Add(ParseTime(iso));
                            _allRaw.Add(e);
                            _allRows.Add(new[]
                            {
                                TaskTime(iso),
                                LevelText(Bridge.Str(e, vLevelv)),
                                EventText(Bridge.Str(e, vEventv)),
                                Bridge.Str(e, vActionIdv),
                                Bridge.Str(e, vTaskIdv),
                                detail
                            });
                        }
                        ApplyFilter();
                        Log(v[INFO] 审计记录：v + _allRows.Count + v 条（v + RangeTexts[_rangeIdx] + v）v);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    Log(v[WARN] 审计记录读取失败: v + err);
                }), 120000);
        }

        private void SetLevel(string level)
        {
            _level = level;
            for (int i = 0; i < _pills.Count; i++)
            {
                _pills[i].Kind = (_levelRow[i] == level) ? vInfov : vNeutralv;
                _pills[i].Invalidate();
            }
            ApplyFilter();
        }

        // 导出当前级别的审计记录（走 tasks runner 的 audit-export，会顺带写一条审计）
        private void ExportAudit()
        {
            string stamp = DateTime.Now.ToString(vyyyyMMdd-HHmmssv);
            string def = System.IO.Path.Combine(Bridge.StatePath, vaudit-v + stamp + v.csvv);
            var v = Dialogs.Prompt(FindForm(), v导出审计记录v,
                v导出「v + _level + v · v + RangeTexts[_rangeIdx] +
                (_kw.ValueText.Trim().Length > 0 ? v · 关键词 v + _kw.ValueText.Trim() : vv) +
                v」的记录（最多 5000 条）。\n格式填 Csv 或 Jsonl。v,
                new List<PromptField>
                {
                    new PromptField(v导出文件（绝对路径）v, def),
                    new PromptField(v格式（Csv / Jsonl）v, vCsvv)
                }, v导出v);
            if (v == null || v[0].Trim().Length == 0) return;

            string fmt = v.Length > 1 && v[1].Trim().Length > 0 ? v[1].Trim() : vCsvv;
            if (fmt.IndexOf(vjsonv, StringComparison.OrdinalIgnoreCase) >= 0) fmt = vJsonlv;
            else fmt = vCsvv;

            var args = new Dictionary<string, object>();
            args[vPathv] = v[0].Trim();
            args[vFormatv] = fmt;
            args[vLimitv] = 5000;
            if (_level == v信息v) args[vLevelv] = vInfov;
            else if (_level == v成功v) args[vLevelv] = vSuccessv;
            else if (_level == v警告v) args[vLevelv] = vWarnv;
            else if (_level == v错误v) args[vLevelv] = vErrorv;
            // 导出的内容要和屏幕上看到的一致：时间窗 + 关键词一起带上
            if (RangeHours[_rangeIdx] > 0) args[vSinceHoursv] = RangeHours[_rangeIdx];
            string kw = _kw.ValueText.Trim();
            if (kw.Length > 0) args[vKeywordv] = kw;

            Bridge.Run(@vgui\Run-GuiReadyTasks.ps1v, vaudit-exportv, args,
                d => SafeInvoke(() =>
                {
                    var data = Bridge.Dict(d.ContainsKey(vDatav) ? d[vDatav] : null);
                    Log(v[OK] 审计已导出：v + Bridge.Str(data, vPathv) +
                        v（v + (int)Bridge.Num(data, vCountv) + v 条）v);
                }),
                err => SafeInvoke(() => Log(v[WARN] 审计导出失败: v + err)), 120000);
        }

        private void ApplyFilter()
        {
            string kw = _kw == null ? vv : _kw.ValueText.Trim();
            DateTime? since = null;
            int hours = RangeHours[_rangeIdx];
            if (hours > 0) since = DateTime.Now.AddHours(-hours);

            var list = new List<string[]>();
            _viewRaw.Clear();
            for (int i = 0; i < _allRows.Count; i++)
            {
                var r = _allRows[i];
                if (_level != v全部v && r[1] != _level) continue;
                if (since.HasValue)
                {
                    // 时间解析不出来的（极少）保留，别让一条脏数据把整行藏掉
                    if (i < _rowTime.Count && _rowTime[i].HasValue && _rowTime[i].Value < since.Value) continue;
                }
                if (kw.Length > 0 && !RowMatches(r, kw)) continue;
                list.Add(r);
                _viewRaw.Add(i < _allRaw.Count ? _allRaw[i] : null);
            }
            _table.SetRows(list);
        }

        private static bool RowMatches(string[] row, string kw)
        {
            foreach (var cell in row)
                if (cell != null && cell.IndexOf(kw, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            return false;
        }

        private static DateTime? ParseTime(string iso)
        {
            if (string.IsNullOrEmpty(iso)) return null;
            DateTime t;
            if (!DateTime.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.RoundtripKind, out t)) return null;
            return t;
        }

        private static string TaskTime(string iso)
        {
            var t = ParseTime(iso);
            return t.HasValue ? t.Value.ToString(vMM-dd HH:mm:ssv) : v-v;
        }

        private static string LevelText(string s)
        {
            switch (s)
            {
                case vInfov: return v信息v;
                case vWarnv: return v警告v;
                case vErrorv: return v错误v;
                case vSuccessv: return v成功v;
                default: return string.IsNullOrEmpty(s) ? v信息v : s;
            }
        }

        private static string EventText(string s)
        {
            switch (s)
            {
                case vtask-queuedv: return v提交任务v;
                case vtask-startv: return v开始执行v;
                case vtask-finishv: return v执行结束v;
                case vconfig-exportv: return v配置备份v;
                case vconfig-importv: return v配置恢复v;
                case vaudit-exportv: return v审计导出v;
                default: return string.IsNullOrEmpty(s) ? v事件v : s;
            }
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _bar.Left = 0;
            _bar.Top = 76;
            _bar.Width = Math.Max(200, w - 4);

            int x = 0;
            foreach (var p in _pills)
            {
                p.Top = 4;
                p.Left = x;
                x += p.Width + 8;
            }
            _kw.Top = 0;
            _kw.Left = x;
            x += _kw.Width + 8;
            _range.Top = 0;
            _range.Left = x;
            x += _range.Width + 8;
            _refresh.Left = Math.Max(x, _bar.Width - _refresh.Width - 4);
            _refresh.Top = 0;
            _export.Left = Math.Max(x, _refresh.Left - _export.Width - 8);
            _export.Top = 0;

            _table.Left = 0;
            _table.Top = 116;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(120, ClientSize.Height - 124);
        }
    }

    // ------------------------------------------------------------ 远程主机
    internal sealed class HostsPage : PageBase
    {
        private readonly DataTable _table;
        private readonly Panel _bar;
        private readonly UiInput _kw;
        private readonly UiButton _tagBtn;
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly Pill _sum;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private readonly List<Dictionary<string, object>> _view = new List<Dictionary<string, object>>();
        private readonly List<string> _tags = new List<string>();
        private readonly List<string> _trusted = new List<string>();
        private int _tagIdx;
        private bool _busy;
        private string _sumBase = vv;

        public HostsPage()
        {
            Key = vhostsv;
            TitleText = v远程主机v;
            Subtitle = v维护 WinRM 主机清单、测试连通性、批量执行命令；可勾选多台一起测试 / 执行，凭据用 DPAPI 加密，双击看完整信息。v;
            Glyph = vhostsv;
            Accent = Theme.AccentOf(vhostsv);

            _sum = new Pill(v读取中v, vNeutralv);
            Head.Slot.Controls.Add(_sum);
            Head.Slot.Width = _sum.Width;

            _bar = new Panel { Height = 32, BackColor = Color.Transparent };
            Controls.Add(_bar);

            _kw = new UiInput(200) { Location = new Point(0, 0) };
            _kw.Box.TextChanged += (s, e) => ApplyFilter();
            _bar.Controls.Add(_kw);

            _tagBtn = new UiButton(v标签：全部v, ButtonKind.Normal, 130, 32) { Location = new Point(0, 0) };
            _tagBtn.Click += (s, e) =>
            {
                if (_tags.Count == 0) return;
                _tagIdx = (_tagIdx + 1) % _tags.Count;
                _tagBtn.Text = _tagIdx == 0 ? v标签：全部v : v标签：v + _tags[_tagIdx];
                _tagBtn.Invalidate();
                ApplyFilter();
            };
            _bar.Controls.Add(_tagBtn);

            _table = new DataTable { Location = new Point(0, 118) };
            // 勾选列：批量测试 / 批量命令默认只作用于勾上的主机
            _table.Columns.Add(new DataColumn(v选v, 44));
            _table.Columns.Add(new DataColumn(v名称v, 100));
            _table.Columns.Add(new DataColumn(v地址v, 130));
            _table.Columns.Add(new DataColumn(v端口v, 50, true));
            _table.Columns.Add(new DataColumn(v协议v, 70));
            _table.Columns.Add(new DataColumn(v认证v, 90));
            _table.Columns.Add(new DataColumn(v凭据v, 60));
            _table.Columns.Add(new DataColumn(v标签v, 100));
            _table.Columns.Add(new DataColumn(v最近测试v, 120));
            _table.Columns.Add(new DataColumn(v状态v, 70));
            _table.Columns.Add(new DataColumn(v备注v, 150));
            _table.RowActivated += ShowHostDetail;
            _table.ActivateOnDoubleClick = true;
            _table.CheckColumn = 0;
            _table.CheckChanged += (idx, on) => UpdateCheckedHint();
            Controls.Add(_table);

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            AddButton(v添加主机v, ButtonKind.Primary, 104, AddHost);
            AddButton(v刷新v, ButtonKind.Normal, 80, Reload);
            AddButton(v编辑v, ButtonKind.Normal, 80, EditHost);
            AddButton(v删除v, ButtonKind.Danger, 80, RemoveHost);
            AddButton(v测试连接v, ButtonKind.Normal, 104, TestSelected);
            AddButton(v批量命令v, ButtonKind.Normal, 104, BatchCommand);
            AddButton(v保存凭据v, ButtonKind.Normal, 104, SaveCredential);
            AddButton(v启用/禁用v, ButtonKind.Normal, 104, ToggleEnabled);
            AddButton(v信任设置v, ButtonKind.Normal, 104, TrustSettings);
        }

        private void AddButton(string text, ButtonKind kind, int width, Action onClick)
        {
            var b = new UiButton(text, kind, width, 36) { Location = new Point(0, 0) };
            b.Click += (s, e) => onClick();
            _buttons.Add(b);
            _actions.Controls.Add(b);
        }

        // 走既有 runner：Run-GuiReadyRemote.ps1 -Mode test（会顺带回写主机的最近测试结果）
        private void TestSelected()
        {
            // 勾了主机就批量测这些；没勾就测当前选中行
            var checkedHosts = CheckedAddresses();
            string spec;
            if (checkedHosts.Count > 0)
            {
                spec = string.Join(v,v, checkedHosts.ToArray());
            }
            else
            {
                int idx = _table.SelectedIndex;
                if (idx < 0 || idx >= _table.Rows.Count)
                {
                    Log(v[WARN] 先在列表里选中一台主机（或勾选多台）v);
                    return;
                }
                spec = _table.Rows[idx][2];
            }
            Log(v[STEP] 测试连接 v + spec + v（最多 30 秒）v);

            var args = new Dictionary<string, object>();
            args[vHostsv] = spec;
            args[vTimeoutSecv] = 30;
            Bridge.Run(@vgui\Run-GuiReadyRemote.ps1v, vtestv, args,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey(vDatav) ? d[vDatav] : null);
                    var results = Bridge.List(data != null && data.ContainsKey(vResultsv) ? data[vResultsv] : null);
                    SafeInvoke(() =>
                    {
                        foreach (var r in results)
                        {
                            bool ok = Bridge.Str(r, vStatusv) == vOKv;
                            Log((ok ? v[OK] v : v[ERROR] v) + Bridge.Str(r, vNamev) +
                                v（v + Bridge.Str(r, vAddressv) + v）v +
                                Bridge.Str(r, vDetailv) + v · v +
                                Bridge.Num(r, vDurationSecv).ToString(v0.0v) + v 秒v);
                        }
                        Reload();
                    });
                },
                err => SafeInvoke(() => Log(v[WARN] 连接测试失败: v + err)), 180000);
        }

        private Dictionary<string, object> SelectedHost()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _view.Count) return null;
            return _view[idx];
        }

        private void AddHost()
        {
            var fields = new List<PromptField>
            {
                new PromptField(v名称v, vv, false, v清单里显示的名字，不能重复v),
                new PromptField(v地址v, vv, false, vIP 或主机名v),
                new PromptField(v端口v, v5985v, false, vHTTP 5985 / HTTPS 5986，留空按协议默认v),
                new PromptField(v备注v, vv, false, v可选v)
            };
            string[] v = Dialogs.Prompt(FindForm(), v添加主机v,
                v凭据不在这里填：先在「全部功能 → 远程批量执行」里跑一次，或在 PowerShell 版里保存。v,
                fields, v添加v);
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args[vNamev] = v[0].Trim();
            args[vAddressv] = v[1].Trim();
            int port;
            args[vPortv] = int.TryParse(v[2].Trim(), out port) ? port : 0;
            args[vNotesv] = v[3].Trim();

            Bridge.Run(@vgui\Run-GuiReadyRemote.ps1v, vhost-addv, args,
                d => SafeInvoke(() =>
                {
                    Log(v[OK] 已添加主机 v + v[0].Trim());
                    Reload();
                }),
                err => SafeInvoke(() => Log(v[WARN] 添加主机失败: v + err)), 60000);
        }

        private void EditHost()
        {
            var h = SelectedHost();
            if (h == null) { Log(v[WARN] 先选中一台主机v); return; }

            var fields = new List<PromptField>
            {
                new PromptField(v名称v, Bridge.Str(h, vNamev)),
                new PromptField(v地址v, Bridge.Str(h, vAddressv)),
                new PromptField(v端口v, ((int)Bridge.Num(h, vPortv)).ToString()),
                new PromptField(v备注v, Bridge.Str(h, vNotesv))
            };
            string[] v = Dialogs.Prompt(FindForm(), v编辑主机v, v改完点保存，会写回主机清单。v, fields, v保存v);
            if (v == null) return;

            var args = new Dictionary<string, object>();
            args[vIdv] = Bridge.Str(h, vIdv);
            args[vNamev] = v[0].Trim();
            args[vAddressv] = v[1].Trim();
            int port;
            args[vPortv] = int.TryParse(v[2].Trim(), out port) ? port : 0;
            args[vNotesv] = v[3].Trim();

            Bridge.Run(@vgui\Run-GuiReadyRemote.ps1v, vhost-updatev, args,
                d => SafeInvoke(() =>
                {
                    Log(v[OK] 已保存主机 v + v[0].Trim());
                    Reload();
                }),
                err => SafeInvoke(() => Log(v[WARN] 保存主机失败: v + err)), 60000);
        }

        private void RemoveHost()
        {
            var h = SelectedHost();
            if (h == null) { Log(v[WARN] 先选中一台主机v); return; }
            string name = Bridge.Str(h, vNamev);
            if (!Dialogs.Confirm(FindForm(), v删除主机v,
                v确定从清单里删除「v + name + v」？保存的凭据也会一起删掉。v, v删除v)) return;

            var args = new Dictionary<string, object>();
            args[vIdv] = Bridge.Str(h, vIdv);
            Bridge.Run(@vgui\Run-GuiReadyRemote.ps1v, vhost-removev, args,
                d => SafeInvoke(() =>
                {
                    Log(v[OK] 已删除主机 v + name);
                    Reload();
                }),
                err => SafeInvoke(() => Log(v[WARN] 删除主机失败: v + err)), 60000);
        }

        // 保存 DPAPI 凭据（密码只在进程内传递，runner 读完 args.json 会立刻删掉）
        private void SaveCredential()
        {
            var h = SelectedHost();
            if (h == null) { Log(v[WARN] 先选中一台主机v); return; }

            var user = new PromptField(v用户名v, vv, false, @v格式：域\用户 或 主机名\用户v);
            var pass = new PromptField(v密码v, vv);
            pass.Secret = true;
            var v = Dialogs.Prompt(FindForm(), v保存凭据v,
                v凭据用 DPAPI 加密保存在本机，只有本机本用户能解出明文。v,
                new List<PromptField> { user, pass }, v保存v);
            if (v == null) return;
            if (v[0].Trim().Length == 0 || v[1].Length == 0)
            {
                Log(v[WARN] 用户名和密码都不能为空v);
                return;
            }

            var args = new Dictionary<string, object>();
            args[vIdv] = Bridge.Str(h, vIdv);
            args[vUserNamev] = v[0].Trim();
            args[vPasswordv] = v[1];

            Bridge.Run(@vgui\Run-GuiReadyRemote.ps1v, vhost-credv, args,
                d => SafeInvoke(() =>
                {
                    Log(v[OK] 已保存凭据：v + Bridge.Str(h, vNamev));
                    Reload();
                }),
                err => SafeInvoke(() => Log(v[WARN] 保存凭据失败: v + err)), 60000);
        }

        // 启用/禁用：影响批量命令默认目标（留空时只跑启用的主机）
        private void ToggleEnabled()
        {
            var h = SelectedHost();
            if (h == null) { Log(v[WARN] 先选中一台主机v); return; }
            bool on = Bridge.Bool(h, vEnabledv, true);

            var args = new Dictionary<string, object>();
            args[vIdv] = Bridge.Str(h, vIdv);
            args[vEnabledv] = !on;
            Bridge.Run(@vgui\Run-GuiReadyRemote.ps1v, vhost-updatev, args,
                d => SafeInvoke(() =>
                {
                    Log(v[OK] v + Bridge.Str(h, vNamev) + v 已v + (on ? v禁用v : v启用v));
                    Reload();
                }),
                err => SafeInvoke(() => Log(v[WARN] 切换启用状态失败: v + err)), 60000);
        }

        // TrustedHosts：WinRM 默认只信任域内主机，工作组环境要显式加地址
        private void TrustSettings()
        {
            var fields = new List<PromptField>
            {
                new PromptField(v添加地址v, vv, false, v可填 IP / 主机名 / 网段，多个用逗号分隔v),
                new PromptField(v移除地址v, vv, false, v填要移除的条目；两项都留空则只看不改v)
            };
            string current = _trusted.Count > 0
                ? string.Join(v、v, _trusted.ToArray())
                : v（空）v;
            string[] v = Dialogs.Prompt(FindForm(), vWinRM 信任设置v,
                v当前 TrustedHosts：v + current + v\n\n注意：改成 * 表示信任所有主机（风险自担）。v,
                fields, v应用v);
            if (v == null) return;

            string add = v[0].Trim();
            string remove = v[1].Trim();
            if (add.Length == 0 && remove.Length == 0) return;

            if (add.Length > 0)
                Bridge.Run(@vgui\Run-GuiReadyRemote.ps1v, vhost-trust-addv,
                    new Dictionary<string, object> { { vAddressv, add } },
                    d => SafeInvoke(() =>
                    {
                        Log(v[OK] 已加入 TrustedHosts：v + add);
                        if (remove.Length > 0) TrustRemove(remove); else Reload();
                    }),
                    err => SafeInvoke(() => Log(v[WARN] 加入信任失败: v + err)), 60000);
            else
                TrustRemove(remove);
        }

        private void TrustRemove(string address)
        {
            Bridge.Run(@vgui\Run-GuiReadyRemote.ps1v, vhost-trust-removev,
                new Dictionary<string, object> { { vAddressv, address } },
                d => SafeInvoke(() =>
                {
                    Log(v[OK] 已从 TrustedHosts 移除：v + address);
                    Reload();
                }),
                err => SafeInvoke(() => Log(v[WARN] 移除信任失败: v + err)), 60000);
        }

        private void BatchCommand()
        {
            var checkedHosts = CheckedAddresses();
            var h = SelectedHost();
            string spec = checkedHosts.Count > 0
                ? string.Join(v,v, checkedHosts.ToArray())
                : (h == null ? vv : Bridge.Str(h, vAddressv));
            var fields = new List<PromptField>
            {
                new PromptField(v目标主机v, spec, false, v留空 = 全部启用的主机；也可填名称/地址，逗号分隔v),
                new PromptField(v要执行的 PowerShell 命令v, vv, true, v多行命令会被当成一段脚本送到每台主机v)
            };
            string[] v = Dialogs.Prompt(FindForm(), v批量执行命令v, v结果会逐台写进运行日志。v, fields, v执行v);
            if (v == null) return;
            if (v[1].Trim().Length == 0) { Log(v[WARN] 命令不能为空v); return; }

            var args = new Dictionary<string, object>();
            args[vHostsv] = v[0].Trim();
            args[vCommandv] = v[1];
            args[vTimeoutSecv] = 120;
            args[vContinueOnErrorv] = true;
            args[vDryRunv] = false;

            bool started = Actions.RunAction(vremote-runv, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) + v批量命令结束，退出码 v + r.ExitCode +
                        v，用时 v + r.Seconds.ToString(v0.0v) + v 秒v);
                    Reload();
                }),
                err => SafeInvoke(() => Log(v[WARN] 批量命令未启动: v + err)));
            if (started) Log(v[STEP] 已提交动作 远程批量执行命令（remote-run）v);
        }

        protected override void OnActivated()
        {
            Reload();
        }

        // 页头胶囊：文字一变宽窄就变，Slot 要跟着重算，否则胶囊会溢出页头
        private void SetSum(string text, string kind)
        {
            _sumBase = text;
            _sum.SetText(text);
            _sum.SetKind(kind);
            Head.Slot.Width = _sum.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        // 勾选列：批量测试 / 批量命令只作用于勾上的主机
        private List<string> CheckedAddresses()
        {
            var list = new List<string>();
            foreach (var i in _table.Checked)
            {
                if (i < 0 || i >= _view.Count) continue;
                string addr = Bridge.Str(_view[i], vAddressv);
                if (addr.Length > 0) list.Add(addr);
            }
            return list;
        }

        private void UpdateCheckedHint()
        {
            int n = _table.Checked.Count;
            string text = n > 0
                ? v已选 v + n + v 台 · 测试连接 / 批量命令会作用于这些主机v
                : _sumBase;
            _sum.SetText(text);
            _sum.SetKind(n > 0 ? vInfov : vNeutralv);
            Head.Slot.Width = _sum.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - _sum.Width - 4);
        }

        // 走既有 runner：Run-GuiReadyRemote.ps1 -Mode hosts
        public void Reload()
        {
            if (_busy) return;
            _busy = true;
            SetSum(v读取中v, vNeutralv);

            Bridge.Run(@vgui\Run-GuiReadyRemote.ps1v, vhostsv, null,
                d =>
                {
                    var data = Bridge.Dict(d.ContainsKey(vDatav) ? d[vDatav] : null);
                    var items = Bridge.List(data != null && data.ContainsKey(vItemsv) ? data[vItemsv] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);
                        _trusted.Clear();
                        _trusted.AddRange(Bridge.StrList(data, vTrustedHostsv));

                        // 标签候选（按出现顺序去重；第 0 项留给「全部」）
                        _tags.Clear();
                        _tags.Add(v全部v);
                        foreach (var h in items)
                            foreach (var t in Bridge.StrList(h, vTagsv))
                                if (!_tags.Exists(x => string.Equals(x, t, StringComparison.OrdinalIgnoreCase)))
                                    _tags.Add(t);
                        if (_tagIdx >= _tags.Count) _tagIdx = 0;
                        _tagBtn.Text = _tagIdx == 0 ? v标签：全部v : v标签：v + _tags[_tagIdx];
                        _tagBtn.Invalidate();

                        int enabled = 0, failed = 0;
                        foreach (var h in items)
                        {
                            if (Bridge.Bool(h, vEnabledv, true)) enabled++;
                            if (Bridge.Str(h, vLastTestStatusv) == vFailedv) failed++;
                        }
                        ApplyFilter();

                        if (items.Count == 0) SetSum(v0 台v, vNeutralv);
                        else if (failed > 0) SetSum(items.Count + v 台 · 启用 v + enabled + v · 失败 v + failed, vWarnv);
                        else SetSum(items.Count + v 台 · 启用 v + enabled, enabled > 0 ? vSuccessv : vNeutralv);

                        Log(v[INFO] 主机清单：v + items.Count + v 台v);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    _view.Clear();
                    _table.SetRows(new string[0][]);
                    _sum.SetText(v读取失败v);
                    _sum.SetKind(vDangerv);
                    Head.Slot.Width = _sum.Width;
                    Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
                    Log(v[WARN] 主机清单读取失败: v + err);
                }), 120000);
        }

        // 双击看完整主机信息（表格十列挤在一起，端口/凭据/测试结果都得能看清）
        private void ShowHostDetail(int idx)
        {
            if (idx < 0 || idx >= _view.Count) return;
            var h = _view[idx];
            var tags = Bridge.StrList(h, vTagsv);
            string test = Bridge.Str(h, vLastTestStatusv);
            string body = v名称：  v + Bridge.Str(h, vNamev) + v\r\nv +
                          v地址：  v + Bridge.Str(h, vAddressv) + v:v + ((int)Bridge.Num(h, vPortv)) + v\r\nv +
                          v协议：  v + Bridge.Str(h, vProtocolv).ToUpperInvariant() + v\r\nv +
                          v认证：  v + (Bridge.Str(h, vAuthv) == vCredentialv ? v保存的凭据v : v当前用户v) + v\r\nv +
                          v凭据：  v + (Bridge.Bool(h, vHasCredentialv) ? v已保存（DPAPI 加密）v : v未保存v) + v\r\nv +
                          v启用：  v + (Bridge.Bool(h, vEnabledv, true) ? v是v : v否v) + v\r\nv +
                          v免证书：v + (Bridge.Bool(h, vAllowUntrustedv) ? v是（不校验证书）v : v否v) + v\r\nv +
                          v标签：  v + (tags.Count > 0 ? string.Join(v、v, tags.ToArray()) : v（无）v) + v\r\nv +
                          v最近测试：v + TaskTime(Bridge.Str(h, vLastTestAtv)) + v · v +
                          (test == vOKv ? v正常v : (test == vFailedv ? v失败v : v未测试v)) + v\r\nv +
                          new string('-', 60) + v\r\nv +
                          v备注\r\nv + Bridge.Str(h, vNotesv, v（无）v);
            Dialogs.Text(FindForm(), v主机详情v, Bridge.Str(h, vNamev), body);
        }

        // 关键词（名称/地址/备注/标签）+ 标签筛选，都在本地做，改一个字符就见效
        private void ApplyFilter()
        {
            string kw = _kw == null ? vv : _kw.ValueText.Trim();
            string tag = (_tagIdx > 0 && _tagIdx < _tags.Count) ? _tags[_tagIdx] : vv;

            _view.Clear();
            var rows = new List<string[]>();
            foreach (var h in _items)
            {
                var tagNames = Bridge.StrList(h, vTagsv);
                string name = Bridge.Str(h, vNamev);
                string address = Bridge.Str(h, vAddressv);
                string notes = Bridge.Str(h, vNotesv);

                if (tag.Length > 0)
                {
                    bool hit = false;
                    foreach (var t in tagNames)
                        if (string.Equals(t, tag, StringComparison.OrdinalIgnoreCase)) { hit = true; break; }
                    if (!hit) continue;
                }
                if (kw.Length > 0)
                {
                    string blob = name + v v + address + v v + notes + v v + string.Join(v v, tagNames.ToArray());
                    if (blob.IndexOf(kw, StringComparison.OrdinalIgnoreCase) < 0) continue;
                }

                _view.Add(h);
                string test = Bridge.Str(h, vLastTestStatusv);
                rows.Add(new[]
                {
                    vv,
                    name,
                    address,
                    ((int)Bridge.Num(h, vPortv)).ToString(),
                    Bridge.Str(h, vProtocolv).ToUpperInvariant(),
                    Bridge.Str(h, vAuthv) == vCredentialv ? v保存凭据v : v当前用户v,
                    Bridge.Bool(h, vHasCredentialv) ? v有v : v无v,
                    tagNames.Count > 0 ? string.Join(v、v, tagNames.ToArray()) : vv,
                    TaskTime(Bridge.Str(h, vLastTestAtv)),
                    test == vOKv ? v正常v : (test == vFailedv ? v失败v : v未测试v),
                    notes.Replace(v\rv, v v).Replace(v\nv, v v)
                });
            }
            _table.SetRows(rows);
            UpdateCheckedHint();
        }

        private static string TaskTime(string iso)
        {
            if (string.IsNullOrEmpty(iso)) return v未测试v;
            DateTime t;
            if (!DateTime.TryParse(iso, System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.RoundtripKind, out t)) return v未测试v;
            return t.ToString(vMM-dd HH:mmv);
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _bar.Left = 0;
            _bar.Top = 76;
            _bar.Width = Math.Max(200, w - 4);
            _kw.Top = 0;
            _kw.Left = 0;
            _tagBtn.Top = 0;
            _tagBtn.Left = _kw.Width + 8;

            _table.Left = 0;
            _table.Top = 118;
            _table.Width = Math.Max(200, w - 4);

            _actions.Left = 0;
            _actions.Width = Math.Max(200, w - 4);
            int bh = LayoutButtonRow(_buttons, _actions.Width, 0);
            _actions.Height = bh;
            _table.Height = Math.Max(100, ClientSize.Height - 118 - bh - 22);
            _actions.Top = _table.Bottom + 6;
        }
    }

    // ------------------------------------------------------------ 角色与功能
    internal sealed class RolePage : PageBase
    {
        private readonly Panel _bar;
        private readonly UiInput _filter;
        private readonly UiButton _scan;
        private readonly UiButton _dep;
        private readonly UiButton _install;
        private readonly UiButton _remove;
        private readonly UiButton _mode;
        private readonly UiButton _reboot;
        private readonly DataTable _table;
        private readonly Pill _state;
        private readonly List<Dictionary<string, object>> _all = new List<Dictionary<string, object>>();
        private int _modeIdx;          // 0=全部 1=仅已装 2=仅未装
        private bool _busy;

        public RolePage()
        {
            Key = vrolev;
            TitleText = v角色与功能v;
            Subtitle = v图形化装 Windows Server 角色与功能（等价于 Install-WindowsFeature）。安装需要管理员；装完是否需要重启会写进日志。v;
            Glyph = vrolev;
            Accent = Theme.AccentOf(vrolev);

            _state = new Pill(v未读取v, vNeutralv);
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _bar = new Panel { Height = 36, BackColor = Color.Transparent };
            Controls.Add(_bar);

            _filter = new UiInput(320) { Location = new Point(0, 2) };
            _filter.Box.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; ApplyFilter(); }
            };
            _scan = new UiButton(v筛选v, ButtonKind.Primary, 84, 32) { Location = new Point(0, 2) };
            _dep = new UiButton(v分析依赖v, ButtonKind.Normal, 104, 32) { Location = new Point(0, 2) };
            _scan.Click += (s, e) => ApplyFilter();
            _dep.Click += (s, e) => ShowDependencies();
            _install = new UiButton(v安装选中v, ButtonKind.Normal, 104, 32) { Location = new Point(0, 2) };
            _install.Click += (s, e) => InstallSelected();
            _remove = new UiButton(v卸载选中v, ButtonKind.Danger, 104, 32) { Location = new Point(0, 2) };
            _remove.Click += (s, e) => RemoveSelected();

            // 勾选多个后「安装选中」自动走批量队列；只看某一类时用这个模式按钮
            _mode = new UiButton(v全部v, ButtonKind.Normal, 92, 32) { Location = new Point(0, 2) };
            _mode.Click += (s, e) =>
            {
                _modeIdx = (_modeIdx + 1) % 3;
                _mode.Text = _modeIdx == 0 ? v全部v : (_modeIdx == 1 ? v仅已装v : v仅未装v);
                _mode.Invalidate();
                ApplyFilter();
            };

            _reboot = new UiButton(v重启服务器v, ButtonKind.Normal, 108, 32) { Location = new Point(0, 2) };
            _reboot.Click += (s, e) => RebootServer();
            _bar.Controls.Add(_filter);
            _bar.Controls.Add(_scan);
            _bar.Controls.Add(_dep);
            _bar.Controls.Add(_install);
            _bar.Controls.Add(_remove);
            _bar.Controls.Add(_mode);
            _bar.Controls.Add(_reboot);

            _table = new DataTable { Location = new Point(0, 120) };
            _table.Columns.Add(new DataColumn(v选v, 40));
            _table.Columns.Add(new DataColumn(v名称v, 200));
            _table.Columns.Add(new DataColumn(v显示名v, 220));
            _table.Columns.Add(new DataColumn(v状态v, 90));
            _table.Columns.Add(new DataColumn(v说明v, 320));
            _table.CheckColumn = 0;
            _table.RowActivated += idx =>
            {
                var r = _table.Rows[idx];
                Log(v[INFO] 选中角色 v + r[1]);
            };
            Controls.Add(_table);
        }

        protected override void OnActivated()
        {
            Load();
        }

        // Run-GuiReadyRole.ps1 -Mode list -> {Support,Summary,Items}
        public void Load()
        {
            if (_busy) return;
            _busy = true;
            SetState(v读取中…v, vInfov);

            Bridge.Run(@vgui\Run-GuiReadyRole.ps1v, vlistv, null,
                d =>
                {
                    var support = Bridge.Dict(d.ContainsKey(vSupportv) ? d[vSupportv] : null);
                    var summary = Bridge.Dict(d.ContainsKey(vSummaryv) ? d[vSummaryv] : null);
                    var items = Bridge.List(d.ContainsKey(vItemsv) ? d[vItemsv] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _all.Clear();
                        _all.AddRange(items);

                        if (!Bridge.Bool(support, vServerManagerv))
                        {
                            SetState(v不适用v, vWarnv);
                            _table.SetRows(new string[0][]);
                            string note = Bridge.Str(support, vNotev, v当前系统没有 ServerManager，角色/功能不适用。v);
                            Log(v[WARN] v + note);
                            return;
                        }

                        int installed = (int)Bridge.Num(summary, vInstalledv);
                        int total = (int)Bridge.Num(summary, vTotalv, _all.Count);
                        SetState(v已装 v + installed + v / v + total,
                                 Bridge.Bool(support, vCanManagev) ? vInfov : vWarnv);
                        if (!Bridge.Bool(support, vAdministratorv))
                            Log(v[WARN] 当前未以管理员运行，只能查看，安装会失败v);
                        ApplyFilter();
                        Log(v[INFO] 角色与功能：v + total + v 项，已装 v + installed + v 项v);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState(v读取失败v, vDangerv);
                    Log(v[WARN] 角色列表读取失败: v + err);
                }), 180000);
        }

        private void ApplyFilter()
        {
            string q = _filter.ValueText.Trim();
            var rows = new List<string[]>();
            foreach (var it in _all)
            {
                string name = Bridge.Str(it, vNamev);
                string display = Bridge.Str(it, vDisplayNamev);
                if (q.Length > 0 &&
                    name.IndexOf(q, StringComparison.OrdinalIgnoreCase) < 0 &&
                    display.IndexOf(q, StringComparison.OrdinalIgnoreCase) < 0) continue;

                bool on = Bridge.Bool(it, vInstalledv);
                if (_modeIdx == 1 && !on) continue;
                if (_modeIdx == 2 && on) continue;
                string state = on ? v已安装v : Bridge.Str(it, vInstallStatev, v未安装v);
                rows.Add(new[] { vv, name, display, on ? v已安装v : StateText(state), Bridge.Str(it, vNotev) });
            }
            _table.SetRows(rows);
        }

        private static string StateText(string state)
        {
            switch (state)
            {
                case vInstalledv: return v已安装v;
                case vAvailablev: return v可安装v;
                case vRemovedv: return v已移除v;
                default: return string.IsNullOrEmpty(state) ? v未安装v : state;
            }
        }

        private void ShowDependencies()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _table.Rows.Count)
            {
                Log(v[WARN] 先选中一个角色v);
                return;
            }
            string name = _table.Rows[idx][1];
            foreach (var it in _all)
            {
                if (Bridge.Str(it, vNamev) != name) continue;
                var deps = Bridge.StrList(it, vDependsOnv);
                Dialogs.Text(FindForm(), v依赖分析v, name,
                    v角色/功能：v + name + v（v + Bridge.Str(it, vDisplayNamev) + v）\r\nv +
                    v当前状态：v + (_table.Rows[idx][3]) + v\r\n\r\nv +
                    v直接依赖：v + (deps.Count > 0 ? string.Join(v、v, deps.ToArray()) : v无v) + v\r\n\r\nv +
                    v安装时工具会按 DependsOn 递归展开，先把未安装的依赖装上（依赖自动补齐），v +
                    v不需要你手工按顺序装。v);
                return;
            }
        }

        // 选中的角色名（勾选优先：勾了多个就是批量）
        private string SelectedRole()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _table.Rows.Count) return vv;
            return _table.Rows[idx][1];
        }

        private List<string> CheckedRoles()
        {
            var names = new List<string>();
            foreach (var i in _table.Checked)
            {
                if (i < 0 || i >= _table.Rows.Count) continue;
                string n = _table.Rows[i][1];
                if (n.Length > 0 && !names.Contains(n)) names.Add(n);
            }
            return names;
        }

        private void InstallSelected()
        {
            var batch = CheckedRoles();
            if (batch.Count > 1)
            {
                string list = string.Join(v,v, batch.ToArray());
                if (!Dialogs.Confirm(FindForm(), v批量安装角色/功能v,
                    v按依赖顺序依次安装这 v + batch.Count + v 项（单个失败不中断后面的）：\n\nv +
                    list + v\n\n耗时可能较长，是否需要重启会写进日志。v, v开始安装v)) return;

                var bargs = new Dictionary<string, object>();
                bargs[vNamesv] = list;
                bargs[vWithManagementToolsv] = false;
                bargs[vDryRunv] = false;
                bool bstarted = Actions.RunAction(vrole-batch-installv, bargs,
                    line => SafeInvoke(() => Log(line)),
                    r => SafeInvoke(() =>
                    {
                        Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) + v批量安装结束，退出码 v + r.ExitCode +
                            v，用时 v + r.Seconds.ToString(v0.0v) + v 秒v);
                        Load();
                    }),
                    err => SafeInvoke(() => Log(v[WARN] 批量安装未启动: v + err)));
                if (bstarted) Log(v[STEP] 已提交动作 批量安装角色/功能（role-batch-install）：v + batch.Count + v 项v);
                return;
            }

            string name = batch.Count == 1 ? batch[0] : SelectedRole();
            if (name.Length == 0) { Log(v[WARN] 先选中（或勾选）一个角色/功能v); return; }
            if (!Dialogs.Confirm(FindForm(), v安装角色/功能v,
                v安装「v + name + v」？会先按依赖顺序补齐，耗时可能较长；是否需要重启会写进日志。v,
                v安装v)) return;

            var args = new Dictionary<string, object>();
            args[vNamev] = name;
            args[vWithManagementToolsv] = false;
            args[vDryRunv] = false;
            bool started = Actions.RunAction(vrole-installv, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) + v安装 v + name +
                        v结束，退出码 v + r.ExitCode + v，用时 v + r.Seconds.ToString(v0.0v) + v 秒v);
                    Log(v[INFO] 如日志提示需要重启，可用工具栏「重启服务器」v);
                    Load();
                }),
                err => SafeInvoke(() => Log(v[WARN] 安装未启动: v + err)));
            if (started) Log(v[STEP] 已提交动作 安装角色/功能（role-install）：v + name);
        }

        private void RemoveSelected()
        {
            var batch = CheckedRoles();
            if (batch.Count > 1)
            {
                string list = string.Join(v,v, batch.ToArray());
                if (!Dialogs.Confirm(FindForm(), v批量移除角色/功能v,
                    v依次移除这 v + batch.Count + v 项（被其它角色依赖的会失败，属于预期）：\n\nv +
                    list + v\n\n不会自动重启。v, v开始移除v)) return;

                var bargs = new Dictionary<string, object>();
                bargs[vNamesv] = list;
                bargs[vDryRunv] = false;
                bool bstarted = Actions.RunAction(vrole-batch-removev, bargs,
                    line => SafeInvoke(() => Log(line)),
                    r => SafeInvoke(() =>
                    {
                        Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) + v批量移除结束，退出码 v + r.ExitCode +
                            v，用时 v + r.Seconds.ToString(v0.0v) + v 秒v);
                        Load();
                    }),
                    err => SafeInvoke(() => Log(v[WARN] 批量移除未启动: v + err)));
                if (bstarted) Log(v[STEP] 已提交动作 批量移除角色/功能（role-batch-remove）：v + batch.Count + v 项v);
                return;
            }

            string name = batch.Count == 1 ? batch[0] : SelectedRole();
            if (name.Length == 0) { Log(v[WARN] 先选中（或勾选）一个角色/功能v); return; }
            if (!Dialogs.Confirm(FindForm(), v移除角色/功能v,
                v确定移除「v + name + v」？不会自动重启，是否重启由你决定。v, v移除v)) return;

            var args = new Dictionary<string, object>();
            args[vNamev] = name;
            args[vDryRunv] = false;
            bool started = Actions.RunAction(vrole-removev, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) + v移除 v + name +
                        v结束，退出码 v + r.ExitCode + v，用时 v + r.Seconds.ToString(v0.0v) + v 秒v);
                    Load();
                }),
                err => SafeInvoke(() => Log(v[WARN] 移除未启动: v + err)));
            if (started) Log(v[STEP] 已提交动作 移除角色/功能（role-remove）：v + name);
        }

        // 角色装完常需要重启；延时 20 秒，期间可在命令行 shutdown /a 取消
        private void RebootServer()
        {
            var v = Dialogs.Prompt(FindForm(), v重启服务器v,
                v所有会话会断开。默认 20 秒后重启，期间可在命令行执行 shutdown /a 取消。v,
                new List<PromptField> { new PromptField(v延时（秒）v, v20v, false, v最小 5v) }, v重启v);
            if (v == null) return;

            int delay;
            if (!int.TryParse(v[0].Trim(), out delay) || delay < 5) delay = 20;

            var args = new Dictionary<string, object>();
            args[vDelaySecv] = delay;
            args[vDryRunv] = false;
            bool started = Actions.RunAction(vrebootv, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() => Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) +
                                          v重启命令已下发，退出码 v + r.ExitCode)),
                err => SafeInvoke(() => Log(v[WARN] 重启未启动: v + err)));
            if (started) Log(v[STEP] 已提交动作 重启服务器（reboot）：v + delay + v 秒后v);
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _bar.Left = 0;
            _bar.Top = 76;
            _bar.Width = Math.Max(200, w - 4);

            int x = 0;
            int reserved = 8 + _scan.Width + 8 + _dep.Width + 8 + _install.Width + 8 +
                           _remove.Width + 8 + _mode.Width + 8 + _reboot.Width;
            _filter.Width = Math.Max(140, Math.Min(300, _bar.Width - reserved - 4));
            _filter.Top = 2;
            _filter.Left = x;
            x += _filter.Width + 8;
            _scan.Top = 2;
            _scan.Left = x;
            x += _scan.Width + 8;
            _dep.Top = 2;
            _dep.Left = x;
            x += _dep.Width + 8;
            _install.Top = 2;
            _install.Left = x;
            x += _install.Width + 8;
            _remove.Top = 2;
            _remove.Left = x;
            x += _remove.Width + 8;
            _mode.Top = 2;
            _mode.Left = x;
            x += _mode.Width + 8;
            _reboot.Top = 2;
            _reboot.Left = x;

            _table.Left = 0;
            _table.Top = 120;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(120, ClientSize.Height - 128);
        }
    }

    // ------------------------------------------------------------ 安全基线
    internal sealed class SecurityPage : PageBase
    {
        private readonly List<StatCard> _cards = new List<StatCard>();
        private readonly DataTable _table;
        private readonly Panel _bar;
        private readonly Pill _state;
        private readonly UiButton _fix;
        private readonly UiButton _fixSel;
        private readonly UiButton _modeBtn;
        private readonly List<Dictionary<string, object>> _items = new List<Dictionary<string, object>>();
        private readonly List<Dictionary<string, object>> _view = new List<Dictionary<string, object>>();
        private int _mode;   // 0=全部 1=只看问题 2=只看不合格
        private bool _busy;

        public SecurityPage()
        {
            Key = vsecurityv;
            TitleText = v安全基线v;
            Subtitle = v本地可验证的 10 项安全基线；修复只覆盖安全可逆项，双击看证据与建议。v;
            Glyph = vsecurityv;
            Accent = Theme.AccentOf(vsecurityv);

            _state = new Pill(v未审计v, vNeutralv);
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            string[][] stats =
            {
                new[] { v通过v, v—v, v#67C23Av, v符合基线v },
                new[] { v警告v, v—v, v#E6A23Cv, v需要人工确认v },
                new[] { v不合格v, v—v, v#F56C6Cv, v可安全修复v },
                new[] { v未知v, v—v, v#94A3B8v, v无法本机验证v }
            };
            foreach (var s in stats)
            {
                var c = new StatCard(s[0], s[1], Theme.Hex(s[2]), s[3]);
                _cards.Add(c);
                Controls.Add(c);
            }

            _bar = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_bar);

            var audit = new UiButton(v重新审计v, ButtonKind.Normal, 100, 36) { Location = new Point(0, 2) };
            audit.Click += (s, e) => Audit();
            _fix = new UiButton(v全部可修项v, ButtonKind.Primary, 108, 36) { Location = new Point(108, 2) };
            _fix.Click += (s, e) => RunFix(0);
            _fixSel = new UiButton(v修复选中v, ButtonKind.Normal, 100, 36) { Location = new Point(224, 2) };
            _fixSel.Click += (s, e) => RunFix(SelectedFixIndex());
            _modeBtn = new UiButton(v全部v, ButtonKind.Normal, 92, 36) { Location = new Point(332, 2) };
            _modeBtn.Click += (s, e) =>
            {
                _mode = (_mode + 1) % 3;
                _modeBtn.Text = _mode == 0 ? v全部v : (_mode == 1 ? v只看问题v : v只看不合格v);
                _modeBtn.Invalidate();
                Fill();
            };
            _bar.Controls.Add(audit);
            _bar.Controls.Add(_fix);
            _bar.Controls.Add(_fixSel);
            _bar.Controls.Add(_modeBtn);

            _table = new DataTable { Location = new Point(0, 192) };
            _table.Columns.Add(new DataColumn(v检查项v, 240));
            _table.Columns.Add(new DataColumn(v结果v, 80));
            _table.Columns.Add(new DataColumn(v证据 / 建议v, 480));
            _table.RowActivated += ShowItem;
            _table.ActivateOnDoubleClick = true;
            Controls.Add(_table);
        }

        // 双击看完整证据 + 建议（表格里两者挤一列，长证据会被截断）
        private void ShowItem(int idx)
        {
            if (idx < 0 || idx >= _view.Count) return;
            var it = _view[idx];
            string fix = Bridge.Str(it, vFixv);
            string body = v检查项：v + Bridge.Str(it, vTitlev) + v\r\nv +
                          v分类：v + Bridge.Str(it, vCategoryv) + v\r\nv +
                          v结果：v + StatusText(Bridge.Str(it, vStatusv)) + v\r\nv +
                          v可自动修复：v + (fix.Length > 0 ? v是（v + fix + v）v : v否，只给建议v) + v\r\nv +
                          new string('-', 60) + v\r\nv +
                          v证据\r\nv + Bridge.Str(it, vDetailv) + v\r\n\r\nv +
                          v建议\r\nv + Bridge.Str(it, vAdvicev, v（无）v);
            Dialogs.Text(FindForm(), v安全检查详情v, Bridge.Str(it, vTitlev), body);
        }

        protected override void OnActivated()
        {
            Audit();
        }

        // Run-GuiReadySecurity.ps1 -Mode audit -> {Summary, Items}
        public void Audit()
        {
            if (_busy) return;
            _busy = true;
            SetState(v审计中…v, vInfov);

            Bridge.Run(@vgui\Run-GuiReadySecurity.ps1v, vauditv, null,
                d =>
                {
                    var summary = Bridge.Dict(d.ContainsKey(vSummaryv) ? d[vSummaryv] : null);
                    var items = Bridge.List(d.ContainsKey(vItemsv) ? d[vItemsv] : null);
                    SafeInvoke(() =>
                    {
                        _busy = false;
                        _items.Clear();
                        _items.AddRange(items);
                        Fill();

                        int ok = (int)Bridge.Num(summary, vOkv);
                        int warn = (int)Bridge.Num(summary, vWarnv);
                        int fail = (int)Bridge.Num(summary, vFailv);
                        int unknown = (int)Bridge.Num(summary, vUnknownv);
                        _cards[0].Set(ok.ToString(), v符合基线v);
                        _cards[1].Set(warn.ToString(), v需要人工确认v);
                        _cards[2].Set(fail.ToString(), v可安全修复 v + (int)Bridge.Num(summary, vFixablev) + v 项v);
                        _cards[3].Set(unknown.ToString(), v无法本机验证v);

                        int total = (int)Bridge.Num(summary, vTotalv, _items.Count);
                        SetState(ok + v / v + total + v 通过v, fail > 0 ? vDangerv : (warn > 0 ? vWarnv : vSuccessv));
                        Log(v[INFO] 安全基线：v + total + v 项，通过 v + ok + v，警告 v + warn + v，不合格 v + fail);
                    });
                },
                err => SafeInvoke(() =>
                {
                    _busy = false;
                    SetState(v审计失败v, vDangerv);
                    Log(v[WARN] 安全审计失败: v + err);
                }), 180000);
        }

        // 证据和建议都留在同一列：以前只显示建议，原始证据就丢了
        private void Fill()
        {
            _view.Clear();
            var rows = new List<string[]>();
            foreach (var it in _items)
            {
                string status = Bridge.Str(it, vStatusv);
                if (_mode == 1 && status != vWarnv && status != vFailv && status != vUnknownv) continue;
                if (_mode == 2 && status != vFailv) continue;

                string detail = Bridge.Str(it, vDetailv);
                string advice = Bridge.Str(it, vAdvicev);
                string cell = detail;
                if (advice.Length > 0) cell = (cell.Length > 0 ? cell + v  |  v : vv) + v建议：v + advice;
                rows.Add(new[] { Bridge.Str(it, vTitlev), StatusText(status), cell });
                _view.Add(it);
            }
            _table.SetRows(rows);
        }

        // 选中项对应的 security-fix 编号（1..6）；没有自动修复则返回 0
        private int SelectedFixIndex()
        {
            int idx = _table.SelectedIndex;
            if (idx < 0 || idx >= _view.Count)
            {
                Log(v[WARN] 先在表里选中一条检查项v);
                return -1;
            }
            string fix = Bridge.Str(_view[idx], vFixv);
            string[] map = { vfirewallv, vdefender-rtv, vsmbv1v, vguestv, vrdp-nlav, vpassword-policyv };
            int i = Array.IndexOf(map, fix);
            if (i < 0)
            {
                Dialogs.Text(FindForm(), v这一项没有自动修复v,
                    Bridge.Str(_view[idx], vTitlev),
                    v该项属于「改了可能把人锁在门外」或「需要人工判断」的范围，工具不会代改。\n\nv +
                    v证据：\nv + Bridge.Str(_view[idx], vDetailv) + v\n\nv +
                    v建议：\nv + Bridge.Str(_view[idx], vAdvicev, v（无）v));
                return -1;
            }
            return i + 1;
        }

        private static string StatusText(string s)
        {
            switch (s)
            {
                case vOKv: return v通过v;
                case vWarnv: return v警告v;
                case vFailv: return v不合格v;
                case vUnknownv: return v未知v;
                default: return string.IsNullOrEmpty(s) ? v未知v : s;
            }
        }

        // fix = 0 表示「全部可修项」，1..6 表示只修选中的那一项
        private void RunFix(int fix)
        {
            if (fix < 0) return;
            var args = new Dictionary<string, object>();
            if (fix > 0) args[vFixv] = fix;
            args[vDryRunv] = false;

            string label = fix > 0 ? v单项安全修复（第 v + fix + v 项）v : v安全基线一键修复v;
            bool started = Actions.RunAction(vsecurity-fixv, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) + label + v结束，退出码 v + r.ExitCode +
                        v，用时 v + r.Seconds.ToString(v0.0v) + v 秒v);
                    Audit();
                }),
                err => SafeInvoke(() => Log(v[WARN] 安全修复未启动: v + err)));
            if (started) Log(v[STEP] 已提交动作 v + label + v（security-fix）v);
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            int gap = 12;
            int perRow = Math.Max(1, Math.Min(_cards.Count, (w + gap) / (208 + gap)));
            int cardW = (w - (perRow - 1) * gap - 4) / perRow;
            if (cardW < 150) cardW = 150;
            for (int i = 0; i < _cards.Count; i++)
            {
                var c = _cards[i];
                c.Width = cardW;
                c.Left = (i % perRow) * (cardW + gap);
                c.Top = 76 + (i / perRow) * (c.Height + gap);
            }
            int rows = (_cards.Count + perRow - 1) / perRow;
            int y = 76 + rows * (_cards[0].Height + gap) + 2;

            _bar.Left = 0;
            _bar.Top = y;
            _bar.Width = Math.Max(200, w - 4);
            y += _bar.Height + 2;

            _table.Left = 0;
            _table.Top = y;
            _table.Width = Math.Max(200, w - 4);
            _table.Height = Math.Max(120, ClientSize.Height - y - 8);
        }
    }

    // ------------------------------------------------------------ 系统工具
    // 与老版 PowerShell 界面逐项对齐：21 个工具分三组（常用 3 / 诊断与脚本 4 /
    // Windows Admin Center 里也有 14）。本机缺的置灰但仍可点 —— 点了会说缺什么、去哪补。
    internal sealed class ToolPage : PageBase
    {
        private sealed class Tool
        {
            public string Name;
            public string Exe;
            public string Args = vv;
            public string Hint = vv;
            public string Group = vv;
            public UiButton Button;
            public bool Available;
            public Tool(string group, string name, string exe, string args = vv, string hint = vv)
            {
                Group = group; Name = name; Exe = exe; Args = args; Hint = hint;
            }
        }

        private sealed class Group
        {
            public string Title;
            public Tool[] Items;
            public int CaptionTop;
            public Group(string title, Tool[] items) { Title = title; Items = items; }
        }

        private readonly List<Tool> _tools = new List<Tool>();
        private readonly Group[] _groups;
        private readonly Pill _state;
        private readonly UiButton _wacToggle;
        private bool _wacExpanded = true;
        private bool _wacInstalled;

        private const int CaptionH = 24;
        private const int RowGap = 10;
        private const int BtnH = 38;

        public ToolPage()
        {
            Key = vtoolv;
            TitleText = v系统工具v;
            Subtitle = vServer Core 默认没有这些图形工具，装了官方 App Compatibility FOD 才会出现；缺失的会置灰，点一下会告诉你怎么补。v;
            Glyph = vtoolv;
            Accent = Theme.AccentOf(vtoolv);

            _state = new Pill(v未检测v, vNeutralv);
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            _groups = new Group[]
            {
                new Group(v常用v, new[]
                {
                    Add(v常用v, v记事本v,         vnotepad.exev),
                    Add(v常用v, v命令提示符v,     vcmd.exev),
                    Add(v常用v, v美化终端v,       vscm-term.cmdv, vv,
                        v还没安装美化终端。到「终端美化」页点「一键美化终端」装上（Nerd Font + Oh My Posh + Fastfetch），之后任意目录输入 scm-term 就能打开 UTF-8 + Nerd Font 的控制台。v)
                }),
                new Group(v诊断与脚本v, new[]
                {
                    Add(v诊断与脚本v, vMMC 控制台v,     vmmc.exev),
                    Add(v诊断与脚本v, v资源监视器v,     vresmon.exev),
                    Add(v诊断与脚本v, v系统信息v,       vmsinfo32.exev),
                    Add(v诊断与脚本v, vPowerShell ISEv, vpowershell_ise.exev)
                }),
                new Group(vWindows Admin Center 里也有v, new[]
                {
                    Add(vwacv, v文件资源管理器v, vexplorer.exev),
                    Add(vwacv, vPowerShellv,     vpowershell.exev),
                    Add(vwacv, v任务管理器v,     vtaskmgr.exev),
                    Add(vwacv, v服务v,           vservices.mscv),
                    Add(vwacv, v设备管理器v,     vdevmgmt.mscv),
                    Add(vwacv, v磁盘管理v,       vdiskmgmt.mscv),
                    Add(vwacv, v任务计划程序v,   vtaskschd.mscv),
                    Add(vwacv, v本地用户和组v,   vlusrmgr.mscv),
                    Add(vwacv, v证书管理v,       vcertmgr.mscv),
                    Add(vwacv, v防火墙高级安全v, vwf.mscv),
                    Add(vwacv, v注册表编辑器v,   vregedit.exev),
                    Add(vwacv, v事件查看器v,     veventvwr.mscv),
                    Add(vwacv, v性能监视器v,     vperfmon.exev),
                    Add(vwacv, vHyper-V 管理器v, vvirtmgmt.mscv)
                })
            };

            _wacToggle = new UiButton(v收起v, ButtonKind.Ghost, 72, 24);
            _wacToggle.Click += (s, e) =>
            {
                _wacExpanded = !_wacExpanded;
                _wacToggle.Text = _wacExpanded ? v收起v : v展开v;
                _wacToggle.Invalidate();
                Relayout();
            };
            Controls.Add(_wacToggle);

            foreach (var g in _groups)
                foreach (var t in g.Items)
                    if (t.Button != null) Controls.Add(t.Button);

            RefreshAvailability();
        }

        private Tool Add(string group, string name, string exe, string args = vv, string hint = vv)
        {
            var t = new Tool(group, name, exe, args, hint);
            t.Button = new UiButton(name, ButtonKind.Normal, 132, BtnH);
            t.Button.Click += (s, e) => Launch(t);
            _tools.Add(t);
            return t;
        }

        protected override void OnActivated()
        {
            RefreshAvailability();
        }

        // 本机有没有这个工具：缺失的置灰、名字后加「（缺失）」
        private void RefreshAvailability()
        {
            int ok = 0;
            foreach (var t in _tools)
            {
                t.Available = ResolveTool(t.Exe).Length > 0;
                if (t.Available) ok++;
                t.Button.Dim = !t.Available;
                t.Button.Text = t.Available ? t.Name : t.Name + v（缺失）v;
                t.Button.Invalidate();
            }
            _wacInstalled = WacInstalled();
            _state.SetText(ok + v / v + _tools.Count + v 可用v);
            _state.SetKind(ok == _tools.Count ? vSuccessv : (ok > 0 ? vWarnv : vDangerv));
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
            Relayout();
        }

        private void Launch(Tool tool)
        {
            string path = ResolveTool(tool.Exe);
            if (path.Length == 0)
            {
                string extra = tool.Hint.Length > 0 ? (v  v + tool.Hint)
                    : v  Server Core 默认不带它，到「环境补全」页点「一键补全」装官方桌面体验（FOD），装完重启再试。v;
                Log(v[WARN] 找不到 v + tool.Name + v（v + tool.Exe + v）。v + extra);
                // 只写日志等于没反馈：给个说明 + 用命令提示符代替的去处
                if (Dialogs.Confirm(FindForm(), v找不到 v + tool.Name,
                    v本机没有 v + tool.Name + v（v + tool.Exe + v）。\n\nv + extra.Trim() +
                    v\n\n要用「命令提示符」打开同目录代替吗？v, v打开命令提示符v))
                {
                    try
                    {
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                        {
                            FileName = vcmd.exev,
                            Arguments = v/k cd /d \vv + Bridge.Root + v\vv,
                            UseShellExecute = true
                        });
                        Log(v[INFO] 已用命令提示符代替 v + tool.Name);
                    }
                    catch (Exception ex)
                    {
                        Log(v[WARN] 打开命令提示符失败: v + ex.Message);
                    }
                }
                return;
            }
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = path,
                    Arguments = tool.Args,
                    UseShellExecute = true
                };
                System.Diagnostics.Process.Start(psi);
                Log(v[OK] 已打开 v + tool.Name);
            }
            catch (Exception ex)
            {
                Log(v[WARN] 打开 v + tool.Name + v 失败: v + ex.Message);
            }
        }

        // System32 -> Windows 目录 -> WindowsApps 别名 -> PATH（老版就是这么找的）
        private static string ResolveTool(string exe)
        {
            if (string.IsNullOrEmpty(exe)) return vv;
            string p = System.IO.Path.Combine(Environment.SystemDirectory, exe);
            if (System.IO.File.Exists(p)) return p;
            p = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), exe);
            if (System.IO.File.Exists(p)) return p;
            try
            {
                string alias = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    @vMicrosoft\WindowsApps\v + exe);
                if (System.IO.File.Exists(alias)) return alias;
            }
            catch { }
            try
            {
                string pathVar = Environment.GetEnvironmentVariable(vPATHv) ?? vv;
                foreach (var d in pathVar.Split(';'))
                {
                    if (string.IsNullOrWhiteSpace(d)) continue;
                    try
                    {
                        string f = System.IO.Path.Combine(d.Trim(), exe);
                        if (System.IO.File.Exists(f)) return f;
                    }
                    catch { }
                }
            }
            catch { }
            return vv;
        }

        // WAC 装没装：只看服务注册项，不联网、不起子进程
        private static bool WacInstalled()
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                           @vSYSTEM\CurrentControlSet\Services\WindowsAdminCenterv))
                    return k != null;
            }
            catch { return false; }
        }

        protected override void BuildContent() { }

        // 分组标题画在页面自身上：它跟着背景一起重绘，不会留下「透明控件下的旧像素」
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            foreach (var grp in _groups)
            {
                bool wac = grp.Title.StartsWith(vWindows Admin Centerv);
                bool hidden = wac && !_wacExpanded;
                string title = grp.Title + v（v + grp.Items.Length + v）v;
                if (wac && _wacInstalled && !hidden)
                    title += v · 本机已装 WAC，这些在 WAC 里也能用v;
                if (hidden) title = grp.Title + v（已收起）v;
                Draw.Text(g, title, Theme.Font(9f, true), Theme.Hint,
                          new Rectangle(0, grp.CaptionTop, Math.Max(200, Width - 120), CaptionH));
            }
        }

        protected override void OnLayout()
        {
            int w = Math.Max(200, ClientSize.Width - 4);
            const int gap = 10;
            int perRow = Math.Max(2, Math.Min(4, (w + gap) / (150 + gap)));
            int bw = (w - (perRow - 1) * gap) / perRow;
            if (bw < 130) bw = 130;

            int y = 76;
            foreach (var grp in _groups)
            {
                grp.CaptionTop = y;
                bool wac = grp.Title.StartsWith(vWindows Admin Centerv);
                bool hidden = wac && !_wacExpanded;

                _wacToggle.Visible = wac;
                if (wac)
                {
                    _wacToggle.Left = Math.Max(0, w - _wacToggle.Width);
                    _wacToggle.Top = y + 1;
                }
                y += CaptionH + 2;

                int i = 0;
                foreach (var t in grp.Items)
                {
                    t.Button.Visible = !hidden;
                    if (hidden) continue;
                    t.Button.Width = bw;
                    t.Button.Left = (i % perRow) * (bw + gap);
                    t.Button.Top = y + (i / perRow) * (BtnH + RowGap);
                    i++;
                }
                if (hidden) continue;
                int rows = (grp.Items.Length + perRow - 1) / perRow;
                y += rows * (BtnH + RowGap) + 8;
            }
        }
    }

    // ------------------------------------------------------------ 终端美化
    internal sealed class BeautyPage : PageBase
    {
        private static readonly string[] Themes =
        {
            v默认（One Dark 自带）v, v1_shellv, vatomicv, vcatppuccin_frappev,
            vdraculav, vemodipt-extendv, vzashv
        };

        private readonly List<StatCard> _cards = new List<StatCard>();
        private readonly Panel _actions;
        private readonly List<UiButton> _buttons = new List<UiButton>();
        private readonly UiButton _theme;
        private readonly UiButton _apply;
        private readonly UiButton _status;
        private readonly UiButton _open;
        private readonly UiButton _restore;
        private readonly UiButton _ps7;
        private readonly Pill _state;
        private int _themeIndex;

        public BeautyPage()
        {
            Key = vbeautyv;
            TitleText = v终端美化v;
            Subtitle = v把 Server Core 的 conhost 打扮好看：Nerd Font + Oh My Posh 提示符 + Fastfetch 首屏信息。装的时候缺什么就从官方源下载（可用环境变量 SCM_CONSOLE_MIRROR 换源）。v;
            Glyph = vbeautyv;
            Accent = Theme.AccentOf(vbeautyv);

            _state = new Pill(v未检查v, vNeutralv);
            Head.Slot.Controls.Add(_state);
            Head.Slot.Width = _state.Width;

            string[][] items =
            {
                new[] { vNerd Fontv, v—v, v#34D399v, vMesloLGS NFv },
                new[] { voh-my-poshv, v—v, v#409EFFv, v提示符v },
                new[] { vfastfetchv, v—v, v#E6A23Cv, v首屏信息（可选）v },
                new[] { vPowerShell 7v, v—v, v#C084FCv, vpwsh（可选）v }
            };
            foreach (var s in items)
            {
                var c = new StatCard(s[0], s[1], Theme.Hex(s[2]), s[3]);
                _cards.Add(c);
                Controls.Add(c);
            }

            _actions = new Panel { Height = 40, BackColor = Color.Transparent };
            Controls.Add(_actions);

            _theme = new UiButton(ThemeText(), ButtonKind.Normal, 240, 36) { Location = new Point(0, 0) };
            _theme.Click += (s, e) => CycleTheme();
            _apply = new UiButton(v一键美化终端v, ButtonKind.Primary, 132, 36) { Location = new Point(0, 0) };
            _apply.Click += (s, e) => RunAction(vconsole-installv, v一键美化终端v,
                                               new Dictionary<string, object> { { vThemev, _themeIndex + 1 } });
            _status = new UiButton(v状态检查v, ButtonKind.Normal, 96, 36) { Location = new Point(0, 0) };
            _status.Click += (s, e) => Check();
            _open = new UiButton(v打开美化终端v, ButtonKind.Normal, 124, 36) { Location = new Point(0, 0) };
            _open.Click += (s, e) => RunAction(vconsole-openv, v打开美化终端v, null);
            _restore = new UiButton(v一键还原v, ButtonKind.Normal, 96, 36) { Location = new Point(0, 0) };
            _restore.Click += (s, e) => RunAction(vconsole-restorev, v终端一键还原v, null);
            // 美化默认用 PowerShell 5.1；想用 7 的提示符/主题在这里装（zip 免安装）
            _ps7 = new UiButton(v安装 PowerShell 7v, ButtonKind.Normal, 140, 36) { Location = new Point(0, 0) };
            _ps7.Click += (s, e) => RunAction(vconsole-ps7v, v安装 PowerShell 7v, null);
            _actions.Controls.Add(_theme);
            _actions.Controls.Add(_apply);
            _actions.Controls.Add(_status);
            _actions.Controls.Add(_open);
            _actions.Controls.Add(_restore);
            _actions.Controls.Add(_ps7);
            _buttons.Add(_theme);
            _buttons.Add(_apply);
            _buttons.Add(_status);
            _buttons.Add(_open);
            _buttons.Add(_restore);
            _buttons.Add(_ps7);
        }

        protected override void OnActivated()
        {
            Check();
        }

        // 本机自查（不跑子进程，纯文件系统 + PATH）
        private void Check()
        {
            bool font = FontInstalled();
            string posh = OnPath(voh-my-posh.exev,
                                 System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                                        @vPrograms\oh-my-posh\bin\oh-my-posh.exev),
                                 System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                                                        @voh-my-posh\bin\oh-my-posh.exev));
            string ff = OnPath(vfastfetch.exev,
                               System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                                      @vMicrosoft\WinGet\Links\fastfetch.exev));

            _cards[0].Set(font ? v已安装v : v未安装v, vMesloLGS NFv);
            _cards[0].Accent = font ? Theme.Ok : Theme.Warn;
            _cards[0].Invalidate();

            _cards[1].Set(posh.Length > 0 ? v已安装v : v未安装v, posh.Length > 0 ? posh : voh-my-poshv);
            _cards[1].Accent = posh.Length > 0 ? Theme.Ok : Theme.Warn;
            _cards[1].Invalidate();

            _cards[2].Set(ff.Length > 0 ? v已安装v : v未安装v, ff.Length > 0 ? ff : vfastfetch（可选）v);
            _cards[2].Accent = ff.Length > 0 ? Theme.Ok : Theme.Hint;
            _cards[2].Invalidate();

            string pwsh = OnPath(vpwsh.exev,
                                 System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                                                        @vPowerShell\7\pwsh.exev));
            _cards[3].Set(pwsh.Length > 0 ? v已安装v : v未安装v, pwsh.Length > 0 ? pwsh : v可选：装 7 用新语法v);
            _cards[3].Accent = pwsh.Length > 0 ? Theme.Ok : Theme.Hint;
            _cards[3].Invalidate();

            bool ready = font && posh.Length > 0;
            SetState(ready ? v已美化v : v未就绪v, ready ? vSuccessv : vWarnv);
            Log(v[INFO] 终端美化状态：字体 v + (font ? v有v : v无v) +
                v，oh-my-posh v + (posh.Length > 0 ? v有v : v无v) +
                v，fastfetch v + (ff.Length > 0 ? v有v : v无v) +
                v，pwsh v + (pwsh.Length > 0 ? v有v : v无v));
        }

        private static bool FontInstalled()
        {
            try
            {
                string dir = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows), vFontsv);
                return System.IO.Directory.GetFiles(dir, vMeslo*v).Length > 0;
            }
            catch { return false; }
        }

        private static string OnPath(string exe, params string[] candidates)
        {
            foreach (var c in candidates)
            {
                try { if (!string.IsNullOrEmpty(c) && System.IO.File.Exists(c)) return c; }
                catch { }
            }
            string[] dirs;
            try { dirs = (Environment.GetEnvironmentVariable(vPATHv) ?? vv).Split(';'); }
            catch { return vv; }
            foreach (var d in dirs)
            {
                if (string.IsNullOrWhiteSpace(d)) continue;
                try
                {
                    string p = System.IO.Path.Combine(d.Trim(), exe);
                    if (System.IO.File.Exists(p)) return p;
                }
                catch { }
            }
            return vv;
        }

        private void RunAction(string id, string name, Dictionary<string, object> extra)
        {
            var args = new Dictionary<string, object>();
            args[vDryRunv] = false;
            if (extra != null) foreach (var kv in extra) args[kv.Key] = kv.Value;

            bool started = Actions.RunAction(id, args,
                line => SafeInvoke(() => Log(line)),
                r => SafeInvoke(() =>
                {
                    Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) + name + v结束，退出码 v + r.ExitCode +
                        v，用时 v + r.Seconds.ToString(v0.0v) + v 秒v);
                    Check();
                }),
                err => SafeInvoke(() => Log(v[WARN] v + name + v未启动: v + err)));
            if (started) Log(v[STEP] 已提交动作 v + name + v（v + id + v）v);
        }

        private void SetState(string text, string kind)
        {
            _state.SetText(text);
            _state.SetKind(kind);
            Head.Slot.Width = _state.Width;
            Head.Slot.Left = Math.Max(0, Head.Width - Head.Slot.Width - 4);
        }

        private string ThemeText()
        {
            return v提示符主题：v + Themes[_themeIndex] + v  ⇄v;
        }

        private void CycleTheme()
        {
            _themeIndex = (_themeIndex + 1) % Themes.Length;
            _theme.Text = ThemeText();
            _theme.Invalidate();
            Log(v[INFO] 提示符主题切换为 v + Themes[_themeIndex]);
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            int gap = 12;
            int perRow = Math.Max(1, Math.Min(_cards.Count, (w + gap) / (208 + gap)));
            int cardW = (w - (perRow - 1) * gap - 4) / perRow;
            if (cardW < 150) cardW = 150;
            for (int i = 0; i < _cards.Count; i++)
            {
                var c = _cards[i];
                c.Width = cardW;
                c.Left = (i % perRow) * (cardW + gap);
                c.Top = 76 + (i / perRow) * (c.Height + gap);
            }
            int rows = (_cards.Count + perRow - 1) / perRow;
            int y = 76 + rows * (_cards[0].Height + gap) + 4;

            _actions.Left = 0;
            _actions.Top = y;
            _actions.Width = Math.Max(200, w - 4);
            // 六个按钮在 1024×700 下放不下一行，统一走换行布局
            _actions.Height = LayoutButtonRow(_buttons, _actions.Width, 0);
        }
    }


    // 「全部功能」页在 ActionConsole.cs 里实现（通用动作控制台）

    // ------------------------------------------------------------ 关于
    internal sealed class AboutPage : PageBase
    {
        private readonly AboutCard _card;
        private readonly UiButton _site;
        private readonly UiButton _update;
        private readonly UiButton _checkUpdate;
        private readonly UiButton _openLogs;
        private readonly UiButton _openReports;

        public AboutPage()
        {
            Key = vaboutv;
            TitleText = v关于v;
            Subtitle = vServer Core GUI 就绪工具 —— 让带界面的程序在 Windows Server Core 上真正跑起来。v;
            Glyph = vaboutv;
            Accent = Theme.AccentOf(vaboutv);

            _card = new AboutCard { HoverGlow = false, Accent = Accent };
            Controls.Add(_card);

            _site = new UiButton(v打开项目主页v, ButtonKind.Primary, 132, 34) { Location = new Point(0, 0) };
            _update = new UiButton(v完整性自检v, ButtonKind.Normal, 112, 34) { Location = new Point(0, 0) };
            _site.Click += (s, e) => OpenHome();
            _update.Click += (s, e) =>
            {
                bool started = Actions.RunAction(vselfcheckv, null,
                    line => SafeInvoke(() => Log(line)),
                    r => SafeInvoke(() => Log((r.ExitCode == 0 ? v[OK] v : v[ERROR] v) +
                                             v完整性自检结束，退出码 v + r.ExitCode)),
                    err => SafeInvoke(() => Log(v[WARN] 自检未启动: v + err)));
                if (started) Log(v[STEP] 已提交动作 本工具完整性自检（selfcheck）v);
            };
            _card.Controls.Add(_site);
            _card.Controls.Add(_update);

            _checkUpdate = new UiButton(v检查更新v, ButtonKind.Normal, 112, 34) { Location = new Point(0, 0) };
            _checkUpdate.Click += (s, e) => SelfUpdate.CheckManual(this);
            _card.Controls.Add(_checkUpdate);

            _openLogs = new UiButton(v打开日志目录v, ButtonKind.Normal, 116, 34) { Location = new Point(0, 0) };
            _openLogs.Click += (s, e) => OpenFolder(vlogsv);
            _openReports = new UiButton(v打开报告目录v, ButtonKind.Normal, 116, 34) { Location = new Point(0, 0) };
            _openReports.Click += (s, e) => OpenFolder(vreportsv);
            _card.Controls.Add(_openLogs);
            _card.Controls.Add(_openReports);
        }

        private void OpenFolder(string name)
        {
            try
            {
                string dir = System.IO.Path.Combine(Bridge.Root, name);
                if (!System.IO.Directory.Exists(dir))
                    System.IO.Directory.CreateDirectory(dir);
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = dir,
                    UseShellExecute = true
                });
                Log(v[OK] 已打开目录 v + dir);
            }
            catch (Exception ex)
            {
                Log(v[WARN] 打开目录失败: v + ex.Message);
            }
        }

        private void OpenHome()
        {
            const string url = vhttps://server-core-mananger.github.io/v;
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = url,
                    UseShellExecute = true
                });
                Log(v[OK] 已在浏览器打开项目主页v);
            }
            catch (Exception ex)
            {
                Log(v[INFO] 项目主页 v + url + v（打开失败: v + ex.Message + v）v);
            }
        }

        protected override void BuildContent() { }

        protected override void OnLayout()
        {
            int w = ClientSize.Width;
            _card.Left = 0;
            _card.Top = 76;
            _card.Width = Math.Max(240, w - 4);

            // 四个按钮排在「作者/QQ/版本/GitHub/官网」和底部说明的下面，统一换行布局。
            // 以前是右下角固定 + 左下角固定，卡片一窄就互相压住，底部说明还会被按钮盖掉。
            int pad = 16;
            var btns = new List<UiButton> { _openLogs, _openReports, _site, _update, _checkUpdate };
            int bh = LayoutButtonRow(btns, _card.Width - pad * 2, 0);
            const int top = 226;

            int avail = ClientSize.Height - 84;
            int needH = top + bh + pad;
            int h = Math.Min(320, Math.Max(needH, avail));
            _card.Height = h;

            // 放不下就把整行往上收一点（仍然在说明文字下方）
            int y = top;
            if (y + bh > h - pad) y = Math.Max(200, h - pad - bh);
            LayoutButtonRow(btns, _card.Width - pad * 2, y);
            foreach (var b in btns) b.Left += pad;
        }
    }

    // ============================================================
    // 关于卡片：继承 SurfaceCard，只重写 OnPaintContent（玻璃底由基类负责）。
    // ============================================================

    internal sealed class AboutCard : SurfaceCard
    {
        // 构建日期按 exe 的写入时间算，别写死 —— 写死的日期放两周就对不上了
        private static string BuildStamp()
        {
            try
            {
                return System.IO.File.GetLastWriteTime(
                    System.Windows.Forms.Application.ExecutablePath).ToString(vyyyy-MM-ddv);
            }
            catch { return v—v; }
        }

        protected override void OnPaintContent(Graphics g, Rectangle r)
        {
            Draw.Text(g, vSCM 运维控制台v, Theme.Font(16f, true), Theme.Text,
                      new Rectangle(22, 16, Math.Max(120, r.Width - 44), 34));
            Draw.Text(g, vWindows Server Core 上的原生图形界面v, Theme.Font(9.5f), Theme.Hint,
                      new Rectangle(22, 44, Math.Max(120, r.Width - 44), 20));

            int y = 76;
            string[][] rows =
            {
                new[] { v作者：v, vmmmv },
                new[] { vQQ 群：v, v1034243331v },
                new[] { v版本：v, vv2.4　构建 v + BuildStamp() },
                new[] { vGitHub：v, vhttps://github.com/Server-Core-Mananger/Server-core-managerv },
                new[] { v官网：v, vhttps://server-core-mananger.github.io/v }
            };
            foreach (var row in rows)
            {
                if (y > 176) break;
                bool link = row[0] == vGitHub：v || row[0] == v官网：v;
                Draw.Text(g, row[0], Theme.Font(10f), Theme.Hint,
                          new Rectangle(22, y, 80, 22));
                Draw.Text(g, row[1], Theme.Font(10f, row[0] == v作者：v), link ? Theme.AccentHi : Theme.Sub,
                          new Rectangle(96, y, Math.Max(60, r.Width - 120), 22));
                if (link)
                {
                    // 下划一条线，告诉用户这行能点（点了直接开浏览器）
                    var sz = TextRenderer.MeasureText(row[1], Theme.Font(10f));
                    int lineW = Math.Min(sz.Width, Math.Max(60, r.Width - 126));
                    using (var pen = new Pen(Color.FromArgb(120, Theme.AccentHi)))
                        g.DrawLine(pen, 96, y + 19, 96 + lineW, y + 19);
                }
                y += 24;
            }
            // 说明文字固定在按钮上方（以前按 r.Height 锚在底部，正好被按钮压住）
            if (r.Height >= 216)
                Draw.Text(g, v用着有问题、或者想要哪个功能：到 QQ 群里说一声。v, Theme.Font(9f), Theme.Hint,
                          new Rectangle(22, 200, Math.Max(60, r.Width - 44), 20));
        }

        private const string GithubUrl = vhttps://github.com/Server-Core-Mananger/Server-core-managerv;
        private const string SiteUrl = vhttps://server-core-mananger.github.io/v;

        // GitHub 是第 4 行（y = 76 + 3 * 24），官网是第 5 行
        private static Rectangle GithubHit(int width)
        {
            return new Rectangle(22, 76 + 3 * 24, Math.Max(80, width - 44), 22);
        }

        private static Rectangle SiteHit(int width)
        {
            return new Rectangle(22, 76 + 4 * 24, Math.Max(80, width - 44), 22);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            bool onLink = GithubHit(Width).Contains(e.Location) || SiteHit(Width).Contains(e.Location);
            Cursor = onLink ? Cursors.Hand : Cursors.Default;
            base.OnMouseMove(e);
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            string url = vv;
            if (e.Button == MouseButtons.Left)
            {
                if (GithubHit(Width).Contains(e.Location)) url = GithubUrl;
                else if (SiteHit(Width).Contains(e.Location)) url = SiteUrl;
            }
            if (url.Length > 0)
            {
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = url,
                        UseShellExecute = true
                    });
                }
                catch { }
            }
            base.OnMouseClick(e);
        }
    }
}

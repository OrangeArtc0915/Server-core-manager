using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 自绘数据表：玻璃容器 + 深色列头 + 行分割线 + 悬停 + 选中竖条。
    // PowerShell 版用 OwnerDraw ListView 勉强做到；C# 里重绘一屏只要几毫秒，
    // 滚动与悬停都能跟手。
    // ============================================================
    internal sealed class DataColumn
    {
        public string Header;
        public int Width;
        public bool Right;
        public DataColumn(string header, int width, bool right = false)
        {
            Header = header; Width = width; Right = right;
        }
    }

    internal sealed class DataTable : UiControl
    {
        public readonly List<DataColumn> Columns = new List<DataColumn>();
        public readonly List<string[]> Rows = new List<string[]>();
        public int RowHeight = 42;
        public int HeaderHeight = 34;
        public Color Accent = Theme.Accent;

        // 勾选列（-1 = 没有）。勾选状态按行号存，SetRows 会清空 ——
        // 列表一换（搜索 / 过滤）旧行号就没意义了，留着只会张冠李戴。
        public int CheckColumn = -1;
        // 程序管理这类「点一下就真的启动程序」的列表要双击才触发，
        // 单击只选中；其余列表保持单击即进入（少点一下）。
        public bool ActivateOnDoubleClick;
        public readonly HashSet<int> Checked = new HashSet<int>();
        public event Action<int, bool> CheckChanged;

        private int _hoverRow = -1;
        private int _selected = -1;
        private int _scroll;
        private int _sortCol = -1;
        private bool _sortAsc = true;

        public event Action<int> RowActivated;

        public DataTable()
        {
            BackColor = Theme.Card;
        }

        // keepScroll = 定时刷新时保留当前滚动位置，否则用户正看历史行会被弹回顶部
        public void SetRows(IEnumerable<string[]> rows, bool keepScroll = false)
        {
            Rows.Clear();
            Rows.AddRange(rows);
            Checked.Clear();
            _sortCol = -1;
            _sortAsc = true;
            if (_selected >= Rows.Count) _selected = -1;
            if (!keepScroll) _scroll = 0;
            int max = Math.Max(0, Rows.Count - VisibleRows);
            if (_scroll > max) _scroll = max;
            Invalidate();
        }

        public void SetSelected(int index)
        {
            _selected = (index >= 0 && index < Rows.Count) ? index : -1;
            Invalidate();
        }

        private int CheckColumnLeft()
        {
            int x = 12;
            for (int i = 0; i < Columns.Count && i < CheckColumn; i++) x += Columns[i].Width;
            return x;
        }

        public int SelectedIndex { get { return _selected; } }
        public string[] SelectedRow
        {
            get { return (_selected >= 0 && _selected < Rows.Count) ? Rows[_selected] : null; }
        }

        private int VisibleRows
        {
            get { return Math.Max(0, (Height - HeaderHeight - 6) / RowHeight); }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            int idx = RowAt(e.Y);
            if (idx != _hoverRow) { _hoverRow = idx; Invalidate(); }
            base.OnMouseMove(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            if (_hoverRow != -1) { _hoverRow = -1; Invalidate(); }
            base.OnMouseLeave(e);
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            // 点列头 = 按该列排序（再点一次反向）。数字列按数值比，其余按字符串。
            if (e.Button == MouseButtons.Left && e.Y < HeaderHeight)
            {
                int x = 12;
                for (int i = 0; i < Columns.Count; i++)
                {
                    if (e.X >= x - 6 && e.X < x + Columns[i].Width - 6)
                    {
                        if (_sortCol == i) _sortAsc = !_sortAsc;
                        else { _sortCol = i; _sortAsc = true; }
                        SortRows();
                        return;
                    }
                    x += Columns[i].Width;
                }
                return;
            }
            if (e.Button == MouseButtons.Left)
            {
                int idx = RowAt(e.Y);
                if (idx >= 0)
                {
                    // 点勾选列只管勾选，不触发「双击进入」那种行激活
                    if (CheckColumn >= 0)
                    {
                        int left = CheckColumnLeft();
                        if (e.X >= left - 8 && e.X <= left + Columns[CheckColumn].Width - 4)
                        {
                            bool on = !Checked.Contains(idx);
                            if (on) Checked.Add(idx); else Checked.Remove(idx);
                            Invalidate();
                            if (CheckChanged != null) CheckChanged(idx, on);
                            base.OnMouseClick(e);
                            return;
                        }
                    }
                    _selected = idx;
                    Invalidate();
                    if (!ActivateOnDoubleClick && RowActivated != null) RowActivated(idx);
                }
            }
            base.OnMouseClick(e);
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            if (ActivateOnDoubleClick && e.Button == MouseButtons.Left)
            {
                int idx = RowAt(e.Y);
                if (idx >= 0)
                {
                    _selected = idx;
                    Invalidate();
                    if (RowActivated != null) RowActivated(idx);
                }
            }
            base.OnMouseDoubleClick(e);
        }

        // 勾选框与 UiCheck 保持同一套画法（圆角方块 + 白勾）
        private static void PaintCheck(Graphics g, Rectangle cell, bool on, Color accent)
        {
            var box = new Rectangle(cell.X + 2, cell.Y + (cell.Height - 18) / 2, 18, 18);
            using (var path = Draw.Round(box, 5))
            {
                using (var b = new SolidBrush(on ? accent : Theme.Sunken)) g.FillPath(b, path);
                using (var pen = new Pen(on ? accent : Theme.BorderHi)) g.DrawPath(pen, path);
            }
            if (!on) return;
            using (var pen = new Pen(Color.White, 2f))
                g.DrawLines(pen, new[]
                {
                    new PointF(box.X + 4.5f, box.Y + 9f),
                    new PointF(box.X + 8f, box.Y + 12.5f),
                    new PointF(box.X + 14f, box.Y + 5f)
                });
        }

        private void SortRows()
        {
            int col = _sortCol;
            bool asc = _sortAsc;
            Rows.Sort((a, b) =>
            {
                string x = col < a.Length ? (a[col] ?? "") : "";
                string y = col < b.Length ? (b[col] ?? "") : "";
                double dx, dy;
                if (double.TryParse(x, NumberStyles.Any, CultureInfo.CurrentCulture, out dx) &&
                    double.TryParse(y, NumberStyles.Any, CultureInfo.CurrentCulture, out dy))
                    return asc ? dx.CompareTo(dy) : dy.CompareTo(dx);
                int c = string.Compare(x, y, StringComparison.CurrentCultureIgnoreCase);
                return asc ? c : -c;
            });
            _selected = -1;
            _scroll = 0;
            Invalidate();
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            int max = Math.Max(0, Rows.Count - VisibleRows);
            int next = _scroll - Math.Sign(e.Delta);
            if (next < 0) next = 0;
            if (next > max) next = max;
            if (next != _scroll) { _scroll = next; Invalidate(); }
            base.OnMouseWheel(e);
        }

        private int RowAt(int y)
        {
            if (y < HeaderHeight) return -1;
            int i = (y - HeaderHeight) / RowHeight + _scroll;
            if (i < 0 || i >= Rows.Count) return -1;
            return i;
        }

        // 根据整行文字判断状态色（不要求各页传额外字段，旧表也能立刻受益）
        private static Color? RowTint(string[] row)
        {
            if (row == null) return null;
            bool warn = false, ok = false;
            foreach (var cell in row)
            {
                if (string.IsNullOrEmpty(cell)) continue;
                if (cell.IndexOf("失败") >= 0 || cell.IndexOf("错误") >= 0 ||
                    cell.IndexOf("异常") >= 0 || cell.IndexOf("未通过") >= 0 ||
                    cell.IndexOf("不可用") >= 0)
                    return Color.FromArgb(20, Theme.Err);
                if (cell.IndexOf("警告") >= 0 || cell.IndexOf("未安装") >= 0 ||
                    cell.IndexOf("未启动") >= 0 || cell.IndexOf("未配置") >= 0 ||
                    cell.IndexOf("部分") >= 0)
                    warn = true;
                else if (cell.IndexOf("成功") >= 0 || cell.IndexOf("正常") >= 0 ||
                         cell.IndexOf("已安装") >= 0 || cell.IndexOf("已启动") >= 0 ||
                         cell.IndexOf("通过") >= 0)
                    ok = true;
            }
            if (warn) return Color.FromArgb(16, Theme.Warn);
            if (ok) return Color.FromArgb(12, Theme.Ok);
            return null;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width, Height);
            Draw.GlassCard(g, r, Theme.RCard, Theme.Card, Theme.Border);

            var state = g.Save();
            using (var path = Draw.Round(new Rectangle(0, 0, Width - 1, Height - 1), Theme.RCard))
                g.SetClip(path);

            int x = 12;
            var f = Theme.Font(9f, true);
            for (int ci = 0; ci < Columns.Count; ci++)
            {
                var c = Columns[ci];
                Draw.Text(g, c.Header, f, Theme.Hint,
                          new Rectangle(x, 0, c.Width - 12, HeaderHeight),
                          c.Right ? ContentAlignment.MiddleRight : ContentAlignment.MiddleLeft);
                if (ci == _sortCol)
                    Draw.Text(g, _sortAsc ? "▲" : "▼", Theme.Font(7f), Accent,
                              new Rectangle(x + c.Width - 24, 0, 16, HeaderHeight),
                              ContentAlignment.MiddleRight);
                x += c.Width;
            }
            using (var pen = new Pen(Theme.Border))
                g.DrawLine(pen, 0, HeaderHeight, Width, HeaderHeight);

            int y = HeaderHeight + 3;
            int last = Math.Min(Rows.Count, _scroll + VisibleRows + 1);
            var fr = Theme.Font(9.5f);
            for (int i = _scroll; i < last; i++)
            {
                var row = Rows[i];
                bool sel = i == _selected;
                bool hov = i == _hoverRow;
                if (sel || hov)
                {
                    var bg = sel ? Theme.AccentDim : Theme.Mix(Theme.Card, Theme.CardHover, 0.55f);
                    using (var b = new SolidBrush(bg))
                        g.FillRectangle(b, 0, y, Width, RowHeight);
                    if (sel)
                        using (var b = new SolidBrush(Accent))
                            g.FillRectangle(b, 0, y, 3, RowHeight);
                }
                else
                {
                    // 行级淡色：状态列写着失败/警告/成功时给一条很淡的底色，
                    // 扫长列表比逐行读文字快得多（旧 PowerShell 版就是按行着色的）
                    Color? tint = RowTint(row);
                    if (tint.HasValue)
                        using (var b = new SolidBrush(tint.Value))
                            g.FillRectangle(b, 0, y, Width, RowHeight);
                }
                int cx = 12;
                for (int ci = 0; ci < Columns.Count && ci < row.Length; ci++)
                {
                    var col = Columns[ci];
                    var cell = new Rectangle(cx, y, col.Width - 12, RowHeight);
                    if (ci == CheckColumn) PaintCheck(g, cell, Checked.Contains(i), Accent);
                    else
                        Draw.Text(g, row[ci] ?? "", fr, sel ? Theme.Text : Theme.Sub, cell,
                                  col.Right ? ContentAlignment.MiddleRight : ContentAlignment.MiddleLeft);
                    cx += col.Width;
                }
                using (var pen = new Pen(Theme.Divider))
                    g.DrawLine(pen, 0, y + RowHeight - 1, Width, y + RowHeight - 1);
                y += RowHeight;
            }

            if (Rows.Count == 0)
            {
                Draw.Text(g, "暂无数据", Theme.Font(9.5f), Theme.Hint,
                          new Rectangle(0, HeaderHeight, Width, Math.Max(40, Height - HeaderHeight)),
                          ContentAlignment.MiddleCenter);
            }
            g.Restore(state);
        }
    }
}

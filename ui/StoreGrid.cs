using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 商店卡片：一个条目 = 一张卡。精选库与搜索结果共用同一种卡，
    // 区别只在 Curated（决定底部徽章显示兼容性还是包源）。
    // ============================================================
    internal sealed class StoreCard
    {
        public string Key = "";          // 唯一键（批量勾选、选中态都按它记）
        public string CatalogId = "";    // 精选库 id（store-install 用）
        public string Name = "";         // 中文名 / 包名
        public string NameEn = "";       // 英文名 / 包 ID
        public string PackageId = "";    // choco / npm 包名
        public string Version = "";
        public string Source = "";
        public string Category = "";
        public string CategoryName = "";
        public string Compat = "";
        public string CompatNote = "";
        public string Ui = "";
        public bool Installed;
        public bool Curated;
        public Dictionary<string, object> Raw;   // 精选条目原始字段，详情弹窗用
    }

    // ============================================================
    // 卡片墙：自适应列数 + 滚轮滚动 + 悬停/选中 + 批量勾选。
    // 不使用 ScrollBar 控件，只用鼠标滚轮（和自绘表格一致）。
    // ============================================================
    internal sealed class StoreGrid : UiControl
    {
        public const int CardW = 236;
        public const int CardH = 108;
        public const int Gap = 14;
        private const int PadX = 2;
        private const int PadY = 2;

        public readonly List<StoreCard> Cards = new List<StoreCard>();
        public readonly HashSet<string> Checked = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        public event Action<int> RowActivated;
        public event Action<int> SelectionChanged;
        public event Action<string, bool> CheckChanged;

        private int _selected = -1;
        private int _hover = -1;
        private int _scroll;

        public StoreGrid()
        {
            // 必须先开启透明背景样式，再设 BackColor；反了会抛
            // "Control does not support transparent background colors."
            SetStyle(ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
        }

        public int SelectedIndex
        {
            get { return _selected; }
            set
            {
                int v = (value >= 0 && value < Cards.Count) ? value : -1;
                if (v == _selected) return;
                _selected = v;
                Invalidate();
            }
        }

        public StoreCard SelectedCard
        {
            get { return (_selected >= 0 && _selected < Cards.Count) ? Cards[_selected] : null; }
        }

        public void SetCards(List<StoreCard> cards, bool keepScroll)
        {
            Cards.Clear();
            if (cards != null) Cards.AddRange(cards);
            if (_selected >= Cards.Count) _selected = -1;
            if (!keepScroll) _scroll = 0;
            ClampScroll();
            _hover = -1;
            Invalidate();
        }

        public List<StoreCard> CheckedCards()
        {
            var list = new List<StoreCard>();
            foreach (var c in Cards)
                if (c.Key.Length > 0 && Checked.Contains(c.Key)) list.Add(c);
            return list;
        }

        public int CheckedCount { get { return Checked.Count; } }

        public void ClearChecked()
        {
            Checked.Clear();
            Invalidate();
        }

        // ---------------------------------------------------------- 布局计算
        private int Columns
        {
            get
            {
                int w = Width - PadX * 2;
                return Math.Max(1, (w + Gap) / (CardW + Gap));
            }
        }

        private int VisibleRows
        {
            get { return Math.Max(1, (Height - PadY * 2 + Gap) / (CardH + Gap)); }
        }

        private int RowCount
        {
            get { return Cards.Count == 0 ? 0 : (Cards.Count + Columns - 1) / Columns; }
        }

        private int MaxScroll
        {
            get { return Math.Max(0, RowCount - VisibleRows); }
        }

        private void ClampScroll()
        {
            if (_scroll < 0) _scroll = 0;
            int max = MaxScroll;
            if (_scroll > max) _scroll = max;
        }

        private Rectangle CardRect(int index)
        {
            int cols = Columns;
            int row = index / cols;
            int col = index % cols;
            return new Rectangle(PadX + col * (CardW + Gap),
                                 PadY + (row - _scroll) * (CardH + Gap), CardW, CardH);
        }

        private int IndexAt(Point p)
        {
            if (Cards.Count == 0) return -1;
            int cols = Columns;
            int rx = p.X - PadX;
            int ry = p.Y - PadY;
            if (rx < 0 || ry < 0) return -1;
            int col = rx / (CardW + Gap);
            int row = ry / (CardH + Gap) + _scroll;
            if (col >= cols) return -1;
            if (rx % (CardW + Gap) > CardW || ry % (CardH + Gap) > CardH) return -1;
            int idx = row * cols + col;
            return (idx >= 0 && idx < Cards.Count) ? idx : -1;
        }

        private static Rectangle CheckBoxRect(Rectangle card)
        {
            return new Rectangle(card.X + CardW - 32, card.Y + 11, 18, 18);
        }

        // ---------------------------------------------------------- 交互
        protected override void OnMouseMove(MouseEventArgs e)
        {
            int idx = IndexAt(e.Location);
            if (idx != _hover)
            {
                _hover = idx;
                Cursor = idx >= 0 ? Cursors.Hand : Cursors.Default;
                Invalidate();
            }
            base.OnMouseMove(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            if (_hover != -1) { _hover = -1; Cursor = Cursors.Default; Invalidate(); }
            base.OnMouseLeave(e);
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                int idx = IndexAt(e.Location);
                if (idx >= 0)
                {
                    var card = Cards[idx];
                    if (CheckBoxRect(CardRect(idx)).Contains(e.Location))
                    {
                        bool on = !Checked.Contains(card.Key);
                        if (on) Checked.Add(card.Key); else Checked.Remove(card.Key);
                        Invalidate();
                        if (CheckChanged != null) CheckChanged(card.Key, on);
                        base.OnMouseClick(e);
                        return;
                    }
                    if (idx != _selected)
                    {
                        _selected = idx;
                        Invalidate();
                        if (SelectionChanged != null) SelectionChanged(idx);
                    }
                }
            }
            base.OnMouseClick(e);
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                int idx = IndexAt(e.Location);
                if (idx >= 0)
                {
                    _selected = idx;
                    Invalidate();
                    if (RowActivated != null) RowActivated(idx);
                }
            }
            base.OnMouseDoubleClick(e);
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            int next = _scroll - Math.Sign(e.Delta);
            if (next < 0) next = 0;
            int max = MaxScroll;
            if (next > max) next = max;
            if (next != _scroll) { _scroll = next; Invalidate(); }
            base.OnMouseWheel(e);
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            ClampScroll();
        }

        // ---------------------------------------------------------- 绘制
        private static Color CompatFore(string c)
        {
            switch (c)
            {
                case "verified": return Theme.Ok;
                case "partial": return Theme.Warn;
                case "unsupported": return Theme.Err;
                default: return Theme.Hint;
            }
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

        private static void FillPill(Graphics g, Rectangle r, Color fore, Color back, string text)
        {
            using (var path = Draw.Round(r, r.Height / 2))
            {
                using (var b = new SolidBrush(back)) g.FillPath(b, path);
                using (var pen = new Pen(Color.FromArgb(70, fore))) g.DrawPath(pen, path);
            }
            Draw.Text(g, text, Theme.Font(8.5f, true), fore,
                      new Rectangle(r.X, r.Y, r.Width, r.Height), ContentAlignment.MiddleCenter);
        }

        private void DrawCard(Graphics g, int idx, Rectangle r, bool sel)
        {
            var card = Cards[idx];
            bool hov = idx == _hover;
            Color fill = sel ? Theme.AccentDim : (hov ? Theme.Mix(Theme.Card, Theme.CardHover, 0.55f) : Theme.Card);
            Color border = sel ? Theme.Accent : (hov ? Theme.BorderHi : Theme.Border);
            Draw.GlassCard(g, r, Theme.RCard, fill, border);
            if (sel)
            {
                using (var b = new SolidBrush(Theme.Accent))
                    g.FillRectangle(b, r.X + 1, r.Y + 12, 3, r.Height - 24);
            }

            // 批量勾选框
            var box = CheckBoxRect(r);
            bool on = card.Key.Length > 0 && Checked.Contains(card.Key);
            using (var path = Draw.Round(box, 5))
            {
                using (var b = new SolidBrush(on ? Theme.Accent : Theme.Sunken)) g.FillPath(b, path);
                using (var pen = new Pen(on ? Theme.Accent : Theme.BorderHi)) g.DrawPath(pen, path);
            }
            if (on)
            {
                using (var pen = new Pen(Color.White, 2f))
                    g.DrawLines(pen, new[]
                    {
                        new PointF(box.X + 4.5f, box.Y + 9f),
                        new PointF(box.X + 8f, box.Y + 12.5f),
                        new PointF(box.X + 14f, box.Y + 5f)
                    });
            }

            int textW = CardW - 56;
            Draw.Text(g, card.Name, Theme.Font(10.5f, true), Theme.Text,
                      new Rectangle(r.X + 14, r.Y + 9, textW, 24));
            string sub = card.NameEn.Length > 0 ? card.NameEn : card.PackageId;
            if (sub.Length > 0 && sub != card.Name)
                Draw.Text(g, sub, Theme.Font(8.5f), Theme.Hint,
                          new Rectangle(r.X + 14, r.Y + 33, CardW - 28, 18));
            string meta = card.CategoryName;
            if (card.Version.Length > 0) meta += (meta.Length > 0 ? " · " : "") + "v" + card.Version;
            if (meta.Length > 0)
                Draw.Text(g, meta, Theme.Font(8.5f), Theme.Sub,
                          new Rectangle(r.X + 14, r.Y + 54, CardW - 28, 18));

            // 底部徽章：精选看兼容性，搜索结果看包源
            string chip = card.Curated ? CompatText(card.Compat) : (card.Source.Length > 0 ? card.Source : "choco");
            Color fore = card.Curated ? CompatFore(card.Compat) : Theme.AccentHi;
            Color back = Theme.Mix(Theme.Bg, fore, 0.16f);
            int chipW = 12 + chip.Length * 12;
            if (chipW < 56) chipW = 56;
            FillPill(g, new Rectangle(r.X + 14, r.Y + CardH - 30, chipW, 21), fore, back, chip);

            if (card.Installed)
            {
                int iw = 52;
                var ir = new Rectangle(r.X + CardW - iw - 14, r.Y + CardH - 30, iw, 21);
                FillPill(g, ir, Theme.Ok, Theme.Mix(Theme.Bg, Theme.Ok, 0.16f), "已装");
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            if (Cards.Count == 0)
            {
                Draw.Text(g, "没有符合条件的应用", Theme.Font(9.5f), Theme.Hint,
                          new Rectangle(0, 0, Width, Math.Max(60, Height)), ContentAlignment.MiddleCenter);
                return;
            }

            int cols = Columns;
            int rows = RowCount;
            int lastRow = Math.Min(rows, _scroll + VisibleRows + 1);
            for (int row = _scroll; row < lastRow; row++)
            {
                for (int col = 0; col < cols; col++)
                {
                    int idx = row * cols + col;
                    if (idx >= Cards.Count) break;
                    DrawCard(g, idx, CardRect(idx), idx == _selected);
                }
            }

            // 滚动条：只有内容超出时才画
            if (rows > VisibleRows)
            {
                int trackTop = PadY;
                int trackH = Math.Max(40, Height - PadY * 2);
                int barH = Math.Max(30, trackH * VisibleRows / rows);
                int barY = trackTop + (trackH - barH) * _scroll / Math.Max(1, rows - VisibleRows);
                using (var b = new SolidBrush(Theme.Mix(Theme.Border, Theme.BorderHi, 0.4f)))
                using (var path = Draw.Round(new Rectangle(Width - 7, barY, 4, barH), 2))
                    g.FillPath(b, path);
            }
        }
    }
}

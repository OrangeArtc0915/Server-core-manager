using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 控件库：全部自绘。PowerShell 版里这些是手画的 Panel + Paint 回调，
    // 换成 C# 之后同一套视觉，但每帧只花几十微秒，hover/切换才能做出动画。
    // ============================================================

    internal abstract class UiControl : Control
    {
        protected UiControl()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
        }
    }

    // ------------------------------------------------------------ 导航项
    internal sealed class NavItem : UiControl
    {
        public string Glyph = "";
        public string PageKey = "";
        private bool _activeOn;
        private double _active;
        private double _hover;

        public bool Active
        {
            get { return _activeOn; }
            set
            {
                if (_activeOn == value) return;
                _activeOn = value;
                double from = _active, to = value ? 1 : 0;
                Anim.Run(180, v =>
                {
                    _active = from + (to - from) * v;
                    Invalidate();
                }, null, Ease.OutCubic);
            }
        }

        public NavItem(string text, string glyph, string pageKey)
        {
            Text = text;
            Glyph = glyph;
            PageKey = pageKey;
            Height = 40;
            Cursor = Cursors.Hand;
        }

        private void SetHover(bool on)
        {
            double from = _hover, to = on ? 1 : 0;
            Anim.Run(120, v =>
            {
                _hover = from + (to - from) * v;
                Invalidate();
            }, null, Ease.OutCubic);
        }

        protected override void OnMouseEnter(EventArgs e) { SetHover(true); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { SetHover(false); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            Color bg = Theme.Panel;
            if (_active > 0.01) bg = Theme.Mix(Theme.Mix(Theme.Panel, Theme.CardHover, (float)_hover),
                                              Theme.AccentDim, (float)_active);
            else if (_hover > 0) bg = Theme.Mix(Theme.Panel, Theme.CardHover, (float)_hover);

            using (var path = Draw.Round(new Rectangle(0, 0, Width - 1, Height - 1), Theme.RItem))
            using (var b = new SolidBrush(bg))
                g.FillPath(b, path);

            if (_active > 0.01)
            {
                int barH = (int)(18 * _active);
                using (var b = new SolidBrush(Color.FromArgb((int)(255 * _active), Theme.Accent)))
                using (var path = Draw.Round(new Rectangle(1, (Height - barH) / 2, 3, Math.Max(2, barH)), 2))
                    g.FillPath(b, path);
            }

            float hi = (float)Math.Max(_active, _hover * 0.6);
            Color fore = Theme.Mix(Theme.Sub, Color.White, hi);
            Icons.Draw(g, Glyph, new Rectangle(15, (Height - 17) / 2, 17, 17), fore, 1.5f);
            var f = Theme.Font(9.75f);
            Draw.Text(g, Text, f, fore, new Rectangle(42, 0, Width - 52, Height));
        }
    }

    // ------------------------------------------------------------ 按钮
    internal enum ButtonKind { Normal, Primary, Danger, Ghost }

    internal sealed class UiButton : UiControl
    {
        public ButtonKind Kind = ButtonKind.Normal;
        public string Glyph = "";
        // 「缺失 / 不可用」外观：变灰但仍然可点（点了要告诉用户缺什么、怎么补）
        public bool Dim;
        private bool _down;
        private double _hover;

        public UiButton(string text, ButtonKind kind = ButtonKind.Normal, int width = 96, int height = 34)
        {
            Text = text;
            Kind = kind;
            Size = new Size(width, height);
            Cursor = Cursors.Hand;
            Font = Theme.Font(9.75f);
        }

        private void SetHover(bool on)
        {
            double from = _hover, to = on ? 1 : 0;
            Anim.Run(110, v => { _hover = from + (to - from) * v; Invalidate(); }, null, Ease.OutCubic);
        }

        protected override void OnMouseEnter(EventArgs e) { SetHover(true); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { SetHover(false); _down = false; base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { _down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);

            Color fill, fore, border;
            switch (Kind)
            {
                case ButtonKind.Primary:
                    fill = _down ? Theme.Accent : Theme.Mix(Theme.Accent, Theme.AccentHi, (float)_hover);
                    fore = Color.White; border = fill; break;
                case ButtonKind.Danger:
                    fill = _down ? Theme.Err : Theme.Mix(Theme.Err, Color.White, (float)_hover * 0.15f);
                    fore = Color.White; border = fill; break;
                case ButtonKind.Ghost:
                    fill = _down ? Theme.AccentDim : Theme.Mix(Theme.Panel, Theme.CardHover, (float)_hover);
                    fore = _down ? Color.White : Theme.Sub; border = Color.Transparent; break;
                default:
                    if (Dim)
                    {
                        fill = _down ? Theme.Sunken : Theme.Mix(Theme.Card, Theme.Bg, 0.45f);
                        fore = _hover > 0.5 ? Theme.Hint : Theme.Disabled;
                        border = Theme.Divider;
                        break;
                    }
                    fill = _down ? Theme.AccentDim : Theme.Mix(Theme.Card, Theme.CardHover, (float)_hover);
                    fore = _hover > 0.5 ? Theme.Text : Theme.Sub; border = Theme.BorderHi; break;
            }

            using (var path = Draw.Round(r, Theme.RButton))
            {
                using (var b = new SolidBrush(fill)) g.FillPath(b, path);
                if (border.A > 0)
                    using (var pen = new Pen(border, 1)) g.DrawPath(pen, path);
            }

            int textLeft = 0;
            if (!string.IsNullOrEmpty(Glyph))
            {
                Icons.Draw(g, Glyph, new Rectangle(11, (Height - 15) / 2, 15, 15), fore, 1.4f);
                textLeft = 30;
            }
            Draw.Text(g, Text, Font, fore,
                      new Rectangle(textLeft + 12, 0, Width - textLeft - 20, Height),
                      ContentAlignment.MiddleCenter);
        }
    }

    // ------------------------------------------------------------ 圆形图标按钮
    internal sealed class IconButton : UiControl
    {
        public string Glyph = "";
        private double _hover;

        public IconButton(string glyph, int size = 32)
        {
            Glyph = glyph;
            Size = new Size(size, size);
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e)
        {
            Anim.Run(110, v => { _hover = v; Invalidate(); }, null, Ease.OutCubic);
            base.OnMouseEnter(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            Anim.Run(110, v => { _hover = 1 - v; Invalidate(); }, null, Ease.OutCubic);
            base.OnMouseLeave(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (_hover > 0.01)
            {
                using (var b = new SolidBrush(Theme.Mix(Theme.Panel, Theme.CardHover, (float)_hover)))
                using (var path = Draw.Round(new Rectangle(0, 0, Width - 1, Height - 1), Theme.RButton))
                    g.FillPath(b, path);
            }
            var fore = Theme.Mix(Theme.Hint, Theme.Text, (float)_hover);
            Icons.Draw(g, Glyph, new Rectangle((Width - 16) / 2, (Height - 16) / 2, 16, 16), fore, 1.5f);
        }
    }

    // ------------------------------------------------------------ 胶囊
    internal sealed class Pill : UiControl
    {
        public string Kind = "Info";
        public Pill(string text, string kind = "Info")
        {
            Text = text;
            Kind = kind;
            Height = 24;
            ResizeToText();
        }

        private void ResizeToText()
        {
            // 量的时候也要 NoPadding，否则胶囊比文字宽出一圈、和旁边按钮对不齐
            var sz = TextRenderer.MeasureText(Text, Theme.Font(9f, true), new Size(4000, 100),
                TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            Width = sz.Width + 20;
        }

        public void SetText(string s)
        {
            Text = s;
            ResizeToText();
            Invalidate();
        }

        public void SetKind(string kind)
        {
            Kind = kind;
            Invalidate();
        }

        private void Colors(out Color fore, out Color back)
        {
            switch (Kind)
            {
                case "Success": fore = Theme.Ok;   back = Theme.Mix(Theme.Bg, Theme.Ok, 0.16f); break;
                case "Warn":    fore = Theme.Warn; back = Theme.Mix(Theme.Bg, Theme.Warn, 0.16f); break;
                case "Danger":  fore = Theme.Err;  back = Theme.Mix(Theme.Bg, Theme.Err, 0.16f); break;
                case "Neutral": fore = Theme.Sub;  back = Theme.Sunken; break;
                default:        fore = Theme.AccentHi; back = Theme.AccentDim; break;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color fore, back;
            Colors(out fore, out back);
            using (var path = Draw.Round(new Rectangle(0, 0, Width - 1, Height - 1), Height / 2))
            using (var b = new SolidBrush(back))
                g.FillPath(b, path);
            Draw.Text(g, Text, Theme.Font(9f, true), fore,
                      new Rectangle(0, 0, Width, Height), ContentAlignment.MiddleCenter);
        }
    }

    // ------------------------------------------------------------ 玻璃容器
    internal class SurfaceCard : UiControl
    {
        public int Radius = Theme.RCard;
        public Color Accent = Theme.Accent;
        public bool HoverGlow = true;
        protected double Hover;

        public SurfaceCard()
        {
            BackColor = Theme.Card;
        }

        protected override void OnMouseEnter(EventArgs e)
        {
            if (!HoverGlow) return;
            Anim.Run(140, v => { Hover = v; Invalidate(); }, null, Ease.OutCubic);
            base.OnMouseEnter(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            if (!HoverGlow) return;
            Anim.Run(160, v => { Hover = 1 - v; Invalidate(); }, null, Ease.OutCubic);
            base.OnMouseLeave(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            var r = new Rectangle(0, 0, Width, Height);
            Color fill = Hover > 0.02 ? Theme.Mix(Theme.Card, Theme.CardHover, (float)Hover) : Theme.Card;
            Color border = Hover > 0.02 ? Theme.Mix(Theme.Border, Accent, (float)Hover) : Theme.Border;
            Draw.GlassCard(g, r, Radius, fill, border);
            if (Hover > 0.02) Draw.TopGlow(g, r, Radius, Accent, (int)(38 * Hover));
            OnPaintContent(g, r);
        }

        protected virtual void OnPaintContent(Graphics g, Rectangle r) { }
    }

    // ------------------------------------------------------------ 指标卡
    internal sealed class StatCard : SurfaceCard
    {
        public string Caption = "";
        public string Value = "—";
        public string Note = "";

        public StatCard(string caption, string value, Color accent, string note = "")
        {
            Caption = caption;
            Value = value;
            Note = note;
            Accent = accent;
            Size = new Size(208, 104);
        }

        protected override void OnPaintContent(Graphics g, Rectangle r)
        {
            using (var b = new SolidBrush(Accent)) g.FillEllipse(b, 14, 13, 7, 7);
            Draw.Text(g, Caption, Theme.Font(9f), Theme.Hint, new Rectangle(30, 8, r.Width - 40, 20));
            Draw.Text(g, Value, Theme.Mono(17f, true), Theme.Text, new Rectangle(14, 32, r.Width - 26, 40));
            Draw.Text(g, Note, Theme.Font(8.5f), Theme.Sub, new Rectangle(14, 76, r.Width - 26, 18));
        }

        // 运行时更新数值（数据回来后由页面调用）
        public void Set(string value, string note = null)
        {
            Value = string.IsNullOrEmpty(value) ? "—" : value;
            if (note != null) Note = note;
            Invalidate();
        }
    }

    // ------------------------------------------------------------ 圆角输入框（容器 + 无边框 TextBox）
    internal sealed class UiInput : UiControl
    {
        public readonly TextBox Box;
        private bool _focus;

        public UiInput(int width, string placeholder = "", int height = 32, bool multiline = false)
        {
            Size = new Size(width, height);
            BackColor = Theme.Sunken;
            Box = new TextBox
            {
                BorderStyle = BorderStyle.None,
                BackColor = Theme.Sunken,
                ForeColor = Theme.Text,
                Font = Theme.Font(9.5f),
                Multiline = multiline,
                ScrollBars = multiline ? ScrollBars.Vertical : ScrollBars.None
            };
            // 单行：按真实行高垂直居中（写死 8 会在不同 DPI / 字号下偏上或偏下）
            if (multiline)
            {
                Box.Location = new Point(11, 8);
                Box.Height = Math.Max(20, height - 16);
            }
            else
            {
                Box.Location = new Point(11, Math.Max(3, (height - Box.PreferredHeight) / 2));
            }
            // .NET Framework 的 TextBox 没有 PlaceholderText；占位文案由调用方用 Label 处理。
            Box.GotFocus += (s, e) => { _focus = true; Invalidate(); };
            Box.LostFocus += (s, e) => { _focus = false; Invalidate(); };
            Controls.Add(Box);
        }

        public string ValueText
        {
            get { return Box.Text; }
            set { Box.Text = value; }
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            if (Box != null)
            {
                Box.Width = Math.Max(20, Width - 20);
                if (Box.Multiline) Box.Height = Math.Max(20, Height - 16);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Draw.Round(r, Theme.RButton))
            {
                using (var b = new SolidBrush(Theme.Sunken)) g.FillPath(b, path);
                using (var pen = new Pen(_focus ? Theme.Accent : Theme.Border, 1))
                    g.DrawPath(pen, path);
            }
        }
    }

    // ------------------------------------------------------------ 勾选框
    internal sealed class UiCheck : UiControl
    {
        public bool Checked;

        public UiCheck(string text, bool value = false)
        {
            Text = text;
            Checked = value;
            Height = 26;
            Cursor = Cursors.Hand;
            BackColor = Theme.Card;
        }

        protected override void OnClick(EventArgs e)
        {
            Checked = !Checked;
            Invalidate();
            base.OnClick(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var box = new Rectangle(0, 4, 18, 18);
            using (var path = Draw.Round(box, 5))
            {
                using (var b = new SolidBrush(Checked ? Theme.Accent : Theme.Sunken)) g.FillPath(b, path);
                using (var pen = new Pen(Checked ? Theme.Accent : Theme.BorderHi)) g.DrawPath(pen, path);
            }
            if (Checked)
            {
                using (var pen = new Pen(Color.White, 2f))
                    g.DrawLines(pen, new[]
                    {
                        new PointF(4.5f, 13f), new PointF(8f, 16.5f), new PointF(14f, 9f)
                    });
            }
            Draw.Text(g, Text, Theme.Font(9.5f), Theme.Sub,
                      new Rectangle(26, 0, Math.Max(20, Width - 30), Height));
        }
    }

    // ------------------------------------------------------------ 分隔线
    internal sealed class Divider : Control
    {
        public Divider()
        {
            Height = 1;
            BackColor = Theme.Divider;
        }
    }
}

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 绘制工具：圆角、玻璃卡片、星空底、文本、投影。
    // 全部是纯 GDI+，Server Core 上没有硬件加速也能跑。
    // ============================================================
    internal static class Draw
    {
        public static GraphicsPath Round(Rectangle r, int radius)
        {
            var p = new GraphicsPath();
            int d = Math.Max(1, radius * 2);
            if (d > r.Width) d = r.Width;
            if (d > r.Height) d = r.Height;
            if (d <= 1)
            {
                p.AddRectangle(r);
                return p;
            }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseAllFigures();
            return p;
        }

        // 玻璃卡片：底色 + 白 6%->1% 纵向渐变 + 顶部内高光 + 1px 描边
        public static void GlassCard(Graphics g, Rectangle r, int radius, Color fill, Color border)
        {
            if (r.Width <= 2 || r.Height <= 2) return;
            var old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var inner = new Rectangle(r.X, r.Y, r.Width - 1, r.Height - 1);
            using (var path = Round(inner, radius))
            {
                using (var b = new SolidBrush(fill)) g.FillPath(b, path);
                using (var lg = new LinearGradientBrush(inner,
                           Color.FromArgb(16, 255, 255, 255), Color.FromArgb(3, 255, 255, 255),
                           LinearGradientMode.Vertical))
                    g.FillPath(lg, path);

                // Save/Restore 比 g.Clip 取 Region 再赋回去便宜：后者每帧都新建一个
                // Region 句柄，而且拿到的 Region 还得自己 Dispose。
                var state = g.Save();
                g.SetClip(path);
                using (var pen = new Pen(Color.FromArgb(26, 255, 255, 255), 1))
                    g.DrawLine(pen, inner.X + 4, inner.Y + 1, inner.Right - 5, inner.Y + 1);
                g.Restore(state);

                // 描边直接复用同一个 path（平移 0.5px 让 1px 线落在像素中心），
                // 以前这里又 Round 了一次，每张卡每帧多 0.12ms。
                using (var pen = new Pen(border, 1))
                {
                    var t = g.Transform;
                    g.TranslateTransform(0.5f, 0.5f);
                    g.DrawPath(pen, path);
                    g.Transform = t;
                }
            }
            g.SmoothingMode = old;
        }

        // 顶部强调色光晕（卡片悬停时用）
        public static void TopGlow(Graphics g, Rectangle r, int radius, Color accent, int strength = 38)
        {
            var old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var inner = new Rectangle(r.X, r.Y, r.Width - 1, r.Height - 1);
            using (var path = Round(inner, radius))
            {
                var state = g.Save();
                g.SetClip(path);
                int h = Math.Min(72, Math.Max(24, r.Height / 2));
                var glow = new Rectangle(r.X, r.Y, r.Width, h);
                using (var lg = new LinearGradientBrush(glow,
                           Color.FromArgb(strength, accent), Color.FromArgb(0, accent),
                           LinearGradientMode.Vertical))
                    g.FillRectangle(lg, glow);
                g.Restore(state);
            }
            g.SmoothingMode = old;
        }

        // 星空底：中心偏下的大椭圆径向渐变（对应 XMP 的 radial-gradient）
        public static void Starfield(Graphics g, Rectangle r)
        {
            if (r.Width <= 2 || r.Height <= 2) return;
            var old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = new GraphicsPath())
            {
                path.AddEllipse(r.X - r.Width * 0.25f, r.Y - r.Height * 0.15f,
                                r.Width * 1.5f, r.Height * 1.6f);
                using (var pgb = new PathGradientBrush(path))
                {
                    pgb.CenterPoint = new PointF(r.X + r.Width * 0.5f, r.Y + r.Height * 1.15f);
                    pgb.CenterColor = Theme.Glow;
                    pgb.SurroundColors = new[] { Theme.BgTop };
                    g.FillPath(pgb, path);
                }
            }
            g.SmoothingMode = old;
        }

        // 多行文本（对话框里的说明、长消息）
        public static void TextBlock(Graphics g, string s, Font f, Color c, Rectangle r)
        {
            if (string.IsNullOrEmpty(s)) return;
            TextRenderer.DrawText(g, s, f, r, c,
                TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.Top |
                TextFormatFlags.NoPadding);
        }

        public static void Text(Graphics g, string s, Font f, Color c, Rectangle r,
                                ContentAlignment align = ContentAlignment.MiddleLeft)
        {
            if (string.IsNullOrEmpty(s)) return;
            // NoPadding：GDI 默认会按字体内部 leading 加上下留白，同一段文字在
            // 「自绘文本」和「Label」之间会差 1-2px（125% 缩放下更明显）。
            // 统一关掉，所有文本才落在同一条基线上。
            TextFormatFlags fl = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine
                               | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix
                               | TextFormatFlags.NoPadding;
            if (align == ContentAlignment.MiddleCenter || align == ContentAlignment.TopCenter ||
                align == ContentAlignment.BottomCenter)
                fl |= TextFormatFlags.HorizontalCenter;
            else if (align == ContentAlignment.MiddleRight || align == ContentAlignment.TopRight ||
                     align == ContentAlignment.BottomRight)
                fl |= TextFormatFlags.Right;
            if (align == ContentAlignment.TopLeft || align == ContentAlignment.TopCenter || align == ContentAlignment.TopRight)
                fl = (fl & ~TextFormatFlags.VerticalCenter) | TextFormatFlags.Top;
            TextRenderer.DrawText(g, s, f, r, c, fl);
        }

        // 窗口外投影：在 Frame 留白里画几层半透明黑（GDI+ 没有模糊）
        public static void ShellShadow(Graphics g, Rectangle r, int radius, int layers = 6)
        {
            var old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            for (int i = layers; i >= 1; i--)
            {
                var rr = new Rectangle(r.X - i, r.Y - i + 1, r.Width + i * 2, r.Height + i * 2);
                using (var path = Round(rr, radius + i))
                using (var pen = new Pen(Color.FromArgb(10, 0, 0, 0), 2))
                    g.DrawPath(pen, path);
            }
            g.SmoothingMode = old;
        }
    }

    // ============================================================
    // 动画：一个共享 60fps 定时器驱动所有补间。
    // PowerShell 版做不到这个（事件回调里没有稳定的帧节奏），
    // 这是换成 C# 之后最直接的观感提升来源。
    // ============================================================
    internal static class Anim
    {
        private sealed class Tween
        {
            public long StartMs;
            public int Duration;
            public Action<double> Tick;
            public Action Done;
            public Func<double, double> Ease;
            public bool Finished;
        }

        private static readonly List<Tween> Items = new List<Tween>();
        // 复用快照表：15ms 一帧，动画期间每帧 new 一个 List 会稳定制造垃圾
        private static readonly List<Tween> Snapshot = new List<Tween>();
        private static readonly Stopwatch Clock = Stopwatch.StartNew();
        private static readonly Timer Ticker = new Timer { Interval = 15 };

        static Anim()
        {
            Ticker.Tick += (s, e) => Step();
        }

        public static void Run(int durationMs, Action<double> tick, Action done = null,
                               Func<double, double> ease = null)
        {
            if (durationMs <= 0)
            {
                if (tick != null) tick(1);
                if (done != null) done();
                return;
            }
            lock (Items)
            {
                Items.Add(new Tween
                {
                    StartMs = Clock.ElapsedMilliseconds,
                    Duration = durationMs,
                    Tick = tick,
                    Done = done,
                    Ease = ease ?? Ease.OutCubic
                });
            }
            if (!Ticker.Enabled) Ticker.Start();
        }

        private static void Step()
        {
            List<Tween> snapshot;
            lock (Items)
            {
                Snapshot.Clear();
                Snapshot.AddRange(Items);
                snapshot = Snapshot;
            }
            bool any = false;
            foreach (var t in snapshot)
            {
                double raw = (Clock.ElapsedMilliseconds - t.StartMs) / (double)t.Duration;
                if (raw > 1) raw = 1;
                double v = t.Ease(raw);
                try { if (t.Tick != null) t.Tick(v); } catch { }
                if (raw >= 1 && !t.Finished)
                {
                    t.Finished = true;
                    try { if (t.Done != null) t.Done(); } catch { }
                }
                else if (!t.Finished) any = true;
            }
            lock (Items) Items.RemoveAll(x => x.Finished);
            if (!any) Ticker.Stop();
        }
    }

    internal static class Ease
    {
        public static double Linear(double t) { return t; }
        public static double OutCubic(double t) { double u = 1 - t; return 1 - u * u * u; }
        public static double OutQuart(double t) { double u = 1 - t; return 1 - u * u * u * u; }
        public static double InOutSine(double t) { return -(Math.Cos(Math.PI * t) - 1) / 2; }
        public static double OutBack(double t)
        {
            const double c = 1.70158;
            double u = t - 1;
            return 1 + (c + 1) * u * u * u + c * u * u;
        }
    }
}

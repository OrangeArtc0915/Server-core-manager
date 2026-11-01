using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 动态背景层：XMP 的底部星空辉光 + HMOL 那种分层背景。
    // 性能上做了取舍：整张背景只在尺寸变化时渲染一次（比可视区四周各大 48px），
    // 之后每帧只是「从这张大图里裁一块」——同尺寸裁剪拷贝实测 0.5ms，
    // 而 GDI+ 的平滑缩放要 30ms，9fps 下会直接把 CPU 吃掉。
    // 动画靠慢速平移（视差），和 HMOL 的 TranslateTransform 是同一个思路。
    // 只在窗口激活时跑，失焦立刻停。
    // ============================================================
    internal sealed class Backdrop : IDisposable
    {
        private const int Margin = 48;

        private struct Star
        {
            public float X, Y, R;
            public int A;
        }

        public static Backdrop Current;

        // 背景平移是 100s 级别的慢速视差，250ms 一帧（4fps）已经足够顺；
        // 原来 150ms 只是多烧 40% 的重绘量，肉眼看不出差别。
        private readonly Timer _timer = new Timer { Interval = 250 };
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private readonly Star[] _stars;
        private readonly object _sync = new object();
        private Bitmap _canvas;
        private Size _view;
        private bool _building;
        private bool _disposed;
        private bool _running;

        // 每帧回调：主窗用它重绘当前页
        public Action Tick;

        // 大图就绪（或尺寸变化后重建完成）时回调一次。
        // 首帧画的时候画布还没生成，各面板只画了纯色底；这里补一次全量重绘，
        // 背景图才会出现 —— 这一步是事件驱动的，不是每帧。
        public Action Built;

        public Backdrop()
        {
            Current = this;
            _timer.Tick += (s, e) =>
            {
                if (Tick != null) Tick();
            };

            var rnd = new Random(20261025);
            _stars = new Star[110];
            for (int i = 0; i < _stars.Length; i++)
            {
                _stars[i] = new Star
                {
                    X = (float)rnd.NextDouble(),
                    Y = (float)rnd.NextDouble(),
                    R = 0.4f + (float)rnd.NextDouble() * 0.9f,
                    A = 12 + rnd.Next(40)
                };
            }
        }

        public void Start()
        {
            if (_running) return;
            _running = true;
            _timer.Start();
        }

        public void Stop()
        {
            if (!_running) return;
            _running = false;
            _timer.Stop();
        }

        // 把背景画到窗口的某一块区域（abs = 该区域在整个窗口客户区里的左上角）
        public void DrawAt(Graphics g, Point abs, Size area, Size window)
        {
            if (area.Width <= 2 || area.Height <= 2) return;

            Bitmap canvas;
            Size view;
            lock (_sync) { canvas = _canvas; view = _view; }

            if (canvas == null || view.Width != window.Width || view.Height != window.Height)
            {
                // 整张背景 100ms 左右，放到后台渲染；首帧用纯色顶上，
                // 别拿渐变去凑（每个面板画一遍渐变会把启动拖慢 100ms）
                StartBuild(window);
                g.Clear(Theme.Bg);
                return;
            }

            double t = _clock.Elapsed.TotalSeconds;
            int ox = abs.X + (int)((Math.Sin(t * 0.05) + 1) * 0.5 * Margin * 2);
            int oy = abs.Y + (int)((Math.Cos(t * 0.037) + 1) * 0.5 * Margin * 2);
            if (ox < 0) ox = 0;
            if (oy < 0) oy = 0;
            // 视差会把取图窗口推到画布外：越界时 GDI+ 会补透明像素，
            // 表现就是某块面板的背景「换了色 / 有缝 / 和旁边错开」。
            // 这里把取图矩形钳进画布内，宁可少一点视差，也不能出现错位。
            int maxX = Math.Max(0, canvas.Width - area.Width);
            int maxY = Math.Max(0, canvas.Height - area.Height);
            if (ox > maxX) ox = maxX;
            if (oy > maxY) oy = maxY;
            var src = new Rectangle(ox, oy, area.Width, area.Height);

            var oldMode = g.CompositingMode;
            var oldInterp = g.InterpolationMode;
            var oldOffset = g.PixelOffsetMode;
            // 不用 SourceCopy：GDI+ 在带子控件裁剪区时会对没覆盖到的像素留黑
            g.CompositingMode = CompositingMode.SourceOver;
            // 同尺寸裁剪不需要插值；不指定 NearestNeighbor 的话 GDI+ 会走 30ms 的缩放路径
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(canvas, new Rectangle(0, 0, area.Width, area.Height), src, GraphicsUnit.Pixel);
            g.CompositingMode = oldMode;
            g.InterpolationMode = oldInterp;
            g.PixelOffsetMode = oldOffset;
        }

        // 控件在窗口客户区里的绝对坐标（各层 Location 相加）
        public static Point AbsoluteLocation(Control c)
        {
            int x = 0, y = 0;
            while (c != null)
            {
                x += c.Left;
                y += c.Top;
                c = c.Parent;
            }
            return new Point(x, y);
        }

        private void StartBuild(Size size)
        {
            lock (_sync)
            {
                if (_building || _disposed) return;
                _building = true;
            }
            var target = new Size(size.Width, size.Height);
            System.Threading.ThreadPool.QueueUserWorkItem(_ =>
            {
                // 启动后 350ms 内先别渲染：GDI+ 有全局锁，后台画大图会和首屏绘制抢，
                // 实测会把「窗口可见」从 125ms 拖到 230ms
                long elapsed = _clock.ElapsedMilliseconds;
                if (elapsed < 350)
                {
                    try { System.Threading.Thread.Sleep((int)(350 - elapsed)); } catch { }
                }
                Bitmap bmp = null;
                try
                {
                    bmp = new Bitmap(target.Width + Margin * 2, target.Height + Margin * 2,
                                     PixelFormat.Format32bppPArgb);
                    Render(bmp);
                }
                catch
                {
                    if (bmp != null) { bmp.Dispose(); bmp = null; }
                }
                lock (_sync)
                {
                    _building = false;
                    if (_disposed) { if (bmp != null) bmp.Dispose(); return; }
                    if (bmp == null) return;
                    if (_canvas != null) _canvas.Dispose();
                    _canvas = bmp;
                    _view = target;
                }
                if (Built != null)
                {
                    try { Built(); } catch { }
                }
            });
        }

        private void Render(Bitmap bmp)
        {
            using (var g = Graphics.FromImage(bmp))
            {
                // 雾气边缘本来就是透明的，不需要抗锯齿
                g.SmoothingMode = SmoothingMode.None;
                g.Clear(Theme.Bg);
                int w = bmp.Width, h = bmp.Height;

                // 1) 底部中央的大椭圆径向（XMP 的 radial-gradient at bottom）
                using (var path = new GraphicsPath())
                {
                    path.AddEllipse(-w * 0.25f, -h * 0.15f, w * 1.5f, h * 1.6f);
                    using (var pgb = new PathGradientBrush(path))
                    {
                        pgb.CenterPoint = new PointF(w * 0.5f, h * 1.15f);
                        pgb.CenterColor = Theme.Glow;
                        pgb.SurroundColors = new[] { Theme.BgTop };
                        g.FillPath(pgb, path);
                    }
                }

                // 2) 两团强调色雾：左上蓝、右下紫（HMOL 的层次感）
                Blob(g, w * 0.24f, h * 0.16f, w * 0.62f, Color.FromArgb(26, 64, 158, 255));
                Blob(g, w * 0.86f, h * 0.76f, w * 0.66f, Color.FromArgb(20, 139, 92, 246));

                // 3) 顶部极淡高光
                int topH = Math.Max(8, h / 3);
                using (var lg = new LinearGradientBrush(new Rectangle(0, 0, w, topH),
                           Color.FromArgb(12, 255, 255, 255), Color.FromArgb(0, 255, 255, 255),
                           LinearGradientMode.Vertical))
                    g.FillRectangle(lg, 0, 0, w, topH);

                // 4) 星点
                for (int i = 0; i < _stars.Length; i++)
                {
                    var p = _stars[i];
                    using (var b = new SolidBrush(Color.FromArgb(p.A, 255, 255, 255)))
                    {
                        float x = p.X * w, y = p.Y * h;
                        g.FillEllipse(b, x - p.R, y - p.R, p.R * 2, p.R * 2);
                    }
                }
            }
        }

        // 一团柔和的径向雾：中心实、边缘透明
        private static void Blob(Graphics g, float cx, float cy, float radius, Color inner)
        {
            if (radius <= 1) return;
            using (var path = new GraphicsPath())
            {
                path.AddEllipse(cx - radius, cy - radius, radius * 2, radius * 2);
                using (var pgb = new PathGradientBrush(path))
                {
                    pgb.CenterPoint = new PointF(cx, cy);
                    pgb.CenterColor = inner;
                    pgb.SurroundColors = new[] { Color.FromArgb(0, inner) };
                    pgb.FocusScales = new PointF(0.15f, 0.15f);
                    g.FillPath(pgb, path);
                }
            }
        }

        public void Dispose()
        {
            Stop();
            _timer.Dispose();
            lock (_sync)
            {
                _disposed = true;
                if (_canvas != null) { _canvas.Dispose(); _canvas = null; }
            }
            if (Current == this) Current = null;
        }
    }
}

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace ScmUi
{
    // ============================================================
    // 设计 token：与 PowerShell 版保持同一套值（XMP 深色 + HMOL 组件结构）。
    // 换肤只改这里，控件全部从这里取色。
    // ============================================================
    internal static class Theme
    {
        // 承载面
        public static readonly Color Frame     = Hex("#0B0B10");
        public static readonly Color Bg        = Hex("#0A0A0C");
        public static readonly Color BgTop     = Hex("#08080A");
        public static readonly Color Glow      = Hex("#1B2735");
        public static readonly Color Panel     = Hex("#14161E");   // 侧栏 / 标题栏 / 日志栏
        public static readonly Color Card      = Hex("#14161E");
        public static readonly Color CardHover = Hex("#1A1C24");
        public static readonly Color Sunken    = Hex("#111116");
        public static readonly Color Border    = Hex("#2B2B2C");
        public static readonly Color BorderHi  = Hex("#363637");
        public static readonly Color Divider   = Hex("#22232A");

        // 文字
        public static readonly Color Text      = Hex("#E5EAF3");
        public static readonly Color Sub       = Hex("#CFD3DC");
        public static readonly Color Hint      = Hex("#A3A6AD");
        public static readonly Color Disabled  = Hex("#6C6E72");

        // 强调与语义
        public static readonly Color Accent    = Hex("#409EFF");
        public static readonly Color AccentHi  = Hex("#66B1FF");
        public static readonly Color AccentDim = Hex("#1B2A3D");
        public static readonly Color Ok        = Hex("#67C23A");
        public static readonly Color Warn      = Hex("#E6A23C");
        public static readonly Color Err       = Hex("#F56C6C");

        // 圆角
        public const int RSmall  = 6;
        public const int RButton = 8;
        public const int RItem   = 8;
        public const int RCard   = 8;
        public const int RShell  = 12;

        private static readonly Dictionary<string, Color> Colors = new Dictionary<string, Color>();
        private static readonly Dictionary<string, Font> Fonts  = new Dictionary<string, Font>();

        public static Color Hex(string s)
        {
            s = s.TrimStart('#');
            return Color.FromArgb(
                Convert.ToInt32(s.Substring(0, 2), 16),
                Convert.ToInt32(s.Substring(2, 2), 16),
                Convert.ToInt32(s.Substring(4, 2), 16));
        }

        // 字体缓存：几百个标签共用同一批 Font 实例（Font 不可变，共享安全）。
        public static Font Font(float size, bool bold = false)
        {
            string key = "y" + size.ToString("0.##") + (bold ? "b" : "");
            Font f;
            if (!Fonts.TryGetValue(key, out f))
            {
                f = new Font("Microsoft YaHei UI", size,
                    bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Point);
                Fonts[key] = f;
            }
            return f;
        }

        public static Font Mono(float size, bool bold = false)
        {
            string key = "c" + size.ToString("0.##") + (bold ? "b" : "");
            Font f;
            if (!Fonts.TryGetValue(key, out f))
            {
                f = new Font("Consolas", size,
                    bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Point);
                Fonts[key] = f;
            }
            return f;
        }

        public static Color Mix(Color a, Color b, float t)
        {
            if (t < 0) t = 0;
            if (t > 1) t = 1;
            return Color.FromArgb(
                (int)(a.R + (b.R - a.R) * t),
                (int)(a.G + (b.G - a.G) * t),
                (int)(a.B + (b.B - a.B) * t));
        }

        // 每个模块一个强调色（XMP 的做法）
        public static Color AccentOf(string icon)
        {
            switch (icon)
            {
                case "monitor":  return Hex("#409EFF");
                case "store":    return Hex("#C084FC");
                case "env":      return Hex("#22D3EE");
                case "role":     return Hex("#34D399");
                case "security": return Hex("#FBBF24");
                case "app":      return Hex("#F472B6");
                case "runtime":  return Hex("#38BDF8");
                case "database": return Hex("#818CF8");
                case "tool":     return Hex("#60A5FA");
                case "beauty":   return Hex("#F472B6");
                case "dsh":      return Hex("#34D399");
                case "files":    return Hex("#22D3EE");
                case "logs":     return Hex("#FBBF24");
                case "tasks":    return Hex("#34D399");
                case "audit":    return Hex("#C084FC");
                case "hosts":    return Hex("#60A5FA");
                default:         return Hex("#94A3B8");
            }
        }
    }

    // ============================================================
    // 图标：24x24 线稿，用 GDI+ 直线/多边形画，不依赖图标字体。
    // 与 PowerShell 版的 Draw-UiIcon 一一对应，保证两版观感一致。
    // ============================================================
    internal static class Icons
    {
        public static void Draw(Graphics g, string name, Rectangle box, Color color, float weight = 1.6f)
        {
            if (string.IsNullOrEmpty(name)) return;
            var old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            float s = Math.Min(box.Width, box.Height) / 24f;
            var state = g.Save();
            g.TranslateTransform(box.X, box.Y);
            g.ScaleTransform(s, s);

            using (var pen = new Pen(color, weight))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                pen.LineJoin = LineJoin.Round;
                switch (name)
                {
                    case "monitor":
                        g.DrawLines(pen, P(22, 12, 18, 12, 15, 21, 9, 3, 6, 12, 2, 12));
                        break;
                    case "store":
                        g.DrawRectangle(pen, 3, 4, 18, 16);
                        g.DrawLine(pen, 12, 8, 12, 15);
                        g.DrawLine(pen, 9, 12, 12, 15);
                        g.DrawLine(pen, 15, 12, 12, 15);
                        break;
                    case "env":
                        g.DrawPolygon(pen, P(12, 2, 21, 7, 21, 17, 12, 22, 3, 17, 3, 7));
                        g.DrawLine(pen, 12, 12, 12, 17);
                        break;
                    case "role":
                        g.DrawPolygon(pen, P(12, 2, 22, 7, 12, 12, 2, 7));
                        g.DrawLines(pen, P(2, 12, 12, 17, 22, 12));
                        g.DrawLines(pen, P(2, 17, 12, 22, 22, 17));
                        break;
                    case "security":
                        g.DrawPolygon(pen, P(12, 2, 20, 5, 20, 12, 12, 22, 4, 12, 4, 5));
                        break;
                    case "app":
                        g.DrawPolygon(pen, P(12, 2, 21, 7, 21, 17, 12, 22, 3, 17, 3, 7));
                        g.DrawLine(pen, 3, 7, 12, 12);
                        g.DrawLine(pen, 21, 7, 12, 12);
                        g.DrawLine(pen, 12, 12, 12, 22);
                        break;
                    case "tool":
                        g.DrawLine(pen, 4, 7, 7, 7);   g.DrawEllipse(pen, 7, 5, 4, 4);   g.DrawLine(pen, 11, 7, 20, 7);
                        g.DrawLine(pen, 4, 12, 13, 12); g.DrawEllipse(pen, 13, 10, 4, 4); g.DrawLine(pen, 17, 12, 20, 12);
                        g.DrawLine(pen, 4, 17, 6, 17);  g.DrawEllipse(pen, 6, 15, 4, 4);  g.DrawLine(pen, 10, 17, 20, 17);
                        break;
                    case "runtime":
                        // 三层堆叠：多版本共存
                        g.DrawPolygon(pen, P(12, 3, 21, 8, 12, 13, 3, 8));
                        g.DrawLines(pen, P(3, 12, 12, 17, 21, 12));
                        g.DrawLines(pen, P(3, 16, 12, 21, 21, 16));
                        break;
                    case "database":
                        // 圆柱：数据库
                        g.DrawEllipse(pen, 4, 3, 16, 5);
                        g.DrawLine(pen, 4, 5.5f, 4, 18.5f);
                        g.DrawLine(pen, 20, 5.5f, 20, 18.5f);
                        g.DrawArc(pen, 4, 16, 16, 5, 0, 180);
                        g.DrawArc(pen, 4, 10, 16, 5, 0, 180);
                        break;
                    case "beauty":
                        g.DrawPolygon(pen, P(12, 2.5, 13.9, 8.1, 19.5, 10, 13.9, 11.9, 12, 17.5, 10.1, 11.9, 4.5, 10, 10.1, 8.1));
                        g.DrawLine(pen, 19f, 16.5f, 19f, 21.5f);
                        g.DrawLine(pen, 16.5f, 19f, 21.5f, 19f);
                        break;
                    case "dsh":
                        g.DrawRectangle(pen, 4, 6, 16, 14);
                        g.DrawRectangle(pen, 9, 11, 6, 6);
                        g.DrawLine(pen, 12, 2, 12, 6);
                        g.DrawLine(pen, 2, 9, 4, 9);
                        g.DrawLine(pen, 2, 15, 4, 15);
                        g.DrawLine(pen, 20, 9, 22, 9);
                        g.DrawLine(pen, 20, 15, 22, 15);
                        g.DrawLine(pen, 9, 20, 9, 22);
                        g.DrawLine(pen, 15, 20, 15, 22);
                        break;
                    case "files":
                        g.DrawLines(pen, P(3, 19, 3, 6, 9, 6, 11, 9, 21, 9, 21, 19, 3, 19));
                        break;
                    case "logs":
                        g.DrawRectangle(pen, 5, 3, 14, 18);
                        g.DrawLine(pen, 8, 8, 16, 8);
                        g.DrawLine(pen, 8, 12, 16, 12);
                        g.DrawLine(pen, 8, 16, 13, 16);
                        break;
                    case "tasks":
                        g.DrawLine(pen, 3, 7, 6, 10);
                        g.DrawLine(pen, 6, 10, 11, 4);
                        g.DrawLine(pen, 3, 17, 6, 20);
                        g.DrawLine(pen, 6, 20, 11, 14);
                        g.DrawLine(pen, 14, 7, 21, 7);
                        g.DrawLine(pen, 14, 17, 21, 17);
                        break;
                    case "audit":
                        g.DrawRectangle(pen, 4, 3, 12, 18);
                        g.DrawEllipse(pen, 13, 13, 8, 8);
                        g.DrawLine(pen, 19, 19, 22, 22);
                        break;
                    case "hosts":
                        g.DrawRectangle(pen, 3, 4, 18, 6);
                        g.DrawRectangle(pen, 3, 14, 18, 6);
                        using (var br = new SolidBrush(color))
                        {
                            g.FillEllipse(br, 6, 6.7f, 1.6f, 1.6f);
                            g.FillEllipse(br, 6, 16.7f, 1.6f, 1.6f);
                        }
                        g.DrawLine(pen, 11, 7.5f, 18, 7.5f);
                        g.DrawLine(pen, 11, 17.5f, 18, 17.5f);
                        break;
                    case "more":
                        g.DrawRectangle(pen, 3, 3, 7, 7);
                        g.DrawRectangle(pen, 14, 3, 7, 7);
                        g.DrawRectangle(pen, 14, 14, 7, 7);
                        g.DrawRectangle(pen, 3, 14, 7, 7);
                        break;
                    case "about":
                        g.DrawEllipse(pen, 3, 3, 18, 18);
                        g.DrawLine(pen, 12, 11, 12, 17);
                        g.DrawLine(pen, 12, 7, 12, 7.5f);
                        break;
                    case "chevron-left":
                        g.DrawLines(pen, P(15, 4, 8, 12, 15, 20));
                        break;
                    case "chevron-right":
                        g.DrawLines(pen, P(9, 4, 16, 12, 9, 20));
                        break;
                    case "search":
                        g.DrawEllipse(pen, 4, 4, 12, 12);
                        g.DrawLine(pen, 15, 15, 21, 21);
                        break;
                    case "refresh":
                        g.DrawArc(pen, 4, 4, 16, 16, 40, 280);
                        g.DrawLines(pen, P(17, 3, 20, 7, 15.5f, 7.5f));
                        break;
                    case "play":
                        g.DrawPolygon(pen, P(8, 5, 19, 12, 8, 19));
                        break;
                    case "stop":
                        g.DrawRectangle(pen, 6, 6, 12, 12);
                        break;
                    default:
                        g.DrawRectangle(pen, 4, 4, 16, 16);
                        break;
                }
            }
            g.Restore(state);
            g.SmoothingMode = old;
        }

        private static PointF[] P(params double[] xy)
        {
            var pts = new PointF[xy.Length / 2];
            for (int i = 0; i < pts.Length; i++)
                pts[i] = new PointF((float)xy[i * 2], (float)xy[i * 2 + 1]);
            return pts;
        }
    }
}

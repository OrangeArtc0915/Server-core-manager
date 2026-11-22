using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 首次启动向导：选这台机器按 2019+ / 2012 R2–2016 / 2008 R2 处理。
    // 探测到的档位高亮成主按钮，回车直接采用；1/2/3 也能选。
    // ============================================================
    internal sealed class FirstRunDialog : Form
    {
        public string Result = "";

        private readonly UiButton _modern;
        private readonly UiButton _legacy;
        private readonly UiButton _old;
        private Point _dragStart;
        private bool _dragging;

        public FirstRunDialog()
        {
            AppSettings.Detect();
            bool detectedModern = AppSettings.DetectedBuild >= AppSettings.ModernBuild;
            bool detectedOld = !detectedModern && AppSettings.DetectedBuild > 0 &&
                               AppSettings.DetectedBuild <= AppSettings.OldBuild;

            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = true;
            BackColor = Theme.Card;
            DoubleBuffered = true;
            KeyPreview = true;
            Width = 720;
            Height = 438;

            _modern = new UiButton("2019 及以上", detectedModern ? ButtonKind.Primary : ButtonKind.Normal, 210, 44);
            _legacy = new UiButton("2012 R2 – 2016", !detectedModern && !detectedOld ? ButtonKind.Primary : ButtonKind.Normal, 210, 44);
            _old = new UiButton("2008 R2", detectedOld ? ButtonKind.Primary : ButtonKind.Normal, 210, 44);

            _modern.Click += (s, e) => { Result = AppSettings.Modern; Close(); };
            _legacy.Click += (s, e) => { Result = AppSettings.Legacy; Close(); };
            _old.Click += (s, e) => { Result = AppSettings.Old; Close(); };

            Controls.Add(_modern);
            Controls.Add(_legacy);
            Controls.Add(_old);

            KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Escape || e.KeyCode == Keys.Enter)
                {
                    e.SuppressKeyPress = true;
                    Result = detectedModern ? AppSettings.Modern : (detectedOld ? AppSettings.Old : AppSettings.Legacy);
                    Close();
                }
                else if (e.KeyCode == Keys.D1) { Result = AppSettings.Modern; Close(); }
                else if (e.KeyCode == Keys.D2) { Result = AppSettings.Legacy; Close(); }
                else if (e.KeyCode == Keys.D3) { Result = AppSettings.Old; Close(); }
            };

            Shown += (s, e) =>
            {
                using (var path = Draw.Round(new Rectangle(0, 0, Width, Height), Theme.RShell))
                    Region = new Region(path);
                int by = Height - 72;
                _modern.Location = new Point(26, by);
                _legacy.Location = new Point(26 + 210 + 12, by);
                _old.Location = new Point(26 + (210 + 12) * 2, by);
                Activate();
                (detectedModern ? _modern : (detectedOld ? _old : _legacy)).Focus();
            };

            Resize += (s, e) =>
            {
                using (var path = Draw.Round(new Rectangle(0, 0, Width, Height), Theme.RShell))
                    Region = new Region(path);
            };

            MouseDown += (s, e) => { _dragging = true; _dragStart = e.Location; };
            MouseMove += (s, e) =>
            {
                if (!_dragging) return;
                Left += e.X - _dragStart.X;
                Top += e.Y - _dragStart.Y;
            };
            MouseUp += (s, e) => _dragging = false;

            Paint += (s, e) =>
            {
                var g = e.Graphics;
                g.SmoothingMode = SmoothingMode.AntiAlias;

                using (var b = new SolidBrush(Theme.Accent))
                    g.FillRectangle(b, 22, 22, 3, 18);
                Draw.Text(g, "首次启动 · 选择系统版本", Theme.Font(11.5f, true), Theme.Text,
                          new Rectangle(34, 16, Width - 60, 30));

                Draw.Text(g, "检测到：" + AppSettings.DetectedName + "（build " + AppSettings.DetectedBuild + "）",
                          Theme.Font(10f, true), Theme.AccentHi,
                          new Rectangle(22, 54, Width - 44, 24));

                Draw.TextBlock(g,
                    "2019 及以上：隐藏与 Windows Admin Center 重复的 8 个页面。\n" +
                    "2012 R2 – 2016：隐藏依赖 App Compatibility FOD 与补全 DLL 的 4 个页面；系统管理页面保留（本地账户改走 net user）。\n" +
                    "2008 R2：同上，且存储页只读；网络 / 防火墙 / 计划任务 / 账户走 netsh / schtasks / net user / WMI 兼容路径。\n" +
                    "选错也没关系：这些都能在「设置」里随时改，不会动数据。",
                    Theme.Font(9.5f), Theme.Sub,
                    new Rectangle(22, 86, Width - 44, 158));

                using (var pen = new Pen(Theme.Border))
                    g.DrawLine(pen, 22, Height - 84, Width - 22, Height - 84);

                Draw.Text(g, "回车 / Esc 采用高亮的默认项 · 1 / 2 / 3 直接选择", Theme.Font(8.5f), Theme.Hint,
                          new Rectangle(22, Height - 106, Width - 44, 18),
                          ContentAlignment.MiddleLeft);
            };
        }

        // 键盘兜底：子控件拿到焦点时 KeyDown 不一定冒泡到窗体
        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape || keyData == Keys.Enter)
            {
                PickDefault();
                return true;
            }
            if (keyData == Keys.D1) { Result = AppSettings.Modern; Close(); return true; }
            if (keyData == Keys.D2) { Result = AppSettings.Legacy; Close(); return true; }
            if (keyData == Keys.D3) { Result = AppSettings.Old; Close(); return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        private void PickDefault()
        {
            AppSettings.Detect();
            if (AppSettings.DetectedBuild >= AppSettings.ModernBuild) Result = AppSettings.Modern;
            else if (AppSettings.DetectedBuild > 0 && AppSettings.DetectedBuild <= AppSettings.OldBuild) Result = AppSettings.Old;
            else Result = AppSettings.Legacy;
            Close();
        }
    }
}

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ScmUi
{
    internal sealed class PromptField
    {
        public string Label;
        public string Value;
        public bool Multiline;
        public string Hint;
        public int Height;      // >0 时覆盖默认高度（多行编辑器用）
        public bool Secret;     // 密码框

        public PromptField(string label, string value = "", bool multiline = false, string hint = "")
        {
            Label = label;
            Value = value ?? "";
            Multiline = multiline;
            Hint = hint;
        }
    }

    // ============================================================
    // 输入 / 确认对话框：无边框 + 圆角 + 深色，和主窗口同一套 token。
    // PowerShell 版靠一串 TextBox 拼对话框；C# 里做成一个可复用的小窗口，
    // 文件操作、主机编辑、商店安装都从这里取参数。
    // ============================================================
    internal sealed class PromptDialog : Form
    {
        public bool Accepted;
        public string[] Values = new string[0];

        private readonly string _title;
        private readonly string _message;
        private readonly int _messageHeight;
        private readonly List<UiInput> _inputs = new List<UiInput>();
        private readonly bool _hasMultiline;
        private Point _dragStart;
        private bool _dragging;

        public PromptDialog(string title, string message, List<PromptField> fields, string okText,
                            int width = 520)
        {
            _title = title ?? "";
            _message = message ?? "";
            Width = Math.Max(360, width);

            if (!string.IsNullOrEmpty(_message))
            {
                var sz = TextRenderer.MeasureText(_message, Theme.Font(9.5f),
                    new Size(Width - 44, 2000), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                _messageHeight = Math.Max(22, sz.Height + 6);
            }

            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            BackColor = Theme.Card;
            DoubleBuffered = true;
            KeyPreview = true;

            int fieldsHeight = 0;
            foreach (var f in fields)
            {
                int h = f.Height > 0 ? f.Height : (f.Multiline ? 76 : 32);
                fieldsHeight += 22 + h + 8 + (string.IsNullOrEmpty(f.Hint) ? 0 : 18) + 8;
                if (f.Multiline) _hasMultiline = true;
            }

            int height = 64 + _messageHeight + fieldsHeight + 54;
            Height = Math.Max(200, height);
            // 顶部留给标题/说明（自己画），body 只占下面这块
            Padding = new Padding(0, 64 + _messageHeight, 0, 0);

            var body = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Card };
            Controls.Add(body);

            int y = 8;
            foreach (var f in fields)
            {
                int boxH = f.Height > 0 ? f.Height : (f.Multiline ? 76 : 32);
                var label = new Label
                {
                    Text = f.Label,
                    AutoSize = true,
                    ForeColor = Theme.Hint,
                    BackColor = Theme.Card,
                    Font = Theme.Font(9f),
                    Location = new Point(22, y)
                };
                body.Controls.Add(label);
                y += 22;

                var input = new UiInput(Width - 44, "", boxH, f.Multiline) { Location = new Point(22, y) };
                input.ValueText = f.Value;
                if (f.Secret) input.Box.UseSystemPasswordChar = true;
                _inputs.Add(input);
                body.Controls.Add(input);
                y += boxH + 8;

                if (!string.IsNullOrEmpty(f.Hint))
                {
                    var hint = new Label
                    {
                        Text = f.Hint,
                        AutoSize = true,
                        ForeColor = Theme.Disabled,
                        BackColor = Theme.Card,
                        Font = Theme.Font(8.25f),
                        Location = new Point(22, y)
                    };
                    body.Controls.Add(hint);
                    y += 18;
                }
                y += 8;
            }

            var cancel = new UiButton("取消", ButtonKind.Normal, 88, 34);
            cancel.Click += (s, e) => { Accepted = false; Close(); };
            var ok = new UiButton(okText, ButtonKind.Primary, 96, 34);
            ok.Click += (s, e) => Accept();
            body.Controls.Add(cancel);
            body.Controls.Add(ok);

            AcceptButton = null;
            CancelButton = null;
            KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Escape) { Accepted = false; Close(); }
                else if (e.KeyCode == Keys.Enter && !e.Shift && !_hasMultiline)
                {
                    e.SuppressKeyPress = true;
                    Accept();
                }
            };

            Shown += (s, e) =>
            {
                cancel.Location = new Point(body.Width - 22 - cancel.Width - 8 - ok.Width, body.Height - 46);
                ok.Location = new Point(body.Width - 22 - ok.Width, body.Height - 46);
                using (var path = Draw.Round(new Rectangle(0, 0, Width, Height), Theme.RShell))
                    Region = new Region(path);
                if (_inputs.Count > 0) _inputs[0].Box.Focus();
            };
            Resize += (s, e) =>
            {
                using (var path = Draw.Round(new Rectangle(0, 0, Width, Height), Theme.RShell))
                    Region = new Region(path);
            };

            MouseDown += (s, e) => { if (e.Y < 56) { _dragging = true; _dragStart = e.Location; } };
            MouseMove += (s, e) =>
            {
                if (!_dragging) return;
                Left += e.X - _dragStart.X;
                Top += e.Y - _dragStart.Y;
            };
            MouseUp += (s, e) => _dragging = false;
            // 顶部说明区被 body 挡住时也能拖
            body.MouseDown += (s, e) => { _dragging = true; _dragStart = e.Location; };
            body.MouseMove += (s, e) =>
            {
                if (!_dragging) return;
                Left += e.X - _dragStart.X;
                Top += e.Y - _dragStart.Y;
            };
            body.MouseUp += (s, e) => _dragging = false;
            Paint += (s, e) =>
            {
                var g = e.Graphics;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (var pen = new Pen(Theme.Border))
                    g.DrawLine(pen, 0, 55, Width, 55);
                using (var b = new SolidBrush(Theme.Accent))
                    g.FillRectangle(b, 22, 20, 3, 16);
                Draw.Text(g, _title, Theme.Font(10.5f, true), Theme.Text,
                          new Rectangle(34, 14, Width - 60, 28));
                if (!string.IsNullOrEmpty(_message))
                    Draw.TextBlock(g, _message, Theme.Font(9.5f), Theme.Sub,
                                   new Rectangle(22, 62, Width - 44, _messageHeight));
            };
        }

        private void Accept()
        {
            var values = new string[_inputs.Count];
            for (int i = 0; i < _inputs.Count; i++) values[i] = _inputs[i].ValueText;
            Values = values;
            Accepted = true;
            Close();
        }
    }

    // ------------------------------------------------------------ 通知收件箱
    internal sealed class NoticeDialog : Form
    {
        public string Action = "";   // "" / readAll / clear

        private Point _dragStart;
        private bool _dragging;

        public NoticeDialog(string title, List<string> lines, int unread)
        {
            Text = title;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            BackColor = Theme.Card;
            DoubleBuffered = true;
            Width = 620;
            Height = 460;

            var list = new ListBox
            {
                Location = new Point(18, 62),
                Size = new Size(Width - 36, Height - 62 - 58),
                BorderStyle = BorderStyle.None,
                BackColor = Theme.Sunken,
                ForeColor = Theme.Sub,
                Font = Theme.Font(9.5f),
                IntegralHeight = false
            };
            foreach (var l in lines) list.Items.Add(l);
            Controls.Add(list);

            var readAll = new UiButton("全部标为已读", ButtonKind.Normal, 124, 34)
            {
                Location = new Point(18, Height - 46)
            };
            readAll.Click += (s, e) => { Action = "readAll"; Close(); };
            var clear = new UiButton("清空", ButtonKind.Danger, 88, 34)
            {
                Location = new Point(150, Height - 46)
            };
            clear.Click += (s, e) => { Action = "clear"; Close(); };
            var close = new UiButton("关闭", ButtonKind.Primary, 88, 34)
            {
                Location = new Point(Width - 18 - 88, Height - 46)
            };
            close.Click += (s, e) => Close();
            Controls.Add(readAll);
            Controls.Add(clear);
            Controls.Add(close);

            Shown += (s, e) =>
            {
                using (var path = Draw.Round(new Rectangle(0, 0, Width, Height), Theme.RShell))
                    Region = new Region(path);
            };
            MouseDown += (s, e) => { if (e.Y < 56) { _dragging = true; _dragStart = e.Location; } };
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
                using (var pen = new Pen(Theme.Border))
                    g.DrawLine(pen, 0, 55, Width, 55);
                using (var b = new SolidBrush(Theme.Accent))
                    g.FillRectangle(b, 18, 20, 3, 16);
                Draw.Text(g, title, Theme.Font(10.5f, true), Theme.Text,
                          new Rectangle(30, 14, Width - 120, 28));
                Draw.Text(g, "未读 " + unread, Theme.Font(9f), Theme.Hint,
                          new Rectangle(Width - 110, 16, 92, 24),
                          ContentAlignment.MiddleRight);
            };
            KeyDown += (s, e) => { if (e.KeyCode == Keys.Escape) Close(); };
        }
    }

    // ------------------------------------------------------------ 只读详情窗
    // 日志 / 任务 / 审计的「查看整条内容」都用它：C# 版最早只把详情打到运行日志，
    // 长消息在 5 行日志栏里根本看不全。
    internal sealed class TextDialog : Form
    {
        public string Action = "";   // "" / copy / open

        private Point _dragStart;
        private bool _dragging;

        public TextDialog(string title, string subtitle, string text, string openPath)
        {
            Text = title;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            BackColor = Theme.Card;
            DoubleBuffered = true;
            Width = 760;
            Height = 540;

            var box = new TextBox
            {
                Location = new Point(18, 78),
                Size = new Size(Width - 36, Height - 78 - 60),
                Multiline = true,
                ReadOnly = true,
                WordWrap = true,
                ScrollBars = ScrollBars.Vertical,
                BorderStyle = BorderStyle.None,
                BackColor = Theme.Sunken,
                ForeColor = Theme.Sub,
                Font = Theme.Mono(9.5f)
            };
            if (!string.IsNullOrEmpty(text)) box.Text = text;
            Controls.Add(box);

            var copy = new UiButton("复制内容", ButtonKind.Normal, 100, 34)
            {
                Location = new Point(18, Height - 46)
            };
            copy.Click += (s, e) =>
            {
                try { Clipboard.SetText(box.Text); } catch { }
                Action = "copy";
                Close();
            };
            Controls.Add(copy);

            if (!string.IsNullOrEmpty(openPath))
            {
                var open = new UiButton("打开文件", ButtonKind.Normal, 100, 34)
                {
                    Location = new Point(126, Height - 46)
                };
                open.Click += (s, e) =>
                {
                    Action = "open";
                    Close();
                };
                Controls.Add(open);
            }

            var close = new UiButton("关闭", ButtonKind.Primary, 88, 34)
            {
                Location = new Point(Width - 18 - 88, Height - 46)
            };
            close.Click += (s, e) => Close();
            Controls.Add(close);

            Shown += (s, e) =>
            {
                using (var path = Draw.Round(new Rectangle(0, 0, Width, Height), Theme.RShell))
                    Region = new Region(path);
            };
            MouseDown += (s, e) => { if (e.Y < 56) { _dragging = true; _dragStart = e.Location; } };
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
                using (var pen = new Pen(Theme.Border))
                    g.DrawLine(pen, 0, 55, Width, 55);
                using (var b = new SolidBrush(Theme.Accent))
                    g.FillRectangle(b, 18, 20, 3, 16);
                Draw.Text(g, title, Theme.Font(10.5f, true), Theme.Text,
                          new Rectangle(30, 14, Width - 60, 28));
                if (!string.IsNullOrEmpty(subtitle))
                    Draw.Text(g, subtitle, Theme.Font(8.75f), Theme.Hint,
                              new Rectangle(18, 54 + 2, Width - 36, 20));
            };
            KeyDown += (s, e) => { if (e.KeyCode == Keys.Escape) Close(); };
        }
    }

    internal static class Dialogs
    {
        // 返回 null 表示取消
        public static string[] Prompt(IWin32Window owner, string title, string message,
                                      List<PromptField> fields, string okText = "确定",
                                      int width = 520)
        {
            using (var dlg = new PromptDialog(title, message, fields, okText, width))
            {
                dlg.ShowDialog(owner);
                return dlg.Accepted ? dlg.Values : null;
            }
        }

        public static bool Confirm(IWin32Window owner, string title, string message,
                                   string okText = "确定")
        {
            using (var dlg = new PromptDialog(title, message, new List<PromptField>(), okText))
            {
                dlg.ShowDialog(owner);
                return dlg.Accepted;
            }
        }

        // 返回 ""（只关闭）/ copy / open
        public static string Text(IWin32Window owner, string title, string subtitle, string text,
                                  string openPath = null)
        {
            using (var dlg = new TextDialog(title, subtitle, text, openPath))
            {
                dlg.ShowDialog(owner);
                return dlg.Action;
            }
        }

        // 返回 ""（只关闭）/ readAll / clear
        public static string Notice(IWin32Window owner, string title, List<string> lines, int unread)
        {
            using (var dlg = new NoticeDialog(title, lines, unread))
            {
                dlg.ShowDialog(owner);
                return dlg.Action;
            }
        }
    }
}

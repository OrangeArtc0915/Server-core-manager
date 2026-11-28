using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace ScmUi
{
    // ============================================================
    // 设置页：版本档位 + 两个显示开关 + 程序自更新。
    // 内容放在可滚动面板里：矮窗口（1024×700 / 日志栏展开）下也不会被裁掉。
    // 改完立即写入 state\ui-settings.json，并让 Shell 重建侧栏。
    // ============================================================
    internal sealed class SettingsPage : PageBase
    {
        private Panel _scroll;
        private SurfaceCard _card, _updCard;

        private Label _detected, _tierNow, _hideWacHint, _setTitle;
        private UiButton _tierAuto, _tierModern, _tierLegacy, _tierOld, _rerun;
        private UiCheck _hideWac, _hideLegacy;

        private Label _updVer, _updStatus, _updTitle;
        private UiButton _updCheck, _updInstall, _updPage;
        private UiButton _srcAuto, _srcGithub, _srcGitee;
        private UiCheck _updStartup;
        private string _availTag = "";
        private string _availSource = "";

        public SettingsPage()
        {
            Key = "settings";
            TitleText = "设置";
            Subtitle = "版本策略、界面显示与程序更新；改完立即生效";
            Glyph = "tool";
            Accent = Theme.AccentHi;
        }

        protected override void BuildContent()
        {
            _scroll = new Panel { BackColor = Theme.Bg, AutoScroll = true };
            Controls.Add(_scroll);

            _card = new SurfaceCard { HoverGlow = false };
            _updCard = new SurfaceCard { HoverGlow = false };
            _scroll.Controls.Add(_card);
            _scroll.Controls.Add(_updCard);

            // ---------------- 版本与显示 ----------------
            _setTitle = TitleLabel("版本与显示");
            _detected = NewLabel("", 9.5f, Theme.Sub);
            _tierNow = NewLabel("", 9f, Theme.Hint);
            _hideWacHint = NewLabel("", 8.5f, Theme.Hint);

            _tierAuto = new UiButton("自动识别", ButtonKind.Normal, 132, 32);
            _tierModern = new UiButton("2019 及以上", ButtonKind.Normal, 132, 32);
            _tierLegacy = new UiButton("2012 R2 – 2016", ButtonKind.Normal, 132, 32);
            _tierOld = new UiButton("2008 R2", ButtonKind.Normal, 132, 32);
            _tierAuto.Click += (s, e) => SetTier(AppSettings.Auto);
            _tierModern.Click += (s, e) => SetTier(AppSettings.Modern);
            _tierLegacy.Click += (s, e) => SetTier(AppSettings.Legacy);
            _tierOld.Click += (s, e) => SetTier(AppSettings.Old);

            _hideWac = new UiCheck("隐藏与 Windows Admin Center 重复的功能");
            _hideWac.Click += (s, e) => Apply();

            _hideLegacy = new UiCheck("隐藏当前系统无法使用的功能（FOD / 补全 DLL / WAC）");
            _hideLegacy.Click += (s, e) => Apply();

            _rerun = new UiButton("重新运行首次向导", ButtonKind.Normal, 158, 32);
            _rerun.Click += (s, e) =>
            {
                using (var dlg = new FirstRunDialog())
                {
                    dlg.ShowDialog(FindForm());
                    if (!string.IsNullOrEmpty(dlg.Result))
                    {
                        AppSettings.Tier = dlg.Result;
                        AppSettings.HideWacDuplicates = AppSettings.IsModern;
                        AppSettings.FirstRunDone = true;
                        Apply();
                        Log("[INFO] 版本档位改为：" + (AppSettings.IsModern ? "2019 及以上" : "2019 及以下"));
                    }
                }
            };

            _card.Controls.Add(_setTitle);
            _card.Controls.Add(_detected);
            _card.Controls.Add(_tierNow);
            _card.Controls.Add(_hideWacHint);
            _card.Controls.Add(_tierAuto);
            _card.Controls.Add(_tierModern);
            _card.Controls.Add(_tierLegacy);
            _card.Controls.Add(_tierOld);
            _card.Controls.Add(_hideWac);
            _card.Controls.Add(_hideLegacy);
            _card.Controls.Add(_rerun);

            // ---------------- 程序更新 ----------------
            _updTitle = TitleLabel("程序更新");
            _updVer = NewLabel("", 9.5f, Theme.Sub);
            _updStatus = NewLabel("", 8.75f, Theme.Hint);
            _updStatus.AutoSize = false;

            _srcAuto = new UiButton("自动", ButtonKind.Normal, 88, 28);
            _srcGithub = new UiButton("GitHub", ButtonKind.Normal, 88, 28);
            _srcGitee = new UiButton("Gitee", ButtonKind.Normal, 88, 28);
            _srcAuto.Click += (s, e) => SetSource("auto");
            _srcGithub.Click += (s, e) => SetSource("github");
            _srcGitee.Click += (s, e) => SetSource("gitee");

            _updStartup = new UiCheck("启动时检查更新（24 小时内不重复）");
            _updStartup.Click += (s, e) =>
            {
                AppSettings.UpdateCheckOnStartup = _updStartup.Checked;
                AppSettings.Save();
            };

            _updCheck = new UiButton("检查更新", ButtonKind.Primary, 112, 32);
            _updCheck.Click += (s, e) => CheckNow();

            _updInstall = new UiButton("立即更新", ButtonKind.Primary, 132, 32) { Visible = false };
            _updInstall.Click += (s, e) =>
            {
                if (_availTag.Length == 0) return;
                SelfUpdate.InstallUpdate(this, _availTag, _availSource);
            };

            _updPage = new UiButton("打开发布页", ButtonKind.Normal, 112, 32);
            _updPage.Click += (s, e) =>
            {
                string url = AppSettings.UpdateSource == "gitee"
                    ? "https://gitee.com/orangearc655743/server-core-manager/releases"
                    : "https://github.com/Server-Core-Mananger/Server-core-manager/releases";
                try { Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); } catch { }
            };

            _updCard.Controls.Add(_updTitle);
            _updCard.Controls.Add(_updVer);
            _updCard.Controls.Add(_updStatus);
            _updCard.Controls.Add(_srcAuto);
            _updCard.Controls.Add(_srcGithub);
            _updCard.Controls.Add(_srcGitee);
            _updCard.Controls.Add(_updStartup);
            _updCard.Controls.Add(_updCheck);
            _updCard.Controls.Add(_updInstall);
            _updCard.Controls.Add(_updPage);
        }

        private static Label NewLabel(string text, float size, Color fore)
        {
            return new Label
            {
                Text = text,
                AutoSize = false,
                BackColor = Theme.Card,
                ForeColor = fore,
                Font = Theme.Font(size),
                TextAlign = ContentAlignment.MiddleLeft
            };
        }

        private static Label TitleLabel(string text)
        {
            return new Label
            {
                Text = text,
                AutoSize = false,
                BackColor = Theme.Card,
                ForeColor = Theme.Text,
                Font = Theme.Font(10.5f, true),
                TextAlign = ContentAlignment.MiddleLeft
            };
        }

        protected override void OnActivated()
        {
            AppSettings.Detect();
            RefreshState();
        }

        private void SetTier(string tier)
        {
            AppSettings.Tier = tier;
            // 换档位时把「隐藏 WAC 重复」回到该档位的默认值：2019+ 开、2019- 关
            _hideWac.Checked = AppSettings.IsModern;
            AppSettings.HideWacDuplicates = _hideWac.Checked;
            Apply();
            Log("[INFO] 版本档位改为：" + (tier == AppSettings.Auto ? "自动识别" :
                (tier == AppSettings.Modern ? "2019 及以上" :
                 (tier == AppSettings.Old ? "2008 R2" : "2012 R2 – 2016"))));
        }

        private void SetSource(string source)
        {
            AppSettings.UpdateSource = source;
            AppSettings.Save();
            RefreshState();
            Log("[INFO] 更新线路改为：" + SourceLabel(source));
        }

        private void Apply()
        {
            AppSettings.HideWacDuplicates = _hideWac.Checked;
            AppSettings.HideUnsupported = _hideLegacy.Checked;
            AppSettings.FirstRunDone = true;
            AppSettings.Save();
            RefreshState();

            var shell = FindForm() as Shell;
            if (shell != null) shell.RebuildNav();
        }

        private void CheckNow()
        {
            _updStatus.Text = "正在检查更新…";
            _updCheck.Kind = ButtonKind.Normal;
            _updCheck.Invalidate();
            SelfUpdate.CheckManual(this, d =>
            {
                bool available = Bridge.Bool(d, "Available");
                string latest = Bridge.Str(d, "Latest");
                string source = Bridge.Str(d, "Source");

                _availTag = available ? Bridge.Str(d, "Tag") : "";
                _availSource = available ? source : "";

                if (available)
                {
                    _updStatus.Text = "发现新版本 " + latest + "（" + SourceLabel(source) + "），可以立即更新。";
                    _updInstall.Text = "立即更新到 " + latest;
                    _updInstall.Visible = true;
                }
                else
                {
                    _updStatus.Text = "已是最新版本（" + SelfUpdate.CurrentVersion + "）。";
                    _updInstall.Visible = false;
                }

                _updCheck.Kind = ButtonKind.Primary;
                _updCheck.Invalidate();
                RefreshState();
            });
        }

        private static string SourceLabel(string source)
        {
            if (source == "gitee") return "Gitee";
            if (source == "github") return "GitHub";
            return "自动";
        }

        private void RefreshState()
        {
            _detected.Text = "检测到 " + AppSettings.DetectedName + "　build " + AppSettings.DetectedBuild;
            _tierNow.Text = "当前策略：" + AppSettings.TierText +
                            "　·　页面过滤按 " + (AppSettings.IsModern ? "2019+" : (AppSettings.IsOld ? "2008 R2" : "2012–2016")) + " 执行";

            _tierAuto.Kind = AppSettings.Tier == AppSettings.Auto ? ButtonKind.Primary : ButtonKind.Normal;
            _tierModern.Kind = AppSettings.Tier == AppSettings.Modern ? ButtonKind.Primary : ButtonKind.Normal;
            _tierLegacy.Kind = AppSettings.Tier == AppSettings.Legacy ? ButtonKind.Primary : ButtonKind.Normal;
            _tierOld.Kind = AppSettings.Tier == AppSettings.Old ? ButtonKind.Primary : ButtonKind.Normal;

            _hideWac.Checked = AppSettings.HideWacDuplicates;
            _hideLegacy.Checked = AppSettings.HideUnsupported;
            _hideWacHint.Text = AppSettings.IsModern
                ? "当前按 2019+ 处理：开启后隐藏系统更新 / 网络 / 账户 / 服务 / 防火墙 / 存储 / 计划任务 / 事件日志。"
                : "当前按 2019- 处理：没有 WAC 可装，这个开关不生效。";

            _updVer.Text = "当前 " + SelfUpdate.CurrentVersion +
                           "　·　最近检查 " + (string.IsNullOrEmpty(AppSettings.LastUpdateCheck) ? "未检查" : AppSettings.LastUpdateCheck) +
                           "　·　线路 " + SourceLabel(AppSettings.UpdateSource);
            _updStartup.Checked = AppSettings.UpdateCheckOnStartup;

            _srcAuto.Kind = AppSettings.UpdateSource == "auto" ? ButtonKind.Primary : ButtonKind.Normal;
            _srcGithub.Kind = AppSettings.UpdateSource == "github" ? ButtonKind.Primary : ButtonKind.Normal;
            _srcGitee.Kind = AppSettings.UpdateSource == "gitee" ? ButtonKind.Primary : ButtonKind.Normal;

            foreach (var c in new Control[] { _tierAuto, _tierModern, _tierLegacy, _tierOld, _hideWac, _hideLegacy,
                                              _srcAuto, _srcGithub, _srcGitee, _updStartup })
                c.Invalidate();
        }

        protected override void OnLayout()
        {
            int w = Math.Max(300, ClientSize.Width);
            int bodyH = Math.Max(120, ClientSize.Height - 76);

            _scroll.SetBounds(0, 76, w, bodyH);
            int cardW = Math.Max(280, _scroll.ClientSize.Width - 22);

            int pad = 22;
            int cw = cardW - pad * 2;

            _updCard.SetBounds(0, 0, cardW, 252);
            _updTitle.SetBounds(pad, 12, cw, 24);
            _updVer.SetBounds(pad, 40, cw, 24);
            _srcAuto.Location = new Point(pad, 68);
            _srcGithub.Location = new Point(pad + 96, 68);
            _srcGitee.Location = new Point(pad + 192, 68);
            _updStartup.SetBounds(pad, 104, cw, 26);
            _updCheck.Location = new Point(pad, 136);
            _updInstall.Location = new Point(pad + 122, 136);
            _updPage.Location = new Point(pad + 262, 136);
            _updStatus.SetBounds(pad, 180, cw, 44);

            // 版本与显示策略放在下面：设置一次就很少动，更新入口放最上面更好找
            _card.SetBounds(0, 264, cardW, 330);
            _setTitle.SetBounds(pad, 12, cw, 24);
            _detected.SetBounds(pad, 40, cw, 24);
            _tierNow.SetBounds(pad, 142, cw, 22);

            int bw = 132;
            int gap = 8;
            int bx = pad;
            _tierAuto.Location = new Point(bx, 68);
            bx += bw + gap;
            _tierModern.Location = new Point(bx, 68);
            bx += bw + gap;
            _tierLegacy.Location = new Point(bx, 68);
            bx += bw + gap;
            _tierOld.Location = new Point(bx, 68);

            _hideWac.SetBounds(pad, 170, cw, 26);
            _hideWacHint.SetBounds(pad + 26, 196, cw - 26, 20);
            _hideLegacy.SetBounds(pad, 224, cw, 26);
            _rerun.Location = new Point(pad, 264);
        }
    }
}

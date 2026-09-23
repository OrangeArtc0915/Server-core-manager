**让带图形界面的程序，在 Windows Server Core 上真正跑起来。**

Windows Server Core 没有桌面、没有 `explorer.exe`、没有 `dwm.exe`。这个工具把「补全图形环境 → 添加程序 → 启动并排障」做成一键操作，而且它自己也带图形界面 —— 装完就能用鼠标点，不用记命令。

::github{repo="OrangeArtc0915/Server-core-manager"}

## 它解决什么问题

Server Core 里想跑一个带界面的程序，正常流程要跨好几个工具、好几轮重启，而且中间到处是「看着能行其实不行」的说法。这个工具把整条链路固化成 29 个动作：

- **环境页**七张状态卡片，一眼看出这台机器缺什么（系统版本、图形组件、渲染管线、.NET 运行时、登录会话、UAC、Web 管理）
- **一键补全**装微软官方的 App Compatibility FOD —— 需要重启，工具会记住进度，重启后接着跑
- **软件页**添加你的程序，按 PE 头判定它是 .NET / Electron / WPF / 原生，自动带入实测推荐参数
- **启动诊断**在程序起不来时查事件日志、WER 记录、缺失的 DLL 与运行时，给出处置建议
- **终端美化**把系统自带的 conhost 美化好（Nerd Font + oh-my-posh + fastfetch），全程离线、可一键还原

## 几个设计取舍

- **只依赖系统自带的 PowerShell 5.1**，不要求先装 .NET 或 PowerShell 7；需要 PS 7 时工具自己装
- **所有需要写操作的重活都走 SYSTEM 计划任务**，因为 WinRM 网络令牌下 DISM 写操作会被拒绝访问
- **下载优先国内源**，一行安装有 Gitee 与 GitHub 两条线路，自动挑能通的
- **每次改动都在真机上验证**，界面自带 `-SelfTest` 与 `-LayoutDump` 诊断开关

> [!IMPORTANT]
> 本站所有数字与结论都来自真机实测，并且尽量附上复现方式。如果哪一条你复现不出来，那就是 Bug，欢迎到 [Issues](https://github.com/OrangeArtc0915/Server-core-manager/issues) 说。

## 做不到的事

补齐 FOD 之后，23 个桌面体验专属组件里仍会缺 4 个。下面这些限制由 Server Core 环境本身决定，不是工具的问题，也不打算含糊过去。

| 限制 | 原因 |
|---|---|
| UWP 和 XAML 应用不行 | 缺 `twinui.dll`，这类程序起不来 |
| 界面是经典主题样式 | 缺 `themeservice.dll` 与 `themeui.dll`，窗口不会应用现代主题；缺 `DispBroker.dll` 也限制了一部分显示能力 |
| 不是远程桌面方案的替代品 | 本工具是在 Server Core **本机**补齐图形能力，程序在本机渲染；想把无头机器上的画面通过网络传输，属于另一个方向 |
| Electron 程序用不上 GPU 加速 | 只能走软件渲染，所以建议带上禁用 GPU 的参数 |
| FOD 下载对网络敏感 | 从 Windows Update 拉取，体积较大且可能失败；工具内置常见错误码的中文处置建议，也支持用 FOD ISO 走本地源 |
| 没有可用的 Windows Terminal | 实测 MSIX 包装不上，即使想办法装上也无法启动；所以改成美化系统自带的 conhost |

## 获取与支持

- 一行安装（国内推荐）：`irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex`
- 源码：[GitHub](https://github.com/OrangeArtc0915/Server-core-manager) ｜ **Gitee 上没有源码**，只放了下面两个文件
- 国内下载（Gitee）：[发布包](https://gitee.com/orangearc655743/server-core-manager/releases) ｜ [安装脚本 install.ps1](https://gitee.com/orangearc655743/server-core-manager/blob/main/install.ps1)
- 作者 **mmm** ｜ QQ 群 **1034243331**
- 想支持这个项目 → [赞助作者](../support/)（完全自愿，不影响功能与修 Bug 的顺序）
- 许可证 **GPL-3.0**

---

*本站使用 [Astro](https://astro.build) 与 [Mizuki](https://github.com/matsuzaka-yuki/Mizuki) 主题构建（MIT）。*

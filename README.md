# Server Core Manager

**让带图形界面的程序，在 Windows Server Core 上真正跑起来。**

Windows Server Core 没有桌面、没有 `explorer.exe`、没有 `dwm.exe`，很多带界面的程序（QQ、各类 Electron 应用、WPF 工具、.NET 桌面程序、MMC 管理单元）装上去不是报错就是白屏。这个工具把「补全图形环境 → 添加程序 → 启动并排障」这条链路做成了一键操作，并且带一个自己的图形界面 —— 不用整天对着终端敲命令。

```
支持的安装方式：① 命令行一行安装   ② 压缩包
```

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [核心原理](#核心原理)
- [功能一览](#功能一览)
- [安装方式一：命令行一行安装](#安装方式一命令行一行安装)
- [安装方式二：压缩包](#安装方式二压缩包)
- [快速上手](#快速上手)
- [实测数据](#实测数据)
- [系统要求](#系统要求)
- [已知限制](#已知限制)
- [常见问题](#常见问题)
- [目录结构](#目录结构)
- [卸载](#卸载)
- [许可证](#许可证)

---

## 它解决什么问题

在 Server Core 上跑图形程序，社区里流传的做法经常是错的。这个项目的所有结论都来自真机实测（Hyper-V + Windows Server 2022 Core），并且把踩到的坑固化进了代码：

| 流传的说法 | 实测结论 |
|---|---|
| 「装 `Server-Gui-Shell` 功能就能恢复桌面」 | **该功能在 Server Core 上根本不存在**，`Install-WindowsFeature` 会直接报找不到 |
| 「Server Core 不可能跑图形程序」 | **可以**。装官方 **App Compatibility FOD** 并重启后，WinForms / WPF / Electron 都能正常渲染 |
| 「远程 PowerShell 里直接 DISM 装 FOD 就行」 | 走 WinRM 网络令牌时 **DISM 写操作会被拒绝访问**，工具会自动改用 SYSTEM 计划任务执行 |
| 「Windows Admin Center 装完就能用」 | v2 安装过程 **会重启 WinRM**，远程会话会被切断；且**服务装完是 Stopped**，需要手动收尾启动 |
| 「Electron 程序在 Server Core 上就是这么慢」 | 加 `--disable-gpu --disable-software-rasterizer` 后，实测**快 3 倍、CPU 降 85%** |

---

## 核心原理

**唯一官方路线：App Compatibility Feature on Demand（FOD）**

```
Add-WindowsCapability -Online -Name ServerCore.AppCompatibility~~~~0.0.1.0
→ 重启
→ dwm.exe / dcomp.dll / dwrite.dll 就位
→ 图形程序可以渲染
```

工具会装的是 `ServerCore.AppCompatibility` 这个按需功能包。实测补齐后新增 15 个关键组件，包括：

`dwm.exe`、`dcomp.dll`、`uDWM.dll`、`dwmcore.dll`、`dwmredir.dll`、`d3d10warp.dll`、`UIAnimation.dll`、`wuceffects.dll`、`mmc.exe`、`explorer.exe`、`eventvwr.exe`、`perfmon.exe`、`resmon.exe` …

组件按三组共跟踪 51 项：核心基线 21、FOD 提供 7、**桌面体验专属 23**。补齐后，「桌面体验专属」这 23 个里**仍会缺 4 个**（`twinui.dll`、`themeservice.dll`、`themeui.dll`、`DispBroker.dll`），这正是下面「已知限制」里那些场景不能用的原因。

---

## 功能一览

### 图形界面（4 个页面 + 7 张状态卡片）

| 页面 | 内容 |
|---|---|
| **环境** | 7 张状态卡片（系统版本 / 图形组件 / 渲染管线 / .NET 运行时 / 登录会话 / 提权 UAC / Web 管理）+ 一键补全、重新探测、GUI 自检、结论路线、自动登录、Windows Admin Center |
| **软件** | 添加程序、启动、设置启动参数、后台常驻、启动诊断、查看兼容档案、移除 |
| **工具** | **20 个系统工具入口**，按当前系统实际有没有自动灰显：记事本、文件资源管理器、命令提示符、PowerShell、任务管理器、MMC 控制台、服务、设备管理器、磁盘管理、任务计划程序、本地用户和组、证书管理、防火墙高级安全、注册表编辑器、事件查看器、性能监视器、资源监视器、系统信息、Hyper-V 管理器、PowerShell ISE |
| **更多** | 全部 **32 个功能**，分 7 组：一键流程 / 探测与诊断 / 程序档案 / 补给 / 会话与登录 / 使用与工具 / Windows Admin Center |

### 32 个功能动作

- **一键流程（5）**：一键补全环境、断点续跑、流程状态、修复 RDP、结论路线
- **探测与诊断（5）**：环境探测、GUI 能力自检、PE 静态预检、程序启动诊断、排障采集
- **程序档案（3）**：兼容档案查询、实测参数、程序列表
- **补给（4）**：安装 App Compatibility FOD、.NET 运行时 zip 免安装补齐、补 .NET 桌面运行时、查看已装框架
- **会话与登录（8）**：自动登录（启用/关闭/状态）、会话列表、登录 Shell 设置、持久化启动、RDP 修复 …
- **使用与工具（3）**：图形启动器、阶段 B 指引、日志与报告
- **Windows Admin Center（4）**：状态检查、一键安装并自动配置、服务控制、打开界面

### Windows Admin Center 一键安装

- 本地没有安装包时，**自动从官方地址下载**（`aka.ms/WACDownload`，约 140 MB），可用 `-NoDownload` 关闭以适配离线/内网
- 自动识别两代安装包并分派参数：经典 MSI 用 `msiexec` + `SME_*`，v2 用 Inno Setup 的 `/VERYSILENT`
- 装完**自动放行防火墙、设为自启、启动服务，并探测 `/shell/` 是否可达**，最后输出浏览器访问地址
- 全程通过 SYSTEM 计划任务执行，以规避 v2 安装包重启 WinRM 导致的会话中断

### 程序兼容档案（`lib/catalog.json`）

每个条目都带**实测证据**，不是拍脑袋写的：

```json
{
  "id": "qq-nt",
  "name": "腾讯 QQ NT（Electron 版）",
  "verdict": "可用（建议参数）",
  "launchArgs": "--disable-gpu --disable-software-rasterizer",
  "verifiedOn": "20348.2700",
  "evidence": "实测 A/B：默认参数首窗口 18.2s / CPU 30.5s；加参数后 6.0s / CPU 4.6s"
}
```

添加程序时，工具会读 PE 头判断它是 .NET / Electron / WPF / 原生，再**自动带入实测推荐参数**。

---

## 安装方式一：命令行一行安装

在**管理员** PowerShell 里执行：

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

它会：下载最新发布包 → 解压到 `C:\Program Files\ServerCoreManager` → 解除「来自 Internet」的文件锁定 → 安装 `scm` 一行命令。

装完之后，**在任意目录输入 `scm` 回车**就能打开图形界面（首次会像 `sconfig` 一样弹一次提权确认）。

需要改默认值时用环境变量（因为 `iex` 没法传参数）：

```powershell
$env:SCM_DEST = 'D:\SCM'      # 改安装目录
$env:SCM_NO_COMMAND = '1'     # 不装 scm 命令
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

也可以先把 [install.ps1](install.ps1) 存成文件，再当普通脚本跑，这样能直接传参：

```powershell
.\install.ps1 -Dest 'D:\SCM' -NoCommand
```

> **重复执行等于升级**：只覆盖程序文件，不会动你已有的程序列表（`launcher\programs.json`）、日志和断点状态。

---

## 安装方式二：压缩包

1. 到 [Releases](https://github.com/OrangeArtc0915/Server-core-manager/releases) 下载 `ServerCoreManager.zip`
2. 解压到任意目录，例如 `D:\ServerCoreManager`
3. 右键 **以管理员身份运行** `一键运行.bat`

### 压缩包内容

```
ServerCoreManager.zip
├─ 一键运行.bat              ← 双击入口，自动提权后打开图形界面
├─ 打开命令行菜单.bat        ← 喜欢命令行的话走这个（15 项两级菜单）
├─ 安装一行命令.bat          ← 把 scm 装进 PATH
├─ Start-GuiReadyApp.ps1     ← 统一入口（默认 GUI，-Console 走菜单）
├─ Start-GuiReady.ps1        ← 命令行菜单
├─ Install-GuiReadyCommand.ps1
├─ Resume-GuiReadyPipeline.ps1
├─ install.ps1 / pack.ps1 / LICENSE / README*
├─ gui\    ← 图形界面（GuiReady.GuiApp.ps1 主界面 + 动作清单 + 动作执行器）
├─ lib\    ← 全部能力模块（16 个）+ catalog.json 兼容档案
└─ launcher\ ← RDP 会话用的轻量面板（可作为登录 Shell 替代 explorer.exe）
```

> 解压后如果 PowerShell 拒绝执行脚本，是压缩包带了「来自 Internet」标记。命令行安装会自动解除；手工解压的话在目录里跑一次：
> `Get-ChildItem -Recurse *.ps1 | Unblock-File`

---

## 快速上手

1. **打开工具** —— `scm`，或双击 `一键运行.bat`
2. **看「环境」页** —— 7 张卡片告诉你缺什么
3. **点「一键补全」** —— 装官方 App Compatibility FOD（约几百 MB，从 Windows Update 拉取）
4. **重启** —— 必须重启，图形组件才会生效。工具支持**跨重启断点续跑**，重启后再打开会接着往下走
5. **「软件」页添加程序** —— 会自动带入实测推荐参数
6. **启动** —— 起不来就点「启动诊断」，它会看事件日志、WER 记录、缺失的 DLL/运行时，并给出处置建议

---

## 实测数据

在 Hyper-V 上的 **Windows Server 2022 Core（build 20348.2700）** 实测。

### 腾讯 QQ NT 9.9.35（Electron）

| 启动参数 | 首窗口耗时 | 内存 | CPU 时间 |
|---|---|---|---|
| 默认 | 18.2 s | 385.9 MB | 30.5 s |
| `--disable-gpu` | 15.1 s | — | — |
| **`--disable-gpu --disable-software-rasterizer`** | **6.0 s** | **325.7 MB** | **4.6 s** |

装完 9 个进程正常运行。原因：Server Core 没有 GPU 驱动和完整 DWM 合成，Chromium 的 GPU 进程会反复失败重试，拖慢启动并抬高 CPU。

### MSLX-Daemon（.NET 10 / ASP.NET Core）

缺 .NET 10.0.0 运行时 → 用 zip 免安装方式部署 10.0.12 → Kestrel 正常启动并监听 `1027`，Web 控制台在浏览器里渲染正常、登录成功。

### 自动登录闭环

LSA 机密写入（密码不以明文落注册表）→ 真实重启 → 自动登录为 `console` 会话 → GUI 自检完整通过（整屏截图非黑占比 98.2%）。

### GUI 能力自检

工具自带 `-SelfTest` 与 `-LayoutDump`：前者核对页面/卡片/按钮数量，后者把控件树的真实坐标打出来并标出越界。用于在 Server Core 上验证界面真的渲染出来了，而不只是「进程还在」。

---

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows Server 2016 / 2019 / 2022 / 2025 **Core**（实测 2022 Core build 20348.2700） |
| PowerShell | 5.1 或更高（Windows 自带即可，无需装 PowerShell 7） |
| 权限 | 管理员（补环境、装 WAC、写 LSA 都要求） |
| 磁盘 | 建议 C: 至少留 5 GB（FOD 包 + 组件） |
| 网络 | 装 FOD 需要能访问 Windows Update；离线环境可以用 FOD ISO 配 `-Source` 走本地源 |

---

## 已知限制

诚实列出做不到的事：

1. **UWP / XAML 应用不行** —— 补齐 FOD 后仍缺 `twinui.dll`，这类程序起不来。
2. **界面是经典样式** —— 缺 `themeservice.dll` / `themeui.dll`（主题服务），所以窗口不会应用现代主题，看起来偏 Win7/经典风格。缺 `DispBroker.dll` 也限制了一部分显示相关能力。
3. **「桌面体验专属」23 个组件，补齐后仍缺 4 个**：`twinui.dll`、`themeservice.dll`、`themeui.dll`、`DispBroker.dll`。
4. **不是远程桌面方案的替代品** —— 本工具是在 Server Core 本机补齐图形能力，程序在本机渲染。若想做「无头机器上跑 GUI、通过网络看画面」，属于另一个方向（见工具里的「阶段 B（IDD 远程渲染）指引」）。
5. **Electron 程序的 GPU 加速用不上** —— 只能走软件渲染，所以建议带上禁用 GPU 的参数。这是 Server Core 环境的客观限制，不是本工具的缺陷。
6. **FOD 从 Windows Update 下载体积较大且对网络敏感**，可能失败。工具内置了常见错误码的中文处置建议（`0x800f0954` / `0x800f0831` / `0x80240021` 等）。

---

## 常见问题

**Q：一定要重启吗？**
要。图形组件（`dwm.exe`、`dcomp.dll` 等）只有在重启后才加载。工具支持跨重启断点续跑，重启后再打开会接着跑完。

**Q：装完 FOD 界面还是很丑 / 主题不对？**
这是预期内的。缺主题服务组件，见「已知限制」第 2 条。

**Q：`scm` 提示找不到工具入口？**
工具目录被移动或改名了。重新跑一次目录里的 `安装一行命令.bat`（`.cmd` 里写死了工具路径）。

**Q：PowerShell 报「无法加载文件，未对文件进行数字签名」？**
包带了「来自 Internet」标记。执行 `Get-ChildItem <工具目录> -Recurse *.ps1 | Unblock-File`。命令行安装方式会自动处理这一步。

**Q：Windows Admin Center 装完访问不了？**
先跑「Windows Admin Center → 状态检查」。两个关键点：**入口是 `/shell/` 而不是根路径**（根路径返回 403 是登录页的正常状态码，不是坏了）；自签名证书需要在浏览器里选择「继续访问」。

**Q：为什么不用官方逐步教程，要用这个工具？**
因为它把「判断该走哪条路 → 装什么 → 装完怎么验证 → 起不来怎么查」串成了一个流程，并且把社区里流传的错误说法（比如 `Server-Gui-Shell`）提前排除掉了。你也可以照着上面的原理自己敲命令，工具只是省事。

---

## 目录结构

```
├─ 一键运行.bat                 双击入口（自动提权 → 图形界面）
├─ 打开命令行菜单.bat           旧的控制台菜单入口
├─ 安装一行命令.bat             把 scm 装进 PATH
├─ Start-GuiReadyApp.ps1        统一入口（默认 GUI，-Console 走菜单）
├─ Start-GuiReady.ps1           15 项两级控制台菜单
├─ Install-GuiReadyCommand.ps1  一行命令的安装器
├─ Resume-GuiReadyPipeline.ps1  跨重启断点续跑
├─ install.ps1                  命令行一行安装（远程拉取发布包）
├─ pack.ps1                     打包发布压缩包
│
├─ gui\
│   ├─ GuiReady.GuiApp.ps1      主界面（含 -SelfTest / -LayoutDump 诊断开关）
│   ├─ GuiReady.Actions.ps1     32 个动作的清单（GUI 与无头执行器共用同一份）
│   └─ Run-GuiReadyAction.ps1   动作执行器（子进程运行，界面不卡）
│
├─ lib\
│   ├─ GuiReady.Common.ps1      日志、权限、JSON 报告、SYSTEM 提权计划任务
│   ├─ GuiReady.Detect.ps1      环境探测（只读）
│   ├─ GuiReady.PeInspect.ps1   PE 静态预检（架构/子系统/.NET/Electron 特征）
│   ├─ GuiReady.Fod.ps1         官方 App Compatibility FOD 安装
│   ├─ GuiReady.DotNet.ps1      .NET 运行时 zip 免安装补齐
│   ├─ GuiReady.AutoLogon.ps1   自动登录（LSA 机密，密码不落明文）
│   ├─ GuiReady.RdpFix.ps1      RDP 修复与登录 Shell 设置
│   ├─ GuiReady.Wac.ps1         Windows Admin Center 安装与状态
│   ├─ GuiReady.GuiTest.ps1     GUI 能力自检 + 窗口截图取证
│   ├─ GuiReady.Pipeline.ps1    一键流程
│   ├─ GuiReady.Catalog.ps1     程序兼容档案读取
│   ├─ GuiReady.Diag.ps1        排障采集
│   ├─ GuiReady.Matrix.ps1      版本适配矩阵
│   ├─ GuiReady.PhaseB.ps1      阶段 B（IDD 远程渲染）指引
│   ├─ GuiReady.Command.ps1     一行命令
│   ├─ GuiReady.GuiShell.ps1    非官方 Gui-Shell 路线（已判定不可行）
│   └─ catalog.json             程序兼容档案（带实测证据）
│
└─ launcher\                    RDP 会话用的轻量面板 + 程序列表存储
```

> 运行时会自动创建 `logs\`（日志）、`reports\`（JSON 报告与截图）、`state\`（断点状态）、`payload\`（下载的安装包），这些都不进仓库。

---

## 卸载

```powershell
# 1) 卸掉一行命令
& 'C:\Program Files\ServerCoreManager\Install-GuiReadyCommand.ps1' -Uninstall

# 2) 删掉安装目录即可（工具本身不写注册表，除了下面这一项）
Remove-Item 'C:\Program Files\ServerCoreManager' -Recurse -Force
```

如果你开过**自动登录**，请先在工具里把它关掉（「会话与登录 → 自动登录 → 关闭」），否则会在注册表和 LSA 里留下自动登录配置。

已经装过的 **App Compatibility FOD 不会**被卸载（它是系统组件）。要卸掉：

```powershell
Remove-WindowsCapability -Online -Name ServerCore.AppCompatibility~~~~0.0.1.0
```

---

## 许可证

[GPL-3.0](LICENSE) —— 你可以自由使用、修改、分发，但**修改后分发必须同样以 GPL-3.0 开源**。

本项目包含的所有「实测结论」都来自真实环境的测试记录，欢迎提交你验证过的机型与程序档案（`lib/catalog.json`）。

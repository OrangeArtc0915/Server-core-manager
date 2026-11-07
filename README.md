# Server Core Manager

**让带图形界面的程序，在 Windows Server Core 上真正跑起来。**

Windows Server Core 没有桌面、没有 `explorer.exe`、没有 `dwm.exe`，很多带界面的程序（QQ、各类 Electron 应用、WPF 工具、.NET 桌面程序、MMC 管理单元）装上去不是报错就是白屏。这个工具把「补全图形环境 → 添加程序 → 启动并排障」这条链路做成了一键操作，并且带一个自己的图形界面 —— 不用整天对着终端敲命令。

> 作者：**mmm** ｜ QQ 群：**1034243331** ｜ GitHub：<https://github.com/OrangeArtc0915/Server-core-manager> ｜ 项目主页：<https://orangeartc0915.github.io/Server-core-manager/>

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
- [国内源与离线使用](#国内源与离线使用)
- [快速上手](#快速上手)
- [实测数据](#实测数据)
- [系统要求](#系统要求)
- [已知限制](#已知限制)
- [常见问题](#常见问题)
- [目录结构](#目录结构)
- [卸载](#卸载)
- [支持作者](#支持作者)
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

### 图形界面（28 个页面，原生 C# 界面，只做深色主题）

> **两套界面，同一个后端**：默认启动的是原生界面 `ui\bin\ScmUi.exe`（csc 现场编译，启动约 150 ms）；它起不来时启动器会安静回退到 PowerShell 版界面（`gui\GuiReady.GuiApp.ps1`），两条路都在包里。下文按原生界面介绍，功能与动作两边一致。
>
> **深色是唯一主题**：目标场景是 Server Core —— 运维就在深色终端里干活，界面与终端同调不刺眼；且 Server Core 常年缺主题/显示个性化组件，浅色在远桌面里更晃眼。所有颜色都走设计 Token（`ui\Theme.cs`），控件全部自绘，不会混进系统浅色控件。

| 页面 | 内容 |
|---|---|
| **总览** | 4 张指标卡（CPU / 内存 / 系统盘 / 关键服务）+ 关键服务列表（带「重启」）+ 最近的系统错误与警告事件 + 占内存最多的进程 + 3 条趋势条；每 5 秒刷新，采集全在子进程里跑 |
| **应用商店** | 24 条**手工精选**（9 类：容器 / Web / 数据 / 运维 / 监控 / 网络 / 开发 / 媒体 / AI）的卡片墙 + 分类与兼容性筛选 + 搜索 + 批量安装队列 + 导入导出 `packages.config`。**本机还没有包管理器时（刚装好的 Server Core 就是这样），点搜索/安装会先弹一次确认：选「是」之后自动装 Chocolatey，装完自动把你刚才那步操作做完**；页面上也常驻「自动安装 Chocolatey」主按钮 |
| **环境补全** | 7 张状态卡片（系统版本 / 图形组件 / 渲染管线 / .NET 运行时 / 登录会话 / 提权 UAC / Web 管理）+ 一键补全、重新探测、GUI 自检、自动登录、Windows Admin Center |
| **角色与功能** | 图形化封装 `Install-WindowsFeature` / `Uninstall-WindowsFeature`：能力胶囊 + 过滤（全部 / 已装 / 未装 / 仅角色）+ 列表逐项安装 / 移除 + 批量队列。装完是否需要重启会写进日志；「包含管理工具」默认关闭 |
| **安全基线** | 10 项**本机可验证**的安全基线（防火墙 / Defender / UAC / SMBv1 / 来宾账户 / 管理员组 / 网络共享 / RDP 与 NLA / 密码与锁定策略 / 24h 登录失败），每项带**原始证据**；可修项带「修复」，只修安全且可逆的 |
| **程序管理** | 添加程序、启动、设置启动参数、后台常驻、启动诊断、查看兼容档案、移除；会读 PE 头自动带入实测推荐参数 |
| **SCM附属** | TUI_TOOL 里的三套附属工具（scterm / scm-top / CraftDock）：查看本地状态，**GitHub / Gitee 两条线路都下载编译好的发行包**，安装到 `payload\plugins\<工具>` |
| **兼容档案** | 程序兼容档案：程序在 Server Core 上能不能跑、要补什么运行时、推荐哪些启动参数 |
| **运行库** | Node / Python / Go / Java / PHP / Bun 各两个版本：官方 zip 解压到 `runtimes\<语言>\<版本>`，`current` 用 junction 指路，机器 PATH 只挂 current —— 切版本不用改脚本；国内镜像优先 |
| **数据库** | PostgreSQL 16.4 / 17.0 与 MySQL 8.4 / 8.0：解压官方 zip、初始化实例、注册服务、**建库 / 备份 / 还原**；管理员密码用 DPAPI 加密存放 |
| **系统工具** | 7 个本机工具（记事本、命令提示符、美化终端、MMC、资源监视器、系统信息、PowerShell ISE）；缺失的标「（缺失）」并说明去哪补、可一键用命令提示符代替；与 WAC 重复的 14 个工具默认收起 |
| **终端美化** | Nerd Font / Oh My Posh / Fastfetch（**按需下载**）+ 6 套主题 + 一键美化 / 打开美化终端 / 实测回读 conhost 字体 / 一键还原 + 安装 PowerShell 7（清华镜像优先） |
| **系统更新** | Windows Update：检查可用更新（系统自带 COM，不依赖第三方模块）、按编号 / 全部安装、已安装历史、自动更新策略（自动安装 / 手动 / 仅通知 / 关闭） |
| **网络配置** | 网卡 / IP / 网关 / DNS / 路由：DHCP 与静态地址切换（改前自动备份）、网卡启停与重启、DNS 解析测试、路由表 |
| **本地账户** | 本地用户与组：新建 / 启停 / 改密 / 调整组 / 删除（挡住当前账户与最后一个管理员）、组成员、登录会话 |
| **服务管理** | 全量服务列表：启动 / 停止 / 重启 / 暂停 / 继续、启动类型（自动 / 延迟 / 手动 / 禁用）、失败恢复策略、依赖与详情 |
| **防火墙** | 入站 / 出站规则：查看、开放端口（TCP/UDP + 来源地址）、启用 / 禁用、删除；显示三个配置文件的默认动作 |
| **存储与备份** | 磁盘 / 卷 / 卷影副本三个视图：初始化磁盘、扩展卷、格式化（二次确认）、清理临时文件、创建 / 删除快照；Windows Server Backup 状态与立即备份 |
| **系统任务** | 查看 Windows 计划任务（默认隐藏本工具自建的 `ScmOps-*`）：启用 / 禁用 / 立即运行 / 停止 / 删除 / 详情 |
| **角色工具** | Hyper-V（虚拟机启停 / 保存 / 快照）、IIS（站点与应用池）、打印（队列）、SMB 共享（含会话与打开文件）；没装的角色会提示去补 |
| **通知** | SMTP 与 Webhook（钉钉 / 飞书 / 企业微信 / 通用 JSON）：配置、测试、发送自定义消息；守护启动失败与端口巡检异常会自动发 |
| **日志中心** | Windows 事件日志与工具自身日志的统一读取、筛选、导出；双击一行看完整消息 |
| **任务中心** | 每个动作都有任务编号、起止时间、退出码与完整日志；双击看详情与审计轨迹 |
| **自动化** | 五个视图：**进程守护**（崩溃自动拉起 + 退避）、**计划任务**（间隔 / 每天定时 + 动作链）、**目录备份**（zip 或整目录复制 + 保留 N 份）、**端口巡检**（TCP 探测 + 本机监听进程）、**下载队列**（BITS 后台传输，可暂停 / 继续 / 收尾） |
| **操作审计** | 提交、执行、配置备份与恢复全在这里留痕；只追加、不修改，可按级别 / 时间 / 关键词筛选后导出 |
| **远程主机** | WinRM 主机清单、连通性测试、批量执行命令；凭据用 DPAPI 加密 |
| **全部功能** | 全部 **155 个动作 / 31 组**：左边选分组，中间选动作，右边填参数后运行（可先「仅预览」看要执行什么） |
| **关于** | 作者 / QQ 群 / GitHub / 官网（链接可点）、打开日志与报告目录、**完整性自检**（文件清单 + 签名 + 目录权限） |

> 每页右上角的「高级」按钮会**就地弹窗**打开本页对应的动作分组（不跳走），配合「全部功能」页使用：日常点卡片，边角参数走「高级」。

### 附属工具（SCM附属）

`TUI_TOOL/` 里的三套工具各自占一个 GitHub 分支（源码），Gitee 不放源码。页面里两条线路下载的都是编译好的发行包，解压到 `payload\plugins\<工具>`：

| 工具 | 内容 | GitHub（发行包） | Gitee（发行包） |
|---|---|---|---|
| scterm | Rust 单文件终端多路复用 | [scterm-v0.1.0](https://github.com/OrangeArtc0915/Server-core-manager/releases/tag/scterm-v0.1.0) | [scterm-v0.1.0](https://gitee.com/orangearc655743/server-core-manager/releases/tag/scterm-v0.1.0) |
| scm-top | 零依赖 TUI 监控（PowerShell） | [scm-top-v0.1.0](https://github.com/OrangeArtc0915/Server-core-manager/releases/tag/scm-top-v0.1.0) | [scm-top-v0.1.0](https://gitee.com/orangearc655743/server-core-manager/releases/tag/scm-top-v0.1.0) |
| CraftDock | TypeScript 终端服务器管理 | [craftdock-v1.0.0](https://github.com/OrangeArtc0915/Server-core-manager/releases/tag/craftdock-v1.0.0) | [craftdock-v1.0.0](https://gitee.com/orangearc655743/server-core-manager/releases/tag/craftdock-v1.0.0) |

> 下载包都会校验 zip 魔数；两个仓库的发行版旁都带 `.sha256`。已安装时整体替换，失败保留旧版本。

> 商店、角色、总览、安全、运行库、数据库、自动化这些页的数据都在**子进程**里取（`choco search` 是网络调用、`Get-WindowsFeature` 要问 CBS、`Get-Counter` 取样要 1 秒、事件日志查询要几百毫秒），结果写成 JSON 由界面读回 —— 原生界面走 `ui\Bridge.cs`，PowerShell 版走查询宿主，界面不会卡住；查询超时会自己收尾，不会永远停在「正在…」。

### 155 个功能动作

- **一键流程（4）**：一键就绪（自动重启 / 需要重启时暂停）、续跑未完成的流程、查看流程状态
- **探测与诊断（4）**：环境探测、exe 兼容性预检、GUI 能力自检（真的建窗 + 抓图取证）、启动并诊断
- **程序档案（3）**：查询某个程序的兼容档案、列出全部档案、添加你自己的档案条目
- **补给（3）**：安装 App Compatibility FOD（官方路线）、按程序需求补齐 .NET 运行时、补齐桌面体验 DLL
- **应用商店（9）**：包管理器状态、安装 Chocolatey、安装 / 卸载软件包、安装精选应用（含前置检查）、批量安装队列、导入 / 导出软件清单、查看详情
- **运行库（5）**：状态、安装版本、切换 current、卸载版本、修复 PATH
- **数据库（7）**：状态、安装引擎、初始化实例、服务注册 / 启停 / 注销、备份、建库、还原
- **角色与功能（5）**：状态、安装 / 移除、批量安装 / 批量移除
- **监控与诊断（2）**：系统快照、服务控制（做完复核真实状态）
- **安全与合规（3）**：安全基线审计、本工具完整性自检、安全基线一键修复
- **AI 辅助（3）**：dsh-TUI 依赖检查（含 npm 实查包名）、安装依赖、启动
- **会话与登录（8）**：RDP / 会话 / UAC / .NET 状态、远程会话修复、重启与取消、自动登录（状态 / 启用 / 关闭）、设置登录 Shell
- **使用与工具（1）**：持久化启动程序（计划任务）
- **Windows Admin Center（4）**：状态检查、一键安装并自动配置、服务控制、打开界面
- **文件与日志（9）**：新建 / 重命名 / 删除 / 保存 / 复制 / 移动 / 压缩 / 解压、导出日志
- **配置备份（2）**：导出配置备份（ZIP）、从备份恢复
- **远程运维（1）**：远程批量执行命令
- **守护与计划（8）**：添加 / 删除守护、立即检查、启用暂停守护；添加 / 删除计划、立即执行、启用暂停计划
- **备份与巡检（6）**：添加 / 执行 / 删除目录备份；添加 / 巡检 / 删除端口目标
- **下载队列（6）**：添加下载、暂停、继续、收尾、取消、移除
- **终端美化（5）**：状态检查、一键美化终端、打开美化终端、一键还原、安装 PowerShell 7
- **Windows 更新（4）**：检查、安装（选中 / 全部）、已安装历史、自动更新策略
- **网络配置（5）**：状态、设置 IP / DHCP、网卡启停重启、DNS 解析测试、路由表
- **本地账户（6）**：用户列表、组列表、新建 / 修改 / 删除用户、登录会话
- **服务管理（5）**：服务列表、启停重启、启动类型、失败恢复、服务详情
- **防火墙（4）**：规则列表、开放端口、启用禁用、删除规则
- **存储与备份（12）**：磁盘卷、扩展 / 格式化 / 初始化、清理临时文件、卷影副本（列表 / 创建 / 删除）、Windows 备份（状态 / 立即备份 / 历史 / 安装功能）
- **系统任务（3）**：列表、详情、启停 / 运行 / 停止 / 删除
- **角色工具（12）**：Hyper-V（列表 / 操作 / 快照）、IIS（站点 / 操作）、打印（列表 / 操作）、SMB 共享（列表 / 新建 / 删除 / 断开句柄）、角色可用性检测
- **通知（4）**：配置、测试、自定义发送、查看配置与记录
- **SCM附属（2）**：下载附属工具发行包（GitHub 线路）、下载附属工具发行包（Gitee 线路）

### 终端美化（在 Server Core 的 conhost 上做出好看的控制台）

Server Core 上没有 Windows Terminal 可用，所以这个功能是**直接把 conhost 打扮好看**：

- **Nerd Font**：装 MesloLGS NF（全机安装 + 写控制台字体白名单 + FontLink 回退到微软雅黑，保证中文正常）
- **Oh My Posh**：单文件程序 + 主题，往 PowerShell 5.1 与 PowerShell 7 的 profile 各写一段可撤销的初始化块，得到彩色提示符
- **6 个内置主题可选**：`1_shell`、`atomic`、`catppuccin_frappe`、`dracula`、`emodipt-extend`、`zash` —— 「一键美化终端」参数里选一个（默认是自带的 One Dark 主题），装完这些主题也都放在 `bin\themes\`，想换风格改 profile 里的 `--config` 指向即可
- **Fastfetch**：进终端先来一段系统信息
- **One Dark 配色 + 打开 ANSI(VT)**：写 `HKCU\Console`（先备份原值，可用「一键还原」还原）
- 装好后的入口是命令 **`scm-term`**（或工具页「美化终端」按钮 / 更多 → 终端美化 → 打开美化终端）
- **任何终端窗口都会提示可用入口**（黄色）：打开 cmd 或 PowerShell 时按「有什么提示什么」打印 `输入 "Sconfig" 返回服务器菜单` / `输入 "scm" 打开 GUI 工具` / `输入 "scm-term" 打开美化终端` —— 只提示真的装过的那几个（避免把用户带去敲一个不存在的命令），也不会因为一个都没装就整段不显示（实测这样会被当成「提示坏了」）。**执行 cls / clear 清屏后会自动重新显示在顶部**（PowerShell 覆写 `Clear-Host`，cmd 用 `doskey` 宏接管 `cls`）。非交互式（`cmd /c ...`、输出被重定向）保持安静，不会污染脚本输出；「一键还原」会一并移除这个提示

> **为什么必须走 `scm-term` 而不是直接开 cmd**（实测结论，不是猜的）：
> 中文控制台的代码页是 936，conhost 在该代码页下**只接受自带中文字形的字体** ——
> 实测 `MesloLGS NF` 和 `Consolas` 都会被拒（API 返回成功，但 conhost 实际回退成「新宋体」）；
> 把控制台切到 UTF-8（`chcp 65001`）后，同一个 Nerd Font 立刻被接受（回读 `face=[MesloLGS NF]`）。
> 另外 `HKCU\Console\CodePage` 和「按标题记忆」两种写法对新建控制台**都不生效**（都实测过）。
> 所以 `scm-term.cmd` 会先 `chcp 65001`、再用 Console API 应用字体，然后才启动带 oh-my-posh 的 PowerShell。
> 素材不再打进发布包：Nerd Font、`oh-my-posh.exe`、`fastfetch.exe` 在第一次「一键美化终端」时**按需从官方源下载**（缺什么下什么）；完全离线时把它们放进 `setup\console\`，动作里勾「不联网下载」。

### 自动化（守护 / 计划 / 备份 / 巡检 / 下载）

「自动化」页把五件平时要靠手写计划任务的事做成了表单，定时一律交给 **Windows 计划任务**（`ScmOps-*`），界面关掉、用户注销也照跑：

| 功能 | 做什么 | 怎么落地 |
|---|---|---|
| **进程守护** | 每 N 分钟检查一次进程；不在就用原参数拉起；连续启动失败按 15→30→60→120→240→300 秒退避 | 计划任务 `ScmOps-Guard-<编号>`；可选「当前登录用户（交互会话）」或 SYSTEM |
| **计划任务** | 按间隔、每天或每周定时，依次执行一串**已有动作**（`reboot;backup-export` 这种动作链） | `ScmOps-Plan-<编号>` 调用 `Run-GuiReadyOps.ps1 -Mode plan-run`，每一步仍走正常动作执行器（任务记录与审计都在） |
| **目录备份** | 源目录 → zip 或整目录复制，按时间戳命名，只保留最新 N 份；目标不能放在源目录里 | `ScmOps-Backup-<编号>` 每天定时执行 |
| **端口巡检** | 一组 主机:端口 逐个 TCP 探测（带超时），本机端口顺带查监听进程 | 不排期，页面上点「巡检一次」 |
| **下载队列** | http/https 文件交给 BITS 后台传输：断点续传、可暂停 / 继续 / 收尾 / 取消 | 不排期；默认存到 `payload\downloads` |

> 创建计划任务需要**管理员权限**；权限不足时会明确提示「请以管理员身份重开」，不会留下半条记录。守护/计划/备份的记录都在 `state\ops\ops.json`，删记录会一并注销对应任务。
>
> 下载队列用的是 **BITS**，它要求当前进程有用户的交互登录会话 —— 在桌面里打开本工具没问题；如果你把工具挂到「以 SYSTEM 运行」的计划任务里，添加下载会明确提示这一点。

### 系统管理（更新 / 网络 / 账户 / 服务 / 防火墙 / 存储 / 任务 / 角色 / 通知）

这些页覆盖 Server Core 上原本只能开 `sconfig`、`diskmgmt`、`services.msc` 或敲命令的场景：

| 页面 | 能做什么 | 数据来源 |
|---|---|---|
| **系统更新** | 检查 / 安装 / 历史 / 自动更新策略 | 系统自带 `Microsoft.Update.Session` COM，不依赖第三方模块 |
| **网络配置** | 看网卡与路由；DHCP / 静态 IP 切换；网卡启停重启；DNS 解析测试 | `NetTCPIP` 模块；改 IP 前先把当前配置写进 `backup\` |
| **本地账户** | 用户与组、启停、改密、调组、删除、登录会话 | `LocalAccounts` + `quser`；挡住「当前账户」与「最后一个管理员」 |
| **服务管理** | 全量服务、启停重启、启动类型、失败恢复、依赖 | `Win32_Service` + `sc.exe`，改完回读 |
| **防火墙** | 规则查看（入站 / 出站）、开放端口、启停、删除 | `NetSecurity` 模块；非管理员会明确提示 |
| **存储与备份** | 磁盘 / 卷 / 卷影副本；扩展、格式化、初始化、清理临时文件 | `Storage` + VSS WMI + Windows Server Backup 模块（没装会提示） |
| **系统任务** | 查看系统计划任务、启停 / 运行 / 停止 / 删除 | `ScheduledTasks`；本工具自建的 `ScmOps-*` 不在这里删 |
| **角色工具** | Hyper-V / IIS / 打印 / SMB 共享（装了角色才有） | 对应 PowerShell 模块；没装的角色只显示提示 |
| **通知** | SMTP / Webhook（钉钉、飞书、企业微信、通用 JSON） | 配置存 `state\notify\`，SMTP 密码用 DPAPI LocalMachine 加密 |

> 所有列表都支持**点列头排序**与「导出 CSV」（UTF-8 BOM，Excel 直接打开）；`Ctrl+K` 可以快速跳转到任意页面。
> 写操作全部走动作执行器，仍然可以在「全部功能」里预览参数；破坏性操作（格式化、初始化磁盘、删除用户）在界面上会二次确认。

### Windows Admin Center 一键安装

- 本地没有安装包时，**自动从官方地址下载**（`aka.ms/WACDownload`，约 140 MB），可用 `-NoDownload` 关闭以适配离线/内网
- 自动识别两代安装包并分派参数：经典 MSI 用 `msiexec` + `SME_*`，v2 用 Inno Setup 的 `/VERYSILENT`
- 装完**自动放行防火墙、设为自启、启动服务，并探测 `/shell/` 是否可达**，最后输出浏览器访问地址
- 全程通过 SYSTEM 计划任务执行，以规避 v2 安装包重启 WinRM 导致的会话中断

### 为什么没有「安装 Windows Terminal」这个功能

> **结论：Windows Terminal 在 Server Core 上用不了（实测，不是推测），所以本工具不再提供这个功能。**
> 它的界面是 XAML 栈，而 Server Core 缺 `Windows.UI.Xaml.dll` / `twinui.dll`（`WinUX.dll` 同样不在）：
> - **MSIX 打包版**：注册直接失败 —— `0x80073CF6`「无法注册包」+ `0x80040154`「初始化 windows.capability 扩展时没有注册类」；`Add-AppxProvisionedPackage`（DISM 预置包）同样报 `0x8007007E`
> - **ZIP 免安装版**（不走 AppX 部署，包里自带 `Microsoft.UI.Xaml.dll`）：进程起来后立刻 APPCRASH（故障模块 `KERNELBASE.dll`，异常码 `e06d7363`），出不了窗口
> - 实测环境：Windows Server 2025 Core 26100.32230。**装好 App Compatibility FOD 并重启之后仍然如此**（FOD 不带 `Windows.UI.Xaml.dll` / `twinui.dll`）
> - 顺带确认：WT 1.24 的包要求 `Windows.Desktop ≥ 10.0.19041` —— **Server 2016 / 2019 也直接排除**
>
> 想在 Server Core 上要个好看的终端，用本工具的 **「更多 → 终端美化」**（Nerd Font + Oh My Posh + Fastfetch，直接美化 conhost）。

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

在**管理员** PowerShell 里执行（国内推荐走 Gitee）：

```powershell
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

GitHub 能直连时也可以走 GitHub：

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

两条线路装的是同一个发布包，脚本内容也一致。脚本里的下载顺序是：
**GitHub Releases → Gitee Releases**，前一条不通或拿到的不是真 zip 就自动换下一条（两条都只下发行包，不下载源码）。

（Gitee 对不存在的下载路径会返回 `200` + 一段 JSON，所以脚本会按 zip 魔数 `PK` 校验内容，不是只看状态码。）

它会：下载指定版本的发布包（默认 `v2.0`）→ 解压到 `C:\Program Files\ServerCoreManager` → 解除「来自 Internet」的文件锁定 → 安装 `scm` 一行命令。

装完之后，**在任意目录输入 `scm` 回车**就能打开图形界面（首次会像 `sconfig` 一样弹一次提权确认）。

需要改默认值时用环境变量（因为 `iex` 没法传参数）：

```powershell
$env:SCM_DEST = 'D:\SCM'      # 改安装目录
$env:SCM_NO_COMMAND = '1'     # 不装 scm 命令
$env:SCM_VERSION = 'v2.0'     # 指定发布版本（两个仓库用同一个 tag）
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

也可以先把 [install.ps1](install.ps1) 存成文件，再按 UTF-8 读进来跑，这样能直接传参（不要直接 `.\install.ps1`：Windows PowerShell 5.1 会按 ANSI 读无 BOM 文件，中文会破坏语法）：

```powershell
& ([scriptblock]::Create((Get-Content .\install.ps1 -Raw -Encoding UTF8))) -Dest 'D:\SCM' -NoCommand
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
├─ gui\    ← PowerShell 版界面（GuiReady.GuiApp.ps1 主界面 + 动作清单 + 动作执行器 + 各 runner）
├─ ui\     ← 原生 C# 界面源码（csc 现场编译成 ui\bin\ScmUi.exe，启动器优先用它）
├─ lib\    ← 全部能力模块 + catalog.json 兼容档案
├─ store\  ← 应用商店精选清单（catalog.json，24 条）
├─ setup\console\ ← 终端美化用的 Oh My Posh 主题（字体与 exe 首次美化时按需下载）
└─ launcher\ ← RDP 会话用的轻量面板（可作为登录 Shell 替代 explorer.exe）
```

> 解压后如果 PowerShell 拒绝执行脚本，是压缩包带了「来自 Internet」标记。命令行安装会自动解除；手工解压的话在目录里跑一次：
> `Get-ChildItem -Recurse *.ps1 | Unblock-File`

---

## 国内源与离线使用

原则：**不必要的网络请求一律不做；必须联网的优先国内源**（终端美化素材不随包分发，装的时候按需下载）。所有"要联网"的地方都在下表中，实测数据来自一台国内的 Windows Server 2025 Core 测试机。

| 依赖 | 来源 | 说明 |
|---|---|---|
| 终端美化素材（Nerd Font / Oh My Posh / Fastfetch） | 官方源**按需下载** | 缺什么下什么，需要联网；暂无国内镜像，可用 `SCM_CONSOLE_MIRROR` 指向内网源 |
| PowerShell 7（可选功能） | **清华 TUNA 镜像** | 本机实测是真文件（`application/zip`，101 MB）；拿不到时自动回退 GitHub 官方。**注意**：清华会拒绝部分网络的访问（实测有网络被返回 403，响应头 `X-TUNA-MIRROR-ID: neomirrors`），这种网络下请用「指定本地 zip」或 `-Url` 参数 |
| .NET 运行时 | 微软官方 CDN | 清华 / 阿里云 / 华为云**都没有** .NET 镜像（实测 404、门户 HTML 或非文件）；官方 CDN 国内实测约 **470 KB/s** |
| Windows Admin Center | 微软官方 `aka.ms` | 无国内镜像；官方 CDN 实测约 **720 KB/s**；可用 `-NoDownload` 走离线内网包 |

**完全离线的场景**（内网、无外网）：上面的"要下载"项都可以绕开 ——
终端美化的第三方程序与字体改成**装的时候按需下载**（缺素材时从官方源 / GitHub 加速镜像取），
完全离线时勾「不联网下载」并把 MesloLGS NF 的 ttf、`oh-my-posh.exe`、`fastfetch.exe` 放进
`setup\console`；PowerShell 7 可以在动作参数里**直接指定本地 zip**（或指定内网 URL）；
.NET 运行时也可以在动作参数里指定本地 zip。

**自建 / 内网源**（环境变量，设置后全局生效）：

| 变量 | 作用 |
|---|---|
| `SCM_MIRROR_GITHUB` | 把 `https://github.com` 前缀换成你的镜像（`install.ps1` 下载发布包也用它） |
| `SCM_MIRROR_GITEE` | 换一个 Gitee 基址（默认 `https://gitee.com/orangearc655743/server-core-manager`） |
| `SCM_MIRROR_TUNA` | 清华镜像基址（默认 `https://mirrors.tuna.tsinghua.edu.cn`） |
| `SCM_MIRROR_DOTNET` | 替换 `https://builds.dotnet.microsoft.com/dotnet` 前缀（内网 .NET 源） |
| `SCM_CONSOLE_MIRROR` | 终端美化素材（oh-my-posh / fastfetch / 字体）的下载前缀；直连 GitHub 不通时会自动依次试 `ghproxy.net` / `ghfast.top` / `gh-proxy.com` |

例：

```powershell
$env:SCM_MIRROR_GITHUB = 'http://mirror.intranet/github'
$env:SCM_MIRROR_TUNA   = 'https://mirrors.example.com'
scm-term   # 或直接跑工具
```

> 说明：GitHub 在国内常常很慢/不可达，而**清华镜像只镜像了少数项目**（PowerShell 是其中之一），
> 别的项目（Oh My Posh、Fastfetch）没有可用的国内镜像 —— 所以发布包**不再内置**它们，
> 改成装的时候按需下载，并自动依次尝试几个 GitHub 加速前缀（也可用 `SCM_CONSOLE_MIRROR` 指向内网源）。

---

## 快速上手

1. **打开工具** —— `scm`，或双击 `一键运行.bat`
2. **看「环境」页** —— 7 张卡片告诉你缺什么（卡片在后台探测，窗口一出来就能操作，数据几秒后自己填上）
3. **点「一键补全」** —— 装官方 App Compatibility FOD（约几百 MB，从 Windows Update 拉取）
4. **重启** —— 必须重启，图形组件才会生效。工具支持**跨重启断点续跑**，重启后再打开会接着往下走
5. **「程序管理」页添加程序** —— 会自动带入实测推荐参数
6. **启动** —— 起不来就点「启动诊断」，它会看事件日志、WER 记录、缺失的 DLL/运行时，并给出处置建议
7. **「自动化」页** —— 要让程序挂了自动拉起、每天定时重启 / 备份、盯端口，都在这里加；定时走 Windows 计划任务，界面关掉也照跑

> **关掉窗口时会自动给你一个终端**：点右上角 X、按 Alt+F4、点「退出（打开终端）」按钮、按 Esc —— 四种关闭方式行为一致，
> 关掉界面后会**自动弹一个终端**（装了美化终端就是 UTF-8 + Nerd Font + oh-my-posh 的 `scm-term`，没装就是普通 PowerShell），
> 不会把你一个人丢在 Server Core 的空会话里。若当时有动作在后台跑，关窗**不会**打断它（日志继续写，重开界面还能看）。
> 自检/布局诊断这类非交互模式不会弹窗。

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

### 启动性能（优化前后对比）

界面启动时最容易踩的坑是「同步探测」：环境探测要跑 DISM、组件扫描、.NET/会话/UAC 查询，
在 Server Core 上**一次要 5~6.5 秒**，跑在界面线程上就会「窗口出来了但点不动」。
现在探测改到独立子进程，分两次回填卡片（先组件推断值、后 DISM 精确值），并保留上次结果做秒显缓存。

| 场景 | 优化前 | 优化后 |
|---|---|---|
| 窗口出现后界面累计冻结（14 秒内） | 2613 ms（单次最长 1086 ms） | **447 ms（单次最长 228 ms）** |
| Server Core 2025 实测（窗口出现 / 界面冻结） | 窗口出现后同步探测阻塞 5~6.5 秒 | **冷启动 1.76 s / 226 ms；热启动 2.01 s / 442 ms** |
| 同步探测阻塞 | 5~6.5 秒全卡在界面线程 | 0（后台进程） |
| 卡片出数据 | 等探测跑完（5 s 后一次性） | 约 2 s 出 6 张，DISM 的 FOD 精确值约 5 s 补上 |
| 第二次及以后启动 | 同样等 5 s | 先用上次结果秒显，后台静默刷新 |

窗口从启动到出现约 2.9 s，拆开看：PowerShell 宿主启动 ~0.75 s（固定成本）、创建全部控件 ~0.83 s、
显示 + Shown 处理 ~0.7 s —— 这部分已经接近 PowerShell + WinForms 的下限，所以没有再往下压。

> 想自己看启动明细：设 `SCM_BOOT_TRACE=1` 再启动，各阶段耗时（毫秒）会追加到 `state\boot-trace.txt`。
> 后台探测的原始结果在 `state\probe.json`（本次）与 `state\env-cache.json`（上次完整结果）。

### 全功能实测（28 个页面 + 155 个动作）

界面布局用一套反射脚手架把 28 个页面在 **1240×820** 与 **1024×700** 两种尺寸下逐页显示，并审计整棵控件树：**越界 0 处、重叠 0 处**。动作清单 155 条 / 31 组直接由 `Run-GuiReadyActions.ps1 -Mode list` 读出 —— 原生界面、动作执行器、无头执行共用同一份定义。

早前那轮把当时的 44 条动作**逐个跑**过（只读和对本机安全的真跑，会改系统状态的只跑预览）。实测环境：Windows 10 22H2（build 19044），管理员会话。

| 分类 | 数量 | 结果 |
|---|---|---|
| 真实执行（只读 / 安全可逆） | 27 | 全部通过 |
| 仅预览（`DryRun`，不动系统） | 17 | 全部通过 |
| 按设计拒绝（本机不适用） | 1 | `fod` 在客户端 Windows 上主动中止并说明原因 |

本轮新增的 20 条（守护与计划 / 备份与巡检 / 下载队列）也逐条跑过。本机（Windows 10，普通用户会话）用于验证权限不足时的失败路径；**计划任务真正的注册 / 启停 / 注销在 Windows Server 2025 Core（build 26100）真机上用管理员账号验过**，结果见下表：

| 场景 | 结果 |
|---|---|
| 目录备份打包 + 保留 1 份，连跑两次 | 生成两个 zip；旧包按保留策略被清理，目录只剩 1 份 |
| 进程守护：进程不在 → 拉起 → 再查 | 第一次 `started`，第二次 `running`（回读到 PID） |
| 守护 / 计划 / 备份的计划任务 | 注册后 `Get-ScheduledTask` 为 Ready；暂停变 Disabled；删除后任务无残留 |
| 计划动作链 `monitor-snapshot` | 成功 1 / 失败 0，任务记录照常落盘 |
| 端口巡检 `127.0.0.1:445,59899` | 445 开放 519 ms（监听进程 System）；59899 超时 800 ms |
| BITS 下载：添加 → 暂停 → 继续 → 收尾 | 37.5 MB 文件完整落盘（39278760 字节），队列清空 |
| 非管理员添加守护 | 明确提示「需要管理员权限」，不写半条记录 |
| 任务重复间隔的写法 | `[TimeSpan]::MaxValue` 会生成非法 XML（`0x80041318`），已改成「每天 0 点触发 + 重复 1 天」 |
| 原生界面在 Server Core 上 | 18 个页面 × 两种分辨率（1240×820 / 1024×700）：越界 0、重叠 0、异常 0 |

> 两个由真机测试暴露的细节已修：BITS 在「没有交互登录会话」时会报 `0x800704DD`，现在会直接说明原因（BITS 必须跑在用户桌面会话里）；下载失败时详情里会带上 BITS 自己的错误原因，大小未知（`BytesTotal = UInt64.MaxValue`）不再显示成天文数字。

**早前那轮实测改掉的 5 个真问题**（都是跑出来的，不是看出来的）：

1. **工具详情的解析**：`choco info` 会把多个键塞进同一行（`Title: 7-Zip | Published: 2026/9/4`），且 `Package url` 那行没有冒号 —— 按实测格式重写了切块逻辑；找不到的包现在会明确说「没找到」而不是显示空格子。
2. **装完包管理器后没重启就不认**：`Chocolatey / node / pnpm` 装完，已经运行的进程 PATH 还是旧的，工具会一直显示「未安装」。改成「先查 PATH，再回退已知安装位置」。
3. **dsh-TUI 依赖装不上**：npm 依赖的构建脚本（koffi）在 cmd 子进程里找不到 `node`，整次安装以 exit 1 结束。安装前会把 node / npm 全局 bin 目录补进 PATH。
4. **dsh-TUI 启动即退出**：它会自己去找 `dsh` CLI，而 `dsh.cmd` 在 `%APPDATA%\npm`（同样可能不在 PATH 里），报「未检测到 dsh CLI」；启动前同样补 PATH。另外 `Start-Process` 不接受空字符串参数，`-Resume` 为空时**每次默认启动都会失败** —— 这两个都是真跑一次才暴露的。
5. **PowerShell 7 的「仅预览」会联网**：受限网络下直接报 403，看着像功能坏了。预览已经挪到网络请求之前。

顺带记一条实测环境事实：**npm 11 默认拦下依赖的 install/postinstall 脚本**（`allowScripts`），dsh-TUI 的原生依赖（koffi / node-pty）因此没编译 —— 工具不替用户放开脚本执行，但会把 npm 原样提示和确切的补救命令打出来。

### GUI 能力自检

- **PowerShell 版界面**自带 `-SelfTest` 与 `-LayoutDump`：前者核对页面/卡片/按钮数量（并会用后台探测产出的 JSON 再渲染一遍卡片，验证数据往返没问题），后者把控件树的真实坐标打出来并标出越界。
- **原生界面**没有内置这两个开关（它更快，也更容易用反射脚手架直接审计）：测试脚本把 `ui\bin\ScmUi.exe` 当程序集加载、创建主窗口、逐页 `ShowPage`，统计每页的越界与重叠，并在进程内直接调用页面方法验证视图切换。两条路都用于确认「界面真的渲染出来了」，而不只是「进程还在」。

---

## 安全设计

这个工具**以管理员身份运行，部分步骤以 SYSTEM 执行**（装 FOD、写 LSA 机密、装 WAC 都要提权）。所以它的安全边界必须讲清楚——否则它自己就会变成服务器上的一个提权入口。

### 一句话威胁模型

> **谁能写工具目录，谁就能拿到管理员/SYSTEM 权限。**

因为工具目录里所有东西都会以高权限被执行：`lib\` `gui\` 下的脚本由提权后的界面拉起；`logs\elevated\worker-*.ps1` 注册成 SYSTEM 计划任务执行；`bin\scm-welcome.cmd` 被 cmd 的 `AutoRun` 挂在**每个** cmd 窗口上。

因此做了三件事：

1. **启动时检查工具目录权限**：只要发现普通用户/`Authenticated Users` 等非管理员主体对工具目录有写权限，就在日志里用醒目格式报出来，并弹一次提示，建议移到 `C:\Program Files\ServerCoreManager`（或按日志里给出的 `icacls` 命令收紧）。
2. **提权 worker 目录自动回退**：工具目录安全时用 `logs\elevated\`；不安全时改用 `%ProgramData%\ServerCoreManager\elevated`（默认 ACL 只有管理员与 SYSTEM 能写）。
3. **worker 目录与文件都收紧 ACL**：去掉继承，只留 `SYSTEM` + `Administrators`（用固定 SID 写，不受系统语言影响）；worker 文件名带随机后缀，写完还会复核「文件够长 + 除管理员/SYSTEM 外没人能改」，不满足就**不注册**计划任务。

### 敏感数据怎么处理

| 数据 | 处理 |
|---|---|
| 开机自动登录的密码 | 默认写 **LSA 机密**（不落注册表明文）；只有显式选「注册表明文」才会写 `DefaultPassword`，且会警告该项目可被远程读取。落盘失败改走 SYSTEM 时用的临时脚本，**跑完立刻销毁** |
| 动作参数（含密码） | GUI 把参数写成 `%TEMP%\gui-ready-*\args.json` 交给子进程；**runner 解析完立刻删文件**，GUI 在动作结束、读完输出后再删整个临时目录（双保险） |
| 查询用的临时文件 | 商店/角色/仪表盘/安全/AI 的查询结果目录（`%TEMP%\gui-*`）在查询收尾时整目录删除 |
| DeepSeek API Key | 只检测环境变量是否存在，**从不写入任何文件**；提示用户自己 `setx` |

### 远程内容与命令执行

| 场景 | 做法 |
|---|---|
| 下载安装脚本（Chocolatey 本体） | 先落盘再执行（不用 `iex`）；**默认只接受 https**，非 https 必须显式 `-AllowInsecure` 才会继续并打警告；下载后检查内容像不像 PowerShell 脚本（大小 + 关键字），不像就拒绝执行；实际地址（含重定向）打进日志 |
| 包名 / 搜索词 / 服务名等外部输入 | 一律走 **JSON 参数文件或 argv 数组**，不做命令行字符串拼接（Windows 下 `Start-Process` 不会自动加引号，拼引号是注入入口）；包名额外做字符集校验（只允许 `A-Za-z0-9._+-`） |
| `npm install -g`（dsh-TUI 依赖） | 只执行安装命令；**不替用户放开**依赖的 install/postinstall 脚本（npm 11+ 默认拦截），而是把后果与确切的补救命令打印出来 |
| `choco install <包>` | 会执行**第三方包的安装脚本（管理员身份）**——这是包管理器的固有风险，所以所有安装类动作都支持「仅预览」，先看清要执行什么再跑 |
| 一键美化终端 | 只往 `HKCU`（当前用户）写控制台外观，`AutoRun` 与 `PATH` 里的启动器都带引号写入；任何一步失败都保留备份可还原 |
| Windows Admin Center | 安装会开放 443 端口并加防火墙规则——这是该功能的目的，装之前请确认你确实想暴露 Web 管理界面 |

### 签名与完整性校验

工具本身也要能被验证 —— 否则"以管理员身份执行自己目录里的脚本"这件事就没有任何保险。现在提供三层：

| 层 | 做什么 | 怎么用 |
|---|---|---|
| **发布包哈希** | `pack.ps1` 打包时算出 zip 的 SHA256，生成 `ServerCoreManager.zip.sha256` 侧车文件 | 用户对照发布页里的 SHA256；`install.ps1` 也会**自动取这个侧车**校验，不一致就**中止且不解压** |
| **文件清单** | 打包时生成 `manifest.sha256`（包内每个代码/配置文件的 SHA256），随包分发 | 解压后执行 `powershell -ExecutionPolicy Bypass -File Sign-GuiReady.ps1 -Verify`，能看出哪个文件被改过；GUI 每次启动也会自动核对一次并在日志里报警 |
| **脚本签名** | `Sign-GuiReady.ps1` 用 Authenticode 给包内 .ps1 签名（PowerShell 原生，不需要 Windows SDK） | 用户可用 `Get-AuthenticodeSignature` 看签名；签名被破坏（改文件）会直接显示不匹配 |

**发版时（维护者）**：

```powershell
# 没有证书：先生成一个自签名代码签名证书（会导出 .pfx 与 .cer）
.\Sign-GuiReady.ps1 -CreateSelfSigned -Subject 'CN=ServerCoreManager'

# 用证书存储里的证书签名（或 -PfxPath .\签名\证书.pfx，密码读环境变量 SCM_PFX_PASSWORD）
.\pack.ps1 -Version v1.2.1 -Sign -Thumbprint <证书指纹>
```

`pack.ps1 -Sign` 的顺序是**先签名 → 再生成清单 → 最后打包**。顺序反了的话，签名会改掉文件哈希，用户侧校验就会误报"文件被改过"。

上传 Releases 时记得 **zip 与 `.sha256` 侧车一起传**，并把 SHA256 写进 Release 说明 —— 校验链才有根。

> **自签名证书只能证明"这份包没被改过"，不能证明"是谁发的"**：在别人的机器上会显示"签名有效但证书不受信任"，需要把那台机器导入 `.cer`（受信任的根证书颁发机构）才会变成"有效"。对外分发建议用受信任 CA 的代码签名证书；本项目目前**没有**受信任 CA 的证书。
>
> `签名\` 目录里那两个 .cmd 是给 **.exe** 用的 signtool 交互式包装（`makecert` → `certmgr` → `cert2spc` → `pvk2pfx` → `signtool` + wosign 时间戳），需要 Windows SDK；本项目发布的是 .ps1 + zip，所以走上面的原生链路。**同一个 .pfx 两边都能用** —— 将来要签 .exe 仍可用它们（路径里带 `签名\` 的那个）。同目录的 `krnln.fnr` / `shell.fne` 是易语言支持库，与签名无关。

### 关于 `irm ... | iex` 这种安装方式

官方推荐的一行安装（`irm https://.../install.ps1 | iex`）本质是「把远端脚本直接喂给管理员 PowerShell」——**传输链路被劫持就等于交出管理员权限**。如果这一点让你不放心，请改用更稳的两步走：

```powershell
# 1) 先下载，自己看一眼
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 -OutFile install.ps1
notepad install.ps1

# 2) 确认后再执行。注意别用 .\install.ps1 —— 见下面的说明
iex (Get-Content -Raw -Encoding UTF8 .\install.ps1)
```

> **为什么不能直接 `.\install.ps1`**：这个文件是不带 BOM 的 UTF-8（带 BOM 会破坏 `irm | iex`：BOM 会被当成脚本第一个字符，`iex` 直接报 `The term '﻿Write-Host' is not recognized`，实测确认）。而 Windows PowerShell 5.1 读**不带 BOM** 的文件时按系统 ANSI 代码页解码 —— 中文系统上就变成乱码，脚本会因语法错误跑不起来。用 `iex (Get-Content -Raw -Encoding UTF8 ...)` 显式按 UTF-8 解码就绕开了这个矛盾。
>
> 想传参数就这样调用：

```powershell
$sb = [scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '.\install.ps1')); & $sb -Dest 'D:\SCM' -NoCommand
```

`install.ps1` 会校验下载到的包是不是真 zip（魔数 `PK`），并**校验 SHA256**：设了 `SCM_EXPECT_SHA256` 就用你给的哈希，否则自动取 `<包>.sha256` 侧车；两者都没有时会明确提示"本次未校验来源"并把本次哈希打出来供比对。内网镜像可以用 `SCM_MIRROR_*` 环境变量指向你自己的源。

### 还没做 / 做不到的

- **没有受信任 CA 的代码签名证书**：签名链路已经通了（`Sign-GuiReady.ps1`），但用自签名证书只能证明"没被改过"，不能证明"是谁发的"。拿到正式证书后直接 `pack.ps1 -Sign -Thumbprint <指纹>` 即可，不需要改代码。
- **发布页的 SHA256 仍需人工核对**：`install.ps1` 会自动校验侧车文件，但侧车本身也是从同一处下载的 —— 真正可信的根是**你自己从发布页抄下的 SHA256**（用 `SCM_EXPECT_SHA256` 传给它）。
- **安装目录只查了 ACL 可写性，没查所有权（owner）**：极端情况下 owner 可以改 ACL 再写文件，还需要补一层 owner 校验。
- **提权计划任务跑完不删任务定义**（脚本/日志/结果文件已清理），排查时可以用 `Get-ScheduledTask GuiReady*` 看。

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
4. **不是远程桌面方案的替代品** —— 本工具是在 Server Core 本机补齐图形能力，程序在本机渲染。若想做「无头机器上跑 GUI、通过网络看画面」（IDD 远程渲染方向），属于另一个方向。
5. **Electron 程序的 GPU 加速用不上** —— 只能走软件渲染，所以建议带上禁用 GPU 的参数。这是 Server Core 环境的客观限制，不是本工具的缺陷。
6. **FOD 从 Windows Update 下载体积较大且对网络敏感**，可能失败。工具内置了常见错误码的中文处置建议（`0x800f0954` / `0x800f0831` / `0x80240021` 等）。
7. **Windows Terminal 在 Server Core 上不可用**（实测）：它是 XAML 程序，Server Core 缺 `Windows.UI.Xaml.dll` / `twinui.dll` / `WinUX.dll` —— MSIX 版注册失败（`0x80073CF6` + `0x80040154`），ZIP 免安装版启动即崩（`e06d7363`）。FOD 也补不上（2025 Core 上 Windows Update 路径被 CBS 拒绝）。**因此本工具已彻底移除 Windows 终端相关功能与离线包**，改为「终端美化」——把 conhost 本身做漂亮（见上一节）。

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
├─ install.ps1                  命令行一行安装（远程拉取发布包；校验 PK 魔数 + SHA256）
├─ pack.ps1                     打包发布（生成 manifest.sha256 与 <zip>.sha256；-Sign 顺便签名）
├─ Sign-GuiReady.ps1            签名 / 生成清单 / 校验（-CreateSelfSigned 造证书，-Verify 只校验）
├─ 签名\                        给 .exe 用的 signtool 包装脚本（需 Windows SDK；本项目用不到）
│
├─ manifest.sha256              发布包里的完整性清单（打包时生成，逐个文件 SHA256）
├─ ui\                          原生界面（C#，csc 现场编译）
│   ├─ Shell.cs                 主窗口：标题栏 / 侧栏 / 28 页宿主 / 日志栏 / 退出即开终端
│   ├─ Pages.cs, Pages2.cs      总览 / 环境 / 日志 / 任务 / 程序 / 档案 / 角色 / 安全 / 工具 / 美化 / 审计 / 远程 / 关于
│   ├─ ToolsPage.cs             SCM附属（附属工具下载：GitHub 源码 / Gitee 编译包）
│   ├─ StorePage.cs             应用商店（卡片墙 + 筛选 + 批量队列）
│   ├─ RuntimePage.cs           运行库
│   ├─ DatabasePage.cs          数据库（含建库 / 还原）
│   ├─ OpsPage.cs               自动化（守护 / 计划 / 备份 / 巡检 / 下载）
│   ├─ SysPage.cs               系统管理页面的公共骨架（表 + 多个视图 + CSV 导出）
│   ├─ SysPages.cs              系统更新 / 网络 / 账户 / 服务 / 防火墙 / 存储 / 系统任务 / 角色工具 / 通知
│   ├─ ActionConsole.cs         全部功能（动作台）+「高级」弹窗
│   ├─ Bridge.cs                界面 ↔ PowerShell runner 的 JSON 桥
│   ├─ Theme.cs, Draw.cs, Controls.cs, Table.cs, Dialog.cs, Backdrop.cs …
│   └─ build-ui.ps1             用系统自带 csc.exe 编译（自动补 UTF-8 BOM）
├─ gui\
│   ├─ GuiReady.GuiApp.ps1      主界面（含 -SelfTest / -LayoutDump 诊断开关）
│   ├─ GuiReady.Actions.ps1     155 个动作的清单（两套界面与无头执行器共用同一份）
│   ├─ GuiReady.Ui.ps1          设计系统：Token 组件 + 子进程查询宿主 + 列表行
│   ├─ Run-GuiReadyAction.ps1   动作执行器（子进程运行，界面不卡）
│   ├─ Run-GuiReadyStore.ps1    商店查询（子进程里查源状态 / 搜索，结果写 JSON）
│   ├─ Run-GuiReadyRole.ps1     角色查询（子进程里读角色/功能清单，结果写 JSON）
│   ├─ Run-GuiReadyMonitor.ps1  监控采集（子进程里取 CPU/内存/磁盘/服务/事件）
│   ├─ Run-GuiReadySecurity.ps1 安全审计（子进程里跑 10 项基线检查）
│   ├─ Run-GuiReadyRuntime.ps1  运行库（列表 / 安装 / 切换 / 卸载 / PATH）
│   ├─ Run-GuiReadyDatabase.ps1 数据库（状态 / 初始化 / 服务 / 备份 / 建库 / 还原）
│   ├─ Run-GuiReadyOps.ps1      自动化（守护 / 计划 / 备份 / 巡检 / 下载）
│   ├─ Run-GuiReadySys.ps1      系统管理（更新 / 网络 / 账户 / 服务 / 防火墙 / 存储 / 任务 / 角色工具 / 通知）
│   ├─ Run-GuiReadyPlugins.ps1  附属工具（清单 / 本地状态 / GitHub + Gitee 下载）
│   ├─ Run-GuiReadyIntegrity.ps1 启动时的文件清单核对
│   ├─ Run-GuiReadyDsh.ps1      dsh-TUI 依赖检查（含 npm 实查包名）
│   └─ Run-GuiReadyProbe.ps1    环境探针（子进程里查环境，卡片不再卡界面）
│
├─ setup\
│   └─ console\                 终端美化用的主题（字体与 exe 首次美化时按需下载）
│
├─ store\
│   └─ catalog.json             应用商店精选清单（24 条，含兼容性凭据）
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
│   ├─ GuiReady.Console.ps1     终端美化（Nerd Font + Oh My Posh + Fastfetch，含一键还原）
│   ├─ GuiReady.GuiTest.ps1     GUI 能力自检 + 窗口截图取证
│   ├─ GuiReady.Pipeline.ps1    一键流程
│   ├─ GuiReady.Catalog.ps1     程序兼容档案读取
│   ├─ GuiReady.Package.ps1     应用商店：包管理器检测 / 搜索 / 安装 / 卸载
│   ├─ GuiReady.Role.ps1        角色与功能：能力探测 / 列表 / 安装 / 移除
│   ├─ GuiReady.Monitor.ps1     系统监控：快照采集（只读）+ 服务控制
│   ├─ GuiReady.Security.ps1    安全合规：10 项基线检查 + 有限的自动修复
│   ├─ GuiReady.Integrity.ps1   完整性：文件清单（SHA256）+ 脚本签名校验 + 目录权限汇总
│   ├─ GuiReady.Runtime.ps1     运行库：多版本解压 / junction current / PATH
│   ├─ GuiReady.Database.ps1    数据库：解压 / 初始化 / 服务 / 建库 / 备份 / 还原
│   ├─ GuiReady.Ops.ps1         自动化：守护 / 计划任务 / 备份 / 巡检 / BITS 下载
│   ├─ GuiReady.Update.ps1      Windows Update（检查 / 安装 / 历史 / 自动更新策略）
│   ├─ GuiReady.Network.ps1     网络：网卡 / IP / DNS / 路由
│   ├─ GuiReady.Accounts.ps1    本地用户 / 组 / 登录会话
│   ├─ GuiReady.Services.ps1    服务：启停 / 启动类型 / 失败恢复 / 依赖
│   ├─ GuiReady.Firewall.ps1    防火墙规则与端口
│   ├─ GuiReady.Storage.ps1     磁盘 / 卷 / 卷影副本 / Windows Server Backup
│   ├─ GuiReady.SysTasks.ps1    系统计划任务
│   ├─ GuiReady.RoleTools.ps1   Hyper-V / IIS / 打印 / SMB 共享
│   ├─ GuiReady.Notify.ps1      通知（SMTP / Webhook / DPAPI 密码）
│   ├─ GuiReady.Plugins.ps1     附属工具清单 / 双线路下载 / 解压替换
│   ├─ GuiReady.Dsh.ps1         DeepSeek Harness：依赖检测 / 安装 / 启动
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

## 支持作者

这个工具是免费的、开源的（GPL-3.0），没有付费功能，也没有广告。如果它确实帮你省下了折腾 Server Core 的时间，可以请作者喝杯咖啡 —— 微信收款码见 **[docs/helpus.md](docs/helpus.md)**。

赞助完全自愿，不影响任何功能，也不影响提 issue 的处理顺序。

还有更省事的支持方式：把使用体验、踩到的坑写进 [Issues](https://github.com/OrangeArtc0915/Server-core-manager/issues)，或者告诉身边同样在折腾 Server Core 的人。

---

## 许可证

[GPL-3.0](LICENSE) —— 自由使用、修改、分发；分发衍生作品时需按 GPL-3.0 提供对应源码，并保留版权与许可声明。

本项目包含的所有「实测结论」都来自真实环境的测试记录，欢迎提交你验证过的机型与程序档案（`lib/catalog.json`）。

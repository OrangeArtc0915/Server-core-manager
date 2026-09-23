# Server Core Manager v1.1.0

**让带图形界面的程序，在 Windows Server Core 上真正跑起来。** 启动提速 + 动作精简 + 终端美化收尾。

Windows Server Core 没有桌面、没有 `explorer.exe`、没有 `dwm.exe`。本工具把「补全图形环境 → 添加程序 → 启动并排障」做成一键操作，并且自带图形界面。

项目主页（介绍、截图、实测数据）：**https://orangeartc0915.github.io/Server-core-manager/**

> 作者：**mmm** ｜ QQ 群：**1034243331**
> 源码：<https://github.com/OrangeArtc0915/Server-core-manager>
> 国内下载（Gitee）：<https://gitee.com/orangearc655743/server-core-manager/releases>
> Gitee 上**没有源码**，只放了一个安装脚本 `install.ps1` 与发布包

---

## 本次更新（v1.1.0）

**启动提速：环境探测挪到后台（实测冻结降 82%）**

- 根因：启动时那一轮环境探测（DISM 查 FOD 3.7 s、组件扫描 0.3 s、.NET/会话/自动登录/UAC 0.65 s）**跑在界面线程上**，实测要 5~6.5 秒，表现就是「窗口出来了但点不动」
- 现在：探测交给独立子进程 `gui\Run-GuiReadyProbe.ps1`，分两次回填卡片 —— 2 秒左右先出 6 张（FOD 值按组件推断，卡片上标「（推断）」），约 5 秒后 DISM 精确值补上
- 上次结果缓存到 `state\env-cache.json`：**第二次以后启动，卡片先用上次结果秒显**，后台静默刷新
- 实测（Win11，同代码，14 秒观测窗）：界面累计冻结 **2613 ms → 447 ms**，单次最长 **1086 ms → 228 ms**
- 其它小改：切页/动作结束时不再同步触发探测；工具页 21 个工具的路径解析改到真正看工具页时再做；启动时把重复的布局计算合并成一次
- 想自己看明细：设 `SCM_BOOT_TRACE=1` 启动，各阶段耗时写入 `state\boot-trace.txt`

**退出行为：关窗自动给一个终端**

- 点窗口 X / Alt+F4 /「退出（打开终端）」按钮 / Esc —— 四种关闭方式统一：关掉界面后自动打开
  **美化终端 `scm-term`**（UTF-8 + Nerd Font + oh-my-posh），没装美化终端就开普通 PowerShell
- 本机没有 sconfig.cmd 的场景也一样有效，不会关掉窗口就什么也没有

**精简：先去掉 9 个功能，再加回 1 个（37 → 29 个）**

- 去掉 **Gui-Shell 路线 2 个**：「用安装介质补全 Server-Gui-Shell」+「回滚」—— 该路线在真正的 Server Core SKU 上不存在，已实测判定不可行
- 去掉 **信息展示类 2 个**：「版本适配矩阵与能力差距」+「阶段 B（IDD 远程渲染）准备指引」（环境页的「结论路线」按钮一并去掉）
- 去掉 **旧的/重复项 5 个**：「启动图形启动器（旧版小面板）」+「一行命令：状态 / 安装 / 卸载」+「终止流程」
- 对应模块（`GuiReady.Matrix/GuiShell/Command/PhaseB`）**保留**：旧的控制台菜单与「一键流程」还在用它们
- Windows Admin Center 那 4 个功能按你的选择**保留**

**移除：Windows 终端功能**（实测在 Server Core 上用不了，见文末），界面、动作清单、模块与离线包一并删除。

- 「工具」页不再有 Windows Terminal 入口；「更多」页少了 6 个终端动作（安装 / 状态 / 取证 / 默认终端 / 打开 / 卸载）
- 发布包体积随之减小：`setup\terminal\` 的 3 个离线包（约 32 MB）不再分发

**新增：终端美化 —— 在 Server Core 上把 conhost 打扮好看**

- **Nerd Font（MesloLGS NF）+ Oh My Posh + Fastfetch**，素材全部内置在发布包 `setup\console\`（约 32 MB），安装**不联网**
- 入口命令 **`scm-term`**：先 `chcp 65001`、再用 Console API 应用字体，然后启动带 oh-my-posh 的 PowerShell
- 新增 **5 个功能**：状态检查（含实测回读 conhost 真实字体）、一键美化终端、打开美化终端、一键还原、安装 PowerShell 7（**走清华镜像**）
- 「工具」页新增「美化终端」按钮（没装会标「（缺失）」并变浅色，点它会提示去哪装）；`HKCU\Console` 改动前会**自动备份**，「一键还原」可退回

**新增：关于页**

- 侧栏新增「关于」页：作者 **mmm** / QQ 群 **1034243331** / GitHub / 项目主页（链接可点）
- 侧栏底部原来的作者信息区已移除（不再占用界面左下角）
- 4 个快捷按钮：打开 GitHub / 打开项目主页 / 打开日志目录 / 打开报告目录

**修复：工具页按钮**

- 「工具」页按钮点击整段加 try/catch：以前「路径解析」抛异常会让点击处理静默死掉，表现就是**点了没反应**
- 每次点击先落一行 `[STEP] 点击工具: xxx` 日志；切到工具页会打印 `工具页: 共 N 个，可用 M 个，缺失 K 个（...）`，出问题看一眼日志就知道是「没触发」还是「启动失败」
- 单个工具解析失败不再影响整页其它按钮

**为什么必须走 `scm-term`（实测）**：中文控制台代码页 936 下，conhost **只接受自带中文字形的字体** —— `MesloLGS NF` 和 `Consolas` 都被拒（API 返回成功但实际回退「新宋体」）；切到 UTF-8 后同一个 Nerd Font 立刻被接受（回读 `face=[MesloLGS NF]`）。`HKCU\Console\CodePage` 与「按标题记忆」两种写法对新建控制台都不生效。

**界面与体验**

- 「工具」页精简：默认只列 **7 个**本机工具；与 Windows Admin Center 重复的 **14 个**管理工具收进「Windows Admin Center 里也有」一组（默认收起；本机装了 WAC 且服务在运行时**整组隐藏**）
- 提速：环境卡片加 45 秒缓存 + 轻量查询 —— 切页刷新从 **2~4 秒 → 几乎瞬时**；WAC 卡片 **3.6 秒 → 0.6 秒**；.NET 卡片 **109 ms → 13 ms**；窗口**先画出来**再补数据
- **关窗自动给终端**：点窗口 X / Alt+F4 / 点「退出（打开终端）」按钮 / 按 Esc —— 四种关闭方式行为统一，关掉界面后自动弹终端（装了美化终端 → `scm-term`：UTF-8 + Nerd Font + oh-my-posh；没装 → 普通 PowerShell），不再把人丢在 Server Core 的空会话里。后台任务不会被关窗打断；`-SelfTest` / `-LayoutDump` 不弹

**国内源**

- PowerShell 7 优先从**清华 TUNA 镜像**取（本机实测是真文件 `application/zip`、101 MB），失败自动回退 GitHub 官方
- 支持自建源环境变量：`SCM_MIRROR_GITHUB` / `SCM_MIRROR_TUNA` / `SCM_MIRROR_DOTNET`（`install.ps1` 也认 `SCM_MIRROR_GITHUB`）
- 实测结论（逐个验过，不是凭印象）：清华 / 阿里云 / 华为云**没有** .NET 与 oh-my-posh/fastfetch 的真文件镜像（404 或门户 HTML）；微软官方 CDN 国内直连约 470~720 KB/s；清华镜像了 PowerShell，但**会拒绝部分网络**（实测有网络被返回 403，响应头 `X-TUNA-MIRROR-ID: neomirrors`）—— 这种网络用「指定本地 zip」即可
- 所以能内置的都内置了：终端美化素材（约 32 MB）随发布包分发，安装**不联网**

**作者信息**：控制台横幅、安装完成提示，以及界面里的**「关于」页**都会显示「作者 mmm / QQ群 1034243331 / GitHub 地址」（界面里的链接可点击直接打开）

**新增：任何终端窗口都显示两个入口提示（黄色，清屏后自动重显）**

- cmd 与 PowerShell 打开时都会打印（**黄色**）：
  `输入 "Sconfig" 返回服务器菜单` / `输入 "scm" 打开 GUI 工具`
- **执行 `cls` / `clear` 清屏后自动重新显示在顶部**：PowerShell 覆写 `global:Clear-Host`（`cls` 是它的别名，一起生效），cmd 用 `doskey cls=cls $T <脚本> --force` 宏接管 `cls`（宏是进程级的，所以在 AutoRun 里每次启动都注册一次；脚本带 `--force` 分支跳过防递归判断）
- cmd 走 `HKCU\Software\Microsoft\Command Processor\AutoRun`（原值会先备份到 `backup\cmdAutoRun-*`），PowerShell 走 profile 的 managed block；随「一键美化终端」一起安装，「一键还原」会一起移除
- **非交互式保持安静**：`cmd /c ...` 不会多这两行（否则会污染脚本抓取的输出），PowerShell 侧用 `[Console]::IsOutputRedirected` 判断
- 说明：终端本身没有“固定行”的概念，滚动后没法把提示钉在窗口顶部；能做到的是清屏/新开窗口时回到顶部。cmd 侧的黄色用 ANSI 亮黄（`ESC[93m`），依赖 `HKCU\Console\VirtualTerminalLevel=1`（「一键美化终端」会设置）
- 这三个坑是实测踩出来的（代码注释里也写明了，避免以后再犯）：
    1. **AutoRun 对每个新 cmd 实例都生效** —— 脚本里一旦出现管道或外部命令（比如 `echo X | find /i "/c"`），管道的子 cmd 又会跑 AutoRun → 实测 **2785 个 find + 2758 个 cmd 无限递归**，机器被拖死。现在第一行就用环境变量 `SCM_WELCOME_DONE` 打标记（子 cmd 继承后立刻退出），且只用 cmd 内建命令
    2. **cmd 的批处理解析器要求 CRLF** —— 本仓库源文件是 LF，here-string 里也是 LF，直接写出去得到 LF-only 的 .cmd，实测 cmd 会把它解析得乱七八糟（每行被拆断、报一堆 `xxx is not recognized`）。现在写入前强制归一化，并做写后自检（没有 CRLF 就放弃设置 AutoRun）
    3. **双引号 here-string 里的 `$_` 转义不可靠** —— 实测生成的 profile 把 `$_.Exception.Message` 的 `$_` 吃掉了，导致 **profile 语法错误、PowerShell 一启动就报错**。现在 profile 模板改成单引号 here-string + 占位符替换（零转义），并且每次安装会**先清掉所有历史 block 再写一份**（幂等，含清理历史上被写坏的“孤儿残留行”）

**修复**

- **从 sconfig 选「退出到命令行」后屏幕什么都没有**（真机定位）：这台机器的 `Winlogon\Shell` 被设成了 `explorer.exe`，而 Server Core 没有桌面栈 —— sconfig 退出时 Winlogon 按 Shell 重启 shell，去拉 explorer 就等于拉了个没有界面的进程，屏幕随即空白。Server Core 的正确做法是让 Shell 走 `servercoreshelllaunch.bat`（内容是 `powershell -noExit -Command Invoke-SConfigLogon`，即登录直接进 sconfig）。**处置**：新增「会话与登录 → 设置登录 Shell」动作，可选 自动进 sconfig / cmd.exe / 恢复原值（reg import 备份）/ 启动器 / explorer；写入前自动 `reg export` 备份到 `backup\shell-*`。真机验证：Shell 已回读为 `cmd.exe /c C:\WINDOWS\system32\servercoreshelllaunch.bat`，且实测该字符串能拉起 sconfig
- **美化终端一打开就报错**（`Program 'oh-my-posh.exe' failed to run: The specified executable is not a valid application for this OS platform`）：发布包里的 `setup\console\oh-my-posh.exe` **本身是个坏文件**（PE 结构在，但版本资源为空、Windows 加载器直接拒绝启动）—— 同一批的 `fastfetch.exe` 是好的，所以只有提示符起不来。已换成官方最新版（v31.3.0，`posh-windows-amd64.exe`）并实测 `--version` 正常。另外 profile 里的初始化块加了 try/catch：oh-my-posh 出问题时回退默认提示符，不会让 PowerShell 变成“什么都没有”
- **`scm-term` 里 fastfetch 参数名写错**：用了 `--key-length`，而 fastfetch 2.68.1 只认 `--key-width`（实测 `unknown option: --key-length`）。已改对
- **WAC 一键安装必然失败，并把 133 MB 安装包灌进日志**（真机定位后修的，就是「卡死 + 日志乱码」的根因）：`Start-Process -ArgumentList` **不会**给含空格的值自动加引号，而安装包路径是 `C:\Program Files\ServerCoreManager\payload\...`。于是 curl 收到的是 `-o C:\Program`，剩下的路径被当成 URL → 既报 `URL rejected: Bad hostname` 下不到东西，又把响应体直接写到 **stdout** —— stdout 正是 GUI 的日志文件，实测产生 **1,090,153 行**乱码，界面随即假死。同样的坑还在安装阶段（`msiexec /i <含空格路径>`、Inno `/LOG=<含空格路径>`）。现在 curl 与两个安装器的参数都手工加引号，并把 stdout 也重定向走。**实测结果**：WAC v2 一键安装成功 —— 下载 133.5 MB → Inno 静默安装退出码 0 → 防火墙放行 443 → 服务 Running/Auto → `/shell/` 探测 HTTP 302
- **`rdp-fix` 的防火墙放行在中文系统上必然失败**：代码按 `DisplayGroup = 'Remote Desktop'` 找规则，而这个组名是**本地化**的（中文系统上是“远程桌面”），实测直接抛「找不到 DisplayGroup 等于 Remote Desktop 的对象」。现在改成 英文组名 → 中文组名 → 按显示名/3389 兜底 → 一条都没有就自己建一条放行 TCP 3389 的规则；真机验证：英文名不匹配、中文名匹配到 3 条并成功启用
- **`lib\GuiReady.Wac.ps1` 缺 UTF-8 BOM**：中文注释在 ACP=936 下被按 GBK 解析，导致整个 WAC 模块函数加载失败，四个 WAC 动作全报 `The term 'Install-GuiReadyWac' is not recognized...`。已补 BOM（中文脚本一律带 BOM，`install.ps1` 除外）
- **动作跑久了界面卡死 + 日志狂跳**（真机量化后修的）：日志是每 400ms 用 `Get-Content` **重读整个输出文件**再追加新行。动作输出涨到几万行时，实测单次读取平均 **365 ms、峰值 815 ms**（已超过 400ms 的 tick 间隔）—— 界面线程几乎全耗在读文件上，越跑越卡直到假死。现在改成**增量读取**（StreamReader 停在文件末尾，只读新增；实测平均 **2 ms、峰值 31 ms**），另外日志面板只保留最近 3500 行、单次最多追加 300 行
- **「工具」页按钮点了没反应 / 报 `The term 'Start-SystemTool' is not recognized`**（真机复现后修的）：按钮的点击处理用了 `GetNewClosure()`，它会新建一个模块作用域，在里面看不到本脚本定义的函数。用 `powershell -File GuiReady.GuiApp.ps1` 直接跑时脚本函数落在全局作用域，所以**只有在真实启动链路**（`scm` → `Start-GuiReadyApp.ps1` 用 `&` 调用 GuiApp）下才会炸——这也解释了上一版为什么“点了没反应”（异常被静默吞掉）。现在改成「参数放进 `$Button.Tag` + 普通 scriptblock」，并在真实链路下用模拟点击实测通过
- **日志乱码**：curl、MSI、原生 exe 的输出带不带换行的进度（单独一个回车符），塞进 RichTextBox 会让光标回到行首反复覆盖，看起来就是乱码。现在日志写入前统一去掉回车符、并把超长行截断到 2000 字符
- 中文脚本缺 UTF-8 BOM：在中文系统（ACP=936）的 PowerShell 5.1 下会乱码，个别脚本甚至**解析失败**（`Start-GuiReady.ps1` 实测 47 处报错）—— 现已补 BOM。`install.ps1` 仍然**不加** BOM，因为 `irm | iex` 会被 BOM 破坏（脚本头部已注明）

**Windows Terminal 在 Server Core 上的最终结论（实测，非推测）—— 这就是功能被移除的原因**

- 装好 App Compatibility FOD 并重启后，Server Core **仍然缺** `Windows.UI.Xaml.dll` / `twinui.dll`（`WinUX.dll`、`explorer.exe`、`regedit.exe` 同样不在）
- MSIX 打包版三条安装路径全部失败：交互式会话 `0x80073CF6`（→ `0x80040154` 初始化 windows.capability 扩展时没有注册类）、WinRM/Session 0 `0x80073D19`+`0x8007007E`、DISM 预置包 `0x8007007E`
- ZIP 免安装版（自带 UI.Xaml）进程起来后立即 APPCRASH（KERNELBASE `e06d7363`），0 个可见窗口
- 顺带确认 WT 1.24 的包要求 `Windows.Desktop ≥ 10.0.19041` —— **Server 2016/2019 也直接排除**
- **处置**：相关界面入口、6 个动作、`lib\GuiReady.Terminal.ps1` 与 `setup\terminal\` 离线包**全部删除**；想要好看的终端请用「更多 → 终端美化」

---

## 下载哪个文件

| 文件 | 用途 |
|---|---|
| **`ServerCoreManager.zip`** | 压缩包安装用。**就下这个**（固定名字，`install.ps1` 也是按这个名字取） |
| `ServerCoreManager-v1.1.0.zip` | 内容相同，只是文件名带版本号，方便留档 |
| `Source code (zip/tar.gz)` | GitHub / Gitee 自动生成的源码包，普通用户不需要 |

两个 zip 内容完全一致，52 个文件，解压后直接可用。

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

两条线路装的是同一个发布包。脚本里的下载顺序是 **GitHub Releases → Gitee Releases → GitHub 分支源码打包**，前一条不通、或拿到的不是真 zip 就自动换下一条（Gitee 对不存在的下载路径会返回 `200` + 一段 JSON，所以脚本按 zip 魔数 `PK` 校验内容，不是只看状态码）。

装到 `C:\Program Files\ServerCoreManager`，并安装 `scm` 一行命令。之后**在任意目录输入 `scm` 回车**即可打开图形界面（首次会像 `sconfig` 一样弹一次提权确认）。

改默认值用环境变量（`iex` 没法传参）：

```powershell
$env:SCM_DEST = 'D:\SCM'      # 改安装目录
$env:SCM_NO_COMMAND = '1'     # 不装 scm 命令
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

重复执行等于**升级**：只覆盖程序文件，不动你的程序列表、日志和断点状态。

---

## 安装方式二：压缩包

1. 下载上面的 `ServerCoreManager.zip`
2. 解压到任意目录，例如 `D:\ServerCoreManager`
3. 右键 **以管理员身份运行** `一键运行.bat`

> 手工解压后如果 PowerShell 拒绝执行脚本，是包带了「来自 Internet」标记。在工具目录里跑一次：
> `Get-ChildItem -Recurse *.ps1 | Unblock-File`
> （命令行安装方式会自动做这一步）

---

## 这个版本包含

- **图形界面**：环境 / 软件 / 工具 / 更多 / 关于 **五个页面**，7 张状态卡片，全部 **29 个功能**收在「更多」里
- **21 个系统工具入口**：默认列 **7 个**本机工具（记事本、命令提示符、美化终端、MMC 控制台、资源监视器、系统信息、PowerShell ISE），另 **14 个**与 Windows Admin Center 重复的收在一组里（默认收起、装了 WAC 则隐藏）……本机没有的标「（缺失）」并变浅色，**点了仍会有反应**（说明怎么补 / 要不要用命令提示符代替）
- **终端美化（Server Core 上的推荐方案）**：把 conhost 本身做漂亮 —— 内置 `setup\console\`（Nerd Font + Oh My Posh + Fastfetch），一键写入 `HKCU\Console` 与 PowerShell profile（可一键还原），入口命令 `scm-term`
- **一键补全环境**：走微软官方 **App Compatibility FOD**，支持跨重启断点续跑
- **程序兼容档案**（`lib/catalog.json`）：按 PE 头识别 .NET / Electron / WPF / 原生，自动带入**实测推荐参数**
- **启动诊断**：程序起不来时查事件日志、WER 记录、缺失的 DLL/运行时，并给处置建议
- **Windows Admin Center 一键安装并自动配置**：本地没安装包时自动从官方下载（约 140 MB），自动识别 MSI / v2 两代安装器，装完自动放行防火墙、设为自启、启动服务并探测 `/shell/`
- **自动登录**：密码写入 LSA 机密，不以明文落注册表
- **.NET 运行时免安装补齐**：zip 方式部署，不写注册表、不进控制面板

### 实测数据（Windows Server 2022 Core，build 20348.2700）

| 程序 | 结果 |
|---|---|
| 腾讯 QQ NT 9.9.35（Electron） | 加 `--disable-gpu --disable-software-rasterizer` 后首窗口 **6.0 s**（默认 18.2 s），CPU 时间 **4.6 s**（默认 30.5 s） |
| MSLX-Daemon（.NET 10 / ASP.NET Core） | 补齐 .NET 10.0.12 后 Kestrel 正常启动，Web 控制台渲染与登录正常 |
| 自动登录闭环 | LSA 机密 + 真实重启 → 自动登录 console 会话 → GUI 自检通过（整屏截图非黑 98.2%） |

---

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows Server 2016 / 2019 / 2022 / 2025 **Core** |
| PowerShell | 5.1 或更高（系统自带即可） |
| 权限 | 管理员 |
| 磁盘 | 建议 C: 至少 5 GB 可用 |
| 网络 | 装 FOD 需要能访问 Windows Update（离线环境可用 FOD ISO 配 `-Source`） |

---

## 已知限制（请先看这里）

1. **UWP / XAML 应用不行** —— 补齐 FOD 后仍缺 `twinui.dll`。
2. **界面是经典主题样式** —— 缺 `themeservice.dll` / `themeui.dll`，窗口不会应用现代主题。
3. 「桌面体验专属」23 个组件**补齐后仍缺 4 个**：`twinui.dll`、`themeservice.dll`、`themeui.dll`、`DispBroker.dll`。
4. **不是远程桌面方案的替代品** —— 本工具是在 Server Core 本机补齐图形能力，程序在本机渲染。想让无头机器上的 GUI 通过网络传输画面，属于另一个方向。
5. **Electron 程序用不上 GPU 加速**，只能走软件渲染，所以建议带禁用 GPU 的参数。这是 Server Core 的客观限制。
6. FOD 从 Windows Update 下载**体积较大且对网络敏感**，可能失败；工具内置常见错误码的中文处置建议。

---

## 如果下载不通

`raw.githubusercontent.com` 在部分网络下（尤其是国内）会连不上，或者被本地加速器缓存住、一直返回旧版本。遇到这种情况：

1. **别用一行命令，直接下载本页的 `ServerCoreManager.zip`**。解压后以管理员身份运行 `一键运行.bat`，功能与一行安装完全一样。
2. 或者把 `install.ps1` 存成本地文件再运行，通过环境变量传参（`$env:SCM_DEST` 等）。

已经装过旧版本的话，重新下载 zip 覆盖解压也是升级方式，不会动你已有的程序列表、日志和断点状态。

---

## 反馈

遇到问题请附上这三样，定位会快很多：

1. 系统版本：`Get-ComputerInfo | Select OsName, OsVersion, WindowsBuildLabEx`
2. 工具里的**「更多 → 排障采集」**产出的报告（默认在 `reports\` 下）
3. 出问题的程序名，以及「启动诊断」的输出

欢迎提交你验证过的程序档案到 `lib/catalog.json`。

---

## 许可证

[GPL-3.0](https://github.com/OrangeArtc0915/Server-core-manager/blob/main/LICENSE) —— 自由使用、修改、分发；**修改后分发必须同样以 GPL-3.0 开源**。

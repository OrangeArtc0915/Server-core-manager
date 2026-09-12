# Server Core Manager v1.0.0

**让带图形界面的程序，在 Windows Server Core 上真正跑起来。** 首个公开版本。

Windows Server Core 没有桌面、没有 `explorer.exe`、没有 `dwm.exe`。本工具把「补全图形环境 → 添加程序 → 启动并排障」做成一键操作，并且自带图形界面。

项目主页（介绍、截图、实测数据）：**https://orangeartc0915.github.io/Server-core-manager/**

---

## 下载哪个文件

| 文件 | 用途 |
|---|---|
| **`ServerCoreManager.zip`** | 压缩包安装用。**就下这个**（固定名字，`install.ps1` 也是按这个名字取） |
| `ServerCoreManager-v1.0.0.zip` | 内容相同，只是文件名带版本号，方便留档 |
| `Source code (zip/tar.gz)` | GitHub 自动生成的源码包，普通用户不需要 |

两个 zip 内容完全一致，35 个文件，解压后直接可用。

---

## 安装方式一：命令行一行安装

在**管理员** PowerShell 里执行：

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

装到 `C:\Program Files\ServerCoreManager`，并安装 `scm` 一行命令。之后**在任意目录输入 `scm` 回车**即可打开图形界面（首次会像 `sconfig` 一样弹一次提权确认）。

改默认值用环境变量（`iex` 没法传参）：

```powershell
$env:SCM_DEST = 'D:\SCM'      # 改安装目录
$env:SCM_NO_COMMAND = '1'     # 不装 scm 命令
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
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

- **图形界面**：环境 / 软件 / 工具 / 更多 四个页面，7 张状态卡片，全部 32 个功能收在「更多」里
- **20 个系统工具入口**：记事本、文件资源管理器、任务管理器、服务、设备管理器、事件查看器、注册表编辑器、Hyper-V 管理器……按系统里实际有没有自动灰显
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

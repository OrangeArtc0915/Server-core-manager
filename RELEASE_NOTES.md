# Server Core Manager v2.4

**让带图形界面的程序，在 Windows Server Core 上真正跑起来。**

v2.3 为了不与 Windows Admin Center 重复，把 8 个页面整组拿掉了。这一版把它们**按系统版本重新分配**：2019 及以上继续隐藏，2019 以下放回来（那些机器装不了 WAC 网关），并把兼容目标下探到 **2008 R2 SP1**。同时加入**程序自更新**。

> 只有 **Windows Server 2022 Core** 做过完整实测。**2019 以下版本（2008 R2 / 2012 / 2012 R2 / 2016）未经真机验证**：兼容路径已经实现，但不保证每个功能都可用。

---

## 本次变化（v2.4）

### 按版本显示页面

首次启动会让你选系统档位，之后可在「设置 → 版本与显示」随时改：

| 档位 | 页面变化 |
|---|---|
| **2019 及以上** | 隐藏与 WAC 重复的 8 页（系统更新 / 网络配置 / 本地账户 / 服务管理 / 防火墙 / 存储与备份 / 系统任务 / 日志中心），共 27 页、151 条动作 |
| **2012 R2 – 2016** | 8 页放回来；隐藏依赖 App Compatibility FOD 与补全 DLL 的 4 页，182 条动作 |
| **2008 R2** | 在上一档基础上，存储页降为只读（隐藏初始化 / 扩展 / 格式化 3 条写动作），179 条动作 |

两个显示开关也可以单独关掉，页面与「全部功能」里的动作会一起变。

### 程序自更新

- GitHub / Gitee 双线路检查，默认 24 小时缓存，启动时静默检查（可在设置里关）
- 下载整包后在进程退出后替换，**保留用户数据**：程序列表、日志、报告、断点状态
- 校验 `.sha256` 侧车，对不上就中止；替换失败自动回滚并留标记
- 不强制更新，设置页与关于页都有入口

### 2008 R2 兼容路径

- 网络：WMI + `netsh`（IPv4 地址 / 网关 / DNS / 路由 / 网卡启停）
- 防火墙：`HNetCfg.FwPolicy2` COM + `netsh`（规则读取、启停、删除、新建）
- 计划任务：`Schedule.Service` COM（枚举、详情、启停、运行、删除）
- 本地账户：WMI + `net user` / `net localgroup`
- 存储：WMI 只读展示，写操作直接拒绝
- 端口：`netstat` 解析（TCP / UDP）
- 安装包会先检查 .NET Framework 与 WMF 5.1，缺了提示运行 `Setup-LegacyPrereq.cmd` 并重启

### 其他

- 补全 DLL 增加 **32 位（WOW64）** 一套：2019 / 2022 / 2025 的 `twinui.dll` / `themeui.dll` / `DispBroker.dll`，32 位程序不再缺组件
- 版本判定统一走 build 号：≥ 17763 为 2019+，≤ 7601 为 2008 R2，其余为中间档
- 设置页重排为可滚动布局，更新与版本策略放在最上面

---

## 安装

两条线路任选，装的是同一个发布包（默认 `v2.4`）：

**Gitee（国内推荐）**

```powershell
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

**GitHub**

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

重复执行安装等于升级，不会动已有的程序列表、日志与断点状态。

发布包旁带 `ServerCoreManager.zip.sha256`；`install.ps1` 会自动取侧车校验，哈希不一致会中止且不解压。

---

## 已知限制

- **2019 以下版本未经真机验证**：2008 R2 / 2012 / 2012 R2 / 2016 只有兼容路径，没有验收结论；`Setup-LegacyPrereq.cmd` 同样未验证
- 2008 SP2 及更早不支持（装不了 WMF 5.1）；2008 R2 需要 SP1
- 2019 以下装不了 App Compatibility FOD / Windows Admin Center，相关页面会自动隐藏
- 部分桌面体验组件仍缺 4 个（`twinui.dll` / `themeui.dll` / `themeservice.dll` / `DispBroker.dll`），UWP / XAML 应用与部分 Electron 程序仍不可用
- Windows Terminal 不能跑在 Server Core 上（缺 AppX 部署与 XAML / Composition 组件），工具提供的是 conhost 美化方案
- 数据库服务注册、计划任务、系统备份等写操作需要管理员

## 源码

<https://github.com/OrangeArtc0915/Server-core-manager>

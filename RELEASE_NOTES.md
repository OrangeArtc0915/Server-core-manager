# Server Core Manager v2.3

**让带图形界面的程序，在 Windows Server Core 上真正跑起来。**

这一版没有加新页面，反而**删掉了 8 个和 Windows Admin Center 重复的页面**：系统更新、网络配置、本地账户、服务管理、防火墙、存储与备份、系统任务、日志中心。

> WAC 已经做得很好的事，就不重复造了。本工具只保留 WAC 没有的能力。

---

## 本次调整（v2.3）

- 页面：35 → **27**
- 动作：200 → **151**
- 动作分组：45 → **37**
- CLI 移除 `scm update`（需要打补丁请直接用 Windows Update / WAC）
- 导航、动作目录、PowerShell 回退界面同步移除；实现保留在代码里，方便以后回滚

保留的重点能力：

- **环境补全**：官方 App Compatibility FOD、GUI 自检、自动登录、WAC 一键安装
- **程序**：程序管理、PE 头识别、兼容档案、实测启动参数
- **运行库 / 数据库**：Node / Python / Go / Java / PHP / Bun，多版本共存；PostgreSQL / MySQL 解压即用
- **诊断工具**：监听端口、端口扫描、DNS、连通性、代理、pktmon 抓包；进程树、快照与结束进程
- **软件与权限**：软件清单 / 静默卸载、SMB 共享授权、NTFS ACL
- **监控告警**：性能历史与 HTML 报表、阈值 / 事件规则、维护窗口静默
- **系统维护**：证书、驱动与硬件、启动项、系统状态备份
- **批量 / 脚本 / 报告**：远程批量采集、执行、装包、传文件、分发脚本；内置脚本库；报告打包与每日任务
- **自动化与审计**：进程守护、计划任务、目录备份、端口巡检、BITS 下载队列；操作审计

## 安装

两条线路任选，装的是同一个发布包（默认 `v2.3`）：

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

- 部分桌面体验组件仍缺 4 个（`twinui.dll` / `themeui.dll` / `themeservice.dll` / `DispBroker.dll`），UWP / XAML 应用与部分 Electron 程序仍不可用
- Windows Terminal 不能跑在 Server Core 上（缺 AppX 部署与 XAML / Composition 组件），工具提供的是 conhost 美化方案
- 数据库服务注册、计划任务、系统备份等写操作需要管理员

## 源码

<https://github.com/OrangeArtc0915/Server-core-manager>

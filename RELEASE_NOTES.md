# Server Core Manager v2.5

**让带图形界面的程序，在 Windows Server Core 上真正跑起来。**

这一版没有加新功能，做的是"搬家"：项目从个人账号迁到组织 **Server-Core-Mananger**，官网换域名，安装与自更新地址全部切到新仓库，同时把四个子项目拆成独立仓库。

> 只有 **Windows Server 2022 Core** 做过完整实测。**2019 以下版本（2008 R2 / 2012 / 2012 R2 / 2016）未经真机验证**：兼容路径已经实现，但不保证每个功能都可用。

---

## 本次变化（v2.5）

### 仓库迁移

- 主项目：`OrangeArtc0915/Server-core-manager` → `Server-Core-Mananger/Server-core-manager`
- 官网：拆到独立仓库 `Server-Core-Mananger/server-core-mananger.github.io`，地址变为 <https://server-core-mananger.github.io/>
- 子项目各自独立成仓库：`scterm`、`Textm`、`TuiMonitor`、`craftdock`
- 旧仓库地址由 GitHub 自动 301 到新仓库，历史 Release、tag、issue 全部保留

### 地址切换

- `install.ps1` 的 GitHub 下载地址、Release 地址、自更新检查地址全部指向组织
- Gitee 线路同步更新，仍作为国内备用源
- 界面「关于」页与官网所有链接改为新地址，不再出现旧账号链接

### craftdock

- 独立仓库：<https://github.com/Server-Core-Mananger/craftdock>
- 包名 `mcsmanager-daemon` / `mcsmanager-common` → `craftdock-daemon` / `craftdock-common`
- 作者与版权：mmm、OrangeArc655743、OrangeArtc0915，Apache-2.0

### 版本

- 安装包默认版本 `v2.5`，界面标题、关于页同步显示 v2.5

---

## 安装

两条线路任选，装的是同一个发布包（默认 `v2.5`）：

**Gitee（国内推荐）**

```powershell
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

**GitHub**

```powershell
irm https://raw.githubusercontent.com/Server-Core-Mananger/Server-core-manager/main/install.ps1 | iex
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

<https://github.com/Server-Core-Mananger/Server-core-manager>

# Server Core Manager v2.2

**让带图形界面的程序，在 Windows Server Core 上真正跑起来。** 本版把日常运维闭环补齐：监控告警、系统维护、诊断工具、软件与权限、批量管理、脚本库与报告中心。

Windows Server Core 没有桌面、没有 `explorer.exe`、没有 `dwm.exe`。本工具把「补全图形环境 → 添加程序 → 启动并排障」做成一键操作，并且自带图形界面。

项目主页（介绍、截图、实测数据）：**https://orangeartc0915.github.io/Server-core-manager/**

> 作者：**mmm** ｜ QQ 群：**1034243331**
> 源码：<https://github.com/OrangeArtc0915/Server-core-manager>
> 国内下载（Gitee）：<https://gitee.com/orangearc655743/server-core-manager/releases>
> Gitee 上**没有源码**，只放了一个安装脚本 `install.ps1` 与发布包

---

## 本版重点（v2.2）

界面 **35 个页面 / 200 个功能动作（45 组）**，新增或增强：

### 监控告警
- 性能历史采样落 CSV，生成内联 SVG 的 HTML 报表
- 阈值 / 事件告警规则、冷却时间、关键事件订阅
- **维护窗口**：窗口内告警静默，结束后自动恢复

### 系统维护
- **证书**：查看 / 导入 / 导出（cer / pfx）/ 删除 / 到期提醒
- **驱动与硬件**：驱动列表、问题设备、SMART、导出与还原
- **启动项**：注册表 / 启动文件夹 / 服务 / 计划任务
- **系统状态备份**：关键注册表与系统信息，默认不含驱动（约 4.5 MB），可复制到共享并保留 N 份

### 诊断工具
- 网络：监听端口、TCP 端口扫描、DNS 解析、连通性、代理设置、pktmon 抓包（转 pcapng）
- 进程：列表 / 进程树 / 详情 / Top 进程快照 / 历史 / 结束进程（关键进程保护）

### 软件与权限
- 软件清单（HKLM / HKLM32 / HKCU Uninstall）、导出 CSV、静默卸载
- SMB 共享授权与收回、NTFS ACL 查询与设置

### 批量管理 / 脚本库
- 对远程主机批量采集、执行命令、装包，新增**上传 / 下载文件、分发执行脚本**
- 内置清理临时文件 / 收集诊断包 / 重置网络 / 磁盘检查 / 导出资产清单，预览后执行

### 报告中心
- 统一列出 `reports\` 下的报表与诊断包
- 打包 ZIP（含 SHA256）、作为邮件附件发送、注册每日自动打包任务

### 命令行（scm）
- `scm status / metrics / alerts / backup / update / run / tools / certs / drivers / startup / batch / scripts`
- 所有命令支持 `--json`；不带参数仍打开图形界面

### 稳定性与体验
- 修复视图切换时表头列重复叠加
- 所有写操作走动作执行器：任务编号、退出码、完整日志与审计
- 发布包补齐 `scripts\`，脚本库开箱可用

---

## 安装

两条线路任选，装的是同一个发布包（默认 `v2.2`）：

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

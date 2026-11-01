---
title: 安装
description: 两种安装方式：管理员 PowerShell 里一行命令（Gitee / GitHub 两条线路），或者下载压缩包手动解压。
group: 入门
order: 1
---

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows Server 2016 / 2019 / 2022 / 2025 **Core**（实测 2022 Core build 20348.2700） |
| PowerShell | 5.1 或更高（系统自带即可，**不需要**先装 PowerShell 7） |
| 权限 | 管理员 |
| 磁盘 | 建议 C: 留 5 GB 以上（FOD 包 + 组件；装运行库 / 数据库再额外留空间） |

## 方式一：命令行一行安装

两条线路任选，装的是同一个发布包，脚本内容也一致。

**Gitee（国内推荐）**

```powershell
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

**GitHub**

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

脚本里的下载顺序是 **GitHub Releases → Gitee Releases → GitHub 分支源码打包**，前一条不通、或拿到的不是真 zip，就自动换下一条。

脚本会依次做四件事：下载发布包 → 解压到 `C:\Program Files\ServerCoreManager` → 解除「来自 Internet」的文件锁定 → 安装 `scm` 一行命令。

装完之后，**在任意目录输入 `scm` 回车**就能打开图形界面（首次会像 `sconfig` 一样弹一次提权确认）。

> [!NOTE]
> Gitee 对**不存在的下载路径**返回的是 `200` + 一段 JSON（实测 60 字节），而不是 404；随便编一个版本号也返回 200。所以脚本不只看 HTTP 状态码，还会按 zip 的魔数 `PK` 校验内容 —— 否则会安安静静下回来一个 JSON，直到解压才报错。

### 改默认值

`iex` 没法传参数，用环境变量（两条线路都适用，下面以 Gitee 为例）：

```powershell
$env:SCM_DEST = 'D:\SCM'      # 改安装目录（默认 C:\Program Files\ServerCoreManager）
$env:SCM_NO_COMMAND = '1'     # 不安装 scm 命令
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

走 GitHub 线路时，只把最后一行换成：

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

自建镜像 / 内网源见[国内源与离线使用](../sources/)。

## 方式二：压缩包

1. 从 [Gitee 发布页](https://gitee.com/orangearc655743/server-core-manager/releases) 下载 `ServerCoreManager.zip`
2. 解压到任意目录，例如 `D:\ServerCoreManager`
3. 右键**以管理员身份运行** `一键运行.bat`

> [!WARNING]
> 手工解压后如果 PowerShell 拒绝执行脚本（提示「未对文件进行数字签名」），是压缩包带了「来自 Internet」标记。在工具目录里跑一次 `Get-ChildItem -Recurse *.ps1 | Unblock-File` 即可。命令行安装会自动做这一步。

## 关于压缩包的体积

发布包约 14 MB，其中 **35 MB 是解压后的终端美化素材**（Nerd Font 字体 + `oh-my-posh.exe` + `fastfetch.exe`，压缩后约 10 MB）。

之所以把这么大的东西直接打进包里，是因为 Oh My Posh 与 Fastfetch **没有可用的国内镜像** —— 打包进去比让用户去 GitHub 下载更靠谱。装终端美化时也**完全不联网**。

## 升级

**重复执行安装等于升级**：只覆盖程序文件，不会动你已有的程序列表（`launcher\programs.json`）、日志与断点状态（`logs\` / `reports\` / `state\`）。

## 装完之后

1. **总览**：先看 CPU / 内存 / 磁盘与关键服务
2. **环境补全**：按状态卡片补齐 FOD 与运行时，需要重启时工具会记住进度
3. **应用商店 / 运行库 / 数据库**：按需装 CLI 工具、多版本语言运行时、PostgreSQL 或 MySQL

接着看[功能一览](../features/)。

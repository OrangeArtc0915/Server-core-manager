---
title: 国内源与离线使用
description: 能内置就内置，必须下载的优先国内源。这里列清楚每个依赖从哪来、实测速度多少，以及完全离线时怎么绕。
group: 进阶
order: 4
---

## 原则

**能内置就内置，必须下载的优先国内源。**

需要联网的地方一共只有下面这几处（实测数据来自一台国内的 Windows Server 2025 Core 测试机）：

| 依赖 | 来源 | 说明 |
|---|---|---|
| 终端美化素材（Nerd Font / Oh My Posh / Fastfetch） | 发布包内置 `setup\console\` | 安装过程**不联网** |
| PowerShell 7（可选） | **清华 TUNA 镜像** | 实测拿到的是真文件（`application/zip`，101 MB）；拿不到时自动回退 GitHub 官方 |
| .NET 运行时 | 微软官方 CDN | 清华 / 阿里云 / 华为云**都没有** .NET 镜像（实测 404 或返回门户 HTML）；官方 CDN 国内实测约 **470 KB/s** |
| Windows Admin Center | 微软官方 `aka.ms` | 无国内镜像；官方 CDN 实测约 **720 KB/s** |
| FOD（App Compatibility） | Windows Update | 用 FOD ISO 配 `-Source` 可以走本地源 |

> [!NOTE]
> 清华镜像**只镜像了少数项目**（PowerShell 是其中之一），Oh My Posh、Fastfetch 这类没有可用的国内镜像 —— 所以它们被**直接打进发布包**，这也是「尽量用国内源」最彻底的做法。

## 自建 / 内网源

用环境变量指定，设置后全局生效：

| 变量 | 作用 |
|---|---|
| `SCM_MIRROR_GITHUB` | 把 `https://github.com` 前缀换成你的镜像（`install.ps1` 下载发布包也用它） |
| `SCM_MIRROR_GITEE` | 换一个 Gitee 基址（默认 `https://gitee.com/orangearc655743/server-core-manager`） |
| `SCM_MIRROR_TUNA` | 清华镜像基址（默认 `https://mirrors.tuna.tsinghua.edu.cn`） |
| `SCM_MIRROR_DOTNET` | 替换 `https://builds.dotnet.microsoft.com/dotnet` 前缀（内网 .NET 源） |

例：

```powershell
$env:SCM_MIRROR_GITHUB = 'http://mirror.intranet/github'
$env:SCM_MIRROR_TUNA   = 'https://mirrors.example.com'
scm
```

## 完全离线（内网、无外网）怎么做

上面「要下载」的项都能绕开：

| 项 | 绕法 |
|---|---|
| 终端美化素材 | 已内置，直接装 |
| PowerShell 7 | 动作参数里**直接指定本地 zip**（或指定内网 URL） |
| .NET 运行时 | 动作参数里指定本地 zip |
| FOD | 用 FOD ISO，配 `-Source` 走本地源 |
| Windows Admin Center | 用 `-NoDownload`，指定本地安装包 |
| 一行安装本身 | 把 `install.ps1` 与发布包放到内网静态服务器，或设 `SCM_MIRROR_GITHUB` / `SCM_MIRROR_GITEE` |

## 相关

- [安装](../install/)
- [终端美化](../console/)

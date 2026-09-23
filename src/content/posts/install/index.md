---
title: 安装 Server Core Manager
published: 2026-09-19
description: "两种安装方式：管理员 PowerShell 里一行命令，或者下载压缩包手动解压。装完四步就能用。"
image: "./cover.png"
tags: ["安装", "快速开始"]
category: "文档"
pinned: true
draft: false
---

Windows Server Core 没有桌面、没有 `explorer.exe`、没有 `dwm.exe`。这个工具把「补全图形环境 → 添加程序 → 启动并排障」做成一键操作，而且它自己也带图形界面，装完就能用鼠标点。

安装只需要管理员权限。

## 方式一：命令行一行安装

在**管理员** PowerShell 里执行（国内推荐走 Gitee）：

```powershell
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

GitHub 能直连时也可以走这条：

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

两条线路装的是同一个发布包，脚本内容也一致。脚本里的下载顺序是 **GitHub Releases → Gitee Releases → GitHub 分支源码打包**，前一条不通、或拿到的不是真 zip，就自动换下一条。

> [!NOTE]
> Gitee 对**不存在的下载路径**返回的是 `200` + 一段 JSON，而不是 404；随便编一个版本号也返回 200。所以脚本不只看 HTTP 状态码，还会按 zip 的魔数 `PK` 校验内容 —— 否则会安安静静下回来一个 JSON，直到解压才报错。

脚本会依次做四件事：下载发布包 → 解压到 `C:\Program Files\ServerCoreManager` → 解除「来自 Internet」的文件锁定 → 安装 `scm` 一行命令。

装完之后，**在任意目录输入 `scm` 回车**就能打开图形界面（首次会像 `sconfig` 一样弹一次提权确认）。

### 需要改默认值

`iex` 没法传参数，用环境变量：

```powershell
$env:SCM_DEST = 'D:\SCM'      # 改安装目录
$env:SCM_NO_COMMAND = '1'     # 不安装 scm 命令
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

自建镜像 / 内网源用 `$env:SCM_MIRROR_GITHUB` 与 `$env:SCM_MIRROR_GITEE`。

## 方式二：压缩包

1. 从 [Releases](https://gitee.com/orangearc655743/server-core-manager/releases) 下载 `ServerCoreManager.zip`
2. 解压到任意目录，例如 `D:\ServerCoreManager`
3. 右键**以管理员身份运行** `一键运行.bat`

> [!WARNING]
> 手工解压后如果 PowerShell 拒绝执行脚本，是压缩包带了「来自 Internet」标记。在工具目录里跑一次 `Get-ChildItem -Recurse *.ps1 | Unblock-File` 即可。命令行安装会自动做这一步。

## 装完之后

1. 打开工具，看「环境」页的七张状态卡片告诉你这台机器缺什么
2. 点「一键补全」，装微软官方的 App Compatibility FOD
3. **重启**。图形组件必须重启才加载，工具支持跨重启接着跑
4. 回到「软件」页添加你的程序，启动参数会自动带好

重复执行安装等于**升级**：只覆盖程序文件，不会动你已有的程序列表（`launcher\programs.json`）、日志与断点状态。

---

作者 **mmm** ｜ QQ 群 **1034243331** ｜ [GitHub](https://github.com/OrangeArtc0915/Server-core-manager) ｜ [Gitee（国内）](https://gitee.com/orangearc655743/server-core-manager)

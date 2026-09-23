---
title: v1.2.0 发布说明
published: 2026-09-23
description: "新增 Gitee 国内安装线路，下载内容改按 zip 魔数校验，回退不再卡死在 GitHub 的超时上。功能动作数量不变。"
tags: ["发布", "更新日志"]
category: "更新日志"
draft: false
---

本版只动安装链路，功能动作数量不变（仍是 29 个）。

## 新增 Gitee 线路

一行安装现在有两条线路，脚本里的下载顺序是 **GitHub Releases → Gitee Releases → GitHub 分支源码打包**，前一条不通就自动换下一条。

国内推荐这条：

```powershell
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

GitHub 能直连时走这条：

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

两条线路装的是同一个发布包，脚本内容也一致。新增 `SCM_MIRROR_GITEE` 环境变量，可以换成自建镜像。

## 下载内容按 zip 魔数校验

Gitee 对**不存在的下载路径**返回的不是 404，而是 `200` + 一段 JSON（实测 60 字节，内容是 `{"message":"空仓库不允许进行的操作","status":200}`）；随便编一个版本号同样返回 200。

也就是说 `curl --fail` 不会失败，会安安静静地下回来一个 JSON，直到解压那一步才报错。所以脚本不只看 HTTP 状态码，还会读文件头、按 zip 的魔数 `PK` 校验内容。

> [!NOTE]
> 顺带一个坑：不设 `--connect-timeout` 的话，GitHub 在国内多是被丢包而不是立刻拒绝连接，会一直卡到 TCP 超时（分钟级）才轮到下一条线路 —— 回退等于形同虚设。现在设成 15 秒。

## 文档与主页

- README 的一行安装改为国内推荐 Gitee，并写清两条线路与自动回退
- 项目主页改用 Astro + [Mizuki](https://github.com/matsuzaka-yuki/Mizuki) 重做，把实测结论与限制整理成文章

> [!IMPORTANT]
> Gitee 上**没有源码**，只放了一个安装脚本 `install.ps1` 与发布包。源码只在 GitHub。

---

作者 **mmm** ｜ QQ 群 **1034243331** ｜ [源码（GitHub）](https://github.com/OrangeArtc0915/Server-core-manager) ｜ [发布包（Gitee）](https://gitee.com/orangearc655743/server-core-manager/releases)

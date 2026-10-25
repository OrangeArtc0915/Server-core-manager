---
title: 游戏资源与镜像下载
description: Modrinth / CurseForge / Spigot 三处资源，按平台分类、按下载量排序，选中即一键装进 mods 或 plugins；服务端核心走 MSL → BMCLAPI → 官方三级回退。
group: 使用
order: 2
project: craftdock
---

## 推荐列表怎么排

进入实例 →「游戏资源」→ `i` 打开推荐，先选平台：

| 平台 | 对应资源 |
|---|---|
| Paper | 插件（Paper / Spigot 生态） |
| Bukkit | 插件（Bukkit / Spigot 生态） |
| Fabric | 模组 |
| Forge | 模组 |
| NeoForge | 模组 |

排序按**下载量**，每页 20 条，用 `[` `]` 翻页。当前实例的加载器和游戏版本会自动带进筛选，
如果筛出来的结果太少，会自动放宽条件（先放宽版本、再放宽加载器），不会给你一张空列表。

## 一键安装

选中条目按 `Enter`，程序会把 jar 直接下到实例的 `mods/` 或 `plugins/` 目录，
下载过程有进度条。装完按 `Space` 可以启用/禁用（文件改名为 `.disabled`），`x` 删除。

已经知道名字或 ID 时，用 `/` 搜索；拿到直链时用 `u` 按 URL 安装。

## 下载会走哪个源

- **服务端核心 / 原版**：MSL 镜像 → BMCLAPI → Mojang 官方，前一个失败才试下一个，全部做 sha256 校验。
- **Java**：MSL JDK 镜像。
- **模组 / 插件**：Modrinth、CurseForge 优先走国内镜像，失败再回官方。

镜像站只对特定客户端标识返回文件，所以程序在请求镜像域名时会带上对应的 UA；
如果探测阶段拿到的是网页而不是文件，会直接判定失败并换源，不会把 1 KB 的 HTML 存成 `.jar`。

## 外部托管的资源

有些 CurseForge / Spigot 资源本身不托管文件，而是跳转到 GitHub 之类的下载页。
这类条目无法直接落盘成 jar，程序会识别出来并提示你用浏览器打开，而不是装一个坏文件。

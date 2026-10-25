---
title: 安装与启动
description: 下载 zip 解压即用，不装 Node.js、不开端口、不需要浏览器。附目录说明和首次启动会做什么。
group: 入门
order: 1
project: craftdock
---

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10 / 11，或 Windows Server 2016 及以上（含 **Server Core**），x64 |
| 运行环境 | **不需要**安装 Node.js / .NET，也不需要浏览器 |
| 终端 | cmd 或 PowerShell（建议窗口至少 120 × 36） |
| 权限 | 普通用户即可；装到受保护目录或用 1024 以下端口时需要管理员 |
| 磁盘 | 程序本体约 140 MB，实例与服务端核心另算 |

## 下载

到 [GitHub Releases](https://github.com/OrangeArtc0915/CraftDock/releases/latest) 下载最新版：

- `craftdock-windows-amd64.zip` —— 完整包，解压即用（推荐）
- `craftdock.exe` —— 只要主程序的话单独拿这个也可以

## 解压后的目录

```
craftdock/
├─ craftdock.exe            主程序（单文件，已内置运行环境）
├─ start-craftdock.bat      启动脚本，顺手把窗口调成 120 × 36
├─ lib/                     可选组件（frpc 客户端等），首次启动自动释放
└─ data/                    实例数据、配置、下载缓存
   ├─ instances/            每个实例一个子目录
   ├─ JavaData/             通过界面下载的 Java 运行时
   └─ frp-providers.json    FRP 服务商与令牌
```

## 启动

双击 `start-craftdock.bat`，或者直接在 cmd / PowerShell 里运行：

```bat
craftdock.exe
```

启动后进入主菜单，用 `↑` `↓` 选条目、`Enter` 进入、`Esc` 返回上一层。

## 首次启动会做什么

1. 检查并释放内置的可选组件（Sakura frpc 等）到 `lib/`；
2. 读取 `data/` 下已有的实例列表；
3. 进入主菜单，此时还没有实例是正常的。

> 首次创建实例时需要联网下载服务端核心和 Java 运行时，之后可以离线使用。
> 网络不通时会自动换源，详见[游戏资源与镜像下载](../resources/)。

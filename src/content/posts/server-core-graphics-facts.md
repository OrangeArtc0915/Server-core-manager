---
title: 关于 Server Core 跑图形程序，哪些说法是错的
published: 2026-09-18
description: "社区里关于 Server Core 跑图形程序的建议，很多是错的。下面每一条都来自真机验证，并且已经固化进代码。"
tags: ["实测", "Server Core"]
category: "实测记录"
draft: false
---

社区里关于 Server Core 跑图形程序的建议，很多是错的。下面每一条都来自真机验证，并且已经固化进代码 —— 工具遇到这些情况会自动走对的那条路，不需要你记。

## 一、装 `Server-Gui-Shell` 功能就能恢复桌面

**错。** 该功能在 Server Core 上**根本不存在**，`Install-WindowsFeature` 会直接报找不到。流传很广，但一试就知道。

## 二、Server Core 不可能跑图形程序

**错。可以。** 装微软官方的 App Compatibility FOD（按需功能包）并重启后，WinForms、WPF、Electron 都能正常渲染。

需要注意的是：补齐 FOD 之后，23 个桌面体验专属组件里仍会缺 4 个（见「关于」页的限制清单），但常规图形程序不受影响。

## 三、远程 PowerShell 里直接 DISM 装 FOD 就行

**不一定。** 走 WinRM 网络令牌时，DISM 的写操作**会被拒绝访问**。这不是权限没给够，而是网络令牌本身带不来本地管理员令牌的那部分能力。

工具的做法是自动改走 SYSTEM 计划任务执行，绕开这个限制。

## 四、Windows Admin Center 装完就能用

**错。** v2 安装包**会重启 WinRM**，直接把远程会话切断；而且服务装完之后状态是 Stopped，不是自动启动。

工具把收尾配置（放行防火墙、设为自启、启动服务、探测入口）放进 SYSTEM 任务里自己完成，装完立刻可用。

## 五、Electron 程序在 Server Core 上就是这么慢

**不是。** 加上 `--disable-gpu --disable-software-rasterizer` 之后，实测**快 3 倍，CPU 时间降 85%**。具体数字见 [Electron 程序在 Server Core 上的启动实测](../electron-launch-benchmark/)。

原因是 Server Core 没有 GPU 驱动，也没有完整的 DWM 合成，Chromium 的 GPU 进程会反复失败重试，既拖慢启动又抬高 CPU。所以工具给 Electron 类程序默认带上上面这两个参数。

---

作者 **mmm** ｜ QQ 群 **1034243331** ｜ [源码（GitHub）](https://github.com/OrangeArtc0915/Server-core-manager) ｜ [发布包（Gitee）](https://gitee.com/orangearc655743/server-core-manager/releases)

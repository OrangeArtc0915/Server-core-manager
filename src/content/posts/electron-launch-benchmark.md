---
title: Electron 程序在 Server Core 上的启动实测
published: 2026-09-18
description: "腾讯 QQ NT 9.9.35 在 Windows Server 2022 Core 上的启动对比：默认 18.2 秒，加上禁用 GPU 的两个参数后 6.0 秒。"
tags: ["实测", "性能", "Electron"]
category: "实测记录"
draft: false
---

测试环境：Hyper-V 上的 Windows Server 2022 Core，build 20348.2700。

## 腾讯 QQ NT 9.9.35（Electron）启动对比

| 启动参数 | 首窗口耗时 | 内存 | CPU 时间 |
|---|---|---|---|
| 默认 | 18.2 s | 385.9 MB | 30.5 s |
| `--disable-gpu` | 15.1 s | 未记录 | 未记录 |
| `--disable-gpu --disable-software-rasterizer` | **6.0 s** | **325.7 MB** | **4.6 s** |

## 为什么差这么多

Server Core 没有 GPU 驱动，也没有完整的 DWM 合成。Chromium 的 GPU 进程会反复失败重试，既拖慢启动又抬高 CPU —— 这是「等不到窗口」的主要来源，不是程序本身的问题。

所以工具在添加 Electron 类程序时，会按 PE 头判断出类型，自动带上这两个参数。

## 另外几项实测

- **MSLX-Daemon（.NET 10 / ASP.NET Core）**：缺运行时，用 zip 免安装方式补齐后 Kestrel 正常启动，Web 控制台渲染与登录正常
- **自动登录**：用 LSA 机密存密码（不是注册表明文），加真实重启验证 —— 重启后自动进入 console 会话，界面自检的整屏截图非黑占比 98.2%
- **Windows Admin Center**：一键安装后的验证输出

```text
[OK]   已安装: 版本 2.7.5.21   安装方式 v2 / Inno Setup 6.7.0
[INFO] 服务 WindowsAdminCenter    Running   启动=Auto
[INFO] 防火墙入站规则: 3 条
[OK]   /shell/ 探测: HTTP 302   网关响应正常
```

---

作者 **mmm** ｜ QQ 群 **1034243331** ｜ [GitHub](https://github.com/OrangeArtc0915/Server-core-manager) ｜ [Gitee（国内）](https://gitee.com/orangearc655743/server-core-manager)

---
title: 添加与管理程序
description: 工具会读 PE 头判断程序类型并自动带入实测推荐参数；Electron 类程序默认带禁用 GPU 的参数，实测快 3 倍。
group: 使用
order: 3
---

## 添加程序

打开「软件」页 → 添加程序 → 选择 exe。工具会读它的 **PE 头**判断类型，再自动带入实测推荐参数：

| 类型 | 判定依据 | 默认参数 |
|---|---|---|
| Electron | 特征段 + 文件布局 | `--disable-gpu --disable-software-rasterizer` |
| .NET / WPF / WinForms | PE 头里的 CLR 头 | 按档案条目 |
| 原生 | 无 CLR 头 | 通常不需要额外参数 |
| 需要控制台 | 子系统 = Console | 单独开控制台窗口 |

## 为什么 Electron 一定要带那两个参数

在 Hyper-V 上的 **Windows Server 2022 Core（build 20348.2700）** 实测腾讯 QQ NT 9.9.35：

| 启动参数 | 首窗口耗时 | 内存 | CPU 时间 |
|---|---|---|---|
| 默认 | 18.2 s | 385.9 MB | 30.5 s |
| `--disable-gpu` | 15.1 s | — | — |
| **`--disable-gpu --disable-software-rasterizer`** | **6.0 s** | **325.7 MB** | **4.6 s** |

装完之后 9 个进程正常运行。

原因：Server Core 没有 GPU 驱动，也没有完整的 DWM 合成，Chromium 的 GPU 进程会反复失败重试，既拖慢启动又抬高 CPU。这是环境限制，不是程序的问题。

## 启动与常驻

- **启动**：直接拉起程序，参数用上面那套
- **后台常驻**：注册成计划任务（登录后自动起、崩溃后自动重试）
- **移除**：只从工具列表里移除，不动程序本身

## 补齐 .NET 运行时

如果程序提示缺 .NET，不需要装安装包：工具用 **zip 就地铺开**的方式补齐 —— 不写注册表、不进控制面板，用完删目录即可。

实测：MSLX-Daemon（.NET 10 / ASP.NET Core）缺运行时，用这个方式部署 10.0.12 后，Kestrel 正常启动并监听端口，Web 控制台在浏览器里渲染正常、登录成功。

## 兼容档案（`lib/catalog.json`）

每个条目都带**实测证据**，不是拍脑袋写的：

```json
{
  "id": "qq-nt",
  "name": "腾讯 QQ NT（Electron 版）",
  "verdict": "可用（建议参数）",
  "launchArgs": "--disable-gpu --disable-software-rasterizer",
  "verifiedOn": "20348.2700",
  "evidence": "实测 A/B：默认参数首窗口 18.2s / CPU 30.5s；加参数后 6.0s / CPU 4.6s"
}
```

「更多 → 程序档案」里可以列出全部档案、查询某一个，也可以**添加你自己的档案条目**（欢迎把你的实测结果提成 PR）。

## 起不来怎么办

见[诊断与排障](../diagnose/)。

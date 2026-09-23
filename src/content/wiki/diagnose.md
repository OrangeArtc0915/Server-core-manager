---
title: 诊断与排障
description: 程序起不来时先看什么、工具会替你查哪些证据、日志和报告落在哪里，以及两个自检开关怎么用。
group: 使用
order: 4
---

## 启动诊断

程序点不动、闪一下就没了，用「启动诊断」。它不只丢一个错误码，而是去查：

- **事件日志**（应用程序日志里的对应条目）
- **WER 记录**（Windows 错误报告留下的崩溃信息）
- **缺失的 DLL**（程序显式依赖但系统里没有的）
- **缺失的运行时**（.NET / VC++ 等）
- 然后给出**处置建议**（补运行时 / 加参数 / 换路线 …）

## exe 兼容性预检

在**启动之前**就能查：选一个 exe，它会告诉你这个程序属于哪类、在 Server Core 上大概率能不能跑、建议加什么参数。

这比“先启动崩一次再看日志”省事。

## GUI 能力自检

Server Core 上没有桌面，所以「进程还活着」不等于「界面真的渲染出来了」。工具里有个更硬的判断方式：

- **`-SelfTest`**：核对页面 / 卡片 / 按钮数量，并**用后台探测产出的 JSON 再渲染一遍卡片**，验证数据往返没问题
- **`-LayoutDump`**：把控件树的真实坐标打出来，并标出越界控件

```powershell
.\Start-GuiReadyApp.ps1 -SelfTest
.\Start-GuiReadyApp.ps1 -LayoutDump
```

非交互模式不会弹窗、不会要你点确认。

## 日志与报告落在哪里

| 目录 | 内容 |
|---|---|
| `logs\` | 每次运行的日志（排障先看这个） |
| `reports\` | JSON 报告与截图取证（GUI 自检的整屏截图也在这里） |
| `state\` | 断点状态、探测缓存（`probe.json` / `env-cache.json`）、启动耗时（`boot-trace.txt`） |
| `payload\` | 下载下来的安装包缓存（WAC 等） |

「关于」页有两个按钮可以直接打开**日志目录**和**报告目录**，不用手打路径。

> [!NOTE]
> 这四个目录都在 `.gitignore` 里，不会进仓库 —— 因为日志里会带主机名、用户名、内网 IP 这类信息。

## 启动明细

想量化「为什么打开慢」：

```powershell
$env:SCM_BOOT_TRACE = '1'
scm
```

各阶段耗时（毫秒）会追加到 `state\boot-trace.txt`。窗口从启动到出现约 2.9 秒，拆开大致是：PowerShell 宿主启动 ~0.75 s（固定成本）、创建全部控件 ~0.83 s、显示 + Shown 处理 ~0.7 s。

## 还是不行

带着 `logs\` 里最新的那份日志去提 [Issue](https://github.com/OrangeArtc0915/Server-core-manager/issues)，或者加 QQ 群 **1034243331**。

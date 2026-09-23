---
title: 环境页与一键补全
description: 为什么必须装 FOD、装了会多出什么、补完之后还缺什么，以及卡片上的数据是怎么来的。
group: 使用
order: 2
---

## 七张状态卡片

打开工具第一眼看到的是「环境」页，7 张卡片分别回答一个问题：

| 卡片 | 看什么 |
|---|---|
| 系统版本 | 是不是 Core SKU、build 多少 |
| 图形组件 | 该有的 DLL / EXE 到位了没有 |
| 渲染管线 | 图形能力能不能真正起作用 |
| .NET 运行时 | 缺哪个版本、要不要补 |
| 登录会话 | 当前会话类型与自动登录状态 |
| 提权 UAC | 关键操作会不会被 UAC 拦住 |
| Web 管理 | Windows Admin Center 装了没有、在不在跑 |

## 一键补全装的是什么

**唯一官方路线：App Compatibility Feature on Demand（FOD）**

```powershell
Add-WindowsCapability -Online -Name ServerCore.AppCompatibility~~~~0.0.1.0
```

装完**必须重启**，`dwm.exe` / `dcomp.dll` / `dwrite.dll` 这些才会就位，图形程序才能渲染。

实测补齐后新增 15 个关键组件，包括 `dwm.exe`、`dcomp.dll`、`uDWM.dll`、`dwmcore.dll`、`dwmredir.dll`、`d3d10warp.dll`、`UIAnimation.dll`、`wuceffects.dll`、`mmc.exe`、`explorer.exe`、`eventvwr.exe`、`perfmon.exe`、`resmon.exe` 等。

工具一共跟踪 51 项组件，分三组：

- **核心基线 21 项**
- **FOD 提供 7 项**
- **桌面体验专属 23 项** —— 补齐后其中**仍会缺 4 个**：`twinui.dll`、`themeservice.dll`、`themeui.dll`、`DispBroker.dll`

这 4 个就是[已知限制](../limits/)里那些场景不能用的原因。

> [!IMPORTANT]
> FOD 从 Windows Update 拉取，体积不小且对网络敏感。工具内置了常见错误码的中文处置建议（`0x800f0954` / `0x800f0831` / `0x80240021` 等）；离线环境可以用 FOD ISO 配 `-Source` 走本地源。

## 卡片上的数据是怎么来的

早期版本里，这一轮探测（DISM 查 FOD 3.7 秒、组件扫描 0.3 秒、.NET / 会话 / 自动登录 / UAC 0.65 秒）**跑在界面线程上**，结果是「窗口出来了但点不动」。

现在探测交给独立子进程，分两次回填：

1. 约 2 秒：先出 6 张，其中 FOD 的值是**按组件推断**的，卡片上标「（推断）」
2. 约 5 秒：DISM 的精确值把它替换掉

上次的完整结果缓存在 `state\env-cache.json`，**第二次以后启动先用上次结果秒显**，后台再静默刷新。

想自己看明细：

```powershell
$env:SCM_BOOT_TRACE = '1'   # 各阶段耗时追加到 state\boot-trace.txt
```

后台探测的原始结果在 `state\probe.json`（本次）与 `state\env-cache.json`（上次）。

## 跨重启续跑

装 FOD 需要重启，而重启会把界面关掉。工具的「一键流程」会记住进度，重启后再打开会**接着往下走**，不用从头再来。

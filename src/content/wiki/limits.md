---
title: 已知限制
description: 补齐 FOD 之后仍然做不到的事，一条条列清楚，并说明原因。这些限制由 Server Core 本身决定，不是工具的缺陷。
group: 参考
order: 2
---

补齐 App Compatibility FOD 之后，桌面体验相关的 23 个组件里**仍会缺 4 个**：`twinui.dll`、`themeservice.dll`、`themeui.dll`、`DispBroker.dll`。下面这些限制就是它们导致的，外加几条环境性的。

## 1. UWP / XAML 应用不行

缺 `twinui.dll`，这类程序起不来。Windows Terminal 就是典型例子（见第 7 条）。

## 2. 界面是经典样式

缺 `themeservice.dll` / `themeui.dll`（主题服务），窗口不会应用现代主题，看起来偏 Win7 / 经典风格。缺 `DispBroker.dll` 也限制了一部分显示相关能力。

**这是预期行为，不是装坏了。**

## 3. 不是远程桌面方案的替代品

本工具是在 Server Core **本机**补齐图形能力，程序在本机渲染。如果你想要的是「无头机器上跑 GUI、通过网络看画面」（IDD 远程渲染方向），那是另一个方向，本工具不做。

## 4. Electron 程序用不上 GPU 加速

只能走软件渲染，所以建议带禁用 GPU 的参数。这是 Server Core 的客观限制 —— 加参数之后实测快 3 倍，但仍然是软件渲染。

## 5. FOD 下载对网络敏感

从 Windows Update 拉取，体积较大且可能失败。工具内置了常见错误码的中文处置建议（`0x800f0954` / `0x800f0831` / `0x80240021` 等），离线环境可以用 FOD ISO 配 `-Source` 走本地源。

## 6. 部分网络下拿不到清华镜像

清华会拒绝部分网络的访问（实测有网络被返回 403，响应头 `X-TUNA-MIRROR-ID: neomirrors`）。这种网络下装 PowerShell 7 请用「指定本地 zip」或 `-Url` 参数。

## 7. Windows Terminal 在 Server Core 上不可用

实测结论：

- **MSIX 版**注册直接失败：`0x80073CF6`「无法注册包」+ `0x80040154`「初始化 windows.capability 扩展时没有注册类」；`Add-AppxProvisionedPackage` 同样报 `0x8007007E`
- **ZIP 免安装版**（自带 `Microsoft.UI.Xaml.dll`）：进程起来立刻崩溃（故障模块 `KERNELBASE.dll`，异常码 `e06d7363`）
- 实测环境：Windows Server 2025 Core 26100.32230，**装好 FOD 并重启之后仍然如此**（FOD 不带 `Windows.UI.Xaml.dll` / `twinui.dll`）
- WT 1.24 要求 `Windows.Desktop ≥ 10.0.19041`，所以 Server 2016 / 2019 也直接排除

**因此本工具已彻底移除 Windows 终端相关功能与离线包**，改为[终端美化](../console/) —— 把 conhost 本身做漂亮。

## 相关

- [环境页与一键补全](../environment/)
- [终端美化](../console/)

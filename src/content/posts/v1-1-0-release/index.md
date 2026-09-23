---
title: v1.1.0 发布说明
published: 2026-09-19
description: "启动提速（界面累计冻结降 82%）、功能精简到 29 个、新增终端美化与终端入口提示，Windows 终端相关功能实测不可用已移除。"
image: "./cover.png"
tags: ["发布", "更新日志"]
category: "更新日志"
draft: false
---

## 启动提速：环境探测挪到后台

之前那一轮环境探测（DISM 查 FOD 3.7 s、组件扫描 0.3 s、.NET / 会话 / 自动登录 / UAC 0.65 s）**跑在界面线程上**，实测要 5~6.5 秒，表现就是「窗口出来了但点不动」。

现在探测交给独立子进程 `gui\Run-GuiReadyProbe.ps1`，分两次回填卡片：2 秒左右先出 6 张（FOD 值按组件推断，卡片上标「（推断）」），约 5 秒后 DISM 的精确值补上。上次的结果缓存在 `state\env-cache.json`，**第二次以后启动先用上次结果秒显**，后台再静默刷新。

实测（同一份代码，14 秒观测窗）：界面累计冻结 **2613 ms → 447 ms**，单次最长 **1086 ms → 228 ms**。

想自己看明细：设 `SCM_BOOT_TRACE=1` 启动，各阶段耗时写进 `state\boot-trace.txt`。

## 退出行为：关窗自动给一个终端

点窗口 X、Alt+F4、「退出（打开终端）」按钮、按 Esc —— 四种关闭方式统一：关掉界面后自动打开**美化终端 `scm-term`**（UTF-8 + Nerd Font + oh-my-posh），没装美化终端就开普通 PowerShell。本机没有 `sconfig.cmd` 的场景也一样有效。

## 精简：先去掉 9 个功能，再加回 1 个（37 → 29 个）

- 去掉 **Gui-Shell 路线 2 个**：「用安装介质补全 Server-Gui-Shell」+「回滚」—— 该路线在真正的 Server Core SKU 上根本不存在，实测判定不可行
- 去掉 **信息展示类 2 个**：「版本适配矩阵与能力差距」+「阶段 B（IDD 远程渲染）准备指引」
- 去掉 **旧的/重复项 5 个**：「启动图形启动器（旧版小面板）」+「一行命令：状态 / 安装 / 卸载」+「终止流程」
- 对应模块（`GuiReady.Matrix` / `GuiShell` / `Command` / `PhaseB`）**保留**，旧的控制台菜单与「一键流程」还在用
- Windows Admin Center 那 4 个功能保留

## 移除：Windows 终端功能

实测在 Server Core 上用不了：MSIX 包装不上，即使想办法装上也无法启动。界面、动作清单、模块与离线包一并删除。

「工具」页不再有 Windows Terminal 入口；「更多」页少了 6 个终端动作（安装 / 状态 / 取证 / 默认终端 / 打开 / 卸载）。想美化命令行，走下面的「终端美化」。

## 新增：终端美化（离线内置）

Nerd Font、oh-my-posh、fastfetch 全部打进发布包，安装过程**不联网**。装好后输入 `scm-term` 打开终端，就是 UTF-8 + Nerd Font + 图标提示符，另带 fastfetch 系统信息面板。

内置 6 个 oh-my-posh 主题：`1_shell`、`atomic`、`catppuccin_frappe`、`dracula`、`emodipt-extend`、`zash`，在「更多 → 终端美化」里直接切换。不想要了可以一键还原（profile、cmd AutoRun、字体、颜色全清）。

> [!TIP]
> 中文控制台的代码页是 936，conhost 在该代码页下**只接受自带中文字形的字体**，`MesloLGS NF` 会被拒绝并回退成「新宋体」。切到 UTF-8（`chcp 65001`）后同一个字体立刻被接受 —— 所以美化终端必须走 `scm-term` 这个启动器：先切代码页，再应用字体。

## 新增：终端里告诉你两条入口

cmd 和 PowerShell 的新窗口都会显示：

```
输入 "Sconfig" 返回服务器菜单
输入 "scm" 打开 GUI 工具
```

清屏（`cls` / `clear`）或新开窗口后会重新显示。输出被重定向时保持安静，不会污染脚本抓取的结果。

> [!WARNING]
> cmd 的 `AutoRun` 对**每个新建的 cmd 实例**都生效。早期版本在批处理里用管道做交互式判断，结果递归拉起子 `cmd`，把测试机拖出 2785 个 `find` 进程。现在改成「只用环境变量做标记、零管道零外部命令」，并在写入后自检换行符（cmd 批处理必须是 CRLF）。

## 新增：设置登录 Shell

一键在 `explorer`、轻量启动器、`cmd`、`sconfig` 之间切换，改动前自动导出注册表备份，随时还原。

sconfig 这条走一个批处理包装（`system32\servercoreshelllaunch.bat`），因为 Winlogon 用 `CreateProcess` 拉起 Shell，不能直接执行 `.bat` 文件。

---

作者 **mmm** ｜ QQ 群 **1034243331** ｜ [源码（GitHub）](https://github.com/OrangeArtc0915/Server-core-manager) ｜ [发布包（Gitee）](https://gitee.com/orangearc655743/server-core-manager/releases)

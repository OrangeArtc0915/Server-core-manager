---
title: 安装与启动
description: 单文件 exe、零第三方依赖；首次启动会自动拉起后台服务、写出默认配置，并直接进入 PowerShell。
group: 入门
order: 1
project: scterm
---

## 系统要求

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 1809 / Windows Server 2019 及以上（需要 ConPTY） |
| 鼠标上报 | 系统 build ≥ 18362；旧版本会自动关闭鼠标功能 |
| 运行时 | 无。编译产物是单个 `scterm.exe`，静态链接 C 运行库 |
| 构建 | 只在从源码构建时需要 Rust stable + MSVC 工具链 |

## 获取与构建

项目没有安装程序，也不需要 Node.js / Python / .NET 运行时：

```bash
cd TUI_TOOL/Terminal
cargo build --release
# 产物：target/release/scterm.exe
```

把 `scterm.exe` 放到任意目录即可运行；配置文件、日志、会话文件会写到用户目录，不污染程序目录。

## 启动

```powershell
scterm
```

首次启动会做三件事：

1. 如果后台服务还没运行，自动以 `scterm.exe server --detached` 拉起（命名管道按用户 SID 隔离）；
2. 如果没有配置文件，写出默认配置；
3. 用默认 profile 打开第一个标签页。**出厂默认是 `powershell`**：优先 `pwsh.exe`，找不到时回退 Windows PowerShell 5.1。

> 自研 shell（cmd 风格）与 `cmd.exe` 仍保留在 profile 列表里，可在设置面板的「默认 profile」行随时切回。

## 常用命令

| 命令 | 作用 |
|---|---|
| `scterm` | 启动客户端（必要时自动拉起后台服务） |
| `scterm server` | 前台运行后台服务 |
| `scterm server --detached` | 由客户端自动调用，后台常驻 |
| `scterm shell` | 自研 cmd 风格命令解释器 |
| `scterm reload` | 校验并打印当前配置、profile、布局、Quake 设置 |
| `scterm actions` | 列出全部动作与当前快捷键 |
| `scterm --layout <名称或表达式>` | 按布局模板打开多窗格标签页 |
| `scterm --quake` | Quake 模式启动：注册热键并隐藏窗口 |
| `scterm --help` / `--version` | 帮助 / 版本 |

## 文件位置

| 内容 | 路径 |
|---|---|
| 配置 | `%APPDATA%\scterm\config.toml`（可用 `SCTERM_CONFIG` 覆盖） |
| 会话快照 | `%APPDATA%\scterm\session.toml` |
| 日志 | `%LOCALAPPDATA%\scterm\logs\scterm-YYYYMMDD.log` |
| shell 集成脚本 | `%LOCALAPPDATA%\scterm\integration\` |
| 背景图目录 | `%APPDATA%\scterm\backgrounds\` |

配置修改后客户端每秒比对一次文件时间，变化即自动重载；`scterm reload` 可以手动校验。解析失败不会覆盖用户文件，只回退内置默认值并把中文错误写进日志与状态栏。

## 退出

- 关闭最后一个标签页即退出客户端；
- 退出客户端会结束它创建的窗格；后台服务进程会继续常驻，供下次启动复用；
- 需要彻底结束后台服务时，在任务管理器结束对应的 `scterm.exe server` 进程即可。

## 下一步

- [快速上手](../quickstart/)
- [标签页与窗格](../tabs-panes/)
- [配置文件详解](../config/)

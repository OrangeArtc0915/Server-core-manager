---
title: Windows 终端在 Server Core 上用不了，我们改做了什么
published: 2026-09-19
description: "实测：MSIX 包装不上，即使想办法装上也无法在 Server Core 启动。于是转向把系统自带的 conhost 美化好，并记录下代码页 936 这个坑。"
tags: ["实测", "终端", "Server Core"]
category: "实测记录"
draft: false
---

## 结论先说

Windows Terminal 在 Server Core 上**不可用**：MSIX 包装不上；即使想办法装上，也无法启动。所以工具里所有 Windows 终端相关的功能（安装 / 状态 / 取证 / 设为默认终端 / 打开 / 卸载）在 v1.1.0 里全部移除了，离线包也一并删掉 —— 留着一个点了没反应的功能，比没有这个功能更糟。

那命令行还能不能好看？**能。** 转向美化系统自带的 `conhost`。

## 一个绕不开的坑：代码页 936

中文 Windows 的控制台代码页是 **936（GBK）**。在这个代码页下，`conhost` **只接受自带中文字形的字体**：

- 实测 `MesloLGS NF` 与 `Consolas` 都被拒绝 —— `SetCurrentConsoleFontEx` 返回 `True`，但回读发现字体被回退成了「新宋体」
- 把控制台切到 UTF-8（`chcp 65001`）之后，同一个 Nerd Font 立刻被接受（`GetCurrentConsoleFontEx` 回读 `face=MesloLGS NF`）

另外两条实测结论：

- `HKCU\Console\CodePage` 对「新建控制台」不生效
- 按标题记忆的 `HKCU\Console\<标题>` 也不生效

所以**美化终端必须走我们自己的启动器 `scm-term.cmd`**：先 `chcp 65001`，再应用字体。直接改注册表是不行的。

## 具体做了什么

- **Nerd Font**：字体装进 `C:\Windows\Fonts`，同时写 `HKLM\...\Console\TrueTypeFont`（中文代码页用 `0936` 这种键名）和 `FontLink\SystemLink` 做中文回退
- **oh-my-posh**：内置 6 个主题（`1_shell`、`atomic`、`catppuccin_frappe`、`dracula`、`emodipt-extend`、`zash`），装完直接切换
- **fastfetch**：系统信息面板
- **全程离线**：字体、`oh-my-posh.exe`、`fastfetch.exe`、主题 json 都打进发布包，安装过程不联网
- **可一键还原**：profile、cmd `AutoRun`、字体、颜色全部清干净

装好后输入 `scm-term` 打开终端即可。

> [!NOTE]
> 给字体辅助脚本千万别重定向 stdout。stdout 一旦变成文件句柄，进程就「不再拥有控制台」，`GetCurrentConsoleFontEx` 会直接失败。

## 顺手加的两条入口提示

cmd 和 PowerShell 的新窗口都会在顶部显示（黄色）：

```
输入 "Sconfig" 返回服务器菜单
输入 "scm" 打开 GUI 工具
```

清屏（`cls` / `clear`）或新开窗口后会重新显示。输出被重定向时保持安静。

> [!WARNING]
> cmd 的 `AutoRun` 对**每个新建的 cmd 实例**都生效，而且管道和外部命令会拉起子 `cmd`、再触发一次 `AutoRun`。早期版本正是踩了这个坑：用 `echo | find` 判断是否交互式，结果递归出 2785 个 `find` 进程。现在的做法是「只用环境变量做标记、零管道零外部命令」，并且写入后自检换行符 —— cmd 批处理必须是 CRLF，LF 会让解析错乱并把 `cmd /c` 的输出污染掉。

## 相关：设置登录 Shell

「会话与登录」组里还有个「设置登录 Shell」，一键在 `explorer`、轻量启动器、`cmd`、`sconfig` 之间切换，改动前自动导出注册表备份。

其中 sconfig 这条要走一个批处理包装（`system32\servercoreshelllaunch.bat`），因为 Winlogon 用 `CreateProcess` 拉起登录 Shell，不能直接执行 `.bat`。

---

作者 **mmm** ｜ QQ 群 **1034243331** ｜ [源码（GitHub）](https://github.com/OrangeArtc0915/Server-core-manager) ｜ [发布包（Gitee）](https://gitee.com/orangearc655743/server-core-manager/releases)

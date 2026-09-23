---
title: 终端美化
description: Windows Terminal 在 Server Core 上装不了，所以这个功能是直接把 conhost 打扮好看：Nerd Font + Oh My Posh + Fastfetch，全程离线，可一键还原。
group: 进阶
order: 1
---

## 为什么不是装 Windows Terminal

**因为它在 Server Core 上用不了**（实测，不是推测）。它的界面是 XAML 栈，而 Server Core 缺 `Windows.UI.Xaml.dll` / `twinui.dll`：

- **MSIX 打包版**：注册直接失败 —— `0x80073CF6`「无法注册包」+ `0x80040154`
- **ZIP 免安装版**（自带 `Microsoft.UI.Xaml.dll`）：进程起来立刻崩溃（异常码 `e06d7363`），出不了窗口
- 实测环境：Windows Server 2025 Core 26100.32230，**装好 FOD 并重启之后仍然如此**
- 顺带确认：WT 1.24 要求 `Windows.Desktop ≥ 10.0.19041`，所以 Server 2016 / 2019 也直接排除

所以这个功能走另一条路：**美化系统自带的 conhost**。

## 装了些什么

| 组件 | 作用 |
|---|---|
| **MesloLGS NF**（Nerd Font） | 全机安装 + 写控制台字体白名单 + `FontLink` 回退到微软雅黑，保证中文正常 |
| **Oh My Posh** | 单文件程序 + 主题，往 PowerShell 5.1 与 7 的 profile 各写一段**可撤销**的初始化块 |
| **6 个内置主题** | `1_shell`、`atomic`、`catppuccin_frappe`、`dracula`、`emodipt-extend`、`zash`（默认 One Dark） |
| **Fastfetch** | 进终端先来一段系统信息 |
| **One Dark 配色 + 打开 ANSI(VT)** | 写 `HKCU\Console`（原值先备份，可还原） |

装好后的入口是命令 **`scm-term`**（或工具页「美化终端」按钮）。

> [!NOTE]
> 素材全部内置在发布包的 `setup\console\`（解压后约 35 MB），**安装过程不联网** —— 因为 Oh My Posh 与 Fastfetch 没有可用的国内镜像。

## 为什么必须走 `scm-term`，不能直接开 cmd

这是实测结论（踩过才知道）：

中文控制台的代码页是 **936**，`conhost` 在该代码页下**只接受自带中文字形的字体**。实测 `MesloLGS NF` 和 `Consolas` 都被拒 —— Console API 返回成功，但回读发现 conhost 实际回退成了「新宋体」。

把控制台切到 UTF-8（`chcp 65001`）后，同一个 Nerd Font **立刻被接受**（回读 `face=MesloLGS NF`）。

另外两种常见写法**都不生效**（都实测过）：

- `HKCU\Console\CodePage`
- 按窗口标题记忆的 `HKCU\Console\<标题>`

所以 `scm-term.cmd` 的顺序是：先 `chcp 65001` → 再用 Console API 应用字体 → 然后启动带 oh-my-posh 的 PowerShell。

## 任何终端都会提示两个入口

打开 cmd 或 PowerShell，顶部会打印（黄色）：

```
输入 "Sconfig" 返回服务器菜单
输入 "scm" 打开 GUI 工具
```

**执行 `cls` / `clear` 清屏后会自动重新显示**（PowerShell 覆写 `Clear-Host`，cmd 用 `doskey` 宏接管 `cls`）。非交互式（`cmd /c ...`、输出被重定向）保持安静，不会污染脚本输出。

> [!WARNING]
> cmd 的 `AutoRun` 对**每个新建的 cmd 实例**都生效，而且管道和外部命令会拉起子 `cmd`、再触发一次 `AutoRun`。早期版本正是踩了这个坑：用 `echo | find` 判断是否交互式，结果递归出 2785 个 `find` 进程。现在的做法是「只用环境变量做标记、零管道零外部命令」，并且**写入后自检换行符** —— cmd 批处理必须是 CRLF，LF 会让解析错乱。

## 一键还原

「更多 → 终端美化 → 一键还原」会把 profile、cmd `AutoRun`、字体、配色、入口提示全部清干净，恢复到装之前的状态。

## 可选：安装 PowerShell 7

走**清华 TUNA 镜像**（本机实测拿到的确实是文件，`application/zip`，101 MB），拿不到时自动回退 GitHub 官方。

> [!IMPORTANT]
> 清华会拒绝部分网络的访问（实测某些网络返回 403，响应头带 `X-TUNA-MIRROR-ID: neomirrors`）。这种网络下请用「指定本地 zip」或 `-Url` 参数。

## 相关

- [国内源与离线使用](../sources/)
- [设置登录 Shell](../session/)

---
title: PowerShell 与外部 shell 集成
description: 默认托管真实 PowerShell；OSC 7/133 提示符集成、路径跟随、命令跳转，以及如何切回自研 shell 或 cmd。
group: 使用
order: 3
project: scterm
---

## 默认 profile：PowerShell

出厂默认 profile 是 `powershell`，探测顺序：

1. `pwsh.exe`（PATH）
2. `%ProgramFiles%\PowerShell\7\pwsh.exe`
3. `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`
4. PATH 里的 `powershell.exe`

因此装了 PowerShell 7 就用 7，没装就用 Windows PowerShell 5.1。命令、参数、别名、对象管道、补全、历史和提示符全部由真实 PowerShell 提供，行为与官方一致。

> 旧配置里的 `pwsh` profile 不会改名；如果 `pwsh.exe` 不存在，它的命令会自动回退到 Windows PowerShell，`scterm reload` 会给出提示。

## 切换 profile

| 目的 | 做法 |
|---|---|
| 改新建标签的默认 profile | `Ctrl+S` → 「默认 profile」行 → `←/→` 切换 → `Enter` 保存 |
| 只为下一个标签选 profile | `Ctrl+Shift+B`，或 `Alt+点标签栏的 +` |
| 临时用自研 shell | 选择 `scterm` profile（`scterm.exe shell`） |
| 临时用 cmd | 选择 `cmd` profile |

可选项来自配置里的 `[[profiles]]`；新配置默认带 `scterm`、`cmd`、`powershell` 三个。

## shell 集成（OSC 7 / OSC 133）

scterm 会给可识别的外部 shell 注入一小段脚本：

- **OSC 7**：上报当前目录，标签栏右下角据此显示路径；
- **OSC 133**：标记提示符开始 / 命令开始 / 命令结束与退出码，用于：
  - 标签上的 `✓` / `✗码` 状态；
  - `Ctrl+Shift+↑/↓` 跳到上一条 / 下一条命令；
  - `Ctrl+Shift+Home` 跳到最早一条命令。

脚本位置：`%LOCALAPPDATA%\scterm\integration\`。命令行等价于：

```text
powershell.exe -NoLogo -ExecutionPolicy Bypass -NoExit -Command ". '<集成脚本>'"
```

- 只对 `powershell.exe` 追加 `-ExecutionPolicy Bypass`，避免 Server Core 默认执行策略阻止脚本；`pwsh.exe` 不加；
- 如果 profile 自己已经带了 `-Command` / `-File` / `/c` / `/k`，scterm 不会覆盖；
- 关掉某个 profile 的集成：在 `[[profiles]]` 里写 `shell_integration = false`。

## 自研 shell（cmd 风格）

`profile = "scterm"` 启动的是 `scterm.exe shell`，它是 cmd 语义，不是 PowerShell：

- 内置命令：`alias cd chcp cls copy date del dir echo erase exit help history md mkdir move pause popd prompt pushd pwd rd ren rename rmdir run set time title type ver vol where`；
- 支持管道 `|`、重定向 `>` `>>` `<`、变量展开、通配符、别名；
- `.sct` 脚本：`run 脚本.sct 参数...`，支持注释、`if / else`、`for`（`/l /d /r`）、`goto`、`call :标签`、`exit /b`；
- 行编辑：`↑↓` 历史、Tab 补全（命令 / 别名 / PATH 可执行文件 / 文件路径）、`Ctrl+C` 取消、`Ctrl+L` 清屏、`Ctrl+←/→` 按词移动、`Ctrl+Backspace/Delete` 按词删除；
- Tab 补全只补命令名与路径，不补参数——参数补全请用真正的 PowerShell（PSReadLine 自带）。

## 提示符跳转与状态

| 操作 | 方式 |
|---|---|
| 上一条命令 | `Ctrl+Shift+↑` |
| 下一条命令 | `Ctrl+Shift+↓` |
| 最早一条命令 | `Ctrl+Shift+Home` |
| 最新一条命令 | 命令面板里的「跳到最新一条命令」 |

如果外部程序不发送 OSC 133，跳转会退化为回到最新输出。

## 下一步

- [布局模板与会话恢复](../layouts-session/)
- [配置文件详解](../config/)

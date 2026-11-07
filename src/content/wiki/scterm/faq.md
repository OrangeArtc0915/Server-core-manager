---
title: 常见问题与已知限制
description: 默认 PowerShell、Quake 没反应、会话没恢复、字体设置失败、复制粘贴与旧系统兼容等问题的结论。
group: 参考
order: 1
project: scterm
---

## 为什么默认是 PowerShell？

出厂默认 profile 是 `powershell`：优先 PowerShell 7，找不到就用 Windows PowerShell 5.1。这样命令、参数、别名、对象管道、补全、历史和提示符都与官方一致，不需要重新学习。

想切回：

- `Ctrl+S` → 「默认 profile」→ 选 `scterm`（自研 cmd 风格 shell）或 `cmd`；
- 或直接改配置 `default_profile = "scterm"`。

## 自研 shell 为什么没有 `Get-ChildItem`？

`scterm` profile 是 **cmd 语义**的内置 shell（`dir`、`copy`、`set`、`if`、`for`、`goto`、`call :标签`、`exit /b`、`.sct` 脚本），不是 PowerShell。需要 cmdlet 就切到 `powershell` profile。

## Quake 热键没反应

依次检查：

1. `[quake] enabled = true` 是否真的生效（`scterm reload` 会打印）；
2. 热键是否被其它程序占用——被占用时客户端只告警、不隐藏窗口；
3. 宿主是否是 Windows Terminal：Quake 依赖 `GetConsoleWindow()`，WT 宿主下拿到的是隐藏消息窗口，热键能注册但看不到显隐效果；
4. 热键写法是否合法：至少一个修饰键，主键放最后。

## 会话没有恢复

- 只有**正常退出**（关闭最后一个标签）才会写 `session.toml`；任务管理器强杀不会写；
- 启动时用了 `--layout` 会跳过会话恢复；
- 配置里 `restore_session = false` 时不保存也不读取；
- 某个标签的布局解析失败会被跳过，其余标签照常恢复。

## 字体设置失败

`SetCurrentConsoleFontEx` 要求字体已安装。Server Core 自带字体很少；字体不存在会报错并沿用原字体。先用系统里确实有的字体（Consolas / Lucida Console / 宋体）。

## 彩色 emoji / 图片 / 透明效果

这些不是 bug，是 conhost 的能力边界：

| 能力 | 状态 |
|---|---|
| 彩色 emoji | 双宽占位，无彩色字形 |
| Sixel / kitty 图像 | 不支持 |
| 亚克力 / Mica / 真透明 | 不支持 |
| 圆角窗口 / 标签拖出成新窗口 | 不支持 |
| 字体连字 / 可变字体 | 不启用 |

控制台只能按单元格上色；背景图也是采样成单元格颜色后混合，不是真正的透明窗口。

## 窗口缩放后内容不重排

与 ConPTY 自身行为一致：尺寸变化只保留左上角内容，不做 reflow。需要重排请用支持 reflow 的 GUI 终端。

## 旧系统上鼠标不可用

系统 build < 18362 时，ConPTY 的鼠标上报有已知缺陷，scterm 会自动关闭鼠标功能（滚轮回看仍可用），并记录一条 WARN。

## 复制/粘贴异常

- 复制按单元格取值，宽字符只写首格；块选择会保留矩形内的空格；
- 粘贴默认使用括号粘贴，多行内容会先弹确认；
- 剪贴板访问失败时会在状态栏提示，不会静默丢失。

## 配置改坏 / 客户端起不来

- 解析失败不会覆盖你的文件，会回退内置默认值并把中文错误写进日志与状态栏；
- 用 `scterm reload` 看具体是哪一项；
- 日志在 `%LOCALAPPDATA%\scterm\logs\`；
- 实在不行删掉 `config.toml`，下次启动会重新生成。

## 后台服务一直存在

客户端会自动拉起 `scterm.exe server --detached`，它按用户 SID 隔离并常驻，供下次启动复用。需要彻底结束时，在任务管理器结束对应的 `scterm.exe server` 进程。

## Tab 补全不补参数

自研 shell 的补全只覆盖：内置命令、别名、PATH 可执行文件、文件路径。参数/开关补全交给 PowerShell 自己的 PSReadLine。

## 已知限制

- 不做远程能力（SSH / WinRM / attach 远端）；
- 不做 GPU 渲染、亚像素字体、透明与模糊；
- 窗口尺寸变化不 reflow；
- 会话恢复不恢复运行中的进程与输出；
- Quake 只对 conhost 窗口有效；
- 动作键位不支持 `win` 修饰键；
- 标签页只有顶部布局，不支持侧边标签。

## 下一步

- [安装与启动](../install/)
- [配置文件详解](../config/)

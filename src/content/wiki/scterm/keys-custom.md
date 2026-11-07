---
title: 自定义快捷键与命令面板
description: 用 [[actions]] 改键、留空只在命令面板出现；Chord 写法、冲突规则与命令面板用法。
group: 进阶
order: 3
project: scterm
---

## 查看全部动作

```powershell
scterm actions
```

输出三列：`command`（动作 id）、`快捷键`、`说明`。所有 UI 能力都是动作，快捷键只绑定到动作，不直接改界面。

## 改键

```toml
[[actions]]
command = "splitPaneHorizontal"
keys = "alt+shift+-"

[[actions]]
command = "closePane"
keys = "ctrl+shift+q"     # 关闭窗格默认没有快捷键，可按需绑定

[[actions]]
command = "commandPalette"
keys = ""                 # 留空 = 只出现在命令面板
```

规则：

- 同一动作再写一个新键会移除旧绑定；
- 同一个键被两个动作绑定时，**后出现的生效**，并打印警告；
- `keys = ""` 表示不绑定快捷键，只保留在命令面板里；
- 改完客户端自动重载，`scterm reload` 可确认是否有冲突警告。

## Chord 写法

```text
ctrl+shift+t
alt+shift+plus
ctrl+tab
f5
alt+arrowleft
```

- 修饰键：`ctrl` / `control`、`alt`、`shift`（动作键位不支持 `win`）；
- 主键名：
  - `tab`、`enter` / `return`、`escape` / `esc`、`backspace`、`space`
  - `left` / `arrowleft`、`right` / `arrowright`、`up` / `arrowup`、`down` / `arrowdown`
  - `home`、`end`、`pageup` / `prior`、`pagedown` / `next`、`insert`、`delete` / `del`
  - `plus`、`minus`、`f1`–`f24`、单个字母/数字
- 主键必须在最后；`+` 本身要写成 `plus`。

## 命令面板

`Ctrl+Shift+P` 打开：

- 子序列模糊匹配「中文名 + 动作 id」，例如输入 `分屏`、`split`、`zoom` 都能找到；
- 每项显示当前快捷键；
- 没有绑定快捷键的动作也能执行；
- `↑↓` 选择，`Enter` 执行，`Esc` 关闭；
- 面板里也会列出 profile 快捷项，选中即用该 profile 新建标签。

常用但默认没有键位的动作：

| 动作 id | 说明 |
|---|---|
| `closePane` | 关闭当前窗格 |
| `promptLast` | 跳到最新一条命令 |
| `paste` 之外的剪贴板动作 | 可通过面板执行 |
| `quit` | 退出 scterm |

## 与子进程的冲突

- 命中的快捷键不会转发给窗格里的程序；
- 没命中的按键按 VT 规则翻译后转发；
- 程序开启 win32-input-mode（`?9001`）时，按下与抬起都按 `CSI Vk;Sc;Uc;Kd;Cs;Rc _` 原样转发，Shift+Enter、Ctrl+Shift+字母等组合也能送达。

如果某个快捷键在 vim / PSReadLine 里失效，先检查它是否被 scterm 的动作占用（`scterm actions`）。

## 下一步

- [快捷键总表](../shortcuts/)
- [配置文件详解](../config/)

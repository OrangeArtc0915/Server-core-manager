---
title: Quake 下拉热键
description: 注册一个全局热键，按下隐藏/呼出控制台窗口；可选启动即隐藏，并支持置顶。
group: 使用
order: 5
project: scterm
---

## 配置

```toml
[quake]
# 是否注册全局呼出热键
enabled = true
# 修饰键 win/ctrl/alt/shift + 主键
hotkey = "win+`"
# 呼出时置顶
topmost = true
```

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | `false` | 打开后才注册热键 |
| `hotkey` | `win+\`` | 大小写不敏感 |
| `topmost` | `true` | 呼出时调用 `SetWindowPos(HWND_TOPMOST)` |

改完配置客户端会自动重载；`scterm reload` 会打印当前 Quake 设置，方便确认热键写法是否生效。

## 热键写法

- 至少一个修饰键：`win` / `ctrl` / `alt` / `shift`；
- 主键放在最后，支持：
  - `a`–`z`、`0`–`9`
  - `f1`–`f24`
  - `space`、`tab`、`enter`、`esc`
  - `` ` `` 或 `backtick`、`minus` / `-`、`plus` / `=`、`comma` / `,`、`period` / `.`、`slash` / `/`、`backslash` / `\`

示例：

```toml
hotkey = "win+`"
hotkey = "ctrl+alt+space"
hotkey = "alt+f12"
```

无修饰键、未知主键、`f25` 以上、修饰键写在主键之后都会报错。

## 启动即隐藏

```powershell
scterm --quake
```

- 先注册热键，**注册成功后**才隐藏窗口；
- 热键已被其他程序占用时，客户端照常启动、窗口保持可见，并在状态栏与日志里提示；
- `--quake` 只影响本次启动，不修改配置文件。

## 行为

- 窗口可见：按下热键 → 隐藏；
- 窗口隐藏或最小化：按下热键 → 恢复、置前，`topmost = true` 时置顶；
- 热键监听在独立线程里跑消息循环，不影响终端主循环。

> Quake 依赖 `GetConsoleWindow()` 返回的控制台窗口。在 conhost 下正常；如果宿主是 Windows Terminal，拿到的是隐藏的消息窗口，热键能注册但看不到显隐效果。

## 已知限制

- 热键是全局的，与其它程序冲突时只能换一个组合；
- 没有「下拉动画」或窗口高度百分比——这是控制台窗口，不是 GUI 浮层；
- 隐藏窗口不会暂停窗格里的进程，命令继续运行。

## 下一步

- [配置文件详解](../config/)
- [常见问题与已知限制](../faq/)

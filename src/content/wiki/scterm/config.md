---
title: 配置文件详解
description: config.toml 的全部字段、默认值、优先级与写回规则；改完自动生效，设置面板只改相关键。
group: 进阶
order: 1
project: scterm
---

## 位置与加载

- 默认路径：`%APPDATA%\scterm\config.toml`；
- 可用环境变量 `SCTERM_CONFIG` 指向其它文件（测试、便携场景）；
- 文件不存在时首次运行自动写出默认配置；
- 客户端每秒比对文件修改时间，变化即重载；
- `scterm reload` 校验并打印配置；解析失败不覆盖用户文件，回退内置默认值并记录中文错误。

## 顶层

```toml
default_profile = "powershell"   # 新建标签页/窗格使用的 profile
scrollback = 10000               # 每个窗格的回看行数
```

## `[render]`：全局渲染

| 键 | 默认 | 取值 |
|---|---|---|
| `mouse` | `true` | 是否允许鼠标上报（build < 18362 会自动关闭） |
| `truecolor` | `"auto"` | `auto` / `always` / `never` |
| `font_face` | 不设置 | 控制台字体名，需系统已安装 |
| `font_size` | 不设置 | 像素高度，6–72 |
| `gradient` | `"vertical"` | `off` / `vertical` / `horizontal` / `diagonal` |
| `gradient_top` | 自动 | 渐变起始色，如 `"#1B2A45"` |
| `gradient_bottom` | 自动 | 渐变结束色 |
| `background_image` | 不设置 | 背景图路径；相对路径按 `backgrounds` 目录解析 |
| `background_image_opacity` | `35` | 0–100 |

## `[behavior]`

| 键 | 默认 | 说明 |
|---|---|---|
| `copy_on_select` | `false` | 松开鼠标即复制选区 |
| `confirm_close` | `true` | 关闭标签前确认 |
| `confirm_multiline_paste` | `true` | 粘贴多行内容前确认 |
| `restore_session` | `true` | 正常退出保存、下次启动恢复会话 |

## `[quake]`

```toml
[quake]
enabled = false
hotkey = "win+`"
topmost = true
```

字段说明见 [Quake 下拉热键](../quake/)。

## `[layouts]`

```toml
[layouts]
dev  = "h(powershell,v(cmd,powershell))"
even = "v50(powershell,cmd)"
```

键是布局名，值是布局表达式。表达式语法见 [布局模板与会话恢复](../layouts-session/)。

## `[[profiles]]`

```toml
[[profiles]]
name = "powershell"
command = "powershell.exe"
args = ["-NoLogo"]
cwd = "%USERPROFILE%"
color_scheme = "Campbell"
shell_integration = true
```

| 键 | 说明 |
|---|---|
| `name` | profile 名，标签标题与布局表达式都用它 |
| `command` | 可执行文件；`@self` 表示 scterm 自身（用于自研 shell） |
| `args` | 启动参数数组 |
| `cwd` | 启动目录，支持 `%VAR%` 展开 |
| `color_scheme` | 该 profile 使用的配色方案名 |
| `shell_integration` | 是否注入 OSC 7/133 集成脚本，默认 `true` |
| `font_face` / `font_size` | 覆盖全局字体 |
| `gradient` | `inherit`（默认）/ `off` / `vertical` / `horizontal` / `diagonal` |
| `gradient_top` / `gradient_bottom` | 覆盖全局渐变颜色 |
| `tab_color` | 标签底色，如 `"#3B78FF"` |

未写的键沿用全局 `[render]`。

## `[[color_schemes]]`

```toml
[[color_schemes]]
name = "MyTheme"
foreground = "#CCCCCC"
background = "#0C0C0C"
cursor = "#FFFFFF"
selection = "#264F78"
ansi_0 = "#0C0C0C"
# … ansi_1 ~ ansi_15
```

只写一部分 `ansi_*` 时，缺失项回退到 Campbell 的对应颜色；一项都不写则沿用宿主终端的 ANSI 配色。内置另有 64 套方案，不必写进配置。

## `[[actions]]`

```toml
[[actions]]
command = "splitPaneHorizontal"
keys = "alt+shift+-"

[[actions]]
command = "commandPalette"
keys = ""            # 留空 = 只出现在命令面板
```

`command` 取值用 `scterm actions` 查看。同一动作换键会移除旧绑定；同一键重复绑定时后出现者生效并告警。

## 优先级与写回

- profile 的外观键优先于全局 `[render]`；profile 未写的键逐项回退。
- 设置面板（`Ctrl+S`）改动立即生效，`Enter` 保存；保存只替换相关键，**注释、自定义 profile / 配色 / 快捷键原样保留**。
- 写文件采用「先写 `.tmp` 再替换」，避免中途退出留下半截配置。

## 校验与排错

```powershell
scterm reload
```

会打印：默认 profile、回看行数、渲染选项、会话恢复、Quake、布局（含表达式是否合法、引用的 profile 是否存在）、profiles、配色方案，以及全部提示与警告。

## 下一步

- [配色、渐变与背景图](../appearance/)
- [自定义快捷键](../keys-custom/)

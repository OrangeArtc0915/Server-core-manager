---
title: 配色、渐变与背景图
description: 64 套内置配色、13 套渐变预设、每 profile 的外观覆盖与背景图采样规则。
group: 进阶
order: 2
project: scterm
---

## 配色方案

内置 64 套：16 套 Windows Terminal 官方方案 + 48 套常用社区主题。都可以直接在配置或设置面板里选用，不必写进 `config.toml`。

```toml
[render]
# 或在 [[profiles]] 里按 profile 指定 color_scheme
```

```toml
[[profiles]]
name = "powershell"
color_scheme = "One Half Dark"
```

自定义方案：

```toml
[[color_schemes]]
name = "MyTheme"
foreground = "#CCCCCC"
background = "#0C0C0C"
cursor = "#FFFFFF"
selection = "#264F78"
ansi_0  = "#0C0C0C"
ansi_1  = "#C50F1F"
# … ansi_2 ~ ansi_15
```

- 只写部分 `ansi_*` 时，缺失项回退到 Campbell；
- 一项都不写则沿用宿主终端的 ANSI 配色；
- 与内置方案同名时以配置为准。

## 渐变背景

```toml
[render]
gradient = "vertical"       # off | vertical | horizontal | diagonal
# gradient_top = "#1B2A45"
# gradient_bottom = "#05070D"
```

- 不写两端颜色时，按配色方案的背景色自动推导（顶部微亮、底部更深）；
- 设置面板提供 13 套预设：自动、深蓝、紫黑、青灰、暖灰、深绿、酒红、棕金、蓝紫、石墨、冰蓝、粉紫、军绿；
- 控制台只能按单元格上色，所以是逐行/逐列的阶梯式渐变，空白区域也会上色。

每个 profile 可以单独覆盖：

```toml
[[profiles]]
name = "cmd"
gradient = "off"            # inherit（默认）| off | vertical | horizontal | diagonal
gradient_top = "#2A2622"
gradient_bottom = "#0A0908"
```

## 背景图

```toml
[render]
background_image = "sea.jpg"
background_image_opacity = 35
```

- 支持 PNG / JPEG / BMP / GIF（GDI+ 解码）；
- 绝对路径原样使用；相对路径先找 `%APPDATA%\scterm\backgrounds\`，找不到再按当前目录；
- 客户会把图片按当前网格采样成单元格颜色，再与渐变/配色背景按不透明度混合；
- 不透明度 0–100，越高图片越明显；
- 设置面板的「背景图片」行可用 `←/→` 在 `backgrounds` 目录里切换，`空格`/`.` 输入路径。

> 这是「按单元格上色」的背景图，不是真正的透明窗口；conhost 不支持 alpha 混合。

## 字体与字号

```toml
[render]
font_face = "Cascadia Mono"
font_size = 18
```

- 字号范围 6–72 像素；
- 字体必须已安装在系统里，Server Core 可用字体较少；
- 调用 `SetCurrentConsoleFontEx` 失败时会报错并沿用原字体；
- profile 可覆盖全局字体与字号，未写的键逐项回退。

设置面板提供：默认、Consolas、Cascadia Mono、Cascadia Code、Lucida Console、Courier New、宋体。

## 标签颜色

```toml
[[profiles]]
name = "powershell"
tab_color = "#3B78FF"
```

- 该 profile 新建的标签使用此底色，并自动选择对比色前景；
- 设置面板提供 12 套预设，也接受 `#RRGGBB`；
- 不设置时用默认灰色标签。

## 真彩色

```toml
[render]
truecolor = "auto"   # auto | always | never
```

`auto` 会根据宿主能力决定；不可用时降级到 256 色，再降级到 16 色。

## 设置面板速查

`Ctrl+S` 打开，19 行：

配色方案、默认 profile、背景渐变、渐变配色、真彩色、字体、字号、当前 profile 字体、当前 profile 字号、当前 profile 渐变、当前 profile 配色、当前 profile 标签色、回看行数、鼠标上报、选中即复制、关闭标签确认、多行粘贴确认、背景图片、图片不透明度。

`↑↓` 选行，`←→` 改值，`Enter` 保存，`Esc` 按打开时的快照还原。改动立即生效，保存只替换相关键。

## 下一步

- [配置文件详解](../config/)
- [常见问题与已知限制](../faq/)

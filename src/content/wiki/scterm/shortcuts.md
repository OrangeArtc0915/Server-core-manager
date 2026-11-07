---
title: 快捷键总表
description: 默认键位一览：标签、窗格、回看、搜索、选择、标记模式与命令行参数。
group: 参考
order: 2
project: scterm
---

> 所有键位都可以在 `[[actions]]` 里覆盖；`keys = ""` 表示只保留在命令面板。用 `scterm actions` 查看当前实际绑定。

## 标签页

| 快捷键 | 动作 |
|---|---|
| `Ctrl+B` | 新建标签（默认 profile） |
| `Ctrl+Shift+B` | 新建标签并选择 profile |
| `Ctrl+Shift+W` | 关闭当前标签 |
| `Ctrl+Tab` | 下一个标签 |
| `Ctrl+Shift+Tab` | 上一个标签 |
| `Ctrl+1` ~ `Ctrl+8` | 切换到第 1~8 个标签 |
| `Ctrl+9` | 最后一个标签 |
| `Ctrl+Shift+R` | 重命名标签 |

鼠标：中键点标签关闭；点 `×` 关闭；标签栏滚轮切换；按住左键拖动重排；`Alt+点 +` 选择 profile。

## 窗格

| 快捷键 | 动作 |
|---|---|
| `Alt+Shift+-` | 左右分屏 |
| `Alt+Shift+加号` | 上下分屏 |
| `Alt+方向键` | 焦点移到相邻窗格 |
| `Ctrl+Shift+Z` | 放大 / 还原聚焦窗格 |
| `Ctrl+Shift+Alt+方向键` | 与相邻窗格交换 |
| `Ctrl+Shift+Alt+T` | 把窗格移到新标签 |
| `Alt+Shift+方向键` | 调整分隔线比例（每次 5%） |
| （无默认） | 关闭窗格：用命令面板，或自行绑定 `closePane` |

鼠标：拖动分隔线调整比例；点击窗格切换焦点；拖动右侧滚动条回看。

## 回看与滚动

| 快捷键 | 动作 |
|---|---|
| `Ctrl+Alt+↑` / `Ctrl+Alt+↓` | 向上 / 向下滚动一行 |
| `Shift+PageUp` / `Shift+PageDown` | 向上 / 向下翻页 |
| `Ctrl+Shift+End` | 回到最新输出 |
| `Ctrl+Shift+↑` | 跳到上一条命令（OSC 133） |
| `Ctrl+Shift+↓` | 跳到下一条命令 |
| `Ctrl+Shift+Home` | 跳到最早一条命令 |
| `Shift+滚轮` | 应用占用鼠标时强制回看 |

## 搜索、选择与剪贴板

| 快捷键 | 动作 |
|---|---|
| `Ctrl+Shift+F` | 搜索回看缓冲 |
| `Enter` / `Shift+Enter` | 搜索：下一个 / 上一个命中 |
| `Ctrl+Shift+C` | 复制选区 |
| `Ctrl+Shift+V` | 粘贴（多行会确认） |
| `Ctrl+Shift+M` | 进入 / 退出标记模式 |
| `Esc` | 清除选区 / 关闭面板 / 退出搜索 |
| `Alt+左键拖动` | 矩形（块）选择 |
| `Ctrl+点击` | 打开 OSC 8 超链接 |
| 右键 | 粘贴 |

## 标记模式

| 按键 | 作用 |
|---|---|
| 方向键 | 移动选区头 |
| `Ctrl+←/→` | 按单词移动 |
| `Home` / `End` | 行首 / 行尾 |
| `Ctrl+Home` / `Ctrl+End` | 缓冲首 / 尾 |
| `PageUp` / `PageDown` | 按可视高度移动 |
| `Enter` | 复制并退出 |
| `Ctrl+Shift+C` | 复制并退出 |
| `Esc` | 取消并退出 |

## 面板

| 快捷键 | 动作 |
|---|---|
| `Ctrl+Shift+P` | 命令面板（模糊匹配中文名与动作 id） |
| `Ctrl+S` | 设置面板 |
| `↑↓` / `Tab` / 滚轮 | 面板内选择行 |
| `←→` | 面板内循环取值 |
| `Enter` | 设置保存 / 面板执行 |
| `Esc` | 设置还原 / 面板关闭 |

## 命令行

| 命令 | 作用 |
|---|---|
| `scterm` | 启动客户端 |
| `scterm --layout <名称或表达式>` | 按布局打开多窗格 |
| `scterm --quake` | Quake 模式启动 |
| `scterm reload` | 校验并打印配置 |
| `scterm actions` | 列出动作与键位 |
| `scterm shell` | 自研 cmd 风格 shell |
| `scterm server` | 前台运行后台服务 |

## 下一步

- [自定义快捷键与命令面板](../keys-custom/)
- [常见问题与已知限制](../faq/)

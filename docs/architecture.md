# scterm 架构设计（阶段 0 基线）

> 目标：在 Windows Server Core（无 GUI）环境下，提供以 Windows Terminal 交互范式为蓝本的终端多路复用工具。
> 本文档固化分层边界、进程模型、IPC 协议、配置模型与能力降级策略；阶段 0 的实现必须严格落在本文件定义的接口内。

## 1. 目标与边界

**做**：ConPTY 驱动、UTF-8/VT 解析、字符网格渲染、标签/窗格、命令面板、动作系统、配置重载、本机多路复用。

**不做（明确非目标）**：
- 任何远程能力（SSH / WinRM / 远端 attach）；本机之外一律不涉及。
- GPU 渲染、亚像素字体、背景图/GIF/透明模糊——属 GUI 客户端（阶段 6）路径，Server Core 核心路径不实现。
- 彩色 emoji 字形渲染：降级为双宽占位。
- 图形化设置界面：配置只通过 TOML + `scterm reload`。

## 2. 分层边界（对齐 Windows Terminal）

代码层面必须显式分离四层，禁止跨层直接调用：

| 层 | 职责 | 允许依赖 | 阶段 0 状态 |
|---|---|---|---|
| `Connection` | 与 PTY 后端交互：ConPTY 创建/读写/Resize/回收；未来扩展 WSL、串口 | `platform` | ConPTY 完整实现 |
| `Emulation` | VT 字节流 → 屏幕状态（ScreenBuffer、光标、备用屏、滚动区） | 无（纯逻辑，可单测） | 仅透传，不解析（阶段 1 实现） |
| `Rendering` | 屏幕状态 → 终端输出（最小差异 VT 序列）；鼠标/键盘输入 → 动作或字节 | `Emulation` | 仅原始字节透传 |
| `Action` | 动作注册表 + 键位分发；命令面板与自定义快捷键的唯一样式入口 | 全部 UI 层能力的抽象接口 | 枚举骨架 + 分发器 |
| `Platform` | Win32 能力探测、控制台模式、版本判定、日志 | 系统 | 完整实现 |

**硬性规则**：任何 UI 操作必须表达为 `Action`，快捷键只绑定到 `Action`，不允许快捷键直接改 UI 状态。阶段 0 先把 `Action` 枚举与分发器立起来，后续新增功能只需注册，不需要改键位逻辑。

## 3. 进程模型

```
 scterm.exe (client)                     scterm.exe server (daemon)
 ┌──────────────────────┐                ┌───────────────────────────────┐
 │ raw console input    │  named pipe    │ Session                        │
 │ rendering loop       │◄──────────────►│  ├─ Tab 0 [pane tree]          │
 │ action dispatcher    │  binary frames │  │    └─ Pane → ConPTY → cmd    │
 └──────────────────────┘                │  └─ Tab 1 ...                  │
                                         └───────────────────────────────┘
```

- **隔离单位**：用户 SID。管道名 `\\.\pipe\scterm-<sid>`，安全描述符仅授予该 SID 与本机 SYSTEM，拒绝其他用户连接。
- **单实例**：server 启动时抢占命名互斥量 `Local\scterm-server-<sid>`；已被占用则直接退出（由已有 server 服务）。
- **自动拉起**：client 首次 `CreateFile` 失败（`ERROR_FILE_NOT_FOUND`）→ 以 `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP` 启动 `scterm.exe server --detached`（父进程退出不影响 server），随后以 50ms 间隔重试连接，上限 2s。
- **PTY 归属**：ConPTY 与其子进程句柄只存在于 server；client 断开不杀 PTY（支撑后续 attach/detach）。
- **回收顺序**（每个 Pane）：`ClosePseudoConsole` → 关闭管道 → `TerminateProcess` 兜底（若 3s 内未退出）→ 关闭进程/线程句柄。任何一步失败都记录 `error` 级日志，不得影响其他 Pane。

## 4. IPC 协议

### 4.1 帧格式（固定 12 字节头，小端）

```
offset 0  magic   4B  "SCTM"
offset 4  ver     1B  协议版本（当前 1）
offset 5  type    1B  帧类型
offset 6  flags   2B  预留，必须为 0
offset 8  length  4B  payload 长度（上限 1 MiB，超限即断连并记录）
offset 12 payload length 字节
```

payload 统一采用「定长结构体 + 可选变长尾部（UTF-8）」，字符串一律 `u32 len + bytes`，不依赖平台结构体布局。

### 4.2 帧类型

| type | 名称 | 方向 | payload |
|---|---|---|---|
| 0x01 | `Hello` | C→S | `proto_ver:u16, client_build:u32, caps:u32, cols:u16, rows:u16, profile:str` |
| 0x02 | `HelloAck` | S→C | `proto_ver:u16, server_build:u32, caps_negotiated:u32, session_id:u64` |
| 0x03 | `CreatePane` | C→S | `pane_id:u32, profile:str, cols:u16, rows:u16` |
| 0x04 | `PaneCreated` | S→C | `pane_id:u32, pid:u32` |
| 0x05 | `Input` | C→S | `pane_id:u32, bytes` |
| 0x06 | `Output` | S→C | `pane_id:u32, bytes`（阶段 4 起可被 `ScreenDiff` 替代） |
| 0x07 | `Resize` | C→S | `pane_id:u32, cols:u16, rows:u16` |
| 0x08 | `PaneExited` | S→C | `pane_id:u32, exit_code:i32` |
| 0x09 | `Ping` | 双向 | `token:u64` |
| 0x0A | `Pong` | 双向 | `token:u64` |
| 0x0B | `Error` | S→C | `code:u16, message:str` |
| 0x0C | `ClosePane` | C→S | `pane_id:u32` |
| 0x0D | `ScreenDiff` | S→C | 阶段 4 启用：`pane_id, x,y,w,h, cells[]` |
| 0x0E | `ActionRequest` | C→S | 阶段 5 启用：插件/可编程控制平面 |

### 4.3 握手与降级

1. client 发 `Hello`，携带自身 build 与能力位；server 回 `HelloAck`，能力位取**交集**（双方都支持才为真）。
2. 协议版本取 `min(client, server)`；主版本不一致时 server 回 `Error{code=0x0001}` 并断连。
3. 阶段 0 仅协商以下能力位（其余保留）：

| bit | 能力 | 探测来源 |
|---|---|---|
| 0 | `TRUECOLOR` | 配置 `render.truecolor` + conhost 版本 |
| 1 | `MOUSE_REPORT` | build ≥ 18362 且 `render.mouse=true` |
| 2 | `BRACKETED_PASTE` | 恒为真（由本工具自身实现） |
| 3 | `OSC52` | 配置开启且未被探测失败标记 |
| 4 | `SIXEL` | 阶段 3 探测，阶段 0 恒假 |

## 5. 配置模型（TOML）

路径：`%APPDATA%\scterm\config.toml`。缺失时首次运行写出默认配置；解析失败不覆盖用户文件，回退内置默认值并打印中文错误。

```toml
default_profile = "scterm"
scrollback = 10000

[render]
mouse = true                  # 自动叠加上表 build 判定
truecolor = "auto"            # auto | always | never
font_face = "Consolas"        # 可选：控制台字体（需系统已安装，Server Core 可用字体有限）
font_size = 16                # 可选：字号像素高度（6–72）
gradient = "vertical"         # 背景渐变：off | vertical | horizontal | diagonal
# gradient_top = "#2b3440"    # 可选：自定义渐变两端颜色；不写则按配色背景自动推导
# gradient_bottom = "#05070a"

[behavior]
copy_on_select = false        # 选中文本松开鼠标即复制到剪贴板

# 自研 shell：command = "@self" 由配置加载时替换为 scterm.exe 的真实路径
[[profiles]]
name = "scterm"
command = "@self"
args = ["shell"]
cwd = "%USERPROFILE%"
color_scheme = "Campbell"

[[profiles]]
name = "pwsh"
command = "pwsh.exe"
args = ["-NoLogo"]
cwd = "%USERPROFILE%"
color_scheme = "Campbell"

[[profiles]]
name = "cmd"
command = "cmd.exe"
cwd = "C:\\"

[[color_schemes]]
name = "Campbell"
foreground = "#CCCCCC"
background = "#0C0C0C"
cursor = "#FFFFFF"
selection = "#264F78"
# 16 色 ANSI 调色板：ansi_0..ansi_15，顺序为 黑/红/绿/黄/蓝/紫/青/白 + 亮色 8 项
ansi_0 = "#0C0C0C"
ansi_1 = "#C50F1F"
ansi_2 = "#13A10E"
ansi_3 = "#C19C00"
ansi_4 = "#0037DA"
ansi_5 = "#881798"
ansi_6 = "#3A96DD"
ansi_7 = "#CCCCCC"
ansi_8 = "#767676"
ansi_9 = "#E74856"
ansi_10 = "#16C60C"
ansi_11 = "#F9F1A5"
ansi_12 = "#3B78FF"
ansi_13 = "#B4009E"
ansi_14 = "#61D6D6"
ansi_15 = "#F2F2F2"

[[actions]]
command = "splitPane"
keys = "alt+shift+d"          # 为空字符串表示仅命令面板可用
```

约束：
- `actions` 允许覆盖默认键位；同一 `keys` 冲突时后出现者生效并打印警告。
- profile 中引用的 `color_scheme` 不存在时回退到内置 Campbell 并警告。
- `ansi_*` 只写一部分时，未写或非法的项回退到 Campbell 对应颜色并警告；一项都不写则沿用宿主终端的 ANSI 配色；旧配置里与内置同名的方案会自动补齐内置调色板。
- 内置配色有 64 套（16 套 Windows Terminal 官方 + 48 套常用社区主题），无需写进配置文件；`scterm reload` 会列出全部名字。
- `cwd` 支持 `%VAR%` 展开，展开失败回退 `%USERPROFILE%`。
- `command = "@self"` 在 `Config::normalize()` 中替换为 `std::env::current_exe()`；服务端解析 profile 时即得到 `<scterm.exe> shell`。
- 出厂默认 profile 为 `powershell`（探测 `pwsh.exe`，缺失时回退 Windows PowerShell 5.1）；自研 shell（`scterm`）与 `cmd` 仍保留在 profile 列表里，可在设置面板切换。
- 旧版配置（只有 cmd / pwsh、`default_profile = "cmd"`）加载时自动补上 `scterm` profile，并把仍指向 cmd 的旧默认迁到 `powershell`，同时在 `scterm reload` 里以「提示」形式告知；用户显式写 `default_profile = "cmd"` 仍然生效。

## 6. 能力探测与降级矩阵

| 能力 | 探测/判定 | 降级策略 |
|---|---|---|
| ConPTY 可用性 | `CreatePseudoConsole` 返回失败 | 报错并退出，提示最低系统要求（Win10 1809 / Server 2019） |
| 鼠标上报 | build < 18362 视为缺陷版本 | 强制关闭 `?1000/1002/1006`，记录 WARN，命令面板中该动作置灰 |
| 真彩色 | 配置 + 探测 | 降级 256 色，再降 16 色 |
| 备用屏幕 `?1049` | 恒支持 | 无 |
| 宽字符/CJK | 内置宽度表 + East Asian Width | 未知宽度按 1 处理并记录一次 |
| emoji | 无彩色字形 | 双宽占位单元格 |
| Sixel/内联图像 | 阶段 3 探测 | 半块字符近似；不支持则关闭并提示 |
| OSC 52 剪贴板 | 尝试设置 + 超时无回执 | 内部粘贴缓冲 |
| 背景图/透明/亚像素 | 平台不支持 | 文档标注「WT 桌面端专属」 |

日志：`%LOCALAPPDATA%\scterm\logs\scterm-YYYYMMDD.log`，UTF-8，滚动保留 7 天。`--verbose` 提升到 debug 级；默认 info。所有日志与用户可见错误信息使用中文。

## 7. 代码结构

```
src/
  main.rs            CLI：client / server / reload / actions / --verbose / --help
  proto/
    mod.rs           帧编解码（12B 头 + payload，长度上限校验）
    msg.rs           各帧 payload 结构体（小端编解码）
    caps.rs          能力位与协商
  ipc/
    pipe.rs          命名管道（SID 安全描述符 + 重叠 I/O 读写）
    server.rs        server 主循环：accept、连接线程 + 写线程、窗格表、profile 解析
    client.rs        连接、自动拉起、输入分发、输出渲染、尺寸同步
  term/
    conpty.rs        CreatePseudoConsole/Resize/Close、属性列表、启动目录、输出泵
  emulation/
    screen.rs        字符网格、Cell/Attrs/Color、光标、滚动区、备用屏幕、回看缓冲
    parser.rs        VT 状态机（CSI/OSC/ESC/DCS）+ UTF-8 解码 + DSR 回写
  render/
    mod.rs           差异渲染（最小 VT 序列）、SGR 生成、256 色降级
  ui/
    app.rs           应用状态：标签页、窗格树、面板/搜索、合成绘制、动作执行
    layout.rs        Rect / Node（Leaf|Split）/ 布局与邻接焦点
    palette.rs       命令面板模糊匹配
    search.rs        回看缓冲搜索与导航
  input/
    mod.rs           控制台输入记录 → Chord / VT 字节；键盘全键位翻译
  config/
    mod.rs           配置模型、默认值、校验、默认配置落盘
    toml.rs          零依赖 TOML 子集解析器
  platform/
    win32.rs         手写 Win32 FFI
    console.rs       原始输入 / VT 输出、输入记录、尺寸读取、模式恢复
    clipboard.rs     CF_UNICODETEXT 读写（Ctrl+Shift+V 与 OSC 52）
    version.rs       build 号与鼠标能力判定
    logging.rs       UTF-8 文件日志
  action/
    mod.rs           Action 枚举 + Chord + 可配置键位注册表
  shell/
    mod.rs           自研 shell 主循环、控制台模式切换、输出（含重定向）抽象
    lineedit.rs      行编辑：重绘、历史、Ctrl+C/Ctrl+L、Tab 补全调用
    parse.rs         变量展开、分词、引号/^ 转义、管道与重定向
    complete.rs      命令 / 别名 / PATH / 文件补全
    builtins.rs      cd dir cls echo set type del mkdir copy move where alias history run ver help exit
    exec.rs          别名展开、内置命令分发、外部程序、管道与重定向
    script.rs        .sct 脚本（每行一条命令，# 注释）
  e2e.rs             集成测试：ConPTY / 管道 / 渲染 / 真实客户端冒烟
```

阶段 3 在 `render/` 补鼠标与括号粘贴、OSC 8/52、Sixel 降级与配色方案细化；阶段 4 引入 `ScreenDiff` 帧与 IOCP 泵。

## 8. 阶段 1 实现说明

**VT 覆盖范围**（`emulation/parser.rs`）：

| 类别 | 已支持 |
|---|---|
| 光标 | CUU/CUD/CUF/CUB、CNL/CPL、CHA/VPA、CUP/HVP、CHT/CBT、DECSC/DECRC、`s`/`u` |
| 擦除 | ED 0/1/2/3、EL 0/1/2、ECH |
| 插入删除 | IL/DL、ICH/DCH、SU/SD |
| 模式 | DECCKM(1)、DECOM(6)、DECAWM(7)、DECTCEM(25)、47/1047/1048/1049、1000/1002/1003/1005/1006、2004 |
| 滚动 | DECSTBM 区域 + 区域内滚动；主屏触底滚动进入回看缓冲 |
| 颜色 | 16 色、256 色、真彩色（38/48;5;n、38/48;2;r;g;b）、全部常用 SGR 属性 |
| 字符串 | OSC 0/1/2 标题；DCS/SOS/PM/APC 整体忽略 |
| 查询 | DSR 6n 光标位置、DA/DA2、DECRQM（`?Ps$p`）——结果写入 `responses`，由客户端作为输入帧回写给子进程 |

**渲染**（`render/mod.rs`）：与上次绘制结果逐格比对，只对变化行输出 `CUP + SGR + 文本`；绘制期间关闭自动换行（`?7l`）避免右下角触发滚动，结束后恢复。宽字符只写首格（右半格标记 `ATTR_WIDE_TAIL` 跳过），组合符宽度 0 忽略。

**已知限制（进入阶段 2/3 前不会修复）**：
- 尺寸变化不做重排（reflow），只保留左上角内容——与 ConPTY 自身行为一致。
- 回看缓冲只收集不显示（滚动查看与搜索属阶段 2）。
- 鼠标、括号粘贴、OSC 8/52、Sixel 未启用（阶段 3）。
- 未实现 REP(`b`)、DECALN(`#8`)、DECSLRM 左右滚动区。


## 9. 阶段 2 实现说明

**配置**（`config/`）

- 位置：`%APPDATA%\scterm\config.toml`（可用环境变量 `SCTERM_CONFIG` 覆盖），首次运行自动写出默认配置。
- 自研 TOML 子集解析器（零第三方依赖）：注释、`[table]`、`[[array of tables]]`、字符串/整数/布尔/字符串数组。
- 解析失败**不覆盖**用户文件：回退内置默认值，把中文错误写进日志与状态栏。
- 客户端每秒比对文件 mtime，变化即重载（对齐 WT「改完即生效」）。`scterm reload` 校验并打印配置，`scterm actions` 列出所有动作与当前键位。

**全屏绘制的两个硬约束**

- 画布尺寸必须用**可见窗口**（`GetConsoleScreenBufferInfo().srWindow`）：`WINDOW_BUFFER_SIZE_RECORD.dwSize` 是缓冲区尺寸，conhost 默认 9001 行，直接采用会让画布变成 9001 行高、窗口被顶到最底部，看起来就是「所有内容堆在最后一行」。
- 启动与每次尺寸事件后调用 `SetConsoleScreenBufferSize(窗口宽高)` 把缓冲区钉成窗口大小（先 `SetConsoleWindowInfo` 归位），否则 conhost 会滚动窗口跟随光标，绝对坐标绘制会漂移。

```toml
default_profile = "cmd"
scrollback = 10000
[render]
mouse = true
truecolor = "auto"        # auto | always | never

[[profiles]]
name = "pwsh"
command = "pwsh.exe"
args = ["-NoLogo"]
cwd = "%USERPROFILE%"
color_scheme = "Campbell"

[[actions]]
command = "splitPaneHorizontal"
keys = "alt+shift+d"      # 留空 = 只出现在命令面板
```

**动作与键位**（`action/` + `input/`）

| 机制 | 说明 |
|---|---|
| Chord | `{ctrl, alt, shift, key}`，支持 `ctrl+shift+t`、`alt+shift+plus`、`ctrl+tab`、`f5` 等写法 |
| 覆盖规则 | 同一动作换键会移除旧绑定；同一键重复绑定后者生效并告警（与 WT 一致） |
| 输入路径 | `ReadConsoleInputW` → 先匹配 Chord → 命中则执行动作（不转发）；否则翻译成 VT 字节转发给窗格 |
| 翻译覆盖 | 方向键/Home/End/PgUp/PgDn/Ins/Del/F1–F12 的修饰键参数、Ctrl+字母控制码、Alt 前缀 ESC、DECCKM 应用光标键模式、Shift+Tab→`ESC[Z`、Backspace→`0x7f` |

默认键位：`Ctrl+B`（新建标签）、`Ctrl+Shift+W`（关闭标签）、`Ctrl+Tab`/`Ctrl+Shift+Tab`（切换）、`Ctrl+1`~`Ctrl+8`（直达标签，`Ctrl+9` 最后一个）、`Ctrl+Shift+R`（重命名标签）、`Alt+Shift+-/+`（左右/上下分屏）、`Alt+方向`（焦点）、`Ctrl+Shift+P`（命令面板）、`Ctrl+S`（设置）、`Ctrl+Shift+F`（搜索）、`Ctrl+Shift+↑/↓`（回看滚动）。

**标签页与窗格**（`ui/app.rs` + `ui/layout.rs`）

- 顶部标签栏固定在第 0 行：` 1:powershell ×  2:cmd ×   + `，当前标签反色；每个标签末尾有独立的 3 列关闭按钮（`×` 居中、整块可点），「+」是 3 列宽的绿色按钮并与标签空一格；中键点标签关闭，滚轮在标签栏切换标签。
- 底部状态栏固定在最下面一行：左侧常驻快捷键提示（按可用宽度从三档里取最长能整段放下的版本，极窄时截断），右侧显示临时状态、回看偏移与当前目录（空间不足时优先截断目录/状态）。窗格内容区 = 第 1 行到倒数第 2 行。
- 每个标签持有独立窗格树：`Leaf(id)` / `Split{axis, ratio%, first, second}`；最小窗格 2×1，空间不足退化为只画第一个窗格。
- 分隔线占 1 列/1 行；与聚焦窗格相邻的分隔线用高亮色。
- `Alt+方向` 按几何中心距离找相邻窗格；关闭窗格时父节点折叠为兄弟节点；最后一个窗格关闭即关闭标签，最后一个标签关闭即退出。
- 每个窗格的 `Screen` 尺寸 = 它的矩形尺寸；布局变化时自动 `resize` 并通过 Resize 帧同步给 ConPTY。

**命令面板与搜索**

- 命令面板（`Ctrl+Shift+P`）：子序列模糊匹配「中文名 + 动作 id」，显示快捷键提示，未绑定动作也能执行；`↑↓` 选择、`Enter` 执行、`Esc` 关闭。
- 搜索（`Ctrl+Shift+F`）：在「回看缓冲 + 当前屏幕」中匹配，命中反色高亮、当前命中加粗，`Enter`/`Shift+Enter` 上下导航并自动滚动到命中行。
- 回看滚动：`Ctrl+Shift+↑/↓` 逐行滚动，`Esc` 退出搜索并回到最新输出。

**设置面板（`Ctrl+S`）**

- 行：配色方案（64 套内置 + 自定义）、默认 profile、背景渐变（关闭/竖向/横向/斜向）、渐变配色（自动/深蓝/紫黑/青灰/暖灰/深绿/酒红/棕金/蓝紫/石墨/冰蓝/粉紫/军绿，共 13 套）、真彩色、字体（默认/Consolas/Cascadia/Lucida Console/宋体…）、字号、回看行数、鼠标上报、选中即复制。
- 交互：`↑↓`/`Tab`/滚轮选择行，`←→` 或点行右半边/左半边循环取值，点行首选中；改动**立即生效**（字号/字体调 `SetCurrentConsoleFontEx`，鼠标调 `SetConsoleMode`）；`Enter` 写回配置文件，`Esc` 按打开时的快照回滚。
- 写回策略：`config::patch_config` 只替换对应键（缺失的键插到所属段落末尾、`自动` 时删除 `gradient_top/bottom`），注释、自定义 profile / 配色 / 快捷键原样保留；先写 `.tmp` 再替换，避免写坏文件。

**阶段 2 已知限制**：鼠标拖拽调整分屏比例未实现（随阶段 3 鼠标上报一起做）；分屏比例固定 50/50；标签栏不支持侧边布局与拖拽重排。

## 10. 阶段 0 验收清单

| # | 项 | 判定方式 |
|---|---|---|
| 1 | `cargo build --release` 产出单个 `scterm.exe`（静态 CRT，无外部依赖） | 依赖检查器无 VC 运行库依赖 |
| 2 | `scterm` 默认打开 cmd 并可交互执行命令 | 手工冒烟 |
| 3 | 中文/emoji 输出不乱码，CJK 宽度正确 | 手工冒烟（仅透传阶段验证不乱码） |
| 4 | 窗口缩放后子进程收到新尺寸 | 在 cmd 中执行 `mode` / PowerShell `$Host.UI.RawUI.WindowSize` |
| 5 | 子进程退出后打印退出码并恢复终端状态 | 执行 `exit 3` |
| 6 | 客户端首次启动可自动拉起 server，二次启动复用 | 进程列表 + 日志 |
| 7 | 非当前用户 SID 连接被拒绝 | 管道 ACL 检查 |
| 8 | `--verbose` 生成日志文件且 UTF-8 中文正常 | 查看日志 |
| 9 | build < 18362 时输出鼠标降级 WARN | 单元测试 `version::probe_mouse_support` |
| 10 | 断连（Ctrl+C 客户端）后 PTY 仍在，重连可继续 | 手工冒烟（attach 属阶段 4，此处仅验证不泄漏/不崩溃） |

**待真机验证**：Server Core 2019 / 2022 / 2025 与 Windows PE 的 ConPTY 可用性、鼠标缺陷阈值、Sixel/OSC 52 能力位——当前无测试机，本机（Win10 19044）通过后在文档回填结论。

## 11. 阶段 1 验收清单

| # | 项 | 判定方式 | 状态 |
|---|---|---|---|
| 1 | VT 解析与网格操作正确 | 单测（光标/擦除/插删/滚动区/SGR/宽字符/备用屏/DSR） | 通过 |
| 2 | 差异渲染只重绘变化区域 | 单测 `render::tests::only_changed_region_is_repainted` | 通过 |
| 3 | 真彩色 SGR 输出 | 单测 `truecolor_sgr_is_emitted` | 通过 |
| 4 | 真实 cmd 输出能被解析并渲染 | 集成测试 `emulation_renders_real_conpty_output` | 通过 |
| 5 | 真实客户端在伪控制台内正确绘制并转发按键 | `cargo test zz_client_console_smoke -- --ignored` | 通过 |
| 6 | 备用屏幕切回主屏内容不丢 | 单测 `alt_screen_switch_by_1049` / `alt_screen_restores_main_content` | 通过 |
| 7 | 窗口标题跟随 OSC 0/2 | 单测 `title_from_osc` + 手工观察控制台标题 | 单测通过，真机待看 |
| 8 | 缩放后子进程收到新尺寸、画面重绘 | 手工：cmd 中 `mode`、PowerShell `$Host.UI.RawUI.WindowSize` | 待真机手工 |
| 9 | 子进程退出打印退出码并恢复终端 | 手工：`exit 3` | 待真机手工 |
| 10 | 中文输入法可用 | 手工：在 cmd/PowerShell 中输入中文 | 待真机手工（依赖 conhost IME） |

## 12. 阶段 2 验收清单

| # | 项 | 判定方式 | 状态 |
|---|---|---|---|
| 1 | 配置解析（表/表数组/注释/转义）、默认配置生成、错误回退 | 单测 `config::tests::*` | 通过 |
| 2 | 键位解析与自定义绑定覆盖 | 单测 `action::tests::*`、`ui::app::tests::custom_binding_from_config_is_used` | 通过 |
| 3 | 标签新建/切换/关闭，每个标签独立窗格树 | 单测 `tab_navigation_wraps`、`closing_tab_keeps_other_tabs_alive` | 通过 |
| 4 | 分屏/嵌套/关闭折叠/焦点移动 | 单测 `split_creates_second_pane_and_moves_focus`、`closing_split_pane_restores_full_rect`、`layout::tests::*` | 通过 |
| 5 | 命令面板模糊搜索并执行未绑定动作 | 单测 `palette_opens_and_lists_actions` | 通过 |
| 6 | 搜索回看缓冲 + 命中导航 | 单测 `search::tests::*`、`search_finds_history_and_scrolls` | 通过 |
| 7 | 快捷键不转发、普通字符正常转发 | 单测 `shortcut_dispatches_action_instead_of_forwarding`、`input::tests::*` | 通过 |
| 8 | 标签栏与窗格内容合成绘制 | 单测 `paint_draws_tab_bar_and_pane_content` | 通过 |
| 9 | 真实客户端渲染 + 按键转发 | `cargo test zz_client_console_smoke -- --ignored` | 通过 |
| 10 | 修改 config.toml 后热重载 | 手工：改配色/profile 后观察画面与状态提示 | 待真机手工 |
| 11 | 鼠标拖拽调整分屏比例 | 未实现（阶段 3） | 未开始 |

## 13. 已实测确认的平台约束（阶段 0）

以下三条是阶段 0 在本机（Windows 10 19044）上实测踩出来的硬约束，代码里已固化，后续不得回退：

| 约束 | 现象 | 处置 |
|---|---|---|
| **命名管道必须用重叠 I/O**（`FILE_FLAG_OVERLAPPED`） | 同步句柄在同一句柄上跨线程并发读写会被 I/O 管理器串行化，读写互锁；且 `WaitForSingleObject` 对同步管道句柄总是返回就绪，无法用于「等待可读」 | 服务端/客户端读写各自独立线程，全部走 `OVERLAPPED` + `GetOverlappedResult`；超时读取用 `CancelIoEx` 收尾 |
| **创建伪控制台前必须脱离控制台并清空标准句柄** | 父进程若持有控制台，或标准句柄指向文件/NUL（分离启动时即如此），子进程会继承这些句柄而不挂到伪控制台：`CreateProcess` 返回成功，但 PTY 一个字节都读不到，子进程输出直接落到父进程的 stdout | `Pane::spawn` 内统一执行 `FreeConsole()` + `SetStdHandle(STD_INPUT/OUTPUT/ERROR, NULL)` |
| **`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` 的用法** | 常量值为 `0x00020016`（`ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)`，与 Windows SDK 一致）；`UpdateProcThreadAttribute` 的 `lpValue` 必须**直接传 HPCON 本身**，传 `&HPCON` 会绑定错误的句柄 | 见 `platform/win32.rs` 与 `term/conpty.rs` 中的注释 |
| **ConPTY 输出管道必须用重叠 I/O** | 客户端进程退出后，本机 conhost **不会**关闭输出管道；同步 `ReadFile` 会永久阻塞，`PaneExited` 永远发不出去（cmd 时代同样存在） | `term/conpty.rs` 用 `CreateNamedPipeW(PIPE_ACCESS_INBOUND \| FILE_FLAG_OVERLAPPED)` 做读端，`WaitForMultipleObjects({管道事件, 进程})` 同时等数据与退出；进程退出后再等 300ms 排空，最后 `CancelIoEx` 收尾 |

日志与排错定位：`%LOCALAPPDATA%\scterm\logs`。

## 14. 风险与未决项

| 风险 | 影响 | 应对 |
|---|---|---|
| Windows PE 缺少 ConPTY 依赖（conhost 组件被精简） | 阶段 0 目标环境之一不可用 | 真机验证后决定是否提供「无 ConPTY 降级」或明确不支持 |
| 原始输入模式下 conhost 输入法（IME）失效 | 中文输入不可用 | 阶段 1 优先验证：保持 `ENABLE_PROCESSED_INPUT` 的 IME 路径，必要时改用 `ReadConsoleInputW` + IME 组合消息 |
| Server 2019 鼠标上报缺陷具体修复版本 | 阈值定错导致误开/误关 | 阈值集中在 `version.rs` 单点，真机回填 |
| 每窗格 2 线程（读/写）在大量窗格下线程数膨胀 | 资源占用 | 阶段 4 改为 IOCP/重叠 I/O 单线程泵 |
| 静态 CRT + 单文件与后续可选依赖冲突 | 分发形态退化 | 阶段 5 引入插件仅作为外部进程，不链接进主二进制 |

## 15. 阶段映射

| 阶段 | 本文档对应落点 |
|---|---|
| 0 | 第 3、4、6 节 + 第 7 节目录骨架 + 第 9 节验收 |
| 1 | `emulation/`、`render/`（单窗格 `ui/session.rs` 已在阶段 2 被 `ui/app.rs` 取代），协议不变（第 8、11 节） |
| 2 | `config/`、`action/`、`input/`、`ui/app.rs`、`ui/layout.rs`、`ui/palette.rs`、`ui/search.rs`（第 9、12 节） |
| 2.5 | 自研 shell：`shell/`、`config/` 的 `@self` profile（第 16、17 节） |
| 3 | 鼠标上报、滚轮回看、拖拽分屏、剪贴板粘贴、OSC 52、重叠 I/O 退出检测（第 18、19 节） |
| 4 | `ScreenDiff` 启用、心跳、稳定 pane_id、attach |
| 5 | `ActionRequest` 启用、后端抽象（WSL/串口） |
| 6 | 独立 GUI 客户端复用第 4 节协议，不进核心路径 |
| 7 | 兼容矩阵与自动化测试补齐 |

## 16. 自研 shell 实现说明

**运行形态**：`scterm shell` 是 scterm.exe 的子命令，由默认 profile 启动（`command = "@self"`、`args = ["shell"]`）。它本身运行在窗格的 ConPTY 里，是一个真正的控制台进程，因此在其中再启动 vim / python 等交互式程序也能正常接管键盘。

**控制台模式切换**（`shell/mod.rs`）

| 状态 | 标准输入模式 | 用途 |
|---|---|---|
| 原始（行编辑） | `ENABLE_EXTENDED_FLAGS \| ENABLE_WINDOW_INPUT` | `ReadConsoleInputW` 逐键读取，Ctrl+C 作为按键而不是信号 |
| 初始（子进程） | 启动时保存的原始模式 | 子进程获得行缓冲/回显/Ctrl+C 信号，可正常交互 |
| 标准输出 | 始终 `ENABLE_PROCESSED_OUTPUT \| ENABLE_VIRTUAL_TERMINAL_PROCESSING` | 行编辑与内置命令都依赖 VT 序列 |

- 启动子进程前切回初始模式，`WaitForSingleObject`/`wait` 结束后再切回原始模式，并 `FlushConsoleInputBuffer` 丢弃键入残留。
- 用 `SetConsoleCtrlHandler` 注册「返回 TRUE」的处理函数：Ctrl+C 只打断子进程，不会杀掉 shell 自身。
- 退出（`exit` / 关闭窗格）时 `Drop` 恢复进入前的两种控制台模式。

**行编辑**（`shell/lineedit.rs`）

- 每次按键都回到提示符所在行首：`CSI n A` + `\r` + `CSI J` 清块，再重画提示符与缓冲；多行（自动换行）与宽字符不会留残影，光标用 `CSI n G` 定位。
- 支持 ←/→、Home/End、Del、Backspace，Ctrl+A/E/U/K/W，↑/↓ 历史（含临时行保存），Ctrl+C 取消当前行，Ctrl+L 清屏，Tab 补全（多候选时按列打印后重画）。
- Ctrl+字母同时兼容两种到达形式：Ctrl 修饰位，或控制字符 0x01–0x1a（ConPTY 直接转发的形式）。

**语法**（`shell/parse.rs`）

| 特性 | 说明 |
|---|---|
| 变量 | `%NAME%`（cmd 风格）、`$NAME`、`${NAME}`；未定义为空串；展开发生在分词前，引号内同样展开 |
| 引号 | 双引号与单引号都只用于分组，引号本身不进入参数 |
| 转义 | `^x` 输出字面量 x（管道/重定向符号前需要） |
| 管道 | `a \| b \| c`，`std::process` 的 `Stdio::piped()` 串联 |
| 重定向 | `>`、`>>`、`<`、`2>`、`2>>`；内置命令支持 `>`/`>>`（输出写入 `Shell::out`） |

**内置命令**（`shell/builtins.rs`）

`cd`（无参回 `%USERPROFILE%`，支持 `~`、`..` 归一化，`chdir` 同义）、`dir`（修改时间/大小/名称 + 汇总，支持 `*.txt` 通配符）、`pwd`、`cls`、`echo`（`echo.` 空行，`echo off/on` 与 cmd 一样不输出）、`set`（查看/设置/删除变量，`set /a` 计算整数表达式）、`type`（支持通配符）、`del`/`erase`（支持通配符）、`mkdir`/`md`、`rmdir`/`rd`、`copy`（源支持通配符）、`move`（源支持通配符）、`ren`/`rename`（只改名，与 cmd 一致）、`pushd`/`popd`（目录栈，无参时与栈顶交换）、`where`、`title`（OSC 2 标题）、`prompt`（cmd 风格 `$P$G/$D/$T/$_/$$`）、`vol`（卷标/序列号/文件系统）、`date`/`time`（只读，支持 `/t`）、`chcp`（固定 UTF-8）、`pause`、`alias`、`history [-c]`、`run *.sct [参数...]`、`ver`、`help`、`exit [码]`。

**执行**（`shell/exec.rs`）

- 别名展开（最多 8 层）→ 单命令：内置命令直接执行，其余用 `std::process::Command` 启动；多命令走管道。
- 管道**首段可以是内置命令**：内置命令输出进内存缓冲，再由后台线程写进下游进程的 stdin（`dir | findstr txt`、`echo hi | findstr hi`）。
- 外部程序共享当前控制台与工作目录；环境变量改动（`set`）对子进程生效。
- 子进程退出码写入环境变量 `ERRORLEVEL`，可用 `%ERRORLEVEL%` 读取。
- `.bat` / `.cmd` 需要 cmd.exe，遇到时给出明确中文提示。

**脚本**（`shell/script.rs`）

- 先解析成语句树（`Command` / `Label` / `Goto` / `Call` / `Return` / `If` / `For`），再由解释器执行；空行、`#`、`::` 是注释，行首 `@` 忽略（脚本本来就不回显命令）。
- `if` 支持 `exist` / `errorlevel N` / `defined VAR` / 字符串 `==`（可加 `not`、`/i`）；执行体可以是单条命令或 `( ... )` 括号块（可跨行；`else` 与 `)` 同行或写在下一行都识别）。
- `for` 支持普通通配符集合、`/d`（只遍历目录）、`/l`（`(起,步长,止)` 闭区间，上限 100 万次）、`/r [根]`（递归遍历，跳过符号链接）；`for /f` 明确报「暂不支持」。
- 循环变量 `%%i` / `%i` 每轮执行前替换：大小写不敏感、只匹配完整词，不会误改 `%PATH%`。
- `goto 标签` 跳转（可跳出括号块）；`call :子程序 [参数]` 递归执行标签后的语句，进入时替换 `%1`…/`%*`，返回时恢复参数帧（最多 64 层）；`call 其它.sct` 复用同一套脚本引擎；`exit /b [码]` 在子程序内返回、在顶层结束，并把码写入 `ERRORLEVEL`。
- 每条普通命令执行前把 `ERRORLEVEL` 置 0、失败置 1；外部程序退出码由 `exec` 写入。参数替换发生在命令执行前，`%1` 与 `%VAR%` 互不干扰。
- `set /a` 整数表达式：`+ - * / % << >> & ^ | ~ !`、括号、逗号、`0x` 十六进制、前导 0 八进制；变量按环境变量取值（未定义为 0）。逗号按 cmd 语义分多段、逐段求值/赋值：**命令行里总是打印最后一段的值**（`set /a n=1` 输出 `1`，`set /a a=1,b=2` 输出 `2`），**脚本（`run`）里一律不打印**（与 cmd 批处理一致）；除数为零报错。运算使用 64 位整数（cmd 为 32 位，超出 32 位范围时结果可能不同）。

**已知限制**：管道中只有第一段可以是内置命令（后续段必须是外部程序）；内置命令不支持 `<` 输入重定向；Tab 补全不处理引号内路径；脚本不支持 `for /f` 与延迟变量展开（`!var!`），`goto` 只在当前子程序内解析标签（不能从子程序跳回主流程）；脚本不逐行回显命令（相当于始终 `@echo off`），`echo` 无参数输出空行（cmd 输出「ECHO 处于打开状态。」）。

## 17. 自研 shell 验收清单

| # | 项 | 判定方式 | 状态 |
|---|---|---|---|
| 1 | 变量展开（`%VAR%` / `$VAR` / `${VAR}`）与未定义变量为空 | 单测 `shell::parse::tests::expands_percent_and_dollar` | 通过 |
| 2 | 引号分组、管道与重定向解析、错误提示 | 单测 `shell::parse::tests::*` | 通过 |
| 3 | 光标换行位置计算与 Ctrl+W 删词 | 单测 `shell::lineedit::tests::*` | 通过 |
| 4 | 命令 / 别名 / 文件补全与公共前缀 | 单测 `shell::complete::tests::*` | 通过 |
| 5 | `set`/`alias` 参数解析、`dir` 排序、PATH 查找 | 单测 `shell::builtins::tests::*` | 通过 |
| 6 | 脚本注释过滤与行号 | 单测 `shell::script::tests::skips_comments_and_blanks` | 通过 |
| 7 | `scterm` profile 的 `@self` 展开为可执行文件路径（默认 profile 为 `powershell`） | 单测 `config::tests::self_command_is_expanded`、`config::tests::parses_config_document` | 通过 |
| 8 | 客户端/服务端协议与既有功能不回归 | `cargo test --quiet -- --test-threads=1 --skip e2e::`（153 项） | 通过 |
| 9 | 真实窗格中提示符、输入回显、内置命令与外部命令 | `cargo test zz_shell_smoke -- --ignored --test-threads=1`（release 构建后运行） | 通过 |
| 10 | 管道与重定向 | 同上（脚本内含 `cmd /c echo ... \| findstr ... > file` 与 `echo ... \| findstr ... > file`） | 通过 |
| 11 | Ctrl+C 取消当前行 / 打断子进程，子进程结束后 shell 存活 | 手工：`ping 127.0.0.1 -n 10` 后按 Ctrl+C，再按回车 | 待真机手工 |
| 12 | Tab 补全、↑↓ 历史、Ctrl+L 清屏 | 手工 | 待真机手工 |
| 13 | 通配符展开 | 单测 `wildcard_matching`、`glob_expands_in_directory` | 通过 |
| 14 | 脚本参数 `%1` / `%*` | 单测 `substitutes_positional_arguments` | 通过 |
| 15 | 内置命令作为管道首段 | e2e `zz_shell_smoke_via_release_binary` | 通过 |
| 16 | `if` 条件解析（`exist` / `defined` / `errorlevel` / `==`，含 `not`、`/i`） | 单测 `splits_condition_keywords`、`evaluates_conditions` | 通过 |
| 17 | `if / else` 单行与跨行括号块 | 单测 `parses_single_line_if_else`、`parses_multiline_if_else`；e2e `zz_script_smoke_via_release_binary` | 通过 |
| 18 | `for` 各形式（普通 / `/d` / `/l` / `/r`）解析 | 单测 `parses_for_forms`、`numeric_for_produces_inclusive_range` | 通过 |
| 19 | 循环变量替换不误伤 `%PATH%` | 单测 `loop_variable_replacement_handles_batch_syntax` | 通过 |
| 20 | `call :子程序` 参数拆分与 `%1` / `%*` 展开 | 单测 `splits_call_arguments`、`substitutes_positional_arguments`；e2e 脚本冒烟 | 通过 |
| 21 | `goto` 跳过命令 / `exit /b` 写退出码 | e2e 脚本冒烟（`goto :done` 跳过 `echo skipped`，`exit /b 7` 后 `%errorlevel%` 为 7） | 通过 |
| 22 | `set /a` 整数表达式（优先级、括号、位移、位运算、进制、变量、除零报错） | 单测 `arithmetic_expressions_follow_cmd_rules` | 通过 |

## 18. 阶段 3 实现说明

**退出检测（重叠 I/O）**（`term/conpty.rs`）

- 输出管道改为命名管道读端（`PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED`），写端交给 `CreatePseudoConsole`。
- 输出泵用 `ReadFile(..., &OVERLAPPED{hEvent})` + `WaitForMultipleObjects({事件, 进程})`：数据到达就读；进程退出后再等 300ms 排空，`CancelIoEx` 收尾，最后发 `PaneExited`（带退出码）。
- 效果：`exit 3` 会关闭窗格并显示退出码；回归测试 `pane_exit_code_is_reported`。

**鼠标**（`input/`、`ui/app.rs`、`platform/console.rs`）

- 原始输入模式追加 `ENABLE_MOUSE_INPUT`；`ENABLE_EXTENDED_FLAGS` 下不设 QuickEdit，避免鼠标被控制台选区抢走。
- 解码 `MOUSE_EVENT`：位置、按键位、滚轮增量、修饰键、移动标志。
- 滚轮：窗格内应用未开启鼠标追踪 → 滚动回看缓冲（每格 3 行，Shift 强制滚回看）；开启追踪 → 按 SGR（`?1006`）或 X10 编码转发给子进程，1000/1002/1003 分别支持按键 / 拖动 / 任意移动。
- 拖拽分隔线：命中 `Node::find_separator` 后按住左键移动，按鼠标位置换算比例（5%–95%），松开结束；`Node::set_ratio` 按路径更新。
- 标签栏：左键点标签切换、点末尾 `+` 新建、中键点标签关闭、滚轮切换标签；点击窗格切换焦点。
- `?1005`（UTF-8 坐标）不单独支持，统一按 SGR 优先。

**回看体验**

- 滚轮每格 3 行（按累计增量换算，触控板的小增量不丢）；`Shift+PageUp/PageDown` 翻页，`Ctrl+Alt+↑/↓` 逐行，`Ctrl+Shift+End` 回到最新。
- `Ctrl+Shift+↑/↓` 跳到上/下一条命令的提示符（依赖 OSC 133）。
- 标题栏右侧显示 `↑ 回看 N 行`；按键输入自动回到最新输出（`scroll_offset = 0`）。

**剪贴板与括号粘贴**（`platform/clipboard.rs`、`ui/app.rs`）

- `Ctrl+Shift+V` 读取剪贴板（`CF_UNICODETEXT`），换行统一成 CR；子进程开启 `?2004` 时用 `ESC[200~ … ESC[201~` 包裹。
- 剪贴板被占用时重试 5 次（20ms），失败静默降级。
- OSC 52：`ESC ] 52 ; c ; BASE64` 解码后写入剪贴板（上限 100KB）。
- OSC 8 超链接暂不实现：Server Core 下没有可点击的 GUI。

**文本选择与复制**（`ui/app.rs`）

- 鼠标左键拖动选择（未开启鼠标追踪时），双击选词，Shift+点击扩展，Esc 清除，键入自动清除。
- `Ctrl+Shift+C` 复制：裁剪行尾空白、行间用 CRLF；选区跨回看缓冲同样有效。
- 选区以「绝对行号（回看 + 屏幕）」记录，滚动后高亮位置保持正确。

**VT 补齐**

| 能力 | 说明 |
|---|---|
| REP `CSI Ps b` | 重复上一个可见字符 |
| DECALN `ESC # 8` | 整屏填 `E` 的对齐测试 |
| `?1004` | 焦点上报（记录屏幕状态） |
| `?2026` | 同步输出（记录状态；渲染本身按帧合并） |
| `CSI 5 n` / `CSI ? 6 n` | 设备状态正常 / 带私有标记的光标位置 |

**主题与字体**

- 内置配色：64 套（16 套 Windows Terminal 官方：Campbell、Campbell Powershell、Vintage、One Half Dark/Light、Solarized Dark/Light、Tango Dark/Light、Dimidium、Ottosson、CGA、IBM 5153、Dark+、VSCode Dark/Light Modern；48 套社区主题：Dracula、Catppuccin Mocha/Frappe/Macchiato、Tokyo Night、Nord、Gruvbox Dark/Hard、One Light、Kanagawa Wave/Dragon、Rose Pine 系列、Night Owl、Monokai Pro、Everforest、Everblush、Ayu Mirage、Aura、Cyberpunk、GitHub、Homebrew、Material、Ocean、Retro、Sakura、Synthwave Alpha、Ubuntu、Zenburn 等）。profile 的 `color_scheme` 直接选名字。
- 每套配色带 16 色 ANSI 调色板：渲染时 `Color::Indexed(0..16)` 映射成方案 RGB（真彩色关闭时再量化到 256 色）；`Indexed(16..256)` 用标准 xterm 色表，因此换主题会连 `ls` / `git` 等 16 色输出一起变色。
- `render.font_face` / `font_size` 通过 `SetCurrentConsoleFontEx` 作用于当前控制台窗口；字体不存在时记录 WARN 并沿用原字体。

**稳定性**

- release 改为 `panic = "unwind"`，服务端会话线程用 `catch_unwind` 隔离：单个客户端异常不会带走后台服务和其它窗格。
- 输出洪峰时重绘节流到 16ms 一帧（主循环 250ms 兜底），避免高吞吐输出把 CPU 打满。
- 输出泵、超时与退出路径都有明确清理（取消 I/O、关闭句柄），长时间运行不泄漏句柄。

## 19. 阶段 3 验收清单

| # | 项 | 判定方式 | 状态 |
|---|---|---|---|
| 1 | 客户端退出后产生 PaneExited 并携带退出码 | e2e `pane_exit_code_is_reported` | 通过 |
| 2 | 滚轮滚动回看（未开启鼠标追踪的窗格） | 单测 `wheel_scrolls_history_of_pane_under_cursor` | 通过 |
| 3 | 应用开启鼠标追踪后转发 SGR 鼠标事件 | 单测 `forwards_mouse_when_app_enables_tracking` | 通过 |
| 4 | 拖拽分隔线调整比例 | 单测 `dragging_separator_updates_ratio`、`layout::tests::separator_hit_test_and_ratio_update` | 通过 |
| 5 | OSC 52 写剪贴板 | 单测 `osc52_writes_clipboard` | 通过 |
| 6 | 粘贴（含括号粘贴） | 手工：复制多行文本后 `Ctrl+Shift+V` 到 shell / python | 待真机手工 |
| 7 | vim / python 内滚轮与鼠标点击 | 手工 | 待真机手工 |
| 8 | 回看提示与输入回到最新 | 单测 + 手工 | 单测通过，手工待验 |
| 9 | 鼠标拖选 + `Ctrl+Shift+C` 复制 | 单测 `selection_text_and_word_selection`、`selection_contains_range` | 通过 |
| 10 | REP / DECALN / DSR 扩展 | 单测 `repeat_last_char_and_alignment_test`、`dsr_status_and_private_cursor` | 通过 |
| 11 | 主题配色与字体配置 | 单测 `parses_font_options_and_themes`、`builtin_schemes_have_full_ansi_palettes`、`parses_ansi_palette_and_falls_back_to_campbell`、`palette_maps_ansi_indexes`、`without_palette_ansi_indexes_pass_through`、`indexed_256_color_uses_xterm_table` + 手工换 scheme | 单测通过，手工待验 |
| 12 | 单个会话异常不影响后台服务 | `panic = "unwind"` + `catch_unwind` 隔离 | 通过（代码审查） |
| 13 | 长时间运行（连续输出、反复开关标签） | 手工压测：`dir /s C:\Windows` 连续输出 5 分钟 | 待真机手工 |
| 14 | 真实客户端全链路探针（启动 / 中文 / Tab / 退格 / 历史 / 大输出 / 缩放 / 退出） | `cargo test zz_client_probe -- --ignored --test-threads=1`（release 构建后运行） | 通过 |
| 15 | 超长命令行换行/强制滚屏 | `cargo test zz_long_input_probe -- --ignored --test-threads=1` | 通过 |
| 16 | 跳到上/下一条命令（OSC 133） | 单测 `osc133_marks_prompt_rows`、`jumps_between_prompts` | 通过 |
| 17 | win32-input-mode（`?9001`）按下与抬起原样转发 | 单测 `key_records_keep_scan_repeat_and_release`、`win32_input_mode_encoding`、`win32_input_mode_forwards_press_and_release` | 通过 |
| 18 | 标签页状态标记（响铃、上一条命令退出码） | 单测 `tab_marks_exit_status_and_bell`、`tab_click_hit_test_uses_cell_width` | 通过 |
| 19 | 内置 shell 按词移动/删除 | 单测 `word_motion_and_deletion` | 通过 |
| 20 | 窗格右侧滚动条（悬停/回看时显示，可拖动） | 单测 `scrollbar_geometry_follows_offset`、`dragging_scrollbar_scrolls_history` | 通过 |
| 21 | 会话当前目录（OSC 7）显示在标签栏 | 单测 `osc7_reports_working_directory`；`zz_client_probe` 的 `cd C:\Windows` 步骤验证标签栏跟随 | 通过 |
| 22 | 跳到最早/最新一条命令（`Ctrl+Shift+Home` / `promptLast`） | 单测 `jump_to_first_and_last_prompt` | 通过 |
| 23 | 渐变背景（逐行 RGB，空白区也上色） | 单测 `gradient_fills_default_backgrounds_only`、`paint_emits_gradient_background`、`gradient_directions`；探针原始输出首屏有 30 行 `48;2;45..8` 渐变 | 通过 |
| 24 | 设置面板（TUI）与写回配置 | 单测 `settings_adjusts_and_reverts`、`settings_scrollback_applies_to_open_panes`、`settings_save_writes_only_related_keys`、`patch_config_*`、`save_edits_roundtrip_to_disk` | 通过 |
| 25 | 翻页/满屏后不再「堆在最后一行」 | ① `WINDOW_BUFFER_SIZE_EVENT` 带的是缓冲区尺寸（conhost 常为 9001 行），改为按可见窗口重算；② 启动与每次尺寸事件后把缓冲区钉成窗口大小；③ 行编辑输入高于一屏时改为「从屏幕顶部重画最后一屏」。验证：`zz_client_probe` 4.6（60 行输出铺满屏幕）、`zz_long_input_probe`（600 字符超过一屏） | 通过 |
| 26 | 设置面板扩展到 10 项（默认 profile / 字体 / 鼠标 / 选中即复制） | 单测 `settings_copy_on_select_toggle`、`settings_save_writes_only_related_keys`、`patch_config_adds_missing_behavior_section` | 通过 |
| 27 | cmd 同义内置命令（md/erase/ren/pushd/popd/vol/date/time/chcp/pause/title/prompt） | 单测 `cmd_aliases_are_builtin`、`prompt_template_codes`；`zz_shell_smoke_via_release_binary` 真机执行 ren/md/erase/rd/vol/chcp/date/pushd | 通过 |
| 28 | 脚本控制流（`if / else`、`for /l`、`call :标签`、`goto`、`exit /b`）在真实窗格端到端 | e2e `zz_script_smoke_via_release_binary`（本机通过；Server Core 上退出码 0，报告结尾「结果：通过」，`%errorlevel%` 为 7） | 通过 |
| 29 | 真实 Windows Server Core 全链路（shell 冒烟、脚本冒烟、客户端探针、超长输入探针、客户端控制台冒烟） | 测试机 `172.29.214.204`（Server 2025 Datacenter Evaluation，`InstallationType=Server Core`，WORKGROUP，4 GB 内存）：`zz_shell_smoke_via_release_binary` / `zz_script_smoke_via_release_binary` / `zz_client_probe` / `zz_long_input_probe` / `zz_client_console_smoke` 全部退出码 0，报告「结果：通过」 | 通过 |
| 30 | 启动时延（进程创建 → 首个提示符） | `zz_bench_probe`：本机 35 ms；Server Core 23 ms | 通过 |
| 31 | 常驻内存（工作集） | 本机：`scterm shell` 5.0 MB、后台 `server --detached` 5.2 MB / 4 线程；Server Core：shell 平均 6.1 MB（峰值 6.4 MB）、server 6.4 MB | 通过 |
| 32 | 10 万行输出吞吐（ConPTY 全链路，`cmd /c for /l ... do @echo`） | `zz_bench_probe`：本机 9.688 s（约 10322 行/秒，1200048 字节，100552 帧）；Server Core 20.500 s（约 4878 行/秒，1200070 字节，101823 帧） | 通过 |
| 33 | 与 cmd 逐项行为对照（`set /a`、`echo off/on`、`if defined/exist`、`for /l`、`call :子程序`、`exit /b`、`goto`） | 基准为本机 cmd 实测（`cmd /d /c` 与批处理各测一遍）；scterm 用真实窗格 e2e 同项验证。结果见下方「D. cmd 行为对照」 | 行为一致，差异见下表 |
| 34 | 渐变配色 13 套 / 设置面板鼠标 / 标签栏鼠标入口与底部状态栏 | 单测 `palette_presets_are_distinct_and_round_trip`、`settings_panel_mouse_selects_and_adjusts`、`tab_bar_plus_click_opens_tab`、`tab_bar_middle_click_closes_tab`、`tab_bar_wheel_switches_tabs`、`tab_bar_narrow_hides_plus`、`tab_bar_shortcuts_select_tabs`、`status_bar_shows_shortcut_hints_when_room` | 通过 |

### D. cmd 行为对照（cmd 为本机实测基准）

| 行为 | cmd 实测 | scterm 实测 | 结论 |
|---|---|---|---|
| `set /a n=1`（命令行） | 输出 `1` | 输出 `1` | 一致 |
| `set /a a=1,b=2` | 输出 `2`（a=1、b=2） | 输出 `2` | 一致 |
| `set /a 111,222` | 输出 `222` | 输出 `222`（Server Core 同样） | 一致 |
| `set /a n=1,n+4` | 输出 `5`，n 仍为 1 | 输出 `5`；脚本内 `pq=5 p=1` 佐证 | 一致 |
| 批处理 / `.sct` 脚本内 `set /a` | 不打印结果 | 不打印结果 | 一致 |
| `set /a 1+` | stderr「缺少操作数」，errorlevel 1073750989 | 中文错误提示，`ERRORLEVEL=1` | 语义一致，错误码与文案不同 |
| `set /a 1/0` | stderr「除数为零」，errorlevel 1073750993 | 中文错误「set /a 除数为零」，`ERRORLEVEL=1` | 语义一致，错误码不同 |
| `echo off` / `echo on` | 不输出 | 不输出 | 一致 |
| `echo` 无参数 | 输出「ECHO 处于打开状态。」 | 输出空行 | 差异（见 §16 已知限制） |
| `if defined n` / `if not exist 缺失文件` | 条件为真则执行 | 条件为真则执行 | 一致 |
| `for /l %%i in (1,1,3)` | `1`、`2`、`3`（闭区间） | `1`、`2`、`3` | 一致 |
| `call :sub alpha beta` | `sub=alpha-beta`，`%1`=`alpha`、`%2`=`beta` | `sub=alpha-beta`，`if "%1"=="alpha"` 成立 | 一致 |
| `goto :done` 跳过中间命令 | 跳过 | 跳过（报告中没有 `skipped`） | 一致 |
| `exit /b 7` 后 `%errorlevel%` | `7` | `7`（OSC 133 报 `]133;D;7`） | 一致 |


## 20. 与 ELYTerminal 的能力对照

参考 [ELY-Open-Source/ELYTerminal](https://github.com/ELY-Open-Source/ELYTerminal)（GPUI GUI 终端）后，按「Server Core 控制台宿主」的可行性做出的取舍：

| ELYTerminal 能力 | 本项目 | 说明 |
|---|---|---|
| 会话侧栏 / Git / Files 面板 | 不适用 | Server Core 无 GUI，终端跑在 conhost 里 |
| 背景模糊/透明度/Mica/背景图 | 不适用 | 控制台宿主不支持 alpha 与图像 |
| 渐变背景 | 已实现 | 控制台只能按单元格上色：按配色背景推导两端色，逐行/逐列插值成平滑渐变，可用 `[render] gradient` 调整或关闭；内置 13 套渐变配色预设 |
| kitty 图像协议、OSC 5522 剪贴板 | 不做 | 控制台无法显示图像 |
| 搜索回看、文本选择、复制粘贴 | 已实现 | `Ctrl+Shift+F` / 拖选 / `Ctrl+Shift+C`/`V` |
| 鼠标追踪、滚轮回看、Shift 强制回看 | 已实现 | 滚轮按累计增量换算 |
| 右侧滚动条（可拖动，程序占用鼠标时也能拖） | 已实现 | 悬停或回看时显示，平时隐藏以免永久占用最右一列 |
| 会话目录跟随（Files/Git 面板的数据源） | 部分 | 只保留 OSC 7 → 标签栏显示路径；不做侧栏面板 |
| 设置窗口（全部设置的图形化入口） | 已实现（TUI） | `Ctrl+S` 打开：配色方案 / 背景渐变 / 渐变配色（13 套）/ 真彩色 / 字体 / 字号 / 回看行数 / 鼠标上报 / 选中即复制；`←→`、鼠标点行与点右侧、滚轮均可改，`Enter` 写回 `config.toml`（只改相关键，注释与自定义内容保留）、`Esc` 取消 |
| 多套主题 | 已实现 | 内置 64 套配色（Windows Terminal 官方 + 社区主题），每套带 16 色 ANSI 调色板，可在配置或设置面板里直接选 |
| Shell 集成 OSC 133 + 跳到上/下一条命令 | 已实现 | 自研 shell 发送 A/B/C/D 标记；外部程序不发则退化为回到最新 |
| 会话状态标记（响铃 / 上一条命令成功或失败） | 已实现 | 标签页显示 `!`、`✓`、`✗码`，切到该标签即清除响铃 |
| 系统通知（后台完成/失败提醒） | 不做 | Server Core 无通知中心，用标签标记与状态栏替代 |
| 自然文本编辑（按词移动/删除） | 部分 | 内置 shell：`Ctrl+←/→` 按词移动，`Ctrl+Backspace/Delete` 按词删除；外部程序按各自习惯处理 |
| win32-input-mode（`?9001`） | 已实现 | 解码保留扫描码/重复次数/抬起事件，按 `CSI Vk;Sc;Uc;Kd;Cs;Rc _` 转发；依赖宿主 ConPTY 支持该序列（Win10 2004+），未请求时行为不变 |
| OSC 8 超链接 | 未实现 | conhost 的点击支持有限 |
| 每 profile 字体/渐变/标签色覆盖 | 已实现 | `[[profiles]]` 里的 `font_face` / `font_size` / `gradient` / `gradient_top` / `gradient_bottom` / `tab_color` 优先于全局 `[render]`；设置面板可按当前 profile 调整并写回 |
| 布局模板 / 会话恢复 / Quake 热键 | 已实现 | `scterm --layout <名称/表达式>` 打开多窗格；正常退出保存 `session.toml` 并自动恢复；`[quake]` 注册全局隐藏/呼出热键 |
| 键盘标记模式 / 矩形选择 | 已实现 | `Ctrl+Shift+M` 用方向键选择、`Enter` 复制；`Alt+左键` 拖动做矩形选择，复制保留列内空格 |
| 亚克力/Mica/真透明/圆角/标签拖出成新窗口/连字/彩色 emoji/Sixel 图像 | 不做 | 控制台宿主（conhost）不具备这些能力，属 GUI 客户端路径 |

## 21. 阶段 4 验收清单（外观覆盖 / shell 集成 / 布局会话 / 选择模式）

| # | 项 | 判定方式 | 状态 |
|---|---|---|---|
| 1 | 每 profile 覆盖字体、渐变、标签色 | 单测 `profile_gradient_overrides_and_inherits`、`profile_font_falls_back_to_global`、`profile_settings_rows_update_active_profile`、`settings_panel_scrolls_to_selected` | 通过 |
| 2 | 外部 shell 集成脚本生成与命令行装饰 | 单测 `detect_shell_kinds`、`powershell_injection`、`cmd_injection`、`scripts_carry_sequences`、`assets_written_once`；e2e `powershell_integration_emits_osc`、`cmd_integration_sets_prompt` | 通过 |
| 3 | 布局表达式解析与写回（`h/v`、比例、引号名） | 单测 `layout_spec_parses_single_and_nested`、`layout_spec_ratio_and_quoted_names`、`layout_spec_rejects_bad_input`、`node_to_spec_roundtrips_tree`、`node_to_spec_escapes_special_names` | 通过 |
| 4 | `scterm --layout <名称/表达式>` 按模板开窗格 | 单测 `parses_client_options_and_legacy_commands`、`rejects_invalid_cli_combinations`；本机以临时配置 `dev = "h(cmd,scterm)"` 实测生成 cmd 与 scterm 两个窗格 | 通过（手工验） |
| 5 | 会话保存/恢复（标签、布局、比例、焦点、活动标签） | 单测 `roundtrip_preserves_tabs_and_layout`、`title_escapes_quotes_and_newlines`、`bad_session_is_ignored`、`restore_rebuilds_tabs_and_focus`、`restore_skips_bad_layout_and_unknown_profile` | 通过 |
| 6 | Quake 热键解析与注册 | 单测 `parses_common_hotkeys`、`rejects_bad_hotkeys`；本机 `--quake` 启动后窗口句柄为 0、日志显示热键已注册 | 单测通过，呼出/隐藏待真机手工 |
| 7 | 标记模式（方向键移动、Enter 复制、Esc 退出、自动滚动） | 单测 `mark_mode_moves_selection_and_exits`、`mark_mode_scrolls_to_keep_head_visible`、`mark_mode_enter_on_empty_selection_reports_nothing`、`mouse_click_exits_mark_mode` | 通过 |
| 8 | Alt 矩形选择（覆盖鼠标上报、保留列内空格） | 单测 `block_selection_copies_rect_and_keeps_spaces`、`block_selection_hit_test_is_rectangular`、`alt_drag_starts_block_selection_even_with_mouse_reporting` | 通过 |
| 9 | 全量回归与 release 构建 | `cargo test --quiet -- --test-threads=1 --skip e2e::`（244 通过）、`cargo build --release`（无警告） | 通过 |
| 10 | 明确排除项未引入 | 代码中无亚克力/Mica/透明/圆角/标签拖出/连字/彩 emoji/图像协议实现 | 通过（代码审查） |
| 11 | 真实 PowerShell profile（命令/参数/别名/对象管道/补全/历史/提示符与官方一致） | 托管本机 `pwsh.exe`（优先）或 Windows PowerShell 5.1：`scterm --layout pwsh` 实测启动 `powershell.exe -NoLogo -ExecutionPolicy Bypass -NoExit -Command ". '<集成脚本>'"`；出厂默认 profile 为 powershell，设置面板可切回自研 shell / cmd | 通过（手工验） |

### PowerShell 兼容说明（方案 A：托管真实 PowerShell）

* **兼容级别**：命令集、参数、别名、对象管道、属性/方法访问、错误提示、返回码、Tab 补全、历史、提示符样式全部由本机真实的 PowerShell 提供（`pwsh.exe` 或 Windows PowerShell 5.1），与官方行为一致；项目不自行复刻 PowerShell 语义。
* **profile 解析**：`normalize()` 探测顺序为 `pwsh.exe`（PATH 与 `%ProgramFiles%\PowerShell\7`）→ `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` → PATH 中的 `powershell.exe`。新配置的 profile 名为 `powershell`；旧配置的 `pwsh` 保持原名，命令不可执行时自动回退到 Windows PowerShell 并在 `scterm reload` 中给出提示。
* **默认 profile**：出厂默认已改为 `powershell`，新建标签页/窗格直接进入真实 PowerShell。自研 shell（`scterm`，cmd 语义：`set /a`、`call :标签`、`goto`、`exit /b`、`%errorlevel%`）与 `cmd` 仍保留，在设置面板（`Ctrl+S`）的「默认 profile」行用 `←/→` 切换即可。
* **shell 集成**：沿用 OSC 7（当前目录）与 OSC 133（提示符标记）；`powershell.exe` 额外追加 `-ExecutionPolicy Bypass`，避免 Server Core 默认执行策略阻止集成脚本；`pwsh.exe` 不加该参数。
* **边界**：PSReadLine 的补全/历史/预测由 PowerShell 自身加载；本项目的设置面板、布局、会话恢复、Quake、mark mode、块选择等终端能力对 PowerShell 窗格同样生效。

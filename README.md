# Textm

Windows Server Core 上可用的终端 / 图形双模式编辑器。Rust 编写，编译产物是单文件 `textm.exe`，
除插件使用的纯 Rust JS 引擎 Boa 外不引入第三方依赖，文字处理、表格、压缩、JSON、LSP、Git 调用
都自行实现或使用系统组件。

## 下载源码

| 线路 | 地址 |
|---|---|
| GitHub | https://github.com/OrangeArtc0915/Server-core-manager/archive/refs/heads/tool/textm.zip |

本分支 `tool/textm` 只放本工具的源码；SCM 主程序在 `main` 分支。

## 构建

```powershell
cargo build --release
# 产物：target\release\textm.exe
```

要求 Rust stable（2021 edition）。`.cargo\config.toml` 已配置静态 CRT 与国内稀疏索引镜像。

## 运行

```powershell
.\textm.exe                 # 终端模式（TUI）
.\textm.exe --gui           # 图形窗口模式
.\textm.exe 文件…           # 启动并打开这些文件
```

图形模式使用系统 GDI，不需要 .NET / WebView；终端模式只需控制台窗口。

## 主要能力

- 编辑：多光标、撤销 / 重做、自动缩进与括号配对、代码折叠、书签、粘性滚动、小地图
- 编码：UTF-8 / UTF-8 BOM / GBK / UTF-16LE / UTF-16BE 自动识别与另存，LF / CRLF / CR 可切换
- 查找替换与工程搜索：正则捕获组、glob 包含 / 排除、遵循 `.gitignore`、跨行匹配
- 语法高亮：26 种内置语言，支持 `languages\*.ini` 自定义语言与 `snippets.ini` 代码片段
- Word（.docx）：段落编辑、加粗 / 斜体 / 下划线、字体颜色；GUI 页面视图按纸张分页
- Excel（.xlsx）：多工作表、样式与合并、冻结与筛选、90+ 函数、跨表引用
- Git 面板：暂存 / 提交 / 差异 / 历史 / 分支 / Blame / 拉取推送
- LSP：诊断、补全、悬停、跳转定义、查找引用、符号重命名、格式化
- 插件：`textm.json` + 内嵌 Boa JS 引擎，支持命令、文档操作、面板与主题 / 片段
- 调试：手写 DAP 客户端，读取 `.vscode/launch.json`，断点 / 单步 / 调用栈 / 变量
- 远程：UNC / SMB 工作区，系统 `ssh` / `scp` 远端命令与文件回传
- 图片：PNG / JPEG / GIF / BMP；TUI 半块字符预览，GUI 直接绘制

完整键位、配置项与已知限制见 [使用说明.txt](使用说明.txt)，实现细节见 [docs/技术文档.md](docs/技术文档.md)。

## 发行包

| 版本 | 文件 |
|---|---|
| `textm-v2.0.0` | `textm-v2.0.0-win-x64.zip`（textm.exe、使用说明.txt、docs/技术文档.md） |

GitHub 与 Gitee 上的发行版旁都带 `.sha256`。

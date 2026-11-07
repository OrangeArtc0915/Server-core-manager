# scterm

Windows Server Core 终端多路复用工具。Rust 编写，零第三方依赖（Win32 API 手写 FFI），
编译产物是单文件 `scterm.exe`，适合在 Server Core 上直接运行。

## 下载源码

| 线路 | 地址 |
|---|---|
| GitHub | https://github.com/OrangeArtc0915/Server-core-manager/archive/refs/heads/tool/scterm.zip |
| Gitee | https://gitee.com/orangearc655743/server-core-manager/repository/archive/tool/scterm.zip |

本分支 `tool/scterm` 只放本工具的源码；SCM 主程序在 `main` 分支。

## 构建

```powershell
cargo build --release
# 产物：target\release\scterm.exe
```

要求 Rust stable（2021 edition）。

## 运行

```powershell
.\scterm.exe
```

设计说明见 [docs/architecture.md](docs/architecture.md)。

## 来源

由 [Server-core-manager](https://github.com/OrangeArtc0915/Server-core-manager) 的
「SCM附属」页面分发（GitHub / Gitee 双线路下载）。

## 许可

GPL-3.0，见 [LICENSE](LICENSE)。

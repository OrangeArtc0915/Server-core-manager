# scm-top（TuiMonitor）

零依赖 TUI 监控。只用系统自带的 `Get-Counter` / CIM，离线可用，
适合没有 btop / glances 的 Windows Server Core。

## 下载源码

| 线路 | 地址 |
|---|---|
| GitHub | https://github.com/OrangeArtc0915/Server-core-manager/archive/refs/heads/tool/tuimonitor.zip |
| Gitee | https://gitee.com/orangearc655743/server-core-manager/repository/archive/tool/tuimonitor.zip |

本分支 `tool/tuimonitor` 只放本工具的源码；SCM 主程序在 `main` 分支。

## 运行

双击 `scm-top.cmd`，或：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scm-top.ps1
```

可选参数 `-IntervalSec 2`（刷新间隔，秒）。按 `q` 或 `Esc` 退出。

## 来源

由 [Server-core-manager](https://github.com/OrangeArtc0915/Server-core-manager) 的
「SCM附属」页面分发（GitHub / Gitee 双线路下载）。

## 许可

GPL-3.0，见 [LICENSE](LICENSE)。

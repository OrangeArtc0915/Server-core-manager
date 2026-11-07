# CraftDock

Windows Server Core 上的终端服务器管理面板（TypeScript + Node.js）。

## 下载源码

| 线路 | 地址 |
|---|---|
| GitHub | https://github.com/OrangeArtc0915/Server-core-manager/archive/refs/heads/tool/craftdock.zip |
| Gitee | https://gitee.com/orangearc655743/server-core-manager/repository/archive/tool/craftdock.zip |

本分支 `tool/craftdock` 只放本工具的源码；SCM 主程序在 `main` 分支。

## 目录

| 目录 | 内容 |
|---|---|
| `common/` | 公共类型与工具 |
| `daemon/` | 后台服务与 TUI |
| `languages/` | 多语言文案 |
| `prod-scripts/` | Windows 构建 / 启动脚本 |

## 构建

需要 Node.js 18+：

```powershell
npm run install:all   # 安装 common / daemon 依赖并构建
npm run build         # 打包
npm run tui           # 开发期直接跑 TUI
```

产物在 `daemon/production/`。源码分支不包含 `node_modules`、`production`、`lib`
以及随附的二进制工具（frpc / pty / 7zr），首次构建会重新安装依赖。

## 来源

由 [Server-core-manager](https://github.com/OrangeArtc0915/Server-core-manager) 的
「SCM附属」页面分发（GitHub / Gitee 双线路下载）。

## 许可

MIT，见 [LICENSE](LICENSE)。`daemon` 部分派生自 MCSManager（Apache-2.0）。

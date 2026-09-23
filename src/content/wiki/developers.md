---
title: 开发者指南
description: 目录结构、打包与发版流程、代码约定（BOM 与换行符的坑），以及项目主页仓库的说明。
group: 参考
order: 3
---

## 仓库结构

```
Server-core-manager\                （main 分支 = 程序本体）
├─ install.ps1                      一行安装（远程拉发布包）
├─ pack.ps1                         打发布包
├─ Start-GuiReadyApp.ps1            统一入口（默认 GUI，-Console 走菜单）
├─ Start-GuiReady.ps1               控制台菜单
├─ gui\                             图形界面（主界面 + 动作清单 + 动作执行器）
├─ lib\                             全部能力模块 + catalog.json 兼容档案
├─ setup\console\                   终端美化素材（Nerd Font / oh-my-posh / fastfetch）
├─ launcher\                        RDP 会话用的轻量面板
└─ docs\                            赞助说明等对外资料
```

运行时会自动创建 `logs\`（日志）、`reports\`（报告与截图）、`state\`（断点与缓存）、`payload\`（下载的安装包），**都不进仓库** —— 日志里带主机名、用户名、内网 IP。

## 打包

```powershell
.\pack.ps1 -Version v1.2.0
```

产出两个文件到 `dist\`：

- `ServerCoreManager.zip` —— **固定名字**，`install.ps1` 按这个名字取，每次发版必须上传
- `ServerCoreManager-v1.2.0.zip` —— 内容相同，只是带版本号方便留档

打包会：
- 排除 `logs` / `reports` / `backup` / `state` / `payload` / `dist` / `.git` 与所有 `.exe` / `.msi` / `.zip`
- **例外**：`setup\` 下的美化素材（含 exe）会打进包，否则「一键美化终端」会缺素材
- 打完自检内置素材是否齐全（字体 / Oh My Posh / Fastfetch / 主题 / 启动器）

## 发版流程

版本号散落在几处，**必须同步改**，否则会出现「包是新版、但某个入口指向旧版本」的不一致：

| 位置 | 说明 |
|---|---|
| `install.ps1` 的 `$GiteeVer` | 指向 Gitee 上的发行版 tag。**这个常量必须与 Gitee tag 一致** |
| `RELEASE_NOTES.md` | 标题、本次更新小节、文件名表 |
| 项目主页（`WEB` 分支） | 侧栏公告、时间线、新版本文章 |

步骤：

1. 改上面的版本号，`pack.ps1 -Version vX.Y.Z` 打包
2. 建 Release 并上传 `ServerCoreManager.zip`（**固定名**）+ 带版本号的那份
   - GitHub：tag 与 Release
   - Gitee：发行版（**只有源码与发布包，不放源码树** —— Gitee 上只放 `install.ps1` 一个脚本文件）
3. **把 `install.ps1` 重新推到 Gitee** 的 `main` 分支 —— 一行安装的国内线路就是用它的 raw 地址

> [!IMPORTANT]
> 第 3 步容易漏。漏了不会装错东西（脚本会按 zip 魔数校验内容、失败后自动回退 GitHub 线路），但**国内加速就等于没生效**。

## 自检开关

```powershell
.\Start-GuiReadyApp.ps1 -SelfTest     # 页面/卡片/按钮数量 + 数据往返验证
.\Start-GuiReadyApp.ps1 -LayoutDump   # 控件树真实坐标 + 越界检测
$env:SCM_BOOT_TRACE = '1'             # 启动各阶段耗时 → state\boot-trace.txt
```

改动界面相关代码后建议至少跑一次 `-SelfTest`，它在真机上验证的是「界面真的渲染出来了」，而不只是「进程还在」。

## 代码约定（都是踩过坑才定下来的）

| 约定 | 原因 |
|---|---|
| 含中文的 `.ps1` **必须有 UTF-8 BOM** | PowerShell 5.1 对无 BOM 文件按 GBK 解析，注释会乱码进而语法错误 |
| `install.ps1` **必须没有** BOM | 它是给 `irm \| iex` 用的，BOM 会被当成正文第一个字符，`#Requires` 失效 |
| `.cmd` / `.bat` **必须 CRLF 换行** | LF 会让 cmd 解析错乱，还会污染 `cmd /c` 的输出 |
| cmd 脚本里**不要用管道 / 外部命令做判断** | `AutoRun` 会因此递归拉起子 cmd |
| 写注册表前先导出备份 | 「一键还原」要能真的还原 |

> [!WARNING]
> 用编辑器改上面这些文件时，**注意别把 BOM 弄丢**（很多编辑器默认保存为无 BOM 的 UTF-8）。丢了 BOM 的后果是脚本直接解析失败，报的错还看不出是编码问题 —— 这个坑在本项目里真实发生过。

## 项目主页（`WEB` 分支）

站点源码就在本仓库的 **`WEB` 分支**（不是 main），用 **Astro + [Mizuki](https://github.com/matsuzaka-yuki/Mizuki) 主题**构建，通过 GitHub Actions 自动部署到 GitHub Pages。

几个需要知道的点：

- `astro.config.mjs` 里 `site` + **`base = /Server-core-manager`** —— 项目站点必须带 base，否则产物资源路径全部指向域名根目录
- 因此**站内链接一律用 `url()` 拼 base**，正文里的内部链接用**相对路径**
- 构建产物 `dist/` 不入库，由 Actions 打包发布

```powershell
pnpm install
pnpm run build      # 产物在 dist\
pnpm run preview    # 本地预览，会按 base 提供
```

### 图标别用运行时 CDN

站点的图标有两套机制，新增时别用错：

- **`.astro` 里**用 astro-icon 的 `<Icon name="mdi:github" />` —— 构建期就把 SVG 内联进 HTML，零请求、零外部依赖
- **`.svelte` 里**只能用 `@iconify/svelte` 的 `<Icon icon="material-symbols:search" />`，它默认会在**运行时**去 `api.iconify.design` 取图标数据

为了不让页面依赖那个第三方域名（国内可能访问不到，表现是按钮没图标、标签页一直转圈），Svelte 用到的图标会被**抽出来本地注册** —— 数据在 `src/data/iconify-local.json`，在 `Layout.astro` 的 `<head>` 里用 `addCollection()` 注册。

所以在 `.svelte` 里加了新图标之后，要跑一次：

```powershell
pnpm run icons      # 重新生成 src/data/iconify-local.json
```

漏跑的后果：只有那一个新图标不在本地集合里，它会去请求 `api.iconify.design`，在国内可能就是不显示。

## 相关

- [诊断与排障](../diagnose/)
- [已知限制](../limits/)

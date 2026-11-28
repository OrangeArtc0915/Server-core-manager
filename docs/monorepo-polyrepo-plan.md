# 单仓库模拟多仓库：落地方案

> 目标仓库：`https://github.com/Server-Core-Mananger/Server-core-manager`
> 验证原型：`https://github.com/Server-Core-Mananger/test`（已跑通 CI、标签发布、目录级归属与过滤链接）
> 本文只描述方案与步骤，不包含实际代码改动。

## 0. 结论

推荐 **方案 A：单仓库 + 目录级项目 + 前缀标签 + 过滤链接**。

- 不拆仓库、不引入 submodule、不迁移目录（先保留 `TUI_TOOL/` 路径）。
- 源码进 git，构建产物（`target/`、`node_modules/`、`dist/`、`*.exe`、`*.zip`）继续忽略。
- 每个工具用 `tool/<名称>` 标签、`<名称>-v*` 标签、目录级 CI 和 CODEOWNERS 模拟独立仓库。
- 发行仍在一个 GitHub Releases 里，但每个工具只链自己的 tag 页面。

等某个工具确实需要独立 Star/Watch/权限时，再按方案 B 拆出去，源码无需重写历史。

## 1. 现状（已核实）

| 项 | 现状 |
|---|---|
| 主仓库 | `Server-Core-Mananger/Server-core-manager`，默认分支 `main` |
| `TUI_TOOL/` | 被 `.gitignore` 第 35 行整体忽略，注释写明「不属于本仓库」 |
| 子项目 | `Terminal`（Rust，约 94 MB，含 `target/`；源码约 0.9 MB）、`craftdock`（约 1.5 GB，含 `node_modules`/产物）、`TuiMonitor`（空） |
| `.github/` | 基本为空，没有 Actions 工作流 |
| 发行方式 | `pack.ps1` 打包 + 手动 GitHub Releases |
| 许可证 | 仓库根目录 MIT |
| `site/` | Astro 站点，本机是 WEB 分支的 worktree，被 `.gitignore` 忽略 |

原型仓库已验证：

- `scterm-v0.1.0` 标签触发 Actions，自动构建并发布 `scterm-v0.1.0-win-x64.zip`（约 548 KB）+ `.sha256`；
- `scterm CI` 在 `windows-latest` 上通过（245 项单测）；
- `tool/scterm`、`tool/craftdock`、`tool/tuimonitor`、`tool/scm` 标签已创建；
- 目录链接、提交历史链接、标签过滤、Issue 过滤都能像独立仓库一样使用。

## 2. 目标与非目标

**目标**

1. 一个仓库维护主程序与全部附属工具。
2. 每个工具在 GitHub 上有独立的「首页、提交历史、标签、发布页、Issue 列表、CI 徽章」。
3. 改动某个工具只跑它自己的 CI；打它的标签只发它自己的包。
4. 用户可以只检出某个工具，不必下载整仓库。
5. 现有主程序打包流程（`pack.ps1`）不被打断。

**非目标**

- 不追求每个工具独立 Star/Watch/Fork/Insights/权限（GitHub 不支持目录级）。
- 不把二进制提交进 git。
- 不重写现有 git 历史。
- 不改变 `site/` 的 WEB 分支工作流。

## 3. 方案对比

| | 方案 A：目录级单仓库（推荐） | 方案 B：单仓库 + subtree 镜像 | 方案 C：多仓库 |
|---|---|---|---|
| 源码真源 | 一个仓库 | 一个仓库 | 每个仓库各一份 |
| GitHub 观感 | 目录 + 过滤链接，接近独立仓库 | 真有独立仓库页面 | 完全独立 |
| 独立 Star/Issue 编号 | 否 | 是（镜像仓库） | 是 |
| 维护成本 | 低 | 中（多一套推送流水线） | 高（三处同步） |
| 适合 | 当前阶段 | 某个工具需要独立社区时 | 工具完全独立演进 |

方案 B 的做法：在 A 的基础上加一条 workflow，用 `git subtree split -P TUI_TOOL/Terminal` 推到 `scterm` 镜像仓库并发版。源码仍只维护一份，但多一个仓库和一套凭据。

本文只展开方案 A；B 作为后续升级路径。

## 4. 方案 A 详细设计

### 4.1 目录结构（先不移动）

```
Server-core-manager/
├─ gui/ launcher/ lib/ setup/ ...        # 现有主程序
├─ TUI_TOOL/
│  ├─ README.md                          # 新增：附属工具索引
│  ├─ Terminal/                          # 真实源码（原样保留）
│  │  ├─ README.md                       # 新增：独立项目首页
│  │  ├─ CHANGELOG.md                    # 新增
│  │  ├─ LICENSE                         # 新增：MIT 副本
│  │  ├─ Cargo.toml / Cargo.lock
│  │  ├─ .cargo/config.toml
│  │  ├─ src/ docs/
│  │  └─ .gitignore                      # 新增：target/、*.exe
│  ├─ craftdock/                         # 现有源码（按需入库，见 4.2）
│  └─ TuiMonitor/
├─ .github/
│  ├─ CODEOWNERS                         # 新增
│  ├─ ISSUE_TEMPLATE/bug.yml             # 新增
│  └─ workflows/
│     ├─ scterm-ci.yml                   # 新增
│     ├─ scterm-release.yml              # 新增
│     ├─ craftdock-ci.yml                # 以后按需
│     └─ scm-release.yml                 # 现有打包流程可迁到这里
├─ plugins.json                          # 新增：插件清单
└─ .gitignore                            # 修改：取消 TUI_TOOL/ 整体忽略
```

> 目录名保留 `TUI_TOOL/Terminal`，避免破坏本机脚本、当前构建路径和已发布的文档链接。等稳定后再考虑 `git mv` 到 `tools/scterm`（GitHub 会自动跳转旧路径，但外部脚本要同步改）。

### 4.2 `.gitignore` 调整

现状（第 35 行）：

```gitignore
TUI_TOOL/
```

改为：

```gitignore
# TUI_TOOL 下的源码进仓库，只忽略构建产物与本地文件
TUI_TOOL/**/target/
TUI_TOOL/**/node_modules/
TUI_TOOL/**/dist/
TUI_TOOL/**/.astro/
TUI_TOOL/**/*.exe
TUI_TOOL/**/*.pdb
TUI_TOOL/**/*.zip
```

注意事项：

- `craftdock` 约 1.5 GB，入库前先确认忽略 `node_modules/`、打包产物、日志、`.env` 等；只提交源码与锁文件。
- 根 `.gitignore` 已有 `*.exe`/`*.zip`，但子目录的 `.gitignore` 再写一遍更稳。
- 不要 `git add -f` 任何二进制。

### 4.3 标签与发行规范

| 产品 | 标签 | Release 附件 |
|---|---|---|
| 主程序 | `scm-v2.1.0` | 现有安装包 |
| scterm | `scterm-v0.1.0` | `scterm-v0.1.0-win-x64.zip`、`scterm-v0.1.0-win-x64.zip.sha256` |
| CraftDock | `craftdock-v1.4.0` | 对应单文件 exe / zip |
| TuiMonitor | `tuimonitor-v0.1.0` | 同上 |

- 标签必须有前缀；`releases/latest` 只认全仓库最新，插件下载要用显式 `releases/download/<tag>/<asset>`。
- 发布说明由 Actions 的 `generate_release_notes: true` 生成即可。
- 附件命名固定为 `<tag>-win-x64.zip`，SHA256 文件同名加 `.sha256`。

### 4.4 目录即仓库的链接

| 用途 | 链接 |
|---|---|
| 源码首页 | `https://github.com/Server-Core-Mananger/Server-core-manager/tree/main/TUI_TOOL/Terminal` |
| 提交历史 | `.../commits/main/TUI_TOOL/Terminal` |
| 标签 | `.../tags?q=scterm-` |
| 发布页 | `.../releases/tag/scterm-v0.1.0` |
| Issue | `.../issues?q=label%3Atool%2Fscterm` |
| PR | `.../pulls?q=label%3Atool%2Fscterm` |
| 代码搜索 | `.../search?q=repo%3AOrangeArtc0915%2FServer-core-manager+path%3ATUI_TOOL%2FTerminal` |
| Actions | `.../actions/workflows/scterm-ci.yml` |

这些链接写进 `TUI_TOOL/Terminal/README.md` 和根 README 的工具索引表，观感就是独立仓库。

### 4.5 CI 工作流

` .github/workflows/scterm-ci.yml`：

```yaml
name: scterm CI

on:
  pull_request:
    paths:
      - "TUI_TOOL/Terminal/**"
  push:
    branches: [main]
    paths:
      - "TUI_TOOL/Terminal/**"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  test:
    runs-on: windows-latest
    defaults:
      run:
        working-directory: TUI_TOOL/Terminal
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - name: 单元测试
        shell: pwsh
        run: |
          cargo test --quiet -- --test-threads=1 --skip e2e:: 2>&1 | Tee-Object -FilePath test.log
          if ($LASTEXITCODE -ne 0) {
            "## 单元测试失败" | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY
            '```' | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY
            Get-Content test.log | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY
            '```' | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY
            exit 1
          }
      - name: 构建
        run: cargo build --release
```

` .github/workflows/scterm-release.yml`：

```yaml
name: scterm Release

on:
  push:
    tags: ["scterm-v*"]

permissions:
  contents: write

jobs:
  release:
    runs-on: windows-latest
    defaults:
      run:
        working-directory: TUI_TOOL/Terminal
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo build --release
      - name: 打包
        shell: pwsh
        run: |
          New-Item -ItemType Directory -Force dist | Out-Null
          Copy-Item target/release/scterm.exe dist/
          Copy-Item README.md, LICENSE dist/
          $name = "$env:GITHUB_REF_NAME-win-x64.zip"
          Compress-Archive -Path dist/* -DestinationPath $name
          Get-FileHash $name -Algorithm SHA256 | ForEach-Object {
            "$($_.Hash.ToLower())  $name" | Out-File -Encoding ascii "$name.sha256"
          }
      - uses: softprops/action-gh-release@v2
        with:
          files: |
            TUI_TOOL/Terminal/scterm-*.zip
            TUI_TOOL/Terminal/scterm-*.zip.sha256
          generate_release_notes: true
```

要点：

- `paths` 过滤让 PR 只跑被改工具的 CI；
- 标签只触发对应工具的发布；
- 失败时把测试输出写进 Step Summary，公开仓库不登录也能看到原因（原型仓库已用这招定位到 PATH 冲突问题）。

### 4.6 CODEOWNERS / Issue 模板 / 标签

`.github/CODEOWNERS`：

```gitignore
*                       @Server-Core-Mananger
/TUI_TOOL/Terminal/     @Server-Core-Mananger
/TUI_TOOL/craftdock/    @Server-Core-Mananger
/TUI_TOOL/TuiMonitor/   @Server-Core-Mananger
/gui/                   @Server-Core-Mananger
```

`.github/ISSUE_TEMPLATE/bug.yml`（提交后人工补 `tool/*` 标签）：

```yaml
name: Bug 报告
description: 报告一个问题；提交后请补上 tool/<名称> 标签，便于按工具过滤
title: "[Bug] "
labels: ["bug"]
body:
  - type: dropdown
    id: tool
    attributes:
      label: 涉及工具
      options: [scterm, CraftDock, TuiMonitor, SCM 主程序]
    validations:
      required: true
  - type: textarea
    id: what
    attributes:
      label: 现象
    validations:
      required: true
  - type: input
    id: version
    attributes:
      label: 版本
  - type: textarea
    id: logs
    attributes:
      label: 日志或截图
      render: text
```

标签（网页或 API 创建）：`tool/scterm`、`tool/craftdock`、`tool/tuimonitor`、`tool/scm`。

### 4.7 `plugins.json`（给主程序做更新检查）

```json
{
  "schema": 1,
  "updated": "2026-11-07",
  "tools": {
    "scterm": {
      "name": "scterm",
      "version": "0.1.0",
      "path": "TUI_TOOL/Terminal",
      "source": "https://github.com/Server-Core-Mananger/Server-core-manager/tree/main/TUI_TOOL/Terminal",
      "release": "https://github.com/Server-Core-Mananger/Server-core-manager/releases/tag/scterm-v0.1.0",
      "download": "https://github.com/Server-Core-Mananger/Server-core-manager/releases/download/scterm-v0.1.0/scterm-v0.1.0-win-x64.zip",
      "sha256": "<发布时填入>"
    }
  }
}
```

主程序更新检查建议：

1. 读取 `plugins.json`（raw.githubusercontent 或 Releases 附件）；
2. 比较本地版本；
3. 下载 zip，校验 `sha256` 后解压到工具目录；
4. 失败时保留旧版本。

### 4.8 站点链接更新

`site/src/data/projects.ts` 里的 scterm 条目补上：

```ts
sourceCode:
  "https://github.com/Server-Core-Mananger/Server-core-manager/tree/main/TUI_TOOL/Terminal",
downloadUrl:
  "https://github.com/Server-Core-Mananger/Server-core-manager/releases?q=scterm-",
```

> `site/` 是 WEB 分支的 worktree，改动要在该分支提交，不要混进 `main`。

## 5. 实施步骤（可回滚）

1. **清理产物**：确认 `TUI_TOOL/**/target`、`node_modules`、`dist` 体积；必要时先本地删除（可再生成）。
2. **备份**：`git status` + 打一个本地 tag 或分支，方便回滚。
3. **改 `.gitignore`**：用 4.2 的规则替换 `TUI_TOOL/`。
4. **加文件**：`TUI_TOOL/README.md`、`TUI_TOOL/Terminal/README.md`、`CHANGELOG.md`、`LICENSE`、`tools/*/.gitignore`、`.github/*`、`plugins.json`。
5. **本地验证**：
   ```powershell
   git status --short
   git check-ignore -v TUI_TOOL/Terminal/target/debug/scterm.exe
   git check-ignore -v TUI_TOOL/craftdock/node_modules
   git ls-files TUI_TOOL | Measure-Object -Line
   ```
   确认只有源码与文档被跟踪。
6. **提交并推送**：
   ```powershell
   git add .gitignore .github plugins.json TUI_TOOL
   git commit -m "chore: 附属工具源码入库，加入目录级 CI / 归属 / 发行约定"
   git push origin main
   ```
7. **创建标签**：`tool/scterm` 等 4 个标签（网页或 `gh label create`）。
8. **首个发布**：
   ```powershell
   git tag -a scterm-v0.1.0 -m "scterm 0.1.0"
   git push origin scterm-v0.1.0
   ```
9. **验证**：见第 6 节。
10. **回滚**：若体积或 CI 不可接受，`git revert` 该提交并恢复 `TUI_TOOL/` 忽略规则即可；标签可删。

## 6. 验收清单

- [ ] `git ls-files TUI_TOOL` 没有 `target/`、`node_modules/`、`*.exe`、`*.zip`
- [ ] `TUI_TOOL/Terminal` 目录页能直接看到 README
- [ ] `.../commits/main/TUI_TOOL/Terminal` 只显示该工具相关提交（按路径过滤）
- [ ] `scterm-v*` 标签触发 Release，附件名与 SHA256 正确
- [ ] `scterm CI` 只在 `TUI_TOOL/Terminal/**` 变化时运行且为绿色
- [ ] README 中的过滤链接（tags / releases / issues / pulls）都能打开
- [ ] `tool/*` 标签存在，Issue 过滤列表可用
- [ ] 主程序 `pack.ps1` 打包流程未受影响
- [ ] 仓库总大小在可接受范围（建议 < 1 GB）

## 7. 风险与规避

| 风险 | 影响 | 规避 |
|---|---|---|
| 误提交构建产物 | 仓库历史膨胀且无法瘦身 | 先改 `.gitignore`，再 `git add`；提交前用 `git status --short` 与 `git ls-files` 检查 |
| `craftdock` 体积大 | clone 慢、CI 慢 | 只提交源码；CI 用路径过滤，不构建未改动的工具 |
| 标签前缀不统一 | 发布页/下载链接混乱 | 统一 `<工具>-v<版本>`，CI 用 `on.push.tags` 精确匹配 |
| Windows runner 成本 | 私有仓库分钟数消耗 | 公开仓库免费；加 `paths` 过滤，避免无意义构建 |
| 目录级权限不可用 | 无法按工具限制写权限 | 用 CODEOWNERS + 分支保护；确需隔离时走方案 B |
| 现有链接失效 | 文档/脚本引用旧路径 | 阶段 1 不移动目录；后续移动时保留重定向并同步脚本 |

## 8. 待确认的决策

1. `TUI_TOOL/Terminal` 是否保持现路径，还是后续迁到 `tools/scterm`？
2. `craftdock` 是入库（只提交源码），还是继续只在独立仓库维护、这里仅放 README 链接？
3. 首个版本号是否用 `scterm-v0.1.0`？
4. 是否把主程序打包也迁到 `scm-release.yml`，还是继续本地 `pack.ps1`？
5. 是否使用方案 B 的 subtree 镜像（先不启用）？

确认后可直接按第 5 节执行；原型仓库 `OrangeArtc0915/test` 已完整验证同一套流程。

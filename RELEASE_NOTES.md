# Server Core Manager v2.6

**让带图形界面的程序，在 Windows Server Core 上真正跑起来。**

这一版只改安装器：**装的时候就选服务器版本**，不用等首次启动再点向导。

> 只有 **Windows Server 2022 Core** 做过完整实测。**2019 以下版本（2008 R2 / 2012 / 2012 R2 / 2016）未经真机验证**：兼容路径已经实现，但不保证每个功能都可用。

---

## 本次变化（v2.6）

### 安装时选择服务器版本

`install.ps1` 在文件落地后会询问一次：

| 选项 | 档位 | 行为 |
|---|---|---|
| 1 | `modern` | 2019 及以上：保留 FOD / Windows Admin Center 页面，隐藏 8 个重复系统页 |
| 2 | `legacy` | 2012 R2 / 2016：隐藏 FOD / WAC 相关页面，保留其余系统页 |
| 3 | `old` | 2008 R2：在上一档基础上把存储写操作设为只读 |

细节：

- 按当前系统 build 给出建议默认值（`≥17763` 选 1，`≤7601` 选 3，其余选 2），回车即用
- 选择结果写入 `state\ui-settings.json` 并标记 `FirstRunDone`，首次启动不再弹版本向导
- **升级时沿用上次选择**，不重复打断；只有显式指定才会覆盖
- 非交互场景（管道、计划任务、`-NoPrompt`）自动使用 `auto`，不会卡在等待输入

### 新增参数与环境变量

```powershell
# 参数（先把脚本存成文件，按 UTF-8 读进来执行）
& ([scriptblock]::Create((Get-Content .\install.ps1 -Raw -Encoding UTF8))) -Dest 'D:\SCM' -Tier old -NoPrompt

# 环境变量（irm | iex 场景）
$env:SCM_TIER = 'legacy'
```

`-Tier` / `SCM_TIER` 可选 `auto`、`modern`、`legacy`、`old`；无效值会提示并回退到 `auto`。`-NoPrompt` 跳过所有交互。

### 版本

- 界面标题、关于页显示 v2.6

---

## 安装

两条线路任选，装的是同一个发布包（默认 `v2.6`）：

**Gitee（国内推荐）**

```powershell
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

**GitHub**

```powershell
irm https://raw.githubusercontent.com/Server-Core-Mananger/Server-core-manager/main/install.ps1 | iex
```

脚本会自动取 `ServerCoreManager.zip.sha256` 校验，哈希不一致会中止且不解压。重复执行等于升级，不会动已有的程序列表、日志与断点状态。

---

## 已知限制

- **2019 以下版本未经真机验证**：2008 R2 / 2012 / 2012 R2 / 2016 只有兼容路径，没有验收结论
- 2008 SP2 及更早不支持（装不了 WMF 5.1）；2008 R2 需要 SP1
- 2019 以下装不了 App Compatibility FOD / Windows Admin Center，相关页面会自动隐藏
- 部分桌面体验组件仍缺 4 个（`twinui.dll` / `themeui.dll` / `themeservice.dll` / `DispBroker.dll`）
- Windows Terminal 不能跑在 Server Core 上，工具提供的是 conhost 美化方案

## 源码

<https://github.com/Server-Core-Mananger/Server-core-manager>

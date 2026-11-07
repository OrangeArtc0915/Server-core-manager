---
title: 布局模板与会话恢复
description: 用一行表达式或命名布局直接开出多窗格；正常退出后自动恢复标签、布局、比例与焦点。
group: 使用
order: 4
project: scterm
---

## 布局表达式

一条表达式描述一棵窗格树：

```text
h(powershell,cmd)              # 左右分：左 PowerShell，右 cmd
v30(powershell,h(cmd,scterm))  # 上 30% PowerShell，下面再左右分
```

规则：

| 写法 | 含义 |
|---|---|
| `h(...)` | 左右分（分隔线竖着，新窗格在右） |
| `v(...)` | 上下分（分隔线横着，新窗格在下） |
| `h30(...)` | 第一个子节点占 30%，省略时为 50% |
| `"my profile"` | 名字里带空格、逗号、引号时用双引号，支持 `\"` `\\` |
| 裸名字 | 直接写 profile 名，如 `powershell` |

- 比例范围 5–95，超出或语法错误会给出中文错误。
- 布局里引用了不存在的 profile 时，启动前就会报错，不会先拉起后台服务。

## 启动时使用布局

```powershell
# 直接用表达式
scterm --layout "h(powershell,v(cmd,scterm))"

# 用配置里的命名布局
scterm --layout dev
```

查找顺序：先按名字查 `[layouts]`，找不到再把参数本身当表达式。

```toml
[layouts]
dev   = "h(powershell,v(cmd,powershell))"
even  = "v50(powershell,cmd)"
```

`--layout` 的优先级高于会话恢复：显式指定布局时不会读取 `session.toml`。

## 会话恢复

正常退出时，scterm 会把当前会话写成 `session.toml`（与配置文件同目录）：

- 标签数量与顺序；
- 每个标签的标题、是否自定义标题；
- 窗格树与分隔比例；
- 每个标签的焦点窗格；
- 当前活动标签。

下次启动自动恢复，并在状态栏提示「已恢复 N 个标签页」。

| 场景 | 行为 |
|---|---|
| 会话文件不存在 / 损坏 | 忽略，退回普通启动 |
| 某个标签的布局解析失败 | 跳过该标签，其余照常恢复 |
| 布局引用了已删除的 profile | 该窗格回退到默认 profile |
| `restore_session = false` | 不保存也不读取会话 |
| 使用 `--layout` | 不读取会话 |
| 强制结束客户端 | 不会写会话快照（只有正常退出才写） |

> 会话恢复只恢复**布局与 profile**，不会恢复窗格里正在运行的程序或输出；窗格会重新启动。

## 手工管理

- 删除 `%APPDATA%\scterm\session.toml` 即恢复到单标签启动；
- 会话文件是普通 TOML，可以手工改标题或布局表达式；
- 想固定一套工作区，建议用 `[layouts]` + `scterm --layout <名称>`，比依赖会话快照更可控。

## 下一步

- [Quake 下拉热键](../quake/)
- [配置文件详解](../config/)

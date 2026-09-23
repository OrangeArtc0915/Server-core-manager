---
title: 常见问题
description: 高频问题与实测结论，包括「为什么必须重启」「装完界面还是不好看」「脚本被拒绝执行」这类。
group: 参考
order: 1
---

## 一定要重启吗？

要。图形组件（`dwm.exe`、`dcomp.dll` 等）只有在重启后才加载。工具支持**跨重启断点续跑**，重启后再打开会接着跑完。

## 装完 FOD 界面还是很丑 / 主题不对？

这是预期内的：Server Core 缺主题服务组件（`themeservice.dll` / `themeui.dll`），窗口不会应用现代主题，看起来偏经典风格。见[已知限制](../limits/)第 2 条。

## `scm` 提示找不到工具入口

工具目录被移动或改名了。重新跑一次工具目录里的 `安装一行命令.bat`（`.cmd` 里写死了工具路径）。

## PowerShell 报「无法加载文件，未对文件进行数字签名」

包带了「来自 Internet」标记。执行：

```powershell
Get-ChildItem <工具目录> -Recurse *.ps1 | Unblock-File
```

命令行安装方式会自动做这一步。

## Windows Admin Center 装完访问不了

先跑「Windows Admin Center → 状态检查」。两个关键点：

1. **入口是 `/shell/` 而不是根路径** —— 根路径返回 403 是登录页的正常状态码，不是坏了
2. HTTPS 用自签名证书，浏览器需要选「继续访问」

## 点了下载 Windows Admin Center 就没反应了？

不会真的卡住 —— 它在下 140 MB。装的过程中日志会一直在写，窗口可以正常操作。进度可以看「更多 → Windows Admin Center → 状态检查」。

## 装美化终端时报 `not a valid application for this OS platform`

发布包里的可执行文件不完整（下载中断或被杀软改过）。重新下载发布包覆盖安装即可。工具装的时候会校验字体与可执行文件是否存在，缺了会在日志里明说。

## 为什么不用官方逐步教程，要用这个工具？

因为它把「判断该走哪条路 → 装什么 → 装完怎么验证 → 起不来怎么查」串成了一个流程，并且把社区里流传的错误说法（比如 `Server-Gui-Shell`）提前排除掉了。你也可以照着[环境页与一键补全](../environment/)里的原理自己敲命令，工具只是省事。

## 这些坑我们已经替你踩过了

下面这些都是开发过程中真实踩到、并且已经修掉的，列出来是让你遇到类似现象时能对上号：

| 现象 | 根因 |
|---|---|
| 改了带中文的 `.ps1`，脚本突然报语法错误 | 编辑器把 **UTF-8 BOM** 弄丢了。PowerShell 5.1 会按 GBK 读，中文注释乱码进而解析失败。含中文的脚本必须带 BOM；但 `install.ps1` **必须没有** BOM（`irm \| iex` 会失效） |
| 终端提示脚本让 cmd 疯狂起子进程（实测 2785 个 `find`） | cmd 的 `AutoRun` 对每个新 cmd 实例都生效，用管道做交互式判断会递归拉起子 cmd。现在只用环境变量做标记、零管道 |
| `cmd /c` 的输出里混进一堆 `'SCM_WELCOME_DONE' is not recognized` | 生成的 `.cmd` 存成了 LF 换行。cmd 批处理**必须是 CRLF** |
| 下载「成功」了但解压报错 | Gitee 对不存在的下载路径返回 `200` + 一段 JSON。现在按 zip 魔数 `PK` 校验内容 |
| 远程 PowerShell 里装 FOD 被拒绝访问 | WinRM 网络令牌下 DISM 写操作会被拒。已改成走 SYSTEM 计划任务 |
| 装完 WAC 远程会话断了、收尾没做完 | v2 安装包会重启 WinRM。收尾动作已全部放进 SYSTEM 任务 |
| 中文系统上「远程会话修复」找不到防火墙规则 | 按英文 `DisplayGroup` 匹配不到（组名被本地化了）。已改按本地化组名匹配 |
| 日志面板让界面卡死、日志无限滚动 | 日志里有 `\r` 回车符 + 面板每 400 ms 全量重读。已改成增量读取并去掉 `\r` |

## 还有问题

到 [Issues](https://github.com/OrangeArtc0915/Server-core-manager/issues) 提，或加 QQ 群 **1034243331**。带上 `logs\` 里最新的日志会快很多。

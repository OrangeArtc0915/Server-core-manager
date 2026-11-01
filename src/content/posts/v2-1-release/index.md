---
title: v2.1 发布说明
published: 2026-11-01
description: "新增运行库、数据库与卡片式应用商店；AI 辅助并入商店，程序档案改名 SCM附属。"
tags: ["发布", "更新日志"]
category: "更新日志"
draft: false
---

这一版加了三块新能力：**运行库**、**数据库**、**卡片式应用商店**。页面从 5 个扩到 17 个，动作从 29 个扩到 78 个。

## 运行库：多版本语言运行时

Server Core 上没有容器可用，所以没有照搬「拉镜像」那套，而是用 Windows 原生方式落地：

- 官方 zip 解压到 `runtimes\<语言>\<版本>`，`current` 用目录 junction 指路
- 机器 PATH 只挂 `current`，**切版本不用改脚本**，新开的命令行才生效
- 内置 Node.js / Python / Go / Java (Temurin) / PHP / Bun，多个版本共存
- 下载优先国内镜像（npmmirror / 华为云 / 阿里云），失败自动回退官方地址
- Python embed 版会自动打开 `site-packages`，安装完立刻探测版本

实测：Python 10.7 MB 官方源 452 秒，走华为云 **1.7 秒**。

## 数据库：PostgreSQL 与 MySQL 8

同样是原生落地，不跑安装器：

- **PostgreSQL**：EDB binaries zip → `initdb`（SCRAM 密码）→ `pg_ctl register` 注册服务（`NT AUTHORITY\NetworkService`）
- **MySQL 8**：`mysqld --initialize-insecure` → 临时起进程设 root 密码 → `mysqld --install` 注册服务（LocalSystem）
- 建库、备份（`pg_dump -Fc` / `mysqldump`）、还原（`pg_restore` / `mysql < dump`）都能在界面上点
- 密码用 DPAPI(LocalMachine) 加密后存实例记录，**不进命令行**
- 数据目录、配置文件、备份文件位置固定，卸载服务不会顺手删数据

一个踩过的坑：MySQL 的选项文件会解析 `\s`、`\t` 这类转义，`my.ini` 里的 Windows 路径必须写正斜杠，否则 `datadir` 会被截断成不存在的路径。

## 应用商店：卡片墙 + 兼容性预检

- 精选库扩到 **24 条**（22 个 Chocolatey 条目 + 2 个 npm 的 AI 辅助条目），按热度排序
- 卡片墙自适应列数，支持鼠标滚轮、分类筛选、兼容性筛选（实测可用 / 部分可用 / 未实测 / 不支持）
- **安装前预检**：包管理器在不在、是否已装、要不要 App Compatibility FOD、运行库依赖
- **详情弹窗**：实测凭据、已知问题、安装方式与静默参数、启动命令、替代应用
- 搜索结果（Chocolatey / npm）沿用同一套卡片，支持勾选批量安装

「AI 辅助」不再单独占一个页面，改成商店里的分类；依赖检查与启动动作仍在「全部功能 → AI 辅助」里。

## 页面调整

- 「程序档案」改名 **SCM附属**（内容待定，暂时沿用程序兼容档案）
- 「关于」页加了可点击的**官网**：<https://orangeartc0915.github.io/Server-core-manager/>
- 内置 TUI 监控（`scm-top`）抽了一份独立版，可以脱离主程序单独运行

## 安装

两条线路任选，装的是同一个发布包：

**Gitee（国内推荐）**

```powershell
irm https://gitee.com/orangearc655743/server-core-manager/raw/main/install.ps1 | iex
```

**GitHub**

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

重复执行安装等于升级，不会动已有的程序列表、日志与断点状态。

## 已知限制

- 数据库**服务注册**需要管理员；非管理员时安装与初始化仍能成功，注册服务时会明确报「需要管理员」
- 精选库里的 24 条目前全部是 **unverified**（未实测）。按项目规则，没有真机证据就不标 `verified`，所以「实测可用」筛选暂时是空的
- MySQL 8.4 已移除 `mysql_native_password`，老客户端请用 8.0.40 那条

## 源码

<https://github.com/OrangeArtc0915/Server-core-manager>

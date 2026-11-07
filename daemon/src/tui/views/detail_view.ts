import Instance from "../../entity/instance/instance";
import fs from "fs-extra";
import path from "path";
import { BaseView, type AppLike } from "../base";
import { blessed, c, displayWidth, menuNumber, PAL, truncateDisplay, type UiKey } from "../ui";
import { formatBytes, formatDuration, statusColor, statusText, typeLabel } from "../format";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { zipEntries } from "../service/zip_service";
import { opsLog } from "../service/ops_log";
import { WorldView } from "./world_view";
import { RconView } from "./rcon_view";
import { openInstanceTab, type InstanceTabKey } from "../instance_tabs";

interface MenuEntry {
  label: string;
  desc: string;
  number?: string;
  run: () => void;
}

/**
 * Instance page in the MCT layout: a status block followed by the list of
 * actions for this instance (terminal, files, config, ...).
 */
export class DetailView extends BaseView {
  private box: any;
  private cursor = 0;
  private offset = 0;

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  private get instance(): Instance | undefined {
    return instanceService.get(this.instanceUuid);
  }

  get title(): string {
    return t("detail.title");
  }

  get hints(): string {
    return "↑↓ 选择  Enter 确认  s/t/r/k 启停重启强杀  w 世界  o RCON  c 克隆  e 导出  x 删除  Esc 返回";
  }

  protected build() {
    this.box = blessed.box({
      parent: this.root,
      top: 0,
      left: 0,
      right: 0,
      bottom: 0,
      tags: true,
      style: { bg: PAL.bg, fg: PAL.text },
      padding: { left: 2, right: 2 }
    });
    this.main = this.box;
    this.refresh();
  }

  private entries(): MenuEntry[] {
    const tab = (key: InstanceTabKey, label: string, desc: string): MenuEntry => ({
      label,
      desc,
      run: () => openInstanceTab(this.app, this.instanceUuid, key)
    });
    return [
      tab("terminal", t("tab.terminal"), "实时输出 · 按 i 输入命令"),
      tab("files", t("tab.files"), "浏览 / 上传 / 下载 / 解压"),
      tab("config", t("tab.config"), "实例参数与 server.properties"),
      tab("players", t("tab.players"), "白名单 / OP 管理"),
      tab("schedule", t("tab.schedule"), "定时启停与命令"),
      tab("backups", t("tab.backups"), "创建 / 恢复 / 删除"),
      tab("mods", t("tab.mods"), "模组 / 插件 · 一键安装"),
      tab("java", t("tab.java"), "为实例指定运行时"),
      tab("frp", t("tab.frp"), "Sakura Frp 内网穿透"),
      tab("overview", t("tab.overview"), "资源趋势与详细信息"),
      {
        label: "世界管理",
        desc: "世界大小 · 备份 / 删除 / 切换",
        run: () => this.app.push(new WorldView(this.app, this.instanceUuid), () => new DetailView(this.app, this.instanceUuid))
      },
      {
        label: "RCON 控制台",
        desc: "不经 PTY 直接发送命令",
        run: () => this.app.push(new RconView(this.app, this.instanceUuid), () => new DetailView(this.app, this.instanceUuid))
      },
      {
        label: "克隆实例",
        desc: "复制文件与配置生成新实例",
        run: () => this.cloneInstance()
      },
      {
        label: "导出实例",
        desc: "打包为 zip 便于迁移",
        run: () => void this.exportInstance()
      },
      {
        label: t("inst.action.start"),
        desc: "启动实例",
        run: () => void this.act("start")
      },
      {
        label: t("inst.action.stop"),
        desc: "发送停止命令",
        run: () => void this.act("stop")
      },
      {
        label: t("inst.action.restart"),
        desc: "停止后重新启动",
        run: () => void this.act("restart")
      },
      {
        label: t("inst.action.kill"),
        desc: "强制结束进程",
        run: () => this.app.ui.confirm(t("inst.action.kill"), `${this.instance?.config.nickname}?`, () => void this.act("kill"))
      },
      {
        label: "删除实例",
        desc: "保留文件或连同文件一起删除",
        run: () => this.removeInstance()
      }
    ];
  }

  private removeInstance() {
    const instance = this.instance;
    if (!instance) return;
    if (instance.status() !== Instance.STATUS_STOP) {
      this.app.message("请先停止实例再删除", "warn");
      return;
    }
    const nickname = instance.config.nickname;
    this.app.ui.select(
      `删除实例 · ${nickname}`,
      [
        { label: "仅删除实例记录（保留服务端文件）", value: false },
        { label: "删除实例并删除全部服务端文件（不可恢复）", value: true }
      ],
      (deleteFiles) => {
        this.app.ui.confirm(
          "删除实例",
          `${nickname}${deleteFiles ? " 及其全部文件" : ""}，确定删除？`,
          () => {
            try {
              instanceService.remove(instance.instanceUuid, Boolean(deleteFiles));
              this.app.message(`已删除实例：${nickname}`, "success");
              this.app.back();
            } catch (error: any) {
              this.app.message(error?.message ?? String(error), "error");
            }
          }
        );
      }
    );
  }

  refresh() {
    if (!this.box) return;
    const instance = this.instance;
    if (!instance) {
      this.app.message(t("inst.noInstance"), "error");
      this.app.back();
      return;
    }
    const config = instance.config;
    const status = instance.status();
    const color = statusColor(status);
    const stats = instanceService.getStats(this.instanceUuid);
    const install = instanceService.getInstallProgress(this.instanceUuid);
    const uptime =
      status === Instance.STATUS_RUNNING && instance.startTimestamp > 0
        ? formatDuration((Date.now() - instance.startTimestamp) / 1000)
        : "-";
    const cpu = stats ? Math.min(999, Math.round(stats.cpu)) : 0;
    const memory = stats ? formatBytes(stats.memory) : "-";

    this.app.ui.screen.title = `CraftDock · ${config.nickname}`;

    const width = this.contentWidth(120);
    const labelWidth = Math.max(18, Math.min(30, Math.floor(width * 0.3)));
    const descWidth = Math.max(10, width - 4 - (labelWidth + 6));
    const entries = this.entries();
    if (this.cursor >= entries.length) this.cursor = entries.length - 1;

    const badge = install
      ? install.phase === "download"
        ? `↓ ${install.percentage}%`
        : t("inst.phase.extract")
      : `● ${statusText(status)}`;
    const lines: string[] = [];
    lines.push(c(PAL.dim, "实例") + "  " + c(PAL.bright, config.nickname) + "    " + c(install ? PAL.cyan : color, badge));
    lines.push(
      c(
        PAL.dim,
        `${typeLabel(config.type)}  ·  ${t("common.port")} ${config.basePort || "-"}  ·  ${t("common.uptime")} ${uptime}  ·  CPU ${cpu}%  ·  ${t(
          "common.mem"
        )} ${memory}`
      )
    );
    const alert = instanceService.getAlert(this.instanceUuid);
    lines.push(
      c(PAL.dim, `ID ${instance.instanceUuid}`) +
        (alert
          ? `    ${c(PAL.red, "⚠ 输出异常")} ${c(
              PAL.muted,
              truncateDisplay(alert.line, Math.max(10, width - 60))
            )}`
          : "")
    );
    lines.push("");
    // The menu starts at row 4; keep the cursor visible on small windows.
    const totalRows = Math.max(1, this.contentHeight(20) - 4);
    const showIndicator = entries.length > totalRows;
    const rows = Math.max(1, totalRows - (showIndicator ? 2 : 0));
    if (this.cursor < this.offset) this.offset = this.cursor;
    if (this.cursor >= this.offset + rows) this.offset = this.cursor - rows + 1;
    this.offset = Math.max(0, Math.min(this.offset, Math.max(0, entries.length - rows)));
    const visible = entries.slice(this.offset, this.offset + rows);
    visible.forEach((entry, i) => {
      const index = this.offset + i;
      const active = index === this.cursor;
      const marker = active ? c(PAL.accent, "❯") : " ";
      const number = entry.number ?? (index < 9 ? menuNumber(index) : " ");
      const label = active ? c(PAL.bright, entry.label) : c(PAL.text, entry.label);
      const pad = Math.max(2, labelWidth - displayWidth(entry.label));
      lines.push(
        `${marker} ${c(active ? PAL.accent : PAL.dim, number)} ${label}${" ".repeat(pad)}${c(
          PAL.dim,
          truncateDisplay(entry.desc, descWidth)
        )}`
      );
    });
    if (showIndicator) {
      lines.push("");
      lines.push(
        c(PAL.dim, `第 ${this.offset + 1}-${Math.min(entries.length, this.offset + rows)} / ${entries.length} 项`)
      );
    }
    this.box.setContent(lines.join("\n"));
    this.app.ui.render();
  }

  onTick() {
    this.refresh();
  }

  private cloneInstance() {
    const instance = this.instance;
    if (!instance) return;
    if (instance.status() !== Instance.STATUS_STOP) {
      this.app.ui.confirm(
        "克隆实例",
        "实例正在运行，复制过程中文件可能变化。建议先停止实例，仍要继续？",
        () => this.promptClone(instance)
      );
      return;
    }
    this.promptClone(instance);
  }

  private promptClone(instance: Instance) {
    this.app.ui.prompt({
      title: "克隆实例",
      label: "新实例名称",
      value: `${instance.config.nickname}-copy`,
      onSubmit: (value) => {
        const nickname = value.trim();
        if (!nickname) return false;
        const close = this.app.ui.busy("正在复制实例文件…");
        void instanceService
          .cloneInstance(this.instanceUuid, nickname)
          .then((clone) => {
            this.app.message(`已克隆为 ${clone.config.nickname}（端口 ${clone.config.basePort}）`, "success");
            opsLog.add("clone", `${instance.config.nickname} -> ${nickname}`, "success");
          })
          .catch((error) => this.app.message(`克隆失败：${error?.message ?? error}`, "error"))
          .finally(() => close());
        return true;
      }
    });
  }

  private async exportInstance() {
    const instance = this.instance;
    if (!instance) return;
    const cwd = instance.absoluteCwdPath();
    if (!fs.existsSync(cwd)) {
      this.app.message(`实例目录不存在：${cwd}`, "error");
      return;
    }
    const now = new Date();
    const pad = (n: number) => String(n).padStart(2, "0");
    const safe = instance.config.nickname.replace(/[\\/:*?"<>|]/g, "_");
    const name = `${safe}-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(
      now.getHours()
    )}${pad(now.getMinutes())}${pad(now.getSeconds())}.zip`;
    const target = path.join(process.cwd(), "data", "Exports", name);
    const close = this.app.ui.busy("正在导出实例…");
    try {
      const entries = fs.readdirSync(cwd).filter((entry) => entry !== "backups" && entry !== "logs");
      if (!entries.length) throw new Error("实例目录为空");
      await zipEntries(cwd, entries, target);
      opsLog.add("export", `${instance.config.nickname} -> ${name}`, "success");
      this.app.ui.alert("导出完成", `已保存到：\n${target}\n\n大小：${formatBytes(fs.statSync(target).size)}`);
    } catch (error: any) {
      this.app.message(`导出失败：${error?.message ?? error}`, "error");
    } finally {
      close();
    }
  }

  private async act(action: "start" | "stop" | "restart" | "kill") {
    try {
      await instanceService.act(this.instanceUuid, action);
      this.app.message(t("inst.action.done", { action: t(`inst.action.${action}`) }), "success");
      this.refresh();
    } catch (error: any) {
      this.app.message(t("inst.action.failed", { err: error?.message ?? error }), "error");
    }
  }

  onKey(ch: string, key: UiKey) {
    const entries = this.entries();
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    if (key.name === "up") {
      this.cursor = (this.cursor - 1 + entries.length) % entries.length;
      this.refresh();
      return;
    }
    if (key.name === "down") {
      this.cursor = (this.cursor + 1) % entries.length;
      this.refresh();
      return;
    }
    if (key.name === "enter" || key.name === "return") {
      entries[this.cursor]?.run();
      return;
    }
    switch (ch) {
      case "s":
        void this.act("start");
        return;
      case "t":
        void this.act("stop");
        return;
      case "r":
        void this.act("restart");
        return;
      case "k":
        this.app.ui.confirm(t("inst.action.kill"), `${this.instance?.config.nickname}?`, () => void this.act("kill"));
        return;
      case "w":
        this.app.push(new WorldView(this.app, this.instanceUuid), () => new DetailView(this.app, this.instanceUuid));
        return;
      case "o":
        this.app.push(new RconView(this.app, this.instanceUuid), () => new DetailView(this.app, this.instanceUuid));
        return;
      case "c":
        this.cloneInstance();
        return;
      case "e":
        void this.exportInstance();
        return;
      case "x":
        this.removeInstance();
        return;
    }
  }

  onMouse(row: number, _col: number, action: "click" | "wheelup" | "wheeldown") {
    const entries = this.entries();
    if (!entries.length) return;
    if (action === "wheelup") {
      this.cursor = (this.cursor - 1 + entries.length) % entries.length;
      this.refresh();
      return;
    }
    if (action === "wheeldown") {
      this.cursor = (this.cursor + 1) % entries.length;
      this.refresh();
      return;
    }
    // Three status lines + one blank line precede the menu rows.
    const index = this.offset + row - 4;
    if (index < 0 || index >= entries.length) return;
    this.cursor = index;
    this.refresh();
    entries[index].run();
  }
}

import fs from "fs-extra";
import path from "path";
import Instance from "../../entity/instance/instance";
import { globalConfiguration } from "../../entity/config";
import { BaseView, type AppLike } from "../base";
import { blessed, c, headerLine, menuNumber, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { formatBytes, formatDuration, statusColor, statusText, typeLabel } from "../format";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { extractArchive } from "../service/zip_service";
import { opsLog } from "../service/ops_log";
import { CreateView } from "./create_view";
import { MslView } from "./msl_view";
import { DetailView } from "./detail_view";

/**
 * Instance list in the MCT layout: one numbered row per instance with a short
 * description on the right. Enter opens the instance menu.
 */
export class InstancesView extends BaseView {
  private box: any;
  public filter = "";
  public tagFilter = "";
  private cursor = 0;
  private offset = 0;

  constructor(app: AppLike) {
    super(app);
  }

  get title(): string {
    return t("inst.title");
  }

  get hints(): string {
    return "↑↓ 选择  Enter 管理  s/t/r/k 启停重启强杀  x 删除  n 新建  i 镜像  o 导入  P 批量分配端口  / 搜索  T 标签  Esc 返回";
  }

  protected build() {
    this.page(t("inst.title"));
    this.box = blessed.box({
      parent: this.root,
      top: 2,
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

  private instances(): Instance[] {
    let all = instanceService.list();
    if (this.filter) {
      const keyword = this.filter.toLowerCase();
      all = all.filter((instance) => instance.config.nickname.toLowerCase().includes(keyword));
    }
    if (this.tagFilter) {
      all = all.filter((instance) => (instance.config.tag ?? []).includes(this.tagFilter));
    }
    return all;
  }

  refresh() {
    if (!this.box) return;
    const instances = this.instances();
    if (this.cursor >= instances.length) this.cursor = Math.max(0, instances.length - 1);
    const width = this.contentWidth(120);
    const labelWidth = Math.max(20, Math.min(34, Math.floor(width * 0.34)));
    const rows = Math.max(1, this.contentHeight(20) - 2);
    if (this.cursor < this.offset) this.offset = this.cursor;
    if (this.cursor >= this.offset + rows) this.offset = this.cursor - rows + 1;
    this.offset = Math.max(0, Math.min(this.offset, Math.max(0, instances.length - rows)));

    const lines: string[] = [];

    if (!instances.length) {
      lines.push("");
      lines.push(c(PAL.dim, t("inst.empty")));
    } else {
      const visible = instances.slice(this.offset, this.offset + rows);
      visible.forEach((instance, i) =>
        this.appendRow(lines, instance, this.offset + i, labelWidth, width)
      );
    }
    this.box.setContent(lines.join("\n"));

    const running = instances.filter((instance) => instance.status() === Instance.STATUS_RUNNING).length;
    const metaParts = [`${instances.length} 个实例`, `运行 ${running}`];
    if (instances.length > rows) {
      metaParts.push(`${this.offset + 1}-${Math.min(instances.length, this.offset + rows)}/${instances.length}`);
    }
    const installing = instances.filter((instance) => instanceService.getInstallProgress(instance.instanceUuid)).length;
    if (installing) metaParts.push(`↓ ${installing}`);
    if (this.filter) metaParts.push(`筛选 ${this.filter}`);
    if (this.tagFilter) metaParts.push(`#${this.tagFilter}`);
    this.pageHeader?.header.setContent(
      headerLine(width - 4, { title: t("inst.title"), meta: metaParts.join("  ·  ") })
    );
    this.app.ui.render();
  }

  private appendRow(lines: string[], instance: Instance, index: number, labelWidth: number, width: number) {
    const active = index === this.cursor;
    const status = instance.status();
    const color = statusColor(status);
    const stats = instanceService.getStats(instance.instanceUuid);
    const install = instanceService.getInstallProgress(instance.instanceUuid);
    const players = instance.info?.mcPingOnline
      ? `${instance.info.currentPlayers}/${instance.info.maxPlayers}`
      : "-";
    const cpu = stats ? Math.round(stats.cpu) : 0;
    const memory = stats ? formatBytes(stats.memory) : "-";
    const uptime =
      status === Instance.STATUS_RUNNING && instance.startTimestamp > 0
        ? formatDuration((Date.now() - instance.startTimestamp) / 1000)
        : "-";

    const badge = install
      ? install.phase === "download"
        ? `↓ ${install.percentage}%`
        : `⟳ ${t("inst.phase.extract")}`
      : `● ${statusText(status)}`;
    const alert = instanceService.getAlert(instance.instanceUuid);
    const desc = install
      ? `${badge}  ·  ${install.speed > 0 ? `${(install.speed / 1024 / 1024).toFixed(1)} MB/s` : "-"}  ·  ${
          install.elapsed
        }s`
      : `${alert ? "⚠ " : ""}${badge}  ·  ${typeLabel(instance.config.type)}  ·  :${instance.config.basePort || "-"}  ·  ${t(
          "common.players"
        )} ${players}  ·  CPU ${cpu}%  ·  ${t("common.mem")} ${memory}  ·  ${uptime}`;
    // Keep every row inside the terminal width, otherwise blessed wraps the
    // line and the columns below it look broken.
    const descWidth = Math.max(12, width - 4 - (labelWidth + 8));
    const descText = truncateDisplay(desc, descWidth);

    const marker = active ? c(PAL.accent, "❯") : " ";
    const number = c(active ? PAL.accent : PAL.dim, menuNumber(index));
    const name = active
      ? c(PAL.bright, padDisplay(truncateDisplay(instance.config.nickname, labelWidth), labelWidth))
      : c(PAL.text, padDisplay(truncateDisplay(instance.config.nickname, labelWidth), labelWidth));
    const descColor = install ? PAL.cyan : color;
    const row = `${marker} ${number} ${name} ${c(descColor, descText)}`;
    lines.push(active ? `{${PAL.selectBg}-bg}${padDisplay(row, width - 4)}{/}` : row);
  }

  onTick() {
    this.refresh();
  }

  private currentInstance(): Instance | undefined {
    return this.instances()[this.cursor];
  }

  private move(delta: number) {
    const count = this.instances().length;
    if (!count) return;
    this.cursor = (this.cursor + delta + count) % count;
    this.refresh();
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.focusSidebar();
      return;
    }
    if (key.name === "up") {
      this.move(-1);
      return;
    }
    if (key.name === "down") {
      this.move(1);
      return;
    }
    if (key.name === "enter" || key.name === "return") {
      this.openDetail();
      return;
    }
    switch (ch) {
      case "s":
        void this.action("start");
        return;
      case "t":
        void this.action("stop");
        return;
      case "r":
        void this.action("restart");
        return;
      case "k":
        void this.action("kill", true);
        return;
      case "x":
        this.remove();
        return;
      case "n":
        this.app.ui.select(
          t("create.mode"),
          [
            { label: t("create.mode.blank"), value: "blank" },
            { label: t("create.mode.mirror"), value: "mirror" }
          ],
          (value) => {
            if (value === "blank") this.app.push(new CreateView(this.app), () => new InstancesView(this.app));
            else this.app.push(new MslView(this.app), () => new InstancesView(this.app));
          }
        );
        return;
      case "i":
        this.app.push(new MslView(this.app), () => new InstancesView(this.app));
        return;
      case "o":
        this.importInstance();
        return;
      case "/":
        this.app.ui.prompt({
          title: t("inst.title"),
          label: t("inst.search"),
          value: this.filter,
          onSubmit: (value) => {
            this.filter = value.trim();
            this.cursor = 0;
            this.refresh();
          }
        });
        return;
      case "T":
        this.pickTag();
        return;
      case "P":
        this.allocatePorts();
        return;
      case "R":
        this.refresh();
        return;
    }
  }

  private openDetail() {
    const current = this.currentInstance();
    if (!current) {
      this.app.message(t("inst.selectFirst"), "warn");
      return;
    }
    this.app.push(new DetailView(this.app, current.instanceUuid), () => new InstancesView(this.app));
  }

  onMouse(row: number, _col: number, action: "click" | "wheelup" | "wheeldown") {
    const count = this.instances().length;
    if (!count) return;
    if (action === "wheelup") {
      this.move(-1);
      return;
    }
    if (action === "wheeldown") {
      this.move(1);
      return;
    }
    const index = this.offset + row - 2;
    if (index < 0 || index >= count) return;
    if (this.cursor === index) {
      this.openDetail();
      return;
    }
    this.cursor = index;
    this.refresh();
  }

  private async action(action: "start" | "stop" | "restart" | "kill", confirm = false) {
    const instance = this.currentInstance();
    if (!instance) {
      this.app.message(t("inst.selectFirst"), "warn");
      return;
    }
    const label = t(`inst.action.${action}`);
    const execute = async () => {
      try {
        await instanceService.act(instance.instanceUuid, action);
        this.app.message(`${label} ${instance.config.nickname}`, "success");
      } catch (error: any) {
        this.app.message(t("inst.action.failed", { err: error?.message ?? error }), "error");
      }
      this.refresh();
    };
    if (confirm) {
      this.app.ui.confirm(label, `${label}: ${instance.config.nickname}?`, () => void execute());
    } else {
      await execute();
    }
  }

  private remove() {
    const instance = this.currentInstance();
    if (!instance) {
      this.app.message(t("inst.selectFirst"), "warn");
      return;
    }
    this.app.ui.select(
      t("inst.delete.title"),
      [
        { label: `${instance.config.nickname}  →  ${t("inst.delete.withFiles")}`, value: true },
        { label: `${instance.config.nickname}  →  ${t("inst.delete.keepFiles")}`, value: false }
      ],
      (deleteFiles) => {
        try {
          instanceService.remove(instance.instanceUuid, Boolean(deleteFiles));
          opsLog.add("delete", instance.config.nickname, "success");
          this.app.message(t("inst.deletedCount", { n: 1 }), "success");
          this.cursor = 0;
          this.refresh();
        } catch (error: any) {
          this.app.message(t("inst.action.failed", { err: error?.message ?? error }), "error");
        }
      }
    );
  }

  /** Import an exported instance archive (zip / 7z) as a new instance. */
  private importInstance() {
    this.app.ui.prompt({
      title: "导入实例",
      label: "备份文件路径（.zip / .7z）",
      value: "",
      onSubmit: (value) => {
        const file = value.trim().replace(/^"(.*)"$/, "$1");
        if (!file || !fs.existsSync(file)) {
          this.app.message(`文件不存在：${file || "（空）"}`, "error");
          return false;
        }
        const nickname = path.basename(file).replace(/\.(zip|7z)$/i, "") || "imported";
        const close = this.app.ui.busy("正在导入实例…");
        void (async () => {
          let created: Instance | undefined;
          try {
            created = instanceService.createBlank({
              nickname,
              startCommand: "",
              type: "minecraft/java"
            });
            await extractArchive(file, created.absoluteCwdPath());
            const detected = this.detectStartCommand(created.absoluteCwdPath());
            instanceService.updateConfig(created.instanceUuid, {
              type: detected.type,
              startCommand: detected.command ?? ""
            } as any);
            this.app.message(
              `导入完成：${nickname}${detected.command ? "（已识别启动命令）" : "（请到配置填写启动命令）"}`,
              "success"
            );
            opsLog.add("import", `${nickname} <- ${file}`, "success");
            this.refresh();
          } catch (error: any) {
            if (created) {
              try {
                instanceService.remove(created.instanceUuid, true);
              } catch (cleanupError) {}
            }
            this.app.message(`导入失败：${error?.message ?? error}`, "error");
          } finally {
            close();
          }
        })();
        return true;
      }
    });
  }

  private detectStartCommand(cwd: string): { command?: string; type: string } {
    try {
      const files = fs.readdirSync(cwd, { withFileTypes: true });
      const bedrock = files.find(
        (file) => file.isFile() && /^bedrock_server(\.exe)?$/i.test(file.name)
      );
      if (bedrock) {
        return { command: `"${bedrock.name}"`, type: "minecraft/bedrock" };
      }
      const jars = files
        .filter((file) => file.isFile() && file.name.toLowerCase().endsWith(".jar"))
        .map((file) => file.name);
      if (!jars.length) return { type: "minecraft/java" };
      const jar =
        jars.find((name) => /^(server|paper|purpur|spigot|bukkit|forge|fabric|velocity|bungeecord).*\.jar$/i.test(name)) ??
        jars[0];
      return { command: `{mcsm_java} -Xmx4G -jar "${jar}" nogui`, type: "minecraft/java" };
    } catch (error) {
      return { type: "minecraft/java" };
    }
  }

  private declaredPort(instance: Instance): number | undefined {
    try {
      const file = path.join(instance.absoluteCwdPath(), "server.properties");
      if (!fs.existsSync(file)) return undefined;
      const match = /^\s*server-port\s*=\s*(\d+)/m.exec(fs.readFileSync(file, "utf-8"));
      return match ? Number(match[1]) : undefined;
    } catch (error) {
      return undefined;
    }
  }

  /** Keep server.properties in sync, otherwise the next start overrides basePort. */
  private writeServerPort(instance: Instance, port: number) {
    try {
      const file = path.join(instance.absoluteCwdPath(), "server.properties");
      if (!fs.existsSync(file)) return;
      const text = fs.readFileSync(file, "utf-8");
      const next = /^\s*server-port\s*=.*$/m.test(text)
        ? text.replace(/^\s*server-port\s*=.*$/m, `server-port=${port}`)
        : `${text.replace(/\s*$/, "")}\nserver-port=${port}\n`;
      fs.writeFileSync(file, next, "utf-8");
    } catch (error: any) {
      this.app.message(`写入 server.properties 失败：${error?.message ?? error}`, "warn");
    }
  }

  /**
   * One-click port cleanup: give every instance a unique, valid port inside the
   * configured allocatable range and sync server.properties.
   */
  private allocatePorts() {
    const instances = instanceService.list();
    if (!instances.length) {
      this.app.message(t("inst.empty"), "warn");
      return;
    }
    const range = (globalConfiguration.config.allocatablePortRange ?? [10010, 65500]) as number[];
    const start = Math.max(1024, Number(range[0]) || 10010);
    const end = Math.max(start + 1, Number(range[1]) || 65500);
    let next = Math.max(start, Number(globalConfiguration.config.currentAllocatablePort) || start);
    const seen = new Set<number>();
    const updates: Array<{ instance: Instance; from: number; to: number }> = [];

    for (const instance of instances) {
      const declared = this.declaredPort(instance) ?? (Number(instance.config.basePort) || 0);
      const invalid = !declared || declared < 1024 || declared > 65535 || seen.has(declared);
      if (!invalid) {
        seen.add(declared);
        continue;
      }
      while (next <= end && seen.has(next)) next++;
      if (next > end) break;
      updates.push({ instance, from: declared, to: next });
      seen.add(next);
      next++;
    }

    if (!updates.length) {
      this.app.message("所有实例的端口都唯一且有效，无需调整", "success");
      return;
    }
    const summary = updates
      .map((item) => `${item.instance.config.nickname}: ${item.from || "-"} → ${item.to}`)
      .join("\n");
    this.app.ui.confirm(
      "批量分配端口",
      `将调整 ${updates.length} 个实例：\n${summary}\n\n运行中的实例需要重启后生效。`,
      () => {
        try {
          for (const item of updates) {
            const config = item.instance.config;
            instanceService.updateConfig(item.instance.instanceUuid, {
              basePort: item.to,
              pingConfig: {
                ip: config.pingConfig?.ip ?? "",
                port: item.to,
                type: config.pingConfig?.type ?? 1
              }
            });
            this.writeServerPort(item.instance, item.to);
          }
          globalConfiguration.config.currentAllocatablePort = next;
          globalConfiguration.store();
          opsLog.add("port allocate", updates.map((item) => `${item.instance.config.nickname}:${item.to}`).join(","), "success");
          this.app.message(`已为 ${updates.length} 个实例分配新端口`, "success");
          this.refresh();
        } catch (error: any) {
          this.app.message(error?.message ?? String(error), "error");
        }
      }
    );
  }

  private pickTag() {
    const tags = new Set<string>();
    for (const instance of instanceService.list()) {
      for (const tag of instance.config.tag ?? []) tags.add(tag);
    }
    const options = [
      { label: t("inst.tag.all"), value: "" },
      ...Array.from(tags).map((tag) => ({ label: "#" + tag, value: tag }))
    ];
    this.app.ui.select(
      t("inst.tag.pick"),
      options,
      (value) => {
        this.tagFilter = value;
        this.cursor = 0;
        this.refresh();
      },
      undefined,
      false
    );
  }
}

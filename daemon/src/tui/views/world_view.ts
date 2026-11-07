import fs from "fs-extra";
import path from "path";
import Instance from "../../entity/instance/instance";
import { BaseView, type AppLike } from "../base";
import { blessed, c, createFlatList, escapeTags, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { formatBytes, formatDateTime } from "../format";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { backupService } from "../service/backup_service";
import { zipEntries } from "../service/zip_service";
import { opsLog } from "../service/ops_log";

interface WorldEntry {
  name: string;
  size: number;
  time: number;
  active: boolean;
}

/** Directory size with a depth guard so a symlink loop cannot hang the TUI. */
function dirSize(target: string, depth = 0): number {
  if (depth > 12) return 0;
  let total = 0;
  try {
    for (const entry of fs.readdirSync(target, { withFileTypes: true })) {
      const child = path.join(target, entry.name);
      if (entry.isDirectory()) total += dirSize(child, depth + 1);
      else if (entry.isFile()) {
        try {
          total += fs.statSync(child).size;
        } catch (error) {}
      }
    }
  } catch (error) {}
  return total;
}

/** World folders: every directory holding a level.dat, plus classic world* names. */
export class WorldView extends BaseView {
  private list: any;
  private worlds: WorldEntry[] = [];

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  get title(): string {
    return "世界管理";
  }

  get hints(): string {
    return "b 备份所选世界   l 设为 level-name   x 删除   r 刷新   Esc 返回";
  }

  private cwd(): string {
    return instanceService.get(this.instanceUuid)?.absoluteCwdPath() ?? "";
  }

  protected build() {
    this.page(instanceService.get(this.instanceUuid)?.config.nickname ?? "", "世界管理", t("inst.title"));
    this.list = createFlatList(this.root, 2);
    this.main = this.list;
    this.list.focus();
    this.refresh();
  }

  private activeLevelName(): string {
    try {
      const file = path.join(this.cwd(), "server.properties");
      if (!fs.existsSync(file)) return "world";
      const match = /^\s*level-name\s*=\s*(.+)$/m.exec(fs.readFileSync(file, "utf-8"));
      return match ? match[1].trim() : "world";
    } catch (error) {
      return "world";
    }
  }

  refresh() {
    if (!this.list) return;
    const root = this.cwd();
    const active = this.activeLevelName();
    const found: WorldEntry[] = [];
    try {
      for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        const dir = path.join(root, entry.name);
        const isWorld = fs.existsSync(path.join(dir, "level.dat")) || /^world/i.test(entry.name);
        if (!isWorld) continue;
        let time = 0;
        try {
          time = fs.statSync(dir).mtimeMs;
        } catch (error) {}
        found.push({ name: entry.name, size: dirSize(dir), time, active: entry.name === active });
      }
    } catch (error: any) {
      this.app.message(`无法读取实例目录：${error?.message ?? error}`, "error");
    }
    this.worlds = found.sort((a, b) => (a.active ? -1 : b.active ? 1 : a.name.localeCompare(b.name)));

    const width = this.contentWidth();
    const nameWidth = Math.max(16, width - 40);
    const items = this.worlds.map(
      (world) =>
        `${world.active ? c(PAL.green, "●") : " "} ${c(
          world.active ? PAL.bright : PAL.text,
          padDisplay(truncateDisplay(world.name, nameWidth), nameWidth)
        )} ${c(PAL.muted, padDisplay(formatBytes(world.size), 10))} ${c(PAL.dim, formatDateTime(world.time))}`
    );
    if (!items.length) items.push(c(PAL.dim, "没有找到世界目录（level.dat / world*）"));
    const previous = this.list.selected ?? 0;
    this.list.setItems(items);
    this.list.select(Math.min(previous, items.length - 1));
    const total = this.worlds.reduce((sum, world) => sum + world.size, 0);
    this.updatePage(
      instanceService.get(this.instanceUuid)?.config.nickname ?? "",
      `${this.worlds.length} 个世界 · 共 ${formatBytes(total)} · level-name=${active}`,
      t("inst.title")
    );
    this.app.ui.render();
  }

  private selected(): WorldEntry | undefined {
    return this.worlds[this.list?.selected ?? 0];
  }

  private async backup() {
    const world = this.selected();
    if (!world) return;
    const instance = instanceService.get(this.instanceUuid);
    if (!instance) return;
    const running = instance.status() === Instance.STATUS_RUNNING;
    const start = () => void this.runBackup(world);
    if (running) {
      this.app.ui.confirm(
        "备份世界",
        `实例正在运行，备份文件可能与实际存档不完全一致。\n建议先执行 save-all。继续？`,
        start
      );
      return;
    }
    start();
  }

  private async runBackup(world: WorldEntry) {
    const instance = instanceService.get(this.instanceUuid);
    if (!instance) return;
    const now = new Date();
    const pad = (n: number) => String(n).padStart(2, "0");
    const name = `world-${world.name}-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(
      now.getHours()
    )}${pad(now.getMinutes())}${pad(now.getSeconds())}.zip`;
    const target = path.join(backupService.dir(this.instanceUuid), name);
    const close = this.app.ui.busy(`正在备份世界 ${world.name}…`);
    try {
      await zipEntries(this.cwd(), [world.name], target);
      this.app.message(`世界备份完成：${name}`, "success");
      opsLog.add("world backup", `${instance.config.nickname} ${world.name}`, "success");
    } catch (error: any) {
      this.app.message(`备份失败：${error?.message ?? error}`, "error");
    } finally {
      close();
    }
  }

  private setLevelName() {
    const world = this.selected();
    if (!world) return;
    if (instanceService.get(this.instanceUuid)?.status() !== Instance.STATUS_STOP) {
      this.app.message("请先停止实例再切换世界", "warn");
      return;
    }
    try {
      const file = path.join(this.cwd(), "server.properties");
      if (!fs.existsSync(file)) {
        this.app.message("实例目录中没有 server.properties，无法切换世界", "error");
        return;
      }
      const text = fs.readFileSync(file, "utf-8");
      const next = /^\s*level-name\s*=.*$/m.test(text)
        ? text.replace(/^\s*level-name\s*=.*$/m, `level-name=${world.name}`)
        : `${text.replace(/\s*$/, "")}\nlevel-name=${world.name}\n`;
      fs.writeFileSync(file, next, "utf-8");
      opsLog.add("world switch", world.name, "success");
      this.app.message(`已设置 level-name=${world.name}（重启后生效）`, "success");
      this.refresh();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private removeWorld() {
    const world = this.selected();
    if (!world) return;
    if (instanceService.get(this.instanceUuid)?.status() !== Instance.STATUS_STOP) {
      this.app.message("请先停止实例再删除世界", "warn");
      return;
    }
    if (world.active) {
      this.app.message("当前正在使用的世界不能删除，请先切换 level-name", "warn");
      return;
    }
    this.app.ui.confirm("删除世界", `删除 ${escapeTags(world.name)}（${formatBytes(world.size)}）？不可恢复`, () => {
      const close = this.app.ui.busy("正在删除世界…");
      void fs
        .remove(path.join(this.cwd(), world.name))
        .then(() => {
          opsLog.add("world delete", world.name, "success");
          this.app.message(`已删除世界：${world.name}`, "success");
          this.refresh();
        })
        .catch((error) => this.app.message(error?.message ?? String(error), "error"))
        .finally(() => close());
    });
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    switch (ch) {
      case "b":
        void this.backup();
        return;
      case "l":
        this.setLevelName();
        return;
      case "x":
        this.removeWorld();
        return;
      case "r":
      case "R":
        this.refresh();
        return;
    }
  }
}

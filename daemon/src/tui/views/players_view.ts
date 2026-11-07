import fs from "fs-extra";
import path from "path";
import Instance from "../../entity/instance/instance";
import { BaseView, type AppLike } from "../base";
import { c, createFlatList, escapeTags, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { opsLog } from "../service/ops_log";

interface PlayerEntry {
  name: string;
  uuid: string;
  whitelisted: boolean;
  op: boolean;
  online: boolean;
  level?: number;
}

/**
 * Whitelist / OP player management, mirroring the MSL "player management"
 * panel: read whitelist.json & ops.json, add players through server commands,
 * remove them even while the server is stopped.
 */
export class PlayersView extends BaseView {
  private list: any;
  private players: PlayerEntry[] = [];

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  private get instance(): Instance | undefined {
    return instanceService.get(this.instanceUuid);
  }

  get title(): string {
    return t("players.title");
  }

  get hints(): string {
    return "k 踢出  b 封禁  p 解封  a 加白名单  o 设为 OP  x 移除  r 刷新  Esc 返回";
  }

  protected build() {
    const name = this.instance?.config.nickname ?? "";
    this.page(name, t("players.title"), t("inst.title"));
    this.list = createFlatList(this.root, 2);
    this.main = this.list;
    this.list.focus();
    this.refresh();
  }

  refresh() {
    if (!this.list) return;
    this.players = this.loadPlayers();
    const width = this.contentWidth();
    const nameWidth = Math.max(16, Math.min(28, Math.floor(width * 0.3)));
    const items = this.players.map((player) => {
      const tags = [
        player.online ? c(PAL.green, "在线") : "",
        player.op ? c(PAL.magenta, "OP") : "",
        player.whitelisted ? c(PAL.green, "白名单") : ""
      ]
        .filter(Boolean)
        .join(" ");
      // Full UUIDs only fit on wide terminals; keep the row inside the width.
      const uuid = width >= 110 ? player.uuid : `${player.uuid.slice(0, 8)}…`;
      return (
        `${player.online ? c(PAL.green, "●") : c(PAL.dim, "○")} ` +
        `${c(PAL.bright, padDisplay(truncateDisplay(player.name, nameWidth), nameWidth))} ` +
        `${c(PAL.dim, escapeTags(uuid))}  ${tags}`
      );
    });
    if (!items.length) items.push(c(PAL.dim, t("players.empty")));
    const previous = this.list.selected ?? 0;
    this.list.setItems(items);
    this.list.select(Math.min(previous, items.length - 1));
    const online = this.players.filter((player) => player.online).length;
    this.updatePage(
      this.instance?.config.nickname ?? "",
      `${this.players.length} 位玩家 · 在线 ${online}`,
      t("inst.title")
    );
    this.app.ui.render();
  }

  private baseDir(): string {
    return this.instance?.absoluteCwdPath() ?? "";
  }

  private readJson<T>(file: string): T[] {
    try {
      const target = path.join(this.baseDir(), file);
      if (!fs.existsSync(target)) return [];
      const data = JSON.parse(fs.readFileSync(target, "utf-8"));
      return Array.isArray(data) ? data : [];
    } catch (error) {
      return [];
    }
  }

  private loadPlayers(): PlayerEntry[] {
    const map = new Map<string, PlayerEntry>();
    for (const item of this.readJson<any>("whitelist.json")) {
      const key = String(item.uuid ?? item.name ?? "").toLowerCase();
      if (!key) continue;
      map.set(key, {
        name: String(item.name ?? item.uuid ?? "?"),
        uuid: String(item.uuid ?? "-"),
        whitelisted: true,
        op: false,
        online: false
      });
    }
    for (const item of this.readJson<any>("ops.json")) {
      const key = String(item.uuid ?? item.name ?? "").toLowerCase();
      if (!key) continue;
      const existing = map.get(key);
      if (existing) {
        existing.op = true;
        existing.level = item.level;
      } else {
        map.set(key, {
          name: String(item.name ?? item.uuid ?? "?"),
          uuid: String(item.uuid ?? "-"),
          whitelisted: false,
          op: true,
          online: false,
          level: item.level
        });
      }
    }
    // Merge players that the console reported as joined but are not in any file.
    for (const name of instanceService.getOnlinePlayers(this.instanceUuid)) {
      const existing = Array.from(map.values()).find(
        (player) => player.name.toLowerCase() === name.toLowerCase()
      );
      if (existing) {
        existing.online = true;
        continue;
      }
      map.set(`name:${name.toLowerCase()}`, {
        name,
        uuid: "-",
        whitelisted: false,
        op: false,
        online: true
      });
    }
    return Array.from(map.values()).sort(
      (a, b) => (a.online === b.online ? a.name.localeCompare(b.name) : a.online ? -1 : 1)
    );
  }

  private selectedPlayer(): PlayerEntry | undefined {
    return this.players[this.list?.selected ?? 0];
  }

  private requireRunning(): boolean {
    if (this.instance?.status() !== Instance.STATUS_RUNNING) {
      this.app.message("请先启动服务器：白名单与 OP 命令需要服务器在线执行", "warn");
      return false;
    }
    return true;
  }

  private addWhitelist() {
    if (!this.requireRunning()) return;
    this.app.ui.prompt({
      title: t("players.addWhitelist"),
      label: "玩家名",
      value: "",
      onSubmit: (value) => {
        const name = value.trim();
        if (!name) return false;
        void this.send(`whitelist add ${name}`, `${name} 已加入白名单`);
      }
    });
  }

  private addOp() {
    if (!this.requireRunning()) return;
    this.app.ui.prompt({
      title: t("players.addOp"),
      label: "玩家名",
      value: "",
      onSubmit: (value) => {
        const name = value.trim();
        if (!name) return false;
        void this.send(`op ${name}`, `${name} 已设为 OP`);
      }
    });
  }

  private kick() {
    if (!this.requireRunning()) return;
    const player = this.selectedPlayer();
    this.app.ui.prompt({
      title: "踢出玩家",
      label: "玩家名",
      value: player?.name ?? "",
      onSubmit: (value) => {
        const name = value.trim();
        if (!name) return false;
        void this.send(`kick ${name}`, `${name} 已被踢出`);
        return true;
      }
    });
  }

  private ban() {
    if (!this.requireRunning()) return;
    const player = this.selectedPlayer();
    this.app.ui.prompt({
      title: "封禁玩家",
      label: "玩家名",
      value: player?.name ?? "",
      onSubmit: (value) => {
        const name = value.trim();
        if (!name) return false;
        void this.send(`ban ${name}`, `${name} 已被封禁`);
        return true;
      }
    });
  }

  private pardon() {
    if (!this.requireRunning()) return;
    const player = this.selectedPlayer();
    this.app.ui.prompt({
      title: "解封玩家",
      label: "玩家名",
      value: player?.name ?? "",
      onSubmit: (value) => {
        const name = value.trim();
        if (!name) return false;
        void this.send(`pardon ${name}`, `${name} 已解封`);
        return true;
      }
    });
  }

  private async send(command: string, okText: string) {
    try {
      await instanceService.sendCommand(this.instanceUuid, command);
      this.app.message(okText, "success");
      opsLog.add("player", command, "success");
      setTimeout(() => {
        if (!this.isDisposed) void this.refresh();
      }, 1500);
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private lastTick = 0;

  onTick() {
    // Join/leave lines update the online set; refresh quietly every 2 seconds.
    if (Date.now() - this.lastTick < 2000) return;
    this.lastTick = Date.now();
    this.refresh();
  }

  private remove() {
    const player = this.selectedPlayer();
    if (!player) {
      this.app.message(t("players.selectFirst"), "warn");
      return;
    }
    if (player.uuid === "-") {
      this.app.message("该玩家只出现在在线列表里，不在白名单/OP 中（可用 b 封禁）", "warn");
      return;
    }
    this.app.ui.confirm(
      t("players.remove"),
      `${player.name}（白名单/OP）`,
      () => {
        if (this.instance?.status() === Instance.STATUS_RUNNING) {
          void this.send(`whitelist remove ${player.name}`, `${player.name} 已移出白名单（OP 请用 deop）`);
          return;
        }
        this.removeOffline(player);
      }
    );
  }

  private removeOffline(player: PlayerEntry) {
    try {
      const filter = (file: string) => {
        const target = path.join(this.baseDir(), file);
        if (!fs.existsSync(target)) return;
        const list = this.readJson<any>(file).filter(
          (item) => String(item.uuid ?? item.name ?? "").toLowerCase() !== player.uuid.toLowerCase()
        );
        fs.writeFileSync(target, JSON.stringify(list, null, 2), "utf-8");
      };
      filter("whitelist.json");
      filter("ops.json");
      this.app.message(`${player.name} 已从白名单/OP 中移除`, "success");
      opsLog.add("player", `remove ${player.name}`, "success");
      this.refresh();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    switch (ch) {
      case "k":
        this.kick();
        return;
      case "b":
        this.ban();
        return;
      case "p":
        this.pardon();
        return;
      case "a":
        this.addWhitelist();
        return;
      case "o":
        this.addOp();
        return;
      case "x":
        this.remove();
        return;
      case "r":
      case "R":
        this.refresh();
        return;
    }
  }
}

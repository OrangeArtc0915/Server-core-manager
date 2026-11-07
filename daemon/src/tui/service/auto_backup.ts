import fs from "fs-extra";
import path from "path";
import Instance from "../../entity/instance/instance";
import logger from "../../service/log";
import { backupService } from "./backup_service";
import { instanceService } from "./instance_service";

export interface AutoBackupConfig {
  /** Backup interval in hours; 0 disables the schedule. */
  intervalHours: number;
  /** How many archives to keep per instance (newest first). */
  keep: number;
  lastRun: number;
}

type Notify = (message: string, level: "info" | "success" | "warn" | "error") => void;

const FILE = () => path.join(process.cwd(), "data", "auto-backup.json");
const TICK_MS = 60_000;

/**
 * Background scheduler for periodic instance backups.
 *
 * The schedule lives in `data/auto-backup.json` (per instance interval + keep
 * count) instead of the daemon config so it survives upgrades without touching
 * the upstream instance schema. Running servers are skipped — archiving a live
 * world directory produces an unusable snapshot — and retried on the next tick.
 */
class AutoBackupService {
  private data: Record<string, AutoBackupConfig> = {};
  private loaded = false;
  private timer?: NodeJS.Timeout;
  private busy = new Set<string>();
  private notify?: Notify;

  private load() {
    if (this.loaded) return;
    this.loaded = true;
    try {
      if (!fs.existsSync(FILE())) return;
      const parsed = JSON.parse(fs.readFileSync(FILE(), "utf-8"));
      if (parsed && typeof parsed === "object") this.data = parsed;
    } catch (error: any) {
      logger.warn(`[TUI] Cannot read auto-backup.json: ${error?.message ?? error}`);
    }
  }

  private save() {
    try {
      fs.mkdirsSync(path.dirname(FILE()));
      fs.writeFileSync(FILE(), JSON.stringify(this.data, null, 2), "utf-8");
    } catch (error: any) {
      logger.warn(`[TUI] Cannot write auto-backup.json: ${error?.message ?? error}`);
    }
  }

  get(instanceUuid: string): AutoBackupConfig | undefined {
    this.load();
    return this.data[instanceUuid];
  }

  /** Enable / update the schedule; `intervalHours <= 0` disables it. */
  set(instanceUuid: string, intervalHours: number, keep: number) {
    this.load();
    if (intervalHours <= 0) {
      delete this.data[instanceUuid];
    } else {
      const previous = this.data[instanceUuid];
      this.data[instanceUuid] = {
        intervalHours,
        keep: Math.max(1, Math.floor(keep)),
        lastRun: previous?.lastRun ?? 0
      };
    }
    this.save();
  }

  init(notify: Notify) {
    this.notify = notify;
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), TICK_MS);
    // First pass after startup settles (instances are still loading at init).
    setTimeout(() => void this.tick(), 20_000);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  async tick() {
    this.load();
    for (const [instanceUuid, config] of Object.entries(this.data)) {
      if (!config || config.intervalHours <= 0 || this.busy.has(instanceUuid)) continue;
      if (Date.now() - (config.lastRun ?? 0) < config.intervalHours * 3600_000) continue;
      const instance = instanceService.get(instanceUuid);
      if (!instance) continue;
      if (
        instance.status() === Instance.STATUS_STOPPING ||
        instance.status() === Instance.STATUS_BUSY
      ) {
        continue;
      }
      this.busy.add(instanceUuid);
      config.lastRun = Date.now();
      this.save();
      try {
        // Running servers are flushed first; archiver reads the files right
        // after, which is the same trade-off the web panel makes.
        if (instance.status() === Instance.STATUS_RUNNING) {
          try {
            await instance.execPreset("command", "save-all flush");
          } catch (error) {}
          await new Promise((resolve) => setTimeout(resolve, 2000));
        }
        const entry = await backupService.create(instanceUuid);
        this.prune(instanceUuid, config.keep);
        this.notify?.(`${instance.config.nickname} 定时备份完成：${entry.name}`, "success");
        logger.info(`[TUI] Auto backup finished: ${instanceUuid} ${entry.name}`);
      } catch (error: any) {
        this.notify?.(`${instance.config.nickname} 定时备份失败：${error?.message ?? error}`, "error");
        logger.warn(`[TUI] Auto backup failed: ${instanceUuid} ${error?.message ?? error}`);
      } finally {
        this.busy.delete(instanceUuid);
      }
    }
  }

  /** Delete the oldest archives beyond the configured keep count. */
  private prune(instanceUuid: string, keep: number) {
    const backups = backupService.list(instanceUuid);
    for (const backup of backups.slice(Math.max(1, keep))) {
      try {
        backupService.remove(instanceUuid, backup.name);
      } catch (error) {}
    }
  }
}

export const autoBackupService = new AutoBackupService();

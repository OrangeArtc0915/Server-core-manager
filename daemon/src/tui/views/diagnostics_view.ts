import fs from "fs-extra";
import { promises as fsp } from "fs";
import net from "net";
import os from "os";
import path from "path";
import { systemInfo } from "mcsmanager-common";
import { BaseView, type AppLike } from "../base";
import { c, createFlatList, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { formatBytes } from "../format";
import { t } from "../lang";
import InstanceSubsystem from "../../service/system_instance";
import { javaService } from "../service/java_service";
import { backupService } from "../service/backup_service";
import { opsLog } from "../service/ops_log";
import { PTY_PATH } from "../../const";
import { sevenZipBinaryPath } from "../service/embedded_assets";

type Level = "ok" | "warn" | "bad";

interface CheckRow {
  level: Level;
  name: string;
  value: string;
}

/** Try to connect to a local port: a successful connect means it is in use. */
function portInUse(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let settled = false;
    const finish = (used: boolean) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(used);
    };
    socket.setTimeout(300);
    socket.once("connect", () => finish(true));
    socket.once("timeout", () => finish(false));
    socket.once("error", () => finish(false));
    socket.connect(port, "127.0.0.1");
  });
}

/** Read `server-port` from an instance's server.properties (best effort). */
function instancePort(cwd: string): number | undefined {
  try {
    const file = path.join(cwd, "server.properties");
    if (!fs.existsSync(file)) return undefined;
    const match = /^\s*server-port\s*=\s*(\d+)/m.exec(fs.readFileSync(file, "utf-8"));
    return match ? Number(match[1]) : undefined;
  } catch (error) {
    return undefined;
  }
}

/**
 * Environment self-check: one screen with everything that commonly breaks a
 * Minecraft server (PTY, 7-Zip, Java, disk, memory, ports).
 */
export class DiagnosticsView extends BaseView {
  private list: any;
  private rows: CheckRow[] = [];
  private scanning = false;
  private lastRun = 0;

  constructor(app: AppLike) {
    super(app);
  }

  get title(): string {
    return t("nav.diagnostics");
  }

  get hints(): string {
    return "r 重新检测   c 磁盘清理   Enter 重新检测   Esc 返回";
  }

  protected build() {
    this.page(t("nav.diagnostics"), "", undefined);
    this.list = createFlatList(this.root, 2);
    this.list.on("select", () => void this.run());
    this.main = this.list;
    this.list.focus();
    void this.run();
  }

  onKey(ch: string, key: UiKey) {
    if (ch === "r" || ch === "R") {
      void this.run();
      return;
    }
    if (ch === "c") {
      this.cleanup();
      return;
    }
    if (key.name === "escape") {
      this.app.focusSidebar();
      return;
    }
    BaseView.prototype.onKey.call(this, ch, key);
  }

  /** Recursive size helper (depth-limited, ignores unreadable paths). */
  private dirBytes(target: string, depth = 0): number {
    if (depth > 12) return 0;
    let total = 0;
    try {
      for (const entry of fs.readdirSync(target, { withFileTypes: true })) {
        const child = path.join(target, entry.name);
        if (entry.isDirectory()) total += this.dirBytes(child, depth + 1);
        else {
          try {
            total += fs.statSync(child).size;
          } catch (error) {}
        }
      }
    } catch (error) {}
    return total;
  }

  /** Disk cleanup: instance logs, crash reports and old backups. */
  private cleanup() {
    const options = [
      { label: "实例日志（logs/*.log，保留最新状态无影响）", value: "logs" },
      { label: "实例目录 logs/ 与 crash-reports/", value: "instance" },
      { label: "旧备份（每个实例只保留最近 3 份）", value: "backups" },
      { label: "以上全部清理", value: "all" }
    ];
    this.app.ui.select("磁盘清理", options, (value) => {
      const run = (target: "logs" | "instance" | "backups") => this.runCleanup(target);
      if (value === "all") {
        let freed = 0;
        for (const target of ["logs", "instance", "backups"] as const) freed += this.runCleanup(target, true);
        this.app.message(`清理完成，共释放 ${formatBytes(freed)}`, "success");
        opsLog.add("cleanup", `all ${freed} bytes`, "success");
        return;
      }
      const freed = run(value as any);
      this.app.message(`清理完成，释放 ${formatBytes(freed)}`, "success");
      opsLog.add("cleanup", `${value} ${freed} bytes`, "success");
    });
  }

  private runCleanup(target: "logs" | "instance" | "backups", silent = false): number {
    let freed = 0;
    const removePath = (file: string) => {
      try {
        freed += this.dirBytes(file);
        fs.removeSync(file);
      } catch (error) {}
    };
    try {
      if (target === "logs") {
        const dir = InstanceSubsystem.LOG_DIR;
        if (fs.existsSync(dir)) {
          for (const name of fs.readdirSync(dir)) {
            if (/\.log$/i.test(name)) removePath(path.join(dir, name));
          }
        }
      }
      if (target === "instance") {
        for (const instance of InstanceSubsystem.getInstances()) {
          const cwd = instance.absoluteCwdPath();
          removePath(path.join(cwd, "logs"));
          removePath(path.join(cwd, "crash-reports"));
        }
      }
      if (target === "backups") {
        for (const instance of InstanceSubsystem.getInstances()) {
          const backups = backupService.list(instance.instanceUuid);
          for (const backup of backups.slice(3)) {
            freed += backup.size;
            try {
              backupService.remove(instance.instanceUuid, backup.name);
            } catch (error) {}
          }
        }
      }
    } catch (error: any) {
      if (!silent) this.app.message(`清理出错：${error?.message ?? error}`, "warn");
    }
    return freed;
  }

  onTick() {
    // Port state changes independently of user actions; refresh quietly but not
    // on every tick (each run opens a few sockets).
    if (!this.scanning && Date.now() - this.lastRun > 5000) void this.run();
  }

  private async run() {
    if (this.scanning || this.isDisposed) return;
    this.scanning = true;
    this.lastRun = Date.now();
    try {
      this.rows = await this.collect();
      if (this.isDisposed || !this.list) return;
      const width = this.contentWidth();
      this.list.setItems(
        this.rows.map((row) => {
          const icon =
            row.level === "ok"
              ? c(PAL.green, "✓")
              : row.level === "warn"
              ? c(PAL.yellow, "!")
              : c(PAL.red, "✗");
          const name = padDisplay(row.name, Math.max(12, Math.min(22, Math.floor(width * 0.22))));
          const valueWidth = Math.max(10, width - name.length - 8);
          return `${icon} ${c(PAL.text, name)} ${c(PAL.muted, truncateDisplay(row.value, valueWidth))}`;
        })
      );
      this.app.ui.render();
    } finally {
      this.scanning = false;
    }
  }

  private async collect(): Promise<CheckRow[]> {
    const rows: CheckRow[] = [];
    const info = systemInfo();

    rows.push({
      level: "ok",
      name: "运行平台",
      value: `${os.platform()} ${os.arch()} · Node ${process.version}`
    });

    const columns = Number(this.app.ui.screen.width) || 0;
    const rowsCount = Number(this.app.ui.screen.height) || 0;
    rows.push({
      level: columns >= 80 && rowsCount >= 20 ? "ok" : "warn",
      name: "终端尺寸",
      value: `${columns} x ${rowsCount}${columns >= 80 && rowsCount >= 20 ? "" : "（偏小，建议至少 80x24）"}`
    });

    const ptyOk = fs.existsSync(PTY_PATH) && fs.statSync(PTY_PATH).size > 1024 * 1024;
    rows.push({
      level: ptyOk ? "ok" : "bad",
      name: "PTY 终端",
      value: ptyOk ? `已就绪 · ${path.basename(PTY_PATH)}` : "缺失，实例将退化为普通管道模式"
    });

    const sevenZip = sevenZipBinaryPath();
    rows.push({
      level: sevenZip ? "ok" : "warn",
      name: "7-Zip",
      value: sevenZip ? `已就绪 · ${path.basename(sevenZip)}` : "缺失，仅支持 zip 格式"
    });

    const javas = javaService.list();
    rows.push({
      level: javas.length ? "ok" : "warn",
      name: "Java 运行时",
      value: javas.length
        ? `${javas.length} 个 · ${truncateDisplay(`${javas[0].id} ${javas[0].version ?? ""}`.trim(), 40)}`
        : "未检测到，创建实例前请先在「Java」页安装"
    });

    const instances = InstanceSubsystem.getInstances();
    const running = instances.filter((instance) => instance.status() === 3).length;
    rows.push({
      level: "ok",
      name: "实例",
      value: `${instances.length} 个 · 运行中 ${running}`
    });

    const dataDir = InstanceSubsystem.getInstanceDataDir();
    let writable = false;
    try {
      fs.mkdirsSync(dataDir);
      fs.accessSync(dataDir, fs.constants.W_OK);
      writable = true;
    } catch (error) {
      writable = false;
    }
    rows.push({
      level: writable ? "ok" : "bad",
      name: "数据目录",
      value: `${dataDir}${writable ? "" : "（不可写）"}`
    });

    try {
      const stat = await fsp.statfs(dataDir);
      const free = stat.bavail * stat.bsize;
      const total = stat.blocks * stat.bsize;
      const ratio = total > 0 ? free / total : 0;
      rows.push({
        level: ratio < 0.05 ? "bad" : ratio < 0.15 ? "warn" : "ok",
        name: "磁盘剩余",
        value: `${formatBytes(free)} / ${formatBytes(total)}（${Math.round(ratio * 100)}% 可用）`
      });
    } catch (error) {
      rows.push({ level: "warn", name: "磁盘剩余", value: "无法读取磁盘信息" });
    }

    const memUsed = Math.max(0, info.totalmem - info.freemem);
    const memRatio = info.totalmem > 0 ? memUsed / info.totalmem : 0;
    rows.push({
      level: memRatio > 0.95 ? "bad" : memRatio > 0.85 ? "warn" : "ok",
      name: "内存占用",
      value: `${formatBytes(memUsed)} / ${formatBytes(info.totalmem)}（CPU ${Math.round(info.cpuUsage * 100)}%）`
    });

    for (const instance of instances.slice(0, 8)) {
      const name = instance.config.nickname;
      const cwd = instance.absoluteCwdPath();
      if (!fs.existsSync(cwd)) {
        rows.push({ level: "bad", name: `实例 ${name}`, value: `目录不存在：${cwd}` });
        continue;
      }
      const port = instancePort(cwd);
      if (!port) continue;
      const used = await portInUse(port);
      const isRunning = instance.status() === 3;
      rows.push({
        level: used && !isRunning ? "warn" : "ok",
        name: `实例 ${name}`,
        value: used
          ? `端口 ${port} 已监听${isRunning ? "（本实例运行中）" : "（可能被其他程序占用）"}`
          : `端口 ${port} 空闲`
      });
    }

    return rows;
  }
}

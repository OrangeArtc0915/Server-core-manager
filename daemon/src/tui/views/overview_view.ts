import { promises as fsp } from "fs";
import fs from "fs-extra";
import path from "path";
import Instance from "../../entity/instance/instance";
import { BaseView, type AppLike } from "../base";
import { blessed, c, displayWidth, escapeTags, gauge, PAL, plain, sparkline, truncateDisplay, type UiKey } from "../ui";
import { formatBytes, formatDuration, statusColor, statusText, typeLabel } from "../format";
import { paintLogLine } from "../log_style";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";

interface DiskInfo {
  free: number;
  total: number;
  at: number;
}

/**
 * Instance overview: live CPU / memory curves (sampled every 2s by the
 * instance service), disk usage of the working directory and the tail of the
 * console output including the latest keyword alert.
 */
export class OverviewView extends BaseView {
  private box: any;
  private disk?: DiskInfo;
  private diskBusy = false;
  private lastDiskAt = 0;

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  private get instance(): Instance | undefined {
    return instanceService.get(this.instanceUuid);
  }

  get title(): string {
    return `${t("tab.overview")} · ${this.instance?.config.nickname ?? ""}`;
  }

  get hints(): string {
    return "e 导出 CSV   s/t/r/k 启停重启强杀   c 清除告警   Esc 返回";
  }

  protected build() {
    this.box = blessed.box({
      parent: this.root,
      top: 0,
      left: 0,
      right: 0,
      bottom: 0,
      tags: true,
      scrollable: true,
      alwaysScroll: true,
      keys: true,
      vi: true,
      style: { bg: PAL.bg, fg: PAL.text },
      padding: { left: 2, right: 2 }
    });
    this.main = this.box;
    this.box.focus();
    this.refresh();
  }

  private updateDisk() {
    const instance = this.instance;
    if (!instance || this.diskBusy || Date.now() - this.lastDiskAt < 15_000) return;
    this.diskBusy = true;
    this.lastDiskAt = Date.now();
    fsp
      .statfs(instance.absoluteCwdPath())
      .then((stat) => {
        this.disk = {
          free: stat.bavail * stat.bsize,
          total: stat.blocks * stat.bsize,
          at: Date.now()
        };
      })
      .catch(() => {
        this.disk = undefined;
      })
      .finally(() => {
        this.diskBusy = false;
      });
  }

  refresh() {
    if (!this.box) return;
    const instance = this.instance;
    if (!instance) {
      this.app.message(t("inst.noInstance"), "error");
      this.app.back();
      return;
    }
    this.updateDisk();

    const config = instance.config;
    const status = instance.status();
    const color = statusColor(status);
    const stats = instanceService.getStats(this.instanceUuid);
    const history = instanceService.getHistory(this.instanceUuid);
    const alert = instanceService.getAlert(this.instanceUuid);
    const uptime =
      status === Instance.STATUS_RUNNING && instance.startTimestamp > 0
        ? formatDuration((Date.now() - instance.startTimestamp) / 1000)
        : "-";
    const width = Math.max(30, this.contentWidth(120) - 4);
    const chartWidth = Math.max(16, Math.min(width - 14, 72));

    const lines: string[] = [];
    lines.push(
      `${c(PAL.dim, "实例")} ${c(PAL.bright, escapeTags(config.nickname))}   ` +
        `${c(color, `● ${statusText(status)}`)}   ${c(
        PAL.muted,
        `${typeLabel(config.type)} · 端口 ${config.basePort || "-"} · PID ${instance.process?.pid ?? "-"}`
      )}`
    );
    lines.push(`${c(PAL.dim, "运行时长")} ${c(PAL.text, uptime)}`);
    lines.push("");

    const cpuNow = stats ? Math.round(stats.cpu) : 0;
    const memNow = stats?.memory ?? 0;
    const cpuPeak = history.cpu.length ? Math.round(Math.max(...history.cpu)) : 0;
    const memPeak = history.memory.length ? Math.max(...history.memory) : 0;
    const cpuAvg = history.cpu.length
      ? Math.round(history.cpu.reduce((sum, value) => sum + value, 0) / history.cpu.length)
      : 0;

    lines.push(
      `${c(PAL.dim, "CPU")}  ${c(PAL.yellow, `${cpuNow}%`)}` +
        `${c(PAL.dim, `   峰值 ${cpuPeak}%   平均 ${cpuAvg}%`)}` +
        `${c(PAL.dim, `   ${gauge(Math.min(1, cpuNow / 100), 12, PAL.yellow)}`)}`
    );
    lines.push("  " + c(PAL.yellow, sparkline(history.cpu, chartWidth, Math.max(100, cpuPeak))));
    lines.push(
      `${c(PAL.dim, "内存")} ${c(PAL.cyan, formatBytes(memNow))}` +
        `${c(PAL.dim, `   峰值 ${formatBytes(memPeak)}`)}`
    );
    lines.push("  " + c(PAL.cyan, sparkline(history.memory, chartWidth, Math.max(1, memPeak))));
    lines.push(c(PAL.dim, `最近 ${history.cpu.length} 次采样 · 每 2 秒一次`));
    lines.push("");

    if (this.disk) {
      const used = Math.max(0, this.disk.total - this.disk.free);
      const ratio = this.disk.total > 0 ? used / this.disk.total : 0;
      lines.push(
        `${c(PAL.dim, "磁盘")} ${c(PAL.text, `已用 ${formatBytes(used)} / ${formatBytes(this.disk.total)}`)}` +
          `   ${gauge(ratio, 12, ratio > 0.9 ? PAL.red : PAL.green)} ${c(PAL.muted, `${Math.round(ratio * 100)}%`)}`
      );
    } else {
      lines.push(`${c(PAL.dim, "磁盘")} ${c(PAL.muted, "读取中或不可用")}`);
    }

    const event = config.eventTask;
    lines.push(
      `${c(PAL.dim, "自动重启")} ${c(
        event?.autoRestart ? PAL.green : PAL.muted,
        event?.autoRestart ? "已开启" : "已关闭"
      )}   ${c(PAL.dim, `已触发 ${instance.autoRestartCount} 次 · 上限 ${
        event?.autoRestartMaxTimes === -1 ? "不限" : event?.autoRestartMaxTimes ?? 0
      }`)}`
    );

    if (alert) {
      lines.push(
        `${c(PAL.red, "⚠ 最近异常")} ${c(PAL.dim, new Date(alert.time).toLocaleTimeString())} ` +
          c(PAL.muted, truncateDisplay(escapeTags(alert.line), Math.max(20, width - 24))) +
          c(PAL.dim, `  ×${alert.count}`)
      );
    }
    lines.push("");

    lines.push(c(PAL.dim, "最近输出"));
    const output = instanceService.getLogLines(this.instanceUuid).slice(-10);
    if (!output.length) {
      lines.push(c(PAL.dim, "  （暂无输出）"));
    } else {
      for (const line of output) {
        const plainText = plain(paintLogLine(line));
        if (displayWidth(plainText) > width - 2) {
          lines.push("  " + paintLogLine(truncateDisplay(plainText, width - 3)));
        } else {
          lines.push("  " + paintLogLine(line));
        }
      }
    }

    this.box.setContent(lines.join("\n"));
    this.app.ui.render();
  }

  onTick() {
    this.refresh();
  }

  private async act(action: "start" | "stop" | "restart" | "kill") {
    try {
      await instanceService.act(this.instanceUuid, action);
      this.app.message(t("inst.action.done", { action: t(`inst.action.${action}`) }), "success");
    } catch (error: any) {
      this.app.message(t("inst.action.failed", { err: error?.message ?? error }), "error");
    }
    this.refresh();
  }

  /** Dump the sampled CPU/memory history to data/Exports as CSV. */
  private exportCsv() {
    const instance = this.instance;
    if (!instance) return;
    const history = instanceService.getHistory(this.instanceUuid);
    if (!history.cpu.length) {
      this.app.message("还没有采样数据，请让实例运行一会儿", "warn");
      return;
    }
    try {
      const now = new Date();
      const pad = (n: number) => String(n).padStart(2, "0");
      const safe = instance.config.nickname.replace(/[\\/:*?"<>|]/g, "_");
      const name = `metrics-${safe}-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(
        now.getDate()
      )}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}.csv`;
      const target = path.join(process.cwd(), "data", "Exports", name);
      fs.mkdirsSync(path.dirname(target));
      const rows = ["sample,cpu_percent,memory_bytes"];
      history.cpu.forEach((cpu, index) => {
        rows.push(`${index + 1},${cpu.toFixed(2)},${history.memory[index] ?? 0}`);
      });
      fs.writeFileSync(target, rows.join("\n"), "utf-8");
      this.app.message(`已导出 ${history.cpu.length} 条采样：${target}`, "success");
    } catch (error: any) {
      this.app.message(`导出失败：${error?.message ?? error}`, "error");
    }
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    switch (ch) {
      case "e":
        this.exportCsv();
        return;
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
      case "c":
        instanceService.clearAlert(this.instanceUuid);
        this.app.message("已清除告警", "success");
        this.refresh();
        return;
    }
  }
}

import fs from "fs-extra";
import path from "path";
import { BaseView, type AppLike } from "../base";
import { blessed, c, escapeTags, PAL, stripAnsi, type UiKey } from "../ui";
import { detectLevel, paintLogLine } from "../log_style";
import { formatClock, formatDateTime } from "../format";
import { t } from "../lang";
import { opsLog } from "../service/ops_log";
import { instanceService } from "../service/instance_service";

const LOG_PATH = "logs/current.log";
const MAX_LINES = 3000;

type LogMode = "runtime" | "ops" | "alerts";

/**
 * Log viewer with three sources (daemon runtime log, TUI operation log and the
 * keyword alert history), plus keyword filtering and a "errors only" switch.
 */
export class LogsView extends BaseView {
  private log: any;
  private header: any;
  private mode: LogMode = "runtime";
  private filter = "";
  private errorsOnly = false;
  private playersOnly = false;
  private raw: string[] = [];
  private lastRefresh = 0;

  constructor(app: AppLike) {
    super(app);
  }

  get title(): string {
    return this.mode === "runtime"
      ? t("logs.runtime")
      : this.mode === "ops"
      ? t("logs.operations")
      : "告警记录";
  }

  get hints(): string {
    return "t 切换日志  f 过滤  E 只看异常  P 只看玩家事件  e 导出  PgUp/PgDn 滚动  r 刷新  Esc 返回";
  }

  protected build() {
    this.page(t("logs.runtime"), "", undefined);
    this.header = blessed.box({
      parent: this.root,
      top: 2,
      left: 0,
      right: 0,
      height: 1,
      tags: true,
      style: { bg: PAL.panelAlt, fg: PAL.muted },
      padding: { left: 2, right: 2 }
    });
    this.log = blessed.log({
      parent: this.root,
      top: 3,
      left: 0,
      right: 0,
      bottom: 0,
      tags: true,
      scrollable: true,
      alwaysScroll: true,
      keys: true,
      vi: true,
      mouse: true,
      scrollback: 5000,
      style: { bg: PAL.bg, fg: PAL.text },
      padding: { left: 2, right: 2 }
    });
    this.main = this.log;
    this.log.focus();
    this.load();
  }

  private renderHeader() {
    const chip = (key: LogMode, label: string) =>
      this.mode === key
        ? `{bold}${c(PAL.accent, ` ${label} `)}{/bold}`
        : c(PAL.dim, ` ${label} `);
    const parts = [
      chip("runtime", t("logs.runtime")),
      chip("ops", t("logs.operations")),
      chip("alerts", "告警")
    ];
    if (this.filter) parts.push(c(PAL.cyan, `过滤「${escapeTags(this.filter)}」`));
    if (this.errorsOnly) parts.push(c(PAL.red, "仅异常"));
    if (this.playersOnly) parts.push(c(PAL.green, "仅玩家事件"));
    this.header.setContent(parts.join("   "));
    this.updatePage(this.title, this.sourceLabel());
  }

  private sourceLabel(): string {
    if (this.mode === "runtime") return LOG_PATH;
    if (this.mode === "ops") return "logs/operations.log";
    return `最近 ${this.raw.length} 条关键字告警`;
  }

  /** Lines for the current mode before filtering. */
  private collect(): string[] {
    if (this.mode === "runtime") {
      if (!fs.existsSync(LOG_PATH)) return [];
      try {
        const text = fs.readFileSync(LOG_PATH, "utf-8");
        return text.split("\n").slice(-MAX_LINES).map((line) => stripAnsi(line));
      } catch (error) {
        return [];
      }
    }
    if (this.mode === "ops") {
      return opsLog.getLines().slice(-MAX_LINES).map((line) => stripAnsi(line));
    }
    return instanceService.getAlertHistory().map((alert) => {
      const name = instanceService.get(alert.instanceUuid)?.config.nickname ?? alert.instanceUuid.slice(0, 8);
      return `${formatDateTime(alert.time)} [${name}] ${alert.line}`;
    });
  }

  private applyFilters(lines: string[]): string[] {
    let result = lines;
    if (this.filter) {
      const keyword = this.filter.toLowerCase();
      result = result.filter((line) => line.toLowerCase().includes(keyword));
    }
    if (this.errorsOnly) {
      result = result.filter((line) => detectLevel(line) === "error");
    }
    if (this.playersOnly) {
      result = result.filter((line) =>
        /joined the game|left the game|丢失连接|lost connection|Player .* (joined|left)/i.test(line)
      );
    }
    return result;
  }

  private load() {
    try {
      this.raw = this.collect();
      this.renderHeader();
      const lines = this.applyFilters(this.raw);
      if (!lines.length) {
        this.log.setContent(
          c(PAL.dim, this.raw.length ? "没有匹配的行（f 修改过滤 / E 关闭仅异常）" : t("ops.empty"))
        );
      } else {
        this.log.setContent(lines.map((line) => paintLogLine(line)).join("\n"));
      }
      this.log.setScrollPerc(100);
      this.app.ui.render();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private export() {
    try {
      const lines = this.applyFilters(this.raw);
      const dir = path.join(process.cwd(), "data", "Exports");
      fs.mkdirsSync(dir);
      const stamp = new Date();
      const pad = (n: number) => String(n).padStart(2, "0");
      const name = `log-${this.mode}-${stamp.getFullYear()}${pad(stamp.getMonth() + 1)}${pad(
        stamp.getDate()
      )}-${pad(stamp.getHours())}${pad(stamp.getMinutes())}${pad(stamp.getSeconds())}.txt`;
      const target = path.join(dir, name);
      fs.writeFileSync(target, lines.join("\n"), "utf-8");
      this.app.message(`已导出 ${lines.length} 行到 ${target}`, "success");
      opsLog.add("log export", target, "success");
    } catch (error: any) {
      this.app.message(`导出失败：${error?.message ?? error}`, "error");
    }
  }

  onTick() {
    // Only the alert feed changes on its own; keep it reasonably fresh.
    if (this.mode !== "alerts") return;
    if (Date.now() - this.lastRefresh < 5000) return;
    this.lastRefresh = Date.now();
    this.load();
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.focusSidebar();
      return;
    }
    if (ch === "t") {
      this.mode = this.mode === "runtime" ? "ops" : this.mode === "ops" ? "alerts" : "runtime";
      this.load();
      return;
    }
    if (ch === "f") {
      this.app.ui.prompt({
        title: "日志过滤",
        label: "关键字（留空清除）",
        value: this.filter,
        onSubmit: (value) => {
          this.filter = value.trim();
          this.load();
        }
      });
      return;
    }
    if (ch === "E") {
      this.errorsOnly = !this.errorsOnly;
      this.app.message(this.errorsOnly ? "只显示异常行" : "显示全部日志", "info");
      this.load();
      return;
    }
    if (ch === "P") {
      this.playersOnly = !this.playersOnly;
      this.app.message(this.playersOnly ? "只显示玩家加入/退出事件" : "显示全部日志", "info");
      this.load();
      return;
    }
    if (ch === "e") {
      this.export();
      return;
    }
    if (ch === "r") {
      this.load();
      return;
    }
    if (ch === "c" && this.mode === "alerts") {
      instanceService.clearAlertHistory();
      this.app.message(`告警记录已清空 ${formatClock()}`, "success");
      this.load();
      return;
    }
    if (key.name === "pageup") {
      this.log.scroll(-10);
      this.app.ui.render();
      return;
    }
    if (key.name === "pagedown") {
      this.log.scroll(10);
      this.app.ui.render();
    }
  }
}

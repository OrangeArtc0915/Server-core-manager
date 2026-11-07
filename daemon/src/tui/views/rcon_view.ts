import Rcon from "rcon-srcds";
import Instance from "../../entity/instance/instance";
import { BaseView, type AppLike } from "../base";
import { blessed, c, escapeTags, PAL, truncateDisplay, type UiKey } from "../ui";
import { formatClock } from "../format";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { opsLog } from "../service/ops_log";

interface RconEntry {
  time: string;
  command: string;
  reply: string;
  error: boolean;
}

/**
 * RCON console: sends commands over the RCON protocol instead of the process
 * stdin, which keeps working when the PTY/stdin path is broken.
 */
export class RconView extends BaseView {
  private box: any;
  private body: any;
  private history: RconEntry[] = [];
  private sending = false;

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  private get instance(): Instance | undefined {
    return instanceService.get(this.instanceUuid);
  }

  get title(): string {
    return "RCON 控制台";
  }

  get hints(): string {
    return "Enter/i 发送命令   c 清空   r 刷新   Esc 返回";
  }

  protected build() {
    const name = this.instance?.config.nickname ?? "";
    this.page(name, this.target(), t("inst.title"));
    this.box = blessed.box({
      parent: this.root,
      top: 2,
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

  private target(): string {
    const config = this.instance?.config;
    if (!config) return "未找到实例";
    const host = config.rconIp || "127.0.0.1";
    const port = config.rconPort || "-";
    return config.enableRcon ? `${host}:${port}` : `未启用 RCON（${host}:${port}）`;
  }

  refresh() {
    if (!this.box) return;
    const config = this.instance?.config;
    const lines: string[] = [];
    if (!config) {
      lines.push(c(PAL.red, t("inst.noInstance")));
    } else if (!config.enableRcon) {
      lines.push(c(PAL.yellow, "RCON 未启用，无法发送命令"));
      lines.push(c(PAL.dim, "到「实例 → 配置」开启 enableRcon，并填写 rconPort / rconPassword 后重启服务器"));
    } else if (!config.rconPassword) {
      lines.push(c(PAL.yellow, "RCON 密码为空：请在实例配置里填写 rconPassword"));
    } else {
      lines.push(
        `${c(PAL.dim, "目标")} ${c(PAL.text, `${config.rconIp || "127.0.0.1"}:${config.rconPort}`)}   ` +
          `${c(PAL.dim, "状态")} ${c(PAL.green, "已配置")}`
      );
    }
    lines.push("");
    if (!this.history.length) {
      lines.push(c(PAL.dim, "还没有命令记录，按 Enter 或 i 发送第一条命令"));
    }
    const width = Math.max(20, this.contentWidth(120) - 4);
    for (const entry of this.history) {
      lines.push(`${c(PAL.dim, entry.time)} ${c(PAL.accent, `> ${escapeTags(entry.command)}`)}`);
      const reply = entry.reply.trim() || (entry.error ? "（无输出）" : "（服务器已接受）");
      for (const line of reply.split("\n").slice(0, 20)) {
        lines.push(`  ${c(entry.error ? PAL.red : PAL.muted, escapeTags(truncateDisplay(line, width - 2)))}`);
      }
    }
    this.box.setContent(lines.join("\n"));
    this.box.setScrollPerc(100);
    this.updatePage(this.instance?.config.nickname ?? "", this.target(), t("inst.title"));
    this.app.ui.render();
  }

  onTick() {
    // Only the header can change (config edits happen in another page).
    if (!this.sending) this.updatePage(this.instance?.config.nickname ?? "", this.target(), t("inst.title"));
  }

  private promptCommand() {
    const config = this.instance?.config;
    if (!config || !config.enableRcon || !config.rconPassword) {
      this.app.message("请先在实例配置中启用 RCON 并填写密码", "warn");
      return;
    }
    if (this.sending) return;
    this.app.ui.prompt({
      title: "RCON 命令",
      label: "命令（例如 list / say hello）",
      value: "",
      onSubmit: (value) => {
        const command = value.trim();
        if (!command) return false;
        void this.send(command);
        return true;
      }
    });
  }

  private async send(command: string) {
    const config = this.instance?.config;
    if (!config) return;
    this.sending = true;
    const client = new Rcon({
      host: config.rconIp || "127.0.0.1",
      port: config.rconPort,
      timeout: 5000,
      encoding: "utf8"
    });
    try {
      const authenticated = await client.authenticate(config.rconPassword);
      if (!authenticated && !client.isAuthenticated()) {
        throw new Error("RCON 认证失败：请检查 rconPassword 与服务器 enable-rcon 设置");
      }
      const reply = await client.execute(command);
      this.push({
        time: formatClock(),
        command,
        reply: typeof reply === "string" ? reply : "",
        error: false
      });
      opsLog.add("rcon", `${config.nickname}: ${command}`, "success");
      this.app.message(`RCON 已执行：${command}`, "success");
    } catch (error: any) {
      this.push({
        time: formatClock(),
        command,
        reply: error?.message ?? String(error),
        error: true
      });
      this.app.message(`RCON 失败：${error?.message ?? error}`, "error");
    } finally {
      try {
        await client.disconnect();
      } catch (error) {}
      this.sending = false;
      this.refresh();
    }
  }

  private push(entry: RconEntry) {
    this.history.push(entry);
    if (this.history.length > 50) this.history.splice(0, this.history.length - 50);
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    if (key.name === "enter" || key.name === "return" || ch === "i") {
      this.promptCommand();
      return;
    }
    if (ch === "c") {
      this.history = [];
      this.refresh();
      return;
    }
    if (ch === "r") {
      this.refresh();
    }
  }
}

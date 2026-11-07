import Instance from "../../entity/instance/instance";
import { BaseView, type AppLike } from "../base";
import { blessed, c, escapeTags, PAL, rule, stripAnsi, type UiKey } from "../ui";
import { paintLogLine } from "../log_style";
import { statusText } from "../format";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";

export class TerminalView extends BaseView {
  private log: any;
  private input: any;
  private promptBar: any;
  private promptRule: any;
  private pending = "";
  private partial = "";
  private lastDataAt = 0;
  private flushTimer?: NodeJS.Timeout;
  private unwatch?: () => void;
  private paused = false;
  private editing = false;
  private historyIndex = -1;
  private instanceName = "";

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
    this.instanceName = this.instance?.config.nickname ?? instanceUuid;
  }

  private get instance(): Instance | undefined {
    return instanceService.get(this.instanceUuid);
  }

  get title(): string {
    const status = this.instance ? statusText(this.instance.status()) : t("inst.noInstance");
    return `${this.instanceName} · ${status}`;
  }

  get hints(): string {
    return "i 输入  ↑↓ 历史  PgUp/PgDn 滚动  Ctrl+P 暂停  Ctrl+F 搜索  Ctrl+L 清屏  Esc 返回";
  }

  /** Command input owns typed characters, so global `?` must not open help. */
  get acceptsText(): boolean {
    return this.editing;
  }

  protected build() {
    this.page(this.instanceName, statusText(this.instance?.status() ?? 0), t("inst.title"));
    this.promptRule = blessed.box({
      parent: this.root,
      bottom: 1,
      left: 0,
      right: 0,
      height: 1,
      tags: true,
      style: { bg: PAL.bg, fg: PAL.border },
      padding: { left: 2, right: 2 }
    });
    this.promptRule.setContent(rule(this.contentWidth(80) - 4 || 80));

    this.log = blessed.log({
      parent: this.root,
      top: 2,
      left: 0,
      right: 0,
      bottom: 2,
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

    this.promptBar = blessed.box({
      parent: this.root,
      bottom: 0,
      left: 0,
      right: 0,
      height: 1,
      tags: true,
      style: { bg: PAL.panelAlt, fg: PAL.accent },
      padding: { left: 0, right: 1 }
    });
    this.input = blessed.textbox({
      parent: this.root,
      bottom: 0,
      left: 2,
      right: 0,
      height: 1,
      // Input is read explicitly (i / Enter): with `inputOnFocus` blessed would
      // grab every key as soon as the widget receives focus, which prevents the
      // global shortcut/tab handling.
      inputOnFocus: false,
      keys: true,
      style: { bg: PAL.panelAlt, fg: PAL.bright }
    });

    this.input.on("submit", (value: string) => {
      const command = String(value ?? "").trim();
      this.input.clearValue();
      this.historyIndex = -1;
      if (command) {
        instanceService.addCommand(this.instanceUuid, command);
        void this.send(command);
      }
      this.startEditing();
    });
    this.input.on("cancel", () => {
      this.editing = false;
      this.input.clearValue();
      this.input.hide();
      this.renderPrompt();
      this.app.ui.render();
    });
    this.input.hide();

    const history = instanceService.getLogLines(this.instanceUuid);
    if (history.length) {
      this.log.setContent(
        history
          .slice(-2000)
          .map((line) => paintLogLine(stripAnsi(line)))
          .join("\n")
      );
      this.log.setScrollPerc(100);
    }

    this.unwatch = instanceService.watchOutput((uuid, text) => {
      if (uuid !== this.instanceUuid) return;
      this.pending += text;
      if (!this.paused) this.lastDataAt = Date.now();
    });
    this.flushTimer = setInterval(() => this.flush(), 120);

    this.main = this.log;
    this.renderPrompt();
    this.applyResize();
  }

  private flush() {
    if (this.paused) return;
    const text = this.partial + this.pending;
    if (!text) return;
    this.pending = "";
    const parts = text.split("\n");
    this.partial = parts.pop() ?? "";
    if (parts.length) {
      this.appendLines(parts);
    } else if (this.partial && Date.now() - this.lastDataAt > 800) {
      this.appendLines([this.partial]);
      this.partial = "";
    }
    this.app.ui.render();
  }

  private appendLines(lines: string[]) {
    for (const raw of lines) {
      // Defensive: never let escape/control bytes reach blessed, they would be
      // printed as garbage (this used to happen when a process stopped while
      // emitting a coloured line).
      const plainText = raw.includes("\r") ? raw.slice(raw.lastIndexOf("\r") + 1) : raw;
      const text = stripAnsi(plainText)
        .replace(/\x1b\[[0-9;?]*$/g, "")
        .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "");
      if (!text) continue;
      this.log.log(paintLogLine(text));
    }
    this.log.setScrollPerc(100);
  }

  private renderPrompt() {
    if (this.editing) {
      this.promptBar.setContent(c(PAL.accent, "❯ ") + c(PAL.dim, this.paused ? "⏸ 已暂停" : ""));
      return;
    }
    const suffix = this.paused ? "   ⏸ 已暂停" : "";
    this.promptBar.setContent(c(PAL.accent, "❯ ") + c(PAL.dim, `按 i 输入命令${suffix}`));
  }

  private async send(command: string) {
    try {
      await instanceService.sendCommand(this.instanceUuid, command);
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private applyResize() {
    const width = Number(this.app.ui.screen.width) || 120;
    const height = Number(this.app.ui.screen.height) || 40;
    void instanceService.resize(
      this.instanceUuid,
      Math.max(20, width - 26),
      Math.max(10, height - 10)
    );
  }

  onTick() {
    const instance = this.instance;
    if (!instance) return;
    this.updatePage(
      this.instanceName,
      `${statusText(instance.status())}  ·  PTY ${instance.config.terminalOption.pty ? "on" : "off"}  ·  ${instance.config.basePort || "-"}`,
      t("inst.title")
    );
    this.renderPrompt();
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    if (ch === "i") {
      this.startEditing();
      return;
    }
    if (key.ctrl && key.name === "l") {
      this.log.setContent("");
      instanceService.clearLog(this.instanceUuid);
      this.app.message(t("term.cleared"), "info");
      return;
    }
    if (key.ctrl && key.name === "f") {
      this.search();
      return;
    }
    if (key.ctrl && key.name === "p") {
      this.paused = !this.paused;
      if (!this.paused) this.lastDataAt = Date.now();
      this.app.message(this.paused ? t("term.paused") : t("term.resumed"), this.paused ? "warn" : "info");
      this.renderPrompt();
      return;
    }
    if (key.name === "pageup") {
      this.log.scroll(-Math.max(1, Math.floor(Number(this.log.height) / 2) || 5));
      this.app.ui.render();
      return;
    }
    if (key.name === "pagedown") {
      this.log.scroll(Math.max(1, Math.floor(Number(this.log.height) / 2) || 5));
      this.app.ui.render();
      return;
    }
    if (key.name === "up") {
      this.history(-1);
      return;
    }
    if (key.name === "down") {
      this.history(1);
    }
  }

  private startEditing(prefill?: string) {
    this.editing = true;
    this.input.show();
    if (prefill !== undefined) this.input.setValue(prefill);
    this.input.focus();
    this.input.readInput?.();
    this.renderPrompt();
    this.app.ui.render();
  }

  private history(delta: number) {
    const commands = instanceService.getCommands(this.instanceUuid);
    if (!commands.length) return;
    if (this.historyIndex === -1) this.historyIndex = commands.length;
    this.historyIndex = Math.max(0, Math.min(commands.length, this.historyIndex + delta));
    this.startEditing(this.historyIndex >= commands.length ? "" : commands[this.historyIndex] ?? "");
  }

  private search() {
    this.app.ui.prompt({
      title: t("term.search"),
      value: "",
      onSubmit: (value) => {
        const keyword = value.trim();
        if (!keyword) return;
        const lines = instanceService.getLogLines(this.instanceUuid);
        const matches = lines.filter((line) => line.toLowerCase().includes(keyword.toLowerCase()));
        if (!matches.length) {
          this.app.message(t("term.searchEmpty"), "warn");
          return;
        }
        this.app.message(t("term.searchResult", { n: matches.length }), "info");
        this.app.ui.alert(t("term.search"), matches.slice(-50).map(escapeTags).join("\n"));
      }
    });
  }

  destroy() {
    this.unwatch?.();
    if (this.flushTimer) clearInterval(this.flushTimer);
    this.flush();
    instanceService.get(this.instanceUuid)?.watchers.delete("tui");
    super.destroy();
  }
}

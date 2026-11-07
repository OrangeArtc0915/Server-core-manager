import { systemInfo } from "mcsmanager-common";
import InstanceSubsystem from "../service/system_instance";
import logger from "../service/log";
import type { AppLike, IView, MessageLevel } from "./base";
import { formatBytes, formatClock } from "./format";
import { t } from "./lang";
import { instanceService } from "./service/instance_service";
import { frpcManager } from "./service/frpc_manager";
import javaManager from "../service/java_manager";
import { MenuView } from "./views/menu_view";
import { blessed, c, displayWidth, formatHints, PAL, plain, rule, truncateDisplay, type UiKey } from "./ui";
import { Ui } from "./ui";

export interface SectionDef {
  key: string;
  label: string;
  icon: string;
  desc?: string;
  factory: () => IView;
}

interface AppOptions {
  sections: SectionDef[];
}

/**
 * Application shell with the MCT layout:
 * full-width brand bar, two status lines, a single content area and a footer
 * hint line. There is no sidebar: navigation is menu driven (Esc goes back).
 */
export class App implements AppLike {
  public readonly ui: Ui;
  private readonly sections: SectionDef[];
  private readonly brandBar: any;
  private readonly topRule: any;
  private readonly statsBox: any;
  private readonly messageBar: any;
  private readonly footer: any;
  public readonly content: any;

  private currentView?: IView;
  private activeSection = -1;
  private backStack: (() => IView)[] = [];
  private messageText = "";
  private messageLevel: MessageLevel = "info";
  private tickTimer?: NodeJS.Timeout;
  private lastEnterAt = 0;
  private quitting = false;
  private compact = false;
  private frameOn = false;

  constructor(options: AppOptions) {
    this.sections = options.sections;
    this.ui = new Ui();
    this.ui.messageSink = (text, level) => this.message(text, level);
    const screen = this.ui.screen;

    this.brandBar = blessed.box({
      parent: screen,
      top: 0,
      left: 0,
      right: 0,
      height: 1,
      tags: true,
      style: { bg: PAL.panelAlt, fg: PAL.text },
      padding: { left: 2, right: 2 }
    });

    this.topRule = blessed.box({
      parent: screen,
      top: 1,
      left: 0,
      right: 0,
      height: 1,
      tags: true,
      style: { bg: PAL.bg, fg: PAL.border }
    });

    this.statsBox = blessed.box({
      parent: screen,
      top: 2,
      left: 0,
      right: 0,
      height: 2,
      tags: true,
      style: { bg: PAL.bg, fg: PAL.muted },
      padding: { left: 2, right: 2 }
    });

    this.content = blessed.box({
      parent: screen,
      top: 4,
      left: 0,
      right: 0,
      bottom: 2,
      style: {
        bg: PAL.bg,
        border: { fg: PAL.cyan },
        label: { fg: PAL.bg, bg: PAL.cyan, bold: true }
      }
    });

    this.messageBar = blessed.box({
      parent: screen,
      bottom: 1,
      left: 0,
      right: 0,
      height: 1,
      tags: true,
      style: { bg: PAL.panel, fg: PAL.muted },
      padding: { left: 1, right: 1 }
    });

    this.footer = blessed.box({
      parent: screen,
      bottom: 0,
      left: 0,
      right: 0,
      height: 1,
      tags: true,
      style: { bg: PAL.panelAlt, fg: PAL.muted },
      padding: { left: 1, right: 1 }
    });

    screen.on("keypress", (ch: string, key: UiKey) => this.routeKey(ch, key));
    screen.enableMouse?.(this.content);
    this.content.on("click", (data: any) => this.dispatchMouse(data, "click"));
    this.content.on("wheelup", (data: any) => this.dispatchMouse(data, "wheelup"));
    this.content.on("wheeldown", (data: any) => this.dispatchMouse(data, "wheeldown"));
    screen.on("resize", () => {
      this.applyLayout();
      this.renderBrand();
      this.topRule.setContent(rule(Number(screen.width) || 120));
      this.renderChrome();
      this.ui.render();
    });
    process.on("SIGINT", () => void this.quit());
    process.on("SIGTERM", () => void this.quit());

    this.applyLayout();
    this.renderBrand();
    this.topRule.setContent(rule(Number(screen.width) || 120));
    this.message(t("app.ready"), "info");

    this.tickTimer = setInterval(() => {
      this.renderChrome();
      try {
        this.currentView?.onTick?.();
      } catch (error: any) {
        logger.error(`[TUI] onTick error: ${error?.stack ?? error?.message ?? error}`);
      }
      this.ui.render();
    }, 1000);
  }

  // ------------------------------------------------------------------ header

  /** Small consoles get one status line so the content area keeps enough rows. */
  private applyLayout() {
    const height = Number(this.ui.screen.height) || 24;
    const compact = height < 24;
    if (compact === this.compact) return;
    this.compact = compact;
    this.statsBox.height = compact ? 1 : 2;
    this.content.top = compact ? 3 : 4;
  }

  private renderBrand() {
    const width = Number(this.ui.screen.width) || 120;
    const left = ` ${c(PAL.bright, "CraftDock")}  ${c(PAL.muted, t("app.tagline"))}`;
    const right = `${c(PAL.dim, "v1.0.0")} ${c(PAL.dim, "·")} ${c(PAL.dim, "Designed By")} ${c(
      PAL.accent,
      "mmm"
    )} `;
    const gap = Math.max(1, width - 4 - displayWidth(plain(left)) - displayWidth(plain(right)));
    this.brandBar.setContent(left + " ".repeat(gap) + right);
  }

  // --------------------------------------------------------------- navigation

  home() {
    this.activeSection = -1;
    this.backStack = [];
    this.replaceView(new MenuView(this, this.sections));
  }

  get isHome() {
    return this.activeSection < 0;
  }

  openSection(key: string) {
    const index = this.sections.findIndex((section) => section.key === key);
    if (index >= 0) this.openSectionByIndex(index);
  }

  openSectionByIndex(index: number) {
    const section = this.sections[index];
    if (!section) return;
    this.activeSection = index;
    this.backStack = [];
    this.replaceView(section.factory());
  }

  push(view: IView, backFactory?: () => IView) {
    if (backFactory) this.backStack.push(backFactory);
    this.replaceView(view);
  }

  replace(view: IView) {
    this.backStack = [];
    this.replaceView(view);
  }

  back() {
    const factory = this.backStack.pop();
    if (factory) {
      this.replaceView(factory());
      return;
    }
    if (this.activeSection >= 0) {
      this.openSectionByIndex(this.activeSection);
      return;
    }
    this.home();
  }

  private replaceView(view: IView) {
    const previous = this.currentView;
    this.currentView = undefined;
    previous?.destroy();
    this.currentView = view;
    this.applyFrame(view);
    view.mount(this.content);
    this.renderChrome();
    this.ui.render();
  }

  get view(): IView | undefined {
    return this.currentView;
  }

  /**
   * Section pages (and everything pushed on top of them) are wrapped in a
   * highlighted frame so the user can tell at a glance that the main menu is
   * no longer the active level.
   */
  get framed(): boolean {
    return this.frameOn;
  }

  private applyFrame(view: IView) {
    const on = this.activeSection >= 0;
    const maxTitle = Math.max(8, Math.min(40, (Number(this.ui.screen.width) || 120) - 20));
    if (on) {
      // Sub pages show their parent section so the nesting level is obvious.
      const section = this.sections[this.activeSection];
      const title =
        section && this.backStack.length > 0 ? `${section.label} › ${view.title}` : view.title;
      this.content.setLabel?.(` ┤ ${truncateDisplay(title, maxTitle)} ├ `);
    }
    if (on === this.frameOn) return;
    this.frameOn = on;
    // blessed caches layout coordinates; drop them so the inset body and the
    // frame are recomputed on the next render pass.
    this.content.lpos = null;
    // blessed only fills in the four sides while parsing constructor options,
    // so a border assigned at runtime must list them explicitly.
    this.content.border = on
      ? { type: "line", fg: PAL.cyan, top: true, right: true, bottom: true, left: true }
      : undefined;
    // An empty label would still paint its coloured chip over the menu.
    if (!on) this.content.removeLabel?.();
  }

  // ------------------------------------------------------ AppLike compatibility

  /** Esc from a section returns to the main menu (sidebar equivalent). */
  focusSidebar() {
    this.home();
  }

  rebuildSidebar() {
    if (this.isHome) this.home();
    else this.renderBrand();
  }

  /** Re-apply the active palette to the persistent shell and repaint the page. */
  restyle() {
    const screen = this.ui.screen;
    if (screen.style) screen.style.bg = PAL.bg;
    this.brandBar.style.bg = PAL.panelAlt;
    this.brandBar.style.fg = PAL.text;
    this.topRule.style.bg = PAL.bg;
    this.topRule.style.fg = PAL.border;
    this.statsBox.style.bg = PAL.bg;
    this.statsBox.style.fg = PAL.muted;
    this.content.style.bg = PAL.bg;
    this.content.style.border = { fg: PAL.cyan };
    this.content.style.label = { fg: PAL.bg, bg: PAL.cyan, bold: true };
    this.messageBar.style.bg = PAL.panel;
    this.messageBar.style.fg = PAL.muted;
    this.footer.style.bg = PAL.panelAlt;
    this.footer.style.fg = PAL.muted;

    this.renderBrand();
    this.topRule.setContent(rule(Number(screen.width) || 120));
    // Recreate the active page so every widget is built with the new colors.
    if (this.activeSection >= 0) this.openSectionByIndex(this.activeSection);
    else this.home();
    this.renderChrome();
    this.ui.render();
  }

  // ------------------------------------------------------------------- messaging

  message(text: string, level: MessageLevel = "info") {
    this.messageText = text;
    this.messageLevel = level;
    this.renderChrome();
    this.ui.render();
  }

  error(error: unknown) {
    this.message(error instanceof Error ? error.message : String(error), "error");
  }

  // ----------------------------------------------------------------------- keys

  private routeKey(ch: string, key: UiKey) {
    if (this.quitting) return;
    // blessed reports a single Enter as both "enter" and "return"; without a
    // guard one keypress would activate two menu levels.
    if (key.name === "enter" || key.name === "return") {
      const now = Date.now();
      if (now - this.lastEnterAt < 40) return;
      this.lastEnterAt = now;
    }
    if (this.ui.isModalOpen) {
      this.ui.routeModalKey(ch, key);
      return;
    }
    if (key.name === "C-c") {
      void this.quit();
      return;
    }
    if (ch === "?" && !this.currentView?.acceptsText) {
      this.showHelp();
      return;
    }
    try {
      this.currentView?.onKey?.(ch, key);
    } catch (error: any) {
      logger.error(`[TUI] key handler error: ${error?.stack ?? error?.message ?? error}`);
      this.message(error?.message ?? String(error), "error");
    }
  }

  /** `?` overlay: global keys plus the current page's own shortcuts. */
  private showHelp() {
    const view = this.currentView;
    const body = [
      c(PAL.accent, "全局快捷键"),
      "Ctrl+C  退出程序",
      "Esc     返回上一级 / 主菜单",
      "?       显示本帮助",
      "",
      c(PAL.accent, `当前页面：${view?.title ?? "主菜单"}`),
      view?.hints || "（无）",
      "",
      c(PAL.dim, "底部状态栏也会显示当前页面的常用按键")
    ].join("\n");
    this.ui.alert("快捷键帮助", body);
  }

  // ---------------------------------------------------------------------- mouse

  private dispatchMouse(data: any, action: "click" | "wheelup" | "wheeldown") {
    if (this.quitting || this.ui.isModalOpen) return;
    const pos = this.content?.lpos;
    if (!pos) return;
    // The view body is inset by one cell when the frame is visible.
    const inset = this.frameOn ? 1 : 0;
    const row = Number(data?.y ?? 0) - pos.yi - inset;
    const col = Number(data?.x ?? 0) - pos.xi - inset;
    try {
      this.currentView?.onMouse?.(row, col, action);
    } catch (error: any) {
      logger.error(`[TUI] mouse handler error: ${error?.stack ?? error?.message ?? error}`);
    }
  }

  // --------------------------------------------------------------------- chrome

  private renderChrome() {
    this.renderStatus();
    this.renderMessage();
    this.renderFooter();
  }

  private renderStatus() {
    const info = systemInfo();
    const instances = InstanceSubsystem.getInstances();
    const running = instances.filter((instance) => instance.status() === 3).length;
    const memUsed = Math.max(0, info.totalmem - info.freemem);
    const sep = c(PAL.dim, " · ");
    const width = Number(this.ui.screen.width) || 120;

    const line1Left =
      `${c(PAL.muted, t("common.instance"))} ${c(PAL.bright, instances.length)}` +
      sep +
      `${c(PAL.muted, t("common.running"))} ${c(PAL.green, running)}` +
      (instanceService.getAlertCount()
        ? `${sep}${c(PAL.red, `⚠ ${instanceService.getAlertCount()}`)}`
        : "");
    const downloads = instanceService.getActiveInstalls();
    const line1Right = downloads.length
      ? `${c(PAL.cyan, "↓")} ${c(PAL.cyan, String(downloads.length))}`
      : c(PAL.dim, formatClock());
    const gap1 = Math.max(1, width - 4 - displayWidth(plain(line1Left)) - displayWidth(plain(line1Right)));
    const line1 = line1Left + " ".repeat(gap1) + line1Right;

    const javaCount = javaManager.list().length;
    const line2 =
      `${c(PAL.muted, "CPU")} ${c(PAL.yellow, `${Math.round(info.cpuUsage * 100)}%`)}` +
      sep +
      `${c(PAL.muted, t("common.mem"))} ${c(PAL.yellow, formatBytes(memUsed))}${c(PAL.dim, "/")}${c(
        PAL.muted,
        formatBytes(info.totalmem)
      )}` +
      sep +
      `${c(PAL.muted, t("nav.java"))} ${c(PAL.muted, String(javaCount))}`;

    this.statsBox.setContent(this.compact ? line1 : line1 + "\n" + line2);
  }

  private renderMessage() {
    const color =
      this.messageLevel === "error"
        ? PAL.red
        : this.messageLevel === "success"
        ? PAL.green
        : this.messageLevel === "warn"
        ? PAL.yellow
        : PAL.accent;
    const icon =
      this.messageLevel === "error"
        ? "✗"
        : this.messageLevel === "success"
        ? "✓"
        : this.messageLevel === "warn"
        ? "!"
        : "›";
    const text = this.messageText || t("app.ready");
    this.messageBar.setContent(` ${c(color, icon)} ${c(PAL.muted, text)}`);
  }

  private renderFooter() {
    const hints = this.currentView?.hints ?? "";
    this.footer.setContent(` ${formatHints(hints)} `);
  }

  quit() {
    if (this.quitting) return;
    this.ui.confirm(t("app.title"), t("app.quit"), () => void this.doQuit());
  }

  private async doQuit() {
    if (this.quitting) return;
    this.quitting = true;
    if (this.tickTimer) clearInterval(this.tickTimer);
    frpcManager.stopAll();
    const close = this.ui.busy(t("app.quitting"));
    try {
      await InstanceSubsystem.exit(false);
    } catch (error: any) {
      logger.error(`[TUI] Failed to stop instances: ${error?.message ?? error}`);
    }
    close();
    this.ui.destroy();
    process.exit(0);
  }
}

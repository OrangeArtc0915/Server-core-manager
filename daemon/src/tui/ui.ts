import blessedImpl from "blessed";
import { t } from "./lang";
import { applyTerminfo } from "./prepare_terminfo";

// Must run after blessed is loaded (patches Tput.ipaths) and before the screen
// is created - the single-file executable carries no `usr/` terminfo directory.
applyTerminfo();

// The bundled @types/blessed typings do not model hex colors, `style.label`
// or several option combinations used by the TUI. Expose the library as `any`
// so widget options stay readable instead of being littered with casts.
const blessed: any = blessedImpl;

// blessed seeds its hex-color cache while its 8-color fallback table is active,
// which poisons every hex value that exactly matches an xterm palette entry
// (they would resolve to colors 0-7). Clearing the cache after load makes hex
// tags and styles resolve against the full 256-color palette.
try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const blessedColors = require("blessed/lib/colors");
  blessedColors._cache = {};
} catch (error) {}

/** Dark palette used across the TUI (re-exported from theme for convenience). */
import { PAL } from "./theme";
export { PAL };

export interface UiKey {
  name?: string;
  ctrl?: boolean;
  meta?: boolean;
  shift?: boolean;
  full?: string;
}

type AnyElement = any;

/** Colored text using blessed tags. */
export function c(color: string, text: string | number): string {
  return `{${color}-fg}${text}{/}`;
}

const CIRCLED = "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳";

/** MCT-style menu marker: circled number for 1-20, plain number otherwise. */
export function menuNumber(index: number): string {
  return index < CIRCLED.length ? CIRCLED[index] : `${index + 1}.`;
}

export function bold(text: string | number): string {
  return `{bold}${text}{/bold}`;
}

/** Visible width of a string, CJK-aware (terminal cells). */
export function displayWidth(text: string): number {
  let width = 0;
  for (const ch of text) {
    const code = ch.codePointAt(0) ?? 0;
    if (code === 0) continue;
    if (
      (code >= 0x1100 && code <= 0x115f) ||
      (code >= 0x2e80 && code <= 0x303e) ||
      (code >= 0x3041 && code <= 0x33ff) ||
      (code >= 0x3400 && code <= 0x4dbf) ||
      (code >= 0x4e00 && code <= 0x9fff) ||
      (code >= 0xa000 && code <= 0xa4cf) ||
      (code >= 0xa960 && code <= 0xa97f) ||
      (code >= 0xac00 && code <= 0xd7a3) ||
      (code >= 0xf900 && code <= 0xfaff) ||
      (code >= 0xfe10 && code <= 0xfe19) ||
      (code >= 0xfe30 && code <= 0xfe6f) ||
      (code >= 0xff00 && code <= 0xff60) ||
      (code >= 0xffe0 && code <= 0xffe6) ||
      (code >= 0x1f300 && code <= 0x1f64f) ||
      (code >= 0x1f900 && code <= 0x1f9ff) ||
      (code >= 0x20000 && code <= 0x3fffd)
    ) {
      width += 2;
    } else {
      width += 1;
    }
  }
  return width;
}

export function padDisplay(text: string, width: number): string {
  // Tagged strings ({color-fg}...{/}) must be measured by their visible width,
  // otherwise columns shift by the length of the markup.
  const w = displayWidth(plain(text));
  return w >= width ? text : text + " ".repeat(width - w);
}

export function truncateDisplay(text: string, width: number): string {
  if (displayWidth(text) <= width) return text;
  let out = "";
  let used = 0;
  for (const ch of text) {
    const cw = displayWidth(ch);
    if (used + cw > width - 1) break;
    out += ch;
    used += cw;
  }
  return out + "…";
}

/** Remove ANSI/VT escape sequences so they do not break the TUI renderer. */
export function stripAnsi(text: string): string {
  return text
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b[@-Z\\-_]/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}

/** Escape braces so user content is not parsed as blessed tags. */
export function escapeTags(text: string): string {
  return String(text ?? "").replace(/[{}]/g, (ch) => (ch === "{" ? "{open}" : "{close}"));
}

/** Plain text of a tagged string. */
export function plain(text: string): string {
  return text.replace(/\{[^}]*\}/g, "");
}

/** Sparkline: values -> block characters. */
export function sparkline(values: number[], width: number, maxValue?: number): string {
  const blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"];
  if (!values.length) return c(PAL.dim, "-".repeat(width));
  const slice = values.slice(-width);
  let max = maxValue ?? Math.max(...slice, 1);
  if (!Number.isFinite(max) || max <= 0) max = 1;
  let out = "";
  for (const value of slice) {
    const ratio = Math.max(0, Math.min(1, value / max));
    out += blocks[Math.min(blocks.length - 1, Math.floor(ratio * blocks.length))];
  }
  return out + " ".repeat(Math.max(0, width - slice.length));
}

/** Horizontal rule. */
export function rule(width: number): string {
  return c(PAL.border, "─".repeat(Math.max(1, width)));
}

/** A small "gauge" bar, e.g. CPU usage. */
export function gauge(value: number, width: number, color = PAL.accent): string {
  const ratio = Math.max(0, Math.min(1, value));
  const filled = Math.round(ratio * width);
  return c(color, "█".repeat(filled)) + c(PAL.border, "░".repeat(Math.max(0, width - filled)));
}

/** Format view hints like "s 启动  t 停止" into colored key chips. */
export function formatHints(hints: string): string {
  return hints
    .split(/\s{2,}/)
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const match = /^(\S+)\s+(.*)$/.exec(part);
      if (!match) return c(PAL.accent, part);
      return c(PAL.accent, match[1]) + " " + c(PAL.muted, match[2]);
    })
    .join(c(PAL.border, "  ·  "));
}

export interface PageHeader {
  header: any;
  ruleBox: any;
  bodyTop: number;
}

/** Borderless, full-width list used by the flat page layout. */
export function createFlatList(parent: any, top: number): any {
  return blessed.list({
    parent,
    top,
    left: 0,
    right: 0,
    bottom: 0,
    tags: true,
    keys: true,
    vi: true,
    mouse: true,
    scrollable: true,
    alwaysScroll: true,
    scrollbar: { ch: " ", style: { bg: PAL.accent } },
    style: {
      bg: PAL.bg,
      fg: PAL.text,
      selected: { bg: PAL.selectBg, fg: PAL.selectFg }
    },
    padding: { left: 2, right: 2 }
  });
}

export function headerLine(
  width: number,
  options: { title: string; meta?: string; breadcrumb?: string }
): string {
  const breadcrumb = options.breadcrumb ? c(PAL.dim, options.breadcrumb + "  ›  ") : "";
  const title = breadcrumb + c(PAL.bright, options.title);
  const meta = options.meta ? c(PAL.muted, options.meta) : "";
  const gap = Math.max(1, width - displayWidth(plain(title)) - displayWidth(plain(meta)) - 4);
  return title + " ".repeat(gap) + meta;
}

/** Standard flat page header: title + meta on one line and a rule below. */
export function createPageHeader(
  parent: any,
  options: { title: string; meta?: string; breadcrumb?: string }
): PageHeader {
  const screenWidth = Number(parent.width) || Number((parent.screen as any)?.width) || 120;
  const width = Math.max(20, screenWidth);
  const header = blessed.box({
    parent,
    top: 0,
    left: 0,
    right: 0,
    height: 1,
    tags: true,
    style: { bg: PAL.bg, fg: PAL.text },
    padding: { left: 2, right: 2 }
  });
  header.setContent(headerLine(width - 4, options));

  const ruleBox = blessed.box({
    parent,
    top: 1,
    left: 0,
    right: 0,
    height: 1,
    tags: true,
    style: { bg: PAL.bg, fg: PAL.border },
    padding: { left: 2, right: 2 }
  });
  ruleBox.setContent(rule(width - 4));
  return { header, ruleBox, bodyTop: 2 };
}

export interface PromptOptions {
  title: string;
  label?: string;
  value?: string;
  secret?: boolean;
  hint?: string;
  onSubmit: (value: string) => void | boolean;
  onCancel?: () => void;
}

export interface FormField {
  key: string;
  label: string;
  value: string;
  secret?: boolean;
  hint?: string;
}

export interface FormOptions {
  title: string;
  fields: FormField[];
  hint?: string;
  onSubmit: (values: Record<string, string>) => void | boolean | string;
  onCancel?: () => void;
}

interface ModalHandle {
  box: AnyElement;
  onKey?: (ch: string, key: UiKey) => boolean | void;
  close: () => void;
}

export class Ui {
  public readonly screen: AnyElement;
  public messageSink?: (text: string, level: "info" | "error" | "success" | "warn") => void;
  private modalStack: ModalHandle[] = [];

  constructor() {
    this.screen = blessed.screen({
      smartCSR: true,
      fullUnicode: true,
      forceUnicode: true,
      // PowerShell/cmd on Windows does not export $TERM; force the 256-color
      // terminfo so the dark palette renders consistently.
      terminal: "xterm-256color",
      dockBorders: true,
      autoPadding: false,
      title: "CraftDock · mmm",
      warnings: false
    });
  }

  get isModalOpen(): boolean {
    return this.modalStack.length > 0;
  }

  render() {
    try {
      this.screen.render();
    } catch (error) {
      // Rendering must never crash the app.
    }
  }

  notify(message: string, level: "info" | "error" | "success" | "warn" = "info") {
    const text = String(message ?? "").replace(/\n/g, " ");
    if (this.messageSink) {
      this.messageSink(text, level);
      return;
    }
  }

  error(error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    this.notify(message, "error");
  }

  getThemeBorder(focused = false) {
    return { type: "line" as const, fg: focused ? PAL.borderFocus : PAL.border };
  }

  panelStyle(focused = false) {
    return {
      bg: PAL.panel,
      fg: PAL.text,
      border: this.getThemeBorder(focused),
      label: { fg: PAL.accent }
    };
  }

  /**
   * Shared chrome for modal windows: a bright border, an inverted title chip
   * and a drop shadow so dialogs clearly float above the page frame.
   *
   * blessed runs with `autoPadding` disabled, so child widgets do NOT inset
   * themselves for the border or padding. Callers must place children at
   * `MODAL_PAD` / `MODAL_PAD + 1` explicitly.
   */
  modalFrame(title?: string, accent = PAL.accent) {
    const options: AnyElement = {
      border: { type: "line", fg: accent },
      shadow: true,
      style: {
        bg: PAL.panelAlt,
        fg: PAL.text,
        border: { fg: accent },
        label: { fg: PAL.bg, bg: accent, bold: true }
      }
    };
    if (title) options.label = ` ${title} `;
    return options;
  }

  listStyle() {
    return {
      bg: PAL.panel,
      fg: PAL.text,
      border: this.getThemeBorder(false),
      label: { fg: PAL.accent },
      selected: { bg: PAL.selectBg, fg: PAL.selectFg, bold: true }
    };
  }

  /** Blocking-looking overlay; returns a function to close it. */
  busy(text = t("common.loading")): () => void {
    const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    let i = 0;
    const box = blessed.box({
      parent: this.screen,
      top: "center",
      left: "center",
      width: Math.min(60, Math.max(30, displayWidth(text) + 12)),
      height: 3,
      ...this.modalFrame(),
      tags: true
    });
    const timer = setInterval(() => {
      box.setContent(` ${c(PAL.accent, frames[i++ % frames.length])} ${text}`);
      this.render();
    }, 90);
    const closed = { value: false };
    const handle: ModalHandle = { box, close: () => {} };
    const close = () => {
      if (closed.value) return;
      closed.value = true;
      clearInterval(timer);
      const index = this.modalStack.indexOf(handle);
      if (index >= 0) this.modalStack.splice(index, 1);
      try {
        box.destroy();
      } catch (error) {}
      this.render();
    };
    handle.close = close;
    this.modalStack.push(handle);
    this.render();
    return close;
  }

  async withBusy<T>(text: string, fn: () => Promise<T>): Promise<T> {
    const close = this.busy(text);
    try {
      return await fn();
    } finally {
      close();
    }
  }

  /**
   * Non-blocking activity indicator in the bottom-right corner, using the same
   * spinner as the quit overlay. Keys keep working, so background downloads can
   * show live progress without interrupting the user.
   */
  activity(text = t("common.loading")) {
    const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    let frame = 0;
    let label = text;
    let percent: number | undefined;
    const width = Math.min(52, Math.max(34, (Number(this.screen.width) || 120) - 6));
    const box = blessed.box({
      parent: this.screen,
      bottom: 2,
      right: 2,
      width,
      height: 3,
      ...this.modalFrame(),
      tags: true,
      padding: { left: 1, right: 1 }
    });
    const draw = () => {
      const spinner = c(PAL.accent, frames[frame++ % frames.length]);
      if (percent === undefined) {
        box.setContent(`${spinner} ${c(PAL.text, label)}`);
        return;
      }
      const barWidth = Math.max(8, width - 12 - displayWidth(label));
      const filled = Math.round((Math.min(100, Math.max(0, percent)) / 100) * barWidth);
      const bar = c(PAL.accent, "█".repeat(filled)) + c(PAL.dim, "░".repeat(barWidth - filled));
      box.setContent(`${spinner} ${c(PAL.text, label)} ${bar} ${c(PAL.bright, `${Math.round(percent)}%`)}`);
    };
    draw();
    this.render();
    const timer = setInterval(() => {
      draw();
      this.render();
    }, 100);
    let closed = false;
    return {
      update: (nextText: string, nextPercent?: number) => {
        if (closed) return;
        label = nextText;
        percent = nextPercent;
        draw();
        this.render();
      },
      close: () => {
        if (closed) return;
        closed = true;
        clearInterval(timer);
        try {
          box.destroy();
        } catch (error) {}
        this.render();
      }
    };
  }

  alert(title: string, message: string, onClose?: () => void) {
    const width = Math.min(92, Math.max(46, (this.screen.width as number) - 8));
    const lines = message.split("\n");
    const height = Math.min((this.screen.height as number) - 3, lines.length + 6);
    const box = blessed.box({
      parent: this.screen,
      top: "center",
      left: "center",
      width,
      height,
      ...this.modalFrame(title),
      tags: true,
      padding: { left: 1, right: 1 },
      scrollable: true,
      alwaysScroll: true,
      keys: true,
      vi: true,
      content: message
    });
    blessed.box({
      parent: box,
      bottom: 1,
      left: 2,
      right: 2,
      height: 1,
      tags: true,
      content: c(PAL.dim, t("common.ok") + " (Enter / Esc)")
    });
    this.pushModal(box, (_ch, key) => {
      if (key.name === "escape" || key.name === "enter" || key.name === "return") {
        this.popModal();
        onClose?.();
      }
      return true;
    });
    box.focus?.();
    this.render();
  }

  confirm(title: string, message: string, onConfirm: () => void, onCancel?: () => void) {
    const width = Math.min(92, Math.max(46, (this.screen.width as number) - 8));
    const box = blessed.box({
      parent: this.screen,
      top: "center",
      left: "center",
      width,
      height: Math.min((this.screen.height as number) - 3, message.split("\n").length + 6),
      ...this.modalFrame(title, PAL.yellow),
      tags: true,
      padding: { left: 1, right: 1 },
      content: `${message}\n\n${c(PAL.muted, `${t("common.yes")} (y/Enter)   ${t("common.no")} (n/Esc)`)}`
    });
    this.pushModal(box, (ch, key) => {
      if (key.name === "escape" || ch === "n" || ch === "N") {
        this.popModal();
        onCancel?.();
        return true;
      }
      if (ch === "y" || ch === "Y" || key.name === "enter" || key.name === "return") {
        this.popModal();
        onConfirm();
        return true;
      }
      return true;
    });
    this.render();
  }

  prompt(options: PromptOptions) {
    const width = Math.min(96, Math.max(50, (this.screen.width as number) - 8));
    const box = blessed.box({
      parent: this.screen,
      top: "center",
      left: "center",
      width,
      height: 8,
      ...this.modalFrame(options.title),
      padding: { left: 1, right: 1 }
    });
    blessed.box({
      parent: box,
      top: 1,
      left: 2,
      right: 2,
      height: 2,
      tags: true,
      content: options.label ?? ""
    });
    const input: AnyElement = blessed.textbox({
      parent: box,
      top: 3,
      left: 2,
      right: 2,
      height: 1,
      value: options.value ?? "",
      secret: options.secret,
      inputOnFocus: true,
      keys: true,
      style: { bg: PAL.bg, fg: PAL.bright, focus: { bg: PAL.selectBg, fg: PAL.selectFg } }
    });
    const hint = blessed.box({
      parent: box,
      top: 5,
      left: 2,
      right: 2,
      height: 2,
      tags: true,
      content: `\n${c(PAL.dim, `${options.hint ?? ""}  Enter 确认   Esc 取消`)}`
    });

    let finished = { value: false };
    const handle = this.pushModal(box, (_ch, key) => {
      if (key.name === "escape") {
        if (finished.value) return true;
        finished.value = true;
        this.closeModal(handle);
        options.onCancel?.();
      }
      return true;
    });
    const submit = () => {
      if (finished.value) return;
      const value = input.getValue();
      const result = options.onSubmit(value);
      if (result === false) {
        hint.setContent(`\n${c(PAL.red, t("common.invalidInput"))}`);
        this.render();
        input.focus();
        return;
      }
      finished.value = true;
      this.closeModal(handle);
    };
    input.on("submit", submit);
    input.on("cancel", () => {
      if (finished.value) return;
      finished.value = true;
      this.closeModal(handle);
      options.onCancel?.();
    });
    input.focus();
    this.render();
  }

  form(options: FormOptions) {
    const width = Math.min(100, Math.max(56, (this.screen.width as number) - 8));
    // Two rows per field keeps six-field forms usable on a ~23 row terminal.
    const height = Math.min((this.screen.height as number) - 3, options.fields.length * 2 + 4);
    const box = blessed.box({
      parent: this.screen,
      top: "center",
      left: "center",
      width,
      height,
      ...this.modalFrame(options.title),
      padding: { left: 1, right: 1 }
    });

    let finished = { value: false };
    const inputs: AnyElement[] = [];
    options.fields.forEach((field, index) => {
      blessed.box({
        parent: box,
        top: index * 2 + 1,
        left: 2,
        right: 2,
        height: 1,
        tags: true,
        content: c(PAL.muted, field.label) + (field.hint ? "  " + c(PAL.dim, field.hint) : "")
      });
      const input: AnyElement = blessed.textbox({
        parent: box,
        top: index * 2 + 2,
        left: 2,
        right: 2,
        height: 1,
        value: field.value ?? "",
        secret: field.secret,
        inputOnFocus: true,
        keys: true,
        style: { bg: PAL.bg, fg: PAL.bright, focus: { bg: PAL.selectBg, fg: PAL.selectFg } }
      });
      input.on("submit", () => {
        if (finished.value) return;
        if (index < inputs.length - 1) {
          inputs[index + 1].focus();
          this.render();
        } else {
          submit();
        }
      });
      inputs.push(input);
    });

    blessed.box({
      parent: box,
      bottom: 1,
      left: 2,
      right: 2,
      height: 1,
      tags: true,
      content: c(PAL.dim, `${options.hint ?? ""}  Tab 下一项   Enter 下一项/提交   Esc 取消`)
    });

    const submit = () => {
      if (finished.value) return;
      const values: Record<string, string> = {};
      options.fields.forEach((field, index) => (values[field.key] = inputs[index].getValue()));
      const result = options.onSubmit(values);
      if (typeof result === "string") {
        this.notify(result, "error");
        return;
      }
      if (result === false) return;
      finished.value = true;
      this.closeModal(handle);
    };

    const handle = this.pushModal(box, (_ch, key) => {
      if (key.name === "escape") {
        if (finished.value) return true;
        finished.value = true;
        this.closeModal(handle);
        options.onCancel?.();
        return true;
      }
      const focusedIndex = inputs.findIndex((input) => input === this.screen.focused);
      if (key.name === "tab" || key.name === "down") {
        const target =
          ((key.shift ? focusedIndex - 1 : focusedIndex + 1) + inputs.length) % inputs.length;
        inputs[target].focus();
        this.render();
        return true;
      }
      if (key.name === "S-tab" || key.name === "up") {
        const target = (focusedIndex - 1 + inputs.length) % inputs.length;
        inputs[target].focus();
        this.render();
        return true;
      }
      return true;
    });
    if (inputs.length) inputs[0].focus();
    this.render();
  }

  select<T>(
    title: string,
    items: { label: string; value: T }[],
    onSelect: (value: T) => void,
    onCancel?: () => void,
    searchable = true
  ) {
    if (!items.length) {
      this.notify(t("common.empty"), "info");
      return;
    }
    const width = Math.min(100, Math.max(52, (this.screen.width as number) - 8));
    const height = Math.min((this.screen.height as number) - 3, items.length + 6);
    const box = blessed.box({
      parent: this.screen,
      top: "center",
      left: "center",
      width,
      height,
      ...this.modalFrame(title)
    });
    const list: AnyElement = blessed.list({
      parent: box,
      top: 1,
      left: 1,
      right: 1,
      bottom: 2,
      items: items.map((item) => item.label),
      tags: true,
      keys: true,
      vi: true,
      mouse: true,
      searchable,
      style: {
        bg: PAL.panel,
        fg: PAL.text,
        selected: { bg: PAL.selectBg, fg: PAL.selectFg, bold: true }
      }
    });
    blessed.box({
      parent: box,
      bottom: 1,
      left: 2,
      right: 2,
      height: 1,
      tags: true,
      content: c(PAL.dim, `Enter 选择   Esc 取消${searchable ? "   输入关键字可过滤" : ""}`)
    });
    list.on("select", (_item: unknown, index: number) => {
      const value = items[index].value;
      this.popModal();
      onSelect(value);
    });
    this.pushModal(box, (_ch, key) => {
      if (key.name === "escape") {
        this.popModal();
        onCancel?.();
        return true;
      }
      return false;
    });
    list.focus();
    this.render();
  }

  private pushModal(box: AnyElement, onKey?: (ch: string, key: UiKey) => boolean | void): ModalHandle {
    this.screen.saveFocus?.();
    const handle: ModalHandle = {
      box,
      onKey,
      close: () => {
        try {
          box.destroy();
        } catch (error) {}
        this.render();
      }
    };
    this.modalStack.push(handle);
    box.setFront?.();
    return handle;
  }

  /**
   * Remove a specific modal instead of the top-most one. Callbacks such as
   * `onSubmit` may open another modal (e.g. a busy overlay) before the caller
   * closes itself; removing by handle keeps the stack consistent.
   */
  private closeModal(handle: ModalHandle) {
    const index = this.modalStack.indexOf(handle);
    if (index < 0) return;
    this.modalStack.splice(index, 1);
    try {
      handle.box.destroy();
    } catch (error) {}
    this.screen.restoreFocus?.();
    const top = this.modalStack[this.modalStack.length - 1];
    top?.box.setFront?.();
    this.render();
  }

  popModal() {
    const handle = this.modalStack.pop();
    if (!handle) return;
    try {
      handle.box.destroy();
    } catch (error) {}
    this.screen.restoreFocus?.();
    const top = this.modalStack[this.modalStack.length - 1];
    top?.box.setFront?.();
    this.render();
  }

  routeModalKey(ch: string, key: UiKey): boolean {
    const top = this.modalStack[this.modalStack.length - 1];
    if (!top) return false;
    if (!top.onKey) return true;
    return top.onKey(ch, key) !== false;
  }

  destroy() {
    try {
      this.screen.destroy();
    } catch (error) {}
  }
}

export { blessed };

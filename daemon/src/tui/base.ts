import { blessed, createPageHeader, headerLine, PAL, type PageHeader, type UiKey } from "./ui";
import type { Ui } from "./ui";

export interface IView {
  readonly title: string;
  readonly hints: string;
  /** True while the page itself consumes typed characters (editor insert mode,
   *  terminal input). Global single-character shortcuts must not steal keys. */
  readonly acceptsText?: boolean;
  mount(parent: unknown): void;
  focusMain?(): void;
  onKey?(ch: string, key: UiKey): void;
  onMouse?(row: number, col: number, action: "click" | "wheelup" | "wheeldown"): void;
  onTick?(): void;
  destroy(): void;
}

export type MessageLevel = "info" | "error" | "success" | "warn";

export interface AppLike {
  ui: Ui;
  /** True while a section page (or one of its sub pages) is shown, i.e. the
   *  content area is wrapped in the highlighted window frame. */
  readonly framed: boolean;
  push(view: IView, backFactory?: () => IView): void;
  back(): void;
  replace(view: IView): void;
  openSection(key: string): void;
  rebuildSidebar(): void;
  message(text: string, level?: MessageLevel): void;
  /** Re-apply the active palette to the shell and repaint the current page. */
  restyle(): void;
  focusSidebar(): void;
  quit(): void;
}

export abstract class BaseView implements IView {
  public root: any;
  protected main: any;
  protected pageHeader?: PageHeader;
  private disposed = false;

  constructor(public readonly app: AppLike) {}

  abstract get title(): string;
  abstract get hints(): string;
  protected abstract build(): void;

  mount(parent: unknown) {
    // The app draws a highlighted frame around section pages. blessed runs
    // with autoPadding disabled, so the view body must inset itself by one
    // cell; otherwise it would paint over the frame.
    const inset = this.app.framed ? 1 : 0;
    this.root = blessed.box({
      parent: parent as any,
      top: inset,
      left: inset,
      right: inset,
      bottom: inset,
      style: { bg: PAL.bg }
    });
    this.build();
  }

  focusMain() {
    this.main?.focus?.();
  }

  /** Draw the standard flat page header. Returns the Y offset for the body. */
  protected page(title: string, meta?: string, breadcrumb?: string): number {
    this.pageHeader = createPageHeader(this.root, { title, meta, breadcrumb });
    return 2;
  }

  /** Update the page header title/meta without recreating it. */
  protected updatePage(title: string, meta?: string, breadcrumb?: string) {
    if (!this.pageHeader || this.disposed || !this.root) return;
    this.pageHeader.header.setContent(headerLine(this.contentWidth() - 4, { title, meta, breadcrumb }));
  }

  /**
   * Usable width of the view body.
   *
   * Reading `.width` on a blessed node whose parent is already gone throws
   * "Cannot read properties of null (reading 'width')", so late async callbacks
   * (timers, download progress) must go through this guard.
   */
  protected contentWidth(fallback = 100): number {
    const screenWidth = Number(this.app.ui.screen.width) || fallback;
    try {
      if (this.disposed || !this.root || !this.root.parent) return screenWidth - 2;
      return Number(this.root.width) || screenWidth - 2;
    } catch (error) {
      return screenWidth - 2;
    }
  }

  /** Destroy-safe counterpart of {@link contentWidth} for vertical layout. */
  protected contentHeight(fallback = 20): number {
    const screenHeight = Number(this.app.ui.screen.height) || 24;
    try {
      if (this.disposed || !this.root || !this.root.parent) return screenHeight - 6;
      return Number(this.root.height) || fallback;
    } catch (error) {
      return fallback;
    }
  }

  onKey(_ch: string, _key: UiKey) {}

  onTick() {}

  destroy() {
    if (this.disposed) return;
    this.disposed = true;
    try {
      this.root?.destroy();
    } catch (error) {}
  }

  get isDisposed() {
    return this.disposed;
  }
}

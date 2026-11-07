import Instance from "../../entity/instance/instance";
import { BaseView, type AppLike } from "../base";
import { blessed, c, displayWidth, escapeTags, menuNumber, PAL, truncateDisplay, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import javaManager from "../../service/java_manager";
import type { SectionDef } from "../app";

interface MenuItem {
  label: string;
  desc: string;
  run: () => void;
}

/**
 * Main menu in the MCT layout: a single list of numbered entries with a short
 * description on the right, navigated with the arrow keys.
 */
export class MenuView extends BaseView {
  private box: any;
  private cursor = 0;
  private offset = 0;

  constructor(app: AppLike, private readonly sections: SectionDef[]) {
    super(app);
  }

  get title(): string {
    return t("menu.title");
  }

  get hints(): string {
    return "↑↓ 选择   Enter 确认   Esc 返回";
  }

  protected build() {
    this.box = blessed.box({
      parent: this.root,
      top: 0,
      left: 0,
      right: 0,
      bottom: 0,
      tags: true,
      style: { bg: PAL.bg, fg: PAL.text },
      padding: { left: 2, right: 2 }
    });
    this.main = this.box;
    this.refresh();
  }

  private items(): MenuItem[] {
    const instances = instanceService.list();
    const running = instances.filter((instance) => instance.status() === Instance.STATUS_RUNNING).length;
    const result: MenuItem[] = this.sections.map((section) => {
      let desc = section.desc ?? "";
      if (section.key === "instances") desc = `${instances.length} 个实例 · 运行 ${running}`;
      if (section.key === "java") desc = `${javaManager.list().length} 个运行时`;
      return {
        label: section.label,
        desc,
        run: () => this.app.openSection(section.key)
      };
    });
    result.push({
      label: t("menu.quit"),
      desc: "Ctrl+C",
      run: () => this.app.quit()
    });
    return result;
  }

  refresh() {
    if (!this.box) return;
    const items = this.items();
    if (this.cursor >= items.length) this.cursor = items.length - 1;
    const width = this.contentWidth(120);
    const labelWidth = Math.max(18, Math.min(30, Math.floor(width * 0.3)));
    const descWidth = Math.max(10, width - 4 - (labelWidth + 6));
    const rows = Math.max(1, this.contentHeight(20) - 2);
    if (this.cursor < this.offset) this.offset = this.cursor;
    if (this.cursor >= this.offset + rows) this.offset = this.cursor - rows + 1;
    this.offset = Math.max(0, Math.min(this.offset, Math.max(0, items.length - rows)));

    let header = c(PAL.dim, t("menu.title"));
    if (items.length > rows) {
      header += c(
        PAL.dim,
        `   ${this.offset + 1}-${Math.min(items.length, this.offset + rows)}/${items.length}`
      );
    }

    const lines: string[] = [header, ""];
    items.slice(this.offset, this.offset + rows).forEach((item, i) => {
      const index = this.offset + i;
      const active = index === this.cursor;
      const pad = Math.max(2, labelWidth - displayWidth(item.label));
      lines.push(
        `${c(PAL.accent, active ? "❯ " : "  ")}` +
          `${c(active ? PAL.accent : PAL.dim, `${menuNumber(index)} `)}` +
          `${c(active ? PAL.bright : PAL.text, escapeTags(item.label))}` +
          " ".repeat(pad) +
          c(PAL.dim, truncateDisplay(item.desc, descWidth))
      );
    });
    this.box.setContent(lines.join("\n"));
    this.app.ui.render();
  }

  onTick() {
    this.refresh();
  }

  onKey(ch: string, key: UiKey) {
    const items = this.items();
    if (key.name === "up") {
      this.cursor = (this.cursor - 1 + items.length) % items.length;
      this.refresh();
      return;
    }
    if (key.name === "down") {
      this.cursor = (this.cursor + 1) % items.length;
      this.refresh();
      return;
    }
    if (key.name === "enter" || key.name === "return") {
      items[this.cursor]?.run();
      return;
    }
    if (key.name === "escape") {
      this.app.quit();
      return;
    }
  }

  onMouse(row: number, _col: number, action: "click" | "wheelup" | "wheeldown") {
    const items = this.items();
    if (!items.length) return;
    if (action === "wheelup") {
      this.cursor = (this.cursor - 1 + items.length) % items.length;
      this.refresh();
      return;
    }
    if (action === "wheeldown") {
      this.cursor = (this.cursor + 1) % items.length;
      this.refresh();
      return;
    }
    const index = this.offset + row - 2;
    if (index < 0 || index >= items.length) return;
    this.cursor = index;
    this.refresh();
    items[index].run();
  }
}

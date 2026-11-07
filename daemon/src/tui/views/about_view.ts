import { BaseView, type AppLike } from "../base";
import { blessed, c, displayWidth, padDisplay, PAL, truncateDisplay, type UiKey } from "../ui";
import { openExternal } from "../service/browser";
import { t } from "../lang";

const SITE = "https://orangeartc0915.github.io/Server-core-manager/projects/";
const QQ_GROUP = "1131093424";

interface ProjectLink {
  name: string;
  usage: string;
  url: string;
}

/** Projects CraftDock is built on or takes inspiration from. */
const LINKS: ProjectLink[] = [
  {
    name: "MCSManager",
    usage: "守护进程内核与功能参考",
    url: "https://github.com/MCSManager/MCSManager"
  },
  {
    name: "MCSManager / PTY",
    usage: "伪终端组件（PTY 已内置）",
    url: "https://github.com/MCSManager/PTY"
  },
  {
    name: "MCT",
    usage: "界面布局参考",
    url: "https://github.com/luoyuqwq/mct"
  },
  {
    name: "MSL",
    usage: "服务端镜像与功能参考",
    url: "https://github.com/MSLTeam/MSL"
  },
  {
    name: "MSLX",
    usage: "资源下载与镜像加速参考",
    url: "https://github.com/MSLTeam/MSLX"
  },
  {
    name: "MSL 服务端镜像站",
    usage: "服务端 / JDK / 资源镜像",
    url: "https://www.mslmc.cn"
  },
  {
    name: "mcimirror",
    usage: "Modrinth / CurseForge API 镜像",
    url: "https://mod.mcimirror.top"
  },
  {
    name: "BMCLAPI",
    usage: "原版服务端镜像（Paper 预取）",
    url: "https://bmclapi.bangbang93.com"
  },
  {
    name: "Modrinth",
    usage: "模组 / 插件搜索与下载",
    url: "https://modrinth.com"
  },
  {
    name: "CurseForge",
    usage: "模组 / 插件搜索与下载",
    url: "https://www.curseforge.com"
  },
  {
    name: "SpigotMC",
    usage: "插件搜索与下载",
    url: "https://www.spigotmc.org"
  },
  {
    name: "Adoptium / Temurin",
    usage: "Java 运行时",
    url: "https://adoptium.net"
  },
  {
    name: "清华 TUNA 镜像",
    usage: "Java 下载备用源",
    url: "https://mirrors.tuna.tsinghua.edu.cn"
  },
  {
    name: "Sakura Frp",
    usage: "内网穿透",
    url: "https://www.natfrp.com"
  },
  {
    name: "OpenFrp",
    usage: "内网穿透（含一键建隧道）",
    url: "https://www.openfrp.net"
  },
  {
    name: "ChmlFrp",
    usage: "内网穿透（含一键建隧道）",
    url: "https://www.chmlfrp.com"
  },
  {
    name: "blessed",
    usage: "终端界面组件库",
    url: "https://github.com/chjj/blessed"
  },
  {
    name: "Node.js SEA",
    usage: "单文件可执行程序打包",
    url: "https://nodejs.org/api/single-executable-applications.html"
  }
];

interface LinkSpan {
  start: number;
  end: number;
  url: string;
}

/** Wrap plain text to `width` columns (CJK aware) keeping the given indent. */
function wrapPlain(text: string, width: number, indent = ""): string[] {
  const limit = Math.max(8, width - displayWidth(indent));
  const out: string[] = [];
  let line = "";
  let used = 0;
  for (const ch of text) {
    const size = displayWidth(ch);
    if (used + size > limit && line) {
      out.push(indent + line);
      line = ch;
      used = size;
    } else {
      line += ch;
      used += size;
    }
  }
  if (line) out.push(indent + line);
  return out.length ? out : [indent];
}

/**
 * About page: author, community and the projects used as building blocks or
 * references. Every link can be opened in the default browser with Enter or a
 * mouse click; the body scrolls with the wheel / PgUp / PgDn.
 */
export class AboutView extends BaseView {
  private box: any;
  private cursor = 0;
  private offset = 0;
  private lines: string[] = [];
  private spans: LinkSpan[] = [];

  constructor(app: AppLike) {
    super(app);
  }

  get title(): string {
    return t("nav.about");
  }

  get hints(): string {
    return "↑↓ 选择链接  Enter 浏览器打开  滚轮/PgUp/PgDn 滚动  Esc 返回";
  }

  protected build() {
    this.page(this.title, "作者 · 友链 · 官网");
    this.box = blessed.box({
      parent: this.root,
      top: 2,
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

  private visibleRows(): number {
    return Math.max(3, this.contentHeight(20) - 2);
  }

  private columnWidth(): number {
    return Math.max(30, this.contentWidth(120) - 4);
  }

  private buildLines(): void {
    const width = this.columnWidth();
    const lines: string[] = [];
    const spans: LinkSpan[] = [];
    const push = (line: string, url?: string) => {
      if (url) spans.push({ start: lines.length, end: lines.length, url });
      lines.push(line);
    };

    push(c(PAL.accent, "CraftDock"));
    for (const part of wrapPlain("原创终端 Minecraft 服务端管理器（借鉴 MCSManager 思路）", width)) {
      push(c(PAL.muted, part));
    }
    push("");
    push(`${c(PAL.dim, "作者")}      ${c(PAL.bright, "mmm")}`);
    push(`${c(PAL.dim, "QQ 群")}     ${c(PAL.bright, QQ_GROUP)}`);
    for (const part of wrapPlain(`官网      ${SITE}`, width)) {
      const text = part.startsWith("官网") ? part : `  ${part.trim()}`;
      push(c(PAL.cyan, text), SITE);
    }
    push("");
    push(c(PAL.dim, "参考与使用的项目（Enter 或点击打开）"));

    this.offsets = [];
    for (let i = 0; i < LINKS.length; i++) {
      const link = LINKS[i];
      const selected = i === this.cursor;
      const name = padDisplay(truncateDisplay(link.name, 22), 22);
      const usage = truncateDisplay(link.usage, Math.max(8, width - 24));
      let row = `${c(PAL.bright, name)} ${c(PAL.muted, usage)}`;
      if (selected) row = `{${PAL.selectBg}-bg}${padDisplay(row, width)}{/}`;
      const start = lines.length;
      push(row, link.url);
      for (const part of wrapPlain(link.url, width, "  ")) {
        push(c(PAL.cyan, part), link.url);
      }
      this.offsets.push({ start, end: lines.length - 1 });
    }

    push("");
    for (const part of wrapPlain(
      "本软件的镜像下载服务由 MSL 开服器提供（https://www.mslmc.cn），请遵守各平台的使用条款。",
      width
    )) {
      push(c(PAL.dim, part));
    }
    for (const part of wrapPlain("感谢所有开源项目与镜像服务的作者。", width)) {
      push(c(PAL.dim, part));
    }

    this.lines = lines;
    this.spans = spans;
  }

  private offsets: { start: number; end: number }[] = [];

  private ensureVisible() {
    const span = this.offsets[this.cursor];
    if (!span) return;
    const rows = this.visibleRows();
    if (span.start < this.offset) this.offset = span.start;
    if (span.end >= this.offset + rows) this.offset = span.end - rows + 1;
  }

  private refresh() {
    if (!this.box) return;
    this.buildLines();
    this.ensureVisible();
    const rows = this.visibleRows();
    const maxOffset = Math.max(0, this.lines.length - rows);
    this.offset = Math.min(Math.max(0, this.offset), maxOffset);
    this.box.setContent(this.lines.slice(this.offset, this.offset + rows).join("\n"));
    this.updatePage(
      this.title,
      `${this.offset + 1}-${Math.min(this.lines.length, this.offset + rows)} / ${this.lines.length}`
    );
    this.app.ui.render();
  }

  private moveCursor(delta: number) {
    this.cursor = Math.min(LINKS.length - 1, Math.max(0, this.cursor + delta));
    this.refresh();
  }

  private openUrl(url: string) {
    try {
      openExternal(url);
      this.app.message(`已在浏览器打开：${url}`, "info");
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private urlAt(line: number): string | undefined {
    const span = this.spans.find((item) => line >= item.start && line <= item.end);
    return span?.url;
  }

  onKey(_ch: string, key: UiKey) {
    switch (key.name) {
      case "escape":
        // This is a top-level section page: go back to the main menu.
        this.app.focusSidebar();
        return;
      case "up":
        this.moveCursor(-1);
        return;
      case "down":
        this.moveCursor(1);
        return;
      case "pageup":
        this.offset -= this.visibleRows();
        this.refresh();
        return;
      case "pagedown":
        this.offset += this.visibleRows();
        this.refresh();
        return;
      case "home":
        this.cursor = 0;
        this.refresh();
        return;
      case "end":
        this.cursor = LINKS.length - 1;
        this.refresh();
        return;
      case "enter":
      case "return":
        this.openUrl(LINKS[this.cursor].url);
        return;
      default:
        return;
    }
  }

  onMouse(row: number, _col: number, action: "click" | "wheelup" | "wheeldown") {
    if (action === "wheelup") {
      this.offset -= 3;
      this.refresh();
      return;
    }
    if (action === "wheeldown") {
      this.offset += 3;
      this.refresh();
      return;
    }
    // The box starts two rows below the view root (below the page header).
    const line = this.offset + (row - 2);
    const url = this.urlAt(line);
    if (!url) return;
    const index = this.offsets.findIndex((span) => line >= span.start && line <= span.end);
    if (index >= 0) this.cursor = index;
    this.refresh();
    this.openUrl(url);
  }
}

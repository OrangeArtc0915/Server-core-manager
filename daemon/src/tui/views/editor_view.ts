import { BaseView, type AppLike } from "../base";
import { blessed, c, displayWidth, PAL, plain, type UiKey } from "../ui";
import { detectLanguage, highlightLine, nextBlockState, SYN, type LangSpec } from "../syntax";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";

/** Expand tabs to two spaces and keep raw -> expanded index mapping. */
function expandTabs(line: string): { text: string; map: number[] } {
  if (!line.includes("\t")) {
    const map: number[] = [];
    for (let i = 0; i <= line.length; i++) map.push(i);
    return { text: line, map };
  }
  let text = "";
  const map: number[] = [];
  for (let i = 0; i < line.length; i++) {
    map.push(text.length);
    text += line[i] === "\t" ? "  " : line[i];
  }
  map.push(text.length);
  return { text, map };
}

function escapeBraces(text: string): string {
  return text.replace(/[{}]/g, (ch) => (ch === "{" ? "{open}" : "{close}"));
}

function isWordChar(ch: string | undefined): boolean {
  return !!ch && /[A-Za-z0-9_]/.test(ch);
}

function toRgb(hex: string): [number, number, number] {
  const value = hex.replace("#", "");
  return [
    parseInt(value.slice(0, 2), 16),
    parseInt(value.slice(2, 4), 16),
    parseInt(value.slice(4, 6), 16)
  ];
}

function toHex(r: number, g: number, b: number): string {
  const clamp = (n: number) => Math.max(0, Math.min(255, Math.round(n)));
  return `#${[r, g, b].map((n) => clamp(n).toString(16).padStart(2, "0")).join("")}`;
}

function mix(a: string, b: string, ratio: number): string {
  const [ar, ag, ab] = toRgb(a);
  const [br, bg, bb] = toRgb(b);
  return toHex(ar + (br - ar) * ratio, ag + (bg - ag) * ratio, ab + (bb - ab) * ratio);
}

type Mode = "normal" | "insert" | "visual" | "visual-line";

interface Pos {
  row: number;
  col: number;
}

interface EditOp {
  from: Pos;
  removed: string;
  inserted: string;
  at: number;
}

// 256-color terminals quantise these values, so the ramp spans several palette
// steps to stay visible instead of collapsing into one shade. Derived from the
// live palette so theme switches take effect immediately.
function editorGradientTop(): string {
  return mix(PAL.panelAlt, PAL.bg, 0.25);
}

function editorGradientBottom(): string {
  return PAL.panel;
}

function searchBg(): string {
  return mix(PAL.bg, PAL.yellow, 0.35);
}

function searchCurrentBg(): string {
  return mix(PAL.bg, PAL.yellow, 0.6);
}

/**
 * In-terminal text editor with Neovim-like modal editing.
 *
 * blessed's textarea grabs every key while reading, which prevents the global
 * shortcut handling (Ctrl+S / Esc / menu keys). This editor renders and edits
 * the buffer itself: Normal / Insert / Visual modes, motions, operators,
 * undo/redo, search and a `:` command line, plus a gradient background.
 */
export class EditorView extends BaseView {
  private body: any;
  private status: any;
  private lines: string[] = [""];
  private row = 0;
  private col = 0;
  private offset = 0;
  private hOffset = 0;
  private loaded = false;
  private original = "";
  private readonly lang: LangSpec;
  private blockState: boolean[] = [];

  private mode: Mode = "normal";
  private count = 0;
  private pending = "";
  private awaitChar: string | null = null;
  private anchor: Pos = { row: 0, col: 0 };
  private yankBuffer: { text: string[]; linewise: boolean } = { text: [], linewise: false };
  private undoStack: EditOp[] = [];
  private redoStack: EditOp[] = [];
  private lastEditAt = 0;
  private showNumber = true;
  private relativeNumber = false;
  private searchPattern = "";
  private searchMatches = new Map<number, Array<[number, number]>>();

  constructor(
    app: AppLike,
    private readonly instanceUuid: string,
    private readonly relPath: string,
    private readonly onDone: () => void
  ) {
    super(app);
    this.lang = detectLanguage(relPath);
  }

  get title(): string {
    return this.relPath.replace(/\\/g, "/");
  }

  get hints(): string {
    if (this.mode === "insert") return "Esc 普通模式   Ctrl+S 保存";
    if (this.mode === "visual" || this.mode === "visual-line") {
      return "y 复制   d 删除   c 修改   Esc 取消   hjkl 扩展选区";
    }
    return "i 进入编辑模式   : 命令   / 搜索   dd yy p   u 撤销   Ctrl+S 保存   Esc 退出";
  }

  /** Insert mode owns typed characters, so global `?` must not open help. */
  get acceptsText(): boolean {
    return this.mode === "insert";
  }

  protected build() {
    const name = instanceService.get(this.instanceUuid)?.config.nickname ?? "";
    this.page(this.title, "Neovim 模式 · :w 保存 · :q 退出", name || undefined);
    this.body = blessed.box({
      parent: this.root,
      top: 2,
      left: 0,
      right: 0,
      bottom: 1,
      tags: true,
      style: { bg: PAL.bg, fg: PAL.text }
    });
    this.status = blessed.box({
      parent: this.root,
      bottom: 0,
      left: 0,
      right: 0,
      height: 1,
      tags: true,
      style: { bg: PAL.panelAlt, fg: PAL.muted },
      padding: { left: 2, right: 2 }
    });
    this.main = this.body;

    try {
      const fm = instanceService.fileManager(this.instanceUuid);
      fm.cwd = ".";
      fm.readFile(this.relPath)
        .then((content) => this.setContent(content))
        .catch((error) => {
          this.app.message(error?.message ?? String(error), "error");
          this.close();
        });
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
      this.close();
    }
  }

  private setContent(content: string) {
    // Refuse binary/huge files: writing them back as UTF-8 would corrupt them.
    if (content.length > 4 * 1024 * 1024 || /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(content)) {
      this.app.message("二进制或过大的文件不支持文本编辑", "error");
      this.close();
      return;
    }
    this.lines = content.replace(/\r\n/g, "\n").split("\n");
    if (!this.lines.length) this.lines = [""];
    this.original = this.lines.join("\n");
    this.row = 0;
    this.col = 0;
    this.offset = 0;
    this.hOffset = 0;
    this.mode = "normal";
    this.count = 0;
    this.pending = "";
    this.undoStack = [];
    this.redoStack = [];
    this.loaded = true;
    this.blockState = [];
    this.recomputeBlocks();
    this.refresh();
  }

  /** Recompute multi-line comment state; stops once the cached tail matches again. */
  private recomputeBlocks(from = 0) {
    const block = this.lang.block;
    if (!block) return;
    let state = from > 0 ? this.blockState[from - 1] ?? false : false;
    for (let i = from; i < this.lines.length; i++) {
      const next = nextBlockState(this.lines[i], state, block, this.lang.lineComments);
      const cached = this.blockState[i];
      this.blockState[i] = next;
      state = next;
      if (i > from && cached === next) break;
    }
    if (from === 0) this.blockState.length = this.lines.length;
  }

  private get text(): string {
    return this.lines.join("\n");
  }

  private get dirty(): boolean {
    return this.loaded && this.text !== this.original;
  }

  private visibleRows(): number {
    return Math.max(3, Number(this.body?.height) || 12);
  }

  private clampCursor() {
    if (this.row >= this.lines.length) this.row = this.lines.length - 1;
    if (this.row < 0) this.row = 0;
    const line = this.lines[this.row] ?? "";
    if (this.col > line.length) this.col = line.length;
    if (this.col < 0) this.col = 0;
    // Normal/visual cursors sit on a character, not past the end of the line.
    if (this.mode !== "insert" && this.col > 0 && this.col >= line.length) {
      this.col = Math.max(0, line.length - 1);
    }
  }

  // ------------------------------------------------------------ buffer edits

  private getRange(from: Pos, to: Pos): string {
    if (from.row === to.row) {
      return this.lines[from.row].slice(from.col, to.col);
    }
    const parts = [this.lines[from.row].slice(from.col)];
    for (let r = from.row + 1; r < to.row; r++) parts.push(this.lines[r]);
    parts.push(this.lines[to.row].slice(0, to.col));
    return parts.join("\n");
  }

  private advance(from: Pos, text: string): Pos {
    const parts = text.split("\n");
    if (parts.length === 1) return { row: from.row, col: from.col + text.length };
    return { row: from.row + parts.length - 1, col: parts[parts.length - 1].length };
  }

  /** Replace the text between two positions (inclusive-exclusive). */
  private replaceRange(from: Pos, to: Pos, text: string): Pos {
    const head = this.lines[from.row].slice(0, from.col);
    const tail = this.lines[to.row].slice(to.col);
    const parts = (head + text + tail).split("\n");
    const removed = to.row - from.row + 1;
    this.lines.splice(from.row, removed, ...parts);
    if (!this.lines.length) this.lines = [""];
    const end = this.advance(from, text);
    this.recomputeBlocks(Math.max(0, from.row - 1));
    this.blockState.length = this.lines.length;
    return end;
  }

  private pushEdit(from: Pos, to: Pos, text: string) {
    const op: EditOp = { from, removed: this.getRange(from, to), inserted: text, at: Date.now() };
    const end = this.replaceRange(from, to, text);
    this.recordEdit(op);
    return end;
  }

  private recordEdit(op: EditOp) {
    const last = this.undoStack[this.undoStack.length - 1];
    const coalesce =
      last &&
      !last.removed &&
      !op.removed &&
      op.at - this.lastEditAt < 400 &&
      last.from.row === op.from.row &&
      last.from.col + last.inserted.length === op.from.col &&
      !op.inserted.includes("\n") &&
      !last.inserted.includes("\n");
    if (coalesce) {
      last.inserted += op.inserted;
    } else {
      this.undoStack.push(op);
      if (this.undoStack.length > 300) this.undoStack.shift();
    }
    this.lastEditAt = op.at;
    this.redoStack = [];
  }

  private undo() {
    const op = this.undoStack.pop();
    if (!op) {
      this.app.message("已经是最早的修改", "info");
      return;
    }
    const end = this.advance(op.from, op.inserted);
    this.replaceRange(op.from, end, op.removed);
    this.redoStack.push(op);
    this.row = op.from.row;
    this.col = op.from.col;
    this.clampCursor();
    this.refresh();
  }

  private redo() {
    const op = this.redoStack.pop();
    if (!op) {
      this.app.message("没有可重做的修改", "info");
      return;
    }
    const end = this.advance(op.from, op.removed);
    this.replaceRange(op.from, end, op.inserted);
    this.undoStack.push(op);
    const after = this.advance(op.from, op.inserted);
    this.row = after.row;
    this.col = after.col;
    this.clampCursor();
    this.refresh();
  }

  private insertText(text: string) {
    const from = { row: this.row, col: this.col };
    const end = this.pushEdit(from, from, text);
    this.row = end.row;
    this.col = end.col;
    this.refresh();
  }

  private insertNewline() {
    const from = { row: this.row, col: this.col };
    const end = this.pushEdit(from, from, "\n");
    this.row = end.row;
    this.col = end.col;
    this.refresh();
  }

  private backspace() {
    if (this.col > 0) {
      const from = { row: this.row, col: this.col - 1 };
      const to = { row: this.row, col: this.col };
      this.pushEdit(from, to, "");
      this.col--;
    } else if (this.row > 0) {
      const prevLength = this.lines[this.row - 1].length;
      const from = { row: this.row - 1, col: prevLength };
      const to = { row: this.row, col: 0 };
      this.pushEdit(from, to, "");
      this.row--;
      this.col = prevLength;
    }
    this.refresh();
  }

  private deleteForward() {
    const line = this.lines[this.row];
    if (this.col < line.length) {
      const from = { row: this.row, col: this.col };
      const to = { row: this.row, col: this.col + 1 };
      this.pushEdit(from, to, "");
    } else if (this.row < this.lines.length - 1) {
      const from = { row: this.row, col: line.length };
      const to = { row: this.row + 1, col: 0 };
      this.pushEdit(from, to, "");
    }
    this.refresh();
  }

  // ------------------------------------------------------------------- render

  private refresh() {
    if (!this.body) return;
    const width = Math.max(20, this.contentWidth(120) - 2);
    const visible = this.visibleRows();
    if (this.row < this.offset) this.offset = this.row;
    if (this.row >= this.offset + visible) this.offset = this.row - visible + 1;
    if (this.offset < 0) this.offset = 0;

    const lineCount = this.lines.length;
    const numberWidth = this.showNumber ? Math.max(3, String(lineCount).length) : 0;
    const gutterWidth = this.showNumber ? numberWidth + 1 : 1;
    // Two leading spaces + gutter + the "│" separator.
    const prefixColumns = 2 + gutterWidth + 1;
    const textWidth = Math.max(10, width - prefixColumns);
    this.ensureHorizontal();

    const out: string[] = [];
    const selection = this.selectionRange();
    const cursorLine = this.row;

    for (let i = 0; i < visible; i++) {
      const index = this.offset + i;
      const gradient = mix(
        editorGradientTop(),
        editorGradientBottom(),
        visible > 1 ? i / (visible - 1) : 0
      );
      const isCursorLine = index === cursorLine;
      const rowBg = isCursorLine ? mix(gradient, PAL.accent, 0.18) : gradient;

      if (index >= lineCount) {
        const gutter = this.showNumber ? " ".repeat(numberWidth) + " " : " ";
        out.push(
          `{${PAL.border}-fg}{${PAL.panel}-bg}${this.pad(`~ ${gutter}`, prefixColumns)}{/}`
        );
        continue;
      }

      const expanded = expandTabs(this.lines[index]);
      const line = expanded.text;
      const caretRaw =
        isCursorLine && this.mode !== "visual-line"
          ? Math.min(expanded.map[this.col] ?? line.length, line.length)
          : -1;
      const horizontal = isCursorLine ? this.hOffset : 0;
      const viewEnd = Math.min(line.length, horizontal + textWidth);
      const view = line.slice(horizontal, viewEnd);

      const colors = new Array<string>(textWidth).fill(SYN.plain);
      const { spans } = highlightLine(line, this.lang, this.blockState[index] ?? false);
      for (const span of spans) {
        const start = Math.max(horizontal, span.start);
        const end = Math.min(viewEnd, span.end);
        for (let k = start; k < end; k++) colors[k - horizontal] = span.color;
      }

      const caret = caretRaw >= 0 ? caretRaw - horizontal : -1;
      const gutter = this.renderGutter(index, numberWidth);
      const code = this.renderCells({
        view,
        colors,
        rowBg,
        caret,
        selectFrom: selection && index >= selection.start.row ? this.selectStart(index, selection) : -1,
        selectTo: selection && index <= selection.end.row ? this.selectEnd(index, selection) : -1,
        horizontal,
        textWidth,
        index
      });
      const prefix = `{${PAL.dim}-fg}{${PAL.panel}-bg}  ${gutter}{/}{${PAL.border}-fg}{${PAL.panel}-bg}│{/}{${rowBg}-bg}`;
      out.push(prefix + code + "{/}");
    }

    this.body.setContent(out.join("\n"));
    this.renderStatus();
    this.app.ui.render();
  }

  private pad(text: string, width: number): string {
    const plain = text.replace(/[{}]/g, "");
    if (plain.length >= width) return plain.slice(0, width);
    return plain + " ".repeat(width - plain.length);
  }

  private renderGutter(index: number, numberWidth: number): string {
    if (!this.showNumber) return " ";
    const absolute = String(index + 1).padStart(numberWidth, " ");
    if (!this.relativeNumber) {
      return index === this.row ? `{${PAL.accent}-fg}{bold}${absolute}{/bold}{/}` : escapeBraces(absolute);
    }
    if (index === this.row) return `{${PAL.accent}-fg}{bold}${absolute}{/bold}{/}`;
    const distance = Math.abs(index - this.row);
    return escapeBraces(String(distance).padStart(numberWidth, " "));
  }

  private ensureHorizontal() {
    const width = Math.max(20, this.contentWidth(120) - 2);
    const numberWidth = this.showNumber ? Math.max(3, String(this.lines.length).length) : 0;
    const gutterWidth = this.showNumber ? numberWidth + 1 : 1;
    const textWidth = Math.max(10, width - (2 + gutterWidth + 1));
    const expanded = expandTabs(this.lines[this.row] ?? "");
    const caret = Math.min(expanded.map[this.col] ?? expanded.text.length, expanded.text.length);
    if (caret < this.hOffset) this.hOffset = caret;
    if (caret >= this.hOffset + textWidth) this.hOffset = Math.max(0, caret - textWidth + 1);
    if (this.hOffset < 0) this.hOffset = 0;
  }

  private selectStart(index: number, selection: { start: Pos; end: Pos; linewise: boolean }): number {
    if (selection.linewise) return 0;
    if (index === selection.start.row) return selection.start.col;
    return 0;
  }

  private selectEnd(index: number, selection: { start: Pos; end: Pos; linewise: boolean }): number {
    if (selection.linewise) return Number.MAX_SAFE_INTEGER;
    if (index === selection.end.row) return selection.end.col + 1;
    return Number.MAX_SAFE_INTEGER;
  }

  /**
   * Paint one row: fg colors come from the syntax spans, bg from the gradient,
   * with selection, search hits and the block cursor layered on top.
   */
  private renderCells(options: {
    view: string;
    colors: string[];
    rowBg: string;
    caret: number;
    selectFrom: number;
    selectTo: number;
    horizontal: number;
    textWidth: number;
    index: number;
  }): string {
    const { view, colors, rowBg, caret, selectFrom, selectTo, horizontal, textWidth, index } = options;
    const matches = this.searchMatches.get(index) ?? [];
    let out = "";
    let runFg = "";
    let runBg = "";
    let buffer = "";

    const flush = () => {
      if (!buffer) return;
      out += `{${runFg}-fg}{${runBg}-bg}${escapeBraces(buffer)}{/}`;
      buffer = "";
    };

    const emit = (text: string, fg: string, bg: string) => {
      if (fg !== runFg || bg !== runBg) {
        flush();
        runFg = fg;
        runBg = bg;
      }
      buffer += text;
    };

    let column = 0;
    for (let k = 0; k < view.length && column < textWidth; k++) {
      const ch = view[k];
      const width = displayWidth(ch);
      if (width === 0) {
        // Combining mark: attaches to the previous cell, costs no column.
        emit(ch, runFg || colors[k], runBg || rowBg);
        continue;
      }
      if (width > textWidth - column) break;

      const absolute = horizontal + k;
      let fg = colors[k];
      let bg = rowBg;

      if (absolute >= selectFrom && absolute < selectTo) bg = PAL.selectBg;
      else {
        for (const [start, end] of matches) {
          if (absolute >= start && absolute < end) {
            const isCurrentRow = index === this.row && this.col >= start && this.col < end;
            bg = isCurrentRow ? searchCurrentBg() : searchBg();
            break;
          }
        }
      }

      if (k === caret) {
        bg = this.mode === "insert" ? PAL.accent : PAL.bright;
        fg = PAL.bg;
      }

      emit(ch, fg, bg);
      column += width;
    }

    // Insert-mode caret sitting past the last character of the line.
    if (caret >= view.length && column < textWidth) {
      emit(" ", PAL.bg, this.mode === "insert" ? PAL.accent : PAL.bright);
      column += 1;
    }

    while (column < textWidth) {
      emit(" ", PAL.text, rowBg);
      column += 1;
    }
    flush();
    return out;
  }

  private renderStatus() {
    const modeBg =
      this.mode === "insert"
        ? PAL.green
        : this.mode === "visual" || this.mode === "visual-line"
        ? PAL.magenta
        : PAL.accent;
    const modeText =
      this.mode === "insert"
        ? " INSERT "
        : this.mode === "visual"
        ? " VISUAL "
        : this.mode === "visual-line"
        ? " V-LINE "
        : " NORMAL ";
    const chip = `{${modeBg}-bg}{${PAL.bg}-fg}{bold}${modeText}{/bold}{/}`;
    const file = this.dirty
      ? `${c(PAL.bright, this.title)}${c(PAL.yellow, " ●")}`
      : c(PAL.bright, this.title);
    // NORMAL mode is read-only: keep the way into edit mode permanently visible
    // in the status line instead of only in the app footer.
    const editHint = this.mode === "insert" ? "" : `  ${c(PAL.dim, "输入 i 进入编辑模式")}`;
    const left = `${chip}  ${file}${editHint}`;
    const right =
      `${c(PAL.muted, `${this.row + 1}:${this.col + 1}`)}  ` +
      `${c(PAL.dim, this.relativeNumber ? "rnu" : "nu")}  ` +
      `${c(PAL.dim, `${this.lines.length} 行`)}  ${c(PAL.dim, this.lang.label)}`;
    const width = this.contentWidth(120);
    const gap = Math.max(1, width - 4 - displayWidth(plain(left)) - displayWidth(plain(right)));
    this.status.setContent(left + " ".repeat(gap) + right);
  }

  // ------------------------------------------------------------------ search

  private buildSearchMatches(pattern: string) {
    this.searchMatches.clear();
    if (!pattern) return;
    const needle = pattern.toLowerCase();
    for (let i = 0; i < this.lines.length; i++) {
      const line = this.lines[i].toLowerCase();
      const hits: Array<[number, number]> = [];
      let from = 0;
      while (from <= line.length) {
        const at = line.indexOf(needle, from);
        if (at < 0) break;
        hits.push([at, at + needle.length]);
        from = at + Math.max(1, needle.length);
        if (hits.length > 200) break;
      }
      if (hits.length) this.searchMatches.set(i, hits);
    }
  }

  private searchNext(backwards = false) {
    if (!this.searchPattern) return;
    this.buildSearchMatches(this.searchPattern);
    const hits: Pos[] = [];
    for (const [row, ranges] of [...this.searchMatches.entries()].sort((a, b) => a[0] - b[0])) {
      for (const [start] of ranges) hits.push({ row, col: start });
    }
    if (!hits.length) {
      this.app.message(`未找到：${this.searchPattern}`, "warn");
      return;
    }
    const current: Pos = { row: this.row, col: this.col };
    let target: Pos | undefined;
    if (!backwards) {
      target = hits.find((hit) => hit.row > current.row || (hit.row === current.row && hit.col > current.col));
      if (!target) target = hits[0];
    } else {
      const before = hits.filter(
        (hit) => hit.row < current.row || (hit.row === current.row && hit.col < current.col)
      );
      target = before.length ? before[before.length - 1] : hits[hits.length - 1];
    }
    this.row = target.row;
    this.col = target.col;
    this.clampCursor();
    this.refresh();
  }

  // --------------------------------------------------------------- commands

  private openCommandLine() {
    this.app.ui.prompt({
      title: "命令",
      label: "w 保存 · q 退出 · wq 保存并退出 · set nu/rnu · e 文件 · 数字 跳行",
      value: "",
      onSubmit: (raw) => {
        const command = raw.trim().replace(/^:/, "");
        this.runCommand(command);
        return true;
      }
    });
  }

  private runCommand(command: string) {
    const [name, ...rest] = command.split(/\s+/);
    const argument = rest.join(" ");
    switch (name) {
      case "":
        break;
      case "w":
        void this.save();
        break;
      case "q":
        this.requestClose();
        break;
      case "q!":
        this.close();
        break;
      case "wq":
      case "x":
        void this.save().then((ok) => {
          if (ok) this.close();
        });
        break;
      case "noh":
      case "nohlsearch":
        this.searchPattern = "";
        this.searchMatches.clear();
        this.refresh();
        break;
      case "set":
        this.applyOption(argument);
        break;
      case "e":
      case "edit":
        if (argument) this.openFile(argument);
        break;
      default:
        if (/^\d+$/.test(name)) {
          this.row = Math.min(this.lines.length - 1, Math.max(0, Number(name) - 1));
          this.clampCursor();
          this.refresh();
          return;
        }
        this.app.message(`未知命令：${command}`, "warn");
    }
  }

  private applyOption(option: string) {
    switch (option) {
      case "nu":
      case "number":
        this.showNumber = true;
        this.relativeNumber = false;
        break;
      case "rnu":
      case "relativenumber":
        this.showNumber = true;
        this.relativeNumber = true;
        break;
      case "nonu":
      case "nonumber":
        this.showNumber = false;
        this.relativeNumber = false;
        break;
      default:
        this.app.message(`未知选项：${option}`, "warn");
        return;
    }
    this.refresh();
  }

  private openFile(target: string) {
    const path = target.replace(/^\.\//, "");
    this.app.push(
      new EditorView(this.app, this.instanceUuid, path, () => this.app.back()),
      () => new EditorView(this.app, this.instanceUuid, this.relPath, () => this.app.back())
    );
  }

  private openSearch() {
    this.app.ui.prompt({
      title: "搜索",
      value: "",
      onSubmit: (raw) => {
        const pattern = raw.trim().replace(/^\//, "");
        if (!pattern) return true;
        this.searchPattern = pattern;
        this.searchNext(false);
        return true;
      }
    });
  }

  // ------------------------------------------------------------- cursor moves

  private moveVertical(delta: number) {
    this.row += delta;
    this.clampCursor();
    this.refresh();
  }

  private moveHorizontal(delta: number) {
    const line = this.lines[this.row];
    const maxCol = this.mode === "insert" ? line.length : Math.max(0, line.length - 1);
    if (delta > 0) {
      if (this.col < maxCol) this.col++;
      else if (this.row < this.lines.length - 1) {
        this.row++;
        this.col = 0;
      }
    } else if (this.col > 0) {
      this.col--;
    } else if (this.row > 0) {
      this.row--;
      const prev = this.lines[this.row];
      this.col = this.mode === "insert" ? prev.length : Math.max(0, prev.length - 1);
    }
    this.refresh();
  }

  private moveWordForward(times = 1) {
    for (let n = 0; n < times; n++) {
      const line = this.lines[this.row];
      let col = this.col;
      if (col < line.length && isWordChar(line[col])) {
        while (col < line.length && isWordChar(line[col])) col++;
      } else {
        while (col < line.length && !isWordChar(line[col]) && line[col] !== " ") col++;
      }
      while (col < line.length && (line[col] === " " || line[col] === "\t")) col++;
      if (col >= line.length && this.row < this.lines.length - 1) {
        this.row++;
        this.col = 0;
      } else {
        this.col = Math.min(col, Math.max(0, line.length - 1));
      }
    }
    this.clampCursor();
    this.refresh();
  }

  private moveWordBackward(times = 1) {
    for (let n = 0; n < times; n++) {
      let col = this.col - 1;
      if (col < 0) {
        if (this.row === 0) break;
        this.row--;
        col = this.lines[this.row].length - 1;
      }
      const line = this.lines[this.row];
      while (col > 0 && !isWordChar(line[col]) && line[col] !== " ") col--;
      while (col > 0 && isWordChar(line[col - 1])) col--;
      this.col = Math.max(0, col);
    }
    this.clampCursor();
    this.refresh();
  }

  private moveWordEnd(times = 1) {
    for (let n = 0; n < times; n++) {
      const line = this.lines[this.row];
      let col = this.col + 1;
      while (col < line.length && !isWordChar(line[col])) col++;
      while (col < line.length - 1 && isWordChar(line[col + 1])) col++;
      this.col = Math.min(col, Math.max(0, line.length - 1));
    }
    this.clampCursor();
    this.refresh();
  }

  private moveLineStart() {
    this.col = 0;
    this.refresh();
  }

  private moveFirstNonBlank() {
    const line = this.lines[this.row];
    const match = line.match(/\S/);
    this.col = match ? match.index ?? 0 : 0;
    this.refresh();
  }

  private moveLineEnd() {
    const line = this.lines[this.row];
    this.col = this.mode === "insert" ? line.length : Math.max(0, line.length - 1);
    this.refresh();
  }

  private gotoLine(index: number) {
    this.row = Math.max(0, Math.min(this.lines.length - 1, index));
    this.clampCursor();
    this.refresh();
  }

  // --------------------------------------------------------------- selection

  private selectionRange(): { start: Pos; end: Pos; linewise: boolean } | undefined {
    if (this.mode !== "visual" && this.mode !== "visual-line") return undefined;
    const a = this.anchor;
    const b = { row: this.row, col: this.col };
    const before = a.row < b.row || (a.row === b.row && a.col <= b.col);
    const start = before ? a : b;
    const end = before ? b : a;
    return { start, end, linewise: this.mode === "visual-line" };
  }

  private selectionText(): string {
    const range = this.selectionRange();
    if (!range) return "";
    if (range.linewise) {
      return this.lines.slice(range.start.row, range.end.row + 1).join("\n");
    }
    return this.getRange(range.start, { row: range.end.row, col: range.end.col + 1 });
  }

  private yankSelection() {
    const range = this.selectionRange();
    if (!range) return;
    if (range.linewise) {
      this.yankBuffer = { text: this.lines.slice(range.start.row, range.end.row + 1), linewise: true };
    } else {
      this.yankBuffer = {
        text: this.selectionText().split("\n"),
        linewise: false
      };
    }
    this.mode = "normal";
    this.app.message(`已复制 ${this.yankBuffer.text.length} 行`, "success");
    this.clampCursor();
    this.refresh();
  }

  private deleteSelection() {
    const range = this.selectionRange();
    if (!range) return false;
    this.yankSelectionToBuffer(range);
    if (range.linewise) {
      const startRow = range.start.row;
      const endRow = range.end.row;
      if (endRow < this.lines.length - 1) {
        this.pushEdit({ row: startRow, col: 0 }, { row: endRow + 1, col: 0 }, "");
      } else if (startRow > 0) {
        this.pushEdit(
          { row: startRow - 1, col: this.lines[startRow - 1].length },
          { row: endRow, col: this.lines[endRow].length },
          ""
        );
      } else {
        this.pushEdit({ row: 0, col: 0 }, { row: endRow, col: this.lines[endRow].length }, "");
      }
      if (!this.lines.length) this.lines = [""];
      this.row = Math.min(startRow, this.lines.length - 1);
      this.col = 0;
    } else {
      this.pushEdit(range.start, { row: range.end.row, col: range.end.col + 1 }, "");
      this.row = range.start.row;
      this.col = range.start.col;
    }
    this.mode = "normal";
    this.clampCursor();
    this.refresh();
    return true;
  }

  private yankSelectionToBuffer(range: { start: Pos; end: Pos; linewise: boolean }) {
    if (range.linewise) {
      this.yankBuffer = { text: this.lines.slice(range.start.row, range.end.row + 1), linewise: true };
    } else {
      this.yankBuffer = {
        text: this.getRange(range.start, { row: range.end.row, col: range.end.col + 1 }).split("\n"),
        linewise: false
      };
    }
  }

  // --------------------------------------------------------------- operators

  private deleteLines(count = 1) {
    const row = this.row;
    const end = Math.min(this.lines.length, row + count);
    if (end <= row) return;
    this.yankBuffer = { text: this.lines.slice(row, end), linewise: true };
    if (end >= this.lines.length && row === 0) {
      // Deleting everything leaves a single empty line.
      this.pushEdit({ row: 0, col: 0 }, { row: this.lines.length - 1, col: this.lines[this.lines.length - 1].length }, "");
    } else if (end >= this.lines.length) {
      // Last line(s): remove the preceding newline together with the text.
      this.pushEdit({ row: row - 1, col: this.lines[row - 1].length }, { row: this.lines.length - 1, col: this.lines[this.lines.length - 1].length }, "");
    } else {
      this.pushEdit({ row, col: 0 }, { row: end, col: 0 }, "");
    }
    this.row = Math.min(row, this.lines.length - 1);
    this.col = 0;
    this.clampCursor();
    this.refresh();
  }

  private yankLines(count = 1) {
    const end = Math.min(this.lines.length, this.row + count);
    this.yankBuffer = { text: this.lines.slice(this.row, end), linewise: true };
    this.app.message(`已复制 ${end - this.row} 行`, "success");
    this.refresh();
  }

  private paste(after = true) {
    if (!this.yankBuffer.text.length) {
      this.app.message("寄存器为空", "info");
      return;
    }
    if (this.yankBuffer.linewise) {
      const text = this.yankBuffer.text.join("\n");
      if (after) {
        const line = this.lines[this.row];
        const from = { row: this.row, col: line.length };
        this.pushEdit(from, from, "\n" + text);
        this.row = from.row + 1;
        this.col = 0;
      } else {
        const from = { row: this.row, col: 0 };
        this.pushEdit(from, from, text + "\n");
        this.col = 0;
      }
    } else {
      const at = { row: this.row, col: this.col + (after && this.lines[this.row].length ? 1 : 0) };
      const text = this.yankBuffer.text.join("\n");
      const end = this.pushEdit(at, at, text);
      this.row = end.row;
      this.col = end.col;
    }
    this.clampCursor();
    this.refresh();
  }

  private deleteChars(count = 1) {
    const line = this.lines[this.row];
    if (!line.length) return;
    const end = Math.min(line.length, this.col + count);
    this.yankBuffer = { text: [line.slice(this.col, end)], linewise: false };
    this.pushEdit({ row: this.row, col: this.col }, { row: this.row, col: end }, "");
    this.clampCursor();
    this.refresh();
  }

  private enterInsert(mode: "i" | "a" | "I" | "A" | "o" | "O") {
    const line = this.lines[this.row];
    switch (mode) {
      case "a":
        if (line.length) this.col = Math.min(line.length, this.col + 1);
        break;
      case "I": {
        const match = line.match(/\S/);
        this.col = match ? match.index ?? 0 : 0;
        break;
      }
      case "A":
        this.col = line.length;
        break;
      case "o": {
        const from = { row: this.row, col: line.length };
        const end = this.pushEdit(from, from, "\n");
        this.row = end.row;
        this.col = 0;
        break;
      }
      case "O": {
        const from = { row: this.row, col: 0 };
        this.pushEdit(from, from, "\n");
        this.col = 0;
        break;
      }
      default:
        break;
    }
    this.mode = "insert";
    this.refresh();
  }

  // --------------------------------------------------------------- key routes

  onMouse(row: number, _col: number, action: "click" | "wheelup" | "wheeldown") {
    if (!this.loaded) return;
    if (action === "wheelup") {
      this.offset = Math.max(0, this.offset - 3);
      this.refresh();
      return;
    }
    if (action === "wheeldown") {
      this.offset = Math.min(Math.max(0, this.lines.length - 1), this.offset + 3);
      this.refresh();
      return;
    }
    const index = this.offset + row - 2;
    if (index < 0 || index >= this.lines.length) return;
    this.row = index;
    this.col = Math.min(this.col, this.lines[index].length);
    this.clampCursor();
    this.refresh();
  }

  onKey(ch: string, key: UiKey) {
    if (key.ctrl && key.name === "s") {
      void this.save();
      return;
    }
    if (!this.loaded) return;
    if (this.mode === "insert") {
      this.handleInsert(ch, key);
      return;
    }
    if (this.mode === "visual" || this.mode === "visual-line") {
      this.handleVisual(ch, key);
      return;
    }
    this.handleNormal(ch, key);
  }

  private handleInsert(ch: string, key: UiKey) {
    switch (key.name) {
      case "escape":
        this.mode = "normal";
        if (this.col > 0) this.col--;
        this.clampCursor();
        this.refresh();
        return;
      case "up":
        this.moveVertical(-1);
        return;
      case "down":
        this.moveVertical(1);
        return;
      case "left":
        this.moveHorizontal(-1);
        return;
      case "right":
        this.moveHorizontal(1);
        return;
      case "home":
        this.col = 0;
        this.refresh();
        return;
      case "end":
        this.col = this.lines[this.row].length;
        this.refresh();
        return;
      case "pageup":
        this.row = Math.max(0, this.row - this.visibleRows());
        this.clampCursor();
        this.refresh();
        return;
      case "pagedown":
        this.row = Math.min(this.lines.length - 1, this.row + this.visibleRows());
        this.clampCursor();
        this.refresh();
        return;
      case "backspace":
        this.backspace();
        return;
      case "delete":
        this.deleteForward();
        return;
      case "enter":
      case "return":
        this.insertNewline();
        return;
      case "tab":
        this.insertText("  ");
        return;
    }
    if (!key.ctrl && !key.meta && ch && ch.charCodeAt(0) >= 32) this.insertText(ch);
  }

  private handleVisual(ch: string, key: UiKey) {
    const times = this.consumeCount();
    switch (key.name) {
      case "escape":
        this.mode = "normal";
        this.clampCursor();
        this.refresh();
        return;
      case "up":
        this.moveVertical(-times);
        return;
      case "down":
        this.moveVertical(times);
        return;
      case "left":
        for (let i = 0; i < times; i++) this.moveHorizontal(-1);
        return;
      case "right":
        for (let i = 0; i < times; i++) this.moveHorizontal(1);
        return;
      case "home":
        this.col = 0;
        this.refresh();
        return;
      case "end":
        this.moveLineEnd();
        return;
      default:
        break;
    }
    if (ch === "h") this.moveHorizontal(-times);
    else if (ch === "l") this.moveHorizontal(times);
    else if (ch === "j") this.moveVertical(times);
    else if (ch === "k") this.moveVertical(-times);
    else if (ch === "0") this.moveLineStart();
    else if (ch === "$") this.moveLineEnd();
    else if (ch === "w") this.moveWordForward(times);
    else if (ch === "b") this.moveWordBackward(times);
    else if (ch === "e") this.moveWordEnd(times);
    else if (ch === "g") {
      this.gotoLine(0);
    } else if (ch === "G") {
      this.gotoLine(this.lines.length - 1);
    } else if (ch === "y") {
      this.yankSelection();
    } else if (ch === "d" || ch === "x") {
      this.deleteSelection();
    } else if (ch === "c") {
      if (this.deleteSelection()) {
        this.mode = "insert";
        this.refresh();
      }
    } else if (ch === "v") {
      this.mode = this.mode === "visual" ? "visual-line" : "visual";
      this.refresh();
    }
  }

  private consumeCount(): number {
    const value = this.count || 1;
    this.count = 0;
    return value;
  }

  private handleNormal(ch: string, key: UiKey) {
    // Pending multi-key commands.
    if (this.awaitChar) {
      const operation = this.awaitChar;
      this.awaitChar = null;
      if (operation === "r" && ch) {
        const line = this.lines[this.row];
        if (this.col < line.length) {
          this.pushEdit({ row: this.row, col: this.col }, { row: this.row, col: this.col + 1 }, ch);
          this.refresh();
        }
      }
      this.count = 0;
      this.pending = "";
      return;
    }

    if (/^[0-9]$/.test(ch)) {
      // "0" is a motion only when it is not part of a count (e.g. 10j).
      if (ch === "0" && !this.count) {
        this.moveLineStart();
        return;
      }
      this.count = this.count * 10 + Number(ch);
      return;
    }

    const times = this.consumeCount();

    switch (key.name) {
      case "escape":
        if (this.pending) {
          this.pending = "";
          return;
        }
        this.requestClose();
        return;
      case "up":
        this.moveVertical(-times);
        return;
      case "down":
        this.moveVertical(times);
        return;
      case "left":
        for (let i = 0; i < times; i++) this.moveHorizontal(-1);
        return;
      case "right":
        for (let i = 0; i < times; i++) this.moveHorizontal(1);
        return;
      case "home":
        this.moveLineStart();
        return;
      case "end":
        this.moveLineEnd();
        return;
      case "pageup":
        this.row = Math.max(0, this.row - this.visibleRows());
        this.clampCursor();
        this.refresh();
        return;
      case "pagedown":
        this.row = Math.min(this.lines.length - 1, this.row + this.visibleRows());
        this.clampCursor();
        this.refresh();
        return;
      case "backspace":
        this.moveHorizontal(-1);
        return;
      default:
        break;
    }

    if (key.ctrl && key.name === "r") {
      this.redo();
      return;
    }
    if (key.ctrl && key.name === "d") {
      this.row = Math.min(this.lines.length - 1, this.row + Math.floor(this.visibleRows() / 2));
      this.clampCursor();
      this.refresh();
      return;
    }
    if (key.ctrl && key.name === "u") {
      this.row = Math.max(0, this.row - Math.floor(this.visibleRows() / 2));
      this.clampCursor();
      this.refresh();
      return;
    }

    switch (ch) {
      case "h":
        for (let i = 0; i < times; i++) this.moveHorizontal(-1);
        return;
      case "j":
        this.moveVertical(times);
        return;
      case "k":
        this.moveVertical(-times);
        return;
      case "l":
        for (let i = 0; i < times; i++) this.moveHorizontal(1);
        return;
      case "$":
        this.moveLineEnd();
        return;
      case "^":
        this.moveFirstNonBlank();
        return;
      case "w":
        this.moveWordForward(times);
        return;
      case "b":
        this.moveWordBackward(times);
        return;
      case "e":
        this.moveWordEnd(times);
        return;
      case "G":
        this.gotoLine(times > 1 ? times - 1 : this.lines.length - 1);
        return;
      case "i":
        this.enterInsert("i");
        return;
      case "a":
        this.enterInsert("a");
        return;
      case "I":
        this.enterInsert("I");
        return;
      case "A":
        this.enterInsert("A");
        return;
      case "o":
        this.enterInsert("o");
        return;
      case "O":
        this.enterInsert("O");
        return;
      case "v":
        this.mode = "visual";
        this.anchor = { row: this.row, col: this.col };
        this.refresh();
        return;
      case "V":
        this.mode = "visual-line";
        this.anchor = { row: this.row, col: 0 };
        this.refresh();
        return;
      case "x":
        this.deleteChars(times);
        return;
      case "X":
        for (let i = 0; i < times; i++) this.backspace();
        return;
      case "p":
        this.paste(true);
        return;
      case "P":
        this.paste(false);
        return;
      case "u":
        this.undo();
        return;
      case "r":
        this.awaitChar = "r";
        return;
      case "/":
        this.openSearch();
        return;
      case "n":
        this.searchNext(false);
        return;
      case "N":
        this.searchNext(true);
        return;
      case ":":
        this.openCommandLine();
        return;
      case "g":
        if (this.pending === "g") {
          this.pending = "";
          this.gotoLine(times > 1 ? times - 1 : 0);
        } else {
          this.pending = "g";
        }
        return;
      case "d":
        if (this.pending === "d") {
          this.pending = "";
          this.deleteLines(times);
        } else {
          this.pending = "d";
        }
        return;
      case "y":
        if (this.pending === "y") {
          this.pending = "";
          this.yankLines(times);
        } else {
          this.pending = "y";
        }
        return;
      default:
        this.pending = "";
    }
  }

  private async save(): Promise<boolean> {
    try {
      const fm = instanceService.fileManager(this.instanceUuid);
      fm.cwd = ".";
      await fm.writeFile(this.relPath, this.text);
      this.original = this.text;
      this.app.message(`${t("files.saved")} · ${this.title}`, "success");
      this.refresh();
      return true;
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
      return false;
    }
  }

  private requestClose() {
    if (!this.dirty) {
      this.close();
      return;
    }
    this.app.ui.confirm(t("files.editorHint"), t("files.unsaved"), () => this.close(), () => this.refresh());
  }

  private close() {
    this.onDone();
  }
}

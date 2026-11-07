import path from "path";
import { BaseView, type AppLike } from "../base";
import { blessed, c, createFlatList, escapeTags, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { EditorView } from "./editor_view";

const KNOWN_FILES = [
  "server.properties",
  "eula.txt",
  "bukkit.yml",
  "spigot.yml",
  "paper.yml",
  "paper-global.yml",
  "config/paper-global.yml",
  "purpur.yml",
  "pufferfish.yml",
  "leaves.yml",
  "fabric-server-launch.properties",
  "ops.json",
  "whitelist.json",
  "banned-players.json",
  "banned-ips.json"
];

export class CommonFilesView extends BaseView {
  private list: any;
  private files: string[] = [];

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  get title(): string {
    return t("cfg.common");
  }

  get hints(): string {
    return "Enter 编辑   a 自定义文件路径   r 刷新   Esc 返回";
  }

  protected build() {
    const name = instanceService.get(this.instanceUuid)?.config.nickname ?? "";
    this.page(name, "常用服务端配置", t("inst.title"));
    this.list = createFlatList(this.root, 2);
    this.list.on("select", () => this.openSelected());
    this.main = this.list;
    this.list.focus();
    this.refresh();
  }

  refresh() {
    const fm = instanceService.fileManager(this.instanceUuid);
    fm.cwd = ".";
    this.files = KNOWN_FILES.filter((file) => {
      try {
        return fm.check(file);
      } catch (error) {
        return false;
      }
    });
    const items = this.files.map(
      (file) => `${c(PAL.accent, "▸")} ${c(PAL.bright, escapeTags(file))}`
    );
    if (!items.length) items.push(c(PAL.dim, t("cfg.commonHint")));
    this.list.setItems(items);
    this.updatePage(
      instanceService.get(this.instanceUuid)?.config.nickname ?? "",
      `常用配置  ·  ${this.files.length} 个文件`,
      t("inst.title")
    );
    this.app.ui.render();
  }

  private openSelected() {
    const file = this.files[this.list?.selected ?? 0];
    if (!file) return;
    this.openFile(file);
  }

  private openFile(file: string) {
    const parent = () => new CommonFilesView(this.app, this.instanceUuid);
    if (file.toLowerCase().endsWith(".properties") || file.toLowerCase() === "eula.txt") {
      this.app.push(new PropertiesView(this.app, this.instanceUuid, file), parent);
    } else {
      this.app.push(new EditorView(this.app, this.instanceUuid, file, () => this.app.back()), parent);
    }
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    if (ch === "r") this.refresh();
    if (ch === "a") {
      this.app.ui.prompt({
        title: t("cfg.common"),
        label: "相对实例根目录的文件路径",
        value: "",
        onSubmit: (value) => {
          const file = value.trim().replace(/\\/g, "/");
          if (!file) return false;
          try {
            const fm = instanceService.fileManager(this.instanceUuid);
            fm.cwd = ".";
            if (!fm.check(file)) {
              this.app.message(t("files.openedFail", { err: file }), "error");
              return false;
            }
          } catch (error: any) {
            this.app.message(error?.message ?? String(error), "error");
            return false;
          }
          this.openFile(path.normalize(file));
        }
      });
    }
  }
}

interface PropRow {
  index: number;
  key: string;
  value: string;
}

export class PropertiesView extends BaseView {
  private list: any;
  private lines: string[] = [];
  private rows: PropRow[] = [];
  private dirty = false;

  constructor(
    app: AppLike,
    private readonly instanceUuid: string,
    private readonly fileName: string
  ) {
    super(app);
  }

  get title(): string {
    return t("props.title", { file: this.fileName });
  }

  get hints(): string {
    return t("props.hint");
  }

  protected build() {
    this.page(this.fileName, "键值编辑", t("inst.title"));
    this.list = createFlatList(this.root, 2);
    this.list.on("select", () => this.editValue());
    this.main = this.list;
    this.list.focus();
    void this.load();
  }

  private async load() {
    try {
      const fm = instanceService.fileManager(this.instanceUuid);
      fm.cwd = ".";
      const text = await fm.readFile(this.fileName);
      this.lines = text.split(/\r?\n/);
      this.parse();
      this.refresh();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private parse() {
    this.rows = [];
    this.lines.forEach((line, index) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#") || trimmed.startsWith("!")) return;
      const eq = line.indexOf("=");
      if (eq < 0) return;
      this.rows.push({
        index,
        key: line.slice(0, eq).trim(),
        value: line.slice(eq + 1)
      });
    });
  }

  private refresh() {
    const contentWidth = this.contentWidth();
    const keyWidth = 34;
    const valueWidth = Math.max(12, contentWidth - keyWidth - 6);
    const items = this.rows.map(
      (row) =>
        `${c(PAL.dim, padDisplay(truncateDisplay(row.key, keyWidth), keyWidth))} ${c(
          PAL.text,
          escapeTags(truncateDisplay(row.value, valueWidth))
        )}`
    );
    if (!items.length) items.push(c(PAL.dim, t("props.empty")));
    const previous = this.list.selected ?? 0;
    this.list.setItems(items);
    this.list.select(Math.min(previous, items.length - 1));
    this.updatePage(
      this.fileName,
      `${this.dirty ? "● 未保存  ·  " : ""}${this.rows.length} 项`,
      t("inst.title")
    );
    this.app.ui.render();
  }

  private editValue() {
    const row = this.rows[this.list?.selected ?? 0];
    if (!row) return;
    this.app.ui.prompt({
      title: row.key,
      label: row.key,
      value: row.value,
      onSubmit: (value) => {
        this.lines[row.index] = `${row.key}=${value}`;
        this.dirty = true;
        this.parse();
        this.refresh();
      }
    });
  }

  private async save() {
    try {
      const fm = instanceService.fileManager(this.instanceUuid);
      fm.cwd = ".";
      await fm.writeFile(this.fileName, this.lines.join("\n"));
      this.dirty = false;
      this.updatePage(this.fileName, `${this.rows.length} 项`, t("inst.title"));
      this.app.message(t("props.saved"), "success");
      this.app.ui.render();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      if (this.dirty) {
        this.app.ui.confirm(this.title, t("files.unsaved"), () => this.app.back());
        return;
      }
      this.app.back();
      return;
    }
    if (ch === "s") void this.save();
    if (ch === "r") void this.load();
  }
}

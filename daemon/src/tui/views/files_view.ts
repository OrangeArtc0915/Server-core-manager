import fs from "fs-extra";
import { promises as fsp } from "fs";
import path from "path";
import { spawn } from "child_process";
import { BaseView, type AppLike } from "../base";
import {
  blessed,
  c,
  createFlatList,
  escapeTags,
  PAL,
  padDisplay,
  truncateDisplay,
  type UiKey
} from "../ui";
import { formatBytes, formatDateTime } from "../format";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { opsLog } from "../service/ops_log";
import { create7z, extractArchive, isSevenZipArchive, zipEntries } from "../service/zip_service";
import { EditorView } from "./editor_view";

interface FileEntry {
  name: string;
  size: number;
  type: number;
  time: string;
}

interface SearchResult {
  rel: string;
  isDir: boolean;
  size: number;
}

export class FilesView extends BaseView {
  private list: any;
  private tableHeader: any;
  private relPath = ".";
  private entries: FileEntry[] = [];
  private selected = new Set<string>();
  private filter = "";
  private showParent = false;
  private searchResults: SearchResult[] | null = null;
  private searchQuery = "";

  constructor(app: AppLike, private readonly instanceUuid: string, initialPath = ".") {
    super(app);
    this.relPath = initialPath || ".";
  }

  get title(): string {
    const name = instanceService.get(this.instanceUuid)?.config.nickname ?? "";
    return t("files.title", { name });
  }

  get hints(): string {
    if (this.selected.size) {
      return `${t("files.batch", { n: this.selected.size })}  x 删除  z 压缩  Space 取消  Esc 返回`;
    }
    if (this.searchResults) {
      return "↑↓ 选择   Enter 打开   f 重新搜索   Esc 返回当前目录";
    }
    return "Enter 打开  ⌫ 上级  Space 多选  e 编辑  x 删除  c 复制  v 移动  z 压缩  u 解压  p 上传  d 下载  n 新建  f 递归搜索  / 筛选  Esc 返回";
  }

  protected build() {
    const name = instanceService.get(this.instanceUuid)?.config.nickname ?? "";
    this.page(name, this.displayPath(), t("inst.title"));
    this.tableHeader = blessed.box({
      parent: this.root,
      top: 2,
      left: 0,
      right: 0,
      height: 1,
      tags: true,
      style: { bg: PAL.panelAlt, fg: PAL.dim },
      padding: { left: 2, right: 2 }
    });
    this.list = createFlatList(this.root, 3);
    this.list.on("select", () => this.openSelected());
    this.main = this.list;
    this.list.focus();
    void this.load();
  }

  private cwdAbsolute(): string {
    return this.fileManager().toAbsolutePath();
  }

  private fileManager() {
    const fm = instanceService.fileManager(this.instanceUuid);
    fm.cwd = this.relPath || ".";
    return fm;
  }

  private displayPath(): string {
    if (this.relPath === "." || this.relPath === "") return "/";
    return "/" + this.relPath.replace(/\\/g, "/");
  }

  private async load() {
    if (this.searchResults) {
      this.renderSearch();
      return;
    }
    try {
      const fm = this.fileManager();
      const result = await fm.list(0, 100);
      this.entries = result.items.filter(
        (entry) => !this.filter || entry.name.toLowerCase().includes(this.filter.toLowerCase())
      );
      this.showParent = this.relPath !== "." && this.relPath !== "";
      const items: string[] = [];
      if (this.showParent) items.push(c(PAL.yellow, "  ↑  上级目录"));
      const contentWidth = this.contentWidth();
      const nameWidth = Math.max(20, contentWidth - 46);
      this.tableHeader.setContent(
        c(PAL.dim, `  ${padDisplay(t("common.name"), nameWidth)} ${padDisplay(t("common.size"), 10)} ${t("common.time")}`)
      );
      for (const entry of this.entries) {
        const isDir = entry.type === 0;
        const icon = isDir ? c(PAL.accent, "▸") : " ";
        const mark = this.selected.has(entry.name) ? c(PAL.accent2, "✓") : " ";
        const name = escapeTags(
          padDisplay(truncateDisplay(entry.name, nameWidth), nameWidth)
        );
        const size = padDisplay(isDir ? "-" : formatBytes(entry.size), 10);
        const time = entry.time ? formatDateTime(new Date(entry.time).getTime()) : "-";
        items.push(
          `${mark} ${icon} ${isDir ? c(PAL.bright, name) : name} ${c(PAL.muted, size)} ${c(PAL.dim, time)}`
        );
      }
      if (!this.entries.length) items.push(c(PAL.dim, t("files.empty")));
      const previous = this.list.selected ?? 0;
      this.list.setItems(items);
      this.list.select(Math.min(previous, items.length - 1));

      const metaParts = [this.displayPath()];
      if (this.filter) metaParts.push(t("files.filter", { q: this.filter }));
      if (this.selected.size) metaParts.push(t("files.batch", { n: this.selected.size }));
      metaParts.push(`${this.entries.length} 项`);
      metaParts.push(result.absolutePath);
      this.updatePage(
        instanceService.get(this.instanceUuid)?.config.nickname ?? "",
        metaParts.join("  ·  "),
        t("inst.title")
      );
      this.app.ui.render();
    } catch (error: any) {
      const reason = error?.message ?? String(error);
      this.app.message(reason, "error");
      try {
        this.tableHeader.setContent(c(PAL.dim, `  ${this.displayPath()}`));
        this.list.setItems([c(PAL.red, `  ✗ ${escapeTags(reason)}`)]);
        this.app.ui.render();
      } catch (renderError) {}
    }
  }

  private currentEntry(): FileEntry | undefined {
    const index = this.list?.selected ?? 0;
    return this.entries[index - (this.showParent ? 1 : 0)];
  }

  /** Render the recursive search results in place of the directory listing. */
  private renderSearch() {
    const results = this.searchResults ?? [];
    const width = this.contentWidth();
    const nameWidth = Math.max(20, width - 30);
    this.tableHeader.setContent(
      c(PAL.dim, `  ${padDisplay("路径", nameWidth)} ${padDisplay(t("common.size"), 10)}`)
    );
    const items = results.map((result) => {
      const rel = escapeTags(
        padDisplay(truncateDisplay(result.rel.replace(/\\/g, "/"), nameWidth), nameWidth)
      );
      const icon = result.isDir ? c(PAL.accent, "▸") : " ";
      const size = padDisplay(result.isDir ? "-" : formatBytes(result.size), 10);
      return `${icon} ${result.isDir ? c(PAL.bright, rel) : rel} ${c(PAL.muted, size)}`;
    });
    if (!items.length) items.push(c(PAL.dim, `未找到匹配「${escapeTags(this.searchQuery)}」的文件`));
    const previous = this.list.selected ?? 0;
    this.list.setItems(items);
    this.list.select(Math.min(previous, items.length - 1));
    this.updatePage(
      instanceService.get(this.instanceUuid)?.config.nickname ?? "",
      `搜索「${this.searchQuery}」 · ${results.length} 项`,
      t("inst.title")
    );
    this.app.ui.render();
  }

  /** Ask for a keyword and walk the instance directory (max depth 8 / 300 hits). */
  private search() {
    this.app.ui.prompt({
      title: "递归搜索文件",
      label: "文件名关键字",
      value: this.searchQuery,
      onSubmit: (value) => {
        const keyword = value.trim();
        if (!keyword) return false;
        this.searchQuery = keyword;
        const close = this.app.ui.busy("正在搜索文件…");
        void this.walkFiles(keyword.toLowerCase())
          .then((results) => {
            if (this.isDisposed) return;
            this.searchResults = results;
            this.renderSearch();
            this.app.message(`搜索完成：${results.length} 项匹配`, "info");
          })
          .catch((error) => this.app.message(error?.message ?? String(error), "error"))
          .finally(() => close());
        return true;
      }
    });
  }

  private async walkFiles(keyword: string): Promise<SearchResult[]> {
    const root = this.cwdAbsolute();
    const results: SearchResult[] = [];
    const limit = 300;
    const skip = new Set([".git", "node_modules"]);
    const visit = async (dir: string, rel: string, depth: number) => {
      if (results.length >= limit || depth > 8) return;
      let entries: any[] = [];
      try {
        entries = await fsp.readdir(dir, { withFileTypes: true });
      } catch (error) {
        return;
      }
      for (const entry of entries) {
        if (results.length >= limit) return;
        if (skip.has(entry.name)) continue;
        const childRel = rel ? path.join(rel, entry.name) : entry.name;
        const isDir = entry.isDirectory();
        if (entry.name.toLowerCase().includes(keyword)) {
          let size = 0;
          if (!isDir) {
            try {
              size = (await fsp.stat(path.join(dir, entry.name))).size;
            } catch (error) {}
          }
          results.push({ rel: childRel, isDir, size });
        }
        if (isDir) await visit(path.join(dir, entry.name), childRel, depth + 1);
      }
    };
    await visit(root, "", 0);
    return results;
  }

  private openSearchResult() {
    const result = this.searchResults?.[this.list?.selected ?? 0];
    if (!result) return;
    this.searchResults = null;
    if (result.isDir) {
      this.relPath = result.rel;
      this.selected.clear();
      void this.load();
    } else {
      this.openEditor(result.rel, path.dirname(result.rel));
    }
  }

  private targetNames(): string[] {
    if (this.selected.size) return Array.from(this.selected);
    const current = this.currentEntry();
    return current ? [current.name] : [];
  }

  private openSelected() {
    if (this.searchResults) {
      this.openSearchResult();
      return;
    }
    const index = this.list.selected ?? 0;
    if (this.showParent && index === 0) {
      this.goUp();
      return;
    }
    const entry = this.currentEntry();
    if (!entry) return;
    if (entry.type === 0) {
      this.relPath = path.normalize(path.join(this.relPath, entry.name));
      this.selected.clear();
      this.filter = "";
      void this.load();
    } else {
      this.openEditor(path.normalize(path.join(this.relPath, entry.name)), this.relPath);
    }
  }

  private openEditor(rel: string, dir: string) {
    this.app.push(
      new EditorView(this.app, this.instanceUuid, rel, () => this.app.back()),
      () => new FilesView(this.app, this.instanceUuid, dir)
    );
  }

  /** `e` edits the selected file (Enter also opens it, folders are entered). */
  private editSelected() {
    const entry = this.currentEntry();
    if (!entry || entry.type === 0) return;
    this.openEditor(path.normalize(path.join(this.relPath, entry.name)), this.relPath);
  }

  private goUp() {
    if (this.relPath === "." || this.relPath === "") return;
    const parent = path.dirname(this.relPath);
    this.relPath = parent === "." || parent === "" ? "." : parent;
    this.selected.clear();
    this.filter = "";
    void this.load();
  }

  onKey(ch: string, key: UiKey) {
    if (this.searchResults) {
      if (key.name === "escape") {
        this.searchResults = null;
        void this.load();
        return;
      }
      if (key.name === "enter" || key.name === "return") {
        this.openSearchResult();
        return;
      }
      if (ch === "f") this.search();
      return;
    }
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    if (key.name === "backspace") {
      this.goUp();
      return;
    }
    if (key.name === "space") {
      const entry = this.currentEntry();
      if (entry) {
        if (this.selected.has(entry.name)) this.selected.delete(entry.name);
        else this.selected.add(entry.name);
        this.app.message(t("files.batch", { n: this.selected.size }), "info");
        void this.load();
      }
      return;
    }
    switch (ch) {
      case "e":
        this.editSelected();
        return;
      case "n":
        this.promptCreateFile();
        return;
      case "m":
        this.promptCreateDir();
        return;
      case "r":
        this.rename();
        return;
      case "x":
        this.remove();
        return;
      case "c":
        this.copyMove(false);
        return;
      case "v":
        this.copyMove(true);
        return;
      case "z":
        this.zip();
        return;
      case "u":
        void this.unzip();
        return;
      case "p":
        this.upload();
        return;
      case "d":
        this.download();
        return;
      case "/":
        this.app.ui.prompt({
          title: t("files.search"),
          value: this.filter,
          onSubmit: (value) => {
            this.filter = value.trim();
            void this.load();
          }
        });
        return;
      case "f":
        this.search();
        return;
      case "o":
        this.openExternal();
        return;
      case "l":
        void this.load();
        return;
    }
  }

  private promptCreateFile() {
    this.app.ui.prompt({
      title: t("files.newFile"),
      onSubmit: (value) => {
        if (!value.trim()) return false;
        try {
          const fm = this.fileManager();
          fm.newFile(value.trim())
            .then(() => {
              this.app.message(t("files.created"), "success");
              return this.load();
            })
            .catch((error) => this.app.message(error?.message ?? String(error), "error"));
        } catch (error: any) {
          this.app.message(error?.message ?? String(error), "error");
        }
      }
    });
  }

  private promptCreateDir() {
    this.app.ui.prompt({
      title: t("files.newDir"),
      onSubmit: (value) => {
        if (!value.trim()) return false;
        try {
          this.fileManager().mkdir(value.trim());
          this.app.message(t("files.created"), "success");
          void this.load();
        } catch (error: any) {
          this.app.message(error?.message ?? String(error), "error");
        }
      }
    });
  }

  private rename() {
    const entry = this.currentEntry();
    if (!entry) return;
    this.app.ui.prompt({
      title: t("files.rename"),
      value: entry.name,
      onSubmit: (value) => {
        if (!value.trim() || value.trim() === entry.name) return;
        try {
          this.fileManager().rename(entry.name, value.trim());
          this.app.message(t("files.renamed"), "success");
          void this.load();
        } catch (error: any) {
          this.app.message(error?.message ?? String(error), "error");
        }
      }
    });
  }

  private remove() {
    const names = this.targetNames();
    if (!names.length) {
      this.app.message(t("files.noSelection"), "warn");
      return;
    }
    this.app.ui.confirm(t("common.confirm"), t("files.delete", { name: names.join(", ") }), () => {
      const fm = this.fileManager();
      void (async () => {
        for (const name of names) {
          try {
            await fm.delete(name);
          } catch (error: any) {
            this.app.message(error?.message ?? String(error), "error");
          }
        }
        this.selected.clear();
        opsLog.add("file delete", `${this.displayPath()} ${names.join(",")}`, "success");
        this.app.message(t("files.deleted"), "success");
        await this.load();
      })();
    });
  }

  private copyMove(move: boolean) {
    const names = this.targetNames();
    if (!names.length) return;
    this.app.ui.prompt({
      title: move ? t("files.move") : t("files.copy"),
      value: names[0],
      onSubmit: (value) => {
        if (!value.trim()) return false;
        const fm = this.fileManager();
        void (async () => {
          for (const name of names) {
            try {
              if (move) await fm.move(name, value.trim());
              else await fm.copy(name, value.trim());
            } catch (error: any) {
              this.app.message(error?.message ?? String(error), "error");
            }
          }
          this.selected.clear();
          this.app.message(move ? t("files.moved") : t("files.copied"), "success");
          await this.load();
        })();
      }
    });
  }

  private zip() {
    const names = this.targetNames();
    if (!names.length) return;
    const suggestion = names.length === 1 ? `${names[0]}.zip` : "archive.zip";
    this.app.ui.prompt({
      title: t("files.zipSelected"),
      value: suggestion,
      onSubmit: (value) => {
        if (!value.trim()) return false;
        const close = this.app.ui.busy(t("common.loading"));
        const cwd = this.cwdAbsolute();
        const outName = value.trim();
        const job = isSevenZipArchive(outName)
          ? create7z(cwd, names, path.join(cwd, outName))
          : zipEntries(cwd, names, path.join(cwd, outName));
        void job
          .then(() => {
            this.selected.clear();
            this.app.message(t("files.zipped"), "success");
            opsLog.add("file zip", `${this.displayPath()} -> ${outName}`, "success");
            return this.load();
          })
          .catch((error) => this.app.message(error?.message ?? String(error), "error"))
          .finally(() => close());
      }
    });
  }

  private async unzip() {
    const entry = this.currentEntry();
    if (!entry || entry.type === 0) return;
    const close = this.app.ui.busy(t("common.loading"));
    try {
      const cwd = this.cwdAbsolute();
      await extractArchive(path.join(cwd, entry.name), cwd);
      this.app.message(t("files.unzipped"), "success");
      await this.load();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    } finally {
      close();
    }
  }

  private upload() {
    this.app.ui.prompt({
      title: t("files.upload"),
      value: "",
      onSubmit: (value) => {
        const source = value.trim().replace(/^"|"$/g, "");
        if (!source) return false;
        if (!fs.existsSync(source)) {
          this.app.message(t("files.openedFail", { err: source }), "error");
          return false;
        }
        const close = this.app.ui.busy(t("common.loading"));
        const cwd = this.cwdAbsolute();
        const target = path.join(cwd, path.basename(source));
        void fs
          .copy(source, target, { overwrite: true })
          .then(() => {
            this.app.message(t("files.uploaded"), "success");
            opsLog.add("file upload", `${source} -> ${this.displayPath()}`, "success");
            return this.load();
          })
          .catch((error) => this.app.message(error?.message ?? String(error), "error"))
          .finally(() => close());
      }
    });
  }

  private download() {
    const entry = this.currentEntry();
    if (!entry) {
      this.app.message(t("files.noSelection"), "warn");
      return;
    }
    this.app.ui.prompt({
      title: t("files.download"),
      value: path.join(process.cwd(), entry.name),
      onSubmit: (value) => {
        const target = value.trim().replace(/^"|"$/g, "");
        if (!target) return false;
        const close = this.app.ui.busy(t("common.loading"));
        const source = path.join(this.cwdAbsolute(), entry.name);
        void fs
          .copy(source, target, { overwrite: true })
          .then(() => this.app.message(t("files.downloaded"), "success"))
          .catch((error) => this.app.message(error?.message ?? String(error), "error"))
          .finally(() => close());
      }
    });
  }

  private openExternal() {
    const entry = this.currentEntry();
    if (!entry) return;
    try {
      const abs = path.join(this.cwdAbsolute(), entry.name);
      if (!fs.existsSync(abs)) throw new Error(abs);
      if (process.platform === "win32") {
        spawn("cmd", ["/c", "start", "", abs], { detached: true, windowsHide: true }).unref();
      } else if (process.platform === "darwin") {
        spawn("open", [abs], { detached: true }).unref();
      } else {
        spawn("xdg-open", [abs], { detached: true }).unref();
      }
      this.app.message(t("files.opened"), "success");
    } catch (error: any) {
      this.app.message(t("files.openedFail", { err: error?.message ?? error }), "error");
    }
  }
}

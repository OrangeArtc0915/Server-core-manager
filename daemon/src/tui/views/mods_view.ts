import fs from "fs-extra";
import path from "path";
import { BaseView, type AppLike } from "../base";
import { c, createFlatList, escapeTags, padDisplay, PAL, truncateDisplay, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { modService, ModInfo } from "../../service/mod_service";
import downloadManager from "../../service/download_manager";
import { modrinthService, ModrinthFile, ModrinthHit } from "../service/modrinth_service";
import { spigotService, SpigotHit } from "../service/spigot_service";
import { curseForgeService, CurseForgeFile, CurseForgeHit } from "../service/curseforge_service";
import { resolveResourceUrl } from "../service/resource_mirror";
import { openExternal } from "../service/browser";
import { opsLog } from "../service/ops_log";

/** Compact download counter, e.g. 12.3M / 856k. */
function formatDownloads(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}k`;
  return String(value || 0);
}

const PAGE_SIZE = 20;

type MarketChoice =
  | { kind: "category"; label: string; type: "mod" | "plugin"; loaders: string[] }
  | { kind: "search" };

type HitChoice = { kind: "hit"; hit: ModrinthHit } | { kind: "nav"; delta: number };
type CfChoice = { kind: "hit"; hit: CurseForgeHit } | { kind: "nav"; delta: number };

export class ModsView extends BaseView {
  private list: any;
  private mods: ModInfo[] = [];
  private total = 0;
  private pageIndex = 1;
  private loading = false;

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  get title(): string {
    const name = instanceService.get(this.instanceUuid)?.config.nickname ?? "";
    return t("mods.title", { name });
  }

  get hints(): string {
    return "Space 启用/禁用  x 删除  i 推荐/安装  / 搜索  u URL 安装  [ ] 翻页  r 刷新  Esc 返回";
  }

  protected build() {
    const name = instanceService.get(this.instanceUuid)?.config.nickname ?? "";
    this.page(name, "游戏资源 · 模组 / 插件", t("inst.title"));
    this.list = createFlatList(this.root, 2);
    this.main = this.list;
    this.list.focus();
    void this.refresh();
  }

  private async refresh(): Promise<void> {
    if (!this.list || this.loading) return;
    this.loading = true;
    try {
      const result = await modService.listMods(this.instanceUuid, this.pageIndex, PAGE_SIZE * 2);
      this.mods = result.mods ?? [];
      this.total = Number(result.total) || this.mods.length;
      const pages = Math.max(1, Math.ceil(this.total / (PAGE_SIZE * 2)));
      if (this.pageIndex > pages) {
        this.pageIndex = pages;
        this.loading = false;
        await this.refresh();
        return;
      }
      const screenWidth = Number(this.app.ui.screen.width) || 120;
      const width = Math.max(20, screenWidth - 22 - 40);
      const items = this.mods.map((mod) => {
        const enabled = mod.enabled ? c(PAL.green, "[✓]") : c(PAL.dim, "[ ]");
        const type = mod.type === "plugin" ? c(PAL.magenta, "P") : mod.type === "mod" ? c(PAL.cyan, "M") : c(PAL.dim, "?");
        const name = truncateDisplay(
          `${mod.name || mod.file} ${mod.version ? `(${mod.version})` : ""}`,
          width
        );
        return `${enabled} ${type} ${c(PAL.bright, escapeTags(name))} ${c(PAL.dim, escapeTags(mod.file))}`;
      });
      if (!items.length) items.push(c(PAL.dim, t("mods.empty")));
      const previous = this.list.selected ?? 0;
      this.list.setItems(items);
      this.list.select(Math.min(previous, items.length - 1));
      this.updatePage(
        instanceService.get(this.instanceUuid)?.config.nickname ?? "",
        `${this.total} 个文件 · 第 ${this.pageIndex}/${pages} 页`,
        t("inst.title")
      );
      this.app.ui.render();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    } finally {
      this.loading = false;
    }
  }

  private selectedMod(): ModInfo | undefined {
    return this.mods[this.list?.selected ?? 0];
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    if (key.name === "space") {
      void this.toggle();
      return;
    }
    switch (ch) {
      case "x":
        this.remove();
        return;
      case "i":
        this.showMarket();
        return;
      case "/":
        this.installSearch();
        return;
      case "u":
      case "I":
        this.installFromUrl();
        return;
      case "r":
      case "R":
        void this.refresh();
        return;
      case "[":
        if (this.pageIndex > 1) {
          this.pageIndex--;
          void this.refresh();
        } else {
          this.app.message("已经是第一页", "info");
        }
        return;
      case "]":
        this.pageIndex++;
        void this.refresh();
        return;
    }
  }

  /** Recommended projects grouped by platform, sorted by downloads. */
  private showMarket() {
    const version = this.detectGameVersion();
    const categories: Array<{ label: string; type: "mod" | "plugin"; loaders: string[] }> = [
      { label: "插件 · Paper / Spigot / Bukkit", type: "plugin", loaders: ["paper", "spigot", "bukkit"] },
      { label: "模组 · Fabric", type: "mod", loaders: ["fabric"] },
      { label: "模组 · Forge", type: "mod", loaders: ["forge"] },
      { label: "模组 · NeoForge", type: "mod", loaders: ["neoforge"] }
    ];
    type MarketChoice =
      | { kind: "category"; label: string; type: "mod" | "plugin"; loaders: string[] }
      | { kind: "search" };
    this.app.ui.select<MarketChoice>(
      `游戏资源 · 推荐${version ? `（MC ${version}）` : ""}`,
      [
        ...categories.map((category) => ({
          label: `${category.label}（按下载量）`,
          value: { kind: "category" as const, ...category } as MarketChoice
        })),
        { label: "搜索关键词…", value: { kind: "search" } as MarketChoice }
      ],
      (choice) => {
        if (choice.kind === "search") {
          this.installSearch();
          return;
        }
        void this.browseRecommended(choice.type, choice.loaders, choice.label, version);
      },
      undefined,
      false
    );
  }

  private async browseRecommended(
    type: "mod" | "plugin",
    loaders: string[],
    label: string,
    version?: string,
    offset = 0,
    useVersion = true
  ): Promise<void> {
    const close = this.app.ui.busy(`正在获取${label}热门项目...`);
    const pageVersion = useVersion ? version : undefined;
    let hits: ModrinthHit[] = [];
    try {
      hits = await modrinthService.search("", type, {
        loaders,
        gameVersions: pageVersion ? [pageVersion] : undefined,
        sort: "downloads",
        limit: PAGE_SIZE,
        offset
      });
      if (!hits.length && offset === 0 && pageVersion) {
        // Some projects do not tag every game version; retry without it.
        close();
        await this.browseRecommended(type, loaders, label, version, 0, false);
        return;
      }
    } catch (error: any) {
      close();
      this.app.message(t("mods.searchFailed", { err: error?.message ?? error }), "error");
      return;
    }
    close();
    const rawCount = hits.length;
    // Modrinth's project_type facet also matches multi-type projects, so keep
    // only entries that really support the requested type.
    hits = hits.filter((hit) => hit.projectTypes.includes(type));
    if (!hits.length && offset === 0) {
      this.app.message("没有找到推荐项目", "info");
      return;
    }
    const width = Math.max(20, this.contentWidth(100) - 50);
    const items: Array<{ label: string; value: HitChoice }> = hits.map((hit) => ({
      label: `${c(PAL.bright, padDisplay(escapeTags(truncateDisplay(hit.title, 26)), 26))} ${c(
        PAL.accent,
        `↓${formatDownloads(hit.downloads)}`
      )} ${c(PAL.dim, escapeTags(truncateDisplay(hit.description, width)))}`,
      value: { kind: "hit", hit } as HitChoice
    }));
    if (hits.length === 0 && offset > 0) {
      items.push({
        label: c(PAL.dim, "本页没有匹配项目，继续下一页 →"),
        value: { kind: "nav", delta: PAGE_SIZE } as HitChoice
      });
    }
    if (offset > 0) {
      items.unshift({ label: c(PAL.accent, "← 上一页"), value: { kind: "nav", delta: -PAGE_SIZE } });
    }
    if (rawCount === PAGE_SIZE) {
      items.push({ label: c(PAL.accent, "下一页 →"), value: { kind: "nav", delta: PAGE_SIZE } });
    }
    const page = Math.floor(offset / PAGE_SIZE) + 1;
    this.app.ui.select<HitChoice>(
      `${label} · 热门${pageVersion ? ` · MC ${pageVersion}` : ""} · 第 ${page} 页`,
      items,
      (choice) => {
        if (choice.kind === "nav") {
          void this.browseRecommended(
            type,
            loaders,
            label,
            version,
            Math.max(0, offset + choice.delta),
            Boolean(pageVersion)
          );
          return;
        }
        void this.installModrinthAuto(choice.hit, type);
      },
      undefined,
      false
    );
  }

  private async toggle() {
    const mod = this.selectedMod();
    if (!mod) return;
    try {
      await modService.toggleMod(this.instanceUuid, mod.file);
      this.app.message(t("mods.toggled"), "success");
      await this.refresh();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private remove() {
    const mod = this.selectedMod();
    if (!mod) return;
    this.app.ui.confirm(t("common.confirm"), t("mods.delete", { name: escapeTags(mod.file) }), () => {
      modService
        .deleteMod(this.instanceUuid, mod.file)
        .then(() => {
          this.app.message(t("mods.deleted"), "success");
          opsLog.add("mod delete", mod.file, "success");
          return this.refresh();
        })
        .catch((error) => this.app.message(error?.message ?? String(error), "error"));
    });
  }

  private installFromUrl() {
    this.app.ui.prompt({
      title: t("mods.url"),
      label: "粘贴下载直链（文件名会自动识别）",
      value: "",
      onSubmit: (value) => {
        const url = value.trim();
        if (!url) return false;
        let fileName = "";
        try {
          fileName = path.basename(new URL(url).pathname);
        } catch (error) {
          this.app.message(t("common.invalidInput"), "error");
          return false;
        }
        if (!fileName) {
          this.app.message(t("common.invalidInput"), "error");
          return false;
        }
        this.pickInstallType((type) => {
          this.app.message(`${t("mods.installing")} ${fileName}`, "info");
          void this.installWithProgress(fileName, () =>
            modService.installMod(this.instanceUuid, url, fileName, type)
          );
        });
      }
    });
  }

  private pickInstallType(onPick: (type: "mod" | "plugin") => void) {
    this.app.ui.select(
      t("mods.installType"),
      [
        { label: "模组（放进 mods 目录，Fabric/Forge 等）", value: "mod" as const },
        { label: "插件（放进 plugins 目录，Spigot/Paper 等）", value: "plugin" as const }
      ],
      (type) => onPick(type),
      undefined,
      false
    );
  }

  /** One-key install: search a source, pick a project and install the best file. */
  private installSearch() {
    this.app.ui.prompt({
      title: "一键安装",
      label: "搜索模组 / 插件关键词",
      value: "",
      onSubmit: (value) => {
        const query = value.trim();
        if (!query) return false;
        this.app.ui.select(
          t("mods.source"),
          [
            { label: "Modrinth（推荐，支持模组与插件）", value: "modrinth" as const },
            { label: "CurseForge（模组 / 插件，镜像加速）", value: "curseforge" as const },
            { label: "SpigotMC（仅插件）", value: "spigot" as const }
          ],
          (source) => {
            if (source === "spigot") {
              void this.searchSpigot(query);
              return;
            }
            const run = (type: "mod" | "plugin") => {
              if (source === "curseforge") void this.searchCurseForge(query, type);
              else void this.searchModrinth(query, type);
            };
            // Detect from the instance layout so most users need no extra step.
            const detected = this.detectType();
            if (detected) run(detected);
            else this.pickInstallType(run);
          },
          undefined,
          false
        );
      }
    });
  }

  /** `mods/` vs `plugins/` tells us what this instance can load. */
  private detectType(): "mod" | "plugin" | undefined {
    try {
      const cwd = instanceService.getInstanceCwd(this.instanceUuid);
      const jars = fs
        .readdirSync(cwd)
        .filter((name) => name.toLowerCase().endsWith(".jar"))
        .join(" ")
        .toLowerCase();
      if (/paper|spigot|bukkit|purpur|folia/.test(jars)) return "plugin";
      if (/fabric|forge|neoforge|quilt/.test(jars)) return "mod";
      const hasMods = fs.existsSync(path.join(cwd, "mods"));
      const hasPlugins = fs.existsSync(path.join(cwd, "plugins"));
      if (hasPlugins && !hasMods) return "plugin";
      if (hasMods && !hasPlugins) return "mod";
    } catch (error) {
      // fall back to asking the user
    }
    return undefined;
  }

  /** Loaders that make sense for the detected instance type. */
  private loadersFor(type: "mod" | "plugin"): string[] {
    return type === "plugin"
      ? ["paper", "spigot", "bukkit", "purpur", "folia"]
      : ["fabric", "forge", "neoforge", "quilt"];
  }

  /** CurseForge numeric mod loader (1 Forge, 4 Fabric, 5 Quilt, 6 NeoForge). */
  private curseForgeLoader(type: "mod" | "plugin"): number | undefined {
    if (type === "plugin") return undefined;
    try {
      const cwd = instanceService.getInstanceCwd(this.instanceUuid);
      const jars = fs
        .readdirSync(cwd)
        .filter((name) => name.toLowerCase().endsWith(".jar"))
        .join(" ")
        .toLowerCase();
      if (/neoforge/.test(jars)) return 6;
      if (/quilt/.test(jars)) return 5;
      if (/fabric/.test(jars)) return 4;
      if (/forge/.test(jars)) return 1;
    } catch (error) {
      // no hint available
    }
    return undefined;
  }

  /** Best-effort Minecraft version of the instance (Paper history or latest log). */
  private detectGameVersion(): string | undefined {
    try {
      const cwd = instanceService.getInstanceCwd(this.instanceUuid);
      const history = path.join(cwd, ".paper", "version_history.json");
      if (fs.existsSync(history)) {
        const data = JSON.parse(fs.readFileSync(history, "utf-8"));
        const match = /MC:\s*([^)\s]+)/.exec(String(data?.currentVersion ?? ""));
        if (match) return match[1];
      }
      const log = path.join(cwd, "logs", "latest.log");
      if (fs.existsSync(log)) {
        const text = fs.readFileSync(log, "utf-8");
        const match = /Starting minecraft server version (\S+)/.exec(text);
        if (match) return match[1];
      }
    } catch (error) {
      // version filtering is optional
    }
    return undefined;
  }

  private pickBestModrinth(
    files: ModrinthFile[],
    type: "mod" | "plugin",
    version?: string
  ): ModrinthFile | undefined {
    const wanted =
      type === "plugin"
        ? ["paper", "spigot", "bukkit", "purpur", "folia"]
        : ["fabric", "forge", "neoforge", "quilt"];
    let pool = files.filter(
      (file) =>
        !file.loaders.length ||
        file.loaders.some((loader) => wanted.includes(loader.toLowerCase()))
    );
    if (!pool.length) pool = files;
    if (version) {
      const matching = pool.filter((file) => file.gameVersions.includes(version));
      if (matching.length) pool = matching;
    }
    return pool[0];
  }

  private pickBestCurseForge(
    files: CurseForgeFile[],
    type: "mod" | "plugin",
    version?: string
  ): CurseForgeFile | undefined {
    const wanted =
      type === "plugin"
        ? ["bukkit", "spigot", "paper", "purpur", "folia"]
        : ["forge", "fabric", "neoforge", "quilt"];
    let pool = files.filter((file) =>
      file.gameVersions.some((value) => wanted.includes(value.toLowerCase()))
    );
    if (!pool.length) pool = files;
    if (version) {
      const matching = pool.filter((file) => file.gameVersions.includes(version));
      if (matching.length) pool = matching;
    }
    return pool[0];
  }

  private async searchModrinth(query: string, type: "mod" | "plugin", offset = 0) {
    const close = this.app.ui.busy(t("mods.searching"));
    let hits: ModrinthHit[] = [];
    try {
      hits = await modrinthService.search(query, type, { limit: PAGE_SIZE, offset });
    } catch (error: any) {
      close();
      this.app.message(t("mods.searchFailed", { err: error?.message ?? error }), "error");
      return;
    }
    close();
    if (!hits.length && offset === 0) {
      this.app.message(t("mods.searchEmpty"), "info");
      return;
    }
    const items: Array<{ label: string; value: HitChoice }> = hits.map((hit) => ({
      label: escapeTags(
        t("mods.searchHit", {
          title: hit.title,
          type: hit.projectType,
          downloads: hit.downloads,
          slug: hit.slug
        })
      ),
      value: { kind: "hit", hit } as HitChoice
    }));
    if (offset > 0) {
      items.unshift({ label: c(PAL.accent, "← 上一页"), value: { kind: "nav", delta: -PAGE_SIZE } });
    }
    if (hits.length === PAGE_SIZE) {
      items.push({ label: c(PAL.accent, "下一页 →"), value: { kind: "nav", delta: PAGE_SIZE } });
    }
    const page = Math.floor(offset / PAGE_SIZE) + 1;
    this.app.ui.select<HitChoice>(
      `${t("mods.pickResult")} · 第 ${page} 页`,
      items,
      (choice) => {
        if (choice.kind === "nav") {
          void this.searchModrinth(query, type, Math.max(0, offset + choice.delta));
          return;
        }
        void this.installModrinthAuto(choice.hit, type);
      },
      undefined,
      false
    );
  }

  /** Pick the newest file matching the detected loader / game version. */
  private async installModrinthAuto(hit: ModrinthHit, type: "mod" | "plugin") {
    const close = this.app.ui.busy(t("common.loading"));
    const version = this.detectGameVersion();
    const loaders = this.loadersFor(type);
    let files: ModrinthFile[] = [];
    try {
      // Let Modrinth filter server-side; relax the constraints step by step.
      files = await modrinthService.versions(hit.projectId, {
        loaders,
        gameVersions: version ? [version] : undefined
      });
      if (!files.length) files = await modrinthService.versions(hit.projectId, { loaders });
      if (!files.length) files = await modrinthService.versions(hit.projectId);
    } catch (error: any) {
      close();
      this.app.message(t("mods.searchFailed", { err: error?.message ?? error }), "error");
      return;
    }
    close();
    if (!files.length) {
      this.app.message(t("mods.noFile"), "error");
      return;
    }
    const best = this.pickBestModrinth(files, type, version) ?? files[0];
    this.app.message(
      `一键安装：${hit.title} · ${best.versionName}${version ? `（${version}）` : ""}`,
      "info"
    );
    await this.installModrinthFile(best, type);
  }

  private async pickVersion(hit: ModrinthHit, type: "mod" | "plugin") {
    const close = this.app.ui.busy(t("common.loading"));
    let files: ModrinthFile[] = [];
    try {
      files = await modrinthService.versions(hit.projectId);
    } catch (error: any) {
      close();
      this.app.message(t("mods.searchFailed", { err: error?.message ?? error }), "error");
      return;
    }
    close();
    if (!files.length) {
      this.app.message(t("mods.noFile"), "error");
      return;
    }
    this.app.ui.select(
      t("mods.pickVersion"),
      files.map((file) => ({
        label: `${escapeTags(file.versionName)} ${c(
          PAL.dim,
          escapeTags(`${file.gameVersions.slice(0, 3).join(",")} ${file.loaders.slice(0, 2).join(",")}`)
        )} ${c(PAL.bright, escapeTags(file.name))}`,
        value: file
      })),
      (file) => {
        void this.installModrinthFile(file, type);
      }
    );
  }

  private async installModrinthFile(file: ModrinthFile, type: "mod" | "plugin") {
    const url = await resolveResourceUrl(file.url);
    await this.installWithProgress(file.name, () =>
      modService.installMod(this.instanceUuid, url, file.name, type, {
        fallbackUrl: url === file.url ? undefined : file.url
      })
    );
  }

  private async searchCurseForge(query: string, type: "mod" | "plugin", offset = 0) {
    const close = this.app.ui.busy(t("mods.searching"));
    let hits: CurseForgeHit[] = [];
    try {
      hits = await curseForgeService.search(query, type, { limit: PAGE_SIZE, offset });
    } catch (error: any) {
      close();
      this.app.message(t("mods.searchFailed", { err: error?.message ?? error }), "error");
      return;
    }
    close();
    if (!hits.length && offset === 0) {
      this.app.message(t("mods.searchEmpty"), "info");
      return;
    }
    const items: Array<{ label: string; value: CfChoice }> = hits.map((hit) => ({
      label: `${escapeTags(hit.name)} ${c(PAL.dim, `↓${hit.downloads}`)} ${c(
        PAL.muted,
        escapeTags(hit.author)
      )}`,
      value: { kind: "hit", hit } as CfChoice
    }));
    if (offset > 0) {
      items.unshift({ label: c(PAL.accent, "← 上一页"), value: { kind: "nav", delta: -PAGE_SIZE } });
    }
    if (hits.length === PAGE_SIZE) {
      items.push({ label: c(PAL.accent, "下一页 →"), value: { kind: "nav", delta: PAGE_SIZE } });
    }
    const page = Math.floor(offset / PAGE_SIZE) + 1;
    this.app.ui.select<CfChoice>(
      `${t("mods.pickResult")} · 第 ${page} 页`,
      items,
      (choice) => {
        if (choice.kind === "nav") {
          void this.searchCurseForge(query, type, Math.max(0, offset + choice.delta));
          return;
        }
        void this.installCurseForgeAuto(choice.hit, type);
      },
      undefined,
      false
    );
  }

  private async installCurseForgeAuto(hit: CurseForgeHit, type: "mod" | "plugin") {
    const close = this.app.ui.busy(t("common.loading"));
    const version = this.detectGameVersion();
    const loaderType = this.curseForgeLoader(type);
    let files: CurseForgeFile[] = [];
    try {
      files = await curseForgeService.files(hit.id, {
        gameVersion: version,
        modLoaderType: loaderType
      });
      if (!files.length) files = await curseForgeService.files(hit.id, { gameVersion: version });
      if (!files.length) files = await curseForgeService.files(hit.id);
    } catch (error: any) {
      close();
      this.app.message(t("mods.searchFailed", { err: error?.message ?? error }), "error");
      return;
    }
    close();
    if (!files.length) {
      this.app.message(t("mods.noFile"), "error");
      return;
    }
    const best = this.pickBestCurseForge(files, type, version) ?? files[0];
    this.app.message(
      `一键安装：${hit.name} · ${best.name}${version ? `（${version}）` : ""}`,
      "info"
    );
    await this.installCurseForgeFile(best, type);
  }

  private async pickCurseForgeFile(hit: CurseForgeHit, type: "mod" | "plugin") {
    const close = this.app.ui.busy(t("common.loading"));
    let files: CurseForgeFile[] = [];
    try {
      files = await curseForgeService.files(hit.id);
    } catch (error: any) {
      close();
      this.app.message(t("mods.searchFailed", { err: error?.message ?? error }), "error");
      return;
    }
    close();
    if (!files.length) {
      this.app.message(t("mods.noFile"), "error");
      return;
    }
    this.app.ui.select(
      t("mods.pickVersion"),
      files.map((file) => ({
        label: `${escapeTags(file.name)} ${c(
          PAL.dim,
          escapeTags(file.gameVersions.slice(0, 3).join(","))
        )}`,
        value: file
      })),
      (file) => void this.installCurseForgeFile(file, type)
    );
  }

  private async installCurseForgeFile(file: CurseForgeFile, type: "mod" | "plugin") {
    const url = await resolveResourceUrl(file.url);
    const fileName = path.basename(file.name) || `curseforge-${file.id}.jar`;
    await this.installWithProgress(fileName, () =>
      modService.installMod(this.instanceUuid, url, fileName, type, {
        fallbackUrl: url === file.url ? undefined : file.url
      })
    );
  }

  private async searchSpigot(query: string) {
    const close = this.app.ui.busy(t("mods.searching"));
    let hits: SpigotHit[] = [];
    try {
      hits = await spigotService.search(query);
    } catch (error: any) {
      close();
      this.app.message(t("mods.searchFailed", { err: error?.message ?? error }), "error");
      return;
    }
    close();
    if (!hits.length) {
      this.app.message(t("mods.searchEmpty"), "info");
      return;
    }
    this.app.ui.select(
      t("mods.pickResult"),
      hits.map((hit) => ({
        label: escapeTags(
          t("mods.spigotHit", { name: hit.name, downloads: hit.downloads, id: hit.id })
        ) + (hit.external ? ` ${c(PAL.yellow, "[外部托管]")}` : ""),
        value: hit
      })),
      (hit) => {
        if (hit.external) {
          const url = hit.externalUrl;
          if (!url) {
            this.app.message("该插件由外部站点托管，无法直接下载", "warn");
            return;
          }
          this.app.ui.confirm(
            "外部托管插件",
            `${hit.name} 不存放在 SpigotMC，需要用浏览器打开外部页面下载。`,
            () => openExternal(url)
          );
          return;
        }
        const fileName = `${hit.name.replace(/[\\/:*?"<>|]+/g, "-")}-${hit.id}.jar`;
        void this.installWithProgress(fileName, () =>
          modService.installMod(
            this.instanceUuid,
            spigotService.downloadUrl(hit.id),
            fileName,
            "plugin"
          )
        );
      }
    );
  }

  /**
   * Run a mod/plugin download while showing the animated progress overlay (the
   * same spinner used when quitting). Downloads happen in the daemon's download
   * manager, so progress is read from its task list.
   */
  private async installWithProgress(fileName: string, run: () => Promise<void>) {
    const activity = this.app.ui.activity(`下载 ${fileName}`);
    const timer = setInterval(() => {
      const task = downloadManager.tasks.find((item) => path.basename(item.path) === fileName);
      if (!task) return;
      const percent = task.total > 0 ? (task.current / task.total) * 100 : undefined;
      activity.update(`下载 ${fileName}`, percent);
    }, 300);
    try {
      await run();
      this.app.message(`${t("mods.installed")} ${fileName}`, "success");
      opsLog.add("mod install", fileName, "success");
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    } finally {
      clearInterval(timer);
      activity.close();
      if (!this.isDisposed) void this.refresh();
    }
  }
}

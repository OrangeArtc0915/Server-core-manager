import os from "os";
import { BaseView, type AppLike } from "../base";
import { c, createFlatList, escapeTags, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { boolText, formatBytes, parseBool, parseNumber } from "../format";
import { setLanguage, t } from "../lang";
import { globalConfiguration } from "../../entity/config";
import javaManager from "../../service/java_manager";
import InstanceSubsystem from "../../service/system_instance";
import { applyTheme, DEFAULT_THEME, getTheme, normalizeBackground, THEMES } from "../theme";

const FIELDS = [
  { key: "tuiLanguage", label: "set.language" },
  { key: "tuiTheme", label: "set.theme" },
  { key: "tuiBackground", label: "set.background" },
  { key: "defaultInstancePath", label: "set.defaultInstancePath" },
  { key: "defaultJavaDataPath", label: "set.defaultJavaDataPath" },
  { key: "outputBufferSize", label: "set.outputBufferSize" },
  { key: "softShutdown", label: "set.softShutdown" },
  { key: "softShutdownWaitSeconds", label: "set.softShutdownWait" }
];

const CUSTOM_BACKGROUND = "__custom__";

/** Preset page backgrounds; empty value = follow the active theme. */
const BACKGROUND_PRESETS: Array<{ label: string; value: string }> = [
  { label: "跟随主题", value: "" },
  { label: "深空蓝", value: "#101820" },
  { label: "午夜蓝", value: "#0f172a" },
  { label: "石墨灰", value: "#1c1c1e" },
  { label: "暗夜绿", value: "#0f1a16" },
  { label: "暗紫", value: "#16101f" },
  { label: "暖褐", value: "#1a1512" },
  { label: "米白（浅色）", value: "#eceff4" },
  { label: "自定义…", value: CUSTOM_BACKGROUND }
];

export class SettingsView extends BaseView {
  private list: any;
  private values: Record<string, string> = {};
  /** Guards against the same Enter/click opening a dialog twice. */
  private lastDialogAt = 0;

  constructor(app: AppLike) {
    super(app);
    this.loadValues();
  }

  get title(): string {
    return t("set.title");
  }

  get hints(): string {
    return "Enter 编辑   s 保存   L 查看日志   Esc 返回";
  }

  private loadValues() {
    const cfg = globalConfiguration.config;
    this.values = {
      tuiLanguage: cfg.tuiLanguage ?? "zh_cn",
      tuiTheme: cfg.tuiTheme ?? DEFAULT_THEME,
      tuiBackground: cfg.tuiBackground ?? "",
      defaultInstancePath: cfg.defaultInstancePath ?? "",
      defaultJavaDataPath: cfg.defaultJavaDataPath ?? "",
      outputBufferSize: String(cfg.outputBufferSize ?? 256),
      softShutdown: boolText(cfg.enableSoftShutdown),
      softShutdownWaitSeconds: String(cfg.softShutdownWaitSeconds ?? 30)
    };
  }

  protected build() {
    this.page(t("set.title"), "", undefined);
    this.list = createFlatList(this.root, 2);
    this.list.on("select", () => this.editSelected());
    this.main = this.list;
    this.list.focus();
    this.refresh();
  }

  refresh() {
    if (!this.list) return;
    const cfg = globalConfiguration.config;
    const contentWidth = this.contentWidth();
    const valueWidth = Math.max(20, contentWidth - 50);
    const items = FIELDS.map((field) => {
      const raw =
        field.key === "tuiTheme"
          ? getTheme(this.values.tuiTheme).label
          : field.key === "tuiBackground"
          ? this.values.tuiBackground || "跟随主题"
          : this.values[field.key] ?? "";
      const value = truncateDisplay(raw, valueWidth);
      return `${c(PAL.dim, padDisplay(t(field.label), 46))} ${c(PAL.text, escapeTags(value))}`;
    });
    items.push("");
    items.push(c(PAL.dim, `${t("set.dataDir")}: ${process.cwd()}`));
    items.push(c(PAL.dim, `${t("set.port")}: ${cfg.port}`));
    items.push(
      c(
        PAL.dim,
        `${t("set.sysinfo")}: ${os.hostname()}  ${os.platform()}/${os.arch()}  ${os.cpus().length} CPU  ${formatBytes(
          os.totalmem()
        )}`
      )
    );
    items.push(
      c(
        PAL.dim,
        `${t("common.instance")}: ${InstanceSubsystem.getInstances().length}   Java: ${javaManager.list().length}`
      )
    );
    items.push("");
    items.push(c(PAL.dim, t("set.about")));
    items.push(
      `${c(PAL.dim, `${t("set.aboutAuthor")}: `)}${c(PAL.text, "mmm")}   ` +
        `${c(PAL.dim, `${t("set.aboutQq")}: `)}${c(PAL.text, "1131093424")}   ` +
        `${c(PAL.dim, `${t("set.aboutLicense")}: `)}${c(PAL.text, "Apache-2.0")}`
    );
    items.push(c(PAL.dim, t("set.aboutStack")));
    const previous = this.list.selected ?? 0;
    this.list.setItems(items);
    this.list.select(Math.min(previous, items.length - 1));
    this.app.ui.render();
  }

  onTick() {
    this.refresh();
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.focusSidebar();
      return;
    }
    if (ch === "s") {
      this.save();
      return;
    }
    if (ch === "L") {
      this.app.openSection("logs");
    }
  }

  private editSelected() {
    // blessed delivers the same Enter to the freshly focused list, which would
    // immediately re-open the dialog; ignore duplicate triggers.
    if (Date.now() - this.lastDialogAt < 250) return;
    this.lastDialogAt = Date.now();

    const index = this.list?.selected ?? 0;
    const field = FIELDS[index];
    if (!field) return;
    // Open on the next tick: the Enter that opened the dialog would otherwise
    // be delivered again to the freshly focused child widget and submit it.
    setTimeout(() => {
      if (this.isDisposed) return;
      if (field.key === "tuiTheme") {
        this.chooseTheme();
        return;
      }
      if (field.key === "tuiBackground") {
        this.chooseBackground();
        return;
      }
      this.app.ui.prompt({
        title: t(field.label),
        label: t(field.label),
        value: this.values[field.key] ?? "",
        onSubmit: (value) => {
          this.values[field.key] = value.trim();
          this.refresh();
        }
      });
    }, 0);
  }

  /**
   * Rebuild the shell after a palette change. Deferred so the dialog that
   * triggered it is fully closed first — recreating the view from inside a
   * modal callback leaves blessed's focus history pointing at dead widgets.
   */
  private scheduleRestyle() {
    const app = this.app;
    setTimeout(() => app.restyle(), 0);
  }

  private persistTheme() {
    try {
      globalConfiguration.config.tuiTheme = this.values.tuiTheme;
      globalConfiguration.config.tuiBackground = this.values.tuiBackground;
      globalConfiguration.store();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  /** Pick a color theme; applies and persists immediately (no need to press s). */
  private chooseTheme() {
    const current = this.values.tuiTheme || DEFAULT_THEME;
    const items = THEMES.map((theme) => ({
      label:
        `${theme.id === current ? c(PAL.green, "●") : c(PAL.dim, "○")} ` +
        `${c(theme.palette.accent, "▇▇")} ${theme.label} ${c(PAL.dim, theme.id)}`,
      value: theme.id
    }));
    this.app.ui.select(t("set.theme"), items, (id) => {
      this.values.tuiTheme = id;
      applyTheme(id, this.values.tuiBackground);
      this.persistTheme();
      this.app.message(`${t("set.theme")}: ${getTheme(id).label}`, "success");
      this.scheduleRestyle();
    });
  }

  /** Background presets, mirroring the theme picker. */
  private chooseBackground() {
    const current = this.values.tuiBackground || "";
    const items = BACKGROUND_PRESETS.map((preset) => {
      const swatch =
        preset.value && preset.value !== CUSTOM_BACKGROUND
          ? c(preset.value, "▇▇")
          : c(PAL.dim, "▇▇");
      const mark = preset.value === current ? c(PAL.green, "●") : c(PAL.dim, "○");
      return { label: `${mark} ${swatch} ${preset.label}`, value: preset.value };
    });
    this.app.ui.select(t("set.background"), items, (value) => {
      if (value === CUSTOM_BACKGROUND) {
        // Defer: the Enter that confirmed the picker must not submit the input.
        setTimeout(() => {
          if (!this.isDisposed) this.editBackground();
        }, 0);
        return;
      }
      this.applyBackground(value);
    });
  }

  private applyBackground(hex: string) {
    this.values.tuiBackground = hex;
    applyTheme(this.values.tuiTheme, hex);
    this.persistTheme();
    this.app.message(hex ? `背景色：${hex}` : "背景色：跟随主题", "success");
    this.scheduleRestyle();
  }

  /** Custom #rrggbb entry (advanced); empty resets to the theme default. */
  private editBackground() {
    this.app.ui.prompt({
      title: t("set.background"),
      label: "输入 #rrggbb；留空 = 跟随主题（浅色背景会自动切换深色文字）",
      value: this.values.tuiBackground,
      onSubmit: (value) => {
        const text = value.trim();
        const hex = normalizeBackground(text);
        if (text && !hex) {
          this.app.message("颜色格式应为 #rrggbb，例如 #1a1b26", "error");
          return false;
        }
        this.applyBackground(hex ?? "");
        return true;
      }
    });
  }

  private save() {
    const cfg = globalConfiguration.config;
    try {
      cfg.tuiLanguage = this.values.tuiLanguage || "zh_cn";
      cfg.tuiTheme = this.values.tuiTheme || DEFAULT_THEME;
      cfg.tuiBackground = normalizeBackground(this.values.tuiBackground) ?? "";
      applyTheme(cfg.tuiTheme, cfg.tuiBackground);
      cfg.defaultInstancePath = this.values.defaultInstancePath;
      cfg.defaultJavaDataPath = this.values.defaultJavaDataPath;
      const buffer = parseNumber(this.values.outputBufferSize, 256);
      cfg.outputBufferSize = Math.min(4096, Math.max(16, buffer));
      cfg.enableSoftShutdown = parseBool(this.values.softShutdown);
      cfg.softShutdownWaitSeconds = Math.max(
        0,
        parseNumber(this.values.softShutdownWaitSeconds, 30)
      );
      globalConfiguration.store();
      setLanguage(cfg.tuiLanguage);
      this.app.rebuildSidebar();
      this.app.message(t("set.saved"), "success");
      this.loadValues();
      this.refresh();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }
}

import { BaseView, type AppLike } from "../base";
import { blessed, c, escapeTags, PAL, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { mslService } from "../service/msl_service";
import { vanillaService } from "../service/vanilla_service";
import { opsLog } from "../service/ops_log";

// Paper-family jars download the vanilla server jar from Mojang on first start.
const PAPERCLIP_SERVERS = new Set(["paper", "purpur", "folia", "leaves", "pufferfish", "pufferfish_purpur"]);

export class MslView extends BaseView {
  private panel: any;

  constructor(app: AppLike) {
    super(app);
  }

  get title(): string {
    return t("msl.title");
  }

  get hints(): string {
    return t("msl.note");
  }

  protected build() {
    this.page(t("msl.title"), "", t("inst.title"));
    this.panel = blessed.box({
      parent: this.root,
      top: 2,
      left: 0,
      right: 0,
      bottom: 0,
      tags: true,
      style: { bg: PAL.bg, fg: PAL.text },
      padding: { left: 2, right: 2, top: 1 },
      content: [
        c(PAL.accent, "MSL"),
        "",
        c(PAL.muted, t("msl.note")),
        "",
        c(PAL.dim, "选择服务端 → 选择版本 → 输入实例名，下载完成后会自动识别启动命令。")
      ].join("\n")
    });
    void this.loadServers();
  }

  private async loadServers() {
    const close = this.app.ui.busy(t("msl.loading"));
    let servers: Record<string, string[]>;
    try {
      servers = await mslService.getServerList();
    } catch (error: any) {
      close();
      this.app.message(t("msl.failed", { err: error?.message ?? error }), "error");
      this.app.back();
      return;
    }
    close();
    const items: { label: string; value: { category: string; server: string } }[] = [];
    for (const category of Object.keys(servers)) {
      for (const server of servers[category]) {
        items.push({
          label: `${escapeTags(category)} / ${c(PAL.accent, escapeTags(server))}`,
          value: { category, server }
        });
      }
    }
    if (!items.length) {
      this.app.message(t("msl.noVersion"), "error");
      this.app.back();
      return;
    }
    this.app.ui.select(
      t("msl.selectServer"),
      items,
      (value) => void this.loadVersions(value.category, value.server),
      () => this.app.back()
    );
  }

  private async loadVersions(category: string, server: string) {
    const close = this.app.ui.busy(t("common.loading"));
    let versions: string[] = [];
    try {
      const result = await mslService.getVersions(server);
      versions = result.versions;
    } catch (error: any) {
      close();
      this.app.message(t("msl.failed", { err: error?.message ?? error }), "error");
      this.app.back();
      return;
    }
    close();
    if (!versions.length) {
      this.app.message(t("msl.noVersion"), "error");
      this.app.back();
      return;
    }
    this.app.ui.select(
      t("msl.selectVersion", { server }),
      versions.map((version) => ({ label: escapeTags(version), value: version })),
      (version) => void this.loadBuilds(category, server, version),
      () => this.app.back()
    );
  }

  /** Forge-style cores publish several builds; pick one when there is a choice. */
  private async loadBuilds(category: string, server: string, version: string) {
    let builds: string[] = [];
    const close = this.app.ui.busy(t("common.loading"));
    try {
      builds = await mslService.getServerBuilds(server, version);
    } catch (error) {
      // builds are optional, fall back to "latest"
    }
    close();
    if (builds.length > 1) {
      this.app.ui.select(
        `选择构建 - ${escapeTags(server)} ${escapeTags(version)}`,
        builds.map((build) => ({ label: escapeTags(build), value: build })),
        (build) => this.askName(category, server, version, build),
        () => this.app.back()
      );
      return;
    }
    this.askName(category, server, version, builds[0] ?? "latest");
  }

  private askName(category: string, server: string, version: string, build: string) {
    const defaultName = `${server}-${version}`.replace(/[\\/:*?"<>|\s]+/g, "-");
    this.app.ui.prompt({
      title: t("msl.instanceName"),
      label: `${escapeTags(server)} ${c(PAL.dim, escapeTags(version))}`,
      value: defaultName,
      onSubmit: (name) => {
        const instanceName = name.trim();
        if (!instanceName) return false;
        void this.install(category, server, version, build, instanceName);
      },
      onCancel: () => this.app.back()
    });
  }

  private async install(
    category: string,
    server: string,
    version: string,
    build: string,
    instanceName: string
  ) {
    const close = this.app.ui.busy(t("common.loading"));
    let url = "";
    try {
      url = await mslService.getDownloadUrl(server, version, build);
    } catch (error: any) {
      close();
      this.app.message(t("msl.failed", { err: error?.message ?? error }), "error");
      this.app.back();
      return;
    }
    close();
    const kind: "java" | "bedrock" = /bedrock|基岩/i.test(category) ? "bedrock" : "java";
    try {
      const task = instanceService.quickInstall(url, instanceName, {
        type: kind === "bedrock" ? "minecraft/bedrock/bds" : "minecraft/java",
        startCommand: ""
      } as any);
      const instanceUuid = task.instance.instanceUuid;
      instanceService.markInstalling(instanceUuid, kind);
      this.app.message(t("msl.installing"), "success");
      this.trackInstall(instanceUuid, instanceName);
      this.prefetchVanilla(instanceUuid, server, version);
      this.app.back();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
      this.app.back();
    }
  }

  /** Non-blocking download animation (same spinner as the quit overlay). */
  private trackInstall(instanceUuid: string, instanceName: string) {
    const activity = this.app.ui.activity(`下载 ${instanceName}`);
    let idle = 0;
    const timer = setInterval(() => {
      const progress = instanceService.getInstallProgress(instanceUuid);
      if (!progress) {
        if (++idle >= 4) {
          clearInterval(timer);
          activity.close();
        }
        return;
      }
      idle = 0;
      const phase = progress.phase === "extract" ? "解压" : "下载";
      activity.update(`${instanceName} ${phase}`, progress.percentage);
    }, 500);
  }

  /** Pre-fetch the vanilla server jar used by paperclip builds (BMCLAPI). */
  private prefetchVanilla(instanceUuid: string, server: string, version: string) {
    if (!PAPERCLIP_SERVERS.has(server.toLowerCase())) return;
    let lastPercent = -1;
    this.app.message(`正在预下载原版服务端 ${version}（BMCLAPI 镜像）…`, "info");
    void vanillaService
      .prefetch(instanceUuid, version, (progress) => {
        if (progress.percent === lastPercent) return;
        if (progress.percent === 0 || progress.percent % 10 !== 0) return;
        lastPercent = progress.percent;
        this.app.message(`预下载原版服务端 ${version}：${progress.percent}%`, "info");
      })
      .then(() => {
        this.app.message(`原版服务端已缓存（${version}），首次启动无需再下载`, "success");
        opsLog.add("vanilla prefetch", `${server}-${version}`, "success");
      })
      .catch((error) => {
        this.app.message(`原版服务端预下载失败（启动时仍会自动重试）：${error?.message ?? error}`, "warn");
      });
  }

  onKey(_ch: string, key: UiKey) {
    if (key.name === "escape") this.app.back();
  }
}

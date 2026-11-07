import { BaseView, type AppLike } from "../base";
import { c, createFlatList, escapeTags, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { javaService, JavaRuntimeView } from "../service/java_service";
import { opsLog } from "../service/ops_log";

export class JavaView extends BaseView {
  private list: any;
  private runtimes: JavaRuntimeView[] = [];

  constructor(app: AppLike, private readonly instanceUuid?: string) {
    super(app);
  }

  get title(): string {
    return t("java.title");
  }

  get hints(): string {
    return "a 添加  d 下载  s 扫描系统  x 删除  b 绑定到实例  Enter 详情  Esc 返回";
  }

  protected build() {
    this.page(t("java.title"), "", this.instanceUuid ? t("inst.title") : undefined);
    this.list = createFlatList(this.root, 2);
    this.list.on("select", () => {
      if (this.instanceUuid) this.assign();
      else this.showRuntimeInfo();
    });
    this.main = this.list;
    this.list.focus();
    this.refresh();
  }

  refresh() {
    if (!this.list) return;
    this.runtimes = javaService.list();
    const screenWidth = this.contentWidth();
    const pathWidth = Math.max(20, screenWidth - 56);
    const items = this.runtimes.map((runtime) => {
      const state = runtime.downloading
        ? c(PAL.yellow, `下载 ${String(runtime.progress ?? 0).padStart(3, " ")}%`)
        : c(PAL.green, "● 已安装");
      const using = runtime.usingInstances.length
        ? ` ${c(PAL.magenta, `×${runtime.usingInstances.length}`)}`
        : "";
      return (
        `${state}  ${c(PAL.bright, padDisplay(truncateDisplay(runtime.id, 22), 22))} ` +
        `${c(PAL.muted, padDisplay(runtime.version ?? "-", 6))} ` +
        `${c(PAL.dim, escapeTags(truncateDisplay(runtime.path ?? "-", pathWidth)))}${using}`
      );
    });
    if (!items.length) items.push(c(PAL.dim, t("java.empty")));
    const previous = this.list.selected ?? 0;
    this.list.setItems(items);
    this.list.select(Math.min(previous, items.length - 1));
    this.updatePage(t("java.title"), `${this.runtimes.length} 个运行时`, this.instanceUuid ? t("inst.title") : "");
    this.app.ui.render();
  }

  onTick() {
    this.refresh();
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      if (this.instanceUuid) this.app.back();
      else this.app.focusSidebar();
      return;
    }
    switch (ch) {
      case "a":
        this.addLocal();
        return;
      case "b":
        this.assign();
        return;
      case "x":
        this.remove();
        return;
      case "d":
        this.download();
        return;
      case "s":
        void this.scan();
        return;
      case "r":
        this.refresh();
        return;
    }
  }

  /** Enter on a runtime: show details (global page) instead of a popup. */
  private showRuntimeInfo() {
    const runtime = this.selectedRuntime();
    if (!runtime) {
      this.app.message(t("java.empty"), "info");
      return;
    }
    const using = runtime.usingInstances
      .map((uuid) => instanceService.get(uuid)?.config.nickname ?? uuid)
      .join(", ");
    const lines = [
      `ID        ${runtime.id}`,
      `版本      ${runtime.version ?? "-"}`,
      `状态      ${runtime.downloading ? `下载 ${runtime.progress ?? 0}%` : "已安装"}`,
      `路径      ${runtime.path ?? "-"}`,
      `绑定实例  ${using || "-"}`,
      "",
      "按 b 可把这个运行时绑定到指定实例。"
    ];
    this.app.ui.alert(`Java · ${runtime.id}`, lines.map((line) => escapeTags(line)).join("\n"));
  }

  private selectedRuntime(): JavaRuntimeView | undefined {
    return this.runtimes[this.list?.selected ?? 0];
  }

  private addLocal() {
    this.app.ui.form({
      title: t("java.hint"),
      fields: [
        { key: "name", label: t("java.addName"), value: "java" },
        { key: "path", label: t("java.addPath"), value: "" }
      ],
      onSubmit: (values) => {
        try {
          javaService.addLocal(values.name.trim(), values.path.trim());
          this.app.message(t("common.success"), "success");
          this.refresh();
        } catch (error: any) {
          return error?.message ?? String(error);
        }
      }
    });
  }

  private download() {
    const options = [
      { label: "Java 21   ·   推荐（1.20.5 及以上）", value: "21" },
      { label: "Java 17   ·   1.18 ~ 1.20.4", value: "17" },
      { label: "Java 8    ·   1.16.5 及更早版本", value: "8" },
      { label: "Java 25   ·   最新 LTS", value: "25" }
    ];
    this.app.ui.select(
      t("java.downloadName"),
      options,
      (version) => {
        this.app.message(`Java ${version} 开始下载（后台进行，可继续操作）`, "info");
        javaService
          .download("temurin", version, () => this.refresh())
          .then((id) => {
            this.app.message(`Java ${version} 安装完成：${id}`, "success");
            opsLog.add("java install", `${version} -> ${id}`, "success");
            this.refresh();
          })
          .catch((error) => {
            this.app.message(`Java ${version} 下载失败：${error?.message ?? error}`, "error");
            this.refresh();
          });
        this.refresh();
      },
      undefined,
      false
    );
  }

  private async scan() {
    const close = this.app.ui.busy(t("java.scan"));
    try {
      const added = javaService.scanSystem();
      close();
      this.app.message(
        added ? t("java.scanned", { n: added }) : t("java.scanEmpty"),
        added ? "success" : "warn"
      );
      this.refresh();
    } catch (error: any) {
      close();
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private remove() {
    const runtime = this.selectedRuntime();
    if (!runtime) return;
    this.app.ui.confirm(t("common.confirm"), t("java.delete", { name: escapeTags(runtime.id) }), () => {
      javaService
        .remove(runtime.id)
        .then(() => {
          this.app.message(t("java.deleted"), "success");
          opsLog.add("java remove", runtime.id, "success");
          this.refresh();
        })
        .catch((error) => this.app.message(error?.message ?? String(error), "error"));
    });
  }

  private assign() {
    const runtime = this.selectedRuntime();
    if (!runtime) return;
    if (this.instanceUuid) {
      this.applyAssign(runtime, this.instanceUuid);
      return;
    }
    this.app.ui.select(
      t("java.assign"),
      instanceService.list().map((instance) => ({
        label: escapeTags(instance.config.nickname),
        value: instance.instanceUuid
      })),
      (uuid) => this.applyAssign(runtime, uuid)
    );
  }

  private applyAssign(runtime: JavaRuntimeView, instanceUuid: string) {
    try {
      instanceService.setJava(instanceUuid, runtime.id);
      const name = instanceService.get(instanceUuid)?.config.nickname ?? instanceUuid;
      this.app.message(t("java.assigned", { java: runtime.id, instance: name }), "success");
      opsLog.add("java assign", `${runtime.id} -> ${name}`, "success");
      this.refresh();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }
}

import { BaseView, type AppLike } from "../base";
import { c, createFlatList, escapeTags, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { formatBytes, formatDateTime } from "../format";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { backupService, BackupEntry } from "../service/backup_service";
import { autoBackupService } from "../service/auto_backup";
import { opsLog } from "../service/ops_log";

export class BackupsView extends BaseView {
  private list: any;
  private backups: BackupEntry[] = [];
  private instances: Array<{ uuid: string; nickname: string; count: number; latest: number }> = [];

  constructor(app: AppLike, private readonly instanceUuid?: string) {
    super(app);
  }

  get title(): string {
    return this.instanceUuid
      ? `${t("backup.title")} · ${instanceService.get(this.instanceUuid)?.config.nickname ?? ""}`
      : `${t("backup.title")} · 选择实例`;
  }

  get hints(): string {
    if (!this.instanceUuid) {
      return "↑↓ 选择实例  Enter 查看备份  n 新建备份  Esc 返回";
    }
    return `${t("backup.hint")}   a 定时备份`;
  }

  protected build() {
    this.page(this.title, "", this.instanceUuid ? t("inst.title") : undefined);
    this.list = createFlatList(this.root, 2);
    this.list.on("select", () => this.onSelect());
    this.main = this.list;
    this.list.focus();
    this.refresh();
  }

  refresh() {
    if (!this.list) return;
    if (this.instanceUuid) {
      this.backups = backupService.list(this.instanceUuid);
      const width = this.contentWidth();
      const nameWidth = Math.max(24, width - 44);
      const items = this.backups.map(
        (backup) =>
          `${c(PAL.bright, padDisplay(truncateDisplay(backup.name, nameWidth), nameWidth))} ` +
          `${c(PAL.muted, padDisplay(formatBytes(backup.size), 10))} ${c(PAL.dim, formatDateTime(backup.time))}`
      );
      if (!items.length) items.push(c(PAL.dim, t("backup.empty")));
      const previous = this.list.selected ?? 0;
      this.list.setItems(items);
      this.list.select(Math.min(previous, items.length - 1));
      const auto = autoBackupService.get(this.instanceUuid);
      const autoText = auto
        ? ` · 定时备份：每 ${auto.intervalHours} 小时保留 ${auto.keep} 份`
        : "";
      this.updatePage(this.title, `${this.backups.length} 个备份${autoText}`, t("inst.title"));
    } else {
      this.instances = instanceService.list().map((instance) => {
        const backups = backupService.list(instance.instanceUuid);
        return {
          uuid: instance.instanceUuid,
          nickname: instance.config.nickname,
          count: backups.length,
          latest: backups[0]?.time ?? 0
        };
      });
      const width = this.contentWidth();
      const nameWidth = Math.max(20, width - 40);
      const items = this.instances.map(
        (item) =>
          `${c(PAL.bright, padDisplay(truncateDisplay(item.nickname, nameWidth), nameWidth))} ` +
          `${c(PAL.accent, padDisplay(`${item.count}`, 4))} ${c(PAL.dim, item.latest ? formatDateTime(item.latest) : "-")}`
      );
      if (!items.length) items.push(c(PAL.dim, t("inst.empty")));
      const previous = this.list.selected ?? 0;
      this.list.setItems(items);
      this.list.select(Math.min(previous, items.length - 1));
      this.updatePage(t("backup.title"), `${this.instances.length} 个实例`);
    }
    this.app.ui.render();
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      if (this.instanceUuid) this.app.back();
      else this.app.focusSidebar();
      return;
    }
    if (ch === "n") {
      void this.create();
      return;
    }
    if (ch === "r") {
      this.refresh();
      return;
    }
    if (ch === "a") {
      this.configureAuto();
      return;
    }
    if (!this.instanceUuid) return;
    if (ch === "x") this.remove();
  }

  /** Per-instance automatic backup schedule (interval in hours + keep count). */
  private configureAuto() {
    if (!this.instanceUuid) return;
    const current = autoBackupService.get(this.instanceUuid);
    this.app.ui.form({
      title: "定时备份",
      hint: "间隔填 0 表示关闭；仅备份已停止的实例。",
      fields: [
        { key: "interval", label: "备份间隔（小时）", value: String(current?.intervalHours ?? 0) },
        { key: "keep", label: "保留份数", value: String(current?.keep ?? 5) }
      ],
      onSubmit: (values) => {
        const interval = Number(values.interval.trim());
        const keep = Number(values.keep.trim());
        if (!Number.isFinite(interval) || interval < 0) return "间隔必须是 0 或正数";
        if (!Number.isFinite(keep) || keep < 1) return "保留份数至少为 1";
        autoBackupService.set(this.instanceUuid!, interval, keep);
        const name = instanceService.get(this.instanceUuid!)?.config.nickname ?? "";
        opsLog.add(
          "auto backup",
          `${name} interval=${interval}h keep=${keep}`,
          "success"
        );
        this.app.message(
          interval > 0 ? `已开启定时备份：每 ${interval} 小时，保留 ${keep} 份` : "已关闭定时备份",
          "success"
        );
        this.refresh();
      }
    });
  }

  private onSelect() {
    if (this.instanceUuid) {
      void this.restore();
      return;
    }
    const item = this.instances[this.list?.selected ?? 0];
    if (!item) return;
    this.app.push(new BackupsView(this.app, item.uuid), () => new BackupsView(this.app));
  }

  private targetUuid(): string | undefined {
    if (this.instanceUuid) return this.instanceUuid;
    return this.instances[this.list?.selected ?? 0]?.uuid;
  }

  private async create() {
    const uuid = this.targetUuid();
    if (!uuid) {
      this.app.message(t("inst.selectFirst"), "warn");
      return;
    }
    const close = this.app.ui.busy(t("backup.create"));
    try {
      const entry = await backupService.create(uuid);
      this.app.message(t("backup.created", { name: entry.name }), "success");
      const name = instanceService.get(uuid)?.config.nickname ?? uuid;
      opsLog.add("backup create", `${name} ${entry.name}`, "success");
      this.refresh();
    } catch (error: any) {
      this.app.message(t("backup.failed", { err: error?.message ?? error }), "error");
    } finally {
      close();
    }
  }

  private async restore() {
    const backup = this.backups[this.list?.selected ?? 0];
    if (!backup || !this.instanceUuid) return;
    this.app.ui.confirm(
      t("common.confirm"),
      t("backup.restore", { name: escapeTags(backup.name) }),
      () => {
        const close = this.app.ui.busy(t("common.loading"));
        void backupService
          .restore(this.instanceUuid!, backup.name)
          .then(() => {
            this.app.message(t("backup.restored"), "success");
            const name = instanceService.get(this.instanceUuid!)?.config.nickname ?? "";
            opsLog.add("backup restore", `${name} ${backup.name}`, "success");
          })
          .catch((error) => this.app.message(error?.message ?? String(error), "error"))
          .finally(() => close());
      }
    );
  }

  private remove() {
    const backup = this.backups[this.list?.selected ?? 0];
    if (!backup || !this.instanceUuid) return;
    this.app.ui.confirm(t("common.confirm"), t("backup.delete", { name: escapeTags(backup.name) }), () => {
      backupService.remove(this.instanceUuid!, backup.name);
      this.app.message(t("files.deleted"), "success");
      opsLog.add("backup delete", backup.name, "success");
      this.refresh();
    });
  }
}

import { BaseView, type AppLike } from "../base";
import { c, createFlatList, escapeTags, PAL, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { opsLog } from "../service/ops_log";
import { autoBackupService } from "../service/auto_backup";
import InstanceControl from "../../service/system_instance_control";

const ACTION_MAP: Record<string, string> = {
  "1": "start",
  "2": "stop",
  "3": "restart",
  "4": "kill",
  "5": "command",
  "6": "delay"
};

const ACTION_LABEL_KEY: Record<string, string> = {
  start: "sch.action1",
  stop: "sch.action2",
  restart: "sch.action3",
  kill: "sch.action4",
  command: "sch.action5",
  delay: "sch.action6"
};

const ACTION_INDEX: Record<string, string> = {
  start: "1",
  stop: "2",
  restart: "3",
  kill: "4",
  command: "5",
  delay: "6"
};

export class ScheduleView extends BaseView {
  private list: any;
  private tasks: any[] = [];

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  get title(): string {
    const name = instanceService.get(this.instanceUuid)?.config.nickname ?? "";
    return t("sch.title", { name });
  }

  get hints(): string {
    return "a 新建   e 编辑   r 立即执行   x 删除   d 每日重启+备份   Enter 详情   Esc 返回";
  }

  protected build() {
    const name = instanceService.get(this.instanceUuid)?.config.nickname ?? "";
    this.page(name, "计划任务", t("inst.title"));
    this.list = createFlatList(this.root, 2);
    this.list.on("select", () => this.showDetail());
    this.main = this.list;
    this.list.focus();
    this.refresh();
  }

  refresh() {
    if (!this.list) return;
    this.tasks = instanceService.schedules(this.instanceUuid);
    const items = this.tasks.map((task) => {
      const typeLabel =
        task.type === 1 ? t("sch.type1") : task.type === 2 ? t("sch.type2") : t("sch.type3");
      const actions = (task.actions ?? [])
        .map((action: any) => t(ACTION_LABEL_KEY[action.type] ?? "sch.action5"))
        .join(" → ");
      return (
        `${c(PAL.bright, escapeTags(task.name))}  ` +
        `${c(PAL.muted, `${typeLabel} ${escapeTags(String(task.time))}`)}  ` +
        `${c(PAL.accent, actions)}  ${c(PAL.dim, `×${task.count}`)}`
      );
    });
    if (!items.length) items.push(c(PAL.dim, t("sch.empty")));
    const previous = this.list.selected ?? 0;
    this.list.setItems(items);
    this.list.select(Math.min(previous, items.length - 1));
    this.updatePage(
      instanceService.get(this.instanceUuid)?.config.nickname ?? "",
      `${this.tasks.length} 个任务`,
      t("inst.title")
    );
    this.app.ui.render();
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    switch (ch) {
      case "a":
        this.create();
        return;
      case "e":
        this.edit();
        return;
      case "r":
        void this.run();
        return;
      case "x":
        this.remove();
        return;
      case "d":
        this.dailyRestart();
        return;
    }
  }

  /**
   * One-click "restart every day + daily backup": creates a cron task that
   * flushes and restarts the server, and enables the 24h auto backup.
   */
  private dailyRestart() {
    this.app.ui.form({
      title: "每日重启 + 备份",
      hint: "创建每天定时重启任务，并开启每 24 小时自动备份",
      fields: [
        { key: "hour", label: "每天几点重启（0-23）", value: "4" },
        { key: "keep", label: "自动备份保留份数", value: "5" }
      ],
      onSubmit: (values) => {
        const hour = Number(values.hour.trim());
        const keep = Number(values.keep.trim());
        if (!Number.isInteger(hour) || hour < 0 || hour > 23) return "小时必须是 0-23 的整数";
        if (!Number.isInteger(keep) || keep < 1) return "保留份数至少为 1";
        try {
          if (this.tasks.some((task) => task.name === "daily-restart")) {
            instanceService.deleteSchedule(this.instanceUuid, "daily-restart");
          }
          InstanceControl.registerScheduleJob({
            instanceUuid: this.instanceUuid,
            name: "daily-restart",
            count: -1,
            time: `0 ${hour} * * *`,
            action: undefined,
            payload: undefined,
            actions: [
              { type: "command", payload: "save-all" },
              { type: "delay", payload: "3000" },
              { type: "restart", payload: "" }
            ],
            type: 2
          } as any);
          autoBackupService.set(this.instanceUuid, 24, keep);
          this.app.message(
            `已创建每天 ${hour}:00 重启任务，并开启每 24 小时自动备份（保留 ${keep} 份）`,
            "success"
          );
          opsLog.add("schedule daily restart", String(hour), "success");
          this.refresh();
        } catch (error: any) {
          return error?.message ?? String(error);
        }
      }
    });
  }

  private selectedTask() {
    return this.tasks[this.list?.selected ?? 0];
  }

  private showDetail() {
    const task = this.selectedTask();
    if (!task) return;
    const actions = (task.actions ?? [])
      .map(
        (action: any) =>
          `${t(ACTION_LABEL_KEY[action.type] ?? "sch.action5")} (${escapeTags(action.payload ?? "")})`
      )
      .join("\n");
    this.app.ui.alert(
      escapeTags(task.name),
      `${t("common.type")}: ${task.type}\n${t("common.time")}: ${escapeTags(String(task.time))}\n${t(
        "sch.field.count"
      )}: ${task.count}\n\n${actions}`
    );
  }

  private actionsText(task: any): string {
    return (task.actions ?? []).map((action: any) => action.type).join(",");
  }

  private openForm(task?: any) {
    const action = task?.actions?.[0];
    this.app.ui.form({
      title: task ? t("sch.edit") : t("sch.add"),
      hint: t("sch.cronHint"),
      fields: [
        { key: "name", label: t("sch.field.name"), value: task?.name ?? `task-${this.tasks.length + 1}` },
        { key: "type", label: t("sch.field.type"), value: String(task?.type ?? 1) },
        { key: "time", label: t("sch.field.time"), value: String(task?.time ?? "3600") },
        {
          key: "action",
          label: t("sch.field.action"),
          value: ACTION_INDEX[action?.type ?? "restart"] ?? "3"
        },
        { key: "payload", label: t("sch.field.payload"), value: String(action?.payload ?? "") },
        { key: "count", label: t("sch.field.count"), value: String(task?.count ?? -1) }
      ],
      onSubmit: (values) => {
        const name = values.name.trim();
        const type = Number(values.type.trim()) || 1;
        const actionType = ACTION_MAP[values.action.trim()] ?? "command";
        const count = Number(values.count.trim());
        if (!name) return t("common.required");
        if (actionType === "command" && !values.payload.trim()) return t("common.required");
        try {
          if (task) instanceService.deleteSchedule(this.instanceUuid, task.name);
          instanceService.addSchedule(this.instanceUuid, {
            name,
            type,
            time: values.time.trim(),
            action: actionType,
            payload: values.payload.trim(),
            count: Number.isFinite(count) ? count : -1
          });
          this.app.message(task ? t("sch.added") : t("sch.added"), "success");
          opsLog.add(task ? "schedule edit" : "schedule add", name, "success");
          this.refresh();
        } catch (error: any) {
          return error?.message ?? String(error);
        }
      }
    });
  }

  private create() {
    this.openForm();
  }

  private edit() {
    const task = this.selectedTask();
    if (task) this.openForm(task);
  }

  private async run() {
    const task = this.selectedTask();
    if (!task) return;
    try {
      await InstanceControl.action(task);
      this.app.message(t("sch.ran"), "success");
      opsLog.add("schedule run", task.name, "success");
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private remove() {
    const task = this.selectedTask();
    if (!task) return;
    this.app.ui.confirm(t("common.confirm"), t("sch.delete", { name: escapeTags(task.name) }), () => {
      try {
        instanceService.deleteSchedule(this.instanceUuid, task.name);
        this.app.message(t("sch.deleted"), "success");
        opsLog.add("schedule delete", task.name, "success");
        this.refresh();
      } catch (error: any) {
        this.app.message(error?.message ?? String(error), "error");
      }
    });
  }
}

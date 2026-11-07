import { BaseView, type AppLike } from "../base";
import { blessed, c, PAL, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";

export class CreateView extends BaseView {
  private panel: any;

  constructor(app: AppLike) {
    super(app);
  }

  get title(): string {
    return t("create.title");
  }

  get hints(): string {
    return t("create.hint");
  }

  protected build() {
    this.page(t("create.title"), "", t("inst.title"));
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
        c(PAL.accent, t("create.mode")),
        "",
        c(PAL.muted, "· " + t("create.mode.blank")),
        c(PAL.muted, "· " + t("create.mode.mirror")),
        "",
        c(PAL.dim, t("create.jarcmd", { mcsm_java: "{mcsm_java}" })),
        c(PAL.dim, t("create.powdershell")),
        "",
        c(PAL.dim, t("cfg.typeHint"))
      ].join("\n")
    });
    this.openForm();
  }

  private openForm() {
    const defaultName = `mc-${instanceService.list().length + 1}`;
    this.app.ui.form({
      title: t("create.title"),
      hint: t("create.hint"),
      fields: [
        { key: "nickname", label: t("create.name"), value: defaultName },
        { key: "type", label: t("create.type"), value: "minecraft/java" },
        { key: "cwd", label: t("create.dir"), value: "" },
        {
          key: "startCommand",
          label: t("create.start"),
          value: "{mcsm_java} -Xmx4G -jar server.jar nogui"
        },
        { key: "stopCommand", label: t("create.stop"), value: "stop" }
      ],
      onSubmit: (values) => {
        const nickname = values.nickname.trim();
        const startCommand = values.startCommand.trim();
        if (!nickname) return t("common.required");
        if (!startCommand) return t("common.required");
        try {
          const instance = instanceService.createBlank({
            nickname,
            cwd: values.cwd.trim(),
            startCommand,
            stopCommand: values.stopCommand.trim() || "stop",
            type: values.type.trim() || "universal"
          });
          this.app.message(t("create.done", { name: instance.config.nickname }), "success");
          this.app.back();
        } catch (error: any) {
          return error?.message ?? String(error);
        }
      },
      onCancel: () => this.app.back()
    });
  }

  onKey(_ch: string, key: UiKey) {
    if (key.name === "escape") this.app.back();
  }
}

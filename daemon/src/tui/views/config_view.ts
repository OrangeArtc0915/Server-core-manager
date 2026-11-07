import fs from "fs-extra";
import path from "path";
import Instance from "../../entity/instance/instance";
import { BaseView, type AppLike } from "../base";
import { blessed, c, createFlatList, escapeTags, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { boolText, parseBool, parseNumber, statusText } from "../format";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { opsLog } from "../service/ops_log";
import { CommonFilesView } from "./server_config_view";
import { PropertiesView } from "./properties_view";

interface FieldDef {
  key: string;
  label: string;
  kind?: "text" | "number" | "bool" | "secret";
}

const FIELDS: FieldDef[] = [
  { key: "nickname", label: "cfg.field.nickname" },
  { key: "cwd", label: "cfg.field.cwd" },
  { key: "startCommand", label: "cfg.field.startCommand" },
  { key: "stopCommand", label: "cfg.field.stopCommand" },
  { key: "updateCommand", label: "cfg.field.updateCommand" },
  { key: "type", label: "cfg.field.type" },
  { key: "stopTimeout", label: "cfg.field.stopTimeout", kind: "number" },
  { key: "ie", label: "cfg.field.ie" },
  { key: "oe", label: "cfg.field.oe" },
  { key: "fileCode", label: "cfg.field.fileCode" },
  { key: "crlf", label: "cfg.field.crlf", kind: "number" },
  { key: "pty", label: "cfg.field.pty", kind: "bool" },
  { key: "ptyWindowCol", label: "cfg.field.ptyCol", kind: "number" },
  { key: "ptyWindowRow", label: "cfg.field.ptyRow", kind: "number" },
  { key: "autoStart", label: "cfg.field.autoStart", kind: "bool" },
  { key: "autoRestart", label: "cfg.field.autoRestart", kind: "bool" },
  { key: "autoRestartMaxTimes", label: "cfg.field.autoRestartMaxTimes", kind: "number" },
  { key: "enableRcon", label: "cfg.field.enableRcon", kind: "bool" },
  { key: "rconIp", label: "cfg.field.rconIp" },
  { key: "rconPort", label: "cfg.field.rconPort", kind: "number" },
  { key: "rconPassword", label: "cfg.field.rconPassword", kind: "secret" },
  { key: "pingIp", label: "cfg.field.pingIp" },
  { key: "pingPort", label: "cfg.field.pingPort", kind: "number" },
  { key: "pingType", label: "cfg.field.pingType", kind: "number" },
  { key: "javaId", label: "cfg.field.javaId" },
  { key: "basePort", label: "cfg.field.basePort", kind: "number" },
  { key: "runAs", label: "cfg.field.runAs" },
  { key: "tag", label: "cfg.field.tag" },
  { key: "frpToken", label: "cfg.field.frpToken", kind: "secret" },
  { key: "frpTunnels", label: "cfg.field.frpTunnels" }
];

export class ConfigView extends BaseView {
  private list: any;
  private values: Record<string, string> = {};

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
    this.loadValues();
  }

  private get instance(): Instance | undefined {
    return instanceService.get(this.instanceUuid);
  }

  get title(): string {
    return t("cfg.title", { name: this.instance?.config.nickname ?? "" });
  }

  get hints(): string {
    return "Enter 编辑   s 保存   v 服务端属性   p 常用服务端配置   Esc 返回";
  }

  private loadValues() {
    const instance = this.instance;
    if (!instance) return;
    const cfg = instance.config;
    this.values = {
      nickname: cfg.nickname,
      cwd: cfg.cwd,
      startCommand: cfg.startCommand,
      stopCommand: cfg.stopCommand,
      updateCommand: cfg.updateCommand,
      type: cfg.type,
      stopTimeout: String(cfg.stopTimeout ?? 0),
      ie: cfg.ie,
      oe: cfg.oe,
      fileCode: cfg.fileCode,
      crlf: String(cfg.crlf),
      pty: boolText(cfg.terminalOption.pty),
      ptyWindowCol: String(cfg.terminalOption.ptyWindowCol),
      ptyWindowRow: String(cfg.terminalOption.ptyWindowRow),
      autoStart: boolText(cfg.eventTask.autoStart),
      autoRestart: boolText(cfg.eventTask.autoRestart),
      autoRestartMaxTimes: String(cfg.eventTask.autoRestartMaxTimes),
      enableRcon: boolText(cfg.enableRcon),
      rconIp: cfg.rconIp,
      rconPort: String(cfg.rconPort),
      rconPassword: cfg.rconPassword,
      pingIp: cfg.pingConfig.ip,
      pingPort: String(cfg.pingConfig.port),
      pingType: String(cfg.pingConfig.type),
      javaId: cfg.java.id,
      basePort: String(cfg.basePort),
      runAs: cfg.runAs,
      tag: (cfg.tag ?? []).join(","),
      frpToken: cfg.extraServiceConfig.sakuraFrpToken,
      frpTunnels: cfg.extraServiceConfig.sakuraFrpTunnelIds
    };
  }

  protected build() {
    const name = this.instance?.config.nickname ?? "";
    this.page(name, "实例配置", t("inst.title"));
    this.list = createFlatList(this.root, 2);
    this.list.on("select", () => this.editSelected());
    this.main = this.list;
    this.list.focus();
    this.refresh();
  }

  refresh() {
    if (!this.list) return;
    const contentWidth = this.contentWidth();
    const labelWidth = 30;
    const valueWidth = Math.max(16, contentWidth - labelWidth - 8);
    const items = FIELDS.map((field) => {
      const raw = this.values[field.key] ?? "";
      const display = field.kind === "secret" && raw ? "*".repeat(Math.min(raw.length, 24)) : raw;
      return `${c(PAL.dim, padDisplay(t(field.label), labelWidth))} ${c(
        PAL.text,
        escapeTags(truncateDisplay(display || "-", valueWidth))
      )}`;
    });
    const previous = this.list.selected ?? 0;
    this.list.setItems(items);
    this.list.select(Math.min(previous, items.length - 1));
    const instance = this.instance;
    this.updatePage(
      instance?.config.nickname ?? "",
      instance ? `${statusText(instance.status())}  ·  ${instance.instanceUuid}` : "",
      t("inst.title")
    );
    this.app.ui.render();
  }

  onTick() {
    this.refresh();
  }

  private editSelected() {
    const field = FIELDS[this.list?.selected ?? 0];
    if (!field) return;
    const current = this.values[field.key] ?? "";
    this.app.ui.prompt({
      title: t(field.label),
      label: t(field.label),
      value: current,
      secret: field.kind === "secret",
      onSubmit: (value) => {
        if (field.kind === "number" && value.trim() !== "" && !Number.isFinite(Number(value.trim()))) {
          this.app.message(t("common.invalidInput"), "error");
          return false;
        }
        this.values[field.key] = field.kind === "bool" ? (parseBool(value) ? "1" : "0") : value;
        this.refresh();
      }
    });
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    if (ch === "s") this.save();
    if (ch === "p") {
      this.app.push(
        new CommonFilesView(this.app, this.instanceUuid),
        () => new ConfigView(this.app, this.instanceUuid)
      );
    }
    if (ch === "v") {
      this.app.push(
        new PropertiesView(this.app, this.instanceUuid),
        () => new ConfigView(this.app, this.instanceUuid)
      );
    }
  }

  private save() {
    const instance = this.instance;
    if (!instance) return;
    const v = this.values;
    if (!v.nickname.trim()) {
      this.app.message(t("common.required"), "error");
      return;
    }
    try {
      const cwd = v.cwd.trim();
      if (cwd) {
        const abs = path.isAbsolute(cwd) ? cwd : path.join(process.cwd(), cwd);
        if (!fs.existsSync(abs)) fs.mkdirsSync(abs);
      }
      instanceService.updateConfig(this.instanceUuid, {
        nickname: v.nickname.trim(),
        cwd: cwd || instance.config.cwd,
        startCommand: v.startCommand,
        stopCommand: v.stopCommand,
        updateCommand: v.updateCommand,
        type: v.type.trim(),
        stopTimeout: parseNumber(v.stopTimeout, 0),
        ie: v.ie.trim() || "utf8",
        oe: v.oe.trim() || "utf8",
        fileCode: v.fileCode.trim() || "utf8",
        crlf: parseNumber(v.crlf, 1),
        runAs: v.runAs.trim(),
        basePort: parseNumber(v.basePort, instance.config.basePort),
        enableRcon: parseBool(v.enableRcon),
        rconIp: v.rconIp.trim(),
        rconPort: parseNumber(v.rconPort, 0),
        rconPassword: v.rconPassword,
        terminalOption: {
          pty: parseBool(v.pty),
          ptyWindowCol: parseNumber(v.ptyWindowCol, 164),
          ptyWindowRow: parseNumber(v.ptyWindowRow, 40)
        },
        eventTask: {
          autoStart: parseBool(v.autoStart),
          autoRestart: parseBool(v.autoRestart),
          autoRestartMaxTimes: parseNumber(v.autoRestartMaxTimes, -1)
        },
        pingConfig: {
          ip: v.pingIp.trim(),
          port: parseNumber(v.pingPort, 25565),
          type: parseNumber(v.pingType, 1)
        },
        java: { id: v.javaId.trim() },
        tag: v.tag
          .split(",")
          .map((item) => item.trim())
          .filter(Boolean),
        extraServiceConfig: {
          sakuraFrpToken: v.frpToken.trim(),
          sakuraFrpTunnelIds: v.frpTunnels.trim()
        }
      } as any);
      opsLog.add("config save", instance.config.nickname, "success");
      this.app.message(t("cfg.saved"), "success");
      this.loadValues();
      this.refresh();
    } catch (error: any) {
      this.app.message(error?.message ?? String(error), "error");
    }
  }
}

import fs from "fs-extra";
import path from "path";
import { BaseView, type AppLike } from "../base";
import { c, createFlatList, escapeTags, PAL, padDisplay, truncateDisplay, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { opsLog } from "../service/ops_log";

interface PropertyField {
  key: string;
  label: string;
  kind?: "text" | "number" | "bool" | "choice";
  options?: string[];
  hint?: string;
}

const FIELDS: PropertyField[] = [
  { key: "motd", label: "MOTD", hint: "服务器列表显示名称" },
  { key: "difficulty", label: "难度", kind: "choice", options: ["peaceful", "easy", "normal", "hard"] },
  { key: "gamemode", label: "默认模式", kind: "choice", options: ["survival", "creative", "adventure", "spectator"] },
  { key: "hardcore", label: "极限模式", kind: "bool" },
  { key: "online-mode", label: "正版验证", kind: "bool" },
  { key: "white-list", label: "白名单", kind: "bool" },
  { key: "enforce-whitelist", label: "强制白名单", kind: "bool" },
  { key: "max-players", label: "最大玩家数", kind: "number" },
  { key: "view-distance", label: "视距", kind: "number" },
  { key: "simulation-distance", label: "模拟距离", kind: "number" },
  { key: "pvp", label: "允许 PVP", kind: "bool" },
  { key: "level-name", label: "世界目录", hint: "切换世界后需重启" },
  { key: "spawn-protection", label: "出生点保护半径", kind: "number" },
  { key: "server-port", label: "服务器端口", kind: "number", hint: "改端口后记得同步实例端口" }
];

/**
 * Friendly editor for the most-used server.properties entries. Unknown keys,
 * comments and ordering are preserved: only the edited lines are rewritten.
 */
export class PropertiesView extends BaseView {
  private list: any;
  private values: Record<string, string> = {};
  private exists = false;

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  get title(): string {
    return "服务端属性";
  }

  get hints(): string {
    return "Enter 修改   s 保存   r 重载   Esc 返回";
  }

  private file(): string {
    return path.join(instanceService.get(this.instanceUuid)?.absoluteCwdPath() ?? "", "server.properties");
  }

  protected build() {
    this.page(instanceService.get(this.instanceUuid)?.config.nickname ?? "", "server.properties", t("inst.title"));
    this.list = createFlatList(this.root, 2);
    this.list.on("select", () => this.editSelected());
    this.main = this.list;
    this.list.focus();
    this.load();
  }

  private load() {
    this.values = {};
    this.exists = fs.existsSync(this.file());
    if (this.exists) {
      try {
        const text = fs.readFileSync(this.file(), "utf-8");
        for (const line of text.split(/\r?\n/)) {
          if (!line || line.trim().startsWith("#")) continue;
          const index = line.indexOf("=");
          if (index <= 0) continue;
          this.values[line.slice(0, index).trim()] = line.slice(index + 1).trim();
        }
      } catch (error: any) {
        this.app.message(`读取 server.properties 失败：${error?.message ?? error}`, "error");
      }
    }
    this.refresh();
  }

  refresh() {
    if (!this.list) return;
    const width = this.contentWidth();
    const valueWidth = Math.max(16, width - 46);
    const items = FIELDS.map((field) => {
      const value = this.values[field.key];
      const display = value === undefined || value === "" ? "(默认)" : value;
      return `${c(PAL.dim, padDisplay(field.label, 20))} ${c(
        value === undefined ? PAL.muted : PAL.text,
        escapeTags(truncateDisplay(display, valueWidth))
      )} ${c(PAL.dim, field.hint ?? "")}`;
    });
    if (!this.exists) items.push(c(PAL.yellow, "未找到 server.properties（实例需要先启动一次生成）"));
    const previous = this.list.selected ?? 0;
    this.list.setItems(items);
    this.list.select(Math.min(previous, items.length - 1));
    this.updatePage(
      instanceService.get(this.instanceUuid)?.config.nickname ?? "",
      this.exists ? "server.properties" : "文件不存在",
      t("inst.title")
    );
    this.app.ui.render();
  }

  onTick() {
    // No polling: the file is only re-read on demand (r) to avoid fighting
    // with an external editor open on the same file.
  }

  private editSelected() {
    const field = FIELDS[this.list?.selected ?? 0];
    if (!field) return;
    if (!this.exists) {
      this.app.message("server.properties 还不存在，请先启动一次服务器", "warn");
      return;
    }
    if (field.kind === "choice" && field.options?.length) {
      this.app.ui.select(
        field.label,
        field.options.map((option) => ({ label: option, value: option })),
        (value) => {
          this.values[field.key] = value;
          this.refresh();
        }
      );
      return;
    }
    this.app.ui.prompt({
      title: field.label,
      label: `${field.key}${field.kind === "bool" ? "（true / false）" : ""}`,
      value: this.values[field.key] ?? "",
      onSubmit: (value) => {
        const text = value.trim();
        if ((field.kind === "bool" || field.kind === "number") && !text) {
          this.app.message("该项不能为空", "error");
          return false;
        }
        if (field.kind === "number" && text && !Number.isFinite(Number(text))) {
          this.app.message("请输入数字", "error");
          return false;
        }
        if (field.kind === "bool" && text && !["true", "false"].includes(text.toLowerCase())) {
          this.app.message("请输入 true 或 false", "error");
          return false;
        }
        this.values[field.key] = field.kind === "bool" ? text.toLowerCase() : text;
        this.refresh();
        return true;
      }
    });
  }

  private save() {
    if (!this.exists) return;
    try {
      const lines = fs.readFileSync(this.file(), "utf-8").split(/\r?\n/);
      const pending = new Map(Object.entries(this.values));
      const next: string[] = [];
      for (const line of lines) {
        const index = line.indexOf("=");
        if (!line.trim().startsWith("#") && index > 0) {
          const key = line.slice(0, index).trim();
          if (pending.has(key)) {
            next.push(`${key}=${pending.get(key)}`);
            pending.delete(key);
            continue;
          }
        }
        next.push(line);
      }
      // Keep trailing newline conventions: append the keys the file lacked.
      for (const [key, value] of pending) next.push(`${key}=${value}`);
      fs.writeFileSync(this.file(), next.join("\n"), "utf-8");
      // Keep the instance port in sync when server-port was edited here.
      const port = Number(this.values["server-port"]);
      const instance = instanceService.get(this.instanceUuid);
      if (instance && Number.isFinite(port) && port > 0 && port !== instance.config.basePort) {
        instanceService.updateConfig(this.instanceUuid, {
          basePort: port,
          pingConfig: {
            ip: instance.config.pingConfig?.ip ?? "",
            port,
            type: instance.config.pingConfig?.type ?? 1
          }
        } as any);
      }
      opsLog.add("properties save", instanceService.get(this.instanceUuid)?.config.nickname ?? "", "success");
      this.app.message("server.properties 已保存（多数改动需重启生效）", "success");
      this.load();
    } catch (error: any) {
      this.app.message(`保存失败：${error?.message ?? error}`, "error");
    }
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    if (ch === "s") {
      this.save();
      return;
    }
    if (ch === "r") {
      this.load();
      return;
    }
  }
}

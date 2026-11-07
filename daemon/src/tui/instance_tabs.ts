import type { AppLike } from "./base";
import { t } from "./lang";

/** Tabs shown for a single instance, mirroring the MCSManager panel layout. */
export type InstanceTabKey =
  | "terminal"
  | "files"
  | "config"
  | "players"
  | "schedule"
  | "backups"
  | "mods"
  | "java"
  | "frp"
  | "overview";

export interface InstanceTabDef {
  key: InstanceTabKey;
  labelKey: string;
}

export const INSTANCE_TABS: InstanceTabDef[] = [
  { key: "terminal", labelKey: "tab.terminal" },
  { key: "files", labelKey: "tab.files" },
  { key: "config", labelKey: "tab.config" },
  { key: "players", labelKey: "tab.players" },
  { key: "schedule", labelKey: "tab.schedule" },
  { key: "backups", labelKey: "tab.backups" },
  { key: "mods", labelKey: "tab.mods" },
  { key: "java", labelKey: "tab.java" },
  { key: "frp", labelKey: "tab.frp" },
  { key: "overview", labelKey: "tab.overview" }
];

export function tabLabel(key: InstanceTabKey): string {
  const def = INSTANCE_TABS.find((tab) => tab.key === key);
  return def ? t(def.labelKey) : key;
}

/**
 * Open an instance page on the given tab. Views are required lazily so this
 * module stays free of static imports from the views (they import the tab bar
 * helpers, which would otherwise create a module cycle).
 */
export function openInstanceTab(app: AppLike, instanceUuid: string, tab: InstanceTabKey) {
  const back = () => {
    const { DetailView } = require("./views/detail_view");
    return new DetailView(app, instanceUuid);
  };
  switch (tab) {
    case "terminal": {
      const { TerminalView } = require("./views/terminal_view");
      return app.push(new TerminalView(app, instanceUuid), back);
    }
    case "files": {
      const { FilesView } = require("./views/files_view");
      return app.push(new FilesView(app, instanceUuid), back);
    }
    case "config": {
      const { ConfigView } = require("./views/config_view");
      return app.push(new ConfigView(app, instanceUuid), back);
    }
    case "players": {
      const { PlayersView } = require("./views/players_view");
      return app.push(new PlayersView(app, instanceUuid), back);
    }
    case "schedule": {
      const { ScheduleView } = require("./views/schedule_view");
      return app.push(new ScheduleView(app, instanceUuid), back);
    }
    case "backups": {
      const { BackupsView } = require("./views/backups_view");
      return app.push(new BackupsView(app, instanceUuid), back);
    }
    case "mods": {
      const { ModsView } = require("./views/mods_view");
      return app.push(new ModsView(app, instanceUuid), back);
    }
    case "java": {
      const { JavaView } = require("./views/java_view");
      return app.push(new JavaView(app, instanceUuid), back);
    }
    case "frp": {
      const { FrpView } = require("./views/frp_view");
      return app.push(new FrpView(app, instanceUuid), back);
    }
    case "overview": {
      const { OverviewView } = require("./views/overview_view");
      return app.push(new OverviewView(app, instanceUuid), back);
    }
  }
}

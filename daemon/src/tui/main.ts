// Load the async task module first: it pulls in the Instance entity before the
// InstanceSubsystem singleton, which is required to break the
// InstanceSubsystem -> Instance -> JavaManager -> InstanceSubsystem import cycle
// (the daemon entry point relies on the same ordering).
// TUI mode flag first: the logger turns off its stdout appender at module load.
import "./bootstrap_env";
// Must run next: prepares the embedded terminfo for the single-file executable
// before blessed is loaded.
import { applyTerminfo, ensureTerminfoRoot } from "./prepare_terminfo";
import { releaseEmbeddedComponents } from "./service/embedded_assets";
import "../service/async_task_service";
import "../service/async_task_service/quick_install";
import fs from "fs-extra";
import { globalConfiguration } from "../entity/config";
import { i18next } from "../i18n";
import logger from "../service/log";
import InstanceSubsystem from "../service/system_instance";
import { initVersionManager } from "../service/version";
import versionAdapter from "../service/version_adapter";
import { App, SectionDef } from "./app";
import { setLanguage, t } from "./lang";
import { applyTheme } from "./theme";
import { instanceService } from "./service/instance_service";
import { opsLog } from "./service/ops_log";
import { autoBackupService } from "./service/auto_backup";
import { InstancesView } from "./views/instances_view";
import { JavaView } from "./views/java_view";
import { BackupsView } from "./views/backups_view";
import { SettingsView } from "./views/settings_view";
import { LogsView } from "./views/logs_view";
import { DiagnosticsView } from "./views/diagnostics_view";
import { AboutView } from "./views/about_view";

function fatal(message: string) {
  // eslint-disable-next-line no-console
  console.error(message);
  process.exit(1);
}

function initCore(): void {
  initVersionManager();
  // Drop the embedded 7zr / PTY into ./lib so no download is needed.
  releaseEmbeddedComponents();
  globalConfiguration.load();
  // Palette must be resolved before the widgets are created.
  applyTheme(globalConfiguration.config.tuiTheme, globalConfiguration.config.tuiBackground);

  try {
    versionAdapter.detectConfig();
  } catch (error: any) {
    logger.warn(`[TUI] Config version adaptation skipped: ${error?.message ?? error}`);
  }

  setLanguage(globalConfiguration.config.tuiLanguage || globalConfiguration.config.language);
  try {
    i18next.changeLanguage(globalConfiguration.config.language || "en_us");
  } catch (error) {
    // keep the default language
  }

  if (!fs.existsSync("logs")) fs.mkdirsSync("logs");
  opsLog.init();

  InstanceSubsystem.loadInstances();
  instanceService.init();
}

/** Headless smoke test: `node tui.js --selftest` (no TTY required). */
async function runSelfTest() {
  initCore();
  const instances = InstanceSubsystem.getInstances().map((instance) => ({
    uuid: instance.instanceUuid,
    nickname: instance.config.nickname,
    type: instance.config.type,
    status: instance.status(),
    cwd: instance.config.cwd
  }));
  let seaInfo: { isSea: boolean; assets: string[] } = { isSea: false, assets: [] };
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const sea = require("node:sea");
    if (sea?.isSea?.()) {
      seaInfo = { isSea: true, assets: typeof sea.getAssetKeys === "function" ? sea.getAssetKeys() : [] };
    }
  } catch (error) {}

  // Verify blessed can resolve terminfo here (same code path as the real UI).
  let tputInfo: { ok: boolean; error: string } = { ok: false, error: "not checked" };
  try {
    applyTerminfo();
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const Tput = require("blessed/lib/tput");
    const tput = new Tput({ terminal: "xterm-256color" });
    tputInfo = { ok: !tput.error, error: tput.error?.message ?? "" };
  } catch (error: any) {
    tputInfo = { ok: false, error: error?.message ?? String(error) };
  }

  // Verify the embedded 7zr console binary and PTY helper were released.
  let sevenZip = "missing";
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { sevenZipBinaryPath } = require("./service/embedded_assets");
    const binary: string | undefined = sevenZipBinaryPath();
    sevenZip = binary ? `${binary} (${fs.statSync(binary).size})` : "missing";
  } catch (error: any) {
    sevenZip = `ERR ${error?.message ?? error}`;
  }
  let pty = "missing";
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { PTY_PATH } = require("../const");
    pty = fs.existsSync(PTY_PATH) ? `${PTY_PATH} (${fs.statSync(PTY_PATH).size})` : "missing";
  } catch (error: any) {
    pty = `ERR ${error?.message ?? error}`;
  }

  // eslint-disable-next-line no-console
  console.log(
    JSON.stringify(
      {
        ok: true,
        sea: seaInfo,
        terminfo: process.env.TERMINFO ?? "",
        terminfoRoot: ensureTerminfoRoot() ?? "",
        tput: tputInfo,
        sevenZip,
        pty,
        cwd: process.cwd(),
        dataDir: InstanceSubsystem.getInstanceDataDir(),
        instances
      },
      null,
      2
    )
  );
  process.exit(0);
}

function bootstrap() {
  if (process.argv.includes("--selftest")) {
    void runSelfTest();
    return;
  }

  if (!process.stdout.isTTY) {
    fatal(
      "CraftDock must run in an interactive terminal (cmd.exe / PowerShell / Windows Terminal)."
    );
  }

  initCore();

  let app: App | undefined;
  process.on("uncaughtException", (error) => {
    logger.error(`[TUI] UncaughtException: ${error?.stack ?? error?.message ?? error}`);
    try {
      app?.message(error?.message ?? String(error), "error");
    } catch (notifyError) {}
  });
  process.on("unhandledRejection", (reason) => {
    logger.error(
      `[TUI] UnhandledRejection: ${reason instanceof Error ? reason.stack ?? reason.message : reason}`
    );
  });

  const sections: SectionDef[] = [
    {
      key: "instances",
      label: t("nav.instances"),
      icon: "I",
      desc: "实例列表 · 快速安装服务端",
      factory: () => new InstancesView(app!)
    },
    {
      key: "java",
      label: t("nav.java"),
      icon: "J",
      desc: "本机 Java 运行时",
      factory: () => new JavaView(app!)
    },
    {
      key: "backups",
      label: t("nav.backups"),
      icon: "B",
      desc: "实例备份与恢复",
      factory: () => new BackupsView(app!)
    },
    {
      key: "settings",
      label: t("nav.settings"),
      icon: "S",
      desc: "语言 · 路径 · 缓冲",
      factory: () => new SettingsView(app!)
    },
    {
      key: "logs",
      label: t("nav.logs"),
      icon: "L",
      desc: "运行日志与操作记录",
      factory: () => new LogsView(app!)
    },
    {
      key: "diagnostics",
      label: t("nav.diagnostics"),
      icon: "D",
      desc: "环境自检 · 端口 · 磁盘",
      factory: () => new DiagnosticsView(app!)
    },
    {
      key: "about",
      label: t("nav.about"),
      icon: "A",
      desc: "作者 · QQ 群 · 友链",
      factory: () => new AboutView(app!)
    }
  ];

  let created: App;
  try {
    created = new App({ sections });
  } catch (error: any) {
    logger.error(`[TUI] Failed to initialize terminal UI: ${error?.stack ?? error}`);
    // eslint-disable-next-line no-console
    console.error(
      `[TUI] Failed to initialize terminal UI: ${error?.message ?? error}\n` +
        "Run it from cmd.exe / PowerShell with a real console window."
    );
    // blessed registers every Screen instance globally. A screen whose Program
    // failed to initialize has no `program`, and the global exit handler would
    // crash while leaving the alternate buffer - drop it before exiting.
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const Screen = require("blessed/lib/widgets/screen");
      if (Array.isArray(Screen?.instances)) Screen.instances.length = 0;
    } catch (cleanupError) {}
    process.exit(1);
  }
  app = created;
  instanceService.onInstallFinished = (instanceUuid, message) => {
    const name = instanceService.get(instanceUuid)?.config.nickname ?? instanceUuid;
    app?.message(`${name}: ${message}`, "success");
  };
  instanceService.onFailure = (instanceUuid, message) => {
    const name = instanceService.get(instanceUuid)?.config.nickname ?? instanceUuid;
    app?.message(`${name} 启动失败：${message}`, "error");
  };
  instanceService.onNotice = (message, level) => {
    app?.message(message, level);
  };
  autoBackupService.init((message, level) => app?.message(message, level));
  app.home();
  app.message(t("app.loaded", { n: InstanceSubsystem.getInstances().length }), "info");

  // The layout switches to a compact mode below 24 rows, so only warn when the
  // window is genuinely too small to show the content area.
  const columns = Number(process.stdout.columns) || 0;
  const rows = Number(process.stdout.rows) || 0;
  if ((columns && columns < 80) || (rows && rows < 20)) {
    app.message(`当前终端 ${columns}x${rows}，窗口偏小，建议至少 80x24`, "warn");
  }

  logger.info(`[TUI] Started, ${InstanceSubsystem.getInstances().length} instance(s) loaded.`);
}

bootstrap();

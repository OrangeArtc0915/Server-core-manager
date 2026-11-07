import fs from "fs-extra";
import path from "path";
import pidusage from "pidusage";
import Instance from "../../entity/instance/instance";
import { PTY_PATH } from "../../const";
import { commandStringToArray } from "../../entity/commands/base/command_parser";
import logger from "../../service/log";
import InstanceControl from "../../service/system_instance_control";
import InstanceSubsystem from "../../service/system_instance";
import { getFileManager } from "../../service/file_router_service";
import { createQuickInstallTask } from "../../service/async_task_service/quick_install";
import javaManager from "../../service/java_manager";
import { javaService } from "./java_service";
import { frpcManager } from "./frpc_manager";
import { frpStore } from "./frp_store";
import { stripAnsi } from "../ui";
import { t } from "../lang";
import { opsLog } from "./ops_log";

export interface InstanceStats {
  cpu: number;
  memory: number;
}

export interface StatsHistory {
  cpu: number[];
  memory: number[];
}

/** Last error-looking output line, surfaced as a warning badge in the UI. */
export interface InstanceAlert {
  time: number;
  keyword: string;
  line: string;
  count: number;
}

const ALERT_PATTERN = /(exception|caused by|outofmemory|segmentation|\bfatal\b|\bsevere\b|\berror\b|\bcrash(?:ed)?\b)/i;
const PLAYER_JOINED = /:\s([A-Za-z0-9_]{1,16}) joined the game/;
const PLAYER_LEFT = /:\s([A-Za-z0-9_]{1,16}) left the game/;
const PLAYER_CONNECTED = /Player connected:\s*([A-Za-z0-9_]{1,16})/;
const PLAYER_DISCONNECTED = /Player disconnected:\s*([A-Za-z0-9_]{1,16})/;
const ALERT_HISTORY_SIZE = 100;

export interface AlertRecord {
  instanceUuid: string;
  time: number;
  keyword: string;
  line: string;
}

export interface InstallProgress {
  instanceUuid: string;
  nickname: string;
  phase: "download" | "extract";
  percentage: number;
  speed: number;
  downloadedBytes: number;
  totalBytes: number;
  elapsed: number;
}

const MAX_LINES = 5000;
const HISTORY_SIZE = 60;
const LOG_DIR = () => InstanceSubsystem.LOG_DIR;

export class InstanceService {
  public readonly memoryLog = new Map<string, string[]>();
  public onInstallFinished?: (instanceUuid: string, message: string) => void;
  public onFailure?: (instanceUuid: string, message: string) => void;
  public onNotice?: (message: string, level: "info" | "warn" | "error") => void;
  private installWatchers = new Map<string, { kind: "java" | "bedrock"; startedAt: number }>();
  private installTasks = new Map<string, { task: any; startedAt: number }>();
  private partialLine = new Map<string, string>();
  private pendingLog = new Map<string, string>();
  private stats = new Map<string, InstanceStats>();
  private history = new Map<string, StatsHistory>();
  private commandHistory = new Map<string, string[]>();
  private statsBusy = false;
  private initialized = false;
  private alerts = new Map<string, InstanceAlert>();
  private alertNotifiedAt = new Map<string, number>();
  private alertHistory: AlertRecord[] = [];
  private onlinePlayers = new Map<string, Set<string>>();

  init() {
    if (this.initialized) return;
    this.initialized = true;

    // All instances (including ones created later through quick install) forward
    // their terminal output to the subsystem, so a single subscription is enough.
    InstanceSubsystem.on("data", (instanceUuid: string, text: string) => {
      this.appendOutput(instanceUuid, text);
      this.checkJavaRequirement(instanceUuid, text);
    });
    InstanceSubsystem.on("open", (info: { instanceUuid: string }) => {
      this.appendSystemLine(info.instanceUuid, `[${t("inst.action.start")}]`);
    });
    InstanceSubsystem.on("exit", (info: { instanceUuid: string }) => {
      this.finalizePartial(info.instanceUuid);
      this.onlinePlayers.delete(info.instanceUuid);
      const timers = this.stopTimers.get(info.instanceUuid);
      if (timers) {
        timers.forEach((timer) => clearTimeout(timer));
        this.stopTimers.delete(info.instanceUuid);
      }
      this.appendSystemLine(info.instanceUuid, `[${t("status.0")}]`);
    });
    InstanceSubsystem.on("failure", (info: { instanceUuid: string }, error: any) => {
      const message = error?.message ?? String(error ?? "");
      this.finalizePartial(info.instanceUuid);
      this.appendSystemLine(info.instanceUuid, `[${t("common.error")}]`);
      if (message) this.onFailure?.(info.instanceUuid, message);
    });

    // Persist terminal output to disk, mirroring the daemon behavior.
    setInterval(() => this.flushLogs(), 500);
    // Collect per-process CPU/memory stats.
    setInterval(() => void this.collectStats(), 2000);
    // Finish post-install configuration (start command detection).
    setInterval(() => void this.checkInstalledInstances(), 3000);
  }

  list(): Instance[] {
    return InstanceSubsystem.getInstances();
  }

  get(instanceUuid: string): Instance | undefined {
    return InstanceSubsystem.getInstance(instanceUuid);
  }

  getDataDir(): string {
    return InstanceSubsystem.getInstanceDataDir();
  }

  logPath(instanceUuid: string): string {
    return path.join(LOG_DIR(), `${instanceUuid}.log`);
  }

  // ---------------------------------------------------------------- operations

  async act(instanceUuid: string, action: "start" | "stop" | "restart" | "kill") {
    const instance = this.require(instanceUuid);
    if (instance.lock) throw new Error(t("inst.locked"));
    if (action === "start") {
      this.ensureStartCommand(instance);
      this.ensureJavaForStart(instance);
      this.syncBasePort(instance);
      instance.autoRestartCount = 0;
      this.clearAlert(instance.instanceUuid);
      this.onlinePlayers.delete(instance.instanceUuid);
    }
    if (action === "stop" || action === "restart") {
      this.ensureStopCommand(instance);
    }
    try {
      await instance.execPreset(action);
      opsLog.add(t(`inst.action.${action}`), instance.config.nickname, "success");
      if (action === "stop") this.scheduleStopRetry(instance);
    } catch (error: any) {
      opsLog.add(t(`inst.action.${action}`), `${instance.config.nickname} ${error?.message ?? error}`, "error");
      throw error;
    }
  }

  private stopTimers = new Map<string, NodeJS.Timeout[]>();

  /**
   * Some servers (Paper 26.x) reject console input while they are still
   * booting, so a stop issued right after start is silently ignored. Retry the
   * graceful command once and warn the user if the instance stays in STOPPING.
   */
  private scheduleStopRetry(instance: Instance) {
    const uuid = instance.instanceUuid;
    const previous = this.stopTimers.get(uuid);
    if (previous) previous.forEach((timer) => clearTimeout(timer));

    const retry = setTimeout(() => {
      if (instance.status() === Instance.STATUS_STOPPING && instance.process) {
        logger.warn(`[TUI] stop command had no effect, retrying for ${uuid}`);
        instance
          .execPreset("command", instance.config.stopCommand?.trim() || "stop")
          .catch(() => undefined);
        this.onNotice?.("停止命令未生效，已自动重试一次", "warn");
      }
    }, 5000);

    const warn = setTimeout(() => {
      if (instance.status() === Instance.STATUS_STOPPING) {
        this.onNotice?.("实例仍在停止中：可在实例菜单按 k 强制结束", "warn");
      }
      this.stopTimers.delete(uuid);
    }, 25000);

    this.stopTimers.set(uuid, [retry, warn]);
  }

  /** Keep the displayed port in sync with the real server.properties port. */
  private syncBasePort(instance: Instance) {
    try {
      const file = path.join(instance.absoluteCwdPath(), "server.properties");
      if (!fs.existsSync(file)) return;
      const text = fs.readFileSync(file, "utf-8");
      const match = /^\s*server-port\s*=\s*(\d+)/m.exec(text);
      if (!match) return;
      const port = Number(match[1]);
      if (!port || port === instance.config.basePort) return;
      instance.parameters({ basePort: port }, true);
      logger.info(`[TUI] basePort synced from server.properties: ${port}`);
    } catch (error) {
      // ignore unreadable server.properties
    }
  }

  /**
   * The daemon default `^C` only works with a PTY. Without the PTY helper the
   * literal "^C" text is written to the server console, which is exactly the
   * garbage users saw after stopping. Switch such instances to `stop`.
   */
  private ensureStopCommand(instance: Instance) {
    const command = (instance.config.stopCommand ?? "").trim();
    const isCtrlC = command === "^C" || command === "^c" || command === "\\x03";
    if (!isCtrlC) return;
    if (this.ptyAvailable && instance.config.terminalOption?.pty) return;
    instance.parameters({ stopCommand: "stop" }, true);
    logger.info(`[TUI] stopCommand "^C" replaced with "stop" for ${instance.instanceUuid}`);
  }

  private ensureStartCommand(instance: Instance) {
    if (!instance.config.startCommand?.trim()) {
      throw new Error("启动命令为空：请到实例菜单 → 配置 填写启动命令后再启动");
    }
  }

  /**
   * A start command using `{mcsm_java}` needs a Java runtime bound to the
   * instance. New instances have none, so pick the best detected runtime (and
   * scan the system once) instead of failing with "Java not found".
   */
  private ensureJavaForStart(instance: Instance) {
    const command = instance.config.startCommand ?? "";
    if (!command.includes("{mcsm_java}")) return;
    const current = instance.config.java?.id;
    if (current && javaManager.exists(current)) return;

    if (!javaService.list().length) {
      try {
        javaService.scanSystem();
      } catch (error) {
        // ignore scan errors, handled below
      }
    }
    const runtimes = javaService.list().filter((runtime) => !runtime.downloading);
    const pick = runtimes
      .slice()
      .sort((a, b) => (Number(b.version) || 0) - (Number(a.version) || 0))[0];
    if (!pick) {
      throw new Error("未找到 Java 运行时：请先在「Java」页扫描系统或下载运行时，再启动服务器");
    }
    instance.parameters({ java: { id: pick.id } }, true);
    logger.info(`[TUI] Auto-selected Java ${pick.id} for ${instance.config.nickname}`);
  }

  /**
   * Paper / vanilla print "requires ... Java N or above" when the instance is
   * bound to an older runtime. Detect it and switch to a suitable runtime
   * instead of letting the server fail with a generic error.
   */
  private javaHintAt = new Map<string, number>();

  private checkJavaRequirement(instanceUuid: string, text: string) {
    const match = /requires (?:running the server with )?Java (\d+)/i.exec(text);
    if (!match) return;
    const required = Number(match[1]);
    if (!Number.isFinite(required) || !required) return;
    const instance = this.get(instanceUuid);
    if (!instance) return;
    const last = this.javaHintAt.get(instanceUuid) ?? 0;
    if (Date.now() - last < 60_000) return;
    this.javaHintAt.set(instanceUuid, Date.now());

    const runtimes = javaService.list().filter((runtime) => !runtime.downloading);
    const current = runtimes.find((runtime) => runtime.id === instance.config.java?.id);
    if ((Number(current?.version) || 0) >= required) return;

    const pick = runtimes
      .filter((runtime) => (Number(runtime.version) || 0) >= required)
      .sort((a, b) => (Number(a.version) || 0) - (Number(b.version) || 0))[0];
    if (!pick) {
      this.onNotice?.(`服务端需要 Java ${required}+，请到「Java」页下载并绑定后再启动`, "warn");
      return;
    }
    instance.parameters({ java: { id: pick.id } }, true);
    this.onNotice?.(
      `服务端需要 Java ${required}+，已自动切换为 Java ${pick.version}（${pick.id}），请重新启动实例`,
      "warn"
    );
    logger.info(`[TUI] Java requirement ${required} for ${instanceUuid}: bound ${pick.id}`);
  }

  async sendCommand(instanceUuid: string, command: string) {
    const instance = this.require(instanceUuid);
    if (instance.status() !== Instance.STATUS_RUNNING) throw new Error(t("term.notRunning"));
    await instance.execPreset("command", command);
  }

  async writeRaw(instanceUuid: string, data: string) {
    const instance = this.require(instanceUuid);
    instance.process?.write(data);
  }

  async resize(instanceUuid: string, width: number, height: number) {
    const instance = this.require(instanceUuid);
    instance.watchers.set("tui", { terminalSize: { w: width, h: height } });
    try {
      await instance.execPreset("resize");
    } catch (error) {
      // PTY resize is optional.
    }
  }

  async refreshPlayers(instanceUuid: string) {
    const instance = this.require(instanceUuid);
    if (!instance.getPreset("refreshPlayers")) return false;
    await instance.execPreset("refreshPlayers");
    return true;
  }

  /** PTY mode needs the external pty binary shipped in ./lib. */
  get ptyAvailable(): boolean {
    return fs.existsSync(PTY_PATH);
  }

  createBlank(options: {
    nickname: string;
    cwd?: string;
    startCommand: string;
    stopCommand?: string;
    type?: string;
    pty?: boolean;
  }): Instance {
    const config = {
      nickname: options.nickname,
      cwd: options.cwd || "",
      startCommand: options.startCommand,
      stopCommand: options.stopCommand || "stop",
      type: options.type || Instance.TYPE_UNIVERSAL,
      processType: "general",
      terminalOption: {
        pty: options.pty ?? this.ptyAvailable,
        ptyWindowCol: 164,
        ptyWindowRow: 40,
        haveColor: false
      },
      eventTask: {
        autoStart: false,
        autoRestart: false,
        autoRestartMaxTimes: -1
      }
    };
    const instance = InstanceSubsystem.createInstance(config);
    logger.info(`[TUI] Instance created: ${instance.config.nickname} (${instance.instanceUuid})`);
    opsLog.add("create", `${instance.config.nickname} (${instance.instanceUuid})`, "success");
    return instance;
  }

  /** Copy an instance (config + working directory) into a new instance. */
  async cloneInstance(sourceUuid: string, nickname: string): Promise<Instance> {
    const source = this.require(sourceUuid);
    const clone = this.createBlank({
      nickname,
      startCommand: source.config.startCommand,
      stopCommand: source.config.stopCommand,
      type: source.config.type,
      pty: source.config.terminalOption?.pty
    });
    try {
      this.updateConfig(clone.instanceUuid, {
        type: source.config.type,
        ie: source.config.ie,
        oe: source.config.oe,
        fileCode: source.config.fileCode,
        crlf: source.config.crlf,
        updateCommand: source.config.updateCommand,
        terminalOption: {
          pty: source.config.terminalOption?.pty ?? false,
          ptyWindowCol: source.config.terminalOption?.ptyWindowCol ?? 164,
          ptyWindowRow: source.config.terminalOption?.ptyWindowRow ?? 40
        },
        eventTask: { autoStart: false, autoRestart: false, autoRestartMaxTimes: -1 },
        pingConfig: {
          ip: source.config.pingConfig?.ip ?? "",
          port: clone.config.basePort,
          type: source.config.pingConfig?.type ?? 1
        },
        java: { id: source.config.java?.id ?? "" }
      } as any);
      const target = clone.absoluteCwdPath();
      fs.mkdirsSync(target);
      await fs.copy(source.absoluteCwdPath(), target, { overwrite: true });
      // The copy carries the source server-port; rewrite it or the next start
      // would sync basePort back to the source port and collide.
      const properties = path.join(target, "server.properties");
      if (fs.existsSync(properties)) {
        const text = fs.readFileSync(properties, "utf-8");
        const next = /^\s*server-port\s*=.*$/m.test(text)
          ? text.replace(/^\s*server-port\s*=.*$/m, `server-port=${clone.config.basePort}`)
          : `${text.replace(/\s*$/, "")}\nserver-port=${clone.config.basePort}\n`;
        fs.writeFileSync(properties, next, "utf-8");
      }
      logger.info(`[TUI] Instance cloned: ${sourceUuid} -> ${clone.instanceUuid}`);
      opsLog.add("clone", `${source.config.nickname} -> ${nickname}`, "success");
      return clone;
    } catch (error: any) {
      try {
        this.remove(clone.instanceUuid, true);
      } catch (cleanupError) {}
      throw error;
    }
  }

  quickInstall(url: string, instanceName: string, setupInfo: Partial<IGlobalInstanceConfig> = {}) {
    const build = {
      nickname: instanceName,
      startCommand: "",
      stopCommand: "stop",
      type: Instance.TYPE_MINECRAFT_JAVA,
      processType: "general",
      terminalOption: { pty: this.ptyAvailable, ptyWindowCol: 164, ptyWindowRow: 40, haveColor: false },
      eventTask: { autoStart: false, autoRestart: false, autoRestartMaxTimes: -1 },
      ...setupInfo
    } as any;
    const task = createQuickInstallTask(url, instanceName, build);

    // Track the background task so views can render live download progress while
    // the user keeps working in other sections.
    const instanceUuid = task.instance.instanceUuid;
    this.installTasks.set(instanceUuid, { task, startedAt: Date.now() });
    const cleanup = () => {
      if (this.installTasks.get(instanceUuid)?.task === task) this.installTasks.delete(instanceUuid);
    };
    task.once("stopped", cleanup);
    task.once("error", cleanup);

    logger.info(`[TUI] Quick install started: ${instanceName} <- ${url}`);
    opsLog.add("install", `${instanceName} <- ${url}`, "info");
    return task;
  }

  /** Live progress of a background quick-install task, when one is running. */
  getInstallProgress(instanceUuid: string): InstallProgress | undefined {
    const entry = this.installTasks.get(instanceUuid);
    if (!entry || entry.task.status() !== 1) return undefined;
    const instance = this.get(instanceUuid);
    const download = entry.task.downloadProgress ?? {};
    const percentage = Number(download.percentage) || 0;
    const totalBytes = Number(download.totalBytes) || 0;
    const downloadedBytes = Number(download.downloadedBytes) || 0;
    let phase: InstallProgress["phase"] = "download";
    if (downloadedBytes > 0 && (percentage >= 100 || (totalBytes > 0 && downloadedBytes >= totalBytes))) {
      phase = "extract";
    }
    return {
      instanceUuid,
      nickname: instance?.config.nickname ?? "",
      phase,
      percentage,
      speed: Number(download.speed) || 0,
      downloadedBytes,
      totalBytes,
      elapsed: Math.max(0, Math.round((Date.now() - entry.startedAt) / 1000))
    };
  }

  getActiveInstalls(): InstallProgress[] {
    const result: InstallProgress[] = [];
    for (const instanceUuid of this.installTasks.keys()) {
      const progress = this.getInstallProgress(instanceUuid);
      if (progress) result.push(progress);
    }
    return result;
  }

  /**
   * Remember an instance that was just installed from a mirror, so a start
   * command can be generated once the download/unpack task finishes.
   */
  markInstalling(instanceUuid: string, kind: "java" | "bedrock") {
    this.installWatchers.set(instanceUuid, { kind, startedAt: Date.now() });
  }

  private async checkInstalledInstances() {
    if (!this.installWatchers.size) return;
    for (const [instanceUuid, meta] of [...this.installWatchers]) {
      const instance = this.get(instanceUuid);
      if (!instance) {
        this.installWatchers.delete(instanceUuid);
        continue;
      }
      if (Date.now() - meta.startedAt > 1000 * 60 * 30) {
        this.installWatchers.delete(instanceUuid);
        continue;
      }
      if (instance.status() === Instance.STATUS_BUSY) continue;
      if (instance.status() !== Instance.STATUS_STOP) {
        this.installWatchers.delete(instanceUuid);
        continue;
      }
      if (instance.config.startCommand?.trim()) {
        this.installWatchers.delete(instanceUuid);
        continue;
      }
      const command = await this.guessStartCommand(instance, meta.kind);
      if (!command) continue;
      try {
        instance.parameters({ startCommand: command });
        this.installWatchers.delete(instanceUuid);
        logger.info(`[TUI] Start command detected for ${instanceUuid}: ${command}`);
        this.onInstallFinished?.(instanceUuid, `start: ${command}`);
      } catch (error) {
        this.installWatchers.delete(instanceUuid);
      }
    }
  }

  private async guessStartCommand(
    instance: Instance,
    kind: "java" | "bedrock"
  ): Promise<string | undefined> {
    try {
      const cwd = instance.absoluteCwdPath();
      if (!fs.existsSync(cwd)) return undefined;
      const files = await fs.readdir(cwd, { withFileTypes: true });
      if (kind === "bedrock") {
        const target = files.find(
          (file) => file.isFile() && /^bedrock_server(\.exe)?$/i.test(file.name)
        );
        return target ? `"${target.name}"` : undefined;
      }
      const jars = files
        .filter((file) => file.isFile() && file.name.toLowerCase().endsWith(".jar"))
        .map((file) => file.name);
      if (!jars.length) return undefined;
      const preferred =
        jars.find((name) => /^(server|paper|spigot|bukkit|forge|fabric|purpur|velocity|bungeecord).*\.jar$/i.test(name)) ??
        jars[0];
      return `{mcsm_java} -Xmx4G -jar "${preferred}" nogui`;
    } catch (error) {
      return undefined;
    }
  }

  remove(instanceUuid: string, deleteFiles: boolean) {
    const instance = this.require(instanceUuid);
    if (instance.status() !== Instance.STATUS_STOP) throw new Error(t("inst.locked"));
    InstanceSubsystem.removeInstance(instanceUuid, deleteFiles);
    frpcManager.stop(instanceUuid);
    frpStore.clearBinding(instanceUuid);
    this.memoryLog.delete(instanceUuid);
    this.stats.delete(instanceUuid);
    this.history.delete(instanceUuid);
    this.commandHistory.delete(instanceUuid);
    this.partialLine.delete(instanceUuid);
    this.pendingLog.delete(instanceUuid);
    this.alerts.delete(instanceUuid);
    this.onlinePlayers.delete(instanceUuid);
    logger.info(`[TUI] Instance removed: ${instanceUuid} (deleteFiles=${deleteFiles})`);
    opsLog.add("delete", `${instance.config.nickname} (deleteFiles=${deleteFiles})`, "success");
  }

  updateConfig(instanceUuid: string, config: Partial<IGlobalInstanceConfig>) {
    const instance = this.require(instanceUuid);
    instance.parameters(config);
    return instance;
  }

  setJava(instanceUuid: string, javaId: string) {
    const instance = this.require(instanceUuid);
    const startCommandList = commandStringToArray(instance.config.startCommand);
    if (startCommandList.length === 0) startCommandList.push("{mcsm_java}");
    startCommandList[0] = "{mcsm_java}";
    instance.parameters({
      java: { id: javaId },
      startCommand: startCommandList.join(" ")
    });
  }

  fileManager(instanceUuid: string) {
    this.require(instanceUuid);
    return getFileManager(instanceUuid);
  }

  getStats(instanceUuid: string): InstanceStats | undefined {
    return this.stats.get(instanceUuid);
  }

  getHistory(instanceUuid: string): StatsHistory {
    return this.history.get(instanceUuid) ?? { cpu: [], memory: [] };
  }

  /** Latest error-looking line for the instance (log keyword alert). */
  getAlert(instanceUuid: string): InstanceAlert | undefined {
    return this.alerts.get(instanceUuid);
  }

  /** Instances whose log currently contains an unacknowledged error. */
  getAlertCount(): number {
    return this.alerts.size;
  }

  clearAlert(instanceUuid: string) {
    this.alerts.delete(instanceUuid);
    this.alertNotifiedAt.delete(instanceUuid);
  }

  /** Recent keyword alerts across all instances (newest last). */
  getAlertHistory(): AlertRecord[] {
    return this.alertHistory.slice();
  }

  clearAlertHistory() {
    this.alertHistory = [];
  }

  /** Players currently online according to join/leave lines in the console. */
  getOnlinePlayers(instanceUuid: string): string[] {
    return Array.from(this.onlinePlayers.get(instanceUuid) ?? []).sort((a, b) => a.localeCompare(b));
  }

  private trackPlayer(instanceUuid: string, line: string) {
    const joined = PLAYER_JOINED.exec(line) ?? PLAYER_CONNECTED.exec(line);
    if (joined) {
      const set = this.onlinePlayers.get(instanceUuid) ?? new Set<string>();
      set.add(joined[1]);
      this.onlinePlayers.set(instanceUuid, set);
      return;
    }
    const left = PLAYER_LEFT.exec(line) ?? PLAYER_DISCONNECTED.exec(line);
    if (left) {
      this.onlinePlayers.get(instanceUuid)?.delete(left[1]);
    }
  }

  /** Record an error-looking output line; notifies at most once a minute. */
  private noteAlert(instanceUuid: string, line: string) {
    if (!line) return;
    const match = ALERT_PATTERN.exec(line);
    if (!match) return;
    // Paper prefixes harmless plugin chatter with [WARN]; only flag real failures.
    if (/\[(INFO|WARN)\]:?\s*(Loaded|Enabling|Disabling|Starting|Stopping|Saving)\b/i.test(line)) return;
    const previous = this.alerts.get(instanceUuid);
    const entry: InstanceAlert = {
      time: Date.now(),
      keyword: match[0].toLowerCase(),
      line: line.trim().slice(0, 160),
      count: (previous?.count ?? 0) + 1
    };
    this.alerts.set(instanceUuid, entry);
    this.alertHistory.push({ instanceUuid, time: entry.time, keyword: entry.keyword, line: entry.line });
    if (this.alertHistory.length > ALERT_HISTORY_SIZE) {
      this.alertHistory.splice(0, this.alertHistory.length - ALERT_HISTORY_SIZE);
    }
    const last = this.alertNotifiedAt.get(instanceUuid) ?? 0;
    if (Date.now() - last < 60_000) return;
    this.alertNotifiedAt.set(instanceUuid, Date.now());
    const name = this.get(instanceUuid)?.config.nickname ?? instanceUuid;
    this.onNotice?.(`${name} 输出异常：${entry.line.slice(0, 60)}`, "warn");
  }

  addCommand(instanceUuid: string, command: string) {
    if (!command.trim()) return;
    const list = this.commandHistory.get(instanceUuid) ?? [];
    if (list[list.length - 1] !== command) list.push(command);
    if (list.length > 100) list.splice(0, list.length - 100);
    this.commandHistory.set(instanceUuid, list);
  }

  getCommands(instanceUuid: string): string[] {
    return this.commandHistory.get(instanceUuid) ?? [];
  }

  schedules(instanceUuid: string) {
    return InstanceControl.listScheduleJob(instanceUuid);
  }

  addSchedule(instanceUuid: string, task: {
    name: string;
    type: number;
    time: string;
    action: string;
    payload: string;
    count: number;
  }) {
    this.require(instanceUuid);
    InstanceControl.registerScheduleJob({
      instanceUuid,
      name: task.name,
      count: task.count,
      time: task.time,
      action: undefined,
      payload: undefined,
      actions: [{ type: task.action, payload: task.payload }],
      type: task.type
    });
  }

  deleteSchedule(instanceUuid: string, name: string) {
    InstanceControl.deleteScheduleTask(instanceUuid, name);
  }

  getInstanceCwd(instanceUuid: string): string {
    return this.require(instanceUuid).absoluteCwdPath();
  }

  // --------------------------------------------------------------------- logs

  getLogLines(instanceUuid: string): string[] {
    const lines = this.memoryLog.get(instanceUuid);
    if (lines && lines.length) return lines;
    // Fall back to the persisted log file so a restarted TUI still shows history.
    const file = this.logPath(instanceUuid);
    try {
      if (fs.existsSync(file)) {
        const text = fs.readFileSync(file, "utf-8");
        const loaded = stripAnsi(text)
          .replace(/\r\n/g, "\n")
          .split("\n")
          .map((line) => this.sanitizeLine(line))
          .slice(-MAX_LINES);
        this.memoryLog.set(instanceUuid, loaded);
        return loaded;
      }
    } catch (error) {
      // ignore unreadable log files
    }
    return [];
  }

  clearLog(instanceUuid: string) {
    this.memoryLog.set(instanceUuid, []);
  }

  private appendOutput(instanceUuid: string, text: string) {
    if (!text) return;
    // Merge before stripping: ANSI/VT sequences are regularly split across two
    // chunks, and a leftover half sequence would be printed as garbage.
    const merged = stripAnsi((this.partialLine.get(instanceUuid) ?? "") + text).replace(
      /\r\n/g,
      "\n"
    );
    const chunks = merged.split("\n");
    const last = chunks.pop() ?? "";
    this.partialLine.set(instanceUuid, last);

    const lines = this.memoryLog.get(instanceUuid) ?? [];
    let appended = "";
    for (const chunk of chunks) {
      const line = this.sanitizeLine(chunk);
      lines.push(line);
      appended += `${line}\n`;
      this.noteAlert(instanceUuid, line);
      this.trackPlayer(instanceUuid, line);
    }
    if (lines.length > MAX_LINES) lines.splice(0, lines.length - MAX_LINES);
    this.memoryLog.set(instanceUuid, lines);

    if (appended) {
      this.pendingLog.set(instanceUuid, (this.pendingLog.get(instanceUuid) ?? "") + appended);
    }
    // Feed live watchers (terminal view) with clean text only.
    const live = appended + this.sanitizeLine(last);
    for (const watcher of this.outputWatchers) {
      try {
        watcher(instanceUuid, live);
      } catch (error) {}
    }
  }

  /**
   * Normalise one output line: keep the last `\r` segment (progress bars),
   * remove control characters and orphan escape fragments left by a process
   * that stopped in the middle of a terminal sequence.
   */
  private sanitizeLine(line: string): string {
    const tail = line.includes("\r") ? line.slice(line.lastIndexOf("\r") + 1) : line;
    return tail
      .replace(/\x1b\[[0-9;?]*$/g, "")
      .replace(/\x1b\][^\x07]*$/g, "")
      .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "");
  }

  /** Flush a dangling partial line (e.g. the process stopped mid-sequence). */
  private finalizePartial(instanceUuid: string) {
    const partial = this.partialLine.get(instanceUuid);
    if (!partial) return;
    this.partialLine.set(instanceUuid, "");
    const line = this.sanitizeLine(partial);
    if (!line.trim()) return;
    const lines = this.memoryLog.get(instanceUuid) ?? [];
    lines.push(line);
    if (lines.length > MAX_LINES) lines.splice(0, lines.length - MAX_LINES);
    this.memoryLog.set(instanceUuid, lines);
    this.pendingLog.set(instanceUuid, (this.pendingLog.get(instanceUuid) ?? "") + `${line}\n`);
    for (const watcher of this.outputWatchers) {
      try {
        watcher(instanceUuid, `${line}\n`);
      } catch (error) {}
    }
  }

  private appendSystemLine(instanceUuid: string, line: string) {
    this.appendOutput(instanceUuid, `\n${line}\n`);
  }

  private outputWatchers = new Set<(instanceUuid: string, text: string) => void>();

  watchOutput(callback: (instanceUuid: string, text: string) => void): () => void {
    this.outputWatchers.add(callback);
    return () => this.outputWatchers.delete(callback);
  }

  private flushLogs() {
    const maxSize = 1024 * 512;
    this.pendingLog.forEach((text, instanceUuid) => {
      if (!text) return;
      this.pendingLog.set(instanceUuid, "");
      const file = this.logPath(instanceUuid);
      try {
        if (!fs.existsSync(LOG_DIR())) fs.mkdirsSync(LOG_DIR());
        if (fs.existsSync(file) && fs.statSync(file).size > maxSize) fs.removeSync(file);
        fs.appendFile(file, text, { encoding: "utf-8" }, () => {});
      } catch (error) {}
    });
  }

  private async collectStats() {
    if (this.statsBusy) return;
    this.statsBusy = true;
    try {
      const tasks: Promise<void>[] = [];
      for (const instance of this.list()) {
        const pid = instance.process?.pid;
        if (instance.status() !== Instance.STATUS_RUNNING || !pid || typeof pid !== "number") {
          this.stats.delete(instance.instanceUuid);
          continue;
        }
        tasks.push(
          pidusage(pid)
            .then((stat) => {
              const value = {
                cpu: Number(stat.cpu) || 0,
                memory: Number(stat.memory) || 0
              };
              this.stats.set(instance.instanceUuid, value);
              const history = this.history.get(instance.instanceUuid) ?? { cpu: [], memory: [] };
              history.cpu.push(value.cpu);
              history.memory.push(value.memory);
              if (history.cpu.length > HISTORY_SIZE) history.cpu.splice(0, history.cpu.length - HISTORY_SIZE);
              if (history.memory.length > HISTORY_SIZE)
                history.memory.splice(0, history.memory.length - HISTORY_SIZE);
              this.history.set(instance.instanceUuid, history);
            })
            .catch(() => {
              this.stats.delete(instance.instanceUuid);
            })
        );
      }
      await Promise.all(tasks);
    } finally {
      this.statsBusy = false;
    }
  }

  private require(instanceUuid: string): Instance {
    const instance = InstanceSubsystem.getInstance(instanceUuid);
    if (!instance) throw new Error(t("inst.noInstance"));
    return instance;
  }
}

export const instanceService = new InstanceService();

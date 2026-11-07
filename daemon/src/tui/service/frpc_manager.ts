import axios from "axios";
import { spawn, type ChildProcess } from "child_process";
import fs from "fs-extra";
import path from "path";
import logger from "../../service/log";
import InstanceSubsystem from "../../service/system_instance";
import { chmlFrpService } from "./chmlfrp_service";
import { getEmbeddedAsset } from "./embedded_assets";
import { frpStore, type FrpBinding, type FrpProvider } from "./frp_store";
import { openFrpService } from "./openfrp_service";
import { extractZip } from "./zip_service";

interface ProviderSpec {
  asset: string;
  exe: string;
}

const PROVIDERS: Record<Exclude<FrpProvider, "sakura">, ProviderSpec> = {
  openfrp: { asset: "frpc-openfrp.zip", exe: "frpc_openfrp.exe" },
  chmlfrp: { asset: "frpc-chmlfrp.zip", exe: "frpc_chmlfrp.exe" }
};

interface RunningFrpc {
  child: ChildProcess;
  provider: FrpProvider;
  startedAt: number;
  logs: string[];
}

const MAX_LOGS = 80;

class FrpcManager {
  private processes = new Map<string, RunningFrpc>();

  isRunning(instanceUuid: string): boolean {
    return this.processes.has(instanceUuid);
  }

  status(instanceUuid: string): { provider: FrpProvider; startedAt: number } | undefined {
    const entry = this.processes.get(instanceUuid);
    if (!entry) return undefined;
    return { provider: entry.provider, startedAt: entry.startedAt };
  }

  logs(instanceUuid: string): string[] {
    return this.processes.get(instanceUuid)?.logs ?? [];
  }

  /** Start the tunnel client for a binding. Throws with a readable message. */
  async start(instanceUuid: string, binding: FrpBinding, token: string): Promise<void> {
    if (binding.provider === "sakura") throw new Error("Sakura Frp 由实例生命周期托管，无需手动启动");
    if (this.processes.has(instanceUuid)) throw new Error("映射已在运行");
    if (!token) throw new Error("请先设置该服务商的访问令牌");
    const instance = InstanceSubsystem.getInstance(instanceUuid);
    if (!instance) throw new Error("实例不存在");

    const binary = await this.ensureBinary(binding.provider);
    const workDir = path.join(process.cwd(), "lib", "frp", instanceUuid);
    fs.mkdirsSync(workDir);

    let args: string[];
    if (binding.provider === "openfrp") {
      args = ["-u", token, "-p", binding.tunnelId];
    } else {
      const config = await chmlFrpService.tunnelConfig(token, {
        node: binding.node ?? "",
        name: binding.tunnelName
      });
      const configFile = path.join(workDir, "frpc.ini");
      fs.writeFileSync(configFile, config, "utf-8");
      binding.config = config;
      frpStore.setBinding(instanceUuid, binding);
      args = ["-c", configFile];
    }

    const child = spawn(binary, args, {
      cwd: workDir,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"]
    });

    const entry: RunningFrpc = {
      child,
      provider: binding.provider,
      startedAt: Date.now(),
      logs: []
    };
    this.processes.set(instanceUuid, entry);

    const append = (line: string) => {
      const text = line.trim();
      if (!text) return;
      entry.logs.push(text);
      if (entry.logs.length > MAX_LOGS) entry.logs.splice(0, entry.logs.length - MAX_LOGS);
      try {
        instance.println("FRP", text);
      } catch (error) {}
    };

    child.stdout?.on("data", (chunk: Buffer) => append(chunk.toString("utf-8")));
    child.stderr?.on("data", (chunk: Buffer) => append(chunk.toString("utf-8")));
    child.on("error", (error) => {
      append(`启动失败: ${error.message}`);
      this.processes.delete(instanceUuid);
    });
    child.on("exit", (code) => {
      append(`frpc 已退出（code=${code ?? "-"}）`);
      this.processes.delete(instanceUuid);
    });

    logger.info(
      `[TUI] frpc (${binding.provider}) started for ${instanceUuid}: pid=${child.pid}, tunnel=${binding.tunnelId}`
    );
  }

  stop(instanceUuid: string): boolean {
    const entry = this.processes.get(instanceUuid);
    if (!entry) return false;
    this.processes.delete(instanceUuid);
    const pid = entry.child.pid;
    try {
      if (process.platform === "win32" && pid) {
        spawn("taskkill", ["/pid", String(pid), "/f", "/t"], { windowsHide: true });
      } else {
        entry.child.kill("SIGTERM");
      }
    } catch (error: any) {
      logger.warn(`[TUI] Cannot stop frpc: ${error?.message ?? error}`);
    }
    logger.info(`[TUI] frpc stopped for ${instanceUuid}`);
    return true;
  }

  stopAll() {
    for (const uuid of [...this.processes.keys()]) this.stop(uuid);
  }

  /** Make sure the frpc client exists locally (embedded asset or download). */
  async ensureBinary(provider: Exclude<FrpProvider, "sakura">): Promise<string> {
    const spec = PROVIDERS[provider];
    const libDir = path.join(process.cwd(), "lib");
    const exe = path.join(libDir, spec.exe);
    try {
      if (fs.existsSync(exe) && fs.statSync(exe).size > 100 * 1024) return exe;
    } catch (error) {
      // ignore
    }
    fs.mkdirsSync(libDir);

    const embedded = getEmbeddedAsset(spec.asset);
    const zip = path.join(libDir, `${provider}.zip`);
    if (embedded) {
      fs.writeFileSync(zip, embedded);
      logger.info(`[TUI] Using embedded ${provider} frpc bundle`);
    } else {
      const url =
        provider === "openfrp" ? await openFrpService.frpcDownloadUrl() : chmlFrpService.frpcDownloadUrl();
      logger.info(`[TUI] Downloading ${provider} frpc: ${url}`);
      await this.download(url, zip);
    }

    const outDir = path.join(libDir, `.${provider}-frpc`);
    fs.removeSync(outDir);
    fs.mkdirsSync(outDir);
    try {
      await extractZip(zip, outDir);
      const found = this.findExecutable(outDir);
      if (!found) throw new Error("frpc 可执行文件不存在");
      fs.copySync(found, exe);
      logger.info(`[TUI] frpc ready: ${exe}`);
      return exe;
    } finally {
      fs.removeSync(outDir);
      fs.removeSync(zip);
    }
  }

  private findExecutable(dir: string): string | undefined {
    const stack = [dir];
    while (stack.length) {
      const current = stack.pop() as string;
      for (const item of fs.readdirSync(current, { withFileTypes: true })) {
        const full = path.join(current, item.name);
        if (item.isDirectory()) stack.push(full);
        else if (/^frpc(\.exe)?$/i.test(item.name)) return full;
      }
    }
    // Some bundles name the binary after the provider.
    const walk = (current: string): string | undefined => {
      for (const item of fs.readdirSync(current, { withFileTypes: true })) {
        const full = path.join(current, item.name);
        if (item.isDirectory()) {
          const nested = walk(full);
          if (nested) return nested;
        } else if (item.isFile() && /\.exe$/i.test(item.name)) {
          return full;
        }
      }
      return undefined;
    };
    return walk(dir);
  }

  private async download(url: string, target: string): Promise<void> {
    const response = await axios({
      url,
      method: "GET",
      responseType: "stream",
      timeout: 120000,
      maxRedirects: 8,
      headers: { "User-Agent": "CraftDock/1.0 (MCSManager Custom TUI)" }
    });
    await new Promise<void>((resolve, reject) => {
      const out = fs.createWriteStream(target);
      response.data.on("error", reject);
      out.on("error", reject);
      out.on("finish", () => resolve());
      response.data.pipe(out);
    });
  }
}

export const frpcManager = new FrpcManager();

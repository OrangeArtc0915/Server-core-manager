import fs from "fs-extra";
import path from "path";
import { execFileSync, spawnSync } from "child_process";
import { pipeline } from "stream";
import axios from "axios";
import { URL } from "url";
import { extract } from "tar";
import { JavaInfo } from "../../entity/commands/java/java_manager";
import downloadManager from "../../service/download_manager";
import javaManager from "../../service/java_manager";
import { mslService } from "./msl_service";
import logger from "../../service/log";
import FileManager from "../../service/system_file";
import { extractZip } from "./zip_service";

export interface JavaRuntimeView {
  id: string;
  name: string;
  version?: string;
  path?: string;
  downloading: boolean;
  progress?: number;
  usingInstances: string[];
}

const ADOPTIUM_BINARY = "https://api.adoptium.net/v3/binary/latest";

class JavaService {
  private progress = new Map<string, number>();

  list(): JavaRuntimeView[] {
    return javaManager.list().map((runtime) => {
      const info = runtime.info as JavaInfo;
      return {
        id: info.fullname,
        name: info.name,
        version: info.version,
        path: info.path ?? runtime.path,
        downloading: Boolean(info.downloading),
        progress: this.progress.get(info.fullname),
        usingInstances: runtime.usingInstances ?? []
      };
    });
  }

  exists(id: string) {
    return javaManager.exists(id);
  }

  addLocal(name: string, executablePath: string) {
    const info = new JavaInfo(name, Date.now());
    if (!FileManager.checkFileName(name)) throw new Error("Invalid Java name");
    if (javaManager.exists(info.fullname)) throw new Error("Java runtime already exists");
    info.path = path.normalize(executablePath);
    javaManager.addJava(info);
    return info.fullname;
  }

  async remove(id: string) {
    await javaManager.removeJava(id);
  }

  /**
   * Download and install an Eclipse Temurin JDK, fully in JS: the archive is
   * fetched from Adoptium and extracted with node-stream-zip, so the external
   * Zip-Tools helper is not required. `onProgress` receives 0-100.
   */
  async download(_name: string, version: string, onProgress?: (percent: number) => void): Promise<string> {
    const info = new JavaInfo("temurin", Date.now(), version);
    const id = info.fullname;
    info.downloading = true;
    javaManager.addJava(info);
    this.progress.set(id, 0);

    const javaPath = path.join(javaManager.getJavaDataDir(), id);
    const zipPath = path.join(javaPath, "jdk.zip");

    try {
      fs.mkdirsSync(javaPath);
      const urls = await this.resolveDownloadUrls(version);
      let lastError: any;
      let downloaded = false;
      for (const url of urls) {
        try {
          logger.info(`[TUI] Downloading Java ${version}: ${url}`);
          await this.downloadFile(url, zipPath, (percent) => {
            this.progress.set(id, percent);
            onProgress?.(percent);
          });
          downloaded = true;
          break;
        } catch (error: any) {
          lastError = error;
          logger.warn(`[TUI] Java download failed from ${url}: ${error?.message ?? error}`);
          await fs.remove(zipPath).catch(() => undefined);
        }
      }
      if (!downloaded) throw lastError ?? new Error("下载失败");
      this.progress.set(id, 100);
      onProgress?.(100);

      await extractZip(zipPath, javaPath);
      await fs.remove(zipPath).catch(() => undefined);

      const home = this.findJavaHome(javaPath);
      if (!home) throw new Error("解压后未找到 java 可执行文件");

      info.path = home;
      info.downloading = false;
      javaManager.updateJavaInfo(info);
      logger.info(`[TUI] Java installed: ${id} -> ${home}`);
      return id;
    } catch (error) {
      this.progress.delete(id);
      await javaManager.removeJava(id).catch(() => undefined);
      throw error;
    } finally {
      this.progress.delete(id);
    }
  }

  /** MSL JDK mirror first, then the TUNA mirrors, Adoptium official last. */
  private async resolveDownloadUrls(version: string): Promise<string[]> {
    const urls: string[] = [];
    try {
      const jdk = await mslService.getJdkUrl(version);
      if (jdk?.url) urls.push(jdk.url);
    } catch (error) {
      // mirror unavailable, try the next source
    }
    try {
      const base = this.tunaBase(version);
      const listing = await axios.get(base, { timeout: 15_000, responseType: "text" });
      const files = Array.from(String(listing.data).matchAll(/href="([^"]+\.zip)"/g)).map(
        (match) => match[1]
      );
      if (files.length) {
        const latest = files.sort().reverse()[0];
        urls.push(new URL(latest, base).toString());
      }
    } catch (error) {
      // mirror unavailable, use the official endpoint
    }
    urls.push(this.adoptiumUrl(version));
    return urls;
  }

  private tunaBase(version: string): string {
    const osName =
      process.platform === "win32" ? "windows" : process.platform === "darwin" ? "mac" : "linux";
    const arch = process.arch === "arm64" ? "aarch64" : "x64";
    return `https://mirrors.tuna.tsinghua.edu.cn/Adoptium/${encodeURIComponent(version)}/jdk/${arch}/${osName}/`;
  }

  private adoptiumUrl(version: string): string {
    const osName =
      process.platform === "win32" ? "windows" : process.platform === "darwin" ? "mac" : "linux";
    const arch = process.arch === "arm64" ? "aarch64" : "x64";
    return `${ADOPTIUM_BINARY}/${encodeURIComponent(version)}/ga/${osName}/${arch}/jdk/hotspot/normal/eclipse`;
  }

  private async downloadFile(
    url: string,
    target: string,
    onProgress: (percent: number) => void
  ): Promise<void> {
    const response = await axios({
      url,
      method: "GET",
      responseType: "stream",
      maxRedirects: 8,
      timeout: 60_000,
      headers: { "User-Agent": "CraftDock/1.0" }
    });
    const total = Number(response.headers["content-length"]) || 0;
    let received = 0;
    let lastTick = 0;
    response.data.on("data", (chunk: Buffer) => {
      received += chunk.length;
      const now = Date.now();
      if (now - lastTick > 200) {
        lastTick = now;
        onProgress(total > 0 ? Math.min(99, Math.round((received / total) * 100)) : 0);
      }
    });
    await new Promise<void>((resolve, reject) => {
      pipeline(response.data, fs.createWriteStream(target), (error) => {
        if (error) reject(error);
        else resolve();
      });
    });
  }

  private findJavaHome(root: string): string | undefined {
    const exe = process.platform === "win32" ? "java.exe" : "java";
    const direct = path.join(root, "bin", exe);
    if (fs.existsSync(direct)) return root;
    for (const dir of fs.readdirSync(root)) {
      const candidate = path.join(root, dir);
      try {
        if (!fs.statSync(candidate).isDirectory()) continue;
        if (fs.existsSync(path.join(candidate, "bin", exe))) return candidate;
      } catch (error) {
        // ignore
      }
    }
    return undefined;
  }

  javaRuntimePath(id: string): string | undefined {
    const runtime = javaManager.getJava(id);
    if (!runtime) return undefined;
    return runtime.info.path ?? runtime.path;
  }

  /** Detect Java runtimes already installed on the host and register them. */
  scanSystem(): number {
    const exeName = process.platform === "win32" ? "java.exe" : "java";
    const candidates = new Set<string>();

    const addCandidate = (javaExe: string) => {
      try {
        const normalized = path.normalize(javaExe);
        if (fs.existsSync(normalized)) candidates.add(normalized);
      } catch (error) {}
    };

    if (process.env.JAVA_HOME) addCandidate(path.join(process.env.JAVA_HOME, "bin", exeName));

    try {
      const output = execFileSync(process.platform === "win32" ? "where" : "which", [exeName], {
        encoding: "utf-8",
        timeout: 5000,
        windowsHide: true
      });
      for (const line of output.split(/\r?\n/)) {
        if (line.trim()) addCandidate(line.trim());
      }
    } catch (error) {}

    // Common installation roots.
    const roots: string[] = [];
    if (process.platform === "win32") {
      roots.push(
        "C:\\Program Files\\Java",
        "C:\\Program Files\\Eclipse Adoptium",
        "C:\\Program Files\\Zulu",
        "C:\\Program Files\\Microsoft\\jdk",
        "C:\\Program Files\\Amazon Corretto",
        "C:\\Program Files\\BellSoft",
        "C:\\Program Files\\Semeru"
      );
    } else {
      roots.push("/usr/lib/jvm", "/usr/java", "/opt/java");
    }
    for (const root of roots) {
      try {
        if (!fs.existsSync(root)) continue;
        for (const dir of fs.readdirSync(root)) {
          addCandidate(path.join(root, dir, "bin", exeName));
        }
      } catch (error) {}
    }

    let added = 0;
    const homes = new Set<string>();
    for (const javaExe of candidates) {
      const home = path.dirname(path.dirname(javaExe));
      if (homes.has(home.toLowerCase())) continue;
      homes.add(home.toLowerCase());
      try {
        const version = this.detectJavaVersion(javaExe);
        const id = `system_${version}`;
        if (javaManager.exists(id)) continue;
        const info = new JavaInfo("system", Date.now(), String(version));
        info.path = home;
        javaManager.addJava(info);
        added++;
      } catch (error) {
        // ignore unreadable installations
      }
    }
    return added;
  }

  private detectJavaVersion(javaExe: string): string {
    const result = spawnSync(javaExe, ["-version"], {
      encoding: "utf-8",
      timeout: 5000,
      windowsHide: true
    });
    const text = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
    const match = /version "(\d+)(?:\.(\d+))?/i.exec(text);
    if (!match) return "unknown";
    const major = Number(match[1]);
    if (major === 1 && match[2]) return match[2];
    return String(major);
  }
}

export const javaService = new JavaService();

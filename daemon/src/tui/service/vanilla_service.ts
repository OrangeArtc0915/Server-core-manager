import axios from "axios";
import crypto from "crypto";
import fs from "fs-extra";
import path from "path";
import { pipeline } from "stream";
import logger from "../../service/log";
import InstanceSubsystem from "../../service/system_instance";
import { mslService } from "./msl_service";

const BMCLAPI_SERVER = "https://bmclapi2.bangbang93.com/version";
const VERSION_MANIFEST = "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json";

export interface VanillaProgress {
  percent: number;
  received: number;
  total: number;
}

interface VanillaSource {
  name: string;
  url: string;
  sha256?: string;
}

/**
 * Paper-family server jars (paperclip) download the matching vanilla server jar
 * from Mojang on first start, which is very slow in China. Pre-fetch it into
 * `<instance>/cache/mojang_<version>.jar` while the instance is still being
 * installed, trying the MSL mirror, then BMCLAPI, then Mojang itself.
 */
class VanillaService {
  async prefetch(
    instanceUuid: string,
    mcVersion: string,
    onProgress?: (progress: VanillaProgress) => void
  ): Promise<string | undefined> {
    if (!mcVersion) return undefined;
    const instance = InstanceSubsystem.getInstance(instanceUuid);
    if (!instance) return undefined;

    const cacheDir = path.join(instance.absoluteCwdPath(), "cache");
    const target = path.join(cacheDir, `mojang_${mcVersion}.jar`);
    try {
      if (fs.existsSync(target) && fs.statSync(target).size > 1024 * 1024) return target;
    } catch (error) {
      // ignore
    }
    fs.mkdirsSync(cacheDir);
    const temp = `${target}.part`;

    // Sources are resolved lazily so a failure of one (or of the version
    // manifest) never prevents the next one from being tried.
    const sources: Array<() => Promise<VanillaSource>> = [
      async () => {
        const mirror = await mslService.getVanillaServer(mcVersion);
        return { name: "MSL", url: mirror.url, sha256: mirror.sha256 };
      },
      async () => ({
        name: "BMCLAPI",
        url: `${BMCLAPI_SERVER}/${encodeURIComponent(mcVersion)}/server`
      }),
      async () => {
        const url = await this.officialServerUrl(mcVersion);
        if (!url) throw new Error("官方下载地址获取失败");
        return { name: "Mojang", url };
      }
    ];

    let lastError: any;
    for (const resolve of sources) {
      let source: VanillaSource;
      try {
        source = await resolve();
      } catch (error: any) {
        lastError = error;
        logger.warn(`[TUI] Vanilla prefetch source unavailable: ${error?.message ?? error}`);
        continue;
      }
      try {
        logger.info(`[TUI] Prefetching vanilla server ${mcVersion} via ${source.name}: ${source.url}`);
        await this.download(source.url, temp, onProgress);
        if (source.sha256) await this.verifySha256(temp, source.sha256);
        // Paperclip may have downloaded it while we were fetching: never
        // overwrite a file the running server might already be using.
        try {
          if (fs.existsSync(target) && fs.statSync(target).size > 1024 * 1024) {
            await fs.remove(temp);
            return target;
          }
        } catch (error) {
          // ignore
        }
        await fs.move(temp, target, { overwrite: true });
        logger.info(`[TUI] Vanilla server cached via ${source.name}: ${target}`);
        return target;
      } catch (error: any) {
        lastError = error;
        logger.warn(`[TUI] Vanilla prefetch failed (${source.name}): ${error?.message ?? error}`);
        await fs.remove(temp).catch(() => undefined);
      }
    }
    throw lastError ?? new Error("原版服务端下载失败");
  }

  private async officialServerUrl(version: string): Promise<string | undefined> {
    const manifest = await axios.get(VERSION_MANIFEST, { timeout: 20_000 });
    const entry = (manifest.data?.versions ?? []).find((item: any) => item.id === version);
    if (!entry?.url) return undefined;
    const detail = await axios.get(entry.url, { timeout: 20_000 });
    return detail.data?.downloads?.server?.url;
  }

  private async verifySha256(file: string, expected: string): Promise<void> {
    if (!/^[0-9a-f]{64}$/i.test(expected)) return;
    const hash = await new Promise<string>((resolve, reject) => {
      const digest = crypto.createHash("sha256");
      fs.createReadStream(file)
        .on("data", (chunk) => digest.update(chunk))
        .on("end", () => resolve(digest.digest("hex")))
        .on("error", reject);
    });
    if (hash.toLowerCase() !== expected.toLowerCase()) {
      throw new Error("sha256 校验失败");
    }
  }

  private async download(
    url: string,
    target: string,
    onProgress?: (progress: VanillaProgress) => void
  ): Promise<void> {
    const response = await axios({
      url,
      method: "GET",
      responseType: "stream",
      maxRedirects: 8,
      timeout: 60_000,
      headers: { "User-Agent": "CraftDock/1.0 (MCSManager Custom TUI)" }
    });
    const total = Number(response.headers["content-length"]) || 0;
    let received = 0;
    let lastTick = 0;
    response.data.on("data", (chunk: Buffer) => {
      received += chunk.length;
      const now = Date.now();
      if (now - lastTick > 400) {
        lastTick = now;
        onProgress?.({ percent: total ? Math.round((received / total) * 100) : 0, received, total });
      }
    });
    await new Promise<void>((resolve, reject) => {
      pipeline(response.data, fs.createWriteStream(target), (error) => {
        if (error) reject(error);
        else resolve();
      });
    });
    onProgress?.({ percent: 100, received, total: total || received });
  }
}

export const vanillaService = new VanillaService();

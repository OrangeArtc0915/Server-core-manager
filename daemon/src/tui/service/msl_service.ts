import axios from "axios";

/**
 * Minimal client for the MSL mirror API (https://www.mslmc.cn/docs/msl/msl-mirrors/).
 * The API requires an application name in the User-Agent and rate limits the
 * download URL endpoint, so responses are cached in memory.
 */
const API_BASE = "https://api.mslmc.cn/v4";
const USER_AGENT = "CraftDock/1.0 (MCSManager Custom TUI; https://github.com/MCSManager/MCSManager)";
const LIST_TTL = 1000 * 60 * 60 * 24;
const DOWNLOAD_TTL = 1000 * 60 * 60 * 6;

interface CacheEntry<T> {
  value: T;
  expireAt: number;
}

export interface MslVersionInfo {
  description: string;
  versions: string[];
}

class MslService {
  private cache = new Map<string, CacheEntry<unknown>>();

  private get<T>(key: string): T | undefined {
    const entry = this.cache.get(key);
    if (!entry) return undefined;
    if (entry.expireAt <= Date.now()) {
      this.cache.delete(key);
      return undefined;
    }
    return entry.value as T;
  }

  private set<T>(key: string, value: T, ttl: number) {
    if (this.cache.size > 300) {
      const first = this.cache.keys().next().value;
      if (first) this.cache.delete(first);
    }
    this.cache.set(key, { value, expireAt: Date.now() + ttl });
  }

  private async request(url: string): Promise<any> {
    const res = await axios({
      method: "GET",
      url,
      timeout: 15000,
      headers: { "User-Agent": USER_AGENT }
    });
    return res.data?.data;
  }

  async getServerList(): Promise<Record<string, string[]>> {
    const key = "servers";
    const cached = this.get<Record<string, string[]>>(key);
    if (cached) return cached;
    const data = await this.request(`${API_BASE}/mirrors`);
    const result: Record<string, string[]> = {};
    if (data && typeof data === "object") {
      for (const name of Object.keys(data)) {
        if (Array.isArray(data[name])) result[name] = data[name].map((v: unknown) => String(v));
      }
    }
    this.set(key, result, LIST_TTL);
    return result;
  }

  async getVersions(server: string): Promise<MslVersionInfo> {
    const key = `versions:${server}`;
    const cached = this.get<MslVersionInfo>(key);
    if (cached) return cached;
    const data = await this.request(`${API_BASE}/mirrors/${encodeURIComponent(server)}`);
    if (!data || !Array.isArray(data.versions)) throw new Error("Unexpected MSL versions response");
    const result: MslVersionInfo = {
      description: String(data.description ?? ""),
      versions: data.versions.map((v: unknown) => String(v))
    };
    this.set(key, result, LIST_TTL);
    return result;
  }

  async getDownloadUrl(server: string, version: string, build = "latest"): Promise<string> {
    const key = `download:${server}:${version}:${build}`;
    const cached = this.get<string>(key);
    if (cached) return cached;
    const data = await this.request(
      `${API_BASE}/download/server/${encodeURIComponent(server)}/${encodeURIComponent(version)}?build=${encodeURIComponent(build)}`
    );
    if (!data || typeof data.url !== "string") throw new Error("Unexpected MSL download response");
    this.set(key, data.url, DOWNLOAD_TTL);
    return data.url;
  }

  /** Available builds of a core/version (Forge-style cores have several). */
  async getServerBuilds(server: string, version: string): Promise<string[]> {
    const key = `builds:${server}:${version}`;
    const cached = this.get<string[]>(key);
    if (cached) return cached;
    const data = await this.request(
      `${API_BASE}/mirrors/${encodeURIComponent(server)}/${encodeURIComponent(version)}`
    );
    const builds = Array.isArray(data) ? data.map((item: unknown) => String(item)) : [];
    this.set(key, builds, LIST_TTL);
    return builds;
  }

  /** MSL JDK mirror (Adoptium builds), preferred for Java downloads in China. */
  async getJdkUrl(version: string): Promise<{ url: string; sha256?: string } | undefined> {
    const os = process.platform === "win32" ? "windows" : process.platform === "darwin" ? "mac" : "linux";
    const arch = process.arch === "arm64" ? "arm64" : process.arch === "ia32" ? "x86" : "x64";
    const key = `jdk:${version}:${os}:${arch}`;
    const cached = this.get<{ url: string; sha256?: string }>(key);
    if (cached) return cached;
    const data = await this.request(
      `${API_BASE}/download/jdk/${encodeURIComponent(version)}?os=${os}&arch=${arch}`
    );
    if (!data || typeof data.url !== "string") return undefined;
    const result = { url: data.url, sha256: typeof data.sha256 === "string" ? data.sha256 : undefined };
    this.set(key, result, DOWNLOAD_TTL);
    return result;
  }

  /**
   * Download address of the vanilla server jar for a given MC version, used to
   * pre-fill paperclip's cache. MSL returns an optional sha256 checksum.
   */
  async getVanillaServer(version: string): Promise<{ url: string; sha256?: string }> {
    const key = `vanilla:${version}`;
    const cached = this.get<{ url: string; sha256?: string }>(key);
    if (cached) return cached;
    const data = await this.request(
      `${API_BASE}/download/server/vanilla/${encodeURIComponent(version)}`
    );
    if (!data || typeof data.url !== "string") throw new Error("Unexpected MSL download response");
    const result = { url: data.url, sha256: typeof data.sha256 === "string" ? data.sha256 : undefined };
    this.set(key, result, DOWNLOAD_TTL);
    return result;
  }
}

export const mslService = new MslService();

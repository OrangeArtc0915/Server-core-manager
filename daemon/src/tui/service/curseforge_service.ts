import axios from "axios";
import logger from "../../service/log";

const TOKEN_API = "https://api.mslmc.cn/v4/software/cf_token";
const MIRROR_API = "https://mod.mcimirror.top/curseforge/v1";
const OFFICIAL_API = "https://api.curseforge.com/v1";
const USER_AGENT = "CraftDock/1.0 (MCSManager Custom TUI)";
const TOKEN_TTL = 1000 * 60 * 60 * 12;

export interface CurseForgeHit {
  id: string;
  name: string;
  summary: string;
  downloads: number;
  author: string;
}

export interface CurseForgeFile {
  id: number;
  name: string;
  url: string;
  gameVersions: string[];
  size: number;
}

/**
 * CurseForge search/download client.
 *
 * A normal CurseForge API key is required, so the key is fetched from the MSL
 * public endpoint (the same approach MSLX uses) and metadata requests go
 * through the mcimirror API mirror, falling back to api.curseforge.com.
 */
class CurseForgeService {
  private token = "";
  private tokenAt = 0;

  private async apiKey(): Promise<string> {
    if (this.token && Date.now() - this.tokenAt < TOKEN_TTL) return this.token;
    try {
      const response = await axios({
        url: TOKEN_API,
        timeout: 15000,
        headers: { "User-Agent": USER_AGENT }
      });
      const encoded = String(response.data?.data ?? "");
      if (encoded) {
        this.token = Buffer.from(encoded, "base64").toString("utf-8").trim();
        this.tokenAt = Date.now();
      }
    } catch (error: any) {
      logger.warn(`[TUI] Cannot fetch the CurseForge token: ${error?.message ?? error}`);
    }
    if (!this.token) throw new Error("CurseForge 暂不可用：无法获取 API Token");
    return this.token;
  }

  private async request(path: string): Promise<any> {
    const key = await this.apiKey();
    const headers = { "x-api-key": key, Accept: "application/json", "User-Agent": USER_AGENT };
    for (const base of [MIRROR_API, OFFICIAL_API]) {
      try {
        const response = await axios({ url: `${base}${path}`, timeout: 25000, headers });
        return response.data;
      } catch (error: any) {
        logger.warn(`[TUI] CurseForge ${base} failed: ${error?.message ?? error}`);
      }
    }
    throw new Error("CurseForge 请求失败（镜像与官方均不可用）");
  }

  /** `type` selects the CurseForge class: 6 = mods, 5 = Bukkit plugins. */
  async search(
    query: string,
    type: "mod" | "plugin",
    options: { offset?: number; limit?: number } = {}
  ): Promise<CurseForgeHit[]> {
    const classId = type === "plugin" ? 5 : 6;
    const offset = options.offset ?? 0;
    const limit = options.limit ?? 20;
    const data = await this.request(
      `/mods/search?gameId=432&classId=${classId}&searchFilter=${encodeURIComponent(
        query
      )}&sortField=2&sortOrder=desc&index=${offset}&pageSize=${limit}`
    );
    const list = Array.isArray(data?.data) ? data.data : [];
    return list.map((item: any) => ({
      id: String(item.id ?? ""),
      name: String(item.name ?? ""),
      summary: String(item.summary ?? ""),
      downloads: Number(item.downloadCount) || 0,
      author: String(item.authors?.[0]?.name ?? "Unknown")
    }));
  }

  async files(
    modId: string,
    options: { gameVersion?: string; modLoaderType?: number } = {}
  ): Promise<CurseForgeFile[]> {
    const query = ["pageSize=50"];
    if (options.gameVersion) query.push(`gameVersion=${encodeURIComponent(options.gameVersion)}`);
    if (options.modLoaderType) query.push(`modLoaderType=${options.modLoaderType}`);
    const data = await this.request(`/mods/${encodeURIComponent(modId)}/files?${query.join("&")}`);
    const list = Array.isArray(data?.data) ? data.data : [];
    return list.map((item: any) => {
      const id = Number(item.id) || 0;
      const fileName = String(item.fileName ?? `file-${id}.jar`);
      const url =
        typeof item.downloadUrl === "string" && item.downloadUrl
          ? item.downloadUrl
          : `https://edge.forgecdn.net/files/${Math.floor(id / 1000)}/${String(id % 1000).padStart(3, "0")}/${encodeURIComponent(fileName)}`;
      const gameVersions = Array.isArray(item.gameVersions)
        ? item.gameVersions.filter((value: unknown) => typeof value === "string")
        : [];
      return {
        id,
        name: fileName,
        url,
        gameVersions,
        size: Number(item.fileLength) || 0
      };
    });
  }
}

export const curseForgeService = new CurseForgeService();

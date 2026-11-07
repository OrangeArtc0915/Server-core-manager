import axios from "axios";

/** SpigotMC (Spiget API) search helper for plugins. */
const BASE = "https://api.spiget.org/v2";
const USER_AGENT = "MCSManager-TUI/1.0 (MCSManager Custom TUI)";

export interface SpigotHit {
  id: number;
  name: string;
  tag: string;
  downloads: number;
  /** `external` resources are hosted elsewhere (often a GitHub release page). */
  external: boolean;
  externalUrl?: string;
}

class SpigotService {
  async search(query: string): Promise<SpigotHit[]> {
    const res = await axios({
      method: "GET",
      url: `${BASE}/search/resources/${encodeURIComponent(query)}`,
      timeout: 15000,
      headers: { "User-Agent": USER_AGENT },
      params: { field: "name", size: 20 }
    });
    if (!Array.isArray(res.data)) return [];
    return res.data.map((item: any) => ({
      id: Number(item.id),
      name: String(item.name ?? ""),
      tag: String(item.tag ?? ""),
      downloads: Number(item.downloads ?? 0),
      external: String(item.file?.type ?? "") === "external",
      externalUrl: item.file?.externalUrl ? String(item.file.externalUrl) : undefined
    }));
  }

  /**
   * Spiget's `/download` endpoint redirects to the real file only for hosted
   * resources; external ones redirect to a web page (HTML), so they must be
   * opened in a browser instead of being downloaded as a plugin jar.
   */
  downloadUrl(id: number): string {
    return `${BASE}/resources/${encodeURIComponent(String(id))}/download`;
  }
}

export const spigotService = new SpigotService();

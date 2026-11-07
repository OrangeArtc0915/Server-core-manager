import axios from "axios";

/**
 * Modrinth search helper used by the TUI mod browser.
 * CurseForge requires an API key, so the TUI only supports Modrinth.
 */
const BASE = "https://api.modrinth.com/v2";
const USER_AGENT = "MCSManager-TUI/1.0 (MCSManager Custom TUI)";

export interface ModrinthHit {
  projectId: string;
  slug: string;
  title: string;
  description: string;
  projectType: string;
  /** All loaders/types a project supports (a jar can be both mod and plugin). */
  projectTypes: string[];
  downloads: number;
}

export interface ModrinthFile {
  name: string;
  versionName: string;
  gameVersions: string[];
  loaders: string[];
  url: string;
}

class ModrinthService {
  async search(
    query: string,
    projectType: "mod" | "plugin",
    options: {
      loaders?: string[];
      gameVersions?: string[];
      sort?: "relevance" | "downloads";
      limit?: number;
      offset?: number;
    } = {}
  ): Promise<ModrinthHit[]> {
    // Modrinth facets: outer array = AND, inner array = OR.
    const facets: string[][] = [[`project_type:${projectType}`]];
    if (options.loaders?.length) {
      facets.push(options.loaders.map((loader) => `categories:${loader}`));
    }
    if (options.gameVersions?.length) {
      facets.push(options.gameVersions.map((version) => `versions:${version}`));
    }
    const params: Record<string, unknown> = {
      query,
      limit: options.limit ?? 20,
      offset: options.offset ?? 0,
      facets: JSON.stringify(facets)
    };
    if (options.sort === "downloads") params.index = "downloads";
    const res = await axios({
      method: "GET",
      url: `${BASE}/search`,
      timeout: 15000,
      headers: { "User-Agent": USER_AGENT },
      params
    });
    const hits = res.data?.hits;
    if (!Array.isArray(hits)) return [];
    return hits.map((hit: any) => ({
      projectId: String(hit.project_id ?? ""),
      slug: String(hit.slug ?? ""),
      title: String(hit.title ?? ""),
      description: String(hit.description ?? ""),
      projectType: String(hit.project_type ?? projectType),
      projectTypes: Array.isArray(hit.all_project_types)
        ? hit.all_project_types.map((value: unknown) => String(value))
        : [String(hit.project_type ?? projectType)],
      downloads: Number(hit.downloads ?? 0)
    }));
  }

  async versions(
    projectId: string,
    options: { loaders?: string[]; gameVersions?: string[] } = {}
  ): Promise<ModrinthFile[]> {
    const params: Record<string, string> = {};
    if (options.loaders?.length) params.loaders = JSON.stringify(options.loaders);
    if (options.gameVersions?.length) params.game_versions = JSON.stringify(options.gameVersions);
    const res = await axios({
      method: "GET",
      url: `${BASE}/project/${encodeURIComponent(projectId)}/version`,
      timeout: 15000,
      headers: { "User-Agent": USER_AGENT },
      params
    });
    if (!Array.isArray(res.data)) return [];
    const files: ModrinthFile[] = [];
    for (const version of res.data) {
      const file = (version.files ?? []).find((f: any) => f.primary) ?? (version.files ?? [])[0];
      if (!file?.url) continue;
      files.push({
        name: String(file.filename ?? "download.jar"),
        versionName: String(version.name ?? version.version_number ?? ""),
        gameVersions: (version.game_versions ?? []).map((v: unknown) => String(v)),
        loaders: (version.loaders ?? []).map((v: unknown) => String(v)),
        url: String(file.url)
      });
    }
    return files;
  }
}

export const modrinthService = new ModrinthService();

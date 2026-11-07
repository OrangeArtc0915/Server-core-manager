import axios from "axios";
import logger from "../../service/log";

const MIRROR = "https://v2.mirrors.mslmc.cn/resources";
// The MSL resource CDN only serves whitelisted clients; it answers 404 HTML for
// other User-Agents. The download manager sends the same UA for this host (see
// common/network.ts), otherwise the actual download would get the 404 page.
const USER_AGENT = "MSLX/1.0";

/**
 * MSL resource CDN mirror (the same mapping MSLX uses):
 *   https://cdn.modrinth.com/data/<rest>          -> .../resources/modrinth/<rest>
 *   https://edge.forgecdn.net/files/<a>/<b>/<file> -> .../resources/curseforge/<a>/<b>/<file>
 *
 * The mirror currently only answers whitelisted User-Agents; when it rejects a
 * request we fall back to the original CDN URL, so downloads always work.
 */
export function mirrorUrl(url: string): string | undefined {
  const modrinth = "https://cdn.modrinth.com/data/";
  if (url.startsWith(modrinth)) return `${MIRROR}/modrinth/${url.slice(modrinth.length)}`;
  const forge = url.match(/^https:\/\/edge\.forgecdn\.net\/files\/(\d+)\/(\d+)\/(.+)$/i);
  if (forge) return `${MIRROR}/curseforge/${forge[1]}/${forge[2]}/${forge[3]}`;
  return undefined;
}

/** Return the mirror URL when it is usable, otherwise the original URL. */
export async function resolveResourceUrl(url: string): Promise<string> {
  const mirror = mirrorUrl(url);
  if (!mirror) return url;
  try {
    // A HEAD request is not trustworthy here (the CDN reports 200 for paths it
    // later rejects with 404), so probe the first bytes of the real file.
    const response = await axios({
      url: mirror,
      method: "GET",
      responseType: "stream",
      timeout: 12000,
      maxRedirects: 5,
      headers: { "User-Agent": USER_AGENT, Range: "bytes=0-1023" },
      validateStatus: () => true
    });
    const status = Number(response.status);
    const type = String(response.headers["content-type"] ?? "");
    const usable = (status === 200 || status === 206) && !/text\/html/i.test(type);
    response.data?.destroy?.();
    if (usable) return mirror;
  } catch (error: any) {
    logger.info(`[TUI] MSL resource mirror unavailable: ${error?.message ?? error}`);
  }
  return url;
}

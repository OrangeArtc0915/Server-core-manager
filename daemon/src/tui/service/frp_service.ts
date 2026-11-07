import axios from "axios";

/**
 * Sakura Frp API client (tunnel list only).
 * Docs: https://doc.natfrp.com/geek.html#porting-launcher
 */
const API_BASE = "https://api.natfrp.com/v4";
const USER_AGENT = "MCSManager-TUI/1.0 (MCSManager Custom TUI)";

export interface SakuraTunnel {
  id: number;
  name: string;
  online: boolean;
}

class FrpService {
  async getTunnels(token: string): Promise<SakuraTunnel[]> {
    try {
      const res = await axios({
        method: "GET",
        url: `${API_BASE}/tunnels`,
        timeout: 15000,
        headers: { Authorization: `Bearer ${token}`, "User-Agent": USER_AGENT }
      });
      if (!Array.isArray(res.data)) throw new Error("Unexpected Sakura Frp response");
      return res.data.map((item: any) => ({
        id: Number(item.id),
        name: String(item.name ?? ""),
        online: Boolean(item.online)
      }));
    } catch (error: any) {
      const message = error?.response?.data?.msg;
      if (typeof message === "string" && message) throw new Error(message);
      throw error;
    }
  }
}

export const frpService = new FrpService();

import axios from "axios";
import logger from "../../service/log";

const API = "https://api.openfrp.net";
const USER_AGENT = "CraftDock/1.0 (MCSManager Custom TUI)";

export interface OpenFrpProxy {
  id: string;
  name: string;
  type: string;
  localPort: number;
  remotePort: number;
  node: string;
}

export interface OpenFrpNode {
  id: number;
  name: string;
  hostname: string;
  minPort: number;
  maxPort: number;
  protocols: string[];
  online: boolean;
  bandwidth?: string;
  remark?: string;
}

function fail(message: string): never {
  throw new Error(message || "OpenFrp 请求失败");
}

/**
 * OpenFrp open API client.
 * Docs / reference implementation: https://docs.openfrp.net and the MSL source.
 * Authentication uses the user's 访问密钥 in the raw `Authorization` header.
 */
class OpenFrpService {
  private async post(path: string, token: string, body?: unknown): Promise<any> {
    const response = await axios({
      method: "POST",
      url: `${API}${path}`,
      data: body ?? {},
      timeout: 20000,
      headers: {
        Authorization: token,
        "User-Agent": USER_AGENT,
        "Content-Type": "application/json"
      }
    });
    const data = response.data ?? {};
    if (data.flag === false) fail(String(data.msg ?? "OpenFrp 请求失败"));
    return data;
  }

  /** Verify the access key and return the account name. */
  async login(token: string): Promise<string> {
    const data = await this.post("/frp/api/getUserInfo", token);
    return String(data?.data?.username ?? data?.data?.name ?? "");
  }

  async listProxies(token: string): Promise<OpenFrpProxy[]> {
    const data = await this.post("/frp/api/getUserProxies", token);
    const list = data?.data?.list;
    if (!Array.isArray(list)) return [];
    return list.map((item: any) => ({
      id: String(item.id ?? ""),
      name: String(item.proxyName ?? item.name ?? item.id ?? ""),
      type: String(item.type ?? item.proxyType ?? "tcp"),
      localPort: Number(item.localPort ?? item.local_port) || 0,
      remotePort: Number(item.remotePort ?? item.remote_port) || 0,
      node: String(item.nodeName ?? item.node ?? "")
    }));
  }

  async listNodes(token: string): Promise<OpenFrpNode[]> {
    const data = await this.post("/frp/api/getNodeList", token);
    const list = data?.data?.list;
    if (!Array.isArray(list)) return [];
    return list.map((node: any) => {
      let minPort = 10000;
      let maxPort = 65535;
      const allow = String(node.allowPort ?? "").replace(/[()\s]/g, "");
      if (allow.includes(",")) {
        const [min, max] = allow.split(",");
        minPort = Number(min) || minPort;
        maxPort = Number(max) || maxPort;
      }
      const protocols: string[] = [];
      for (const key of Object.keys(node.protocolSupport ?? {})) {
        if (node.protocolSupport[key]) protocols.push(key);
      }
      if (!protocols.length) protocols.push("tcp");
      return {
        id: Number(node.id) || 0,
        name: String(node.name ?? ""),
        hostname: String(node.hostname ?? ""),
        minPort,
        maxPort,
        protocols,
        online: Number(node.status) === 200,
        bandwidth: node.bandwidth ? String(node.bandwidth) : undefined,
        remark: node.description ? String(node.description) : undefined
      };
    });
  }

  async createProxy(
    token: string,
    options: {
      nodeId: number;
      name: string;
      type: string;
      localPort: number;
      remotePort: number;
    }
  ): Promise<void> {
    await this.post("/frp/api/newProxy", token, {
      node_id: options.nodeId,
      name: options.name,
      type: options.type,
      local_addr: "127.0.0.1",
      local_port: String(options.localPort),
      remote_port: String(options.remotePort),
      domain_bind: "",
      dataGzip: true,
      dataEncrypt: false,
      url_route: "",
      host_rewrite: "",
      request_from: "",
      request_pass: "",
      custom: ""
    });
  }

  async removeProxy(token: string, proxyId: string): Promise<void> {
    await this.post("/frp/api/removeProxy", token, { proxy_id: proxyId });
  }

  /** Download address of the OpenFrp-customised frpc bundle for this platform. */
  async frpcDownloadUrl(): Promise<string> {
    try {
      const response = await axios({
        method: "GET",
        url: `${API}/commonQuery/get?key=software`,
        timeout: 20000,
        headers: { "User-Agent": USER_AGENT }
      });
      const data = response.data?.data;
      const latest = String(data?.latest ?? "");
      const source = data?.source?.[0]?.value;
      if (latest && source) {
        const platform = process.platform === "win32" ? "windows" : process.platform;
        const arch = process.arch === "x64" ? "amd64" : process.arch;
        const ext = process.platform === "win32" ? "zip" : "tar.gz";
        return `${source}${latest}frpc_${platform}_${arch}.${ext}`;
      }
    } catch (error: any) {
      logger.warn(`[TUI] OpenFrp software query failed: ${error?.message ?? error}`);
    }
    // Known recent build as a fallback.
    return "https://staticassets.naids.com/client/OF_0.68.0_37f78258_260326/frpc_windows_amd64.zip";
  }
}

export const openFrpService = new OpenFrpService();

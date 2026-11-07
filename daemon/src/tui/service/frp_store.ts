import fs from "fs-extra";
import path from "path";
import logger from "../../service/log";

export type FrpProvider = "sakura" | "openfrp" | "chmlfrp";

export interface FrpBinding {
  provider: FrpProvider;
  /** OpenFrp proxy id or ChmlFrp tunnel id. */
  tunnelId: string;
  tunnelName: string;
  /** ChmlFrp node name (OpenFrp resolves the node from the proxy id). */
  node?: string;
  /** ChmlFrp frpc.ini content fetched from the API. */
  config?: string;
  localPort?: number;
  remotePort?: number;
}

interface StoreData {
  tokens: Partial<Record<FrpProvider, string>>;
  providers: Record<string, FrpProvider>;
  instances: Record<string, FrpBinding>;
}

const FILE = () => path.join(process.cwd(), "data", "frp-providers.json");

/**
 * TUI-side settings for the third-party FRP providers (OpenFrp / ChmlFrp).
 * Sakura Frp keeps using the daemon's native `extraServiceConfig` fields, so
 * only the other providers live here.
 */
class FrpStore {
  private data: StoreData = { tokens: {}, providers: {}, instances: {} };
  private loaded = false;

  private load() {
    if (this.loaded) return;
    this.loaded = true;
    try {
      const file = FILE();
      if (!fs.existsSync(file)) return;
      const parsed = JSON.parse(fs.readFileSync(file, "utf-8"));
      this.data = {
        tokens: parsed?.tokens ?? {},
        providers: parsed?.providers ?? {},
        instances: parsed?.instances ?? {}
      };
    } catch (error: any) {
      logger.warn(`[TUI] Cannot read frp-providers.json: ${error?.message ?? error}`);
    }
  }

  private save() {
    try {
      fs.mkdirsSync(path.dirname(FILE()));
      fs.writeFileSync(FILE(), JSON.stringify(this.data, null, 2), "utf-8");
    } catch (error: any) {
      logger.warn(`[TUI] Cannot write frp-providers.json: ${error?.message ?? error}`);
    }
  }

  getToken(provider: FrpProvider): string {
    this.load();
    return this.data.tokens[provider] ?? "";
  }

  setToken(provider: FrpProvider, token: string) {
    this.load();
    if (token) this.data.tokens[provider] = token;
    else delete this.data.tokens[provider];
    this.save();
  }

  getBinding(instanceUuid: string): FrpBinding | undefined {
    this.load();
    return this.data.instances[instanceUuid];
  }

  /** Selected provider for an instance (Sakura when nothing was chosen yet). */
  getProvider(instanceUuid: string): FrpProvider {
    this.load();
    return this.data.providers[instanceUuid] ?? "sakura";
  }

  setProvider(instanceUuid: string, provider: FrpProvider) {
    this.load();
    this.data.providers[instanceUuid] = provider;
    this.save();
  }

  setBinding(instanceUuid: string, binding: FrpBinding) {
    this.load();
    this.data.instances[instanceUuid] = binding;
    this.save();
  }

  clearBinding(instanceUuid: string) {
    this.load();
    delete this.data.instances[instanceUuid];
    this.save();
  }
}

export const frpStore = new FrpStore();

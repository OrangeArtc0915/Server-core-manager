import { BaseView, type AppLike } from "../base";
import fs from "fs-extra";
import path from "path";
import { blessed, c, escapeTags, PAL, type UiKey } from "../ui";
import { t } from "../lang";
import { instanceService } from "../service/instance_service";
import { frpService, SakuraTunnel } from "../service/frp_service";
import { frpStore, type FrpBinding } from "../service/frp_store";
import { frpcManager } from "../service/frpc_manager";
import { openFrpService, type OpenFrpNode, type OpenFrpProxy } from "../service/openfrp_service";
import { chmlFrpService, type ChmlNode, type ChmlTunnel } from "../service/chmlfrp_service";
import { opsLog } from "../service/ops_log";

type Provider = "sakura" | "openfrp" | "chmlfrp";

const PROVIDER_LABEL: Record<Provider, string> = {
  sakura: "Sakura Frp（樱花）",
  openfrp: "OpenFrp",
  chmlfrp: "ChmlFrp"
};

export class FrpView extends BaseView {
  private panel: any;

  constructor(app: AppLike, private readonly instanceUuid: string) {
    super(app);
  }

  private get instance() {
    return instanceService.get(this.instanceUuid);
  }

  private get config() {
    return this.instance?.config;
  }

  get title(): string {
    const name = this.instance?.config.nickname ?? "";
    return t("frp.title", { name });
  }

  get hints(): string {
    return "p 服务商  t 令牌  f 隧道  c 创建  s 启动  o 停止  x 清除  r 刷新  Esc 返回";
  }

  protected build() {
    const name = this.instance?.config.nickname ?? "";
    this.page(name, "内网穿透", t("inst.title"));
    this.panel = blessed.box({
      parent: this.root,
      top: 2,
      left: 0,
      right: 0,
      bottom: 0,
      tags: true,
      style: { bg: PAL.bg, fg: PAL.text },
      padding: { left: 2, right: 2, top: 1 },
      content: ""
    });
    this.refresh();
  }

  // ---------------------------------------------------------------- provider

  private provider(): Provider {
    return frpStore.getProvider(this.instanceUuid);
  }

  private token(provider: Provider): string {
    if (provider === "sakura") return this.config?.extraServiceConfig.sakuraFrpToken ?? "";
    return frpStore.getToken(provider);
  }

  private binding(): FrpBinding | undefined {
    const binding = frpStore.getBinding(this.instanceUuid);
    if (binding && binding.provider === this.provider()) return binding;
    return undefined;
  }

  refresh() {
    if (!this.panel) return;
    const config = this.config;
    if (!config) return;
    const provider = this.provider();
    const token = this.token(provider);
    const binding = this.binding();
    const running = frpcManager.status(this.instanceUuid);
    const sakuraRunning = Boolean(this.instance?.info?.sakuraFrpStatus);
    const sakuraTunnels = config.extraServiceConfig.sakuraFrpTunnelIds;

    const tunnelText =
      provider === "sakura"
        ? sakuraTunnels
          ? c(PAL.bright, sakuraTunnels)
          : c(PAL.dim, t("common.notSet"))
        : binding?.tunnelName
          ? `${c(PAL.bright, binding.tunnelName)} ${c(PAL.dim, `#${binding.tunnelId}`)}`
          : c(PAL.dim, t("common.notSet"));

    const statusText = running
      ? c(PAL.green, `● 运行中（${PROVIDER_LABEL[running.provider]}）`)
      : provider === "sakura" && sakuraRunning
        ? c(PAL.green, "● 运行中（随实例启动）")
        : c(PAL.dim, "○ 未启动");

    const lines = [
      `${c(PAL.muted, "服务商")}     ${c(PAL.accent, PROVIDER_LABEL[provider])}`,
      `${c(PAL.muted, "访问令牌")}   ${
        token ? c(PAL.green, token.slice(0, 6) + "********") : c(PAL.dim, t("common.notSet"))
      }`,
      `${c(PAL.muted, "隧道")}       ${tunnelText}`,
      `${c(PAL.muted, "映射状态")}   ${statusText}`,
      ""
    ];
    if (provider === "sakura") {
      lines.push(
        c(PAL.dim, "Sakura Frp 由实例生命周期托管：保存密钥和隧道后随实例启停。"),
        c(PAL.dim, "frpc 缺失时会自动下载，也可由内置组件直接释放。")
      );
    } else {
      lines.push(
        c(PAL.dim, "映射为手动开关：s 启动、x 停止；frpc 随 CraftDock 退出而停止。"),
        c(PAL.dim, "访问令牌只在本地保存，不写入实例配置。")
      );
    }
    const logs = frpcManager.logs(this.instanceUuid).slice(-5);
    if (logs.length) {
      lines.push("", c(PAL.muted, "最近输出"));
      for (const line of logs) {
        lines.push(c(PAL.dim, escapeTags(line.slice(0, 160))));
      }
    }
    this.panel.setContent(lines.join("\n"));
    this.app.ui.render();
  }

  onTick() {
    this.refresh();
  }

  onKey(ch: string, key: UiKey) {
    if (key.name === "escape") {
      this.app.back();
      return;
    }
    switch (ch) {
      case "p":
        this.pickProvider();
        return;
      case "t":
        this.editToken();
        return;
      case "f":
        void this.pickTunnel();
        return;
      case "c":
        void this.createTunnel();
        return;
      case "s":
        void this.startMapping();
        return;
      case "o":
        this.stopMapping();
        return;
      case "x":
        this.clear();
        return;
      case "r":
        this.refresh();
        return;
    }
  }

  private pickProvider() {
    this.app.ui.select(
      "选择穿透服务商",
      [
        { label: "Sakura Frp（樱花，随实例启停）", value: "sakura" as Provider },
        { label: "OpenFrp（手动开关，支持一键建隧道）", value: "openfrp" as Provider },
        { label: "ChmlFrp（手动开关，支持一键建隧道）", value: "chmlfrp" as Provider }
      ],
      (provider) => {
        if (frpcManager.isRunning(this.instanceUuid)) {
          this.app.message("请先停止当前映射再切换服务商", "warn");
          return;
        }
        // Sakura runs through the daemon lifecycle, so drop its credentials when
        // another provider is chosen - otherwise both clients would start.
        if (provider !== "sakura" && this.config?.extraServiceConfig.sakuraFrpToken) {
          instanceService.updateConfig(this.instanceUuid, {
            extraServiceConfig: { sakuraFrpToken: "", sakuraFrpTunnelIds: "" }
          } as any);
        }
        frpStore.setProvider(this.instanceUuid, provider as Provider);
        this.app.message(`已切换服务商：${PROVIDER_LABEL[provider as Provider]}`, "success");
        this.refresh();
      },
      undefined,
      false
    );
  }

  private editToken() {
    const provider = this.provider();
    const current = this.token(provider);
    this.app.ui.prompt({
      title: `${PROVIDER_LABEL[provider]} 访问令牌`,
      label: provider === "sakura" ? "访问密钥（留空清除）" : "访问令牌（留空清除）",
      value: "",
      secret: true,
      onSubmit: (value) => {
        const token = value.trim();
        try {
          if (provider === "sakura") {
            instanceService.updateConfig(this.instanceUuid, {
              extraServiceConfig: {
                sakuraFrpToken: token,
                sakuraFrpTunnelIds: this.config?.extraServiceConfig.sakuraFrpTunnelIds ?? ""
              }
            } as any);
          } else {
            frpStore.setToken(provider, token);
          }
          this.app.message(t("frp.saved"), "success");
          opsLog.add("frp token", `${provider} ${current ? "updated" : "set"}`, "success");
          this.refresh();
        } catch (error: any) {
          return error?.message ?? String(error);
        }
      }
    });
  }

  // ------------------------------------------------------------------ tunnels

  private async pickTunnel() {
    const provider = this.provider();
    if (!this.token(provider)) {
      this.app.message(t("frp.noToken"), "warn");
      return;
    }
    if (provider === "sakura") {
      await this.pickSakuraTunnel();
      return;
    }
    const close = this.app.ui.busy("正在拉取隧道列表...");
    try {
      if (provider === "openfrp") {
        const proxies = await openFrpService.listProxies(this.token(provider));
        close();
        if (!proxies.length) {
          this.app.message("账号下没有隧道，可按 c 一键创建", "info");
          return;
        }
        this.app.ui.select(
          "选择 OpenFrp 隧道",
          proxies.map((proxy: OpenFrpProxy) => ({
            label: `${escapeTags(proxy.name)} ${c(PAL.dim, `#${proxy.id} ${proxy.type} ${proxy.localPort}→${proxy.remotePort}`)}`,
            value: proxy
          })),
          (proxy) => this.bindTunnel(proxy)
        );
        return;
      }
      const tunnels = await chmlFrpService.listTunnels(this.token(provider));
      close();
      if (!tunnels.length) {
        this.app.message("账号下没有隧道，可按 c 一键创建", "info");
        return;
      }
      this.app.ui.select(
        "选择 ChmlFrp 隧道",
        tunnels.map((tunnel: ChmlTunnel) => ({
          label: `${escapeTags(tunnel.name)} ${c(PAL.dim, `#${tunnel.id} ${tunnel.node} ${tunnel.type} ${tunnel.localPort}→${tunnel.remotePort}`)}`,
          value: tunnel
        })),
        (tunnel) => this.bindTunnel(tunnel)
      );
    } catch (error: any) {
      close();
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private bindTunnel(tunnel: OpenFrpProxy | ChmlTunnel) {
    const provider = this.provider();
    const binding: FrpBinding =
      provider === "openfrp"
        ? {
            provider: "openfrp",
            tunnelId: String((tunnel as OpenFrpProxy).id),
            tunnelName: (tunnel as OpenFrpProxy).name,
            localPort: (tunnel as OpenFrpProxy).localPort,
            remotePort: (tunnel as OpenFrpProxy).remotePort
          }
        : {
            provider: "chmlfrp",
            tunnelId: String((tunnel as ChmlTunnel).id),
            tunnelName: (tunnel as ChmlTunnel).name,
            node: (tunnel as ChmlTunnel).node,
            localPort: (tunnel as ChmlTunnel).localPort
          };
    frpStore.setBinding(this.instanceUuid, binding);
    this.app.message(`已选择隧道：${binding.tunnelName}，按 s 启动映射`, "success");
    this.refresh();
  }

  private async pickSakuraTunnel() {
    const token = this.token("sakura");
    const close = this.app.ui.busy(t("frp.fetching"));
    let tunnels: SakuraTunnel[] = [];
    try {
      tunnels = await frpService.getTunnels(token);
    } catch (error: any) {
      close();
      this.app.message(error?.message ?? String(error), "error");
      return;
    }
    close();
    if (!tunnels.length) {
      this.app.message(t("common.empty"), "info");
      return;
    }
    this.app.ui.select(
      t("frp.pickTunnel"),
      tunnels.map((tunnel) => ({
        label: escapeTags(
          t("frp.tunnelLine", {
            id: tunnel.id,
            name: tunnel.name,
            online: tunnel.online ? t("frp.online") : t("frp.offline")
          })
        ),
        value: tunnel
      })),
      (tunnel) => {
        const existing = this.config?.extraServiceConfig.sakuraFrpTunnelIds ?? "";
        const ids = existing
          .split(",")
          .map((item) => item.trim())
          .filter(Boolean);
        if (!ids.includes(String(tunnel.id))) ids.push(String(tunnel.id));
        instanceService.updateConfig(this.instanceUuid, {
          extraServiceConfig: {
            sakuraFrpToken: this.config?.extraServiceConfig.sakuraFrpToken ?? "",
            sakuraFrpTunnelIds: ids.join(",")
          }
        } as any);
        this.app.message(t("frp.tunnelApplied", { ids: ids.join(",") }), "success");
        this.refresh();
      }
    );
  }

  // ------------------------------------------------------------------- create

  private async createTunnel() {
    const provider = this.provider();
    if (provider === "sakura") {
      this.app.message("Sakura Frp 需在官网面板创建隧道，再按 f 选择", "info");
      return;
    }
    if (!this.token(provider)) {
      this.app.message(t("frp.noToken"), "warn");
      return;
    }
    const close = this.app.ui.busy("正在获取节点列表...");
    try {
      if (provider === "openfrp") {
        const nodes = (await openFrpService.listNodes(this.token(provider))).filter((n) => n.online);
        close();
        if (!nodes.length) {
          this.app.message("没有可用节点", "warn");
          return;
        }
        this.app.ui.select(
          "选择 OpenFrp 节点（TCP）",
          nodes.map((node: OpenFrpNode) => ({
            label: `${escapeTags(node.name)} ${c(PAL.dim, `${node.minPort}-${node.maxPort} ${node.bandwidth ?? ""}`)}`,
            value: node
          })),
          (node) => this.askOpenFrpCreate(node)
        );
        return;
      }
      const nodes = await chmlFrpService.listNodes();
      close();
      if (!nodes.length) {
        this.app.message("没有可用节点", "warn");
        return;
      }
      this.app.ui.select(
        "选择 ChmlFrp 节点（TCP）",
        nodes.map((node: ChmlNode) => ({
          label: `${escapeTags(node.name)} ${c(PAL.dim, `${node.area} ${node.group === "vip" ? "VIP" : "普通"}`)}`,
            value: node
        })),
        (node) => this.askChmlCreate(node)
      );
    } catch (error: any) {
      close();
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private defaultLocalPort(): string {
    // Prefer the real server port from server.properties: the instance's
    // basePort may still be the random value assigned at creation time.
    try {
      const file = path.join(this.instance?.absoluteCwdPath() ?? "", "server.properties");
      if (this.instance && fs.existsSync(file)) {
        const text = fs.readFileSync(file, "utf-8");
        const match = /^\s*server-port\s*=\s*(\d+)/m.exec(text);
        if (match) return match[1];
      }
    } catch (error) {
      // fall through to the configured base port
    }
    const port = Number(this.config?.basePort) || 25565;
    return String(port);
  }

  private askOpenFrpCreate(node: OpenFrpNode) {
    const randomPort = String(
      Math.floor(node.minPort + Math.random() * Math.max(1, node.maxPort - node.minPort))
    );
    this.app.ui.form({
      title: `新建 OpenFrp 隧道 · ${node.name}`,
      fields: [
        { key: "name", label: "隧道名称", value: `${this.config?.nickname ?? "tunnel"}-mc` },
        { key: "local", label: "本地端口", value: this.defaultLocalPort() },
        { key: "remote", label: "远程端口", value: randomPort }
      ],
      onSubmit: (values) => {
        const name = values.name.trim();
        const localPort = Number(values.local.trim());
        const remotePort = Number(values.remote.trim());
        if (!name) return "隧道名称不能为空";
        if (!localPort || localPort > 65535) return "本地端口无效";
        if (!remotePort || remotePort > 65535) return "远程端口无效";
        void this.submitOpenFrpCreate(node, name, localPort, remotePort);
      }
    });
  }

  private async submitOpenFrpCreate(node: OpenFrpNode, name: string, localPort: number, remotePort: number) {
    const close = this.app.ui.busy("正在创建隧道...");
    try {
      await openFrpService.createProxy(this.token("openfrp"), {
        nodeId: node.id,
        name,
        type: "tcp",
        localPort,
        remotePort
      });
      const proxies = await openFrpService.listProxies(this.token("openfrp"));
      close();
      const created = proxies.find((proxy) => proxy.name === name);
      if (created) this.bindTunnel(created);
      else this.app.message("隧道已创建，请按 f 选择", "success");
      opsLog.add("frp create", `openfrp ${name}`, "success");
    } catch (error: any) {
      close();
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  private askChmlCreate(node: ChmlNode) {
    this.app.ui.form({
      title: `新建 ChmlFrp 隧道 · ${node.name}`,
      fields: [
        { key: "name", label: "隧道名称", value: `${this.config?.nickname ?? "tunnel"}-mc` },
        { key: "local", label: "本地端口", value: this.defaultLocalPort() },
        { key: "remote", label: "远程端口", value: String(10000 + Math.floor(Math.random() * 40000)) }
      ],
      onSubmit: (values) => {
        const name = values.name.trim();
        const localPort = Number(values.local.trim());
        const remotePort = Number(values.remote.trim());
        if (!name) return "隧道名称不能为空";
        if (!localPort || localPort > 65535) return "本地端口无效";
        if (!remotePort || remotePort > 65535) return "远程端口无效";
        void this.submitChmlCreate(node, name, localPort, remotePort);
      }
    });
  }

  private async submitChmlCreate(node: ChmlNode, name: string, localPort: number, remotePort: number) {
    const close = this.app.ui.busy("正在创建隧道...");
    try {
      await chmlFrpService.createTunnel(this.token("chmlfrp"), {
        name,
        node: node.name,
        type: "tcp",
        localIp: "127.0.0.1",
        localPort,
        remotePort,
        encryption: false,
        compression: false
      });
      const tunnels = await chmlFrpService.listTunnels(this.token("chmlfrp"));
      close();
      const created = tunnels.find((tunnel) => tunnel.name === name);
      if (created) this.bindTunnel(created);
      else this.app.message("隧道已创建，请按 f 选择", "success");
      opsLog.add("frp create", `chmlfrp ${name}`, "success");
    } catch (error: any) {
      close();
      this.app.message(error?.message ?? String(error), "error");
    }
  }

  // ------------------------------------------------------------------- switch

  private async startMapping() {
    const provider = this.provider();
    const binding = this.binding();
    if (provider === "sakura") {
      this.app.message("Sakura Frp 随实例启停，无需手动启动", "info");
      return;
    }
    if (!binding?.tunnelId) {
      this.app.message("请先按 f 选择隧道，或按 c 一键创建", "warn");
      return;
    }
    const close = this.app.ui.busy("正在启动映射...");
    try {
      await frpcManager.start(this.instanceUuid, binding, this.token(provider));
      close();
      this.app.message(`映射已启动：${binding.tunnelName}`, "success");
      opsLog.add("frp start", `${provider} ${binding.tunnelName}`, "success");
    } catch (error: any) {
      close();
      this.app.message(error?.message ?? String(error), "error");
    }
    this.refresh();
  }

  private stopMapping() {
    if (this.provider() === "sakura") {
      this.app.message("Sakura Frp 随实例停止，无需手动关闭", "info");
      return;
    }
    if (!frpcManager.stop(this.instanceUuid)) {
      this.app.message("当前没有运行中的映射", "info");
      return;
    }
    opsLog.add("frp stop", this.instanceUuid, "success");
    this.app.message("映射已停止", "success");
    this.refresh();
  }

  private clear() {
    this.app.ui.confirm("清除穿透配置", "会停止映射并清空当前服务商的隧道绑定，确定？", () => {
      frpcManager.stop(this.instanceUuid);
      const provider = this.provider();
      if (provider === "sakura") {
        instanceService.updateConfig(this.instanceUuid, {
          extraServiceConfig: { sakuraFrpToken: "", sakuraFrpTunnelIds: "" }
        } as any);
      } else {
        frpStore.clearBinding(this.instanceUuid);
      }
      this.app.message(t("frp.saved"), "success");
      this.refresh();
    });
  }
}

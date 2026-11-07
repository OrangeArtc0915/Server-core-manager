import fs from "fs-extra";
import path from "path";
import os from "os";
import axios from "axios";
import { ILifeCycleTask } from "../../instance/life_cycle";
import Instance from "../../instance/instance";
import logger from "../../../service/log";
import { $t } from "../../../i18n";
import { getCommonHeaders } from "../../../common/network";
import { ProcessWrapper } from "mcsmanager-common";
import { downloadFileToLocalFile } from "../../../service/download";

// Sakura Frp (natfrp.com) tunnel client.
// The official customized frpc fetches the tunnel config from the Sakura Frp
// server. Credentials are passed through environment variables instead of
// command line arguments to avoid leaking the access token in the process list:
//   NATFRP_TOKEN  - user access token
//   NATFRP_TARGET - comma-separated tunnel IDs
// Docs: https://doc.natfrp.com/frpc/manual.html

// Map Node platform/arch values to the file name convention used by the
// Sakura Frp CDN (https://nya.globalslb.net/natfrp/client/frpc/).
const FRP_PLATFORM_MAP: Record<string, string> = {
  win32: "windows",
  darwin: "darwin",
  linux: "linux",
  freebsd: "freebsd"
};
const FRP_ARCH_MAP: Record<string, string> = {
  x64: "amd64",
  ia32: "386",
  arm64: "arm64",
  arm: "armv7",
  mips: "mips",
  mipsel: "mipsle",
  mips64: "mips64",
  mips64el: "mips64le",
  riscv64: "riscv64",
  loong64: "loong64"
};

function getFrpPlatform(): string | undefined {
  return FRP_PLATFORM_MAP[os.platform()];
}

function getFrpArch(): string | undefined {
  return FRP_ARCH_MAP[os.arch()];
}

function frpWinExt(): string {
  return os.platform() === "win32" ? ".exe" : "";
}

// Compare versions like "0.51.0-sakura-13.1". Returns >0 when a > b.
function compareFrpVersion(a: string, b: string): number {
  const parse = (v: string): number[] => {
    const match = v.match(/^(\d+)\.(\d+)\.(\d+)-sakura-([\d.]+)$/);
    if (!match) return [];
    return [
      Number(match[1]),
      Number(match[2]),
      Number(match[3]),
      ...match[4].split(".").map(Number)
    ];
  };
  const pa = parse(a);
  const pb = parse(b);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

// The stable redirect host (getfrp.sh) pins an old frpc build that has been
// removed from the CDN, so resolve the newest available version on the fly.
async function resolveLatestFrpcUrl(): Promise<string | undefined> {
  const platform = getFrpPlatform();
  const arch = getFrpArch();
  if (!platform || !arch) {
    logger.error(
      `Unsupported platform/arch for Sakura Frp: ${os.platform()}/${os.arch()}`
    );
    return undefined;
  }
  const { data } = await axios<string>({
    url: `${SakuraFrpTask.FRP_CDN}/`,
    timeout: 1000 * 15,
    headers: getCommonHeaders(SakuraFrpTask.FRP_CDN),
    maxRedirects: 5
  });
  const matches = data.match(/href="\d+\.\d+\.\d+-sakura-[\d.]+\/"/g) || [];
  const versions = matches
    .map((m) => m.match(/\d+\.\d+\.\d+-sakura-[\d.]+/)?.[0])
    .filter((v): v is string => !!v);
  versions.sort((a, b) => compareFrpVersion(b, a));
  const latest = versions[0];
  if (!latest) {
    logger.error("Failed to resolve the latest Sakura Frp version from the CDN index");
    return undefined;
  }
  return `${SakuraFrpTask.FRP_CDN}/${latest}/frpc_${platform}_${arch}${frpWinExt()}`;
}

export class SakuraFrp {
  public processWrapper?: ProcessWrapper;

  constructor(public readonly token: string, public readonly tunnelIds: string) {
    this.processWrapper = new ProcessWrapper(
      SakuraFrpTask.FRP_EXE_PATH,
      [],
      path.dirname(SakuraFrpTask.FRP_EXE_PATH),
      0,
      "utf-8",
      { env: { ...process.env, NATFRP_TOKEN: token, NATFRP_TARGET: tunnelIds } }
    );
  }

  public open() {
    logger.info("Start sakura frp:", SakuraFrpTask.FRP_EXE_PATH);
    this.processWrapper?.start();
    if (!this.processWrapper?.getPid()) {
      throw new Error("pid is null");
    }
  }

  public stop() {
    try {
      if (this.processWrapper?.exitCode() == null) {
        this.processWrapper?.kill();
      }
      this.processWrapper = undefined;
    } catch (error: any) {}
  }
}

export default class SakuraFrpTask implements ILifeCycleTask {
  public status: number = 0;
  public name: string = "sakura_frp";
  public static readonly FRP_CDN = "https://nya.globalslb.net/natfrp/client/frpc";
  public static readonly FRP_EXE_NAME = `sakura_frpc_${getFrpPlatform()}_${getFrpArch()}${frpWinExt()}`;
  public static readonly FRP_EXE_PATH = path.normalize(
    path.join(process.cwd(), "lib", SakuraFrpTask.FRP_EXE_NAME)
  );

  async start(instance: Instance) {
    const { sakuraFrpToken, sakuraFrpTunnelIds } = instance.config?.extraServiceConfig;
    if (!sakuraFrpToken || !sakuraFrpTunnelIds) return;

    if (!fs.existsSync(SakuraFrpTask.FRP_EXE_PATH)) {
      const tmpTask = setInterval(() => {
        instance.println("FRP", $t("TXT_CODE_sakura_frp.installing"));
      }, 2000);
      try {
        const url = await resolveLatestFrpcUrl();
        if (!url) {
          instance.println("ERROR", $t("TXT_CODE_sakura_frp.unsupported"));
          return;
        }
        await downloadFileToLocalFile(url, SakuraFrpTask.FRP_EXE_PATH);
        instance.println("FRP", $t("TXT_CODE_sakura_frp.done"));
      } catch (error: any) {
        logger.error($t("TXT_CODE_sakura_frp.downloadErr"), error);
        instance.println("ERROR", $t("TXT_CODE_sakura_frp.downloadErr") + `: ${error}`);
        fs.remove(SakuraFrpTask.FRP_EXE_PATH, () => {});
        return;
      } finally {
        clearInterval(tmpTask);
      }
    }

    const frpProcess = new SakuraFrp(sakuraFrpToken, sakuraFrpTunnelIds);
    frpProcess.processWrapper?.on("start", (pid: number) => {
      if (pid) {
        logger.info(
          `Instance ${instance.config.nickname}(${instance.instanceUuid}) ${pid} Sakura Frp task started!`
        );
        instance.sakuraFrp = frpProcess;
        instance.info.sakuraFrpStatus = true;
      } else {
        logger.warn(
          `Instance ${instance.config.nickname}(${instance.instanceUuid}) Sakura Frp task start failed! Process ID is ${pid}`
        );
      }
    });
    frpProcess.processWrapper?.on("exit", () => {
      logger.info(
        `Instance ${instance.config.nickname}(${instance.instanceUuid}) Sakura Frp task stopped!`
      );
      instance.info.sakuraFrpStatus = false;
      instance.sakuraFrp = undefined;
    });

    try {
      frpProcess.open();
    } catch (error: any) {
      logger.warn(
        `Instance ${instance.config.nickname}(${instance.instanceUuid}) Sakura Frp task Start failure! ERR:`
      );
      logger.warn(error);
    }
  }

  async stop(instance: Instance) {
    if (instance.sakuraFrp) {
      instance.sakuraFrp.stop();
    }
  }
}

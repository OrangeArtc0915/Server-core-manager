import fs from "fs-extra";
import path from "path";
import InstanceSubsystem from "../../service/system_instance";
import { instanceService } from "./instance_service";
import { extractZip, zipEntries } from "./zip_service";

export interface BackupEntry {
  name: string;
  size: number;
  time: number;
}

const BACKUP_ROOT = () => path.join(process.cwd(), "data", "Backups");

class BackupService {
  dir(instanceUuid: string): string {
    return path.join(BACKUP_ROOT(), instanceUuid);
  }

  list(instanceUuid: string): BackupEntry[] {
    const dir = this.dir(instanceUuid);
    if (!fs.existsSync(dir)) return [];
    return fs
      .readdirSync(dir)
      .filter((name) => name.toLowerCase().endsWith(".zip"))
      .map((name) => {
        const stat = fs.statSync(path.join(dir, name));
        return { name, size: stat.size, time: stat.mtimeMs };
      })
      .sort((a, b) => b.time - a.time);
  }

  listAll(): Array<{ instanceUuid: string; nickname: string; backups: BackupEntry[] }> {
    const result: Array<{ instanceUuid: string; nickname: string; backups: BackupEntry[] }> = [];
    for (const instance of InstanceSubsystem.getInstances()) {
      const backups = this.list(instance.instanceUuid);
      if (backups.length) {
        result.push({
          instanceUuid: instance.instanceUuid,
          nickname: instance.config.nickname,
          backups
        });
      }
    }
    return result;
  }

  async create(instanceUuid: string, onProgress?: (message: string) => void): Promise<BackupEntry> {
    const instance = instanceService.get(instanceUuid);
    if (!instance) throw new Error("Instance not found");
    const cwd = instance.absoluteCwdPath();
    if (!fs.existsSync(cwd)) throw new Error(`Working directory not found: ${cwd}`);
    const entries = fs
      .readdirSync(cwd)
      .filter((name) => name !== "backups" && name !== "logs")
      .filter((name) => !/^mcsm_install_package\./i.test(name));
    if (!entries.length) throw new Error("Instance directory is empty");

    const now = new Date();
    const pad = (n: number) => String(n).padStart(2, "0");
    const name = `backup-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(
      now.getHours()
    )}${pad(now.getMinutes())}${pad(now.getSeconds())}.zip`;
    const target = path.join(this.dir(instanceUuid), name);
    await zipEntries(cwd, entries, target, onProgress);
    const stat = fs.statSync(target);
    return { name, size: stat.size, time: stat.mtimeMs };
  }

  async restore(instanceUuid: string, name: string): Promise<void> {
    const instance = instanceService.get(instanceUuid);
    if (!instance) throw new Error("Instance not found");
    const zipFile = path.join(this.dir(instanceUuid), name);
    if (!fs.existsSync(zipFile)) throw new Error("Backup not found");
    await extractZip(zipFile, instance.absoluteCwdPath());
  }

  remove(instanceUuid: string, name: string) {
    const zipFile = path.join(this.dir(instanceUuid), name);
    if (fs.existsSync(zipFile)) fs.removeSync(zipFile);
  }
}

export const backupService = new BackupService();

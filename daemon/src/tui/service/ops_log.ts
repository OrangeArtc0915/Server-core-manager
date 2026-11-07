import fs from "fs-extra";
import path from "path";
import { formatDateTime } from "../format";

export type OpsLevel = "info" | "success" | "error";

const LOG_FILE = () => path.join(process.cwd(), "logs", "operations.log");
const MAX_LINES = 2000;

class OpsLog {
  private lines: string[] = [];
  private loaded = false;

  init() {
    if (this.loaded) return;
    this.loaded = true;
    try {
      const file = LOG_FILE();
      if (fs.existsSync(file)) {
        const text = fs.readFileSync(file, "utf-8");
        this.lines = text.split("\n").filter(Boolean).slice(-MAX_LINES);
      }
    } catch (error) {
      this.lines = [];
    }
  }

  add(action: string, target = "", level: OpsLevel = "info") {
    this.init();
    const line = `[${formatDateTime(Date.now())}] [${level.toUpperCase()}] ${action}${
      target ? ` | ${target}` : ""
    }`;
    this.lines.push(line);
    if (this.lines.length > MAX_LINES) this.lines.splice(0, this.lines.length - MAX_LINES);
    try {
      const file = LOG_FILE();
      if (!fs.existsSync(path.dirname(file))) fs.mkdirsSync(path.dirname(file));
      fs.appendFile(file, line + "\n", () => {});
    } catch (error) {
      // logging must never break the UI
    }
  }

  getLines(): string[] {
    this.init();
    return this.lines;
  }
}

export const opsLog = new OpsLog();

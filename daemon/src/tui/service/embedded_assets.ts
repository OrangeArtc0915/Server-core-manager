import fs from "fs-extra";
import os from "os";
import path from "path";
import logger from "../../service/log";

/**
 * Native components shipped inside the single-file executable.
 *
 * The build embeds 7-Zip (archives) and the MCSManager PTY helper (live
 * terminals) as SEA assets; at runtime they are extracted to `./lib` so they
 * can be executed. The frpc clients are intentionally NOT embedded — they are
 * downloaded on first use to keep the release package small.
 */
function isSea(): boolean {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const sea = require("node:sea");
    return Boolean(sea?.isSea?.());
  } catch (error) {
    return false;
  }
}

export function getEmbeddedAsset(name: string): Buffer | undefined {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const sea = require("node:sea");
    if (sea?.isSea?.()) {
      const keys: string[] = typeof sea.getAssetKeys === "function" ? sea.getAssetKeys() : [];
      if (!keys.includes(name)) return undefined;
      return Buffer.from(sea.getRawAsset(name));
    }
  } catch (error) {
    // not running as a SEA executable
  }
  for (const dir of [
    path.join(process.cwd(), "assets"),
    path.join(__dirname, "..", "..", "assets"),
    path.join(__dirname, "..", "..", "..", "assets")
  ]) {
    try {
      const file = path.join(dir, name);
      if (fs.existsSync(file) && fs.statSync(file).size) return fs.readFileSync(file);
    } catch (error) {
      // ignore unreadable candidates
    }
  }
  return undefined;
}

/** Path of a usable 7-Zip console binary (embedded build first, user copy next). */
export function sevenZipBinaryPath(): string | undefined {
  const candidates = [
    path.join(process.cwd(), "lib", "7zr.exe"),
    path.join(process.cwd(), "lib", `7z_${os.platform()}_${os.arch()}.exe`),
    path.join(process.cwd(), "lib", "7za.exe")
  ];
  for (const file of candidates) {
    try {
      if (fs.existsSync(file) && fs.statSync(file).size > 100 * 1024) return file;
    } catch (error) {
      // ignore unreadable candidates
    }
  }
  return undefined;
}

/** Extract the embedded 7zr so archive handling never needs an external install. */
function releaseSevenZip(): void {
  try {
    const target = path.join(process.cwd(), "lib", "7zr.exe");
    if (fs.existsSync(target) && fs.statSync(target).size > 300 * 1024) return;
    const data = getEmbeddedAsset("7zr.exe");
    if (!data) return;
    fs.mkdirsSync(path.dirname(target));
    fs.writeFileSync(target, data);
    logger.info(`[TUI] Extracted embedded 7zr -> ${target}`);
  } catch (error: any) {
    logger.warn(`[TUI] Cannot release embedded 7zr: ${error?.message ?? error}`);
  }
}

/** Extract the embedded PTY helper so terminals work out of the box. */
function releasePty(): void {
  try {
    const target = path.join(process.cwd(), "lib", "pty_win32_x64.exe");
    if (fs.existsSync(target) && fs.statSync(target).size > 1024 * 1024) return;
    const data = getEmbeddedAsset("pty_win32_x64.exe");
    if (!data) return;
    fs.mkdirsSync(path.dirname(target));
    fs.writeFileSync(target, data);
    if (os.platform() !== "win32") {
      try {
        fs.chmodSync(target, 0o755);
      } catch (error) {
        // best effort on POSIX
      }
    }
    logger.info(`[TUI] Extracted embedded PTY -> ${target}`);
  } catch (error: any) {
    logger.warn(`[TUI] Cannot release embedded PTY: ${error?.message ?? error}`);
  }
}

/** Extract the embedded native components into ./lib at startup. */
export function releaseEmbeddedComponents(): void {
  releaseSevenZip();
  releasePty();
}

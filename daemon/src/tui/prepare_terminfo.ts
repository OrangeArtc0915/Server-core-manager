import fs from "fs-extra";
import os from "os";
import path from "path";

/**
 * Single-file executable support.
 *
 * blessed resolves terminfo from `TERMINFO` (a *directory tree*), from
 * `<bundle dir>/../usr/<name>`, or from its internal fallback table. A SEA
 * executable has no `usr` directory next to itself, so the build embeds
 * `xterm-256color` / `xterm` as assets and we extract them at runtime using the
 * ncurses layout blessed expects:
 *
 *   <root>/x/xterm-256color      (first letter of the entry name)
 *   <root>/78/xterm-256color     (first byte as hex)
 *
 * `Tput.ipaths` is initialized when the module loads, so `applyTerminfo()` also
 * prepends the extracted root at runtime (called from ui.ts before the screen is
 * created).
 */
let cachedRoot: string | undefined;
let extractionTried = false;

function isSea(): boolean {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const sea = require("node:sea");
    return Boolean(sea?.isSea?.());
  } catch (error) {
    return false;
  }
}

function writeEntry(root: string, name: string, data: Buffer) {
  const first = name[0];
  const hex = name.charCodeAt(0).toString(16).padStart(2, "0");
  for (const dir of [path.join(root, first), path.join(root, hex)]) {
    fs.mkdirsSync(dir);
    fs.writeFileSync(path.join(dir, name), data);
  }
  // Flat copy as well, harmless and helps tools that read the file directly.
  fs.writeFileSync(path.join(root, name), data);
}

/** Extract the embedded terminfo (once) and return the terminfo root directory. */
export function ensureTerminfoRoot(): string | undefined {
  if (cachedRoot && fs.existsSync(path.join(cachedRoot, "x", "xterm-256color"))) return cachedRoot;
  if (extractionTried) return undefined;
  extractionTried = true;

  const assets = readAssets();
  if (!assets) {
    // eslint-disable-next-line no-console
    console.error("[TUI] Embedded terminfo asset not found.");
    return undefined;
  }

  const candidates = [
    path.join(os.tmpdir(), "craftdock-terminfo"),
    path.join(process.cwd(), ".craftdock-terminfo")
  ];

  for (const root of candidates) {
    try {
      fs.mkdirsSync(root);
      for (const name of Object.keys(assets)) {
        writeEntry(root, name, assets[name]);
      }
      const main = path.join(root, "x", "xterm-256color");
      if (!fs.statSync(main).size) throw new Error("empty asset");
      cachedRoot = root;
      return root;
    } catch (error: any) {
      // eslint-disable-next-line no-console
      console.error(`[TUI] Cannot write terminfo to ${root}: ${error?.message ?? error}`);
    }
  }
  return undefined;
}

/**
 * Terminfo sources: the embedded SEA assets, or (for plain `node tui.js`
 * bundle runs) the `usr/` directory copied next to the bundle at build time.
 */
function readAssets(): Record<string, Buffer> | undefined {
  const names = ["xterm-256color", "xterm"];

  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const sea = require("node:sea");
    if (sea?.isSea?.()) {
      const keys: string[] = typeof sea.getAssetKeys === "function" ? sea.getAssetKeys() : [];
      const assets: Record<string, Buffer> = {};
      for (const name of names) {
        if (keys.includes(name)) assets[name] = Buffer.from(sea.getRawAsset(name));
      }
      return Object.keys(assets).length ? assets : undefined;
    }
  } catch (error) {
    // not a SEA executable
  }

  for (const dir of [path.join(__dirname, "..", "usr"), path.join(process.cwd(), "usr")]) {
    const assets: Record<string, Buffer> = {};
    for (const name of names) {
      try {
        const file = path.join(dir, name);
        if (fs.existsSync(file) && fs.statSync(file).size) assets[name] = fs.readFileSync(file);
      } catch (error) {
        // ignore unreadable candidates
      }
    }
    if (Object.keys(assets).length) return assets;
  }
  return undefined;
}

/** Point blessed at the extracted terminfo. Safe to call multiple times. */
export function applyTerminfo(): void {
  const root = ensureTerminfoRoot();
  if (!root) return;

  process.env.TERMINFO = root;

  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const Tput = require("blessed/lib/tput");
    const paths: string[] = Tput?.ipaths;
    if (Array.isArray(paths)) {
      const index = paths.indexOf(root);
      if (index > 0) paths.splice(index, 1);
      if (index !== 0) paths.unshift(root);
    }
  } catch (error) {
    // blessed not loaded yet (prepare_terminfo imported first) - env is enough.
  }
}

if (isSea()) {
  const root = ensureTerminfoRoot();
  if (root) process.env.TERMINFO = root;
}

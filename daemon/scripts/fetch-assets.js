/**
 * Prepare the native components that are embedded into the single-file
 * executable as SEA assets, then regenerate sea-tui.json so the build only
 * references files that actually exist.
 *
 * Embedded: 7zr (archives) and the MCSManager PTY helper (live terminals).
 * frpc clients are NOT embedded: they are downloaded on first use by the
 * FRP page, which keeps the release package small.
 *
 * Run from src/daemon (build-tui-exe.bat does this before the SEA step).
 */
const fs = require("fs");
const path = require("path");
const axios = require("axios");

const ROOT = path.join(__dirname, "..");
const ASSETS = path.join(ROOT, "assets");
const UA = "CraftDock/1.0 (MCSManager Custom TUI)";

function log(message) {
  process.stdout.write(`[assets] ${message}\n`);
}

async function download(url, target) {
  const response = await axios({
    url,
    method: "GET",
    responseType: "stream",
    timeout: 180000,
    maxRedirects: 8,
    headers: { "User-Agent": UA }
  });
  await new Promise((resolve, reject) => {
    const out = fs.createWriteStream(target);
    response.data.on("error", reject);
    out.on("error", reject);
    out.on("finish", resolve);
    response.data.pipe(out);
  });
}

async function fetchSevenZip() {
  const target = path.join(ASSETS, "7zr.exe");
  if (fs.existsSync(target) && fs.statSync(target).size > 300 * 1024) return target;
  // Official 7-Zip standalone console build (7z format only, ~600 KB).
  const url = "https://www.7-zip.org/a/7zr.exe";
  log(`7zr <- ${url}`);
  await download(url, target);
  if (fs.statSync(target).size < 300 * 1024) throw new Error("7zr.exe looks truncated");
  return target;
}

/**
 * MCSManager's PTY helper is only published inside the daemon release zip.
 * A pre-seeded assets/pty_win32_x64.exe wins, otherwise the matching daemon
 * package is downloaded once and the single binary is extracted from it.
 */
async function fetchPty() {
  const target = path.join(ASSETS, "pty_win32_x64.exe");
  if (fs.existsSync(target) && fs.statSync(target).size > 1024 * 1024) return target;
  const zipPath = path.join(ASSETS, "mcsmanager-daemon-win.zip");
  if (!fs.existsSync(zipPath) || fs.statSync(zipPath).size < 10 * 1024 * 1024) {
    const url =
      "https://github.com/MCSManager/MCSManager/releases/download/v10.18.3/mcsmanager_windows_daemon_only_release.zip";
    log(`pty <- ${url}`);
    await download(url, zipPath);
  }
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const StreamZip = require("node-stream-zip");
  const zip = new StreamZip.async({ file: zipPath });
  try {
    const names = Object.keys(await zip.entries());
    const member =
      names.find((name) => /(^|\/)lib\/pty_win32_x64\.exe$/i.test(name)) ||
      names.find((name) => /(^|\/)pty_win32_x64\.exe$/i.test(name));
    if (!member) throw new Error("pty_win32_x64.exe not found in the daemon package");
    await zip.extract(member, target);
  } finally {
    await zip.close().catch(() => {});
  }
  if (fs.statSync(target).size < 1024 * 1024) throw new Error("pty_win32_x64.exe looks truncated");
  log(`pty extracted from ${path.basename(zipPath)}`);
  return target;
}

async function main() {
  fs.mkdirSync(ASSETS, { recursive: true });
  const assets = {
    "xterm-256color": "node_modules/blessed/usr/xterm-256color",
    xterm: "node_modules/blessed/usr/xterm"
  };

  const jobs = [
    ["7zr.exe", fetchSevenZip],
    ["pty_win32_x64.exe", fetchPty]
  ];
  for (const [name, job] of jobs) {
    try {
      const file = await job();
      assets[name] = path.relative(ROOT, file).replace(/\\/g, "/");
      log(`${name} ready (${(fs.statSync(file).size / 1048576).toFixed(1)} MB)`);
    } catch (error) {
      log(`WARN cannot fetch ${name}: ${error.message}`);
    }
  }

  const config = {
    main: "production/tui.js",
    output: "production/tui-sea.blob",
    disableExperimentalSEAWarning: true,
    useSnapshot: false,
    useCodeCache: false,
    assets
  };
  fs.writeFileSync(path.join(ROOT, "sea-tui.json"), `${JSON.stringify(config, null, 2)}\n`);
  log(`sea-tui.json written with ${Object.keys(assets).length} assets`);
}

main().catch((error) => {
  console.error(`[assets] ${error.stack ?? error.message}`);
  process.exit(1);
});

/**
 * blessed resolves its bundled terminfo database with `__dirname + '/../usr'`.
 * After webpack bundling, `__dirname` points at the bundle directory, so the
 * `usr` folder from node_modules/blessed must be copied one level above it.
 *
 * Dev layout : daemon/production/tui.js  -> daemon/usr
 * Release    : production-code/daemon/tui.js -> production-code/usr
 */
const fs = require("fs");
const path = require("path");

const source = path.join(__dirname, "..", "node_modules", "blessed", "usr");
const target = path.join(__dirname, "..", "usr");

if (!fs.existsSync(source)) {
  console.warn(`[tui] blessed terminfo database not found: ${source}`);
  process.exit(0);
}

fs.mkdirSync(target, { recursive: true });
fs.cpSync(source, target, { recursive: true });
console.log(`[tui] Copied blessed terminfo -> ${target}`);

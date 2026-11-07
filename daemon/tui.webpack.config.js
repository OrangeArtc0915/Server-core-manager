const base = require("./webpack.config.js");

const BUNDLE = process.env.BUNDLE === "1";

/**
 * TUI build: a second entry that reuses the daemon webpack rules (TypeScript,
 * bundle mode, language packs) but emits `production/tui.js`.
 *
 * blessed ships an optional `terminal` widget that requires `term.js` / `pty.js`
 * (not installed). They are only needed by that widget, which the TUI never
 * uses, so they stay external and are never loaded at runtime.
 */
module.exports = {
  ...base,
  entry: "./src/tui/main.ts",
  output: {
    ...base.output,
    filename: "tui.js"
  },
  externals: BUNDLE
    ? [
        ...(Array.isArray(base.externals) ? base.externals : []),
        { "term.js": "commonjs term.js", "pty.js": "commonjs pty.js" }
      ]
    : base.externals
};

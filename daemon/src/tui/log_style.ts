/**
 * Log-level coloring for the instance terminal and the daemon log viewer.
 * INFO is white, WARN yellow, ERROR red; DEBUG/TRACE get cooler tones.
 */
import { PAL } from "./theme";

export type LogLevel = "trace" | "debug" | "success" | "info" | "warn" | "error";

const LEVEL_TOKEN = /\b(TRACE|DEBUG|SUCCESS|INFO|NOTICE|WARN|WARNING|ERROR|SEVERE|FATAL|CRITICAL)\b/i;

/** Resolved per call so a theme switch applies to already-running views. */
function levelColor(level: LogLevel): string {
  switch (level) {
    case "trace":
      return PAL.dim;
    case "debug":
      return PAL.cyan;
    case "success":
      return PAL.green;
    case "info":
      return PAL.bright;
    case "warn":
      return PAL.yellow;
    default:
      return PAL.red;
  }
}

/** Detect the level of a log line; null means "no explicit level". */
export function detectLevel(line: string): LogLevel | null {
  const match = LEVEL_TOKEN.exec(line);
  if (match) {
    switch (match[1].toUpperCase()) {
      case "TRACE":
        return "trace";
      case "DEBUG":
        return "debug";
      case "SUCCESS":
        return "success";
      case "INFO":
      case "NOTICE":
        return "info";
      case "WARN":
      case "WARNING":
        return "warn";
      default:
        return "error";
    }
  }
  // Java stack traces and crash reports carry no level token.
  if (/Caused by:|Exception\b|\bError\b|^\s+at\s+[\w$.]+\(|^Traceback\b/.test(line)) {
    return "error";
  }
  return null;
}

/** Escape braces so log content cannot be parsed as blessed tags. */
function escape(text: string): string {
  return text.replace(/[{}]/g, (ch) => (ch === "{" ? "{open}" : "{close}"));
}

function tag(color: string, text: string, bold = false): string {
  return bold ? `{bold}{${color}-fg}${text}{/}{/bold}` : `{${color}-fg}${text}{/}`;
}

const LEADING = /^(?:\[[^\]]*\]\s*)+/;

/**
 * Paint one log line. The leading `[12:34:56]` style prefix is dimmed unless it
 * already contains the level (Paper prints `[12:34:56 INFO]:`), the body gets
 * the level color.
 */
export function paintLogLine(line: string): string {
  const text = String(line ?? "");
  if (!text) return "";
  const level = detectLevel(text);
  const color = level ? levelColor(level) : PAL.text;
  const bold = level === "error";
  const lead = LEADING.exec(text);
  const body = lead && lead[0].length < text.length ? text.slice(lead[0].length) : "";
  if (lead && body && !LEVEL_TOKEN.test(lead[0])) {
    return tag(PAL.dim, escape(lead[0])) + tag(color, escape(body), bold);
  }
  return tag(color, escape(text), bold);
}

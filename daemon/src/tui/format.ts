import { t } from "./lang";

export function formatBytes(bytes?: number): string {
  if (bytes == null || isNaN(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value >= 100 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`;
}

export function formatDuration(seconds: number): string {
  if (!numbersFinite(seconds) || seconds <= 0) return "-";
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = Math.floor(seconds % 60);
  if (days > 0) return `${days}${t("common.days")}${hours}${t("common.hours")}`;
  if (hours > 0) return `${hours}${t("common.hours")}${minutes}${t("common.minutes")}`;
  if (minutes > 0) return `${minutes}${t("common.minutes")}${secs}${t("common.seconds")}`;
  return `${secs}${t("common.seconds")}`;
}

function numbersFinite(value: number): boolean {
  return Number.isFinite(value);
}

export function formatDateTime(timestamp?: number): string {
  if (!timestamp) return "-";
  const date = new Date(timestamp);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(
    date.getHours()
  )}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

export function formatClock(): string {
  const date = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

export function statusText(status: number): string {
  const key = `status.${status}`;
  return t(key);
}

export function statusColor(status: number): string {
  switch (status) {
    case 3:
      return "#3fb950";
    case 2:
    case 1:
      return "#d29922";
    case -1:
      return "#bc8cff";
    default:
      return "#8b949e";
  }
}

export function typeLabel(type?: string): string {
  if (!type) return "-";
  return type.replace(/^minecraft\//, "").replace(/\//g, "-");
}

export function shortUuid(uuid: string): string {
  return uuid ? uuid.slice(0, 8) : "-";
}

export function boolText(value: boolean | undefined): string {
  return value ? "1" : "0";
}

export function parseBool(value: string): boolean {
  return ["1", "true", "y", "yes", "on"].includes(String(value).trim().toLowerCase());
}

export function parseNumber(value: string, fallback: number): number {
  const n = Number(String(value).trim());
  return Number.isFinite(n) ? n : fallback;
}

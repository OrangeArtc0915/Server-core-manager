import { spawn } from "child_process";

/** Open a URL with the system default browser (detached, never blocks). */
export function openExternal(url: string): void {
  const child =
    process.platform === "win32"
      ? spawn("cmd.exe", ["/c", "start", "", url], {
          windowsHide: true,
          detached: true,
          stdio: "ignore"
        })
      : process.platform === "darwin"
        ? spawn("open", [url], { detached: true, stdio: "ignore" })
        : spawn("xdg-open", [url], { detached: true, stdio: "ignore" });
  child.on("error", () => undefined);
  child.unref();
}

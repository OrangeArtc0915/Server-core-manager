import archiver from "archiver";
import { spawn } from "child_process";
import fs from "fs-extra";
import path from "path";
import StreamZip from "node-stream-zip";
import { sevenZipBinaryPath } from "./embedded_assets";

/** Validate that `child` stays inside `base`. */
function ensureInside(base: string, child: string) {
  const rel = path.relative(base, child);
  if (rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel)) {
    throw new Error("Path escapes the base directory");
  }
}

/**
 * Create a zip from entries (files/directories) relative to `baseDir`.
 * Uses archiver (pure JS) so it works without the external Zip-Tools binary.
 */
export function zipEntries(
  baseDir: string,
  entries: string[],
  outFile: string,
  onProgress?: (message: string) => void
): Promise<void> {
  return new Promise((resolve, reject) => {
    try {
      fs.mkdirsSync(path.dirname(outFile));
      const output = fs.createWriteStream(outFile);
      const archive = archiver("zip", { zlib: { level: 6 } });

      output.on("close", () => resolve());
      output.on("error", (error) => reject(error));
      archive.on("warning", (error) => {
        if ((error as any).code !== "ENOENT") reject(error);
      });
      archive.on("error", (error) => reject(error));
      archive.on("progress", (data) => {
        onProgress?.(`${data.entries.processed}/${data.entries.total}`);
      });

      archive.pipe(output);
      for (const entry of entries) {
        const abs = path.normalize(path.join(baseDir, entry));
        ensureInside(baseDir, abs);
        if (!fs.existsSync(abs)) continue;
        const info = fs.statSync(abs);
        if (info.isDirectory()) archive.directory(abs, entry);
        else archive.file(abs, { name: entry });
      }
      void archive.finalize();
    } catch (error) {
      reject(error);
    }
  });
}

/** Extract a zip into destDir (zip-slip safe, overwrites existing files). */
export async function extractZip(zipFile: string, destDir: string): Promise<void> {
  const zip = new StreamZip.async({ file: zipFile });
  try {
    const entries = await zip.entries();
    for (const name of Object.keys(entries)) {
      const target = path.resolve(destDir, name);
      ensureInside(destDir, target);
    }
    fs.mkdirsSync(destDir);
    await zip.extract(null, destDir);
  } finally {
    await zip.close().catch(() => {});
  }
}

function runSevenZip(args: string[], cwd: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const binary = sevenZipBinaryPath();
    if (!binary) {
      reject(new Error("内置 7z 组件缺失，请重新构建程序"));
      return;
    }
    const child = spawn(binary, args, {
      cwd,
      windowsHide: true,
      timeout: 30 * 60 * 1000
    });
    let output = "";
    child.stdout?.on("data", (chunk: Buffer) => (output += chunk.toString()));
    child.stderr?.on("data", (chunk: Buffer) => (output += chunk.toString()));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      const detail = output
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean)
        .slice(-3)
        .join(" ");
      reject(new Error(`7z 处理失败（退出码 ${code}）${detail ? "：" + detail : ""}`));
    });
  });
}

/** True for archives handled by the embedded 7zr binary. */
export function isSevenZipArchive(file: string): boolean {
  return /\.7z$/i.test(file);
}

/** Create a .7z archive with the embedded 7zr binary. */
export async function create7z(baseDir: string, entries: string[], outFile: string): Promise<void> {
  fs.mkdirsSync(path.dirname(outFile));
  await runSevenZip(["a", "-y", outFile, ...entries], baseDir);
}

/** Extract a .7z archive with the embedded 7zr binary. */
export async function extract7z(file: string, destDir: string): Promise<void> {
  fs.mkdirsSync(destDir);
  await runSevenZip(["x", "-y", `-o${destDir}`, file], path.dirname(file));
}

/** Extract an archive, routing .7z to the embedded binary and the rest to zlib. */
export async function extractArchive(file: string, destDir: string): Promise<void> {
  if (isSevenZipArchive(file)) {
    await extract7z(file, destDir);
    return;
  }
  await extractZip(file, destDir);
}

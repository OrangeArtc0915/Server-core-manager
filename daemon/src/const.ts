import os from "os";
import path from "path";

const SYS_INFO = `${os.platform()}_${os.arch()}${os.platform() === "win32" ? ".exe" : ""}`;
const ptyName = `pty_${SYS_INFO}`;
const PTY_PATH = path.normalize(path.join(process.cwd(), "lib", ptyName));
const FILENAME_BLACKLIST = ["\\", "/", ".", "'", '"', "?", "*", "<", ">"];
const LOCAL_PRESET_LANG_PATH = path.normalize(path.join(process.cwd(), "language"));
const IGNORE = "[IGNORE_LOG]";
const SYSTEM_TYPE = os.platform();
const ZIP_TIMEOUT_SECONDS = 60 * 40;
const GOLANG_ZIP_NAME = `file_zip_${SYSTEM_TYPE}_${os.arch()}${
  SYSTEM_TYPE === "win32" ? ".exe" : ""
}`;
const GOLANG_ZIP_PATH = path.normalize(path.join(process.cwd(), "lib", GOLANG_ZIP_NAME));

const SEVEN_ZIP_NAME = `7z_${os.platform()}_${os.arch()}${os.platform() === "win32" ? ".exe" : ""}`;
const SEVEN_ZIP_PATH = path.normalize(path.join(process.cwd(), "lib", SEVEN_ZIP_NAME));

export {
  FILENAME_BLACKLIST,
  GOLANG_ZIP_PATH,
  IGNORE,
  LOCAL_PRESET_LANG_PATH,
  PTY_PATH,
  SEVEN_ZIP_NAME,
  SEVEN_ZIP_PATH,
  SYSTEM_TYPE,
  ZIP_TIMEOUT_SECONDS
};

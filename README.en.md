# Server Core Manager

**Run GUI applications on Windows Server Core — for real.**

Windows Server Core ships without a desktop, without `explorer.exe`, without `dwm.exe`. Most GUI programs (QQ / Electron apps / WPF tools / .NET desktop apps / MMC snap-ins) either crash or render a blank window. This tool turns the whole chain — *complete the graphics stack → add your programs → launch and troubleshoot* — into one-click operations, and it ships with **its own GUI**, so you are not stuck in a terminal all day.

```
Two installation methods:  (1) one-line command   (2) zip package
```

> Chinese documentation: [README.md](README.md)

---

## Table of contents

- [The problem](#the-problem)
- [How it works](#how-it-works)
- [Features](#features)
- [Install (1) one-line command](#install-1-one-line-command)
- [Install (2) zip package](#install-2-zip-package)
- [Quick start](#quick-start)
- [Measured results](#measured-results)
- [Requirements](#requirements)
- [Known limitations](#known-limitations)
- [FAQ](#faq)
- [License](#license)

---

## The problem

Advice found around the web for running GUI apps on Server Core is frequently wrong. Every conclusion in this project comes from real testing on Hyper-V with **Windows Server 2022 Core**, and the pitfalls are baked into the code:

| Common claim | What testing actually showed |
|---|---|
| "Just install `Server-Gui-Shell` to get the desktop back" | **That feature does not exist on Server Core.** `Install-WindowsFeature` fails outright. |
| "You can't run GUI apps on Server Core" | **You can.** After installing the official **App Compatibility FOD** and rebooting, WinForms / WPF / Electron all render correctly. |
| "Just run DISM over remote PowerShell" | Over WinRM network tokens, **DISM write operations are denied**. The tool automatically falls back to a SYSTEM scheduled task. |
| "Windows Admin Center works right after install" | The v2 installer **restarts WinRM**, killing the remote session — and **leaves the service stopped**. It needs an explicit finishing step. |
| "Electron apps are just that slow on Server Core" | With `--disable-gpu --disable-software-rasterizer`, measured **3× faster start and 85% less CPU**. |

---

## How it works

**The only official path: App Compatibility Feature on Demand (FOD)**

```
Add-WindowsCapability -Online -Name ServerCore.AppCompatibility~~~~0.0.1.0
→ reboot
→ dwm.exe / dcomp.dll / dwrite.dll are now present
→ GUI applications can render
```

After the FOD is applied, 15 key components appear, including:

`dwm.exe`, `dcomp.dll`, `uDWM.dll`, `dwmcore.dll`, `dwmredir.dll`, `d3d10warp.dll`, `UIAnimation.dll`, `wuceffects.dll`, `mmc.exe`, `explorer.exe`, `eventvwr.exe`, `perfmon.exe`, `resmon.exe` …

Components are tracked in three groups, 51 in total: core baseline 21, FOD-provided 7, and **desktop-experience exclusive 23**. Even after the FOD, **4 of those 23 remain missing** (`twinui.dll`, `themeservice.dll`, `themeui.dll`, `DispBroker.dll`) — which is exactly why the scenarios in [Known limitations](#known-limitations) still do not work.

---

## Features

### GUI (4 pages + 7 status cards)

| Page | Contents |
|---|---|
| **Environment** | 7 status cards (OS build / graphics components / render pipeline / .NET runtimes / logon sessions / UAC / Web management) plus one-click completion, re-scan, GUI self-test, verdict routing, auto-logon, Windows Admin Center |
| **Software** | Add program, launch, edit launch arguments, persistent background launch, launch diagnostics, view compatibility profile, remove |
| **Tools** | **20 system tool shortcuts**, automatically greyed out when the target is absent: Notepad, File Explorer, Command Prompt, PowerShell, Task Manager, MMC, Services, Device Manager, Disk Management, Task Scheduler, Local Users and Groups, Certificates, Windows Firewall, Registry Editor, Event Viewer, Performance Monitor, Resource Monitor, System Information, Hyper-V Manager, PowerShell ISE |
| **More** | All **32 actions** in 7 groups |

### 32 actions, 7 groups

- **One-click flows (5)** — full environment completion, resume after reboot, pipeline status, RDP repair, verdict routing
- **Detection & diagnostics (5)** — environment scan, GUI capability self-test, static PE pre-check, launch diagnostics, troubleshooting bundle
- **Program profiles (3)** — compatibility lookup, measured arguments, program list
- **Provisioning (4)** — install App Compatibility FOD, portable .NET runtime, .NET Desktop Runtime, list installed frameworks
- **Sessions & logon (8)** — auto-logon (enable / disable / status), session list, logon shell, persistent launch, RDP repair …
- **Usage & tools (3)** — graphical launcher, Phase B guide, logs and reports
- **Windows Admin Center (4)** — status check, one-click install & configure, service control, open UI

### Windows Admin Center, one-click

- If no installer is present locally, it **downloads from the official URL** (`aka.ms/WACDownload`, ~140 MB). Use `-NoDownload` for offline / air-gapped environments.
- Detects both installer generations and dispatches the right silent arguments: classic MSI uses `msiexec` + `SME_*`; v2 (Inno Setup) uses `/VERYSILENT`.
- After installing it **opens the firewall, sets automatic startup, starts the service, and probes `/shell/`** before printing the browser URL.
- Everything runs through a SYSTEM scheduled task, because the v2 installer restarts WinRM and would otherwise kill the calling session.

### Program compatibility profiles (`lib/catalog.json`)

Every entry carries **measured evidence**, not guesswork:

```json
{
  "id": "qq-nt",
  "name": "Tencent QQ NT (Electron)",
  "verdict": "works (recommended args)",
  "launchArgs": "--disable-gpu --disable-software-rasterizer",
  "verifiedOn": "20348.2700",
  "evidence": "A/B test: default 18.2s to first window / 30.5s CPU; with args 6.0s / 4.6s"
}
```

When you add a program, the tool reads its PE header to classify it as .NET / Electron / WPF / native, then **fills in the measured recommended arguments automatically**.

---

## Install (1) one-line command

In an **administrator** PowerShell:

```powershell
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

It downloads the latest release package, extracts it to `C:\Program Files\ServerCoreManager`, clears the "from the Internet" file block, and installs the `scm` command.

Afterwards, **type `scm` in any directory** to open the GUI (it self-elevates once, exactly like `sconfig`).

To change defaults, use environment variables (`iex` cannot forward parameters):

```powershell
$env:SCM_DEST = 'D:\SCM'      # change install directory
$env:SCM_NO_COMMAND = '1'     # skip the scm command
irm https://raw.githubusercontent.com/OrangeArtc0915/Server-core-manager/main/install.ps1 | iex
```

Or save [install.ps1](install.ps1) as a file and run it as a normal script, which accepts parameters directly:

```powershell
.\install.ps1 -Dest 'D:\SCM' -NoCommand
```

> **Re-running performs an upgrade**: program files are overwritten, but your program list (`launcher\programs.json`), logs and resume state are preserved.

---

## Install (2) zip package

1. Download `ServerCoreManager.zip` from [Releases](https://github.com/OrangeArtc0915/Server-core-manager/releases)
2. Extract anywhere, e.g. `D:\ServerCoreManager`
3. Right-click **Run as administrator** on `一键运行.bat` ("Run" — the file name is Chinese)

### What's inside

```
ServerCoreManager.zip
├─ 一键运行.bat              ← double-click entry (self-elevates, opens the GUI)
├─ 打开命令行菜单.bat        ← console menu entry (15-item two-level menu)
├─ 安装一行命令.bat          ← installs scm into PATH
├─ Start-GuiReadyApp.ps1     ← unified entry (GUI by default, -Console for the menu)
├─ Start-GuiReady.ps1        ← console menu
├─ Install-GuiReadyCommand.ps1
├─ Resume-GuiReadyPipeline.ps1
├─ install.ps1 / pack.ps1 / LICENSE / README*
├─ gui\    ← GUI (main window, action manifest, action runner)
├─ lib\    ← all capability modules (16) + catalog.json
└─ launcher\ ← lightweight panel for RDP sessions (usable as the logon shell)
```

> If PowerShell refuses to run the scripts after a manual extraction, the package carries the "from the Internet" mark. Run once in the tool directory:
> `Get-ChildItem -Recurse *.ps1 | Unblock-File`

---

## Quick start

1. **Open the tool** — `scm`, or double-click `一键运行.bat`
2. **Look at the Environment page** — the 7 cards tell you what's missing
3. **Click "one-click completion"** — installs the official App Compatibility FOD (a few hundred MB from Windows Update)
4. **Reboot** — required for the graphics components to load. The tool supports **resuming across reboots**; open it again and it continues where it left off
5. **Add your program on the Software page** — measured recommended arguments are filled in automatically
6. **Launch** — if it fails, click "launch diagnostics": it inspects the event log, WER records, and missing DLLs/runtimes, then suggests what to do

---

## Measured results

All on **Windows Server 2022 Core (build 20348.2700)** under Hyper-V.

### Tencent QQ NT 9.9.35 (Electron)

| Launch arguments | Time to first window | Memory | CPU time |
|---|---|---|---|
| default | 18.2 s | 385.9 MB | 30.5 s |
| `--disable-gpu` | 15.1 s | — | — |
| **`--disable-gpu --disable-software-rasterizer`** | **6.0 s** | **325.7 MB** | **4.6 s** |

9 processes running normally afterwards. The reason: Server Core has no GPU driver and no full DWM composition, so Chromium's GPU process fails and retries repeatedly, which delays startup and burns CPU.

### MSLX-Daemon (.NET 10 / ASP.NET Core)

Missing the .NET 10.0.0 runtime → deployed 10.0.12 in portable (zip) mode → Kestrel started and listened on `1027`; the web console rendered correctly in a browser and login succeeded.

### Auto-logon, end to end

LSA secret written (password never stored in plaintext in the registry) → real reboot → auto-logon into the `console` session → full GUI self-test passed (full-screen capture 98.2% non-black).

### GUI capability self-test

The tool ships with `-SelfTest` and `-LayoutDump`: the former verifies page/card/button counts, the latter dumps the real control-tree coordinates and flags out-of-bounds controls. Both exist to prove the UI actually rendered on Server Core, rather than merely "the process is still alive".

---

## Requirements

| Item | Requirement |
|---|---|
| OS | Windows Server 2016 / 2019 / 2022 / 2025 **Core** (tested on 2022 Core build 20348.2700) |
| PowerShell | 5.1 or later (the bundled one is fine; PowerShell 7 not required) |
| Privileges | Administrator (provisioning, WAC, LSA writes all require it) |
| Disk | ~5 GB free on C: recommended (FOD package + components) |
| Network | Windows Update reachable for the FOD; offline environments can use a FOD ISO with `-Source` |

---

## Known limitations

Stated honestly — what this cannot do:

1. **UWP / XAML apps do not work.** After the FOD, `twinui.dll` is still missing.
2. **The UI uses the classic theme.** `themeservice.dll` / `themeui.dll` are missing, so windows do not get the modern theme and look closer to Windows 7 / Classic. The missing `DispBroker.dll` limits some display-related capabilities as well.
3. **Of the 23 desktop-experience components, 4 remain missing** even after completion: `twinui.dll`, `themeservice.dll`, `themeui.dll`, `DispBroker.dll`.
4. **Not a remote-desktop replacement.** This tool adds graphics capability *on the Server Core machine itself*; programs render locally. "Run a GUI on a headless box and view it over the network" is a different direction — see the "Phase B (IDD remote rendering) guide" inside the tool.
5. **No GPU acceleration for Electron apps.** They fall back to software rendering, hence the recommended disable-GPU arguments. That is a property of the Server Core environment, not a defect of this tool.
6. **The FOD download from Windows Update is large and network-sensitive** and can fail. The tool includes Chinese remediation hints for common error codes (`0x800f0954` / `0x800f0831` / `0x80240021`, etc.).

---

## FAQ

**Q: Is a reboot really required?**
Yes. The graphics components (`dwm.exe`, `dcomp.dll`, …) only load after a reboot. The tool resumes across reboots — reopen it and it continues.

**Q: After the FOD the UI still looks dated / theming is off.**
Expected. See limitation #2.

**Q: `scm` says the tool entry cannot be found.**
The tool directory was moved or renamed. Re-run `安装一行命令.bat` from that directory (the generated `.cmd` has the tool path baked in).

**Q: PowerShell says the file is not digitally signed.**
The package carries the "from the Internet" mark. Run `Get-ChildItem <tool dir> -Recurse *.ps1 | Unblock-File`. The one-line install method handles this automatically.

**Q: Windows Admin Center is installed but unreachable.**
Run "Windows Admin Center → status check" first. Two key points: **the entry point is `/shell/`, not the root path** (the root returns 403, which is the normal status code of the sign-in page, not a failure); and the self-signed certificate requires clicking "continue" in the browser.

**Q: Why use this instead of following a tutorial manually?**
Because it chains "decide which route applies → install the right thing → verify it worked → diagnose when it doesn't" into one flow, and rules out the misinformation circulating in the community (such as `Server-Gui-Shell`) up front. You can absolutely run the commands yourself — the tool just saves you the work.

---

## Uninstall

```powershell
# 1) remove the one-word command
& 'C:\Program Files\ServerCoreManager\Install-GuiReadyCommand.ps1' -Uninstall

# 2) delete the install directory (the tool writes no registry keys other than the auto-logon entry below)
Remove-Item 'C:\Program Files\ServerCoreManager' -Recurse -Force
```

If you enabled **auto-logon**, disable it inside the tool first ("Sessions & logon → auto-logon → disable"), otherwise the auto-logon configuration remains in the registry and LSA.

An already-installed **App Compatibility FOD is not removed** (it is a system component). To remove it:

```powershell
Remove-WindowsCapability -Online -Name ServerCore.AppCompatibility~~~~0.0.1.0
```

---

## License

[GPL-3.0](LICENSE) — free to use, modify and distribute, but **modified distributions must also be released under GPL-3.0**.

Every "measured result" in this project comes from a real test record. Contributions of verified hardware/software profiles (`lib/catalog.json`) are welcome.

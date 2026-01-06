# Install Flutter on Windows Without Android Studio

[![License: MIT](https://img.shields.io/github/license/saty-a/flutter-dev-setup)](LICENSE)
![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Windows: supported](https://img.shields.io/badge/Windows-supported-0078D6?logo=windows&logoColor=white)
![macOS: supported](https://img.shields.io/badge/macOS-supported-000000?logo=apple&logoColor=white)
![Linux: help wanted](https://img.shields.io/badge/Linux-help%20wanted-lightgrey?logo=linux&logoColor=black)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](http://makeapullrequest.com)

One PowerShell script that sets up a complete Flutter **and** Android build toolchain on
Windows 10/11 — Git for Windows, the latest stable Flutter SDK, Eclipse Temurin JDK 17 and
the Android SDK **command-line tools** — then sets `ANDROID_HOME`, `JAVA_HOME` and your user
`PATH`, accepts all Android SDK licenses, then runs `flutter doctor` so you can see exactly
where you stand.
No Android Studio, no VS Code, no Chocolatey/winget/Scoop, and **no administrator rights**.

macOS gets the same thing from `macos/setup.sh` — one bash script, Apple Silicon and Intel,
no sudo and no Homebrew.

> **Hours of manual Flutter and Android SDK setup, reduced to one double-click.**

**Windows and macOS are fully supported. Linux is still a TODO stub** — see
[Platform status and roadmap](#platform-status-and-roadmap).

---

## Quick start (Windows)

1. **Get the files.** Click **Code → Download ZIP**, then right-click the ZIP →
   *Extract All*. (Or `git clone https://github.com/saty-a/flutter-dev-setup.git`
   if you already have Git — the script installs it for you if you don't.)
2. **Open the `windows` folder and double-click `run-setup.bat`.**
3. **Wait.** Most of the time is downloading and unzipping (the Flutter SDK alone is ~1 GB).
   The window stays open at the end and prints a summary table plus the log file path.

That's it. Nothing to install first, nothing to elevate, nothing to configure.

When it finishes: **open a *new* terminal** — `PATH` changes never reach already-open
windows — and run:

```powershell
flutter doctor
```

If double-clicking is blocked by policy, or you want flags, see
[Running it from PowerShell](#running-it-from-powershell-flags).

## Quick start (macOS)

Apple Silicon and Intel, macOS 12 or newer. Requires the Xcode Command Line Tools for
`git` — if they are missing the script tells you to run `xcode-select --install` and stops
rather than hanging on the GUI prompt.

```bash
git clone https://github.com/saty-a/flutter-dev-setup.git
cd flutter-dev-setup
bash macos/setup.sh
```

Same flags as Windows, in Unix spelling:

| Flag | Effect |
|---|---|
| `--verify-only` | Check and report only; changes nothing |
| `--skip-android` | Skip the JDK and Android SDK steps |
| `--install-root <path>` | Default `$HOME/dev` (no spaces — a Flutter limitation) |
| `--precache` | Also run `flutter precache --android` |

It installs under `$HOME/dev` and writes a single marker-delimited block to your shell
profile (`~/.zprofile` for zsh — it prints which file it chose). When it finishes, open a
new terminal (or `source` that file) and run `flutter doctor`.

---

## Why this exists

Getting Flutter building Android apps on a fresh Windows machine is not one install. It is a
Flutter zip, a JDK, Android `cmdline-tools`, three `sdkmanager` packages, `PATH` plus
`ANDROID_HOME` and `JAVA_HOME`, and a license prompt — in the right order, in a path with no
spaces, without admin rights, and usually behind a corporate proxy. Miss any step and
`flutter doctor` hands you an error string instead of an explanation.

If you have seen any of these, this repo is for you:

- `'flutter' is not recognized as an internal or external command`
- `cmdline-tools component is missing`
- `Android sdkmanager tool not found`
- `Unable to locate Android SDK` / `Android SDK not found at this location`
- `Failed to find 'ANDROID_HOME' environment variable`
- `Android license status unknown` / `Some Android licenses not accepted`
- `JAVA_HOME is set to an invalid directory`, or Flutter quietly not using the JDK from `JAVA_HOME`
- `cmdline-tools: could not determine SDK root`
- `Failed to download any source lists!` / `IO exception while downloading manifest`

Every one of those is a thing this script sets up correctly, or repairs on a re-run.
It is meant for a first Flutter machine, a lab or classroom of them, and for handing a new
developer something they can run on day one without a walkthrough.

---

## What it installs (Windows)

| Tool | Version | Install location |
|---|---|---|
| Git for Windows | latest (resolved at runtime) | `%LOCALAPPDATA%\Programs\Git` |
| Flutter SDK | latest **stable** (resolved at runtime) | `C:\dev\flutter` |
| Eclipse Temurin JDK | latest 17 GA (resolved at runtime) | `C:\dev\java\jdk-17.x.y+z` |
| Android cmdline-tools | pinned (see `$Config` in `setup.ps1`) | `C:\dev\Android\sdk\cmdline-tools\latest` |
| Android SDK packages | `platform-tools`, `platforms;android-36`, `build-tools;36.0.0` | `C:\dev\Android\sdk` |

Versions are resolved at runtime from the publishers' own endpoints — Google's Flutter
releases JSON, the Adoptium API, the Git for Windows releases API — so you get current
stable builds rather than whatever was current when this repo was last touched. Pinned
fallback URLs in `$Config` are used only if that resolution fails.

Downloads are fetched from official sources only (Google, Adoptium, GitHub) and
SHA-256 verified where the publisher provides checksums (Flutter, JDK, cmdline-tools).

No Android Studio and no VS Code — this is the pure command-line toolchain.
`flutter doctor` may still *suggest* Android Studio; that suggestion is safe to ignore
for command-line builds.

## Requirements

- Windows 10 or 11, 64-bit
- Windows PowerShell 5.1 — the one already built into Windows; PowerShell 7 is not needed
- ~15 GB free disk space on the install drive
- Internet access
- **No administrator rights needed** — everything installs per-user

## Running it from PowerShell (flags)

**Option A (easiest):** double-click `windows\run-setup.bat`.

**Option B (PowerShell):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\setup.ps1
```

Flags:

| Flag | Effect |
|---|---|
| `-VerifyOnly` | Check what's installed + run `flutter doctor`; change nothing |
| `-SkipAndroid` | Skip JDK + Android SDK (e.g. Android Studio already provides them) |
| `-InstallRoot D:\sdk` | Install somewhere else (path must not contain spaces) |
| `-Precache` | Also run `flutter precache --android` at the end |

`run-setup.bat` passes arguments straight through, so `run-setup.bat -VerifyOnly` works too.

When it finishes: **open a new terminal** (PATH changes don't affect already-open ones)
and run `flutter doctor` to confirm.

## What it changes on your system

This doubles as the uninstall checklist. Everything is **user-scope** — nothing is
written to `HKLM` or `C:\Program Files`.

- Creates `C:\dev\` containing `flutter\`, `java\`, `Android\sdk\`, `.downloads\` (installer cache), `logs\`
  - If `C:\dev` cannot be created (locked-down machines), the script warns and falls
    back to `%USERPROFILE%\dev` — substitute that path throughout this document
- Installs Git to `%LOCALAPPDATA%\Programs\Git` (registered in *Apps & features*)
- Adds to the **user** `PATH`: `C:\dev\flutter\bin`, `C:\dev\java\<jdk>\bin`, `C:\dev\Android\sdk\platform-tools`, `C:\dev\Android\sdk\cmdline-tools\latest\bin`, Git's `cmd` folder
- Sets user environment variables: `ANDROID_HOME`, `JAVA_HOME`
- Accepts Android SDK licenses (hash files in `C:\dev\Android\sdk\licenses\`)
- Writes persistent Flutter tool settings (`android-sdk` and `jdk-dir` absolute paths)
  into the user profile (`%APPDATA%\flutter\settings`) via `flutter config`
- Creates an empty `%USERPROFILE%\.android\repositories.cfg` (silences an sdkmanager warning)
- Writes a log per run to `C:\dev\logs\` (`setup-YYYYMMDD-HHMMSS.log`, a full PowerShell transcript)

Two implementation details worth knowing if you audit scripts before running them:
the environment variables are written straight into `HKCU\Environment` rather than with
`setx` (which truncates values at 1024 characters and rewrites `REG_EXPAND_SZ` as
`REG_SZ`), and the script then broadcasts `WM_SETTINGCHANGE` so Explorer and newly launched
processes pick the changes up. On proxied networks it also sets `JAVA_TOOL_OPTIONS` for its
own child JVMs only — process-scoped, never persisted.

## Re-running safely (idempotent repair and audit)

The script is idempotent: every step first checks whether it is already done and
skips cleanly, so re-running works as a **repair/audit** — the final summary table
shows each component as Installed / Already installed / MISSING.
To force a reinstall of one tool, delete its folder under `C:\dev` and re-run
(for Git, uninstall it via *Apps & features* instead — it lives in
`%LOCALAPPDATA%\Programs\Git`).

Exit codes: `0` success · `1` failure/components missing · `2` everything
installed but `flutter doctor` reports toolchain issues.

## Verifying (dry run, changes nothing)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\setup.ps1 -VerifyOnly
```

## FAQ

**Do I need Android Studio for Flutter?**
No. Android Studio is an IDE; what Flutter actually needs from it is the Android SDK, and
the SDK ships separately as `cmdline-tools` — which is what this script installs. You can
build, run and sign Android apps with only the command line. `flutter doctor` will still
list Android Studio as "not found"; for CLI builds that line is cosmetic.

**Can I install the Android SDK without Android Studio on Windows?**
Yes — that is exactly what the `cmdline-tools` + `sdkmanager` path is for, and it is what
this script automates (`platform-tools`, `platforms;android-36`, `build-tools;36.0.0`).

**Do I need admin rights?**
No. Everything lands under `C:\dev` and `%LOCALAPPDATA%`, and only user-scope environment
variables are written. This also avoids Flutter's documented "SDK is installed in a
protected folder and may not function correctly" failure mode.

**Does it work with the PowerShell that ships with Windows?**
Yes — Windows PowerShell 5.1. You do not need PowerShell 7, Chocolatey, winget or Scoop,
and the script installs no package manager of its own.

**Will it break an existing Flutter or Android Studio installation?**
It checks before it acts, so nothing is installed twice. If Android Studio already gives
you a JDK and SDK, run it with `-SkipAndroid` so it only handles Git and Flutter. Note that
it does write `android-sdk`/`jdk-dir` into `%APPDATA%\flutter\settings`, so an existing
Flutter install will be pointed at this script's SDK paths.

**What about WSL2?**
Not needed and not what this targets. This is a native Windows toolchain; you can build and
run Android apps from Windows directly, with no WSL2 involved.

**Can I use it to set up several machines?**
Yes — it is unattended, logs each run, and `-VerifyOnly` gives you an audit pass, so the
same file works for one laptop or a room of them. `-InstallRoot` moves everything if `C:`
is small or locked down.

## Troubleshooting

**Execution policy blocked** — use `run-setup.bat` or the `-ExecutionPolicy Bypass`
one-liner above; neither changes the machine's policy.

**Corporate proxy** — set the proxy for the session before running:
`$env:HTTPS_PROXY = 'http://proxy.example.com:8080'`

**sdkmanager: "Failed to download any source lists!" / "IO exception while
downloading manifest"** — the Java tooling can't reach Google's package
repository even though the PowerShell downloads worked. Typical on corporate
networks: PowerShell uses the Windows proxy + Windows certificate store, but
the JVM uses neither. The script handles this automatically (it points the JVM
at the Windows certificate store and the system proxy via `JAVA_TOOL_OPTIONS`).
If it still fails, your proxy likely requires credentials — set
`$env:HTTPS_PROXY = 'http://user:pass@proxy.example.com:8080'` and re-run,
or run the script once on an unrestricted network (hotspot).

**Antivirus makes extraction very slow** — extracting the ~1 GB Flutter zip
(thousands of small files) can crawl under real-time scanning. Optionally add a
Defender exclusion for `C:\dev` (requires admin) or just wait it out.

**Download failed / checksum mismatch** — delete the matching file in
`C:\dev\.downloads` and re-run; partial downloads are never reused.

**`flutter doctor` complaints** —
- *Android Studio not found*: expected; safe to ignore for CLI builds.
- *Visual Studio not installed*: only needed for Windows **desktop** apps, not Android.
- *Chrome not found*: only needed for Flutter **web** development.
- *licenses not accepted*: re-run the script (it re-runs license acceptance) or run
  `flutter doctor --android-licenses` manually.

**`flutter`/`adb` not recognized in a new terminal** — terminals launched from an
IDE that was open during setup inherit the old environment; restart the IDE.

## Uninstall

1. Delete `C:\dev` (or `%USERPROFILE%\dev` if setup warned it fell back there)
2. Uninstall "Git" via *Apps & features*
3. In *Settings → Environment Variables → User variables*: remove `ANDROID_HOME`,
   `JAVA_HOME`, and the PATH entries listed above
4. Delete `%APPDATA%\flutter\settings` — it stores the android-sdk/jdk-dir paths
   pointing into `C:\dev` and would misdirect any future Flutter installation
5. Optionally delete caches and script-created config: `%USERPROFILE%\.android`
   (includes the `repositories.cfg` the script created), `%USERPROFILE%\.gradle`,
   `%LOCALAPPDATA%\Pub\Cache`

## Platform status and roadmap

| Platform | Status | Script |
|---|---|---|
| Windows 10/11 | Supported | `windows/setup.ps1` + `windows/run-setup.bat` |
| macOS 12+ (Apple Silicon & Intel) | Supported | `macos/setup.sh` |
| Linux | Planned — stub only | `linux/setup.sh` |

- [x] Windows: Git, Flutter SDK, JDK 17, Android SDK, env vars, license acceptance, `flutter doctor`
- [x] Idempotent re-runs plus a `-VerifyOnly` audit mode
- [x] Corporate proxy / SSL-inspection handling for the JVM
- [x] macOS — `macos/setup.sh` mirroring the Windows flag surface and exit codes
- [ ] Linux — `linux/setup.sh`, same contract
- [ ] CI smoke test on `windows-latest` (PSScriptAnalyzer + `-VerifyOnly`)

`linux/setup.sh` still prints a pointer and exits `1`. Until it lands, use the official
[Linux manual guide](https://docs.flutter.dev/get-started/install/linux) — and see
[CONTRIBUTING.md](CONTRIBUTING.md) if you would like to port it; the macOS script is now a
second reference implementation alongside the Windows one.

## If this isn't what you need

- **Want to do it by hand and understand every step?** Flutter's own
  [manual install](https://docs.flutter.dev/install/manual) and
  [troubleshooting](https://docs.flutter.dev/install/troubleshoot) pages.
- **Want the full Android Studio IDE?** Install it, then run this with `-SkipAndroid` to get
  just Git and Flutter.
- **Need several Flutter SDK versions side by side?** Use
  [FVM](https://github.com/leoafarias/fvm).
- **Setting up a CI runner rather than a laptop?** Use
  [flutter-action](https://github.com/subosito/flutter-action).

## Contributing

Contributions are open and genuinely wanted — start with
**[CONTRIBUTING.md](CONTRIBUTING.md)**.

The **top wanted contribution is `linux/setup.sh`.** It is still a stub, and there are now
two reference implementations to copy from — `windows/setup.ps1` and `macos/setup.sh`. A
port should keep the same flag surface (`--verify-only` / `--skip-android` /
`--install-root` / `--precache`), the same exit codes (`0` / `1` / `2`), be idempotent,
install to user scope with no `sudo`, verify SHA-256 where the publisher provides
checksums, log each run, and end with the same Installed / Already installed / MISSING
summary. Partial work is welcome — a `setup.sh` that only does the JDK step, with the rest
as clean no-ops, is a useful pull request.

Other ways to help, no shell scripting required:

1. **Run it and tell me what happened.** [Open an issue](../../issues/new) with your OS
   version and architecture, the flags you used, and the log from `<install root>/logs/`
   (on Windows: `winver`, `$PSVersionTable.PSVersion` and `C:\dev\logs\`).
2. **Test it behind a corporate proxy or SSL inspection.** That is the hardest path to
   verify alone and the one most likely to still be wrong.
3. **Hit a `flutter doctor` case Troubleshooting doesn't cover?** Open an issue with the
   exact error text so it can be added.

If this repository helped you, please give it a star — that's how other people fighting the
same `flutter doctor` errors find it.

## About

Installing Flutter without Android Studio still means reading three docs pages, unzipping
two SDKs, editing `PATH`, `ANDROID_HOME` and `JAVA_HOME` by hand, and then guessing why
`flutter doctor` says `cmdline-tools component is missing`. This repo turns that into one
readable, auditable script per platform that you can re-run whenever a machine drifts — for
your own laptop, for a classroom of them, or for a developer's first day.

## License

[MIT](LICENSE). These scripts download and run third-party installers and change your
environment variables; read `windows/setup.ps1` or `macos/setup.sh` before you run it, and
note that the software comes with no warranty.

Flutter and the related logo are trademarks of Google LLC. Android is a trademark of
Google LLC. This project is not endorsed by or affiliated with Google LLC.

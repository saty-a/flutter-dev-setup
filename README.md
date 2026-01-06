# Flutter Development Environment Setup

Scripted, unattended setup of a complete Flutter (Android) development toolchain.
**Windows is fully supported; macOS and Linux are TODO stubs.**

## What it installs (Windows)

| Tool | Version | Install location |
|---|---|---|
| Git for Windows | latest (resolved at runtime) | `%LOCALAPPDATA%\Programs\Git` |
| Flutter SDK | latest **stable** (resolved at runtime) | `C:\dev\flutter` |
| Eclipse Temurin JDK | latest 17 GA (resolved at runtime) | `C:\dev\java\jdk-17.x.y+z` |
| Android cmdline-tools | pinned (see `$Config` in `setup.ps1`) | `C:\dev\Android\sdk\cmdline-tools\latest` |
| Android SDK packages | `platform-tools`, `platforms;android-36`, `build-tools;36.0.0` | `C:\dev\Android\sdk` |

Downloads are fetched from official sources only (Google, Adoptium, GitHub) and
SHA-256 verified where the publisher provides checksums (Flutter, JDK, cmdline-tools).

No Android Studio and no VS Code — this is the pure command-line toolchain.
`flutter doctor` may still *suggest* Android Studio; that suggestion is safe to ignore
for command-line builds.

## Requirements

- Windows 10 or 11, 64-bit
- ~15 GB free disk space on the install drive
- Internet access
- **No administrator rights needed** — everything installs per-user

## How to run (Windows)

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
- Writes a log per run to `C:\dev\logs\`

## Re-running safely

The script is idempotent: every step first checks whether it is already done and
skips cleanly, so re-running works as a **repair/audit** — the final summary table
shows each component as Installed / Already installed / MISSING.
To force a reinstall of one tool, delete its folder under `C:\dev` and re-run
(for Git, uninstall it via *Apps & features* instead — it lives in
`%LOCALAPPDATA%\Programs\Git`).

Exit codes: `0` success · `1` failure/components missing · `2` everything
installed but `flutter doctor` reports toolchain issues.

## Verifying

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\setup.ps1 -VerifyOnly
```

## macOS / Linux

Not implemented yet (`macos/setup.sh`, `linux/setup.sh` are stubs). Manual guides:
[macOS](https://docs.flutter.dev/get-started/install/macos) ·
[Linux](https://docs.flutter.dev/get-started/install/linux)

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

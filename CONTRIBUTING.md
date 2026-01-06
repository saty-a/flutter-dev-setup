# Contributing

This repo is one script per platform that takes a machine from nothing to a working
Flutter + Android command-line toolchain, unattended, with no admin rights.

- `windows/setup.ps1` — complete, and the **reference implementation** for everything below.
- `macos/setup.sh`, `linux/setup.sh` — stubs that print a message and exit 1.

Contributions are welcome, including small ones. Please read the
[Non-goals](#non-goals) before writing anything larger than about 50 lines.

---

## What this project needs, in order

### 1. Implement `macos/setup.sh` or `linux/setup.sh`

This is the biggest gap and the most useful thing you can do. It is a port, not a
design job: `windows/setup.ps1` already decided what "done" means, and the
[porting contract](#the-porting-contract) below spells it out step by step.

**Partial work is welcome.** A `macos/setup.sh` that only resolves and installs the
JDK, with the other steps as clean no-ops that report `MISSING` in the summary, is a
PR I will merge. I would rather review four small PRs than wait for one big one.
Comment on the platform's tracking issue before you start so two people don't port
the same step.

### 2. Run `windows/setup.ps1` on a real machine and tell me what happened

Success reports are as useful as failures — I cannot test every Windows edition,
locale, corporate proxy and antivirus combination myself. Use the
**compatibility report** issue template; it asks for the Windows edition and build
(`winver`), `$PSVersionTable.PSVersion`, whether the machine was clean, the exit code,
and the final summary table.

The hairiest, least testable code path is **corporate networks**: proxies plus TLS
inspection, where PowerShell downloads succeed (Windows proxy + Windows cert store)
but the JVM used by `sdkmanager` fails at both. `Get-SystemProxy` and
`Set-JvmNetworkDefaults` exist for exactly that, and I can only guess at how many
real setups they cover. If you work somewhere with Zscaler/Netskope-style inspection,
a single report is worth more than a feature.

### 3. Report bugs with the transcript log

Every non-`-VerifyOnly` run writes a `Start-Transcript` log to
`<InstallRoot>\logs\setup-<timestamp>.log` — normally `C:\dev\logs\`, or
`%USERPROFILE%\dev\logs\` if the script warned that it fell back there.
Attach that file, or paste the last ~60 lines around the failure.

> The transcript includes your username, machine name and full paths, and echoes
> resolved download URLs. Skim it before pasting and redact anything internal
> (proxy hostnames and credentials in particular).

Also include the exit code: `0` success, `1` failure or components missing,
`2` installed but `flutter doctor` reports toolchain issues.

### 4. Docs

Highest-value docs work: a `flutter doctor` failure, or an sdkmanager/JDK error, that
the README's Troubleshooting section doesn't cover — with the **exact error text**,
so the next person searching that string finds it. Second-highest: correcting anything
in the README that is wrong on your machine.

---

## The porting contract

`macos/setup.sh` and `linux/setup.sh` should behave like `windows/setup.ps1`, not merely
install the same things. Parity means all of the following.

**Same flag surface,** translated to the platform convention:

| `setup.ps1` | `setup.sh` | Meaning |
|---|---|---|
| `-VerifyOnly` | `--verify-only` | Check and report only; change nothing on disk or in the environment |
| `-SkipAndroid` | `--skip-android` | Skip the JDK and Android SDK steps |
| `-InstallRoot <path>` | `--install-root <path>` | Default `$HOME/dev`; must not contain spaces (a Flutter SDK limitation, not ours) |
| `-Precache` | `--precache` | Run `flutter precache --android` at the end |

**Same exit codes:** `0` success · `1` failure or components missing · `2` everything
installed but `flutter doctor` reports toolchain issues. Derive them from the summary
the same way the Windows script does (any `MISSING` → 1, else any `ISSUES FOUND` → 2).

**Same idempotency.** Every step checks whether it is already done and skips cleanly,
so a re-run is a repair/audit rather than a duplicate install. This is the property
that most matters and the one most installers get wrong. Concretely:

- Never append a duplicate PATH entry or profile block.
- A half-extracted or checksum-failing download is deleted and re-fetched, never reused
  (`Invoke-Download` writes to `<name>.partial` and only renames after the hash matches).
- A broken leftover directory is removed before a fresh extract, not extracted into.
- Under `--verify-only`, every step is read-only and still records a summary row.

**Same summary and log.** A final table with one row per component and the statuses
`Installed` / `Already installed` / `MISSING` (plus `Accepted` / `Already accepted` for
licenses), and a per-run log at `<root>/logs/setup-<timestamp>.log`.

**Environment variables, the Unix way.** Windows writes `HKCU\Environment` and broadcasts
`WM_SETTINGCHANGE`. The shell equivalent is a **single marker-delimited block** in one
user profile file, rewritten in place on every run:

```sh
# >>> flutter-setup >>>
export ANDROID_HOME="$HOME/dev/Android/sdk"
export JAVA_HOME="$HOME/dev/java/jdk-17.0.x+y"
export PATH="$HOME/dev/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
# <<< flutter-setup <<<
```

Rules for that block: pick the target file from `$SHELL` (zsh → `~/.zprofile`,
bash → `~/.bash_profile` if it exists, else `~/.profile`); **print the file you chose**
in the run output; on re-run replace the existing block instead of appending a second
one; and also `export` the same values into the current process so later steps in the
same run (sdkmanager, flutter) see them immediately — that is what `Set-Item Env:` at the
end of `Set-UserEnvVar` is for. Finish with the equivalent of the Windows
"open a NEW terminal" notice.

**Same download discipline.** Resolve the latest stable at runtime and SHA-256 verify
everything the publisher publishes a hash for:

- Flutter — `releases_macos.json` / `releases_linux.json` (each release entry carries
  `sha256`); pick `arm64` vs `x64` from `uname -m` on macOS. Linux ships `.tar.xz`.
- JDK 17 — the Adoptium v3 assets API with `os=mac|linux` and
  `architecture=x64|aarch64`; it returns a checksum per binary.
- Android cmdline-tools — `commandlinetools-mac-*` / `commandlinetools-linux-*`, pinned
  by build number with its published SHA-256, extracted so the final layout is
  `<sdk>/cmdline-tools/latest/bin/...` (sdkmanager derives the SDK root from its own
  location and requires that exact shape).
- Official publishers only: Google, Adoptium, GitHub releases. No third-party mirrors.

**Prerequisites you cannot install without elevation.** Git on Linux and the Xcode
Command Line Tools on macOS cannot be installed unattended without sudo or a GUI prompt
(`xcode-select --install` opens a dialog). Do not fight this and do not hang waiting on
it: detect the tool, and if it is missing print the one exact command the user should
run and exit non-zero with a clear message. Same for `curl`, `unzip`, `tar`/`xz`.

**License acceptance** goes through `sdkmanager --licenses` with `yes |` — the Windows
script only uses a `yes.txt` file plus `cmd /c` redirection because PS 5.1's native
piping into `.bat` files is unreliable. Success is checked by the presence of
`$ANDROID_HOME/licenses/android-sdk-license`, not by exit code alone.

**Acceptance criteria for a port PR:** tested on a machine (or VM) that did **not**
already have Flutter installed; paste the summary table and the full `flutter doctor -v`
output; and state the OS version, architecture and shell.

---

## Non-goals

Stating these up front so nobody burns a weekend on a PR I would decline. If you want
one of them, open an issue and make the case first.

- **No Android Studio, no VS Code, no IDE plugins.** This is the pure command-line
  toolchain. `flutter doctor` suggesting Android Studio is expected and fine.
- **No admin / sudo / UAC prompt.** Nothing writes `HKLM`, `C:\Program Files`,
  `/usr/local`, `/opt` or anything else outside the user's own directories.
- **No package manager as a requirement.** Not Chocolatey, winget, Scoop, Homebrew or
  apt. Stock Windows PowerShell 5.1 and a stock shell must be enough.
- **No PowerShell 7 requirement** for `windows/setup.ps1`.
- **No version management.** One latest-stable Flutter install. If you need multiple SDK
  versions, use [FVM](https://fvm.app) — that is a different tool.
- **No iOS/Xcode toolchain, no Windows desktop (Visual Studio) and no web (Chrome)
  toolchains.** Android only.
- **No emulator/AVD creation** for now. Real devices over USB work with the installed
  `platform-tools`.
- **No paths with spaces**, and no attempt to work around Flutter's own limitation there.
- **No telemetry, no analytics, no network calls** beyond resolving and downloading from
  the publishers listed above.
- **No splitting `setup.ps1` into modules.** One auditable file per platform is a feature:
  people read this script before running it, and a single file is what makes that possible.

---

## Testing a change to `setup.ps1` safely

This script installs software, edits your user PATH and accepts SDK licenses. Do not
develop against your only working environment.

**Best: a VM with a snapshot.** Take the snapshot *before* the first run so you can test
the fresh-install path repeatedly. Windows Sandbox works too (it discards state on close)
but enabling it needs Pro/Enterprise and admin.

**Good enough on your daily machine: a scratch local Windows user account.** Because
every write is user-scope — `HKCU\Environment`, `%LOCALAPPDATA%`, `%USERPROFILE%` — a
second account is a genuinely clean slate. The one exception is Git: if it is already
installed machine-wide under `C:\Program Files\Git`, `Install-Git` will detect and skip
it, so that path is not exercised.

**Always:**

```powershell
# 1. a scratch, space-free root on a drive with ~15 GB free
powershell -NoProfile -ExecutionPolicy Bypass -File windows\setup.ps1 -InstallRoot D:\scratch

# 2. read-only report before and after — this must never change anything
powershell -NoProfile -ExecutionPolicy Bypass -File windows\setup.ps1 -InstallRoot D:\scratch -VerifyOnly

# 3. exit code
$LASTEXITCODE
```

Then **run it a second time unchanged** and confirm every row reads
`Already installed` / `Already accepted` and the exit code is still `0`. A change that
breaks the second run is broken, even if the first run looked perfect.

### Resetting state to re-test the fresh-install path

1. Delete the install root (`D:\scratch`, or `C:\dev`, or `%USERPROFILE%\dev` if the
   script warned it fell back there). **Tip:** move `<root>\.downloads` aside first and
   restore it afterwards — `Invoke-Download` skips cached files whose SHA-256 matches, so
   this saves re-downloading well over a gigabyte on every iteration.
2. Remove the user environment variables and PATH entries. Either use
   *Settings → Environment Variables → User variables*, or, mirroring what the script
   itself writes:

   ```powershell
   $root   = 'C:\dev'                    # whatever -InstallRoot you used
   $prefix = $root.TrimEnd('\') + '\'
   $key    = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
   $raw    = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
   $raw -split ';'                       # LOOK at this before continuing
   $kept = @($raw -split ';' | Where-Object {
       $_ -and ([Environment]::ExpandEnvironmentVariables($_) + '\') -notlike "$prefix*"
   }) -join ';'
   # user PATH must stay REG_EXPAND_SZ or any %VAR% entries in it stop resolving
   $key.SetValue('Path', $kept, [Microsoft.Win32.RegistryValueKind]::ExpandString)
   'ANDROID_HOME', 'JAVA_HOME' | ForEach-Object { $key.DeleteValue($_, $false) }
   $key.Close()
   ```

   Git's entry (`%LOCALAPPDATA%\Programs\Git\cmd`) is separate — remove it only if you
   are also uninstalling Git via *Apps & features* to test that path.
3. Delete `%APPDATA%\flutter\settings`. It stores the absolute `android-sdk` and
   `jdk-dir` paths written by `flutter config`, and a stale copy will misdirect the next
   install so that `flutter doctor` passes for the wrong reason.
4. Optionally clear `%USERPROFILE%\.android` (including the `repositories.cfg` the script
   creates), `%USERPROFILE%\.gradle`, `%LOCALAPPDATA%\Pub\Cache`.
5. Open a **new** terminal — already-open shells keep the old environment — and confirm
   `flutter`, `adb` and `java` are gone before re-running.

### Worth testing beyond the happy path

`-SkipAndroid` · an install root on a second drive · a path containing a space (must fail
fast with a clear message) · no network / a blocked proxy · an elevated shell (must warn,
not change behaviour) · a machine that already has Android Studio's SDK.

---

## PowerShell rules for `windows/setup.ps1`

These are not style preferences. Each one is a bug that has already been paid for.

- **Target stock Windows PowerShell 5.1.** Test with `powershell.exe`, never only
  `pwsh.exe`. No PS 7-only syntax: no ternary `? :`, no `??` / `??=`, no `&&` / `||`
  pipeline chains, no `-Parallel`, no `ConvertFrom-Json -AsHashtable`, no
  `-SkipCertificateCheck`, no `Join-Path` with more than one child path, no
  `Get-Error`. If you are unsure, run it under 5.1 — that is the only real check.
- **`Set-StrictMode -Version 2.0` is on.** Reading an uninitialized variable or a
  property that does not exist is a terminating error, and calling a function with
  method syntax (`Foo($a, $b)`) is too. Initialize `$script:` state before use, and test
  for optional properties with `$obj.PSObject.Properties.Name -contains 'x'` rather than
  a truthiness check.
- **Native stderr is a trap under `$ErrorActionPreference = 'Stop'`.** With `2>&1`, every
  stderr line from a native command becomes a terminating `NativeCommandError` — and
  `git`, `flutter`, `dart` and the JVM all write ordinary progress and warnings to stderr.
  Follow the existing patterns: save and restore `$ErrorActionPreference` around
  `flutter` invocations the way `Invoke-FlutterDoctor` does, and prefer variants that
  write to stdout (`java --version`, not `java -version`). Check `$LASTEXITCODE` after
  every native call.
- **Keep the UTF-8 BOM on `setup.ps1`.** PowerShell 5.1 decodes a BOM-less file as ANSI,
  so the UTF-8 em dashes in the script's `throw` messages and comments come out as mojibake
  in the errors users actually read. Check the first three bytes with
  `[IO.File]::ReadAllBytes('windows\setup.ps1')[0..2]` → `239 187 191`, i.e. `EF BB BF`,
  and set your editor to save `.ps1` as "UTF-8 with BOM". Inside regexes keep using
  `\uXXXX` escapes instead of literal non-ASCII (as `Invoke-FlutterDoctor` does for
  `\u2717`) so matching never depends on the encoding at all.
- **Never use `setx`** for PATH or any variable. It truncates values at 1024 characters
  and rewrites `REG_EXPAND_SZ` as `REG_SZ`, silently breaking any `%VAR%` already in the
  user's PATH. Go through `Set-UserEnvVar` and `Add-UserPathEntry`, which write
  `HKCU\Environment` directly — plain values as `String`, `Path` as `ExpandString` — and
  read existing values with `DoNotExpandEnvironmentNames` so other people's `%VAR%`
  entries survive. Broadcast `WM_SETTINGCHANGE` once at the end, not per variable.
- **Never add `cmdline-tools;latest` to the sdkmanager package list.** As soon as the
  pinned zip lags the current release, that request becomes a self-update, and on Windows
  sdkmanager cannot replace its own running jars — it deadlocks or fails the whole run.
  The pinned zip in `$Config` is the only source of cmdline-tools.
- **Every step stays idempotent and honours `-VerifyOnly`.** Check first, skip cleanly,
  call `Add-Summary` exactly once per component with `Installed` / `Already installed` /
  `MISSING` so the exit code stays meaningful. Under `-VerifyOnly` a step must not write
  anything — `Set-UserEnvVar` and `Add-UserPathEntry` already guard on it; anything new
  you add must too.
- **All downloads go through `Invoke-Download`** with a SHA-256 wherever the publisher
  publishes one, and all extraction through `Expand-ArchiveFast` (which prefers
  `tar.exe` and keeps the zip-slip guard on the fallback path). Do not call
  `Invoke-WebRequest` or `Expand-Archive` directly.
- **New pinned URLs come with a verified hash and a dated comment**, matching the
  `$Config` block. Runtime resolution stays the primary source; pins are fallbacks only.
- **No new external dependencies**, no new files, no modules. One script.
- Run `Invoke-ScriptAnalyzer -Path windows\setup.ps1` before pushing. It is not clean
  today (`Write-Warn2` uses an unapproved verb; `Write-Host` is used deliberately for
  console UX). Don't add new warnings, and don't "fix" the existing ones in a PR that
  does anything else.

### Shell rules for `macos/` and `linux/`

- `#!/usr/bin/env bash`, `set -euo pipefail`, and **bash 3.2 compatible** — that is what
  macOS still ships, so no associative arrays, no `${var,,}`, no `mapfile`/`readarray`.
- `shellcheck` clean, keep the executable bit (`git update-index --chmod=+x`), LF endings.
- Quote every expansion; the install root is user-supplied.
- Same structure as the Windows script — small per-step functions, a summary array, a
  preflight — so the two stay diffable against each other.

---

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), matching the existing
history (`feat:`, `fix:`, `chore:`). Add a scope when it helps:

```
feat(macos): install Temurin JDK 17 via the Adoptium API
fix(windows): keep %VAR% entries intact when appending to user PATH
docs: add the exact sdkmanager manifest error to Troubleshooting
chore: mark shell stubs executable
```

Imperative mood, lowercase subject, no trailing period, aim for ≤72 characters. Use the
body to say **why** whenever the change isn't self-evident — most of the odd-looking code
in `setup.ps1` exists because of a PowerShell 5.1 quirk, and the next reader needs to know
which one.

---

## Pull requests

- One logical change per PR. Small is good; incomplete-but-clean is good.
- Say what you tested on: OS and build, shell, `$PSVersionTable.PSVersion` for
  PowerShell changes.
- Paste the final summary table, the exit code, and `flutter doctor -v` if your change can
  affect the toolchain.
- For any `setup.ps1` change, confirm three runs: `-VerifyOnly` (unchanged system), a full
  run, and a second full run showing `Already installed` throughout.
- Keep diffs reviewable: no reformatting of untouched code, no reflowing whole files, no
  bumping pinned URLs/SHAs in the same PR as a behaviour change.
- Don't commit logs, `.downloads` contents, or anything from your machine.
- I aim to reply within a week. If a PR goes quiet, comment on it — that is not nagging.
- I will decline things that conflict with [Non-goals](#non-goals). Checking that list, or
  opening an issue first, is the cheapest way to avoid wasted work.

## Claiming an issue

Comment on it and I'll assign you. If an assigned issue goes quiet for two weeks I'll
unassign it so someone else can pick it up — no hard feelings, and you're welcome to
reclaim it. For the platform ports, comment on the tracking issue saying which **step**
you're taking, so two people don't write the same function twice.

Start here: [good first issues](../../contribute) · [help wanted](../../labels/help%20wanted)

## Questions

Open an issue. There's no chat server, no mailing list, and nothing else to join.
There are no dumb questions about a setup script — if something in the README was
ambiguous enough to make you ask, that is a docs bug and I want to hear it.

Be straightforward and assume good faith; that is the whole behavioural expectation.

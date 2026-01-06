# Security

These scripts download and execute third-party installers, modify your user `PATH` and
environment variables, and accept Android SDK licences on your behalf. That is a meaningful
amount of trust, so here is what they do and do not do, and how to report a problem.

## Reporting a vulnerability

Please report privately rather than opening a public issue:
use **[Report a vulnerability](../../security/advisories/new)** on the Security tab, or
email <satyaprakash6945@gmail.com>.

Include the script version (commit SHA), what an attacker would need to be able to do, and
the impact. I'll acknowledge within a week. This is a solo, unpaid project — there is no
bounty, and no guaranteed patch timeline — but anything that lets an attacker get code onto
a user's machine will be treated as the top priority.

## What the scripts do, security-wise

- **Downloads come only from the official publishers**: Google
  (`storage.googleapis.com`, `dl.google.com`), Eclipse Adoptium (`api.adoptium.net`,
  `github.com/adoptium`) and Git for Windows (`github.com/git-for-windows`). No mirrors,
  no shortened URLs, no third-party CDNs.
- **Everything with a published checksum is SHA-256 verified** before use — the Flutter
  SDK, the JDK and the Android cmdline-tools zip. Downloads land as `<name>.partial` and
  are only renamed after the hash matches, so a partial or tampered file is never reused.
  Pinned fallback URLs in `$Config` carry their expected hash inline.
- **Git for Windows has no publisher-provided checksum** for its `.exe`, so it is fetched
  over HTTPS from the official GitHub release and run with its Inno Setup silent switches.
  This is the one download not hash-verified; if you need it verified, install Git yourself
  first and the script will detect and skip it.
- **TLS 1.2 is forced** for PowerShell's own requests, because 5.1's default handshake is
  often too old for these endpoints.
- **No elevation.** Nothing writes `HKLM`, `C:\Program Files` or any machine-scope
  location. Everything lands under the install root (default `C:\dev`), `HKCU\Environment`
  and `%LOCALAPPDATA%\Programs\Git`. Running the script elevated only produces a warning.
- **Zip extraction is path-traversal guarded** on the .NET fallback path (entries that
  resolve outside the destination are rejected).
- **Licence acceptance is automatic** — `sdkmanager --licenses` is answered `y`. You are
  accepting Google's Android SDK licence terms without reading them on screen. That is the
  point of an unattended installer, and it is worth knowing.
- **No telemetry.** The scripts phone nothing home. The only network traffic is version
  resolution and the downloads listed above (plus whatever `flutter doctor`,
  `flutter precache` and `sdkmanager` do on their own).
- **Logs are local only.** Transcripts under `<InstallRoot>\logs\` contain your username,
  machine name, full paths and resolved URLs. Nothing uploads them — but skim before
  attaching one to an issue.

## Supported versions

The tip of `main` only. There are no maintained release branches; if something is wrong,
the fix is to pull the current script and re-run it (it is idempotent and doubles as a
repair).

## Out of scope

Vulnerabilities in the software these scripts install — Flutter, the Android SDK, the JDK,
Git — belong to those projects. Report them upstream. Issues in *how* this repo fetches,
verifies or configures them are in scope here.

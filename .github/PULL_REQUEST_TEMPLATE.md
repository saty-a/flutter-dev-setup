<!--
Thanks for the PR. Delete whatever doesn't apply — an honest short PR beats a padded one.
Full context: CONTRIBUTING.md
-->

## What this changes

<!-- One or two sentences. Link the issue it closes, if any. -->

## How it was tested

- OS / build:
- Shell / `$PSVersionTable.PSVersion` (for PowerShell changes):
- Exit code:

<!-- Paste the final summary table, and flutter doctor -v if the toolchain could be affected. -->

## Checklist

- [ ] I ran it on a machine or VM that did **not** already have the components installed.
- [ ] I ran it **twice** — the second run reports `Already installed` throughout and still exits 0.
- [ ] `-VerifyOnly` / `--verify-only` still changes nothing on disk or in the environment.
- [ ] Every new step calls `Add-Summary` (or the shell equivalent) so exit codes stay meaningful.
- [ ] No admin/sudo required; nothing written outside the install root and user-scope env vars.
- [ ] PowerShell only: runs under Windows PowerShell **5.1**, no PS 7-only syntax, UTF-8 **BOM** preserved on `setup.ps1`, no `setx`.
- [ ] Shell only: `shellcheck` clean, bash 3.2 compatible, executable bit set.
- [ ] Any new download is SHA-256 verified via `Invoke-Download` (or its shell equivalent) and comes from an official publisher.
- [ ] Diff is limited to this change — no unrelated reformatting, no pinned-version bumps mixed in.
- [ ] Nothing from my machine got committed (logs, `.downloads`, local paths).

## Anything I should look at closely?

<!-- Trade-offs you made, things you weren't sure about, or a step you deliberately left as a no-op. -->

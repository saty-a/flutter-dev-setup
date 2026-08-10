#!/usr/bin/env bash
#
# =============================================================================
#  Complete Flutter (Android) development environment setup for Linux.
# =============================================================================
#
# SYNOPSIS
#   Unattended installer that takes a fresh Linux machine (x86_64) to a
#   fully working Flutter Android toolchain:
#
#     1. Prerequisites            (git / curl / unzip / xz / tar / sha256sum —
#                                  detected, never installed: that needs root)
#     2. Flutter SDK              (latest stable, resolved at runtime, SHA-256 verified)
#     3. Eclipse Temurin JDK 17   (resolved at runtime via the Adoptium API, SHA-256 verified)
#     4. Android command-line tools + platform-tools + platform + build-tools
#     5. Environment variables    (one marker-delimited block in your shell profile)
#     6. Android SDK license acceptance (fully automatic)
#     7. flutter doctor verification
#
#   Everything installs under the install root and the user's own home — no
#   sudo, no package manager, no Android Studio. The script is
#   idempotent: every step checks whether it is already done and skips cleanly,
#   so re-running it is a repair/audit rather than a duplicate install.
#
# USAGE
#   ./setup.sh [--verify-only] [--skip-android] [--install-root <path>] [--precache]
#   ./setup.sh --help
#
# EXIT CODES
#   0  success
#   1  failure, or a component is MISSING
#   2  everything installed but `flutter doctor` reports toolchain issues
#
# SIDE EFFECT OUTSIDE THE INSTALL ROOT
#   `flutter config` persists the android-sdk and jdk-dir paths in
#   ~/Library/Application Support/flutter (or ~/.config/flutter), and an empty
#   ~/.android/repositories.cfg is created to silence an sdkmanager warning.
#
# PORT NOTES (see CONTRIBUTING.md "The porting contract")
#   This mirrors windows/setup.ps1 step for step so the two stay diffable.
#   Deliberate Linux differences are marked "Linux:" in the comments.
#   Kept bash 3.2 compatible on purpose: Linux ships bash 5, but macos/setup.sh
#   must run on the bash 3.2 that Apple still ships, and keeping one dialect
#   means the two scripts stay diffable — no associative arrays, no mapfile,
#   no ${var,,}, no namerefs.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# ---- Config: runtime resolvers + pinned fallbacks (verified 2026-08-05) ----
# ---------------------------------------------------------------------------
# Runtime resolution is always the primary source; the pins below are used only
# when resolution fails. Every pin was HEAD-checked (HTTP 200) on the date above.

# Runtime resolvers (primary sources — always give the latest stable)
CFG_FLUTTER_RELEASES_JSON='https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json'
CFG_TEMURIN_ASSETS_API='https://api.adoptium.net/v3/assets/latest/17/hotspot'
CFG_ANDROID_REPO_XML='https://dl.google.com/android/repository/repository2-3.xml'
CFG_ANDROID_REPO_BASE='https://dl.google.com/android/repository'

# Pinned Flutter fallback — stable 3.44.9.
# Linux ships a .tar.xz (macOS/Windows ship .zip), and Google publishes the
# prebuilt Linux SDK for x86_64 ONLY — there is no arm64 archive in
# releases_linux.json at all, which is why detect_arch refuses aarch64 with
# instructions instead of guessing.
CFG_FLUTTER_FALLBACK_VERSION='3.44.9'
CFG_FLUTTER_FALLBACK_URL_X64='https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.44.9-stable.tar.xz'
CFG_FLUTTER_FALLBACK_SHA_X64='a9120fa4a01048bdef438ddc3a2d4b7389662ea98a95db86eeaf10382bc4efcb'

# Pinned Temurin fallback — jdk-17.0.20+8, .tar.gz.
# Linux uses the plain layout: java lives at <dir>/bin/java (no Contents/Home).
CFG_JDK_FALLBACK_URL_X64='https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20%2B8/OpenJDK17U-jdk_x64_linux_hotspot_17.0.20_8.tar.gz'
CFG_JDK_FALLBACK_SHA_X64='be7668bc030d578b83d6d5ef9221d6d6729bbbca8cf94a7d52e16ac68b5a5a35'

# Pinned Android cmdline-tools fallback — revision 22.0, build 15859902.
# Linux has a single architecture-neutral archive (the mac builds are split by
# arch; Linux is not). Google publishes only a SHA-1 for these archives
# (repository2-3.xml carries <checksum type="sha1">), so this is the one
# download verified with SHA-1 instead of SHA-256. Flutter and the JDK do
# publish SHA-256 and use it.
CFG_CMDLINE_FALLBACK_URL_X64="$CFG_ANDROID_REPO_BASE/commandlinetools-linux-15859902_latest.zip"
CFG_CMDLINE_FALLBACK_SHA1_X64='040d3996a65543d22ec4bf73e4c37aa37a8d4af4'

# Matches Flutter stable 3.44.x defaults (compileSdk 36) and AGP 9.3 (build-tools 36.0.0)
CFG_ANDROID_PLATFORM='platforms;android-36'
CFG_ANDROID_BUILD_TOOLS='build-tools;36.0.0'

CFG_REQUIRED_DISK_GB=15
CFG_DOWNLOAD_RETRIES=3
CFG_MIN_KERNEL_MAJOR=4        # Flutter needs a reasonably modern glibc/kernel
CFG_USER_AGENT='flutter-setup-script'

# ---------------------------------------------------------------------------
# ---- Script state ----------------------------------------------------------
# ---------------------------------------------------------------------------
VERIFY_ONLY=0
SKIP_ANDROID=0
PRECACHE=0
INSTALL_ROOT="$HOME/dev"

FLUTTER_HOME=''
JAVA_ROOT=''
ANDROID_HOME_DIR=''
DOWNLOAD_DIR=''
LOG_DIR=''
STAGE_DIR=''
LOG_FILE=''
LOG_FIFO=''
LOG_PID=''
LOG_ACTIVE=0

PROFILE_FILE=''
MARK_BEGIN='# >>> flutter-setup >>>'
MARK_END='# <<< flutter-setup <<<'

ARCH_FLUTTER=''      # x64                (releases_linux.json dart_sdk_arch)
ARCH_ADOPTIUM=''     # x64                (Adoptium API architecture)
ARCH_CMDLINE=''      # linux              (filename token in repository2-3.xml)
HASH_TOOL=''         # sha256sum | shasum (chosen in check_required_tools)

GIT_BIN=''
JAVA_HOME_RESOLVED=''
FLUTTER_BIN=''

# Values produced by the resolve_* functions (bash 3.2 has no namerefs, so
# multi-value returns go through these globals).
RESOLVED_URL=''
RESOLVED_SHA=''
RESOLVED_ALGO=''
RESOLVED_VERSION=''

# PATH entries to publish, in the order they should appear
PATH_ENTRIES=()

IS_TTY=0
ERROR_REPORTED=0
FINISHED=0
EXIT_CODE=0

# ---------------------------------------------------------------------------
# ---- Output helpers (mirrors Write-Step/Ok/Skip/Warn2/Fail) -----------------
# ---------------------------------------------------------------------------
C_RESET=''; C_STEP=''; C_OK=''; C_SKIP=''; C_WARN=''; C_FAIL=''; C_HEAD=''

init_colors() {
    if [ -t 1 ]; then
        IS_TTY=1
    fi
    # Degrade gracefully: no TTY, TERM=dumb/unset, or NO_COLOR set => plain text
    if [ "$IS_TTY" -eq 1 ] && [ -z "${NO_COLOR:-}" ] &&
       [ -n "${TERM:-}" ] && [ "${TERM:-}" != 'dumb' ]; then
        C_RESET=$'\033[0m'
        C_STEP=$'\033[36m'   # cyan
        C_OK=$'\033[32m'     # green
        C_SKIP=$'\033[90m'   # dark gray
        C_WARN=$'\033[33m'   # yellow
        C_FAIL=$'\033[31m'   # red
        C_HEAD=$'\033[35m'   # magenta
    fi
}

write_step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_RESET"; }
write_ok()   { printf '    %s[OK]%s      %s\n' "$C_OK" "$C_RESET" "$1"; }
write_skip() { printf '    %s[SKIP]%s    %s\n' "$C_SKIP" "$C_RESET" "$1"; }
write_warn() { printf '    %s[WARN]%s    %s\n' "$C_WARN" "$C_RESET" "$1"; }
write_fail() { printf '    %s[FAIL]%s    %s\n' "$C_FAIL" "$C_RESET" "$1"; }
write_info() { printf '    %s\n' "$1"; }

indent_lines() {
    # Indent a captured block of child output the way the Windows script does.
    sed 's/^/    /'
}

# ---------------------------------------------------------------------------
# ---- Summary (mirrors Add-Summary / Show-Summary) ---------------------------
# ---------------------------------------------------------------------------
# Three parallel indexed arrays: bash 3.2 has no associative arrays.
SUMMARY_COMPONENT=()
SUMMARY_STATUS=()
SUMMARY_DETAIL=()

add_summary() {
    SUMMARY_COMPONENT+=("$1")
    SUMMARY_STATUS+=("$2")
    SUMMARY_DETAIL+=("${3:-}")
}

show_summary() {
    local count i w_comp w_stat
    count=${#SUMMARY_COMPONENT[@]}
    printf '\n%s=============================================%s\n' "$C_HEAD" "$C_RESET"
    printf '%s  Summary                                    %s\n' "$C_HEAD" "$C_RESET"
    printf '%s=============================================%s\n' "$C_HEAD" "$C_RESET"
    if [ "$count" -eq 0 ]; then
        printf '  (nothing recorded)\n'
        return 0
    fi
    w_comp=9   # len('Component')
    w_stat=6   # len('Status')
    i=0
    while [ "$i" -lt "$count" ]; do
        [ ${#SUMMARY_COMPONENT[$i]} -gt "$w_comp" ] && w_comp=${#SUMMARY_COMPONENT[$i]}
        [ ${#SUMMARY_STATUS[$i]} -gt "$w_stat" ] && w_stat=${#SUMMARY_STATUS[$i]}
        i=$((i + 1))
    done
    printf '\n%-*s  %-*s  %s\n' "$w_comp" 'Component' "$w_stat" 'Status' 'Detail'
    printf '%-*s  %-*s  %s\n' \
        "$w_comp" "$(dashes "$w_comp")" "$w_stat" "$(dashes "$w_stat")" "$(dashes 40)"
    i=0
    while [ "$i" -lt "$count" ]; do
        printf '%-*s  %-*s  %s\n' \
            "$w_comp" "${SUMMARY_COMPONENT[$i]}" \
            "$w_stat" "${SUMMARY_STATUS[$i]}" \
            "${SUMMARY_DETAIL[$i]}"
        i=$((i + 1))
    done
    printf '\n'
}

dashes() {
    local n=$1 out=''
    while [ "$n" -gt 0 ]; do out="$out-"; n=$((n - 1)); done
    printf '%s' "$out"
}

summary_has_status() {
    local want=$1 i=0 count=${#SUMMARY_STATUS[@]}
    while [ "$i" -lt "$count" ]; do
        if [ "${SUMMARY_STATUS[$i]}" = "$want" ]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# ---- Failure handling ------------------------------------------------------
# ---------------------------------------------------------------------------
die() {
    printf '\n'
    write_fail "Setup failed: $1"
    shift || true
    while [ "$#" -gt 0 ]; do
        write_info "$1"
        shift
    done
    ERROR_REPORTED=1
    if [ ${#SUMMARY_COMPONENT[@]} -gt 0 ]; then
        show_summary
    fi
    exit 1
}

on_exit() {
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ "$FINISHED" -eq 0 ] && [ "$ERROR_REPORTED" -eq 0 ]; then
        printf '\n'
        write_fail "Setup failed unexpectedly (exit $rc) — see the output above."
        if [ ${#SUMMARY_COMPONENT[@]} -gt 0 ]; then
            show_summary
        fi
    fi
    stop_log
    cleanup_staging
    exit "$rc"
}

on_interrupt() {
    printf '\n'
    write_warn 'Interrupted.'
    ERROR_REPORTED=1
    exit 130
}

cleanup_staging() {
    # Guarded rm -rf: never act on an empty/relative/unexpected path.
    case "$STAGE_DIR" in
        /*/.staging-*)
            if [ -d "$STAGE_DIR" ]; then
                rm -rf -- "$STAGE_DIR"
            fi
            ;;
    esac
    STAGE_DIR=''
}

# ---------------------------------------------------------------------------
# ---- Per-run log (mirrors Start-Transcript) --------------------------------
# ---------------------------------------------------------------------------
# stdout/stderr are routed through a FIFO into `tee`, so the console keeps
# seeing everything live (an `exec > file` alone would hide the whole run).
# The log copy is filtered: ANSI colour codes are stripped and carriage-return
# progress redraws are collapsed, so the file stays paste-able into an issue.
# tee runs as a real background job, which means stop_log can `wait` for it and
# the last lines can never be lost.
start_log() {
    local esc
    LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
    LOG_FIFO="$STAGE_DIR/log.fifo"
    : > "$LOG_FILE" || die "Cannot write the log file $LOG_FILE"
    mkfifo "$LOG_FIFO" || die "Cannot create the log pipe $LOG_FIFO"
    esc=$(printf '\033')
    exec 3>&1 4>&2
    {
        tee /dev/fd/3 < "$LOG_FIFO" |
            awk -v e="$esc" '
                { sub(/^.*\r/, ""); gsub(e "\\[[0-9;]*[A-Za-z]", ""); print; fflush() }
            ' > "$LOG_FILE"
    } &
    LOG_PID=$!
    exec > "$LOG_FIFO" 2>&1
    LOG_ACTIVE=1
}

stop_log() {
    if [ "$LOG_ACTIVE" -ne 1 ]; then
        return 0
    fi
    LOG_ACTIVE=0
    exec 1>&3 2>&4          # closes the write end so tee/awk see EOF
    if [ -n "$LOG_PID" ]; then
        wait "$LOG_PID" 2>/dev/null || true
        LOG_PID=''
    fi
    if [ -n "$LOG_FIFO" ] && [ -p "$LOG_FIFO" ]; then
        rm -f -- "$LOG_FIFO"
    fi
}

# ---------------------------------------------------------------------------
# ---- Generic helpers -------------------------------------------------------
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
    cat <<'USAGE'
Flutter (Android) development environment setup for Linux.

Usage:
  setup.sh [options]

Options:
  --verify-only          Check and report only; change nothing on disk or in
                         the environment (still runs `flutter doctor`).
  --skip-android         Skip the JDK and Android SDK steps (e.g. Android
                         Studio already provides them).
  --install-root <path>  Root directory for SDK installs.
                         Default: $HOME/dev. Must not contain spaces — that is
                         a Flutter SDK limitation, not this script's.
  --precache             Run `flutter precache --android` at the end.
  -h, --help             Show this help and exit.

Examples:
  ./setup.sh
  ./setup.sh --verify-only
  ./setup.sh --install-root "$HOME/sdk" --precache
  ./setup.sh --skip-android

Exit codes:
  0  success
  1  failure, or a component is MISSING
  2  everything installed but `flutter doctor` reports toolchain issues

What it changes (also the uninstall checklist):
  * <root>/{flutter,java,Android/sdk,.downloads,logs}
  * one marker-delimited block in your shell profile (~/.profile for bash,
    ~/.zprofile for zsh) exporting ANDROID_HOME, JAVA_HOME and PATH
  * Android SDK licence hashes in <root>/Android/sdk/licenses/
  * `flutter config` android-sdk / jdk-dir in the Flutter user settings
  * an empty ~/.android/repositories.cfg
No sudo, no package manager, nothing outside your home directory.
USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --verify-only)  VERIFY_ONLY=1 ;;
            --skip-android) SKIP_ANDROID=1 ;;
            --precache)     PRECACHE=1 ;;
            --install-root)
                if [ "$#" -lt 2 ]; then
                    printf 'Error: --install-root requires a path argument.\n\n' >&2
                    usage >&2
                    exit 1
                fi
                INSTALL_ROOT="$2"
                shift
                ;;
            --install-root=*)
                INSTALL_ROOT="${1#--install-root=}"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'Error: unknown option: %s\n\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
    if [ -z "$INSTALL_ROOT" ]; then
        printf 'Error: --install-root must not be empty.\n' >&2
        exit 1
    fi
}

init_paths() {
    FLUTTER_HOME="$INSTALL_ROOT/flutter"
    JAVA_ROOT="$INSTALL_ROOT/java"
    ANDROID_HOME_DIR="$INSTALL_ROOT/Android/sdk"
    DOWNLOAD_DIR="$INSTALL_ROOT/.downloads"
    LOG_DIR="$INSTALL_ROOT/logs"
}

# ---------------------------------------------------------------------------
# ---- HTTP + checksum + download (mirrors Invoke-Download) ------------------
# ---------------------------------------------------------------------------
http_get() {
    # Small text bodies only (manifests). Prints the body on stdout.
    curl --fail --location --silent --show-error \
         --connect-timeout 20 --max-time 120 \
         --retry 2 --retry-delay 2 \
         --user-agent "$CFG_USER_AGENT" \
         -- "$1"
}

http_reachable() {
    curl --fail --location --silent --show-error --head \
         --connect-timeout 15 --max-time 30 \
         --user-agent "$CFG_USER_AGENT" \
         --output /dev/null -- "$1"
}

file_hash() {
    # $1 = algorithm (256 or 1), $2 = file
    # coreutils sha256sum/sha1sum is the norm on Linux; shasum (perl) is the
    # fallback for minimal images. HASH_TOOL is chosen in check_required_tools.
    case "${HASH_TOOL:-}" in
        shasum) shasum -a "$1" -- "$2" | awk '{ print $1; exit }' ;;
        *)
            if [ "$1" = '1' ]; then
                sha1sum -- "$2" | awk '{ print $1; exit }'
            else
                sha256sum -- "$2" | awk '{ print $1; exit }'
            fi ;;
    esac
}

hash_matches() {
    # $1 = algorithm, $2 = file, $3 = expected hex
    local actual
    actual=$(file_hash "$1" "$2") || return 1
    [ "$(lower "$actual")" = "$(lower "$3")" ]
}

human_mb() {
    # Portable file size in MB (GNU stat uses -c; BSD -f is the fallback)
    local bytes
    bytes=$(stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo 0)
    awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1048576 }'
}

download() {
    # $1 = url, $2 = destination, $3 = hash algorithm (256|1|""), $4 = expected hash
    local url="$1" dest="$2" algo="${3:-}" want="${4:-}"
    local part="$dest.partial" attempt=1 wait_s name progress
    name=$(basename -- "$dest")

    if [ -f "$dest" ]; then
        if [ -z "$want" ] || [ -z "$algo" ] || hash_matches "$algo" "$dest" "$want"; then
            write_skip "Already downloaded: $name"
            return 0
        fi
        write_warn 'Cached file failed checksum; re-downloading'
        rm -f -- "$dest"
    fi

    # A live progress bar only makes sense on a terminal; in CI/pipes keep quiet.
    if [ "$IS_TTY" -eq 1 ]; then
        progress='--progress-bar'
    else
        progress='--no-progress-meter'
    fi

    while [ "$attempt" -le "$CFG_DOWNLOAD_RETRIES" ]; do
        write_info "Downloading ($attempt/$CFG_DOWNLOAD_RETRIES): $url"
        rm -f -- "$part"
        # --fail: no HTML error pages on disk. --location: follow redirects
        # (GitHub release assets). --retry: curl's own exponential backoff for
        # transient blips, wrapped in this outer 3/6/12s backoff loop for the
        # rest. --speed-limit/--speed-time abort a transfer that has stalled
        # rather than hanging forever.
        if curl --fail --location "$progress" --show-error \
                --connect-timeout 20 --retry 2 --retry-delay 2 \
                --speed-limit 1024 --speed-time 60 \
                --user-agent "$CFG_USER_AGENT" \
                --output "$part" -- "$url"; then
            if [ -n "$want" ] && [ -n "$algo" ]; then
                if ! hash_matches "$algo" "$part" "$want"; then
                    write_warn "SHA-$algo mismatch for $name"
                    rm -f -- "$part"
                    if [ "$attempt" -ge "$CFG_DOWNLOAD_RETRIES" ]; then
                        die "Checksum verification failed after $CFG_DOWNLOAD_RETRIES attempts: $url" \
                            "Expected SHA-$algo $want"
                    fi
                    attempt=$((attempt + 1))
                    continue
                fi
            fi
            # Only complete, verified files ever get the real name, so the
            # skip-if-cached check above is always trustworthy.
            mv -f -- "$part" "$dest"
            write_ok "Downloaded $name ($(human_mb "$dest") MB)"
            return 0
        fi
        rm -f -- "$part"
        if [ "$attempt" -ge "$CFG_DOWNLOAD_RETRIES" ]; then
            die "Download failed after $CFG_DOWNLOAD_RETRIES attempts: $url" \
                'Check your network / proxy (HTTPS_PROXY) and try again.'
        fi
        wait_s=$((3 * (1 << (attempt - 1))))   # 3, 6, 12 seconds
        write_warn "Attempt $attempt failed. Retrying in ${wait_s}s..."
        sleep "$wait_s"
        attempt=$((attempt + 1))
    done
}

# ---------------------------------------------------------------------------
# ---- Extraction (mirrors Expand-ArchiveFast) -------------------------------
# ---------------------------------------------------------------------------
extract_zip() {
    # $1 = archive, $2 = destination directory (created if absent)
    local rc=0
    mkdir -p -- "$2"
    # unzip refuses absolute paths and normalises ".." entries, and we only ever
    # extract into a private staging directory, so zip-slip is covered twice.
    unzip -q -o -- "$1" -d "$2" || rc=$?
    if [ "$rc" -eq 1 ]; then
        write_warn "unzip reported warnings for $(basename -- "$1") (continuing; contents are verified below)"
    elif [ "$rc" -ne 0 ]; then
        die "unzip failed on $(basename -- "$1") (exit $rc)"
    fi
}

extract_targz() {
    # $1 = archive, $2 = destination directory (created if absent)
    mkdir -p -- "$2"
    tar -xzf "$1" -C "$2" || die "tar failed on $(basename -- "$1")"
}

extract_tarxz() {
    # $1 = archive, $2 = destination. The Linux Flutter SDK ships .tar.xz
    # (macOS and Windows ship .zip), so xz must be present — check_required_tools
    # verifies that up front rather than letting tar fail here.
    mkdir -p -- "$2"
    tar -xJf "$1" -C "$2" || die "tar failed on $(basename -- "$1")"
}

# ---------------------------------------------------------------------------
# ---- Minimal JSON reader ---------------------------------------------------
# ---------------------------------------------------------------------------
# No jq: the contract forbids new dependencies and most minimal Linux images
# json_normalize puts every JSON object on its own line (so one release entry
# or one "package" object is one line), then json_str pulls a string value out
# of a line. Works on both pretty-printed and compact JSON. It is deliberately
# not a full parser: it assumes no '{' or '}' inside string values, which holds
# for every manifest this script reads.
json_normalize() {
    awk '
        { gsub(/\r/, ""); doc = doc $0 " " }
        END {
            gsub(/[ \t][ \t]+/, " ", doc)
            gsub(/\{/, "\n{", doc)
            gsub(/\}/, "}\n", doc)
            print doc
        }
    '
}

json_str() {
    # $1 = normalized text (one or more lines), $2 = key. First match wins.
    awk -v k="$2" '
        {
            if (match($0, "\"" k "\"[ ]*:[ ]*\"")) {
                rest = substr($0, RSTART + RLENGTH)
                if (match(rest, "\"")) { print substr(rest, 1, RSTART - 1); exit }
            }
        }
    ' <<< "$1"
    # Note: here-strings (not pipes) feed awk everywhere in this script — an awk
    # that `exit`s early would otherwise SIGPIPE the writer, and `set -o
    # pipefail` would turn that into a spurious failure.
}

# ---------------------------------------------------------------------------
# ---- Runtime resolvers -----------------------------------------------------
# ---------------------------------------------------------------------------
resolve_flutter() {
    # Sets RESOLVED_URL / RESOLVED_SHA / RESOLVED_ALGO / RESOLVED_VERSION.
    local raw norm current stable base entry archive
    RESOLVED_ALGO='256'
    # x86_64 only: detect_arch already refused anything else, because Google
    # publishes no arm64 Linux archive.
    RESOLVED_URL="$CFG_FLUTTER_FALLBACK_URL_X64"
    RESOLVED_SHA="$CFG_FLUTTER_FALLBACK_SHA_X64"
    RESOLVED_VERSION="$CFG_FLUTTER_FALLBACK_VERSION (pinned fallback)"

    if ! raw=$(http_get "$CFG_FLUTTER_RELEASES_JSON" 2>/dev/null); then
        write_warn 'Could not fetch the Flutter releases manifest; using the pinned Flutter URL'
        return 0
    fi
    norm=$(json_normalize <<< "$raw")
    # current_release is an object of its own, so take the "stable" value from
    # the first object line after the "current_release" key (a release entry's
    # own "channel": "stable" must not be mistaken for it).
    current=$(awk '/"current_release"/ { f = 1; next } f { print; exit }' <<< "$norm")
    stable=$(json_str "$current" 'stable')
    base=$(json_str "$norm" 'base_url')
    if [ -z "$stable" ] || [ -z "$base" ]; then
        write_warn 'Flutter manifest had an unexpected shape; using the pinned Flutter URL'
        return 0
    fi
    # Both architectures share the release hash, so match hash AND dart_sdk_arch.
    entry=$(awk -v h="$stable" -v a="$ARCH_FLUTTER" '
        $0 ~ "\"hash\"[ ]*:[ ]*\"" h "\"" && $0 ~ "\"dart_sdk_arch\"[ ]*:[ ]*\"" a "\"" { print; exit }
    ' <<< "$norm")
    archive=$(json_str "$entry" 'archive')
    if [ -z "$entry" ] || [ -z "$archive" ]; then
        write_warn "No stable $ARCH_FLUTTER build in the Flutter manifest; using the pinned Flutter URL"
        return 0
    fi
    RESOLVED_URL="$base/$archive"
    RESOLVED_SHA=$(json_str "$entry" 'sha256')
    RESOLVED_VERSION=$(json_str "$entry" 'version')
    if [ -z "$RESOLVED_SHA" ]; then
        write_warn 'Flutter manifest entry carried no sha256; download will not be checksum verified'
    fi
}

resolve_jdk() {
    # Sets RESOLVED_URL / RESOLVED_SHA / RESOLVED_ALGO / RESOLVED_VERSION.
    local api raw norm pkg link sum name release
    RESOLVED_ALGO='256'
    RESOLVED_URL="$CFG_JDK_FALLBACK_URL_X64"
    RESOLVED_SHA="$CFG_JDK_FALLBACK_SHA_X64"
    RESOLVED_VERSION='jdk-17 (pinned fallback)'

    api="$CFG_TEMURIN_ASSETS_API?os=linux&architecture=$ARCH_ADOPTIUM&image_type=jdk&vendor=eclipse"
    if ! raw=$(http_get "$api" 2>/dev/null); then
        write_warn 'Could not query the Adoptium API; using the pinned JDK URL'
        return 0
    fi
    norm=$(json_normalize <<< "$raw")
    # binary.installer (a .pkg) also has link/checksum/name and comes first in
    # the response, so target the object that follows the "package" key.
    pkg=$(awk '/"package"[ ]*:[ ]*$/ { f = 1; next } f { print; exit }' <<< "$norm")
    link=$(json_str "$pkg" 'link')
    sum=$(json_str "$pkg" 'checksum')
    name=$(json_str "$pkg" 'name')
    release=$(json_str "$norm" 'release_name')
    case "$name" in
        *.tar.gz) ;;
        *)  write_warn "Adoptium returned an unexpected package '$name'; using the pinned JDK URL"
            return 0 ;;
    esac
    if [ -z "$link" ] || [ -z "$sum" ]; then
        write_warn 'Adoptium response had an unexpected shape; using the pinned JDK URL'
        return 0
    fi
    RESOLVED_URL="$link"
    RESOLVED_SHA="$sum"
    if [ -n "$release" ]; then
        RESOLVED_VERSION="$release"
    fi
}

resolve_cmdline_tools() {
    # Sets RESOLVED_URL / RESOLVED_SHA / RESOLVED_ALGO / RESOLVED_VERSION.
    # SHA-1 on purpose: repository2-3.xml is the only machine-readable manifest
    # for cmdline-tools and it publishes <checksum type="sha1"> only.
    local raw line rev url sha
    RESOLVED_ALGO='1'
    RESOLVED_URL="$CFG_CMDLINE_FALLBACK_URL_X64"
    RESOLVED_SHA="$CFG_CMDLINE_FALLBACK_SHA1_X64"
    RESOLVED_VERSION='22.0 (pinned fallback)'

    if ! raw=$(http_get "$CFG_ANDROID_REPO_XML" 2>/dev/null); then
        write_warn 'Could not fetch the Android repository manifest; using the pinned cmdline-tools URL'
        return 0
    fi
    # Walk every <remotePackage path="cmdline-tools;MAJOR.MINOR"> (skipping
    # -alpha/-rc previews) and keep the highest revision whose <url> filename
    # carries our platform token ("linux"). Linux ships one architecture-neutral
    # archive, unlike macOS where the builds are split per architecture.
    line=$(awk -v tok="$ARCH_CMDLINE" '
        /<remotePackage[ \t]+path="cmdline-tools;/ {
            p = $0
            sub(/.*path="cmdline-tools;/, "", p)
            sub(/".*/, "", p)
            inpkg = (p ~ /^[0-9]+\.[0-9]+$/)
            if (inpkg) { split(p, v, "."); rev = v[1] * 1000 + v[2]; ver = p }
            sha = ""
            next
        }
        /<remotePackage/ { inpkg = 0; next }
        inpkg && /<checksum[^>]*type="sha1"[^>]*>/ {
            s = $0; sub(/.*type="sha1">/, "", s); sub(/<.*/, "", s); sha = s; next
        }
        inpkg && /<url>/ {
            u = $0; sub(/.*<url>/, "", u); sub(/<.*/, "", u)
            if (index(u, tok) > 0 && rev > bestrev) {
                bestrev = rev; besturl = u; bestsha = sha; bestver = ver
            }
            next
        }
        END { if (besturl != "" && bestsha != "") printf "%s %s %s\n", bestver, besturl, bestsha }
    ' <<< "$raw")
    if [ -z "$line" ]; then
        write_warn 'No Linux cmdline-tools entry found in the manifest; using the pinned URL'
        return 0
    fi
    rev=$(awk '{ print $1 }' <<< "$line")
    url=$(awk '{ print $2 }' <<< "$line")
    sha=$(awk '{ print $3 }' <<< "$line")
    RESOLVED_VERSION="$rev"
    RESOLVED_URL="$CFG_ANDROID_REPO_BASE/$url"
    RESOLVED_SHA="$sha"
}

# ---------------------------------------------------------------------------
# ---- Environment: one marker block in one profile file ---------------------
# ---------------------------------------------------------------------------
# Windows writes HKCU\Environment and broadcasts WM_SETTINGCHANGE. The shell
# equivalent is a single marker-delimited block, rewritten in place each run,
# plus an immediate export so later steps in THIS run see the values.
choose_profile_file() {
    local shell_name
    shell_name=$(basename -- "${SHELL:-/bin/bash}")
    case "$shell_name" in
        zsh)
            PROFILE_FILE="$HOME/.zprofile"
            ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                PROFILE_FILE="$HOME/.bash_profile"
            else
                PROFILE_FILE="$HOME/.profile"
            fi
            ;;
        *)
            PROFILE_FILE="$HOME/.profile"
            ;;
    esac
}

export_env_var() {
    # $1 = name, $2 = value. Always mirrored into this process (that is what
    # Set-Item Env: does at the end of Set-UserEnvVar); the persistent copy is
    # written once, by write_profile_block.
    case "$1" in
        JAVA_HOME)   JAVA_HOME="$2";     export JAVA_HOME ;;
        ANDROID_HOME) ANDROID_HOME="$2"; export ANDROID_HOME ;;
        *) die "export_env_var: unsupported variable $1" ;;
    esac
    if [ "$VERIFY_ONLY" -eq 1 ]; then
        write_skip "$1=$2 (verify-only: process only, profile untouched)"
    else
        write_ok "$1=$2"
    fi
}

add_path_entry() {
    # Records the entry for the profile block and prepends it to this process's
    # PATH so sdkmanager/flutter see it immediately. Never duplicates.
    local entry="$1" i=0 count=${#PATH_ENTRIES[@]}
    while [ "$i" -lt "$count" ]; do
        if [ "${PATH_ENTRIES[$i]}" = "$entry" ]; then
            entry=''
            break
        fi
        i=$((i + 1))
    done
    if [ -n "$entry" ]; then
        PATH_ENTRIES+=("$entry")
    fi
    case ":$PATH:" in
        *":$1:"*) ;;
        *) PATH="$1:$PATH"; export PATH ;;
    esac
}

symbolic_path() {
    # Render an absolute path using $JAVA_HOME / $ANDROID_HOME where possible,
    # so the profile block reads like the one in CONTRIBUTING.md.
    local p="$1"
    if [ -n "${JAVA_HOME:-}" ]; then
        case "$p" in
            "$JAVA_HOME"/*) printf '$JAVA_HOME%s' "${p#"$JAVA_HOME"}"; return 0 ;;
        esac
    fi
    if [ -n "${ANDROID_HOME:-}" ]; then
        case "$p" in
            "$ANDROID_HOME"/*) printf '$ANDROID_HOME%s' "${p#"$ANDROID_HOME"}"; return 0 ;;
        esac
    fi
    printf '%s' "$p"
}

profile_block_text() {
    local i=0 count=${#PATH_ENTRIES[@]} joined=''
    printf '%s\n' "$MARK_BEGIN"
    printf '%s\n' '# Written by flutter-dev-setup (linux/setup.sh). Re-run the script to update;'
    printf '%s\n' '# edits inside this block are replaced. Delete the whole block to uninstall.'
    if [ -n "${ANDROID_HOME:-}" ]; then
        printf 'export ANDROID_HOME="%s"\n' "$ANDROID_HOME"
    fi
    if [ -n "${JAVA_HOME:-}" ]; then
        printf 'export JAVA_HOME="%s"\n' "$JAVA_HOME"
    fi
    while [ "$i" -lt "$count" ]; do
        if [ -z "$joined" ]; then
            joined=$(symbolic_path "${PATH_ENTRIES[$i]}")
        else
            joined="$joined:$(symbolic_path "${PATH_ENTRIES[$i]}")"
        fi
        i=$((i + 1))
    done
    if [ -n "$joined" ]; then
        printf 'export PATH="%s:$PATH"\n' "$joined"
    fi
    printf '%s\n' "$MARK_END"
}

write_profile_block() {
    write_step 'Shell environment'
    choose_profile_file
    write_info "Profile file: $PROFILE_FILE"

    if [ ${#PATH_ENTRIES[@]} -eq 0 ] && [ -z "${JAVA_HOME:-}" ] && [ -z "${ANDROID_HOME:-}" ]; then
        write_skip 'Nothing to publish (no components installed)'
        return 0
    fi

    if [ "$VERIFY_ONLY" -eq 1 ]; then
        if [ -f "$PROFILE_FILE" ] && grep -Fqx "$MARK_BEGIN" "$PROFILE_FILE"; then
            write_ok "flutter-setup block present in $PROFILE_FILE"
        else
            write_fail "No flutter-setup block in $PROFILE_FILE"
        fi
        write_skip 'verify-only: profile not modified'
        return 0
    fi

    local tmp begins ends mode
    tmp="$STAGE_DIR/profile.new"
    : > "$tmp"
    if [ -f "$PROFILE_FILE" ]; then
        begins=$(grep -Fxc "$MARK_BEGIN" "$PROFILE_FILE" || true)
        ends=$(grep -Fxc "$MARK_END" "$PROFILE_FILE" || true)
        if [ "${begins:-0}" -gt 0 ] && [ "${ends:-0}" -eq 0 ]; then
            write_warn "$PROFILE_FILE has an opening flutter-setup marker but no closing one;"
            write_warn 'everything after it is treated as part of the block and replaced.'
        fi
        # Drop the previous block (markers included) instead of appending a
        # second one. Everything outside the markers is preserved verbatim.
        awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip   { print }
        ' "$PROFILE_FILE" > "$tmp"
        if [ -s "$tmp" ]; then
            printf '\n' >> "$tmp"
        fi
        if [ "${begins:-0}" -gt 0 ]; then
            write_info 'Replacing the existing flutter-setup block'
        fi
    fi
    profile_block_text >> "$tmp"

    # Write via temp file + mv so an interrupted run can never leave a
    # truncated profile; keep the original permissions if there was one.
    if [ -f "$PROFILE_FILE" ]; then
        mode=$(stat -c '%a' "$PROFILE_FILE" 2>/dev/null || stat -f '%Lp' "$PROFILE_FILE" 2>/dev/null || echo '')
        if [ -n "$mode" ]; then
            chmod "$mode" "$tmp" 2>/dev/null || true
        fi
    else
        chmod 644 "$tmp" 2>/dev/null || true
    fi
    mv -f -- "$tmp" "$PROFILE_FILE" || die "Cannot update $PROFILE_FILE"
    write_ok "Environment block written to $PROFILE_FILE"
}

# ---------------------------------------------------------------------------
# ---- JVM networking on corporate machines ----------------------------------
# ---------------------------------------------------------------------------
set_jvm_network_defaults() {
    # sdkmanager is a JVM app and ignores the shell's proxy variables, which is
    # why it can fail ("Failed to download any source lists!") on networks where
    # curl works fine. Process-scoped only, never persisted.
    # Linux: unlike the Windows script this does NOT override the truststore.
    # Windows needs -Djavax.net.ssl.trustStoreType=Windows-ROOT because the JVM
    # ignores the OS certificate store; on Linux the JDK's bundled cacerts is
    # the right store already, and distros that add corporate CAs do it via
    # ca-certificates, which the JDK picks up. Overriding would only break TLS
    # that already works.
    local opts='-Djava.net.useSystemProxies=true' proxy='' host port
    proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
    if [ -n "$proxy" ]; then
        case "$proxy" in
            *://*) proxy="${proxy#*://}" ;;
        esac
        proxy="${proxy%%/*}"
        proxy="${proxy##*@}"          # strip any user:password@
        host="${proxy%%:*}"
        port="${proxy#*:}"
        if [ -n "$host" ] && [ "$port" != "$proxy" ] && [ -n "$port" ]; then
            write_ok "JVM proxy for Android tooling: $host:$port"
            opts="$opts -Dhttps.proxyHost=$host -Dhttps.proxyPort=$port"
            opts="$opts -Dhttp.proxyHost=$host -Dhttp.proxyPort=$port"
        fi
    fi
    case "${JAVA_TOOL_OPTIONS:-}" in
        *"$opts"*) ;;
        '') JAVA_TOOL_OPTIONS="$opts" ;;
        *)  JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS} $opts" ;;
    esac
    export JAVA_TOOL_OPTIONS
    # JVMs print 'Picked up JAVA_TOOL_OPTIONS: ...' to stderr — expected, harmless.
}

# ---------------------------------------------------------------------------
# ---- Root preparation (runs before the log so the log covers everything) ---
# ---------------------------------------------------------------------------
prepare_root() {
    local fallback nothing_at_root something_at_fallback

    case "$INSTALL_ROOT" in
        '~')    INSTALL_ROOT="$HOME" ;;
        '~/'*)  INSTALL_ROOT="$HOME/${INSTALL_ROOT#\~/}" ;;
    esac
    case "$INSTALL_ROOT" in
        /*) ;;
        *)  INSTALL_ROOT="$PWD/$INSTALL_ROOT" ;;
    esac
    INSTALL_ROOT="${INSTALL_ROOT%/}"
    [ -n "$INSTALL_ROOT" ] || die 'The install root resolved to an empty path.'
    init_paths

    case "$INSTALL_ROOT" in
        *[[:space:]]*)
            die "Install root '$INSTALL_ROOT' contains spaces." \
                'The Flutter SDK does not support paths with spaces — use e.g. $HOME/dev.'
            ;;
    esac
    if [ ${#INSTALL_ROOT} -gt 120 ]; then
        write_warn "Install root is ${#INSTALL_ROOT} characters long; deep Gradle/Flutter"
        write_warn 'paths underneath it may hit filesystem limits. A shorter root is safer.'
    fi

    if [ "$VERIFY_ONLY" -eq 1 ]; then
        # Mirror the install-time fallback below: an earlier run may have
        # installed under $HOME/dev instead of the requested root.
        fallback="$HOME/dev"
        nothing_at_root=1
        something_at_fallback=0
        if [ -x "$FLUTTER_HOME/bin/flutter" ] || [ -d "$ANDROID_HOME_DIR" ]; then
            nothing_at_root=0
        fi
        if [ -x "$fallback/flutter/bin/flutter" ] || [ -d "$fallback/Android/sdk" ]; then
            something_at_fallback=1
        fi
        if [ "$nothing_at_root" -eq 1 ] && [ "$something_at_fallback" -eq 1 ] &&
           [ "$INSTALL_ROOT" != "$fallback" ]; then
            case "$fallback" in
                *[[:space:]]*) ;;
                *)  write_warn "Nothing found under $INSTALL_ROOT; verifying $fallback instead"
                    INSTALL_ROOT="$fallback"
                    init_paths ;;
            esac
        fi
        return 0
    fi

    if ! mkdir -p -- "$INSTALL_ROOT" 2>/dev/null; then
        fallback="$HOME/dev"
        write_warn "Cannot create $INSTALL_ROOT; falling back to $fallback"
        case "$fallback" in
            *[[:space:]]*)
                die "Fallback path '$fallback' contains spaces (unsupported by Flutter)." \
                    'Re-run with --install-root pointing at a space-free writable directory.'
                ;;
        esac
        INSTALL_ROOT="$fallback"
        init_paths
        mkdir -p -- "$INSTALL_ROOT" || die "Cannot create $INSTALL_ROOT either."
    fi
    [ -w "$INSTALL_ROOT" ] || die "$INSTALL_ROOT is not writable."
    mkdir -p -- "$DOWNLOAD_DIR" "$LOG_DIR" || die "Cannot create directories under $INSTALL_ROOT"
    STAGE_DIR=$(mktemp -d "$DOWNLOAD_DIR/.staging-XXXXXX") ||
        die "Cannot create a staging directory under $DOWNLOAD_DIR"
    # Staging lives on the same volume as the destinations on purpose: the final
    # `mv` is then a rename, which is what makes the skip-check sentinels
    # ("bin/flutter exists" => a COMPLETE install) trustworthy.
}

# ---------------------------------------------------------------------------
# ---- Preflight (mirrors Test-Preflight) ------------------------------------
# ---------------------------------------------------------------------------
detect_arch() {
    # Google publishes the prebuilt Linux Flutter SDK for x86_64 ONLY — there is
    # no arm64 entry in releases_linux.json. Rather than silently install an
    # x86_64 SDK that cannot run, refuse with the supported alternative.
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)
            ARCH_FLUTTER='x64'; ARCH_ADOPTIUM='x64'; ARCH_CMDLINE='linux' ;;
        aarch64|arm64)
            die "Flutter does not publish a prebuilt Linux SDK for $machine." \
                'Google ships the Linux SDK for x86_64 only, so there is nothing for this' \
                'script to download. On arm64 Linux the supported route is a git checkout:' \
                '' \
                '    git clone -b stable --depth 1 https://github.com/flutter/flutter.git ~/dev/flutter' \
                '    export PATH="$HOME/dev/flutter/bin:$PATH"' \
                '    flutter --version   # builds the tool from source on first run' \
                '' \
                'Temurin and the Android cmdline-tools DO publish arm64 Linux builds, so once' \
                'you have a Flutter checkout the rest of the toolchain is available — but this' \
                'script installs them as a set and will not run without a Flutter archive.' \
                'Upstream tracking issue: https://github.com/flutter/flutter/issues/109609' ;;
        *)
            die "Unsupported architecture: $machine (this script supports x86_64)" ;;
    esac
    write_ok "Architecture: $machine (Flutter $ARCH_FLUTTER, Temurin $ARCH_ADOPTIUM, cmdline-tools $ARCH_CMDLINE)"
}

distro_install_hint() {
    # Best-effort per-distro command for the missing prerequisites. $1 = packages
    # in Debian naming; we translate for the common families.
    local id='' like=''
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        id=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
        like=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}")
    fi
    case "$id $like" in
        *debian*|*ubuntu*)
            printf '    sudo apt-get update && sudo apt-get install -y %s\n' "$1" ;;
        *fedora*|*rhel*|*centos*)
            printf '    sudo dnf install -y %s\n' "$(printf '%s' "$1" | sed 's/xz-utils/xz/')" ;;
        *arch*)
            printf '    sudo pacman -S --needed %s\n' "$(printf '%s' "$1" | sed 's/xz-utils/xz/')" ;;
        *suse*)
            printf '    sudo zypper install -y %s\n' "$(printf '%s' "$1" | sed 's/xz-utils/xz/')" ;;
        *alpine*)
            printf '    sudo apk add %s\n' "$(printf '%s' "$1" | sed 's/xz-utils/xz/')" ;;
        *)
            printf '    (use your package manager to install: %s)\n' "$1" ;;
    esac
}

check_required_tools() {
    # Detect-or-instruct, never hang: installing these needs root, which this
    # script deliberately never takes.
    local missing='' pkgs='' t
    for t in curl unzip tar xz awk sed mkfifo; do
        if ! have_cmd "$t"; then
            missing="$missing $t"
            case "$t" in
                xz)    pkgs="$pkgs xz-utils" ;;
                awk)   pkgs="$pkgs gawk" ;;
                sed|mkfifo) pkgs="$pkgs coreutils" ;;
                *)     pkgs="$pkgs $t" ;;
            esac
        fi
    done
    # A SHA-256 tool: coreutils ships sha256sum, some minimal images only have
    # perl's shasum. Either is fine; detect which and remember it.
    if have_cmd sha256sum && have_cmd sha1sum; then
        HASH_TOOL='sha256sum'
    elif have_cmd shasum; then
        HASH_TOOL='shasum'
    else
        HASH_TOOL=''
        missing="$missing sha256sum"
        pkgs="$pkgs coreutils"
    fi
    if [ -n "$missing" ]; then
        # Both lists are built by appending " item", so trim the leading space.
        die "Required tool(s) not found:$missing" \
            'Installing them needs root, which this script never takes. Run:' \
            '' \
            "$(distro_install_hint "${pkgs# }")" \
            '' \
            'then re-run this script.'
    fi
    write_ok "Required tools present: curl, unzip, tar, xz, $HASH_TOOL"
}

resolve_git() {
    # Linux has no stub-binary trap (unlike macOS), so command -v is honest.
    local candidate
    GIT_BIN=''
    candidate=$(command -v git 2>/dev/null || true)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        GIT_BIN="$candidate"
        return 0
    fi
    return 1
}

free_gb_for() {
    # Nearest existing ancestor, so this works before the root is created.
    local d="$1"
    while [ ! -d "$d" ] && [ "$d" != '/' ]; do
        d=$(dirname -- "$d")
    done
    df -Pk -- "$d" | awk 'NR > 1 { avail = $4 } END { printf "%.1f", avail / 1048576 }'
}

preflight() {
    local product major free_gb
    write_step 'Preflight checks'

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        product=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")
    else
        product='Linux (no /etc/os-release)'
    fi
    major=$(uname -r | cut -d. -f1)
    case "$major" in
        ''|*[!0-9]*) major=0 ;;
    esac
    if [ "$major" -lt "$CFG_MIN_KERNEL_MAJOR" ]; then
        die "Linux kernel $CFG_MIN_KERNEL_MAJOR or newer is required (found $(uname -r))."
    fi
    write_ok "Distribution: $product (kernel $(uname -r))"

    detect_arch

    if [ "$(id -u)" -eq 0 ]; then
        write_warn 'Running as root. Everything installs into this account only, and files'
        write_warn 'would end up root-owned. Run as the user who will develop instead.'
    fi

    check_required_tools

    if [ "$VERIFY_ONLY" -eq 0 ]; then
        free_gb=$(free_gb_for "$INSTALL_ROOT")
        if awk -v f="$free_gb" -v need="$CFG_REQUIRED_DISK_GB" 'BEGIN { exit !(f < need) }'; then
            die "Only $free_gb GB free on the volume holding $INSTALL_ROOT — at least $CFG_REQUIRED_DISK_GB GB required."
        fi
        write_ok "Disk space: $free_gb GB free for $INSTALL_ROOT"
    fi

    # HEAD an object that actually answers 200; the bare bucket root answers 400.
    if http_reachable "$CFG_FLUTTER_RELEASES_JSON"; then
        write_ok 'Internet connectivity confirmed'
    elif [ "$VERIFY_ONLY" -eq 1 ]; then
        write_warn 'No internet connectivity; verify-only report continues offline.'
    else
        die 'No internet connectivity (or a proxy is blocking access).' \
            'If you are behind a proxy: export HTTPS_PROXY=http://host:port and re-run.'
    fi
}

# ---------------------------------------------------------------------------
# ---- Step 1: prerequisites / git (mirrors Install-Git) ---------------------
# ---------------------------------------------------------------------------
install_git() {
    write_step 'Git'

    if resolve_git; then
        local v
        v=$("$GIT_BIN" --version 2>&1 | head -1)
        write_skip "Git already installed: $v"
        write_info "Path: $GIT_BIN"
        add_summary 'Git' 'Already installed' "$v"
        return 0
    fi

    write_fail 'Git was not found, and installing it needs root.'
    add_summary 'Git' 'MISSING' 'install git with your package manager'
    if [ "$VERIFY_ONLY" -eq 1 ]; then
        # Read-only report: record the row and keep going.
        return 0
    fi
    die 'Git is required by the Flutter SDK. This script never takes root, so install it:' \
        '' \
        "$(distro_install_hint 'git')" \
        'then re-run this script.'
}

# ---------------------------------------------------------------------------
# ---- Step 2: Flutter SDK (mirrors Install-Flutter) -------------------------
# ---------------------------------------------------------------------------
install_flutter() {
    write_step 'Flutter SDK'

    local flutter_exe="$FLUTTER_HOME/bin/flutter"
    if [ -x "$flutter_exe" ]; then
        write_skip "Flutter already present at $FLUTTER_HOME"
        add_path_entry "$FLUTTER_HOME/bin"
        add_summary 'Flutter SDK' 'Already installed' "$FLUTTER_HOME"
        FLUTTER_BIN="$flutter_exe"
        return 0
    fi
    if [ "$VERIFY_ONLY" -eq 1 ]; then
        local found
        found=$(command -v flutter 2>/dev/null || true)
        if [ -n "$found" ]; then
            write_ok "Flutter found on PATH: $found"
            add_summary 'Flutter SDK' 'Already installed' "$found"
            FLUTTER_BIN="$found"
        else
            write_fail 'Flutter is not installed'
            add_summary 'Flutter SDK' 'MISSING' 'run setup without --verify-only'
        fi
        return 0
    fi

    resolve_flutter
    write_info "Latest stable Flutter: $RESOLVED_VERSION ($ARCH_FLUTTER)"
    local zip staging
    zip="$DOWNLOAD_DIR/$(basename -- "$RESOLVED_URL")"
    download "$RESOLVED_URL" "$zip" "$RESOLVED_ALGO" "$RESOLVED_SHA"

    write_info 'Extracting the Flutter SDK (a few minutes)...'
    staging="$STAGE_DIR/flutter"
    rm -rf -- "$staging"
    extract_tarxz "$zip" "$staging"
    # The archive contains a top-level flutter/ directory.
    if [ ! -x "$staging/flutter/bin/flutter" ]; then
        die 'Extraction finished but flutter/bin/flutter was not found in the archive.'
    fi
    if [ -e "$FLUTTER_HOME" ]; then
        # Leftover of an interrupted run — bin/flutter is absent or we would
        # have returned above. Remove it instead of extracting into it.
        write_warn "Removing an incomplete Flutter directory at $FLUTTER_HOME"
        rm -rf -- "$FLUTTER_HOME"
    fi
    mkdir -p -- "$(dirname -- "$FLUTTER_HOME")"
    mv -- "$staging/flutter" "$FLUTTER_HOME" || die "Cannot move the Flutter SDK into $FLUTTER_HOME"
    rm -rf -- "$staging"

    add_path_entry "$FLUTTER_HOME/bin"
    FLUTTER_BIN="$flutter_exe"
    write_ok "Flutter $RESOLVED_VERSION installed at $FLUTTER_HOME"
    add_summary 'Flutter SDK' 'Installed' "$RESOLVED_VERSION at $FLUTTER_HOME"
}

# ---------------------------------------------------------------------------
# ---- Step 3: Temurin JDK 17 (mirrors Install-Jdk) --------------------------
# ---------------------------------------------------------------------------
jdk_home_in() {
    # Linux Temurin uses the plain layout: java is at <dir>/bin/java. The
    # Contents/Home case is macOS-only and is kept purely so a shared archive
    # layout change cannot break this helper.
    if [ -x "$1/bin/java" ]; then
        printf '%s' "$1"
        return 0
    fi
    if [ -x "$1/Contents/Home/bin/java" ]; then
        printf '%s' "$1/Contents/Home"
        return 0
    fi
    return 1
}

find_installed_jdk() {
    local d home
    [ -d "$JAVA_ROOT" ] || return 1
    for d in "$JAVA_ROOT"/*; do
        [ -d "$d" ] || continue
        if home=$(jdk_home_in "$d"); then
            printf '%s' "$home"
            return 0
        fi
    done
    return 1
}

install_jdk() {
    write_step 'Eclipse Temurin JDK 17'

    local existing
    if existing=$(find_installed_jdk); then
        write_skip "JDK already present at $existing"
        export_env_var 'JAVA_HOME' "$existing"
        add_path_entry "$existing/bin"
        JAVA_HOME_RESOLVED="$existing"
        add_summary 'JDK 17' 'Already installed' "$existing"
        return 0
    fi
    if [ "$VERIFY_ONLY" -eq 1 ]; then
        if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
            write_ok "JAVA_HOME set: $JAVA_HOME"
            add_summary 'JDK 17' 'Already installed' "$JAVA_HOME"
            JAVA_HOME_RESOLVED="$JAVA_HOME"
        else
            write_fail 'No JDK found (JAVA_HOME unset or invalid)'
            add_summary 'JDK 17' 'MISSING' 'run setup without --verify-only'
        fi
        return 0
    fi

    resolve_jdk
    write_info "Latest Temurin 17: $RESOLVED_VERSION ($ARCH_ADOPTIUM)"
    local tgz staging d staged='' staged_home='' dest
    tgz="$DOWNLOAD_DIR/$(basename -- "${RESOLVED_URL%%\?*}")"
    download "$RESOLVED_URL" "$tgz" "$RESOLVED_ALGO" "$RESOLVED_SHA"

    write_info 'Extracting the JDK...'
    staging="$STAGE_DIR/jdk"
    rm -rf -- "$staging"
    extract_targz "$tgz" "$staging"
    for d in "$staging"/*; do
        [ -d "$d" ] || continue
        if staged_home=$(jdk_home_in "$d"); then
            staged="$d"
            break
        fi
    done
    if [ -z "$staged" ]; then
        die 'JDK extraction finished but no bin/java was found in the archive.'
    fi

    dest="$JAVA_ROOT/$(basename -- "$staged")"
    if [ -e "$dest" ]; then
        write_warn "Removing an incomplete JDK directory at $dest"
        rm -rf -- "$dest"
    fi
    mkdir -p -- "$JAVA_ROOT"
    mv -- "$staged" "$dest" || die "Cannot move the JDK into $dest"
    rm -rf -- "$staging"

    local home v
    home=$(jdk_home_in "$dest") || die "The installed JDK at $dest has no bin/java."
    export_env_var 'JAVA_HOME' "$home"
    add_path_entry "$home/bin"
    JAVA_HOME_RESOLVED="$home"
    # `java --version` (JDK 9+) writes to stdout; `java -version` writes to stderr.
    v=$("$home/bin/java" --version 2>/dev/null | head -1 || true)
    write_ok "JDK installed: ${v:-$RESOLVED_VERSION}"
    add_summary 'JDK 17' 'Installed' "$home"
}

# ---------------------------------------------------------------------------
# ---- Step 4: Android SDK (cmdline-tools + packages + licenses) -------------
# ---------------------------------------------------------------------------
sdkmanager_path() {
    printf '%s' "$ANDROID_HOME_DIR/cmdline-tools/latest/bin/sdkmanager"
}

run_sdkmanager() {
    # Returns sdkmanager's own exit code. `yes |` answers every licence prompt;
    # pipefail is disabled inside the subshell because `yes` is killed by
    # SIGPIPE the moment sdkmanager stops reading, which would otherwise be
    # reported as a pipeline failure. Output is not piped through sed: it is
    # already captured by the log tee, and a pipe would buffer the progress
    # lines sdkmanager prints for a long download.
    local rc=0
    set +e
    ( set +o pipefail; yes 2>/dev/null | "$(sdkmanager_path)" "$@" 2>&1 )
    rc=$?
    set -e
    return "$rc"
}

install_android_cmdline_tools() {
    write_step 'Android command-line tools'

    local sdkmanager staging latest_dir
    sdkmanager=$(sdkmanager_path)

    if [ -x "$sdkmanager" ]; then
        write_skip "cmdline-tools already present at $ANDROID_HOME_DIR"
        add_summary 'Android cmdline-tools' 'Already installed' "$ANDROID_HOME_DIR"
    elif [ "$VERIFY_ONLY" -eq 1 ]; then
        write_fail 'Android cmdline-tools not installed'
        add_summary 'Android cmdline-tools' 'MISSING' 'run setup without --verify-only'
        # Fall through: the env-var report below keeps the verify output complete.
    else
        resolve_cmdline_tools
        write_info "cmdline-tools revision: $RESOLVED_VERSION ($ARCH_CMDLINE)"
        write_info 'Verifying with SHA-1: Google publishes no SHA-256 for this archive.'
        local zip
        zip="$DOWNLOAD_DIR/$(basename -- "$RESOLVED_URL")"
        download "$RESOLVED_URL" "$zip" "$RESOLVED_ALGO" "$RESOLVED_SHA"

        # sdkmanager derives the SDK root from its own location and REQUIRES
        # <sdk>/cmdline-tools/latest/bin/sdkmanager. The zip holds a bare
        # top-level cmdline-tools/ directory, so extract to staging and move it.
        staging="$STAGE_DIR/cmdline-tools"
        rm -rf -- "$staging"
        extract_zip "$zip" "$staging"
        if [ ! -f "$staging/cmdline-tools/bin/sdkmanager" ]; then
            die 'cmdline-tools extraction finished but cmdline-tools/bin/sdkmanager is missing.'
        fi
        latest_dir="$ANDROID_HOME_DIR/cmdline-tools/latest"
        mkdir -p -- "$ANDROID_HOME_DIR/cmdline-tools"
        if [ -e "$latest_dir" ]; then
            # Anything here is broken (no executable sdkmanager) and moving into
            # an existing directory would NEST rather than replace.
            write_warn "Removing an incomplete cmdline-tools directory at $latest_dir"
            rm -rf -- "$latest_dir"
        fi
        mv -- "$staging/cmdline-tools" "$latest_dir" || die "Cannot move cmdline-tools into $latest_dir"
        rm -rf -- "$staging"
        chmod +x "$latest_dir"/bin/* 2>/dev/null || true
        if [ ! -x "$sdkmanager" ]; then
            die "cmdline-tools installed but $sdkmanager is not executable."
        fi
        write_ok "cmdline-tools installed at $latest_dir"
        add_summary 'Android cmdline-tools' 'Installed' "$latest_dir"
    fi

    # Environment for the Android tooling
    export_env_var 'ANDROID_HOME' "$ANDROID_HOME_DIR"
    add_path_entry "$ANDROID_HOME_DIR/platform-tools"
    add_path_entry "$ANDROID_HOME_DIR/cmdline-tools/latest/bin"

    [ -x "$sdkmanager" ]
}

install_android_packages() {
    write_step 'Android SDK packages'

    local adb platform_dir build_tools_dir license_file repo_cfg rc
    adb="$ANDROID_HOME_DIR/platform-tools/adb"
    platform_dir="$ANDROID_HOME_DIR/platforms/${CFG_ANDROID_PLATFORM#*;}"
    build_tools_dir="$ANDROID_HOME_DIR/build-tools/${CFG_ANDROID_BUILD_TOOLS#*;}"
    license_file="$ANDROID_HOME_DIR/licenses/android-sdk-license"

    if [ "$VERIFY_ONLY" -eq 1 ]; then
        # Note: a distro-packaged adb on PATH proves nothing, so only our own paths
        # are checked here.
        if [ -x "$adb" ] && [ -d "$platform_dir" ] && [ -d "$build_tools_dir" ]; then
            write_ok 'platform-tools, platform and build-tools present'
            add_summary 'Android SDK packages' 'Already installed' "$ANDROID_HOME_DIR"
        else
            write_fail 'Android SDK packages incomplete or missing'
            add_summary 'Android SDK packages' 'MISSING' 'run setup without --verify-only'
        fi
        if [ -f "$license_file" ]; then
            write_ok 'Android SDK licenses accepted'
            add_summary 'Android licenses' 'Accepted' ''
        else
            write_fail 'Android SDK licenses not accepted'
            add_summary 'Android licenses' 'MISSING' 'run setup without --verify-only'
        fi
        return 0
    fi

    # Silence the known "missing repositories.cfg" sdkmanager warning
    repo_cfg="$HOME/.android/repositories.cfg"
    if [ ! -f "$repo_cfg" ]; then
        mkdir -p -- "$HOME/.android"
        : > "$repo_cfg"
    fi

    # NOTE: deliberately NOT installing 'cmdline-tools;latest' — as soon as the
    # downloaded archive lags the current release that request becomes a
    # self-update, and sdkmanager replacing its own jars mid-run deadlocks.
    if [ -x "$adb" ] && [ -d "$platform_dir" ] && [ -d "$build_tools_dir" ]; then
        write_skip 'Required SDK packages already installed'
        add_summary 'Android SDK packages' 'Already installed' \
            "platform-tools, $CFG_ANDROID_PLATFORM, $CFG_ANDROID_BUILD_TOOLS"
    else
        write_info "Installing: platform-tools, $CFG_ANDROID_PLATFORM, $CFG_ANDROID_BUILD_TOOLS (large download, please wait)..."
        rc=0
        run_sdkmanager "--sdk_root=$ANDROID_HOME_DIR" \
            'platform-tools' "$CFG_ANDROID_PLATFORM" "$CFG_ANDROID_BUILD_TOOLS" || rc=$?
        if [ "$rc" -ne 0 ]; then
            die "sdkmanager package install failed (exit $rc)." \
                "If the output above shows 'Failed to download any source lists' or 'IO exception" \
                "while downloading manifest', your network (proxy/TLS inspection) is blocking the" \
                'Java tooling even though curl worked. Set HTTPS_PROXY explicitly (with credentials' \
                'if required) and re-run, or run once on a different network.'
        fi
        [ -x "$adb" ] || die 'sdkmanager finished but platform-tools/adb is missing.'
        write_ok 'SDK packages installed'
        add_summary 'Android SDK packages' 'Installed' \
            "platform-tools, $CFG_ANDROID_PLATFORM, $CFG_ANDROID_BUILD_TOOLS"
    fi

    if [ -f "$license_file" ]; then
        write_skip 'Android SDK licenses already accepted'
        add_summary 'Android licenses' 'Already accepted' ''
    else
        write_info 'Accepting Android SDK licenses...'
        rc=0
        run_sdkmanager "--sdk_root=$ANDROID_HOME_DIR" '--licenses' || rc=$?
        # Success is the licence file existing, not the exit code alone.
        if [ -f "$license_file" ]; then
            write_ok 'All Android SDK licenses accepted'
            add_summary 'Android licenses' 'Accepted' ''
        else
            write_fail "sdkmanager --licenses did not write $license_file (exit $rc)"
            add_summary 'Android licenses' 'MISSING' 'run: sdkmanager --licenses'
        fi
    fi
}

# ---------------------------------------------------------------------------
# ---- Step 5: flutter configuration + doctor (mirrors Invoke-FlutterDoctor) --
# ---------------------------------------------------------------------------
run_flutter_doctor() {
    write_step 'Verification: flutter doctor'

    local flutter="$FLUTTER_HOME/bin/flutter" found doctor_output scoped xmark pattern rc
    if [ ! -x "$flutter" ]; then
        found=$(command -v flutter 2>/dev/null || true)
        if [ -n "$found" ]; then
            flutter="$found"
        else
            write_fail 'flutter not found; skipping doctor'
            add_summary 'flutter doctor' 'SKIPPED' 'flutter not installed'
            return 0
        fi
    fi

    if [ "$SKIP_ANDROID" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
        # Point Flutter explicitly at our SDK/JDK: robust even if the env vars
        # are shadowed later. The first flutter invocation also downloads the
        # Dart SDK, so its output is shown rather than swallowed — otherwise the
        # script looks hung for several minutes.
        write_info 'Configuring Flutter (the first run downloads the Dart SDK)...'
        rc=0
        "$flutter" config --android-sdk "$ANDROID_HOME_DIR" 2>&1 | indent_lines || rc=$?
        if [ "$rc" -ne 0 ]; then
            write_warn "flutter config --android-sdk exited with code $rc"
        fi
        if [ -n "${JAVA_HOME:-}" ]; then
            rc=0
            "$flutter" config --jdk-dir "$JAVA_HOME" 2>&1 | indent_lines || rc=$?
            if [ "$rc" -ne 0 ]; then
                write_warn "flutter config --jdk-dir exited with code $rc"
            fi
        fi

        # Register licence acceptance with Flutter's own checker as well.
        write_info 'Running flutter doctor --android-licenses...'
        rc=0
        set +e
        ( set +o pipefail; yes 2>/dev/null | "$flutter" doctor --android-licenses 2>&1 ) | indent_lines
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -ne 0 ]; then
            write_warn "flutter doctor --android-licenses exited with code $rc (see the doctor output below)"
        fi
    fi

    if [ "$PRECACHE" -eq 1 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
        write_info 'Running flutter precache --android...'
        rc=0
        "$flutter" precache --android 2>&1 | indent_lines || rc=$?
        if [ "$rc" -ne 0 ]; then
            write_warn "flutter precache --android exited with code $rc"
        fi
    fi

    printf '\n'
    doctor_output=$("$flutter" doctor -v 2>&1 || true)
    printf '%s\n' "$doctor_output" | indent_lines

    # Report doctor's verdict honestly — but only the sections this script owns
    # may count as failures. On Linux that means [X] "Linux toolchain - develop
    # for Linux desktop" (clang/cmake/ninja/GTK), Chrome and Android Studio are
    # out of scope: this script sets up ANDROID builds, not desktop or web
    # targets (see Non-goals in CONTRIBUTING.md).
    # The cross mark is built from bytes so matching never depends on the
    # file's encoding or the current locale.
    xmark=$(printf '\342\234\227')
    pattern="^[[:space:]]*\[($xmark|X|ERR)\][[:space:]]*(Flutter|Android toolchain)"
    scoped=$(printf '%s\n' "$doctor_output" | grep -E "$pattern" || true)
    if [ -n "$scoped" ]; then
        add_summary 'flutter doctor' 'ISSUES FOUND' 'toolchain problems — see the doctor output above'
    elif printf '%s\n' "$doctor_output" | grep -Eq "\[($xmark|X|ERR)\]"; then
        add_summary 'flutter doctor' 'Passed (unrelated issues)' \
            'out-of-scope items flagged (e.g. Linux desktop toolchain/Chrome/Android Studio)'
    else
        add_summary 'flutter doctor' 'Passed' ''
    fi
}

# ---------------------------------------------------------------------------
# ---- Main ------------------------------------------------------------------
# ---------------------------------------------------------------------------
main() {
    init_colors
    parse_args "$@"
    init_paths

    trap on_exit EXIT
    trap on_interrupt INT TERM

    printf '\n%s=============================================%s\n' "$C_HEAD" "$C_RESET"
    printf '%s  Flutter Development Environment Setup      %s\n' "$C_HEAD" "$C_RESET"
    printf '%s=============================================%s\n' "$C_HEAD" "$C_RESET"
    if [ "$VERIFY_ONLY" -eq 1 ]; then
        printf '%s  Mode: VERIFY ONLY (no changes will be made)%s\n' "$C_WARN" "$C_RESET"
    fi
    if [ "$SKIP_ANDROID" -eq 1 ]; then
        printf '%s  Android SDK/JDK steps: SKIPPED%s\n' "$C_WARN" "$C_RESET"
    fi
    printf '  Install root: %s\n' "$INSTALL_ROOT"

    # Create/resolve the root before logging starts so the log covers the whole
    # run, preflight included (the Windows transcript starts after preflight
    # because its root fallback lives there; here that fallback is handled by
    # prepare_root, which is the only step that can still change the root).
    prepare_root
    if [ "$VERIFY_ONLY" -eq 0 ]; then
        start_log
        printf '  Resolved install root: %s\n' "$INSTALL_ROOT"
        printf '  Log file: %s\n' "$LOG_FILE"
    fi

    preflight

    install_git
    install_flutter

    if [ "$SKIP_ANDROID" -eq 0 ]; then
        install_jdk
        if [ "$VERIFY_ONLY" -eq 0 ]; then
            set_jvm_network_defaults
        fi
        # verify-only's package/licence checks are pure path tests, so they are
        # safe to run without a working sdkmanager.
        if install_android_cmdline_tools || [ "$VERIFY_ONLY" -eq 1 ]; then
            install_android_packages
        fi
    fi

    write_profile_block

    run_flutter_doctor
    show_summary

    # 0 = all good, 1 = something missing, 2 = installed but doctor unhappy
    if summary_has_status 'MISSING'; then
        EXIT_CODE=1
    elif summary_has_status 'ISSUES FOUND'; then
        EXIT_CODE=2
    fi

    if [ "$VERIFY_ONLY" -eq 0 ]; then
        printf '%sDone. IMPORTANT: open a NEW terminal window (or run: source %s)%s\n' \
            "$C_OK" "$PROFILE_FILE" "$C_RESET"
        printf '%sso the PATH changes take effect.%s\n' "$C_OK" "$C_RESET"
        printf 'Log file: %s\n' "$LOG_FILE"
    fi

    FINISHED=1
    exit "$EXIT_CODE"
}

# The guard keeps the script sourceable (for testing individual resolvers)
# while still running normally when executed.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

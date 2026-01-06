<#
.SYNOPSIS
    Complete Flutter (Android) development environment setup for Windows.

.DESCRIPTION
    Unattended installer that takes a fresh Windows 10/11 (64-bit) machine to a
    fully working Flutter Android toolchain:

      1. Git for Windows           (silent install, per-user, no admin needed)
      2. Flutter SDK               (latest stable, resolved at runtime, SHA-256 verified)
      3. Eclipse Temurin JDK 17    (resolved at runtime via Adoptium API, SHA-256 verified)
      4. Android command-line tools + platform-tools + platform + build-tools
      5. Environment variables     (user PATH, ANDROID_HOME, JAVA_HOME)
      6. Android SDK license acceptance (fully automatic)
      7. flutter doctor verification

    Everything is installed per-user — no administrator rights required.
    The script is idempotent: every step checks whether it is already done and
    skips cleanly, so it is safe to re-run at any time (also works as "repair").

.PARAMETER InstallRoot
    Root directory for SDK installs (default: C:\dev). Must not contain spaces —
    the Flutter SDK does not support paths with spaces or special characters.
    If the root cannot be created (locked-down machine), the script falls back
    to %USERPROFILE%\dev and prints a warning.

.PARAMETER VerifyOnly
    Only check what is installed/configured and run `flutter doctor`; install nothing.

.PARAMETER SkipAndroid
    Skip the JDK / Android SDK steps (e.g. if Android Studio already provides them).

.PARAMETER Precache
    Run `flutter precache --android` at the end (downloads Android build artifacts now
    instead of on first build).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 -VerifyOnly
    powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 -InstallRoot D:\sdk

.NOTES
    Exit codes: 0 = success, 1 = failure or components missing,
    2 = everything installed but flutter doctor reports toolchain issues.
    Side effect outside the install root: `flutter config` persists the
    android-sdk and jdk-dir paths in the user profile (%APPDATA%\flutter).
#>

[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\dev',
    [switch]$VerifyOnly,
    [switch]$SkipAndroid,
    [switch]$Precache
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# ---- Config: runtime resolvers + pinned fallbacks (verified 2026-08-05) ----
# ---------------------------------------------------------------------------
$Config = @{
    # Runtime resolvers (primary sources — always give the latest stable)
    FlutterReleasesJson  = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'
    TemurinAssetsApi     = 'https://api.adoptium.net/v3/assets/latest/17/hotspot?os=windows&architecture=x64&image_type=jdk&vendor=eclipse'
    GitLatestApi         = 'https://api.github.com/repos/git-for-windows/git/releases/latest'

    # Pinned fallbacks (used only if runtime resolution fails)
    FlutterFallbackUrl   = 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.44.8-stable.zip'
    FlutterFallbackSha   = '095c108a08e0377d8a6501fed65aeb288908a070ed3f135e525dc6431c7686e4'
    JdkFallbackUrl       = 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20%2B8/OpenJDK17U-jdk_x64_windows_hotspot_17.0.20_8.zip'
    JdkFallbackSha       = '418497be5cf585bdd2203d6486a565d66d3f5e992d5630d45104cb873fab8122'
    GitFallbackUrl       = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-64-bit.exe'

    # Android (pinned: URL embeds a build number, no generic "latest" URL exists)
    CmdlineToolsUrl      = 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip'
    CmdlineToolsSha      = '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a'
    # Matches Flutter stable 3.44.x defaults (compileSdk 36) and AGP 9.3 (build-tools 36.0.0)
    AndroidPlatform      = 'platforms;android-36'
    AndroidBuildTools    = 'build-tools;36.0.0'

    RequiredDiskGB       = 15
    DownloadRetries      = 3
}

# ---------------------------------------------------------------------------
# ---- Output helpers --------------------------------------------------------
# ---------------------------------------------------------------------------
function Write-Step($Message)  { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok($Message)    { Write-Host "    [OK]      $Message" -ForegroundColor Green }
function Write-Skip($Message)  { Write-Host "    [SKIP]    $Message" -ForegroundColor DarkGray }
function Write-Warn2($Message) { Write-Host "    [WARN]    $Message" -ForegroundColor Yellow }
function Write-Fail($Message)  { Write-Host "    [FAIL]    $Message" -ForegroundColor Red }

$script:Summary = New-Object System.Collections.ArrayList
function Add-Summary($Component, $Status, $Detail) {
    [void]$script:Summary.Add([pscustomobject]@{
        Component = $Component; Status = $Status; Detail = $Detail
    })
}
function Show-Summary {
    Write-Host ''
    Write-Host '=============================================' -ForegroundColor Magenta
    Write-Host '  Summary                                    ' -ForegroundColor Magenta
    Write-Host '=============================================' -ForegroundColor Magenta
    $script:Summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
}

# ---------------------------------------------------------------------------
# ---- Generic helpers -------------------------------------------------------
# ---------------------------------------------------------------------------
function Test-CommandExists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Json([string]$Url) {
    # GitHub API rejects requests without a User-Agent
    return Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 30 `
        -Headers @{ 'User-Agent' = 'flutter-setup-script' }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Sha256
    )
    if (Test-Path $Destination) {
        if (-not $Sha256 -or (Get-FileHash $Destination -Algorithm SHA256).Hash -ieq $Sha256) {
            Write-Skip "Already downloaded: $(Split-Path $Destination -Leaf)"
            return
        }
        Write-Warn2 'Cached file failed checksum; re-downloading'
        Remove-Item $Destination -Force
    }
    $tempFile = "$Destination.partial"
    for ($attempt = 1; $attempt -le $Config.DownloadRetries; $attempt++) {
        try {
            Write-Host "    Downloading ($attempt/$($Config.DownloadRetries)): $Url"
            $prevProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'   # progress bar makes IWR ~10x slower in PS 5.1
            try {
                Invoke-WebRequest -Uri $Url -OutFile $tempFile -UseBasicParsing `
                    -MaximumRedirection 10 -Headers @{ 'User-Agent' = 'flutter-setup-script' }
            } finally {
                $ProgressPreference = $prevProgress
            }
            if ($Sha256 -and (Get-FileHash $tempFile -Algorithm SHA256).Hash -ine $Sha256) {
                throw "SHA-256 mismatch for $Url"
            }
            # Only complete, verified files ever get the real name (safe skip-if-cached)
            Move-Item $tempFile $Destination -Force
            $sizeMB = [math]::Round((Get-Item $Destination).Length / 1MB, 1)
            Write-Ok "Downloaded $(Split-Path $Destination -Leaf) ($sizeMB MB)"
            return
        } catch {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            if ($attempt -eq $Config.DownloadRetries) {
                throw "Download failed after $($Config.DownloadRetries) attempts: $Url`n$($_.Exception.Message)"
            }
            $wait = 3 * [math]::Pow(2, $attempt - 1)   # 3, 6, 12s
            Write-Warn2 "Attempt $attempt failed ($($_.Exception.Message)). Retrying in $wait s..."
            Start-Sleep -Seconds $wait
        }
    }
}

function Expand-ArchiveFast {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tarExe) {
        # tar.exe (ships with Windows 10 1803+) is far faster than Expand-Archive
        & $tarExe -xf $ZipPath -C $Destination
        if ($LASTEXITCODE -ne 0) { throw "tar.exe failed extracting $ZipPath (exit $LASTEXITCODE)" }
    } else {
        # .NET Framework's ExtractToDirectory has no overwrite overload and throws
        # on any pre-existing file, so extract entry-by-entry with overwrite.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $destRoot = (Get-Item $Destination).FullName.TrimEnd('\')
            foreach ($entry in $archive.Entries) {
                $target = [System.IO.Path]::GetFullPath((Join-Path $destRoot $entry.FullName))
                if (-not $target.StartsWith($destRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Zip entry escapes destination: $($entry.FullName)"
                }
                if ($entry.Name -eq '') {
                    # Directory entry — ExtractToFile would throw on these
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                } else {
                    $parent = Split-Path $target -Parent
                    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                    # Extension methods need the static class in PowerShell
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                }
            }
        } finally { $archive.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# ---- Environment variable / PATH helpers (user scope, registry-backed) ----
# ---------------------------------------------------------------------------
# setx is NOT used: it truncates values at 1024 characters and rewrites
# REG_EXPAND_SZ as REG_SZ. We edit HKCU\Environment directly instead.

function Get-UserEnvVarRaw([string]$Name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        if ($null -eq $key) { return $null }
        # DoNotExpandEnvironmentNames keeps %REFS% intact so we never destroy them
        return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally { if ($key) { $key.Close() } }
}

function Set-UserEnvVar([string]$Name, [string]$Value) {
    if (-not $VerifyOnly) {
        # CreateSubKey opens writable and creates the key if a minimal profile lacks it
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
        try {
            $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String)
        } finally { if ($key) { $key.Close() } }
        Write-Ok "Set user env var $Name = $Value"
    }
    # Mirror into this session so later steps (sdkmanager, flutter) see it immediately
    Set-Item -Path "Env:$Name" -Value $Value
}

function Add-UserPathEntry([string]$Entry) {
    if (-not $VerifyOnly) {
        $raw = Get-UserEnvVarRaw 'Path'
        if ($null -eq $raw) { $raw = '' }
        # Dedupe against expanded, trailing-slash-tolerant forms
        $already = $false
        foreach ($e in ($raw -split ';' | Where-Object { $_ })) {
            $expanded = [Environment]::ExpandEnvironmentVariables($e).TrimEnd('\')
            if ($expanded -ieq $Entry.TrimEnd('\')) { $already = $true; break }
        }
        if ($already) {
            Write-Skip "PATH already contains $Entry"
        } else {
            $newValue = if ($raw -and -not $raw.EndsWith(';')) { "$raw;$Entry" } else { "$raw$Entry" }
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
            try {
                # User PATH is conventionally REG_EXPAND_SZ; keep %VAR% entries working
                $key.SetValue('Path', $newValue, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            } finally { if ($key) { $key.Close() } }
            Write-Ok "Added to user PATH: $Entry"
        }
    }
    # Current session: PREPEND so our tools win over any stale machine-wide entries
    if (($env:Path -split ';') -notcontains $Entry) {
        $env:Path = "$Entry;$env:Path"
    }
}

function Send-EnvironmentChangeBroadcast {
    # Tell running apps (Explorer, new terminals) that environment variables changed.
    # Without this, users must log off/on before new consoles see the updated PATH.
    if (-not ('FlutterSetup.NativeMethods' -as [type])) {
        Add-Type -Namespace FlutterSetup -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $HWND_BROADCAST   = [IntPtr]0xFFFF
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002
    $result = [UIntPtr]::Zero
    [void][FlutterSetup.NativeMethods]::SendMessageTimeout(
        $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment',
        $SMTO_ABORTIFHUNG, 5000, [ref]$result)
}

# ---------------------------------------------------------------------------
# ---- Non-interactive "yes" input for license prompts -----------------------
# ---------------------------------------------------------------------------
# PowerShell-native piping into .bat files intermittently dies with "the
# pipeline has been stopped" in PS 5.1 when the child exits before consuming
# all stdin. cmd.exe stdin redirection from a yes-file is reliable.
function Invoke-WithYesInput {
    param([Parameter(Mandatory)][string]$Executable, [string[]]$Arguments)
    $yesFile = Join-Path $script:DownloadDir 'yes.txt'
    if (-not (Test-Path $yesFile)) {
        Set-Content -Path $yesFile -Value (('y' + "`r`n") * 60) -NoNewline -Encoding ASCII
    }
    $argString = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    # Stream child output to the console; keep the success stream empty so the
    # function's ONLY return value is the exit code (callers do `-ne 0` checks,
    # which would silently become array filtering if output leaked into it).
    & cmd /c "`"$Executable`" $argString < `"$yesFile`" 2>&1" | ForEach-Object { Write-Host "    $_" }
    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# ---- Preflight -------------------------------------------------------------
# ---------------------------------------------------------------------------
function Test-Preflight {
    Write-Step 'Preflight checks'

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'Windows 10 or newer is required.'
    }
    Write-Ok "Windows version: $([Environment]::OSVersion.Version)"

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw '64-bit Windows is required.'
    }

    if (Test-IsElevated) {
        Write-Warn2 'Running elevated. Everything installs user-scope for the CURRENT account;'
        Write-Warn2 'for best results run non-elevated as the user who will develop.'
    }

    # TLS 1.2 for PowerShell 5.1 (its default handshake is often too old)
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if ($VerifyOnly) {
        # Mirror the install-time locked-down-machine fallback below: a prior run
        # may have installed under %USERPROFILE%\dev instead of $InstallRoot.
        $fallback = Join-Path $env:USERPROFILE 'dev'
        $nothingAtRoot = -not (Test-Path (Join-Path $script:InstallRoot 'flutter\bin\flutter.bat')) -and
                         -not (Test-Path (Join-Path $script:InstallRoot 'Android\sdk'))
        $somethingAtFallback = (Test-Path (Join-Path $fallback 'flutter\bin\flutter.bat')) -or
                               (Test-Path (Join-Path $fallback 'Android\sdk'))
        if ($nothingAtRoot -and $somethingAtFallback -and ($fallback -notmatch '\s')) {
            Write-Warn2 "Nothing found under $script:InstallRoot; verifying fallback root $fallback instead"
            $script:InstallRoot = $fallback
            Initialize-Paths
        }
        return
    }

    if ($script:InstallRoot -match '\s') {
        throw "InstallRoot '$script:InstallRoot' contains spaces. The Flutter SDK does not support paths with spaces — choose e.g. C:\dev."
    }
    try {
        New-Item -ItemType Directory -Path $script:InstallRoot -Force | Out-Null
    } catch {
        # Locked-down machine where C:\ root is not writable: fall back to the profile
        $fallback = Join-Path $env:USERPROFILE 'dev'
        Write-Warn2 "Cannot create $script:InstallRoot ($($_.Exception.Message)); falling back to $fallback"
        if ($fallback -match '\s') {
            throw "Fallback path '$fallback' contains spaces (unsupported by Flutter). Re-run with -InstallRoot pointing to a space-free writable folder."
        }
        $script:InstallRoot = $fallback
        Initialize-Paths
        New-Item -ItemType Directory -Path $script:InstallRoot -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null

    $drive = (Get-Item $script:InstallRoot).PSDrive
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGB -lt $Config.RequiredDiskGB) {
        throw "Only $freeGB GB free on drive $($drive.Name): — at least $($Config.RequiredDiskGB) GB required."
    }
    Write-Ok "Disk space: $freeGB GB free on $($drive.Name):"

    try {
        # HEAD an object that returns 200 — the bare GCS root answers 400, which IWR throws on
        Invoke-WebRequest -Uri $Config.FlutterReleasesJson -Method Head -UseBasicParsing -TimeoutSec 15 | Out-Null
        Write-Ok 'Internet connectivity confirmed'
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            # Any HTTP response proves connectivity; only DNS/TCP/TLS failures have no Response
            Write-Ok 'Internet connectivity confirmed (server answered with an HTTP status)'
        } else {
            throw "No internet connectivity (or a proxy is blocking access): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# ---- Step 1: Git -----------------------------------------------------------
# ---------------------------------------------------------------------------
function Install-Git {
    Write-Step 'Git for Windows'

    if (Test-CommandExists 'git') {
        $v = (& git --version) 2>&1
        Write-Skip "Git already installed: $v"
        Add-Summary 'Git' 'Already installed' "$v"
        return
    }
    # Common install locations that may just be missing from this session's PATH
    $knownGit = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
        'C:\Program Files\Git\cmd\git.exe'
    )
    foreach ($g in $knownGit) {
        if (Test-Path $g) {
            Add-UserPathEntry (Split-Path $g)
            Write-Skip "Git found at $g (ensured on PATH)"
            Add-Summary 'Git' 'Already installed' $g
            return
        }
    }
    if ($VerifyOnly) {
        Write-Fail 'Git is not installed'
        Add-Summary 'Git' 'MISSING' 'run setup without -VerifyOnly'
        return
    }

    # Resolve latest 64-bit installer from the GitHub API; fall back to a pinned URL
    $url = $Config.GitFallbackUrl
    try {
        $release = Get-Json $Config.GitLatestApi
        $asset = $release.assets | Where-Object { $_.name -match '^Git-[\d\.]+-64-bit\.exe$' } | Select-Object -First 1
        if ($asset) { $url = $asset.browser_download_url }
    } catch {
        Write-Warn2 "Could not query GitHub API ($($_.Exception.Message)); using pinned Git URL"
    }

    $installer = Join-Path $script:DownloadDir (Split-Path $url -Leaf)
    Invoke-Download -Url $url -Destination $installer

    Write-Host '    Installing Git silently (per-user, no admin)...'
    # /CURRENTUSER (Inno Setup): installs to %LOCALAPPDATA%\Programs\Git without UAC
    $proc = Start-Process -FilePath $installer -ArgumentList `
        '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/CURRENTUSER' -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "Git installer exited with code $($proc.ExitCode)"
    }

    $gitCmd = Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd'
    if (-not (Test-Path (Join-Path $gitCmd 'git.exe'))) {
        # An elevated shell may have installed machine-wide instead
        $gitCmd = 'C:\Program Files\Git\cmd'
    }
    if (-not (Test-Path (Join-Path $gitCmd 'git.exe'))) {
        throw 'Git installer finished but git.exe was not found in the expected locations.'
    }
    Add-UserPathEntry $gitCmd
    $v = (& (Join-Path $gitCmd 'git.exe') --version) 2>&1
    Write-Ok "Git installed: $v"
    Add-Summary 'Git' 'Installed' "$v"
}

# ---------------------------------------------------------------------------
# ---- Step 2: Flutter SDK ---------------------------------------------------
# ---------------------------------------------------------------------------
function Install-Flutter {
    Write-Step 'Flutter SDK'

    $flutterBat = Join-Path $script:FlutterHome 'bin\flutter.bat'
    if (Test-Path $flutterBat) {
        Write-Skip "Flutter already present at $script:FlutterHome"
        Add-UserPathEntry (Join-Path $script:FlutterHome 'bin')
        Add-Summary 'Flutter SDK' 'Already installed' $script:FlutterHome
        return
    }
    if ($VerifyOnly) {
        if (Test-CommandExists 'flutter') {
            Write-Ok "Flutter found on PATH: $((Get-Command flutter).Source)"
            Add-Summary 'Flutter SDK' 'Already installed' (Get-Command flutter).Source
        } else {
            Write-Fail 'Flutter is not installed'
            Add-Summary 'Flutter SDK' 'MISSING' 'run setup without -VerifyOnly'
        }
        return
    }

    # Resolve latest stable from the official releases manifest
    $url = $Config.FlutterFallbackUrl
    $sha = $Config.FlutterFallbackSha
    $version = '(pinned fallback)'
    try {
        $manifest = Get-Json $Config.FlutterReleasesJson
        $stableHash = $manifest.current_release.stable
        $release = $manifest.releases |
            # Order matters under StrictMode: older manifest entries lack
            # dart_sdk_arch, so the hash check must short-circuit first
            Where-Object { $_.hash -eq $stableHash -and $_.dart_sdk_arch -eq 'x64' } |
            Select-Object -First 1
        if ($release) {
            $url = "$($manifest.base_url)/$($release.archive)"
            $sha = $release.sha256
            $version = $release.version
        }
    } catch {
        Write-Warn2 "Could not resolve latest stable ($($_.Exception.Message)); using pinned Flutter URL"
    }
    Write-Host "    Latest stable Flutter: $version"

    $zip = Join-Path $script:DownloadDir (Split-Path $url -Leaf)
    Invoke-Download -Url $url -Destination $zip -Sha256 $sha

    Write-Host '    Extracting Flutter SDK (a few minutes)...'
    # Stage-and-move: extract to staging, then rename into place. The rename is
    # near-atomic on the same volume, so bin\flutter.bat existing at FlutterHome
    # reliably means a COMPLETE extraction (trustworthy idempotency sentinel).
    $staging = Join-Path $script:DownloadDir 'flutter-staging'
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    Expand-ArchiveFast -ZipPath $zip -Destination $staging
    if (-not (Test-Path (Join-Path $staging 'flutter\bin\flutter.bat'))) {
        throw 'Extraction finished but flutter\bin\flutter.bat was not found in the archive'
    }
    if (Test-Path $script:FlutterHome) {
        # Leftover of an interrupted run (flutter.bat absent, or we'd have returned above)
        Remove-Item $script:FlutterHome -Recurse -Force
    }
    Move-Item (Join-Path $staging 'flutter') $script:FlutterHome
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue

    Add-UserPathEntry (Join-Path $script:FlutterHome 'bin')
    Write-Ok "Flutter $version installed at $script:FlutterHome"
    Add-Summary 'Flutter SDK' 'Installed' "$version at $script:FlutterHome"
}

# ---------------------------------------------------------------------------
# ---- Step 3: Temurin JDK 17 ------------------------------------------------
# ---------------------------------------------------------------------------
function Install-Jdk {
    Write-Step 'Eclipse Temurin JDK 17'

    $existingJdk = $null
    if (Test-Path $script:JavaRoot) {
        $existingJdk = Get-ChildItem $script:JavaRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } |
            Select-Object -First 1
    }
    if ($existingJdk) {
        Write-Skip "JDK already present at $($existingJdk.FullName)"
        Set-UserEnvVar 'JAVA_HOME' $existingJdk.FullName
        Add-UserPathEntry (Join-Path $existingJdk.FullName 'bin')
        Add-Summary 'JDK 17' 'Already installed' $existingJdk.FullName
        return
    }
    if ($VerifyOnly) {
        if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
            Write-Ok "JAVA_HOME set: $env:JAVA_HOME"
            Add-Summary 'JDK 17' 'Already installed' $env:JAVA_HOME
        } else {
            Write-Fail 'No JDK found (JAVA_HOME unset or invalid)'
            Add-Summary 'JDK 17' 'MISSING' 'run setup without -VerifyOnly'
        }
        return
    }

    # Resolve latest 17 GA (link + checksum) from Adoptium; fall back to pin
    $url = $Config.JdkFallbackUrl
    $sha = $Config.JdkFallbackSha
    try {
        $assets = Get-Json $Config.TemurinAssetsApi
        $pkg = $assets[0].binary.package
        if ($pkg.link) {
            $url = $pkg.link
            $sha = $pkg.checksum
        }
    } catch {
        Write-Warn2 "Could not query Adoptium API ($($_.Exception.Message)); using pinned JDK URL"
    }

    $zip = Join-Path $script:DownloadDir (Split-Path ([uri]$url).LocalPath -Leaf)
    Invoke-Download -Url $url -Destination $zip -Sha256 $sha

    Write-Host '    Extracting JDK...'
    # Stage-and-move for a trustworthy idempotency sentinel (see Install-Flutter)
    $staging = Join-Path $script:DownloadDir 'jdk-staging'
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    Expand-ArchiveFast -ZipPath $zip -Destination $staging
    $stagedJdk = Get-ChildItem $staging -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } |
        Select-Object -First 1
    if (-not $stagedJdk) { throw 'JDK extraction finished but no bin\java.exe found in the archive' }
    if (Test-Path $script:JavaRoot) {
        # Anything here is a broken leftover (we'd have returned above otherwise)
        Remove-Item $script:JavaRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $script:JavaRoot -Force | Out-Null
    Move-Item $stagedJdk.FullName (Join-Path $script:JavaRoot $stagedJdk.Name)
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    $jdkDir = Get-Item (Join-Path $script:JavaRoot $stagedJdk.Name)

    Set-UserEnvVar 'JAVA_HOME' $jdkDir.FullName
    Add-UserPathEntry (Join-Path $jdkDir.FullName 'bin')
    # java --version (JDK 9+) prints to stdout; `-version` prints to stderr, which
    # PS 5.1 + ErrorActionPreference=Stop turns into a terminating error
    $v = & (Join-Path $jdkDir.FullName 'bin\java.exe') --version | Select-Object -First 1
    Write-Ok "JDK installed: $v"
    Add-Summary 'JDK 17' 'Installed' $jdkDir.FullName
}

# ---------------------------------------------------------------------------
# ---- Step 4: Android SDK (cmdline-tools + packages + licenses) -------------
# ---------------------------------------------------------------------------
function Get-SdkManagerPath {
    return Join-Path $script:AndroidHome 'cmdline-tools\latest\bin\sdkmanager.bat'
}

function Install-AndroidCmdlineTools {
    Write-Step 'Android command-line tools'

    $sdkmanager = Get-SdkManagerPath
    if (Test-Path $sdkmanager) {
        Write-Skip "cmdline-tools already present at $script:AndroidHome"
        Add-Summary 'Android cmdline-tools' 'Already installed' $script:AndroidHome
    } elseif ($VerifyOnly) {
        Write-Fail 'Android cmdline-tools not installed'
        Add-Summary 'Android cmdline-tools' 'MISSING' 'run setup without -VerifyOnly'
        # Still check env vars below so the verify report is complete
    } else {
        $zip = Join-Path $script:DownloadDir (Split-Path $Config.CmdlineToolsUrl -Leaf)
        Invoke-Download -Url $Config.CmdlineToolsUrl -Destination $zip -Sha256 $Config.CmdlineToolsSha

        # sdkmanager derives the SDK root from its own location and REQUIRES the
        # layout <sdk>\cmdline-tools\latest\bin\... The zip holds a bare
        # 'cmdline-tools' folder, so extract to staging and move it into place.
        $staging = Join-Path $script:DownloadDir 'cmdline-tools-staging'
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
        Expand-ArchiveFast -ZipPath $zip -Destination $staging

        $latestDir = Join-Path $script:AndroidHome 'cmdline-tools\latest'
        New-Item -ItemType Directory -Path (Split-Path $latestDir) -Force | Out-Null
        if (Test-Path $latestDir) {
            # A 'latest' dir reaching this path is broken (no sdkmanager.bat) — and
            # Move-Item into an existing dir would NEST instead of replace
            Remove-Item $latestDir -Recurse -Force
        }
        Move-Item (Join-Path $staging 'cmdline-tools') $latestDir
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $sdkmanager)) { throw "cmdline-tools installed but $sdkmanager not found" }
        Write-Ok "cmdline-tools installed at $latestDir"
        Add-Summary 'Android cmdline-tools' 'Installed' $latestDir
    }

    # Environment for Android tooling
    Set-UserEnvVar 'ANDROID_HOME' $script:AndroidHome
    Add-UserPathEntry (Join-Path $script:AndroidHome 'platform-tools')
    Add-UserPathEntry (Join-Path $script:AndroidHome 'cmdline-tools\latest\bin')
    return (Test-Path $sdkmanager)
}

function Install-AndroidPackages {
    Write-Step 'Android SDK packages'

    $adb = Join-Path $script:AndroidHome 'platform-tools\adb.exe'
    $platformDir = Join-Path $script:AndroidHome ('platforms\' + ($Config.AndroidPlatform -split ';')[1])
    $buildToolsDir = Join-Path $script:AndroidHome ('build-tools\' + ($Config.AndroidBuildTools -split ';')[1])

    if ($VerifyOnly) {
        if ((Test-Path $adb) -and (Test-Path $platformDir) -and (Test-Path $buildToolsDir)) {
            Write-Ok 'platform-tools, platform and build-tools present'
            Add-Summary 'Android SDK packages' 'Already installed' $script:AndroidHome
        } else {
            Write-Fail 'Android SDK packages incomplete or missing'
            Add-Summary 'Android SDK packages' 'MISSING' 'run setup without -VerifyOnly'
        }
        $licenseFile = Join-Path $script:AndroidHome 'licenses\android-sdk-license'
        if (Test-Path $licenseFile) {
            Write-Ok 'Android SDK licenses accepted'
            Add-Summary 'Android licenses' 'Accepted' ''
        } else {
            Write-Fail 'Android SDK licenses not accepted'
            Add-Summary 'Android licenses' 'MISSING' 'run setup without -VerifyOnly'
        }
        return
    }

    $sdkmanager = Get-SdkManagerPath

    # Silence the known "missing repositories.cfg" sdkmanager warning
    $repoCfg = Join-Path $env:USERPROFILE '.android\repositories.cfg'
    if (-not (Test-Path $repoCfg)) {
        New-Item -ItemType Directory -Path (Split-Path $repoCfg) -Force | Out-Null
        New-Item -ItemType File -Path $repoCfg -Force | Out-Null
    }

    # NOTE: deliberately NOT installing 'cmdline-tools;latest' here — once the
    # pinned zip lags the current release, that request becomes a self-update
    # that fails on Windows (sdkmanager cannot replace its own running jars).
    $packages = @(
        'platform-tools',
        $Config.AndroidPlatform,
        $Config.AndroidBuildTools
    )
    if ((Test-Path $adb) -and (Test-Path $platformDir) -and (Test-Path $buildToolsDir)) {
        Write-Skip 'Required SDK packages already installed'
        Add-Summary 'Android SDK packages' 'Already installed' ($packages -join ', ')
    } else {
        Write-Host "    Installing: $($packages -join ', ') (large download, please wait)..."
        $exitCode = Invoke-WithYesInput -Executable $sdkmanager `
            -Arguments (@("--sdk_root=$script:AndroidHome") + $packages)
        if ($exitCode -ne 0) { throw "sdkmanager package install failed (exit $exitCode)" }
        if (-not (Test-Path $adb)) { throw 'sdkmanager finished but platform-tools\adb.exe is missing' }
        Write-Ok 'SDK packages installed'
        Add-Summary 'Android SDK packages' 'Installed' ($packages -join ', ')
    }

    $licenseFile = Join-Path $script:AndroidHome 'licenses\android-sdk-license'
    if (Test-Path $licenseFile) {
        Write-Skip 'Android SDK licenses already accepted'
        Add-Summary 'Android licenses' 'Already accepted' ''
    } else {
        Write-Host '    Accepting Android SDK licenses...'
        $exitCode = Invoke-WithYesInput -Executable $sdkmanager `
            -Arguments @("--sdk_root=$script:AndroidHome", '--licenses')
        if ($exitCode -ne 0) { throw "sdkmanager --licenses failed (exit $exitCode)" }
        Write-Ok 'All Android SDK licenses accepted'
        Add-Summary 'Android licenses' 'Accepted' ''
    }
}

# ---------------------------------------------------------------------------
# ---- Step 5: flutter configuration + doctor --------------------------------
# ---------------------------------------------------------------------------
function Invoke-FlutterDoctor {
    Write-Step 'Verification: flutter doctor'

    $flutterBat = Join-Path $script:FlutterHome 'bin\flutter.bat'
    if (-not (Test-Path $flutterBat)) {
        if (Test-CommandExists 'flutter') {
            $flutterBat = (Get-Command flutter).Source
        } else {
            Write-Fail 'flutter not found; skipping doctor'
            Add-Summary 'flutter doctor' 'SKIPPED' 'flutter not installed'
            return
        }
    }

    # flutter/dart/git write progress and warnings to stderr. In PS 5.1, `2>&1`
    # under ErrorActionPreference=Stop turns each stderr line into a TERMINATING
    # NativeCommandError - relax it around every flutter invocation.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (-not $SkipAndroid -and -not $VerifyOnly) {
            # Point Flutter explicitly at our SDK/JDK (robust even if env vars are shadowed)
            & $flutterBat config --android-sdk $script:AndroidHome 2>&1 | Out-Null
            if ($env:JAVA_HOME) {
                & $flutterBat config --jdk-dir $env:JAVA_HOME 2>&1 | Out-Null
            }

            # Register license acceptance with Flutter's own checker as well
            Write-Host '    Running flutter doctor --android-licenses...'
            $licExit = Invoke-WithYesInput -Executable $flutterBat -Arguments @('doctor', '--android-licenses')
            if ($licExit -ne 0) {
                Write-Warn2 "flutter doctor --android-licenses exited with code $licExit (check doctor output below)"
            }
        }

        if ($Precache -and -not $VerifyOnly) {
            Write-Host '    Running flutter precache --android...'
            & $flutterBat precache --android 2>&1 | ForEach-Object { Write-Host "    $_" }
        }

        Write-Host ''
        $doctorOutput = @(& $flutterBat doctor -v 2>&1)
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $doctorOutput | ForEach-Object { Write-Host "    $_" }

    # Report doctor's verdict honestly - but only sections this script owns may
    # count as failures; [X] Visual Studio / Chrome etc. are out of scope here.
    $scoped = @($doctorOutput | Where-Object {
        "$_" -match '^\s*\[(\u2717|X|ERR)\]\s*(Flutter|Windows Version|Android toolchain)'
    })
    if ($scoped.Count -gt 0) {
        Add-Summary 'flutter doctor' 'ISSUES FOUND' 'toolchain problems - see doctor output above'
    } elseif (($doctorOutput -join "`n") -match '\[(\u2717|X|ERR)\]') {
        Add-Summary 'flutter doctor' 'Passed (unrelated issues)' 'out-of-scope items flagged (e.g. Visual Studio/Chrome)'
    } else {
        Add-Summary 'flutter doctor' 'Passed' ''
    }
}

# ---------------------------------------------------------------------------
# ---- Main ------------------------------------------------------------------
# ---------------------------------------------------------------------------
function Initialize-Paths {
    $script:FlutterHome = Join-Path $script:InstallRoot 'flutter'
    $script:JavaRoot    = Join-Path $script:InstallRoot 'java'
    $script:AndroidHome = Join-Path $script:InstallRoot 'Android\sdk'
    $script:DownloadDir = Join-Path $script:InstallRoot '.downloads'
    $script:LogDir      = Join-Path $script:InstallRoot 'logs'
}

$script:InstallRoot = $InstallRoot
Initialize-Paths

$transcriptStarted = $false
$exitCode = 0
try {
    Write-Host ''
    Write-Host '=============================================' -ForegroundColor Magenta
    Write-Host '  Flutter Development Environment Setup     ' -ForegroundColor Magenta
    Write-Host '=============================================' -ForegroundColor Magenta
    if ($VerifyOnly)  { Write-Host '  Mode: VERIFY ONLY (no changes will be made)' -ForegroundColor Yellow }
    if ($SkipAndroid) { Write-Host '  Android SDK/JDK steps: SKIPPED' -ForegroundColor Yellow }
    Write-Host "  Install root: $script:InstallRoot"

    Test-Preflight

    if (-not $VerifyOnly) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        $logFile = Join-Path $script:LogDir ('setup-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
        Start-Transcript -Path $logFile | Out-Null
        $transcriptStarted = $true
        # Re-echo after preflight: it may have fallen back to %USERPROFILE%\dev,
        # and the transcript starts only now
        Write-Host "  Resolved install root: $script:InstallRoot"
    }

    Install-Git
    Install-Flutter

    if (-not $SkipAndroid) {
        Install-Jdk
        $toolsOk = Install-AndroidCmdlineTools
        # VerifyOnly's package/license checks are pure Test-Path — safe without sdkmanager
        if ($toolsOk -or $VerifyOnly) {
            Install-AndroidPackages
        }
    }

    if (-not $VerifyOnly) {
        Send-EnvironmentChangeBroadcast
    }

    Invoke-FlutterDoctor
    Show-Summary

    # Exit codes: 0 = all good, 1 = components missing, 2 = installed but doctor found toolchain issues
    if ($script:Summary | Where-Object { $_.Status -eq 'MISSING' }) { $exitCode = 1 }
    elseif ($script:Summary | Where-Object { $_.Status -eq 'ISSUES FOUND' }) { $exitCode = 2 }

    if (-not $VerifyOnly) {
        Write-Host 'Done. IMPORTANT: open a NEW terminal window so PATH changes take effect.' -ForegroundColor Green
        if ($transcriptStarted) { Write-Host "Log file: $logFile" }
    }
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Fail "Setup failed: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    if ($script:Summary.Count -gt 0) { Show-Summary }
} finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
exit $exitCode

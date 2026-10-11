# Builds Linux release artifacts from already-built release binaries:
#   Rimmerge-<version>-linux-x64-portable.tar.gz      desktop app + CLI + licenses
#   rimmerge-cli-<version>-x86_64-unknown-linux-gnu.tar.gz  the CLI binary alone
#   rimmerge_<version>_amd64.deb                       Tauri-generated .deb package
#   Rimmerge_<version>_amd64.AppImage                  Tauri-generated AppImage
#
# The .deb and AppImage are already built by `tauri build --bundles deb,appimage`
# in the CI job; this script collects them from target/release/bundle/ alongside
# the portable tarball it assembles itself. Shared by the CI workflow and a
# maintainer\x27s local check, so a local run produces the same layout a release ships.
#
# Prerequisites (this script builds nothing):
#   cargo build --release -p rimmerge-cli
#   (cd apps/desktop && bun run tauri build)
#
# Usage:
#   pwsh ./scripts/package-linux.ps1 -Version 1.0.0 [-OutDir <dir>] [-TargetDir <dir>]
#   -OutDir defaults to the repo root, -TargetDir to <repo>/target/release.
#
# Layout of the portable tarball (one top-level folder):
#   Rimmerge-<version>-linux-x64-portable/
#     Rimmerge          the desktop app binary (renamed from rimmerge-desktop)
#     cli/rimmerge      the CLI binary
#     README.txt        how to run, where data lives, how to uninstall
#     LICENSE-MIT, LICENSE-APACHE
#
# Tauri-generated bundles are copied verbatim from their own output paths:
#   target/release/bundle/deb/rimmerge_<version>_amd64.deb
#   target/release/bundle/appimage/Rimmerge_<version>_amd64.AppImage
#
# Fails if any expected binary is missing and removes any partial output on
# failure. Prints every output path. The release\x27s SHA256SUMS.txt is written
# by the workflow, not here.

param(
    [Parameter(Mandatory = $true)][ValidatePattern("^\d+\.\d+\.\d+$")][string]$Version,
    [string]$OutDir,
    [string]$TargetDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir)    { $OutDir    = $repoRoot }
if (-not $TargetDir) { $TargetDir = Join-Path $repoRoot "target/release" }

$desktopBin = Join-Path $TargetDir "rimmerge-desktop"
$cliBin     = Join-Path $TargetDir "rimmerge"
foreach ($required in @($desktopBin, $cliBin)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "missing $required - build it first (see this script\x27s header)"
    }
}

# Locate the Tauri-generated bundles (paths are version-dependent and
# Tauri writes them relative to target/release/bundle/).
$debPattern      = Join-Path $TargetDir "bundle/deb/rimmerge_${Version}_amd64.deb"
$appimagePattern = Join-Path $TargetDir "bundle/appimage/Rimmerge_${Version}_amd64.AppImage"
foreach ($bundleFile in @($debPattern, $appimagePattern)) {
    if (-not (Test-Path -LiteralPath $bundleFile)) {
        throw "missing $bundleFile - run: bun run tauri build"
    }
}

$portableName = "Rimmerge-$Version-linux-x64-portable"
$cliName      = "rimmerge-cli-$Version-x86_64-unknown-linux-gnu"
$tempDir      = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$stage        = Join-Path $tempDir ("rimmerge-linux-" + [guid]::NewGuid().ToString("N"))
$folder       = Join-Path $stage $portableName
New-Item -ItemType Directory -Path $folder | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$resolvedOut  = (Resolve-Path -LiteralPath $OutDir).Path
$tarball      = Join-Path $resolvedOut "$portableName.tar.gz"
$cliTarball   = Join-Path $resolvedOut "$cliName.tar.gz"
$outDeb       = Join-Path $resolvedOut "rimmerge_${Version}_amd64.deb"
$outAppImage  = Join-Path $resolvedOut "Rimmerge_${Version}_amd64.AppImage"

$readme = @"
Rimmerge $Version - portable Linux build

Run the desktop app:   ./Rimmerge
Run the CLI:           ./cli/rimmerge

To use the CLI from any terminal, add this folder\x27s cli/ subdirectory to
your PATH. The folder is named after the version, so rename it to
"Rimmerge" first, or update the PATH entry each time you upgrade.

Requires WebKitGTK 4.1 and GTK at runtime. On Debian/Ubuntu:
  sudo apt install libwebkit2gtk-4.1-0 libayatana-appindicator3-1 librsvg2-2

Your data lives under XDG directories (defaulting to ~/.local/share):
  ~/.local/share/rimmerge              settings, profiles, decisions, rule databases
  ~/.local/share/dev.rimmerge.app      the WebView cache and display preferences

Moving or updating this folder keeps both. To update, extract the newer
tarball beside or over this one.

To uninstall, delete this folder. To remove your data as well, also delete
both data directories above.

Binaries are not code-signed. Verify a download with:
  sha256sum -c SHA256SUMS.txt          (in the download folder)

Documentation: https://github.com/Rimmerge-Project/rimmerge
Licensed under MIT OR Apache-2.0 (see LICENSE-MIT and LICENSE-APACHE).
"@

$outputs = @()
try {
    # Portable tarball
    Copy-Item -LiteralPath $desktopBin -Destination (Join-Path $folder "Rimmerge")
    New-Item -ItemType Directory -Path (Join-Path $folder "cli") | Out-Null
    Copy-Item -LiteralPath $cliBin -Destination (Join-Path $folder "cli/rimmerge")
    foreach ($license in @("LICENSE-MIT", "LICENSE-APACHE")) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $license) -Destination $folder
    }
    Set-Content -LiteralPath (Join-Path $folder "README.txt") -Value $readme -Encoding utf8

    # chmod +x: required on Linux before tar-ing, so the archive preserves the
    # executable bit. On a Windows host (local maintainer check), IsLinux is
    # false and this is skipped — the tarball would carry the wrong permissions
    # if assembled on Windows, so Linux runners are the authoritative packaging
    # environment for this script.
    if ($IsLinux -or $IsMacOS) {
        chmod +x (Join-Path $folder "Rimmerge")
        chmod +x (Join-Path $folder "cli/rimmerge")
    }

    foreach ($stale in @($tarball, $cliTarball, $outDeb, $outAppImage)) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale }
    }

    # tar preserves the Unix permissions chmod set above.
    tar -czf $tarball -C $stage $portableName
    tar -czf $cliTarball -C $TargetDir rimmerge

    # Copy Tauri-generated packages verbatim.
    Copy-Item -LiteralPath $debPattern      -Destination $outDeb
    Copy-Item -LiteralPath $appimagePattern -Destination $outAppImage

    $outputs = @($tarball, $cliTarball, $outDeb, $outAppImage)
    $outputs | ForEach-Object { Write-Output $_ }
}
catch {
    foreach ($partial in $outputs) {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
    throw
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force
}

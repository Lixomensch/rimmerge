# Builds Linux release artifacts from already-built release binaries:
#   Rimmerge-<version>-linux-x64-portable.tar.gz      desktop app + CLI + licenses
#   rimmerge-cli-<version>-x86_64-unknown-linux-gnu.tar.gz  the CLI binary alone
#   Rimmerge_<version>_amd64.deb                       Tauri-generated .deb package
#
# The .deb is built by Tauri. This script collects it alongside
# the portable tarballs it assembles itself. Shared by the CI workflow and a
# maintainer's local check, so a local run produces the same layout a release ships.
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
#   target/release/bundle/deb/Rimmerge_<version>_amd64.deb
#
# Fails if any expected binary is missing and removes any partial output on
# failure. Prints every output path. The release's SHA256SUMS.txt is written
# by the workflow, not here.

param(
    [Parameter(Mandatory = $true)][ValidatePattern("^\d+\.\d+\.\d+$")][string]$Version,
    [string]$OutDir,
    [string]$TargetDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not $IsLinux) { throw "Linux packages must be assembled on Linux" }

function Invoke-CheckedNative {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir)    { $OutDir    = $repoRoot }
if (-not $TargetDir) { $TargetDir = Join-Path $repoRoot "target/release" }

$desktopBin = Join-Path $TargetDir "rimmerge-desktop"
$cliBin     = Join-Path $TargetDir "rimmerge"
foreach ($required in @($desktopBin, $cliBin)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "missing $required - build it first (see this script's header)"
    }
}

# Locate the Tauri-generated bundles (paths are version-dependent and
# Tauri writes them relative to target/release/bundle/).
$debPattern      = Join-Path $TargetDir "bundle/deb/Rimmerge_${Version}_amd64.deb"
if (-not (Test-Path -LiteralPath $debPattern -PathType Leaf)) {
    throw "missing $debPattern - run: bun run tauri build"
}

$portableName = "Rimmerge-$Version-linux-x64-portable"
$cliName      = "rimmerge-cli-$Version-x86_64-unknown-linux-gnu"
$tempDir      = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$stage        = Join-Path $tempDir ("rimmerge-linux-" + [guid]::NewGuid().ToString("N"))
$folder       = Join-Path $stage $portableName
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$resolvedOut  = (Resolve-Path -LiteralPath $OutDir).Path
$tarball      = Join-Path $resolvedOut "$portableName.tar.gz"
$cliTarball   = Join-Path $resolvedOut "$cliName.tar.gz"
$outDeb       = Join-Path $resolvedOut "Rimmerge_${Version}_amd64.deb"

$readme = @"
Rimmerge $Version - portable Linux build

Run the desktop app:   ./Rimmerge
Run the CLI:           ./cli/rimmerge

To use the CLI from any terminal, add this folder's cli/ subdirectory to
your PATH. The folder is named after the version, so rename it to
"Rimmerge" first, or update the PATH entry each time you upgrade.

Initial packaging baseline: Ubuntu 24.04, x86_64 (GNU/Linux).
Requires WebKitGTK 4.1 and GTK at runtime. On Ubuntu 24.04:
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

$outputs = @($tarball, $cliTarball, $outDeb)
# Never delete a source package when an output folder aliases its directory.
foreach ($output in $outputs) {
    foreach ($source in @($desktopBin, $cliBin, $debPattern)) {
        if ([System.IO.Path]::GetFullPath($output) -eq [System.IO.Path]::GetFullPath($source)) {
            throw "output aliases an input: $output"
        }
    }
    if ((Test-Path -LiteralPath $output) -and -not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "output is not a regular file: $output"
    }
}
try {
    New-Item -ItemType Directory -Path $folder | Out-Null
    # Portable tarball
    Copy-Item -LiteralPath $desktopBin -Destination (Join-Path $folder "Rimmerge")
    New-Item -ItemType Directory -Path (Join-Path $folder "cli") | Out-Null
    Copy-Item -LiteralPath $cliBin -Destination (Join-Path $folder "cli/rimmerge")
    foreach ($license in @("LICENSE-MIT", "LICENSE-APACHE")) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $license) -Destination $folder
    }
    Set-Content -LiteralPath (Join-Path $folder "README.txt") -Value $readme -Encoding utf8

    # Archives preserve these modes; assemble both from the staged binaries.
    Invoke-CheckedNative -Command chmod -Arguments @("+x", (Join-Path $folder "Rimmerge"), (Join-Path $folder "cli/rimmerge"))

    foreach ($stale in $outputs) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale }
    }

    # tar preserves the Unix permissions chmod set above.
    Invoke-CheckedNative -Command tar -Arguments @("-czf", $tarball, "-C", $stage, $portableName)
    Invoke-CheckedNative -Command tar -Arguments @("-czf", $cliTarball, "-C", (Join-Path $folder "cli"), "rimmerge")

    # Copy Tauri-generated packages verbatim.
    Copy-Item -LiteralPath $debPattern      -Destination $outDeb
    foreach ($output in $outputs) {
        if (-not (Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item -LiteralPath $output).Length -eq 0) {
            throw "missing or empty output: $output"
        }
    }
    $outputs | ForEach-Object { Write-Output $_ }
}
catch {
    foreach ($partial in $outputs) {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}

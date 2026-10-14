# Collect the exact Windows/Linux release set before writing checksums.
# Used by release.yml; does not create or publish a release.
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory = $true)][string]$ArtifactDir,
    [Parameter(Mandatory = $true)][string]$OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$artifacts = @(
    "zips-windows/Rimmerge-$Version-windows-x64-portable.zip",
    "zips-windows/rimmerge-cli-$Version-x86_64-pc-windows-msvc.zip",
    "zips-linux/Rimmerge-$Version-linux-x64-portable.tar.gz",
    "zips-linux/rimmerge-cli-$Version-x86_64-unknown-linux-gnu.tar.gz",
    "zips-linux/Rimmerge_${Version}_amd64.deb"
)
foreach ($artifact in $artifacts) {
    $source = Join-Path $ArtifactDir $artifact
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -eq 0) {
        throw "missing or empty release artifact: $source"
    }
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outRoot = (Resolve-Path -LiteralPath $OutDir).Path
$outputs = @($artifacts | ForEach-Object { Join-Path $outRoot (Split-Path -Leaf $_) })
$checksums = Join-Path $outRoot 'SHA256SUMS.txt'
foreach ($output in @($outputs) + @($checksums)) {
    if ((Test-Path -LiteralPath $output) -and -not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "output is not a regular file: $output"
    }
}
for ($index = 0; $index -lt $artifacts.Count; $index++) {
    if ([System.IO.Path]::GetFullPath((Join-Path $ArtifactDir $artifacts[$index])) -eq $outputs[$index]) {
        throw "output aliases an input: $($outputs[$index])"
    }
}
try {
    for ($index = 0; $index -lt $artifacts.Count; $index++) {
        Copy-Item -LiteralPath (Join-Path $ArtifactDir $artifacts[$index]) -Destination $outputs[$index] -Force
    }
    $lines = foreach ($output in $outputs) {
        $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $(Split-Path -Leaf $output)"
    }
    Set-Content -LiteralPath $checksums -Value $lines -Encoding utf8NoBOM
    Get-Content -LiteralPath $checksums
}
catch {
    foreach ($partial in @($outputs) + @($checksums)) {
        if (Test-Path -LiteralPath $partial -PathType Leaf) { Remove-Item -LiteralPath $partial -Force }
    }
    throw
}

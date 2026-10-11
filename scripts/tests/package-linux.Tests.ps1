# Hermetic packaging regressions: scratch files only, no build or installation.
# Run on Linux: pwsh ./scripts/tests/package-linux.Tests.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsLinux) { throw 'These packaging tests require Linux' }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$package = Join-Path $repoRoot 'scripts/package-linux.ps1'
$collect = Join-Path $repoRoot 'scripts/collect-release-artifacts.ps1'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("rimmerge package checks " + [guid]::NewGuid().ToString('N'))
$target = Join-Path $scratch 'target'
$mockBin = Join-Path $scratch 'bin'
$version = '9.8.7'
$realTar = (Get-Command tar).Source
$realChmod = (Get-Command chmod).Source
$sha256sum = (Get-Command sha256sum).Source
$savedPath = $env:PATH
$testVariables = @('RIMMERGE_TEST_TAR_MODE', 'RIMMERGE_TEST_TAR_COUNT', 'RIMMERGE_TEST_DEB', 'RIMMERGE_TEST_CHMOD_FAIL')
$savedVariables = @{}
foreach ($name in $testVariables) { $savedVariables[$name] = [Environment]::GetEnvironmentVariable($name) }
$passed = 0

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Invoke-Script([string]$Script, [string[]]$Arguments, [bool]$Success) {
    $output = & pwsh -NoProfile -File $Script @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    Assert-That (($code -eq 0) -eq $Success) "unexpected exit $code`: $output"
}
function Pass([string]$Name) {
    $script:passed++
    Write-Output "PASS: $Name"
}
function Package-Names {
    @("Rimmerge-$version-linux-x64-portable.tar.gz", "rimmerge-cli-$version-x86_64-unknown-linux-gnu.tar.gz", "Rimmerge_${version}_amd64.deb", "Rimmerge_${version}_amd64.AppImage")
}

try {
    New-Item -ItemType Directory -Force -Path $mockBin, (Join-Path $target 'bundle/deb'), (Join-Path $target 'bundle/appimage') | Out-Null
    Set-Content (Join-Path $target 'rimmerge-desktop') 'synthetic desktop'
    Set-Content (Join-Path $target 'rimmerge') 'synthetic cli'
    $env:RIMMERGE_TEST_DEB = Join-Path $target "bundle/deb/Rimmerge_${version}_amd64.deb"
    Set-Content $env:RIMMERGE_TEST_DEB 'synthetic deb'
    Set-Content (Join-Path $target "bundle/appimage/Rimmerge_${version}_amd64.AppImage") 'synthetic appimage'
    $env:RIMMERGE_TEST_TAR_COUNT = Join-Path $scratch 'tar-count'
    $tarMock = @'
#!/bin/sh
n=$(cat "$RIMMERGE_TEST_TAR_COUNT")
n=$((n + 1))
printf '%s' "$n" > "$RIMMERGE_TEST_TAR_COUNT"
if { [ "$RIMMERGE_TEST_TAR_MODE" = first ] && [ "$n" = 1 ]; } || { [ "$RIMMERGE_TEST_TAR_MODE" = second ] && [ "$n" = 2 ]; }; then
  printf partial > "$2"
  exit 42
fi
if [ "$RIMMERGE_TEST_TAR_MODE" = silent ] && [ "$n" = 1 ]; then exit 0; fi
if [ "$RIMMERGE_TEST_TAR_MODE" = missing-deb ] && [ "$n" = 2 ]; then mv "$RIMMERGE_TEST_DEB" "$RIMMERGE_TEST_DEB.removed"; fi
exec __TAR__ "$@"
'@
    $chmodMock = @'
#!/bin/sh
if [ "$RIMMERGE_TEST_CHMOD_FAIL" = yes ]; then exit 43; fi
exec __CHMOD__ "$@"
'@
    Set-Content (Join-Path $mockBin 'tar') ($tarMock.Replace('__TAR__', $realTar)) -Encoding utf8NoBOM
    Set-Content (Join-Path $mockBin 'chmod') ($chmodMock.Replace('__CHMOD__', $realChmod)) -Encoding utf8NoBOM
    & $realChmod '+x' (Join-Path $mockBin 'tar') (Join-Path $mockBin 'chmod')
    Assert-That ($LASTEXITCODE -eq 0) 'mock setup chmod failed'
    $env:PATH = "$mockBin`:$savedPath"

    foreach ($mode in @('first', 'second', 'silent', 'missing-deb', 'chmod')) {
        Set-Content $env:RIMMERGE_TEST_TAR_COUNT '0'
        $env:RIMMERGE_TEST_TAR_MODE = $mode
        $env:RIMMERGE_TEST_CHMOD_FAIL = if ($mode -eq 'chmod') { 'yes' } else { 'no' }
        $out = Join-Path $scratch "failure-$mode"
        New-Item -ItemType Directory -Path $out | Out-Null
        Set-Content (Join-Path $out 'unrelated.txt') 'keep'
        Invoke-Script $package @('-Version', $version, '-TargetDir', $target, '-OutDir', $out) $false
        foreach ($name in (Package-Names)) { Assert-That (-not (Test-Path (Join-Path $out $name))) "partial output remains: $name" }
        Assert-That ((Get-Content (Join-Path $out 'unrelated.txt')) -eq 'keep') 'unrelated file removed'
        if (Test-Path "$($env:RIMMERGE_TEST_DEB).removed") { Move-Item "$($env:RIMMERGE_TEST_DEB).removed" $env:RIMMERGE_TEST_DEB }
        Pass "packaging failure $mode rejects success and cleans partial outputs"
    }

    $env:RIMMERGE_TEST_CHMOD_FAIL = 'no'
    $env:RIMMERGE_TEST_TAR_MODE = 'success'
    Set-Content $env:RIMMERGE_TEST_TAR_COUNT '0'
    $out = Join-Path $scratch 'success'
    Invoke-Script $package @('-Version', $version, '-TargetDir', $target, '-OutDir', $out) $true
    Assert-That (@(Get-ChildItem $out -File).Count -eq 4) 'expected all four Linux packages'
    $extract = Join-Path $scratch 'extract'
    New-Item -ItemType Directory -Path $extract | Out-Null
    & $realTar '-xzf' (Join-Path $out "Rimmerge-$version-linux-x64-portable.tar.gz") '-C' $extract
    Assert-That ($LASTEXITCODE -eq 0) 'portable extraction failed'
    $portable = Join-Path $extract "Rimmerge-$version-linux-x64-portable"
    Assert-That ((Get-Content (Join-Path $portable 'Rimmerge')) -eq 'synthetic desktop') 'desktop payload changed'
    foreach ($name in @('Rimmerge', 'cli/rimmerge')) {
        Assert-That (([int][System.IO.File]::GetUnixFileMode((Join-Path $portable $name)) -band 0x49) -ne 0) "missing execute permission: $name"
    }
    foreach ($license in @('LICENSE-MIT', 'LICENSE-APACHE')) {
        Assert-That ((Get-FileHash (Join-Path $portable $license)).Hash -eq (Get-FileHash (Join-Path $repoRoot $license)).Hash) "license differs: $license"
    }
    Assert-That (-not ((Get-Content (Join-Path $portable 'README.txt') -Raw).Contains('\x27'))) 'README contains an escaped apostrophe'
    & $realTar '-xzf' (Join-Path $out "rimmerge-cli-$version-x86_64-unknown-linux-gnu.tar.gz") '-C' $extract
    Assert-That ($LASTEXITCODE -eq 0) 'CLI extraction failed'
    Assert-That (([int][System.IO.File]::GetUnixFileMode((Join-Path $extract 'rimmerge')) -band 0x49) -ne 0) 'CLI tarball lost execute permission'
    Pass 'four Linux packages; tar contents, licenses and executable permissions'

    Invoke-Script $package @('-Version', $version, '-TargetDir', $target, '-OutDir', (Join-Path $target 'bundle/deb')) $false
    Assert-That (Test-Path $env:RIMMERGE_TEST_DEB -PathType Leaf) 'input alias deleted source deb'
    Pass 'output alias cannot delete source packages'

    $artifacts = Join-Path $scratch 'artifacts'
    $names = @(
        "zips-windows/Rimmerge-$version-windows-x64-portable.zip",
        "zips-windows/rimmerge-cli-$version-x86_64-pc-windows-msvc.zip"
    ) + @((Package-Names) | ForEach-Object { "zips-linux/$_" })
    foreach ($name in $names) {
        $file = Join-Path $artifacts $name
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        Set-Content $file "synthetic $name"
    }
    foreach ($name in $names) {
        $file = Join-Path $artifacts $name
        Move-Item $file "$file.removed"
        $release = Join-Path $scratch ('missing-' + [guid]::NewGuid().ToString('N'))
        Invoke-Script $collect @('-Version', $version, '-ArtifactDir', $artifacts, '-OutDir', $release) $false
        Assert-That (-not (Test-Path (Join-Path $release 'SHA256SUMS.txt'))) 'checksums generated with a missing artifact'
        Move-Item "$file.removed" $file
        Pass "release collection refuses missing $name"
    }
    $empty = Join-Path $artifacts $names[-1]
    $payload = Get-Content -LiteralPath $empty -Raw
    [System.IO.File]::WriteAllText($empty, '')
    $emptyOut = Join-Path $scratch 'empty-release'
    Invoke-Script $collect @('-Version', $version, '-ArtifactDir', $artifacts, '-OutDir', $emptyOut) $false
    Assert-That (-not (Test-Path (Join-Path $emptyOut 'SHA256SUMS.txt'))) 'empty artifact accepted'
    Set-Content -LiteralPath $empty -Value $payload
    Pass 'release collection refuses empty artifacts'

    # Inject an I/O failure after the first copy, in a separate process.
    $wrapper = Join-Path $scratch 'copy-failure.ps1'
    Set-Content -LiteralPath $wrapper -Encoding utf8NoBOM -Value @'
param($Collector, $Version, $ArtifactDir, $OutDir)
$ErrorActionPreference = 'Stop'
$script:copies = 0
function Copy-Item {
    param($LiteralPath, $Destination, [switch]$Force)
    $script:copies++
    if ($script:copies -eq 2) { throw 'synthetic copy failure' }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
& $Collector -Version $Version -ArtifactDir $ArtifactDir -OutDir $OutDir
'@
    $failedRelease = Join-Path $scratch 'copy-failed-release'
    New-Item -ItemType Directory -Path $failedRelease | Out-Null
    Set-Content (Join-Path $failedRelease 'unrelated.txt') 'keep'
    Invoke-Script $wrapper @('-Collector', $collect, '-Version', $version, '-ArtifactDir', $artifacts, '-OutDir', $failedRelease) $false
    Assert-That (@(Get-ChildItem $failedRelease -File).Count -eq 1) 'partial release outputs remain'
    Assert-That ((Get-Content (Join-Path $failedRelease 'unrelated.txt')) -eq 'keep') 'unrelated release file removed'
    Pass 'release copy failure cleans artifacts and checksums without deleting unrelated files'

    $release = Join-Path $scratch 'release'
    Invoke-Script $collect @('-Version', $version, '-ArtifactDir', $artifacts, '-OutDir', $release) $true
    Assert-That (@(Get-ChildItem $release -File).Count -eq 7) 'expected six artifacts plus checksums'
    Push-Location $release
    try {
        & $sha256sum '-c' 'SHA256SUMS.txt'
        Assert-That ($LASTEXITCODE -eq 0) 'checksum verification failed'
    } finally { Pop-Location }
    Pass 'all six release artifacts copied and independently verified with sha256sum'
    Write-Output "Summary: $passed packaging checks passed"
}
finally {
    $env:PATH = $savedPath
    foreach ($name in $testVariables) { [Environment]::SetEnvironmentVariable($name, $savedVariables[$name]) }
    if (Test-Path $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

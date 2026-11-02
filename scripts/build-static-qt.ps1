[CmdletBinding()]
param(
    [string]$QtVersion = "",
    [Parameter(Mandatory = $true)][string]$InstallPrefix,
    [string]$SourceDirectory = "",
    [string]$BuildDirectory = "",
    [string]$DependencyPrefix = "",
    [ValidateSet("x64", "arm64")][string]$Architecture = "x64",
    [string]$HostQtPrefix = "",
    [ValidateSet("Debug", "Release")][string]$Configuration = "Release",
    [string]$QtMirrorBaseUrl = "https://qt.mirror.constant.com/official_releases",
    [ValidateRange(1, 256)][int]$Parallelism = 4,
    [ValidateSet("Auto", "Ninja", "NMake Makefiles", "Visual Studio 18 2026")][string]$CmakeGenerator = "Auto",
    [switch]$DevelopmentModules,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
. (Join-Path $PSScriptRoot "snow-build-environment.ps1")
if ([string]::IsNullOrWhiteSpace($QtVersion)) { $QtVersion = $script:SnowQtVersion }
if ($QtVersion -cne $script:SnowQtVersion) {
    throw "The audited Qt toolchain requires Qt $script:SnowQtVersion, requested $QtVersion."
}
$hostArchitecture = Get-SnowWindowsHostArchitecture
$crossCompilation = $Architecture -cne $hostArchitecture
if ($crossCompilation) { $HostQtPrefix = Resolve-SnowQtHostPrefix -HostQtPrefix $HostQtPrefix }
else { $HostQtPrefix = "" }
Add-SnowMsvcToolsToPath -Architecture $Architecture | Out-Null
$enableDevelopmentModules = $DevelopmentModules -or $Configuration -eq "Debug"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = (Get-Location).Path
    )

    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed ($LASTEXITCODE): $Command $($Arguments -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-NinjaProgram {
    $command = Get-Command "ninja.exe" -ErrorAction SilentlyContinue
    $candidates = @(@(
            $(if ($command) { $command.Source }),
            $(if (-not [string]::IsNullOrWhiteSpace($env:VSINSTALLDIR)) {
                Join-Path $env:VSINSTALLDIR `
                    "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
            })
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            ForEach-Object { [System.IO.Path]::GetFullPath([string]$_) } |
            Select-Object -Unique)
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return ""
}

function Get-CMakeGeneratorCandidates {
    # Ordered by preference. Ninja is Qt's officially supported generator and the fastest; the
    # Visual Studio generator writes .sln/.vcxproj and shares no generated include chain with the
    # Makefile-style generators, so it survives hosts where Ninja/NMake lose their
    # CMakeFiles payload; NMake is the last resort.
    param([Parameter(Mandatory = $true)]
        [ValidateSet("Auto", "Ninja", "NMake Makefiles", "Visual Studio 18 2026")][string]$Preference)

    $ninja = Get-NinjaProgram
    $nmake = Get-Command "nmake.exe" -ErrorAction SilentlyContinue
    $nmakeProgram = if ($nmake) { [System.IO.Path]::GetFullPath($nmake.Source) } else { "" }
    $visualStudio = [pscustomobject]@{ Name = "Visual Studio 18 2026"; Program = "" }

    switch ($Preference) {
        "Ninja" {
            if (-not $ninja) {
                throw ("Ninja was not found. Visual Studio ships one under " +
                    "'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'.")
            }
            return @([pscustomobject]@{ Name = "Ninja"; Program = $ninja })
        }
        "NMake Makefiles" {
            if (-not $nmakeProgram) { throw "nmake.exe was not found on PATH." }
            return @([pscustomobject]@{ Name = "NMake Makefiles"; Program = $nmakeProgram })
        }
        "Visual Studio 18 2026" {
            return @($visualStudio)
        }
        default {
            $candidates = @()
            if ($ninja) {
                $candidates += [pscustomobject]@{ Name = "Ninja"; Program = $ninja }
            }
            $candidates += $visualStudio
            if ($nmakeProgram) {
                $candidates += [pscustomobject]@{ Name = "NMake Makefiles"; Program = $nmakeProgram }
            }
            return $candidates
        }
    }
}

function Get-NormalizedDirectoryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -eq $rootPath) {
        return $rootPath
    }
    return $fullPath.TrimEnd([char[]]@('\', '/'))
}

function Test-PathIsSameOrDescendant {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $normalizedPath = Get-NormalizedDirectoryPath -Path $Path
    $normalizedParent = Get-NormalizedDirectoryPath -Path $Parent
    if ($normalizedPath.Equals(
            $normalizedParent,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $parentPrefix = $normalizedParent
    if (-not $parentPrefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $parentPrefix += [System.IO.Path]::DirectorySeparatorChar
    }
    return $normalizedPath.StartsWith(
        $parentPrefix,
        [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeRecursiveRemovalTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $normalizedPath = Get-NormalizedDirectoryPath -Path $Path
    $rootPath = Get-NormalizedDirectoryPath -Path (
        [System.IO.Path]::GetPathRoot($normalizedPath))
    if ($normalizedPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description cannot be a filesystem root: $normalizedPath"
    }

    $protectedPaths = @(
        $repoRoot,
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData),
        [System.IO.Path]::GetTempPath()
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($protectedPath in $protectedPaths) {
        if (Test-PathIsSameOrDescendant -Path $protectedPath -Parent $normalizedPath) {
            throw "$Description cannot be a protected path or one of its ancestors: $normalizedPath"
        }
    }
}

function Assert-QtDirectoryIsolation {
    param([Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Build,
        [Parameter(Mandatory = $true)][string]$Install,
        [string]$HostPrefix = '')
    $directories = [ordered]@{ Source = $Source; Build = $Build; Install = $Install }
    if ($HostPrefix) { $directories.Host = $HostPrefix }
    $names = @($directories.Keys)
    for ($left = 0; $left -lt $names.Count; $left++) {
        for ($right = $left + 1; $right -lt $names.Count; $right++) {
            $leftPath = $directories[$names[$left]]
            $rightPath = $directories[$names[$right]]
            if ((Test-PathIsSameOrDescendant -Path $leftPath -Parent $rightPath) -or
                (Test-PathIsSameOrDescendant -Path $rightPath -Parent $leftPath)) {
                throw "Qt $($names[$left]) and $($names[$right]) directories must be distinct and non-overlapping: '$leftPath', '$rightPath'."
            }
        }
    }
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromHours(2)
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        Write-Output "Downloading $Uri"
        $response = $client.GetAsync(
            $Uri,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode()
        $contentLength = $response.Content.Headers.ContentLength
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $buffer = [byte[]]::new(1024 * 1024)
        $downloaded = [int64]0
        $lastLog = [DateTime]::UtcNow
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $downloaded += $read
            $now = [DateTime]::UtcNow
            if (($now - $lastLog).TotalSeconds -ge 2) {
                $downloadedMiB = [math]::Round($downloaded / 1MB, 1)
                if ($contentLength) {
                    $percent = [math]::Round(($downloaded * 100.0) / $contentLength, 1)
                    $totalMiB = [math]::Round($contentLength / 1MB, 1)
                    Write-Progress -Activity "Downloading Qt $QtVersion sources" `
                        -Status "$downloadedMiB / $totalMiB MiB ($percent%)" `
                        -PercentComplete $percent
                    Write-Output "Qt source download: $downloadedMiB / $totalMiB MiB ($percent%)"
                }
                else {
                    Write-Progress -Activity "Downloading Qt $QtVersion sources" `
                        -Status "$downloadedMiB MiB received"
                    Write-Output "Qt source download: $downloadedMiB MiB received"
                }
                $lastLog = $now
            }
        }
        Write-Progress -Activity "Downloading Qt $QtVersion sources" -Completed
        Write-Output "Qt source download complete: $([math]::Round($downloaded / 1MB, 1)) MiB"
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
}

function Get-DependencyFingerprint {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    $abiFiles = @(
        (Join-Path $Prefix "share\zlib\vcpkg_abi_info.txt"),
        (Join-Path $Prefix "share\libpng\vcpkg_abi_info.txt")
    )
    foreach ($abiFile in $abiFiles) {
        if (-not (Test-Path -LiteralPath $abiFile -PathType Leaf)) {
            throw "The static Qt dependency package is incomplete: $abiFile"
        }
    }
    $fingerprintText = ($abiFiles | ForEach-Object {
        "$([System.IO.Path]::GetFileName((Split-Path -Parent $_))):$((Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash)"
    }) -join "|"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintText)
    return [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

function Assert-QtDependencyArchitecture {
    param([Parameter(Mandatory = $true)][string]$Prefix,
        [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64')

    # The pinned zlib-ng port names its static MSVC library zlibstatic.lib.
    foreach ($library in @('zlibstatic.lib', 'libpng16.lib')) {
        if (-not (Test-SnowWindowsLibraryArchitecture -Path (Join-Path $Prefix "lib/$library") `
                -Architecture $Architecture)) {
            throw "Static Qt dependency $library does not match target architecture $Architecture."
        }
    }
}

function Assert-QtSourceArchive {
    param([Parameter(Mandatory = $true)][string]$Path)

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $script:SnowQtToolchain.sourceArchiveSha256) {
        $message = "Qt $($script:SnowQtVersion) source archive SHA256 mismatch: $Path" +
            " (expected $($script:SnowQtToolchain.sourceArchiveSha256), got $actualHash)"
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw $message
    }
}

function Expand-QtSourceArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    # The bsdtar shipped with Windows 10 streams .tar.xz through an `xz -d` child
    # process and deadlocks once the stream outgrows the pipe buffer, which is
    # always the case for the Qt source archive. Decompress explicitly when a
    # standalone xz is available, then hand a plain .tar to tar.
    $xz = Get-Command xz -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $xz) {
        Invoke-Checked -Command "tar" -Arguments @("-xf", $ArchivePath, "-C", $Destination)
        return
    }
    $plainArchivePath = [System.IO.Path]::ChangeExtension($ArchivePath, ".tar")
    try {
        Write-Output "Decompressing $([System.IO.Path]::GetFileName($ArchivePath)) with $($xz.Source)"
        $decompressor = Start-Process -FilePath $xz.Source `
            -ArgumentList @("-dc", $ArchivePath) `
            -RedirectStandardOutput $plainArchivePath -NoNewWindow -PassThru -Wait
        if ($decompressor.ExitCode -ne 0) {
            throw "xz exited with code $($decompressor.ExitCode) while decompressing $ArchivePath."
        }
        Invoke-Checked -Command "tar" -Arguments @("-xf", $plainArchivePath, "-C", $Destination)
    }
    finally {
        Remove-Item -LiteralPath $plainArchivePath -Force -ErrorAction SilentlyContinue
    }
}

function Test-InstalledQtSystemCodecs {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [ValidateSet("Debug", "Release")][string]$Configuration = "Release",
        [ValidateSet("x64", "arm64")][string]$Architecture = "x64"
    )

    return Test-SnowQtSystemCodecKit -Qt6Dir (Join-Path $Prefix "lib\cmake\Qt6") `
        -Configuration $Configuration -Architecture $Architecture
}

function Test-InstalledQtLicenseBundle {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    $licenseRoot = Join-Path $Prefix "share\snow-apps\qt-licenses"
    foreach ($requiredLicenseFile in @(
            "manifest.json",
            "root\REUSE.toml",
            "root\LICENSES\GPL-3.0-only.txt",
            "qtbase\REUSE.toml",
            "qtsvg\REUSE.toml",
            "qttools\REUSE.toml",
            "qttranslations\licenseRule.json",
            "qttranslations\LICENSES\GPL-3.0-only.txt")) {
        if (-not (Test-Path -LiteralPath (Join-Path $licenseRoot $requiredLicenseFile) -PathType Leaf)) {
            return $false
        }
    }
    try {
        $manifest = Get-Content -LiteralPath (Join-Path $licenseRoot "manifest.json") -Raw |
            ConvertFrom-Json
        if ($manifest.SchemaVersion -ne 1 -or $manifest.QtVersion -cne $script:SnowQtVersion -or
            $manifest.SourceArchiveSha256 -cne $script:SnowQtToolchain.sourceArchiveSha256) {
            return $false
        }
        foreach ($component in @("root", "qtbase", "qtsvg", "qttools", "qttranslations")) {
            if ($component -cnotin $manifest.Components) { return $false }
        }
    }
    catch { return $false }
    foreach ($patch in $script:SnowStaticQtSourcePatches) {
        $patchPath = Join-Path $licenseRoot "patches\$($patch.File)"
        if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                $patch.SHA256) { return $false }
    }
    return $true
}

function Install-QtSourcePatches {
    param([Parameter(Mandatory = $true)][string]$Source)

    $versionPath = Join-Path $Source "qtbase/.cmake.conf"
    $expectedVersion = [regex]::Escape($script:SnowQtVersion)
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf) -or
        (Get-Content -LiteralPath $versionPath -Raw) -notmatch
            "(?m)^set\(QT_REPO_MODULE_VERSION `"$expectedVersion`"\)\r?`$") {
        throw "The audited Qt source patches require qtbase $($script:SnowQtVersion): $versionPath"
    }
    foreach ($patch in $script:SnowStaticQtSourcePatches) {
        $patchPath = Join-Path $PSScriptRoot $patch.File
        $previousGitCeiling = $env:GIT_CEILING_DIRECTORIES
        # A source tree inside this repository must not inherit its patch root.
        $env:GIT_CEILING_DIRECTORIES = [System.IO.Path]::GetDirectoryName(
            [System.IO.Path]::GetFullPath($Source)).Replace('\', '/')
        Push-Location $Source
        try {
            & git apply --reverse --check $patchPath 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Output "Qt source patch already applied: $($patch.File)"
                continue
            }
            Invoke-Checked -Command "git" -Arguments @("apply", "--check", $patchPath) `
                -WorkingDirectory $Source
            Invoke-Checked -Command "git" -Arguments @("apply", $patchPath) `
                -WorkingDirectory $Source
        }
        finally {
            Pop-Location
            $env:GIT_CEILING_DIRECTORIES = $previousGitCeiling
        }
    }
}

function Install-QtLicenseBundle {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$SourceArchive
    )

    $licenseRoot = Join-Path $Prefix "share\snow-apps\qt-licenses"
    if (-not (Test-PathIsSameOrDescendant -Path $licenseRoot -Parent $Prefix)) {
        throw "The Qt license bundle destination escapes the install prefix: $licenseRoot"
    }
    $licenseSources = [ordered]@{
        root = $Source
        qtbase = Join-Path $Source "qtbase"
        qtsvg = Join-Path $Source "qtsvg"
        qttools = Join-Path $Source "qttools"
        qttranslations = Join-Path $Source "qttranslations"
    }
    foreach ($component in $licenseSources.Keys) {
        $componentSource = $licenseSources[$component]
        # Qt Translations retains its upstream license-rule metadata rather than REUSE.toml.
        $metadataName = if ($component -eq "qttranslations") { "licenseRule.json" } else { "REUSE.toml" }
        $metadataFile = Join-Path $componentSource $metadataName
        $licensesDirectory = Join-Path $componentSource "LICENSES"
        if (-not (Test-Path -LiteralPath $metadataFile -PathType Leaf) -or
            -not (Test-Path -LiteralPath $licensesDirectory -PathType Container)) {
            throw "Qt licensing metadata is incomplete for $component at $componentSource"
        }
    }
    # Validate every component before replacing a previously usable bundle.
    if (Test-Path -LiteralPath $licenseRoot) {
        Remove-Item -LiteralPath $licenseRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $licenseRoot -Force | Out-Null
    foreach ($component in $licenseSources.Keys) {
        $componentSource = $licenseSources[$component]
        $metadataName = if ($component -eq "qttranslations") { "licenseRule.json" } else { "REUSE.toml" }
        $componentDestination = Join-Path $licenseRoot $component
        New-Item -ItemType Directory -Path $componentDestination -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $componentSource $metadataName) -Destination $componentDestination
        Copy-Item -LiteralPath (Join-Path $componentSource "LICENSES") -Destination $componentDestination -Recurse
    }
    $patchesDirectory = Join-Path $licenseRoot "patches"
    New-Item -ItemType Directory -Path $patchesDirectory -Force | Out-Null
    foreach ($patch in $script:SnowStaticQtSourcePatches) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $patch.File) -Destination $patchesDirectory
    }

    [ordered]@{
        SchemaVersion = 1
        QtVersion = $Version
        SourceArchiveSha256 = $script:SnowQtToolchain.sourceArchiveSha256
        SourceArchive = $SourceArchive
        Components = @($licenseSources.Keys)
        SourcePatches = $script:SnowStaticQtSourcePatches
    } | ConvertTo-Json -Depth 3 | Set-Content `
        -LiteralPath (Join-Path $licenseRoot "manifest.json") -Encoding utf8
}

function Write-StaticQtBuildStamp {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$BuildConfiguration,
        [Parameter(Mandatory = $true)][string]$Fingerprint,
        [Parameter(Mandatory = $true)][string]$SourceArchive,
        [Parameter(Mandatory = $true)][int]$BuildParallelism,
        [bool]$WithDevelopmentModules = ($BuildConfiguration -eq "Debug"),
        [ValidateSet("x64", "arm64")][string]$Architecture = "x64",
        [string]$HostArchitecture = (Get-SnowWindowsHostArchitecture),
        [string]$HostQtPrefix = ""
    )

    $stampDirectory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $stampDirectory | Out-Null
    if (-not $HostQtPrefix -and $Architecture -ceq $HostArchitecture) {
        $HostQtPrefix = Split-Path -Parent (Split-Path -Parent $stampDirectory)
    }
    [ordered]@{
        SchemaVersion = $script:SnowStaticQtSchemaVersion
        QtVersion = $Version
        SourceArchiveSha256 = $script:SnowQtToolchain.sourceArchiveSha256
        Configuration = $BuildConfiguration
        Architecture = $Architecture
        HostArchitecture = $HostArchitecture
        HostQtPrefix = $HostQtPrefix
        HostTools = if ($HostQtPrefix) {
            @(foreach ($name in @("moc", "rcc", "uic", "lrelease", "lupdate")) {
                [ordered]@{ Name = "$name.exe"; SHA256 = (Get-FileHash -Algorithm SHA256 `
                    -LiteralPath (Join-Path $HostQtPrefix "bin/$name.exe")).Hash.ToLowerInvariant() }
            })
        } else { @() }
        DevelopmentModules = $WithDevelopmentModules
        DependencyFingerprint = $Fingerprint
        FeatureFingerprint = $script:SnowStaticQtFeatureFingerprint
        SourcePatches = $script:SnowStaticQtSourcePatches
        Ltcg = (Get-SnowStaticQtLtcgEnabled -Configuration $BuildConfiguration -Architecture $Architecture)
        SystemPng = ($BuildConfiguration -eq "Release")
        SystemZlib = ($BuildConfiguration -eq "Release")
        Timezone = $true
        TimezoneLocale = $false
        LicenseBundle = "share/snow-apps/qt-licenses"
        SourceArchive = $SourceArchive
        Submodules = @("qtbase", "qtsvg", "qttools", "qttranslations")
        SkippedSubmodules = @(
            "qtactiveqt",
            "qtdeclarative",
            "qtimageformats",
            "qtlanguageserver",
            "qtshadertools"
        )
        DisabledFeatures = @(
            "androiddeployqt",
            "dbus",
            "dynamicgl",
            "opengl",
            "opengl_dynamic",
            "printsupport",
            "qdoc",
            "qmake",
            "sql",
            "testlib",
            "timezone_locale",
            "wasmdeployqt",
            "windeployqt"
        ) | Where-Object { $_ -ne "testlib" -or -not $WithDevelopmentModules }
        Parallelism = $BuildParallelism
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Assert-CacheEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Cache,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if ($Cache -notmatch $Pattern) {
        throw "Qt configuration does not satisfy $Description."
    }
}

function Get-ProbeTreeSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxEntries = 60
    )

    $summary = @()
    $entries = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            Select-Object -First $MaxEntries)
    foreach ($entry in $entries) {
        $relative = $entry.FullName.Substring([Math]::Min($Path.Length + 1, $entry.FullName.Length))
        if ($entry.PSIsContainer) {
            $summary += "  dir  $relative"
        }
        else {
            $summary += ("  file {0,8}  {1}" -f $entry.Length, $relative)
        }
    }
    if ($entries.Count -ge $MaxEntries) {
        $summary += "  ... (truncated)"
    }
    return $summary
}

function Test-AtomicFileReplaceSupport {
    # CMake lands rules.ninja and InstallScripts.json by writing "name.tmp" and renaming it into
    # place (so an unchanged file keeps its mtime and nothing rebuilds), and it silently keeps
    # nothing when that rename fails. Reproduce exactly that sequence, so a filesystem filter
    # (antivirus, DLP encryption, a sync client) shows up as a plain boolean instead of a file
    # that is mysteriously absent from CMake's own scratch directory.
    param([Parameter(Mandatory = $true)][string]$Directory)

    $probeDirectory = Join-Path $Directory ("atomic-replace-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $result = [ordered]@{
        Directory = $probeDirectory
        CreateTemp = $false
        RenameIntoTarget = $false
        ReplaceExisting = $false
        SurvivesDwell = $false
        Error = ""
    }
    try {
        New-Item -ItemType Directory -Force -Path $probeDirectory | Out-Null
        $tempPath = Join-Path $probeDirectory "rules.ninja.tmp"
        $targetPath = Join-Path $probeDirectory "rules.ninja"
        # Realistic ninja rule text rather than a two-word file: a scanner that treats build-rule
        # content differently only shows up if the payload looks like what CMake writes.
        $sample = (@(
                "# CMAKE generated file: DO NOT EDIT!"
                "# Generated by `"Ninja`" Generator, CMake Version 4.4"
                "rule CXX_COMPILER__snow_cmake_generator_probe_unscanned_Release"
                "  command = $($env:VCToolsInstallDir)bin\Hostx64\x64\cl.exe /nologo /TP /Fo CMakeFiles\snow_cmake_generator_probe.dir\main.cpp.obj /Fd CMakeFiles\snow_cmake_generator_probe.dir\ /FS -c main.cpp"
                "  description = Building CXX object CMakeFiles/snow_cmake_generator_probe.dir/main.cpp.obj"
                "  deps = msvc"
                "rule CXX_EXECUTABLE_LINKER__snow_cmake_generator_probe_Release"
                "  command = $($env:VCToolsInstallDir)bin\Hostx64\x64\link.exe /nologo @CMakeFiles\snow_cmake_generator_probe.dir\objects1.rsp /out:snow_cmake_generator_probe.exe /implib:snow_cmake_generator_probe.lib /pdb:snow_cmake_generator_probe.pdb /machine:x64 /INCREMENTAL:NO /subsystem:console"
                "  description = Linking CXX executable snow_cmake_generator_probe.exe"
            ) -join "`r`n")
        $sample = $sample + ("`r`n# " + ("padding " * 260))
        Set-Content -LiteralPath $tempPath -Value $sample -Encoding utf8
        $result.CreateTemp = Test-Path -LiteralPath $tempPath
        [System.IO.File]::Move($tempPath, $targetPath)
        $result.RenameIntoTarget = (Test-Path -LiteralPath $targetPath) -and
            ((Get-Item -LiteralPath $targetPath).Length -gt 1000)
        Set-Content -LiteralPath $tempPath -Value ($sample + "`r`n# second") -Encoding utf8
        [System.IO.File]::Move($tempPath, $targetPath, $true)
        $result.ReplaceExisting = (Get-Item -LiteralPath $targetPath).Length -gt 1000
        # A real-time scanner acts shortly after the file appears, so give it the chance to swallow
        # the file and check again: a build-rule file full of cl.exe/link.exe command lines is
        # exactly the shape some engines quarantine.
        Start-Sleep -Milliseconds 600
        $result.SurvivesDwell = (Test-Path -LiteralPath $targetPath -PathType Leaf) -and
            ((Get-Item -LiteralPath $targetPath).Length -gt 1000)
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    # Leave the directory as it was found.
    foreach ($created in @($tempPath, $targetPath)) {
        if ($created -and (Test-Path -LiteralPath $created -PathType Leaf)) {
            Remove-Item -LiteralPath $created -Force -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]$result
}

function Get-AlternativeCMakeCandidates {
    param([Parameter(Mandatory = $true)][string]$CurrentCMake)

    # The cmake from Scoop and the one bundled with Visual Studio are independent builds of
    # different versions. When one of them cannot generate a build system on a host, the other
    # very often can, so both are tried before giving up.
    $candidates = @(
        $(if (-not [string]::IsNullOrWhiteSpace($env:VSINSTALLDIR)) {
            Join-Path $env:VSINSTALLDIR `
                "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
        })
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        ForEach-Object { [System.IO.Path]::GetFullPath([string]$_) } |
        Where-Object { -not $_.Equals($CurrentCMake, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -Unique
    return @($candidates)
}

function Invoke-CMakeGeneratorProbe {
    param(
        [Parameter(Mandatory = $true)][string]$CMakeCommand,
        [Parameter(Mandatory = $true)][string]$ProbeDirectory,
        [Parameter(Mandatory = $true)]$Generator,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $probeSource = Join-Path $ProbeDirectory "src"
    $probeBuild = Join-Path $ProbeDirectory "build"
    New-Item -ItemType Directory -Force -Path $probeSource | Out-Null
    Set-Content -LiteralPath (Join-Path $probeSource "CMakeLists.txt") -Encoding utf8 -Value @(
        "cmake_minimum_required(VERSION 3.21)"
        "project(snow_cmake_generator_probe CXX)"
        "add_executable(snow_cmake_generator_probe main.cpp)"
    )
    Set-Content -LiteralPath (Join-Path $probeSource "main.cpp") -Encoding utf8 `
        -Value "int main() { return 0; }"

    $probeArguments = @(
        # --debug-trycompile keeps the nested try-compile project on disk. That nested project is
        # exactly whose CMakeFiles payload goes missing when this probe fails, and CMake deletes it
        # once the try_compile returns, leaving nothing to look at.
        "--debug-trycompile",
        "-S", $probeSource,
        "-B", $probeBuild,
        "-G", $Generator.Name,
        "-DCMAKE_BUILD_TYPE=$Configuration",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"
    )
    if ($Generator.Program) {
        $probeArguments += "-DCMAKE_MAKE_PROGRAM=$($Generator.Program)"
    }
    if ($Generator.Name -like "Visual Studio*") {
        # The project's own presets select the same architecture and host toolset; without them
        # the Visual Studio generator reports "No CMAKE_CXX_COMPILER could be found".
        $visualStudioArchitecture = if ($Architecture -eq "arm64") { "ARM64" } else { "x64" }
        $probeArguments += @("-A", $visualStudioArchitecture, "-T", "host=x64")
        if (-not [string]::IsNullOrWhiteSpace($env:VSINSTALLDIR)) {
            $probeArguments += "-DCMAKE_GENERATOR_INSTANCE=$env:VSINSTALLDIR"
        }
    }
    & $CMakeCommand @probeArguments *> $LogPath
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    & $CMakeCommand "--build" $probeBuild "--config" $Configuration *>> $LogPath
    return ($LASTEXITCODE -eq 0)
}

function Select-CMakeGenerator {
    # Runs a three-line C++ project through every candidate generator and cmake build, in
    # preference order, and returns the first combination that both configures and builds.
    # That is what makes this script survive a host where one generator cannot produce a usable
    # build system (the symptom is 'CMakeFiles\rules.ninja' or 'CMakeFiles\cmTC_*.dir\build.make'
    # reported missing), and it turns a three-minute Qt configure failure into a ten-second probe.
    param(
        [Parameter(Mandatory = $true)][string]$BuildDirectory,
        [Parameter(Mandatory = $true)][string]$Preference
    )

    $generators = @(Get-CMakeGeneratorCandidates -Preference $Preference)
    $probeRoot = Join-Path $BuildDirectory ".cmake-generator-probe"
    if (Test-Path -LiteralPath $probeRoot) {
        Remove-Item -LiteralPath $probeRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null

    $primaryCMake = [System.IO.Path]::GetFullPath((Get-Command cmake).Source)
    $cmakes = @($primaryCMake) + @(Get-AlternativeCMakeCandidates -CurrentCMake $primaryCMake)

    $results = @()
    $index = 0
    foreach ($generator in $generators) {
        foreach ($cmake in $cmakes) {
            $index++
            $name = "attempt{0}" -f $index
            $probeDirectory = Join-Path $probeRoot $name
            $logPath = Join-Path $probeRoot "$name.log"
            # Put this cmake first on PATH for its own attempt: CMake re-enters itself for some
            # nested steps by name, so an attempt is only representative if its own bin directory
            # wins the lookup.
            $env:Path = "$(Split-Path -Parent $cmake);$env:Path"
            $succeeded = $false
            try {
                $succeeded = Invoke-CMakeGeneratorProbe -CMakeCommand $cmake `
                    -ProbeDirectory $probeDirectory -Generator $generator -LogPath $logPath
            }
            catch {
                Add-Content -LiteralPath $logPath -Value $_.Exception.Message `
                    -Encoding utf8 -ErrorAction SilentlyContinue
            }
            $results += [pscustomobject]@{
                Name = $name
                Generator = $generator
                CMake = $cmake
                Directory = $probeDirectory
                Log = $logPath
                Succeeded = $succeeded
            }
            if ($succeeded) {
                Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
                return $generator
            }
        }
    }

    $report = @(
        "No available cmake can configure and build a three-line C++ program with any of the " +
        "tried generators: $(($generators | ForEach-Object { $_.Name }) -join ', ').",
        "The same failure shows up inside Qt as 'CMakeFiles\rules.ninja' or " +
        "'CMakeFiles\cmTC_*.dir\build.make' not found, so this has to be fixed first.",
        "",
        "Attempts:"
    )
    foreach ($result in $results) {
        $report += "  $($result.Name): $($result.Generator.Name) via $($result.CMake)"
    }
    $report += ""
    $report += "Probe root: $probeRoot"
    $report += ""
    $report += "Environment variables that change how CMake drives the toolchain:"
    foreach ($name in @("CMAKE_GENERATOR", "CMAKE_MAKE_PROGRAM", "CMAKE_ROOT", "CMAKE_PREFIX_PATH",
            "CMAKE_TOOLCHAIN_FILE", "NINJA", "NINJA_STATUS", "MAKE", "MAKEFLAGS", "CL", "_CL_",
            "TMP", "TEMP", "VSLANG", "INCLUDE", "LIB", "VCINSTALLDIR", "VSINSTALLDIR")) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) {
            $report += ("  {0}={1}" -f $name, $value)
        }
    }
    $pathEntries = @($env:Path -split ";" | Where-Object { $_ })
    $report += ("  Path entries: {0}; first three: {1}" -f $pathEntries.Count,
        (($pathEntries | Select-Object -First 3) -join " | "))

    $atomicWrite = Test-AtomicFileReplaceSupport -Directory $probeRoot
    $report += ""
    $report += "Atomic write test (the temp-file + rename that CMake uses for rules.ninja):"
    $report += ("  create name.tmp: {0}; rename into place: {1}; replace existing file: {2}; " +
        "still there after 600 ms: {3}" -f $atomicWrite.CreateTemp, $atomicWrite.RenameIntoTarget,
        $atomicWrite.ReplaceExisting, $atomicWrite.SurvivesDwell)
    if ($atomicWrite.Error) {
        $report += ("  error: " + $atomicWrite.Error)
    }
    if (-not ($atomicWrite.CreateTemp -and $atomicWrite.RenameIntoTarget -and
            $atomicWrite.ReplaceExisting -and $atomicWrite.SurvivesDwell)) {
        $report += ("  => Something on this machine blocks the rename that CMake relies on. Add an " +
            "exclusion for $BuildDirectory (and the Qt source directory) in the antivirus, DLP or " +
            "sync client, or build on a volume that is not filtered, then rerun.")
    }
    else {
        $report += ("  The rename itself works here, so the loss happens somewhere else; the tree " +
            "below is the primary evidence.")
    }

    $fileSystemFilters = @()
    $servicesKey = "HKLM:\SYSTEM\CurrentControlSet\Services"
    if (Test-Path -LiteralPath $servicesKey) {
        $fileSystemFilters = @(Get-ChildItem -LiteralPath $servicesKey -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $properties = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                    if (-not $properties) { return }
                    $typeProperty = $properties.PSObject.Properties["Type"]
                    $groupProperty = $properties.PSObject.Properties["Group"]
                    $displayProperty = $properties.PSObject.Properties["DisplayName"]
                    if (-not $typeProperty -or -not $groupProperty) { return }
                    if ($typeProperty.Value -ne 2 -or "$($groupProperty.Value)" -notlike "FSFilter*") {
                        return
                    }
                    $display = if ($displayProperty) { $displayProperty.Value } else { "" }
                    "{0}  [{1}]  {2}" -f $_.PSChildName, $groupProperty.Value, $display
                } | Sort-Object)
    }
    $report += ""
    $report += "Filesystem filter drivers loaded on this machine (the suspects when writes vanish):"
    if ($fileSystemFilters.Count -gt 0) {
        $report += @($fileSystemFilters | Select-Object -First 30 | ForEach-Object { "  $_" })
    }
    else {
        $report += "  (none could be enumerated)"
    }

    foreach ($result in $results) {
        $report += ""
        $report += "=== $($result.Name): $($result.Generator.Name) via $($result.CMake) ==="
        $probeBuild = Join-Path $result.Directory "build"
        if (Test-Path -LiteralPath (Join-Path $probeBuild "CMakeFiles") -PathType Container) {
            $report += "The probe build tree does contain a CMakeFiles directory."
        }
        else {
            $report += "The probe build tree has NO CMakeFiles directory."
        }
        $scratchRoot = Join-Path $probeBuild "CMakeFiles\CMakeScratch"
        $scratchProjects = @()
        if (Test-Path -LiteralPath $scratchRoot -PathType Container) {
            $scratchProjects = @(Get-ChildItem -LiteralPath $scratchRoot -Directory -Force `
                    -ErrorAction SilentlyContinue)
        }
        if ($scratchProjects.Count -gt 0) {
            $report += "Kept try-compile project(s):"
            foreach ($project in $scratchProjects) {
                $report += "  $($project.Name)"
                $rulesFile = Join-Path $project.FullName "CMakeFiles\rules.ninja"
                if ($result.Generator.Name -eq "Ninja") {
                    if (Test-Path -LiteralPath $rulesFile -PathType Leaf) {
                        $report += "  CMakeFiles\rules.ninja IS present in this project."
                    }
                    else {
                        $report += ("  CMakeFiles\rules.ninja is MISSING from this project, while " +
                            "build.ninja (which includes it) is there.")
                        $scratchCMakeFiles = Split-Path -Parent $rulesFile
                        $report += ("  Leftover temp files in that directory: " + (@(
                                    Get-ChildItem -LiteralPath $scratchCMakeFiles -Force `
                                        -Filter "rules.ninja*" -ErrorAction SilentlyContinue |
                                        ForEach-Object { $_.Name }) -join ", "))
                        if (Test-Path -LiteralPath $scratchCMakeFiles -PathType Container) {
                            try {
                                $acl = Get-Acl -LiteralPath $scratchCMakeFiles
                                $report += ("  ACL owner: {0}; rules: {1}" -f $acl.Owner,
                                    (($acl.Access | Select-Object -First 6 |
                                            ForEach-Object { "$($_.IdentityReference):$($_.FileSystemRights):$($_.AccessControlType)" }) -join " | "))
                            }
                            catch {
                                $report += ("  ACL could not be read: " + $_.Exception.Message)
                            }
                            $insideTest = Test-AtomicFileReplaceSupport -Directory $scratchCMakeFiles
                            $report += ("  Same atomic write test inside {0}:" -f $scratchCMakeFiles)
                            $report += ("    create rules.ninja.tmp: {0}; rename to rules.ninja: {1}; " +
                                "replace it: {2}; still there after 600 ms: {3}" -f
                                $insideTest.CreateTemp, $insideTest.RenameIntoTarget,
                                $insideTest.ReplaceExisting, $insideTest.SurvivesDwell)
                            if ($insideTest.Error) {
                                $report += ("    error: " + $insideTest.Error)
                            }
                        }
                    }
                }
                $report += Get-ProbeTreeSummary -Path $project.FullName -MaxEntries 60
            }
        }
        else {
            $report += "No try-compile project survived; the scratch directory is empty."
        }
        $report += "Probe tree:"
        $report += Get-ProbeTreeSummary -Path $result.Directory -MaxEntries 60
        if (Test-Path -LiteralPath $result.Log -PathType Leaf) {
            $report += "Log head:"
            $report += @(Get-Content -LiteralPath $result.Log -TotalCount 20 | ForEach-Object { "  $_" })
            $report += "Log tail:"
            $report += @(Get-Content -LiteralPath $result.Log -Tail 20 | ForEach-Object { "  $_" })
        }
    }
    throw ($report -join [Environment]::NewLine)
}

if ([string]::IsNullOrWhiteSpace($DependencyPrefix)) {
    $releaseTarget = Get-SnowWindowsTarget -Architecture $Architecture
    $DependencyPrefix = Join-Path $releaseTarget.InstalledRoot $releaseTarget.Triplet
}
$dependencyPrefix = [System.IO.Path]::GetFullPath($DependencyPrefix)
foreach ($requiredDependencyFile in @(
        "include\zlib.h",
        "include\png.h",
        "share\zlib\zlib-config.cmake",
        "share\libpng\libpng-config.cmake")) {
    $requiredPath = Join-Path $dependencyPrefix $requiredDependencyFile
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Static Qt requires the release static vcpkg PNG/zlib packages: $requiredPath"
    }
}
$dependencyFingerprint = Get-DependencyFingerprint -Prefix $dependencyPrefix
Assert-QtDependencyArchitecture -Prefix $dependencyPrefix -Architecture $Architecture

$installPrefix = [System.IO.Path]::GetFullPath($InstallPrefix)
$qtConfig = Join-Path $installPrefix "lib\cmake\Qt6\Qt6Config.cmake"
$stampPath = Join-Path $installPrefix "share\snow-apps\static-qt-build.json"

$workRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
}
else {
    [System.IO.Path]::GetTempPath()
}
# The build tree deliberately lives outside %TEMP%: temp cleaners and security software prune or
# block generated files there, which shows up as CMake writing build.ninja / Makefile without the
# CMakeFiles payload they include ("loading 'CMakeFiles\rules.ninja': The system cannot find the
# file specified", or NMake's "cannot find file CMakeFiles\cmTC_*.dir\build.make"). A short
# in-repo path also keeps the longest object paths far below CMAKE_OBJECT_PATH_MAX.
$buildRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $workRoot
}
else {
    Join-Path $repoRoot ".tools/qt-build"
}
if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $SourceDirectory = Join-Path $workRoot "snow-qt-$QtVersion-$Architecture/qt-everywhere-src-$QtVersion"
}
$sourceDirectory = [System.IO.Path]::GetFullPath($SourceDirectory)
if ([string]::IsNullOrWhiteSpace($BuildDirectory)) {
    $BuildDirectory = Join-Path $buildRoot "$QtVersion-$Architecture-$($Configuration.ToLowerInvariant())"
}
$buildDirectory = [System.IO.Path]::GetFullPath($BuildDirectory)

Assert-QtDirectoryIsolation -Source $sourceDirectory -Build $buildDirectory `
    -Install $installPrefix -HostPrefix $HostQtPrefix
Assert-SafeRecursiveRemovalTarget -Path $installPrefix -Description "Qt install prefix"
Assert-SafeRecursiveRemovalTarget -Path $buildDirectory -Description "Qt build directory"

$refreshLicenseBundleOnly = $false
if (Test-Path -LiteralPath $qtConfig -PathType Leaf) {
    $stampMatches = $false
    $binaryStampMatches = $false
    if (Test-Path -LiteralPath $stampPath -PathType Leaf) {
        $stamp = Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json
        $binaryStampMatches = (Test-SnowStaticQtStamp -Stamp $stamp -Version $QtVersion `
            -Configuration $Configuration -Architecture $Architecture -HostArchitecture $hostArchitecture) -and
            $stamp.DependencyFingerprint -eq $dependencyFingerprint
        if ($binaryStampMatches) {
            $toolPrefix = if ($crossCompilation) { $HostQtPrefix } else { $installPrefix }
            $binaryStampMatches = Test-SnowQtHostToolHashes -Stamp $stamp -Prefix $toolPrefix
            if ($crossCompilation) { $binaryStampMatches = $binaryStampMatches -and $stamp.HostQtPrefix -ceq $HostQtPrefix }
        }
        $stampMatches = $binaryStampMatches
    }
    $systemCodecsMatch = Test-InstalledQtSystemCodecs -Prefix $installPrefix -Configuration $Configuration -Architecture $Architecture
    $systemCodecsMatch = $systemCodecsMatch -and
        (Get-SnowQtKitVersion -Qt6Dir (Join-Path $installPrefix "lib/cmake/Qt6")) -ceq $QtVersion -and
        (Test-SnowQtArchitecture -Qt6Dir (Join-Path $installPrefix "lib/cmake/Qt6") `
            -Architecture $Architecture -Configuration $Configuration)
    $developmentModulesMatch = -not $enableDevelopmentModules -or
        (Test-SnowQtDevelopmentModules -Qt6Dir (Join-Path $installPrefix "lib/cmake/Qt6"))
    $translationsMatch = Test-SnowQtTranslationKit -Qt6Dir (Join-Path $installPrefix "lib/cmake/Qt6")
    if ($stampMatches -and $systemCodecsMatch -and
        $developmentModulesMatch -and $translationsMatch -and
        (Test-InstalledQtLicenseBundle -Prefix $installPrefix)) {
        Write-Output "Validated static Qt $QtVersion ($Configuration) at $installPrefix"
        exit 0
    }
    if ($binaryStampMatches -and $systemCodecsMatch -and -not $Force) {
        $refreshLicenseBundleOnly = $developmentModulesMatch -and $translationsMatch
        if ($refreshLicenseBundleOnly) {
            Write-Output "Refreshing the audited Qt source-license bundle without rebuilding validated binaries."
        } else {
            Write-Output "Adding missing development modules or stock-dialog translations to the validated Qt kit."
        }
    }
    elseif (-not $Force) {
        throw "The Qt installation at $installPrefix does not match the audited $Configuration feature policy. Use a distinct prefix or pass -Force to replace it."
    }
    else {
        Remove-Item -LiteralPath $installPrefix -Recurse -Force
    }
}

if ($Force -and (Test-Path -LiteralPath $buildDirectory -PathType Container)) {
    Remove-Item -LiteralPath $buildDirectory -Recurse -Force
}

$configurationArgument = if ($Configuration -eq "Debug") { "-debug" } else { "-release" }
$ltcgEnabled = Get-SnowStaticQtLtcgEnabled -Configuration $Configuration -Architecture $Architecture
$ltcgArgument = if ($ltcgEnabled) { "-ltcg" } else { "-no-ltcg" }
$zlibArgument = if ($Configuration -eq "Debug") { "-qt-zlib" } else { "-system-zlib" }
$pngArgument = if ($Configuration -eq "Debug") { "-qt-libpng" } else { "-system-libpng" }
# Two third-party libraries must never be resolved from the ambient PATH. A conda install once
# sat on PATH during configure, so Qt happily linked conda's pcre2-16.lib and zstd.lib import
# libraries; the "static" kit then needed pcre2-16.dll and zstd.dll at run time, which makes the
# build impossible to ship. Qt ships PCRE2 in tree, so pin that one to Qt's own copy. Qt 6.12 has
# no bundled zstd at all (qtbase/src/3rdparty has no zstd directory, and qt_find_package(WrapZSTD)
# only ever looks for an external install), and the vcpkg static triplet does not provide it, so
# the feature is disabled instead: it only backs zstd-compressed .rcc payloads, the mimetype
# database, and zstd Content-Encoding in QtNetwork, none of which this application uses.
$pcreArgument = "-qt-pcre"
$zstdArgument = "-no-feature-zstd"
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
$buildGenerator = Select-CMakeGenerator -Preference $CmakeGenerator -BuildDirectory $buildDirectory
Write-Output ("Configuring static Qt $QtVersion ($Configuration) with the " +
    "$($buildGenerator.Name) generator$(if ($buildGenerator.Program) { " at $($buildGenerator.Program)" }), " +
    "build tree $buildDirectory.")
$archivePath = Join-Path ([System.IO.Path]::GetDirectoryName($sourceDirectory)) "qt-everywhere-src-$QtVersion.tar.xz"
$sourceRelativePath = "qt/$($QtVersion.Substring(0, $QtVersion.LastIndexOf('.')))/$QtVersion/single/qt-everywhere-src-$QtVersion.tar.xz"
# Mirrors are given either as a download.qt.io root mirror (e.g. the Tsinghua or
# USTC /qt tree) or as one of its published subtrees (e.g. .../official_releases).
# Expand the matching tree so either form resolves to a valid URL.
$mirrorRoot = $QtMirrorBaseUrl.TrimEnd('/')
$mirrorUrls = @()
if ($mirrorRoot -match '/(official_releases|archive)$') {
    $mirrorUrls += "$mirrorRoot/$sourceRelativePath"
}
else {
    $mirrorUrls += "$mirrorRoot/official_releases/$sourceRelativePath"
    $mirrorUrls += "$mirrorRoot/archive/$sourceRelativePath"
}
$sourceUrls = @($mirrorUrls) + @(
    "https://download.qt.io/official_releases/$sourceRelativePath"
) | Select-Object -Unique

if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($archivePath)) |
            Out-Null
        $downloaded = $false
        foreach ($sourceUrl in $sourceUrls) {
            try {
                Save-RemoteFile -Uri $sourceUrl -Destination $archivePath
                Assert-QtSourceArchive -Path $archivePath
                $downloaded = $true
                break
            }
            catch {
                Write-Warning "Qt source mirror failed ($sourceUrl): $($_.Exception.Message)"
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $downloaded) {
            throw ("All Qt source mirrors failed. Download qt-everywhere-src-$QtVersion.tar.xz " +
                "(SHA256 $($script:SnowQtToolchain.sourceArchiveSha256)) manually into " +
                "'$([System.IO.Path]::GetDirectoryName($archivePath))', or extract it and pass " +
                "-SourceDirectory with the qt-everywhere-src-$QtVersion tree.")
        }
    }
    Assert-QtSourceArchive -Path $archivePath
    $sourceParent = Split-Path -Parent $sourceDirectory
    $extractedSourceDirectory = Join-Path $sourceParent "qt-everywhere-src-$QtVersion"
    New-Item -ItemType Directory -Force -Path $sourceParent | Out-Null
    if (-not (Test-Path -LiteralPath $extractedSourceDirectory -PathType Container)) {
        Expand-QtSourceArchive -ArchivePath $archivePath -Destination $sourceParent
    }
    if ($sourceDirectory -ne $extractedSourceDirectory -and
        (Test-Path -LiteralPath $extractedSourceDirectory -PathType Container)) {
        Move-Item -LiteralPath $extractedSourceDirectory -Destination $sourceDirectory
    }
    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        throw "Qt source archive did not produce the expected directory: $sourceDirectory"
    }
}

Install-QtSourcePatches -Source $sourceDirectory

if ($refreshLicenseBundleOnly) {
    Install-QtLicenseBundle -Source $sourceDirectory -Prefix $installPrefix `
        -Version $QtVersion -SourceArchive $sourceUrls[-1]
    if (-not (Test-InstalledQtLicenseBundle -Prefix $installPrefix)) {
        throw "The refreshed Qt licensing bundle failed validation."
    }
    Write-StaticQtBuildStamp -Path $stampPath -Version $QtVersion `
        -BuildConfiguration $Configuration -Fingerprint $dependencyFingerprint `
        -SourceArchive $sourceUrls[-1] -BuildParallelism $Parallelism `
        -Architecture $Architecture -HostArchitecture $hostArchitecture -HostQtPrefix $HostQtPrefix `
        -WithDevelopmentModules (Test-SnowQtDevelopmentModules -Qt6Dir (Join-Path $installPrefix "lib/cmake/Qt6"))
    Write-Output "Validated static Qt $QtVersion ($Configuration) and refreshed its license provenance at $installPrefix"
    exit 0
}

# The Visual Studio generator locates MSBuild itself, so there is no build tool to pin there.
$generatorProgramArguments = if ($buildGenerator.Program) {
    @("-DCMAKE_MAKE_PROGRAM=$($buildGenerator.Program)")
}
else { @() }
if ($buildGenerator.Name -like "Visual Studio*" -and
    -not [string]::IsNullOrWhiteSpace($env:VSINSTALLDIR)) {
    $generatorProgramArguments += "-DCMAKE_GENERATOR_INSTANCE=$env:VSINSTALLDIR"
}
$configureArguments = @(
    "-static",
    $configurationArgument,
    "-static-runtime",
    $ltcgArgument,
    $zlibArgument,
    $pngArgument,
    $pcreArgument,
    $zstdArgument,
    "-no-opengl",
    "-no-feature-androiddeployqt",
    "-no-feature-wasmdeployqt",
    "-opensource",
    "-confirm-license",
    "-prefix", $installPrefix,
    "-submodules", "qtbase,qtsvg,qttools,qttranslations",
    "-skip", "qtactiveqt",
    "-skip", "qtdeclarative",
    "-skip", "qtimageformats",
    "-skip", "qtlanguageserver",
    "-skip", "qtshadertools",
    "-nomake", "tests",
    "-nomake", "examples",
    # Pin the generator instead of letting configure auto-detect one: without this Qt falls back
    # to whatever make tool happens to be first on PATH (it picked "MinGW Makefiles" on this host
    # when the MSVC directories were not visible).
    "-cmake-generator", $buildGenerator.Name,
    "--",
    "-UFEATURE_opengl*",
    "-UQT_FEATURE_opengl*",
    "-UFEATURE_dynamicgl",
    "-UQT_FEATURE_dynamicgl",
    "-DCMAKE_PREFIX_PATH=$dependencyPrefix",
    "-DZLIB_ROOT=$dependencyPrefix",
    "-DPNG_ROOT=$dependencyPrefix",
    "-DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON",
    # Belt and braces for the bundled pcre2 / disabled zstd choice above: even if a stray
    # PCRE2Config.cmake or zstdConfig.cmake is reachable, configure must not consume it.
    "-DCMAKE_DISABLE_FIND_PACKAGE_PCRE2=ON",
    "-DCMAKE_DISABLE_FIND_PACKAGE_WrapSystemPCRE2=ON",
    "-DCMAKE_DISABLE_FIND_PACKAGE_zstd=ON",
    $generatorProgramArguments,
    "-DFEATURE_timezone=ON",
    "-DFEATURE_timezone_locale=OFF",
    "-DQT_FEATURE_concurrent=ON",
    "-DQT_FEATURE_dbus=OFF",
    "-DQT_FEATURE_linguist=ON",
    "-DQT_FEATURE_printsupport=OFF",
    "-DQT_FEATURE_qdoc=OFF",
    "-DQT_FEATURE_qmake=OFF",
    "-DQT_FEATURE_sql=OFF",
    "-DQT_FEATURE_testlib=$(if ($enableDevelopmentModules) { 'ON' } else { 'OFF' })",
    "-DQT_FEATURE_windeployqt=OFF",
    "-DQT_FEATURE_assistant=OFF",
    "-DQT_FEATURE_designer=OFF",
    "-DQT_FEATURE_distancefieldgenerator=OFF",
    "-DQT_FEATURE_kmap2qmap=OFF",
    "-DQT_FEATURE_pixeltool=OFF",
    "-DQT_FEATURE_qdbus=OFF",
    "-DQT_FEATURE_qev=OFF",
    "-DQT_FEATURE_qtattributionsscanner=OFF",
    "-DQT_FEATURE_qtdiag=OFF",
    "-DQT_FEATURE_qtplugininfo=OFF"
)
if ($crossCompilation) {
    # configure's platform switches belong before the CMake argument delimiter.
    $delimiter = [Array]::IndexOf($configureArguments, "--")
    $targetSpec = if ($Architecture -eq "arm64") { "win32-arm64-msvc" } else { "win32-msvc" }
    $targetProcessor = if ($Architecture -eq "arm64") { "ARM64" } else { "AMD64" }
    $configureArguments = @($configureArguments[0..($delimiter - 1)]) +
        @("-xplatform", $targetSpec, "-qt-host-path", $HostQtPrefix) +
        @($configureArguments[$delimiter..($configureArguments.Count - 1)]) +
        @("-DCMAKE_SYSTEM_NAME=Windows", "-DCMAKE_SYSTEM_PROCESSOR=$targetProcessor",
            "-DQT_HOST_PATH:PATH=$HostQtPrefix")
}
Invoke-Checked -Command (Join-Path $sourceDirectory "configure.bat") `
    -Arguments $configureArguments -WorkingDirectory $buildDirectory

$cachePath = Join-Path $buildDirectory "CMakeCache.txt"
if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
    throw "Qt configure did not produce $cachePath."
}
$cache = Get-Content -LiteralPath $cachePath -Raw
$ltcgState = if ($ltcgEnabled) { "ON" } else { "OFF" }
$systemCodecState = if ($Configuration -eq "Release") { "ON" } else { "OFF" }
Assert-CacheEntry -Cache $cache -Pattern "(?m)^FEATURE_ltcg:BOOL=$ltcgState\r?`$" -Description "$Configuration LTCG policy"
Assert-CacheEntry -Cache $cache -Pattern "(?m)^QT_FEATURE_ltcg:INTERNAL=$ltcgState\r?`$" -Description "the internal $Configuration LTCG policy"
Assert-CacheEntry -Cache $cache -Pattern "(?m)^FEATURE_system_png:BOOL=$systemCodecState\r?`$" -Description "$Configuration libpng linkage"
Assert-CacheEntry -Cache $cache -Pattern "(?m)^QT_FEATURE_system_png:INTERNAL=$systemCodecState\r?`$" -Description "the internal $Configuration libpng linkage"
Assert-CacheEntry -Cache $cache -Pattern "(?m)^FEATURE_system_zlib:BOOL=$systemCodecState\r?`$" -Description "$Configuration zlib linkage"
Assert-CacheEntry -Cache $cache -Pattern "(?m)^QT_FEATURE_system_zlib:INTERNAL=$systemCodecState\r?`$" -Description "the internal $Configuration zlib linkage"
Assert-CacheEntry -Cache $cache -Pattern '(?m)^FEATURE_pcre2:BOOL=ON\r?$' -Description "PCRE2 support"
Assert-CacheEntry -Cache $cache -Pattern '(?m)^QT_FEATURE_pcre2:INTERNAL=ON\r?$' -Description "the internal PCRE2 feature"
Assert-CacheEntry -Cache $cache -Pattern '(?m)^QT_FEATURE_system_pcre2:INTERNAL=OFF\r?$' `
    -Description "PCRE2 linkage (Qt's bundled copy instead of a system PCRE2)"
Assert-CacheEntry -Cache $cache -Pattern '(?m)^QT_FEATURE_zstd:(?:INTERNAL|UNINITIALIZED|BOOL)=OFF\r?$' `
    -Description "zstd support (Qt 6.12 ships no bundled copy)"
Assert-CacheEntry -Cache $cache -Pattern '(?m)^FEATURE_timezone:BOOL=ON\r?$' -Description "time-zone handling"
Assert-CacheEntry -Cache $cache -Pattern '(?m)^QT_FEATURE_timezone:INTERNAL=ON\r?$' -Description "the internal time-zone feature"
Assert-CacheEntry -Cache $cache -Pattern '(?m)^QT_FEATURE_concurrent:INTERNAL=ON\r?$' -Description "the required Qt Concurrent feature"
Assert-CacheEntry -Cache $cache -Pattern '(?m)^FEATURE_timezone_locale:BOOL=OFF\r?$' -Description "disabled localized time-zone display names"
Assert-CacheEntry -Cache $cache `
    -Pattern '(?m)^QT_FEATURE_linguist:(?:INTERNAL|UNINITIALIZED)=ON\r?$' `
    -Description "the LinguistTools feature"
foreach ($disabledFeature in @(
        "androiddeployqt",
        "dbus",
        "dynamicgl",
        "opengl",
        "opengl_dynamic",
        "printsupport",
        "qdoc",
        "qmake",
        "sql",
        "testlib",
        "timezone_locale",
        "wasmdeployqt",
        "windeployqt")) {
    if ($disabledFeature -eq "testlib" -and $enableDevelopmentModules) {
        Assert-CacheEntry -Cache $cache `
            -Pattern "(?m)^QT_FEATURE_${disabledFeature}:(?:INTERNAL|UNINITIALIZED)=ON\r?`$" `
            -Description "the development $disabledFeature feature"
        continue
    }
    Assert-CacheEntry -Cache $cache `
        -Pattern "(?m)^QT_FEATURE_$([regex]::Escape($disabledFeature)):(?:INTERNAL|UNINITIALIZED)=OFF\r?`$" `
        -Description "the disabled $disabledFeature feature"
}
foreach ($skippedSubmodule in @(
        "qtactiveqt",
        "qtdeclarative",
        "qtimageformats",
        "qtlanguageserver",
        "qtshadertools")) {
    Assert-CacheEntry -Cache $cache `
        -Pattern "(?m)^BUILD_$([regex]::Escape($skippedSubmodule)):(?:BOOL|UNINITIALIZED)=OFF\r?`$" `
        -Description "the skipped $skippedSubmodule submodule"
}
$normalizedDependencyPrefix = $dependencyPrefix -replace '\\', '/'
if (($cache -replace '\\', '/') -notmatch [regex]::Escape($normalizedDependencyPrefix)) {
    throw "Qt did not resolve its dependencies from $dependencyPrefix."
}
$makefileGeneratorEntry = [regex]::Match($cache, '(?m)^CMAKE_MAKE_PROGRAM:(?:FILEPATH|UNINITIALIZED)=(.*)$')
$makefileGeneratorValue = if ($makefileGeneratorEntry.Success) {
    $makefileGeneratorEntry.Groups[1].Value.Trim()
} else { "" }
Assert-CacheEntry -Cache $cache `
    -Pattern "(?m)^CMAKE_GENERATOR:INTERNAL=$([regex]::Escape($buildGenerator.Name))\r?`$" `
    -Description "the $($buildGenerator.Name) CMake generator"
if ($buildGenerator.Program -and
    -not [System.IO.Path]::IsPathRooted($makefileGeneratorValue)) {
    throw ("Qt configure did not pin the build tool to $($buildGenerator.Program); the compiler " +
        "tests then look the tool up on PATH, which this host reports incorrectly.")
}

$buildArguments = @(
    "--build", $buildDirectory,
    "--config", $Configuration,
    "--parallel", $Parallelism.ToString()
)
Invoke-Checked -Command "cmake" -Arguments $buildArguments
Invoke-Checked -Command "cmake" -Arguments @(
    "--install", $buildDirectory, "--config", $Configuration
)

if (-not (Test-Path -LiteralPath $qtConfig -PathType Leaf)) {
    throw "Qt $QtVersion installation did not produce $qtConfig"
}
if (-not (Test-SnowQtTranslationKit -Qt6Dir (Join-Path $installPrefix "lib/cmake/Qt6"))) {
    throw "The installed Qt kit does not provide Simplified and Traditional Chinese stock-dialog translations."
}
if (-not (Test-InstalledQtSystemCodecs -Prefix $installPrefix -Configuration $Configuration -Architecture $Architecture)) {
    throw "The installed Qt targets do not export the audited $Configuration codec/LTCG/timezone feature policy."
}
if (-not (Test-SnowQtArchitecture -Qt6Dir (Join-Path $installPrefix "lib/cmake/Qt6") `
        -Architecture $Architecture -Configuration $Configuration)) {
    throw "The installed Qt libraries do not match the requested $Architecture target."
}

Install-QtLicenseBundle -Source $sourceDirectory -Prefix $installPrefix `
    -Version $QtVersion -SourceArchive $sourceUrls[-1]
if (-not (Test-InstalledQtLicenseBundle -Prefix $installPrefix)) {
    throw "The installed Qt licensing bundle failed validation."
}

Write-StaticQtBuildStamp -Path $stampPath -Version $QtVersion `
    -BuildConfiguration $Configuration -Fingerprint $dependencyFingerprint `
    -SourceArchive $sourceUrls[-1] -BuildParallelism $Parallelism -WithDevelopmentModules $enableDevelopmentModules `
    -Architecture $Architecture -HostArchitecture $hostArchitecture -HostQtPrefix $HostQtPrefix

Write-Output "Static Qt $QtVersion ($Configuration) installed at $installPrefix"

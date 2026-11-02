# Deterministic tool version checks; no downloads or compilation.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'snow-build-environment.ps1')

function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function rustc {
    $global:LASTEXITCODE = $script:FixtureRustExitCode
    return $script:FixtureRustOutput
}
$script:FixtureRustExitCode = 0
foreach ($version in @('1.97.1', '1.97.2', '1.98.0', '1.100.0', '2.0.0')) {
    foreach ($hostName in @('x86_64', 'aarch64')) {
        $script:FixtureRustOutput = "release: $version`nhost: $hostName-pc-windows-msvc"
        $info = Get-SnowRustToolchainInfo
        Require ($info.Version -ceq $version) 'Accept Rust at or above the minimum without replacing it.'
        $expectedArchitecture = if ($hostName -ceq 'aarch64') { 'arm64' } else { 'x64' }
        Require ($info.Architecture -ceq $expectedArchitecture) 'Retain Rust host architecture validation.'
    }
}
foreach ($output in @('release: 1.97.0', 'release: 1.96.9', 'release: invalid', '')) {
    $script:FixtureRustOutput = "$output`nhost: x86_64-pc-windows-msvc"
    $rejected = $false
    try { Get-SnowRustToolchainInfo | Out-Null } catch { $rejected = $true }
    Require $rejected 'Reject Rust below the minimum and unparseable versions.'
}
foreach ($hostName in @('x86_64-pc-windows-gnu', 'x86_64-unknown-linux-gnu')) {
    $script:FixtureRustOutput = "release: 1.98.0`nhost: $hostName"
    $rejected = $false
    try { Get-SnowRustToolchainInfo | Out-Null } catch { $rejected = $true }
    Require $rejected 'A newer incompatible Rust host must still fail.'
}
$script:FixtureRustOutput = "release: 1.98.0`nhost: x86_64-pc-windows-msvc"
$script:FixtureRustExitCode = 1
$rejected = $false
try { Get-SnowRustToolchainInfo | Out-Null } catch { $rejected = $true }
Require $rejected 'A failed rustc invocation must fail validation.'

# Execute the real bootstrap Rust setup with command boundaries recorded.
$script:FixtureRustExitCode = 0
$script:Calls = @()
function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments, [string]$WorkingDirectory)
    $script:Calls += [pscustomobject]@{ Command = $Command; Arguments = $Arguments }
}
$parseErrors = $null
$bootstrap = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'bootstrap.ps1'), [ref]$null, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'Bootstrap must parse successfully.'
$repoRoot = $script:SnowRepoRoot
$rustup = [pscustomobject]@{ Source = 'rustup' }
$cargo = [pscustomobject]@{ Source = 'cargo' }
$rustTarget = 'aarch64-pc-windows-msvc'
. (Join-Path $PSScriptRoot 'snow-ocr-toolchain.ps1')
$ocrToolchain = Get-SnowOcrToolchain
$commands = @($bootstrap.EndBlock.Statements | Where-Object {
    $_.Extent.Text -match 'Invoke-Checked -Command \$(rustup|cargo)\.Source'
})
Require ($commands.Count -eq 5) 'Exercise the worker pin, active Rust components, target, and both metadata calls.'
foreach ($command in $commands) { & ([scriptblock]::Create($command.Extent.Text)) }
Require (($script:Calls[1].Arguments -join ' ') -ceq 'component add rustfmt clippy') `
    'Add components to the active toolchain.'
Require (($script:Calls[2].Arguments -join ' ') -ceq "target add $rustTarget") `
    'Add the requested target to the active toolchain.'
Require (($script:Calls[0].Arguments -join ' ') -ceq "toolchain install $ocrToolchain --profile minimal --component rustfmt,clippy --target $rustTarget") `
    'Install the submodule-pinned OCR compiler without changing the default compiler.'
foreach ($call in $script:Calls | Where-Object Command -CEQ cargo) {
    Require ($call.Arguments[0] -ceq 'metadata') 'Cargo must use the active toolchain without an exact-version override.'
}

# Visual Studio keeps Ninja outside PATH; the OCR worker's shaderc build needs it.
$ninjaFixture = Join-Path ([IO.Path]::GetTempPath()) ("snow-ninja-test-" + [guid]::NewGuid().ToString('N'))
$ninjaDirectory = Join-Path $ninjaFixture 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'
$savedVsInstallDirectory = $env:VSINSTALLDIR
$savedVcInstallDirectory = $env:VCINSTALLDIR
$savedPath = $env:Path
try {
    New-Item -ItemType Directory -Path $ninjaDirectory -Force | Out-Null
    $env:VSINSTALLDIR = $ninjaFixture
    $env:VCINSTALLDIR = $null
    $env:Path = @($env:Path -split ';' | Where-Object { $_ -and
            -not (Test-Path -LiteralPath (Join-Path $_ 'ninja.exe') -PathType Leaf) }) -join ';'
    Require ((Get-SnowNinjaSearchDirectory) -ccontains $ninjaDirectory) `
        'Locate Ninja under the Visual Studio installation that owns the MSVC tools.'
    Require ($null -eq (Resolve-SnowNinjaExecutable)) 'Report a missing Ninja instead of guessing.'
    New-Item -ItemType File -Path (Join-Path $ninjaDirectory 'ninja.exe') | Out-Null
    Require ((Resolve-SnowNinjaExecutable) -ceq (Join-Path $ninjaDirectory 'ninja.exe')) `
        'Fall back to the Visual Studio Ninja when PATH has none.'
    Require ((Resolve-SnowNinjaExecutable -SearchDirectory $ninjaDirectory) -ceq
        (Join-Path $ninjaDirectory 'ninja.exe')) 'Accept an explicitly provided Ninja directory.'
}
finally {
    $env:VSINSTALLDIR = $savedVsInstallDirectory
    $env:VCINSTALLDIR = $savedVcInstallDirectory
    $env:Path = $savedPath
    Remove-Item -LiteralPath $ninjaFixture -Recurse -Force -ErrorAction SilentlyContinue
}

$saved = @{}
foreach ($name in @('VCPKG_ROOT', 'VCPKG_FORCE_SYSTEM_BINARIES', 'VCPKG_FORCE_DOWNLOADED_BINARIES')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $env:VCPKG_FORCE_SYSTEM_BINARIES = '1'
    $env:VCPKG_FORCE_DOWNLOADED_BINARIES = '1'
    Set-SnowVcpkgEnvironment
    Require (-not (Test-Path Env:VCPKG_FORCE_SYSTEM_BINARIES) -and
        -not (Test-Path Env:VCPKG_FORCE_DOWNLOADED_BINARIES)) `
        'vcpkg must be free to accept installed tools or acquire tools meeting its minimum.'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
Write-Output 'Build toolchain minimum-version tests passed.'

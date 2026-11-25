param(
    [ValidateSet('amd64', 'arm64')][string]$Architecture = 'amd64',
    [switch]$PrintEnvironment,
    [switch]$PrintSystemPaths
)

$ErrorActionPreference = 'Stop'
$programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$userProfile = [Environment]::GetFolderPath('UserProfile')
$system = [Environment]::GetFolderPath('System')
$commandProcessor = Join-Path $system 'cmd.exe'
if ($PrintSystemPaths) {
    @{ program_files_x86 = $programFilesX86; program_files = $programFiles; user_profile = $userProfile; command_processor = $commandProcessor } | ConvertTo-Json -Compress
    return
}
foreach ($entry in @{ 'ProgramFiles(x86)' = $programFilesX86; 'ProgramFiles' = $programFiles; 'USERPROFILE' = $userProfile; 'ComSpec' = $commandProcessor; 'SystemRoot' = (Split-Path $system); 'WINDIR' = (Split-Path $system) }.GetEnumerator()) {
    if (![Environment]::GetEnvironmentVariable($entry.Key, 'Process')) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
}
if (!$env:PATHEXT) { $env:PATHEXT = '.COM;.EXE;.BAT;.CMD' }
$vsRoot = $null
if ($env:FLCLASH_MSVC_COMPILER) {
    $directory = Get-Item -LiteralPath (Split-Path $env:FLCLASH_MSVC_COMPILER)
    while ($directory -and $directory.Name -ne 'VC') { $directory = $directory.Parent }
    if ($directory) { $vsRoot = $directory.Parent.FullName }
}
if (!$vsRoot) {
    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (!(Test-Path -LiteralPath $vswhere)) { throw 'Install Visual Studio Build Tools with Desktop development with C++ (vswhere.exe is missing).' }
    $vsRoot = & $vswhere -latest -products '*' -property installationPath
}
if (!$vsRoot) { throw 'Visual Studio C++ tools were not found.' }
$vcvars = Join-Path $vsRoot 'VC/Auxiliary/Build/vcvarsall.bat'
$vcArch = if ($Architecture -eq 'arm64') { 'amd64_arm64' } else { 'amd64' }
& $env:ComSpec /d /c "call `"$vcvars`" $vcArch >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
}
if ($LASTEXITCODE -ne 0) { throw "Visual Studio environment setup failed for $Architecture" }

$cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $userProfile '.cargo' }
$env:PATH = (Join-Path $cargoHome 'bin') + ';' + $env:PATH
$toolchain = if ($env:FLCLASH_RUST_TOOLCHAIN) {
    $env:FLCLASH_RUST_TOOLCHAIN
} elseif ($env:RUSTUP_TOOLCHAIN -and $env:RUSTUP_TOOLCHAIN -notmatch 'windows-gnu') {
    $env:RUSTUP_TOOLCHAIN
} elseif ($env:RUSTC -and $env:RUSTC -match 'toolchains[\\/]([^\\/]+msvc)[\\/]bin') {
    $matches[1]
} else {
    $active = (& rustup show active-toolchain) -split ' ' | Select-Object -First 1
    if ($active -and $active -match 'windows-msvc$') { $active } else { 'stable-msvc' }
}
$rustc = & rustup which --toolchain $toolchain rustc
if ($LASTEXITCODE -ne 0) { throw "Install an MSVC Rust toolchain: rustup toolchain install $toolchain" }
$env:RUSTUP_TOOLCHAIN = $toolchain
$env:RUSTC = $rustc

if ($PrintEnvironment) {
    $names = @('PATH', 'PATHEXT', 'INCLUDE', 'LIB', 'LIBPATH', 'RUSTUP_TOOLCHAIN', 'RUSTC', 'SystemRoot', 'WINDIR', 'ComSpec', 'USERPROFILE', 'ProgramFiles', 'ProgramFiles(x86)')
    $values = @{}
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -ne $value) { $values[$name] = $value }
    }
    ConvertTo-Json -InputObject $values -Compress
}

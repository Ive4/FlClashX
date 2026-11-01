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
$rustTarget = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
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

$cmakeBin = Join-Path $vsRoot 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin'
$llvmCandidates = @(
    $env:LIBCLANG_PATH,
    $(if ($env:LLVM_HOME) { Join-Path $env:LLVM_HOME 'bin' }),
    (Join-Path $programFiles 'LLVM/bin'),
    (Join-Path $vsRoot 'VC/Tools/Llvm/x64/bin'),
    (Join-Path $vsRoot 'VC/Tools/Llvm/bin')
) + ($env:PATH -split ';')
$libclang = $llvmCandidates | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'libclang.dll')) } | Select-Object -First 1
if (!$libclang) { throw 'Install LLVM with libclang.dll, or set LIBCLANG_PATH to the LLVM/Harmony SDK bin directory.' }
$env:LIBCLANG_PATH = $libclang
$env:PATH = "$cmakeBin;$libclang;" + $env:PATH
foreach ($nativeTool in @('cmake', 'clang')) {
    if (!(Get-Command $nativeTool -ErrorAction SilentlyContinue)) { throw "Install $nativeTool and add its bin directory to PATH." }
}
if ($Architecture -eq 'amd64' -and !(Get-Command nasm -ErrorAction SilentlyContinue)) { throw 'Install NASM and add its directory to PATH (BoringSSL x64 assembly requires it).' }
$includeFlags = ($env:INCLUDE -split ';' | Where-Object { $_ } | ForEach-Object { '-isystem "' + $_ + '"' }) -join ' '
[Environment]::SetEnvironmentVariable("BINDGEN_EXTRA_CLANG_ARGS_$($rustTarget.Replace('-', '_'))", "--target=$rustTarget -fms-extensions -fms-compatibility $includeFlags", 'Process')
$env:CFLAGS = "$env:CFLAGS /utf-8".Trim()
$env:CXXFLAGS = "$env:CXXFLAGS /utf-8".Trim()

if ($PrintEnvironment) {
    $names = @('PATH', 'PATHEXT', 'INCLUDE', 'LIB', 'LIBPATH', 'RUSTUP_TOOLCHAIN', 'RUSTC', 'LIBCLANG_PATH', 'CFLAGS', 'CXXFLAGS', 'SystemRoot', 'WINDIR', 'ComSpec', 'USERPROFILE', 'ProgramFiles', 'ProgramFiles(x86)', "BINDGEN_EXTRA_CLANG_ARGS_$($rustTarget.Replace('-', '_'))")
    $values = @{}
    foreach ($name in $names) { $values[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    ConvertTo-Json -InputObject $values -Compress
}

param(
    [string]$NativeSdk = $env:OHOS_NDK_HOME,
    [string]$Toolchain = $(if ($env:FLCLASH_OHOS_RUST_TOOLCHAIN) { $env:FLCLASH_OHOS_RUST_TOOLCHAIN } else { '1.99.0-msvc' }),
    [string]$TargetDirectory,
    [string]$OutputDirectory,
    [switch]$CheckToolchain
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
if (!$NativeSdk) { throw 'Set OHOS_NDK_HOME or pass -NativeSdk with the HarmonyOS native SDK directory.' }
$NativeSdk = (Resolve-Path -LiteralPath $NativeSdk).Path
$llvm = Join-Path $NativeSdk 'llvm'
$bin = Join-Path $llvm 'bin'
$sysroot = Join-Path $NativeSdk 'sysroot'
$sdkToolchain = Join-Path $NativeSdk 'build/cmake/ohos.toolchain.cmake'
foreach ($required in @("$bin/clang.exe", "$bin/clang++.exe", "$bin/libclang.dll", "$bin/llvm-ar.exe", $sdkToolchain)) {
    if (!(Test-Path -LiteralPath $required)) { throw "Incomplete HarmonyOS native SDK: $required" }
}
if (!$TargetDirectory) { $TargetDirectory = Join-Path $repository '.dart_tool/ohos_core' }
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repository 'ohos/entry/libs/arm64-v8a' }
$TargetDirectory = [IO.Path]::GetFullPath($TargetDirectory)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $TargetDirectory | Out-Null
$target = 'aarch64-unknown-linux-ohos'
$suffix = $target.Replace('-', '_')
$sdkCmakeBin = Join-Path $NativeSdk 'build-tools/cmake/bin'
$env:PATH = "$sdkCmakeBin;$bin;" + $env:PATH
if (!(Get-Command cmake -ErrorAction SilentlyContinue)) { throw 'Install CMake 3.22 or newer and add it to PATH.' }
if (!(Get-Command ninja -ErrorAction SilentlyContinue)) { throw 'Install Ninja and add it to PATH (or use the SDK build-tools/cmake/bin directory).' }
$cmakeToolchain = Join-Path $TargetDirectory 'flclash-ohos.cmake'
$sdkToolchainCmake = $sdkToolchain.Replace('\', '/')
@"
set(OHOS_ARCH arm64-v8a)
set(OHOS_STL c++_shared)
include("$sdkToolchainCmake")
"@ | Set-Content -LiteralPath $cmakeToolchain -Encoding ascii
$linker = Join-Path $TargetDirectory 'flclash-ohos-link.cmd'
"@echo off`r`n`"$bin\clang.exe`" --target=aarch64-linux-ohos --sysroot=`"$sysroot`" -L`"$llvm/lib/aarch64-linux-ohos`" %*`r`n" | Set-Content -LiteralPath $linker -Encoding ascii
$cCompiler = Join-Path $TargetDirectory 'flclash-ohos-clang.cmd'
$cxxCompiler = Join-Path $TargetDirectory 'flclash-ohos-clang++.cmd'
"@echo off`r`n`"$bin\clang.exe`" --target=aarch64-linux-ohos --sysroot=`"$sysroot`" %*`r`n" | Set-Content -LiteralPath $cCompiler -Encoding ascii
"@echo off`r`n`"$bin\clang++.exe`" --target=aarch64-linux-ohos --sysroot=`"$sysroot`" %*`r`n" | Set-Content -LiteralPath $cxxCompiler -Encoding ascii
$flags = "--target=aarch64-linux-ohos --sysroot=`"$sysroot`""
$nativeEnvironment = @{
    'CC_SHELL_ESCAPED_FLAGS' = '1'
    'CMAKE_GENERATOR' = 'Ninja'
    'LIBCLANG_PATH' = $bin
    "CARGO_TARGET_$($suffix.ToUpperInvariant())_LINKER" = $linker
    "CC_$suffix" = $cCompiler
    "CXX_$suffix" = $cxxCompiler
    "AR_$suffix" = "$bin/llvm-ar.exe"
    "CFLAGS_$suffix" = '--target=aarch64-linux-ohos'
    "CXXFLAGS_$suffix" = '--target=aarch64-linux-ohos'
    "CMAKE_TOOLCHAIN_FILE_$suffix" = $cmakeToolchain
    "BORING_BSSL_SYSROOT_$suffix" = $sysroot
    "BORING_BSSL_RUST_CPPLIB_$suffix" = 'c++_shared'
    "BINDGEN_EXTRA_CLANG_ARGS_$suffix" = $flags
}
foreach ($entry in $nativeEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
$rustLibraryDirectory = & rustup run $Toolchain rustc --print target-libdir --target $target
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $rustLibraryDirectory)) { throw "Install the Rust target: rustup target add --toolchain $Toolchain $target" }
if ($CheckToolchain) { return }
$cargoArgs = @('build', '--locked', '--release', '--lib', '--manifest-path', "$repository/core/rust/Cargo.toml", '--target', $target, '--target-dir', $TargetDirectory)
$configuration = [IO.File]::ReadAllText((Join-Path $repository 'build_config.yaml'))
$features = [regex]::Match($configuration, '(?m)^core_features:\s*(.*?)\s*$').Groups[1].Value.Trim('"', "'")
if ($features) { $cargoArgs += @('--features', $features) }
& rustup run $Toolchain cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS Rust Core build failed; previous staged libraries were preserved.' }
$library = Join-Path $TargetDirectory "$target/release/libflclash.so"
if (!(Test-Path -LiteralPath $library) -or (Get-Item -LiteralPath $library).Length -eq 0) { throw "Cargo produced no $library" }
$cxxRuntime = Join-Path $llvm 'lib/aarch64-linux-ohos/libc++_shared.so'
if (!(Test-Path -LiteralPath $cxxRuntime)) { throw "Missing HarmonyOS C++ runtime $cxxRuntime" }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
foreach ($artifact in @($library, $cxxRuntime)) {
    $destination = Join-Path $OutputDirectory (Split-Path $artifact -Leaf)
    $staged = "$destination.$PID.tmp"
    Copy-Item -LiteralPath $artifact -Destination $staged -Force
    Move-Item -LiteralPath $staged -Destination $destination -Force
}

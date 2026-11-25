param([string]$ToolDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'flclashx-llvm-mingw'))

$ErrorActionPreference = 'Stop'
$release = '20261117'
$arch, $digest = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    Arm64 { 'aarch64'; 'c7f56de1d7aca15196c19083a799205390397b8b87a825aec3485e1e4f3c2cdd' }
    X64   { 'x86_64'; '4d002e330a0f703625aa5ccbc37e96f8f824413e163bfc7336774aabd2c3a412' }
    default { throw 'LLVM MinGW requires a Windows x64 or ARM64 host' }
}
$name = "llvm-mingw-$release-ucrt-$arch"
$bin = Join-Path $ToolDirectory "$name/bin"
if (!(Test-Path -LiteralPath (Join-Path $bin "$arch-w64-mingw32-clang.exe"))) {
    [void](New-Item -Path $ToolDirectory -ItemType Directory -Force)
    $archive = Join-Path $ToolDirectory "$name.zip"
    curl.exe --fail --silent --show-error --location --retry 3 "https://github.com/mstorsjo/llvm-mingw/releases/download/$release/$name.zip" --output $archive
    if ($LASTEXITCODE -ne 0) { throw 'Failed to download LLVM MinGW' }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $digest) {
        throw 'LLVM MinGW checksum mismatch'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $ToolDirectory -Force
}
if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $bin }
Write-Output $bin

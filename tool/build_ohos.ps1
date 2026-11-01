param([string]$HarmonyHome = 'D:\Java\Huawei')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$override = Join-Path $root 'pubspec_overrides.yaml'
if (Test-Path $override) { throw 'Existing pubspec_overrides.yaml must be preserved; remove it from this build workspace first.' }
. (Join-Path $HarmonyHome 'Enable-Harmony.ps1')
$env:PUB_HOSTED_URL = 'https://pub.dev'
$flutter = Join-Path $env:HM_FLUTTER_HOME 'bin/flutter.bat'
$lock = Join-Path $root 'pubspec.lock'
$originalLock = [IO.File]::ReadAllBytes($lock)
Push-Location $root
try {
    if (!(Test-Path 'ohos/build-profile.json5')) {
        Copy-Item 'ohos/build-profile.template.json5' 'ohos/build-profile.json5'
    }
    & "$PSScriptRoot/prepare_ohos.ps1"
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS pub get failed' }
    & "$PSScriptRoot/build_rust_ohos.ps1" -NativeSdk $env:OHOS_NDK_HOME
    & $flutter build hap --release --target-platform ohos-arm64
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS HAP build failed; inspect the build output above' }
} finally {
    if (Test-Path $override) { Remove-Item -LiteralPath $override }
    [IO.File]::WriteAllBytes($lock, $originalLock)
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not restore ordinary dependency resolution' }
    Pop-Location
}

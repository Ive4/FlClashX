param(
    [Parameter(Mandatory = $true)][string]$GoHome,
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot) 'ohos/entry/libs/arm64-v8a')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$go = [IO.Path]::GetFullPath((Join-Path $GoHome 'bin/go.exe'))
$clang = [IO.Path]::GetFullPath((Join-Path $GoHome 'bin/ohos-clang.cmd'))
foreach ($tool in @($go, $clang)) {
    if (!(Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Missing HarmonyOS Go toolchain file: $tool" }
}

$coreDir = Join-Path $root 'core'
$tunnel = Join-Path $coreDir 'Clash.Meta/tunnel/tunnel.go'
$config = Get-Content -LiteralPath (Join-Path $root 'build_config.yaml') -Raw
$version = [regex]::Match($config, '(?m)^core_version:\s*(v[\d.]+)\s*$').Groups[1].Value
if (!$version) { throw 'Missing mihomo version in build_config.yaml' }
$source = Get-Content -LiteralPath $tunnel -Raw
$lookup = 'if !features.Android {'
if ([regex]::Matches($source, [regex]::Escape($lookup)).Count -ne 1) {
    throw 'Recheck the HarmonyOS package-owner overlay against the pinned mihomo revision'
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$stage = Join-Path $output ('.core-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$variables = @{ GOOS = 'openharmony'; GOARCH = 'arm64'; CGO_ENABLED = '1'; CC = $clang; GOTOOLCHAIN = 'local' }
$previous = @{}
Push-Location $coreDir
try {
    foreach ($entry in $variables.GetEnumerator()) {
        $previous[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    # Keep the official checkout pristine while routing HarmonyOS lookups through the VPN callback.
    $replacement = Join-Path $stage 'tunnel.go'
    $overlay = Join-Path $stage 'overlay.json'
    [IO.File]::WriteAllText($replacement, $source.Replace($lookup, 'if !features.Android && runtime.GOOS != "openharmony" {'))
    [IO.File]::WriteAllText($overlay, (ConvertTo-Json -InputObject @{ Replace = @{ $tunnel = $replacement } } -Depth 3))
    $library = Join-Path $stage 'libflclash.so'
    & $go build -mod=readonly -buildmode=c-shared -tags=with_gvisor "-overlay=$overlay" "-ldflags=-s -w -X github.com/metacubex/mihomo/constant.Version=$version" -o $library ./cmd/ohos
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS Go Core build failed' }
    Move-Item -LiteralPath $library -Destination (Join-Path $output 'libflclash.so') -Force
} finally {
    Pop-Location
    foreach ($entry in $previous.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    foreach ($file in 'libflclash.so', 'libflclash.h', 'tunnel.go', 'overlay.json') {
        $path = Join-Path $stage $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $stage
}

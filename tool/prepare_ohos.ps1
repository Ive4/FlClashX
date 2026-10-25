$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$overridePath = "$root/pubspec_overrides.yaml"
if (Test-Path $overridePath) {
    throw 'pubspec_overrides.yaml already exists; preserve it before preparing HarmonyOS'
}
$config = Get-Content "$root/.dart_tool/package_config.json" -Raw | ConvertFrom-Json
$manifest = [IO.File]::ReadAllText("$root/pubspec.yaml")
$existing = [regex]::Match($manifest, '(?m)^dependency_overrides:\r?\n(?:[ \t]+[^\r\n]*\r?\n|\r?\n)*')
$overrides = @($existing.Value.TrimEnd())
if (!$existing.Success) { $overrides = @('dependency_overrides:') }
foreach ($name in @('material_ui', 'cupertino_ui')) {
    $package = $config.packages | Where-Object name -eq $name
    $destination = "$root/.dart_tool/ohos-packages/$name"
    if (!(Test-Path $destination)) {
        $source = ([Uri]$package.rootUri).LocalPath
        New-Item -ItemType Directory -Force $destination | Out-Null
        Copy-Item "$source/*" $destination -Recurse
        Get-ChildItem "$destination/lib" -Recurse -Filter '*.dart' | ForEach-Object {
            $text = [IO.File]::ReadAllText($_.FullName)
            $text = $text.Replace('case TargetPlatform.android:', 'case TargetPlatform.ohos: case TargetPlatform.android:')
            $text = [regex]::Replace($text, 'TargetPlatform\.android(\s*(?:\|\||=>))', 'TargetPlatform.ohos || TargetPlatform.android$1')
            [IO.File]::WriteAllText($_.FullName, $text)
        }
    }
    $overrides += "  ${name}:"
    $overrides += "    path: .dart_tool/ohos-packages/$name"
}
$sourceRoot = "$root/.dart_tool/ohos-sqlite"
$sqliteSource = "$sourceRoot/sqlite-amalgamation-3540100/sqlite3.c"
if (!(Test-Path $sqliteSource)) {
    New-Item -ItemType Directory -Force $sourceRoot | Out-Null
    $archive = "$sourceRoot/sqlite.zip"
    Invoke-WebRequest 'https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip' -OutFile $archive
    $digest = & python -c 'import hashlib,sys; print(hashlib.sha3_256(open(sys.argv[1], "rb").read()).hexdigest())' $archive
    if ($LASTEXITCODE -ne 0 -or $digest -ne '92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30') {
        throw 'SQLite source checksum mismatch'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $sourceRoot -Force
}
$sqlitePackage = $config.packages | Where-Object name -eq sqlite3
$sqliteDestination = "$root/.dart_tool/ohos-packages/sqlite3"
if (!(Test-Path $sqliteDestination)) {
    New-Item -ItemType Directory -Force $sqliteDestination | Out-Null
    Copy-Item "$(([Uri]$sqlitePackage.rootUri).LocalPath)/*" $sqliteDestination -Recurse
}
Copy-Item $sqliteSource "$sqliteDestination/sqlite3.c" -Force
$hookPath = "$sqliteDestination/hook/build.dart"
$hook = [IO.File]::ReadAllText($hookPath)
$replacement = @'
    final compiler = input.config.code.cCompiler?.compiler;
    final isOhos = compiler?.path.contains('openharmony') ?? false;
    final sqlite = isOhos
        ? CompileSqlite(
            sourceFiles: [input.packageRoot.resolve('sqlite3.c').toFilePath()],
            defines: CompilerDefines.defaults(false),
            additionalIncludes: [],
            additionalFlags: [
              '--target=aarch64-linux-ohos',
              '--sysroot=${File.fromUri(compiler!).parent.parent.parent.path}/sysroot',
            ],
            additionalLibraryDirectories: [],
            additionalLibraries: [],
          )
        : SqliteBinary.forBuild(input);
'@
$hook = $hook.Replace('    final sqlite = SqliteBinary.forBuild(input);', $replacement)
$hook = $hook.Replace("input.outputDirectory.resolve('sqlite.map').path", "input.outputDirectory.resolve('sqlite.map').toFilePath()")
[IO.File]::WriteAllText($hookPath, $hook)
$overrides += @('  sqlite3:', '    path: .dart_tool/ohos-packages/sqlite3')
$overrides | Set-Content $overridePath -Encoding utf8

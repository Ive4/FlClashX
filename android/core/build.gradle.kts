import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.io.ByteArrayOutputStream
import javax.inject.Inject

plugins {
    id("com.android.library")
}

android {
    namespace = "com.follow.clash.core"
    compileSdk = libs.versions.compileSdk.get().toInt()
    ndkVersion = libs.versions.ndkVersion.get()

    defaultConfig {
        minSdk = libs.versions.minSdk.get().toInt()
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

val coreTargets =
    (rootProject.findProperty("target-platform") as String?)
        ?.split(",")?.map { it.trim() }?.distinct()
        ?: listOf("android-arm", "android-arm64", "android-x64")

val cargoExecutable = providers.provider {
    val name = if (System.getProperty("os.name").startsWith("Windows")) "cargo.exe" else "cargo"
    val cargoHome = System.getenv("CARGO_HOME") ?: File(System.getProperty("user.home"), ".cargo").path
    val search = listOf(File(cargoHome, "bin").path) + System.getenv("PATH").orEmpty().split(File.pathSeparator)
    search.map { File(it, name) }.firstOrNull { it.canExecute() }?.path
        ?: throw GradleException("The Rust Core requires cargo on PATH; install Rust and the Android Rust targets")
}

abstract class BuildRustCore : DefaultTask() {
    @get:Inject
    abstract val execOperations: ExecOperations

    @get:Inject
    abstract val fileSystemOperations: FileSystemOperations

    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sources: ConfigurableFileCollection

    @get:Internal
    abstract val moduleDirectory: DirectoryProperty

    @get:Input
    abstract val cargo: Property<String>

    @get:Input
    abstract val toolchainVersion: Property<String>

    @get:Input
    abstract val targets: ListProperty<String>

    @get:Input
    abstract val androidApi: Property<Int>

    @get:Input
    abstract val coreFeatures: Property<String>

    @get:Input
    abstract val nativeEnvironment: MapProperty<String, String>

    @get:Internal
    abstract val sdkDirectory: DirectoryProperty

    @get:Internal
    abstract val ndkDirectory: DirectoryProperty

    @get:Input
    abstract val ndkVersion: Property<String>

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun build() {
        val windows = System.getProperty("os.name").startsWith("Windows")
        val host = when {
            windows -> "windows-x86_64"
            System.getProperty("os.name").startsWith("Mac") -> "darwin-x86_64"
            else -> "linux-x86_64"
        }
        val ndk = ndkDirectory.get().asFile
        val llvm = ndk.resolve("toolchains/llvm/prebuilt/$host")
        val executable = if (windows) ".exe" else ""
        val bin = llvm.resolve("bin")
        val libclangCandidates = listOf("lib", "lib64", "bin").map { llvm.resolve(it) } +
            listOfNotNull(System.getenv("LIBCLANG_PATH")?.let { File(it) }) +
            listOf(File(System.getenv("ProgramFiles").orEmpty(), "LLVM/bin"),
                File("/opt/homebrew/opt/llvm/lib"), File("/usr/local/opt/llvm/lib")) +
            File("/usr/lib").listFiles().orEmpty().filter { it.name.startsWith("llvm-") }.map { it.resolve("lib") }
        val libclang = libclangCandidates
            .firstOrNull { it.listFiles()?.any { file -> file.name.startsWith("libclang.") } == true }
            ?: throw GradleException("Install LLVM/libclang and set LIBCLANG_PATH; this NDK ships no host libclang")
        val cmakeBin = sdkDirectory.get().asFile.resolve("cmake").listFiles()
            ?.filter { it.isDirectory }?.sortedByDescending { it.name }
            ?.map { it.resolve("bin") }?.firstOrNull { it.resolve("cmake$executable").isFile }
        val path = listOfNotNull(cmakeBin?.path, bin.path, File(cargo.get()).parent)
            .joinToString(File.pathSeparator) + File.pathSeparator + System.getenv("PATH").orEmpty()
        val staged = temporaryDir.resolve("jni-staging")
        val cargoTarget = temporaryDir.resolve("cargo")
        val api = androidApi.get()
        val targetMap = mapOf(
            "android-arm" to Triple("armeabi-v7a", "armv7-linux-androideabi", "armv7a-linux-androideabi"),
            "android-arm64" to Triple("arm64-v8a", "aarch64-linux-android", "aarch64-linux-android"),
            "android-x64" to Triple("x86_64", "x86_64-linux-android", "x86_64-linux-android"),
        )
        fileSystemOperations.delete { delete(staged) }
        for (platform in targets.get()) {
            val (abi, rustTarget, clangTarget) = targetMap[platform]
                ?: throw GradleException("No Rust Core for Flutter target platform $platform")
            val suffix = rustTarget.replace('-', '_')
            val linker = bin.resolve("$clangTarget$api-clang${if (windows) ".cmd" else ""}")
            if (!linker.isFile) throw GradleException("Missing NDK linker $linker")
            val flags = "--target=$clangTarget$api --sysroot=\"${llvm.resolve("sysroot").path}\""
            val cmakeToolchain = temporaryDir.resolve("$abi.cmake")
            cmakeToolchain.writeText(
                "set(ANDROID_ABI \"$abi\")\n" +
                    "set(ANDROID_PLATFORM android-$api)\n" +
                    "set(ANDROID_STL c++_shared)\n" +
                    "include(\"${ndk.resolve("build/cmake/android.toolchain.cmake").invariantSeparatorsPath}\")\n",
            )
            val environment = mapOf(
                "PATH" to path,
                "ANDROID_NDK_HOME" to ndk.path,
                "LIBCLANG_PATH" to libclang.path,
                "CMAKE_GENERATOR" to "Ninja",
                "CC_SHELL_ESCAPED_FLAGS" to "1",
                "CARGO_TARGET_${suffix.uppercase()}_LINKER" to linker.path,
                "CC_$suffix" to bin.resolve("clang$executable").path,
                "CXX_$suffix" to bin.resolve("clang++$executable").path,
                "AR_$suffix" to bin.resolve("llvm-ar$executable").path,
                "CFLAGS_$suffix" to flags,
                "CXXFLAGS_$suffix" to flags,
                "BINDGEN_EXTRA_CLANG_ARGS_$suffix" to flags,
                "CMAKE_TOOLCHAIN_FILE_$suffix" to cmakeToolchain.path,
                "BORING_BSSL_RUST_CPPLIB_$suffix" to "c++_shared",
            )
            execOperations.exec {
                workingDir(moduleDirectory)
                environment(environment)
                commandLine(
                    listOf(cargo.get(), "build", "--locked", "--release", "--lib", "--target", rustTarget,
                        "--target-dir", cargoTarget.path) +
                        if (coreFeatures.get().isEmpty()) emptyList() else listOf("--features", coreFeatures.get()),
                )
            }
            val built = cargoTarget.resolve("$rustTarget/release/libflclash.so")
            if (!built.isFile || built.length() == 0L) throw GradleException("Cargo produced no $built")
            val abiDirectory = staged.resolve(abi).apply { mkdirs() }
            built.copyTo(abiDirectory.resolve("libflclash.so"), overwrite = true)
            val runtimeTriple = if (abi == "armeabi-v7a") "arm-linux-androideabi" else clangTarget
            val cxxRuntime = llvm.resolve("sysroot/usr/lib/$runtimeTriple/libc++_shared.so")
            if (!cxxRuntime.isFile) throw GradleException("Missing NDK C++ runtime $cxxRuntime")
            cxxRuntime.copyTo(abiDirectory.resolve("libc++_shared.so"), overwrite = true)
        }
        fileSystemOperations.sync {
            from(staged)
            into(outputDirectory)
        }
    }
}

val rustModule = rootProject.layout.projectDirectory.dir("../core/rust")
val buildConfig = providers.fileContents(rootProject.layout.projectDirectory.file("../build_config.yaml")).asText
val nativeBuildEnvironment = providers.provider {
    System.getenv().filterKeys { key ->
        key in setOf("PATH", "RUSTUP_TOOLCHAIN", "RUSTC", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "LIBCLANG_PATH") ||
            listOf("CARGO_", "CC", "CXX", "AR", "CFLAGS", "CXXFLAGS", "CMAKE_", "BORING_", "BINDGEN_", "NASM")
                .any { key.startsWith(it) }
    }
}

androidComponents {
    onVariants { variant ->
        val buildCore = tasks.register<BuildRustCore>("build${variant.name.replaceFirstChar { it.uppercase() }}RustCore") {
            sources.from(
                fileTree(rustModule) { exclude("target/**", "target-ohos/**", ".git/**") },
                rootProject.layout.projectDirectory.file("../build_config.yaml"),
                rootProject.fileTree("../.cargo"),
                rootProject.fileTree("..") { include("rust-toolchain", "rust-toolchain.toml") },
            )
            moduleDirectory.set(rustModule)
            cargo.set(cargoExecutable)
            toolchainVersion.set(cargoExecutable.map { executable ->
                val version = ByteArrayOutputStream()
                execOperations.exec {
                    workingDir(rustModule)
                    commandLine(executable, "--version", "--verbose")
                    standardOutput = version
                }
                execOperations.exec {
                    workingDir(rustModule)
                    commandLine(File(executable).resolveSibling(if (System.getProperty("os.name").startsWith("Windows")) "rustc.exe" else "rustc"), "-Vv")
                    standardOutput = version
                }
                version.toString().trim()
            })
            targets.set(coreTargets)
            androidApi.set(libs.versions.minSdk.get().toInt())
            coreFeatures.set(buildConfig.map { text ->
                Regex("""(?m)^core_features:\s*(.*?)\s*$""").find(text)?.groupValues?.get(1)?.trim('"', '\'') ?: ""
            })
            nativeEnvironment.set(nativeBuildEnvironment)
            sdkDirectory.set(androidComponents.sdkComponents.sdkDirectory)
            ndkDirectory.set(androidComponents.sdkComponents.ndkDirectory)
            ndkVersion.set(libs.versions.ndkVersion)
        }
        variant.sources.jniLibs?.addGeneratedSourceDirectory(buildCore, BuildRustCore::outputDirectory)
    }
}

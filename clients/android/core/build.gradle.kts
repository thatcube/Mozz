plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
}

// --- Which architectures ---------------------------------------------------
//
// The Android ABIs the app can carry are exactly the ones whose Swift core has
// been cross-compiled and staged. Deriving `abiFilters` from this list rather
// than hand-keeping the two in parallel is what stops a build asking CMake to
// link a `libMozzFFI.so` that was never built — the failure mode this replaced.
//
// arm64-v8a is every modern phone, and the Apple-silicon emulator too, so it is
// the default. armeabi-v7a is deliberately unsupported: a 32-bit build would
// need its own ~150 MB Swift runtime payload for a population that cannot run
// this app well anyway.
val abiForArch = mapOf("aarch64" to "arm64-v8a", "x86_64" to "x86_64")

val swiftArchitectures: List<String> =
    (providers.gradleProperty("mozz.swiftArchs").orNull ?: "aarch64")
        .split(",").map { it.trim() }.filter { it.isNotEmpty() }

val androidAbis: List<String> =
    swiftArchitectures.map { abiForArch[it] ?: error("no Android ABI is mapped to '$it'") }

android {
    namespace = "com.thatcube.mozz.core"
    compileSdk = 37

    defaultConfig {
        // 28 matches the `…-android28` triples the Swift Android SDK is built
        // for. Raising it means re-pinning those; lowering it is not possible.
        minSdk = 28

        ndk {
            abiFilters += androidAbis
        }

        consumerProguardFiles("consumer-rules.pro")
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    ndkVersion = "27.3.13750724"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    defaultConfig {
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)
    api(libs.kotlinx.serialization.json)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestRuntimeOnly(libs.androidx.test.runner)
}

// --- The Swift core --------------------------------------------------------
//
// `libMozzFFI.so` is not built by Gradle. It is the repository's Swift core,
// cross-compiled by the same script the spike uses, then staged here alongside
// the Swift Android runtime objects it needs at load time. Keeping one script
// for the spike and the app means the thing CI proves is the thing that ships.

val repoRoot: File = rootDir.parentFile.parentFile

val buildSwiftCore = tasks.register("buildSwiftCore") {
    group = "mozz"
    description = "Cross-compiles the Swift core for each Android ABI."

    // Only the inputs the script actually reads. `Sources/**` is the whole core;
    // a change anywhere in it can change the .so.
    inputs.dir(File(repoRoot, "Sources")).withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.file(File(repoRoot, "Package.swift"))
    inputs.file(File(repoRoot, "spike/android-ffi/build-local.sh"))
    inputs.property("architectures", swiftArchitectures)
    outputs.dirs(swiftArchitectures.map { File(repoRoot, ".build/android-stage-$it") })

    doLast {
        swiftArchitectures.forEach { arch ->
            providers.exec {
                workingDir = repoRoot
                commandLine("./spike/android-ffi/build-local.sh", "--arch", arch)
            }.result.get().assertNormalExitValue()
        }
    }
}

val stageSwiftCore = tasks.register<Sync>("stageSwiftCore") {
    group = "mozz"
    // Sync, not Copy: jniLibs is generated, and a library that stops being part
    // of the payload has to stop being in the APK. A Copy would leave the old
    // one behind forever — which is how a test framework ends up shipping.
    description = "Stages libMozzFFI.so and the Swift Android runtime into jniLibs."
    dependsOn(buildSwiftCore)

    into(layout.projectDirectory.dir("src/main/jniLibs"))
    swiftArchitectures.forEach { arch ->
        val abi = abiForArch.getValue(arch)
        from(File(repoRoot, ".build/android-stage-$arch")) {
            include("*.so")
            into(abi)
        }
    }
}

// CMake links against the staged libMozzFFI.so, so staging has to happen before
// any native build — not merely before packaging.
tasks.withType<com.android.build.gradle.tasks.ExternalNativeBuildTask>().configureEach {
    dependsOn(stageSwiftCore)
}
tasks.named("preBuild") { dependsOn(stageSwiftCore) }

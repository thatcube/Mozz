// Kept in step with :core — an APK can only split along the ABIs whose Swift
// core was actually staged. See core/build.gradle.kts.
val androidAbis: List<String> =
    (providers.gradleProperty("mozz.swiftArchs").orNull ?: "aarch64")
        .split(",").map { it.trim() }.filter { it.isNotEmpty() }
        .map { mapOf("aarch64" to "arm64-v8a", "x86_64" to "x86_64")[it] ?: error("unmapped arch '$it'") }

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.thatcube.mozz"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.brando.mozz"
        minSdk = 28
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    androidResources {
        // The analyzer's weights are read as a file, not as a stream, and an
        // asset only has a file descriptor when it is stored uncompressed.
        // They are half-precision floats, so compression buys almost nothing
        // and costs a decompression pass on first run.
        noCompress += "bin"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    // The Swift runtime payload is large and unstripped. Splitting by ABI keeps
    // a phone from carrying the emulator's x86_64 copy of all of it.
    splits {
        abi {
            isEnable = true
            reset()
            include(*androidAbis.toTypedArray())
            isUniversalApk = false
        }
    }

    buildFeatures {
        compose = true
        // Needed only to tell a debug build from a release one at runtime, which
        // gates the image logger — it prints artwork URLs, and those carry the
        // server token.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    sourceSets {
    }
}

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.work.runtime)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.adaptive)
    implementation(libs.androidx.adaptive.layout)
    implementation(libs.androidx.adaptive.navigation)

    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.session)

    debugImplementation(libs.androidx.compose.ui.tooling)
    androidTestImplementation(libs.androidx.test.junit)
}

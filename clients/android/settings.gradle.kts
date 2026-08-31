// Mozz for Android.
//
// The music logic is not here. `Sources/` at the repository root is Swift,
// cross-compiled to `libMozzFFI.so` and driven over a C ABI — the same code the
// iOS app and the desktop app run. This project is a window, a queue and an
// audio engine. See ../../docs/adr/ADR-0014-android-support.md.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode = RepositoriesMode.FAIL_ON_PROJECT_REPOS
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "mozz-android"

include(":app")
include(":core")

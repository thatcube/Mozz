cmake_minimum_required(VERSION 3.22.1)
project(mozzjni C)

# libMozzFFI.so is not built here — it is the Swift core, cross-compiled by
# ../../../../../spike/android-ffi/build-local.sh and staged into jniLibs by the
# `stageSwiftCore` Gradle task. Importing it (rather than dlopen + dlsym) means
# a signature drift between the @_cdecl declarations and this shim is a link
# error at build time instead of a crash on a user's phone.
add_library(MozzFFI SHARED IMPORTED)
set_target_properties(MozzFFI PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libMozzFFI.so)

add_library(mozzjni SHARED mozz_jni.c)

# 16 KB page alignment, which Android 15+ devices require and Google Play
# requires of anything targeting Android 15 or later.
#
# NDK r27 still links with a 4 KB max page size by default, so this is not
# inherited from anywhere — and the failure is quiet: the library loads fine on a
# 4 KB device and the APK is simply rejected later. The Swift core is already
# built 16 KB aligned by its own toolchain, which is what made this easy to miss:
# 25 of the 26 libraries in the payload were correct and only the shim was not.
target_link_options(mozzjni PRIVATE "-Wl,-z,max-page-size=16384")

target_link_libraries(mozzjni MozzFFI)

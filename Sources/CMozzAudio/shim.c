/*
 * SwiftPM requires a C target to contain at least one source file, even when
 * the target exists only to publish headers. This is that file.
 *
 * The implementation lives in the Rust staticlib, which is linked separately -
 * see tools/build-audio-staticlib.sh. Nothing should ever be added here: a
 * function defined on this side would be one the shared engine does not have,
 * which is the whole class of divergence the engine exists to remove.
 */

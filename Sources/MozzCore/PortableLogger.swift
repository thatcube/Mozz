#if !canImport(os)
import Foundation

// MARK: - A stand-in for os.Logger off Apple platforms
//
// Several modules log through `os.Logger`, using its structured interpolation:
//
//     syncLog.notice("phase \(phase.rawValue, privacy: .public): \(count) items")
//
// That `privacy:` label is not ordinary string interpolation — it is part of
// `OSLogInterpolation`, and it does not exist anywhere but Apple's `os` module.
// So a module that logs this way simply does not compile on Windows or Linux.
//
// The obvious fix is to wrap every call site in `#if canImport(os)`. That works
// and changes nothing on Apple, but it puts a conditional around five lines in
// one file today and around every future log line forever, which is the kind of
// tax that eventually gets paid by not logging.
//
// Instead this declares a `Logger` with the same call shape, compiled ONLY where
// `os` is absent. On Apple nothing here exists at all and `os.Logger` is used
// exactly as before — the logging code is not merely equivalent, it is the same
// code reaching the same API. Off Apple, `import MozzCore` supplies this one.
//
// The interpolation accepts and discards `privacy:` because there is no system
// log to redact into: output goes to stderr, which on these platforms is either
// a developer's console or nothing.

/// Mirrors `OSLogPrivacy`'s spelling so call sites need no change.
public struct LogPrivacy: Sendable {
    public static let `public` = LogPrivacy()
    public static let `private` = LogPrivacy()
    public static let auto = LogPrivacy()
    public static let sensitive = LogPrivacy()
}

/// Mirrors the subset of `OSLogMessage` that Mozz actually constructs.
public struct LogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol {
        var text: String

        public init(literalCapacity: Int, interpolationCount: Int) {
            text = ""
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation(_ value: String) {
            text += value
        }

        public mutating func appendInterpolation(_ value: String, privacy: LogPrivacy) {
            text += value
        }

        public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: T) {
            text += value.description
        }

        public mutating func appendInterpolation<T: CustomStringConvertible>(
            _ value: T, privacy: LogPrivacy
        ) {
            text += value.description
        }

        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T) {
            text += String(value)
        }

        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: LogPrivacy) {
            text += String(value)
        }
    }

    public let text: String

    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
}

/// A stderr logger with `os.Logger`'s surface.
///
/// stderr rather than a file: on Windows and Linux a user running the app from a
/// terminal to find out why it misbehaves is exactly who this output is for, and
/// a log file nobody knows about helps nobody. A real log destination is a
/// packaging decision for whenever these platforms ship, not a core one.
public struct Logger: Sendable {
    private let prefix: String

    public init(subsystem: String = "com.thatcube.Mozz", category: String = "") {
        prefix = category.isEmpty ? subsystem : "\(subsystem) [\(category)]"
    }

    public func trace(_ message: LogMessage) { emit("TRACE", message) }
    public func debug(_ message: LogMessage) { emit("DEBUG", message) }
    public func info(_ message: LogMessage) { emit("INFO", message) }
    public func notice(_ message: LogMessage) { emit("NOTICE", message) }
    public func warning(_ message: LogMessage) { emit("WARNING", message) }
    public func error(_ message: LogMessage) { emit("ERROR", message) }
    public func critical(_ message: LogMessage) { emit("CRITICAL", message) }
    public func fault(_ message: LogMessage) { emit("FAULT", message) }

    private func emit(_ level: String, _ message: LogMessage) {
        FileHandle.standardError.write(Data("\(prefix) \(level): \(message.text)\n".utf8))
    }
}
#endif

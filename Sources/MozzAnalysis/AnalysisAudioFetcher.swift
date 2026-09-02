import Foundation
import MozzCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetch at most `maxBytes` from a URL. The seam the analysis pass fetches
/// through, so tests hand it bytes from disk instead of a socket.
public typealias AnalysisAudioLoader = @Sendable (_ url: URL, _ maxBytes: Int) async throws -> Data

/// A GET that stops the moment it has enough.
///
/// This exists because an analysis stream has no end we can predict. Every
/// backend serves it as an on-demand transcode: no `Content-Length`, no ranges,
/// and the server keeps encoding for as long as we keep reading. `data(for:)`
/// would therefore transcode and download whole songs to look at ninety seconds
/// of them — across a library, that is the difference between a background job
/// and a data plan.
///
/// So the transfer is a delegate rather than a one-shot: bytes accumulate, and
/// the first callback that crosses the cap cancels the task. Cancelling is what
/// tells the server to stop transcoding, which is the saving that actually
/// matters — the bytes we would have thrown away were never encoded.
///
/// Deliberately not `URLSession.bytes`: this has to run wherever the core runs,
/// and the Android build is on swift-corelibs-foundation, whose reliable path
/// is the delegate one.
public enum AnalysisAudioFetcher {
    /// The production loader.
    ///
    /// - Parameter timeout: inactivity allowance. Generous, because the first
    ///   byte waits on the server starting an ffmpeg.
    public static func live(timeout: TimeInterval = 60) -> AnalysisAudioLoader {
        { url, maxBytes in
            try await BoundedFetch(maxBytes: maxBytes, timeout: timeout).run(url)
        }
    }
}

/// One capped transfer. Single-use: `run` is called once, and the object dies
/// with the response.
private final class BoundedFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let timeout: TimeInterval

    // Every mutable field below is touched from both the delegate queue and the
    // calling task, so all of them are behind this one lock.
    private let lock = NSLock()
    private var buffer = Data()
    private var resume: ((Result<Data, any Error>) -> Void)?
    private var session: URLSession?
    private var settled = false
    /// Set when WE cancelled because the cap was reached, so the cancellation
    /// error that follows is recognised as success rather than reported.
    private var satisfied = false
    /// The status of a response we are reading only to quote back. A server
    /// that refuses says why in the body, and on a phone that sentence is the
    /// entire diagnosis — nobody is watching a console.
    private var errorStatus: Int?

    init(maxBytes: Int, timeout: TimeInterval) {
        self.maxBytes = max(maxBytes, 1)
        self.timeout = timeout
    }

    func run(_ url: URL) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = timeout
                config.timeoutIntervalForResource = timeout * 4
                config.httpShouldUsePipelining = false
                // No disk cache: this is a one-shot read of a transcode that
                // will never be requested again.
                config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

                lock.lock()
                if settled {                      // cancelled before we started
                    lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: MozzError.cancelled)
                    return
                }
                resume = { continuation.resume(with: $0) }
                self.session = session
                lock.unlock()

                session.dataTask(with: url).resume()
            }
        } onCancel: {
            self.settle(.failure(MozzError.cancelled))
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            settle(.failure(MozzError.invalidResponse))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            // Read a little of the refusal rather than discarding it.
            lock.lock()
            errorStatus = http.statusCode
            lock.unlock()
            completionHandler(.allow)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        let status = errorStatus
        let cap = status == nil ? maxBytes : Self.errorBodyBytes
        let full = buffer.count >= cap
        if full { satisfied = true }
        let payload = full ? buffer : Data()
        lock.unlock()

        guard full else { return }
        dataTask.cancel()   // stops the server transcoding, not just our reading
        if let status {
            settle(.failure(Self.refusal(status: status, body: payload)))
        } else {
            settle(.success(payload))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else {
            lock.lock(); let payload = buffer; let status = errorStatus; lock.unlock()
            if let status {
                settle(.failure(Self.refusal(status: status, body: payload)))
            } else {
                settle(.success(payload))
            }
            return
        }
        lock.lock(); let ours = satisfied; lock.unlock()
        if ours { return }  // our own cap-cancel; `settle` already ran
        settle(.failure(Self.map(error)))
    }

    // MARK: -

    /// Deliver the first outcome and drop everything. Later outcomes are
    /// ignored: a cap-cancel is always followed by a cancellation error, and a
    /// continuation resumed twice is a crash.
    private func settle(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        let resume = self.resume
        let session = self.session
        self.resume = nil
        self.session = nil
        lock.unlock()

        // Breaks the session's strong reference to this delegate; without it
        // every analyzed track leaks one session.
        session?.invalidateAndCancel()
        resume?(result)
    }

    /// How much of a refusal is worth quoting. Enough for Plex's one-line
    /// reason, not enough to paste an error page into a Settings row.
    private static let errorBodyBytes = 512

    /// The status, plus whatever the server said about it.
    ///
    /// `MozzError.transport` rather than `badStatus`, which carries only a
    /// number — the number is the part we already knew.
    private static func refusal(status: Int, body: Data) -> any Error {
        let text = String(decoding: body.prefix(errorBodyBytes), as: UTF8.self)
        let reason = scrubbed(text)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(200)
        guard !reason.isEmpty else { return MozzError.badStatus(status) }
        return MozzError.transport("the server answered \(status): \(reason)")
    }

    /// Servers echo the request back in error pages, and the request carries a
    /// token. This ends up on screen, so the token does not.
    private static func scrubbed(_ text: String) -> String {
        var out = text
        for key in ["X-Plex-Token", "api_key", "token", "t", "p", "s"] {
            guard let regex = try? NSRegularExpression(
                pattern: "\(NSRegularExpression.escapedPattern(for: key))=[^&\\s\"'<>]+",
                options: [.caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: "\(key)=REDACTED")
        }
        return out
    }

    private static func map(_ error: any Error) -> any Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled:
            return MozzError.cancelled
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .networkConnectionLost, .timedOut, .dnsLookupFailed, .secureConnectionFailed:
            return MozzError.serverUnreachable
        default:
            return MozzError.transport(urlError.localizedDescription)
        }
    }
}

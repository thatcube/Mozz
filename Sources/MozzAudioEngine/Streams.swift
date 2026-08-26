import Foundation
import MozzAudioEngine

/// Reads a track from a file on disk.
///
/// The simple case, and the one downloads use. Kept separate from the HTTP
/// stream rather than folded into it, because a local file needs none of the
/// range requests, retries or buffering that a network stream does, and a
/// single class doing both would carry that machinery into the path that has
/// no use for it.
public final class FileStream: AudioEngine.Stream {
    private let handle: FileHandle
    private var closed = false

    public init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
    }

    public func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard !closed, count > 0 else { return 0 }
        guard let data = try? handle.read(upToCount: count), !data.isEmpty else { return 0 }
        data.copyBytes(to: buffer, count: data.count)
        return data.count
    }

    public func seek(offset: Int64, origin: Int32) -> Int64 {
        guard !closed else { return -1 }

        // Read the current position BEFORE asking for the size, because
        // seekToEnd moves the file offset. Doing it the other way round makes
        // every seek-from-current behave as a seek-from-end, which a decoder
        // probing a container reads as a file that keeps ending early.
        let current = Int64((try? handle.offset()) ?? 0)
        let size = Int64((try? handle.seekToEnd()) ?? 0)

        let base: Int64
        switch origin {
        case 1: base = current
        case 2: base = size
        default: base = 0
        }
        let target = UInt64(max(0, min(base + offset, size)))
        do {
            try handle.seek(toOffset: target)
        } catch {
            return -1
        }
        return Int64(target)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

/// Reads a track from a media server over HTTP, with the caller's credentials.
///
/// `AVQueuePlayer` did this invisibly, which is most of why it was worth
/// keeping for so long. Doing it here is the price of one engine instead of
/// three, and it buys something back: the same streaming behaviour on every
/// platform, rather than whatever each OS media framework happens to do.
///
/// ## Blocking is correct here
///
/// Every method blocks the calling thread. That looks alarming and is exactly
/// right: the engine only ever calls these from its decode thread, never from
/// the audio callback, and that thread's whole job is to get ahead of playback.
/// A decode thread that blocks for 200ms on a slow server is a decode thread
/// doing its job; the ring it feeds is what protects the sound.
///
/// ## Seeking
///
/// Seeks are served by a fresh ranged request rather than by buffering the
/// whole file. A range that the server ignores - some return 200 and the whole
/// body instead of 206 - is detected and treated as a failure rather than
/// silently producing audio from the wrong offset, which would sound like a
/// corrupt file.
public final class HTTPStream: AudioEngine.Stream {
    private let request: URLRequest
    private let session: URLSession
    private let timeout: TimeInterval

    /// Bytes already delivered, which is also the offset the next request needs.
    private var position: Int64 = 0
    /// Total length, once the server has told us. Nil until the first response.
    private var totalLength: Int64?
    /// Whatever the last response delivered that has not been read yet.
    private var buffered = Data()
    /// Absolute offset the buffer starts at.
    private var bufferStart: Int64 = 0
    private var closed = false

    /// How much to ask for at a time.
    ///
    /// Large enough that a track is a handful of requests rather than hundreds,
    /// small enough that a seek does not first wait for megabytes nobody wants.
    private let chunkSize: Int

    public init(
        request: URLRequest,
        session: URLSession = .shared,
        chunkSize: Int = 512 * 1024,
        timeout: TimeInterval = 30
    ) {
        self.request = request
        self.session = session
        self.chunkSize = chunkSize
        self.timeout = timeout
    }

    public func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard !closed, count > 0 else { return 0 }

        if let totalLength, position >= totalLength {
            return 0
        }

        if !bufferCovers(position) {
            guard fetch(from: position) else { return -1 }
        }

        let offsetInBuffer = Int(position - bufferStart)
        guard offsetInBuffer >= 0, offsetInBuffer < buffered.count else { return 0 }

        let take = min(count, buffered.count - offsetInBuffer)
        buffered.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.update(from: base.advanced(by: offsetInBuffer).assumingMemoryBound(to: UInt8.self), count: take)
        }
        position += Int64(take)
        return take
    }

    public func seek(offset: Int64, origin: Int32) -> Int64 {
        guard !closed else { return -1 }

        let base: Int64
        switch origin {
        case 1:
            base = position
        case 2:
            // Seeking from the end needs the length, and the length only
            // arrives with a response. Ask for one byte rather than the file.
            if totalLength == nil, !fetch(from: 0, length: 1) { return -1 }
            base = totalLength ?? 0
        default:
            base = 0
        }

        var target = base + offset
        if target < 0 { target = 0 }
        if let totalLength, target > totalLength { target = totalLength }
        position = target
        return target
    }

    public func close() {
        guard !closed else { return }
        closed = true
        buffered = Data()
    }

    private func bufferCovers(_ offset: Int64) -> Bool {
        guard !buffered.isEmpty else { return false }
        return offset >= bufferStart && offset < bufferStart + Int64(buffered.count)
    }

    /// Fetch a range synchronously, replacing the buffer.
    private func fetch(from offset: Int64, length: Int? = nil) -> Bool {
        var ranged = request
        let want = length ?? chunkSize
        let end = offset + Int64(want) - 1
        ranged.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        ranged.timeoutInterval = timeout

        // A semaphore rather than async/await because the engine's decode
        // thread calls this synchronously and has nowhere to suspend to.
        let gate = DispatchSemaphore(value: 0)
        var payload: Data?
        var response: HTTPURLResponse?

        let task = session.dataTask(with: ranged) { data, urlResponse, _ in
            payload = data
            response = urlResponse as? HTTPURLResponse
            gate.signal()
        }
        task.resume()

        if gate.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            return false
        }

        guard let response, let payload else { return false }

        switch response.statusCode {
        case 206:
            // A proper partial response. Content-Range carries the true total,
            // which is the only reliable place to learn it.
            if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
                let total = contentRange.split(separator: "/").last,
                let parsed = Int64(total)
            {
                totalLength = parsed
            }
            bufferStart = offset
            buffered = payload
            return true

        case 200:
            // The server ignored the range and sent the whole body. Honest for
            // offset zero and wrong for anything else - accepting it there
            // would decode from the start while claiming to be elsewhere, which
            // sounds like a corrupt file rather than a bug.
            guard offset == 0 else { return false }
            totalLength = Int64(payload.count)
            bufferStart = 0
            buffered = payload
            return true

        case 416:
            // Asked past the end. Not a failure: it is how a stream ends when
            // the length was never announced.
            totalLength = offset
            buffered = Data()
            return true

        default:
            return false
        }
    }
}

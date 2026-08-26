import XCTest

@testable import MozzAudioEngine

/// These tests link the real Rust staticlib and drive real audio through it.
///
/// That is the point of them. A Swift wrapper that merely compiles proves the
/// header parses; it proves nothing about whether the symbols exist, whether
/// the struct layouts agree, or whether a Swift closure survives being called
/// from a Rust thread minutes later. Only running it shows that.
final class AudioEngineTests: XCTestCase {
    /// A stream the test owns, so the callback path is exercised rather than
    /// mocked away.
    final class MemoryStream: AudioEngine.Stream {
        private let bytes: [UInt8]
        private var position = 0
        private(set) var closeCount = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
            let take = min(count, bytes.count - position)
            if take > 0 {
                bytes.withUnsafeBufferPointer { source in
                    buffer.update(from: source.baseAddress! + position, count: take)
                }
                position += take
            }
            return take
        }

        func seek(offset: Int64, origin: Int32) -> Int64 {
            let base: Int64
            switch origin {
            case 1: base = Int64(position)
            case 2: base = Int64(bytes.count)
            default: base = 0
            }
            let landed = max(0, min(base + offset, Int64(bytes.count)))
            position = Int(landed)
            return landed
        }

        func close() { closeCount += 1 }
    }

    /// A mono 8 kHz WAV, built here so the samples are known exactly and no
    /// fixture file has to be committed.
    private func wav(frames: Int) -> [UInt8] {
        var out = [UInt8]()
        func u32(_ v: UInt32) { out.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u16(_ v: UInt16) { out.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }

        let data = UInt32(frames * 2)
        out.append(contentsOf: Array("RIFF".utf8)); u32(36 + data)
        out.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(data)
        for _ in 0..<frames { u16(UInt16(bitPattern: 8_000)) }
        return out
    }

    /// Poll for something the decode thread produces, rather than assuming a
    /// speed this machine may not have.
    private func eventually(
        _ description: String, _ condition: () -> Bool, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<400 {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }

    func testAnEngineStartsIdle() throws {
        let engine = try XCTUnwrap(AudioEngine(sampleRate: 8_000, channels: 1, bufferFrames: 8192))
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.positionSeconds, 0)
        engine.close()
    }

    /// The whole boundary in one test: Swift hands the engine a Swift object,
    /// Rust calls back into it from another thread, and audio comes out.
    func testAudioPlaysThroughSwiftSuppliedCallbacks() throws {
        let engine = try XCTUnwrap(AudioEngine(sampleRate: 8_000, channels: 1, bufferFrames: 8192))
        let stream = MemoryStream(wav(frames: 16_000))

        engine.playNow(stream: stream, trackID: 4242, fileExtension: "wav")

        eventually("the engine reaches playing") { engine.state == .playing }
        XCTAssertEqual(engine.currentTrackID, 4242)
        eventually("position advances") { engine.positionSeconds > 0.02 }
        XCTAssertFalse(engine.hasFailed)

        engine.close()
    }

    /// The stream is retained across the boundary and released by the engine's
    /// close callback. If that balance is wrong it is either a leak or a
    /// use-after-free on the decode thread, and neither is visible from Swift.
    func testTheStreamIsClosedExactlyOnce() throws {
        let engine = try XCTUnwrap(AudioEngine(sampleRate: 8_000, channels: 1, bufferFrames: 8192))
        let stream = MemoryStream(wav(frames: 4_000))

        engine.playNow(stream: stream, trackID: 1, fileExtension: "wav")
        eventually("playing") { engine.state == .playing }
        engine.close()

        eventually("the stream is closed") { stream.closeCount == 1 }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(stream.closeCount, 1, "closed more than once")
    }

    /// A caller that keeps using a closed engine must get defaults, not a
    /// crash — the crash report would blame the audio engine for a bug in a
    /// view controller.
    func testAClosedEngineIsInertRatherThanFatal() throws {
        let engine = try XCTUnwrap(AudioEngine(sampleRate: 8_000, channels: 1, bufferFrames: 4096))
        engine.close()
        engine.close()

        engine.pause()
        engine.resume()
        engine.stop()
        engine.seek(to: 30)
        engine.setReplayGain(mode: .track, preampDB: 3)
        engine.setEqualizer(gainsDB: [1, 2, 3], preampDB: 0, enabled: true)

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.positionSeconds, 0)
        XCTAssertEqual(engine.currentTrackID, 0)
        XCTAssertFalse(engine.hasFailed)
    }

    /// Handing a stream to a closed engine must still close it, or every such
    /// call leaks whatever the caller allocated.
    func testAStreamGivenToAClosedEngineIsStillClosed() throws {
        let engine = try XCTUnwrap(AudioEngine(sampleRate: 8_000, channels: 1, bufferFrames: 4096))
        engine.close()

        let stream = MemoryStream(wav(frames: 100))
        engine.playNow(stream: stream, trackID: 1, fileExtension: "wav")

        XCTAssertEqual(stream.closeCount, 1, "the stream leaked")
    }

    func testBytesThatAreNotAudioAreReportedRatherThanCrashing() throws {
        let engine = try XCTUnwrap(AudioEngine(sampleRate: 8_000, channels: 1, bufferFrames: 4096))
        engine.playNow(stream: MemoryStream([UInt8](repeating: 9, count: 64)), trackID: 3)

        eventually("the failure is reported") { engine.hasFailed }
        XCTAssertNotEqual(engine.state, .playing)
        engine.close()
    }

    /// Fewer than ten gains must pad rather than read past the end of the
    /// array into C.
    func testAShortEqualiserArrayIsPaddedRatherThanOverrunning() throws {
        let engine = try XCTUnwrap(AudioEngine(sampleRate: 8_000, channels: 1, bufferFrames: 4096))
        engine.setEqualizer(gainsDB: [6.0], preampDB: 0, enabled: true)
        engine.setEqualizer(gainsDB: Array(repeating: 1.0, count: 40), preampDB: 0, enabled: true)
        XCTAssertFalse(engine.hasFailed)
        engine.close()
    }
}

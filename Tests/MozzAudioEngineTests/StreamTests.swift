import XCTest

@testable import MozzAudioEngine

/// `AVQueuePlayer` did HTTP streaming invisibly, which is most of why it was
/// worth keeping for so long. These cover the behaviour that has to be
/// reproduced by hand now — and in particular the cases where a server does
/// something slightly wrong, because those are what turn into "this file is
/// corrupt" reports from users whose files are fine.
final class FileStreamTests: XCTestCase {
    private func temporaryFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mozz-stream-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    func testItReadsTheWholeFileInOrder() throws {
        let url = try temporaryFile([1, 2, 3, 4, 5])
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try XCTUnwrap(FileStream(url: url))
        var out = [UInt8](repeating: 0, count: 5)
        let read = out.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 5) }

        XCTAssertEqual(read, 5)
        XCTAssertEqual(out, [1, 2, 3, 4, 5])
        stream.close()
    }

    func testSeekingFromEachOriginLandsWhereItSays() throws {
        let url = try temporaryFile(Array(0..<100))
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try XCTUnwrap(FileStream(url: url))
        XCTAssertEqual(stream.seek(offset: 10, origin: 0), 10, "from the start")
        XCTAssertEqual(stream.seek(offset: 5, origin: 1), 15, "from the current position")
        XCTAssertEqual(stream.seek(offset: -20, origin: 2), 80, "from the end")

        var out = [UInt8](repeating: 0, count: 1)
        _ = out.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 1) }
        XCTAssertEqual(out[0], 80, "the byte read should match the reported position")
        stream.close()
    }

    /// A seek past either end must clamp rather than fail, because a decoder
    /// probing a container's index routinely asks for both.
    func testSeekingOutOfBoundsClamps() throws {
        let url = try temporaryFile(Array(0..<10))
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try XCTUnwrap(FileStream(url: url))
        XCTAssertEqual(stream.seek(offset: -999, origin: 0), 0)
        XCTAssertEqual(stream.seek(offset: 999, origin: 0), 10)
        stream.close()
    }

    func testReadingPastTheEndReturnsZeroRatherThanFailing() throws {
        let url = try temporaryFile([1, 2])
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try XCTUnwrap(FileStream(url: url))
        _ = stream.seek(offset: 0, origin: 2)
        var out = [UInt8](repeating: 0, count: 4)
        let read = out.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(read, 0, "the end of a file is zero bytes, not an error")
        stream.close()
    }

    func testAMissingFileIsNilRatherThanACrash() {
        let absent = URL(fileURLWithPath: "/no/such/file/anywhere")
        XCTAssertNil(FileStream(url: absent))
    }

    func testClosingTwiceIsSafe() throws {
        let url = try temporaryFile([1])
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = try XCTUnwrap(FileStream(url: url))
        stream.close()
        stream.close()

        var out = [UInt8](repeating: 0, count: 1)
        let read = out.withUnsafeMutableBufferPointer { stream.read(into: $0.baseAddress!, count: 1) }
        XCTAssertEqual(read, 0, "a closed stream reads as empty rather than crashing")
    }
}

/// Served by a real local HTTP server, because the interesting cases are all
/// about how a server behaves and a mocked URLSession would only assert what I
/// already believe.
final class HTTPStreamTests: XCTestCase {
    /// A deliberately minimal server that can be told to misbehave.
    final class Server {
        enum Behaviour {
            /// Correct: honours Range with 206 and a Content-Range.
            case ranged
            /// Ignores Range entirely and returns the whole body with 200.
            case ignoresRange
        }

        let port: UInt16
        let body: Data
        private let behaviour: Behaviour
        private let socket: Int32
        private var running = true

        init(body: Data, behaviour: Behaviour) {
            self.body = body
            self.behaviour = behaviour

            // Built into locals first: Swift will not let a closure capture
            // self until every stored property is assigned, and the socket
            // setup needs closures for the sockaddr rebinding.
            let listening = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(
                listening, SOL_SOCKET, SO_REUSEADDR, &yes,
                socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            // Port zero lets the OS choose, so tests running in parallel cannot
            // collide on a hard-coded number.
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")

            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = Darwin.bind(
                        listening, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            _ = Darwin.listen(listening, 8)

            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = getsockname(listening, $0, &length)
                }
            }

            self.socket = listening
            self.port = bound.sin_port.byteSwapped

            Thread.detachNewThread { [weak self] in self?.serve() }
        }

        var url: URL { URL(string: "http://127.0.0.1:\(port)/track.wav")! }

        func stop() {
            running = false
            if socket >= 0 { Darwin.close(socket) }
        }

        private func serve() {
            while running {
                let client = Darwin.accept(socket, nil, nil)
                if client < 0 { return }

                var request = [UInt8](repeating: 0, count: 4096)
                let received = Darwin.recv(client, &request, request.count, 0)
                let text = received > 0
                    ? String(decoding: request[0..<received], as: UTF8.self) : ""

                let response: Data
                switch behaviour {
                case .ignoresRange:
                    response = header(status: "200 OK", length: body.count, range: nil) + body
                case .ranged:
                    if let range = parseRange(text) {
                        let end = min(range.upper, body.count - 1)
                        if range.lower >= body.count {
                            response = header(status: "416 Range Not Satisfiable", length: 0, range: nil)
                        } else {
                            let slice = body[range.lower...end]
                            response = header(
                                status: "206 Partial Content", length: slice.count,
                                range: "bytes \(range.lower)-\(end)/\(body.count)") + slice
                        }
                    } else {
                        response = header(status: "200 OK", length: body.count, range: nil) + body
                    }
                }

                response.withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress, response.count, 0) }
                Darwin.close(client)
            }
        }

        private func header(status: String, length: Int, range: String?) -> Data {
            var text = "HTTP/1.1 \(status)\r\nContent-Length: \(length)\r\n"
            if let range { text += "Content-Range: \(range)\r\n" }
            text += "Accept-Ranges: bytes\r\n\r\n"
            return Data(text.utf8)
        }

        private func parseRange(_ request: String) -> (lower: Int, upper: Int)? {
            guard let line = request.split(separator: "\r\n").first(where: {
                $0.lowercased().hasPrefix("range:")
            }) else { return nil }
            guard let spec = line.split(separator: "=").last else { return nil }
            let parts = spec.split(separator: "-")
            guard parts.count == 2, let lower = Int(parts[0]), let upper = Int(parts[1]) else {
                return nil
            }
            return (lower, upper)
        }
    }

    private func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    func testItReadsAWholeBodyAcrossSeveralChunks() throws {
        let body = payload(5_000)
        let server = Server(body: body, behaviour: .ranged)
        defer { server.stop() }

        let stream = HTTPStream(request: URLRequest(url: server.url), chunkSize: 1_024)
        var collected = Data()
        var scratch = [UInt8](repeating: 0, count: 700)

        while true {
            let read = scratch.withUnsafeMutableBufferPointer {
                stream.read(into: $0.baseAddress!, count: 700)
            }
            if read <= 0 { break }
            collected.append(contentsOf: scratch[0..<read])
        }
        stream.close()

        XCTAssertEqual(collected.count, body.count, "the whole body should arrive")
        XCTAssertEqual(collected, body, "and in the right order")
    }

    func testSeekingReadsFromTheRequestedOffset() throws {
        let body = payload(3_000)
        let server = Server(body: body, behaviour: .ranged)
        defer { server.stop() }

        let stream = HTTPStream(request: URLRequest(url: server.url), chunkSize: 512)
        XCTAssertEqual(stream.seek(offset: 1_500, origin: 0), 1_500)

        var scratch = [UInt8](repeating: 0, count: 4)
        let read = scratch.withUnsafeMutableBufferPointer {
            stream.read(into: $0.baseAddress!, count: 4)
        }
        stream.close()

        XCTAssertEqual(read, 4)
        XCTAssertEqual(Array(scratch[0..<4]), Array(body[1_500..<1_504]))
    }

    /// Seeking from the end needs the length, which only a response carries.
    func testSeekingFromTheEndLearnsTheLength() throws {
        let body = payload(2_048)
        let server = Server(body: body, behaviour: .ranged)
        defer { server.stop() }

        let stream = HTTPStream(request: URLRequest(url: server.url), chunkSize: 256)
        XCTAssertEqual(stream.seek(offset: 0, origin: 2), 2_048)
        stream.close()
    }

    /// The case that would otherwise sound like a corrupt file: a server that
    /// ignores Range and returns the whole body. Accepting that at a non-zero
    /// offset would decode from the start while claiming to be elsewhere.
    func testAServerThatIgnoresRangeFailsTheSeekRatherThanLying() throws {
        let body = payload(4_000)
        let server = Server(body: body, behaviour: .ignoresRange)
        defer { server.stop() }

        let stream = HTTPStream(request: URLRequest(url: server.url), chunkSize: 1_024)

        // Seek FIRST, so the very first request is for a non-zero offset. That
        // is the dangerous shape: the server answers 200 with the whole body
        // starting at zero, and believing it would decode from the start while
        // reporting a position two thousand bytes in.
        _ = stream.seek(offset: 2_000, origin: 0)

        var scratch = [UInt8](repeating: 0, count: 8)
        let read = scratch.withUnsafeMutableBufferPointer {
            stream.read(into: $0.baseAddress!, count: 8)
        }
        XCTAssertEqual(read, -1, "a server that ignored the range must not be trusted")
        stream.close()

        // Reading from zero is still fine, because the whole body genuinely is
        // what was asked for.
        let fresh = HTTPStream(request: URLRequest(url: server.url), chunkSize: 1_024)
        let first = scratch.withUnsafeMutableBufferPointer {
            fresh.read(into: $0.baseAddress!, count: 8)
        }
        XCTAssertEqual(first, 8)
        XCTAssertEqual(Array(scratch[0..<8]), Array(body[0..<8]))
        fresh.close()
    }

    func testReadingPastTheEndEndsTheStream() throws {
        let body = payload(512)
        let server = Server(body: body, behaviour: .ranged)
        defer { server.stop() }

        let stream = HTTPStream(request: URLRequest(url: server.url), chunkSize: 256)
        _ = stream.seek(offset: 0, origin: 2)

        var scratch = [UInt8](repeating: 0, count: 16)
        let read = scratch.withUnsafeMutableBufferPointer {
            stream.read(into: $0.baseAddress!, count: 16)
        }
        stream.close()

        XCTAssertEqual(read, 0, "the end of a stream is zero bytes, not an error")
    }

    func testAnUnreachableServerFailsRatherThanHanging() {
        // Port 1 is reserved and nothing listens there.
        let url = URL(string: "http://127.0.0.1:1/track.wav")!
        let stream = HTTPStream(request: URLRequest(url: url), chunkSize: 256, timeout: 2)

        var scratch = [UInt8](repeating: 0, count: 8)
        let read = scratch.withUnsafeMutableBufferPointer {
            stream.read(into: $0.baseAddress!, count: 8)
        }
        stream.close()

        XCTAssertEqual(read, -1, "an unreachable server is a read error")
    }
}

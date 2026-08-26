#if canImport(Network)
import Foundation
import Network

public enum PairingService {
    /// The Bonjour service type devices advertise while pairing.
    ///
    /// **This must also appear in `NSBonjourServices` in Info.plist.** Without
    /// it, advertising fails — and it fails *only* in a TestFlight or App Store
    /// build, never in a local one, which makes it the kind of omission that is
    /// discovered by a user rather than by us.
    public static let type = "_mozz._tcp"

    /// Pairing is a face-to-face act with someone waiting on both ends. A
    /// ceremony that has not progressed within this long has failed, and saying
    /// so beats a spinner that never resolves.
    public static let timeout: Duration = .seconds(60)
}

public enum PairingTransportError: Error {
    case connectionFailed(String)
    case closedBeforeCompleting
    case timedOut
}

/// One pairing conversation over one socket.
///
/// Deliberately thin. Everything with a rule in it — ordering, refusals,
/// reassembly — lives in ``PairingSession`` and ``PairingWire``, which are
/// testable without a network. What is left here is the part that genuinely
/// needs a socket, and it is kept small because it is the part that cannot be
/// tested as thoroughly.
public actor PairingLink {
    private let connection: NWConnection
    private var wire = PairingWire()
    private var ready = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    public static func connect(to endpoint: NWEndpoint) async throws -> PairingLink {
        let link = PairingLink(connection: NWConnection(to: endpoint, using: .tcp))
        try await link.start()
        return link
    }

    func start() async throws {
        guard !ready else { return }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Resumed()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case let .failed(error):
                    if resumed.claim() { continuation.resume(throwing: PairingTransportError.connectionFailed("\(error)")) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: PairingTransportError.closedBeforeCompleting) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        ready = true
    }

    public func send(_ frame: PairingFrame) async throws {
        let bytes = PairingWire.frame(frame.encoded())
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: PairingTransportError.connectionFailed("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads until one whole frame is available. A read that returns fewer bytes
    /// than a frame is ordinary rather than exceptional, which is why the loop is
    /// here and the reassembly is somewhere with tests.
    public func receive() async throws -> PairingFrame {
        while true {
            if let frame = try nextBufferedFrame() { return frame }
            let chunk = try await readChunk()
            buffered += try wire.append(chunk)
        }
    }

    private var buffered: [Data] = []

    private func nextBufferedFrame() throws -> PairingFrame? {
        guard !buffered.isEmpty else { return nil }
        return try PairingFrame.decode(buffered.removeFirst())
    }

    /// Cancellation has to reach the socket, not just the task.
    ///
    /// `NWConnection.receive` calls back when bytes arrive and at no other time,
    /// so a continuation waiting on it ignores `Task.cancel()` entirely and waits
    /// forever. In the app that is someone backing out of the pairing screen and
    /// leaving a task that never finishes; it showed up here as a test that hung
    /// rather than failed. Cancelling the connection makes the callback fire,
    /// which is what actually unblocks it.
    private func readChunk() async throws -> Data {
        let connection = self.connection
        let resumed = Resumed()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                if Task.isCancelled {
                    if resumed.claim() { continuation.resume(throwing: CancellationError()) }
                    return
                }
                connection.receive(minimumIncompleteLength: 1,
                                   maximumLength: PairingWire.maxFrameLength) { data, _, isComplete, error in
                    guard resumed.claim() else { return }
                    if let error {
                        continuation.resume(throwing: PairingTransportError.connectionFailed("\(error)"))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: PairingTransportError.closedBeforeCompleting)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func close() {
        connection.cancel()
    }

    /// `stateUpdateHandler` can fire more than once for states we care about —
    /// `.failed` after `.ready`, or `.cancelled` during teardown — and resuming a
    /// continuation twice is a crash rather than a warning.
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

/// The side that waits to be found. The joiner advertises, because it is the one
/// asking to be let in; the member goes looking, because it is the one holding
/// something worth giving.
public actor PairingHost {
    private let listener: NWListener
    private var waiting: [CheckedContinuation<PairingLink, Error>] = []
    private var arrived: [PairingLink] = []

    public init(advertise: Bool, name: String = "Mozz") throws {
        let parameters = NWParameters.tcp
        // Only meaningful alongside a Bonjour service. Setting it on a bare
        // listener makes the listener wait on peer-to-peer setup that will never
        // arrive, which presents as a hang rather than an error.
        parameters.includePeerToPeer = advertise
        listener = try NWListener(using: parameters)
        if advertise {
            listener.service = NWListener.Service(name: name, type: PairingService.type)
        }
    }

    /// The port actually bound. Only meaningful once started; used by tests to
    /// connect directly and by nothing else, since real devices find each other
    /// through Bonjour.
    public var port: UInt16? { listener.port?.rawValue }

    private var started = false

    public func start() async throws {
        // Idempotent: a caller that hands an already-started host to
        // PairingCeremony must not re-register handlers or resume a second
        // continuation.
        guard !started else { return }
        started = true
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            Task { await self.accept(connection) }
        }

        // Wait for `.ready`, not merely for a port to appear.
        //
        // `listener.port` can be readable before the listener is actually
        // accepting, so a peer that dials the moment a port exists can arrive
        // at a socket nobody is listening on yet. That failure has no error
        // anywhere - both sides simply wait - which makes it a hang rather than
        // something that reports itself.
        let listener = self.listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Resumed()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case let .failed(error):
                    if resumed.claim() {
                        continuation.resume(throwing: PairingTransportError.connectionFailed("\(error)"))
                    }
                case .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: PairingTransportError.closedBeforeCompleting)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private func accept(_ connection: NWConnection) async {
        let link = PairingLink(connection: connection)
        do {
            try await link.start()
        } catch {
            return
        }
        if waiting.isEmpty {
            arrived.append(link)
        } else {
            waiting.removeFirst().resume(returning: link)
        }
    }

    public func nextLink() async throws -> PairingLink {
        if !arrived.isEmpty { return arrived.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
        }
    }

    public func stop() {
        listener.cancel()
        for continuation in waiting { continuation.resume(throwing: PairingTransportError.closedBeforeCompleting) }
        waiting.removeAll()
    }
}

/// Finds devices advertising for pairing.
///
/// Several may answer at once, which is ordinary in a house with more than one
/// Mozz device. The caller tries them in turn: on the QR path a device that is
/// not the one scanned is rejected by ``PairingSession`` itself, so "wrong
/// device" and "impostor" need no separate handling here.
public func browseForPairingDevices() -> AsyncStream<NWEndpoint> {
    AsyncStream { continuation in
        let browser = NWBrowser(for: .bonjour(type: PairingService.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results { continuation.yield(result.endpoint) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { continuation.finish() }
        }
        continuation.onTermination = { _ in browser.cancel() }
        browser.start(queue: .global(qos: .userInitiated))
    }
}
#endif

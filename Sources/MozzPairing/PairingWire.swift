import Foundation

/// Turns a stream of bytes back into discrete frames.
///
/// TCP does not preserve message boundaries, so every frame is written with a
/// four-byte big-endian length in front of it. The receiving side has to cope
/// with a frame arriving in six pieces, with two frames arriving in one read,
/// and with both happening at once — which is the whole reason this is a type
/// with tests rather than a few lines inside a connection callback.
public struct PairingWire {
    /// Frames are a hello, a peer, a reveal, or a seal. The largest legitimate
    /// one is a seal, already capped by ``PairingFrame/Size/maxCiphertext``. This
    /// is the same ceiling applied one layer out, so a peer cannot make us buffer
    /// without bound before the frame decoder ever sees it.
    public static let maxFrameLength = PairingFrame.Size.maxCiphertext + 1024

    public enum WireError: Error, Equatable {
        case frameTooLarge(Int)
    }

    private var buffer = Data()

    public init() {}

    /// Prefix a payload for the wire.
    public static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        out.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        out.append(payload)
        return out
    }

    /// Feed whatever arrived. Returns every frame that is now complete, which may
    /// be none, one, or several.
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []

        while true {
            guard buffer.count >= 4 else { break }

            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxFrameLength else {
                // Refuse before reserving anything. A length is a claim, and a
                // claim from someone we have not authenticated yet is exactly the
                // kind we should not act on.
                throw WireError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }

            let start = buffer.index(buffer.startIndex, offsetBy: 4)
            let end = buffer.index(start, offsetBy: length)
            frames.append(Data(buffer[start..<end]))
            buffer = Data(buffer[end...])
        }

        return frames
    }

    /// Bytes held back waiting for the rest of their frame. Useful for asserting
    /// a conversation ended cleanly rather than mid-frame.
    public var pendingByteCount: Int { buffer.count }
}

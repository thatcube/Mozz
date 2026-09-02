import Foundation

/// How a sonic vector becomes the `track_features.embedding` BLOB.
///
/// Packed little-endian Float32, explicitly — not `Codable`, not the host's
/// byte order. The column is described that way in the v6 migration, these rows
/// sync between a person's devices, and a database written on one architecture
/// has to read identically on another.
public enum SonicEmbeddingCodec {
    public static func pack(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Returns nil for a blob that is not a whole number of Float32s — a
    /// truncated write, or a column written by something that did not agree
    /// about the format.
    public static func unpack(_ data: Data) -> [Float]? {
        guard !data.isEmpty, data.count % 4 == 0 else { return nil }
        var out = [Float]()
        out.reserveCapacity(data.count / 4)
        var index = data.startIndex
        while index < data.endIndex {
            var bits: UInt32 = 0
            for byte in 0..<4 {
                bits |= UInt32(data[index + byte]) << (8 * UInt32(byte))
            }
            out.append(Float(bitPattern: UInt32(littleEndian: bits)))
            index += 4
        }
        return out
    }
}

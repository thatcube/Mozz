import Foundation

/// The convolutional half of VGGish, run on our own arithmetic.
///
/// **Why hand-written rather than a runtime.** Core ML is Apple-only, TFLite is
/// Android-first, ONNX Runtime is a native binary per platform — and any of the
/// three means the iPhone and the Pixel compute embeddings with different code.
/// Vectors from two devices land in one nearest-neighbour index, so "close
/// enough" is not a property we can accept: it has to be the same arithmetic in
/// the same order. Six convolutions and four pools is a small enough thing to
/// own outright, and `Tests/MozzAnalysisTests` pins it against PyTorch's output.
///
/// **Why only the trunk.** The full network is 288 MB, and 96% of that is two
/// 4096-wide dense layers trained to answer "is this a dog bark" for AudioSet.
/// Dropping them makes the ranking BETTER on every measurement (78.3% vs 76.5%
/// genre top-3, 82.3% vs 68.9% artist 1-NN against the DSP engine) and leaves
/// 4.5M parameters — 9 MB at half precision.
///
/// Layout throughout is channel-major: `value(channel, row, column)` lives at
/// `channel * rows * columns + row * columns + column`.
public struct VGGishTrunk: Sendable {
    /// One 3×3 convolution with unit padding, plus its bias.
    struct Layer: Sendable {
        let outputChannels: Int
        let inputChannels: Int
        /// `[out][in][3][3]`, flattened.
        let weights: [Float]
        let biases: [Float]
        /// Whether a 2×2 max-pool follows this layer's ReLU.
        let poolsAfter: Bool
    }

    private let layers: [Layer]
    /// Width of the vector this produces.
    public static let embeddingSize = 512

    /// The four-byte tag every weight file starts with.
    static let magic: [UInt8] = Array("MZVG".utf8)

    public enum LoadError: Error, Sendable {
        case notWeightData
        case unsupportedVersion(Int)
        case truncated
    }

    /// Read the exported weights.
    ///
    /// Deliberately takes `Data` rather than finding a file: the core does not
    /// know what a bundle, an asset manager or an application directory is, and
    /// each platform ships this differently. See `tools/export-vggish.py` for
    /// what writes it.
    public init(weights data: Data) throws {
        var cursor = 0
        func take(_ count: Int) throws -> Data {
            guard cursor + count <= data.count else { throw LoadError.truncated }
            defer { cursor += count }
            return data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + cursor + count))
        }
        func takeUInt32() throws -> Int {
            let bytes = try take(4)
            return Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        }

        guard Array(try take(4)) == Self.magic else { throw LoadError.notWeightData }
        let version = try takeUInt32()
        guard version == 1 else { throw LoadError.unsupportedVersion(version) }
        let count = try takeUInt32()

        var layers: [Layer] = []
        for index in 0..<count {
            let outputs = try takeUInt32()
            let inputs = try takeUInt32()
            let rows = try takeUInt32()
            let columns = try takeUInt32()
            guard rows == 3, columns == 3 else { throw LoadError.notWeightData }
            let weightCount = outputs * inputs * rows * columns
            let halves = try take(weightCount * 2)
            let biasBytes = try take(outputs * 4)
            layers.append(Layer(
                outputChannels: outputs,
                inputChannels: inputs,
                weights: Self.floats(fromHalves: halves, count: weightCount),
                biases: biasBytes.withUnsafeBytes { raw in
                    (0..<outputs).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian) }
                },
                // VGG's shape: pool after 1, 2, 4 and 6 convolutions.
                poolsAfter: [0, 1, 3, 5].contains(index)))
        }
        self.layers = layers
    }

    /// Half-precision weights, widened once at load.
    ///
    /// Stored at half precision because the file ships inside the app and 9 MB
    /// is very different from 18; widened rather than computed in half because
    /// `Float16` arithmetic is not available everywhere the core runs, and
    /// agreeing across platforms matters more here than a megabyte of RAM.
    static func floats(fromHalves data: Data, count: Int) -> [Float] {
        data.withUnsafeBytes { raw -> [Float] in
            (0..<count).map { i in
                let bits = raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self).littleEndian
                return Self.float(fromHalf: bits)
            }
        }
    }

    /// IEEE 754 half → single. Written out rather than delegated to `Float16`
    /// so the conversion is identical on every platform, including ones whose
    /// Swift has no `Float16`.
    static func float(fromHalf bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x03FF)
        if exponent == 0 {
            if mantissa == 0 { return Float(bitPattern: sign) }        // ±0
            // Subnormal: normalize it into a single-precision exponent.
            var e = exponent, m = mantissa
            while m & 0x0400 == 0 { m <<= 1; e = e &- 1 }
            m &= 0x03FF
            return Float(bitPattern: sign | ((e &+ 127 &- 15 &+ 1) << 23) | (m << 13))
        }
        if exponent == 0x1F {                                           // inf / NaN
            return Float(bitPattern: sign | 0x7F800000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | ((exponent &+ 127 &- 15) << 23) | (mantissa << 13))
    }

    /// Run one 96×64 log-mel patch through the stack and max-pool what comes
    /// out, giving one 512-value description of that 0.96 seconds.
    public func embed(patch: [Float], rows: Int = 96, columns: Int = 64) -> [Float] {
        var activations = Plane(patch)
        var height = rows, width = columns, channels = 1

        for layer in layers {
            activations = convolve(activations, channels: channels,
                                   height: height, width: width, layer: layer)
            channels = layer.outputChannels
            if layer.poolsAfter {
                (activations, height, width) = pool(activations, channels: channels,
                                                    height: height, width: width)
            }
        }

        // Max over each channel's remaining 6×4 field. Max rather than mean
        // because a channel fires on a thing being PRESENT somewhere in the
        // window, and averaging dilutes that by however long the window is —
        // measured 78.3% vs 77.7% genre top-3, and better again on 1-NN.
        var embedding = [Float](repeating: 0, count: channels)
        let plane = height * width
        for channel in 0..<channels {
            var best = -Float.greatestFiniteMagnitude
            let base = channel * plane
            for offset in 0..<plane { best = Swift.max(best, activations.values[base + offset]) }
            embedding[channel] = best
        }
        return embedding
    }

    /// 3×3 convolution, unit zero padding, stride 1, with ReLU folded in.
    ///
    /// Four lanes at a time. The naive scalar version cost 0.39s per patch,
    /// which is 37 seconds of arithmetic for a track and a library nobody could
    /// finish; the shape of the loop is unchanged, but the innermost walk along
    /// a row now moves in `SIMD4` steps.
    ///
    /// Every plane is 16-byte aligned and every row length is a multiple of
    /// four (64, 32, 16, 8 across the stack), so the destination stores are
    /// aligned by construction; only the source reads are shifted by the ±1 of
    /// the kernel, and those use unaligned loads.
    private func convolve(_ input: Plane, channels: Int, height: Int, width: Int,
                          layer: Layer) -> Plane {
        let outputs = layer.outputChannels
        let plane = height * width
        let result = Plane(count: outputs * plane)

        let source = input.values
        let destination = result.values
        layer.weights.withUnsafeBufferPointer { kernels in
            for out in 0..<outputs {
                let outBase = out * plane
                let bias = layer.biases[out]
                for index in 0..<plane { destination[outBase + index] = bias }

                for inChannel in 0..<channels {
                    let inBase = inChannel * plane
                    let kernelBase = (out * channels + inChannel) * 9
                    for tap in 0..<9 {
                        let weight = kernels[kernelBase + tap]
                        if weight == 0 { continue }
                        let lanes = SIMD4<Float>(repeating: weight)
                        let dy = tap / 3 - 1, dx = tap % 3 - 1
                        for y in 0..<height {
                            let sy = y + dy
                            if sy < 0 || sy >= height { continue }
                            let rowOut = outBase + y * width
                            let rowIn = inBase + sy * width
                            let xStart = Swift.max(0, -dx)
                            let xEnd = Swift.min(width, width - dx)

                            var x = xStart
                            // Lead-in to a multiple of four, so the vector body
                            // writes on aligned boundaries.
                            while x < xEnd, x % 4 != 0 {
                                destination[rowOut + x] += weight * source[rowIn + x + dx]
                                x += 1
                            }
                            while x + 4 <= xEnd {
                                let read = UnsafeRawPointer(source + (rowIn + x + dx))
                                    .loadUnaligned(as: SIMD4<Float>.self)
                                let slot = UnsafeMutableRawPointer(destination + (rowOut + x))
                                slot.storeBytes(of: slot.load(as: SIMD4<Float>.self) + lanes * read,
                                                as: SIMD4<Float>.self)
                                x += 4
                            }
                            while x < xEnd {
                                destination[rowOut + x] += weight * source[rowIn + x + dx]
                                x += 1
                            }
                        }
                    }
                }

                var index = 0                                   // ReLU
                let zero = SIMD4<Float>(repeating: 0)
                while index + 4 <= plane {
                    let slot = UnsafeMutableRawPointer(destination + (outBase + index))
                    slot.storeBytes(of: slot.load(as: SIMD4<Float>.self).replacing(
                        with: zero, where: slot.load(as: SIMD4<Float>.self) .< zero),
                                    as: SIMD4<Float>.self)
                    index += 4
                }
                while index < plane {
                    if destination[outBase + index] < 0 { destination[outBase + index] = 0 }
                    index += 1
                }
            }
        }
        return result
    }

    /// 2×2 max-pool, stride 2. Odd sizes truncate, as PyTorch's does.
    private func pool(_ input: Plane, channels: Int, height: Int, width: Int)
        -> (Plane, Int, Int) {
        let outHeight = height / 2, outWidth = width / 2
        let result = Plane(count: channels * outHeight * outWidth)
        let source = input.values, destination = result.values
        for channel in 0..<channels {
            let inBase = channel * height * width
            let outBase = channel * outHeight * outWidth
            for y in 0..<outHeight {
                let top = inBase + (y * 2) * width
                let bottom = top + width
                for x in 0..<outWidth {
                    let left = x * 2
                    let a = Swift.max(source[top + left], source[top + left + 1])
                    let b = Swift.max(source[bottom + left], source[bottom + left + 1])
                    destination[outBase + y * outWidth + x] = Swift.max(a, b)
                }
            }
        }
        return (result, outHeight, outWidth)
    }
}

/// A 16-byte aligned scratch plane.
///
/// Alignment is not an optimisation detail here: the convolution stores whole
/// `SIMD4` vectors, and an aligned store to an unaligned address is undefined
/// behaviour rather than a slow path. `Array<Float>` only promises four-byte
/// alignment, so the buffers are allocated by hand.
final class Plane {
    let values: UnsafeMutablePointer<Float>
    let count: Int

    init(count: Int) {
        self.count = count
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: count * MemoryLayout<Float>.size, alignment: 16)
        self.values = raw.bindMemory(to: Float.self, capacity: count)
        self.values.initialize(repeating: 0, count: count)
    }

    convenience init(_ source: [Float]) {
        self.init(count: source.count)
        source.withUnsafeBufferPointer { values.update(from: $0.baseAddress!, count: $0.count) }
    }

    deinit {
        values.deinitialize(count: count)
        UnsafeMutableRawPointer(values).deallocate()
    }
}

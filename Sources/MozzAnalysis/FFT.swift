import Foundation

/// An in-place radix-2 Cooley–Tukey FFT, written here rather than taken from a
/// platform framework.
///
/// `vDSP` would be faster and is right there on Apple hardware. It is also
/// Apple-only, and this is the one piece of the analyzer where that matters
/// most: a vector computed on an iPhone and the same track's vector computed on
/// a Pixel have to be the same vector, because they end up in the same nearest-
/// neighbour index and they sync between the two devices. Two implementations of
/// "an FFT" agree to within rounding, and rounding is exactly what a golden
/// fixture cannot tolerate.
///
/// Speed is not the constraint it looks like. A 90-second analysis window at
/// 16 kHz is 1.4M samples — about 2,800 frames of 1,024 — which is milliseconds
/// of work, once per track, on a background queue.
struct FFT {
    let size: Int
    private let levels: Int
    /// Twiddles for the whole transform, computed once per size and reused for
    /// every frame of the file.
    private let cosTable: [Double]
    private let sinTable: [Double]

    /// - Parameter size: must be a power of two.
    init(size: Int) {
        precondition(size > 0 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        self.levels = Int(log2(Double(size)))
        var cosTable = [Double](repeating: 0, count: size / 2)
        var sinTable = [Double](repeating: 0, count: size / 2)
        for i in 0..<(size / 2) {
            let angle = 2 * Double.pi * Double(i) / Double(size)
            cosTable[i] = cos(angle)
            sinTable[i] = sin(angle)
        }
        self.cosTable = cosTable
        self.sinTable = sinTable
    }

    /// Forward transform, in place. `real` and `imag` must both be `size` long.
    func forward(real: inout [Double], imag: inout [Double]) {
        precondition(real.count == size && imag.count == size)

        // Bit-reversal permutation.
        var j = 0
        for i in 0..<size {
            if i < j {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
            var mask = size >> 1
            while j & mask != 0 {
                j &= ~mask
                mask >>= 1
            }
            j |= mask
        }
        _ = levels

        // Butterflies, smallest span first.
        var span = 2
        while span <= size {
            let half = span / 2
            let step = size / span
            var start = 0
            while start < size {
                var k = 0
                for i in start..<(start + half) {
                    let partner = i + half
                    let c = cosTable[k]
                    let s = sinTable[k]
                    let tre = real[partner] * c + imag[partner] * s
                    let tim = -real[partner] * s + imag[partner] * c
                    real[partner] = real[i] - tre
                    imag[partner] = imag[i] - tim
                    real[i] += tre
                    imag[i] += tim
                    k += step
                }
                start += span
            }
            span <<= 1
        }
    }

    /// Magnitude spectrum of one real-valued frame, bins `0...size/2`.
    ///
    /// The frame is copied, so the caller's window buffer is untouched.
    func magnitudes(of frame: [Double]) -> [Double] {
        precondition(frame.count == size)
        var real = frame
        var imag = [Double](repeating: 0, count: size)
        forward(real: &real, imag: &imag)
        let bins = size / 2 + 1
        var out = [Double](repeating: 0, count: bins)
        for i in 0..<bins {
            out[i] = (real[i] * real[i] + imag[i] * imag[i]).squareRoot()
        }
        return out
    }
}

/// A periodic Hann window, the standard choice for spectral analysis of music.
///
/// Periodic (`/ count`) rather than symmetric (`/ (count - 1)`): with hop = half
/// the window it sums to a constant, so successive frames neither over- nor
/// under-weight the samples they share.
func hannWindow(_ count: Int) -> [Double] {
    guard count > 1 else { return [Double](repeating: 1, count: max(count, 0)) }
    return (0..<count).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(count)) }
}

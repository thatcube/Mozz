import Dispatch
import Foundation

/// The learned analyzer: log-mel patches through VGGish's convolutional trunk,
/// max-pooled per patch and averaged across the track.
///
/// Drop-in beside ``SonicAnalyzer``. It produces the same ``SonicFeatures``,
/// stamped with its own engine, so a library analyzed by one is never compared
/// against a library analyzed by the other — `track_features.feature_source` is
/// what keeps two incomparable spaces apart, and bumping the engine is what
/// makes a device re-analyze.
///
/// Why this and not the DSP engine, measured rather than asserted:
///
///     FMA genre, top-3 (n=1200)     69.6% -> 78.3%
///     human "sounds alike" (n=378)  59.0% -> 62.7%
///     real library, artist 1-NN     68.9% -> 82.3%
///     real library, album top-3     35.7% -> 45.0%
public struct VGGishAnalyzer: Sendable {
    /// `name@version`, as with the DSP engine: any change that moves a vector
    /// takes the next version and re-analyzes libraries in the background.
    public static let engine = "mozz-vggish@1"

    /// How many 0.96-second patches to describe a track with.
    ///
    /// Ninety seconds holds ninety-four, and each one is nine hundred million
    /// multiply-accumulates on somebody's phone. Measured against FMA's genre
    /// retrieval, six is where the curve flattens:
    ///
    ///      2 patches   72.5% top-3   50.8% 1-NN
    ///      3           72.7%         56.3%
    ///      4           75.8%         59.2%
    ///      6           76.9%         61.9%
    ///      8           76.2%         60.6%
    ///     12           77.0%         61.8%
    ///
    /// Six and twelve are the same answer within the noise of 1,200 tracks, and
    /// six costs half as much; below four the description genuinely thins out.
    /// Twelve was a guess, and it cost a Pixel sixty-six hours per library.
    ///
    /// Spread across the window rather than taken from the front, which is a
    /// thing the DSP engine could not do at any price: one contiguous window
    /// was all it ever saw, so a song with a long intro was described by its
    /// intro.
    public static let patchesPerTrack = 6

    /// How many patches to convolve at once.
    ///
    /// Deliberately not every core: this is background work competing with a
    /// music player and whatever else someone is doing, and the last core is
    /// worth more to them than the last few percent of throughput.
    static let maximumConcurrency = Swift.max(1, ProcessInfo.processInfo.activeProcessorCount - 2)

    private let frontEnd: VGGishFrontEnd
    private let trunk: VGGishTrunk

    public init(trunk: VGGishTrunk, frontEnd: VGGishFrontEnd = VGGishFrontEnd()) {
        self.trunk = trunk
        self.frontEnd = frontEnd
    }

    /// The rate this expects, which is not negotiable: the network was trained
    /// on 16 kHz and reads anything else as different music.
    public var sampleRate: Int { VGGishFrontEnd.sampleRate }

    public func analyze(_ samples: [Float], patchLimit: Int = patchesPerTrack) -> SonicFeatures? {
        let patches = frontEnd.patches(samples, limit: patchLimit)
        guard !patches.isEmpty else { return nil }

        // Patches are independent, and a phone has eight cores idling while one
        // of them does nine billion multiply-accumulates. Measured on a Pixel,
        // one core managed 2.4 tracks a minute — sixty-six hours for a library.
        //
        // The reduction stays sequential on purpose: each patch writes its own
        // slot and the sum is taken afterwards in a fixed order, so the answer
        // is bit-identical to the single-threaded one. Vectors from two devices
        // land in one index, and "same to within floating-point reassociation"
        // is not the same as identical.
        var embeddings = [[Float]](repeating: [], count: patches.count)
        let lanes = Swift.min(Self.maximumConcurrency, patches.count)
        if lanes > 1 {
            embeddings.withUnsafeMutableBufferPointer { slots in
                let box = UncheckedBox(slots)
                DispatchQueue.concurrentPerform(iterations: patches.count) { index in
                    box.value[index] = trunk.embed(patch: patches[index])
                }
            }
        } else {
            for (index, patch) in patches.enumerated() {
                embeddings[index] = trunk.embed(patch: patch)
            }
        }

        var sum = [Double](repeating: 0, count: VGGishTrunk.embeddingSize)
        for embedding in embeddings {
            guard embedding.count == sum.count else { return nil }
            for i in 0..<embedding.count { sum[i] += Double(embedding[i]) }
        }
        let scale = 1.0 / Double(patches.count)
        var mean = sum.map { $0 * scale }

        // Unit length, so a dot product is a cosine — the corpus standardizes
        // these again at query time, but a normalized vector is what every
        // consumer of `SonicFeatures` already assumes.
        let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-9 else { return nil }
        for i in 0..<mean.count { mean[i] /= norm }

        var energy = 0.0
        for sample in samples { energy += Double(sample) * Double(sample) }
        let rms = (energy / Double(Swift.max(samples.count, 1))).squareRoot()
        let loudness = 20 * log10(Swift.max(rms, 1e-9))
        // Silence has no timbre to describe, and a vector for it would sit in
        // the index claiming to be near everything quiet.
        guard loudness > -70 else { return nil }

        return SonicFeatures(
            values: mean.map { Float($0) },
            engine: Self.engine,
            // The network has no opinion about tempo. Left nil rather than
            // guessed: `saveSonicEmbedding` coalesces, so a BPM the DSP engine
            // already measured survives.
            tempoBPM: nil,
            loudnessDBFS: loudness,
            analyzedSeconds: Double(samples.count) / Double(VGGishFrontEnd.sampleRate))
    }
}

/// Hands a mutable buffer to `concurrentPerform` without Swift 6 complaining.
///
/// Safe because each iteration writes exactly one slot, indexed by its own
/// iteration number, and nothing reads the buffer until every iteration has
/// finished.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

import Foundation

/// Turns decoded mono PCM into a ``SonicFeatures`` vector.
///
/// Pure Swift, no platform frameworks, no vendored native code, no model
/// weights — see the module note in `Package.swift` for why that constraint is
/// load-bearing rather than purity for its own sake.
///
/// **What this is and is not.** These are hand-designed descriptors: timbre
/// (MFCCs), harmony (chroma), brightness and noisiness (spectral shape),
/// dynamics, and tempo. That is dramatically more than a genre tag knows, and
/// less than a trained embedding knows. It is deliberately the first engine
/// rather than the last one: `track_features.feature_source` records
/// `name@version` per row precisely so a better engine can replace this one
/// without a migration and without touching anything downstream.
public struct SonicAnalyzer: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// The rate the input is expected at. Analysis is done at a fixed rate
        /// so two devices analyzing the same track agree; resampling is the
        /// fetcher's job, not this type's.
        public var sampleRate: Int
        public var frameSize: Int
        public var hopSize: Int
        public var melBands: Int
        public var melMinHz: Double
        public var melMaxHz: Double
        /// How many cepstral coefficients to keep. More is finer timbre detail
        /// and more dimensions for the corpus to standardize.
        public var mfccCount: Int
        /// Whether to describe how fast timbre CHANGES as well as what it is —
        /// the mean absolute frame-to-frame delta of each coefficient. A steady
        /// pad and a chopped sample can share a spectrum and differ entirely
        /// here.
        public var includeMFCCDeltas: Bool
        /// Whether to scale the input to a fixed RMS before analyzing, so a
        /// track's mastering level stops colouring its timbre. Loudness itself
        /// is still described — it is measured before the scaling.
        public var normalizeGain: Bool

        public init(sampleRate: Int, frameSize: Int, hopSize: Int, melBands: Int,
                    melMinHz: Double, melMaxHz: Double,
                    mfccCount: Int = SonicFeatureLayout.mfccCount,
                    includeMFCCDeltas: Bool = false,
                    normalizeGain: Bool = false) {
            self.sampleRate = sampleRate
            self.frameSize = frameSize
            self.hopSize = hopSize
            self.melBands = melBands
            self.melMinHz = melMinHz
            self.melMaxHz = melMaxHz
            self.mfccCount = mfccCount
            self.includeMFCCDeltas = includeMFCCDeltas
            self.normalizeGain = normalizeGain
        }

        public static let v1 = Configuration(
            sampleRate: 16_000, frameSize: 1024, hopSize: 256,
            melBands: 40, melMinHz: 20, melMaxHz: 8_000)

        /// Frames per second of the STFT — the clock the tempo search counts in.
        var frameRate: Double { Double(sampleRate) / Double(hopSize) }
        var nyquist: Double { Double(sampleRate) / 2 }
    }

    /// `name@version`. Bump the version for ANY change that moves a vector:
    /// a new feature, a reordered one, a different window, a different scaling.
    /// Rows carrying an older engine are not comparable and get re-analyzed.
    public static let engine = "mozz-dsp@1"

    public let configuration: Configuration
    private let fft: FFT
    private let window: [Double]
    private let melFilters: [MelBand]

    public init(configuration: Configuration = .v1) {
        self.configuration = configuration
        self.fft = FFT(size: configuration.frameSize)
        self.window = hannWindow(configuration.frameSize)
        self.melFilters = Self.melFilterbank(configuration: configuration)
    }

    /// Tempo alone, for when something else is describing the timbre.
    ///
    /// The learned engine has no opinion about tempo, and dropping BPM to gain
    /// a better embedding would be a poor trade — so this runs the cheap half
    /// of the pipeline: an onset envelope from spectral flux, and an
    /// autocorrelation over it. No mel filterbank, no cepstrum, no statistics,
    /// which is most of what `analyze` spends its time on.
    public func tempo(of samples: [Float]) -> Double? {
        let config = configuration
        guard samples.count >= config.frameSize * 8 else { return nil }
        let bins = config.frameSize / 2 + 1
        var onsets: [Double] = []
        var previous = [Double](repeating: 0, count: bins)
        var frame = [Double](repeating: 0, count: config.frameSize)
        var start = 0
        while start + config.frameSize <= samples.count {
            for i in 0..<config.frameSize {
                frame[i] = Double(samples[start + i]) * window[i]
            }
            let magnitudes = fft.magnitudes(of: frame)
            let total = magnitudes.reduce(0, +)
            if total > 1e-9 {
                var rising = 0.0
                for b in 0..<bins {
                    let delta = magnitudes[b] - previous[b]
                    if delta > 0 { rising += delta }
                }
                onsets.append(rising / total)
            } else {
                onsets.append(0)
            }
            previous = magnitudes
            start += config.hopSize
        }
        return Self.estimateTempo(onsets: onsets, frameRate: config.frameRate)
    }

    /// Analyze one mono buffer.
    ///
    /// Returns nil when there is not enough signal to describe — too short, or
    /// silent. A nil is a track to leave unanalyzed and retry later, never a
    /// zero vector: a zero vector would sit in the index claiming to be
    /// equidistant from everything.
    public func analyze(_ input: [Float]) -> SonicFeatures? {
        let config = configuration
        guard input.count >= config.frameSize * 8 else { return nil }

        // Mastering level is not timbre. Scaling to a fixed RMS first stops a
        // loud master reading as a different instrument from a quiet one; the
        // track's actual loudness is still described, measured below from the
        // signal as it arrived.
        let inputRMS = (input.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(input.count)).squareRoot()
        let samples: [Float]
        if config.normalizeGain, inputRMS > 1e-6 {
            let gain = Float(0.1 / inputRMS)
            samples = input.map { $0 * gain }
        } else {
            samples = input
        }

        let bins = config.frameSize / 2 + 1
        var mfccStats = (0..<config.mfccCount).map { _ in RunningStat() }
        var mfccDeltas = (0..<config.mfccCount).map { _ in RunningStat() }
        var previousMFCC: [Double]?
        var chromaSum = [Double](repeating: 0, count: SonicFeatureLayout.chromaCount)
        var centroid = RunningStat(), rolloff = RunningStat(), flatness = RunningStat()
        var flux = RunningStat(), zcr = RunningStat(), rms = RunningStat()
        var peak = 0.0
        var energySum = 0.0
        var sampleCount = 0
        var onsets: [Double] = []
        var previousMagnitudes = [Double](repeating: 0, count: bins)
        let chromaClass = Self.chromaClasses(bins: bins, sampleRate: config.sampleRate)

        var frame = [Double](repeating: 0, count: config.frameSize)
        var start = 0
        while start + config.frameSize <= samples.count {
            // Windowed frame, plus the time-domain statistics that are cheapest
            // to take while the samples are already in hand.
            var crossings = 0
            var frameEnergy = 0.0
            var previousSample = Double(samples[start])
            for i in 0..<config.frameSize {
                let sample = Double(samples[start + i])
                frame[i] = sample * window[i]
                frameEnergy += sample * sample
                peak = Swift.max(peak, abs(sample))
                if (sample >= 0) != (previousSample >= 0) { crossings += 1 }
                previousSample = sample
            }
            energySum += frameEnergy
            sampleCount += config.frameSize
            rms.add((frameEnergy / Double(config.frameSize)).squareRoot())
            zcr.add(Double(crossings) / Double(config.frameSize))

            let magnitudes = fft.magnitudes(of: frame)
            let total = magnitudes.reduce(0, +)

            if total > 1e-9 {
                // Spectral centroid and 85% rolloff, both as a fraction of
                // Nyquist so they are rate-independent numbers in 0...1.
                var weighted = 0.0
                for b in 0..<bins { weighted += Double(b) * magnitudes[b] }
                centroid.add(weighted / total / Double(bins - 1))

                var cumulative = 0.0
                var rolloffBin = bins - 1
                let threshold = total * 0.85
                for b in 0..<bins {
                    cumulative += magnitudes[b]
                    if cumulative >= threshold { rolloffBin = b; break }
                }
                rolloff.add(Double(rolloffBin) / Double(bins - 1))

                // Flatness: geometric over arithmetic mean. Near 1 is noise-like,
                // near 0 is tonal.
                var logSum = 0.0
                for b in 0..<bins { logSum += log(magnitudes[b] + 1e-10) }
                let geometric = exp(logSum / Double(bins))
                flatness.add(geometric / (total / Double(bins) + 1e-10))

                // Flux: the positive change since the last frame, normalized by
                // this frame's own magnitude so loud tracks do not read as busy
                // ones. Doubles as the onset envelope the tempo search runs on.
                var positiveChange = 0.0
                for b in 0..<bins {
                    let delta = magnitudes[b] - previousMagnitudes[b]
                    if delta > 0 { positiveChange += delta }
                }
                let normalizedFlux = positiveChange / total
                flux.add(normalizedFlux)
                onsets.append(normalizedFlux)

                for b in 0..<bins where chromaClass[b] >= 0 {
                    chromaSum[chromaClass[b]] += magnitudes[b]
                }

                // Mel-frequency cepstral coefficients: log energy in
                // perceptually spaced bands, decorrelated by a DCT.
                var logMel = [Double](repeating: 0, count: config.melBands)
                for m in 0..<config.melBands {
                    var acc = 0.0
                    let band = melFilters[m]
                    for (offset, weight) in band.weights.enumerated() {
                        let bin = band.startBin + offset
                        if bin < bins { acc += weight * magnitudes[bin] }
                    }
                    logMel[m] = log(acc + 1e-10)
                }
                let mfcc = Self.dct(logMel, count: config.mfccCount)
                for i in 0..<config.mfccCount { mfccStats[i].add(mfcc[i]) }
                if let previous = previousMFCC {
                    for i in 0..<config.mfccCount { mfccDeltas[i].add(abs(mfcc[i] - previous[i])) }
                }
                previousMFCC = mfcc
            } else {
                flux.add(0)
                onsets.append(0)
            }

            previousMagnitudes = magnitudes
            start += config.hopSize
        }

        guard rms.count > 0, energySum > 0 else { return nil }

        let overallRMS = (energySum / Double(sampleCount)).squareRoot()
        let loudnessDBFS = 20 * log10(Swift.max(config.normalizeGain ? inputRMS : overallRMS, 1e-9))
        // Silence, or so near it that everything above is describing noise floor.
        guard loudnessDBFS > -70 else { return nil }

        let tempo = Self.estimateTempo(onsets: onsets, frameRate: config.frameRate)
        let crestDB = 20 * log10(Swift.max(peak, 1e-9) / Swift.max(overallRMS, 1e-9))

        // Chroma is normalized by its own maximum, not by its sum: what matters
        // is the SHAPE of the pitch-class profile, and dividing by the sum makes
        // a track with one strong class look like a track with twelve weak ones.
        let chromaMax = chromaSum.max() ?? 0
        let chroma = chromaMax > 0 ? chromaSum.map { $0 / chromaMax } : chromaSum

        // Each feature is emitted with the weight its family carries in the
        // final distance. Only the RATIOS matter — the vector is normalized —
        // so these read as "timbre and tempo decide most of it, harmony and
        // dynamics colour it, second-order spread breaks ties".
        var values: [Double] = []
        var weights: [Double] = []
        values.reserveCapacity(SonicFeatureLayout.dimension(for: config))
        weights.reserveCapacity(SonicFeatureLayout.dimension(for: config))
        func add(_ value: Double, weight: Double) {
            values.append(value)
            weights.append(weight)
        }

        // --- Timbre. Weighted highest: it carries most of "sounds like". ---
        for i in 0..<config.mfccCount {
            // c0 is overall log energy and runs an order of magnitude wider than
            // the rest, so it gets its own scale.
            let scale = i == 0 ? 25.0 : 12.0
            add(squashSigned(mfccStats[i].mean, scale: scale), weight: 1.0)
        }
        for i in 0..<config.mfccCount {
            add(clamp01(mfccStats[i].standardDeviation / 12), weight: 0.6)
        }
        if config.includeMFCCDeltas {
            for i in 0..<config.mfccCount {
                add(clamp01(mfccDeltas[i].mean / 6), weight: 0.7)
            }
        }
        // --- Harmony. ---
        for c in chroma { add(clamp01(c), weight: 0.5) }
        // --- Spectral shape. ---
        add(clamp01(centroid.mean), weight: 0.8)
        add(clamp01(centroid.standardDeviation * 3), weight: 0.4)
        add(clamp01(rolloff.mean), weight: 0.6)
        add(clamp01(rolloff.standardDeviation * 3), weight: 0.3)
        add(clamp01(flatness.mean), weight: 0.6)
        add(clamp01(flatness.standardDeviation * 3), weight: 0.3)
        add(clamp01(flux.mean * 4), weight: 0.7)
        add(clamp01(flux.standardDeviation * 4), weight: 0.4)
        add(clamp01(zcr.mean * 4), weight: 0.4)
        add(clamp01(zcr.standardDeviation * 8), weight: 0.2)
        // --- Dynamics. dBFS mapped so -60 reads as 0 and 0 as 1. ---
        add(clamp01((loudnessDBFS + 60) / 60), weight: 0.5)
        add(clamp01(rms.standardDeviation * 8), weight: 0.4)
        add(clamp01(crestDB / 30), weight: 0.4)
        // --- Rhythm. An unmeasurable tempo sits at the midpoint, which centres
        // to zero below: it contributes nothing rather than voting for a BPM. ---
        add(tempo.map { clamp01(($0 - 40) / 180) } ?? 0.5, weight: 1.0)
        add(clamp01(onsets.reduce(0, +) / Double(Swift.max(onsets.count, 1)) * 4), weight: 0.5)

        assert(values.count == SonicFeatureLayout.dimension(for: config))

        // Centre, then weight, then normalize. Every feature above lands in
        // 0...1, and a set of all-positive vectors makes cosine similarity
        // useless — every pair scores 0.9-something and the ranking is noise.
        // Subtracting the midpoint puts them either side of zero and gives the
        // metric its range back.
        let centred = zip(values, weights).map { ($0 - 0.5) * $1 }
        let norm = centred.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-9 else { return nil }
        let unit = centred.map { Float($0 / norm) }

        return SonicFeatures(values: unit, engine: Self.engine, tempoBPM: tempo,
                             loudnessDBFS: loudnessDBFS,
                             analyzedSeconds: Double(input.count) / Double(config.sampleRate))
    }
}

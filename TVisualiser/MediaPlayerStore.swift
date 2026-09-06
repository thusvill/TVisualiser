import AVFoundation
import Accelerate
import Combine
import CoreImage
import Foundation
import SwiftUI
import UIKit

// ================================================================
// MARK: - Spectrum Layout
// ================================================================

/// Describes how an ascending (bass -> treble) array of band energies gets
/// spatially arranged across the display bins. New visual arrangements —
/// a different bar layout, a mirrored wave, etc. — only need a new case
/// here; the FFT/analysis code never needs to change.
enum SpectrumLayout {

    /// Bass sits in the middle, fanning out to treble on both edges.
    /// (Classic media-player look.)
    case centerOut

    /// Bass on the left, treble on the right — a plain ascending sweep.
    case leftToRight

    /// Bass on the right, treble on the left — mirror of `leftToRight`.
    case rightToLeft

    /// Treble sits in the middle, bass at both edges (inverse of `centerOut`).
    case edgesIn

    /// Arranges `bands` (ascending bass -> treble, any length) into
    /// `totalCount` display bins according to this layout.
    func arrange(bands: [Float], totalCount: Int) -> [Float] {
        guard totalCount > 0, !bands.isEmpty else {
            return Array(repeating: 0, count: max(0, totalCount))
        }

        switch self {
        case .leftToRight:
            return Self.resample(bands, to: totalCount)

        case .rightToLeft:
            return Self.resample(bands, to: totalCount).reversed()

        case .centerOut:
            let half = max(1, totalCount / 2)
            let halfBands = Self.resample(bands, to: half)
            var result = Array(repeating: Float(0), count: totalCount)
            for k in 0..<half {
                result[k] = halfBands[half - 1 - k]
            }
            for k in 0..<(totalCount - half) {
                let sourceIndex = min(k, half - 1)
                result[half + k] = halfBands[sourceIndex]
            }
            return result

        case .edgesIn:
            let centerOut = SpectrumLayout.centerOut.arrange(bands: bands, totalCount: totalCount)
            let half = totalCount / 2
            var result = Array(repeating: Float(0), count: totalCount)
            for i in 0..<totalCount {
                result[i] = centerOut[(i + half) % totalCount]
            }
            return result
        }
    }

    /// Linearly resamples `values` to exactly `count` entries, preserving
    /// the ascending shape regardless of how the source/target lengths differ.
    private static func resample(_ values: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard values.count > 1 else {
            return Array(repeating: values.first ?? 0, count: count)
        }

        var output = Array(repeating: Float(0), count: count)
        let lastIndex = Float(values.count - 1)
        for i in 0..<count {
            let position = count > 1 ? (Float(i) / Float(count - 1)) * lastIndex : 0
            let lower = Int(position)
            let upper = min(lower + 1, values.count - 1)
            let fraction = position - Float(lower)
            output[i] = values[lower] * (1 - fraction) + values[upper] * fraction
        }
        return output
    }
}

@MainActor
final class MediaPlayerStore: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = "Select a media source"
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artwork: UIImage?
    @Published private(set) var waveformColor: Color = .black
    @Published private(set) var waveform = Array(repeating: Float(0), count: 96)
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var activeSourceID: String?

    /// Change this to switch how the spectrum bars are spatially arranged
    /// (e.g. from a future Settings toggle) without touching the analyzer.
    @Published var spectrumLayout: SpectrumLayout = .edgesIn {
        didSet { playback.setSpectrumLayout(spectrumLayout) }
    }

    @Published private(set) var palette: AlbumPalette = .default

    nonisolated private static let waveformSampleCount = 96

    private let playback = AudioPlaybackEngine()
    private var timer: Timer?

    func updateWaveform(_ waveformValues: [Float]) {
        guard waveformValues.count == Self.waveformSampleCount else { return }
        
        // Smoothness factor (0.2 = smooth & fluid, 0.5 = punchy, 1.0 = instant)
        let smoothingFactor: Float = 0.22
        
        var smoothed = waveform
        for i in 0..<Self.waveformSampleCount {
            smoothed[i] += (waveformValues[i] - smoothed[i]) * smoothingFactor
        }
        
        withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.86)) {
            self.waveform = smoothed
        }
    }
    
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePlaybackState()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        playback.stop()
        isPlaying = false
        currentTime = 0
        duration = 0
        //waveform = Self.silentWaveform()
        updateWaveform(Self.silentWaveform())
    }

    func select(source: any MediaSource) {
        activeSourceID = source.id
        trackTitle = "No media selected"
        artist = ""
        album = ""
        artwork = nil
        waveformColor = .black
    }

    func load(track: MediaTrack, from source: any MediaSource) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let preparedTrack = try await source.prepare(track)
                try playback.load(url: preparedTrack.mediaURL)

                // Prefer whatever the source already parsed, but fall back
                // to metadata read straight from the file itself whenever
                // the source came back empty — mirrors how artwork already
                // falls back to `playback.artworkData()` below. This is
                // what fixes artist (and album/title) showing blank: the
                // source's own tag parsing may miss fields that are still
                // present in the file's embedded metadata.
                trackTitle = preparedTrack.title.isEmpty
                    ? (playback.titleFromMetadata() ?? preparedTrack.title)
                    : preparedTrack.title
                artist = preparedTrack.artist.isEmpty
                    ? (playback.artistFromMetadata() ?? preparedTrack.artist)
                    : preparedTrack.artist
                album = preparedTrack.album.isEmpty
                    ? (playback.albumFromMetadata() ?? preparedTrack.album)
                    : preparedTrack.album

                duration = playback.duration
//                waveform = Self.silentWaveform()
                updateWaveform(Self.silentWaveform())
                currentTime = 0
                let artworkData = preparedTrack.artworkData ?? playback.artworkData()
                artwork = artworkData.flatMap(UIImage.init(data:))
                waveformColor = artwork.flatMap(Self.averageColor) ?? .black
                isPlaying = false
                if let artwork {
                                withAnimation(.easeInOut(duration: 0.5)) {
                                    self.palette = PaletteExtractor.extract(from: artwork)
                                }
                            }
            } catch {
                trackTitle = error.localizedDescription
                isPlaying = false
            }
        }
    }

    func togglePlayback() {
        guard playback.hasLoadedFile else { return }
        if isPlaying {
            playback.pause()
        } else {
            playback.play()
        }
        isPlaying = playback.isPlaying
        if !isPlaying {
//            waveform = Self.silentWaveform()
            updateWaveform(Self.silentWaveform())
        }
    }

    func skipBackward() {
        guard playback.hasLoadedFile else { return }
        currentTime = max(0, playback.currentTime() - 10)
        playback.seek(to: currentTime)
    }

    func skipForward() {
        guard playback.hasLoadedFile else { return }
        let nextTime = duration > 0
            ? min(duration, playback.currentTime() + 10)
            : playback.currentTime() + 10
        currentTime = nextTime
        playback.seek(to: nextTime)
    }

    private func updatePlaybackState() {
        guard isPlaying else {
            if waveform.contains(where: { $0 != 0 }) {
//                waveform = Self.silentWaveform()
                updateWaveform(Self.silentWaveform())
            }
            return
        }
        //waveform = playback.spectrum()
        updateWaveform(playback.spectrum())
        let actualTime = playback.currentTime()
        if actualTime.isFinite && actualTime > 0 {
            currentTime = duration > 0 ? min(duration, actualTime) : actualTime
        }
    }

    private static func averageColor(of image: UIImage) -> Color? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])
        guard let output = filter?.outputImage,
              let cgImage = CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
              let pixel = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(pixel) else { return nil }
        return Color(
            red: Double(bytes[0]) / 255,
            green: Double(bytes[1]) / 255,
            blue: Double(bytes[2]) / 255
        )
    }

    private static func silentWaveform() -> [Float] {
        Array(repeating: 0, count: waveformSampleCount)
    }
}

private final class AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let spectrumAnalyzer = LiveSpectrumAnalyzer(binCount: 96)
    private var audioFile: AVAudioFile?
    private var playbackStartFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var hasLoadedFile: Bool { audioFile != nil }

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        engine.attach(playerNode)
    }

    func load(url: URL) throws {
        stop()

        let file = try AVAudioFile(forReading: url)
        audioFile = file
        duration = Double(file.length) / file.processingFormat.sampleRate
        pausedFrame = 0
        playbackStartFrame = 0
        spectrumAnalyzer.reset()

        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
        installSpectrumTap()
        engine.prepare()
    }

    func artworkData() -> Data? {
        guard let url = audioFile?.url else { return nil }
        let asset = AVAsset(url: url)
        return asset.commonMetadata
            .first(where: { $0.commonKey == .commonKeyArtwork })?
            .dataValue
    }

    /// Track title read straight from the file's embedded metadata.
    /// Used as a fallback when the source's own parsing didn't supply one.
    func titleFromMetadata() -> String? {
        stringMetadata(commonKey: .commonKeyTitle)
    }

    /// Artist read straight from the file's embedded metadata (ID3 TPE1,
    /// iTunes ©ART, QuickTime artist atom, etc.). Used as a fallback when
    /// the source's own parsing didn't supply one — this is what makes
    /// artist show up even when a given MediaSource never populates it.
    func artistFromMetadata() -> String? {
        stringMetadata(commonKey: .commonKeyArtist)
    }

    /// Album name read straight from the file's embedded metadata.
    /// Used as a fallback when the source's own parsing didn't supply one.
    func albumFromMetadata() -> String? {
        stringMetadata(commonKey: .commonKeyAlbumName)
    }

    /// Looks up a common metadata key across every metadata format the
    /// asset exposes (not just `commonMetadata`). `commonMetadata` is
    /// supposed to be the union of every format's common-keyed items, but
    /// in practice some ID3/iTunes tags don't get mapped into it — going
    /// straight to `asset.metadata(forFormat:)` per format and matching on
    /// `commonKey` there catches those cases too.
    private func stringMetadata(commonKey: AVMetadataKey) -> String? {
        guard let url = audioFile?.url else { return nil }
        let asset = AVAsset(url: url)

        if let value = asset.commonMetadata
            .first(where: { $0.commonKey == commonKey })?
            .stringValue,
           !value.isEmpty {
            return value
        }

        for format in asset.availableMetadataFormats {
            if let value = asset.metadata(forFormat: format)
                .first(where: { $0.commonKey == commonKey })?
                .stringValue,
               !value.isEmpty {
                return value
            }
        }

        return nil
    }

    func spectrum() -> [Float] {
        guard isPlaying else { return spectrumAnalyzer.silentSnapshot() }
        return spectrumAnalyzer.snapshot()
    }

    func setSpectrumLayout(_ layout: SpectrumLayout) {
        spectrumAnalyzer.setLayout(layout)
    }

    func play() {
        guard audioFile != nil else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                isPlaying = false
                return
            }
        }
        guard schedulePlayback(from: pausedFrame) else { return }
        playerNode.play()
        isPlaying = true
    }

    func pause() {
        pausedFrame = currentFrame()
        playerNode.pause()
        isPlaying = false
        spectrumAnalyzer.reset()
    }

    func stop() {
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        engine.mainMixerNode.removeTap(onBus: 0)
        audioFile = nil
        duration = 0
        playbackStartFrame = 0
        pausedFrame = 0
        isPlaying = false
        spectrumAnalyzer.reset()
    }

    func currentTime() -> TimeInterval {
        guard let file = audioFile else { return 0 }
        return Double(currentFrame()) / file.processingFormat.sampleRate
    }

    func seek(to time: TimeInterval) {
        guard let file = audioFile else { return }
        let wasPlaying = isPlaying
        let frame = AVAudioFramePosition(
            min(
                max(0, time),
                duration
            ) * file.processingFormat.sampleRate
        )
        pausedFrame = min(max(0, frame), file.length)
        playerNode.stop()
        spectrumAnalyzer.reset()
        if wasPlaying {
            play()
        }
    }

    private func installSpectrumTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: engine.mainMixerNode.outputFormat(forBus: 0)
        ) { [weak spectrumAnalyzer] buffer, _ in
            spectrumAnalyzer?.analyze(buffer)
        }
    }

    private func schedulePlayback(from frame: AVAudioFramePosition) -> Bool {
        guard let file = audioFile else { return false }
        let requestedFrame = min(max(0, frame), file.length)
        let startFrame = requestedFrame >= file.length ? 0 : requestedFrame
        let remainingFrames = AVAudioFrameCount(max(0, file.length - startFrame))
        guard remainingFrames > 0 else {
            pausedFrame = 0
            return false
        }

        playbackStartFrame = startFrame
        pausedFrame = startFrame
        playerNode.stop()
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: remainingFrames,
            at: nil
        )
        return true
    }

    private func currentFrame() -> AVAudioFramePosition {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return pausedFrame
        }

        let frame = playbackStartFrame + AVAudioFramePosition(playerTime.sampleTime)
        if let file = audioFile {
            return min(max(0, frame), file.length)
        }
        return max(0, frame)
    }
}

// ================================================================
// MARK: - Live Spectrum Analyzer
// ================================================================
//
// Pipeline, each step isolated so future changes stay contained:
//
//   1. FFT the incoming audio buffer -> raw magnitudes.
//   2. Group magnitudes into `bandResolution` perceptually-spaced bands,
//      ascending bass -> treble (this is the "frequency analysis" step —
//      it never needs to know about layout or display bin count).
//   3. Normalize EACH band against its OWN rolling peak (not a single
//      global peak). This is what fixes bass reading as permanently
//      "full": previously every band was compared against whichever band
//      was loudest that frame — which is nearly always bass in real
//      music — so bass constantly divided by itself and pinned near 1.0.
//      Now every band's 0...1 value reflects its own recent dynamics.
//   4. Hand the normalized, ascending band array to the current
//      `SpectrumLayout`, which arranges it into `binCount` display bins
//      (center-out, left-to-right, etc.). Swap `layout` to support a new
//      visual style — nothing above this step changes.
//   5. Per-slot attack/release smoothing for fluid on-screen motion.
//
private final class LiveSpectrumAnalyzer {
    private let binCount: Int
    private let bandResolution: Int
    private let fftSize: Int
    private let log2FFTSize: vDSP_Length
    private let fftSetup: FFTSetup
    private let lock = NSLock()

    private var window: [Float]
    private var monoSamples: [Float]
    private var realParts: [Float]
    private var imaginaryParts: [Float]
    private var magnitudes: [Float]

    private var bandPeaks: [Float]
    private var smoothedBins: [Float]
    private var latestBins: [Float]
    private var currentLayout: SpectrumLayout = .centerOut

    /// How quickly each band's individual peak relaxes when the signal
    /// drops. Closer to 1.0 = slower fall (smoother, more "floaty"),
    /// closer to 0 = snappier but jitterier.
    private let bandPeakDecay: Float = 0.97

    /// Prevents near-silence from being amplified into visible noise.
    private let minimumBandFloor: Float = 0.02

    init(binCount: Int, bandResolution: Int = 64, fftSize: Int = 1024) {
        self.binCount = binCount
        self.bandResolution = bandResolution
        self.fftSize = fftSize
        self.log2FFTSize = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2FFTSize, FFTRadix(kFFTRadix2))!
        self.window = Array(repeating: 0, count: fftSize)
        self.monoSamples = Array(repeating: 0, count: fftSize)
        self.realParts = Array(repeating: 0, count: fftSize / 2)
        self.imaginaryParts = Array(repeating: 0, count: fftSize / 2)
        self.magnitudes = Array(repeating: 0, count: fftSize / 2)
        self.bandPeaks = Array(repeating: minimumBandFloor, count: bandResolution)
        self.smoothedBins = Array(repeating: 0, count: binCount)
        self.latestBins = Array(repeating: 0, count: binCount)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func setLayout(_ layout: SpectrumLayout) {
        lock.lock()
        currentLayout = layout
        lock.unlock()
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = min(Int(buffer.frameLength), fftSize)
        let channelCount = max(1, Int(buffer.format.channelCount))
        monoSamples.withUnsafeMutableBufferPointer { samples in
            samples.initialize(repeating: 0)
            for frame in 0..<frameCount {
                var total: Float = 0
                for channel in 0..<channelCount {
                    total += channelData[channel][frame]
                }
                samples[frame] = total / Float(channelCount)
            }
        }

        vDSP_vmul(
            monoSamples,
            1,
            window,
            1,
            &monoSamples,
            1,
            vDSP_Length(fftSize)
        )

        realParts.withUnsafeMutableBufferPointer { realBuffer in
            imaginaryParts.withUnsafeMutableBufferPointer { imaginaryBuffer in
                monoSamples.withUnsafeBufferPointer { sampleBuffer in
                    var splitComplex = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imaginaryBuffer.baseAddress!
                    )
                    sampleBuffer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: fftSize / 2
                    ) { complexSamples in
                        vDSP_ctoz(
                            complexSamples,
                            2,
                            &splitComplex,
                            1,
                            vDSP_Length(fftSize / 2)
                        )
                    }
                    vDSP_fft_zrip(
                        fftSetup,
                        &splitComplex,
                        1,
                        log2FFTSize,
                        FFTDirection(FFT_FORWARD)
                    )
                    vDSP_zvmags(
                        &splitComplex,
                        1,
                        &magnitudes,
                        1,
                        vDSP_Length(fftSize / 2)
                    )
                }
            }
        }

        let nextBins = spectrumSnapshot(from: magnitudes)
        lock.lock()
        latestBins = nextBins
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        let bins = latestBins
        lock.unlock()
        return bins
    }

    func silentSnapshot() -> [Float] {
        Array(repeating: 0, count: binCount)
    }

    func reset() {
        lock.lock()
        bandPeaks = Array(repeating: minimumBandFloor, count: bandResolution)
        smoothedBins = Array(repeating: 0, count: binCount)
        latestBins = Array(repeating: 0, count: binCount)
        lock.unlock()
    }

    // ------------------------------------------------------------
    // Step 2 + 3: perceptual banding, then per-band peak normalization.
    // ------------------------------------------------------------
    private func bandEnergies(from magnitudes: [Float]) -> [Float] {
        let usableBins = max(2, magnitudes.count - 2)
        var rawBands = Array(repeating: Float(0), count: bandResolution)

        for index in 0..<bandResolution {
            let lower = frequencyIndex(for: index, usableBins: usableBins, resolution: bandResolution)
            let upper = max(lower + 1, frequencyIndex(for: index + 1, usableBins: usableBins, resolution: bandResolution))
            var total: Float = 0
            var samples = 0
            for magnitudeIndex in lower..<min(upper, magnitudes.count) {
                total += magnitudes[magnitudeIndex]
                samples += 1
            }
            rawBands[index] = samples > 0 ? sqrt(total / Float(samples)) : 0
        }

        var normalizedBands = Array(repeating: Float(0), count: bandResolution)
        for index in 0..<bandResolution {
            let magnitude = rawBands[index]

            // Fast attack, slow release: jump straight to a new peak,
            // otherwise let the peak float back down gradually.
            if magnitude > bandPeaks[index] {
                bandPeaks[index] = magnitude
            } else {
                bandPeaks[index] = max(magnitude, bandPeaks[index] * bandPeakDecay)
            }
            bandPeaks[index] = max(bandPeaks[index], minimumBandFloor)

            let normalized = min(max(magnitude / bandPeaks[index], 0), 1)
            normalizedBands[index] = pow(normalized, 0.52)
        }

        return normalizedBands
    }

    // Steps 2-5 combined for one analysis pass.
    private func spectrumSnapshot(from magnitudes: [Float]) -> [Float] {
        guard binCount > 0 else { return [] }

        let normalizedBands = bandEnergies(from: magnitudes)

        lock.lock()
        let layout = currentLayout
        lock.unlock()

        let arranged = layout.arrange(bands: normalizedBands, totalCount: binCount)

        for index in 0..<binCount {
            let target = arranged[index]
            let coefficient: Float = target > smoothedBins[index] ? 0.72 : 0.36
            smoothedBins[index] += (target - smoothedBins[index]) * coefficient
        }

        return smoothedBins.map { min(max($0, 0), 1) }
    }

    private func frequencyIndex(for visualBin: Int, usableBins: Int, resolution: Int) -> Int {
        let position = Float(visualBin) / Float(max(1, resolution))
        let curved = pow(position, 2.25)
        return min(max(1, Int(curved * Float(usableBins))), usableBins)
    }
}
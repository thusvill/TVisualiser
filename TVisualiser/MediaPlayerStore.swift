import AVFoundation
import Accelerate
import Combine
import CoreImage
import Foundation
import SwiftUI
import UIKit

@MainActor
final class MediaPlayerStore: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = "Select a media source"
    @Published private(set) var artist = "TVisualiser"
    @Published private(set) var album = ""
    @Published private(set) var artwork: UIImage?
    @Published private(set) var waveformColor: Color = .black
    @Published private(set) var waveform = Array(repeating: Float(0), count: 96)
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var activeSourceID: String?

    nonisolated private static let waveformSampleCount = 96

    private let playback = AudioPlaybackEngine()
    private var timer: Timer?

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
        waveform = Self.silentWaveform()
    }

    func select(source: any MediaSource) {
        activeSourceID = source.id
        trackTitle = "No media selected"
        artist = source.displayName
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
                trackTitle = preparedTrack.title
                artist = preparedTrack.artist
                album = preparedTrack.album
                duration = playback.duration
                waveform = Self.silentWaveform()
                currentTime = 0
                let artworkData = preparedTrack.artworkData ?? playback.artworkData()
                artwork = artworkData.flatMap(UIImage.init(data:))
                waveformColor = artwork.flatMap(Self.averageColor) ?? .black
                isPlaying = false
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
            waveform = Self.silentWaveform()
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
                waveform = Self.silentWaveform()
            }
            return
        }
        waveform = playback.spectrum()
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

    func spectrum() -> [Float] {
        guard isPlaying else { return spectrumAnalyzer.silentSnapshot() }
        return spectrumAnalyzer.snapshot()
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

private final class LiveSpectrumAnalyzer {
    private let binCount: Int
    private let fftSize: Int
    private let log2FFTSize: vDSP_Length
    private let fftSetup: FFTSetup
    private let lock = NSLock()
    private var window: [Float]
    private var monoSamples: [Float]
    private var realParts: [Float]
    private var imaginaryParts: [Float]
    private var magnitudes: [Float]
    private var smoothedBins: [Float]
    private var latestBins: [Float]
    private var rollingPeak: Float = 0.12

    init(binCount: Int, fftSize: Int = 1024) {
        self.binCount = binCount
        self.fftSize = fftSize
        self.log2FFTSize = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2FFTSize, FFTRadix(kFFTRadix2))!
        self.window = Array(repeating: 0, count: fftSize)
        self.monoSamples = Array(repeating: 0, count: fftSize)
        self.realParts = Array(repeating: 0, count: fftSize / 2)
        self.imaginaryParts = Array(repeating: 0, count: fftSize / 2)
        self.magnitudes = Array(repeating: 0, count: fftSize / 2)
        self.smoothedBins = Array(repeating: 0, count: binCount)
        self.latestBins = Array(repeating: 0, count: binCount)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
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

        lock.lock()
        let nextBins = spectrumBins(from: magnitudes)
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
        rollingPeak = 0.12
        smoothedBins = Array(repeating: 0, count: binCount)
        latestBins = Array(repeating: 0, count: binCount)
        lock.unlock()
    }

    private func spectrumBins(from magnitudes: [Float]) -> [Float] {
        guard binCount > 0 else { return [] }

        let usableBins = max(2, magnitudes.count - 2)
        var rawBins = Array(repeating: Float(0), count: binCount)
        for index in 0..<binCount {
            let lower = frequencyIndex(for: index, usableBins: usableBins)
            let upper = max(lower + 1, frequencyIndex(for: index + 1, usableBins: usableBins))
            var total: Float = 0
            var samples = 0
            for magnitudeIndex in lower..<min(upper, magnitudes.count) {
                total += magnitudes[magnitudeIndex]
                samples += 1
            }
            rawBins[index] = samples > 0 ? sqrt(total / Float(samples)) : 0
        }

        let currentPeak = max(rawBins.max() ?? 0.0001, 0.0001)
        rollingPeak = max(currentPeak, rollingPeak * 0.90)

        for index in 0..<binCount {
            let normalized = min(max(rawBins[index] / rollingPeak, 0), 1)
            let shaped = pow(normalized, 0.52)
            let coefficient: Float = shaped > smoothedBins[index] ? 0.72 : 0.36
            smoothedBins[index] += (shaped - smoothedBins[index]) * coefficient
        }

        return smoothedBins.map { min(max($0, 0), 1) }
    }

    private func frequencyIndex(for visualBin: Int, usableBins: Int) -> Int {
        let position = Float(visualBin) / Float(max(1, binCount))
        let curved = pow(position, 2.25)
        return min(max(1, Int(curved * Float(usableBins))), usableBins)
    }
}

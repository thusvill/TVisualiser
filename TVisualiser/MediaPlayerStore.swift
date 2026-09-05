import AVFoundation
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

    private let playback = AudioPlaybackEngine()
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
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
        waveform = Array(repeating: 0, count: waveform.count)
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
                waveform = playback.waveformSamples(count: waveform.count)
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
        isPlaying.toggle()
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
        guard isPlaying else { return }
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
}

private final class AudioPlaybackEngine {
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var hasLoadedFile: Bool { player != nil }

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    func load(url: URL) throws {
        player?.stop()
        let nextPlayer = try AVAudioPlayer(contentsOf: url)
        nextPlayer.isMeteringEnabled = true
        nextPlayer.prepareToPlay()
        player = nextPlayer
        duration = nextPlayer.duration
    }

    func artworkData() -> Data? {
        guard let url = player?.url else { return nil }
        let asset = AVAsset(url: url)
        return asset.commonMetadata
            .first(where: { $0.commonKey == .commonKeyArtwork })?
            .dataValue
    }

    func waveformSamples(count: Int) -> [Float] {
        guard let url = player?.url, count > 0,
              let file = try? AVAudioFile(forReading: url) else {
            return Array(repeating: 0.04, count: count)
        }

        let totalFrames = Int(file.length)
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: 4096
              ) else {
            return Array(repeating: 0.04, count: count)
        }

        var peaks = Array(repeating: Float(0), count: count)
        var processedFrames = 0
        while processedFrames < totalFrames {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<frameCount {
                let index = min(count - 1, (processedFrames + frame) * count / totalFrames)
                var peak: Float = 0
                for channel in 0..<Int(buffer.format.channelCount) {
                    peak = max(peak, abs(channels[channel][frame]))
                }
                peaks[index] = max(peaks[index], peak)
            }
            processedFrames += frameCount
        }

        let maximum = peaks.max() ?? 1
        return peaks.map { value in
            guard maximum > 0 else { return Float(0.04) }
            return max(0.04, min(1, value / maximum))
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = player.isPlaying
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        player?.stop()
        player = nil
        duration = 0
        isPlaying = false
    }

    func currentTime() -> TimeInterval {
        player?.currentTime ?? 0
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
    }
}

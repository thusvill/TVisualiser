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
                currentTime = 0
                artwork = preparedTrack.artworkData.flatMap(UIImage.init(data:))
                waveformColor = .black
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
        nextPlayer.prepareToPlay()
        player = nextPlayer
        duration = nextPlayer.duration
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

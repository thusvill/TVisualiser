import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ReceiverStore: ObservableObject {
    @Published private(set) var isReceiving = false
    @Published private(set) var trackTitle = "Waiting for AirPlay"
    @Published private(set) var artist = "TVisualiser"
    @Published private(set) var album = ""
    @Published private(set) var artwork: UIImage?
    @Published private(set) var audioLevel: Float = 0.08
    @Published private(set) var waveform = Array(repeating: Float(0), count: 96)

    private let server = RTSPServer()
    private let playback = AudioPlaybackEngine()
    private var lastPacketTime = Date.distantPast
    private var timer: Timer?

    func start() {
        DebugSettings.log("Starting receiver store")
        server.onAnnounceReceived = { [weak self] request in
            Task { @MainActor in self?.handleAnnounce(request) }
        }
        server.onAudioDataReceived = { [weak self] data in
            Task { @MainActor in self?.handleAudioPacket(data) }
        }
        server.start(tcpPort: 5000, udpAudioPort: 6000)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastPacketTime) > 1.0 {
                self.isReceiving = false
                self.audioLevel *= 0.82
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server.stop()
        playback.stop()
    }

    private func handleAnnounce(_ request: String) {
        DebugSettings.log("ANNOUNCE received")
        isReceiving = true
        let fields = request.components(separatedBy: "\r\n")
        for field in fields {
            if field.hasPrefix("a=min-latency:") { continue }
            if field.hasPrefix("a=title:") { trackTitle = String(field.dropFirst("a=title:".count)) }
            if field.hasPrefix("a=artist:") { artist = String(field.dropFirst("a=artist:".count)) }
            if field.hasPrefix("a=album:") { album = String(field.dropFirst("a=album:".count)) }
        }
    }

    private func handleAudioPacket(_ data: Data) {
        guard data.count > 12 else { return }
        DebugSettings.log("Analyzing audio packet payload: \(data.count - 12) bytes")
        isReceiving = true
        lastPacketTime = Date()

        let payload = data.dropFirst(12)
        var values = [Float]()
        values.reserveCapacity(waveform.count)
        for byte in payload {
            values.append(abs(Float(Int(byte) - 128) / 128.0))
        }
        guard !values.isEmpty else { return }

        let stride = max(1, values.count / waveform.count)
        waveform = (0..<waveform.count).map { index in
            let start = min(index * stride, values.count - 1)
            let end = min(start + stride, values.count)
            return values[start..<end].reduce(0, +) / Float(max(1, end - start))
        }
        audioLevel = waveform.reduce(0, +) / Float(waveform.count)
    }
}

private final class AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)

    init() {
        engine.attach(player)
        if let format {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer)
        if !engine.isRunning {
            try? engine.start()
        }
        if !player.isPlaying { player.play() }
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}

import AVFoundation
import Combine
import CoreImage
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ReceiverStore: ObservableObject {
    @Published private(set) var isReceiving = false
    @Published private(set) var isPlaying = true
    @Published private(set) var trackTitle = "Waiting for AirPlay"
    @Published private(set) var artist = "TVisualiser"
    @Published private(set) var album = ""
    @Published private(set) var artwork: UIImage?
    @Published private(set) var waveformColor: Color = .black
    @Published private(set) var audioLevel: Float = 0.08
    @Published private(set) var waveform = Array(repeating: Float(0), count: 96)
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 210

    private let server = RTSPServer()
    private let playback = AudioPlaybackEngine()
    private var lastPacketTime = Date.distantPast
    private var lastWaveformUpdate = Date.distantPast
    private var waveformBuffer: [Float] = Array(repeating: 0, count: 96)
    private var timer: Timer?

    func start() {
        DebugSettings.log("Starting receiver store")
        server.onAnnounceReceived = { [weak self] request in
            Task { @MainActor in self?.handleAnnounce(request) }
        }
        server.onMetadataReceived = { [weak self] data in
            Task { @MainActor in self?.handleMetadata(data) }
        }
        server.onAudioDataReceived = { [weak self] data in
            Task { @MainActor in self?.handleAudioPacket(data) }
        }
        server.start(tcpPort: 5000, udpAudioPort: 6000)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastPacketTime) > 1.0 {
                    self.isReceiving = false
                    self.audioLevel *= 0.82
                }
                if self.isPlaying {
                    self.currentTime = min(self.currentTime + 0.1, self.duration)
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server.stop()
        playback.stop()
    }

    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            playback.play()
            lastPacketTime = Date()
        } else {
            playback.pause()
        }
    }

    func skipBackward() {
        currentTime = max(0, currentTime - 10)
    }

    func skipForward() {
        currentTime = min(duration, currentTime + 10)
    }

    private func handleAnnounce(_ request: String) {
        DebugSettings.log("ANNOUNCE received")
        isReceiving = true
        lastPacketTime = Date()
        let fields = request.components(separatedBy: "\r\n")
        for field in fields {
            if field.hasPrefix("a=min-latency:") { continue }
            if field.hasPrefix("a=title:") { trackTitle = String(field.dropFirst("a=title:".count)) }
            if field.hasPrefix("a=artist:") { artist = String(field.dropFirst("a=artist:".count)) }
            if field.hasPrefix("a=album:") { album = String(field.dropFirst("a=album:".count)) }
        }
    }

    private func handleMetadata(_ data: Data) {
        DebugSettings.log("DMAP metadata received: \(data.count) bytes")
        isReceiving = true
        lastPacketTime = Date()

        var offset = data.startIndex
        while offset + 8 <= data.endIndex {
            let code = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let length = data[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
            let valueStart = offset + 8
            let valueEnd = valueStart + Int(length)
            guard valueEnd <= data.endIndex else { break }

            let valueData = data[valueStart..<valueEnd]
            if code == "covr" {
                if let image = normalizeArtwork(valueData) {
                    artwork = image
                    waveformColor = image.averageColor()
                }
            } else if let value = String(data: valueData, encoding: .utf8) {
                let cleaned = sanitizeText(value)
                switch code {
                case "minm": trackTitle = cleaned.isEmpty ? "Unknown Title" : cleaned
                case "asar": artist = cleaned.isEmpty ? "Unknown Artist" : cleaned
                case "asal": album = cleaned.isEmpty ? "Unknown Album" : cleaned
                default: break
                }
            }
            offset = valueEnd
        }
    }

    private func handleAudioPacket(_ data: Data) {
        guard data.count >= 12 else { return }
        let isRTP = (data[data.startIndex] & 0xC0) == 0x80
        let payload = isRTP ? data.dropFirst(12) : data[...]
        guard payload.count >= 4 else { return }
        DebugSettings.log("Playing \(isRTP ? "RTP/L16" : "PCM fallback") packet: \(payload.count) bytes")
        isReceiving = true
        lastPacketTime = Date()

        var littleEndianPCM = Data(capacity: payload.count)
        if isRTP {
            for index in stride(from: payload.startIndex, to: payload.endIndex - 1, by: 2) {
                littleEndianPCM.append(payload[index + 1])
                littleEndianPCM.append(payload[index])
            }
        } else {
            littleEndianPCM.append(contentsOf: payload)
        }

        let sampleCount = littleEndianPCM.count / MemoryLayout<Int16>.size
        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { littleEndianPCM.copyBytes(to: $0) }
        let frameCount = sampleCount / 2
        guard frameCount > 0 else { return }

        let stride = max(1, frameCount / waveformBuffer.count)
        var nextWaveform = waveformBuffer
        var total: Float = 0
        for index in 0..<waveformBuffer.count {
            let start = min(index * stride, max(0, frameCount - 1))
            let end = min(start + stride, frameCount)
            var segmentTotal: Float = 0
            var segmentCount = 0
            for frame in start..<end {
                guard frame * 2 + 1 < samples.count else { continue }
                let left = abs(Float(samples[frame * 2])) / Float(Int16.max)
                let right = abs(Float(samples[frame * 2 + 1])) / Float(Int16.max)
                let value = ((left + right) / 2)
                let finiteValue = value.isFinite ? value : 0
                segmentTotal += finiteValue
                segmentCount += 1
            }
            let avg = segmentCount == 0 ? 0 : segmentTotal / Float(segmentCount)
            let safeValue = Self.clamp(avg, min: 0, max: 1)
            nextWaveform[index] = safeValue
            total += safeValue
        }

        let now = Date()
        if now.timeIntervalSince(lastWaveformUpdate) >= 0.05 {
            waveformBuffer = nextWaveform
            waveform = waveformBuffer
            audioLevel = total / Float(max(1, waveformBuffer.count))
            audioLevel = audioLevel.isFinite ? audioLevel : 0
            lastWaveformUpdate = now
        }

        playback.enqueuePCM(littleEndianPCM, frameCount: frameCount)
    }

    private func normalizeArtwork(_ data: Data) -> UIImage? {
        guard data.count > 0, data.count < 10_000_000 else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1200
        let size = image.size
        let maxDimension = max(size.width, size.height)
        guard maxDimension > maxSide else { return image }
        let scale = maxSide / maxDimension
        let drawSize = CGSize(width: max(size.width * scale, 1), height: max(size.height * scale, 1))
        let renderer = UIGraphicsImageRenderer(size: drawSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: drawSize))
        }
    }

    private func sanitizeText(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            guard scalar.value >= 32 || scalar == "\n" || scalar == "\r" || scalar == "\t" else { return false }
            return true
        }
        let text = String(String.UnicodeScalarView(filtered))
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }
}

private extension ReceiverStore {
    static func clamp(_ value: Float, min: Float, max: Float) -> Float {
        Swift.min(Swift.max(value, min), max)
    }
}

// MARK: - Average color extraction for dynamic waveform tint

private extension UIImage {
    func averageColor() -> Color {
        guard let inputImage = CIImage(image: self) else { return .black }
        let extentVector = CIVector(
            x: inputImage.extent.origin.x,
            y: inputImage.extent.origin.y,
            z: inputImage.extent.size.width,
            w: inputImage.extent.size.height
        )
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]
        ), let outputImage = filter.outputImage else {
            return .black
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return Color(
            red: Double(bitmap[0]) / 255,
            green: Double(bitmap[1]) / 255,
            blue: Double(bitmap[2]) / 255
        )
    }
}

private final class AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 44_100,
        channels: 2,
        interleaved: false
    )
    var isPlaying = false

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        engine.attach(player)
        if let format {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    func play() {
        if !engine.isRunning {
            try? engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func enqueuePCM(_ data: Data, frameCount: Int) {
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBytes in
            guard let source = rawBytes.bindMemory(to: Int16.self).baseAddress,
                  let channels = buffer.int16ChannelData else { return }
            for frame in 0..<frameCount {
                channels[0][frame] = source[frame * 2]
                channels[1][frame] = source[frame * 2 + 1]
            }
        }
        enqueue(buffer)
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer)
        if !engine.isRunning {
            try? engine.start()
        }
        if !player.isPlaying { player.play() }
        isPlaying = true
    }

    func stop() {
        player.stop()
        engine.stop()
        isPlaying = false
    }
}
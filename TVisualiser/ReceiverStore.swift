
import AVFoundation
import Combine
import CoreImage
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ReceiverStore: ObservableObject {

    // MARK: - Published UI State

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
    @Published private(set) var duration: TimeInterval = 0

    // MARK: - Private

    private let server = RTSPServer()
    private let playback = AudioPlaybackEngine()

    private var lastPacketTime = Date.distantPast
    private var lastWaveformUpdate = Date.distantPast

    private var waveformBuffer: [Float] =
        Array(repeating: 0, count: 96)

    private var playbackStartDate: Date?
    private var pausedPosition: TimeInterval = 0
    private var timer: Timer?

    // MARK: - Lifecycle

    func start() {
        DebugSettings.log("Starting receiver store")

        // RTSP / metadata callbacks can arrive on arbitrary queues.
        server.onAnnounceReceived = { [weak self] request in
            Task { @MainActor [weak self] in
                self?.handleAnnounce(request)
            }
        }

        server.onMetadataReceived = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.handleMetadata(data)
            }
        }

        // IMPORTANT:
        // Audio packets must NOT be pushed through MainActor.
        server.onAudioDataReceived = { [weak self] data in
            self?.handleAudioPacket(data)
        }

        server.onPlaybackCommandReceived = { [weak self] method in
            Task { @MainActor [weak self] in
                self?.handlePlaybackCommand(method)
            }
        }

        server.start(
            tcpPort: 5000,
            udpAudioPort: 6000
        )

        // Start the playback engine.
        playback.play()

        timer = Timer.scheduledTimer(
            withTimeInterval: 0.05,
            repeats: true
        ) { [weak self] _ in

            Task { @MainActor [weak self] in
                guard let self else { return }

                self.updatePlaybackState()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        server.stop()
        playback.stop()

        isReceiving = false
        isPlaying = false

        currentTime = 0
        duration = 0
        audioLevel = 0

        waveformBuffer = Array(
            repeating: 0,
            count: waveformBuffer.count
        )

        waveform = waveformBuffer
    }

    // MARK: - Playback Controls

    func togglePlayback() {
        if isPlaying {
            playback.pause()
            isPlaying = false
            pausedPosition = currentTime
            playbackStartDate = nil
        } else {
            playback.play()
            isPlaying = true
            lastPacketTime = Date()
            playbackStartDate = Date().addingTimeInterval(-pausedPosition)
        }
    }

    private func handlePlaybackCommand(_ method: String) {
        switch method.uppercased() {
        case "PLAY":
            playback.play()
            isPlaying = true
            lastPacketTime = Date()
            playbackStartDate = Date().addingTimeInterval(-pausedPosition)
        case "PAUSE":
            playback.pause()
            isPlaying = false
            pausedPosition = currentTime
            playbackStartDate = nil
        case "FLUSH", "TEARDOWN":
            playback.pause()
            isPlaying = false
            pausedPosition = 0
            playbackStartDate = nil
            currentTime = 0
        default:
            break
        }
    }

    func skipBackward() {
        let newTime = max(
            0,
            currentTime - 10
        )
        currentTime = newTime
        pausedPosition = newTime
        if isPlaying {
            playbackStartDate = Date().addingTimeInterval(-newTime)
        }
    }

    func skipForward() {
        if duration > 0 {
            let newTime = min(
                duration,
                currentTime + 10
            )
            currentTime = newTime
            pausedPosition = newTime
            if isPlaying {
                playbackStartDate = Date().addingTimeInterval(-newTime)
            }
        }
    }

    // MARK: - Playback State

    private func updatePlaybackState() {

        let now = Date()

        // No packets for more than one second.
        if now.timeIntervalSince(lastPacketTime) > 1.0 {
            isReceiving = false

            audioLevel *= 0.82

            if audioLevel < 0.001 {
                audioLevel = 0
            }
        }

        guard isPlaying else {
            pausedPosition = currentTime
            return
        }

        let actualTime = playback.currentTime()

        if actualTime.isFinite && actualTime > 0 {
            if duration > 0 {
                currentTime = min(
                    max(0, actualTime),
                    duration
                )
            } else {
                currentTime = max(
                    0,
                    actualTime
                )
            }
            pausedPosition = currentTime
            return
        }

        let elapsed = playbackStartDate.map {
            now.timeIntervalSince($0)
        } ?? 0

        let resolvedTime = max(
            0,
            pausedPosition + elapsed
        )

        if duration > 0 {
            currentTime = min(
                resolvedTime,
                duration
            )
        } else {
            currentTime = resolvedTime
        }

        pausedPosition = currentTime
    }

    // MARK: - AirPlay ANNOUNCE

    private func handleAnnounce(_ request: String) {
        DebugSettings.log("ANNOUNCE received")

        isReceiving = true
        lastPacketTime = Date()

        currentTime = 0
        duration = 0

        let fields = request.components(
            separatedBy: "\r\n"
        )

        for field in fields {

            if field.hasPrefix("a=min-latency:") {
                continue
            }

            if field.hasPrefix("a=title:") {
                trackTitle = String(
                    field.dropFirst(
                        "a=title:".count
                    )
                )
            }

            if field.hasPrefix("a=artist:") {
                artist = String(
                    field.dropFirst(
                        "a=artist:".count
                    )
                )
            }

            if field.hasPrefix("a=album:") {
                album = String(
                    field.dropFirst(
                        "a=album:".count
                    )
                )
            }
        }
    }

    // MARK: - DMAP Metadata

    private func handleMetadata(_ data: Data) {
        DebugSettings.log(
            "DMAP metadata received: \(data.count) bytes"
        )

        isReceiving = true
        lastPacketTime = Date()

        var offset = data.startIndex

        while offset + 8 <= data.endIndex {

            let code = String(
                data: data[offset..<(offset + 4)],
                encoding: .ascii
            ) ?? ""

            let length = data[
                (offset + 4)..<(offset + 8)
            ].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }

            let valueStart = offset + 8
            let valueEnd = valueStart + Int(length)

            guard valueEnd <= data.endIndex else {
                break
            }

            let valueData = data[
                valueStart..<valueEnd
            ]

            switch code {

            case "covr":

                if let image = normalizeArtwork(valueData) {
                    artwork = image
                    waveformColor = image.averageColor()
                }

            case "mper":

                guard valueData.count >= 4 else {
                    offset = valueEnd
                    continue
                }

                var value: UInt32 = 0

                for byte in valueData.prefix(4) {
                    value = (value << 8) | UInt32(byte)
                }

                let milliseconds = Double(value)

                if milliseconds > 0 {
                    duration = milliseconds / 1000.0

                    if currentTime > duration {
                        currentTime = 0
                        pausedPosition = 0
                        playbackStartDate = Date()
                    }
                }

            default:

                if let value = String(
                    data: valueData,
                    encoding: .utf8
                ) {

                    let cleaned = sanitizeText(value)

                    switch code {

                    case "minm":
                        trackTitle =
                            cleaned.isEmpty
                            ? "Unknown Title"
                            : cleaned

                    case "asar":
                        artist =
                            cleaned.isEmpty
                            ? "Unknown Artist"
                            : cleaned

                    case "asal":
                        album =
                            cleaned.isEmpty
                            ? "Unknown Album"
                            : cleaned

                    default:
                        break
                    }
                }
            }

            offset = valueEnd
        }
    }

    // MARK: - RTP Audio

    // IMPORTANT:
    //
    // This function is intentionally NOT @MainActor.
    //
    // RTP packets should be processed away from SwiftUI/MainActor
    // so audio processing does not block UI or Core Audio.
    private nonisolated func handleAudioPacket(_ data: Data) {

        guard data.count >= 12 else {
            return
        }

        let isRTP =
            (data[data.startIndex] & 0xC0) == 0x80

        let payload: Data

        if isRTP {
            payload = Data(
                data.dropFirst(12)
            )
        } else {
            payload = data
        }

        guard payload.count >= 4 else {
            return
        }

        // RTP/L16 is big-endian PCM.
        // Convert it to little-endian Int16 PCM.
        var littleEndianPCM = Data(
            capacity: payload.count
        )

        if isRTP {

            var index = payload.startIndex

            while index + 1 < payload.endIndex {

                littleEndianPCM.append(
                    payload[index + 1]
                )

                littleEndianPCM.append(
                    payload[index]
                )

                index += 2
            }

        } else {

            littleEndianPCM.append(
                contentsOf: payload
            )
        }

        let sampleCount =
            littleEndianPCM.count /
            MemoryLayout<Int16>.size

        let frameCount = sampleCount / 2

        guard frameCount > 0 else {
            return
        }

        // Build waveform from this packet.
        let packetWaveform =
            Self.makeWaveform(
                pcm: littleEndianPCM,
                frameCount: frameCount,
                bucketCount: 96
            )

        let level = Self.waveformAverage(
            packetWaveform
        )

        // Feed audio immediately.
        playback.enqueuePCM(
            littleEndianPCM,
            frameCount: frameCount
        )

        // UI updates are throttled to ~20 FPS.
        let now = Date()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            self.isReceiving = true
            self.lastPacketTime = now

            if now.timeIntervalSince(
                self.lastWaveformUpdate
            ) >= 0.05 {

                self.waveformBuffer =
                    packetWaveform

                self.waveform =
                    packetWaveform

                self.audioLevel =
                    level.isFinite
                    ? Self.clamp(
                        level,
                        min: 0,
                        max: 1
                    )
                    : 0

                self.lastWaveformUpdate = now
            }
        }
    }

    // MARK: - Waveform Processing

    private nonisolated static func makeWaveform(
        pcm: Data,
        frameCount: Int,
        bucketCount: Int
    ) -> [Float] {

        guard frameCount > 0 else {
            return Array(
                repeating: 0,
                count: bucketCount
            )
        }

        var samples = [Int16](
            repeating: 0,
            count: frameCount * 2
        )

        pcm.withUnsafeBytes { rawBytes in

            guard let source =
                rawBytes.bindMemory(
                    to: Int16.self
                ).baseAddress
            else {
                return
            }

            samples.withUnsafeMutableBufferPointer {
                destination in

                destination.baseAddress?.assign(
                    from: source,
                    count: min(
                        destination.count,
                        frameCount * 2
                    )
                )
            }
        }

        var result = [Float](
            repeating: 0,
            count: bucketCount
        )

        let framesPerBucket =
            max(
                1,
                Int(
                    ceil(
                        Double(frameCount) /
                        Double(bucketCount)
                    )
                )
            )

        for bucket in 0..<bucketCount {

            let start =
                min(
                    bucket * framesPerBucket,
                    frameCount - 1
                )

            let end =
                min(
                    start + framesPerBucket,
                    frameCount
                )

            var total: Float = 0
            var count = 0

            if start < end {

                for frame in start..<end {

                    let left =
                        abs(
                            Float(
                                samples[frame * 2]
                            )
                        ) /
                        Float(Int16.max)

                    let right =
                        abs(
                            Float(
                                samples[frame * 2 + 1]
                            )
                        ) /
                        Float(Int16.max)

                    let value =
                        (left + right) * 0.5

                    if value.isFinite {
                        total += value
                        count += 1
                    }
                }
            }

            let average =
                count > 0
                ? total / Float(count)
                : 0

            result[bucket] =
                Self.clamp(
                    average,
                    min: 0,
                    max: 1
                )
        }

        return result
    }

    private nonisolated static func waveformAverage(
        _ waveform: [Float]
    ) -> Float {

        guard !waveform.isEmpty else {
            return 0
        }

        let total =
            waveform.reduce(
                Float(0),
                +
            )

        return total /
            Float(waveform.count)
    }

    // MARK: - Artwork

    private func normalizeArtwork(
        _ data: Data
    ) -> UIImage? {

        guard
            data.count > 0,
            data.count < 10_000_000
        else {
            return nil
        }

        guard let image = UIImage(
            data: data
        ) else {
            return nil
        }

        let maxSide: CGFloat = 1200

        let size = image.size

        let maxDimension =
            max(
                size.width,
                size.height
            )

        guard maxDimension > maxSide else {
            return image
        }

        let scale =
            maxSide /
            maxDimension

        let drawSize = CGSize(
            width: max(
                size.width * scale,
                1
            ),
            height: max(
                size.height * scale,
                1
            )
        )

        let renderer =
            UIGraphicsImageRenderer(
                size: drawSize
            )

        return renderer.image { _ in
            image.draw(
                in: CGRect(
                    origin: .zero,
                    size: drawSize
                )
            )
        }
    }

    // MARK: - Text

    private func sanitizeText(
        _ value: String
    ) -> String {

        let filtered =
            value.unicodeScalars.filter { scalar in

                guard
                    scalar.value >= 32 ||
                    scalar == "\n" ||
                    scalar == "\r" ||
                    scalar == "\t"
                else {
                    return false
                }

                return true
            }

        let text =
            String(
                String.UnicodeScalarView(
                    filtered
                )
            )

        return String(
            text
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .prefix(80)
        )
    }

    private nonisolated static func clamp(
        _ value: Float,
        min: Float,
        max: Float
    ) -> Float {

        Swift.min(
            Swift.max(
                value,
                min
            ),
            max
        )
    }
}

// MARK: - Average Color

private extension UIImage {

    func averageColor() -> Color {

        guard let inputImage =
            CIImage(image: self)
        else {
            return .black
        }

        let extentVector = CIVector(
            x: inputImage.extent.origin.x,
            y: inputImage.extent.origin.y,
            z: inputImage.extent.size.width,
            w: inputImage.extent.size.height
        )

        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: inputImage,
                kCIInputExtentKey: extentVector
            ]
        ),
        let outputImage = filter.outputImage
        else {
            return .black
        }

        var bitmap = [UInt8](
            repeating: 0,
            count: 4
        )

        let context = CIContext(
            options: [
                .workingColorSpace:
                    kCFNull as Any
            ]
        )

        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(
                x: 0,
                y: 0,
                width: 1,
                height: 1
            ),
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

// MARK: - Audio Playback Engine

private final class AudioPlaybackEngine {

    private let engine =
        AVAudioEngine()

    private let player =
        AVAudioPlayerNode()

    private let format =
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )

    private(set) var isPlaying = false

    init() {

        let session =
            AVAudioSession.sharedInstance()

        try? session.setCategory(
            .playback,
            mode: .moviePlayback,
            options: []
        )

        try? session.setActive(true)

        engine.attach(player)

        if let format {

            engine.connect(
                player,
                to: engine.mainMixerNode,
                format: format
            )
        }
    }

    // MARK: Playback

    func play() {

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                DebugSettings.log(
                    "Audio engine start failed: \(error)"
                )
                return
            }
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

    func stop() {

        player.stop()

        engine.stop()

        isPlaying = false
    }

    // MARK: Actual Playback Position

    func currentTime() -> TimeInterval {

        guard player.isPlaying else {
            return 0
        }

        guard let nodeTime =
            player.lastRenderTime
        else {
            return 0
        }

        guard let playerTime =
            player.playerTime(
                forNodeTime: nodeTime
            )
        else {
            return 0
        }

        guard
            playerTime.sampleRate > 0,
            playerTime.sampleTime >= 0
        else {
            return 0
        }

        let seconds =
            Double(playerTime.sampleTime) /
            playerTime.sampleRate

        return seconds.isFinite
            ? max(0, seconds)
            : 0
    }

    // MARK: PCM Queue

    func enqueuePCM(
        _ data: Data,
        frameCount: Int
    ) {

        guard frameCount > 0 else {
            return
        }

        guard let format else {
            return
        }

        guard let buffer =
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity:
                    AVAudioFrameCount(
                        frameCount
                    )
            )
        else {
            return
        }

        buffer.frameLength =
            AVAudioFrameCount(
                frameCount
            )

        data.withUnsafeBytes { rawBytes in

            guard let source =
                rawBytes.bindMemory(
                    to: Int16.self
                ).baseAddress
            else {
                return
            }

            guard let channels =
                buffer.int16ChannelData
            else {
                return
            }

            for frame in 0..<frameCount {

                channels[0][frame] =
                    source[frame * 2]

                channels[1][frame] =
                    source[frame * 2 + 1]
            }
        }

        // Schedule the buffer.
        player.scheduleBuffer(
            buffer
        )

        // DO NOT automatically start playback here.
        //
        // This is important because incoming RTP packets
        // must not override the user's pause state.
        if isPlaying &&
            !player.isPlaying {

            player.play()
        }
    }
}


//
//  ContentView.swift
//  TVisualiser
//
//  Created by mac on 2026-09-04.
//

import SwiftUI
import UIKit

// ================================================================
// MARK: - ContentView
// ================================================================

struct ContentView: View {

    @EnvironmentObject private var receiver: MediaPlayerStore
    @EnvironmentObject private var ftp: FTPAccountStore

    // ------------------------------------------------------------
    // Settings
    // ------------------------------------------------------------

    @AppStorage("showClock")
    private var showClock: Bool = true

    @AppStorage("dynamicWaveformColor")
    private var dynamicWaveformColor: Bool = true

    @AppStorage("waveformLineWidth")
    private var waveformLineWidth: Double = 2.0

    @AppStorage("waveformSensitivity")
    private var waveformSensitivity: Double = 1.0

    // ------------------------------------------------------------
    // State
    // ------------------------------------------------------------

    @State private var presentedSheet: PresentedSheet?

    @Namespace private var focusNamespace

    // ============================================================
    // MARK: Body
    // ============================================================

    var body: some View {

    GeometryReader { geometry in
        let width = geometry.size.width
        let height = geometry.size.height
        let artworkSize = min(width * 0.27, height * 0.34, 330)
        let playerCardWidth = min(width * 0.48, 760)

        ZStack {
            VStack(spacing: 0) {

                HeaderView(
                    showClock: showClock,
                    onMedia: { showingMediaLibrary = true },
                    onSettings: { showingSettings = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .focusSection()
                Spacer(minLength: 0)

                // Plain, non-focusable content — nothing here should
                // ever hold focus or intercept the D-pad.
                VStack(spacing: 18) {
                    AlbumArtView(artwork: receiver.artwork, side: artworkSize)
                    MetadataView(title: receiver.trackTitle, artist: receiver.artist, album: receiver.album)
                        .frame(maxWidth: 720)
                    AudioVisualizerView(
                        data: receiver.waveform,
                        color: dynamicWaveformColor ? receiver.waveformColor : .black,
                        sensitivity: waveformSensitivity,
                        lineWidth: waveformLineWidth
                    )
                    .frame(width: width, height: 72)
                }
                .frame(maxWidth: .infinity, maxHeight: min(height * 0.62, 440), alignment: .center)
                .padding(.top, 24)

                Spacer(minLength: 0)

                MediaControlCard(
                    currentTime: receiver.currentTime,
                    duration: receiver.duration,
                    isPlaying: receiver.isPlaying,
                    onBackward: { receiver.skipBackward() },
                    onPlayPause: { receiver.togglePlayback() },
                    onForward: { receiver.skipForward() },
                    focusNamespace: focusNamespace
                )
                .frame(width: playerCardWidth)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
        }
        .background(background.ignoresSafeArea())
    }
    .preferredColorScheme(.light)
    .onPlayPauseCommand {
        receiver.togglePlayback()
    }
    
    .sheet(isPresented: $showingSettings) {
    SettingsView()
        .environmentObject(receiver)
        .environmentObject(ftp)
}
.sheet(isPresented: $showingMediaLibrary) {
    MediaLibraryView()
        .environmentObject(receiver)
        .environmentObject(ftp)
}
}
}

// ================================================================
// MARK: - Background
// ================================================================

private extension ContentView {

    var background: some View {

        ZStack {

            // ------------------------------------------------------
            // Base background
            // ------------------------------------------------------

            Color(
                white: 0.93
            )
            .ignoresSafeArea()

            // ------------------------------------------------------
            // Full-screen blurred artwork
            // ------------------------------------------------------

            if let artwork = receiver.artwork {

                Image(
                    uiImage: artwork
                )
                .resizable()
                .scaledToFill()
                .scaleEffect(1.2)
                .blur(
                    radius: 20
                )
                .saturation(1.15)
                .opacity(1)
                .ignoresSafeArea()

//                RadialGradient(
//                    colors: [
//                        receiver.waveformColor
//                            .opacity(0.34),
//
//                        receiver.waveformColor
//                            .opacity(0.18),
//
//                        Color.clear
//                    ],
//                    center: .center,
//                    startRadius: 5,
//                    endRadius: 50
//                )
//                .ignoresSafeArea()
            }

            // ------------------------------------------------------
            // Soft warm wash to keep the blur visible
            // ------------------------------------------------------

//            LinearGradient(
//                colors: [
//                    Color.white.opacity(0.00),
//                    Color(white: 0.92).opacity(0.08),
//                    Color(white: 0.95).opacity(0.08)
//                ],
//                startPoint: .top,
//                endPoint: .bottom
//            )
//            .ignoresSafeArea()

            // ------------------------------------------------------
            // Subtle darkening to preserve contrast
            // ------------------------------------------------------

            Color.black.opacity(0.08)
                .ignoresSafeArea()

            // ------------------------------------------------------
            // Center highlight
            // ------------------------------------------------------

//            RadialGradient(
//                colors: [
//                    Color.white.opacity(0.25),
//                    Color.clear
//                ],
//                center: .center,
//                startRadius: 120,
//                endRadius: 700
//            )
//            .ignoresSafeArea()
        }
    }

}

// ================================================================
// MARK: - Header
// ================================================================

struct HeaderView: View {

    let showClock: Bool
    let onMedia: () -> Void
    let onSettings: () -> Void

    var body: some View {

        ZStack {

            // ======================================================
            // Settings
            // ======================================================

            VStack {

                HStack {

                    Button(action: onMedia) {
                        Label("Media", systemImage: "music.note.list")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(Color.white.opacity(0.82), in: Capsule())
                    }
                    .buttonStyle(TVButtonStyle())

                    Button(
                        action: onSettings
                    ) {

                        HStack(
                            spacing: 10
                        ) {

                            Image(
                                systemName:
                                    "gearshape.fill"
                            )
                            .font(
                                .system(
                                    size: 19,
                                    weight: .semibold
                                )
                            )

                            Text(
                                "Select to open settings"
                            )
                            .font(
                                .system(
                                    size: 17,
                                    weight: .medium,
                                    design: .rounded
                                )
                            )
                        }
                        .foregroundStyle(
                            .black
                        )
                        .padding(
                            .horizontal,
                            18
                        )
                        .padding(
                            .vertical,
                            11
                        )
                        .background(
                            Color.white.opacity(0.82),
                            in: Capsule()
                        )
                        .overlay {

                            Capsule()
                                .stroke(
                                    Color.white.opacity(0.90),
                                    lineWidth: 1
                                )
                        }
                        .shadow(
                            color: .black.opacity(0.12),
                            radius: 12,
                            x: 0,
                            y: 5
                        )
                    }
                    .buttonStyle(
                        TVButtonStyle()
                    )

                    Spacer()
                }

                Spacer()
            }
            .padding(
                .top,
                24
            )
            .padding(
                .leading,
                30
            )

            // ======================================================
            // Clock
            // ======================================================

            if showClock {

                VStack {

                    HStack {

                        Spacer()

                        TimelineView(
                            .periodic(
                                from: .now,
                                by: 1
                            )
                        ) { context in

                            ClockView(
                                date: context.date
                            )
                        }
                    }

                    Spacer()
                }
                .padding(
                    .top,
                    20
                )
                .padding(
                    .trailing,
                    32
                )
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
    }
}

// ================================================================
// MARK: - Button Style
// ================================================================

struct TVButtonStyle: ButtonStyle {

    @Environment(\.isFocused) private var isFocused

    func makeBody(
        configuration: Configuration
    ) -> some View {

        configuration.label
            .scaleEffect(
                configuration.isPressed
                    ? 0.94
                    : 1.0
            )
            .opacity(
                configuration.isPressed
                    ? 0.75
                    : 1.0
            )
            .scaleEffect(
                isFocused
                    ? 1.10
                    : 1.0
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .stroke(
                        Color.black.opacity(0.72),
                        lineWidth: 3
                    )
                    .padding(-7)
                }
            }
            .animation(
                .easeOut(
                    duration: 0.10
                ),
                value: configuration.isPressed
            )
            .animation(
                .easeOut(duration: 0.12),
                value: isFocused
            )
    }
}

// ================================================================
// MARK: - Album Art
// ================================================================

struct AlbumArtView: View {

    let artwork: UIImage?
    let side: CGFloat

    var body: some View {

        Group {

            if let artwork {

                Image(
                    uiImage: artwork
                )
                .resizable()
                .scaledToFill()

            } else {

                ZStack {

                    Color.white.opacity(0.74)

                    VStack(
                        spacing: 12
                    ) {

                        Image(
                            systemName:
                                "music.note"
                        )
                        .font(
                            .system(
                                size: 48,
                                weight: .medium
                            )
                        )

                        Text(
                            "Select a media source"
                        )
                        .font(
                            .system(
                                size: 20,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                    }
                    .foregroundStyle(
                        .black.opacity(0.45)
                    )
                }
            }
        }
        .frame(
            width: side,
            height: side
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
        .overlay {

            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
            .stroke(
                Color.white.opacity(0.85),
                lineWidth: 1
            )
        }
        .shadow(
            color: .black.opacity(0.23),
            radius: 30,
            x: 0,
            y: 16
        )
    }
}

// ================================================================
// MARK: - Metadata
// ================================================================

struct MetadataView: View {

    let title: String
    let artist: String
    let album: String

    var body: some View {

        VStack(
            spacing: 5
        ) {

            Text(
                title.isEmpty
                        ? "Select a media source"
                    : title
            )
            .font(
                .system(
                    size: 31,
                    weight: .bold,
                    design: .rounded
                )
            )
            .foregroundStyle(
                .black
            )
            .lineLimit(1)
            .truncationMode(.tail)

            HStack(
                spacing: 7
            ) {

                Text(
                    artist.isEmpty
                        ? "TVisualiser"
                        : artist
                )

                if !album.isEmpty {

                    Text("•")
                        .foregroundStyle(
                            .black.opacity(0.34)
                        )

                    Text(
                        album
                    )
                }
            }
            .font(
                .system(
                    size: 17,
                    weight: .medium,
                    design: .rounded
                )
            )
            .foregroundStyle(
                .black.opacity(0.58)
            )
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }
}

// ================================================================
// MARK: - Audio Visualizer
// ================================================================

struct AudioVisualizerView: View {

    let data: [Float]
    let color: Color
    let sensitivity: Double
    let lineWidth: Double

    var body: some View {
        GeometryReader { geometry in
            WaveformBars(data: data, sensitivity: sensitivity)
                .stroke(
                    color.opacity(0.88),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height
                )
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .clipped()
    }
}

private struct WaveformBars: Shape {
    let data: [Float]
    let sensitivity: Double

    func path(in rect: CGRect) -> Path {
        let values = data.isEmpty ? Array(repeating: Float(0.04), count: 2) : data
        let step = rect.width / CGFloat(max(1, values.count))
        let centerY = rect.midY
        let usableHeight = rect.height * 0.46
        var path = Path()

        for index in values.indices {
            let normalized = max(0.02, min(1, values[index] * Float(sensitivity)))
            let shaped = CGFloat(pow(normalized, 0.72))
            let barHeight = max(CGFloat(2), shaped * usableHeight)
            let x = rect.minX + step * (CGFloat(index) + 0.5)
            path.move(to: CGPoint(x: x, y: centerY - barHeight))
            path.addLine(to: CGPoint(x: x, y: centerY + barHeight))
        }
        return path
    }
}

// ================================================================
// MARK: - Media Control Card
// ================================================================

struct MediaControlCard: View {

    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool

    let onBackward: () -> Void
    let onPlayPause: () -> Void
    let onForward: () -> Void
    let focusNamespace: Namespace.ID

    private enum Control: Hashable {
        case backward
        case playPause
        case forward
    }

    @FocusState private var focusedControl: Control?

    var body: some View {

        VStack(
            spacing: 14
        ) {

            // ======================================================
            // CONTROL BUTTONS
            // ======================================================

            HStack(
                alignment: .center,
                spacing: 30
            ) {

                // --------------------------------------------------
                // BACK 10
                // --------------------------------------------------

                Button(
                    action: onBackward
                ) {

                    Image(
                        systemName:
                            "gobackward.10"
                    )
                    .font(
                        .system(
                            size: 24,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        .black
                    )
                    .frame(
                        width: 55,
                        height: 55
                    )
                }
                .buttonStyle(
                    TVButtonStyle()
                )
                .focused(
                    $focusedControl,
                    equals: .backward
                )

                // --------------------------------------------------
                // PLAY / PAUSE
                // --------------------------------------------------

                Button(
                    action: onPlayPause
                ) {

                    Image(
                        systemName:
                            isPlaying
                                ? "pause.fill"
                                : "play.fill"
                    )
                    .font(
                        .system(
                            size: 25,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(
                        .white
                    )
                    .frame(
                        width: 66,
                        height: 66
                    )
                    .background(
                        Color.black,
                        in: Circle()
                    )
                }
                .buttonStyle(
                    TVButtonStyle()
                )
                .focused(
                    $focusedControl,
                    equals: .playPause
                )
                .prefersDefaultFocus(
                    true,
                    in: focusNamespace
                )

                // --------------------------------------------------
                // FORWARD 10
                // --------------------------------------------------

                Button(
                    action: onForward
                ) {

                    Image(
                        systemName:
                            "goforward.10"
                    )
                    .font(
                        .system(
                            size: 24,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        .black
                    )
                    .frame(
                        width: 55,
                        height: 55
                    )
                }
                .buttonStyle(
                    TVButtonStyle()
                )
                .focused(
                    $focusedControl,
                    equals: .forward
                )
            }
            .focusSection()
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    moveFocusLeft()
                case .right:
                    moveFocusRight()
                default:
                    break
                }
            }

            // ======================================================
            // PROGRESS BAR
            // ======================================================

            HStack(
                spacing: 12
            ) {

                Text(
                    formatTime(
                        currentTime
                    )
                )
                .font(
                    .system(
                        size: 13,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .foregroundStyle(
                    .black.opacity(0.65)
                )
                .frame(
                    width: 42,
                    alignment: .leading
                )

                MediaProgressBar(
                    progress: progress
                )

                Text(
                    formatTime(
                        duration
                    )
                )
                .font(
                    .system(
                        size: 13,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .foregroundStyle(
                    .black.opacity(0.65)
                )
                .frame(
                    width: 42,
                    alignment: .trailing
                )
            }
        }
        .padding(
            .horizontal,
            30
        )
        .padding(
            .vertical,
            18
        )
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(
                cornerRadius: 26,
                style: .continuous
            )
        )
        .overlay {

            RoundedRectangle(
                cornerRadius: 26,
                style: .continuous
            )
            .stroke(
                Color.white.opacity(0.75),
                lineWidth: 1
            )
        }
        .shadow(
            color: .black.opacity(0.15),
            radius: 28,
            x: 0,
            y: 14
        )
        .onAppear {
            focusedControl = .playPause
        }
    }

    private var progress: CGFloat {

        guard duration > 0 else {
            return 0
        }

        return CGFloat(
            min(
                1,
                max(
                    0,
                    currentTime / duration
                )
            )
        )
    }

    private func formatTime(
        _ seconds: TimeInterval
    ) -> String {

        let total =
            Int(
                max(
                    0,
                    seconds.rounded()
                )
            )

        let minutes =
            total / 60

        let seconds =
            total % 60

        return String(
            format: "%d:%02d",
            minutes,
            seconds
        )
    }

    private func moveFocusLeft() {
        switch focusedControl {
        case .forward:
            focusedControl = .playPause
        case .playPause, nil:
            focusedControl = .backward
        case .backward:
            onBackward()
        }
    }

    private func moveFocusRight() {
        switch focusedControl {
        case .backward:
            focusedControl = .playPause
        case .playPause, nil:
            focusedControl = .forward
        case .forward:
            onForward()
        }
    }
}

// ================================================================
// MARK: - Progress Bar
// ================================================================

struct MediaProgressBar: View {

    let progress: CGFloat

    var body: some View {

        GeometryReader { geometry in

            let width =
                geometry.size.width

            let progressWidth =
                width * progress

            ZStack(
                alignment: .leading
            ) {

                Capsule()
                    .fill(
                        Color.black.opacity(0.16)
                    )
                    .frame(
                        height: 4
                    )

                Capsule()
                    .fill(
                        Color.black
                    )
                    .frame(
                        width: max(
                            0,
                            progressWidth
                        ),
                        height: 4
                    )

                Circle()
                    .fill(
                        Color.black
                    )
                    .frame(
                        width: 12,
                        height: 12
                    )
                    .offset(
                        x: max(
                            0,
                            min(
                                progressWidth - 6,
                                width - 12
                            )
                        )
                    )
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
        }
        .frame(
            height: 20
        )
    }
}

// ================================================================
// MARK: - Clock
// ================================================================

struct ClockView: View {

    let date: Date

    var body: some View {

        VStack(
            alignment: .trailing,
            spacing: 0
        ) {

            Text(
                date,
                format:
                    .dateTime
                    .hour()
                    .minute()
            )
            .font(
                .system(
                    size: 40,
                    weight: .bold,
                    design: .rounded
                )
            )
            .monospacedDigit()
            .foregroundStyle(
                .black
            )

            Text(
                date,
                format:
                    .dateTime
                    .weekday(
                        .abbreviated
                    )
            )
            .font(
                .system(
                    size: 21,
                    weight: .bold,
                    design: .rounded
                )
            )
            .foregroundStyle(
                .black.opacity(0.85)
            )
        }
    }
}

// ================================================================
// MARK: - Media Library
// ================================================================

struct MediaLibraryView: View {

    @EnvironmentObject private var ftp: FTPAccountStore
    @EnvironmentObject private var player: MediaPlayerStore
    @Environment(\.presentationMode) private var presentationMode

    @State private var tracks: [MediaTrack] = []
    @State private var isLoading = false
    @State private var errorMessage = ""

    var body: some View {

    NavigationView {
        List {
            Section("FTP") {
                if !ftp.isConfigured {
                    Text("Configure the local FTP server in Settings.")
                    Button("Open Settings") {
                        presentationMode.wrappedValue.dismiss()
                    }
                } else {
                    Button(isLoading ? "Loading files..." : "Refresh files") { refresh() }
                        .disabled(isLoading)

                    if tracks.isEmpty && !isLoading {
                        Text("No audio or video files available to this app.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(tracks) { track in
                        Button {
                            let source = FTPMediaSource(account: ftp)
                            player.load(track: track, from: source)
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            Label(track.title, systemImage: "play.circle")
                        }
                        .buttonStyle(TVButtonStyle())
                    }
                }
            }

            if !errorMessage.isEmpty {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Media Library")
        .task {
            if ftp.isConfigured {
                refresh()
            }
        }
    }
    .onExitCommand {
        presentationMode.wrappedValue.dismiss()
    }
}

    private func refresh() {
        isLoading = true
        errorMessage = ""
        Task {
            do {
                tracks = try await FTPMediaSource(account: ftp).tracks()
            } catch {
                tracks = []
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// ================================================================
// MARK: - Settings View
// ================================================================

struct SettingsView: View {

    @EnvironmentObject private var ftp: FTPAccountStore
    @EnvironmentObject private var player: MediaPlayerStore

    @Environment(
        \.presentationMode
    )
    var presentationMode

    @AppStorage("showClock")
    private var showClock: Bool = true

    @AppStorage("dynamicWaveformColor")
    private var dynamicWaveformColor: Bool = true

    @AppStorage("waveformLineWidth")
    private var waveformLineWidth: Double = 2.0

    @AppStorage("waveformSensitivity")
    private var waveformSensitivity: Double = 1.0

    var body: some View {

    NavigationView {
        Form {

            Section {
                Text("TVisualiser")
                    .font(.title2.bold())
                Text("Choose a source to begin playback.")
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Toggle("Show clock", isOn: $showClock)
            }

            Section("FTP") {
                TextField("Server address", text: $ftp.host)
                TextField("Port", value: $ftp.port, format: .number)
                TextField("Username", text: $ftp.username)
                SecureField("Password", text: $ftp.password)
                TextField("Media folder", text: $ftp.path)
                Button("Save FTP Settings") { ftp.save() }
                Text("Use the server IP only, without ftp://. The default port for the included server is 2121.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Waveform") {
                Toggle("Dynamic color from cover art", isOn: $dynamicWaveformColor)
                ValueStepper(label: "Line width", value: $waveformLineWidth, range: 1...6, step: 0.5)
                ValueStepper(label: "Sensitivity", value: $waveformSensitivity, range: 0.5...2.0, step: 0.1)
            }
        }
        .navigationTitle("Settings")
        .onDisappear {
            ftp.save()
        }
    }
    .onExitCommand {
        presentationMode.wrappedValue.dismiss()
    }
}
}

// ================================================================
// MARK: - Value Stepper
// ================================================================

struct ValueStepper: View {

    let label: String

    @Binding var value: Double

    let range: ClosedRange<Double>

    let step: Double

    var body: some View {

        HStack(spacing: 18) {
            Text(label)
            Spacer()

            Button(action: decrease) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(TVButtonStyle())
            .disabled(value <= range.lowerBound)

            Text(String(format: "%.1f", value))
                .font(.system(.body, design: .rounded).monospacedDigit())
                .frame(width: 54)

            Button(action: increase) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(TVButtonStyle())
            .disabled(value >= range.upperBound)
        }
        .padding(.vertical, 8)
    }

    private func decrease() {
        value =
            max(
                range.lowerBound,
                value - step
            )
    }

    private func increase() {
        value =
            min(
                range.upperBound,
                value + step
            )
    }
}

// ================================================================
// MARK: - Preview
// ================================================================

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(MediaPlayerStore())
            .environmentObject(FTPAccountStore())
    }
}

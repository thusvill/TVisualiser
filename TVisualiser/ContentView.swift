//
//  ContentView.swift
//  TVisualiser
//
//  Created by mac on 2026-09-04.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var receiver: ReceiverStore
    @State private var showingSettings = false

    @AppStorage("showClock") private var showClock: Bool = true
    @AppStorage("autoOpenOnAirPlay") private var autoOpenOnAirPlay: Bool = false
    @AppStorage("dynamicWaveformColor") private var dynamicWaveformColor: Bool = true
    @AppStorage("waveformLineWidth") private var waveformLineWidth: Double = 2.0
    @AppStorage("waveformSensitivity") private var waveformSensitivity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 500
            let artSide: CGFloat = min(geo.size.width - 120, isCompact ? 220 : 340)

            ZStack {
                // Layer 1: base background
                background
                    .ignoresSafeArea()

                // Layer 2: blurred cover art background
                backgroundArt
                    .ignoresSafeArea()

                // Layer 3: media controls — its own layer, above the
                // blurred background but below the main content layer
                mediaControls
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 240)

                // Layer 4: main foreground content
                VStack(spacing: 0) {
                    Spacer(minLength: 90)

                    albumArt(side: artSide)
                        .padding(.bottom, 30)

                     waveform
                         .frame(height: 60)

                    // Spacer(minLength: 30)

                    playerPanel
                        .frame(maxWidth: 650)

                    Spacer(minLength: 60)
                }
            }
            .overlay(alignment: .topLeading) {
                settingsHint
                    .padding(.top, 28)
                    .padding(.leading, 40)
            }
            .overlay(alignment: .topTrailing) {
                if showClock {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        clockView(date: context.date)
                    }
                    .padding(.top, 26)
                    .padding(.trailing, 40)
                }
            }
        }
        .preferredColorScheme(.light)
        .focusable(true)
        .onPlayPauseCommand {
            receiver.togglePlayback()
        }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                showingSettings = true
            case .left:
                receiver.skipBackward()
            case .right:
                receiver.skipForward()
            default:
                break
            }
        }
        .onChange(of: receiver.isReceiving) { nowReceiving in
            if nowReceiving && autoOpenOnAirPlay && showingSettings {
                showingSettings = false
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private var background: some View {
        Color(white: 0.94)
    }

    private var backgroundArt: some View {
        Group {
            if let artwork = receiver.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 60)
                    .saturation(0.1)
                    .opacity(0.34)
                    .clipped()
                    .overlay(Color.white.opacity(0.2))
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Settings hint (gear + "press up" label)

    private var settingsHint: some View {
        Button {
            showingSettings = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20, weight: .semibold))
                Text("Press up on the remote to open settings")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }

    private func clockView(date: Date) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
            Text(date, format: .dateTime.weekday(.abbreviated))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
        }
    }

    // MARK: - Album art

    private func albumArt(side: CGFloat) -> some View {
        Group {
            if let artwork = receiver.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.98)
                    Text("Cover Art")
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay(Rectangle().stroke(.black, lineWidth: 2))
    }

    // MARK: - Waveform (dynamic color, custom sensitivity/width)

    private var waveform: some View {
        Canvas { context, size in
            let count = receiver.waveform.count
            guard count > 1 else { return }
            var path = Path()
            for index in 0..<count {
                let x = CGFloat(index) / CGFloat(max(1, count - 1)) * size.width
                let rawLevel = CGFloat(max(0.03, receiver.waveform[index]))
                let level = min(1.0, rawLevel * CGFloat(waveformSensitivity))
                let y = size.height / 2 + (index.isMultiple(of: 2) ? -1 : 1) * level * size.height * 0.72
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let color = dynamicWaveformColor ? receiver.waveformColor : .black
            context.stroke(path, with: .color(color), lineWidth: waveformLineWidth)
        }
    }

    // MARK: - Media controls (own z-layer, non-interactive glyphs —
    // real control flows through onPlayPauseCommand / onMoveCommand)

    private var mediaControls: some View {
        HStack(spacing: 18) {
            Image(systemName: "gobackward.10")
                .font(.system(size: 26, weight: .bold))
                .frame(width: 42, height: 42)
                .foregroundStyle(.black)

            Image(systemName: receiver.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 28, weight: .bold))
                .frame(width: 56, height: 56)
                .foregroundStyle(.white)
                .background(Color.black, in: Circle())

            Image(systemName: "goforward.10")
                .font(.system(size: 26, weight: .bold))
                .frame(width: 42, height: 42)
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.black.opacity(0.25), lineWidth: 1.5))
    }

    // MARK: - Player panel

    private var playerPanel: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(receiver.trackTitle)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(receiver.artist)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.black.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 10) {
                Text(formatTime(receiver.currentTime))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.7))

                lineProgress
                    .frame(maxWidth: .infinity)

                Text(formatTime(receiver.duration))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.7))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .overlay(Rectangle().stroke(.black, lineWidth: 1.5))
    }

    private var lineProgress: some View {
        GeometryReader { proxy in
            let total = max(receiver.duration, 1)
            let fraction = CGFloat(min(receiver.currentTime, receiver.duration) / total)
            let width = max(proxy.size.width, 1)
            let dotX = width * fraction

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.black.opacity(0.45))
                    .frame(height: 2)

                Rectangle()
                    .fill(.black)
                    .frame(width: max(0, width * fraction), height: 2)

                Circle()
                    .fill(.black)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, min(dotX - 5, width - 10)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 16)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(0, seconds.rounded()))
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct SettingsView: View {
    @AppStorage("showClock") private var showClock: Bool = true
    @AppStorage("autoOpenOnAirPlay") private var autoOpenOnAirPlay: Bool = false
    @AppStorage("dynamicWaveformColor") private var dynamicWaveformColor: Bool = true
    @AppStorage("waveformLineWidth") private var waveformLineWidth: Double = 2.0
    @AppStorage("waveformSensitivity") private var waveformSensitivity: Double = 1.0

    var body: some View {
        Form {
            Section {
                Text("TVisualiser")
                    .font(.title2.bold())
                Text("AirPlay receiver is active on port 5000.")
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Toggle("Show clock", isOn: $showClock)
            }

            Section("AirPlay") {
                Toggle("Auto-show Now Playing on connect", isOn: $autoOpenOnAirPlay)
                Text("If Settings is open when a stream begins, it will close automatically. tvOS apps can't launch themselves from the background, so the app must already be running.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Waveform") {
                Toggle("Dynamic color from cover art", isOn: $dynamicWaveformColor)

                valueStepper(
                    label: "Line width",
                    value: $waveformLineWidth,
                    range: 1...6,
                    step: 0.5
                )

                valueStepper(
                    label: "Sensitivity",
                    value: $waveformSensitivity,
                    range: 0.5...2.0,
                    step: 0.1
                )
            }

            Section("Remote controls") {
                Text("Play/Pause button — toggle playback")
                Text("Swipe left / right — skip ±10s")
                Text("Swipe up — open Settings")
            }
        }
    }

    private func valueStepper(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack {
            Text("\(label): \(String(format: "%.1f", value.wrappedValue))")
            Spacer()
            HStack(spacing: 20) {
                Button {
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                } label: {
                    Image(systemName: "minus.circle")
                }

                Button {
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ReceiverStore())
}

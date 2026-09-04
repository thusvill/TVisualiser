//
//  ContentView.swift
//  TVisualiser
//
//  Created by mac on 2026-09-04.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var receiver: ReceiverStore

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.045, blue: 0.055)
                .ignoresSafeArea()

            if let artwork = receiver.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.28)
                    .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer()
                visualizer
                Spacer()
                footer
            }
            .padding(.horizontal, 92)
            .padding(.vertical, 64)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("T/VISUALISER")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .tracking(4)
                .foregroundStyle(.white)
            Spacer()
            HStack(spacing: 12) {
                Circle()
                    .fill(receiver.isReceiving ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 12, height: 12)
                Text(receiver.isReceiving ? "AIRPLAY LIVE" : "READY TO RECEIVE")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private var visualizer: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let count = receiver.waveform.count
                let spacing = size.width / CGFloat(count)
                for index in 0..<count {
                    let level = CGFloat(max(0.04, receiver.waveform[index]))
                    let barHeight = level * size.height * 0.9
                    let rect = CGRect(
                        x: CGFloat(index) * spacing,
                        y: (size.height - barHeight) / 2,
                        width: max(3, spacing * 0.56),
                        height: barHeight
                    )
                    let color = index < count / 2 ? Color(red: 0.98, green: 0.38, blue: 0.25) : Color(red: 0.70, green: 0.92, blue: 0.30)
                    context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.85)))
                }
            }
        }
        .frame(height: 270)
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(receiver.trackTitle)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text([receiver.artist, receiver.album].filter { !$0.isEmpty }.joined(separator: "  /  "))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer()
            Text("\(Int(receiver.audioLevel * 100))%")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.70, green: 0.92, blue: 0.30))
        }
    }
}

#Preview {
    ContentView()
}

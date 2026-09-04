# TVisualiser Project Log

Last updated: 2026-09-04

## Objective

Build a standalone tvOS audio visualizer that advertises as an AirPlay 1 / RAOP receiver, receives audio over the local network, decodes and plays it through `AVAudioEngine`, extracts metadata and cover art, and renders an audio-driven waveform with artwork ambience.

## Current Project

- Xcode project: `TVisualiser.xcodeproj`
- App source directory: `TVisualiser/`
- Target: `TVisualiser`
- Device family: tvOS
- Current Xcode project deployment setting is tvOS 26.1. Verify before changing; the original brief requested tvOS 15.1.1+.
- No external Swift packages are currently configured.

## Implemented

### App wiring

- `TVisualiserApp.swift` creates a `ReceiverStore` as a `StateObject`.
- The app starts `AirPlayAdvertiser` and `ReceiverStore` on launch.
- `ReceiverStore` is injected into `ContentView` through the SwiftUI environment.

### Visualizer UI

- `ContentView.swift` now contains a full-screen album-focused tvOS visualizer based on the supplied reference image.
- Displays a live clock/date header, centered artwork, blurred artwork ambience, a thin line waveform, and a bordered now-playing panel.
- Shows a deterministic fallback cover while no artwork metadata has arrived.
- Keeps live AirPlay/ready status in the player panel.

### Receiver state

- `ReceiverStore.swift` owns observable connection, metadata, level, waveform, and artwork state.
- RTSP announce text is scanned for `a=title`, `a=artist`, and `a=album` fields.
- Incoming UDP packets update the waveform and level state.
- Receiver status decays back to idle after one second without packets.
- `AudioPlaybackEngine` provides an `AVAudioEngine` plus `AVAudioPlayerNode` foundation for decoded PCM buffers.

### Network lifecycle

- `RTSPServer.swift` has a `stop()` method that cancels listeners and active connections.
- Existing TCP RTSP and UDP listener implementation remains in place.
- `AirPlayAdvertiser.swift` publishes the audio-only `_raop._tcp.` service. The unsupported `_airplay._tcp.` companion service is not advertised.
- The target's generated Info.plist declares `_raop._tcp` and a local-network usage description.
- The RAOP TXT record includes standard codec and encryption capability flags expected by AirPlay audio senders.
- `DebugSettings.swift` provides one global switch, `DebugSettings.enabled = true`; set it to `false` to silence TVisualiser diagnostics.
- Debug output now covers Bonjour publish failures, listener states, TCP connections, RTSP requests/responses, receive/send errors, RTP packet sizes, ANNOUNCE events, and analyzer payload sizes.
- `SET_PARAMETER` now forwards its binary body and parses DAAP tags: `minm` updates title, `asar` updates artist, and `asal` updates album.
- `ReceiverStore` now interprets the bridge's UDP stream as raw 44.1 kHz stereo signed 16-bit PCM, schedules it through `AVAudioEngine`, and derives the waveform from decoded samples.
- `covr` DMAP artwork is decoded into the UI image; the player surface uses rounded artwork/material styling and includes a settings sheet.
- `airplay_bridge.py` now behaves as a classic RAOP sender: it sends a non-empty SDP `ANNOUNCE`, reads complete RTSP responses, uses the negotiated `server_port`, and transmits RTP payload type 96 L16 audio with sequence numbers and timestamps.
- `RTSPServer` now buffers fragmented/coalesced RTSP messages and honors `Content-Length`, allowing binary metadata bodies and SDP bodies to reach their callbacks safely.

## Validation

The following command succeeds from the app source directory:

```sh
xcodebuild -project ../TVisualiser.xcodeproj -scheme TVisualiser -sdk appletvsimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Pylance/Swift diagnostics checked on the touched Swift files: no errors reported.

The target still builds successfully after the local-network and advertisement changes.

The Python `test.py` handshake was verified from the attached output through `OPTIONS`, `ANNOUNCE`, `SETUP`, `SET_PARAMETER`, and `RECORD`. Its DMAP metadata should now update the UI to `Blinding Lights`, `The Weeknd`, and `After Hours`. That script sends no RTP audio packets, so it cannot animate the waveform or produce playback; add UDP RTP fixture packets separately for that test.

`airplay_bridge.py` does send raw PCM over UDP port 6000. The Swift receiver now consumes that exact format for playback. The bridge's FFmpeg input (`avfoundation`, device `:0`) must provide the intended audio source; on macOS this is commonly a microphone/input device, not system Music audio, unless a loopback device is configured.

## Known Gaps

This is not yet a complete interoperable AirPlay 1 receiver. Real AirPlay senders generally require:

1. RTSP request framing across partial TCP reads, rather than treating each read as one request.
2. Proper RAOP `ANNOUNCE`, `SETUP`, `RECORD`, `FLUSH`, `TEARDOWN`, and `SET_PARAMETER` state handling.
3. RSA/FairPlay session negotiation where encryption is enabled.
4. SDP parsing and AES/ALAC stream configuration.
5. RTP header parsing, sequence/timestamp handling, decryption, and ALAC decoding.
6. Conversion of decoded PCM into `AVAudioPCMBuffer` objects scheduled on `AudioPlaybackEngine`.
7. DMAP / `SET_PARAMETER` metadata parsing for title, artist, album, and artwork.
8. A real cover-art decode path into `UIImage`.
9. Local-network usage permission and App Store entitlement review.
10. Device testing with an Apple TV and real AirPlay sources; simulator networking does not prove RAOP compatibility.

If an AirPlay entry remains grey after granting local-network access, capture the sender's RTSP requests. A grey entry can also mean the sender rejected the receiver during `OPTIONS`/`ANNOUNCE`/`SETUP`; discovery alone only proves Bonjour publication.

The attached diagnostic output shows an `appletvsimulator` run. The simulator can validate Swift compilation and local listener startup, but it is not a valid end-to-end AirPlay receiver test. Use a signed build on physical Apple TV hardware, with the sender and Apple TV on the same LAN, before interpreting a missing RTSP connection as a protocol result.

With debugging enabled, the expected connection sequence is an accepted TCP connection followed by `OPTIONS`, `ANNOUNCE`, `SETUP`, and `RECORD`. If no accepted connection appears, investigate Bonjour/network permissions or stale service records. If the sequence stops at a request, implement the corresponding RAOP response/state handling before changing the UI.

The current UDP waveform path treats packet bytes as an analyzer fallback. It must not be described as decoded audio playback until the RTP/ALAC pipeline is implemented.

The Python sender now exercises the unencrypted classic RAOP/L16 path. iPhone Music/AirPlay commonly selects encrypted ALAC and requires the RSA/FairPlay session path, which is still not implemented in this app.

## Recommended Next Plan

1. Refactor `RTSPServer` into a connection/session state machine with buffered RTSP framing.
2. Parse the `ANNOUNCE` SDP into a typed `RAOPSession` configuration.
3. Implement the unauthenticated/non-encrypted RTP path first, with packet validation and test fixtures.
4. Add ALAC decoding using a compatible, App Store-acceptable implementation and feed PCM buffers to `AudioPlaybackEngine`.
5. Add `SET_PARAMETER` parsing for text metadata and binary artwork.
6. Add unit tests for RTSP framing, SDP parsing, RTP sequence handling, and metadata parsing.
7. Add real-device network permission configuration and test with iPhone/Mac AirPlay sources.
8. Revisit the deployment target only after checking the APIs and decoder strategy against tvOS 15.1.1.

## Resume Notes For Another LLM

- Start by reading this file, then inspect `Network/RTSPServer.swift` and `ReceiverStore.swift`.
- Preserve unrelated worktree changes. Current status when this log was created: `ContentView.swift`, `TVisualiserApp.swift`, `Network/AirPlayAdvertiser.swift`, and `Network/RTSPServer.swift` were modified; `ReceiverStore.swift` was untracked.
- Do not claim full AirPlay support until encryption/session negotiation and ALAC decoding are implemented and tested on hardware.
- Do not commit changes unless explicitly requested.

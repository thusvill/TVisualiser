# Telegram Implementation Progress

Updated: 2026-09-04

## Current state

- AirPlay code has been removed.
- The app targets tvOS 15.1.1 at the target level.
- `TelegramAccountStore` owns account state and stores authenticated sessions in Keychain.
- Telegram app credentials are centralized in `TVisualiser/TelegramAccountStore.swift` in `TelegramAppConfiguration`.
- `TelegramMediaSource` conforms to `MediaSource`, but `tracks()` currently reports that MTProto is unavailable.
- The settings screen no longer exposes `api_id` or `api_hash`; it only exposes the phone number and session status.

## Important blocker

Telegram user-account login requires MTProto. The Bot API cannot log in a user account. The Swift MTProto package checked during this work declares tvOS 18 as its minimum platform, so it cannot be added while preserving tvOS 15.1.1.

Do not implement a fake REST login or claim that a phone number alone authenticates Telegram. The app must use a real MTProto implementation for phone/code login, QR login, 2FA, chat listing, media download, and session restoration.

## Next implementation steps

1. Select or build an MTProto transport whose compiled deployment target includes tvOS 15.1.1. Prefer an official TDLib build or a maintained library with an actual tvOS 15 binary/module.
2. Add `TelegramAuthCoordinator` behind a protocol so UI does not depend on the selected library.
3. Implement states: signed out, waiting for phone, waiting for code, waiting for 2FA password, QR ready, signing in, signed in, and failure.
4. Persist only the authenticated session/auth key in Keychain. Never persist the Telegram login code or 2FA password.
5. Extend `TelegramMediaSource` to list chats and audio/video documents, download selected media into a cache, and return `MediaTrack` values.
6. Add a source browser to the existing tvOS focus hierarchy and connect selected tracks to `MediaPlayerStore`.
7. Test on a real tvOS 15.1.1 device; simulator-only testing cannot validate Telegram networking and Keychain behavior fully.

## Validation already run

- Swift diagnostics passed for the Telegram files.
- tvOS simulator build succeeded before this handoff was written.

## Google Drive implementation

- `GoogleDriveAccountStore.swift` implements Google device authorization, Keychain token storage, token refresh, sign out, and UI-facing authorization state.
- `GoogleDriveMediaSource.swift` lists audio/video files through Drive REST and downloads selected files into the app cache.
- `MediaPlayerStore.swift` loads cached local media with `AVAudioPlayer`.
- Settings exposes Google sign-in, the device code/link, file refresh, file selection, and sign out.
- The main screen now exposes a `Media` button that opens `MediaLibraryView`.
- `MediaPlayerStore` uses `AVAudioPlayer` for downloaded local files; skip controls now seek the actual player position.
- Apple TV Play/Pause still routes through `.onPlayPauseCommand` and the player button.
- Before running sign-in, replace `REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID` in `GoogleDriveConfiguration` with a Google OAuth client ID created for TV/limited-input devices.
- The device OAuth scope is `drive.file` because Google does not allow `drive.readonly` for TV/device clients. This limits listing to files created by or explicitly opened with this app; use a web/native OAuth flow for unrestricted Drive read access.
- Configure the OAuth consent screen and add the Google account as a test user while the project is in testing mode.

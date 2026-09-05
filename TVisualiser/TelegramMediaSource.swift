import Foundation

final class TelegramMediaSource: MediaSource {
    let id = "telegram"
    let displayName = "Telegram"

    private let account: TelegramAccountStore

    init(account: TelegramAccountStore) {
        self.account = account
    }

    func tracks() async throws -> [MediaTrack] {
        guard case .signedIn = account.state else {
            throw MediaSourceError.unavailable("Sign in to Telegram before browsing media.")
        }

        throw MediaSourceError.unavailable("Telegram MTProto transport is not configured for tvOS 15.1.1.")
    }
}

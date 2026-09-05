import Foundation
import Combine
import Security

enum TelegramAppConfiguration {
    static let apiID = "22213192"
    static let apiHash = "caa8fcb998df726dde22264c57196dd2"
}

@MainActor
final class TelegramAccountStore: ObservableObject {
    enum State: Equatable {
        case signedOut
        case ready
        case signedIn(String)
        case failed(String)
    }

    @Published private(set) var state: State
    @Published var phoneNumber = ""

    private let keychain: TelegramKeychain

    init(keychain: TelegramKeychain) {
        self.keychain = keychain
        if let account = keychain.loadAccount() {
            state = .signedIn(account.displayName)
            phoneNumber = account.phoneNumber
        } else {
            state = .signedOut
        }
    }

    convenience init() {
        self.init(keychain: TelegramKeychain())
    }

    func saveAuthenticatedSession(_ session: TelegramSession) {
        do {
            try keychain.save(session)
            state = .signedIn(session.displayName)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        keychain.delete()
        state = .signedOut
        phoneNumber = ""
    }
}

struct TelegramSession: Codable, Sendable {
    let phoneNumber: String
    let displayName: String
    let authorizationData: Data
}

struct TelegramKeychain {
    private let service = "thusvill.TVisualiser.telegram"
    private let account = "user-session"

    func save(_ session: TelegramSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw TelegramAccountError.keychain(status) }
    }

    func loadAccount() -> TelegramSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TelegramSession.self, from: data)
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum TelegramAccountError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Unable to save Telegram session (Keychain status \(status))."
        }
    }
}

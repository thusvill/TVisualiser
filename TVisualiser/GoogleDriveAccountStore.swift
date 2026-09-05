import Combine
import Foundation
import Security

enum GoogleDriveConfiguration {
    static let placeholderClientID = "REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID"

    // Create an OAuth client for TV and limited-input devices in Google Cloud,
    // then place its client ID here. Client IDs are not passwords.
    static let clientID = ""
    static let clientSecret = ""
    // Google TV/device OAuth supports drive.file, not drive.readonly.
    static let scope = "https://www.googleapis.com/auth/drive.file"
}

@MainActor
final class GoogleDriveAccountStore: ObservableObject {
    enum State: Equatable {
        case signedOut
        case waitingForApproval
        case signedIn
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut
    @Published private(set) var userCode = ""
    @Published private(set) var verificationURL: URL?
    @Published var tracks: [MediaTrack] = []

    private let tokenStore: GoogleDriveTokenStore
    private let session: URLSession
    private var pollingTask: Task<Void, Never>?

    init(
        tokenStore: GoogleDriveTokenStore = GoogleDriveTokenStore(),
        session: URLSession = .shared
    ) {
        self.tokenStore = tokenStore
        self.session = session
        if tokenStore.hasToken {
            state = .signedIn
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    func signIn() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await beginDeviceAuthorization()
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func signOut() {
        pollingTask?.cancel()
        tokenStore.delete()
        state = .signedOut
        userCode = ""
        verificationURL = nil
        tracks = []
    }

    func accessToken() async throws -> String {
        try await tokenStore.validAccessToken(session: session)
    }

    private func beginDeviceAuthorization() async throws {
        guard GoogleDriveConfiguration.clientID != GoogleDriveConfiguration.placeholderClientID else {
            throw GoogleDriveError.configurationMissing
        }
        guard GoogleDriveConfiguration.clientSecret != "REPLACE_WITH_GOOGLE_OAUTH_CLIENT_SECRET" else {
            throw GoogleDriveError.clientSecretMissing
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            "client_id": GoogleDriveConfiguration.clientID,
            "scope": GoogleDriveConfiguration.scope
        ])

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let authorization = try JSONDecoder().decode(GoogleDeviceAuthorization.self, from: data)

        userCode = authorization.userCode
        verificationURL = URL(string: authorization.verificationURL)
        state = .waitingForApproval

        let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))
        while Date() < deadline && !Task.isCancelled {
            try await Task.sleep(nanoseconds: UInt64(authorization.interval) * 1_000_000_000)
            if try await pollToken(deviceCode: authorization.deviceCode) {
                state = .signedIn
                return
            }
        }

        throw GoogleDriveError.authorizationExpired
    }

    private func pollToken(deviceCode: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            "client_id": GoogleDriveConfiguration.clientID,
            "client_secret": GoogleDriveConfiguration.clientSecret,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleDriveError.invalidResponse }
        if http.statusCode == 428 || http.statusCode == 400 {
            let error = try? JSONDecoder().decode(GoogleOAuthError.self, from: data)
            if error?.code == "authorization_pending" || error?.code == "slow_down" { return false }
        }
        try validate(response, data: data)
        let token = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        try tokenStore.save(token)
        return true
    }

    private func formData(_ values: [String: String]) -> Data {
        values.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(GoogleOAuthErrorResponse.self, from: data) {
                throw GoogleDriveError.requestFailed(error.errorDescription ?? "Google authorization failed.")
            }
            let message = String(data: data, encoding: .utf8) ?? "Google Drive request failed."
            throw GoogleDriveError.requestFailed(message)
        }
    }
}

private struct GoogleDeviceAuthorization: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct GoogleOAuthError: Decodable {
    let code: String

    enum CodingKeys: String, CodingKey {
        case code = "error"
    }
}

private struct GoogleOAuthErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

struct GoogleTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let savedAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresIn = try container.decode(Int.self, forKey: .expiresIn)
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
    }

    init(accessToken: String, refreshToken: String?, expiresIn: Int, savedAt: Date = Date()) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.savedAt = savedAt
    }

    var isExpired: Bool {
        Date() >= savedAt.addingTimeInterval(TimeInterval(max(0, expiresIn - 60)))
    }
}

struct GoogleDriveTokenStore {
    private let service = "thusvill.TVisualiser.google-drive"
    private let account = "oauth-token"

    var hasToken: Bool { load() != nil }

    func save(_ token: GoogleTokenResponse) throws {
        let data = try JSONEncoder().encode(token)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw GoogleDriveError.keychain
        }
    }

    func validAccessToken(session: URLSession) async throws -> String {
        guard let token = load() else { throw GoogleDriveError.notSignedIn }
        guard token.isExpired else { return token.accessToken }
        guard let refreshToken = token.refreshToken else { throw GoogleDriveError.notSignedIn }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id=\(GoogleDriveConfiguration.clientID)",
            "client_secret=\(GoogleDriveConfiguration.clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleDriveError.notSignedIn
        }
        let refreshed = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        let updated = GoogleTokenResponse(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? refreshToken,
            expiresIn: refreshed.expiresIn
        )
        try save(updated)
        return updated.accessToken
    }

    func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    private func load() -> GoogleTokenResponse? {
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
        return try? JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }
}

enum GoogleDriveError: LocalizedError {
    case configurationMissing
    case clientSecretMissing
    case authorizationExpired
    case invalidResponse
    case requestFailed(String)
    case notSignedIn
    case keychain

    var errorDescription: String? {
        switch self {
        case .configurationMissing: return "Add a Google OAuth client ID to GoogleDriveConfiguration."
        case .clientSecretMissing: return "Add the Google OAuth client secret to GoogleDriveConfiguration."
        case .authorizationExpired: return "Google authorization expired before approval."
        case .invalidResponse: return "Google returned an invalid response."
        case .requestFailed(let message): return message
        case .notSignedIn: return "Sign in to Google Drive first."
        case .keychain: return "Unable to save Google Drive credentials."
        }
    }
}
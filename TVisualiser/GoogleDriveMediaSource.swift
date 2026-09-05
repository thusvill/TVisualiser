import Foundation

final class GoogleDriveMediaSource: MediaSource {
    let id = "google-drive"
    let displayName = "Google Drive"

    private let account: GoogleDriveAccountStore
    private let session: URLSession

    init(account: GoogleDriveAccountStore, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    func tracks() async throws -> [MediaTrack] {
        let token = try await account.accessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "trashed = false and mimeType != 'application/vnd.google-apps.folder'"),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,size,modifiedTime)"),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleDriveError.requestFailed(String(data: data, encoding: .utf8) ?? "Drive listing failed.")
        }
        let listing = try JSONDecoder().decode(GoogleDriveFileList.self, from: data)
        return listing.files.compactMap { file in
            guard Self.isPlayable(file.mimeType) else { return nil }
            return MediaTrack(
                id: file.id,
                title: file.name,
                artist: "Google Drive",
                album: "",
                artworkData: nil,
                mediaURL: URL(string: "https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media")!,
                duration: nil
            )
        }
    }

    func prepare(_ track: MediaTrack) async throws -> MediaTrack {
        let token = try await account.accessToken()
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("google-drive-\(track.id)")
        if !FileManager.default.fileExists(atPath: cacheURL.path) {
            var request = URLRequest(url: track.mediaURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw GoogleDriveError.requestFailed("Unable to download \(track.title).")
            }
            try data.write(to: cacheURL, options: .atomic)
        }
        return MediaTrack(id: track.id, title: track.title, artist: track.artist, album: track.album, artworkData: track.artworkData, mediaURL: cacheURL, duration: track.duration)
    }

    private static func isPlayable(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/")
    }
}

private struct GoogleDriveFileList: Decodable {
    let files: [GoogleDriveFile]
}

private struct GoogleDriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
}
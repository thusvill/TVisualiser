import Foundation
import UniformTypeIdentifiers

final class FTPMediaSource: MediaSource {
    let id = "ftp"
    let displayName = "FTP"

    private let account: FTPAccountStore
    private let session: URLSession

    init(account: FTPAccountStore, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    func tracks() async throws -> [MediaTrack] {
        let listing = try await request(path: normalizedPath, isListing: true)
        return listing
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ", omittingEmptySubsequences: true).last
                    .map(String.init) ?? ""
                guard !name.isEmpty, !name.hasSuffix("/"),
                      Self.isPlayable(name: name),
                      let mediaURL = try? url(for: path(for: name)) else { return nil }
                return MediaTrack(
                    id: path(for: name),
                    title: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
                    artist: "FTP",
                    album: "",
                    artworkData: nil,
                    mediaURL: mediaURL,
                    duration: nil
                )
            }
    }

    func prepare(_ track: MediaTrack) async throws -> MediaTrack {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ftp-\(Data(track.id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_"))")
            .appendingPathExtension(track.mediaURL.pathExtension)
        if !FileManager.default.fileExists(atPath: cacheURL.path) {
            let (data, _) = try await session.data(from: track.mediaURL)
            try data.write(to: cacheURL, options: .atomic)
        }
        return MediaTrack(id: track.id, title: track.title, artist: track.artist,
                          album: track.album, artworkData: track.artworkData,
                          mediaURL: cacheURL, duration: track.duration)
    }

    private var normalizedPath: String {
        let value = account.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "/" : (value.hasPrefix("/") ? value : "/" + value)
    }

    private func path(for name: String) -> String {
        normalizedPath == "/" ? "/\(name)" : "\(normalizedPath)/\(name)"
    }

    private func url(for path: String) throws -> URL {
        let rawHost = account.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ftp://", with: "")
            .replacingOccurrences(of: "ftps://", with: "")
        guard !rawHost.isEmpty, !rawHost.contains("/") else {
            throw MediaSourceError.unavailable("Enter the FTP server address without ftp://, for example 192.168.1.20.")
        }
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = rawHost
        components.port = account.port
        components.user = account.username.isEmpty ? nil : account.username
        components.password = account.password.isEmpty ? nil : account.password
        components.path = path
        guard let result = components.url else {
            throw MediaSourceError.unavailable("The FTP server address is invalid.")
        }
        return result
    }

    private func request(path: String, isListing: Bool) async throws -> String {
        let requestURL = try url(for: path)
        var request = URLRequest(url: requestURL)
        request.httpMethod = isListing ? "LIST" : "GET"
        let (data, _) = try await session.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    private static func isPlayable(name: String) -> Bool {
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }
}

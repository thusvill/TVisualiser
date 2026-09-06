import Foundation
import UniformTypeIdentifiers
import FilesProvider

final class FTPMediaSource: MediaSource {
    let id = "ftp"
    let displayName = "FTP"

    private let account: FTPAccountStore
    private let provider: FTPFileProvider

    // Reused across prepare()/prefetch() calls so we don't pay a fresh
    // USER/PASS/TYPE round trip for every track.
    private let connection: FTPControlConnection

    init(account: FTPAccountStore) throws {
        self.account = account

        var rawHost = account.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ftp://", with: "")
            .replacingOccurrences(of: "ftps://", with: "")

        var port = account.port

        if let portRange = rawHost.range(of: ":") {
            let hostPart = String(rawHost[..<portRange.lowerBound])
            let portString = String(rawHost[portRange.upperBound...])
            rawHost = hostPart
            if let parsedPort = Int(portString) {
                port = parsedPort
            }
        }

        guard !rawHost.isEmpty else {
            throw NSError(domain: "FTPMediaSource", code: 1, userInfo: [NSLocalizedDescriptionKey: "Host address is empty."])
        }

        var components = URLComponents()
        components.scheme = "ftp"
        components.host = rawHost
        components.port = port

        guard let baseURL = components.url else {
            throw NSError(domain: "FTPMediaSource", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid FTP URL components."])
        }

        let credential: URLCredential? = account.username.isEmpty ? nil : URLCredential(
            user: account.username,
            password: account.password,
            persistence: .forSession
        )

        guard let ftpProvider = FTPFileProvider(baseURL: baseURL, credential: credential) else {
            throw NSError(domain: "FTPMediaSource", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize FTP provider."])
        }

        self.provider = ftpProvider
        self.connection = FTPControlConnection(
            host: rawHost, port: port,
            username: account.username, password: account.password
        )
        print("FTP Source Initialized: \(baseURL)")
    }

    func tracks() async throws -> [MediaTrack] {
        let pathToFetch = normalizedPath.isEmpty ? "." : normalizedPath
        print("FTP: Fetching from path: '\(pathToFetch)'")

        return try await withCheckedThrowingContinuation { continuation in
            provider.contentsOfDirectory(path: pathToFetch) { [weak self] files, error in
                guard let self = self else { return }

                if let error = error {
                    print("FTP Error fetching tracks: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }

                let mediaTracks = files.compactMap { file -> MediaTrack? in
                    let name = file.name
                    guard !file.isDirectory, Self.isPlayable(name: name) else { return nil }
                    let trackPath = self.path(for: name, relativeTo: pathToFetch)
                    return MediaTrack(
                        id: trackPath,
                        title: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
                        artist: "FTP",
                        album: "",
                        artworkData: nil,
                        mediaURL: URL(string: "ftp://\(self.account.host)/\(trackPath)")!,
                        duration: nil
                    )
                }

                continuation.resume(returning: mediaTracks)
            }
        }
    }

    /// Downloads the full file to local cache (skips if already cached) and
    /// returns a MediaTrack pointing at that local file, ready for
    /// AVAudioFile(forReading:). This blocks until the whole file is on disk —
    /// AVAudioFile needs a complete, accurately-sized file to work correctly
    /// with this app's frame-accurate scheduling/seek logic.
    func prepare(_ track: MediaTrack) async throws -> MediaTrack {
        let cacheURL = try await ensureCached(track: track)
        return MediaTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            artworkData: track.artworkData,
            mediaURL: cacheURL,
            duration: track.duration
        )
    }

    /// Fire-and-forget download of a track into the local cache, so that a
    /// later `prepare()` call for it (e.g. the next track in a playlist)
    /// resolves instantly instead of waiting on the network. Safe to call
    /// speculatively; errors are logged, not thrown, since nothing is
    /// blocking on this.
    func prefetch(_ track: MediaTrack) {
        Task {
            do {
                _ = try await ensureCached(track: track)
                print("FTP: Prefetched \(track.id)")
            } catch {
                print("FTP: Prefetch failed for \(track.id): \(error)")
            }
        }
    }

    // MARK: - Shared download/cache logic

    private func cacheURL(for track: MediaTrack) -> URL {
        let safeId = track.id.replacingOccurrences(of: "/", with: "_")
        let cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FtpMediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        return cacheFolder.appendingPathComponent(safeId)
    }

    /// Downloads `track` to disk if not already fully cached, verifying the
    /// cached size matches the remote size (guards against a previous
    /// partial/interrupted download being reused).
    @discardableResult
    private func ensureCached(track: MediaTrack) async throws -> URL {
        let destination = cacheURL(for: track)

        if FileManager.default.fileExists(atPath: destination.path) {
            let remoteSize = try? connection.fileSize(path: track.id)
            let localSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
            if let remoteSize, let localSize, remoteSize == localSize, remoteSize > 0 {
                return destination // already fully cached
            }
            // Stale/partial file — remove and re-download.
            try? FileManager.default.removeItem(at: destination)
        }

        let tempURL = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tempURL)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: tempURL)
        var downloadError: Error?

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task {
                    do {
                        try self.connection.retrieveRange(path: track.id, offset: 0, length: nil) { chunk in
                            handle.write(chunk)
                        }
                        continuation.resume(returning: ())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            downloadError = error
        }

        try? handle.close()

        if let downloadError {
            try? FileManager.default.removeItem(at: tempURL)
            print("FTP Download Error for \(track.id): \(downloadError.localizedDescription)")
            throw downloadError
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private var normalizedPath: String {
        return account.path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func path(for name: String, relativeTo base: String) -> String {
        if base == "." {
            return name
        }
        let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return "\(cleanBase)/\(name)"
    }

    private static func isPlayable(name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension
        guard !ext.isEmpty else { return false }
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }
}

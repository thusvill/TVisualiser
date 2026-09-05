import Foundation
import UIKit

struct MediaTrack: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkData: Data?
    let mediaURL: URL
    let duration: TimeInterval?
}

protocol MediaSource: AnyObject {
    var id: String { get }
    var displayName: String { get }
    func tracks() async throws -> [MediaTrack]
    func prepare(_ track: MediaTrack) async throws -> MediaTrack
}

extension MediaSource {
    func prepare(_ track: MediaTrack) async throws -> MediaTrack {
        track
    }
}

enum MediaSourceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

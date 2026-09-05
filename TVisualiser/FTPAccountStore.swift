import Combine
import Foundation

@MainActor
final class FTPAccountStore: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "ftp.host") ?? ""
    @Published var port = UserDefaults.standard.integer(forKey: "ftp.port") == 0
        ? 21 : UserDefaults.standard.integer(forKey: "ftp.port")
    @Published var username = UserDefaults.standard.string(forKey: "ftp.username") ?? "anonymous"
    @Published var password = UserDefaults.standard.string(forKey: "ftp.password") ?? ""
    @Published var path = UserDefaults.standard.string(forKey: "ftp.path") ?? "/"

    func save() {
        UserDefaults.standard.set(host, forKey: "ftp.host")
        UserDefaults.standard.set(port, forKey: "ftp.port")
        UserDefaults.standard.set(username, forKey: "ftp.username")
        UserDefaults.standard.set(password, forKey: "ftp.password")
        UserDefaults.standard.set(path, forKey: "ftp.path")
    }

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

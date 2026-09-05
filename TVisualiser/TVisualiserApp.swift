import SwiftUI

@MainActor
@main
struct TVisualiserApp: App {
    @StateObject private var player: MediaPlayerStore
    @StateObject private var ftp: FTPAccountStore
    
    init() {
        //DebugSettings.enabled = true
        let player = MediaPlayerStore()
        let ftp = FTPAccountStore()
        _player = StateObject(wrappedValue: player)
        _ftp = StateObject(wrappedValue: ftp)
        player.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(ftp)
        }
    }
}

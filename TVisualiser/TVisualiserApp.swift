import SwiftUI

@MainActor
@main
struct TVisualiserApp: App {
    @StateObject private var player: MediaPlayerStore
    @StateObject private var telegram: TelegramAccountStore
    @StateObject private var googleDrive: GoogleDriveAccountStore
    
    init() {
        //DebugSettings.enabled = true
        let player = MediaPlayerStore()
        let telegram = TelegramAccountStore()
        let googleDrive = GoogleDriveAccountStore()
        _player = StateObject(wrappedValue: player)
        _telegram = StateObject(wrappedValue: telegram)
        _googleDrive = StateObject(wrappedValue: googleDrive)
        player.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(telegram)
                .environmentObject(googleDrive)
        }
    }
}

import SwiftUI

@main
struct TVisualiserApp: App {
    @StateObject private var receiver: ReceiverStore
    private let advertiser = AirPlayAdvertiser()
    
    init() {
        DebugSettings.enabled = true
        let receiver = ReceiverStore()
        _receiver = StateObject(wrappedValue: receiver)
        advertiser.startAdvertising()
        receiver.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(receiver)
        }
    }
}

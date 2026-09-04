import Foundation

final class AirPlayAdvertiser: NSObject, NetServiceDelegate {
    private var raopService: NetService?
    
    func startAdvertising(displayName: String = "TVisualiser", raopPort: Int32 = 5000, airplayPort: Int32 = 5000) {
        DebugSettings.log("Starting Bonjour advertisement for \(displayName)")
        let macAddress = "112233445566"
        let raopName = "\(macAddress)@\(displayName)"
        
        // 1. Audio Service (_raop._tcp.)
        raopService = NetService(
            domain: "local.",
            type: "_raop._tcp.",
            name: raopName,
            port: raopPort
        )
        
        let raopTxtRecord: [String: String] = [
            "txtvers": "1",
            "ch": "2",
            "cn": "0,1,2,3",
            "da": "true",
            "ek": "1",
            "et": "0,1,3,5",
            "md": "0,1,2",
            "pw": "false",
            "sf": "0x4",
            "sr": "44100",
            "ss": "16",
            "sv": "false",
            "tp": "UDP",
            "vn": "65537",
            "vs": "130.14",
            "am": "AppleTV2,1"
        ]
        
        raopService?.delegate = self
        raopService?.setTXTRecord(NetService.data(fromTXTRecord: raopTxtRecord.mapValues { $0.data(using: .utf8)! }))

        raopService?.publish()
        DebugSettings.log("RAOP audio service publish requested on port \(raopPort)")
    }

    func netServiceDidPublish(_ sender: NetService) {
        DebugSettings.log("Bonjour published \(sender.type) as \(sender.name):\(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        DebugSettings.log("Bonjour failed for \(sender.type): \(errorDict)")
    }

    func netServiceDidStop(_ sender: NetService) {
        DebugSettings.log("Bonjour stopped \(sender.type)")
    }
    
    func stopAdvertising() {
        raopService?.stop()
        raopService = nil
        DebugSettings.log("AirPlay advertisement stopped")
    }
}

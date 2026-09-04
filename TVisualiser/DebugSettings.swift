import Foundation

enum DebugSettings {
    // Set to false to silence all TVisualiser diagnostic output.
    static var enabled = true

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("[TVisualiser] \(message())")
    }
}

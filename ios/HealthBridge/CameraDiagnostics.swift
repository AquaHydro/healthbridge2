import Foundation

/// Opt-in debugging only. Never add image data, QR payloads, tokens or health samples.
enum CameraDiagnostics {
  static var enabled: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains("--camera-diagnostics")
    #else
      false
    #endif
  }
  private static let lock = NSLock()
  private static var events: [[String: Any]] = []
  static func record(_ event: String, _ fields: [String: Any] = [:]) {
    guard enabled else { return }
    lock.lock()
    defer { lock.unlock() }
    var entry = fields
    entry["event"] = event
    entry["time"] = Date().timeIntervalSince1970
    events.append(entry)
    events = Array(events.suffix(64))
    if let data = try? JSONSerialization.data(
      withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(
        to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
          "camera-diagnostics.json"), options: .atomic)
    }
  }
}

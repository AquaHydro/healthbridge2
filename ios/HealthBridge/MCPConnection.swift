import Foundation

extension ServerAPI {
  /// Verify only the MCP initialization response. No health tool is called here.
  func verifyMCP() async throws {
    var request = URLRequest(url: base.appendingPathComponent("mcp"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": [
        "protocolVersion": "2025-11-25", "capabilities": [:],
        "clientInfo": ["name": "HealthBridge setup", "version": "0.1.0"],
      ],
    ])
    let configuration = Self.sessionConfiguration()
    configuration.timeoutIntervalForResource = 20
    configuration.urlCache = nil
    let session = URLSession(
      configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      Self.isInitializationResponse(
        data: data, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "")
    else { throw CredentialError.invalidMCP }
  }
  static func isInitializationResponse(data: Data, contentType: String) -> Bool {
    guard data.count <= 65536 else { return false }
    let payloads: [Data]
    if contentType.lowercased().contains("text/event-stream") {
      let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
      payloads = text.components(separatedBy: "\n\n").compactMap { event in
        let lines = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map {
          String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        return lines.isEmpty ? nil : Data(lines.joined(separator: "\n").utf8)
      }
    } else if contentType.lowercased().contains("application/json") {
      payloads = [data]
    } else {
      return false
    }
    return payloads.contains { payload in
      guard let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
        message["jsonrpc"] as? String == "2.0", message["id"] as? Int == 1, message["error"] == nil,
        let result = message["result"] as? [String: Any], result["protocolVersion"] is String,
        let info = result["serverInfo"] as? [String: Any], info["name"] as? String == "HealthBridge"
      else { return false }
      return true
    }
  }
}

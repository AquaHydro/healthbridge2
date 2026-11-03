import Foundation
import Security
import UIKit

struct TokenPair: Codable {
  let ingest: String
  let mcp: String
  static func generate() throws -> Self {
    func random() throws -> String {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw BridgeError.keychain
      }
      return bytes.map { String(format: "%02x", $0) }.joined()
    }
    let ingest = try random()
    var mcp = try random()
    while ingest == mcp { mcp = try random() }
    return Self(ingest: ingest, mcp: mcp)
  }
}

enum CredentialRules {
  static func token(_ input: String) throws -> String {
    let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, token.utf8.count <= 4096,
      token.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || Array("-._~+/=".utf8).contains($0)
      })
    else { throw CredentialError.invalidToken }
    return token
  }
  static func origin(_ url: URL) -> String {
    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    c.host = c.host?.lowercased()
    c.path = ""
    c.query = nil
    c.fragment = nil
    if c.port == 443 { c.port = nil }
    return c.string!
  }
}
enum CredentialError: LocalizedError {
  case invalidToken, sameToken, invalidMCP
  var errorDescription: String? {
    switch self {
    case .invalidToken: "Token 仅支持字母、数字及 -._~+/=，不能包含空格或换行。"
    case .sameToken: "只读 Token 必须与写入 Token 不同。"
    case .invalidMCP: "无法验证 MCP 只读连接，请检查地址和 MCP_TOKEN。"
    }
  }
}
struct CredentialStore {
  let service: String
  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
  func read(_ account: String) throws -> Data? {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw BridgeError.keychain }
    return data
  }
  func save(_ data: Data, account: String) throws {
    let attrs: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary)
    if status == errSecItemNotFound {
      var q = query(account)
      q.merge(attrs) { _, new in new }
      guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw BridgeError.keychain }
    } else if status != errSecSuccess {
      throw BridgeError.keychain
    }
  }
  func delete(_ account: String) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw BridgeError.keychain
    }
  }
}
enum AgentClient: String, CaseIterable, Identifiable {
  case codex = "Codex"
  case claude = "Claude Code"
  case generic = "通用 JSON"
  var id: String { rawValue }
  func configuration(origin: URL, token: String?) throws -> String {
    let endpoint = origin.appendingPathComponent("mcp").absoluteString
    let credential = try token.map(CredentialRules.token) ?? "<你的 MCP_TOKEN>"
    if self == .codex {
      func quoted(_ value: String) throws -> String {
        // JSON basic strings are also valid TOML strings for these ASCII values.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(data: try encoder.encode(value), encoding: .utf8)!
      }
      return
        "[mcp_servers.healthbridge]\nurl = \(try quoted(endpoint))\nhttp_headers = { Authorization = \(try quoted("Bearer " + credential)) }\n"
    }
    let server: [String: Any] = [
      "type": "http", "url": endpoint, "headers": ["Authorization": "Bearer " + credential],
    ]
    let object: [String: Any] = self == .claude ? ["mcpServers": ["healthbridge": server]] : server
    return String(
      data: try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      encoding: .utf8)!
  }
}
@MainActor enum SecureCopy {
  static func text(_ value: String) {
    UIPasteboard.general.setItems(
      [["public.utf8-plain-text": value]],
      options: [.expirationDate: Date().addingTimeInterval(120), .localOnly: false])
  }
}

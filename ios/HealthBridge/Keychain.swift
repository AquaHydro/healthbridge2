import Foundation

enum Keychain {
  private static var suffix: String {
    #if DEBUG && targetEnvironment(simulator)
      ProcessInfo.processInfo.arguments.contains("--ui-test") ? ".ui-tests" : ""
    #else
      ""
    #endif
  }
  // Keep the original service/account so existing installed apps retain their upload token.
  private static var ingest: CredentialStore {
    CredentialStore(service: "app.yiliang.healthbridge.ingest" + suffix)
  }
  private static var mcp: CredentialStore {
    CredentialStore(service: "app.yiliang.healthbridge.mcp" + suffix)
  }
  private static var draft: CredentialStore {
    CredentialStore(service: "app.yiliang.healthbridge.setup" + suffix)
  }
  static func read() throws -> String {
    guard let data = try ingest.read("ingest"), let token = String(data: data, encoding: .utf8)
    else { throw BridgeError.keychain }
    return token
  }
  static func save(_ token: String) throws { try ingest.save(Data(token.utf8), account: "ingest") }
  static func delete() { try? ingest.delete("ingest") }
  static func readMCP(for url: URL) throws -> String? {
    try mcp.read(CredentialRules.origin(url)).flatMap { String(data: $0, encoding: .utf8) }
  }
  static func saveMCP(_ token: String, for url: URL) throws {
    try mcp.save(Data(token.utf8), account: CredentialRules.origin(url))
  }
  static func deleteMCP(for url: URL) throws { try mcp.delete(CredentialRules.origin(url)) }
  static func pendingPair() throws -> TokenPair? {
    try draft.read("pending").map { try JSONDecoder().decode(TokenPair.self, from: $0) }
  }
  static func savePendingPair(_ pair: TokenPair) throws {
    try draft.save(JSONEncoder().encode(pair), account: "pending")
  }
  static func clearPendingPair(matching token: String) throws {
    if try pendingPair()?.ingest == token { try draft.delete("pending") }
  }
  static func pairingAttempt(for invitation: ConnectionInvitation) throws -> PairingAttempt {
    if let data = try draft.read("pairing-attempt"),
      let attempt = try? JSONDecoder().decode(PairingAttempt.self, from: data),
      attempt.invitation == invitation
    {
      return attempt
    }
    let attempt = PairingAttempt(invitation: invitation, claimant: try TokenPair.generate().ingest)
    try draft.save(JSONEncoder().encode(attempt), account: "pairing-attempt")
    return attempt
  }
  static func clearPairingAttempt() throws { try draft.delete("pairing-attempt") }

}

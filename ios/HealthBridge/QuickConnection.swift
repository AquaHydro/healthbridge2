import Foundation

struct ConnectionInvitation: Codable, Identifiable, Equatable {
  let server: URL
  let code: String
  var id: String { code }
  static func parse(_ text: String) throws -> Self {
    guard text.utf8.count <= 4096,
      let link = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      link.scheme == "healthbridge", link.host == "connect", link.query == nil, link.path.isEmpty,
      link.user == nil, link.password == nil, link.port == nil,
      var encoded = link.fragment, !encoded.isEmpty
    else { throw PairingError.invalidLink }
    encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    struct Payload: Decodable {
      let v: Int
      let server: String
      let code: String
    }
    guard let data = Data(base64Encoded: encoded),
      let payload = try? JSONDecoder().decode(Payload.self, from: data),
      payload.v == 1, payload.code.count == 64,
      payload.code.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw PairingError.invalidLink }
    return Self(server: try ServerAPI.normalizedURL(payload.server), code: payload.code)
  }
}
struct PairingAttempt: Codable {
  let invitation: ConnectionInvitation
  let claimant: String
}
struct PairingResponse: Decodable {
  let ok: Bool
  let ingest_token: String
  let mcp_token: String
  let status: ServerStatus
}
enum PairingError: LocalizedError {
  case invalidLink, expired, unavailable
  var errorDescription: String? {
    switch self {
    case .invalidLink: "这不是有效的连接链接。"
    case .expired: "连接码已过期或已使用，请重新生成。"
    case .unavailable: "暂时无法连接，请稍后重试。"
    }
  }
}
extension ServerAPI {
  func redeem(_ invitation: ConnectionInvitation, claimant: String) async throws -> PairingResponse
  {
    struct Body: Encodable {
      let code: String
      let claimant: String
    }
    let result = try await request(
      "v1/pairing/redeem", method: "POST",
      body: JSONEncoder().encode(Body(code: invitation.code, claimant: claimant)),
      type: PairingResponse.self)
    guard result.ok, result.status.ok, result.status.schema_version == 1,
      try CredentialRules.token(result.ingest_token) != CredentialRules.token(result.mcp_token)
    else { throw PairingError.unavailable }
    return result
  }
}

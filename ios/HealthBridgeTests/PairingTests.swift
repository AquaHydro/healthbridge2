import XCTest

@testable import HealthBridge

final class PairingTests: XCTestCase {
  private func link(
    server: String = "https://example.test", code: String = String(repeating: "a", count: 64),
    version: Int = 1
  ) throws -> String {
    let json = try JSONSerialization.data(withJSONObject: [
      "v": version, "server": server, "code": code,
    ])
    return "healthbridge://connect#"
      + json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
        of: "/", with: "_"
      ).replacingOccurrences(of: "=", with: "")
  }
  func testInvitationAcceptsOnlyExpectedVersionSecureOriginAndCode() throws {
    let parsed = try ConnectionInvitation.parse(link())
    XCTAssertEqual(parsed.server.host, "example.test")
    XCTAssertEqual(parsed.code.count, 64)
    for invalid in [
      try link(server: "http://example.test"), try link(server: "https://example.test/path"),
      try link(code: "guessable"), try link(version: 2), "healthbridge://connect?token=secret",
      String(repeating: "x", count: 4097),
    ] { XCTAssertThrowsError(try ConnectionInvitation.parse(invalid)) }
  }
  func testPairingAttemptUsesSameClaimantForSafeRetries() throws {
    let store = CredentialStore(service: "healthbridge.pairing-test." + UUID().uuidString)
    defer { try? store.delete("attempt") }
    let invitation = try ConnectionInvitation.parse(link())
    let attempt = PairingAttempt(
      invitation: invitation, claimant: String(repeating: "b", count: 64))
    try store.save(JSONEncoder().encode(attempt), account: "attempt")
    let restored = try JSONDecoder().decode(
      PairingAttempt.self, from: XCTUnwrap(store.read("attempt")))
    XCTAssertEqual(restored.invitation, invitation)
    XCTAssertTrue(restored.claimant == attempt.claimant)
  }
}

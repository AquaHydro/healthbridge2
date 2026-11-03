import UIKit
import XCTest

@testable import HealthBridge

// Boundaries: legacy token compatibility, isolated origins, draft persistence, failed reads,
// unsafe token input, JSON/TOML escaping, wrong MCP replies, expiry and reader-only exports.
final class CredentialTests: XCTestCase {
  func testGeneratedTokensAreIndependentAnd256BitHex() throws {
    let pair = try TokenPair.generate()
    XCTAssertTrue(pair.ingest.count == 64 && pair.mcp.count == 64)
    XCTAssertTrue(pair.ingest != pair.mcp)
    XCTAssertTrue((pair.ingest + pair.mcp).allSatisfy { $0.isHexDigit })
  }
  func testKeychainOriginIsolationDraftRecoveryAndDelete() throws {
    let store = CredentialStore(service: "healthbridge.test." + UUID().uuidString)
    let a = CredentialRules.origin(URL(string: "https://EXAMPLE.test:443/")!)
    let b = CredentialRules.origin(URL(string: "https://other.test")!)
    defer {
      try? store.delete(a)
      try? store.delete(b)
    }
    XCTAssertEqual(a, "https://example.test")
    let pair = TokenPair(ingest: "synthetic-writer", mcp: "synthetic-reader")
    try store.save(JSONEncoder().encode(pair), account: a)
    XCTAssertNil(try store.read(b))
    let restored = try JSONDecoder().decode(TokenPair.self, from: XCTUnwrap(store.read(a)))
    XCTAssertTrue(restored.ingest == pair.ingest && restored.mcp == pair.mcp)
    try store.save(Data("synthetic-new".utf8), account: a)
    XCTAssertTrue(try store.read(a) == Data("synthetic-new".utf8))
    try store.delete(a)
    XCTAssertNil(try store.read(a))
  }
  func testTokenValidationRejectsControlCharacters() throws {
    for invalid in ["", "a b", "a\nb", "中文", String(repeating: "x", count: 4097)] {
      XCTAssertThrowsError(try CredentialRules.token(invalid))
    }
    XCTAssertEqual(try CredentialRules.token(" abc123 \n"), "abc123")
  }
  func testClientConfigurationsExportOnlyReaderWithValidSerialization() throws {
    let url = URL(string: "https://example.test")!
    let reader = "synthetic-reader_+/=."
    for client in AgentClient.allCases {
      let config = try client.configuration(origin: url, token: reader)
      XCTAssertFalse(config.contains("synthetic-writer"))
      XCTAssertFalse(try client.configuration(origin: url, token: nil).contains(reader))
      if client != .codex {
        let root = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let server =
          client == .claude
          ? ((root["mcpServers"] as? [String: Any])?["healthbridge"] as? [String: Any]) : root
        XCTAssertEqual(
          (server?["headers"] as? [String: String])?["Authorization"], "Bearer " + reader)
      } else {
        XCTAssertFalse(config.contains(#"\/"#))
      }
    }
  }
  func testMCPInitializationParserRequiresMatchingResponse() {
    let valid =
      #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"HealthBridge"}}}"#
    XCTAssertTrue(
      ServerAPI.isInitializationResponse(data: Data(valid.utf8), contentType: "application/json"))
    XCTAssertTrue(
      ServerAPI.isInitializationResponse(
        data: Data("event: message\r\ndata: \(valid)\r\n\r\n".utf8),
        contentType: "text/event-stream; charset=utf-8"))
    for invalid in [
      "{}", valid.replacingOccurrences(of: "HealthBridge", with: "Other"),
      valid.replacingOccurrences(of: #""id":1"#, with: #""id":2"#),
    ] {
      XCTAssertFalse(
        ServerAPI.isInitializationResponse(
          data: Data(invalid.utf8), contentType: "application/json"))
    }
  }
  @MainActor func testCopyPreservesExactConfig() {
    let fixture = "synthetic-reader-copy-test"
    SecureCopy.text(fixture)
    XCTAssertTrue(UIPasteboard.general.string == fixture)
    UIPasteboard.general.items = []
  }
}

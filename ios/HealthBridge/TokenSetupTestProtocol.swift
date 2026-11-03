#if DEBUG && targetEnvironment(simulator)
  import Foundation

  /// Isolated, synthetic UI acceptance transport, never compiled into a device build.
  final class TokenSetupTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
      request.url?.host == "example.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      if request.url?.path == "/v1/pairing/redeem" {
        let body =
          "{\"ok\":true,\"ingest_token\":\"synthetic-writer-test\",\"mcp_token\":\"synthetic-reader-test\",\"status\":{\"ok\":true,\"version\":\"0.1.0\",\"schema_version\":1,\"counts\":{}}}"
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
        return
      }
      let allowed =
        request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-reader-test"
      let body =
        allowed
        ? #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"HealthBridge","version":"0.1.0"}}}"#
        : #"{"error":"unauthorized"}"#
      let response = HTTPURLResponse(
        url: request.url!, statusCode: allowed ? 200 : 401, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }
#endif

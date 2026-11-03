import Foundation

final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
struct ServerAPI {
  let base: URL
  let token: String
  static func normalizedURL(_ text: String) throws -> URL {
    guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      c.scheme == "https", c.host != nil, c.user == nil, c.password == nil, c.query == nil,
      c.fragment == nil, c.path.isEmpty || c.path == "/", let url = c.url
    else { throw BridgeError.invalidURL }
    return url
  }
  func request<T: Decodable>(
    _ path: String, method: String = "GET", body: Data? = nil, type: T.Type
  ) async throws -> T {
    var request = URLRequest(url: base.appendingPathComponent(path))
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 15
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let config = Self.sessionConfiguration()
    config.timeoutIntervalForResource = 20
    config.urlCache = nil
    let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw BridgeError.unavailable }
    if http.statusCode == 410 { throw PairingError.expired }
    if http.statusCode == 429 { throw PairingError.unavailable }
    if http.statusCode == 401 { throw BridgeError.unauthorized }
    if http.statusCode == 400 || http.statusCode == 404 { throw BridgeError.incompatible }
    guard http.statusCode == 200 else { throw BridgeError.unavailable }
    return try JSONDecoder().decode(T.self, from: data)
  }
  func ping() async throws -> ServerStatus {
    let status = try await request("v1/ping", type: ServerStatus.self)
    guard status.ok, status.schema_version == 1 else { throw BridgeError.incompatible }
    return status
  }
  func upload(_ batch: IngestBatch) async throws {
    let receipt = try await request(
      "v1/ingest", method: "POST", body: JSONEncoder().encode(batch), type: IngestReceipt.self)
    try Self.validate(receipt, for: batch)
  }
  static func validate(_ receipt: IngestReceipt, for batch: IngestBatch) throws {
    guard receipt.ok, receipt.added == batch.added.count, receipt.deleted == batch.deleted.count
    else { throw BridgeError.invalidReceipt }
    if let hourly = batch.hourly {
      guard receipt.hourly == hourly.count,
        receipt.hourly_ranges == batch.hourly_ranges?.count
      else { throw BridgeError.incompatible }
    }
  }
  func deleteAll() async throws {
    struct Receipt: Decodable { let ok: Bool }
    let receipt = try await request("v1/data", method: "DELETE", type: Receipt.self)
    guard receipt.ok else { throw BridgeError.invalidReceipt }
  }
}

extension ServerAPI {
  static func sessionConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--ui-token-network") {
        config.protocolClasses = [TokenSetupTestProtocol.self]
      }
    #endif
    return config
  }
}

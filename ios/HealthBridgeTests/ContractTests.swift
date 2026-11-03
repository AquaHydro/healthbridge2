import XCTest

@testable import HealthBridge

final class ContractTests: XCTestCase {
  func testConnectionRequiresOriginOnlyHTTPS() throws {
    for invalid in [
      "http://example.com", "https://a:b@example.com", "https://example.com/path",
      "https://example.com?token=x", "https://example.com#token",
    ] { XCTAssertThrowsError(try ServerAPI.normalizedURL(invalid)) }
    XCTAssertEqual(try ServerAPI.normalizedURL("https://example.com/").host, "example.com")
  }
  func testSleepEncodesExplicitNullUnit() throws {
    let sample = HealthSample(
      uuid: UUID().uuidString, type: "sleep", start_ms: 0, end_ms: 1, tz_min: 0, value: 3,
      unit: nil, source: "Synthetic", device: nil)
    let data = try JSONEncoder().encode(sample)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertTrue(object["unit"] is NSNull)
  }
  func testSharingRequiresBothConnectionAndExplicitConsent() {
    var p = Preferences()
    XCTAssertFalse(p.canSync)
    p.server = "https://example.com"
    XCTAssertFalse(p.canSync)
    p.consentDate = Date()
    XCTAssertTrue(p.canSync)
    p.consentDate = nil
    XCTAssertFalse(p.canSync)
  }
}

extension ContractTests {
  func testOlderSavedPreferencesKeepConnectionAndConsent() throws {
    var p = Preferences()
    p.onboarded = true
    p.server = "https://example.com"
    p.consentDate = Date()
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
    object.removeValue(forKey: "authorizationPending")
    let restored = try JSONDecoder().decode(
      Preferences.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(restored.server, p.server)
    XCTAssertTrue(restored.canUpload)
  }
  func testIncompleteHealthSetupCannotUpload() {
    var p = Preferences()
    p.server = "https://example.com"
    p.consentDate = Date()
    XCTAssertFalse(p.canUpload)
    p.onboarded = true
    XCTAssertTrue(p.canUpload)
    p.authorizationPending = true
    XCTAssertFalse(p.canUpload)
  }
}

extension ContractTests {
  // Failure modes: duplicate notifications, changes during a running pass, disabled types,
  // cross-hour samples, sparse historical deltas, unknown deletions, legacy preferences.
  func testSyncQueueMergesTypesAndRetainsUpdatesDuringPass() {
    var queue = SyncQueue()
    queue.enqueue([.steps], selected: [.steps, .sleep])
    queue.enqueue([.steps, .sleep, .hrv], selected: [.steps, .sleep])
    XCTAssertEqual(queue.take(), [.steps, .sleep])
    queue.enqueue([.steps], selected: [.steps, .sleep])
    XCTAssertEqual(queue.take(), [.steps])
    XCTAssertTrue(queue.types.isEmpty)
  }
  func testHourlyWindowsKeepSparseChangesSeparateAndCoverCrossHourSamples() {
    let hour: Int64 = 3_600_000
    func sample(_ start: Int64, _ end: Int64) -> HealthSample {
      HealthSample(uuid: UUID().uuidString, type: "steps", start_ms: start, end_ms: end,
        tz_min: 0, value: 10, unit: "count", source: nil, device: nil)
    }
    let windows = HourlyWindow.affected(added: [sample(100, hour + 1), sample(hour * 20, hour * 21)],
      deleted: [], since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 100000))
    XCTAssertEqual(windows.count, 2)
    XCTAssertEqual(windows[0].end.timeIntervalSince1970, 7200)
    XCTAssertEqual(windows[1].start.timeIntervalSince1970, 72000)
    XCTAssertEqual(windows[1].end.timeIntervalSince1970, 75600)
  }
  func testDeletionRebuildAndPersistedResumeSurviveRelaunch() throws {
    let windows = HourlyWindow.affected(added: [], deleted: ["synthetic-deletion"],
      since: Date(timeIntervalSince1970: 3700), now: Date(timeIntervalSince1970: 10000))
    XCTAssertEqual(windows, [HourlyWindow(start: Date(timeIntervalSince1970: 3600),
      end: Date(timeIntervalSince1970: 10800))])
    var p = Preferences()
    p.hourlyResume["steps"] = HourlyResume(fingerprint: "synthetic-page", cursor: Date(timeIntervalSince1970: 7200))
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
    XCTAssertEqual(restored.hourlyResume["steps"]?.cursor.timeIntervalSince1970, 7200)
  }
  func testOldPreferencesDefaultToHourlyAndRetainConsent() throws {
    var p = Preferences()
    p.consentDate = Date()
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
    for key in ["frequency", "lastTrigger", "hourlyFormatVersion", "hourlyResume"] { object.removeValue(forKey: key) }
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(restored.frequency, .hourly)
    XCTAssertEqual(restored.hourlyFormatVersion, 0)
    XCTAssertNotNil(restored.consentDate)
  }
}

extension ContractTests {
  func testFrequencyMergesContinuousNotificationsUntilIntervalExpires() {
    let previous = Date(timeIntervalSince1970: 10000)
    XCTAssertEqual(SyncFrequency.hourly.nextAllowed(after: previous), previous.addingTimeInterval(3600))
    XCTAssertEqual(SyncFrequency.daily.nextAllowed(after: previous), previous.addingTimeInterval(86400))
    XCTAssertEqual(SyncFrequency.immediate.nextAllowed(after: previous), previous)
    XCTAssertEqual(SyncFrequency.manual.nextAllowed(after: previous), .distantFuture)
    XCTAssertLessThan(SyncFrequency.hourly.nextAllowed(after: nil), Date())
  }
}

extension ContractTests {
  func testOldServerReceiptCannotConfirmHourlyPage() throws {
    let batch = IngestBatch(added: [], deleted: [], types: ["steps"], hourly: [], hourly_ranges: [])
    let old = try JSONDecoder().decode(IngestReceipt.self,
      from: Data("{\"ok\":true,\"added\":0,\"deleted\":0}".utf8))
    XCTAssertThrowsError(try ServerAPI.validate(old, for: batch))
    let current = try JSONDecoder().decode(IngestReceipt.self,
      from: Data("{\"ok\":true,\"added\":0,\"deleted\":0,\"hourly\":0,\"hourly_ranges\":0}".utf8))
    XCTAssertNoThrow(try ServerAPI.validate(current, for: batch))
  }
}

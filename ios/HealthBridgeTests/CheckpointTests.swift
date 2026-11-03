import HealthKit
import XCTest

@testable import HealthBridge

@MainActor final class CheckpointTests: XCTestCase {
  private var page: HealthPage {
    HealthPage(
      added: [], deleted: [UUID().uuidString], anchor: HKQueryAnchor(fromValue: 7), count: 1)
  }
  func testEmptyRawPageAcknowledgesWithoutUploading() async throws {
    let empty = HealthPage(added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 8), count: 0)
    var uploads = 0
    let anchor = try await PageTransfer.acknowledgedAnchor(
      page: empty, type: .hrv, allowed: { true }, upload: { _ in uploads += 1 })
    XCTAssertEqual(uploads, 0)
    XCTAssertFalse(anchor.isEmpty)
  }
  func testNoConsentNeverStartsUpload() async {
    var called = false
    do {
      _ = try await PageTransfer.acknowledgedAnchor(page: page, type: .steps, allowed: { false }) {
        _ in called = true
      }
      XCTFail("Must refuse")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(called)
  }
  func testFailedReceiptProducesNoCheckpoint() async {
    do {
      _ = try await PageTransfer.acknowledgedAnchor(page: page, type: .steps, allowed: { true }) {
        _ in throw BridgeError.invalidReceipt
      }
      XCTFail("Must not commit")
    } catch { XCTAssertTrue(error is BridgeError) }
  }
  func testRevocationWhileRequestIsInFlightProducesNoCheckpoint() async {
    var consent = true
    do {
      _ = try await PageTransfer.acknowledgedAnchor(page: page, type: .steps, allowed: { consent })
      { _ in consent = false }
      XCTFail("Must not commit")
    } catch { XCTAssertTrue(error is CancellationError) }
  }
  func testAcknowledgedDeletionCanAdvanceAnchor() async throws {
    let data = try await PageTransfer.acknowledgedAnchor(
      page: page, type: .steps, allowed: { true }
    ) { batch in
      XCTAssertEqual(batch.deleted.count, 1)
      XCTAssertEqual(batch.types, ["steps"])
    }
    XCTAssertNotNil(try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data))
  }
  func testCancelledUploadCannotCommitEvenIfTransportReturnsSuccess() async {
    let page = page
    let task = Task {
      try await PageTransfer.acknowledgedAnchor(page: page, type: .steps, allowed: { true }) { _ in
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Must not commit")
    } catch { XCTAssertTrue(error is CancellationError) }
  }
}

final class HourlyAggregationTests: XCTestCase {
  // Failure modes: boundary duplication, empty/deleted hours, invalid readings,
  // uneven observation counts, and timezone changes affecting bucket identity.
  func testHeartRateHourlyCountsAndExclusiveEnd() {
    let start = Date(timeIntervalSince1970: 3_600)
    let end = start.addingTimeInterval(7_200)
    let result = HealthStore.heartRateBuckets([
      (start.addingTimeInterval(-1), 200), (start, 60),
      (start.addingTimeInterval(3_599), 80),
      (start.addingTimeInterval(3_600), 100), (end, 200),
      (start, .nan), (start, 0)
    ], since: start, until: end)
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0].count, 2)
    XCTAssertEqual(result[0].sum, 140)
    XCTAssertEqual(result[0].min, 60)
    XCTAssertEqual(result[0].max, 80)
    XCTAssertEqual(result[1].count, 1)
    XCTAssertEqual(result[1].sum, 100)
    XCTAssertEqual(result[0].start_ms, 3_600_000)
    XCTAssertEqual(result[0].end_ms, 7_200_000)
  }
  func testEmptyWindowProducesNoBucketsForReplacement() {
    XCTAssertTrue(HealthStore.heartRateBuckets([], since: .distantPast, until: .distantFuture).isEmpty)
  }
  func testHourIdentityUsesAbsoluteTime() {
    XCTAssertEqual(HealthStore.hourStart(Date(timeIntervalSince1970: 7_199)).timeIntervalSince1970, 3_600)
    XCTAssertEqual(HealthStore.hourStart(Date(timeIntervalSince1970: 7_200)).timeIntervalSince1970, 7_200)
  }
}

@MainActor final class HourlyTransferTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 0)
  private var page: HealthPage {
    HealthPage(added: [], deleted: ["deleted-synthetic"], anchor: HKQueryAnchor(fromValue: 9), count: 1)
  }
  private enum Failure: Error { case upload, budget }

  func testSecondWindowFailureResumesOnlyAfterAcknowledgedWindow() async throws {
    let end = start.addingTimeInterval(14 * 86400)
    let windows = [HourlyWindow(start: start, end: end)]
    var resume: HourlyResume?
    var reads: [Date] = []
    var sent = 0
    var committedAnchor: Data?
    do {
      committedAnchor = try await HourlyTransfer.acknowledgedAnchor(
        page: page, type: .steps, windows: windows, fingerprint: "same-page", resume: nil,
        allowed: { true }, read: { window in reads.append(window.start); return [] },
        upload: { batch in
          if batch.hourly_ranges?.isEmpty == false {
            sent += 1
            if sent == 2 { throw Failure.upload }
          }
        }, checkpoint: { resume = $0 })
      XCTFail("A failed window cannot acknowledge the page")
    } catch Failure.upload {}
    XCTAssertNil(committedAnchor)
    XCTAssertEqual(resume?.cursor, start.addingTimeInterval(7 * 86400))
    reads = []
    committedAnchor = try await HourlyTransfer.acknowledgedAnchor(
      page: page, type: .steps, windows: windows, fingerprint: "same-page", resume: resume,
      allowed: { true }, read: { window in reads.append(window.start); return [] },
      upload: { _ in }, checkpoint: { resume = $0 })
    XCTAssertEqual(reads, [start.addingTimeInterval(7 * 86400)])
    XCTAssertNil(resume)
    XCTAssertNotNil(committedAnchor)
  }

  func testDifferentPageNeverReusesCursor() async throws {
    var starts: [Date] = []
    _ = try await HourlyTransfer.acknowledgedAnchor(
      page: page, type: .steps,
      windows: [HourlyWindow(start: start, end: start.addingTimeInterval(3600))],
      fingerprint: "new-page", resume: HourlyResume(fingerprint: "old-page", cursor: .distantFuture),
      allowed: { true }, read: { starts.append($0.start); return [] },
      upload: { _ in }, checkpoint: { _ in })
    XCTAssertEqual(starts, [start])
  }

  func testDeletingLastSampleSendsEmptyReplacementRange() async throws {
    var replacements: [IngestBatch] = []
    _ = try await HourlyTransfer.acknowledgedAnchor(
      page: page, type: .heartRate,
      windows: [HourlyWindow(start: start, end: start.addingTimeInterval(3600))],
      fingerprint: "deletion", resume: nil, allowed: { true }, read: { _ in [] },
      upload: { if $0.hourly_ranges?.isEmpty == false { replacements.append($0) } },
      checkpoint: { _ in })
    XCTAssertEqual(replacements.count, 1)
    XCTAssertTrue(replacements[0].hourly?.isEmpty == true)
    XCTAssertEqual(replacements[0].hourly_ranges?.first?.start_ms, 0)
    XCTAssertEqual(replacements[0].hourly_ranges?.first?.end_ms, 3_600_000)
    XCTAssertTrue(replacements[0].deleted.isEmpty)
  }

  func testRevocationAfterReceiptDoesNotCommitWindowOrAnchor() async {
    var consent = true
    var checkpoints = 0
    do {
      _ = try await HourlyTransfer.acknowledgedAnchor(
        page: page, type: .steps,
        windows: [HourlyWindow(start: start, end: start.addingTimeInterval(3600))],
        fingerprint: "revoked", resume: nil, allowed: { consent }, read: { _ in [] },
        upload: { if $0.hourly_ranges?.isEmpty == false { consent = false } },
        checkpoint: { _ in checkpoints += 1 })
      XCTFail("Revoked consent cannot acknowledge")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(checkpoints, 0)
  }

  func testBudgetExpiryKeepsWindowCheckpointWithoutAcknowledgingPage() async {
    var resume: HourlyResume?
    do {
      _ = try await HourlyTransfer.acknowledgedAnchor(
        page: page, type: .steps,
        windows: [HourlyWindow(start: start, end: start.addingTimeInterval(8 * 86400))],
        fingerprint: "budget", resume: nil, allowed: { true }, read: { _ in [] },
        upload: { _ in }, checkpoint: { resume = $0 },
        didCommitWindow: { throw Failure.budget })
      XCTFail("Budget expiry must defer the page anchor")
    } catch Failure.budget {} catch { XCTFail("Unexpected error") }
    XCTAssertEqual(resume?.cursor, start.addingTimeInterval(7 * 86400))
  }
}

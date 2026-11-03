import Foundation
import HealthKit

/// The only path that produces a persistable anchor. Rejected receipts, cancellation,
/// or revoked consent throw before a new checkpoint can be stored.
struct PageTransfer {
  @MainActor static func acknowledgedAnchor(
    page: HealthPage,
    type: HealthType,
    allowed: () -> Bool,
    upload: (IngestBatch) async throws -> Void
  ) async throws -> Data {
    try Task.checkCancellation()
    guard allowed() else { throw CancellationError() }
    if !page.added.isEmpty || !page.deleted.isEmpty {
      try await upload(IngestBatch(added: page.added, deleted: page.deleted, types: [type.rawValue]))
    }
    try Task.checkCancellation()
    guard allowed() else { throw CancellationError() }
    return try NSKeyedArchiver.archivedData(
      withRootObject: page.anchor, requiringSecureCoding: true)
  }
}

/// Replacements are acknowledged individually; the HealthKit page anchor is returned
/// only when every affected hour has been replaced. A replay can resume the same page.
struct HourlyTransfer {
  @MainActor static func acknowledgedAnchor(
    page: HealthPage, type: HealthType, windows: [HourlyWindow], fingerprint: String,
    resume: HourlyResume?, allowed: () -> Bool,
    read: (HourlyWindow) async throws -> [HourlyBucket],
    upload: (IngestBatch) async throws -> Void,
    checkpoint: (HourlyResume?) -> Void,
    didCommitWindow: () throws -> Void = {}
  ) async throws -> Data {
    func checkAllowed() throws {
      try Task.checkCancellation()
      guard allowed() else { throw CancellationError() }
    }
    try checkAllowed()
    let resumedCursor = resume?.fingerprint == fingerprint ? resume?.cursor : nil
    for window in windows {
      var cursor = max(window.start, resumedCursor ?? window.start)
      while cursor < window.end {
        try checkAllowed()
        let until = min(cursor.addingTimeInterval(7 * 86400), window.end)
        let part = HourlyWindow(start: cursor, end: until)
        let buckets = try await read(part)
        try checkAllowed()
        try await upload(IngestBatch(added: [], deleted: [], types: [type.rawValue],
          hourly: buckets, hourly_ranges: [HourlyRange(type: type.rawValue,
            start_ms: Int64(cursor.timeIntervalSince1970 * 1000),
            end_ms: Int64(until.timeIntervalSince1970 * 1000))]))
        try checkAllowed()
        cursor = until
        checkpoint(HourlyResume(fingerprint: fingerprint, cursor: cursor))
        try didCommitWindow()
      }
    }
    try checkAllowed()
    let anchor = try NSKeyedArchiver.archivedData(withRootObject: page.anchor, requiringSecureCoding: true)
    checkpoint(nil)
    return anchor
  }
}

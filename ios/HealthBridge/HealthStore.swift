import Foundation
import HealthKit

struct HealthPage {
  let added: [HealthSample]
  let deleted: [String]
  let anchor: HKQueryAnchor
  let count: Int
}
final class HealthStore {
  let store = HKHealthStore()
  func authorize(_ types: Set<HealthType>) async throws {
    guard HKHealthStore.isHealthDataAvailable() else { throw BridgeError.noHealth }
    try await store.requestAuthorization(toShare: [], read: Set(types.map(\.hkType)))
  }
  func page(_ type: HealthType, since: Date, anchor: HKQueryAnchor?) async throws -> HealthPage {
    try await withCheckedThrowingContinuation { continuation in
      let query = HKAnchoredObjectQuery(
        type: type.hkType,
        predicate: HKQuery.predicateForSamples(
          withStart: since, end: nil, options: (type == .steps || type == .heartRate) ? [] : .strictStartDate), anchor: anchor, limit: 250
      ) { _, samples, deleted, anchor, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let anchor else {
          continuation.resume(throwing: BridgeError.noHealth)
          return
        }
        let added = (samples ?? []).map { Self.convert($0, type: type) }
        continuation.resume(
          returning: HealthPage(
            added: added, deleted: (deleted ?? []).map { $0.uuid.uuidString.lowercased() },
            anchor: anchor, count: added.count + (deleted?.count ?? 0)))
      }
      store.execute(query)
    }
  }
  /// Fixed UTC hours keep bucket identity stable across travel and daylight saving changes.
  static func hourStart(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3600) * 3600)
  }

  /// Re-read every requested window, including empty results. Replacing the whole
  /// window on the server removes buckets whose final HealthKit sample was deleted.
  func hourly(_ type: HealthType, since: Date, until: Date, notBefore: Date? = nil) async throws -> [HourlyBucket] {
    guard type == .steps || type == .heartRate, since < until else { return [] }
    let lowerBound = max(since, notBefore ?? since)
    try Task.checkCancellation()
    if type == .heartRate {
      let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
        let query = HKSampleQuery(
          sampleType: type.hkType,
          predicate: HKQuery.predicateForSamples(
            withStart: since, end: until),
          limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { _, samples, error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKQuantitySample }) }
        }
        store.execute(query)
      }
      try Task.checkCancellation()
      var readings: [(Date, Double)] = []
      for sample in samples {
        try Task.checkCancellation()
        if sample.count > 1 {
          // Condensed workout samples may span hours. Read each underlying value,
          // rather than treating an average as one observation or inventing weights.
          readings += try await heartRateSeries(sample)
        } else {
          readings.append((sample.startDate, sample.quantity.doubleValue(for: type.hkUnit)))
        }
      }
      return Self.heartRateBuckets(readings, since: lowerBound, until: until).map { bucket in
        var bucket = bucket
        bucket.coverage_start_ms = Int64(max(Date(timeIntervalSince1970: Double(bucket.start_ms) / 1000), lowerBound).timeIntervalSince1970 * 1000)
        return bucket
      }
    }
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKStatisticsCollectionQuery(
        quantityType: type.hkType as! HKQuantityType,
        quantitySamplePredicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
          HKQuery.predicateForSamples(withStart: since, end: until),
          HKQuery.predicateForSamples(withStart: notBefore, end: nil, options: .strictStartDate),
        ]),
        options: .cumulativeSum, anchorDate: Date(timeIntervalSince1970: 0),
        intervalComponents: DateComponents(hour: 1))
      query.initialResultsHandler = { _, collection, error in
        if let error { continuation.resume(throwing: error); return }
        guard let collection else {
          continuation.resume(throwing: BridgeError.noHealth); return
        }
        var buckets: [HourlyBucket] = []
        collection.enumerateStatistics(from: since, to: until) { statistics, _ in
          guard statistics.startDate >= since, statistics.startDate < until,
            let quantity = statistics.sumQuantity() else { return }
          let value = quantity.doubleValue(for: type.hkUnit)
          var bucket = Self.bucket(type: type, start: statistics.startDate,
            sum: value, count: 1, minimum: value, maximum: value)
          bucket.coverage_start_ms = Int64(max(statistics.startDate, lowerBound).timeIntervalSince1970 * 1000)
          buckets.append(bucket)
        }
        continuation.resume(returning: buckets)
      }
      store.execute(query)
    }
  }

  private func heartRateSeries(_ sample: HKQuantitySample) async throws -> [(Date, Double)] {
    try await withCheckedThrowingContinuation { continuation in
      var readings: [(Date, Double)] = []
      let query = HKQuantitySeriesSampleQuery(
        quantityType: sample.quantityType,
        predicate: HKQuery.predicateForObject(with: sample.uuid)
      ) { _, quantity, interval, _, done, error in
        if let error { continuation.resume(throwing: error); return }
        if let quantity, let interval {
          readings.append((interval.start, quantity.doubleValue(for: HealthType.heartRate.hkUnit)))
        }
        if done { continuation.resume(returning: readings) }
      }
      store.execute(query)
    }
  }

  static func heartRateBuckets(
    _ samples: [(Date, Double)], since: Date, until: Date
  ) -> [HourlyBucket] {
    let grouped = Dictionary(grouping: samples.filter {
      $0.0 >= since && $0.0 < until && $0.1.isFinite && $0.1 > 0
    }) { hourStart($0.0) }
    return grouped.keys.sorted().map { start in
      let values = grouped[start]!.map { $0.1 }
      return bucket(type: .heartRate, start: start, sum: values.reduce(0, +),
        count: values.count, minimum: values.min()!, maximum: values.max()!)
    }
  }

  private static func bucket(type: HealthType, start: Date, sum: Double,
    count: Int, minimum: Double, maximum: Double) -> HourlyBucket {
    HourlyBucket(type: type.rawValue,
      start_ms: Int64(start.timeIntervalSince1970 * 1000),
      end_ms: Int64(start.timeIntervalSince1970 * 1000) + 3_600_000,
      tz_min: TimeZone.current.secondsFromGMT(for: start) / 60,
      sum: sum, count: count, min: minimum, max: maximum)
  }

  static func convert(_ sample: HKSample, type: HealthType) -> HealthSample {
    let zone =
      (sample.metadata?[HKMetadataKeyTimeZone] as? String).flatMap(TimeZone.init(identifier:))
      ?? .current
    let value: Double
    if let quantity = sample as? HKQuantitySample {
      value = quantity.quantity.doubleValue(for: type.hkUnit)
    } else {
      value = Double((sample as? HKCategorySample)?.value ?? 0)
    }
    return HealthSample(
      uuid: sample.uuid.uuidString.lowercased(), type: type.rawValue,
      start_ms: Int64(sample.startDate.timeIntervalSince1970 * 1000),
      end_ms: Int64(sample.endDate.timeIntervalSince1970 * 1000),
      tz_min: zone.secondsFromGMT(for: sample.startDate) / 60, value: value, unit: type.unit,
      source: sample.sourceRevision.source.name, device: sample.sourceRevision.productType)
  }
  func overview(_ type: HealthType, days: Int = 30) async throws -> [DayValue] {
    let calendar = Calendar.current
    let start = calendar.date(
      byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: Date()))!
    if type == .sleep {
      let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
        let q = HKSampleQuery(
          sampleType: type.hkType,
          predicate: HKQuery.predicateForSamples(
            withStart: start.addingTimeInterval(-86400), end: Date()), limit: HKObjectQueryNoLimit,
          sortDescriptors: nil
        ) { _, samples, error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: samples ?? [])
          }
        }
        store.execute(q)
      }
      let nights = Dictionary(grouping: samples.compactMap { $0 as? HKCategorySample }) { sample in
        calendar.startOfDay(for: calendar.date(byAdding: .hour, value: 6, to: sample.endDate)!)
      }
      return nights.compactMap { date, rows in
        guard date >= start else { return nil }
        let sources = Dictionary(grouping: rows) {
          "\($0.sourceRevision.source.bundleIdentifier)|\($0.sourceRevision.productType ?? "")"
        }
        let chosen =
          sources.sorted { a, b in
            let stagesA = a.value.filter { $0.value >= 3 }.count
            let stagesB = b.value.filter { $0.value >= 3 }.count
            return stagesA != stagesB
              ? stagesA > stagesB : Self.duration(a.value) > Self.duration(b.value)
          }.first?.value ?? []
        return DayValue(date: date, value: Self.duration(chosen) / 3600)
      }.sorted { $0.date < $1.date }
    }
    return try await withCheckedThrowingContinuation { continuation in
      let option: HKStatisticsOptions = type == .steps ? .cumulativeSum : .discreteAverage
      let q = HKStatisticsCollectionQuery(
        quantityType: type.hkType as! HKQuantityType,
        quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: Date()),
        options: option, anchorDate: start, intervalComponents: DateComponents(day: 1))
      q.initialResultsHandler = { _, collection, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        var values: [DayValue] = []
        collection?.enumerateStatistics(from: start, to: Date()) { statistics, _ in
          if let quantity = type == .steps ? statistics.sumQuantity() : statistics.averageQuantity()
          {
            values.append(
              DayValue(date: statistics.startDate, value: quantity.doubleValue(for: type.hkUnit)))
          }
        }
        continuation.resume(returning: values)
      }
      store.execute(q)
    }
  }
  static func duration(_ samples: [HKCategorySample]) -> TimeInterval {
    let sorted = samples.filter { $0.value == 1 || $0.value >= 3 }.sorted {
      $0.startDate < $1.startDate
    }
    var end = Date.distantPast
    var duration: TimeInterval = 0
    for sample in sorted {
      duration += max(0, sample.endDate.timeIntervalSince(max(end, sample.startDate)))
      end = max(end, sample.endDate)
    }
    return duration
  }
}

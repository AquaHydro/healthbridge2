import Foundation
import CryptoKit
import HealthKit
import Observation
import UIKit

@MainActor @Observable final class AppModel {
  static let shared = AppModel()
  var preferences = Preferences.load()
  var overview: [HealthType: [DayValue]] = [:]
  var overviewLoading = false
  var notice: String?
  var syncing = false
  var serverStatus: ServerStatus?
  var selectedTab = 0
  var connectionSheet = false
  var incomingInvitation: ConnectionInvitation?
  var consentSheet = false
  let health = HealthStore()
  private var observers: [HealthType: HKObserverQuery] = [:]
  private var syncTask: Task<Void, Never>?
  private var generation = 0
  private var maintenance = false
  private var retryTask: Task<Void, Never>?
  private var retryAttempt = 0
  private var nextTypeIndex = 0
  private var syncQueue = SyncQueue()
  private var automaticTask: Task<Void, Never>?
  private var overviewTask: Task<Void, Never>?

  var isUITesting: Bool {
    #if DEBUG && targetEnvironment(simulator)
      ProcessInfo.processInfo.arguments.contains("--ui-test")
    #else
      false
    #endif
  }
  init() {
    // Raw anchors from v1 cannot prove the new hourly representation was uploaded.
    if preferences.hourlyFormatVersion < 1 {
      for type in [HealthType.heartRate, .steps] {
        UserDefaults.standard.removeObject(forKey: "anchor.\(type.rawValue)")
        preferences.progress.removeValue(forKey: type.rawValue)
      }
      preferences.hourlyResume = [:]
      preferences.hourlyFormatVersion = 1
      if !isUITesting { preferences.save() }
    }
    if CameraDiagnostics.enabled {
      selectedTab = 2
      connectionSheet = true
      CameraDiagnostics.record("diagnostic_launch")
    }
    #if DEBUG && targetEnvironment(simulator)
      let args = ProcessInfo.processInfo.arguments
      if args.contains("--ui-test") {
        preferences = Preferences()
        preferences.onboarded = !args.contains("--ui-intro")
        if args.contains("--ui-pair") {
          preferences.onboarded = false
          let payload = try! JSONSerialization.data(withJSONObject: [
            "v": 1, "server": "https://example.invalid", "code": String(repeating: "a", count: 64),
          ])
          incomingInvitation = try? ConnectionInvitation.parse(
            "healthbridge://connect#" + payload.base64EncodedString())
        }
        if args.contains("--ui-agent") {
          preferences.server = "https://example.invalid"
          selectedTab = 2
          try? Keychain.save("synthetic-writer-test")
          try? Keychain.deleteMCP(for: URL(string: preferences.server)!)
        }
        if args.contains("--ui-fixtures") {
          for type in HealthType.allCases {
            overview[type] = (0..<30).map { index in
              let day = Calendar.current.date(
                byAdding: .day, value: index - 29, to: Calendar.current.startOfDay(for: Date()))!
              let value: Double =
                type == .sleep
                ? 6.5 + Double(index % 4) / 3
                : type == .steps ? Double(4000 + index * 103) : Double(50 + index % 15)
              return DayValue(date: day, value: value)
            }
          }
        }
        if args.contains("--ui-failure") || args.contains("--ui-lock")
          || args.contains("--ui-progress") || args.contains("--ui-paused")
        {
          preferences.server = "https://example.invalid"
          preferences.consentDate = args.contains("--ui-paused") ? nil : Date()
          selectedTab = 1
          if args.contains("--ui-failure") { notice = "本次尚未完成，请稍后重试同步" }
          if args.contains("--ui-lock") { notice = "iPhone 锁定时无法读取健康数据，解锁后继续" }
          if args.contains("--ui-progress") {
            syncing = true
            preferences.lastTrigger = SyncTrigger.healthUpdate.rawValue
          }
        }
      }
    #endif
  }

  var statusText: String {
    if !preferences.canSync {
      return preferences.consentDate == nil && !preferences.server.isEmpty
        ? "同步已暂停 · 已撤回共享" : "本机模式 · 未上传"
    }
    if preferences.authorizationPending { return "等待完成健康授权" }
    if syncing { return "正在同步健康数据" }
    if let notice { return notice }
    if let date = preferences.progress.values.compactMap(\.lastSuccess).max() {
      return "上次同步 \(date.formatted(.relative(presentation: .named)))"
    }
    return "等待首次同步"
  }
  func save() { if !isUITesting { preferences.save() } }
  func api() throws -> ServerAPI {
    ServerAPI(base: try ServerAPI.normalizedURL(preferences.server), token: try Keychain.read())
  }
  func connect(url: URL, token: String, status: ServerStatus, mcpToken: String? = nil) async throws
  {
    await stopSync()
    if let mcpToken { try Keychain.saveMCP(mcpToken, for: url) }
    let tokenChanged = (try? Keychain.read()) != token
    try Keychain.save(token)
    let changed =
      preferences.server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      != url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    preferences.server = url.absoluteString
    if changed {
      preferences.consentDate = nil
    }
    if changed || tokenChanged {
      resetAnchors()
      preferences.progress = [:]
    }
    serverStatus = status
    save()
    try? Keychain.clearPendingPair(matching: token)
  }
  func grantConsent() {
    preferences.authorizationPending = true
    preferences.consentDate = Date()
    save()
  }
  func revokeConsent() async {
    preferences.consentDate = nil
    save()
    await stopSync()
    await configureObservers()
    notice = nil
  }
  func disconnect() async {
    preferences.consentDate = nil
    save()
    await stopSync()
    await configureObservers()
    if let url = try? ServerAPI.normalizedURL(preferences.server) {
      try? Keychain.deleteMCP(for: url)
    }
    Keychain.delete()
    preferences.server = ""
    resetAnchors()
    preferences.progress = [:]
    serverStatus = nil
    notice = nil
    save()
  }
  func authorize() async {
    preferences.authorizationPending = true
    save()
    await stopSync()
    do {
      try await health.authorize(preferences.selected)
      preferences.onboarded = true
      preferences.authorizationPending = false
      save()
      await configureObservers()
      refreshOverview()
      startSync(trigger: .authorization)
    } catch { notice = "无法打开健康授权，请稍后重试。" }
  }
  func setType(_ type: HealthType, enabled: Bool) async {
    let previous = preferences.selected
    if enabled { preferences.authorizationPending = true }
    if enabled { preferences.selected.insert(type) } else { preferences.selected.remove(type) }
    save()
    await stopSync()
    if enabled {
      do { try await health.authorize([type]) } catch {
        preferences.selected = previous
        notice = "请在系统设置中检查健康访问权限。"
      }
      preferences.authorizationPending = false
      save()
    }
    await configureObservers()
    refreshOverview()
    startSync(types: [type], trigger: .settings)
  }
  func setRange(_ days: Int) async {
    guard days != preferences.days else { return }
    let expands = days == 0 || (preferences.days != 0 && days > preferences.days)
    await stopSync()
    preferences.days = days
    if expands { resetAnchors() }
    save()
    startSync(trigger: .settings)
  }
  func setFrequency(_ frequency: SyncFrequency) async {
    preferences.frequency = frequency
    save()
    automaticTask?.cancel()
    if frequency == .manual { preferences.pendingAutomatic = []; await stopSync() }
    else { scheduleAutomatic() }
    save()
    await configureObservers()
  }
  func resetAnchors() {
    for type in HealthType.allCases {
      UserDefaults.standard.removeObject(forKey: "anchor.\(type.rawValue)")
    }
    preferences.since = [:]
    preferences.hourlyResume = [:]
  }
  func deleteServerData() async throws {
    guard !maintenance else { return }
    maintenance = true
    defer {
      maintenance = false
      startSync()
    }
    await stopSync()
    try await api().deleteAll()
    resetAnchors()
    // A fixed lower bound prevents old history returning after an intentional purge.
    for type in HealthType.allCases {
      preferences.since[type.rawValue] = Date()
      preferences.progress[type.rawValue] = .init(message: "服务器数据已删除，之后只同步新数据")
    }
    save()
    serverStatus = try await api().ping()
    startSync()
  }
  func resumeAfterUnlock() {
    guard preferences.frequency != .manual,
      retryAttempt > 0 || notice != nil || !preferences.hourlyResume.isEmpty else { return }
    startSync(trigger: .unlocked)
  }
  private func scheduleAutomatic() {
    automaticTask?.cancel()
    guard preferences.frequency != .manual, !preferences.pendingAutomatic.isEmpty,
      preferences.canUpload else { return }
    let due = preferences.frequency.nextAllowed(after: preferences.lastAutomatic)
    if due <= Date() {
      let types = preferences.pendingAutomatic
      preferences.pendingAutomatic = []
      preferences.lastAutomatic = Date()
      save()
      startSync(types: types, trigger: .healthUpdate, automaticReady: true)
    } else if UIApplication.shared.applicationState == .active {
      automaticTask = Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0, due.timeIntervalSinceNow) * 1_000_000_000))
        guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
        scheduleAutomatic()
      }
    }
    // In background, pending types persist until the next system wake. No timer is promised.
  }
  func foreground() {
    scheduleAutomatic()
    refreshOverview()
  }
  func refreshOverview() {
    guard !isUITesting else { return }
    overviewTask?.cancel()
    overviewTask = Task {
      overviewLoading = true
      defer { overviewLoading = false }
      for type in HealthType.allCases where preferences.selected.contains(type) {
        do {
          let values = try await health.overview(type)
          try Task.checkCancellation()
          overview[type] = values
        } catch is CancellationError { return } catch {
          overview[type] = []
          if !UIApplication.shared.isProtectedDataAvailable { notice = "等待解锁后读取健康数据" }
        }
      }
    }
  }
  // Called synchronously from didFinishLaunching, before HealthKit delivers background events.
  func registerLaunchObservers() {
    guard !isUITesting else { return }
    guard preferences.canUpload, preferences.frequency != .manual, HKHealthStore.isHealthDataAvailable() else { return }
    for type in preferences.selected { register(type) }
  }
  private func register(_ type: HealthType) {
    guard observers[type] == nil else { return }
    let query = HKObserverQuery(sampleType: type.hkType, predicate: nil) { _, completion, error in
      Task { @MainActor in
        defer { completion() }
        if error != nil {
          self.notice = "等待解锁后继续，或手动重试同步"
          return
        }
        self.startSync(types: [type], trigger: .healthUpdate)
        // Notifications received during an upload stay queued and drain before completion.
        while let task = self.syncTask { await task.value }
      }
    }
    observers[type] = query
    health.store.execute(query)
  }
  func configureObservers() async {
    for (type, query) in observers
    where !preferences.canSync || preferences.frequency == .manual || !preferences.selected.contains(type) {
      health.store.stop(query)
      observers.removeValue(forKey: type)
      try? await health.store.disableBackgroundDelivery(for: type.hkType)
    }
    guard preferences.canSync, preferences.frequency != .manual else {
      try? await health.store.disableAllBackgroundDelivery()
      return
    }
    for type in preferences.selected {
      register(type)
      do {
        try await health.store.enableBackgroundDelivery(for: type.hkType, frequency: preferences.frequency.healthKitFrequency)
      } catch { notice = "后台交付暂不可用，请手动同步。" }
    }
  }
  func stopSync() async {
    generation += 1
    syncQueue.clear()
    retryTask?.cancel()
    automaticTask?.cancel()
    retryTask = nil
    let task = syncTask
    syncTask?.cancel()
    await task?.value
    syncTask = nil
    syncing = false
  }
  func startSync(types: Set<HealthType>? = nil, trigger: SyncTrigger = .manual, automaticReady: Bool = false) {
    guard !isUITesting, !maintenance, preferences.canUpload else { return }
    if trigger == .healthUpdate && !automaticReady {
      preferences.pendingAutomatic.formUnion((types ?? preferences.selected).intersection(preferences.selected))
      save()
      scheduleAutomatic()
      return
    }
    if trigger == .manual {
      preferences.pendingAutomatic.subtract(types ?? preferences.selected)
      automaticTask?.cancel()
    }
    syncQueue.enqueue(types ?? preferences.selected, selected: preferences.selected)
    preferences.lastTrigger = trigger.rawValue
    save()
    guard syncTask == nil, !syncQueue.types.isEmpty else { return }
    let epoch = generation
    syncTask = Task {
      syncing = true
      var backgroundID = UIBackgroundTaskIdentifier.invalid
      backgroundID = UIApplication.shared.beginBackgroundTask(withName: "HealthBridge sync") {
        self.syncTask?.cancel()
      }
      defer {
        if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
        syncing = false
        syncTask = nil
        if !syncQueue.types.isEmpty && !Task.isCancelled && generation == epoch {
          startSync(types: [], trigger: .healthUpdate, automaticReady: true)
        }
      }
      // A single executor turn merges simultaneous HealthKit notifications without a timer.
      await Task.yield()
      let requested = syncQueue.take()
      var unfinished = requested
      let deadline = Date().addingTimeInterval(25)
      var shouldRetry = false
      var hadFailure = false
      let all = HealthType.allCases
      let ordered = Array(all[nextTypeIndex...]) + Array(all[..<nextTypeIndex])
      for type in ordered where requested.contains(type) && preferences.selected.contains(type) {
        guard valid(epoch, type), Date() < deadline else { break }
        do {
          let api = try api()
          let status = try await api.ping()
          guard status.hourly_schema_version == 1 else { throw BridgeError.incompatible }
          let since =
            preferences.since[type.rawValue]
            ?? (preferences.days == 0
              ? Date(timeIntervalSince1970: 0)
              : Calendar.current.date(byAdding: .day, value: -preferences.days, to: Date())!)
          preferences.since[type.rawValue] = since
          save()
          var anchor = loadAnchor(type)
          repeat {
            guard valid(epoch, type) else { break }
            preferences.progress[type.rawValue, default: .init()].message = "正在读取并上传"
            let page = try await health.page(type, since: since, anchor: anchor)
            try Task.checkCancellation()
            guard valid(epoch, type) else { break }
            // One HealthKit page is one server transaction; persist only its acknowledged anchor.
            let data: Data
            if type == .heartRate || type == .steps {
              // Raw measurements remain local. Recompute only hours touched by this delta.
              // A deletion has no timestamp, so conservatively replace the selected history.
              let windows = HourlyWindow.affected(added: page.added, deleted: page.deleted,
                since: since, now: Date())
              let ids = (page.added.map(\.uuid) + page.deleted.map { "deleted:" + $0 }).sorted().joined(separator: ",")
              let fingerprint = SHA256.hash(data: Data(ids.utf8)).map { String(format: "%02x", $0) }.joined()
              data = try await HourlyTransfer.acknowledgedAnchor(
                page: page, type: type, windows: windows, fingerprint: fingerprint,
                resume: preferences.hourlyResume[type.rawValue],
                allowed: { self.valid(epoch, type) },
                read: { window in
                  try await self.health.hourly(type, since: window.start, until: window.end, notBefore: since)
                }, upload: api.upload,
                checkpoint: { resume in
                  self.preferences.hourlyResume[type.rawValue] = resume
                  self.save()
                }, didCommitWindow: {
                  if Date() >= deadline { throw SyncBudgetExpired() }
                })
            } else {
              data = try await PageTransfer.acknowledgedAnchor(
                page: page, type: type, allowed: { self.valid(epoch, type) }, upload: api.upload)
            }
            UserDefaults.standard.set(data, forKey: "anchor.\(type.rawValue)")
            anchor = page.anchor
            nextTypeIndex = (all.firstIndex(of: type)! + 1) % all.count
            preferences.progress[type.rawValue, default: .init()].uploaded += page.added.count
            preferences.progress[type.rawValue, default: .init()].lastSuccess = Date()
            preferences.progress[type.rawValue, default: .init()].message =
              page.count == 0 ? "已检查最新变化" : "已确认上传"
            save()
            notice = nil
            if page.count == 0 { unfinished.remove(type); break }
            if Date() >= deadline {
              shouldRetry = true
              break
            }
          } while valid(epoch, type)
        } catch is SyncBudgetExpired {
          shouldRetry = true
          break
        } catch is CancellationError { break } catch {
          guard valid(epoch, type) else { break }
          let message: String
          if let error = error as? BridgeError {
            message = error.localizedDescription
          } else if !UIApplication.shared.isProtectedDataAvailable {
            message = "iPhone 锁定时无法读取健康数据，解锁后继续"
          } else {
            message = "本次尚未完成，请稍后重试同步"
          }
          preferences.progress[type.rawValue, default: .init()].message = message
          notice = message
          save()
          shouldRetry = true
          hadFailure = true
        }
      }
      if !unfinished.isEmpty { shouldRetry = true }
      if shouldRetry && preferences.canSync && !Task.isCancelled {
        retryAttempt = hadFailure ? min(retryAttempt + 1, 5) : 0
        let delay = UInt64(hadFailure ? min(300, 5 * (1 << retryAttempt)) : 2)
        retryTask?.cancel()
        retryTask = Task {
          try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
          guard !Task.isCancelled else { return }
          startSync(types: unfinished, trigger: .retry)
        }
      } else {
        retryAttempt = 0
      }
    }
  }
  private func valid(_ epoch: Int, _ type: HealthType) -> Bool {
    !Task.isCancelled && generation == epoch && preferences.canUpload
      && preferences.selected.contains(type)
  }
  private func loadAnchor(_ type: HealthType) -> HKQueryAnchor? {
    guard let data = UserDefaults.standard.data(forKey: "anchor.\(type.rawValue)") else {
      return nil
    }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
  }
}

private struct SyncBudgetExpired: Error {}

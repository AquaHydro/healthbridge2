import Charts
import SwiftUI

struct MainView: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    @Bindable var model = model
    TabView(selection: $model.selectedTab) {
      NavigationStack { OverviewView() }.tabItem { Label("概览", systemImage: "heart.text.square") }
        .tag(0)
      NavigationStack { SyncView() }.tabItem {
        Label("同步", systemImage: "arrow.triangle.2.circlepath")
      }.tag(1)
      NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }.tag(2)
    }.sheet(isPresented: $model.connectionSheet) {
      NavigationStack {
        QuickConnectView().toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { model.connectionSheet = false }
          }
        }
      }
    }
    .sheet(isPresented: $model.consentSheet) {
      NavigationStack {
        ConsentView().toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { model.consentSheet = false }
          }
        }
      }
    }
    .task { model.foreground() }
  }
}
struct OverviewView: View {
  @Environment(\.dynamicTypeSize) private var textSize
  @Environment(AppModel.self) private var model
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Button {
          model.selectedTab = 1
        } label: {
          HStack {
            Image(systemName: model.preferences.canSync ? "arrow.triangle.2.circlepath" : "iphone")
            Text(model.statusText).font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right").font(.caption)
          }.padding().background(
            Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
        if model.overviewLoading {
          HStack {
            ProgressView()
            Text("正在读取本机健康数据").font(.subheadline).foregroundStyle(.secondary)
          }
        }
        ForEach(HealthType.allCases.filter { model.preferences.selected.contains($0) }) { type in
          NavigationLink {
            HealthDetailView(type: type)
          } label: {
            card(type)
          }.buttonStyle(.plain)
        }
        if model.preferences.selected.isEmpty {
          ContentUnavailableView(
            "尚未选择数据类型", systemImage: "heart", description: Text("在设置中选择你想查看的数据。"))
        }
        Text("概览来自本机 Apple 健康。后台更新由 iOS 调度，Apple Watch 数据需先同步到 iPhone。").font(.footnote)
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(
            .vertical)
      }.padding(16)
    }.background(Color(.systemGroupedBackground)).navigationTitle("概览").refreshable {
      model.foreground()
    }
  }
  private func card(_ type: HealthType) -> some View {
    let values = Array((model.overview[type] ?? []).suffix(7))
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: type.icon).foregroundStyle(type.color)
        Text(type.title).font(.headline)
        Spacer()
        if !textSize.isAccessibilitySize { Text("最近记录").font(.caption).foregroundStyle(.secondary) }
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
      }
      if let last = values.last {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(last.value, format: .number.precision(.fractionLength(type == .sleep ? 1 : 0))).font(
            .system(.largeTitle, design: .rounded).bold())
          Text(type.displayUnit).foregroundStyle(.secondary)
        }
        Text(last.date, format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary)
        if !textSize.isAccessibilitySize {
          HealthChart(type: type, values: values).frame(height: 105).allowsHitTesting(false)
        } else {
          Text("查看详细数据").font(.footnote).foregroundStyle(.secondary)
        }
      } else {
        Text("暂无可读取的数据").font(.title3.weight(.semibold)).padding(.top, 6)
        Text("请确认 Apple 健康中有记录，并检查 HealthBridge 的读取权限。").font(.subheadline).foregroundStyle(
          .secondary)
      }
    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
      Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
  }
}
struct HealthChart: View {
  let type: HealthType
  let values: [DayValue]
  @State private var selected: Date?
  var body: some View {
    Chart(values) { day in
      if type == .steps || type == .sleep {
        BarMark(x: .value("日期", day.date, unit: .day), y: .value(type.displayUnit, day.value))
          .foregroundStyle(type.color).cornerRadius(4)
      } else {
        LineMark(x: .value("日期", day.date), y: .value(type.displayUnit, day.value)).foregroundStyle(
          type.color
        ).lineStyle(StrokeStyle(lineWidth: 2))
        PointMark(x: .value("日期", day.date), y: .value(type.displayUnit, day.value))
          .foregroundStyle(type.color).symbolSize(30)
      }
      if let selected, Calendar.current.isDate(selected, inSameDayAs: day.date) {
        RuleMark(x: .value("日期", day.date)).foregroundStyle(.secondary).annotation(position: .top) {
          Text("\(day.value.formatted(.number.precision(.fractionLength(1)))) \(type.displayUnit)")
            .font(.caption).padding(5).background(
              .regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
      }
    }.chartXSelection(value: $selected).chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
    }.chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisValueLabel(format: .dateTime.month().day())
      }
    }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).accessibilityLabel("\(type.title)每日趋势")
  }
}
struct HealthDetailView: View {
  @Environment(AppModel.self) private var model
  let type: HealthType
  @State private var days = 7
  var body: some View {
    let start = Calendar.current.date(
      byAdding: .day, value: 1 - days, to: Calendar.current.startOfDay(for: Date()))!
    let values = (model.overview[type] ?? []).filter { $0.date >= start }
    List {
      Picker("时间范围", selection: $days) {
        Text("7 天").tag(7)
        Text("30 天").tag(30)
      }.pickerStyle(.segmented)
      if values.isEmpty {
        ContentUnavailableView(
          "暂无数据", systemImage: type.icon,
          description: Text("在系统设置中检查健康数据访问权限，或在 Apple 健康中查看是否已有记录。"))
      } else {
        HealthChart(type: type, values: values).frame(height: 230).padding(.vertical)
        Section("每日数值 · \(type.displayUnit)") {
          ForEach(values.reversed()) { day in
            HStack {
              Text(day.date, format: .dateTime.year().month().day())
              Spacer()
              Text(day.value, format: .number.precision(.fractionLength(type == .sleep ? 1 : 0)))
            }
          }
        }
      }
      Section("数据来源") {
        Text(
          type == .sleep
            ? "本机 Apple 健康；每晚优先采用有睡眠阶段的单一来源，重叠区间合并。"
            : type == .steps
              ? "本机 HealthKit 统计。服务器保存步数的小时汇总。" : "本机 HealthKit 每日平均值。心率变异性为 SDNN。"
        ).foregroundStyle(.secondary)
      }
    }.navigationTitle(type.title)
  }
}
struct SyncView: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    List {
      Section {
        Label(
          model.statusText,
          systemImage: model.syncing
            ? "arrow.triangle.2.circlepath"
            : model.preferences.canSync
              ? (model.notice == nil ? "checkmark.circle" : "exclamationmark.triangle")
              : "pause.circle")
        if let trigger = model.preferences.lastTrigger {
          LabeledContent("最近触发原因", value: trigger).font(.subheadline)
        }
        if model.syncing { ProgressView().frame(maxWidth: .infinity) }
        if model.preferences.canSync {
          Button(
            model.preferences.authorizationPending ? "继续健康授权" : model.syncing ? "正在同步" : "立即同步"
          ) {
            if model.preferences.authorizationPending {
              Task { await model.authorize() }
            } else {
              model.startSync()
            }
          }.disabled(model.syncing)
        } else {
          Button(model.preferences.server.isEmpty ? "连接服务器" : "重新同意共享") {
            if model.preferences.server.isEmpty {
              model.connectionSheet = true
            } else {
              model.consentSheet = true
            }
          }
        }
      }
      Section("各类型进度") {
        ForEach(HealthType.allCases.filter { model.preferences.selected.contains($0) }) { type in
          let progress = model.preferences.progress[type.rawValue] ?? TypeProgress()
          VStack(alignment: .leading, spacing: 8) {
            Label(type.title, systemImage: type.icon).font(.headline).foregroundStyle(type.color)
            Text(model.preferences.canSync ? progress.message : "仅在本机查看，不上传").font(.subheadline)
            if model.preferences.canSync {
              Text("累计处理 \(progress.uploaded) 条").font(.caption)
                .foregroundStyle(.secondary)
              if let date = progress.lastSuccess {
                Text("最后完成 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }.padding(.vertical, 5)
        }
      }
      Section {
        DisclosureGroup("同步说明") {
          Text("可以离开此页面。未完成的同步会在系统允许时重试，也可手动同步。")
          Text("后台更新由 iOS 调度。锁屏期间可能需要等待解锁；上划关闭 App 后，请重新打开。")
        }
      }.font(.footnote).foregroundStyle(.secondary)
    }.navigationTitle("同步")
  }
}
struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var revoke = false
  @State private var purge = false
  @State private var disconnect = false
  @State private var busy = false
  @State private var message: String?
  var body: some View {
    List {
      Section("连接") {
        Button {
          model.connectionSheet = true
        } label: {
          LabeledContent("服务器", value: model.preferences.server.isEmpty ? "未连接" : "已配置")
        }
        NavigationLink("连接 AI Agent") { AgentHelpView() }
      }
      Section("健康数据") {
        NavigationLink("数据类型") { SettingsTypesView() }
        Picker("期望同步频率", selection: Binding(
          get: { model.preferences.frequency },
          set: { frequency in Task { await model.setFrequency(frequency) } }
        )) {
          ForEach(SyncFrequency.allCases) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("sync-frequency")
        Text("更新会按所选间隔合并。后台等待下次系统唤醒，可能晚于期望时间；仅手动会关闭自动同步。立即同步不受频率限制。")
          .font(.footnote).foregroundStyle(.secondary)
        Picker(
          "首次同步范围",
          selection: Binding(
            get: { model.preferences.days }, set: { days in Task { await model.setRange(days) } })
        ) { ForEach([7, 30, 90, 365, 0], id: \.self) { Text($0 == 0 ? "全部" : "\($0) 天").tag($0) } }
        Text("扩大范围会补传历史数据；缩小范围不删除服务器数据。").font(.footnote).foregroundStyle(.secondary)
      }
      Section("数据共享") {
        if let date = model.preferences.consentDate {
          LabeledContent("同意时间", value: date.formatted(date: .abbreviated, time: .shortened))
          NavigationLink("查看共享说明") {
            ScrollView { Text(sharingText).padding(24) }.navigationTitle("共享说明")
          }
          Button("撤回同意", role: .destructive) { revoke = true }
        } else {
          Text("尚未同意共享，健康数据只在本机查看。").foregroundStyle(.secondary)
          if !model.preferences.server.isEmpty { Button("重新同意") { model.consentSheet = true } }
        }
      }
      if !model.preferences.server.isEmpty {
        Section {
          Button("删除服务器全部数据", role: .destructive) { purge = true }.disabled(busy)
          Button("断开连接", role: .destructive) { disconnect = true }.disabled(busy)
        } footer: {
          Text("删除后保持连接，仅上传之后的新数据。断开连接会清除本机 Token、地址和同步位置，服务器数据保留。")
        }
      }
      Section {
        NavigationLink("隐私说明") { PrivacyView() }
        LabeledContent("HealthBridge", value: "0.1.0")
        if busy { ProgressView() }
        if let message { Text(message).foregroundStyle(.secondary) }
      }
    }.navigationTitle("设置")
      .confirmationDialog(
        "撤回后停止上传，已上传的数据仍可被 AI Agent 查询。", isPresented: $revoke, titleVisibility: .visible
      ) { Button("撤回同意", role: .destructive) { Task { await model.revokeConsent() } } }
      .confirmationDialog(
        "删除你服务器上的全部健康样本？此操作无法从 App 撤销。", isPresented: $purge, titleVisibility: .visible
      ) { Button("删除全部服务器数据", role: .destructive) { Task { await deleteData() } } }
      .confirmationDialog("断开后停止上传并清除本机连接配置。", isPresented: $disconnect, titleVisibility: .visible)
    {
      Button("断开并保留服务器数据", role: .destructive) { Task { await model.disconnect() } }
      Button("删除服务器数据并断开", role: .destructive) {
        Task {
          busy = true
          defer { busy = false }
          do {
            try await model.deleteServerData()
            await model.disconnect()
          } catch { message = "删除尚未完成，连接配置已保留，请重试。" }
        }
      }
    }
  }
  private func deleteData() async {
    busy = true
    defer { busy = false }
    do {
      try await model.deleteServerData()
      message = "服务器数据已清空。"
    } catch { message = (error as? BridgeError)?.localizedDescription ?? "暂时无法删除，请检查网络后重试。" }
  }
}
struct SettingsTypesView: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    Form {
      ForEach(HealthType.allCases) { type in
        Toggle(
          isOn: Binding(
            get: { model.preferences.selected.contains(type) },
            set: { value in Task { await model.setType(type, enabled: value) } })
        ) { Label(type.title, systemImage: type.icon).foregroundStyle(type.color) }
      }
      Text("关闭某类数据会停止上传；服务器已有数据保留。新增类型会再次请求系统读取授权。").font(.footnote).foregroundStyle(.secondary)
    }.navigationTitle("数据类型")
  }
}

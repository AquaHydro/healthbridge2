import SwiftUI

let sharingText =
  "你选择的步数和心率仅以小时汇总上传，首小时只包含共享起点之后的数据，跨越共享起点的步数样本可能不计入；睡眠、静息心率和心率变异性保留样本记录。数据将发送到下方配置的服务器，保存在你自己的 Cloudflare 账号中。持有 MCP 只读 Token 的 AI Agent 可以查询已上传数据。你接入的 AI 服务可能按其自身政策处理这些数据。HealthBridge 不向开发者的服务器发送健康数据。你可随时撤回共享，停止之后的上传；已上传的数据仍可被 Agent 读取，需另行删除服务器数据或轮换 MCP Token。"

struct OnboardingView: View {
  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Spacer()
        Image(systemName: "heart.text.clipboard.fill").font(.system(size: 64)).foregroundStyle(
          .blue)
        Text("让健康数据连上 AI").font(.largeTitle.bold()).multilineTextAlignment(.center)
        Text("数据存放在你的 Cloudflare。").foregroundStyle(.secondary)
        Spacer()
        NavigationLink("开始连接") { QuickConnectView(onboarding: true) }.buttonStyle(PrimaryButton())
        NavigationLink("仅在本机查看") { TypeSelectionView(onboarding: true) }.padding(.bottom, 24)
      }.padding(24).background(Color(.systemGroupedBackground))
    }
  }
}
struct PrimaryButton: ButtonStyle {
  @Environment(\.isEnabled) var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
      .foregroundStyle(.white).background(
        enabled ? Color.blue : Color.gray, in: RoundedRectangle(cornerRadius: 14)
      ).opacity(configuration.isPressed ? 0.75 : 1)
  }
}
struct ConnectionView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  var onboarding = false
  @State private var address = ""
  @State private var token = ""
  @State private var mcpToken = ""
  private enum Field: Hashable { case address, ingest }
  @FocusState private var editing: Field?
  @State private var showGeneration = false
  @State private var showReadToken = false
  @State private var loaded = false
  @State private var result: ServerStatus?
  @State private var message: String?
  @State private var busy = false
  @State private var advance = false
  var body: some View {
    Form {
      Section { Text("连接不会上传健康数据。").foregroundStyle(.secondary) }
      Section {
        DisclosureGroup("高级配置") { Button("生成新 Token") { showGeneration = true } }
        Text("填写已有服务器的凭据。").font(.footnote)
          .foregroundStyle(.secondary)
      }
      Section("服务器") {
        TextField("https://你的服务.workers.dev", text: $address).textInputAutocapitalization(.never)
          .autocorrectionDisabled().keyboardType(.URL).focused($editing, equals: .address)
          .accessibilityIdentifier(
            "serverURL")
        SecureField("INGEST_TOKEN", text: $token).textInputAutocapitalization(.never)
          .autocorrectionDisabled().textContentType(.init(rawValue: "")).focused(
            $editing, equals: .ingest
          ).accessibilityIdentifier("ingestToken")
        Button {
          if let value = UIPasteboard.general.string { token = value }
        } label: {
          Label("粘贴 Token", systemImage: "doc.on.clipboard")
        }
      }
      Section {
        Button(mcpToken.isEmpty ? "添加只读 Token（选填）" : "更换只读 Token") { showReadToken = true }
        if !mcpToken.isEmpty {
          Label("只读 Token 已填写，等待连接验证", systemImage: "key")
          Button("暂不填写只读 Token") { mcpToken = "" }
        }
      } header: {
        Text("Agent 只读 Token")
      } footer: {
        Text("填写后会同时验证并保存，之后可在“连接 AI Agent”页快捷复制。也可稍后导入。")
      }
      Section {
        Button {
          Task { await test() }
        } label: {
          HStack {
            Text(busy ? "正在测试连接" : "测试连接")
            Spacer()
            if busy { ProgressView() }
          }
        }.disabled(busy || address.isEmpty || token.isEmpty)
        if let result {
          Label(
            "连接成功 · v\(result.version) · \(result.counts.values.reduce(0,+)) 条样本",
            systemImage: "checkmark.circle.fill"
          ).foregroundStyle(.green)
        }
        if let message { Label(message, systemImage: "info.circle").foregroundStyle(.secondary) }
      }
      Section {
        Button("继续") { Task { await next() } }.disabled(result == nil || busy)
        NavigationLink("如何部署服务器") { DeploymentHelpView() }
      } footer: {
        Text("凭据仅保存在本机钥匙串。")
      }
    }.navigationTitle("连接服务器")
      .onAppear {
        guard !loaded else { return }
        loaded = true
        address = model.preferences.server
        if !address.isEmpty {
          token = (try? Keychain.read()) ?? ""
          if let url = try? ServerAPI.normalizedURL(address) {
            mcpToken = (try? Keychain.readMCP(for: url)) ?? ""
          }
        }
      }
      .onChange(of: address) { _, _ in result = nil }
      .onChange(of: token) { _, _ in result = nil }
      .onChange(of: mcpToken) { _, _ in result = nil }
      .sheet(isPresented: $showGeneration) {
        TokenSetupView { pair in
          token = pair.ingest
          mcpToken = pair.mcp
          result = nil
        }
      }
      .sheet(isPresented: $showReadToken) {
        ReadTokenInputView(initial: mcpToken) {
          mcpToken = $0
          result = nil
        }
      }
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("完成") { editing = nil }
        }
      }
      .navigationDestination(isPresented: $advance) { ConsentView(onboarding: onboarding) }
      .toolbar { if onboarding { NavigationLink("暂不连接") { TypeSelectionView(onboarding: true) } } }
  }
  private func test() async {
    busy = true
    result = nil
    message = nil
    let submittedAddress = address
    let submittedToken = token
    let submittedMCP = mcpToken
    defer { busy = false }
    do {
      let writeToken = try CredentialRules.token(submittedToken)
      let readToken = submittedMCP.isEmpty ? nil : try CredentialRules.token(submittedMCP)
      if let readToken, readToken == writeToken { throw CredentialError.sameToken }
      let base = try ServerAPI.normalizedURL(submittedAddress)
      let status = try await ServerAPI(
        base: base, token: writeToken
      ).ping()
      if let readToken { try await ServerAPI(base: base, token: readToken).verifyMCP() }
      if address == submittedAddress && token == submittedToken && mcpToken == submittedMCP {
        result = status
      }
    } catch { message = (error as? LocalizedError)?.errorDescription ?? "暂时无法连接，请检查地址与网络后重试。" }
  }
  private func next() async {
    guard let result else { return }
    do {
      try await model.connect(
        url: ServerAPI.normalizedURL(address), token: CredentialRules.token(token), status: result,
        mcpToken: mcpToken.isEmpty ? nil : CredentialRules.token(mcpToken))
      if model.preferences.canSync && !onboarding {
        await model.configureObservers()
        model.startSync()
        dismiss()
      } else {
        advance = true
      }
    } catch { message = "无法保存连接，请解锁设备后重试。" }
  }
}
struct ConsentView: View {
  @Environment(AppModel.self) private var model
  var onboarding = false
  @State private var proceed = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Image(systemName: "lock.shield.fill").font(.system(size: 48)).foregroundStyle(.blue)
        Text("允许共享健康数据？").font(.largeTitle.bold())
        Text(model.preferences.server).font(.footnote.monospaced()).textSelection(.enabled)
        Text("步数和心率仅上传小时汇总，其他所选类型上传样本记录。数据会上传到此服务器，并可被你接入的 AI 服务读取。你可随时停止共享；已上传的数据需另行删除。").lineSpacing(4)
        NavigationLink("了解数据如何使用") {
          ScrollView { Text(sharingText).padding(24) }.navigationTitle("共享说明")
        }
        NavigationLink("阅读隐私说明") { PrivacyView() }
        Button("同意并继续") {
          model.grantConsent()
          proceed = true
        }.buttonStyle(PrimaryButton())
        Button("不同意，仅在本机查看") {
          Task {
            await model.disconnect()
            proceed = true
          }
        }.frame(maxWidth: .infinity)
      }.padding(24)
    }.background(Color(.systemGroupedBackground)).navigationTitle("数据共享同意")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $proceed) { TypeSelectionView(onboarding: onboarding) }
  }
}
struct TypeSelectionView: View {
  @Environment(AppModel.self) private var model
  var onboarding = false
  @State private var authorizing = false
  @State private var progress = false
  var body: some View {
    Form {
      Section("选择要读取的数据") {
        ForEach(HealthType.allCases) { type in
          Toggle(
            isOn: Binding(
              get: { model.preferences.selected.contains(type) },
              set: { value in
                if value {
                  model.preferences.selected.insert(type)
                } else {
                  model.preferences.selected.remove(type)
                }
                model.save()
              })
          ) { Label(type.title, systemImage: type.icon).foregroundStyle(type.color) }
        }
      }
      if model.preferences.canSync {
        Section("首次同步范围") {
          Picker(
            "时间范围",
            selection: Binding(
              get: { model.preferences.days },
              set: {
                let days = $0
                Task { await model.setRange(days) }
              })
          ) {
            ForEach([7, 30, 90, 365, 0], id: \.self) { Text($0 == 0 ? "全部" : "最近 \($0) 天").tag($0) }
          }
        }
      }
      Section {
        Text("下一步由 iOS 询问读取权限。HealthBridge 不写入或修改健康数据。iOS 不会告诉 App 你是否拒绝了某项读取，空数据也可能表示该范围尚无记录。")
          .foregroundStyle(.secondary)
        Button(authorizing ? "等待系统授权" : "允许读取健康数据") {
          Task {
            authorizing = true
            await model.authorize()
            authorizing = false
            if model.preferences.onboarded {
              model.connectionSheet = false
              model.consentSheet = false
              model.incomingInvitation = nil
              model.selectedTab = model.preferences.canSync ? 1 : 0
            }
          }
        }.disabled(authorizing || model.preferences.selected.isEmpty)
        if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
      }
    }.navigationTitle("数据类型与范围")
  }
}
struct PrivacyView: View {
  var body: some View {
    ScrollView {
      Text(
        "HealthBridge 只读取你选择的健康数据，不修改 Apple 健康记录。概览在本机计算。\n\n仅在明确同意后，步数和心率只上传小时汇总、小时区间与时区，不上传单条样本或来源；睡眠、静息心率和心率变异性上传所选样本、时间、时区与来源。数据通过 HTTPS 发往你配置的服务器。上传 Token 保存在本机钥匙串。应用无广告、分析或第三方追踪 SDK。\n\n持有 MCP Token 的客户端可以读取服务器数据。请仅交给可信赖的 AI 服务，并检查其隐私政策。\n\n撤回同意停止后续上传；已上传的数据仍保留。你可以删除服务器数据、断开连接，或在自己的 Cloudflare 账号中轮换 Token。Cloudflare 的备份保留遵循其服务政策，逻辑删除不代表立即清除所有备份。\n\n系统健康授权可在 iPhone 设置中的健康数据访问页面管理。"
      ).padding(24).lineSpacing(6)
    }.navigationTitle("隐私说明")
  }
}
struct DeploymentHelpView: View {
  var body: some View {
    List {
      Text("在自己的 Cloudflare 账号中创建专属 D1 数据库和 Worker，将 DB 绑定到数据库，应用仓库 server/migrations 下的迁移。")
      Text(
        "分别生成两个随机 Token，将 INGEST_TOKEN 和 MCP_TOKEN 保存为 Worker Secrets。两者不可相同。部署完成后，将 HTTPS 地址和写入 Token 填入 App。"
      )
      Text("完整命令、依赖版本、迁移与验证步骤见项目 README。请勿把 Token 放在 URL、聊天或 Git 中。")
    }.navigationTitle("部署服务器")
  }
}

import SwiftUI

struct AgentHelpView: View {
  @Environment(AppModel.self) private var model
  @State private var input = ""
  @State private var saved: String?
  @State private var savedOrigin: String?
  @State private var client = AgentClient.codex
  @State private var includeToken = true
  @State private var busy = false
  @State private var manageToken = false
  @State private var message: String?
  private var url: URL? { try? ServerAPI.normalizedURL(model.preferences.server) }
  private var canCopyToken: Bool {
    saved != nil && input == saved && !busy && url.map(CredentialRules.origin) == savedOrigin
  }
  var body: some View {
    Form {
      if let url {
        Section { Label(url.host ?? "已连接", systemImage: "lock.shield") }
        DisclosureGroup(
          "管理只读凭据",
          isExpanded: Binding(get: { saved == nil || manageToken }, set: { manageToken = $0 })
        ) {
          SecureField("MCP_TOKEN", text: $input).textContentType(.init(rawValue: ""))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled().accessibilityIdentifier("mcpToken")
          PasteButton(payloadType: String.self) { values in
            if let text = values.first { input = text }
          }
          Button {
            Task { await verify() }
          } label: {
            HStack {
              Text(busy ? "正在验证" : "验证并保存只读 Token")
              Spacer()
              if busy { ProgressView() }
            }
          }.disabled(busy || input.isEmpty).accessibilityIdentifier("saveMCPToken")
          if canCopyToken { Label("只读连接已验证", systemImage: "checkmark.shield") }
          Button("复制只读 Token") { if let saved { copy(saved, label: "只读 Token") } }.disabled(
            !canCopyToken)
        }
        Section("客户端配置") {
          Picker("客户端", selection: $client) {
            ForEach(AgentClient.allCases) { Text($0.rawValue).tag($0) }
          }
          Button(includeToken ? "复制完整配置" : "复制配置模板") {
            do {
              copy(
                try client.configuration(origin: url, token: includeToken ? saved : nil),
                label: includeToken ? "完整配置" : "配置模板")
            } catch { message = "无法生成配置，请检查 Token。" }
          }.disabled(includeToken && !canCopyToken).accessibilityIdentifier("copyAgentConfig")
          Text("只读配置，仅粘贴到你自己的客户端。").font(.footnote).foregroundStyle(.secondary)
          DisclosureGroup("更多选项") {
            Toggle("包含只读凭据", isOn: $includeToken)
            DisclosureGroup("查看配置") {
              Text((try? client.configuration(origin: url, token: nil)) ?? "").font(
                .caption.monospaced()
              ).textSelection(.enabled)
            }
            Button("复制 MCP 地址") {
              copy(url.appendingPathComponent("mcp").absoluteString, label: "地址")
            }
            Text("配置预览隐藏凭据，复制内容 2 分钟后过期。")
          }
        }
      } else {
        Section {
          ContentUnavailableView(
            "请先连接服务器", systemImage: "network", description: Text("连接后即可保存只读 Token 并复制 Agent 配置。"))
          Button("连接服务器") { model.connectionSheet = true }
        }
      }
      if let message {
        Section {
          Text(message).foregroundStyle(.secondary).accessibilityIdentifier("agentFeedback")
        }
      }

    }.navigationTitle("连接 AI Agent")
      .task(id: model.preferences.server) {
        saved = nil
        savedOrigin = nil
        input = ""
        message = nil
        if let url {
          do {
            saved = try Keychain.readMCP(for: url)
            savedOrigin = CredentialRules.origin(url)
            input = saved ?? ""
          } catch { message = "无法读取钥匙串，请解锁后重试。" }
        }
      }
  }
  private func verify() async {
    guard let url else { return }
    let submitted = input
    let server = model.preferences.server
    busy = true
    message = nil
    defer { busy = false }
    do {
      let token = try CredentialRules.token(submitted)
      guard token != (try Keychain.read()) else { throw CredentialError.sameToken }
      try await ServerAPI(base: url, token: token).verifyMCP()
      guard input == submitted && model.preferences.server == server else { return }
      try Keychain.saveMCP(token, for: url)
      input = token
      manageToken = true
      saved = token
      savedOrigin = CredentialRules.origin(url)
      message = "只读 Token 已验证并安全保存。"
    } catch { message = (error as? LocalizedError)?.errorDescription ?? "暂时无法验证，请检查网络后重试。" }
  }
  private func copy(_ value: String, label: String) {
    SecureCopy.text(value)
    message = "已复制\(label)，请在 2 分钟内粘贴。"
  }
}

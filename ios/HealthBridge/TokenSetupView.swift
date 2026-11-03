import SwiftUI

struct TokenSetupView: View {
  @Environment(\.dismiss) private var dismiss
  let use: (TokenPair) -> Void
  @State private var pair: TokenPair?
  @State private var message: String?
  @State private var regenerate = false
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label("在 iPhone 安全生成", systemImage: "key.horizontal")
          Text("生成两枚独立的随机 Token，并保存在本机钥匙串草稿中。现有连接保持不变。").foregroundStyle(.secondary)
        }
        Section {
          Button(pair == nil ? "生成两枚 Token" : "重新生成") {
            if pair == nil { generate() } else { regenerate = true }
          }.accessibilityIdentifier("generateTokens")
          if let pair {
            Label("两枚 Token 已生成", systemImage: "checkmark.shield")
            Button("复制 INGEST_TOKEN") { copy(pair.ingest, name: "写入 Token") }
            Button("复制 MCP_TOKEN") { copy(pair.mcp, name: "只读 Token") }
          }
        } footer: {
          Text("复制内容可通过通用剪贴板粘贴到 Mac，剪贴板有效期为 2 分钟。")
        }
        Section("配置到你的 Cloudflare") {
          Text(
            "1. 在专属 Worker 的 Settings → Variables and Secrets 中新增两个 Secret，名称分别为 INGEST_TOKEN 和 MCP_TOKEN。"
          )
          Text("2. 分别粘贴上方对应的 Token 并保存部署。")
          Text("3. 返回 App，使用这组 Token 测试连接。App 不会自动修改服务器 Secrets。")
          Button("使用这组 Token") {
            if let pair {
              use(pair)
              dismiss()
            }
          }.disabled(pair == nil).accessibilityIdentifier("useGeneratedTokens")
        }
        if let message {
          Section {
            Text(message).foregroundStyle(.secondary).accessibilityIdentifier("tokenFeedback")
          }
        }
      }.navigationTitle("生成新 Token").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .task { do { pair = try Keychain.pendingPair() } catch { message = "无法读取草稿，请解锁设备后重试。" } }
        .confirmationDialog(
          "重新生成会替换本机草稿。已复制到 Cloudflare 的旧值不会自动更改。", isPresented: $regenerate,
          titleVisibility: .visible
        ) { Button("替换草稿", role: .destructive) { generate() } }
    }
  }
  private func generate() {
    do {
      let generated = try TokenPair.generate()
      try Keychain.savePendingPair(generated)
      pair = generated
      message = "草稿已安全保存，关闭后可继续配置。"
    } catch { message = "生成或保存未完成，请解锁后重试。" }
  }
  private func copy(_ value: String, name: String) {
    SecureCopy.text(value)
    message = "已复制\(name)，请在 2 分钟内粘贴。"
  }
}

/// Keep independent credentials on separate forms so password AutoFill cannot treat
/// the second SecureField as a password-confirmation field and mirror the writer.
struct ReadTokenInputView: View {
  @Environment(\.dismiss) private var dismiss
  let initial: String
  let use: (String) -> Void
  @State private var value = ""
  @State private var message: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("MCP_TOKEN") {
          SecureField("只读 Token", text: $value).textContentType(.init(rawValue: ""))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          PasteButton(payloadType: String.self) { if let text = $0.first { value = text } }
        }
        Section {
          Button("使用此只读 Token") {
            do {
              use(try CredentialRules.token(value))
              dismiss()
            } catch { message = error.localizedDescription }
          }.disabled(value.isEmpty)
          Text("填写部署时的 MCP_TOKEN。稍后测试连接时会验证它，不能使用写入 Token 替代。").foregroundStyle(.secondary)
          if let message { Text(message).foregroundStyle(.secondary) }
        }
      }.navigationTitle("填写只读 Token").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear { value = initial }
    }
  }
}

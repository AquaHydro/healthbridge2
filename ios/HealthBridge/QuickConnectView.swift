import AVFoundation
import SwiftUI

struct QuickConnectView: View {
  @Environment(AppModel.self) private var model
  @State private var invitation: ConnectionInvitation?
  @State private var scanning = false
  @State private var busy = false
  @State private var advance = false
  @State private var message: String?
  let onboarding: Bool
  init(onboarding: Bool = false, invitation: ConnectionInvitation? = nil) {
    self.onboarding = onboarding
    _invitation = State(initialValue: invitation)
  }
  var body: some View {
    Form {
      if let invitation {
        Section {
          Label(invitation.server.host ?? "你的服务器", systemImage: "lock.shield")
          Button(busy ? "正在连接…" : "连接") { Task { await connect(invitation) } }.disabled(busy)
            .accessibilityIdentifier("redeemConnection")
        } footer: {
          Text("连接不会上传健康数据。")
        }
      } else {
        if !model.preferences.onboarded, let server = URL(string: model.preferences.server),
          server.host != nil
        {
          Section {
            Label("已连接到 " + (server.host ?? "服务器"), systemImage: "checkmark.shield")
            NavigationLink("继续") { ConsentView(onboarding: true) }
          }
        }
        Section {
          Button {
            Task { await scan() }
          } label: {
            Label("扫描连接码", systemImage: "qrcode.viewfinder")
          }
          PasteButton(payloadType: String.self) { if let value = $0.first { receive(value) } }
        } footer: {
          Text("使用部署完成后显示的连接码或链接。")
        }
      }
      if let message { Section { Text(message).foregroundStyle(.secondary) } }
      Section {
        Link(
          "部署到 Cloudflare",
          destination: URL(
            string:
              "https://deploy.workers.cloudflare.com/?url=https://github.com/AquaHydro/healthbridge"
          )!)
        NavigationLink("手动连接") { ConnectionView(onboarding: onboarding) }
      } footer: {
        Text("已有服务器可直接连接。")
      }
    }.navigationTitle("连接服务器").navigationBarTitleDisplayMode(.inline)
      .task { if CameraDiagnostics.enabled { await scan() } }
      .sheet(isPresented: $scanning) {
        NavigationStack {
          ConnectionScanner(
            receive: receive,
            failed: {
              message = "相机暂不可用，请粘贴连接链接。"
              scanning = false
            }
          ).ignoresSafeArea(edges: .bottom).navigationTitle("扫描连接码").navigationBarTitleDisplayMode(
            .inline
          ).toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { scanning = false } }
          }
        }
      }
      .navigationDestination(isPresented: $advance) { ConsentView(onboarding: onboarding) }
      .toolbar {
        if onboarding { NavigationLink("仅在本机查看") { TypeSelectionView(onboarding: true) } }
      }
  }
  private func receive(_ text: String) {
    scanning = false
    do {
      invitation = try ConnectionInvitation.parse(text)
      message = nil
    } catch { message = "这不是有效的连接链接。" }
  }
  private func scan() async {
    CameraDiagnostics.record("scan_requested")
    guard AVCaptureDevice.default(for: .video) != nil else {
      message = "此设备暂不支持扫码，请粘贴连接链接。"
      return
    }
    guard await AVCaptureDevice.requestAccess(for: .video)
    else {
      message = "请允许相机访问，或粘贴连接链接。"
      return
    }
    scanning = true
  }
  private func connect(_ invitation: ConnectionInvitation) async {
    busy = true
    message = nil
    defer { busy = false }
    do {
      let attempt = try Keychain.pairingAttempt(for: invitation)
      let response = try await ServerAPI(base: invitation.server, token: "").redeem(
        invitation, claimant: attempt.claimant)
      try await model.connect(
        url: invitation.server, token: response.ingest_token, status: response.status,
        mcpToken: response.mcp_token)
      try? Keychain.clearPairingAttempt()
      advance = true
    } catch { message = (error as? LocalizedError)?.errorDescription ?? "暂时无法连接，请重试。" }
  }
}

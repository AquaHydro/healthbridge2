import SwiftUI
import UIKit

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    AppModel.shared.registerLaunchObservers()
    return true
  }
  func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
    AppModel.shared.foreground()
    AppModel.shared.resumeAfterUnlock()
  }
}
@main struct HealthBridgeApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @Environment(\.scenePhase) private var phase
  @State private var model = AppModel.shared
  var body: some Scene {
    WindowGroup {
      @Bindable var model = model
      Group {
        if CameraDiagnostics.enabled {
          NavigationStack {
            ConnectionScanner(
              receive: { _ in CameraDiagnostics.record("barcode_recognized") },
              failed: { CameraDiagnostics.record("scanner_failed") }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("相机检查").navigationBarTitleDisplayMode(.inline)
          }
        } else if model.preferences.onboarded {
          MainView()
        } else {
          OnboardingView()
        }
      }
      .environment(model)
      .environment(\.locale, Locale(identifier: "zh_CN"))
      .preferredColorScheme(
        model.isUITesting && ProcessInfo.processInfo.arguments.contains("--ui-dark") ? .dark : nil
      )
      .safeAreaInset(edge: .top) {
        if model.isUITesting {
          Text("界面测试 · 合成数据").font(.caption).foregroundStyle(.secondary).dynamicTypeSize(
            ...DynamicTypeSize.large)
        }
      }
      .onOpenURL { url in
        if let invitation = try? ConnectionInvitation.parse(url.absoluteString) {
          model.connectionSheet = false
          model.consentSheet = false
          model.incomingInvitation = invitation
        }
      }
      .sheet(item: $model.incomingInvitation) { invitation in
        NavigationStack {
          QuickConnectView(onboarding: !model.preferences.onboarded, invitation: invitation)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("取消") { model.incomingInvitation = nil }
              }
            }
        }.environment(model)
      }
      .onChange(of: phase) { _, value in
        if value == .active && model.preferences.onboarded { model.foreground() }
      }
    }
  }
}

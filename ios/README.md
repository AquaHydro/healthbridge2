# iOS App

打开 `HealthBridge.xcodeproj`，选择 `HealthBridge` Scheme。最低 iOS 17，SwiftUI + HealthKit，无第三方 iOS 依赖。

完整安装、签名、系统授权与验证步骤见根 README。项目不保存个人开发团队；在 Xcode 选择自己的团队，或以 `DEVELOPMENT_TEAM` 参数传入。不要提交描述文件、证书或 Token。

工程源配置为 `project.yml`，如需重新生成，安装 XcodeGen 后执行 `xcodegen generate --spec ios/project.yml`。普通构建不需要 XcodeGen。

HealthKit 读取、删除事件、锁屏和后台交付必须在真机验证。模拟器运行和测试不能代替这些验收。

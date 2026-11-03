import XCTest

final class FlowTests: XCTestCase {
  func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func launch(_ options: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test"] + options
    app.launch()
    return app
  }
  func testIntroAndInvalidConnection() {
    let app = launch(["--ui-intro"])
    XCTAssertTrue(app.buttons["开始连接"].waitForExistence(timeout: 5))
    capture("01-intro")
    app.buttons["开始连接"].tap()
    app.buttons["手动连接"].tap()
    XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["继续"].isEnabled)
    app.textFields["serverURL"].tap()
    app.textFields["serverURL"].typeText("http://invalid.test")
    app.secureTextFields["ingestToken"].tap()
    app.secureTextFields["ingestToken"].typeText("synthetic-test-only")
    app.buttons["完成"].tap()
    if !app.buttons["测试连接"].isHittable { app.swipeUp() }
    app.buttons["测试连接"].tap()
    XCTAssertTrue(app.staticTexts["请填写不含路径、账号或查询参数的 HTTPS 服务器地址。"].waitForExistence(timeout: 3))
    capture("02-invalid-connection")
    app.swipeUp()
    XCTAssertFalse(app.buttons["继续"].isEnabled)
  }
  func testLocalOverviewDetailAndSettings() {
    let app = launch(["--ui-fixtures"])
    XCTAssertTrue(app.staticTexts["本机模式 · 未上传"].waitForExistence(timeout: 5))
    capture("03-local-overview")
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "睡眠")).firstMatch.tap()
    XCTAssertTrue(app.buttons["30 天"].waitForExistence(timeout: 3))
    app.buttons["30 天"].tap()
    capture("04-detail-30-days")
    app.navigationBars.buttons.firstMatch.tap()
    app.tabBars.buttons["设置"].tap()
    XCTAssertTrue(app.buttons["数据类型"].waitForExistence(timeout: 3))
    capture("05-settings")
    app.buttons["隐私说明"].tap()
    XCTAssertTrue(app.navigationBars["隐私说明"].waitForExistence(timeout: 3))
    capture("06-privacy")
  }
  func testEmptyAndSyncStates() {
    let app = launch([])
    XCTAssertTrue(app.staticTexts["暂无可读取的数据"].firstMatch.waitForExistence(timeout: 5))
    capture("07-empty")
    app.tabBars.buttons["同步"].tap()
    XCTAssertTrue(app.buttons["连接服务器"].waitForExistence(timeout: 3))
    capture("08-local-sync")
    for (argument, label, name) in [
      ("--ui-failure", "本次尚未完成，请稍后重试同步", "09-failure"),
      ("--ui-lock", "iPhone 锁定时无法读取健康数据，解锁后继续", "10-lock-wait"),
      ("--ui-progress", "正在同步健康数据", "11-progress"), ("--ui-paused", "同步已暂停 · 已撤回共享", "12-paused"),
    ] {
      app.terminate()
      app.launchArguments = ["--ui-test", argument]
      app.launch()
      XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 5))
      capture(name)
    }
  }
  func testDarkAndLargeText() {
    let app = launch([
      "--ui-fixtures", "--ui-dark", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL",
    ])
    XCTAssertTrue(app.staticTexts["本机模式 · 未上传"].waitForExistence(timeout: 5))
    capture("13-dark-large-text")
    app.tabBars.buttons["设置"].tap()
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "服务器")).firstMatch
        .waitForExistence(timeout: 3))
    capture("14-dark-settings")
  }
}

extension FlowTests {
  func testGenerateAndResumeTokenDraft() {
    let app = launch(["--ui-intro"])
    app.buttons["开始连接"].tap()
    app.buttons["手动连接"].tap()
    if !app.buttons["生成新 Token"].exists { app.buttons["高级配置"].tap() }
    app.buttons["生成新 Token"].tap()
    XCTAssertTrue(app.buttons["generateTokens"].waitForExistence(timeout: 3))
    if app.buttons["generateTokens"].label == "重新生成" {
      app.buttons["generateTokens"].tap()
      app.buttons["替换草稿"].tap()
    } else {
      app.buttons["generateTokens"].tap()
    }
    XCTAssertTrue(app.buttons["复制 MCP_TOKEN"].waitForExistence(timeout: 3))
    capture("15-token-generation")
    app.buttons["复制 MCP_TOKEN"].tap()
    app.buttons["关闭"].tap()
    XCTAssertFalse(app.buttons["继续"].isEnabled)
    if !app.buttons["生成新 Token"].exists { app.buttons["高级配置"].tap() }
    app.buttons["生成新 Token"].tap()
    XCTAssertTrue(app.buttons["复制 INGEST_TOKEN"].waitForExistence(timeout: 3))
    if !app.buttons["useGeneratedTokens"].isHittable { app.swipeUp() }
    app.buttons["useGeneratedTokens"].tap()
    XCTAssertTrue(app.secureTextFields["ingestToken"].exists)
    app.swipeUp()
    XCTAssertFalse(app.buttons["继续"].isEnabled)
    capture("16-generated-connection")
  }
  func testImportReadOnlyTokenAndCopyConfiguration() {
    let app = launch(["--ui-agent", "--ui-token-network"])
    app.buttons["连接 AI Agent"].tap()
    XCTAssertTrue(app.secureTextFields["mcpToken"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["复制只读 Token"].isEnabled)
    app.secureTextFields["mcpToken"].tap()
    app.secureTextFields["mcpToken"].typeText("synthetic-reader-test")
    app.buttons["saveMCPToken"].tap()
    XCTAssertTrue(app.staticTexts["只读连接已验证"].waitForExistence(timeout: 5))
    app.buttons["复制只读 Token"].tap()
    capture("17-agent-token")
    app.swipeUp()
    XCTAssertTrue(app.buttons["copyAgentConfig"].waitForExistence(timeout: 3))
    app.buttons["copyAgentConfig"].tap()
    capture("18-agent-copy")
  }
}

extension FlowTests {
  func testQuickConnectionStopsAtExplicitSharingConsent() {
    let app = launch(["--ui-pair", "--ui-token-network"])
    XCTAssertTrue(app.buttons["redeemConnection"].waitForExistence(timeout: 5))
    capture("19-quick-connect")
    app.buttons["redeemConnection"].tap()
    XCTAssertTrue(app.staticTexts["允许共享健康数据？"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["同意并继续"].exists)
    capture("20-sharing-consent")
  }
  func testFirstInstallHasQuickActionsAndAdvancedFallback() {
    let app = launch(["--ui-intro"])
    XCTAssertTrue(app.buttons["开始连接"].waitForExistence(timeout: 5))
    capture("21-first-install")
    app.buttons["开始连接"].tap()
    XCTAssertTrue(app.buttons["扫描连接码"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.secureTextFields["ingestToken"].exists)
    capture("22-quick-actions")
  }
}

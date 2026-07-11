import XCTest

final class AdaptiveScribeUITests: XCTestCase {
    @MainActor
    func testConsentFirstDeepSeekSetupCanExitWithoutAKeyOrNetwork() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scribe-fixture", "setup"]
        app.launch()

        openSettings(in: app)
        let setup = app.buttons["scribe-provider-setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        setup.click()

        XCTAssertTrue(app.staticTexts["Set up Scribe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["DeepSeek"].exists)
        XCTAssertTrue(app.buttons["Advanced OpenAI-compatible"].exists)
        app.buttons["DeepSeek"].click()

        XCTAssertTrue(app.staticTexts["Use DeepSeek for Scribe"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["scribe-provider-disclosure"].exists)
        attachScreenshot(app: app, name: "deepseek-disclosure")
        app.buttons["I understand"].click()
        XCTAssertTrue(app.secureTextFields["scribe-provider-api-key"].waitForExistence(timeout: 3))
        app.buttons["Not now"].click()
        XCTAssertFalse(app.secureTextFields["scribe-provider-api-key"].exists)

        attachScreenshot(app: app, name: "deepseek-setup-dismissed")
    }

    @MainActor
    func testAdvancedSetupShowsNormalizedRecipientBeforeAnyCredential() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scribe-fixture", "setup"]
        app.launch()

        openSettings(in: app)
        app.buttons["scribe-provider-setup"].click()
        XCTAssertTrue(app.buttons["Advanced OpenAI-compatible"].waitForExistence(timeout: 5))
        app.buttons["Advanced OpenAI-compatible"].click()
        let baseURL = app.textFields["scribe-advanced-base-url"]
        let model = app.textFields["scribe-advanced-model"]
        XCTAssertTrue(baseURL.waitForExistence(timeout: 3))
        baseURL.click()
        baseURL.typeText("HTTPS://Provider.Example:443/v1/")
        model.click()
        model.typeText("fixture-model")
        app.buttons["Review recipient and data use"].click()

        XCTAssertTrue(app.staticTexts["Connect to https://provider.example"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@",
            "Recipient: https://provider.example"
        )).firstMatch.exists)
        XCTAssertFalse(app.secureTextFields["scribe-provider-api-key"].exists)
        attachScreenshot(app: app, name: "advanced-recipient-disclosure")
        app.buttons["Not now"].click()
    }

    @MainActor
    func testWritingEnvironmentSettingsExposeFailClosedFirstSlice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scribe-fixture", "settings"]
        app.launch()

        openSettings(in: app)
        let adaptationToggle = app.descendants(matching: .any)["scribe-adaptation-toggle"]
        XCTAssertTrue(adaptationToggle.waitForExistence(timeout: 3))
        let slack = app.staticTexts["Slack"]
        XCTAssertTrue(slack.exists)
        let claudeCode = app.staticTexts["Claude Code"]
        XCTAssertTrue(claudeCode.exists)
        let claudeDetail = app.descendants(matching: .any)["scribe-environment-detail-claude-code"]
        XCTAssertTrue(claudeDetail.exists)
        let otherApps = app.staticTexts["Other apps"]
        XCTAssertTrue(otherApps.exists)

        attachScreenshot(app: app, name: "writing-environments")
    }

    @MainActor
    func testNarrowSlackReviewHasOneCueAndSafeActionHierarchy() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--scribe-fixture", "slackReview",
            "--scribe-fixture-width", "520",
            "-NSReduceMotion", "YES",
            "-NSIncreaseContrast", "YES"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Draft ready"].waitForExistence(timeout: 8))
        let environmentCues = app.descendants(matching: .any).matching(
            identifier: "scribe-environment-cue"
        )
        XCTAssertEqual(environmentCues.count, 1)
        XCTAssertEqual(environmentCues.firstMatch.label, "Writing environment")
        XCTAssertEqual(environmentCues.firstMatch.value as? String, "Slack · Neutral")
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "label == %@",
            "Draft again"
        )).count, 1)
        XCTAssertTrue(app.buttons["Insert into original app"].exists)
        XCTAssertTrue(app.buttons["Copy draft"].exists)
        XCTAssertTrue(app.buttons["Discard draft"].exists)
        attachScreenshot(element: app.dialogs.firstMatch, name: "slack-review-520")
    }

    @MainActor
    func testInsertionRecoveryKeepsDraftAndOnlyLocalRecoveryActions() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--scribe-fixture", "insertionRecovery",
            "--scribe-fixture-width", "720",
            "-AppleInterfaceStyle", "Dark",
            "-NSReduceTransparency", "YES"
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)[
            "scribe-insertion-recovery-status"
        ].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Return and insert"].exists)
        XCTAssertTrue(app.buttons["Copy draft"].exists)
        XCTAssertTrue(app.buttons["Discard draft"].exists)
        XCTAssertFalse(app.buttons["Draft again"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["scribe-environment-cue"].exists)
        attachScreenshot(element: app.dialogs.firstMatch, name: "insertion-recovery-720-dark")
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        let settings = app.buttons["sidebar-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.click()
    }

    @MainActor
    private func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachScreenshot(element: XCUIElement, name: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest

final class AdaptiveScribeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // The fixture suite launches different app processes and windows. A
        // previous fixture can still be winding down when XCTest starts the
        // next case, so begin from a known no-process state rather than
        // allowing stale UI ownership to make settings navigation flaky.
        terminateFixtureApplication()
    }

    override func tearDownWithError() throws {
        terminateFixtureApplication()
    }

    private func terminateFixtureApplication() {
        let app = XCUIApplication()
        app.terminate()

        let deadline = Date().addingTimeInterval(5)
        while app.state != .notRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(app.state, .notRunning, "Fixture app must terminate before the next UI case")
    }

    @MainActor
    func testConsentFirstDeepSeekSetupCanExitWithoutAKeyOrNetwork() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scribe-fixture", "setup"]
        app.launch()

        openSettings(in: app)
        selectSettingsCategory("scribe", in: app)
        let setup = app.buttons["scribe-provider-setup"]
        scrollToExistence(setup, in: app)
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        setup.click()

        XCTAssertTrue(app.buttons["DeepSeek"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Advanced OpenAI-compatible"].exists)
        app.buttons["DeepSeek"].click()

        XCTAssertTrue(app.staticTexts["Use DeepSeek for Scribe"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["scribe-provider-disclosure"].exists)
        attachScreenshot(app: app, name: "deepseek-disclosure")
        app.buttons["I understand"].click()
        XCTAssertTrue(app.secureTextFields["scribe-provider-api-key"].waitForExistence(timeout: 3))
        app.buttons["Not now"].click()
        XCTAssertTrue(waitForNonexistence(app.secureTextFields["scribe-provider-api-key"]))

        attachScreenshot(app: app, name: "deepseek-setup-dismissed")
    }

    @MainActor
    func testAdvancedSetupShowsNormalizedRecipientBeforeAnyCredential() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scribe-fixture", "setup"]
        app.launch()

        openSettings(in: app)
        selectSettingsCategory("scribe", in: app)
        let setup = app.buttons["scribe-provider-setup"]
        scrollToExistence(setup, in: app)
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        setup.click()
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
        selectSettingsCategory("scribe", in: app)
        let adaptationToggle = app.descendants(matching: .any)["scribe-adaptation-toggle"]
        scrollToExistence(adaptationToggle, in: app)
        XCTAssertTrue(adaptationToggle.waitForExistence(timeout: 3))
        let initialToggleValue = String(describing: adaptationToggle.value!)
        adaptationToggle.click()
        XCTAssertNotEqual(String(describing: adaptationToggle.value!), initialToggleValue)
        XCTAssertTrue(app.buttons["settings-add-application"].exists)
        XCTAssertTrue(app.buttons["scribe-provider-setup"].exists)

        attachScreenshot(app: app, name: "scribe-app-profiles")
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
            "Record again"
        )).count, 1)
        XCTAssertTrue(app.buttons["Insert polished into Slack"].exists)
        XCTAssertTrue(app.buttons["Copy polished"].exists)
        XCTAssertTrue(app.buttons["Retry polish"].exists)
        XCTAssertTrue(app.buttons["Copy unpolished"].exists)
        XCTAssertTrue(app.buttons["Discard draft"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["scribe-exact-literal-summary"].exists)
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
        XCTAssertTrue(app.buttons["Return to Claude and insert polished"].exists)
        XCTAssertTrue(app.buttons["Copy polished"].exists)
        XCTAssertTrue(app.buttons["Copy unpolished"].exists)
        XCTAssertTrue(app.buttons["Discard draft"].exists)
        XCTAssertFalse(app.buttons["Record again"].exists)
        let cues = app.descendants(matching: .any).matching(identifier: "scribe-environment-cue")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.firstMatch.value as? String, "Claude · Coding")
        attachScreenshot(element: app.dialogs.firstMatch, name: "insertion-recovery-720-dark")
    }

    @MainActor
    func testEscapeRequiresConfirmationWhileReviewDraftRemainsAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--scribe-fixture", "slackReview",
            "--scribe-fixture-width", "520"
        ]
        app.launch()

        let fixture = app.descendants(matching: .any)["scribe-fixture-slack-review"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))
        fixture.click()
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["Discard this draft?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Discard draft"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.staticTexts["Discard this draft?"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["Copy polished"].exists)
    }

    @MainActor
    func testRecoverableFailureAlsoConfirmsBeforeDiscard() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--scribe-fixture", "retryable-failure",
            "--scribe-fixture-width", "560"
        ]
        app.launch()

        let fixture = app.descendants(matching: .any)["scribe-fixture-retryable-failure"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Discard draft"].exists)
        fixture.click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Discard this draft?"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.staticTexts["Discard this draft?"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["Copy unpolished"].exists)
        XCTAssertTrue(app.buttons["Insert unpolished"].exists)
        XCTAssertTrue(app.buttons["Try Scribe again"].exists)
    }

    @MainActor
    func testActionLayoutUsesExact560PointBreakpointAndStableOrder() throws {
        for (width, expectedLayout) in [(520, "Vertical"), (559, "Vertical"), (560, "Vertical"), (720, "Vertical")] {
            let app = XCUIApplication()
            app.launchArguments = [
                "--scribe-fixture", "slackReview",
                "--scribe-fixture-width", String(width)
            ]
            if width == 520 {
                app.launchArguments.append("--scribe-fixture-large-text")
            }
            app.launch()

            let group = app.descendants(matching: .any)["scribe-action-group"]
            XCTAssertTrue(group.waitForExistence(timeout: 8))
            app.activate()
            let ordered = ["Discard draft", "Record again", "Retry polish", "Copy unpolished", "Insert unpolished", "Copy polished", "Insert polished into Slack"]
                .map { app.buttons[$0] }
            XCTAssertTrue(ordered.allSatisfy(\.isHittable))
            let ys = ordered.map { $0.frame.midY }
            if expectedLayout == "Vertical" {
                XCTAssertTrue(zip(ys, ys.dropFirst()).allSatisfy { pair in pair.0 < pair.1 })
            } else {
                XCTAssertLessThan((ys.max() ?? 0) - (ys.min() ?? 0), 4)
            }
            app.terminate()
        }
    }

    @MainActor
    func testReturnActivatesTheUniqueDefaultActionOnce() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--scribe-fixture", "slackReview",
            "--scribe-fixture-width", "560"
        ]
        app.launch()

        let fixture = app.descendants(matching: .any)["scribe-fixture-slack-review"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))
        fixture.click()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["scribe-fixture-return-success"]
            .waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Done")).count, 1)
    }

    @MainActor
    func testNativeTabTraversalFollowsActionSourceOrderAtCompactAndWideWidths() throws {
        let expected = [
            "scribe-action-discard-draft",
            "scribe-action-record-again",
            "scribe-action-retry-polish",
            "scribe-action-copy-unpolished",
            "scribe-action-insert-unpolished",
            "scribe-action-copy-polished",
            "scribe-action-insert-polished"
        ]

        for width in [520, 560] {
            let app = XCUIApplication()
            app.launchArguments = [
                "--scribe-fixture", "slackReview",
                "--scribe-fixture-width", String(width),
                "--scribe-fixture-focus-probe"
            ]
            app.launch()

            let fixture = app.descendants(matching: .any)["scribe-fixture-slack-review"]
            XCTAssertTrue(fixture.waitForExistence(timeout: 8))
            fixture.click()
            let probe = app.staticTexts["scribe-focused-action"]
            XCTAssertTrue(probe.waitForExistence(timeout: 3))

            var traversed: [String] = []
            let initiallyFocused = String(describing: probe.value!)
            if expected.contains(initiallyFocused) {
                traversed.append(initiallyFocused)
            }
            for _ in 0..<12 where traversed.count < expected.count {
                app.typeKey(.tab, modifierFlags: [])
                let focused = String(describing: probe.value!)
                if expected.contains(focused), traversed.last != focused {
                    traversed.append(focused)
                }
            }

            XCTAssertEqual(traversed, expected, "Unexpected Tab order at width \(width)")
            for identifier in expected {
                XCTAssertTrue(app.buttons[identifier].exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testRenderedActionButtonsHonorDisabledLoadingDefaultAndCancelSemantics() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--scribe-fixture", "control-semantics",
            "--scribe-fixture-width", "720"
        ]
        app.launch()

        let fixture = app.descendants(matching: .any)["scribe-fixture-control-semantics"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))
        fixture.click()

        let enabled = app.buttons["control-fixture-enabled"]
        let disabled = app.buttons["control-fixture-disabled"]
        let loading = app.buttons["control-fixture-loading"]
        let defaultAction = app.buttons["control-fixture-default"]
        let cancel = app.buttons["control-fixture-cancel"]
        let counts = app.staticTexts["control-fixture-counts"]

        XCTAssertTrue(enabled.isEnabled)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertFalse(loading.isEnabled)
        XCTAssertEqual(String(describing: loading.value!), "Loading")
        XCTAssertTrue(defaultAction.isEnabled)
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertEqual(
            String(describing: counts.value!),
            "enabled=0;disabled=0;loading=0;default=0;cancel=0"
        )

        disabled.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        loading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(
            String(describing: counts.value!),
            "enabled=0;disabled=0;loading=0;default=0;cancel=0"
        )

        enabled.click()
        XCTAssertEqual(
            String(describing: counts.value!),
            "enabled=1;disabled=0;loading=0;default=0;cancel=0"
        )
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(
            String(describing: counts.value!),
            "enabled=1;disabled=0;loading=0;default=1;cancel=0"
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(
            String(describing: counts.value!),
            "enabled=1;disabled=0;loading=0;default=1;cancel=1"
        )
    }

    @MainActor
    func testSettingsUseCurrentControlsAndContinuousWaveformSlider() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scribe-fixture", "settings"]
        app.launch()

        openSettings(in: app)
        selectSettingsCategory("dictation", in: app)
        let qualitySelector = app.descendants(matching: .any)["settings-quality-selector"]
        XCTAssertTrue(qualitySelector.waitForExistence(timeout: 3))
        selectSettingsCategory("scribe", in: app)
        let adaptationToggle = app.descendants(matching: .any)["scribe-adaptation-toggle"]
        scrollToExistence(adaptationToggle, in: app)
        XCTAssertTrue(adaptationToggle.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["settings-add-application"].exists)

        selectSettingsCategory("advanced", in: app)
        let disclosure = app.descendants(matching: .any)["settings-advanced-disclosure"]
        XCTAssertTrue(disclosure.exists)
        let disclosureState = app.descendants(matching: .any)["settings-advanced-disclosure-state"]
        XCTAssertEqual(disclosureState.value as? String, "Collapsed")
        disclosure.click()
        XCTAssertEqual(disclosureState.value as? String, "Expanded")
        XCTAssertTrue(app.descendants(matching: .any)["settings-recognition-model-menu"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings-search-depth-selector"].exists)
        let slider = app.sliders["settings-waveform-sensitivity-slider"]
        XCTAssertTrue(slider.exists)
        app.activate()
        let settingsScrollView = app.scrollViews.firstMatch
        for _ in 0..<4 where !slider.isHittable {
            settingsScrollView.scroll(byDeltaX: 0, deltaY: -240)
        }
        XCTAssertTrue(slider.isHittable)
        let sliderValue = slider.value
        XCTAssertNotNil(sliderValue)
        XCTAssertFalse(String(describing: sliderValue!).isEmpty)
        let displayedValue = app.staticTexts["settings-waveform-sensitivity-value"]
        let originalValue = String(describing: displayedValue.value!)
        slider.adjust(toNormalizedSliderPosition: 0.1)
        XCTAssertNotEqual(String(describing: displayedValue.value!), originalValue)
    }

    @MainActor
    func testSuccessFixtureUsesExactInsertedCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--scribe-fixture", "success",
            "--scribe-fixture-width", "720"
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["scribe-fixture-success"]
            .waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Inserted into original app"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@",
            "copy"
        )).firstMatch.exists)
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        app.activate()
        let settings = app.buttons["sidebar-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        let settingsContent = app.descendants(matching: .any)["settings-category-content-general"]
        for _ in 0..<3 where !settingsContent.exists {
            app.activate()
            settings.click()
            app.activate()
            _ = settingsContent.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(settingsContent.exists)
    }

    @MainActor
    func testSettingsRouterUsesExactBreakpointAndReachesEveryCategory() throws {
        for width in [520, 559, 560, 720] {
            let app = XCUIApplication()
            app.launchArguments = ["--scribe-fixture", "settings", "--scribe-fixture-width", String(width)]
            app.launch()
            openSettings(in: app)

            if width < 560 {
                XCTAssertTrue(app.descendants(matching: .any)["settings-category-selector"].exists)
                XCTAssertFalse(app.descendants(matching: .any)["settings-category-rail"].exists)
            } else {
                XCTAssertTrue(app.descendants(matching: .any)["settings-category-rail"].exists)
            }
            for category in ["general", "dictation", "scribe", "privacy", "advanced"] {
                selectSettingsCategory(category, in: app)
                XCTAssertTrue(app.descendants(matching: .any)["settings-category-content-\(category)"].waitForExistence(timeout: 2))
            }
            app.terminate()
        }
    }

    @MainActor
    func testSettingsUsesRailAtExactly560Points() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scribe-fixture", "settings", "--scribe-fixture-width", "560"]
        app.launch()
        openSettings(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings-category-rail"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["settings-category-selector"].exists)
    }

    @MainActor
    func testProviderSetupDismissalClearsCredentialAndDoesNotReappearOnNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scribe-fixture", "setup", "--scribe-fixture-width", "720"]
        app.launch()
        openSettings(in: app)
        selectSettingsCategory("scribe", in: app)
        let setup = app.buttons["scribe-provider-setup"]
        scrollToExistence(setup, in: app)
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        setup.click()
        app.buttons["OpenAI Direct"].click()
        app.buttons["I understand"].click()
        let key = app.secureTextFields["scribe-provider-api-key"]
        XCTAssertTrue(key.waitForExistence(timeout: 3))
        key.click()
        key.typeText("ephemeral-fixture-key")
        app.buttons["Not now"].click()
        XCTAssertTrue(waitForNonexistence(key))
        selectSettingsCategory("privacy", in: app)
        XCTAssertFalse(app.staticTexts["Connect Scribe"].exists)
    }

    @MainActor
    private func selectSettingsCategory(_ category: String, in app: XCUIApplication) {
        let title = category.prefix(1).uppercased() + category.dropFirst()
        let railByID = app.descendants(matching: .any)["settings-category-\(category)"].firstMatch
        if railByID.waitForExistence(timeout: 1) {
            railByID.click()
            return
        }
        let railByTitle = app.buttons[title].firstMatch
        if railByTitle.exists {
            railByTitle.click()
            return
        }
        // Prefer popUpButtons; fall back to any element with the ID (some
        // macOS/SwiftUI builds expose the picker as a non-popUp control).
        let selector = app.popUpButtons["settings-category-selector"].firstMatch.exists
            ? app.popUpButtons["settings-category-selector"].firstMatch
            : app.descendants(matching: .any)["settings-category-selector"].firstMatch
        if selector.waitForExistence(timeout: 2) {
            selector.click()
            let menuItem = app.menuItems[title].firstMatch
            if menuItem.waitForExistence(timeout: 2) {
                menuItem.click()
                return
            }
            let choice = app.staticTexts[title].firstMatch
            if choice.waitForExistence(timeout: 1) {
                choice.click()
                return
            }
        }
        XCTFail("Could not select settings category \(category) via rail or compact selector")
    }

    @MainActor
    private func waitForNonexistence(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func scrollToExistence(_ element: XCUIElement, in app: XCUIApplication) {
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<6 where !element.exists {
            scrollView.scroll(byDeltaX: 0, deltaY: 360)
        }
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

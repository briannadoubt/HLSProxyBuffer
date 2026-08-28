import XCTest

final class HLSProxyFeedDemoAppUITests: XCTestCase {
    private let itemCount = 24
    private let measuredNavigationCount = 100

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryFeedUsesRealVerticalPagingAndReversesCleanly() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        let pager = app.scrollViews["primary-vertical-feed"]
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        let focusedItem = app.staticTexts["feed-focused-item"]
        let focusedPlayback = app.staticTexts["feed-focused-playback"]
        XCTAssertTrue(waitForValue("short-0", in: focusedItem, timeout: 10))
        XCTAssertTrue(waitForValue("Playing", in: focusedPlayback, timeout: 10))

        pager.swipeUp()
        XCTAssertTrue(waitForValue("short-1", in: focusedItem, timeout: 10))
        XCTAssertTrue(waitForValue("Playing", in: focusedPlayback, timeout: 10))

        pager.swipeUp()
        XCTAssertTrue(waitForValue("short-2", in: focusedItem, timeout: 10))
        pager.swipeDown()
        XCTAssertTrue(waitForValue("short-1", in: focusedItem, timeout: 10))
        XCTAssertTrue(waitForValue("Playing", in: focusedPlayback, timeout: 10))

        let focusedPage = app.descendants(matching: .any)["feed-item-short-1"]
        XCTAssertTrue(focusedPage.waitForExistence(timeout: 5))
    }

    @MainActor
    func testOneHundredRapidNavigationsKeepPlaybackAndResourcesCorrect() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--qualification-mode"]
        app.launch()

        XCTAssertTrue(waitForValue("Ready", in: app.staticTexts["qualification-ready"], timeout: 10))
        XCTAssertTrue(waitForValue("Playing", in: app.staticTexts["qualification-playback-state"], timeout: 10))

        for expectedIndex in 1..<itemCount {
            app.buttons["qualification-next"].tap()
            XCTAssertTrue(waitForValue(
                "short-\(expectedIndex)",
                in: app.staticTexts["qualification-focus"],
                timeout: 5
            ))
            XCTAssertTrue(waitForValue(
                "Playing",
                in: app.staticTexts["qualification-playback-state"],
                timeout: 5
            ))
        }

        let warmupButton = app.buttons["qualification-mark-warmup"]
        warmupButton.tap()
        XCTAssertTrue(waitForValue("ready", in: warmupButton, timeout: 5))
        let warmupNavigationCount = itemCount - 1
        XCTAssertTrue(waitForValue(
            "\(warmupNavigationCount)",
            in: app.staticTexts["qualification-navigation-count"],
            timeout: 5
        ))

        for _ in 0..<measuredNavigationCount {
            app.buttons["qualification-next"].tap()
        }
        let totalNavigationCount = warmupNavigationCount + measuredNavigationCount
        XCTAssertTrue(waitForValue(
            "\(totalNavigationCount)",
            in: app.staticTexts["qualification-navigation-count"],
            timeout: 10
        ))

        app.buttons["qualification-finish"].tap()
        let reportElement = app.staticTexts["qualification-report"]
        XCTAssertTrue(waitForValueMatching(
            NSPredicate(format: "value != %@", "pending"),
            in: reportElement,
            timeout: 15
        ))
        let report = reportElement.value as? String ?? reportElement.label
        XCTAssertTrue(waitForValue(
            "PASS",
            in: app.staticTexts["qualification-result"],
            timeout: 2
        ), report)
        let expectedFinalIndex = totalNavigationCount % itemCount
        XCTAssertTrue(waitForValue(
            "short-\(expectedFinalIndex)",
            in: app.staticTexts["qualification-focus"],
            timeout: 5
        ))
        XCTAssertTrue(waitForValue("Playing", in: app.staticTexts["qualification-playback-state"], timeout: 5))

        XCTAssertTrue(
            report.contains("\"measuredNavigationCount\":\(measuredNavigationCount)"),
            report
        )
        XCTAssertTrue(report.contains("\"passed\":true"), report)
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.json")
        attachment.name = "hls-feed-ui-qualification.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAnalyticsInspectorShowsTypedSanitizedPublicPipeline() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        let inspectorButton = app.buttons["analytics-inspector-button"]
        XCTAssertTrue(inspectorButton.waitForExistence(timeout: 10))
        inspectorButton.tap()

        let inspector = app.descendants(matching: .any)["analytics-inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        let mode = app.descendants(matching: .any)["analytics-mode"]
        XCTAssertTrue(waitForValue("shortForm", in: mode, timeout: 5))
        let eventCount = app.descendants(matching: .any)["analytics-event-count"]
        XCTAssertTrue(waitForValueMatching(
            NSPredicate(format: "value != %@", "0"),
            in: eventCount,
            timeout: 10
        ))

        for layer in ["avFoundation", "proxyOrigin", "engine", "exporter"] {
            XCTAssertTrue(
                scrollToExistence(
                    app.descendants(matching: .any)["analytics-layer-\(layer)"],
                    in: app
                ),
                layer
            )
        }
        XCTAssertTrue(
            scrollToExistence(
                app.descendants(matching: .any)["analytics-summary-status"],
                in: app
            )
        )
        XCTAssertTrue(
            scrollToExistence(
                app.descendants(matching: .any)["analytics-delivery-health"],
                in: app
            )
        )

        let previewElement = app.descendants(matching: .any)["analytics-export-preview"]
        XCTAssertTrue(scrollToExistence(previewElement, in: app))
        XCTAssertTrue(waitForValueMatching(
            NSPredicate(format: "value != %@", "pending"),
            in: previewElement,
            timeout: 10
        ))
        let preview = previewElement.value as? String ?? previewElement.label
        for forbidden in [
            "http://", "https://", "authorization", "cookie", "bearer", "token",
            "requestHeaders", "responseHeaders", "userIdentifier", "ipAddress",
        ] {
            XCTAssertFalse(
                preview.localizedCaseInsensitiveContains(forbidden),
                "Inspector leaked forbidden text: \(forbidden)"
            )
        }

        app.buttons["analytics-inspector-close"].tap()
        XCTAssertFalse(inspector.waitForExistence(timeout: 2))
    }

    @MainActor
    private func scrollToExistence(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 12
    ) -> Bool {
        for _ in 0..<maximumSwipes {
            if element.exists {
                return true
            }
            app.swipeUp()
        }
        return element.exists
    }

    @MainActor
    private func waitForValue(
        _ expectedValue: String,
        in element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "value == %@ OR label == %@", expectedValue, expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForValueMatching(
        _ predicate: NSPredicate,
        in element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

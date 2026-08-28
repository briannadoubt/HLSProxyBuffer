import XCTest

final class HLSProxyFeedDemoAppUITests: XCTestCase {
    private let itemCount = 24
    private let measuredNavigationCount = 100

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryFeedQualifiesRealVerticalPagingAndAdverseConditions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--vertical-qualification-mode"]
        app.launch()

        let pager = app.scrollViews["primary-vertical-feed"]
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        XCTAssertEqual(assertSettled(in: app, expectedFocus: "short-0"), "short-0")

        pager.swipeUp()
        XCTAssertEqual(assertSettled(in: app, expectedFocus: "short-1"), "short-1")

        pager.swipeUp()
        XCTAssertEqual(assertSettled(in: app, expectedFocus: "short-2"), "short-2")
        pager.swipeDown()
        XCTAssertEqual(assertSettled(in: app, expectedFocus: "short-1"), "short-1")

        let focusedPage = app.descendants(matching: .any)["feed-item-short-1"]
        XCTAssertTrue(focusedPage.waitForExistence(timeout: 5))

        let poorNetworkButton = app.buttons["vertical-network-poor"]
        XCTAssertTrue(poorNetworkButton.waitForExistence(timeout: 5))
        poorNetworkButton.tap()
        XCTAssertTrue(waitForValue(
            "poor",
            in: app.staticTexts["vertical-network-condition"],
            timeout: 5
        ))

        let cancellationElement = app.staticTexts["vertical-cancellation-count"]
        let cancellationBaseline = value(of: cancellationElement)
        pager.swipeUp(velocity: .fast)
        pager.swipeUp(velocity: .fast)
        pager.swipeUp(velocity: .fast)
        pager.swipeDown(velocity: .fast)
        pager.swipeDown(velocity: .fast)
        _ = assertSettled(in: app)
        XCTAssertTrue(waitForValueMatching(
            NSPredicate(format: "value != %@", cancellationBaseline),
            in: cancellationElement,
            timeout: 10
        ), "Rapid reversal did not cancel obsolete preparation")

        app.buttons["vertical-network-offline"].tap()
        XCTAssertTrue(waitForValue(
            "offline",
            in: app.staticTexts["vertical-network-condition"],
            timeout: 5
        ))
        pager.swipeDown()
        _ = assertSettled(in: app)

        app.buttons["vertical-network-normal"].tap()
        XCTAssertTrue(waitForValue(
            "normal",
            in: app.staticTexts["vertical-network-condition"],
            timeout: 5
        ))
        pager.swipeUp()
        _ = assertSettled(in: app)

        app.buttons["vertical-memory-pressure"].tap()
        _ = assertSettled(in: app)

        XCUIDevice.shared.press(.home)
        app.activate()
        _ = assertSettled(in: app)

        app.buttons["vertical-qualification-finish"].tap()
        let reportElement = app.staticTexts["vertical-qualification-report"]
        XCTAssertTrue(waitForValueMatching(
            NSPredicate(format: "value != %@", "pending"),
            in: reportElement,
            timeout: 15
        ))
        let report = value(of: reportElement)
        XCTAssertTrue(report.contains("\"qualificationKind\":\"vertical_paging_ui\""), report)
        XCTAssertTrue(report.contains("\"passed\":true"), report)
        XCTAssertTrue(report.contains("\"finalOwnershipAligned\":true"), report)
        XCTAssertTrue(report.contains("\"networkConditionTransitionCount\":3"), report)

        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.json")
        attachment.name = "hls-feed-vertical-ui-qualification.json"
        attachment.lifetime = .keepAlways
        add(attachment)
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
    @discardableResult
    private func assertSettled(
        in app: XCUIApplication,
        expectedFocus: String? = nil,
        timeout: TimeInterval = 15
    ) -> String {
        let focused = app.staticTexts["feed-focused-item"]
        let playback = app.staticTexts["feed-focused-playback"]
        let active = app.staticTexts["vertical-active-item"]
        let audible = app.staticTexts["vertical-audible-item"]

        if let expectedFocus {
            XCTAssertTrue(waitForValue(expectedFocus, in: focused, timeout: timeout))
        } else {
            XCTAssertTrue(waitForValueMatching(
                NSPredicate(format: "value BEGINSWITH %@", "short-"),
                in: focused,
                timeout: timeout
            ))
        }
        XCTAssertTrue(waitForValue("Playing", in: playback, timeout: timeout))

        for _ in 0..<3 {
            let focusedValue = value(of: focused)
            guard focusedValue.hasPrefix("short-") else { continue }
            if waitForValue(focusedValue, in: active, timeout: timeout),
               waitForValue(focusedValue, in: audible, timeout: timeout),
               value(of: focused) == focusedValue {
                return focusedValue
            }
        }
        XCTFail(
            "Focused, active, and audible owners did not converge: "
                + "focus=\(value(of: focused)) active=\(value(of: active)) "
                + "audible=\(value(of: audible))"
        )
        return value(of: focused)
    }

    @MainActor
    private func value(of element: XCUIElement) -> String {
        element.value as? String ?? element.label
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

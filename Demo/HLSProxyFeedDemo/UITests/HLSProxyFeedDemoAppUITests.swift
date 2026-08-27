import XCTest

final class HLSProxyFeedDemoAppUITests: XCTestCase {
    private let itemCount = 14

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOneHundredRapidNavigationsKeepPlaybackAndResourcesCorrect() throws {
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
        XCTAssertTrue(waitForValue("13", in: app.staticTexts["qualification-navigation-count"], timeout: 5))

        for _ in 0..<100 {
            app.buttons["qualification-next"].tap()
        }
        XCTAssertTrue(waitForValue("113", in: app.staticTexts["qualification-navigation-count"], timeout: 10))

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
        XCTAssertTrue(waitForValue("short-1", in: app.staticTexts["qualification-focus"], timeout: 5))
        XCTAssertTrue(waitForValue("Playing", in: app.staticTexts["qualification-playback-state"], timeout: 5))

        XCTAssertTrue(report.contains("\"measuredNavigationCount\":100"), report)
        XCTAssertTrue(report.contains("\"passed\":true"), report)
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.json")
        attachment.name = "hls-feed-ui-qualification.json"
        attachment.lifetime = .keepAlways
        add(attachment)
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

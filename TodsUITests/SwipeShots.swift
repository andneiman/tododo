import XCTest

/// Real screenshots of gestures in the iPhone app (demo data, no account).
/// Run: xcodebuild test -scheme TodsUITests -destination 'platform=iOS Simulator,name=…'
/// Each screenshot is attached to the test result (exported in CI).
final class SwipeShots: XCTestCase {
    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-demoScreen", screen]
        app.launch()
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Task details: swipe a step left (Show / Hide) and right (Delete).
    func testStepSwipes() {
        var app = launch("detail")
        let step = app.staticTexts["Book a room"].exists ? app.staticTexts["Book a room"] : app.textFields["Book a room"]
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        step.swipeLeft()
        sleep(1)
        shoot(app, "step-swipe-left")

        app.terminate()
        app = launch("detail")
        let step2 = app.staticTexts["Book a room"].exists ? app.staticTexts["Book a room"] : app.textFields["Book a room"]
        XCTAssertTrue(step2.waitForExistence(timeout: 10))
        step2.swipeRight()
        sleep(1)
        shoot(app, "step-swipe-right")
    }
}

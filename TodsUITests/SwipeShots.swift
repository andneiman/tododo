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

    /// Sidebar: long press a group header opens its menu; Rename puts the name in edit mode.
    func testGroupMenu() {
        let app = launch("home")
        let header = app.buttons["group-Projects"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        header.press(forDuration: 1.0)
        sleep(1)
        shoot(app, "group-long-press")
        let rename = app.buttons["Rename Group"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        sleep(2)
        app.typeText(" 2")
        sleep(1)
        shoot(app, "group-rename")
    }
}

import XCTest

final class LocalDropMenuCommandUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
    }

    func testViewKeyboardShortcutsNavigateBetweenScreens() {
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen-receive"].waitForExistence(timeout: 5))

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["screen-send"].waitForExistence(timeout: 2))

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["screen-history"].waitForExistence(timeout: 2))

        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["screen-settings"].waitForExistence(timeout: 2))

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["screen-receive"].waitForExistence(timeout: 2))
    }

    func testPreferencesShortcutOpensSettings() {
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen-receive"].waitForExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.descendants(matching: .any)["screen-settings"].waitForExistence(timeout: 2))
    }

    func testSendTextCommandShortcutOpensSheet() {
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen-receive"].waitForExistence(timeout: 5))

        app.typeKey("t", modifierFlags: .command)

        XCTAssertTrue(app.staticTexts["Send Text"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Stage Text"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)

        app.buttons["Cancel"].click()
        XCTAssertFalse(app.staticTexts["Send Text"].waitForExistence(timeout: 1))
    }

    func testSettingsAllowsRevealingAndRegeneratingIncomingPIN() {
        app.launchArguments = ["--ui-testing", "--ui-testing-incoming-pin-enabled"]
        app.launch()

        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["screen-settings"].waitForExistence(timeout: 2))

        let visibilityButton = app.descendants(matching: .any)["settings-incoming-pin-visibility"]
        XCTAssertTrue(visibilityButton.waitForExistence(timeout: 2))
        visibilityButton.click()

        let pinField = app.descendants(matching: .any)["settings-incoming-pin-field"]
        XCTAssertTrue(pinField.waitForExistence(timeout: 2))
        let originalValue = pinField.value as? String
        XCTAssertEqual(originalValue?.count, 6)

        let regenerateButton = app.descendants(matching: .any)["settings-incoming-pin-regenerate"]
        XCTAssertTrue(regenerateButton.waitForExistence(timeout: 2))
        regenerateButton.click()

        XCTAssertTrue(waitForValueChange(ofElementWithID: "settings-incoming-pin-field", from: originalValue, timeout: 2))
        let regeneratedValue = app.descendants(matching: .any)["settings-incoming-pin-field"].value as? String
        XCTAssertEqual(regeneratedValue?.count, 6)
        XCTAssertNotEqual(regeneratedValue, originalValue)
    }

    func testSeededBatchShowsMultipleStagedItemsAndSupportsRemovingOne() {
        app.launchArguments = ["--ui-testing", "--ui-testing-seed-staged-batch"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["screen-send"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3 items staged · 17 bytes"].waitForExistence(timeout: 2))

        XCTAssertTrue(app.staticTexts["alpha.txt"].exists)
        XCTAssertTrue(app.staticTexts["bravo.pdf"].exists)
        XCTAssertTrue(app.staticTexts["charlie.jpg"].exists)

        let removeButton = app.buttons["Remove bravo.pdf"]
        XCTAssertTrue(removeButton.waitForExistence(timeout: 2))
        removeButton.click()

        XCTAssertTrue(app.staticTexts["2 items staged · 12 bytes"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["bravo.pdf"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["alpha.txt"].exists)
        XCTAssertTrue(app.staticTexts["charlie.jpg"].exists)
    }

    private func waitForValueChange(
        ofElementWithID identifier: String,
        from originalValue: String?,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = app.descendants(matching: .any)[identifier].value as? String
            if value != originalValue {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}

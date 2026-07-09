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

    func testAppMenusExposeTransferCommands() {
        app.launch()

        XCTAssertTrue(app.menuBars.firstMatch.waitForExistence(timeout: 5))

        clickMenuBarItem(named: "File")
        XCTAssertTrue(app.menuItems["Send File…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Send Folder…"].exists)
        XCTAssertTrue(app.menuItems["Send Text…"].exists)
        XCTAssertTrue(app.menuItems["Clear History"].exists)
        app.typeKey(.escape, modifierFlags: [])

        clickMenuBarItem(named: "View")
        XCTAssertTrue(app.menuItems["Receive"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Send"].exists)
        XCTAssertTrue(app.menuItems["History"].exists)
        XCTAssertTrue(app.menuItems["Settings"].exists)
        app.typeKey(.escape, modifierFlags: [])

        clickMenuBarItem(named: "Help")
        XCTAssertTrue(app.menuItems["LocalDrop Help"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["LocalSend Protocol Docs"].exists)
        XCTAssertTrue(app.menuItems["Report an Issue"].exists)
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

    private func clickMenuBarItem(named name: String) {
        let menuBars = app.menuBars

        for index in 0..<menuBars.count {
            let menuBar = menuBars.element(boundBy: index)
            let item = menuBar.menuBarItems.matching(NSPredicate(format: "label == %@", name)).element(boundBy: 0)
            if item.exists {
                item.click()
                return
            }
        }

        XCTFail("Menu bar item not found: \(name)")
    }
}

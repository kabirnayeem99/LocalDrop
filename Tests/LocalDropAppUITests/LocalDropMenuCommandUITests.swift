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

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 5))

        menuBar.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["Send File…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Send Folder…"].exists)
        XCTAssertTrue(app.menuItems["Send Text…"].exists)
        XCTAssertTrue(app.menuItems["Clear History"].exists)
        app.typeKey(.escape, modifierFlags: [])

        menuBar.menuBarItems["View"].click()
        XCTAssertTrue(app.menuItems["Receive"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Send"].exists)
        XCTAssertTrue(app.menuItems["History"].exists)
        XCTAssertTrue(app.menuItems["Settings"].exists)
        app.typeKey(.escape, modifierFlags: [])

        menuBar.menuBarItems["Help"].click()
        XCTAssertTrue(app.menuItems["LocalDrop Help"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["LocalSend Protocol Docs"].exists)
        XCTAssertTrue(app.menuItems["Report an Issue"].exists)
    }
}

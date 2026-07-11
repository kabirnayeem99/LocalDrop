import XCTest
@testable import LocalDrop

final class LocalDropAppTests: XCTestCase {
    func testSendEntryPresentationStateTransitions() {
        var state = SendEntryPresentationState()

        state.beginFiles()
        XCTAssertTrue(state.isFileImporterPresented)

        state.beginFolders()
        XCTAssertTrue(state.isFolderImporterPresented)

        state.beginTextEntry(prefilledText: "hello")
        XCTAssertTrue(state.isTextEntryPresented)
        XCTAssertEqual(state.textEntryDraft, "hello")

        state.finishTextEntry()
        XCTAssertFalse(state.isTextEntryPresented)
        XCTAssertEqual(state.textEntryDraft, "")
    }
}

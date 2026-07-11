import Foundation

struct SendEntryPresentationState {
    var isFileImporterPresented = false
    var isFolderImporterPresented = false
    var isTextEntryPresented = false
    var textEntryDraft = ""

    mutating func beginFiles() {
        isFileImporterPresented = true
    }

    mutating func beginFolders() {
        isFolderImporterPresented = true
    }

    mutating func beginTextEntry(prefilledText: String = "") {
        textEntryDraft = prefilledText
        isTextEntryPresented = true
    }

    mutating func finishTextEntry() {
        isTextEntryPresented = false
        textEntryDraft = ""
    }
}

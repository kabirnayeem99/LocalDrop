import Foundation
import Testing
@testable import LocalSendKit

struct ModelTests {
    @Test func deviceTypeUnknownFallsBackToDesktop() throws {
        let data = Data(#""spaceship""#.utf8)
        #expect(try JSONDecoder().decode(DeviceType.self, from: data) == .desktop)
        #expect(try JSONDecoder().decode(DeviceType.self, from: Data(#""WEB""#.utf8)) == .web)
    }

    @Test func protocolTypeSerializesLowercase() throws {
        let data = try JSONEncoder().encode(ProtocolType.https)
        #expect(String(decoding: data, as: UTF8.self) == #""https""#)
    }

    @Test func multicastMessageEncodesAnnounceAndAnnouncement() throws {
        let message = MulticastMessage(
            alias: "Mac",
            fingerprint: "ABC",
            port: 53317,
            protocolType: .https,
            announce: true
        )

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        #expect(object?["announce"] as? Bool == true)
        #expect(object?["announcement"] as? Bool == true)
    }

    @Test func multicastMessageDecodesEitherAnnouncementFlag() throws {
        let data = Data(#"{"alias":"Mac","version":"2.0","fingerprint":"A","port":53317,"protocol":"https","announcement":true}"#.utf8)
        let decoded = try JSONDecoder().decode(MulticastMessage.self, from: data)
        #expect(decoded.announce == true)
        #expect(decoded.announcement == true)
    }

    @Test func fileDTOOmitsOptionalFields() throws {
        let file = FileDto(id: "1", fileName: "a.txt", size: 1, fileType: "text/plain")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any]
        #expect(object?["sha256"] == nil)
        #expect(object?["preview"] == nil)
        #expect(object?["metadata"] == nil)
    }

    /// Mirrors `file_dto.dart:66-73`: a value with a `/` is decoded as a MIME type (`text/…` is
    /// text), anything else is matched against the bare `FileType` enum case name.
    @Test func fileDTOTextPayloadMatchesBothWireFormsOfTheTextFileType() {
        func file(_ fileType: String) -> FileDto {
            FileDto(id: "1", fileName: "a", size: 1, fileType: fileType)
        }

        // Bare enum name.
        #expect(file("text").isTextPayload)
        #expect(file("TEXT").isTextPayload)
        #expect(file(" text ").isTextPayload)

        // MIME form via `decodeFromMime`.
        #expect(file("text/plain").isTextPayload)
        #expect(file("Text/Markdown").isTextPayload)

        // Everything else decodes to some other `FileType`.
        #expect(file("image/jpeg").isTextPayload == false)
        #expect(file("application/pdf").isTextPayload == false)
        #expect(file("application/octet-stream").isTextPayload == false)
        #expect(file("textual").isTextPayload == false)
        #expect(file("").isTextPayload == false)
    }

    /// Mirrors `receive_session_state.dart:63-68`: a text file that *carries* a preview is a
    /// message. A text file with no preview at all is a plain document.
    @Test func fileDTOMessagePayloadRequiresTextTypeAndPresentPreview() {
        func file(_ fileType: String, preview: String?) -> FileDto {
            FileDto(id: "1", fileName: "a", size: 1, fileType: fileType, preview: preview)
        }

        #expect(file("text", preview: "hello").isMessagePayload)
        #expect(file("text/plain", preview: "hello").isMessagePayload)
        #expect(file("text", preview: nil).isMessagePayload == false)
        // Presence, not content: the reference's `firstFile.preview != null` is satisfied by the
        // empty string, so an empty message prompts instead of being quick-saved to disk.
        #expect(file("text", preview: "").isMessagePayload)
        #expect(file("text/plain", preview: "").isMessagePayload)
        #expect(file("image/jpeg", preview: "base64-thumbnail").isMessagePayload == false)
        #expect(file("image/jpeg", preview: "").isMessagePayload == false)
    }

    @Test func dtoRoundTrips() throws {
        let response = PrepareDownloadResponse(
            info: InfoResponse(alias: "Mac", fingerprint: "AAA", download: true),
            sessionId: "session",
            files: [
                "f1": FileDto(
                    id: "f1",
                    fileName: "test.jpg",
                    size: 42,
                    fileType: "image/jpeg",
                    sha256: "HASH",
                    preview: "PREVIEW",
                    metadata: FileMetadata(modified: "2024-01-01T00:00:00Z")
                )
            ]
        )
        let roundTrip = try JSONDecoder().decode(PrepareDownloadResponse.self, from: JSONEncoder().encode(response))
        #expect(roundTrip == response)
        #expect(MulticastMessage(alias: "Mac", fingerprint: "AAA", port: 1, protocolType: .https, announce: false).registerInfo.protocolType == .https)
        #expect(RegisterInfo(alias: "Mac", fingerprint: "BBB", port: 2, protocolType: .http, download: true).asInfoResponse.download)
        #expect(InfoResponse(alias: "Info", fingerprint: "CCC", download: false).alias == "Info")
    }
}

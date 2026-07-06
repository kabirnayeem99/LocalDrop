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

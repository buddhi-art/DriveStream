import Foundation
import XCTest

final class SharedDriveModelTests: XCTestCase {
    func testSharedDriveListUsesStableIDsAndSingleLineUnicodeNames() throws {
        let output = #"[{"id":"Drive_1","name":" Design\n東京 "},{"id":"Drive_1","name":"duplicate"},{"id":"Drive-2","name":"Finance"}]"#
        XCTAssertEqual(try GoogleSharedDrive.decodeList(output), [
            GoogleSharedDrive(id: "Drive_1", name: "Design 東京"),
            GoogleSharedDrive(id: "Drive-2", name: "Finance")
        ])
        XCTAssertTrue(try GoogleSharedDrive.decodeList("[]").isEmpty)
    }

    func testMalformedOrUnboundedListsFailClosed() {
        for value in ["{}", "null", "noise", "[{\"id\":\"../bad\",\"name\":\"x\"}]", "[{\"id\":\"valid\"}]"] {
            XCTAssertThrowsError(try GoogleSharedDrive.decodeList(value))
        }
        XCTAssertThrowsError(try GoogleSharedDrive.decodeList(String(repeating: " ", count: 1_048_577)))
        let excessive = Array(repeating: GoogleSharedDrive(id: "valid", name: "Name"), count: 4_097)
        let json = "[" + excessive.map { _ in #"{"id":"valid","name":"Name"}"# }.joined(separator: ",") + "]"
        XCTAssertThrowsError(try GoogleSharedDrive.decodeList(json))
    }

    func testRootIDValidationAndSettingsMigration() throws {
        for value in ["../x", "drive:other", "drive\n[extra]", "é", String(repeating: "x", count: 257)] {
            XCTAssertFalse(GoogleSharedDrive.validID(value))
        }
        XCTAssertTrue(GoogleSharedDrive.validID("AZ_az-09"))
        var draft = try JSONDecoder().decode(StreamConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(draft.sharedDriveID.isEmpty)
        let previous = draft
        draft.sharedDriveID = "Drive_1"
        XCTAssertTrue(draft.mountProfileDiffers(from: previous))
        XCTAssertEqual(try JSONDecoder().decode(StreamConfig.self, from: JSONEncoder().encode(draft)), draft)
        draft.sharedDriveID = "../bad"
        XCTAssertNotNil(draft.validationError)
    }

    func testMountIssuesNeverRetainRawLogText() {
        let log = #"/Users/PRIVATE_USER/PRIVATE_FILE http://127.0.0.1:12345/ {"access_token":"PRIVATE_TOKEN"} malformed_PRIVATE_SECRET"#
        for reason in ["invalid_grant", "not empty", "unknown flag", "429", "network is unreachable", "macFUSE", "unexpected exit"] {
            let issue = DriveStreamIssue.mountFailure(description: reason + log, log: log)
            let visible = issue.title + issue.summary + issue.details
            XCTAssertFalse(visible.contains("PRIVATE_"))
            XCTAssertFalse(visible.contains("127.0.0.1"))
            XCTAssertTrue(issue.details.contains("Open Logs"))
        }
    }

    func testCacheNamespacesCannotEscapeThePrivateRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/private-cache", isDirectory: true)
        XCTAssertEqual(try RcloneDriveRootService.cacheDirectory(namespace: nil, root: root), root)
        let namespace = UUID().uuidString.lowercased()
        XCTAssertEqual(try RcloneDriveRootService.cacheDirectory(namespace: namespace, root: root),
                       root.appendingPathComponent("mount-roots").appendingPathComponent(namespace, isDirectory: true))
        for value in ["../outside", "/absolute", "invalid"] {
            XCTAssertThrowsError(try RcloneDriveRootService.cacheDirectory(namespace: value, root: root))
        }
    }
}

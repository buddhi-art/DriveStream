import Foundation
import XCTest

/// Offline installer regressions: no downloads, helper execution or user paths.
final class RcloneDownloadTests: XCTestCase {
    func testVersionedReleaseURLsAndArchiveIdentity() throws {
        XCTAssertEqual(RcloneDownloads.versionURL.absoluteString, "https://downloads.rclone.org/version.txt")
        for version in ["v1.75.2", "v1.76.0"] {
            for architecture in ["arm64", "amd64"] {
                let release = try RcloneDownloads.Release(
                    versionText: "rclone \(version)", architecture: architecture
                )
                let filename = "rclone-\(version)-osx-\(architecture).zip"
                let directory = "https://downloads.rclone.org/\(version)/"
                XCTAssertEqual(release.version, version)
                XCTAssertEqual(release.architecture, architecture)
                XCTAssertEqual(release.archiveName, filename)
                XCTAssertEqual(release.downloadURL.absoluteString, directory + filename)
                XCTAssertEqual(release.checksumURL.absoluteString, directory + "SHA256SUMS")
                XCTAssertEqual(release.downloadURL.lastPathComponent, release.archiveName)
                XCTAssertEqual(release.downloadURL.deletingLastPathComponent(), release.checksumURL.deletingLastPathComponent())
                XCTAssertFalse(release.downloadURL.absoluteString.contains("rclone-current"))
            }
        }
    }

    func testOfficialVersionLineAllowsSurroundingWhitespace() throws {
        let release = try RcloneDownloads.Release(
            versionText: " \nrclone v1.75.2\r\n \t", architecture: "arm64"
        )
        XCTAssertEqual(release.version, "v1.75.2")
        XCTAssertEqual(release.downloadURL.absoluteString, "https://downloads.rclone.org/v1.75.2/rclone-v1.75.2-osx-arm64.zip")
    }

    func testUnsupportedArchitectureIsRejected() {
        for architecture in ["", "x86_64", "aarch64", "arm64e", "ARM64", "amd64/../arm64"] {
            XCTAssertThrowsError(try RcloneDownloads.Release(versionText: "rclone v1.75.2", architecture: architecture)) { error in
                guard case .unsupportedArchitecture(let rejected) = error as? DependencyError else {
                    return XCTFail("Expected unsupported architecture, got \(error)")
                }
                XCTAssertEqual(rejected, architecture)
            }
        }
    }

    func testMalformedVersionCannotSelectARelease() {
        let versions = [
            "", "v1.75.2", "rclone 1.75.2", "rclone v1.75",
            "rclone v1.75.2.1", "rclone v1.75.2-beta.1", "rclone v1.75.2+build",
            "rclone v1.75.2/../v1.76.0", "rclone v1.75.2?download=other",
            "rclone v1.75.2#other", "rclone v1.75.2\nrclone v1.76.0",
            "rclone\tv1.75.2", "rclone v١.75.2", "rclone v1.75.2\0"
        ]
        for versionText in versions {
            XCTAssertThrowsError(try RcloneDownloads.Release(versionText: versionText, architecture: "amd64")) { error in
                guard case .verificationFailed = error as? DependencyError else {
                    return XCTFail("Expected invalid release version, got \(error)")
                }
            }
        }
    }

    func testChecksumSelectsOnlyTheSameVersionAndArchitecture() throws {
        let expected = String(repeating: "a", count: 64)
        let wrong = String(repeating: "b", count: 64)
        for architecture in ["arm64", "amd64"] {
            let release = try RcloneDownloads.Release(versionText: "rclone v1.75.2", architecture: architecture)
            let otherArchitecture = architecture == "arm64" ? "amd64" : "arm64"
            let unrelated = """
            \(wrong)  rclone-v1.75.2-osx-\(otherArchitecture).zip
            \(wrong)  rclone-v1.76.0-osx-\(architecture).zip
            \(wrong)  rclone-current-osx-\(architecture).zip
            \(wrong)  \(release.archiveName).extra
            """
            XCTAssertNil(DependencyArchiveSafety.checksum(in: unrelated, for: release.archiveName))
            let manifest = unrelated + "\n" + expected.uppercased() + " *" + release.archiveName + "\n"
            XCTAssertEqual(DependencyArchiveSafety.checksum(in: manifest, for: release.archiveName), expected)
        }
    }

    func testMissingMalformedAndDuplicateChecksumsAreRejected() throws {
        let release = try RcloneDownloads.Release(versionText: "rclone v1.75.2", architecture: "arm64")
        let digest = String(repeating: "a", count: 64)
        let entry = digest + "  " + release.archiveName + "\n"
        let manifests = [
            "",
            String(repeating: "a", count: 63) + "  " + release.archiveName,
            String(repeating: "a", count: 65) + "  " + release.archiveName,
            String(repeating: "g", count: 64) + "  " + release.archiveName,
            digest + "  " + release.archiveName + " extra-field",
            entry + entry,
            entry + String(repeating: "b", count: 64) + " *" + release.archiveName + "\n"
        ]
        for manifest in manifests {
            XCTAssertNil(DependencyArchiveSafety.checksum(in: manifest, for: release.archiveName))
        }
    }

    @MainActor
    func testArchiveHashGateRejectsMismatchAndChangedBytes() async throws {
        let root = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-rclone-hash-tests-")
        defer { ServiceFileSafety.removeTemporaryDirectory(root, prefix: "DriveStream-rclone-hash-tests-") }
        let archive = root.appendingPathComponent("rclone-v1.75.2-osx-arm64.zip")
        try ServiceFileSafety.createPrivateFile(archive, data: Data("abc".utf8))
        let expectedHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try await DependencyManager.verifyArchiveChecksum(at: archive, expectedHash: expectedHash)
        for rejectedHash in ["", "not-a-hash", String(repeating: "0", count: 64), expectedHash + "0"] {
            do {
                try await DependencyManager.verifyArchiveChecksum(at: archive, expectedHash: rejectedHash)
                XCTFail("A mismatched or malformed archive hash must not pass verification")
            } catch let error as DependencyError {
                guard case .checksumMismatch = error else { return XCTFail("Unexpected verification error: \(error)") }
            }
        }
        try ServiceFileSafety.atomicWrite(Data("changed archive bytes".utf8), to: archive)
        do {
            try await DependencyManager.verifyArchiveChecksum(at: archive, expectedHash: expectedHash)
            XCTFail("Changed archive bytes must not pass the selected release hash")
        } catch let error as DependencyError {
            guard case .checksumMismatch = error else { return XCTFail("Unexpected verification error: \(error)") }
        }
    }
}

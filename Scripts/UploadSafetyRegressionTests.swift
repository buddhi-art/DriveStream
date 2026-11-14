import Foundation

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct UploadSafetyRegressionTests {
    static func main() async {
        do { try await run() }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var checks = 0
        func expect(_ value: Bool, _ description: String) throws {
            guard value else { throw RegressionFailure(description: description) }
            checks += 1
            try? FileHandle.standardOutput.write(contentsOf: Data(("PASS: " + description + "\n").utf8))
        }
        let decoder = JSONDecoder()
        func core(_ json: String) throws -> RcloneCoreStats {
            try decoder.decode(RcloneCoreStats.self, from: Data(json.utf8))
        }
        func cache(_ json: String = #"{"diskCache":{"uploadsQueued":0,"uploadsInProgress":0,"erroredFiles":0,"outOfSpace":false}}"#) throws -> RcloneVFSStats {
            try decoder.decode(RcloneVFSStats.self, from: Data(json.utf8))
        }
        let empty = RcloneUploadQueue()
        let absentFatal = try core(#"{"errors":0,"transferring":[]}"#)
        let presentFalse = try core(#"{"fatalError":false,"transferring":[]}"#)
        let presentTrue = try core(#"{"fatalError":true,"transferring":[]}"#)
        let clean = try cache()
        let idleWithoutFlag = UploadSafetySnapshot.assess(queue: empty, vfs: clean, core: absentFatal)
        try expect(idleWithoutFlag.state == .idleObserved, "An omitted fatalError does not make a complete idle queue unknown")
        try expect(!idleWithoutFlag.requiresExitConsent, "Fresh complete idle observation alone does not demand a pending-upload override")
        try expect(UploadSafetySnapshot.assess(queue: empty, vfs: clean, core: presentFalse).state == .idleObserved, "Explicit false fatalError is idle")
        try expect(UploadSafetySnapshot.assess(queue: empty, vfs: clean, core: presentTrue).state == .blocked, "Explicit true fatalError remains blocked")
        let noSpace = try cache(#"{"diskCache":{"uploadsQueued":0,"uploadsInProgress":0,"erroredFiles":0,"outOfSpace":true}}"#)
        try expect(UploadSafetySnapshot.assess(queue: empty, vfs: noSpace, core: absentFatal).state == .blocked, "Out-of-space is not hidden behind a missing fatalError flag")
        let failedCache = try cache(#"{"diskCache":{"uploadsQueued":0,"uploadsInProgress":0,"erroredFiles":1,"outOfSpace":false}}"#)
        try expect(UploadSafetySnapshot.assess(queue: empty, vfs: failedCache, core: absentFatal).state == .blocked, "Cache write errors remain blocked without fatalError")
        let waiting = try cache(#"{"diskCache":{"uploadsQueued":1,"uploadsInProgress":0,"erroredFiles":0,"outOfSpace":false}}"#)
        try expect(UploadSafetySnapshot.assess(queue: empty, vfs: waiting, core: absentFatal).state == .pending, "Pending counters win over a temporarily empty queue")
        let incomplete = try cache(#"{"diskCache":{"uploadsQueued":0,"uploadsInProgress":0,"erroredFiles":0}}"#)
        try expect(UploadSafetySnapshot.assess(queue: empty, vfs: incomplete, core: absentFatal).state == .unknown, "Missing required cache evidence still fails closed")
        try expect(UploadSafetySnapshot.assess(queue: empty, vfs: clean, core: absentFatal, now: .distantPast).requiresExitConsent, "Stale idle observation cannot approve exit")
        try expect(UploadSafetySnapshot.assess(queue: empty, vfs: clean, core: absentFatal, now: Date().addingTimeInterval(60)).requiresExitConsent, "Future-dated idle observation cannot approve exit")
        do {
            _ = try decoder.decode(RcloneUploadQueue.self, from: Data("{}".utf8))
            throw RegressionFailure(description: "Missing queue unexpectedly decoded as empty")
        } catch is DecodingError {
            try expect(true, "Missing queue body is still rejected")
        }

        let root = try ServiceFileSafety.temporaryDirectory(prefix: "DriveStream-issue-regressions-")
        defer { ServiceFileSafety.removeTemporaryDirectory(root, prefix: "DriveStream-issue-regressions-") }
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: false)
        func fixture(_ name: String) throws -> URL {
            let directory = cacheRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return directory
        }
        func put(_ directory: URL, _ name: String, _ bytes: Data) throws {
            let path = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: path)
        }
        let cleanJSON = Data(#"{"Dirty":false,"Size":12}"#.utf8)
        let dirtyJSON = Data(#"{"Dirty":true,"Size":12}"#.utf8)
        let dsStore = Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]) + Data(repeating: 0xCC, count: 80)
        let appleDouble = Data([0, 5, 0x16, 7, 0, 2, 0, 0]) + Data(repeating: 0xDD, count: 80)
        let sidecars = try fixture("sidecars")
        try put(sidecars, "ordinary.bin", cleanJSON)
        try put(sidecars, ".DS_Store", dsStore)
        try put(sidecars, "._ordinary.bin", appleDouble)
        try put(sidecars, "folder/.DS_Store", dsStore)
        let benign = await DirtyCacheInspection.inspect(metadataPath: sidecars.path, cacheRoot: cacheRoot)
        try expect(benign.complete && benign.dirtyFiles == 0, "Verified Finder DS_Store and AppleDouble files do not block an idle cache")
        try expect(try Data(contentsOf: sidecars.appendingPathComponent(".DS_Store")) == dsStore, "Metadata inspection leaves Finder sidecars unchanged")

        let hidden = try fixture("hidden")
        for name in [".env", ".hidden-config", ".nested/ordinary", ".DS_Store", "._actual-json"] {
            try put(hidden, name, dirtyJSON)
        }
        let hiddenResult = await DirtyCacheInspection.inspect(metadataPath: hidden.path, cacheRoot: cacheRoot)
        if !hiddenResult.complete || hiddenResult.dirtyFiles != 5 {
            for name in [".env", ".hidden-config", ".nested/ordinary", ".DS_Store", "._actual-json"] {
                let value = Result { try CacheMetadataReader.read(at: hidden.appendingPathComponent(name)) }
                try? FileHandle.standardError.write(contentsOf: Data("Diagnostic \(name): \(value)\n".utf8))
            }
            try? FileHandle.standardError.write(contentsOf: Data("Hidden scan: \(hiddenResult)\n".utf8))
        }
        try expect(hiddenResult.complete && hiddenResult.dirtyFiles == 5, "Hidden remote metadata, including sidecar-like names containing JSON, is inspected")
        let mixed = try fixture("mixed")
        try put(mixed, ".DS_Store", dsStore)
        try put(mixed, "._x", appleDouble)
        try put(mixed, ".important", dirtyJSON)
        let mixedResult = await DirtyCacheInspection.inspect(metadataPath: mixed.path, cacheRoot: cacheRoot)
        try expect(mixedResult.complete && mixedResult.dirtyFiles == 1, "Finder clutter never hides genuine hidden dirty writes")

        let malformedHidden = try fixture("malformed-hidden")
        try put(malformedHidden, ".private", Data("not metadata".utf8))
        try expect(!(await DirtyCacheInspection.inspect(metadataPath: malformedHidden.path, cacheRoot: cacheRoot)).complete, "Unknown malformed dotfiles still fail closed")
        let fakeSidecar = try fixture("fake-sidecar")
        try put(fakeSidecar, ".DS_Store", Data("not a DS_Store or JSON record".utf8))
        try expect(!(await DirtyCacheInspection.inspect(metadataPath: fakeSidecar.path, cacheRoot: cacheRoot)).complete, "A sidecar filename without the expected format is not blindly skipped")
        let disguised = try fixture("disguised")
        try put(disguised, "ordinary.bin", appleDouble)
        try expect(!(await DirtyCacheInspection.inspect(metadataPath: disguised.path, cacheRoot: cacheRoot)).complete, "AppleDouble-looking bytes under an ordinary metadata name remain invalid")

        let sparse = try fixture("sparse")
        let ranges = (0..<800).map { ["Pos": $0 * 8192, "Size": 4096] }
        let sparseJSON = try JSONSerialization.data(withJSONObject: ["Dirty": true, "Rs": ranges, "Size": 8_000_000])
        try expect(sparseJSON.count > 4096, "Sparse metadata regression really exceeds a single 4 KiB page")
        try put(sparse, "video.bin", sparseJSON)
        try expect(try CacheMetadataReader.read(at: sparse.appendingPathComponent("video.bin")) == .metadata(dirty: true), "Incremental 4 KiB reads support larger valid sparse metadata")
        let sparseResult = await DirtyCacheInspection.inspect(metadataPath: sparse.path, cacheRoot: cacheRoot)
        try expect(sparseResult.complete && sparseResult.dirtyFiles == 1, "Larger valid metadata remains dirty, not unknown")
        try expect(CacheMetadataReader.readChunkBytes == 4096, "Per-read metadata allocation is page-sized")
        try expect(CacheMetadataReader.maximumMetadataBytes == 256 * 1024, "Total per-file input remains bounded without a 4 KiB format limit")

        let oversized = try fixture("oversized")
        let tooBig = Data(#"{"Dirty":false,"padding":""#.utf8)
            + Data(repeating: 0x41, count: CacheMetadataReader.maximumMetadataBytes) + Data(#""}"#.utf8)
        try put(oversized, "large.bin", tooBig)
        try expect(!(await DirtyCacheInspection.inspect(metadataPath: oversized.path, cacheRoot: cacheRoot)).complete, "Oversized ordinary metadata fails closed")
        let largeSidecar = try fixture("large-sidecar")
        try put(largeSidecar, ".DS_Store", dsStore + Data(repeating: 0xAA, count: 300 * 1024))
        try expect((await DirtyCacheInspection.inspect(metadataPath: largeSidecar.path, cacheRoot: cacheRoot)).complete, "Large verified Finder sidecar can be classified from a bounded prefix")
        let links = try fixture("links")
        let outside = root.appendingPathComponent("outside.json")
        try dirtyJSON.write(to: outside)
        try FileManager.default.createSymbolicLink(at: links.appendingPathComponent(".DS_Store"), withDestinationURL: outside)
        try expect(!(await DirtyCacheInspection.inspect(metadataPath: links.path, cacheRoot: cacheRoot)).complete, "Sidecar-named symbolic links never bypass containment checks")
        try expect(try Data(contentsOf: outside) == dirtyJSON, "Read-only scan does not alter outside data")
        let empties = try fixture("empty")
        try put(empties, "blank.bin", Data())
        try expect(!(await DirtyCacheInspection.inspect(metadataPath: empties.path, cacheRoot: cacheRoot)).complete, "Empty metadata is not treated as clean")
        print("All \(checks) upload-safety and cache-metadata issue regressions passed.")
    }
}

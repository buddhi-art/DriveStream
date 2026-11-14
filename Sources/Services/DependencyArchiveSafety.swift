import CryptoKit
import Foundation

/// HTTPS-published hashes provide integrity, not a pinned signing identity.
/// Never run the downloaded helper before its official versioned checksum matches.
enum DependencyArchiveSafety {
    static func checksum(in text: String, for filename: String) -> String? {
        var matches: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let digest = String(fields[0]).lowercased()
            let name = fields[1].hasPrefix("*") ? String(fields[1].dropFirst()) : String(fields[1])
            guard name == filename, digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            matches.append(digest)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func fetchData(from url: URL, maximumBytes: Int = 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("DriveStream/1.1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FileDownloadError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw FileDownloadError.httpStatus(http.statusCode) }
        guard response.expectedContentLength <= maximumBytes else { throw FileDownloadError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw FileDownloadError.tooLarge }
            data.append(byte)
            if data.count.isMultiple(of: 1024) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return data
    }

    static func sha256(of url: URL) async throws -> String {
        let worker = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            let digest = try await worker.value
            try Task.checkCancellation()
            return digest
        } onCancel: { worker.cancel() }
    }

    /// Parse the bounded ZIP central directory, reject traversal/symlinks/duplicates
    /// and ZIP64/multi-volume ambiguity, and extract ONLY the expected executable.
    /// Other entries can never create files or symlinks during extraction.
    static func rcloneMember(in archive: URL, version: String, architecture: String) throws -> String {
        let expected = "rclone-\(version)-osx-\(architecture)/rclone"
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw invalidArchive() }
        let tailSize = min(size, 65_557)
        try handle.seek(toOffset: size - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        let bytes = [UInt8](tail)
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: 0, by: -1) {
            if u32(bytes, offset) == 0x06054b50,
               offset + 22 + Int(u16(bytes, offset + 20)) == bytes.count {
                end = offset; break
            }
        }
        guard let end, u16(bytes, end + 4) == 0, u16(bytes, end + 6) == 0,
              u16(bytes, end + 8) == u16(bytes, end + 10) else { throw invalidArchive() }
        let count = Int(u16(bytes, end + 10))
        let directorySize = Int(u32(bytes, end + 12))
        let directoryOffset = UInt64(u32(bytes, end + 16))
        guard count > 0, count <= 1_000, directorySize <= 1024 * 1024,
              directoryOffset + UInt64(directorySize) == size - tailSize + UInt64(end) else { throw invalidArchive() }
        try handle.seek(toOffset: directoryOffset)
        let central = [UInt8](try handle.read(upToCount: directorySize) ?? Data())
        guard central.count == directorySize else { throw invalidArchive() }
        var offset = 0
        var names: Set<String> = []
        var found = false
        var totalExpanded: UInt64 = 0
        for _ in 0..<count {
            try Task.checkCancellation()
            guard offset + 46 <= central.count, u32(central, offset) == 0x02014b50 else { throw invalidArchive() }
            let nameLength = Int(u16(central, offset + 28))
            let extraLength = Int(u16(central, offset + 30))
            let commentLength = Int(u16(central, offset + 32))
            let next = offset + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, next <= central.count, u16(central, offset + 34) == 0,
                  u16(central, offset + 8) & 1 == 0 else { throw invalidArchive() }
            let nameData = Data(central[(offset + 46)..<(offset + 46 + nameLength)])
            guard let name = String(data: nameData, encoding: .utf8), safeMemberName(name),
                  names.insert(name).inserted else { throw invalidArchive() }
            let mode = (u32(central, offset + 38) >> 16) & 0o170000
            guard mode == 0 || mode == 0o100000 || (mode == 0o040000 && name.hasSuffix("/")) else { throw invalidArchive() }
            let expanded = UInt64(u32(central, offset + 24))
            totalExpanded += expanded
            guard totalExpanded <= 1024 * 1024 * 1024 else { throw invalidArchive() }
            if name == expected {
                guard mode != 0o040000, expanded > 0, expanded <= 256 * 1024 * 1024 else { throw invalidArchive() }
                let localOffset = UInt64(u32(central, offset + 42))
                guard localOffset + 30 < directoryOffset else { throw invalidArchive() }
                try handle.seek(toOffset: localOffset)
                let local = [UInt8](try handle.read(upToCount: 30) ?? Data())
                guard local.count == 30, u32(local, 0) == 0x04034b50,
                      u16(local, 26) == UInt16(nameLength), u16(local, 6) == u16(central, offset + 8),
                      u16(local, 8) == u16(central, offset + 10) else { throw invalidArchive() }
                let localName = try handle.read(upToCount: nameLength) ?? Data()
                guard localName == nameData else { throw invalidArchive() }
                found = true
            }
            offset = next
        }
        guard offset == central.count, found else { throw DependencyError.binaryNotFoundInArchive }
        return expected
    }

    static func safeMemberName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return components.enumerated().allSatisfy { index, component in
            component != "." && component != ".." && (!component.isEmpty || index == components.count - 1)
        }
    }

    private static func invalidArchive() -> DependencyError {
        .archiveExtractionFailed("The archive has unsafe or unsupported ZIP entries.")
    }
    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | UInt32(u16(bytes, offset + 2)) << 16
    }
}

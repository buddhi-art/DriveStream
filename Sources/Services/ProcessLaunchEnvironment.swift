import Darwin
import Foundation

/// Deliberately small helper environment. Never forward the app's inherited API
/// keys, loader hooks, cloud credentials, or arbitrary rclone configuration.
enum ProcessLaunchEnvironment {
    // System tools win over user-installed helpers; never search cwd or an inherited PATH.
    static let trustedPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    // Go's HTTP transport (used by rclone) supports these six spellings. ALL_PROXY,
    // PAC, arbitrary certificate paths and CGI variables are intentionally unsupported.
    static let proxyKeys: Set<String> = [
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"
    ]
    // OAuth helpers and the app's private mount RC endpoint may deliberately
    // supply these credentials. They are NEVER inherited, even when they exist in
    // the parent environment. RC password transport must not reintroduce argv secrets.
    private static let credentialOverrideKeys: Set<String> = [
        "RCLONE_DRIVE_CLIENT_ID", "RCLONE_DRIVE_CLIENT_SECRET", "RCLONE_RC_PASS"
    ]

    static func make(overrides: [String: String]? = nil) -> [String: String] {
        make(inherited: ProcessInfo.processInfo.environment, overrides: overrides)
    }

    /// Separate policy input makes leakage/override regression tests deterministic.
    static func make(inherited: [String: String], overrides: [String: String]? = nil) -> [String: String] {
        var result = [
            "PATH": trustedPath,
            "HOME": realHomeDirectory(),
            "TMPDIR": realTemporaryDirectory(),
            // Stable installed macOS UTF-8 locale, not attacker-supplied LC_* values.
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8"
        ]
        for key in proxyKeys {
            if let value = inherited[key], safeEnvironmentValue(value) { result[key] = value }
        }
        for (key, value) in overrides ?? [:] {
            guard (proxyKeys.contains(key) || credentialOverrideKeys.contains(key)),
                  safeEnvironmentValue(value) else { continue }
            result[key] = value
        }
        return result
    }

    private static func safeEnvironmentValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func realHomeDirectory() -> String {
        // getpwuid_r is reentrant and ignores forged HOME. Do not use getpwuid's
        // shared buffer from concurrent detached command workers.
        var record = passwd()
        var entry: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let home: String? = buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(getuid(), &record, storage.baseAddress, storage.count, &entry) == 0,
                  entry != nil, let directory = record.pw_dir else { return nil }
            return String(cString: directory)
        }
        if let home, home.hasPrefix("/") { return home }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func realTemporaryDirectory() -> String {
        // Darwin's per-user private temp location, independent of inherited TMPDIR.
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if length > 0 && length <= 16_384 {
            var buffer = [CChar](repeating: 0, count: length)
            let path = buffer.withUnsafeMutableBufferPointer { storage -> String? in
                guard confstr(_CS_DARWIN_USER_TEMP_DIR, storage.baseAddress, storage.count) == length,
                      let address = storage.baseAddress else { return nil }
                return String(cString: address)
            }
            if let path, path.hasPrefix("/") { return path }
        }
        return "/private/tmp/"
    }
}

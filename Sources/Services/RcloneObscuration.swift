import CommonCrypto
import Foundation
import Security

/// Interoperable with rclone fs/config/obscure: AES-256-CTR, random 16-byte IV,
/// published fixed key, and unpadded URL-safe base64 of IV + ciphertext.
/// This is reversible OBSCURATION, NOT encryption or access control. The private
/// config still contains recoverable crypt keys; no Touch ID lock is implied.
/// https://github.com/rclone/rclone/blob/v1.75.2/fs/config/obscure/obscure.go
enum RcloneObscuration {
    private static let key: [UInt8] = [
        0x9c, 0x93, 0x5b, 0x48, 0x73, 0x0a, 0x55, 0x4d,
        0x6b, 0xfd, 0x7c, 0x63, 0xc8, 0x86, 0xa9, 0x2b,
        0xd3, 0x90, 0x19, 0x8e, 0xb8, 0x12, 0x8a, 0xfb,
        0xf4, 0xde, 0x16, 0x2b, 0x8b, 0x95, 0xf6, 0x38
    ]
    private static let blockSize = 16

    enum Failure: LocalizedError {
        case randomSource, invalidValue, crypto, tooLarge
        var errorDescription: String? {
            switch self {
            case .randomSource: "Could not generate a password obscuration IV."
            case .invalidValue: "Invalid rclone obscured password."
            case .crypto: "Could not transform the rclone obscured password."
            case .tooLarge: "The password is too large."
            }
        }
    }

    static func obscure(_ value: String) throws -> String {
        var iv = [UInt8](repeating: 0, count: blockSize)
        let status = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, blockSize, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.randomSource }
        return try obscure(value, iv: Data(iv))
    }

    /// An explicit IV exists only for official fixed-vector tests; production must
    /// use obscure(_:) above so the cryptographically random IV is never reused.
    static func obscure(_ value: String, iv: Data) throws -> String {
        let plaintext = Data(value.utf8) // No trim, line reader, NUL termination or argv conversion.
        guard plaintext.count <= Int(Int32.max) - blockSize else { throw Failure.tooLarge }
        let ciphertext = try transform(plaintext, iv: iv)
        return (iv + ciphertext).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func reveal(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), value.utf8.count % 4 != 1 else { throw Failure.invalidValue }
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), bytes.count >= blockSize else { throw Failure.invalidValue }
        let plaintext = try transform(Data(bytes.dropFirst(blockSize)), iv: Data(bytes.prefix(blockSize)))
        guard let string = String(data: plaintext, encoding: .utf8) else { throw Failure.invalidValue }
        return string
    }

    private static func transform(_ input: Data, iv: Data) throws -> Data {
        guard iv.count == blockSize else { throw Failure.invalidValue }
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), ivBytes.baseAddress,
                    keyBytes.baseAddress, keyBytes.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { throw Failure.crypto }
        defer { CCCryptorRelease(cryptor) }
        if input.isEmpty { return Data() }
        var output = Data(count: input.count)
        let outputCount = output.count
        var written = 0
        let updateStatus = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(cryptor, inputBytes.baseAddress, inputBytes.count,
                                outputBytes.baseAddress, outputCount, &written)
            }
        }
        guard updateStatus == kCCSuccess, written == input.count else { throw Failure.crypto }
        return output
    }
}

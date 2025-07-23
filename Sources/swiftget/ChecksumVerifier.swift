import Foundation
import Crypto
import Logging

struct ChecksumVerifier {
    static func verify(file url: URL, against info: ChecksumInfo, logger: Logger) throws {
        let data = try Data(contentsOf: url)
        let actualHash: String

        switch info.algorithm {
        case .md5:
            actualHash = Insecure.MD5.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        case .sha1:
            actualHash = Insecure.SHA1.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        case .sha256:
            actualHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        }

        if actualHash.lowercased() != info.hash.lowercased() {
            logger.error("Checksum mismatch: expected \(info.hash), got \(actualHash)")
            throw DownloadError.checksumMismatch(expected: info.hash, actual: actualHash)
        }

        logger.info("Checksum verified: \(info.algorithm) = \(actualHash)")
    }
}
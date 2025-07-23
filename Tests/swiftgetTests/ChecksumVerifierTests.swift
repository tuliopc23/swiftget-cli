import XCTest
import Logging
@testable import swiftget

final class ChecksumVerifierTests: XCTestCase {
    private let logger = Logger(label: "test")

    func testVerifyMD5Success() throws {
        let data = Data([1, 2, 3, 4])
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_md5.dat")
        try data.write(to: tmpFile)
        let hash = Insecure.MD5.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let info = ChecksumInfo(algorithm: .md5, hash: hash)
        XCTAssertNoThrow(try ChecksumVerifier.verify(file: tmpFile, against: info, logger: logger))
        try? FileManager.default.removeItem(at: tmpFile)
    }

    func testVerifySHA256Mismatch() throws {
        let data = Data([5, 6, 7, 8])
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_sha256.dat")
        try data.write(to: tmpFile)
        let wrongHash = String(repeating: "0", count: 64)
        let info = ChecksumInfo(algorithm: .sha256, hash: wrongHash)
        XCTAssertThrowsError(try ChecksumVerifier.verify(file: tmpFile, against: info, logger: logger))
        try? FileManager.default.removeItem(at: tmpFile)
    }
}
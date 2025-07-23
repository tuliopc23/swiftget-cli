import XCTest
@testable import swiftget

final class SwiftGetTests: XCTestCase {
    func testDownloadConfigurationDefaults() {
        let config = DownloadConfiguration(
            directory: nil,
            output: nil,
            connections: 1,
            maxSpeed: nil,
            userAgent: nil,
            headers: [:],
            proxy: nil,
            checksum: nil,
            continueDownload: false,
            quiet: false,
            verbose: false,
            showProgress: true,
            checkCertificate: true,
            extract: false,
            openInFinder: false
        )
        
        XCTAssertEqual(config.connections, 1)
        XCTAssertEqual(config.effectiveUserAgent, "SwiftGet/2.0.0 (macOS)")
        XCTAssertTrue(config.showProgress)
        XCTAssertTrue(config.checkCertificate)
    }
    
    func testChecksumInfoParsing() {
        let md5Checksum = ChecksumInfo(algorithm: .md5, hash: "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(md5Checksum.hash, "d41d8cd98f00b204e9800998ecf8427e")
        
        let sha256Checksum = ChecksumInfo(algorithm: .sha256, hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sha256Checksum.hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
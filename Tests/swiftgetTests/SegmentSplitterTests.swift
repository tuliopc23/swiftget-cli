import XCTest
@testable import swiftget

final class SegmentSplitterTests: XCTestCase {
    func testSplitEvenSegments() {
        let length: Int64 = 1000
        let segments = MultiConnectionDownloader.splitSegments(contentLength: length, numSegments: 4)
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 249)
        XCTAssertEqual(segments[3].start, 750)
        XCTAssertEqual(segments[3].end, 999)
    }

    func testSplitUnevenSegments() {
        let length: Int64 = 1003
        let segments = MultiConnectionDownloader.splitSegments(contentLength: length, numSegments: 4)
        XCTAssertEqual(segments.count, 4)
        // First three segments get an extra byte
        XCTAssertEqual(segments[0].end, 250)
        XCTAssertEqual(segments[1].start, 251)
        XCTAssertEqual(segments[2].start, 502)
        XCTAssertEqual(segments[3].start, 753)
        XCTAssertEqual(segments[3].end, 1002)
    }
}
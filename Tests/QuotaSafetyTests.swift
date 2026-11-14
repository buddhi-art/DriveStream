import Foundation
import XCTest

final class QuotaSafetyTests: XCTestCase {
    func testNormalFallbackCapacity() {
        XCTAssertEqual(RcloneAbout(used: 40, free: 60).effectiveTotal, 100)
        XCTAssertEqual(RcloneAbout(used: 40, free: 0).effectiveTotal, 40)
    }

    func testFallbackRejectsOverflow() {
        XCTAssertNil(RcloneAbout(used: Int64.max, free: 1).effectiveTotal)
        XCTAssertNil(RcloneAbout(used: 1, free: Int64.max).effectiveTotal)
        XCTAssertNil(RcloneAbout(used: Int64.max, free: Int64.max).effectiveTotal)
    }

    func testFallbackAllowsExactInt64Boundary() {
        XCTAssertEqual(RcloneAbout(used: Int64.max - 1, free: 1).effectiveTotal, Int64.max)
        XCTAssertEqual(RcloneAbout(used: 1, free: Int64.max - 1).effectiveTotal, Int64.max)
        XCTAssertEqual(RcloneAbout(used: Int64.max, free: 0).effectiveTotal, Int64.max)
    }

    func testExplicitPositiveTotalTakesPrecedence() {
        XCTAssertEqual(RcloneAbout(total: 100, used: 40, free: 70).effectiveTotal, 100)
        XCTAssertEqual(RcloneAbout(total: 100, used: Int64.max, free: 1).effectiveTotal, 100)
        XCTAssertEqual(RcloneAbout(total: Int64.max, used: Int64.max, free: Int64.max).effectiveTotal, Int64.max)
        XCTAssertEqual(RcloneAbout(total: 100, used: -1, free: -1).effectiveTotal, 100)
        XCTAssertEqual(RcloneAbout(total: 100).effectiveTotal, 100)
    }

    func testInvalidTotalUsesFallback() {
        XCTAssertEqual(RcloneAbout(total: 0, used: 40, free: 60).effectiveTotal, 100)
        XCTAssertEqual(RcloneAbout(total: -1, used: 40, free: 60).effectiveTotal, 100)
        XCTAssertNil(RcloneAbout(total: 0, used: Int64.max, free: 1).effectiveTotal)
        XCTAssertNil(RcloneAbout(total: -1).effectiveTotal)
    }

    func testFallbackRequiresBothComponents() {
        XCTAssertNil(RcloneAbout().effectiveTotal)
        XCTAssertNil(RcloneAbout(used: 40).effectiveTotal)
        XCTAssertNil(RcloneAbout(free: 60).effectiveTotal)
        XCTAssertNil(RcloneAbout(used: 0).effectiveTotal)
        XCTAssertNil(RcloneAbout(free: 0).effectiveTotal)
    }

    func testFallbackRejectsNegativeComponents() {
        XCTAssertNil(RcloneAbout(used: -1, free: 100).effectiveTotal)
        XCTAssertNil(RcloneAbout(used: 100, free: -1).effectiveTotal)
        XCTAssertNil(RcloneAbout(used: 1, free: -1).effectiveTotal)
        XCTAssertNil(RcloneAbout(used: 1, free: -2).effectiveTotal)
        XCTAssertNil(RcloneAbout(used: Int64.min, free: Int64.min).effectiveTotal)
    }

    func testZeroUsedCanUsePositiveFreeCapacity() {
        XCTAssertEqual(RcloneAbout(used: 0, free: 100).effectiveTotal, 100)
        XCTAssertEqual(RcloneAbout(used: 0, free: Int64.max).effectiveTotal, Int64.max)
    }

    func testZeroCapacityIsUnavailable() {
        XCTAssertNil(RcloneAbout(used: 0, free: 0).effectiveTotal)
        XCTAssertNil(RcloneAbout(total: 0, used: 0, free: 0).effectiveTotal)
    }

    func testDecodedAboutOverflowAndBoundary() throws {
        let decoder = JSONDecoder()
        let overflow = try decoder.decode(RcloneAbout.self, from: Data(#"{"used":9223372036854775807,"free":1}"#.utf8))
        XCTAssertEqual(overflow.used, Int64.max)
        XCTAssertNil(overflow.effectiveTotal)

        let boundary = try decoder.decode(RcloneAbout.self, from: Data(#"{"used":"9223372036854775806","free":"1"}"#.utf8))
        XCTAssertEqual(boundary.used, Int64.max - 1)
        XCTAssertEqual(boundary.effectiveTotal, Int64.max)

        let explicit = try decoder.decode(RcloneAbout.self, from: Data(#"{"total":100,"used":9223372036854775807,"free":1}"#.utf8))
        XCTAssertEqual(explicit.effectiveTotal, 100)
    }
}

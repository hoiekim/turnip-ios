import XCTest
@testable import Turnip

final class ThumbnailLoaderTests: XCTestCase {
    func testPrefetchRangeIsCenteredAndClampedToBounds() {
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 50, count: 200, radius: 10), 40..<61)
        // Near the start: clamps at 0, does not shift the upper bound to compensate.
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 3, count: 200, radius: 10), 0..<14)
        // Near the end: clamps at count.
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 195, count: 200, radius: 10), 185..<200)
        // Window larger than the list: the whole list.
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 2, count: 5, radius: 10), 0..<5)
    }

    func testPrefetchRangeHandlesDegenerateInputs() {
        XCTAssertTrue(ThumbnailLoader.prefetchRange(around: 0, count: 0, radius: 10).isEmpty)
        // An out-of-range index (stale after a library change) is clamped rather than trapping.
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 500, count: 20, radius: 3), 16..<20)
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: -4, count: 20, radius: 3), 0..<4)
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 5, count: 20, radius: 0), 5..<6)
    }
}

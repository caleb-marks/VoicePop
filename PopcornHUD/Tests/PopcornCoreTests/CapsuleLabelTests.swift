import XCTest
@testable import PopcornCore

final class CapsuleLabelTests: XCTestCase {
    // 7 pt per character - simple, monotonic, deterministic.
    private func width(_ s: String) -> CGFloat { CGFloat(s.count) * 7 }

    func testLabelThatFitsIsUnchanged() {
        XCTAssertEqual(CapsuleLabel.fitted("Recording", maxWidth: 100, measure: width), "Recording")
        XCTAssertEqual(CapsuleLabel.fitted("Transcribing…", maxWidth: 91, measure: width), "Transcribing…")
    }

    func testOverflowIsTruncatedWithEllipsisWithinWidth() {
        let long = "Some very long daemon state text that cannot fit"
        let out = CapsuleLabel.fitted(long, maxWidth: 70, measure: width)
        XCTAssertTrue(out.hasSuffix(CapsuleLabel.ellipsis))
        XCTAssertLessThanOrEqual(width(out), 70)
        XCTAssertTrue(long.hasPrefix(String(out.dropLast())))
        // Longest that fits: 10 chars * 7 = 70 → 9 chars + ellipsis.
        XCTAssertEqual(out.count, 10)
    }

    func testTrailingWhitespaceIsTrimmedBeforeEllipsis() {
        let out = CapsuleLabel.fitted("Model loading please wait", maxWidth: 49, measure: width)
        XCTAssertFalse(out.contains(" …"))
        XCTAssertLessThanOrEqual(width(out), 49)
    }

    func testTinyWidthFallsBackToEllipsis() {
        XCTAssertEqual(CapsuleLabel.fitted("Recording", maxWidth: 3, measure: width), "…")
        XCTAssertEqual(CapsuleLabel.fitted("Recording", maxWidth: 0, measure: width), "…")
    }
}

import XCTest
import AppKit

final class LiveTranscriptTests: XCTestCase {
    @MainActor func testLongTranscriptScrollsToTailOnEveryUpdate() {
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 408, height: 78))
        let text = NSTextView(frame: .zero)
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        for count in [3, 12, 30, 70, 120] {
            let value = (0..<count).map { "Строка \($0): длинная мысль продолжается." }.joined(separator: "\n")
            scroll.apply(stable: value, draft: "Последнее слово", fontSize: 15)
            scroll.layoutSubtreeIfNeeded()
            XCTAssertTrue(text.string.hasSuffix("Последнее слово"))
            XCTAssertGreaterThan(scroll.contentView.bounds.maxY, text.frame.height - 5)
        }
        scroll.apply(stable: "Замена 😀", draft: "хвост", fontSize: 15)
        scroll.layoutSubtreeIfNeeded()
        scroll.apply(stable: "Замена 😁", draft: "готово", fontSize: 15)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(text.string, "Замена 😁 готово")
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.origin.y, 1)
    }
}

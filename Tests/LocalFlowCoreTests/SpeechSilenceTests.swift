import XCTest
@testable import LocalFlowCore

final class SpeechSilenceTests: XCTestCase {
    func testSilenceAndVeryShortTapsDoNotLoadRecognizer() async throws {
        let speech = SpeechEngine()
        for samples in [[Float](), [Float](repeating: 0.1, count: 800), [Float](repeating: 0, count: 16000)] {
            let result = try await speech.recognize(samples)
            XCTAssertTrue(result.text.isEmpty)
            XCTAssertTrue(result.words.isEmpty)
            let loaded = await speech.isLoaded
            XCTAssertFalse(loaded)
        }
    }
}

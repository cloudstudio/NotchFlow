import XCTest
@testable import NotchKit

/// The voice cache turns a 1–3s Piper synthesis into an instant replay. If the
/// key math changes, it either serves the wrong audio or defeats the cache.
final class VoiceCacheKeyTests: XCTestCase {
    func testStableAcrossCalls() {
        XCTAssertEqual(
            Voice.cacheKey(voice: "/v/en_GB-semaine-medium.onnx", line: "Hey, I have a question for you."),
            Voice.cacheKey(voice: "/v/en_GB-semaine-medium.onnx", line: "Hey, I have a question for you.")
        )
    }

    func testDiffersByLine() {
        XCTAssertNotEqual(
            Voice.cacheKey(voice: "/v/v.onnx", line: "Hey"),
            Voice.cacheKey(voice: "/v/v.onnx", line: "Bye")
        )
    }

    func testDiffersByVoiceModel() {
        XCTAssertNotEqual(
            Voice.cacheKey(voice: "/v/amy.onnx", line: "Hey"),
            Voice.cacheKey(voice: "/v/semaine.onnx", line: "Hey")
        )
    }

    func testDependsOnFilenameNotDirectory() {
        // Same model file in a different directory should hit the same cache entry.
        XCTAssertEqual(
            Voice.cacheKey(voice: "/a/v.onnx", line: "Hey"),
            Voice.cacheKey(voice: "/b/v.onnx", line: "Hey")
        )
    }
}

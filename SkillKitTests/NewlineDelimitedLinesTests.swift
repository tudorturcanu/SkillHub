import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class NewlineDelimitedLinesTests: XCTestCase {

    private func lines(_ text: String) async throws -> [String] {
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in Array(text.utf8) { continuation.yield(byte) }
            continuation.finish()
        }
        var result: [String] = []
        for try await line in NewlineDelimitedLines(bytes) { result.append(line) }
        return result
    }

    func testUnicodeLineSeparatorsStayInsideTheirJSONLine() async throws {
        let event = #"{"type":"assistant","text":"a\#u{2028}b\#u{2029}c\#u{0085}d"}"#
        let result = try await lines(event + "\n" + #"{"type":"result"}"# + "\n")
        XCTAssertEqual(result, [event, #"{"type":"result"}"#])
        XCTAssertNotNil(JSONEvent.parse(result[0]))
    }

    func testCRLFAndUnterminatedLastLine() async throws {
        let result = try await lines("one\r\n\ntwo")
        XCTAssertEqual(result, ["one", "", "two"])
    }
}

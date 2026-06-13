import XCTest
@testable import CarelessWhisper

final class GitAnnotationTests: XCTestCase {
    func testDecodesFullPayload() throws {
        let json = """
        {"summary":"Adds overlay","risk":"low","highlights":["Touches init order"]}
        """.data(using: .utf8)!
        let ann = try JSONDecoder().decode(GitAnnotation.self, from: json)
        XCTAssertEqual(ann.summary, "Adds overlay")
        XCTAssertEqual(ann.risk, .low)
        XCTAssertEqual(ann.highlights, ["Touches init order"])
    }

    func testDecodesPartialPayload() throws {
        let json = #"{"summary":"Just a note"}"#.data(using: .utf8)!
        let ann = try JSONDecoder().decode(GitAnnotation.self, from: json)
        XCTAssertEqual(ann.summary, "Just a note")
        XCTAssertNil(ann.risk)
        XCTAssertNil(ann.highlights)
    }

    func testInvalidRiskRejected() {
        let json = #"{"risk":"catastrophic"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(GitAnnotation.self, from: json))
    }

    func testRiskLevelRawValues() {
        XCTAssertEqual(RiskLevel.medium.rawValue, "medium")
        XCTAssertEqual(RiskLevel(rawValue: "high"), .high)
    }
}

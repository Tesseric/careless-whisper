import XCTest
@testable import CarelessWhisper

final class ChangeClassifierTests: XCTestCase {
    func testTestDirectorySegment() {
        XCTAssertEqual(ChangeClassifier.bucket(for: "Tests/DiffStatsTests.swift"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "src/__tests__/foo.js"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "app/spec/models/user.rb"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "e2e/login.ts"), .test)
    }

    func testTestFilenamePatterns() {
        XCTAssertEqual(ChangeClassifier.bucket(for: "Sources/App/AppStateTests.swift"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "pkg/parser_test.go"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "ui/button.test.tsx"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "ui/button.spec.ts"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "scripts/test_parser.py"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "models/user_spec.rb"), .test)
    }

    func testOtherBucket() {
        XCTAssertEqual(ChangeClassifier.bucket(for: "README.md"), .other)
        XCTAssertEqual(ChangeClassifier.bucket(for: "Package.resolved"), .other)
        XCTAssertEqual(ChangeClassifier.bucket(for: ".gitignore"), .other)
        XCTAssertEqual(ChangeClassifier.bucket(for: "config/app.yml"), .other)
        XCTAssertEqual(ChangeClassifier.bucket(for: "Cargo.lock"), .other)
    }

    func testFunctionalBucket() {
        XCTAssertEqual(ChangeClassifier.bucket(for: "Sources/App/AppState.swift"), .functional)
        XCTAssertEqual(ChangeClassifier.bucket(for: "src/index.js"), .functional)
        XCTAssertEqual(ChangeClassifier.bucket(for: "data/schema.json"), .functional)
    }

    func testTestRuleWinsOverOther() {
        // A docs/config-extension file inside a test dir is still a test.
        XCTAssertEqual(ChangeClassifier.bucket(for: "src/__tests__/fixtures/sample.json"), .test)
        XCTAssertEqual(ChangeClassifier.bucket(for: "Tests/data/config.yml"), .test)
    }
}

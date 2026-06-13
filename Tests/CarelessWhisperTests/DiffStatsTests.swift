import XCTest
@testable import CarelessWhisper

final class DiffStatsTests: XCTestCase {
    func testParsesAddedRemovedAndFiles() {
        let numstat = """
        120\t12\tSources/App/AppState.swift
        64\t0\tTests/DiffStatsTests.swift
        3\t1\tREADME.md
        """
        let scope = DiffStats.parseScope(numstat: numstat)

        XCTAssertEqual(scope.functional.added, 120)
        XCTAssertEqual(scope.functional.removed, 12)
        XCTAssertEqual(scope.functional.files, 1)

        XCTAssertEqual(scope.test.added, 64)
        XCTAssertEqual(scope.test.files, 1)

        XCTAssertEqual(scope.other.added, 3)
        XCTAssertEqual(scope.other.removed, 1)
        XCTAssertEqual(scope.other.files, 1)

        XCTAssertEqual(scope.total.added, 187)
        XCTAssertEqual(scope.total.removed, 13)
        XCTAssertEqual(scope.total.files, 3)
    }

    func testBinaryFilesCountAsFileWithZeroLines() {
        let numstat = "-\t-\tassets/logo.png"
        let scope = DiffStats.parseScope(numstat: numstat)
        XCTAssertEqual(scope.total.added, 0)
        XCTAssertEqual(scope.total.removed, 0)
        XCTAssertEqual(scope.total.files, 1)
    }

    func testRenameUsesFinalPathForClassification() {
        // git --numstat rename form: "added removed old => new"
        let numstat = "10\t2\tsrc/old.js => Tests/new_test.js"
        let scope = DiffStats.parseScope(numstat: numstat)
        XCTAssertEqual(scope.test.added, 10)
        XCTAssertEqual(scope.test.files, 1)
        XCTAssertEqual(scope.functional.files, 0)
    }

    func testBraceRenameForm() {
        // git --numstat brace rename form: "src/{old => new}/file.swift"
        let numstat = "5\t5\tSources/{Old => New}/Service.swift"
        let scope = DiffStats.parseScope(numstat: numstat)
        XCTAssertEqual(scope.functional.added, 5)
        XCTAssertEqual(scope.functional.files, 1)
    }

    func testEmptyAndBlankInputYieldsZeros() {
        let scope = DiffStats.parseScope(numstat: "")
        XCTAssertEqual(scope.total.added, 0)
        XCTAssertEqual(scope.total.removed, 0)
        XCTAssertEqual(scope.total.files, 0)
    }
}

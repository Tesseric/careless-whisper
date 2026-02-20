import XCTest
@testable import CarelessWhisper

final class AccessibilityInjectorTests: XCTestCase {

    // MARK: - AXInjectionError descriptions

    func testErrorDescriptions() {
        let cases: [(AXInjectionError, String)] = [
            (.noFrontmostApp, "No frontmost application found"),
            (.notATextField("AXButton"), "Focused element is not a text field (role: AXButton)"),
            (.valueNotSettable, "Focused text field value is not settable"),
        ]

        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected)
        }
    }

    func testNoFocusedElementErrorIncludesCode() {
        let error = AXInjectionError.noFocusedElement(.apiDisabled)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("AXError"))
    }

    func testSetValueFailedErrorIncludesCode() {
        let error = AXInjectionError.setValueFailed(.notImplemented)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("AXError"))
    }

    func testReadValueFailedErrorIncludesCode() {
        let error = AXInjectionError.readValueFailed(.attributeUnsupported)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("AXError"))
    }

    func testNoInsertionPointError() {
        let error = AXInjectionError.noInsertionPoint
        XCTAssertEqual(error.errorDescription, "Could not determine insertion point")
    }

    // MARK: - Protocol conformance

    func testAccessibilityInjectorConformsToTextInjector() {
        let injector = AccessibilityInjector()
        XCTAssertTrue(injector is TextInjector)
    }
}

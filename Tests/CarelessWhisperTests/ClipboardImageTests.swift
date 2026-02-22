import XCTest
@testable import CarelessWhisper

final class ClipboardImageTests: XCTestCase {

    // MARK: - ClipboardImageError descriptions

    func testErrorDescriptions() {
        let cases: [(ClipboardImageError, String)] = [
            (.noImageOnClipboard, "No image found on the clipboard."),
            (.failedToReadImage, "Failed to read image from the clipboard."),
            (.failedToConvertPNG, "Failed to convert clipboard image to PNG."),
        ]

        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected)
        }
    }

    func testDirectoryErrorIncludesUnderlyingMessage() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "disk full"])
        let error = ClipboardImageError.failedToCreateDirectory(underlying)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("disk full"))
    }

    func testWriteErrorIncludesUnderlyingMessage() {
        let underlying = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        let error = ClipboardImageError.failedToWriteFile(underlying)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("permission denied"))
    }

    // MARK: - ClipboardImageService

    func testDetectClipboardImageReturnsChangeCount() {
        let service = ClipboardImageService()
        let result = service.detectClipboardImage()
        // changeCount is always a non-negative integer from NSPasteboard
        XCTAssertGreaterThanOrEqual(result.changeCount, 0)
    }

    func testSaveClipboardImageFailsWithoutImage() {
        // Clear the pasteboard so there's no image
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)

        let service = ClipboardImageService()
        XCTAssertThrowsError(try service.saveClipboardImage()) { error in
            XCTAssertTrue(error is ClipboardImageError)
            guard let clipError = error as? ClipboardImageError else { return }
            if case .failedToReadImage = clipError {
                // expected
            } else {
                XCTFail("Expected failedToReadImage, got \(clipError)")
            }
        }
    }
}

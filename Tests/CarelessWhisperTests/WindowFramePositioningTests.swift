import XCTest
import CoreGraphics
@testable import CarelessWhisper

final class WindowFramePositioningTests: XCTestCase {
    // AX coords: origin top-left, y grows downward. Cocoa: origin bottom-left, y grows up.
    func testTopRightConversionOnPrimaryScreen() {
        // Window at AX (100, 50), size 800x600, primary screen height 1000.
        // Top-right X = 100 + 800 = 900. Top edge AX y = 50 → Cocoa y = 1000 - 50 = 950.
        let p = WindowFramePositioning.windowTopRightInCocoa(
            axOrigin: CGPoint(x: 100, y: 50),
            axSize: CGSize(width: 800, height: 600),
            primaryScreenHeight: 1000
        )
        XCTAssertEqual(p.x, 900, accuracy: 0.001)
        XCTAssertEqual(p.y, 950, accuracy: 0.001)
    }

    func testPanelOriginInsetsInsideWindow() {
        // Given the window's top-right Cocoa point, a panel of width 200/height 120 inset 8px
        // sits with its right edge 8px left of the window's right edge, top 8px below the top.
        let origin = WindowFramePositioning.panelOrigin(
            windowTopRightCocoa: CGPoint(x: 900, y: 950),
            panelSize: CGSize(width: 200, height: 120),
            inset: 8
        )
        XCTAssertEqual(origin.x, 900 - 8 - 200, accuracy: 0.001) // 692
        XCTAssertEqual(origin.y, 950 - 8 - 120, accuracy: 0.001) // 822
    }
}

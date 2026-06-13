import SwiftUI
import AppKit

/// NSHostingView subclass that notifies when its SwiftUI content's intrinsic size changes.
/// Shared by the recording HUD and the persistent git overlay.
final class SizeObservingHostingView<Content: View>: NSHostingView<Content> {
    var onIntrinsicSizeInvalidated: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }
}

import SwiftUI

/// Hands the hosting `NSWindow` to SwiftUI once it's available.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in self?.onWindow?(window) }
        }
    }
}

/// Window-level behaviour for compact mode: resizing to a small footprint and
/// floating above other apps.
@MainActor
final class WindowController {
    private weak var window: NSWindow?
    private var expandedFrame: NSRect?
    private static let compactSize = NSSize(width: 540, height: 480)

    func attach(_ window: NSWindow) {
        self.window = window
    }

    func setKeepOnTop(_ onTop: Bool) {
        window?.level = onTop ? .floating : .normal
        // Follow the user across Spaces while pinned, like a floating utility.
        if onTop {
            window?.collectionBehavior.insert(.canJoinAllSpaces)
        } else {
            window?.collectionBehavior.remove(.canJoinAllSpaces)
        }
    }

    func setCompact(_ compact: Bool) {
        guard let window else { return }
        if compact {
            guard window.frame.width > Self.compactSize.width + 40 else { return }
            expandedFrame = window.frame
            // Keep the top-left corner where it is.
            let frame = NSRect(
                x: window.frame.minX,
                y: window.frame.maxY - Self.compactSize.height,
                width: Self.compactSize.width,
                height: Self.compactSize.height
            )
            window.setFrame(frame, display: true, animate: true)
        } else if let expanded = expandedFrame {
            window.setFrame(expanded, display: true, animate: true)
            expandedFrame = nil
        }
    }
}

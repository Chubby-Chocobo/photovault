import AppKit
import PhotoVaultAppSupport
import SwiftUI

/// Tells when the menu bar popup opens and closes, and how tall its screen's visible area is. A
/// `MenuBarExtra` window keeps its SwiftUI content alive between openings, so `onAppear` is no signal; the
/// window itself is. It is ordered in when the popup opens and out when it closes (`isVisible`, observed),
/// and key status is a second signal (`PopupOpenState`). Every report reads the window as it is when the
/// report is made, never a value saved earlier.
struct PopupWindowObserver: NSViewRepresentable {
    var onOpenChange: (_ isOpen: Bool) -> Void
    /// The visible height (without the menu bar and the Dock) of the screen the popup is on.
    var onScreenHeight: (_ visibleScreenHeight: Double) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onOpenChange: onOpenChange, onScreenHeight: onScreenHeight)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onOpenChange = onOpenChange
        view.onScreenHeight = onScreenHeight
    }

    final class ObserverView: NSView {
        var onOpenChange: (Bool) -> Void
        var onScreenHeight: (Double) -> Void
        private var state = PopupOpenState()
        private var visibility: NSKeyValueObservation?
        private static let signals: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
        ]

        init(onOpenChange: @escaping (Bool) -> Void, onScreenHeight: @escaping (Double) -> Void) {
            self.onOpenChange = onOpenChange
            self.onScreenHeight = onScreenHeight
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            visibility = nil
            for name in Self.signals { NotificationCenter.default.removeObserver(self, name: name, object: window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Selector observers go away with this view; the KVO token goes with it too.
            for name in Self.signals {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            visibility = window.observe(\.isVisible) { [weak self] _, _ in
                // KVO arrives on the thread that changed the window, which for a window is the main thread.
                MainActor.assumeIsolated { self?.report() }
            }
            // The window may already be showing; report it after the current update, as it is then.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        @objc private func windowChanged(_ note: Notification) { report() }

        private func report() {
            guard let window else { return }
            if let height = window.screen?.visibleFrame.height { onScreenHeight(Double(height)) }
            if let isOpen = state.update(isVisible: window.isVisible, isKey: window.isKeyWindow) { onOpenChange(isOpen) }
        }
    }
}

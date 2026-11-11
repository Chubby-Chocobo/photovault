import AppKit
import SwiftUI

/// Tells when the menu bar popup opens and closes. A `MenuBarExtra` window keeps its SwiftUI content alive
/// between openings, so `onAppear` is no signal; the window itself is: it becomes key when it opens and stops
/// being key when it closes (it closes because it lost key status).
struct PopupWindowObserver: NSViewRepresentable {
    var onChange: (_ isOpen: Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onChange: onChange)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Selector observers go away with this view, so nothing is left to remove later.
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: window)
            // The window may already be key when this view joins it; report that after the current update.
            let isKey = window.isKeyWindow
            DispatchQueue.main.async { [weak self] in self?.onChange(isKey) }
        }

        @objc private func windowDidBecomeKey(_ note: Notification) { onChange(true) }
        @objc private func windowDidResignKey(_ note: Notification) { onChange(false) }
    }
}

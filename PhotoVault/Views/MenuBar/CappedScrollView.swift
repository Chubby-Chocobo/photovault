import AppKit
import SwiftUI

/// Scrolls its content when it is taller than `limit`, and is exactly as tall as the content otherwise,
/// so a short popover does not grow.
struct CappedScrollView<Content: View>: View {
    var limit: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content()
                .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: contentHeight.map { min($0, limit) })
    }

    /// The visible height of the screen the popover is on, less the room the menu bar, the divider and
    /// the Settings / Quit rows below the content need.
    static var screenLimit: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, visible - 170)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

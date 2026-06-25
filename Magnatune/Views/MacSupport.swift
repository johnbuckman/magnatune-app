import SwiftUI
import UIKit

extension View {
    /// Enables click-and-drag scrolling with a MOUSE on Mac Catalyst for the enclosing
    /// ScrollView (native trackpad/touch scrolling is unaffected). No-op elsewhere.
    /// Apply to the content INSIDE a ScrollView (e.g. the LazyHStack).
    @ViewBuilder func mouseDraggableScroll() -> some View {
        #if targetEnvironment(macCatalyst)
        background(MouseDragScrollEnabler())
        #else
        self
        #endif
    }
}

/// Re-enables the interactive swipe-back (left-edge) gesture even when the navigation
/// bar is hidden — UIKit disables it by default in that case. iPad/iPhone; harmless on Mac.
struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let nav = vc.navigationController else { return }
            context.coordinator.nav = nav
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactivePopGestureRecognizer?.delegate = context.coordinator
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var nav: UINavigationController?
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (nav?.viewControllers.count ?? 0) > 1   // only when there's somewhere to go back to
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Walks up to the enclosing UIScrollView and lets its pan gesture accept mouse
/// (indirect pointer) drags, so a plain mouse can drag-scroll horizontal rows.
private final class FindScrollView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        var v: UIView? = superview
        while let s = v, !(s is UIScrollView) { v = s.superview }
        if let scroll = v as? UIScrollView {
            scroll.panGestureRecognizer.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            ]
        }
    }
}

private struct MouseDragScrollEnabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { FindScrollView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

/// Bridges to the Catalyst window scene to give the app Mac-native window chrome:
/// a clean, title-less title bar (modern unified look) and a sensible minimum size.
/// No-op on iPad apart from the multitasking minimum size.
struct MacWindowConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isHidden = true
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let scene = uiView.window?.windowScene else { return }
            // Resizable from iPhone width up to anything. Below ~600pt wide the UI
            // auto-switches to the compact (iPhone) layout; at/above it shows the sidebar.
            scene.sizeRestrictions?.minimumSize = CGSize(width: 320, height: 568)
            scene.sizeRestrictions?.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude)
            #if targetEnvironment(macCatalyst)
            if let titlebar = scene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
                titlebar.separatorStyle = .none
            }
            #endif
        }
    }
}

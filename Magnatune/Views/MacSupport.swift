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

/// Installs a full-width horizontal swipe recognizer on the key window: swipe-right →
/// back, swipe-left → forward. Unlike the left-edge `interactivePopGestureRecognizer`,
/// it fires anywhere on screen, so "back" works on section-root pages (Popular, Settings,
/// Help, …) and on Mac Catalyst, and "forward" re-does a back you just made. The router
/// owns the actual history; this just calls it.
///
/// Attached to the window (not the navigation controller's view): SwiftUI hosts the
/// NavigationStack content in a way that a recognizer on the UINavigationController's view
/// never receives its touches, whereas the window is the common ancestor of everything.
///
/// Gated so it stays out of the way: ignores touches that start within the left-edge zone
/// (left to the native edge-pop, avoiding a double pop), and touches that begin on a
/// horizontally-scrollable UIScrollView, a UISlider, a UISegmentedControl or the AirPlay
/// route picker. Only a decisive, horizontal-dominant end-gesture triggers navigation, so
/// vertical scrolling and sheet swipe-to-dismiss are unaffected.
struct BackForwardSwipeInstaller: UIViewControllerRepresentable {
    var onBack: () -> Void
    var onForward: () -> Void

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        context.coordinator.onBack = onBack
        context.coordinator.onForward = onForward
        DispatchQueue.main.async {
            guard let host = vc.viewIfLoaded?.window else { return }
            context.coordinator.install(on: host)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBack: () -> Void = {}
        var onForward: () -> Void = {}
        private weak var installedOn: UIView?
        private let edgeZone: CGFloat = 24      // leave the left edge to the native pop gesture
        private let distance: CGFloat = 70      // min horizontal travel to count as a nav swipe
        private static let recognizerName = "magBackForwardNav"

        func install(on view: UIView) {
            guard installedOn !== view else { return }   // this coordinator already installed here
            installedOn = view
            // A previous coordinator (e.g. from a compact↔regular layout switch) may have left
            // one on the same window — remove it so there's exactly one, bound to us.
            view.gestureRecognizers?.forEach {
                if $0.name == Self.recognizerName { view.removeGestureRecognizer($0) }
            }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.name = Self.recognizerName
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            // Tap-suppression comes from the failure requirement below, not from cancelling
            // touches — so leave view touches (and scrolling) untouched.
            pan.cancelsTouchesInView = false
            #if targetEnvironment(macCatalyst)
            pan.allowedScrollTypesMask = []     // don't fire on trackpad/mouse-wheel scroll
            #endif
            view.addGestureRecognizer(pan)
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            guard g.state == .ended, let host = installedOn else { return }
            let t = g.translation(in: host)
            let v = g.velocity(in: host)
            // Decisive, horizontal-dominant gesture only (so vertical scrolls never trigger).
            guard abs(t.x) > distance, abs(t.x) > abs(t.y) * 1.3 else { return }
            guard abs(v.x) > abs(v.y) else { return }
            if t.x > 0 { onBack() } else { onForward() }   // right → back, left → forward
        }

        // Only claim clearly horizontal gestures. Vertical (and diagonal-ish) drags let the
        // pan fail, so scrolling and taps proceed untouched.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let host = installedOn else { return true }
            let v = pan.velocity(in: host)
            return abs(v.x) > abs(v.y)
        }

        // Run alongside scroll pans (so vertical scrolling is unaffected).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer
        }

        // Make taps/buttons wait for our pan: during a horizontal swipe the pan recognizes
        // and the tap is suppressed (no accidental open); otherwise the pan fails on touch-up
        // and the tap fires normally. Scroll/edge pans are excluded so they stay independent.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            !(other is UIPanGestureRecognizer)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let host = installedOn else { return true }
            // Leave the left-edge zone to the native interactive-pop gesture (avoid double back).
            if touch.location(in: host).x < edgeZone { return false }
            // Don't start on controls/scrollers that own horizontal drags.
            var v = touch.view
            while let cur = v {
                if cur is UISlider || cur is UISegmentedControl { return false }
                if String(describing: type(of: cur)).contains("RoutePicker") { return false }
                if let scroll = cur as? UIScrollView,
                   scroll.isScrollEnabled,
                   scroll.contentSize.width > scroll.bounds.width + 1 {
                    return false   // a horizontally-scrollable row (carousels, cover strips)
                }
                v = cur.superview
            }
            return true
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

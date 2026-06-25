import SwiftUI
import UIKit

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
            scene.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 600)
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

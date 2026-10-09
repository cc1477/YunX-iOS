import SwiftUI
import UIKit
import shared

struct ComposeView: UIViewControllerRepresentable {
    @Environment(\.sizeCategory) private var sizeCategory
    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        _ = sizeCategory
        // Compose 1.8.2 reads fontScale during layout. Refresh its views on live
        // Dynamic Type changes without applying a second text-size multiplier.
        func invalidateLayout(_ view: UIView) {
            view.setNeedsLayout()
            view.subviews.forEach(invalidateLayout)
        }
        invalidateLayout(uiViewController.view)
        uiViewController.view.layoutIfNeeded()
    }
}

struct ContentView: View {
    var body: some View {
        ComposeView()
            // Compose owns safe-area and keyboard insets for the whole window.
            .ignoresSafeArea(.all)
    }
}

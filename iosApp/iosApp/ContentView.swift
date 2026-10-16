import SwiftUI
import UIKit
import shared

struct ComposeView: UIViewControllerRepresentable {
    @Environment(\.sizeCategory) private var sizeCategory
    func makeUIViewController(context: Context) -> UIViewController {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--diagnostic-export-test") {
            return DiagnosticExportTestViewControllerKt.DiagnosticExportTestViewController()
        }
        if ProcessInfo.processInfo.arguments.contains("--quark-login-test") {
            return QuarkLoginTestViewControllerKt.QuarkLoginTestViewController()
        }
        #endif
        return MainViewControllerKt.MainViewController()
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
    @Environment(\.scenePhase) private var scenePhase

    private func importSharedLink() {
        let board = UIPasteboard.general
        guard board.contains(pasteboardTypes: [SharePayload.pasteboardType]),
              let data = board.data(forPasteboardType: SharePayload.pasteboardType),
              data.count <= 400_000,
              let payload = try? JSONDecoder().decode(SharePayload.self, from: data),
              payload.isValid else { return }
        let key = "lastImportedShareID"
        guard UserDefaults.standard.string(forKey: key) != payload.id.uuidString else { return }
        if SharedLinkInbox.shared.submit(text: payload.text) {
            UserDefaults.standard.set(payload.id.uuidString, forKey: key)
        }
    }

    var body: some View {
        ComposeView()
            // Compose owns safe-area and keyboard insets for the whole window.
            .ignoresSafeArea(.all)
            .onAppear(perform: importSharedLink)
            .onChange(of: scenePhase) { phase in
                if phase == .active { importSharedLink() }
            }
    }
}

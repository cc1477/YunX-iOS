import UIKit
import UserNotifications
import shared

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var backgroundCompletion: (() -> Void)?
    private var transitionTask: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        IosLifecycleBridge.shared.install()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        guard transitionTask == .invalid else { return }
        // Only a short handoff budget; this does not keep the foreground worker pool alive.
        transitionTask = application.beginBackgroundTask(withName: "YunX download handoff") { [weak self] in
            IosLifecycleBridge.shared.expireBackgroundTransition()
            self?.endTransition(application)
        }
        IosLifecycleBridge.shared.enterBackground { [weak self] in
            self?.endTransition(application)
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        IosLifecycleBridge.shared.enterForeground()
    }

    private func endTransition(_ application: UIApplication) {
        guard transitionTask != .invalid else { return }
        let token = transitionTask
        transitionTask = .invalid
        application.endBackgroundTask(token)
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == "com.yunx.app.bg" else { completionHandler(); return }
        backgroundCompletion = completionHandler
        // Reconnect even on a cold launch, before any SwiftUI/Compose view is created.
        BackgroundSessionBridge.shared.reconnect { [weak self] in
            let completion = self?.backgroundCompletion
            self?.backgroundCompletion = nil
            completion?()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier.hasPrefix("yunx.progress.") {
            completionHandler([])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }
}

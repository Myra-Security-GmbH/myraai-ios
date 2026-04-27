import SwiftUI
import UserNotifications

@main
struct AIGatewayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - App Delegate (APNs registration)

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Start with provisional (silent, no dialog) so the OS token is available immediately.
        // The web layer calls window.Android.requestFullPushPermission() after the user has
        // experienced value (e.g. after receiving a project invite notification).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .provisional]) { _, _ in
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        NativeBridge.pendingDeviceToken = hex
        // Notify the web layer so it can register via the admin API.
        NotificationCenter.default.post(name: .apnsTokenReceived, object: hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Sandbox / simulator — not a fatal error in production
    }

    // Show notification banners even when the app is in the foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                  willPresent notification: UNNotification,
                                  withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    static let apnsTokenReceived = Notification.Name("APNsTokenReceived")
}

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
        // Hard (non-provisional) authorization is REQUIRED: .provisional routes
        // pushes to Quiet Delivery so testers/users never see a banner — that was
        // the bug a prior simplification pass removed, and RegressionGuards T-1
        // (test_first_launch_shows_push_permission_dialog) fails the build if
        // .provisional is re-introduced here. Do not add it back.
        //
        // The push dialog is once-per-install, so any UI test that launches the
        // app before T-1 would consume it and make T-1 flaky. Every UI test
        // EXCEPT T-1 launches with -MyraUITestSuppressPushPrompt so only T-1
        // triggers the prompt — deterministic regardless of test order. DEBUG
        // only; absent from the Release build users get.
        if !AppDelegate.suppressPushPromptForUITest {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        return true
    }

    private static var suppressPushPromptForUITest: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-MyraUITestSuppressPushPrompt")
        #else
        return false
        #endif
    }

    static var apnsToken: String?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppDelegate.apnsToken = hex
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

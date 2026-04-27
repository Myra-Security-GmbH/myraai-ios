import WebKit
import UIKit

// MARK: - Native Bridge (WKScriptMessageHandler)

final class NativeBridge: NSObject, WKScriptMessageHandler {

    static let handlerNames = ["hapticFeedback", "share", "copyToClipboard", "notifyScrollTop", "getDeviceToken", "requestFullPushPermission"]

    // Set by AppDelegate once APNs registration succeeds.
    static var pendingDeviceToken: String?

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {
        case "hapticFeedback": handleHaptic(message.body as? String ?? "light")
        case "share":          handleShare(message.body as? [String: Any] ?? [:])
        case "copyToClipboard":
            if let text = message.body as? String { UIPasteboard.general.string = text }
        case "notifyScrollTop": break
        case "getDeviceToken":  handleGetDeviceToken(message)
        case "requestFullPushPermission": handleRequestFullPushPermission()
        default: break
        }
    }

    // MARK: - Haptic (generators retained before firing for reliable response)

    private func handleHaptic(_ type: String) {
        Task { @MainActor in
            switch type {
            case "light":
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.prepare(); gen.impactOccurred()
            case "medium":
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.prepare(); gen.impactOccurred()
            case "success":
                let gen = UINotificationFeedbackGenerator()
                gen.prepare(); gen.notificationOccurred(.success)
            default:
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.prepare(); gen.impactOccurred()
            }
        }
    }

    // MARK: - Full push permission upgrade (called after user sees value)
    private func handleRequestFullPushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Device token (APNs)
    // JS calls window.Android.getDeviceToken(callbackName) and expects
    // window[callbackName](token) to be invoked with the hex token string.

    private func handleGetDeviceToken(_ message: WKScriptMessage) {
        guard let callbackName = message.body as? String,
              let webView = (message.webView) else { return }
        let token = NativeBridge.pendingDeviceToken ?? ""
        let js = "\(callbackName)(\(token.isEmpty ? "null" : "\"\(token)\""));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Share

    private func handleShare(_ body: [String: Any]) {
        let text = body["text"] as? String ?? ""
        let urlStr = body["url"] as? String ?? ""
        guard !text.isEmpty || !urlStr.isEmpty else { return }
        var items: [Any] = []
        if !text.isEmpty { items.append(text) }
        if !urlStr.isEmpty, let url = URL(string: urlStr) { items.append(url) }
        Task { @MainActor in
            let activityVC = UIActivityViewController(activityItems: items,
                                                      applicationActivities: nil)
            guard let root = UIApplication.shared.keyWindow?.rootViewController else { return }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = root.view
                popover.sourceRect = CGRect(x: root.view.bounds.midX,
                                            y: root.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            root.present(activityVC, animated: true)
        }
    }
}

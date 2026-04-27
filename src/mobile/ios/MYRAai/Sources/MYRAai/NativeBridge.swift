import WebKit
import UIKit

// MARK: - Native Bridge (WKScriptMessageHandler)

final class NativeBridge: NSObject, WKScriptMessageHandler {

    static let handlerNames = ["hapticFeedback", "share", "copyToClipboard", "notifyScrollTop"]

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {
        case "hapticFeedback":
            handleHaptic(message.body as? String ?? "light")
        case "share":
            handleShare(message.body as? [String: Any] ?? [:])
        case "copyToClipboard":
            if let text = message.body as? String {
                UIPasteboard.general.string = text
            }
        case "notifyScrollTop":
            break
        default:
            break
        }
    }

    // MARK: - Haptic
    // Generators are retained in local vars before firing — required for reliable haptics

    private func handleHaptic(_ type: String) {
        Task { @MainActor in
            switch type {
            case "light":
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.prepare()
                gen.impactOccurred()
            case "medium":
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.prepare()
                gen.impactOccurred()
            case "success":
                let gen = UINotificationFeedbackGenerator()
                gen.prepare()
                gen.notificationOccurred(.success)
            default:
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.prepare()
                gen.impactOccurred()
            }
        }
    }

    // MARK: - Share

    private func handleShare(_ body: [String: Any]) {
        let text = body["text"] as? String ?? ""
        let urlStr = body["url"] as? String ?? ""
        var items: [Any] = [text]
        if !urlStr.isEmpty, let url = URL(string: urlStr) {
            items.append(url)
        }
        Task { @MainActor in
            let activityVC = UIActivityViewController(activityItems: items,
                                                      applicationActivities: nil)
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })?.rootViewController else { return }
            root.present(activityVC, animated: true)
        }
    }
}

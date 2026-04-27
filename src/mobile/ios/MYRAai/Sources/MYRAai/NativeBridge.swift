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

    private func handleHaptic(_ type: String) {
        DispatchQueue.main.async {
            switch type {
            case "light":
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "medium":
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "success":
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            default:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        DispatchQueue.main.async {
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

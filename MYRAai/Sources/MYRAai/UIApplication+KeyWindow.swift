import UIKit

extension UIApplication {
    /// Returns the currently active key window, supporting multi-scene setups on iPad.
    var keyWindow: UIWindow? {
        connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
    }
}

extension UIApplication {
    /// The view controller a new sheet/alert should present from: the key window's root, followed down its
    /// `presentedViewController` chain (skipping one that is being dismissed). nil when there is no window.
    func topViewController() -> UIViewController? {
        var top = keyWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }

    /// Presents an activity sheet (share sheet) from the top view controller. On an iPad the popover is anchored
    /// to the middle of the screen with no arrow. `onFailure` runs when there is nothing to present from.
    /// Main thread only.
    func presentSheet(_ sheet: UIActivityViewController, onFailure: () -> Void) {
        guard let top = topViewController() else {
            onFailure()
            return
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}

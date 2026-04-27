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

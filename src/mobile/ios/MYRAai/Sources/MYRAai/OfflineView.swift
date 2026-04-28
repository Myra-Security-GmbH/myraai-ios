import SwiftUI

struct OfflineView: View {
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.brandBackground
            VStack(spacing: 24) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundColor(.brandSubtle)
                    .accessibilityLabel(String(localized: "No internet connection"))

                Text("No Connection", comment: "Offline screen headline")
                    .font(.title2).fontWeight(.semibold)
                    .foregroundColor(.white)

                Text("Check your internet connection\nand try again.",
                     comment: "Offline screen body text")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.brandMuted)

                Button(action: onRetry) {
                    Text("Retry", comment: "Retry button")
                        .font(.body).fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color.brandAccent)
                        .clipShape(.rect(cornerRadius: 10))
                }
                .padding(.top, 8)
            }
            .padding(40)
        }
    }
}

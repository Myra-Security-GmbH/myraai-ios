import SwiftUI

struct OfflineView: View {
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color(red: 13/255, green: 27/255, blue: 42/255)
            VStack(spacing: 24) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundColor(Color(red: 0.49, green: 0.70, blue: 0.83))
                Text("No Connection")
                    .font(.title2).fontWeight(.semibold)
                    .foregroundColor(.white)
                Text("Check your internet connection\nand try again.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color(red: 0.62, green: 0.69, blue: 0.75))
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.body).fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.36, green: 0.77, blue: 0.92))
                        .cornerRadius(10)
                }
                .padding(.top, 8)
            }
            .padding(40)
        }
    }
}

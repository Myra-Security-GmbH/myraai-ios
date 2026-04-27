import SwiftUI

// Shown over the web view until the first page finishes loading,
// preventing the blank white flash on cold start.
struct LaunchOverlay: View {
    var body: some View {
        ZStack {
            Color(red: 13/255, green: 27/255, blue: 42/255)
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
        }
    }
}

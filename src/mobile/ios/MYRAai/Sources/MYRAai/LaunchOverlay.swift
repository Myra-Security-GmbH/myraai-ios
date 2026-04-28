import SwiftUI

struct LaunchOverlay: View {
    @State private var showSpinner = false

    var body: some View {
        ZStack {
            Color.brandBackground
            VStack(spacing: 24) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .accessibilityLabel("MYRA AI")
                    .accessibilityHidden(false)

                // Spinner appears after 1.5 s — signals to user that loading is in progress
                if showSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color.brandAccent)
                        .transition(.opacity)
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeIn(duration: 0.3)) { showSpinner = true }
        }
    }
}

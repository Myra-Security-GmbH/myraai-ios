import SwiftUI

struct LaunchOverlay: View {
    @State private var showSpinner = false

    var body: some View {
        ZStack {
            Color(red: 13/255, green: 27/255, blue: 42/255)
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
                        .tint(Color(red: 0.36, green: 0.77, blue: 0.92))
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

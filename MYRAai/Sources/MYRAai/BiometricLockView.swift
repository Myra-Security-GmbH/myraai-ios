import SwiftUI
import LocalAuthentication

struct BiometricLockView: View {
    let onUnlocked: () -> Void

    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.brandBackground
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("MYRA AI is locked", comment: "Biometric lock screen — headline")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.brandText)
                    Text("Authenticate to continue", comment: "Biometric lock screen — subtitle")
                        .font(.subheadline)
                        .foregroundColor(.brandSubtle)
                }

                if let msg = errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundColor(.brandError)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    authenticate()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: biometryIcon())
                        Text("Unlock", comment: "Biometric lock screen — unlock button")
                    }
                    .font(.body.weight(.medium))
                    .foregroundColor(.white) // white label on the rust accent button
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color.brandAccent)
                    .clipShape(Capsule())
                }
                .disabled(isAuthenticating)
            }
            .padding(40)
        }
        .onAppear { authenticate() }
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // No biometrics + no passcode → unlock; chat-app, not a vault.
            onUnlocked()
            return
        }
        isAuthenticating = true
        errorMessage = nil
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                            localizedReason: String(localized: "Unlock MYRA AI",
                                                     comment: "Biometric prompt reason")) { success, error in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    onUnlocked()
                } else if let e = error as? LAError, e.code == .userCancel {
                    // User dismissed — stay locked, show prompt
                    errorMessage = nil
                } else {
                    errorMessage = error?.localizedDescription
                        ?? String(localized: "Authentication failed",
                                  comment: "Biometric lock screen — generic failure")
                }
            }
        }
    }

    private func biometryIcon() -> String {
        let ctx = LAContext()
        var err: NSError?
        ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        return ctx.biometryType == .faceID ? "faceid" : "touchid"
    }
}

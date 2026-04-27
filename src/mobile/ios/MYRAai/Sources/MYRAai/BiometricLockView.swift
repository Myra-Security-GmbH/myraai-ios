import SwiftUI
import LocalAuthentication

struct BiometricLockView: View {
    let onUnlocked: () -> Void

    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(red: 13/255, green: 27/255, blue: 42/255)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("MYRA AI is locked")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.white)
                    Text("Authenticate to continue")
                        .font(.subheadline)
                        .foregroundColor(Color(white: 0.7))
                }

                if let msg = errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    authenticate()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: biometryIcon())
                        Text("Unlock")
                    }
                    .font(.body.weight(.medium))
                    .foregroundColor(Color(red: 13/255, green: 27/255, blue: 42/255))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color(red: 0.36, green: 0.77, blue: 0.92))
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
            // No biometrics and no passcode set — unlock immediately
            onUnlocked()
            return
        }
        isAuthenticating = true
        errorMessage = nil
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                            localizedReason: "Unlock MYRA AI") { success, error in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    onUnlocked()
                } else if let e = error as? LAError, e.code == .userCancel {
                    // User dismissed — stay locked, show prompt
                    errorMessage = nil
                } else {
                    errorMessage = error?.localizedDescription ?? "Authentication failed"
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

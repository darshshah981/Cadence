import SwiftUI

struct GoogleSignInButton: View {
    let isConnecting: Bool
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("GoogleG")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                Text(isConnecting ? "Opening Google" : "Sign in with Google")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(foregroundColor)

                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foregroundColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .frame(height: 44)
            .background(backgroundColor, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isConnecting)
        .opacity(isEnabled ? 1 : 0.62)
        .accessibilityLabel(isConnecting ? "Opening Google sign-in" : "Sign in with Google")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 19 / 255, green: 19 / 255, blue: 20 / 255)
            : .white
    }

    private var foregroundColor: Color {
        colorScheme == .dark
            ? Color(red: 227 / 255, green: 227 / 255, blue: 227 / 255)
            : Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color(red: 142 / 255, green: 145 / 255, blue: 143 / 255)
            : Color(red: 116 / 255, green: 119 / 255, blue: 117 / 255)
    }
}

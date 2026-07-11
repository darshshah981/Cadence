import SwiftUI

enum CadenceActionRole: String, Equatable, Sendable {
    case primary
    case secondary
    case quiet
    case destructive
}

struct CadenceActionDescriptor: Equatable, Sendable {
    let title: String
    let role: CadenceActionRole
    let isDefault: Bool
}

struct CadenceActionButton: View {
    let title: String
    let role: CadenceActionRole
    var isDefault = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        switch role {
        case .primary:
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .modifier(DefaultActionModifier(enabled: isDefault))
        case .secondary:
            Button(title, action: action)
                .buttonStyle(.bordered)
                .tint(FlowTheme.accent)
        case .quiet:
            Button(title, action: action)
                .buttonStyle(.borderless)
        case .destructive:
            Button(title, role: .destructive, action: action)
                .buttonStyle(.borderless)
        }
    }
}

private struct DefaultActionModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

enum ScribeActionPolicy {
    static func actions(
        for state: ScribeSessionState,
        hasLiteralTranscript: Bool,
        canRetryGeneration: Bool
    ) -> [CadenceActionDescriptor] {
        switch state {
        case .idle, .choosingIntent:
            return []
        case .listening:
            return [
                .init(title: "Cancel request", role: .destructive, isDefault: false),
                .init(title: "Stop and draft", role: .primary, isDefault: true)
            ]
        case .transcribing, .generating, .generatingSlow:
            return [.init(title: "Cancel request", role: .quiet, isDefault: false)]
        case .reviewing:
            return [
                .init(title: "Discard draft", role: .destructive, isDefault: false),
                .init(title: "Draft again", role: .secondary, isDefault: false),
                .init(title: "Copy draft", role: .quiet, isDefault: false),
                .init(title: "Insert into original app", role: .primary, isDefault: true)
            ]
        case .insertionRecovery:
            return [
                .init(title: "Discard draft", role: .destructive, isDefault: false),
                .init(title: "Copy draft", role: .quiet, isDefault: false),
                .init(title: "Return and insert", role: .primary, isDefault: true)
            ]
        case .inserting:
            return []
        case .succeeded:
            return [.init(title: "Done", role: .primary, isDefault: true)]
        case .cancelled:
            return []
        case .failed:
            var actions = [CadenceActionDescriptor(
                title: "Discard request",
                role: .destructive,
                isDefault: false
            )]
            if hasLiteralTranscript {
                actions.append(.init(title: "Use spoken words", role: .quiet, isDefault: false))
            }
            actions.append(.init(
                title: canRetryGeneration ? "Try Scribe again" : "Record request again",
                role: .primary,
                isDefault: true
            ))
            return actions
        }
    }

    static func isValid(_ descriptors: [CadenceActionDescriptor]) -> Bool {
        descriptors.filter { $0.role == .primary }.count <= 1
            && descriptors.filter { $0.role == .secondary }.count <= 1
            && descriptors.filter(\.isDefault).count <= 1
            && !descriptors.contains { $0.isDefault && $0.role == .destructive }
    }
}

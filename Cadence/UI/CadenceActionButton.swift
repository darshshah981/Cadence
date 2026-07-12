import SwiftUI

enum CadenceActionRole: String, Equatable, Sendable {
    case primary
    case secondary
    case quiet
    case destructive
    case icon
    case navigation
    case menu
}

enum CadenceActionKeyboardShortcut: Equatable, Sendable {
    case none
    case defaultAction
    case cancelAction
}

struct CadenceActionID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        precondition(!rawValue.isEmpty, "Cadence action identifiers must not be empty")
        self.rawValue = rawValue
    }
}

enum ScribeActionRoute: Equatable, Sendable {
    case cancel
    case stop
    case retry
    case reRecord
    case useLiteral
    case insert
    case insertUnpolished
    case copyPolished
    case copyUnpolished
    case close
}

struct CadenceActionDescriptor: Equatable, Identifiable, Sendable {
    let id: CadenceActionID
    let title: String
    let role: CadenceActionRole
    let keyboardShortcut: CadenceActionKeyboardShortcut
    let isEnabled: Bool
    let isLoading: Bool
    let accessibilityIdentifier: String
    let route: ScribeActionRoute

    var isDefault: Bool { keyboardShortcut == .defaultAction }
    var canActivate: Bool { isEnabled && !isLoading }

    init(
        id: CadenceActionID,
        title: String,
        role: CadenceActionRole,
        keyboardShortcut: CadenceActionKeyboardShortcut = .none,
        isEnabled: Bool = true,
        isLoading: Bool = false,
        accessibilityIdentifier: String? = nil,
        route: ScribeActionRoute
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.keyboardShortcut = role == .destructive ? .none : keyboardShortcut
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.accessibilityIdentifier = accessibilityIdentifier ?? id.rawValue
        self.route = route
    }

    init(title: String, role: CadenceActionRole, isDefault: Bool) {
        self.init(
            id: CadenceActionID(rawValue: "cadence.action.\(Self.slug(title))"),
            title: title,
            role: role,
            keyboardShortcut: isDefault ? .defaultAction : .none,
            route: .close
        )
    }

    private static func slug(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct CadenceActionButton: View {
    let actionID: CadenceActionID
    let title: String
    let role: CadenceActionRole
    let keyboardShortcut: CadenceActionKeyboardShortcut
    let isEnabled: Bool
    let isLoading: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    init(
        actionID: CadenceActionID? = nil,
        title: String,
        role: CadenceActionRole,
        keyboardShortcut: CadenceActionKeyboardShortcut = .none,
        isDefault: Bool = false,
        isEnabled: Bool = true,
        isLoading: Bool = false,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        let stableID = actionID ?? CadenceActionID(
            rawValue: "cadence.action.\(Self.slug(title))"
        )
        self.actionID = stableID
        self.title = title
        self.role = role
        self.keyboardShortcut = role == .destructive
            ? .none
            : (isDefault ? .defaultAction : keyboardShortcut)
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.accessibilityIdentifier = accessibilityIdentifier ?? stableID.rawValue
        self.action = action
    }

    init(
        descriptor: CadenceActionDescriptor,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            actionID: descriptor.id,
            title: descriptor.title,
            role: descriptor.role,
            keyboardShortcut: descriptor.keyboardShortcut,
            isEnabled: descriptor.isEnabled,
            isLoading: descriptor.isLoading,
            accessibilityIdentifier: accessibilityIdentifier ?? descriptor.accessibilityIdentifier,
            action: action
        )
    }

    @ViewBuilder
    var body: some View {
        let button = actionButton
            .disabled(!isEnabled || isLoading)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityValue(isLoading ? "Loading" : "")

        switch keyboardShortcut {
        case .none:
            button
        case .defaultAction:
            button.keyboardShortcut(.defaultAction)
        case .cancelAction:
            button.keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch role {
        case .primary:
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
        case .secondary, .navigation, .menu:
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .tint(FlowTheme.accent)
        case .quiet, .icon:
            Button(action: action) { label }
                .buttonStyle(.borderless)
        case .destructive:
            Button(role: .destructive, action: action) { label }
                .buttonStyle(.borderless)
        }
    }

    private var label: some View {
        HStack(spacing: CadenceDesignMetrics.spacingS) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(2)
        }
    }

    private static func slug(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct CadenceActionGroup: View {
    let actions: [CadenceActionDescriptor]
    let layoutWidth: CGFloat
    let perform: (ScribeActionRoute) -> Void
    @FocusState private var focusedActionID: CadenceActionID?

    @ViewBuilder
    var body: some View {
        Group {
            if layoutWidth < CadenceDesignMetrics.compactActionBreakpoint {
                verticalActions
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: CadenceDesignMetrics.spacingS) {
                        actionButtons
                    }
                    verticalActions
                }
            }
        }
        #if DEBUG
        .overlay(alignment: .topTrailing) {
            if ScribeLaunchFixtures.showsActionFocusProbe {
                Text(focusedActionID.map(Self.actionAccessibilityIdentifier) ?? "none")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .accessibilityLabel("Focused Scribe action")
                    .accessibilityValue(
                        focusedActionID.map(Self.actionAccessibilityIdentifier) ?? "none"
                    )
                    .accessibilityIdentifier("scribe-focused-action")
                    .allowsHitTesting(false)
                    .offset(y: -14)
            }
        }
        #endif
    }

    private var verticalActions: some View {
        VStack(alignment: .leading, spacing: CadenceDesignMetrics.spacingS) {
            actionButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(actions) { descriptor in
            CadenceActionButton(
                descriptor: descriptor,
                accessibilityIdentifier: Self.actionAccessibilityIdentifier(descriptor.id)
            ) {
                perform(descriptor.route)
            }
            .focusable(true)
            .focused($focusedActionID, equals: descriptor.id)
        }
    }

    static func actionAccessibilityIdentifier(_ id: CadenceActionID) -> String {
        let suffix = id.rawValue.hasPrefix("scribe.")
            ? String(id.rawValue.dropFirst("scribe.".count))
            : id.rawValue
        return "scribe-action-\(suffix)"
    }
}

#if DEBUG
struct CadenceActionControlFixtureView: View {
    @State private var enabledCount = 0
    @State private var disabledCount = 0
    @State private var loadingCount = 0
    @State private var defaultCount = 0
    @State private var cancelCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceDesignMetrics.spacingM) {
            Text("Action semantics fixture")
                .font(.headline)

            HStack(spacing: CadenceDesignMetrics.spacingS) {
                CadenceActionButton(
                    title: "Enabled action",
                    role: .secondary,
                    accessibilityIdentifier: "control-fixture-enabled"
                ) { enabledCount += 1 }
                CadenceActionButton(
                    title: "Disabled action",
                    role: .secondary,
                    isEnabled: false,
                    accessibilityIdentifier: "control-fixture-disabled"
                ) { disabledCount += 1 }
                CadenceActionButton(
                    title: "Loading action",
                    role: .secondary,
                    isLoading: true,
                    accessibilityIdentifier: "control-fixture-loading"
                ) { loadingCount += 1 }
            }

            HStack(spacing: CadenceDesignMetrics.spacingS) {
                CadenceActionButton(
                    title: "Default action",
                    role: .primary,
                    keyboardShortcut: .defaultAction,
                    accessibilityIdentifier: "control-fixture-default"
                ) { defaultCount += 1 }
                CadenceActionButton(
                    title: "Cancel action",
                    role: .quiet,
                    keyboardShortcut: .cancelAction,
                    accessibilityIdentifier: "control-fixture-cancel"
                ) { cancelCount += 1 }
            }

            Text(
                "enabled=\(enabledCount);disabled=\(disabledCount);loading=\(loadingCount);" +
                "default=\(defaultCount);cancel=\(cancelCount)"
            )
            .font(.system(size: 11, design: .monospaced))
            .accessibilityLabel("Action activation counts")
            .accessibilityValue(
                "enabled=\(enabledCount);disabled=\(disabledCount);loading=\(loadingCount);" +
                "default=\(defaultCount);cancel=\(cancelCount)"
            )
            .accessibilityIdentifier("control-fixture-counts")
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FlowTheme.elevated)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scribe-fixture-control-semantics")
    }
}
#endif

enum ScribeActionPolicy {
    private static func id(_ value: String) -> CadenceActionID {
        CadenceActionID(rawValue: "scribe.\(value)")
    }

    static func actions(
        for state: ScribeSessionState,
        hasLiteralTranscript: Bool,
        canRetryGeneration: Bool,
        targetDisplayName: String = "original app"
    ) -> [CadenceActionDescriptor] {
        switch state {
        case .idle:
            return []
        case .listening:
            return [
                .init(id: id("cancel-request"), title: "Cancel request", role: .destructive, route: .cancel),
                .init(
                    id: id("stop-and-draft"), title: "Stop and draft", role: .primary,
                    keyboardShortcut: .defaultAction, route: .stop
                )
            ]
        case .transcribing, .generating, .generatingSlow:
            return [.init(
                id: id("cancel-request"), title: "Cancel request", role: .quiet,
                keyboardShortcut: .cancelAction, route: .cancel
            )]
        case .reviewing:
            var actions: [CadenceActionDescriptor] = [
                .init(id: id("discard-draft"), title: "Discard draft", role: .destructive, route: .cancel),
                .init(id: id("record-again"), title: "Record again", role: .secondary, route: .reRecord),
            ]
            if canRetryGeneration {
                actions.append(.init(id: id("retry-polish"), title: "Retry polish", role: .quiet, route: .retry))
            }
            if hasLiteralTranscript {
                actions.append(.init(id: id("copy-unpolished"), title: "Copy unpolished", role: .quiet, route: .copyUnpolished))
                actions.append(.init(id: id("insert-unpolished"), title: "Insert unpolished", role: .quiet, route: .insertUnpolished))
            }
            actions.append(.init(id: id("copy-polished"), title: "Copy polished", role: .quiet, route: .copyPolished))
            actions.append(.init(
                id: id("insert-polished"), title: "Insert polished into \(targetDisplayName)", role: .primary,
                keyboardShortcut: .defaultAction, route: .insert
            ))
            return actions
        case .insertionRecovery:
            var actions: [CadenceActionDescriptor] = [
                .init(id: id("discard-draft"), title: "Discard draft", role: .destructive, route: .cancel),
            ]
            if hasLiteralTranscript {
                actions.append(.init(id: id("copy-unpolished"), title: "Copy unpolished", role: .quiet, route: .copyUnpolished))
                actions.append(.init(id: id("insert-unpolished"), title: "Insert unpolished", role: .quiet, route: .insertUnpolished))
            }
            actions.append(.init(id: id("copy-polished"), title: "Copy polished", role: .quiet, route: .copyPolished))
            actions.append(.init(
                id: id("insert-polished"), title: "Return to \(targetDisplayName) and insert polished", role: .primary,
                keyboardShortcut: .defaultAction, route: .insert
            ))
            return actions
        case .inserting:
            return []
        case .succeeded:
            return [.init(
                id: id("done"), title: "Done", role: .primary,
                keyboardShortcut: .defaultAction, route: .close
            )]
        case .cancelled:
            return []
        case .failed:
            var actions = [CadenceActionDescriptor(
                id: id(hasLiteralTranscript ? "discard-draft" : "discard-request"),
                title: hasLiteralTranscript ? "Discard draft" : "Discard request",
                role: .destructive,
                route: .cancel
            )]
            if hasLiteralTranscript {
                actions.append(.init(
                    id: id("copy-unpolished"), title: "Copy unpolished", role: .quiet,
                    route: .copyUnpolished
                ))
                actions.append(.init(
                    id: id("insert-unpolished"), title: "Insert unpolished", role: .quiet,
                    route: .insertUnpolished
                ))
            }
            actions.append(.init(
                id: id("retry"),
                title: canRetryGeneration ? "Try Scribe again" : "Record request again",
                role: .primary,
                keyboardShortcut: .defaultAction,
                route: .retry
            ))
            return actions
        }
    }

    static func showsEnvironmentCue(_ state: ScribeSessionState) -> Bool {
        if case .reviewing = state { return true }
        if case .insertionRecovery = state { return true }
        return false
    }

    static func hasRecoverableContent(
        in state: ScribeSessionState,
        literalTranscript: String?
    ) -> Bool {
        let literal = literalTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        if literal?.isEmpty == false { return true }
        switch state {
        case let .reviewing(result), let .insertionRecovery(result):
            return !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }

    static func requiresDiscardConfirmation(
        for state: ScribeSessionState,
        hasRecoverableContent: Bool
    ) -> Bool {
        guard hasRecoverableContent else { return false }
        switch state {
        case .reviewing, .insertionRecovery, .failed:
            return true
        default:
            return false
        }
    }

    static func isValid(_ descriptors: [CadenceActionDescriptor]) -> Bool {
        Set(descriptors.map(\.id)).count == descriptors.count
            && descriptors.filter { $0.role == .primary }.count <= 1
            && descriptors.filter { $0.role == .secondary }.count <= 1
            && descriptors.filter { $0.keyboardShortcut == .defaultAction }.count <= 1
            && !descriptors.contains {
                $0.role == .destructive && $0.keyboardShortcut != .none
            }
    }
}

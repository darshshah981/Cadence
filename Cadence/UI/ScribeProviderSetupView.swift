import SwiftUI

enum ScribeProviderSetupChoice: Equatable, Sendable {
    case deepSeek
    case advanced
}

enum ScribeProviderSetupStage: Equatable, Sendable {
    case chooseProvider
    case advancedConfiguration
    case disclosure
    case credential
    case validating
    case ready
    case practicing
    case practice
}

@MainActor
final class ScribeProviderSetupModel: ObservableObject {
    @Published private(set) var stage: ScribeProviderSetupStage = .chooseProvider
    @Published private(set) var choice: ScribeProviderSetupChoice?
    @Published var advancedBaseURL = ""
    @Published var advancedModel = ""
    @Published var credential = ""
    @Published private(set) var normalizedAdvancedEndpoint: AdvancedScribeEndpoint?
    @Published private(set) var failureMessage: String?
    @Published private(set) var practiceDraft: String?

    func choose(_ choice: ScribeProviderSetupChoice) {
        self.choice = choice
        failureMessage = nil
        stage = choice == .deepSeek ? .disclosure : .advancedConfiguration
    }

    func submitAdvancedConfiguration() {
        do {
            normalizedAdvancedEndpoint = try AdvancedScribeEndpoint(advancedBaseURL)
            _ = try ScribeModelIdentifier(advancedModel)
            failureMessage = nil
            stage = .disclosure
        } catch let error as ScribeProviderConfigurationError {
            failureMessage = error.setupMessage
        } catch {
            failureMessage = "Enter a valid HTTPS API base URL and model identifier."
        }
    }

    func acceptDisclosure() {
        failureMessage = nil
        stage = .credential
    }

    func beginValidation() -> Bool {
        guard !credential.isEmpty else {
            failureMessage = "Enter an API key to continue."
            return false
        }
        failureMessage = nil
        stage = .validating
        return true
    }

    func validationFailed(_ message: String) {
        failureMessage = message
        stage = .credential
    }

    func validationSucceeded() {
        credential = ""
        failureMessage = nil
        stage = .ready
    }

    func beginPractice() {
        failureMessage = nil
        practiceDraft = nil
        stage = .practicing
    }

    func practiceSucceeded(_ draft: String) {
        practiceDraft = draft
        failureMessage = nil
        stage = .practice
    }

    func practiceFailed(_ message: String) {
        failureMessage = message
        stage = .ready
    }

    func goBack() {
        failureMessage = nil
        switch stage {
        case .chooseProvider:
            break
        case .advancedConfiguration:
            choice = nil
            stage = .chooseProvider
        case .disclosure:
            stage = choice == .advanced ? .advancedConfiguration : .chooseProvider
            if choice == .deepSeek { choice = nil }
        case .credential:
            credential = ""
            stage = .disclosure
        case .practice:
            practiceDraft = nil
            stage = .ready
        case .validating, .ready, .practicing:
            break
        }
    }

    func clearCandidate() {
        credential = ""
    }
}

struct ScribeProviderSetupView: View {
    @StateObject private var model = ScribeProviderSetupModel()
    @State private var validationTask: Task<Void, Never>?
    let onConnectDeepSeek: (String) async throws -> Void
    let onConnectAdvanced: (String, String, String) async throws -> Void
    let onGeneratePractice: () async throws -> String
    let onSwitchProvider: (ScribeProviderKind) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            actions
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 480, idealHeight: 620)
        .background(FlowTheme.background)
        .onExitCommand { dismiss() }
        .onDisappear {
            validationTask?.cancel()
            validationTask = nil
            model.clearCandidate()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(FlowTheme.textPrimary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(FlowTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .chooseProvider:
            providerChoice
        case .advancedConfiguration:
            advancedConfiguration
        case .disclosure:
            disclosure
        case .credential:
            credentialEntry
        case .validating:
            validating
        case .ready:
            ready
        case .practicing:
            practicing
        case .practice:
            practice
        }
    }

    private var providerChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose where Cadence sends Scribe text. No provider is preselected, and choosing does not start a network request.")
                .foregroundStyle(FlowTheme.textSecondary)
            providerCard(
                title: "DeepSeek",
                detail: "Release-tested DeepSeek V4 Flash profile at api.deepseek.com.",
                action: {
                    onSwitchProvider(.deepSeek)
                    model.choose(.deepSeek)
                }
            )
            providerCard(
                title: "Advanced OpenAI-compatible",
                detail: "One HTTPS, bearer-authenticated, non-streaming Chat Completions endpoint.",
                action: {
                    onSwitchProvider(.advanced)
                    model.choose(.advanced)
                }
            )
        }
    }

    private var advancedConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter an API base URL and model. Cadence derives one /chat/completions endpoint; it does not discover models or contact the server yet.")
                .foregroundStyle(FlowTheme.textSecondary)
            TextField("API base URL", text: $model.advancedBaseURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("scribe-advanced-base-url")
            TextField("Model identifier", text: $model.advancedModel)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("scribe-advanced-model")
            if let failureMessage = model.failureMessage {
                setupError(failureMessage)
            }
        }
    }

    private var disclosure: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(disclosureText)
                    .font(.body)
                    .foregroundStyle(FlowTheme.textSecondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("scribe-provider-disclosure")
                if model.choice == .deepSeek {
                    if let entry = ScribeProviderCatalog.releaseOne.deepSeekEntries.first {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.displayName)
                                .font(.headline)
                            Text("Only bundled DeepSeek model · Tested with Cadence \(cadenceVersion) · source reviewed \(entry.documentationReviewedOn)")
                                .font(.caption)
                                .foregroundStyle(FlowTheme.textTertiary)
                        }
                        .padding(10)
                        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine)
                    }
                    Link(
                        "Review the DeepSeek Privacy Policy",
                        destination: ScribeProviderDisclosure.deepSeekPrivacyPolicyURL
                    )
                } else if let endpoint = model.normalizedAdvancedEndpoint {
                    Text("Recipient: \(endpoint.normalizedOrigin)\nRequest endpoint: \(endpoint.requestURL.absoluteString)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(FlowTheme.textPrimary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var credentialEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The candidate key stays in memory until the synthetic compatibility check succeeds. Cadence then stores it in this Mac's non-synchronizing Keychain.")
                .foregroundStyle(FlowTheme.textSecondary)
            SecureField("API key", text: $model.credential)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("scribe-provider-api-key")
            Text("Validation sends only “Return only OK.” and “Cadence provider compatibility check.”")
                .font(.caption)
                .foregroundStyle(FlowTheme.textTertiary)
            if let failureMessage = model.failureMessage {
                setupError(failureMessage)
            }
        }
    }

    private var validating: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Validating compatibility…")
                    .font(.headline)
                Text("Cadence will stop safely after 15 seconds and will not retry automatically.")
                    .font(.caption)
                    .foregroundStyle(FlowTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Scribe is ready", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(FlowTheme.success)
            Text("Connection test succeeded. Cadence received one compatible, non-streaming text completion from this endpoint and model configuration.")
                .foregroundStyle(FlowTheme.textSecondary)
            Text("Review every draft before inserting it. A successful check does not certify provider privacy, security, model quality, or permanent availability.")
                .font(.caption)
                .foregroundStyle(FlowTheme.textTertiary)
        }
    }

    private var practicing: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Drafting a synthetic practice update…")
                    .font(.headline)
                Text("This sends no selected app text and never inserts the result.")
                    .font(.caption)
                    .foregroundStyle(FlowTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Practice draft", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Text("Review only. This synthetic draft was not inserted or copied anywhere.")
                .font(.caption)
                .foregroundStyle(FlowTheme.textSecondary)
            ScrollView {
                Text(model.practiceDraft ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if model.stage != .chooseProvider
                && model.stage != .validating
                && model.stage != .ready
                && model.stage != .practicing {
                CadenceActionButton(title: "Back", role: .quiet) { model.goBack() }
            }
            if model.stage != .validating && model.stage != .ready && model.stage != .practicing {
                CadenceActionButton(title: "Not now", role: .quiet) { dismiss() }
            }
            Spacer()
            switch model.stage {
            case .chooseProvider:
                EmptyView()
            case .advancedConfiguration:
                CadenceActionButton(title: "Review recipient and data use", role: .primary, isDefault: true) {
                    model.submitAdvancedConfiguration()
                }
            case .disclosure:
                CadenceActionButton(title: "I understand", role: .primary, isDefault: true) {
                    model.acceptDisclosure()
                }
            case .credential:
                CadenceActionButton(title: connectTitle, role: .primary, isDefault: true) {
                    connect()
                }
            case .validating:
                CadenceActionButton(title: "Cancel validation", role: .destructive) { dismiss() }
            case .ready:
                CadenceActionButton(title: "Try a practice draft", role: .quiet) { practiceDraft() }
                CadenceActionButton(title: "Done", role: .primary, isDefault: true) { dismiss() }
            case .practicing:
                CadenceActionButton(title: "Cancel practice", role: .quiet) { dismiss() }
            case .practice:
                CadenceActionButton(title: "Done", role: .primary, isDefault: true) { dismiss() }
            }
        }
    }

    private func providerCard(title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(FlowTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private func setupError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
    }

    private func connect() {
        guard model.beginValidation(), let choice = model.choice else { return }
        let key = model.credential
        validationTask?.cancel()
        validationTask = Task { @MainActor in
            defer { validationTask = nil }
            do {
                switch choice {
                case .deepSeek:
                    try await onConnectDeepSeek(key)
                case .advanced:
                    try await onConnectAdvanced(model.advancedBaseURL, model.advancedModel, key)
                }
                model.validationSucceeded()
            } catch let failure as ScribeProviderFailure {
                model.validationFailed(failure.userMessage)
            } catch let configuration as ScribeProviderConfigurationError {
                model.validationFailed(configuration.setupMessage)
            } catch {
                model.validationFailed("Cadence could not validate this provider. Check the connection details and try again.")
            }
        }
    }

    private func practiceDraft() {
        model.beginPractice()
        validationTask?.cancel()
        validationTask = Task { @MainActor in
            defer { validationTask = nil }
            do {
                model.practiceSucceeded(try await onGeneratePractice())
            } catch let failure as ScribeProviderFailure {
                model.practiceFailed(failure.userMessage)
            } catch {
                model.practiceFailed("Cadence could not create the practice draft. You can finish setup and try Scribe later.")
            }
        }
    }

    private func dismiss() {
        validationTask?.cancel()
        validationTask = nil
        model.clearCandidate()
        onDismiss()
    }

    private var title: String {
        switch model.stage {
        case .chooseProvider: return "Set up Scribe"
        case .advancedConfiguration: return "Configure an Advanced provider"
        case .disclosure:
            if model.choice == .deepSeek { return ScribeProviderDisclosure.deepSeekTitle }
            let origin = model.normalizedAdvancedEndpoint?.normalizedOrigin ?? "the configured provider"
            return "Connect to \(origin)"
        case .credential: return "Connect Scribe"
        case .validating: return "Check provider compatibility"
        case .ready: return "Scribe ready"
        case .practicing: return "Try Scribe safely"
        case .practice: return "Practice complete"
        }
    }

    private var subtitle: String {
        switch model.stage {
        case .chooseProvider: return "Local transcription, optional cloud drafting"
        case .advancedConfiguration: return "No network request occurs on this step"
        case .disclosure: return "Review before any validation request"
        case .credential: return "Candidate key is not saved before success"
        case .validating: return "Synthetic request only"
        case .ready: return "Provider configuration saved on this Mac"
        case .practicing: return "Synthetic request only · no insertion"
        case .practice: return "Review-only setup result"
        }
    }

    private var connectTitle: String {
        if model.choice == .deepSeek { return "Connect and validate with DeepSeek" }
        let host = model.normalizedAdvancedEndpoint?.requestURL.host ?? "provider"
        return "Connect and validate \(host)"
    }

    private var disclosureText: String {
        if model.choice == .deepSeek {
            return ScribeProviderDisclosure.deepSeek
        }
        let origin = model.normalizedAdvancedEndpoint?.normalizedOrigin ?? "the configured endpoint"
        return ScribeProviderDisclosure.advanced(origin: origin)
    }

    private var cadenceVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

private extension ScribeProviderConfigurationError {
    var setupMessage: String {
        switch self {
        case .invalidBaseURL: return "Enter an absolute HTTPS API base URL with a host."
        case .insecureBaseURL: return "Scribe provider URLs must use HTTPS."
        case .embeddedCredentials: return "Remove the username or password from the URL. Enter the API key separately."
        case .queryOrFragment: return "Enter an API base URL without a query or fragment."
        case .unsafePath: return "The API base path contains an unsafe or ambiguous segment."
        case .requestURLInsteadOfBase: return "Enter the API base prefix, not a URL ending in /chat/completions."
        case .invalidModel: return "Enter a model identifier up to 256 bytes with no control characters."
        }
    }
}

private extension ScribeProviderFailure {
    var userMessage: String {
        switch category {
        case .setupRequired: return "Choose and connect a Scribe provider first."
        case .configurationInvalid: return "The saved provider configuration needs repair."
        case .credentialRejected: return "The provider rejected this API key or account access."
        case .balanceRequired: return "DeepSeek reports that this account needs balance before Scribe can run."
        case .rateLimited: return "The provider is temporarily rate limited. Try again after it recovers."
        case .transportUnavailable: return "Cadence could not reach the provider. Check the network and endpoint."
        case .unsafeConnection: return "Cadence refused a redirect or unsafe connection. Check the endpoint and trust settings."
        case .timedOut: return "The provider check took too long and was cancelled."
        case .providerUnavailable: return "The provider is temporarily unavailable."
        case .providerRejected: return "The provider rejected this compatibility request."
        case .incompatibleRequest: return "This endpoint or bundled provider profile is not compatible with Cadence."
        case .endpointNotFound: return "The endpoint or model was not found."
        case .invalidResponse: return "Cadence received a response it could not safely use."
        case .cancelled: return "Provider validation was cancelled."
        }
    }
}

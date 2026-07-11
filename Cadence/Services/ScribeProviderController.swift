import Foundation

@MainActor
final class ScribeProviderController {
    var onReadinessChange: ((ScribeProviderReadiness) -> Void)?
    var onProviderRemoved: (() -> Void)?

    private(set) var readiness: ScribeProviderReadiness = .setupRequired {
        didSet {
            guard oldValue != readiness else { return }
            onReadinessChange?(readiness)
        }
    }

    private let configurationStore: any ScribeProviderConfigurationPersisting
    private let credentialStore: any ScribeCredentialStoring
    private let connectionManager: ScribeProviderConnectionManager
    private let transport: any ScribeHTTPTransporting
    private let legacyProvider: (any ScribeProvider)?

    init(
        configurationStore: any ScribeProviderConfigurationPersisting = ScribeProviderConfigurationStore(),
        credentialStore: any ScribeCredentialStoring = KeychainScribeCredentialStore(),
        transport: any ScribeHTTPTransporting = ScribeHTTPTransport(),
        legacyProvider: (any ScribeProvider)? = nil
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.connectionManager = ScribeProviderConnectionManager(
            configurationStore: configurationStore,
            credentialStore: credentialStore
        )
        self.transport = transport
        self.legacyProvider = legacyProvider
        try? connectionManager.removeUnreferencedCredentials()
        refreshReadiness()
    }

    func refreshReadiness() {
        switch configurationStore.load() {
        case .absent:
            readiness = legacyProvider == nil ? .setupRequired : .ready(.legacyLocal)
        case .rejected:
            readiness = .configurationInvalid
        case let .valid(configuration):
            guard configuration.isEnabled else {
                readiness = .disabled
                return
            }
            guard configurationIsSupported(configuration) else {
                readiness = configuration.kind == .deepSeek
                    ? .deprecated(.deepSeek)
                    : .configurationInvalid
                return
            }
            do {
                readiness = try credentialStore.load(reference: configuration.credentialReference) == nil
                    ? .needsAttention(configuration.kind)
                    : .ready(configuration.kind)
            } catch {
                readiness = .needsAttention(configuration.kind)
            }
        }
    }

    func actionForNewRequest() throws -> ScribeProviderActionSnapshot {
        switch configurationStore.load() {
        case .absent:
            if let legacyProvider {
                return ScribeProviderActionSnapshot(
                    provider: legacyProvider,
                    destination: .legacyLocal
                )
            }
            throw ScribeProviderFailure(
                phase: .generation,
                category: .setupRequired,
                retryDisposition: .reconnect
            )
        case .rejected:
            throw ScribeProviderFailure(
                phase: .generation,
                category: .configurationInvalid,
                retryDisposition: .reconnect
            )
        case let .valid(configuration):
            guard configuration.isEnabled, configurationIsSupported(configuration) else {
                throw ScribeProviderFailure(
                    phase: .generation,
                    category: .configurationInvalid,
                    retryDisposition: configuration.kind == .deepSeek ? .updateCadence : .changeConfiguration
                )
            }
            let credential: String
            do {
                guard let loaded = try credentialStore.load(reference: configuration.credentialReference) else {
                    throw ScribeCredentialStoreError.invalidStoredValue
                }
                credential = loaded
            } catch {
                throw ScribeProviderFailure(
                    phase: .generation,
                    category: .configurationInvalid,
                    retryDisposition: .reconnect
                )
            }
            switch configuration.kind {
            case .deepSeek:
                return ScribeProviderActionSnapshot(
                    provider: DeepSeekScribeProvider(
                        credentialLoader: { credential },
                        transport: transport
                    ),
                    destination: .deepSeek
                )
            case .advanced:
                let endpoint: AdvancedScribeEndpoint
                let model: ScribeModelIdentifier
                do {
                    endpoint = try AdvancedScribeEndpoint(configuration.baseURL.absoluteString)
                    model = try ScribeModelIdentifier(configuration.modelID)
                } catch {
                    throw ScribeProviderFailure(
                        phase: .generation,
                        category: .configurationInvalid,
                        retryDisposition: .changeConfiguration
                    )
                }
                return ScribeProviderActionSnapshot(
                    provider: OpenAICompatibleScribeProvider(
                        endpoint: endpoint,
                        model: model,
                        credentialLoader: { credential },
                        transport: transport
                    ),
                    destination: .advanced(
                        origin: endpoint.normalizedOrigin,
                        disclosureVersion: configuration.disclosureVersion
                    )
                )
            case .legacyLocal:
                guard let legacyProvider else {
                    throw ScribeProviderFailure(
                        phase: .generation,
                        category: .configurationInvalid,
                        retryDisposition: .updateCadence
                    )
                }
                return ScribeProviderActionSnapshot(
                    provider: legacyProvider,
                    destination: .legacyLocal
                )
            }
        }
    }

    func providerForNewAction() throws -> any ScribeProvider {
        try actionForNewRequest().provider
    }

    func connectDeepSeek(
        credential: String,
        acceptedAt: Date = Date()
    ) async throws {
        let candidate = try ScribeProviderCandidateConfiguration.deepSeek(acceptedAt: acceptedAt)
        try await connect(candidate: candidate, credential: credential)
    }

    func connectAdvanced(
        baseURL: String,
        model: String,
        credential: String,
        acceptedAt: Date = Date()
    ) async throws {
        let candidate = ScribeProviderCandidateConfiguration.advanced(
            endpoint: try AdvancedScribeEndpoint(baseURL),
            model: try ScribeModelIdentifier(model),
            acceptedAt: acceptedAt
        )
        try await connect(candidate: candidate, credential: credential)
    }

    func setEnabled(_ enabled: Bool) throws {
        guard case var .valid(configuration) = configurationStore.load() else {
            refreshReadiness()
            return
        }
        configuration.isEnabled = enabled
        try configurationStore.save(configuration)
        refreshReadiness()
    }

    func removeProvider() throws {
        onProviderRemoved?()
        do {
            try connectionManager.removeProvider()
            readiness = .removed
        } catch {
            refreshReadiness()
            throw error
        }
    }

    var statusText: String {
        switch readiness {
        case .disabled:
            return "Scribe is disabled · provider key retained"
        case .setupRequired:
            return "Provider setup required · literal Dictation remains available"
        case .validating:
            return "Validating the selected provider…"
        case let .ready(kind):
            return kind == .legacyLocal
                ? "On-device drafting · no network"
                : "\(kind.displayName) connected · review before insert"
        case let .temporarilyUnavailable(kind):
            return "\(kind.displayName) is temporarily unavailable"
        case .configurationInvalid:
            return "Provider configuration needs repair"
        case let .needsAttention(kind):
            return "\(kind.displayName) needs attention"
        case let .deprecated(kind):
            return "\(kind.displayName) needs a Cadence update"
        case .removed:
            return "Provider removed · provider setup required"
        }
    }

    var configuredKind: ScribeProviderKind? {
        guard case let .valid(configuration) = configurationStore.load() else { return nil }
        return configuration.kind
    }

    var configuredProviderIsEnabled: Bool {
        guard case let .valid(configuration) = configurationStore.load() else { return false }
        return configuration.isEnabled
    }

    var configuredRecipient: String? {
        guard case let .valid(configuration) = configurationStore.load() else { return nil }
        return configuration.normalizedOrigin
    }

    private func connect(
        candidate: ScribeProviderCandidateConfiguration,
        credential: String
    ) async throws {
        readiness = .validating
        do {
            _ = try await connectionManager.connect(
                candidate: candidate,
                credential: credential
            ) { [transport] candidate, candidateCredential in
                switch candidate.kind {
                case .deepSeek:
                    try await DeepSeekScribeProvider(
                        credentialLoader: { candidateCredential },
                        transport: transport
                    ).validateConnection()
                case .advanced:
                    try await OpenAICompatibleScribeProvider(
                        endpoint: try AdvancedScribeEndpoint(candidate.baseURL.absoluteString),
                        model: try ScribeModelIdentifier(candidate.modelID),
                        credentialLoader: { candidateCredential },
                        transport: transport
                    ).validateConnection()
                case .legacyLocal:
                    throw ScribeProviderConnectionError.validationFailed
                }
            }
            refreshReadiness()
        } catch {
            refreshReadiness()
            throw error
        }
    }

    private func configurationIsSupported(_ configuration: ScribeProviderConfiguration) -> Bool {
        guard configuration.disclosureVersion == ScribeProviderDisclosure.currentVersion else {
            return false
        }
        switch configuration.kind {
        case .deepSeek:
            guard let entry = ScribeProviderCatalog.releaseOne.deepSeekEntries.first else { return false }
            return configuration.catalogID == entry.catalogID
                && configuration.modelID == entry.modelID
                && configuration.requestURL == entry.endpoint
                && configuration.normalizedOrigin == "https://api.deepseek.com"
        case .advanced:
            guard let endpoint = try? AdvancedScribeEndpoint(configuration.baseURL.absoluteString),
                  let model = try? ScribeModelIdentifier(configuration.modelID) else {
                return false
            }
            return endpoint.normalizedOrigin == configuration.normalizedOrigin
                && endpoint.normalizedBaseURL == configuration.baseURL
                && endpoint.requestURL == configuration.requestURL
                && model.rawValue == configuration.modelID
        case .legacyLocal:
            return legacyProvider != nil
        }
    }
}

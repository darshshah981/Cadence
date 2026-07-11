import Foundation

typealias ScribeProviderConsentVerifying = @Sendable (
    ScribeProviderConsentReceipt
) async -> Bool

enum ScribeModelSelectionState: Equatable, Sendable {
    case ready(selectedModelID: String)
    case needsAttention(selectedModelID: String)
    case offlinePreserved(selectedModelID: String)
}

struct ScribeModelValidationProof: Equatable, Sendable {
    fileprivate let id: UUID
    let providerKind: ScribeProviderKind
    let selectedModelID: String
    let consentReceiptID: UUID
    let setupRevision: Int

    func matches(
        _ candidate: ScribeProviderConnectionCandidate,
        setupRevision: Int
    ) -> Bool {
        providerKind == candidate.kind
            && selectedModelID == candidate.selectedModelID
            && consentReceiptID == candidate.consentReceipt.id
            && self.setupRevision == setupRevision
    }
}

enum ScribeModelSetupValidationResult: Equatable, Sendable {
    case ready(ScribeModelValidationProof)
    case notReady(ScribeModelSelectionState)
}

actor ScribeModelCatalogService {
    typealias CredentialLoader = @Sendable (ScribeProviderKind) async throws -> String

    private struct OpenAIModels: Decodable { let data: [OpenAIModel] }
    private struct OpenAIModel: Decodable { let id: String }
    private struct OpenRouterModels: Decodable { let data: [OpenRouterModel] }
    private struct OpenRouterModel: Decodable {
        let id: String
        let architecture: Architecture
        let canonicalSlug: String?
        let name: String?
        let contextLength: Int?
        let supportedParameters: [String]?
        let expirationDate: String?

        enum CodingKeys: String, CodingKey {
            case id, architecture, name
            case canonicalSlug = "canonical_slug"
            case contextLength = "context_length"
            case supportedParameters = "supported_parameters"
            case expirationDate = "expiration_date"
        }
    }
    private struct Architecture: Decodable {
        let outputModalities: [String]
        enum CodingKeys: String, CodingKey { case outputModalities = "output_modalities" }
    }
    private struct ZDREndpoints: Decodable { let data: [ZDREndpoint] }
    private struct ZDREndpoint: Decodable {
        let modelID: String
        enum CodingKeys: String, CodingKey { case modelID = "model_id" }
    }

    private let transport: any ScribeHTTPTransporting
    private let credentialLoader: CredentialLoader
    private let consentVerifier: ScribeProviderConsentVerifying
    private let bundledCatalog: ScribeBundledModelCatalog
    private var validatedSelections: [ScribeProviderKind: Set<String>] = [:]
    private var discoveredModels: [ScribeProviderKind: [ScribeSearchableModelEntry]] = [:]
    private var unconsumedProofs: [UUID: ScribeModelValidationProof] = [:]

    init(
        transport: any ScribeHTTPTransporting = ScribeHTTPTransport(),
        credentialLoader: @escaping CredentialLoader,
        consentVerifier: @escaping ScribeProviderConsentVerifying = { _ in false },
        priorValidatedSelections: [ScribePriorValidatedModelSelection] = [],
        bundledCatalog: ScribeBundledModelCatalog = .empty
    ) {
        self.transport = transport
        self.credentialLoader = credentialLoader
        self.consentVerifier = consentVerifier
        self.bundledCatalog = bundledCatalog
        for selection in priorValidatedSelections where
            selection.disclosureRevision == ScribeProviderDisclosure.currentVersion
                && selection.lastValidatedAt.timeIntervalSince1970.isFinite
                && selection.lastValidatedAt.timeIntervalSince1970 > 0
                && Self.isExactModelIdentifier(selection.selectedModelID) {
            validatedSelections[selection.providerKind, default: []]
                .insert(selection.selectedModelID)
        }
    }

    func validateNewSetup(
        provider: ScribeProviderKind,
        selectedModelID: String,
        consentReceipt: ScribeProviderConsentReceipt,
        setupRevision: Int
    ) async -> ScribeModelSetupValidationResult {
        let state: ScribeModelSelectionState
        switch provider {
        case .openAIDirect:
            state = await refreshOpenAI(
                selectedModelID: selectedModelID,
                consentReceipt: consentReceipt
            )
        case .openRouter:
            state = await refreshOpenRouter(
                selectedModelID: selectedModelID,
                consentReceipt: consentReceipt
            )
        case .deepSeek, .advanced, .legacyLocal:
            return .notReady(.needsAttention(selectedModelID: selectedModelID))
        }
        guard state == .ready(selectedModelID: selectedModelID) else {
            return .notReady(state)
        }
        let proof = ScribeModelValidationProof(
            id: UUID(),
            providerKind: provider,
            selectedModelID: selectedModelID,
            consentReceiptID: consentReceipt.id,
            setupRevision: setupRevision
        )
        unconsumedProofs[proof.id] = proof
        return .ready(proof)
    }

    func consume(
        _ proof: ScribeModelValidationProof,
        for candidate: ScribeProviderConnectionCandidate,
        setupRevision: Int
    ) -> Bool {
        guard proof.matches(candidate, setupRevision: setupRevision),
              unconsumedProofs.removeValue(forKey: proof.id) == proof else { return false }
        return true
    }

    func discard(_ proof: ScribeModelValidationProof) {
        unconsumedProofs.removeValue(forKey: proof.id)
    }

    func refreshOpenRouter(
        selectedModelID: String,
        consentReceipt: ScribeProviderConsentReceipt?
    ) async -> ScribeModelSelectionState {
        guard await authorized(consentReceipt, for: .openRouter) else {
            return .needsAttention(selectedModelID: selectedModelID)
        }
        var reachedConfirmedEligibility = false
        do {
            let rawModels = try await discoveryGET(
                URL(string: "https://openrouter.ai/api/v1/models/user")!,
                provider: .openRouter
            )
            let rawZDR = try await discoveryGET(
                URL(string: "https://openrouter.ai/api/v1/endpoints/zdr")!,
                provider: .openRouter
            )
            let models = try JSONDecoder().decode(OpenRouterModels.self, from: rawModels).data
            guard models.count <= 10_000,
                  Set(models.map(\.id)).count == models.count,
                  models.allSatisfy({ model in
                      model.architecture.outputModalities.count <= 16
                          && model.architecture.outputModalities
                            .allSatisfy(Self.isBoundedMetadata)
                  }) else {
                throw ScribeProviderConfigurationError.invalidModel
            }
            let zdrIDs = Set(try JSONDecoder().decode(ZDREndpoints.self, from: rawZDR).data.map(\.modelID))
            let eligibleIDs = Set(models.compactMap { model -> String? in
                guard model.architecture.outputModalities.contains("text"),
                      zdrIDs.contains(model.id),
                      Self.isExactModelIdentifier(model.id) else { return nil }
                return model.id
            })
            discoveredModels[.openRouter] = try models
                .filter { eligibleIDs.contains($0.id) }
                .map { try Self.openRouterEntry($0) }
                .sorted { $0.modelID < $1.modelID }
            guard eligibleIDs.contains(selectedModelID) else {
                return .needsAttention(selectedModelID: selectedModelID)
            }
            reachedConfirmedEligibility = true
            let model = try ScribeModelIdentifier(selectedModelID)
            guard model.rawValue == selectedModelID else {
                return .needsAttention(selectedModelID: selectedModelID)
            }
            let credential = try await credentialLoader(.openRouter)
            try await OpenRouterScribeProvider(
                model: model,
                credentialLoader: { credential },
                transport: transport
            ).validateConnection()
            validatedSelections[.openRouter, default: []].insert(selectedModelID)
            return .ready(selectedModelID: selectedModelID)
        } catch let failure as ScribeProviderFailure {
            if !reachedConfirmedEligibility {
                return discoveryFailureState(
                    failure: failure,
                    provider: .openRouter,
                    selectedModelID: selectedModelID
                )
            }
            return unavailableState(
                failure: failure,
                provider: .openRouter,
                selectedModelID: selectedModelID
            )
        } catch {
            return reachedConfirmedEligibility
                ? .needsAttention(selectedModelID: selectedModelID)
                : preservedState(for: .openRouter, selectedModelID: selectedModelID)
        }
    }

    /// OpenAI model visibility is only a candidate signal; production-adapter
    /// validation is always required before the exact selected identifier becomes ready.
    func refreshOpenAI(
        selectedModelID: String,
        consentReceipt: ScribeProviderConsentReceipt?
    ) async -> ScribeModelSelectionState {
        guard await authorized(consentReceipt, for: .openAIDirect) else {
            return .needsAttention(selectedModelID: selectedModelID)
        }
        var reachedConfirmedEligibility = false
        do {
            let data = try await discoveryGET(
                URL(string: "https://api.openai.com/v1/models")!,
                provider: .openAIDirect
            )
            let decodedModels = try JSONDecoder().decode(OpenAIModels.self, from: data).data
            guard decodedModels.count <= 10_000,
                  Set(decodedModels.map(\.id)).count == decodedModels.count else {
                throw ScribeProviderConfigurationError.invalidModel
            }
            let visible = Set(decodedModels.map(\.id)
                .filter(Self.isExactModelIdentifier))
            discoveredModels[.openAIDirect] = visible.sorted().map { modelID in
                ScribeSearchableModelEntry(
                    providerKind: .openAIDirect,
                    modelID: modelID,
                    displayName: modelID,
                    recommendation: .none,
                    source: .live,
                    compatibility: .liveVisible,
                    providerDisplayName: "OpenAI",
                    searchTerms: [modelID, "OpenAI"],
                    eligibilityFacts: [.authenticatedUserVisible]
                )
            }
            guard visible.contains(selectedModelID) else {
                return .needsAttention(selectedModelID: selectedModelID)
            }
            reachedConfirmedEligibility = true
            let model = try ScribeModelIdentifier(selectedModelID)
            guard model.rawValue == selectedModelID else {
                return .needsAttention(selectedModelID: selectedModelID)
            }
            let credential = try await credentialLoader(.openAIDirect)
            try await OpenAIDirectScribeProvider(
                model: model,
                credentialLoader: { credential },
                transport: transport
            ).validateConnection()
            validatedSelections[.openAIDirect, default: []].insert(selectedModelID)
            return .ready(selectedModelID: selectedModelID)
        } catch let failure as ScribeProviderFailure {
            if !reachedConfirmedEligibility {
                return discoveryFailureState(
                    failure: failure,
                    provider: .openAIDirect,
                    selectedModelID: selectedModelID
                )
            }
            return unavailableState(
                failure: failure,
                provider: .openAIDirect,
                selectedModelID: selectedModelID
            )
        } catch {
            return reachedConfirmedEligibility
                ? .needsAttention(selectedModelID: selectedModelID)
                : preservedState(for: .openAIDirect, selectedModelID: selectedModelID)
        }
    }

    /// Session-memory candidates for the searchable chooser. OpenRouter entries have
    /// already passed visibility, text-output, and ZDR filtering; readiness still
    /// requires exact-adapter validation of the selected identifier.
    func availableModelIDs(for provider: ScribeProviderKind) -> [String] {
        availableModels(for: provider).map(\.modelID)
    }

    func availableModels(
        for provider: ScribeProviderKind,
        customModelID: String? = nil
    ) -> [ScribeSearchableModelEntry] {
        var merged: [String: ScribeSearchableModelEntry] = [:]
        for entry in bundledCatalog.entries where
            bundledCatalog.revision >= 0
                && entry.providerKind == provider
                && entry.source == .bundled
                && Self.isExactModelIdentifier(entry.modelID)
                && Self.isSafeDisplayName(entry.displayName) {
            merged[entry.modelID] = entry
        }
        let liveCompatibility: ScribeModelCompatibility = provider == .openRouter
            ? .liveEligible
            : .liveVisible
        for live in discoveredModels[provider] ?? [] {
            let modelID = live.modelID
            if let bundled = merged[modelID] {
                merged[modelID] = ScribeSearchableModelEntry(
                    providerKind: provider,
                    modelID: modelID,
                    displayName: bundled.displayName,
                    recommendation: bundled.recommendation,
                    source: bundled.source,
                    compatibility: liveCompatibility,
                    canonicalSlug: live.canonicalSlug ?? bundled.canonicalSlug,
                    providerDisplayName: live.providerDisplayName,
                    searchTerms: Array(Set(bundled.searchTerms + live.searchTerms)).sorted(),
                    contextLength: live.contextLength ?? bundled.contextLength,
                    supportedParameters: live.supportedParameters,
                    expiry: live.expiry,
                    eligibilityFacts: live.eligibilityFacts,
                    outputModalities: live.outputModalities
                )
            } else {
                merged[modelID] = live
            }
        }
        if let customModelID,
           Self.isExactModelIdentifier(customModelID),
           merged[customModelID] == nil {
            merged[customModelID] = ScribeSearchableModelEntry(
                providerKind: provider,
                modelID: customModelID,
                displayName: customModelID,
                recommendation: .none,
                source: .custom,
                compatibility: .requiresValidation
            )
        }
        return merged.values.sorted { $0.modelID < $1.modelID }
    }

    private func discoveryGET(_ url: URL, provider: ScribeProviderKind) async throws -> Data {
        let key = try await credentialLoader(provider)
        guard !key.isEmpty else {
            throw FixedOriginScribeProviderSupport.failure(.validation, .credentialRejected, .reconnect)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return try await FixedOriginScribeProviderSupport.send(
            request, phase: .validation, transport: transport
        )
    }

    private func authorized(
        _ receipt: ScribeProviderConsentReceipt?,
        for provider: ScribeProviderKind
    ) async -> Bool {
        guard let receipt,
              await consentVerifier(receipt),
              receipt.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
              receipt.providerKind == provider,
              receipt.disclosureRevision == ScribeProviderDisclosure.currentVersion,
              receipt.acceptedAt.timeIntervalSince1970.isFinite,
              receipt.acceptedAt.timeIntervalSince1970 > 0 else { return false }
        switch provider {
        case .openAIDirect:
            return receipt.recipientOrigin == "https://api.openai.com"
                && receipt.routingPolicy == .directSingleModel
                && receipt.retentionPolicy == .requestStorageDisabled
                && receipt.dataPolicy == .providerPolicyApplies
        case .openRouter:
            return receipt.recipientOrigin == "https://openrouter.ai"
                && receipt.routingPolicy == .zeroDataRetentionSingleModel
                && receipt.retentionPolicy == .zeroDataRetentionRequired
                && receipt.dataPolicy == .collectionDenied
        default:
            return false
        }
    }

    private func unavailableState(
        failure: ScribeProviderFailure,
        provider: ScribeProviderKind,
        selectedModelID: String
    ) -> ScribeModelSelectionState {
        guard [.transportUnavailable, .timedOut, .providerUnavailable]
            .contains(failure.category) else {
            return .needsAttention(selectedModelID: selectedModelID)
        }
        if validatedSelections[provider]?.contains(selectedModelID) == true {
            return .offlinePreserved(selectedModelID: selectedModelID)
        }
        return .needsAttention(selectedModelID: selectedModelID)
    }

    private func preservedState(
        for provider: ScribeProviderKind,
        selectedModelID: String
    ) -> ScribeModelSelectionState {
        validatedSelections[provider]?.contains(selectedModelID) == true
            ? .offlinePreserved(selectedModelID: selectedModelID)
            : .needsAttention(selectedModelID: selectedModelID)
    }

    private func discoveryFailureState(
        failure: ScribeProviderFailure,
        provider: ScribeProviderKind,
        selectedModelID: String
    ) -> ScribeModelSelectionState {
        let transientOrFeedFailure: Set<ScribeProviderFailureCategory> = [
            .transportUnavailable, .timedOut, .providerUnavailable, .invalidResponse,
            .rateLimited, .incompatibleRequest, .endpointNotFound
        ]
        guard transientOrFeedFailure.contains(failure.category) else {
            return .needsAttention(selectedModelID: selectedModelID)
        }
        return preservedState(for: provider, selectedModelID: selectedModelID)
    }

    private static func isExactModelIdentifier(_ value: String) -> Bool {
        guard let identifier = try? ScribeModelIdentifier(value) else { return false }
        return identifier.rawValue == value
    }

    private static func isSafeDisplayName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value && value.utf8.count <= 128
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    private static func openRouterEntry(
        _ model: OpenRouterModel
    ) throws -> ScribeSearchableModelEntry {
        guard isExactModelIdentifier(model.id) else {
            throw ScribeProviderConfigurationError.invalidModel
        }
        let displayName = model.name ?? model.id
        guard isSafeDisplayName(displayName),
              model.canonicalSlug.map(isBoundedMetadata) ?? true,
              model.expirationDate.map(isBoundedMetadata) ?? true,
              model.contextLength.map({ $0 > 0 }) ?? true,
              (model.supportedParameters?.count ?? 0) <= 64,
              model.supportedParameters?.allSatisfy(isBoundedMetadata) ?? true else {
            throw ScribeProviderConfigurationError.invalidModel
        }
        let providerName = model.id.split(separator: "/").first.map(String.init) ?? "OpenRouter"
        guard isSafeDisplayName(providerName) else {
            throw ScribeProviderConfigurationError.invalidModel
        }
        let terms = Array(Set([
            model.id, model.canonicalSlug, model.name, providerName
        ].compactMap { $0 })).sorted()
        return ScribeSearchableModelEntry(
            providerKind: .openRouter,
            modelID: model.id,
            displayName: displayName,
            recommendation: .none,
            source: .live,
            compatibility: .liveEligible,
            canonicalSlug: model.canonicalSlug,
            providerDisplayName: providerName,
            searchTerms: terms,
            contextLength: model.contextLength,
            supportedParameters: (model.supportedParameters ?? []).sorted(),
            expiry: model.expirationDate,
            eligibilityFacts: [
                .authenticatedUserVisible, .textOutput, .zeroDataRetentionEndpoint
            ],
            outputModalities: model.architecture.outputModalities.sorted()
        )
    }

    private static func isBoundedMetadata(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

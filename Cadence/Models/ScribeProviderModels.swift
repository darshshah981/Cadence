import Foundation

enum ScribeProviderKind: String, CaseIterable, Codable, Equatable, Sendable {
    case deepSeek
    case openAIDirect
    case openRouter
    case advanced
    case legacyLocal

    var displayName: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .openAIDirect: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .advanced: return "Advanced provider"
        case .legacyLocal: return "On-device provider"
        }
    }
}

enum ScribeProviderRoutingPolicy: String, Codable, Equatable, Sendable {
    case directSingleModel
    case zeroDataRetentionSingleModel
    case providerControlledSingleModel
}

enum ScribeProviderRetentionPolicy: String, Codable, Equatable, Sendable {
    case requestStorageDisabled
    case zeroDataRetentionRequired
    case providerControlled
}

enum ScribeProviderDataPolicy: String, Codable, Equatable, Sendable {
    case providerPolicyApplies
    case collectionDenied
    case providerControlled
}

enum ScribeCredentialStorageDomain: String, Codable, Equatable, Hashable, Sendable {
    case inherited
    case candidate
}

struct ScribeStoredCredentialReference: Codable, Equatable, Hashable, Sendable {
    let domain: ScribeCredentialStorageDomain
    let opaqueReference: ScribeCredentialReference
}

/// Material provider consent. Model identifiers are intentionally absent so an exact-model
/// change under the same recipient and privacy contract does not invalidate consent.
struct ScribeProviderConsentReceipt: Codable, Equatable, Sendable {
    let id: UUID
    let providerKind: ScribeProviderKind
    let recipientOrigin: String
    let routingPolicy: ScribeProviderRoutingPolicy
    let retentionPolicy: ScribeProviderRetentionPolicy
    let dataPolicy: ScribeProviderDataPolicy
    let disclosureRevision: Int
    let acceptedAt: Date

    fileprivate init(
        id: UUID,
        providerKind: ScribeProviderKind,
        recipientOrigin: String,
        routingPolicy: ScribeProviderRoutingPolicy,
        retentionPolicy: ScribeProviderRetentionPolicy,
        dataPolicy: ScribeProviderDataPolicy,
        disclosureRevision: Int,
        acceptedAt: Date
    ) {
        self.id = id
        self.providerKind = providerKind
        self.recipientOrigin = recipientOrigin
        self.routingPolicy = routingPolicy
        self.retentionPolicy = retentionPolicy
        self.dataPolicy = dataPolicy
        self.disclosureRevision = disclosureRevision
        self.acceptedAt = acceptedAt
    }
}

/// The consent authority is the only production component that should issue and retain these
/// values. Catalog use additionally requires its injected verifier to confirm the opaque ID.
enum ScribeProviderConsentIssuer {
    static func issue(
        id: UUID = UUID(),
        providerKind: ScribeProviderKind,
        recipientOrigin: String,
        routingPolicy: ScribeProviderRoutingPolicy,
        retentionPolicy: ScribeProviderRetentionPolicy,
        dataPolicy: ScribeProviderDataPolicy,
        disclosureRevision: Int,
        acceptedAt: Date
    ) -> ScribeProviderConsentReceipt {
        ScribeProviderConsentReceipt(
            id: id,
            providerKind: providerKind,
            recipientOrigin: recipientOrigin,
            routingPolicy: routingPolicy,
            retentionPolicy: retentionPolicy,
            dataPolicy: dataPolicy,
            disclosureRevision: disclosureRevision,
            acceptedAt: acceptedAt
        )
    }
}

extension ScribeProviderConsentReceipt {
    func materiallyMatches(_ configuration: ScribeProviderLibraryConfiguration) -> Bool {
        guard providerKind == configuration.kind,
              recipientOrigin == configuration.normalizedOrigin,
              disclosureRevision == configuration.disclosureVersion else { return false }
        switch configuration.kind {
        case .openAIDirect:
            return routingPolicy == .directSingleModel
                && retentionPolicy == .requestStorageDisabled
                && dataPolicy == .providerPolicyApplies
        case .openRouter:
            return routingPolicy == .zeroDataRetentionSingleModel
                && retentionPolicy == .zeroDataRetentionRequired
                && dataPolicy == .collectionDenied
        case .deepSeek, .advanced:
            return routingPolicy == .providerControlledSingleModel
                && retentionPolicy == .providerControlled
                && dataPolicy == .providerControlled
        case .legacyLocal:
            return false
        }
    }
}

struct ScribePriorValidatedModelSelection: Equatable, Sendable {
    let providerKind: ScribeProviderKind
    let selectedModelID: String
    let lastValidatedAt: Date
    let disclosureRevision: Int

    private init(
        providerKind: ScribeProviderKind,
        selectedModelID: String,
        lastValidatedAt: Date,
        disclosureRevision: Int
    ) {
        self.providerKind = providerKind
        self.selectedModelID = selectedModelID
        self.lastValidatedAt = lastValidatedAt
        self.disclosureRevision = disclosureRevision
    }

    init?(configuration: ScribeProviderLibraryConfiguration) {
        guard configuration.isEnabled,
              configuration.kind == .openAIDirect || configuration.kind == .openRouter,
              ScribeProviderLibraryConfigurationValidator.isValid(configuration) else {
            return nil
        }
        self.init(
            providerKind: configuration.kind,
            selectedModelID: configuration.selectedModelID,
            lastValidatedAt: configuration.lastValidatedAt,
            disclosureRevision: configuration.disclosureVersion
        )
    }
}

enum ScribeModelRecommendation: String, Equatable, Sendable {
    case none
    case recommended
}

enum ScribeModelCatalogSource: String, Equatable, Sendable {
    case bundled
    case live
    case custom
}

enum ScribeModelCompatibility: String, Equatable, Sendable {
    case requiresValidation
    case liveVisible
    case liveEligible
}

enum ScribeModelEligibilityFact: String, Equatable, Hashable, Sendable {
    case authenticatedUserVisible
    case textOutput
    case zeroDataRetentionEndpoint
}

/// Privacy-safe chooser metadata. Deliberately not Codable so live account catalogs cannot
/// be accidentally persisted through the application's envelope stores.
struct ScribeSearchableModelEntry: Equatable, Identifiable, Sendable {
    var id: String { "\(providerKind.rawValue):\(modelID)" }
    let providerKind: ScribeProviderKind
    let modelID: String
    let displayName: String
    let recommendation: ScribeModelRecommendation
    let source: ScribeModelCatalogSource
    let compatibility: ScribeModelCompatibility
    let canonicalSlug: String?
    let providerDisplayName: String
    let searchTerms: [String]
    let contextLength: Int?
    let supportedParameters: [String]
    let expiry: String?
    let eligibilityFacts: Set<ScribeModelEligibilityFact>
    let outputModalities: [String]

    init(
        providerKind: ScribeProviderKind,
        modelID: String,
        displayName: String,
        recommendation: ScribeModelRecommendation,
        source: ScribeModelCatalogSource,
        compatibility: ScribeModelCompatibility,
        canonicalSlug: String? = nil,
        providerDisplayName: String? = nil,
        searchTerms: [String] = [],
        contextLength: Int? = nil,
        supportedParameters: [String] = [],
        expiry: String? = nil,
        eligibilityFacts: Set<ScribeModelEligibilityFact> = [],
        outputModalities: [String] = []
    ) {
        self.providerKind = providerKind
        self.modelID = modelID
        self.displayName = displayName
        self.recommendation = recommendation
        self.source = source
        self.compatibility = compatibility
        self.canonicalSlug = canonicalSlug
        self.providerDisplayName = providerDisplayName ?? providerKind.displayName
        self.searchTerms = searchTerms
        self.contextLength = contextLength
        self.supportedParameters = supportedParameters
        self.expiry = expiry
        self.eligibilityFacts = eligibilityFacts
        self.outputModalities = outputModalities
    }
}

enum ScribeBundledModelCatalogError: Error, Equatable, Sendable {
    case unsupportedRevision
    case duplicateModel
    case invalidEntry
}

struct ScribeBundledModelCatalog: Equatable, Sendable {
    let revision: Int
    let entries: [ScribeSearchableModelEntry]

    init(revision: Int, entries: [ScribeSearchableModelEntry]) throws {
        guard revision == 1 else { throw ScribeBundledModelCatalogError.unsupportedRevision }
        var identities: Set<String> = []
        for entry in entries {
            let identity = "\(entry.providerKind.rawValue):\(entry.modelID)"
            guard identities.insert(identity).inserted else {
                throw ScribeBundledModelCatalogError.duplicateModel
            }
            guard entry.source == .bundled,
                  entry.compatibility == .requiresValidation,
                  entry.eligibilityFacts.isEmpty,
                  entry.outputModalities.count <= 16,
                  entry.outputModalities.allSatisfy({ Self.isStable($0, maximumBytes: 64) }),
                  Self.isStable(entry.modelID, maximumBytes: 256),
                  (try? ScribeModelIdentifier(entry.modelID))?.rawValue == entry.modelID,
                  Self.isStable(entry.displayName, maximumBytes: 128),
                  Self.isStable(entry.providerDisplayName, maximumBytes: 128),
                  entry.searchTerms.count <= 16,
                  entry.searchTerms.allSatisfy({ Self.isStable($0, maximumBytes: 256) }),
                  entry.supportedParameters.count <= 64,
                  entry.supportedParameters.allSatisfy({ Self.isStable($0, maximumBytes: 128) }),
                  entry.canonicalSlug.map({ Self.isStable($0, maximumBytes: 256) }) ?? true,
                  entry.expiry.map({ Self.isStable($0, maximumBytes: 256) }) ?? true,
                  entry.contextLength.map({ $0 > 0 }) ?? true else {
                throw ScribeBundledModelCatalogError.invalidEntry
            }
        }
        self.revision = revision
        self.entries = entries.sorted {
            ($0.providerKind.rawValue, $0.modelID) < ($1.providerKind.rawValue, $1.modelID)
        }
    }

    private static func isStable(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    static let empty = try! ScribeBundledModelCatalog(revision: 1, entries: [])
}

enum ScribeProviderConfigurationError: String, Error, Equatable, Sendable {
    case invalidBaseURL
    case insecureBaseURL
    case embeddedCredentials
    case queryOrFragment
    case unsafePath
    case requestURLInsteadOfBase
    case invalidModel
}

struct AdvancedScribeEndpoint: Codable, Equatable, Sendable {
    let normalizedOrigin: String
    let normalizedBaseURL: URL
    let requestURL: URL

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host,
              !host.isEmpty else {
            throw ScribeProviderConfigurationError.invalidBaseURL
        }
        guard scheme.lowercased() == "https" else {
            throw ScribeProviderConfigurationError.insecureBaseURL
        }
        guard components.user == nil, components.password == nil else {
            throw ScribeProviderConfigurationError.embeddedCredentials
        }
        guard components.query == nil, components.fragment == nil else {
            throw ScribeProviderConfigurationError.queryOrFragment
        }

        let encodedPath = components.percentEncodedPath
        guard encodedPath.range(
            of: "%2f|%5c",
            options: [.regularExpression, .caseInsensitive]
        ) == nil else {
            throw ScribeProviderConfigurationError.unsafePath
        }
        let pathSegments = encodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard pathSegments.allSatisfy({ segment in
            let decoded = String(segment).removingPercentEncoding ?? String(segment)
            return decoded != "." && decoded != ".."
        }) else {
            throw ScribeProviderConfigurationError.unsafePath
        }

        var normalizedPath = encodedPath
        while normalizedPath.hasSuffix("/") { normalizedPath.removeLast() }
        guard !normalizedPath.lowercased().hasSuffix("/chat/completions") else {
            throw ScribeProviderConfigurationError.requestURLInsteadOfBase
        }

        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        components.percentEncodedPath = normalizedPath
        components.query = nil
        components.fragment = nil
        guard let baseURL = components.url else {
            throw ScribeProviderConfigurationError.invalidBaseURL
        }

        var originComponents = components
        originComponents.percentEncodedPath = ""
        guard let originURL = originComponents.url else {
            throw ScribeProviderConfigurationError.invalidBaseURL
        }
        let endpointString = baseURL.absoluteString + "/chat/completions"
        guard let requestURL = URL(string: endpointString) else {
            throw ScribeProviderConfigurationError.invalidBaseURL
        }

        self.normalizedOrigin = originURL.absoluteString
        self.normalizedBaseURL = baseURL
        self.requestURL = requestURL
    }
}

struct ScribeModelIdentifier: Codable, Equatable, Sendable {
    let rawValue: String

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ScribeProviderConfigurationError.invalidModel
        }
        rawValue = trimmed
    }
}

struct ScribeCredentialReference: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String
}

struct DeepSeekScribeCatalogEntry: Equatable, Sendable {
    let displayName: String
    let catalogID: String
    let modelID: String
    let endpoint: URL
    let acceptedResponseModelIDs: Set<String>
    let thinkingDisabled: Bool
    let introducedCadenceVersion: String
    let documentationReviewedOn: String
}

struct ScribeProviderCatalog: Equatable, Sendable {
    let deepSeekEntries: [DeepSeekScribeCatalogEntry]

    static let releaseOne = ScribeProviderCatalog(deepSeekEntries: [
        DeepSeekScribeCatalogEntry(
            displayName: "DeepSeek V4 Flash",
            catalogID: "deepseek.v4-flash.non-thinking.v1",
            modelID: "deepseek-v4-flash",
            endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
            acceptedResponseModelIDs: ["deepseek-v4-flash"],
            thinkingDisabled: true,
            introducedCadenceVersion: "1",
            documentationReviewedOn: "2026-07-10"
        )
    ])
}

struct ScribeProviderCandidateConfiguration: Equatable, Sendable {
    static let currentDisclosureVersion = ScribeProviderDisclosure.currentVersion

    let kind: ScribeProviderKind
    let normalizedOrigin: String
    let baseURL: URL
    let requestURL: URL
    let modelID: String
    let catalogID: String?
    let disclosureVersion: Int
    let acceptedAt: Date

    static func deepSeek(acceptedAt: Date) throws -> ScribeProviderCandidateConfiguration {
        guard let entry = ScribeProviderCatalog.releaseOne.deepSeekEntries.first else {
            throw ScribeProviderConfigurationError.invalidModel
        }
        return ScribeProviderCandidateConfiguration(
            kind: .deepSeek,
            normalizedOrigin: "https://api.deepseek.com",
            baseURL: URL(string: "https://api.deepseek.com")!,
            requestURL: entry.endpoint,
            modelID: entry.modelID,
            catalogID: entry.catalogID,
            disclosureVersion: currentDisclosureVersion,
            acceptedAt: acceptedAt
        )
    }

    static func advanced(
        endpoint: AdvancedScribeEndpoint,
        model: ScribeModelIdentifier,
        acceptedAt: Date
    ) -> ScribeProviderCandidateConfiguration {
        ScribeProviderCandidateConfiguration(
            kind: .advanced,
            normalizedOrigin: endpoint.normalizedOrigin,
            baseURL: endpoint.normalizedBaseURL,
            requestURL: endpoint.requestURL,
            modelID: model.rawValue,
            catalogID: nil,
            disclosureVersion: currentDisclosureVersion,
            acceptedAt: acceptedAt
        )
    }

    func persisted(
        credentialReference: ScribeCredentialReference
    ) -> ScribeProviderConfiguration {
        ScribeProviderConfiguration(
            kind: kind,
            normalizedOrigin: normalizedOrigin,
            baseURL: baseURL,
            requestURL: requestURL,
            modelID: modelID,
            catalogID: catalogID,
            disclosureVersion: disclosureVersion,
            acceptedAt: acceptedAt,
            credentialReference: credentialReference,
            isEnabled: true
        )
    }
}

struct ScribeProviderConfiguration: Codable, Equatable, Sendable {
    let kind: ScribeProviderKind
    let normalizedOrigin: String
    let baseURL: URL
    let requestURL: URL
    let modelID: String
    let catalogID: String?
    let disclosureVersion: Int
    let acceptedAt: Date
    let credentialReference: ScribeCredentialReference
    var isEnabled: Bool

    static func deepSeek(
        credentialReference: ScribeCredentialReference,
        acceptedAt: Date
    ) throws -> ScribeProviderConfiguration {
        try ScribeProviderCandidateConfiguration.deepSeek(acceptedAt: acceptedAt)
            .persisted(credentialReference: credentialReference)
    }
}

enum ScribeProviderConfigurationRejection: Equatable, Sendable {
    case malformed
    case futureSchema
}

enum ScribeProviderConfigurationLoadResult: Equatable, Sendable {
    case absent
    case valid(ScribeProviderConfiguration)
    case rejected(ScribeProviderConfigurationRejection)
}

struct ScribeProviderConfigurationEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let configuration: ScribeProviderConfiguration

    init(
        schemaVersion: Int = ScribeProviderConfigurationEnvelope.currentSchemaVersion,
        configuration: ScribeProviderConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
    }
}

struct ScribeProviderLibraryConfiguration: Codable, Equatable, Identifiable, Sendable {
    /// Catalog identifiers are release-owned metadata and share the model-ID storage bound.
    static let maximumCatalogIDUTF8Bytes = 256

    let id: UUID
    let kind: ScribeProviderKind
    let displayName: String
    let normalizedOrigin: String
    let baseURL: URL
    let requestURL: URL
    let selectedModelID: String
    let catalogID: String?
    let disclosureVersion: Int
    let acceptedAt: Date
    let lastValidatedAt: Date
    let credentialReference: ScribeCredentialReference
    let credentialStorageDomain: ScribeCredentialStorageDomain?
    let consentReceipt: ScribeProviderConsentReceipt?
    let isEnabled: Bool

    var storedCredentialReference: ScribeStoredCredentialReference {
        ScribeStoredCredentialReference(
            domain: credentialStorageDomain ?? .inherited,
            opaqueReference: credentialReference
        )
    }

    init(
        id: UUID = UUID(),
        kind: ScribeProviderKind,
        displayName: String,
        normalizedOrigin: String,
        baseURL: URL,
        requestURL: URL,
        selectedModelID: String,
        catalogID: String?,
        disclosureVersion: Int,
        acceptedAt: Date,
        lastValidatedAt: Date,
        credentialReference: ScribeCredentialReference,
        isEnabled: Bool,
        credentialStorageDomain: ScribeCredentialStorageDomain? = nil,
        consentReceipt: ScribeProviderConsentReceipt? = nil
    ) throws {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.normalizedOrigin = normalizedOrigin
        self.baseURL = baseURL
        self.requestURL = requestURL
        self.selectedModelID = selectedModelID
        self.catalogID = catalogID
        self.disclosureVersion = disclosureVersion
        self.acceptedAt = acceptedAt
        self.lastValidatedAt = lastValidatedAt
        self.credentialReference = credentialReference
        self.credentialStorageDomain = credentialStorageDomain
        self.consentReceipt = consentReceipt
        self.isEnabled = isEnabled
    }

    func normalized() -> ScribeProviderLibraryConfiguration {
        let normalizedCatalogID = catalogID?
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try! ScribeProviderLibraryConfiguration(
            id: id,
            kind: kind,
            displayName: displayName.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedOrigin: normalizedOrigin.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL,
            requestURL: requestURL,
            selectedModelID: selectedModelID.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines),
            catalogID: normalizedCatalogID?.isEmpty == true ? nil : normalizedCatalogID,
            disclosureVersion: disclosureVersion,
            acceptedAt: acceptedAt,
            lastValidatedAt: lastValidatedAt,
            credentialReference: credentialReference,
            isEnabled: isEnabled,
            credentialStorageDomain: credentialStorageDomain,
            consentReceipt: consentReceipt
        )
    }

    func withEnabled(_ isEnabled: Bool) -> ScribeProviderLibraryConfiguration {
        replacing(isEnabled: isEnabled)
    }

    func withOrigin(_ normalizedOrigin: String) -> ScribeProviderLibraryConfiguration {
        replacing(normalizedOrigin: normalizedOrigin)
    }

    private func replacing(
        normalizedOrigin: String? = nil,
        isEnabled: Bool? = nil
    ) -> ScribeProviderLibraryConfiguration {
        try! ScribeProviderLibraryConfiguration(
            id: id,
            kind: kind,
            displayName: displayName,
            normalizedOrigin: normalizedOrigin ?? self.normalizedOrigin,
            baseURL: baseURL,
            requestURL: requestURL,
            selectedModelID: selectedModelID,
            catalogID: catalogID,
            disclosureVersion: disclosureVersion,
            acceptedAt: acceptedAt,
            lastValidatedAt: lastValidatedAt,
            credentialReference: credentialReference,
            isEnabled: isEnabled ?? self.isEnabled,
            credentialStorageDomain: credentialStorageDomain,
            consentReceipt: consentReceipt
        )
    }
}

enum ScribeProviderLibraryConfigurationValidator {
    static func isValid(_ configuration: ScribeProviderLibraryConfiguration) -> Bool {
        let value = configuration.normalized()
        guard !value.displayName.isEmpty,
              value.displayName.utf8.count <= 256,
              !value.displayName.unicodeScalars.contains(where: isUnsupportedControl),
              (try? ScribeModelIdentifier(value.selectedModelID)) != nil,
              !value.credentialReference.rawValue.isEmpty,
              value.credentialReference.rawValue.utf8.count <= 256,
              !value.credentialReference.rawValue.unicodeScalars.contains(where: isUnsupportedControl),
              value.disclosureVersion > 0,
              value.acceptedAt <= value.lastValidatedAt else { return false }
        if let catalogID = value.catalogID {
            guard !catalogID.isEmpty,
                  catalogID.utf8.count <= ScribeProviderLibraryConfiguration.maximumCatalogIDUTF8Bytes,
                  !catalogID.unicodeScalars.contains(where: isUnsupportedControl) else { return false }
        }
        if let receipt = value.consentReceipt {
            guard value.kind != .legacyLocal,
                  receipt.materiallyMatches(value),
                  receipt.acceptedAt <= value.lastValidatedAt else { return false }
        } else if value.kind == .legacyLocal {
            guard value.credentialStorageDomain == nil else { return false }
        }
        switch value.kind {
        case .deepSeek:
            return value.normalizedOrigin == "https://api.deepseek.com"
                && value.baseURL.absoluteString == "https://api.deepseek.com"
                && value.requestURL.absoluteString == "https://api.deepseek.com/chat/completions"
        case .openAIDirect:
            return value.normalizedOrigin == "https://api.openai.com"
                && value.baseURL.absoluteString == "https://api.openai.com"
                && value.requestURL.absoluteString == "https://api.openai.com/v1/responses"
        case .openRouter:
            return value.normalizedOrigin == "https://openrouter.ai"
                && value.baseURL.absoluteString == "https://openrouter.ai"
                && value.requestURL.absoluteString == "https://openrouter.ai/api/v1/chat/completions"
        case .advanced:
            guard let endpoint = try? AdvancedScribeEndpoint(value.baseURL.absoluteString) else { return false }
            return endpoint.normalizedOrigin == value.normalizedOrigin
                && endpoint.normalizedBaseURL == value.baseURL
                && endpoint.requestURL == value.requestURL
        case .legacyLocal:
            return value.normalizedOrigin == "local://this-mac"
        }
    }

    private static func isUnsupportedControl(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}

struct ScribeProviderLibrary: Codable, Equatable, Sendable {
    let revision: Int
    let configurations: [ScribeProviderLibraryConfiguration]
    let activeConfigurationID: UUID?

    func normalized() -> ScribeProviderLibrary {
        ScribeProviderLibrary(
            revision: revision,
            configurations: configurations
                .map { $0.normalized() }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            activeConfigurationID: activeConfigurationID
        )
    }

    func semanticallyEquals(_ other: ScribeProviderLibrary) -> Bool {
        normalized() == other.normalized()
    }
}

struct ScribeProviderLibraryEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let library: ScribeProviderLibrary

    init(
        schemaVersion: Int = ScribeProviderLibraryEnvelope.currentSchemaVersion,
        library: ScribeProviderLibrary
    ) {
        self.schemaVersion = schemaVersion
        self.library = library
    }
}

enum ScribeProviderLibraryRejection: Equatable, Sendable {
    case malformed
    case futureSchema
    case duplicateConfigurationID
    case duplicateProviderKind
    case duplicateCredentialReference
    case invalidActiveConfigurationID
    case disabledActiveConfiguration
    case invalidConfiguration
}

enum ScribeProviderLibraryLoadResult: Equatable, Sendable {
    case absent
    case valid(ScribeProviderLibrary)
    case rejected(ScribeProviderLibraryRejection)
}

enum ScribeCredentialReferenceSet: Equatable, Sendable {
    case available(Set<ScribeCredentialReference>)
    case unavailable
}

enum ScribeProviderReadiness: Equatable, Sendable {
    case disabled
    case setupRequired
    case validating
    case ready(ScribeProviderKind)
    case temporarilyUnavailable(ScribeProviderKind)
    case configurationInvalid
    case needsAttention(ScribeProviderKind)
    case deprecated(ScribeProviderKind)
    case removed
}

enum ScribeProviderPhase: String, Codable, Equatable, Sendable {
    case validation
    case generation
}

enum ScribeProviderFailureCategory: String, Codable, Equatable, Sendable {
    case setupRequired
    case configurationInvalid
    case credentialRejected
    case balanceRequired
    case rateLimited
    case transportUnavailable
    case unsafeConnection
    case timedOut
    case providerUnavailable
    case providerRejected
    case incompatibleRequest
    case endpointNotFound
    case invalidResponse
    case cancelled
}

enum ScribeProviderRetryDisposition: String, Codable, Equatable, Sendable {
    case none
    case manualNow
    case manualAfterWait
    case reconnect
    case updateCadence
    case changeConfiguration
}

struct ScribeProviderFailure: Error, Equatable, Sendable {
    let phase: ScribeProviderPhase
    let category: ScribeProviderFailureCategory
    let retryDisposition: ScribeProviderRetryDisposition
    let retryAfterSeconds: Int?

    init(
        phase: ScribeProviderPhase,
        category: ScribeProviderFailureCategory,
        retryDisposition: ScribeProviderRetryDisposition,
        retryAfterSeconds: Int? = nil
    ) {
        self.phase = phase
        self.category = category
        self.retryDisposition = retryDisposition
        self.retryAfterSeconds = retryAfterSeconds
    }
}

extension ScribeProviderFailure {
    var userMessage: String {
        switch category {
        case .setupRequired:
            return "Scribe needs an AI provider. Connect one in Scribe settings."
        case .configurationInvalid:
            return "The saved Scribe provider needs attention. Reconnect it in Scribe settings."
        case .credentialRejected:
            return "The provider rejected this API key or account access."
        case .balanceRequired:
            return "DeepSeek reports that this account needs balance before Scribe can run."
        case .rateLimited:
            return "The provider is temporarily rate limited. Try again after it recovers."
        case .transportUnavailable:
            return "Cadence could not reach the provider. Check the network and endpoint."
        case .unsafeConnection:
            return "Cadence refused a redirect or unsafe connection. Check the endpoint and trust settings."
        case .timedOut:
            return "The provider check took too long and was cancelled."
        case .providerUnavailable:
            return "The provider is temporarily unavailable."
        case .providerRejected:
            return "The provider rejected this compatibility request."
        case .incompatibleRequest:
            return "This endpoint or bundled provider profile is not compatible with Cadence."
        case .endpointNotFound:
            return "The endpoint or model was not found."
        case .invalidResponse:
            return "Cadence received a response it could not safely use."
        case .cancelled:
            return "Provider validation was cancelled."
        }
    }
}

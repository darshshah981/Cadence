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
    let isEnabled: Bool

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
        isEnabled: Bool
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
            isEnabled: isEnabled
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
            isEnabled: isEnabled ?? self.isEnabled
        )
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

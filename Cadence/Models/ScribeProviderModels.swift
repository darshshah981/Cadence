import Foundation

enum ScribeProviderKind: String, CaseIterable, Codable, Equatable, Sendable {
    case deepSeek
    case advanced
    case legacyLocal

    var displayName: String {
        switch self {
        case .deepSeek: return "DeepSeek"
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

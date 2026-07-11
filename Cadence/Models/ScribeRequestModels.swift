import Foundation

enum ScribeLiteralSource: String, Codable, Equatable, Sendable {
    case alreadyExact
    case vocabularyAlias
    case explicitGrammar
    case safeAutomaticPattern
}

struct ScribeSourceRange: Codable, Equatable, Sendable {
    let utf16Location: Int
    let utf16Length: Int
}

struct ScribeExactLiteral: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let value: String
    let source: ScribeLiteralSource
    let sourceRange: ScribeSourceRange?

    init(
        id: Int,
        value: String,
        source: ScribeLiteralSource,
        sourceRange: ScribeSourceRange? = nil
    ) {
        self.id = id
        self.value = value
        self.source = source
        self.sourceRange = sourceRange
    }
}

enum ScribeLiteralParseStatus: Equatable, Sendable {
    case clean
    case needsLocalRepair
}

struct NormalizedScribeTranscript: Equatable, Sendable {
    let text: String
    let exactLiterals: [ScribeExactLiteral]
    let parseStatus: ScribeLiteralParseStatus
}

struct ProviderSafeScribeInput: Equatable, Sendable {
    let systemMessage: String
    let userMessage: String
}

struct ScribeProviderRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let input: ProviderSafeScribeInput
}

struct ScribeEgressDestination: Equatable, Sendable {
    let providerKind: ScribeProviderKind
    let recipientOrigin: String
    let disclosureVersion: Int
    let isRemote: Bool

    static let deepSeek = ScribeEgressDestination(
        providerKind: .deepSeek,
        recipientOrigin: "https://api.deepseek.com",
        disclosureVersion: ScribeProviderDisclosure.currentVersion,
        isRemote: true
    )

    static let openAIDirect = ScribeEgressDestination(
        providerKind: .openAIDirect,
        recipientOrigin: "https://api.openai.com",
        disclosureVersion: ScribeProviderDisclosure.currentVersion,
        isRemote: true
    )

    static let openRouter = ScribeEgressDestination(
        providerKind: .openRouter,
        recipientOrigin: "https://openrouter.ai",
        disclosureVersion: ScribeProviderDisclosure.currentVersion,
        isRemote: true
    )

    static let legacyLocal = ScribeEgressDestination(
        providerKind: .legacyLocal,
        recipientOrigin: "local://this-mac",
        disclosureVersion: ScribeProviderDisclosure.currentVersion,
        isRemote: false
    )

    static func advanced(origin: String, disclosureVersion: Int) -> ScribeEgressDestination {
        ScribeEgressDestination(
            providerKind: .advanced,
            recipientOrigin: origin,
            disclosureVersion: disclosureVersion,
            isRemote: true
        )
    }
}

struct ScribeExplicitSelectionArtifact: Equatable, Sendable {
    let captureID: UUID
    let target: ScribeTargetIdentity
    let verificationToken: String
    let text: String
}

enum ScribeContextArtifact: Equatable, Sendable {
    case explicitSelection(ScribeExplicitSelectionArtifact)
}

struct ScribeContextAuthorization: Equatable, Sendable {
    let scope: ScribeContextScope
    let providerKind: ScribeProviderKind
    let recipientOrigin: String
    let disclosureVersion: Int
    let captureID: UUID
    let target: ScribeTargetIdentity
    let verificationToken: String
}

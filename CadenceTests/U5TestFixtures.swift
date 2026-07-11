import Foundation
@testable import Cadence

enum U5Fixtures {
    static func configuration(
        id: UUID = UUID(),
        kind: ScribeProviderKind,
        model: String,
        receipt: ScribeProviderConsentReceipt?,
        reference: ScribeStoredCredentialReference = .init(
            domain: .candidate,
            opaqueReference: .init(rawValue: "credential")
        ),
        enabled: Bool = true,
        catalogID: String? = nil
    ) throws -> ScribeProviderLibraryConfiguration {
        let origin: String
        let requestURL: URL
        switch kind {
        case .openAIDirect:
            origin = "https://api.openai.com"
            requestURL = URL(string: "https://api.openai.com/v1/responses")!
        case .openRouter:
            origin = "https://openrouter.ai"
            requestURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .deepSeek:
            origin = "https://api.deepseek.com"
            requestURL = URL(string: "https://api.deepseek.com/chat/completions")!
        case .advanced:
            origin = "https://custom.example"
            requestURL = URL(string: "https://custom.example/chat/completions")!
        case .legacyLocal:
            origin = "local://this-mac"
            requestURL = URL(string: origin)!
        }
        return try ScribeProviderLibraryConfiguration(
            id: id,
            kind: kind,
            displayName: kind.displayName,
            normalizedOrigin: origin,
            baseURL: URL(string: origin)!,
            requestURL: requestURL,
            selectedModelID: model,
            catalogID: catalogID ?? (kind == .deepSeek
                ? ScribeProviderCatalog.releaseOne.deepSeekEntries.first?.catalogID
                : nil),
            disclosureVersion: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10),
            lastValidatedAt: Date(timeIntervalSince1970: 20),
            credentialReference: reference.opaqueReference,
            isEnabled: enabled,
            credentialStorageDomain: reference.domain,
            consentReceipt: receipt
        )
    }
}

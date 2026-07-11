import Foundation

enum ScribeProviderConnectionError: Error, Equatable {
    case validationFailed
}

@MainActor
final class ScribeProviderConnectionManager {
    typealias Validator = @Sendable (
        ScribeProviderCandidateConfiguration,
        String
    ) async throws -> Void

    private let configurationStore: any ScribeProviderConfigurationPersisting
    private let credentialStore: any ScribeCredentialStoring

    init(
        configurationStore: any ScribeProviderConfigurationPersisting,
        credentialStore: any ScribeCredentialStoring
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
    }

    func connect(
        candidate: ScribeProviderCandidateConfiguration,
        credential: String,
        validate: Validator
    ) async throws -> ScribeProviderConfiguration {
        try await validate(candidate, credential)
        try Task.checkCancellation()

        let oldConfiguration: ScribeProviderConfiguration?
        if case let .valid(configuration) = configurationStore.load() {
            oldConfiguration = configuration
        } else {
            oldConfiguration = nil
        }

        let stagedReference = try credentialStore.stage(credential)
        let connected = candidate.persisted(credentialReference: stagedReference)
        do {
            try Task.checkCancellation()
            try configurationStore.save(connected)
        } catch {
            try? credentialStore.delete(reference: stagedReference)
            throw error
        }

        if let oldReference = oldConfiguration?.credentialReference,
           oldReference != stagedReference {
            try? credentialStore.delete(reference: oldReference)
        }
        return connected
    }

    func removeProvider() throws {
        let activeReference: ScribeCredentialReference?
        if case let .valid(configuration) = configurationStore.load() {
            activeReference = configuration.credentialReference
        } else {
            activeReference = nil
        }
        try configurationStore.save(nil)
        if let activeReference {
            try credentialStore.delete(reference: activeReference)
        }
    }

    func removeUnreferencedCredentials() throws {
        let activeReference: ScribeCredentialReference?
        switch configurationStore.load() {
        case let .valid(configuration):
            activeReference = configuration.credentialReference
        case .absent:
            activeReference = nil
        case .rejected:
            return
        }
        for reference in try credentialStore.allReferences() where reference != activeReference {
            try credentialStore.delete(reference: reference)
        }
    }
}

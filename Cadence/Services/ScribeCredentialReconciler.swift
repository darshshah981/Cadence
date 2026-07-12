import Foundation

enum ScribeProtectedCredentialReferences: Equatable, Sendable {
    case available(Set<ScribeStoredCredentialReference>)
    case unavailable
}

actor ScribeCredentialReconciler {
    private let libraryStore: any ScribeProviderLibraryPersisting
    private let legacyStore: any ScribeProviderConfigurationPersisting
    private let ledgerStore: any ScribeCredentialCleanupLedgerPersisting
    private let vault: any ScribeCredentialVaulting

    init(
        libraryStore: any ScribeProviderLibraryPersisting,
        legacyStore: any ScribeProviderConfigurationPersisting,
        ledgerStore: any ScribeCredentialCleanupLedgerPersisting,
        vault: any ScribeCredentialVaulting
    ) {
        self.libraryStore = libraryStore
        self.legacyStore = legacyStore
        self.ledgerStore = ledgerStore
        self.vault = vault
    }

    func protectedReferences() -> ScribeProtectedCredentialReferences {
        var protected: Set<ScribeStoredCredentialReference> = []
        switch libraryStore.load() {
        case .absent: break
        case let .valid(library):
            protected.formUnion(library.configurations.map(\.storedCredentialReference))
        case .rejected: return .unavailable
        }
        switch legacyStore.load() {
        case .absent: break
        case let .valid(configuration):
            protected.insert(ScribeStoredCredentialReference(
                domain: .inherited,
                opaqueReference: configuration.credentialReference
            ))
        case .rejected: return .unavailable
        }
        if case .rejected = ledgerStore.load() { return .unavailable }
        return .available(protected)
    }

    func reconcile() async throws {
        guard case let .available(protected) = protectedReferences() else {
            throw ScribeProviderConnectionError.retainedStoreUnreadable
        }
        for reference in try await vault.candidateReferences() where !protected.contains(reference) {
            try await deleteOrRecord(reference, protected: protected)
        }
        guard case let .valid(ledger) = ledgerStore.load() else { return }
        for reference in ledger.references where !protected.contains(reference) {
            try await deleteOrRecord(reference, protected: protected)
        }
    }

    func deleteIfUnreferenced(_ reference: ScribeStoredCredentialReference) async throws {
        guard case let .available(protected) = protectedReferences() else {
            throw ScribeProviderConnectionError.retainedStoreUnreadable
        }
        guard !protected.contains(reference) else { return }
        try await deleteOrRecord(reference, protected: protected)
    }

    func recordTombstone(_ reference: ScribeStoredCredentialReference) throws {
        let current: ScribeCredentialCleanupLedger
        switch ledgerStore.load() {
        case .absent:
            current = ScribeCredentialCleanupLedger(revision: 0, references: [])
        case let .valid(ledger): current = ledger
        case .rejected: throw ScribeProviderConnectionError.retainedStoreUnreadable
        }
        var references = current.references
        references.insert(reference)
        try ledgerStore.save(ScribeCredentialCleanupLedger(
            revision: current.revision + 1,
            references: references
        ))
    }

    private func deleteOrRecord(
        _ reference: ScribeStoredCredentialReference,
        protected: Set<ScribeStoredCredentialReference>
    ) async throws {
        guard !protected.contains(reference) else { return }
        do {
            try await vault.delete(reference)
            try clearTombstone(reference)
        } catch {
            guard case let .available(latestProtected) = protectedReferences() else {
                throw ScribeProviderConnectionError.retainedStoreUnreadable
            }
            guard !latestProtected.contains(reference) else { return }
            try recordTombstone(reference)
        }
    }

    private func clearTombstone(_ reference: ScribeStoredCredentialReference) throws {
        let current: ScribeCredentialCleanupLedger
        switch ledgerStore.load() {
        case .absent: return
        case let .valid(ledger): current = ledger
        case .rejected: throw ScribeProviderConnectionError.retainedStoreUnreadable
        }
        var references = current.references
        guard references.remove(reference) != nil else { return }
        try ledgerStore.save(references.isEmpty ? nil : ScribeCredentialCleanupLedger(
            revision: current.revision + 1,
            references: references
        ))
    }
}

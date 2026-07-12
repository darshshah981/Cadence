import Foundation

actor ScribeProviderConsentAuthority {
    private var ephemeral: [UUID: ScribeProviderConsentReceipt] = [:]
    private var committed: [UUID: ScribeProviderConsentReceipt] = [:]

    func issueEphemeral(
        providerKind: ScribeProviderKind,
        recipientOrigin: String,
        routingPolicy: ScribeProviderRoutingPolicy,
        retentionPolicy: ScribeProviderRetentionPolicy,
        dataPolicy: ScribeProviderDataPolicy,
        disclosureRevision: Int = ScribeProviderDisclosure.currentVersion,
        acceptedAt: Date = Date()
    ) -> ScribeProviderConsentReceipt {
        let receipt = ScribeProviderConsentIssuer.issue(
            providerKind: providerKind,
            recipientOrigin: recipientOrigin,
            routingPolicy: routingPolicy,
            retentionPolicy: retentionPolicy,
            dataPolicy: dataPolicy,
            disclosureRevision: disclosureRevision,
            acceptedAt: acceptedAt
        )
        ephemeral[receipt.id] = receipt
        return receipt
    }

    func verify(_ receipt: ScribeProviderConsentReceipt) -> Bool {
        ephemeral[receipt.id] == receipt || committed[receipt.id] == receipt
    }

    func commit(_ receipt: ScribeProviderConsentReceipt) -> Bool {
        guard ephemeral.removeValue(forKey: receipt.id) == receipt else { return false }
        committed[receipt.id] = receipt
        return true
    }

    func revoke(_ receiptID: UUID) {
        ephemeral.removeValue(forKey: receiptID)
        committed.removeValue(forKey: receiptID)
    }

    func revokeAllEphemeral() {
        ephemeral.removeAll(keepingCapacity: false)
    }

    func bootstrap(from library: ScribeProviderLibrary) {
        committed.removeAll(keepingCapacity: false)
        for configuration in library.configurations where
            ScribeProviderLibraryConfigurationValidator.isValid(configuration) {
            guard let receipt = configuration.consentReceipt,
                  receipt.disclosureRevision == ScribeProviderDisclosure.currentVersion,
                  receipt.materiallyMatches(configuration) else { continue }
            committed[receipt.id] = receipt
        }
    }

    nonisolated func verifier() -> ScribeProviderConsentVerifying {
        { [weak self] receipt in
            guard let self else { return false }
            return await self.verify(receipt)
        }
    }
}

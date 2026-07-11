import Foundation
import Testing
@testable import Cadence

struct ScribeProviderConsentTests {
    @Test
    func opaqueReceiptRequiresAuthorityAndRevocationIsImmediate() async {
        let authority = ScribeProviderConsentAuthority()
        let receipt = await authority.issueEphemeral(
            providerKind: .openRouter,
            recipientOrigin: "https://openrouter.ai",
            routingPolicy: .zeroDataRetentionSingleModel,
            retentionPolicy: .zeroDataRetentionRequired,
            dataPolicy: .collectionDenied,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        #expect(await authority.verify(receipt))
        #expect(await authority.commit(receipt))
        #expect(await authority.verify(receipt))
        await authority.revoke(receipt.id)
        #expect(!(await authority.verify(receipt)))
    }

    @Test
    func materialDriftInvalidatesButModelIsOutsideConsent() throws {
        let receipt = ScribeProviderConsentIssuer.issue(
            providerKind: .openAIDirect,
            recipientOrigin: "https://api.openai.com",
            routingPolicy: .directSingleModel,
            retentionPolicy: .requestStorageDisabled,
            dataPolicy: .providerPolicyApplies,
            disclosureRevision: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let one = try U5Fixtures.configuration(kind: .openAIDirect, model: "gpt-one", receipt: receipt)
        let two = try U5Fixtures.configuration(kind: .openAIDirect, model: "gpt-two", receipt: receipt)
        #expect(receipt.materiallyMatches(one))
        #expect(receipt.materiallyMatches(two))
        #expect(!receipt.materiallyMatches(one.withOrigin("https://wrong.example")))
    }

    @Test @MainActor
    func setupDismissAndProviderSwitchClearSecretAndFenceLateCallbacks() async {
        let authority = ScribeProviderConsentAuthority()
        let session = ScribeProviderSetupSession(consentAuthority: authority)
        session.begin(providerKind: .openAIDirect, credential: "secret") { _, _, fence in
            try? await Task.sleep(for: .milliseconds(50))
            #expect(!(await fence()))
        }
        let revision = session.attemptRevision
        await session.providerSwitched(to: .openRouter)
        #expect(session.credentialBuffer.isEmpty)
        #expect(!session.acceptsCallback(revision: revision))

        session.begin(providerKind: .openRouter, credential: "second") { _, _, _ in }
        let secondRevision = session.attemptRevision
        await session.dismiss()
        #expect(session.credentialBuffer.isEmpty)
        #expect(session.providerKind == nil)
        #expect(!session.acceptsCallback(revision: secondRevision))
    }
}

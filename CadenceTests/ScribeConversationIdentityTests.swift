import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeConversationIdentityTests {
    @Test
    func noAdaptersAreTrustedByDefault() throws {
        let resolver = try ScribeConversationIdentityResolver()
        let result = resolver.resolve(adapterID: id("unregistered"), for: binding())
        guard case .unsupported(_, .noRegisteredAdapter) = result else {
            Issue.record("Unregistered surfaces must remain unsupported")
            return
        }
        #expect(result.durableMemoryKey == nil)
    }

    @Test
    func stableConversationReturnsSameOpaqueKeyAcrossActionsAndProcessRestarts() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let first = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()))
        let afterRestart = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()))

        #expect(first.memoryKey == afterRestart.memoryKey)
        #expect(first.binding != afterRestart.binding)
        #expect(first.memoryKey.opaqueValue.count == 64)
        #expect(first.memoryKey.opaqueValue.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(!first.memoryKey.opaqueValue.contains("account-a"))
    }

    @Test
    func accountWorkspaceProjectAndConversationCoordinatesStayIsolated() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let target = binding()
        let baseline = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: target)).memoryKey
        var changedKeys = Set<ScribeConversationMemoryKey>()

        for field in ["account", "workspace", "project", "conversation"] {
            adapter.makeEvidence = { target in
                self.evidence(
                    registration: adapter.registration, binding: target,
                    account: field == "account" ? "account-b" : "account-a",
                    workspace: .identified(self.id(field == "workspace" ? "workspace-b" : "workspace-a")),
                    project: .identified(self.id(field == "project" ? "project-b" : "project-a")),
                    conversation: field == "conversation" ? "conversation-b" : "conversation-a"
                )
            }
            let changed = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: target)).memoryKey
            #expect(changed != baseline)
            changedKeys.insert(changed)
        }
        #expect(changedKeys.count == 4)
    }

    @Test
    func returningFromBToARecoversOnlyAsStableIdentifiersMatch() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let firstA = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()))
        adapter.makeEvidence = { self.evidence(registration: adapter.registration, binding: $0, conversation: "conversation-b") }
        let b = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()))
        adapter.makeEvidence = { self.evidence(registration: adapter.registration, binding: $0) }
        let secondA = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()))
        #expect(firstA.memoryKey != b.memoryKey)
        #expect(firstA.memoryKey == secondA.memoryKey)
        #expect(!resolver.revalidate(firstA, for: secondA.binding))
    }

    @Test
    func appAndAdapterNamespacesDoNotMergeIdenticalCoordinates() throws {
        let first = fixture()
        let otherApp = fixture(registration: registration(application: "other-service"))
        let otherAdapter = fixture(registration: registration(adapter: "other-adapter"))
        let otherHost = fixture(registration: registration(host: "com.example.OtherBrowser"))
        let otherSchema = fixture(registration: registration(version: 2))
        var keys = Set<ScribeConversationMemoryKey>()
        for adapter in [first, otherApp, otherAdapter, otherHost, otherSchema] {
            let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
            let result = try verified(resolver.resolve(
                adapterID: adapter.registration.adapterID,
                for: binding(host: adapter.registration.hostBundleIdentifier)
            ))
            keys.insert(result.memoryKey)
        }
        #expect(keys.count == 5)
    }

    @Test
    func duplicatedGenericTitlesCannotSupplyMissingConversationOrAccountIdentity() throws {
        // Titles are deliberately absent from the evidence API. A title-only
        // integration can provide neither of the required stable coordinates.
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        for missingAccount in [false, true] {
            adapter.makeEvidence = {
                self.evidence(registration: adapter.registration, binding: $0,
                              account: missingAccount ? nil : "account-a",
                              conversation: missingAccount ? "conversation-a" : nil)
            }
            for _ in 0..<2 {
                let result = resolver.resolve(adapterID: adapter.registration.adapterID, for: binding())
                #expect(result.durableMemoryKey == nil)
                guard case .ambiguous(_, .missingStableIdentifiers) = result else {
                    Issue.record("A title or app match cannot establish a conversation")
                    return
                }
            }
        }
    }

    @Test
    func missingContainersCannotBecomeAccountWideIdentity() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        for unknownWorkspace in [false, true] {
            adapter.makeEvidence = {
                self.evidence(registration: adapter.registration, binding: $0,
                              workspace: unknownWorkspace ? .unknown : .notApplicable,
                              project: unknownWorkspace ? .notApplicable : .unknown)
            }
            #expect(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()).durableMemoryKey == nil)
        }
        adapter.makeEvidence = {
            self.evidence(registration: adapter.registration, binding: $0,
                          workspace: .notApplicable, project: .notApplicable)
        }
        #expect(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()).durableMemoryKey != nil)
    }

    @Test
    func privateAndUnknownPrivacyAndUncertainConfidenceRemainTransient() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        for privacy in [ScribeConversationPrivacyState.privateBrowsing, .unknown] {
            adapter.makeEvidence = {
                self.evidence(registration: adapter.registration, binding: $0, privacy: privacy)
            }
            #expect(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()).durableMemoryKey == nil)
        }
        for confidence in [ScribeConversationIdentityConfidence.partial, .ambiguous] {
            adapter.makeEvidence = {
                self.evidence(registration: adapter.registration, binding: $0, confidence: confidence)
            }
            #expect(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()).durableMemoryKey == nil)
        }
    }

    @Test
    func missingBrowserTabOrWindowNeverVerifies() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        for target in [binding(window: nil), binding(tab: nil)] {
            let result = resolver.resolve(adapterID: adapter.registration.adapterID, for: target)
            guard case .ambiguous(_, .missingSurfaceIdentity) = result else {
                Issue.record("Missing surface identity must remain ambiguous")
                return
            }
        }
        #expect(adapter.evidenceCallCount == 0)
    }

    @Test
    func nativeSurfaceRequiresWindowButNotTab() throws {
        let adapter = fixture(registration: registration(source: .nativeIntegration))
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        #expect(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding(tab: nil)).durableMemoryKey != nil)
    }

    @Test
    func transientKeysBindActionProcessIncarnationWindowTabAndNavigation() throws {
        let resolver = try ScribeConversationIdentityResolver()
        let original = binding()
        let changes = [
            binding(action: UUID(), process: original.process, window: original.windowIncarnation, tab: original.tabIncarnation, navigation: original.navigationRevision),
            binding(action: original.actionID, process: process(), window: original.windowIncarnation, tab: original.tabIncarnation, navigation: original.navigationRevision),
            binding(action: original.actionID, process: original.process, window: UUID(), tab: original.tabIncarnation, navigation: original.navigationRevision),
            binding(action: original.actionID, process: original.process, window: original.windowIncarnation, tab: UUID(), navigation: original.navigationRevision),
            binding(action: original.actionID, process: original.process, window: original.windowIncarnation, tab: original.tabIncarnation, navigation: UUID())
        ]
        let baseline = try transient(resolver.resolve(adapterID: nil, for: original)).key
        #expect(try transient(resolver.resolve(adapterID: nil, for: original)).key == baseline)
        for target in changes {
            #expect(try transient(resolver.resolve(adapterID: nil, for: target)).key != baseline)
        }
    }

    @Test
    func recycledPIDAndCrossTabEvidenceCannotVerifyOrRevalidatePendingWork() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let original = binding()
        let identity = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: original))
        adapter.makeEvidence = { _ in self.evidence(registration: adapter.registration, binding: original) }
        let reusedPID = binding(action: original.actionID, process: process(), window: original.windowIncarnation, tab: original.tabIncarnation, navigation: original.navigationRevision)
        let otherTab = binding(action: original.actionID, process: original.process, window: original.windowIncarnation, tab: UUID(), navigation: original.navigationRevision)
        for target in [reusedPID, otherTab] {
            let result = resolver.resolve(adapterID: adapter.registration.adapterID, for: target)
            guard case .ambiguous(_, .actionBindingMismatch) = result else {
                Issue.record("Old incarnation evidence must be rejected")
                return
            }
            #expect(!resolver.revalidate(identity, for: target))
        }
    }

    @Test
    func duplicateTabsMayRecoverVerifiedSameConversationButNeverReusePendingBinding() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let first = binding()
        let second = binding(action: first.actionID, process: first.process, window: first.windowIncarnation, tab: UUID(), navigation: first.navigationRevision)
        let identity = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: first))
        let other = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: second))
        #expect(identity.memoryKey == other.memoryKey)
        #expect(!resolver.revalidate(identity, for: second))
    }

    @Test
    func changedStableIdentityInvalidatesEvenAnUnchangedBinding() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let target = binding()
        let original = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: target))
        #expect(resolver.revalidate(original, for: target))
        adapter.makeEvidence = { self.evidence(registration: adapter.registration, binding: $0, account: "account-b") }
        #expect(!resolver.revalidate(original, for: target))
        adapter.makeEvidence = { _ in nil }
        #expect(!resolver.revalidate(original, for: target))
    }

    @Test
    func evidenceSourceApplicationSchemaAndHostMismatchesFailClosed() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        let mismatches = [
            registration(adapter: "other-adapter"), registration(version: 2),
            registration(source: .nativeIntegration), registration(application: "other-service")
        ]
        for mismatch in mismatches {
            adapter.makeEvidence = { self.evidence(registration: mismatch, binding: $0) }
            #expect(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()).durableMemoryKey == nil)
        }
        adapter.makeEvidence = { self.evidence(registration: adapter.registration, binding: $0) }
        let result = resolver.resolve(adapterID: adapter.registration.adapterID, for: binding(host: "com.example.OtherApp"))
        guard case .unsupported(_, .hostApplicationMismatch) = result else {
            Issue.record("A registered adapter cannot claim another host")
            return
        }
    }

    @Test
    func registrationMutationAndDuplicatesAreRejected() throws {
        let adapter = fixture()
        #expect(throws: ScribeConversationAdapterRegistrationError.duplicateAdapter) {
            try ScribeConversationIdentityResolver(adapters: [adapter, adapter])
        }
        #expect(throws: ScribeConversationAdapterRegistrationError.invalidRegistration) {
            try ScribeConversationIdentityResolver(adapters: [fixture(registration: registration(version: 0))])
        }
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        adapter.registration = registration(version: 2)
        guard case .unsupported(_, .registrationChanged) = resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()) else {
            Issue.record("Registration changes require explicit re-registration")
            return
        }
    }

    @Test
    func identifierValidationRejectsEmptyWhitespaceControlsUnicodeAndOversizeValues() {
        for value in ["", " ", "account a", " a", "a ", "a\n", "a\0b", "é", String(repeating: "a", count: 513)] {
            #expect(ScribeConversationStableID(rawValue: value) == nil)
        }
        #expect(id("Account-A") != id("account-a"))
        #expect(ScribeConversationStableID(rawValue: String(repeating: "a", count: 512)) != nil)
    }

    @Test
    func lengthFramingPreventsCoordinateConcatenationCollisions() throws {
        let adapter = fixture()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        // These coordinates collide if joined using an unescaped pipe delimiter.
        adapter.makeEvidence = {
            self.evidence(registration: adapter.registration, binding: $0,
                          account: "account-a|identified|workspace-a", workspace: .identified(self.id("workspace-b")))
        }
        let first = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()))
        adapter.makeEvidence = {
            self.evidence(registration: adapter.registration, binding: $0,
                          account: "account-a", workspace: .identified(self.id("workspace-a|identified|workspace-b")))
        }
        let second = try verified(resolver.resolve(adapterID: adapter.registration.adapterID, for: binding()))
        #expect(first.memoryKey != second.memoryKey)
    }

    private func id(_ value: String) -> ScribeConversationStableID {
        ScribeConversationStableID(rawValue: value)!
    }

    private func process(host: String = "com.example.Browser") -> ApplicationProcessIdentity {
        .init(processIdentifier: 77, bundleIdentifier: host,
              bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"), incarnation: UUID(),
              launchDate: Date(timeIntervalSince1970: 100))
    }

    private func binding(
        action: UUID = UUID(), process: ApplicationProcessIdentity? = nil,
        window: UUID? = UUID(), tab: UUID? = UUID(), navigation: UUID = UUID(),
        host: String = "com.example.Browser"
    ) -> ScribeConversationActionBinding {
        .init(actionID: action, process: process ?? self.process(host: host),
              windowIncarnation: window, tabIncarnation: tab, navigationRevision: navigation)
    }

    private func registration(
        adapter: String = "fixture-browser-adapter", version: UInt32 = 1,
        source: ScribeConversationIdentitySource = .browserIntegration,
        host: String = "com.example.Browser", application: String = "support-service"
    ) -> ScribeConversationAdapterRegistration {
        .init(adapterID: id(adapter), schemaVersion: version, source: source,
              hostBundleIdentifier: host, applicationID: id(application))
    }

    private func evidence(
        registration: ScribeConversationAdapterRegistration, binding: ScribeConversationActionBinding,
        account: String? = "account-a", workspace: ScribeConversationContainerID? = nil,
        project: ScribeConversationContainerID? = nil, conversation: String? = "conversation-a",
        confidence: ScribeConversationIdentityConfidence = .verifiedStableIdentifiers,
        privacy: ScribeConversationPrivacyState = .regular
    ) -> ScribeConversationIdentityEvidence {
        .init(adapterID: registration.adapterID, schemaVersion: registration.schemaVersion,
              source: registration.source, binding: binding, confidence: confidence, privacyState: privacy,
              applicationID: registration.applicationID, accountID: account.map(id),
              workspaceID: workspace ?? .identified(id("workspace-a")),
              projectID: project ?? .identified(id("project-a")), conversationID: conversation.map(id))
    }

    private func fixture(registration: ScribeConversationAdapterRegistration? = nil) -> ConversationFixtureAdapter {
        let registered = registration ?? self.registration()
        return ConversationFixtureAdapter(registration: registered) { self.evidence(registration: registered, binding: $0) }
    }

    private func verified(_ resolution: ScribeConversationIdentityResolution) throws -> ScribeVerifiedConversationIdentity {
        guard case let .verified(identity) = resolution else {
            Issue.record("Expected verified identity")
            throw ConversationFixtureError.unexpectedResolution
        }
        return identity
    }

    private func transient(_ resolution: ScribeConversationIdentityResolution) throws -> ScribeTransientConversationIdentity {
        switch resolution {
        case let .ambiguous(identity, _), let .unsupported(identity, _): return identity
        case .verified:
            Issue.record("Expected temporary identity")
            throw ConversationFixtureError.unexpectedResolution
        }
    }
}

private enum ConversationFixtureError: Error { case unexpectedResolution }

@MainActor
private final class ConversationFixtureAdapter: ScribeConversationIdentityAdapter {
    var registration: ScribeConversationAdapterRegistration
    var makeEvidence: (ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence?
    private(set) var evidenceCallCount = 0

    init(registration: ScribeConversationAdapterRegistration,
         makeEvidence: @escaping (ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence?) {
        self.registration = registration
        self.makeEvidence = makeEvidence
    }

    func evidence(for binding: ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence? {
        evidenceCallCount += 1
        return makeEvidence(binding)
    }
}

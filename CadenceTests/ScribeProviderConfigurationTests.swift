import Foundation
import Security
import Testing
@testable import Cadence

struct ScribeProviderConfigurationTests {
    @Test(arguments: [
        ("https://provider.example/v1", "https://provider.example/v1", "https://provider.example/v1/chat/completions"),
        ("HTTPS://Provider.Example:443/OpenAI/v1///", "https://provider.example/OpenAI/v1", "https://provider.example/OpenAI/v1/chat/completions"),
        ("https://provider.example:8443", "https://provider.example:8443", "https://provider.example:8443/chat/completions")
    ])
    func advancedEndpointNormalizesOnlyTheApprovedSurface(
        input: String,
        expectedBase: String,
        expectedEndpoint: String
    ) throws {
        let endpoint = try AdvancedScribeEndpoint(input)

        #expect(endpoint.normalizedBaseURL.absoluteString == expectedBase)
        #expect(endpoint.requestURL.absoluteString == expectedEndpoint)
        #expect(endpoint.normalizedOrigin == URL(string: expectedBase)?.originString)
    }

    @Test(arguments: [
        "http://provider.example/v1",
        "https://user:pass@provider.example/v1",
        "https://provider.example/v1?key=nope",
        "https://provider.example/v1#fragment",
        "https://provider.example/v1/../secret",
        "https://provider.example/v1/%2e%2e/secret",
        "https://provider.example/v1%2Fsecret",
        "https://provider.example/v1\\secret",
        "https://provider.example/v1/chat/completions",
        "not a url"
    ])
    func advancedEndpointRejectsAmbiguousOrUnsafeValues(input: String) {
        #expect(throws: ScribeProviderConfigurationError.self) {
            try AdvancedScribeEndpoint(input)
        }
    }

    @Test
    func providerCatalogPinsOneDeepSeekProfile() throws {
        let entry = try #require(ScribeProviderCatalog.releaseOne.deepSeekEntries.only)

        #expect(entry.catalogID == "deepseek.v4-flash.non-thinking.v1")
        #expect(entry.modelID == "deepseek-v4-flash")
        #expect(entry.endpoint.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(entry.acceptedResponseModelIDs == ["deepseek-v4-flash"])
        #expect(entry.thinkingDisabled)
    }

    @Test
    func configurationStoreDistinguishesMissingValidMalformedAndFuture() throws {
        let suite = "CadenceTests.ScribeConfig.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScribeProviderConfigurationStore(defaults: defaults, key: "provider")

        #expect(store.load() == .absent)
        let configuration = try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "opaque-ref"),
            acceptedAt: Date(timeIntervalSince1970: 123)
        )
        try store.save(configuration)
        #expect(store.load() == .valid(configuration))

        defaults.set(Data("not-json".utf8), forKey: "provider")
        #expect(store.load() == .rejected(.malformed))

        defaults.set(try JSONEncoder().encode(ScribeProviderConfigurationEnvelope(
            schemaVersion: 999,
            configuration: configuration
        )), forKey: "provider")
        #expect(store.load() == .rejected(.futureSchema))
    }

    @Test
    func keychainAttributesAreAppScopedAndNonSynchronizing() {
        let attributes = KeychainScribeCredentialStore.addAttributes(
            reference: .init(rawValue: "opaque")
        )

        #expect(attributes[kSecClass as String] as! CFString == kSecClassGenericPassword)
        #expect(attributes[kSecAttrService as String] as? String == KeychainScribeCredentialStore.service)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(attributes[kSecAttrAccessible as String] as! CFString == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
}

@MainActor
struct ScribeProviderConnectionManagerTests {
    @Test
    func failedValidationPersistsNothingAndPreservesWorkingConfiguration() async throws {
        let oldReference = ScribeCredentialReference(rawValue: "old")
        let old = try ScribeProviderConfiguration.deepSeek(
            credentialReference: oldReference,
            acceptedAt: Date(timeIntervalSince1970: 1)
        )
        let configurationStore = StubConfigurationStore(configuration: old)
        let credentialStore = StubCredentialStore(values: [oldReference: "working-key"])
        let manager = ScribeProviderConnectionManager(
            configurationStore: configurationStore,
            credentialStore: credentialStore
        )
        let candidate = try ScribeProviderCandidateConfiguration.deepSeek(
            acceptedAt: Date(timeIntervalSince1970: 2)
        )

        await #expect(throws: ScribeProviderConnectionError.validationFailed) {
            try await manager.connect(candidate: candidate, credential: "bad-key") { _, _ in
                throw ScribeProviderConnectionError.validationFailed
            }
        }

        #expect(configurationStore.configuration == old)
        #expect(credentialStore.values == [oldReference: "working-key"])
        #expect(credentialStore.stagedCredentials.isEmpty)
    }

    @Test
    func successfulReplacementStagesCommitsThenCleansOldReference() async throws {
        let oldReference = ScribeCredentialReference(rawValue: "old")
        let old = try ScribeProviderConfiguration.deepSeek(
            credentialReference: oldReference,
            acceptedAt: Date(timeIntervalSince1970: 1)
        )
        let configurationStore = StubConfigurationStore(configuration: old)
        let credentialStore = StubCredentialStore(values: [oldReference: "working-key"])
        configurationStore.onSave = { credentialStore.events.append("commit-observed") }
        let manager = ScribeProviderConnectionManager(
            configurationStore: configurationStore,
            credentialStore: credentialStore
        )
        let candidate = try ScribeProviderCandidateConfiguration.deepSeek(
            acceptedAt: Date(timeIntervalSince1970: 2)
        )

        let connected = try await manager.connect(
            candidate: candidate,
            credential: "new-key"
        ) { receivedCandidate, key in
            #expect(receivedCandidate == candidate)
            #expect(key == "new-key")
        }

        #expect(configurationStore.configuration == connected)
        #expect(credentialStore.values[connected.credentialReference] == "new-key")
        #expect(credentialStore.values[oldReference] == nil)
        #expect(credentialStore.events.prefix(3) == ["stage", "commit-observed", "delete:old"])
    }

    @Test
    func cancelledValidationCannotReachCredentialStaging() async throws {
        let configurationStore = StubConfigurationStore(configuration: nil)
        let credentialStore = StubCredentialStore(values: [:])
        let manager = ScribeProviderConnectionManager(
            configurationStore: configurationStore,
            credentialStore: credentialStore
        )
        let candidate = try ScribeProviderCandidateConfiguration.deepSeek(acceptedAt: Date())
        let task = Task {
            try await manager.connect(candidate: candidate, credential: "candidate") { _, _ in
                try await Task.sleep(for: .seconds(10))
            }
        }

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(configurationStore.configuration == nil)
        #expect(credentialStore.values.isEmpty)
        #expect(credentialStore.stagedCredentials.isEmpty)
    }
}

@MainActor
struct ScribeProviderControllerTests {
    @Test
    func setupRequiredMakesZeroRequestsUntilAffirmativeConnect() async throws {
        let configurationStore = StubConfigurationStore(configuration: nil)
        let credentialStore = StubCredentialStore(values: [:])
        let transport = ControllerTransport(responses: [Self.deepSeekResponse("OK")])
        let controller = ScribeProviderController(
            configurationStore: configurationStore,
            credentialStore: credentialStore,
            transport: transport
        )

        #expect(controller.readiness == .setupRequired)
        #expect(await transport.requests.isEmpty)
        #expect(throws: ScribeProviderFailure(
            phase: .generation,
            category: .setupRequired,
            retryDisposition: .reconnect
        )) {
            try controller.providerForNewAction()
        }

        try await controller.connectDeepSeek(
            credential: "candidate-key",
            acceptedAt: Date(timeIntervalSince1970: 123)
        )

        #expect(controller.readiness == .ready(.deepSeek))
        #expect(await transport.requests.count == 1)
        #expect(configurationStore.configuration?.normalizedOrigin == "https://api.deepseek.com")
        #expect(!credentialStore.values.isEmpty)
    }

    @Test
    func failedValidationDoesNotPersistAndRemovalIsScoped() async throws {
        let failedConfigurationStore = StubConfigurationStore(configuration: nil)
        let failedCredentialStore = StubCredentialStore(values: [:])
        let failedTransport = ControllerTransport(responses: [
            Self.response(status: 401, body: Data("raw body".utf8))
        ])
        let failedController = ScribeProviderController(
            configurationStore: failedConfigurationStore,
            credentialStore: failedCredentialStore,
            transport: failedTransport
        )

        await #expect(throws: ScribeProviderFailure.self) {
            try await failedController.connectDeepSeek(credential: "bad")
        }
        #expect(failedConfigurationStore.configuration == nil)
        #expect(failedCredentialStore.values.isEmpty)

        let configurationStore = StubConfigurationStore(configuration: nil)
        let credentialStore = StubCredentialStore(values: [:])
        let transport = ControllerTransport(responses: [Self.deepSeekResponse("OK")])
        let controller = ScribeProviderController(
            configurationStore: configurationStore,
            credentialStore: credentialStore,
            transport: transport
        )
        try await controller.connectDeepSeek(credential: "working")
        try controller.removeProvider()

        #expect(controller.readiness == .removed)
        #expect(configurationStore.configuration == nil)
        #expect(credentialStore.values.isEmpty)
    }

    @Test
    func legacyControllerDoesNotBroadSweepCredentialsAtStartup() throws {
        let activeReference = ScribeCredentialReference(rawValue: "active")
        let orphanReference = ScribeCredentialReference(rawValue: "orphan")
        let configuration = try ScribeProviderConfiguration.deepSeek(
            credentialReference: activeReference,
            acceptedAt: Date()
        )
        let configurationStore = StubConfigurationStore(configuration: configuration)
        let credentialStore = StubCredentialStore(values: [
            activeReference: "working",
            orphanReference: "staged-before-crash"
        ])

        let controller = ScribeProviderController(
            configurationStore: configurationStore,
            credentialStore: credentialStore,
            transport: ControllerTransport(responses: [])
        )

        #expect(controller.readiness == .ready(.deepSeek))
        #expect(credentialStore.values == [
            activeReference: "working",
            orphanReference: "staged-before-crash"
        ])
    }

    @Test
    func rejectedConfigurationNeverAuthorizesCredentialCleanup() {
        let unreadableReference = ScribeCredentialReference(rawValue: "possibly-active")
        let configurationStore = StubConfigurationStore(
            configuration: nil,
            loadOverride: .rejected(.malformed)
        )
        let credentialStore = StubCredentialStore(values: [
            unreadableReference: "must-not-be-deleted"
        ])

        let controller = ScribeProviderController(
            configurationStore: configurationStore,
            credentialStore: credentialStore,
            transport: ControllerTransport(responses: [])
        )

        #expect(controller.readiness == .configurationInvalid)
        #expect(credentialStore.values[unreadableReference] == "must-not-be-deleted")
    }

    @Test
    func controllerRejectsAdvancedRecipientDriftAndOldDisclosure() throws {
        let reference = ScribeCredentialReference(rawValue: "advanced")
        let endpoint = try AdvancedScribeEndpoint("https://provider.example/v1")
        let candidate = ScribeProviderCandidateConfiguration.advanced(
            endpoint: endpoint,
            model: try ScribeModelIdentifier("model"),
            acceptedAt: Date()
        )
        let valid = candidate.persisted(credentialReference: reference)
        let drifted = ScribeProviderConfiguration(
            kind: .advanced,
            normalizedOrigin: "https://disclosed.example",
            baseURL: valid.baseURL,
            requestURL: valid.requestURL,
            modelID: valid.modelID,
            catalogID: valid.catalogID,
            disclosureVersion: valid.disclosureVersion,
            acceptedAt: valid.acceptedAt,
            credentialReference: reference,
            isEnabled: true
        )
        let credentialStore = StubCredentialStore(values: [reference: "key"])
        let driftedController = ScribeProviderController(
            configurationStore: StubConfigurationStore(configuration: drifted),
            credentialStore: credentialStore,
            transport: ControllerTransport(responses: [])
        )
        #expect(driftedController.readiness == .configurationInvalid)
        #expect(throws: ScribeProviderFailure.self) {
            try driftedController.actionForNewRequest()
        }

        let oldDisclosure = ScribeProviderConfiguration(
            kind: valid.kind,
            normalizedOrigin: valid.normalizedOrigin,
            baseURL: valid.baseURL,
            requestURL: valid.requestURL,
            modelID: valid.modelID,
            catalogID: valid.catalogID,
            disclosureVersion: ScribeProviderDisclosure.currentVersion - 1,
            acceptedAt: valid.acceptedAt,
            credentialReference: reference,
            isEnabled: true
        )
        let oldController = ScribeProviderController(
            configurationStore: StubConfigurationStore(configuration: oldDisclosure),
            credentialStore: credentialStore,
            transport: ControllerTransport(responses: [])
        )
        #expect(oldController.readiness == .configurationInvalid)
    }

    @Test
    func providerRemovalSuppressesActiveWorkEvenWhenKeyDeletionFails() throws {
        let reference = ScribeCredentialReference(rawValue: "active")
        let configuration = try ScribeProviderConfiguration.deepSeek(
            credentialReference: reference,
            acceptedAt: Date()
        )
        let configurationStore = StubConfigurationStore(configuration: configuration)
        let credentialStore = StubCredentialStore(
            values: [reference: "working"],
            deleteFailures: [reference]
        )
        let controller = ScribeProviderController(
            configurationStore: configurationStore,
            credentialStore: credentialStore,
            transport: ControllerTransport(responses: [])
        )
        var invalidated = false
        controller.onProviderRemoved = { invalidated = true }

        #expect(throws: ScribeCredentialStoreError.self) {
            try controller.removeProvider()
        }

        #expect(invalidated)
        #expect(configurationStore.configuration == nil)
        #expect(credentialStore.values[reference] == "working")
        #expect(controller.readiness == .setupRequired)
    }

    private static func deepSeekResponse(_ content: String) -> ScribeHTTPResponse {
        response(status: 200, body: try! JSONSerialization.data(withJSONObject: [
            "model": "deepseek-v4-flash",
            "choices": [[
                "index": 0,
                "finish_reason": "stop",
                "message": ["role": "assistant", "content": content]
            ]]
        ]))
    }

    private static func response(status: Int, body: Data) -> ScribeHTTPResponse {
        ScribeHTTPResponse(
            data: body,
            response: HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/chat/completions")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private final class StubConfigurationStore: ScribeProviderConfigurationPersisting {
    var configuration: ScribeProviderConfiguration?
    var onSave: (() -> Void)?
    private var loadOverride: ScribeProviderConfigurationLoadResult?

    init(
        configuration: ScribeProviderConfiguration?,
        loadOverride: ScribeProviderConfigurationLoadResult? = nil
    ) {
        self.configuration = configuration
        self.loadOverride = loadOverride
    }

    func load() -> ScribeProviderConfigurationLoadResult {
        if let loadOverride { return loadOverride }
        return configuration.map(ScribeProviderConfigurationLoadResult.valid) ?? .absent
    }

    func save(_ configuration: ScribeProviderConfiguration?) throws {
        self.configuration = configuration
        loadOverride = nil
        onSave?()
    }
}

private final class StubCredentialStore: ScribeCredentialStoring {
    var values: [ScribeCredentialReference: String]
    var stagedCredentials: [String] = []
    var events: [String] = []
    private var sequence = 0
    private let deleteFailures: Set<ScribeCredentialReference>

    init(
        values: [ScribeCredentialReference: String],
        deleteFailures: Set<ScribeCredentialReference> = []
    ) {
        self.values = values
        self.deleteFailures = deleteFailures
    }

    func stage(_ credential: String) throws -> ScribeCredentialReference {
        sequence += 1
        let reference = ScribeCredentialReference(rawValue: "staged-\(sequence)")
        values[reference] = credential
        stagedCredentials.append(credential)
        events.append("stage")
        return reference
    }

    func load(reference: ScribeCredentialReference) throws -> String? { values[reference] }

    func delete(reference: ScribeCredentialReference) throws {
        if deleteFailures.contains(reference) {
            throw ScribeCredentialStoreError.keychain(errSecInteractionNotAllowed)
        }
        if reference.rawValue.hasPrefix("staged-") { events.append("commit-observed") }
        events.append("delete:\(reference.rawValue)")
        values.removeValue(forKey: reference)
    }

    func allReferences() throws -> Set<ScribeCredentialReference> { Set(values.keys) }
}

private actor ControllerTransport: ScribeHTTPTransporting {
    private var responses: [ScribeHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [ScribeHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest, deadline: Duration) async throws -> ScribeHTTPResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private extension URL {
    var originString: String? {
        guard let scheme, let host else { return nil }
        return port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}

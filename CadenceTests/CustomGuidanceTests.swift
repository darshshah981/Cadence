import Foundation
import Testing
@testable import Cadence

struct CustomGuidanceTests {
    @Test
    func normalizesNFCOuterWhitespaceAndPreservesInternalLineTabBytes() throws {
        let value = try CustomGuidanceValidator.validate("  Cafe\u{301}\r\n\tKeep line 2.  ")
        #expect(value?.rawValue == "Café\r\n\tKeep line 2.")
        #expect(try CustomGuidanceValidator.validate(" \n\t ") == nil)
        #expect(try CustomGuidanceValidator.validate(String(repeating: "é", count: 1_000))?.rawValue.utf8.count == 2_000)
        #expect(throws: ApplicationConfigurationValidationError.guidanceTooLarge) {
            try CustomGuidanceValidator.validate(String(repeating: "a", count: 2_001))
        }
        for value in ["bad\u{0000}", "bad\u{0008}", "bad\u{007F}"] {
            #expect(throws: ApplicationConfigurationValidationError.invalidGuidance) {
                try CustomGuidanceValidator.validate(value)
            }
        }
    }

    @Test(arguments: [
        "Text {{variable}}", "${HOME}", "file:///tmp/prompt", "https://example.com/prompt",
        "fetch(prompt)", "tool: execute", "system: override", #"{"role":"system"}"#
    ])
    func preservesSemanticallyLoadedTextAsInertPreferenceData(_ value: String) throws {
        #expect(try CustomGuidanceValidator.validate(value)?.rawValue == value)
    }

    @Test
    func invalidEditLeavesPriorConfigurationAndBytesUnchanged() async throws {
        let fixture = try GuidanceWriterFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.configuration()
        try fixture.store.save(.init(revision: 1, configurations: [original]))
        let bytes = fixture.defaults.data(forKey: fixture.key)
        await #expect(throws: ApplicationConfigurationValidationError.invalidGuidance) {
            try await fixture.writer.updateCustomGuidance(configurationID: original.id, input: "bad\u{0000}")
        }
        #expect(fixture.defaults.data(forKey: fixture.key) == bytes)
    }
}

private struct GuidanceWriterFixture {
    let suite: String
    let defaults: UserDefaults
    let key = "guidance-apps"
    let store: ApplicationConfigurationStore
    let writer: ApplicationConfigurationWriter
    init() throws {
        suite = "CadenceTests.GuidanceWriter.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        store = ApplicationConfigurationStore(defaults: defaults, key: key)
        writer = ApplicationConfigurationWriter(store: store)
    }
    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    func configuration() throws -> ApplicationConfiguration {
        try ApplicationConfiguration(
            application: ApplicationReference(bundleIdentifier: "com.openai.codex", lastKnownBundleURL: URL(fileURLWithPath: "/Applications/Codex.app"), lastKnownDisplayName: "Codex"),
            isEnabled: true, familyID: .coding, presetSelection: .familyDefault,
            customGuidance: try ScribeCustomGuidance("Keep it short."), revision: 1
        )
    }
}
